from __future__ import annotations

from pathlib import Path
from typing import Optional

from .models import LevelDat, PlayableTrack, RouteContext
from .parsers.drvpath import parse_drvpath
from .parsers.level_dat import parse_level_dat


class RouteResolver:
    def __init__(self, tracks_root: Path) -> None:
        self.tracks_root = tracks_root

    def resolve(self, track: PlayableTrack, level_index: Optional[int] = None) -> tuple[RouteContext, LevelDat]:
        if level_index is None:
            level_index = track.name_variant_index - 1
        return self.resolve_name_level(track.name, level_index, track)

    def resolve_name_level(
        self,
        name: str,
        level_index: int,
        playable_track: Optional[PlayableTrack] = None,
    ) -> tuple[RouteContext, LevelDat]:
        if level_index < 0:
            raise ValueError(f"Level index must be >= 0, got {level_index}")

        name_dir = self.tracks_root / name
        if not name_dir.exists():
            raise ValueError(f"Name folder not found: {name_dir}")

        level_dir = name_dir / f"level{level_index:02d}"
        if not level_dir.exists():
            available = self._available_level_indices(name_dir)
            if available:
                levels = ", ".join(str(value) for value in available)
                raise ValueError(f"Level {level_index} not found for {name}; available levels: {levels}")
            raise ValueError(f"Level folder not found for {name}: {level_dir}")

        drvpath = parse_drvpath(level_dir / "drvpath.ini")
        level_dat = parse_level_dat(level_dir / "level.dat")
        levelft_ids = [record.model_id for record in level_dat.levelft_records if record.model_id]

        context = RouteContext(
            playable_track=playable_track,
            name_dir=name_dir,
            level_dir=level_dir,
            level_index=level_index,
            compartment_ids=drvpath.compartment_ids,
            levelft_ids=levelft_ids,
        )
        return context, level_dat

    def _available_level_indices(self, name_dir: Path) -> list[int]:
        indices = []
        for level_dir in name_dir.glob("level*"):
            suffix = level_dir.name[5:]
            if not suffix.isdigit():
                continue
            try:
                indices.append(int(suffix))
            except ValueError:
                continue
        return sorted(indices)
