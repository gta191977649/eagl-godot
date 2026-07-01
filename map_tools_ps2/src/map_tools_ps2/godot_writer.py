from __future__ import annotations

import json
import re
import shutil
import struct
from pathlib import Path
from typing import Any

from .binary import Matrix4, Vec3, compose_matrix4, transform_point
from .glb_writer import _decode_vif_color_5551, _indices_for_block, _texture_hash_for_run
from .model import DecodedBlock, MeshObject, Scene, TrackCollisionPolygon
from .textures import Texture, TextureLibrary


FORMAT_VERSION = 2
DRIVABLE_COLLISION_MIN_NORMAL_Y = 0.1
COLLISION_DEGENERATE_EPSILON = 1e-12


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
        material = _material_record(material_key, texture_hash, textures.get(texture_hash), obj.name, block.render_flag)
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
    exported_faces: list[Vec3] = []
    triangle_count = 0
    candidate_triangle_count = 0
    filtered_triangle_count = 0

    for polygon in scene.track_collision_polygons:
        if not _track_collision_polygon_contributes_to_drive_area(polygon):
            continue
        faces, candidate_count, filtered_count = _collision_faces_for_polygon(polygon)
        candidate_triangle_count += candidate_count
        filtered_triangle_count += filtered_count
        if not faces:
            continue
        face_spec = binary.add(_pack_vec3(tuple(faces)), stride=12, kind="float32_vec3")
        line_spec = binary.add(b"", stride=12, kind="float32_vec3")
        surface_triangle_count = len(faces) // 3
        triangle_count += surface_triangle_count
        exported_faces.extend(faces)
        surfaces.append(
            {
                "category": "Road",
                "debug_only": False,
                "triangle_count": surface_triangle_count,
                "candidate_triangle_count": candidate_count,
                "valid_triangle_count": surface_triangle_count,
                "filtered_triangle_count": filtered_count,
                "aabb": _aabb(tuple(faces)),
                "faces": face_spec,
                "debug_lines": line_spec,
                "source_kind": "track_polygon_collision_area",
                "source_name": f"TRACK_POLYGON_COLLISION_AREA_{polygon.index:06d}",
                "source_chunk_offset": polygon.source_chunk_offset,
                "source_record_offset": polygon.source_record_offset,
                "record_index": polygon.index,
            }
        )

    return {
        "version": 1,
        "stats": {
            "enabled": bool(surfaces),
            "surface_count": len(surfaces),
            "triangle_count": triangle_count,
            "valid_triangle_count": triangle_count,
            "candidate_triangle_count": candidate_triangle_count,
            "filtered_triangle_count": filtered_triangle_count,
            "bounds": _aabb(tuple(exported_faces)) if exported_faces else None,
            "track_collision_polygon_count": len(scene.track_collision_polygons),
            "track_collision_drive_area_polygon_count": sum(
                1 for polygon in scene.track_collision_polygons if _track_collision_polygon_contributes_to_drive_area(polygon)
            ),
            "track_route_segment_count": len(scene.track_route_segments),
            "track_route_edge_count": len(scene.track_route_edges),
            "allowed_road_area_count": len(scene.allowed_road_areas),
            "collision_source": "track_collision_polygons",
        },
        "surfaces": surfaces,
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
) -> dict[str, Any]:
    alpha_mode = texture.alpha_mode if texture is not None and texture.alpha_mode is not None else ""
    alpha_cutoff = texture.alpha_cutoff if texture is not None and texture.alpha_cutoff is not None else 0.5
    if texture is not None and _should_force_opaque_road_edge(object_name, texture, render_flag):
        alpha_mode = ""
        alpha_cutoff = 0.5
    return {
        "key": key,
        "name": texture.name if texture is not None else "default",
        "texture_hash": texture_hash or 0,
        "unshaded": True,
        "vertex_color_use_as_albedo": True,
        "alpha_mode": alpha_mode,
        "source_alpha_mode": texture.alpha_mode if texture is not None and texture.alpha_mode is not None else "",
        "alpha_cutoff": alpha_cutoff,
        "render_flag": render_flag or 0,
        "object_name": object_name,
        "is_any_semitransparency": texture.is_any_semitransparency or 0 if texture is not None else 0,
        "alpha_bits": texture.alpha_bits or 0 if texture is not None else 0,
        "alpha_fix": texture.alpha_fix or 0 if texture is not None else 0,
    }


def _should_force_opaque_road_edge(object_name: str, texture: Texture, render_flag: int | None) -> bool:
    if texture.alpha_mode is None:
        return False
    if texture.is_any_semitransparency:
        return False
    if render_flag in {0x4041, 0xC180}:
        return True

    object_name_upper = object_name.upper()
    if object_name_upper.startswith(("RD_", "RDDRT_", "DIRTRD_", "TRN_")):
        return True

    texture_name = texture.name.upper()
    return texture_name.startswith(
        ("ROAD", "W_ROAD", "T_ROAD", "T_DIRTRD", "SHLD_", "D_TERRAIN", "A_DIRT")
    )


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
