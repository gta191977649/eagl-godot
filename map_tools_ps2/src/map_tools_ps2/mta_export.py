from __future__ import annotations

from .dynamic_physics import collision_primitive, definition_attributes, placement_attributes, definition_physics_key

import json
import os
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from dataclasses import replace
from pathlib import Path
from typing import Any

from .img_archive import ImgEntry, read_img_v2_directory, write_img_v2
from .mta_scene import MtaScene, _MTA_WATER_SAFE_QUAD_BUDGET
from .mta_lod import generate_eagle_lod
from .progress import report_progress

_BLENDER_PROGRESS_PREFIX = "MTA_PROGRESS "


def parse_blender_progress(line: str) -> tuple[str, int, int] | None:
    """Read one "MTA_PROGRESS <stage>, <current>, <total>" tab-separated line.

    Blender writes plenty of unrelated output, so anything that does not match
    the exact shape is ordinary log text and must be left alone.
    """
    if not line.startswith(_BLENDER_PROGRESS_PREFIX):
        return None
    fields = line[len(_BLENDER_PROGRESS_PREFIX) :].rstrip("\n").split("\t")
    if len(fields) != 3 or not fields[1].isdigit() or not fields[2].isdigit():
        return None
    return fields[0], int(fields[1]), int(fields[2])


DEFAULT_BLENDER_PATHS = (
    Path(r"C:\Program Files\Blender Foundation\Blender 4.5\blender.exe"),
    Path(r"C:\Program Files\Blender Foundation\Blender 4.4\blender.exe"),
    Path(r"C:\Program Files\Blender Foundation\Blender 4.3\blender.exe"),
)

_BARRIER_ANIMATION_FX = """texture gAnimTexture;

technique hp2BarrierNeon
{
    pass P0
    {
        Texture[0] = gAnimTexture;
        ColorOp[0] = Modulate;
        ColorArg1[0] = Texture;
        ColorArg2[0] = Diffuse;
        AlphaOp[0] = SelectArg1;
        AlphaArg1[0] = Texture;
        AlphaBlendEnable = true;
        SrcBlend = One;
        DestBlend = One;
        ZWriteEnable = false;
    }
}
"""


def find_blender(explicit: Path | None) -> Path:
    if explicit is not None:
        if not explicit.exists():
            raise FileNotFoundError(f"Blender executable not found: {explicit}")
        return explicit
    configured = os.environ.get("BLENDER_PATH")
    if configured and Path(configured).exists():
        return Path(configured)
    found = shutil.which("blender")
    if found:
        return Path(found)
    for candidate in DEFAULT_BLENDER_PATHS:
        if candidate.exists():
            return candidate
    raise FileNotFoundError("Blender was not found; pass --blender or set BLENDER_PATH")


def _write_staging(scene: MtaScene, textures: Any, root: Path) -> Path:
    texture_dir = root / "textures"
    texture_dir.mkdir(parents=True, exist_ok=True)
    texture_records = []
    cutoff_by_variant = {
        (material.texture_hash, material.alpha_mode, material.surface_category, material.special_role): material.alpha_cutoff
        for model in scene.models
        for material in model.materials
        if material.texture_hash is not None
    }
    variants = scene.texture_variants or {
        (tex_hash, (textures.get(tex_hash).alpha_mode or "OPAQUE"), None, None): name
        for tex_hash, name in scene.texture_names.items()
        if textures.get(tex_hash) is not None
    }
    emitted_texture_names: set[str] = set()
    for (tex_hash, alpha_mode, surface_category, special_role), texture_name in sorted(
        variants.items(), key=lambda item: (item[0][0], item[0][1], item[0][2] or "", item[0][3] or "")
    ):
        texture = textures.get(tex_hash)
        if texture is None:
            continue
        # Reflection materials are deliberately opaque in the DFF/IDE so the
        # shader owns blending and ordering.  The TXD raster is independent:
        # its source alpha is the authored reflection mask and must remain
        # DXT5/BLEND instead of being flattened to opaque DXT1.
        raster_alpha_mode = (
            str(texture.alpha_mode or "OPAQUE").upper()
            if special_role == "reflection"
            else alpha_mode
        )
        raster_alpha_cutoff = (
            texture.alpha_cutoff
            if special_role == "reflection"
            else cutoff_by_variant.get((tex_hash, alpha_mode, surface_category, special_role))
        )
        # Several variant keys can share one emitted name. The TXD holds one
        # raster per name even when multiple material records reference it.
        if texture_name in emitted_texture_names:
            continue
        emitted_texture_names.add(texture_name)
        filename = f"{texture_name}.png"
        (texture_dir / filename).write_bytes(texture.png)
        record = {
            "hash": tex_hash,
            "name": texture_name,
            "file": f"textures/{filename}",
            "has_alpha": raster_alpha_mode != "OPAQUE",
            "alpha_mode": raster_alpha_mode,
            "alpha_cutoff": raster_alpha_cutoff,
            "source_alpha_mode": texture.alpha_mode or "OPAQUE",
            "special_role": special_role,
        }
        texture_records.append(record)

    material_catalog: list[dict[str, Any]] = []
    material_indices: dict[tuple[int | None, str | None, str, int | None, str | None, str | None], int] = {}
    model_records = []
    for model in scene.models:
        model_materials = []
        for material in model.materials:
            key = (
                material.texture_hash, material.texture_name, material.alpha_mode,
                material.hp2_material_id, material.surface_category,
                material.special_role,
            )
            if key not in material_indices:
                material_indices[key] = len(material_catalog)
                material_catalog.append(
                    {
                        "texture_hash": material.texture_hash,
                        "texture_name": material.texture_name,
                        "alpha": material.alpha,
                        "alpha_mode": material.alpha_mode,
                        "alpha_cutoff": material.alpha_cutoff,
                        "alpha_reason": material.alpha_reason,
                        "render_flag": material.render_flag,
                        "hp2_material_id": material.hp2_material_id,
                        "surface_category": material.surface_category,
                        "special_role": material.special_role,
                        "source_alpha_mode": material.source_alpha_mode,
                        "source_alpha_cutoff": material.source_alpha_cutoff,
                        "source_submeshes": list(material.source_submeshes),
                        "source_texture_slots": list(material.source_texture_slots),
                    }
                )
            model_materials.append(material_indices[key])
        model_records.append(
            {
                "model_id": model.model_id,
                "source_name": model.source_name,
                "source_offset": model.source_offset,
                "origin": model.origin,
                "vertices": model.vertices,
                "faces": model.faces,
                "uvs": model.uvs,
                "colors": model.colors,
                "face_materials": model.face_materials,
                "materials": model_materials,
                "collision_vertices": model.collision_vertices,
                "collision_faces": model.collision_faces,
                "collision_materials": model.collision_materials,
                "collision_kind": model.collision_kind,
                "dynamic_collision_primitive": collision_primitive(model),
                "render_layer": model.render_layer,
                "draw_last": model.draw_last,
                "additive": model.additive,
                "no_zbuffer_write": model.no_zbuffer_write,
                "is_lod": model.is_lod,
                "lod_source_id": model.lod_source_id,
                "lod_target_ratio": model.lod_target_ratio,
            }
        )
    manifest = {
        "version": 1,
        "models": model_records,
        "textures": texture_records,
        "material_catalog": material_catalog,
        "txd_file": f"track{scene.track_id:02d}.txd",
        "lod_mode": scene.report.get("lod_mode", "off"),
        "lod_generation": scene.report.get("lod_generation", []),
    }
    path = root / "mta_stage.json"
    path.write_text(json.dumps(manifest, separators=(",", ":")), encoding="utf-8")
    return path


def _prepare_eagle_lods(scene: MtaScene) -> None:
    """Replace LOD placeholders with Eagle Editor meshoptimizer geometry."""
    source_models = {model.model_id: model for model in scene.models if not model.is_lod}
    results: list[dict[str, Any]] = []
    skipped: set[str] = set()
    for lod_model in [model for model in scene.models if model.is_lod]:
        source = source_models.get(lod_model.lod_source_id or "")
        if source is None:
            raise RuntimeError(f"LOD source model is missing: {lod_model.lod_source_id}")
        generated, result = generate_eagle_lod(source, lod_model)
        results.append(result)
        if not generated:
            if scene.report.get("lod_mode") == "required":
                raise RuntimeError(
                    f"Eagle Editor LOD generation rejected {source.model_id}: {result.get('attempts')}"
                )
            skipped.add(lod_model.model_id)
    if skipped:
        scene.models[:] = [model for model in scene.models if model.model_id not in skipped]
        scene.placements[:] = [
            replace(placement, lod_parent=None) if placement.lod_parent in skipped else placement
            for placement in scene.placements
            if placement.model_id not in skipped
        ]
        scene.zones[:] = sorted({placement.zone for placement in scene.placements} | {model.zone for model in scene.models})
    scene.report.update(
        {
            "lod_generator": "MTA-Eagle-Editor meshoptimizer 0.6.2 / meshoptimizer 0.25",
            "lod_texture_strategy": "source track TXD; exact material texture names and source UVs",
            "lod_generation": results,
            "lod_models": sum(model.is_lod for model in scene.models),
            "lod_models_skipped": len(skipped),
        }
    )


def _run_blender(
    scene: MtaScene,
    textures: Any,
    stage_dir: Path,
    blender: Path,
    dragonff_path: Path | None,
) -> tuple[Path, str, dict[str, Any]]:
    manifest = _write_staging(scene, textures, stage_dir)
    loose_dir = stage_dir / "loose"
    script = Path(__file__).with_name("blender_export_mta.py")
    command = [
        str(blender),
        "--background",
        "--factory-startup",
        "--python",
        str(script),
        "--",
        str(manifest),
        str(loose_dir),
        str(dragonff_path or ""),
    ]
    # Stream instead of buffering: this step writes thousands of DFF/COL files
    # and is by far the longest part of an export, so its progress has to reach
    # the terminal while it runs. stderr is merged so the log stays complete.
    lines: list[str] = []
    with subprocess.Popen(
        command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, encoding="utf-8", errors="replace", bufsize=1,
    ) as process:
        for line in process.stdout or ():
            lines.append(line)
            parsed = parse_blender_progress(line)
            if parsed is not None:
                stage, current, total = parsed
                report_progress(f"Blender: {stage}", current, total, None)
        returncode = process.wait()
    log = "".join(lines)
    (stage_dir / "blender.log").write_text(log, encoding="utf-8")
    if returncode != 0 or '"status": "ok"' not in log:
        raise RuntimeError(f"Blender/DragonFF export failed ({returncode}); see {stage_dir / 'blender.log'}")
    marker = next((line[len("MTA_EXPORT ") :] for line in log.splitlines() if line.startswith("MTA_EXPORT ")), None)
    bridge_report = json.loads(marker) if marker else {}
    return loose_dir, log, bridge_report


def _archive_parts(
    output_dir: Path,
    stem: str,
    files: list[Path],
    rollover_bytes: int,
) -> tuple[list[Path], list[dict[str, int]]]:
    groups: list[list[Path]] = []
    current: list[Path] = []
    current_size = 0
    for path in sorted(files, key=lambda value: value.name.lower()):
        estimated = ((path.stat().st_size + 2047) // 2048) * 2048 + 32
        if current and current_size + estimated > rollover_bytes:
            groups.append(current)
            current, current_size = [], 0
        current.append(path)
        current_size += estimated
    if current:
        groups.append(current)
    archives, stats = [], []
    for index, group in enumerate(groups):
        name = f"{stem}.img" if index == 0 else f"{stem}_{index}.img"
        archive = output_dir / name
        stat = write_img_v2(archive, [ImgEntry(path.name, path.read_bytes()) for path in group])
        archives.append(archive)
        stats.append(stat)
    return archives, stats


def _indent_write(root: ET.Element, path: Path) -> None:
    ET.indent(root, space="    ")
    ET.ElementTree(root).write(path, encoding="unicode", xml_declaration=False, short_empty_elements=False)


def _number(value: float) -> str:
    if abs(value) < 5e-10:
        value = 0.0
    return f"{value:.9g}"


def _img_archive_declarations(archive_paths: list[Path]) -> list[dict[str, int | str]]:
    maxima: dict[str, int] = {}
    for archive in archive_paths:
        stem = archive.stem
        base, separator, suffix = stem.rpartition("_")
        if separator and suffix.isdigit():
            name, index = base, int(suffix)
        else:
            name, index = stem, 0
        maxima[name] = max(maxima.get(name, 0), index)
    preferred = {"dff": 0, "col": 1, "txd": 2}
    return [
        {"name": name, "max": maximum}
        for name, maximum in sorted(maxima.items(), key=lambda item: (preferred.get(item[0], 99), item[0]))
    ]


def _write_water_dat(
    root: Path,
    source: Path | None,
    scene: MtaScene | None = None,
    offset: tuple[float, float, float] = (0.0, 0.0, 0.0),
) -> dict[str, Any]:
    target = root / "water.dat"
    if source is not None:
        content = source.read_bytes()
        target.write_bytes(content)
        return {"status": "copied", "source": str(source), "bytes": len(content)}
    if scene is not None and scene.water_quads:
        if len(scene.water_quads) > _MTA_WATER_SAFE_QUAD_BUDGET:
            raise ValueError(
                f"water.dat would contain {len(scene.water_quads)} quads; "
                f"safe MTA pool budget is {_MTA_WATER_SAFE_QUAD_BUDGET}"
            )
        lines = []
        source_points = [
            tuple(corner[axis] + offset[axis] for axis in range(3))
            for water in scene.water_quads
            for corner in water.corners
        ]
        clipped_corners = 0
        emitted_points: list[tuple[float, float, float]] = []
        for water in scene.water_quads:
            values: list[str] = []
            emitted_quad: list[tuple[float, float, float]] = []
            for corner in water.corners:
                source_point = tuple(corner[axis] + offset[axis] for axis in range(3))
                emitted_point = (
                    max(-3000.0, min(3000.0, source_point[0])),
                    max(-3000.0, min(3000.0, source_point[1])),
                    max(-1000.0, min(1000.0, source_point[2])),
                )
                if emitted_point != source_point:
                    clipped_corners += 1
                emitted_points.append(emitted_point)
                emitted_quad.append(emitted_point)
                values.extend(_number(value) for value in emitted_point)
                values.extend(("0", "0", "1", "0"))
            south_west, south_east, north_west, north_east = emitted_quad
            if not (
                south_west[0] < south_east[0]
                and north_west[0] < north_east[0]
                and south_west[1] < north_west[1]
                and south_east[1] < north_east[1]
            ):
                raise ValueError(
                    "water.dat contains a quad that MTA CreateQuad would reject; "
                    f"expected SW,SE,NW,NE but got {emitted_quad}"
                )
            values.append(str(water.water_type))
            lines.append(" ".join(values))
        content = ("\n".join(lines) + "\n").encode("ascii")
        target.write_bytes(content)
        def bounds(points: list[tuple[float, float, float]]) -> dict[str, list[float]]:
            return {
                "min": [min(point[axis] for point in points) for axis in range(3)],
                "max": [max(point[axis] for point in points) for axis in range(3)],
            }
        return {
            "status": "generated",
            "source": "HP2 WATER visible mesh",
            "quads": len(scene.water_quads),
            "bytes": len(content),
            "source_bounds": bounds(source_points),
            "bounds": bounds(emitted_points),
            "clipped_corners": clipped_corners,
            "safe_quad_budget": _MTA_WATER_SAFE_QUAD_BUDGET,
            "corner_order": "SW_SE_NW_NE",
        }
    else:
        # EagleLoader probes every map resource for water.dat. A single
        # newline is a valid zero-quad file and avoids a misleading error.
        target.write_bytes(b"\n")
        return {"status": "placeholder", "source": None, "bytes": 1}


def _write_resource_xml(
    scene: MtaScene,
    root: Path,
    author: str,
    archive_paths: list[Path],
    offset: tuple[float, float, float],
) -> list[dict[str, int | str]]:
    models = {model.model_id: model for model in scene.models}
    definitions_by_zone: dict[str, list[Any]] = {zone: [] for zone in scene.zones}
    placements_by_zone: dict[str, list[Any]] = {zone: [] for zone in scene.zones}
    for model in scene.models:
        definitions_by_zone[model.zone].append(model)
    for placement in scene.placements:
        placements_by_zone[placement.zone].append(placement)
    zones_root = root / "zones"
    for zone in scene.zones:
        zone_dir = zones_root / zone
        zone_dir.mkdir(parents=True, exist_ok=True)
        definition_root = ET.Element("zoneDefinitions")
        # EagleLoader/GTA convention: register high-detail definitions first,
        # then their LOD* models. This also keeps the final definition from
        # accidentally being a detail model while the async loader drains.
        for model in sorted(definitions_by_zone[zone], key=lambda value: (value.is_lod, value.model_id.lower())):
            attrs = {
                "id": model.model_id,
                "dff": model.model_id,
                "txd": f"track{scene.track_id:02d}",
                "lodDistance": _number(model.lod_distance),
                "zone": zone,
                "disable_backface_culling": "true",
            }
            flags = ["disable_backface_culling"]
            if model.draw_last:
                flags.append("draw_last")
                attrs["draw_last"] = "true"
            if model.additive:
                flags.append("additive")
                attrs["additive"] = "true"
            if model.no_zbuffer_write:
                flags.append("no_zbuffer_write")
                attrs["no_zbuffer_write"] = "true"
            attrs["flags"] = ",".join(flags)
            # GTA also uses COL bounds for streaming. Models without physical
            # collision receive a same-name bounds-only COL3.
            attrs["col"] = model.model_id
            attrs.update(definition_attributes(model))
            ET.SubElement(definition_root, "definition", attrs)
        _indent_write(definition_root, zone_dir / f"{zone}.definition")

        map_root = ET.Element("map")
        ET.SubElement(map_root, "info", {"name": "map_tools_ps2", "author": author, "version": "1.0"})
        for placement in sorted(
            placements_by_zone[zone],
            key=lambda value: (value.model_id.upper().startswith("LOD"), value.model_id.lower(), value.position),
        ):
            placement_attrs = {
                    "id": placement.model_id,
                    "posX": _number(placement.position[0] + offset[0]),
                    "posY": _number(placement.position[1] + offset[1]),
                    "posZ": _number(placement.position[2] + offset[2]),
                    "rotX": _number(placement.rotation[0]),
                    "rotY": _number(placement.rotation[1]),
                    "rotZ": _number(placement.rotation[2]),
                    "overrideFlags": "double_sided",
                }
            if placement.lod_parent:
                placement_attrs["lodParent"] = placement.lod_parent
            if placement.unique_id:
                placement_attrs["uniqueID"] = placement.unique_id
            placement_attrs.update(placement_attributes(models[placement.model_id]))
            ET.SubElement(map_root, placement.element_type, placement_attrs)
        _indent_write(map_root, zone_dir / f"{zone}.map")

    zone_lines = []
    if any(abs(value) > 1e-10 for value in offset):
        # Placements already contain the requested offset. Keep the list free
        # of an offset directive to prevent EagleLoader applying it twice.
        pass
    zone_lines.extend(scene.zones)
    (root / "eagleZones.txt").write_text("\n".join(zone_lines) + "\n", encoding="utf-8")

    archive_declarations = _img_archive_declarations(archive_paths)
    default_img_names = {"dff", "col", "txd", "custom"}
    needs_img_override = any(str(value["name"]) not in default_img_names for value in archive_declarations)
    if needs_img_override:
        img_config = ET.Element("eagleLoader")
        for declaration in archive_declarations:
            ET.SubElement(
                img_config,
                "img",
                {"name": str(declaration["name"]), "max": str(declaration["max"])},
            )
        _indent_write(img_config, root / "eagleLoader-imgs.xml")

    meta = ET.Element("meta")
    ET.SubElement(meta, "info", {"trackpack": "true", "author": author, "version": "1.0.0", "name": scene.resource_name})
    ET.SubElement(meta, "file", {"src": "eagleZones.txt", "type": "client"})
    ET.SubElement(meta, "file", {"src": "zones/*/*.map", "type": "client"})
    ET.SubElement(meta, "file", {"src": "zones/*/*.definition", "type": "client"})
    if needs_img_override:
        ET.SubElement(meta, "file", {"src": "eagleLoader-imgs.xml", "type": "client"})
    ET.SubElement(meta, "file", {"src": "water.dat", "type": "client"})
    for archive in archive_paths:
        ET.SubElement(meta, "file", {"src": f"imgs/{archive.name}", "type": "client"})
    _indent_write(meta, root / "meta.xml")
    return archive_declarations


def export_mta_resource(
    scene: MtaScene,
    textures: Any,
    output_dir: Path,
    *,
    author: str,
    blender_path: Path | None = None,
    dragonff_path: Path | None = None,
    keep_intermediate: bool = False,
    rollover_bytes: int = 1_500_000_000,
    offset: tuple[float, float, float] = (0.0, 0.0, 0.0),
    water_dat: Path | None = None,
) -> Path:
    if water_dat is not None and not water_dat.is_file():
        raise FileNotFoundError(f"water.dat file not found: {water_dat}")
    if output_dir.exists() and any(output_dir.iterdir()):
        raise FileExistsError(f"output directory is not empty: {output_dir}")
    output_dir.mkdir(parents=True, exist_ok=True)
    blender = find_blender(blender_path)
    report_progress("Preparing LOD meshes", 0, 4, None)
    _prepare_eagle_lods(scene)
    report_progress("Preparing LOD meshes", 1, 4, None)
    stage_dir = Path(tempfile.mkdtemp(prefix=f"{scene.resource_name}_mta_", dir=output_dir.parent))
    try:
        report_progress("Running Blender export", 2, 4, None)
        loose_dir, blender_log, bridge_report = _run_blender(scene, textures, stage_dir, blender, dragonff_path)
        img_dir = output_dir / "imgs"
        img_dir.mkdir(parents=True, exist_ok=True)
        archive_paths: list[Path] = []
        archive_report: dict[str, Any] = {}
        for stem, files in (
            ("dff", list((loose_dir / "dff").glob("*.dff"))),
            ("col", list((loose_dir / "col").glob("*.col"))),
            ("txd", [loose_dir / f"track{scene.track_id:02d}.txd"]),
        ):
            files = [path for path in files if path.exists()]
            if not files:
                continue
            archives, stats = _archive_parts(img_dir, stem, files, rollover_bytes)
            archive_paths.extend(archives)
            archive_report[stem] = stats
        water_report = _write_water_dat(output_dir, water_dat, scene, offset)
        water_path = output_dir / "water.dat"
        if not water_path.is_file():
            raise RuntimeError(f"water.dat was not written to the MTA resource: {water_path}")
        water_report = {**water_report, "file": "water.dat", "path": str(water_path)}
        report_progress("Writing MTA resource", 3, 4, None)
        # Standalone maps use native IDE flags; animation belongs to the managed runtime.
        animation_assets = {"status": "disabled", "reason": "standard Eagle export", "files": []}
        img_declarations = _write_resource_xml(scene, output_dir, author, archive_paths, offset)

        dff_entries = {name[:-4] for archive in archive_paths if archive.name.startswith("dff") for _off, _size, name in read_img_v2_directory(archive) if name.endswith(".dff")}
        col_entries = {name[:-4] for archive in archive_paths if archive.name.startswith("col") for _off, _size, name in read_img_v2_directory(archive) if name.endswith(".col")}
        expected_dff = {model.model_id for model in scene.models}
        expected_col = {model.model_id for model in scene.models}
        if any(model_id.startswith(f"t{scene.track_id:02d}_c_") for model_id in expected_dff):
            raise RuntimeError("obsolete t##_c_* collision-carrier DFF was generated")
        blender_match = re.search(r"Blender ([^\r\n]+)", blender_log)
        dragonff_version = "unknown"
        if dragonff_path and (dragonff_path / "blender_manifest.toml").exists():
            manifest_text = (dragonff_path / "blender_manifest.toml").read_text(encoding="utf-8")
            version_match = re.search(r'^version\s*=\s*"([^"]+)"', manifest_text, re.MULTILINE)
            if version_match:
                dragonff_version = version_match.group(1)
        dff_center_error = float(bridge_report.get("max_prop_local_aabb_center_error", 0.0))
        lod_readback = bridge_report.get("lod", [])
        generated_lods = [value for value in lod_readback if value.get("status") == "generated"]
        skipped_lod_records = [value for value in lod_readback if value.get("status") == "skipped"]
        report = dict(scene.report)
        report.update(
            {
                "resource_name": scene.resource_name,
                "output": str(output_dir),
                "blender": str(blender),
                "blender_version": blender_match.group(1) if blender_match else "unknown",
                "dragonff_path": str(dragonff_path) if dragonff_path else "auto",
                "dragonff_version": dragonff_version,
                "dff_entries": len(dff_entries),
                "col_entries": len(col_entries),
                "missing_dff": sorted(expected_dff - dff_entries),
                "missing_col": sorted(expected_col - col_entries),
                "dff_without_same_name_col": sorted(dff_entries - col_entries),
                "col_without_same_name_dff": sorted(col_entries - dff_entries),
                "archives": archive_report,
                "img_override": {
                    "mode": "custom" if any(
                        str(value["name"]) not in {"dff", "col", "txd", "custom"}
                        for value in img_declarations
                    ) else "default",
                    "file": "eagleLoader-imgs.xml" if any(
                        str(value["name"]) not in {"dff", "col", "txd", "custom"}
                        for value in img_declarations
                    ) else None,
                    "archives": img_declarations,
                    "actual_files": [archive.name for archive in archive_paths],
                },
                "water_dat": water_report,
                "texture_animation_assets": animation_assets,
                "warnings": scene.warnings,
                "blender_status": "ok" if '"status": "ok"' in blender_log else "completed",
                "dragonff_readback": bridge_report,
                "dff_prop_local_aabb_center_error": dff_center_error,
                "dff_max_local_aabb_center_error": bridge_report.get("max_local_aabb_center_error", 0.0),
                "high_detail_models": sum(not model.is_lod for model in scene.models),
                "generated_lod_models": len(generated_lods),
                "skipped_lod_models": len(skipped_lod_records),
                "lod_generation": lod_readback,
                "lod_triangle_ratios": [
                    value["output_triangles"] / value["source_triangles"]
                    for value in generated_lods if value.get("source_triangles")
                ],
                "max_dff_vertices": bridge_report.get("max_dff_vertices", 0),
                "max_dff_col_bounds_error": max(
                    float(bridge_report.get("max_bounds_only_col_error", 0.0)),
                    float(bridge_report.get("max_mesh_col_bounds_error", 0.0)),
                ),
                "txd_alpha": bridge_report.get("txd_alpha", {}),
            }
        )
        report_path = output_dir / f"{scene.resource_name}.mta.report.json"
        report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
        report_progress("Writing MTA resource", 4, 4, report_path.name)
        if (
            report["missing_dff"]
            or report["missing_col"]
            or report["dff_without_same_name_col"]
            or report["col_without_same_name_dff"]
        ):
            raise RuntimeError(f"MTA archive validation failed; see {report_path}")
        logical_center_error = float(scene.report.get("max_logical_pivot_error", 0.0))
        if logical_center_error > 0.001:
            raise RuntimeError(
                "MTA scene contains an off-center logical streaming chunk "
                f"(maximum combined AABB center error {logical_center_error:.9g}); see {report_path}"
            )
        if keep_intermediate:
            # Debug staging must never become part of the MTA resource.
            destination = output_dir.with_name(output_dir.name + ".intermediate")
            shutil.copytree(stage_dir, destination)
        return report_path
    except Exception:
        # Preserve failed staging beside the resource so meta.xml wildcards or
        # resource scanners cannot accidentally expose debug assets to MTA.
        failure = output_dir.with_name(output_dir.name + ".failed-intermediate")
        if stage_dir.exists() and not failure.exists():
            shutil.copytree(stage_dir, failure)
        raise
    finally:
        if stage_dir.exists():
            shutil.rmtree(stage_dir)
