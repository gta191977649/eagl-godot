from __future__ import annotations

import math
import struct
from dataclasses import dataclass
from pathlib import Path


SECTOR_SIZE = 2048
DIRECTORY_ENTRY_SIZE = 32


@dataclass(frozen=True)
class ImgEntry:
    name: str
    data: bytes


def _validate_name(name: str) -> bytes:
    try:
        encoded = name.encode("ascii")
    except UnicodeEncodeError as exc:
        raise ValueError(f"IMG entry name is not ASCII: {name!r}") from exc
    # The directory entry holds the name in a 24-byte field that GTA reads as a
    # C string, so a 24-byte name leaves no room for the terminator and the
    # reader runs into the next entry.
    if not encoded or len(encoded) > 23:
        raise ValueError(f"IMG entry name must be 1..23 ASCII bytes: {name!r}")
    if any(value < 0x20 for value in encoded):
        raise ValueError(f"IMG entry name contains control bytes: {name!r}")
    return encoded


def write_img_v2(path: Path, entries: list[ImgEntry]) -> dict[str, int]:
    names: set[str] = set()
    encoded_names: list[bytes] = []
    for entry in entries:
        encoded = _validate_name(entry.name)
        folded = entry.name.lower()
        if folded in names:
            raise ValueError(f"duplicate IMG entry: {entry.name}")
        names.add(folded)
        encoded_names.append(encoded)

    header_size = 8 + len(entries) * DIRECTORY_ENTRY_SIZE
    first_sector = math.ceil(header_size / SECTOR_SIZE)
    offsets: list[int] = []
    sizes: list[int] = []
    cursor = first_sector
    for entry in entries:
        sectors = max(1, math.ceil(len(entry.data) / SECTOR_SIZE))
        offsets.append(cursor)
        sizes.append(sectors)
        cursor += sectors

    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as stream:
        stream.write(struct.pack("<4sI", b"VER2", len(entries)))
        for encoded, offset, size in zip(encoded_names, offsets, sizes):
            stream.write(struct.pack("<II24s", offset, size, encoded))
        stream.write(b"\0" * (first_sector * SECTOR_SIZE - stream.tell()))
        for entry, sectors in zip(entries, sizes):
            stream.write(entry.data)
            stream.write(b"\0" * (sectors * SECTOR_SIZE - len(entry.data)))
    return {"entries": len(entries), "bytes": path.stat().st_size, "sectors": cursor}


def read_img_v2_directory(path: Path) -> list[tuple[int, int, str]]:
    with path.open("rb") as stream:
        magic, count = struct.unpack("<4sI", stream.read(8))
        if magic != b"VER2":
            raise ValueError(f"not an IMG v2 archive: {path}")
        result = []
        for _index in range(count):
            offset, size, raw_name = struct.unpack("<II24s", stream.read(32))
            result.append((offset, size, raw_name.split(b"\0", 1)[0].decode("ascii")))
        return result
