# NFS HP2 PS2 Track Mesh Reconstruction Notes

This document records the current understanding of Need for Speed: Hot Pursuit 2 PS2 track mesh binary structure and primitive reconstruction in this repo.

It is written for future agents working on `map_tools_ps2`, especially around terrain holes, broken small props, and mismatches between extracted GLB output and PCSX2 GS dumps.

## Scope

The notes apply to local HP2 PS2 track bundles such as:

```text
/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA/TRACKS/TRACKB61.LZC
```

The relevant implementation files are:

```text
src/map_tools_ps2/model.py
src/map_tools_ps2/vif.py
src/map_tools_ps2/strip_entries.py
src/map_tools_ps2/primitive_stream.py
src/map_tools_ps2/glb_writer.py
src/map_tools_ps2/gs_oracle.py
```

The current best primitive rule is source-backed VIF control, not geometry guessing.

## High-Level Container Structure

Track files may be plain `.BUN` or compressed `.LZC`/`COMP`.

At a high level, a track bundle is a bChunk tree. The exact top-level section mix can vary by track, but the mesh path used by this exporter is:

```text
TRACKB##.BUN or decompressed TRACKB##.LZC
└── bChunk tree
    ├── track/section/support chunks
    ├── texture and material-related chunks
    ├── scenery instance chunks
    │   └── 0x00034103  scenery instance records
    │       └── references primary mesh object indices
    └── solid mesh chunks
        ├── 0x80034000  primary solid/object list container
        │   └── 0x80034002  mesh object
        │       ├── 0x00034003  object header
        │       │   ├── ASCII object name
        │       │   └── local transform matrix
        │       ├── 0x00034004  strip-entry table
        │       │   ├── record 0, 0x40 bytes
        │       │   │   ├── texture index
        │       │   │   ├── VIF data offset
        │       │   │   ├── VIF qword count
        │       │   │   ├── render flags
        │       │   │   └── packed topology/count bytes
        │       │   ├── record 1, 0x40 bytes
        │       │   └── ...
        │       ├── 0x00034005  VIF strip data blob
        │       │   ├── block 0 packet, selected by strip-entry record 0
        │       │   ├── block 1 packet, selected by strip-entry record 1
        │       │   └── ...
        │       └── 0x00034006  texture hash references
        └── additional 0x80034002 mesh objects
            └── same child layout
```

The important relationship is:

```text
mesh object
  0x00034004 record N
    -> gives VIF byte offset and qword size
    -> selects one packet inside 0x00034005
    -> produces one DecodedBlock / GLB primitive group
```

The normal decode path is:

```text
load_bundle_bytes()
  -> decompress if needed
parse_chunks()
  -> bChunk tree
parse_scene()
  -> MeshObject list + scenery instances
write_glb()
  -> reconstructed GLB
```

Important chunks observed for solid mesh objects:

```text
0x80034002  mesh object container
0x00034003  mesh object header/name/transform
0x00034004  strip-entry table / per-block metadata
0x00034005  VIF strip data blob
0x00034006  texture hash references
```

The object name comes from `0x00034003`. GLB node suffixes like `_0713` are exporter object indices, not part of the source name. For example:

```text
TRN_SECTION30_CHOP3_0713
  source object name: TRN_SECTION30_CHOP3
  scene object index: 713
```

## Strip-Entry Records

Each `0x00034004` record is `0x40` bytes. Runtime evidence and bundle inspection agree this is a strip-entry table.

The current parser is `parse_strip_entry_record()` in `strip_entries.py`.

Known fields:

```text
offset  size  current field name
0x00    u32   texture_index_raw
0x08    u32   vif_offset
0x0C    u32   qword/render word
              low 16 bits  = qword_count
              high 16 bits = render_flags
0x1C    u32   packed strip word
              bits  0..7   = topology_code / material-like low byte
              bits  8..15  = vertex_count_byte
              bits 16..23  = count_byte / expected_face_count
              bits 24..31  = packed_ff_or_zero
```

The VIF data range for a block is:

```text
vif_payload[vif_offset : vif_offset + qword_count * 16]
```

The `count_byte` often equals the runtime-emitted face count after the VIF control mask is applied. It is useful evidence, but it is not by itself a primitive assembly rule.

Do not use `count_byte` alone to invent strip cuts or force quads. Earlier exporter bugs came from doing that.

## VIF Packet Layout Per Block

Most track mesh blocks decode to one VIF vertex run.

A typical HP2 PS2 block packet looks like:

```text
UNPACK 0x8000 / V4_8    count=1   -> header
UNPACK 0xC001 / V4_32   count=1   -> strip/triangle cull control
UNPACK 0xC002..         count=N   -> position rows
UNPACK 0xC020..         count=N   -> UV rows
UNPACK 0xC034..         count=N   -> packed values, usually color/control
FLUSH 0x14
padding
```

In the current parser:

```text
VifVertexRun.header        = 4 bytes from UNPACK imm=0x8000, command=0x6E
VifVertexRun.tri_cull      = 4 x u32 from UNPACK imm=0xC001, command=0x6C
VifVertexRun.vertices      = decoded from UNPACK imm=0xC002..0xC01F
VifVertexRun.texcoords     = decoded from UNPACK imm=0xC020..0xC033
VifVertexRun.packed_values = decoded from UNPACK imm=0xC034..0xC03F, command=0x6F
```

The VIF parser must preserve command events when debugging. `parse_vif_command_events()` records:

```text
offset
imm
count
command
payload_offset
payload
raw
decoded
```

UNPACK details:

```text
command 0x60..0x7F are UNPACK variants
command & 0xEF gives the base unpack command for masked 0x70..0x7F forms
imm & 0x03FF is the VU destination
imm & 0x4000 is unsigned/zero extend
imm & 0x8000 adds TOPS
```

The local PS2 VIF reference is:

```text
docs/ps2_arch.txt
```

if present in the workspace.

## The VIF Control Mask

The second VIF section, currently named `tri_cull`, is the missing control data that fixes many broken reconstructions.

This is not an official Sony name. It comes from the related extractor:

```text
/Users/nurupo/Desktop/dev/modelulator.v5.1.5.pub/src/util/xSolid/PSX2.lua
```

That tool uses `tri_cull` plus the header mode byte to build a triangle skip mask before assembling strip triangles.

A more neutral name would be:

```text
strip_disable_control
strip_adc_control
```

Current code keeps the name `tri_cull` to match the external reference.

### Header Fields Used

For HP2-era standard track blocks:

```text
header[0] = NumVerts
header[1] = Mode
```

Example:

```text
header = (28, 6, 84, 252)
NumVerts = 28
Mode = 6
```

The other header bytes are preserved but not fully named yet.

### Control Words

Example from `TRACKB61 / TRN_SECTION30_CHOP3`:

```text
tri_cull = (
  0x00286666,
  0x00000000,
  0x00000000,
  0x00433330,
)
```

Using the Modelulator-derived bit math, this produces:

```text
mask = 0xCCCCCCC0
```

Over 28 incoming strip vertices, disabled incoming vertices are:

```text
0, 1, 4, 5, 8, 9, 12, 13, 16, 17, 20, 21, 24, 25
```

The result is 14 emitted triangles, not the 26 triangles a raw 28-vertex strip would generate.

## Primitive Assembly Rule

The current source-backed rule is:

```text
1. Decode VIF header and tri_cull.
2. Compute the per-vertex ADC/disabled mask.
3. Treat the block as a GS triangle strip.
4. For each possible strip triangle, skip it if the incoming third vertex is disabled.
5. Use GS strip winding:
   even strip index -> (i, i+1, i+2)
   odd strip index  -> (i, i+2, i+1)
```

In code:

```text
primitive_stream_for_block()
  -> adc_disabled_from_vif_control()
  -> assemble_primitive_stream_triangles()
```

GS primitive constants used by `primitive_stream.py`:

```text
GS_PRIM_TRIANGLE       = 3
GS_PRIM_TRIANGLE_STRIP = 4
GS_PRIM_TRIANGLE_FAN   = 5
```

For HP2 track blocks, `_infer_block_primitive_mode()` currently returns `"strip"` because the runtime queues the original VIF packet and the VIF control mask decides which strip triangles draw.

## Why This Fixes Broken Terrain And Props

The old exporter often did:

```text
decoded vertices -> assume one continuous strip -> geometry heuristics
```

That creates bridge triangles across places where the runtime disables strip emission.

For `TRN_SECTION30_CHOP3_0713`, the source object is `TRN_SECTION30_CHOP3`, object index `713`. Blocks around `49..58` looked quad-like but were not proof of a quad primitive. The VIF control data proves they are triangle strips with disabled incoming vertices.

Example after applying VIF control:

```text
block 50: verts=28 expected=14 emitted=14 proof=vif_control
block 51: verts=20 expected=10 emitted=10 proof=vif_control
block 52: verts=28 expected=14 emitted=14 proof=vif_control
block 55: verts=28 expected=14 emitted=14 proof=vif_control
block 57: verts=28 expected=14 emitted=14 proof=vif_control
```

This often looks like 4-vertex quad batches:

```text
vertices 0..3   -> 2 triangles
vertices 4..7   -> 2 triangles
vertices 8..11  -> 2 triangles
...
```

But that is only one pattern produced by the mask. Do not implement this as a general quad heuristic.

The correct model is:

```text
VIF header + VIF tri_cull -> ADC/disabled mask -> GS triangle strip assembly
```

## Relationship To Older Topology Heuristics

Earlier work had a special rule for topology `0x05` blocks where:

```text
expected_face_count * 2 == vertex_count
```

This fixed lightpost-like blocks by disabling vertices:

```text
0, 1, 4, 5, 8, 9, 12, 13, ...
```

That worked because it accidentally matched a real VIF control pattern.

Now the same result comes from `tri_cull`, so object-name or topology-specific fixes should be treated as fallback diagnostics only.

Do not promote a geometry or metadata rule if `source_proof="vif_control"` is available.

## GS Dump Oracle

Use `oracle-gsdump` to compare decoded source blocks with PCSX2 GS draw batches when a dump contains unique enough matches.

Example:

```bash
PYTHONPATH=src python3 -m map_tools_ps2 oracle-gsdump \
  "/Users/nurupo/Library/Application Support/PCSX2/snaps/Need for Speed - Hot Pursuit 2_SLUS-20362_20260412010044.gs.zst" \
  --game-dir /Users/nurupo/Desktop/ps2/hp2_ps2/GameFile \
  --track 61 \
  --object XS_LIGHTPOST \
  --limit 40
```

Known exact matches after VIF control:

```text
XS_LIGHTPOSTA_1_00      block 6 / 20 vertices / 10 triangles
XS_LIGHTPOSTDBLB_1_00   block 9 / 20 vertices / 10 triangles
XS_LIGHTPOSTDOUBLE_1_00 block 9 / 20 vertices / 10 triangles
```

For `TRN_SECTION30_CHOP3`, the current TRACKB61 GS dump uniquely matches only small blocks from that object, and those are exact. The large visible chunks still need a more targeted GS dump if exact GS proof is required.

## Validation Commands

Run unit tests:

```bash
PYTHONPATH=src python3 -m unittest discover -s tests
```

Compile check:

```bash
PYTHONPATH=src python3 -m compileall -q src tests
```

Export a TRACKB61 GLB sample:

```bash
PYTHONPATH=src python3 -m map_tools_ps2 export \
  --game-dir /Users/nurupo/Desktop/ps2/hp2_ps2/GameFile \
  --track 61 \
  -o out/TRACKB61.vif_control_patch.glb
```

Corpus smoke over local LZC tracks:

```bash
PYTHONPATH=src python3 - <<'PY'
from pathlib import Path
from collections import Counter
from map_tools_ps2.comp import load_bundle_bytes
from map_tools_ps2.chunks import parse_chunks
from map_tools_ps2.model import parse_scene, transformed_block_vertices
from map_tools_ps2.glb_writer import _indices_for_block
from map_tools_ps2.primitive_stream import primitive_stream_for_block

root = Path("/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA/TRACKS")
proofs = Counter()
for path in sorted(root.glob("TRACKB*.LZC")):
    data = load_bundle_bytes(path)
    scene = parse_scene(parse_chunks(data), data)
    for obj in scene.objects:
        for block in obj.blocks:
            vertices = transformed_block_vertices(obj, block)
            stream = primitive_stream_for_block(vertices, block)
            _indices_for_block(vertices, obj.name, block)
            proofs[stream.source_proof] += 1
print(dict(proofs))
PY
```

At the time this doc was written, all local `TRACKB*.LZC` blocks assembled with:

```text
source_proof = vif_control
```

## What Not To Do

Do not assume:

```text
topology_code alone == primitive mode
count_byte alone == topology target
vertex_count / 2 == quad primitive
long edge == restart proof
object name == topology rule
```

Those can be useful diagnostics, but they are not the runtime rule.

Prefer this priority:

```text
1. Source-backed VIF control mask.
2. GS dump exact match, if source control is missing or ambiguous.
3. Explicitly marked fallback heuristics only when source control is unavailable.
```

## Open Questions

The current implementation is good enough to reconstruct local HP2 PS2 track blocks far more faithfully, but several names remain structural rather than fully reversed:

```text
header[2], header[3]
strip_entry.word_1c low byte naming
packed_values at 0xC034..0xC03F beyond color/control use
exact VU program-side meaning of each tri_cull bit transform
```

Use Ghidra MCP only around primitive mode selection, restart/ADC generation, and block grouping unless the user asks for deeper reverse engineering.
