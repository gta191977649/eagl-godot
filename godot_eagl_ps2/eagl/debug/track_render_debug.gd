extends Node3D

const PS2TextureBankScript := preload("res://eagl/assets/texture/ps2_texture_bank.gd")

@export var platform := "EAGL_HOTPUSUIT2_PS2"
@export_global_dir var game_root := "/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA"
@export var track_id := "61"
@export var load_on_ready := true
@export var place_scenery_instances := true
@export var expand_scenery_instances := false
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
var _loading_layer: CanvasLayer
var _loading_panel: PanelContainer
var _loading_label: Label
var _loading_bar: ProgressBar
@onready var camera: Camera3D = $DebugCamera


func _ready() -> void:
	_ensure_loading_ui()
	if load_on_ready:
		call_deferred("_load_debug_track")


func _load_debug_track() -> void:
	if _is_loading:
		return
	_is_loading = true
	if track_node != null:
		track_node.queue_free()
		track_node = null

	await _set_loading_status("Initializing EAGL", 0.05, true)

	var ok: bool = EAGLManager.initialize(platform, game_root, {
		"place_scenery_instances": place_scenery_instances,
		"expand_scenery_instances": expand_scenery_instances,
		"texture_filter_mode": texture_filter_mode,
	})
	if not ok:
		_is_loading = false
		await _set_loading_status("Failed: %s" % EAGLManager.last_error, 1.0, true)
		push_error(EAGLManager.last_error)
		return

	await _set_loading_status("Resolving TRACK%s bundle" % track_id, 0.15, true)
	var loader = EAGLManager.platform.track_loader
	var files: Dictionary = loader.resolver.resolve_track(track_id)
	if files.is_empty():
		_is_loading = false
		await _set_loading_status("Failed: %s" % loader.resolver.last_error, 1.0, true)
		push_error(loader.resolver.last_error)
		return

	await _set_loading_status("Parsing BUN mesh and scenery chunks", 0.35, true)
	var asset = loader.parser.parse(files)
	if asset == null:
		_is_loading = false
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
	track_node = loader.scene_builder.build_track_scene(asset, options)
	var stats: Dictionary = asset.summary()
	stats["from_cache"] = false
	stats["rendered_object_count"] = track_node.get_meta("eagl_rendered_object_count", 0)
	stats["placed_scenery_instance_count"] = track_node.get_meta("eagl_placed_scenery_instance_count", 0)
	stats["scenery_multimesh_count"] = track_node.get_meta("eagl_scenery_multimesh_count", 0)
	stats["environment_object_count"] = track_node.get_meta("eagl_environment_object_count", 0)
	stats["track_marker_count"] = track_node.get_meta("eagl_track_marker_count", 0)
	stats["skipped"] = track_node.get_meta("eagl_skipped", {})
	stats["textured_surface_count"] = track_node.get_meta("eagl_textured_surface_count", 0)
	stats["fallback_surface_count"] = track_node.get_meta("eagl_fallback_surface_count", 0)
	stats["uv_surface_count"] = track_node.get_meta("eagl_uv_surface_count", 0)
	stats["textured_missing_uv_surface_count"] = track_node.get_meta("eagl_textured_missing_uv_surface_count", 0)
	loader.stats = stats

	await _set_loading_status("Finalizing view", 0.95, true)
	add_child(track_node)
	_ensure_debug_lighting()
	_frame_camera(track_node)
	await _set_loading_status("Loaded TRACK%s" % files.get("track_id", track_id), 1.0, true)
	_hide_loading_ui_deferred()
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


func _ensure_loading_ui() -> void:
	if _loading_layer != null:
		return

	_loading_layer = CanvasLayer.new()
	_loading_layer.name = "LoadingOverlay"
	add_child(_loading_layer)

	var margin := MarginContainer.new()
	margin.name = "LoadingMargin"
	margin.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	margin.offset_left = 0.0
	margin.offset_top = -96.0
	margin.offset_right = 0.0
	margin.offset_bottom = -24.0
	_loading_layer.add_child(margin)

	_loading_panel = PanelContainer.new()
	_loading_panel.name = "LoadingPanel"
	_loading_panel.custom_minimum_size = Vector2(420.0, 0.0)
	_loading_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	margin.add_child(_loading_panel)

	var box := VBoxContainer.new()
	box.name = "LoadingBox"
	box.add_theme_constant_override("separation", 8)
	_loading_panel.add_child(box)

	_loading_label = Label.new()
	_loading_label.name = "LoadingLabel"
	_loading_label.text = "Idle"
	box.add_child(_loading_label)

	_loading_bar = ProgressBar.new()
	_loading_bar.name = "LoadingProgress"
	_loading_bar.min_value = 0.0
	_loading_bar.max_value = 100.0
	_loading_bar.value = 0.0
	_loading_bar.custom_minimum_size = Vector2(380.0, 18.0)
	box.add_child(_loading_bar)

	_loading_layer.visible = false


func _set_loading_status(message: String, progress: float, visible: bool = true) -> void:
	_ensure_loading_ui()
	_loading_layer.visible = visible
	_loading_label.text = message
	_loading_bar.value = clampf(progress, 0.0, 1.0) * 100.0
	print("EAGL load progress: %3.0f%% %s" % [_loading_bar.value, message])
	await get_tree().process_frame


func _hide_loading_ui_deferred() -> void:
	await get_tree().create_timer(0.35).timeout
	if _loading_layer != null:
		_loading_layer.visible = false


func _ensure_debug_lighting() -> void:
	if get_node_or_null("Sun") == null:
		var sun := DirectionalLight3D.new()
		sun.name = "Sun"
		sun.light_energy = 2.0
		sun.rotation_degrees = Vector3(-55.0, -35.0, 0.0)
		add_child(sun)

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
