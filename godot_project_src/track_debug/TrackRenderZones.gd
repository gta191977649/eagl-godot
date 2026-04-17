class_name TrackRenderZones
extends Node3D

const INACTIVE_COLOR = Color(0.0, 0.35, 1.0, 1.0)
const ACTIVE_COLOR = Color(0.0, 1.0, 0.25, 1.0)

@export var vertical_padding = 2.0
@export var marker_half_size = 45.0
@export var marker_height = 80.0

var _material: StandardMaterial3D
var _last_key = ""


func _ready() -> void:
	_material = _make_material()
	_connect_toggle()


func _process(_delta: float) -> void:
	_rebuild_if_needed()


func _rebuild_if_needed() -> void:
	var debug = get_parent()
	if debug == null or debug.loader == null:
		return
	var key = _state_key(debug)
	if key == _last_key:
		return
	_last_key = key
	_rebuild(debug)


func _state_key(debug) -> String:
	return "%s:%d:%s:%s:%s:%s:%d" % [
		debug.track_name,
		debug.level_index,
		debug.layer_mode,
		str(debug.active_route_indices),
		str(debug.active_compartments),
		str(debug.show_full_route),
		debug.loader.loaded_compartments.size()
	]


func _rebuild(debug) -> void:
	_clear()
	var vertices = PackedVector3Array()
	var colors = PackedColorArray()
	var route = debug.loader.route
	for route_index in range(route.compartment_ids.size()):
		var position = route.route_position_for_index(route_index)
		if position == Vector3.ZERO and route.route_points.is_empty():
			continue
		var color = ACTIVE_COLOR if debug.active_route_indices.has(route_index) else INACTIVE_COLOR
		_append_box(vertices, colors, _route_marker_bounds(position), color)
	if vertices.size() > 0:
		add_child(_zone_line_node(vertices, colors))


func _route_marker_bounds(position: Vector3) -> AABB:
	var size = Vector3(marker_half_size * 2.0, marker_height, marker_half_size * 2.0)
	return AABB(position - Vector3(marker_half_size, vertical_padding, marker_half_size), size)


func _append_box(vertices: PackedVector3Array, colors: PackedColorArray, bounds: AABB, color: Color) -> void:
	var p = bounds.position
	var e = bounds.end
	var corners = [
		Vector3(p.x, p.y, p.z), Vector3(e.x, p.y, p.z), Vector3(e.x, p.y, e.z), Vector3(p.x, p.y, e.z),
		Vector3(p.x, e.y, p.z), Vector3(e.x, e.y, p.z), Vector3(e.x, e.y, e.z), Vector3(p.x, e.y, e.z)
	]
	for edge in [[0, 1], [1, 2], [2, 3], [3, 0], [4, 5], [5, 6], [6, 7], [7, 4], [0, 4], [1, 5], [2, 6], [3, 7]]:
		vertices.append(corners[edge[0]])
		vertices.append(corners[edge[1]])
		colors.append(color)
		colors.append(color)


func _zone_line_node(vertices: PackedVector3Array, colors: PackedColorArray) -> MeshInstance3D:
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_COLOR] = colors
	var mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	mesh.surface_set_material(0, _material)
	var node = MeshInstance3D.new()
	node.name = "derived_render_zones"
	node.mesh = mesh
	return node


func _connect_toggle() -> void:
	var checkbox = get_node_or_null("../DebugHud/SelectPanel/VBox/RenderZones")
	if checkbox != null:
		visible = checkbox.button_pressed
		checkbox.toggled.connect(func(enabled): visible = enabled)


func _make_material() -> StandardMaterial3D:
	var material = StandardMaterial3D.new()
	material.resource_name = "EAGL derived render zones"
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.no_depth_test = true
	return material


func _clear() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
