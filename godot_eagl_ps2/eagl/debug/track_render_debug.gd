extends Node3D

const PS2TextureBankScript := preload("res://eagl/assets/texture/ps2_texture_bank.gd")

@export var platform := "EAGL_HOTPUSUIT2_PS2"
@export_global_dir var game_root := "/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA"
@export var track_id := "31"
@export var load_on_ready := true
@export var place_scenery_instances := true
@export var expand_scenery_instances := false
@export var cast_shadow := false
@export_enum(
	"linear_mipmap",
	"linear",
	"nearest_mipmap",
	"nearest",
	"linear_mipmap_anisotropic",
	"nearest_mipmap_anisotropic"
) var texture_filter_mode := "linear_mipmap"

var track_node: Node3D
var _is_loading := false
@onready var camera: Camera3D = $DebugCamera
@onready var _loading_panel: PanelContainer = $DebugUI/DebugUILayout/SafeMargin/VerticalBands/BottomControls/LoadingPanel
@onready var _loading_label: Label = $DebugUI/DebugUILayout/SafeMargin/VerticalBands/BottomControls/LoadingPanel/LoadingBox/LoadingLabel
@onready var _loading_bar: ProgressBar = $DebugUI/DebugUILayout/SafeMargin/VerticalBands/BottomControls/LoadingPanel/LoadingBox/LoadingProgress
@onready var _track_selector: OptionButton = $DebugUI/DebugUILayout/SafeMargin/VerticalBands/TopControls/TrackSelectPanel/TrackSelectFlow/TrackSelector
@onready var _reload_button: Button = $DebugUI/DebugUILayout/SafeMargin/VerticalBands/TopControls/TrackSelectPanel/TrackSelectFlow/ReloadTrack
@onready var _track_status_label: Label = $DebugUI/DebugUILayout/SafeMargin/VerticalBands/TopControls/TrackSelectPanel/TrackSelectFlow/TrackStatus
@onready var _cast_shadow_toggle: CheckButton = $DebugUI/DebugUILayout/SafeMargin/VerticalBands/TopControls/RenderDebugPanel/RenderDebugFlow/CastShadowToggle
@onready var _camera_position_label: Label = $DebugUI/DebugUILayout/CameraPositionPanel/CameraPositionLabel


func _ready() -> void:
	_loading_panel.visible = false
	_track_selector.item_selected.connect(_on_track_selected)
	_reload_button.pressed.connect(reload_track)
	_cast_shadow_toggle.button_pressed = cast_shadow
	_cast_shadow_toggle.toggled.connect(_on_cast_shadow_toggled)
	_populate_track_selector()
	if load_on_ready:
		call_deferred("_load_debug_track")


func _process(_delta: float) -> void:
	_update_camera_position_label()


func _load_debug_track() -> void:
	if _is_loading:
		return
	_is_loading = true
	_set_track_controls_enabled(false)

	await _set_loading_status("Initializing EAGL", 0.05, true)

	var ok: bool = EAGLManager.initialize(platform, game_root, {
		"place_scenery_instances": place_scenery_instances,
		"expand_scenery_instances": expand_scenery_instances,
		"texture_filter_mode": texture_filter_mode,
	})
	if not ok:
		_is_loading = false
		_set_track_controls_enabled(true)
		await _set_loading_status("Failed: %s" % EAGLManager.last_error, 1.0, true)
		push_error(EAGLManager.last_error)
		return

	await _set_loading_status("Resolving %s bundle" % _track_display_name(track_id), 0.15, true)
	var loader = EAGLManager.platform.track_loader
	var files: Dictionary = loader.resolver.resolve_track(track_id)
	if files.is_empty():
		_is_loading = false
		_set_track_controls_enabled(true)
		await _set_loading_status("Failed: %s" % loader.resolver.last_error, 1.0, true)
		push_error(loader.resolver.last_error)
		return

	await _set_loading_status("Parsing BUN mesh and scenery chunks", 0.35, true)
	var asset = loader.parser.parse(files)
	if asset == null:
		_is_loading = false
		_set_track_controls_enabled(true)
		await _set_loading_status("Failed: parser returned no asset", 1.0, true)
		push_error("Track parser returned no asset")
		return

	await _set_loading_status("Decoding PS2 textures and generating mipmaps", 0.60, true)
	asset.texture_bank = PS2TextureBankScript.new()
	asset.texture_bank.load_for_track(files)
	for message in asset.texture_bank.errors:
		asset.add_warning(message)

	await _set_loading_status("Building Godot scene instances", 0.82, true)
	var options := {}
	if loader.resolver != null and loader.resolver.config != null:
		options = loader.resolver.config.options
	var next_track_node: Node3D = loader.scene_builder.build_track_scene(asset, options)
	var stats: Dictionary = asset.summary()
	stats["from_cache"] = false
	stats["rendered_object_count"] = next_track_node.get_meta("eagl_rendered_object_count", 0)
	stats["placed_scenery_instance_count"] = next_track_node.get_meta("eagl_placed_scenery_instance_count", 0)
	stats["scenery_multimesh_count"] = next_track_node.get_meta("eagl_scenery_multimesh_count", 0)
	stats["environment_object_count"] = next_track_node.get_meta("eagl_environment_object_count", 0)
	stats["track_marker_count"] = next_track_node.get_meta("eagl_track_marker_count", 0)
	stats["skipped"] = next_track_node.get_meta("eagl_skipped", {})
	stats["textured_surface_count"] = next_track_node.get_meta("eagl_textured_surface_count", 0)
	stats["fallback_surface_count"] = next_track_node.get_meta("eagl_fallback_surface_count", 0)
	stats["uv_surface_count"] = next_track_node.get_meta("eagl_uv_surface_count", 0)
	stats["textured_missing_uv_surface_count"] = next_track_node.get_meta("eagl_textured_missing_uv_surface_count", 0)
	loader.stats = stats

	await _set_loading_status("Finalizing view", 0.95, true)
	_replace_track_node(next_track_node)
	_ensure_debug_lighting()
	_apply_cast_shadow()
	_frame_camera(track_node)
	await _set_loading_status("Loaded TRACK%s" % files.get("track_id", track_id), 1.0, true)
	_hide_loading_ui_deferred()
	_sync_track_selector_to_current()
	_set_track_controls_enabled(true)
	_is_loading = false
	print("EAGL debug track loaded: ", EAGLManager.get_stats())
	print("EAGL debug scene rendered: objects=%s placed_scenery=%s scenery_multimeshes=%s environment=%s markers=%s textured_surfaces=%s fallback_surfaces=%s uv_surfaces=%s textured_missing_uv=%s skipped=%s" % [
		track_node.get_meta("eagl_rendered_object_count", 0),
		track_node.get_meta("eagl_placed_scenery_instance_count", 0),
		track_node.get_meta("eagl_scenery_multimesh_count", 0),
		track_node.get_meta("eagl_environment_object_count", 0),
		track_node.get_meta("eagl_track_marker_count", 0),
		track_node.get_meta("eagl_textured_surface_count", 0),
		track_node.get_meta("eagl_fallback_surface_count", 0),
		track_node.get_meta("eagl_uv_surface_count", 0),
		track_node.get_meta("eagl_textured_missing_uv_surface_count", 0),
		track_node.get_meta("eagl_skipped", {}),
	])


func reload_track() -> void:
	_load_debug_track()


func _populate_track_selector() -> void:
	if _track_selector == null:
		return
	_track_selector.clear()

	var tracks := _available_track_ids()
	if tracks.is_empty():
		tracks.append(_track_display_name(track_id))

	for index in range(tracks.size()):
		var source_id: String = tracks[index]
		_track_selector.add_item(source_id)
		_track_selector.set_item_metadata(index, source_id)

	_sync_track_selector_to_current()


func _available_track_ids() -> Array[String]:
	var tracks_dir := _resolve_tracks_dir(game_root)
	if tracks_dir == "":
		return []

	var dir := DirAccess.open(tracks_dir)
	if dir == null:
		return []

	var seen := {}
	dir.list_dir_begin()
	while true:
		var file_name := dir.get_next()
		if file_name == "":
			break
		if dir.current_is_dir():
			continue
		var path := tracks_dir.path_join(file_name)
		if not _file_has_data(path):
			continue
		var upper := file_name.to_upper()
		var ext := upper.get_extension()
		if ext != "BUN" and ext != "LZC":
			continue
		var stem := upper.get_basename()
		if not stem.begins_with("TRACKA") and not stem.begins_with("TRACKB"):
			continue
		if stem.length() < 8:
			continue
		seen[stem] = true
	dir.list_dir_end()

	var out: Array[String] = []
	for key in seen.keys():
		out.append(String(key))
	out.sort()
	return out


func _resolve_tracks_dir(root: String) -> String:
	var normalized := root.trim_suffix("/")
	var candidates := [
		normalized.path_join("ZZDATA").path_join("TRACKS"),
		normalized.path_join("TRACKS"),
		normalized,
	]
	for candidate in candidates:
		if DirAccess.dir_exists_absolute(candidate):
			if candidate.get_file().to_upper() == "TRACKS":
				return candidate
			if DirAccess.dir_exists_absolute(candidate.path_join("TRACKS")):
				return candidate.path_join("TRACKS")
	return ""


func _file_has_data(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	return file.get_length() > 0


func _sync_track_selector_to_current() -> void:
	if _track_selector == null:
		return
	var current := _track_display_name(track_id)
	for index in range(_track_selector.item_count):
		var source_id := String(_track_selector.get_item_metadata(index))
		if source_id == current or _track_numeric_id(source_id) == _track_numeric_id(current):
			_track_selector.select(index)
			if _track_status_label != null:
				_track_status_label.text = _track_numeric_id(source_id)
			return


func _on_track_selected(index: int) -> void:
	if _is_loading or _track_selector == null:
		return
	var source_id := String(_track_selector.get_item_metadata(index))
	if source_id == "":
		return
	if source_id == _track_display_name(track_id):
		return
	track_id = source_id
	if _track_status_label != null:
		_track_status_label.text = _track_numeric_id(source_id)
	_load_debug_track()


func _on_cast_shadow_toggled(enabled: bool) -> void:
	cast_shadow = enabled
	_apply_cast_shadow()


func _apply_cast_shadow() -> void:
	if track_node == null:
		return
	for node in track_node.find_children("EAGL_Sun", "DirectionalLight3D", true, false):
		var light := node as DirectionalLight3D
		if light == null:
			continue
		if not light.has_meta("eagl_enabled_light_energy"):
			light.set_meta("eagl_enabled_light_energy", light.light_energy)
		light.shadow_enabled = cast_shadow
		light.light_energy = float(light.get_meta("eagl_enabled_light_energy", light.light_energy)) if cast_shadow else 0.0
		light.visible = cast_shadow


func _set_track_controls_enabled(enabled: bool) -> void:
	if _track_selector != null:
		_track_selector.disabled = not enabled


func _replace_track_node(next_track_node: Node3D) -> void:
	var previous_track_node := track_node
	if previous_track_node != null and is_instance_valid(previous_track_node):
		if previous_track_node.get_parent() != null:
			previous_track_node.get_parent().remove_child(previous_track_node)
		previous_track_node.queue_free()

	track_node = next_track_node
	track_node.name = "TrackRoot"
	track_node.visible = true
	track_node.transform = Transform3D.IDENTITY
	add_child(track_node)
	move_child(track_node, 0)
	track_node.propagate_call("set_visible", [true])
	track_node.force_update_transform()


func _track_display_name(value: String) -> String:
	var upper := value.strip_edges().to_upper()
	if upper.begins_with("TRACKA") or upper.begins_with("TRACKB"):
		return upper
	if upper.begins_with("A") and upper.length() >= 2:
		return "TRACKA%s" % _track_numeric_id(upper)
	return "TRACKB%s" % _track_numeric_id(upper)


func _track_numeric_id(value: String) -> String:
	var digits := ""
	for i in range(value.length()):
		var ch := value.substr(i, 1)
		if ch >= "0" and ch <= "9":
			digits += ch
	if digits == "":
		digits = "61"
	if digits.length() == 1:
		digits = "0%s" % digits
	elif digits.length() > 2:
		digits = digits.substr(digits.length() - 2)
	return digits


func _set_loading_status(message: String, progress: float, visible: bool = true) -> void:
	_loading_panel.visible = visible
	_loading_label.text = message
	_loading_bar.value = clampf(progress, 0.0, 1.0) * 100.0
	print("EAGL load progress: %3.0f%% %s" % [_loading_bar.value, message])
	await get_tree().process_frame


func _hide_loading_ui_deferred() -> void:
	await get_tree().create_timer(0.35).timeout
	if _loading_panel != null:
		_loading_panel.visible = false


func _ensure_debug_lighting() -> void:
	var legacy_sun := get_node_or_null("Sun")
	if legacy_sun is DirectionalLight3D:
		(legacy_sun as DirectionalLight3D).visible = false

	if camera == null:
		push_warning("DebugCamera node is missing from the track debug scene")
		return
	camera.current = true


func _frame_camera(node: Node3D) -> void:
	if camera == null:
		return
	var bounds := _node_bounds(node)
	if bounds.size == Vector3.ZERO:
		camera.position = Vector3(0.0, 80.0, 180.0)
		_look_at_with_free_camera(Vector3.ZERO)
		return

	var center := bounds.get_center()
	var max_size: float = maxf(bounds.size.x, maxf(bounds.size.y, bounds.size.z))
	var distance: float = maxf(max_size * 0.95, 80.0)
	camera.position = center + Vector3(0.0, distance * 0.55, distance)
	camera.far = max(distance * 5.0, 4000.0)
	camera.near = 0.1
	_look_at_with_free_camera(center)


func _look_at_with_free_camera(target: Vector3) -> void:
	if camera != null and camera.has_method("look_at_target"):
		camera.call("look_at_target", target)
	elif camera != null:
		camera.look_at(target, Vector3.UP)


func _update_camera_position_label() -> void:
	if _camera_position_label == null or camera == null:
		return
	var pos := camera.global_position
	_camera_position_label.text = "Camera\nX: %.2f\nY: %.2f\nZ: %.2f" % [pos.x, pos.y, pos.z]


func _node_bounds(node: Node3D) -> AABB:
	var bounds := AABB()
	var found := false
	for mesh in node.find_children("*", "MeshInstance3D", true, false):
		var mesh_node := mesh as MeshInstance3D
		if mesh_node == null:
			continue
		var mesh_aabb := mesh_node.get_aabb()
		if mesh_aabb.size == Vector3.ZERO:
			continue
		mesh_aabb = mesh_node.global_transform * mesh_aabb
		if not found:
			bounds = mesh_aabb
			found = true
		else:
			bounds = bounds.merge(mesh_aabb)
	return bounds if found else AABB()
