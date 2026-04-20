# HP2 PS2 PhysicsCar Reverse Notes

Ghidra strings in `SLUS_203.62` identify the relevant runtime systems:

- `Car::Move()`
- `PhysicsCar::Move()`
- `PhysicsCar::ResolveForces()`
- `Car::SetMovementMode()`
- `Car::TriggerCarTerrainEffects()`

The v1 controller intentionally uses a custom Godot node rather than `VehicleBody3D` so these routines can be mirrored as they are recovered. The current tuning values are marked `estimated` in metadata. They are organized around the same broad update order implied by the executable strings: input/movement mode, force resolution, integration, terrain effects, and render-part updates.

## Car Assembly Notes

`FUN_0011e860` builds the playable car render assembly. The loader formats and hashes body damage variants with `%s_%c` / `%s_%c%d`, but tires and brakes are handled as runtime-attached parts:

- Six tire solids are requested by name: `%s_TIRE_FRONT_A`, `%s_TIRE_FRONT_B`, `%s_TIRE_FRONT_C`, `%s_TIRE_REAR_A`, `%s_TIRE_REAR_B`, and `%s_TIRE_REAR_C`.
- Two brake solids are requested by name: `%s_BRAKE_FRONT` and `%s_BRAKE_REAR`.
- Tire and brake solids are attached through slot calls near the same routine instead of being rendered once at their authored origin.
- The executable also names cullable runtime parts `CULLABLE_CAR_PART_TIRE_FL`, `CULLABLE_CAR_PART_TIRE_FR`, `CULLABLE_CAR_PART_TIRE_RR`, `CULLABLE_CAR_PART_TIRE_RL`, and matching brake FL/FR/RR/RL entries.
- Headlight and brake-light solids are resolved separately by `FUN_00188790` using names such as `%s_HEADLIGHT_LEFT`, `%s_HEADLIGHT_RIGHT`, `%s_BRAKELIGHT_LEFT`, `%s_BRAKELIGHT_RIGHT`, `%s_HEADLIGHT_ON`, and `%s_BRAKELIGHT_ON`.

The Godot v1 loader mirrors that assembly at a high level: front/rear tire and brake meshes are instanced to four wheel locator slots inferred from `0x00034013`; alternate tire LODs/blurs and cockpit/view variants are hidden by default.

Fields that still need exact recovery:

- Original longitudinal acceleration and drag constants.
- Original lateral grip/slip curve.
- Original yaw response and damping.
- Per-car handling table source, if one exists outside the visible `CARS/*/GEOMETRY.BIN` chunks.
- Exact meaning of `0x00034013` car metadata rows; v1 exposes them as 0x20-byte estimated locator records.
