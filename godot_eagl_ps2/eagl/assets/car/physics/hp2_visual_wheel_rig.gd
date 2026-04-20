class_name HP2VisualWheelRig
extends RefCounted

var spin_pivots: Array[Node3D] = []
var steer_pivots: Array[Node3D] = []
var visual_root: Node3D


func cache(owner: Node) -> void:
	spin_pivots.clear()
	steer_pivots.clear()
	visual_root = owner.get_node_or_null(owner.visual_root_path) as Node3D
	if visual_root == null:
		return
	for node in visual_root.find_children("*", "Node3D", true, false):
		var node3d = node as Node3D
		if node3d == null:
			continue
		if node3d.has_meta("eagl_spin_pivot") and bool(node3d.get_meta("eagl_spin_pivot")):
			spin_pivots.append(node3d)
		if node3d.has_meta("eagl_steer_pivot") and bool(node3d.get_meta("eagl_steer_pivot")):
			steer_pivots.append(node3d)


func update(owner, config, steering, delta: float) -> void:
	steering.update(owner, config)
	var max_steer = float(config.tuning.get("max_steer_angle", 0.62))
	owner.wheel_angular_speed = owner.local_longitudinal_speed / maxf(float(config.tuning.get("wheel_radius", 0.36)), 0.01)
	owner.steering_angle = owner.steer * max_steer
	for spin_pivot in spin_pivots:
		if spin_pivot == null or not is_instance_valid(spin_pivot):
			continue
		var slot_id = String(spin_pivot.get_meta("eagl_wheel_slot_id", ""))
		var state: Dictionary = owner.wheel_states.get(slot_id, {})
		var spin_direction = float(spin_pivot.get_meta("eagl_spin_direction", 1.0))
		var visual_angular_speed = float(state.get("angular_speed", owner.wheel_angular_speed))
		if absf(visual_angular_speed) <= 0.0001:
			visual_angular_speed = owner.wheel_angular_speed
		spin_pivot.rotation.x += visual_angular_speed * spin_direction * delta
		spin_pivot.position.y = -float(state.get("compression", 0.0)) * float(state.get("travel", 0.0)) * 0.25
	for steer_pivot in steer_pivots:
		if steer_pivot == null or not is_instance_valid(steer_pivot):
			continue
		var slot_id = String(steer_pivot.get_meta("eagl_wheel_slot_id", ""))
		var state: Dictionary = owner.wheel_states.get(slot_id, {})
		var angle = float(state.get("steering_angle", owner.steering_angle))
		steer_pivot.rotation.y = angle
		steer_pivot.set_meta("eagl_visual_steer", owner.steer)
		steer_pivot.set_meta("eagl_visual_steering_angle", angle)
