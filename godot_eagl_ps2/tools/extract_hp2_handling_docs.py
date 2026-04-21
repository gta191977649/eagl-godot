#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import struct
from collections import Counter, defaultdict
from pathlib import Path


CHUNK_GLOBAL_CAR_TABLE = 0x00034600
ROW_STRIDE = 0x560
MAX_ROWS = 64
NAME_OFFSET = 0x20
VEHICLE_TYPE_OFFSET = 0x538
WHEEL_VECTOR_OFFSETS = {
    "FL": 0x120,
    "FR": 0x140,
    "RL": 0x180,
    "RR": 0x160,
}
INFERRED_FLOAT_OFFSETS = {
    "body_center_x": 0x0F0,
    "body_center_y": 0x0F4,
    "body_center_z": 0x0F8,
    "front_suspension_travel": 0x1AC,
    "front_suspension_rest": 0x1B0,
    "rear_suspension_travel": 0x1CC,
    "rear_suspension_rest": 0x1D0,
    "body_length": 0x1E4,
    "body_width": 0x1E8,
    "body_height": 0x1EC,
    "aero_reference": 0x1F0,
    "front_tire_stiffness": 0x230,
    "front_tire_grip": 0x234,
    "front_brake_bias": 0x238,
    "front_lateral_grip": 0x23C,
    "front_longitudinal_grip": 0x240,
    "rear_tire_stiffness": 0x250,
    "rear_tire_grip": 0x254,
    "rear_brake_bias": 0x258,
    "rear_lateral_grip": 0x25C,
    "rear_longitudinal_grip": 0x260,
    "steering_response": 0x278,
    "steering_return": 0x27C,
    "steering_lock_scale": 0x280,
    "rolling_resistance": 0x284,
    "final_drive_ratio": 0x28C,
    "reverse_gear_ratio": 0x290,
    "neutral_gear_ratio": 0x294,
    "gear_ratio_1": 0x298,
    "gear_ratio_2": 0x29C,
    "gear_ratio_3": 0x2A0,
    "gear_ratio_4": 0x2A4,
    "gear_ratio_5": 0x2A8,
    "gear_ratio_6": 0x2AC,
    "mass": 0x2B0,
    "engine_peak_rpm": 0x2B4,
    "engine_redline_rpm": 0x2B8,
    "aero_drag": 0x2BC,
}
INFERRED_INT_OFFSETS = {
    "gear_count": 0x288,
}
FRONT_CURVE_OFFSETS = [0x2C0, 0x2C4, 0x2C8, 0x2CC, 0x2D0, 0x2D4, 0x2D8, 0x2DC, 0x2E0]
REAR_CURVE_OFFSETS = [0x2E4, 0x2E8, 0x2EC, 0x2F0, 0x2F4, 0x2F8]


def u32(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def f32(data: bytes, offset: int) -> float:
    return struct.unpack_from("<f", data, offset)[0]


def align(value: int, boundary: int) -> int:
    return (value + boundary - 1) & ~(boundary - 1)


def parse_chunks(data: bytes, start: int = 0, end: int | None = None) -> list[dict]:
    if end is None:
        end = len(data)
    chunks: list[dict] = []
    pos = start
    while pos + 8 <= end:
        chunk_id = u32(data, pos)
        size = u32(data, pos + 4)
        data_offset = pos + 8
        chunk_end = data_offset + size
        if chunk_end > end:
            break
        children: list[dict] = []
        if chunk_id & 0x80000000:
            children = parse_chunks(data, data_offset, chunk_end)
        chunks.append(
            {
                "id": chunk_id,
                "offset": pos,
                "data_offset": data_offset,
                "end_offset": chunk_end,
                "size": size,
                "children": children,
            }
        )
        pos = chunk_end
    return chunks


def walk_chunks(chunks: list[dict]) -> list[dict]:
    out: list[dict] = []
    for chunk in chunks:
        out.append(chunk)
        out.extend(walk_chunks(chunk["children"]))
    return out


def find_chunk(data: bytes, chunk_id: int) -> dict:
    for chunk in walk_chunks(parse_chunks(data)):
        if chunk["id"] == chunk_id:
            return chunk
    raise ValueError(f"chunk 0x{chunk_id:08X} not found")


def read_name(data: bytes, row_base: int) -> str:
    raw = data[row_base + NAME_OFFSET : row_base + NAME_OFFSET + 0x20]
    return raw.split(b"\0", 1)[0].decode("ascii", "ignore").upper()


def read_curve(data: bytes, row_base: int, offsets: list[int], label: str) -> list[dict]:
    return [
        {
            "name": f"{label}_{index}",
            "offset": offset,
            "offset_hex": f"0x{offset:03X}",
            "value": f32(data, row_base + offset),
            "confidence": "inferred",
        }
        for index, offset in enumerate(offsets)
    ]


def read_wheel_slots(data: bytes, row_base: int) -> list[dict]:
    slots: list[dict] = []
    for slot_id, offset in WHEEL_VECTOR_OFFSETS.items():
        x = f32(data, row_base + offset)
        y = f32(data, row_base + offset + 4)
        z = f32(data, row_base + offset + 8)
        radius = f32(data, row_base + offset + 12)
        slots.append(
            {
                "slot_id": slot_id,
                "offset": offset,
                "offset_hex": f"0x{offset:03X}",
                "position_ps2": {"x": x, "y": y, "z": z},
                "position_godot": {"x": y, "y": z, "z": -x},
                "wheel_radius": radius,
                "axle": "front" if slot_id.startswith("F") else "rear",
                "side": "left" if slot_id.endswith("L") else "right",
                "confidence": "verified",
            }
        )
    return slots


def derived_dimensions(wheel_slots: list[dict]) -> dict:
    by_id = {slot["slot_id"]: slot for slot in wheel_slots}
    fl = by_id["FL"]["position_ps2"]
    fr = by_id["FR"]["position_ps2"]
    rl = by_id["RL"]["position_ps2"]
    rr = by_id["RR"]["position_ps2"]
    front_center_x = (fl["x"] + fr["x"]) * 0.5
    front_center_y = (fl["y"] + fr["y"]) * 0.5
    front_center_z = (fl["z"] + fr["z"]) * 0.5
    rear_center_x = (rl["x"] + rr["x"]) * 0.5
    rear_center_y = (rl["y"] + rr["y"]) * 0.5
    rear_center_z = (rl["z"] + rr["z"]) * 0.5
    center_x = (front_center_x + rear_center_x) * 0.5
    center_y = (front_center_y + rear_center_y) * 0.5
    center_z = (front_center_z + rear_center_z) * 0.5
    return {
        "wheelbase": abs(front_center_x - rear_center_x),
        "front_track": abs(fl["y"] - fr["y"]),
        "rear_track": abs(rl["y"] - rr["y"]),
        "front_axle_center_ps2": {"x": front_center_x, "y": front_center_y, "z": front_center_z},
        "rear_axle_center_ps2": {"x": rear_center_x, "y": rear_center_y, "z": rear_center_z},
        "wheel_center_ps2": {"x": center_x, "y": center_y, "z": center_z},
    }


def read_row(data: bytes, row_index: int, row_base: int, asset_dirs: set[str]) -> dict:
    name = read_name(data, row_base)
    float_fields = {
        field_name: {
            "offset": offset,
            "offset_hex": f"0x{offset:03X}",
            "value": f32(data, row_base + offset),
            "confidence": "inferred",
        }
        for field_name, offset in INFERRED_FLOAT_OFFSETS.items()
    }
    int_fields = {
        field_name: {
            "offset": offset,
            "offset_hex": f"0x{offset:03X}",
            "value": u32(data, row_base + offset),
            "confidence": "inferred",
        }
        for field_name, offset in INFERRED_INT_OFFSETS.items()
    }
    wheel_slots = read_wheel_slots(data, row_base)
    return {
        "row_index": row_index,
        "row_offset": row_base,
        "row_offset_hex": f"0x{row_base:X}",
        "car_name": name,
        "asset_dir_exists": name in asset_dirs,
        "vehicle_type": {
            "offset": VEHICLE_TYPE_OFFSET,
            "offset_hex": f"0x{VEHICLE_TYPE_OFFSET:03X}",
            "value": u32(data, row_base + VEHICLE_TYPE_OFFSET),
            "confidence": "verified",
        },
        "wheel_slots": wheel_slots,
        "vehicle_dimensions": derived_dimensions(wheel_slots),
        "inferred_float_fields": float_fields,
        "inferred_int_fields": int_fields,
        "front_curve": read_curve(data, row_base, FRONT_CURVE_OFFSETS, "front_curve"),
        "rear_curve": read_curve(data, row_base, REAR_CURVE_OFFSETS, "rear_curve"),
    }


def summary_row(row: dict, duplicate_index: int, duplicate_count: int) -> dict:
    f = {k: v["value"] for k, v in row["inferred_float_fields"].items()}
    i = {k: v["value"] for k, v in row["inferred_int_fields"].items()}
    w = {slot["slot_id"]: slot for slot in row["wheel_slots"]}
    dims = row["vehicle_dimensions"]
    return {
        "row_index": row["row_index"],
        "car_name": row["car_name"],
        "asset_dir_exists": row["asset_dir_exists"],
        "duplicate_index": duplicate_index,
        "duplicate_count": duplicate_count,
        "vehicle_type": row["vehicle_type"]["value"],
        "mass": f["mass"],
        "engine_peak_rpm": f["engine_peak_rpm"],
        "engine_redline_rpm": f["engine_redline_rpm"],
        "gear_count": i["gear_count"],
        "final_drive_ratio": f["final_drive_ratio"],
        "reverse_gear_ratio": f["reverse_gear_ratio"],
        "neutral_gear_ratio": f["neutral_gear_ratio"],
        "gear_ratio_1": f["gear_ratio_1"],
        "gear_ratio_2": f["gear_ratio_2"],
        "gear_ratio_3": f["gear_ratio_3"],
        "gear_ratio_4": f["gear_ratio_4"],
        "gear_ratio_5": f["gear_ratio_5"],
        "gear_ratio_6": f["gear_ratio_6"],
        "front_suspension_travel": f["front_suspension_travel"],
        "front_suspension_rest": f["front_suspension_rest"],
        "rear_suspension_travel": f["rear_suspension_travel"],
        "rear_suspension_rest": f["rear_suspension_rest"],
        "front_tire_stiffness": f["front_tire_stiffness"],
        "front_tire_grip": f["front_tire_grip"],
        "front_brake_bias": f["front_brake_bias"],
        "front_lateral_grip": f["front_lateral_grip"],
        "front_longitudinal_grip": f["front_longitudinal_grip"],
        "rear_tire_stiffness": f["rear_tire_stiffness"],
        "rear_tire_grip": f["rear_tire_grip"],
        "rear_brake_bias": f["rear_brake_bias"],
        "rear_lateral_grip": f["rear_lateral_grip"],
        "rear_longitudinal_grip": f["rear_longitudinal_grip"],
        "steering_response": f["steering_response"],
        "steering_return": f["steering_return"],
        "steering_lock_scale": f["steering_lock_scale"],
        "rolling_resistance": f["rolling_resistance"],
        "aero_drag": f["aero_drag"],
        "body_center_x": f["body_center_x"],
        "body_center_y": f["body_center_y"],
        "body_center_z": f["body_center_z"],
        "body_length": f["body_length"],
        "body_width": f["body_width"],
        "body_height": f["body_height"],
        "aero_reference": f["aero_reference"],
        "wheelbase": dims["wheelbase"],
        "front_track": dims["front_track"],
        "rear_track": dims["rear_track"],
        "fl_x": w["FL"]["position_ps2"]["x"],
        "fl_y": w["FL"]["position_ps2"]["y"],
        "fl_z": w["FL"]["position_ps2"]["z"],
        "fl_radius": w["FL"]["wheel_radius"],
        "fr_x": w["FR"]["position_ps2"]["x"],
        "fr_y": w["FR"]["position_ps2"]["y"],
        "fr_z": w["FR"]["position_ps2"]["z"],
        "fr_radius": w["FR"]["wheel_radius"],
        "rl_x": w["RL"]["position_ps2"]["x"],
        "rl_y": w["RL"]["position_ps2"]["y"],
        "rl_z": w["RL"]["position_ps2"]["z"],
        "rl_radius": w["RL"]["wheel_radius"],
        "rr_x": w["RR"]["position_ps2"]["x"],
        "rr_y": w["RR"]["position_ps2"]["y"],
        "rr_z": w["RR"]["position_ps2"]["z"],
        "rr_radius": w["RR"]["wheel_radius"],
    }


def write_json(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=False) + "\n")


def write_csv(path: Path, rows: list[dict]) -> None:
    if not rows:
        return
    with path.open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


def write_readme(path: Path, payload: dict) -> None:
    stats = payload["stats"]
    duplicate_names = ", ".join(payload["duplicate_row_names"])
    missing_asset_names = ", ".join(payload["rows_without_asset_dirs"]) or "none"
    readme = f"""# HP2 PS2 Handling Reverse Notes

This directory was generated from the original PS2 binaries:

- handling table: `{payload["inputs"]["globalb_path"]}`
- car asset folders: `{payload["inputs"]["cars_path"]}`

## What is actually defining handling

Ghidra-verified code paths show that car handling is **not** defined inside `CARS/*/GEOMETRY.BIN`.

- `HP2_PhysicsCar_Construct_FUN_00137100 @ 0x00137100` constructs the runtime from a row in `GLOBALB.BUN` chunk `0x00034600`.
- `HP2_Engine_InitFromGlobalB_FUN_0018a7e8 @ 0x0018a7e8` consumes the engine payload from `row + 0x2B0`.
- `HP2_DriveTrain_InitFromGlobalB_FUN_0018ae70 @ 0x0018ae70` consumes the drivetrain payload from `row + 0x270`.
- `HP2_DriveTrain_BuildShiftTables_FUN_0018ac38 @ 0x0018ac38` confirms `row + 0x288` is the forward gear count and `row + 0x290..0x2AC` is the reverse/neutral/forward gear-ratio cluster.
- `HP2_CarRenderPhysicsAttachmentSetup_FUN_0011e860 @ 0x0011e860` reads `row + 0x20` for the car name, `row + 0x120/0x140/0x160/0x180` for the four wheel vectors, and `row + 0x538` for a vehicle variant selector.
- `CARS/*/GEOMETRY.BIN` still matters, but only for render/runtime-attachment metadata such as wheel/tire/brake locator setup.

## Counts

- Asset folders under `CARS`: **{stats["car_dir_count"]}**
- Fixed handling rows in `GLOBALB`: **{stats["row_count"]}**
- Unique handling row names: **{stats["unique_row_name_count"]}**
- Duplicate-name handling groups: **{stats["duplicate_name_count"]}**
- Handling rows with no matching asset folder: **{stats["rows_without_asset_dir_count"]}** (`{missing_asset_names}`)

## Parameter types

There are two useful ways to count the recovered row parameters:

1. **By category**: 9 groups
   - identity
   - vehicle variant / type
   - 4 wheel position+radius records
   - body-center / body-size fields
   - suspension fields
   - tire and brake/grip fields
   - steering fields
   - drivetrain / gearing fields
   - curve coefficient blocks
2. **By raw field slots per row**: **72 total**
   - 1 string name
   - 1 verified vehicle-type integer
   - 16 verified wheel floats (`4 wheels x (x, y, z, radius)`)
   - 39 inferred scalar fields (`38` floats + `1` integer gear count)
   - 15 inferred curve floats (`9` front-like + `6` rear-like)

## Duplicate handling rows

Some names appear twice in `GLOBALB`. Those duplicates are separate rows with separate values and should not be collapsed blindly:

`{duplicate_names}`

## Output files

- `hp2_globalb_handling_rows.json`: full extracted row dump with offsets and values
- `hp2_globalb_handling_summary.csv`: flattened comparison sheet, one line per handling row
- `hp2_asset_to_row_map.csv`: car-folder to matching handling-row indices

## Caveats

- Only the offsets listed above are Ghidra-verified as exact semantics.
- The extra scalar names in the JSON/CSV are still **inferred labels** based on stable float clusters and constructor usage.
- The `front_curve_*` and `rear_curve_*` blocks are contiguous coefficient groups near the engine/drivetrain payloads; their exact runtime meaning is still not fully proven.
"""
    path.write_text(readme)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--globalb", required=True, type=Path)
    parser.add_argument("--cars", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()

    data = args.globalb.read_bytes()
    chunk = find_chunk(data, CHUNK_GLOBAL_CAR_TABLE)
    table_base = align(chunk["data_offset"], 0x10)
    row_count = min(MAX_ROWS, (chunk["end_offset"] - table_base) // ROW_STRIDE)
    asset_dirs = {path.name.upper() for path in args.cars.iterdir() if path.is_dir()}

    rows = [read_row(data, row_index, table_base + row_index * ROW_STRIDE, asset_dirs) for row_index in range(row_count)]
    name_counter = Counter(row["car_name"] for row in rows)
    name_seen: defaultdict[str, int] = defaultdict(int)
    summary_rows: list[dict] = []
    asset_map_rows: list[dict] = []

    by_name: defaultdict[str, list[int]] = defaultdict(list)
    for row in rows:
        by_name[row["car_name"]].append(row["row_index"])

    for row in rows:
        name_seen[row["car_name"]] += 1
        summary_rows.append(summary_row(row, name_seen[row["car_name"]], name_counter[row["car_name"]]))

    for car_name in sorted(asset_dirs):
        row_indices = by_name.get(car_name, [])
        asset_map_rows.append(
            {
                "car_name": car_name,
                "asset_dir_exists": True,
                "matching_row_count": len(row_indices),
                "matching_row_indices": ",".join(str(index) for index in row_indices),
            }
        )

    payload = {
        "inputs": {
            "globalb_path": str(args.globalb),
            "cars_path": str(args.cars),
        },
        "ghidra_verified_layout": {
            "functions": [
                {"name": "HP2_CarRenderPhysicsAttachmentSetup_FUN_0011e860", "address": "0x0011e860"},
                {"name": "HP2_PhysicsCar_Construct_FUN_00137100", "address": "0x00137100"},
                {"name": "HP2_Engine_InitFromGlobalB_FUN_0018a7e8", "address": "0x0018a7e8"},
                {"name": "HP2_DriveTrain_InitFromGlobalB_FUN_0018ae70", "address": "0x0018ae70"},
                {"name": "HP2_DriveTrain_BuildShiftTables_FUN_0018ac38", "address": "0x0018ac38"},
                {"name": "HP2_BuildAccelerationOrShiftCurve_FUN_00188df0", "address": "0x00188df0"},
            ],
            "verified_offsets": {
                "name": "row + 0x020",
                "wheel_vectors": ["row + 0x120", "row + 0x140", "row + 0x160", "row + 0x180"],
                "drivetrain_base": "row + 0x270",
                "gear_count": "row + 0x288",
                "gear_ratios": "row + 0x290 .. row + 0x2AC",
                "engine_base": "row + 0x2B0",
                "vehicle_type": "row + 0x538",
            },
        },
        "stats": {
            "car_dir_count": len(asset_dirs),
            "row_count": row_count,
            "unique_row_name_count": len(name_counter),
            "duplicate_name_count": sum(1 for count in name_counter.values() if count > 1),
            "rows_without_asset_dir_count": sum(1 for name in name_counter if name not in asset_dirs),
        },
        "duplicate_row_names": sorted([name for name, count in name_counter.items() if count > 1]),
        "rows_without_asset_dirs": sorted([name for name in name_counter if name not in asset_dirs]),
        "rows": rows,
    }

    args.out.mkdir(parents=True, exist_ok=True)
    write_json(args.out / "hp2_globalb_handling_rows.json", payload)
    write_csv(args.out / "hp2_globalb_handling_summary.csv", summary_rows)
    write_csv(args.out / "hp2_asset_to_row_map.csv", asset_map_rows)
    write_readme(args.out / "README.md", payload)


if __name__ == "__main__":
    main()
