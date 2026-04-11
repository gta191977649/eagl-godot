from __future__ import annotations

import shutil
import struct
import subprocess
from dataclasses import dataclass
from pathlib import Path


GIF_REG_PRIM = 0x00
GIF_REG_RGBAQ = 0x01
GIF_REG_ST = 0x02
GIF_REG_UV = 0x03
GIF_REG_XYZF2 = 0x04
GIF_REG_XYZ2 = 0x05
GIF_REG_XYZF3 = 0x0C
GIF_REG_XYZ3 = 0x0D
GIF_REG_AD = 0x0E

GS_REG_PRIM = 0x00
GS_REG_TEX0_1 = 0x06
GS_REG_TEX0_2 = 0x07
GS_REG_CLAMP_1 = 0x08
GS_REG_CLAMP_2 = 0x09
GS_REG_TEX1_1 = 0x14
GS_REG_TEX1_2 = 0x15
GS_REG_TEX2_1 = 0x16
GS_REG_TEX2_2 = 0x17
GS_REG_ALPHA_1 = 0x42
GS_REG_ALPHA_2 = 0x43
GS_REG_TEST_1 = 0x47
GS_REG_TEST_2 = 0x48
GS_REG_TEXA = 0x3B

GIF_FLG_PACKED = 0
GIF_FLG_REGLIST = 1
GIF_FLG_IMAGE = 2


@dataclass(frozen=True)
class GsDump:
    serial: str
    crc: int
    screenshot_size: tuple[int, int]
    event_counts: dict[int, int]
    path3_transfers: tuple[bytes, ...]


@dataclass(frozen=True)
class GifTag:
    transfer_index: int
    tag_offset: int
    nloop: int
    eop: bool
    pre: bool
    prim: int
    flg: int
    registers: tuple[int, ...]


@dataclass(frozen=True)
class GsScreenVertex:
    x: int
    y: int
    z: int
    fog: int | None
    register: int
    disable_drawing: bool = False


@dataclass(frozen=True)
class GsDrawPacket:
    transfer_index: int
    tag_offset: int
    prim_type: int
    prim_raw: int
    texture_state: tuple[tuple[int, int], ...]
    vertices: tuple[GsScreenVertex, ...]
    st: tuple[tuple[float, float, float] | None, ...]
    uv: tuple[tuple[int, int] | None, ...]
    rgbaq: tuple[tuple[int, int, int, int, float] | None, ...]


def read_gs_dump(path: Path) -> GsDump:
    return parse_gs_dump(_read_dump_bytes(path))


def _read_dump_bytes(path: Path) -> bytes:
    if path.suffix.lower() != ".zst":
        return path.read_bytes()

    zstd = shutil.which("zstd")
    if zstd is None:
        raise RuntimeError("zstd is required to read .gs.zst dumps")
    return subprocess.check_output([zstd, "-dc", str(path)])


def parse_gs_dump(data: bytes) -> GsDump:
    if len(data) < 8:
        raise ValueError("GS dump is too small")

    magic, header_size = struct.unpack_from("<II", data, 0)
    if magic != 0xFFFFFFFF:
        raise ValueError("only new-format PCSX2 GS dumps are supported")

    (
        _state_version,
        state_size,
        serial_offset,
        serial_size,
        crc,
        screenshot_width,
        screenshot_height,
        _screenshot_offset,
        _screenshot_size,
    ) = struct.unpack_from("<IIIIIIIII", data, 8)

    header_base = 8
    serial = data[header_base + serial_offset : header_base + serial_offset + serial_size].decode(
        "ascii", errors="replace"
    )

    event_counts: dict[int, int] = {}
    path3_transfers: list[bytes] = []
    offset = 8 + header_size + state_size + 0x2000
    while offset < len(data):
        event_id = data[offset]
        offset += 1
        event_counts[event_id] = event_counts.get(event_id, 0) + 1
        if event_id == 0:
            path_index = data[offset]
            size = struct.unpack_from("<I", data, offset + 1)[0]
            offset += 5
            payload = data[offset : offset + size]
            if path_index == 3:
                path3_transfers.append(payload)
            offset += size
        elif event_id == 1:
            offset += 1
        elif event_id == 2:
            offset += 4
        elif event_id == 3:
            offset += 0x2000
        else:
            raise ValueError(f"unknown GS dump event {event_id} at 0x{offset - 1:x}")

    return GsDump(
        serial=serial.rstrip("\0"),
        crc=crc,
        screenshot_size=(screenshot_width, screenshot_height),
        event_counts=event_counts,
        path3_transfers=tuple(path3_transfers),
    )


def extract_draw_packets(dump: GsDump) -> tuple[GsDrawPacket, ...]:
    return extract_draw_packets_from_path3_transfers(dump.path3_transfers)


def extract_draw_packets_from_path3_transfers(path3_transfers: tuple[bytes, ...]) -> tuple[GsDrawPacket, ...]:
    draws: list[GsDrawPacket] = []
    current_prim = 0
    texture_state: dict[int, int] = {}

    for transfer_index, payload in enumerate(path3_transfers):
        pos = 0
        while pos + 16 <= len(payload):
            tag_offset = pos
            tag = _read_gif_tag(payload, transfer_index, tag_offset)
            pos += 16
            tag_prim = tag.prim if tag.pre else current_prim

            if tag.flg == GIF_FLG_PACKED:
                byte_count = 16 * tag.nloop * len(tag.registers)
                if pos + byte_count > len(payload):
                    break
                draw, current_prim = _read_packed_payload(
                    payload[pos : pos + byte_count],
                    tag,
                    tag_prim,
                    current_prim,
                    texture_state,
                )
                if draw is not None:
                    draws.append(draw)
                pos += byte_count
            elif tag.flg == GIF_FLG_REGLIST:
                value_count = tag.nloop * len(tag.registers)
                byte_count = ((value_count + 1) // 2) * 16
                if pos + byte_count > len(payload):
                    break
                draw, current_prim = _read_reglist_payload(
                    payload[pos : pos + byte_count],
                    tag,
                    tag_prim,
                    current_prim,
                    texture_state,
                )
                if draw is not None:
                    draws.append(draw)
                pos += byte_count
            elif tag.flg == GIF_FLG_IMAGE:
                pos += tag.nloop * 16
            else:
                break

    return tuple(draws)


def _read_gif_tag(payload: bytes, transfer_index: int, tag_offset: int) -> GifTag:
    low, high = struct.unpack_from("<QQ", payload, tag_offset)
    nreg = (low >> 60) & 0x0F
    if nreg == 0:
        nreg = 16
    return GifTag(
        transfer_index=transfer_index,
        tag_offset=tag_offset,
        nloop=low & 0x7FFF,
        eop=bool((low >> 15) & 1),
        pre=bool((low >> 46) & 1),
        prim=(low >> 47) & 0x7FF,
        flg=(low >> 58) & 0x03,
        registers=tuple((high >> (index * 4)) & 0x0F for index in range(nreg)),
    )


def _read_packed_payload(
    payload: bytes,
    tag: GifTag,
    tag_prim: int,
    current_prim: int,
    texture_state: dict[int, int],
) -> tuple[GsDrawPacket | None, int]:
    vertices: list[GsScreenVertex] = []
    st_values: list[tuple[float, float, float] | None] = []
    uv_values: list[tuple[int, int] | None] = []
    rgbaq_values: list[tuple[int, int, int, int, float] | None] = []
    pending_st: tuple[float, float, float] | None = None
    pending_uv: tuple[int, int] | None = None
    pending_rgbaq: tuple[int, int, int, int, float] | None = None

    pos = 0
    for _loop_index in range(tag.nloop):
        for register in tag.registers:
            qword = payload[pos : pos + 16]
            pos += 16
            if register == GIF_REG_PRIM:
                current_prim = struct.unpack_from("<Q", qword, 0)[0] & 0x7FF
                tag_prim = current_prim
            elif register == GIF_REG_ST:
                pending_st = _decode_st(qword)
            elif register == GIF_REG_UV:
                pending_uv = _decode_uv(qword)
            elif register == GIF_REG_RGBAQ:
                pending_rgbaq = _decode_rgbaq(qword)
            elif register in (GIF_REG_XYZ2, GIF_REG_XYZF2, GIF_REG_XYZ3, GIF_REG_XYZF3):
                vertices.append(_decode_xyz(qword, register))
                st_values.append(pending_st)
                uv_values.append(pending_uv)
                rgbaq_values.append(pending_rgbaq)
            elif register == GIF_REG_AD:
                data, address = struct.unpack_from("<QQ", qword, 0)
                address &= 0x7F
                if address == GS_REG_PRIM:
                    current_prim = data & 0x7FF
                    tag_prim = current_prim
                elif address in _TRACKED_TEXTURE_REGISTERS:
                    texture_state[address] = data

    if not vertices:
        return None, current_prim
    return _make_draw_packet(tag, tag_prim, texture_state, vertices, st_values, uv_values, rgbaq_values), current_prim


def _read_reglist_payload(
    payload: bytes,
    tag: GifTag,
    tag_prim: int,
    current_prim: int,
    texture_state: dict[int, int],
) -> tuple[GsDrawPacket | None, int]:
    values = _iter_reglist_values(payload, tag.nloop * len(tag.registers))
    vertices: list[GsScreenVertex] = []
    st_values: list[tuple[float, float, float] | None] = []
    uv_values: list[tuple[int, int] | None] = []
    rgbaq_values: list[tuple[int, int, int, int, float] | None] = []
    pending_uv: tuple[int, int] | None = None
    pending_rgbaq: tuple[int, int, int, int, float] | None = None

    for _loop_index in range(tag.nloop):
        for register in tag.registers:
            value = next(values)
            if register == GIF_REG_PRIM:
                current_prim = value & 0x7FF
                tag_prim = current_prim
            elif register == GIF_REG_UV:
                pending_uv = (value & 0x3FFF, (value >> 32) & 0x3FFF)
            elif register == GIF_REG_RGBAQ:
                pending_rgbaq = _decode_rgbaq64(value)
            elif register in (GIF_REG_XYZ2, GIF_REG_XYZF2, GIF_REG_XYZ3, GIF_REG_XYZF3):
                vertices.append(_decode_xyz64(value, register))
                st_values.append(None)
                uv_values.append(pending_uv)
                rgbaq_values.append(pending_rgbaq)

    if not vertices:
        return None, current_prim
    return _make_draw_packet(tag, tag_prim, texture_state, vertices, st_values, uv_values, rgbaq_values), current_prim


def _make_draw_packet(
    tag: GifTag,
    prim_raw: int,
    texture_state: dict[int, int],
    vertices: list[GsScreenVertex],
    st_values: list[tuple[float, float, float] | None],
    uv_values: list[tuple[int, int] | None],
    rgbaq_values: list[tuple[int, int, int, int, float] | None],
) -> GsDrawPacket:
    return GsDrawPacket(
        transfer_index=tag.transfer_index,
        tag_offset=tag.tag_offset,
        prim_type=prim_raw & 0x07,
        prim_raw=prim_raw,
        texture_state=tuple(sorted(texture_state.items())),
        vertices=tuple(vertices),
        st=tuple(st_values),
        uv=tuple(uv_values),
        rgbaq=tuple(rgbaq_values),
    )


def _iter_reglist_values(payload: bytes, value_count: int):
    for index in range(value_count):
        qword_offset = (index // 2) * 16
        value_offset = qword_offset + (8 if index & 1 else 0)
        yield struct.unpack_from("<Q", payload, value_offset)[0]


def _decode_st(qword: bytes) -> tuple[float, float, float]:
    return struct.unpack_from("<fff", qword, 0)


def _decode_uv(qword: bytes) -> tuple[int, int]:
    value = struct.unpack_from("<Q", qword, 0)[0]
    return value & 0x3FFF, (value >> 32) & 0x3FFF


def _decode_rgbaq(qword: bytes) -> tuple[int, int, int, int, float]:
    value = struct.unpack_from("<I", qword, 0)[0]
    return value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF, (value >> 24) & 0xFF, struct.unpack_from("<f", qword, 4)[0]


def _decode_rgbaq64(value: int) -> tuple[int, int, int, int, float]:
    return value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF, (value >> 24) & 0xFF, struct.unpack("<f", ((value >> 32) & 0xFFFFFFFF).to_bytes(4, "little"))[0]


def _decode_xyz(qword: bytes, register: int) -> GsScreenVertex:
    low, high = struct.unpack_from("<QQ", qword, 0)
    disable_drawing = register in (GIF_REG_XYZF3, GIF_REG_XYZ3) or bool((high >> 47) & 1)
    if register in (GIF_REG_XYZF2, GIF_REG_XYZF3):
        return GsScreenVertex(low & 0xFFFF, (low >> 32) & 0xFFFF, high & 0xFFFFFF, (high >> 24) & 0xFF, register, disable_drawing)
    return GsScreenVertex(low & 0xFFFF, (low >> 32) & 0xFFFF, high & 0xFFFFFFFF, None, register, disable_drawing)


def _decode_xyz64(value: int, register: int) -> GsScreenVertex:
    disable_drawing = register in (GIF_REG_XYZF3, GIF_REG_XYZ3)
    if register in (GIF_REG_XYZF2, GIF_REG_XYZF3):
        return GsScreenVertex(value & 0xFFFF, (value >> 16) & 0xFFFF, (value >> 32) & 0xFFFFFF, (value >> 56) & 0xFF, register, disable_drawing)
    return GsScreenVertex(value & 0xFFFF, (value >> 16) & 0xFFFF, (value >> 32) & 0xFFFFFFFF, None, register, disable_drawing)


_TRACKED_TEXTURE_REGISTERS = {
    GS_REG_TEX0_1,
    GS_REG_TEX0_2,
    GS_REG_CLAMP_1,
    GS_REG_CLAMP_2,
    GS_REG_TEX1_1,
    GS_REG_TEX1_2,
    GS_REG_TEX2_1,
    GS_REG_TEX2_2,
    GS_REG_ALPHA_1,
    GS_REG_ALPHA_2,
    GS_REG_TEST_1,
    GS_REG_TEST_2,
    GS_REG_TEXA,
}
