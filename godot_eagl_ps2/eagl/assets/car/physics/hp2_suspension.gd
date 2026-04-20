class_name HP2Suspension
extends RefCounted

const WHEEL_ORDER = ["FL", "FR", "RL", "RR"]


func update_wheel_contacts(owner: Node3D, config, body: Node3D, basis: Basis, delta: float) -> void:
	var world = owner.get_world_3d()
	var mass = config.mass()
	var gravity = float(config.tuning.get("gravity", 28.0))
	var rest_length = config.suspension_value("runtime_rest_length", 0.45)
	var travel = config.suspension_value("runtime_travel", 0.28)
	var spring_rate = config.suspension_value("spring_rate", mass * 5.5)
	var damping = config.suspension_value("damping", mass * 0.75)
	var full_droop = rest_length + travel
	for slot_id in WHEEL_ORDER:
		var state: Dictionary = owner.wheel_states.get(slot_id, {})
		var slot: Dictionary = state.get("slot", {})
		var local_pos: Vector3 = slot.get("position_godot", Vector3.ZERO)
		var radius = float(slot.get("wheel_radius", config.tuning.get("wheel_radius", 0.36)))
		var mount = body.global_transform * local_pos
		var suspension_axis = basis.y.normalized()
		var from = mount + suspension_axis * travel
		var to = mount - suspension_axis * (full_droop + radius)
		var hit = {}
		if world != null:
			var query = PhysicsRayQueryParameters3D.create(from, to)
			hit = world.direct_space_state.intersect_ray(query)
		var previous_length = float(state.get("suspension_length", full_droop))
		if hit.is_empty():
			state["grounded"] = false
			state["compression"] = 0.0
			state["compression_length"] = 0.0
			state["compression_velocity"] = 0.0
			state["suspension_length"] = full_droop
			state["normal_force"] = 0.0
			state["spring_force"] = 0.0
			state["damper_force"] = 0.0
			state["suspension_force_vector"] = Vector3.ZERO
			state["contact_position"] = to
			state["contact_normal"] = Vector3.UP
		else:
			var hit_position: Vector3 = hit.get("position", to)
			var hit_normal: Vector3 = hit.get("normal", Vector3.UP)
			var distance = from.distance_to(hit_position)
			var suspension_length = clampf(distance - radius, 0.0, full_droop)
			var compression_length = clampf(full_droop - suspension_length, 0.0, travel)
			var compression = compression_length / maxf(travel, 0.01)
			var compression_velocity = (previous_length - suspension_length) / maxf(delta, 0.0001)
			var static_load = mass * gravity * 0.25
			var spring_force = compression * spring_rate
			var damper_force = clampf(compression_velocity * damping, -static_load * 0.65, static_load * 1.25)
			var normal_force = maxf(0.0, static_load + spring_force + damper_force)
			var normal = hit_normal.normalized() if hit_normal.length_squared() > 0.001 else Vector3.UP
			state["grounded"] = true
			state["compression"] = compression
			state["compression_length"] = compression_length
			state["compression_velocity"] = compression_velocity
			state["suspension_length"] = suspension_length
			state["normal_force"] = normal_force
			state["spring_force"] = spring_force
			state["damper_force"] = damper_force
			state["suspension_force_vector"] = normal * normal_force
			state["contact_position"] = hit_position
			state["contact_normal"] = normal
			state["surface"] = hit.get("collider", null)
		state["rest_length"] = rest_length
		state["travel"] = travel
		state["full_droop"] = full_droop
		state["wheel_radius"] = radius
		owner.wheel_states[slot_id] = state


func update_body_ground_pose(owner, config, body: Node3D, delta: float) -> void:
	var grounded_positions: Array[Vector3] = []
	var normals: Array[Vector3] = []
	var radius_total = 0.0
	var radius_count = 0
	for slot_id in WHEEL_ORDER:
		var state: Dictionary = owner.wheel_states.get(slot_id, {})
		if not bool(state.get("grounded", false)):
			continue
		grounded_positions.append(state.get("contact_position", body.global_position))
		normals.append(state.get("contact_normal", Vector3.UP))
		radius_total += float(state.get("wheel_radius", config.tuning.get("wheel_radius", 0.36)))
		radius_count += 1
	if grounded_positions.is_empty():
		return
	var average_y = 0.0
	var average_normal = Vector3.ZERO
	for p in grounded_positions:
		average_y += p.y
	for n in normals:
		average_normal += n
	average_y /= float(grounded_positions.size())
	average_normal = average_normal.normalized() if average_normal.length_squared() > 0.001 else Vector3.UP
	var minimum_y = average_y + maxf(radius_total / maxf(float(radius_count), 1.0), 0.2)
	if body.global_position.y < minimum_y:
		body.global_position.y = lerpf(body.global_position.y, minimum_y, clampf(delta * 16.0, 0.0, 1.0))
		align_to_ground_normal(body, average_normal, delta)
	if body.global_position.y <= minimum_y + 0.01 and owner.velocity.y < 0.0:
		owner.velocity.y = 0.0


func align_to_ground_normal(body: Node3D, normal: Vector3, delta: float) -> void:
	if normal.length_squared() <= 0.001:
		return
	var basis = body.global_transform.basis.orthonormalized()
	var forward = (-basis.z).slide(normal).normalized()
	if forward.length_squared() <= 0.001:
		return
	var target = Basis.looking_at(forward, normal)
	body.global_transform.basis = basis.slerp(target, clampf(delta * 7.0, 0.0, 1.0)).orthonormalized()
