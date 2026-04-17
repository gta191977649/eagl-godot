from __future__ import annotations

import struct
from pathlib import Path
from typing import Dict, List

from ..models import Symbol


class ElfObject:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.file_bytes = path.read_bytes()
        if self.file_bytes[:4] != b"\x7fELF":
            raise ValueError(f"{path} is not an ELF file")

        self.data = b""
        self.data_index = 0
        self.symbols: List[Symbol] = []
        self.relocations: Dict[int, Symbol] = {}
        self._parse()

    def _parse(self) -> None:
        ehdr = struct.unpack_from("<16sHHIIIIIHHHHHH", self.file_bytes, 0)
        _, _, _, _, _, _, shoff, _, _, _, _, shentsize, shnum, _ = ehdr

        sections = []
        for i in range(shnum):
            off = shoff + i * shentsize
            sh = struct.unpack_from("<IIIIIIIIII", self.file_bytes, off)
            sections.append(
                {
                    "name": sh[0],
                    "type": sh[1],
                    "flags": sh[2],
                    "addr": sh[3],
                    "offset": sh[4],
                    "size": sh[5],
                    "link": sh[6],
                    "info": sh[7],
                    "addralign": sh[8],
                    "entsize": sh[9],
                }
            )

        symtab = None
        relsec = None
        for idx, sec in enumerate(sections):
            if sec["size"] <= 0:
                continue
            if sec["type"] == 1 and not self.data:
                self.data = self.file_bytes[sec["offset"] : sec["offset"] + sec["size"]]
                self.data_index = idx
            elif sec["type"] == 2:
                symtab = sec
            elif sec["type"] == 9:
                relsec = sec

        if not self.data or symtab is None:
            raise ValueError(f"Unable to locate required sections in {self.path}")

        strtab = sections[symtab["link"]] if 0 <= symtab["link"] < len(sections) else None
        if strtab is None or strtab["type"] != 3:
            raise ValueError(f"Unable to locate symbol string table in {self.path}")

        strings = self.file_bytes[strtab["offset"] : strtab["offset"] + strtab["size"]]
        sym_count = symtab["size"] // 16
        for i in range(sym_count):
            off = symtab["offset"] + i * 16
            st_name, st_value, st_size, st_info, _st_other, st_shndx = struct.unpack_from(
                "<IIIBBH", self.file_bytes, off
            )
            end = strings.find(b"\x00", st_name)
            if st_name >= len(strings):
                name = ""
            elif end == -1:
                name = strings[st_name:].decode("latin1", errors="ignore")
            else:
                name = strings[st_name:end].decode("latin1", errors="ignore")
            self.symbols.append(Symbol(name=name, value=st_value, size=st_size, info=st_info, shndx=st_shndx))

        if relsec is not None:
            rel_count = relsec["size"] // 8
            for i in range(rel_count):
                off = relsec["offset"] + i * 8
                r_offset, r_info = struct.unpack_from("<II", self.file_bytes, off)
                sym_id = r_info >> 8
                if sym_id < len(self.symbols):
                    self.relocations[r_offset] = self.symbols[sym_id]

    def u8(self, offset: int) -> int:
        return self.data[offset]

    def u16(self, offset: int) -> int:
        return struct.unpack_from("<H", self.data, offset)[0]

    def u32(self, offset: int) -> int:
        return struct.unpack_from("<I", self.data, offset)[0]

    def bytes_at(self, offset: int, length: int) -> bytes:
        return self.data[offset : offset + length]

    def cstring(self, offset: int) -> str:
        end = self.data.find(b"\x00", offset)
        if end == -1:
            end = len(self.data)
        return self.data[offset:end].decode("latin1", errors="ignore")

    def data_symbol(self, prefix: str) -> List[Symbol]:
        out = []
        for sym in self.symbols:
            if sym.name.startswith(prefix) and (sym.info & 0xF) != 0 and sym.shndx == self.data_index:
                out.append(sym)
        return out
