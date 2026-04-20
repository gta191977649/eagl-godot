extends Node3D

const FreeCameraScript := preload("res://eagl/debug/free_camera.gd")

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
var _drive_toggle: CheckButton
var _follow_toggle: CheckButton
var _all_variants_toggle: CheckButton
var _group_toggles: Dictionary = {}

const PART_GROUPS := ["Body", "Wheels", "Brakes", "GlassLightsDamage", "ShadowBlur", "Dashboard"]


func _ready() -> void:
	_ensure_world()
	_ensure_ui()
	_initialize_eagl()
	_populate_car_selector()
	_load_selected_or_default()


func _process(delta: float) -> void:
	_update_follow_camera(delta)
	_update_debug_labels()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R:
			_reset_car()
		elif event.keycode == KEY_F:
			_frame_car()


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
	_frame_car()
	_set_status("Loaded %s" % car_id)


func _reset_car() -> void:
	if _car_root == null:
		return
	_car_root.global_transform = Transform3D(Basis.IDENTITY, Vector3(0.0, _car_suspension_height(_car_root), 0.0))
	if _controller != null and _controller.has_method("reset_motion"):
		_controller.reset_motion()


func _ensure_world() -> void:
	if get_node_or_null("Sun") == null:
		var sun := DirectionalLight3D.new()
		sun.name = "Sun"
		sun.light_energy = 5.0
		sun.rotation_degrees = Vector3(-45.0, 35.0, 0.0)
		add_child(sun)
	if get_node_or_null("DebugCamera") == null:
		var camera := Camera3D.new()
		camera.name = "DebugCamera"
		camera.current = true
		camera.position = Vector3(0.0, 5.0, 12.0)
		camera.rotation_degrees = Vector3(-20.0, 0.0, 0.0)
		camera.script = FreeCameraScript
		add_child(camera)
		_debug_camera = camera
	else:
		_debug_camera = get_node_or_null("DebugCamera") as Camera3D
	if get_node_or_null("Ground") == null:
		var body := StaticBody3D.new()
		body.name = "Ground"
		var collision := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(240.0, 0.2, 240.0)
		collision.shape = shape
		body.add_child(collision)
		var mesh := MeshInstance3D.new()
		var plane := PlaneMesh.new()
		plane.size = Vector2(240.0, 240.0)
		mesh.mesh = plane
		var material := StandardMaterial3D.new()
		material.albedo_color = Color(0.18, 0.2, 0.18)
		material.roughness = 1.0
		mesh.set_surface_override_material(0, material)
		body.add_child(mesh)
		body.add_child(_make_grid_mesh())
		add_child(body)


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
	_drive_toggle = CheckButton.new()
	_drive_toggle.text = "Drive"
	_drive_toggle.button_pressed = true
	_drive_toggle.toggled.connect(func(_pressed: bool) -> void: _apply_debug_toggles())
	top.add_child(_drive_toggle)
	_follow_toggle = CheckButton.new()
	_follow_toggle.text = "Follow cam"
	_follow_toggle.button_pressed = false
	top.add_child(_follow_toggle)
	_all_variants_toggle = CheckButton.new()
	_all_variants_toggle.text = "All variants"
	_all_variants_toggle.button_pressed = false
	_all_variants_toggle.toggled.connect(func(_pressed: bool) -> void:
		_initialize_eagl()
		_load_selected_or_default()
	)
	top.add_child(_all_variants_toggle)
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
	_camera_label.name = "FreeCameraLabel"
	_camera_label.text = "Free camera"
	rows.add_child(_camera_label)
	if _debug_camera != null:
		_debug_camera.speed_label_path = _debug_camera.get_path_to(_camera_label)


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
	_stats_label.text = "Car: %s\nSpeed: %.1f km/h  Grounded: %s  Slip: %.2f\nLocal: %.2f forward / %.2f side  Yaw: %.3f  Steer: %.2f\nObjects: %s rendered / %s parsed / %s hidden  Wheels: %s  Brakes: %s\nTextures: %s bank / %s textured surfaces / %s fallback  Locators: %s\nBounds: %.2f x %.2f x %.2f  Visual offset: %.2f, %.2f, %.2f\nGeometry: %s  Tuning: %s (%s)\nWarnings: %s\nControls: W/S throttle/brake, A/D steer, Space handbrake, R reset, F frame camera" % [
		_car_root.get_meta("eagl_car_id", ""),
		float(state.get("speed_kmh", 0.0)),
		str(state.get("grounded", false)),
		float(state.get("slip", 0.0)),
		float(state.get("longitudinal_speed", 0.0)),
		float(state.get("lateral_speed", 0.0)),
		float(state.get("yaw_rate", 0.0)),
		float(state.get("steer", 0.0)),
		_car_root.get_meta("eagl_rendered_object_count", 0),
		_car_root.get_meta("eagl_object_count", 0),
		_car_root.get_meta("eagl_hidden_variant_count", 0),
		_car_root.get_meta("eagl_wheel_instance_count", 0),
		_car_root.get_meta("eagl_brake_instance_count", 0),
		_car_root.get_meta("eagl_texture_count", 0),
		_car_root.get_meta("eagl_textured_surface_count", 0),
		_car_root.get_meta("eagl_fallback_surface_count", 0),
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
		warnings.size(),
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
	if _controller != null and _drive_toggle != null:
		_controller.enabled = _drive_toggle.button_pressed
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


func _frame_car() -> void:
	if _car_root == null or _debug_camera == null:
		return
	var bounds: AABB = _car_root.get_meta("eagl_bounds", AABB(Vector3(-2.0, -0.75, -4.0), Vector3(4.0, 2.0, 8.0)))
	var focus := _car_root.global_position + bounds.position + bounds.size * 0.5
	var radius := maxf(maxf(bounds.size.x, bounds.size.y), bounds.size.z) * 0.65
	var distance := maxf(8.0, radius * 2.4)
	_debug_camera.global_position = focus + Vector3(distance * 0.55, maxf(3.0, radius * 0.55), distance)
	_debug_camera.look_at(focus, Vector3.UP)


func _update_follow_camera(delta: float) -> void:
	if _car_root == null or _debug_camera == null or _follow_toggle == null or not _follow_toggle.button_pressed:
		return
	var basis := _car_root.global_transform.basis.orthonormalized()
	var target := _car_root.global_position + Vector3.UP * 1.3
	var desired := target + basis.z * 9.0 + Vector3.UP * 3.2
	_debug_camera.global_position = _debug_camera.global_position.lerp(desired, clampf(delta * 5.0, 0.0, 1.0))
	_debug_camera.look_at(target, Vector3.UP)


func _car_suspension_height(car: Node) -> float:
	var tuning: Dictionary = car.get_meta("eagl_physics_tuning", {})
	return float(tuning.get("suspension_height", 0.75))


func _make_grid_mesh() -> MeshInstance3D:
	var grid := MeshInstance3D.new()
	grid.name = "DebugGrid"
	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	var half := 60
	for i in range(-half, half + 1):
		var color := Color(0.32, 0.36, 0.34, 1.0) if i % 5 == 0 else Color(0.24, 0.27, 0.25, 1.0)
		vertices.append(Vector3(i, 0.012, -half))
		vertices.append(Vector3(i, 0.012, half))
		colors.append(color)
		colors.append(color)
		vertices.append(Vector3(-half, 0.012, i))
		vertices.append(Vector3(half, 0.012, i))
		colors.append(color)
		colors.append(color)
	vertices.append(Vector3(-half, 0.018, 0.0))
	vertices.append(Vector3(half, 0.018, 0.0))
	colors.append(Color(0.9, 0.2, 0.18, 1.0))
	colors.append(Color(0.9, 0.2, 0.18, 1.0))
	vertices.append(Vector3(0.0, 0.018, -half))
	vertices.append(Vector3(0.0, 0.018, half))
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
