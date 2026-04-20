# HP2 PS2 PhysicsCar Reverse Notes

Ghidra strings in `SLUS_203.62` identify the relevant runtime systems:

- `Car::Move()`
- `PhysicsCar::Move()`
- `PhysicsCar::ResolveForces()`
- `Car::SetMovementMode()`
- `Car::TriggerCarTerrainEffects()`
- `EngineSlotPool`
- `DriveTrainSlotPool`
- `DriveTrain`
- `World::DoTimestep - FakeEngineTask`

The v1 controller intentionally uses a custom Godot node rather than `VehicleBody3D` so these routines can be mirrored as they are recovered. The current tuning values are marked `estimated` in metadata. They are organized around the same broad update order implied by the executable strings: input/movement mode, force resolution, integration, terrain effects, and render-part updates.

## Car Assembly Notes

`HP2_CarRenderPhysicsAttachmentSetup_FUN_0011e860` builds the playable car render assembly. The loader formats and hashes body damage variants with `%s_%c` / `%s_%c%d`, but tires and brakes are handled as runtime-attached parts:

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

## GLOBALB 0x00034600 Handling Row

The current parser decodes each car row from `GLOBAL/GLOBALB.BUN` chunk `0x00034600` with stride `0x560`. The layout pieces verified from `HP2_CarRenderPhysicsAttachmentSetup_FUN_0011e860` are:

- row name at `row + 0x20`;
- wheel vectors/radii at `row + 0x120`, `0x140`, `0x160`, and `0x180`;
- vehicle type at `row + 0x538`, used by the assembly path for variant selection.

Other finite float clusters are exported as inferred/unknown row fields, not exact names. The default Godot controller now consumes these decoded values through a custom four-wheel pipeline, but each promoted value keeps source offset and confidence metadata so future Ghidra passes can tighten or rename fields without losing provenance.

The drivetrain cluster at `0x288..0x2ac` has now been decoded from sample rows and executable reads as a gear table shape:

- `0x288`: forward gear count, stored as an integer. `HP2_BuildAccelerationOrShiftCurve_FUN_00188df0` reads `*(int *)(row + 0x288)` for the gear loop bound;
- `0x28c`: drivetrain scalar/final-drive-like ratio, commonly `4.0` in tested rows;
- `0x290`: reverse gear ratio;
- `0x294`: neutral ratio, usually `0`;
- `0x298`, `0x29c`, `0x2a0`, `0x2a4`, `0x2a8`, `0x2ac`: contiguous forward gear ratios.

For example, `MCLAREN` decodes to six forward gears: `3.23`, `2.19`, `1.71`, `1.39`, `1.16`, `0.93`, plus reverse `-3.23` and drivetrain scalar `4.0`.

`HP2_PhysicsCar_Construct_FUN_00137100` constructs the engine from `row + 0x2b0` and the drivetrain from `row + 0x270`. `HP2_DriveTrain_InitFromGlobalB_FUN_0018ae70` calls `HP2_DriveTrain_BuildShiftTables_FUN_0018ac38`, which builds shift tables by scanning RPM in `50` RPM steps up to `redline - 200` and choosing the first RPM where the next gear produces more wheel torque than the current gear. If no crossing is found, it uses `redline - 200`. The Godot automatic transmission now mirrors that recovered torque-crossing rule.

## Engine And Drivetrain Notes

The executable confirms dedicated engine and drivetrain runtime components through `EngineSlotPool`, `DriveTrainSlotPool`, and `DriveTrain` strings, plus a `World::DoTimestep - FakeEngineTask` profiler marker. The current Godot controller mirrors that architecture with explicit RPM, gear, clutch, shift, reverse, torque-curve, engine-brake, and wheel-torque stages.

The gear count, reverse ratio, neutral ratio, forward gear ratios, engine row pointer, drivetrain row pointer, and automatic upshift scan shape are now tied to executable usage. The exact Black Box torque curve payload and clutch/torque-converter behavior are still not bit-exact; keep these fields marked `inferred` until the `HP2_Curve_EvaluateLinear_FUN_0018f838` curve payload and drivetrain update loop are completely mapped.
