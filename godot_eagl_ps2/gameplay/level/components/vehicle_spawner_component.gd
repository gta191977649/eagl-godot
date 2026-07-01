class_name VehicleSpawnerComponent
extends Node

signal player_spawned(vehicle_root: Node3D, player_target: Node3D)

@export var player_parent_path: NodePath
@export var player_group := "Player_car"
@export var disable_embedded_cameras := true


func spawn_player(definition: Resource, spawn_transform: Transform3D) -> Dictionary:
	if definition == null or definition.vehicle_scene == null:
		push_error("VehicleSpawner missing VehicleDefinition or vehicle_scene")
		return {}

	var parent := get_node_or_null(player_parent_path) as Node3D
	if parent == null:
		push_error("VehicleSpawner player_parent_path is not a Node3D: %s" % player_parent_path)
		return {}

	_clear_children(parent)
	var vehicle_root := definition.vehicle_scene.instantiate() as Node3D
	if vehicle_root == null:
		push_error("Vehicle scene for %s did not instantiate a Node3D root" % definition.id)
		return {}

	parent.add_child(vehicle_root)
	var player_target := _resolve_player_target(definition, vehicle_root)
	if player_target == null:
		push_error("Vehicle scene for %s has no spawn target Node3D" % definition.id)
		vehicle_root.queue_free()
		return {}

	_configure_player_target(player_target, spawn_transform, float(definition.spawn_vertical_offset))
	if disable_embedded_cameras:
		_disable_cameras(vehicle_root)

	player_spawned.emit(vehicle_root, player_target)
	return {
		"vehicle_root": vehicle_root,
		"player_target": player_target,
	}


func _configure_player_target(player_target: Node3D, spawn_transform: Transform3D, spawn_vertical_offset: float) -> void:
	var adjusted_transform := spawn_transform
	adjusted_transform.origin += Vector3.UP * spawn_vertical_offset
	player_target.global_transform = adjusted_transform
	if player_target is PhysicsBody3D:
		var body := player_target as PhysicsBody3D
		if "linear_velocity" in body:
			body.set("linear_velocity", Vector3.ZERO)
		if "angular_velocity" in body:
			body.set("angular_velocity", Vector3.ZERO)
		if "sleeping" in body:
			body.set("sleeping", false)
	_reset_motion_state_recursive(player_target)
	if "is_current_veh" in player_target:
		player_target.set("is_current_veh", true)
		if player_target.has_method("assign_vehicle"):
			player_target.call("assign_vehicle")
	player_target.add_to_group(player_group)


func _resolve_player_target(definition: Resource, root: Node3D) -> Node3D:
	if definition != null and definition.spawn_target_path != NodePath():
		var from_path := root.get_node_or_null(definition.spawn_target_path) as Node3D
		if from_path != null:
			return from_path
	var body := _find_preferred_body(root)
	if body != null:
		return body
	return root


func _find_preferred_body(root: Node) -> Node3D:
	if root is VehicleBody3D:
		return root as Node3D
	if root is RigidBody3D:
		return root as Node3D
	for child in root.get_children():
		var found := _find_preferred_body(child)
		if found != null:
			return found
	return null


func _disable_cameras(root: Node) -> void:
	if root is Camera3D:
		(root as Camera3D).current = false
	for child in root.get_children():
		_disable_cameras(child)


func _clear_children(parent: Node) -> void:
	for child in parent.get_children():
		child.queue_free()


func _reset_motion_state_recursive(node: Node) -> void:
	if node is Node3D and "previous_global_position" in node:
		node.set("previous_global_position", (node as Node3D).global_position)
	if "previous_velocity" in node:
		node.set("previous_velocity", Vector3.ZERO)
	if "local_velocity" in node:
		node.set("local_velocity", Vector3.ZERO)
	if "force_vector" in node:
		node.set("force_vector", Vector2.ZERO)
	if "slip_vector" in node:
		node.set("slip_vector", Vector2.ZERO)
	if "delta_time" in node:
		node.set("delta_time", 0.0)
	if "speed" in node:
		node.set("speed", 0.0)
	if "throttle_input" in node:
		node.set("throttle_input", 0.0)
	if "brake_input" in node:
		node.set("brake_input", 0.0)
	if "steering_input" in node:
		node.set("steering_input", 0.0)
	if "handbrake_input" in node:
		node.set("handbrake_input", 0.0)
	if "clutch_input" in node:
		node.set("clutch_input", 0.0)
	for child in node.get_children():
		_reset_motion_state_recursive(child)
