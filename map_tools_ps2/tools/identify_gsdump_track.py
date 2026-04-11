#!/usr/bin/env python3
from __future__ import annotations

import argparse
import shutil
import struct
import subprocess
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

from map_tools_ps2.binary import align
from map_tools_ps2.chunks import parse_chunks, walk_chunks


@dataclass(frozen=True)
class GsDumpInfo:
    serial: str
    crc: int
    screenshot_size: tuple[int, int]
    transfer_count: int
    transfer_bytes: int
    event_counts: dict[int, int]
    transfer_blob: bytes
    full_dump: bytes


@dataclass(frozen=True)
class TexturePayload:
    track_id: int
    source_path: Path
    name: str
    width: int
    height: int
    image: bytes
    palette: bytes


@dataclass
class MatchDetail:
    source: str
    texture: str
    score: int
    image_exact: bool
    palette_exact: bool
    image_partial: bool


@dataclass
class TrackScore:
    track_id: int
    score: int = 0
    exact_map_names: list[str] = field(default_factory=list)
    exact_sky_names: list[str] = field(default_factory=list)
    details: list[MatchDetail] = field(default_factory=list)


def main() -> int:
    parser = argparse.ArgumentParser(description="Identify HP2 PS2 track candidates from a PCSX2 GS dump.")
    parser.add_argument("gsdump", type=Path, help=".gs or .gs.zst file")
    parser.add_argument(
        "--tracks-dir",
        type=Path,
        default=Path("/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA/TRACKS"),
        help="directory containing TRACK*.BUN/LZC and TEX*TRACK/LOCATION.BIN",
    )
    parser.add_argument("--top", type=int, default=8, help="number of candidate scores to print")
    args = parser.parse_args()

    with _read_dump_bytes(args.gsdump) as dump_bytes:
        info = parse_gsdump(dump_bytes)
        scores = score_tracks(info, args.tracks_dir)

    print(f"dump: {args.gsdump}")
    print(
        f"serial={info.serial} crc=0x{info.crc:08x} screenshot={info.screenshot_size[0]}x{info.screenshot_size[1]} "
        f"transfers={info.transfer_count} transfer_bytes={info.transfer_bytes}"
    )
    print("event_counts=" + ", ".join(f"{event}:{count}" for event, count in sorted(info.event_counts.items())))

    if not scores:
        print("no texture signatures matched")
        return 1

    print("\ntrack candidates:")
    for score in scores[: args.top]:
        files = _candidate_files(args.tracks_dir, score.track_id)
        markers = []
        if score.exact_map_names:
            markers.append("maps=" + ",".join(score.exact_map_names[:4]))
        if score.exact_sky_names:
            markers.append("sky=" + ",".join(score.exact_sky_names[:4]))
        print(f"  {score.track_id:02d}: score={score.score} {' '.join(markers)}")
        if files:
            print("      files=" + ", ".join(str(path) for path in files))
        for detail in score.details[:6]:
            flags = []
            if detail.image_exact:
                flags.append("image")
            if detail.palette_exact:
                flags.append("palette")
            if detail.image_partial:
                flags.append("partial")
            print(f"      {detail.source}:{detail.texture} +{detail.score} ({'/'.join(flags)})")

    tied = [score.track_id for score in scores if score.score == scores[0].score]
    if len(tied) > 1:
        print(
            "\nambiguous_top_score="
            + ",".join(f"{track_id:02d}" for track_id in tied)
            + " (these tracks share the matched GPU-visible textures)"
        )
    return 0


class _read_dump_bytes:
    def __init__(self, path: Path):
        self.path = path
        self._temp: tempfile.NamedTemporaryFile[bytes] | None = None

    def __enter__(self) -> bytes:
        if self.path.suffix.lower() != ".zst":
            return self.path.read_bytes()

        zstd = shutil.which("zstd")
        if zstd is None:
            raise SystemExit("zstd is required to read .gs.zst dumps")
        self._temp = tempfile.NamedTemporaryFile(prefix="hp2_gsdump_", suffix=".gs")
        with self._temp as out:
            subprocess.run([zstd, "-dc", str(self.path)], check=True, stdout=out)
            out.flush()
            return Path(out.name).read_bytes()

    def __exit__(self, *_exc: object) -> None:
        return None


def parse_gsdump(data: bytes) -> GsDumpInfo:
    if len(data) < 8:
        raise ValueError("GS dump is too small")

    magic, header_size = struct.unpack_from("<II", data, 0)
    if magic != 0xFFFFFFFF:
        raise ValueError("only new-format PCSX2 GS dumps are supported")

    (
        _state_version,
        state_size,
        serial_offset,
        serial_size,
        crc,
        screenshot_width,
        screenshot_height,
        _screenshot_offset,
        _screenshot_size,
    ) = struct.unpack_from("<IIIIIIIII", data, 8)
    header_base = 8
    serial = data[header_base + serial_offset : header_base + serial_offset + serial_size].decode(
        "ascii", errors="replace"
    )

    event_offset = 8 + header_size + state_size + 0x2000
    event_counts: dict[int, int] = {}
    transfer_count = 0
    transfer_bytes = 0
    transfer_parts: list[bytes] = []
    offset = event_offset
    while offset < len(data):
        event_id = data[offset]
        offset += 1
        event_counts[event_id] = event_counts.get(event_id, 0) + 1
        if event_id == 0:
            path_index = data[offset]
            size = struct.unpack_from("<I", data, offset + 1)[0]
            offset += 5
            payload = data[offset : offset + size]
            if path_index == 3:
                transfer_count += 1
                transfer_bytes += len(payload)
                transfer_parts.append(payload)
            offset += size
        elif event_id == 1:
            offset += 1
        elif event_id == 2:
            offset += 4
        elif event_id == 3:
            offset += 0x2000
        else:
            raise ValueError(f"unknown GS dump event {event_id} at 0x{offset - 1:x}")

    return GsDumpInfo(
        serial=serial.rstrip("\0"),
        crc=crc,
        screenshot_size=(screenshot_width, screenshot_height),
        transfer_count=transfer_count,
        transfer_bytes=transfer_bytes,
        event_counts=event_counts,
        transfer_blob=b"".join(transfer_parts),
        full_dump=data,
    )


def score_tracks(info: GsDumpInfo, tracks_dir: Path) -> list[TrackScore]:
    scores: dict[int, TrackScore] = {}
    for texture in _iter_track_textures(tracks_dir):
        score, detail = _score_texture(texture, info)
        if score == 0:
            continue

        track_score = scores.setdefault(texture.track_id, TrackScore(track_id=texture.track_id))
        track_score.score += score
        track_score.details.append(detail)
        upper_name = texture.name.upper()
        if detail.image_exact and upper_name.startswith("TRACK") and upper_name.endswith("_MAP"):
            track_score.exact_map_names.append(texture.name)
        if detail.image_exact and "SKY" in upper_name:
            track_score.exact_sky_names.append(texture.name)

    for score in scores.values():
        score.details.sort(key=lambda detail: detail.score, reverse=True)
    return sorted(scores.values(), key=lambda score: (-score.score, score.track_id))


def _score_texture(texture: TexturePayload, info: GsDumpInfo) -> tuple[int, MatchDetail]:
    high_value_name = _is_high_value_texture_name(texture.name)
    image_exact = len(texture.image) >= 512 and (
        info.transfer_blob.find(texture.image) != -1 or info.full_dump.find(texture.image) != -1
    )
    palette_exact = len(texture.palette) >= 64 and (
        info.transfer_blob.find(texture.palette) != -1 or info.full_dump.find(texture.palette) != -1
    )
    image_partial = False
    if high_value_name and not image_exact and len(texture.image) >= 2048:
        image_partial = any(
            info.full_dump.find(texture.image[offset : offset + 1024]) != -1
            for offset in (0, len(texture.image) // 4, len(texture.image) // 2, max(0, len(texture.image) - 1024))
        )

    score = 0
    upper_name = texture.name.upper()
    if image_exact:
        score += 12 if len(texture.image) >= 4096 else 5
    if image_partial:
        score += 3
    if palette_exact and (image_exact or image_partial):
        score += 1
    if image_exact and upper_name.startswith("TRACK") and upper_name.endswith("_MAP"):
        score += 30
    if image_exact and "SKY" in upper_name:
        score += 10

    return score, MatchDetail(
        source=texture.source_path.name,
        texture=texture.name,
        score=score,
        image_exact=image_exact,
        palette_exact=palette_exact,
        image_partial=image_partial,
    )


def _iter_track_textures(tracks_dir: Path) -> list[TexturePayload]:
    textures: list[TexturePayload] = []
    for path in sorted(tracks_dir.glob("TEX*LOCATION.BIN")) + sorted(tracks_dir.glob("TEX*TRACK.BIN")):
        track_id = _track_id(path)
        if track_id is None:
            continue
        textures.extend(_read_texture_payloads(path, track_id))
    return textures


def _read_texture_payloads(path: Path, track_id: int) -> list[TexturePayload]:
    data = path.read_bytes()
    chunks = parse_chunks(data)
    entry_chunk = next((chunk for chunk in walk_chunks(chunks) if chunk.chunk_id == 0x30300003), None)
    data_chunk = next((chunk for chunk in walk_chunks(chunks) if chunk.chunk_id == 0x30300004), None)
    if entry_chunk is None or data_chunk is None:
        return []

    entries = entry_chunk.payload(data)
    if len(entries) % 0xA4 != 0:
        return []

    data_base = align(data_chunk.data_offset, 0x80)
    textures: list[TexturePayload] = []
    for index in range(len(entries) // 0xA4):
        entry = entries[index * 0xA4 : (index + 1) * 0xA4]
        name = entry[0x08:0x20].split(b"\0")[0].decode("ascii", errors="replace")
        if not name:
            continue
        if not _is_candidate_texture_name(name):
            continue
        width, height = struct.unpack_from("<HH", entry, 0x24)
        image_offset = struct.unpack_from("<I", entry, 0x30)[0]
        palette_offset = struct.unpack_from("<I", entry, 0x34)[0]
        image_size = struct.unpack_from("<I", entry, 0x38)[0]
        palette_size = struct.unpack_from("<I", entry, 0x3C)[0]
        textures.append(
            TexturePayload(
                track_id=track_id,
                source_path=path,
                name=name,
                width=width,
                height=height,
                image=data[data_base + image_offset : data_base + image_offset + image_size],
                palette=data[data_base + palette_offset : data_base + palette_offset + palette_size],
            )
        )
    return textures


def _is_candidate_texture_name(name: str) -> bool:
    upper_name = name.upper()
    return any(
        term in upper_name
        for term in (
            "TRACK",
            "SKY",
            "TUNNEL",
            "REDWOOD",
            "BARN",
            "HAY",
            "BIRCH",
            "COBBLE",
            "FOREST",
            "PINE",
            "VINEYARD",
            "MOUNTAIN",
            "CANYON",
            "AIRFIELD",
            "JUNGLE",
            "BEACH",
            "LAVA",
            "CITY",
            "TREE",
            "ROAD",
            "GRASS",
        )
    )


def _is_high_value_texture_name(name: str) -> bool:
    upper_name = name.upper()
    return any(
        term in upper_name
        for term in (
            "TRACK",
            "SKY",
            "TUNNEL",
            "REDWOOD",
            "BARN",
            "HAY",
            "BIRCH",
            "COBBLE",
            "FOREST",
            "VINEYARD",
            "CANYON",
            "JUNGLE",
            "BEACH",
            "LAVA",
        )
    )


def _track_id(path: Path) -> int | None:
    stem = path.stem.upper()
    if not stem.startswith("TEX"):
        return None
    digits = ""
    for char in stem[3:]:
        if not char.isdigit():
            break
        digits += char
    return int(digits) if digits else None


def _candidate_files(tracks_dir: Path, track_id: int) -> list[Path]:
    files = []
    common = tracks_dir / f"TRACKA{track_id:02d}.BUN"
    if common.exists():
        files.append(common)
    for specific in (tracks_dir / f"TRACKB{track_id:02d}.LZC", tracks_dir / f"TRACKB{track_id:02d}.BUN"):
        if specific.exists():
            files.append(specific)
            break
    for suffix in ("LOCATION", "TRACK"):
        path = tracks_dir / f"TEX{track_id:02d}{suffix}.BIN"
        if path.exists():
            files.append(path)
    return files


if __name__ == "__main__":
    raise SystemExit(main())
