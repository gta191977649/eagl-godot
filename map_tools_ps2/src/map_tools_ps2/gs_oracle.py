from __future__ import annotations

from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path

from .chunks import parse_chunks
from .comp import load_bundle_bytes
from .gs_dump import GsDrawPacket, extract_draw_packets, read_gs_dump
from .gs_validate import _draw_st_key, _normalize_st_key, _source_st_key
from .model import MeshObject, parse_scene, transformed_block_vertices
from .primitive_stream import (
    PrimitiveStream,
    Triangle,
    assemble_primitive_stream_triangles,
    primitive_stream_for_block,
)


@dataclass(frozen=True)
class OracleMatch:
    object_index: int
    object_name: str
    block_index: int
    draw_index: int
    vertex_count: int
    topology_code: int | None
    expected_face_count: int | None
    header: tuple[int, int, int, int] | None
    packed_signature: tuple[int, ...]
    source_proof: str
    source_triangles: tuple[Triangle, ...]
    gs_triangles: tuple[Triangle, ...]
    result: str


@dataclass(frozen=True)
class OracleReport:
    track_path: Path
    gsdump_path: Path
    object_filter: str
    source_blocks: int
    draw_packets: int
    matches: tuple[OracleMatch, ...]
    skipped_ambiguous_keys: int

    def format_text(self, limit: int = 80) -> str:
        result_counts = Counter(match.result for match in self.matches)
        proof_counts = Counter(match.source_proof for match in self.matches)
        lines = [
            f"track={self.track_path}",
            f"gsdump={self.gsdump_path}",
            f"object_filter={self.object_filter or '<all>'}",
            f"source_blocks={self.source_blocks} draw_packets={self.draw_packets} matches={len(self.matches)} "
            f"skipped_ambiguous_keys={self.skipped_ambiguous_keys}",
            "results=" + _format_counter(result_counts),
            "proofs=" + _format_counter(proof_counts),
            "groups:",
        ]
        group_counts = Counter(
            (
                match.topology_code,
                match.vertex_count,
                match.expected_face_count,
                match.header,
                match.source_proof,
                match.result,
            )
            for match in self.matches
        )
        for group, count in group_counts.most_common(limit):
            topology_code, vertex_count, expected_faces, header, proof, result = group
            lines.append(
                f"  count={count:4d} topo={_fmt_hex(topology_code)} v={vertex_count} expected={expected_faces} "
                f"header={header} proof={proof} result={result}"
            )
        lines.append("samples:")
        for match in self.matches[:limit]:
            lines.append(
                f"  {match.object_index:04d}:{match.block_index:03d} draw={match.draw_index:05d} "
                f"{match.object_name} v={match.vertex_count} topo={_fmt_hex(match.topology_code)} "
                f"proof={match.source_proof} result={match.result} "
                f"source_faces={len(match.source_triangles)} gs_faces={len(match.gs_triangles)}"
            )
        return "\n".join(lines)


def compare_track_to_gsdump(
    track_path: Path,
    gsdump_path: Path,
    object_filter: str = "",
    st_precision: int = 2,
    max_key_sources: int = 24,
    max_key_draws: int = 24,
) -> OracleReport:
    bundle = load_bundle_bytes(track_path)
    scene = parse_scene(parse_chunks(bundle), bundle)
    draws = extract_draw_packets(read_gs_dump(gsdump_path))

    source_blocks = _source_blocks(scene.objects, object_filter)
    sources_by_key: defaultdict[tuple[int, tuple[tuple[float, float], ...]], list[tuple[int, MeshObject, int, PrimitiveStream]]] = defaultdict(list)
    for object_index, obj, block_index, stream in source_blocks:
        block = obj.blocks[block_index]
        key = _normalize_st_key(_source_st_key(block, st_precision), st_precision)
        if key:
            sources_by_key[(len(block.run.vertices), key)].append((object_index, obj, block_index, stream))

    draws_by_key: defaultdict[tuple[int, tuple[tuple[float, float], ...]], list[tuple[int, GsDrawPacket]]] = defaultdict(list)
    for draw_index, draw in enumerate(draws):
        key = _draw_st_key(draw, st_precision)
        if key:
            draws_by_key[(len(draw.vertices), _normalize_st_key(key, st_precision))].append((draw_index, draw))

    matches: list[OracleMatch] = []
    skipped_ambiguous_keys = 0
    for key in sorted(set(sources_by_key) & set(draws_by_key)):
        source_group = sources_by_key[key]
        draw_group = draws_by_key[key]
        if len(source_group) > max_key_sources or len(draw_group) > max_key_draws:
            skipped_ambiguous_keys += 1
            continue
        for source, draw_pair in zip(source_group, draw_group):
            object_index, obj, block_index, stream = source
            draw_index, draw = draw_pair
            block = obj.blocks[block_index]
            source_triangles = assemble_primitive_stream_triangles(stream)
            gs_triangles = _triangles_for_gs_draw(draw)
            matches.append(
                OracleMatch(
                    object_index=object_index,
                    object_name=obj.name,
                    block_index=block_index,
                    draw_index=draw_index,
                    vertex_count=len(block.run.vertices),
                    topology_code=block.topology_code,
                    expected_face_count=block.expected_face_count,
                    header=block.run.header,
                    packed_signature=tuple(block.run.packed_values[:8]),
                    source_proof=stream.source_proof,
                    source_triangles=source_triangles,
                    gs_triangles=gs_triangles,
                    result=_compare_triangles(source_triangles, gs_triangles),
                )
            )

    return OracleReport(
        track_path=track_path,
        gsdump_path=gsdump_path,
        object_filter=object_filter,
        source_blocks=len(source_blocks),
        draw_packets=len(draws),
        matches=tuple(matches),
        skipped_ambiguous_keys=skipped_ambiguous_keys,
    )


def _source_blocks(
    objects: list[MeshObject],
    object_filter: str,
) -> list[tuple[int, MeshObject, int, PrimitiveStream]]:
    needle = object_filter.lower()
    sources: list[tuple[int, MeshObject, int, PrimitiveStream]] = []
    for object_index, obj in enumerate(objects):
        if needle and needle not in obj.name.lower():
            continue
        for block_index, block in enumerate(obj.blocks):
            vertices = transformed_block_vertices(obj, block)
            stream = primitive_stream_for_block(vertices, block)
            sources.append((object_index, obj, block_index, stream))
    return sources


def _triangles_for_gs_draw(draw: GsDrawPacket) -> tuple[Triangle, ...]:
    count = len(draw.vertices)
    if draw.prim_type == 3:
        return tuple(
            (index, index + 1, index + 2)
            for index in range(0, count - 2, 3)
            if not draw.vertices[index + 2].disable_drawing
        )
    if draw.prim_type == 4:
        return tuple(
            _strip_triangle(index, index, index + 1, index + 2)
            for index in range(count - 2)
            if not draw.vertices[index + 2].disable_drawing
        )
    if draw.prim_type == 5:
        return tuple(
            (0, index, index + 1)
            for index in range(1, count - 1)
            if not draw.vertices[index + 1].disable_drawing
        )
    return ()


def _compare_triangles(source_triangles: tuple[Triangle, ...], gs_triangles: tuple[Triangle, ...]) -> str:
    if source_triangles == gs_triangles:
        return "exact"
    if _connectivity_key(source_triangles) == _connectivity_key(gs_triangles):
        return "connectivity"
    if len(source_triangles) == len(gs_triangles):
        return "count_only"
    return "mismatch"


def _connectivity_key(triangles: tuple[Triangle, ...]) -> tuple[tuple[int, int, int], ...]:
    return tuple(sorted(tuple(sorted(triangle)) for triangle in triangles))


def _strip_triangle(strip_index: int, a: int, b: int, c: int) -> Triangle:
    return (a, c, b) if strip_index & 1 else (a, b, c)


def _format_counter(counter: Counter[str]) -> str:
    if not counter:
        return "-"
    return ",".join(f"{key}:{value}" for key, value in sorted(counter.items()))


def _fmt_hex(value: int | None) -> str:
    return "-" if value is None else f"0x{value:x}"
