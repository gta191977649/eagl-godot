extends Node3D

const CarLoaderScript = preload("res://eagl/assets/car/car_loader.gd")
const CarConfigScript = preload("res://eagl/handling/car_config.gd")
const GlobalBHandlingLoaderScript = preload("res://eagl/handling/globalb_handling_loader.gd")
const RoadSurfaceSamplerScript = preload("res://eagl/handling/road_surface_sampler.gd")
const DEFAULT_PLATFORM := "EAGL_HOTPUSUIT2_PS2"

const GROUND_SIZE = 20000.0
const GROUND_HEIGHT = 1.0
const GROUND_OFFSET_Y = -0.5
const CAMERA_DISTANCE = 8.5
const CAMERA_TARGET_HEIGHT = 1.55
const CAMERA_SMOOTHING = 7.0
const CAMERA_LOOK_AHEAD = 2.75
const CAMERA_MOUSE_SENSITIVITY = 0.0035
const CAMERA_MIN_PITCH = deg_to_rad(-18.0)
const CAMERA_MAX_PITCH = deg_to_rad(45.0)
const CAMERA_FILL_LIGHT_ENERGY = 2.2
const CAMERA_FILL_LIGHT_RANGE = 28.0

@export var platform := DEFAULT_PLATFORM
@export_global_dir var game_root = ""
@export_file("*.json") var handling_json_path = ""
@export var initial_car_id := "CORVETTE"

@onready var car = $Car
@onready var camera: Camera3D = $FollowCamera
@onready var telemetry: Label = $HUD/TelemetryPanel/Telemetry
@onready var car_list: ItemList = $HUD/ControlsPanel/MarginContainer/ControlsLayout/CarList
@onready var overlay_toggle: CheckBox = $HUD/ControlsPanel/MarginContainer/ControlsLayout/ControlsRow/OverlayToggle
@onready var reset_button: Button = $HUD/ControlsPanel/MarginContainer/ControlsLayout/ControlsRow/ResetButton
@onready var current_car_label: Label = $HUD/ControlsPanel/MarginContainer/ControlsLayout/CurrentCarLabel
@onready var world_environment: WorldEnvironment = $WorldEnvironment
@onready var sun: DirectionalLight3D = $Sun
@onready var flat_track = $FlatTrack
@onready var flat_track_shape: CollisionShape3D = $FlatTrack/CollisionShape3D
@onready var flat_track_mesh: MeshInstance3D = $FlatTrack/MeshInstance3D

var _sampler = null
var _car_loader = null
var _status_message := ""
var _camera_yaw := 0.0
var _camera_pitch := deg_to_rad(14.0)
var _camera_target_position := Vector3.ZERO
var _spawn_transform := Transform3D.IDENTITY
var _car_entries: Array[Dictionary] = []
var _selected_car_index := -1
var _syncing_ui := false


func _enter_tree() -> void:
	var car_node = get_node_or_null("Car")
	if car_node == null:
		return
	if car_node.config == null:
		car_node.config = _build_runtime_config_for_car(_resolved_initial_car_id())
	var loaded_config = _load_handling_config(car_node)
	if loaded_config != null:
		car_node.config = loaded_config
	if car_node.config != null:
		_seat_car_from_config(car_node)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_camera_yaw -= event.relative.x * CAMERA_MOUSE_SENSITIVITY
		_camera_pitch = clampf(_camera_pitch - event.relative.y * CAMERA_MOUSE_SENSITIVITY, CAMERA_MIN_PITCH, CAMERA_MAX_PITCH)


func _ready() -> void:
	_ensure_input_actions()
	_setup_ground()
	_setup_lighting()
	_sampler = RoadSurfaceSamplerScript.new()
	_sampler.build_from_flat_plane(GROUND_SIZE, GROUND_SIZE, 0.0, 1)
	car.set_surface_sampler(_sampler)
	_bind_ui()
	_seed_camera_from_car()
	_spawn_transform = _spawn_transform_for_config(car.config)
	var resolved_root := _ensure_eagl_ready()
	_car_loader = CarLoaderScript.new(resolved_root)
	_load_car_visual()
	car.reset_runtime_state(_spawn_transform)
	_rebuild_car_entries()
	_sync_ui_from_car()


func _process(delta: float) -> void:
	_update_camera(delta)
	_update_telemetry()


func _update_camera(delta: float) -> void:
	var forward: Vector3 = car.global_transform.basis * Vector3.RIGHT
	var desired_target = car.global_transform.origin + Vector3.UP * CAMERA_TARGET_HEIGHT + forward * CAMERA_LOOK_AHEAD
	var horizontal_radius = cos(_camera_pitch) * CAMERA_DISTANCE
	var orbit_offset = Vector3(
		-cos(_camera_yaw) * horizontal_radius,
		sin(_camera_pitch) * CAMERA_DISTANCE,
		-sin(_camera_yaw) * horizontal_radius
	)
	var desired_position = desired_target + orbit_offset
	var smoothing = clampf(delta * CAMERA_SMOOTHING, 0.0, 1.0)
	_camera_target_position = _camera_target_position.lerp(desired_target, smoothing)
	camera.global_position = camera.global_position.lerp(desired_position, smoothing)
	camera.look_at(_camera_target_position, Vector3.UP)


func _update_telemetry() -> void:
	var snapshot = car.get_debug_snapshot()
	if snapshot.is_empty() and _status_message == "":
		return

	var lines: Array[String] = []
	if _status_message != "":
		lines.append(_status_message)
	lines.append("")
	lines.append("Car:   %s" % _current_car_display_name())
	lines.append("Speed: %5.1f km/h" % float(snapshot.get("speed_kph", 0.0)))
	lines.append("RPM:   %5.0f" % float(snapshot.get("rpm", 0.0)))
	lines.append("Gear:  %d" % int(snapshot.get("gear", 1)))
	lines.append("Slip:  %+5.1f deg" % float(snapshot.get("slip_angle_deg", 0.0)))
	lines.append("Mouse: %s" % ("orbit" if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else "click to capture"))
	lines.append("")
	for wheel in snapshot.get("wheels", []):
		lines.append(
			"%s  cur=%5.3f raw=%5.3f [%5.3f..%5.3f] %s  F=%6.0f" % [
				String(wheel.get("slot", "--")),
				float(wheel.get("compression", 0.0)),
				float(wheel.get("suspension_distance", 0.0)),
				float(wheel.get("min_travel", 0.0)),
				float(wheel.get("max_travel", 0.0)),
				"GRD" if bool(wheel.get("grounded", false)) else "AIR",
				float(wheel.get("force", 0.0)),
			]
		)
	telemetry.text = "\n".join(lines)


func _ensure_input_actions() -> void:
	_ensure_key_action("car_accelerate", [KEY_W, KEY_UP])
	_ensure_key_action("car_brake", [KEY_S, KEY_DOWN])
	_ensure_key_action("car_steer_left", [KEY_A, KEY_LEFT])
	_ensure_key_action("car_steer_right", [KEY_D, KEY_RIGHT])
	_ensure_key_action("car_handbrake", [KEY_SPACE])


func _ensure_key_action(action_name: String, keycodes: Array[int]) -> void:
	if not InputMap.has_action(action_name):
		InputMap.add_action(action_name)
	if not InputMap.action_get_events(action_name).is_empty():
		return
	for keycode in keycodes:
		var event = InputEventKey.new()
		event.physical_keycode = keycode
		InputMap.action_add_event(action_name, event)


func _load_car_visual() -> void:
	if car.config == null or _car_loader == null:
		return
	var existing := car.get_node_or_null("CarVisual")
	if existing != null:
		car.remove_child(existing)
		existing.free()
		car.refresh_visual_bindings()
	var visual = _car_loader.load(car.config.car_name, car.config)
	if visual == null:
		_set_status("Car visual failed: %s" % _car_loader.last_error)
		push_warning("Failed to load car visual for %s: %s" % [car.config.car_name, _car_loader.last_error])
		return
	_set_status("")
	car.add_child(visual)
	car.refresh_visual_bindings()
	_print_vehicle_debug_info(visual)
	_sync_ui_from_car()


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


func _load_handling_config(car_node) -> Resource:
	var json_path := _resolved_handling_json_path()
	if json_path == "" or not FileAccess.file_exists(json_path):
		return null
	var existing = car_node.config
	if existing == null:
		return null
	var loader = GlobalBHandlingLoaderScript.new()
	var loaded = loader.load_config(json_path, existing.car_name, existing.duplicate_index, existing.drive_type)
	if loaded == null:
		push_warning("Failed to load handling JSON config for %s from %s" % [existing.car_name, json_path])
		return null
	print("EAGL handling config override: car=%s duplicate=%d json=%s" % [
		loaded.car_name,
		int(loaded.duplicate_index),
		json_path,
	])
	return loaded


func _seat_car_from_config(car_node) -> void:
	var target_height = _spawn_height_for_config(car_node.config)
	if is_nan(target_height):
		return
	car_node.position.y = target_height


func _spawn_height_for_config(config) -> float:
	if config == null:
		return NAN
	if config.wheel_radii.is_empty():
		return NAN
	var target_origin_z := 0.0
	for index in range(mini(config.wheel_local_positions_ps2.size(), config.wheel_radii.size())):
		var pivot_local_z = config.wheel_local_positions_ps2[index].z
		target_origin_z = maxf(target_origin_z, config.wheel_radii[index] - pivot_local_z)
	return target_origin_z + 0.02


func _spawn_transform_for_config(config) -> Transform3D:
	var spawn_transform: Transform3D = _spawn_transform if _spawn_transform != Transform3D.IDENTITY else car.transform
	var origin: Vector3 = spawn_transform.origin
	var target_height = _spawn_height_for_config(config)
	if not is_nan(target_height):
		origin.y = target_height
	spawn_transform.origin = origin
	return spawn_transform


func _ensure_eagl_ready() -> String:
	var resolved_root := _resolved_game_root()
	if resolved_root == "":
		_set_status("Missing game_root. Initialize EAGLManager first, set CarDebug.game_root, ProjectSettings eagl/game_root, or EAGL_HP2_GAME_ROOT.")
		return ""
	if EAGLManager.is_initialized():
		return resolved_root
	if not EAGLManager.initialize(platform, resolved_root, {}):
		_set_status("EAGL init failed: %s" % EAGLManager.last_error)
		return resolved_root
	return EAGLManager.get_game_root()


func _set_status(message: String) -> void:
	_status_message = message
	if current_car_label == null:
		return
	var label_lines: Array[String] = ["Current: %s" % _current_car_display_name()]
	if message != "":
		label_lines.append(message)
	current_car_label.text = "\n".join(label_lines)


func _bind_ui() -> void:
	if overlay_toggle != null and not overlay_toggle.toggled.is_connected(_on_overlay_toggled):
		overlay_toggle.toggled.connect(_on_overlay_toggled)
	if reset_button != null and not reset_button.pressed.is_connected(_on_reset_pressed):
		reset_button.pressed.connect(_on_reset_pressed)
	if car_list != null and not car_list.item_selected.is_connected(_on_car_selected):
		car_list.item_selected.connect(_on_car_selected)


func _rebuild_car_entries() -> void:
	_car_entries.clear()
	var seen := {}
	_append_car_binary_entries(seen)
	_append_current_config_entry(seen)
	if _car_entries.is_empty() and car.config != null:
		_append_config_entry(car.config, "Fallback", seen)
	_refresh_car_list_ui()


func _append_car_binary_entries(seen: Dictionary) -> void:
	var cars_dir := _resolved_cars_dir()
	if cars_dir == "":
		return
	var dir := DirAccess.open(cars_dir)
	if dir == null:
		return
	var car_ids: Array[String] = []
	dir.list_dir_begin()
	while true:
		var entry_name := dir.get_next()
		if entry_name == "":
			break
		if not dir.current_is_dir():
			continue
		var geometry_bin := cars_dir.path_join(entry_name).path_join("GEOMETRY.BIN")
		var geometry_lzc := cars_dir.path_join(entry_name).path_join("GEOMETRY.LZC")
		if not FileAccess.file_exists(geometry_bin) and not FileAccess.file_exists(geometry_lzc):
			continue
		car_ids.append(entry_name.to_upper())
	dir.list_dir_end()
	car_ids.sort()
	for car_id in car_ids:
		var entry_key := _entry_key(car_id, 1, _default_drive_type())
		if seen.has(entry_key):
			continue
		seen[entry_key] = true
		_car_entries.append({
			"key": entry_key,
			"label": _format_car_entry_label(car_id, 1, "", "Binary"),
			"source": "car_binary",
			"car_name": car_id,
			"duplicate_index": 1,
			"drive_type": _default_drive_type(),
		})


func _append_current_config_entry(seen: Dictionary) -> void:
	if car == null or car.config == null:
		return
	_append_config_entry(car.config, "Current", seen)


func _append_config_entry(config, source_label: String, seen: Dictionary, extra: Dictionary = {}) -> void:
	if config == null:
		return
	var car_name := String(config.car_name)
	var duplicate_index := int(config.duplicate_index)
	var drive_type := String(config.drive_type)
	var entry_key := _entry_key(car_name, duplicate_index, drive_type)
	if seen.has(entry_key):
		return
	seen[entry_key] = true
	var entry := {
		"key": entry_key,
		"label": _format_car_entry_label(car_name, duplicate_index, drive_type, source_label),
		"source": "config",
		"car_name": car_name,
		"duplicate_index": duplicate_index,
		"drive_type": drive_type,
		"config": config,
	}
	for key in extra.keys():
		entry[key] = extra[key]
	_car_entries.append(entry)


func _refresh_car_list_ui() -> void:
	if car_list == null:
		return
	_syncing_ui = true
	car_list.clear()
	for entry in _car_entries:
		car_list.add_item(String(entry.get("label", "Unknown Car")))
	var target_index := _index_for_current_car()
	if target_index >= 0:
		car_list.select(target_index)
		_selected_car_index = target_index
	_syncing_ui = false


func _sync_ui_from_car() -> void:
	if overlay_toggle != null:
		_syncing_ui = true
		overlay_toggle.button_pressed = car.draw_debug
		_syncing_ui = false
	if car_list != null and not _car_entries.is_empty():
		var target_index := _index_for_current_car()
		if target_index >= 0:
			_syncing_ui = true
			car_list.select(target_index)
			_selected_car_index = target_index
			_syncing_ui = false
	_set_status(_status_message)


func _index_for_current_car() -> int:
	if car.config == null:
		return -1
	var target_key := _entry_key(String(car.config.car_name), int(car.config.duplicate_index), String(car.config.drive_type))
	for index in range(_car_entries.size()):
		if String(_car_entries[index].get("key", "")) == target_key:
			return index
	return -1


func _current_car_display_name() -> String:
	if car == null or car.config == null:
		return "None"
	return _format_car_entry_label(String(car.config.car_name), int(car.config.duplicate_index), String(car.config.drive_type), "")


func _default_drive_type() -> String:
	if car != null and car.config != null:
		return String(car.config.drive_type)
	return "RWD"


func _entry_key(car_name: String, duplicate_index: int, drive_type: String) -> String:
	return "%s::%d::%s" % [car_name, duplicate_index, drive_type]


func _format_car_entry_label(car_name: String, duplicate_index: int, drive_type: String, source_label: String) -> String:
	var label := car_name
	if duplicate_index > 1:
		label += " #%d" % duplicate_index
	if drive_type != "":
		label += " [%s]" % drive_type
	if source_label != "":
		label += "  %s" % source_label
	return label


func _load_entry_config(entry: Dictionary):
	var source := String(entry.get("source", "config"))
	match source:
		"car_binary":
			return _build_runtime_config_for_car(
				String(entry.get("car_name", "")),
				int(entry.get("duplicate_index", 1)),
				String(entry.get("drive_type", _default_drive_type()))
			)
		_:
			return entry.get("config", null)


func _switch_to_car_index(index: int) -> void:
	if index < 0 or index >= _car_entries.size():
		return
	var entry: Dictionary = _car_entries[index]
	var new_config = _load_entry_config(entry)
	if new_config == null:
		_set_status("Failed to load %s" % String(entry.get("label", "car")))
		return
	car.apply_config(new_config)
	_spawn_transform = _spawn_transform_for_config(new_config)
	_load_car_visual()
	car.reset_runtime_state(_spawn_transform)
	_seed_camera_from_car()
	_selected_car_index = index
	_set_status("Loaded %s" % String(entry.get("label", "car")))
	_sync_ui_from_car()


func _on_car_selected(index: int) -> void:
	if _syncing_ui or index == _selected_car_index:
		return
	_switch_to_car_index(index)


func _on_reset_pressed() -> void:
	_spawn_transform = _spawn_transform_for_config(car.config)
	car.reset_runtime_state(_spawn_transform)
	_seed_camera_from_car()
	_set_status("Reset %s" % _current_car_display_name())


func _on_overlay_toggled(enabled: bool) -> void:
	if _syncing_ui:
		return
	car.set_debug_overlay_enabled(enabled)
	_set_status("Debug overlay %s" % ("enabled" if enabled else "hidden"))


func _build_runtime_config_for_car(car_name: String, duplicate_index: int = 1, drive_type: String = ""):
	var resolved_drive_type: String = drive_type if drive_type != "" else _default_drive_type()
	var json_path: String = _resolved_handling_json_path()
	if json_path != "" and FileAccess.file_exists(json_path):
		var loader = GlobalBHandlingLoaderScript.new()
		var loaded = loader.load_config(json_path, car_name, duplicate_index, resolved_drive_type)
		if loaded != null:
			return loaded
	var config = CarConfigScript.new()
	if car != null and car.config != null:
		config = car.config.duplicate(true)
	config.car_name = car_name
	config.duplicate_index = duplicate_index
	config.drive_type = resolved_drive_type
	return config


func _resolved_cars_dir() -> String:
	var resolved_root: String = _resolved_game_root()
	if resolved_root == "":
		return ""
	var candidates: Array[String] = [
		resolved_root.path_join("CARS"),
		resolved_root,
	]
	for candidate: String in candidates:
		if not DirAccess.dir_exists_absolute(candidate):
			continue
		if candidate.get_file().to_upper() == "CARS":
			return candidate
		var nested: String = candidate.path_join("CARS")
		if DirAccess.dir_exists_absolute(nested):
			return nested
	return ""


func _resolved_initial_car_id() -> String:
	var desired: String = initial_car_id.strip_edges().to_upper()
	if desired != "":
		var cars_dir: String = _resolved_cars_dir()
		if cars_dir != "" and DirAccess.dir_exists_absolute(cars_dir.path_join(desired)):
			return desired
	if car != null and car.config != null and String(car.config.car_name) != "":
		return String(car.config.car_name).to_upper()
	var cars_dir: String = _resolved_cars_dir()
	if cars_dir == "":
		return "CORVETTE"
	var dir := DirAccess.open(cars_dir)
	if dir == null:
		return "CORVETTE"
	var first_car_id := "CORVETTE"
	dir.list_dir_begin()
	while true:
		var entry_name: String = dir.get_next()
		if entry_name == "":
			break
		if not dir.current_is_dir():
			continue
		var geometry_bin: String = cars_dir.path_join(entry_name).path_join("GEOMETRY.BIN")
		var geometry_lzc: String = cars_dir.path_join(entry_name).path_join("GEOMETRY.LZC")
		if FileAccess.file_exists(geometry_bin) or FileAccess.file_exists(geometry_lzc):
			first_car_id = entry_name.to_upper()
			break
	dir.list_dir_end()
	return first_car_id


func _setup_ground() -> void:
	var shape := flat_track_shape.shape as BoxShape3D
	if shape != null:
		shape.size = Vector3(GROUND_SIZE, GROUND_HEIGHT, GROUND_SIZE)
	flat_track_shape.position = Vector3(0.0, GROUND_OFFSET_Y, 0.0)

	var box_mesh := flat_track_mesh.mesh as BoxMesh
	if box_mesh != null:
		box_mesh.size = Vector3(GROUND_SIZE, GROUND_HEIGHT, GROUND_SIZE)
	flat_track_mesh.position = Vector3(0.0, GROUND_OFFSET_Y, 0.0)
	flat_track_mesh.material_override = _build_grid_material()


func _build_grid_material() -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

uniform vec4 base_color : source_color = vec4(0.055, 0.06, 0.065, 1.0);
uniform vec4 minor_line_color : source_color = vec4(0.18, 0.2, 0.22, 1.0);
uniform vec4 major_line_color : source_color = vec4(0.52, 0.58, 0.62, 1.0);
uniform float minor_spacing = 1.0;
uniform float major_spacing = 10.0;
uniform float minor_width = 0.9;
uniform float major_width = 1.35;
uniform float fade_distance = 550.0;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float grid_line(float spacing, float width) {
	vec2 scaled = world_pos.xz / spacing;
	vec2 cell = abs(fract(scaled - 0.5) - 0.5) / max(fwidth(scaled), vec2(0.0001));
	float line = min(cell.x, cell.y);
	return 1.0 - smoothstep(0.0, width, line);
}

void fragment() {
	float minor = grid_line(minor_spacing, minor_width);
	float major = grid_line(major_spacing, major_width);
	float distance_fade = 1.0 - smoothstep(fade_distance * 0.35, fade_distance, distance(CAMERA_POSITION_WORLD.xz, world_pos.xz));
	vec3 color = base_color.rgb;
	color = mix(color, minor_line_color.rgb, minor * 0.45 * distance_fade);
	color = mix(color, major_line_color.rgb, major * distance_fade);
	ALBEDO = color;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}
"""
	var material := ShaderMaterial.new()
	material.shader = shader
	return material


func _seed_camera_from_car() -> void:
	var forward: Vector3 = (car.global_transform.basis * Vector3.RIGHT).normalized()
	_camera_yaw = atan2(-forward.z, forward.x)
	_camera_target_position = car.global_transform.origin + Vector3.UP * CAMERA_TARGET_HEIGHT


func _setup_lighting() -> void:
	if world_environment != null and world_environment.environment != null:
		world_environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		world_environment.environment.ambient_light_color = Color(0.72, 0.76, 0.82, 1.0)
		world_environment.environment.ambient_light_energy = 2.35
		world_environment.environment.background_mode = Environment.BG_COLOR
		world_environment.environment.background_color = Color(0.08, 0.095, 0.11, 1.0)
	if sun != null:
		sun.light_energy = 3.1
		sun.shadow_enabled = true
	var camera_fill := camera.get_node_or_null("CameraFill") as OmniLight3D
	if camera_fill == null:
		camera_fill = OmniLight3D.new()
		camera_fill.name = "CameraFill"
		camera.add_child(camera_fill)
	camera_fill.position = Vector3.ZERO
	camera_fill.light_color = Color(0.86, 0.9, 1.0, 1.0)
	camera_fill.light_energy = CAMERA_FILL_LIGHT_ENERGY
	camera_fill.omni_range = CAMERA_FILL_LIGHT_RANGE
	camera_fill.shadow_enabled = false


func _print_vehicle_debug_info(visual: Node3D) -> void:
	var assembly_summary: Dictionary = visual.get_meta("eagl_assembly_summary", {})
	var wheel_pivots: PackedStringArray = visual.get_meta("eagl_wheel_pivot_names", PackedStringArray())
	var dummies: PackedStringArray = visual.get_meta("eagl_dummy_names", PackedStringArray())
	var wheel_selection: Dictionary = visual.get_meta("eagl_wheel_visual_selection", {})
	print("EAGL vehicle loaded: car=%s body_variant=%s source=%s body_meshes=%d" % [
		String(visual.get_meta("eagl_car_id", "")),
		String(visual.get_meta("eagl_primary_body_variant", "")),
		String(visual.get_meta("eagl_source_path", "")),
		int(visual.get_meta("eagl_body_mesh_count", 0)),
	])
	print("EAGL vehicle assembly: body_groups=%s wheel_groups=%s brake_groups=%s variant=%s" % [
		assembly_summary.get("body_group_count", "?"),
		assembly_summary.get("wheel_group_count", "?"),
		assembly_summary.get("brake_group_count", "?"),
		assembly_summary.get("variant_name", ""),
	])
	print("EAGL vehicle wheel pivots: %s" % ", ".join(PackedStringArray(wheel_pivots)))
	print("EAGL vehicle dummies: %s" % ", ".join(PackedStringArray(dummies)))
	if not wheel_selection.is_empty():
		var wheel_lines: Array[String] = []
		for slot_id in ["FL", "FR", "RL", "RR"]:
			var entry: Dictionary = wheel_selection.get(slot_id, {})
			if entry.is_empty():
				continue
			wheel_lines.append("%s=%s(%s)" % [
				slot_id,
				String(entry.get("object_name", "")),
				String(entry.get("detail_suffix", "")),
			])
		print("EAGL vehicle wheel visuals: %s" % ", ".join(wheel_lines))
