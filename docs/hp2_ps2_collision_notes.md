# HP2 PS2 Collision and Drive-Area Notes

These notes summarize the current reverse-engineering state for track collision, route boundaries, and the related PS2 data chunks. They are meant as handoff context for another agent continuing the work.

## High-Level Model

HP2 PS2 uses at least three related systems:

- Render/solid meshes under `0x80034000` / `0x80034002`, with VIF vertex data and strip metadata. These are useful for fallback road/terrain physics, but they are not the authoritative `IsDriveable` collision source.
- Track polygon collision records in chunk `0x00034132`. Ghidra shows these are decoded into `TrackPolygonCollisionBody` objects and used by the collision system.
- Track route records in chunk `0x00034121`. These drive route traversal, route-edge transitions, and side-boundary logic. They are not the `IsDriveable` collision area.
- Track route-edge records in chunk `0x00034122`. Route point `+0x2c` low byte indexes this 12-byte record table.
- Allowed-road/zone polygons in chunk `0x00034530`. These are authored flat 2D polygons, but current evidence shows they are broad areas/zones, not the actual driveable boundary. Drawing them as DriveArea boundaries produces large boxes across the map.

The current Godot implementation builds player Road collision from primary `0x00034132` track collision polygons when that chunk is present, and uses render polygons only as a fallback. Wall/scenery collision still comes from coarse `CS_` templates. The blue `DriveArea` debug overlay uses `0x00034132` polygon boundaries, but it is debug-only and should not become player physics.

## Ghidra Anchors

Loaded ELF: `SLUS_203.62`.

Useful decompiled functions:

- `0x001cbb70`: route traversal/search. It walks route points using 0x70-byte point records starting at route segment `+0x428`.
- `0x001c14f8`: resolves a route-edge record from route point byte `point + 0x2c`: `edge_table + point[0x2c] * 0xc`.
- `0x001c0ff8`: resolves route segment pointer from route-edge byte 0.
- `0x001c1020`: resolves target route point: `route_segment + ushort(edge + 2) * 0x70 + 0x428`.
- `0x00244588`: advances across a route edge and computes lateral boundary distance. It reads `*(short *)(point + side * 2 + 0x30)` and scales it by `1 / 256`.
- `0x001c1408`: projects a route-local point into world space. It uses route point position plus lateral offset along `(forward_y, -forward_x)` and forward distance along `(forward_x, forward_y)`.
- `0x0024dd58`: builds route-edge lookup structures from route table entries `0..0x30` and their packed edge flags.
- `0x001d8768`: `TrackPolygonCollisionBody::TrackPolygonCollisionBody()` constructor path, uses `TrackPolygon%d`.
- `0x001514a8`: decodes a packed 0x20-byte track polygon record into vertices, bounds, vertex count, normal, and plane distance.
- `0x001d7aa0`: creates `TrackPolygonCollisionBody` objects for track polygons overlapping a query/body AABB.
- `0x00151d30`: gathers nearby track polygons for a 2D movement/height query, then groups them by collision flags. Primary ground candidates have neither `0x02` nor `0x08` set.
- `0x00152070`: selects the active track polygon under a position and returns height/material/normal data from the decoded track polygon cache.
- `0x00245b00` / `0x00245ba0`: collision query wrappers used by drive-target style checks. They prepare a `0x114e0` query object, call the collision world query, and use callbacks at `0x245af8` / `0x245b98`; those callbacks clear the result flag on any hit.
- `0x00245ca8`, `0x00245c40`, `0x00245a98` / `0x00245a40`: related collision query wrappers using query modes `3`, `7`, and `5/7`. Their tiny callbacks also clear result flag `context + 0x08` on an accepted hit.
- `0x00246b10`: state-machine branch that emits event/string id `0x24ddc`, builds a fresh `0x114e0` query buffer through `0x00245738`, then calls `0x00245b00`.
- `0x00247378`: sibling branch that emits event/string id `0x24dd9`, clears a caller-provided `0x114e0` buffer through `0x00245700`, then calls `0x00245ba0`.
- `0x00246138` and `0x00246c00`: two DrivingChoice-style state machines. They call the query wrappers above based on current state, car state at `car + 0x124`, collision buffer state, and timed transitions.
- `0x0021ba50`: serializes/deserializes `DriveTarget`. Observed fields include target count at `+0x00`, per-target vectors starting at `+0x10`, per-target floats at `+0x150`, per-target s16 values at `+0x1b4`, per-target byte flags at `+0x1a0` and `+0x1dc`, and scalar state at `+0x1f0..+0x204`.

Important distinction: the route functions above explain route continuity and target placement, but `DrivingChoice::IsDriveable()` must be modeled as a drive-target collision query against collision bodies, not as a route/navmesh containment test.

## `0x00034132` Track Polygon Collision Chunk

This chunk is a flat list of 0x20-byte records. `0x001514a8` decodes each record like this:

```text
record + 0x01  u8  packed min/max vertex selectors for cached bounds
record + 0x02  u8  material / surface id, copied to decoded polygon +0x0b
record + 0x03  u8  flags, copied to decoded polygon +0x0a
record + 0x04  s16 z_base
record + 0x06  s16 runtime decoded-polygon cache index
record + 0x08  s16 x[4], scaled by /8
record + 0x10  s16 y[4], scaled by /8
record + 0x18  s16 z_offset[4], scaled by /256 and added to z_base
```

Flags observed in Ghidra:

- `flags & 0x10`: polygon has 4 vertices. Otherwise it has 3.
- `flags & 0x04`: decoded z coordinates are multiplied by 4.
- `flags & 0x02` and `flags & 0x08`: used by collision-result grouping in `0x00151d30`. The first/primary group is polygons where both bits are clear; the current Godot `DriveArea` overlay uses only this primary group, because including the secondary groups draws non-driveable collision polygons at bridge/wall/auxiliary heights.

Decoded PS2 vertex:

```text
x = s16(record + 0x08 + i * 2) / 8
y = s16(record + 0x10 + i * 2) / 8
z = s16(record + 0x04) + s16(record + 0x18 + i * 2) / 256
if flags & 0x04: z *= 4
```

Godot conversion uses the existing `ps2_to_godot_vec3`: `(x, z, -y)`.

## `0x00034121` Track Route Chunk

Observed route segment layout:

```text
segment + 0x0a  s16 route_index
segment + 0x0c  u32 route_type
segment + 0x10  u32 point_count
segment + 0x18  u32 flags
segment + 0x428 route points begin
```

Each route point is `0x70` bytes:

```text
point + 0x00  f32 x
point + 0x04  f32 y
point + 0x08  f32 z
point + 0x0c  f32 forward_x
point + 0x10  f32 forward_y
point + 0x14  f32 segment_length
point + 0x18  f32 left_width      (route corridor side width used by current Godot debug boundary)
point + 0x1c  f32 right_width     (route corridor side width used by current Godot debug boundary)
point + 0x2c  u32 route_edge_flags
point + 0x30  s16 boundary_offset[0], scaled by /256 at runtime
point + 0x32  s16 boundary_offset[1], scaled by /256 at runtime
point + 0x34  s16 boundary_offset[2], scaled by /256 at runtime
point + 0x36  s16 boundary_offset[3], scaled by /256 at runtime
```

The low byte at `+0x2c` is used directly as an index into the `0x00034122` route-edge table. Other bitfields are used by traversal/building code; known masks from decompilation include `0x700`, bit 11, bit 14, `0x3f00`, and `0xfc00000`.

## `0x00034122` Track Route-Edge Chunk

This chunk is a flat list of 12-byte edge records:

```text
edge + 0x00  u8  target_route_index
edge + 0x01  u8  mode / route-edge type
edge + 0x02  u16 target_point_index
edge + 0x04  u32 metadata0
edge + 0x08  u32 metadata1
```

Ghidra confirms this mapping:

- `0x001c14f8`: `edge_table + point[0x2c] * 0xc`
- `0x001c0ff8`: target route pointer from `edge[0]`
- `0x001c1020`: target point from `ushort(edge + 2)`

Current interpretation:

- For route visualization only, `left_width` and `right_width` from `+0x18/+0x1c` form a continuous corridor.
- Only route indexes `0..0x30` should feed route-boundary visualization. This matches `0x0024dd58` and avoids drawing higher-index route records as separate lane corridors.
- Shortcut/main-route joins should be merged for route visualization, but this is still not the authoritative `IsDriveable` collision area.
- For route-edge transition logic, use `boundary_offset[side]` from `+0x30 + side * 2`, scaled by `/256`, matching `0x00244588`.
- Do not use `0x34530` polygons as the blue DriveArea boundary. The screenshot with huge blue boxes is the expected failure mode from that incorrect interpretation.

## `0x00034530` Zone / Allowed-Road Areas

This chunk is a flat list of fixed-size polygon records:

```text
chunk + 0x00  u32 area_count
then area_count records of 0x3c bytes:
  +0x00  u32 vertex_count, normally 3..6
  +0x04  Vector2 vertices[6], f32 x/y pairs
  +0x34  u32 metadata0
  +0x38  u32 metadata1
```

Important correction: the trailing metadata is 8 bytes, not 24. Consuming 24 bytes desynchronizes the parser after the first polygon.

Second correction: despite the name previously used in the Godot parser, this chunk should not currently be treated as the driveable boundary. Its polygons are too coarse and can span large off-road map regions. Keep parsing it for future comparison/metadata, but do not feed it into DriveArea boundary collision or the DriveArea debug overlay.

## Current Godot Handling

Relevant files:

- `eagl/assets/track/track_parser_ps2.gd`
- `eagl/assets/track/track_asset.gd`
- `eagl/handling/road_surface_sampler.gd`
- `eagl/rendering/track_collision_builder.gd`
- `eagl/rendering/track_route_builder.gd`

Current behavior after the latest fix:

- Parses `0x34530` records as fixed `0x3c` structures.
- Stores authored allowed-road polygons as `asset.allowed_road_areas`.
- Parses `0x34121` route point `left_width`, `right_width`, `route_edge_flags`, and `boundary_offsets`.
- Parses `0x34122` route-edge records as `asset.track_route_edges`.
- Parses `0x34132` track collision polygon records as `asset.track_collision_polygons`.
- Builds player Road physics from primary decoded `0x34132` collision polygons, filtered with `(flags & 0x0a) == 0` and the same upward-surface validation used by `RoadSurfaceSampler`.
- Builds DriveArea debug lines from the outer boundary of those primary decoded `0x34132` collision polygons.
- DriveArea debug boundary extraction counts original polygon perimeter edges in projected Godot X/Z space, splits collinear partial overlaps, and removes edge segments covered by another primary drivable polygon. Do not count full 3D triangle edges here: neighboring road polygons can share the same X/Z edge while carrying slightly different heights, and forks can have T-junction coverage that otherwise leaves false internal blue lines across the road.
- `RoadSurfaceSampler.build_from_track_asset()` now also prefers those primary `0x34132` polygons for road-height sampling, falling back to render mesh only if the collision chunk is missing.
- Falls back to render-polygon boundary edges, then route-corridor visualization, only if `0x34132` collision polygons are missing.
- Parses route point `route_edge_flags` and `boundary_offsets`, but does not use them as the `IsDriveable` collision area.

TRACKB31 validation after the primary `0x34132` filter:

- Primary polygons included: `13274`
- Secondary/auxiliary polygons excluded by `flags & 0x0a`: `2614`
- Nearest render-road/terrain height delta over sampled collision vertices: min `-10.3267`, p05 `-0.0043`, median `-0.0020`, p95 `~0`, max `1.1285`
- `RoadSurfaceSampler` built `19312` triangles from primary collision polygons and returned a valid material/height/normal sample at a primary polygon centroid.
- Player Road physics also builds `19312` triangles from `track_polygon_collision_area`; render `track_polygon_surface` is not used for Road physics when `0x34132` exists.
- Projected DriveArea boundary line count after the internal-seam/fork-coverage fix: `2161` lines for TRACKB31.

Remaining gap:

The implementation still does not fully reproduce the AI `DrivingChoice::IsDriveable()` / DriveTarget path. That path appears to be a drive-target collision query:

1. Build the `DriveTarget` / OBB query volume.
2. Query the collision world against track polygon and dynamic collision bodies.
3. Treat any accepted hit callback as not driveable.

The decoded `0x34132` polygons are now the static track collision geometry for this investigation, but the Godot gameplay code still needs a faithful DriveTarget OBB query to match the original `IsDriveable()` behavior exactly.

Current DriveTarget query reconstruction:

1. A query context stores the target car/object pointer at `+0x00`, a result flag at `+0x08`, and sometimes a caller-owned query buffer pointer at `+0x10`.
2. Wrappers set `*(context + 0x08) = 1` before querying.
3. `0x00245738` initializes a fresh global query buffer by writing `DAT_002fc050 = 0x114e0` and calling `0x001878b0(&DAT_002fc050)`.
4. `0x00245700` zeroes an existing caller-owned `0x114e0` buffer with `memset(buffer, 0, 0x114e0)`.
5. `0x00245b00` and `0x00245ba0` call a virtual function at object-vtable `+0x2c` with type/key `0x2bebe0`, the query buffer, and size `0x114e0`. This is the current best anchor for the missing OBB/broadphase-body construction.
6. The wrappers then call a collision-world virtual at vtable `+0xb4` with a mode id (`1`, `2`, `3`, `5`, or `7`) and a callback.
7. The callback body is effectively `sw zero, 8(a0); jr ra`, so any accepted collision hit makes the wrapper return false/not-driveable.

## Player Car DriveArea Detection

For player car movement, do not use the AI DriveTarget / OBB path above as the primary DriveArea rule. The current Ghidra evidence points to point/surface queries against active track collision polygons:

- `0x00152070` is the active track-polygon surface query. It tests X/Y inside decoded `0x34132` polygons, computes height from the polygon plane, returns material id from decoded polygon `+0x0b`, returns the polygon normal from decoded polygon `+0x70`, and clears the caller hit flag when no polygon is found.
- `0x00151d30` gathers nearby decoded polygons and groups them by flags. The primary player-drivable group is `(flags & 0x02) == 0 && (flags & 0x08) == 0`, equivalent to the Godot filter `(flags & 0x0a) == 0`.
- `0x00120ef8` calls `0x00152070` repeatedly from the vehicle/player physics path, including multiple car/contact sample points and grid/support samples.
- `0x001209f8` rejects candidate player/vehicle points when `0x00152070` reports no surface hit. It also applies a height tolerance of about `4.0` and a lateral projection threshold around `1.5`.
- These player-side queries invalidate support/contact points and generated road/ground samples. They are not evidence for a horizontal hard wall, teleport clamp, or pinball-style velocity reflection at the DriveArea boundary.
- `0x001ebad8` is another cached segment/area lookup used by controller-style movement. It returns true on segment hit and can output height/material, but it is separate from the AI DriveTarget OBB wrapper.

Current Godot player DriveArea behavior:

- `RoadSurfaceSampler.build_from_track_asset()` builds from primary decoded `0x34132` polygons first, using `(flags & 0x0a) == 0`.
- `RoadSurfaceSampler.sample_surface()` is the local equivalent of the player-side `0x00152070` surface hit query. It now returns the surface **closest to the query Z** rather than the highest, matching the PS2 behavior where the vehicle's current height disambiguates between road levels.
- `RoadSurfaceSampler.has_driveable_surface()` adds a 4.0-unit height tolerance check (mirroring `FUN_001209f8`) so that bridge decks or tunnel floors more than 4 m from the query height are rejected. This prevents a bridge polygon above a road from being treated as driveable while the car is at road level.
- `EAGLSceneBuilder` stores the built sampler on `TrackRoot` metadata as `eagl_drive_area_sampler`.
- `scene/Gamelevel/gamelevel.gd` binds that sampler to the player car after track load.
- `EAGLCar` does not use a horizontal hard DriveArea clamp. Each wheel samples the primary `0x34132` DriveArea under its current position; if that wheel has no DriveArea surface, engine force is removed for that wheel and wheel friction slip is reduced. The rigid body remains free to slide, scrape, and collide with real track/scenery physics.
- `HP2PhysicsController` follows the same direction for the planar controller: DriveArea misses scale the affected wheel normal load to zero instead of clamping the whole body position.

Validation on TRACKB31:

- `TrackRoot` metadata reports `eagl_drive_area_sampler_triangle_count = 19312`.
- Parser-only sampler probe reports a valid sample at a primary polygon centroid.
- Full scene-builder probe reports `sampler_exists=true`, `triangles=19312`, and `collision_tris=23656`.

## Ghidra Decompilation Verification (2026-05-02)

Decompiled against SLUS_203.62 (.text segment 0x00100000–0x002a5903).

Key confirmations from fresh decompilation:

- `FUN_00152070` (`0x00152070`): The active surface query matches the sampler design. Uses accumulating-minimum cross-product test on XY edges (`fVar9 ≤ 0.0` for each edge means inside), consistent with the Godot `_barycentric_xy` approach. Height computed as `plane_d − (nx·x + ny·y)`, which is an accurate approximation for near-horizontal polygons (nz ≈ 1). Caches last-hit polygon at `param_1[0xac]` for fast repeated calls; the Godot sampler skips this optimisation without loss of correctness.
- `FUN_00151d30` (`0x00151d30`): Primary driveable group confirmed as `(flags & 0x02) == 0 && (flags & 0x08) == 0`, secondary groups stored at `param_2[0xaa]` and `param_2[0xab]`. Godot filter `(flags & 0x0a) == 0` is equivalent. ✓
- `FUN_001514a8` (`0x001514a8`): XY decode `(s16 << 13) × (1/65536) = s16/8` confirmed ✓. Z decode `z_base + z_offset/256` with `×4` if `flags & 0x04` confirmed ✓.
- `FUN_001209f8` (`0x001209f8`): Calls `FUN_00152070` per candidate contact point and rejects if: no surface hit; `abs(surface_height − car_center_height) > 4.0`; lateral distance from road direction > 1.5. The 4.0-unit height tolerance is now enforced in `RoadSurfaceSampler.has_driveable_surface()`.
- `FUN_00120ef8` (`0x00120ef8`): Vehicle physics path. Calls `FUN_00152070` for car-centre height reference, calls `FUN_001209f8` to filter contact points. Uses multiple grid/support sample points around the car footprint, not just wheel positions.
