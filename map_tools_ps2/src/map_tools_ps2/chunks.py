from __future__ import annotations

from dataclasses import dataclass, field
from typing import Iterable

from .binary import u32le


@dataclass(frozen=True)
class Chunk:
    chunk_id: int
    size: int
    offset: int
    data_offset: int
    children: tuple["Chunk", ...] = field(default_factory=tuple)

    @property
    def end_offset(self) -> int:
        return self.data_offset + self.size

    @property
    def is_parent(self) -> bool:
        return bool(self.chunk_id & 0x80000000)

    def payload(self, bundle: bytes) -> bytes:
        return bundle[self.data_offset : self.end_offset]


def parse_chunks(data: bytes, start: int = 0, end: int | None = None) -> tuple[Chunk, ...]:
    if end is None:
        end = len(data)
    chunks: list[Chunk] = []
    pos = start
    while pos + 8 <= end:
        chunk_id = u32le(data, pos)
        size = u32le(data, pos + 4)
        data_offset = pos + 8
        chunk_end = data_offset + size
        if chunk_end > end:
            raise ValueError(
                f"chunk 0x{chunk_id:08x} at 0x{pos:x} ends at 0x{chunk_end:x}, beyond 0x{end:x}"
            )
        children: tuple[Chunk, ...] = ()
        if chunk_id & 0x80000000:
            children = parse_chunks(data, data_offset, chunk_end)
        chunks.append(Chunk(chunk_id, size, pos, data_offset, children))
        pos = chunk_end
    if pos != end:
        raise ValueError(f"chunk region ended at 0x{pos:x}, expected 0x{end:x}")
    return tuple(chunks)


def walk_chunks(chunks: Iterable[Chunk]) -> Iterable[Chunk]:
    for chunk in chunks:
        yield chunk
        yield from walk_chunks(chunk.children)


def format_chunk_tree(chunks: Iterable[Chunk], depth: int = 0) -> str:
    lines: list[str] = []
    for chunk in chunks:
        lines.append(
            f"{'  ' * depth}0x{chunk.offset:08x} 0x{chunk.chunk_id:08x} size=0x{chunk.size:08x}"
        )
        if chunk.children:
            lines.append(format_chunk_tree(chunk.children, depth + 1))
    return "\n".join(line for line in lines if line)
