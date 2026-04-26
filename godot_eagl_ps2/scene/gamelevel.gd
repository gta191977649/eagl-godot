extends Node3D

const CarConfigScript = preload("res://eagl/handling/car_config.gd")
const CarLoaderScript = preload("res://eagl/assets/car/car_loader.gd")
const GlobalBHandlingLoaderScript = preload("res://eagl/handling/globalb_handling_loader.gd")

const DEFAULT_PLATFORM := "EAGL_HOTPUSUIT2_PS2"
const CAMERA_DISTANCE := 8.5
const CAMERA_TARGET_HEIGHT := 1.55
const CAMERA_LOOK_AHEAD := 2.75
const CAMERA_MOUSE_SENSITIVITY := 0.0035
const CAMERA_MIN_PITCH := deg_to_rad(-18.0)
const CAMERA_MAX_PITCH := deg_to_rad(45.0)

@export var platform := DEFAULT_PLATFORM
@export_global_dir var game_root := ""
@export var track_id := "31"
@export var initial_car_id := "CORVETTE"
@export_enum("FWD", "RWD", "AWD") var drive_type := "RWD"
@export_file("*.json") var handling_json_path := ""

@export var place_scenery_instances := true
@export var expand_scenery_instances := false
@export var generate_lods := true
@export var shadow_texture_visibility_distance := 300.0
@export var shadow_texture_visibility_margin := 80.0
@export var track_use_scene_lighting := false
@export var ambient_light_energy := 1.65
@export var build_collision := true
@export var collision_layer := 1
@export var collision_mask := 1
@export var car_collision_layer := 1
@export var car_collision_mask := 1
@export var build_route := true
@export var route_loop := true
@export var enable_route_respawn := true
@export var fall_respawn_drop := 25.0
@export var respawn_height_offset := 0.25
@export var respawn_cooldown := 1.0
@export_enum(
	"linear_mipmap",
	"linear",
	"nearest_mipmap",
	"nearest",
	"linear_mipmap_anisotropic",
	"nearest_mipmap_anisotropic"
) var texture_filter_mode := "linear_mipmap"

@export var spawn_height_offset := 0.02
@export var start_direction_flip := false
@export var start_line_forward_offset := 4.0
@export var camera_near := 0.1
@export var camera_far_min := 30000.0
@export var camera_far_bounds_scale := 2.5

@onready var track: EAGLTrack = $Track
@onready var car: EAGLCar = $Car
@onready var camera: Camera3D = $FollowCamera

var _car_loader = null
var _camera_yaw := 0.0
var _camera_pitch := deg_to_rad(14.0)
var _camera_target_position := Vector3.ZERO
var _spawn_transform := Transform3D.IDENTITY
var _car_spawned := false
var _respawn_cooldown_remaining := 0.0


func _ready() -> void:
	_ensure_input_actions()
	_configure_track()
	_configure_car_collision()
	_bind_track_signals()
	_prepare_car_config()
	track.load_track(track_id)


func _process(delta: float) -> void:
	if _car_spawned:
		_update_camera(delta)


func _physics_process(delta: float) -> void:
	if _respawn_cooldown_remaining > 0.0:
		_respawn_cooldown_remaining = maxf(_respawn_cooldown_remaining - delta, 0.0)
	if _car_spawned:
		_check_route_respawn()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event.is_action_pressed("car_reset"):
		_reset_car_to_nearest_route_input()
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_camera_yaw -= event.relative.x * CAMERA_MOUSE_SENSITIVITY
		_camera_pitch = clampf(_camera_pitch - event.relative.y * CAMERA_MOUSE_SENSITIVITY, CAMERA_MIN_PITCH, CAMERA_MAX_PITCH)


func _configure_track() -> void:
	track.platform = platform
	track.game_root = game_root
	track.track_id = track_id
	track.load_on_ready = false
	track.place_scenery_instances = place_scenery_instances
	track.expand_scenery_instances = expand_scenery_instances
	track.generate_lods = generate_lods
	track.shadow_texture_visibility_distance = shadow_texture_visibility_distance
	track.shadow_texture_visibility_margin = shadow_texture_visibility_margin
	track.texture_filter_mode = texture_filter_mode
	track.track_use_scene_lighting = track_use_scene_lighting
	track.build_collision = build_collision
	track.collision_layer = collision_layer
	track.collision_mask = collision_mask
	track.collision_debug_visible = false
	track.build_route = build_route
	track.route_debug_visible = false
	track.route_loop = route_loop
	track.initialize_manager = true


func _configure_car_collision() -> void:
	car.collision_layer = car_collision_layer
	car.collision_mask = car_collision_mask | collision_layer


func _bind_track_signals() -> void:
	if not track.track_loaded.is_connected(_on_track_loaded):
		track.track_loaded.connect(_on_track_loaded)
	if not track.track_failed.is_connected(_on_track_failed):
		track.track_failed.connect(_on_track_failed)


func _prepare_car_config() -> void:
	var car_id := _resolved_initial_car_id()
	var config = _build_runtime_config_for_car(car_id, 1, drive_type)
	if config != null:
		car.apply_config(config)
	_seat_car_from_config(car)


func _on_track_loaded(_loaded_track_id: String, track_node: Node3D, _stats: Dictionary) -> void:
	_apply_gameplay_lighting(track_node)
	_ensure_track_collision_enabled(track_node)
	_ensure_track_route_enabled(track_node)
	_load_car_visual()
	_set_shadow_casting_recursive(track_node, false)
	_set_shadow_casting_recursive(car, true)
	_spawn_transform = _start_line_spawn_transform(track_node)
	car.reset_runtime_state(_spawn_transform)
	car.sync_wheel_slots_from_visual()
	_configure_camera_clip(track_node)
	_seed_camera_from_car()
	_car_spawned = true
	camera.current = true


func _on_track_failed(failed_track_id: String, message: String) -> void:
	_car_spawned = false
	push_error("Gamelevel failed to load track %s: %s" % [failed_track_id, message])


func _ensure_track_collision_enabled(track_node: Node3D) -> void:
	if not build_collision:
		return
	var collision_root := track_node.get_node_or_null("TrackCollision")
	var body_count := int(track_node.get_meta("eagl_collision_body_count", 0))
	var shape_count := int(track_node.get_meta("eagl_collision_shape_count", 0))
	if collision_root == null or body_count <= 0 or shape_count <= 0:
		push_error("Gamelevel track loaded without collision bodies; vehicle may fall through the road")
		return
	for node in collision_root.find_children("*", "StaticBody3D", true, false):
		var body := node as StaticBody3D
		if body == null:
			continue
		body.collision_layer = collision_layer
		body.collision_mask = collision_mask
	print("Gamelevel collision enabled: bodies=%s shapes=%s layer=%s mask=%s" % [
		body_count,
		shape_count,
		collision_layer,
		collision_mask,
	])


func _ensure_track_route_enabled(track_node: Node3D) -> void:
	if not build_route:
		return
	var route_count := int(track_node.get_meta("eagl_route_point_count", 0))
	if route_count <= 0:
		push_warning("Gamelevel track loaded without route points; fall respawn will be disabled")
		return
	print("Gamelevel route enabled: points=%s" % route_count)


func _load_car_visual() -> void:
	if car.config == null:
		return
	var resolved_root := _resolved_game_root()
	_car_loader = CarLoaderScript.new(resolved_root)
	var visual = _car_loader.load(String(car.config.car_name), car.config)
	if visual == null:
		push_warning("Failed to load car visual for %s: %s" % [car.config.car_name, _car_loader.last_error])
		car.replace_visual(null)
		return
	car.replace_visual(visual)


func _start_line_spawn_transform(track_node: Node3D) -> Transform3D:
	var marker := _find_start_line_marker(track_node)
	if marker == null:
		push_warning("Gamelevel could not find a start-line marker; spawning car at origin")
		var fallback := Transform3D.IDENTITY
		fallback.origin.y = _spawn_height_for_config(car.config) + spawn_height_offset
		return fallback

	var bounds := _node_global_bounds(marker)
	var origin := marker.global_position
	if bounds.size != Vector3.ZERO:
		origin = bounds.get_center()

	var basis := _start_line_basis(marker)
	if start_direction_flip:
		basis = basis.rotated(Vector3.UP, PI)
	var forward := (basis * Vector3(0.0, 0.0, 1.0)).normalized()
	if forward.length_squared() <= 0.001:
		forward = Vector3(0.0, 0.0, 1.0)

	origin += forward * start_line_forward_offset
	origin.y += _spawn_height_for_config(car.config) + spawn_height_offset
	return Transform3D(basis, origin)


func _find_start_line_marker(track_node: Node3D) -> Node3D:
	var marker_root := track_node.get_node_or_null("TrackMarkers")
	if marker_root == null:
		marker_root = track_node
	var candidates := _start_line_candidates(marker_root)
	if candidates.is_empty() and marker_root != track_node:
		candidates = _start_line_candidates(track_node)
	if candidates.is_empty():
		return null
	candidates.sort_custom(func(a: Node3D, b: Node3D) -> bool:
		var a_bounds := _node_global_bounds(a)
		var b_bounds := _node_global_bounds(b)
		return a_bounds.size.length_squared() > b_bounds.size.length_squared()
	)
	return candidates[0]


func _start_line_basis(marker: Node3D) -> Basis:
	if marker is MultiMeshInstance3D:
		var marker_multimesh := (marker as MultiMeshInstance3D).multimesh
		if marker_multimesh != null and marker_multimesh.instance_count > 0:
			return (marker.global_transform.basis * marker_multimesh.get_instance_transform(0).basis).orthonormalized()
	return marker.global_transform.basis.orthonormalized()


func _start_line_candidates(root: Node) -> Array[Node3D]:
	var out: Array[Node3D] = []
	_collect_start_line_candidates(root, out)
	return out


func _collect_start_line_candidates(node: Node, out: Array[Node3D]) -> void:
	if node is Node3D:
		var node_3d := node as Node3D
		var category := String(node.get_meta("bun_category", "")).to_upper()
		var node_name := node.name.to_upper()
		if category == "TRACK_MARKER" or node_name.contains("STARTLINE"):
			out.append(node_3d)
	for child in node.get_children():
		_collect_start_line_candidates(child, out)


func _apply_gameplay_lighting(track_node: Node3D) -> void:
	for node in track_node.find_children("*", "WorldEnvironment", true, false):
		var world_environment := node as WorldEnvironment
		if world_environment == null or world_environment.environment == null:
			continue
		world_environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		world_environment.environment.ambient_light_energy = ambient_light_energy
	for node in track_node.find_children("EAGL_Sun", "DirectionalLight3D", true, false):
		var sun := node as DirectionalLight3D
		if sun == null:
			continue
		if not sun.has_meta("eagl_enabled_light_energy"):
			sun.set_meta("eagl_enabled_light_energy", sun.light_energy)
		sun.shadow_enabled = true
		sun.light_energy = float(sun.get_meta("eagl_enabled_light_energy", sun.light_energy))
		sun.light_cull_mask = sun.light_cull_mask | 1
		sun.visible = true


func _set_shadow_casting_recursive(root: Node, enabled: bool) -> void:
	if root is GeometryInstance3D:
		var geometry := root as GeometryInstance3D
		geometry.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED if enabled else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for child in root.get_children():
		_set_shadow_casting_recursive(child, enabled)


func _configure_camera_clip(track_node: Node3D) -> void:
	camera.near = camera_near
	var far_distance := camera_far_min
	var bounds: AABB = track_node.get_meta("eagl_bounds", AABB())
	if bounds.size != Vector3.ZERO:
		far_distance = maxf(far_distance, bounds.size.length() * camera_far_bounds_scale)
	camera.far = far_distance


func _update_camera(_delta: float) -> void:
	var forward: Vector3 = car.global_transform.basis * Vector3(0.0, 0.0, 1.0)
	var desired_target := car.global_transform.origin + Vector3.UP * CAMERA_TARGET_HEIGHT + forward * CAMERA_LOOK_AHEAD
	var horizontal_radius := cos(_camera_pitch) * CAMERA_DISTANCE
	var orbit_offset := Vector3(
		-cos(_camera_yaw) * horizontal_radius,
		sin(_camera_pitch) * CAMERA_DISTANCE,
		-sin(_camera_yaw) * horizontal_radius
	)
	_camera_target_position = desired_target
	camera.global_position = desired_target + orbit_offset
	camera.look_at(_camera_target_position, Vector3.UP)


func _seed_camera_from_car() -> void:
	var forward: Vector3 = (car.global_transform.basis * Vector3(0.0, 0.0, 1.0)).normalized()
	_camera_yaw = atan2(-forward.z, forward.x)
	_camera_target_position = car.global_transform.origin + Vector3.UP * CAMERA_TARGET_HEIGHT
	_update_camera(0.0)


func _check_route_respawn() -> void:
	if not enable_route_respawn or _respawn_cooldown_remaining > 0.0 or track == null:
		return
	_reset_car_to_nearest_route(true)


func _reset_car_to_nearest_route(only_if_fallen := false) -> void:
	if not _car_spawned or track == null:
		return
	var nearest := track.get_nearest_route_point(car.global_position)
	if nearest.is_empty():
		return
	if only_if_fallen:
		var route_position: Vector3 = nearest.get("position", Vector3.ZERO)
		if car.global_position.y >= route_position.y - fall_respawn_drop:
			return
		if _respawn_cooldown_remaining > 0.0:
			return
	_respawn_at_route_point(nearest)


func _reset_car_to_nearest_route_input() -> void:
	if _respawn_cooldown_remaining > 0.0:
		return
	_reset_car_to_nearest_route(false)


func _respawn_at_route_point(route_hit: Dictionary) -> void:
	var route_position: Vector3 = route_hit.get("position", car.global_position)
	var forward: Vector3 = route_hit.get("forward", car.global_transform.basis * Vector3(0.0, 0.0, 1.0))
	forward.y = 0.0
	if forward.length_squared() <= 0.001:
		forward = Vector3(0.0, 0.0, 1.0)
	else:
		forward = forward.normalized()
	var up := Vector3.UP
	var right := up.cross(forward).normalized()
	var basis := Basis(right, up, forward).orthonormalized()
	var origin := route_position + Vector3.UP * (_spawn_height_for_config(car.config) + respawn_height_offset)
	car.reset_runtime_state(Transform3D(basis, origin))
	_seed_camera_from_car()
	_respawn_cooldown_remaining = respawn_cooldown
	print("Gamelevel respawned car at route segment %s" % int(route_hit.get("segment_index", -1)))


func _ensure_input_actions() -> void:
	_ensure_key_action("car_accelerate", [KEY_W, KEY_UP])
	_ensure_key_action("car_brake", [KEY_S, KEY_DOWN])
	_ensure_key_action("car_steer_left", [KEY_A, KEY_LEFT])
	_ensure_key_action("car_steer_right", [KEY_D, KEY_RIGHT])
	_ensure_key_action("car_handbrake", [KEY_SPACE])
	_ensure_key_action("car_reset", [KEY_R])


func _ensure_key_action(action_name: String, keycodes: Array[int]) -> void:
	if not InputMap.has_action(action_name):
		InputMap.add_action(action_name)
	if not InputMap.action_get_events(action_name).is_empty():
		return
	for keycode in keycodes:
		var event := InputEventKey.new()
		event.physical_keycode = keycode
		InputMap.action_add_event(action_name, event)


func _build_runtime_config_for_car(car_name: String, duplicate_index: int = 1, selected_drive_type: String = ""):
	var resolved_drive_type := selected_drive_type if selected_drive_type != "" else drive_type
	var loaded = _load_authoritative_handling_config(car_name, duplicate_index, resolved_drive_type)
	if loaded != null:
		return loaded
	var config = CarConfigScript.new()
	if car != null and car.config != null:
		config = car.config.duplicate(true)
	config.car_name = car_name
	config.duplicate_index = duplicate_index
	config.drive_type = resolved_drive_type
	return config


func _load_authoritative_handling_config(car_name: String, duplicate_index: int = 1, selected_drive_type: String = "") -> Resource:
	if car_name == "":
		return null
	var resolved_drive_type := selected_drive_type if selected_drive_type != "" else drive_type
	var loader = GlobalBHandlingLoaderScript.new()
	var globalb_path := _resolved_globalb_path()
	if globalb_path != "":
		var binary_loaded = loader.load_config_from_globalb(globalb_path, car_name, duplicate_index, resolved_drive_type)
		if binary_loaded != null:
			return binary_loaded
	var json_path := _resolved_handling_json_path()
	if json_path == "" or not FileAccess.file_exists(json_path):
		return null
	return loader.load_config(json_path, car_name, duplicate_index, resolved_drive_type)


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


func _resolved_handling_json_path() -> String:
	if handling_json_path != "":
		return handling_json_path
	var project_path := str(ProjectSettings.get_setting("eagl/handling_json", ""))
	if project_path != "":
		return project_path
	return OS.get_environment("EAGL_HP2_HANDLING_JSON")


func _resolved_globalb_path() -> String:
	var resolved_root := _resolved_game_root()
	if resolved_root == "":
		return ""
	var globalb_path := resolved_root.path_join("GLOBAL").path_join("GLOBALB.BUN")
	if FileAccess.file_exists(globalb_path):
		return globalb_path
	return ""


func _resolved_cars_dir() -> String:
	var resolved_root := _resolved_game_root()
	if resolved_root == "":
		return ""
	var candidates: Array[String] = [
		resolved_root.path_join("CARS"),
		resolved_root,
	]
	for candidate in candidates:
		if not DirAccess.dir_exists_absolute(candidate):
			continue
		if candidate.get_file().to_upper() == "CARS":
			return candidate
		var nested := candidate.path_join("CARS")
		if DirAccess.dir_exists_absolute(nested):
			return nested
	return ""


func _resolved_initial_car_id() -> String:
	var desired := initial_car_id.strip_edges().to_upper()
	if desired != "":
		var cars_dir := _resolved_cars_dir()
		if cars_dir == "" or DirAccess.dir_exists_absolute(cars_dir.path_join(desired)):
			return desired
	if car != null and car.config != null and String(car.config.car_name) != "":
		return String(car.config.car_name).to_upper()
	return "CORVETTE"


func _seat_car_from_config(car_node: EAGLCar) -> void:
	var target_height := _spawn_height_for_config(car_node.config)
	if is_nan(target_height):
		return
	car_node.position.y = target_height + spawn_height_offset


func _spawn_height_for_config(config) -> float:
	if config == null:
		return 0.0
	if config.wheel_radii.is_empty():
		return 0.0
	var target_origin_y := 0.0
	for index in range(mini(config.wheel_local_positions_ps2.size(), config.wheel_radii.size())):
		var pivot_local_z = config.wheel_local_positions_ps2[index].z
		target_origin_y = maxf(target_origin_y, config.wheel_radii[index] - pivot_local_z)
	return target_origin_y


func _node_bounds(node: Node3D) -> AABB:
	var result := _node_bounds_recursive(node, Transform3D.IDENTITY)
	return result["bounds"] if bool(result["found"]) else AABB()


func _node_global_bounds(node: Node3D) -> AABB:
	var parent_transform := Transform3D.IDENTITY
	var parent_node := node.get_parent()
	if parent_node is Node3D:
		parent_transform = (parent_node as Node3D).global_transform
	var result := _node_bounds_recursive(node, parent_transform)
	return result["bounds"] if bool(result["found"]) else AABB()


func _node_bounds_recursive(node: Node, parent_transform: Transform3D) -> Dictionary:
	var node_transform := parent_transform
	if node is Node3D:
		node_transform = parent_transform * (node as Node3D).transform

	var bounds := AABB()
	var found := false
	if node is MeshInstance3D:
		var mesh_aabb := (node as MeshInstance3D).get_aabb()
		if mesh_aabb.size != Vector3.ZERO:
			bounds = node_transform * mesh_aabb
			found = true
	elif node is MultiMeshInstance3D:
		var multimesh_aabb := (node as MultiMeshInstance3D).get_aabb()
		if multimesh_aabb.size != Vector3.ZERO:
			bounds = node_transform * multimesh_aabb
			found = true

	for child in node.get_children():
		var child_result := _node_bounds_recursive(child, node_transform)
		if not bool(child_result["found"]):
			continue
		if not found:
			bounds = child_result["bounds"]
			found = true
		else:
			bounds = bounds.merge(child_result["bounds"])
	return {
		"found": found,
		"bounds": bounds,
	}
