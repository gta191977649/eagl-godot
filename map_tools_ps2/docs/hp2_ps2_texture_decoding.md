# HP2 PS2 Texture Decoding

This document describes how to decode Need for Speed: Hot Pursuit 2 PS2 track textures from `TEX##TRACK.BIN` and `TEX##LOCATION.BIN`.

The important rule is that HP2 PS2 legacy texture packs should follow Modelulator's legacy PS2 texture path, not the newer simplified PS2 texture path.

Reference implementations:

```text
Python:
src/map_tools_ps2/textures.py

Modelulator:
/Users/nurupo/Desktop/dev/modelulator.v5.1.5.pub/src/loaders/Legacy/eTexturePack.lua
/Users/nurupo/Desktop/dev/modelulator.v5.1.5.pub/src/util/texture/Legacy/PSX2.lua
```

## Texture Files

Track texture lookup uses files from `ZZDATA/TRACKS`:

```text
TEX##TRACK.BIN
TEX##LOCATION.BIN
```

For `TRACKB64`, load:

```text
TEX64TRACK.BIN
TEX64LOCATION.BIN
```

The exporter currently loads `LOCATION` first and then `TRACK`, keeping the first texture found for each texture hash.

## bChunk Layout

Texture BIN files are bChunk containers.

The useful chunks are:

```text
0x30300003  texture entry table
0x30300004  texture image and palette data blob
```

The data blob payload starts at the `0x30300004` chunk data offset aligned to `0x80`.

```text
data_base = align(data_chunk.data_offset, 0x80)
```

Texture entry offsets are relative to `data_base`.

## Texture Entry Format

Each texture entry is `0xA4` bytes.

Known fields:

```text
0x08  char[0x18]  texture name, null terminated
0x20  u32         texture hash
0x24  u16         width
0x26  u16         height
0x28  u8          bit depth field
0x30  u32         image data offset, relative to data_base
0x34  u32         palette offset, relative to data_base
0x38  u32         image data size
0x3C  u32         palette size
0x48  u8          shift_width
0x49  u8          shift_height
0x4A  u8          pixel_storage_mode
0x4B  u8          clut_pixel_storage_mode
0x4E  u8          texture_fx
0x4F  u8          is_any_semitransparency
0x55  u8          swizzle flag, nonzero means swizzled
0x76  u8          alpha_bits
0x77  u8          alpha_fix
```

Read image and palette bytes like this:

```text
image   = data[data_base + image_offset   : data_base + image_offset   + image_size]
palette = data[data_base + palette_offset : data_base + palette_offset + palette_size]
```

Skip entries with empty name, zero dimensions, missing image bytes, or missing palette bytes.

## Pixel Storage Modes

The low three bits of `pixel_storage_mode` identify the indexed texture depth in the current decoder:

```text
psm_type_index = pixel_storage_mode & 0x07
```

Depth selection:

```text
if psm_type_index > 0:
    depth = 32 >> max(psm_type_index - 1, 0)
elif bit_depth in {4, 8}:
    depth = bit_depth
elif palette_size == 0x40:
    depth = 4
elif palette_size in {0x80, 0x400}:
    depth = 8
else:
    unsupported
```

Supported indexed depths are currently `4` and `8`.

Common HP2 PS2 examples:

```text
PSMT4-like textures: pixel_storage_mode 0x14, palette_size 0x40, depth 4
PSMT8-like textures: pixel_storage_mode 0x13, palette_size 0x400, depth 8
```

## Palette Decode

Palette entries are stored as four bytes:

```text
R, G, B, A
```

The current PNG/GLB path emits RGBA.

PS2 alpha is not a direct 0..255 alpha value. Decode it as:

```text
expanded = max((a << 1) - ((a ^ 1) & 0x01), 0)
if expanded <= 0xFF:
    a = expanded
else:
    a = original_a
```

Palette swizzle is needed when `pixel_storage_mode & 0x07 == 3`.

Palette index remap:

```text
block = index & ~0x1F
pos = index & 0x1F

if 8 <= pos < 16:
    pos += 8
elif 16 <= pos < 24:
    pos -= 8

source_index = block + pos
```

Then read palette color from `source_index * 4`.

## Correct Swizzled Texture Decode

For entry-driven HP2 PS2 decode, do not use the older fallback helpers or a simple linear row decode for swizzled textures.

Use the legacy Modelulator `RWBuffer` path:

```text
texture.Legacy.PSX2:Get
  if swizzled:
      Buffer = PSX2.RWBuffer(Input, "Write", PSMCT32, 32, width / scale_y, height / scale_x)
      Input  = PSX2.RWBuffer(Buffer, "Read", pixel_storage_mode, depth, width, height)
  unpack indexed pixels from 32-bit words
  crop each row from buffer_width to visible width
  flip vertically
  map indices through decoded palette
```

This is implemented in Python as:

```text
_decode_modelulator_indexed_texture
_legacy_ps2_rw_buffer
_legacy_ps2_swizzle_psmt4
_legacy_ps2_swizzle_psmt8
_legacy_ps2_block_address
```

### Why This Matters

Using the newer/non-legacy PS2 swizzle path produces visible colored or diagonal bands in terrain textures.

Known textures that show the issue when decoded incorrectly:

```text
SH_CLIFF2SANDBLEND
SHLD_G
D_TERRAINGRASS
SH_BEACHSAND2OCEAN
ROAD06
```

Fixed sample PNGs generated from the Python reference are in:

```text
/tmp/hp2_texture_samples_fixed
```

Broken comparison samples from the old decoder are in:

```text
/tmp/hp2_texture_samples_current
```

## Legacy RWBuffer Summary

The legacy path treats texture memory as PS2 GS pages, blocks, columns, words, and packed subword pixels.

Important derived values:

```text
scale      = 32 / depth
scale_mask = scale - 1

scale_x = bit_extract(scale_mask, width=1, pos=2, shift=1)
        | bit_extract(scale_mask, width=1, pos=0, shift=0)
scale_x += 1

scale_y = bit_extract(scale_mask, width=1, pos=3, shift=1)
        | bit_extract(scale_mask, width=1, pos=1, shift=0)
scale_y += 1

buffer_width  = next_power_of_two(width)
buffer_height = next_power_of_two(height)
```

`pixel_storage_mode` fields:

```text
type_index = (pixel_storage_mode >> 0) & 0x07
type_flag  = (pixel_storage_mode >> 3) & 0x01
type_mode  = (pixel_storage_mode >> 4) & 0x03
```

The RWBuffer implementation needs:

```text
swap_xy = ((type_mode == 0 or type_mode == 3) and type_index == 2)
          or (type_mode == 1 and type_index == 4)

z_buffer = type_mode == 3

shifted = (type_mode == 0 or type_mode == 3)
          and type_index == 2
          and type_flag != 0
```

The complete address calculation is easy to get subtly wrong. Port from `src/map_tools_ps2/textures.py` rather than rewriting from memory.

## Final Image Orientation

After remapping and unpacking indices:

1. If the texture is swizzled, crop each row from `buffer_width` to visible `width`.
2. Flip rows vertically.
3. Convert indices to RGBA palette colors.

Do not apply the newer Modelulator half-page crop for HP2 legacy texture packs. That was the source of the visible color-band artifacts.

## Alpha And Material Classification

Texture decode and material classification are separate steps.

The PNG may contain alpha values, but the material mode should not be inferred from PNG alpha alone. Use TPK metadata, especially:

```text
0x4F  is_any_semitransparency
0x76  alpha_bits
0x77  alpha_fix
```

Current Python material classification:

```text
1. Decode RGBA.
2. If all alpha values are effectively opaque, material is opaque.
3. If only transparent/cutout alpha values exist, material is MASK.
4. If intermediate alpha exists and is_any_semitransparency is nonzero, material is BLEND.
5. If intermediate/high alpha exists but is_any_semitransparency is zero, treat high alpha as opaque:
   - if alpha 0 is present, use MASK
   - otherwise use opaque
```

This avoids treating road and terrain cutout/transition textures as glass.

## Road Edge Alpha

Some road and shoulder textures have alpha around their edge.

This does not always mean the material should be transparent blend. In HP2 PS2, many road-edge and shoulder textures are composited with base terrain or another road layer.

If the Godot loader renders those textures with normal alpha blending and there is no base surface underneath, the road edge will show sky/background through it.

Correct policy:

```text
is_any_semitransparency == 0 and edge alpha exists:
    use alpha scissor / alpha test / MASK
    keep depth write behavior like opaque/cutout geometry

is_any_semitransparency != 0:
    use true alpha blend only when the texture is genuinely semitransparent
```

Typical cutout/road/terrain textures should not be sorted as transparent glass.

## Godot Material Policy

Recommended Godot mapping:

```text
opaque:
    transparency = disabled
    depth draw = opaque

MASK:
    transparency = alpha scissor
    alpha_scissor_threshold around 0.5
    depth draw = opaque/cutout depth writing

BLEND:
    transparency = alpha blend
    use only for true semitransparent textures
```

Large environment surfaces need special handling:

```text
WATER:
    true blend may be needed
    avoid double-sided transparent rendering unless intentionally required

SKYDOME:
    do not render together with SKYDOME_ENVMAP as normal transparent props

SKYDOME_ENVMAP:
    treat as environment/reflection source data, not a generic visible prop
```

Rendering both `SKYDOME` and `SKYDOME_ENVMAP` as transparent/double-sided meshes can cause depth flicker and striped alpha artifacts.

Use unlit/unshaded materials where possible. HP2 track assets already carry baked texture and vertex-lighting color. If the mesh has vertex colors, multiply vertex color into the material output.

## Validation Checklist

For another loader implementation, validate with `TEX64LOCATION.BIN` and `TRACKB64`.

Texture decode:

```text
SH_CLIFF2SANDBLEND  should be a smooth sand/cliff blend, no diagonal color bands
SHLD_G              should be a road shoulder/grass transition, no repeated stripe bands
D_TERRAINGRASS      should look like noisy terrain grass, no tiled color corruption
SH_BEACHSAND2OCEAN  should show beach/ocean transition, no artificial banding
ROAD06              should decode through the 8-bit indexed path
```

Material behavior:

```text
road/shoulder alpha edges do not show blue sky/background unless the base layer is intentionally missing
road/terrain alpha textures are not treated as normal transparent glass
water blends without heavy depth flicker
SKYDOME_ENVMAP is not rendered as a normal duplicate sky prop
vertex colors are visible on exported/imported meshes
```

Python regression test reference:

```text
tests/test_comp.py::TextureTests::test_fixture_swizzled_track_texture_uses_legacy_ps2_layout
```

Run:

```bash
PYTHONPATH=src python3 -m unittest tests.test_comp
```

## Common Mistakes

Avoid these:

```text
Using PNG alpha alone to choose BLEND mode.
Using simple linear row decode for swizzled textures.
Using the newer non-legacy Modelulator half-page crop for HP2 PS2 legacy textures.
Rendering road/shoulder cutout materials as transparent sorted glass.
Rendering both SKYDOME and SKYDOME_ENVMAP as normal visible transparent props.
Ignoring vertex colors in the final material.
```

