from __future__ import annotations

from dataclasses import dataclass

from .binary import u32le


@dataclass(frozen=True)
class StripEntryRecord:
    raw: bytes
    texture_index_raw: int
    texture_index: int | None
    vif_offset: int
    qword_count: int
    qword_size: int
    render_flags: int
    word_1c: int
    topology_code: int
    packed_material_or_render_index: int
    vertex_count_byte: int
    count_byte: int
    packed_ff_or_zero: int


def parse_strip_entry_record(record: bytes) -> StripEntryRecord:
    if len(record) != 0x40:
        raise ValueError(f"strip-entry record must be 0x40 bytes, got {len(record)}")

    texture_index_raw = u32le(record, 0)
    qword_word = u32le(record, 0x0C)
    word_1c = u32le(record, 0x1C)
    qword_count = qword_word & 0xFFFF
    return StripEntryRecord(
        raw=bytes(record),
        texture_index_raw=texture_index_raw,
        texture_index=texture_index_raw if texture_index_raw != 0xFFFFFFFF else None,
        vif_offset=u32le(record, 0x08),
        qword_count=qword_count,
        qword_size=qword_count * 16,
        render_flags=(qword_word >> 16) & 0xFFFF,
        word_1c=word_1c,
        topology_code=word_1c & 0xFF,
        packed_material_or_render_index=word_1c & 0xFF,
        vertex_count_byte=(word_1c >> 8) & 0xFF,
        count_byte=(word_1c >> 16) & 0xFF,
        packed_ff_or_zero=(word_1c >> 24) & 0xFF,
    )
