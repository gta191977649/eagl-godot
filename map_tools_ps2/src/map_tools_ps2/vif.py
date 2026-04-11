from __future__ import annotations

import struct
from dataclasses import dataclass

from .binary import Vec3, align, unpack_f32s

POSITION_S16_SCALE = 1.0 / 4096.0
POSITION_S8_SCALE = 1.0 / 128.0


@dataclass(frozen=True)
class VifVertexRun:
    vertices: tuple[Vec3, ...]
    texcoords: tuple[tuple[float, float], ...]
    packed_values: tuple[int, ...]
    header: tuple[int, int, int, int] | None


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


def _unpack_data_size(command: int, count: int) -> int | None:
    if command == 0x60:
        return count * 4
    if command == 0x61:
        return align(count * 2, 4)
    if command == 0x62:
        return align(count, 4)
    if command == 0x64:
        return count * 8
    if command == 0x65:
        return align(count * 4, 4)
    if command == 0x66:
        return align(count * 2, 4)
    if command == 0x68:
        return count * 12
    if command == 0x69:
        return align(count * 6, 4)
    if command == 0x6A:
        return align(count * 3, 4)
    if command == 0x6C:
        return count * 16
    if command == 0x6D:
        return count * 8
    if command == 0x6E:
        return align(count * 4, 4)
    if command == 0x6F:
        return align(count * 2, 4)
    return None


def _decode_position_values(
    command: int,
    count: int,
    payload: bytes,
    offset: int,
) -> tuple[tuple[float, ...], ...]:
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
    layout = _POSITION_COMMAND_LAYOUTS.get(command)
    if layout is None:
        return
    rows.extend(_decode_position_values(command, count, payload, offset))


def _append_texcoord_pairs(
    texcoords: list[tuple[float, float]], command: int, count: int, payload: bytes, offset: int
) -> None:
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


def _flush_rows(
    rows: list[tuple[float, ...]],
    texcoords: list[tuple[float, float]],
    packed_values: list[int],
    header: tuple[int, int, int, int] | None,
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

    return VifVertexRun(tuple(vertices), texcoord_pairs, packed_value_tuple, header)


def extract_vif_vertex_runs(payload: bytes) -> tuple[VifVertexRun, ...]:
    if len(payload) >= 8 and payload[:8] == b"\x11" * 8:
        payload = payload[8:]

    runs: list[VifVertexRun] = []
    rows: list[tuple[float, ...]] = []
    texcoords: list[tuple[float, float]] = []
    packed_values: list[int] = []
    current_header: tuple[int, int, int, int] | None = None
    pos = 0

    while pos + 4 <= len(payload):
        imm, count, command = struct.unpack_from("<HBB", payload, pos)
        pos += 4
        size = _unpack_data_size(command, count)
        if size is None:
            if command == 0x14:
                run = _flush_rows(rows, texcoords, packed_values, current_header)
                if run is not None:
                    runs.append(run)
                current_header = None
            elif command != 0x00:
                run = _flush_rows(rows, texcoords, packed_values, current_header)
                if run is not None:
                    runs.append(run)
                current_header = None
            continue
        if pos + size > len(payload):
            break

        if command == 0x6E and imm == 0x8000 and count == 1 and size >= 4:
            run = _flush_rows(rows, texcoords, packed_values, current_header)
            if run is not None:
                runs.append(run)
            current_header = tuple(payload[pos : pos + 4])  # type: ignore[assignment]
        elif imm >= 0xC002 and imm < 0xC020 and command in _POSITION_COMMAND_LAYOUTS:
            _append_position_rows(rows, command, count, payload, pos)
        elif imm >= 0xC020 and imm < 0xC034 and command in (0x60, 0x64, 0x68, 0x6C):
            _append_texcoord_pairs(texcoords, command, count, payload, pos)
        elif imm >= 0xC034 and imm < 0xC040 and command == 0x6F:
            packed_values.extend(struct.unpack_from("<" + "H" * count, payload, pos))

        pos += size

    run = _flush_rows(rows, texcoords, packed_values, current_header)
    if run is not None:
        runs.append(run)
    return tuple(runs)
