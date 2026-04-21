# HP2 PS2 Handling Reverse Notes

This directory was generated from the original PS2 binaries:

- handling table: `/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA/GLOBAL/GLOBALB.BUN`
- car asset folders: `/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA/CARS`

## What is actually defining handling

Ghidra-verified code paths show that car handling is **not** defined inside `CARS/*/GEOMETRY.BIN`.

- `HP2_PhysicsCar_Construct_FUN_00137100 @ 0x00137100` constructs the runtime from a row in `GLOBALB.BUN` chunk `0x00034600`.
- `HP2_Engine_InitFromGlobalB_FUN_0018a7e8 @ 0x0018a7e8` consumes the engine payload from `row + 0x2B0`.
- `HP2_DriveTrain_InitFromGlobalB_FUN_0018ae70 @ 0x0018ae70` consumes the drivetrain payload from `row + 0x270`.
- `HP2_DriveTrain_BuildShiftTables_FUN_0018ac38 @ 0x0018ac38` confirms `row + 0x288` is the forward gear count and `row + 0x290..0x2AC` is the reverse/neutral/forward gear-ratio cluster.
- `HP2_CarRenderPhysicsAttachmentSetup_FUN_0011e860 @ 0x0011e860` reads `row + 0x20` for the car name, `row + 0x120/0x140/0x160/0x180` for the four wheel vectors, and `row + 0x538` for a vehicle variant selector.
- `CARS/*/GEOMETRY.BIN` still matters, but only for render/runtime-attachment metadata such as wheel/tire/brake locator setup.

## Counts

- Asset folders under `CARS`: **43**
- Fixed handling rows in `GLOBALB`: **64**
- Unique handling row names: **44**
- Duplicate-name handling groups: **20**
- Handling rows with no matching asset folder: **1** (`DIABLO`)

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

`911TURBO, BARCHETTA, CARRERAGT, CL55AMG, CLK_GTR, CORVETTE, DIABLO, ELISE, F50, HOLDEN, JAGUAR, MCLAREN, MCLARENLM, MURCIELAGO, MUSTANG, OPEL, TS50, VANQUISH, VAUXHALL, VIPERGTS`

## Output files

- `hp2_globalb_handling_rows.json`: full extracted row dump with offsets and values
- `hp2_globalb_handling_summary.csv`: flattened comparison sheet, one line per handling row
- `hp2_asset_to_row_map.csv`: car-folder to matching handling-row indices

## Caveats

- Only the offsets listed above are Ghidra-verified as exact semantics.
- The extra scalar names in the JSON/CSV are still **inferred labels** based on stable float clusters and constructor usage.
- The `front_curve_*` and `rear_curve_*` blocks are contiguous coefficient groups near the engine/drivetrain payloads; their exact runtime meaning is still not fully proven.
