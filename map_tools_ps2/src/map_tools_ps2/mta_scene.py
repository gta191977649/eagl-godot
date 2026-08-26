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

from .binary import Matrix4, Vec3, transform_point
from .glb_writer import _decode_vif_color_5551, _indices_for_block
from .material_alpha import MaterialAlphaDecision, alpha_decisions_for_scene, alpha_diagnostics, decide_material_alpha
from .model import MeshObject, Scene, SceneryInstance, transformed_block_vertices


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
    lod_distance: float = 300.0
    render_layer: str = "base"
    draw_last: bool = False
    additive: bool = False
    no_zbuffer_write: bool = False


@dataclass(frozen=True)
class MtaPlacement:
    model_id: str
    zone: str
    element_type: str
    position: tuple[float, float, float]
    rotation: tuple[float, float, float]
    source_name: str


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
_SKY_RE = re.compile(r"SKYDOME", re.IGNORECASE)


def _is_water_model(name: str) -> bool:
    return name.strip().upper() == "WATER"


def _is_sky_model(name: str) -> bool:
    return bool(_SKY_RE.search(name))


def _is_mta_visual_excluded(name: str) -> bool:
    return _is_water_model(name) or _is_sky_model(name)


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
    if not model.vertices:
        return 500.0
    radius = max(math.sqrt(x * x + y * y + z * z) for x, y, z in model.vertices)
    return min(2000.0, max(500.0, radius * 2.0 + 200.0))


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


def _water_quads_for_triangles(triangles: list[_Triangle], transform: Matrix4) -> list[MtaWaterQuad]:
    """Convert a flat triangle mesh to exact MTA water patches."""
    edge_owners: dict[tuple[tuple[float, float, float], tuple[float, float, float]], list[int]] = defaultdict(list)
    positions = [tuple(vertex.position for vertex in triangle.vertices) for triangle in triangles]
    for triangle_index, points in enumerate(positions):
        for first, second in ((0, 1), (1, 2), (2, 0)):
            edge_owners[tuple(sorted((_point_key(points[first]), _point_key(points[second]))))].append(triangle_index)

    paired: set[int] = set()
    local_quads: list[tuple[tuple[float, float, float], ...]] = []
    for edge, owners in sorted(edge_owners.items()):
        if len(owners) != 2 or owners[0] in paired or owners[1] in paired:
            continue
        first_index, second_index = owners
        first_points = positions[first_index]
        second_points = positions[second_index]
        shared = set(edge)
        first_unique = next((point for point in first_points if _point_key(point) not in shared), None)
        second_unique = next((point for point in second_points if _point_key(point) not in shared), None)
        if first_unique is None or second_unique is None:
            continue
        shared_points = [
            next(point for point in first_points + second_points if _point_key(point) == key)
            for key in edge
        ]
        local_quads.append((first_unique, shared_points[0], shared_points[1], second_unique))
        paired.update(owners)

    for triangle_index, points in enumerate(positions):
        if triangle_index in paired:
            continue
        midpoint = tuple((points[1][axis] + points[2][axis]) * 0.5 for axis in range(3))
        local_quads.append((points[0], points[1], points[2], midpoint))

    result: list[MtaWaterQuad] = []
    for quad in local_quads:
        world = []
        for point in quad:
            transformed = transform_point(Vec3(*point), transform)
            world.append((transformed.x, transformed.y, transformed.z))
        result.append(MtaWaterQuad(tuple(world)))  # type: ignore[arg-type]
    return result


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
    prop_lod_distance: float = 300.0,
    vertex_colors: str = "always",
    collision_rules: dict[str, Any] | None = None,
) -> MtaScene:
    if collision_mode not in {"model", "bounds-only"}:
        raise ValueError(
            f"unsupported collision mode {collision_mode!r}; use 'model' or 'bounds-only' "
            "(TrackCollisionPolygon-based modes were removed)"
        )
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
    templates = {obj.name: obj for obj in scene.objects if obj.name in placement_names or obj.chunk_offset in scene.scenery_template_offsets}
    excluded_static_objects = [
        obj for obj in scene.objects
        if obj.name not in placement_names
        and obj.chunk_offset not in scene.scenery_template_offsets
        and _is_mta_visual_excluded(obj.name)
    ]
    static_objects = [
        obj for obj in scene.objects
        if obj.name not in placement_names
        and obj.chunk_offset not in scene.scenery_template_offsets
        and not _is_mta_visual_excluded(obj.name)
    ]
    static_triangles = {
        obj.name: list(_triangles_for_object(obj, bake_transform=True))
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
    for obj in static_objects:
        triangles = static_triangles[obj.name]
        is_road = obj.name.upper().startswith("RD_SECTION")
        parts = _split_model_triangles(triangles, max_vertices, 255.0 if is_road else None)
        if len(parts) > 1:
            road_split_sources.append(
                {
                    "source": obj.name,
                    "parts": len(parts),
                    "reason": "col3_coordinate_or_vertex_limit" if is_road else "vertex_limit",
                }
            )
        for part_index, part in enumerate(parts):
            layers = _render_layers(part, alpha_decisions, alpha_usage, textures)
            if len(layers) > 1:
                mixed_render_models_split += 1
            for layer, layer_triangles in layers:
                is_companion = layer == "blend" and len(layers) > 1
                origin = _bounds_center(layer_triangles)
                cell = cell_for_xy(origin[0], origin[1], chunk_size)
                model_id = (
                    _model_id(track_id, "a", f"static:{obj.name}:{part_index}:blend", part_index)
                    if is_companion
                    else _model_id(track_id, "s", f"{obj.name}:{part_index}", part_index)
                )
                model = MtaModel(model_id, obj.name, "road" if is_road else "static", zone_name(track_id, cell), origin)
                _fill_model(model, layer_triangles, texture_names, texture_variants, alpha_decisions, alpha_usage, textures)
                _configure_model_render_state(model, layer)
                if is_companion:
                    blend_companion_models += 1
                if vertex_colors == "off":
                    model.colors.clear()
                model.lod_distance = _auto_lod(model)
                if is_road and collision_mode == "model":
                    road_degenerate_faces += _copy_visual_collision(model, collision_rules)
                    max_col3_coordinate = max(
                        max_col3_coordinate,
                        max((abs(value) for vertex in model.collision_vertices for value in vertex), default=0.0),
                    )
                models.append(model)
                placements.append(MtaPlacement(model_id, model.zone, "building", origin, (0.0, 0.0, 0.0), obj.name))

    warnings: list[str] = []
    water_quads: list[MtaWaterQuad] = []
    water_source_triangles = 0
    excluded_scenery_placements: Counter[str] = Counter()
    variant_placements: dict[tuple[str, tuple[float, float, float]], list[tuple[Any, tuple[float, float, float], tuple[float, float, float]]]] = defaultdict(list)
    max_matrix_error = 0.0
    prop_pivot_offsets_before: list[float] = []
    prop_pivot_offsets_after: list[float] = []
    prop_placement_corrections: list[float] = []
    max_pivot_world_reconstruction_error = 0.0
    for instance in scenery_instances:
        if _is_water_model(instance.object_name):
            water_object = templates.get(instance.object_name)
            if water_object is None:
                warnings.append(f"missing WATER template: {instance.object_name}")
            else:
                triangles = list(_triangles_for_object(water_object, bake_transform=False))
                water_source_triangles += len(triangles)
                water_quads.extend(_water_quads_for_triangles(triangles, instance.transform))
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

    for variant_index, ((name, scale), entries) in enumerate(sorted(variant_placements.items())):
        obj = templates[name]
        triangles = _scaled_triangles(obj, scale)
        if not triangles:
            warnings.append(f"empty scenery template: {name}")
            continue
        layers = _render_layers(triangles, alpha_decisions, alpha_usage, textures)
        if len(layers) > 1:
            mixed_render_models_split += 1
        for layer, layer_triangles in layers:
            is_companion = layer == "blend" and len(layers) > 1
            origin = _bounds_center(layer_triangles)
            prop_pivot_offsets_before.append(_length(origin))
            adjusted_entries = []
            sample_vertices = (
                layer_triangles[0].vertices[0].position,
                layer_triangles[len(layer_triangles) // 2].vertices[1].position,
                layer_triangles[-1].vertices[2].position,
            )
            for instance, position, rotation in entries:
                rotation_rows = compose_zxy_row(rotation)
                correction = _row_transform_offset(origin, rotation_rows)
                adjusted_position = tuple(position[axis] + correction[axis] for axis in range(3))
                prop_placement_corrections.append(_length(correction))
                for vertex in sample_vertices:
                    old_world = tuple(
                        sum(vertex[source_axis] * rotation_rows[source_axis][axis] for source_axis in range(3))
                        + position[axis]
                        for axis in range(3)
                    )
                    local_vertex = tuple(vertex[axis] - origin[axis] for axis in range(3))
                    new_world = tuple(
                        sum(local_vertex[source_axis] * rotation_rows[source_axis][axis] for source_axis in range(3))
                        + adjusted_position[axis]
                        for axis in range(3)
                    )
                    max_pivot_world_reconstruction_error = max(
                        max_pivot_world_reconstruction_error,
                        *(abs(old_world[axis] - new_world[axis]) for axis in range(3)),
                    )
                adjusted_entries.append((instance, adjusted_position, rotation))

            counts = Counter(
                cell_for_xy(position[0], position[1], chunk_size)
                for _instance, position, _rotation in adjusted_entries
            )
            owner_cell = sorted(counts, key=lambda cell: (-counts[cell], cell))[0]
            model_id = (
                _model_id(track_id, "a", f"prop:{name}:{scale}:blend", variant_index)
                if is_companion
                else _model_id(track_id, "p", f"{name}:{scale}", variant_index)
            )
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
            for instance, position, rotation in adjusted_entries:
                cell = cell_for_xy(position[0], position[1], chunk_size)
                placements.append(MtaPlacement(model_id, zone_name(track_id, cell), "object", position, rotation, instance.object_name))

    zones = sorted({placement.zone for placement in placements} | {model.zone for model in models})
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
        "static_models": sum(model.kind in {"road", "static"} for model in models),
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
        "triangle_loss": source_expanded_triangles != output_expanded_triangles,
        "geometry_reuse_count": max(0, sum(placement.element_type == "object" for placement in placements) - sum(model.kind == "prop" for model in models)),
        "materials": len(referenced_texture_hashes),
        "missing_texture_hashes": [f"0x{value:08x}" for value in missing_texture_hashes],
        "collision_triangles": sum(len(model.collision_faces) for model in models),
        "mesh_col_models": sum(model.collision_kind == "mesh" for model in models),
        "bounds_only_col_models": sum(model.collision_kind == "bounds" for model in models),
        "road_degenerate_collision_faces": road_degenerate_faces,
        "max_col3_local_coordinate": max_col3_coordinate,
        "track_collision_input_polygons": len(scene.track_collision_polygons),
        "track_collision_used": False,
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
        "water_source_triangles": water_source_triangles,
        "water_quads": len(water_quads),
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
