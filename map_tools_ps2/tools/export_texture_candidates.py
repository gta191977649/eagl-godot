#!/usr/bin/env python3
from __future__ import annotations

import argparse
import struct
from pathlib import Path

from map_tools_ps2.binary import align
from map_tools_ps2.chunks import parse_chunks, walk_chunks
from map_tools_ps2.png import encode_rgba_png
from map_tools_ps2.textures import _decode_palette, _unswizzle_psmt8_indices


def main() -> int:
    parser = argparse.ArgumentParser(description="Export alternate PS2 texture decode candidates")
    parser.add_argument("source", help="TEX##TRACK.BIN or TEX##LOCATION.BIN")
    parser.add_argument("--name", required=True, help="texture name")
    parser.add_argument("-o", "--output-dir", required=True, help="output directory")
    args = parser.parse_args()

    source = Path(args.source)
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    entry = load_texture_entry(source, args.name)
    if entry is None:
        raise SystemExit(f"texture {args.name!r} not found in {source}")

    for label, rgba in generate_candidates(entry).items():
        out_path = output_dir / f"{entry['name']}_{label}.png"
        out_path.write_bytes(encode_rgba_png(entry["width"], entry["height"], rgba))
        print(out_path)
    return 0


def load_texture_entry(path: Path, texture_name: str) -> dict[str, object] | None:
    data = path.read_bytes()
    chunks = parse_chunks(data)
    entry_chunk = next((chunk for chunk in walk_chunks(chunks) if chunk.chunk_id == 0x30300003), None)
    data_chunk = next((chunk for chunk in walk_chunks(chunks) if chunk.chunk_id == 0x30300004), None)
    if entry_chunk is None or data_chunk is None:
        return None

    entries = entry_chunk.payload(data)
    data_base = align(data_chunk.data_offset, 0x80)
    for index in range(len(entries) // 0xA4):
        entry = entries[index * 0xA4 : (index + 1) * 0xA4]
        name = entry[0x08:0x20].split(b"\0")[0].decode("ascii", errors="replace")
        if name != texture_name:
            continue
        width, height = struct.unpack_from("<HH", entry, 0x24)
        data_offset = struct.unpack_from("<I", entry, 0x30)[0]
        palette_offset = struct.unpack_from("<I", entry, 0x34)[0]
        data_size = struct.unpack_from("<I", entry, 0x38)[0]
        palette_size = struct.unpack_from("<I", entry, 0x3C)[0]
        return {
            "name": name,
            "width": width,
            "height": height,
            "image": data[data_base + data_offset : data_base + data_offset + data_size],
            "palette": data[data_base + palette_offset : data_base + palette_offset + palette_size],
        }
    return None


def generate_candidates(entry: dict[str, object]) -> dict[str, bytes]:
    width = int(entry["width"])
    height = int(entry["height"])
    image = bytes(entry["image"])
    palette = bytes(entry["palette"])

    indices_linear_lo = _linear_psmt4_indices(image, width, height, high_nibble_first=False)
    indices_linear_hi = _linear_psmt4_indices(image, width, height, high_nibble_first=True)
    indices_unswizzled_lo = _unswizzle_psmt8_indices(indices_linear_lo, width, height)
    indices_unswizzled_hi = _unswizzle_psmt8_indices(indices_linear_hi, width, height)
    packed_unswizzled_lo = _packed_unswizzle_psmt4_indices(image, width, height, high_nibble_first=False)
    packed_unswizzled_hi = _packed_unswizzle_psmt4_indices(image, width, height, high_nibble_first=True)

    linear_palette = _decode_palette(palette, swizzle=False)
    palettes = _palette_variants(linear_palette, palette)
    index_sets = {
        "linear_lo": indices_linear_lo,
        "linear_hi": indices_linear_hi,
        "unswizzled_lo": indices_unswizzled_lo,
        "unswizzled_hi": indices_unswizzled_hi,
        "packed_unswizzled_lo": packed_unswizzled_lo,
        "packed_unswizzled_hi": packed_unswizzled_hi,
    }

    candidates: dict[str, bytes] = {}
    for palette_label, colors in palettes.items():
        for index_label, indices in index_sets.items():
            label = f"{index_label}_{palette_label}"
            candidates[label] = _rgba_from_indices(indices, colors, width * height)
    return candidates


def _linear_psmt4_indices(image: bytes, width: int, height: int, high_nibble_first: bool) -> bytes:
    pixel_count = width * height
    packed_size = (pixel_count + 1) // 2
    packed = image[:packed_size]
    unpacked = bytearray(pixel_count)
    for index, byte in enumerate(packed):
        pixel_index = index * 2
        first = (byte >> 4) & 0x0F if high_nibble_first else byte & 0x0F
        second = byte & 0x0F if high_nibble_first else (byte >> 4) & 0x0F
        unpacked[pixel_index] = first
        if pixel_index + 1 < pixel_count:
            unpacked[pixel_index + 1] = second
    return bytes(unpacked)


def _packed_unswizzle_psmt4_indices(image: bytes, width: int, height: int, high_nibble_first: bool) -> bytes:
    packed_width = max(width // 2, 1)
    unswizzled = _unswizzle_psmt8_indices(image[: packed_width * height], packed_width, height)
    return _linear_psmt4_indices(unswizzled, width, height, high_nibble_first)


def _palette_variants(
    linear_palette: list[tuple[int, int, int, int]],
    raw_palette: bytes,
) -> dict[str, list[tuple[int, int, int, int]]]:
    palettes = {"pal_linear": linear_palette}
    if len(linear_palette) == 16:
        palettes["pal_halfswap"] = linear_palette[8:] + linear_palette[:8]
        palettes["pal_pairswap"] = _reorder_palette(linear_palette, [index ^ 1 for index in range(16)])
        palettes["pal_quadswap"] = _reorder_palette(linear_palette, [4, 5, 6, 7, 0, 1, 2, 3, 12, 13, 14, 15, 8, 9, 10, 11])
        palettes["pal_evenodd"] = [linear_palette[index] for index in range(0, 16, 2)] + [linear_palette[index] for index in range(1, 16, 2)]
        palettes["pal_reverse"] = list(reversed(linear_palette))
        palettes["pal_reverse8"] = list(reversed(linear_palette[:8])) + list(reversed(linear_palette[8:16]))
        palettes["pal_midshift"] = _reorder_palette(linear_palette, [0, 1, 2, 3, 8, 9, 10, 11, 4, 5, 6, 7, 12, 13, 14, 15])
    elif len(linear_palette) >= 32:
        palettes["pal_swizzled"] = _decode_palette(raw_palette, swizzle=True)
    return palettes


def _reorder_palette(
    palette: list[tuple[int, int, int, int]],
    order: list[int],
) -> list[tuple[int, int, int, int]]:
    return [palette[index] for index in order]


def _rgba_from_indices(indices: bytes, colors: list[tuple[int, int, int, int]], pixel_count: int) -> bytes:
    out = bytearray()
    for index in indices[:pixel_count]:
        out.extend(colors[index % len(colors)])
    return bytes(out)


if __name__ == "__main__":
    raise SystemExit(main())
