from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from .chunks import parse_chunks
from .comp import load_bundle_bytes
from .glb_writer import _indices_for_block, _ps2_to_gltf_vertices, _strip_segment_indices
from .model import parse_scene, transformed_block_vertices


@dataclass(frozen=True)
class TopologyBenchmarkRecord:
    object_name: str
    object_index: int
    block_index: int
    vertex_count: int
    expected_face_count: int | None
    topology_code: int | None
    raw_strip_faces: int
    emitted_faces: int
    source_offset: int | None

    @property
    def dropped_faces(self) -> int:
        return max(0, self.raw_strip_faces - self.emitted_faces)


@dataclass(frozen=True)
class TopologyBenchmarkReport:
    track_path: Path
    object_filter: str
    records: tuple[TopologyBenchmarkRecord, ...]

    @property
    def changed_records(self) -> tuple[TopologyBenchmarkRecord, ...]:
        return tuple(record for record in self.records if record.raw_strip_faces != record.emitted_faces)

    @property
    def dropped_face_count(self) -> int:
        return sum(record.dropped_faces for record in self.records)

    def format_text(self, limit: int = 32) -> str:
        lines = [
            f"track={self.track_path.name} object_filter={self.object_filter or '<all>'}",
            f"records={len(self.records)} changed_records={len(self.changed_records)} "
            f"dropped_faces={self.dropped_face_count}",
        ]
        for record in sorted(self.changed_records, key=lambda item: item.dropped_faces, reverse=True)[:limit]:
            lines.append(
                f"  {record.object_index:04d}:{record.block_index:03d} {record.object_name} "
                f"verts={record.vertex_count} metadata_faces={record.expected_face_count} "
                f"topology=0x{record.topology_code or 0:02x} raw_strip={record.raw_strip_faces} "
                f"emitted={record.emitted_faces} dropped={record.dropped_faces} "
                f"vif_offset={record.source_offset}"
            )
        return "\n".join(lines)


def benchmark_topology(track_path: Path, object_filter: str = "TRN_SECTION60_UNDERROAD") -> TopologyBenchmarkReport:
    data = load_bundle_bytes(track_path)
    scene = parse_scene(parse_chunks(data), data)
    records: list[TopologyBenchmarkRecord] = []
    needle = object_filter.lower()
    for object_index, obj in enumerate(scene.objects):
        if needle and needle not in obj.name.lower():
            continue
        for block_index, block in enumerate(obj.blocks):
            vertices = _ps2_to_gltf_vertices(transformed_block_vertices(obj, block))
            raw_strip_faces = len(_strip_segment_indices(vertices, 0, len(vertices))) // 3
            emitted_faces = len(_indices_for_block(vertices, obj.name, block)) // 3
            records.append(
                TopologyBenchmarkRecord(
                    object_name=obj.name,
                    object_index=object_index,
                    block_index=block_index,
                    vertex_count=len(vertices),
                    expected_face_count=block.expected_face_count,
                    topology_code=block.topology_code,
                    raw_strip_faces=raw_strip_faces,
                    emitted_faces=emitted_faces,
                    source_offset=block.source_offset,
                )
            )
    return TopologyBenchmarkReport(track_path=track_path, object_filter=object_filter, records=tuple(records))
