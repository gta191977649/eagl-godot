#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

from car_tools import ExportError, export_car


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Command-line utilities for the godot_eagl_ps2 project."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    export_car_parser = subparsers.add_parser(
        "export-car",
        help="Export a PS2 vehicle model to .glb or .gltf using pure Python.",
    )
    export_car_parser.add_argument(
        "--game-root",
        required=True,
        help="Path to the extracted game root or GameFile directory.",
    )
    export_car_parser.add_argument(
        "--car-id",
        required=True,
        help="Vehicle ID, for example CORVETTE.",
    )
    export_car_parser.add_argument(
        "--output",
        required=True,
        help="Destination .glb or .gltf path.",
    )
    export_car_parser.add_argument(
        "--duplicate-index",
        type=int,
        default=1,
        help="GLOBALB duplicate row index for the vehicle. Default: 1.",
    )
    export_car_parser.add_argument(
        "--drive-type",
        default="RWD",
        choices=["FWD", "RWD", "AWD"],
        help="Fallback drive type when GLOBALB is unavailable. Default: RWD.",
    )
    export_car_parser.set_defaults(func=run_export_car)
    return parser


def run_export_car(args: argparse.Namespace) -> int:
    output_path = Path(args.output).expanduser()
    if output_path.suffix.lower() not in {".glb", ".gltf"}:
        raise SystemExit("--output must end with .glb or .gltf")
    try:
        result = export_car(
            game_root=Path(args.game_root).expanduser(),
            car_id=args.car_id.upper(),
            output_path=output_path,
            duplicate_index=int(args.duplicate_index),
            drive_type=args.drive_type.upper(),
        )
    except ExportError as exc:
        raise SystemExit(str(exc)) from exc

    print(f"Exported {result['car_id']} -> {output_path}")
    if result["warnings"]:
        print(f"Warnings: {result['warning_count']}")
        for message in result["warnings"]:
            print(f"  - {message}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
