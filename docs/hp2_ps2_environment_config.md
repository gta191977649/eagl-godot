# HP2 PS2 Track Environment Config

## Scope

- Applies to `TRACKB##.LZC` / decompressed track bundles.
- Environment data is stored in top-level `0x000342xx` chunks.
- The game code aligns environment payload reads with `(chunk_offset + 0x17) & ~0xf`; payload-relative aligned offset is usually `0x0c`.

## Known Chunks

| Chunk | Meaning | Notes |
| --- | --- | --- |
| `0x00034200` | Track metadata | Starts with a NUL-terminated track/environment name. |
| `0x00034201` | Track config/list | Seen near metadata; not the sun/light record. |
| `0x00034202` | Sun + lens flare config | Main per-track sun vector and flare sprite records. |
| `0x00034250` | Fog config | Not sun. Ghidra shows `0x80` byte fog records. |

## Sun + Lens Flare Chunk `0x00034202`

Aligned base is `aligned_payload_offset = ((chunk_offset + 0x17) & ~0xf) - data_offset`.

| Offset from aligned base | Type | Meaning |
| --- | --- | --- |
| `0x00` | `u32` | Version/type. Observed value: `2`. |
| `0x04` | `vec3 f32` | Primary sun position/vector used for flare projection. |
| `0x10` | `vec3 f32` | Duplicate/vector used by lighting-side game code. |
| `0x1c` | flare record `[6]` | Six records, stride `0x24`. |

## Flare Record

| Offset | Type | Meaning |
| --- | --- | --- |
| `0x00` | `u32` | Texture index. |
| `0x04` | `u32` | Draw/blend mode. |
| `0x08` | `f32` | Intensity/alpha multiplier. |
| `0x0c` | `f32` | Sprite size. |
| `0x10` | `f32` | Screen X offset. |
| `0x14` | `f32` | Screen Y offset. |
| `0x18` | `rgba8` | Color bytes are R, G, B, A. Treat PS2 alpha `0x80` as full alpha. |
| `0x1c` | `u16` | Angle/base rotation. |
| `0x20` | `f32` | Falloff/rotation factor. |

## Flare Texture Indices

Confirmed from Ghidra function `FUN_001251c0`.

| Index | Texture | Hash |
| --- | --- | --- |
| `0` | `SUNCENTER` | `0x47beb4b6` |
| `1` | `SUNHALO` | `0xd4d26c59` |
| `2` | `SUNMAJORRAYS` | `0x1744b82d` |
| `3` | `SUNMINORRAYS` | `0xad3c5239` |
| `4` | `SUNRING` | `0xd4d80a65` |

## Track Sun Vectors

These are raw PS2-space vectors from `0x34202`.

| Tracks | Vector |
| --- | --- |
| `T61` `T62` `T63` | `(-4000, 2600, 2750)` |
| `T64` `T65` `T66` | `(-4000, 2600, 750)` |
| `T31` `T32` `T33` | `(-3100, 0, 1400)` |
| `T34` `T35` `T36` | `(-3100, 0, 800)` |
| `T11` `T12` `T13` | `(-3900, 650, 1300)` |
| `T14` `T15` `T16` | `(-3900, 650, 1300)`, flare records disabled |
| `T21` `T22` `T23` | `(6000, 5500, 3250)` |
| `T24` `T25` `T26` | `(6000, 5500, 2000)`, flare records disabled |
| `T41` `T42` `T43` | `(-5800, -1000, 2500)` |
| `T44` `T45` `T46` | `(-5800, -1000, 1500)` |

## Godot Mapping

- Convert PS2 vector with `MathUtils.ps2_to_godot_vec3`: `(x, y, z) -> (x, z, -y)`.
- Normalize the converted vector for the directional light.
- Use the original vector magnitude only as source data; render sun at a fixed far distance.
- Directional light is a modern upgrade: enable Godot shadows and let lit track geometry receive/cast shadows.
- Keep sky dome, envmap, and water unlit so the PS2 background treatment is not darkened by the new sun.

## Ambient Fill

- Current best source is `0x34250` fog record color, not `0x34202`.
- Main record name is stored near fog-record `+0x10`, usually `<FOG<MAIN>`.
- Fog color is at fog-record `+0x54` as RGBA bytes.
- Godot ambient fill uses the `MAIN` fog color when present, with fixed energy tuned for the lit-material upgrade.
- This is an inference from track data structure and visual role; it is not yet confirmed as the exact PS2 ambient-light variable.

## Implementation Pointers

- Parser: `eagl/assets/track/track_parser_ps2.gd`
- Runtime sun/shadows: `eagl/rendering/environment_builder.gd`
- Lens flare overlay: `eagl/rendering/sun_lens_flare.gd`
- Lit/unlit material split: `eagl/rendering/material_builder.gd`
