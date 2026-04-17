from __future__ import annotations

import struct
from pathlib import Path
from typing import List

from ..models import (
    LevelDat,
    LevelFtRecord,
    LevelGroupRecord,
    LevelLinkRecord,
    LevelNamedObjectRecord,
    LevelPlacementRecord,
    Vec3,
)


SECTION_SIZES = (0x24, 0x14, 0x78, 0x38, 0x44, 0x74, 0x10, 0x24, 0x0C)


def _read_cstring(blob: bytes) -> str:
    return blob.split(b"\x00", 1)[0].decode("latin1", errors="ignore")


def parse_level_dat(path: Path) -> LevelDat:
    data = path.read_bytes()
    offset = 0
    tables: List[List[bytes]] = []
    for size in SECTION_SIZES:
        count = struct.unpack_from("<I", data, offset)[0]
        offset += 4
        table = []
        for _ in range(count):
            table.append(data[offset : offset + size])
            offset += size
        tables.append(table)

    placements = []
    for record in tables[0]:
        values = struct.unpack("<7fII", record)
        placements.append(LevelPlacementRecord(*values))

    links = []
    for record in tables[1]:
        links.append(LevelLinkRecord(*struct.unpack("<IIiii", record)))

    named_objects = []
    for record in tables[2]:
        named_objects.append(
            LevelNamedObjectRecord(
                primary_name=_read_cstring(record[0x00:0x14]),
                secondary_name=_read_cstring(record[0x50:0x78]),
                raw=record,
            )
        )

    levelft = []
    for record in tables[3]:
        levelft.append(LevelFtRecord(model_id=_read_cstring(record[0x00:0x0C]), raw=record))

    groups = []
    for record in tables[7]:
        groups.append(LevelGroupRecord(*struct.unpack("<9I", record)))

    points = []
    for record in tables[8]:
        points.append(Vec3(*struct.unpack("<3f", record)))

    return LevelDat(
        placement_records=placements,
        link_records=links,
        named_object_records=named_objects,
        levelft_records=levelft,
        table4_records=tables[4],
        table5_records=tables[5],
        table6_records=tables[6],
        group_records=groups,
        point_records=points,
    )
