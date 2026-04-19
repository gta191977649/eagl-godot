# Godot BUN Loader Design

This document describes a practical Godot loader architecture for Need for Speed: Hot Pursuit 2 PS2 `TRACKB##.BUN` and decompressed `TRACKB##.LZC` track bundles.

The main rule is to separate reusable mesh definitions from visible placed instances. Do not create visible Godot nodes for every `0x80034002` mesh object directly. Some mesh objects are source/template props that should only be referenced by scenery placement records.

## Recommended Node Hierarchy

Use this shape for the generated Godot scene:

```text
Node3D TrackRoot
├── Node MeshLibrary
├── Node3D StaticGeometry
│   ├── Node3D SolidPack_01
│   ├── Node3D SolidPack_02
│   └── ...
├── Node3D Scenery
│   ├── MultiMeshInstance3D XS_CHEVRCNRA_1_00
│   ├── MultiMeshInstance3D XS_LIGHTPOSTA_1_00
│   ├── MultiMeshInstance3D XW_1GUARDRAILGRASS_1_8P
│   └── ...
├── Node3D Collision
├── Node3D DebugMarkers
└── Node UnknownChunks
```

`MeshLibrary` can be a non-visible resource cache. It should hold one shared `ArrayMesh` per decoded source mesh.

`StaticGeometry` is for track pieces that are visible directly from their own solid-pack transforms.

`Scenery` is for `0x00034103` placed props. For performance, group repeated props by mesh hash and create one `MultiMeshInstance3D` per mesh hash/material set.

## Binary Hierarchy

The useful track hierarchy is:

```text
TRACKB##.BUN or decompressed TRACKB##.LZC
├── solid mesh packs
│   └── 0x80034000
│       ├── 0x00034001 solid pack header
│       └── 0x80034002 mesh object
│           ├── 0x00034003 object header: name, name hash, template transform
│           ├── 0x00034004 strip-entry table
│           ├── 0x00034005 VIF vertex packet data
│           └── 0x00034006 texture hash references
│
└── scenery placement sections
    └── 0x80034100
        ├── 0x00034101 scenery section header
        ├── 0x00034102 scenery info table: mesh name hashes
        ├── 0x00034103 scenery instance transforms
        └── 0x00034104 extra/unknown section data
```

Confirmed object placement records are `0x00034103` records under `0x80034100`.

## Data Model

Keep parsing separate from Godot node creation.

Suggested pure parser classes:

```gdscript
class_name BunTrack
var mesh_defs_by_hash: Dictionary        # int -> BunMeshDef
var mesh_defs_by_name: Dictionary        # String -> BunMeshDef
var solid_packs: Array[BunSolidPack]
var scenery_sections: Array[BunScenerySection]
var materials: Dictionary
var unknown_chunks: Array
```

```gdscript
class_name BunSolidPack
var source_chunk_offset: int
var mesh_defs: Array[BunMeshDef]
var is_scenery_template_palette: bool
```

```gdscript
class_name BunMeshDef
var name: String
var name_hash: int
var source_chunk_offset: int
var mesh: ArrayMesh
var texture_hashes: Array[int]
var template_transform: Transform3D
var is_scenery_template: bool
```

```gdscript
class_name BunScenerySection
var section_number: int
var source_chunk_offset: int
var info_table: Array[BunSceneryInfo]
var instances: Array[BunSceneryInstance]
```

```gdscript
class_name BunSceneryInfo
var lod_hashes: Array[int]  # highest LOD first
```

```gdscript
class_name BunSceneryInstance
var scenery_info_index: int
var mesh_hash: int
var mesh_def: BunMeshDef
var transform: Transform3D
var source_chunk_offset: int
var record_index: int
```

## Loader Pipeline

Implement the loader in two stages:

```text
BunParser
  Reads/decompresses BUN/LZC.
  Parses bChunk tree.
  Decodes mesh definitions, scenery sections, and placement records.
  Produces BunTrack data only.

BunSceneBuilder
  Converts BunTrack data into Godot resources and nodes.
  Creates ArrayMesh resources, materials, MultiMeshInstance3D nodes, and debug nodes.
```

Recommended pipeline:

```text
1. Read .BUN or decompress .LZC/COMP.
2. Parse the bChunk tree.
3. Parse every 0x80034002 mesh definition.
4. Build name_hash -> BunMeshDef from 0x00034003 + 0x08.
5. Decode geometry from 0x00034004 and 0x00034005.
6. Decode texture references from 0x00034006.
7. Load matching TEX##TRACK.BIN and TEX##LOCATION.BIN if textures are available.
8. Parse every 0x80034100 scenery section.
9. Resolve every 0x00034103 placement through the section's 0x00034102 hash table.
10. Build Godot nodes:
    - static section geometry
    - scenery MultiMeshes
    - optional collision/debug/unknown chunk nodes
```

## Mesh Definitions

Each `0x80034002` is a source mesh definition:

```text
0x80034002 mesh object
├── 0x00034003 object header
├── 0x00034004 strip-entry table
├── 0x00034005 VIF packet data
└── 0x00034006 texture hashes
```

Important `0x00034003` fields for HP2 PS2:

```text
0x08  u32        name hash
0x10  char[]     ASCII mesh name
0x60  f32[16]    template/local transform matrix
```

The first `0x80034000` solid pack in the tested tracks acts as the scenery/template palette. It contains source prop meshes such as signs, buildings, lights, trees, and other repeated scenery. Do not instantiate that first palette as visible geometry when using scenery placements.

## Object Categorization

The BUN does not appear to carry a simple explicit category enum such as `SKYBOX`, `PROP`, `ROAD`, or `TERRAIN`.
Categories should be inferred from:

```text
1. Parent chunk / solid pack position.
2. Whether the object is referenced by 0x34103 scenery placements.
3. Object name prefixes.
4. Special object names such as SKYDOME, WATER, and STARTLINE.
```

Use categorization for scene organization, debugging, and Godot node parenting.
Do not use name-only categorization to decide scenery placement; use the `0x34103 -> 0x34102 -> mesh hash` chain for actual placed props.

Recommended enum:

```gdscript
enum BunObjectCategory {
    MESH_DEFINITION,
    SCENERY_TEMPLATE,
    SCENERY_INSTANCE,
    ROAD,
    TERRAIN,
    SHADOW,
    STATIC_DETAIL,
    ENVIRONMENT,
    TRACK_MARKER,
    LANDMARK,
    UNKNOWN
}
```

### Scenery Template Props

The first `0x80034000` solid pack is the main prop/source mesh palette.
For `TRACKB64`, this first pack contains 489 objects with prefixes like:

```text
XT  vegetation/tree/canopy props
XW  walls, rails, barriers, guardrails
XS  signs, billboards, arrows, light posts
XB  buildings
XH  Hawaiian/village/tiki props
XF  flags
```

Examples:

```text
XB_OFFICEA_A1_00
XB_OFFICEBT_A1_00
XF_FLAG_1_00
XH_TIKICURVEDTOP_1_00
XS_BIGDONOTENTER_1_00
XS_LIGHTPOSTA_1_00
XT_PALMCOCONUT_SS1A_00
XW_1GUARDRAILGRASS_1_8P
```

Treat these as:

```text
category: SCENERY_TEMPLATE
visible directly: false when using scenery placements
used by: 0x80034100 / 0x00034103 scenery instance records
```

These meshes should live in `MeshLibrary` and be referenced by `Scenery` MultiMeshes.

### Placed Props

Placed visible props come from `0x00034103` records under `0x80034100`.
They are resolved through the section's `0x00034102` hash table.

Treat these as:

```text
category: SCENERY_INSTANCE
visible directly: yes
source mesh: hash-resolved BunMeshDef
Godot node: MultiMeshInstance3D preferred
```

Common `TRACKB64` placed prop groups include:

```text
XW_1GUARDRAILGRASS_1_8P
XW_1CITYRAILTWOBARS_1_8
XT_TREELINEPALMSSOLID_L
XW_1GUARDRAILOLDGRASS_2
XT_TREELINEPALMS_L1A_00
XS_CHEVRCNRA_1_00
XS_LIGHTPOSTA_1_00
XT_PALMCOCONUT_SS1A_00
```

### Static Track Geometry

Solid packs after the first scenery/template palette usually contain visible track section geometry.

Common prefixes:

```text
RD_      road surface
DIRTRD_  dirt road
TRN_     terrain / track environment mesh
SHD_     shadow mesh
S10/S20  section-specific detail
XWU_     section-local wall/guardrail/detail
A_       area/detail prop baked into the section pack
```

Treat these as:

```text
category: ROAD / TERRAIN / SHADOW / STATIC_DETAIL
visible directly: yes
transform: 0x34003 template/local transform
Godot node: MeshInstance3D or merged section mesh
```

Suggested hierarchy:

```text
StaticGeometry
├── Roads
├── Terrain
├── Shadows
└── SectionDetails
```

### Section-Local Props

Some prop-like objects are not in the first template palette.
They appear inside later section packs mixed with road and terrain geometry.

Examples:

```text
A_BIGSIGNWIDE_4002
A_CRATEMETALWOODSMALL_4
TROPIC_...
STAD_...
LI_...
KT_...
XWU_...
```

Treat these as:

```text
category: STATIC_DETAIL
visible directly: yes
instancing path: usually not 0x34103
parent: StaticGeometry/SectionDetails
```

The important distinction is:

```text
First-pack XS/XW/XT/XB/XH/XF objects
  = source templates, not directly visible when scenery placements are used.

Later-pack XS/XW/XT/A/etc objects
  = section-local static detail, usually directly visible.
```

### Skybox, Water, And Environment

Skybox is not part of the `0x34103` scenery placement system.
In `TRACKB64`, the final solid pack contains:

```text
SKYDOME
SKYDOME_ENVMAP
TRACK61_STARTLINE_BACK
TRACK61_STARTLINE_FORW
WATER
```

`SKYDOME` and `SKYDOME_ENVMAP` are nearly overlapping giant dome meshes. `SKYDOME_ENVMAP` is referenced by a `0x34103` record, but it should not be treated as a normal visible prop.
Rendering both `SKYDOME` and `SKYDOME_ENVMAP` as transparent/double-sided scene meshes can cause z-fighting, flickering, and striped alpha artifacts.

Treat sky and water as:

```text
category: ENVIRONMENT
parent: Environment
transform: 0x34003 template/local transform
```

Suggested hierarchy:

```text
Environment
├── Sky          # generated from one selected sky source or a Godot sky shader
└── WATER
```

Recommended handling:

```text
SKYDOME
  Use as the visible sky source only if a mesh sky is needed.
  Prefer converting it to a Godot WorldEnvironment sky later.

SKYDOME_ENVMAP
  Treat as reflection/environment-map source data, not as a normal visible prop.
  Do not place it under Scenery just because it is referenced by 0x34103.
  Do not render it together with SKYDOME as overlapping transparent geometry.

WATER
  Treat as a special environment surface, not a generic alpha prop.
  Render single-sided unless there is proof both sides are needed.
  Prefer a dedicated water material/shader over generic transparent prop material.
```

The Python GLB exporter skips `SKYDOME` and `SKYDOME_ENVMAP` as normal geometry for this reason.

### Track Markers

Start-line meshes and similar special visual markers should not be treated as scenery props.

Examples:

```text
TRACK61_STARTLINE_BACK
TRACK61_STARTLINE_FORW
```

Treat these as:

```text
category: TRACK_MARKER
visible directly: yes
parent: TrackMarkers
```

Suggested hierarchy:

```text
TrackMarkers
├── TRACK61_STARTLINE_BACK
└── TRACK61_STARTLINE_FORW
```

### Landmarks And Large Unique Structures

Some large structures appear in separate solid packs or section packs:

```text
BRIDGEPILLARS_S222-EXPO
BRIDGEPILLARSB_2001
W_BRIDGEROPE_B_01
MARTINSPEAK
```

Treat these as:

```text
category: LANDMARK or STATIC_DETAIL
visible directly: yes
parent: StaticGeometry/Landmarks
```

Suggested hierarchy:

```text
StaticGeometry
└── Landmarks
    ├── BRIDGEPILLARS_S222-EXPO
    ├── MARTINSPEAK
    └── ...
```

### Practical Categorization Rules

Use rules in this order:

```gdscript
func categorize_mesh(mesh_def: BunMeshDef, solid_pack: BunSolidPack) -> BunObjectCategory:
    var name := mesh_def.name.to_upper()

    if solid_pack.is_scenery_template_palette:
        return BunObjectCategory.SCENERY_TEMPLATE

    if name.begins_with("SKYDOME") or name == "WATER" or name.contains("ENVMAP"):
        return BunObjectCategory.ENVIRONMENT

    if name.begins_with("TRACK") and name.contains("STARTLINE"):
        return BunObjectCategory.TRACK_MARKER

    if name.begins_with("RD_") or name.begins_with("DIRTRD_"):
        return BunObjectCategory.ROAD

    if name.begins_with("TRN_"):
        return BunObjectCategory.TERRAIN

    if name.begins_with("SHD_") or name.begins_with("SH_"):
        return BunObjectCategory.SHADOW

    if name.contains("BRIDGE") or name == "MARTINSPEAK":
        return BunObjectCategory.LANDMARK

    return BunObjectCategory.STATIC_DETAIL
```

Scenery placement instances should be categorized separately when they are created:

```gdscript
func categorize_instance(instance: BunSceneryInstance) -> BunObjectCategory:
    return BunObjectCategory.SCENERY_INSTANCE
```

For runtime performance, `Scenery` should primarily be grouped by mesh hash as `MultiMeshInstance3D`.
Semantic categories can be stored as metadata:

```gdscript
node.set_meta("bun_category", "SCENERY_INSTANCE")
node.set_meta("mesh_hash", mesh_hash)
node.set_meta("source_chunk_offset", source_chunk_offset)
```

## Static Geometry

Solid packs after the first scenery/template palette usually contain visible track section geometry:

```text
SolidPack_01 -> section 10 road/terrain/shadow meshes
SolidPack_02 -> section 20 road/terrain/shadow meshes
...
```

For these objects:

```gdscript
mesh_instance.mesh = mesh_def.mesh
mesh_instance.transform = mesh_def.template_transform
```

This is separate from scenery instances.

## Scenery Instances

Scenery placement hierarchy:

```text
0x80034100 scenery section
├── 0x00034101 section header
├── 0x00034102 info table
└── 0x00034103 instance table
```

HP2 `0x00034102` record layout:

```text
0x00  u32  highest LOD mesh name hash
0x04  u32  lower LOD mesh name hash, often 0
0x08  u32  lower LOD mesh name hash, often 0
0x0C  ...  remaining metadata not currently required for placement
record size: 0x28 bytes
```

HP2 `0x00034103` record layout:

```text
0x00  s16[3]  bounds min
0x06  s16[3]  bounds max
0x0C  s16     SceneryInfoNumber, index into this section's 0x00034102 table
0x0E  u16     exclude/visibility flags
0x10  f32     position x
0x14  f32     position y
0x18  f32     position z
0x1C  s16[9]  3x3 rotation/scale matrix, divide by 0x4000
0x2E  u16     padding/unknown
record size: 0x30 bytes
```

Resolution logic:

```gdscript
var info_index = instance_record.scenery_info_number
var info = scenery_section.info_table[info_index]
var mesh_hash = info.lod_hashes[0]
var mesh_def = track.mesh_defs_by_hash[mesh_hash]
```

Then place it:

```gdscript
instance.transform = instance_record.transform
```

Do not multiply the source mesh template transform into the instance transform:

```gdscript
# Wrong. This causes props/buildings to drift or fly.
instance.transform = mesh_def.template_transform * instance_record.transform

# Correct.
instance.transform = instance_record.transform
```

## MultiMesh Grouping

For runtime performance, avoid one `MeshInstance3D` node per prop when possible. `TRACKB64` has around 15k resolved scenery placements.

Group by mesh hash:

```gdscript
var groups := {}  # mesh_hash -> Array[Transform3D]

for section in track.scenery_sections:
    for instance in section.instances:
        groups.get_or_add(instance.mesh_hash, []).append(instance.transform)
```

Then create one `MultiMeshInstance3D` per group:

```gdscript
for mesh_hash in groups.keys():
    var mesh_def: BunMeshDef = track.mesh_defs_by_hash[mesh_hash]
    var transforms: Array = groups[mesh_hash]

    var multimesh := MultiMesh.new()
    multimesh.mesh = mesh_def.mesh
    multimesh.transform_format = MultiMesh.TRANSFORM_3D
    multimesh.instance_count = transforms.size()

    for i in range(transforms.size()):
        multimesh.set_instance_transform(i, transforms[i])

    var node := MultiMeshInstance3D.new()
    node.name = mesh_def.name
    node.multimesh = multimesh
    scenery_root.add_child(node)
```

If different materials need different surfaces, keep one `ArrayMesh` with surfaces intact. If one mesh hash needs multiple material variants, group by `(mesh_hash, material_key)`.

## LOD Strategy

`0x00034102` can contain up to three LOD hashes:

```text
lod_hashes[0] = highest LOD
lod_hashes[1] = lower LOD, often 0
lod_hashes[2] = lower LOD, often 0
```

Initial loader:

```gdscript
mesh_hash = info.lod_hashes[0]
```

Later LOD-aware loader:

```gdscript
func choose_lod_hash(info: BunSceneryInfo, lod: int) -> int:
    for i in range(lod, info.lod_hashes.size()):
        if info.lod_hashes[i] != 0:
            return info.lod_hashes[i]
    return info.lod_hashes[0]
```

Possible LOD hierarchy:

```text
Scenery
└── XS_TREE_A
    ├── LOD0 MultiMesh using hash[0]
    ├── LOD1 MultiMesh using hash[1]
    └── LOD2 MultiMesh using hash[2]
```

## Coordinate Conversion

The current Python GLB exporter uses this vertex basis conversion:

```text
target x = source x
target y = source z
target z = -source y
```

Godot is Y-up, so this mapping is a good starting point:

```gdscript
func ps2_to_godot_position(p: Vector3) -> Vector3:
    return Vector3(p.x, p.z, -p.y)
```

For transforms, convert the whole basis and origin. Do not only convert translation.

Conceptually:

```gdscript
func ps2_to_godot_transform(t: Transform3D) -> Transform3D:
    var x_axis = ps2_to_godot_vector(t.basis.x)
    var y_axis = ps2_to_godot_vector(t.basis.y)
    var z_axis = ps2_to_godot_vector(t.basis.z)
    var origin = ps2_to_godot_position(t.origin)
    return Transform3D(Basis(x_axis, y_axis, z_axis), origin)
```

Check handedness and winding after import. If faces appear inside-out, flip triangle winding or one basis axis consistently.

## Materials And Vertex Colors

For full TPK entry offsets, PS2 palette decode, legacy swizzle decode, and alpha/material classification rules, see [hp2_ps2_texture_decoding.md](/Users/nurupo/Desktop/dev/eagl-godot/map_tools_ps2/docs/hp2_ps2_texture_decoding.md).

The PS2 mesh packet can include packed `V4_5` vertex color data. The Python exporter decodes it as `R5G5B5A1` and writes GLB `COLOR_0`.

For Godot:

```text
Read packed values from the VIF color stream.
Decode R5G5B5A1 to Color.
Attach colors to ArrayMesh surface arrays as Mesh.ARRAY_COLOR.
Use materials that multiply texture by vertex color.
```

Recommended material behavior:

```text
albedo texture * vertex color
unshaded or low-light material mode for baked PS2 lighting
alpha mode from decoded texture alpha
double-sided for foliage/cards/sign props as needed
```

Do not classify alpha mode from PNG alpha alone. Use the PS2 TPK texture metadata too:

```text
TPK entry +0x4F is_any_semitransparency
TPK entry +0x76 alpha_bits
TPK entry +0x77 alpha_fix
```

Observed examples in `TRACKB64`:

```text
SKYDOMECAP_SUNSET_1       semitrans=1 alpha_bits=68  -> true BLEND
SKYDOMEREFLECTCAP_SUNSE   semitrans=1 alpha_bits=68  -> true BLEND, but envmap should not render as prop
WATER                     semitrans=1 alpha_bits=68  -> true BLEND, special water material
SHLD_G                    semitrans=0 alpha_bits=10  -> should be MASK, not BLEND
```

Some non-semitransparent textures decode with high alpha values such as `223`.
If `is_any_semitransparency == 0`, treat high nonzero alpha values as opaque for material mode selection.
For example, alpha values `{0, 223, 254}` should become alpha scissor/mask, not transparent blend.

Suggested material policy:

```text
if no alpha below near-opaque:
    material = opaque

elif is_any_semitransparency == 0 and all alpha values are 0 or >= 128:
    material = alpha scissor / MASK

elif is_any_semitransparency == 1:
    material = BLEND or a special material

if object is WATER:
    use special single-sided water material

if object is SKYDOME_ENVMAP:
    do not render as normal visible geometry
```

This avoids transparent sorting flicker on cutout textures that are not semitransparent in the PS2 material metadata.

## Unknown Chunks

Keep unknown chunks in a debug/preservation structure instead of discarding them:

```gdscript
class_name BunUnknownChunk
var chunk_id: int
var offset: int
var size: int
var parent_chunk_id: int
```

Repeated list-like chunks seen in `TRACKB64` but not confirmed as object placements:

```text
0x00034450  count 162  under 0x80034405
0x0003401d  count 54
0x00038010  count 10   under 0x80038000
0x00038020  count 11   under 0x80038000
0x00038030  count 20   under 0x80038000
0x00034021..0x00034025 count 14 each under 0x80034020
```

Do not label these as scenery instances until verified. The only confirmed prop placement table is `0x00034103`.

## Coverage Review

The hierarchy in this document covers the confirmed visible mesh systems:

```text
covered:
0x80034000 / 0x80034002 solid mesh definitions
0x00034003 mesh name, name hash, template transform
0x00034004 strip metadata
0x00034005 VIF geometry, UVs, packed colors
0x00034006 texture hash references
0x80034100 scenery sections
0x00034102 scenery info mesh-hash table
0x00034103 scenery placement transforms
```

For `TRACKB64`, this accounts for:

```text
mesh definitions:             1,345
scenery template meshes:        489
resolved scenery placements: 15,059
scenery section containers:     125
```

This means the current hierarchy covers the known visible prop/scenery instance system:

```text
MeshLibrary
StaticGeometry
Scenery
Environment
TrackMarkers
Landmarks
```

However, it does not yet fully decode every BUN subsystem. A complete game-ready loader should preserve and later investigate additional chunk families.

### Unmapped But Common Chunk Families

These chunk families appear across multiple tracks and should be represented as preserved data/debug groups until decoded:

```text
0x80034020
├── 0x00034021
├── 0x00034022
├── 0x00034023
├── 0x00034024
└── 0x00034025

0x80034405
├── 0x00034440
└── 0x00034450 repeated records

0x80038000
├── 0x00038010 repeated records
├── 0x00038020 repeated records
└── 0x00038030 repeated records

0x80036000
├── 0x00036001
├── 0x00036002
└── 0x00036003

0x80034147
├── 0x00034148
└── 0x00034149

0x80034800
├── 0x00034801
└── 0x00034802

0x80034500
├── 0x00034510
├── 0x00034520
└── 0x00034530
```

Large single leaf chunks also appear:

```text
0x00034121
0x00034122
0x00034130
0x00034131
0x00034132
0x00034133
0x00034106
0x00034200
0x00034202
```

These may include collision, culling/visibility data, route data, AI/traffic/navigation data, lighting data, region data, triggers, or other track systems.
Do not assume they are object placements without runtime or external evidence.

### Recommended Godot Nodes For Unmapped Systems

Include explicit placeholder nodes so the scene hierarchy is future-proof:

```text
TrackRoot
├── StaticGeometry
├── Scenery
├── Environment
├── TrackMarkers
├── Collision          # reserved for decoded collision chunks
├── Visibility         # reserved for culling/section-tree data
├── Routes             # reserved for racing line, AI, traffic, or navigation data
├── Lighting           # reserved for light/lightmap/environment data
├── Triggers           # reserved for gameplay regions/triggers
└── UnknownChunks      # raw preserved records keyed by chunk id and offset
```

Each unknown chunk should keep enough provenance for later decoding:

```gdscript
class_name BunUnknownChunk
var chunk_id: int
var offset: int
var size: int
var parent_chunk_id: int
var parent_offset: int
var payload: PackedByteArray
```

### Does The Current Hierarchy Cover All Instances?

For visible scenery props, yes: the currently confirmed instance mechanism is `0x00034103`, and the hierarchy covers it through `Scenery` / `MultiMeshInstance3D`.

For all possible game systems, no: route, collision, trigger, visibility, lighting, traffic, and gameplay data may have their own record lists. Those should not be called mesh instances yet, but they should be preserved under dedicated placeholder roots.

In short:

```text
current hierarchy covers:
  visible mesh definitions
  static solid-pack geometry
  sky/environment meshes
  start-line/special static meshes
  confirmed scenery prop instances

current hierarchy does not fully decode:
  collision
  visibility/culling
  AI/traffic/routes
  light/environment metadata
  gameplay triggers/regions
  unknown repeated chunk families
```

## Implementation Checklist

1. Implement COMP/LZC decompression or call an external decompressor first.
2. Implement bChunk parsing.
3. Parse `0x80034002` mesh objects into `BunMeshDef`.
4. Decode `0x00034003` name, name hash, and template transform.
5. Decode `0x00034004` strip metadata.
6. Decode `0x00034005` VIF vertices, UVs, and packed colors.
7. Decode `0x00034006` texture hash references.
8. Build hash lookup from `BunMeshDef.name_hash`.
9. Mark the first `0x80034000` solid pack as the scenery/template palette.
10. Parse `0x80034100` scenery sections.
11. Parse `0x00034102` info records.
12. Parse `0x00034103` placement records.
13. Resolve placements through `0x34103 -> 0x34102 -> mesh hash -> mesh def`.
14. Build static geometry from non-template solid packs.
15. Build scenery with `MultiMeshInstance3D` groups.
16. Add placeholder roots for `Collision`, `Visibility`, `Routes`, `Lighting`, and `Triggers`.
17. Keep unknown chunks available for debugging and future decoding.

## Common Bugs To Avoid

Do not treat `0x34103 + 0x0C` as a direct mesh object index. It is `SceneryInfoNumber`.

Do not instantiate the first `0x80034000` scenery/template palette directly when using scenery placements.

Do not multiply `mesh_def.template_transform * instance_record.transform` for scenery props.

Do not convert only positions when changing coordinate systems. Convert transform basis and origin together.

Do not create a unique `ArrayMesh` per scenery placement. Reuse mesh resources and prefer `MultiMeshInstance3D`.
