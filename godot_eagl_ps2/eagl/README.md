# EAGL

Engine Asset Gateway Layer for loading original game assets into Godot.

Current platform:

- `EAGL_HOTPUSUIT2_PS2`
- Alias: `EAGL_HOTPURSUIT2_PS2`
- Initial target: Need for Speed: Hot Pursuit 2 PS2 track bundles under `ZZDATA/TRACKS`

## Usage

`EAGLManager` is registered as a Godot autoload in `project.godot`.

```gdscript
EAGLManager.initialize("EAGL_HOTPUSUIT2_PS2", "/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA")
var track := EAGLManager.load_track("61")
add_child(track)
```

The PS2 resolver accepts either:

- the extracted `GameFile` directory
- the `GameFile/ZZDATA` directory
- the `GameFile/ZZDATA/TRACKS` directory

Track IDs may be passed as `61`, `B61`, `TRACKB61`, or `TRACKA61`.

## Current Track Path

`load_track()` follows this pipeline:

1. Resolve `TRACKB##.BUN` or `TRACKB##.LZC`
2. Decompress `COMP`/`.LZC` bundles
3. Parse bChunk containers
4. Decode `0x80034002` mesh objects
5. Decode `0x00034004` strip-entry metadata and `0x00034005` VIF packets
6. Apply HP2 PS2 VIF strip-control masking
7. Convert PS2 coordinates to Godot coordinates
8. Decode `TEX##TRACK.BIN` and `TEX##LOCATION.BIN` PS2 indexed texture banks
9. Parse solid packs and `0x80034100` scenery placement sections
10. Build Godot `ArrayMesh` surfaces with VIF vertex colors and texture materials
11. Create the generated track hierarchy:

```text
TrackRoot
├── MeshLibrary
├── StaticGeometry
│   ├── Roads
│   ├── Terrain
│   ├── Shadows
│   ├── SectionDetails
│   └── Landmarks
├── Scenery
│   ├── Buildings
│   ├── Signs
│   ├── Trees
│   ├── WallsRails
│   └── Props
├── Environment
│   ├── SKYDOME
│   ├── SKYDOME_ENVMAP
│   └── WATER
├── TrackMarkers
│   └── startline objects
└── UnknownChunks
```

Texture materials are selected through the solid object's `0x00034006` texture hash table and each block's strip-entry texture index. Surfaces with unresolved hashes fall back to deterministic debug colors.

## Debug Scene

Open or run:

```text
res://eagl/debug/track_render_debug.tscn
```

Defaults:

- platform: `EAGL_HOTPUSUIT2_PS2`
- game root: `/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA`
- track: `61`
- shared scenery placement: on
- baked scenery expansion: off

Scenery placement records are parsed from `0x00034103` and resolved through the `0x00034102` hash table. EAGL keeps placement mechanism separate from semantic category:

- `eagl_placement_kind`: `DIRECT_SOLID` or `SCENERY_INSTANCE`
- `bun_category`: `ENVIRONMENT`, `TRACK_MARKER`, `PROP`, `ROAD`, `TERRAIN`, `SHADOW`, `LANDMARK`, or `STATIC_DETAIL`
- `eagl_source_role`: `TEMPLATE_PALETTE`, `STATIC_SOLID_PACK`, or `SPECIAL_SOLID_PACK`

This lets special instanced objects like `SKYDOME_ENVMAP`, `WATER`, and start-line meshes use their `0x34103` transforms while still living under `Environment` or `TrackMarkers`. Normal repeated props are grouped into `MultiMeshInstance3D` nodes by category and mesh hash under semantic buckets such as `Trees`, `Signs`, and `WallsRails`. Toggle `expand_scenery_instances` only when you specifically need fully baked per-instance geometry; it is much heavier.
