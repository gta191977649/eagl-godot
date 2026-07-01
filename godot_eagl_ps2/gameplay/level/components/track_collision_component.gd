class_name TrackCollisionComponent
extends Node

signal collision_ready(collision_root: Node3D, body_count: int)

@export var collision_parent_path: NodePath
@export var collision_layer := 1
@export var collision_mask := 1

var collision_root: Node3D
var owns_collision_root := false


func build_collision(track_root: Node3D) -> Node3D:
	clear_collision()
	if track_root == null:
		collision_ready.emit(null, 0)
		return null

	var imported_collision := _find_imported_collision_root(track_root)
	if imported_collision != null:
		collision_root = imported_collision
		owns_collision_root = false
		_configure_imported_collision(collision_root)
		var stats := _collision_stats(collision_root)
		if int(stats.get("body_count", 0)) <= 0 or int(stats.get("shape_count", 0)) <= 0:
			push_error("Imported TrackCollision exists but contains %d StaticBody3D and %d CollisionShape3D." % [int(stats.get("body_count", 0)), int(stats.get("shape_count", 0))])
		collision_ready.emit(collision_root, int(stats.get("body_count", 0)))
		return collision_root

	push_error("TrackCollisionComponent requires imported TrackContent/TrackCollision; runtime mesh collision generation is disabled.")
	collision_ready.emit(null, 0)
	return null


func clear_collision() -> void:
	if owns_collision_root and collision_root != null and is_instance_valid(collision_root):
		collision_root.queue_free()
	collision_root = null
	owns_collision_root = false


func _find_imported_collision_root(track_root: Node3D) -> Node3D:
	if track_root.has_meta("eagl_collision_root"):
		return track_root
	var named_root := track_root.get_node_or_null("TrackContent/TrackCollision") as Node3D
	if named_root != null:
		return named_root
	for child in track_root.find_children("*", "Node3D", true, false):
		if bool(child.get_meta("eagl_collision_root", false)):
			return child as Node3D
	return null


func _configure_imported_collision(root: Node) -> void:
	for child in root.get_children():
		if child is StaticBody3D:
			var body := child as StaticBody3D
			body.collision_layer = collision_layer
			body.collision_mask = collision_mask
		elif child is CollisionShape3D:
			var shape_node := child as CollisionShape3D
			shape_node.disabled = false
		_configure_imported_collision(child)


func _collision_stats(root: Node) -> Dictionary:
	var stats := {
		"body_count": 0,
		"shape_count": 0,
	}
	_accumulate_collision_stats(root, stats)
	return stats


func _accumulate_collision_stats(root: Node, stats: Dictionary) -> void:
	for child in root.get_children():
		if child is StaticBody3D:
			stats["body_count"] = int(stats["body_count"]) + 1
		if child is CollisionShape3D and (child as CollisionShape3D).shape != null:
			stats["shape_count"] = int(stats["shape_count"]) + 1
		_accumulate_collision_stats(child, stats)
