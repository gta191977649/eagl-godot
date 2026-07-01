class_name SpawnResolverComponent
extends Node

@export var collision_mask := 1
@export var raycast_up_distance := 50.0
@export var raycast_down_distance := 200.0
@export var start_forward_offset := 4.0
@export var vehicle_spawn_clearance := 0.3
@export var flip_spawn_forward := false

var track_root: Node3D


func set_track_root(next_track_root: Node3D) -> void:
	track_root = next_track_root


func get_spawn_transform(marker_path: NodePath, _vehicle_body: VehicleBody3D = null) -> Transform3D:
	var marker := _get_marker(marker_path)
	if marker == null:
		push_warning("Spawn marker not found: %s" % marker_path)
		return Transform3D(Basis.IDENTITY, Vector3.UP * vehicle_spawn_clearance)

	var basis := marker.global_transform.basis.orthonormalized()
	if flip_spawn_forward:
		basis = basis.rotated(Vector3.UP, PI).orthonormalized()

	var forward := (basis * Vector3(0.0, 0.0, 1.0)).normalized()
	var origin := marker.global_position + forward * start_forward_offset
	var ground_point = _raycast_ground(origin)
	if ground_point != null:
		origin = ground_point + Vector3.UP * vehicle_spawn_clearance
	else:
		push_error("SpawnResolverComponent: ground raycast missed near %s with collision_mask=%d" % [origin, collision_mask])
		origin.y += vehicle_spawn_clearance

	return Transform3D(basis, origin)


func _get_marker(marker_path: NodePath) -> Node3D:
	if track_root == null:
		return null
	return track_root.get_node_or_null(marker_path) as Node3D


func _raycast_ground(origin: Vector3):
	var world := get_viewport().world_3d
	if world == null:
		return null
	var from := origin + Vector3.UP * raycast_up_distance
	var to := origin - Vector3.UP * raycast_down_distance
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = collision_mask
	var hit := world.direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return null
	return hit.get("position", origin)
