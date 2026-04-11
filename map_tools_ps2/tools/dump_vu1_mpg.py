#!/usr/bin/env python3
from __future__ import annotations

import argparse
import struct
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Section:
    name: str
    vaddr: int
    offset: int
    size: int


@dataclass(frozen=True)
class MpgBlock:
    command_offset: int
    vu_addr: int
    instruction_count: int
    data_offset: int


HP2_VU1_ANNOTATIONS: dict[int, str] = {
    0x0000: "entry 0: mesh packet path; branches into render/output control",
    0x0006: "matrix-precompute path A: select uploaded matrix at VU addr 0x348",
    0x0008: "matrix-precompute path A: select render constants at VU addr 0x330",
    0x0009: "matrix-precompute path B: select uploaded matrix at VU addr 0x34c",
    0x000b: "matrix-precompute path B: select render constants at VU addr 0x330",
    0x000c: "matrix-precompute path C: select uploaded matrix at VU addr 0x348",
    0x000e: "matrix-precompute path C: select render constants at VU addr 0x33c",
    0x000f: "matrix-precompute path D: select uploaded matrix at VU addr 0x34c",
    0x0011: "matrix-precompute path D: select render constants at VU addr 0x33c",
    0x0018: "load uploaded matrix row 0 from selected 0x348/0x34c block",
    0x0019: "load render/projection row 0 from selected 0x330/0x33c block",
    0x001a: "load render/projection row 1 from selected 0x330/0x33c block",
    0x001b: "load render/projection row 2 from selected 0x330/0x33c block",
    0x001c: "load render/projection row 3 from selected 0x330/0x33c block",
    0x001d: "begin row 0 multiply: ACC = const row 0 * matrix row 0.x",
    0x0021: "begin row 1 multiply against render/projection constants",
    0x0025: "begin row 2 multiply against render/projection constants",
    0x0029: "begin row 3 multiply; also loads rows 4..7 for viewport/output constants",
    0x0034: "return from matrix precompute; composed rows are resident for entry 0",
    0x004d: "entry 0 render flags/output-control path begins",
    0x0068: "GS kick path: XGKICK output buffer at VU addr 0x308",
    0x0073: "GS kick path: XGKICK output buffer at VU addr 0x320",
    0x0083: "GS kick path: XGKICK output buffer at VU addr 0x318 plus flag offset",
    0x00c3: "main mesh loop: read packet vertex count/header from XTOP-relative VU memory",
    0x013a: "packet decode subroutine: XTOP selects the original uploaded VIF packet",
    0x013c: "load constant at VU addr 0x298",
    0x013d: "load constant at VU addr 0x299",
    0x0141: "load source packet vectors relative to XTOP",
    0x0146: "load precomputed transform/viewport row at VU addr 0x338",
    0x0147: "load precomputed transform/viewport row at VU addr 0x339",
    0x0160: "begin SIMD vertex transform/projection group",
    0x0170: "projection rows feed clip/output values",
    0x017c: "read clip flags for four SIMD lanes",
    0x0180: "store per-lane clipping flags at VU addr 0x2a2",
    0x018f: "pack accepted transformed vertices for GIF/GS output",
    0x01a4: "prepare GS output buffer at VU addr 0x308",
}


def read_sections(data: bytes) -> tuple[Section, ...]:
    if data[:4] != b"\x7fELF" or data[4] != 1 or data[5] != 1:
        raise ValueError("expected a little-endian ELF32 file")

    section_header_offset = struct.unpack_from("<I", data, 0x20)[0]
    section_header_size = struct.unpack_from("<H", data, 0x2E)[0]
    section_count = struct.unpack_from("<H", data, 0x30)[0]
    section_names_index = struct.unpack_from("<H", data, 0x32)[0]
    names_header = section_header_offset + section_names_index * section_header_size
    names_offset = struct.unpack_from("<I", data, names_header + 0x10)[0]
    names_size = struct.unpack_from("<I", data, names_header + 0x14)[0]
    names = data[names_offset : names_offset + names_size]

    sections: list[Section] = []
    for index in range(section_count):
        header = section_header_offset + index * section_header_size
        name_offset, _, _, vaddr, offset, size = struct.unpack_from("<IIIIII", data, header)
        name_end = names.find(b"\0", name_offset)
        name = names[name_offset:name_end].decode("ascii", errors="replace")
        sections.append(Section(name, vaddr, offset, size))
    return tuple(sections)


def vaddr_to_file_offset(sections: tuple[Section, ...], vaddr: int) -> int:
    for section in sections:
        if section.vaddr <= vaddr < section.vaddr + section.size:
            return section.offset + (vaddr - section.vaddr)
    raise ValueError(f"virtual address 0x{vaddr:x} is not inside any ELF section")


def iter_mpg_blocks(data: bytes, upload_offset: int) -> tuple[MpgBlock, ...]:
    qwc = struct.unpack_from("<I", data, upload_offset)[0] & 0xFFFF
    pos = upload_offset + 16
    end = pos + qwc * 16
    blocks: list[MpgBlock] = []

    while pos + 4 <= end and pos + 4 <= len(data):
        imm, count, command = struct.unpack_from("<HBB", data, pos)
        command_offset = pos
        pos += 4
        if command == 0x4A:
            instruction_count = 256 if count == 0 else count
            data_size = instruction_count * 8
            blocks.append(MpgBlock(command_offset, imm, instruction_count, pos))
            pos += data_size
            continue
        if command == 0x00:
            continue
        # This tool only needs to locate MPG payloads in the upload packet. Other VIF
        # commands in the same DMA packet are state setup words, so step one word.
    return tuple(blocks)


def instruction_at(data: bytes, block: MpgBlock, index: int) -> tuple[int, int]:
    offset = block.data_offset + index * 8
    lower, upper = struct.unpack_from("<II", data, offset)
    return upper, lower


def dump_block(data: bytes, block: MpgBlock, start: int, count: int, annotate: bool) -> None:
    stop = min(block.instruction_count, start + count)
    for index in range(start, stop):
        vu_pc = block.vu_addr + index
        upper, lower = instruction_at(data, block, index)
        suffix = ""
        if annotate and vu_pc in HP2_VU1_ANNOTATIONS:
            suffix = f"  ; {HP2_VU1_ANNOTATIONS[vu_pc]}"
        print(f"{vu_pc:04x}: upper={upper:08x} lower={lower:08x}{suffix}")


def parse_int(value: str) -> int:
    return int(value, 0)


def main() -> int:
    parser = argparse.ArgumentParser(description="Dump MPG-uploaded VU1 microprogram words from HP2's PS2 ELF")
    parser.add_argument("elf", type=Path, help="SLUS_203.62 or another PS2 ELF")
    parser.add_argument("--upload-vaddr", type=parse_int, default=0x002A6940)
    parser.add_argument("--block", type=int, default=0, help="MPG block index to dump")
    parser.add_argument("--start", type=parse_int, default=0)
    parser.add_argument("--count", type=parse_int, default=0x80)
    parser.add_argument("--annotate-hp2", action="store_true", help="add HP2-specific semantic notes")
    args = parser.parse_args()

    data = args.elf.read_bytes()
    sections = read_sections(data)
    upload_offset = vaddr_to_file_offset(sections, args.upload_vaddr)
    blocks = iter_mpg_blocks(data, upload_offset)
    print(f"upload_vaddr=0x{args.upload_vaddr:x} file_offset=0x{upload_offset:x} mpg_blocks={len(blocks)}")
    for index, block in enumerate(blocks):
        rel = block.command_offset - upload_offset
        print(
            f"block[{index}] cmd_rel=0x{rel:x} vu_addr=0x{block.vu_addr:x} "
            f"instructions={block.instruction_count} data_rel=0x{block.data_offset - upload_offset:x}"
        )

    if args.block < 0 or args.block >= len(blocks):
        raise SystemExit(f"block {args.block} is outside 0..{len(blocks) - 1}")

    dump_block(data, blocks[args.block], args.start, args.count, args.annotate_hp2)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
