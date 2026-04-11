# TRACKB44 Alpha / Material Investigation

This document records what is currently proven about wrong alpha-texture output in the `TRACKB44` PS2 exporter path.

It is intentionally separate from the terrain-hole investigation.

The hole work established a topology problem.

This document covers the **material / alpha** side only.

## Scope

Questions addressed here:

- whether the current exporter is too simple for PS2 alpha behavior
- whether `TRACKB44` data already carries useful per-block alpha hints
- what can be fixed without pretending the full PS2 GS pipeline is decoded

Questions **not** answered here:

- the full GS alpha-test state machine
- the exact PS2 blend equation used for each draw
- Z-write behavior for alpha-test failures
- the exact meaning of every render flag value

## Proven Current Exporter Behavior

The current exporter path was inspected directly in:

- `/Users/nurupo/Desktop/dev/eagl-dot/map_tools_ps2/src/map_tools_ps2/textures.py`
- `/Users/nurupo/Desktop/dev/eagl-dot/map_tools_ps2/src/map_tools_ps2/glb_writer.py`

Before the patch in this investigation, the exporter:

1. decoded palette alpha with `_decode_ps2_alpha`
2. classified the entire texture as either `MASK`, `BLEND`, or opaque
3. emitted one material per texture hash
4. forced every textured material to `doubleSided = True`
5. used a fixed `alphaCutoff = 0.5` for all mask materials

That is materially simpler than PS2 behavior.

It means the exporter was not distinguishing:

- road / terrain alpha overlays versus foliage cards
- glass / helicopter windows versus billboard-like cutout props
- textures that are reused under different per-block render flags

## What TRACKB44 Data Proves

### 1. Alpha is not purely a texture-only problem

The same texture name can appear under different `render_flag` values in the same track.

Examples from `TRACKB44`:

- `W_ROADTUNNELB` appears with `0x4041` and with `None`
- `RD_BRIDGEMD_BLEND` appears with `0x4041` and with `None`
- `RD_PUDDLE_MASK` appears with `0x4041` and with `None`

So a material cache keyed only by `texture_hash` is too coarse if usage-side state affects the correct export.

### 2. Alpha-textured road materials cluster under a specific flag

For `TRACKB44`, alpha-textured road materials commonly appear under `render_flag = 0x4041`.

Examples:

- `RD_BRIDGEMD`
- `RD_BRIDGEMD_BLEND`
- `RD_MID1`
- `RD_MID2`
- `RD_MID_LEAF1`
- `RD_MID_LEAF2`
- `RD_MID_LEAFEND`
- `RD_PUDDLE2_MASK`
- `RD_SHLDGVBLD`
- `W_ROADTUNNELB`

That does **not** fully decode `0x4041`, but it does prove there is meaningful per-block state associated with many alpha road materials.

### 3. Some textures are true binary cutouts, some are true graded-alpha textures

Raw palette alpha values from `TEX44TRACK.BIN` / `TEX44LOCATION.BIN` show both classes.

Binary-style examples:

- `1_BIRCH`: `[0, 127]`
- `BRANCH01`: `[0, 127]`
- `RD_BRIDGEMD_BLEND`: `[0, 127]`
- `BUSH3`: `[0, 127]`

True graded-alpha examples:

- `HELI_WINDOW`: `[0, 100]`
- `LIGHT_GLASS`: `[0, 44]`
- `LILLYPADS`: `[0, 14, 28, 40, 56, 66, 76, 89, 101, 111, 119, 127]`
- `LI_RD_BRIDGE01`: `[0, 12, 32, 54, 76, 97, 99, 111, 119, 127]`
- `W_ROADTUNNELB`: `[0, 14, 28, 42, 57, 71, 85, 99, 113, 127]`
- `HELI_ROTOR`: multiple graded steps from `0` upward

So the track genuinely contains both:

- mask-like cutout textures
- blend-like translucent textures

The exporter must not collapse those to one behavior.

### 4. Forcing all textured materials to double-sided was too broad

Before this patch, every textured material was emitted with:

```python
"doubleSided": True
```

That is plainly wrong for at least these families:

- road overlays
- puddles
- tunnel blend surfaces
- helicopter windows

Those are not foliage cards and should not share the same blanket two-sided rule.

This conclusion does **not** require a full PS2 culling decode. It only requires noticing that one exporter-wide default was being applied to obviously different usage classes.

## What Was Changed

### 1. Alpha analysis now preserves a texture-derived cutoff

`textures.py` now computes:

- `alpha_mode`
- `alpha_cutoff`

from the decoded RGBA output.

For `MASK` textures, the exporter now stores the midpoint between the highest transparent alpha and the lowest opaque alpha, instead of hardcoding `0.5`.

Current conservative behavior:

- no transparent pixels below the threshold -> opaque
- only zero-valued transparency -> `MASK`
- any non-zero sub-opaque alpha values -> `BLEND`

This still does **not** decode PS2 GS alpha-test state, but it is a better representation of the decoded source texture.

### 2. Alpha materials are now keyed by usage state, not just texture hash

`glb_writer.py` now caches materials by:

- `texture_hash`
- `alpha_mode`
- `alpha_cutoff`
- `doubleSided`

This matters because the same texture can appear under different object / render-flag contexts in `TRACKB44`.

### 3. Alpha double-sided export is now usage-aware

New conservative rule:

- alpha materials on road / terrain / transition / helicopter families are exported as `doubleSided = False`
- alpha prop / card usage stays `doubleSided = True`

Current exporter rule is intentionally conservative and based on object family, not on an invented GS state decode.

Objects treated as non-double-sided for alpha export include prefixes like:

- `RD_`
- `RDDRT_`
- `TRN_`
- `LI_`
- `TRACK_HELICOPTER`

Render flags `0x4041` and `0xC180` are also treated as non-double-sided alpha usage.

This does **not** claim those flags fully mean "cull enabled" or "glass mode".

It only fixes the proven exporter mistake of sending those alpha surfaces through the same universal two-sided path as foliage cards.

## Validation

Test command:

```text
PYTHONPATH=src python3 -m unittest tests.test_comp
```

Result:

```text
Ran 50 tests in 4.467s

OK
```

Export command:

```text
PYTHONPATH=src python3 -m map_tools_ps2 export \
  --game-dir /Users/nurupo/Desktop/ps2/hp2_ps2/GameFile \
  --track 44 \
  -o /Users/nurupo/Desktop/dev/eagl-dot/map_tools_ps2/out/TRACKB44_alpha_material_fix.glb
```

Result:

```text
wrote /Users/nurupo/Desktop/dev/eagl-dot/map_tools_ps2/out/TRACKB44_alpha_material_fix.glb (921 objects, 263302 decoded vertices)
```

## Important Limits

This patch is **not** a full PS2 alpha fix.

It does **not** reproduce:

- PS2 alpha-test write-color / skip-depth behavior
- PS2 GS blend equations
- per-draw or per-pixel Z-write behavior
- all render-flag semantics

So if some textures still look wrong after this change, the next work item is **not** another heuristic rename.

The next work item is to reverse the render-state path that consumes the per-block flags and alpha-test / blend setup at runtime.

## Practical Takeaway

There were two separate exporter problems:

1. topology holes from incorrect primitive reconstruction
2. wrong alpha appearance from over-simplified material export

This document addresses the second one only.

The current patch fixes a proven exporter mistake:

- alpha materials were being exported with one global double-sided rule
- mask materials were being exported with one global cutoff

That was not faithful even to the decoded source data already available in `TRACKB44`.
