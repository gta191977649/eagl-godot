#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from map_otools import TrackManager
from map_otools.utils import resolve_tracks_root


def non_negative_int(value: str) -> int:
    number = int(value)
    if number < 0:
        raise argparse.ArgumentTypeError("level must be >= 0")
    return number


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Need for Speed HP2 track exporter")
    subparsers = parser.add_subparsers(dest="command", required=True)

    export_track = subparsers.add_parser("export-track", help="Export one playable track")
    export_track.add_argument("input", type=Path, help="Game root or tracks folder")
    export_track.add_argument("-o", "--output", type=Path, required=True, help="Output .gltf or .glb file")
    export_track.add_argument("--track-id", type=int, help="Playable track id from Tracks.ini")
    export_track.add_argument("--track-name", help="Playable track displayName from Tracks.ini")
    export_track.add_argument("--level", type=non_negative_int, help="0-based route folder index, e.g. 0 for level00")
    export_track.add_argument("--fidelity", choices=["faithful", "raw"], default="faithful")

    export_name = subparsers.add_parser("export-name", help="Export one base track-name world")
    export_name.add_argument("input", type=Path, help="Game root or tracks folder")
    export_name.add_argument("--name", required=True, help="Track-name folder, e.g. Medit")
    export_name.add_argument("-o", "--output", type=Path, required=True, help="Output .gltf or .glb file")
    export_name.add_argument("--variant", type=int, help="Compatibility alias for the name-local playable variant")
    export_name.add_argument("--level", type=non_negative_int, help="0-based route folder index, e.g. 0 for level00")
    export_name.add_argument("--fidelity", choices=["faithful", "raw"])

    export_all = subparsers.add_parser("export-all", help="Export all playable tracks")
    export_all.add_argument("input", type=Path, help="Game root or tracks folder")
    export_all.add_argument("-o", "--output", type=Path, required=True, help="Output directory")
    export_all.add_argument("--format", choices=["gltf", "glb"], default="glb")
    export_all.add_argument("--fidelity", choices=["faithful", "raw"], default="faithful")

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    tracks_root = resolve_tracks_root(args.input)
    if tracks_root is None:
        print(f"error: unable to find Tracks.ini under {args.input}", file=sys.stderr)
        return 1

    shader_source = Path("/Users/nurupo/Desktop/dev/otools/OTools/target_nfshp2.cpp")
    manager = TrackManager(shader_source)

    try:
        if args.command == "export-track":
            if args.track_id is None and not args.track_name:
                raise ValueError("export-track requires --track-id or --track-name")
            out_path = manager.export_playable_track(
                tracks_root=tracks_root,
                out_path=args.output,
                track_id=args.track_id,
                track_name=args.track_name,
                level=args.level,
                fidelity=args.fidelity,
            )
            print(out_path)
        elif args.command == "export-name":
            fidelity = args.fidelity
            if fidelity is None:
                fidelity = "faithful" if args.level is not None else "raw"
            out_path = manager.export_name_world(
                tracks_root=tracks_root,
                name=args.name,
                out_path=args.output,
                fidelity=fidelity,
                variant=args.variant,
                level=args.level,
            )
            print(out_path)
        elif args.command == "export-all":
            outputs = manager.export_all_tracks(
                tracks_root=tracks_root,
                out_dir=args.output,
                fmt=args.format,
                fidelity=args.fidelity,
            )
            for out_path in outputs:
                print(out_path)
        else:
            raise ValueError(f"Unknown command {args.command}")
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
