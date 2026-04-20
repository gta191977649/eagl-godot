extends Node3D

@export var platform := "EAGL_HOTPUSUIT2_PS2"
@export_global_dir var game_root := "/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA"
@export var default_car := "MCLAREN"

var _car_root: Node3D
var _controller
var _car_selector: OptionButton
var _status_label: Label
var _stats_label: Label
var _camera_label: Label
var _debug_camera: Camera3D
var _all_variants_toggle: CheckButton
var _assembly_debug_toggle: CheckButton
var _dummy_label_mode_button: OptionButton
var _assembly_debug_lines: MeshInstance3D
var _assembly_debug_labels: Node3D
var _assembly_debug_label_nodes: Array[Label3D] = []
var _assembly_debug_material: StandardMaterial3D
var _ground_visuals: Node3D
var _group_toggles: Dictionary = {}
var _camera_yaw_offset := 0.0
var _camera_pitch := deg_to_rad(18.0)
var _manual_orbit_timer := 0.0
var _dummy_label_mode := 1

const PART_GROUPS := ["Body", "Wheels", "Brakes", "GlassLightsDamage", "ShadowBlur", "Dashboard"]
const CAMERA_MOUSE_SENSITIVITY := 0.006
const CAMERA_MIN_PITCH := -0.18
const CAMERA_MAX_PITCH := 0.72
const CAMERA_RECENTER_DELAY := 1.2
const DEBUG_SLOT_SIZE := 0.18
const DEBUG_PIVOT_SIZE := 0.13
const DEBUG_MESH_CENTER_SIZE := 0.09
const DEBUG_AXIS_SIZE := 0.24
const DEBUG_DUMMY_SIZE := 0.075
const DEBUG_DUMMY_LABEL_OFFSET := Vector3(0.05, 0.12, 0.0)
const DEBUG_DUMMY_LABEL_OFF := 0
const DEBUG_DUMMY_LABEL_WHEEL := 1
const DEBUG_DUMMY_LABEL_KNOWN := 2
const DEBUG_DUMMY_LABEL_ALL := 3
const INFINITE_GROUND_PATCH_SIZE := 320.0
const INFINITE_GROUND_RECENTER_STEP := 20.0
const INFINITE_GROUND_GRID_HALF_LINES := 80
const INFINITE_GROUND_GRID_STEP := 2.0


func _ready() -> void:
	_ensure_world()
	_ensure_ui()
	_initialize_eagl()
	_populate_car_selector()
	_load_selected_or_default()


func _process(delta: float) -> void:
	_update_infinite_ground()
	_update_follow_camera(delta)
	_update_assembly_debug_lines()
	_update_debug_labels()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R:
			_reset_car()
		elif event.keycode == KEY_F:
			_frame_car()
		elif event.keycode == KEY_P:
			if _assembly_debug_toggle != null:
				_assembly_debug_toggle.button_pressed = not _assembly_debug_toggle.button_pressed
			_update_assembly_debug_lines()
		elif event.keycode == KEY_L:
			_cycle_dummy_label_mode()
	elif event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if motion.relative.length_squared() > 0.0:
			_camera_yaw_offset -= motion.relative.x * CAMERA_MOUSE_SENSITIVITY
			_camera_pitch = clampf(_camera_pitch - motion.relative.y * CAMERA_MOUSE_SENSITIVITY, CAMERA_MIN_PITCH, CAMERA_MAX_PITCH)
			_manual_orbit_timer = CAMERA_RECENTER_DELAY


func _initialize_eagl() -> void:
	var ok: bool = EAGLManager.initialize(platform, game_root, {
		"texture_filter_mode": "nearest_mipmap",
		"generate_lods": false,
		"show_all_car_variants": _all_variants_toggle != null and _all_variants_toggle.button_pressed,
	})
	if not ok:
		_set_status("Failed: %s" % EAGLManager.last_error)


func _populate_car_selector() -> void:
	if _car_selector == null:
		return
	_car_selector.clear()
	var cars_dir := _cars_dir()
	var names: Array[String] = []
	var dir := DirAccess.open(cars_dir)
	if dir != null:
		dir.list_dir_begin()
		while true:
			var entry := dir.get_next()
			if entry == "":
				break
			if dir.current_is_dir() and not entry.begins_with(".") and FileAccess.file_exists(cars_dir.path_join(entry).path_join("GEOMETRY.BIN")):
				names.append(entry.to_upper())
		dir.list_dir_end()
	names.sort()
	for name in names:
		_car_selector.add_item(name)
	var default_index := names.find(default_car.to_upper())
	if default_index >= 0:
		_car_selector.select(default_index)


func _load_selected_or_default() -> void:
	var car_id := default_car
	if _car_selector != null and _car_selector.item_count > 0:
		car_id = _car_selector.get_item_text(_car_selector.selected)
	_load_car(car_id)


func _load_car(car_id: String) -> void:
	if _car_root != null and is_instance_valid(_car_root):
		_car_root.queue_free()
		_car_root = null
		_controller = null
	_set_status("Loading %s..." % car_id)
	await get_tree().process_frame
	var node := EAGLManager.load_car(car_id)
	if node == null:
		_set_status("Failed to load %s" % car_id)
		return
	_car_root = node
	_car_root.position = Vector3(0.0, _car_suspension_height(node), 0.0)
	add_child(_car_root)
	_controller = _car_root.get_node_or_null("EAGLCarController3D")
	_apply_debug_toggles()
	_update_infinite_ground()
	_frame_car()
	_set_status("Loaded %s" % car_id)


func _reset_car() -> void:
	if _car_root == null:
		return
	_car_root.global_transform = Transform3D(Basis.IDENTITY, Vector3(0.0, _car_suspension_height(_car_root), 0.0))
	if _controller != null and _controller.has_method("reset_motion"):
		_controller.reset_motion()


func _ensure_world() -> void:
	_ensure_debug_environment()
	_ensure_debug_lights()
	if get_node_or_null("DebugCamera") == null:
		var camera := Camera3D.new()
		camera.name = "DebugCamera"
		camera.current = true
		camera.position = Vector3(0.0, 5.0, 12.0)
		camera.rotation_degrees = Vector3(-20.0, 0.0, 0.0)
		add_child(camera)
		_debug_camera = camera
	else:
		_debug_camera = get_node_or_null("DebugCamera") as Camera3D
	if get_node_or_null("AssemblyDebugLines") == null:
		_assembly_debug_lines = MeshInstance3D.new()
		_assembly_debug_lines.name = "AssemblyDebugLines"
		_assembly_debug_lines.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_assembly_debug_lines.set_as_top_level(true)
		_assembly_debug_material = StandardMaterial3D.new()
		_assembly_debug_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_assembly_debug_material.vertex_color_use_as_albedo = true
		_assembly_debug_material.no_depth_test = true
		_assembly_debug_lines.material_override = _assembly_debug_material
		add_child(_assembly_debug_lines)
	else:
		_assembly_debug_lines = get_node_or_null("AssemblyDebugLines") as MeshInstance3D
	if get_node_or_null("AssemblyDebugLabels") == null:
		_assembly_debug_labels = Node3D.new()
		_assembly_debug_labels.name = "AssemblyDebugLabels"
		_assembly_debug_labels.set_as_top_level(true)
		add_child(_assembly_debug_labels)
	else:
		_assembly_debug_labels = get_node_or_null("AssemblyDebugLabels") as Node3D
	if get_node_or_null("Ground") == null:
		var body := StaticBody3D.new()
		body.name = "Ground"
		var collision := CollisionShape3D.new()
		var shape := WorldBoundaryShape3D.new()
		shape.plane = Plane(Vector3.UP, 0.0)
		collision.shape = shape
		body.add_child(collision)
		_ground_visuals = Node3D.new()
		_ground_visuals.name = "GroundVisuals"
		body.add_child(_ground_visuals)
		var mesh := MeshInstance3D.new()
		mesh.name = "GroundPatch"
		var plane := PlaneMesh.new()
		plane.size = Vector2(INFINITE_GROUND_PATCH_SIZE, INFINITE_GROUND_PATCH_SIZE)
		mesh.mesh = plane
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var material := StandardMaterial3D.new()
		material.albedo_color = Color(0.18, 0.2, 0.18)
		material.roughness = 1.0
		mesh.set_surface_override_material(0, material)
		_ground_visuals.add_child(mesh)
		_ground_visuals.add_child(_make_grid_mesh())
		add_child(body)
	else:
		var ground := get_node_or_null("Ground") as Node3D
		if ground != null:
			_ground_visuals = ground.get_node_or_null("GroundVisuals") as Node3D


func _ensure_debug_environment() -> void:
	var world_environment := get_node_or_null("WorldEnvironment") as WorldEnvironment
	if world_environment == null:
		world_environment = WorldEnvironment.new()
		world_environment.name = "WorldEnvironment"
		add_child(world_environment)
	if world_environment.environment == null:
		world_environment.environment = Environment.new()
	var environment := world_environment.environment
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.56, 0.60, 0.58, 1.0)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.64, 0.68, 0.66, 1.0)
	environment.ambient_light_energy = 0.75
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_BG
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.adjustment_enabled = true
	environment.adjustment_brightness = 1.04
	environment.adjustment_contrast = 1.05
	environment.adjustment_saturation = 1.02
	world_environment.set_meta("eagl_debug_environment", true)


func _ensure_debug_lights() -> void:
	var sun := get_node_or_null("Sun") as DirectionalLight3D
	if sun == null:
		sun = DirectionalLight3D.new()
		sun.name = "Sun"
		add_child(sun)
	sun.light_color = Color(1.0, 0.96, 0.84, 1.0)
	sun.light_energy = 8.0
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	sun.rotation_degrees = Vector3(-35.0, 35.0, 0.0)
	sun.set_meta("eagl_debug_sun", true)

	var fill := get_node_or_null("FillLight") as OmniLight3D
	if fill == null:
		fill = OmniLight3D.new()
		fill.name = "FillLight"
		add_child(fill)
	fill.position = Vector3(-3.0, 4.0, 5.0)
	fill.light_color = Color(0.62, 0.74, 0.82, 1.0)
	fill.light_energy = 0.85
	fill.omni_range = 16.0
	fill.shadow_enabled = false
	fill.set_meta("eagl_debug_fill_light", true)


func _ensure_ui() -> void:
	if get_node_or_null("DebugUI") != null:
		return
	var layer := CanvasLayer.new()
	layer.name = "DebugUI"
	add_child(layer)
	var margin := MarginContainer.new()
	margin.name = "SafeMargin"
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	layer.add_child(margin)
	var rows := VBoxContainer.new()
	rows.name = "Rows"
	rows.add_theme_constant_override("separation", 8)
	margin.add_child(rows)
	var controls_panel := PanelContainer.new()
	controls_panel.name = "ControlsPanel"
	rows.add_child(controls_panel)
	var top := HFlowContainer.new()
	top.name = "TopControls"
	top.add_theme_constant_override("h_separation", 8)
	top.add_theme_constant_override("v_separation", 6)
	controls_panel.add_child(top)
	var car_label := Label.new()
	car_label.text = "Car"
	top.add_child(car_label)
	_car_selector = OptionButton.new()
	_car_selector.custom_minimum_size = Vector2(180, 0)
	_car_selector.item_selected.connect(func(_index: int) -> void: _load_selected_or_default())
	top.add_child(_car_selector)
	var reload := Button.new()
	reload.text = "Reload"
	reload.pressed.connect(_load_selected_or_default)
	top.add_child(reload)
	var reset := Button.new()
	reset.text = "Reset"
	reset.pressed.connect(_reset_car)
	top.add_child(reset)
	var frame := Button.new()
	frame.text = "Frame"
	frame.pressed.connect(_frame_car)
	top.add_child(frame)
	_all_variants_toggle = CheckButton.new()
	_all_variants_toggle.text = "All variants"
	_all_variants_toggle.button_pressed = false
	_all_variants_toggle.toggled.connect(func(_pressed: bool) -> void:
		_initialize_eagl()
		_load_selected_or_default()
	)
	top.add_child(_all_variants_toggle)
	_assembly_debug_toggle = CheckButton.new()
	_assembly_debug_toggle.text = "Pivots"
	_assembly_debug_toggle.button_pressed = true
	_assembly_debug_toggle.toggled.connect(func(_pressed: bool) -> void: _update_assembly_debug_lines())
	top.add_child(_assembly_debug_toggle)
	var labels_label := Label.new()
	labels_label.text = "Labels"
	top.add_child(labels_label)
	_dummy_label_mode_button = OptionButton.new()
	_dummy_label_mode_button.add_item("Off", DEBUG_DUMMY_LABEL_OFF)
	_dummy_label_mode_button.add_item("Wheel", DEBUG_DUMMY_LABEL_WHEEL)
	_dummy_label_mode_button.add_item("Known", DEBUG_DUMMY_LABEL_KNOWN)
	_dummy_label_mode_button.add_item("All", DEBUG_DUMMY_LABEL_ALL)
	_dummy_label_mode_button.selected = DEBUG_DUMMY_LABEL_WHEEL
	_dummy_label_mode_button.item_selected.connect(func(index: int) -> void:
		_set_dummy_label_mode(_dummy_label_mode_button.get_item_id(index))
	)
	top.add_child(_dummy_label_mode_button)
	_status_label = Label.new()
	_status_label.text = "Idle"
	top.add_child(_status_label)
	var group_panel := PanelContainer.new()
	group_panel.name = "PartGroupsPanel"
	rows.add_child(group_panel)
	var groups := HFlowContainer.new()
	groups.name = "PartGroups"
	groups.add_theme_constant_override("h_separation", 8)
	groups.add_theme_constant_override("v_separation", 4)
	group_panel.add_child(groups)
	var groups_label := Label.new()
	groups_label.text = "Parts"
	groups.add_child(groups_label)
	for group_name in PART_GROUPS:
		var toggle := CheckButton.new()
		toggle.text = group_name
		toggle.button_pressed = true
		toggle.toggled.connect(func(_pressed: bool) -> void: _apply_debug_toggles())
		groups.add_child(toggle)
		_group_toggles[group_name] = toggle
	var stats_panel := PanelContainer.new()
	stats_panel.name = "StatsPanel"
	rows.add_child(stats_panel)
	_stats_label = Label.new()
	_stats_label.name = "Stats"
	_stats_label.text = "Stats"
	_stats_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	_stats_label.add_theme_constant_override("shadow_offset_x", 1)
	_stats_label.add_theme_constant_override("shadow_offset_y", 1)
	stats_panel.add_child(_stats_label)
	_camera_label = Label.new()
	_camera_label.name = "FollowCameraLabel"
	_camera_label.text = "Follow camera: move mouse to orbit"
	rows.add_child(_camera_label)


func _update_debug_labels() -> void:
	if _stats_label == null:
		return
	if _car_root == null:
		_stats_label.text = "No car loaded"
		return
	var state := {}
	if _controller != null and _controller.has_method("debug_state"):
		state = _controller.debug_state()
	var warnings: Array = EAGLManager.get_stats().get("car", {}).get("warnings", [])
	var bounds: AABB = _car_root.get_meta("eagl_bounds", AABB())
	var offset: Vector3 = _car_root.get_meta("eagl_visual_offset", Vector3.ZERO)
	var control_hint := "W/S throttle/brake, A/D steer, Space handbrake, mouse orbit, P pivots, L labels, R reset, F frame camera"
	_stats_label.text = "Car: %s\nSpeed: %.1f km/h  Mode: %s  Grounded: %s  Slip: %.2f\nEngine: gear %s/%s  %.0f rpm  clutch %.2f  %s  ratio %.2f x %.2f  shift %.0f rpm %.0f/%.0f kmh\nInput: throttle %.2f -> %.2f  reverse %.2f  brake %.2f  torque %.0f engine / %.0f wheel  engine brake %.0f\nLocal: %.2f forward / %.2f side  Yaw: %.3f  Steer: %.2f (%.2f rad)\nForces: drive %.0f  brake %.0f  lateral %.0f  drag %.0f  normal %.0f  suspension %.0f\nObjects: %s rendered / %s parsed / %s hidden  Wheels: %s  Brakes: %s  Pivots: %s spin / %s steer\nTextures: %s bank / %s textured surfaces / %s fallback / %s missing hashes  Locators: %s\nBounds: %.2f x %.2f x %.2f  Visual offset: %.2f, %.2f, %.2f\nGeometry: %s  Tuning: %s (%s)  Exact: %s\nWarnings: %s\nDebug pivots: %s  Dummy labels: %s  Legend: slot yellow, steer cyan, spin magenta, mesh white, brake orange, dummies violet\nControls: %s" % [
		_car_root.get_meta("eagl_car_id", ""),
		float(state.get("speed_kmh", 0.0)),
		state.get("movement_mode", "coast"),
		str(state.get("grounded", false)),
		float(state.get("slip", 0.0)),
		state.get("gear_label", "1"),
		state.get("gear_count", 5),
		float(state.get("engine_rpm", 0.0)),
		float(state.get("clutch_engagement", 1.0)),
		state.get("drivetrain_mode", "coast"),
		float(state.get("gear_ratio", 0.0)),
		float(state.get("final_drive_ratio", 0.0)),
		float(state.get("shift_up_rpm", 0.0)),
		float(state.get("shift_down_speed", 0.0)) * 3.6,
		float(state.get("shift_up_speed", 0.0)) * 3.6,
		float(state.get("throttle", 0.0)),
		float(state.get("filtered_throttle", 0.0)),
		float(state.get("filtered_reverse_throttle", 0.0)),
		float(state.get("brake", 0.0)),
		float(state.get("engine_torque", 0.0)),
		float(state.get("wheel_torque", 0.0)),
		float(state.get("engine_brake_force", 0.0)),
		float(state.get("longitudinal_speed", 0.0)),
		float(state.get("lateral_speed", 0.0)),
		float(state.get("yaw_rate", 0.0)),
		float(state.get("steer", 0.0)),
		float(state.get("steering_angle", 0.0)),
		float(state.get("drive_force", 0.0)),
		float(state.get("brake_force", 0.0)),
		float(state.get("lateral_force", 0.0)),
		float(state.get("drag_force", 0.0)),
		float(state.get("normal_force", 0.0)),
		float(state.get("suspension_force", 0.0)),
		_car_root.get_meta("eagl_rendered_object_count", 0),
		_car_root.get_meta("eagl_object_count", 0),
		_car_root.get_meta("eagl_hidden_variant_count", 0),
		_car_root.get_meta("eagl_wheel_instance_count", 0),
		_car_root.get_meta("eagl_brake_instance_count", 0),
		state.get("spin_pivot_count", 0),
		state.get("steer_pivot_count", 0),
		_car_root.get_meta("eagl_texture_count", 0),
		_car_root.get_meta("eagl_textured_surface_count", 0),
		_car_root.get_meta("eagl_fallback_surface_count", 0),
		_car_root.get_meta("eagl_missing_texture_hashes", []).size(),
		_car_root.get_meta("eagl_locator_count", 0),
		bounds.size.x,
		bounds.size.y,
		bounds.size.z,
		offset.x,
		offset.y,
		offset.z,
		"all variants" if bool(_car_root.get_meta("eagl_show_all_car_variants", false)) else "primary variants",
		state.get("tuning_source", "unknown"),
		state.get("tuning_status", "unknown"),
		state.get("exact_handling_status", _car_root.get_meta("eagl_exact_handling_status", "unknown")),
		warnings.size(),
		"on" if _assembly_debug_enabled() else "off",
		_dummy_label_mode_name(_dummy_label_mode),
		control_hint,
	]


func _set_status(message: String) -> void:
	if _status_label != null:
		_status_label.text = message
	print("EAGL car debug: ", message)


func _cars_dir() -> String:
	var root := game_root.trim_suffix("/")
	if DirAccess.dir_exists_absolute(root.path_join("CARS")):
		return root.path_join("CARS")
	if DirAccess.dir_exists_absolute(root.path_join("ZZDATA").path_join("CARS")):
		return root.path_join("ZZDATA").path_join("CARS")
	return root


func _apply_debug_toggles() -> void:
	if _controller != null:
		_controller.enabled = true
		_controller.debug_free_drive = false
	if _car_root == null:
		return
	var visual := _car_root.get_node_or_null("Visual")
	if visual == null:
		return
	for group_name in PART_GROUPS:
		var group := visual.get_node_or_null(group_name)
		var toggle: CheckButton = _group_toggles.get(group_name)
		if group != null and toggle != null:
			group.visible = toggle.button_pressed
	_update_assembly_debug_lines()


func _assembly_debug_enabled() -> bool:
	return _assembly_debug_toggle == null or _assembly_debug_toggle.button_pressed


func _set_dummy_label_mode(mode: int) -> void:
	_dummy_label_mode = clampi(mode, DEBUG_DUMMY_LABEL_OFF, DEBUG_DUMMY_LABEL_ALL)
	if _dummy_label_mode_button != null:
		for index in range(_dummy_label_mode_button.item_count):
			if _dummy_label_mode_button.get_item_id(index) == _dummy_label_mode:
				_dummy_label_mode_button.select(index)
				break
	_update_assembly_debug_lines()


func _cycle_dummy_label_mode() -> void:
	var next_mode := _dummy_label_mode + 1
	if next_mode > DEBUG_DUMMY_LABEL_ALL:
		next_mode = DEBUG_DUMMY_LABEL_OFF
	_set_dummy_label_mode(next_mode)


func _dummy_label_mode_name(mode: int) -> String:
	match mode:
		DEBUG_DUMMY_LABEL_OFF:
			return "off"
		DEBUG_DUMMY_LABEL_WHEEL:
			return "wheel"
		DEBUG_DUMMY_LABEL_KNOWN:
			return "known"
		DEBUG_DUMMY_LABEL_ALL:
			return "all"
	return "unknown"


func _update_assembly_debug_lines() -> void:
	if _assembly_debug_lines == null:
		return
	if _car_root == null or not _assembly_debug_enabled():
		_assembly_debug_lines.mesh = null
		_clear_assembly_debug_labels()
		return
	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	var visual := _car_root.get_node_or_null("Visual")
	if visual != null:
		for slot in visual.find_children("WheelSlot_*", "Node3D", true, false):
			_append_wheel_debug(vertices, colors, slot as Node3D)
		for slot in visual.find_children("BrakeSlot_*", "Node3D", true, false):
			_append_brake_debug(vertices, colors, slot as Node3D)
		_append_locator_debug(vertices, colors, visual as Node3D)
	_update_assembly_debug_labels(visual as Node3D)
	if vertices.is_empty():
		_assembly_debug_lines.mesh = null
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_COLOR] = colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	_assembly_debug_lines.mesh = mesh


func _append_locator_debug(vertices: PackedVector3Array, colors: PackedColorArray, visual: Node3D) -> void:
	if visual == null or _car_root == null:
		return
	var locators: Array = _car_root.get_meta("eagl_locators", [])
	var dummy_color := Color(0.72, 0.2, 1.0, 1.0)
	for locator in locators:
		var dict: Dictionary = locator
		var local_position: Vector3 = dict.get("position_godot", _locator_ps2_to_godot(dict.get("position_ps2", Vector3.ZERO)))
		var global_position := visual.global_transform * local_position
		_append_cross(vertices, colors, global_position, DEBUG_DUMMY_SIZE, dummy_color)


func _update_assembly_debug_labels(visual: Node3D) -> void:
	if visual == null or _assembly_debug_labels == null or _car_root == null:
		_clear_assembly_debug_labels()
		return
	var locators: Array = _car_root.get_meta("eagl_locators", [])
	var visible_locators: Array = []
	for locator in locators:
		var locator_dict: Dictionary = locator
		if _locator_should_show_label(locator_dict):
			visible_locators.append(locator_dict)
	_resize_assembly_debug_labels(visible_locators.size())
	for index in range(visible_locators.size()):
		var dict: Dictionary = visible_locators[index]
		var local_position: Vector3 = dict.get("position_godot", _locator_ps2_to_godot(dict.get("position_ps2", Vector3.ZERO)))
		var global_position := visual.global_transform * local_position
		var label: Label3D = _assembly_debug_label_nodes[index]
		label.name = _safe_label_node_name("Dummy_%02d" % int(dict.get("index", 0)))
		label.text = _locator_label_text(dict)
		label.position = global_position + DEBUG_DUMMY_LABEL_OFFSET


func _clear_assembly_debug_labels() -> void:
	if _assembly_debug_labels == null:
		return
	for child in _assembly_debug_label_nodes:
		child.free()
	_assembly_debug_label_nodes.clear()


func _resize_assembly_debug_labels(target_count: int) -> void:
	while _assembly_debug_label_nodes.size() > target_count:
		var label: Label3D = _assembly_debug_label_nodes.pop_back()
		label.free()
	while _assembly_debug_label_nodes.size() < target_count:
		var label := Label3D.new()
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.fixed_size = true
		label.pixel_size = 0.0018
		label.modulate = Color(0.95, 0.8, 1.0, 1.0)
		label.outline_modulate = Color(0.0, 0.0, 0.0, 0.95)
		label.outline_size = 5
		_assembly_debug_labels.add_child(label)
		_assembly_debug_label_nodes.append(label)


func _locator_should_show_label(locator: Dictionary) -> bool:
	match _dummy_label_mode:
		DEBUG_DUMMY_LABEL_OFF:
			return false
		DEBUG_DUMMY_LABEL_WHEEL:
			return String(locator.get("display_name", locator.get("name", ""))).begins_with("TIRE_")
		DEBUG_DUMMY_LABEL_KNOWN:
			return String(locator.get("known_name", "")) != ""
		DEBUG_DUMMY_LABEL_ALL:
			return true
	return false


func _locator_label_text(locator: Dictionary) -> String:
	var display_name := String(locator.get("display_name", locator.get("name", "")))
	if display_name == "":
		display_name = "HASH_%08X" % int(locator.get("hash_08", 0))
	if _dummy_label_mode != DEBUG_DUMMY_LABEL_ALL:
		return "%02d %s" % [
			int(locator.get("index", -1)),
			display_name,
		]
	var p: Vector3 = locator.get("position_ps2", Vector3.ZERO)
	return "%02d %s\n%.2f %.2f %.2f" % [
		int(locator.get("index", -1)),
		display_name,
		p.x,
		p.y,
		p.z,
	]


func _locator_ps2_to_godot(position_ps2: Vector3) -> Vector3:
	return Vector3(position_ps2.y, position_ps2.z, -position_ps2.x)


func _safe_label_node_name(value: String) -> String:
	var out := value
	for ch in [" ", "/", "\\", ":", ".", "-"]:
		out = out.replace(ch, "_")
	return out


func _append_wheel_debug(vertices: PackedVector3Array, colors: PackedColorArray, slot: Node3D) -> void:
	if slot == null:
		return
	var slot_color := Color(1.0, 0.88, 0.08, 1.0)
	var steer_color := Color(0.1, 0.95, 1.0, 1.0)
	var spin_color := Color(1.0, 0.15, 0.95, 1.0)
	var mesh_color := Color(1.0, 1.0, 1.0, 1.0)
	var link_color := Color(0.35, 1.0, 0.35, 1.0)
	_append_cross(vertices, colors, slot.global_position, DEBUG_SLOT_SIZE, slot_color)
	_append_basis_axes(vertices, colors, slot.global_transform, DEBUG_AXIS_SIZE)
	var steer := slot.get_node_or_null("SteerPivot") as Node3D
	if steer == null:
		return
	_append_line(vertices, colors, slot.global_position, steer.global_position, link_color)
	_append_cross(vertices, colors, steer.global_position, DEBUG_PIVOT_SIZE, steer_color)
	_append_basis_axes(vertices, colors, steer.global_transform, DEBUG_AXIS_SIZE * 0.8)
	var spin := steer.get_node_or_null("SpinPivot") as Node3D
	if spin == null:
		return
	_append_line(vertices, colors, steer.global_position, spin.global_position, link_color)
	_append_cross(vertices, colors, spin.global_position, DEBUG_PIVOT_SIZE, spin_color)
	_append_basis_axes(vertices, colors, spin.global_transform, DEBUG_AXIS_SIZE * 0.75)
	var mesh := spin.get_node_or_null("Mesh") as MeshInstance3D
	if mesh != null:
		var mesh_center := mesh.global_transform * (mesh.get_aabb().position + mesh.get_aabb().size * 0.5)
		_append_line(vertices, colors, spin.global_position, mesh_center, mesh_color)
		_append_cross(vertices, colors, mesh_center, DEBUG_MESH_CENTER_SIZE, mesh_color)


func _append_brake_debug(vertices: PackedVector3Array, colors: PackedColorArray, slot: Node3D) -> void:
	if slot == null:
		return
	var slot_color := Color(1.0, 0.45, 0.05, 1.0)
	var steer_color := Color(0.1, 0.95, 1.0, 1.0)
	var mesh_color := Color(1.0, 1.0, 1.0, 1.0)
	var link_color := Color(1.0, 0.52, 0.12, 1.0)
	_append_cross(vertices, colors, slot.global_position, DEBUG_SLOT_SIZE * 0.8, slot_color)
	_append_basis_axes(vertices, colors, slot.global_transform, DEBUG_AXIS_SIZE * 0.7)
	var steer := slot.get_node_or_null("SteerPivot") as Node3D
	if steer == null:
		return
	_append_line(vertices, colors, slot.global_position, steer.global_position, link_color)
	_append_cross(vertices, colors, steer.global_position, DEBUG_PIVOT_SIZE * 0.8, steer_color)
	var mesh := steer.get_node_or_null("Mesh") as MeshInstance3D
	if mesh != null:
		var mesh_center := mesh.global_transform * (mesh.get_aabb().position + mesh.get_aabb().size * 0.5)
		_append_line(vertices, colors, steer.global_position, mesh_center, mesh_color)
		_append_cross(vertices, colors, mesh_center, DEBUG_MESH_CENTER_SIZE * 0.8, mesh_color)


func _append_basis_axes(vertices: PackedVector3Array, colors: PackedColorArray, transform: Transform3D, size: float) -> void:
	var origin := transform.origin
	var basis := transform.basis.orthonormalized()
	_append_line(vertices, colors, origin, origin + basis.x * size, Color(1.0, 0.1, 0.08, 1.0))
	_append_line(vertices, colors, origin, origin + basis.y * size, Color(0.1, 0.95, 0.1, 1.0))
	_append_line(vertices, colors, origin, origin + basis.z * size, Color(0.1, 0.35, 1.0, 1.0))


func _append_cross(vertices: PackedVector3Array, colors: PackedColorArray, center: Vector3, size: float, color: Color) -> void:
	_append_line(vertices, colors, center - Vector3.RIGHT * size, center + Vector3.RIGHT * size, color)
	_append_line(vertices, colors, center - Vector3.UP * size, center + Vector3.UP * size, color)
	_append_line(vertices, colors, center - Vector3.FORWARD * size, center + Vector3.FORWARD * size, color)


func _append_line(vertices: PackedVector3Array, colors: PackedColorArray, from: Vector3, to: Vector3, color: Color) -> void:
	vertices.append(from)
	vertices.append(to)
	colors.append(color)
	colors.append(color)


func _frame_car() -> void:
	if _car_root == null or _debug_camera == null:
		return
	_camera_yaw_offset = 0.0
	_camera_pitch = deg_to_rad(18.0)
	var bounds: AABB = _car_root.get_meta("eagl_bounds", AABB(Vector3(-2.0, -0.75, -4.0), Vector3(4.0, 2.0, 8.0)))
	var focus := _car_root.global_position + bounds.position + bounds.size * 0.5
	var radius := maxf(maxf(bounds.size.x, bounds.size.y), bounds.size.z) * 0.65
	var distance := maxf(8.0, radius * 2.4)
	_debug_camera.global_position = focus + Vector3(distance * 0.55, maxf(3.0, radius * 0.55), distance)
	_debug_camera.look_at(focus, Vector3.UP)


func _update_follow_camera(delta: float) -> void:
	if _car_root == null or _debug_camera == null:
		return
	var basis := _car_root.global_transform.basis.orthonormalized()
	var target := _car_root.global_position + Vector3.UP * 1.35
	var car_back := basis.z.normalized()
	var car_yaw := atan2(car_back.x, car_back.z)
	var speed_kmh := 0.0
	if _controller != null and _controller.has_method("debug_state"):
		speed_kmh = float(_controller.debug_state().get("speed_kmh", 0.0))
	if _manual_orbit_timer > 0.0:
		_manual_orbit_timer = maxf(0.0, _manual_orbit_timer - delta)
	elif speed_kmh > 8.0:
		_camera_yaw_offset = lerpf(_camera_yaw_offset, 0.0, clampf(delta * 1.6, 0.0, 1.0))
	var bounds: AABB = _car_root.get_meta("eagl_bounds", AABB(Vector3(-2.0, -0.75, -4.0), Vector3(4.0, 2.0, 8.0)))
	var radius := maxf(maxf(bounds.size.x, bounds.size.y), bounds.size.z) * 0.65
	var distance := maxf(7.5, radius * 2.2)
	var yaw := car_yaw + _camera_yaw_offset
	var horizontal := cos(_camera_pitch) * distance
	var desired := target + Vector3(sin(yaw) * horizontal, sin(_camera_pitch) * distance + 1.2, cos(yaw) * horizontal)
	_debug_camera.global_position = _debug_camera.global_position.lerp(desired, clampf(delta * 6.0, 0.0, 1.0))
	_debug_camera.look_at(target, Vector3.UP)
	if _camera_label != null:
		_camera_label.text = "Follow camera: mouse orbit  yaw %.1f  pitch %.1f" % [rad_to_deg(_camera_yaw_offset), rad_to_deg(_camera_pitch)]


func _car_suspension_height(car: Node) -> float:
	var tuning: Dictionary = car.get_meta("eagl_physics_tuning", {})
	return float(tuning.get("suspension_height", 0.75))


func _update_infinite_ground() -> void:
	if _ground_visuals == null:
		return
	var center := Vector3.ZERO
	if _car_root != null:
		var step := INFINITE_GROUND_RECENTER_STEP
		center.x = roundf(_car_root.global_position.x / step) * step
		center.z = roundf(_car_root.global_position.z / step) * step
	_ground_visuals.global_position = center


func _make_grid_mesh() -> MeshInstance3D:
	var grid := MeshInstance3D.new()
	grid.name = "DebugGrid"
	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	var half := INFINITE_GROUND_GRID_HALF_LINES
	var extent := float(half) * INFINITE_GROUND_GRID_STEP
	for i in range(-half, half + 1):
		var color := Color(0.32, 0.36, 0.34, 1.0) if i % 5 == 0 else Color(0.24, 0.27, 0.25, 1.0)
		var offset := float(i) * INFINITE_GROUND_GRID_STEP
		vertices.append(Vector3(offset, 0.012, -extent))
		vertices.append(Vector3(offset, 0.012, extent))
		colors.append(color)
		colors.append(color)
		vertices.append(Vector3(-extent, 0.012, offset))
		vertices.append(Vector3(extent, 0.012, offset))
		colors.append(color)
		colors.append(color)
	vertices.append(Vector3(-extent, 0.018, 0.0))
	vertices.append(Vector3(extent, 0.018, 0.0))
	colors.append(Color(0.9, 0.2, 0.18, 1.0))
	colors.append(Color(0.9, 0.2, 0.18, 1.0))
	vertices.append(Vector3(0.0, 0.018, -extent))
	vertices.append(Vector3(0.0, 0.018, extent))
	colors.append(Color(0.2, 0.75, 0.35, 1.0))
	colors.append(Color(0.2, 0.75, 0.35, 1.0))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_COLOR] = colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	grid.mesh = mesh
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	grid.set_surface_override_material(0, material)
	return grid
