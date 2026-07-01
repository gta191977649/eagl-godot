class_name AISpawnService
extends Node

@export var enabled := false
@export var race_ai_scenes: Array[PackedScene] = []
@export var police_ai_scenes: Array[PackedScene] = []
@export var race_ai_parent_path: NodePath
@export var police_ai_parent_path: NodePath
@export var race_spawn_markers: Array[NodePath] = []
@export var police_spawn_markers: Array[NodePath] = []


func spawn_ai(_track_root: Node3D) -> void:
	if not enabled:
		return
	_spawn_group(race_ai_scenes, race_ai_parent_path, race_spawn_markers)
	_spawn_group(police_ai_scenes, police_ai_parent_path, police_spawn_markers)


func _spawn_group(scenes: Array[PackedScene], parent_path: NodePath, marker_paths: Array[NodePath]) -> void:
	var parent := get_node_or_null(parent_path) as Node3D
	if parent == null:
		return
	for index in range(mini(scenes.size(), marker_paths.size())):
		var scene := scenes[index]
		var marker := get_node_or_null(marker_paths[index]) as Node3D
		if scene == null or marker == null:
			continue
		var vehicle := scene.instantiate() as Node3D
		if vehicle == null:
			continue
		parent.add_child(vehicle)
		vehicle.global_transform = marker.global_transform
