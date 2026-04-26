# HP2 PS2 Car UV Overlay Tool

Standalone Python extractor for Need for Speed: Hot Pursuit 2 PS2 car wheel textures and UV overlays.

The tool does not depend on Godot or Pillow. It uses only the Python standard library and writes PNGs directly.

## Usage

```bash
python3 hp2_car_uv_overlay.py \
  --root /Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA \
  --car CORVETTE \
  --out out \
  --scale 6 \
  --dump-binary
```

Outputs:

- `out/<CAR>/textures/*.png`: decoded vehicle textures used by selected objects
- `out/<CAR>/overlays/*_uv_overlay.png`: UV lines over decoded textures
- `out/<CAR>/overlays/missing_*_on_*png`: diagnostic overlays for unresolved material IDs projected onto the tyre texture
- `out/<CAR>/summary.json`: block-level source hashes, strip texture dimensions, UV bounds, and output paths
- `out/<CAR>/wheel_uv_binary_dump.json`: raw strip/VIF dump paths, VIF UV unpack events, decoded UV samples, Modelulator-style strip masks, and validation flags
- `out/<CAR>/binary_dump/*.bin`: original 0x40-byte strip records and VIF payload slices for each wheel block

By default it processes objects whose names contain `_TIRE_`.
It also loads `GLOBAL/GLOBALB.BUN` as a fallback texture pack for shared wheel textures such as `TIRE` and `TIREBACK`. Use `--no-global-textures` to reproduce car-only lookup diagnostics.

```bash
python3 hp2_car_uv_overlay.py --car MCLAREN --object-filter _TIRE_
```

Known shared wheel texture hashes:

- `0x001d38b3`: `TIRE` in `GLOBAL/GLOBALB.BUN`
- `0xc8c5a8a4`: `TIREBACK` in `GLOBAL/GLOBALB.BUN`

If global textures are disabled or unavailable, these are emitted as missing material diagnostic overlays so their UVs can still be inspected.

## Validation Notes

Ghidra shows the game validates strip texture dimensions before rendering. `FUN_0010c158` walks 0x40-byte strip records, resolves the texture through the material table, compares the strip dimensions at `+0x04/+0x06` to the actual texture dimensions normalized to a power-of-two extent, then reads/writes U/V through `FUN_0011c268` and `FUN_0011c398` only when scaling is needed.

The `--dump-binary` report mirrors that path. For correctly resolved tyre blocks, `runtime_uv_scale` should be `[1.0, 1.0]` and `strip_dimensions_match_texture` should be true.

The PS2 strip mask matches Modelulator's `src/util/xSolid/PSX2.lua` handling: a mask bit of `1` skips that strip vertex and resets winding; a mask bit of `0` emits a triangle candidate. Each dumped block includes `strip_mask.mask_hex`, `strip_mask.mask_bits_for_vertices`, and the disabled/enabled vertex indices used by the overlay renderer.
