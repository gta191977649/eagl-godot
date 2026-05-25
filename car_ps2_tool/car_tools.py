from __future__ import annotations

import base64
import binascii
import json
import math
import struct
import zlib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


POSITION_S16_SCALE = 1.0 / 4096.0
POSITION_S8_SCALE = 1.0 / 128.0

CHUNK_GLOBAL_CAR_TABLE = 0x00034600
HP2_GLOBALB_ROW_STRIDE = 0x560
HP2_GLOBALB_WHEEL_VECTOR_OFFSETS = {
    "FL": 0x120,
    "FR": 0x140,
    "RR": 0x160,
    "RL": 0x180,
}

SLOT_IDS = ["FL", "FR", "RL", "RR"]
TIRE_DETAIL_SUFFIXES = ["A", "B", "C"]
CAR_WINDOW_MATERIAL_HASHES = {
    0x7B220DDF,
    0xE7E4EF49,
    0x1B0763A0,
    0x60F8B13C,
    0x4CDEBFCA,
    0x0AB88F5D,
}
TIRE_RIM_MATERIAL_HASH = 0x001D38B3
TIRE_CAP_MATERIAL_HASH = 0xC8C5A8A4


@dataclass
class CarConfig:
    car_name: str
    duplicate_index: int = 1
    drive_type: str = "RWD"
    globalb_vehicle_type_id: int = -1
    wheel_local_positions_ps2: list[tuple[float, float, float]] = field(default_factory=lambda: [
        (1.3, 0.72, 0.2),
        (1.3, -0.72, 0.2),
        (-1.36, 0.72, 0.2),
        (-1.36, -0.72, 0.2),
    ])
    wheel_radii: list[float] = field(default_factory=lambda: [0.32, 0.32, 0.33, 0.33])


@dataclass
class CarAsset:
    car_id: str
    source_path: str
    source_files: dict[str, str]
    objects: list[dict[str, Any]] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)


@dataclass
class TextureInfo:
    name: str
    texture_hash: int
    width: int
    height: int
    png_bytes: bytes
    alpha_mode: str
    alpha_cutoff: float


class ExportError(RuntimeError):
    pass


class PS2Binary:
    @staticmethod
    def load_bundle_bytes(path: Path) -> bytes:
        data = path.read_bytes()
        if data.startswith(b"COMP"):
            return PS2Binary.decompress_lzc(data)
        return data

    @staticmethod
    def decompress_lzc(data: bytes) -> bytes:
        if len(data) < 16 or not data.startswith(b"COMP"):
            return data
        decompressed_size = PS2Binary.u32(data, 8)
        return PS2Binary.ea_comp_decompress_payload(data[16:], decompressed_size)

    @staticmethod
    def ea_comp_decompress_payload(payload: bytes, decompressed_size: int) -> bytes:
        out = bytearray()
        src = 0
        flags = 1
        payload_size = len(payload)
        while src < payload_size and len(out) < decompressed_size:
            if flags == 1:
                if src + 2 > payload_size:
                    raise ExportError("Truncated ea_comp flag word")
                flags = (payload[src] | (payload[src + 1] << 8)) | 0x10000
                src += 2
            cycles = 1 if (payload_size - 32) < src else 16
            for _ in range(cycles):
                if src >= payload_size or len(out) >= decompressed_size:
                    break
                if flags & 1:
                    if src + 2 > payload_size:
                        raise ExportError("Truncated ea_comp back-reference")
                    control = payload[src]
                    distance = payload[src + 1] | ((control & 0xF0) << 4)
                    src += 2
                    if distance == 0 or distance > len(out):
                        raise ExportError(f"Invalid ea_comp back-reference distance {distance}")
                    copy_pos = len(out) - distance
                    for _copy in range((control & 0x0F) + 3):
                        out.append(out[copy_pos])
                        copy_pos += 1
                        if len(out) >= decompressed_size:
                            break
                else:
                    out.append(payload[src])
                    src += 1
                flags >>= 1
        if len(out) != decompressed_size:
            raise ExportError(f"Decompressed {len(out)} bytes, expected {decompressed_size}")
        return bytes(out)

    @staticmethod
    def align(value: int, boundary: int) -> int:
        return (value + boundary - 1) & ~(boundary - 1)

    @staticmethod
    def u8(data: bytes, offset: int) -> int:
        return data[offset] if 0 <= offset < len(data) else 0

    @staticmethod
    def s8(data: bytes, offset: int) -> int:
        value = PS2Binary.u8(data, offset)
        return value - 0x100 if value & 0x80 else value

    @staticmethod
    def u16(data: bytes, offset: int) -> int:
        if offset + 1 >= len(data):
            return 0
        return struct.unpack_from("<H", data, offset)[0]

    @staticmethod
    def s16(data: bytes, offset: int) -> int:
        if offset + 1 >= len(data):
            return 0
        return struct.unpack_from("<h", data, offset)[0]

    @staticmethod
    def u32(data: bytes, offset: int) -> int:
        if offset + 3 >= len(data):
            return 0
        return struct.unpack_from("<I", data, offset)[0]

    @staticmethod
    def f32(data: bytes, offset: int) -> float:
        if offset + 3 >= len(data):
            return 0.0
        return struct.unpack_from("<f", data, offset)[0]

    @staticmethod
    def ascii(data: bytes, start: int, end: int) -> str:
        if start < 0 or end <= start or start >= len(data):
            return ""
        return data[start:min(end, len(data))].decode("ascii", errors="ignore")


def v_add(a: tuple[float, float, float], b: tuple[float, float, float]) -> tuple[float, float, float]:
    return (a[0] + b[0], a[1] + b[1], a[2] + b[2])


def v_sub(a: tuple[float, float, float], b: tuple[float, float, float]) -> tuple[float, float, float]:
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def v_scale(a: tuple[float, float, float], value: float) -> tuple[float, float, float]:
    return (a[0] * value, a[1] * value, a[2] * value)


def v_dot(a: tuple[float, float, float], b: tuple[float, float, float]) -> float:
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def v_cross(a: tuple[float, float, float], b: tuple[float, float, float]) -> tuple[float, float, float]:
    return (
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    )


def v_length_sq(a: tuple[float, float, float]) -> float:
    return v_dot(a, a)


def v_length(a: tuple[float, float, float]) -> float:
    return math.sqrt(v_length_sq(a))


def v_normalize(a: tuple[float, float, float]) -> tuple[float, float, float]:
    length = v_length(a)
    if length <= 1e-9:
        return (0.0, 0.0, 0.0)
    return (a[0] / length, a[1] / length, a[2] / length)


def ps2_to_godot_vec3(value: tuple[float, float, float]) -> tuple[float, float, float]:
    return (value[0], value[2], -value[1])


def transform_point_rows(point: tuple[float, float, float], matrix_rows: list[list[float]]) -> tuple[float, float, float]:
    if len(matrix_rows) < 4:
        return point
    x, y, z = point
    r0, r1, r2, r3 = matrix_rows[0], matrix_rows[1], matrix_rows[2], matrix_rows[3]
    return (
        x * float(r0[0]) + y * float(r1[0]) + z * float(r2[0]) + float(r3[0]),
        x * float(r0[1]) + y * float(r1[1]) + z * float(r2[1]) + float(r3[1]),
        x * float(r0[2]) + y * float(r1[2]) + z * float(r2[2]) + float(r3[2]),
    )


def ps2_rows_to_godot_basis(matrix_rows: list[list[float]]) -> list[tuple[float, float, float]]:
    if len(matrix_rows) < 4:
        return [(1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0)]
    r0, r1, r2 = matrix_rows[0], matrix_rows[1], matrix_rows[2]
    return [
        (float(r0[0]), float(r0[2]), -float(r0[1])),
        (float(r2[0]), float(r2[2]), -float(r2[1])),
        (-float(r1[0]), -float(r1[2]), float(r1[1])),
    ]


def basis_apply(basis: list[tuple[float, float, float]], vec: tuple[float, float, float]) -> tuple[float, float, float]:
    return (
        basis[0][0] * vec[0] + basis[1][0] * vec[1] + basis[2][0] * vec[2],
        basis[0][1] * vec[0] + basis[1][1] * vec[1] + basis[2][1] * vec[2],
        basis[0][2] * vec[0] + basis[1][2] * vec[1] + basis[2][2] * vec[2],
    )


def basis_mul(a: list[tuple[float, float, float]], b: list[tuple[float, float, float]]) -> list[tuple[float, float, float]]:
    return [basis_apply(a, b[0]), basis_apply(a, b[1]), basis_apply(a, b[2])]


def basis_determinant(basis: list[tuple[float, float, float]]) -> float:
    return v_dot(basis[0], v_cross(basis[1], basis[2]))


def basis_orthonormalized(basis: list[tuple[float, float, float]]) -> list[tuple[float, float, float]]:
    x = v_normalize(basis[0])
    y = v_sub(basis[1], v_scale(x, v_dot(x, basis[1])))
    y = v_normalize(y)
    z = v_cross(x, y)
    z = v_normalize(z)
    y = v_cross(z, x)
    return [x, y, z]


def rotation_between_vectors(from_dir: tuple[float, float, float], to_dir: tuple[float, float, float]) -> list[tuple[float, float, float]]:
    from_n = v_normalize(from_dir)
    to_n = v_normalize(to_dir)
    dot = max(-1.0, min(1.0, v_dot(from_n, to_n)))
    if dot >= 0.9999:
        return [(1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0)]
    if dot <= -0.9999:
        axis = v_cross(from_n, (0.0, 1.0, 0.0))
        if v_length_sq(axis) <= 1e-6:
            axis = v_cross(from_n, (0.0, 0.0, 1.0))
        return axis_angle_basis(v_normalize(axis), math.pi)
    axis = v_normalize(v_cross(from_n, to_n))
    return axis_angle_basis(axis, math.acos(dot))


def axis_angle_basis(axis: tuple[float, float, float], angle: float) -> list[tuple[float, float, float]]:
    x, y, z = axis
    c = math.cos(angle)
    s = math.sin(angle)
    t = 1.0 - c
    return [
        (t * x * x + c, t * x * y + s * z, t * x * z - s * y),
        (t * x * y - s * z, t * y * y + c, t * y * z + s * x),
        (t * x * z + s * y, t * y * z - s * x, t * z * z + c),
    ]


def yaw_basis(angle: float) -> list[tuple[float, float, float]]:
    c = math.cos(angle)
    s = math.sin(angle)
    return [
        (c, 0.0, -s),
        (0.0, 1.0, 0.0),
        (s, 0.0, c),
    ]


def compute_bounds(points: list[tuple[float, float, float]]) -> dict[str, tuple[float, float, float]] | None:
    if not points:
        return None
    min_v = [math.inf, math.inf, math.inf]
    max_v = [-math.inf, -math.inf, -math.inf]
    for point in points:
        for index in range(3):
            min_v[index] = min(min_v[index], point[index])
            max_v[index] = max(max_v[index], point[index])
    return {"min": tuple(min_v), "max": tuple(max_v)}


def merge_bounds(a: dict[str, tuple[float, float, float]] | None, b: dict[str, tuple[float, float, float]] | None) -> dict[str, tuple[float, float, float]] | None:
    if a is None:
        return b
    if b is None:
        return a
    return {
        "min": (
            min(a["min"][0], b["min"][0]),
            min(a["min"][1], b["min"][1]),
            min(a["min"][2], b["min"][2]),
        ),
        "max": (
            max(a["max"][0], b["max"][0]),
            max(a["max"][1], b["max"][1]),
            max(a["max"][2], b["max"][2]),
        ),
    }


def parse_chunks(data: bytes, start: int = 0, end: int | None = None) -> list[dict[str, Any]]:
    if end is None:
        end = len(data)
    chunks: list[dict[str, Any]] = []
    pos = start
    while pos + 8 <= end:
        chunk_id = PS2Binary.u32(data, pos)
        size = PS2Binary.u32(data, pos + 4)
        data_offset = pos + 8
        chunk_end = data_offset + size
        if chunk_end > end:
            raise ExportError(f"Chunk 0x{chunk_id:08x} at 0x{pos:x} ends beyond parent region")
        children: list[dict[str, Any]] = []
        if chunk_id & 0x80000000:
            children = parse_chunks(data, data_offset, chunk_end)
        chunks.append({
            "id": chunk_id,
            "size": size,
            "offset": pos,
            "data_offset": data_offset,
            "end_offset": chunk_end,
            "children": children,
        })
        pos = chunk_end
    return chunks


def walk_chunks(chunks: list[dict[str, Any]]) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for chunk in chunks:
        out.append(chunk)
        out.extend(walk_chunks(chunk.get("children", [])))
    return out


def child_with_id(chunk: dict[str, Any], chunk_id: int) -> dict[str, Any] | None:
    for child in chunk.get("children", []):
        if int(child.get("id", 0)) == chunk_id:
            return child
    return None


def payload(bundle: bytes, chunk: dict[str, Any]) -> bytes:
    return bundle[chunk["data_offset"]:chunk["end_offset"]]


def find_ascii_name(raw: bytes) -> dict[str, Any] | None:
    limit = min(0x34, len(raw) - 4)
    for start in range(0x10, limit, 4):
        end = start
        while end < len(raw):
            byte = raw[end]
            if byte == 0 or byte < 0x20 or byte > 0x7E:
                break
            end += 1
        if end - start >= 4 and end < len(raw) and raw[end] == 0:
            return {"name": PS2Binary.ascii(raw, start, end), "start": start}
    return None


def read_transform(raw: bytes, name_start: int) -> list[list[float]]:
    matrix_offset = name_start + 0x50
    if matrix_offset + 64 > len(raw):
        return [
            [1.0, 0.0, 0.0, 0.0],
            [0.0, 1.0, 0.0, 0.0],
            [0.0, 0.0, 1.0, 0.0],
            [0.0, 0.0, 0.0, 1.0],
        ]
    rows: list[list[float]] = []
    for row in range(4):
        row_offset = matrix_offset + row * 16
        rows.append([
            PS2Binary.f32(raw, row_offset),
            PS2Binary.f32(raw, row_offset + 4),
            PS2Binary.f32(raw, row_offset + 8),
            PS2Binary.f32(raw, row_offset + 12),
        ])
    return rows


def read_texture_hashes(raw: bytes) -> list[int]:
    hashes: list[int] = []
    for offset in range(0, len(raw) - 3, 8):
        value = PS2Binary.u32(raw, offset)
        if value != 0:
            hashes.append(value)
    return hashes


def strip_vif_prefix(raw: bytes) -> bytes:
    if len(raw) >= 8 and raw[:8] == b"\x11" * 8:
        return raw[8:]
    return raw


def base_unpack_command(command: int) -> int:
    return command & 0xEF


def is_unpack_command(command: int) -> bool:
    return 0x60 <= command <= 0x7F


def unpack_format_name(command: int) -> str:
    lookup = {
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
    }
    return lookup.get(command & 0x0F, "")


def unpack_data_size(command: int, count: int) -> int:
    if not is_unpack_command(command) or not unpack_format_name(command):
        return -1
    vn = (command >> 2) & 0x03
    vl = command & 0x03
    return PS2Binary.align(((0x08 >> vl) * (vn + 1) * count) >> 1, 4)


def vif_command_payload_size(command: int, count: int, imm: int) -> int:
    unpack_size = unpack_data_size(command, count)
    if unpack_size >= 0:
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
    return -1


def position_layout(base_command: int) -> dict[str, Any]:
    layouts = {
        0x60: {"components": 1, "kind": "f32"},
        0x61: {"components": 1, "kind": "s16"},
        0x62: {"components": 1, "kind": "s8"},
        0x64: {"components": 2, "kind": "f32"},
        0x65: {"components": 2, "kind": "s16"},
        0x66: {"components": 2, "kind": "s8"},
        0x68: {"components": 3, "kind": "f32"},
        0x69: {"components": 3, "kind": "s16"},
        0x6A: {"components": 3, "kind": "s8"},
        0x6C: {"components": 4, "kind": "f32"},
        0x6D: {"components": 4, "kind": "s16"},
        0x6E: {"components": 4, "kind": "s8"},
    }
    return layouts.get(base_command, {})


def decode_position_values(command: int, count: int, raw: bytes, offset: int) -> list[list[float]]:
    layout = position_layout(base_unpack_command(command))
    if not layout:
        return []
    component_count = int(layout["components"])
    value_kind = str(layout["kind"])
    total_value_count = count * component_count
    values: list[float] = []
    if value_kind == "f32":
        for index in range(total_value_count):
            values.append(PS2Binary.f32(raw, offset + index * 4))
    elif value_kind == "s16":
        for index in range(total_value_count):
            values.append(float(PS2Binary.s16(raw, offset + index * 2)) * POSITION_S16_SCALE)
    else:
        for index in range(total_value_count):
            values.append(float(PS2Binary.s8(raw, offset + index)) * POSITION_S8_SCALE)
    out: list[list[float]] = []
    for row_start in range(0, len(values), component_count):
        out.append(values[row_start:row_start + component_count])
    return out


def append_texcoord_pairs(texcoords: list[tuple[float, float]], command: int, count: int, raw: bytes, offset: int) -> None:
    base_command = base_unpack_command(command)
    if base_command == 0x6C:
        for row_offset in range(count):
            base = offset + row_offset * 16
            row = [
                PS2Binary.f32(raw, base),
                PS2Binary.f32(raw, base + 4),
                PS2Binary.f32(raw, base + 8),
                PS2Binary.f32(raw, base + 12),
            ]
            texcoords.append((row[0], row[1]))
            texcoords.append((row[3], row[2]))
    elif base_command == 0x64:
        for pair_offset in range(count):
            base = offset + pair_offset * 8
            texcoords.append((PS2Binary.f32(raw, base), PS2Binary.f32(raw, base + 4)))
    elif base_command == 0x68:
        for row_offset in range(count):
            base = offset + row_offset * 12
            texcoords.append((PS2Binary.f32(raw, base), PS2Binary.f32(raw, base + 4)))
    elif base_command == 0x60:
        values = [PS2Binary.f32(raw, offset + i * 4) for i in range(count)]
        for pair_offset in range(0, len(values) - 1, 2):
            texcoords.append((values[pair_offset], values[pair_offset + 1]))


def flush_rows(
    runs: list[dict[str, Any]],
    rows: list[list[float]],
    texcoords: list[tuple[float, float]],
    packed_values: list[int],
    header: list[int],
    tri_cull: list[int],
) -> None:
    if len(rows) < 3:
        rows.clear()
        texcoords.clear()
        packed_values.clear()
        return
    vertices: list[tuple[float, float, float]] = []
    row_index = 0
    while row_index + 2 < len(rows):
        x_row = rows[row_index]
        y_row = rows[row_index + 1]
        z_row = rows[row_index + 2]
        width = min(len(x_row), len(y_row), len(z_row))
        for lane in range(width):
            vertices.append((float(x_row[lane]), float(y_row[lane]), float(z_row[lane])))
        row_index += 3
    rows.clear()
    if not vertices:
        texcoords.clear()
        packed_values.clear()
        return
    if header and int(header[0]) > 0 and int(header[0]) < len(vertices):
        vertices = vertices[:int(header[0])]
    runs.append({
        "vertices": vertices,
        "texcoords": texcoords[:len(vertices)],
        "packed_values": packed_values[:len(vertices)],
        "header": header[:],
        "tri_cull": tri_cull[:],
    })
    texcoords.clear()
    packed_values.clear()


def extract_vif_vertex_runs(raw: bytes) -> list[dict[str, Any]]:
    payload = strip_vif_prefix(raw)
    runs: list[dict[str, Any]] = []
    rows: list[list[float]] = []
    texcoords: list[tuple[float, float]] = []
    packed_values: list[int] = []
    current_header: list[int] = []
    current_tri_cull: list[int] = []
    pos = 0
    while pos + 4 <= len(payload):
        imm = PS2Binary.u16(payload, pos)
        count = PS2Binary.u8(payload, pos + 2)
        command = PS2Binary.u8(payload, pos + 3)
        pos += 4
        size = vif_command_payload_size(command, count, imm)
        if size < 0:
            if command == 0x14 or command != 0x00:
                flush_rows(runs, rows, texcoords, packed_values, current_header, current_tri_cull)
                current_header = []
                current_tri_cull = []
            continue
        if pos + size > len(payload):
            break
        if not is_unpack_command(command):
            if command == 0x14:
                flush_rows(runs, rows, texcoords, packed_values, current_header, current_tri_cull)
                current_header = []
                current_tri_cull = []
            pos += size
            continue
        base_command = base_unpack_command(command)
        if base_command == 0x6E and imm == 0x8000 and count == 1 and size >= 4:
            flush_rows(runs, rows, texcoords, packed_values, current_header, current_tri_cull)
            current_header = [payload[pos], payload[pos + 1], payload[pos + 2], payload[pos + 3]]
            current_tri_cull = []
        elif base_command == 0x6C and imm == 0xC001 and count == 1 and size >= 16:
            current_tri_cull = [
                PS2Binary.u32(payload, pos),
                PS2Binary.u32(payload, pos + 4),
                PS2Binary.u32(payload, pos + 8),
                PS2Binary.u32(payload, pos + 12),
            ]
        elif 0xC002 <= imm < 0xC020 and position_layout(base_command):
            rows.extend(decode_position_values(command, count, payload, pos))
        elif 0xC020 <= imm < 0xC034 and base_command in {0x60, 0x64, 0x68, 0x6C}:
            append_texcoord_pairs(texcoords, command, count, payload, pos)
        elif 0xC034 <= imm < 0xC040 and base_command == 0x6F:
            for index in range(count):
                packed_values.append(PS2Binary.u16(payload, pos + index * 2))
        pos += size
    flush_rows(runs, rows, texcoords, packed_values, current_header, current_tri_cull)
    return runs


def parse_strip_entry_record(record: bytes) -> dict[str, Any]:
    texture_index_raw = PS2Binary.u32(record, 0)
    qword_word = PS2Binary.u32(record, 0x0C)
    word_1c = PS2Binary.u32(record, 0x1C)
    qword_count = qword_word & 0xFFFF
    return {
        "texture_index_raw": texture_index_raw,
        "vif_offset": PS2Binary.u32(record, 0x08),
        "qword_count": qword_count,
        "qword_size": qword_count * 16,
        "render_flags": (qword_word >> 16) & 0xFFFF,
        "word_1c": word_1c,
        "topology_code": word_1c & 0xFF,
        "vertex_count_byte": (word_1c >> 8) & 0xFF,
        "count_byte": (word_1c >> 16) & 0xFF,
    }


def extract_blocks_from_strip_entries(vif_payload: bytes, metadata_payload: bytes) -> list[dict[str, Any]]:
    clean_metadata = strip_vif_prefix(metadata_payload)
    record_count = len(clean_metadata) // 0x40
    if record_count <= 0:
        return []
    blocks: list[dict[str, Any]] = []
    for record_index in range(record_count):
        record = clean_metadata[record_index * 0x40:(record_index + 1) * 0x40]
        strip_entry = parse_strip_entry_record(record)
        vif_offset = int(strip_entry["vif_offset"])
        qword_size = int(strip_entry["qword_size"])
        if qword_size <= 0 or vif_offset < 0 or vif_offset + qword_size > len(vif_payload):
            return []
        decoded = extract_vif_vertex_runs(vif_payload[vif_offset:vif_offset + qword_size])
        if len(decoded) != 1:
            return []
        texture_index_raw = int(strip_entry["texture_index_raw"])
        blocks.append({
            "run": decoded[0],
            "primitive_mode": "strip",
            "expected_face_count": int(strip_entry["count_byte"]),
            "topology_code": int(strip_entry["topology_code"]),
            "texture_index": texture_index_raw if texture_index_raw != 0xFFFFFFFF else -1,
            "render_flag": int(strip_entry["render_flags"]),
            "source_offset": vif_offset,
            "source_qword_size": qword_size,
            "strip_entry": strip_entry,
        })
    return blocks


def parse_mesh_object(object_chunk: dict[str, Any], bundle: bytes) -> dict[str, Any]:
    header_chunk = child_with_id(object_chunk, 0x00034003)
    run_metadata_chunk = child_with_id(object_chunk, 0x00034004)
    vif_data_chunk = child_with_id(object_chunk, 0x00034005)
    texture_refs_chunk = child_with_id(object_chunk, 0x00034006)
    if header_chunk is None or vif_data_chunk is None:
        return {}
    header_payload = payload(bundle, header_chunk)
    name_info = find_ascii_name(header_payload)
    if not name_info:
        return {}
    vif_payload = strip_vif_prefix(payload(bundle, vif_data_chunk))
    metadata_payload = payload(bundle, run_metadata_chunk) if run_metadata_chunk else b""
    blocks = extract_blocks_from_strip_entries(vif_payload, metadata_payload)
    if not blocks:
        for run in extract_vif_vertex_runs(vif_payload):
            blocks.append({
                "run": run,
                "primitive_mode": "strip",
                "expected_face_count": 0,
                "topology_code": 0,
                "texture_index": -1,
                "render_flag": 0,
                "source_offset": -1,
                "source_qword_size": -1,
                "strip_entry": {},
            })
    if not blocks:
        return {}
    texture_hashes = read_texture_hashes(payload(bundle, texture_refs_chunk)) if texture_refs_chunk else []
    return {
        "name": str(name_info["name"]),
        "chunk_offset": int(object_chunk["offset"]),
        "transform": read_transform(header_payload, int(name_info["start"])),
        "blocks": blocks,
        "texture_hashes": texture_hashes,
        "name_hash": PS2Binary.u32(header_payload, 0x08) if len(header_payload) >= 0x0C else 0,
    }


def parse_car_asset(files: dict[str, str]) -> CarAsset:
    model_path = Path(files["model"])
    bundle = PS2Binary.load_bundle_bytes(model_path)
    chunks = parse_chunks(bundle)
    asset = CarAsset(car_id=files["car_id"], source_path=str(model_path), source_files=dict(files))
    binary_name = read_binary_car_name_from_chunks(chunks, bundle, asset.car_id)
    if binary_name:
        asset.car_id = binary_name
    for chunk in walk_chunks(chunks):
        if int(chunk.get("id", 0)) != 0x80034000:
            continue
        for child in chunk.get("children", []):
            if int(child.get("id", 0)) != 0x80034002:
                continue
            obj = parse_mesh_object(child, bundle)
            if obj:
                asset.objects.append(obj)
    return asset


def read_binary_car_name_from_chunks(chunks: list[dict[str, Any]], bundle: bytes, fallback: str) -> str:
    for chunk in walk_chunks(chunks):
        if int(chunk.get("id", 0)) != 0x80034002:
            continue
        header_chunk = child_with_id(chunk, 0x00034003)
        if header_chunk is None:
            continue
        name_info = find_ascii_name(payload(bundle, header_chunk))
        if not name_info:
            continue
        normalized = normalized_binary_car_name_from_object(str(name_info["name"]))
        if normalized:
            return normalized
    return normalized_binary_car_name(fallback)


def normalized_binary_car_name_from_object(value: str) -> str:
    normalized = value.strip().replace("\\", "/").upper()
    if "/CARS/" in normalized:
        return normalized_binary_car_name(normalized)
    for suffix in ["_CV", "_A", "_B", "_C", "_D", "_SCUFFS"]:
        if normalized.endswith(suffix):
            return normalized_binary_car_name(normalized)
    return ""


def normalized_binary_car_name(value: str) -> str:
    normalized = value.strip().replace("\\", "/").upper()
    if not normalized:
        return ""
    cars_marker = "/CARS/"
    cars_index = normalized.find(cars_marker)
    if cars_index >= 0:
        after_cars = normalized[cars_index + len(cars_marker):]
        slash_index = after_cars.find("/")
        normalized = after_cars[:slash_index] if slash_index > 0 else after_cars
    else:
        normalized = Path(normalized).name
        if normalized.startswith("GEOMETRY."):
            normalized = ""
    if normalized.endswith(".BIN") or normalized.endswith(".LZC"):
        normalized = normalized.rsplit(".", 1)[0]
    for suffix in [
        "_TIRE_FRONT_A",
        "_TIRE_FRONT_B",
        "_TIRE_FRONT_C",
        "_TIRE_REAR_A",
        "_TIRE_REAR_B",
        "_TIRE_REAR_C",
        "_BRAKE_FRONT",
        "_BRAKE_REAR",
        "_SCUFFS",
        "_CV",
        "_A",
        "_B",
        "_C",
        "_D",
    ]:
        if normalized.endswith(suffix) and len(normalized) > len(suffix):
            normalized = normalized[:-len(suffix)]
            break
    return normalized if is_plausible_binary_car_name(normalized) else ""


def is_plausible_binary_car_name(value: str) -> bool:
    if len(value) < 2:
        return False
    for char in value:
        if not (char.isdigit() or ("A" <= char <= "Z") or char == "_"):
            return False
    return True


def resolve_cars_dir(root: Path) -> Path | None:
    normalized = root
    candidates = [
        normalized / "ZZDATA" / "CARS",
        normalized / "CARS",
        normalized,
    ]
    for candidate in candidates:
        if not candidate.is_dir():
            continue
        if candidate.name.upper() == "CARS":
            return candidate
        nested = candidate / "CARS"
        if nested.is_dir():
            return nested
    return None


def resolve_car_model_path(root: Path, car_id: str) -> Path:
    value = car_id.strip()
    direct = Path(value)
    if value.upper().endswith((".BIN", ".LZC")) and direct.is_file():
        return direct
    normalized = normalized_car_id(value)
    cars_dir = resolve_cars_dir(root)
    if cars_dir is None:
        raise ExportError(f"Could not locate CARS under game root: {root}")
    for extension in ("BIN", "LZC"):
        candidate = cars_dir / normalized / f"GEOMETRY.{extension}"
        if candidate.is_file():
            return candidate
    raise ExportError(f"Could not find {normalized}/GEOMETRY.BIN or GEOMETRY.LZC under {cars_dir}")


def resolve_car_texture_path(root: Path, model_path: Path) -> Path:
    candidates: list[Path] = []
    cars_dir = resolve_cars_dir(root)
    if cars_dir is not None:
        candidates.append(cars_dir / "TEXTURES.BIN")
    model_dir = model_path.parent
    candidates.append(model_dir / "TEXTURES.BIN")
    parent_dir = model_dir.parent
    candidates.append(parent_dir / "TEXTURES.BIN")
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    return candidates[0]


def resolve_global_texture_path(root: Path, model_path: Path) -> Path:
    candidates = [
        root / "ZZDATA" / "GLOBAL" / "GLOBALB.BUN",
        root / "GLOBAL" / "GLOBALB.BUN",
        root / "GLOBALB.BUN",
    ]
    cars_dir = resolve_cars_dir(root)
    if cars_dir is not None:
        candidates.append(cars_dir.parent / "GLOBAL" / "GLOBALB.BUN")
    model_dir = model_path.parent
    parent_dir = model_dir.parent
    candidates.append(parent_dir / "GLOBAL" / "GLOBALB.BUN")
    candidates.append(parent_dir.parent / "ZZDATA" / "GLOBAL" / "GLOBALB.BUN")
    for candidate in unique_paths(candidates):
        if candidate.is_file():
            return candidate
    return candidates[0]


def normalized_car_id(car_id: str) -> str:
    return Path(car_id.strip().rstrip("/\\")).name.upper()


def unique_paths(values: list[Path]) -> list[Path]:
    seen: set[str] = set()
    out: list[Path] = []
    for value in values:
        key = str(value).upper()
        if not key or key in seen:
            continue
        seen.add(key)
        out.append(value)
    return out


def parse_globalb_config(globalb_path: Path, car_name: str, duplicate_index: int, drive_type: str) -> CarConfig | None:
    if not globalb_path.is_file():
        return None
    bundle = PS2Binary.load_bundle_bytes(globalb_path)
    chunks = parse_chunks(bundle)
    chunk = first_chunk(chunks, CHUNK_GLOBAL_CAR_TABLE)
    if chunk is None:
        return None
    table_base = (int(chunk["offset"]) + 0x17) & ~0xF
    table_end = int(chunk["end_offset"])
    car_row = -1
    match_count = 0
    for row_index in range(globalb_row_count(table_base, table_end)):
        row_offset = table_base + row_index * HP2_GLOBALB_ROW_STRIDE
        if globalb_car_name(bundle, row_offset) != car_name.upper():
            continue
        match_count += 1
        if match_count == duplicate_index:
            car_row = row_index
            break
    if car_row < 0:
        return None
    row_base = table_base + car_row * HP2_GLOBALB_ROW_STRIDE
    wheel_positions: list[tuple[float, float, float]] = []
    wheel_radii: list[float] = []
    for slot_id in SLOT_IDS:
        vector_offset = HP2_GLOBALB_WHEEL_VECTOR_OFFSETS[slot_id]
        wheel_positions.append((
            PS2Binary.f32(bundle, row_base + vector_offset),
            PS2Binary.f32(bundle, row_base + vector_offset + 4),
            PS2Binary.f32(bundle, row_base + vector_offset + 8),
        ))
        wheel_radii.append(PS2Binary.f32(bundle, row_base + vector_offset + 12))
    return CarConfig(
        car_name=car_name.upper(),
        duplicate_index=duplicate_index,
        drive_type=drive_type.upper(),
        globalb_vehicle_type_id=PS2Binary.u32(bundle, row_base + 0x538),
        wheel_local_positions_ps2=wheel_positions,
        wheel_radii=wheel_radii,
    )


def first_chunk(chunks: list[dict[str, Any]], chunk_id: int) -> dict[str, Any] | None:
    for chunk in walk_chunks(chunks):
        if int(chunk.get("id", 0)) == chunk_id:
            return chunk
    return None


def globalb_row_count(table_base: int, table_end: int) -> int:
    if table_end <= table_base:
        return 0
    return min((table_end - table_base) // HP2_GLOBALB_ROW_STRIDE, 64)


def globalb_car_name(bundle: bytes, row_offset: int) -> str:
    start = row_offset + 0x20
    end = start
    max_end = min(start + 0x10, len(bundle))
    while end < max_end and bundle[end] != 0:
        end += 1
    return PS2Binary.ascii(bundle, start, end).strip().upper()


class TextureBank:
    def __init__(self) -> None:
        self.textures: dict[int, TextureInfo] = {}
        self.texture_name_hashes: dict[str, int] = {}
        self.errors: list[str] = []

    def has_texture(self, texture_hash: int) -> bool:
        return texture_hash in self.textures

    def get_info(self, texture_hash: int) -> TextureInfo | None:
        return self.textures.get(texture_hash)

    def get_hash_for_name(self, texture_name: str) -> int:
        return int(self.texture_name_hashes.get(texture_name.strip().upper(), 0))

    def load_for_car(self, files: dict[str, str], required_hashes: list[int], required_names: list[str]) -> None:
        wanted_hashes = {value for value in required_hashes if value != 0}
        wanted_names = {value.strip().upper() for value in required_names if value.strip()}
        for key in ("texture_car", "texture", "textures"):
            path = Path(files.get(key, ""))
            if path.is_file():
                self._read_ps2_tpk(path, wanted_hashes, wanted_names)
        global_path = Path(files.get("texture_global", ""))
        if global_path.is_file():
            missing_hashes = {texture_hash for texture_hash in wanted_hashes if texture_hash not in self.textures}
            if missing_hashes:
                self._read_ps2_tpk(global_path, missing_hashes, set())

    def _read_ps2_tpk(self, path: Path, wanted_hashes: set[int], wanted_names: set[str]) -> None:
        data = path.read_bytes()
        chunks = parse_chunks(data)
        flat = walk_chunks(chunks)
        entry_chunk = first_chunk_by_id(flat, 0x30300003)
        data_chunk = first_chunk_by_id(flat, 0x30300004)
        if entry_chunk is None or data_chunk is None:
            self.errors.append(f"missing texture entry/data chunks in {path}")
            return
        entries = payload(data, entry_chunk)
        if len(entries) % 0xA4 != 0:
            self.errors.append(f"unexpected texture entry table size {len(entries)} in {path}")
            return
        data_base = PS2Binary.align(int(data_chunk["data_offset"]), 0x80)
        count = len(entries) // 0xA4
        for index in range(count):
            entry = entries[index * 0xA4:(index + 1) * 0xA4]
            self._decode_entry(path, data, data_base, entry, wanted_hashes, wanted_names)

    def _decode_entry(self, path: Path, data: bytes, data_base: int, entry: bytes, wanted_hashes: set[int], wanted_names: set[str]) -> None:
        name = entry_name(entry)
        texture_hash = PS2Binary.u32(entry, 0x20)
        has_filter = bool(wanted_hashes or wanted_names)
        if has_filter and texture_hash not in wanted_hashes and name.upper() not in wanted_names:
            return
        width = PS2Binary.u16(entry, 0x24)
        height = PS2Binary.u16(entry, 0x26)
        bit_depth = PS2Binary.u8(entry, 0x28)
        data_offset = PS2Binary.u32(entry, 0x30)
        palette_offset = PS2Binary.u32(entry, 0x34)
        data_size = PS2Binary.u32(entry, 0x38)
        palette_size = PS2Binary.u32(entry, 0x3C)
        shift_width = PS2Binary.u8(entry, 0x48)
        shift_height = PS2Binary.u8(entry, 0x49)
        pixel_storage_mode = PS2Binary.u8(entry, 0x4A)
        semitransparency = PS2Binary.u8(entry, 0x4F)
        is_swizzled = PS2Binary.u8(entry, 0x55) != 0
        if not name or texture_hash == 0 or width <= 0 or height <= 0 or data_size <= 0:
            return
        image_start = data_base + data_offset
        palette_start = data_base + palette_offset
        if image_start + data_size > len(data) or (palette_size > 0 and palette_start + palette_size > len(data)):
            self.errors.append(f"texture {name} points outside {path}")
            return
        indexed = data[image_start:image_start + data_size]
        rgba = b""
        if bit_depth == 32 and palette_size == 0:
            rgba = decode_rgba_texture(width, height, indexed)
        else:
            if palette_size <= 0:
                return
            palette = data[palette_start:palette_start + palette_size]
            rgba = decode_indexed_texture(
                width,
                height,
                indexed,
                palette,
                bit_depth,
                shift_width,
                shift_height,
                pixel_storage_mode,
                is_swizzled,
            )
        if not rgba:
            self.errors.append(f"could not decode texture {name} in {path}")
            return
        alpha_props = material_alpha_properties_for_rgba(rgba, semitransparency)
        png_bytes = rgba_to_png(width, height, rgba)
        info = TextureInfo(
            name=name,
            texture_hash=texture_hash,
            width=width,
            height=height,
            png_bytes=png_bytes,
            alpha_mode=str(alpha_props["mode"]),
            alpha_cutoff=float(alpha_props["cutoff"]),
        )
        self.textures[texture_hash] = info
        self.texture_name_hashes[name.upper()] = texture_hash


def first_chunk_by_id(chunks: list[dict[str, Any]], chunk_id: int) -> dict[str, Any] | None:
    for chunk in chunks:
        if int(chunk.get("id", 0)) == chunk_id:
            return chunk
    return None


def entry_name(entry: bytes) -> str:
    end = 0x08
    while end < 0x20 and end < len(entry) and entry[end] != 0:
        end += 1
    return PS2Binary.ascii(entry, 0x08, end).strip()


def decode_rgba_texture(width: int, height: int, image: bytes) -> bytes:
    if len(image) < width * height * 4:
        return b""
    out = bytearray()
    for y in range(height - 1, -1, -1):
        row = y * width * 4
        for x in range(width):
            offset = row + x * 4
            out.extend((image[offset], image[offset + 1], image[offset + 2], decode_ps2_alpha(image[offset + 3])))
    return bytes(out)


def indexed_bit_depth(bit_depth: int, pixel_storage_mode: int, palette_size: int) -> int:
    psm_index = psm_type_index(pixel_storage_mode)
    if psm_index > 0:
        return 32 >> max(psm_index - 1, 0)
    if bit_depth in {4, 8}:
        return bit_depth
    if palette_size == 0x40:
        return 4
    if palette_size in {0x80, 0x400}:
        return 8
    return 0


def psm_type_index(pixel_storage_mode: int) -> int:
    return pixel_storage_mode & 0x07


def u32_words(data: bytes) -> list[int]:
    words: list[int] = []
    for offset in range(0, len(data), 4):
        value = 0
        for byte_index in range(4):
            if offset + byte_index < len(data):
                value |= data[offset + byte_index] << (byte_index * 8)
        words.append(value)
    return words


def decode_indexed_texture(
    width: int,
    height: int,
    image: bytes,
    palette: bytes,
    bit_depth: int,
    shift_width: int,
    shift_height: int,
    pixel_storage_mode: int,
    is_swizzled: bool,
) -> bytes:
    depth = indexed_bit_depth(bit_depth, pixel_storage_mode, len(palette))
    if depth not in {4, 8}:
        return b""
    color_count = len(palette) // 4
    if color_count <= 0:
        return b""
    colors = decode_palette(palette, psm_type_index(pixel_storage_mode) == 3)
    buffer_width = 1 << shift_width
    buffer_height = 1 << shift_height
    if width <= 0 or height <= 0 or buffer_width <= 0 or buffer_height <= 0:
        return b""
    words = u32_words(image)
    if is_swizzled:
        scale = int(32 / depth)
        scale_mask = scale - 1
        scale_x = (adjust_with_mask(scale_mask, 1, 2, 1) | adjust_with_mask(scale_mask, 1, 0, 0)) + 1
        scale_y = (adjust_with_mask(scale_mask, 1, 3, 1) | adjust_with_mask(scale_mask, 1, 1, 0)) + 1
        words = legacy_ps2_rw_buffer(words, "write", 0, 32, int(width / scale_y), int(height / scale_x))
        words = legacy_ps2_rw_buffer(words, "read", pixel_storage_mode, depth, width, height)
    indices: list[int] = []
    index_mask = (1 << depth) - 1
    for word in words:
        for shift in range(0, 32, depth):
            indices.append((word >> shift) & index_mask)
    if is_swizzled:
        cropped: list[int] = []
        for y in range(height):
            row = y * buffer_width
            for x in range(width):
                source = row + x
                cropped.append(indices[source] if source < len(indices) else 0)
        indices = cropped
    final_indices: list[int] = []
    for y in range(height - 1, -1, -1):
        row = y * width
        for x in range(width):
            source = row + x
            final_indices.append(indices[source] if source < len(indices) else 0)
    rgba = bytearray()
    for index in final_indices[:width * height]:
        rgba.extend(colors[int(index) % color_count])
    return bytes(rgba)


def legacy_ps2_rw_buffer(image_data: list[int], mode: str, pixel_storage_mode: int, bit_depth: int, width: int, height: int) -> list[int]:
    scale = int(32 / bit_depth)
    scale_mask = scale - 1
    scale_x = (adjust_with_mask(scale_mask, 1, 2, 1) | adjust_with_mask(scale_mask, 1, 0, 0)) + 1
    scale_y = (adjust_with_mask(scale_mask, 1, 3, 1) | adjust_with_mask(scale_mask, 1, 1, 0)) + 1
    physical_width = int(width / scale_y)
    physical_height = int(height / scale_x)
    physical_buffer_width = align_power_of_two_max(physical_width)
    physical_buffer_height = align_power_of_two_max(physical_height)
    buffer_width = align_power_of_two_max(width)
    buffer_height = align_power_of_two_max(height)
    data = [0] * (physical_buffer_width * physical_buffer_height)
    type_index = adjust_with_mask(pixel_storage_mode, 3, 0)
    type_mode = adjust_with_mask(pixel_storage_mode, 2, 4)
    type_flag = adjust_with_mask(pixel_storage_mode, 1, 3) != 0
    swap_xy = (((type_mode == 0) or (type_mode == 3)) and type_index == 2) or (type_mode == 1 and type_index == 4)
    z_buffer = type_mode == 3
    shifted = ((type_mode == 0) or (type_mode == 3)) and type_index == 2 and type_flag
    column_width = 8 * scale_x
    column_height = 2 * scale_y
    page_height = 1 << (1 if swap_xy else 0)
    page_width = (page_height ^ 0x03) << 2
    page_height <<= 2
    texture_buffer_width = int(width / (page_width * column_width))
    if texture_buffer_width <= 0:
        texture_buffer_width = 1
    input_address = 0
    from_offset_w = 0
    for index in range(buffer_width * buffer_height):
        y = index // buffer_width
        x = index - y * buffer_width
        page_x = int(x / (page_width * column_width))
        page_y = int(y / (page_height * 4 * column_height))
        page = page_x + page_y * texture_buffer_width
        px = x - page_x * (page_width * column_width)
        py = y - page_y * (page_height * 4 * column_height)
        block_x = int(px / column_width)
        block_y = int(py / (4 * column_height))
        block = legacy_ps2_block_address(block_x + block_y * page_width, swap_xy, z_buffer, shifted)
        bx = px - block_x * column_width
        by = py - block_y * (4 * column_height)
        column_y = int(by / column_height)
        column = column_y
        cx = bx
        cy = by - column_y * column_height
        pixel = legacy_ps2_swizzle(cx + cy * column_width, bit_depth, True)
        word = int(pixel / scale)
        offset = pixel & scale_mask
        if bit_depth < 16:
            word ^= (column & 0x01) << 2
        word = (rotate_bits(word >> 1, -1, 3) << 1) | (word & 0x01)
        output_address = (page << 11) | (block << 6) | (column << 4) | word
        if mode == "read":
            address_a = input_address
            address_b = output_address
            source_shift = bit_depth * offset
            target_shift = bit_depth * from_offset_w
        else:
            address_a = output_address
            address_b = input_address
            source_shift = bit_depth * from_offset_w
            target_shift = bit_depth * offset
        input_value = image_data[address_b] if 0 <= address_b < len(image_data) else 0
        pixel_data = adjust_with_mask(input_value, bit_depth, source_shift, target_shift)
        if 0 <= address_a < len(data):
            data[address_a] |= pixel_data
        from_offset_w += 1
        if from_offset_w > 0 and (from_offset_w & scale_mask) == 0:
            input_address += 1
        from_offset_w &= scale_mask
    return data


def adjust_with_mask(src: int, mask_width: int, mask_position: int = 0, adjustment: int = 0) -> int:
    return ((src >> mask_position) & ((1 << mask_width) - 1)) << adjustment


def rotate_bits(value: int, shift: int, width: int) -> int:
    shift %= width
    mask = (1 << width) - 1
    value &= mask
    return ((value << shift) | (value >> (width - shift))) & mask


def align_power_of_two_max(value: int) -> int:
    target = 1
    while target < max(value, 1):
        target <<= 1
    return target


def legacy_ps2_block_address(block: int, swap_xy: bool, z_buffer: bool, shifted: bool) -> int:
    bx = adjust_with_mask(block, 2, 0)
    by = adjust_with_mask(block, 2, 2)
    cx = adjust_with_mask(block, 2, 4)
    cy = adjust_with_mask(block, 1, 6)
    ax = adjust_with_mask(block, 1, 7)
    ay = adjust_with_mask(block, 1, 8)
    flip_xy = bool(swap_xy and (cy == 1))
    if flip_xy:
        bx, by = by, bx
    if shifted:
        bx ^= 0x01
    result = 0
    result ^= bx << 0
    result ^= by << 1
    result ^= cx << 2
    result = rotate_bits(result, int(shifted), 3)
    result ^= (0x03 * int(flip_xy)) << 1
    result = (result << 2) ^ (ax << 0) ^ (ay << 1)
    if z_buffer:
        result ^= 0x18
    return result & 0x1F


def legacy_ps2_swizzle(index: int, bit_depth: int, use_z_order: bool) -> int:
    x = index & 0x07
    y = (index >> 3) & 0x01
    z = (index >> 4) & 0x01
    w = (index >> 5) & 0x01
    if use_z_order:
        value = (x & 0x01) | ((x & 0x02) << 1) | ((x & 0x04) << 2) | (y << 1) | (z << 3) | (w << 4)
    else:
        value = index
    if bit_depth == 4:
        return value
    if bit_depth == 8:
        return value >> 1
    return value >> 2


def decode_palette(palette: bytes, swizzle: bool) -> list[bytes]:
    colors: list[bytes] = []
    for index in range(len(palette) // 4):
        source_index = unswizzle_palette_index(index) if swizzle else index
        off = source_index * 4
        colors.append(bytes((palette[off], palette[off + 1], palette[off + 2], decode_ps2_alpha(palette[off + 3]))))
    return colors


def decode_ps2_alpha(value: int) -> int:
    expanded = max((value << 1) - ((value ^ 1) & 0x01), 0)
    return expanded if expanded <= 0xFF else value


def unswizzle_palette_index(index: int) -> int:
    block = index & ~0x1F
    pos = index & 0x1F
    if 8 <= pos < 16:
        pos += 8
    elif 16 <= pos < 24:
        pos -= 8
    return block + pos


def alpha_properties_for_rgba(rgba: bytes) -> dict[str, Any]:
    alphas = {rgba[offset] for offset in range(3, len(rgba), 4)}
    non_opaque = {alpha for alpha in alphas if alpha < 250}
    if not non_opaque:
        return {"mode": "", "cutoff": 0.0}
    only_cutout = True
    max_cutout = 0
    min_opaque = 255
    has_opaque = False
    for alpha in non_opaque:
        if alpha > 2:
            only_cutout = False
        max_cutout = max(max_cutout, alpha)
    for alpha in alphas:
        if alpha >= 250:
            has_opaque = True
            min_opaque = min(min_opaque, alpha)
    if only_cutout:
        cutoff = 0.5
        if has_opaque:
            cutoff = (float(max_cutout + min_opaque) / 2.0) / 255.0
        return {"mode": "MASK", "cutoff": cutoff}
    return {"mode": "BLEND", "cutoff": 0.0}


def material_alpha_properties_for_rgba(rgba: bytes, is_any_semitransparency: int) -> dict[str, Any]:
    props = alpha_properties_for_rgba(rgba)
    if props.get("mode", "") != "BLEND" or is_any_semitransparency != 0:
        return props
    alphas = {rgba[offset] for offset in range(3, len(rgba), 4)}
    if not alphas:
        return {"mode": "", "cutoff": 0.0}
    for alpha in alphas:
        if alpha != 0 and alpha < 0x80:
            return props
    return {"mode": "MASK", "cutoff": 0.5} if 0 in alphas else {"mode": "", "cutoff": 0.0}


def rgba_to_png(width: int, height: int, rgba: bytes) -> bytes:
    rows = bytearray()
    stride = width * 4
    for row_start in range(0, len(rgba), stride):
        rows.append(0)
        rows.extend(rgba[row_start:row_start + stride])
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    idat = zlib.compress(bytes(rows), level=9)
    return b"".join([
        b"\x89PNG\r\n\x1a\n",
        png_chunk(b"IHDR", ihdr),
        png_chunk(b"IDAT", idat),
        png_chunk(b"IEND", b""),
    ])


def png_chunk(kind: bytes, payload_bytes: bytes) -> bytes:
    crc = binascii.crc32(kind)
    crc = binascii.crc32(payload_bytes, crc) & 0xFFFFFFFF
    return struct.pack(">I", len(payload_bytes)) + kind + payload_bytes + struct.pack(">I", crc)


def collect_required_texture_hashes(asset: CarAsset) -> list[int]:
    seen: set[int] = set()
    hashes: list[int] = []
    for obj in asset.objects:
        for value in obj.get("texture_hashes", []):
            texture_hash = int(value)
            if texture_hash == 0 or texture_hash in seen:
                continue
            seen.add(texture_hash)
            hashes.append(texture_hash)
    return hashes


def candidate_texture_names(car_id: str, semantic: str) -> list[str]:
    if not car_id:
        return []
    if semantic == "HEADLIGHT":
        return [
            f"{car_id}_HEADLIGHT",
            f"{car_id}_HEADLIGHT_LEFT",
            f"{car_id}_HEADLIGHT_LEF",
            f"{car_id}_HEADLIGHT_RIGHT",
            f"{car_id}_HEADLIGHT_RIGH",
            f"{car_id}_HEADLIGHT_RIG",
        ]
    if semantic == "BRAKELIGHT":
        return [
            f"{car_id}_BRAKELIGHT",
            f"{car_id}_BRAKELIGHT_LEFT",
            f"{car_id}_BRAKELIGHT_LEF",
            f"{car_id}_BRAKELIGHT_RIGHT",
            f"{car_id}_BRAKELIGHT_RIGH",
            f"{car_id}_BRAKELIGHT_RIG",
        ]
    return []


def unique_strings(values: list[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for value in values:
        key = value.strip().upper()
        if not key or key in seen:
            continue
        seen.add(key)
        out.append(key)
    return out


def collect_required_texture_names(asset: CarAsset) -> list[str]:
    car_id = str(asset.car_id).upper()
    names = ["DASHWINDOW"]
    names.extend(candidate_texture_names(car_id, "HEADLIGHT"))
    names.extend(candidate_texture_names(car_id, "BRAKELIGHT"))
    return unique_strings(names)


def object_bounds_ps2(obj: dict[str, Any], apply_object_transform: bool = True) -> dict[str, tuple[float, float, float]] | None:
    out: dict[str, tuple[float, float, float]] | None = None
    for block in obj.get("blocks", []):
        block_bounds = block_bounds_ps2(obj, block, apply_object_transform)
        out = merge_bounds(out, block_bounds)
    return out


def block_bounds_ps2(obj: dict[str, Any], block: dict[str, Any], apply_object_transform: bool = True) -> dict[str, tuple[float, float, float]] | None:
    vertices = block.get("run", {}).get("vertices", [])
    if not vertices:
        return None
    transform_rows = obj.get("transform", [])
    points: list[tuple[float, float, float]] = []
    for vertex in vertices:
        point = transform_point_rows(vertex, transform_rows) if apply_object_transform else vertex
        points.append(point)
    return compute_bounds(points)


def texture_hash_for_block_dict(obj: dict[str, Any], block: dict[str, Any]) -> int:
    texture_index = int(block.get("texture_index", -1))
    hashes = obj.get("texture_hashes", [])
    if 0 <= texture_index < len(hashes):
        return int(hashes[texture_index])
    return 0


def side_texture_suffixes(side_prefix: str) -> list[str]:
    if side_prefix == "LEFT":
        return ["LEFT", "LEF"]
    if side_prefix == "RIGHT":
        return ["RIGHT", "RIGH", "RIG"]
    return []


def side_texture_prefixes(block_bounds: dict[str, tuple[float, float, float]] | None, object_bounds: dict[str, tuple[float, float, float]] | None) -> list[str]:
    if block_bounds is None or object_bounds is None:
        return ["LEFT", "RIGHT"]
    center_y = (block_bounds["min"][1] + block_bounds["max"][1]) * 0.5
    object_center_y = (object_bounds["min"][1] + object_bounds["max"][1]) * 0.5
    if center_y > object_center_y:
        return ["RIGHT", "LEFT"]
    return ["LEFT", "RIGHT"]


def candidate_texture_names_for_block(
    car_id: str,
    semantic: str,
    block_bounds: dict[str, tuple[float, float, float]] | None,
    object_bounds: dict[str, tuple[float, float, float]] | None,
) -> list[str]:
    default_name = f"{car_id}_{semantic}"
    candidates: list[str] = []
    for side_prefix in side_texture_prefixes(block_bounds, object_bounds):
        for suffix in side_texture_suffixes(side_prefix):
            candidates.append(f"{car_id}_{semantic}_{suffix}")
    candidates.append(default_name)
    candidates.extend(candidate_texture_names(car_id, semantic))
    return unique_strings(candidates)


def light_texture_has_side_suffix(texture_name: str) -> bool:
    upper = texture_name.upper()
    return upper.endswith("_LEFT") or upper.endswith("_LEF") or upper.endswith("_RIGHT") or upper.endswith("_RIGH") or upper.endswith("_RIG")


def apply_resolved_texture_uv_flags(
    block: dict[str, Any],
    alias_name: str,
    target_name: str,
    block_bounds: dict[str, tuple[float, float, float]] | None,
    object_bounds: dict[str, tuple[float, float, float]] | None,
) -> None:
    if alias_name not in {"HEADLIGHT", "BRAKELIGHT"}:
        return
    if light_texture_has_side_suffix(target_name) or block_bounds is None or object_bounds is None:
        return
    center_y = (block_bounds["min"][1] + block_bounds["max"][1]) * 0.5
    object_center_y = (object_bounds["min"][1] + object_bounds["max"][1]) * 0.5
    relative_center_y = center_y - object_center_y
    if abs(relative_center_y) <= 1e-4:
        return
    block["resolved_texture_mirror_u"] = relative_center_y > 0.0


def alias_texture_name_for_block(
    car_id: str,
    obj: dict[str, Any],
    block: dict[str, Any],
    object_bounds: dict[str, tuple[float, float, float]] | None,
) -> str:
    source_hash = texture_hash_for_block_dict(obj, block)
    if source_hash in CAR_WINDOW_MATERIAL_HASHES:
        return "DASHWINDOW"
    block_bounds = block_bounds_ps2(obj, block, False)
    if block_bounds is None or object_bounds is None:
        return ""
    object_min = object_bounds["min"]
    object_max = object_bounds["max"]
    block_min = block_bounds["min"]
    block_max = block_bounds["max"]
    transformed_object_bounds = object_bounds_ps2(obj, True)
    transformed_block_bounds = block_bounds_ps2(obj, block, True)
    if transformed_object_bounds is None or transformed_block_bounds is None:
        return ""
    transformed_object_min = transformed_object_bounds["min"]
    transformed_object_max = transformed_object_bounds["max"]
    transformed_block_min = transformed_block_bounds["min"]
    transformed_block_max = transformed_block_bounds["max"]
    object_size = tuple(abs(object_max[i] - object_min[i]) for i in range(3))
    block_size = tuple(abs(block_max[i] - block_min[i]) for i in range(3))
    transformed_object_size = tuple(abs(transformed_object_max[i] - transformed_object_min[i]) for i in range(3))
    transformed_block_size = tuple(abs(transformed_block_max[i] - transformed_block_min[i]) for i in range(3))
    transformed_block_center_x = (transformed_block_min[0] + transformed_block_max[0]) * 0.5
    front_limit = transformed_object_min[0] + max(transformed_object_size[0] * 0.12, 0.18)
    rear_limit = transformed_object_max[0] - max(transformed_object_size[0] * 0.12, 0.18)
    front_light_height_limit = object_min[2] + max(object_size[2] * 0.72, 0.70)
    rear_light_height_limit = object_min[2] + max(object_size[2] * 0.72, 0.70)
    light_length_limit = max(transformed_object_size[0] * 0.18, 0.32)
    light_width_limit = max(object_size[1] * 0.55, 0.55)
    if transformed_block_size[0] <= light_length_limit and block_size[1] <= light_width_limit and transformed_block_center_x <= front_limit and block_max[2] <= front_light_height_limit:
        return "HEADLIGHT"
    if transformed_block_size[0] <= light_length_limit and block_size[1] <= light_width_limit and transformed_block_center_x >= rear_limit and block_max[2] <= rear_light_height_limit:
        return "BRAKELIGHT"
    return ""


def resolved_alias_texture_name(
    texture_bank: TextureBank,
    car_id: str,
    alias_name: str,
    block_bounds: dict[str, tuple[float, float, float]] | None,
    object_bounds: dict[str, tuple[float, float, float]] | None,
) -> str:
    if alias_name == "DASHWINDOW":
        return alias_name if texture_bank.get_hash_for_name(alias_name) != 0 else ""
    for candidate in candidate_texture_names_for_block(car_id, alias_name, block_bounds, object_bounds):
        if texture_bank.get_hash_for_name(candidate) != 0:
            return candidate
    return ""


def is_body_variant_name(object_name: str, car_id: str) -> bool:
    car_id = car_id.upper()
    return any(object_name.upper() == f"{car_id}{suffix}" for suffix in ("_A", "_B", "_C", "_D"))


def install_car_texture_aliases(asset: CarAsset, texture_bank: TextureBank) -> None:
    car_id = asset.car_id.upper()
    for obj in asset.objects:
        object_name = str(obj.get("name", "")).upper()
        if not is_body_variant_name(object_name, car_id):
            continue
        bounds = object_bounds_ps2(obj, False)
        if bounds is None:
            continue
        blocks = obj.get("blocks", [])
        for block in blocks:
            source_hash = texture_hash_for_block_dict(obj, block)
            if source_hash == 0 or texture_bank.has_texture(source_hash):
                continue
            alias_name = alias_texture_name_for_block(car_id, obj, block, bounds)
            if not alias_name:
                continue
            block_bounds = block_bounds_ps2(obj, block, False)
            target_name = resolved_alias_texture_name(texture_bank, car_id, alias_name, block_bounds, bounds)
            if not target_name:
                continue
            target_hash = texture_bank.get_hash_for_name(target_name)
            if target_hash != 0:
                block["resolved_texture_hash"] = target_hash
                block["resolved_texture_name"] = target_name
                block["resolved_texture_alias"] = alias_name
                block["source_texture_hash"] = source_hash
                apply_resolved_texture_uv_flags(block, alias_name, target_name, block_bounds, bounds)


def is_tire_texture_name(texture_name: str) -> bool:
    return texture_name.upper().endswith("_TIRE")


def is_named_tire_texture_hash(texture_bank: TextureBank, texture_hash: int) -> bool:
    if texture_hash == 0:
        return False
    info = texture_bank.get_info(texture_hash)
    return info is not None and is_tire_texture_name(info.name)


def first_named_object_texture_hash(obj: dict[str, Any], texture_bank: TextureBank, suffix: str) -> int:
    for value in obj.get("texture_hashes", []):
        texture_hash = int(value)
        if texture_hash == 0 or not texture_bank.has_texture(texture_hash):
            continue
        info = texture_bank.get_info(texture_hash)
        if info and info.name.upper().endswith(suffix):
            return texture_hash
    return 0


def first_available_object_texture_hash(obj: dict[str, Any], texture_bank: TextureBank) -> int:
    for value in obj.get("texture_hashes", []):
        texture_hash = int(value)
        if texture_hash != 0 and texture_bank.has_texture(texture_hash):
            return texture_hash
    return 0


def should_alias_tire_material(source_hash: int, target_name: str) -> bool:
    target_upper = target_name.upper()
    if source_hash in {TIRE_RIM_MATERIAL_HASH, TIRE_CAP_MATERIAL_HASH}:
        return not target_upper.endswith("_TIRE")
    return True


def apply_tire_game_uv_flags(block: dict[str, Any], source_hash: int) -> None:
    _ = source_hash
    block["resolved_texture_preserve_v"] = False
    block["resolved_texture_mirror_u"] = False
    block.pop("resolved_texture_uv_offset", None)
    block.pop("resolved_texture_uv_scale", None)


def tire_alias_target_hash(obj: dict[str, Any], texture_bank: TextureBank) -> int:
    dedicated = first_named_object_texture_hash(obj, texture_bank, "_TIRE")
    return dedicated if dedicated != 0 else first_available_object_texture_hash(obj, texture_bank)


def install_tire_texture_aliases(asset: CarAsset, texture_bank: TextureBank) -> None:
    for obj in asset.objects:
        object_name = str(obj.get("name", "")).upper()
        if "_TIRE_" not in object_name:
            continue
        target_hash = tire_alias_target_hash(obj, texture_bank)
        if target_hash == 0:
            continue
        target_info = texture_bank.get_info(target_hash)
        target_name = target_info.name if target_info else ""
        for block in obj.get("blocks", []):
            source_hash = texture_hash_for_block_dict(obj, block)
            if is_named_tire_texture_hash(texture_bank, source_hash):
                apply_tire_game_uv_flags(block, source_hash)
                continue
            if source_hash == 0 or texture_bank.has_texture(source_hash):
                continue
            if not should_alias_tire_material(source_hash, target_name):
                continue
            block["resolved_texture_hash"] = target_hash
            block["resolved_texture_name"] = target_name
            block["resolved_texture_alias"] = "TIRE"
            block["source_texture_hash"] = source_hash
            if is_tire_texture_name(target_name):
                apply_tire_game_uv_flags(block, source_hash)


def load_texture_bank_for_asset(asset: CarAsset) -> TextureBank | None:
    texture_path = Path(asset.source_files.get("texture_car", ""))
    if not texture_path.is_file():
        return None
    texture_bank = TextureBank()
    texture_bank.load_for_car(
        asset.source_files,
        collect_required_texture_hashes(asset),
        collect_required_texture_names(asset),
    )
    install_car_texture_aliases(asset, texture_bank)
    install_tire_texture_aliases(asset, texture_bank)
    asset.warnings.extend(texture_bank.errors)
    return texture_bank


def gs_prim_type_for_mode(mode: str) -> int:
    if mode == "triangles":
        return 3
    if mode == "strip":
        return 4
    if mode == "fan":
        return 5
    return 0


def shift_left(value: int, shift: int) -> int:
    return value << shift if shift >= 0 else value >> -shift


def vif_control_mask(num_vertices: int, mode: int, tri_cull: list[int]) -> int:
    use_upper = mode & 0x04
    downer_side = (-(((mode & 0x03) + 1) >> 2) << (use_upper >> 2)) & 0x03
    upper_side = ~(-use_upper)
    downer = int(tri_cull[downer_side]) if 0 <= downer_side < len(tri_cull) else 0
    upper = int(tri_cull[upper_side]) if 0 <= upper_side < len(tri_cull) else 0
    hi_downer = downer >> 18
    lo_downer = downer & 0x7FFF
    hi_downer_swap = hi_downer ^ (lo_downer & 0x1E)
    hi_upper_swap = ((upper >> 2) | ((mode + 1) >> 1)) & 0x04
    new_downer = (lo_downer << 4) | (hi_downer_swap >> 1)
    new_upper = (upper >> 2) ^ (((hi_downer_swap >> 1) & 0x07) << 13) ^ (hi_upper_swap << 18)
    mask = shift_left(new_downer, ((mode - 3) << 2) - 3)
    if use_upper != 0:
        mask = (mask & ((0xFFFFFFFF << 13) & 0xFFFFFFFF)) | (new_upper & 0x3FFF)
    mask = shift_left(mask, (7 - mode) << 2)
    mask = mask & ((0xFFFFFFFF << (32 - num_vertices)) & 0xFFFFFFFF)
    return mask & 0xFFFFFFFF


def adc_disabled_from_vif_control(header: list[int], tri_cull: list[int], vertex_count: int) -> list[bool]:
    if len(header) < 2 or len(tri_cull) < 4 or vertex_count <= 0:
        return []
    num_vertices = int(header[0])
    mode = int(header[1])
    if num_vertices <= 0 or num_vertices > vertex_count or num_vertices > 32 or mode > 7:
        return []
    mask = vif_control_mask(num_vertices, mode, tri_cull)
    return [((mask >> (31 - index)) & 1) != 0 for index in range(vertex_count)]


def append_tri(out: list[int], a: int, b: int, c: int) -> None:
    if a != b and a != c and b != c:
        out.extend((a, b, c))


def strip_control_indices(block: dict[str, Any], vertex_count: int) -> list[int]:
    run = block.get("run", {})
    disabled = adc_disabled_from_vif_control(run.get("header", []), run.get("tri_cull", []), vertex_count)
    if not disabled:
        disabled = [False] * vertex_count
    out: list[int] = []
    face = 1
    for index in range(vertex_count):
        if bool(disabled[index]):
            face = 1
            continue
        a = index - 1 - face
        b = index - 1
        c = index - 1 + face
        if 0 <= a < vertex_count and 0 <= b < vertex_count and 0 <= c < vertex_count:
            append_tri(out, a, b, c)
        face = -face
    return out


def triangle_list_indices(count: int) -> list[int]:
    out: list[int] = []
    for index in range(0, count - (count % 3), 3):
        append_tri(out, index, index + 1, index + 2)
    return out


def fan_indices(count: int) -> list[int]:
    out: list[int] = []
    for index in range(1, count - 1):
        append_tri(out, 0, index, index + 1)
    return out


def indices_for_block(block: dict[str, Any], vertex_count: int) -> list[int]:
    primitive_mode = str(block.get("primitive_mode", "strip"))
    prim_type = gs_prim_type_for_mode(primitive_mode)
    if prim_type == 4:
        return strip_control_indices(block, vertex_count)
    if prim_type == 3:
        return triangle_list_indices(vertex_count)
    if prim_type == 5:
        return fan_indices(vertex_count)
    return []


def decode_vif_color_5551(value: int) -> tuple[float, float, float, float]:
    red = float((value & 0x1F) << 3) / 255.0
    green = float(((value >> 5) & 0x1F) << 3) / 255.0
    blue = float(((value >> 10) & 0x1F) << 3) / 255.0
    return (red, green, blue, 1.0)


def texture_hash_for_block(obj: dict[str, Any], block: dict[str, Any], block_index: int) -> int:
    resolved = int(block.get("resolved_texture_hash", 0))
    if resolved != 0:
        return resolved
    hashes = obj.get("texture_hashes", [])
    texture_index = int(block.get("texture_index", -1))
    if 0 <= texture_index < len(hashes):
        return int(hashes[texture_index])
    return int(hashes[min(block_index, len(hashes) - 1)]) if hashes else 0


def uv_array(block: dict[str, Any], vertex_count: int) -> list[tuple[float, float]]:
    texcoords = block.get("run", {}).get("texcoords", [])
    if len(texcoords) < vertex_count:
        return []
    out: list[tuple[float, float]] = []
    for index in range(vertex_count):
        uv = texcoords[index]
        u = 1.0 - uv[0] if bool(block.get("resolved_texture_mirror_u", False)) else uv[0]
        v = uv[1] if bool(block.get("resolved_texture_preserve_v", False)) else 1.0 - uv[1]
        if "resolved_texture_uv_offset" in block and "resolved_texture_uv_scale" in block:
            uv_offset = block["resolved_texture_uv_offset"]
            uv_scale = block["resolved_texture_uv_scale"]
            u = uv_offset[0] + u * uv_scale[0]
            v = uv_offset[1] + v * uv_scale[1]
        out.append((u, v))
    return out


def color_array(block: dict[str, Any], vertex_count: int) -> list[tuple[float, float, float, float]]:
    packed_values = block.get("run", {}).get("packed_values", [])
    if len(packed_values) < vertex_count:
        return []
    return [decode_vif_color_5551(int(packed_values[index])) for index in range(vertex_count)]


def normal_array(vertices: list[tuple[float, float, float]], indices: list[int]) -> list[tuple[float, float, float]]:
    accum = [(0.0, 0.0, 0.0) for _ in vertices]
    for index in range(0, len(indices) - 2, 3):
        a = int(indices[index])
        b = int(indices[index + 1])
        c = int(indices[index + 2])
        if not (0 <= a < len(vertices) and 0 <= b < len(vertices) and 0 <= c < len(vertices)):
            continue
        normal = v_cross(v_sub(vertices[b], vertices[a]), v_sub(vertices[c], vertices[a]))
        if v_length_sq(normal) <= 1e-6:
            continue
        normal = v_normalize(normal)
        accum[a] = v_add(accum[a], normal)
        accum[b] = v_add(accum[b], normal)
        accum[c] = v_add(accum[c], normal)
    out: list[tuple[float, float, float]] = []
    for normal in accum:
        out.append(v_normalize(normal) if v_length_sq(normal) > 1e-6 else (0.0, 1.0, 0.0))
    return out


def runtime_part_local_basis(obj: dict[str, Any]) -> list[tuple[float, float, float]]:
    basis = basis_orthonormalized(ps2_rows_to_godot_basis(obj.get("transform", [])))
    if basis_determinant(basis) < 0.0:
        basis = basis_orthonormalized([v_scale(basis[0], -1.0), basis[1], basis[2]])
    return basis


def wheel_mesh_axle_direction(mesh_size: tuple[float, float, float], basis: list[tuple[float, float, float]]) -> tuple[float, float, float]:
    axle_axis = 0
    smallest = mesh_size[0]
    if mesh_size[1] < smallest:
        axle_axis = 1
        smallest = mesh_size[1]
    if mesh_size[2] < smallest:
        axle_axis = 2
    if axle_axis == 1:
        return v_normalize(basis[1])
    if axle_axis == 2:
        return v_normalize(basis[2])
    return v_normalize(basis[0])


def local_bbox_size_godot(obj: dict[str, Any]) -> tuple[float, float, float]:
    points: list[tuple[float, float, float]] = []
    for block in obj.get("blocks", []):
        for vertex in block.get("run", {}).get("vertices", []):
            points.append(ps2_to_godot_vec3(vertex))
    bounds = compute_bounds(points)
    if bounds is None:
        return (0.0, 0.0, 0.0)
    return (
        abs(bounds["max"][0] - bounds["min"][0]),
        abs(bounds["max"][1] - bounds["min"][1]),
        abs(bounds["max"][2] - bounds["min"][2]),
    )


def canonical_wheel_part_basis(obj: dict[str, Any]) -> list[tuple[float, float, float]]:
    basis = basis_orthonormalized(runtime_part_local_basis(obj))
    axle_direction = wheel_mesh_axle_direction(local_bbox_size_godot(obj), basis)
    if v_length_sq(axle_direction) <= 1e-6:
        return basis
    correction = rotation_between_vectors(axle_direction, (1.0, 0.0, 0.0))
    return basis_orthonormalized(basis_mul(correction, basis))


def expected_wheel_diameter(config: CarConfig, axle: str) -> float:
    indices = [0, 1] if axle == "front" else [2, 3]
    values = [config.wheel_radii[index] * 2.0 for index in indices if index < len(config.wheel_radii)]
    return sum(values) / len(values) if values else 0.0


def wheel_template_score(obj: dict[str, Any], expected_diameter_value: float, detail_level: int) -> float:
    local_size = local_bbox_size_godot(obj)
    basis = runtime_part_local_basis(obj)
    transformed_size = (
        abs(basis[0][0]) * local_size[0] + abs(basis[1][0]) * local_size[1] + abs(basis[2][0]) * local_size[2],
        abs(basis[0][1]) * local_size[0] + abs(basis[1][1]) * local_size[1] + abs(basis[2][1]) * local_size[2],
        abs(basis[0][2]) * local_size[0] + abs(basis[1][2]) * local_size[1] + abs(basis[2][2]) * local_size[2],
    )
    largest_dimension = max(transformed_size)
    if expected_diameter_value <= 1e-4:
        return -largest_dimension + float(detail_level) * 0.01
    dimension_error = abs(largest_dimension - expected_diameter_value)
    tiny_penalty = 10.0 if largest_dimension < expected_diameter_value * 0.35 else 0.0
    return dimension_error + tiny_penalty + float(detail_level) * 0.01


def named_tire_choice(asset: CarAsset, tire_objects: dict[str, dict[str, Any]], axle: str, detail_suffix: str) -> dict[str, Any]:
    object_name = f"_TIRE_{axle.upper()}_{detail_suffix}"
    obj = tire_objects.get(object_name)
    if obj is None:
        return {}
    return {
        "axle": axle,
        "source_axle": axle,
        "detail_suffix": detail_suffix,
        "detail_level": TIRE_DETAIL_SUFFIXES.index(detail_suffix),
        "actual_detail_suffix": detail_suffix,
        "object_name": f"{asset.car_id.upper()}{object_name}",
        "object": obj,
    }


def retarget_tire_choice(choice: dict[str, Any], axle: str, detail_suffix: str, reason: str) -> dict[str, Any]:
    if not choice:
        return {}
    out = dict(choice)
    out["axle"] = axle
    out["detail_suffix"] = detail_suffix
    out["detail_level"] = TIRE_DETAIL_SUFFIXES.index(detail_suffix)
    out["selection_reason"] = reason
    out.setdefault("actual_detail_suffix", str(choice.get("detail_suffix", "")))
    return out


def resolved_tire_detail_choices(asset: CarAsset, tire_objects: dict[str, dict[str, Any]], config: CarConfig) -> dict[str, dict[str, Any]]:
    front_choices = {suffix: named_tire_choice(asset, tire_objects, "front", suffix) for suffix in TIRE_DETAIL_SUFFIXES}
    rear_choices = {suffix: named_tire_choice(asset, tire_objects, "rear", suffix) for suffix in TIRE_DETAIL_SUFFIXES}
    if config.globalb_vehicle_type_id == 2:
        front_choices["C"] = retarget_tire_choice(front_choices.get("B", {}), "front", "C", "vehicle_type_2_front_c_uses_front_b")
        rear_choices["C"] = retarget_tire_choice(rear_choices.get("B", {}), "rear", "C", "vehicle_type_2_rear_c_uses_rear_b")
    if not rear_choices.get("A"):
        rear_choices["A"] = retarget_tire_choice(front_choices.get("A", {}), "rear", "A", "rear_a_falls_back_to_front_a")
    if not rear_choices.get("B"):
        rear_choices["B"] = retarget_tire_choice(front_choices.get("B", {}), "rear", "B", "rear_b_falls_back_to_front_b")
    if not rear_choices.get("C"):
        rear_choices["C"] = retarget_tire_choice(front_choices.get("C", {}), "rear", "C", "rear_c_falls_back_to_front_c")
    return {"front": front_choices, "rear": rear_choices}


def best_tire_choice_for_axle(choices: dict[str, dict[str, Any]], config: CarConfig, axle: str) -> dict[str, Any]:
    expected = expected_wheel_diameter(config, axle)
    best_choice: dict[str, Any] = {}
    best_score = math.inf
    for suffix in TIRE_DETAIL_SUFFIXES:
        choice = choices.get(suffix, {})
        if not choice:
            continue
        score = wheel_template_score(choice["object"], expected, int(choice.get("detail_level", -1)))
        if score < best_score:
            best_score = score
            best_choice = choice
    return best_choice


def select_normal_wheel_visuals(asset: CarAsset, tire_objects: dict[str, dict[str, Any]], config: CarConfig) -> dict[str, dict[str, Any]]:
    detail_choices = resolved_tire_detail_choices(asset, tire_objects, config)
    front_choice = best_tire_choice_for_axle(detail_choices.get("front", {}), config, "front")
    rear_choice = best_tire_choice_for_axle(detail_choices.get("rear", {}), config, "rear")
    return {slot_id: (front_choice if slot_id in {"FL", "FR"} else rear_choice) for slot_id in SLOT_IDS}


def pick_primary_body_variant(asset: CarAsset) -> str:
    car_id = asset.car_id.upper()
    available = {str(obj.get("name", "")).upper() for obj in asset.objects}
    for suffix in ("_A", "_B", "_C", "_D"):
        candidate = f"{car_id}{suffix}"
        if candidate in available:
            return candidate
    return ""


def is_runtime_wheel_part(object_name: str) -> bool:
    upper = object_name.upper()
    return "_TIRE_" in upper or "_BRAKE_" in upper or upper.endswith("_WHEEL_BLUR")


def should_include_static_mesh(object_name: str, car_id: str, primary_body_variant: str) -> bool:
    upper = object_name.upper()
    normalized_car_id = car_id.upper()
    if is_runtime_wheel_part(upper):
        return False
    if upper.endswith("_SCUFFS") or upper.endswith("_CV"):
        return False
    if primary_body_variant and upper == primary_body_variant:
        return True
    if upper.endswith("_SIDE_MIRROR_LE") or upper.endswith("_SIDE_MIRROR_RI"):
        return True
    if upper.endswith("_WIPER_LEFT") or upper.endswith("_WIPER_RIGHT"):
        return True
    if upper.endswith("_LICENSE_PLATE_"):
        return True
    if normalized_car_id and upper.startswith(f"{normalized_car_id}_"):
        return False
    return True


def collect_named_objects(asset: CarAsset, suffixes: list[str]) -> dict[str, dict[str, Any]]:
    out: dict[str, dict[str, Any]] = {}
    for obj in asset.objects:
        object_name = str(obj.get("name", ""))
        for suffix in suffixes:
            if object_name.endswith(suffix) and suffix not in out:
                out[suffix] = obj
    return out


def wheel_base_yaw(slot_id: str) -> float:
    return -math.pi * 0.5 if slot_id.endswith("R") else math.pi * 0.5


def slot_index(slot_id: str) -> int:
    return SLOT_IDS.index(slot_id)


def transformed_vertices_for_block(
    obj: dict[str, Any],
    block: dict[str, Any],
    apply_object_transform: bool,
    basis: list[tuple[float, float, float]] | None = None,
    translation: tuple[float, float, float] = (0.0, 0.0, 0.0),
    uniform_scale: float = 1.0,
) -> list[tuple[float, float, float]]:
    out: list[tuple[float, float, float]] = []
    transform_rows = obj.get("transform", [])
    for vertex in block.get("run", {}).get("vertices", []):
        point = transform_point_rows(vertex, transform_rows) if apply_object_transform else vertex
        godot = ps2_to_godot_vec3(point)
        if basis is not None:
            godot = basis_apply(basis, godot)
        if abs(uniform_scale - 1.0) > 1e-6:
            godot = v_scale(godot, uniform_scale)
        out.append(v_add(godot, translation))
    return out


def build_mesh_primitives(
    obj: dict[str, Any],
    texture_bank: TextureBank | None,
    apply_object_transform: bool,
    basis: list[tuple[float, float, float]] | None = None,
    translation: tuple[float, float, float] = (0.0, 0.0, 0.0),
    uniform_scale: float = 1.0,
) -> list[dict[str, Any]]:
    primitives: list[dict[str, Any]] = []
    for block_index, block in enumerate(obj.get("blocks", [])):
        vertices = transformed_vertices_for_block(obj, block, apply_object_transform, basis, translation, uniform_scale)
        if len(vertices) < 3:
            continue
        indices = indices_for_block(block, len(vertices))
        if len(indices) < 3:
            continue
        texcoords = uv_array(block, len(vertices))
        colors = color_array(block, len(vertices))
        normals = normal_array(vertices, indices)
        texture_hash = texture_hash_for_block(obj, block, block_index)
        texture_info = texture_bank.get_info(texture_hash) if texture_bank and texture_hash != 0 else None
        primitives.append({
            "positions": vertices,
            "indices": indices,
            "normals": normals,
            "texcoords": texcoords if len(texcoords) == len(vertices) else [],
            "colors": colors if len(colors) == len(vertices) else [],
            "texture": texture_info,
            "name": str(obj.get("name", "")),
        })
    return primitives


def load_car_scene(game_root: Path, car_id: str, duplicate_index: int, drive_type: str) -> dict[str, Any]:
    model_path = resolve_car_model_path(game_root, car_id)
    texture_car = resolve_car_texture_path(game_root, model_path)
    texture_global = resolve_global_texture_path(game_root, model_path)
    files = {
        "car_id": normalized_car_id(car_id),
        "model": str(model_path),
        "texture_car": str(texture_car),
        "texture_global": str(texture_global),
    }
    asset = parse_car_asset(files)
    texture_bank = load_texture_bank_for_asset(asset)
    globalb_path = texture_global if texture_global.is_file() else Path()
    config = parse_globalb_config(globalb_path, asset.car_id, duplicate_index, drive_type) or CarConfig(
        car_name=asset.car_id,
        duplicate_index=duplicate_index,
        drive_type=drive_type.upper(),
    )
    primary_body_variant = pick_primary_body_variant(asset)
    meshes: list[dict[str, Any]] = []
    for obj in asset.objects:
        name = str(obj.get("name", ""))
        if not should_include_static_mesh(name, asset.car_id, primary_body_variant):
            continue
        primitives = build_mesh_primitives(obj, texture_bank, True)
        if primitives:
            meshes.append({"name": name, "primitives": primitives})
    tire_objects = collect_named_objects(asset, [
        "_TIRE_FRONT_A",
        "_TIRE_FRONT_B",
        "_TIRE_FRONT_C",
        "_TIRE_REAR_A",
        "_TIRE_REAR_B",
        "_TIRE_REAR_C",
    ])
    brake_objects = collect_named_objects(asset, [
        "_BRAKE_FRONT",
        "_BRAKE_REAR",
    ])
    wheel_visual_selection = select_normal_wheel_visuals(asset, tire_objects, config)
    for slot_id in SLOT_IDS:
        index = slot_index(slot_id)
        if index >= len(config.wheel_local_positions_ps2):
            continue
        pivot_position = ps2_to_godot_vec3(config.wheel_local_positions_ps2[index])
        slot_yaw_basis = yaw_basis(wheel_base_yaw(slot_id))
        tire_choice = wheel_visual_selection.get(slot_id, {})
        tire_obj = tire_choice.get("object")
        if tire_obj is not None:
            canonical_basis = canonical_wheel_part_basis(tire_obj)
            final_basis = basis_mul(slot_yaw_basis, canonical_basis)
            expected_radius = config.wheel_radii[index] if index < len(config.wheel_radii) else 0.0
            local_size = local_bbox_size_godot(tire_obj)
            visual_radius = max(local_size[1], local_size[2]) * 0.5
            uniform_scale = expected_radius / visual_radius if expected_radius > 1e-4 and visual_radius > 1e-4 else 1.0
            primitives = build_mesh_primitives(tire_obj, texture_bank, False, final_basis, pivot_position, uniform_scale)
            if primitives:
                meshes.append({"name": f"{slot_id}_Tire", "primitives": primitives})
        brake_suffix = "_BRAKE_FRONT" if slot_id in {"FL", "FR"} else "_BRAKE_REAR"
        brake_obj = brake_objects.get(brake_suffix) or brake_objects.get("_BRAKE_FRONT")
        if brake_obj is not None:
            canonical_basis = canonical_wheel_part_basis(brake_obj)
            final_basis = basis_mul(slot_yaw_basis, canonical_basis)
            primitives = build_mesh_primitives(brake_obj, texture_bank, False, final_basis, pivot_position, 1.0)
            if primitives:
                meshes.append({"name": f"{slot_id}_Brake", "primitives": primitives})
    return {
        "asset": asset,
        "config": config,
        "meshes": meshes,
    }


class BufferBuilder:
    def __init__(self) -> None:
        self.data = bytearray()

    def add(self, payload_bytes: bytes, alignment: int = 4) -> tuple[int, int]:
        while len(self.data) % alignment != 0:
            self.data.append(0)
        offset = len(self.data)
        self.data.extend(payload_bytes)
        return offset, len(payload_bytes)


def pack_floats(values: list[float]) -> bytes:
    return struct.pack("<" + "f" * len(values), *values)


def pack_uint16(values: list[int]) -> bytes:
    return struct.pack("<" + "H" * len(values), *values)


def pack_uint32(values: list[int]) -> bytes:
    return struct.pack("<" + "I" * len(values), *values)


def flatten_vec2(values: list[tuple[float, float]]) -> list[float]:
    out: list[float] = []
    for x, y in values:
        out.extend((x, y))
    return out


def flatten_vec3(values: list[tuple[float, float, float]]) -> list[float]:
    out: list[float] = []
    for x, y, z in values:
        out.extend((x, y, z))
    return out


def flatten_vec4(values: list[tuple[float, float, float, float]]) -> list[float]:
    out: list[float] = []
    for x, y, z, w in values:
        out.extend((x, y, z, w))
    return out


def min_max_vec3(values: list[tuple[float, float, float]]) -> tuple[list[float], list[float]]:
    mins = [math.inf, math.inf, math.inf]
    maxs = [-math.inf, -math.inf, -math.inf]
    for value in values:
        for index in range(3):
            mins[index] = min(mins[index], value[index])
            maxs[index] = max(maxs[index], value[index])
    return mins, maxs


def add_accessor(gltf: dict[str, Any], buffer_view: int, component_type: int, count: int, type_name: str, min_values: list[float] | None = None, max_values: list[float] | None = None) -> int:
    accessor = {
        "bufferView": buffer_view,
        "componentType": component_type,
        "count": count,
        "type": type_name,
    }
    if min_values is not None:
        accessor["min"] = min_values
    if max_values is not None:
        accessor["max"] = max_values
    gltf.setdefault("accessors", []).append(accessor)
    return len(gltf["accessors"]) - 1


def build_gltf_document(scene: dict[str, Any], output_ext: str) -> tuple[dict[str, Any], bytes]:
    gltf: dict[str, Any] = {
        "asset": {"version": "2.0", "generator": "godot_eagl_ps2 pure python exporter"},
        "scene": 0,
        "scenes": [{"name": scene["asset"].car_id, "nodes": []}],
        "nodes": [],
        "meshes": [],
        "buffers": [],
        "bufferViews": [],
        "accessors": [],
        "materials": [],
        "textures": [],
        "images": [],
        "samplers": [{"magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497}],
    }
    buffer_builder = BufferBuilder()
    image_cache: dict[int, tuple[int, int]] = {}
    material_cache: dict[str, int] = {}

    def ensure_image(texture: TextureInfo) -> tuple[int, int]:
        cached = image_cache.get(texture.texture_hash)
        if cached is not None:
            return cached
        offset, length = buffer_builder.add(texture.png_bytes, 4)
        gltf["bufferViews"].append({"buffer": 0, "byteOffset": offset, "byteLength": length})
        buffer_view_index = len(gltf["bufferViews"]) - 1
        gltf["images"].append({"bufferView": buffer_view_index, "mimeType": "image/png", "name": texture.name})
        image_index = len(gltf["images"]) - 1
        gltf["textures"].append({"sampler": 0, "source": image_index})
        texture_index = len(gltf["textures"]) - 1
        image_cache[texture.texture_hash] = (image_index, texture_index)
        return image_index, texture_index

    def ensure_material(texture: TextureInfo | None) -> int:
        if texture is None:
            key = "fallback"
            if key not in material_cache:
                gltf["materials"].append({
                    "name": "fallback",
                    "pbrMetallicRoughness": {
                        "baseColorFactor": [1.0, 1.0, 1.0, 1.0],
                        "metallicFactor": 0.0,
                        "roughnessFactor": 1.0,
                    },
                    "doubleSided": True,
                })
                material_cache[key] = len(gltf["materials"]) - 1
            return material_cache[key]
        key = f"tex:{texture.texture_hash}"
        if key not in material_cache:
            _, texture_index = ensure_image(texture)
            material: dict[str, Any] = {
                "name": texture.name,
                "pbrMetallicRoughness": {
                    "baseColorTexture": {"index": texture_index},
                    "baseColorFactor": [1.0, 1.0, 1.0, 1.0],
                    "metallicFactor": 0.0,
                    "roughnessFactor": 1.0,
                },
                "doubleSided": True,
            }
            if texture.alpha_mode:
                material["alphaMode"] = texture.alpha_mode
            if texture.alpha_mode == "MASK":
                material["alphaCutoff"] = texture.alpha_cutoff
            gltf["materials"].append(material)
            material_cache[key] = len(gltf["materials"]) - 1
        return material_cache[key]

    for mesh_entry in scene["meshes"]:
        mesh_primitives: list[dict[str, Any]] = []
        for primitive in mesh_entry["primitives"]:
            positions = primitive["positions"]
            normals = primitive["normals"]
            texcoords = primitive["texcoords"]
            colors = primitive["colors"]
            indices = primitive["indices"]

            position_bytes = pack_floats(flatten_vec3(positions))
            position_offset, position_length = buffer_builder.add(position_bytes, 4)
            gltf["bufferViews"].append({"buffer": 0, "byteOffset": position_offset, "byteLength": position_length, "target": 34962})
            position_buffer_view = len(gltf["bufferViews"]) - 1
            min_values, max_values = min_max_vec3(positions)
            position_accessor = add_accessor(gltf, position_buffer_view, 5126, len(positions), "VEC3", min_values, max_values)

            normal_bytes = pack_floats(flatten_vec3(normals))
            normal_offset, normal_length = buffer_builder.add(normal_bytes, 4)
            gltf["bufferViews"].append({"buffer": 0, "byteOffset": normal_offset, "byteLength": normal_length, "target": 34962})
            normal_accessor = add_accessor(gltf, len(gltf["bufferViews"]) - 1, 5126, len(normals), "VEC3")

            attributes = {
                "POSITION": position_accessor,
                "NORMAL": normal_accessor,
            }

            if texcoords:
                texcoord_bytes = pack_floats(flatten_vec2(texcoords))
                texcoord_offset, texcoord_length = buffer_builder.add(texcoord_bytes, 4)
                gltf["bufferViews"].append({"buffer": 0, "byteOffset": texcoord_offset, "byteLength": texcoord_length, "target": 34962})
                attributes["TEXCOORD_0"] = add_accessor(gltf, len(gltf["bufferViews"]) - 1, 5126, len(texcoords), "VEC2")

            if colors:
                color_bytes = pack_floats(flatten_vec4(colors))
                color_offset, color_length = buffer_builder.add(color_bytes, 4)
                gltf["bufferViews"].append({"buffer": 0, "byteOffset": color_offset, "byteLength": color_length, "target": 34962})
                attributes["COLOR_0"] = add_accessor(gltf, len(gltf["bufferViews"]) - 1, 5126, len(colors), "VEC4")

            if len(positions) < 65536:
                index_bytes = pack_uint16(indices)
                index_component_type = 5123
            else:
                index_bytes = pack_uint32(indices)
                index_component_type = 5125
            index_offset, index_length = buffer_builder.add(index_bytes, 4)
            gltf["bufferViews"].append({"buffer": 0, "byteOffset": index_offset, "byteLength": index_length, "target": 34963})
            index_accessor = add_accessor(gltf, len(gltf["bufferViews"]) - 1, index_component_type, len(indices), "SCALAR")

            mesh_primitives.append({
                "attributes": attributes,
                "indices": index_accessor,
                "material": ensure_material(primitive["texture"]),
                "mode": 4,
            })

        gltf["meshes"].append({"name": mesh_entry["name"], "primitives": mesh_primitives})
        mesh_index = len(gltf["meshes"]) - 1
        gltf["nodes"].append({"name": mesh_entry["name"], "mesh": mesh_index})
        gltf["scenes"][0]["nodes"].append(len(gltf["nodes"]) - 1)

    binary_blob = bytes(buffer_builder.data)
    gltf["buffers"].append({"byteLength": len(binary_blob)})
    if output_ext == ".gltf":
        gltf["buffers"][0]["uri"] = "data:application/octet-stream;base64," + base64.b64encode(binary_blob).decode("ascii")
    return gltf, binary_blob


def write_gltf(path: Path, gltf: dict[str, Any]) -> None:
    path.write_text(json.dumps(gltf, indent=2), encoding="utf-8")


def write_glb(path: Path, gltf: dict[str, Any], binary_blob: bytes) -> None:
    json_bytes = json.dumps(gltf, separators=(",", ":")).encode("utf-8")
    json_padding = (4 - (len(json_bytes) % 4)) % 4
    json_bytes += b" " * json_padding
    bin_padding = (4 - (len(binary_blob) % 4)) % 4
    binary_blob += b"\x00" * bin_padding
    total_length = 12 + 8 + len(json_bytes) + 8 + len(binary_blob)
    with path.open("wb") as handle:
        handle.write(struct.pack("<4sII", b"glTF", 2, total_length))
        handle.write(struct.pack("<I4s", len(json_bytes), b"JSON"))
        handle.write(json_bytes)
        handle.write(struct.pack("<I4s", len(binary_blob), b"BIN\x00"))
        handle.write(binary_blob)


def export_car(game_root: Path, car_id: str, output_path: Path, duplicate_index: int = 1, drive_type: str = "RWD") -> dict[str, Any]:
    scene = load_car_scene(game_root, car_id, duplicate_index, drive_type)
    gltf, binary_blob = build_gltf_document(scene, output_path.suffix.lower())
    output_path.parent.mkdir(parents=True, exist_ok=True)
    if output_path.suffix.lower() == ".gltf":
        write_gltf(output_path, gltf)
    elif output_path.suffix.lower() == ".glb":
        write_glb(output_path, gltf, binary_blob)
    else:
        raise ExportError("Output path must end with .glb or .gltf")
    return {
        "car_id": scene["asset"].car_id,
        "mesh_count": len(scene["meshes"]),
        "warning_count": len(scene["asset"].warnings),
        "warnings": scene["asset"].warnings,
    }
