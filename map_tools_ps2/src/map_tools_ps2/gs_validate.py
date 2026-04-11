from __future__ import annotations

from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path

from .chunks import parse_chunks
from .comp import load_bundle_bytes
from .glb_writer import _indices_for_block
from .gs_dump import GsDrawPacket, extract_draw_packets, read_gs_dump
from .model import DecodedBlock, MeshObject, parse_scene, transformed_block_vertices


@dataclass(frozen=True)
class SourceBlockSignature:
    object_name: str
    object_index: int
    block_index: int
    vertex_count: int
    primitive_mode: str
    emitted_face_count: int
    texture_index: int | None
    texture_hash: int | None
    st_key: tuple[tuple[float, float], ...]
    normalized_st_key: tuple[tuple[float, float], ...]


@dataclass(frozen=True)
class BlockMatch:
    source: SourceBlockSignature
    exact_draws: tuple[GsDrawPacket, ...]
    normalized_draws: tuple[GsDrawPacket, ...]
    vertex_count_draws: tuple[GsDrawPacket, ...]


@dataclass(frozen=True)
class GsValidationReport:
    track_path: Path
    gsdump_path: Path
    object_filter: str
    draw_count: int
    primitive_counts: Counter[int]
    source_blocks: tuple[SourceBlockSignature, ...]
    matches: tuple[BlockMatch, ...]

    def format_text(self, limit: int = 48) -> str:
        lines = [
            f"track={self.track_path}",
            f"gsdump={self.gsdump_path}",
            f"object_filter={self.object_filter}",
            "gs_draws="
            + str(self.draw_count)
            + " primitive_counts="
            + ", ".join(f"{primitive}:{count}" for primitive, count in sorted(self.primitive_counts.items())),
            f"source_blocks={len(self.source_blocks)}",
        ]

        exact_count = sum(1 for match in self.matches if match.exact_draws)
        normalized_count = sum(1 for match in self.matches if match.normalized_draws)
        fan_mismatches = [
            match
            for match in self.matches
            if match.source.primitive_mode == "strip"
            and any(draw.prim_type == 5 for draw in match.exact_draws + match.normalized_draws)
        ]
        lines.append(
            f"exact_st_matches={exact_count} normalized_st_matches={normalized_count} "
            f"strip_source_to_fan_draw_matches={len(fan_mismatches)}"
        )

        for match in self.matches[:limit]:
            exact_counts = Counter(draw.prim_type for draw in match.exact_draws)
            normalized_counts = Counter(draw.prim_type for draw in match.normalized_draws)
            vertex_counts = Counter(draw.prim_type for draw in match.vertex_count_draws)
            source = match.source
            lines.append(
                f"{source.object_index:04d}:{source.block_index:03d} {source.object_name} "
                f"v={source.vertex_count} mode={source.primitive_mode} faces={source.emitted_face_count} "
                f"tex={source.texture_index} exact="
                + _format_counter(exact_counts)
                + " norm="
                + _format_counter(normalized_counts)
                + " same_vcount="
                + _format_counter(vertex_counts)
            )
        return "\n".join(lines)


def validate_gsdump_against_track(
    track_path: Path,
    gsdump_path: Path,
    object_filter: str = "TRN_SECTION60_UNDERROAD",
    texture_dir: Path | None = None,
    draw_start: int = 0,
    draw_stop: int | None = None,
    st_precision: int = 2,
) -> GsValidationReport:
    dump = read_gs_dump(gsdump_path)
    draws = extract_draw_packets(dump)
    if draw_stop is not None:
        draws = draws[draw_start:draw_stop]
    elif draw_start:
        draws = draws[draw_start:]

    data = load_bundle_bytes(track_path)
    del texture_dir
    scene = parse_scene(parse_chunks(data), data)
    source_blocks = _source_block_signatures(scene.objects, object_filter, st_precision)

    draws_by_st: defaultdict[tuple[int, tuple[tuple[float, float], ...]], list[GsDrawPacket]] = defaultdict(list)
    draws_by_normalized_st: defaultdict[tuple[int, tuple[tuple[float, float], ...]], list[GsDrawPacket]] = defaultdict(list)
    draws_by_vertex_count: defaultdict[int, list[GsDrawPacket]] = defaultdict(list)
    for draw in draws:
        draws_by_vertex_count[len(draw.vertices)].append(draw)
        st_key = _draw_st_key(draw, st_precision)
        if st_key:
            draws_by_st[(len(draw.vertices), st_key)].append(draw)
            draws_by_normalized_st[(len(draw.vertices), _normalize_st_key(st_key, st_precision))].append(draw)

    matches = tuple(
        BlockMatch(
            source=source,
            exact_draws=tuple(draws_by_st.get((source.vertex_count, source.st_key), ())),
            normalized_draws=tuple(draws_by_normalized_st.get((source.vertex_count, source.normalized_st_key), ())),
            vertex_count_draws=tuple(draws_by_vertex_count.get(source.vertex_count, ())),
        )
        for source in source_blocks
    )

    return GsValidationReport(
        track_path=track_path,
        gsdump_path=gsdump_path,
        object_filter=object_filter,
        draw_count=len(draws),
        primitive_counts=Counter(draw.prim_type for draw in draws),
        source_blocks=tuple(source_blocks),
        matches=matches,
    )


def _source_block_signatures(
    objects: list[MeshObject],
    object_filter: str,
    st_precision: int,
) -> tuple[SourceBlockSignature, ...]:
    signatures: list[SourceBlockSignature] = []
    needle = object_filter.lower()
    for object_index, obj in enumerate(objects):
        if needle and needle not in obj.name.lower():
            continue
        for block_index, block in enumerate(obj.blocks):
            vertices = transformed_block_vertices(obj, block)
            texture_hash = _texture_hash_for_block(obj, block)
            signatures.append(
                SourceBlockSignature(
                    object_name=obj.name,
                    object_index=object_index,
                    block_index=block_index,
                    vertex_count=len(block.run.vertices),
                    primitive_mode=block.primitive_mode,
                    emitted_face_count=len(_indices_for_block(vertices, obj.name, block)) // 3,
                    texture_index=block.texture_index,
                    texture_hash=texture_hash,
                    st_key=_source_st_key(block, st_precision),
                    normalized_st_key=_normalize_st_key(_source_st_key(block, st_precision), st_precision),
                )
            )
    return tuple(signatures)


def _texture_hash_for_block(obj: MeshObject, block: DecodedBlock) -> int | None:
    if block.texture_index is None:
        return None
    if block.texture_index < 0 or block.texture_index >= len(obj.texture_hashes):
        return None
    return obj.texture_hashes[block.texture_index]


def _source_st_key(block: DecodedBlock, precision: int) -> tuple[tuple[float, float], ...]:
    return tuple((round(u, precision), round(v, precision)) for u, v in block.run.texcoords)


def _draw_st_key(draw: GsDrawPacket, precision: int) -> tuple[tuple[float, float], ...] | None:
    values: list[tuple[float, float]] = []
    for st in draw.st:
        if st is None:
            return None
        values.append((round(st[0], precision), round(st[1], precision)))
    return tuple(values)


def _normalize_st_key(
    values: tuple[tuple[float, float], ...],
    precision: int,
) -> tuple[tuple[float, float], ...]:
    if not values:
        return ()
    us = [value[0] for value in values]
    vs = [value[1] for value in values]
    min_u, max_u = min(us), max(us)
    min_v, max_v = min(vs), max(vs)
    range_u = max_u - min_u
    range_v = max_v - min_v
    return tuple(
        (
            round((u - min_u) / range_u, precision) if range_u > 1e-8 else 0.0,
            round((v - min_v) / range_v, precision) if range_v > 1e-8 else 0.0,
        )
        for u, v in values
    )


def _format_counter(counter: Counter[int]) -> str:
    if not counter:
        return "-"
    return ",".join(f"{key}:{value}" for key, value in sorted(counter.items()))
