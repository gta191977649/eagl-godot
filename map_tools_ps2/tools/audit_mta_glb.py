"""Compare placed GLB roads with final MTA IMG geometry and .map placements.

Run with the exporter Python environment. DragonFF is loaded without Blender.
The report supports both older lod_candidate_models and newer road_transforms maps.
"""
from __future__ import annotations

import argparse
from collections import defaultdict
import importlib
import json
from pathlib import Path
import struct
import sys
import types
import xml.etree.ElementTree as ET

from shapely.geometry import Polygon, box
from shapely.ops import unary_union
from shapely.strtree import STRtree

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from map_tools_ps2.img_archive import read_img_v2_directory


def glb_roads(path):
    data = path.read_bytes()
    size = struct.unpack_from("<I", data, 12)[0]
    doc = json.loads(data[20:20 + size])
    binary = data[28 + size:]

    def accessor(index):
        value = doc["accessors"][index]
        view = doc["bufferViews"][value["bufferView"]]
        code = {5126: "f", 5125: "I", 5123: "H", 5121: "B"}[value["componentType"]]
        width = {"VEC3": 3, "SCALAR": 1}[value["type"]]
        fmt = "<" + code * width
        stride = view.get("byteStride", struct.calcsize(fmt))
        start = view.get("byteOffset", 0) + value.get("byteOffset", 0)
        return [struct.unpack_from(fmt, binary, start + i * stride) for i in range(value["count"])]

    roads = defaultdict(set)
    for node in doc["nodes"]:
        if "mesh" not in node:
            continue
        mesh = doc["meshes"][node["mesh"]]
        name = mesh["name"].split("_inst_")[0]
        if not name.startswith("RD_SECTION"):
            continue
        if any(key in node for key in ("matrix", "translation", "rotation", "scale")):
            raise ValueError("Expected exporter GLB with baked world positions")
        for primitive in mesh["primitives"]:
            if primitive.get("mode", 4) != 4:
                raise ValueError("Export reference with --primitive-assembly triangles")
            points = [(x, -z, y) for x, y, z in accessor(primitive["attributes"]["POSITION"])]
            indices = [item[0] for item in accessor(primitive["indices"])]
            for i in range(0, len(indices), 3):
                roads[name].add(tuple(points[index] for index in indices[i:i + 3]))
    return roads


def mta_roads(root, report, dragonff, use_lod=False):
    package = types.ModuleType("audit_dragonff")
    package.__path__ = [str(dragonff)]
    sys.modules[package.__name__] = package
    lib = importlib.import_module("audit_dragonff.gtaLib.dff")
    source_for_model = {}
    if "road_transforms" in report:
        for record in report["road_transforms"]:
            for model in record["output_models"]:
                source_for_model[model] = record["source"]
    else:
        for record in report["lod_candidate_models"]:
            if record["role"] == "road":
                source_for_model[record["detail_model"]] = record["source"]
    nodes = [node for path in (root / "zones").rglob("*.map") for node in ET.parse(path).getroot()]
    if use_lod:
        parents = {node.get("id"): node.get("lodParent") for node in nodes if node.get("lodParent")}
        source_for_model = {parents.get(model, model): source for model, source in source_for_model.items()}
    placements = defaultdict(list)
    for node in nodes:
        model = node.get("id")
        if model not in source_for_model:
            continue
        if any(float(node.get("rot" + axis, 0)) != 0 for axis in "XYZ"):
            raise ValueError("Expected world-baked MTA road placements")
        placements[model].append(tuple(float(node.get("pos" + axis, 0)) for axis in "XYZ"))
    roads = defaultdict(list)
    found = set()
    for archive in (root / "imgs").glob("*.img"):
        with archive.open("rb") as stream:
            for offset, sectors, name in read_img_v2_directory(archive):
                model = name.removesuffix(".dff")
                if not name.endswith(".dff") or model not in source_for_model:
                    continue
                found.add(model)
                stream.seek(offset * 2048)
                dff = lib.dff()
                dff.load_memory(stream.read(sectors * 2048))
                for geometry in dff.geometry_list:
                    for position in placements[model]:
                        points = [tuple(v[i] + position[i] for i in range(3)) for v in geometry.vertices]
                        roads[source_for_model[model]].extend(
                            tuple(points[i] for i in (t.a, t.b, t.c)) for t in geometry.triangles
                        )
    missing = set(source_for_model) - found
    if missing or set(source_for_model) - placements.keys():
        raise ValueError(f"Missing DFF/placement: {missing}, {set(source_for_model) - placements.keys()}")
    return roads


def bounds(triangles):
    points = [p for t in triangles for p in t]
    return [[min(p[i] for p in points) for i in range(3)], [max(p[i] for p in points) for i in range(3)]] if points else None


def compare(reference, actual, height_tolerance=0.01):
    if not reference:
        raise ValueError("No reference roads in GLB")
    records = []
    for name, triangles in sorted(reference.items()):
        output = actual.get(name, [])
        ref_polys = [Polygon([(p[0], p[1]) for p in t]) for t in triangles]
        out_polys = [Polygon([(p[0], p[1]) for p in t]) for t in output]
        expected_area, produced_area = unary_union(ref_polys), unary_union(out_polys)
        missing = expected_area.difference(produced_area).area
        extra = produced_area.difference(expected_area).area
        tree = STRtree(out_polys)
        missed_samples = 0
        max_height_error = 0.0
        # Interior samples test height as well as XY coverage; a global AABB
        # can conceal misplaced internal road segments.
        for triangle, polygon in zip(triangles, ref_polys):
            if polygon.area < 1e-8:
                continue
            x, y, z = (sum(p[i] for p in triangle) / 3 for i in range(3))
            errors = []
            for index in tree.query(box(x - 0.002, y - 0.002, x + 0.002, y + 0.002)):
                a, b, c = output[index]
                den = (b[1] - c[1]) * (a[0] - c[0]) + (c[0] - b[0]) * (a[1] - c[1])
                if abs(den) < 1e-12:
                    continue
                u = ((b[1] - c[1]) * (x - c[0]) + (c[0] - b[0]) * (y - c[1])) / den
                v = ((c[1] - a[1]) * (x - c[0]) + (a[0] - c[0]) * (y - c[1])) / den
                w = 1 - u - v
                if min(u, v, w) >= -1e-4:
                    errors.append(abs(z - (u * a[2] + v * b[2] + w * c[2])))
            if not errors:
                missed_samples += 1
            else:
                max_height_error = max(max_height_error, min(errors))
        limit = max(0.02, expected_area.area * 0.0001)
        records.append({
            "source": name, "reference_triangles": len(triangles), "output_triangles": len(output),
            "reference_bounds": bounds(triangles), "output_bounds": bounds(output),
            "reference_xy_area": expected_area.area, "missing_xy_area": missing, "extra_xy_area": extra,
            "missing_centroid_samples": missed_samples, "max_height_error": max_height_error,
            "passed": missing <= limit and extra <= limit and missed_samples == 0 and max_height_error < height_tolerance,
        })
    return {"passed": all(r["passed"] for r in records), "height_tolerance": height_tolerance, "roads": len(records),
            "failed_roads": sum(not r["passed"] for r in records), "records": records}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("glb", type=Path)
    parser.add_argument("resource", type=Path)
    parser.add_argument("--dragonff", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--lod", action="store_true", help="Use each actual lodParent; retain details without a LOD")
    parser.add_argument("--height-tolerance", type=float, default=0.01)
    args = parser.parse_args()
    reports = list(args.resource.glob("*.mta.report.json"))
    if len(reports) != 1:
        raise ValueError("Expected exactly one MTA report")
    report = json.loads(reports[0].read_text())
    result = compare(glb_roads(args.glb), mta_roads(args.resource, report, args.dragonff, args.lod), args.height_tolerance)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({k: v for k, v in result.items() if k != "records"}))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
