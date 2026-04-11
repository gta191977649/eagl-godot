from __future__ import annotations

import json
import struct
from pathlib import Path
from typing import Any

from .binary import Vec3
from .model import DecodedBlock, Scene, transformed_block_vertices
from .textures import TextureLibrary


def _ps2_to_gltf_vec3(vertex: Vec3) -> Vec3:
    return Vec3(vertex.x, vertex.z, -vertex.y)


def _ps2_to_gltf_vertices(vertices: tuple[Vec3, ...]) -> tuple[Vec3, ...]:
    return tuple(_ps2_to_gltf_vec3(vertex) for vertex in vertices)


def _strip_indices(start_index: int, count: int) -> list[int]:
    indices: list[int] = []
    for i in range(count - 2):
        a = start_index + i
        b = start_index + i + 1
        c = start_index + i + 2
        face = (a, c, b) if i & 1 else (a, b, c)
        if len({face[0], face[1], face[2]}) == 3:
            indices.extend(face)
    return indices


def _strip_indices_for_vertices(vertices: tuple[Vec3, ...], object_name: str = "") -> list[int]:
    if len(vertices) < 3:
        return []

    boundary = _prop_tail_restart_boundary(vertices, object_name)
    if boundary is not None:
        return _strip_indices_with_boundaries(vertices, {boundary})

    indices = _strip_segment_indices(vertices, 0, len(vertices))
    boundaries = _strip_restart_boundaries(vertices) | _strip_duplicate_pair_boundaries(vertices)
    if not boundaries:
        return indices

    segmented_indices = _strip_indices_with_boundaries(vertices, boundaries)
    if _should_use_segmented_strip(vertices, indices, segmented_indices):
        return segmented_indices
    return indices


def _triangle_list_indices(count: int) -> list[int]:
    indices: list[int] = []
    for start_index in range(0, count - (count % 3), 3):
        indices.extend((start_index, start_index + 1, start_index + 2))
    return indices


def _quad_batch_indices(count: int) -> list[int]:
    indices: list[int] = []
    for start_index in range(0, count - (count % 4), 4):
        indices.extend((start_index, start_index + 1, start_index + 2))
        indices.extend((start_index + 1, start_index + 3, start_index + 2))
    return indices


def _strip_segment_indices(vertices: tuple[Vec3, ...], start_index: int, count: int) -> list[int]:
    indices: list[int] = []
    for i in range(count - 2):
        a = start_index + i
        b = start_index + i + 1
        c = start_index + i + 2
        face = (a, c, b) if i & 1 else (a, b, c)
        if not _is_degenerate_triangle(vertices[face[0]], vertices[face[1]], vertices[face[2]]):
            indices.extend(face)
    return indices


def _strip_indices_with_boundaries(vertices: tuple[Vec3, ...], boundaries: set[int]) -> list[int]:
    indices: list[int] = []
    start_index = 0
    for boundary in sorted(boundary for boundary in boundaries if 0 < boundary < len(vertices)):
        count = boundary - start_index
        if count >= 3:
            indices.extend(_strip_segment_indices(vertices, start_index, count))
        start_index = boundary
    if len(vertices) - start_index >= 3:
        indices.extend(_strip_segment_indices(vertices, start_index, len(vertices) - start_index))
    return indices


def _prop_tail_restart_boundary(vertices: tuple[Vec3, ...], object_name: str) -> int | None:
    if not _is_prop_object(object_name):
        return None
    if _has_degenerate_strip_triangles(vertices):
        return None

    boundaries = sorted(_strip_restart_boundaries(vertices))
    if len(boundaries) != 1:
        return None

    boundary = boundaries[0]
    tail = len(vertices) - boundary
    if tail > 4:
        return None
    return boundary


def _strip_restart_boundaries(vertices: tuple[Vec3, ...]) -> set[int]:
    full_distances = [_vertex_distance(vertices[i], vertices[i + 1]) for i in range(len(vertices) - 1)]
    distances = [distance for distance in full_distances if distance > 1e-5]
    if len(distances) < 4:
        return set()

    parity_baselines: dict[int, float] = {}
    for parity in (0, 1):
        parity_distances = [distance for index, distance in enumerate(full_distances) if index % 2 == parity and distance > 1e-5]
        if not parity_distances:
            return set()
        parity_baselines[parity] = _median(parity_distances)

    boundaries: set[int] = set()
    for index, distance in enumerate(full_distances):
        if distance <= 1e-5:
            continue
        baseline = parity_baselines[index & 1]
        prev_distance = full_distances[index - 2] if index >= 2 else baseline
        next_distance = full_distances[index + 2] if index + 2 < len(full_distances) else baseline
        local_threshold = max(baseline * 1.6, min(prev_distance, next_distance) * 1.5)
        if distance > local_threshold:
            boundaries.add(index + 1)
    return boundaries


def _strip_duplicate_pair_boundaries(vertices: tuple[Vec3, ...]) -> set[int]:
    boundaries: set[int] = set()
    for index in range(1, len(vertices) - 1):
        first = vertices[index]
        second = vertices[index + 1]
        for previous in range(index - 1):
            if _same_vertex(first, vertices[previous]) and _same_vertex(second, vertices[previous + 1]):
                boundaries.add(index)
                break
            if _same_vertex(first, vertices[previous + 1]) and _same_vertex(second, vertices[previous]):
                boundaries.add(index)
                break
    return boundaries


def _has_degenerate_strip_triangles(vertices: tuple[Vec3, ...]) -> bool:
    for index in range(len(vertices) - 2):
        if _is_degenerate_triangle(vertices[index], vertices[index + 1], vertices[index + 2]):
            return True
    return False


def _is_degenerate_triangle(a: Vec3, b: Vec3, c: Vec3) -> bool:
    abx = b.x - a.x
    aby = b.y - a.y
    abz = b.z - a.z
    acx = c.x - a.x
    acy = c.y - a.y
    acz = c.z - a.z
    cross_x = aby * acz - abz * acy
    cross_y = abz * acx - abx * acz
    cross_z = abx * acy - aby * acx
    return (cross_x * cross_x + cross_y * cross_y + cross_z * cross_z) <= 1e-12


def _same_vertex(a: Vec3, b: Vec3, epsilon: float = 1e-5) -> bool:
    return abs(a.x - b.x) <= epsilon and abs(a.y - b.y) <= epsilon and abs(a.z - b.z) <= epsilon


def _is_prop_object(name: str) -> bool:
    return name.startswith(("XB_", "XS_", "XT_", "XW_", "XWU_", "TRACK_HELICOPTER"))


def _should_prioritize_target_count(name: str) -> bool:
    if _is_prop_object(name):
        return True
    return name.startswith(("TRN_", "RD_", "ROAD", "SHOLDER", "SHOULDER"))


def _should_skip_object(name: str) -> bool:
    return name in {"BACKGROUND", "ROCKIES", "SKYDOME", "SKYDOME_ENVMAP"}


def _vertex_distance(a: Vec3, b: Vec3) -> float:
    dx = a.x - b.x
    dy = a.y - b.y
    dz = a.z - b.z
    return (dx * dx + dy * dy + dz * dz) ** 0.5


def _topology_score(vertices: tuple[Vec3, ...], indices: list[int]) -> tuple[int, float, int]:
    if not indices:
        return (0, 0.0, 0)

    adjacent_distances = [_vertex_distance(vertices[index], vertices[index + 1]) for index in range(len(vertices) - 1)]
    non_zero_distances = [distance for distance in adjacent_distances if distance > 1e-5]
    if not non_zero_distances:
        return (0, 0.0, 0)

    baseline = max(_upper_half_median(non_zero_distances), 1e-5)
    bad_triangle_count = 0
    worst_ratio = 0.0
    face_count = 0

    for face_offset in range(0, len(indices), 3):
        face = indices[face_offset : face_offset + 3]
        if len(face) < 3:
            break
        a, b, c = (vertices[face[0]], vertices[face[1]], vertices[face[2]])
        if _is_degenerate_triangle(a, b, c):
            continue
        face_count += 1
        longest_edge = max(_vertex_distance(a, b), _vertex_distance(b, c), _vertex_distance(a, c))
        ratio = longest_edge / baseline
        if ratio > 3.5:
            bad_triangle_count += 1
        worst_ratio = max(worst_ratio, ratio)

    return (bad_triangle_count, worst_ratio, face_count)


def _should_use_segmented_strip(
    vertices: tuple[Vec3, ...],
    indices: list[int],
    segmented_indices: list[int],
) -> bool:
    if segmented_indices == indices:
        return False

    score = _topology_score(vertices, indices)
    segmented_score = _topology_score(vertices, segmented_indices)
    if segmented_score[0] + 2 <= score[0]:
        return True
    if score[0] >= 6 and segmented_score[0] < score[0] and segmented_score[1] + 1e-6 < score[1] * 0.6:
        return True
    return False


def _should_replace_topology(
    candidate_score: tuple[int, float, int],
    best_score: tuple[int, float, int],
    unknown_count: int,
    prefer_target_count: bool = False,
) -> bool:
    best_count_error = abs(best_score[2] - unknown_count)
    candidate_count_error = abs(candidate_score[2] - unknown_count)

    if (
        prefer_target_count
        and candidate_count_error == 0
        and best_count_error >= 4
        and 0 < candidate_score[0] <= 4
        and candidate_score[1] <= 16.0
    ):
        return True

    if candidate_score[0] < best_score[0]:
        return True
    if candidate_score[0] > best_score[0]:
        return False

    if (
        prefer_target_count
        and candidate_count_error == 0
        and best_count_error > 0
        and candidate_score[0] == 0
        and candidate_score[1] <= best_score[1] * 3.0 + 1e-6
    ):
        return True

    if candidate_count_error < best_count_error:
        if candidate_score[1] + 1e-6 < best_score[1]:
            return True
        if prefer_target_count and candidate_count_error == 0 and best_count_error >= 2 and candidate_score[1] <= 3.0:
            return True
        if best_count_error >= 4 and candidate_score[1] <= best_score[1] * 1.6 + 1e-6:
            return True
        if prefer_target_count and candidate_count_error == 0 and best_count_error >= 2 and candidate_score[1] <= best_score[1] + 1.1:
            return True

    if (
        candidate_count_error == best_count_error
        and (prefer_target_count or best_score[0] > 0)
        and candidate_score[1] + 1e-6 < best_score[1]
    ):
        return True

    return False


def _segmented_strip_indices_for_unknown_count(vertices: tuple[Vec3, ...], unknown_count: int | None) -> list[int] | None:
    if unknown_count is None:
        return None

    vertex_count = len(vertices)
    if unknown_count <= 0 or unknown_count >= vertex_count:
        return None

    delta = vertex_count - unknown_count
    if delta <= 0 or delta & 1:
        return None

    segment_count = delta // 2
    if segment_count <= 1 or segment_count > vertex_count // 3:
        return None

    segment_cache: dict[tuple[int, int], tuple[tuple[int, float, int], list[int]]] = {}

    def segment_score(start_index: int, end_index: int) -> tuple[tuple[int, float, int], list[int]]:
        key = (start_index, end_index)
        cached = segment_cache.get(key)
        if cached is not None:
            return cached
        indices = _strip_segment_indices(vertices, start_index, end_index - start_index)
        score = _topology_score(vertices, indices)
        segment_cache[key] = (score, indices)
        return (score, indices)

    best: tuple[tuple[int, int, float, int], tuple[int, ...]] | None = None

    def search(
        start_index: int,
        remaining_segments: int,
        face_count: int,
        bad_count: int,
        worst_ratio: float,
        boundaries: tuple[int, ...],
    ) -> None:
        nonlocal best

        if remaining_segments == 1:
            if vertex_count - start_index < 3:
                return
            score, _indices = segment_score(start_index, vertex_count)
            total_faces = face_count + score[2]
            total_bad = bad_count + score[0]
            total_worst = max(worst_ratio, score[1])
            key = (abs(unknown_count - total_faces), total_bad, total_worst, -total_faces)
            if best is None or key < best[0]:
                best = (key, boundaries)
            return

        min_end = start_index + 3
        max_end = vertex_count - 3 * (remaining_segments - 1)
        for end_index in range(min_end, max_end + 1):
            score, _indices = segment_score(start_index, end_index)
            search(
                end_index,
                remaining_segments - 1,
                face_count + score[2],
                bad_count + score[0],
                max(worst_ratio, score[1]),
                boundaries + (end_index,),
            )

    search(0, segment_count, 0, 0, 0.0, ())
    if best is None or not best[1]:
        return None

    return _strip_indices_with_boundaries(vertices, set(best[1]))


def _flexible_segmented_strip_indices_for_unknown_count(vertices: tuple[Vec3, ...], unknown_count: int | None) -> list[int] | None:
    if unknown_count is None:
        return None

    vertex_count = len(vertices)
    if unknown_count <= 0 or unknown_count >= vertex_count:
        return None

    face_slack = max(8, vertex_count // 3)
    max_faces = unknown_count + face_slack
    segment_cache: dict[tuple[int, int], tuple[tuple[int, float, int], list[int]]] = {}

    def segment_score(start_index: int, end_index: int) -> tuple[tuple[int, float, int], list[int]]:
        key = (start_index, end_index)
        cached = segment_cache.get(key)
        if cached is not None:
            return cached

        count = end_index - start_index
        if count < 3:
            result = ((0, 0.0, 0), [])
        else:
            indices = _strip_segment_indices(vertices, start_index, count)
            result = (_topology_score(vertices, indices), indices)
        segment_cache[key] = result
        return result

    # end_index -> total_faces -> (bad_count, worst_ratio, padding_count, boundaries)
    states: dict[int, dict[int, tuple[int, float, int, tuple[int, ...]]]] = {0: {0: (0, 0.0, 0, ())}}

    for start_index in range(vertex_count):
        face_states = states.get(start_index)
        if not face_states:
            continue

        for face_count, state in list(face_states.items()):
            bad_count, worst_ratio, padding_count, boundaries = state
            for end_index in range(start_index + 1, vertex_count + 1):
                score, _indices = segment_score(start_index, end_index)
                new_face_count = face_count + score[2]
                if new_face_count > max_faces:
                    continue
                new_state = (
                    bad_count + score[0],
                    max(worst_ratio, score[1]),
                    padding_count + (1 if end_index - start_index < 3 else 0),
                    boundaries + ((end_index,) if end_index < vertex_count else ()),
                )
                end_states = states.setdefault(end_index, {})
                existing = end_states.get(new_face_count)
                if existing is None or new_state[:3] < existing[:3]:
                    end_states[new_face_count] = new_state

    final_states = states.get(vertex_count)
    if not final_states:
        return None

    best: tuple[tuple[int, int, float, int], tuple[int, ...]] | None = None
    for face_count, state in final_states.items():
        bad_count, worst_ratio, padding_count, boundaries = state
        key = (abs(unknown_count - face_count), bad_count, worst_ratio, padding_count)
        if best is None or key < best[0]:
            best = (key, boundaries)

    if best is None:
        return None
    return _strip_indices_with_boundaries(vertices, set(best[1]))


def _hybrid_indices_for_unknown_count(vertices: tuple[Vec3, ...], unknown_count: int | None) -> list[int] | None:
    if unknown_count is None:
        return None

    vertex_count = len(vertices)
    if unknown_count <= 0 or unknown_count >= vertex_count or vertex_count > 40:
        return None

    segment_cache: dict[tuple[str, int, int], tuple[tuple[int, float, int], list[int]] | None] = {}

    def segment_score(mode: str, start_index: int, end_index: int) -> tuple[tuple[int, float, int], list[int]] | None:
        key = (mode, start_index, end_index)
        cached = segment_cache.get(key)
        if cached is not None or key in segment_cache:
            return cached

        count = end_index - start_index
        if mode == "skip":
            result = ((0, 0.0, 0), []) if count <= 2 else None
        elif mode == "strip":
            if count < 3:
                result = None
            else:
                indices = _strip_segment_indices(vertices, start_index, count)
                result = (_topology_score(vertices, indices), indices)
        elif mode == "triangles":
            if count < 3:
                result = None
            else:
                indices = [start_index + local_index for local_index in _triangle_list_indices(count)]
                result = (_topology_score(vertices, indices), indices)
        elif mode == "quads":
            if count < 4:
                result = None
            else:
                indices = [start_index + local_index for local_index in _quad_batch_indices(count)]
                result = (_topology_score(vertices, indices), indices)
        else:
            result = None

        segment_cache[key] = result
        return result

    states: dict[int, dict[int, tuple[int, float, int, tuple[tuple[str, int, int], ...]]]] = {0: {0: (0, 0.0, 0, ())}}
    max_faces = unknown_count + 10
    modes = ("skip", "strip", "triangles", "quads")

    for start_index in range(vertex_count):
        face_states = states.get(start_index)
        if not face_states:
            continue

        for face_count, state in list(face_states.items()):
            bad_count, worst_ratio, pad_count, plan = state
            for end_index in range(start_index + 1, vertex_count + 1):
                for mode in modes:
                    scored = segment_score(mode, start_index, end_index)
                    if scored is None:
                        continue
                    score, _indices = scored
                    new_face_count = face_count + score[2]
                    if new_face_count > max_faces:
                        continue
                    new_state = (
                        bad_count + score[0],
                        max(worst_ratio, score[1]),
                        pad_count + (1 if mode == "skip" else 0),
                        plan + ((mode, start_index, end_index),),
                    )
                    end_states = states.setdefault(end_index, {})
                    existing = end_states.get(new_face_count)
                    if existing is None or new_state[:3] < existing[:3]:
                        end_states[new_face_count] = new_state

    final_states = states.get(vertex_count)
    if not final_states:
        return None

    best: tuple[tuple[int, int, float, int], tuple[tuple[str, int, int], ...]] | None = None
    for face_count, state in final_states.items():
        bad_count, worst_ratio, pad_count, plan = state
        key = (abs(unknown_count - face_count), bad_count, worst_ratio, pad_count)
        if best is None or key < best[0]:
            best = (key, plan)

    if best is None:
        return None

    indices: list[int] = []
    for mode, start_index, end_index in best[1]:
        if mode == "skip":
            continue
        scored = segment_score(mode, start_index, end_index)
        if scored is None:
            continue
        indices.extend(scored[1])
    return indices


def _indices_for_run(vertices: tuple[Vec3, ...], object_name: str = "", unknown_count: int | None = None) -> list[int]:
    vertex_count = len(vertices)
    prefer_explicit_primitives = _is_prop_object(object_name)
    prefer_target_count = _should_prioritize_target_count(object_name)

    if prefer_explicit_primitives and unknown_count is not None:
        if vertex_count % 3 == 0 and unknown_count == vertex_count // 3:
            return _triangle_list_indices(vertex_count)
        if vertex_count % 4 == 0 and unknown_count == vertex_count // 2:
            return _quad_batch_indices(vertex_count)

    indices = _strip_indices_for_vertices(vertices, object_name)
    best_score = _topology_score(vertices, indices)

    if unknown_count is None:
        return indices

    raw_strip_indices = _strip_segment_indices(vertices, 0, vertex_count)
    raw_strip_score = _topology_score(vertices, raw_strip_indices)
    if _should_replace_topology(raw_strip_score, best_score, unknown_count, prefer_target_count):
        indices = raw_strip_indices
        best_score = raw_strip_score

    segmented_strip_indices = _segmented_strip_indices_for_unknown_count(vertices, unknown_count)
    if segmented_strip_indices:
        segmented_strip_score = _topology_score(vertices, segmented_strip_indices)
        if _should_replace_topology(segmented_strip_score, best_score, unknown_count, prefer_target_count):
            indices = segmented_strip_indices
            best_score = segmented_strip_score

    if prefer_target_count and best_score[2] != unknown_count:
        flexible_segmented_indices = _flexible_segmented_strip_indices_for_unknown_count(vertices, unknown_count)
        if flexible_segmented_indices:
            flexible_segmented_score = _topology_score(vertices, flexible_segmented_indices)
            if _should_replace_topology(flexible_segmented_score, best_score, unknown_count, prefer_target_count):
                indices = flexible_segmented_indices

    return indices


def _indices_for_block(vertices: tuple[Vec3, ...], object_name: str, block: DecodedBlock) -> list[int]:
    if block.primitive_mode == "triangles":
        return _triangle_list_indices(len(vertices))
    if block.primitive_mode == "quads":
        return _quad_batch_indices(len(vertices))

    indices = _indices_for_run(vertices, object_name, block.expected_face_count)
    topology_code = block.topology_code
    if block.expected_face_count is None or topology_code is None:
        return indices

    prefer_target_count = _should_prioritize_target_count(object_name)
    best_score = _topology_score(vertices, indices)

    if topology_code in {0x05, 0x07}:
        hybrid_indices = _hybrid_indices_for_unknown_count(vertices, block.expected_face_count)
        if hybrid_indices:
            hybrid_score = _topology_score(vertices, hybrid_indices)
            if (
                topology_code == 0x05
                and hybrid_score[2] == block.expected_face_count
                and hybrid_score[0] <= best_score[0] + 1
                and hybrid_score[1] <= 7.0
            ):
                return hybrid_indices
            if _should_replace_topology(hybrid_score, best_score, block.expected_face_count, prefer_target_count):
                return hybrid_indices

    if topology_code == 0x12:
        flexible_indices = _flexible_segmented_strip_indices_for_unknown_count(vertices, block.expected_face_count)
        if flexible_indices:
            flexible_score = _topology_score(vertices, flexible_indices)
            if _should_replace_topology(flexible_score, best_score, block.expected_face_count, prefer_target_count):
                return flexible_indices

    return indices


def _median(values: list[float]) -> float:
    ordered = sorted(values)
    mid = len(ordered) // 2
    if len(ordered) & 1:
        return ordered[mid]
    return (ordered[mid - 1] + ordered[mid]) * 0.5


def _upper_half_median(values: list[float]) -> float:
    ordered = sorted(values)
    return _median(ordered[len(ordered) // 2 :])


def _should_export_vif_colors(object_name: str, render_flag: int | None, mode: str = "auto") -> bool:
    if mode == "always":
        return True
    if mode == "off":
        return False
    if render_flag in {0x4041, 0x4040, 0x0041}:
        return True
    if object_name.startswith(("RD_", "ROAD", "SHOLDER", "SHOULDER")):
        return True
    return False


class GlbBuilder:
    def __init__(self, textures: TextureLibrary | None = None):
        self.textures = textures or TextureLibrary({})
        self.bin = bytearray()
        self.buffer_views: list[dict[str, Any]] = []
        self.accessors: list[dict[str, Any]] = []
        self.images: list[dict[str, Any]] = []
        self.samplers: list[dict[str, Any]] = [{"magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497}]
        self.gltf_textures: list[dict[str, Any]] = []
        self.materials: list[dict[str, Any]] = [{"name": "default", "pbrMetallicRoughness": {"baseColorFactor": [0.8, 0.8, 0.8, 1.0], "roughnessFactor": 1.0, "metallicFactor": 0.0}}]
        self._texture_materials: dict[int, int] = {}

    def add_bytes(self, data: bytes, target: int | None = None) -> int:
        self._align_bin()
        offset = len(self.bin)
        self.bin.extend(data)
        view: dict[str, Any] = {"buffer": 0, "byteOffset": offset, "byteLength": len(data)}
        if target is not None:
            view["target"] = target
        self.buffer_views.append(view)
        return len(self.buffer_views) - 1

    def add_accessor(
        self,
        data: bytes,
        component_type: int,
        accessor_type: str,
        count: int,
        target: int | None = None,
        min_value: list[float] | None = None,
        max_value: list[float] | None = None,
        normalized: bool = False,
    ) -> int:
        view = self.add_bytes(data, target)
        accessor: dict[str, Any] = {
            "bufferView": view,
            "byteOffset": 0,
            "componentType": component_type,
            "count": count,
            "type": accessor_type,
        }
        if min_value is not None:
            accessor["min"] = min_value
        if max_value is not None:
            accessor["max"] = max_value
        if normalized:
            accessor["normalized"] = True
        self.accessors.append(accessor)
        return len(self.accessors) - 1

    def material_for_hash(self, tex_hash: int | None) -> int:
        texture = self.textures.get(tex_hash)
        if texture is None:
            return 0
        if texture.tex_hash in self._texture_materials:
            return self._texture_materials[texture.tex_hash]

        image_view = self.add_bytes(texture.png)
        self.images.append(
            {
                "name": texture.name,
                "bufferView": image_view,
                "mimeType": "image/png",
            }
        )
        image_index = len(self.images) - 1
        self.gltf_textures.append({"sampler": 0, "source": image_index, "name": texture.name})
        texture_index = len(self.gltf_textures) - 1
        self.materials.append(
            {
                "name": texture.name,
                "pbrMetallicRoughness": {
                    "baseColorTexture": {"index": texture_index},
                    "roughnessFactor": 1.0,
                    "metallicFactor": 0.0,
                },
                "doubleSided": True,
            }
        )
        if texture.alpha_mode == "BLEND":
            self.materials[-1]["alphaMode"] = "BLEND"
        elif texture.alpha_mode == "MASK":
            self.materials[-1]["alphaMode"] = "MASK"
            self.materials[-1]["alphaCutoff"] = 0.5
        material_index = len(self.materials) - 1
        self._texture_materials[texture.tex_hash] = material_index
        return material_index

    def _align_bin(self) -> None:
        while len(self.bin) % 4:
            self.bin.append(0)


def write_glb(
    scene: Scene,
    out_path: Path,
    textures: TextureLibrary | None = None,
    vertex_colors: str = "auto",
) -> None:
    builder = GlbBuilder(textures)
    meshes: list[dict[str, Any]] = []
    nodes: list[dict[str, Any]] = []

    for object_index, obj in enumerate(scene.objects):
        if _should_skip_object(obj.name):
            continue
        primitives: list[dict[str, Any]] = []
        for block_index, block in enumerate(obj.blocks):
            run = block.run
            vertices = _ps2_to_gltf_vertices(transformed_block_vertices(obj, block))
            if len(vertices) < 3:
                continue
            local_indices = _indices_for_block(vertices, obj.name, block)
            if not local_indices:
                continue

            position_accessor = builder.add_accessor(
                _pack_vec3(vertices),
                5126,
                "VEC3",
                len(vertices),
                target=34962,
                min_value=_min_vec3(vertices),
                max_value=_max_vec3(vertices),
            )
            index_accessor = builder.add_accessor(
                struct.pack("<" + "I" * len(local_indices), *local_indices),
                5125,
                "SCALAR",
                len(local_indices),
                target=34963,
            )

            attributes: dict[str, int] = {"POSITION": position_accessor}
            if len(run.texcoords) >= len(vertices):
                attributes["TEXCOORD_0"] = builder.add_accessor(
                    _pack_vec2(run.texcoords[: len(vertices)]),
                    5126,
                    "VEC2",
                    len(vertices),
                    target=34962,
                )
            if _should_export_vif_colors(obj.name, block.render_flag, vertex_colors) and len(run.packed_values) >= len(vertices):
                attributes["COLOR_0"] = builder.add_accessor(
                    _pack_vif_colors(run.packed_values[: len(vertices)]),
                    5126,
                    "VEC4",
                    len(vertices),
                    target=34962,
                )

            texture_hash = _texture_hash_for_run(obj.texture_hashes, obj.run_texture_indices, block_index)
            primitives.append(
                {
                    "attributes": attributes,
                    "indices": index_accessor,
                    "material": builder.material_for_hash(texture_hash),
                    "mode": 4,
                }
            )

        if primitives:
            meshes.append({"name": obj.name, "primitives": primitives})
            nodes.append({"name": f"{obj.name}_{object_index:04d}", "mesh": len(meshes) - 1})

    if not meshes:
        raise ValueError("No GLB primitives were generated")

    state: dict[str, Any] = {
        "asset": {"version": "2.0", "generator": "map_tools_ps2 experimental GLB writer"},
        "scene": 0,
        "scenes": [{"nodes": list(range(len(nodes)))}],
        "nodes": nodes,
        "meshes": meshes,
        "buffers": [{"byteLength": len(builder.bin)}],
        "bufferViews": builder.buffer_views,
        "accessors": builder.accessors,
        "materials": builder.materials,
    }
    if builder.images:
        state["images"] = builder.images
        state["textures"] = builder.gltf_textures
        state["samplers"] = builder.samplers

    json_chunk = json.dumps(state, separators=(",", ":")).encode("utf-8")
    json_chunk += b" " * ((4 - len(json_chunk) % 4) % 4)
    builder._align_bin()
    bin_chunk = bytes(builder.bin)

    total_length = 12 + 8 + len(json_chunk) + 8 + len(bin_chunk)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("wb") as fh:
        fh.write(struct.pack("<III", 0x46546C67, 2, total_length))
        fh.write(struct.pack("<I4s", len(json_chunk), b"JSON"))
        fh.write(json_chunk)
        fh.write(struct.pack("<I4s", len(bin_chunk), b"BIN\0"))
        fh.write(bin_chunk)


def _pack_vec3(vertices: tuple[Vec3, ...]) -> bytes:
    values = []
    for vertex in vertices:
        values.extend((vertex.x, vertex.y, vertex.z))
    return struct.pack("<" + "f" * len(values), *values)


def _texture_hash_for_run(
    texture_hashes: tuple[int, ...], run_texture_indices: tuple[int | None, ...], run_index: int
) -> int | None:
    if not texture_hashes:
        return None
    if run_texture_indices and run_index < len(run_texture_indices):
        texture_index = run_texture_indices[run_index]
        if texture_index is not None and 0 <= texture_index < len(texture_hashes):
            return texture_hashes[texture_index]
    return texture_hashes[min(run_index, len(texture_hashes) - 1)]


def _pack_vec2(values_in: tuple[tuple[float, float], ...]) -> bytes:
    values = []
    for u, v in values_in:
        values.extend((u, v))
    return struct.pack("<" + "f" * len(values), *values)


def _pack_vif_colors(values_in: tuple[int, ...]) -> bytes:
    values: list[float] = []
    for packed in values_in:
        r, g, b, a = _decode_vif_color_5551(packed)
        values.extend((r, g, b, a))
    return struct.pack("<" + "f" * len(values), *values)


def _decode_vif_color_5551(value: int) -> tuple[float, float, float, float]:
    # Inferred from the road-material V4_5 stream: low bits behave like R5G5B5A1.
    red = (value & 0x1F) / 31.0
    green = ((value >> 5) & 0x1F) / 31.0
    blue = ((value >> 10) & 0x1F) / 31.0
    alpha = 1.0 if value & 0x8000 else 0.0
    return (red, green, blue, alpha)


def _min_vec3(vertices: tuple[Vec3, ...]) -> list[float]:
    return [min(v.x for v in vertices), min(v.y for v in vertices), min(v.z for v in vertices)]


def _max_vec3(vertices: tuple[Vec3, ...]) -> list[float]:
    return [max(v.x for v in vertices), max(v.y for v in vertices), max(v.z for v in vertices)]
