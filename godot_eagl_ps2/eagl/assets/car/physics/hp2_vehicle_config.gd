class_name HP2VehicleConfig
extends RefCounted

const WHEEL_ORDER = ["FL", "FR", "RL", "RR"]

var tuning: Dictionary = {}
var handling_data: Dictionary = {}


func configure(new_tuning: Dictionary, new_handling_data: Dictionary) -> void:
	tuning = new_tuning
	handling_data = new_handling_data


func wheel_slots() -> Array:
	var slots: Array = handling_data.get("wheel_slots", [])
	if slots.is_empty():
		slots = handling_data.get("globalb_row", {}).get("wheel_slots", [])
	return slots


func mass() -> float:
	return maxf(float(tuning.get("mass", 1200.0)), 1.0)


func yaw_inertia() -> float:
	var wheelbase = field_value(handling_data.get("vehicle_dimensions", {}).get("wheelbase", {}), fallback_wheelbase())
	var track = field_value(handling_data.get("vehicle_dimensions", {}).get("front_track", {}), fallback_track())
	return mass() * (wheelbase * wheelbase + track * track) / 12.0


func fallback_wheelbase() -> float:
	var fl = slot_position("FL")
	var rl = slot_position("RL")
	if fl != Vector3.ZERO or rl != Vector3.ZERO:
		return maxf(absf(fl.z - rl.z), 1.0)
	return 2.65


func fallback_track() -> float:
	var fl = slot_position("FL")
	var fr = slot_position("FR")
	if fl != Vector3.ZERO or fr != Vector3.ZERO:
		return maxf(absf(fl.x - fr.x), 1.0)
	return 1.55


func slot_position(slot_id: String) -> Vector3:
	for slot in wheel_slots():
		var dict: Dictionary = slot
		if String(dict.get("slot_id", "")) == slot_id:
			return dict.get("position_godot", Vector3.ZERO)
	return Vector3.ZERO


func aero_drag() -> float:
	var aero: Dictionary = tuning.get("aero", {})
	var field: Dictionary = aero.get("aero_drag", {})
	return maxf(field_value(field, float(tuning.get("linear_drag", 0.42)) / 900.0), 0.00001)


func suspension_value(name: String, fallback: float) -> float:
	var suspension: Dictionary = tuning.get("suspension", {})
	var field: Dictionary = suspension.get(name, {})
	return field_value(field, fallback)


func gear_count() -> int:
	var ratios: Array = tuning.get("gear_ratios", [])
	var count = int(tuning.get("gear_count", ratios.size() if not ratios.is_empty() else 5))
	if not ratios.is_empty():
		count = mini(count, ratios.size())
	return clampi(count, 3, 7)


func final_drive_ratio() -> float:
	return maxf(float(tuning.get("final_drive_ratio", 3.42)), 0.1)


func engine_idle_rpm() -> float:
	return clampf(float(tuning.get("engine_idle_rpm", 850.0)), 500.0, 1600.0)


func engine_peak_rpm() -> float:
	return clampf(float(tuning.get("engine_peak_rpm", 6500.0)), 1500.0, engine_redline_rpm())


func engine_redline_rpm() -> float:
	return clampf(float(tuning.get("engine_redline_rpm", 7600.0)), 3000.0, 14000.0)


func current_gear_ratio(current_gear: int) -> float:
	if current_gear < 0:
		return float(tuning.get("reverse_gear_ratio", -3.10))
	var ratios: Array = tuning.get("gear_ratios", [])
	if ratios.is_empty():
		return 1.0
	var index = clampi(current_gear - 1, 0, max(ratios.size() - 1, 0))
	return float(ratios[index])


func field_value(field, fallback: float) -> float:
	if field is Dictionary:
		return float((field as Dictionary).get("value", fallback))
	return fallback
