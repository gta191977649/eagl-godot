from __future__ import annotations

import math
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path

from .binary import Vec3
from .chunks import parse_chunks
from .comp import load_bundle_bytes
from .gs_dump import GsDrawPacket, GsScreenVertex, extract_draw_packets, read_gs_dump
from .gs_validate import _draw_st_key, _normalize_st_key, _source_st_key
from .model import MeshObject, parse_scene, transformed_block_vertices


@dataclass(frozen=True)
class TransformSample:
    object_name: str
    object_index: int
    block_index: int
    draw_index: int
    vertex_count: int
    local_vertices: tuple[Vec3, ...]
    world_vertices: tuple[Vec3, ...]
    gs_vertices: tuple[GsScreenVertex, ...]


@dataclass(frozen=True)
class AffineFit:
    coefficients: tuple[tuple[float, float, float, float], ...]
    rms: float
    normalized_rms: float
    median: float
    sample_count: int
    point_count: int


@dataclass(frozen=True)
class TransformBenchmarkReport:
    track_path: Path
    gsdump_path: Path
    object_filter: str
    candidate_source_blocks: int
    candidate_draws: int
    sample_count: int
    point_count: int
    world_fit: AffineFit | None
    local_fit: AffineFit | None
    samples: tuple[TransformSample, ...]

    def format_text(self, limit: int = 24) -> str:
        lines = [
            f"track={self.track_path}",
            f"gsdump={self.gsdump_path}",
            f"object_filter={self.object_filter}",
            f"candidate_source_blocks={self.candidate_source_blocks} candidate_draws={self.candidate_draws}",
            f"matched_samples={self.sample_count} matched_points={self.point_count}",
        ]
        lines.append("world_transform_fit=" + _format_fit(self.world_fit))
        lines.append("raw_local_fit=" + _format_fit(self.local_fit))
        if self.world_fit and self.local_fit:
            ratio = self.local_fit.normalized_rms / self.world_fit.normalized_rms if self.world_fit.normalized_rms else math.inf
            lines.append(f"local_vs_world_normalized_rms_ratio={ratio:.3f}")
        for sample in self.samples[:limit]:
            lines.append(
                f"{sample.object_index:04d}:{sample.block_index:03d} draw={sample.draw_index:05d} "
                f"v={sample.vertex_count} {sample.object_name}"
            )
        return "\n".join(lines)


def benchmark_transform_against_gsdump(
    track_path: Path,
    gsdump_path: Path,
    object_filter: str = "",
    st_precision: int = 2,
    min_vertices: int = 4,
    max_samples: int = 256,
) -> TransformBenchmarkReport:
    dump = read_gs_dump(gsdump_path)
    draws = extract_draw_packets(dump)
    draw_candidates = [
        (draw_index, draw, _normalized_draw_key(draw, st_precision))
        for draw_index, draw in enumerate(draws)
        if len(draw.vertices) >= min_vertices and _normalized_draw_key(draw, st_precision)
    ]

    data = load_bundle_bytes(track_path)
    scene = parse_scene(parse_chunks(data), data)
    source_candidates = _source_candidates(scene.objects, object_filter, st_precision, min_vertices)

    draws_by_key: defaultdict[tuple[int, tuple[tuple[float, float], ...]], list[tuple[int, GsDrawPacket]]] = defaultdict(list)
    for draw_index, draw, key in draw_candidates:
        if key:
            draws_by_key[(len(draw.vertices), key)].append((draw_index, draw))

    sources_by_key: defaultdict[tuple[int, tuple[tuple[float, float], ...]], list[tuple[int, MeshObject, int]]] = defaultdict(list)
    for source in source_candidates:
        object_index, obj, block_index, key = source
        sources_by_key[(len(obj.blocks[block_index].run.vertices), key)].append((object_index, obj, block_index))

    samples: list[TransformSample] = []
    for key in sorted(set(draws_by_key) & set(sources_by_key)):
        # Repeated road/terrain tiles often share identical normalized UV patterns.
        # Pairing in file/draw order is a benchmark heuristic; the trimmed fit below
        # drops the worst pairings before reporting residuals.
        for (object_index, obj, block_index), (draw_index, draw) in zip(sources_by_key[key], draws_by_key[key]):
            block = obj.blocks[block_index]
            samples.append(
                TransformSample(
                    object_name=obj.name,
                    object_index=object_index,
                    block_index=block_index,
                    draw_index=draw_index,
                    vertex_count=len(block.run.vertices),
                    local_vertices=block.run.vertices,
                    world_vertices=transformed_block_vertices(obj, block),
                    gs_vertices=draw.vertices,
                )
            )
            if len(samples) >= max_samples:
                break
        if len(samples) >= max_samples:
            break

    point_count = sum(sample.vertex_count for sample in samples)
    return TransformBenchmarkReport(
        track_path=track_path,
        gsdump_path=gsdump_path,
        object_filter=object_filter,
        candidate_source_blocks=len(source_candidates),
        candidate_draws=len(draw_candidates),
        sample_count=len(samples),
        point_count=point_count,
        world_fit=_fit_samples(samples, use_world=True),
        local_fit=_fit_samples(samples, use_world=False),
        samples=tuple(samples),
    )


def _source_candidates(
    objects: list[MeshObject],
    object_filter: str,
    st_precision: int,
    min_vertices: int,
) -> list[tuple[int, MeshObject, int, tuple[tuple[float, float], ...]]]:
    needle = object_filter.lower()
    candidates: list[tuple[int, MeshObject, int, tuple[tuple[float, float], ...]]] = []
    for object_index, obj in enumerate(objects):
        if needle and needle not in obj.name.lower():
            continue
        for block_index, block in enumerate(obj.blocks):
            if len(block.run.vertices) < min_vertices:
                continue
            key = _normalize_st_key(_source_st_key(block, st_precision), st_precision)
            if key:
                candidates.append((object_index, obj, block_index, key))
    return candidates


def _normalized_draw_key(draw: GsDrawPacket, st_precision: int) -> tuple[tuple[float, float], ...] | None:
    key = _draw_st_key(draw, st_precision)
    if not key:
        return None
    return _normalize_st_key(key, st_precision)


def _fit_samples(samples: list[TransformSample], use_world: bool) -> AffineFit | None:
    rows: list[tuple[float, float, float, float]] = []
    targets: list[tuple[float, float, float]] = []
    sample_indices: list[int] = []
    for sample_index, sample in enumerate(samples):
        vertices = sample.world_vertices if use_world else sample.local_vertices
        for vertex, gs_vertex in zip(vertices, sample.gs_vertices):
            rows.append((vertex.x, vertex.y, vertex.z, 1.0))
            targets.append((float(gs_vertex.x), float(gs_vertex.y), float(gs_vertex.z)))
            sample_indices.append(sample_index)

    if len(rows) < 4:
        return None

    active = list(range(len(rows)))
    coefficients: tuple[tuple[float, float, float, float], ...] | None = None
    for _iteration in range(3):
        coefficients = _fit_affine_rows([rows[index] for index in active], [targets[index] for index in active])
        residuals = [_residual(rows[index], targets[index], coefficients) for index in active]
        if len(residuals) < 20:
            break
        cutoff = sorted(residuals)[int(len(residuals) * 0.85)]
        next_active = [index for index, residual in zip(active, residuals) if residual <= cutoff]
        if len(next_active) < 4 or len(next_active) == len(active):
            break
        active = next_active

    if coefficients is None:
        return None

    residuals = [_residual(rows[index], targets[index], coefficients) for index in active]
    normalized_residuals = _normalized_residuals(
        [rows[index] for index in active],
        [targets[index] for index in active],
        coefficients,
    )
    sample_count = len({sample_indices[index] for index in active})
    return AffineFit(
        coefficients=coefficients,
        rms=math.sqrt(sum(value * value for value in residuals) / len(residuals)),
        normalized_rms=math.sqrt(sum(value * value for value in normalized_residuals) / len(normalized_residuals)),
        median=sorted(residuals)[len(residuals) // 2],
        sample_count=sample_count,
        point_count=len(active),
    )


def _fit_affine_rows(
    rows: list[tuple[float, float, float, float]],
    targets: list[tuple[float, float, float]],
) -> tuple[tuple[float, float, float, float], ...]:
    return tuple(_least_squares_4(rows, [target[axis] for target in targets]) for axis in range(3))


def _least_squares_4(rows: list[tuple[float, float, float, float]], values: list[float]) -> tuple[float, float, float, float]:
    normal = [[0.0 for _ in range(4)] for _ in range(4)]
    rhs = [0.0 for _ in range(4)]
    for row, value in zip(rows, values):
        for i in range(4):
            rhs[i] += row[i] * value
            for j in range(4):
                normal[i][j] += row[i] * row[j]
    solution = _solve_4x4(normal, rhs)
    return solution[0], solution[1], solution[2], solution[3]


def _solve_4x4(matrix: list[list[float]], rhs: list[float]) -> list[float]:
    augmented = [row[:] + [value] for row, value in zip(matrix, rhs)]
    for column in range(4):
        pivot = max(range(column, 4), key=lambda row: abs(augmented[row][column]))
        if abs(augmented[pivot][column]) < 1e-10:
            raise ValueError("singular affine fit")
        if pivot != column:
            augmented[column], augmented[pivot] = augmented[pivot], augmented[column]
        divisor = augmented[column][column]
        for index in range(column, 5):
            augmented[column][index] /= divisor
        for row in range(4):
            if row == column:
                continue
            factor = augmented[row][column]
            if factor == 0.0:
                continue
            for index in range(column, 5):
                augmented[row][index] -= factor * augmented[column][index]
    return [augmented[row][4] for row in range(4)]


def _predict(row: tuple[float, float, float, float], coefficients: tuple[tuple[float, float, float, float], ...]) -> tuple[float, float, float]:
    return tuple(sum(row[index] * axis[index] for index in range(4)) for axis in coefficients)  # type: ignore[return-value]


def _residual(
    row: tuple[float, float, float, float],
    target: tuple[float, float, float],
    coefficients: tuple[tuple[float, float, float, float], ...],
) -> float:
    predicted = _predict(row, coefficients)
    return math.sqrt(sum((predicted[axis] - target[axis]) ** 2 for axis in range(3)))


def _normalized_residuals(
    rows: list[tuple[float, float, float, float]],
    targets: list[tuple[float, float, float]],
    coefficients: tuple[tuple[float, float, float, float], ...],
) -> list[float]:
    ranges: list[float] = []
    for axis in range(3):
        values = [target[axis] for target in targets]
        axis_range = max(values) - min(values)
        ranges.append(axis_range if axis_range > 1e-8 else 1.0)

    residuals: list[float] = []
    for row, target in zip(rows, targets):
        predicted = _predict(row, coefficients)
        residuals.append(math.sqrt(sum(((predicted[axis] - target[axis]) / ranges[axis]) ** 2 for axis in range(3))))
    return residuals


def _format_fit(fit: AffineFit | None) -> str:
    if fit is None:
        return "<insufficient samples>"
    return (
        f"samples={fit.sample_count} points={fit.point_count} "
        f"rms={fit.rms:.3f} normalized_rms={fit.normalized_rms:.6f} median={fit.median:.3f}"
    )
