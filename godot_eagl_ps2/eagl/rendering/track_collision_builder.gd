class_name EAGLTrackCollisionBuilder
extends RefCounted

const CATEGORY_ORDER := [
	"Road",
	"Terrain",
	"WallBarrier",
	"SceneryCollision",
	"DriveArea",
]

const CATEGORY_COLORS := {
	"Road": Color(0.1, 1.0, 0.25, 0.28),
	"Terrain": Color(0.0, 0.85, 1.0, 0.22),
	"WallBarrier": Color(1.0, 0.12, 0.02, 0.34),
	"SceneryCollision": Color(1.0, 0.82, 0.02, 0.32),
	"DriveArea": Color(0.05, 0.35, 1.0, 0.28),
}

const DEFAULT_DEBUG_SURFACE_OFFSET := 0.08


func add_track_collision(track_root: Node3D, asset, options: Dictionary = {}) -> Dictionary:
	var source_stats: Dictionary = asset.collision_stats.duplicate(true)
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
	var built_stats := _build_collision_nodes(collision_root, asset.collision_surfaces, layer, mask, overlay_visible, overlay_surface_offset, source_stats)
	_apply_root_metadata(track_root, built_stats)
	return built_stats


func set_debug_overlay_visible(track_root: Node, visible: bool) -> void:
	if track_root == null:
		return
	for node in track_root.find_children("*", "MeshInstance3D", true, false):
		if bool(node.get_meta("eagl_collision_debug_overlay", false)):
			node.visible = visible


func _build_collision_nodes(collision_root: Node3D, surfaces: Array[Dictionary], layer: int, mask: int, overlay_visible: bool, overlay_surface_offset: float, source_stats: Dictionary) -> Dictionary:
	var physics_grouped := _group_faces_by_category(surfaces, false)
	var overlay_grouped := _group_faces_by_category(surfaces, true)
	var overlay_line_grouped := _group_debug_lines_by_category(surfaces)
	var body_count := 0
	var shape_count := 0
	var overlay_count := 0
	var triangle_count := 0
	var by_category := {}

	for category in CATEGORY_ORDER:
		var faces: PackedVector3Array = physics_grouped.get(category, PackedVector3Array())
		var overlay_faces: PackedVector3Array = overlay_grouped.get(category, PackedVector3Array())
		var overlay_lines: PackedVector3Array = overlay_line_grouped.get(category, PackedVector3Array())
		if faces.is_empty() and overlay_faces.is_empty() and overlay_lines.is_empty():
			continue
		var body: Node3D
		if faces.is_empty():
			body = Node3D.new()
		else:
			var static_body := StaticBody3D.new()
			static_body.collision_layer = layer
			static_body.collision_mask = mask
			body = static_body
			body_count += 1
		body.name = category
		body.set_meta("eagl_collision_category", category)
		body.set_meta("eagl_collision_triangle_count", int(faces.size() / 3))
		collision_root.add_child(body)

		if not faces.is_empty():
			var shape := ConcavePolygonShape3D.new()
			shape.backface_collision = true
			shape.set_faces(faces)
			var shape_node := CollisionShape3D.new()
			shape_node.name = "%sShape" % category
			shape_node.shape = shape
			body.add_child(shape_node)
			shape_count += 1
			triangle_count += int(faces.size() / 3)
			by_category[category] = {
				"triangles": int(faces.size() / 3),
				"shapes": 1,
				"body": body.name,
			}

		if not overlay_faces.is_empty():
			var overlay := _make_overlay_mesh(category, overlay_faces, overlay_visible, overlay_surface_offset)
			body.add_child(overlay)
			overlay_count += 1
		if not overlay_lines.is_empty():
			var line_overlay := _make_overlay_line_mesh(category, overlay_lines, overlay_visible)
			body.add_child(line_overlay)
			overlay_count += 1


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
	return stats


func _group_faces_by_category(surfaces: Array[Dictionary], include_debug_only: bool) -> Dictionary:
	var grouped := {}
	for category in CATEGORY_ORDER:
		grouped[category] = PackedVector3Array()

	for surface in surfaces:
		if bool(surface.get("debug_only", false)) and not include_debug_only:
			continue
		var category := String(surface.get("category", ""))
		if not grouped.has(category):
			continue
		var target: PackedVector3Array = grouped[category]
		var faces: PackedVector3Array = surface.get("faces", PackedVector3Array())
		target.append_array(faces)
		grouped[category] = target
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
	overlay.name = "%sOverlay" % category
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
	overlay.name = "%sOverlay" % category
	overlay.mesh = mesh
	overlay.visible = visible
	overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	overlay.extra_cull_margin = 1.0
	overlay.set_meta("eagl_collision_debug_overlay", true)
	overlay.set_meta("eagl_collision_category", category)
	overlay.set_meta("eagl_collision_line_count", int(lines.size() / 2))
	return overlay


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
