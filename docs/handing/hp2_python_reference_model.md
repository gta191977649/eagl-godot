# HP2 Python Reference Model — Implementation & Benchmarking Guide

**Purpose:** Build a Python re-implementation of the HP2 physics equations (from RE findings) to serve as ground truth for comparing against the Godot implementation. No controller, no emulator, no PS2 required.  
**Companion docs:**
- `hp2_car_physics_reverse_engineering.md` — source of all constants and equations used here
- `hp2_car_physics_validate.md` — overall validation strategy this feeds into

---

## Architecture Decision: Planar 4-Wheel Model

We do **not** implement full 3D rigid body physics. Instead we use a **planar 4-wheel model** — the car moves in 2D (X/Z plane), no roll or pitch. This captures everything that matters for handling feel:

- Yaw rate and sideslip (the primary feel signals)
- Per-wheel normal load and grip utilization
- Weight transfer front/rear under acceleration and braking
- Engine torque curve, shift cut, gear shifts
- Friction circle per wheel
- Oversteer assist

What it omits (acceptable for this comparison):
- Body roll and its effect on camber
- Pitch under braking/acceleration
- Suspension travel limits
- 3D terrain following

This fidelity level is sufficient because all the metrics we measure are planar — yaw rate, sideslip, speed, lateral acceleration, grip utilization. Full 3D adds complexity without improving the comparison.

---

## Project Structure

```
hp2_reference/
├── hp2_reference.py          # Main model — all subsystems
├── test_runner.py            # Standardized test scenarios
├── compare.py                # Comparison metrics vs Godot CSV
├── car_params.py             # GlobalB constants (from RE)
├── data/
│   └── godot_*.csv           # Godot telemetry exports (one per test)
└── results/
    └── *.png / *.csv         # Comparison plots and scores
```

Install dependencies:
```bash
pip install numpy scipy matplotlib pandas dtaidistance similaritymeasures
```

---

## Experiment Design

### The Core Principle: Identical Programmatic Inputs to Both Systems

**Neither system is driven by a human.** Both Python and Godot receive the exact same numerical input sequences — fixed `(throttle, brake, steer)` tuples held for fixed durations — injected directly by code. No controller, no keyboard, no timing variance between runs.

```
┌─────────────────────────────────────────────────────────────┐
│                    EXPERIMENT DESIGN                        │
│                                                             │
│  Input Sequence (shared)                                    │
│  e.g. Step Steer:                                           │
│    Phase 1: throttle=0.6, brake=0, steer=0,   dur=5s       │
│    Phase 2: throttle=0.3, brake=0, steer=0.5, dur=4s       │
│                    │                                        │
│         ┌──────────┴──────────┐                             │
│         ▼                     ▼                             │
│  ┌─────────────┐      ┌──────────────┐                      │
│  │  Python     │      │  Godot       │                      │
│  │  HP2 Model  │      │  Car Scene   │                      │
│  │  (RE eqns)  │      │  (your impl) │                      │
│  └──────┬──────┘      └──────┬───────┘                      │
│         │                    │                              │
│         ▼                    ▼                              │
│  hp2_step_steer.csv   godot_step_steer.csv                  │
│  (ground truth)       (under test)                          │
│         │                    │                              │
│         └──────────┬─────────┘                              │
│                    ▼                                        │
│              compare.py                                     │
│         (RMSE, DTW, lag, score)                             │
└─────────────────────────────────────────────────────────────┘
```

### Why This Matters

If inputs were manual (human-driven), any difference in output could be explained by input variation — the comparison would be meaningless. With programmatic inputs, **both systems see exactly the same stimulus**, so any difference in the output CSVs comes purely from the physics implementation, not from how the car was driven.

### How Godot Inputs Are Injected (No Human Required)

Godot's car reads from an **`InputSource` interface** rather than directly from `Input.get_action_strength()`. The test runner swaps in a `ScriptedInput` object and sets values programmatically each physics frame.

```gdscript
# InputSource.gd — base class, two implementations
class_name InputSource extends RefCounted
func get_throttle() -> float: return 0.0
func get_brake()    -> float: return 0.0
func get_steer()    -> float: return 0.0
```

```gdscript
# PlayerInput.gd — used during normal gameplay
class_name PlayerInput extends InputSource
func get_throttle() -> float: return Input.get_action_strength("accelerate")
func get_brake()    -> float: return Input.get_action_strength("brake")
func get_steer()    -> float:
    return Input.get_action_strength("steer_right") \
         - Input.get_action_strength("steer_left")
```

```gdscript
# ScriptedInput.gd — used during benchmark tests, no human involved
class_name ScriptedInput extends InputSource
var throttle := 0.0
var brake    := 0.0
var steer    := 0.0
func get_throttle() -> float: return throttle
func get_brake()    -> float: return brake
func get_steer()    -> float: return steer
```

```gdscript
# PhysicsController.gd — one line change enables both modes
var input_source: InputSource = PlayerInput.new()  # swap to ScriptedInput for tests

func _physics_process(delta):
    var thr = input_source.get_throttle()   # same code path regardless of source
    var brk = input_source.get_brake()
    var str = input_source.get_steer()
    # ... rest of physics unchanged
```

```gdscript
# BenchmarkRunner.gd — drives the whole test suite automatically
extends Node

@onready var car       = $Car
@onready var telemetry = $Car/TelemetryExporter
var scripted           = ScriptedInput.new()

func _ready():
    car.input_source = scripted   # take over from player
    run_all_tests()

func run_all_tests():
    await _run("step_steer",    _phases_step_steer())
    await _run("acceleration",  _phases_acceleration())
    await _run("braking",       _phases_braking())
    await _run("drift_init",    _phases_drift_init())
    await _run("steady_circle", _phases_steady_circle())
    get_tree().quit()   # supports headless: godot --headless res://tests/benchmark.tscn

func _run(name: String, phases: Array):
    _reset_car()
    telemetry.start()
    for phase in phases:
        scripted.throttle = phase.throttle
        scripted.brake    = phase.brake
        scripted.steer    = phase.steer
        await _wait(phase.duration)
    telemetry.stop(name)

func _wait(seconds: float):
    var elapsed := 0.0
    while elapsed < seconds:
        await get_tree().physics_frame
        elapsed += get_physics_process_delta_time()

func _reset_car():
    car.global_position  = Vector3.ZERO
    car.global_rotation  = Vector3.ZERO
    car.linear_velocity  = Vector3.ZERO
    car.angular_velocity = Vector3.ZERO

# Scenario definitions — same phases as Python test_runner.py
func _phases_step_steer() -> Array:
    return [
        { "throttle": 0.6, "brake": 0.0, "steer": 0.0, "duration": 5.0 },
        { "throttle": 0.3, "brake": 0.0, "steer": 0.5, "duration": 4.0 },
    ]

func _phases_acceleration() -> Array:
    return [{ "throttle": 1.0, "brake": 0.0, "steer": 0.0, "duration": 15.0 }]

func _phases_braking() -> Array:
    return [
        { "throttle": 1.0, "brake": 0.0, "steer": 0.0, "duration": 8.0 },
        { "throttle": 0.0, "brake": 1.0, "steer": 0.0, "duration": 8.0 },
    ]

func _phases_drift_init() -> Array:
    return [
        { "throttle": 0.8, "brake": 0.0, "steer": 0.00, "duration": 4.0 },
        { "throttle": 1.0, "brake": 0.0, "steer": 0.70, "duration": 5.0 },
    ]

func _phases_steady_circle() -> Array:
    return [
        { "throttle": 0.8,  "brake": 0.0, "steer": 0.00, "duration": 3.0  },
        { "throttle": 0.45, "brake": 0.0, "steer": 0.40, "duration": 12.0 },
    ]
```

Run headless (no window, CI-friendly):
```bash
godot --headless --path /path/to/project res://tests/benchmark.tscn
# CSVs written automatically to user:// then copy to hp2_reference/data/godot_*.csv
```

### Test Scenario Phases (Shared Between Python and Godot)

Every scenario is defined as a sequence of `(throttle, brake, steer, duration)` phases. Both systems use **identical values**. This is the contract between the two sides — never change one without changing the other.

| Test | Phase | Throttle | Brake | Steer | Duration | Purpose |
|---|---|---|---|---|---|---|
| **step_steer** | 1 | 0.6 | 0.0 | 0.00 | 5.0s | Build to ~80 km/h straight |
| | 2 | 0.3 | 0.0 | 0.50 | 4.0s | Snap steer, measure response |
| **acceleration** | 1 | 1.0 | 0.0 | 0.00 | 15.0s | Full throttle from rest |
| **braking** | 1 | 1.0 | 0.0 | 0.00 | 8.0s | Build to ~120 km/h |
| | 2 | 0.0 | 1.0 | 0.00 | 8.0s | Full brake to stop |
| **drift_init** | 1 | 0.8 | 0.0 | 0.00 | 4.0s | Build to ~100 km/h |
| | 2 | 1.0 | 0.0 | 0.70 | 5.0s | Full throttle + steer |
| **steady_circle** | 1 | 0.8 | 0.0 | 0.00 | 3.0s | Build speed |
| | 2 | 0.45 | 0.0 | 0.40 | 12.0s | Lock into constant circle |

### CSV Schema Contract

Both systems must write CSVs with **exactly these column names** in this order. `compare.py` joins on column name — any mismatch silently produces wrong results.

| Column | Unit | Source in Python | Source in Godot |
|---|---|---|---|
| `t` | s | simulation clock | `Time.get_ticks_msec() / 1000.0` |
| `speed_kmh` | km/h | `car.speed * 3.6` | `car.speed * 3.6` |
| `speed_ms` | m/s | `car.speed` | `car.linear_velocity.length()` |
| `yaw_rate` | deg/s | `degrees(car.yaw_rate)` | `rad_to_deg(car.angular_velocity.y)` |
| `sideslip` | deg | `car.sideslip` | `car.sideslip_deg` |
| `heading` | deg | `degrees(car.heading)` | `rad_to_deg(car.rotation.y)` |
| `vx` | m/s | `car.vx` | `car.linear_velocity.x` |
| `vy` | m/s | `car.vy` | `car.linear_velocity.z` |
| `pos_x` | m | `car.x` | `car.global_position.x` |
| `pos_y` | m | `car.y` | `car.global_position.z` |
| `accel_long` | m/s² | `car.accel_long` | `car.longitudinal_accel` |
| `rpm` | rpm | `car.engine.rpm` | `car.engine_rpm` |
| `gear` | int | `car.dt_obj.current_gear` | `car.current_gear` |
| `shift_cut` | 0/1 | `int(car.engine.shift_cut_active)` | `int(car.shift_cut_active)` |
| `grip_FL/FR/RL/RR` | 0–1 | `wheel.grip_utilization` | `wheels[i].grip_utilization` |
| `load_FL/FR/RL/RR` | N | `wheel.normal_load` | `wheels[i].normal_load` |

---

## Part 1 — car_params.py (Constants from RE)

All values sourced directly from `hp2_car_physics_reverse_engineering.md`.  
Replace placeholder values with actual GlobalB dumps when available.

```python
# car_params.py
import numpy as np

# ── Global physics constants (from RE symbol table) ────────────────────────
GLOBAL_GRIP_SCALE   = 1.0     # fGpffffb3e0 — master friction scale
SPRING_SCALE        = 1.0     # fGpffffb3d0
DAMPER_SCALE        = 1.0     # fGpffffb3d4
SUSPENSION_LIMIT    = 0.15    # fGpffffb3cc — max compression (m)
SHIFT_CUT_FACTOR    = 0.35    # fGpffffafb4 — torque fraction during shift cut
SHIFT_CUT_DURATION  = 0.4     # seconds (from timer analysis)
REV_LIMITER_DRAG    = 0.5     # fGpffffafb0
SIDESLIP_THRESHOLD  = 12.0    # fGpffff8418 — degrees, oversteer assist trigger
OVERSTEER_TORQUE    = 20.0    # Nm applied to outer rear wheel
ANTI_DIVE_COEFF     = 0.08    # fGpffff83d0
STEER_SCALE         = 0.00004 # fGpffff8470 — int16 → radians
AUTO_BRAKE_BASE     = 0.05    # fGpffffa744
AWD_REVERSE_DRAG    = 0.7     # fGpffff8a44

# ── Surface friction table (from DAT_00318c14, stride 0x90) ────────────────
SURFACE_MU = {
    "asphalt": 1.00,
    "dirt":    0.70,
    "grass":   0.50,
    "gravel":  0.60,
    "ice":     0.20,
}

# ── Example car: Ferrari 360 Modena (RWD) ──────────────────────────────────
# Fill from GlobalB dump or RE estimates
CAR_FERRARI = {
    "mass":              1450.0,    # kg
    "inertia_yaw":       2200.0,    # kg·m² (Izz)
    "wheelbase":         2.60,      # m
    "track_front":       1.60,      # m
    "track_rear":        1.58,      # m
    "cg_height":         0.42,      # m
    "cg_bias_front":     0.42,      # fraction of weight on front axle at rest
    "wheel_radius":      0.32,      # m
    "front_drive_frac":  0.00,      # RWD
    "rear_drive_frac":   1.00,
    "final_drive":       3.91,
    "gear_ratios":       [-3.46, 3.15, 2.02, 1.43, 1.13, 0.93, 0.76],
    # index 0 = reverse, 1 = 1st, ...
    "max_rpm":           8500.0,
    "downforce_coeff":   0.25,      # aero
    "drag_coeff":        0.38,
    "spring_rate":       28000.0,   # N/m per wheel
    "damper_rate":       3500.0,    # N·s/m per wheel
    "brake_bias_front":  0.65,      # fraction of brake force to front
    "torque_curve": np.array([      # [rpm_normalized, Nm]
        [0.00,  80],
        [0.10, 160],
        [0.20, 280],
        [0.30, 340],
        [0.40, 380],
        [0.55, 400],
        [0.70, 370],
        [0.85, 310],
        [1.00, 200],
    ]),
    "friction_curve": np.array([    # [rpm_normalized, Nm friction drag]
        [0.0,  20],
        [0.5,  35],
        [1.0,  60],
    ]),
}
```

---

## Part 2 — hp2_reference.py (The Model)

```python
# hp2_reference.py
import numpy as np
from car_params import *

# ═══════════════════════════════════════════════════════════════════════════
# ENGINE
# ═══════════════════════════════════════════════════════════════════════════

class Engine:
    def __init__(self, params: dict):
        self.torque_curve   = params["torque_curve"]
        self.friction_curve = params["friction_curve"]
        self.max_rpm        = params["max_rpm"]
        self.rpm            = 800.0
        self.shift_cut_active = False
        self.shift_cut_timer  = 0.0
        self.throttle_scale   = 1.0   # becomes 3.0 with nitrous

    def get_net_torque(self, throttle: float) -> float:
        rpm_n = np.clip(self.rpm / self.max_rpm, 0.0, 1.0)
        peak  = np.interp(rpm_n, self.torque_curve[:, 0], self.torque_curve[:, 1])
        peak *= self.throttle_scale
        if self.shift_cut_active:
            peak *= SHIFT_CUT_FACTOR
        if self.rpm >= self.max_rpm - 100.0:
            peak = -REV_LIMITER_DRAG * abs(peak)
        friction = np.interp(rpm_n, self.friction_curve[:, 0], self.friction_curve[:, 1])
        net = peak * throttle - friction * (1.0 - throttle)
        return net

    def update(self, dt: float, wheel_angular_vel: float, gear_ratio: float):
        # RPM from driven wheel speed through gearbox
        target_rpm = abs(wheel_angular_vel * gear_ratio * 60.0 / (2.0 * np.pi))
        target_rpm = np.clip(target_rpm, 800.0, self.max_rpm * 1.05)
        # Smooth RPM tracking (first-order lag)
        self.rpm += (target_rpm - self.rpm) * min(1.0, dt * 15.0)

        if self.shift_cut_active:
            self.shift_cut_timer += dt
            if self.shift_cut_timer >= SHIFT_CUT_DURATION:
                self.shift_cut_active = False
                self.shift_cut_timer  = 0.0

    def trigger_shift_cut(self):
        self.shift_cut_active = True
        self.shift_cut_timer  = 0.0


# ═══════════════════════════════════════════════════════════════════════════
# DRIVETRAIN
# ═══════════════════════════════════════════════════════════════════════════

class DriveTrain:
    def __init__(self, params: dict, engine: Engine):
        self.engine          = engine
        self.gear_ratios     = params["gear_ratios"]
        self.final_drive     = params["final_drive"]
        self.front_frac      = params["front_drive_frac"]
        self.rear_frac       = params["rear_drive_frac"]
        self.wheel_radius    = params["wheel_radius"]
        self.current_gear    = 1           # 1 = 1st gear
        self.auto_shift_timer = 0.0

        # Pre-compute shift points (simplified: shift at 80% and 40% of max RPM)
        self.upshift_rpm   = engine.max_rpm * 0.82
        self.downshift_rpm = engine.max_rpm * 0.40

    @property
    def effective_ratio(self) -> float:
        return self.gear_ratios[self.current_gear] * self.final_drive

    def update_auto_shift(self, dt: float, speed_ms: float):
        self.auto_shift_timer += dt
        if self.auto_shift_timer < 0.5:   # 0.5s minimum between shifts
            return
        if self.engine.rpm > self.upshift_rpm and self.current_gear < len(self.gear_ratios) - 1:
            self.current_gear += 1
            self.engine.trigger_shift_cut()
            self.auto_shift_timer = 0.0
        elif self.engine.rpm < self.downshift_rpm and self.current_gear > 1:
            self.current_gear -= 1
            self.auto_shift_timer = 0.0

    def get_wheel_torque(self, throttle: float) -> dict:
        """Returns torque at each wheel in Nm."""
        engine_torque = self.engine.get_net_torque(throttle)
        shaft_torque  = engine_torque * abs(self.effective_ratio)
        return {
            "FL": shaft_torque * self.front_frac * 0.5,
            "FR": shaft_torque * self.front_frac * 0.5,
            "RL": shaft_torque * self.rear_frac  * 0.5,
            "RR": shaft_torque * self.rear_frac  * 0.5,
        }


# ═══════════════════════════════════════════════════════════════════════════
# WHEEL (spring-damper + friction circle)
# ═══════════════════════════════════════════════════════════════════════════

class Wheel:
    def __init__(self, name: str, params: dict, surface: str = "asphalt"):
        self.name            = name
        self.radius          = params["wheel_radius"]
        self.spring_rate     = params["spring_rate"]
        self.damper_rate     = params["damper_rate"]
        self.surface_mu      = SURFACE_MU[surface]
        self.normal_load     = 0.0         # set each frame by weight distribution
        self.angular_vel     = 0.0         # rad/s
        self.drive_torque    = 0.0
        self.brake_torque    = 0.0
        self.lambda_long     = 0.0         # longitudinal contact impulse
        self.lambda_lat      = 0.0         # lateral contact impulse
        self.grip_utilization = 0.0
        self.is_grounded     = True

    def compute_contact_forces(self, slip_long: float, slip_lat: float, dt: float):
        """
        Friction circle: clamp sqrt(Fx²+Fz²) ≤ μ·Fn
        Matches FUN_001a4930 + FUN_001a4ee0 from RE.
        """
        speed = np.sqrt(slip_long**2 + slip_lat**2)
        if speed < 1e-5 or not self.is_grounded:
            self.lambda_long = 0.0
            self.lambda_lat  = 0.0
            self.grip_utilization = 0.0
            return

        max_grip = GLOBAL_GRIP_SCALE * dt * self.normal_load * self.surface_mu
        scale    = min(1.0, max_grip / speed)

        self.lambda_long     = slip_long * scale
        self.lambda_lat      = -slip_lat * scale
        self.grip_utilization = np.clip((speed * scale) / (max_grip + 1e-6), 0.0, 1.0)

    def update_angular_vel(self, dt: float):
        """Simple wheel spin model — net torque → angular acceleration."""
        inertia    = 1.8     # kg·m² — wheel rotational inertia estimate
        net_torque = self.drive_torque - self.brake_torque - self.lambda_long * self.radius
        self.angular_vel += (net_torque / inertia) * dt
        self.angular_vel  = np.clip(self.angular_vel, -300.0, 300.0)


# ═══════════════════════════════════════════════════════════════════════════
# WEIGHT DISTRIBUTION
# ═══════════════════════════════════════════════════════════════════════════

def compute_normal_loads(params: dict, accel_long: float, speed: float) -> dict:
    """
    Computes per-wheel normal load accounting for longitudinal weight transfer
    and aerodynamic downforce.
    Matches FUN_001375f0 and FUN_001add70 from RE.
    """
    mass        = params["mass"]
    g           = 9.81
    wb          = params["wheelbase"]
    cg_h        = params["cg_height"]
    cg_front    = params["cg_bias_front"]
    aero        = params["downforce_coeff"] * speed**2 * 0.5

    static_front = mass * g * (1.0 - cg_front)
    static_rear  = mass * g * cg_front

    # Longitudinal transfer: anti-dive coefficient from RE
    transfer = mass * accel_long * cg_h / wb * ANTI_DIVE_COEFF * 8.0

    front_total = static_front - transfer + aero * 0.45
    rear_total  = static_rear  + transfer + aero * 0.55

    front_total = max(front_total, 0.0)
    rear_total  = max(rear_total,  0.0)

    return {
        "FL": front_total * 0.5,
        "FR": front_total * 0.5,
        "RL": rear_total  * 0.5,
        "RR": rear_total  * 0.5,
    }


# ═══════════════════════════════════════════════════════════════════════════
# STEERING (Ackermann + sideslip)
# ═══════════════════════════════════════════════════════════════════════════

def ackermann_angles(steer_input: float, params: dict) -> tuple:
    """
    True Ackermann: inner wheel turns more than outer.
    steer_input: -1.0 (full left) to +1.0 (full right)
    Returns (left_wheel_angle_rad, right_wheel_angle_rad)
    """
    max_angle = np.radians(30.0)   # max physical steer angle
    base      = steer_input * max_angle
    wb        = params["wheelbase"]
    tw        = params["track_front"]

    if abs(base) < 1e-4:
        return 0.0, 0.0

    # Ackermann correction: inner = atan(wb / (wb/tan(base) - tw/2))
    turn_radius = wb / np.tan(abs(base)) if abs(base) > 1e-3 else 1e6
    inner = np.arctan(wb / (turn_radius - tw * 0.5)) * np.sign(base)
    outer = np.arctan(wb / (turn_radius + tw * 0.5)) * np.sign(base)
    return (inner, outer) if base > 0 else (outer, inner)  # FL, FR


def compute_sideslip(vx: float, vy: float, heading: float) -> float:
    """
    Sideslip = velocity heading - body heading.
    Matches FUN_001c08d0 from RE.
    vx, vy: world-space velocity
    heading: body heading angle (rad)
    """
    speed = np.sqrt(vx**2 + vy**2)
    if speed < 5.0 / 3.6:   # below ~5 km/h, return 0 (matches RE threshold)
        return 0.0
    vel_heading = np.arctan2(vx, vy)
    slip = vel_heading - heading
    # Wrap to [-π, π]
    slip = (slip + np.pi) % (2 * np.pi) - np.pi
    return np.degrees(slip)


# ═══════════════════════════════════════════════════════════════════════════
# MAIN CAR STATE — PLANAR RIGID BODY
# ═══════════════════════════════════════════════════════════════════════════

class HP2Car:
    """
    Planar 4-wheel vehicle model implementing HP2 physics equations.
    State: (x, y, heading, vx, vy, yaw_rate)
    """

    def __init__(self, params: dict, surface: str = "asphalt"):
        self.p       = params
        self.engine  = Engine(params)
        self.dt_obj  = DriveTrain(params, self.engine)
        self.wheels  = {
            name: Wheel(name, params, surface)
            for name in ["FL", "FR", "RL", "RR"]
        }

        # Rigid body state
        self.x        = 0.0
        self.y        = 0.0
        self.heading  = 0.0    # rad
        self.vx       = 0.0    # world space m/s
        self.vy       = 0.0    # world space m/s
        self.yaw_rate = 0.0    # rad/s

        # Derived
        self.speed       = 0.0
        self.sideslip    = 0.0
        self.accel_long  = 0.0
        self.time        = 0.0

    # ── wheel positions in body frame ─────────────────────────────────────
    def _wheel_positions(self) -> dict:
        wb = self.p["wheelbase"]
        tf = self.p["track_front"] * 0.5
        tr = self.p["track_rear"]  * 0.5
        return {
            "FL": np.array([ tf,  wb * (1 - self.p["cg_bias_front"])]),
            "FR": np.array([-tf,  wb * (1 - self.p["cg_bias_front"])]),
            "RL": np.array([ tr, -wb * self.p["cg_bias_front"]]),
            "RR": np.array([-tr, -wb * self.p["cg_bias_front"]]),
        }

    def step(self, throttle: float, brake: float, steer: float, dt: float,
             substeps: int = 4):
        """
        Advance simulation by dt seconds.
        throttle, brake: 0.0–1.0
        steer: -1.0 (left) to +1.0 (right)
        substeps: internal sub-steps for stability (matches HP2's variable sub-stepping)
        """
        sub_dt = dt / substeps
        for _ in range(substeps):
            self._substep(throttle, brake, steer, sub_dt)
        self.time += dt

    def _substep(self, throttle: float, brake: float, steer: float, dt: float):
        mass   = self.p["mass"]
        iz     = self.p["inertia_yaw"]
        wb     = self.p["wheelbase"]
        cg_b   = self.p["cg_bias_front"]

        # ── 1. Update engine and drivetrain ─────────────────────────────
        avg_rear_w = (self.wheels["RL"].angular_vel + self.wheels["RR"].angular_vel) * 0.5
        self.engine.update(dt, avg_rear_w, self.dt_obj.effective_ratio)
        self.dt_obj.update_auto_shift(dt, self.speed)
        drive_torques = self.dt_obj.get_wheel_torque(throttle)

        # ── 2. Weight distribution ───────────────────────────────────────
        loads = compute_normal_loads(self.p, self.accel_long, self.speed)
        for name, w in self.wheels.items():
            w.normal_load  = loads[name]
            w.drive_torque = drive_torques[name]

        # ── 3. Brake torque distribution ─────────────────────────────────
        max_brake_torque = 3500.0   # Nm total (matched to stopping distance)
        for name in ["FL", "FR"]:
            self.wheels[name].brake_torque = brake * max_brake_torque * self.p["brake_bias_front"] * 0.5
        for name in ["RL", "RR"]:
            self.wheels[name].brake_torque = brake * max_brake_torque * (1 - self.p["brake_bias_front"]) * 0.5

        # ── 4. Ackermann steer angles ────────────────────────────────────
        fl_angle, fr_angle = ackermann_angles(steer, self.p)
        steer_angles = {"FL": fl_angle, "FR": fr_angle, "RL": 0.0, "RR": 0.0}

        # ── 5. Compute wheel contact forces ──────────────────────────────
        positions = self._wheel_positions()
        wheel_forces_x = 0.0   # world X (lateral)
        wheel_forces_y = 0.0   # world Y (longitudinal)
        yaw_torque     = 0.0

        for name, w in self.wheels.items():
            pos = positions[name]
            sa  = steer_angles[name]

            # Velocity at wheel contact point
            vx_w = self.vx - self.yaw_rate * pos[0]
            vy_w = self.vy + self.yaw_rate * pos[1]

            # Transform to wheel frame
            c, s    = np.cos(self.heading + sa), np.sin(self.heading + sa)
            v_long  = c * vy_w + s * vx_w    # forward in wheel frame
            v_lat   = -s * vy_w + c * vx_w   # lateral in wheel frame

            # Slip velocities
            v_wheel = w.angular_vel * w.radius
            slip_long = v_wheel - v_long
            slip_lat  = v_lat

            # Friction circle
            w.compute_contact_forces(slip_long, slip_lat, dt)
            w.update_angular_vel(dt)

            # Transform forces back to world frame
            fx_world = c * w.lambda_lat  - s * w.lambda_long
            fy_world = s * w.lambda_lat  + c * w.lambda_long

            wheel_forces_x += fx_world
            wheel_forces_y += fy_world
            yaw_torque += fx_world * pos[1] - fy_world * pos[0]

        # ── 6. Aerodynamic drag ───────────────────────────────────────────
        drag = -self.p["drag_coeff"] * self.speed**2 * np.sign(self.vy)

        # ── 7. Oversteer assist (from HP2_PhysicsCar_MoveUpdate RE) ───────
        self.sideslip = compute_sideslip(self.vx, self.vy, self.heading)
        if abs(self.sideslip) > SIDESLIP_THRESHOLD and self.speed > 80.0 / 3.6:
            outer = "RR" if self.sideslip > 0 else "RL"
            self.wheels[outer].drive_torque += OVERSTEER_TORQUE

        # ── 8. Integrate rigid body (Euler) ──────────────────────────────
        ax = wheel_forces_x / mass
        ay = (wheel_forces_y + drag) / mass

        prev_vy      = self.vy
        self.vx     += ax * dt
        self.vy     += ay * dt
        self.yaw_rate += (yaw_torque / iz) * dt

        # Heading from yaw rate
        self.heading += self.yaw_rate * dt

        # Position
        self.x += self.vx * dt
        self.y += self.vy * dt

        # Derived state
        self.speed      = np.sqrt(self.vx**2 + self.vy**2)
        self.accel_long = (self.vy - prev_vy) / dt
```

---

## Part 3 — test_runner.py (Standardized Scenarios)

Each test runs the car with a fixed programmatic input sequence and returns a time-series DataFrame. These are the exact scenarios Godot must also export CSVs for.

```python
# test_runner.py
import numpy as np
import pandas as pd
from hp2_reference import HP2Car
from car_params import CAR_FERRARI

DT      = 1.0 / 60.0   # 60 Hz — match Godot physics tick
SURFACE = "asphalt"


def _run(car: HP2Car, input_fn, duration: float) -> pd.DataFrame:
    """Drive the car with input_fn(t) → (throttle, brake, steer) for `duration` seconds."""
    rows = []
    t = 0.0
    while t <= duration:
        throttle, brake, steer = input_fn(t)
        car.step(throttle, brake, steer, DT)
        rows.append({
            "t":                t,
            "speed_kmh":        car.speed * 3.6,
            "speed_ms":         car.speed,
            "yaw_rate":         np.degrees(car.yaw_rate),
            "sideslip":         car.sideslip,
            "heading":          np.degrees(car.heading),
            "vx":               car.vx,
            "vy":               car.vy,
            "pos_x":            car.x,
            "pos_y":            car.y,
            "accel_long":       car.accel_long,
            "rpm":              car.engine.rpm,
            "gear":             car.dt_obj.current_gear,
            "shift_cut":        int(car.engine.shift_cut_active),
            "grip_FL":          car.wheels["FL"].grip_utilization,
            "grip_FR":          car.wheels["FR"].grip_utilization,
            "grip_RL":          car.wheels["RL"].grip_utilization,
            "grip_RR":          car.wheels["RR"].grip_utilization,
            "load_FL":          car.wheels["FL"].normal_load,
            "load_FR":          car.wheels["FR"].normal_load,
            "load_RL":          car.wheels["RL"].normal_load,
            "load_RR":          car.wheels["RR"].normal_load,
        })
        t += DT
    return pd.DataFrame(rows)


# ── Test A: Steady-State Circle ─────────────────────────────────────────────
def test_steady_circle(steer_pct=0.40, throttle=0.45, duration=12.0) -> pd.DataFrame:
    """Fixed steer + throttle. Measures equilibrium yaw rate and sideslip."""
    car = HP2Car(CAR_FERRARI, SURFACE)
    # Pre-accelerate to ~80 km/h straight
    for _ in range(int(3.0 / DT)):
        car.step(0.8, 0.0, 0.0, DT)
    # Now lock into circle
    return _run(car, lambda t: (throttle, 0.0, steer_pct), duration)


# ── Test B: Step Steer Response ────────────────────────────────────────────
def test_step_steer(steer_pct=0.50, speed_kmh=80.0, duration=4.0) -> pd.DataFrame:
    """
    Hold speed at ~80 km/h, then at t=0 snap to 50% steer.
    Measures response time, overshoot, settling.
    """
    car = HP2Car(CAR_FERRARI, SURFACE)
    target = speed_kmh / 3.6
    # Pre-stabilize speed
    for _ in range(int(4.0 / DT)):
        thr = 0.3 if car.speed < target else 0.0
        car.step(thr, 0.0, 0.0, DT)

    def inputs(t):
        return (0.3, 0.0, steer_pct)   # hold speed, full steer

    return _run(car, inputs, duration)


# ── Test C: Drift Initiation ───────────────────────────────────────────────
def test_drift_initiation(speed_kmh=100.0, duration=5.0) -> pd.DataFrame:
    """Full throttle + 70% steer simultaneously. Measures drift onset and self-correction."""
    car = HP2Car(CAR_FERRARI, SURFACE)
    # Pre-accelerate
    for _ in range(int(4.0 / DT)):
        car.step(0.8, 0.0, 0.0, DT)
    return _run(car, lambda t: (1.0, 0.0, 0.70), duration)


# ── Test D: 0–100 km/h Acceleration ──────────────────────────────────────
def test_acceleration(duration=15.0) -> pd.DataFrame:
    """Full throttle from rest. Measures time-to-100, shift points."""
    car = HP2Car(CAR_FERRARI, SURFACE)
    return _run(car, lambda t: (1.0, 0.0, 0.0), duration)


# ── Test E: Threshold Braking ─────────────────────────────────────────────
def test_braking(start_kmh=120.0, duration=8.0) -> pd.DataFrame:
    """Full brake from 120 km/h. Measures stopping distance and yaw deviation."""
    car = HP2Car(CAR_FERRARI, SURFACE)
    # Pre-accelerate
    while car.speed < start_kmh / 3.6:
        car.step(1.0, 0.0, 0.0, DT)
    return _run(car, lambda t: (0.0, 1.0, 0.0), duration)


# ── Test F: Steer Sweep (Lateral Force Curve) ──────────────────────────────
def test_lateral_force_curve(speed_kmh=80.0, duration=30.0) -> pd.DataFrame:
    """
    Very slowly sweep steer from 0 to full lock.
    Input variation doesn't matter — slow enough that timing is irrelevant.
    """
    car = HP2Car(CAR_FERRARI, SURFACE)
    while car.speed < speed_kmh / 3.6:
        car.step(0.6, 0.0, 0.0, DT)

    def inputs(t):
        steer = min(1.0, t / duration)   # 0 → 1 over full duration
        speed = speed_kmh / 3.6
        thr   = 0.3 if car.speed < speed else 0.0
        return (thr, 0.0, steer)

    return _run(car, inputs, duration)


if __name__ == "__main__":
    import os
    os.makedirs("data", exist_ok=True)
    print("Running HP2 reference tests...")
    test_steady_circle().to_csv("data/hp2_steady_circle.csv",    index=False)
    test_step_steer().to_csv("data/hp2_step_steer.csv",          index=False)
    test_drift_initiation().to_csv("data/hp2_drift_init.csv",    index=False)
    test_acceleration().to_csv("data/hp2_acceleration.csv",      index=False)
    test_braking().to_csv("data/hp2_braking.csv",                index=False)
    test_lateral_force_curve().to_csv("data/hp2_lat_curve.csv",  index=False)
    print("Done. CSVs written to data/")
```

---

## Part 4 — compare.py (All Metrics)

```python
# compare.py
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
from scipy.signal import welch, correlate
from scipy.stats  import wasserstein_distance

try:
    from dtaidistance import dtw
    HAS_DTW = True
except ImportError:
    HAS_DTW = False


# ═══════════════════════════════════════════════════════════════════════════
# SCALAR METRIC EXTRACTORS
# (one number per test run — easy to put in a table)
# ═══════════════════════════════════════════════════════════════════════════

def metric_step_steer(df: pd.DataFrame) -> dict:
    """Extract response time, overshoot, settling time from step steer test."""
    yaw = df["yaw_rate"].values
    t   = df["t"].values

    peak_yaw    = yaw.max()
    steady_yaw  = yaw[-int(len(yaw) * 0.2):].mean()   # last 20% = steady state

    # Response time: first frame where yaw reaches 90% of peak
    threshold = 0.9 * peak_yaw
    idx_90    = np.argmax(yaw >= threshold)
    response_ms = t[idx_90] * 1000.0 if idx_90 > 0 else float("nan")

    # Overshoot
    overshoot_pct = ((peak_yaw - steady_yaw) / (steady_yaw + 1e-6)) * 100.0

    # Settling time: last time yaw is outside ±5% of steady state
    band     = 0.05 * abs(steady_yaw)
    outside  = np.where(np.abs(yaw - steady_yaw) > band)[0]
    settle_s = t[outside[-1]] if len(outside) > 0 else 0.0

    return {
        "yaw_peak_degs":       round(float(peak_yaw),    2),
        "yaw_steady_degs":     round(float(steady_yaw),  2),
        "response_time_ms":    round(float(response_ms), 1),
        "overshoot_pct":       round(float(overshoot_pct), 1),
        "settling_time_s":     round(float(settle_s),    3),
    }


def metric_acceleration(df: pd.DataFrame) -> dict:
    """Extract 0-100 time and shift events."""
    t      = df["t"].values
    speed  = df["speed_kmh"].values
    gears  = df["gear"].values

    idx_100 = np.argmax(speed >= 100.0)
    t_100   = t[idx_100] if idx_100 > 0 else float("nan")

    # Gear shifts: index where gear changes
    shifts   = np.where(np.diff(gears) > 0)[0]
    shift_ts = [round(float(t[i]), 3) for i in shifts]

    return {
        "time_to_100_s":   round(float(t_100), 2),
        "shift_count":     len(shifts),
        "shift_times_s":   shift_ts,
    }


def metric_braking(df: pd.DataFrame) -> dict:
    """Stopping distance and yaw deviation during braking."""
    pos_x  = df["pos_x"].values
    pos_y  = df["pos_y"].values
    speed  = df["speed_ms"].values
    yaw    = df["heading"].values

    idx_stop     = np.argmax(speed < 0.5)
    if idx_stop == 0:
        idx_stop = len(speed) - 1

    dist_x = pos_x[idx_stop] - pos_x[0]
    dist_y = pos_y[idx_stop] - pos_y[0]
    stop_distance = np.sqrt(dist_x**2 + dist_y**2)

    yaw_deviation = np.degrees(np.abs(yaw[:idx_stop] - yaw[0]).max())

    return {
        "stopping_distance_m": round(float(stop_distance), 1),
        "max_yaw_deviation_deg": round(float(yaw_deviation), 2),
    }


def metric_drift(df: pd.DataFrame) -> dict:
    """Drift onset frame, peak sideslip, self-correction."""
    slip   = df["sideslip"].values
    t      = df["t"].values

    idx_onset  = np.argmax(np.abs(slip) > 15.0)
    onset_ms   = t[idx_onset] * 1000.0 if idx_onset > 0 else float("nan")
    peak_slip  = float(np.abs(slip).max())

    # Self-correction: does slip come back below 10° after peaking?
    peak_idx      = np.argmax(np.abs(slip))
    after_peak    = np.abs(slip[peak_idx:])
    corrected     = bool(np.any(after_peak < 10.0))

    return {
        "drift_onset_ms":     round(float(onset_ms), 1),
        "peak_sideslip_deg":  round(peak_slip, 1),
        "self_corrects":      corrected,
    }


def metric_steady_circle(df: pd.DataFrame) -> dict:
    """Equilibrium yaw rate and sideslip on steady-state circle."""
    steady = df.tail(int(len(df) * 0.3))   # last 30% = steady state
    return {
        "yaw_rate_steady_degs":  round(float(steady["yaw_rate"].mean()), 2),
        "sideslip_steady_deg":   round(float(steady["sideslip"].mean()),  2),
        "lateral_accel_ms2":     round(float((steady["yaw_rate"] * steady["speed_ms"] / 57.3).mean()), 2),
    }


# ═══════════════════════════════════════════════════════════════════════════
# SIGNAL-LEVEL METRICS
# (compare full time-series: hp2 vs godot)
# ═══════════════════════════════════════════════════════════════════════════

FS = 60.0   # sample rate Hz


def rmse(a: np.ndarray, b: np.ndarray) -> float:
    n = min(len(a), len(b))
    return float(np.sqrt(np.mean((a[:n] - b[:n])**2)))


def normalized_rmse(a: np.ndarray, b: np.ndarray) -> float:
    return rmse(a, b) / (np.std(b) + 1e-6)


def cross_correlation_lag_ms(a: np.ndarray, b: np.ndarray) -> float:
    n    = min(len(a), len(b))
    corr = correlate(a[:n], b[:n], mode="full")
    lag  = np.argmax(corr) - (n - 1)
    return float(lag / FS * 1000.0)


def dtw_distance(a: np.ndarray, b: np.ndarray) -> float:
    if not HAS_DTW:
        return float("nan")
    n = min(len(a), len(b))
    return float(dtw.distance(a[:n].astype(np.double), b[:n].astype(np.double)))


def psd_centroid(signal: np.ndarray) -> float:
    f, p = welch(signal, fs=FS, nperseg=min(256, len(signal)//2))
    return float(np.sum(f * p) / (np.sum(p) + 1e-12))


def psd_peak_freq(signal: np.ndarray) -> float:
    f, p = welch(signal, fs=FS, nperseg=min(256, len(signal)//2))
    return float(f[np.argmax(p)])


def compare_signals(hp2_df: pd.DataFrame, godot_df: pd.DataFrame,
                    signals: list) -> pd.DataFrame:
    """
    For each signal, compute all comparison metrics.
    Returns a DataFrame with one row per signal.
    """
    rows = []
    for sig in signals:
        a = hp2_df[sig].values.astype(float)
        b = godot_df[sig].values.astype(float) if sig in godot_df else np.zeros_like(a)
        rows.append({
            "signal":          sig,
            "rmse":            round(rmse(a, b), 4),
            "nrmse":           round(normalized_rmse(a, b), 4),
            "lag_ms":          round(cross_correlation_lag_ms(a, b), 1),
            "dtw":             round(dtw_distance(a, b), 2),
            "wasserstein":     round(wasserstein_distance(a, b), 4),
            "psd_centroid_hp2":   round(psd_centroid(a), 3),
            "psd_centroid_godot": round(psd_centroid(b), 3),
            "psd_peak_hp2_hz":    round(psd_peak_freq(a), 3),
            "psd_peak_godot_hz":  round(psd_peak_freq(b), 3),
        })
    return pd.DataFrame(rows)


# ═══════════════════════════════════════════════════════════════════════════
# COMPOSITE SCORE
# ═══════════════════════════════════════════════════════════════════════════

def closeness_score(hp2_df: pd.DataFrame, godot_df: pd.DataFrame) -> float:
    """
    Single number 0.0–1.0. Weighted combination of all signal metrics.
    0.90+ = essentially identical. <0.60 = noticeably different.
    """
    scores = {}
    sigs   = ["yaw_rate", "sideslip", "speed_ms", "grip_FL", "grip_RL"]

    for sig in sigs:
        if sig not in hp2_df or sig not in godot_df:
            continue
        a = hp2_df[sig].values.astype(float)
        b = godot_df[sig].values.astype(float)
        scores[f"nrmse_{sig}"] = max(0.0, 1.0 - normalized_rmse(a, b))

    # Lag penalty on yaw rate
    if "yaw_rate" in hp2_df and "yaw_rate" in godot_df:
        lag = abs(cross_correlation_lag_ms(
            hp2_df["yaw_rate"].values, godot_df["yaw_rate"].values))
        scores["lag_yaw"]    = max(0.0, 1.0 - lag / 100.0)

    # PSD centroid match on yaw rate
    if "yaw_rate" in hp2_df and "yaw_rate" in godot_df:
        diff = abs(psd_centroid(hp2_df["yaw_rate"].values) -
                   psd_centroid(godot_df["yaw_rate"].values))
        scores["psd_yaw"]   = max(0.0, 1.0 - diff / 3.0)

    # Wasserstein on sideslip distribution
    if "sideslip" in hp2_df and "sideslip" in godot_df:
        w = wasserstein_distance(hp2_df["sideslip"].values, godot_df["sideslip"].values)
        scores["dist_slip"] = max(0.0, 1.0 - w / 15.0)

    weights = {
        "nrmse_yaw_rate": 0.25,
        "nrmse_sideslip": 0.20,
        "nrmse_speed_ms": 0.10,
        "nrmse_grip_FL":  0.05,
        "nrmse_grip_RL":  0.05,
        "lag_yaw":        0.15,
        "psd_yaw":        0.10,
        "dist_slip":      0.10,
    }
    total = w_sum = 0.0
    for k, w in weights.items():
        if k in scores:
            total += scores[k] * w
            w_sum += w
    return round(total / w_sum, 3) if w_sum > 0 else 0.0


# ═══════════════════════════════════════════════════════════════════════════
# REPORT GENERATOR
# ═══════════════════════════════════════════════════════════════════════════

def full_report(test_name: str, hp2_csv: str, godot_csv: str,
                scalar_fn=None, save_plot: bool = True):
    hp2   = pd.read_csv(hp2_csv)
    godot = pd.read_csv(godot_csv)

    print(f"\n{'='*60}")
    print(f"  TEST: {test_name}")
    print(f"{'='*60}")

    # Scalar metrics comparison
    if scalar_fn:
        hp2_scalars   = scalar_fn(hp2)
        godot_scalars = scalar_fn(godot)
        print(f"\n{'Metric':<30} {'HP2':>12} {'Godot':>12} {'Δ%':>8}")
        print("-" * 65)
        for k in hp2_scalars:
            if isinstance(hp2_scalars[k], (int, float)):
                h = hp2_scalars[k]
                g = godot_scalars.get(k, float("nan"))
                pct = abs(g - h) / (abs(h) + 1e-6) * 100
                flag = " ✓" if pct < 10 else " ✗"
                print(f"  {k:<28} {h:>12.2f} {g:>12.2f} {pct:>7.1f}%{flag}")

    # Signal-level metrics
    sigs = ["yaw_rate", "sideslip", "speed_ms"]
    sigs = [s for s in sigs if s in hp2.columns and s in godot.columns]
    if sigs:
        sig_df = compare_signals(hp2, godot, sigs)
        print(f"\nSignal comparison:")
        print(sig_df.to_string(index=False))

    # Composite score
    score = closeness_score(hp2, godot)
    grade = "EXCELLENT" if score >= 0.90 else \
            "GOOD"      if score >= 0.75 else \
            "FAIR"      if score >= 0.60 else "POOR"
    print(f"\n  Closeness score: {score:.3f}  [{grade}]")

    # Plots
    if save_plot:
        import os
        os.makedirs("results", exist_ok=True)
        fig, axes = plt.subplots(len(sigs), 1, figsize=(12, 3 * len(sigs)))
        if len(sigs) == 1: axes = [axes]
        for ax, sig in zip(axes, sigs):
            ax.plot(hp2["t"],   hp2[sig],   label="HP2 (reference)", linewidth=2)
            ax.plot(godot["t"], godot[sig], label="Godot",           linewidth=1.5, linestyle="--")
            ax.set_ylabel(sig)
            ax.legend(loc="upper right")
            ax.grid(True, alpha=0.3)
        axes[-1].set_xlabel("Time (s)")
        fig.suptitle(f"{test_name} — Closeness: {score:.3f} [{grade}]")
        plt.tight_layout()
        fname = f"results/{test_name.lower().replace(' ', '_')}.png"
        plt.savefig(fname, dpi=150)
        print(f"  Plot saved: {fname}")
        plt.close()

    return score


# ═══════════════════════════════════════════════════════════════════════════
# ENTRY POINT
# ═══════════════════════════════════════════════════════════════════════════

if __name__ == "__main__":
    from test_runner import metric_step_steer, metric_acceleration, metric_braking, \
                            metric_drift, metric_steady_circle

    tests = [
        ("Step Steer",        "data/hp2_step_steer.csv",    "data/godot_step_steer.csv",    metric_step_steer),
        ("Acceleration",      "data/hp2_acceleration.csv",  "data/godot_acceleration.csv",  metric_acceleration),
        ("Braking",           "data/hp2_braking.csv",       "data/godot_braking.csv",       metric_braking),
        ("Drift Initiation",  "data/hp2_drift_init.csv",    "data/godot_drift_init.csv",    metric_drift),
        ("Steady Circle",     "data/hp2_steady_circle.csv", "data/godot_steady_circle.csv", metric_steady_circle),
    ]

    scores = []
    for name, hp2_f, godot_f, fn in tests:
        try:
            s = full_report(name, hp2_f, godot_f, scalar_fn=fn)
            scores.append(s)
        except FileNotFoundError as e:
            print(f"  Skipped {name}: {e}")

    if scores:
        print(f"\n{'='*60}")
        print(f"  OVERALL SCORE: {np.mean(scores):.3f}")
        print(f"{'='*60}")
```

---

## Part 5 — Godot Telemetry Exporter

This GDScript must be added to your Godot car scene so it produces CSVs with **the same column schema** as the Python reference model.

```gdscript
# TelemetryExporter.gd
# Attach to the same node as PhysicsController.gd

extends Node

var _active := false
var _rows: Array[PackedStringArray] = []

const HEADER = ["t", "speed_kmh", "speed_ms", "yaw_rate", "sideslip",
                "heading", "vx", "vy", "pos_x", "pos_y", "accel_long",
                "rpm", "gear", "shift_cut",
                "grip_FL", "grip_FR", "grip_RL", "grip_RR",
                "load_FL", "load_FR", "load_RL", "load_RR"]

func start():
    _rows.clear()
    _active = true

func stop(test_name: String):
    _active = false
    var path = "user://godot_%s.csv" % test_name
    var f = FileAccess.open(path, FileAccess.WRITE)
    f.store_csv_line(HEADER)
    for row in _rows:
        f.store_csv_line(row)
    f.close()
    print("Telemetry saved: ", path)
    # Also print OS path so you can copy to hp2_reference/data/
    print(OS.get_user_data_dir())

func record(t: float, car):
    if not _active:
        return
    var row: PackedStringArray = [
        str(snappedf(t, 0.0001)),
        str(snappedf(car.speed * 3.6, 0.01)),
        str(snappedf(car.speed, 0.001)),
        str(snappedf(rad_to_deg(car.angular_velocity.y), 0.01)),
        str(snappedf(car.sideslip_deg, 0.01)),
        str(snappedf(rad_to_deg(car.rotation.y), 0.01)),
        str(snappedf(car.linear_velocity.x, 0.001)),
        str(snappedf(car.linear_velocity.z, 0.001)),
        str(snappedf(car.global_position.x, 0.01)),
        str(snappedf(car.global_position.z, 0.01)),
        str(snappedf(car.longitudinal_accel, 0.001)),
        str(snappedf(car.engine_rpm, 0.1)),
        str(car.current_gear),
        str(int(car.shift_cut_active)),
        str(snappedf(car.wheels[0].grip_utilization, 0.001)),
        str(snappedf(car.wheels[1].grip_utilization, 0.001)),
        str(snappedf(car.wheels[2].grip_utilization, 0.001)),
        str(snappedf(car.wheels[3].grip_utilization, 0.001)),
        str(snappedf(car.wheels[0].normal_load, 0.1)),
        str(snappedf(car.wheels[1].normal_load, 0.1)),
        str(snappedf(car.wheels[2].normal_load, 0.1)),
        str(snappedf(car.wheels[3].normal_load, 0.1)),
    ]
    _rows.append(row)
```

---

## Part 6 — Metrics Reference Table

What each metric tells you and when to care about it:

| Metric | Unit | Target | Fail threshold | What it diagnoses |
|---|---|---|---|---|
| RMSE yaw_rate | deg/s | < 3.0 | > 8.0 | Overall cornering match |
| RMSE sideslip | deg | < 2.0 | > 5.0 | Drift behavior match |
| RMSE speed | m/s | < 0.5 | > 2.0 | Engine/braking power match |
| Lag yaw_rate | ms | < ±20 | > ±50 | Steering response timing |
| DTW yaw_rate | — | < 50 | > 200 | Shape of cornering response |
| Wasserstein sideslip | deg | < 2.0 | > 5.0 | How often and how far car drifts |
| PSD centroid yaw | Hz | < ±0.5 | > ±1.5 | Oscillation character (jitter vs smooth) |
| Response time | ms | ±20ms | > ±50ms | Steering feel |
| Overshoot | % | ±5pp | > ±15pp | Oscillation / stability feel |
| 0–100 time | s | ±0.3s | > ±1.0s | Engine power feel |
| Stop distance | m | ±5% | > ±15% | Braking power feel |
| Drift onset | ms | ±50ms | > ±150ms | Oversteer assist feel |
| Steady yaw rate | deg/s | ±10% | > ±25% | Grip level feel |
| Composite score | 0–1 | > 0.85 | < 0.70 | Overall fidelity |

---

## Part 7 — Workflow Summary

```
Step 1 — Generate HP2 reference CSVs
    cd hp2_reference/
    python test_runner.py
    → writes data/hp2_*.csv

Step 2 — Generate Godot CSVs
    In Godot, attach TelemetryExporter.gd
    Run each test scenario with identical programmatic inputs:
        - step_steer:   80 km/h → snap to 50% steer → hold 4s
        - acceleration: full throttle from rest → 15s
        - braking:      120 km/h → full brake → stop
        - drift_init:   100 km/h → full throttle + 70% steer → 5s
        - steady_circle: 80 km/h → 40% steer + 45% throttle → 12s
    Copy CSVs from Godot user:// to hp2_reference/data/godot_*.csv

Step 3 — Run comparison
    python compare.py
    → prints scalar comparison tables per test
    → prints signal metric tables per test
    → prints composite closeness score per test
    → saves overlay plots to results/*.png

Step 4 — Iterate
    Adjust Godot parameters, re-export CSVs, re-run compare.py
    Watch composite score. Target: > 0.85 across all 5 tests.
```

---

## Common Score Failures and Where to Look

| Score drops on | Likely problem | Parameter to adjust |
|---|---|---|
| Step steer RMSE + lag | Response time too slow or fast | Steering rack ratio, tire cornering stiffness |
| Drift initiation timing | Oversteer assist threshold wrong | `SIDESLIP_THRESHOLD` in your Godot impl |
| Acceleration speed curve | Torque curve shape wrong, wrong shift RPMs | Torque curve breakpoints, upshift RPM table |
| Steady circle yaw rate | Overall grip level wrong | `GLOBAL_GRIP_SCALE` equivalent |
| Braking stop distance | Brake torque magnitude wrong | `max_brake_torque`, `brake_bias_front` |
| PSD centroid mismatch | Physics sub-step count too low or damping wrong | Increase substeps, tune damper rate |
| Wasserstein sideslip high | Car drifts too much or too little overall | Oversteer assist torque magnitude |
