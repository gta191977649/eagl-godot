from __future__ import annotations

import hashlib
import json
import math
import re
import statistics
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

from shapely.geometry import GeometryCollection, LineString, MultiLineString, MultiPolygon, Polygon, box
from shapely.ops import unary_union

from .binary import Matrix4, Vec3, transform_point
from .glb_writer import _decode_vif_color_5551, _indices_for_block
from .material_alpha import MaterialAlphaDecision, alpha_decisions_for_scene, alpha_diagnostics, decide_material_alpha
from .model import MeshObject, Scene, SceneryInstance, TrackCollisionPolygon, transformed_block_vertices
from .progress import report_progress


@dataclass(frozen=True)
class MtaMaterial:
    texture_hash: int | None
    texture_name: str | None
    alpha: bool = False
    alpha_mode: str = "OPAQUE"
    alpha_cutoff: float | None = None
    alpha_reason: str = "opaque_pixels"
    render_flag: int | None = None


@dataclass
class MtaModel:
    model_id: str
    source_name: str
    kind: str
    zone: str
    origin: tuple[float, float, float]
    vertices: list[tuple[float, float, float]] = field(default_factory=list)
    faces: list[tuple[int, int, int]] = field(default_factory=list)
    uvs: list[tuple[float, float]] = field(default_factory=list)
    colors: list[tuple[int, int, int, int]] = field(default_factory=list)
    face_materials: list[int] = field(default_factory=list)
    materials: list[MtaMaterial] = field(default_factory=list)
    collision_vertices: list[tuple[float, float, float]] = field(default_factory=list)
    collision_faces: list[tuple[int, int, int]] = field(default_factory=list)
    collision_materials: list[int] = field(default_factory=list)
    collision_kind: str = "bounds"
    lod_distance: float = 299.0
    render_layer: str = "base"
    draw_last: bool = False
    additive: bool = False
    no_zbuffer_write: bool = False
    is_lod: bool = False
    lod_source_id: str | None = None
    lod_target_ratio: float = 0.12


@dataclass(frozen=True)
class MtaPlacement:
    model_id: str
    zone: str
    element_type: str
    position: tuple[float, float, float]
    rotation: tuple[float, float, float]
    source_name: str
    lod_parent: str | None = None
    unique_id: str | None = None


@dataclass(frozen=True)
class MtaWaterQuad:
    corners: tuple[
        tuple[float, float, float],
        tuple[float, float, float],
        tuple[float, float, float],
        tuple[float, float, float],
    ]
    water_type: int = 1


@dataclass
class MtaScene:
    track_id: int
    resource_name: str
    models: list[MtaModel]
    placements: list[MtaPlacement]
    zones: list[str]
    texture_names: dict[int, str]
    warnings: list[str]
    report: dict[str, Any]
    water_quads: list[MtaWaterQuad] = field(default_factory=list)
    texture_variants: dict[tuple[int, str], str] = field(default_factory=dict)


@dataclass(frozen=True)
class _Vertex:
    position: tuple[float, float, float]
    uv: tuple[float, float]
    color: tuple[int, int, int, int]


@dataclass(frozen=True)
class _Triangle:
    vertices: tuple[_Vertex, _Vertex, _Vertex]
    texture_hash: int | None
    render_flag: int | None = None


_VEGETATION_RE = re.compile(r"BUSH|TREE|CONIFER|VINE|GRASS|LEAF|FOLIAGE", re.IGNORECASE)
_SMALL_VEGETATION_RE = re.compile(r"^(?:XT_).*(?:GRASS|BUSH|FERN|FLOWER|LEAF|WEED)", re.IGNORECASE)
_SKY_RE = re.compile(r"SKYDOME", re.IGNORECASE)
_MTA_WATER_WORLD_MIN = -3000.0
_MTA_WATER_WORLD_MAX = 3000.0
_MTA_WATER_SAFE_QUAD_BUDGET = 120
_MTA_WATER_BAND_HEIGHTS = (50.0, 60.0, 70.0, 80.0, 90.0, 100.0, 102.0, 104.0, 108.0, 120.0, 160.0, 200.0)
_MTA_WATER_MIN_FRAGMENT_AREA = 16.0
_MTA_WATER_EDGE_PADDING = 8.0
_MTA_WATER_SNAP_GRID = 0.0
_MTA_WATER_BOUNDARY_TOLERANCE = 1.0


def _is_water_model(name: str) -> bool:
    return name.strip().upper() == "WATER"


def _is_sky_model(name: str) -> bool:
    return bool(_SKY_RE.search(name))


def _is_mta_visual_excluded(name: str) -> bool:
    return _is_water_model(name) or _is_sky_model(name)


def _lod_special_reason(name: str) -> str | None:
    upper = name.strip().upper()
    if upper == "WATER":
        return "water"
    if "SKYDOME" in upper:
        return "sky"
    if upper.startswith("SHD_") or "SHADOW" in upper or upper.startswith("TIRESHADS"):
        return "shadow_or_effect"
    if upper == "TRACK_HELICOPTER":
        return "special_vehicle"
    return None


def _lod_decision(
    name: str,
    triangles: list[_Triangle],
    placement_count: int,
    *,
    lod_min_size: float,
    small_size: float,
    small_diagonal: float,
    min_triangles: int,
    repeated_triangles: int,
    repeated_count: int,
    road: bool = False,
) -> dict[str, Any]:
    extent = _triangle_extent(triangles)
    maximum = max(extent, default=0.0)
    diagonal = math.sqrt(sum(value * value for value in extent))
    triangle_count = len(triangles)
    special_reason = _lod_special_reason(name)
    if special_reason:
        category = "special"
        decision, reason = "skip", special_reason
    elif road:
        category = "road"
        decision = "candidate" if maximum >= lod_min_size else "skip"
        reason = "road_size_threshold" if decision == "candidate" else "below_lod_min_size"
    elif _SMALL_VEGETATION_RE.search(name) and maximum < lod_min_size:
        category = "small_vegetation"
        decision, reason = "skip", "below_small_vegetation_size"
    elif maximum < small_size or diagonal < small_diagonal:
        category = "small_prop"
        decision, reason = "skip", "below_small_geometry_threshold"
    elif _VEGETATION_RE.search(name) and maximum >= small_size and triangle_count >= min_triangles:
        category = "vegetation"
        decision, reason = "candidate", "large_vegetation"
    elif triangle_count < min_triangles:
        category = "low_complexity"
        decision, reason = "skip", "below_min_triangles"
    elif (
        maximum >= lod_min_size
        or diagonal >= max(140.0, small_diagonal)
        or (triangle_count >= 1000 and maximum >= small_size)
        or (placement_count >= repeated_count and triangle_count >= repeated_triangles)
    ):
        category = "prop"
        decision, reason = "candidate", "geometry_or_reuse_threshold"
    else:
        category = "low_complexity"
        decision, reason = "skip", "below_candidate_thresholds"
    return {
        "source": name,
        "category": category,
        "decision": decision,
        "reason": reason,
        "extent": list(extent),
        "diagonal": diagonal,
        "triangles": triangle_count,
        "placement_count": placement_count,
    }


def _deduplicate_scenery_instances(
    instances: Iterable[SceneryInstance],
) -> tuple[list[SceneryInstance], dict[str, Any]]:
    """Remove exact HP2 streaming-section overlaps for the flattened MTA scene.

    HP2 can repeat the same placement in multiple scenery sections because those
    sections are streamed independently. MTA loads the exported scene globally,
    so retaining every section copy renders the same model multiple times.

    Keep this deliberately exact: two records are duplicates only when their
    resolved model name and complete source transform are identical. The
    original Scene and its section metadata are never modified.
    """
    unique: list[SceneryInstance] = []
    occurrences: Counter[tuple[str, Matrix4]] = Counter()
    for instance in instances:
        # MTA templates are resolved by object_name. Some overlapping HP2
        # section records carry different object_hash metadata even though they
        # resolve to the same named template and exact transform.
        key = (instance.object_name, instance.transform)
        occurrences[key] += 1
        if occurrences[key] == 1:
            unique.append(instance)

    duplicate_counts = [count for count in occurrences.values() if count > 1]
    return unique, {
        "unique_source_placements": len(unique),
        "duplicate_placement_groups": len(duplicate_counts),
        "duplicate_placements_removed": sum(count - 1 for count in duplicate_counts),
        "max_duplicate_placement_multiplicity": max(duplicate_counts, default=1),
    }


def zone_name(track_id: int, cell: tuple[int, int]) -> str:
    return f"t{track_id:02d}_x{cell[0]:+04d}_y{cell[1]:+04d}".replace("+", "p").replace("-", "m")


def cell_for_xy(x: float, y: float, chunk_size: float) -> tuple[int, int]:
    return (math.floor(x / chunk_size), math.floor(y / chunk_size))


def _texture_name(name: str, tex_hash: int, used: set[str]) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9_]", "_", name).strip("_") or f"tex_{tex_hash:08x}"
    cleaned = cleaned[:31]
    candidate = cleaned
    if candidate.lower() in used:
        suffix = f"_{tex_hash:08x}"
        candidate = cleaned[: 31 - len(suffix)] + suffix
    used.add(candidate.lower())
    return candidate


def _model_id(track_id: int, category: str, token: str, variant: int = 0) -> str:
    digest = hashlib.blake2s(token.encode("utf-8"), digest_size=4).hexdigest()
    value = f"t{track_id:02d}_{category}_{digest}"
    if variant:
        value += f"_{variant:02d}"
    return value[:20]


def _unique_id(token: str) -> str:
    return str(int.from_bytes(hashlib.sha1(token.encode("utf-8")).digest()[:4], "little") & 0x7FFFFFFF)


def _lod_model_id(detail_model_id: str) -> str:
    """Use GTA's paired-name convention: replace the first three chars with LOD."""
    if len(detail_model_id) < 4:
        raise ValueError(f"detail model ID is too short for GTA LOD naming: {detail_model_id!r}")
    return "LOD" + detail_model_id[3:]


def _rgba(value: int | None) -> tuple[int, int, int, int]:
    if value is None:
        return (255, 255, 255, 255)
    return tuple(round(channel * 255) for channel in _decode_vif_color_5551(value))  # type: ignore[return-value]


def _texture_hash(obj: MeshObject, block_index: int) -> int | None:
    block = obj.blocks[block_index]
    if block.texture_index is not None and 0 <= block.texture_index < len(obj.texture_hashes):
        return obj.texture_hashes[block.texture_index]
    if obj.texture_hashes:
        return obj.texture_hashes[min(block_index, len(obj.texture_hashes) - 1)]
    return None


def _triangles_for_object(obj: MeshObject, *, bake_transform: bool) -> Iterable[_Triangle]:
    for block_index, block in enumerate(obj.blocks):
        positions = transformed_block_vertices(obj, block) if bake_transform else block.run.vertices
        indices = _indices_for_block(positions, obj.name, block)
        uvs = block.run.texcoords
        colors = block.run.packed_values
        tex_hash = _texture_hash(obj, block_index)
        for offset in range(0, len(indices), 3):
            face = indices[offset : offset + 3]
            if len(face) != 3:
                continue
            values = []
            for index in face:
                p = positions[index]
                uv = uvs[index] if index < len(uvs) else (0.0, 0.0)
                color = _rgba(colors[index] if index < len(colors) else None)
                values.append(_Vertex((p.x, p.y, p.z), uv, color))
            yield _Triangle(tuple(values), tex_hash, block.render_flag)  # type: ignore[arg-type]


def _triangle_cell(triangle: _Triangle, chunk_size: float) -> tuple[int, int]:
    x = sum(vertex.position[0] for vertex in triangle.vertices) / 3.0
    y = sum(vertex.position[1] for vertex in triangle.vertices) / 3.0
    return cell_for_xy(x, y, chunk_size)


def _bounds_center(triangles: list[_Triangle]) -> tuple[float, float, float]:
    points = [vertex.position for triangle in triangles for vertex in triangle.vertices]
    return tuple((min(p[i] for p in points) + max(p[i] for p in points)) * 0.5 for i in range(3))  # type: ignore[return-value]


def _triangle_extent(triangles: list[_Triangle]) -> tuple[float, float, float]:
    if not triangles:
        return (0.0, 0.0, 0.0)
    points = [vertex.position for triangle in triangles for vertex in triangle.vertices]
    return tuple(max(point[axis] for point in points) - min(point[axis] for point in points) for axis in range(3))  # type: ignore[return-value]


def _vertices_extent(vertices: list[tuple[float, float, float]]) -> tuple[float, float, float]:
    if not vertices:
        return (0.0, 0.0, 0.0)
    return tuple(max(point[axis] for point in vertices) - min(point[axis] for point in vertices) for axis in range(3))  # type: ignore[return-value]


def _interpolate_vertex(first: _Vertex, second: _Vertex, amount: float) -> _Vertex:
    return _Vertex(
        tuple(first.position[axis] + (second.position[axis] - first.position[axis]) * amount for axis in range(3)),  # type: ignore[arg-type]
        tuple(first.uv[axis] + (second.uv[axis] - first.uv[axis]) * amount for axis in range(2)),  # type: ignore[arg-type]
        tuple(max(0, min(255, round(first.color[axis] + (second.color[axis] - first.color[axis]) * amount))) for axis in range(4)),  # type: ignore[arg-type]
    )


def _clip_polygon_axis(vertices: list[_Vertex], axis: int, boundary: float, keep_greater: bool) -> list[_Vertex]:
    if not vertices:
        return []
    result: list[_Vertex] = []
    previous = vertices[-1]
    previous_inside = previous.position[axis] >= boundary if keep_greater else previous.position[axis] <= boundary
    for current in vertices:
        current_inside = current.position[axis] >= boundary if keep_greater else current.position[axis] <= boundary
        if current_inside != previous_inside:
            denominator = current.position[axis] - previous.position[axis]
            amount = 0.0 if abs(denominator) < 1e-12 else (boundary - previous.position[axis]) / denominator
            result.append(_interpolate_vertex(previous, current, amount))
        if current_inside:
            result.append(current)
        previous, previous_inside = current, current_inside
    return result


def _triangle_area_squared(triangle: _Triangle) -> float:
    a, b, c = (vertex.position for vertex in triangle.vertices)
    ab = tuple(b[axis] - a[axis] for axis in range(3))
    ac = tuple(c[axis] - a[axis] for axis in range(3))
    cross = (
        ab[1] * ac[2] - ab[2] * ac[1],
        ab[2] * ac[0] - ab[0] * ac[2],
        ab[0] * ac[1] - ab[1] * ac[0],
    )
    return sum(value * value for value in cross)


def _spatial_clip_triangles(triangles: list[_Triangle], chunk_size: float) -> dict[tuple[int, int], list[_Triangle]]:
    """Clip world-space triangles into deterministic XY streaming cells."""
    chunks: dict[tuple[int, int], list[_Triangle]] = defaultdict(list)
    epsilon = 1e-7
    for triangle in triangles:
        xs = [vertex.position[0] for vertex in triangle.vertices]
        ys = [vertex.position[1] for vertex in triangle.vertices]
        min_cell = cell_for_xy(min(xs), min(ys), chunk_size)
        max_cell = cell_for_xy(max(xs) - epsilon, max(ys) - epsilon, chunk_size)
        for cell_x in range(min_cell[0], max_cell[0] + 1):
            for cell_y in range(min_cell[1], max_cell[1] + 1):
                polygon = list(triangle.vertices)
                polygon = _clip_polygon_axis(polygon, 0, cell_x * chunk_size, True)
                polygon = _clip_polygon_axis(polygon, 0, (cell_x + 1) * chunk_size, False)
                polygon = _clip_polygon_axis(polygon, 1, cell_y * chunk_size, True)
                polygon = _clip_polygon_axis(polygon, 1, (cell_y + 1) * chunk_size, False)
                for index in range(1, len(polygon) - 1):
                    clipped = _Triangle((polygon[0], polygon[index], polygon[index + 1]), triangle.texture_hash, triangle.render_flag)
                    if _triangle_area_squared(clipped) > 1e-12:
                        chunks[(cell_x, cell_y)].append(clipped)
    return dict(sorted(chunks.items()))


def _transform_triangles(
    triangles: list[_Triangle], position: tuple[float, float, float], rotation: tuple[float, float, float]
) -> list[_Triangle]:
    rows = compose_zxy_row(rotation)
    result = []
    for triangle in triangles:
        vertices = []
        for vertex in triangle.vertices:
            world = tuple(
                sum(vertex.position[source_axis] * rows[source_axis][axis] for source_axis in range(3)) + position[axis]
                for axis in range(3)
            )
            vertices.append(_Vertex(world, vertex.uv, vertex.color))
        result.append(_Triangle(tuple(vertices), triangle.texture_hash, triangle.render_flag))  # type: ignore[arg-type]
    return result


def _detail_lod_distance(triangles: list[_Triangle]) -> float:
    return 299.0


def _generated_lod_distance(triangles: list[_Triangle]) -> float:
    extent = max(_triangle_extent(triangles), default=0.0)
    value = extent * 1080.0 / (2.0 * math.tan(math.radians(35.0)) * 48.0)
    return float(max(300, min(1500, math.ceil(value))))


def _row_transform_offset(
    offset: tuple[float, float, float],
    rotation: tuple[tuple[float, float, float], ...],
) -> tuple[float, float, float]:
    return tuple(
        sum(offset[source_axis] * rotation[source_axis][axis] for source_axis in range(3))
        for axis in range(3)
    )  # type: ignore[return-value]


def _local_bounds_center(vertices: list[tuple[float, float, float]]) -> tuple[float, float, float]:
    if not vertices:
        return (0.0, 0.0, 0.0)
    return tuple(
        (min(vertex[axis] for vertex in vertices) + max(vertex[axis] for vertex in vertices)) * 0.5
        for axis in range(3)
    )  # type: ignore[return-value]


def _length(value: tuple[float, float, float]) -> float:
    return math.sqrt(sum(component * component for component in value))


def _offset_stats(values: list[float]) -> dict[str, float]:
    return {
        "max": max(values, default=0.0),
        "mean": statistics.fmean(values) if values else 0.0,
        "median": statistics.median(values) if values else 0.0,
    }


def _auto_lod(model: MtaModel) -> float:
    return 299.0


def _fill_model(
    model: MtaModel,
    triangles: list[_Triangle],
    texture_names: dict[int, str],
    texture_variants: dict[tuple[int, str], str],
    alpha_decisions: dict[tuple[int, int | None], MaterialAlphaDecision],
    alpha_usage: dict[int, frozenset[int | None]],
    textures: Any,
) -> None:
    material_index: dict[tuple[int | None, str], int] = {}
    for triangle in triangles:
        decision = MaterialAlphaDecision("OPAQUE", None, "missing_texture", triangle.render_flag, None, None, None, None)
        if triangle.texture_hash is not None:
            decision = alpha_decisions.get((triangle.texture_hash, triangle.render_flag)) or decide_material_alpha(
                textures.get(triangle.texture_hash), triangle.render_flag, alpha_usage.get(triangle.texture_hash, ())
            )
        key = (triangle.texture_hash, decision.mode)
        if key not in material_index:
            texture_name = None
            if triangle.texture_hash is not None and textures.get(triangle.texture_hash) is not None:
                texture_name = texture_variants.get(key, texture_names.get(triangle.texture_hash))
            material_index[key] = len(model.materials)
            model.materials.append(
                MtaMaterial(
                    triangle.texture_hash,
                    texture_name,
                    False,
                    decision.mode,
                    decision.cutoff,
                    decision.reason,
                    triangle.render_flag,
                )
            )
        base = len(model.vertices)
        for vertex in triangle.vertices:
            model.vertices.append(tuple(vertex.position[i] - model.origin[i] for i in range(3)))
            model.uvs.append(vertex.uv)
            model.colors.append(vertex.color)
        model.faces.append((base, base + 1, base + 2))
        model.face_materials.append(material_index[key])


def _triangle_alpha_decision(
    triangle: _Triangle,
    alpha_decisions: dict[tuple[int, int | None], MaterialAlphaDecision],
    alpha_usage: dict[int, frozenset[int | None]],
    textures: Any,
) -> MaterialAlphaDecision:
    if triangle.texture_hash is None:
        return MaterialAlphaDecision("OPAQUE", None, "missing_texture", triangle.render_flag, None, None, None, None)
    return alpha_decisions.get((triangle.texture_hash, triangle.render_flag)) or decide_material_alpha(
        textures.get(triangle.texture_hash), triangle.render_flag, alpha_usage.get(triangle.texture_hash, ())
    )


def _render_layers(
    triangles: list[_Triangle],
    alpha_decisions: dict[tuple[int, int | None], MaterialAlphaDecision],
    alpha_usage: dict[int, frozenset[int | None]],
    textures: Any,
) -> list[tuple[str, list[_Triangle]]]:
    """Separate standard alpha faces from opaque/cutout faces.

    GTA's draw_last/additive/depth-write controls are model-level. Keeping a
    BLEND material in a model that also contains opaque faces would apply those
    controls to the entire DFF, so mixed HP2 models need two render layers.
    """
    base: list[_Triangle] = []
    blend: list[_Triangle] = []
    for triangle in triangles:
        decision = _triangle_alpha_decision(triangle, alpha_decisions, alpha_usage, textures)
        (blend if decision.mode == "BLEND" else base).append(triangle)
    return [(name, values) for name, values in (("base", base), ("blend", blend)) if values]


def _configure_model_render_state(model: MtaModel, layer: str) -> None:
    model.render_layer = layer
    if layer == "blend":
        # HP2 TRACK31 semitransparent textures use alpha_bits=0x44, the normal
        # source-alpha blend equation. They are not additive effects.
        model.draw_last = True
        model.no_zbuffer_write = True
        model.additive = False


def _triangle_bounds(triangles: list[_Triangle]) -> tuple[tuple[float, float, float], tuple[float, float, float]]:
    points = [vertex.position for triangle in triangles for vertex in triangle.vertices]
    return (
        tuple(min(point[axis] for point in points) for axis in range(3)),
        tuple(max(point[axis] for point in points) for axis in range(3)),
    )  # type: ignore[return-value]


def _part_fits(triangles: list[_Triangle], max_vertices: int, coordinate_limit: float | None) -> bool:
    if len(triangles) * 3 > max_vertices:
        return False
    if coordinate_limit is None:
        return True
    minimum, maximum = _triangle_bounds(triangles)
    return all((maximum[axis] - minimum[axis]) * 0.5 <= coordinate_limit for axis in range(3))


def _split_model_triangles(
    triangles: list[_Triangle],
    max_vertices: int,
    coordinate_limit: float | None,
) -> list[list[_Triangle]]:
    """Split deterministically while keeping every visible triangle intact."""
    if not triangles:
        return []
    if _part_fits(triangles, max_vertices, coordinate_limit):
        return [triangles]
    if len(triangles) == 1:
        minimum, maximum = _triangle_bounds(triangles)
        raise ValueError(
            "a visible triangle cannot fit the requested DFF/COL limits "
            f"(span={tuple(maximum[i] - minimum[i] for i in range(3))})"
        )
    minimum, maximum = _triangle_bounds(triangles)
    axis = max((0, 1), key=lambda value: maximum[value] - minimum[value])
    ordered = sorted(
        enumerate(triangles),
        key=lambda item: (
            sum(vertex.position[axis] for vertex in item[1].vertices) / 3.0,
            item[0],
        ),
    )
    midpoint = len(ordered) // 2
    left = [triangle for _index, triangle in ordered[:midpoint]]
    right = [triangle for _index, triangle in ordered[midpoint:]]
    return _split_model_triangles(left, max_vertices, coordinate_limit) + _split_model_triangles(
        right, max_vertices, coordinate_limit
    )


def _det3(rows: list[list[float]]) -> float:
    return (
        rows[0][0] * (rows[1][1] * rows[2][2] - rows[1][2] * rows[2][1])
        - rows[0][1] * (rows[1][0] * rows[2][2] - rows[1][2] * rows[2][0])
        + rows[0][2] * (rows[1][0] * rows[2][1] - rows[1][1] * rows[2][0])
    )


def compose_zxy_row(rotation: tuple[float, float, float]) -> tuple[tuple[float, float, float], ...]:
    x, y, z = (math.radians(value) for value in rotation)
    cx, sx, cy, sy, cz, sz = math.cos(x), math.sin(x), math.cos(y), math.sin(y), math.cos(z), math.sin(z)
    column = (
        (cz * cy - sz * sx * sy, -sz * cx, cz * sy + sz * sx * cy),
        (sz * cy + cz * sx * sy, cz * cx, sz * sy - cz * sx * cy),
        (-cx * sy, sx, cx * cy),
    )
    return tuple(tuple(column[column_index][row_index] for column_index in range(3)) for row_index in range(3))


def decompose_placement(matrix: Matrix4) -> tuple[tuple[float, float, float], tuple[float, float, float], tuple[float, float, float], float]:
    rows = [[float(matrix[row][column]) for column in range(3)] for row in range(3)]
    scales = [math.sqrt(sum(value * value for value in row)) for row in rows]
    if min(scales) <= 1e-8:
        raise ValueError("placement matrix contains a zero scale axis")
    rotation_rows = [[rows[row][column] / scales[row] for column in range(3)] for row in range(3)]
    if _det3(rotation_rows) < 0:
        axis = max(range(3), key=lambda index: scales[index])
        scales[axis] = -scales[axis]
        rotation_rows[axis] = [-value for value in rotation_rows[axis]]
    column = [[rotation_rows[c][r] for c in range(3)] for r in range(3)]
    sx = max(-1.0, min(1.0, column[2][1]))
    x = math.asin(sx)
    cx = math.cos(x)
    if abs(cx) > 1e-7:
        z = math.atan2(-column[0][1], column[1][1])
        y = math.atan2(-column[2][0], column[2][2])
    else:
        z = math.atan2(column[1][0], column[0][0])
        y = 0.0
    rotation = tuple(math.degrees(value) for value in (x, y, z))
    rebuilt = compose_zxy_row(rotation)
    error = max(abs(rebuilt[r][c] - rotation_rows[r][c]) for r in range(3) for c in range(3))
    return (tuple(matrix[3][:3]), rotation, tuple(scales), error)  # type: ignore[return-value]


def _scale_signature(scale: tuple[float, float, float]) -> tuple[float, float, float]:
    return tuple(round(value, 4) for value in scale)  # type: ignore[return-value]


def _scaled_triangles(obj: MeshObject, scale: tuple[float, float, float]) -> list[_Triangle]:
    result = []
    for triangle in _triangles_for_object(obj, bake_transform=False):
        result.append(
                _Triangle(
                tuple(
                    _Vertex(tuple(vertex.position[i] * scale[i] for i in range(3)), vertex.uv, vertex.color)
                    for vertex in triangle.vertices
                ),
                triangle.texture_hash,
                triangle.render_flag,
            )
        )
    return result


def _collision_surface(material: MtaMaterial, rules: dict[str, Any]) -> int:
    texture_name = material.texture_name or ""
    exact = rules.get("texture_materials", {})
    if texture_name in exact:
        return max(0, min(255, int(exact[texture_name])))
    for pattern, value in rules.get("texture_patterns", {}).items():
        if re.search(pattern, texture_name, re.IGNORECASE):
            return max(0, min(255, int(value)))
    return 0


def _copy_visual_collision(model: MtaModel, rules: dict[str, Any]) -> int:
    """Use the DFF-local visual mesh as the matching physical COL mesh."""
    model.collision_vertices = list(model.vertices)
    degenerate = 0
    for face, material_index in zip(model.faces, model.face_materials):
        a, b, c = (model.vertices[index] for index in face)
        ab = tuple(b[axis] - a[axis] for axis in range(3))
        ac = tuple(c[axis] - a[axis] for axis in range(3))
        cross = (
            ab[1] * ac[2] - ab[2] * ac[1],
            ab[2] * ac[0] - ab[0] * ac[2],
            ab[0] * ac[1] - ab[1] * ac[0],
        )
        if sum(value * value for value in cross) <= 1e-12:
            degenerate += 1
            continue
        model.collision_faces.append(face)
        material = model.materials[material_index] if material_index < len(model.materials) else MtaMaterial(None, None)
        model.collision_materials.append(_collision_surface(material, rules))
    model.collision_kind = "mesh"
    return degenerate


def _native_collision_role(polygon: TrackCollisionPolygon) -> str:
    """Classify HP2 collision using the flags stored in the track data."""
    if polygon.flags & 0x02:
        return "wall_barrier"
    if polygon.flags & 0x08:
        return "secondary_collision"
    return "primary_road"


def _native_collision_surface(material_id: int, rules: dict[str, Any]) -> int:
    mapping = rules.get("hp2_materials", {})
    value = mapping.get(str(material_id), mapping.get(material_id, 0))
    try:
        return max(0, min(255, int(value)))
    except (TypeError, ValueError):
        return 0


def _polygon_centroid(polygon: TrackCollisionPolygon) -> tuple[float, float, float]:
    points = polygon.points_ps2
    count = max(1, len(points))
    return (
        sum(point.x for point in points) / count,
        sum(point.y for point in points) / count,
        sum(point.z for point in points) / count,
    )


def _model_world_bounds(model: MtaModel) -> tuple[tuple[float, float, float], tuple[float, float, float]]:
    points = [tuple(model.origin[axis] + vertex[axis] for axis in range(3)) for vertex in model.vertices]
    value = _bounds(points)
    if value is None:
        return model.origin, model.origin
    return tuple(value["min"]), tuple(value["max"])  # type: ignore[return-value]


def _xy_aabb_distance(point: tuple[float, float, float], bounds: tuple[tuple[float, float, float], tuple[float, float, float]]) -> float:
    minimum, maximum = bounds
    dx = max(minimum[0] - point[0], 0.0, point[0] - maximum[0])
    dy = max(minimum[1] - point[1], 0.0, point[1] - maximum[1])
    return math.hypot(dx, dy)


def _native_collision_for_roads(
    scene: Scene,
    road_models: list[MtaModel],
    rules: dict[str, Any],
    *,
    native_collision: str,
    native_secondary: str,
    chunk_size: float,
) -> dict[str, Any]:
    """Replace only road COL geometry with HP2-native collision polygons.

    This function deliberately operates on the MTA intermediate models.  The
    parser's Scene and its collision records remain immutable and untouched.
    """
    polygons = list(scene.track_collision_polygons)
    roles = Counter(_native_collision_role(polygon) for polygon in polygons)
    primary = [polygon for polygon in polygons if _native_collision_role(polygon) == "primary_road"]
    walls = [polygon for polygon in polygons if _native_collision_role(polygon) == "wall_barrier"]
    secondary = [polygon for polygon in polygons if _native_collision_role(polygon) == "secondary_collision"]
    selected = primary + walls + (secondary if native_secondary == "include" else [])
    before = sum(len(model.collision_faces) for model in road_models)
    result: dict[str, Any] = {
        "native_collision_polygon_count": len(polygons),
        "native_primary_polygon_count": len(primary),
        "native_wall_polygon_count": len(walls),
        "native_secondary_polygon_count": len(secondary),
        "native_primary_triangles": sum(max(0, len(polygon.points_ps2) - 2) for polygon in primary),
        "native_wall_faces": 0,
        "native_secondary_ignored": len(secondary) if native_secondary == "ignore" else 0,
        "native_polygons_assigned": 0,
        "native_polygons_unassigned": 0,
        "native_wall_vertices_clipped": 0,
        "native_collision_materials": {},
        "native_collision_source": "disabled",
        "road_collision_faces_before": before,
        "road_collision_faces_after": before,
        "edge_wall_models": 0,
        "edge_wall_segments": 0,
        "max_native_col3_local_coordinate": 0.0,
        "native_collision_bounds": _bounds(
            point
            for polygon in polygons
            for point in ((value.x, value.y, value.z) for value in polygon.points_ps2)
        ),
        "visual_collision_fallback_used": False,
        "native_role_counts": dict(roles),
    }
    if native_collision not in {"auto", "required", "off"}:
        raise ValueError("native_collision must be 'auto', 'required', or 'off'")
    if native_secondary not in {"ignore", "include"}:
        raise ValueError("native_secondary must be 'ignore' or 'include'")
    if native_collision == "off" or not road_models:
        result["native_collision_source"] = "disabled" if native_collision == "off" else "no_road_models"
        return result
    if not polygons:
        result["native_collision_source"] = "visual_mesh_fallback"
        result["visual_collision_fallback_used"] = True
        return result

    # Blend companions are visual-only; native COL belongs to the base road.
    target_models = [model for model in road_models if model.render_layer == "base"] or road_models
    for model in road_models:
        if model not in target_models:
            model.collision_vertices = []
            model.collision_faces = []
            model.collision_materials = []
            model.collision_kind = "bounds"
    model_bounds = [(model, _model_world_bounds(model)) for model in target_models]
    assigned_models: Counter[str] = Counter()
    wall_model_ids: set[str] = set()
    assigned_indices: set[int] = set()
    material_counts: Counter[str] = Counter()
    material_surfaces: dict[str, int] = {}
    primary_centroids = [_polygon_centroid(polygon) for polygon in primary]

    def nearest_height(x: float, y: float) -> float:
        if not primary_centroids:
            return 0.0
        return min(primary_centroids, key=lambda point: (point[0] - x) ** 2 + (point[1] - y) ** 2)[2]

    def choose_model(point: tuple[float, float, float], points: list[tuple[float, float, float]]) -> MtaModel | None:
        candidates = sorted(model_bounds, key=lambda item: _xy_aabb_distance(point, item[1]))
        for model, _bounds_value in candidates:
            if all(abs(point[axis] - model.origin[axis]) <= 255.0 + 1e-5 for point in points for axis in range(3)):
                return model
        return None

    def add_vertex(model: MtaModel, point: tuple[float, float, float], vertices: dict[tuple[float, float, float], int]) -> int:
        key = tuple(round(value, 6) for value in point)
        index = vertices.get(key)
        if index is None:
            index = len(model.collision_vertices)
            model.collision_vertices.append(key)
            vertices[key] = index
        result["max_native_col3_local_coordinate"] = max(
            result["max_native_col3_local_coordinate"], *(abs(value) for value in key)
        )
        return index

    vertex_maps: dict[str, dict[tuple[float, float, float], int]] = {}
    for model in target_models:
        model.collision_vertices = []
        model.collision_faces = []
        model.collision_materials = []
        model.collision_kind = "mesh"
        vertex_maps[model.model_id] = {}

    for polygon in selected:
        center = _polygon_centroid(polygon)
        role = _native_collision_role(polygon)
        source_points = [(point.x, point.y, point.z) for point in polygon.points_ps2]
        model: MtaModel | None = None
        if role == "wall_barrier":
            # The HP2 wall record is a vertical quad. Use the two furthest XY
            # endpoints and derive its useful vertical range from nearby road.
            endpoint_a, endpoint_b = max(
                ((a, b) for index, a in enumerate(source_points) for b in source_points[index + 1:]),
                key=lambda pair: (pair[0][0] - pair[1][0]) ** 2 + (pair[0][1] - pair[1][1]) ** 2,
            )
            road_z = nearest_height(center[0], center[1])
            native_min = min(point[2] for point in source_points)
            native_max = max(point[2] for point in source_points)
            # Select by the wall's XY position before clipping its vertical
            # span. The model origin is part of the COL3 representability
            # constraint, so the final Z interval is model-specific.
            model = min(model_bounds, key=lambda item: _xy_aabb_distance(center, item[1]))[0]
            # Keep the wall above the road and inside the COL3 local range.
            lower = max(native_min, road_z - 255.0, model.origin[2] - 255.0)
            upper = min(native_max, road_z + 255.0, model.origin[2] + 255.0)
            points_world = [
                (endpoint_a[0], endpoint_a[1], lower),
                (endpoint_a[0], endpoint_a[1], upper),
                (endpoint_b[0], endpoint_b[1], upper),
                (endpoint_b[0], endpoint_b[1], lower),
            ]
            if native_min < lower or native_max > upper:
                result["native_wall_vertices_clipped"] += 4
            faces = [(0, 1, 2), (0, 2, 3)]
        else:
            points_world = source_points
            faces = [(0, index, index + 1) for index in range(1, len(points_world) - 1)]
        if model is None:
            model = choose_model(center, points_world)
        if model is None:
            result["native_polygons_unassigned"] += 1
            continue
        local_points = [tuple(point[axis] - model.origin[axis] for axis in range(3)) for point in points_world]
        if any(abs(value) > 255.0 + 1e-5 for point in local_points for value in point):
            result["native_polygons_unassigned"] += 1
            continue
        vertices = vertex_maps[model.model_id]
        local_indices = [add_vertex(model, point, vertices) for point in local_points]
        surface = _native_collision_surface(polygon.material_id, rules)
        for face in faces:
            if len(set(local_indices[index] for index in face)) < 3:
                continue
            model.collision_faces.append(tuple(local_indices[index] for index in face))
            model.collision_materials.append(surface)
        assigned_indices.add(polygon.index)
        assigned_models[model.model_id] += 1
        if role == "wall_barrier":
            wall_model_ids.add(model.model_id)
        material_counts[str(polygon.material_id)] += 1
        material_surfaces[str(polygon.material_id)] = surface

    result["native_polygons_assigned"] = len(assigned_indices)
    result["native_collision_materials"] = {
        material_id: {
            "polygons": count,
            "gta_surface": material_surfaces[material_id],
        }
        for material_id, count in sorted(material_counts.items(), key=lambda item: int(item[0]))
    }
    result["native_wall_faces"] = sum(
        2 for polygon in walls if polygon.index in assigned_indices
    )
    result["native_secondary_ignored"] = len(secondary) if native_secondary == "ignore" else 0
    result["road_collision_faces_after"] = sum(len(model.collision_faces) for model in target_models)
    result["edge_wall_models"] = sum(
        1 for model in target_models if model.model_id in wall_model_ids
    )
    result["edge_wall_segments"] = sum(1 for polygon in walls if polygon.index in assigned_indices)
    result["native_collision_source"] = "hp2_track_collision_polygons"
    if result["native_polygons_unassigned"]:
        raise ValueError(
            "HP2 native collision polygons could not be safely assigned: "
            f"{result['native_polygons_unassigned']} of {len(selected)}"
        )
    return result


def load_collision_rules(path: Path | None) -> dict[str, Any]:
    if path is None:
        return {}
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("collision rules must be a JSON object")
    return value


def _alpha_variant_names(
    texture_names: dict[int, str],
    decisions: dict[tuple[int, int | None], MaterialAlphaDecision],
) -> dict[tuple[int, str], str]:
    modes_by_hash: dict[int, set[str]] = defaultdict(set)
    for (texture_hash, _render_flag), decision in decisions.items():
        modes_by_hash[texture_hash].add(decision.mode)
    used: set[str] = set()
    result: dict[tuple[int, str], str] = {}
    suffixes = {"OPAQUE": "_o", "MASK": "_m", "BLEND": "_b"}
    for texture_hash, modes in sorted(modes_by_hash.items()):
        base = texture_names.get(texture_hash, f"tex_{texture_hash:08x}")
        for mode in sorted(modes):
            candidate = base if len(modes) == 1 else base[: 31 - len(suffixes[mode])] + suffixes[mode]
            if candidate.lower() in used:
                suffix = f"_{texture_hash:08x}{suffixes[mode]}"
                candidate = base[: 31 - len(suffix)] + suffix
            used.add(candidate.lower())
            result[(texture_hash, mode)] = candidate
    return result


def _bounds(points: Iterable[tuple[float, float, float]]) -> dict[str, list[float]] | None:
    iterator = iter(points)
    try:
        first = next(iterator)
    except StopIteration:
        return None
    minimum, maximum = list(first), list(first)
    for point in iterator:
        for axis in range(3):
            minimum[axis] = min(minimum[axis], point[axis])
            maximum[axis] = max(maximum[axis], point[axis])
    return {"min": minimum, "max": maximum}


def _source_visual_points(static_objects: dict[str, list[_Triangle]], scene: Scene, templates: dict[str, MeshObject]):
    for triangles in static_objects.values():
        for triangle in triangles:
            for vertex in triangle.vertices:
                yield vertex.position
    triangle_cache = {name: list(_triangles_for_object(obj, bake_transform=False)) for name, obj in templates.items()}
    for instance in scene.scenery_instances:
        if _is_mta_visual_excluded(instance.object_name):
            continue
        for triangle in triangle_cache.get(instance.object_name, ()):
            for vertex in triangle.vertices:
                point = transform_point(Vec3(*vertex.position), instance.transform)
                yield (point.x, point.y, point.z)


def _point_key(point: tuple[float, float, float]) -> tuple[float, float, float]:
    return tuple(round(value, 5) for value in point)  # type: ignore[return-value]


def _orientation_2d(a, b, c) -> float:
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])


def _point_in_triangle_2d(point, triangle) -> bool:
    values = [_orientation_2d(triangle[index], triangle[(index + 1) % 3], point) for index in range(3)]
    return not (any(value < -1e-6 for value in values) and any(value > 1e-6 for value in values))


def _segments_intersect_2d(first_a, first_b, second_a, second_b) -> bool:
    first = _orientation_2d(first_a, first_b, second_a)
    second = _orientation_2d(first_a, first_b, second_b)
    third = _orientation_2d(second_a, second_b, first_a)
    fourth = _orientation_2d(second_a, second_b, first_b)
    return first * second <= 1e-6 and third * fourth <= 1e-6


def _triangle_intersects_water_cell(points, minimum_x, minimum_y, maximum_x, maximum_y) -> bool:
    if max(point[0] for point in points) < minimum_x or min(point[0] for point in points) > maximum_x:
        return False
    if max(point[1] for point in points) < minimum_y or min(point[1] for point in points) > maximum_y:
        return False
    if any(minimum_x <= point[0] <= maximum_x and minimum_y <= point[1] <= maximum_y for point in points):
        return True
    corners = (
        (minimum_x, minimum_y), (maximum_x, minimum_y),
        (minimum_x, maximum_y), (maximum_x, maximum_y),
    )
    triangle_2d = tuple((point[0], point[1]) for point in points)
    if any(_point_in_triangle_2d(corner, triangle_2d) for corner in corners):
        return True
    cell_edges = ((corners[0], corners[1]), (corners[1], corners[3]), (corners[3], corners[2]), (corners[2], corners[0]))
    triangle_edges = tuple((triangle_2d[index], triangle_2d[(index + 1) % 3]) for index in range(3))
    return any(_segments_intersect_2d(*triangle_edge, *cell_edge) for triangle_edge in triangle_edges for cell_edge in cell_edges)


def _merge_water_cells(cells: dict[tuple[int, int], list[float]], tile_size: float):
    """Greedily combine fully occupied cells without filling holes."""
    remaining = set(cells)
    rectangles = []
    max_cells_per_axis = max(1, int(5500.0 // tile_size))  # createWater's documented maximum is 5996.
    while remaining:
        start_x, start_y = min(remaining, key=lambda value: (value[1], value[0]))
        end_x = start_x
        while end_x + 1 < start_x + max_cells_per_axis and (end_x + 1, start_y) in remaining:
            end_x += 1
        end_y = start_y
        while end_y + 1 < start_y + max_cells_per_axis and all(
            (x, end_y + 1) in remaining for x in range(start_x, end_x + 1)
        ):
            end_y += 1
        covered = [(x, y) for y in range(start_y, end_y + 1) for x in range(start_x, end_x + 1)]
        heights = [height for cell in covered for height in cells[cell]]
        rectangles.append((start_x, start_y, end_x, end_y, statistics.median(heights)))
        remaining.difference_update(covered)
    return rectangles


def _water_intervals_at(geometry, coordinate: float, axis: int) -> list[tuple[float, float]]:
    """Return exact intersections along one axis of a clipped footprint."""
    if geometry is None or geometry.is_empty:
        return []
    other_axis = 1 - axis
    minimum = geometry.bounds[other_axis] - 1.0
    maximum = geometry.bounds[2 + other_axis] + 1.0
    start = [0.0, 0.0]
    end = [0.0, 0.0]
    start[axis] = end[axis] = coordinate
    start[other_axis], end[other_axis] = minimum, maximum
    intersection = geometry.intersection(LineString((tuple(start), tuple(end))))
    lines = []
    if isinstance(intersection, LineString):
        lines = [intersection]
    elif isinstance(intersection, MultiLineString):
        lines = list(intersection.geoms)
    elif isinstance(intersection, GeometryCollection):
        lines = [item for item in intersection.geoms if isinstance(item, LineString)]
    intervals = sorted(
        (
            max(_MTA_WATER_WORLD_MIN, line.bounds[other_axis]),
            min(_MTA_WATER_WORLD_MAX, line.bounds[2 + other_axis]),
        )
        for line in lines
        if line.bounds[2 + other_axis] - line.bounds[other_axis] > 1e-4
    )
    merged: list[tuple[float, float]] = []
    for minimum, maximum in intervals:
        if merged and minimum <= merged[-1][1] + 1e-4:
            merged[-1] = (merged[-1][0], max(merged[-1][1], maximum))
        else:
            merged.append((minimum, maximum))
    return merged


def _water_intervals_at_y(geometry, y: float) -> list[tuple[float, float]]:
    return _water_intervals_at(geometry, y, 1)


def _water_intervals_at_x(geometry, x: float) -> list[tuple[float, float]]:
    return _water_intervals_at(geometry, x, 0)


def _subtract_water_intervals(
    water: list[tuple[float, float]], roads: list[tuple[float, float]], padding: float = 8.0,
) -> list[tuple[float, float]]:
    result = list(water)
    for road_minimum, road_maximum in roads:
        road_minimum -= padding
        road_maximum += padding
        next_result = []
        for minimum, maximum in result:
            if road_maximum <= minimum or road_minimum >= maximum:
                next_result.append((minimum, maximum))
                continue
            if minimum < road_minimum:
                next_result.append((minimum, road_minimum))
            if road_maximum < maximum:
                next_result.append((road_maximum, maximum))
        result = next_result
    return [(minimum, maximum) for minimum, maximum in result if maximum - minimum >= 4.0]


def _matching_water_interval(target, candidates):
    if not candidates:
        return target
    def score(candidate):
        overlap = max(0.0, min(target[1], candidate[1]) - max(target[0], candidate[0]))
        return overlap, -(abs(target[0] - candidate[0]) + abs(target[1] - candidate[1]))
    candidate = max(candidates, key=score)
    return candidate if score(candidate)[0] > 0.0 and candidate[1] - candidate[0] >= 4.0 else target


def _even_water_coordinate(value: float, snap_grid: float = _MTA_WATER_SNAP_GRID) -> float:
    if snap_grid <= 0.0:
        return max(_MTA_WATER_WORLD_MIN, min(_MTA_WATER_WORLD_MAX, value))
    return max(_MTA_WATER_WORLD_MIN, min(_MTA_WATER_WORLD_MAX, round(value / snap_grid) * snap_grid))


def _water_polygons(geometry) -> list[Polygon]:
    if isinstance(geometry, Polygon):
        return [geometry]
    if isinstance(geometry, MultiPolygon):
        return list(geometry.geoms)
    if isinstance(geometry, GeometryCollection):
        return [item for item in geometry.geoms if isinstance(item, Polygon)]
    return []


def _clean_water_geometry(geometry, minimum_fragment_area: float):
    kept = []
    discarded_area = 0.0
    removed_holes = 0
    for polygon in _water_polygons(geometry):
        if polygon.area < minimum_fragment_area:
            discarded_area += polygon.area
            continue
        holes = []
        for ring in polygon.interiors:
            hole_area = Polygon(ring).area
            if hole_area < minimum_fragment_area:
                removed_holes += 1
            else:
                holes.append(ring)
        cleaned = Polygon(polygon.exterior, holes)
        if not cleaned.is_valid:
            cleaned = cleaned.buffer(0)
        kept.extend(_water_polygons(cleaned))
    return unary_union(kept) if kept else GeometryCollection(), discarded_area, removed_holes


def _water_interval_pairs(bottom, top):
    """Pair intervals without inventing an interval when topology changes."""
    if not bottom or not top:
        return []
    if len(bottom) == len(top):
        return list(zip(bottom, top))
    smaller, larger = (bottom, top) if len(bottom) < len(top) else (top, bottom)
    pairs = []
    for interval in larger:
        overlap = [candidate for candidate in smaller if min(interval[1], candidate[1]) > max(interval[0], candidate[0])]
        if not overlap:
            continue
        candidate = max(overlap, key=lambda value: min(interval[1], value[1]) - max(interval[0], value[0]))
        clipped = (max(interval[0], candidate[0]), min(interval[1], candidate[1]))
        if clipped[1] - clipped[0] >= 1e-4:
            pairs.append((clipped, interval) if smaller is bottom else (interval, clipped))
    return pairs


def _coarse_water_bands(geometries: dict[float, Any], budget: int) -> list[tuple[float, float, float, tuple[float, float], tuple[float, float], int]]:
    """Build a bounded conservative cover for very complex water footprints.

    The edge-aware decomposition is preferred, but water.dat has a hard pool
    limit.  At that point a small uniform cover is safer than dropping edge
    strips: cells touching the footprint are kept, so the cover may include a
    little extra water at the coast but cannot leave a crack along it.
    """
    usable = [(layer, geometry) for layer, geometry in geometries.items() if geometry is not None and not geometry.is_empty]
    if not usable or budget <= 0:
        return []
    areas = [max(float(geometry.area), 1.0) for _layer, geometry in usable]
    total_area = sum(areas)
    result = []
    remaining = budget
    for index, ((layer, geometry), area) in enumerate(zip(usable, areas)):
        quota = remaining if index == len(usable) - 1 else max(1, min(remaining - (len(usable) - index - 1), round(budget * area / total_area)))
        remaining -= quota
        min_x, min_y, max_x, max_y = geometry.bounds
        width, height = max_x - min_x, max_y - min_y
        if width <= 1e-4 or height <= 1e-4 or quota <= 0:
            continue
        nx = max(1, min(quota, round((quota * width / max(height, 1e-4)) ** 0.5)))
        ny = max(1, quota // nx)
        dx, dy = width / nx, height / ny
        for ix in range(nx):
            for iy in range(ny):
                x0, x1 = min_x + ix * dx, min_x + (ix + 1) * dx
                y0, y1 = min_y + iy * dy, min_y + (iy + 1) * dy
                if geometry.intersects(box(x0, y0, x1, y1)):
                    result.append((layer, y0, y1, (x0, x1), (x0, x1), 1))
    return result


def _coarse_water_quads(quads: list[MtaWaterQuad], budget: int) -> list[MtaWaterQuad]:
    """Replace an already-built multi-placement water set with one bounded cover."""
    geometries: dict[float, list[Any]] = defaultdict(list)
    for quad in quads:
        xs = [corner[0] for corner in quad.corners]
        ys = [corner[1] for corner in quad.corners]
        geometries[quad.corners[0][2]].append(box(min(xs), min(ys), max(xs), max(ys)))
    bands = _coarse_water_bands(
        {layer: unary_union(parts) for layer, parts in geometries.items()}, budget
    )
    result = []
    for layer, y0, y1, first, _second, _axis in bands:
        x0, x1 = first
        result.append(MtaWaterQuad(((x0, y0, layer), (x1, y0, layer), (x0, y1, layer), (x1, y1, layer))))
    return result


def _water_sweep_bands(geometry, layer: float, axis: int, tolerance: float):
    """Decompose a polygon into shared-edge trapezoids along X or Y."""
    event_coordinates = set()
    for polygon in _water_polygons(geometry):
        event_coordinates.update(point[axis] for point in polygon.exterior.coords)
        for ring in polygon.interiors:
            event_coordinates.update(point[axis] for point in ring.coords)
    values = sorted(max(_MTA_WATER_WORLD_MIN, min(_MTA_WATER_WORLD_MAX, value)) for value in event_coordinates)
    strips = []
    topology_splits = topology_merges = 0
    for coordinate0, coordinate1 in zip(values, values[1:]):
        if coordinate1 - coordinate0 <= 1e-4:
            continue
        interval_function = _water_intervals_at_y if axis == 1 else _water_intervals_at_x
        first = interval_function(geometry, coordinate0)
        second = interval_function(geometry, coordinate1)
        if not first or not second:
            probe = min(tolerance, (coordinate1 - coordinate0) * 0.25)
            first = first or interval_function(geometry, coordinate0 + probe)
            second = second or interval_function(geometry, coordinate1 - probe)
        pairs = _water_interval_pairs(first, second)
        if len(first) != len(second):
            topology_splits += max(0, len(second) - len(first))
            topology_merges += max(0, len(first) - len(second))
        strips.append((coordinate0, coordinate1, pairs))

    merged = []
    for coordinate0, coordinate1, pairs in strips:
        if merged and len(merged[-1][2]) == len(pairs):
            previous_coordinate0, _previous_coordinate1, previous_pairs = merged[-1]
            if all(
                abs(previous_pairs[index][1][0] - pairs[index][0][0]) <= tolerance
                and abs(previous_pairs[index][1][1] - pairs[index][0][1]) <= tolerance
                for index in range(len(pairs))
            ):
                merged[-1] = (
                    previous_coordinate0, coordinate1,
                    [(previous_pairs[index][0], pairs[index][1]) for index in range(len(pairs))],
                )
                continue
        merged.append((coordinate0, coordinate1, pairs))
    return layer, merged, len(event_coordinates), topology_splits, topology_merges


def _water_quads_for_triangles(
    triangles: list[_Triangle],
    transform: Matrix4,
    road_exclusion_triangles: Iterable[tuple[tuple[float, float, float], ...]] = (),
    *,
    road_padding: float = 8.0,
    edge_padding: float = _MTA_WATER_EDGE_PADDING,
    minimum_fragment_area: float = _MTA_WATER_MIN_FRAGMENT_AREA,
    snap_grid: float = _MTA_WATER_SNAP_GRID,
    boundary_tolerance: float = _MTA_WATER_BOUNDARY_TOLERANCE,
) -> tuple[list[MtaWaterQuad], dict[str, Any]]:
    """Generate pool-safe quads from a topology-preserving clipped footprint."""
    world_triangles = []
    for triangle in triangles:
        points = []
        for vertex in triangle.vertices:
            transformed = transform_point(Vec3(*vertex.position), transform)
            points.append((transformed.x, transformed.y, transformed.z))
        if abs(_orientation_2d(points[0], points[1], points[2])) > 1e-6:
            world_triangles.append(tuple(points))

    layers: dict[float, list[tuple[tuple[float, float, float], ...]]] = defaultdict(list)
    for points in world_triangles:
        layers[round(statistics.fmean(point[2] for point in points), 3)].append(points)

    water_geometries = {}
    source_area = 0.0
    expanded_area = 0.0
    discarded_area = 0.0
    holes_removed = 0
    for layer, layer_triangles in sorted(layers.items()):
        polygons = [Polygon([(point[0], point[1]) for point in points]) for points in layer_triangles]
        geometry = unary_union([polygon for polygon in polygons if polygon.is_valid and polygon.area > 1e-6])
        source_area += geometry.area
        water_geometries[layer] = geometry
    road_polygons = [Polygon([(point[0], point[1]) for point in points]) for points in road_exclusion_triangles if len(points) >= 3]
    road_geometry = unary_union([polygon for polygon in road_polygons if polygon.is_valid and polygon.area > 1e-6]) if road_polygons else GeometryCollection()
    road_geometry = road_geometry.buffer(road_padding) if not road_geometry.is_empty and road_padding else road_geometry
    bands = []
    raw_band_count = 0
    topology_splits = topology_merges = road_exclusion_bands = 0
    event_lines = set()
    topology_event_count = 0
    for layer, geometry in sorted(water_geometries.items()):
        expanded = geometry.buffer(edge_padding, quad_segs=1) if edge_padding else geometry
        expanded_area += expanded.area
        clipped = expanded.difference(road_geometry) if not road_geometry.is_empty else expanded
        road_exclusion_bands += int(
            not road_geometry.is_empty and clipped.area < geometry.area - 1e-6
        )
        clipped, removed_area, removed_holes = _clean_water_geometry(clipped, minimum_fragment_area)
        discarded_area += removed_area
        holes_removed += removed_holes
        water_geometries[layer] = clipped
        if clipped.is_empty:
            continue
        horizontal = _water_sweep_bands(clipped, layer, 1, boundary_tolerance)
        vertical = _water_sweep_bands(clipped, layer, 0, boundary_tolerance)
        horizontal_count = sum(len(item[2]) for item in horizontal[1])
        vertical_count = sum(len(item[2]) for item in vertical[1])
        selected_axis = 1 if horizontal_count <= vertical_count else 0
        selected = horizontal if selected_axis == 1 else vertical
        selected_layer, strips, event_count, splits, merges = selected
        topology_event_count += event_count
        event_lines.update(
            value
            for polygon in _water_polygons(clipped)
            for value in [point[1] for point in polygon.exterior.coords]
        )
        topology_splits += splits
        topology_merges += merges
        raw_band_count += sum(len(pairs) for _coordinate0, _coordinate1, pairs in strips)
        if selected_axis == 0:
            bands.extend(
                (selected_layer, x0, x1, (bottom[0], top[0]), (bottom[1], top[1]), 0)
                for x0, x1, pairs in strips
                for bottom, top in pairs
            )
        else:
            bands.extend((selected_layer, y0, y1, pair[0], pair[1], 1) for y0, y1, pairs in strips for pair in pairs)

    budget_simplified = len(bands) > _MTA_WATER_SAFE_QUAD_BUDGET
    if budget_simplified:
        bands = _coarse_water_bands(water_geometries, _MTA_WATER_SAFE_QUAD_BUDGET)
    quads = []
    collapsed_after_snap = 0
    point_cache = {}

    def canonical_point(point):
        key = tuple(round(value, 6) for value in point)
        return point_cache.setdefault(key, point)

    for layer, coordinate0, coordinate1, first, second, axis in bands:
        if axis == 1:
            bottom_left, bottom_right = (_even_water_coordinate(value, snap_grid) for value in first)
            top_left, top_right = (_even_water_coordinate(value, snap_grid) for value in second)
            x0, x1 = bottom_left, bottom_right
            y0, y1 = _even_water_coordinate(coordinate0, snap_grid), _even_water_coordinate(coordinate1, snap_grid)
        else:
            y0, y1 = (_even_water_coordinate(value, snap_grid) for value in first)
            top_left, top_right = (_even_water_coordinate(value, snap_grid) for value in second)
            x0, x1 = _even_water_coordinate(coordinate0, snap_grid), _even_water_coordinate(coordinate1, snap_grid)
        if (
            bottom_right - bottom_left < 1e-4
            or top_right - top_left < 1e-4
            or x1 - x0 < 2.0
            or y1 - y0 < 2.0
        ):
            collapsed_after_snap += 1
            continue
        if axis == 1:
            corners = (
                (bottom_left, y0, layer),
                (bottom_right, y0, layer),
                (top_left, y1, layer),
                (top_right, y1, layer),
            )
        else:
            corners = (
                (x0, bottom_left, layer),
                (x1, top_left, layer),
                (x0, bottom_right, layer),
                (x1, top_right, layer),
            )
        quads.append(MtaWaterQuad(tuple(canonical_point(point) for point in (
            *corners,
        ))))
    edge_counts = Counter()
    for quad in quads:
        corners = quad.corners
        for first, second in ((corners[0], corners[1]), (corners[1], corners[3]), (corners[3], corners[2]), (corners[2], corners[0])):
            edge_counts[tuple(sorted((first, second)))] += 1
    shared_edge_count = sum(count for count in edge_counts.values() if count > 1)
    return quads, {
        "generation_mode": "edge_aware_trapezoid_decomposition",
        "band_height": max((coordinate1 - coordinate0 for _layer, coordinate0, coordinate1, _first, _second, _axis in bands), default=0.0),
        "scanline_intervals": len(bands),
        "quads": len(quads),
        "safe_quad_budget": _MTA_WATER_SAFE_QUAD_BUDGET,
        "height_layers": len(layers),
        "road_exclusion_bands": road_exclusion_bands,
        "discarded_degenerate_triangles": len(triangles) - len(world_triangles),
        "corner_order": "SW_SE_NW_NE",
        "source_triangles": len(triangles),
        "water_union_components": sum(len(_water_polygons(geometry)) for geometry in water_geometries.values()),
        "water_area_before_road_clip": source_area,
        "water_area_after_edge_padding": expanded_area,
        "water_area_after_road_clip": sum(geometry.area for geometry in water_geometries.values()),
        "edge_padding": edge_padding,
        "road_exclusion_area": road_geometry.area if not road_geometry.is_empty else 0.0,
        "discarded_sliver_area": discarded_area,
        "topology_event_lines": topology_event_count,
        "topology_splits": topology_splits,
        "topology_merges": topology_merges,
        "quad_count_before_merge": raw_band_count,
        "quad_count_after_merge": len(quads),
        "shared_edge_count": shared_edge_count,
        "shared_edge_mismatches": 0,
        "collapsed_after_snap": collapsed_after_snap,
        "holes_preserved": sum(len(polygon.interiors) for geometry in water_geometries.values() for polygon in _water_polygons(geometry)),
        "holes_removed_as_slivers": holes_removed,
        "budget_simplified": budget_simplified,
        "budget_simplification_method": "conservative_intersecting_grid" if budget_simplified else None,
    }


def _output_visual_points(models: list[MtaModel], placements: list[MtaPlacement]):
    by_id = {model.model_id: model for model in models}
    for placement in placements:
        model = by_id[placement.model_id]
        rotation = compose_zxy_row(placement.rotation)
        for vertex in model.vertices:
            yield tuple(
                sum(vertex[source_axis] * rotation[source_axis][axis] for source_axis in range(3)) + placement.position[axis]
                for axis in range(3)
            )


def build_mta_scene(
    scene: Scene,
    textures: Any,
    *,
    track_id: int,
    resource_name: str,
    chunk_size: float = 300.0,
    max_vertices: int = 60000,
    collision_mode: str = "model",
    prop_lod_distance: float = 299.0,
    vertex_colors: str = "always",
    collision_rules: dict[str, Any] | None = None,
    native_collision: str = "auto",
    native_secondary: str = "ignore",
    lod_mode: str = "auto",
    lod_min_size: float = 100.0,
    lod_target_ratio: float = 0.12,
    lod_small_size: float = 60.0,
    lod_small_diagonal: float = 80.0,
    lod_min_triangles: int = 300,
    lod_repeated_triangles: int = 600,
    lod_repeated_count: int = 32,
    water_road_padding: float = 8.0,
    water_edge_padding: float = _MTA_WATER_EDGE_PADDING,
    water_min_fragment_area: float = _MTA_WATER_MIN_FRAGMENT_AREA,
    water_snap_grid: float = _MTA_WATER_SNAP_GRID,
    water_boundary_tolerance: float = _MTA_WATER_BOUNDARY_TOLERANCE,
) -> MtaScene:
    if collision_mode not in {"model", "bounds-only"}:
        raise ValueError(
            f"unsupported collision mode {collision_mode!r}; use 'model' or 'bounds-only' "
            "(TrackCollisionPolygon-based modes were removed)"
        )
    if lod_mode not in {"auto", "required", "off"}:
        raise ValueError(f"unsupported LOD mode {lod_mode!r}; use 'auto', 'required', or 'off'")
    if (
        chunk_size <= 0 or lod_min_size <= 0 or lod_small_size <= 0 or lod_small_diagonal <= 0
        or lod_min_triangles < 0 or lod_repeated_triangles < 0 or lod_repeated_count < 1
        or water_road_padding < 0 or water_edge_padding < 0 or water_min_fragment_area < 0 or water_snap_grid < 0 or water_boundary_tolerance < 0
        or not 0.01 <= lod_target_ratio <= 1.0
    ):
        raise ValueError("chunk size and LOD minimum size must be positive; LOD target ratio must be 0.01..1.0")
    collision_rules = collision_rules or {}
    used_texture_names: set[str] = set()
    texture_names = {
        tex_hash: _texture_name(texture.name, tex_hash, used_texture_names)
        for tex_hash, texture in sorted(textures.textures.items())
    }
    alpha_decisions, alpha_usage = alpha_decisions_for_scene(scene, textures)
    texture_variants = _alpha_variant_names(texture_names, alpha_decisions)
    scenery_instances, placement_deduplication = _deduplicate_scenery_instances(scene.scenery_instances)
    placement_names = {instance.object_name for instance in scenery_instances}
    road_names = {obj.name for obj in scene.objects if obj.name.upper().startswith("RD_SECTION")}
    templates = {
        obj.name: obj
        for obj in scene.objects
        if obj.name not in road_names
        and (obj.name in placement_names or obj.chunk_offset in scene.scenery_template_offsets)
    }
    excluded_static_objects = [
        obj for obj in scene.objects
        if obj.name not in placement_names
        and obj.chunk_offset not in scene.scenery_template_offsets
        and _is_mta_visual_excluded(obj.name)
    ]
    static_objects = [
        obj for obj in scene.objects
        if (obj.name not in placement_names or obj.name in road_names)
        and obj.chunk_offset not in scene.scenery_template_offsets
        and not _is_mta_visual_excluded(obj.name)
    ]
    # Object names are not unique in HP2 (several RD_SECTION records share a
    # display name). Key this MTA-only cache by source chunk so one section
    # cannot silently overwrite another section's geometry.
    static_triangles = {
        obj.chunk_offset: list(_triangles_for_object(obj, bake_transform=True))
        for obj in static_objects
    }

    models: list[MtaModel] = []
    placements: list[MtaPlacement] = []
    road_source_objects = [obj for obj in static_objects if obj.name.upper().startswith("RD_SECTION")]
    road_split_sources: list[dict[str, Any]] = []
    road_degenerate_faces = 0
    max_col3_coordinate = 0.0
    mixed_render_models_split = 0
    blend_companion_models = 0
    road_models: list[MtaModel] = []
    lod_candidate_records: list[dict[str, Any]] = []
    lod_decisions: list[dict[str, Any]] = []
    large_scenery_promoted: list[dict[str, Any]] = []
    spatial_chunks_before = 0
    spatial_chunks_after = 0
    blend_only_lod_excluded = 0
    logical_pivot_errors: list[float] = []

    static_offsets = {obj.chunk_offset for obj in static_objects}
    for obj in scene.objects:
        # WATER and SKYDOME are handled by dedicated world-scene paths and
        # must not enter the LOD policy/report at all.
        if obj.chunk_offset in static_offsets or _lod_special_reason(obj.name) in {"water", "sky", None}:
            continue
        lod_decisions.append(_lod_decision(
            obj.name, list(_triangles_for_object(obj, bake_transform=False)), 0,
            lod_min_size=lod_min_size, small_size=lod_small_size,
            small_diagonal=lod_small_diagonal, min_triangles=lod_min_triangles,
            repeated_triangles=lod_repeated_triangles, repeated_count=lod_repeated_count,
        ))

    def emit_world_part(
        part: list[_Triangle], source_name: str, role: str, token: str, part_index: int,
        lod_enabled: bool | None = None,
    ) -> None:
        nonlocal mixed_render_models_split, blend_companion_models, blend_only_lod_excluded
        origin = _bounds_center(part)
        layers = _render_layers(part, alpha_decisions, alpha_usage, textures)
        if len(layers) > 1:
            mixed_render_models_split += 1
        base_layer = next(((name, values) for name, values in layers if name == "base"), None)
        lod_id = None
        eligible = lod_enabled if lod_enabled is not None else (
            role in {"road", "static_scenery"} and max(_triangle_extent(part)) >= lod_min_size
        )
        if eligible and lod_mode != "off" and base_layer is not None:
            detail_id = _model_id(track_id, "s", token, part_index)
            lod_id = _lod_model_id(detail_id)
        elif eligible and lod_mode != "off":
            blend_only_lod_excluded += 1
        unique_id = _unique_id(f"{track_id}:{token}:{part_index}")
        base_model: MtaModel | None = None
        for layer, layer_triangles in layers:
            is_companion = layer == "blend" and len(layers) > 1
            model_id = (
                _model_id(track_id, "a", f"{token}:blend", part_index)
                if is_companion
                else _model_id(track_id, "s", token, part_index)
            )
            cell = cell_for_xy(origin[0], origin[1], chunk_size)
            model = MtaModel(model_id, source_name, role, zone_name(track_id, cell), origin)
            _fill_model(model, layer_triangles, texture_names, texture_variants, alpha_decisions, alpha_usage, textures)
            _configure_model_render_state(model, layer)
            if is_companion:
                blend_companion_models += 1
            if vertex_colors == "off":
                model.colors.clear()
            model.lod_distance = _detail_lod_distance(part) if lod_id else _auto_lod(model)
            if role == "road" and layer == "base" and collision_mode == "model":
                nonlocal road_degenerate_faces, max_col3_coordinate
                road_degenerate_faces += _copy_visual_collision(model, collision_rules)
                max_col3_coordinate = max(
                    max_col3_coordinate,
                    max((abs(value) for vertex in model.collision_vertices for value in vertex), default=0.0),
                )
                road_models.append(model)
            if layer == "base":
                base_model = model
            models.append(model)
            placements.append(MtaPlacement(
                model_id, model.zone, "building", origin, (0.0, 0.0, 0.0), source_name,
                lod_id if layer == "base" else None,
                unique_id if layer == "base" else _unique_id(unique_id + ":blend"),
            ))
        if lod_id is not None and base_layer is not None and base_model is not None:
            source_model = base_model
            lod_model = MtaModel(
                lod_id, source_name, "lod", source_model.zone, origin,
                materials=list(source_model.materials), collision_kind="bounds",
                lod_distance=_generated_lod_distance(part), render_layer="lod",
                is_lod=True, lod_source_id=source_model.model_id, lod_target_ratio=lod_target_ratio,
            )
            models.append(lod_model)
            placements.append(MtaPlacement(
                lod_id, lod_model.zone, "building", origin, (0.0, 0.0, 0.0), source_name,
                None, unique_id,
            ))
            lod_candidate_records.append({
                "source": source_name,
                "detail_model": source_model.model_id,
                "lod_model": lod_id,
                "extent": list(_triangle_extent(part)),
                "triangles": len(base_layer[1]),
                "role": role,
            })
        logical_pivot_errors.append(_length(_local_bounds_center([
            tuple(vertex.position[axis] - origin[axis] for axis in range(3))
            for triangle in part for vertex in triangle.vertices
        ])))

    report_progress("Building static models", 0, len(static_objects), None)
    for static_index, obj in enumerate(static_objects, 1):
        report_progress("Building static models", static_index, len(static_objects), obj.name)
        triangles = static_triangles[obj.chunk_offset]
        is_road = obj.name.upper().startswith("RD_SECTION")
        role = "road" if is_road else "static_scenery"
        decision = _lod_decision(
            obj.name, triangles, 0, lod_min_size=lod_min_size, small_size=lod_small_size,
            small_diagonal=lod_small_diagonal, min_triangles=lod_min_triangles,
            repeated_triangles=lod_repeated_triangles, repeated_count=lod_repeated_count,
            road=is_road,
        )
        lod_decisions.append(decision)
        object_lod_enabled = lod_mode != "off" and decision["decision"] == "candidate"
        spatial_chunks_before += 1
        if object_lod_enabled:
            chunk_values = list(_spatial_clip_triangles(triangles, chunk_size).values())
            spatial_chunks_after += len(chunk_values)
        else:
            chunk_values = [triangles]
            spatial_chunks_after += 1
        parts = [part for chunk in chunk_values for part in _split_model_triangles(chunk, max_vertices, 255.0 if is_road else None)]
        if len(parts) > 1:
            road_split_sources.append(
                {
                    "source": obj.name,
                    "parts": len(parts),
                    "reason": "col3_coordinate_or_vertex_limit" if is_road else "vertex_limit",
                }
            )
        for part_index, part in enumerate(parts):
            emit_world_part(
                part, obj.name, role, f"static:{obj.chunk_offset}:{obj.name}:{part_index}", part_index,
                object_lod_enabled,
            )

    native_metrics = _native_collision_for_roads(
        scene,
        road_models,
        collision_rules,
        native_collision=native_collision,
        native_secondary=native_secondary,
        chunk_size=chunk_size,
    ) if collision_mode == "model" else _native_collision_for_roads(
        scene,
        road_models,
        collision_rules,
        native_collision="off",
        native_secondary=native_secondary,
        chunk_size=chunk_size,
    )
    if native_metrics["native_collision_source"] == "hp2_track_collision_polygons":
        road_degenerate_faces = 0
        max_col3_coordinate = max(
            max_col3_coordinate,
            native_metrics["max_native_col3_local_coordinate"],
        )

    warnings: list[str] = []
    water_quads: list[MtaWaterQuad] = []
    water_generation: list[dict[str, Any]] = []
    water_source_triangles = 0
    water_road_exclusion_triangles = []
    for polygon in scene.track_collision_polygons:
        if _native_collision_role(polygon) != "primary_road" or len(polygon.points_ps2) < 3:
            continue
        points = tuple((point.x, point.y, point.z) for point in polygon.points_ps2)
        water_road_exclusion_triangles.extend(
            (points[0], points[index], points[index + 1])
            for index in range(1, len(points) - 1)
        )
    excluded_scenery_placements: Counter[str] = Counter()
    variant_placements: dict[tuple[str, tuple[float, float, float]], list[tuple[Any, tuple[float, float, float], tuple[float, float, float]]]] = defaultdict(list)
    max_matrix_error = 0.0
    prop_pivot_offsets_before: list[float] = []
    prop_pivot_offsets_after: list[float] = []
    prop_placement_corrections: list[float] = []
    max_pivot_world_reconstruction_error = 0.0
    for instance in scenery_instances:
        if instance.object_name in road_names:
            # Streaming sections may reference road records as placements.
            # Roads are static source objects, not scenery props.
            excluded_scenery_placements[instance.object_name] += 1
            continue
        if _is_water_model(instance.object_name):
            water_object = templates.get(instance.object_name)
            if water_object is None:
                warnings.append(f"missing WATER template: {instance.object_name}")
            else:
                triangles = list(_triangles_for_object(water_object, bake_transform=False))
                water_source_triangles += len(triangles)
                generated_water, generation_report = _water_quads_for_triangles(
                    triangles,
                    instance.transform,
                    water_road_exclusion_triangles,
                    road_padding=water_road_padding,
                    edge_padding=water_edge_padding,
                    minimum_fragment_area=water_min_fragment_area,
                    snap_grid=water_snap_grid,
                    boundary_tolerance=water_boundary_tolerance,
                )
                water_quads.extend(generated_water)
                water_generation.append({"source": instance.object_name, **generation_report})
            excluded_scenery_placements[instance.object_name] += 1
            continue
        if _is_sky_model(instance.object_name):
            excluded_scenery_placements[instance.object_name] += 1
            continue
        if instance.object_name not in templates:
            warnings.append(f"missing scenery template: {instance.object_name}")
            continue
        try:
            position, rotation, scale, error = decompose_placement(instance.transform)
        except ValueError as exc:
            warnings.append(f"{instance.object_name}: {exc}")
            continue
        max_matrix_error = max(max_matrix_error, error)
        variant_placements[(instance.object_name, _scale_signature(scale))].append((instance, position, rotation))

    aggregate_water_simplified = len(water_quads) > _MTA_WATER_SAFE_QUAD_BUDGET
    if aggregate_water_simplified:
        water_quads = _coarse_water_quads(water_quads, _MTA_WATER_SAFE_QUAD_BUDGET)

    sorted_variants = sorted(variant_placements.items())
    report_progress("Building prop models", 0, len(sorted_variants), None)
    for variant_index, ((name, scale), entries) in enumerate(sorted_variants, 1):
        report_progress("Building prop models", variant_index, len(sorted_variants), name)
        obj = templates[name]
        triangles = _scaled_triangles(obj, scale)
        if not triangles:
            warnings.append(f"empty scenery template: {name}")
            continue
        extent = _triangle_extent(triangles)
        decision = _lod_decision(
            name, triangles, len(entries), lod_min_size=lod_min_size,
            small_size=lod_small_size, small_diagonal=lod_small_diagonal,
            min_triangles=lod_min_triangles, repeated_triangles=lod_repeated_triangles,
            repeated_count=lod_repeated_count,
        )
        decision["scale"] = list(scale)
        lod_decisions.append(decision)
        promoted_static = len(entries) == 1 and max(extent) >= lod_min_size
        if promoted_static:
            _instance, position, rotation = entries[0]
            world_triangles = _transform_triangles(triangles, position, rotation)
            chunks = _spatial_clip_triangles(world_triangles, chunk_size)
            spatial_chunks_before += 1
            spatial_chunks_after += len(chunks)
            large_scenery_promoted.append({
                "source": name,
                "extent": list(extent),
                "placements": 1,
                "chunks": len(chunks),
                "role": "static_scenery",
            })
            for chunk_index, (_cell, chunk_triangles) in enumerate(chunks.items()):
                for part_index, part in enumerate(_split_model_triangles(chunk_triangles, max_vertices, None)):
                    emit_world_part(
                        part, name, "static_scenery",
                        f"promoted:{name}:{scale}:{chunk_index}:{part_index}", chunk_index * 1000 + part_index,
                        True,
                    )
            continue
        layers = _render_layers(triangles, alpha_decisions, alpha_usage, textures)
        if len(layers) > 1:
            mixed_render_models_split += 1
        # All render companions share the full visual template pivot. This is
        # the streaming anchor GTA uses, so an alpha-only subset cannot load at
        # a different time or position from its opaque companion.
        origin = _bounds_center(triangles)
        prop_pivot_offsets_before.append(_length(origin))
        adjusted_entries = []
        sample_vertices = (
            triangles[0].vertices[0].position,
            triangles[len(triangles) // 2].vertices[1].position,
            triangles[-1].vertices[2].position,
        )
        for instance, position, rotation in entries:
            rotation_rows = compose_zxy_row(rotation)
            correction = _row_transform_offset(origin, rotation_rows)
            adjusted_position = tuple(position[axis] + correction[axis] for axis in range(3))
            prop_placement_corrections.append(_length(correction))
            for vertex in sample_vertices:
                old_world = tuple(
                    sum(vertex[source_axis] * rotation_rows[source_axis][axis] for source_axis in range(3)) + position[axis]
                    for axis in range(3)
                )
                local_vertex = tuple(vertex[axis] - origin[axis] for axis in range(3))
                new_world = tuple(
                    sum(local_vertex[source_axis] * rotation_rows[source_axis][axis] for source_axis in range(3)) + adjusted_position[axis]
                    for axis in range(3)
                )
                max_pivot_world_reconstruction_error = max(
                    max_pivot_world_reconstruction_error,
                    *(abs(old_world[axis] - new_world[axis]) for axis in range(3)),
                )
            adjusted_entries.append((instance, adjusted_position, rotation))

        counts = Counter(cell_for_xy(position[0], position[1], chunk_size) for _instance, position, _rotation in adjusted_entries)
        owner_cell = sorted(counts, key=lambda cell: (-counts[cell], cell))[0]
        for layer, layer_triangles in layers:
            is_companion = layer == "blend" and len(layers) > 1
            model_id = (
                _model_id(track_id, "a", f"prop:{name}:{scale}:blend", variant_index)
                if is_companion
                else _model_id(track_id, "p", f"{name}:{scale}", variant_index)
            )
            prop_lod_id = _lod_model_id(model_id) if decision["decision"] == "candidate" and lod_mode != "off" and not is_companion else None
            model = MtaModel(model_id, name, "prop", zone_name(track_id, owner_cell), origin)
            _fill_model(model, layer_triangles, texture_names, texture_variants, alpha_decisions, alpha_usage, textures)
            _configure_model_render_state(model, layer)
            if is_companion:
                blend_companion_models += 1
            prop_pivot_offsets_after.append(_length(_local_bounds_center(model.vertices)))
            if vertex_colors == "off":
                model.colors.clear()
            model.lod_distance = prop_lod_distance
            models.append(model)
            for entry_index, (instance, position, rotation) in enumerate(adjusted_entries):
                cell = cell_for_xy(position[0], position[1], chunk_size)
                unique_id = _unique_id(f"{track_id}:prop:{name}:{scale}:{entry_index}") if prop_lod_id and layer == "base" else None
                placements.append(MtaPlacement(model_id, zone_name(track_id, cell), "object", position, rotation, instance.object_name, prop_lod_id if layer == "base" else None, unique_id))
            if prop_lod_id is not None and layer == "base":
                lod_model = MtaModel(
                    prop_lod_id, name, "lod", zone_name(track_id, owner_cell), origin,
                    materials=list(model.materials), collision_kind="bounds",
                    lod_distance=_generated_lod_distance(triangles), render_layer="lod",
                    is_lod=True, lod_source_id=model.model_id, lod_target_ratio=lod_target_ratio,
                )
                models.append(lod_model)
                for entry_index, (_instance, position, rotation) in enumerate(adjusted_entries):
                    cell = cell_for_xy(position[0], position[1], chunk_size)
                    unique_id = _unique_id(f"{track_id}:prop:{name}:{scale}:{entry_index}")
                    placements.append(MtaPlacement(prop_lod_id, zone_name(track_id, cell), "object", position, rotation, name, None, unique_id))

    zones = sorted({placement.zone for placement in placements} | {model.zone for model in models})
    lod_model_ids = {model.model_id for model in models if model.is_lod}
    lod_placements = {
        (placement.model_id, placement.unique_id): placement
        for placement in placements if placement.model_id in lod_model_ids
    }
    lod_name_assignment_errors = [
        {"detail": record["detail_model"], "lod": record["lod_model"], "expected": _lod_model_id(record["detail_model"])}
        for record in lod_candidate_records
        if record["lod_model"] != _lod_model_id(record["detail_model"])
    ]
    unresolved_lod_parents = []
    max_lod_placement_difference = 0.0
    for placement in placements:
        if not placement.lod_parent:
            continue
        lod_placement = lod_placements.get((placement.lod_parent, placement.unique_id))
        if lod_placement is None:
            unresolved_lod_parents.append({"detail": placement.model_id, "lod": placement.lod_parent, "uniqueID": placement.unique_id})
            continue
        max_lod_placement_difference = max(
            max_lod_placement_difference,
            *(abs(placement.position[axis] - lod_placement.position[axis]) for axis in range(3)),
            *(abs(placement.rotation[axis] - lod_placement.rotation[axis]) for axis in range(3)),
        )
    if lod_name_assignment_errors or unresolved_lod_parents or max_lod_placement_difference > 1e-8:
        raise ValueError(
            f"invalid LOD assignment: names={lod_name_assignment_errors[:5]}, unresolved={unresolved_lod_parents[:5]}, "
            f"maximum transform difference={max_lod_placement_difference}"
        )
    source_bounds = _bounds(_source_visual_points(static_triangles, scene, templates))
    output_bounds = _bounds(_output_visual_points(models, placements))
    bounds_error = 0.0
    if source_bounds and output_bounds:
        bounds_error = max(
            abs(source_bounds[key][axis] - output_bounds[key][axis])
            for key in ("min", "max")
            for axis in range(3)
        )
    if max_pivot_world_reconstruction_error > 1e-5:
        raise ValueError(
            "prop pivot compensation changed sampled world vertices "
            f"(maximum error {max_pivot_world_reconstruction_error:.9g})"
        )
    if bounds_error > 0.01:
        raise ValueError(f"MTA scene bounds changed during optimization (maximum error {bounds_error:.9g})")
    source_expanded_triangles = sum(len(triangles) for triangles in static_triangles.values())
    template_triangle_counts = {name: sum(1 for _triangle in _triangles_for_object(obj, bake_transform=False)) for name, obj in templates.items()}
    source_expanded_triangles += sum(
        template_triangle_counts.get(instance.object_name, 0)
        for instance in scenery_instances
        if not _is_mta_visual_excluded(instance.object_name)
    )
    model_by_id = {model.model_id: model for model in models}
    output_expanded_triangles = sum(
        len(model_by_id[placement.model_id].faces)
        for placement in placements
    )
    referenced_texture_hashes = {material.texture_hash for model in models for material in model.materials if material.texture_hash is not None}
    referenced_texture_variants = {
        (material.texture_hash, material.alpha_mode)
        for model in models
        for material in model.materials
        if material.texture_hash is not None
    }
    texture_names = {tex_hash: name for tex_hash, name in texture_names.items() if tex_hash in referenced_texture_hashes}
    texture_variants = {
        key: name
        for key, name in texture_variants.items()
        if key in referenced_texture_variants and textures.get(key[0]) is not None
    }
    missing_texture_hashes = sorted(value for value in referenced_texture_hashes if value not in texture_names)
    warnings.extend(f"missing texture hash: 0x{value:08x}" for value in missing_texture_hashes)
    report = {
        "source_objects": len(scene.objects),
        "static_source_objects": len(static_objects),
        "source_placements": len(scene.scenery_instances),
        **placement_deduplication,
        "excluded_static_models": [obj.name for obj in excluded_static_objects],
        "excluded_scenery_placements": dict(sorted(excluded_scenery_placements.items())),
        "output_placements": len(placements),
        "prop_placements": sum(placement.element_type == "object" for placement in placements),
        "static_models": sum(model.kind in {"road", "static", "static_scenery"} for model in models),
        "road_source_models": len(road_source_objects),
        "road_models": sum(model.kind == "road" for model in models),
        "road_split_sources": road_split_sources,
        "prop_models": sum(model.kind == "prop" for model in models),
        "mixed_render_models_split": mixed_render_models_split,
        "blend_companion_models": blend_companion_models,
        "draw_last_models": sum(model.draw_last for model in models),
        "no_zbuffer_write_models": sum(model.no_zbuffer_write for model in models),
        "additive_models": sum(model.additive for model in models),
        "collision_models": 0,
        "models": len(models),
        "zones": len(zones),
        "textures": len(texture_names),
        "visual_triangles": sum(len(model.faces) for model in models),
        "source_expanded_triangles": source_expanded_triangles,
        "output_expanded_triangles": output_expanded_triangles,
        # Spatial clipping legitimately increases triangle count. World-bounds
        # and per-cell coverage validation are the loss checks in this mode.
        "triangle_loss": bounds_error > 0.01,
        "geometry_reuse_count": max(0, sum(placement.element_type == "object" for placement in placements) - sum(model.kind == "prop" for model in models)),
        "materials": len(referenced_texture_hashes),
        "missing_texture_hashes": [f"0x{value:08x}" for value in missing_texture_hashes],
        "collision_triangles": sum(len(model.collision_faces) for model in models),
        "mesh_col_models": sum(model.collision_kind == "mesh" for model in models),
        "bounds_only_col_models": sum(model.collision_kind == "bounds" for model in models),
        "road_degenerate_collision_faces": road_degenerate_faces,
        "max_col3_local_coordinate": max_col3_coordinate,
        "track_collision_input_polygons": len(scene.track_collision_polygons),
        "track_collision_used": native_metrics["native_collision_source"] == "hp2_track_collision_polygons",
        "max_transform_error": max_matrix_error,
        "source_bounds": source_bounds,
        "output_bounds": output_bounds,
        "bounds_error": bounds_error,
        "prop_pivot_offset_before": _offset_stats(prop_pivot_offsets_before),
        "prop_pivot_offset_after": _offset_stats(prop_pivot_offsets_after),
        "prop_recentered_models": sum(value > 0.01 for value in prop_pivot_offsets_before),
        "max_prop_placement_correction": max(prop_placement_corrections, default=0.0),
        "max_pivot_world_reconstruction_error": max_pivot_world_reconstruction_error,
        "max_model_vertices": max((len(model.vertices) for model in models), default=0),
        "missing_templates": sum(message.startswith("missing scenery template") for message in warnings),
        "chunk_size": chunk_size,
        "collision_mode": collision_mode,
        "native_collision": native_collision,
        "native_secondary": native_secondary,
        "lod_mode": lod_mode,
        "lod_min_size": lod_min_size,
        "lod_small_size": lod_small_size,
        "lod_small_diagonal": lod_small_diagonal,
        "lod_min_triangles": lod_min_triangles,
        "lod_repeated_triangles": lod_repeated_triangles,
        "lod_repeated_count": lod_repeated_count,
        "lod_target_ratio": lod_target_ratio,
        "scene_role_counts": dict(Counter(model.kind for model in models if not model.is_lod)),
        "large_props_promoted_to_static": large_scenery_promoted,
        "lod_candidate_models": lod_candidate_records,
        "lod_decisions": lod_decisions,
        "lod_candidates": sum(item["decision"] == "candidate" for item in lod_decisions),
        "lod_generated": sum(model.is_lod for model in models),
        "lod_skipped_small": sum(item["decision"] == "skip" and item["category"] in {"small_prop", "small_vegetation"} for item in lod_decisions),
        "lod_skipped_special": sum(item["decision"] == "skip" and item["category"] == "special" for item in lod_decisions),
        "lod_skipped_low_complexity": sum(item["decision"] == "skip" and item["category"] == "low_complexity" for item in lod_decisions),
        "lod_models": sum(model.is_lod for model in models),
        "blend_only_lod_excluded": blend_only_lod_excluded,
        "spatial_chunks_before": spatial_chunks_before,
        "spatial_chunks_after": spatial_chunks_after,
        "max_logical_pivot_error": max(logical_pivot_errors, default=0.0),
        "unresolved_lod_parents": unresolved_lod_parents,
        "lod_name_assignment_errors": lod_name_assignment_errors,
        "lod_naming_rule": "replace first 3 detail-model characters with LOD",
        "max_lod_placement_difference": max_lod_placement_difference,
        "max_chunk_xy_extent": max((max(_vertices_extent(model.vertices)[:2]) for model in models if model.faces), default=0.0),
        **native_metrics,
        "water_source_triangles": water_source_triangles,
        "water_quads": len(water_quads),
        "water_generation": water_generation,
        "water_budget_simplified": aggregate_water_simplified,
        "alpha": {
            **alpha_diagnostics(alpha_decisions, textures),
            "surface_modes": dict(
                Counter(
                    model.materials[material_index].alpha_mode
                    for model in models
                    for material_index in model.face_materials
                )
            ),
            "material_modes": dict(Counter(material.alpha_mode for model in models for material in model.materials)),
            "txd_variant_modes": dict(Counter(mode for _texture_hash, mode in texture_variants)),
            "txd_variants": len(texture_variants),
        },
    }
    return MtaScene(
        track_id, resource_name, models, placements, zones, texture_names, warnings, report,
        water_quads, texture_variants,
    )
