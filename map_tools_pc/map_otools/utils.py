from __future__ import annotations

import re
from pathlib import Path
from typing import Optional


def align(value: int, boundary: int) -> int:
    return (value + (boundary - 1)) & ~(boundary - 1)


def safe_name(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", name)


def resolve_tracks_root(input_path: Path) -> Optional[Path]:
    if (input_path / "Tracks.ini").exists():
        return input_path
    if (input_path / "tracks" / "Tracks.ini").exists():
        return input_path / "tracks"
    return None
