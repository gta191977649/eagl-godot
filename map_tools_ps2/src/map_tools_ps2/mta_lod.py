from __future__ import annotations

import ctypes
import math
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any


_ATTEMPTS = ((0.12, 0.06), (0.20, 0.035), (0.32, 0.02), (0.48, 0.01), (0.65, 0.004))
_SIMPLIFY_SPARSE = 1 << 1
_SIMPLIFY_REGULARIZE = 1 << 4


def _load_meshoptimizer() -> Any:
    path = Path(__file__).with_name("_native") / "meshoptimizer.dll"
    if not path.is_file():
        raise RuntimeError(f"Eagle LOD meshoptimizer runtime is missing: {path}")
    library = ctypes.CDLL(str(path))
    function = library.meshopt_simplifyWithAttributes
    function.restype = ctypes.c_size_t
    function.argtypes = [
        ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint), ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_float), ctypes.c_size_t, ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_float), ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_float), ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_ubyte), ctypes.c_size_t, ctypes.c_float,
        ctypes.c_uint, ctypes.POINTER(ctypes.c_float),
    ]
    return function


def _position_key(value: tuple[float, float, float]) -> tuple[float, float, float]:
    return tuple(round(float(component), 7) for component in value)  # type: ignore[return-value]


def _face_normal(a, b, c) -> tuple[float, float, float]:
    ab = tuple(b[axis] - a[axis] for axis in range(3))
    ac = tuple(c[axis] - a[axis] for axis in range(3))
    value = (
        ab[1] * ac[2] - ab[2] * ac[1],
        ab[2] * ac[0] - ab[0] * ac[2],
        ab[0] * ac[1] - ab[1] * ac[0],
    )
    length = math.sqrt(sum(component * component for component in value))
    return tuple(component / length for component in value) if length > 1e-12 else (0.0, 0.0, 1.0)  # type: ignore[return-value]


def _indexed_source(model: Any) -> dict[str, Any]:
    vertices, uvs, colors, faces, materials = [], [], [], [], []
    lookup: dict[tuple[Any, ...], int] = {}
    normal_sums: list[list[float]] = []
    for face, material in zip(model.faces, model.face_materials):
        source_positions = [model.vertices[index] for index in face]
        normal = _face_normal(*source_positions)
        indexed_face = []
        for source_index in face:
            position = tuple(float(value) for value in model.vertices[source_index])
            uv = tuple(float(value) for value in model.uvs[source_index]) if model.uvs else (0.0, 0.0)
            color = tuple(int(value) for value in model.colors[source_index]) if model.colors else (255, 255, 255, 255)
            # Material, UV and prelight seams remain separate vertices, matching
            # Eagle Editor's RawMesh representation.
            key = (_position_key(position), tuple(round(value, 7) for value in uv), color, int(material))
            index = lookup.get(key)
            if index is None:
                index = lookup[key] = len(vertices)
                vertices.append(position)
                uvs.append(uv)
                colors.append(color)
                normal_sums.append([0.0, 0.0, 0.0])
            for axis in range(3):
                normal_sums[index][axis] += normal[axis]
            indexed_face.append(index)
        if len(set(indexed_face)) == 3:
            faces.append(tuple(indexed_face))
            materials.append(int(material))
    normals = []
    for value in normal_sums:
        length = math.sqrt(sum(component * component for component in value))
        normals.append(tuple(component / length for component in value) if length > 1e-12 else (0.0, 0.0, 1.0))
    return {"vertices": vertices, "uvs": uvs, "colors": colors, "normals": normals, "faces": faces, "materials": materials}


def _triangle_components(source: dict[str, Any], *, by_material: bool) -> list[list[int]]:
    faces = source["faces"]
    parents = list(range(len(faces)))

    def root(value: int) -> int:
        while parents[value] != value:
            parents[value] = parents[parents[value]]
            value = parents[value]
        return value

    first_at_position: dict[tuple[Any, ...], int] = {}
    for face_index, face in enumerate(faces):
        material = source["materials"][face_index] if by_material else None
        for vertex_index in face:
            key = (material, _position_key(source["vertices"][vertex_index]))
            other = first_at_position.setdefault(key, face_index)
            left, right = root(face_index), root(other)
            if left != right:
                parents[right] = left
    groups: dict[tuple[int, int | None], list[int]] = defaultdict(list)
    for face_index, face in enumerate(faces):
        group_material = source["materials"][face_index] if by_material else None
        groups[(root(face_index), group_material)].extend(face)
    return list(groups.values())


def _support_positions(source: dict[str, Any], indices: list[int]) -> set[tuple[float, float, float]]:
    points = [source["vertices"][index] for index in indices]
    if not points:
        return set()
    minimum = tuple(min(point[axis] for point in points) for axis in range(3))
    maximum = tuple(max(point[axis] for point in points) for axis in range(3))
    center = tuple((minimum[axis] + maximum[axis]) * 0.5 for axis in range(3))
    extent = tuple(max(maximum[axis] - minimum[axis], 1e-9) for axis in range(3))
    normalized = [tuple((point[axis] - center[axis]) / extent[axis] for axis in range(3)) for point in points]
    result = set()
    for dx in (-1, 0, 1):
        for dy in (-1, 0, 1):
            for dz in (-1, 0, 1):
                if dx == dy == dz == 0:
                    continue
                index = max(range(len(points)), key=lambda item: normalized[item][0] * dx + normalized[item][1] * dy + normalized[item][2] * dz)
                result.add(_position_key(points[index]))
    return result


def _locked_positions(source: dict[str, Any]) -> set[tuple[float, float, float]]:
    edge_counts: Counter[tuple[Any, Any]] = Counter()
    for face in source["faces"]:
        for first, second in ((face[0], face[1]), (face[1], face[2]), (face[2], face[0])):
            edge = tuple(sorted((_position_key(source["vertices"][first]), _position_key(source["vertices"][second]))))
            edge_counts[edge] += 1
    result = {point for edge, count in edge_counts.items() if count == 1 for point in edge}
    for component in _triangle_components(source, by_material=True):
        result.update(_support_positions(source, component))
    return result


def _simplify_once(source: dict[str, Any], ratio: float, error: float) -> dict[str, Any]:
    simplify = _load_meshoptimizer()
    vertices = source["vertices"]
    position_values = [component for vertex in vertices for component in vertex]
    attribute_values = [
        component
        for normal, uv in zip(source["normals"], source["uvs"])
        for component in (*normal, *uv)
    ]
    positions = (ctypes.c_float * len(position_values))(*position_values)
    attributes = (ctypes.c_float * len(attribute_values))(*attribute_values)
    weights = (ctypes.c_float * 5)(0.15, 0.15, 0.15, 0.035, 0.035)
    locked = _locked_positions(source)
    locks = (ctypes.c_ubyte * len(vertices))(*[int(_position_key(vertex) in locked) for vertex in vertices])
    output_faces: list[tuple[int, int, int]] = []
    for component in _triangle_components(source, by_material=False):
        if len(component) < 12:
            output_faces.extend(tuple(component[index:index + 3]) for index in range(0, len(component), 3))
            continue
        source_indices = (ctypes.c_uint * len(component))(*component)
        destination = (ctypes.c_uint * len(component))()
        target = max(3, math.ceil((len(component) // 3) * ratio) * 3)
        result_error = ctypes.c_float()
        count = simplify(
            destination, source_indices, len(component), positions, len(vertices), 12,
            attributes, 20, weights, 5, locks, target, error,
            _SIMPLIFY_SPARSE | _SIMPLIFY_REGULARIZE, ctypes.byref(result_error),
        )
        values = list(destination[:count]) if count >= 3 and count % 3 == 0 else component
        output_faces.extend(tuple(values[index:index + 3]) for index in range(0, len(values), 3))

    exact = {tuple(sorted(face)): material for face, material in zip(source["faces"], source["materials"])}
    votes: list[Counter[int]] = [Counter() for _ in vertices]
    for face, material in zip(source["faces"], source["materials"]):
        for index in face:
            votes[index][material] += 1
    output_materials = []
    for face in output_faces:
        material = exact.get(tuple(sorted(face)))
        if material is None:
            combined: Counter[int] = Counter()
            for index in face:
                combined.update(votes[index])
            material = min(combined, key=lambda value: (-combined[value], value)) if combined else 0
        output_materials.append(material)

    used = sorted({index for face in output_faces for index in face})
    remap = {old: new for new, old in enumerate(used)}
    return {
        "vertices": [vertices[index] for index in used],
        "uvs": [source["uvs"][index] for index in used],
        "colors": [source["colors"][index] for index in used],
        "normals": [source["normals"][index] for index in used],
        "faces": [tuple(remap[index] for index in face) for face in output_faces],
        "materials": output_materials,
    }


def _area(model: dict[str, Any]) -> float:
    return sum(
        math.sqrt(sum(component * component for component in _cross(
            model["vertices"][face[0]], model["vertices"][face[1]], model["vertices"][face[2]]
        ))) * 0.5
        for face in model["faces"]
    )


def _cross(a, b, c):
    ab = tuple(b[axis] - a[axis] for axis in range(3))
    ac = tuple(c[axis] - a[axis] for axis in range(3))
    return (
        ab[1] * ac[2] - ab[2] * ac[1],
        ab[2] * ac[0] - ab[0] * ac[2],
        ab[0] * ac[1] - ab[1] * ac[0],
    )


def _validate(source: dict[str, Any], candidate: dict[str, Any], material_count: int) -> tuple[bool, dict[str, Any]]:
    if not candidate["faces"] or len(candidate["vertices"]) > 65535:
        return False, {"reason": "empty geometry or DFF vertex limit"}
    source_min = tuple(min(vertex[axis] for vertex in source["vertices"]) for axis in range(3))
    source_max = tuple(max(vertex[axis] for vertex in source["vertices"]) for axis in range(3))
    candidate_min = tuple(min(vertex[axis] for vertex in candidate["vertices"]) for axis in range(3))
    candidate_max = tuple(max(vertex[axis] for vertex in candidate["vertices"]) for axis in range(3))
    scale = max(max(source_max[axis] - source_min[axis] for axis in range(3)), 1e-5)
    bounds_error = max(
        *(abs(candidate_min[axis] - source_min[axis]) for axis in range(3)),
        *(abs(candidate_max[axis] - source_max[axis]) for axis in range(3)),
    ) / scale
    area_ratio = _area(candidate) / max(_area(source), 1e-8)
    valid_indices = all(0 <= index < len(candidate["vertices"]) for face in candidate["faces"] for index in face)
    valid_materials = all(0 <= material < material_count for material in candidate["materials"])
    finite_uvs = all(math.isfinite(value) for uv in candidate["uvs"] for value in uv)
    valid = valid_indices and valid_materials and finite_uvs and bounds_error <= 0.005 and 0.55 <= area_ratio <= 1.35
    return valid, {
        "bounds_error": bounds_error,
        "area_ratio": area_ratio,
        "valid_indices": valid_indices,
        "valid_materials": valid_materials,
        "finite_uvs": finite_uvs,
        "reason": None if valid else "Eagle silhouette/material/UV validation failed",
    }


def generate_eagle_lod(source_model: Any, lod_model: Any) -> tuple[bool, dict[str, Any]]:
    source = _indexed_source(source_model)
    attempts = []
    requested = float(lod_model.lod_target_ratio)
    ratios = [(requested, 0.06)] + [value for value in _ATTEMPTS if value[0] != requested]
    for ratio, error in ratios:
        candidate = _simplify_once(source, ratio, error)
        valid, metrics = _validate(source, candidate, len(source_model.materials))
        attempt = {
            "ratio": ratio, "error": error, "vertices": len(candidate["vertices"]),
            "triangles": len(candidate["faces"]), "valid": valid, **metrics,
        }
        attempts.append(attempt)
        if not valid:
            continue
        lod_model.vertices = candidate["vertices"]
        lod_model.uvs = candidate["uvs"] if source_model.uvs else []
        lod_model.colors = candidate["colors"] if source_model.colors else []
        lod_model.faces = candidate["faces"]
        lod_model.face_materials = candidate["materials"]
        lod_model.materials = list(source_model.materials)
        lod_model.collision_kind = "bounds"
        texture_refs = sorted({material.texture_name for material in lod_model.materials if material.texture_name})
        return True, {
            "model": lod_model.model_id,
            "source": source_model.model_id,
            "status": "generated",
            "algorithm": "MTA-Eagle-Editor meshoptimizer 0.6.2",
            "ratio": ratio,
            "source_vertices": len(source_model.vertices),
            "source_triangles": len(source_model.faces),
            "output_vertices": len(lod_model.vertices),
            "output_triangles": len(lod_model.faces),
            "texture_strategy": "reuse source track TXD with exact material names and UVs",
            "texture_references": texture_refs,
            "attempts": attempts,
        }
    return False, {
        "model": lod_model.model_id,
        "source": source_model.model_id,
        "status": "skipped",
        "algorithm": "MTA-Eagle-Editor meshoptimizer 0.6.2",
        "ratio": None,
        "source_vertices": len(source_model.vertices),
        "source_triangles": len(source_model.faces),
        "output_vertices": 0,
        "output_triangles": 0,
        "texture_strategy": "reuse source track TXD with exact material names and UVs",
        "texture_references": [],
        "attempts": attempts,
    }
