extends Node3D

@export var track_definition: Resource
@export var vehicle_definition: Resource

@onready var track_loader: Node = $Services/TrackLoader
@onready var track_collision: Node = $Services/TrackCollision
@onready var spawn_resolver: Node = $Services/SpawnResolver
@onready var vehicle_spawner: Node = $Services/VehicleSpawner
@onready var ai_spawner: Node = $Services/AISpawnService
@onready var car_camera: EAGLCarCamera = $Cameras/CarCamera


func _ready() -> void:
	_ensure_mavs_camera_actions()
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
	track_collision.build_collision(track_root)
	spawn_resolver.set_track_root(track_root)
	await get_tree().physics_frame
	var spawn_transform: Transform3D = spawn_resolver.get_spawn_transform(track_definition.player_start_marker_path)
	vehicle_spawner.spawn_player(vehicle_definition, spawn_transform)
	ai_spawner.spawn_ai(track_root)


func _on_track_failed(message: String) -> void:
	push_error("Level failed to load track: %s" % message)


func _on_player_spawned(_vehicle_root: Node3D, vehicle_body: VehicleBody3D) -> void:
	car_camera.set_target(vehicle_body)
	car_camera.reset_to_target()
	car_camera.current = true


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
