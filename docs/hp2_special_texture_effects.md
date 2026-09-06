# HP2 PS2 special texture effects

This document is the source-of-truth for shader-addressable texture roles in
`map_tools_ps2`. Classification is deliberately independent of texture and
object display names.

## Ghidra evidence

Program: `SLUS_203.62` in the `hp2_ps2` Ghidra project.

- `FUN_001036c8` is the solid/model pack loader. It recognizes model chunks
  `0x34003`, `0x34004`, `0x34005`, `0x34006`, and `0x3401d`. It tests bit
  `0x10` at model offset `0x30` and allocates an element from
  `eVertexAnimatorSlotPool` when the bit is set.
- `FUN_0010a008` constructs `eVertexAnimatorSlotPool` with 16 records of
  `0x110` bytes. This is a model/vertex animation mechanism, not sufficient
  evidence that an arbitrary `0x3401d` chunk animates UVs.
- The executable contains distinct `TexturePack`, `TextureAnimPack`,
  `LoadedTextureData`, and `UpdateTextureAnimations` identifiers. The global
  animation pack is serialized as metadata chunk `0x30300102` and frame chunk
  `0x30300103`.
- The executable surface-name table at `0x003312b0` contains the native
  `PUDDLE` surface. Track collision records distinguish `PUDDLE` (4) and
  `MUD_PUDDLE` (20); those face-level records are the reflection evidence.

## Serialized texture evidence

All 60 track texture packs were audited. TPK entries are `0xa4` bytes. The
time-varying UV descriptor is stored in the entry tail:

| Offset | Type | Meaning |
|---|---|---|
| `0x78` | `u32` | effect flags; bit `0x100` enables UV motion |
| `0x7c` | `f32` | authored U scroll rate |
| `0x80` | `f32` | authored V scroll rate |

For example, texture hash `0x04c80a1b` has flags `0x100`, U rate `0`, and V
rate `-0.390625`. Renaming that texture does not affect its classification.
Across all 30 tracks, every non-zero descriptor represents translation along U
or V. No source UV-rotation descriptor was found.

## Exported effect classes

The authoritative prefix registry and MTA length contract live in
`map_tools_ps2/src/map_tools_ps2/special_textures.py`. Scene classification,
managed export, manifests, reports and validation import that registry; this
list is explanatory rather than a second configuration source.

Four source-backed classes occur in the shipped track data:

1. `reflection` -> `refl_*`
2. `uv_scroll` -> `uvscroll_*`
3. `texture_animation` -> `texanim_*`
4. `model_animation` -> `modelanim_*`

`uvrotate_*` is reserved in the public manifest contract but currently has no
source-backed texture in the 30 tracks. It must not be populated from a name
or visual guess.

For model animation, only the dominant material of a source-flagged animated
model is marked. Dominance is accumulated source triangle area, with the
texture-slot index as the deterministic tie-breaker.

Windmill-like assets without a source model-animation flag are not labeled
`modelanim_*`. Authored moving belt/water materials that carry the TPK UV
descriptor are still labeled `uvscroll_*`; this avoids contaminating static
support materials.

## Alpha contract

Reflection raster alpha is retained byte-for-byte in the TXD for shader use.
The exported material is nevertheless `OPAQUE`, and its definition does not
receive `draw_last`, `additive`, or `no_zbuffer_write`. The special-texture
manifest records both source and exported alpha modes.
