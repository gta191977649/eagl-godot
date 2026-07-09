class_name EAGLTrackCollisionBuilder
extends RefCounted

const MathUtils = preload("res://eagl/utils/math_utils.gd")

const CATEGORY_ORDER := [
	"Road",
	"Terrain",
	"WallBarrier",
	"SceneryCollision",
	"DriveArea",
]

const CATEGORY_COLORS := {
	"Road": Color(1.0, 0.86, 0.04, 0.40),
	"RoadEdge": Color(0.72, 0.18, 1.0, 0.95),
	"TrackPolygon": Color(1.0, 0.45, 0.08, 0.92),
	"Terrain": Color(0.0, 0.85, 1.0, 0.22),
	"WallBarrier": Color(1.0, 0.12, 0.02, 0.55),
	"SceneryCollision": Color(1.0, 0.82, 0.02, 0.45),
	"DriveArea": Color(0.05, 0.35, 1.0, 0.28),
}

const DEFAULT_DEBUG_SURFACE_OFFSET := 0.08
const DEFAULT_DRIVABLE_MIN_NORMAL_Y := 0.1
const ROAD_CHUNK_TARGET_COUNT := 48
const ROAD_CHUNK_MIN_CELL_SIZE := 24.0
const ROAD_CHUNK_MAX_CELL_SIZE := 72.0
const ROAD_CHUNK_MAX_TRIANGLES := 768


func add_track_collision(track_root: Node3D, asset, options: Dictionary = {}) -> Dictionary:
	var source_stats: Dictionary = asset.collision_stats.duplicate(true)
	if not bool(options.get("build_collision", false)):
		var disabled_stats := source_stats.duplicate(true)
		disabled_stats["enabled"] = false
		_apply_root_metadata(track_root, disabled_stats)
		return disabled_stats

	return add_collision_surfaces(track_root, asset.collision_surfaces, options, source_stats, asset.track_collision_polygons)


func add_collision_surfaces(
	track_root: Node3D,
	surfaces: Array[Dictionary],
	options: Dictionary = {},
	source_stats: Dictionary = {},
	track_polygons: Array[Dictionary] = []
) -> Dictionary:
	if not bool(options.get("build_collision", false)):
		var disabled_stats := source_stats.duplicate(true)
		disabled_stats["enabled"] = false
		_apply_root_metadata(track_root, disabled_stats)
		return disabled_stats

	var collision_root := Node3D.new()
	collision_root.name = "TrackCollision"
	collision_root.set_meta("eagl_collision_root", true)
	track_root.add_child(collision_root)

	var layer := int(options.get("collision_layer", 1))
	var mask := int(options.get("collision_mask", 1))
	var overlay_visible := bool(options.get("collision_debug_visible", false))
	var overlay_surface_offset := float(options.get("collision_debug_surface_offset", DEFAULT_DEBUG_SURFACE_OFFSET))
	var built_stats := _build_collision_nodes(collision_root, surfaces, track_polygons, layer, mask, overlay_visible, overlay_surface_offset, source_stats)
	_apply_root_metadata(track_root, built_stats)
	return built_stats


func set_debug_overlay_visible(track_root: Node, visible: bool) -> void:
	if track_root == null:
		return
	for node in track_root.find_children("*", "MeshInstance3D", true, false):
		if bool(node.get_meta("eagl_collision_debug_overlay", false)):
			node.visible = visible


func _build_collision_nodes(collision_root: Node3D, surfaces: Array[Dictionary], track_polygons: Array[Dictionary], layer: int, mask: int, overlay_visible: bool, overlay_surface_offset: float, source_stats: Dictionary) -> Dictionary:
	var sanitization := _sanitize_surfaces(surfaces)
	var sanitized_surfaces: Array[Dictionary] = sanitization.get("surfaces", [])
	var overlay_line_grouped := _group_debug_lines_by_category(surfaces)
	var track_polygon_surfaces := _track_polygon_collision_surfaces(track_polygons)
	var use_track_polygon_collision := not track_polygon_surfaces.is_empty()
	var explicit_road_surfaces := _surfaces_for_category(sanitized_surfaces, "Road", false)
	var use_explicit_road_collision := not explicit_road_surfaces.is_empty()
	var track_polygon_overlay_grouped: Dictionary = {}
	var track_polygon_overlay_lines: PackedVector3Array = PackedVector3Array()
	var track_polygon_total_overlay_line_count := 0
	if use_track_polygon_collision and not use_explicit_road_collision:
		track_polygon_overlay_grouped = _group_debug_lines_by_category(track_polygon_surfaces)
		track_polygon_overlay_lines = track_polygon_overlay_grouped.get("Road", PackedVector3Array())
		track_polygon_total_overlay_line_count = _line_count_for_grouped_lines(track_polygon_overlay_grouped)
	var body_count := 0
	var shape_count := 0
	var overlay_count := 0
	var triangle_count := 0
	var track_polygon_overlay_count := 0
	var track_polygon_overlay_line_count := 0
	var by_category := {}
	var road_chunk_count := 0
	var road_chunk_triangle_max := 0
	var road_chunk_triangle_avg := 0.0
	var road_chunk_cell_size := 0.0

	var road_result := _build_road_chunk_nodes(
		collision_root,
		explicit_road_surfaces if use_explicit_road_collision else (_surfaces_for_category(track_polygon_surfaces, "Road", false) if use_track_polygon_collision else explicit_road_surfaces),
		overlay_line_grouped.get("Road", PackedVector3Array()),
		layer,
		mask,
		overlay_visible,
		overlay_surface_offset,
		use_explicit_road_collision or not use_track_polygon_collision
	)
	body_count += int(road_result.get("body_count", 0))
	shape_count += int(road_result.get("shape_count", 0))
	overlay_count += int(road_result.get("overlay_count", 0))
	triangle_count += int(road_result.get("triangle_count", 0))
	road_chunk_count = int(road_result.get("road_chunk_count", 0))
	road_chunk_triangle_max = int(road_result.get("road_chunk_triangle_max", 0))
	road_chunk_triangle_avg = float(road_result.get("road_chunk_triangle_avg", 0.0))
	road_chunk_cell_size = float(road_result.get("road_chunk_cell_size", 0.0))
	if road_result.has("by_category"):
		by_category["Road"] = road_result["by_category"]

	if use_track_polygon_collision and not use_explicit_road_collision:
		var overlay_root := Node3D.new()
		overlay_root.name = "TrackPolygonDebug"
		overlay_root.set_meta("eagl_collision_category", "TrackPolygon")
		collision_root.add_child(overlay_root)
		var polygon_overlay := _make_overlay_line_mesh("TrackPolygon", track_polygon_overlay_lines, overlay_visible)
		polygon_overlay.name = "TrackPolygonCollisionLines"
		polygon_overlay.set_meta("eagl_track_polygon_collision_overlay", true)
		overlay_root.add_child(polygon_overlay)
		overlay_count += 1
		track_polygon_overlay_count = _non_empty_line_group_count(track_polygon_overlay_grouped)
		track_polygon_overlay_line_count = track_polygon_total_overlay_line_count
		by_category["TrackPolygon"] = {
			"lines": int(track_polygon_overlay_lines.size() / 2),
			"polygons": _track_polygon_drive_area_count(track_polygons),
			"shape_kind": "track_polygon_lines",
		}

	if not use_explicit_road_collision:
		for category in CATEGORY_ORDER:
			if category == "Road":
				continue
			var category_surfaces := _surfaces_for_category(sanitized_surfaces, category, false)
			if use_track_polygon_collision:
				category_surfaces.append_array(_surfaces_for_category(track_polygon_surfaces, category, false))
			var overlay_surfaces := _surfaces_for_category(sanitized_surfaces, category, true)
			var faces := _faces_from_surfaces(category_surfaces)
			var overlay_faces := _faces_from_surfaces(overlay_surfaces)
			var overlay_lines: PackedVector3Array = overlay_line_grouped.get(category, PackedVector3Array())
			if use_track_polygon_collision:
				overlay_lines.append_array(track_polygon_overlay_grouped.get(category, PackedVector3Array()))
			if faces.is_empty() and overlay_faces.is_empty() and overlay_lines.is_empty():
				continue
			var category_result := _build_single_category_node(
				collision_root,
				category,
				faces,
				overlay_faces,
				overlay_lines,
				layer,
				mask,
				overlay_visible,
				overlay_surface_offset
			)
			body_count += int(category_result.get("body_count", 0))
			shape_count += int(category_result.get("shape_count", 0))
			overlay_count += int(category_result.get("overlay_count", 0))
			triangle_count += int(category_result.get("triangle_count", 0))
			if category_result.has("by_category"):
				by_category[category] = category_result["by_category"]

	var stats := source_stats.duplicate(true)
	stats["enabled"] = true
	stats["body_count"] = body_count
	stats["shape_count"] = shape_count
	stats["overlay_count"] = overlay_count
	stats["triangle_count"] = triangle_count
	stats["by_built_category"] = by_category
	stats["collision_layer"] = layer
	stats["collision_mask"] = mask
	stats["debug_overlay_visible"] = overlay_visible
	stats["debug_overlay_surface_offset"] = overlay_surface_offset
	stats["filtered_triangle_count"] = int(sanitization.get("filtered_triangle_count", 0))
	stats["filtered_by_category"] = sanitization.get("filtered_by_category", {})
	stats["road_chunk_count"] = road_chunk_count
	stats["road_chunk_triangle_max"] = road_chunk_triangle_max
	stats["road_chunk_triangle_avg"] = road_chunk_triangle_avg
	stats["road_chunk_cell_size"] = road_chunk_cell_size
	stats["track_polygon_overlay_count"] = track_polygon_overlay_count
	stats["track_polygon_overlay_line_count"] = track_polygon_overlay_line_count
	stats["track_polygon_overlay_source"] = "track_collision_polygons" if use_track_polygon_collision and not use_explicit_road_collision else ""
	stats["road_edge_wall_count"] = 0
	stats["road_edge_wall_segment_count"] = 0
	stats["road_edge_wall_total_length"] = 0.0
	stats["road_edge_wall_source"] = ""
	return stats


func _surfaces_for_category(surfaces: Array[Dictionary], category: String, include_debug_only: bool) -> Array[Dictionary]:
	var grouped: Array[Dictionary] = []
	for surface in surfaces:
		if bool(surface.get("debug_only", false)) and not include_debug_only:
			continue
		if String(surface.get("category", "")) != category:
			continue
		grouped.append(surface)
	return grouped


func _group_debug_lines_by_category(surfaces: Array[Dictionary]) -> Dictionary:
	var grouped := {}
	for category in CATEGORY_ORDER:
		grouped[category] = PackedVector3Array()

	for surface in surfaces:
		var category := String(surface.get("category", ""))
		if not grouped.has(category):
			continue
		var target: PackedVector3Array = grouped[category]
		var lines: PackedVector3Array = surface.get("debug_lines", PackedVector3Array())
		target.append_array(lines)
		grouped[category] = target
	return grouped


func _line_count_for_grouped_lines(grouped: Dictionary) -> int:
	var count := 0
	for value in grouped.values():
		if typeof(value) == TYPE_PACKED_VECTOR3_ARRAY:
			var lines: PackedVector3Array = value
			count += int(lines.size() / 2)
	return count


func _non_empty_line_group_count(grouped: Dictionary) -> int:
	var count := 0
	for value in grouped.values():
		if typeof(value) == TYPE_PACKED_VECTOR3_ARRAY:
			var lines: PackedVector3Array = value
			if not lines.is_empty():
				count += 1
	return count


func _track_polygon_overlay_lines(track_polygons: Array[Dictionary]) -> PackedVector3Array:
	var lines := PackedVector3Array()
	for polygon in track_polygons:
		if not _track_collision_polygon_contributes_to_drive_area(polygon):
			continue
		var points := _track_polygon_godot_points(polygon)
		if points.size() < 3:
			continue
		for index in range(points.size()):
			lines.append(points[index])
			lines.append(points[(index + 1) % points.size()])
	return lines


func _track_polygon_collision_surfaces(track_polygons: Array[Dictionary]) -> Array[Dictionary]:
	var surfaces: Array[Dictionary] = []
	for polygon in track_polygons:
		if not bool(polygon.get("valid_plane", true)):
			continue
		var points := _track_polygon_godot_points(polygon)
		if points.size() < 3:
			continue
		var faces := PackedVector3Array()
		_append_track_polygon_face(faces, points[0], points[1], points[2])
		if points.size() >= 4:
			_append_track_polygon_face(faces, points[0], points[2], points[3])
		if faces.is_empty():
			continue
		var category := _track_collision_polygon_category(polygon)
		surfaces.append({
			"category": category,
			"debug_only": false,
			"triangle_count": int(faces.size() / 3),
			"faces": faces,
			"debug_lines": _track_polygon_edge_lines(points),
			"source_kind": "track_polygon_collision_area",
			"source_name": String(polygon.get("source_name", "TrackPolygon_%06d" % int(polygon.get("record_index", surfaces.size())))),
			"source_chunk_offset": int(polygon.get("source_chunk_offset", -1)),
			"source_record_offset": int(polygon.get("source_record_offset", -1)),
			"record_index": int(polygon.get("record_index", polygon.get("index", -1))),
			"aabb": _aabb_dictionary_for_faces(faces),
		})
	return surfaces


func _track_polygon_edge_lines(points: PackedVector3Array) -> PackedVector3Array:
	var lines := PackedVector3Array()
	for index in range(points.size()):
		lines.append(points[index])
		lines.append(points[(index + 1) % points.size()])
	return lines


func _append_track_polygon_face(faces: PackedVector3Array, a: Vector3, b: Vector3, c: Vector3) -> void:
	var normal := (b - a).cross(c - a)
	if normal.length_squared() <= 0.000001:
		return
	if normal.y < 0.0:
		var swap := b
		b = c
		c = swap
	faces.append(a)
	faces.append(b)
	faces.append(c)


func _track_polygon_drive_area_count(track_polygons: Array[Dictionary]) -> int:
	var count := 0
	for polygon in track_polygons:
		if _track_collision_polygon_contributes_to_drive_area(polygon):
			count += 1
	return count


func _track_collision_polygon_contributes_to_drive_area(polygon: Dictionary) -> bool:
	return (int(polygon.get("flags", 0)) & 0x0a) == 0 and bool(polygon.get("valid_plane", true))


func _track_collision_polygon_category(polygon: Dictionary) -> String:
	var flags := int(polygon.get("flags", 0))
	if (flags & 0x02) != 0:
		return "WallBarrier"
	if (flags & 0x08) != 0:
		return "SceneryCollision"
	return "Road"


func _track_polygon_godot_points(polygon: Dictionary) -> PackedVector3Array:
	var godot_points = polygon.get("points_godot", PackedVector3Array())
	if typeof(godot_points) == TYPE_PACKED_VECTOR3_ARRAY:
		var packed_godot: PackedVector3Array = godot_points
		if packed_godot.size() >= 3:
			return packed_godot
	if typeof(godot_points) == TYPE_ARRAY:
		var array_godot := PackedVector3Array()
		for point_value in godot_points:
			array_godot.append(_vec3_value(point_value))
		if array_godot.size() >= 3:
			return array_godot

	var ps2_points = polygon.get("points_ps2", [])
	var out := PackedVector3Array()
	if typeof(ps2_points) != TYPE_ARRAY and typeof(ps2_points) != TYPE_PACKED_VECTOR3_ARRAY:
		return out
	for point_value in ps2_points:
		out.append(MathUtils.ps2_to_godot_vec3(_vec3_value(point_value)))
	return out


func _sanitize_surfaces(surfaces: Array[Dictionary]) -> Dictionary:
	var sanitized: Array[Dictionary] = []
	var filtered_triangle_count := 0
	var filtered_by_category := {}

	for surface in surfaces:
		var next_surface := surface.duplicate(true)
		var category := String(surface.get("category", ""))
		var faces: PackedVector3Array = surface.get("faces", PackedVector3Array())
		if category in ["Road", "DriveArea"] and not faces.is_empty():
			var filtered_faces := _filter_drivable_faces(faces, DEFAULT_DRIVABLE_MIN_NORMAL_Y)
			filtered_triangle_count += max(0, int((faces.size() - filtered_faces.size()) / 3))
			if filtered_faces.size() != faces.size():
				filtered_by_category[category] = int(filtered_by_category.get(category, 0)) + int((faces.size() - filtered_faces.size()) / 3)
			next_surface["faces"] = filtered_faces
			next_surface["triangle_count"] = int(filtered_faces.size() / 3)
			next_surface["aabb"] = _aabb_dictionary_for_faces(filtered_faces)
		elif not faces.is_empty() and not next_surface.has("aabb"):
			next_surface["aabb"] = _aabb_dictionary_for_faces(faces)
		sanitized.append(next_surface)

	return {
		"surfaces": sanitized,
		"filtered_triangle_count": filtered_triangle_count,
		"filtered_by_category": filtered_by_category,
	}


func _filter_drivable_faces(faces: PackedVector3Array, min_normal_y: float) -> PackedVector3Array:
	if faces.is_empty():
		return faces

	var filtered := PackedVector3Array()
	for index in range(0, faces.size() - 2, 3):
		var a := faces[index]
		var b := faces[index + 1]
		var c := faces[index + 2]
		var normal := (b - a).cross(c - a)
		if normal.length_squared() <= 0.000001:
			continue
		if normal.normalized().y < min_normal_y:
			continue
		filtered.append(a)
		filtered.append(b)
		filtered.append(c)
	return filtered


func _build_road_chunk_nodes(collision_root: Node3D, surfaces: Array[Dictionary], overlay_lines: PackedVector3Array, layer: int, mask: int, overlay_visible: bool, overlay_surface_offset: float, build_surface_overlay: bool = true) -> Dictionary:
	if surfaces.is_empty() and overlay_lines.is_empty():
		return {}

	var chunking := _chunk_road_surfaces(surfaces)
	var chunks: Array = chunking.get("chunks", [])
	var cell_size := float(chunking.get("cell_size", 0.0))
	var body_names: Array[String] = []
	var body_count := 0
	var shape_count := 0
	var overlay_count := 0
	var triangle_count := 0
	var chunk_triangle_max := 0

	for chunk_index in range(chunks.size()):
		var chunk_surfaces := _dictionary_array_from_variant(chunks[chunk_index])
		var chunk_faces := _faces_from_surfaces(chunk_surfaces)
		if chunk_faces.is_empty():
			continue
		var chunk_triangles := int(chunk_faces.size() / 3)
		var physics_faces := _faces_for_collision_category("Road", chunk_faces)
		var body := StaticBody3D.new()
		body.collision_layer = layer
		body.collision_mask = mask
		body.name = "Road_Chunk_%03d" % body_count
		body.set_meta("eagl_collision_category", "Road")
		body.set_meta("eagl_collision_triangle_count", chunk_triangles)
		body.set_meta("eagl_collision_chunk_index", body_count)
		collision_root.add_child(body)
		body_names.append(body.name)
		body_count += 1
		triangle_count += chunk_triangles
		chunk_triangle_max = max(chunk_triangle_max, chunk_triangles)

		var shape := ConcavePolygonShape3D.new()
		shape.backface_collision = _use_backface_collision("Road")
		shape.set_faces(physics_faces)
		var shape_node := CollisionShape3D.new()
		shape_node.name = "%sShape" % body.name
		shape_node.shape = shape
		body.add_child(shape_node)
		shape_count += 1

		if build_surface_overlay:
			var overlay := _make_overlay_mesh("Road", chunk_faces, overlay_visible, overlay_surface_offset)
			overlay.name = "%sOverlay" % body.name
			body.add_child(overlay)
			overlay_count += 1

	if not overlay_lines.is_empty():
		var overlay_root := Node3D.new()
		overlay_root.name = "RoadEdgeDebug"
		overlay_root.set_meta("eagl_collision_category", "RoadEdge")
		collision_root.add_child(overlay_root)
		var line_overlay := _make_overlay_line_mesh("RoadEdge", overlay_lines, overlay_visible)
		overlay_root.add_child(line_overlay)
		overlay_count += 1

	return {
		"body_count": body_count,
		"shape_count": shape_count,
		"overlay_count": overlay_count,
		"triangle_count": triangle_count,
		"road_chunk_count": body_count,
		"road_chunk_triangle_max": chunk_triangle_max,
		"road_chunk_triangle_avg": float(triangle_count) / float(body_count) if body_count > 0 else 0.0,
		"road_chunk_cell_size": cell_size,
		"by_category": {
			"triangles": triangle_count,
			"shapes": shape_count,
			"bodies": body_names,
			"shape_kind": "concave_chunked",
			"chunks": body_count,
		},
	}


func _build_single_category_node(collision_root: Node3D, category: String, faces: PackedVector3Array, overlay_faces: PackedVector3Array, overlay_lines: PackedVector3Array, layer: int, mask: int, overlay_visible: bool, overlay_surface_offset: float) -> Dictionary:
	var body: Node3D
	var body_count := 0
	var shape_count := 0
	var overlay_count := 0
	var triangle_count := int(faces.size() / 3)
	if faces.is_empty():
		body = Node3D.new()
	else:
		var static_body := StaticBody3D.new()
		static_body.collision_layer = layer
		static_body.collision_mask = mask
		body = static_body
		body_count = 1
	body.name = category
	body.set_meta("eagl_collision_category", category)
	body.set_meta("eagl_collision_triangle_count", triangle_count)
	collision_root.add_child(body)

	if not faces.is_empty():
		var physics_faces := _faces_for_collision_category(category, faces)
		var shape := ConcavePolygonShape3D.new()
		shape.backface_collision = _use_backface_collision(category)
		shape.set_faces(physics_faces)
		var shape_node := CollisionShape3D.new()
		shape_node.name = "%sShape" % category
		shape_node.shape = shape
		body.add_child(shape_node)
		shape_count = 1

	if not overlay_faces.is_empty():
		var overlay := _make_overlay_mesh(category, overlay_faces, overlay_visible, overlay_surface_offset)
		body.add_child(overlay)
		overlay_count += 1
	if not overlay_lines.is_empty():
		var line_overlay := _make_overlay_line_mesh(category, overlay_lines, overlay_visible)
		body.add_child(line_overlay)
		overlay_count += 1

	return {
		"body_count": body_count,
		"shape_count": shape_count,
		"overlay_count": overlay_count,
		"triangle_count": triangle_count,
		"by_category": {
			"triangles": triangle_count,
			"shapes": shape_count,
			"body": body.name,
			"shape_kind": "concave",
		},
	}


func _chunk_road_surfaces(surfaces: Array[Dictionary]) -> Dictionary:
	if surfaces.is_empty():
		return {"chunks": [], "cell_size": 0.0}
	var merged_aabb := _merged_surface_aabb(surfaces)
	var bounds_area := maxf(merged_aabb.size.x, 0.0) * maxf(merged_aabb.size.z, 0.0)
	var cell_size := ROAD_CHUNK_MIN_CELL_SIZE
	if bounds_area > 0.0001:
		cell_size = sqrt(bounds_area / float(ROAD_CHUNK_TARGET_COUNT))
	cell_size = clampf(cell_size, ROAD_CHUNK_MIN_CELL_SIZE, ROAD_CHUNK_MAX_CELL_SIZE)

	var chunk_groups := {}
	for surface in surfaces:
		var center := _surface_aabb_center(surface)
		var cell_x := int(floor((center.x - merged_aabb.position.x) / cell_size))
		var cell_z := int(floor((center.z - merged_aabb.position.z) / cell_size))
		var key := "%d:%d" % [cell_x, cell_z]
		if not chunk_groups.has(key):
			chunk_groups[key] = []
		var chunk_surfaces: Array = chunk_groups[key]
		chunk_surfaces.append(surface)
		chunk_groups[key] = chunk_surfaces

	var keys: Array = chunk_groups.keys()
	keys.sort()
	var chunks: Array = []
	for key in keys:
		var group_surfaces := _dictionary_array_from_variant(chunk_groups[key])
		var group_triangles := _triangle_count_for_surfaces(group_surfaces)
		if group_triangles <= ROAD_CHUNK_MAX_TRIANGLES:
			chunks.append(group_surfaces)
			continue
		for split_chunk in _split_road_chunk_surfaces(group_surfaces, ROAD_CHUNK_MAX_TRIANGLES):
			chunks.append(split_chunk)

	return {
		"chunks": chunks,
		"cell_size": cell_size,
	}


func _split_road_chunk_surfaces(surfaces: Array[Dictionary], max_triangles: int) -> Array:
	if surfaces.is_empty():
		return []
	var bounds := _merged_surface_aabb(surfaces)
	var axis := 0 if bounds.size.x >= bounds.size.z else 2
	var sorted_surfaces: Array = surfaces.duplicate()
	sorted_surfaces.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_coord := _surface_sort_coord(a, axis)
		var b_coord := _surface_sort_coord(b, axis)
		if is_equal_approx(a_coord, b_coord):
			return _surface_sort_coord(a, 0) < _surface_sort_coord(b, 0)
		return a_coord < b_coord
	)

	var out: Array = []
	var current: Array[Dictionary] = []
	var current_triangles := 0
	for surface_value in sorted_surfaces:
		var surface: Dictionary = surface_value
		var surface_triangles: int = int(max(1, int(surface.get("triangle_count", 0))))
		if not current.is_empty() and current_triangles + surface_triangles > max_triangles:
			out.append(current)
			current = []
			current_triangles = 0
		current.append(surface)
		current_triangles += surface_triangles
	if not current.is_empty():
		out.append(current)
	return out


func _triangle_count_for_surfaces(surfaces: Array[Dictionary]) -> int:
	var total := 0
	for surface in surfaces:
		total += int(surface.get("triangle_count", 0))
	return total


func _dictionary_array_from_variant(value) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if typeof(value) != TYPE_ARRAY:
		return out
	for item in value:
		if typeof(item) == TYPE_DICTIONARY:
			out.append(item)
	return out


func _faces_from_surfaces(surfaces: Array[Dictionary]) -> PackedVector3Array:
	var faces := PackedVector3Array()
	for surface in surfaces:
		faces.append_array(surface.get("faces", PackedVector3Array()))
	return faces


func _faces_for_collision_category(category: String, faces: PackedVector3Array) -> PackedVector3Array:
	if category in ["Road", "DriveArea"]:
		return _flip_triangle_winding(faces)
	return faces


func _flip_triangle_winding(faces: PackedVector3Array) -> PackedVector3Array:
	if faces.is_empty():
		return faces
	var flipped := PackedVector3Array()
	flipped.resize(faces.size())
	for index in range(0, faces.size() - 2, 3):
		flipped[index] = faces[index]
		flipped[index + 1] = faces[index + 2]
		flipped[index + 2] = faces[index + 1]
	return flipped


func _merged_surface_aabb(surfaces: Array[Dictionary]) -> AABB:
	var merged := AABB()
	var has_bounds := false
	for surface in surfaces:
		var surface_aabb := _surface_aabb(surface)
		if surface_aabb.size == Vector3.ZERO and surface.get("faces", PackedVector3Array()).is_empty():
			continue
		if not has_bounds:
			merged = surface_aabb
			has_bounds = true
			continue
		merged = merged.merge(surface_aabb)
	return merged


func _surface_aabb_center(surface: Dictionary) -> Vector3:
	var aabb := _surface_aabb(surface)
	return aabb.position + aabb.size * 0.5


func _surface_sort_coord(surface: Dictionary, axis: int) -> float:
	var center := _surface_aabb_center(surface)
	if axis == 2:
		return center.z
	return center.x


func _surface_aabb(surface: Dictionary) -> AABB:
	var raw_aabb = surface.get("aabb", null)
	if typeof(raw_aabb) == TYPE_DICTIONARY:
		var aabb_dict: Dictionary = raw_aabb
		if aabb_dict.has("min") and aabb_dict.has("max"):
			var min_point := _vec3_from_aabb_array(aabb_dict.get("min", []))
			var max_point := _vec3_from_aabb_array(aabb_dict.get("max", []))
			return AABB(min_point, max_point - min_point)
	var faces: PackedVector3Array = surface.get("faces", PackedVector3Array())
	return _aabb_for_faces(faces)


func _vec3_from_aabb_array(value) -> Vector3:
	if typeof(value) != TYPE_ARRAY:
		return Vector3.ZERO
	var array_value: Array = value
	if array_value.size() < 3:
		return Vector3.ZERO
	return Vector3(float(array_value[0]), float(array_value[1]), float(array_value[2]))


func _vec3_value(value) -> Vector3:
	if typeof(value) == TYPE_VECTOR3:
		return value
	if typeof(value) == TYPE_ARRAY:
		var array_value: Array = value
		if array_value.size() >= 3:
			return Vector3(float(array_value[0]), float(array_value[1]), float(array_value[2]))
	return Vector3.ZERO


func _aabb_dictionary_for_faces(faces: PackedVector3Array):
	if faces.is_empty():
		return null
	var aabb := _aabb_for_faces(faces)
	return {
		"min": [aabb.position.x, aabb.position.y, aabb.position.z],
		"max": [
			aabb.position.x + aabb.size.x,
			aabb.position.y + aabb.size.y,
			aabb.position.z + aabb.size.z,
		],
	}


func _aabb_for_faces(faces: PackedVector3Array) -> AABB:
	if faces.is_empty():
		return AABB()
	var min_point := faces[0]
	var max_point := faces[0]
	for index in range(1, faces.size()):
		var point := faces[index]
		min_point = min_point.min(point)
		max_point = max_point.max(point)
	return AABB(min_point, max_point - min_point)


func _make_overlay_mesh(category: String, faces: PackedVector3Array, visible: bool, surface_offset: float) -> MeshInstance3D:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _wireframe_overlay_lines(faces, surface_offset)

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)

	var material := StandardMaterial3D.new()
	material.resource_name = "%sCollisionOverlay" % category
	var color: Color = CATEGORY_COLORS.get(category, Color(1.0, 1.0, 1.0, 0.85))
	color.a = maxf(color.a, 0.85)
	material.albedo_color = color
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	material.no_depth_test = true
	material.render_priority = 10
	mesh.surface_set_material(0, material)

	var overlay := MeshInstance3D.new()
	overlay.name = "%sCollisionOverlay" % category
	overlay.mesh = mesh
	overlay.visible = visible
	overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	overlay.extra_cull_margin = maxf(surface_offset * 4.0, 1.0)
	overlay.set_meta("eagl_collision_debug_overlay", true)
	overlay.set_meta("eagl_collision_category", category)
	overlay.set_meta("eagl_collision_triangle_count", int(faces.size() / 3))
	overlay.set_meta("eagl_collision_debug_surface_offset", surface_offset)
	return overlay


func _make_overlay_line_mesh(category: String, lines: PackedVector3Array, visible: bool) -> MeshInstance3D:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = lines

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)

	var material := StandardMaterial3D.new()
	material.resource_name = "%sCollisionOverlay" % category
	var color: Color = CATEGORY_COLORS.get(category, Color(1.0, 1.0, 1.0, 0.85))
	color.a = maxf(color.a, 0.85)
	material.albedo_color = color
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	material.no_depth_test = true
	material.render_priority = 11
	mesh.surface_set_material(0, material)

	var overlay := MeshInstance3D.new()
	overlay.name = "%sCollisionLines" % category
	overlay.mesh = mesh
	overlay.visible = visible
	overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	overlay.extra_cull_margin = 1.0
	overlay.set_meta("eagl_collision_debug_overlay", true)
	overlay.set_meta("eagl_collision_category", category)
	overlay.set_meta("eagl_collision_line_count", int(lines.size() / 2))
	return overlay


func _use_backface_collision(category: String) -> bool:
	match category:
		"Road", "DriveArea":
			return false
	return true


func _wireframe_overlay_lines(faces: PackedVector3Array, surface_offset: float) -> PackedVector3Array:
	var offset_faces := _offset_overlay_faces(faces, surface_offset)
	var lines := PackedVector3Array()
	for index in range(0, offset_faces.size() - 2, 3):
		var a := offset_faces[index]
		var b := offset_faces[index + 1]
		var c := offset_faces[index + 2]
		lines.append(a)
		lines.append(b)
		lines.append(b)
		lines.append(c)
		lines.append(c)
		lines.append(a)
	return lines


func _offset_overlay_faces(faces: PackedVector3Array, surface_offset: float) -> PackedVector3Array:
	if surface_offset <= 0.0:
		return faces
	var out := PackedVector3Array()
	out.resize(faces.size())
	for index in range(0, faces.size() - 2, 3):
		var a := faces[index]
		var b := faces[index + 1]
		var c := faces[index + 2]
		var normal := (b - a).cross(c - a)
		if normal.length_squared() <= 0.000001:
			normal = Vector3.UP
		else:
			normal = normal.normalized()
		out[index] = a + normal * surface_offset
		out[index + 1] = b + normal * surface_offset
		out[index + 2] = c + normal * surface_offset
	return out


func _apply_root_metadata(track_root: Node3D, stats: Dictionary) -> void:
	track_root.set_meta("eagl_collision_enabled", bool(stats.get("enabled", false)))
	track_root.set_meta("eagl_collision_stats", stats.duplicate(true))
	track_root.set_meta("eagl_collision_body_count", int(stats.get("body_count", 0)))
	track_root.set_meta("eagl_collision_shape_count", int(stats.get("shape_count", 0)))
	track_root.set_meta("eagl_collision_surface_count", int(stats.get("surface_count", 0)))
	track_root.set_meta("eagl_collision_triangle_count", int(stats.get("triangle_count", 0)))
	track_root.set_meta("eagl_collision_track_polygon_overlay_count", int(stats.get("track_polygon_overlay_count", 0)))
	track_root.set_meta("eagl_collision_track_polygon_overlay_line_count", int(stats.get("track_polygon_overlay_line_count", 0)))
