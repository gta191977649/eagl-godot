from __future__ import annotations

import argparse
import csv
import json
import math
import re
import sys
from pathlib import Path

from .bounds_benchmark import benchmark_bounds_against_metadata
from .chunks import format_chunk_tree, parse_chunks
from .comp import decompress_lzc, load_bundle_bytes
from .debug_writer import write_ps2mesh_debug
from .glb_writer import write_glb
from .fbx_writer import write_binary_fbx_from_glb, write_binary_fbx_with_blender
from .frontend_textures import export_frontend_textures
from .global_textures import export_global_textures
from .optimized_export import build_optimized, write_optimized_glb
from .godot_writer import write_godot_track_package
from .gs_transform_benchmark import benchmark_transform_against_gsdump
from .gs_oracle import compare_track_to_gsdump
from .gs_validate import validate_gsdump_against_track
from .model import parse_scene
from .mta_export import export_mta_resource
from .mta_scene import build_mta_scene, load_collision_rules
from .obj_writer import write_obj
from .primitive_probe import probe_primitive_rule
from .progress import progress_iter
from .progress import cli_progress_context, report_progress
from .route_export import write_route_txt
from .sound_extract import export_sound
from .textures import load_texture_library_for_track
from .topology_benchmark import benchmark_topology


def _mta_collision_mode(value: str) -> str:
    if value in {"model", "bounds-only"}:
        return value
    if value in {"track", "hybrid", "visual", "none"}:
        raise argparse.ArgumentTypeError(
            f"'{value}' used the removed TrackCollisionPolygon/legacy collision pipeline; "
            "use 'model' or 'bounds-only'"
        )
    raise argparse.ArgumentTypeError("expected 'model' or 'bounds-only'")


def _native_collision_mode(value: str) -> str:
    if value not in {"auto", "required", "off"}:
        raise argparse.ArgumentTypeError("expected 'auto', 'required', or 'off'")
    return value


def _native_secondary_mode(value: str) -> str:
    if value not in {"ignore", "include"}:
        raise argparse.ArgumentTypeError("expected 'ignore' or 'include'")
    return value


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
        write_obj(scene, out_path, progress=True, expand_instances=args.with_placement)
    print(f"wrote {out_path} ({len(scene.objects)} objects, {scene.vertex_count} decoded vertices)")
    return 0


def _cmd_export_godot(args: argparse.Namespace) -> int:
    src = _resolve_track_input(args)
    data = load_bundle_bytes(src)
    scene = parse_scene(parse_chunks(data), data)
    if not scene.objects:
        raise SystemExit("no mesh objects decoded")
    texture_dir = Path(args.texture_dir) if args.texture_dir else None
    textures = load_texture_library_for_track(src, texture_dir)
    out_dir = Path(args.output) if args.output else src.with_suffix("")
    manifest_path = write_godot_track_package(
        scene,
        out_dir,
        src.stem,
        textures,
        vertex_colors=args.vertex_colors,
        progress=True,
    )
    print(
        f"wrote {manifest_path} "
        f"({len(scene.objects)} objects, {len(scene.scenery_instances)} scenery instances, {scene.vertex_count} decoded vertices)"
    )
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


def _cmd_export_route(args: argparse.Namespace) -> int:
    src = _resolve_track_input(args)
    data = load_bundle_bytes(src)
    scene = parse_scene(parse_chunks(data), data)
    match = re.search(r"TRACKB?(\d+)", src.stem, re.IGNORECASE)
    track_id = int(args.track) if args.track is not None else (int(match.group(1)) if match else 0)
    out_path = Path(args.output) if args.output else src.with_name(f"{src.stem}.route.txt")
    route_path = write_route_txt(scene, out_path, track_id, progress=True)
    report_path = route_path.with_name("route.report.json")
    report = json.loads(report_path.read_text(encoding="utf-8"))
    print(f"wrote {route_path} ({report['segments']} segments, {report['waypoints']} waypoints, {report['edges']} edges)")
    print(f"wrote {report_path}")
    return 0


def _cmd_export_optimized(args: argparse.Namespace) -> int:
    src = _resolve_track_input(args)
    data = load_bundle_bytes(src)
    scene = parse_scene(parse_chunks(data), data)
    if not scene.objects:
        raise SystemExit("no mesh objects decoded")
    texture_dir = Path(args.texture_dir) if args.texture_dir else None
    textures = load_texture_library_for_track(src, texture_dir)
    geometries, nodes, report = build_optimized(scene, args.chunk_size, args.instance_mode)
    base = Path(args.output) if args.output else src.with_name(src.stem)
    if base.suffix.lower() in {".glb", ".fbx"}:
        base = base.with_suffix("")
    formats = {args.format} if args.format != "both" else {"glb", "fbx"}
    glb_path = base.with_name(base.name + ".optimized.glb")
    if "glb" in formats or "fbx" in formats:
        write_optimized_glb(geometries, nodes, textures, glb_path, args.vertex_colors)
        report["glb_bytes"] = glb_path.stat().st_size
    if "fbx" in formats:
        fbx_path = base.with_name(base.name + ".optimized.fbx")
        texture_out = base.with_name(base.name + ".optimized.fbx.textures")
        texture_out.mkdir(parents=True, exist_ok=True)
        if args.fbx_backend == "blender":
            report.update(write_binary_fbx_with_blender(glb_path, fbx_path, texture_out))
        else:
            report.update(write_binary_fbx_from_glb(glb_path, fbx_path, texture_out))
        report["fbx_bytes"] = fbx_path.stat().st_size
    report_path = base.with_name(base.name + ".optimized.report.json")
    report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(f"wrote {', '.join(sorted(formats))} ({report['optimized_geometries']} geometries, {report['output_nodes']} nodes)")
    print(f"wrote {report_path}")
    return 0


def _cmd_export_mta(args: argparse.Namespace) -> int:
    src = _resolve_track_input(args)
    data = load_bundle_bytes(src)
    scene = parse_scene(parse_chunks(data), data)
    if not scene.objects:
        raise SystemExit("no mesh objects decoded")
    match = re.search(r"TRACKB?(\d+)", src.stem, re.IGNORECASE)
    track_id = int(args.track) if args.track is not None else (int(match.group(1)) if match else 0)
    resource_name = args.resource_name or f"HP2_TRACK{track_id:02d}"
    texture_dir = Path(args.texture_dir) if args.texture_dir else None
    textures = load_texture_library_for_track(src, texture_dir)
    mta_scene = build_mta_scene(
        scene,
        textures,
        track_id=track_id,
        resource_name=resource_name,
        chunk_size=args.chunk_size,
        max_vertices=args.max_vertices,
        collision_mode=args.collision,
        prop_lod_distance=args.prop_lod_distance,
        vertex_colors=args.vertex_colors,
        collision_rules=load_collision_rules(Path(args.collision_rules) if args.collision_rules else None),
        native_collision=args.native_collision,
        native_secondary=args.native_secondary,
        lod_mode=args.lod_mode,
        lod_min_size=args.lod_min_size,
        lod_target_ratio=args.lod_target_ratio,
        lod_small_size=args.lod_small_size,
        lod_small_diagonal=args.lod_small_diagonal,
        lod_min_triangles=args.lod_min_triangles,
        lod_repeated_triangles=args.lod_repeated_triangles,
        lod_repeated_count=args.lod_repeated_count,
        water_road_padding=args.water_road_padding,
        water_edge_padding=args.water_edge_padding,
        water_min_fragment_area=args.water_min_fragment_area,
        water_snap_grid=args.water_snap_grid,
        water_boundary_tolerance=args.water_boundary_tolerance,
    )
    if args.static_lod_distance != "auto":
        distance = float(args.static_lod_distance)
        if args.lod_mode != "off" and not 80.0 <= distance <= 299.0:
            raise SystemExit("--static-lod-distance must be between 80 and 299 when generated LOD is enabled")
        for model in mta_scene.models:
            if model.kind in {"static", "static_scenery", "road"} and not model.is_lod:
                model.lod_distance = distance
    out_dir = Path(args.output) if args.output else Path.cwd() / resource_name
    report = export_mta_resource(
        mta_scene,
        textures,
        out_dir,
        author=args.author,
        blender_path=Path(args.blender) if args.blender else None,
        dragonff_path=Path(args.dragonff_path) if args.dragonff_path else None,
        keep_intermediate=args.keep_intermediate,
        rollover_bytes=args.img_rollover_bytes,
        offset=(args.offset_x, args.offset_y, args.offset_z),
        water_dat=Path(args.water_dat) if args.water_dat else None,
    )
    print(f"wrote EagleLoader resource {out_dir}")
    water_info = mta_scene.report.get("water_quads", 0)
    water_source = "copied source" if args.water_dat else f"{water_info} generated quads"
    print(f"wrote {out_dir / 'water.dat'} ({water_source})")
    print(f"wrote {report}")
    return 0


def _cmd_export_skybox(args: argparse.Namespace) -> int:
    src = _resolve_track_input(args)
    track_match = re.search(r"TRACKB?(\d+)", src.stem, re.IGNORECASE)
    track_number = int(args.track) if args.track is not None else int(track_match.group(1)) if track_match else 0
    data = load_bundle_bytes(src)
    scene = parse_scene(parse_chunks(data), data)
    textures = load_texture_library_for_track(src, Path(args.texture_dir) if args.texture_dir else None)
    sky_objects = [obj for obj in scene.objects if obj.name.upper().startswith("SKYDOME") or "SKYBOX" in obj.name.upper()]
    referenced = []
    seen_hashes: set[int] = set()
    for obj in sky_objects:
        for texture_hash in obj.texture_hashes:
            if texture_hash not in seen_hashes:
                seen_hashes.add(texture_hash)
                referenced.append((obj.name, texture_hash))
    output = Path(args.output) if args.output else Path.cwd() / f"HP2_TRACK{track_number:02d}_skybox"
    if output.exists() and any(output.iterdir()):
        raise FileExistsError(f"output directory is not empty: {output}")
    output.mkdir(parents=True, exist_ok=True)
    texture_dir = output / "textures"
    texture_dir.mkdir(exist_ok=True)
    manifest = []
    report_progress("Exporting skybox textures", 0, len(referenced), None)
    for index, (object_name, texture_hash) in enumerate(referenced, 1):
        texture = textures.get(texture_hash)
        record = {"object": object_name, "hash": texture_hash, "status": "missing"}
        if texture is not None:
            filename = re.sub(r"[^A-Za-z0-9_.-]+", "_", texture.name).strip(" .") or f"texture_{texture_hash:08x}"
            filename = f"{filename}_{texture_hash:08x}.png"
            (texture_dir / filename).write_bytes(texture.png)
            record.update({"status": "written", "name": texture.name, "file": f"textures/{filename}", "width": texture.width, "height": texture.height})
        manifest.append(record)
        report_progress("Exporting skybox textures", index, len(referenced), texture.name if texture is not None else f"0x{texture_hash:08x}")
    manifest_path = output / "skybox_manifest.json"
    manifest_path.write_text(json.dumps({"track": track_number, "objects": [obj.name for obj in sky_objects], "textures": manifest}, indent=2), encoding="utf-8")
    print(f"wrote {len([item for item in manifest if item['status'] == 'written'])} skybox textures to {output}")
    print(f"wrote {manifest_path}")
    return 0


def _cmd_export_frontend_textures(args: argparse.Namespace) -> int:
    export_frontend_textures(Path(args.frontend_dir), Path(args.output))
    return 0


def _cmd_export_global_textures(args: argparse.Namespace) -> int:
    export_global_textures(Path(args.global_dir), Path(args.output))
    return 0


def _cmd_export_sound(args: argparse.Namespace) -> int:
    export_sound(Path(args.sound_dir), Path(args.output), workers=args.workers)
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

    godot_parser = subparsers.add_parser(
        "export-godot",
        help="export a Godot-optimized .eagltrack package",
    )
    godot_parser.add_argument("input", nargs="?")
    godot_parser.add_argument("-o", "--output", help="output directory for .eagltrack.json/bin and textures")
    godot_parser.add_argument("--game-dir", help="game directory containing ZZDATA/TRACKS")
    godot_parser.add_argument("--track", type=int, help="track number, for example 44 for TRACKB44")
    godot_parser.add_argument("--texture-dir", help="directory containing TEX##TRACK.BIN and TEX##LOCATION.BIN")
    godot_parser.add_argument(
        "--vertex-colors",
        choices=("auto", "always", "off"),
        default="always",
        help="vertex color export mode for Godot output",
    )
    godot_parser.set_defaults(func=_cmd_export_godot)

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

    optimized_parser = subparsers.add_parser(
        "export-optimized",
        help="export a spatially merged, instanced GLB and/or Binary FBX",
    )
    optimized_parser.add_argument("input", nargs="?")
    optimized_parser.add_argument("-o", "--output")
    optimized_parser.add_argument("--game-dir", help="game directory containing ZZDATA/TRACKS")
    optimized_parser.add_argument("--track", type=int, help="track number, for example 31 for TRACKB31")
    optimized_parser.add_argument("--texture-dir", help="directory containing TEX##TRACK.BIN and TEX##LOCATION.BIN")
    optimized_parser.add_argument("--format", choices=("glb", "fbx", "both"), default="glb")
    optimized_parser.add_argument("--chunk-size", type=float, default=300.0)
    optimized_parser.add_argument("--instance-mode", choices=("reuse", "expand"), default="reuse")
    optimized_parser.add_argument("--fbx-backend", choices=("blender", "python"), default="blender")
    optimized_parser.add_argument("--vertex-colors", choices=("auto", "always", "off"), default="always")
    optimized_parser.set_defaults(func=_cmd_export_optimized)

    mta_parser = subparsers.add_parser(
        "export-mta",
        help="export a complete MTA:SA EagleLoader trackpack with DFF/COL/TXD IMG archives",
    )
    mta_parser.add_argument("input", nargs="?")
    mta_parser.add_argument("-o", "--output", help="new or empty Eagle resource output directory")
    mta_parser.add_argument("--game-dir", help="game directory containing ZZDATA/TRACKS")
    mta_parser.add_argument("--track", type=int, help="track number, for example 31 for TRACKB31")
    mta_parser.add_argument("--texture-dir", help="directory containing TEX##TRACK.BIN and TEX##LOCATION.BIN")
    mta_parser.add_argument("--resource-name", help="MTA resource name; defaults to HP2_TRACK##")
    mta_parser.add_argument("--author", default="map_tools_ps2")
    mta_parser.add_argument("--chunk-size", type=float, default=300.0)
    mta_parser.add_argument("--max-vertices", type=int, default=60000)
    mta_parser.add_argument("--collision", type=_mta_collision_mode, default="model", metavar="{model,bounds-only}")
    mta_parser.add_argument("--native-collision", type=_native_collision_mode, default="auto", metavar="{auto,required,off}")
    mta_parser.add_argument("--native-secondary", type=_native_secondary_mode, default="ignore", metavar="{ignore,include}")
    mta_parser.add_argument("--collision-rules", help="optional JSON file mapping texture names/patterns to GTA surfaces")
    mta_parser.add_argument("--txd-mode", choices=("track",), default="track")
    mta_parser.add_argument("--archive-mode", choices=("img",), default="img")
    mta_parser.add_argument("--static-lod-distance", default="299", help="auto or a numeric draw distance")
    mta_parser.add_argument("--prop-lod-distance", type=float, default=299.0)
    mta_parser.add_argument("--lod-mode", choices=("auto", "required", "off"), default="auto")
    mta_parser.add_argument("--lod-min-size", type=float, default=100.0)
    mta_parser.add_argument("--lod-target-ratio", type=float, default=0.12)
    mta_parser.add_argument("--lod-small-size", type=float, default=60.0)
    mta_parser.add_argument("--lod-small-diagonal", type=float, default=80.0)
    mta_parser.add_argument("--lod-min-triangles", type=int, default=300)
    mta_parser.add_argument("--lod-repeated-triangles", type=int, default=600)
    mta_parser.add_argument("--lod-repeated-count", type=int, default=32)
    mta_parser.add_argument("--offset-x", type=float, default=0.0)
    mta_parser.add_argument("--offset-y", type=float, default=0.0)
    mta_parser.add_argument("--offset-z", type=float, default=0.0)
    mta_parser.add_argument("--water-dat", help="optional EagleLoader water.dat to copy; defaults to an empty compatibility file")
    mta_parser.add_argument("--water-road-padding", type=float, default=8.0)
    mta_parser.add_argument("--water-edge-padding", type=float, default=8.0)
    mta_parser.add_argument("--water-min-fragment-area", type=float, default=16.0)
    mta_parser.add_argument("--water-snap-grid", type=float, default=0.0)
    mta_parser.add_argument("--water-boundary-tolerance", type=float, default=1.0)
    mta_parser.add_argument("--vertex-colors", choices=("auto", "always", "off"), default="always")
    mta_parser.add_argument("--blender", help="path to Blender 4.2+ executable")
    mta_parser.add_argument("--dragonff-path", help="path to the DragonFF package directory")
    mta_parser.add_argument(
        "--keep-intermediate",
        action="store_true",
        help="keep Blender staging beside the resource as OUTPUT.intermediate",
    )
    mta_parser.add_argument("--img-rollover-bytes", type=int, default=1_500_000_000)
    mta_parser.set_defaults(func=_cmd_export_mta)

    from .managed_export import command as export_family_command
    family_parser = subparsers.add_parser("export-mta-families", help="export shared, runtime-managed HP2 Eagle family packs")
    family_parser.add_argument("--game-dir", required=True)
    family_parser.add_argument("-o", "--output", required=True)
    family_parser.add_argument("--family", choices=("all", "parkland", "desert", "medit", "alpine", "tropic"), default="all")
    family_parser.add_argument("--blender")
    family_parser.add_argument("--dragonff-path")
    family_parser.add_argument("--author", default="map_tools_ps2")
    family_parser.set_defaults(func=export_family_command)

    skybox_parser = subparsers.add_parser(
        "export-skybox",
        help="export textures referenced by SKYDOME/SKYBOX objects as PNG files",
    )
    skybox_parser.add_argument("input", nargs="?")
    skybox_parser.add_argument("-o", "--output", help="new or empty skybox output directory")
    skybox_parser.add_argument("--game-dir", help="game directory containing ZZDATA/TRACKS")
    skybox_parser.add_argument("--track", type=int, help="track number, for example 31 for TRACKB31")
    skybox_parser.add_argument("--texture-dir", help="directory containing TEX##TRACK.BIN and TEX##LOCATION.BIN")
    skybox_parser.set_defaults(func=_cmd_export_skybox)

    frontend_parser = subparsers.add_parser(
        "export-frontend-textures",
        help="export all decodable FRONTEND PS2 textures as PNG files",
    )
    frontend_parser.add_argument("--frontend-dir", required=True, help="FRONTEND directory")
    frontend_parser.add_argument("-o", "--output", required=True, help="output directory")
    frontend_parser.set_defaults(func=_cmd_export_frontend_textures)

    global_parser = subparsers.add_parser(
        "export-global-textures",
        help="export all decodable GLOBAL PS2 textures as PNG files",
    )
    global_parser.add_argument("--global-dir", required=True, help="GLOBAL directory")
    global_parser.add_argument("-o", "--output", required=True, help="output directory")
    global_parser.set_defaults(func=_cmd_export_global_textures)

    sound_parser = subparsers.add_parser(
        "export-sound",
        help="extract HP2 PS2 music, speech, UI/SFX, and engine banks as MP3 files",
    )
    sound_parser.add_argument(
        "--zzdata-dir", "--sound-dir", dest="sound_dir", required=True,
        help="game ZZDATA directory (--sound-dir is retained as a compatibility alias)",
    )
    sound_parser.add_argument("-o", "--output", required=True, help="output directory")
    sound_parser.add_argument(
        "--workers", type=int, default=0,
        help="parallel resource worker processes; 0 selects automatically (up to 6)",
    )
    sound_parser.set_defaults(func=_cmd_export_sound)

    placement_parser = subparsers.add_parser(
        "export-placement",
        help="export scenery prop placement coordinates",
    )
    placement_parser.add_argument("input", nargs="?")
    placement_parser.add_argument("-o", "--output")
    placement_parser.add_argument("--game-dir", help="game directory containing ZZDATA/TRACKS")
    placement_parser.add_argument("--track", type=int, help="track number, for example 44 for TRACKB44")
    placement_parser.set_defaults(func=_cmd_export_placement)

    route_parser = subparsers.add_parser(
        "export-route",
        help="export HP2 AI vehicle route waypoints and branch edges",
    )
    route_parser.add_argument("input", nargs="?")
    route_parser.add_argument("-o", "--output", help="route.txt output path")
    route_parser.add_argument("--game-dir", help="game directory containing ZZDATA/TRACKS")
    route_parser.add_argument("--track", type=int, help="track number, for example 31 for TRACKB31")
    route_parser.set_defaults(func=_cmd_export_route)

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
    parser = build_parser()
    subparser_action = next(
        action for action in parser._actions if isinstance(action, argparse._SubParsersAction)
    )
    known_commands = set(subparser_action.choices)
    if argv and argv[0] not in known_commands and argv[0] not in {"-h", "--help"}:
        argv = ["export", *argv]
    args = parser.parse_args(argv)
    if hasattr(args, "func"):
        with cli_progress_context():
            return args.func(args)
    parser.print_help()
    return 2
