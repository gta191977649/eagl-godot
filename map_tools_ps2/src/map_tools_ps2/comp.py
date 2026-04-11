from __future__ import annotations

import struct
from dataclasses import dataclass
from pathlib import Path


class CompError(ValueError):
    pass


@dataclass(frozen=True)
class CompHeader:
    flags: int
    decompressed_size: int
    compressed_size: int


def read_comp_header(data: bytes) -> CompHeader:
    if len(data) < 16:
        raise CompError("COMP file is shorter than its 16-byte header")
    if data[:4] != b"COMP":
        raise CompError("missing COMP signature")
    flags, decompressed_size, compressed_size = struct.unpack_from("<III", data, 4)
    if compressed_size and compressed_size != len(data):
        raise CompError(
            f"COMP header compressed size {compressed_size} does not match file size {len(data)}"
        )
    return CompHeader(flags=flags, decompressed_size=decompressed_size, compressed_size=compressed_size)


def ea_comp_decompress_payload(payload: bytes, decompressed_size: int) -> bytes:
    out = bytearray()
    src = 0
    flags = 1
    payload_size = len(payload)

    while src < payload_size and len(out) < decompressed_size:
        if flags == 1:
            if src + 2 > payload_size:
                raise CompError("truncated ea_comp flag word")
            flags = (payload[src] | (payload[src + 1] << 8)) | 0x10000
            src += 2

        cycles = 1 if (payload_size - 32) < src else 16
        for _ in range(cycles):
            if src >= payload_size or len(out) >= decompressed_size:
                break

            if flags & 1:
                if src + 2 > payload_size:
                    raise CompError("truncated ea_comp back-reference")
                control = payload[src]
                distance = payload[src + 1] | ((control & 0xF0) << 4)
                src += 2
                if distance == 0 or distance > len(out):
                    raise CompError(f"invalid ea_comp back-reference distance {distance}")
                copy_pos = len(out) - distance
                for _ in range((control & 0x0F) + 3):
                    out.append(out[copy_pos])
                    copy_pos += 1
                    if len(out) >= decompressed_size:
                        break
            else:
                out.append(payload[src])
                src += 1

            flags >>= 1

    if len(out) != decompressed_size:
        raise CompError(f"decompressed {len(out)} bytes, expected {decompressed_size}")
    return bytes(out)


def decompress_lzc(data: bytes) -> bytes:
    header = read_comp_header(data)
    return ea_comp_decompress_payload(data[16:], header.decompressed_size)


def load_bundle_bytes(path: Path) -> bytes:
    data = path.read_bytes()
    if data.startswith(b"COMP"):
        return decompress_lzc(data)
    return data
