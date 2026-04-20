# HP2 PS2 Car Binary Structure And Rendering Notes

This document records the current understanding of Need for Speed: Hot Pursuit 2 PS2 car assets and the implementation decisions in `godot_eagl_ps2`.

It is written for future agents working on car loading, wheel pivots, runtime parts, textures, materials, or Godot rendering. The key lesson is that HP2 car data is split across per-car geometry, global runtime tables, global textures, and global material records. Do not treat `GEOMETRY.BIN` as a complete standalone model.

## Source Files

PS2 car files live under:

```text
/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA/CARS
```

Typical per-car layout:

```text
ZZDATA/CARS/<CAR_ID>/
  GEOMETRY.BIN or GEOMETRY.LZC
  DASHGEOM.BIN or DASHGEOM.LZC, optional cockpit/dashboard geometry
```

Shared files used by the current loader:

```text
ZZDATA/CARS/TEXTURES.BIN
ZZDATA/GLOBAL/GLOBALB.BUN or GLOBALB.LZC
```

The PC version is useful for naming and effect cross-checks:

```text
/Users/nurupo/Desktop/nfshp2/Cars/<pc_car>/geomdata.ini
/Users/nurupo/Desktop/nfshp2/Cars/<pc_car>/vehicle.ini
/Users/nurupo/Desktop/nfshp2/Cars/reflection.ini
```

PC geometry names such as `ALPHA_TRANS_WINShape~EASVehicleGlass` and vehicle fields such as `specular_glass_exponent=40.0` confirm that windows are transparent/specular glass, not body paint.

## Relevant Implementation Files

```text
godot_eagl_ps2/eagl/platforms/ps2/ps2_asset_resolver.gd
godot_eagl_ps2/eagl/assets/car/car_loader.gd
godot_eagl_ps2/eagl/assets/car/car_parser_ps2.gd
godot_eagl_ps2/eagl/assets/car/hp2_car_data.gd
godot_eagl_ps2/eagl/assets/texture/ps2_texture_bank.gd
godot_eagl_ps2/eagl/rendering/car_scene_builder.gd
godot_eagl_ps2/eagl/rendering/mesh_builder.gd
godot_eagl_ps2/eagl/rendering/material_builder.gd
godot_eagl_ps2/eagl/utils/math_utils.gd
godot_eagl_ps2/eagl/shader/hp2_car_opaque.gdshader
godot_eagl_ps2/eagl/shader/hp2_car_alpha.gdshader
godot_eagl_ps2/eagl/debug/validate_hp2_cars.gd
godot_eagl_ps2/eagl/debug/car_drive_debug.tscn
```

## High-Level Car Load Path

The resolver returns:

```text
geometry     -> CARS/<CAR_ID>/GEOMETRY.BIN or .LZC
dashboard    -> CARS/<CAR_ID>/DASHGEOM.BIN or .LZC, optional
texture_car  -> CARS/TEXTURES.BIN
globalb      -> GLOBAL/GLOBALB.BUN or .LZC
```

The texture bank for cars loads both:

```text
GLOBALB first
CARS/TEXTURES.BIN second
```

This is required because shared runtime textures are in `GLOBALB`, including:

```text
TIRE
TIREBACK
BRAKESFRONT
BRAKESREAR
```

## bChunk Structure

Car geometry files are bChunk containers. The mesh object structure reuses the same core layout as tracks:

```text
GEOMETRY.BIN or decompressed GEOMETRY.LZC
+-- bChunk tree
    +-- 0x00034013  car locator metadata records
    +-- 0x00034024  geometry metadata / wheel arch point cloud
    +-- 0x80034000  solid pack
        +-- 0x80034002  mesh object
            +-- 0x00034003  object header
            |   +-- ASCII object name
            |   +-- object name hash
            |   +-- 4x4 row-major transform
            +-- 0x00034004  strip-entry table
            +-- 0x00034005  VIF vertex data blob
            +-- 0x00034006  texture hash references
            +-- 0x0003401D  light/material hash references, when present
```

Each `0x00034004` record is `0x40` bytes and selects one VIF packet in `0x00034005`.

Known strip-entry fields:

```text
0x00  u32  texture index into object 0x00034006 hash table, or 0xFFFFFFFF
0x08  u32  byte offset into stripped VIF payload
0x0C  u32  low 16 bits: VIF qword count, high 16 bits: render flags
0x1C  u32  packed topology / vertex count / polygon count
0x1F  s8   light/material index into object 0x0003401D hash table
```

The current parser turns each strip-entry record into one render block.

## Coordinates And Transforms

Do not use the normal track coordinate transform for HP2 cars.

Track/world conversion:

```text
ps2_to_godot_vec3(v) = Vector3(v.x, v.z, -v.y)
```

HP2 car-local conversion:

```text
hp2_car_to_godot_vec3(v) = Vector3(v.y, v.z, -v.x)
```

This means:

```text
PS2 car X  -> Godot -Z, forward/back
PS2 car Y  -> Godot +X, left/right
PS2 car Z  -> Godot +Y, up
```

Object transforms are stored as matrix rows. Point transform is row-major:

```text
out.x = x*r0.x + y*r1.x + z*r2.x + r3.x
out.y = x*r0.y + y*r1.y + z*r2.y + r3.y
out.z = x*r0.z + y*r1.z + z*r2.z + r3.z
```

`MathUtils.hp2_car_rows_to_godot_transform()` converts object matrix rows into a Godot `Transform3D`.

Current policy:

```text
Most car object vertices are already in model-local car space.
Most source object transforms are ignored for visual mesh placement.
Wiper objects keep source transforms.
Runtime wheels/brakes are assembled separately under wheel-slot pivots.
```

The validation script contains a transform math smoke test. Keep it passing when editing this area.

## Runtime Wheel Pivots

The best wheel slot source is not the visible mesh and not the apparent dummy points. It is a runtime car table in `GLOBALB.BUN`.

Recovered via Ghidra:

```text
Function:      FUN_0011e860
Table symbol:  uGpffffaf78
Init function: FUN_00187f98
Chunk:         GLOBAL/GLOBALB.BUN 0x00034600
Row stride:    0x560
Car name:      row + 0x20, ASCII
```

The row contains four wheel vectors. Each vector is:

```text
float x
float y
float z
float radius
```

Known offsets inside the `0x560` row:

```text
0x120  FL
0x140  FR
0x160  RR
0x180  RL
```

The parser currently emits slots in `FL, FR, RL, RR` order and converts positions with:

```text
position_godot = Vector3(ps2.y, ps2.z, -ps2.x)
```

The average `wheel_radius` from these vectors is copied into handling data when available.

### Fallback Wheel Sources

Fallbacks exist for cars or files where `GLOBALB` lookup fails:

1. `0x00034024` wheel arch metadata.
2. `0x00034013` runtime tire dummy locator hashes.
3. Generic locator inference.
4. Geometry bounds fallback.

The source priority is intentional. Use the runtime `GLOBALB` vectors whenever present.

Known `0x00034013` locator hashes:

```text
0xACEC665C  TIRE_FRONT_LEFT
0x4AE7F96F  TIRE_FRONT_RIGHT
0x7EFCF06F  TIRE_REAR_LEFT
0x5F09C5E2  TIRE_REAR_RIGHT
0xBEA9AEE6  TIRE_REAR_LEFT_AUX
0x944E5339  TIRE_REAR_RIGHT_AUX
```

The dummy points are useful for validation and debugging, but screenshots showed they can appear slightly below/offset relative to the body. The runtime table positions match the game control path better.

## Runtime Wheel And Brake Mesh Assembly

Do not render all tire/brake variants directly in the body group.

Current naming patterns:

```text
<CAR_ID>_TIRE_FRONT_A
<CAR_ID>_TIRE_FRONT_B
<CAR_ID>_TIRE_FRONT_C
<CAR_ID>_TIRE_REAR_A
<CAR_ID>_TIRE_REAR_B
<CAR_ID>_TIRE_REAR_C
<CAR_ID>_BRAKE_FRONT
<CAR_ID>_BRAKE_REAR
<CAR_ID>_WHEEL_BLUR_F
<CAR_ID>_WHEEL_BLUR_R
```

Default render behavior:

```text
Primary tire meshes are instanced under four WheelSlot nodes.
Brake meshes are instanced under four BrakeSlot nodes.
Wheel blur meshes are hidden unless debug option show_wheel_blur is enabled.
Alternate tire variants are hidden by default.
```

Scene hierarchy:

```text
Visual/Wheels/WheelSlot_FL
  SteerPivot
    SpinPivot
      Mesh

Visual/Brakes/BrakeSlot_FL
  SteerPivot
    Mesh
```

The controller updates:

```text
front wheel steer: SteerPivot rotation
wheel spin:        SpinPivot rotation.x
```

## Texture Hashes And Aliases

HP2 uses a simple uppercase name hash:

```text
hash = 0xFFFFFFFF
for char in name:
    hash = (hash * 0x21 + ord(char)) & 0xFFFFFFFF
```

Important aliases:

```text
TIRE        -> <CAR_ID>_TIRE, when car-specific tire texture exists
BRAKE       -> BRAKESFRONT
BRAKE_FRONT -> BRAKESFRONT
BRAKE_REAR  -> BRAKESREAR
```

`GLOBALB` textures are required for generic/shared runtime parts. If wheels or brakes are black/missing, first verify that the car texture bank loaded `GLOBALB` in addition to `CARS/TEXTURES.BIN`.

## Window And Glass Surfaces

Important trap: PS2 windows are often block-level surfaces inside a body object, not separate objects named `GLASS`.

For example, McLaren windows are blocks inside `MCLAREN_A`, with missing texture hashes that are actually HP2 window name hashes:

```text
0x7B220DDF  WINDOW_FRONT
0xE7E4EF49  WINDOW_LEFT_FRONT
0x60F8B13C  WINDOW_RIGHT_FRONT
0x0AB88F5D  WINDOW_RIGHT_REAR
0x4CDEBFCA  WINDOW_LEFT_REAR
0x1B0763A0  WINDOW_REAR
```

These hashes may not resolve to actual decoded textures. If treated as normal fallback surfaces, they inherit body fallback color and turn red. Correct behavior is:

```text
detect glass by texture hash
force material role hp2_car_glass
use alpha shader / BLEND path
disable vertex color modulation
apply blue-gray transparent tint
keep strong specular and Fresnel reflection
```

This matches PC data where glass nodes are named like:

```text
ALPHA_TRANS_WINShape~EASVehicleGlass
ALPHA_TRANS_DWShape~EASVehicleGlass
ALPHA_TRANS_PWShape~EASVehicleGlass
```

PC `vehicle.ini` commonly contains:

```text
specular_glass_exponent=40.0
```

So glass should be transparent and reflective, not opaque body-colored paint.

## Global Material Library

`GLOBALB.BUN` chunk `0x0003401E` is parsed as a global material library.

Current record layout:

```text
payload + 0x14  u32  material count
payload + 0x18       first record
record size          0x140

record + 0x08  u32          material hash
record + 0x0C  char[0x20]   material name, null terminated
record + 0x20  float[16]    material values
```

Current material interpretation in `material_builder.gd`:

```text
values[4..6]    diffuse color
values[7]       reflection/specular floor
values[8..10]   specular color
values[11]      reflection strength
values[12]      specular exponent
values[13]      Fresnel scaler
```

Fallback named material records:

```text
Rubber       tires
Brakes       brake discs
Interior     dashboard/cockpit
Window911B   preferred glass fallback
Window911    secondary glass fallback
Refheadlight lights
Mirror       mirrors
Default      body/general fallback
```

The material hash used by a render block comes from its `0x0003401D` light/material table and strip-entry material index.

## Shaders

Car-specific shaders live in:

```text
res://eagl/shader/hp2_car_opaque.gdshader
res://eagl/shader/hp2_car_alpha.gdshader
```

They implement a practical approximation of HP2 car material behavior:

```text
base texture or fallback tint
optional PS2 vertex color modulation
ambient/fill lighting floor
directional sun response
Fresnel reflection
clearcoat/specular highlight
reflection banding
distance fade support
```

Body paint needs clearcoat and directional glint. Glass needs alpha blending plus strong specular/Fresnel. Tires, brakes, and interior should remain much more matte.

The debug scene includes:

```text
WorldEnvironment
DirectionalLight3D named Sun
OmniLight3D named FillLight
```

Do not switch car shaders back to fully unshaded to compensate for a dark test scene. Fix the debug lighting or shader profile instead.

## Render Flags And Alpha

Known observed render flags:

```text
0xC180  common on McLaren window blocks
0x4180  common textured/lit body detail blocks
0x4080  common body detail blocks
0x5080  common body skin blocks
0x4041  track/road alpha edge case
```

Texture alpha is still primarily decoded from the texture pack. The material builder has additional HP2 car overrides because window surfaces can be hash-only glass without a decoded texture.

## Validation

Primary validation command:

```text
/Applications/Godot.app/Contents/MacOS/Godot --headless --path /Users/nurupo/Desktop/dev/eagl-godot/godot_eagl_ps2 --script res://eagl/debug/validate_hp2_cars.gd
```

Debug scene load smoke test:

```text
/Applications/Godot.app/Contents/MacOS/Godot --headless --path /Users/nurupo/Desktop/dev/eagl-godot/godot_eagl_ps2 --scene res://eagl/debug/car_drive_debug.tscn --quit-after 1
```

Expected headless behavior: Godot may print dummy-renderer RID/ObjectDB leak warnings on exit. Treat exit code `0` and validation output as the signal unless there is an actual parse/shader error before shutdown.

Validation currently checks:

```text
car assets load with nonzero objects/blocks/vertices/texture refs
runtime wheel slots exist
wheel/brake hierarchy is assembled
wheel/brake textures resolve to expected shared names
HP2 car shaders are assigned
car transform math remains correct
wheel blur is hidden by default
controller can cache wheel pivots and update wheel visuals
```

## Efficient Binary Inspection

For quick hash checks, Python is faster than creating temporary Godot scripts:

```python
def hp2_name_hash(name: str) -> int:
    out = 0xFFFFFFFF
    for ch in name:
        out = (out * 0x21 + ord(ch)) & 0xFFFFFFFF
    return out

for name in [
    "WINDOW_FRONT",
    "WINDOW_LEFT_FRONT",
    "WINDOW_RIGHT_FRONT",
    "WINDOW_RIGHT_REAR",
    "WINDOW_LEFT_REAR",
    "WINDOW_REAR",
]:
    print(f"{name} {hp2_name_hash(name):08X}")
```

For deeper dumps, parse bChunk headers and specific payloads in Python first, then port stable findings back into GDScript. Avoid adding long-lived debug scripts unless the data needs to be part of regression validation.

## Current Open Areas

These facts are still partial or approximate:

```text
Exact physics/handling constants are still estimated.
Full semantic meaning of all 16 GLOBALB material floats is not confirmed.
Some render flags are observed but not fully decoded.
Some light/material table entries need more Ghidra/PC cross-reference.
Damage variant behavior is only partially represented.
Wheel blur rendering is hidden by default and not final.
```

When changing any of these areas, record the binary offset, source function, and validation evidence in this document or a linked follow-up doc.
