from __future__ import annotations

from dataclasses import dataclass
from typing import Literal

from .binary import Vec3
from .model import DecodedBlock
from .strip_entries import StripEntryRecord


GS_PRIM_TRIANGLE = 3
GS_PRIM_TRIANGLE_STRIP = 4
GS_PRIM_TRIANGLE_FAN = 5

PrimitiveStreamProof = Literal["vif_control", "fallback"]
Triangle = tuple[int, int, int]


@dataclass(frozen=True)
class PrimitiveStream:
    prim_type: int | None
    vertices: tuple[Vec3, ...]
    texcoords: tuple[tuple[float, float], ...]
    packed_values: tuple[int, ...]
    metadata_record: StripEntryRecord | None
    adc_disabled: tuple[bool, ...]
    segments: tuple[tuple[int, int], ...]
    source_proof: PrimitiveStreamProof


def primitive_stream_for_block(vertices: tuple[Vec3, ...], block: DecodedBlock) -> PrimitiveStream:
    prim_type = _gs_prim_type_for_block(block)
    adc_disabled: tuple[bool, ...] = tuple(False for _ in vertices)
    source_proof: PrimitiveStreamProof = "fallback"

    if prim_type == GS_PRIM_TRIANGLE_STRIP:
        vif_adc_disabled = adc_disabled_from_vif_control(block.run.header, block.run.tri_cull, len(vertices))
        if vif_adc_disabled is not None:
            adc_disabled = vif_adc_disabled
            source_proof = "vif_control"

    return PrimitiveStream(
        prim_type=prim_type,
        vertices=vertices,
        texcoords=block.run.texcoords,
        packed_values=block.run.packed_values,
        metadata_record=block.strip_entry,
        adc_disabled=adc_disabled,
        segments=segments_from_adc_disabled(prim_type, adc_disabled),
        source_proof=source_proof,
    )


def assemble_primitive_stream_indices(stream: PrimitiveStream) -> list[int]:
    triangles = assemble_primitive_stream_triangles(stream)
    return [index for triangle in triangles for index in triangle]


def assemble_primitive_stream_triangles(stream: PrimitiveStream) -> tuple[Triangle, ...]:
    count = len(stream.vertices)
    if stream.prim_type == GS_PRIM_TRIANGLE:
        return tuple(
            (index, index + 1, index + 2)
            for index in range(0, count - 2, 3)
            if not stream.adc_disabled[index + 2]
        )
    if stream.prim_type == GS_PRIM_TRIANGLE_STRIP:
        triangles: list[Triangle] = []
        face = 1
        for index in range(count):
            if stream.adc_disabled[index]:
                face = 1
                continue
            a = index - 1 - face
            b = index - 1
            c = index - 1 + face
            if a >= 0 and b >= 0 and c >= 0 and a < count and b < count and c < count:
                triangles.append((a, b, c))
            face = -face
        return tuple(triangles)
    if stream.prim_type == GS_PRIM_TRIANGLE_FAN:
        return tuple(
            (0, index, index + 1)
            for index in range(1, count - 1)
            if not stream.adc_disabled[index + 1]
        )
    return ()


def adc_disabled_from_vif_control(
    header: tuple[int, int, int, int] | None,
    tri_cull: tuple[int, int, int, int] | None,
    vertex_count: int,
) -> tuple[bool, ...] | None:
    if header is None or tri_cull is None or vertex_count <= 0:
        return None

    num_vertices = header[0]
    mode = header[1]
    if num_vertices <= 0 or num_vertices > vertex_count or mode > 7:
        return None

    mask = _vif_control_mask(num_vertices, mode, tri_cull)
    return tuple(bool((mask >> (31 - index)) & 1) for index in range(vertex_count))


def segments_from_adc_disabled(prim_type: int | None, adc_disabled: tuple[bool, ...]) -> tuple[tuple[int, int], ...]:
    count = len(adc_disabled)
    if prim_type != GS_PRIM_TRIANGLE_STRIP or count < 3:
        return ((0, count),)

    starts = [0]
    for index in range(1, count - 1):
        if adc_disabled[index] and adc_disabled[index + 1]:
            starts.append(index)
    starts = sorted(set(starts))

    segments: list[tuple[int, int]] = []
    for segment_index, start in enumerate(starts):
        end = starts[segment_index + 1] if segment_index + 1 < len(starts) else count
        if end - start >= 3:
            segments.append((start, end))
    return tuple(segments) if segments else ((0, count),)


def _gs_prim_type_for_block(block: DecodedBlock) -> int | None:
    if block.primitive_mode == "triangles":
        return GS_PRIM_TRIANGLE
    if block.primitive_mode == "fan":
        return GS_PRIM_TRIANGLE_FAN
    if block.primitive_mode == "strip":
        return GS_PRIM_TRIANGLE_STRIP
    return None


def _vif_control_mask(num_vertices: int, mode: int, tri_cull: tuple[int, int, int, int]) -> int:
    use_upper = mode & 0x04
    downer_side = (-(((mode & 0x03) + 1) >> 2) << (use_upper >> 2)) & 0x03
    upper_side = ~(-use_upper)

    downer = tri_cull[downer_side] if 0 <= downer_side < len(tri_cull) else 0
    upper = tri_cull[upper_side] if 0 <= upper_side < len(tri_cull) else 0

    hi_downer = downer >> 18
    lo_downer = downer & 0x7FFF
    hi_downer_swap = hi_downer ^ (lo_downer & 0x1E)
    hi_upper_swap = ((upper >> 2) | ((mode + 1) >> 1)) & 0x04

    new_downer = (lo_downer << 4) | (hi_downer_swap >> 1)
    new_upper = (upper >> 2) ^ (((hi_downer_swap >> 1) & 0x07) << 13) ^ (hi_upper_swap << 18)

    mask = _shift_left(new_downer, ((mode - 3) << 2) - 3)
    if use_upper:
        mask = (mask & (-1 << 13)) | (new_upper & 0x3FFF)
    mask = _shift_left(mask, (7 - mode) << 2)
    mask &= -1 << (32 - num_vertices)
    return mask & 0xFFFFFFFF


def _shift_left(value: int, shift: int) -> int:
    if shift >= 0:
        return value << shift
    return value >> -shift
