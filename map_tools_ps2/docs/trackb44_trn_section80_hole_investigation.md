# TRACKB44 Terrain Hole Investigation

## Scope

This document records the investigation for the terrain holes visible in exported PS2 track geometry, with the immediate focus on the Blender object named `TRN_SECTION80_CHOP3_0881`.

The goal of this write-up is not to preserve speculation. It captures:

- what object `..._0881` actually is
- what the current exporter was doing
- what the PS2 executable proves about the real runtime structure
- what caused the holes in the exported mesh
- what patch was applied
- what remains unresolved in the real PS2 strip pipeline

This file is intentionally detailed so future agents do not have to reconstruct the same evidence chain from scratch.

## Executive Conclusion

The holes were caused by an exporter-side topology heuristic, not by texture decode, transform decode, or a proven PS2 render rule.

More precisely:

1. `TRN_SECTION80_CHOP3_0881` is object index `881`, object name `TRN_SECTION80_CHOP3`.
2. The exporter was forcing terrain runs to match `0x34004.word07.byte2` by inventing strip restart boundaries through dynamic programming.
3. That heuristic is not backed by decoded PS2 strip-entry semantics.
4. On `TRN_SECTION80_CHOP3`, that heuristic collapsed the object from `1132` geometry-supported strip faces down to `704` emitted faces, which is exactly the kind of underfilled topology that produces visible holes.
5. The PS2 executable proves that the game has a separate strip-entry table/data system. We have not fully decoded that system yet, so using byte-2 as a free-form topology target was unsupported.
6. The first applied patch removed count-driven topology invention for non-prop terrain/road objects and kept only evidence-backed geometry restart detection there.
7. A follow-up validation pass found a second failure class: some road/terrain runs are not full strips either. They are better explained by exact metadata-matched primitive batches, especially quads.
8. The current exporter now does two things:
   - it does **not** invent restart boundaries from byte-2 for terrain/road runs
   - it **does** promote exact triangle/quad candidates when they are exact metadata matches and measurably better on geometry and UV coherence than strip

This is still a conservative fix. It removes the known bad behavior without pretending we have fully decoded the PS2 strip-entry pipeline.

## Session Note: Ghidra MCP Availability

The user requested Ghidra MCP for the reverse-engineering portion.

Attempting to access the MCP server in this session failed immediately during initialization:

```text
resources/list failed: failed to get client:
MCP startup failed:
handshaking with MCP server failed:
connection closed: initialize response
```

So the reverse-engineering evidence in this document comes from:

- bundle/asset inspection inside this repo
- `radare2` disassembly of `SLUS_203.62`

not from a live Ghidra MCP session.

## Object Identification

The Blender object suffix `_0881` comes from the exporter object index formatting.

In the current exporter, GLB node names are generated as:

```python
nodes.append({"name": f"{obj.name}_{object_index:04d}", "mesh": len(meshes) - 1})
```

For `TRACKB44.BUN`, object index `881` resolves to:

```text
object_index 881 chunk_offset 0x6f2860 blocks 50
name = TRN_SECTION80_CHOP3
```

So the screenshot label `TRN_SECTION80_CHOP3_0881` maps directly to:

- object name: `TRN_SECTION80_CHOP3`
- scene object index: `881`
- chunk offset: `0x006f2860`

## PS2 Runtime Evidence: This Is a Strip-Entry System

The strongest non-speculative result from the executable work is that the game runtime has an explicit strip-entry table and strip-entry data pair for this geometry path.

### Relevant strings in `SLUS_203.62`

`strings -a SLUS_203.62` exposes:

- `TRISTRIP`
- `DuplicatedStripEntryData`
- `DuplicatedStripEntryTable`
- `CulledStripsNotVisible`
- `CulledStripsFullVisible`
- `CulledStripsPartialVisible`
- `eStripEntry`

Those names already strongly suggest the terrain/solid path is not “just decode one vertex run as one monolithic strip and hope.”

### Relevant functions

Using `radare2` on `/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/SLUS_203.62`:

- `fcn.00103bf0`
- `fcn.00103ff0`

show the clearest concrete evidence.

### `fcn.00103bf0`

This function duplicates three related resources whose debug labels are visible in the binary:

- `DuplicatedSolid`
- `DuplicatedStripEntryData`
- `DuplicatedStripEntryTable`

Behavior observed in disassembly:

- it allocates a copy of the strip-entry data blob using the original object field at offset `0x3c`
- it allocates a copy of the strip-entry table using the original object field at offset `0x34`
- the table allocation size is `count << 6`, which means each entry is `0x40` bytes

That `0x40` entry size is an exact structural match for the `0x00034004` records in the track bundle.

### `fcn.00103ff0`

This function iterates the copied `0x40`-byte table entries and adjusts the value at entry offset `+0x08`:

- load count from object `+0x34`
- load table pointer from object `+0xb0`
- for each entry:
  - load `entry[0x08]`
  - add new data base
  - subtract old data base
  - store adjusted value back to `entry[0x08]`

In plain language:

- each strip-entry table record contains an offset/pointer at `+0x08`
- that offset points into the duplicated strip-entry data buffer

This matches our bundle observations exactly:

- `0x00034004.word02` lives at record offset `+0x08`
- it points into `0x00034005`
- `0x00034004.word03.low16 * 16` matches the byte span for that data slice

### What this proves

This is enough to support the following statement as evidence-backed:

`0x00034004` and `0x00034005` are not arbitrary exporter metadata. They correspond to the PS2 runtime strip-entry table/data path used by world solids / terrain-like geometry.

What it does **not** prove yet:

- the exact semantic meaning of every table field
- the exact segmentation rule that turns one entry’s vertex payload into its final emitted triangle batches
- whether byte `0x1e` is “triangle count”, “surviving strip triangle count”, “post-cull primitive count”, or another count tied to strip processing

## Asset Evidence for `TRN_SECTION80_CHOP3`

Running `tools/analyze_bun_models.py` against:

- bundle: `/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA/TRACKS/TRACKB44.BUN`
- texture dir: `/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA/TRACKS`
- object filter: `TRN_SECTION80_CHOP3`

produced:

```text
## object 0x006f2860 TRN_SECTION80_CHOP3
header_size=0xc0 name_start=0x10 vif_size=0x8118
metadata_prefixed=False metadata_size=0xc80 records=50 vif_runs=50
```

Important takeaways:

- the object has `50` strip-entry records
- the `0x34004` table size is `0xc80 = 50 * 0x40`
- the `0x34005` data blob is `0x8118` bytes
- record count and decoded VIF run count match exactly

That is consistent with the PS2 runtime function that copies:

- a `count * 0x40` strip-entry table
- a separate strip-entry data blob

### Texture set for this object

`TRN_SECTION80_CHOP3` references four textures:

- `CLIFF_4BLEND`
- `GRASS01`
- `RIVER_BOTTOM`
- `RIVERBED1_SHORE`

This is normal terrain material content, not an unusual prop path.

## Stage 1: Removing Unsupported Count-Fit Topology

The first patch addressed the original hole source by removing count-fit strip segmentation for non-props.

### The critical metric: old exporter vs geometry-supported strip

For the exact object in question:

```text
TRN_SECTION80_CHOP3
blocks = 50
raw strip faces      = 1152
geometry strip faces = 1132
metadata byte2 sum   = 704
```

Before the patch, the exporter emitted:

```text
chosen faces = 704
```

After the patch, the exporter emits:

```text
chosen faces = 1132
```

That is the single most important numeric result in this investigation.

The old exporter was deleting `428` faces relative to the geometry-backed strip result on this one object alone:

```text
1132 - 704 = 428
```

That is large enough to explain the visible underfilled terrain patch / hole pattern in the screenshot.

### Why that old path was wrong

The problem was not simply “we used byte2.”

The problem was:

- we used byte2
- without decoded strip-entry semantics
- and let it drive a free-form restart-boundary search

That distinction matters.

### What the old code did

For non-prop terrain and road objects, `_indices_for_run()` and `_indices_for_block()` considered several candidates derived from `expected_face_count` / metadata byte-2:

- full raw strip
- segmented strip with arbitrary restart boundaries chosen to hit the target count
- flexible segmented strip with even more padding freedom
- topology-code-specific hybrid paths for some subtype codes

The old replacement logic accepted these candidates whenever they matched the metadata count “well enough” and did not look obviously distorted by the exporter’s geometric score.

That sounds safe, but it is not. Matching the face count alone does **not** prove that the chosen restart boundaries are the same ones the PS2 runtime used.

### Why this is unsupported

The runtime evidence says the PS2 uses a strip-entry system.

What we do **not** currently decode:

- the true strip subdivision rule
- any hidden per-strip batch metadata
- any index/segment control embedded beyond the fields we already mapped

So when the old exporter searched all possible boundaries until the total triangle count matched byte-2, it was not decoding PS2 behavior. It was fabricating a topology that happened to satisfy one count.

That is exactly the kind of guesswork the user asked us to eliminate.

### Concrete per-run evidence

A few representative runs from `TRN_SECTION80_CHOP3` are enough to show the pattern.

### Run 0

```text
vertex_count = 30
metadata byte2 = 16
old emitted faces = 16
new emitted faces = 25
geometry strip faces = 25
```

The old exporter threw away `9` faces even though the geometry-backed strip candidate already had:

- `0` bad triangles
- low distortion score

There was no decoded PS2 evidence justifying that trim.

### Run 1

```text
vertex_count = 29
metadata byte2 = 17
old emitted faces = 17
new emitted faces = 24
geometry strip faces = 24
```

Again, the previous exporter forced a count match and removed `7` geometry-supported faces.

### Run 2

```text
vertex_count = 28
metadata byte2 = 22
old emitted faces = 22
new emitted faces = 26
geometry strip faces = 26
```

### Run 3

```text
vertex_count = 30
metadata byte2 = 18
old emitted faces = 18
new emitted faces = 26
geometry strip faces = 26
```

### Runs 5 through 41

This pattern repeats across the object:

- many runs with `28-30` decoded vertices
- metadata byte-2 values in the `12-18` range
- old exporter reduced them to that target count
- geometry-backed strip output stayed in the `22-27` range

This is why the object looked shredded.

### Widespread impact on TRACKB44

This was not isolated to one object.

Before the patch, `TRACKB44` had `166` terrain/road objects where the exporter emitted at least `40` fewer faces than the geometry-backed strip path.

Largest examples observed before the fix:

```text
0371 TRN_SECTION30_CHOP6          chosen=2820 geom=3982 delta=1162
0302 TRN_SECTION20_CHOP5          chosen=2718 geom=3715 delta= 997
0654 TRN_SECTION70_MINE_PROP      chosen=1617 geom=2553 delta= 936
0256 TRN_SECTION20_CHOP3          chosen=2180 geom=3023 delta= 843
0904 TRN_SECTION80_CHOP6          chosen=1324 geom=2106 delta= 782
0730 TRN_SECTION70_CHOP5          chosen=1639 geom=2376 delta= 737
0340 TRN_SECTION30_CHOP3          chosen=1846 geom=2577 delta= 731
0400 TRN_SECTION40_CHOP2          chosen=1320 geom=2046 delta= 726
0440 TRN_SECTION50_CHOP2          chosen=1429 geom=2148 delta= 719
0601 TRN_SECTION60_CHOP8          chosen=1320 geom=2034 delta= 714
...
0881 TRN_SECTION80_CHOP3          chosen= 704 geom=1132 delta= 428
```

After the patch:

```text
remaining_deltas 0
```

Meaning:

- for terrain/road objects, the exporter no longer underfills geometry relative to its own geometry-backed strip reconstruction
- the count-driven topology pruning path is gone for those classes

### Why geometry-backed strip was the right first conservative fallback

This patch does **not** claim that the geometry-backed strip is the exact PS2 answer.

It claims something narrower and stronger:

- geometry-backed strip restart detection is supported by actual decoded vertex relationships
- metadata-byte2 dynamic programming for terrain is not

So until the real strip-entry semantics are decoded, the safer hierarchy is:

1. explicit proven primitive modes for prop-style objects
2. geometry-backed strip restart detection
3. do **not** invent extra restart boundaries just to satisfy metadata byte-2

That policy removes unsupported face deletion.

### First applied patch

The patch changed `src/map_tools_ps2/glb_writer.py`.

### New rule

Unknown-count-driven topology search is now restricted to prop-style objects only.

Terrain / road / shoulder objects now:

- still use geometry restart detection
- still skip obvious bad background objects
- still keep prop-specific explicit triangle/quad promotion separate
- no longer use metadata byte-2 to synthesize strip restarts

### Practical effect

For non-props:

- `_indices_for_run()` now returns the geometry-backed strip result directly
- `_indices_for_block()` no longer applies topology-code hybrid/flexible count heuristics

For props:

- existing count-based behavior remains available, because that path was intentionally used to recover non-strip explicit primitive layouts on many small scenery objects

### Stage 1 validation

### Unit / repo tests

Executed:

```text
PYTHONPATH=src python3 -m unittest tests.test_comp
```

Result:

```text
Ran 44 tests in 3.846s
OK
```

### Target object verification

Executed against `TRACKB44.BUN` after the patch:

```text
TRN_SECTION80_CHOP3 chosen 1132 geom 1132 meta 704
```

This confirms the target object no longer gets cut down to the metadata-count result.

### Whole-track terrain / road verification after stage 1

Executed against `TRACKB44.BUN` after the patch:

```text
remaining_deltas 0
```

Meaning there are no remaining terrain/road objects in `TRACKB44` where the exporter still emits fewer faces than its own geometry-backed strip reconstruction.

### Export artifact

Track export generated successfully after the patch:

```text
out/TRACKB44_topology_fix.glb
```

Command used:

```text
PYTHONPATH=src python3 -m map_tools_ps2 export \
  --game-dir /Users/nurupo/Desktop/ps2/hp2_ps2/GameFile \
  --track 44 \
  -o out/TRACKB44_topology_fix.glb
```

Result:

```text
wrote out/TRACKB44_topology_fix.glb (921 objects, 263302 decoded vertices)
```

## Stage 2: Exact Primitive Batches for Remaining UV-Broken Runs

The first patch fixed the “holes from underfilled terrain” problem, but it did not fully solve topology for all affected runs.

The user then reported a concrete follow-up issue:

- newly filled geometry existed
- but some of the new faces had clearly wrong UV correspondence
- screenshot focus was around `SECTION50_CHOP4`

This changed the diagnosis from:

- “the exporter is deleting too many faces”

to:

- “some runs are not strips at all, so restoring all strip faces is still wrong”

### Concrete screenshot target

The screenshot label was truncated, but the visible object suffix strongly pointed at object index `0466`.

`TRACKB44.BUN` scene objects around that index:

```text
466 RDDRT_SECTION50_CHOP4
467 RD_SECTION50_CHOP4
469 TRN_SECTION50_CHOP4
```

These were inspected together because they are the matching road / road-edge / terrain companions for the same section.

### The pattern found in `SECTION50_CHOP4`

Many runs in these objects have this exact shape:

```text
vertex_count = 28
metadata byte2 = 14
```

That is an exact match for the exporter’s quad-batch face count rule:

```text
quad faces = vertex_count / 2
```

Examples:

- `RDDRT_SECTION50_CHOP4` blocks `18..29`
- `RD_SECTION50_CHOP4` many early road blocks
- selected `TRN_SECTION50_CHOP4` blocks
- selected `TRN_SECTION80_CHOP3` blocks

### Why this is stronger than the old byte-2 count fitting

This second-stage rule is **not** “search arbitrary boundaries until the face count matches.”

It is much narrower:

1. only consider exact primitive candidates already implied by the vertex count:
   - triangle list when `expected_face_count == vertex_count / 3`
   - quad batches when `expected_face_count == vertex_count / 2`
2. compare those exact candidates against strip using:
   - geometry score
   - UV coherence score
3. only promote the exact candidate when it is measurably better

That means this rule is bounded by actual decoded data and does not fabricate unknown restart boundaries.

### UV coherence evidence

For the road blocks in `RD_SECTION50_CHOP4`, the strip candidate repeatedly produced many tiny / zero-area UV triangles, while the quad candidate removed them.

Representative examples:

```text
RD_SECTION50_CHOP4 block 0:
  strip_uv = (6 tiny, worst_edge 1.111, 24 faces)
  quad_uv  = (0 tiny, worst_edge 1.111, 14 faces)

RD_SECTION50_CHOP4 block 11:
  strip_uv = (8 tiny, worst_edge 1.406, 24 faces)
  quad_uv  = (0 tiny, worst_edge 1.406, 14 faces)

RDDRT_SECTION50_CHOP4 block 22:
  strip_uv = (10 tiny, worst_edge 1.414, 26 faces)
  quad_uv  = (0 tiny, worst_edge 1.414, 14 faces)

TRN_SECTION50_CHOP4 block 23:
  strip_uv = (6 tiny, worst_edge 2.236, 26 faces)
  quad_uv  = (0 tiny, worst_edge 2.236, 14 faces)

TRN_SECTION80_CHOP3 block 5:
  strip_uv = (4 tiny, worst_edge 1.414, 24 faces)
  quad_uv  = (0 tiny, worst_edge 1.414, 14 faces)
```

The tuple format above is:

```text
(tiny_uv_area_face_count, worst_uv_edge_length, face_count)
```

This is the strongest asset-side evidence for the second-stage patch:

- the strip candidate was creating UV-degenerate faces
- the exact quad candidate removed them
- the quad candidate also matched metadata byte-2 exactly

### Geometry evidence for the same runs

These exact quad candidates also consistently score better or equal on geometry.

Examples:

```text
RDDRT_SECTION50_CHOP4 block 22:
  quad_score  = (0 bad, 1.0000 worst, 14 faces)
  strip_score = (0 bad, 2.2974 worst, 26 faces)

RD_SECTION50_CHOP4 block 0:
  quad_score  = (0 bad, 1.0228 worst, 14 faces)
  strip_score = (0 bad, 1.9771 worst, 24 faces)

TRN_SECTION50_CHOP4 block 23:
  quad_score  = (0 bad, 1.0783 worst, 14 faces)
  strip_score = (0 bad, 2.4781 worst, 26 faces)
```

So this is not a UV-only patch. The exact quad layout is also geometrically cleaner.

### Practical result after stage 2

Selected inspected blocks now resolve as:

```text
466 RDDRT_SECTION50_CHOP4 block 22 -> 14 faces
467 RD_SECTION50_CHOP4    block 0  -> 14 faces
469 TRN_SECTION50_CHOP4   block 23 -> 14 faces
881 TRN_SECTION80_CHOP3   block 5  -> 14 faces
```

Aggregate object totals after stage 2:

```text
466 RDDRT_SECTION50_CHOP4 chosen 394 geom 517 meta 336
467 RD_SECTION50_CHOP4    chosen 550 geom 774 meta 509
469 TRN_SECTION50_CHOP4   chosen 1805 geom 1858 meta 1498
881 TRN_SECTION80_CHOP3   chosen 959 geom 1132 meta 704
```

Interpretation:

- stage 1 fixed the catastrophic underfill (`704 -> 1132`) for `TRN_SECTION80_CHOP3`
- stage 2 backed off some of that reintroduced strip fill where exact primitive batches were better supported
- the current result (`959`) stays well above the broken old value (`704`) while avoiding many UV-degenerate strip faces

### Second applied patch

The current exporter now includes:

- `_uv_topology_score(...)`
- `_should_prefer_exact_primitive(...)`
- `_exact_primitive_indices_for_block(...)`

These are used to promote exact triangle/quad candidates when:

- metadata face count is an exact match
- geometry is not worse
- UV coherence improves materially

This logic was added in:

- `src/map_tools_ps2/glb_writer.py`

### Stage 2 validation

Tests:

```text
PYTHONPATH=src python3 -m unittest tests.test_comp
Ran 45 tests
OK
```

New fixture coverage includes:

- `TRACKB44` `RD_SECTION50_CHOP4` block 0 choosing the exact 14-face quad batch
- `TRACKB44` `TRN_SECTION80_CHOP3` staying between the broken metadata-only result and the full strip result

Updated export artifact:

```text
out/TRACKB44_topology_uv_fix.glb
```

Command:

```text
PYTHONPATH=src python3 -m map_tools_ps2 export \
  --game-dir /Users/nurupo/Desktop/ps2/hp2_ps2/GameFile \
  --track 44 \
  -o out/TRACKB44_topology_uv_fix.glb
```

Result:

```text
wrote out/TRACKB44_topology_uv_fix.glb (921 objects, 263302 decoded vertices)
```

## Stage 3: Deterministic Exact-Quad Rule

Stage 2 was still not strict enough.

It improved several `SECTION50_CHOP4` blocks, but it still left some source-clean exact-quad runs on strip-derived topology because the decision was still score-based.

Concrete `TRACKB44` examples that were still wrong after stage 2:

```text
RDDRT_SECTION50_CHOP4 block 18 chosen_faces 26 quad_faces 14
RDDRT_SECTION50_CHOP4 block 20 chosen_faces 26 quad_faces 14
RD_SECTION50_CHOP4    block 27 chosen_faces 16 quad_faces 14
TRN_SECTION50_CHOP4   block 67 chosen_faces 22 quad_faces 14
TRN_SECTION50_CHOP4   block 85 chosen_faces 12 quad_faces 10
```

### Additional `radare2` Findings

Reverse engineering on `SLUS_203.62` produced two hard results that matter here.

#### `0x001036c0` chunk mapping

The world-solid loader at `0x001036c0` maps object chunks like this:

- `0x00034004` -> object `+0xb0`
- `0x00034005` -> object `+0xb4`, with byte size at `+0x3c`
- `0x00034006` -> object `+0xb8`, with entry count at `+0xac`
- `0x0003401d` -> object `+0xbc`

This confirms that object `+0xb8` is the duplicated `0x34006` table.
It is not an unknown primitive-descriptor table.

#### `0x00104070` material-index usage

The runtime loop at `0x00104070`:

- iterates the `0x40`-byte records from object `+0xb0`
- steps by `0x40`
- reads record byte `0`
- multiplies it by `8`
- indexes object `+0xb8`
- compares the referenced `32`-bit value to the requested key
- toggles bit `0x0100` in record field `+0x0e`

That is consistent with `0x34006` being the texture-hash table already documented in the bundle format.
So record byte `0` remains a texture/material index.
It is not primitive mode.

This removes one false lead and leaves the exact-topology evidence in the decoded VIF run itself.

### Source-Clean Exact Quads

For a non-prop road / terrain block, the exporter can now use a deterministic exact-quad rule when all of the following are true:

1. `expected_face_count == vertex_count / 2`
2. `vertex_count % 4 == 0`
3. straight `4`-vertex quad batching emits exactly `expected_face_count` faces
4. those quad faces have zero geometry-degenerate triangles
5. those quad faces have zero tiny / zero-area UV triangles

This is not a score preference.
It is a direct statement about the decoded source vertices and UVs.

Track-wide scan for non-prop `RD_`, `RDDRT_`, and `TRN_` objects in `TRACKB44`:

```text
exact-count road/terrain runs: 3160
clean exact-quad runs:         2968
```

### Concrete Stage-3 Validation

For the blocks that stage 2 still missed:

```text
RDDRT_SECTION50_CHOP4 block 18 -> 14 faces
RDDRT_SECTION50_CHOP4 block 20 -> 14 faces
RD_SECTION50_CHOP4    block 27 -> 14 faces
TRN_SECTION50_CHOP4   block 67 -> 14 faces
TRN_SECTION50_CHOP4   block 85 -> 10 faces
```

Tests:

```text
PYTHONPATH=src python3 -m unittest tests.test_comp
Ran 46 tests
OK
```

Updated object totals:

```text
466 RDDRT_SECTION50_CHOP4 chosen 370 geom 517 meta 336
467 RD_SECTION50_CHOP4    chosen 548 geom 774 meta 509
469 TRN_SECTION50_CHOP4   chosen 1795 geom 1858 meta 1498
881 TRN_SECTION80_CHOP3   chosen 959 geom 1132 meta 704
```

Updated export artifact:

```text
out/TRACKB44_topology_deterministic_quad_fix.glb
```

Command:

```text
PYTHONPATH=src python3 -m map_tools_ps2 export \
  --game-dir /Users/nurupo/Desktop/ps2/hp2_ps2/GameFile \
  --track 44 \
  -o out/TRACKB44_topology_deterministic_quad_fix.glb
```

Result:

```text
wrote out/TRACKB44_topology_deterministic_quad_fix.glb (921 objects, 263302 decoded vertices)
```

## Important Non-Conclusions

This investigation does **not** prove:

- that metadata byte-2 is useless
- that the geometry-backed strip result is fully PS2-accurate
- that topology codes `0x05`, `0x07`, `0x12` are fully understood
- that `V4_5` packed values are irrelevant
- that glTF `MASK` / `BLEND` output reproduces PS2 GS alpha-test or blending behavior

Instead, it proves a narrower but actionable point:

The exporter’s old terrain-hole behavior came from treating metadata byte-2 as enough information to invent topology. It is not enough.

It also proves that a large class of exact `vertex_count / 2` road / terrain runs in `TRACKB44` are already clean quad batches in the decoded source data, and those can be emitted deterministically without waiting for the full strip-entry runtime decode.

## Alpha Pipeline Note: Relevant To Texture Appearance, Not Proof For Holes

Background material about PS2 alpha test / blending behavior is useful for a **separate** exporter problem: wrong alpha-texture appearance in the final GLB.

That background does **not** change the core topology conclusion of this document.

What is proven here:

- the `TRN_SECTION80_CHOP3` / `SECTION50_CHOP4` hole cases came from primitive reconstruction
- the exporter was selecting the wrong faces for some road / terrain runs
- that failure is evidenced by face counts, run-by-run topology inspection, and decoded runtime chunk usage

What the current exporter actually does for alpha is much simpler than PS2 GS behavior:

- palette alpha is decoded in `/Users/nurupo/Desktop/dev/eagl-dot/map_tools_ps2/src/map_tools_ps2/textures.py` via `_decode_ps2_alpha`
- the exporter then classifies the entire texture as either `MASK`, `BLEND`, or opaque in `_alpha_mode_for_rgba`
- material emission in `/Users/nurupo/Desktop/dev/eagl-dot/map_tools_ps2/src/map_tools_ps2/glb_writer.py` maps that to glTF `alphaMode` and a fixed `alphaCutoff = 0.5`

That means the current exporter does **not** model:

- PS2 per-pixel alpha-test outcomes that can still write color while skipping depth
- PS2 GS blend equations that do not map cleanly to standard PC / glTF blending
- per-material or per-draw alpha-test state beyond the texture-wide `MASK` / `BLEND` guess

So:

- yes, PS2 alpha-pipeline research is relevant to the wrong-alpha-texture issue
- no, it is not evidence that the terrain-hole bug was caused by alpha handling
- the two issues should be investigated separately to avoid mixing geometry errors with material/render-state errors

## Remaining Reverse-Engineering Work

The real long-term fix is to decode the actual PS2 strip-entry semantics, not to keep layering heuristics.

Highest-value remaining tasks:

1. Find the render / build path that consumes the `eStripEntry` table at runtime.
2. Determine the exact meaning of the `0x40` table record fields, especially byte `0x1e` and the tail fields after bounds.
3. Determine whether the true strip subdivision lives in:
   - table entry flags
   - `0x34005` sub-packet structure
   - `V4_5` packed data
   - a combination of table + VIF/VU state
4. Confirm whether byte-2 is:
   - final emitted triangle count
   - post-cull triangle count
   - per-entry strip primitive count
   - or another count related to strip visibility/subdivision
5. Confirm whether some exact `vertex_count / 2` cases are true quad batches in the PS2 runtime, or whether they are a visible side effect of a more specific strip-entry mode that just happens to collapse to the same topology.

Until that work is done, topology changes driven solely by byte-2 should be treated as untrusted for terrain.

## Reproduction Notes

### Object inspection

```text
PYTHONPATH=src python3 tools/analyze_bun_models.py \
  /Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA/TRACKS/TRACKB44.BUN \
  --texture-dir /Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA/TRACKS \
  --object TRN_SECTION80_CHOP3
```

### Runtime string check

```text
strings -a /Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/SLUS_203.62 | \
  rg "TRISTRIP|eStripEntry|DuplicatedStripEntry|CulledStrips"
```

### Runtime disassembly points

```text
r2 -2qc 'aaa; s 0x00103bf0; pdf' /Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/SLUS_203.62
r2 -2qc 'aaa; s 0x00103ff0; pdf' /Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/SLUS_203.62
```

## Final Takeaway

The immediate hole bug was exporter guesswork.

The PS2 runtime clearly has a strip-entry system, but the exporter had been using only one count field from that system to synthesize topology for terrain. That was not a decoded rule, and it removed hundreds of faces from `TRN_SECTION80_CHOP3` alone.

The applied patch stops doing that.

Future work should decode the actual strip-entry semantics rather than reintroducing count-fitting heuristics.
