from __future__ import annotations

import argparse
import csv
import math
import sys
from pathlib import Path

from .bounds_benchmark import benchmark_bounds_against_metadata
from .chunks import format_chunk_tree, parse_chunks
from .comp import decompress_lzc, load_bundle_bytes
from .debug_writer import write_ps2mesh_debug
from .glb_writer import write_glb
from .gs_transform_benchmark import benchmark_transform_against_gsdump
from .gs_oracle import compare_track_to_gsdump
from .gs_validate import validate_gsdump_against_track
from .model import parse_scene
from .obj_writer import write_obj
from .primitive_probe import probe_primitive_rule
from .progress import progress_iter
from .textures import load_texture_library_for_track
from .topology_benchmark import benchmark_topology


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


def _default_debug_path(out_path: Path) -> Path:
    stem = out_path.stem
    if stem.endswith(".native"):
        stem = stem[: -len(".native")]
    return out_path.with_name(f"{stem}.ps2mesh.json")


def _default_placement_path(track_path: Path) -> Path:
    return track_path.with_suffix(".txt")


def write_placement_txt(scene, out_path: Path, progress: bool = False) -> int:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", newline="") as fh:
        writer = csv.writer(fh, lineterminator="\n")
        writer.writerow(("NAME", "x", "y", "z", "sacle_x", "scale_y", "scale_z"))
        for instance in progress_iter(
            scene.scenery_instances,
            total=len(scene.scenery_instances),
            desc="Exporting placements",
            enabled=progress,
        ):
            x, y, z, _w = instance.transform[3]
            writer.writerow(
                (
                    instance.object_name,
                    _format_float(x),
                    _format_float(y),
                    _format_float(z),
                    _format_float(_axis_scale(instance.transform[0])),
                    _format_float(_axis_scale(instance.transform[1])),
                    _format_float(_axis_scale(instance.transform[2])),
                )
            )
    return len(scene.scenery_instances)


def _axis_scale(row: tuple[float, float, float, float]) -> float:
    return math.sqrt(row[0] * row[0] + row[1] * row[1] + row[2] * row[2])


def _format_float(value: float) -> str:
    return f"{value:.9g}"


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
        write_glb(
            scene,
            out_path,
            textures,
            vertex_colors=args.vertex_colors,
            expand_instances=args.with_placement,
            primitive_assembly=args.primitive_assembly,
            progress=True,
        )
    else:
        write_obj(scene, out_path, progress=True)
    print(f"wrote {out_path} ({len(scene.objects)} objects, {scene.vertex_count} decoded vertices)")
    return 0


def _cmd_export_placement(args: argparse.Namespace) -> int:
    src = _resolve_track_input(args)
    data = load_bundle_bytes(src)
    scene = parse_scene(parse_chunks(data), data)
    out_path = Path(args.output) if args.output else _default_placement_path(src)
    count = write_placement_txt(scene, out_path, progress=True)
    print(f"wrote {out_path} ({count} placements)")
    return 0


def _cmd_export_dual(args: argparse.Namespace) -> int:
    src = _resolve_track_input(args)
    data = load_bundle_bytes(src)
    scene = parse_scene(parse_chunks(data), data)
    if not scene.objects:
        raise SystemExit("no mesh objects decoded")

    out_path = Path(args.output) if args.output else src.with_name(f"{src.stem}.native.glb")
    texture_dir = Path(args.texture_dir) if args.texture_dir else None
    textures = load_texture_library_for_track(src, texture_dir)
    write_glb(
        scene,
        out_path,
        textures,
        vertex_colors=args.vertex_colors,
        expand_instances=args.with_placement,
        primitive_assembly="native",
        progress=True,
    )

    debug_path = Path(args.debug_output) if args.debug_output else _default_debug_path(out_path)
    bin_path = write_ps2mesh_debug(scene, debug_path, progress=True)
    print(
        f"wrote {out_path} and {debug_path} + {bin_path} "
        f"({len(scene.objects)} objects, {scene.vertex_count} decoded vertices)"
    )
    return 0


def _cmd_validate_gsdump(args: argparse.Namespace) -> int:
    src = _resolve_track_input(args)
    texture_dir = Path(args.texture_dir) if args.texture_dir else None
    report = validate_gsdump_against_track(
        src,
        Path(args.gsdump),
        object_filter=args.object,
        texture_dir=texture_dir,
        draw_start=args.draw_start,
        draw_stop=args.draw_stop,
        st_precision=args.st_precision,
    )
    print(report.format_text(limit=args.limit))
    return 0


def _cmd_benchmark_transform(args: argparse.Namespace) -> int:
    src = _resolve_track_input(args)
    report = benchmark_transform_against_gsdump(
        src,
        Path(args.gsdump),
        object_filter=args.object,
        st_precision=args.st_precision,
        min_vertices=args.min_vertices,
        max_samples=args.max_samples,
    )
    print(report.format_text(limit=args.limit))
    return 0


def _cmd_benchmark_bounds(args: argparse.Namespace) -> int:
    src = _resolve_track_input(args)
    report = benchmark_bounds_against_metadata(src, object_filter=args.object)
    print(report.format_text(limit=args.limit))
    return 0


def _cmd_benchmark_topology(args: argparse.Namespace) -> int:
    src = _resolve_track_input(args)
    report = benchmark_topology(src, object_filter=args.object)
    print(report.format_text(limit=args.limit))
    return 0


def _cmd_probe_primitive(args: argparse.Namespace) -> int:
    src = _resolve_track_input(args)
    report = probe_primitive_rule(
        src,
        Path(args.gsdump),
        object_name=args.object,
        block_index=args.block,
        draw_index=args.draw,
        object_index=args.object_index,
    )
    print(report.format_text())
    return 0


def _cmd_oracle_gsdump(args: argparse.Namespace) -> int:
    src = _resolve_track_input(args)
    report = compare_track_to_gsdump(
        src,
        Path(args.gsdump),
        object_filter=args.object,
        st_precision=args.st_precision,
        max_key_sources=args.max_key_sources,
        max_key_draws=args.max_key_draws,
    )
    print(report.format_text(limit=args.limit))
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
        "--with-placement",
        dest="with_placement",
        action="store_true",
        help="place scenery props using instance coordinate records",
    )
    export_parser.add_argument(
        "--expand-instances",
        dest="with_placement",
        action="store_true",
        help=argparse.SUPPRESS,
    )
    export_parser.add_argument(
        "--vertex-colors",
        choices=("auto", "always", "off"),
        default="always",
        help="vertex color export mode for GLB output",
    )
    export_parser.add_argument(
        "--primitive-assembly",
        choices=("triangles", "native"),
        default="triangles",
        help="GLB primitive assembly: triangles reconstructs indices, native preserves strips/fans",
    )
    export_parser.set_defaults(func=_cmd_export)

    dual_parser = subparsers.add_parser(
        "export-dual",
        help="export a native-primitive GLB plus ps2mesh debug JSON/BIN",
    )
    dual_parser.add_argument("input", nargs="?")
    dual_parser.add_argument("-o", "--output")
    dual_parser.add_argument("--debug-output", help="debug JSON output path; BIN is written next to it")
    dual_parser.add_argument("--game-dir", help="game directory containing ZZDATA/TRACKS")
    dual_parser.add_argument("--track", type=int, default=61, help="track number, default 61")
    dual_parser.add_argument("--texture-dir", help="directory containing TEX##TRACK.BIN and TEX##LOCATION.BIN")
    dual_parser.add_argument(
        "--with-placement",
        dest="with_placement",
        action="store_true",
        help="place scenery props using instance coordinate records",
    )
    dual_parser.add_argument(
        "--expand-instances",
        dest="with_placement",
        action="store_true",
        help=argparse.SUPPRESS,
    )
    dual_parser.add_argument(
        "--vertex-colors",
        choices=("auto", "always", "off"),
        default="always",
        help="vertex color export mode for GLB output",
    )
    dual_parser.set_defaults(func=_cmd_export_dual)

    placement_parser = subparsers.add_parser(
        "export-placement",
        help="export scenery prop placement coordinates",
    )
    placement_parser.add_argument("input", nargs="?")
    placement_parser.add_argument("-o", "--output")
    placement_parser.add_argument("--game-dir", help="game directory containing ZZDATA/TRACKS")
    placement_parser.add_argument("--track", type=int, help="track number, for example 44 for TRACKB44")
    placement_parser.set_defaults(func=_cmd_export_placement)

    decompress_parser = subparsers.add_parser("decompress", help="decompress a COMP/LZC bundle")
    decompress_parser.add_argument("input")
    decompress_parser.add_argument("-o", "--output")
    decompress_parser.set_defaults(func=_cmd_decompress)

    chunks_parser = subparsers.add_parser("chunks", help="print the decompressed chunk tree")
    chunks_parser.add_argument("input")
    chunks_parser.set_defaults(func=_cmd_chunks)

    validate_parser = subparsers.add_parser("validate-gsdump", help="compare decoded track blocks to GS dump draw packets")
    validate_parser.add_argument("gsdump", help="PCSX2 .gs or .gs.zst dump")
    validate_parser.add_argument("input", nargs="?")
    validate_parser.add_argument("--game-dir", help="game directory containing ZZDATA/TRACKS")
    validate_parser.add_argument("--track", type=int, default=61, help="track number, default 61 for the supplied GS dump")
    validate_parser.add_argument("--texture-dir", help="directory containing TEX##TRACK.BIN and TEX##LOCATION.BIN")
    validate_parser.add_argument("--object", default="TRN_SECTION60_UNDERROAD", help="object-name substring to validate")
    validate_parser.add_argument("--draw-start", type=int, default=0, help="first GS draw packet to include")
    validate_parser.add_argument("--draw-stop", type=int, help="exclusive GS draw packet stop index")
    validate_parser.add_argument("--st-precision", type=int, default=2, help="decimal precision used for ST matching")
    validate_parser.add_argument("--limit", type=int, default=48, help="maximum source block rows to print")
    validate_parser.set_defaults(func=_cmd_validate_gsdump)

    benchmark_parser = subparsers.add_parser(
        "benchmark-transform",
        help="fit source vertices against GS dump screen vertices to compare transform paths",
    )
    benchmark_parser.add_argument("gsdump", help="PCSX2 .gs or .gs.zst dump")
    benchmark_parser.add_argument("input", nargs="?")
    benchmark_parser.add_argument("--game-dir", help="game directory containing ZZDATA/TRACKS")
    benchmark_parser.add_argument("--track", type=int, default=61, help="track number, default 61 for the supplied GS dump")
    benchmark_parser.add_argument("--object", default="", help="object-name substring to benchmark; empty scans all objects")
    benchmark_parser.add_argument("--st-precision", type=int, default=2, help="decimal precision used for normalized ST matching")
    benchmark_parser.add_argument("--min-vertices", type=int, default=4, help="minimum vertices per matched draw/block")
    benchmark_parser.add_argument("--max-samples", type=int, default=256, help="maximum unique source/draw samples to fit")
    benchmark_parser.add_argument("--limit", type=int, default=24, help="maximum matched sample rows to print")
    benchmark_parser.set_defaults(func=_cmd_benchmark_transform)

    bounds_parser = subparsers.add_parser(
        "benchmark-bounds",
        help="compare decoded local/transformed vertices to 0x34004 block metadata bounds",
    )
    bounds_parser.add_argument("input", nargs="?")
    bounds_parser.add_argument("--game-dir", help="game directory containing ZZDATA/TRACKS")
    bounds_parser.add_argument("--track", type=int, default=61, help="track number, default 61")
    bounds_parser.add_argument("--object", default="", help="object-name substring to benchmark; empty scans all objects")
    bounds_parser.add_argument("--limit", type=int, default=24, help="maximum mismatch rows to print")
    bounds_parser.set_defaults(func=_cmd_benchmark_bounds)

    topology_parser = subparsers.add_parser(
        "benchmark-topology",
        help="compare raw strip face counts to GLB-emitted face counts",
    )
    topology_parser.add_argument("input", nargs="?")
    topology_parser.add_argument("--game-dir", help="game directory containing ZZDATA/TRACKS")
    topology_parser.add_argument("--track", type=int, default=61, help="track number, default 61")
    topology_parser.add_argument(
        "--object",
        default="TRN_SECTION60_UNDERROAD",
        help="object-name substring to benchmark",
    )
    topology_parser.add_argument("--limit", type=int, default=32, help="maximum changed rows to print")
    topology_parser.set_defaults(func=_cmd_benchmark_topology)

    primitive_parser = subparsers.add_parser(
        "probe-primitive",
        help="compare one source block against one GS draw under primitive assembly hypotheses",
    )
    primitive_parser.add_argument("gsdump", help="PCSX2 .gs or .gs.zst dump")
    primitive_parser.add_argument("input", nargs="?")
    primitive_parser.add_argument("--game-dir", help="game directory containing ZZDATA/TRACKS")
    primitive_parser.add_argument("--track", type=int, default=61, help="track number, default 61")
    primitive_parser.add_argument("--object", default="XS_LIGHTPOSTA_1_00", help="exact source object name")
    primitive_parser.add_argument("--object-index", type=int, help="source object index, used to disambiguate duplicate names")
    primitive_parser.add_argument("--block", type=int, default=6, help="source block index")
    primitive_parser.add_argument("--draw", type=int, default=1761, help="GS draw packet index")
    primitive_parser.set_defaults(func=_cmd_probe_primitive)

    oracle_parser = subparsers.add_parser(
        "oracle-gsdump",
        help="compare reconstructed primitive streams against GS dump draw packets",
    )
    oracle_parser.add_argument("gsdump", help="PCSX2 .gs or .gs.zst dump")
    oracle_parser.add_argument("input", nargs="?")
    oracle_parser.add_argument("--game-dir", help="game directory containing ZZDATA/TRACKS")
    oracle_parser.add_argument("--track", type=int, default=61, help="track number, default 61")
    oracle_parser.add_argument("--object", default="", help="object-name substring to compare")
    oracle_parser.add_argument("--st-precision", type=int, default=2, help="decimal precision used for normalized ST matching")
    oracle_parser.add_argument("--max-key-sources", type=int, default=24, help="skip keys with more source candidates")
    oracle_parser.add_argument("--max-key-draws", type=int, default=24, help="skip keys with more draw candidates")
    oracle_parser.add_argument("--limit", type=int, default=80, help="maximum groups and sample rows to print")
    oracle_parser.set_defaults(func=_cmd_oracle_gsdump)

    return parser


def main(argv: list[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv[1:]
    if argv and argv[0] not in {
        "export",
        "export-dual",
        "export-placement",
        "decompress",
        "chunks",
        "validate-gsdump",
        "benchmark-transform",
        "benchmark-bounds",
        "benchmark-topology",
        "probe-primitive",
        "oracle-gsdump",
        "-h",
        "--help",
    }:
        argv = ["export", *argv]
    parser = build_parser()
    args = parser.parse_args(argv)
    if hasattr(args, "func"):
        return args.func(args)
    parser.print_help()
    return 2
