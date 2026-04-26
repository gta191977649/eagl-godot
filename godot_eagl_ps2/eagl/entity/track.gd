class_name EAGLTrack
extends Node3D

const TrackRouteBuilderScript := preload("res://eagl/rendering/track_route_builder.gd")

signal loading_started(track_id: String)
signal track_loaded(track_id: String, track_node: Node3D, stats: Dictionary)
signal track_failed(track_id: String, message: String)

@export var platform := "EAGL_HOTPUSUIT2_PS2"
@export_global_dir var game_root := ""
@export var track_id := "31"
@export var load_on_ready := true
@export var place_scenery_instances := true
@export var expand_scenery_instances := false
@export var generate_lods := true
@export var shadow_texture_visibility_distance := 300.0
@export var shadow_texture_visibility_margin := 80.0
@export var track_use_scene_lighting := false
@export var build_collision := true
@export var collision_debug_visible := false
@export var collision_debug_surface_offset := 0.08
@export var collision_layer := 1
@export var collision_mask := 1
@export var build_route := true
@export var route_debug_visible := false
@export var route_debug_height_offset := 1.0
@export var route_loop := true
@export var initialize_manager := true
@export var force_reinitialize_manager := false
@export_enum(
	"linear_mipmap",
	"linear",
	"nearest_mipmap",
	"nearest",
	"linear_mipmap_anisotropic",
	"nearest_mipmap_anisotropic"
) var texture_filter_mode := "linear_mipmap"

var _track_node: Node3D
var _is_loading := false
var _last_error := ""
var _stats: Dictionary = {}

@onready var _content_root := get_node_or_null("TrackContent") as Node3D


func _ready() -> void:
	if _content_root == null:
		_content_root = Node3D.new()
		_content_root.name = "TrackContent"
		add_child(_content_root)
	if load_on_ready:
		call_deferred("load_track")


func load_track(next_track_id := "") -> void:
	if _is_loading:
		return
	if next_track_id != "":
		track_id = next_track_id

	_is_loading = true
	_last_error = ""
	_stats.clear()
	loading_started.emit(track_id)

	if not _ensure_manager_ready():
		_fail_load(_last_error)
		return

	var next_track_node := EAGLManager.load_track(track_id) as Node3D
	var load_error := _track_load_error(next_track_node)
	if load_error != "":
		if next_track_node != null:
			next_track_node.queue_free()
		_fail_load(load_error)
		return

	_replace_track_node(next_track_node)
	_stats = EAGLManager.get_stats().duplicate(true)
	_is_loading = false
	track_loaded.emit(track_id, _track_node, _stats.duplicate(true))


func reload_track() -> void:
	load_track()


func clear_track() -> void:
	if _track_node != null and is_instance_valid(_track_node):
		if _track_node.get_parent() != null:
			_track_node.get_parent().remove_child(_track_node)
		_track_node.queue_free()
	_track_node = null
	_stats.clear()


func set_collision_debug_visible(visible: bool) -> void:
	collision_debug_visible = visible
	_apply_collision_debug_visible()


func set_route_debug_visible(visible: bool) -> void:
	route_debug_visible = visible
	_apply_route_debug_visible()


func get_nearest_route_point(world_position: Vector3) -> Dictionary:
	if _track_node == null:
		return {}
	var route_points: Array = _track_node.get_meta("eagl_route_points", [])
	var nearest := TrackRouteBuilderScript.nearest_route_point(route_points, _track_node.to_local(world_position), route_loop)
	if nearest.is_empty():
		return nearest
	nearest["local_position"] = nearest.get("position", Vector3.ZERO)
	nearest["position"] = _track_node.to_global(nearest["local_position"])
	return nearest


func get_track_node() -> Node3D:
	return _track_node


func get_stats() -> Dictionary:
	return _stats.duplicate(true)


func get_last_error() -> String:
	return _last_error


func is_loading() -> bool:
	return _is_loading


func _ensure_manager_ready() -> bool:
	if not initialize_manager and not EAGLManager.is_initialized():
		_last_error = "EAGLManager is not initialized"
		push_error(_last_error)
		return false
	if initialize_manager and (force_reinitialize_manager or not EAGLManager.is_initialized() or _manager_options_differ()):
		var resolved_game_root := _resolved_game_root()
		if resolved_game_root == "":
			_last_error = "Track requires EAGLManager game_root, exported game_root, ProjectSettings eagl/game_root, or EAGL_HP2_GAME_ROOT"
			push_error(_last_error)
			return false
		var ok: bool = EAGLManager.initialize(platform, resolved_game_root, _build_loader_options())
		if not ok:
			_last_error = EAGLManager.last_error
			return false
	return true


func _build_loader_options() -> Dictionary:
	return {
		"place_scenery_instances": place_scenery_instances,
		"expand_scenery_instances": expand_scenery_instances,
		"generate_lods": generate_lods,
		"shadow_texture_visibility_distance": shadow_texture_visibility_distance,
		"shadow_texture_visibility_margin": shadow_texture_visibility_margin,
		"texture_filter_mode": texture_filter_mode,
		"track_use_scene_lighting": track_use_scene_lighting,
		"build_collision": build_collision,
		"collision_layer": collision_layer,
		"collision_mask": collision_mask,
		"collision_debug_visible": collision_debug_visible,
		"collision_debug_surface_offset": collision_debug_surface_offset,
		"build_route": build_route,
		"route_debug_visible": route_debug_visible,
		"route_debug_height_offset": route_debug_height_offset,
		"route_loop": route_loop,
	}


func _manager_options_differ() -> bool:
	if not EAGLManager.is_initialized():
		return true
	var desired := _build_loader_options()
	var current := EAGLManager.get_options() if EAGLManager.has_method("get_options") else {}
	for key in desired.keys():
		if not current.has(key):
			return true
		if current[key] != desired[key]:
			return true
	return false


func _resolved_game_root() -> String:
	if EAGLManager.is_initialized():
		var manager_root := EAGLManager.get_game_root()
		if manager_root != "":
			return manager_root
	if game_root != "":
		return game_root
	var project_root := str(ProjectSettings.get_setting("eagl/game_root", ""))
	if project_root != "":
		return project_root
	return OS.get_environment("EAGL_HP2_GAME_ROOT")


func _replace_track_node(next_track_node: Node3D) -> void:
	clear_track()
	_track_node = next_track_node
	_track_node.name = "TrackRoot"
	_track_node.visible = true
	_track_node.transform = Transform3D.IDENTITY
	_content_root.add_child(_track_node)
	_track_node.propagate_call("set_visible", [true])
	_apply_collision_debug_visible()
	_apply_route_debug_visible()
	_track_node.force_update_transform()


func _apply_collision_debug_visible() -> void:
	if _track_node == null:
		return
	for node in _track_node.find_children("*", "MeshInstance3D", true, false):
		if bool(node.get_meta("eagl_collision_debug_overlay", false)):
			node.visible = collision_debug_visible


func _apply_route_debug_visible() -> void:
	if _track_node == null:
		return
	for node in _track_node.find_children("*", "GeometryInstance3D", true, false):
		if bool(node.get_meta("eagl_route_debug_overlay", false)):
			node.visible = route_debug_visible


func _track_load_error(node: Node3D) -> String:
	if node == null:
		return EAGLManager.last_error if EAGLManager.last_error != "" else "Track loader returned no node"
	if node.has_meta("error"):
		return String(node.get_meta("error"))
	return ""


func _fail_load(message: String) -> void:
	_last_error = message
	_is_loading = false
	track_failed.emit(track_id, _last_error)
