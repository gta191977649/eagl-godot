from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any

from .img_archive import ImgEntry, read_img_v2_directory, write_img_v2
from .mta_scene import MtaScene


DEFAULT_BLENDER_PATHS = (
    Path(r"C:\Program Files\Blender Foundation\Blender 4.5\blender.exe"),
    Path(r"C:\Program Files\Blender Foundation\Blender 4.4\blender.exe"),
    Path(r"C:\Program Files\Blender Foundation\Blender 4.3\blender.exe"),
)


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
        (material.texture_hash, material.alpha_mode): material.alpha_cutoff
        for model in scene.models
        for material in model.materials
        if material.texture_hash is not None
    }
    variants = scene.texture_variants or {
        (tex_hash, (textures.get(tex_hash).alpha_mode or "OPAQUE")): name
        for tex_hash, name in scene.texture_names.items()
        if textures.get(tex_hash) is not None
    }
    for (tex_hash, alpha_mode), texture_name in sorted(variants.items()):
        texture = textures.get(tex_hash)
        if texture is None:
            continue
        filename = f"{texture_name}.png"
        (texture_dir / filename).write_bytes(texture.png)
        record = {
            "hash": tex_hash,
            "name": texture_name,
            "file": f"textures/{filename}",
            "has_alpha": alpha_mode != "OPAQUE",
            "alpha_mode": alpha_mode,
            "alpha_cutoff": cutoff_by_variant.get((tex_hash, alpha_mode)),
            "source_alpha_mode": texture.alpha_mode or "OPAQUE",
        }
        texture_records.append(record)

    material_catalog: list[dict[str, Any]] = []
    material_indices: dict[tuple[int | None, str | None, str], int] = {}
    model_records = []
    for model in scene.models:
        model_materials = []
        for material in model.materials:
            key = (material.texture_hash, material.texture_name, material.alpha_mode)
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
                    }
                )
            model_materials.append(material_indices[key])
        model_records.append(
            {
                "model_id": model.model_id,
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
            }
        )
    manifest = {
        "version": 1,
        "models": model_records,
        "textures": texture_records,
        "material_catalog": material_catalog,
        "txd_file": f"track{scene.track_id:02d}.txd",
    }
    path = root / "mta_stage.json"
    path.write_text(json.dumps(manifest, separators=(",", ":")), encoding="utf-8")
    return path


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
    result = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", errors="replace")
    log = (result.stdout or "") + ("\n" + result.stderr if result.stderr else "")
    (stage_dir / "blender.log").write_text(log, encoding="utf-8")
    if result.returncode != 0 or '"status": "ok"' not in log:
        raise RuntimeError(f"Blender/DragonFF export failed ({result.returncode}); see {stage_dir / 'blender.log'}")
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
                values.extend(_number(value) for value in emitted_point)
                values.extend(("0", "0", "1", "0"))
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
        for model in sorted(definitions_by_zone[zone], key=lambda value: value.model_id):
            attrs = {
                "id": model.model_id,
                "dff": model.model_id,
                "txd": f"track{scene.track_id:02d}",
                "lodDistance": _number(model.lod_distance),
                "zone": zone,
                "flags": "disable_backface_culling",
                "disable_backface_culling": "true",
            }
            # GTA also uses COL bounds for streaming. Models without physical
            # collision receive a same-name bounds-only COL3.
            attrs["col"] = model.model_id
            ET.SubElement(definition_root, "definition", attrs)
        _indent_write(definition_root, zone_dir / f"{zone}.definition")

        map_root = ET.Element("map")
        ET.SubElement(map_root, "info", {"name": "map_tools_ps2", "author": author, "version": "1.0"})
        for placement in sorted(placements_by_zone[zone], key=lambda value: (value.model_id, value.position)):
            ET.SubElement(
                map_root,
                placement.element_type,
                {
                    "id": placement.model_id,
                    "posX": _number(placement.position[0] + offset[0]),
                    "posY": _number(placement.position[1] + offset[1]),
                    "posZ": _number(placement.position[2] + offset[2]),
                    "rotX": _number(placement.rotation[0]),
                    "rotY": _number(placement.rotation[1]),
                    "rotZ": _number(placement.rotation[2]),
                    "overrideFlags": "double_sided",
                },
            )
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
    eagle_scene = {
        "format": "EagleScene",
        "revision": 2,
        "sections": {
            "lights": {"lights": [], "version": 1},
            "materialClasses": {"materials": [], "version": 2},
            "materialEmitters": {"emitters": [], "version": 2},
            "safeCollisions": {"safeCollisions": [], "version": 1},
            "shadowCasters": {"overrides": [], "version": 1},
        },
        "version": 1,
    }
    (root / "EagleScene.eaglescne").write_text(json.dumps(eagle_scene, indent=2), encoding="utf-8")
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
    stage_dir = Path(tempfile.mkdtemp(prefix=f"{scene.resource_name}_mta_", dir=output_dir.parent))
    try:
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
                "warnings": scene.warnings,
                "blender_status": "ok" if '"status": "ok"' in blender_log else "completed",
                "dragonff_readback": bridge_report,
                "dff_prop_local_aabb_center_error": dff_center_error,
                "txd_alpha": bridge_report.get("txd_alpha", {}),
            }
        )
        report_path = output_dir / f"{scene.resource_name}.mta.report.json"
        report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
        if (
            report["missing_dff"]
            or report["missing_col"]
            or report["dff_without_same_name_col"]
            or report["col_without_same_name_dff"]
        ):
            raise RuntimeError(f"MTA archive validation failed; see {report_path}")
        if dff_center_error > 0.001:
            raise RuntimeError(
                "DragonFF readback found an off-center prop DFF "
                f"(maximum local AABB center error {dff_center_error:.9g}); see {report_path}"
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
