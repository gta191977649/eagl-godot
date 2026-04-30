# HP2 Car Physics Validation Guide

**Purpose:** Methods and metrics to validate how closely the Godot handling implementation matches the original NFS: Hot Pursuit 2 (PS2) handling feel.  
**Companion doc:** `hp2_car_physics_reverse_engineering.md` — contains all RE findings, struct layouts, and constants this document references.  
**Intended reader:** Agent or developer iterating on the Godot handling system.

---

## Overview

Validation is split into 6 layers, ordered from cheapest to most effort:

| Layer | Type | What it proves |
|---|---|---|
| 1 | Parameter fidelity | RE constants are implemented correctly |
| 2 | Kinematic benchmarks | Physics outputs match on standard maneuvers |
| 3 | Phase space analysis | Dynamics shape matches, not just endpoints |
| 4 | Perceptual / subjective | Human feel matches |
| 5 | Ground truth from emulator | Direct comparison against real HP2 data |
| 6 | Automated regression | Stays valid as code changes |

Run them in order. Layers 1–2 are required before moving to feel testing.

---

## Layer 1 — Parameter Fidelity

Binary pass/fail checks against the RE-found values. These confirm the implementation is correct before testing outputs.

| Check | Expected Value | How to Verify |
|---|---|---|
| Torque curve sample count | 9 points | Count breakpoints in your `torque_curve` resource |
| Torque curve shape | Max deviation < 5% from RE 9-point table | Plot `torque_curve.sample(t)` at 100 RPM steps, overlay against RE data |
| Friction curve sample count | 3 points | Count breakpoints in `friction_curve` resource |
| Shift-cut duration | 0.3–0.5 seconds | Log `shift_cut_timer` from upshift to `shift_cut_active = false` |
| Oversteer assist trigger angle | ~10–15 degrees sideslip | Log sideslip at the frame `outer_rear_wheel.drive_torque` changes |
| Friction circle clamp | `grip_utilization` saturates at 1.0, never exceeds | Log `grip_utilization` per wheel during hard cornering |
| Front load increase on brake | Verify sign | Log `wheel[FL].normal_load` and `wheel[RL].normal_load` during threshold brake |
| Rear load increase on throttle | Verify sign | Log same during full throttle launch |
| Surface friction ratios | asphalt ~1.0, dirt ~0.7, grass ~0.5 | Measure stopping distance from 100 km/h on each surface, compare ratios |
| Drive fraction (RWD car) | `front_drive_frac ≈ 0.0`, `rear_drive_frac ≈ 1.0` | Print from init |
| Final drive ratio | Matches GlobalB value for the car under test | Print from init |

**Pass criteria:** All checks pass before proceeding to Layer 2.

---

## Layer 2 — Kinematic Benchmarks

Standardized input sequences, recorded outputs, numerical comparison. Run identical inputs on both HP2 (emulator capture — see Layer 5) and Godot, then diff the CSVs.

### Test A — Steady-State Circle

**Setup:** Flat surface (asphalt), fixed throttle to hold ~80 km/h, steering locked at 40% lock. Run for 10 seconds after reaching steady state.

**Record:** equilibrium yaw rate (deg/s), lateral acceleration (m/s²), sideslip angle (deg).

**Pass criteria:**
- Yaw rate within ±10% of HP2 capture
- Sideslip angle at steady state within ±3°

**What it reveals:** Cornering balance (under/oversteer), grip level tuning.

---

### Test B — Step Steer Response

**Setup:** 80 km/h constant speed (hold with throttle). At t=0, snap steering to 50% lock and hold for 3 seconds.

**Record:** yaw rate (deg/s) at 60 Hz from t=0 to t=3.

**Key metrics:**
- **Response time** — time from input to 90% of peak yaw rate
- **Overshoot %** — `(peak_yaw - steady_yaw) / steady_yaw * 100`
- **Settling time** — time until yaw rate stays within ±5% of steady value

**Pass criteria:**
- Response time within ±20ms of HP2
- Overshoot % within ±5 percentage points
- Settling time within ±100ms

**Why this matters:** This single test is the highest-correlation metric for perceived steering feel. A 50ms response time difference is noticeable to most players.

---

### Test C — Drift Initiation

**Setup:** 100 km/h, full throttle + 70% steering input applied simultaneously.

**Record:** time from input to sideslip > 15°, peak sideslip angle reached, whether car self-corrects (sideslip returns below 10° without player input).

**Key metrics:**
- **Drift onset time** — frames from input to sideslip crossing 15°
- **Self-correction** — does the oversteer assist fire and stabilize the car?
- **Equilibrium drift angle** — sustained sideslip angle with full throttle held

**Pass criteria:**
- Drift onset within ±3 frames (±50ms at 60 fps) of HP2
- Self-correction fires at same sideslip angle as HP2 (~10–15°)
- Equilibrium drift angle within ±5° of HP2

**What it reveals:** Oversteer assist calibration — the defining characteristic of HP2 feel.

---

### Test D — 0–100 km/h Acceleration

**Setup:** Standing start, full throttle, automatic gearbox.

**Record:** speed (km/h) at 60 Hz from t=0 to 100 km/h. Also record gear and RPM.

**Key metrics:**
- **Total time to 100 km/h** — within ±0.3s of HP2
- **Shift point RPMs** — within ±200 RPM of HP2 auto-shift table
- **Speed curve shape** — plot both on same graph, visually overlap
- **Shift-cut dip** — visible torque reduction at each upshift, matching duration

**Pass criteria:**
- 0–100 time within ±0.3s
- Shift-cut visible and timed correctly (0.3–0.5s dip)

---

### Test E — Threshold Braking

**Setup:** 120 km/h, full brake applied at t=0.

**Record:** speed at 60 Hz, yaw deviation (degrees from straight), which wheels lock first.

**Key metrics:**
- **Stopping distance** — within ±5% of HP2
- **Yaw deviation** — should stay under ±3° (HP2 brakes straight)
- **Lock sequence** — rear should lock before front on full brake

**Pass criteria:**
- Stopping distance within ±5%
- No spin-out under straight-line braking

---

## Layer 3 — Phase Space and Transfer Function Analysis

Reveals whether the *dynamics shape* matches, not just scalar endpoints. Use after passing Layer 2.

### Yaw Rate vs Lateral Acceleration Phase Plot

**How:** During a slalom run, record `(lateral_accel_ms2, yaw_rate_degs)` at 60 Hz. Plot as XY scatter.

**What to look for:** Both HP2 and Godot should trace the same loop shape. HP2 has a characteristic "banana" curve due to fast weight transfer. If your curve is rounder, weight transfer is too slow. If it's more figure-8, damping is too low.

---

### Slip Angle vs Lateral Force (Per Wheel)

**How:** At constant 80 km/h, slowly sweep steering from 0 to full lock over 5 seconds. Record per-wheel slip angle and lateral contact impulse (`lambda_y`).

**What to look for:**
- Linear region slope — should match RE Pacejka curve segment 0
- Peak force angle — where the curve peaks before dropping
- Post-peak drop rate — gradual (HP2) vs sharp (snap oversteer)

**Pass criteria:** Peak occurs within ±2° of HP2 curve, post-peak slope within ±20%.

---

### Throttle-Steer Coupling

**How:** Mid-corner at steady state, step throttle from 20% to 80% in one frame.

**Record:** Yaw rate response over 2 seconds.

**What to look for:**
- RWD car: yaw rate should *increase* (car rotates on throttle)
- FWD car: yaw rate should *decrease* (car pushes wide)
- AWD car: neutral or slight rotation depending on front/rear bias

If coupling direction or magnitude is wrong, the `front_drive_frac` / `rear_drive_frac` values need adjustment.

---

## Layer 4 — Perceptual / Subjective Validation

Numerical metrics can all pass while feel diverges. This layer is required for final sign-off.

### Absolute Category Rating (ACR) — 1 to 7 Scale

Have testers rate each dimension for both systems (without labeling which is which):

| Dimension | 1 (worst) | 7 (best) | What it captures |
|---|---|---|---|
| Steering precision | Vague/numb | Exact response | Does the car go where you point it? |
| Drift controllability | Unpredictable | Fully controllable | Can you hold a drift angle predictably? |
| Limit predictability | Sudden snap | Gradual warning | Do you feel when you're about to lose it? |
| Recovery naturalness | Fight to recover | Intuitive catch | When you lose it, does recovery feel right? |
| Responsiveness | Sluggish | Immediate | Does the car respond instantly to inputs? |

**Scoring:** Compute the mean per dimension. Godot should be within ±0.5 points of HP2 on each dimension.

---

### Blind A/B Protocol

1. Label builds as "Car A" and "Car B" — tester does not know which is HP2 and which is Godot
2. Run 3 laps on the same circuit with each
3. Ask two questions:
   - "Which felt more like HP2?" (binary choice)
   - "Describe one specific difference you noticed"
4. Tally results

**Pass criteria:**
- 60% or more of testers cannot distinguish = acceptable fidelity
- 80% or more cannot distinguish = excellent fidelity

**Important:** Use testers who know HP2. Unfamiliar players cannot judge closeness.

---

### Just-Noticeable Difference (JND) Test

Use this to learn which parameters matter most perceptually:

1. Start with Godot at exact RE parameter values (Layer 1 pass)
2. Detune one variable at a time by increasing amounts (10%, 20%, 50%)
3. For each level, run blind A/B against baseline
4. Find the % change where 75% of testers notice a difference = JND for that parameter

**Parameters to test (suggested order):**

| Parameter | Why it matters |
|---|---|
| Oversteer assist trigger angle | Core HP2 drift identity |
| Step steer response time | Most perceptible steering feel driver |
| Shift-cut duration | Gear-change feel |
| Steady-state yaw rate (grip level) | Overall speed and corner feel |
| Weight transfer speed | Body roll and balance feel |

Parameters with low JND (noticeable at <15% change) are high priority to match precisely. Parameters with high JND (only noticeable at >40% change) have tuning slack.

---

## Layer 5 — Ground Truth Extraction from HP2 Emulator

The most reliable comparison source. Captures actual HP2 physics state at runtime.

### Setup (PCSX2 + PINE or Cheat Engine)

PCSX2 exposes a memory API via the PINE protocol (Unix socket or TCP). Alternatively use the built-in Cheat Engine integration.

**Key memory addresses to watch** (base addresses from RE, may need ASLR adjustment per session):

| Signal | Address Pattern | Notes |
|---|---|---|
| Speed (m/s) | `StateData_base + 0x00` | Float |
| Angular velocity Y (yaw rate) | `RigidBody_base + 0x90 + 0x04` | Vec4 Y component |
| Sideslip angle | Computed: `heading_fixed - velocity_heading` | See `FUN_001c08d0` |
| Wheel normal load FL | `Wheel[0]_ptr + 0x158` | Float |
| Wheel normal load FR | `Wheel[1]_ptr + 0x158` | Float |
| Wheel normal load RL | `Wheel[2]_ptr + 0x158` | Float |
| Wheel normal load RR | `Wheel[3]_ptr + 0x158` | Float |
| Grip utilization FL | `Wheel[0]_ptr + 0x168` | Float, 0..1 |
| Grip utilization FR | `Wheel[1]_ptr + 0x168` | Float, 0..1 |
| Throttle input | `car_data + 0x214` | Float |
| Brake input | `car_data + 0x218` | Float |
| Steer input | `car_data + 0x210` | Int16 |
| Current gear | `car_data + 0x224` | Int |
| Engine RPM | `Engine_base + 0x0C` | Float |

**Capture script outline (Python + PINE):**
```python
import socket, struct, csv, time

PINE_ADDR = "/tmp/pcsx2.sock"  # or TCP 28011
LOG_HZ = 60
LOG_DURATION = 30  # seconds

def read_float(sock, address):
    # PINE read request: type=0 (read), size=4, address
    req = struct.pack("<BII", 0, address, 4)
    sock.send(req)
    return struct.unpack("<f", sock.recv(4))[0]

with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
    s.connect(PINE_ADDR)
    with open("hp2_ground_truth.csv", "w") as f:
        writer = csv.writer(f)
        writer.writerow(["t", "speed", "yaw_rate", "sideslip",
                         "load_fl", "load_fr", "load_rl", "load_rr",
                         "grip_fl", "grip_fr", "grip_rl", "grip_rr",
                         "throttle", "brake", "steer", "gear", "rpm"])
        for i in range(LOG_DURATION * LOG_HZ):
            row = [i / LOG_HZ,
                   read_float(s, SPEED_ADDR),
                   read_float(s, YAW_ADDR),
                   # ... etc
                   ]
            writer.writerow(row)
            time.sleep(1.0 / LOG_HZ)
```

### Godot Telemetry (match the same CSV schema)

```gdscript
# In PhysicsController.gd
var _log: Array = []
var _logging := false

func start_log():
    _log.clear()
    _logging = true

func stop_log(path: String):
    _logging = false
    var f = FileAccess.open(path, FileAccess.WRITE)
    f.store_csv_line(["t", "speed", "yaw_rate", "sideslip",
                      "load_fl", "load_fr", "load_rl", "load_rr",
                      "grip_fl", "grip_fr", "grip_rl", "grip_rr",
                      "throttle", "brake", "steer", "gear", "rpm"])
    for row in _log:
        f.store_csv_line(row.map(str))

func _physics_process(delta: float):
    # ... normal physics ...
    if _logging:
        _log.append([
            Time.get_ticks_msec() / 1000.0,
            linear_velocity.length(),
            rad_to_deg(angular_velocity.y),
            _compute_sideslip(),
            wheels[0].normal_load, wheels[1].normal_load,
            wheels[2].normal_load, wheels[3].normal_load,
            wheels[0].grip_utilization, wheels[1].grip_utilization,
            wheels[2].grip_utilization, wheels[3].grip_utilization,
            throttle_input, brake_input, steer_input,
            current_gear, engine_rpm
        ])
```

### Comparison

Load both CSVs in Python/pandas and compare per-maneuver:
```python
import pandas as pd
import matplotlib.pyplot as plt

hp2 = pd.read_csv("hp2_ground_truth.csv")
godot = pd.read_csv("godot_capture.csv")

fig, axes = plt.subplots(3, 1, figsize=(12, 10))
axes[0].plot(hp2.t, hp2.speed,    label="HP2")
axes[0].plot(godot.t, godot.speed, label="Godot", linestyle="--")
axes[0].set_title("Speed (m/s)")
axes[1].plot(hp2.t, hp2.yaw_rate,    label="HP2")
axes[1].plot(godot.t, godot.yaw_rate, label="Godot", linestyle="--")
axes[1].set_title("Yaw Rate (deg/s)")
axes[2].plot(hp2.t, hp2.sideslip,    label="HP2")
axes[2].plot(godot.t, godot.sideslip, label="Godot", linestyle="--")
axes[2].set_title("Sideslip Angle (deg)")
for ax in axes:
    ax.legend()
plt.tight_layout()
plt.savefig("comparison.png")
```

---

## Layer 6 — Automated Regression

Prevents validated behavior from silently breaking during iteration.

### Godot Test Scene Structure

Create a headless test scene `res://tests/handling_benchmark.tscn`:
- Flat asphalt plane
- Car spawned at known position/orientation
- `BenchmarkRunner.gd` replays recorded input sequences and asserts metrics

```gdscript
# BenchmarkRunner.gd
const BASELINE = {
    "step_steer_response_ms": 120.0,
    "step_steer_overshoot_pct": 12.0,
    "zero_to_100_time_s": 5.4,
    "stop_distance_m": 48.0,
    "drift_onset_frames": 18,
    "steady_circle_yaw_degs": 34.0,
}
const TOLERANCE = 0.05  # 5%

func run_all() -> bool:
    var results = {}
    results["step_steer_response_ms"]  = _test_step_steer()
    results["zero_to_100_time_s"]      = _test_acceleration()
    results["stop_distance_m"]         = _test_braking()
    results["drift_onset_frames"]      = _test_drift_initiation()
    results["steady_circle_yaw_degs"]  = _test_steady_circle()

    var passed = true
    for key in BASELINE:
        var deviation = abs(results[key] - BASELINE[key]) / BASELINE[key]
        if deviation > TOLERANCE:
            push_error("FAIL %s: got %.2f expected %.2f (%.1f%% off)"
                % [key, results[key], BASELINE[key], deviation * 100])
            passed = false
        else:
            print("PASS %s: %.2f (%.1f%% within tolerance)" % [key, results[key], deviation * 100])
    return passed
```

### Populating BASELINE Values

Run Layer 5 ground truth extraction first. The baseline values should come from HP2 captures, not from your Godot system. Using Godot's own outputs as baseline defeats the purpose.

### CI Integration

Add to your project's CI pipeline (GitHub Actions, etc.):
```yaml
- name: Run handling benchmarks
  run: godot --headless --path . res://tests/handling_benchmark.tscn
```

Fail the build if any metric deviates > 5% from baseline.

---

## Recommended Validation Order

For a new implementation or after major changes:

```
1. Layer 1 — Parameter fidelity checks (30 min)
   └─ All pass? Continue. Any fail? Fix before proceeding.

2. Layer 2 Test B — Step steer response (1 hour including HP2 capture)
   └─ This single test has the highest correlation with feel.

3. Layer 2 Tests A, C, D, E — Full kinematic suite (2–3 hours)
   └─ Establish baseline numbers for Layer 6 automation.

4. Layer 6 — Write automated regression tests (1 hour)
   └─ Lock in the validated behavior.

5. Layer 4 — Blind A/B with 3–5 testers (1 session)
   └─ Required before any "it feels right" claim.

6. Layer 3 — Phase plots (optional, useful for diagnosing feel divergence)

7. Layer 5 — Full emulator ground truth (optional but most rigorous)
```

---

## Common Failure Modes and Diagnostics

| Symptom | Likely Cause | Where to Look |
|---|---|---|
| Car feels too grippy / never drifts | `GLOBAL_GRIP_SCALE` too high, or oversteer assist not firing | Log `grip_utilization` and `sideslip` simultaneously |
| Car snaps to oversteer suddenly | Post-peak lateral force drop too steep | Layer 3 slip angle vs lateral force plot |
| Steering feels numb at center | Step steer response time too long | Layer 2 Test B — check response time metric |
| Gear shifts feel instant (no punch) | Shift-cut not implemented or duration too short | Log `shift_cut_active` and engine torque per frame |
| Wrong car rotates on throttle | Drive fraction wrong direction (FWD vs RWD) | Layer 3 throttle-steer coupling test |
| Car spins on braking | Rear brake bias too high or front/rear load not transferring | Layer 2 Test E + per-wheel load logging |
| Feel matches numerically but not subjectively | Timing of sensations is off by 50–100ms | Focus on Layer 2 Test B response time — most perceptually sensitive |

---

## Quick Reference: Acceptable Tolerances

| Metric | Acceptable Deviation |
|---|---|
| Torque curve deviation | < 5% at any RPM point |
| Step steer response time | ± 20ms |
| Step steer overshoot | ± 5 percentage points |
| 0–100 time | ± 0.3s |
| Stopping distance | ± 5% |
| Steady-state yaw rate | ± 10% |
| Sideslip at steady circle | ± 3° |
| Drift onset timing | ± 3 frames at 60fps |
| Oversteer assist trigger | ± 2° from 10–15° target |
| Blind A/B indistinguishable | ≥ 60% of testers |
