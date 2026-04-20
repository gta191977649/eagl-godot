class_name HP2AckermannSteering
extends RefCounted

const WHEEL_ORDER = ["FL", "FR", "RL", "RR"]
const FRONT_WHEELS = ["FL", "FR"]


func init_wheel_states(owner, config) -> void:
	owner.wheel_states.clear()
	for slot in config.wheel_slots():
		var slot_dict: Dictionary = slot
		var slot_id = String(slot_dict.get("slot_id", ""))
		if slot_id == "":
			continue
		owner.wheel_states[slot_id] = {
			"slot": slot_dict.duplicate(true),
			"grounded": false,
			"compression": 0.0,
			"normal_force": 0.0,
			"longitudinal_force": 0.0,
			"lateral_force": 0.0,
			"slip_ratio": 0.0,
			"slip_angle": 0.0,
			"combined_tire_saturation": 0.0,
			"angular_speed": 0.0,
			"steering_angle": 0.0,
			"skidding": false,
		}
	update(owner, config)


func update(owner, config) -> void:
	var dimensions: Dictionary = config.handling_data.get("vehicle_dimensions", {})
	var wheelbase = config.field_value(dimensions.get("wheelbase", {}), config.fallback_wheelbase())
	var front_track = config.field_value(dimensions.get("front_track", {}), config.fallback_track())
	var max_steer = float(config.tuning.get("max_steer_angle", 0.62))
	var requested = owner.steer * max_steer
	for slot_id in WHEEL_ORDER:
		var state: Dictionary = owner.wheel_states.get(slot_id, {})
		if not FRONT_WHEELS.has(slot_id):
			state["steering_angle"] = 0.0
			owner.wheel_states[slot_id] = state
			continue
		if absf(requested) < 0.0001:
			state["steering_angle"] = 0.0
			owner.wheel_states[slot_id] = state
			continue
		var turn_radius = wheelbase / tan(absf(requested))
		var inner = atan(wheelbase / maxf(turn_radius - front_track * 0.5, 0.1))
		var outer = atan(wheelbase / (turn_radius + front_track * 0.5))
		var turning_left: bool = requested > 0.0
		var is_left: bool = slot_id.ends_with("L")
		var magnitude = inner if is_left == turning_left else outer
		state["steering_angle"] = signf(requested) * magnitude
		state["ackermann_inner"] = is_left == turning_left
		owner.wheel_states[slot_id] = state
