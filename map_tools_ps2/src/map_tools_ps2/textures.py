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
    bit_depth: int | None = None
    shift_width: int | None = None
    shift_height: int | None = None
    pixel_storage_mode: int | None = None
    clut_pixel_storage_mode: int | None = None
    is_swizzled: bool | None = None
    texture_fx: int | None = None
    alpha_bits: int | None = None
    alpha_fix: int | None = None
    is_any_semitransparency: int | None = None


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
        bit_depth = entry[0x28]
        data_offset = struct.unpack_from("<I", entry, 0x30)[0]
        palette_offset = struct.unpack_from("<I", entry, 0x34)[0]
        data_size = struct.unpack_from("<I", entry, 0x38)[0]
        palette_size = struct.unpack_from("<I", entry, 0x3C)[0]
        shift_width = entry[0x48]
        shift_height = entry[0x49]
        pixel_storage_mode = entry[0x4A]
        clut_pixel_storage_mode = entry[0x4B]
        texture_fx = entry[0x4E]
        is_any_semitransparency = entry[0x4F]
        is_swizzled = entry[0x55] != 0
        alpha_bits = entry[0x76]
        alpha_fix = entry[0x77]

        image = data[data_base + data_offset : data_base + data_offset + data_size]
        palette = data[data_base + palette_offset : data_base + palette_offset + palette_size]
        if not name or not width or not height or not image or not palette:
            continue

        try:
            rgba = decode_indexed_texture(
                width,
                height,
                image,
                palette,
                bit_depth=bit_depth,
                shift_width=shift_width,
                shift_height=shift_height,
                pixel_storage_mode=pixel_storage_mode,
                is_swizzled=is_swizzled,
            )
        except ValueError:
            continue
        alpha_mode, alpha_cutoff = _material_alpha_properties_for_rgba(rgba, is_any_semitransparency)
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
                bit_depth=bit_depth,
                shift_width=shift_width,
                shift_height=shift_height,
                pixel_storage_mode=pixel_storage_mode,
                clut_pixel_storage_mode=clut_pixel_storage_mode,
                is_swizzled=is_swizzled,
                texture_fx=texture_fx,
                alpha_bits=alpha_bits,
                alpha_fix=alpha_fix,
                is_any_semitransparency=is_any_semitransparency,
            )
        )
    return tuple(textures)


def decode_indexed_texture(
    width: int,
    height: int,
    image: bytes,
    palette: bytes,
    *,
    bit_depth: int | None = None,
    shift_width: int | None = None,
    shift_height: int | None = None,
    pixel_storage_mode: int | None = None,
    is_swizzled: bool | None = None,
) -> bytes:
    if (
        bit_depth is not None
        and shift_width is not None
        and shift_height is not None
        and pixel_storage_mode is not None
        and is_swizzled is not None
    ):
        return _decode_modelulator_indexed_texture(
            width,
            height,
            image,
            palette,
            bit_depth=bit_depth,
            shift_width=shift_width,
            shift_height=shift_height,
            pixel_storage_mode=pixel_storage_mode,
            is_swizzled=is_swizzled,
        )

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


def _decode_modelulator_indexed_texture(
    width: int,
    height: int,
    image: bytes,
    palette: bytes,
    *,
    bit_depth: int,
    shift_width: int,
    shift_height: int,
    pixel_storage_mode: int,
    is_swizzled: bool,
) -> bytes:
    depth = _indexed_bit_depth(bit_depth, pixel_storage_mode, len(palette))
    if depth not in (4, 8):
        raise ValueError(f"unsupported indexed PS2 bit depth {depth}")

    color_count = len(palette) // 4
    if color_count <= 0:
        raise ValueError("missing PS2 palette")
    colors = _decode_palette(palette, swizzle=_psm_type_index(pixel_storage_mode) == 3)

    buffer_width = 1 << shift_width
    buffer_height = 1 << shift_height
    if width <= 0 or height <= 0 or buffer_width <= 0 or buffer_height <= 0:
        raise ValueError("invalid PS2 texture dimensions")

    words = _u32_words(image)
    if is_swizzled:
        scale = 32 // depth
        scale_mask = scale - 1
        scale_x = (_adjust_with_mask(scale_mask, 1, 2, 1) | _adjust_with_mask(scale_mask, 1, 0, 0)) + 1
        scale_y = (_adjust_with_mask(scale_mask, 1, 3, 1) | _adjust_with_mask(scale_mask, 1, 1, 0)) + 1
        words = _legacy_ps2_rw_buffer(words, "write", 0, 32, width // scale_y, height // scale_x)
        words = _legacy_ps2_rw_buffer(words, "read", pixel_storage_mode, depth, width, height)

    indices: list[int] = []
    scale = 32 // depth
    index_mask = (1 << depth) - 1
    for word in words:
        for shift in range(0, 32, depth):
            indices.append((word >> shift) & index_mask)

    if is_swizzled:
        cropped_indices: list[int] = []
        for y in range(height):
            row = y * buffer_width
            cropped_indices.extend(indices[row : row + width])
        indices = cropped_indices

    final_indices: list[int] = []
    for y in range(height - 1, -1, -1):
        row = y * width
        final_indices.extend(indices[row : row + width])

    out = bytearray()
    for index in final_indices[: width * height]:
        out.extend(colors[index % color_count])
    return bytes(out)


def _indexed_bit_depth(bit_depth: int, pixel_storage_mode: int, palette_size: int) -> int:
    psm_index = _psm_type_index(pixel_storage_mode)
    if psm_index > 0:
        return 32 >> max(psm_index - 1, 0)
    if bit_depth in (4, 8):
        return bit_depth
    if palette_size == 0x40:
        return 4
    if palette_size in (0x80, 0x400):
        return 8
    raise ValueError(f"unsupported PS2 palette size 0x{palette_size:x}")


def _psm_type_index(pixel_storage_mode: int) -> int:
    return pixel_storage_mode & 0x07


def _u32_words(data: bytes) -> list[int]:
    padded = data + (b"\0" * ((4 - (len(data) % 4)) % 4))
    return [struct.unpack_from("<I", padded, offset)[0] for offset in range(0, len(padded), 4)]


def _legacy_ps2_rw_buffer(
    image_data: list[int],
    mode: str,
    pixel_storage_mode: int,
    bit_depth: int,
    width: int,
    height: int,
) -> list[int]:
    scale = 32 // bit_depth
    scale_mask = scale - 1
    scale_x = (_adjust_with_mask(scale_mask, 1, 2, 1) | _adjust_with_mask(scale_mask, 1, 0, 0)) + 1
    scale_y = (_adjust_with_mask(scale_mask, 1, 3, 1) | _adjust_with_mask(scale_mask, 1, 1, 0)) + 1

    physical_width = width // scale_y
    physical_height = height // scale_x
    physical_buffer_width = _align_power_of_two_max(physical_width)
    physical_buffer_height = _align_power_of_two_max(physical_height)
    buffer_width = _align_power_of_two_max(width)
    buffer_height = _align_power_of_two_max(height)
    data = [0] * (physical_buffer_width * physical_buffer_height)

    type_index = _adjust_with_mask(pixel_storage_mode, 3, 0)
    type_mode = _adjust_with_mask(pixel_storage_mode, 2, 4)
    type_flag = _adjust_with_mask(pixel_storage_mode, 1, 3) != 0

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

    swizzle_function = _LEGACY_SWIZZLE_FUNCTIONS[bit_depth]
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
        block = _legacy_ps2_block_address(block_x + block_y * page_width, swap_xy, z_buffer, shifted)

        bx = px - block_x * column_width
        by = py - block_y * (4 * column_height)
        column_y = by // column_height
        column = column_y

        cx = bx
        cy = by - column_y * column_height
        pixel = swizzle_function(cx + cy * column_width, True)

        word = pixel // scale
        offset = pixel & scale_mask
        if bit_depth < 16:
            word ^= (column & 0x01) << 2
        word = (_rotate_bits(word >> 1, -1, 3) << 1) | (word & 0x01)

        output_address = (page << 11) | (block << 6) | (column << 4) | word
        if mode == "read":
            address_a, address_b = input_address, output_address
            source_shift = bit_depth * offset
            target_shift = bit_depth * from_offset_w
        elif mode == "write":
            address_a, address_b = output_address, input_address
            source_shift = bit_depth * from_offset_w
            target_shift = bit_depth * offset
        else:
            raise ValueError(f"unsupported PS2 buffer mode {mode}")

        input_value = image_data[address_b] if 0 <= address_b < len(image_data) else 0
        pixel_data = _adjust_with_mask(input_value, bit_depth, source_shift, target_shift)
        if 0 <= address_a < len(data):
            data[address_a] |= pixel_data

        from_offset_w += 1
        if from_offset_w > 0 and (from_offset_w & scale_mask) == 0:
            input_address += 1
        from_offset_w &= scale_mask

    return data


def _adjust_with_mask(src: int, mask_width: int, mask_position: int = 0, adjustment: int = 0) -> int:
    return ((src >> mask_position) & ((1 << mask_width) - 1)) << adjustment


def _rotate_bits(value: int, shift: int, width: int) -> int:
    shift %= width
    mask = (1 << width) - 1
    value &= mask
    return ((value << shift) | (value >> (width - shift))) & mask


def _align_power_of_two_max(value: int) -> int:
    if value <= 1:
        return 1
    return 1 << (value - 1).bit_length()


def _legacy_ps2_swizzle_psmt4(pixel_index: int, mode_flag: bool) -> int:
    ax, ay = (pixel_index >> 0) & 0x01, (pixel_index >> 1) & 0x01
    bx, by = (pixel_index >> 2) & 0x01, (pixel_index >> 3) & 0x01
    cx, cy = (pixel_index >> 4) & 0x01, (pixel_index >> 5) & 0x01
    dx = (pixel_index >> 6) & 0x01
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


def _legacy_ps2_swizzle_psmt8(pixel_index: int, mode_flag: bool) -> int:
    ax, ay = (pixel_index >> 0) & 0x01, (pixel_index >> 1) & 0x01
    bx, by = (pixel_index >> 2) & 0x01, (pixel_index >> 3) & 0x01
    cx, cy = (pixel_index >> 4) & 0x01, (pixel_index >> 5) & 0x01
    result = 0
    result ^= ax << 0
    result ^= cy << 1
    result = _rotate_bits(result, 5 + int(mode_flag), 7)
    result ^= bx << (0 + 4 * int(mode_flag))
    result ^= cx << (2 + 3 * int(mode_flag))
    result ^= by << 1
    result ^= ax << 2
    result ^= ay << 3
    result ^= cy << 4
    return result & 0x3F


def _legacy_ps2_swizzle_psmt16(pixel_index: int, mode_flag: bool) -> int:
    ax, ay = (pixel_index >> 0) & 0x01, (pixel_index >> 1) & 0x01
    bx, by = (pixel_index >> 2) & 0x01, (pixel_index >> 3) & 0x01
    cx = (pixel_index >> 4) & 0x01
    result = 0
    result ^= ay << 0
    result ^= bx << 1
    result ^= by << 2
    result ^= ax << 3
    result = _rotate_bits(result, 2 * int(mode_flag), 4)
    result ^= cx << 4
    return result & 0x1F


def _legacy_ps2_swizzle_psmt32(pixel_index: int, mode_flag: bool) -> int:
    ax, ay = (pixel_index >> 0) & 0x01, (pixel_index >> 1) & 0x01
    bx, by = (pixel_index >> 2) & 0x01, (pixel_index >> 3) & 0x01
    result = 0
    result ^= ay << 0
    result ^= bx << 1
    result ^= by << 2
    result = _rotate_bits(result, 2 + int(mode_flag), 3)
    result = (result << 1) ^ ax
    return result & 0x0F


_LEGACY_SWIZZLE_FUNCTIONS = {
    4: _legacy_ps2_swizzle_psmt4,
    8: _legacy_ps2_swizzle_psmt8,
    16: _legacy_ps2_swizzle_psmt16,
    24: _legacy_ps2_swizzle_psmt32,
    32: _legacy_ps2_swizzle_psmt32,
}


def _legacy_ps2_block_address(block_index: int, swap_xy: bool, flip_xy: bool, shifted: bool) -> int:
    swap = int(swap_xy)
    swap = (swap << 0) ^ (swap << 1)
    block_index = _rotate_bits(block_index, swap, 5)
    ax, ay = (block_index >> 0) & 0x01, (block_index >> 3) & 0x01
    bx, by = (block_index >> 1) & 0x01, (block_index >> 4) & 0x01
    cx = (block_index >> 2) & 0x01
    result = 0
    result ^= bx << 0
    result ^= by << 1
    result ^= cx << 2
    result = _rotate_bits(result, int(shifted), 3)
    result ^= (0x03 * int(flip_xy)) << 1
    result = (result << 2) ^ (ax << 0) ^ (ay << 1)
    return result & 0x1F


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
    expanded = max((value << 1) - ((value ^ 1) & 0x01), 0)
    if expanded <= 0xFF:
        return expanded
    return value


def _alpha_properties_for_rgba(rgba: bytes) -> tuple[str | None, float | None]:
    alphas = {rgba[offset + 3] for offset in range(0, len(rgba), 4)}
    non_opaque = {alpha for alpha in alphas if alpha < 250}
    if not non_opaque:
        return None, None
    cutout = {alpha for alpha in non_opaque if alpha <= 2}
    if non_opaque == cutout:
        opaque = {alpha for alpha in alphas if alpha >= 250}
        cutoff = 0.5
        if opaque:
            cutoff = ((max(cutout) + min(opaque)) / 2.0) / 255.0
        return "MASK", cutoff
    return "BLEND", None


def _material_alpha_properties_for_rgba(
    rgba: bytes, is_any_semitransparency: int | None
) -> tuple[str | None, float | None]:
    mode, cutoff = _alpha_properties_for_rgba(rgba)
    if mode != "BLEND" or is_any_semitransparency:
        return mode, cutoff

    # Some HP2 PS2 textures contain high decoded alpha values such as 0xdf
    # even when the TPK entry says the texture is not semitransparent. Treat
    # those high values as opaque for material mode selection to avoid
    # unnecessary transparent sorting.
    alphas = {rgba[offset + 3] for offset in range(0, len(rgba), 4)}
    if alphas and all(alpha == 0 or alpha >= 0x80 for alpha in alphas):
        if 0 in alphas:
            return "MASK", 0.5
        return None, None
    return mode, cutoff


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
