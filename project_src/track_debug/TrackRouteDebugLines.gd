class_name TrackRouteDebugLines
extends Node3D

const ROUTE_COLOR = Color.RED
const AI_ROUTE_COLOR = Color(0.15, 0.7, 1.0, 1.0)

@export var height_offset = 8.0

var _last_key = ""
var _material: StandardMaterial3D
var _show_route_lines = true
var _show_ai_route_lines = true


func _ready() -> void:
	_material = _make_material()
	_connect_toggle()
	_reload_if_needed()


func _process(_delta: float) -> void:
	_reload_if_needed()


func _reload_if_needed() -> void:
	var debug = get_parent()
	if debug == null:
		return
	var key = "%s:%s:%d" % [debug.tracks_root, debug.track_name, debug.level_index]
	if key == _last_key:
		_apply_visibility()
		return
	_last_key = key
	_rebuild(debug)


func _rebuild(debug) -> void:
	_clear()
	var route_points = _offset_points(debug.loader.route.route_points)
	if route_points.size() > 1:
		add_child(_line_node("level_route", route_points, ROUTE_COLOR))
	var ai_segments = _offset_segments(debug.loader.route.ai_route_segments)
	if not ai_segments.is_empty():
		add_child(_segments_node("ai_route", ai_segments, AI_ROUTE_COLOR))
	_apply_visibility()


func _offset_points(points: PackedVector3Array) -> PackedVector3Array:
	var out = PackedVector3Array()
	for point in points:
		out.append(point + Vector3(0.0, height_offset, 0.0))
	return out


func _offset_segments(segments: Array[PackedVector3Array]) -> Array[PackedVector3Array]:
	var out: Array[PackedVector3Array] = []
	for segment in segments:
		var points = _offset_points(segment)
		if points.size() > 1:
			out.append(points)
	return out


func _line_node(node_name: String, points: PackedVector3Array, color: Color) -> MeshInstance3D:
	return _segments_node(node_name, [points], color)


func _segments_node(node_name: String, segments: Array[PackedVector3Array], color: Color) -> MeshInstance3D:
	var vertices = PackedVector3Array()
	var colors = PackedColorArray()
	for points in segments:
		for index in range(points.size() - 1):
			vertices.append(points[index])
			vertices.append(points[index + 1])
			colors.append(color)
			colors.append(color)
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_COLOR] = colors
	var mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	mesh.surface_set_material(0, _material)
	var node = MeshInstance3D.new()
	node.name = node_name
	node.mesh = mesh
	return node


func _connect_toggle() -> void:
	var route_checkbox = get_node_or_null("../DebugHud/SelectPanel/VBox/RouteLines")
	if route_checkbox != null:
		_show_route_lines = route_checkbox.button_pressed
		route_checkbox.toggled.connect(func(enabled):
			_show_route_lines = enabled
			_apply_visibility()
		)
	var ai_checkbox = get_node_or_null("../DebugHud/SelectPanel/VBox/AIRouteLines")
	if ai_checkbox != null:
		_show_ai_route_lines = ai_checkbox.button_pressed
		ai_checkbox.toggled.connect(func(enabled):
			_show_ai_route_lines = enabled
			_apply_visibility()
		)
	_apply_visibility()


func _apply_visibility() -> void:
	var route_node = get_node_or_null("level_route")
	if route_node != null:
		route_node.visible = _show_route_lines
	var ai_node = get_node_or_null("ai_route")
	if ai_node != null:
		ai_node.visible = _show_ai_route_lines


func _make_material() -> StandardMaterial3D:
	var material = StandardMaterial3D.new()
	material.resource_name = "EAGL route debug lines"
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.no_depth_test = true
	return material


func _clear() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
