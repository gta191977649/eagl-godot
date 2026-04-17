from __future__ import annotations

from dataclasses import dataclass, field

from .binary import IDENTITY4, Matrix4, Vec3, compose_matrix4, f32le, transform_point, u32le
from .chunks import Chunk, walk_chunks
from .primitives import PrimitiveMode
from .strip_entries import StripEntryRecord, parse_strip_entry_record
from .vif import VifVertexRun, extract_vif_vertex_runs


@dataclass(frozen=True)
class DecodedBlock:
    run: VifVertexRun
    primitive_mode: PrimitiveMode = "unknown"
    expected_face_count: int | None = None
    topology_code: int | None = None
    texture_index: int | None = None
    render_flag: int | None = None
    source_offset: int | None = None
    source_qword_size: int | None = None
    strip_entry: StripEntryRecord | None = None


@dataclass(frozen=True)
class MeshObject:
    name: str
    chunk_offset: int
    transform: Matrix4
    blocks: tuple[DecodedBlock, ...]
    texture_hashes: tuple[int, ...] = ()

    @property
    def vertex_runs(self) -> tuple[VifVertexRun, ...]:
        return tuple(block.run for block in self.blocks)

    @property
    def run_texture_indices(self) -> tuple[int | None, ...]:
        return tuple(block.texture_index for block in self.blocks)

    @property
    def run_unknown_counts(self) -> tuple[int | None, ...]:
        return tuple(block.expected_face_count for block in self.blocks)

    @property
    def run_render_flags(self) -> tuple[int | None, ...]:
        return tuple(block.render_flag for block in self.blocks)


@dataclass(frozen=True)
class SceneryInstance:
    object_index: int
    object_name: str
    transform: Matrix4
    source_chunk_offset: int
    record_index: int


@dataclass
class Scene:
    objects: list[MeshObject] = field(default_factory=list)
    scenery_instances: list[SceneryInstance] = field(default_factory=list)

    @property
    def vertex_count(self) -> int:
        return sum(len(block.run.vertices) for obj in self.objects for block in obj.blocks)


def _find_ascii_name(payload: bytes) -> tuple[str, int] | None:
    for start in range(0x10, min(0x34, len(payload) - 4), 4):
        end = start
        while end < len(payload):
            byte = payload[end]
            if byte == 0:
                break
            if byte < 0x20 or byte > 0x7E:
                break
            end += 1
        if end - start >= 4 and end < len(payload) and payload[end] == 0:
            return payload[start:end].decode("ascii", errors="replace"), start
    return None


def _read_transform(payload: bytes, name_start: int) -> Matrix4:
    matrix_offset = name_start + 0x50
    if matrix_offset + 64 > len(payload):
        return IDENTITY4
    rows = []
    for row in range(4):
        row_offset = matrix_offset + row * 16
        rows.append(
            (
                f32le(payload, row_offset),
                f32le(payload, row_offset + 4),
                f32le(payload, row_offset + 8),
                f32le(payload, row_offset + 12),
            )
        )
    return tuple(rows)  # type: ignore[return-value]


def parse_mesh_object(object_chunk: Chunk, bundle: bytes) -> MeshObject | None:
    children = list(object_chunk.children)
    header = next((chunk for chunk in children if chunk.chunk_id == 0x00034003), None)
    run_metadata = next((chunk for chunk in children if chunk.chunk_id == 0x00034004), None)
    vif_data = next((chunk for chunk in children if chunk.chunk_id == 0x00034005), None)
    texture_refs = next((chunk for chunk in children if chunk.chunk_id == 0x00034006), None)
    if header is None or vif_data is None:
        return None

    header_payload = header.payload(bundle)
    name_info = _find_ascii_name(header_payload)
    if name_info is None:
        return None
    name, name_start = name_info

    vif_payload = _strip_vif_prefix(vif_data.payload(bundle))
    metadata_payload = run_metadata.payload(bundle) if run_metadata else b""
    blocks = _extract_blocks_from_strip_entries(vif_payload, metadata_payload, name)
    if not blocks:
        fallback_runs = extract_vif_vertex_runs(vif_payload)
        if fallback_runs:
            blocks = tuple(
                DecodedBlock(
                    run=run,
                    primitive_mode=_infer_block_primitive_mode(name, None, len(run.vertices)),
                )
                for run in fallback_runs
            )
    if not blocks:
        return None

    return MeshObject(
        name=name,
        chunk_offset=object_chunk.offset,
        transform=_read_transform(header_payload, name_start),
        blocks=blocks,
        texture_hashes=_read_texture_hashes(texture_refs.payload(bundle)) if texture_refs else (),
    )


def parse_scene(chunks: tuple[Chunk, ...], bundle: bytes) -> Scene:
    scene = Scene()
    primary_object_list: list[MeshObject] = []
    found_primary_object_list = False
    for chunk in _walk(chunks):
        if chunk.chunk_id == 0x80034002:
            obj = parse_mesh_object(chunk, bundle)
            if obj is not None:
                scene.objects.append(obj)
                if not found_primary_object_list:
                    primary_object_list.append(obj)
        elif chunk.chunk_id == 0x80034000 and not found_primary_object_list:
            found_primary_object_list = True
            primary_object_list = [
                obj
                for child in chunk.children
                if child.chunk_id == 0x80034002
                for obj in [parse_mesh_object(child, bundle)]
                if obj is not None
            ]
    scene.scenery_instances.extend(_extract_scenery_instances(chunks, bundle, tuple(primary_object_list)))
    return scene


def transformed_vertices(obj: MeshObject, run: VifVertexRun) -> tuple[Vec3, ...]:
    return tuple(transform_point(vertex, obj.transform) for vertex in run.vertices)


def transformed_block_vertices(obj: MeshObject, block: DecodedBlock) -> tuple[Vec3, ...]:
    return transformed_vertices(obj, block.run)


def instantiated_mesh_object(obj: MeshObject, instance: SceneryInstance) -> MeshObject:
    return MeshObject(
        name=f"{obj.name}_inst_{instance.source_chunk_offset:08x}_{instance.record_index:03d}",
        chunk_offset=obj.chunk_offset,
        transform=compose_matrix4(obj.transform, instance.transform),
        blocks=obj.blocks,
        texture_hashes=obj.texture_hashes,
    )


def _walk(chunks: tuple[Chunk, ...]):
    for chunk in chunks:
        yield chunk
        yield from _walk(chunk.children)


def _extract_scenery_instances(
    chunks: tuple[Chunk, ...],
    bundle: bytes,
    primary_objects: tuple[MeshObject, ...],
) -> tuple[SceneryInstance, ...]:
    if not primary_objects:
        return ()

    instances: list[SceneryInstance] = []
    for chunk in walk_chunks(chunks):
        if chunk.chunk_id != 0x00034103:
            continue
        payload = chunk.payload(bundle)
        for record_index, offset in enumerate(range(0, len(payload) - 0x2F, 0x30)):
            object_index = _signed_i16le(payload, offset + 0x0C)
            if object_index < 0 or object_index >= len(primary_objects):
                continue
            instances.append(
                SceneryInstance(
                    object_index=object_index,
                    object_name=primary_objects[object_index].name,
                    transform=_read_scenery_instance_transform(payload, offset),
                    source_chunk_offset=chunk.offset,
                    record_index=record_index,
                )
            )
    return tuple(instances)


def _signed_i16le(data: bytes, offset: int) -> int:
    value = int.from_bytes(data[offset : offset + 2], "little", signed=True)
    return value


def _read_scenery_instance_transform(payload: bytes, offset: int) -> Matrix4:
    scale = 1.0 / 16384.0
    rows = []
    short_offset = offset + 0x1C
    for row in range(3):
        base = short_offset + row * 6
        rows.append(
            (
                _signed_i16le(payload, base) * scale,
                _signed_i16le(payload, base + 2) * scale,
                _signed_i16le(payload, base + 4) * scale,
                0.0,
            )
        )
    rows.append(
        (
            f32le(payload, offset + 0x10),
            f32le(payload, offset + 0x14),
            f32le(payload, offset + 0x18),
            1.0,
        )
    )
    return tuple(rows)  # type: ignore[return-value]


def _read_texture_hashes(payload: bytes) -> tuple[int, ...]:
    hashes: list[int] = []
    for offset in range(0, len(payload) - 3, 8):
        value = u32le(payload, offset)
        if value:
            hashes.append(value)
    return tuple(hashes)


def _read_run_texture_indices(payload: bytes, run_count: int) -> tuple[int | None, ...]:
    records = _read_run_metadata_records(payload, run_count)
    if not records:
        return ()

    indices: list[int | None] = []
    for record in records:
        value = u32le(record, 0)
        indices.append(value if value != 0xFFFFFFFF else None)
    return tuple(indices)


def _read_run_unknown_counts(payload: bytes, run_count: int) -> tuple[int | None, ...]:
    records = _read_run_metadata_records(payload, run_count)
    if not records:
        return ()

    counts: list[int | None] = []
    for record in records:
        packed = u32le(record, 0x1C)
        unknown_count = (packed >> 16) & 0xFF
        counts.append(unknown_count if unknown_count else None)
    return tuple(counts)


def _read_run_render_flags(payload: bytes, run_count: int) -> tuple[int | None, ...]:
    records = _read_run_metadata_records(payload, run_count)
    if not records:
        return ()

    flags: list[int | None] = []
    for record in records:
        value = (u32le(record, 0x0C) >> 16) & 0xFFFF
        flags.append(value if value else None)
    return tuple(flags)


def _read_run_metadata_records(payload: bytes, run_count: int) -> tuple[bytes, ...]:
    if not payload:
        return ()
    payload = _strip_vif_prefix(payload)
    if len(payload) < run_count * 64:
        return ()

    return tuple(payload[offset : offset + 64] for offset in range(0, run_count * 64, 64))


def _strip_vif_prefix(payload: bytes) -> bytes:
    if len(payload) >= 8 and payload[:8] == b"\x11" * 8:
        return payload[8:]
    return payload


def _extract_blocks_from_strip_entries(
    vif_payload: bytes,
    metadata_payload: bytes,
    object_name: str,
) -> tuple[DecodedBlock, ...]:
    record_count = len(_strip_vif_prefix(metadata_payload)) // 64
    records = _read_run_metadata_records(metadata_payload, record_count)
    if not records:
        return ()

    blocks: list[DecodedBlock] = []
    for record in records:
        strip_entry = parse_strip_entry_record(record)
        texture_index = strip_entry.texture_index_raw
        vif_offset = strip_entry.vif_offset
        qword_size = strip_entry.qword_size
        render_flag = strip_entry.render_flags
        topology_code = strip_entry.topology_code
        expected_face_count = strip_entry.count_byte
        if qword_size <= 0 or vif_offset < 0 or vif_offset + qword_size > len(vif_payload):
            return ()
        decoded = extract_vif_vertex_runs(vif_payload[vif_offset : vif_offset + qword_size])
        if len(decoded) != 1:
            return ()
        run = decoded[0]
        blocks.append(
            DecodedBlock(
                run=run,
                primitive_mode=_infer_block_primitive_mode(object_name, expected_face_count or None, len(run.vertices)),
                expected_face_count=expected_face_count or None,
                topology_code=topology_code,
                texture_index=texture_index if texture_index != 0xFFFFFFFF else None,
                render_flag=render_flag or None,
                source_offset=vif_offset,
                source_qword_size=qword_size,
                strip_entry=strip_entry,
            )
        )

    return tuple(blocks)


def _infer_block_primitive_mode(object_name: str, expected_face_count: int | None, vertex_count: int) -> PrimitiveMode:
    # The PS2 render path queues the original VIF packet; metadata byte +0x1e is not a primitive mode.
    del object_name, expected_face_count, vertex_count
    return "strip"
