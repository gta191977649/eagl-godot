#!/usr/bin/env python3
"""Generate HP2 benchmark comparison graphs without third-party packages.

The "ground truth" series here is the documented Python planar reference model,
not a live PS2 emulator capture. Replace the generated reference CSVs with
emulator captures later when Layer 5 data is available.
"""

from __future__ import annotations

import csv
import json
import math
import os
from pathlib import Path


HEADER = [
    "t", "speed_kmh", "speed_ms", "yaw_rate", "sideslip", "heading",
    "vx", "vy", "pos_x", "pos_y", "accel_long", "rpm", "gear",
    "shift_cut", "grip_FL", "grip_FR", "grip_RL", "grip_RR",
    "load_FL", "load_FR", "load_RL", "load_RR", "surface_type", "surface_mu",
]

SCENARIOS = {
    "low_speed_turn_radius": [(0.35, 0.0, 0.0, 1.75), (0.18, 0.0, 1.0, 9.0)],
    "step_steer": [(0.6, 0.0, 0.0, 5.0), (0.3, 0.0, 0.5, 4.0)],
    "acceleration": [(1.0, 0.0, 0.0, 15.0)],
    "braking": [(1.0, 0.0, 0.0, 8.0), (0.0, 1.0, 0.0, 8.0)],
    "drift_init": [(0.8, 0.0, 0.0, 4.0), (1.0, 0.0, 0.7, 5.0)],
    "drift_recovery": [(0.8, 0.0, 0.0, 4.0), (1.0, 0.0, 0.7, 3.0), (0.2, 0.0, 0.0, 4.0)],
    "steady_circle": [(0.8, 0.0, 0.0, 3.0), (0.45, 0.0, 0.4, 12.0)],
}

TORQUE_CURVE = [
    (0.00, 80.0), (0.10, 160.0), (0.20, 280.0), (0.30, 340.0), (0.40, 380.0),
    (0.55, 400.0), (0.70, 370.0), (0.85, 310.0), (1.00, 200.0),
]
FRICTION_CURVE = [(0.0, 20.0), (0.5, 35.0), (1.0, 60.0)]
GEARS = [-3.46, 3.15, 2.02, 1.43, 1.13, 0.93, 0.76]


def sample_curve(curve: list[tuple[float, float]], x: float) -> float:
    if x <= curve[0][0]:
        return curve[0][1]
    for (x0, y0), (x1, y1) in zip(curve, curve[1:]):
        if x <= x1:
            a = max(0.0, min(1.0, (x - x0) / max(x1 - x0, 1e-6)))
            return y0 + (y1 - y0) * a
    return curve[-1][1]


def wrap_pi(value: float) -> float:
    return (value + math.pi) % (math.tau) - math.pi


class ReferenceCar:
    def __init__(self, params: dict[str, float | int | str | list] | None = None) -> None:
        p = params or {}
        self.mass = float(p.get("mass", 1450.0))
        self.izz = float(p.get("inertia_yaw", 2200.0))
        self.wheelbase = float(p.get("wheelbase", 2.60))
        self.track_front = float(p.get("track_front", 1.60))
        self.track_rear = float(p.get("track_rear", 1.58))
        self.cg_height = float(p.get("cg_height", 0.42))
        self.front_bias = float(p.get("front_weight_bias", 0.58))
        self.radius = float(p.get("wheel_radius", 0.32))
        self.base_mu = float(p.get("base_mu", 1.0))
        self.front_wheel_grip_scale = float(p.get("front_wheel_grip_scale", 1.0))
        self.rear_wheel_grip_scale = float(p.get("rear_wheel_grip_scale", 1.0))
        self.front_wheel_lat_grip_scale = float(p.get("front_wheel_lat_grip_scale", self.front_wheel_grip_scale))
        self.rear_wheel_lat_grip_scale = float(p.get("rear_wheel_lat_grip_scale", self.rear_wheel_grip_scale))
        self.final_drive = float(p.get("final_drive", 3.91))
        self.gears = [float(v) for v in p.get("gear_ratios", GEARS)]
        if len(self.gears) < 2:
            self.gears = GEARS[:]
        self.max_rpm = float(p.get("max_rpm", 8500.0))
        self.peak_rpm = float(p.get("peak_rpm", 6500.0))
        self.idle_rpm = float(p.get("idle_rpm", 900.0))
        self.torque_curve = self._curve_from_params(p.get("torque_curve"), TORQUE_CURVE)
        self.friction_curve = self._curve_from_params(p.get("friction_curve"), FRICTION_CURVE)
        self.upshift_rpm = float(p.get("upshift_rpm", min(self.max_rpm * 0.96, self.peak_rpm * 0.98)))
        self.downshift_rpm = float(p.get("downshift_rpm", self.max_rpm * 0.40))
        self.longitudinal_stiffness = float(p.get("longitudinal_stiffness", 6000.0))
        self.longitudinal_speed_damping = float(p.get("longitudinal_speed_damping", 0.0))
        self.lateral_stiffness = float(p.get("lateral_stiffness", 6500.0))
        self.brake_torque_total = float(p.get("brake_torque_total", 4200.0))
        self.brake_bias_front = float(p.get("brake_bias_front", 0.65))
        self.rolling_resistance = float(p.get("rolling_resistance", 0.035))
        self.aero_drag = float(p.get("aero_drag", 0.42))
        self.weight_transfer_coeff = float(p.get("weight_transfer_coeff", 0.64))
        self.steering_response_rate = float(p.get("steering_response_rate", 5.5))
        self.max_steer_degrees = float(p.get("max_steer_degrees", 30.0))
        self.rpm = self.idle_rpm
        self.gear = 1
        self.shift_cut = 0.0
        self.shift_timer = 0.0
        self.steer_state = 0.0
        self.wheel_w = {slot: 0.0 for slot in ("FL", "FR", "RL", "RR")}
        self.x = self.y = self.heading = self.vx = self.vy = self.yaw_rate = 0.0
        self.accel_long = 0.0
        self.last_forward_speed = 0.0
        self.grip = {slot: 0.0 for slot in ("FL", "FR", "RL", "RR")}
        self.load = {slot: 0.0 for slot in ("FL", "FR", "RL", "RR")}

    def rows_for(self, phases: list[tuple[float, float, float, float]], hz: int = 60) -> list[dict[str, float | str]]:
        rows = []
        t = 0.0
        dt = 1.0 / hz
        for throttle, brake, steer, duration in phases:
            for _ in range(int(round(duration * hz))):
                self.step(throttle, brake, steer, dt)
                t += dt
                rows.append(self.row(t))
        return rows

    def step(self, throttle: float, brake: float, steer: float, dt: float) -> None:
        for _ in range(4):
            self._substep(throttle, brake, steer, dt / 4.0)

    def _substep(self, throttle: float, brake: float, steer: float, dt: float) -> None:
        speed = math.hypot(self.vx, self.vy)
        rear_w = (self.wheel_w["RL"] + self.wheel_w["RR"]) * 0.5
        ratio = self.gears[self.gear] * self.final_drive
        target_rpm = min(self.max_rpm * 1.05, max(self.idle_rpm, abs(rear_w * ratio * 60.0 / math.tau)))
        self.rpm += (target_rpm - self.rpm) * min(1.0, dt * 15.0)

        self.shift_timer += dt
        if self.shift_cut > 0.0:
            self.shift_cut = max(0.0, self.shift_cut - dt)
        if self.shift_timer >= 0.5 and self.rpm > self.upshift_rpm and self.gear < len(self.gears) - 1:
            self.gear += 1
            self.shift_cut = 0.4
            self.shift_timer = 0.0
        elif self.shift_timer >= 0.5 and self.rpm < self.downshift_rpm and self.gear > 1 and speed * 3.6 < 25.0:
            self.gear -= 1
            self.shift_timer = 0.0

        rpm_n = min(1.0, max(0.0, self.rpm / self.max_rpm))
        torque = sample_curve(self.torque_curve, rpm_n)
        if self.shift_cut > 0.0:
            torque *= 0.35
        friction = sample_curve(self.friction_curve, rpm_n)
        net_torque = torque * throttle - friction * (1.0 - throttle)
        shaft = net_torque * abs(self.gears[self.gear] * self.final_drive)

        target_steer = steer
        self.steer_state += max(-self.steering_response_rate * dt, min(self.steering_response_rate * dt, target_steer - self.steer_state))
        steer_angle = math.radians(self.max_steer_degrees) * self.steer_state
        forward = (math.sin(self.heading), math.cos(self.heading))
        right = (math.cos(self.heading), -math.sin(self.heading))

        base_front = self.mass * 9.81 * self.front_bias
        base_rear = self.mass * 9.81 * (1.0 - self.front_bias)
        transfer = self.mass * self.accel_long * self.cg_height / self.wheelbase * self.weight_transfer_coeff
        front = max(0.0, base_front - transfer)
        rear = max(0.0, base_rear + transfer)
        self.load = {"FL": front * 0.5, "FR": front * 0.5, "RL": rear * 0.5, "RR": rear * 0.5}

        positions = {
            "FL": (-self.track_front * 0.5, self.wheelbase * (1.0 - self.front_bias)),
            "FR": (self.track_front * 0.5, self.wheelbase * (1.0 - self.front_bias)),
            "RL": (-self.track_rear * 0.5, -self.wheelbase * self.front_bias),
            "RR": (self.track_rear * 0.5, -self.wheelbase * self.front_bias),
        }
        total_fx = total_fy = yaw_torque = 0.0
        for slot, (lx, ly) in positions.items():
            wheel_angle = self.heading + (self._ackermann(steer_angle).get(slot, 0.0) if slot.startswith("F") else 0.0)
            wf = (math.sin(wheel_angle), math.cos(wheel_angle))
            wr = (math.cos(wheel_angle), -math.sin(wheel_angle))
            wx = right[0] * lx + forward[0] * ly
            wy = right[1] * lx + forward[1] * ly
            vel = (self.vx + self.yaw_rate * wy, self.vy - self.yaw_rate * wx)
            v_long = vel[0] * wf[0] + vel[1] * wf[1]
            v_lat = vel[0] * wr[0] + vel[1] * wr[1]
            drive = shaft * 0.5 if slot.startswith("R") else 0.0
            brake_torque = brake * self.brake_torque_total * (self.brake_bias_front if slot.startswith("F") else 1.0 - self.brake_bias_front) * 0.5
            brake_dir = 1.0 if v_long >= 0.0 else -1.0
            slip_long = (
                drive / max(self.radius, 1e-6)
                - brake_torque / max(self.radius, 1e-6) * brake_dir
                - v_long * self.longitudinal_stiffness * self.longitudinal_speed_damping
            )
            slip_lat = v_lat * self.lateral_stiffness
            grip_scale = self.front_wheel_grip_scale if slot.startswith("F") else self.rear_wheel_grip_scale
            contact_speed = math.hypot(slip_long, slip_lat)
            max_grip = self.load[slot] * self.base_mu * grip_scale
            scale = min(1.0, max_grip / max(contact_speed, 0.0001))
            force_long = slip_long * scale
            force_lat = -slip_lat * scale
            self.grip[slot] = min(1.0, (contact_speed * scale) / max(max_grip, 0.0001))
            target_w = v_long / max(self.radius, 1e-6)
            self.wheel_w[slot] += (target_w - self.wheel_w[slot]) * min(1.0, dt * 18.0)
            fx = wf[0] * force_long + wr[0] * force_lat
            fy = wf[1] * force_long + wr[1] * force_lat
            total_fx += fx
            total_fy += fy
            yaw_torque += wy * fx - wx * fy

        if speed > 0.01:
            drag = self.aero_drag * speed * speed + self.rolling_resistance * self.mass * 9.81
            total_fx -= self.vx / speed * drag
            total_fy -= self.vy / speed * drag
        self.vx += total_fx / self.mass * dt
        self.vy += total_fy / self.mass * dt
        self.yaw_rate += yaw_torque / self.izz * dt
        self.heading = wrap_pi(self.heading + self.yaw_rate * dt)
        self.x += self.vx * dt
        self.y += self.vy * dt
        fwd_speed = self.vx * math.sin(self.heading) + self.vy * math.cos(self.heading)
        self.accel_long = (fwd_speed - self.last_forward_speed) / max(dt, 1e-6)
        self.last_forward_speed = fwd_speed

    def _ackermann(self, center_angle: float) -> dict[str, float]:
        if abs(center_angle) < 1e-4:
            return {"FL": 0.0, "FR": 0.0, "RL": 0.0, "RR": 0.0}
        sign = 1.0 if center_angle > 0.0 else -1.0
        turn_radius = self.wheelbase / max(math.tan(abs(center_angle)), 1e-4)
        inner = math.atan(self.wheelbase / max(turn_radius - self.track_front * 0.5, 1e-4)) * sign
        outer = math.atan(self.wheelbase / (turn_radius + self.track_front * 0.5)) * sign
        if center_angle > 0.0:
            return {"FL": outer, "FR": inner, "RL": 0.0, "RR": 0.0}
        return {"FL": inner, "FR": outer, "RL": 0.0, "RR": 0.0}

    @staticmethod
    def _curve_from_params(value: object, fallback: list[tuple[float, float]]) -> list[tuple[float, float]]:
        if not isinstance(value, list) or len(value) < 2:
            return fallback
        curve: list[tuple[float, float]] = []
        for point in value:
            if not isinstance(point, list) or len(point) < 2:
                return fallback
            curve.append((float(point[0]), float(point[1])))
        return curve

    def row(self, t: float) -> dict[str, float | str]:
        speed = math.hypot(self.vx, self.vy)
        slip = 0.0 if speed < 5.0 / 3.6 else math.degrees(wrap_pi(math.atan2(self.vx, self.vy) - self.heading))
        row = {
            "t": t, "speed_kmh": speed * 3.6, "speed_ms": speed, "yaw_rate": math.degrees(self.yaw_rate),
            "sideslip": slip, "heading": math.degrees(self.heading), "vx": self.vx, "vy": self.vy,
            "pos_x": self.x, "pos_y": self.y, "accel_long": self.accel_long, "rpm": self.rpm,
            "gear": self.gear, "shift_cut": 1 if self.shift_cut > 0.0 else 0,
            "surface_type": "asphalt", "surface_mu": self.base_mu,
        }
        for slot in ("FL", "FR", "RL", "RR"):
            row[f"grip_{slot}"] = self.grip[slot]
            row[f"load_{slot}"] = self.load[slot]
        return row


def read_csv(path: Path) -> list[dict[str, float | str]]:
    with path.open() as handle:
        return [
            {key: (value if key == "surface_type" else float(value)) for key, value in row.items()}
            for row in csv.DictReader(handle)
        ]


def write_csv(path: Path, rows: list[dict[str, float | str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=HEADER)
        writer.writeheader()
        writer.writerows(rows)


def interp(rows: list[dict[str, float | str]], t: float, key: str) -> float:
    if not rows:
        return 0.0
    if t <= float(rows[0]["t"]):
        return float(rows[0][key])
    for a, b in zip(rows, rows[1:]):
        ta, tb = float(a["t"]), float(b["t"])
        if ta <= t <= tb:
            alpha = (t - ta) / max(tb - ta, 1e-9)
            return float(a[key]) + (float(b[key]) - float(a[key])) * alpha
    return float(rows[-1][key])


def rmse(a_rows: list[dict[str, float | str]], b_rows: list[dict[str, float | str]], key: str) -> float:
    times = [float(row["t"]) for row in a_rows]
    if not times:
        return 0.0
    errors = [(float(row[key]) - interp(b_rows, t, key)) ** 2 for t, row in zip(times, a_rows)]
    return math.sqrt(sum(errors) / len(errors))


def average(rows: list[dict[str, float | str]], key: str, start_t: float | None = None, end_t: float | None = None) -> float:
    filtered = [
        float(row[key])
        for row in rows
        if (start_t is None or float(row["t"]) >= start_t) and (end_t is None or float(row["t"]) <= end_t)
    ]
    if not filtered:
        return 0.0
    return sum(filtered) / len(filtered)


def first_crossing_time(
    rows: list[dict[str, float | str]],
    key: str,
    threshold: float,
    start_t: float = 0.0,
    use_abs: bool = False,
) -> float | None:
    for row in rows:
        t = float(row["t"])
        if t < start_t:
            continue
        value = float(row[key])
        if use_abs:
            value = abs(value)
        if value >= threshold:
            return t
    return None


def settling_time(rows: list[dict[str, float | str]], key: str, target: float, start_t: float, tolerance_ratio: float = 0.05) -> float | None:
    if not rows:
        return None
    tolerance = max(abs(target) * tolerance_ratio, 0.25)
    for index, row in enumerate(rows):
        t = float(row["t"])
        if t < start_t:
            continue
        window = rows[index:]
        if all(abs(float(sample[key]) - target) <= tolerance for sample in window):
            return t
    return None


def peak_abs(rows: list[dict[str, float | str]], key: str, start_t: float = 0.0) -> float:
    values = [abs(float(row[key])) for row in rows if float(row["t"]) >= start_t]
    return max(values) if values else 0.0


def peak_value(rows: list[dict[str, float | str]], key: str, start_t: float = 0.0) -> float:
    values = [float(row[key]) for row in rows if float(row["t"]) >= start_t]
    return max(values) if values else 0.0


def grip_balance(rows: list[dict[str, float | str]], start_t: float | None = None, end_t: float | None = None) -> float:
    front = average(rows, "grip_FL", start_t, end_t) + average(rows, "grip_FR", start_t, end_t)
    rear = average(rows, "grip_RL", start_t, end_t) + average(rows, "grip_RR", start_t, end_t)
    return rear * 0.5 - front * 0.5


def rows_after(rows: list[dict[str, float | str]], start_t: float) -> list[dict[str, float | str]]:
    return [row for row in rows if float(row["t"]) >= start_t]


def turn_radius_metric(rows: list[dict[str, float | str]], start_t: float = 3.5) -> float:
    radii: list[float] = []
    for row in rows:
        t = float(row["t"])
        if t < start_t:
            continue
        speed = float(row["speed_ms"])
        yaw_rate_deg = abs(float(row["yaw_rate"]))
        if speed < 1.0 or yaw_rate_deg < 1.0:
            continue
        yaw_rate_rad = math.radians(yaw_rate_deg)
        radii.append(speed / max(yaw_rate_rad, 1e-6))
    return sum(radii) / len(radii) if radii else 0.0


def response_metrics(rows: list[dict[str, float | str]], onset_t: float) -> dict[str, float]:
    steady_yaw = average(rows, "yaw_rate", onset_t + 2.0, None)
    peak_yaw = peak_value(rows, "yaw_rate", onset_t)
    low = abs(steady_yaw) * 0.1
    high = abs(steady_yaw) * 0.9
    rise_start = first_crossing_time(rows, "yaw_rate", low, onset_t, use_abs=True)
    rise_end = first_crossing_time(rows, "yaw_rate", high, onset_t, use_abs=True)
    settle = settling_time(rows, "yaw_rate", steady_yaw, onset_t)
    overshoot = 0.0
    if abs(steady_yaw) > 1e-6:
        overshoot = (peak_yaw - steady_yaw) / abs(steady_yaw) * 100.0
    return {
        "rise_time_10_90": 0.0 if rise_start is None or rise_end is None else rise_end - rise_start,
        "peak_yaw_rate": peak_yaw,
        "steady_yaw_rate": steady_yaw,
        "overshoot_pct": overshoot,
        "settling_time": 0.0 if settle is None else settle - onset_t,
        "peak_sideslip": peak_abs(rows, "sideslip", onset_t),
    }


def scenario_metrics(name: str, rows: list[dict[str, float | str]]) -> dict[str, float]:
    if name == "step_steer":
        return response_metrics(rows, 5.0)
    if name == "steady_circle":
        return {
            "steady_yaw_rate": average(rows, "yaw_rate", 8.0, None),
            "steady_sideslip": average(rows, "sideslip", 8.0, None),
            "rear_front_grip_balance": grip_balance(rows, 8.0, None),
        }
    if name == "drift_init":
        onset = first_crossing_time(rows, "sideslip", 15.0, 4.0, use_abs=True)
        return {
            "drift_onset_time": 0.0 if onset is None else onset - 4.0,
            "peak_sideslip": peak_abs(rows, "sideslip", 4.0),
            "rear_front_grip_balance": grip_balance(rows, 4.0, None),
        }
    if name == "drift_recovery":
        recovery_time = None
        for row in rows_after(rows, 7.0):
            if abs(float(row["sideslip"])) <= 5.0:
                recovery_time = float(row["t"]) - 7.0
                break
        return {
            "recovery_time_to_5deg": 0.0 if recovery_time is None else recovery_time,
            "peak_sideslip": peak_abs(rows, "sideslip", 4.0),
        }
    if name == "low_speed_turn_radius":
        return {
            "turn_radius_m": turn_radius_metric(rows),
            "steady_speed_kmh": average(rows, "speed_kmh", 4.0, None),
        }
    return {}


def path_from_env() -> Path:
    return Path.home() / "Library/Application Support/Godot/app_userdata/EagleDot/hp2_benchmarks"


def read_params(root: Path) -> dict:
    path = root / "godot_hp2_params.json"
    if not path.exists():
        return {}
    return json.loads(path.read_text())


def svg_polyline(rows: list[dict[str, float | str]], key: str, t_max: float, y_min: float, y_max: float, x: int, y: int, w: int, h: int) -> str:
    points = []
    for row in rows[:: max(1, len(rows) // 500)]:
        px = x + float(row["t"]) / max(t_max, 1e-6) * w
        py = y + h - (float(row[key]) - y_min) / max(y_max - y_min, 1e-6) * h
        points.append(f"{px:.1f},{py:.1f}")
    return " ".join(points)


def write_svg(path: Path, series: dict[str, tuple[list[dict[str, float | str]], list[dict[str, float | str]]]], summary: list[dict[str, float | str]]) -> None:
    width, panel_h = 1180, 170
    height = 80 + len(series) * panel_h
    colors = {"speed_kmh": "#2563eb", "yaw_rate": "#dc2626", "sideslip": "#16a34a"}
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        '<rect width="100%" height="100%" fill="#f8fafc"/>',
        '<text x="24" y="32" font-family="Arial" font-size="22" font-weight="700">HP2 benchmark: Godot controller vs documented Python reference</text>',
        '<text x="24" y="56" font-family="Arial" font-size="13" fill="#475569">Solid = Godot HP2ControllerCar, dashed = Python reference model. This is not a PS2 emulator capture.</text>',
    ]
    y = 82
    for name, (godot, ref) in series.items():
        plot_x, plot_y, plot_w, plot_h = 180, y + 24, 960, 110
        parts.append(f'<text x="24" y="{y + 22}" font-family="Arial" font-size="17" font-weight="700">{name}</text>')
        parts.append(f'<rect x="{plot_x}" y="{plot_y}" width="{plot_w}" height="{plot_h}" fill="#ffffff" stroke="#cbd5e1"/>')
        t_max = max(float(godot[-1]["t"]), float(ref[-1]["t"]))
        for key in ("speed_kmh", "yaw_rate", "sideslip"):
            values = [float(row[key]) for row in godot + ref]
            y_min, y_max = min(values), max(values)
            pad = max((y_max - y_min) * 0.08, 1.0)
            y_min -= pad
            y_max += pad
            color = colors[key]
            g_points = svg_polyline(godot, key, t_max, y_min, y_max, plot_x, plot_y, plot_w, plot_h)
            r_points = svg_polyline(ref, key, t_max, y_min, y_max, plot_x, plot_y, plot_w, plot_h)
            parts.append(f'<polyline points="{r_points}" fill="none" stroke="{color}" stroke-width="1.7" stroke-dasharray="5 5" opacity="0.65"/>')
            parts.append(f'<polyline points="{g_points}" fill="none" stroke="{color}" stroke-width="2.0"/>')
        row = next(item for item in summary if item["test"] == name)
        parts.append(f'<text x="24" y="{y + 52}" font-family="Arial" font-size="12" fill="#334155">speed RMSE {float(row["speed_rmse"]):.2f} km/h</text>')
        parts.append(f'<text x="24" y="{y + 72}" font-family="Arial" font-size="12" fill="#334155">yaw RMSE {float(row["yaw_rmse"]):.2f} deg/s</text>')
        parts.append(f'<text x="24" y="{y + 92}" font-family="Arial" font-size="12" fill="#334155">slip RMSE {float(row["sideslip_rmse"]):.2f} deg</text>')
        y += panel_h
    parts.append('<text x="820" y="56" font-family="Arial" font-size="13" fill="#2563eb">blue speed</text>')
    parts.append('<text x="920" y="56" font-family="Arial" font-size="13" fill="#dc2626">red yaw rate</text>')
    parts.append('<text x="1040" y="56" font-family="Arial" font-size="13" fill="#16a34a">green sideslip</text>')
    parts.append("</svg>")
    path.write_text("\n".join(parts))


def main() -> None:
    root = Path(os.environ.get("HP2_BENCHMARK_DIR", path_from_env()))
    params = read_params(root)
    results = Path(__file__).resolve().parent / "results"
    results.mkdir(parents=True, exist_ok=True)
    series = {}
    summary = []
    for name, phases in SCENARIOS.items():
        godot_path = root / f"godot_{name}.csv"
        if not godot_path.exists():
            raise SystemExit(f"missing Godot benchmark CSV: {godot_path}")
        godot_rows = read_csv(godot_path)
        reference_rows = ReferenceCar(params).rows_for(phases)
        write_csv(results / f"reference_{name}.csv", reference_rows)
        series[name] = (godot_rows, reference_rows)
        summary.append({
            "test": name,
            "speed_rmse": rmse(godot_rows, reference_rows, "speed_kmh"),
            "yaw_rmse": rmse(godot_rows, reference_rows, "yaw_rate"),
            "sideslip_rmse": rmse(godot_rows, reference_rows, "sideslip"),
            "godot_max_speed": max(float(row["speed_kmh"]) for row in godot_rows),
            "reference_max_speed": max(float(row["speed_kmh"]) for row in reference_rows),
            "godot_peak_abs_sideslip": max(abs(float(row["sideslip"])) for row in godot_rows),
            "reference_peak_abs_sideslip": max(abs(float(row["sideslip"])) for row in reference_rows),
        } | scenario_metrics(name, godot_rows))
    with (results / "benchmark_summary.csv").open("w", newline="") as handle:
        fieldnames: list[str] = []
        for row in summary:
            for key in row.keys():
                if key not in fieldnames:
                    fieldnames.append(key)
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(summary)
    write_svg(results / "hp2_benchmark_comparison.svg", series, summary)
    print(results / "hp2_benchmark_comparison.svg")
    print(results / "benchmark_summary.csv")
    for row in summary:
        print(
            f"{row['test']}: speed_rmse={float(row['speed_rmse']):.2f} km/h "
            f"yaw_rmse={float(row['yaw_rmse']):.2f} deg/s "
            f"sideslip_rmse={float(row['sideslip_rmse']):.2f} deg"
        )


if __name__ == "__main__":
    main()
