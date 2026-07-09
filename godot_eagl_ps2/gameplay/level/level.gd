extends Node3D

const RoadSurfaceSamplerScript = preload("res://eagl/handling/road_surface_sampler.gd")

@export var track_definition: Resource
@export var vehicle_definition: Resource

@onready var track_loader: Node = $Services/TrackLoader
@onready var track_collision: Node = $Services/TrackCollision
@onready var spawn_resolver: Node = $Services/SpawnResolver
@onready var vehicle_spawner: Node = $Services/VehicleSpawner
@onready var ai_spawner: Node = $Services/AISpawnService
@onready var track_boundary_limiter: Node = $Services/TrackBoundaryLimiter
@onready var car_camera: EAGLCarCamera = $Cameras/CarCamera

var _current_track_root: Node3D


func _ready() -> void:
	_ensure_mavs_camera_actions()
	_ensure_gevp_actions()
	_bind_services()
	track_loader.load_track(track_definition)


func _bind_services() -> void:
	if not track_loader.track_ready.is_connected(_on_track_ready):
		track_loader.track_ready.connect(_on_track_ready)
	if not track_loader.track_failed.is_connected(_on_track_failed):
		track_loader.track_failed.connect(_on_track_failed)
	if not vehicle_spawner.player_spawned.is_connected(_on_player_spawned):
		vehicle_spawner.player_spawned.connect(_on_player_spawned)


func _on_track_ready(track_root: Node3D) -> void:
	_current_track_root = track_root
	track_collision.build_collision(track_root)
	spawn_resolver.set_track_root(track_root)
	track_boundary_limiter.set_track_root(track_root)
	await get_tree().physics_frame
	var spawn_transform: Transform3D = spawn_resolver.get_spawn_transform(track_definition.player_start_marker_path)
	vehicle_spawner.spawn_player(vehicle_definition, spawn_transform)
	ai_spawner.spawn_ai(track_root)


func _on_track_failed(message: String) -> void:
	push_error("Level failed to load track: %s" % message)


func _on_player_spawned(vehicle_root: Node3D, player_target: Node3D) -> void:
	_bind_surface_sampler(vehicle_root, player_target)
	var camera_target := _resolve_camera_target(vehicle_root, player_target)
	car_camera.set_target(camera_target)
	car_camera.reset_to_target()
	car_camera.current = true


func _bind_surface_sampler(vehicle_root: Node3D, player_target: Node3D) -> void:
	var sampler_target := _find_surface_sampler_target(player_target)
	if sampler_target == null:
		sampler_target = _find_surface_sampler_target(vehicle_root)
	if sampler_target == null:
		return

	var polygon_root := _find_track_polygon_root(_current_track_root)
	if polygon_root == null:
		push_warning("Level track has no eagl_track_collision_polygons metadata; vehicle will use fallback surface handling.")
		return

	var sampler = RoadSurfaceSamplerScript.new()
	sampler.build_from_track_asset(polygon_root)
	if sampler.surface_count() <= 0:
		push_warning("Level TrackPolygon sampler built no surfaces; vehicle will use fallback surface handling.")
		return

	sampler_target.call("set_surface_sampler", sampler)
	polygon_root.set_meta("eagl_drive_area_sampler", sampler)
	polygon_root.set_meta("eagl_drive_area_sampler_polygon_count", sampler.polygon_count())
	polygon_root.set_meta("eagl_drive_area_sampler_triangle_count", sampler.triangle_count())
	polygon_root.set_meta("eagl_drive_area_sampler_surface_count", sampler.surface_count())
	print("Level TrackPolygon surface sampler enabled: polygons=%s triangles=%s" % [
		sampler.polygon_count(),
		sampler.triangle_count(),
	])


func _find_surface_sampler_target(root: Node) -> Node:
	if root == null:
		return null
	if root.has_method("set_surface_sampler"):
		return root
	for child in root.get_children():
		var found := _find_surface_sampler_target(child)
		if found != null:
			return found
	return null


func _find_track_polygon_root(root: Node3D) -> Node3D:
	if root == null:
		return null
	var track_content := root.get_node_or_null("TrackContent") as Node3D
	if track_content != null and track_content.has_meta("eagl_track_collision_polygons"):
		return track_content
	if root.has_meta("eagl_track_collision_polygons"):
		return root
	for child in root.find_children("*", "Node3D", true, false):
		if child.has_meta("eagl_track_collision_polygons"):
			return child as Node3D
	return null


func _ensure_mavs_camera_actions() -> void:
	_ensure_key_action("Camera Right", [KEY_KP_6])
	_ensure_key_action("Camera Left", [KEY_KP_4])
	_ensure_key_action("Camera Up", [KEY_KP_8])
	_ensure_key_action("Camera Down", [KEY_KP_2])


func _ensure_key_action(action_name: String, keycodes: Array[int]) -> void:
	if not InputMap.has_action(action_name):
		InputMap.add_action(action_name)
	if not InputMap.action_get_events(action_name).is_empty():
		return
	for keycode in keycodes:
		var event := InputEventKey.new()
		event.physical_keycode = keycode
		InputMap.action_add_event(action_name, event)


func _ensure_gevp_actions() -> void:
	_ensure_key_action("Throttle", [KEY_W, KEY_UP])
	_ensure_key_action("Brakes", [KEY_S, KEY_DOWN])
	_ensure_key_action("Steer Left", [KEY_A, KEY_LEFT])
	_ensure_key_action("Steer Right", [KEY_D, KEY_RIGHT])
	_ensure_key_action("Handbrake", [KEY_SPACE])
	_ensure_key_action("Clutch", [KEY_C])
	_ensure_key_action("Toggle Transmission", [KEY_T])
	_ensure_key_action("Shift Up", [KEY_F, KEY_KP_ADD])
	_ensure_key_action("Shift Down", [KEY_R, KEY_KP_SUBTRACT])


func _resolve_camera_target(vehicle_root: Node3D, player_target: Node3D) -> Node3D:
	if vehicle_definition != null and vehicle_definition.camera_target_path != NodePath():
		var from_path := vehicle_root.get_node_or_null(vehicle_definition.camera_target_path) as Node3D
		if from_path != null:
			return from_path
	return player_target
