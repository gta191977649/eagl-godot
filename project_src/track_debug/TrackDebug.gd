class_name TrackDebug
extends Node3D

const EaglTrackLoaderScript = preload("res://track_debug/eagl_loader/EaglTrackLoader.gd")
const EaglLayerPolicyScript = preload("res://track_debug/eagl_loader/EaglLayerPolicy.gd")
const TrackDebugCatalogScript = preload("res://track_debug/TrackDebugCatalog.gd")

@export var tracks_root = "/Users/nurupo/Desktop/nfshp2/tracks"
@export var track_name = "Medit"
@export var level_index = 0
@export var route_radius = 1
@export var route_frustum_culling = true
@export var debug_route_switches = true
@export var debug_track_rebuilds = true
@export var route_switch_hysteresis = 0.0

@onready var camera: Camera3D = $FreeCamera
@onready var hud: Label = $DebugHud/Panel/Label
@onready var world_root: Node3D = $World
@onready var speed_slider: HSlider = $DebugHud/CameraPanel/VBox/Speed
@onready var sensitivity_slider: HSlider = $DebugHud/CameraPanel/VBox/Sensitivity
@onready var fov_slider: HSlider = $DebugHud/CameraPanel/VBox/Fov
@onready var track_select: OptionButton = $DebugHud/SelectPanel/VBox/Track
@onready var level_select: OptionButton = $DebugHud/SelectPanel/VBox/Level
@onready var full_route_check: CheckBox = $DebugHud/SelectPanel/VBox/FullRoute
@onready var auto_camera_check: CheckBox = $DebugHud/SelectPanel/VBox/AutoCamera
@onready var ai_route_lines_check: CheckBox = $DebugHud/SelectPanel/VBox/AIRouteLines

var loader = EaglTrackLoaderScript.new()
var track_node: Node3D
var route_index = 0
var route_boundary_index = 0
var route_preload_index = -1
var layer_mode = "normal_only"
var show_full_route = false
var auto_camera_route = true
var show_ai_route_lines = true
var _updating_selectors = false
var _loaded_route_key = ""
var _last_route_distance = -1.0
var _route_travel_direction = 0
var active_route_indices: Array[int] = []
var active_compartments: Array[int] = []
var last_error = ""

func _ready() -> void:
	_init_camera_panel()
	_init_selector_panel()
	load_track()

func _process(_delta: float) -> void:
	if _reload_track_if_source_changed():
		_update_hud()
		return
	var route_changed = _update_camera_route()
	if route_frustum_culling and not route_changed:
		_refresh_visibility()
	_update_hud()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		_handle_debug_key(event.keycode)

func load_track() -> void:
	var old_child_count = _clear_world()
	_reset_route_state()
	_loaded_route_key = _route_source_key()
	track_node = loader.load_track(tracks_root, track_name, level_index)
	world_root.add_child(track_node)
	loader.sync_route_node_anchors()
	last_error = str(track_node.get_meta("error", ""))
	_place_camera()
	route_index = clamp(route_index, 0, max(0, loader.route.compartment_ids.size() - 1))
	if auto_camera_route and not loader.route.compartment_ids.is_empty():
		_snap_route_to_camera_projection()
	else:
		_refresh_visibility()
	_log_track_rebuild(old_child_count)
	_log_loader_warnings()

func _handle_debug_key(keycode: int) -> void:
	if keycode == KEY_BRACKETLEFT:
		_step_route(-1)
	elif keycode == KEY_BRACKETRIGHT:
		_step_route(1)
	elif keycode == KEY_L:
		layer_mode = EaglLayerPolicyScript.next_mode(layer_mode)
		_refresh_visibility()
	elif keycode == KEY_F:
		route_frustum_culling = not route_frustum_culling
		_refresh_visibility()
	elif keycode == KEY_R:
		load_track()
	elif keycode == KEY_H:
		$DebugHud.visible = not $DebugHud.visible
	elif keycode == KEY_C:
		_snap_route_to_camera()

func _init_camera_panel() -> void:
	speed_slider.value = camera.base_speed
	sensitivity_slider.value = camera.mouse_sensitivity * 1000.0
	fov_slider.value = camera.fov
	speed_slider.value_changed.connect(_set_camera_speed)
	sensitivity_slider.value_changed.connect(_set_camera_sensitivity)
	fov_slider.value_changed.connect(_set_camera_fov)

func _init_selector_panel() -> void:
	full_route_check.button_pressed = show_full_route
	auto_camera_check.button_pressed = auto_camera_route
	ai_route_lines_check.button_pressed = show_ai_route_lines
	track_select.item_selected.connect(_select_track)
	level_select.item_selected.connect(_select_level)
	full_route_check.toggled.connect(_set_full_route)
	auto_camera_check.toggled.connect(_set_auto_camera_route)
	ai_route_lines_check.toggled.connect(_set_ai_route_lines)
	_populate_tracks()
	_populate_levels()

func _populate_tracks() -> void:
	_updating_selectors = true
	track_select.clear()
	var names = TrackDebugCatalogScript.track_names(tracks_root)
	if not names.is_empty() and not names.has(track_name):
		track_name = names[0]
	for name in names:
		track_select.add_item(name)
		if name == track_name:
			track_select.select(track_select.item_count - 1)
	_updating_selectors = false

func _populate_levels() -> void:
	_updating_selectors = true
	level_select.clear()
	var values = TrackDebugCatalogScript.level_indices(tracks_root, track_name)
	if not values.is_empty() and not values.has(level_index):
		level_index = values[0]
	elif values.is_empty():
		level_index = 0
	for value in values:
		level_select.add_item("level%02d" % value)
		level_select.set_item_metadata(level_select.item_count - 1, value)
		if value == level_index:
			level_select.select(level_select.item_count - 1)
	_updating_selectors = false

func _select_track(index: int) -> void:
	if _updating_selectors:
		return
	track_name = track_select.get_item_text(index)
	route_index = 0
	_populate_levels()
	load_track()

func _select_level(index: int) -> void:
	if _updating_selectors:
		return
	level_index = int(level_select.get_item_metadata(index))
	route_index = 0
	load_track()

func _set_full_route(enabled: bool) -> void:
	show_full_route = enabled
	_refresh_visibility()

func _set_auto_camera_route(enabled: bool) -> void:
	auto_camera_route = enabled
	if enabled and not loader.route.compartment_ids.is_empty():
		_snap_route_to_camera_projection()
	else:
		_refresh_visibility()

func _set_ai_route_lines(enabled: bool) -> void:
	show_ai_route_lines = enabled

func _set_camera_speed(value: float) -> void:
	camera.base_speed = value

func _set_camera_sensitivity(value: float) -> void:
	camera.mouse_sensitivity = value / 1000.0

func _set_camera_fov(value: float) -> void:
	camera.fov = value

func _step_route(delta: int) -> void:
	auto_camera_route = false
	auto_camera_check.button_pressed = false
	var old_index = route_index
	if loader.route.compartment_ids.is_empty():
		route_index = 0
	else:
		_route_travel_direction = 1 if delta > 0 else -1
		route_boundary_index = _wrapped_route_index(route_boundary_index + delta)
		route_index = _route_render_index_from_boundary(route_boundary_index)
		_update_route_preload_index()
	_refresh_visibility()
	_log_route_switch("manual", old_index, route_index, route_index, 0.0, 0.0)


func _snap_route_to_camera() -> void:
	if loader.route.compartment_ids.is_empty():
		return
	var old_index = route_index
	_snap_route_to_camera_projection()
	_log_route_switch("snap", old_index, route_index, route_index, _last_route_distance, 0.0)


func _snap_route_to_camera_projection() -> void:
	if loader.route == null or loader.route.compartment_ids.is_empty():
		return
	var distance_along = loader.route.route_distance_along(camera.global_position)
	route_index = loader.route.route_index_at_distance_for_direction(distance_along, 0)
	route_boundary_index = route_index
	route_preload_index = -1
	_last_route_distance = distance_along
	_route_travel_direction = 0
	_refresh_visibility()


func _reload_track_if_source_changed() -> bool:
	if _route_source_key() == _loaded_route_key:
		return false
	route_index = 0
	_populate_tracks()
	_populate_levels()
	load_track()
	return true

func _update_camera_route() -> bool:
	if show_full_route or not auto_camera_route or loader.route.compartment_ids.is_empty():
		return false
	var distance_along = loader.route.route_distance_along_near(camera.global_position, _last_route_distance)
	var previous_distance = _last_route_distance
	var old_index = route_index
	var old_preload = route_preload_index
	var old_direction = _route_travel_direction
	_update_route_travel_direction(distance_along)
	var proposed_boundary = loader.route.route_index_at_distance_for_direction(distance_along, _route_travel_direction)
	route_boundary_index = _limited_route_boundary_index_from(route_boundary_index, proposed_boundary) if previous_distance >= 0.0 else proposed_boundary
	var proposed = _route_render_index_from_boundary(route_boundary_index)
	if previous_distance < 0.0:
		proposed = _route_render_index_from_boundary(loader.route.route_index_at_distance_for_direction(distance_along, 0))
	route_index = proposed
	_update_route_preload_index()
	var preload_changed = old_preload != route_preload_index or old_direction != _route_travel_direction
	if route_index != old_index or preload_changed:
		_refresh_visibility()
		var movement_delta = loader.route.route_distance_delta(previous_distance, distance_along) if previous_distance >= 0.0 else 0.0
		_log_route_switch("auto", old_index, route_index, proposed, distance_along, movement_delta)
		return true
	return false


func route_probe_position() -> Vector3:
	return _route_probe_position()


func route_progress_index() -> int:
	if loader.route == null or loader.route.compartment_ids.is_empty():
		return -1
	return route_boundary_index


func route_direction_label() -> String:
	if _route_travel_direction > 0:
		return "forward"
	if _route_travel_direction < 0:
		return "reverse"
	return "unknown"


func _route_probe_position() -> Vector3:
	if loader.route == null or loader.route.route_points.is_empty():
		return camera.global_position
	return loader.route.projected_position(camera.global_position)


func _update_route_travel_direction(distance_along: float) -> void:
	if _last_route_distance < 0.0:
		_last_route_distance = distance_along
		return
	var delta = loader.route.route_distance_delta(_last_route_distance, distance_along)
	if absf(delta) > 0.25:
		_route_travel_direction = 1 if delta > 0.0 else -1
	else:
		var tangent = loader.route.route_tangent_at_distance(distance_along)
		var camera_forward = -camera.global_transform.basis.z
		var view_alignment = Vector2(camera_forward.x, camera_forward.z).dot(Vector2(tangent.x, tangent.z))
		if absf(view_alignment) > 0.2:
			_route_travel_direction = 1 if view_alignment > 0.0 else -1
	_last_route_distance = distance_along


func _refresh_visibility() -> void:
	var radius = -1 if show_full_route else route_radius
	if radius < 0:
		active_route_indices = _all_route_indices()
		active_compartments = loader.set_route_visibility(route_index, radius, layer_mode, camera, route_frustum_culling)
	else:
		active_route_indices = _active_route_window_indices()
		active_compartments = loader.set_route_visibility_for_indices(active_route_indices, layer_mode, camera, route_frustum_culling)


func _log_route_switch(reason: String, old_index: int, new_index: int, proposed_index: int, distance_along: float, movement_delta: float) -> void:
	if not debug_route_switches or old_index == new_index:
		return
	var old_comp = _route_compartment_at(old_index)
	var new_comp = _route_compartment_at(new_index)
	var proposed_comp = _route_compartment_at(proposed_index)
	var boundary_comp = _route_compartment_at(route_boundary_index)
	var preload_comp = _route_compartment_at(route_preload_index) if route_preload_index >= 0 else -1
	var projected = route_probe_position()
	var anchor = loader.route.route_position_for_index(new_index)
	print("[route-switch] %s %s level%02d old=%d/comp%d new=%d/comp%d proposed=%d/comp%d boundary=%d/comp%d preload=%d/comp%d travel=%s dist=%.2f delta=%.2f active_indices=%s active=%s projected=%s anchor=%s camera=%s" % [
		reason,
		track_name,
		level_index,
		old_index,
		old_comp,
		new_index,
		new_comp,
		proposed_index,
		proposed_comp,
		route_boundary_index,
		boundary_comp,
		route_preload_index,
		preload_comp,
		route_direction_label(),
		distance_along,
		movement_delta,
		str(active_route_indices),
		str(active_compartments),
		_format_vec3(projected),
		_format_vec3(anchor),
		_format_vec3(camera.global_position)
	])


func _log_track_rebuild(old_child_count: int) -> void:
	if not debug_track_rebuilds:
		return
	print("[track-rebuild] %s level%02d removed_world_roots=%d world_roots=%d route_nodes=%d unique_comps=%d ai_points=%d ai_segments=%d loaded_comps=%d level_nodes=%d active=%s textures=%d decoded=%d skipped=%s error=%s" % [
		track_name,
		level_index,
		old_child_count,
		world_root.get_child_count(),
		loader.route.compartment_ids.size(),
		loader.route.unique_compartments().size(),
		loader.route.ai_route_points.size(),
		loader.route.ai_route_segments.size(),
		loader.loaded_compartments.size(),
		loader.level_nodes.size(),
		str(active_compartments),
		loader.level_texture_bank.textures.size(),
		loader.level_texture_bank.decoded_images,
		str(loader.skipped),
		last_error if last_error != "" else "none"
	])
	print("[track-rebuild] %s level%02d layers=%s" % [track_name, level_index, str(loader.layer_counts)])


func _log_loader_warnings() -> void:
	if not debug_track_rebuilds:
		return
	if loader.material_factory.missing_textures > 0:
		print("[load-warning] %s level%02d missing base/material textures=%d" % [track_name, level_index, loader.material_factory.missing_textures])
	if loader.level_material_factory.missing_textures > 0:
		print("[load-warning] %s level%02d missing level/material textures=%d" % [track_name, level_index, loader.level_material_factory.missing_textures])
	for reason in loader.skipped.keys():
		var count = int(loader.skipped[reason])
		if count > 0:
			print("[load-warning] %s level%02d skipped %s x%d" % [track_name, level_index, reason, count])
	for warning in loader.warnings:
		print("[load-warning] %s level%02d %s" % [track_name, level_index, warning])
	for layer_name in loader.layer_counts.keys():
		if not EaglLayerPolicyScript.is_normal_layer(layer_name) and not EaglLayerPolicyScript.is_lod_layer(layer_name):
			print("[load-warning] %s level%02d unknown layer '%s' x%d hidden in normal_only" % [
				track_name,
				level_index,
				layer_name,
				int(loader.layer_counts[layer_name])
			])


func _route_compartment_at(index: int) -> int:
	if loader.route == null or loader.route.compartment_ids.is_empty():
		return -1
	return loader.route.compartment_ids[_wrapped_route_index(index)]


func _format_vec3(value: Vector3) -> String:
	return "(%.1f,%.1f,%.1f)" % [value.x, value.y, value.z]


func _reset_route_state() -> void:
	_last_route_distance = -1.0
	_route_travel_direction = 0
	route_boundary_index = 0
	route_preload_index = -1
	active_route_indices = []


func _route_source_key() -> String:
	return "%s:%s:%d" % [tracks_root, track_name, level_index]

func _update_hud() -> void:
	var stats = loader.stats()
	var progress_index = route_progress_index()
	var progress_comp = loader.route.compartment_ids[progress_index] if progress_index != -1 else -1
	var view_label = "full" if show_full_route else "hp2 +/- %d + two-away" % max(route_radius, 1)
	var route_node_count = loader.route.compartment_ids.size()
	var route_comp_count = loader.route.unique_compartments().size()
	var boundary_comp = loader.route.compartment_ids[route_boundary_index] if not loader.route.compartment_ids.is_empty() else -1
	var preload_comp = loader.route.compartment_ids[route_preload_index] if route_preload_index >= 0 and not loader.route.compartment_ids.is_empty() else -1
	hud.text = "\n".join([
		"EAGL Track Debug",
		"track: %s level%02d" % [track_name, level_index],
		"route nodes: %d unique comps: %d" % [route_node_count, route_comp_count],
		"render node: %d / %d" % [route_index, max(0, route_node_count - 1)],
		"route view: %s auto %s active comps: %s" % [view_label, str(auto_camera_route), str(active_compartments)],
		"projected boundary: node %d comp %d travel %s" % [progress_index, progress_comp, route_direction_label()],
		"hp2 window: boundary %d/comp%d preload %d/comp%d indices %s" % [route_boundary_index, boundary_comp, route_preload_index, preload_comp, str(active_route_indices)],
		"layer mode: %s frustum cull %s skipped meshes %d" % [layer_mode, str(route_frustum_culling), stats.frustum_culled_meshes],
		"textures: %d decoded images: %d skipped images: %d" % [stats.textures, stats.decoded_images, stats.skipped_images],
		"missing textures: %d skipped primitives: %s" % [stats.missing_textures, str(stats.skipped)],
		"camera: speed %.1f sens %.3f fov %.1f captured %s" % [camera.base_speed, camera.mouse_sensitivity, camera.fov, str(camera.is_captured())],
		"error: %s" % last_error if last_error != "" else "status: loaded",
		"",
		"RMB look | mouse wheel speed | Esc release | WASD move | Q/E down/up | Shift fast | Ctrl slow",
		"[/] route | C snap route | L layer mode | F frustum | R reload | H HUD"
	])
	if not speed_slider.has_focus():
		speed_slider.value = camera.base_speed

func _clear_world() -> int:
	var removed = world_root.get_child_count()
	for child in world_root.get_children():
		world_root.remove_child(child)
		child.queue_free()
	track_node = null
	return removed

func _place_camera() -> void:
	var bounds = _track_bounds()
	if bounds.size == Vector3.ZERO:
		camera.global_position = Vector3(0, 120, 250)
	else:
		camera.global_position = bounds.get_center() + Vector3(0, max(80.0, bounds.size.y + 80.0), max(180.0, bounds.size.z * 0.4))
	camera.look_at(bounds.get_center() if bounds.size != Vector3.ZERO else Vector3.ZERO)

func _track_bounds() -> AABB:
	var bounds = AABB()
	var found = false
	for mesh in world_root.find_children("*", "MeshInstance3D", true, false):
		if not mesh.is_visible_in_tree():
			continue
		var aabb: AABB = mesh.get_aabb()
		aabb = mesh.global_transform * aabb
		if not found:
			bounds = aabb
			found = true
		else:
			bounds = bounds.merge(aabb)
	return bounds if found else AABB()


func _wrapped_route_index(index: int) -> int:
	var count = loader.route.compartment_ids.size()
	if count <= 0:
		return 0
	return ((index % count) + count) % count


func _update_route_preload_index() -> void:
	if loader.route == null or loader.route.compartment_ids.is_empty():
		route_preload_index = -1
		return
	if _route_travel_direction > 0:
		route_preload_index = _wrapped_route_index(route_boundary_index + 1)
	elif _route_travel_direction < 0:
		route_preload_index = _wrapped_route_index(route_boundary_index - 1)
	else:
		route_preload_index = -1


func _route_render_index_from_boundary(boundary_index: int) -> int:
	if _route_travel_direction > 0:
		return _wrapped_route_index(boundary_index - 1)
	if _route_travel_direction < 0:
		return _wrapped_route_index(boundary_index + 1)
	return _wrapped_route_index(boundary_index)


func _limited_route_boundary_index_from(current_index: int, proposed_index: int) -> int:
	var delta = _wrapped_route_delta(current_index, proposed_index)
	if abs(delta) <= 1:
		return _wrapped_route_index(proposed_index)
	if _route_travel_direction > 0:
		return _wrapped_route_index(current_index + 1)
	if _route_travel_direction < 0:
		return _wrapped_route_index(current_index - 1)
	return current_index


func _wrapped_route_delta(from_index: int, to_index: int) -> int:
	var count = loader.route.compartment_ids.size()
	if count <= 0:
		return 0
	var delta = _wrapped_route_index(to_index) - _wrapped_route_index(from_index)
	if delta > count / 2:
		delta -= count
	elif delta < -count / 2:
		delta += count
	return delta


func _active_route_window_indices() -> Array[int]:
	var out: Array[int] = []
	if loader.route == null or loader.route.compartment_ids.is_empty():
		return out
	var radius = max(route_radius, 1)
	for offset in range(-radius, radius + 1):
		_append_unique_route_index(out, route_index + offset)
	if route_preload_index >= 0:
		_append_unique_route_index(out, route_preload_index)
	elif radius < 2:
		_append_unique_route_index(out, route_index - 1)
		_append_unique_route_index(out, route_index + 1)
	return out


func _all_route_indices() -> Array[int]:
	var out: Array[int] = []
	if loader.route == null:
		return out
	for index in range(loader.route.compartment_ids.size()):
		out.append(index)
	return out


func _append_unique_route_index(out: Array[int], index: int) -> void:
	var wrapped = _wrapped_route_index(index)
	if not out.has(wrapped):
		out.append(wrapped)
