# NFS: Hot Pursuit 2 — Car Physics Reverse Engineering

**Binary:** PS2 ELF (MIPS R5900 / Emotion Engine)  
**Game:** Need for Speed: Hot Pursuit 2 (PS2)  
**Architecture:** MIPS R5900 with heavy use of PS2 VU0 SIMD vector instructions (`_lqc2`, `_sqc2`, `_vmul`, `_vadd`, `_vsub`, `_vmulbc`, `_vrsqrt`)  
**Car data file:** `GLOBAL/GLOBALB.LZC` / `GLOBALB.BUN`

---

## 1. Physics Architecture Overview

The engine is a **constraint-based rigid-body physics system** running inside `World::DoTimestep()` with these sequential phases:

```
1. PlayerCarThink / AICarThink  → read inputs, update gear state
2. Do Wheel Forces              → compute tire contact constraints
3. Drive                        → apply engine/drivetrain torque to wheels
4. BeginMovement                → rigid body prep
5. DoTimestepMove               → integrate rigid body (Euler integration)
6. DoTimestepCollisions         → resolve body collisions
7. FinishMovement               → sync state
8. FakeEngineTask               → update engine RPM
```

The system uses **5-iteration constraint solving** per timestep and subdivides the dt when speed is high.

### PhysicsCar Object Layout

| Field Offset | Description |
|---|---|
| `+0x00` | ptr to GlobalB car data block |
| `+0x06` | ptr to RigidBody (3D physics body) |
| `+0x07` | ptr to TwoWheelAckermanSteering |
| `+0x08..0x0B` | Wheel[4] ptrs (FL, FR, RL, RR) |
| `+0x0C..0x0F` | WheelConstraint[4] ptrs |
| `+0x10` | ptr to Engine |
| `+0x11` | ptr to DriveTrain |
| `+0x12` | ptr to StateData (speed, yaw, etc.) |
| `+0x13` | ptr to GlobalB params |
| `+0x14` | ptr to World/Track |
| `+0x15` | ptr to CarController (player inputs) |
| `+0x18` | ptr to chassis body (rigid body with inertia tensor) |

### Input Block (at `car_data + 0x210`)

| Offset | Type | Description |
|---|---|---|
| `+0x210` | `int16` | `steer` — signed short (-32768..32767 = left..right) |
| `+0x214` | `float` | `throttle` — 0.0–1.0 |
| `+0x218` | `float` | `brake` — 0.0–1.0 |
| `+0x21c` | `float` | `ebrake` — 0.0–1.0 |
| `+0x220` | `int` | `requested_gear` |
| `+0x224` | `int` | `current_gear` |
| `+0x228` | `bool` | `nitrous_active` |
| `+0x234` | `int` | `car_unique_id` |

---

## 2. Engine Subsystem

**Key functions:** `HP2_Engine_InitFromGlobalB_FUN_0018a7e8`, `FUN_0018aa28`, `FUN_0018aab0`, `HP2_Engine_UpdateShiftCutTimer_FUN_0018abf0`

### Engine Struct Layout

| Offset | Description |
|---|---|
| `+0x08` | vtable ptr |
| `+0x0C` | `current_rpm` (float) |
| `+0x10` | ptr to GlobalB engine params |
| `+0x18..0x28` | torque curve — 9-point piecewise linear, loaded from GlobalB |
| `+0x2C..0x34` | engine friction curve — 3-point piecewise linear |
| `+0x40` | `4WD_flag` |
| `+0x44` | `throttle_input` (0..1) |
| `+0x4C` | `throttle_multiplier` (1.0 normally) |
| `+0x50` | `shift_cut_active` (bool) |
| `+0x54` | `shift_cut_start_time` |
| `+0x58` | `throttle_scale` (1.0 normally; 3.0 during nitrous) |

### Torque Output (pseudocode)

```c
float Engine_GetTorque(Engine* e) {
    float rpm_normalized = e->current_rpm * RPM_SCALE;
    float peak_torque = Curve_EvaluateLinear(rpm_normalized, &e->torque_curve);
    peak_torque *= e->throttle_scale;
    if (e->shift_cut_active)
        peak_torque *= SHIFT_CUT_FACTOR;   // reduces torque during upshift
    // Rev limiter: beyond max RPM, apply negative torque
    if (rpm_normalized >= globalb->max_rpm - 100.0f)
        peak_torque = -REV_LIMITER_DRAG * peak_torque;
    return peak_torque;
}

float Engine_GetNetForce(Engine* e) {
    float torque = Engine_GetTorque(e);
    float net = torque * e->throttle_input * e->throttle_multiplier;
    // Engine friction (off-throttle drag)
    float friction = Curve_EvaluateLinear(current_rpm * scale, &e->friction_curve);
    net += -friction * (1.0f - e->throttle_input * e->throttle_multiplier);
    if (is_AWD && net < 0.0f)
        net *= AWD_REVERSE_DRAG_MULT;
    return net;
}
```

### Shift Cut Timer

```c
void Engine_UpdateShiftCutTimer(Engine* e) {
    if (e->shift_cut_active &&
        e->shift_cut_start + 4.0f < current_time * TIME_SCALE)
        e->shift_cut_active = false;
}
```

The shift cut lasts ~4 time-units (approximately 0.3–0.5 seconds at normal game speed), reducing torque on upshift for a realistic jerk feel.

---

## 3. Drivetrain Subsystem

**Key functions:** `HP2_DriveTrain_InitFromGlobalB_FUN_0018ae70`, `HP2_DriveTrain_BuildShiftTables_FUN_0018ac38`, `HP2_DriveTrain_SetRequestedGear_FUN_0018bca0`, `HP2_DriveTrain_UpdateAutoGearState_FUN_0018bce0`

### Drivetrain Struct Layout

| Offset | Description |
|---|---|
| `+0x0C` | `current_torque_scale` (0..1) |
| `+0x14` | ptr to Engine |
| `+0x18..0x24` | Wheel[4] ptrs |
| `+0x2C` | `current_gear` (target) |
| `+0x30` | `actual_gear` |
| `+0x34` | `last_downshift_speed` |
| `+0x38` | `transmission_type` (3 = automatic) |
| `+0x44` | `auto_shift_timer` |
| `+0x50..0x70` | `upshift_rpm_table[6]` (computed at init) |
| `+0x74..0x94` | `downshift_rpm_table[6]` |

### GlobalB Drivetrain Block (at `car_data + 0x270`)

| Offset | Description |
|---|---|
| `+0x00` | `front_axle_drive_fraction` (0.0=RWD, 0.5=50:50 AWD, 1.0=FWD) |
| `+0x04` | `rear_axle_drive_fraction` |
| `+0x08` | `front_gear_ratio` |
| `+0x0C` | `rear_gear_ratio` |
| `+0x10` | `front_drive_bias` (0..1) |
| `+0x18` | `gear_ratio[reverse]` |
| `+0x20` | `gear_ratio[1st]` |
| `+0x28` | `gear_ratio[2nd]` |
| ... | up to 6 forward gears + reverse |
| `+0x60` | `final_drive_ratio` |

### Auto-Shift Logic

```c
// Returns -1 (stay), -2 (in-progress)
// Upshift: RPM > upshift_table[gear] AND all wheels contact AND slip < 4.0
// Downshift: RPM < downshift_table[gear]
// 10-second timer prevents gear hunting
```

### Torque Distribution

```c
void DriveTrain_ApplyTorque(float engine_torque, DriveTrain* dt) {
    float ratio = gear_ratio[current_gear] * final_drive;
    float front_torque = engine_torque * ratio * front_drive_frac;
    float rear_torque  = engine_torque * ratio * rear_drive_frac;
    // Left/right split by wheel normal load ratio
    float rear_split = wheel_load_R / (wheel_load_L + wheel_load_R);
    wheel[RL].drive_torque = rear_torque * (1.0f - rear_split);
    wheel[RR].drive_torque = rear_torque * rear_split;
}
```

---

## 4. Tire & Contact Physics

**Key function:** `FUN_001a4930` — combined suspension spring/damper + tire lateral force

### Wheel Struct Layout

| Offset | Description |
|---|---|
| `+0x20` | `suspension_compression` (float, positive = compressed) |
| `+0x24` | `suspension_natural_length` |
| `+0x70..0x90` | wheel rotation matrix (3×3 + padding, 128-bit aligned) |
| `+0xA0..0xB0` | wheel attachment point (world space) |
| `+0x104` | `lateral_slip_velocity` |
| `+0x108` | `longitudinal_torque_accumulator` |
| `+0x10C` | `slip_locked` (1 = wheel locked/skidding) |
| `+0x114` | `lambda_x` — longitudinal contact impulse |
| `+0x118` | `lambda_y` — lateral contact impulse |
| `+0x150` | `surface_type_index` (0=asphalt, 1=dirt, 2=grass…) |
| `+0x154` | `is_grounded` |
| `+0x158` | `normal_load` (downforce, float) |
| `+0x15C` | `friction_coefficient` |
| `+0x160` | `slip_angle_lateral` |
| `+0x164` | `slip_angle_longitudinal` |
| `+0x168` | `grip_utilization` (0..1, 1 = at traction limit) |
| `+0x170` | `drive_torque` (from drivetrain) |
| `+0x174` | `brake_torque` |

### Tire Force Computation (pseudocode)

```c
void Wheel_ComputeForce(Wheel* w, RigidBody* body) {
    // === Spring/Damper ===
    float spring_force = w->drive_torque  * globalb->spring_rate   * SPRING_SCALE;
    float damper_force = w->brake_torque  * globalb->damper_rate   * DAMPER_SCALE;
    if (w->compression > 0.0f) { spring_force = -spring_force; damper_force = -damper_force; }
    if (!w->slip_locked)
        w->torque_accum += spring_force + damper_force;

    // === Velocity decomposition into wheel frame ===
    vec2 vel_2d = project_to_wheel_plane(body->velocity_at_point(w->contact_point));
    float slip_lateral      = w->compression * body->angular_velocity - vel_2d.x;
    float slip_longitudinal = vel_2d.y;

    // === Friction circle ===
    float contact_speed = sqrt(slip_lateral*slip_lateral + slip_longitudinal*slip_longitudinal);
    if (contact_speed > 0.0f) {
        float mu   = body->angular_speed * w->dt
                   * w->normal_load * w->torque_scale
                   * surface_table[w->surface_type].friction_coeff;
        float grip = GLOBAL_GRIP_SCALE * w->dt * mu;
        float inv_speed = grip / contact_speed;

        // Clamp impulses to friction circle
        w->lambda_x = inv_speed * slip_lateral;
        w->lambda_y = -inv_speed * slip_longitudinal;

        // Camber/steer contribution on lateral force
        float camber_angle = atan2(slip_lateral, slip_longitudinal) * CAMBER_SCALE;
        w->lambda_y -= sin(camber_angle) * 0.5f * w->lambda_y;
    }
}
```

### Final Friction Circle Clamp (after 5-iteration solver)

```c
float total_force = sqrt(lambda_x*lambda_x + lambda_y*lambda_y);
float max_grip    = GLOBAL_GRIP_SCALE * dt * normal_load * surface_mu * torque_scale;

if (total_force > max_grip && total_force > MIN_FORCE_THRESHOLD) {
    lambda_x *= max_grip / total_force;
    lambda_y *= max_grip / total_force;
}
grip_utilization = clamp(total_force / max_grip, 0.0f, 1.0f);
```

### Surface Friction Table (stride 0x90 at `DAT_00318c14`)

| Index | Surface | Friction Multiplier |
|---|---|---|
| 0 | Asphalt | ~1.00 |
| 1 | Dirt | ~0.70 |
| 2 | Grass | ~0.50 |
| 3+ | Gravel / Ice / Water | lower |

---

## 5. Steering Subsystem

**System name:** `TwoWheelAckermanSteering` (confirmed in binary strings)  
**Key functions:** `FUN_001c0270`, `FUN_001c0938`, `FUN_001c0b18`, `FUN_001c08d0`

### Raw Input → Angle

```c
float steer_to_angle(int16_t raw) {
    float angle = raw * STEER_SCALE_FACTOR;
    if (angle > ANGLE_MAX)  angle -= ANGLE_WRAP;
    if (angle < ANGLE_MIN)  angle += ANGLE_WRAP;
    return angle;  // result in game-space radians/degrees
}
```

### Ackermann Geometry

```c
void Ackermann_ComputeWheelAngles(Steering* s) {
    mat4 heading_matrix = BuildHeadingMatrix(car->yaw_angle);
    // Inner/outer wheel get different angles
    // based on geometric projection of turn radius
    for each front_wheel {
        vec2 delta      = target_contact - wheel_attachment_world;
        vec2 local_delta = InverseTransform(delta, heading_matrix);
        wheel->steer_angle = local_delta.x - wheel_rest_offset.x;
    }
}
```

### Sideslip Angle

```c
float GetSideslipAngle(StateData* sd) {
    if (sd->speed < 5.0f) return 0.0f;
    int16_t vel_heading = atan2(velocity.x, velocity.z) >> HEADING_SHIFT;
    float sideslip = (sd->heading - vel_heading) * HEADING_TO_ANGLE_SCALE;
    // Wrap to ±180°
    if (sideslip > HALF_TURN) sideslip -= FULL_TURN;
    if (sideslip < -HALF_TURN) sideslip += FULL_TURN;
    return sideslip;
}
```

### Oversteer / Drift Assist (baked into the main physics loop)

```c
// In HP2_PhysicsCar_MoveUpdate (FUN_00137d90):
// If speed > ~80 km/h AND sideslip > SIDESLIP_THRESHOLD (~10–15 degrees):
// automatically apply counter-torque to the outer rear wheel
if (state->drive_direction == FORWARD && fabs(sideslip) > SIDESLIP_THRESHOLD) {
    outer_rear_wheel->drive_torque = 20.0f;  // countersteering assist
}
```

**This is the core of the HP2 arcade-drift feel** — it is not a separate "drift mode" but woven directly into the physics loop.

---

## 6. Weight Transfer & Aerodynamics

**Key functions:** `FUN_001375f0`, `FUN_001add70`

### Weight Distribution

```c
void PhysicsCar_DistributeWeight(PhysicsCar* car) {
    float accel_effect = body->forward_velocity_delta * ANTI_DIVE_COEFF;
    float aero_load    = speed_squared * globalb->downforce_coeff;
    float total_with_aero = total_weight + aero_load;
    float front_load = total_with_aero * (0.5f - accel_effect);
    float rear_load  = total_with_aero *  accel_effect;
    // Apply per-wheel
    for each front wheel: set_normal_load(front_load / 2.0f);
    for each rear  wheel: set_normal_load(rear_load  / 2.0f);
}
```

### Aerodynamic Forces

- Drag ∝ `speed² × drag_coeff` with a 4th-power normal direction weighting
- Separate front/rear downforce: `AERO_FRONT * speed` (front), `AERO_REAR * speed` (rear)
- Both applied per-side via contact force accumulation

---

## 7. Braking Subsystem

### Brake Torque Distribution

```c
for (int i = 0; i < 4; i++) {
    wheel[i].brake_torque = brake_input * globalb->brake_bias[i];
    if (i >= 2)  // rear wheels: also add e-brake
        wheel[i].brake_torque += ebrake_input * globalb->rear_brake_scale[i];
}
```

### Engine Braking

```c
float DriveTrain_GetEngineBrakeTorque(DriveTrain* dt) {
    float delta = current_rpm - target_rpm;
    float torque = clamp(delta, -MAX_ENGINE_BRAKE, MAX_ENGINE_BRAKE);
    return torque * globalb->final_drive;
}
```

---

## 8. Constraint Solver

```c
void PhysicsCar_ResolveForces(PhysicsCar* car) {
    // Compute all wheel spring/contact forces
    for each wheel: Wheel_ComputeForce(wheel);

    // Euler integration step
    body->velocity        += dt * accumulated_force  / mass;
    body->angular_velocity += dt * accumulated_torque * inv_inertia;

    // 5-iteration constraint relaxation
    for (int iter = 0; iter < 5; iter++) {
        accumulate_constraint_forces(constraint_list, accel_buffer);
        integrate_constraints(dt / 5.0f, constraint_list);
        for each wheel: recompute_wheel_impulse(wheel);
        drivetrain_redistribute_torque(drivetrain);
    }

    // Commit final contact impulses & grip_utilization
    for each wheel: finalize_wheel_contact(wheel);
}
```

### RigidBody Struct Layout

| Offset | Description |
|---|---|
| `+0x10..0x50` | world-space rotation matrix (4 × vec4) |
| `+0x60` | linear velocity (vec4) |
| `+0x70` | angular momentum (vec4) |
| `+0x90` | angular velocity (vec4) |
| `+0xA0` | body-space velocity |
| `+0x118` | mass |
| `+0x11C` | 1/mass |
| `+0x120` | Ixx (inertia X) |
| `+0x134` | Iyy (inertia Y) |
| `+0x148` | Izz (inertia Z) |

---

## 9. GlobalB Car Data Block Layout

Loaded from `GLOBAL/GLOBALB.LZC`.

| Offset Range | Data |
|---|---|
| `+0x1A0..0x1BF` | Wheel attachment positions [4 × vec3] |
| `+0x1E0` | Wheel radius (float) |
| `+0x270..0x2AF` | DriveTrain params (gear ratios, drive bias, final drive) |
| `+0x2B0..0x2CF` | Engine params (RPM range, torque curve base) |
| `+0x2C0..` | Torque curve data (9+ floats: RPM vs Nm) |
| `+0x2F0..0x2FF` | Tire friction overrides [4 floats per wheel] |
| `+0x31C` | Chassis yaw-torque constant (used in oversteer model) |

---

## 10. Tire Model Notes

The tire lateral force model uses a **multi-segment Pacejka-style lookup table** (7 curves, indexed by `slip_speed / wheel_radius`). The normalized lateral force is scaled by normal load. At high speeds (curve index ≥ 6) a saturation curve is used, which gives the progressive grip limit feel at speed.

---

## 11. Key Physics Constants

| Symbol | Role |
|---|---|
| `RPM_SCALE` (fGpffff8a3c) | Engine RPM-to-curve normalization |
| `SHIFT_CUT_FACTOR` (fGpffffafb4) | Throttle multiplier during upshift (~0.3–0.5) |
| `REV_LIMITER_DRAG` (fGpffffafb0) | Negative torque past redline |
| `AWD_REVERSE_DRAG` (fGpffff8a44) | AWD reverse resistance multiplier |
| `SPRING_SCALE` (fGpffffb3d0) | Global spring force scale |
| `DAMPER_SCALE` (fGpffffb3d4) | Global damper force scale |
| `GLOBAL_GRIP_SCALE` (fGpffffb3e0) | Master grip/friction scale |
| `SUSPENSION_LIMIT` (fGpffffb3cc) | Max compression before softening |
| `SIDESLIP_THRESHOLD` (fGpffff8418) | Oversteer assist trigger angle (~10–15°) |
| `ANTI_DIVE_COEFF` (fGpffff83d0) | Weight-transfer anti-dive factor |
| `STEER_SCALE` (fGpffff8470) | Raw int16 steer to angle factor |
| `AERO_FRONT` (fGpffff8e30) | Front downforce speed coefficient |
| `AERO_REAR` (fGpffff8e34) | Rear downforce speed coefficient |
| `AUTO_BRAKE_BASE` (fGpffffa744) | Off-throttle auto-brake amount |
| `SIDESLIP_BRAKE_LO` (fGpffffa750) | Lower sideslip auto-brake threshold |
| `SIDESLIP_BRAKE_HI` (fGpffffa754) | Upper sideslip auto-brake threshold |

---

## 12. Godot Implementation Guide

### Recommended Architecture

```
VehicleBody3D (or RigidBody3D)
├── Engine.gd          — torque curve, RPM, shift-cut
├── DriveTrain.gd      — gear ratios, torque distribution
├── Wheel.gd × 4       — spring/damper + friction circle
├── SteeringSystem.gd  — Ackermann + sideslip tracking
└── PhysicsController.gd — main loop, weight transfer, oversteer assist
```

### Key Implementation Points

**1. Engine — 9-point torque curve**
```gdscript
var torque_curve: Curve  # RPM (0..1 normalized) → peak torque (Nm)
var friction_curve: Curve  # RPM (0..1) → friction drag (Nm)

func get_net_torque(rpm: float, throttle: float) -> float:
    var t = torque_curve.sample(rpm / max_rpm) * throttle_scale
    if shift_cut_active:
        t *= shift_cut_factor
    if rpm >= max_rpm - 100.0:
        t = -rev_limiter_drag * t
    var friction = friction_curve.sample(rpm / max_rpm) * (1.0 - throttle)
    return t - friction
```

**2. Friction Circle per wheel**
```gdscript
func compute_contact_impulse(slip_lat: float, slip_long: float,
                              normal_load: float, surface_mu: float, dt: float):
    var speed = sqrt(slip_lat*slip_lat + slip_long*slip_long)
    if speed < 0.0001: return Vector2.ZERO
    var max_grip = GLOBAL_GRIP_SCALE * dt * normal_load * surface_mu
    var scale = min(1.0, max_grip / speed)
    grip_utilization = speed * scale / max_grip
    return Vector2(slip_lat, -slip_long) * scale
```

**3. Weight Transfer**
```gdscript
func distribute_weight(car_mass: float, accel_fwd: float, speed: float) -> Array:
    var aero = speed * speed * downforce_coeff
    var total = car_mass * 9.8 + aero
    var accel_shift = accel_fwd * anti_dive_coeff
    var front = total * (0.5 - accel_shift) / 2.0
    var rear  = total * (0.5 + accel_shift) / 2.0
    return [front, front, rear, rear]  # FL, FR, RL, RR
```

**4. Oversteer Assist (the HP2 arcade-drift magic)**
```gdscript
func apply_oversteer_assist(sideslip_deg: float):
    if abs(sideslip_deg) < SIDESLIP_THRESHOLD: return
    if speed < 80.0 / 3.6: return  # only above ~80 km/h
    # Apply counter-torque to outer rear wheel
    var outer = RR if sideslip_deg > 0.0 else RL
    outer.drive_torque += OVERSTEER_ASSIST_TORQUE  # ~20 Nm in original
```

**5. Sub-stepping (important for stability)**
```gdscript
func _physics_process(delta: float):
    var steps = max(1, int(delta / SUBSTEP_DT) + 1)
    var sub_dt = delta / steps
    for i in steps:
        _physics_substep(sub_dt)
```

**6. Shift-Cut feel**
```gdscript
func on_upshift():
    shift_cut_active = true
    shift_cut_timer = 0.0

func _physics_process(delta):
    if shift_cut_active:
        shift_cut_timer += delta
        if shift_cut_timer > SHIFT_CUT_DURATION:  # ~0.3–0.5s
            shift_cut_active = false
```

### Surface Friction Values (Suggested Godot Equivalents)

| Surface | HP2 mu | Godot PhysicsMaterial `friction` |
|---|---|---|
| Asphalt | 1.00 | 0.85–1.00 |
| Dirt | 0.70 | 0.55–0.70 |
| Grass | 0.50 | 0.40–0.55 |
| Gravel | 0.60 | 0.50–0.65 |
| Ice | 0.20 | 0.15–0.25 |

### What Makes HP2 Feel the Way It Does

1. **Sticky low-speed, drifty high-speed**: The Pacejka curve saturates at high speed — at speed the lateral grip drops off smoothly rather than snapping.

2. **The drift is automatic, not toggle-based**: The oversteer assist fires whenever sideslip exceeds ~10–15° at speed. Players experience it as the car naturally "catching" oversteers and flowing into controlled slides.

3. **Engine feel**: The 9-point torque curve + shift-cut + rev limiter drag gives that punchy "each gear has a power band" feel rather than flat power delivery.

4. **Weight transfer is immediate**: The single-step Euler integration means weight shifts snap fast, contributing to the responsive, slightly toy-like feel of arcade handling.

5. **No traction control, only auto-brake**: On corner exit, wheelspin is allowed — traction is limited only by the friction circle and normal load. The off-throttle auto-brake (`AUTO_BRAKE_BASE`) is what helps cars rotate into corners without a drift-mode toggle.

---

## 13. Relevant Ghidra Function Map

| Function Address | Description |
|---|---|
| `FUN_001000b8` | Entry point / main |
| `HP2_Engine_InitFromGlobalB_FUN_0018a7e8` | Engine init from car data |
| `FUN_0018aa28` | Engine torque output |
| `FUN_0018aab0` | Engine net force (with friction) |
| `HP2_Engine_UpdateShiftCutTimer_FUN_0018abf0` | Shift cut timer |
| `HP2_DriveTrain_InitFromGlobalB_FUN_0018ae70` | DriveTrain init |
| `HP2_DriveTrain_BuildShiftTables_FUN_0018ac38` | Compute auto-shift RPM tables |
| `HP2_DriveTrain_SetRequestedGear_FUN_0018bca0` | Manual gear shift |
| `HP2_DriveTrain_UpdateAutoGearState_FUN_0018bce0` | Auto-gearbox logic |
| `FUN_0018b6c8` | Torque distribution to wheels |
| `FUN_0018b948` | Brake torque distribution |
| `FUN_001a4930` | Tire force computation (main) |
| `FUN_001a4ee0` | Friction circle clamp (final) |
| `FUN_001c0b18` | Ackermann wheel angle computation |
| `FUN_001c08d0` | Sideslip angle calculation |
| `FUN_00137d90` (HP2_PhysicsCar_MoveUpdate) | Main car physics update |
| `FUN_001375f0` | Weight distribution |
| `FUN_001add70` | Aerodynamic drag/downforce |
| `FUN_00138f38` | Constraint solver (5-iter) |
