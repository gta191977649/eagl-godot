from __future__ import annotations

import json
import math
import re
import shutil
import struct
from pathlib import Path
from typing import Any

from shapely import constrained_delaunay_triangles, set_precision
from shapely.geometry import GeometryCollection, LineString, MultiPolygon, Point, Polygon
from shapely.ops import polygonize, unary_union

from .binary import Matrix4, Vec3, compose_matrix4, transform_point
from .glb_writer import _decode_vif_color_5551, _indices_for_block, _texture_hash_for_run
from .material_alpha import decide_material_alpha, scene_texture_render_flags
from .model import DecodedBlock, MeshObject, Scene, TrackCollisionPolygon
from .textures import Texture, TextureLibrary


FORMAT_VERSION = 2
DRIVABLE_COLLISION_MIN_NORMAL_Y = 0.1
COLLISION_DEGENERATE_EPSILON = 1e-12
BOUNDARY_POINT_QUANTIZE = 20.0
DRIVE_AREA_POLYGON_GRID_SIZE = 16.0
DRIVE_AREA_POLYGON_EDGE_EPSILON = 0.08
BOUNDARY_SAMPLE_OFFSET = 0.25
BOUNDARY_GRID_CELL_SIZE = 16.0
WALL_BARRIER_SNAP_GRID = 0.25
WALL_BARRIER_MIN_POLYGON_AREA = 4.0
WALL_BARRIER_MIN_TRIANGLE_AREA = 0.02
ROAD_COLLISION_MAX_TRIANGLE_EDGE = 10.0
ROUTE_RIBBON_MIN_WIDTH = 3.0
ROUTE_RIBBON_PADDING = 1.0


class BinaryBuffer:
    def __init__(self) -> None:
        self.data = bytearray()

    def align(self, size: int = 4) -> None:
        padding = (-len(self.data)) % size
        if padding:
            self.data.extend(b"\0" * padding)

    def add(self, payload: bytes, *, stride: int, kind: str) -> dict[str, Any]:
        self.align(4)
        offset = len(self.data)
        self.data.extend(payload)
        return {
            "offset": offset,
            "byte_length": len(payload),
            "count": len(payload) // stride if stride else 0,
            "stride": stride,
            "kind": kind,
        }


def write_godot_track_package(
    scene: Scene,
    out_dir: Path,
    track_name: str,
    textures: TextureLibrary | None = None,
    vertex_colors: str = "always",
    progress: bool = False,
) -> Path:
    del progress
    textures = textures or TextureLibrary({})
    out_dir.mkdir(parents=True, exist_ok=True)
    texture_dir = out_dir / "textures"
    texture_dir.mkdir(parents=True, exist_ok=True)

    binary = BinaryBuffer()
    pack_info = _object_pack_info(scene)
    pivots_by_object_index = {object_index: _object_pivot(obj) for object_index, obj in enumerate(scene.objects)}
    objects: list[dict[str, Any]] = []
    materials: dict[str, dict[str, Any]] = {}
    referenced_texture_hashes: set[int] = set()
    texture_render_flags = scene_texture_render_flags(scene)

    for object_index, obj in enumerate(scene.objects):
        info = pack_info.get(obj.chunk_offset, {})
        is_scenery_template = bool(info.get("is_scenery_template", False))
        surfaces = _object_surfaces(
            obj,
            object_index,
            pivots_by_object_index[object_index],
            binary,
            textures,
            materials,
            referenced_texture_hashes,
            vertex_colors,
            texture_render_flags,
        )
        if not surfaces:
            continue
        objects.append(
            {
                "index": object_index,
                "name": obj.name,
                "chunk_offset": obj.chunk_offset,
                "name_hash": obj.name_hash or 0,
                "transform": _matrix_to_json(_transform_with_pivot(obj.transform, pivots_by_object_index[object_index])),
                "texture_hashes": list(obj.texture_hashes),
                "solid_pack_index": info.get("solid_pack_index", -1),
                "solid_pack_offset": info.get("solid_pack_offset", -1),
                "is_scenery_template": is_scenery_template,
                "source_role": _source_role(info),
                "category": _category_for_object(obj, surfaces, is_scenery_template, textures),
                "aabb": _aabb_for_surfaces(surfaces),
                "pivot": _vec3_to_json(_ps2_to_godot_vec3(pivots_by_object_index[object_index])),
                "surfaces": surfaces,
            }
        )

    collision = _collision_manifest(scene, objects, binary)
    boundary = _boundary_manifest(scene)
    route = _route_manifest(scene)

    binary_path = out_dir / f"{track_name}.eagltrack.bin"
    binary_path.write_bytes(bytes(binary.data))

    texture_records = _write_textures(texture_dir, textures, referenced_texture_hashes)
    manifest = {
        "format": "eagltrack",
        "version": FORMAT_VERSION,
        "generator": "map_tools_ps2 export-godot",
        "track_id": _track_id_from_name(track_name),
        "binary": {
            "path": binary_path.name,
            "byte_length": len(binary.data),
            "endianness": "little",
        },
        "textures": texture_records,
        "materials": list(materials.values()),
        "objects": objects,
        "solid_packs": _solid_packs_to_json(scene),
        "scenery_sections": _scenery_sections_to_json(scene),
        "scenery_instances": _scenery_instances_to_json(scene, pivots_by_object_index),
        "collision": collision,
        "boundary": boundary,
        "route": route,
        "stats": {
            "source_object_count": len(scene.objects),
            "exported_object_count": len(objects),
            "solid_pack_count": len(scene.solid_packs),
            "scenery_section_count": len(scene.scenery_sections),
            "scenery_instance_count": len(scene.scenery_instances),
            "surface_count": sum(len(obj["surfaces"]) for obj in objects),
            "vertex_count": sum(surface["positions"]["count"] for obj in objects for surface in obj["surfaces"]),
            "index_count": sum(surface["indices"]["count"] for obj in objects for surface in obj["surfaces"]),
            "texture_count": len(texture_records),
            "collision_surface_count": collision["stats"]["surface_count"],
            "collision_triangle_count": collision["stats"]["triangle_count"],
            "track_collision_polygon_count": len(scene.track_collision_polygons),
            "track_collision_drive_area_polygon_count": sum(
                1 for polygon in scene.track_collision_polygons if _track_collision_polygon_contributes_to_drive_area(polygon)
            ),
            "track_route_segment_count": len(scene.track_route_segments),
            "track_route_edge_count": len(scene.track_route_edges),
            "route_point_count": int(route["stats"]["point_count"]),
            "boundary_segment_count": int(boundary["stats"]["segment_count"]),
            "allowed_road_area_count": len(scene.allowed_road_areas),
            "collision_source": "track_collision_polygons",
        },
    }

    manifest_path = out_dir / f"{track_name}.eagltrack.json"
    manifest_text = json.dumps(manifest, indent=2)
    manifest_path.write_text(manifest_text, encoding="utf-8")
    shutil.copyfile(manifest_path, out_dir / f"{track_name}.eagltrack")
    return manifest_path


def _object_surfaces(
    obj: MeshObject,
    object_index: int,
    pivot: Vec3,
    binary: BinaryBuffer,
    textures: TextureLibrary,
    materials: dict[str, dict[str, Any]],
    referenced_texture_hashes: set[int],
    vertex_colors: str,
    texture_render_flags: dict[int, frozenset[int | None]],
) -> list[dict[str, Any]]:
    surfaces: list[dict[str, Any]] = []
    for block_index, block in enumerate(obj.blocks):
        vertices = tuple(_ps2_to_godot_vec3(_sub_vec3(vertex, pivot)) for vertex in block.run.vertices)
        if len(vertices) < 3:
            continue
        indices = _indices_for_block(vertices, obj.name, block)
        if len(indices) < 3:
            continue
        indices = _filter_indices(indices, len(vertices))
        if len(indices) < 3:
            continue
        normals = _normals(vertices, indices)
        texture_hash = _texture_hash_for_run(obj.texture_hashes, obj.run_texture_indices, block_index)
        material_key = _material_key(texture_hash, obj.name, block.render_flag)
        material = _material_record(
            material_key,
            texture_hash,
            textures.get(texture_hash),
            obj.name,
            block.render_flag,
            texture_render_flags.get(texture_hash, ()) if texture_hash is not None else (),
        )
        materials.setdefault(material_key, material)
        if texture_hash:
            referenced_texture_hashes.add(texture_hash)

        surface: dict[str, Any] = {
            "name": f"{obj.name}_{block_index:03d}",
            "object_index": object_index,
            "block_index": block_index,
            "material": material_key,
            "texture_hash": texture_hash or 0,
            "render_flag": block.render_flag or 0,
            "primitive_mode": block.primitive_mode,
            "expected_face_count": block.expected_face_count or 0,
            "topology_code": block.topology_code or 0,
            "source_offset": block.source_offset if block.source_offset is not None else -1,
            "source_qword_size": block.source_qword_size if block.source_qword_size is not None else -1,
            "aabb": _aabb(vertices),
            "positions": binary.add(_pack_vec3(vertices), stride=12, kind="float32_vec3"),
            "normals": binary.add(_pack_vec3(normals), stride=12, kind="float32_vec3"),
            "indices": binary.add(struct.pack("<" + "I" * len(indices), *indices), stride=4, kind="uint32"),
        }
        if len(block.run.texcoords) >= len(vertices):
            surface["uvs"] = binary.add(_pack_uvs(block.run.texcoords[: len(vertices)]), stride=8, kind="float32_vec2")
        if _should_export_colors(block, vertex_colors) and len(block.run.packed_values) >= len(vertices):
            surface["colors"] = binary.add(_pack_colors(block.run.packed_values[: len(vertices)]), stride=4, kind="uint8_rgba")
        surfaces.append(surface)
    return surfaces


def _filter_indices(indices: list[int], vertex_count: int) -> list[int]:
    out: list[int] = []
    for offset in range(0, len(indices) - 2, 3):
        a, b, c = indices[offset : offset + 3]
        if min(a, b, c) < 0 or max(a, b, c) >= vertex_count:
            continue
        if a == b or a == c or b == c:
            continue
        out.extend((a, b, c))
    return out


def _normals(vertices: tuple[Vec3, ...], indices: list[int]) -> tuple[Vec3, ...]:
    accum = [[0.0, 0.0, 0.0] for _ in vertices]
    for offset in range(0, len(indices) - 2, 3):
        ia, ib, ic = indices[offset : offset + 3]
        a, b, c = vertices[ia], vertices[ib], vertices[ic]
        ab = Vec3(b.x - a.x, b.y - a.y, b.z - a.z)
        ac = Vec3(c.x - a.x, c.y - a.y, c.z - a.z)
        normal = Vec3(
            ab.y * ac.z - ab.z * ac.y,
            ab.z * ac.x - ab.x * ac.z,
            ab.x * ac.y - ab.y * ac.x,
        )
        length_sq = normal.x * normal.x + normal.y * normal.y + normal.z * normal.z
        if length_sq <= 1e-12:
            continue
        inv_len = length_sq ** -0.5
        for index in (ia, ib, ic):
            accum[index][0] += normal.x * inv_len
            accum[index][1] += normal.y * inv_len
            accum[index][2] += normal.z * inv_len
    out: list[Vec3] = []
    for x, y, z in accum:
        length_sq = x * x + y * y + z * z
        if length_sq <= 1e-12:
            out.append(Vec3(0.0, 1.0, 0.0))
        else:
            inv_len = length_sq ** -0.5
            out.append(Vec3(x * inv_len, y * inv_len, z * inv_len))
    return tuple(out)


def _pack_vec3(values_in: tuple[Vec3, ...]) -> bytes:
    values: list[float] = []
    for value in values_in:
        values.extend((value.x, value.y, value.z))
    return struct.pack("<" + "f" * len(values), *values)


def _pack_uvs(values_in: tuple[tuple[float, float], ...]) -> bytes:
    values: list[float] = []
    for u, v in values_in:
        values.extend((u, 1.0 - v))
    return struct.pack("<" + "f" * len(values), *values)


def _pack_colors(values_in: tuple[int, ...]) -> bytes:
    out = bytearray()
    for packed in values_in:
        r, g, b, _a = _decode_vif_color_5551(packed)
        out.extend(
            (
                max(0, min(255, round(r * 255.0))),
                max(0, min(255, round(g * 255.0))),
                max(0, min(255, round(b * 255.0))),
                255,
            )
        )
    return bytes(out)


def _collision_manifest(scene: Scene, objects: list[dict[str, Any]], binary: BinaryBuffer) -> dict[str, Any]:
    del objects
    surfaces: list[dict[str, Any]] = []
    polygons: list[dict[str, Any]] = []

    for polygon in scene.track_collision_polygons:
        polygons.append(_collision_polygon_record(polygon))

    corridor_surface = _wall_barrier_polygonized_corridor_surface(scene, binary)
    if corridor_surface is not None:
        surfaces.append(corridor_surface)

    drive_area_lines = _drive_area_boundary_lines(scene.track_collision_polygons) if corridor_surface is None else []
    if drive_area_lines:
        surfaces.append(
            {
                "category": "DriveArea",
                "debug_only": True,
                "triangle_count": 0,
                "line_count": len(drive_area_lines) // 2,
                "candidate_triangle_count": 0,
                "valid_triangle_count": 0,
                "filtered_triangle_count": 0,
                "aabb": _aabb(tuple(drive_area_lines)),
                "faces": binary.add(b"", stride=12, kind="float32_vec3"),
                "debug_lines": binary.add(_pack_vec3(tuple(drive_area_lines)), stride=12, kind="float32_vec3"),
                "source_kind": "track_polygon_collision_area_boundary",
                "source_name": "DriveAreaBoundary",
                "source_chunk_offset": -1,
                "source_record_offset": -1,
                "record_index": -1,
            }
        )

    return {
        "version": 2,
        "stats": {
            "enabled": any(bool(polygon.get("valid_plane", False)) for polygon in polygons),
            "surface_count": len(surfaces),
            "polygon_count": len(polygons),
            "valid_polygon_count": sum(1 for polygon in polygons if bool(polygon.get("valid_plane", False))),
            "triangle_count": int(corridor_surface.get("triangle_count", 0)) if corridor_surface is not None else 0,
            "valid_triangle_count": int(corridor_surface.get("triangle_count", 0)) if corridor_surface is not None else 0,
            "candidate_triangle_count": int(corridor_surface.get("candidate_triangle_count", 0)) if corridor_surface is not None else 0,
            "filtered_triangle_count": 0,
            "bounds": _bounds_for_collision_polygons(polygons),
            "track_collision_polygon_count": len(scene.track_collision_polygons),
            "track_collision_drive_area_polygon_count": sum(
                1 for polygon in scene.track_collision_polygons if _track_collision_polygon_contributes_to_drive_area(polygon)
            ),
            "track_route_segment_count": len(scene.track_route_segments),
            "track_route_edge_count": len(scene.track_route_edges),
            "allowed_road_area_count": len(scene.allowed_road_areas),
            "collision_source": "track_collision_polygons",
            "road_corridor_source": str(corridor_surface.get("source_kind", "")) if corridor_surface is not None else "",
            "road_corridor_triangle_count": int(corridor_surface.get("triangle_count", 0)) if corridor_surface is not None else 0,
            "drive_area_boundary_line_count": len(drive_area_lines) // 2,
        },
        "polygons": polygons,
        "surfaces": surfaces,
    }


def _boundary_manifest(scene: Scene) -> dict[str, Any]:
    segments = _drive_area_boundary_segments(scene.track_collision_polygons)
    bounds = None
    if segments:
        min_x = min(min(float(segment["a_xz"][0]), float(segment["b_xz"][0])) for segment in segments)
        min_z = min(min(float(segment["a_xz"][1]), float(segment["b_xz"][1])) for segment in segments)
        max_x = max(max(float(segment["a_xz"][0]), float(segment["b_xz"][0])) for segment in segments)
        max_z = max(max(float(segment["a_xz"][1]), float(segment["b_xz"][1])) for segment in segments)
        bounds = {
            "min_xz": [min_x, min_z],
            "max_xz": [max_x, max_z],
        }
    return {
        "enabled": bool(segments),
        "cell_size": BOUNDARY_GRID_CELL_SIZE,
        "segments": segments,
        "stats": {
            "segment_count": len(segments),
            "bounds": bounds,
        },
    }


def _route_manifest(scene: Scene) -> dict[str, Any]:
    points: list[dict[str, Any]] = []
    for point in scene.route_points:
        flat_position = point.get("position_godot_flat")
        if not isinstance(flat_position, Vec3):
            continue
        points.append(
            {
                "index": int(point.get("index", len(points))),
                "name": str(point.get("name", "")),
                "position": _vec3_to_json(flat_position),
                "route_sequence": int(point.get("route_sequence", -1)),
                "route_group": str(point.get("route_group", "")),
                "source_chunk_offset": int(point.get("source_chunk_offset", -1)),
                "source_record_offset": int(point.get("source_record_offset", -1)),
            }
        )
    source_stats = scene.route_stats if isinstance(scene.route_stats, dict) else {}
    return {
        "enabled": bool(points),
        "points": points,
        "stats": {
            "point_count": len(points),
            "raw_point_count": int(source_stats.get("raw_point_count", len(points))),
            "declared_count": int(source_stats.get("declared_count", len(points))),
            "source_chunk_offset": int(source_stats.get("source_chunk_offset", -1)),
            "source_chunk_id": int(source_stats.get("source_chunk_id", 0)),
            "filtered_non_route_point_count": int(source_stats.get("filtered_non_route_point_count", 0)),
            "sorted_by_radar_name": bool(source_stats.get("sorted_by_radar_name", False)),
        },
    }


def _collision_faces_for_polygon(polygon: TrackCollisionPolygon) -> tuple[list[Vec3], int, int]:
    faces: list[Vec3] = []
    points = tuple(_ps2_to_godot_vec3(point) for point in polygon.points_ps2)
    if len(points) < 3:
        return faces, 0, 0
    candidate_count = 1
    filtered_count = 0
    if not _append_drivable_collision_face(faces, points[0], points[1], points[2]):
        filtered_count += 1
    if len(points) == 4:
        candidate_count += 1
        if not _append_drivable_collision_face(faces, points[0], points[2], points[3]):
            filtered_count += 1
    return faces, candidate_count, filtered_count


def _wall_barrier_polygonized_corridor_surface(scene: Scene, binary: BinaryBuffer) -> dict[str, Any] | None:
    wall_segments = _wall_barrier_segments(scene.track_collision_polygons)
    route_ribbons = _route_ribbon_polygons(scene)
    if not wall_segments or not route_ribbons:
        return None

    height_sampler = _TrackPolygonHeightSampler(scene.track_collision_polygons)
    height_query = _RouteHeightQuery(scene.track_route_segments)
    route_seed = _clean_geometry(unary_union(route_ribbons))
    if route_seed.is_empty:
        return None

    barrier_lines = [
        LineString((_snap_xy(start, WALL_BARRIER_SNAP_GRID), _snap_xy(end, WALL_BARRIER_SNAP_GRID)))
        for start, end in wall_segments
        if _distance2(start, end) > 1e-8
    ]
    if not barrier_lines:
        return None

    linework = unary_union(barrier_lines)
    candidate_polygons = [
        polygon
        for polygon in polygonize(linework)
        if polygon.area >= WALL_BARRIER_MIN_POLYGON_AREA and polygon.intersects(route_seed)
    ]

    selected = _clean_geometry(unary_union(candidate_polygons)) if candidate_polygons else GeometryCollection()
    fallback_parts = _route_fallback_parts(route_seed, selected)
    footprint = _clean_geometry(unary_union([geometry for geometry in (selected, fallback_parts) if not geometry.is_empty]))
    drive_area = _drive_polygon_area_geometry(scene.track_collision_polygons)
    if not drive_area.is_empty:
        footprint = _clean_geometry(footprint.intersection(drive_area.buffer(WALL_BARRIER_SNAP_GRID)))
    footprint = _filter_footprint(footprint)
    if footprint.is_empty:
        return None

    faces, candidate_triangle_count, filtered_triangle_count = _triangulated_road_faces(footprint, height_sampler, height_query)
    if not faces:
        return None
    debug_lines, missing_edge_height_count = _footprint_debug_lines(footprint, height_sampler, height_query)
    triangle_count = len(faces) // 3
    polygon_count = len(_polygon_parts(footprint))
    return {
        "category": "Road",
        "debug_only": False,
        "triangle_count": triangle_count,
        "line_count": len(debug_lines) // 2,
        "candidate_triangle_count": candidate_triangle_count,
        "valid_triangle_count": triangle_count,
        "filtered_triangle_count": filtered_triangle_count,
        "aabb": _aabb(tuple(faces)),
        "faces": binary.add(_pack_vec3(tuple(faces)), stride=12, kind="float32_vec3"),
        "debug_lines": binary.add(_pack_vec3(tuple(debug_lines)), stride=12, kind="float32_vec3"),
        "source_kind": "wall_barrier_polygonized_corridor",
        "source_name": "WallBarrierPolygonizedRoadCorridor",
        "source_chunk_offset": -1,
        "source_record_offset": -1,
        "record_index": -1,
        "wall_segment_count": len(wall_segments),
        "candidate_polygon_count": len(candidate_polygons),
        "footprint_polygon_count": polygon_count,
        "route_ribbon_count": len(route_ribbons),
        "route_fallback_area": float(fallback_parts.area) if not fallback_parts.is_empty else 0.0,
        "drive_area_clip": not drive_area.is_empty,
        "height_fallback_count": missing_edge_height_count,
    }


def _route_ribbon_polygons(scene: Scene) -> list[Polygon]:
    ribbons: list[Polygon] = []
    route_points_by_index = {segment.route_index: segment.points for segment in scene.track_route_segments}
    for segment in scene.track_route_segments:
        for point_index in range(len(segment.points) - 1):
            polygon = _route_ribbon_between_points(segment.points[point_index], segment.points[point_index + 1])
            if polygon is not None:
                ribbons.append(polygon)
        for point in segment.points:
            edge_index = point.route_edge_index
            if edge_index == 0xFF or edge_index < 0 or edge_index >= len(scene.track_route_edges):
                continue
            edge = scene.track_route_edges[edge_index]
            target_points = route_points_by_index.get(edge.target_route_index)
            if not target_points or edge.target_point_index < 0 or edge.target_point_index >= len(target_points):
                continue
            polygon = _route_ribbon_between_points(point, target_points[edge.target_point_index])
            if polygon is not None:
                ribbons.append(polygon)
    return ribbons


def _route_ribbon_between_points(a, b) -> Polygon | None:
    a_left, a_right = _route_point_boundary_xy(a)
    b_left, b_right = _route_point_boundary_xy(b)
    polygon = Polygon((a_left, b_left, b_right, a_right))
    if polygon.area <= 1e-6:
        return None
    return _clean_geometry(polygon.buffer(ROUTE_RIBBON_PADDING, join_style=2))


def _route_point_boundary_xy(point) -> tuple[tuple[float, float], tuple[float, float]]:
    forward_x, forward_y = point.forward_ps2_2d
    forward_len = math.hypot(forward_x, forward_y)
    if forward_len <= 1e-6:
        forward_x, forward_y = 1.0, 0.0
    else:
        forward_x /= forward_len
        forward_y /= forward_len
    left_width = max(float(point.left_width), ROUTE_RIBBON_MIN_WIDTH)
    right_width = max(float(point.right_width), ROUTE_RIBBON_MIN_WIDTH)
    origin = point.position_ps2
    left = (origin.x - forward_y * left_width, origin.y + forward_x * left_width)
    right = (origin.x + forward_y * right_width, origin.y - forward_x * right_width)
    return left, right


def _route_fallback_parts(route_seed, selected):
    if route_seed.is_empty:
        return GeometryCollection()
    if selected.is_empty:
        return route_seed
    return GeometryCollection()


def _drive_polygon_area_geometry(polygons: list[TrackCollisionPolygon]):
    drive_polygons = []
    for polygon in polygons:
        if not _track_collision_polygon_contributes_to_drive_area(polygon):
            continue
        points = [(point.x, point.y) for point in polygon.points_ps2]
        if len(points) < 3:
            continue
        area = Polygon(points)
        if area.area >= WALL_BARRIER_MIN_POLYGON_AREA:
            drive_polygons.append(area)
    return _clean_geometry(unary_union(drive_polygons)) if drive_polygons else GeometryCollection()


def _triangulated_road_faces(footprint, height_sampler: "_TrackPolygonHeightSampler", height_query: "_RouteHeightQuery") -> tuple[list[Vec3], int, int]:
    faces: list[Vec3] = []
    candidate_triangle_count = 0
    filtered_triangle_count = 0
    for polygon in _polygon_parts(footprint):
        triangles = constrained_delaunay_triangles(polygon)
        for triangle in _polygon_parts(triangles):
            if triangle.area <= WALL_BARRIER_MIN_TRIANGLE_AREA:
                filtered_triangle_count += 1
                continue
            if not triangle.covered_by(polygon.buffer(WALL_BARRIER_SNAP_GRID)):
                filtered_triangle_count += 1
                continue
            coords = list(triangle.exterior.coords)
            if len(coords) < 4:
                filtered_triangle_count += 1
                continue
            for sub_triangle in _subdivide_triangle_xy(tuple(coords[:3])):
                candidate_triangle_count += 1
                ps2_points: list[Vec3] = []
                centroid_x = (sub_triangle[0][0] + sub_triangle[1][0] + sub_triangle[2][0]) / 3.0
                centroid_y = (sub_triangle[0][1] + sub_triangle[1][1] + sub_triangle[2][1]) / 3.0
                centroid_z = height_sampler.height_at(centroid_x, centroid_y, height_query.query_z(centroid_x, centroid_y))
                for x, y in sub_triangle:
                    query_z = height_query.query_z(x, y)
                    height = height_sampler.height_at(x, y, query_z)
                    if height is None:
                        height = centroid_z
                    if height is None:
                        break
                    ps2_points.append(Vec3(x, y, height))
                if len(ps2_points) != 3:
                    filtered_triangle_count += 1
                    continue
                if not _append_drivable_collision_face(
                    faces,
                    _ps2_to_godot_vec3(ps2_points[0]),
                    _ps2_to_godot_vec3(ps2_points[1]),
                    _ps2_to_godot_vec3(ps2_points[2]),
                ):
                    filtered_triangle_count += 1
    return faces, candidate_triangle_count, filtered_triangle_count


def _subdivide_triangle_xy(
    triangle: tuple[tuple[float, float], tuple[float, float], tuple[float, float]],
    max_edge_length: float = ROAD_COLLISION_MAX_TRIANGLE_EDGE,
) -> list[tuple[tuple[float, float], tuple[float, float], tuple[float, float]]]:
    stack = [triangle]
    out: list[tuple[tuple[float, float], tuple[float, float], tuple[float, float]]] = []
    max_edge_sq = max_edge_length * max_edge_length
    while stack:
        a, b, c = stack.pop()
        edges = (
            (_distance2(a, b), a, b, c),
            (_distance2(b, c), b, c, a),
            (_distance2(c, a), c, a, b),
        )
        longest_sq, start, end, opposite = max(edges, key=lambda edge: edge[0])
        if longest_sq <= max_edge_sq:
            out.append((a, b, c))
            continue
        midpoint = ((start[0] + end[0]) * 0.5, (start[1] + end[1]) * 0.5)
        stack.append((start, midpoint, opposite))
        stack.append((midpoint, end, opposite))
    return out


def _footprint_debug_lines(footprint, height_sampler: "_TrackPolygonHeightSampler", height_query: "_RouteHeightQuery") -> tuple[list[Vec3], int]:
    lines: list[Vec3] = []
    missing_height_count = 0
    for polygon in _polygon_parts(footprint):
        missing_height_count += _append_ring_debug_lines(lines, polygon.exterior.coords, height_sampler, height_query)
        for interior in polygon.interiors:
            missing_height_count += _append_ring_debug_lines(lines, interior.coords, height_sampler, height_query)
    return lines, missing_height_count


def _append_ring_debug_lines(lines: list[Vec3], coords, height_sampler: "_TrackPolygonHeightSampler", height_query: "_RouteHeightQuery") -> int:
    missing_height_count = 0
    points = list(coords)
    for index in range(len(points) - 1):
        a = _heighted_ps2_point(points[index], height_sampler, height_query)
        b = _heighted_ps2_point(points[index + 1], height_sampler, height_query)
        if a is None or b is None:
            missing_height_count += 1
            continue
        lines.extend((_ps2_to_godot_vec3(a), _ps2_to_godot_vec3(b)))
    return missing_height_count


def _heighted_ps2_point(coord, height_sampler: "_TrackPolygonHeightSampler", height_query: "_RouteHeightQuery") -> Vec3 | None:
    x = float(coord[0])
    y = float(coord[1])
    height = height_sampler.height_at(x, y, height_query.query_z(x, y))
    if height is None:
        return None
    return Vec3(x, y, height)


def _polygon_parts(geometry) -> list[Polygon]:
    if geometry.is_empty:
        return []
    if isinstance(geometry, Polygon):
        return [geometry]
    if isinstance(geometry, MultiPolygon):
        return list(geometry.geoms)
    if isinstance(geometry, GeometryCollection):
        return [part for part in geometry.geoms if isinstance(part, Polygon)]
    return []


def _filter_footprint(geometry):
    parts = [polygon for polygon in _polygon_parts(geometry) if polygon.area >= WALL_BARRIER_MIN_POLYGON_AREA]
    return _clean_geometry(unary_union(parts)) if parts else GeometryCollection()


def _clean_geometry(geometry):
    if geometry.is_empty:
        return geometry
    return set_precision(geometry, WALL_BARRIER_SNAP_GRID).buffer(0)


def _snap_xy(point: tuple[float, float], grid: float) -> tuple[float, float]:
    return (round(point[0] / grid) * grid, round(point[1] / grid) * grid)


def _distance2(a: tuple[float, float], b: tuple[float, float]) -> float:
    dx = b[0] - a[0]
    dy = b[1] - a[1]
    return dx * dx + dy * dy


def _wall_barrier_corridor_surface(scene: Scene, binary: BinaryBuffer) -> dict[str, Any] | None:
    wall_segments = _wall_barrier_segments(scene.track_collision_polygons)
    if not wall_segments or not scene.track_route_segments:
        return None

    height_sampler = _TrackPolygonHeightSampler(scene.track_collision_polygons)
    faces: list[Vec3] = []
    debug_lines: list[Vec3] = []
    sample_count = 0
    missed_height_count = 0

    for segment in scene.track_route_segments:
        previous_left: Vec3 | None = None
        previous_right: Vec3 | None = None
        for route_point in segment.points:
            forward_x, forward_y = route_point.forward_ps2_2d
            forward_len = math.hypot(forward_x, forward_y)
            if forward_len <= 1e-6:
                previous_left = None
                previous_right = None
                continue
            forward_x /= forward_len
            forward_y /= forward_len
            origin = (route_point.position_ps2.x, route_point.position_ps2.y)
            left_hit = _nearest_wall_ray_hit(origin, (-forward_y, forward_x), wall_segments)
            right_hit = _nearest_wall_ray_hit(origin, (forward_y, -forward_x), wall_segments)
            if left_hit is None or right_hit is None:
                previous_left = None
                previous_right = None
                continue

            query_z = route_point.position_ps2.z
            center_height = height_sampler.height_at(origin[0], origin[1], query_z)
            left_height = height_sampler.height_at(left_hit[0], left_hit[1], query_z)
            right_height = height_sampler.height_at(right_hit[0], right_hit[1], query_z)
            if center_height is None and (left_height is None or right_height is None):
                previous_left = None
                previous_right = None
                missed_height_count += 1
                continue
            if left_height is None:
                left_height = center_height if center_height is not None else right_height
                missed_height_count += 1
            if right_height is None:
                right_height = center_height if center_height is not None else left_height
                missed_height_count += 1
            if left_height is None or right_height is None:
                previous_left = None
                previous_right = None
                continue

            left_point = _ps2_to_godot_vec3(Vec3(left_hit[0], left_hit[1], left_height))
            right_point = _ps2_to_godot_vec3(Vec3(right_hit[0], right_hit[1], right_height))
            sample_count += 1
            if previous_left is not None and previous_right is not None:
                _append_drivable_collision_face(faces, previous_left, previous_right, right_point)
                _append_drivable_collision_face(faces, previous_left, right_point, left_point)
                debug_lines.extend((previous_left, left_point))
                debug_lines.extend((previous_right, right_point))
            previous_left = left_point
            previous_right = right_point

    if not faces:
        return None
    triangle_count = len(faces) // 3
    return {
        "category": "Road",
        "debug_only": False,
        "triangle_count": triangle_count,
        "line_count": len(debug_lines) // 2,
        "candidate_triangle_count": triangle_count,
        "valid_triangle_count": triangle_count,
        "filtered_triangle_count": 0,
        "aabb": _aabb(tuple(faces)),
        "faces": binary.add(_pack_vec3(tuple(faces)), stride=12, kind="float32_vec3"),
        "debug_lines": binary.add(_pack_vec3(tuple(debug_lines)), stride=12, kind="float32_vec3"),
        "source_kind": "wall_barrier_corridor",
        "source_name": "WallBarrierRoadCorridor",
        "source_chunk_offset": -1,
        "source_record_offset": -1,
        "record_index": -1,
        "route_sample_count": sample_count,
        "height_fallback_count": missed_height_count,
    }


class _TrackPolygonHeightSampler:
    def __init__(self, polygons: list[TrackCollisionPolygon]) -> None:
        self._polygons = [polygon for polygon in polygons if _track_collision_polygon_contributes_to_drive_area(polygon)]
        self._planes: dict[int, tuple[Vec3, float]] = {}
        self._bounds: dict[int, tuple[float, float, float, float]] = {}
        self._grid: dict[tuple[int, int], list[int]] = {}
        self._cell_size = 16.0
        for index, polygon in enumerate(self._polygons):
            normal, plane_d, valid = _plane_for_ps2_polygon(tuple(polygon.points_ps2))
            if not valid or abs(normal.z) <= 1e-6:
                continue
            self._planes[index] = (normal, plane_d)
            min_x = min(point.x for point in polygon.points_ps2)
            max_x = max(point.x for point in polygon.points_ps2)
            min_y = min(point.y for point in polygon.points_ps2)
            max_y = max(point.y for point in polygon.points_ps2)
            self._bounds[index] = (min_x, max_x, min_y, max_y)
            for cell_x in range(math.floor(min_x / self._cell_size), math.floor(max_x / self._cell_size) + 1):
                for cell_y in range(math.floor(min_y / self._cell_size), math.floor(max_y / self._cell_size) + 1):
                    self._grid.setdefault((cell_x, cell_y), []).append(index)

    def height_at(self, x: float, y: float, query_z: float) -> float | None:
        cell_x = math.floor(x / self._cell_size)
        cell_y = math.floor(y / self._cell_size)
        best: tuple[float, float] | None = None
        for offset_x in (-1, 0, 1):
            for offset_y in (-1, 0, 1):
                for polygon_index in self._grid.get((cell_x + offset_x, cell_y + offset_y), []):
                    bounds = self._bounds[polygon_index]
                    if x < bounds[0] - 0.01 or x > bounds[1] + 0.01 or y < bounds[2] - 0.01 or y > bounds[3] + 0.01:
                        continue
                    polygon = self._polygons[polygon_index]
                    if not _point_in_convex_ps2_polygon_xy(x, y, tuple(polygon.points_ps2)):
                        continue
                    normal, plane_d = self._planes[polygon_index]
                    height = -((normal.x * x) + (normal.y * y) + plane_d) / normal.z
                    distance = abs(height - query_z)
                    if best is None or distance < best[0]:
                        best = (distance, height)
        return best[1] if best is not None else None


class _RouteHeightQuery:
    def __init__(self, segments) -> None:
        self._points: list[tuple[float, float, float]] = []
        self._grid: dict[tuple[int, int], list[int]] = {}
        self._cell_size = 24.0
        for segment in segments:
            for point in segment.points:
                index = len(self._points)
                position = point.position_ps2
                self._points.append((position.x, position.y, position.z))
                cell_x = math.floor(position.x / self._cell_size)
                cell_y = math.floor(position.y / self._cell_size)
                self._grid.setdefault((cell_x, cell_y), []).append(index)

    def query_z(self, x: float, y: float) -> float:
        if not self._points:
            return 0.0
        cell_x = math.floor(x / self._cell_size)
        cell_y = math.floor(y / self._cell_size)
        best: tuple[float, float] | None = None
        search_radius = 0
        while best is None and search_radius <= 4:
            for offset_x in range(-search_radius, search_radius + 1):
                for offset_y in range(-search_radius, search_radius + 1):
                    if abs(offset_x) != search_radius and abs(offset_y) != search_radius:
                        continue
                    for point_index in self._grid.get((cell_x + offset_x, cell_y + offset_y), []):
                        point = self._points[point_index]
                        distance_sq = (point[0] - x) * (point[0] - x) + (point[1] - y) * (point[1] - y)
                        if best is None or distance_sq < best[0]:
                            best = (distance_sq, point[2])
            search_radius += 1
        if best is not None:
            return best[1]
        nearest = min(self._points, key=lambda point: (point[0] - x) * (point[0] - x) + (point[1] - y) * (point[1] - y))
        return nearest[2]


def _wall_barrier_segments(polygons: list[TrackCollisionPolygon]) -> list[tuple[tuple[float, float], tuple[float, float]]]:
    segments: list[tuple[tuple[float, float], tuple[float, float]]] = []
    for polygon in polygons:
        if (polygon.flags & 0x02) == 0:
            continue
        unique: list[tuple[float, float]] = []
        for point in polygon.points_ps2:
            xy = (point.x, point.y)
            if not any(abs(xy[0] - current[0]) <= 1e-6 and abs(xy[1] - current[1]) <= 1e-6 for current in unique):
                unique.append(xy)
        if len(unique) == 2 and unique[0] != unique[1]:
            segments.append((unique[0], unique[1]))
    return segments


def _nearest_wall_ray_hit(
    origin: tuple[float, float],
    direction: tuple[float, float],
    segments: list[tuple[tuple[float, float], tuple[float, float]]],
    max_distance: float = 100.0,
) -> tuple[float, float] | None:
    best_distance: float | None = None
    for start, end in segments:
        distance = _ray_segment_distance(origin, direction, start, end)
        if distance is None or distance > max_distance:
            continue
        if best_distance is None or distance < best_distance:
            best_distance = distance
    if best_distance is None:
        return None
    return (origin[0] + direction[0] * best_distance, origin[1] + direction[1] * best_distance)


def _ray_segment_distance(
    origin: tuple[float, float],
    direction: tuple[float, float],
    start: tuple[float, float],
    end: tuple[float, float],
) -> float | None:
    segment = (end[0] - start[0], end[1] - start[1])
    denominator = _cross2(direction, segment)
    if abs(denominator) <= 1e-8:
        return None
    delta = (start[0] - origin[0], start[1] - origin[1])
    ray_distance = _cross2(delta, segment) / denominator
    segment_t = _cross2(delta, direction) / denominator
    if ray_distance <= 0.05 or segment_t < -1e-6 or segment_t > 1.0 + 1e-6:
        return None
    return ray_distance


def _cross2(left: tuple[float, float], right: tuple[float, float]) -> float:
    return left[0] * right[1] - left[1] * right[0]


def _point_in_convex_ps2_polygon_xy(x: float, y: float, points: tuple[Vec3, ...]) -> bool:
    sign: bool | None = None
    for index in range(len(points)):
        current = points[index]
        next_point = points[(index + 1) % len(points)]
        cross = (next_point.x - current.x) * (y - current.y) - (next_point.y - current.y) * (x - current.x)
        if abs(cross) <= 0.01:
            continue
        current_sign = cross > 0.0
        if sign is None:
            sign = current_sign
        elif sign != current_sign:
            return False
    return True


def _bounds_for_collision_polygons(polygons: list[dict[str, Any]]) -> dict[str, list[float]] | None:
    points: list[Vec3] = []
    for polygon in polygons:
        if not bool(polygon.get("valid_plane", False)):
            continue
        for point_value in polygon.get("points_ps2", []):
            if not isinstance(point_value, list) or len(point_value) < 3:
                continue
            points.append(_ps2_to_godot_vec3(Vec3(float(point_value[0]), float(point_value[1]), float(point_value[2]))))
    return _aabb(tuple(points)) if points else None


def _collision_polygon_record(polygon: TrackCollisionPolygon) -> dict[str, Any]:
    points = tuple(polygon.points_ps2)
    normal, plane_d, valid_plane = _plane_for_ps2_polygon(points)
    return {
        "source_kind": "track_polygon_collision_area",
        "source_name": f"TRACK_POLYGON_COLLISION_AREA_{polygon.index:06d}",
        "collision_role": _track_collision_polygon_role(polygon.flags),
        "drive_surface": _track_collision_polygon_contributes_to_drive_area(polygon),
        "record_index": polygon.index,
        "source_chunk_offset": polygon.source_chunk_offset,
        "source_record_offset": polygon.source_record_offset,
        "material_id": polygon.material_id,
        "flags": polygon.flags,
        "selector_byte": polygon.selector_byte,
        "vertex_count": polygon.vertex_count,
        "points_ps2": [_vec3_to_json(point) for point in points],
        "plane_normal_ps2": _vec3_to_json(normal),
        "plane_d_ps2": plane_d,
        "valid_plane": valid_plane,
        "aabb_ps2_xy": _aabb_ps2_xy(points),
    }


def _plane_for_ps2_polygon(points: tuple[Vec3, ...]) -> tuple[Vec3, float, bool]:
    if len(points) < 3:
        return Vec3(0.0, 0.0, 0.0), 0.0, False
    normal = _face_normal(points[0], points[1], points[2])
    length_sq = normal.x * normal.x + normal.y * normal.y + normal.z * normal.z
    if length_sq <= COLLISION_DEGENERATE_EPSILON:
        return Vec3(0.0, 0.0, 0.0), 0.0, False
    length = length_sq ** 0.5
    normal = Vec3(normal.x / length, normal.y / length, normal.z / length)
    if normal.z < 0.0:
        normal = Vec3(-normal.x, -normal.y, -normal.z)
    plane_d = -(normal.x * points[0].x + normal.y * points[0].y + normal.z * points[0].z)
    return normal, plane_d, True


def _aabb_ps2_xy(points: tuple[Vec3, ...]) -> dict[str, list[float]]:
    if not points:
        return {"min": [0.0, 0.0], "max": [0.0, 0.0]}
    return {
        "min": [min(point.x for point in points), min(point.y for point in points)],
        "max": [max(point.x for point in points), max(point.y for point in points)],
    }


def _append_drivable_collision_face(faces: list[Vec3], a: Vec3, b: Vec3, c: Vec3) -> bool:
    normal = _face_normal(a, b, c)
    length_sq = normal.x * normal.x + normal.y * normal.y + normal.z * normal.z
    if length_sq <= COLLISION_DEGENERATE_EPSILON:
        return False
    if normal.y < 0.0:
        b, c = c, b
        normal = _face_normal(a, b, c)
        length_sq = normal.x * normal.x + normal.y * normal.y + normal.z * normal.z
        if length_sq <= COLLISION_DEGENERATE_EPSILON:
            return False
    if normal.y * (length_sq ** -0.5) < DRIVABLE_COLLISION_MIN_NORMAL_Y:
        return False
    faces.extend((a, b, c))
    return True


def _face_normal(a: Vec3, b: Vec3, c: Vec3) -> Vec3:
    ab = Vec3(b.x - a.x, b.y - a.y, b.z - a.z)
    ac = Vec3(c.x - a.x, c.y - a.y, c.z - a.z)
    return Vec3(
        ab.y * ac.z - ab.z * ac.y,
        ab.z * ac.x - ab.x * ac.z,
        ab.x * ac.y - ab.y * ac.x,
    )


def _track_collision_polygon_contributes_to_drive_area(polygon: TrackCollisionPolygon) -> bool:
    return (polygon.flags & 0x0A) == 0


def _track_collision_polygon_role(flags: int) -> str:
    if (flags & 0x02) != 0:
        return "wall_barrier"
    if (flags & 0x08) != 0:
        return "secondary_collision"
    return "road_surface"


def _drive_area_boundary_lines(polygons: list[TrackCollisionPolygon]) -> list[Vec3]:
    edges: list[dict[str, Any]] = []
    polygon_infos: list[dict[str, Any]] = []
    polygon_grid: dict[str, list[int]] = {}
    for polygon in polygons:
        if not _track_collision_polygon_contributes_to_drive_area(polygon):
            continue
        points = tuple(_ps2_to_godot_vec3(point) for point in polygon.points_ps2)
        if len(points) < 3:
            continue
        projected = tuple((point.x, point.z) for point in points)
        owner_index = len(polygon_infos)
        info = _projected_polygon_info(projected)
        polygon_infos.append(info)
        _index_projected_polygon(polygon_grid, info, owner_index)
        for index in range(len(points)):
            _append_projected_boundary_edge(edges, points[index], points[(index + 1) % len(points)], owner_index)

    return _projected_boundary_lines_from_split_edges(edges, polygon_infos, polygon_grid)


def _drive_area_boundary_segments(polygons: list[TrackCollisionPolygon]) -> list[dict[str, Any]]:
    edges: list[dict[str, Any]] = []
    polygon_infos: list[dict[str, Any]] = []
    polygon_grid: dict[str, list[int]] = {}
    for polygon in polygons:
        if not _track_collision_polygon_contributes_to_drive_area(polygon):
            continue
        points = tuple(_ps2_to_godot_vec3(point) for point in polygon.points_ps2)
        if len(points) < 3:
            continue
        projected = tuple((point.x, point.z) for point in points)
        owner_index = len(polygon_infos)
        info = _projected_polygon_info(projected)
        polygon_infos.append(info)
        _index_projected_polygon(polygon_grid, info, owner_index)
        for index in range(len(points)):
            _append_projected_boundary_edge(edges, points[index], points[(index + 1) % len(points)], owner_index)
    return _projected_boundary_segments_from_split_edges(edges, polygon_infos, polygon_grid)


def _append_projected_boundary_edge(edges: list[dict[str, Any]], a: Vec3, b: Vec3, owner_index: int) -> None:
    qa = _projected_boundary_point_key(a)
    qb = _projected_boundary_point_key(b)
    if qa == qb:
        return
    dx = qb[0] - qa[0]
    dy = qb[1] - qa[1]
    divisor = math.gcd(abs(dx), abs(dy))
    if divisor <= 0:
        return
    dir_x = dx // divisor
    dir_y = dy // divisor
    if dir_x < 0 or (dir_x == 0 and dir_y < 0):
        dir_x = -dir_x
        dir_y = -dir_y
    ta = qa[0] * dir_x + qa[1] * dir_y
    tb = qb[0] * dir_x + qb[1] * dir_y
    if ta == tb:
        return
    normal_x = -dir_y
    normal_y = dir_x
    line_offset = normal_x * qa[0] + normal_y * qa[1]
    edges.append(
        {
            "a": a,
            "b": b,
            "ta": ta,
            "tb": tb,
            "start": min(ta, tb),
            "end": max(ta, tb),
            "line_key": f"{dir_x},{dir_y},{line_offset}",
            "owner": owner_index,
        }
    )


def _quantized_boundary_point_key(point: Vec3) -> str:
    return ",".join(
        str(round(component * BOUNDARY_POINT_QUANTIZE))
        for component in (point.x, point.y, point.z)
    )


def _projected_boundary_point_key(point: Vec3) -> tuple[int, int]:
    return (
        round(point.x * BOUNDARY_POINT_QUANTIZE),
        round(point.z * BOUNDARY_POINT_QUANTIZE),
    )


def _projected_boundary_lines_from_split_edges(
    edges: list[dict[str, Any]],
    polygon_infos: list[dict[str, Any]],
    polygon_grid: dict[str, list[int]],
) -> list[Vec3]:
    by_line: dict[str, list[dict[str, Any]]] = {}
    for edge in edges:
        line_key = str(edge.get("line_key", ""))
        if not line_key:
            continue
        by_line.setdefault(line_key, []).append(edge)

    lines: list[Vec3] = []
    for line_edges in by_line.values():
        cuts = sorted({int(edge["start"]) for edge in line_edges} | {int(edge["end"]) for edge in line_edges})
        for cut_index in range(len(cuts) - 1):
            segment_start = cuts[cut_index]
            segment_end = cuts[cut_index + 1]
            if segment_start == segment_end:
                continue
            covering_edge: dict[str, Any] | None = None
            covering_count = 0
            for edge in line_edges:
                if int(edge["start"]) <= segment_start and segment_end <= int(edge["end"]):
                    covering_count += 1
                    covering_edge = edge
                    if covering_count > 1:
                        break
            if covering_count != 1 or covering_edge is None:
                continue
            point_a = _point_on_projected_edge(covering_edge, segment_start)
            point_b = _point_on_projected_edge(covering_edge, segment_end)
            if _projected_segment_is_covered_by_another_polygon(
                point_a,
                point_b,
                int(covering_edge.get("owner", -1)),
                polygon_infos,
                polygon_grid,
            ):
                continue
            lines.extend((point_a, point_b))
    return lines


def _projected_boundary_segments_from_split_edges(
    edges: list[dict[str, Any]],
    polygon_infos: list[dict[str, Any]],
    polygon_grid: dict[str, list[int]],
) -> list[dict[str, Any]]:
    by_line: dict[str, list[dict[str, Any]]] = {}
    for edge in edges:
        line_key = str(edge.get("line_key", ""))
        if not line_key:
            continue
        by_line.setdefault(line_key, []).append(edge)

    segments: list[dict[str, Any]] = []
    for line_edges in by_line.values():
        cuts = sorted({int(edge["start"]) for edge in line_edges} | {int(edge["end"]) for edge in line_edges})
        for cut_index in range(len(cuts) - 1):
            segment_start = cuts[cut_index]
            segment_end = cuts[cut_index + 1]
            if segment_start == segment_end:
                continue
            covering_edge: dict[str, Any] | None = None
            covering_count = 0
            for edge in line_edges:
                if int(edge["start"]) <= segment_start and segment_end <= int(edge["end"]):
                    covering_count += 1
                    covering_edge = edge
                    if covering_count > 1:
                        break
            if covering_count != 1 or covering_edge is None:
                continue
            point_a = _point_on_projected_edge(covering_edge, segment_start)
            point_b = _point_on_projected_edge(covering_edge, segment_end)
            owner_index = int(covering_edge.get("owner", -1))
            if _projected_segment_is_covered_by_another_polygon(point_a, point_b, owner_index, polygon_infos, polygon_grid):
                continue
            inward_normal = _projected_boundary_segment_inward_normal(point_a, point_b, owner_index, polygon_infos)
            if inward_normal is None:
                continue
            min_x = min(point_a.x, point_b.x)
            min_z = min(point_a.z, point_b.z)
            max_x = max(point_a.x, point_b.x)
            max_z = max(point_a.z, point_b.z)
            segments.append(
                {
                    "segment_index": len(segments),
                    "a_xz": [point_a.x, point_a.z],
                    "b_xz": [point_b.x, point_b.z],
                    "inward_normal_xz": [inward_normal[0], inward_normal[1]],
                    "aabb_xz": {
                        "min": [min_x, min_z],
                        "max": [max_x, max_z],
                    },
                }
            )
    return segments


def _projected_boundary_segment_inward_normal(
    a: Vec3,
    b: Vec3,
    owner_index: int,
    polygon_infos: list[dict[str, Any]],
) -> tuple[float, float] | None:
    if owner_index < 0 or owner_index >= len(polygon_infos):
        return None
    dx = b.x - a.x
    dz = b.z - a.z
    length = math.hypot(dx, dz)
    if length <= 1e-6:
        return None
    left_normal = (-dz / length, dx / length)
    midpoint = ((a.x + b.x) * 0.5, (a.z + b.z) * 0.5)
    polygon = polygon_infos[owner_index]["points"]
    left_sample = (
        midpoint[0] + left_normal[0] * BOUNDARY_SAMPLE_OFFSET,
        midpoint[1] + left_normal[1] * BOUNDARY_SAMPLE_OFFSET,
    )
    right_normal = (-left_normal[0], -left_normal[1])
    right_sample = (
        midpoint[0] + right_normal[0] * BOUNDARY_SAMPLE_OFFSET,
        midpoint[1] + right_normal[1] * BOUNDARY_SAMPLE_OFFSET,
    )
    left_inside = _point_in_polygon_2d(left_sample, polygon) or _projected_point_on_polygon_edge(left_sample, polygon)
    right_inside = _point_in_polygon_2d(right_sample, polygon) or _projected_point_on_polygon_edge(right_sample, polygon)
    if left_inside and not right_inside:
        return left_normal
    if right_inside and not left_inside:
        return right_normal
    centroid_x = sum(point[0] for point in polygon) / len(polygon)
    centroid_z = sum(point[1] for point in polygon) / len(polygon)
    centroid_delta = (centroid_x - midpoint[0], centroid_z - midpoint[1])
    if centroid_delta[0] * left_normal[0] + centroid_delta[1] * left_normal[1] >= 0.0:
        return left_normal
    return right_normal


def _projected_segment_is_covered_by_another_polygon(
    a: Vec3,
    b: Vec3,
    owner_index: int,
    polygon_infos: list[dict[str, Any]],
    polygon_grid: dict[str, list[int]],
) -> bool:
    samples = (
        _lerp_vec3(a, b, 0.25),
        _lerp_vec3(a, b, 0.5),
        _lerp_vec3(a, b, 0.75),
    )
    for sample in samples:
        point_2d = (sample.x, sample.z)
        key = _projected_polygon_grid_key(
            math.floor(point_2d[0] / DRIVE_AREA_POLYGON_GRID_SIZE),
            math.floor(point_2d[1] / DRIVE_AREA_POLYGON_GRID_SIZE),
        )
        for candidate_index in polygon_grid.get(key, []):
            if candidate_index == owner_index or candidate_index < 0 or candidate_index >= len(polygon_infos):
                continue
            info = polygon_infos[candidate_index]
            if not _projected_point_in_bounds(point_2d, info):
                continue
            polygon = info["points"]
            if _point_in_polygon_2d(point_2d, polygon) or _projected_point_on_polygon_edge(point_2d, polygon):
                return True
    return False


def _point_on_projected_edge(edge: dict[str, Any], t: int) -> Vec3:
    ta = float(edge["ta"])
    tb = float(edge["tb"])
    denom = tb - ta
    if abs(denom) <= 1e-6:
        return edge["a"]
    alpha = max(0.0, min(1.0, (float(t) - ta) / denom))
    return _lerp_vec3(edge["a"], edge["b"], alpha)


def _lerp_vec3(a: Vec3, b: Vec3, alpha: float) -> Vec3:
    return Vec3(
        a.x + (b.x - a.x) * alpha,
        a.y + (b.y - a.y) * alpha,
        a.z + (b.z - a.z) * alpha,
    )


def _projected_polygon_info(polygon: tuple[tuple[float, float], ...]) -> dict[str, Any]:
    xs = [point[0] for point in polygon]
    ys = [point[1] for point in polygon]
    return {
        "points": polygon,
        "min_x": min(xs),
        "max_x": max(xs),
        "min_y": min(ys),
        "max_y": max(ys),
    }


def _index_projected_polygon(polygon_grid: dict[str, list[int]], info: dict[str, Any], owner_index: int) -> None:
    min_cell_x = math.floor(float(info["min_x"]) / DRIVE_AREA_POLYGON_GRID_SIZE)
    max_cell_x = math.floor(float(info["max_x"]) / DRIVE_AREA_POLYGON_GRID_SIZE)
    min_cell_y = math.floor(float(info["min_y"]) / DRIVE_AREA_POLYGON_GRID_SIZE)
    max_cell_y = math.floor(float(info["max_y"]) / DRIVE_AREA_POLYGON_GRID_SIZE)
    for cell_x in range(min_cell_x, max_cell_x + 1):
        for cell_y in range(min_cell_y, max_cell_y + 1):
            key = _projected_polygon_grid_key(cell_x, cell_y)
            polygon_grid.setdefault(key, []).append(owner_index)


def _projected_polygon_grid_key(cell_x: int, cell_y: int) -> str:
    return f"{cell_x}:{cell_y}"


def _projected_point_in_bounds(point: tuple[float, float], info: dict[str, Any]) -> bool:
    return (
        point[0] >= float(info["min_x"]) - DRIVE_AREA_POLYGON_EDGE_EPSILON
        and point[0] <= float(info["max_x"]) + DRIVE_AREA_POLYGON_EDGE_EPSILON
        and point[1] >= float(info["min_y"]) - DRIVE_AREA_POLYGON_EDGE_EPSILON
        and point[1] <= float(info["max_y"]) + DRIVE_AREA_POLYGON_EDGE_EPSILON
    )


def _projected_point_on_polygon_edge(point: tuple[float, float], polygon: tuple[tuple[float, float], ...]) -> bool:
    max_distance_sq = DRIVE_AREA_POLYGON_EDGE_EPSILON * DRIVE_AREA_POLYGON_EDGE_EPSILON
    for index in range(len(polygon)):
        if _point_segment_distance_squared_2d(point, polygon[index], polygon[(index + 1) % len(polygon)]) <= max_distance_sq:
            return True
    return False


def _point_segment_distance_squared_2d(
    point: tuple[float, float],
    a: tuple[float, float],
    b: tuple[float, float],
) -> float:
    ab_x = b[0] - a[0]
    ab_y = b[1] - a[1]
    length_sq = ab_x * ab_x + ab_y * ab_y
    if length_sq <= 1e-6:
        dx = point[0] - a[0]
        dy = point[1] - a[1]
        return dx * dx + dy * dy
    t = ((point[0] - a[0]) * ab_x + (point[1] - a[1]) * ab_y) / length_sq
    t = max(0.0, min(1.0, t))
    closest_x = a[0] + ab_x * t
    closest_y = a[1] + ab_y * t
    dx = point[0] - closest_x
    dy = point[1] - closest_y
    return dx * dx + dy * dy


def _point_in_polygon_2d(point: tuple[float, float], polygon: tuple[tuple[float, float], ...]) -> bool:
    inside = False
    x, y = point
    for index in range(len(polygon)):
        ax, ay = polygon[index]
        bx, by = polygon[(index + 1) % len(polygon)]
        intersects = ((ay > y) != (by > y)) and (
            x < (bx - ax) * (y - ay) / ((by - ay) if abs(by - ay) > 1e-12 else 1e-12) + ax
        )
        if intersects:
            inside = not inside
    return inside


def _sub_vec3(left: Vec3, right: Vec3) -> Vec3:
    return Vec3(left.x - right.x, left.y - right.y, left.z - right.z)


def _object_pivot(obj: MeshObject) -> Vec3:
    mins: list[float] | None = None
    maxs: list[float] | None = None
    for block in obj.blocks:
        for vertex in block.run.vertices:
            if mins is None:
                mins = [vertex.x, vertex.y, vertex.z]
                maxs = [vertex.x, vertex.y, vertex.z]
                continue
            mins[0] = min(mins[0], vertex.x)
            mins[1] = min(mins[1], vertex.y)
            mins[2] = min(mins[2], vertex.z)
            maxs[0] = max(maxs[0], vertex.x)
            maxs[1] = max(maxs[1], vertex.y)
            maxs[2] = max(maxs[2], vertex.z)
    if mins is None or maxs is None:
        return Vec3(0.0, 0.0, 0.0)
    return Vec3(
        (mins[0] + maxs[0]) * 0.5,
        (mins[1] + maxs[1]) * 0.5,
        (mins[2] + maxs[2]) * 0.5,
    )


def _transform_with_pivot(transform: Matrix4, pivot: Vec3) -> Matrix4:
    if pivot.x == 0.0 and pivot.y == 0.0 and pivot.z == 0.0:
        return transform
    return compose_matrix4(_translation_matrix(pivot), transform)


def _translation_matrix(offset: Vec3) -> Matrix4:
    return (
        (1.0, 0.0, 0.0, 0.0),
        (0.0, 1.0, 0.0, 0.0),
        (0.0, 0.0, 1.0, 0.0),
        (offset.x, offset.y, offset.z, 1.0),
    )


def _should_export_colors(block: DecodedBlock, mode: str) -> bool:
    if mode == "off":
        return False
    return True


def _ps2_to_godot_vec3(vertex: Vec3) -> Vec3:
    return Vec3(vertex.x, vertex.z, -vertex.y)


def _matrix_to_json(matrix: Matrix4) -> list[list[float]]:
    return [[float(value) for value in row] for row in matrix]


def _vec3_to_json(value: Vec3) -> list[float]:
    return [float(value.x), float(value.y), float(value.z)]


def _aabb(vertices: tuple[Vec3, ...]) -> dict[str, list[float]]:
    return {
        "min": [min(v.x for v in vertices), min(v.y for v in vertices), min(v.z for v in vertices)],
        "max": [max(v.x for v in vertices), max(v.y for v in vertices), max(v.z for v in vertices)],
    }


def _aabb_for_surfaces(surfaces: list[dict[str, Any]]) -> dict[str, list[float]]:
    mins = [surface["aabb"]["min"] for surface in surfaces]
    maxs = [surface["aabb"]["max"] for surface in surfaces]
    return {
        "min": [min(value[index] for value in mins) for index in range(3)],
        "max": [max(value[index] for value in maxs) for index in range(3)],
    }


def _object_pack_info(scene: Scene) -> dict[int, dict[str, Any]]:
    out: dict[int, dict[str, Any]] = {}
    for pack in scene.solid_packs:
        role = "TEMPLATE_PALETTE" if pack.is_scenery_template_palette else "STATIC_SOLID_PACK"
        for offset in pack.object_chunk_offsets:
            out[offset] = {
                "solid_pack_index": pack.index,
                "solid_pack_offset": pack.source_chunk_offset,
                "is_scenery_template": pack.is_scenery_template_palette,
                "source_role": role,
            }
    return out


def _source_role(info: dict[str, Any]) -> str:
    return str(info.get("source_role", "UNKNOWN"))


def _category_for_object(obj: MeshObject, surfaces: list[dict[str, Any]], is_scenery_template: bool, textures: TextureLibrary) -> str:
    name = obj.name.upper()
    if name.startswith("SKYDOME") or name == "WATER" or "ENVMAP" in name:
        return "ENVIRONMENT"
    if name.startswith("TRACK") and "STARTLINE" in name:
        return "TRACK_MARKER"
    if name.startswith("RD_") or name.startswith("DIRTRD_"):
        return "ROAD"
    if name.startswith("TRN_"):
        return "TERRAIN"
    if name.startswith("SHD_") or name.startswith("SH_") or "SHAD" in name:
        return "SHADOW"
    if _surfaces_use_only_shadow_textures(surfaces, textures):
        return "SHADOW"
    if "BRIDGE" in name or name == "MARTINSPEAK":
        return "LANDMARK"
    if is_scenery_template:
        return "PROP"
    if name.startswith(("XS_", "XT_", "XW_", "XB_", "XH_", "XF_")):
        return "PROP"
    return "STATIC_DETAIL"


def _surfaces_use_only_shadow_textures(surfaces: list[dict[str, Any]], textures: TextureLibrary) -> bool:
    found = False
    for surface in surfaces:
        texture = textures.get(surface.get("texture_hash"))
        if texture is None or not texture.name:
            return False
        found = True
        if "SHAD" not in texture.name.upper():
            return False
    return found


def _material_key(texture_hash: int | None, object_name: str, render_flag: int | None) -> str:
    safe_name = _safe_filename(object_name).lower()
    return f"{texture_hash or 0:08x}:{safe_name}:{render_flag or 0:04x}"


def _material_record(
    key: str,
    texture_hash: int | None,
    texture: Texture | None,
    object_name: str,
    render_flag: int | None,
    usage_flags: frozenset[int | None] | tuple[int | None, ...] = (),
) -> dict[str, Any]:
    decision = decide_material_alpha(texture, render_flag, usage_flags)
    alpha_mode = "" if decision.mode == "OPAQUE" else decision.mode
    alpha_cutoff = decision.cutoff if decision.cutoff is not None else 0.5
    return {
        "key": key,
        "name": texture.name if texture is not None else "default",
        "texture_hash": texture_hash or 0,
        "unshaded": True,
        "vertex_color_use_as_albedo": True,
        "alpha_mode": alpha_mode,
        "source_alpha_mode": texture.alpha_mode if texture is not None and texture.alpha_mode is not None else "",
        "alpha_cutoff": alpha_cutoff,
        "alpha_reason": decision.reason,
        "render_flag": render_flag or 0,
        "object_name": object_name,
        "is_any_semitransparency": texture.is_any_semitransparency or 0 if texture is not None else 0,
        "alpha_bits": texture.alpha_bits or 0 if texture is not None else 0,
        "alpha_fix": texture.alpha_fix or 0 if texture is not None else 0,
    }


def _write_textures(texture_dir: Path, textures: TextureLibrary, referenced_hashes: set[int]) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for texture_hash in sorted(referenced_hashes):
        texture = textures.get(texture_hash)
        if texture is None:
            continue
        rel_path = Path("textures") / f"{texture_hash:08x}_{_safe_filename(texture.name)}.png"
        (texture_dir.parent / rel_path).write_bytes(texture.png)
        records.append(
            {
                "hash": texture_hash,
                "name": texture.name,
                "path": rel_path.as_posix(),
                "width": texture.width,
                "height": texture.height,
                "has_alpha": texture.has_alpha,
                "alpha_mode": texture.alpha_mode or "",
                "alpha_cutoff": texture.alpha_cutoff or 0.5,
                "is_any_semitransparency": texture.is_any_semitransparency or 0,
                "alpha_bits": texture.alpha_bits or 0,
                "alpha_fix": texture.alpha_fix or 0,
            }
        )
    return records


def _safe_filename(value: str) -> str:
    out = re.sub(r"[^A-Za-z0-9_.-]+", "_", value.strip())
    return out or "texture"


def _solid_packs_to_json(scene: Scene) -> list[dict[str, Any]]:
    return [
        {
            "index": pack.index,
            "source_chunk_offset": pack.source_chunk_offset,
            "is_scenery_template_palette": pack.is_scenery_template_palette,
            "object_chunk_offsets": list(pack.object_chunk_offsets),
        }
        for pack in scene.solid_packs
    ]


def _scenery_sections_to_json(scene: Scene) -> list[dict[str, Any]]:
    return [
        {
            "section_index": section.section_index,
            "section_number": section.section_index,
            "source_chunk_offset": section.source_chunk_offset,
            "info_table": [list(row) for row in section.info_table],
            "instance_record_indices": [instance.record_index for instance in section.instances],
        }
        for section in scene.scenery_sections
    ]


def _scenery_instances_to_json(scene: Scene, pivots_by_object_index: dict[int, Vec3]) -> list[dict[str, Any]]:
    return [
        {
            "object_index": instance.object_index,
            "object_name": instance.object_name,
            "transform": _matrix_to_json(
                _transform_with_pivot(
                    instance.transform,
                    pivots_by_object_index.get(instance.object_index, Vec3(0.0, 0.0, 0.0)),
                )
            ),
            "source_chunk_offset": instance.source_chunk_offset,
            "record_index": instance.record_index,
            "section_index": instance.section_index if instance.section_index is not None else -1,
            "section_number": instance.section_index if instance.section_index is not None else -1,
            "section_chunk_offset": instance.section_chunk_offset if instance.section_chunk_offset is not None else -1,
            "scenery_info_index": instance.scenery_info_index if instance.scenery_info_index is not None else -1,
            "object_hash": instance.object_hash or 0,
        }
        for instance in scene.scenery_instances
    ]


def _track_id_from_name(track_name: str) -> str:
    match = re.search(r"(\d+)$", track_name)
    return match.group(1) if match else track_name
