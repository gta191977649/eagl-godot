extends Node3D

const CarLoaderScript = preload("res://eagl/assets/car/car_loader.gd")
const CarConfigScript = preload("res://eagl/handling/car_config.gd")
const GlobalBHandlingLoaderScript = preload("res://eagl/handling/globalb_handling_loader.gd")
const DEFAULT_PLATFORM := "EAGL_HOTPUSUIT2_PS2"

const GROUND_SIZE = 20000.0
const GROUND_HEIGHT = 1.0
const GROUND_OFFSET_Y = -0.5
const CAMERA_DISTANCE = 8.5
const CAMERA_TARGET_HEIGHT = 1.55
const CAMERA_LOOK_AHEAD = 2.75
const CAMERA_MOUSE_SENSITIVITY = 0.0035
const CAMERA_MIN_PITCH = deg_to_rad(-18.0)
const CAMERA_MAX_PITCH = deg_to_rad(45.0)
const CAMERA_FILL_LIGHT_ENERGY = 2.2
const CAMERA_FILL_LIGHT_RANGE = 28.0
const AIRBORNE_DEBUG_HEIGHT = 1.65
const HUD_MARGIN = 10
const HUD_GAP = 8
const HUD_WIDE_MIN_WIDTH = 1180.0
const HUD_LEFT_WIDTH = 360.0
const HUD_RIGHT_WIDTH = 400.0


class EngineCurvePlot:
	extends Control

	var torque_curve: Array[Vector2] = []
	var friction_curve: Array[Vector2] = []
	var torque_label := "Torque"
	var friction_label := "Friction"
	var current_rpm := 0.0
	var max_rpm := 1.0

	func set_curves(new_torque_curve: Array, new_friction_curve: Array) -> void:
		torque_curve = _typed_curve(new_torque_curve)
		friction_curve = _typed_curve(new_friction_curve)
		queue_redraw()

	func set_runtime_rpm(new_current_rpm: float, new_max_rpm: float) -> void:
		current_rpm = maxf(new_current_rpm, 0.0)
		max_rpm = maxf(new_max_rpm, 1.0)
		queue_redraw()

	func _draw() -> void:
		var rect := Rect2(Vector2.ZERO, size)
		draw_rect(rect, Color(0.035, 0.038, 0.044, 0.82), true)
		draw_rect(rect, Color(0.30, 0.34, 0.38, 0.75), false, 1.0)
		var content_x := 30.0
		var content_w := maxf(size.x - 40.0, 10.0)
		var plot_h := maxf((size.y - 52.0) * 0.5, 42.0)
		var torque_plot := Rect2(Vector2(content_x, 22.0), Vector2(content_w, plot_h))
		var friction_plot := Rect2(Vector2(content_x, torque_plot.position.y + torque_plot.size.y + 19.0), Vector2(content_w, plot_h))
		_draw_grid(torque_plot)
		_draw_grid(friction_plot)
		var torque_range := _curve_range(torque_curve, true)
		var friction_range := _curve_range(friction_curve, false)
		_draw_curve(torque_plot, torque_curve, float(torque_range.x), float(torque_range.y), Color(1.0, 0.58, 0.18, 1.0), 2.2)
		_draw_curve(friction_plot, friction_curve, float(friction_range.x), float(friction_range.y), Color(0.24, 0.78, 1.0, 1.0), 2.0)
		_draw_rpm_indicator(torque_plot)
		_draw_rpm_indicator(friction_plot)
		var font := get_theme_default_font()
		if font != null:
			draw_string(font, Vector2(8.0, 15.0), "Engine curves", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 12, Color(0.90, 0.92, 0.94))
			draw_string(font, Vector2(8.0, size.y - 5.0), "x: rpm/redline", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 10, Color(0.62, 0.66, 0.70))
			draw_string(font, Vector2(size.x - 72.0, 15.0), "%.0f rpm" % current_rpm, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 10, Color(1.0, 0.92, 0.34))
			draw_rect(Rect2(Vector2(size.x - 104.0, torque_plot.position.y + 8.0), Vector2(10.0, 3.0)), Color(1.0, 0.58, 0.18, 1.0), true)
			draw_string(font, Vector2(size.x - 90.0, torque_plot.position.y + 14.0), "%s %.0f-%.0f" % [torque_label, float(torque_range.x), float(torque_range.y)], HORIZONTAL_ALIGNMENT_LEFT, -1.0, 10, Color(0.90, 0.92, 0.94))
			draw_rect(Rect2(Vector2(size.x - 104.0, friction_plot.position.y + 8.0), Vector2(10.0, 3.0)), Color(0.24, 0.78, 1.0, 1.0), true)
			draw_string(font, Vector2(size.x - 90.0, friction_plot.position.y + 14.0), "%s %.1f-%.1f" % [friction_label, float(friction_range.x), float(friction_range.y)], HORIZONTAL_ALIGNMENT_LEFT, -1.0, 10, Color(0.90, 0.92, 0.94))

	func _draw_curve(plot: Rect2, curve: Array[Vector2], min_y: float, max_y: float, color: Color, width: float) -> void:
		if curve.size() < 2:
			return
		var previous := _plot_point(plot, curve[0], min_y, max_y)
		for index in range(1, curve.size()):
			var current := _plot_point(plot, curve[index], min_y, max_y)
			draw_line(previous, current, color, width, true)
			previous = current
		for point in curve:
			draw_circle(_plot_point(plot, point, min_y, max_y), 2.3, color)

	func _draw_rpm_indicator(plot: Rect2) -> void:
		var normalized := clampf(current_rpm / max_rpm, 0.0, 1.0)
		var x := plot.position.x + normalized * plot.size.x
		draw_line(Vector2(x, plot.position.y), Vector2(x, plot.position.y + plot.size.y), Color(1.0, 0.92, 0.34, 0.95), 1.6, true)
		draw_circle(Vector2(x, plot.position.y), 3.0, Color(1.0, 0.92, 0.34, 1.0))

	func _draw_grid(plot: Rect2) -> void:
		for i in range(5):
			var x := plot.position.x + plot.size.x * float(i) / 4.0
			draw_line(Vector2(x, plot.position.y), Vector2(x, plot.position.y + plot.size.y), Color(0.18, 0.20, 0.23, 0.85), 1.0)
			var y := plot.position.y + plot.size.y * float(i) / 4.0
			draw_line(Vector2(plot.position.x, y), Vector2(plot.position.x + plot.size.x, y), Color(0.18, 0.20, 0.23, 0.85), 1.0)

	func _plot_point(plot: Rect2, point: Vector2, min_y: float, max_y: float) -> Vector2:
		var y_alpha := (point.y - min_y) / maxf(max_y - min_y, 0.0001)
		return Vector2(
			plot.position.x + clampf(point.x, 0.0, 1.0) * plot.size.x,
			plot.position.y + (1.0 - clampf(y_alpha, 0.0, 1.0)) * plot.size.y
		)

	func _curve_range(curve: Array[Vector2], include_zero: bool) -> Vector2:
		if curve.is_empty():
			return Vector2(0.0, 1.0)
		var min_y := 0.0 if include_zero else curve[0].y
		var max_y := curve[0].y
		for point in curve:
			min_y = minf(min_y, point.y)
			max_y = maxf(max_y, point.y)
		var span := maxf(max_y - min_y, 0.0001)
		var padding := span * 0.18
		if include_zero:
			min_y = 0.0
		else:
			min_y -= padding
		max_y += padding
		var step := 50.0 if max_y > 100.0 else 1.0
		min_y = floor(min_y / step) * step
		max_y = ceil(max_y / step) * step
		if max_y <= min_y:
			max_y = min_y + step
		return Vector2(min_y, max_y)

	func _typed_curve(raw_curve: Array) -> Array[Vector2]:
		var out: Array[Vector2] = []
		for point in raw_curve:
			if point is Vector2:
				out.append(point)
			elif point is Array and point.size() >= 2:
				out.append(Vector2(float(point[0]), float(point[1])))
		return out


@export var platform := DEFAULT_PLATFORM
@export_global_dir var game_root = ""
@export_file("*.json") var handling_json_path = ""
@export var initial_car_id := "CORVETTE"

@onready var car = $Car
@onready var camera: Camera3D = $FollowCamera
@onready var telemetry: Label = $HUD/TelemetryPanel/Telemetry
@onready var car_list: ItemList = $HUD/ControlsPanel/MarginContainer/ControlsLayout/CarList
@onready var overlay_toggle: CheckBox = $HUD/ControlsPanel/MarginContainer/ControlsLayout/ControlsRow/OverlayToggle
@onready var airborne_toggle: CheckBox = $HUD/ControlsPanel/MarginContainer/ControlsLayout/DebugOptionsRow/AirborneToggle
@onready var reset_button: Button = $HUD/ControlsPanel/MarginContainer/ControlsLayout/ControlsRow/ResetButton
@onready var current_car_label: Label = $HUD/ControlsPanel/MarginContainer/ControlsLayout/CurrentCarLabel
@onready var world_environment: WorldEnvironment = $WorldEnvironment
@onready var sun: DirectionalLight3D = $Sun
@onready var flat_track = $FlatTrack
@onready var flat_track_shape: CollisionShape3D = $FlatTrack/CollisionShape3D
@onready var flat_track_mesh: MeshInstance3D = $FlatTrack/MeshInstance3D

var _car_loader = null
var _status_message := ""
var _camera_yaw := 0.0
var _camera_pitch := deg_to_rad(14.0)
var _camera_target_position := Vector3.ZERO
var _spawn_transform := Transform3D.IDENTITY
var _car_entries: Array[Dictionary] = []
var _selected_car_index := -1
var _syncing_ui := false
var _car_display_name_cache := {}
var _airborne_debug_enabled := false
var _engine_curve_plot: EngineCurvePlot
var _parameter_summary_label: Label
var _debug_grid: GridContainer


func _enter_tree() -> void:
	var car_node = get_node_or_null("Car")
	if car_node == null:
		return
	var initial_car_id := _resolved_initial_car_id()
	var initial_duplicate := 1
	var initial_drive_type := _default_drive_type()
	if car_node.config != null:
		if String(car_node.config.car_name) != "":
			initial_car_id = String(car_node.config.car_name)
		initial_duplicate = int(car_node.config.duplicate_index)
		initial_drive_type = String(car_node.config.drive_type)
	var loaded_config = _load_authoritative_handling_config(initial_car_id, initial_duplicate, initial_drive_type)
	if loaded_config != null:
		car_node.config = loaded_config
	elif car_node.config == null:
		car_node.config = _build_runtime_config_for_car(initial_car_id, initial_duplicate, initial_drive_type)
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
	_ensure_debug_parameter_panels()
	_ensure_debug_hud_layout()
	_bind_ui()
	_seed_camera_from_car()
	_spawn_transform = _spawn_transform_for_config(car.config)
	var resolved_root := _ensure_eagl_ready()
	_car_loader = CarLoaderScript.new(resolved_root)
	_load_car_visual()
	car.reset_runtime_state(_spawn_transform)
	_apply_airborne_debug_state()
	car.sync_wheel_slots_from_visual()
	_rebuild_car_entries()
	_sync_ui_from_car()


func _process(delta: float) -> void:
	_update_camera(delta)
	_update_hud_grid_columns()
	_update_telemetry()
	_update_parameter_debug_ui()


func _update_camera(delta: float) -> void:
	var forward: Vector3 = car.global_transform.basis * Vector3(0.0, 0.0, 1.0)
	var desired_target = car.global_transform.origin + Vector3.UP * CAMERA_TARGET_HEIGHT + forward * CAMERA_LOOK_AHEAD
	var horizontal_radius = cos(_camera_pitch) * CAMERA_DISTANCE
	var orbit_offset = Vector3(
		-cos(_camera_yaw) * horizontal_radius,
		sin(_camera_pitch) * CAMERA_DISTANCE,
		-sin(_camera_yaw) * horizontal_radius
	)
	var desired_position = desired_target + orbit_offset
	_camera_target_position = desired_target
	camera.global_position = desired_position
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
	if car != null and car.config != null:
		lines.append("Type:  %d   Class: %d   Profile: %d" % [
			int(car.config.globalb_vehicle_type_id),
			int(car.config.globalb_vehicle_class_id),
			int(car.config.globalb_handling_profile_id),
		])
		if car.config.globalb_handling_profile_count > 0:
			lines.append("PSeq:  %s" % _format_profile_sequence(car.config.globalb_handling_profile_sequence))
	lines.append("Speed: %5.1f km/h" % float(snapshot.get("speed_kmh", 0.0)))
	lines.append("RPM:   %5.0f" % float(snapshot.get("rpm", 0.0)))
	lines.append("Gear:  %d" % int(snapshot.get("gear", 1)))
	lines.append("Slip:  %+5.1f deg" % float(snapshot.get("slip_angle_deg", 0.0)))
	lines.append("Mass:  %5.0f kg %s" % [
		float(snapshot.get("mass_kg", 0.0)),
		"(est)" if bool(snapshot.get("mass_is_estimate", false)) else "",
	])
	lines.append("Drv:   %d  Gain: %.6f" % [
		int(snapshot.get("driven_wheel_count", 0)),
		float(snapshot.get("engine_force_gain", 0.0)),
	])
	lines.append("LAcc:  %5.2f  Drag: %6.1f" % [
		float(snapshot.get("hp2_launch_accel_reference", 0.0)),
		float(snapshot.get("drag_force", 0.0)),
	])
	lines.append("EngT:  %6.1f" % float(snapshot.get("engine_force_total", 0.0)))
	lines.append("Mouse: %s" % ("orbit" if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else "click to capture"))
	lines.append("Air:   %s" % ("frozen" if _airborne_debug_enabled else "normal"))
	lines.append("HP2 Asst: %s  mu=%.2f" % [
		String(snapshot.get("assist_wheel", "")),
		float(snapshot.get("surface_mu", 1.0)),
	])
	lines.append("")
	for wheel in snapshot.get("wheels", []):
		lines.append(
			"%s  %s rpm=%6.0f skid=%4.2f steer=%+5.1f eng=%5.1f brk=%5.1f" % [
				String(wheel.get("slot", "--")),
				"GRD" if bool(wheel.get("grounded", false)) else "AIR",
				float(wheel.get("rpm", 0.0)),
				float(wheel.get("skid", 0.0)),
				float(wheel.get("steering_deg", 0.0)),
				float(wheel.get("engine_force", 0.0)),
				float(wheel.get("brake_force", 0.0)),
			]
		)
	telemetry.text = "\n".join(lines)


func _ensure_debug_parameter_panels() -> void:
	var hud := get_node_or_null("HUD") as CanvasLayer
	if hud == null:
		return
	if hud.get_node_or_null("EngineCurvePanel") == null:
		var curve_panel := PanelContainer.new()
		curve_panel.name = "EngineCurvePanel"
		curve_panel.offset_left = 16.0
		curve_panel.offset_top = 220.0
		curve_panel.offset_right = 536.0
		curve_panel.offset_bottom = 490.0
		hud.add_child(curve_panel)

		var curve_margin := MarginContainer.new()
		curve_margin.name = "MarginContainer"
		curve_margin.add_theme_constant_override("margin_left", 6)
		curve_margin.add_theme_constant_override("margin_top", 6)
		curve_margin.add_theme_constant_override("margin_right", 6)
		curve_margin.add_theme_constant_override("margin_bottom", 6)
		curve_panel.add_child(curve_margin)

		_engine_curve_plot = EngineCurvePlot.new()
		_engine_curve_plot.name = "CurvePlot"
		_engine_curve_plot.custom_minimum_size = Vector2(348.0, 218.0)
		_engine_curve_plot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_engine_curve_plot.size_flags_vertical = Control.SIZE_EXPAND_FILL
		curve_margin.add_child(_engine_curve_plot)
	else:
		_engine_curve_plot = hud.get_node("EngineCurvePanel/MarginContainer/CurvePlot") as EngineCurvePlot

	if hud.get_node_or_null("ParameterPanel") == null:
		var parameter_panel := PanelContainer.new()
		parameter_panel.name = "ParameterPanel"
		parameter_panel.offset_left = 16.0
		parameter_panel.offset_top = 500.0
		parameter_panel.offset_right = 536.0
		parameter_panel.offset_bottom = 790.0
		hud.add_child(parameter_panel)

		var parameter_margin := MarginContainer.new()
		parameter_margin.name = "MarginContainer"
		parameter_margin.add_theme_constant_override("margin_left", 8)
		parameter_margin.add_theme_constant_override("margin_top", 6)
		parameter_margin.add_theme_constant_override("margin_right", 8)
		parameter_margin.add_theme_constant_override("margin_bottom", 6)
		parameter_panel.add_child(parameter_margin)

		var parameter_scroll := ScrollContainer.new()
		parameter_scroll.name = "ScrollContainer"
		parameter_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		parameter_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		parameter_margin.add_child(parameter_scroll)

		_parameter_summary_label = Label.new()
		_parameter_summary_label.name = "ParameterSummary"
		_parameter_summary_label.add_theme_font_size_override("font_size", 11)
		_parameter_summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_parameter_summary_label.text = "Loading parameters..."
		_parameter_summary_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		parameter_scroll.add_child(_parameter_summary_label)
	else:
		_parameter_summary_label = hud.get_node("ParameterPanel/MarginContainer/ScrollContainer/ParameterSummary") as Label


func _ensure_debug_hud_layout() -> void:
	var hud := get_node_or_null("HUD") as CanvasLayer
	if hud == null:
		return
	var root := hud.get_node_or_null("HUDRoot") as MarginContainer
	if root == null:
		root = MarginContainer.new()
		root.name = "HUDRoot"
		root.set_anchors_preset(Control.PRESET_FULL_RECT)
		root.add_theme_constant_override("margin_left", HUD_MARGIN)
		root.add_theme_constant_override("margin_top", HUD_MARGIN)
		root.add_theme_constant_override("margin_right", HUD_MARGIN)
		root.add_theme_constant_override("margin_bottom", HUD_MARGIN)
		hud.add_child(root)

		var scroll := ScrollContainer.new()
		scroll.name = "ScrollContainer"
		scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		root.add_child(scroll)

		_debug_grid = GridContainer.new()
		_debug_grid.name = "DebugGrid"
		_debug_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_debug_grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_debug_grid.add_theme_constant_override("h_separation", HUD_GAP)
		_debug_grid.add_theme_constant_override("v_separation", HUD_GAP)
		scroll.add_child(_debug_grid)
	else:
		_debug_grid = root.get_node("ScrollContainer/DebugGrid") as GridContainer

	var left_column := _debug_grid.get_node_or_null("LeftColumn") as VBoxContainer
	if left_column == null:
		left_column = VBoxContainer.new()
		left_column.name = "LeftColumn"
		left_column.custom_minimum_size = Vector2(HUD_LEFT_WIDTH, 0.0)
		left_column.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		left_column.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		left_column.add_theme_constant_override("separation", HUD_GAP)
		_debug_grid.add_child(left_column)

	var telemetry_panel := get_node_or_null("HUD/TelemetryPanel") as Control
	var controls_panel := get_node_or_null("HUD/ControlsPanel") as Control
	_configure_panel_for_layout(telemetry_panel, Vector2(HUD_LEFT_WIDTH, 142.0), false)
	_configure_panel_for_layout(get_node_or_null("HUD/EngineCurvePanel") as Control, Vector2(HUD_LEFT_WIDTH, 230.0), false)
	_configure_panel_for_layout(get_node_or_null("HUD/ParameterPanel") as Control, Vector2(HUD_LEFT_WIDTH, 188.0), false)
	_configure_panel_for_layout(controls_panel, Vector2(HUD_RIGHT_WIDTH, 372.0), false)
	if telemetry != null:
		telemetry.add_theme_font_size_override("font_size", 12)
	if car_list != null:
		car_list.custom_minimum_size = Vector2(0.0, 180.0)
	if current_car_label != null:
		current_car_label.add_theme_font_size_override("font_size", 14)

	_reparent_control(telemetry_panel, left_column)
	_reparent_control(get_node_or_null("HUD/EngineCurvePanel") as Control, left_column)
	_reparent_control(get_node_or_null("HUD/ParameterPanel") as Control, left_column)
	_reparent_control(controls_panel, _debug_grid)
	_update_hud_grid_columns()


func _configure_panel_for_layout(panel: Control, minimum_size: Vector2, expand_vertical: bool) -> void:
	if panel == null:
		return
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.offset_left = 0.0
	panel.offset_top = 0.0
	panel.offset_right = 0.0
	panel.offset_bottom = 0.0
	panel.clip_contents = true
	panel.custom_minimum_size = minimum_size
	panel.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL if expand_vertical else Control.SIZE_SHRINK_BEGIN


func _reparent_control(control: Control, new_parent: Node) -> void:
	if control == null or new_parent == null or control.get_parent() == new_parent:
		return
	control.reparent(new_parent, false)


func _update_hud_grid_columns() -> void:
	if _debug_grid == null:
		return
	var viewport_size := get_viewport().get_visible_rect().size
	_debug_grid.columns = 2 if viewport_size.x >= HUD_WIDE_MIN_WIDTH else 1


func _update_parameter_debug_ui() -> void:
	if car == null:
		return
	var snapshot: Dictionary = car.get_debug_snapshot() if car.has_method("get_debug_snapshot") else {}
	if _engine_curve_plot != null:
		var torque_curve: Array = []
		var friction_curve: Array = []
		if car.engine != null:
			torque_curve = car.engine.torque_curve
			friction_curve = car.engine.friction_curve
			_engine_curve_plot.set_runtime_rpm(float(car.engine.rpm), float(car.engine.max_rpm))
		_engine_curve_plot.set_curves(torque_curve, friction_curve)
	if _parameter_summary_label != null:
		_parameter_summary_label.text = _build_parameter_summary(snapshot)


func _build_parameter_summary(snapshot: Dictionary) -> String:
	if car == null or car.config == null:
		return "No handling config loaded."
	var cfg = car.config
	var lines: Array[String] = []
	lines.append("Loaded Handling Parameters")
	lines.append("Car %s  row %d  dup %d  %s" % [
		String(cfg.car_name),
		int(cfg.row_index),
		int(cfg.duplicate_index),
		String(cfg.drive_type),
	])
	lines.append("Mass %.0f kg  WB %.3f m  Radius %.3f m" % [
		float(cfg.mass_kg),
		float(car.wheelbase),
		float(car.wheel_radius),
	])
	lines.append("Gear %d  RPM %.0f  Shift %.0f/%.0f" % [
		int(snapshot.get("gear", 1)),
		float(snapshot.get("rpm", 0.0)),
		float(car.drivetrain.downshift_rpm),
		float(car.drivetrain.upshift_rpm),
	])
	lines.append("Final %.3f  Gears %s" % [
		float(car.drivetrain.final_drive),
		_format_float_array(Array(car.drivetrain.gear_ratios), "%.2f", 7),
	])
	lines.append("Grip long F/R %.2f %.2f  lat F/R %.2f %.2f" % [
		float(car.front_wheel_grip_scale),
		float(car.rear_wheel_grip_scale),
		float(car.front_wheel_lat_grip_scale),
		float(car.rear_wheel_lat_grip_scale),
	])
	lines.append("Surface %s  mu %.3f  brake %.0f  bias %.2f" % [
		String(snapshot.get("surface_type", "")),
		float(snapshot.get("surface_mu", 0.0)),
		float(car.brake_torque_total),
		float(car.brake_bias_front),
	])
	lines.append("Steer max %.1f deg  response %.2f  hi-scale %.2f@%.0f" % [
		float(car.steering_system.max_steer_degrees),
		float(car.steering_system.steering_response_rate),
		float(car.steering_system.high_speed_steer_scale),
		float(car.steering_system.high_speed_steer_kph),
	])
	lines.append("Aero %.4f  roll %.4f  WT %.2f  CG %.2f" % [
		float(car.aero_drag),
		float(car.rolling_resistance),
		float(car.weight_transfer_coeff),
		float(car.cg_height),
	])
	lines.append("Torque samples %s" % _format_float_array(Array(cfg.engine_torque_samples), "%.3f", 9))
	lines.append("Friction samples %s" % _format_float_array(Array(cfg.engine_friction_samples), "%.3f", 3))
	return "\n".join(lines)


func _format_float_array(values: Array, pattern: String, max_items: int) -> String:
	var parts: Array[String] = []
	for index in range(mini(values.size(), max_items)):
		parts.append(pattern % float(values[index]))
	if values.size() > max_items:
		parts.append("...")
	return "[" + ", ".join(parts) + "]"


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
	var visual = _car_loader.load(car.config.car_name, car.config)
	if visual == null:
		_set_status("Car visual failed: %s" % _car_loader.last_error)
		push_warning("Failed to load car visual for %s: %s" % [car.config.car_name, _car_loader.last_error])
		car.replace_visual(null)
		return
	_set_status("")
	car.replace_visual(visual)
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
	if car_node == null or car_node.config == null:
		return null
	return _load_authoritative_handling_config(
		String(car_node.config.car_name),
		int(car_node.config.duplicate_index),
		String(car_node.config.drive_type)
	)


func _load_authoritative_handling_config(car_name: String, duplicate_index: int = 1, drive_type: String = "") -> Resource:
	if car_name == "":
		return null
	var resolved_drive_type := drive_type if drive_type != "" else _default_drive_type()
	var loader = GlobalBHandlingLoaderScript.new()
	var globalb_path := _resolved_globalb_path()
	if globalb_path != "":
		var binary_loaded = loader.load_config_from_globalb(globalb_path, car_name, duplicate_index, resolved_drive_type)
		if binary_loaded != null:
			print("EAGL handling config: car=%s duplicate=%d source=GLOBALB.BUN path=%s" % [
				binary_loaded.car_name,
				int(binary_loaded.duplicate_index),
				globalb_path,
			])
			return binary_loaded
	var json_path := _resolved_handling_json_path()
	if json_path == "" or not FileAccess.file_exists(json_path):
		return null
	var json_loaded = loader.load_config(json_path, car_name, duplicate_index, resolved_drive_type)
	if json_loaded == null:
		push_warning("Failed to load handling JSON config for %s from %s" % [car_name, json_path])
		return null
	print("EAGL handling config: car=%s duplicate=%d source=json path=%s" % [
		json_loaded.car_name,
		int(json_loaded.duplicate_index),
		json_path,
	])
	return json_loaded


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
	if airborne_toggle != null and not airborne_toggle.toggled.is_connected(_on_airborne_toggled):
		airborne_toggle.toggled.connect(_on_airborne_toggled)
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
	var loader = GlobalBHandlingLoaderScript.new()
	var globalb_path := _resolved_globalb_path()
	if globalb_path != "":
		var globalb_entries: Array[Dictionary] = loader.list_globalb_entries(globalb_path)
		globalb_entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			var car_a := String(a.get("car_name", ""))
			var car_b := String(b.get("car_name", ""))
			if car_a == car_b:
				return int(a.get("duplicate_index", 1)) < int(b.get("duplicate_index", 1))
			return car_a < car_b
		)
		for row in globalb_entries:
			var car_id := String(row.get("car_name", ""))
			if not _car_asset_exists(cars_dir, car_id):
				continue
			var drive_type := String(row.get("drive_type", _drive_type_for_car(car_id)))
			var duplicate_index := int(row.get("duplicate_index", 1))
			var entry_key := _entry_key(car_id, duplicate_index, drive_type)
			if seen.has(entry_key):
				continue
			seen[entry_key] = true
			var display_name := _binary_display_name_for_car(car_id)
			_car_entries.append({
				"key": entry_key,
				"label": _format_car_entry_label(car_id, duplicate_index, drive_type, "Binary"),
				"source": "car_binary",
				"car_name": car_id,
				"display_name": display_name,
				"duplicate_index": duplicate_index,
				"drive_type": drive_type,
				"globalb_row_index": int(row.get("row_index", -1)),
				"handling_profile_id": int(row.get("handling_profile_id", -1)),
				"vehicle_class_id": int(row.get("vehicle_class_id", -1)),
			})
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
		var drive_type := _drive_type_for_car(car_id)
		var entry_key := _entry_key(car_id, 1, drive_type)
		if seen.has(entry_key):
			continue
		seen[entry_key] = true
		var display_name := _binary_display_name_for_car(car_id)
		_car_entries.append({
			"key": entry_key,
			"label": _format_car_entry_label(car_id, 1, drive_type, "Binary"),
			"source": "car_binary",
			"car_name": car_id,
			"display_name": display_name,
			"duplicate_index": 1,
			"drive_type": drive_type,
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
		"display_name": _binary_display_name_for_car(car_name),
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
	if airborne_toggle != null:
		_syncing_ui = true
		airborne_toggle.button_pressed = _airborne_debug_enabled
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
	return "RWD"


func _drive_type_for_car(car_name: String) -> String:
	if car != null and car.config != null and String(car.config.car_name).to_upper() == car_name.to_upper():
		return String(car.config.drive_type)
	return "RWD"


func _entry_key(car_name: String, _duplicate_index: int, drive_type: String) -> String:
	return "%s::%s" % [car_name.strip_edges().to_upper(), drive_type.strip_edges().to_upper()]


func _format_car_entry_label(car_name: String, _duplicate_index: int, drive_type: String, source_label: String) -> String:
	var label := _binary_display_name_for_car(car_name)
	if label == "":
		label = car_name.strip_edges().to_upper()
	if drive_type != "":
		label += " [%s]" % drive_type
	if source_label != "":
		label += "  %s" % source_label
	return label


func _binary_display_name_for_car(car_name: String) -> String:
	var normalized := car_name.strip_edges().to_upper()
	if normalized == "":
		return ""
	if _car_display_name_cache.has(normalized):
		return String(_car_display_name_cache[normalized])

	var display_name := normalized
	if _car_loader != null:
		var binary_name := String(_car_loader.read_binary_car_name(normalized)).strip_edges().to_upper()
		if binary_name != "":
			display_name = binary_name
	_car_display_name_cache[normalized] = display_name
	return display_name


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
	_apply_airborne_debug_state()
	car.sync_wheel_slots_from_visual()
	_seed_camera_from_car()
	_rebuild_car_entries()
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
	_apply_airborne_debug_state()
	_seed_camera_from_car()
	_set_status("Reset %s" % _current_car_display_name())


func _on_overlay_toggled(enabled: bool) -> void:
	if _syncing_ui:
		return
	car.set_debug_overlay_enabled(enabled)
	_set_status("Debug overlay %s" % ("enabled" if enabled else "hidden"))


func _on_airborne_toggled(enabled: bool) -> void:
	if _syncing_ui:
		return
	_airborne_debug_enabled = enabled
	_apply_airborne_debug_state()
	_seed_camera_from_car()
	_set_status("Airborne debug %s" % ("enabled" if enabled else "disabled"))


func _apply_airborne_debug_state() -> void:
	if car == null:
		return
	if car.has_method("set_airborne_debug_enabled"):
		car.set_airborne_debug_enabled(_airborne_debug_enabled, AIRBORNE_DEBUG_HEIGHT)
		if not _airborne_debug_enabled:
			car.reset_runtime_state(_spawn_transform)
		return
	car.freeze = _airborne_debug_enabled
	car.linear_velocity = Vector3.ZERO
	car.angular_velocity = Vector3.ZERO
	car.sleeping = false
	if _airborne_debug_enabled:
		var airborne_transform: Transform3D = car.transform
		airborne_transform.origin.y = AIRBORNE_DEBUG_HEIGHT
		car.reset_runtime_state(airborne_transform)
	else:
		car.reset_runtime_state(_spawn_transform)


func _build_runtime_config_for_car(car_name: String, duplicate_index: int = 1, drive_type: String = ""):
	var resolved_drive_type: String = drive_type if drive_type != "" else _default_drive_type()
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


func _resolved_globalb_path() -> String:
	var resolved_root: String = _resolved_game_root()
	if resolved_root == "":
		return ""
	var globalb_path := resolved_root.path_join("GLOBAL").path_join("GLOBALB.BUN")
	if FileAccess.file_exists(globalb_path):
		return globalb_path
	return ""


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


func _car_asset_exists(cars_dir: String, car_id: String) -> bool:
	var geometry_bin := cars_dir.path_join(car_id).path_join("GEOMETRY.BIN")
	var geometry_lzc := cars_dir.path_join(car_id).path_join("GEOMETRY.LZC")
	return FileAccess.file_exists(geometry_bin) or FileAccess.file_exists(geometry_lzc)


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
	var forward: Vector3 = (car.global_transform.basis * Vector3(0.0, 0.0, 1.0)).normalized()
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
	print("EAGL vehicle loaded: car=%s body_variant=%s source=%s body_meshes=%d textures=%d textured_surfaces=%d fallback_surfaces=%d" % [
		String(visual.get_meta("eagl_car_id", "")),
		String(visual.get_meta("eagl_primary_body_variant", "")),
		String(visual.get_meta("eagl_source_path", "")),
		int(visual.get_meta("eagl_body_mesh_count", 0)),
		int(visual.get_meta("eagl_texture_count", 0)),
		int(visual.get_meta("eagl_textured_surface_count", 0)),
		int(visual.get_meta("eagl_fallback_surface_count", 0)),
	])
	var texture_source := String(visual.get_meta("eagl_texture_source_path", ""))
	if texture_source != "":
		print("EAGL vehicle textures: source=%s skipped=%d uv_surfaces=%d missing_uv=%d" % [
			texture_source,
			int(visual.get_meta("eagl_skipped_texture_count", 0)),
			int(visual.get_meta("eagl_uv_surface_count", 0)),
			int(visual.get_meta("eagl_textured_missing_uv_surface_count", 0)),
		])
	print("EAGL vehicle assembly: body_groups=%s wheel_groups=%s brake_groups=%s variant=%s" % [
		assembly_summary.get("body_group_count", "?"),
		assembly_summary.get("wheel_group_count", "?"),
		assembly_summary.get("brake_group_count", "?"),
		assembly_summary.get("variant_name", ""),
	])
	print("EAGL vehicle wheel pivots: %s" % ", ".join(PackedStringArray(wheel_pivots)))
	print("EAGL vehicle dummies: %s" % ", ".join(PackedStringArray(dummies)))
	print("EAGL vehicle globalb: type=%d class=%d profile=%d seq=%s" % [
		int(visual.get_meta("eagl_vehicle_type_id", -1)),
		int(visual.get_meta("eagl_vehicle_class_id", -1)),
		int(visual.get_meta("eagl_handling_profile_id", -1)),
		_format_profile_sequence(PackedInt32Array(visual.get_meta("eagl_handling_profile_sequence", PackedInt32Array()))),
	])
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


func _format_profile_sequence(sequence: PackedInt32Array) -> String:
	if sequence.is_empty():
		return "-"
	var parts: Array[String] = []
	for value in sequence:
		parts.append(str(value))
	return ",".join(parts)
