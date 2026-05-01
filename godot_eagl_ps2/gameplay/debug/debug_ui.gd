extends CanvasLayer

const RENDER_DEBUG_WINDOW_SIZE := Vector2(320.0, 184.0)

var _render_debug_window_open := false
var _render_collision_enabled := false
var _render_route_enabled := false
var _render_drive_area_enabled := false
var _pending_render_collision_apply := false
var _pending_render_route_apply := false
var _pending_render_drive_area_apply := false

@onready var _debug_label: Label = $DebugInfoLabel


func _ready() -> void:
	set_debug_info("", "")


func _process(_delta: float) -> void:
	_draw_imgui()
	if _pending_render_collision_apply:
		_apply_render_collision()
	if _pending_render_route_apply:
		_apply_render_route()
	if _pending_render_drive_area_apply:
		_apply_render_drive_area()


func set_debug_info(track_name: String, camera_mode_name: String) -> void:
	if _debug_label == null:
		return
	_debug_label.text = "Track: %s\nCamera: %s" % [
		track_name,
		camera_mode_name,
	]


func _draw_imgui() -> void:
	if ImGui.BeginMainMenuBar():
		if ImGui.BeginMenu("Scene"):
			ImGui.MenuItem("Scene")
			ImGui.EndMenu()

		if ImGui.BeginMenu("Render"):
			if ImGui.MenuItem("Render Debug"):
				_render_debug_window_open = true
			ImGui.EndMenu()

		if ImGui.BeginMenu("About"):
			ImGui.MenuItem("About")
			ImGui.EndMenu()

		ImGui.EndMainMenuBar()

	_draw_render_debug_window()


func _draw_render_debug_window() -> void:
	if not _render_debug_window_open:
		return

	ImGui.SetNextWindowSize(RENDER_DEBUG_WINDOW_SIZE, ImGui.Cond_Once)
	var open_ref := [_render_debug_window_open]
	ImGui.Begin("Render Debug", open_ref)

	var collision_ref := [_render_collision_enabled]
	if ImGui.Checkbox("Render Collision", collision_ref):
		_set_render_collision_enabled(bool(collision_ref[0]))
	var route_ref := [_render_route_enabled]
	if ImGui.Checkbox("Render Route", route_ref):
		_set_render_route_enabled(bool(route_ref[0]))
	var drive_area_ref := [_render_drive_area_enabled]
	if ImGui.Checkbox("Render Drive Area", drive_area_ref):
		_set_render_drive_area_enabled(bool(drive_area_ref[0]))

	ImGui.End()
	_render_debug_window_open = bool(open_ref[0])


func _set_render_collision_enabled(enabled: bool) -> void:
	if _render_collision_enabled == enabled and not _pending_render_collision_apply:
		return
	_render_collision_enabled = enabled
	_pending_render_collision_apply = true
	_apply_render_collision()


func _set_render_route_enabled(enabled: bool) -> void:
	if _render_route_enabled == enabled and not _pending_render_route_apply:
		return
	_render_route_enabled = enabled
	_pending_render_route_apply = true
	_apply_render_route()


func _set_render_drive_area_enabled(enabled: bool) -> void:
	if _render_drive_area_enabled == enabled and not _pending_render_drive_area_apply:
		return
	_render_drive_area_enabled = enabled
	_pending_render_drive_area_apply = true
	_apply_render_drive_area()


func _apply_render_collision() -> void:
	var track := _find_track_debug_target()
	if track == null:
		return

	if track.has_method("set_collision_debug_visible"):
		track.call("set_collision_debug_visible", _render_collision_enabled)
	else:
		_set_collision_debug_overlay_visible(track, _render_collision_enabled)

	_pending_render_collision_apply = false


func _apply_render_route() -> void:
	var track := _find_track_debug_target()
	if track == null:
		return

	if track.has_method("set_route_debug_visible"):
		track.call("set_route_debug_visible", _render_route_enabled)
	else:
		_set_route_debug_overlay_visible(track, _render_route_enabled)

	_pending_render_route_apply = false


func _apply_render_drive_area() -> void:
	var track := _find_track_debug_target()
	if track == null:
		return

	if track.has_method("set_drive_area_debug_visible"):
		track.call("set_drive_area_debug_visible", _render_drive_area_enabled)
	else:
		_set_drive_area_debug_overlay_visible(track, _render_drive_area_enabled)

	_pending_render_drive_area_apply = false


func _find_track_debug_target() -> Node:
	var parent := get_parent()
	if parent != null:
		var sibling_track := parent.get_node_or_null("Track")
		if sibling_track != null:
			return sibling_track
		if _is_track_debug_target(parent):
			return parent

	var scene := get_tree().current_scene
	if scene == null:
		return null
	if _is_track_debug_target(scene):
		return scene
	return scene.find_child("Track", true, false)


func _is_track_debug_target(node: Node) -> bool:
	return (
		node.has_method("set_collision_debug_visible")
		or node.has_method("set_route_debug_visible")
		or node.has_method("set_drive_area_debug_visible")
		or node.has_meta("eagl_collision_enabled")
		or node.has_meta("eagl_route_enabled")
	)


func _set_collision_debug_overlay_visible(root: Node, visible: bool) -> void:
	for node in root.find_children("*", "MeshInstance3D", true, false):
		if bool(node.get_meta("eagl_collision_debug_overlay", false)) and not _is_drive_area_overlay(node):
			node.visible = visible


func _set_route_debug_overlay_visible(root: Node, visible: bool) -> void:
	for node in root.find_children("*", "GeometryInstance3D", true, false):
		if bool(node.get_meta("eagl_route_debug_overlay", false)):
			node.visible = visible


func _set_drive_area_debug_overlay_visible(root: Node, visible: bool) -> void:
	for node in root.find_children("*", "MeshInstance3D", true, false):
		if _is_drive_area_overlay(node):
			node.visible = visible


func _is_drive_area_overlay(node: Node) -> bool:
	return (
		bool(node.get_meta("eagl_collision_debug_overlay", false))
		and String(node.get_meta("eagl_collision_category", "")) == "DriveArea"
	)
