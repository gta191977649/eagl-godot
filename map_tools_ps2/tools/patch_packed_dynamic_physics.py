"""Apply the exporter dynamic-physics policy to existing packed resources.

This is intentionally limited to generated definition/map XML attributes; it
does not touch IMG geometry, COL, textures, manifests, or EagleLoader.
"""
from __future__ import annotations

import argparse
import xml.etree.ElementTree as ET
from pathlib import Path


def indent(node: ET.Element, level: int = 0) -> None:
    whitespace = "\n" + "    " * level
    if len(node):
        if not node.text or not node.text.strip():
            node.text = whitespace + "    "
        for child in node:
            indent(child, level + 1)
        if not node[-1].tail or not node[-1].tail.strip():
            node[-1].tail = whitespace
    if level and (not node.tail or not node.tail.strip()):
        node.tail = whitespace


PHYSICS_FIELDS = {
    "physicsRoot", "simulated", "frozen", "breakable", "respawn",
    "mass", "turnMass", "airResistance", "elasticity", "buoyancy",
    "centerOfMass",
}


def update_definition(element: ET.Element) -> bool:
    if element.get("dynamic") != "true" and element.get("physicsRoot") not in {"1218", "1233"}:
        return False
    free = element.get("physicsRoot") == "1218"
    expected = {
        "physicsRoot": "1218" if free else "1233",
        "simulated": "true", "frozen": "false", "breakable": "true",
        "respawn": "false", "mass": "50" if free else "30",
        "turnMass": "50", "airResistance": "0.99",
        "buoyancy": "50",
    }
    changed = any(element.get(key) != value for key, value in expected.items())
    for key, value in expected.items():
        element.set(key, value)
    # ``dynamic`` is placement-only. Its presence used to be how this updater
    # identified generated definitions; remove it after applying the profile.
    if "dynamic" in element.attrib:
        del element.attrib["dynamic"]
        changed = True
    return changed


def update_placement(element: ET.Element, dynamic_definitions: dict[str, dict[str, str]]) -> bool:
    defaults = dynamic_definitions.get(element.get("id", ""))
    if defaults is None and element.get("dynamic") != "true":
        return False
    changed = element.tag != "object" or element.get("dynamic") != "true"
    element.tag = "object"
    element.set("dynamic", "true")
    # Packed track_manager instantiates rows directly. Repeat the definition
    # physics on the placement so the row is complete even before inheritance.
    for key, value in (defaults or {}).items():
        if element.get(key) != value:
            element.set(key, value)
            changed = True
    return changed


def update_xml(path: Path, updater) -> int:
    tree = ET.parse(path)
    changed = sum(updater(element) for element in tree.getroot().iter())
    if changed:
        indent(tree.getroot())
        tree.write(path, encoding="utf-8", xml_declaration=True)
    return changed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("resources", type=Path)
    args = parser.parse_args()
    packs = sorted(args.resources.glob("hp2_*_pack"))
    if len(packs) != 5:
        raise ValueError(f"expected five hp2 family packs under {args.resources}, found {len(packs)}")
    totals = {"definitions": 0, "placements": 0}
    for pack in packs:
        definition_path = pack / "zones" / "shared" / "shared.definition"
        definition_tree = ET.parse(definition_path)
        dynamic_definitions = {
            element.get("id"): {
                key: value for key, value in element.attrib.items()
                if key in PHYSICS_FIELDS
            }
            for element in definition_tree.getroot()
            if element.get("dynamic") == "true" or element.get("physicsRoot") in {"1218", "1233"}
        }
        totals["definitions"] += update_xml(definition_path, update_definition)
        for map_path in sorted((pack / "tracks").glob("*/track.map")):
            totals["placements"] += update_xml(
                map_path, lambda element: update_placement(element, dynamic_definitions)
            )
    print(f"updated dynamic physics: {totals['definitions']} definitions, {totals['placements']} placements")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
