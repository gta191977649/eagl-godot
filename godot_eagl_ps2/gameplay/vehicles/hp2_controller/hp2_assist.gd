class_name HP2Assist
extends RefCounted


var min_speed_kmh := 80.0
var sideslip_threshold_deg := 12.0
var assist_torque_nm := 20.0
var active_wheel := ""


func reset_runtime() -> void:
	active_wheel = ""


func apply(wheels: Dictionary, speed_kmh: float, sideslip_deg: float) -> void:
	active_wheel = ""
	if speed_kmh <= min_speed_kmh or absf(sideslip_deg) <= sideslip_threshold_deg:
		return
	active_wheel = "RR" if sideslip_deg > 0.0 else "RL"
	var wheel = wheels.get(active_wheel, null)
	if wheel != null:
		wheel.drive_torque += assist_torque_nm
