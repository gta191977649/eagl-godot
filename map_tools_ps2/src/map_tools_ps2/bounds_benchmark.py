from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from .binary import Vec3, f32le
from .chunks import Chunk, parse_chunks, walk_chunks
from .comp import load_bundle_bytes
from .model import MeshObject, _read_run_metadata_records, parse_mesh_object, transformed_block_vertices


@dataclass(frozen=True)
class BoundsBenchmarkRecord:
    object_name: str
    object_offset: int
    block_index: int
    vertex_count: int
    local_error: float
    transformed_error: float


@dataclass(frozen=True)
class BoundsBenchmarkReport:
    track_path: Path
    object_filter: str
    records: tuple[BoundsBenchmarkRecord, ...]

    @property
    def local_stats(self) -> tuple[float, float, float]:
        return _error_stats(record.local_error for record in self.records)

    @property
    def transformed_stats(self) -> tuple[float, float, float]:
        return _error_stats(record.transformed_error for record in self.records)

    @property
    def transformed_much_better_count(self) -> int:
        return sum(1 for record in self.records if record.transformed_error + 0.05 < record.local_error)

    def format_text(self, limit: int = 24) -> str:
        local_med, local_p95, local_max = self.local_stats
        transformed_med, transformed_p95, transformed_max = self.transformed_stats
        lines = [
            f"track={self.track_path.name} object_filter={self.object_filter or '<all>'}",
            f"records={len(self.records)} transformed_much_better={self.transformed_much_better_count}",
            "metadata_bounds_vs_local_vertices="
            f"median={local_med:.6f} p95={local_p95:.6f} max={local_max:.6f}",
            "metadata_bounds_vs_transformed_vertices="
            f"median={transformed_med:.6f} p95={transformed_p95:.6f} max={transformed_max:.6f}",
        ]
        if self.records:
            lines.append("largest transformed-space mismatches:")
            for record in sorted(self.records, key=lambda item: item.transformed_error, reverse=True)[:limit]:
                lines.append(
                    f"  {record.object_name} block={record.block_index} verts={record.vertex_count} "
                    f"local_err={record.local_error:.6f} transformed_err={record.transformed_error:.6f} "
                    f"object=0x{record.object_offset:08x}"
                )
        return "\n".join(lines)


def benchmark_bounds_against_metadata(track_path: Path, object_filter: str = "") -> BoundsBenchmarkReport:
    data = load_bundle_bytes(track_path)
    chunks = parse_chunks(data)
    records: list[BoundsBenchmarkRecord] = []
    for object_chunk in walk_chunks(chunks):
        if object_chunk.chunk_id != 0x80034002:
            continue
        obj = parse_mesh_object(object_chunk, data)
        if obj is None or (object_filter and object_filter not in obj.name):
            continue
        records.extend(_benchmark_object_bounds(object_chunk, data, obj))
    return BoundsBenchmarkReport(track_path=track_path, object_filter=object_filter, records=tuple(records))


def _benchmark_object_bounds(object_chunk: Chunk, data: bytes, obj: MeshObject) -> list[BoundsBenchmarkRecord]:
    metadata_chunk = next((chunk for chunk in object_chunk.children if chunk.chunk_id == 0x00034004), None)
    if metadata_chunk is None:
        return []
    metadata_records = _read_run_metadata_records(metadata_chunk.payload(data), len(obj.blocks))
    if len(metadata_records) != len(obj.blocks):
        return []

    rows: list[BoundsBenchmarkRecord] = []
    for block_index, (block, metadata_record) in enumerate(zip(obj.blocks, metadata_records)):
        metadata_min = Vec3(f32le(metadata_record, 0x10), f32le(metadata_record, 0x14), f32le(metadata_record, 0x18))
        metadata_max = Vec3(f32le(metadata_record, 0x20), f32le(metadata_record, 0x24), f32le(metadata_record, 0x28))
        local_error = _bounds_error(block.run.vertices, metadata_min, metadata_max)
        transformed_error = _bounds_error(transformed_block_vertices(obj, block), metadata_min, metadata_max)
        rows.append(
            BoundsBenchmarkRecord(
                object_name=obj.name,
                object_offset=obj.chunk_offset,
                block_index=block_index,
                vertex_count=len(block.run.vertices),
                local_error=local_error,
                transformed_error=transformed_error,
            )
        )
    return rows


def _bounds_error(vertices: tuple[Vec3, ...], expected_min: Vec3, expected_max: Vec3) -> float:
    if not vertices:
        return 0.0
    actual_min, actual_max = _vertex_bounds(vertices)
    return max(
        abs(actual_min.x - expected_min.x),
        abs(actual_min.y - expected_min.y),
        abs(actual_min.z - expected_min.z),
        abs(actual_max.x - expected_max.x),
        abs(actual_max.y - expected_max.y),
        abs(actual_max.z - expected_max.z),
    )


def _vertex_bounds(vertices: tuple[Vec3, ...]) -> tuple[Vec3, Vec3]:
    return (
        Vec3(
            min(vertex.x for vertex in vertices),
            min(vertex.y for vertex in vertices),
            min(vertex.z for vertex in vertices),
        ),
        Vec3(
            max(vertex.x for vertex in vertices),
            max(vertex.y for vertex in vertices),
            max(vertex.z for vertex in vertices),
        ),
    )


def _error_stats(values_iterable) -> tuple[float, float, float]:
    values = sorted(values_iterable)
    if not values:
        return (0.0, 0.0, 0.0)
    return (values[len(values) // 2], values[min(len(values) - 1, int(len(values) * 0.95))], values[-1])
