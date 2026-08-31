"""Batch extraction of PS2 FRONTEND texture libraries."""

from __future__ import annotations

import json
import re
from collections import Counter
from pathlib import Path

from .comp import load_bundle_bytes
from .progress import report_progress
from .textures import read_ps2_tpk_bytes


SUPPORTED_SUFFIXES = {".BIN", ".BUN", ".LZC"}


def _safe_name(value: str, fallback: str) -> str:
    name = re.sub(r"[^A-Za-z0-9_.-]+", "_", value).strip(" .")
    return name or fallback


def _resource_candidates(frontend_dir: Path) -> list[Path]:
    paths = [path for path in frontend_dir.rglob("*") if path.is_file() and path.suffix.upper() in SUPPORTED_SUFFIXES]
    paths.sort(key=lambda path: (str(path.relative_to(frontend_dir)).lower(), path.suffix.upper() != ".BUN"))

    # A compressed LZC and its decompressed BUN are the same resource. Keep
    # the BUN when both are present, while retaining unrelated resources.
    selected: list[Path] = []
    by_stem: dict[Path, Path] = {}
    for path in paths:
        key = path.with_suffix("").relative_to(frontend_dir)
        previous = by_stem.get(key)
        if previous is None or (path.suffix.upper() == ".BUN" and previous.suffix.upper() == ".LZC"):
            by_stem[key] = path
    selected.extend(sorted(by_stem.values(), key=lambda path: str(path.relative_to(frontend_dir)).lower()))
    return selected


def export_frontend_textures(frontend_dir: Path, output_dir: Path) -> dict[str, object]:
    frontend_dir = frontend_dir.resolve()
    output_dir = output_dir.resolve()
    frontend_dir.mkdir(parents=True, exist_ok=True)
    if output_dir.exists() and not output_dir.is_dir():
        raise NotADirectoryError(f"Output path is not a directory: {output_dir}")
    output_dir.mkdir(parents=True, exist_ok=True)

    resources = _resource_candidates(frontend_dir)
    manifest: dict[str, object] = {
        "frontend_dir": str(frontend_dir),
        "output_dir": str(output_dir),
        "resources": [],
        "unprocessed_files": [
            {"source": str(path.relative_to(frontend_dir)), "reason": "unsupported extension"}
            for path in sorted(frontend_dir.rglob("*"))
            if path.is_file() and path.suffix.upper() not in SUPPORTED_SUFFIXES
        ],
        "summary": {"resources": len(resources), "written": 0, "textures": 0, "skipped": 0},
    }
    records: list[dict[str, object]] = []
    summary = manifest["summary"]
    assert isinstance(summary, dict)

    report_progress("Scanning FRONTEND texture resources", 0, len(resources), None)
    for index, source_path in enumerate(resources, 1):
        relative = source_path.relative_to(frontend_dir)
        record: dict[str, object] = {"source": str(relative), "status": "skipped", "textures": []}
        try:
            if source_path.stat().st_size == 0:
                record["reason"] = "empty file"
            else:
                data = load_bundle_bytes(source_path)
                textures = read_ps2_tpk_bytes(data, source_path, flip_vertical=True)
                if not textures:
                    record["reason"] = "no TPK textures found"
                else:
                    source_key = _safe_name(str(relative.with_suffix("")), source_path.stem)
                    source_output = output_dir / source_key
                    source_output.mkdir(parents=True, exist_ok=True)
                    texture_records: list[dict[str, object]] = []
                    used_names: Counter[str] = Counter()
                    for texture in textures:
                        base = _safe_name(texture.name, f"texture_{texture.tex_hash:08x}")
                        used_names[base] += 1
                        suffix = f"_{texture.tex_hash:08x}"
                        if used_names[base] > 1:
                            suffix += f"_{used_names[base]}"
                        filename = f"{base}{suffix}.png"
                        (source_output / filename).write_bytes(texture.png)
                        texture_records.append({
                            "name": texture.name,
                            "hash": f"0x{texture.tex_hash:08x}",
                            "width": texture.width,
                            "height": texture.height,
                            "file": str(Path(source_key) / filename),
                        })
                    record["status"] = "written"
                    record["textures"] = texture_records
                    summary["written"] = int(summary["written"]) + 1
                    summary["textures"] = int(summary["textures"]) + len(texture_records)
        except Exception as exc:  # Continue extracting independent resources.
            record["reason"] = f"{type(exc).__name__}: {exc}"
        if record["status"] == "skipped":
            summary["skipped"] = int(summary["skipped"]) + 1
        records.append(record)
        report_progress("Extracting FRONTEND textures", index, len(resources), str(relative))

    manifest["resources"] = records
    manifest_path = output_dir / "frontend_manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(f"wrote {summary['textures']} textures from {summary['written']} resources to {output_dir}")
    print(f"wrote {manifest_path}")
    return manifest
