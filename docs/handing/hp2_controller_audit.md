# HP2 Controller Audit Report

**Date:** 2026-04-28  
**Audited path:** `godot_eagl_ps2/gameplay/vehicles/hp2_controller/`  
**Benchmark data:** `results/benchmark_summary.csv`  
**Reference:** `docs/handing/hp2_car_physics_reverse_engineering.md`

---

## 1. Benchmark Scorecard

Results from `benchmark_summary.csv` measured against the Python reference model.

| Test | Speed RMSE | Yaw RMSE | Sideslip RMSE | Peak Sideslip (Godot / Ref) | Grade |
|------|-----------|----------|---------------|-----------------------------|-------|
| `step_steer` | 0.079 | 0.413 | 0.076 | 7.12° / 7.12° | ✅ PASS |
| `acceleration` | 0.374 | 0.0 | 0.0 | — | ⚠️ WARN |
| `braking` | 0.539 | 0.0 | 0.0 | — | ⚠️ WARN |
| `drift_init` | **6.469** | **13.244** | **6.534** | **8.05° / 13.87°** | ❌ FAIL |
| `steady_circle` | 0.116 | 0.599 | 0.095 | 4.95° / 4.95° | ✅ PASS |

**Overall fidelity score:** 2/5 clean passes, 2 warnings, 1 critical failure.

---

## 2. Per-Subsystem Audit

### 2.1 `engine.gd` — HP2Engine ✅ FAITHFUL

| Aspect | RE Finding | Implementation | Status |
|--------|-----------|----------------|--------|
| Torque curve | 9-point piecewise linear | 9 `Vector2` breakpoints present | ✅ |
| Friction curve | 3-point, rpm-indexed | 3 `Vector2` breakpoints present | ✅ |
| RPM tracking | Lerp toward wheel-derived target at ≈15 Hz | `lerpf(rpm, target, delta * 15.0)` | ✅ |
| Shift-cut factor | 0.35× for ~0.4s | `SHIFT_CUT_FACTOR = 0.35`, `SHIFT_CUT_DURATION = 0.4` | ✅ |
| Rev-limiter drag | Negative torque past max_rpm | `peak_torque = -REV_LIMITER_DRAG * abs(peak_torque)` | ✅ |
| Idle / peak / max RPM | Configurable per car | Applied from `config` in `_apply_handling_profile_params` | ✅ |

**Verdict:** Most faithful subsystem. No action required.

---

### 2.2 `hp2_assist.gd` — HP2Assist ✅ FAITHFUL

| Aspect | RE Finding | Implementation | Status |
|--------|-----------|----------------|--------|
| Sideslip threshold | ~12° | `sideslip_threshold_deg = 12.0` | ✅ |
| Minimum speed | 80 km/h | `min_speed_kmh = 80.0` | ✅ |
| Corrective torque | 20 Nm on outer rear wheel | `assist_torque_nm = 20.0`, correct `"RR"/"RL"` selection | ✅ |
| Direction logic | Positive sideslip → RR, negative → RL | `active_wheel = "RR" if sideslip_deg > 0.0 else "RL"` | ✅ |

**Verdict:** Correct. No action required.

---

### 2.3 `steering_system.gd` — HP2SteeringSystem ⚠️ MINOR DIVERGENCE

| Aspect | RE Finding | Implementation | Status |
|--------|-----------|----------------|--------|
| Max steer angle | Per-car, configurable | `max_steer_degrees` driven by config | ✅ |
| Response mechanism | Rate ramp toward input | `move_toward(current_steer, target, rate * delta)` | ✅ |
| Speed-dependent rate | RE showed steer rate scales with ~1/speed above 60 km/h | Flat `steering_response_rate = 5.5` regardless of speed | ⚠️ |

**Impact:** Minor. Contributes to `step_steer` yaw_rmse = 0.413 (above but near the 0.3 pass threshold). At high speed the car steers in slightly too fast.

**Fix:** Multiply `steering_response_rate` by `clamp(1.0 - speed_kmh / 200.0, 0.3, 1.0)` inside `update()`.

---

### 2.4 `drivetrain.gd` — HP2Drivetrain ⚠️ STRUCTURAL ISSUE

| Aspect | RE Finding | Implementation | Status |
|--------|-----------|----------------|--------|
| RWD torque split | Load-proportional rear split | `rr_split = load_rr / total_rear_load` | ✅ |
| Gear ratios | Per-car 6+R | Configurable `PackedFloat32Array` | ✅ |
| Final drive | Per-car | Configurable | ✅ |
| Per-gear shift tables | RE: different upshift RPM per gear | Single `upshift_rpm` / `downshift_rpm` scalar | ⚠️ |
| `update_auto_shift()` | — | Method exists but is **never called** — dead code | ⚠️ |
| Shift logic location | — | Duplicated: `drivetrain.update_auto_shift()` and `physics_controller._update_auto_shift()` | ⚠️ |

**Impact of per-gear tables:** Flat threshold causes early upshifts in low gears and late upshifts in high gears. Contributes to `acceleration` speed_rmse = 0.374.

**Impact of dead code:** `drivetrain.update_auto_shift()` is bypassed entirely. `physics_controller._update_auto_shift()` (line 586) directly manipulates `drivetrain.*` properties instead. No double-shift risk since only one path runs, but the code is split confusingly.

**Fix:**
1. Remove `drivetrain.update_auto_shift()` or make it the sole caller.
2. Add `var upshift_rpm_per_gear: PackedFloat32Array` to drivetrain and interpolate per gear.

---

### 2.5 `wheel.gd` — HP2Wheel ⚠️ FRICTION CIRCLE FORMULATION

| Aspect | RE Finding | Implementation | Status |
|--------|-----------|----------------|--------|
| Friction circle | `sqrt(Fx²+Fz²) ≤ μ·Fn` | Correctly enforced in `compute_contact_forces` | ✅ |
| Slip inputs expected unit | Force requests (N) — friction circle clips them | Both `slip_long` and `slip_lat` passed in Newtons | ✅ |
| Brake lerp blend | `lerpf(target, 0.0, brake_torque / 2200)` | Matches RE constant | ✅ |
| Drive spin-up | Torque spin-up on grip_utilization > 0.98 | `drive_torque * 0.015` heuristic | ⚠️ |
| Airborne inertia | Wheel spins freely in air | `update_airborne_angular_velocity` present | ✅ |

**Note on `grip_utilization > 0.98` spin-up:** RE used a wheelspin flag tied to slip exceeding a per-tire threshold. The 0.98 threshold is a reasonable approximation but will not reproduce the abrupt wheel-spin onset visible in the original.

---

### 2.6 `physics_controller.gd` — HP2PhysicsController ❌ TWO CRITICAL BUGS

#### Bug A — Hardcoded `0.02` dt in slip calculation (line 464)

```gdscript
# Current (WRONG)
wheel.compute_contact_forces(
    drive_force_request - brake_force_request - v_long * longitudinal_stiffness * 0.02,
    v_lat * lateral_stiffness
)
```

The constant `0.02` hard-codes a 50 Hz assumption for the substep. With 4 substeps at 60 Hz, the actual `step_delta ≈ 0.00417 s`, meaning the longitudinal slip damping term is **4.8× too large**. This over-damps the longitudinal force, causing:
- Under-acceleration: `acceleration` speed_rmse = 0.374
- Over-braking early: `braking` speed_rmse = 0.539

**Fix:** Replace `0.02` with `delta` (the substep delta already in scope):
```gdscript
wheel.compute_contact_forces(
    drive_force_request - brake_force_request - v_long * longitudinal_stiffness * delta,
    v_lat * lateral_stiffness
)
```

#### Bug B — Artificial yaw damping term (line 480)

```gdscript
# Current (WRONG)
_yaw_rate += ((yaw_torque - yaw_damping * _yaw_rate) / maxf(inertia_yaw, 1.0)) * delta
```

RE finding: HP2's yaw dynamics came entirely from tire lateral forces. There is no explicit yaw-rate damping constant in the binary. The `yaw_damping` term is an invented stabilizer.

**Effect at drift-relevant yaw rates:**

| Yaw rate | Artificial damping torque |
|----------|--------------------------|
| 0.3 rad/s | 28.5 Nm |
| 0.5 rad/s | 47.5 Nm |
| 1.0 rad/s | 95.0 Nm |

At 1.0 rad/s this is larger than the oversteer-assist torque (20 Nm) and nearly 4% of `inertia_yaw`. It is the **primary cause** of the drift_init failure: peak sideslip reaches only 8.05° vs 13.87° reference (42% deficit) because yaw rotation is artificially braked during the initiation phase.

`steady_circle` passes because in steady state `yaw_torque ≈ 0` so the damping has no net effect.

**Fix:** Remove the `yaw_damping` term from the integration:
```gdscript
# Correct
_yaw_rate += (yaw_torque / maxf(inertia_yaw, 1.0)) * delta
```

If oscillation occurs without it, the correct fix is to tune `lateral_stiffness` and `rear_wheel_grip_scale` so tire forces naturally provide adequate damping — matching how the original PS2 physics worked.

---

### 2.7 `physics_controller.gd` — Other Observations

| Item | Status | Notes |
|------|--------|-------|
| Ackermann geometry | ✅ | Correct inner/outer angle derivation |
| 4-substep integration | ✅ | `substeps = 4` default, consistent with RE's per-frame iterations |
| Weight transfer | ✅ | Longitudinal transfer with `weight_transfer_coeff`, `cg_height / wheelbase` |
| Lateral weight transfer | ❌ MISSING | RE had lateral (cornering) weight transfer to outer wheels. Currently `FL/FR` always equal, `RL/RR` always equal |
| Aero downforce | ❌ MISSING | RE had a speed-squared downforce term scaling all wheel loads. Only drag is present |
| `InputSource` abstraction | ✅ | Clean swappable interface, fully compatible with automated benchmarking |
| Telemetry export (`get_telemetry_row`) | ✅ | All required columns present |
| Config loading (`apply_config`) | ✅ | Correctly maps GlobalB car parameters |

---

## 3. Missing Parts

### Priority 1 — Critical (causes test failures)

| # | Issue | File | Line | Impact |
|---|-------|------|------|--------|
| P1-A | Hardcoded `0.02` substep dt in slip calculation | `physics_controller.gd` | 464 | `acceleration` ⚠️, `braking` ⚠️ |
| P1-B | Artificial `yaw_damping` term not in RE | `physics_controller.gd` | 480 | `drift_init` ❌ |

### Priority 2 — Significant (affects feel but tests pass)

| # | Issue | File | Notes |
|---|-------|------|-------|
| P2-A | No lateral weight transfer | `physics_controller.gd:_compute_normal_loads` | Outer-wheel load not increased in cornering; affects grip balance |
| P2-B | No aero downforce | `physics_controller.gd:_substep` | At 180+ km/h downforce contributes meaningfully to grip |
| P2-C | Speed-independent steering rate | `steering_system.gd:update` | RE rate scaled with 1/speed above ~60 km/h |

### Priority 3 — Minor (cosmetic / structural)

| # | Issue | File | Notes |
|---|-------|------|-------|
| P3-A | `drivetrain.update_auto_shift()` is dead code | `drivetrain.gd` | Never called; logic lives in `physics_controller._update_auto_shift()` |
| P3-B | Single upshift/downshift RPM threshold | `drivetrain.gd` | RE had per-gear shift tables; low priority if target gearbox feel is approximate |
| P3-C | Wheel spin-up heuristic (`grip_utilization > 0.98`) | `wheel.gd` | RE used a slip-threshold flag; minor onset timing difference |

---

## 4. Recommended Fix Sequence

Apply in this order to avoid regressions between fixes:

**Step 1 — Fix P1-A (slip dt)**
```gdscript
# physics_controller.gd line ~464
wheel.compute_contact_forces(
    drive_force_request - brake_force_request - v_long * longitudinal_stiffness * delta,
    v_lat * lateral_stiffness
)
```
Re-run `acceleration` and `braking` benchmarks. Expected: speed_rmse drops to < 0.15.

**Step 2 — Fix P1-B (yaw damping)**
```gdscript
# physics_controller.gd line ~480
_yaw_rate += (yaw_torque / maxf(inertia_yaw, 1.0)) * delta
# remove: - yaw_damping * _yaw_rate
```
Re-run `drift_init`. Expected: peak_sideslip approaches 13.87° reference.  
If oscillation appears in `steady_circle`, reduce `rear_wheel_grip_scale` slightly (try 0.85) to restore natural damping through tire forces.

**Step 3 — Add lateral weight transfer (P2-A)**

Inside `_compute_normal_loads`, add lateral contribution:
```gdscript
func _compute_normal_loads(longitudinal_acceleration: float, lateral_acceleration: float) -> Dictionary:
    var base_front := vehicle_mass_kg * GRAVITY * front_weight_bias
    var base_rear  := vehicle_mass_kg * GRAVITY * (1.0 - front_weight_bias)
    var long_transfer := vehicle_mass_kg * longitudinal_acceleration * cg_height / maxf(wheelbase, 0.0001) * weight_transfer_coeff
    var lat_transfer  := vehicle_mass_kg * lateral_acceleration  * cg_height / maxf((track_front + track_rear) * 0.5, 0.0001) * weight_transfer_coeff
    var front := maxf(base_front - long_transfer, 0.0)
    var rear  := maxf(base_rear  + long_transfer, 0.0)
    return {
        "FL": maxf(front * 0.5 - lat_transfer, 0.0),
        "FR": maxf(front * 0.5 + lat_transfer, 0.0),
        "RL": maxf(rear  * 0.5 - lat_transfer, 0.0),
        "RR": maxf(rear  * 0.5 + lat_transfer, 0.0),
    }
```
Derive `lateral_acceleration` from `(_vx * cos(_heading) - _vz * sin(_heading))` delta per substep.

**Step 4 — Speed-dependent steering rate (P2-C)**
```gdscript
# steering_system.gd:update()
var speed_factor := clampf(1.0 - speed_kmh / 250.0, 0.25, 1.0)  # pass speed_kmh in
current_steer = move_toward(current_steer, target, steering_response_rate * speed_factor * delta)
```

**Step 5 — Clean up dead code (P3-A)**  
Either delete `drivetrain.update_auto_shift()` or move the full shift logic back there and call it from `_substep`.

---

## 5. Expected Benchmark After Fixes

Projected outcomes after P1-A + P1-B are applied (P2 / P3 have smaller impact):

| Test | Current Grade | Projected Grade | Key Change |
|------|--------------|-----------------|------------|
| `step_steer` | ✅ PASS | ✅ PASS | Slight yaw improvement from lateral transfer |
| `acceleration` | ⚠️ WARN | ✅ PASS | slip dt fix removes longitudinal over-damping |
| `braking` | ⚠️ WARN | ✅ PASS | slip dt fix |
| `drift_init` | ❌ FAIL | ✅ PASS | yaw_damping removal restores sideslip amplitude |
| `steady_circle` | ✅ PASS | ✅ PASS | Unaffected; monitor for oscillation regression |
