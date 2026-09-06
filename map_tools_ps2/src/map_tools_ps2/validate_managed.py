"""Validate published family packs without Blender or an MTA client.

python -m map_tools_ps2.validate_managed PATH_TO_MAP_RESOURCES
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import xml.etree.ElementTree as ET

from .img_archive import read_img_v2_directory
from .race_catalog import FAMILIES, load_profiles
from .special_textures import (
    SPECIAL_TEXTURE_CONTRACT_VERSION,
    SPECIAL_TEXTURE_NAME_MAX_VISIBLE,
    SPECIAL_TEXTURE_PREFIXES,
)


def validate_pack(pack: Path, base: int):
    manifest = json.loads((pack / "track_manifest.json").read_text())
    special_contract = manifest.get("specialTextures", {})
    assert special_contract.get("version") == SPECIAL_TEXTURE_CONTRACT_VERSION
    assert special_contract.get("prefixes") == SPECIAL_TEXTURE_PREFIXES
    special_path = special_contract.get("file")
    assert special_path == "special_textures.json"
    special = json.loads((pack / special_path).read_text(encoding="utf-8"))
    special_names = {record["name"] for record in special["textures"]}
    prefixes = tuple(special_contract["prefixes"].values())
    assert all(name.startswith(prefixes) and len(name) <= SPECIAL_TEXTURE_NAME_MAX_VISIBLE for name in special_names)
    assert len(special_names) == len(special["textures"])
    for record in special["textures"]:
        assert record["name"].startswith(SPECIAL_TEXTURE_PREFIXES[record["effectKind"]])
        if record["effectKind"] == "reflection":
            assert record.get("reflectionLayer") in {"surface", "mask"}, record["name"]
    assert not (pack / "eagleZones.txt").exists(), "managed pack must not auto-load"
    assert set(manifest["tracks"]) == {str(i) for i in range(base+1,base+7)}
    declared = {n.attrib["src"] for n in ET.parse(pack / "meta.xml").getroot() if n.tag == "file"}
    for path in declared:
        assert (pack / path).is_file(), f"missing meta file {path}"
    archives = {}
    for kind in ("dff", "col", "txd"):
        path = pack / "imgs" / (kind + ".img")
        entries = read_img_v2_directory(path)
        names = {name for _, _, name in entries}
        assert len(names) == len(entries), "duplicate IMG entry"
        for offset, sectors, name in entries:
            assert offset*2048 >= 8+len(entries)*32 and (offset+sectors)*2048 <= path.stat().st_size, name
        archives[kind] = names
    definitions = {}
    for path in manifest["definitions"]:
        for row in ET.parse(pack / path).getroot():
            attrs = row.attrib
            assert attrs["id"] not in definitions
            definitions[attrs["id"]] = attrs
            for kind in archives:
                assert attrs[kind]+"."+kind in archives[kind], (attrs["id"], kind)
    profiles = load_profiles()
    placements = carriers = 0
    for key, track in manifest["tracks"].items():
        for field in ("type", "closed", "mainLoop", "spawn", "shortcuts", "trafficPaths", "edgeEvidence"):
            assert track[field] == profiles[int(key)][field], (key, field)
        for path in (track["mapFile"], track["routeFile"]):
            assert path in declared and (pack / path).is_file()
        rows = [r.attrib for r in ET.parse(pack / track["mapFile"]).getroot() if r.tag != "info"]
        identities = {(r["id"], r.get("uniqueID")) for r in rows}
        for row in rows:
            assert row["id"] in definitions
            assert all(math.isfinite(float(row[k])) for k in ("posX","posY","posZ","rotX","rotY","rotZ"))
            if row.get("lodParent"):
                assert (row["lodParent"], row.get("uniqueID")) in identities, (key, row)
        for binding in track["environment"].get("animations", []):
            assert binding["frames"] and all(p in declared for p in binding["frames"])
        assert set(track["environment"].get("specialTextures", [])) <= special_names
        scene = json.loads((pack / "tracks" / key / "scene.report.json").read_text())
        assert scene["native_polygons_unassigned"] == 0, key
        carriers += scene.get("native_collision_carriers", 0)
        placements += len(rows)
    report = json.loads((pack / "sharing.report.json").read_text())
    assert report["blender_validation"]["status"] == "ok"
    assert report["definitions_after"] == len(definitions)
    if "texture_mapping" in report:
        assert report["texture_mapping"]["canonical_names"] == report["textures_after"]
        assert len(report["texture_mapping"]["identity_digest"]) == 64
    assert "special_textures.json" in declared
    return {"family": FAMILIES[base], "tracks": 6, "placements": placements,
            "native_collision_carriers": carriers,
            "models_before": report["models_before"], "definitions_after": len(definitions),
            "textures_before": report["textures_before"], "textures_after": report["textures_after"],
            "asset_bytes_before": report["dff_bytes_before_dedup"]+report["col_bytes_before_dedup"]+report["texture_png_bytes_before"],
            "asset_bytes_after": report["dff_bytes_after"]+report["col_bytes_after"]+report["texture_png_bytes_after"],
            "manifest_sha256": hashlib.sha256((pack / "track_manifest.json").read_bytes()).hexdigest(), "status": "ok"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    result = [validate_pack(args.root / ("hp2_"+family+"_pack"), base) for base,family in FAMILIES.items()]
    text = json.dumps({"families":result,"tracks":30,"circuits":20,"sprints":10},indent=2)+"\n"
    if args.report:
        args.report.write_text(text,encoding="utf-8")
    print(text)


if __name__ == "__main__":
    main()
