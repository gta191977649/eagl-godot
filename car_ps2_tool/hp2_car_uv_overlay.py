#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
import struct
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Any


DEFAULT_ROOT = Path("/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA")
RIM_MATERIAL_HASH = 0x001D38B3
CAP_MATERIAL_HASH = 0xC8C5A8A4

POSITION_S16_SCALE = 1.0 / 4096.0
POSITION_S8_SCALE = 1.0 / 128.0

OVERLAY_COLORS = [
    (255, 24, 24, 255),
    (28, 242, 72, 255),
    (24, 112, 255, 255),
    (255, 235, 32, 255),
    (255, 64, 242, 255),
    (0, 242, 242, 255),
]


def u8(data: bytes | bytearray, offset: int) -> int:
    return data[offset] if 0 <= offset < len(data) else 0


def s8(data: bytes | bytearray, offset: int) -> int:
    value = u8(data, offset)
    return value - 0x100 if value & 0x80 else value


def u16(data: bytes | bytearray, offset: int) -> int:
    if offset < 0 or offset + 1 >= len(data):
        return 0
    return data[offset] | (data[offset + 1] << 8)


def s16(data: bytes | bytearray, offset: int) -> int:
    value = u16(data, offset)
    return value - 0x10000 if value & 0x8000 else value


def u32(data: bytes | bytearray, offset: int) -> int:
    if offset < 0 or offset + 3 >= len(data):
        return 0
    return data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16) | (data[offset + 3] << 24)


def f32(data: bytes | bytearray, offset: int) -> float:
    if offset < 0 or offset + 3 >= len(data):
        return 0.0
    return struct.unpack_from("<f", data, offset)[0]


def align(value: int, boundary: int) -> int:
    return (value + boundary - 1) & ~(boundary - 1)


def safe_name(value: str) -> str:
    out = value.strip() or "unnamed"
    for token in ":/\\ @":
        out = out.replace(token, "_")
    return out


def load_bundle_bytes(path: Path) -> bytes:
    data = path.read_bytes()
    if data.startswith(b"COMP"):
        return decompress_lzc(data)
    return data


def decompress_lzc(data: bytes) -> bytes:
    if len(data) < 16 or not data.startswith(b"COMP"):
        return data
    decompressed_size = u32(data, 8)
    payload = data[16:]
    out = bytearray()
    src = 0
    flags = 1
    while src < len(payload) and len(out) < decompressed_size:
        if flags == 1:
            if src + 2 > len(payload):
                break
            flags = (payload[src] | (payload[src + 1] << 8)) | 0x10000
            src += 2
        cycles = 1 if (len(payload) - 32) < src else 16
        for _ in range(cycles):
            if src >= len(payload) or len(out) >= decompressed_size:
                break
            if flags & 1:
                if src + 2 > len(payload):
                    return bytes(out)
                control = payload[src]
                distance = payload[src + 1] | ((control & 0xF0) << 4)
                src += 2
                if distance == 0 or distance > len(out):
                    return bytes(out)
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
    return bytes(out)


@dataclass
class Chunk:
    id: int
    size: int
    offset: int
    data_offset: int
    end_offset: int
    children: list["Chunk"]


def parse_chunks(data: bytes, start: int = 0, end: int | None = None) -> list[Chunk]:
    if end is None:
        end = len(data)
    chunks: list[Chunk] = []
    pos = start
    while pos + 8 <= end:
        chunk_id = u32(data, pos)
        size = u32(data, pos + 4)
        data_offset = pos + 8
        chunk_end = data_offset + size
        if chunk_end > end:
            break
        children = parse_chunks(data, data_offset, chunk_end) if chunk_id & 0x80000000 else []
        chunks.append(Chunk(chunk_id, size, pos, data_offset, chunk_end, children))
        pos = chunk_end
    return chunks


def walk_chunks(chunks: list[Chunk]) -> list[Chunk]:
    out: list[Chunk] = []
    for chunk in chunks:
        out.append(chunk)
        out.extend(walk_chunks(chunk.children))
    return out


def child_with_id(chunk: Chunk, chunk_id: int) -> Chunk | None:
    for child in chunk.children:
        if child.id == chunk_id:
            return child
    return None


def first_chunk_with_id(chunks: list[Chunk], chunk_id: int) -> Chunk | None:
    for chunk in chunks:
        if chunk.id == chunk_id:
            return chunk
    return None


def payload(data: bytes, chunk: Chunk) -> bytes:
    return data[chunk.data_offset : chunk.end_offset]


@dataclass
class Texture:
    name: str
    hash: int
    width: int
    height: int
    rgba: bytearray
    info: dict[str, Any]


class TextureBank:
    def __init__(self) -> None:
        self.textures: dict[int, Texture] = {}
        self.name_hashes: dict[str, int] = {}
        self.errors: list[str] = []

    def load(self, path: Path, wanted_hashes: set[int] | None = None, wanted_names: set[str] | None = None) -> None:
        wanted_hashes = wanted_hashes or set()
        wanted_names = wanted_names or set()
        data = path.read_bytes()
        chunks = walk_chunks(parse_chunks(data))
        entry_chunk = first_chunk_with_id(chunks, 0x30300003)
        data_chunk = first_chunk_with_id(chunks, 0x30300004)
        if entry_chunk is None or data_chunk is None:
            self.errors.append(f"missing texture entry/data chunks in {path}")
            return
        entries = payload(data, entry_chunk)
        if len(entries) % 0xA4 != 0:
            self.errors.append(f"unexpected texture entry table size {len(entries)} in {path}")
            return
        data_base = align(data_chunk.data_offset, 0x80)
        for offset in range(0, len(entries), 0xA4):
            self._decode_entry(path, data, data_base, entries[offset : offset + 0xA4], wanted_hashes, wanted_names)

    def has(self, texture_hash: int) -> bool:
        return texture_hash in self.textures

    def get(self, texture_hash: int) -> Texture | None:
        return self.textures.get(texture_hash)

    def get_hash_for_name(self, texture_name: str) -> int:
        return self.name_hashes.get(texture_name.strip().upper(), 0)

    def _decode_entry(
        self,
        path: Path,
        data: bytes,
        data_base: int,
        entry: bytes,
        wanted_hashes: set[int],
        wanted_names: set[str],
    ) -> None:
        name = entry_name(entry)
        texture_hash = u32(entry, 0x20)
        if (wanted_hashes or wanted_names) and texture_hash not in wanted_hashes and name.upper() not in wanted_names:
            return
        width = u16(entry, 0x24)
        height = u16(entry, 0x26)
        bit_depth = u8(entry, 0x28)
        data_offset = u32(entry, 0x30)
        palette_offset = u32(entry, 0x34)
        data_size = u32(entry, 0x38)
        palette_size = u32(entry, 0x3C)
        shift_width = u8(entry, 0x48)
        shift_height = u8(entry, 0x49)
        pixel_storage_mode = u8(entry, 0x4A)
        is_swizzled = u8(entry, 0x55) != 0
        if not name or texture_hash == 0 or width <= 0 or height <= 0 or data_size <= 0:
            return
        image_start = data_base + data_offset
        palette_start = data_base + palette_offset
        if image_start + data_size > len(data) or (palette_size > 0 and palette_start + palette_size > len(data)):
            self.errors.append(f"texture {name} points outside {path}")
            return
        image = data[image_start : image_start + data_size]
        if bit_depth == 32 and palette_size == 0:
            rgba = decode_rgba_texture(width, height, image)
        else:
            if palette_size <= 0:
                return
            palette = data[palette_start : palette_start + palette_size]
            rgba = decode_indexed_texture(
                width,
                height,
                image,
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
        texture = Texture(
            name=name,
            hash=texture_hash,
            width=width,
            height=height,
            rgba=rgba,
            info={
                "name": name,
                "hash": texture_hash,
                "width": width,
                "height": height,
                "source_path": str(path),
                "bit_depth": bit_depth,
                "shift_width": shift_width,
                "shift_height": shift_height,
                "pixel_storage_mode": pixel_storage_mode,
                "is_swizzled": is_swizzled,
            },
        )
        self.textures[texture_hash] = texture
        self.name_hashes[name.upper()] = texture_hash


def entry_name(entry: bytes) -> str:
    end = 0x08
    while end < min(0x20, len(entry)) and entry[end] != 0:
        end += 1
    return entry[0x08:end].decode("ascii", "ignore").strip()


def decode_rgba_texture(width: int, height: int, image: bytes) -> bytearray:
    if len(image) < width * height * 4:
        return bytearray()
    rgba = bytearray()
    for y in range(height - 1, -1, -1):
        row = y * width * 4
        for x in range(width):
            offset = row + x * 4
            rgba.extend((image[offset], image[offset + 1], image[offset + 2], decode_ps2_alpha(image[offset + 3])))
    return rgba


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
) -> bytearray:
    depth = indexed_bit_depth(bit_depth, pixel_storage_mode, len(palette))
    if depth not in (4, 8):
        return bytearray()
    color_count = len(palette) // 4
    if color_count <= 0:
        return bytearray()
    colors = decode_palette(palette, psm_type_index(pixel_storage_mode) == 3)
    buffer_width = 1 << shift_width
    buffer_height = 1 << shift_height
    if width <= 0 or height <= 0 or buffer_width <= 0 or buffer_height <= 0:
        return bytearray()
    words = u32_words(image)
    if is_swizzled:
        scale = 32 // depth
        scale_mask = scale - 1
        scale_x = (adjust_with_mask(scale_mask, 1, 2, 1) | adjust_with_mask(scale_mask, 1, 0, 0)) + 1
        scale_y = (adjust_with_mask(scale_mask, 1, 3, 1) | adjust_with_mask(scale_mask, 1, 1, 0)) + 1
        words = legacy_ps2_rw_buffer(words, "write", 0, 32, width // scale_y, height // scale_x)
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
    for index in final_indices[: width * height]:
        rgba.extend(colors[index % color_count])
    return rgba


def indexed_bit_depth(bit_depth: int, pixel_storage_mode: int, palette_size: int) -> int:
    psm_index = psm_type_index(pixel_storage_mode)
    if psm_index > 0:
        return 32 >> max(psm_index - 1, 0)
    if bit_depth in (4, 8):
        return bit_depth
    if palette_size == 0x40:
        return 4
    if palette_size in (0x80, 0x400):
        return 8
    return 0


def psm_type_index(pixel_storage_mode: int) -> int:
    return pixel_storage_mode & 0x07


def u32_words(data: bytes) -> list[int]:
    return [u32(data, offset) for offset in range(0, len(data), 4)]


def legacy_ps2_rw_buffer(image_data: list[int], mode: str, pixel_storage_mode: int, bit_depth: int, width: int, height: int) -> list[int]:
    scale = 32 // bit_depth
    scale_mask = scale - 1
    scale_x = (adjust_with_mask(scale_mask, 1, 2, 1) | adjust_with_mask(scale_mask, 1, 0, 0)) + 1
    scale_y = (adjust_with_mask(scale_mask, 1, 3, 1) | adjust_with_mask(scale_mask, 1, 1, 0)) + 1
    physical_width = width // scale_y
    physical_height = height // scale_x
    physical_buffer_width = align_power_of_two_max(physical_width)
    physical_buffer_height = align_power_of_two_max(physical_height)
    buffer_width = align_power_of_two_max(width)
    buffer_height = align_power_of_two_max(height)
    out = [0] * (physical_buffer_width * physical_buffer_height)
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
    texture_buffer_width = width // (page_width * column_width)
    if texture_buffer_width <= 0:
        texture_buffer_width = 1
    input_address = 0
    from_offset_w = 0
    for index in range(buffer_width * buffer_height):
        y = index // buffer_width
        x = index - y * buffer_width
        page_x = x // (page_width * column_width)
        page_y = y // (page_height * 4 * column_height)
        page = page_x + page_y * texture_buffer_width
        px = x - page_x * (page_width * column_width)
        py = y - page_y * (page_height * 4 * column_height)
        block_x = px // column_width
        block_y = py // (4 * column_height)
        block = legacy_ps2_block_address(block_x + block_y * page_width, swap_xy, z_buffer, shifted)
        bx = px - block_x * column_width
        by = py - block_y * (4 * column_height)
        column_y = by // column_height
        column = column_y
        cx = bx
        cy = by - column_y * column_height
        pixel = legacy_ps2_swizzle(cx + cy * column_width, bit_depth, True)
        word = pixel // scale
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
        if 0 <= address_a < len(out):
            out[address_a] |= pixel_data
        from_offset_w += 1
        if from_offset_w > 0 and (from_offset_w & scale_mask) == 0:
            input_address += 1
        from_offset_w &= scale_mask
    return out


def adjust_with_mask(src: int, mask_width: int, mask_position: int = 0, adjustment: int = 0) -> int:
    return ((src >> mask_position) & ((1 << mask_width) - 1)) << adjustment


def rotate_bits(value: int, shift: int, width: int) -> int:
    shift %= width
    mask = (1 << width) - 1
    value &= mask
    return ((value << shift) | (value >> (width - shift))) & mask


def align_power_of_two_max(value: int) -> int:
    out = 1
    while out < value:
        out <<= 1
    return out


def legacy_ps2_swizzle(pixel_index: int, bit_depth: int, mode_flag: bool) -> int:
    if bit_depth == 4:
        return legacy_ps2_swizzle_psmt4(pixel_index, mode_flag)
    if bit_depth == 8:
        return legacy_ps2_swizzle_psmt8(pixel_index, mode_flag)
    if bit_depth == 16:
        return legacy_ps2_swizzle_psmt16(pixel_index, mode_flag)
    return legacy_ps2_swizzle_psmt32(pixel_index, mode_flag)


def legacy_ps2_swizzle_psmt4(pixel_index: int, mode_flag: bool) -> int:
    ax, ay, bx, by = (pixel_index >> 0) & 1, (pixel_index >> 1) & 1, (pixel_index >> 2) & 1, (pixel_index >> 3) & 1
    cx, cy, dx = (pixel_index >> 4) & 1, (pixel_index >> 5) & 1, (pixel_index >> 6) & 1
    result = 0
    result ^= dx << 0
    result ^= by << 1
    result ^= cx << 2
    result ^= ax << 3
    result ^= ay << 4
    result ^= bx << 5
    result ^= ax << 7
    result ^= cy << (3 + 3 * int(mode_flag))
    result >>= 0 if mode_flag else 1
    result ^= dx << 5
    return result & 0x7F


def legacy_ps2_swizzle_psmt8(pixel_index: int, mode_flag: bool) -> int:
    ax, ay, bx, by = (pixel_index >> 0) & 1, (pixel_index >> 1) & 1, (pixel_index >> 2) & 1, (pixel_index >> 3) & 1
    cx, cy = (pixel_index >> 4) & 1, (pixel_index >> 5) & 1
    result = 0
    result ^= ax << 0
    result ^= cy << 1
    result = rotate_bits(result, 5 + int(mode_flag), 7)
    result ^= bx << (0 + 4 * int(mode_flag))
    result ^= cx << (2 + 3 * int(mode_flag))
    result ^= by << 1
    result ^= ax << 2
    result ^= ay << 3
    result ^= cy << 4
    return result & 0x3F


def legacy_ps2_swizzle_psmt16(pixel_index: int, mode_flag: bool) -> int:
    ax, ay, bx, by = (pixel_index >> 0) & 1, (pixel_index >> 1) & 1, (pixel_index >> 2) & 1, (pixel_index >> 3) & 1
    cx = (pixel_index >> 4) & 1
    result = 0
    result ^= ay << 0
    result ^= bx << 1
    result ^= by << 2
    result ^= ax << 3
    result = rotate_bits(result, 2 * int(mode_flag), 4)
    result ^= cx << 4
    return result & 0x1F


def legacy_ps2_swizzle_psmt32(pixel_index: int, mode_flag: bool) -> int:
    ax, ay, bx, by = (pixel_index >> 0) & 1, (pixel_index >> 1) & 1, (pixel_index >> 2) & 1, (pixel_index >> 3) & 1
    result = 0
    result ^= ay << 0
    result ^= bx << 1
    result ^= by << 2
    result = rotate_bits(result, 2 + int(mode_flag), 3)
    result = (result << 1) ^ ax
    return result & 0x0F


def legacy_ps2_block_address(block_index: int, swap_xy: bool, flip_xy: bool, shifted: bool) -> int:
    swap = int(swap_xy)
    swap = (swap << 0) ^ (swap << 1)
    block_index = rotate_bits(block_index, swap, 5)
    ax, ay = (block_index >> 0) & 1, (block_index >> 3) & 1
    bx, by = (block_index >> 1) & 1, (block_index >> 4) & 1
    cx = (block_index >> 2) & 1
    result = 0
    result ^= bx << 0
    result ^= by << 1
    result ^= cx << 2
    result = rotate_bits(result, int(shifted), 3)
    result ^= (0x03 * int(flip_xy)) << 1
    result = (result << 2) ^ (ax << 0) ^ (ay << 1)
    return result & 0x1F


def decode_palette(palette: bytes, swizzle: bool) -> list[tuple[int, int, int, int]]:
    colors = []
    for index in range(len(palette) // 4):
        source_index = unswizzle_palette_index(index) if swizzle else index
        off = source_index * 4
        colors.append((palette[off], palette[off + 1], palette[off + 2], decode_ps2_alpha(palette[off + 3])))
    return colors


def decode_ps2_alpha(value: int) -> int:
    expanded = max((value << 1) - ((value ^ 1) & 1), 0)
    return expanded if expanded <= 0xFF else value


def unswizzle_palette_index(index: int) -> int:
    block = index & ~0x1F
    pos = index & 0x1F
    if 8 <= pos < 16:
        pos += 8
    elif 16 <= pos < 24:
        pos -= 8
    return block + pos


def write_png(path: Path, width: int, height: int, rgba: bytearray | bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    raw = bytearray()
    stride = width * 4
    for y in range(height):
        raw.append(0)
        raw.extend(rgba[y * stride : y * stride + stride])
    def chunk(kind: bytes, payload_bytes: bytes) -> bytes:
        crc = zlib.crc32(kind + payload_bytes) & 0xFFFFFFFF
        return struct.pack(">I", len(payload_bytes)) + kind + payload_bytes + struct.pack(">I", crc)
    png = bytearray(b"\x89PNG\r\n\x1a\n")
    png.extend(chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)))
    png.extend(chunk(b"IDAT", zlib.compress(bytes(raw), 9)))
    png.extend(chunk(b"IEND", b""))
    path.write_bytes(png)


@dataclass
class Block:
    object_name: str
    block_index: int
    texture_index: int
    source_hash: int
    strip_entry: dict[str, int | bytes]
    run: dict[str, Any]


def parse_car_geometry(path: Path) -> list[dict[str, Any]]:
    data = load_bundle_bytes(path)
    chunks = parse_chunks(data)
    objects: list[dict[str, Any]] = []
    for chunk in walk_chunks(chunks):
        if chunk.id != 0x80034000:
            continue
        for child in chunk.children:
            if child.id != 0x80034002:
                continue
            obj = parse_mesh_object(child, data)
            if obj:
                objects.append(obj)
    return objects


def parse_mesh_object(object_chunk: Chunk, data: bytes) -> dict[str, Any] | None:
    header_chunk = child_with_id(object_chunk, 0x00034003)
    run_metadata_chunk = child_with_id(object_chunk, 0x00034004)
    vif_data_chunk = child_with_id(object_chunk, 0x00034005)
    texture_refs_chunk = child_with_id(object_chunk, 0x00034006)
    if header_chunk is None or vif_data_chunk is None:
        return None
    header = payload(data, header_chunk)
    name_info = find_ascii_name(header)
    if not name_info:
        return None
    vif_payload = strip_vif_prefix(payload(data, vif_data_chunk))
    metadata_payload = payload(data, run_metadata_chunk) if run_metadata_chunk is not None else b""
    blocks = extract_blocks_from_strip_entries(vif_payload, metadata_payload, name_info["name"])
    texture_hashes = read_texture_hashes(payload(data, texture_refs_chunk)) if texture_refs_chunk is not None else []
    return {"name": name_info["name"], "blocks": blocks, "texture_hashes": texture_hashes}


def find_ascii_name(data: bytes) -> dict[str, Any] | None:
    limit = min(0x34, len(data) - 4)
    for start in range(0x10, limit, 4):
        end = start
        while end < len(data):
            byte = data[end]
            if byte == 0 or byte < 0x20 or byte > 0x7E:
                break
            end += 1
        if end - start >= 4 and end < len(data) and data[end] == 0:
            return {"name": data[start:end].decode("ascii", "ignore"), "start": start}
    return None


def read_texture_hashes(data: bytes) -> list[int]:
    hashes = []
    for offset in range(0, len(data) - 3, 8):
        value = u32(data, offset)
        if value:
            hashes.append(value)
    return hashes


def strip_vif_prefix(data: bytes) -> bytes:
    if len(data) >= 8 and all(byte == 0x11 for byte in data[:8]):
        return data[8:]
    return data


def extract_blocks_from_strip_entries(vif_payload: bytes, metadata_payload: bytes, object_name: str) -> list[dict[str, Any]]:
    clean_metadata = strip_vif_prefix(metadata_payload)
    record_count = len(clean_metadata) // 0x40
    if record_count <= 0:
        return []
    blocks = []
    for record_index in range(record_count):
        record = clean_metadata[record_index * 0x40 : record_index * 0x40 + 0x40]
        strip_entry = parse_strip_entry_record(record)
        vif_offset = strip_entry["vif_offset"]
        qword_size = strip_entry["qword_size"]
        if qword_size <= 0 or vif_offset < 0 or vif_offset + qword_size > len(vif_payload):
            return []
        vif_slice = vif_payload[vif_offset : vif_offset + qword_size]
        decoded = extract_vif_vertex_runs(vif_slice)
        if len(decoded) != 1:
            return []
        texture_index_raw = strip_entry["texture_index_raw"]
        blocks.append(
            {
                "run": decoded[0],
                "primitive_mode": "strip",
                "texture_index": texture_index_raw if texture_index_raw != 0xFFFFFFFF else -1,
                "strip_entry": strip_entry,
                "vif_payload": vif_slice,
                "object_name": object_name,
                "block_index": record_index,
            }
        )
    return blocks


def parse_strip_entry_record(record: bytes) -> dict[str, int | bytes]:
    texture_index_raw = u32(record, 0)
    qword_word = u32(record, 0x0C)
    word_1c = u32(record, 0x1C)
    qword_count = qword_word & 0xFFFF
    return {
        "raw": record,
        "texture_index_raw": texture_index_raw,
        "texture_width_u16": u16(record, 0x04),
        "texture_height_u16": u16(record, 0x06),
        "vif_offset": u32(record, 0x08),
        "qword_count": qword_count,
        "qword_size": qword_count * 16,
        "render_flags": (qword_word >> 16) & 0xFFFF,
        "word_1c": word_1c,
    }


def extract_vif_vertex_runs(data: bytes) -> list[dict[str, Any]]:
    data = strip_vif_prefix(data)
    runs: list[dict[str, Any]] = []
    rows: list[list[float]] = []
    texcoords: list[tuple[float, float]] = []
    packed_values: list[int] = []
    current_header: list[int] = []
    current_tri_cull: list[int] = []
    pos = 0
    while pos + 4 <= len(data):
        imm = u16(data, pos)
        count = u8(data, pos + 2)
        command = u8(data, pos + 3)
        pos += 4
        size = vif_command_payload_size(command, count, imm)
        if size < 0:
            if command == 0x14 or command != 0x00:
                flush_rows(runs, rows, texcoords, packed_values, current_header, current_tri_cull)
                current_header = []
                current_tri_cull = []
            continue
        if pos + size > len(data):
            break
        if not is_unpack_command(command):
            if command == 0x14:
                flush_rows(runs, rows, texcoords, packed_values, current_header, current_tri_cull)
                current_header = []
                current_tri_cull = []
            pos += size
            continue
        base = base_unpack_command(command)
        if base == 0x6E and imm == 0x8000 and count == 1 and size >= 4:
            flush_rows(runs, rows, texcoords, packed_values, current_header, current_tri_cull)
            current_header = [data[pos], data[pos + 1], data[pos + 2], data[pos + 3]]
            current_tri_cull = []
        elif base == 0x6C and imm == 0xC001 and count == 1 and size >= 16:
            current_tri_cull = [u32(data, pos), u32(data, pos + 4), u32(data, pos + 8), u32(data, pos + 12)]
        elif 0xC002 <= imm < 0xC020 and has_position_layout(base):
            rows.extend(decode_position_values(command, count, data, pos))
        elif 0xC020 <= imm < 0xC034 and base in (0x60, 0x64, 0x68, 0x6C):
            append_texcoord_pairs(texcoords, command, count, data, pos)
        elif 0xC034 <= imm < 0xC040 and base == 0x6F:
            for i in range(count):
                packed_values.append(u16(data, pos + i * 2))
        pos += size
    flush_rows(runs, rows, texcoords, packed_values, current_header, current_tri_cull)
    return runs


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
        x_row, y_row, z_row = rows[row_index], rows[row_index + 1], rows[row_index + 2]
        width = min(len(x_row), len(y_row), len(z_row))
        for lane in range(width):
            vertices.append((x_row[lane], y_row[lane], z_row[lane]))
        row_index += 3
    rows.clear()
    if not vertices:
        texcoords.clear()
        packed_values.clear()
        return
    if header and 0 < header[0] < len(vertices):
        vertices = vertices[: header[0]]
    runs.append(
        {
            "vertices": vertices,
            "texcoords": texcoords[: len(vertices)],
            "packed_values": packed_values[: len(vertices)],
            "header": list(header),
            "tri_cull": list(tri_cull),
        }
    )
    texcoords.clear()
    packed_values.clear()


def decode_position_values(command: int, count: int, data: bytes, offset: int) -> list[list[float]]:
    base = base_unpack_command(command)
    layout = position_layout(base)
    if layout is None:
        return []
    component_count, kind = layout
    total = count * component_count
    values: list[float] = []
    if kind == "f32":
        values = [f32(data, offset + i * 4) for i in range(total)]
    elif kind == "s16":
        values = [float(s16(data, offset + i * 2)) * POSITION_S16_SCALE for i in range(total)]
    else:
        values = [float(s8(data, offset + i)) * POSITION_S8_SCALE for i in range(total)]
    return [values[row : row + component_count] for row in range(0, len(values), component_count)]


def append_texcoord_pairs(texcoords: list[tuple[float, float]], command: int, count: int, data: bytes, offset: int) -> None:
    base = base_unpack_command(command)
    if base == 0x6C:
        for row_offset in range(count):
            base_offset = offset + row_offset * 16
            row = [f32(data, base_offset), f32(data, base_offset + 4), f32(data, base_offset + 8), f32(data, base_offset + 12)]
            texcoords.append((row[0], row[1]))
            texcoords.append((row[3], row[2]))
    elif base == 0x64:
        for pair_offset in range(count):
            base_offset = offset + pair_offset * 8
            texcoords.append((f32(data, base_offset), f32(data, base_offset + 4)))
    elif base == 0x68:
        for row_offset in range(count):
            base_offset = offset + row_offset * 12
            texcoords.append((f32(data, base_offset), f32(data, base_offset + 4)))
    elif base == 0x60:
        values = [f32(data, offset + i * 4) for i in range(count)]
        for pair_offset in range(0, len(values) - 1, 2):
            texcoords.append((values[pair_offset], values[pair_offset + 1]))


def extract_vif_uv_events(data: bytes) -> list[dict[str, Any]]:
    data = strip_vif_prefix(data)
    events = []
    pos = 0
    while pos + 4 <= len(data):
        command_offset = pos
        imm = u16(data, pos)
        count = u8(data, pos + 2)
        command = u8(data, pos + 3)
        pos += 4
        size = vif_command_payload_size(command, count, imm)
        if size < 0:
            continue
        if pos + size > len(data):
            break
        base = base_unpack_command(command)
        if is_unpack_command(command) and 0xC020 <= imm < 0xC034 and base in (0x60, 0x64, 0x68, 0x6C):
            pairs: list[tuple[float, float]] = []
            append_texcoord_pairs(pairs, command, count, data, pos)
            events.append(
                {
                    "command_offset": command_offset,
                    "payload_offset": pos,
                    "imm": f"0x{imm:04x}",
                    "command": f"0x{command:02x}",
                    "base_command": f"0x{base:02x}",
                    "format": unpack_format_name(command),
                    "count": count,
                    "payload_size": size,
                    "decoded_pairs": [[round(u, 8), round(v, 8)] for u, v in pairs],
                }
            )
        pos += size
    return events


def vif_command_payload_size(command: int, count: int, imm: int) -> int:
    unpack_size = unpack_data_size(command, count)
    if unpack_size >= 0:
        return unpack_size
    if command in (0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x10, 0x11, 0x13, 0x14, 0x15, 0x17):
        return 0
    if command == 0x20:
        return 4
    if command in (0x30, 0x31):
        return 16
    if command == 0x4A:
        return (count if count > 0 else 0x100) * 8
    if command in (0x50, 0x51):
        return (imm if imm > 0 else 0x10000) * 16
    return -1


def unpack_data_size(command: int, count: int) -> int:
    if not is_unpack_command(command) or unpack_format_name(command) == "":
        return -1
    vn = (command >> 2) & 0x03
    vl = command & 0x03
    return align(((0x08 >> vl) * (vn + 1) * count) >> 1, 4)


def unpack_format_name(command: int) -> str:
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
    }.get(command & 0x0F, "")


def position_layout(base_command: int) -> tuple[int, str] | None:
    return {
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
    }.get(base_command)


def has_position_layout(base_command: int) -> bool:
    return position_layout(base_command) is not None


def base_unpack_command(command: int) -> int:
    return command & 0xEF


def is_unpack_command(command: int) -> bool:
    return 0x60 <= command <= 0x7F


def texture_hash_for_block(texture_hashes: list[int], block: dict[str, Any]) -> int:
    index = int(block.get("texture_index", -1))
    if 0 <= index < len(texture_hashes):
        return texture_hashes[index]
    return 0


def resolved_uvs(block: dict[str, Any], texture: Texture | None) -> list[tuple[float, float]]:
    run = block["run"]
    texcoords = run.get("texcoords", [])
    vertex_count = len(run.get("vertices", []))
    scale_u, scale_v = strip_texture_dimension_uv_scale(block, texture)
    out = []
    for u, v in texcoords[:vertex_count]:
        out.append((u * scale_u, 1.0 - (v * scale_v)))
    return out


def strip_texture_dimension_uv_scale(block: dict[str, Any], texture: Texture | None) -> tuple[float, float]:
    if texture is None:
        return (1.0, 1.0)
    entry = block.get("strip_entry", {})
    stored_w = int(entry.get("texture_width_u16", 0))
    stored_h = int(entry.get("texture_height_u16", 0))
    if stored_w <= 0 or stored_h <= 0:
        return (1.0, 1.0)
    actual_w_norm = normalized_texture_extent(texture.width)
    actual_h_norm = normalized_texture_extent(texture.height)
    stored_w_norm = stored_w / 32768.0
    stored_h_norm = stored_h / 32768.0
    if stored_w_norm <= 0.0 or stored_h_norm <= 0.0:
        return (1.0, 1.0)
    return (actual_w_norm / stored_w_norm, actual_h_norm / stored_h_norm)


def normalized_texture_extent(value: int) -> float:
    if value <= 0:
        return 1.0
    power = 1
    while power * 2 <= value:
        power *= 2
    return float(value) / float(power)


def indices_for_block(block: dict[str, Any]) -> list[int]:
    vertex_count = len(block["run"].get("vertices", []))
    return strip_indices(block, vertex_count)


def strip_indices(block: dict[str, Any], vertex_count: int) -> list[int]:
    disabled = adc_disabled_from_vif_control(block["run"].get("header", []), block["run"].get("tri_cull", []), vertex_count)
    if not disabled:
        disabled = [False] * vertex_count
    out: list[int] = []
    face = 1
    for index in range(vertex_count):
        if disabled[index]:
            face = 1
            continue
        a = index - 1 - face
        b = index - 1
        c = index - 1 + face
        if 0 <= a < vertex_count and 0 <= b < vertex_count and 0 <= c < vertex_count and len({a, b, c}) == 3:
            out.extend((a, b, c))
        face = -face
    return out


def adc_disabled_from_vif_control(header: list[int], tri_cull: list[int], vertex_count: int) -> list[bool]:
    if len(header) < 2 or len(tri_cull) < 4 or vertex_count <= 0:
        return []
    num_vertices = int(header[0])
    mode = int(header[1])
    if num_vertices <= 0 or num_vertices > vertex_count or num_vertices > 32 or mode > 7:
        return []
    mask = vif_control_mask(num_vertices, mode, tri_cull)
    return [((mask >> (31 - index)) & 1) != 0 for index in range(vertex_count)]


def strip_mask_report(block: dict[str, Any]) -> dict[str, Any]:
    run = block.get("run", {})
    header = run.get("header", [])
    tri_cull = run.get("tri_cull", [])
    vertex_count = len(run.get("vertices", []))
    if len(header) < 2 or len(tri_cull) < 4 or vertex_count <= 0:
        return {
            "available": False,
            "mask_hex": None,
            "disabled_vertex_indices": [],
            "enabled_vertex_indices": list(range(vertex_count)),
        }
    num_vertices = int(header[0])
    mode = int(header[1])
    if num_vertices <= 0 or num_vertices > vertex_count or num_vertices > 32 or mode > 7:
        return {
            "available": False,
            "num_vertices": num_vertices,
            "mode": mode,
            "mask_hex": None,
            "disabled_vertex_indices": [],
            "enabled_vertex_indices": list(range(vertex_count)),
        }
    mask = vif_control_mask(num_vertices, mode, tri_cull)
    disabled = [index for index in range(vertex_count) if ((mask >> (31 - index)) & 1) != 0]
    disabled_set = set(disabled)
    enabled = [index for index in range(vertex_count) if index not in disabled_set]
    return {
        "available": True,
        "num_vertices": num_vertices,
        "mode": mode,
        "mask_hex": f"0x{mask:08x}",
        "mask_bits_for_vertices": "".join("1" if ((mask >> (31 - index)) & 1) else "0" for index in range(vertex_count)),
        "disabled_vertex_indices": disabled,
        "enabled_vertex_indices": enabled,
        "modelulator_rule": "mask bit 1 skips this strip vertex and resets winding; mask bit 0 emits a triangle candidate.",
    }


def shift_left(value: int, shift: int) -> int:
    return value << shift if shift >= 0 else value >> -shift


def vif_control_mask(num_vertices: int, mode: int, tri_cull: list[int]) -> int:
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
    mask = shift_left(new_downer, ((mode - 3) << 2) - 3)
    if use_upper:
        mask = (mask & ((0xFFFFFFFF << 13) & 0xFFFFFFFF)) | (new_upper & 0x3FFF)
    mask = shift_left(mask, (7 - mode) << 2)
    mask &= (0xFFFFFFFF << (32 - num_vertices)) & 0xFFFFFFFF
    return mask & 0xFFFFFFFF


def draw_overlay(base: Texture, draw_blocks: list[dict[str, Any]], scale: int) -> bytearray:
    width = base.width * scale
    height = base.height * scale
    rgba = scale_image_nearest(base.rgba, base.width, base.height, scale)
    for index, block_info in enumerate(draw_blocks):
        color = OVERLAY_COLORS[index % len(OVERLAY_COLORS)]
        uvs = block_info["uvs"]
        indices = block_info["indices"]
        for i in range(0, len(indices) - 2, 3):
            a = uv_to_pixel(uvs[indices[i]], width, height)
            b = uv_to_pixel(uvs[indices[i + 1]], width, height)
            c = uv_to_pixel(uvs[indices[i + 2]], width, height)
            draw_line(rgba, width, height, a, b, color)
            draw_line(rgba, width, height, b, c, color)
            draw_line(rgba, width, height, c, a, color)
    return rgba


def scale_image_nearest(rgba: bytearray, width: int, height: int, scale: int) -> bytearray:
    if scale <= 1:
        return bytearray(rgba)
    out = bytearray(width * scale * height * scale * 4)
    for y in range(height * scale):
        src_y = y // scale
        for x in range(width * scale):
            src_x = x // scale
            src = (src_y * width + src_x) * 4
            dst = (y * width * scale + x) * 4
            out[dst : dst + 4] = rgba[src : src + 4]
    return out


def uv_to_pixel(uv: tuple[float, float], width: int, height: int) -> tuple[int, int]:
    u = uv[0] - math.floor(uv[0])
    v = uv[1] - math.floor(uv[1])
    return (max(0, min(width - 1, round(u * (width - 1)))), max(0, min(height - 1, round(v * (height - 1)))))


def draw_line(
    rgba: bytearray,
    width: int,
    height: int,
    a: tuple[int, int],
    b: tuple[int, int],
    color: tuple[int, int, int, int],
) -> None:
    x, y = a
    dx = abs(b[0] - x)
    dy = -abs(b[1] - y)
    sx = 1 if x < b[0] else -1
    sy = 1 if y < b[1] else -1
    err = dx + dy
    while True:
        blend_pixel(rgba, width, height, x, y, color)
        blend_pixel(rgba, width, height, x + 1, y, color)
        blend_pixel(rgba, width, height, x, y + 1, color)
        if x == b[0] and y == b[1]:
            break
        e2 = 2 * err
        if e2 >= dy:
            err += dy
            x += sx
        if e2 <= dx:
            err += dx
            y += sy


def blend_pixel(rgba: bytearray, width: int, height: int, x: int, y: int, color: tuple[int, int, int, int]) -> None:
    if x < 0 or y < 0 or x >= width or y >= height:
        return
    offset = (y * width + x) * 4
    alpha = 0.82
    for channel in range(4):
        rgba[offset + channel] = int(rgba[offset + channel] * (1.0 - alpha) + color[channel] * alpha)


def write_wheel_binary_dump(car_out_dir: Path, car_id: str, wheel_blocks: list[dict[str, Any]], bank: TextureBank) -> Path:
    dump_dir = car_out_dir / "binary_dump"
    dump_dir.mkdir(parents=True, exist_ok=True)
    blocks = []
    for entry in wheel_blocks:
        block = entry["block"]
        strip = block.get("strip_entry", {})
        run = block.get("run", {})
        source_hash = int(entry.get("source_hash", 0))
        texture = bank.get(source_hash)
        strip_raw = strip.get("raw", b"")
        vif_payload = block.get("vif_payload", b"")
        label = f"{safe_name(entry['object_name'])}_block_{int(entry['block_index']):03d}_{source_hash:08x}"
        strip_path = dump_dir / f"{label}_strip_record.bin"
        vif_path = dump_dir / f"{label}_vif_payload.bin"
        if isinstance(strip_raw, (bytes, bytearray)):
            strip_path.write_bytes(strip_raw)
        if isinstance(vif_payload, (bytes, bytearray)):
            vif_path.write_bytes(vif_payload)
        raw_uvs = run.get("texcoords", [])
        final_uvs = resolved_uvs(block, texture) if texture is not None else []
        validation = wheel_block_validation(block, texture)
        blocks.append(
            {
                "object_name": entry["object_name"],
                "block_index": entry["block_index"],
                "source_hash": f"{source_hash:08x}",
                "material_label": material_label(source_hash),
                "texture": texture.info if texture is not None else None,
                "strip_record_bin": str(strip_path),
                "vif_payload_bin": str(vif_path),
                "strip_record": {
                    "raw_hex": bytes(strip_raw).hex() if isinstance(strip_raw, (bytes, bytearray)) else "",
                    "texture_index_raw": int(strip.get("texture_index_raw", 0)),
                    "texture_width_u16": int(strip.get("texture_width_u16", 0)),
                    "texture_height_u16": int(strip.get("texture_height_u16", 0)),
                    "vif_offset": int(strip.get("vif_offset", 0)),
                    "qword_count": int(strip.get("qword_count", 0)),
                    "qword_size": int(strip.get("qword_size", 0)),
                    "render_flags": f"0x{int(strip.get('render_flags', 0)):04x}",
                    "word_1c": f"0x{int(strip.get('word_1c', 0)):08x}",
                },
                "mesh_counts": {
                    "vertices": len(run.get("vertices", [])),
                    "raw_uvs": len(raw_uvs),
                    "packed_values": len(run.get("packed_values", [])),
                    "triangles": len(indices_for_block(block)) // 3,
                },
                "header": run.get("header", []),
                "tri_cull": [f"0x{value:08x}" for value in run.get("tri_cull", [])],
                "strip_mask": strip_mask_report(block),
                "vif_uv_events": extract_vif_uv_events(vif_payload if isinstance(vif_payload, (bytes, bytearray)) else b""),
                "raw_uv_sample": [[round(u, 8), round(v, 8)] for u, v in raw_uvs[:16]],
                "final_uv_sample": [[round(u, 8), round(v, 8)] for u, v in final_uvs[:16]],
                "validation": validation,
            }
        )
    dump = {
        "car": car_id,
        "ghidra_runtime_basis": {
            "FUN_0010c158": "Iterates 0x40-byte strip records, resolves texture through material table, compares strip +0x04/+0x06 normalized extents against actual texture width/height, rescales UVs only when they differ.",
            "FUN_0011c268": "Reads U/V floats from the geometry UV buffer using the pointer math in FUN_0011c090.",
            "FUN_0011c398": "Writes scaled U/V floats back through the same UV pointer path.",
        },
        "modelulator_basis": {
            "source": "/Users/nurupo/Desktop/dev/modelulator.v5.1.5.pub/src/util/xSolid/PSX2.lua",
            "lines": "569-617",
            "meaning": "Derives a 32-bit strip mask from heading + tri_cull, skips vertices whose mask bit is 1, and resets triangle-strip winding on skipped vertices.",
        },
        "validation_summary": summarize_validation(blocks),
        "blocks": blocks,
    }
    dump_path = car_out_dir / "wheel_uv_binary_dump.json"
    dump_path.write_text(json.dumps(dump, indent=2), encoding="utf-8")
    return dump_path


def wheel_block_validation(block: dict[str, Any], texture: Texture | None) -> dict[str, Any]:
    strip = block.get("strip_entry", {})
    run = block.get("run", {})
    vertices = run.get("vertices", [])
    raw_uvs = run.get("texcoords", [])
    scale_u, scale_v = strip_texture_dimension_uv_scale(block, texture)
    stored_w = int(strip.get("texture_width_u16", 0))
    stored_h = int(strip.get("texture_height_u16", 0))
    actual_w_u16 = 0
    actual_h_u16 = 0
    if texture is not None:
        actual_w_u16 = round(normalized_texture_extent(texture.width) * 32768.0)
        actual_h_u16 = round(normalized_texture_extent(texture.height) * 32768.0)
    return {
        "uv_count_matches_vertices": len(raw_uvs) >= len(vertices) and len(vertices) > 0,
        "strip_dimensions_match_texture": texture is not None and stored_w == actual_w_u16 and stored_h == actual_h_u16,
        "runtime_uv_scale": [round(scale_u, 8), round(scale_v, 8)],
        "runtime_rescale_needed": texture is not None and (abs(scale_u - 1.0) > 0.000001 or abs(scale_v - 1.0) > 0.000001),
        "stored_texture_extent_u16": [stored_w, stored_h],
        "actual_texture_extent_u16": [actual_w_u16, actual_h_u16] if texture is not None else None,
        "resolved_texture_present": texture is not None,
    }


def summarize_validation(blocks: list[dict[str, Any]]) -> dict[str, Any]:
    resolved = [block for block in blocks if block["validation"]["resolved_texture_present"]]
    missing = [block for block in blocks if not block["validation"]["resolved_texture_present"]]
    return {
        "total_blocks": len(blocks),
        "resolved_texture_blocks": len(resolved),
        "material_id_or_missing_texture_blocks": len(missing),
        "uv_count_mismatches": sum(1 for block in blocks if not block["validation"]["uv_count_matches_vertices"]),
        "resolved_blocks_needing_runtime_rescale": sum(1 for block in resolved if block["validation"]["runtime_rescale_needed"]),
        "resolved_blocks_with_strip_dimension_mismatch": sum(
            1 for block in resolved if not block["validation"]["strip_dimensions_match_texture"]
        ),
    }


def collect_wheel_blocks(objects: list[dict[str, Any]], object_filter: str) -> list[dict[str, Any]]:
    collected = []
    object_filter_upper = object_filter.upper()
    for obj in objects:
        object_name = obj["name"]
        if object_filter_upper and object_filter_upper not in object_name.upper():
            continue
        hashes = obj.get("texture_hashes", [])
        for block_index, block in enumerate(obj.get("blocks", [])):
            source_hash = texture_hash_for_block(hashes, block)
            collected.append(
                {
                    "object_name": object_name,
                    "block_index": block_index,
                    "source_hash": source_hash,
                    "block": block,
                }
            )
    return collected


def main() -> int:
    parser = argparse.ArgumentParser(description="Extract HP2 PS2 car textures and render wheel UV overlays.")
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT, help="ZZDATA root")
    parser.add_argument("--car", default="CORVETTE", help="Car folder name under ZZDATA/CARS")
    parser.add_argument("--geometry", type=Path, default=None, help="Override GEOMETRY.BIN path")
    parser.add_argument("--textures", type=Path, default=None, help="Override TEXTURES.BIN path")
    parser.add_argument("--global-textures", type=Path, default=None, help="Override GLOBALB.BUN path for shared textures")
    parser.add_argument("--no-global-textures", action="store_true", help="Do not use GLOBAL/GLOBALB.BUN as a fallback texture source")
    parser.add_argument("--out", type=Path, default=Path("out"), help="Output directory")
    parser.add_argument("--object-filter", default="_TIRE_", help="Only process objects containing this text")
    parser.add_argument("--scale", type=int, default=6, help="Overlay output scale")
    parser.add_argument("--missing-target", choices=["none", "tire"], default="tire", help="Diagnostic target for missing material-id UVs")
    parser.add_argument("--dump-binary", action="store_true", help="Write raw wheel strip/VIF dumps and decoded UV validation JSON")
    args = parser.parse_args()

    car_id = args.car.upper()
    geometry_path = args.geometry or args.root / "CARS" / car_id / "GEOMETRY.BIN"
    texture_path = args.textures or args.root / "CARS" / "TEXTURES.BIN"
    global_texture_path = args.global_textures or args.root / "GLOBAL" / "GLOBALB.BUN"
    out_dir = args.out
    texture_dir = out_dir / car_id / "textures"
    overlay_dir = out_dir / car_id / "overlays"
    texture_dir.mkdir(parents=True, exist_ok=True)
    overlay_dir.mkdir(parents=True, exist_ok=True)

    objects = parse_car_geometry(geometry_path)
    wheel_blocks = collect_wheel_blocks(objects, args.object_filter)
    required_hashes = {entry["source_hash"] for entry in wheel_blocks if entry["source_hash"]}
    bank = TextureBank()
    bank.load(texture_path, wanted_hashes=required_hashes)
    if not args.no_global_textures and global_texture_path.exists():
        missing_hashes = {texture_hash for texture_hash in required_hashes if not bank.has(texture_hash)}
        if missing_hashes:
            bank.load(global_texture_path, wanted_hashes=missing_hashes)

    for texture in bank.textures.values():
        write_png(texture_dir / f"{texture.hash:08x}_{safe_name(texture.name)}.png", texture.width, texture.height, texture.rgba)

    resolved_groups: dict[int, list[dict[str, Any]]] = {}
    missing_groups: dict[int, list[dict[str, Any]]] = {}
    tire_texture_hash = next(
        (texture.hash for texture in bank.textures.values() if texture.name.upper().endswith("_TIRE")),
        0,
    )
    for entry in wheel_blocks:
        source_hash = entry["source_hash"]
        block = entry["block"]
        texture = bank.get(source_hash)
        if texture is None:
            missing_groups.setdefault(source_hash, []).append(entry)
            continue
        uvs = resolved_uvs(block, texture)
        indices = indices_for_block(block)
        if len(uvs) < len(block["run"].get("vertices", [])) or len(indices) < 3:
            continue
        resolved_groups.setdefault(source_hash, []).append({**entry, "uvs": uvs, "indices": indices})

    summary: dict[str, Any] = {
        "car": car_id,
        "geometry": str(geometry_path),
        "textures": str(texture_path),
        "global_textures": None if args.no_global_textures else str(global_texture_path),
        "object_filter": args.object_filter,
        "decoded_textures": [texture.info for texture in bank.textures.values()],
        "resolved_groups": {},
        "missing_material_groups": {},
        "errors": bank.errors,
    }

    if args.dump_binary:
        summary["wheel_uv_binary_dump"] = str(write_wheel_binary_dump(out_dir / car_id, car_id, wheel_blocks, bank))

    for texture_hash, entries in sorted(resolved_groups.items()):
        texture = bank.get(texture_hash)
        if texture is None:
            continue
        overlay = draw_overlay(texture, entries, max(1, args.scale))
        overlay_path = overlay_dir / f"{texture.hash:08x}_{safe_name(texture.name)}_uv_overlay.png"
        write_png(overlay_path, texture.width * max(1, args.scale), texture.height * max(1, args.scale), overlay)
        summary["resolved_groups"][f"{texture_hash:08x}"] = {
            "texture_name": texture.name,
            "block_count": len(entries),
            "overlay": str(overlay_path),
            "blocks": summarize_entries(entries),
        }

    if args.missing_target == "tire" and tire_texture_hash and bank.get(tire_texture_hash):
        target = bank.get(tire_texture_hash)
        assert target is not None
        for source_hash, entries in sorted(missing_groups.items()):
            draw_entries = []
            for entry in entries:
                block = entry["block"]
                uvs = resolved_uvs(block, target)
                indices = indices_for_block(block)
                if len(indices) >= 3:
                    draw_entries.append({**entry, "uvs": uvs, "indices": indices})
            if not draw_entries:
                continue
            overlay = draw_overlay(target, draw_entries, max(1, args.scale))
            label = material_label(source_hash)
            overlay_path = overlay_dir / f"missing_{source_hash:08x}_{label}_on_{safe_name(target.name)}.png"
            write_png(overlay_path, target.width * max(1, args.scale), target.height * max(1, args.scale), overlay)
            summary["missing_material_groups"][f"{source_hash:08x}"] = {
                "label": label,
                "diagnostic_target": target.name,
                "block_count": len(draw_entries),
                "overlay": str(overlay_path),
                "blocks": summarize_entries(draw_entries),
            }
    else:
        for source_hash, entries in sorted(missing_groups.items()):
            summary["missing_material_groups"][f"{source_hash:08x}"] = {
                "label": material_label(source_hash),
                "block_count": len(entries),
                "blocks": summarize_entries(entries),
            }

    summary_path = out_dir / car_id / "summary.json"
    summary_path.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(summary_path)
    for group in summary["resolved_groups"].values():
        print(group["overlay"])
    for group in summary["missing_material_groups"].values():
        if "overlay" in group:
            print(group["overlay"])
    return 0


def material_label(texture_hash: int) -> str:
    if texture_hash == RIM_MATERIAL_HASH:
        return "wheel_rim_material"
    if texture_hash == CAP_MATERIAL_HASH:
        return "wheel_cap_material"
    return "unknown_material"


def summarize_entries(entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
    out = []
    for entry in entries:
        block = entry["block"]
        strip = block.get("strip_entry", {})
        uvs = entry.get("uvs") or []
        if uvs:
            min_u = min(uv[0] for uv in uvs)
            min_v = min(uv[1] for uv in uvs)
            max_u = max(uv[0] for uv in uvs)
            max_v = max(uv[1] for uv in uvs)
        else:
            min_u = min_v = max_u = max_v = 0.0
        out.append(
            {
                "object_name": entry["object_name"],
                "block_index": entry["block_index"],
                "source_hash": f"{entry['source_hash']:08x}",
                "strip_texture_width_u16": strip.get("texture_width_u16", 0),
                "strip_texture_height_u16": strip.get("texture_height_u16", 0),
                "strip_word_1c": f"{int(strip.get('word_1c', 0)):08x}",
                "uv_min": [round(min_u, 6), round(min_v, 6)],
                "uv_max": [round(max_u, 6), round(max_v, 6)],
            }
        )
    return out


if __name__ == "__main__":
    raise SystemExit(main())
