from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from .binary import Vec3
from .chunks import Chunk, parse_chunks, walk_chunks
from .comp import load_bundle_bytes
from .gs_dump import GsDrawPacket, extract_draw_packets, read_gs_dump
from .model import DecodedBlock, MeshObject, parse_scene, transformed_block_vertices, _strip_vif_prefix


Triangle = tuple[int, int, int]


@dataclass(frozen=True)
class PrimitiveHypothesis:
    name: str
    triangles: tuple[Triangle, ...]
    triangle_count_match: bool
    ordering_match: bool
    connectivity_match: bool
    note: str = ""


@dataclass(frozen=True)
class PrimitiveProbeReport:
    track_path: Path
    gsdump_path: Path
    object_index: int
    object_name: str
    block_index: int
    draw_index: int
    source_vertex_count: int
    block_header: tuple[int, int, int, int] | None
    metadata_record_hex: str | None
    source_offset: int | None
    source_qword_size: int | None
    expected_face_count: int | None
    topology_code: int | None
    gs_prim_type: int
    gs_prim_raw: int
    gs_disabled_indices: tuple[int, ...]
    gs_restart_boundaries: tuple[int, ...]
    gs_triangles: tuple[Triangle, ...]
    st_order_max_error: float | None
    hypotheses: tuple[PrimitiveHypothesis, ...]

    @property
    def selected(self) -> PrimitiveHypothesis | None:
        for hypothesis in self.hypotheses:
            if hypothesis.triangle_count_match and hypothesis.ordering_match and hypothesis.connectivity_match:
                return hypothesis
        return None

    def format_text(self) -> str:
        lines = [
            f"track={self.track_path}",
            f"gsdump={self.gsdump_path}",
            f"source={self.object_index}:{self.object_name} block={self.block_index}",
            f"source_vertices={self.source_vertex_count}",
            f"draw={self.draw_index} prim_type={self.gs_prim_type} prim_raw=0x{self.gs_prim_raw:x}",
            f"block_header={self.block_header} expected_faces={self.expected_face_count} topology_code={_fmt_hex(self.topology_code)}",
            f"source_vif_offset={_fmt_hex(self.source_offset)} source_qword_size={self.source_qword_size}",
            f"metadata_record={self.metadata_record_hex or '-'}",
            f"gs_disabled_indices={list(self.gs_disabled_indices)}",
            f"gs_restart_boundaries={list(self.gs_restart_boundaries)}",
            f"gs_visible_triangles={len(self.gs_triangles)} {list(self.gs_triangles)}",
            f"normalized_st_order_max_error={self.st_order_max_error if self.st_order_max_error is not None else '-'}",
            "hypotheses:",
        ]
        for hypothesis in self.hypotheses:
            lines.append(
                "  "
                + hypothesis.name
                + f": triangles={len(hypothesis.triangles)} "
                + f"count_match={hypothesis.triangle_count_match} "
                + f"order_match={hypothesis.ordering_match} "
                + f"connectivity_match={hypothesis.connectivity_match}"
                + (f" note={hypothesis.note}" if hypothesis.note else "")
            )
            lines.append(f"    {list(hypothesis.triangles)}")
        selected = self.selected
        if selected is None:
            lines.append("selected=-")
        else:
            lines.append(f"selected={selected.name}")
            lines.append(f"rule={_rule_text(self, selected)}")
        return "\n".join(lines)


def probe_primitive_rule(
    track_path: Path,
    gsdump_path: Path,
    object_name: str = "XS_LIGHTPOSTA_1_00",
    block_index: int = 6,
    draw_index: int = 1761,
    object_index: int | None = None,
) -> PrimitiveProbeReport:
    bundle = load_bundle_bytes(track_path)
    chunks = parse_chunks(bundle)
    scene = parse_scene(chunks, bundle)
    obj_index, obj = _select_object(scene.objects, object_name, object_index)
    if block_index < 0 or block_index >= len(obj.blocks):
        raise ValueError(f"{obj.name} has {len(obj.blocks)} blocks; block {block_index} is out of range")
    block = obj.blocks[block_index]

    draws = extract_draw_packets(read_gs_dump(gsdump_path))
    if draw_index < 0 or draw_index >= len(draws):
        raise ValueError(f"GS dump has {len(draws)} draw packets; draw {draw_index} is out of range")
    draw = draws[draw_index]
    if len(block.run.vertices) != len(draw.vertices):
        raise ValueError(
            f"source block has {len(block.run.vertices)} vertices but GS draw has {len(draw.vertices)}"
        )

    metadata_record = _metadata_record_for_block(chunks, bundle, obj.chunk_offset, block_index)
    gs_triangles = _triangles_for_gs_draw(draw)
    restart_boundaries = _restart_boundaries_from_gs_disable(draw)
    source_vertices = transformed_block_vertices(obj, block)
    hypotheses = _build_hypotheses(source_vertices, draw, restart_boundaries, gs_triangles)

    return PrimitiveProbeReport(
        track_path=track_path,
        gsdump_path=gsdump_path,
        object_index=obj_index,
        object_name=obj.name,
        block_index=block_index,
        draw_index=draw_index,
        source_vertex_count=len(block.run.vertices),
        block_header=block.run.header,
        metadata_record_hex=metadata_record.hex() if metadata_record is not None else None,
        source_offset=block.source_offset,
        source_qword_size=block.source_qword_size,
        expected_face_count=block.expected_face_count,
        topology_code=block.topology_code,
        gs_prim_type=draw.prim_type,
        gs_prim_raw=draw.prim_raw,
        gs_disabled_indices=tuple(index for index, vertex in enumerate(draw.vertices) if vertex.disable_drawing),
        gs_restart_boundaries=restart_boundaries,
        gs_triangles=gs_triangles,
        st_order_max_error=_normalized_st_max_error(block, draw),
        hypotheses=hypotheses,
    )


def _select_object(
    objects: list[MeshObject],
    object_name: str,
    object_index: int | None,
) -> tuple[int, MeshObject]:
    if object_index is not None:
        if object_index < 0 or object_index >= len(objects):
            raise ValueError(f"object index {object_index} is out of range")
        obj = objects[object_index]
        if obj.name != object_name:
            raise ValueError(f"object {object_index} is {obj.name}, not {object_name}")
        return object_index, obj

    for index, obj in enumerate(objects):
        if obj.name == object_name:
            return index, obj
    raise ValueError(f"object {object_name!r} was not found")


def _metadata_record_for_block(
    chunks: tuple[Chunk, ...],
    bundle: bytes,
    object_chunk_offset: int,
    block_index: int,
) -> bytes | None:
    object_chunk = next(
        (chunk for chunk in walk_chunks(chunks) if chunk.chunk_id == 0x80034002 and chunk.offset == object_chunk_offset),
        None,
    )
    if object_chunk is None:
        return None
    metadata = next((chunk for chunk in object_chunk.children if chunk.chunk_id == 0x00034004), None)
    if metadata is None:
        return None
    payload = _strip_vif_prefix(metadata.payload(bundle))
    offset = block_index * 64
    if offset + 64 > len(payload):
        return None
    return payload[offset : offset + 64]


def _build_hypotheses(
    vertices: tuple[Vec3, ...],
    draw: GsDrawPacket,
    restart_boundaries: tuple[int, ...],
    gs_triangles: tuple[Triangle, ...],
) -> tuple[PrimitiveHypothesis, ...]:
    count = len(draw.vertices)
    candidates = (
        ("A triangle list", _triangle_list_triangles(count), ""),
        ("B triangle strip", _strip_triangles(count), ""),
        ("C triangle strip with degenerate skip", _strip_triangles_skip_degenerate(vertices), ""),
        (
            "D triangle strip with restart",
            _strip_triangles_with_boundaries(count, restart_boundaries),
            f"boundaries={list(restart_boundaries)}",
        ),
        (
            "E mixed strip/list",
            _mixed_triangles_from_restart_segments(count, restart_boundaries),
            "tested as triangle-list assembly inside the GS restart segments",
        ),
    )
    return tuple(
        PrimitiveHypothesis(
            name=name,
            triangles=triangles,
            triangle_count_match=len(triangles) == len(gs_triangles),
            ordering_match=triangles == gs_triangles,
            connectivity_match=_connectivity_key(triangles) == _connectivity_key(gs_triangles),
            note=note,
        )
        for name, triangles, note in candidates
    )


def _triangles_for_gs_draw(draw: GsDrawPacket) -> tuple[Triangle, ...]:
    count = len(draw.vertices)
    if draw.prim_type == 3:
        triangles = _triangle_list_triangles(count)
        return tuple(
            triangle for triangle in triangles if not draw.vertices[triangle[2]].disable_drawing
        )
    if draw.prim_type == 4:
        triangles: list[Triangle] = []
        for index in range(count - 2):
            if draw.vertices[index + 2].disable_drawing:
                continue
            triangles.append(_strip_triangle(index, index, index + 1, index + 2))
        return tuple(triangles)
    if draw.prim_type == 5:
        triangles = tuple((0, index, index + 1) for index in range(1, count - 1))
        return tuple(
            triangle for index, triangle in enumerate(triangles, start=2) if not draw.vertices[index].disable_drawing
        )
    return ()


def _restart_boundaries_from_gs_disable(draw: GsDrawPacket) -> tuple[int, ...]:
    if draw.prim_type != 4:
        return ()
    boundaries: list[int] = []
    vertices = draw.vertices
    for index in range(3, len(vertices) - 2):
        if vertices[index].disable_drawing and vertices[index + 1].disable_drawing:
            boundaries.append(index)
    return tuple(boundaries)


def _triangle_list_triangles(count: int) -> tuple[Triangle, ...]:
    return tuple((index, index + 1, index + 2) for index in range(0, count - 2, 3))


def _strip_triangles(count: int) -> tuple[Triangle, ...]:
    return tuple(_strip_triangle(index, index, index + 1, index + 2) for index in range(count - 2))


def _strip_triangles_skip_degenerate(vertices: tuple[Vec3, ...]) -> tuple[Triangle, ...]:
    triangles: list[Triangle] = []
    for index in range(len(vertices) - 2):
        triangle = _strip_triangle(index, index, index + 1, index + 2)
        if not _is_degenerate(vertices[triangle[0]], vertices[triangle[1]], vertices[triangle[2]]):
            triangles.append(triangle)
    return tuple(triangles)


def _strip_triangles_with_boundaries(count: int, boundaries: tuple[int, ...]) -> tuple[Triangle, ...]:
    triangles: list[Triangle] = []
    start = 0
    for boundary in tuple(boundary for boundary in boundaries if 0 < boundary < count):
        triangles.extend(_strip_segment_triangles(start, boundary))
        start = boundary
    triangles.extend(_strip_segment_triangles(start, count))
    return tuple(triangles)


def _strip_segment_triangles(start: int, end: int) -> tuple[Triangle, ...]:
    return tuple(
        _strip_triangle(local_index, start + local_index, start + local_index + 1, start + local_index + 2)
        for local_index in range(max(0, end - start - 2))
    )


def _mixed_triangles_from_restart_segments(count: int, boundaries: tuple[int, ...]) -> tuple[Triangle, ...]:
    triangles: list[Triangle] = []
    start = 0
    for boundary in tuple(boundary for boundary in boundaries if 0 < boundary < count) + (count,):
        triangles.extend((start + index, start + index + 1, start + index + 2) for index in range(0, boundary - start - 2, 3))
        start = boundary
    return tuple(triangles)


def _strip_triangle(strip_index: int, a: int, b: int, c: int) -> Triangle:
    return (a, c, b) if strip_index & 1 else (a, b, c)


def _connectivity_key(triangles: tuple[Triangle, ...]) -> tuple[tuple[int, int, int], ...]:
    return tuple(sorted(tuple(sorted(triangle)) for triangle in triangles))


def _is_degenerate(a: Vec3, b: Vec3, c: Vec3) -> bool:
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


def _normalized_st_max_error(block: DecodedBlock, draw: GsDrawPacket) -> float | None:
    if len(block.run.texcoords) != len(draw.st) or any(st is None for st in draw.st):
        return None
    source = _normalize_pairs(block.run.texcoords)
    gs = _normalize_pairs(tuple((st[0], st[1]) for st in draw.st if st is not None))
    if len(source) != len(gs):
        return None
    return max((abs(a[0] - b[0]) + abs(a[1] - b[1])) for a, b in zip(source, gs, strict=True))


def _normalize_pairs(values: tuple[tuple[float, float], ...]) -> tuple[tuple[float, float], ...]:
    if not values:
        return ()
    us = [value[0] for value in values]
    vs = [value[1] for value in values]
    min_u, max_u = min(us), max(us)
    min_v, max_v = min(vs), max(vs)
    range_u = max(max_u - min_u, 1e-8)
    range_v = max(max_v - min_v, 1e-8)
    return tuple(((u - min_u) / range_u, (v - min_v) / range_v) for u, v in values)


def _rule_text(report: PrimitiveProbeReport, selected: PrimitiveHypothesis) -> str:
    if selected.name == "D triangle strip with restart":
        return (
            "Use GS triangle strip assembly, but treat consecutive ADC/disable vertices as strip restart bridges. "
            f"For this block, header={report.block_header}, topology_code={_fmt_hex(report.topology_code)}, "
            f"expected_faces={report.expected_face_count}: split the raw stream at "
            f"{list(report.gs_restart_boundaries)}; equivalent segments are "
            f"{_segments_text(report.source_vertex_count, report.gs_restart_boundaries)}."
        )
    return selected.name


def _segments_text(count: int, boundaries: tuple[int, ...]) -> str:
    points = (0,) + boundaries + (count,)
    return str([(points[index], points[index + 1]) for index in range(len(points) - 1)])


def _fmt_hex(value: int | None) -> str:
    return "-" if value is None else f"0x{value:x}"
