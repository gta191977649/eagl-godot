class_name VehicleSpawnerComponent
extends Node

signal player_spawned(vehicle_root: Node3D, vehicle_body: VehicleBody3D)

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
	var vehicle_body := _find_vehicle_body(vehicle_root)
	if vehicle_body == null:
		push_error("Vehicle scene for %s has no VehicleBody3D" % definition.id)
		vehicle_root.queue_free()
		return {}

	_configure_player_body(vehicle_body, spawn_transform)
	if disable_embedded_cameras:
		_disable_cameras(vehicle_root)

	player_spawned.emit(vehicle_root, vehicle_body)
	return {
		"vehicle_root": vehicle_root,
		"vehicle_body": vehicle_body,
	}


func _configure_player_body(vehicle_body: VehicleBody3D, spawn_transform: Transform3D) -> void:
	vehicle_body.global_transform = spawn_transform
	vehicle_body.linear_velocity = Vector3.ZERO
	vehicle_body.angular_velocity = Vector3.ZERO
	vehicle_body.sleeping = false
	if "is_current_veh" in vehicle_body:
		vehicle_body.set("is_current_veh", true)
	vehicle_body.add_to_group(player_group)


func _find_vehicle_body(root: Node) -> VehicleBody3D:
	if root is VehicleBody3D:
		return root as VehicleBody3D
	for child in root.get_children():
		var found := _find_vehicle_body(child)
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
