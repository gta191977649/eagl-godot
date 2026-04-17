from __future__ import annotations

import struct
from dataclasses import dataclass
from typing import Any

from .binary import Vec3, align, unpack_f32s

POSITION_S16_SCALE = 1.0 / 4096.0
POSITION_S8_SCALE = 1.0 / 128.0


@dataclass(frozen=True)
class VifVertexRun:
    vertices: tuple[Vec3, ...]
    texcoords: tuple[tuple[float, float], ...]
    packed_values: tuple[int, ...]
    header: tuple[int, int, int, int] | None
    tri_cull: tuple[int, int, int, int] | None = None


@dataclass(frozen=True)
class VifCommandEvent:
    offset: int
    imm: int
    count: int
    command: int
    payload_offset: int
    payload: bytes
    raw: bytes
    decoded: Any = None

    @property
    def unpack_destination(self) -> int | None:
        return self.imm & 0x03FF if _is_unpack_command(self.command) else None

    @property
    def unpack_qword_address(self) -> int | None:
        return self.imm & 0x003F if _is_unpack_command(self.command) else None

    @property
    def unpack_byte_address(self) -> int | None:
        address = self.unpack_qword_address
        return address * 0x10 if address is not None else None

    @property
    def unpack_add_tops(self) -> bool:
        return bool(self.imm & 0x8000) if _is_unpack_command(self.command) else False

    @property
    def unpack_unsigned(self) -> bool:
        return bool(self.imm & 0x4000) if _is_unpack_command(self.command) else False

    @property
    def unpack_masked(self) -> bool:
        return bool(self.command & 0x10) if _is_unpack_command(self.command) else False

    @property
    def unpack_format(self) -> str | None:
        return _unpack_format_name(self.command) if _is_unpack_command(self.command) else None


_POSITION_COMMAND_LAYOUTS: dict[int, tuple[int, str]] = {
    0x60: (1, "f32"),
    0x61: (1, "s16"),
    0x62: (1, "s8"),
    0x64: (2, "f32"),
    0x65: (2, "s16"),
    0x66: (2, "s8"),
    0x68: (3, "f32"),
    0x69: (3, "s16"),
    0x6A: (3, "s8"),
    0x6C: (4, "f32"),
    0x6D: (4, "s16"),
    0x6E: (4, "s8"),
}


def _base_unpack_command(command: int) -> int:
    return command & 0xEF


def _is_unpack_command(command: int) -> bool:
    return 0x60 <= command <= 0x7F


def _unpack_data_size(command: int, count: int) -> int | None:
    if not _is_unpack_command(command) or _unpack_format_name(command) is None:
        return None
    vn = (command >> 2) & 0x03
    vl = command & 0x03
    return align(((0x08 >> vl) * (vn + 1) * count) >> 1, 4)


def _vif_command_payload_size(command: int, count: int, imm: int) -> int | None:
    unpack_size = _unpack_data_size(command, count)
    if unpack_size is not None:
        return unpack_size
    if command in {0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x10, 0x11, 0x13, 0x14, 0x15, 0x17}:
        return 0
    if command == 0x20:
        return 4
    if command in {0x30, 0x31}:
        return 16
    if command == 0x4A:
        return (count if count > 0 else 0x100) * 8
    if command in {0x50, 0x51}:
        return (imm if imm > 0 else 0x10000) * 16
    return None


def _unpack_format_name(command: int) -> str | None:
    return {
        0x0: "S32",
        0x1: "S16",
        0x2: "S8",
        0x4: "V2_32",
        0x5: "V2_16",
        0x6: "V2_8",
        0x8: "V3_32",
        0x9: "V3_16",
        0xA: "V3_8",
        0xC: "V4_32",
        0xD: "V4_16",
        0xE: "V4_8",
        0xF: "V4_5",
    }.get(command & 0x0F)


def _decode_position_values(
    command: int,
    count: int,
    payload: bytes,
    offset: int,
) -> tuple[tuple[float, ...], ...]:
    command = _base_unpack_command(command)
    component_count, value_kind = _POSITION_COMMAND_LAYOUTS[command]
    total_value_count = count * component_count

    if value_kind == "f32":
        values = unpack_f32s(payload, offset, total_value_count)
    elif value_kind == "s16":
        raw_values = struct.unpack_from("<" + "h" * total_value_count, payload, offset)
        values = tuple(value * POSITION_S16_SCALE for value in raw_values)
    else:
        raw_values = struct.unpack_from("<" + "b" * total_value_count, payload, offset)
        values = tuple(value * POSITION_S8_SCALE for value in raw_values)

    return tuple(
        tuple(values[row_start : row_start + component_count])
        for row_start in range(0, len(values), component_count)
    )


def _append_position_rows(
    rows: list[tuple[float, ...]], command: int, count: int, payload: bytes, offset: int
) -> None:
    command = _base_unpack_command(command)
    layout = _POSITION_COMMAND_LAYOUTS.get(command)
    if layout is None:
        return
    rows.extend(_decode_position_values(command, count, payload, offset))


def _append_texcoord_pairs(
    texcoords: list[tuple[float, float]], command: int, count: int, payload: bytes, offset: int
) -> None:
    command = _base_unpack_command(command)
    if command == 0x6C:
        values = unpack_f32s(payload, offset, count * 4)
        for row_offset in range(0, len(values), 4):
            row = values[row_offset : row_offset + 4]
            texcoords.append((row[0], row[1]))
            texcoords.append((row[3], row[2]))
    elif command == 0x64:
        values = unpack_f32s(payload, offset, count * 2)
        for pair_offset in range(0, len(values), 2):
            texcoords.append((values[pair_offset], values[pair_offset + 1]))
    elif command == 0x68:
        values = unpack_f32s(payload, offset, count * 3)
        for row_offset in range(0, len(values), 3):
            texcoords.append((values[row_offset], values[row_offset + 1]))
    elif command == 0x60:
        values = unpack_f32s(payload, offset, count)
        for pair_offset in range(0, len(values) - 1, 2):
            texcoords.append((values[pair_offset], values[pair_offset + 1]))


def parse_vif_command_events(payload: bytes) -> tuple[VifCommandEvent, ...]:
    if len(payload) >= 8 and payload[:8] == b"\x11" * 8:
        payload = payload[8:]

    events: list[VifCommandEvent] = []
    pos = 0
    while pos + 4 <= len(payload):
        offset = pos
        imm, count, command = struct.unpack_from("<HBB", payload, pos)
        pos += 4
        size = _vif_command_payload_size(command, count, imm)
        if size is None:
            events.append(
                VifCommandEvent(
                    offset=offset,
                    imm=imm,
                    count=count,
                    command=command,
                    payload_offset=pos,
                    payload=b"",
                    raw=payload[offset:pos],
                    decoded=None,
                )
            )
            continue
        if pos + size > len(payload):
            break

        event_payload = payload[pos : pos + size]
        events.append(
            VifCommandEvent(
                offset=offset,
                imm=imm,
                count=count,
                command=command,
                payload_offset=pos,
                payload=event_payload,
                raw=payload[offset : pos + size],
                decoded=_decode_event_payload(command, count, payload, pos),
            )
        )
        pos += size
    return tuple(events)


def _decode_event_payload(command: int, count: int, payload: bytes, offset: int) -> Any:
    base_command = _base_unpack_command(command)
    if base_command in _POSITION_COMMAND_LAYOUTS:
        return _decode_position_values(command, count, payload, offset)
    if base_command == 0x6F:
        return struct.unpack_from("<" + "H" * count, payload, offset)
    if command == 0x20:
        return struct.unpack_from("<I", payload, offset)[0]
    if command in {0x30, 0x31}:
        return struct.unpack_from("<IIII", payload, offset)
    return None


def _flush_rows(
    rows: list[tuple[float, ...]],
    texcoords: list[tuple[float, float]],
    packed_values: list[int],
    header: tuple[int, int, int, int] | None,
    tri_cull: tuple[int, int, int, int] | None,
) -> VifVertexRun | None:
    if len(rows) < 3:
        rows.clear()
        texcoords.clear()
        packed_values.clear()
        return None

    vertices: list[Vec3] = []
    row_index = 0
    while row_index + 2 < len(rows):
        x_row, y_row, z_row = rows[row_index], rows[row_index + 1], rows[row_index + 2]
        width = min(len(x_row), len(y_row), len(z_row))
        for lane in range(width):
            vertices.append(Vec3(x_row[lane], y_row[lane], z_row[lane]))
        row_index += 3

    rows.clear()
    if not vertices:
        texcoords.clear()
        packed_values.clear()
        return None

    if header is not None and header[0]:
        vertices = vertices[: header[0]]

    texcoord_pairs = tuple(texcoords[: len(vertices)])
    packed_value_tuple = tuple(packed_values[: len(vertices)])
    texcoords.clear()
    packed_values.clear()

    return VifVertexRun(tuple(vertices), texcoord_pairs, packed_value_tuple, header, tri_cull)


def extract_vif_vertex_runs(payload: bytes) -> tuple[VifVertexRun, ...]:
    if len(payload) >= 8 and payload[:8] == b"\x11" * 8:
        payload = payload[8:]

    runs: list[VifVertexRun] = []
    rows: list[tuple[float, ...]] = []
    texcoords: list[tuple[float, float]] = []
    packed_values: list[int] = []
    current_header: tuple[int, int, int, int] | None = None
    current_tri_cull: tuple[int, int, int, int] | None = None
    pos = 0

    while pos + 4 <= len(payload):
        imm, count, command = struct.unpack_from("<HBB", payload, pos)
        pos += 4
        size = _vif_command_payload_size(command, count, imm)
        if size is None:
            if command == 0x14:
                run = _flush_rows(rows, texcoords, packed_values, current_header, current_tri_cull)
                if run is not None:
                    runs.append(run)
                current_header = None
                current_tri_cull = None
            elif command != 0x00:
                run = _flush_rows(rows, texcoords, packed_values, current_header, current_tri_cull)
                if run is not None:
                    runs.append(run)
                current_header = None
                current_tri_cull = None
            continue
        if pos + size > len(payload):
            break

        if not _is_unpack_command(command):
            if command == 0x14:
                run = _flush_rows(rows, texcoords, packed_values, current_header, current_tri_cull)
                if run is not None:
                    runs.append(run)
                current_header = None
                current_tri_cull = None
            pos += size
            continue

        base_command = _base_unpack_command(command)
        if base_command == 0x6E and imm == 0x8000 and count == 1 and size >= 4:
            run = _flush_rows(rows, texcoords, packed_values, current_header, current_tri_cull)
            if run is not None:
                runs.append(run)
            current_header = tuple(payload[pos : pos + 4])  # type: ignore[assignment]
            current_tri_cull = None
        elif base_command == 0x6C and imm == 0xC001 and count == 1 and size >= 16:
            current_tri_cull = struct.unpack_from("<IIII", payload, pos)
        elif imm >= 0xC002 and imm < 0xC020 and base_command in _POSITION_COMMAND_LAYOUTS:
            _append_position_rows(rows, command, count, payload, pos)
        elif imm >= 0xC020 and imm < 0xC034 and base_command in (0x60, 0x64, 0x68, 0x6C):
            _append_texcoord_pairs(texcoords, command, count, payload, pos)
        elif imm >= 0xC034 and imm < 0xC040 and base_command == 0x6F:
            packed_values.extend(struct.unpack_from("<" + "H" * count, payload, pos))

        pos += size

    run = _flush_rows(rows, texcoords, packed_values, current_header, current_tri_cull)
    if run is not None:
        runs.append(run)
    return tuple(runs)
