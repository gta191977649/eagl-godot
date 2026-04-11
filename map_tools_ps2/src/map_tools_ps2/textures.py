from __future__ import annotations

import struct
from dataclasses import dataclass
from pathlib import Path

from .binary import align
from .chunks import parse_chunks, walk_chunks
from .png import encode_rgba_png


@dataclass(frozen=True)
class Texture:
    name: str
    tex_hash: int
    width: int
    height: int
    data_offset: int
    palette_offset: int
    data_size: int
    palette_size: int
    source_path: Path
    png: bytes
    has_alpha: bool
    alpha_mode: str | None
    alpha_cutoff: float | None


@dataclass
class TextureLibrary:
    textures: dict[int, Texture]

    def get(self, tex_hash: int | None) -> Texture | None:
        if tex_hash is None:
            return None
        return self.textures.get(tex_hash)


def load_texture_library_for_track(track_path: Path, texture_dir: Path | None = None) -> TextureLibrary:
    texture_dir = texture_dir or track_path.parent
    track_id = _track_id_from_path(track_path)
    textures: dict[int, Texture] = {}
    if track_id is None:
        return TextureLibrary(textures)

    for suffix in ("LOCATION", "TRACK"):
        path = texture_dir / f"TEX{track_id}{suffix}.BIN"
        if not path.exists():
            continue
        for texture in read_ps2_tpk(path):
            textures.setdefault(texture.tex_hash, texture)
    return TextureLibrary(textures)


def read_ps2_tpk(path: Path) -> tuple[Texture, ...]:
    data = path.read_bytes()
    chunks = parse_chunks(data)
    entry_chunk = next((chunk for chunk in walk_chunks(chunks) if chunk.chunk_id == 0x30300003), None)
    data_chunk = next((chunk for chunk in walk_chunks(chunks) if chunk.chunk_id == 0x30300004), None)
    if entry_chunk is None or data_chunk is None:
        return ()

    entries = entry_chunk.payload(data)
    if len(entries) % 0xA4 != 0:
        return ()

    data_base = align(data_chunk.data_offset, 0x80)
    textures: list[Texture] = []
    for index in range(len(entries) // 0xA4):
        entry = entries[index * 0xA4 : (index + 1) * 0xA4]
        name = entry[0x08:0x20].split(b"\0")[0].decode("ascii", errors="replace")
        tex_hash = struct.unpack_from("<I", entry, 0x20)[0]
        width, height = struct.unpack_from("<HH", entry, 0x24)
        data_offset = struct.unpack_from("<I", entry, 0x30)[0]
        palette_offset = struct.unpack_from("<I", entry, 0x34)[0]
        data_size = struct.unpack_from("<I", entry, 0x38)[0]
        palette_size = struct.unpack_from("<I", entry, 0x3C)[0]

        image = data[data_base + data_offset : data_base + data_offset + data_size]
        palette = data[data_base + palette_offset : data_base + palette_offset + palette_size]
        if not name or not width or not height or not image or not palette:
            continue

        try:
            rgba = decode_indexed_texture(width, height, image, palette)
        except ValueError:
            continue
        alpha_mode, alpha_cutoff = _alpha_properties_for_rgba(rgba)
        textures.append(
            Texture(
                name=name,
                tex_hash=tex_hash,
                width=width,
                height=height,
                data_offset=data_offset,
                palette_offset=palette_offset,
                data_size=data_size,
                palette_size=palette_size,
                source_path=path,
                png=encode_rgba_png(width, height, rgba),
                has_alpha=alpha_mode is not None,
                alpha_mode=alpha_mode,
                alpha_cutoff=alpha_cutoff,
            )
        )
    return tuple(textures)


def decode_indexed_texture(width: int, height: int, image: bytes, palette: bytes) -> bytes:
    if len(palette) == 0x40:
        indices = (
            _linear_psmt4_indices(image, width, height)
            if width < 128 or height < 128
            else _unswizzle_psmt4_indices(image, width, height)
        )
        colors = _decode_palette(palette, swizzle=False)
    elif len(palette) == 0x80:
        indices = (
            image[: width * height]
            if width < 128 or height < 64
            else _unswizzle_psmt8_indices(image, width, height)
        )
        colors = _decode_palette(palette, swizzle=False)
    elif len(palette) == 0x400:
        indices = image[: width * height] if width < 128 or height < 64 else _unswizzle_psmt8_indices(image, width, height)
        colors = _decode_palette(palette, swizzle=True)
    else:
        raise ValueError(f"unsupported PS2 palette size 0x{len(palette):x}")

    out = bytearray()
    for index in indices[: width * height]:
        out.extend(colors[index % len(colors)])
    return bytes(out)


def _unswizzle_psmt4_indices(image: bytes, width: int, height: int) -> bytes:
    return _unswizzle_psmt8_indices(_linear_psmt4_indices(image, width, height), width, height)


def _linear_psmt4_indices(image: bytes, width: int, height: int) -> bytes:
    pixel_count = width * height
    packed_size = (pixel_count + 1) // 2
    packed = image[:packed_size]
    unpacked = bytearray(pixel_count)
    for index, byte in enumerate(packed):
        pixel_index = index * 2
        unpacked[pixel_index] = byte & 0x0F
        if pixel_index + 1 < pixel_count:
            unpacked[pixel_index + 1] = byte >> 4
    return bytes(unpacked)


def _unswizzle_psmt8_indices(image: bytes, width: int, height: int) -> bytes:
    pixel_count = width * height
    if len(image) < pixel_count:
        return image[:pixel_count]

    out = bytearray(pixel_count)
    for y in range(height):
        block_y = (y & ~0x0F) * width
        pos_y = (((y & ~0x03) >> 1) + (y & 1)) & 0x07
        swap_selector = (((y + 2) >> 2) & 1) * 4
        base_column_location = pos_y * width * 2
        for x in range(width):
            block_x = (x & ~0x0F) * 2
            column_location = base_column_location + ((x + swap_selector) & 0x07) * 4
            byte_num = ((y >> 1) & 1) + ((x >> 2) & 2)
            source = block_y + block_x + column_location + byte_num
            if source < len(image):
                out[y * width + x] = image[source]
    return bytes(out)


def _decode_palette(palette: bytes, swizzle: bool) -> list[tuple[int, int, int, int]]:
    colors: list[tuple[int, int, int, int]] = []
    for index in range(len(palette) // 4):
        source_index = _unswizzle_palette_index(index) if swizzle else index
        off = source_index * 4
        r, g, b, a = palette[off : off + 4]
        colors.append((r, g, b, _decode_ps2_alpha(a)))
    return colors


def _decode_ps2_alpha(value: int) -> int:
    if value >= 0x7F:
        return 255
    return min(value * 2, 255)


def _alpha_properties_for_rgba(rgba: bytes) -> tuple[str | None, float | None]:
    alphas = {rgba[offset + 3] for offset in range(0, len(rgba), 4)}
    transparent = {alpha for alpha in alphas if alpha < 250}
    if not transparent:
        return None, None
    if transparent == {0}:
        opaque = {alpha for alpha in alphas if alpha >= 250}
        cutoff = 0.5
        if opaque:
            cutoff = ((max(transparent) + min(opaque)) / 2.0) / 255.0
        return "MASK", cutoff
    return "BLEND", None


def _alpha_mode_for_rgba(rgba: bytes) -> str | None:
    mode, _ = _alpha_properties_for_rgba(rgba)
    return mode


def _unswizzle_palette_index(index: int) -> int:
    block = index & ~0x1F
    pos = index & 0x1F
    if 8 <= pos < 16:
        pos += 8
    elif 16 <= pos < 24:
        pos -= 8
    return block + pos


def _track_id_from_path(path: Path) -> str | None:
    stem = path.stem.upper()
    if stem.startswith("TRACKB") and len(stem) >= 8:
        return stem[6:8]
    if stem.startswith("TRACKA") and len(stem) >= 8:
        return stem[6:8]
    return None
