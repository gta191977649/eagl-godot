"""Family-wide Eagle asset sharing with per-track placement manifests."""
from __future__ import annotations

from .dynamic_physics import definition_attributes, placement_attributes, definition_physics_key

import hashlib
import json
import pickle
import tempfile
import xml.etree.ElementTree as ET
from collections import Counter
from dataclasses import asdict, replace
from pathlib import Path

from .chunks import parse_chunks
from .comp import load_bundle_bytes
from .img_archive import ImgEntry, write_img_v2
from .model import parse_scene
from .mta_export import (_prepare_eagle_lods, _run_blender, _indent_write,
                         find_blender, _BARRIER_ANIMATION_FX)
from .mta_scene import MtaScene, build_mta_scene
from .progress import report_progress
from .race_catalog import FAMILIES, load_profiles, validate_profile
from .route_export import write_route_txt
from .textures import TextureLibrary, load_texture_library_for_track
from .special_textures import (
    SPECIAL_TEXTURE_CONTRACT_VERSION,
    SPECIAL_TEXTURE_PREFIXES,
    canonical_texture_name,
    reflection_layer_for_texture,
)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()).hexdigest()


def geometry_key(model):
    return digest({k: getattr(model, k) for k in ("vertices", "faces", "uvs", "colors", "face_materials")}
                  | {"materials": [asdict(m) for m in model.materials], "is_lod": model.is_lod})


def definition_key(model, geometry=None):
    return digest([geometry or geometry_key(model), model.collision_vertices,
                   model.collision_faces, model.collision_materials, model.collision_kind,
                   definition_physics_key(model), model.lod_distance, model.draw_last,
                   model.additive, model.no_zbuffer_write])


def texture_key(texture, alpha, cutoff, category, animation=None, role=None, effect=None):
    # Equal pixels are not interchangeable when shaders animate them with
    # different phase offsets. Keep surface and animation identities intact.
    values = [hashlib.sha256(texture.png).hexdigest(), texture.width,
              texture.height, alpha, cutoff, category, animation]
    # Preserve every pre-feature canonical name; only special variants add a
    # new identity component.
    if role is not None:
        values.append(role)
    if effect is not None:
        values.append(effect)
    return digest(values)


def export_family(game_dir: Path, output: Path, base: int, *, blender=None, dragonff=None, author="map_tools_ps2"):
    if base not in FAMILIES:
        raise ValueError(f"unknown family {base}")
    if output.exists() and any(output.iterdir()):
        raise FileExistsError(f"output must be new or empty: {output}")
    output.mkdir(parents=True, exist_ok=True)
    (output / "imgs").mkdir()
    (output / "zones" / "shared").mkdir(parents=True)
    (output / "tracks").mkdir()
    (output / "effects").mkdir()
    (output / "effects" / "barrier.fx").write_text(_BARRIER_ANIMATION_FX, encoding="utf-8")
    (output / "effects" / "additive.fx").write_text(
        (Path(__file__).with_name("data") / "additive.fx").read_text(encoding="utf-8"), encoding="utf-8"
    )
    profiles = load_profiles()
    library = TextureLibrary({})
    merged = MtaScene(base, output.name, [], [], ["shared"], {}, [], {"lod_mode": "off"})
    models, geom_names, geometry_by_id, texture_keys, tracks = {}, {}, {}, {}, {}
    synthetic_keys: dict[int, str] = {}
    canonical_keys: dict[str, str] = {}
    original_models = original_textures = original_texture_bytes = 0
    model_occurrences = Counter()
    special_by_name = {}
    family = FAMILIES[base]
    track_ids = list(range(base + 1, base + 7))
    prepare_stage = f"Family {family}: preparing tracks"
    report_progress(prepare_stage, 0, len(track_ids), None)
    for track_index, track_id in enumerate(track_ids, 1):
        report_progress(prepare_stage, track_index - 1, len(track_ids), f"track {track_id}")
        source = game_dir / "ZZDATA" / "TRACKS" / f"TRACKB{track_id}.LZC"
        if not source.exists():
            source = source.with_suffix(".BUN")
        data = load_bundle_bytes(source)
        scene = parse_scene(parse_chunks(data), data)
        textures = load_texture_library_for_track(source)
        profile = profiles[track_id]
        validate_profile(profile, scene.track_route_segments, scene.track_route_edges)
        track_dir = output / "tracks" / str(track_id)
        track_dir.mkdir()
        write_route_txt(scene, track_dir / "route.txt", track=track_id)
        cache_root = output.parent / ".hp2_export_cache"
        cache_root.mkdir(exist_ok=True)
        dependencies = [Path(__file__).with_name(name) for name in ("mta_scene.py", "managed_collision.py", "mta_lod.py", "model.py", "textures.py", "source_physics.py", "dynamic_physics.py")]
        stamp = digest([hashlib.sha256(data).hexdigest(),
                        *[hashlib.sha256(p.read_bytes()).hexdigest() for p in dependencies],
                        *[hashlib.sha256(p.read_bytes()).hexdigest() for p in textures.source_paths]])
        cache = cache_root / f"{track_id}_{stamp}.pickle"
        if cache.is_file():
            with cache.open("rb") as handle:
                mta = pickle.load(handle)  # local exporter-owned build cache only
        else:
            mta = build_mta_scene(scene, textures, track_id=track_id, resource_name=output.name, native_collision_overflow=True)
            _prepare_eagle_lods(mta)
            with cache.open("wb") as handle:
                pickle.dump(mta, handle, protocol=pickle.HIGHEST_PROTOCOL)
        (track_dir / "scene.report.json").write_text(json.dumps(mta.report, indent=2) + "\n", encoding="utf-8")
        texture_remap = {}
        original_textures += len(mta.texture_variants)
        texture_items = sorted(mta.texture_variants.items(), key=lambda item: str(item[0]))
        texture_stage = f"Family {family}: sharing textures (track {track_id})"
        report_progress(texture_stage, 0, len(texture_items), None)
        for texture_index, ((tex_hash, alpha, category, role), name) in enumerate(texture_items, 1):
            report_progress(texture_stage, texture_index, len(texture_items), name)
            texture = textures.get(tex_hash)
            if texture is None:
                raise ValueError(f"track {track_id}: missing texture {tex_hash:x}")
            cutoff = next((m.alpha_cutoff for model in mta.models for m in model.materials
                           if m.texture_name == name), None)
            animation = next(([a.phase, a.frames_per_second,
                               [hashlib.sha256(textures.get(h).png).hexdigest() for h in a.frame_hashes]]
                              for a in mta.texture_animations if a.target_texture_name == name), None)
            source_evidence = mta.report.get("special_texture_evidence", {}).get(f"0x{tex_hash:08x}", {})
            effect_identity = None
            if role == "uv_scroll":
                effect_identity = [source_evidence.get("flags"), source_evidence.get("u"), source_evidence.get("v")]
            elif role == "uv_rotate":
                effect_identity = [source_evidence.get("flags"), source_evidence.get("rotation")]
            key = texture_key(texture, alpha, cutoff, category, animation, role, effect_identity)
            original_texture_bytes += len(texture.png)
            canonical = canonical_texture_name(key, surface=category, special=role)
            synthetic = int(key[:12], 16)
            if len(canonical) > 31:
                raise ValueError(f"MTA texture name exceeds 31 visible characters: {canonical}")
            if synthetic in synthetic_keys and synthetic_keys[synthetic] != key:
                raise ValueError(f"texture synthetic-hash collision: {canonical}")
            if canonical in canonical_keys and canonical_keys[canonical] != key:
                raise ValueError(f"texture canonical-name collision: {canonical}")
            synthetic_keys[synthetic] = key
            canonical_keys[canonical] = key
            library.textures[synthetic] = replace(texture, tex_hash=synthetic)
            merged.texture_variants[(synthetic, alpha, category, role)] = canonical
            merged.texture_names[synthetic] = canonical
            texture_remap[name] = (synthetic, canonical)
            texture_keys[key] = len(texture.png)
        track_special_names = set()
        for model in mta.models:
            for material_index, material in enumerate(model.materials):
                if not material.special_role or not material.texture_name:
                    continue
                target = texture_remap.get(material.texture_name)
                source_texture = textures.get(material.texture_hash)
                if target is None or source_texture is None:
                    continue
                canonical = target[1]
                track_special_names.add(canonical)
                record = special_by_name.setdefault(canonical, {
                    "name": canonical,
                    "effectKind": material.special_role,
                    "prefix": SPECIAL_TEXTURE_PREFIXES[material.special_role],
                    "sourceName": source_texture.name,
                    "sourceHash": f"0x{material.texture_hash:08x}",
                    "tracks": set(), "bindings": [],
                    "sourceAlphaMode": material.source_alpha_mode,
                    "sourceAlphaCutoff": material.source_alpha_cutoff,
                    "exportAlphaMode": material.alpha_mode,
                    **(
                        {"reflectionLayer": reflection_layer_for_texture(source_texture)}
                        if material.special_role == "reflection" else {}
                    ),
                    "evidence": mta.report.get("special_texture_evidence", {}).get(
                        f"0x{material.texture_hash:08x}",
                        {"kind": "reflection", "source": "native_collision_material", "materialIds": [4, 20]}
                        if material.special_role == "reflection" else {},
                    ),
                })
                record["tracks"].add(track_id)
                binding = {
                    "track": track_id, "object": model.source_name,
                    "objectOffset": f"0x{model.source_offset:08x}" if model.source_offset is not None else None,
                    "materialIndex": material_index,
                    "submeshes": list(material.source_submeshes),
                    "textureSlots": list(material.source_texture_slots),
                }
                if binding not in record["bindings"]:
                    record["bindings"].append(binding)
        remap = {}
        original_models += len(mta.models)
        model_stage = f"Family {family}: sharing models (track {track_id})"
        report_progress(model_stage, 0, len(mta.models), None)
        for model_index, model in enumerate(mta.models, 1):
            report_progress(model_stage, model_index, len(mta.models), model.model_id)
            model.materials = [replace(material, texture_hash=texture_remap[material.texture_name][0],
                texture_name=texture_remap[material.texture_name][1]) if material.texture_name in texture_remap
                else material for material in model.materials]
            geom = geometry_key(model)
            key = definition_key(model, geom)
            canonical = f"h{base}_" + key[:15]
            remap[model.model_id] = canonical
            model_occurrences[canonical] += 1
            if canonical not in models:
                # LOD meshes are already materialized by _prepare_eagle_lods.
                shared = replace(model, model_id=canonical, zone="shared", lod_source_id=None)
                models[canonical] = shared
                merged.models.append(shared)
                geometry_by_id[canonical] = geom
                geom_names.setdefault(geom, canonical)
        placements = ET.Element("map")
        ET.SubElement(placements, "info", {"name": f"HP2 track {track_id}", "author": author})
        for index, placement in enumerate(mta.placements):
            attrs = {"id": remap[placement.model_id],
                **dict(zip(("posX", "posY", "posZ"), map(str, placement.position))),
                **dict(zip(("rotX", "rotY", "rotZ"), map(str, placement.rotation))),
                "doubleSided": "true", "uniqueID": placement.unique_id or f"t{track_id}_{index}"}
            if placement.lod_parent:
                attrs["lodParent"] = remap[placement.lod_parent]
            attrs.update(placement_attributes(models[remap[placement.model_id]]))
            ET.SubElement(placements, placement.element_type, attrs)
        _indent_write(placements, track_dir / "track.map")
        animations = []
        for animation in mta.texture_animations:
            frames = []
            for tex_hash in animation.frame_hashes:
                texture = textures.get(tex_hash)
                if texture is None:
                    raise ValueError(f"missing animation frame {tex_hash:x}")
                name = "effects/" + hashlib.sha256(texture.png).hexdigest()[:24] + ".png"
                (output / name).write_bytes(texture.png)
                frames.append(name)
            target = texture_remap.get(animation.target_texture_name)
            if target:
                animations.append({"texture": target[1], "frames": frames,
                    "fps": animation.frames_per_second, "phase": animation.phase})
                special = special_by_name.get(target[1])
                if special is not None:
                    variants = special.setdefault("animationBindings", [])
                    parameters = {"name": animation.animation_name, "frames": frames,
                                  "fps": animation.frames_per_second, "phase": animation.phase}
                    if parameters not in variants:
                        variants.append(parameters)
        sky = []
        for obj in scene.objects:
            if "SKYDOME" in obj.name.upper() or "SKYBOX" in obj.name.upper():
                for tex_hash in obj.texture_hashes:
                    texture = textures.get(tex_hash)
                    if texture:
                        name = "effects/" + hashlib.sha256(texture.png).hexdigest()[:24] + ".png"
                        (output / name).write_bytes(texture.png)
                        if name not in sky:
                            sky.append(name)
        additive_textures = sorted({
            material.texture_name
            for model in mta.models if model.additive
            for material in model.materials if material.texture_name
        })
        tracks[str(track_id)] = {**profile, "routeFile": f"tracks/{track_id}/route.txt",
            "mapFile": f"tracks/{track_id}/track.map", "offset": [0, 0, 0],
            "water": [asdict(q) for q in mta.water_quads],
            "environment": {"skyTextures": sky, "animations": animations,
                            "additiveTextures": additive_textures,
                            "specialTextures": sorted(track_special_names)},
            "grid": list(vars(scene.track_route_segments[0].points[0].position_ps2).values())}
        # Grid anchor always comes from the authored route, never segment order.
        route = next(r for r in scene.track_route_segments if r.route_index == profile["spawn"]["route"])
        pos = route.points[profile["spawn"]["point"]].position_ps2
        tracks[str(track_id)]["grid"] = [pos.x, pos.y, pos.z]
    report_progress(prepare_stage, len(track_ids), len(track_ids), None)
    # meta.xml is published last, so incomplete exports cannot become available.
    with tempfile.TemporaryDirectory(prefix=f"hp2_{base}_", dir=output.parent) as temp:
        loose, log, report = _run_blender(merged, library, Path(temp), find_blender(blender), dragonff)
        (output / "blender.log").write_text(log, encoding="utf-8")
        geom_entry_names = sorted(set(geom_names.values()))
        dff_stage = f"Family {family}: packing DFF archive"
        report_progress(dff_stage, 0, len(geom_entry_names), None)
        dff_entries = []
        for dff_index, name in enumerate(geom_entry_names, 1):
            report_progress(dff_stage, dff_index, len(geom_entry_names), name)
            dff_entries.append(ImgEntry(name + ".dff", (loose / "dff" / (name + ".dff")).read_bytes()))
        cols, col_for = {}, {}
        model_names = sorted(models)
        col_stage = f"Family {family}: deduplicating COL meshes"
        report_progress(col_stage, 0, len(model_names), None)
        for col_index, name in enumerate(model_names, 1):
            report_progress(col_stage, col_index, len(model_names), name)
            payload = (loose / "col" / (name + ".col")).read_bytes()
            # COL header embeds an arbitrary model name and model ID.
            key = hashlib.sha256(payload[:8] + bytes(24) + payload[32:]).hexdigest()
            col_name = "c" + key[:18]
            cols.setdefault(col_name, payload)
            col_for[name] = col_name
        archive_stage = f"Family {family}: writing IMG archives"
        report_progress(archive_stage, 0, 3, "dff.img")
        write_img_v2(output / "imgs" / "dff.img", dff_entries)
        report_progress(archive_stage, 1, 3, "col.img")
        write_img_v2(output / "imgs" / "col.img", [ImgEntry(n + ".col", b) for n, b in sorted(cols.items())])
        txd_bytes = (loose / f"track{base:02d}.txd").read_bytes()
        report_progress(archive_stage, 2, 3, "txd.img")
        write_img_v2(output / "imgs" / "txd.img", [ImgEntry(f"family{base}.txd", txd_bytes)])
        report_progress(archive_stage, 3, 3, None)
        definitions = ET.Element("zoneDefinitions")
        definition_items = sorted(models.items())
        definition_stage = f"Family {family}: writing shared definitions"
        report_progress(definition_stage, 0, len(definition_items), None)
        for definition_index, (name, model) in enumerate(definition_items, 1):
            report_progress(definition_stage, definition_index, len(definition_items), name)
            flags = ["disable_backface_culling"]
            for flag in ("draw_last", "additive", "no_zbuffer_write"):
                if getattr(model, flag):
                    flags.append(flag)
            ET.SubElement(definitions, "definition", {"id": name, "zone": "shared",
                "dff": geom_names[geometry_by_id[name]], "col": col_for[name], "txd": f"family{base}",
                "lodDistance": str(model.lod_distance), "flags": ",".join(flags),
                **{flag: "true" for flag in flags}, **definition_attributes(model)})
        _indent_write(definitions, output / "zones" / "shared" / "shared.definition")
        savings = {"dynamic_definitions": sum(bool(m.physics) for m in models.values()),
            "dynamic_mapping_status": "native_gta_approximation_pending_game_validation",
            "models_before": original_models, "definitions_after": len(models),
            "dff_after": len(dff_entries), "col_after": len(cols),
            "textures_before": original_textures, "textures_after": len(texture_keys),
            "texture_mapping": {"canonical_names": len(canonical_keys),
                "identity_digest": digest(sorted(canonical_keys.items()))},
            "texture_png_bytes_before": original_texture_bytes, "texture_png_bytes_after": sum(texture_keys.values()),
            "dff_bytes_before_dedup": sum((loose / "dff" / (n + ".dff")).stat().st_size * model_occurrences[n] for n in models),
            "dff_bytes_after": sum(len(e.data) for e in dff_entries),
            "col_bytes_before_dedup": sum((loose / "col" / (n + ".col")).stat().st_size * model_occurrences[n] for n in models),
            "col_bytes_after": sum(map(len, cols.values())), "blender_validation": report}
    special_records = []
    for record in sorted(special_by_name.values(), key=lambda value: (value["prefix"], value["name"])):
        record["family"] = family
        record["tracks"] = sorted(record["tracks"])
        record["bindings"].sort(key=lambda value: (value["track"], value["objectOffset"] or "", value["materialIndex"]))
        evidence = record.get("evidence", {})
        if record["effectKind"] == "uv_scroll":
            record["parameters"] = {"u": evidence.get("u", 0.0), "v": evidence.get("v", 0.0)}
        elif record["effectKind"] == "uv_rotate":
            record["parameters"] = {"rotation": evidence.get("rotation")}
        special_records.append(record)
    special_payload = {"version": SPECIAL_TEXTURE_CONTRACT_VERSION, "family": FAMILIES[base], "prefixes": SPECIAL_TEXTURE_PREFIXES,
                       "textures": special_records}
    (output / "special_textures.json").write_text(json.dumps(special_payload, indent=2) + "\n", encoding="utf-8")
    manifest = {"version": 1, "family": FAMILIES[base], "resource": output.name,
                "definitions": ["zones/shared/shared.definition"],
                "specialTextures": {"version": SPECIAL_TEXTURE_CONTRACT_VERSION, "file": "special_textures.json", "prefixes": SPECIAL_TEXTURE_PREFIXES},
                "tracks": tracks}
    (output / "track_manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    (output / "sharing.report.json").write_text(json.dumps(savings, indent=2) + "\n", encoding="utf-8")
    (output / "pack_server.lua").write_text((Path(__file__).with_name("data") / "hp2_pack_server.lua").read_text(encoding="utf-8"), encoding="utf-8")
    meta = ET.Element("meta")
    ET.SubElement(meta, "info", {"name": output.name, "author": author, "hp2managed": "true", "version": "1.0"})
    ET.SubElement(meta, "script", {"src": "pack_server.lua", "type": "server"})
    for function in ("getHP2TrackManifest", "getHP2RouteText"):
        ET.SubElement(meta, "export", {"function": function, "type": "server"})
    resource_files = sorted(output.rglob("*"))
    meta_stage = f"Family {family}: listing resource files"
    report_progress(meta_stage, 0, len(resource_files), None)
    for path_index, path in enumerate(resource_files, 1):
        report_progress(meta_stage, path_index, len(resource_files), path.name)
        if path.is_file() and path.suffix not in {".log", ".lua"} and path.name != "meta.xml":
            ET.SubElement(meta, "file", {"src": path.relative_to(output).as_posix()})
    _indent_write(meta, output / "meta.xml")
    return manifest


def command(args):
    exported = []
    for base, family in FAMILIES.items():
        if args.family != "all" and args.family != family:
            continue
        pack = Path(args.output) / ("hp2_" + family + "_pack")
        export_family(Path(args.game_dir), pack, base,
            blender=Path(args.blender) if args.blender else None,
            dragonff=Path(args.dragonff_path) if args.dragonff_path else None, author=args.author)
        exported.append(pack)
    _write_special_texture_summary(Path(args.output), exported)
    return 0


def _write_special_texture_summary(output: Path, packs: list[Path]) -> None:
    records = []
    for pack in packs:
        payload = json.loads((pack / "special_textures.json").read_text(encoding="utf-8"))
        for record in payload["textures"]:
            records.append({"family": payload["family"], **record})
    records.sort(key=lambda value: (value["prefix"], value["name"], value["family"]))
    (output / "special_textures.json").write_text(
        json.dumps({"version": SPECIAL_TEXTURE_CONTRACT_VERSION, "prefixes": SPECIAL_TEXTURE_PREFIXES, "textures": records}, indent=2) + "\n",
        encoding="utf-8",
    )
    lines = [
        "# HP2 special textures", "",
        "| Prefix | Canonical texture | Effect | Layer | Source | Hash | Family | Tracks | Source alpha | Export alpha | Evidence |",
        "|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    for record in records:
        evidence = record.get("evidence", {})
        source = evidence.get("source", "")
        track_list = ", ".join(map(str, record["tracks"]))
        source_alpha = record.get("sourceAlphaMode") or "OPAQUE"
        export_alpha = record.get("exportAlphaMode") or "OPAQUE"
        lines.append(
            f"| {record['prefix']} | `{record['name']}` | {record['effectKind']} | {record.get('reflectionLayer', '')} | "
            f"`{record['sourceName']}` | `{record['sourceHash']}` | {record['family']} | "
            f"{track_list} | {source_alpha} | {export_alpha} | {source} |"
        )
    lines.extend(["", "## Prefixes with no exported textures", ""])
    present = {record["prefix"] for record in records}
    missing = [prefix for prefix in SPECIAL_TEXTURE_PREFIXES.values() if prefix not in present]
    lines.append(", ".join(f"`{prefix}`" for prefix in missing) if missing else "None.")
    (output / "special_textures.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
