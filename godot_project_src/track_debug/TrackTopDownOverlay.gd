class_name TrackTopDownOverlay
extends Control

const PANEL_COLOR = Color(0.02, 0.02, 0.02, 0.72)
const ROUTE_COLOR = Color(1.0, 0.12, 0.08, 0.95)
const AI_ROUTE_COLOR = Color(0.15, 0.7, 1.0, 0.9)
const INACTIVE_ZONE_COLOR = Color(0.0, 0.35, 1.0, 0.85)
const ACTIVE_ZONE_COLOR = Color(0.0, 1.0, 0.2, 0.95)
const CURRENT_ZONE_COLOR = Color(1.0, 0.9, 0.0, 1.0)
const CURRENT_ZONE_OVERLAY_COLOR = Color(1.0, 0.9, 0.0, 0.35)
const PRELOAD_ZONE_COLOR = Color(1.0, 0.55, 0.0, 1.0)
const DIRECTION_ARROW_COLOR = Color(1.0, 1.0, 0.15, 1.0)
const CAMERA_COLOR = Color(0.2, 0.7, 1.0, 1.0)
const PROJECTED_CAMERA_COLOR = Color(1.0, 1.0, 1.0, 1.0)
const TEXT_COLOR = Color(0.92, 0.92, 0.92, 1.0)
const TOP_LABEL_HEIGHT = 78.0
const LEGEND_WIDTH = 190.0
const LABEL_FONT_SIZE = 18
const RENDER_MARKER_HALF_SIZE = 45.0

@export var padding = 18.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	var debug = _debug_node()
	if debug == null or debug.loader == null or debug.loader.route.route_points.is_empty():
		return
	draw_rect(Rect2(Vector2.ZERO, size), PANEL_COLOR, true)
	var world_rect = _world_rect(debug)
	if world_rect.size.x <= 0.0 or world_rect.size.y <= 0.0:
		return
	_draw_route(debug, world_rect)
	_draw_ai_route(debug, world_rect)
	_draw_active_zones(debug, world_rect)
	_draw_current_and_camera(debug, world_rect)
	_draw_direction_arrow(debug, world_rect)
	_draw_label(debug)
	_draw_legend()


func _debug_node():
	var parent = get_parent()
	return parent.get_parent() if parent != null else null


func _world_rect(debug) -> Rect2:
	var found = false
	var rect = Rect2()
	for point in debug.loader.route.route_points:
		rect = _include_point(rect, Vector2(point.x, point.z), found)
		found = true
	if debug.show_ai_route_lines:
		for point in debug.loader.route.ai_route_points:
			rect = _include_point(rect, Vector2(point.x, point.z), found)
			found = true
	for route_index in range(debug.loader.route.compartment_ids.size()):
		var center = debug.loader.route.route_position_for_index(route_index)
		for point in _marker_corners(Vector2(center.x, center.z)):
			rect = _include_point(rect, point, found)
			found = true
	if not found:
		return Rect2()
	rect = rect.grow(max(rect.size.x, rect.size.y) * 0.05 + 1.0)
	return rect


func _include_point(rect: Rect2, point: Vector2, found: bool) -> Rect2:
	if not found:
		return Rect2(point, Vector2.ZERO)
	return rect.expand(point)


func _draw_route(debug, world_rect: Rect2) -> void:
	var points = debug.loader.route.route_points
	for index in range(points.size() - 1):
		draw_line(_to_overlay(Vector2(points[index].x, points[index].z), world_rect), _to_overlay(Vector2(points[index + 1].x, points[index + 1].z), world_rect), ROUTE_COLOR, 3.0)


func _draw_ai_route(debug, world_rect: Rect2) -> void:
	if not debug.show_ai_route_lines:
		return
	for segment in debug.loader.route.ai_route_segments:
		for index in range(segment.size() - 1):
			draw_line(_to_overlay(Vector2(segment[index].x, segment[index].z), world_rect), _to_overlay(Vector2(segment[index + 1].x, segment[index + 1].z), world_rect), AI_ROUTE_COLOR, 2.0)


func _draw_active_zones(debug, world_rect: Rect2) -> void:
	if debug.loader.route.compartment_ids.is_empty():
		return
	for route_index in range(debug.loader.route.compartment_ids.size()):
		var center = debug.loader.route.route_position_for_index(route_index)
		if center == Vector3.ZERO and debug.loader.route.route_points.is_empty():
			continue
		var min_point = _to_overlay(Vector2(center.x - RENDER_MARKER_HALF_SIZE, center.z - RENDER_MARKER_HALF_SIZE), world_rect)
		var max_point = _to_overlay(Vector2(center.x + RENDER_MARKER_HALF_SIZE, center.z + RENDER_MARKER_HALF_SIZE), world_rect)
		var rect = Rect2(min_point, max_point - min_point).abs()
		var is_current_node = route_index == debug.route_boundary_index
		var is_active_node = debug.active_route_indices.has(route_index)
		var color = INACTIVE_ZONE_COLOR
		if is_active_node:
			color = ACTIVE_ZONE_COLOR
		if is_current_node:
			color = CURRENT_ZONE_COLOR
		if is_current_node:
			draw_rect(rect, CURRENT_ZONE_OVERLAY_COLOR, true)
		draw_rect(rect, color, false, 3.0)
		var label = "current %d" % route_index if is_current_node else str(route_index)
		_draw_node_number_left(label, rect, color)


func _draw_current_and_camera(debug, world_rect: Rect2) -> void:
	var render_pos = debug.loader.route.route_position_for_index(debug.route_index)
	var render_node = _to_overlay(Vector2(render_pos.x, render_pos.z), world_rect)
	var boundary_pos = debug.loader.route.route_position_for_index(debug.route_boundary_index)
	var boundary = _to_overlay(Vector2(boundary_pos.x, boundary_pos.z), world_rect)
	var projected = debug.route_probe_position()
	draw_circle(render_node, 6.0, ACTIVE_ZONE_COLOR)
	draw_circle(boundary, 8.0, CURRENT_ZONE_COLOR)
	if debug.route_preload_index >= 0:
		var preload_pos = debug.loader.route.route_position_for_index(debug.route_preload_index)
		draw_circle(_to_overlay(Vector2(preload_pos.x, preload_pos.z), world_rect), 6.0, PRELOAD_ZONE_COLOR)
	draw_circle(_to_overlay(Vector2(projected.x, projected.z), world_rect), 6.0, PROJECTED_CAMERA_COLOR)
	draw_circle(_to_overlay(Vector2(debug.camera.global_position.x, debug.camera.global_position.z), world_rect), 6.0, CAMERA_COLOR)


func _draw_direction_arrow(debug, world_rect: Rect2) -> void:
	var projected = debug.route_probe_position()
	var status = debug.route_direction_label()
	var direction = 0
	if status == "forward":
		direction = 1
	elif status == "reverse":
		direction = -1
	if direction == 0:
		var position = _to_overlay(Vector2(projected.x, projected.z), world_rect)
		_draw_text("direction unknown", position + Vector2(10.0, -10.0), DIRECTION_ARROW_COLOR)
		return
	var distance_along = debug.loader.route.route_distance_along(debug.camera.global_position)
	var tangent = debug.loader.route.route_tangent_at_distance(distance_along) * float(direction)
	var tangent_2d = Vector2(tangent.x, tangent.z)
	if tangent_2d.length_squared() <= 0.000001:
		return
	tangent_2d = tangent_2d.normalized()
	var start = _to_overlay(Vector2(projected.x, projected.z), world_rect)
	var length = 34.0
	var end = start + Vector2(tangent_2d.x, -tangent_2d.y) * length
	var side = Vector2(-tangent_2d.y, -tangent_2d.x)
	draw_line(start, end, DIRECTION_ARROW_COLOR, 4.0)
	draw_line(end, end - Vector2(tangent_2d.x, -tangent_2d.y) * 11.0 + side * 7.0, DIRECTION_ARROW_COLOR, 4.0)
	draw_line(end, end - Vector2(tangent_2d.x, -tangent_2d.y) * 11.0 - side * 7.0, DIRECTION_ARROW_COLOR, 4.0)
	_draw_text("direction " + status, end + Vector2(8.0, -8.0), DIRECTION_ARROW_COLOR)


func _draw_label(debug) -> void:
	var current_comp = debug.loader.route.compartment_ids[debug.route_index] if not debug.loader.route.compartment_ids.is_empty() else -1
	var progress_index = debug.route_progress_index()
	var progress_comp = debug.loader.route.compartment_ids[progress_index] if progress_index != -1 else -1
	var preload_comp = debug.loader.route.compartment_ids[debug.route_preload_index] if debug.route_preload_index >= 0 and not debug.loader.route.compartment_ids.is_empty() else -1
	var camera_pos = debug.camera.global_position
	_draw_text("%s level%02d direction %s" % [debug.track_name, debug.level_index, debug.route_direction_label()], Vector2(12.0, 22.0), TEXT_COLOR)
	_draw_text("render node %d comp %d active %s" % [debug.route_index, current_comp, str(debug.active_compartments)], Vector2(12.0, 44.0), TEXT_COLOR)
	_draw_text("boundary %d comp %d preload %d comp %d travel %s" % [progress_index, progress_comp, debug.route_preload_index, preload_comp, debug.route_direction_label()], Vector2(12.0, 66.0), TEXT_COLOR)
	_draw_text("camera xyz %.1f %.1f %.1f" % [camera_pos.x, camera_pos.y, camera_pos.z], Vector2(12.0, 88.0), TEXT_COLOR)


func _draw_legend() -> void:
	var x = size.x - LEGEND_WIDTH + 12.0
	var y = TOP_LABEL_HEIGHT + padding
	_draw_legend_line(Vector2(x, y), ROUTE_COLOR, "route path")
	_draw_legend_line(Vector2(x, y + 24.0), AI_ROUTE_COLOR, "AI route")
	_draw_legend_box(Vector2(x, y + 48.0), INACTIVE_ZONE_COLOR, "inactive node")
	_draw_legend_box(Vector2(x, y + 72.0), ACTIVE_ZONE_COLOR, "active node")
	_draw_legend_box(Vector2(x, y + 96.0), CURRENT_ZONE_COLOR, "current node")
	_draw_legend_dot(Vector2(x + 10.0, y + 124.0), CURRENT_ZONE_COLOR, "current node")
	_draw_legend_dot(Vector2(x + 10.0, y + 148.0), PRELOAD_ZONE_COLOR, "preload side")
	_draw_legend_line(Vector2(x, y + 172.0), DIRECTION_ARROW_COLOR, "direction")
	_draw_legend_dot(Vector2(x + 10.0, y + 196.0), CAMERA_COLOR, "camera")
	_draw_legend_dot(Vector2(x + 10.0, y + 220.0), PROJECTED_CAMERA_COLOR, "projected camera")


func _draw_legend_line(position: Vector2, color: Color, label: String) -> void:
	draw_line(position, position + Vector2(26.0, 0.0), color, 3.0)
	_draw_text(label, position + Vector2(34.0, 7.0), TEXT_COLOR)


func _draw_legend_box(position: Vector2, color: Color, label: String) -> void:
	draw_rect(Rect2(position, Vector2(22.0, 14.0)), color, false, 3.0)
	_draw_text(label, position + Vector2(34.0, 14.0), TEXT_COLOR)


func _draw_legend_dot(position: Vector2, color: Color, label: String) -> void:
	draw_circle(position, 6.0, color)
	_draw_text(label, position + Vector2(24.0, 7.0), TEXT_COLOR)


func _marker_corners(center: Vector2) -> Array[Vector2]:
	return [
		center + Vector2(-RENDER_MARKER_HALF_SIZE, -RENDER_MARKER_HALF_SIZE),
		center + Vector2(RENDER_MARKER_HALF_SIZE, -RENDER_MARKER_HALF_SIZE),
		center + Vector2(RENDER_MARKER_HALF_SIZE, RENDER_MARKER_HALF_SIZE),
		center + Vector2(-RENDER_MARKER_HALF_SIZE, RENDER_MARKER_HALF_SIZE)
	]


func _to_overlay(point: Vector2, world_rect: Rect2) -> Vector2:
	var map_rect = _map_area()
	var usable = Vector2(max(1.0, map_rect.size.x), max(1.0, map_rect.size.y))
	var scale = min(usable.x / max(1.0, world_rect.size.x), usable.y / max(1.0, world_rect.size.y))
	var used = world_rect.size * scale
	var origin = map_rect.position + (map_rect.size - used) * 0.5
	var local = (point - world_rect.position) * scale
	return Vector2(origin.x + local.x, origin.y + used.y - local.y)


func _map_area() -> Rect2:
	var top = TOP_LABEL_HEIGHT + padding
	return Rect2(
		Vector2(padding, top),
		Vector2(max(1.0, size.x - LEGEND_WIDTH - padding * 2.0), max(1.0, size.y - top - padding))
	)


func _draw_text(text: String, position: Vector2, color: Color) -> void:
	var font = get_theme_default_font()
	draw_string(font, position, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, LABEL_FONT_SIZE, color)


func _draw_node_number_left(text: String, rect: Rect2, color: Color) -> void:
	var font = get_theme_default_font()
	var label_size = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, LABEL_FONT_SIZE)
	var position = Vector2(rect.position.x - label_size.x - 6.0, rect.position.y + 18.0)
	_draw_text(text, position, color)
