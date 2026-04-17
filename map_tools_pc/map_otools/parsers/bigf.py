from __future__ import annotations

import struct
from pathlib import Path
from typing import Dict


class BigfArchive:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.data = path.read_bytes()
        magic, _size, count, _index_len = struct.unpack_from(">4sIII", self.data, 0)
        if magic != b"BIGF":
            raise ValueError(f"{path} is not a BIGF archive")
        self.entries: Dict[str, bytes] = {}
        off = 16
        for _ in range(count):
            entry_off, entry_size = struct.unpack_from(">II", self.data, off)
            off += 8
            end = self.data.index(b"\x00", off)
            name = self.data[off:end].decode("latin1")
            off = end + 1
            self.entries[name] = self.data[entry_off : entry_off + entry_size]
