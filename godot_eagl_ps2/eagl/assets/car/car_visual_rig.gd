class_name CarVisualRig
extends RefCounted

const MathUtils = preload("res://eagl/utils/math_utils.gd")
const SLOT_IDS := ["FL", "FR", "RL", "RR"]

var owner: Node3D
var visual_root: Node3D
var wheel_visuals := {}
var wheel_roll_visuals := {}
var wheel_suspension_nodes := {}
var debug_pivot_nodes := {}
var debug_dummy_nodes := {}


func set_owner(target_owner: Node3D) -> void:
	owner = target_owner


func has_wheel_visuals() -> bool:
	return not wheel_visuals.is_empty()


func replace_visual_root(visual: Node3D, physics_origin_offset_ps2: Vector3 = Vector3.ZERO) -> void:
	if owner == null:
		return
	_remove_visual_root("CarVisual")
	_remove_visual_root("GeneratedVisuals")
	if visual != null:
		owner.add_child(visual)
	refresh_bindings(physics_origin_offset_ps2)


func refresh_bindings(physics_origin_offset_ps2: Vector3 = Vector3.ZERO) -> void:
	wheel_visuals.clear()
	wheel_roll_visuals.clear()
	wheel_suspension_nodes.clear()
	debug_pivot_nodes.clear()
	debug_dummy_nodes.clear()
	visual_root = null
	if owner == null:
		return

	var resolved_root := owner.get_node_or_null("CarVisual") as Node3D
	if resolved_root == null:
		resolved_root = owner.get_node_or_null("GeneratedVisuals") as Node3D
	if resolved_root == null:
		return

	visual_root = resolved_root
	visual_root.position = MathUtils.ps2_to_godot_vec3(-physics_origin_offset_ps2)
	for slot_id in SLOT_IDS:
		var pivot_node := visual_root.get_node_or_null("WheelPivots/%s" % slot_id) as Node3D
		if pivot_node != null:
			debug_pivot_nodes[slot_id] = pivot_node
		var suspension_node := visual_root.get_node_or_null("WheelPivots/%s/Suspension" % slot_id) as Node3D
		if suspension_node != null:
			wheel_suspension_nodes[slot_id] = suspension_node
			var steer_node := visual_root.get_node_or_null("WheelPivots/%s/Suspension/Steer" % slot_id) as Node3D
			if steer_node != null:
				wheel_visuals[slot_id] = steer_node
			var roll_node := visual_root.get_node_or_null("WheelPivots/%s/Suspension/Steer/Roll/Spin" % slot_id) as Node3D
			if roll_node == null:
				roll_node = visual_root.get_node_or_null("WheelPivots/%s/Suspension/Steer/Roll" % slot_id) as Node3D
			if roll_node != null:
				wheel_roll_visuals[slot_id] = roll_node

	var dummies_root := visual_root.get_node_or_null("Dummies")
	if dummies_root != null:
		for child in dummies_root.get_children():
			if child is Node3D:
				debug_dummy_nodes[String(child.name)] = child

	fit_collision_shape_to_visual_bounds()


func ensure_generated_visuals(config, wheels: Array) -> void:
	if owner == null or config == null:
		return
	if has_wheel_visuals():
		return

	var generated_root := owner.get_node_or_null("GeneratedVisuals") as Node3D
	if generated_root == null:
		generated_root = Node3D.new()
		generated_root.name = "GeneratedVisuals"
		owner.add_child(generated_root)

	var body_root := generated_root.get_node_or_null("Body") as Node3D
	if body_root == null:
		body_root = Node3D.new()
		body_root.name = "Body"
		generated_root.add_child(body_root)

	var body_mesh := body_root.get_node_or_null("Shell") as MeshInstance3D
	if body_mesh == null:
		body_mesh = MeshInstance3D.new()
		body_mesh.name = "Shell"
		var shell_mesh := BoxMesh.new()
		shell_mesh.size = MathUtils.ps2_to_godot_vec3(config.body_size_ps2).abs()
		body_mesh.mesh = shell_mesh
		var material := StandardMaterial3D.new()
		material.albedo_color = Color(0.82, 0.08, 0.05, 1.0)
		body_mesh.material_override = material
		body_mesh.position = MathUtils.ps2_to_godot_vec3(config.center_of_mass_ps2)
		body_root.add_child(body_mesh)

	var wheel_pivots := generated_root.get_node_or_null("WheelPivots") as Node3D
	if wheel_pivots == null:
		wheel_pivots = Node3D.new()
		wheel_pivots.name = "WheelPivots"
		generated_root.add_child(wheel_pivots)

	var dummies_root := generated_root.get_node_or_null("Dummies") as Node3D
	if dummies_root == null:
		dummies_root = Node3D.new()
		dummies_root.name = "Dummies"
		generated_root.add_child(dummies_root)

	for wheel in wheels:
		var wheel_root := wheel_pivots.get_node_or_null(wheel.slot_id) as Node3D
		if wheel_root == null:
			wheel_root = Node3D.new()
			wheel_root.name = wheel.slot_id
			wheel_root.position = MathUtils.ps2_to_godot_vec3(wheel.local_position_ps2)
			wheel_pivots.add_child(wheel_root)

		var suspension_root := wheel_root.get_node_or_null("Suspension") as Node3D
		if suspension_root == null:
			suspension_root = Node3D.new()
			suspension_root.name = "Suspension"
			wheel_root.add_child(suspension_root)

		var steer_root := suspension_root.get_node_or_null("Steer") as Node3D
		if steer_root == null:
			steer_root = Node3D.new()
			steer_root.name = "Steer"
			suspension_root.add_child(steer_root)

		var roll_root := steer_root.get_node_or_null("Roll") as Node3D
		if roll_root == null:
			roll_root = Node3D.new()
			roll_root.name = "Roll"
			steer_root.add_child(roll_root)

		var spin_root := roll_root.get_node_or_null("Spin") as Node3D
		if spin_root == null:
			spin_root = Node3D.new()
			spin_root.name = "Spin"
			spin_root.set_meta("eagl_spin_direction", -1.0 if wheel.side == "right" else 1.0)
			roll_root.add_child(spin_root)

		var tire_mesh := spin_root.get_node_or_null("Tire") as MeshInstance3D
		if tire_mesh == null:
			tire_mesh = MeshInstance3D.new()
			tire_mesh.name = "Tire"
			var sphere := SphereMesh.new()
			sphere.radius = wheel.wheel_radius
			sphere.height = wheel.wheel_radius * 2.0
			tire_mesh.mesh = sphere
			var wheel_material := StandardMaterial3D.new()
			wheel_material.albedo_color = Color(0.08, 0.08, 0.08, 1.0)
			tire_mesh.material_override = wheel_material
			spin_root.add_child(tire_mesh)

		var dummy_name := "%s_PIVOT" % wheel.slot_id
		if dummies_root.get_node_or_null(dummy_name) == null:
			var dummy := Node3D.new()
			dummy.name = dummy_name
			dummy.position = MathUtils.ps2_to_godot_vec3(wheel.local_position_ps2)
			dummies_root.add_child(dummy)

	if dummies_root.get_node_or_null("BODY_CENTER") == null:
		var center_dummy := Node3D.new()
		center_dummy.name = "BODY_CENTER"
		center_dummy.position = MathUtils.ps2_to_godot_vec3(config.center_of_mass_ps2)
		dummies_root.add_child(center_dummy)

	refresh_bindings(config.physics_origin_offset_ps2)


func update_from_wheels(wheels: Array) -> void:
	for wheel in wheels:
		var wheel_visual = wheel_visuals.get(wheel.slot_id, null)
		var suspension_node = wheel_suspension_nodes.get(wheel.slot_id, null)
		var pivot_node = debug_pivot_nodes.get(wheel.slot_id, null)
		if _is_live_node3d(suspension_node) and _is_live_node3d(pivot_node) and _is_live_node3d(visual_root):
			var suspension_transform: Node3D = suspension_node
			suspension_transform.position = MathUtils.ps2_to_godot_vec3(wheel.world_wheel_center_ps2 - wheel.world_pivot_ps2)
		elif _is_live_node3d(wheel_visual):
			var target_position = MathUtils.ps2_to_godot_vec3(wheel.world_wheel_center_ps2)
			var wheel_node: Node3D = wheel_visual
			wheel_node.global_position = target_position
		if not _is_live_node3d(wheel_visual):
			continue
		var steer_node: Node3D = wheel_visual
		var steer_rotation = steer_node.rotation
		steer_rotation.y = wheel.steer_angle
		steer_node.rotation = steer_rotation
		var roll_visual = wheel_roll_visuals.get(wheel.slot_id, null)
		if _is_live_node3d(roll_visual):
			var roll_node: Node3D = roll_visual
			var roll_rotation = roll_node.rotation
			roll_rotation.x = wheel.roll_angle * float(roll_node.get_meta("eagl_spin_direction", 1.0))
			roll_node.rotation = roll_rotation


func fit_collision_shape_to_visual_bounds() -> void:
	if owner == null or visual_root == null:
		return
	var collision_shape := owner.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if collision_shape == null:
		return
	var box_shape := collision_shape.shape as BoxShape3D
	if box_shape == null:
		return
	var body_root := visual_root.get_node_or_null("Body") as Node3D
	if body_root == null:
		return
	var has_bounds := false
	var min_point := Vector3.ZERO
	var max_point := Vector3.ZERO
	for child in body_root.get_children():
		if not (child is MeshInstance3D):
			continue
		var mesh_instance := child as MeshInstance3D
		var local_aabb := mesh_instance.get_aabb()
		var corners := [
			local_aabb.position,
			local_aabb.position + Vector3(local_aabb.size.x, 0.0, 0.0),
			local_aabb.position + Vector3(0.0, local_aabb.size.y, 0.0),
			local_aabb.position + Vector3(0.0, 0.0, local_aabb.size.z),
			local_aabb.position + Vector3(local_aabb.size.x, local_aabb.size.y, 0.0),
			local_aabb.position + Vector3(local_aabb.size.x, 0.0, local_aabb.size.z),
			local_aabb.position + Vector3(0.0, local_aabb.size.y, local_aabb.size.z),
			local_aabb.position + local_aabb.size,
		]
		for corner in corners:
			var point: Vector3 = owner.to_local(mesh_instance.global_transform * corner)
			if not has_bounds:
				min_point = point
				max_point = point
				has_bounds = true
			else:
				min_point = min_point.min(point)
				max_point = max_point.max(point)
	if not has_bounds:
		return
	box_shape.size = (max_point - min_point).abs()
	collision_shape.position = (min_point + max_point) * 0.5


func _remove_visual_root(node_name: String) -> void:
	var existing := owner.get_node_or_null(node_name)
	if existing != null:
		owner.remove_child(existing)
		existing.free()


func _is_live_node3d(node: Variant) -> bool:
	return node is Node3D and is_instance_valid(node)
