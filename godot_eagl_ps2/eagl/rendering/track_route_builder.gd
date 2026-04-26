class_name EAGLTrackRouteBuilder
extends RefCounted

const DEFAULT_DEBUG_HEIGHT_OFFSET := 1.0
const SURFACE_EPSILON := 0.001


func add_track_route(track_root: Node3D, asset, options: Dictionary = {}) -> Dictionary:
	var source_stats: Dictionary = asset.route_stats.duplicate(true)
	if not bool(options.get("build_route", false)):
		var disabled_stats := source_stats.duplicate(true)
		disabled_stats["enabled"] = false
		_apply_root_metadata(track_root, disabled_stats, [])
		return disabled_stats

	var route_points := _project_route_points(asset.route_points, asset.collision_surfaces)
	var stats := source_stats.duplicate(true)
	stats["enabled"] = true
	stats["point_count"] = route_points.size()
	stats["projected_point_count"] = _projected_point_count(route_points)
	stats["loop"] = bool(options.get("route_loop", true))

	if not route_points.is_empty():
		var route_root := Node3D.new()
		route_root.name = "TrackRoute"
		route_root.set_meta("eagl_route_root", true)
		track_root.add_child(route_root)
		_add_route_overlay(route_root, route_points, bool(options.get("route_debug_visible", false)), float(options.get("route_debug_height_offset", DEFAULT_DEBUG_HEIGHT_OFFSET)), bool(stats["loop"]))

	_apply_root_metadata(track_root, stats, route_points)
	return stats


func set_debug_overlay_visible(track_root: Node, visible: bool) -> void:
	if track_root == null:
		return
	for node in track_root.find_children("*", "GeometryInstance3D", true, false):
		if bool(node.get_meta("eagl_route_debug_overlay", false)):
			node.visible = visible


static func nearest_route_point(route_points: Array, position: Vector3, loop: bool = true) -> Dictionary:
	if route_points.is_empty():
		return {}
	if route_points.size() == 1:
		var only_point: Vector3 = route_points[0].get("position", Vector3.ZERO)
		return {
			"position": only_point,
			"forward": Vector3.FORWARD,
			"point_index": 0,
			"segment_index": 0,
			"distance": position.distance_to(only_point),
			"horizontal_distance": _horizontal_distance(position, only_point),
		}

	var best := {}
	var best_distance_sq := INF
	var segment_count := route_points.size() if loop else route_points.size() - 1
	for index in range(segment_count):
		var a: Vector3 = route_points[index].get("position", Vector3.ZERO)
		var b: Vector3 = route_points[(index + 1) % route_points.size()].get("position", Vector3.ZERO)
		var ab := Vector2(b.x - a.x, b.z - a.z)
		var ap := Vector2(position.x - a.x, position.z - a.z)
		var denom := ab.length_squared()
		var t := 0.0
		if denom > SURFACE_EPSILON:
			t = clampf(ap.dot(ab) / denom, 0.0, 1.0)
		var closest := a.lerp(b, t)
		var dx := position.x - closest.x
		var dz := position.z - closest.z
		var distance_sq := dx * dx + dz * dz
		if distance_sq >= best_distance_sq:
			continue
		var forward := (b - a)
		forward.y = 0.0
		if forward.length_squared() <= SURFACE_EPSILON:
			forward = Vector3.FORWARD
		else:
			forward = forward.normalized()
		best_distance_sq = distance_sq
		best = {
			"position": closest,
			"forward": forward,
			"point_index": index,
			"segment_index": index,
			"segment_t": t,
			"distance": position.distance_to(closest),
			"horizontal_distance": sqrt(distance_sq),
		}
	return best


func _project_route_points(source_points: Array[Dictionary], collision_surfaces: Array[Dictionary]) -> Array[Dictionary]:
	var road_faces := PackedVector3Array()
	for surface in collision_surfaces:
		var category := String(surface.get("category", ""))
		if category != "Road" and category != "Terrain":
			continue
		road_faces.append_array(surface.get("faces", PackedVector3Array()))

	var out: Array[Dictionary] = []
	for point in source_points:
		var flat: Vector3 = point.get("position_godot_flat", Vector3.ZERO)
		var projected := _project_to_surface(flat, road_faces)
		var route_point := point.duplicate(true)
		route_point["position"] = projected.get("position", flat)
		route_point["projected"] = bool(projected.get("projected", false))
		out.append(route_point)
	return out


func _project_to_surface(flat_point: Vector3, faces: PackedVector3Array) -> Dictionary:
	var best_y := -INF
	var best_found := false
	for index in range(0, faces.size() - 2, 3):
		var a := faces[index]
		var b := faces[index + 1]
		var c := faces[index + 2]
		var bary := _barycentric_xz(flat_point, a, b, c)
		if bary.is_empty():
			continue
		var y := float(bary["u"]) * a.y + float(bary["v"]) * b.y + float(bary["w"]) * c.y
		if y <= best_y:
			continue
		best_y = y
		best_found = true
	if best_found:
		return {"projected": true, "position": Vector3(flat_point.x, best_y, flat_point.z)}
	return {"projected": false, "position": flat_point}


func _barycentric_xz(point: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Dictionary:
	var ab := Vector2(b.x - a.x, b.z - a.z)
	var ac := Vector2(c.x - a.x, c.z - a.z)
	var ap := Vector2(point.x - a.x, point.z - a.z)
	var denom := ab.x * ac.y - ab.y * ac.x
	if absf(denom) <= SURFACE_EPSILON:
		return {}
	var v := (ap.x * ac.y - ap.y * ac.x) / denom
	var w := (ab.x * ap.y - ab.y * ap.x) / denom
	var u := 1.0 - v - w
	if u < -SURFACE_EPSILON or v < -SURFACE_EPSILON or w < -SURFACE_EPSILON:
		return {}
	return {"u": u, "v": v, "w": w}


func _add_route_overlay(route_root: Node3D, route_points: Array[Dictionary], visible: bool, height_offset: float, loop: bool) -> void:
	var line_mesh := _route_line_mesh(route_points, height_offset, loop)
	var line := MeshInstance3D.new()
	line.name = "RouteLine"
	line.mesh = line_mesh
	line.visible = visible
	line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	line.set_meta("eagl_route_debug_overlay", true)
	route_root.add_child(line)

	var marker_mesh := SphereMesh.new()
	marker_mesh.radius = 1.2
	marker_mesh.height = 2.4
	var marker_material := _route_material(Color(1.0, 0.85, 0.08, 0.9))
	marker_mesh.material = marker_material
	for route_point in route_points:
		var marker := MeshInstance3D.new()
		marker.name = "RoutePoint_%03d" % int(route_point.get("index", 0))
		marker.mesh = marker_mesh
		marker.position = route_point.get("position", Vector3.ZERO) + Vector3.UP * height_offset
		marker.visible = visible
		marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		marker.set_meta("eagl_route_debug_overlay", true)
		marker.set_meta("eagl_route_point_index", int(route_point.get("index", 0)))
		route_root.add_child(marker)


func _route_line_mesh(route_points: Array[Dictionary], height_offset: float, loop: bool) -> ArrayMesh:
	var vertices := PackedVector3Array()
	if route_points.size() >= 2:
		for index in range(route_points.size() - 1):
			vertices.append(route_points[index].get("position", Vector3.ZERO) + Vector3.UP * height_offset)
			vertices.append(route_points[index + 1].get("position", Vector3.ZERO) + Vector3.UP * height_offset)
		if loop:
			vertices.append(route_points[route_points.size() - 1].get("position", Vector3.ZERO) + Vector3.UP * height_offset)
			vertices.append(route_points[0].get("position", Vector3.ZERO) + Vector3.UP * height_offset)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	mesh.surface_set_material(0, _route_material(Color(1.0, 0.2, 0.9, 0.9)))
	return mesh


func _route_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.no_depth_test = true
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	return material


func _projected_point_count(route_points: Array[Dictionary]) -> int:
	var count := 0
	for point in route_points:
		if bool(point.get("projected", false)):
			count += 1
	return count


func _apply_root_metadata(track_root: Node3D, stats: Dictionary, route_points: Array) -> void:
	track_root.set_meta("eagl_route_enabled", bool(stats.get("enabled", false)))
	track_root.set_meta("eagl_route_stats", stats.duplicate(true))
	track_root.set_meta("eagl_route_point_count", int(stats.get("point_count", 0)))
	track_root.set_meta("eagl_route_points", route_points.duplicate(true))


static func _horizontal_distance(a: Vector3, b: Vector3) -> float:
	var dx := a.x - b.x
	var dz := a.z - b.z
	return sqrt(dx * dx + dz * dz)
