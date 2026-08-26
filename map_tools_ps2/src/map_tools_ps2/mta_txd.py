from __future__ import annotations

import struct


def dxt_raster_format_flags(mode: str, *, mipmaps: bool = True) -> int:
    """Return GTA-compatible D3D9 raster flags for BC1/BC3 native textures."""
    mode = mode.upper()
    # RenderWare's raster type must agree with the compressed D3D format.
    # Keeping DragonFF's source RGBA8888 flags (0x0505) makes MTA reject the
    # entire TXD even though DragonFF can read it back.
    raster_type = {
        "OPAQUE": 0x02,  # 565 + DXT1
        "MASK": 0x01,  # 1555 + alpha-capable DXT1
        "BLEND": 0x03,  # 4444 + DXT5
    }.get(mode)
    if raster_type is None:
        raise ValueError(f"unsupported alpha mode: {mode}")
    return (raster_type << 8) | (0x8000 if mipmaps else 0)


def mip_dimensions(width: int, height: int) -> list[tuple[int, int]]:
    """Return a complete explicit mip chain, including the 1x1 level."""
    if width < 1 or height < 1:
        raise ValueError("texture dimensions must be positive")
    result = []
    while True:
        result.append((width, height))
        if width == 1 and height == 1:
            return result
        width = max(1, width // 2)
        height = max(1, height // 2)


def _normalized_bgra(data: bytes, mode: str) -> bytes:
    mode = mode.upper()
    if mode not in {"OPAQUE", "MASK", "BLEND"}:
        raise ValueError(f"unsupported alpha mode: {mode}")
    pixels = bytearray(data)
    if len(pixels) % 4:
        raise ValueError("BGRA8888 data size is not divisible by four")
    for offset in range(3, len(pixels), 4):
        if mode == "OPAQUE" or pixels[offset] >= 250:
            pixels[offset] = 255
    return bytes(pixels)


def _downsample_bgra(data: bytes, width: int, height: int, mode: str) -> bytes:
    dst_width, dst_height = max(1, width // 2), max(1, height // 2)
    output = bytearray(dst_width * dst_height * 4)
    alpha_aware = mode != "OPAQUE"
    for dst_y in range(dst_height):
        y0, y1 = dst_y * 2, min(dst_y * 2 + 2, height)
        for dst_x in range(dst_width):
            x0, x1 = dst_x * 2, min(dst_x * 2 + 2, width)
            samples = [
                data[(src_y * width + src_x) * 4 : (src_y * width + src_x + 1) * 4]
                for src_y in range(y0, y1)
                for src_x in range(x0, x1)
            ]
            count = len(samples)
            alpha_sum = sum(sample[3] for sample in samples)
            alpha = 255 if not alpha_aware else (alpha_sum + count // 2) // count
            if alpha_aware and alpha_sum:
                channels = [
                    (sum(sample[channel] * sample[3] for sample in samples) + alpha_sum // 2) // alpha_sum
                    for channel in range(3)
                ]
            else:
                channels = [
                    (sum(sample[channel] for sample in samples) + count // 2) // count
                    for channel in range(3)
                ]
            if alpha >= 250:
                alpha = 255
            offset = (dst_y * dst_width + dst_x) * 4
            output[offset : offset + 4] = bytes((*channels, alpha))
    return bytes(output)


def build_bgra_mip_chain(base: bytes, width: int, height: int, mode: str) -> list[bytes]:
    if len(base) != width * height * 4:
        raise ValueError(f"BGRA8888 base level has {len(base)} bytes, expected {width * height * 4}")
    levels = [_normalized_bgra(base, mode)]
    level_width, level_height = width, height
    while level_width > 1 or level_height > 1:
        levels.append(_downsample_bgra(levels[-1], level_width, level_height, mode.upper()))
        level_width, level_height = max(1, level_width // 2), max(1, level_height // 2)
    return levels


def _rgb565(red: int, green: int, blue: int) -> int:
    return ((red * 31 + 127) // 255 << 11) | ((green * 63 + 127) // 255 << 5) | ((blue * 31 + 127) // 255)


def _decode565(value: int) -> tuple[int, int, int]:
    return (((value >> 11) & 31) * 255 // 31, ((value >> 5) & 63) * 255 // 63, (value & 31) * 255 // 31)


def _block_pixels(data: bytes, width: int, height: int, block_x: int, block_y: int) -> list[tuple[int, int, int, int]]:
    result = []
    for y in range(4):
        src_y = min(block_y * 4 + y, height - 1)
        for x in range(4):
            src_x = min(block_x * 4 + x, width - 1)
            offset = (src_y * width + src_x) * 4
            blue, green, red, alpha = data[offset : offset + 4]
            result.append((red, green, blue, alpha))
    return result


def _color_endpoints(pixels: list[tuple[int, int, int, int]], transparent: bool) -> tuple[int, int]:
    colors = [pixel for pixel in pixels if not transparent or pixel[3] >= 128]
    if not colors:
        return 0, 0
    # Luminance endpoints are inexpensive and substantially better than independent RGB bounds.
    low = min(colors, key=lambda value: value[0] * 77 + value[1] * 150 + value[2] * 29)
    high = max(colors, key=lambda value: value[0] * 77 + value[1] * 150 + value[2] * 29)
    low565 = _rgb565(*low[:3])
    high565 = _rgb565(*high[:3])
    if transparent:
        return (min(low565, high565), max(low565, high565))
    if high565 == low565:
        if high565 < 0xFFFF:
            high565 += 1
        elif low565 > 0:
            low565 -= 1
    return (max(high565, low565), min(high565, low565))


def _bc1_block(pixels: list[tuple[int, int, int, int]], allow_alpha: bool, alpha_cutoff: int) -> bytes:
    transparent = allow_alpha and any(pixel[3] < alpha_cutoff for pixel in pixels)
    color0, color1 = _color_endpoints(pixels, transparent)
    first, second = _decode565(color0), _decode565(color1)
    if color0 > color1:
        palette = (
            first,
            second,
            tuple((2 * first[channel] + second[channel]) // 3 for channel in range(3)),
            tuple((first[channel] + 2 * second[channel]) // 3 for channel in range(3)),
        )
    else:
        palette = (
            first,
            second,
            tuple((first[channel] + second[channel]) // 2 for channel in range(3)),
        )
    indices = 0
    for pixel_index, pixel in enumerate(pixels):
        if transparent and pixel[3] < alpha_cutoff:
            index = 3
        else:
            index = min(
                range(len(palette)),
                key=lambda candidate: sum((pixel[channel] - palette[candidate][channel]) ** 2 for channel in range(3)),
            )
        indices |= index << (pixel_index * 2)
    return struct.pack("<HHI", color0, color1, indices)


def _bc3_alpha_block(pixels: list[tuple[int, int, int, int]]) -> bytes:
    alphas = [pixel[3] for pixel in pixels]
    alpha0, alpha1 = max(alphas), min(alphas)
    if alpha0 == alpha1:
        palette = (alpha0,) * 8
    else:
        palette = (alpha0, alpha1) + tuple(round((alpha0 * (7 - step) + alpha1 * step) / 7) for step in range(1, 7))
    indices = 0
    for pixel_index, alpha in enumerate(alphas):
        index = min(range(8), key=lambda candidate: abs(alpha - palette[candidate]))
        indices |= index << (pixel_index * 3)
    return bytes((alpha0, alpha1)) + indices.to_bytes(6, "little")


def compress_bgra_level(data: bytes, width: int, height: int, mode: str, alpha_cutoff: float = 0.5) -> bytes:
    if len(data) != width * height * 4:
        raise ValueError("mip data length does not match its dimensions")
    mode = mode.upper()
    if mode not in {"OPAQUE", "MASK", "BLEND"}:
        raise ValueError(f"unsupported alpha mode: {mode}")
    cutoff = max(0, min(255, round(alpha_cutoff * 255)))
    output = bytearray()
    for block_y in range((height + 3) // 4):
        for block_x in range((width + 3) // 4):
            pixels = _block_pixels(data, width, height, block_x, block_y)
            if mode == "BLEND":
                output.extend(_bc3_alpha_block(pixels))
                output.extend(_bc1_block(pixels, False, cutoff))
            else:
                output.extend(_bc1_block(pixels, mode == "MASK", cutoff))
    return bytes(output)


def build_dxt_mip_chain(
    base: bytes,
    width: int,
    height: int,
    mode: str,
    alpha_cutoff: float | None = None,
) -> list[bytes]:
    rgba_levels = build_bgra_mip_chain(base, width, height, mode)
    dimensions = mip_dimensions(width, height)
    cutoff = 0.5 if alpha_cutoff is None else alpha_cutoff
    return [
        compress_bgra_level(level, level_width, level_height, mode, cutoff)
        for level, (level_width, level_height) in zip(rgba_levels, dimensions)
    ]
