from __future__ import annotations

import configparser
from pathlib import Path
from typing import Dict, List, Optional

from .models import PlayableTrack


class TrackCatalog:
    def __init__(self, tracks_root: Path) -> None:
        self.tracks_root = tracks_root
        self.tracks = self._load()
        self.by_name: Dict[str, List[PlayableTrack]] = {}
        for track in self.tracks:
            self.by_name.setdefault(track.name.lower(), []).append(track)

    def _load(self) -> List[PlayableTrack]:
        cfg = configparser.ConfigParser()
        cfg.optionxform = str
        ini_path = self.tracks_root / "Tracks.ini"
        if not ini_path.exists():
            raise ValueError(f"Tracks.ini not found under {self.tracks_root}")
        cfg.read(ini_path, encoding="latin1")

        raw_tracks = []
        for section in cfg.sections():
            raw_tracks.append(
                {
                    "section": section,
                    "track_id": cfg.getint(section, "id"),
                    "name": cfg.get(section, "name"),
                    "display_name": cfg.get(section, "displayName", fallback=section),
                    "loop": cfg.getint(section, "loop", fallback=None),
                    "length": cfg.getfloat(section, "length", fallback=None),
                }
            )

        raw_tracks.sort(key=lambda item: item["track_id"])
        name_counts: Dict[str, int] = {}
        tracks: List[PlayableTrack] = []
        for item in raw_tracks:
            key = item["name"].lower()
            name_counts[key] = name_counts.get(key, 0) + 1
            tracks.append(
                PlayableTrack(
                    section=item["section"],
                    track_id=item["track_id"],
                    name=item["name"],
                    display_name=item["display_name"],
                    loop=item["loop"],
                    length=item["length"],
                    name_variant_index=name_counts[key],
                )
            )
        return tracks

    def get_by_id(self, track_id: int) -> PlayableTrack:
        for track in self.tracks:
            if track.track_id == track_id:
                return track
        raise ValueError(f"Track id {track_id} not found")

    def get_by_name(self, display_name: str) -> PlayableTrack:
        for track in self.tracks:
            if track.display_name.lower() == display_name.lower():
                return track
        raise ValueError(f"Track name {display_name} not found")

    def name_tracks(self, name: str) -> List[PlayableTrack]:
        tracks = self.by_name.get(name.lower())
        if not tracks:
            raise ValueError(f"No playable tracks found for name {name}")
        return sorted(tracks, key=lambda item: item.name_variant_index)

    def resolve_name_variant(self, name: str, variant_index: int) -> PlayableTrack:
        tracks = self.name_tracks(name)
        if variant_index < 1 or variant_index > len(tracks):
            raise ValueError(f"Variant {variant_index} is out of range for name {name}; expected 1..{len(tracks)}")
        return tracks[variant_index - 1]
