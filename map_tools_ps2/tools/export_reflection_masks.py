"""Export the generated reflection-mask registry as standalone EAGL textures.

Mask selection comes from each pack's source-backed ``reflectionLayer`` field;
source texture names are never inspected.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from map_tools_ps2.textures import load_texture_library_for_track


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("game_dir", type=Path)
    parser.add_argument("packs_root", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    written: dict[str, str] = {}
    for manifest_path in sorted(args.packs_root.glob("hp2_*_pack/special_textures.json")):
        payload = json.loads(manifest_path.read_text(encoding="utf-8"))
        for record in payload["textures"]:
            if record.get("effectKind") != "reflection" or record.get("reflectionLayer") != "mask":
                continue
            canonical = record["name"]
            source_hash = int(record["sourceHash"], 16)
            track = int(record["tracks"][0])
            track_path = args.game_dir / "TRACKS" / f"TRACKB{track}.LZC"
            texture = load_texture_library_for_track(track_path).get(source_hash)
            if texture is None:
                raise RuntimeError(f"missing source hash {record['sourceHash']} for {canonical}")
            target = args.output / f"{canonical}.png"
            target.write_bytes(texture.png)
            written[canonical] = str(target)
    if not written:
        raise RuntimeError("no reflection masks found in deployed manifests")
    print(json.dumps(written, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
