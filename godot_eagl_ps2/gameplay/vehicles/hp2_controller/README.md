# HP2 Controller Validation Harness

Minimal planar HP2-style validation controller for deterministic telemetry, benchmark captures, and comparison with the Python/PS2 reference work.

## Files

- `hp2_car.tscn` - `RigidBody3D` scene with manual planar X/Z + yaw integration.
- `physics_controller.gd` - tire forces, weight transfer, steering, sideslip, substepping, and oversteer assist.
- `engine.gd` / `drivetrain.gd` - simplified torque curve, shift cut, automatic gears, and RWD torque split.
- `input_source.gd`, `player_input.gd`, `scripted_input.gd` - deterministic input abstraction.
- `telemetry_exporter.gd` - strict CSV schema writer.
- `benchmark_runner.gd` - automated step steer, acceleration, braking, drift init, and steady circle runner.
- `benchmark_compare.py` - dependency-free Python reference comparison that writes an SVG graph and summary CSV.

## Run Benchmarks Headless

```bash
godot --headless --path /Users/nurupo/Desktop/dev/eagl-godot/godot_eagl_ps2 res://gameplay/vehicles/hp2_controller/benchmark_runner.tscn
```

CSV files are written to `user://hp2_benchmarks` as:

- `godot_step_steer.csv`
- `godot_acceleration.csv`
- `godot_braking.csv`
- `godot_drift_init.csv`
- `godot_steady_circle.csv`
- `godot_surface_asphalt_braking.csv`
- `godot_surface_dirt_braking.csv`
- `godot_surface_grass_braking.csv`

The benchmark also prints an airborne wheel-spin check. In airborne debug the chassis remains planar/frozen for inspection, while steering, engine RPM, drivetrain torque, and wheel spin continue to update with zero normal load/contact force.

## Compare Against Python Reference

```bash
python3 gameplay/vehicles/hp2_controller/benchmark_compare.py
```

Outputs:

- `gameplay/vehicles/hp2_controller/results/hp2_benchmark_comparison.svg`
- `gameplay/vehicles/hp2_controller/results/benchmark_summary.csv`
- `gameplay/vehicles/hp2_controller/results/reference_*.csv`

The comparison reference is the documented planar Python model. It is not a PS2 emulator capture; swap in Layer 5 capture CSVs later when available.

## CSV Schema

The exporter writes this exact header:

```text
t speed_kmh speed_ms yaw_rate sideslip heading vx vy pos_x pos_y accel_long rpm gear shift_cut grip_FL grip_FR grip_RL grip_RR load_FL load_FR load_RL load_RR surface_type surface_mu
```

Columns are comma-separated in the file.

## Scope

This is a measurement system, not final gameplay handling. It keeps roll and pitch out of the planar body solve so the benchmark output stays deterministic, but wheel load now passes through the HP2 profile-driven suspension spring/damper/travel model.
