from __future__ import annotations

import struct
from io import BytesIO
from typing import List, Optional, Tuple

from PIL import Image


class FshPixelSection:
    def __init__(self, fmt: int, width: int, height: int, mip_levels: int, pixels: bytes) -> None:
        self.fmt = fmt
        self.width = width
        self.height = height
        self.mip_levels = mip_levels
        self.pixels = pixels


class FshImageRecord:
    def __init__(self, tag: str, name: Optional[str], pixel_sections: List[FshPixelSection]) -> None:
        self.tag = tag
        self.name = name
        self.pixel_sections = pixel_sections


class FshArchive:
    SECTION_COMMENT = 0x6F
    SECTION_NAME = 0x70
    SECTION_METALBIN = 0x69
    SECTION_HOTSPOT = 0x7C

    PIXEL_8888 = 0x7D
    PIXEL_888 = 0x7F
    PIXEL_4444 = 0x6D
    PIXEL_5551 = 0x7E
    PIXEL_565 = 0x78
    PIXEL_PAL8 = 0x7B
    PIXEL_DXT1 = 0x60
    PIXEL_DXT3 = 0x61
    PIXEL_DXT5 = 0x62
    PIXEL_P24 = 0x24
    PIXEL_P32 = 0x2A
    PIXEL_P32_PSP = 0x3B

    def __init__(self, data: bytes, source: str) -> None:
        self.data = data
        self.source = source
        self.images = self._parse()

    def _parse(self) -> List[FshImageRecord]:
        sig, _total, count, _tag = struct.unpack_from("<4sII4s", self.data, 0)
        if sig != b"SHPI":
            raise ValueError(f"{self.source} is not an SHPI/FSH file")

        image_headers: List[Tuple[str, int]] = []
        off = 16
        for _ in range(count):
            tag_bytes, image_off = struct.unpack_from("<4sI", self.data, off)
            image_headers.append((tag_bytes.decode("latin1"), image_off))
            off += 8

        images: List[FshImageRecord] = []
        for index, (tag, image_off) in enumerate(image_headers):
            current = image_off
            name: Optional[str] = None
            pixel_sections: List[FshPixelSection] = []
            while True:
                section_header = struct.unpack_from("<I", self.data, current)[0]
                section_id = section_header & 0xFF
                next_section_offset = (section_header >> 8) & 0xFFFFFF
                section_size = 0
                if next_section_offset > 4:
                    section_size = next_section_offset - 4
                elif next_section_offset == 0:
                    next_image_off = image_headers[index + 1][1] if index + 1 < len(image_headers) else len(self.data)
                    section_size = max(0, next_image_off - current - 4)

                payload_off = current + 4
                if section_id == self.SECTION_NAME:
                    end = self.data.index(b"\x00", payload_off)
                    name = self.data[payload_off:end].decode("latin1", errors="ignore")
                elif (section_id & 0x80) == 0 and section_size >= 12:
                    width, height, _center_x, _center_y, packed = struct.unpack_from("<HHHHI", self.data, payload_off)
                    mip_levels = (packed >> 28) & 0xF
                    pixels = self.data[payload_off + 12 : payload_off + section_size]
                    pixel_sections.append(FshPixelSection(section_id, width, height, mip_levels, pixels))

                if next_section_offset == 0:
                    break
                current += next_section_offset

            images.append(FshImageRecord(tag=tag, name=name, pixel_sections=pixel_sections))
        return images


def rgb565_to_rgba(color: int) -> Tuple[int, int, int, int]:
    r = ((color >> 11) & 0x1F) * 255 // 31
    g = ((color >> 5) & 0x3F) * 255 // 63
    b = (color & 0x1F) * 255 // 31
    return (r, g, b, 255)


def decode_dxt1(width: int, height: int, data: bytes) -> bytes:
    out = bytearray(width * height * 4)
    blocks_w = (width + 3) // 4
    blocks_h = (height + 3) // 4
    cursor = 0
    for by in range(blocks_h):
        for bx in range(blocks_w):
            c0, c1, bits = struct.unpack_from("<HHI", data, cursor)
            cursor += 8
            palette = [rgb565_to_rgba(c0), rgb565_to_rgba(c1)]
            if c0 > c1:
                palette.append(tuple((2 * palette[0][i] + palette[1][i]) // 3 for i in range(4)))
                palette.append(tuple((palette[0][i] + 2 * palette[1][i]) // 3 for i in range(4)))
            else:
                palette.append(tuple((palette[0][i] + palette[1][i]) // 2 for i in range(4)))
                palette.append((0, 0, 0, 0))
            for py in range(4):
                for px in range(4):
                    x = bx * 4 + px
                    y = by * 4 + py
                    if x >= width or y >= height:
                        continue
                    index = (bits >> (2 * (py * 4 + px))) & 0x3
                    rgba = palette[index]
                    out[(y * width + x) * 4 : (y * width + x + 1) * 4] = bytes(rgba)
    return bytes(out)


def decode_dxt3(width: int, height: int, data: bytes) -> bytes:
    out = bytearray(width * height * 4)
    blocks_w = (width + 3) // 4
    blocks_h = (height + 3) // 4
    cursor = 0
    for by in range(blocks_h):
        for bx in range(blocks_w):
            alpha_bytes = data[cursor : cursor + 8]
            cursor += 8
            c0, c1, bits = struct.unpack_from("<HHI", data, cursor)
            cursor += 8
            palette = [rgb565_to_rgba(c0), rgb565_to_rgba(c1)]
            palette.append(tuple((2 * palette[0][i] + palette[1][i]) // 3 for i in range(4)))
            palette.append(tuple((palette[0][i] + 2 * palette[1][i]) // 3 for i in range(4)))
            alpha_value = int.from_bytes(alpha_bytes, "little")
            for py in range(4):
                for px in range(4):
                    x = bx * 4 + px
                    y = by * 4 + py
                    if x >= width or y >= height:
                        continue
                    rgb_index = (bits >> (2 * (py * 4 + px))) & 0x3
                    a = ((alpha_value >> (4 * (py * 4 + px))) & 0xF) * 17
                    rgba = list(palette[rgb_index])
                    rgba[3] = a
                    out[(y * width + x) * 4 : (y * width + x + 1) * 4] = bytes(rgba)
    return bytes(out)


def decode_dxt5(width: int, height: int, data: bytes) -> bytes:
    out = bytearray(width * height * 4)
    blocks_w = (width + 3) // 4
    blocks_h = (height + 3) // 4
    cursor = 0
    for by in range(blocks_h):
        for bx in range(blocks_w):
            a0 = data[cursor]
            a1 = data[cursor + 1]
            alpha_bits = int.from_bytes(data[cursor + 2 : cursor + 8], "little")
            cursor += 8
            c0, c1, bits = struct.unpack_from("<HHI", data, cursor)
            cursor += 8

            alpha_palette = [a0, a1]
            if a0 > a1:
                alpha_palette.extend(
                    [
                        (6 * a0 + 1 * a1) // 7,
                        (5 * a0 + 2 * a1) // 7,
                        (4 * a0 + 3 * a1) // 7,
                        (3 * a0 + 4 * a1) // 7,
                        (2 * a0 + 5 * a1) // 7,
                        (1 * a0 + 6 * a1) // 7,
                    ]
                )
            else:
                alpha_palette.extend(
                    [
                        (4 * a0 + 1 * a1) // 5,
                        (3 * a0 + 2 * a1) // 5,
                        (2 * a0 + 3 * a1) // 5,
                        (1 * a0 + 4 * a1) // 5,
                        0,
                        255,
                    ]
                )

            palette = [rgb565_to_rgba(c0), rgb565_to_rgba(c1)]
            palette.append(tuple((2 * palette[0][i] + palette[1][i]) // 3 for i in range(4)))
            palette.append(tuple((palette[0][i] + 2 * palette[1][i]) // 3 for i in range(4)))

            for py in range(4):
                for px in range(4):
                    x = bx * 4 + px
                    y = by * 4 + py
                    if x >= width or y >= height:
                        continue
                    p = py * 4 + px
                    rgb_index = (bits >> (2 * p)) & 0x3
                    alpha_index = (alpha_bits >> (3 * p)) & 0x7
                    rgba = list(palette[rgb_index])
                    rgba[3] = alpha_palette[alpha_index]
                    out[(y * width + x) * 4 : (y * width + x + 1) * 4] = bytes(rgba)
    return bytes(out)


def decode_argb8888(width: int, height: int, data: bytes) -> bytes:
    out = bytearray(width * height * 4)
    for i in range(width * height):
        b, g, r, a = data[i * 4 : i * 4 + 4]
        out[i * 4 : i * 4 + 4] = bytes((r, g, b, a))
    return bytes(out)


def decode_bgr888(width: int, height: int, data: bytes) -> bytes:
    out = bytearray(width * height * 4)
    for i in range(width * height):
        b, g, r = data[i * 3 : i * 3 + 3]
        out[i * 4 : i * 4 + 4] = bytes((r, g, b, 255))
    return bytes(out)


def decode_4444(width: int, height: int, data: bytes) -> bytes:
    out = bytearray(width * height * 4)
    for i in range(width * height):
        value = struct.unpack_from("<H", data, i * 2)[0]
        a = ((value >> 12) & 0xF) * 17
        r = ((value >> 8) & 0xF) * 17
        g = ((value >> 4) & 0xF) * 17
        b = (value & 0xF) * 17
        out[i * 4 : i * 4 + 4] = bytes((r, g, b, a))
    return bytes(out)


def decode_5551(width: int, height: int, data: bytes) -> bytes:
    out = bytearray(width * height * 4)
    for i in range(width * height):
        value = struct.unpack_from("<H", data, i * 2)[0]
        a = 255 if (value & 0x8000) else 0
        r = ((value >> 10) & 0x1F) * 255 // 31
        g = ((value >> 5) & 0x1F) * 255 // 31
        b = (value & 0x1F) * 255 // 31
        out[i * 4 : i * 4 + 4] = bytes((r, g, b, a))
    return bytes(out)


def decode_565(width: int, height: int, data: bytes) -> bytes:
    out = bytearray(width * height * 4)
    for i in range(width * height):
        value = struct.unpack_from("<H", data, i * 2)[0]
        r = ((value >> 11) & 0x1F) * 255 // 31
        g = ((value >> 5) & 0x3F) * 255 // 63
        b = (value & 0x1F) * 255 // 31
        out[i * 4 : i * 4 + 4] = bytes((r, g, b, 255))
    return bytes(out)


def decode_pal8(width: int, height: int, indices: bytes, palette: bytes, has_alpha: bool) -> bytes:
    step = 4 if has_alpha else 3
    out = bytearray(width * height * 4)
    for i in range(width * height):
        idx = indices[i]
        entry = palette[idx * step : idx * step + step]
        if has_alpha:
            r, g, b, a = entry
        else:
            r, g, b = entry
            a = 255
        out[i * 4 : i * 4 + 4] = bytes((r, g, b, a))
    return bytes(out)


def decode_fsh_image(record: FshImageRecord) -> Optional[bytes]:
    palette_rgb = None
    palette_rgba = None
    image_pixels = None
    for section in record.pixel_sections:
        if section.fmt == FshArchive.PIXEL_P24:
            palette_rgb = section.pixels
        elif section.fmt in (FshArchive.PIXEL_P32, FshArchive.PIXEL_P32_PSP):
            palette_rgba = section.pixels
        elif image_pixels is None:
            image_pixels = section

    if image_pixels is None:
        return None

    width = image_pixels.width
    height = image_pixels.height
    pixels = image_pixels.pixels

    top_size = {
        FshArchive.PIXEL_8888: width * height * 4,
        FshArchive.PIXEL_888: width * height * 3,
        FshArchive.PIXEL_4444: width * height * 2,
        FshArchive.PIXEL_5551: width * height * 2,
        FshArchive.PIXEL_565: width * height * 2,
        FshArchive.PIXEL_PAL8: width * height,
        FshArchive.PIXEL_DXT1: ((width + 3) // 4) * ((height + 3) // 4) * 8,
        FshArchive.PIXEL_DXT3: ((width + 3) // 4) * ((height + 3) // 4) * 16,
        FshArchive.PIXEL_DXT5: ((width + 3) // 4) * ((height + 3) // 4) * 16,
    }.get(image_pixels.fmt)
    if top_size is None or len(pixels) < top_size:
        return None
    pixels = pixels[:top_size]

    if image_pixels.fmt == FshArchive.PIXEL_8888:
        rgba = decode_argb8888(width, height, pixels)
    elif image_pixels.fmt == FshArchive.PIXEL_888:
        rgba = decode_bgr888(width, height, pixels)
    elif image_pixels.fmt == FshArchive.PIXEL_4444:
        rgba = decode_4444(width, height, pixels)
    elif image_pixels.fmt == FshArchive.PIXEL_5551:
        rgba = decode_5551(width, height, pixels)
    elif image_pixels.fmt == FshArchive.PIXEL_565:
        rgba = decode_565(width, height, pixels)
    elif image_pixels.fmt == FshArchive.PIXEL_PAL8:
        if palette_rgba is not None:
            rgba = decode_pal8(width, height, pixels, palette_rgba, True)
        elif palette_rgb is not None:
            rgba = decode_pal8(width, height, pixels, palette_rgb, False)
        else:
            return None
    elif image_pixels.fmt == FshArchive.PIXEL_DXT1:
        rgba = decode_dxt1(width, height, pixels)
    elif image_pixels.fmt == FshArchive.PIXEL_DXT3:
        rgba = decode_dxt3(width, height, pixels)
    elif image_pixels.fmt == FshArchive.PIXEL_DXT5:
        rgba = decode_dxt5(width, height, pixels)
    else:
        return None

    image = Image.frombytes("RGBA", (width, height), rgba)
    buf = BytesIO()
    image.save(buf, format="PNG")
    return buf.getvalue()
