from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .chunks import format_chunk_tree, parse_chunks
from .comp import decompress_lzc, load_bundle_bytes
from .glb_writer import write_glb
from .model import parse_scene
from .obj_writer import write_obj
from .textures import load_texture_library_for_track


def _resolve_track_input(args: argparse.Namespace) -> Path:
    if getattr(args, "input", None):
        return Path(args.input)

    game_dir = getattr(args, "game_dir", None)
    track = getattr(args, "track", None)
    if not game_dir or track is None:
        raise SystemExit("provide either INPUT or both --game-dir and --track")

    track_id = f"{int(track):02d}"
    tracks_dir = Path(game_dir) / "ZZDATA" / "TRACKS"
    candidates = (
        tracks_dir / f"TRACKB{track_id}.BUN",
        tracks_dir / f"TRACKB{track_id}.LZC",
    )
    for candidate in candidates:
        if candidate.exists():
            return candidate
    raise SystemExit(f"could not find TRACKB{track_id}.BUN or TRACKB{track_id}.LZC in {tracks_dir}")


def _cmd_decompress(args: argparse.Namespace) -> int:
    src = Path(args.input)
    data = src.read_bytes()
    if data.startswith(b"COMP"):
        out = decompress_lzc(data)
    else:
        out = data
    out_path = Path(args.output) if args.output else src.with_suffix(".BUN")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_bytes(out)
    print(f"wrote {out_path} ({len(out)} bytes)")
    return 0


def _cmd_chunks(args: argparse.Namespace) -> int:
    data = load_bundle_bytes(Path(args.input))
    print(format_chunk_tree(parse_chunks(data)))
    return 0


def _cmd_export(args: argparse.Namespace) -> int:
    src = _resolve_track_input(args)
    data = load_bundle_bytes(src)
    chunks = parse_chunks(data)
    scene = parse_scene(chunks, data)
    if not scene.objects:
        raise SystemExit("no mesh objects decoded")
    default_name = f"{src.stem}.obj"
    out_path = Path(args.output) if args.output else src.with_name(default_name)
    if out_path.suffix.lower() == ".glb":
        texture_dir = Path(args.texture_dir) if args.texture_dir else None
        textures = load_texture_library_for_track(src, texture_dir)
        write_glb(scene, out_path, textures, vertex_colors=args.vertex_colors)
    else:
        write_obj(scene, out_path)
    print(f"wrote {out_path} ({len(scene.objects)} objects, {scene.vertex_count} decoded vertices)")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="map-tools-ps2")
    subparsers = parser.add_subparsers(dest="command")

    export_parser = subparsers.add_parser("export", help="export an experimental OBJ")
    export_parser.add_argument("input", nargs="?")
    export_parser.add_argument("-o", "--output")
    export_parser.add_argument("--game-dir", help="game directory containing ZZDATA/TRACKS")
    export_parser.add_argument("--track", type=int, help="track number, for example 44 for TRACKB44")
    export_parser.add_argument("--texture-dir", help="directory containing TEX##TRACK.BIN and TEX##LOCATION.BIN")
    export_parser.add_argument(
        "--vertex-colors",
        choices=("auto", "always", "off"),
        default="auto",
        help="vertex color export mode for GLB output",
    )
    export_parser.set_defaults(func=_cmd_export)

    decompress_parser = subparsers.add_parser("decompress", help="decompress a COMP/LZC bundle")
    decompress_parser.add_argument("input")
    decompress_parser.add_argument("-o", "--output")
    decompress_parser.set_defaults(func=_cmd_decompress)

    chunks_parser = subparsers.add_parser("chunks", help="print the decompressed chunk tree")
    chunks_parser.add_argument("input")
    chunks_parser.set_defaults(func=_cmd_chunks)

    return parser


def main(argv: list[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv[1:]
    if argv and argv[0] not in {"export", "decompress", "chunks", "-h", "--help"}:
        argv = ["export", *argv]
    parser = build_parser()
    args = parser.parse_args(argv)
    if hasattr(args, "func"):
        return args.func(args)
    parser.print_help()
    return 2
