# HP2 PS2 Suspension Reverse Notes

This note summarizes the suspension model recovered from the original PS2 executable with Ghidra MCP.

## Main conclusion

The original NFS HP2 PS2 suspension does **not** look like a classic downward raycast-per-wheel system.

Instead, each wheel appears to:

1. build a wheel sample point in world space
2. query the road surface under that point
3. recover ground height, surface normal, and material/type
4. add wheel radius
5. clamp travel against suspension limits
6. compute spring/damper force from travel and travel velocity

The terrain query is done by `FUN_00152070 @ 0x00152070`, which searches nearby road polygons/cells using wheel `x/y`, checks 2D polygon inclusion, and solves the polygon plane equation to recover surface `z`. That is a road-surface sampling approach, not a generic physics raycast.

## Key functions

- `HP2_PhysicsCar_MoveUpdate_FUN_00137d90 @ 0x00137d90`
  - main per-frame physics update
  - runs the car in substeps
  - updates four wheel-side runtime objects
- `FUN_001375f0 @ 0x001375f0`
  - distributes load / bias into the four wheel objects
- `FUN_001a5fc0 @ 0x001a5fc0`
  - core per-wheel suspension/contact update
- `FUN_001a4580 -> FUN_001a45a8 -> FUN_00152070`
  - per-wheel ground lookup path

## `FUN_001a5fc0` wheel runtime field map

High-confidence fields for the wheel/contact object created by `FUN_001a5ea0`:

- `+0x0c`: pointer to axle suspension tuning block
- `+0x14`: current clamped suspension length / travel sample
- `+0x18`: suspension velocity
- `+0x1c`: suspension force
- `+0x20`: cached local suspension/contact vector
- `+0x28`: accumulated suspension length over substeps
- `+0x30..+0x60`: transformed suspension/contact basis matrices
- `+0x70`: grounded/contact flag
- `+0x78`: preload / load-share term injected from chassis load distribution
- `+0x80`: local anchor / suspension-direction input vector
- `+0x90`: pointer to linked wheel helper object
- `+0x94`: pointer to chassis/body transform object
- `+0x98`: optional linked peer object
- `+0x9c`: wheel index

Medium-confidence:

- `+0x10`: pointer to auxiliary suspension reference data; its `+0x14` is used as a baseline/reference length inside the force formula

## Suspension tuning block layout

The suspension code reads from a per-axle tuning block:

- front axle block: `GLOBALB row + 0x230`
- rear axle block: `GLOBALB row + 0x250`

Current inferred layout from direct usage in `FUN_001a5fc0`:

- `+0x00`: progressive spring scale term
- `+0x04`: base spring coefficient
- `+0x08`: rebound damping coefficient
- `+0x0c`: bump/compression damping coefficient
- `+0x10`: extra bump-stop / overtravel coefficient
- `+0x14`: upper suspension travel limit
- `+0x18`: lower suspension travel / contact-loss limit

These names are still inferred from usage. The offsets are firmer than the final public labels.

## Wheel record inputs used by suspension

Wheel records come from:

- `GLOBALB row + 0x120`
- `GLOBALB row + 0x140`
- `GLOBALB row + 0x160`
- `GLOBALB row + 0x180`

Within each wheel record:

- `+0x00/+0x04/+0x08`: wheel position vector
- `+0x0c`: wheel radius

The suspension update adds this radius after the terrain height query before travel clamping.

## Practical summary

The original HP2 suspension is best described as:

- four independent wheel samplers
- per-wheel road-polygon height/normal query
- wheel-radius-adjusted compression
- spring-damper suspension force with preload and overtravel handling

It is not best described as a generic raycast suspension.
