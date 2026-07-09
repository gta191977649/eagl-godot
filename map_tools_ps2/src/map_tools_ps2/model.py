from __future__ import annotations

from dataclasses import dataclass, field

from .binary import IDENTITY4, Matrix4, Vec3, f32le, transform_point, u32le
from .chunks import Chunk, walk_chunks
from .primitives import PrimitiveMode
from .strip_entries import StripEntryRecord, parse_strip_entry_record
from .vif import VifVertexRun, extract_vif_vertex_runs


CHUNK_TRACK_ROUTE = 0x00034121
CHUNK_TRACK_ROUTE_EDGES = 0x00034122
CHUNK_TRACK_POLYGON_COLLISION = 0x00034132
CHUNK_ROUTE_RADAR = 0x00034510
CHUNK_ALLOWED_ROAD_AREAS = 0x00034530
TRACK_ROUTE_EDGE_RECORD_SIZE = 0x0C
TRACK_COLLISION_POLYGON_RECORD_SIZE = 0x20
ALLOWED_ROAD_AREA_RECORD_SIZE = 0x3C
ALLOWED_ROAD_AREA_MAX_POINTS = 6


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
    name_hash: int | None = None

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
    scenery_info_index: int | None = None
    object_hash: int | None = None
    section_index: int | None = None
    section_chunk_offset: int | None = None


@dataclass(frozen=True)
class ScenerySection:
    section_index: int
    source_chunk_offset: int
    info_table: tuple[tuple[int, int, int], ...]
    instances: tuple[SceneryInstance, ...]


@dataclass(frozen=True)
class SolidPack:
    index: int
    source_chunk_offset: int
    is_scenery_template_palette: bool
    object_chunk_offsets: tuple[int, ...]


@dataclass(frozen=True)
class TrackCollisionPolygon:
    index: int
    selector_byte: int
    material_id: int
    flags: int
    vertex_count: int
    points_ps2: tuple[Vec3, ...]
    source_chunk_offset: int
    source_record_offset: int


@dataclass(frozen=True)
class TrackRoutePoint:
    index: int
    position_ps2: Vec3
    forward_ps2_2d: tuple[float, float]
    segment_length: float
    left_width: float
    right_width: float
    route_edge_index: int
    route_edge_flags: int
    boundary_offsets_raw: tuple[int, int, int, int]
    boundary_offsets: tuple[float, float, float, float]
    source_record_offset: int


@dataclass(frozen=True)
class TrackRouteSegment:
    index: int
    route_index: int
    route_type: int
    flags: int
    points: tuple[TrackRoutePoint, ...]
    source_chunk_offset: int
    source_record_offset: int


@dataclass(frozen=True)
class TrackRouteEdge:
    index: int
    target_route_index: int
    mode: int
    target_point_index: int
    metadata0: int
    metadata1: int
    source_chunk_offset: int
    source_record_offset: int


@dataclass(frozen=True)
class AllowedRoadArea:
    index: int
    declared_vertex_count: int
    points_ps2_2d: tuple[tuple[float, float], ...]
    metadata: bytes
    source_chunk_offset: int
    source_record_offset: int
    source_metadata_offset: int


@dataclass
class Scene:
    objects: list[MeshObject] = field(default_factory=list)
    scenery_instances: list[SceneryInstance] = field(default_factory=list)
    scenery_template_offsets: set[int] = field(default_factory=set)
    solid_packs: list[SolidPack] = field(default_factory=list)
    scenery_sections: list[ScenerySection] = field(default_factory=list)
    track_collision_polygons: list[TrackCollisionPolygon] = field(default_factory=list)
    track_route_segments: list[TrackRouteSegment] = field(default_factory=list)
    track_route_edges: list[TrackRouteEdge] = field(default_factory=list)
    route_points: list[dict[str, object]] = field(default_factory=list)
    route_stats: dict[str, object] = field(default_factory=dict)
    allowed_road_areas: list[AllowedRoadArea] = field(default_factory=list)

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
        name_hash=u32le(header_payload, 0x08) if len(header_payload) >= 0x0C else None,
    )


def parse_scene(chunks: tuple[Chunk, ...], bundle: bytes) -> Scene:
    scene = Scene()
    for chunk in _walk(chunks):
        if chunk.chunk_id == 0x80034002:
            obj = parse_mesh_object(chunk, bundle)
            if obj is not None:
                scene.objects.append(obj)

    objects_by_offset = {obj.chunk_offset: obj for obj in scene.objects}
    primary_object_list: list[MeshObject] = []
    for solid_pack_index, chunk in enumerate(chunk for chunk in _walk(chunks) if chunk.chunk_id == 0x80034000):
        object_offsets = tuple(child.offset for child in chunk.children if child.chunk_id == 0x80034002 and child.offset in objects_by_offset)
        is_template_palette = solid_pack_index == 0
        scene.solid_packs.append(
            SolidPack(
                index=solid_pack_index,
                source_chunk_offset=chunk.offset,
                is_scenery_template_palette=is_template_palette,
                object_chunk_offsets=object_offsets,
            )
        )
        if is_template_palette:
            primary_object_list = [objects_by_offset[offset] for offset in object_offsets]
            scene.scenery_template_offsets = set(object_offsets)

    scene.scenery_sections.extend(
        _extract_scenery_sections(chunks, bundle, tuple(scene.objects), tuple(primary_object_list))
    )
    for section in scene.scenery_sections:
        scene.scenery_instances.extend(section.instances)
    scene.track_collision_polygons.extend(_parse_track_collision_polygons(chunks, bundle))
    scene.track_route_segments.extend(_parse_track_route_segments(chunks, bundle))
    scene.track_route_edges.extend(_parse_track_route_edges(chunks, bundle))
    route_parse = _parse_route_points(chunks, bundle)
    scene.route_points.extend(route_parse["points"])
    scene.route_stats.update(route_parse["stats"])
    scene.allowed_road_areas.extend(_parse_allowed_road_areas(chunks, bundle))
    return scene


def transformed_vertices(obj: MeshObject, run: VifVertexRun) -> tuple[Vec3, ...]:
    return tuple(transform_point(vertex, obj.transform) for vertex in run.vertices)


def transformed_block_vertices(obj: MeshObject, block: DecodedBlock) -> tuple[Vec3, ...]:
    return transformed_vertices(obj, block.run)


def instantiated_mesh_object(obj: MeshObject, instance: SceneryInstance) -> MeshObject:
    return MeshObject(
        name=f"{obj.name}_inst_{instance.source_chunk_offset:08x}_{instance.record_index:03d}",
        chunk_offset=obj.chunk_offset,
        transform=instance.transform,
        blocks=obj.blocks,
        texture_hashes=obj.texture_hashes,
        name_hash=obj.name_hash,
    )


def _walk(chunks: tuple[Chunk, ...]):
    for chunk in chunks:
        yield chunk
        yield from _walk(chunk.children)


def _extract_scenery_instances(
    chunks: tuple[Chunk, ...],
    bundle: bytes,
    objects: tuple[MeshObject, ...],
    primary_objects: tuple[MeshObject, ...],
) -> tuple[SceneryInstance, ...]:
    instances: list[SceneryInstance] = []
    for section in _extract_scenery_sections(chunks, bundle, objects, primary_objects):
        instances.extend(section.instances)
    return tuple(instances)


def _extract_scenery_sections(
    chunks: tuple[Chunk, ...],
    bundle: bytes,
    objects: tuple[MeshObject, ...],
    primary_objects: tuple[MeshObject, ...],
) -> tuple[ScenerySection, ...]:
    if not objects and not primary_objects:
        return ()

    object_indices_by_hash = _object_indices_by_hash(objects)
    sections: list[ScenerySection] = []
    for section_index, chunk in enumerate(chunk for chunk in walk_chunks(chunks) if chunk.chunk_id == 0x80034100):
        info_table = _read_scenery_info_table(chunk, bundle)
        instance_chunk = next((child for child in chunk.children if child.chunk_id == 0x00034103), None)
        instances: list[SceneryInstance] = []
        if instance_chunk is None:
            sections.append(
                ScenerySection(
                    section_index=section_index,
                    source_chunk_offset=chunk.offset,
                    info_table=info_table,
                    instances=(),
                )
            )
            continue
        payload = instance_chunk.payload(bundle)
        for record_index, offset in enumerate(range(0, len(payload) - 0x2F, 0x30)):
            scenery_info_index = _signed_i16le(payload, offset + 0x0C)
            object_index: int | None = None
            object_hash: int | None = None
            if 0 <= scenery_info_index < len(info_table):
                for candidate_hash in info_table[scenery_info_index]:
                    if candidate_hash in object_indices_by_hash:
                        object_hash = candidate_hash
                        object_index = object_indices_by_hash[candidate_hash]
                        break
            if object_index is None and not info_table and 0 <= scenery_info_index < len(primary_objects):
                object_index = objects.index(primary_objects[scenery_info_index])
            if object_index is None:
                continue
            obj = objects[object_index]
            instances.append(
                SceneryInstance(
                    object_index=object_index,
                    object_name=obj.name,
                    transform=_read_scenery_instance_transform(payload, offset),
                    source_chunk_offset=instance_chunk.offset,
                    record_index=record_index,
                    scenery_info_index=scenery_info_index,
                    object_hash=object_hash,
                    section_index=section_index,
                    section_chunk_offset=chunk.offset,
                )
            )
        sections.append(
            ScenerySection(
                section_index=section_index,
                source_chunk_offset=chunk.offset,
                info_table=info_table,
                instances=tuple(instances),
            )
        )
    return tuple(sections)


def _object_indices_by_hash(objects: tuple[MeshObject, ...]) -> dict[int, int]:
    indices: dict[int, int] = {}
    for index, obj in enumerate(objects):
        if obj.name_hash in (None, 0, 0x11111111):
            continue
        indices.setdefault(obj.name_hash, index)
    return indices


def _read_scenery_info_table(section_chunk: Chunk, bundle: bytes) -> tuple[tuple[int, int, int], ...]:
    info_chunk = next((child for child in section_chunk.children if child.chunk_id == 0x00034102), None)
    if info_chunk is None:
        return ()
    payload = info_chunk.payload(bundle)
    table: list[tuple[int, int, int]] = []
    for offset in range(0, len(payload) - 0x27, 0x28):
        table.append(
            (
                u32le(payload, offset),
                u32le(payload, offset + 4),
                u32le(payload, offset + 8),
            )
        )
    return tuple(table)


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


def _parse_track_collision_polygons(chunks: tuple[Chunk, ...], bundle: bytes) -> tuple[TrackCollisionPolygon, ...]:
    polygons: list[TrackCollisionPolygon] = []
    for chunk in walk_chunks(chunks):
        if chunk.chunk_id != CHUNK_TRACK_POLYGON_COLLISION:
            continue
        payload = chunk.payload(bundle)
        polygon_count = len(payload) // TRACK_COLLISION_POLYGON_RECORD_SIZE
        for polygon_index in range(polygon_count):
            offset = polygon_index * TRACK_COLLISION_POLYGON_RECORD_SIZE
            polygon = _parse_track_collision_polygon_record(payload, offset, polygon_index, chunk.offset)
            if polygon is not None:
                polygons.append(polygon)
        break
    return tuple(polygons)


def _parse_track_collision_polygon_record(
    payload: bytes,
    offset: int,
    polygon_index: int,
    chunk_offset: int,
) -> TrackCollisionPolygon | None:
    if offset + TRACK_COLLISION_POLYGON_RECORD_SIZE > len(payload):
        return None
    selector_byte = payload[offset + 0x01]
    material_id = payload[offset + 0x02]
    flags = payload[offset + 0x03]
    vertex_count = 4 if (flags & 0x10) else 3
    z_base = _signed_i16le(payload, offset + 0x04)
    points: list[Vec3] = []
    for vertex_index in range(vertex_count):
        x = _signed_i16le(payload, offset + 0x08 + vertex_index * 2) / 8.0
        y = _signed_i16le(payload, offset + 0x10 + vertex_index * 2) / 8.0
        z = z_base + (_signed_i16le(payload, offset + 0x18 + vertex_index * 2) / 256.0)
        if flags & 0x04:
            z *= 4.0
        points.append(Vec3(x, y, z))
    if len(points) < 3:
        return None
    return TrackCollisionPolygon(
        index=polygon_index,
        selector_byte=selector_byte,
        material_id=material_id,
        flags=flags,
        vertex_count=vertex_count,
        points_ps2=tuple(points),
        source_chunk_offset=chunk_offset,
        source_record_offset=offset,
    )


def _parse_track_route_segments(chunks: tuple[Chunk, ...], bundle: bytes) -> tuple[TrackRouteSegment, ...]:
    segments: list[TrackRouteSegment] = []
    for chunk in walk_chunks(chunks):
        if chunk.chunk_id != CHUNK_TRACK_ROUTE:
            continue
        payload = chunk.payload(bundle)
        offset = 0
        segment_index = 0
        while offset + 0x428 <= len(payload):
            point_count = u32le(payload, offset + 0x10)
            if point_count <= 0 or point_count > 0x400:
                break
            record_size = 0x428 + point_count * 0x70
            if offset + record_size > len(payload):
                break
            points: list[TrackRoutePoint] = []
            for point_index in range(point_count):
                point_offset = offset + 0x428 + point_index * 0x70
                points.append(
                    TrackRoutePoint(
                        index=point_index,
                        position_ps2=Vec3(
                            f32le(payload, point_offset),
                            f32le(payload, point_offset + 0x04),
                            f32le(payload, point_offset + 0x08),
                        ),
                        forward_ps2_2d=(
                            f32le(payload, point_offset + 0x0C),
                            f32le(payload, point_offset + 0x10),
                        ),
                        segment_length=f32le(payload, point_offset + 0x14),
                        left_width=f32le(payload, point_offset + 0x18),
                        right_width=f32le(payload, point_offset + 0x1C),
                        route_edge_index=payload[point_offset + 0x2C],
                        route_edge_flags=u32le(payload, point_offset + 0x2C),
                        boundary_offsets_raw=(
                            _signed_i16le(payload, point_offset + 0x30),
                            _signed_i16le(payload, point_offset + 0x32),
                            _signed_i16le(payload, point_offset + 0x34),
                            _signed_i16le(payload, point_offset + 0x36),
                        ),
                        boundary_offsets=(
                            _signed_i16le(payload, point_offset + 0x30) / 256.0,
                            _signed_i16le(payload, point_offset + 0x32) / 256.0,
                            _signed_i16le(payload, point_offset + 0x34) / 256.0,
                            _signed_i16le(payload, point_offset + 0x36) / 256.0,
                        ),
                        source_record_offset=point_offset,
                    )
                )
            segments.append(
                TrackRouteSegment(
                    index=segment_index,
                    route_index=_signed_i16le(payload, offset + 0x0A),
                    route_type=u32le(payload, offset + 0x0C),
                    flags=u32le(payload, offset + 0x18),
                    points=tuple(points),
                    source_chunk_offset=chunk.offset,
                    source_record_offset=offset,
                )
            )
            offset += record_size
            segment_index += 1
        break
    return tuple(segments)


def _parse_track_route_edges(chunks: tuple[Chunk, ...], bundle: bytes) -> tuple[TrackRouteEdge, ...]:
    edges: list[TrackRouteEdge] = []
    for chunk in walk_chunks(chunks):
        if chunk.chunk_id != CHUNK_TRACK_ROUTE_EDGES:
            continue
        payload = chunk.payload(bundle)
        edge_count = len(payload) // TRACK_ROUTE_EDGE_RECORD_SIZE
        for edge_index in range(edge_count):
            offset = edge_index * TRACK_ROUTE_EDGE_RECORD_SIZE
            edges.append(
                TrackRouteEdge(
                    index=edge_index,
                    target_route_index=payload[offset],
                    mode=payload[offset + 0x01],
                    target_point_index=int.from_bytes(payload[offset + 0x02 : offset + 0x04], "little"),
                    metadata0=u32le(payload, offset + 0x04),
                    metadata1=u32le(payload, offset + 0x08),
                    source_chunk_offset=chunk.offset,
                    source_record_offset=offset,
                )
            )
        break
    return tuple(edges)


def _parse_allowed_road_areas(chunks: tuple[Chunk, ...], bundle: bytes) -> tuple[AllowedRoadArea, ...]:
    areas: list[AllowedRoadArea] = []
    for chunk in walk_chunks(chunks):
        if chunk.chunk_id != CHUNK_ALLOWED_ROAD_AREAS:
            continue
        payload = chunk.payload(bundle)
        if len(payload) < 4:
            break
        declared_count = u32le(payload, 0)
        offset = 4
        for area_index in range(declared_count):
            if offset + ALLOWED_ROAD_AREA_RECORD_SIZE > len(payload):
                break
            vertex_count = u32le(payload, offset)
            if vertex_count < 3 or vertex_count > ALLOWED_ROAD_AREA_MAX_POINTS:
                break
            points: list[tuple[float, float]] = []
            points_offset = offset + 4
            for _ in range(vertex_count):
                points.append(
                    (
                        f32le(payload, points_offset),
                        f32le(payload, points_offset + 4),
                    )
                )
                points_offset += 8
            metadata_offset = offset + 4 + ALLOWED_ROAD_AREA_MAX_POINTS * 8
            metadata = payload[metadata_offset : metadata_offset + 8]
            areas.append(
                AllowedRoadArea(
                    index=area_index,
                    declared_vertex_count=vertex_count,
                    points_ps2_2d=tuple(points),
                    metadata=metadata,
                    source_chunk_offset=chunk.offset,
                    source_record_offset=offset,
                    source_metadata_offset=metadata_offset,
                )
            )
            offset += ALLOWED_ROAD_AREA_RECORD_SIZE
        break
    return tuple(areas)


def _parse_route_points(chunks: tuple[Chunk, ...], bundle: bytes) -> dict[str, object]:
    raw_points: list[dict[str, object]] = []
    source_chunk_offset = -1
    declared_count = 0
    for chunk in walk_chunks(chunks):
        if chunk.chunk_id != CHUNK_ROUTE_RADAR:
            continue
        source_chunk_offset = chunk.offset
        payload = chunk.payload(bundle)
        if len(payload) < 4:
            break
        declared_count = u32le(payload, 0)
        max_records = max(0, (len(payload) - 4) // 32)
        count = min(declared_count, max_records)
        for index in range(count):
            record_offset = 4 + index * 32
            name = _ascii_fixed(payload, record_offset, 16)
            point_ps2_2d = (
                f32le(payload, record_offset + 16),
                f32le(payload, record_offset + 20),
            )
            raw_points.append(
                {
                    "index": index,
                    "name": name,
                    "position_ps2_2d": point_ps2_2d,
                    "position_godot_flat": Vec3(point_ps2_2d[0], 0.0, -point_ps2_2d[1]),
                    "aux": f32le(payload, record_offset + 24),
                    "source_chunk_offset": source_chunk_offset,
                    "source_record_offset": record_offset,
                }
            )
        break

    normalized = _normalized_route_points(raw_points)
    points = normalized["points"]
    return {
        "points": points,
        "stats": {
            "point_count": len(points),
            "raw_point_count": len(raw_points),
            "declared_count": declared_count,
            "source_chunk_offset": source_chunk_offset,
            "source_chunk_id": CHUNK_ROUTE_RADAR if source_chunk_offset >= 0 else 0,
            "filtered_non_route_point_count": normalized["filtered_non_route_point_count"],
            "sorted_by_radar_name": normalized["sorted_by_radar_name"],
        },
    }


def _normalized_route_points(raw_points: list[dict[str, object]]) -> dict[str, object]:
    route_points: list[dict[str, object]] = []
    route_groups: set[str] = set()
    for point in raw_points:
        name = str(point.get("name", ""))
        sequence = _route_point_sequence(name)
        if sequence < 0:
            continue
        route_point = dict(point)
        route_point["route_sequence"] = sequence
        route_point["route_group"] = _route_point_group(name)
        route_points.append(route_point)
        route_groups.add(str(route_point["route_group"]))

    sorted_by_name = False
    if len(route_groups) == 1:
        route_points.sort(key=lambda point: (int(point.get("route_sequence", 0)), int(point.get("index", 0))))
        sorted_by_name = True

    return {
        "points": route_points,
        "filtered_non_route_point_count": len(raw_points) - len(route_points),
        "sorted_by_radar_name": sorted_by_name,
    }


def _route_point_group(name: str) -> str:
    separator = name.rfind("_")
    if separator <= 0:
        return ""
    return name[:separator]


def _route_point_sequence(name: str) -> int:
    separator = name.rfind("_")
    if separator < 0 or separator >= len(name) - 1:
        return -1
    suffix = name[separator + 1 :]
    if not suffix.isdigit():
        return -1
    return int(suffix)


def _ascii_fixed(payload: bytes, offset: int, length: int) -> str:
    limit = min(offset + length, len(payload))
    end = offset
    while end < limit and payload[end] != 0:
        end += 1
    return payload[offset:end].decode("ascii", errors="replace").strip()


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
