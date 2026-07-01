class_name TrackLoaderComponent
extends Node

signal track_ready(track_root: Node3D)
signal track_failed(message: String)

@export var target_root_path: NodePath

var current_track: Node3D


func load_track(definition: Resource) -> void:
	clear_track()
	if definition == null:
		track_failed.emit("Missing TrackDefinition")
		return
	if definition.editable_track_scene == null:
		track_failed.emit("TrackDefinition %s has no editable_track_scene" % definition.id)
		return

	var target_root := get_node_or_null(target_root_path) as Node3D
	if target_root == null:
		track_failed.emit("TrackLoader target_root_path is not a Node3D: %s" % target_root_path)
		return

	var track_instance := definition.editable_track_scene.instantiate() as Node3D
	if track_instance == null:
		track_failed.emit("Track scene for %s did not instantiate a Node3D root" % definition.id)
		return

	track_instance.name = definition.id if definition.id != "" else "CurrentTrack"
	target_root.add_child(track_instance)
	current_track = track_instance
	track_ready.emit(current_track)


func clear_track() -> void:
	if current_track != null and is_instance_valid(current_track):
		current_track.queue_free()
	current_track = null
