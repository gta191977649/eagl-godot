@tool
extends EditorImportPlugin

const TrackCollisionBuilderScript := preload("res://eagl/rendering/track_collision_builder.gd")
const TrackRouteBuilderScript := preload("res://eagl/rendering/track_route_builder.gd")
const BOUNDARY_GRID_CELL_SIZE := 16.0


func _get_importer_name() -> String:
	return "eagl.track"


func _get_visible_name() -> String:
	return "EAGL Track"


func _get_recognized_extensions() -> PackedStringArray:
	return PackedStringArray(["eagltrack"])


func _get_save_extension() -> String:
	return "scn"


func _get_resource_type() -> String:
	return "PackedScene"


func _get_preset_count() -> int:
	return 1


func _get_preset_name(_preset_index: int) -> String:
	return "Default"


func _get_import_options(_path: String, _preset_index: int) -> Array[Dictionary]:
	return [
		{"name": "generate_lods", "default_value": false},
		{"name": "group_scenery_by_section", "default_value": true},
		{"name": "place_scenery_instances", "default_value": true},
		{"name": "include_debug_metadata", "default_value": false},
		{"name": "collision_debug_visible", "default_value": true},
		{
			"name": "texture_filter_mode",
			"default_value": "linear_mipmap",
			"property_hint": PROPERTY_HINT_ENUM,
			"hint_string": "linear_mipmap,linear,nearest_mipmap,nearest"
		},
	]


func _get_option_visibility(_path: String, _option_name: StringName, _options: Dictionary) -> bool:
	return true


func _import(source_file: String, save_path: String, options: Dictionary, _platform_variants: Array[String], _gen_files: Array[String]) -> Error:
	var manifest_file := FileAccess.open(source_file, FileAccess.READ)
	if manifest_file == null:
		push_error("Could not open EAGL track manifest: %s" % source_file)
		return ERR_CANT_OPEN

	var manifest = JSON.parse_string(manifest_file.get_as_text())
	if typeof(manifest) != TYPE_DICTIONARY:
		push_error("Invalid EAGL track manifest JSON: %s" % source_file)
		return ERR_PARSE_ERROR
	var version := int(manifest.get("version", 0))
	if String(manifest.get("format", "")) != "eagltrack" or version < 1 or version > 2:
		push_error("Unsupported EAGL track manifest: %s" % source_file)
		return ERR_FILE_UNRECOGNIZED

	var manifest_dir := source_file.get_base_dir()
	var binary_info: Dictionary = manifest.get("binary", {})
	var binary_path := manifest_dir.path_join(String(binary_info.get("path", "")))
	var binary := FileAccess.get_file_as_bytes(binary_path)
	if binary.is_empty() and int(binary_info.get("byte_length", 0)) > 0:
		push_error("Could not read EAGL track binary: %s" % binary_path)
		return ERR_CANT_OPEN

	var build := _build_scene(manifest, binary, manifest_dir, options)
	var build_error := String(build.get("error", ""))
	if build_error != "":
		push_error(build_error)
		return ERR_PARSE_ERROR
	var scene: Node3D = build["root"]
	_assign_scene_owners(scene, scene)
	var packed := PackedScene.new()
	var pack_error := packed.pack(scene)
	if pack_error != OK:
		return pack_error
	return ResourceSaver.save(packed, "%s.%s" % [save_path, _get_save_extension()])


func _assign_scene_owners(node: Node, owner: Node) -> void:
	for child in node.get_children():
		child.owner = owner
		_assign_scene_owners(child, owner)


func _build_scene(manifest: Dictionary, binary: PackedByteArray, manifest_dir: String, options: Dictionary) -> Dictionary:
	var include_debug := bool(options.get("include_debug_metadata", true))
	var root := Node3D.new()
	root.name = "TrackRoot"
	root.set_meta("eagl_asset_type", "track")
	root.set_meta("eagl_import_source", manifest.get("track_id", ""))
	root.set_meta("eagl_source_format", "eagltrack")

	var mesh_library := Node.new()
	mesh_library.name = "MeshLibrary"
	root.add_child(mesh_library)

	var static_root := Node3D.new()
	static_root.name = "StaticGeometry"
	root.add_child(static_root)
	var static_roots := _create_named_node3d_children(static_root, ["Roads", "Terrain", "Shadows", "SectionDetails", "Landmarks"])

	var scenery_root := Node3D.new()
	scenery_root.name = "Scenery"
	root.add_child(scenery_root)
	var scenery_roots := _create_named_node3d_children(scenery_root, ["Buildings", "Signs", "Trees", "WallsRails", "Props"])

	var environment_root := Node3D.new()
	environment_root.name = "Environment"
	root.add_child(environment_root)

	var marker_root := Node3D.new()
	marker_root.name = "TrackMarkers"
	root.add_child(marker_root)

	var textures := _texture_records_by_hash(manifest.get("textures", []), manifest_dir)
	var materials := _build_material_cache(manifest.get("materials", []), textures, include_debug)
	var object_entries := _build_object_entries(manifest.get("objects", []), binary, materials, options, mesh_library, include_debug)

	var placed := 0
	var place_scenery := bool(options.get("place_scenery_instances", true))
	_add_static_geometry(manifest, object_entries, static_roots, environment_root, marker_root, place_scenery, include_debug)
	if place_scenery:
		placed = _add_scenery_instances(manifest, object_entries, static_roots, scenery_roots, environment_root, marker_root, options, include_debug)

	var stats: Dictionary = manifest.get("stats", {})
	root.set_meta("eagl_object_count", int(stats.get("source_object_count", 0)))
	root.set_meta("eagl_rendered_object_count", object_entries.size())
	root.set_meta("eagl_placed_scenery_instance_count", placed)
	root.set_meta("eagl_scenery_instance_count", int(stats.get("scenery_instance_count", 0)))
	root.set_meta("eagl_surface_count", int(stats.get("surface_count", 0)))
	root.set_meta("eagl_vertex_count", int(stats.get("vertex_count", 0)))
	root.set_meta("eagl_texture_count", textures.size())
	var collision_payload := _parse_collision_payload(manifest, binary)
	if not bool(collision_payload.get("ok", true)):
		return {
			"root": root,
			"object_entries": object_entries,
			"error": String(collision_payload.get("error", "EAGL track collision manifest parse failed")),
		}
	collision_payload["collision_debug_visible"] = bool(options.get("collision_debug_visible", true))
	var surfaces: Array[Dictionary] = collision_payload.get("surfaces", [])
	var polygons: Array[Dictionary] = collision_payload.get("polygons", [])
	var collision_result := _import_collision(root, surfaces, collision_payload)
	if not bool(collision_result.get("ok", true)):
		return {
			"root": root,
			"object_entries": object_entries,
			"error": String(collision_result.get("error", "EAGL track collision import failed")),
		}
	_apply_collision_polygon_metadata(root, polygons, collision_payload.get("source_stats", {}), surfaces)
	_import_boundary(root, manifest)
	_import_route(root, manifest, _route_projection_surfaces(surfaces, polygons))
	return {
		"root": root,
		"object_entries": object_entries,
	}




func _create_named_node3d_children(parent: Node3D, names: Array[String]) -> Dictionary:
	var out := {}
	for child_name in names:
		var child := Node3D.new()
		child.name = child_name
		parent.add_child(child)
		out[child_name] = child
	return out


func _texture_records_by_hash(records: Array, manifest_dir: String) -> Dictionary:
	var out := {}
	for record in records:
		var texture_record: Dictionary = record
		var texture_hash := int(texture_record.get("hash", 0))
		if texture_hash == 0:
			continue
		texture_record["resource_path"] = manifest_dir.path_join(String(texture_record.get("path", "")))
		out[texture_hash] = texture_record
	return out


func _build_material_cache(records: Array, textures: Dictionary, include_debug: bool) -> Dictionary:
	var out := {}
	for record in records:
		var material_record: Dictionary = record
		var key := String(material_record.get("key", "00000000"))
		var material := StandardMaterial3D.new()
		material.resource_name = "EAGL_%s" % String(material_record.get("name", key))
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		material.vertex_color_use_as_albedo = bool(material_record.get("vertex_color_use_as_albedo", true))
		var texture_hash := int(material_record.get("texture_hash", 0))
		if texture_hash != 0 and textures.has(texture_hash):
			var texture_record: Dictionary = textures[texture_hash]
			var texture_path := String(texture_record.get("resource_path", ""))
			if texture_path != "":
				var texture = ResourceLoader.load(texture_path)
				if texture is Texture2D:
					material.albedo_texture = texture
		var alpha_mode := String(material_record.get("alpha_mode", ""))
		if alpha_mode == "MASK":
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			material.alpha_scissor_threshold = float(material_record.get("alpha_cutoff", 0.5))
		elif alpha_mode == "BLEND":
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		if include_debug:
			material.set_meta("eagl_texture_hash", texture_hash)
			material.set_meta("eagl_texture_name", material_record.get("name", ""))
		out[key] = material
	if not out.has("00000000"):
		var fallback := StandardMaterial3D.new()
		fallback.resource_name = "EAGL_default"
		fallback.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		fallback.cull_mode = BaseMaterial3D.CULL_DISABLED
		fallback.vertex_color_use_as_albedo = true
		out["00000000"] = fallback
	return out


func _build_object_entries(objects: Array, binary: PackedByteArray, materials: Dictionary, options: Dictionary, mesh_library: Node, include_debug: bool) -> Dictionary:
	var out := {}
	for obj in objects:
		var object_record: Dictionary = obj
		var mesh = _build_mesh(object_record, binary, materials, options)
		if mesh == null:
			continue
		var chunk_offset := int(object_record.get("chunk_offset", -1))
		var entry := {
			"object": object_record,
			"mesh": mesh,
			"mirrored_mesh": null,
		}
		out[chunk_offset] = entry
		if include_debug:
			var def_node := Node.new()
			def_node.name = _safe_node_name("%s_%08x" % [String(object_record.get("name", "Object")), int(object_record.get("name_hash", 0))])
			def_node.set_meta("eagl_mesh_name", object_record.get("name", ""))
			def_node.set_meta("eagl_chunk_offset", chunk_offset)
			def_node.set_meta("eagl_name_hash", object_record.get("name_hash", 0))
			def_node.set_meta("eagl_is_scenery_template", object_record.get("is_scenery_template", false))
			def_node.set_meta("bun_category", object_record.get("category", ""))
			mesh_library.add_child(def_node)
	return out


func _build_mesh(object_record: Dictionary, binary: PackedByteArray, materials: Dictionary, options: Dictionary):
	var surface_arrays: Array[Array] = []
	var surface_materials: Array[Material] = []
	var surface_names: Array[String] = []
	for surface in object_record.get("surfaces", []):
		var surface_record: Dictionary = surface
		var vertices := _read_vec3_array(binary, surface_record.get("positions", {}))
		var indices := _read_index_array(binary, surface_record.get("indices", {}))
		if vertices.size() < 3 or indices.size() < 3:
			continue
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_INDEX] = indices
		arrays[Mesh.ARRAY_NORMAL] = _read_vec3_array(binary, surface_record.get("normals", {}))
		if surface_record.has("uvs"):
			arrays[Mesh.ARRAY_TEX_UV] = _read_uv_array(binary, surface_record.get("uvs", {}))
		if surface_record.has("colors"):
			arrays[Mesh.ARRAY_COLOR] = _read_color_array(binary, surface_record.get("colors", {}))
		surface_arrays.append(arrays)
		surface_materials.append(materials.get(String(surface_record.get("material", "00000000")), materials["00000000"]))
		surface_names.append(String(surface_record.get("name", "surface_%03d" % surface_names.size())))

	if surface_arrays.is_empty():
		return null
	if bool(options.get("generate_lods", true)):
		var importer_mesh := ImporterMesh.new()
		for surface_index in range(surface_arrays.size()):
			importer_mesh.add_surface(
				Mesh.PRIMITIVE_TRIANGLES,
				surface_arrays[surface_index],
				[],
				{},
				surface_materials[surface_index],
				surface_names[surface_index]
			)
		importer_mesh.generate_lods(deg_to_rad(25.0), deg_to_rad(60.0), [])
		return importer_mesh.get_mesh()

	var mesh := ArrayMesh.new()
	for surface_index in range(surface_arrays.size()):
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_arrays[surface_index])
		mesh.surface_set_material(surface_index, surface_materials[surface_index])
	return mesh


func _read_vec3_array(binary: PackedByteArray, spec: Dictionary) -> PackedVector3Array:
	var out := PackedVector3Array()
	var offset := int(spec.get("offset", 0))
	var count := int(spec.get("count", 0))
	var stride := int(spec.get("stride", 12))
	for index in range(count):
		var base := offset + index * stride
		out.append(Vector3(binary.decode_float(base), binary.decode_float(base + 4), binary.decode_float(base + 8)))
	return out


func _read_uv_array(binary: PackedByteArray, spec: Dictionary) -> PackedVector2Array:
	var out := PackedVector2Array()
	var offset := int(spec.get("offset", 0))
	var count := int(spec.get("count", 0))
	var stride := int(spec.get("stride", 8))
	for index in range(count):
		var base := offset + index * stride
		out.append(Vector2(binary.decode_float(base), binary.decode_float(base + 4)))
	return out


func _read_color_array(binary: PackedByteArray, spec: Dictionary) -> PackedColorArray:
	var out := PackedColorArray()
	var offset := int(spec.get("offset", 0))
	var count := int(spec.get("count", 0))
	var stride := int(spec.get("stride", 4))
	for index in range(count):
		var base := offset + index * stride
		out.append(Color(float(binary[base]) / 255.0, float(binary[base + 1]) / 255.0, float(binary[base + 2]) / 255.0, float(binary[base + 3]) / 255.0))
	return out


func _read_index_array(binary: PackedByteArray, spec: Dictionary) -> PackedInt32Array:
	var out := PackedInt32Array()
	var offset := int(spec.get("offset", 0))
	var count := int(spec.get("count", 0))
	var stride := int(spec.get("stride", 4))
	for index in range(count):
		out.append(int(binary.decode_u32(offset + index * stride)))
	return out


func _parse_collision_payload(manifest: Dictionary, binary: PackedByteArray) -> Dictionary:
	var collision_record = manifest.get("collision", {})
	if typeof(collision_record) != TYPE_DICTIONARY:
		return {
			"ok": true,
			"surfaces": [],
			"source_stats": {},
			"manifest_declares_collision": false,
		}

	var source_stats: Dictionary = collision_record.get("stats", {})
	var polygons := _parse_collision_polygon_records(collision_record.get("polygons", []))
	var manifest_declares_collision := (
		bool(source_stats.get("enabled", false))
		or int(source_stats.get("valid_triangle_count", source_stats.get("triangle_count", 0))) > 0
		or not polygons.is_empty()
	)

	var surfaces_value = collision_record.get("surfaces", [])
	if typeof(surfaces_value) != TYPE_ARRAY:
		if manifest_declares_collision:
			return {"ok": false, "error": "EAGL track manifest declares collision but collision.surfaces is not an array."}
		return {
			"ok": true,
			"surfaces": [],
			"polygons": polygons,
			"source_stats": source_stats,
			"manifest_declares_collision": false,
		}
	var surface_values: Array = surfaces_value
	manifest_declares_collision = manifest_declares_collision or not surface_values.is_empty()

	var surfaces: Array[Dictionary] = []
	for surface_value in surface_values:
		if typeof(surface_value) != TYPE_DICTIONARY:
			continue
		var surface_record: Dictionary = surface_value
		surfaces.append({
			"category": String(surface_record.get("category", "")),
			"debug_only": bool(surface_record.get("debug_only", false)),
			"triangle_count": int(surface_record.get("triangle_count", 0)),
			"source_kind": String(surface_record.get("source_kind", "")),
			"source_name": String(surface_record.get("source_name", "")),
			"source_chunk_offset": int(surface_record.get("source_chunk_offset", -1)),
			"source_record_offset": int(surface_record.get("source_record_offset", -1)),
			"record_index": int(surface_record.get("record_index", -1)),
			"aabb": surface_record.get("aabb", null),
			"faces": _read_vec3_array(binary, surface_record.get("faces", {})),
			"debug_lines": _read_vec3_array(binary, surface_record.get("debug_lines", {})),
		})

	if surfaces.is_empty():
		return {
			"ok": true,
			"surfaces": [],
			"polygons": polygons,
			"source_stats": source_stats,
			"manifest_declares_collision": manifest_declares_collision,
		}

	return {
		"ok": true,
		"surfaces": surfaces,
		"polygons": polygons,
		"source_stats": source_stats,
		"manifest_declares_collision": manifest_declares_collision,
	}


func _parse_collision_polygon_records(polygons_value) -> Array[Dictionary]:
	var polygons: Array[Dictionary] = []
	if typeof(polygons_value) != TYPE_ARRAY:
		return polygons
	for polygon_value in polygons_value:
		if typeof(polygon_value) != TYPE_DICTIONARY:
			continue
		var polygon_record: Dictionary = polygon_value
		var points := _vec3_points_from_array(polygon_record.get("points_ps2", []))
		if points.size() < 3:
			continue
		var aabb_record = polygon_record.get("aabb_ps2_xy", {})
		var min_xy := Vector2(INF, INF)
		var max_xy := Vector2(-INF, -INF)
		for point in points:
			min_xy.x = minf(min_xy.x, point.x)
			min_xy.y = minf(min_xy.y, point.y)
			max_xy.x = maxf(max_xy.x, point.x)
			max_xy.y = maxf(max_xy.y, point.y)
		if typeof(aabb_record) == TYPE_DICTIONARY:
			var aabb_dict: Dictionary = aabb_record
			if aabb_dict.has("min"):
				min_xy = _vec2_from_array(aabb_dict.get("min", []))
			if aabb_dict.has("max"):
				max_xy = _vec2_from_array(aabb_dict.get("max", []))
		var normal := _vec3_from_array(polygon_record.get("plane_normal_ps2", []))
		polygons.append({
			"source_kind": String(polygon_record.get("source_kind", "track_polygon_collision_area")),
			"source_name": String(polygon_record.get("source_name", "")),
			"collision_role": String(polygon_record.get("collision_role", _track_collision_polygon_role(int(polygon_record.get("flags", 0))))),
			"drive_surface": bool(polygon_record.get("drive_surface", (int(polygon_record.get("flags", 0)) & 0x0a) == 0)),
			"record_index": int(polygon_record.get("record_index", polygon_record.get("index", polygons.size()))),
			"source_chunk_offset": int(polygon_record.get("source_chunk_offset", -1)),
			"source_record_offset": int(polygon_record.get("source_record_offset", -1)),
			"material_id": int(polygon_record.get("material_id", -1)),
			"flags": int(polygon_record.get("flags", 0)),
			"selector_byte": int(polygon_record.get("selector_byte", 0)),
			"vertex_count": int(polygon_record.get("vertex_count", points.size())),
			"points_ps2": points,
			"plane_normal_ps2": normal,
			"plane_d_ps2": float(polygon_record.get("plane_d_ps2", 0.0)),
			"valid_plane": bool(polygon_record.get("valid_plane", normal.length_squared() > 0.000001)),
			"aabb_ps2_xy": {
				"min": min_xy,
				"max": max_xy,
			},
		})
	return polygons


func _import_collision(root: Node3D, surfaces: Array[Dictionary], collision_payload: Dictionary) -> Dictionary:
	var source_stats: Dictionary = collision_payload.get("source_stats", {})
	var manifest_declares_collision := bool(collision_payload.get("manifest_declares_collision", false))
	var polygons: Array[Dictionary] = collision_payload.get("polygons", [])

	var builder = TrackCollisionBuilderScript.new()
	var options := {
		"build_collision": true,
		"collision_layer": 1,
		"collision_mask": 1,
		"collision_debug_visible": bool(collision_payload.get("collision_debug_visible", false)),
		"collision_debug_surface_offset": 0.08,
	}
	var built_stats: Dictionary = builder.add_collision_surfaces(
		root,
		surfaces,
		options,
		source_stats,
		polygons
	)
	var body_count := int(built_stats.get("body_count", 0))
	var shape_count := int(built_stats.get("shape_count", 0))
	if manifest_declares_collision and (body_count <= 0 or shape_count <= 0):
		return {
			"ok": false,
			"error": "EAGL track manifest declares collision but import generated %d StaticBody3D and %d CollisionShape3D." % [body_count, shape_count],
	}
	return {"ok": true, "stats": built_stats}


func _apply_collision_polygon_metadata(root: Node3D, polygons: Array[Dictionary], source_stats: Dictionary, surfaces: Array[Dictionary]) -> void:
	root.set_meta("eagl_track_collision_polygons", polygons.duplicate(true))
	root.set_meta("eagl_track_collision_polygon_count", polygons.size())
	root.set_meta("eagl_track_collision_polygon_stats", source_stats.duplicate(true))
	root.set_meta("eagl_track_collision_polygon_sampler_enabled", not polygons.is_empty())
	root.set_meta("eagl_track_collision_road_surfaces", _sampler_road_surfaces(surfaces))


func _sampler_road_surfaces(surfaces: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for surface in surfaces:
		if String(surface.get("category", "")) != "Road":
			continue
		var faces: PackedVector3Array = surface.get("faces", PackedVector3Array())
		if faces.is_empty():
			continue
		out.append({
			"source_kind": String(surface.get("source_kind", "")),
			"source_name": String(surface.get("source_name", "")),
			"faces": faces,
		})
	return out


func _import_boundary(root: Node3D, manifest: Dictionary) -> void:
	var boundary_record = manifest.get("boundary", {})
	if typeof(boundary_record) != TYPE_DICTIONARY:
		_apply_boundary_metadata(root, false, BOUNDARY_GRID_CELL_SIZE, [], {})
		return

	var segments_value = boundary_record.get("segments", [])
	var cell_size := maxf(float(boundary_record.get("cell_size", BOUNDARY_GRID_CELL_SIZE)), 0.001)
	var segments: Array[Dictionary] = []
	if typeof(segments_value) == TYPE_ARRAY:
		for segment_value in segments_value:
			if typeof(segment_value) != TYPE_DICTIONARY:
				continue
			var segment_record: Dictionary = segment_value
			var a_xz := _vec2_from_array(segment_record.get("a_xz", []))
			var b_xz := _vec2_from_array(segment_record.get("b_xz", []))
			var inward_normal := _vec2_from_array(segment_record.get("inward_normal_xz", []))
			if a_xz == Vector2.ZERO and b_xz == Vector2.ZERO:
				continue
			if inward_normal.length_squared() <= 0.000001:
				continue
			inward_normal = inward_normal.normalized()
			var aabb_record = segment_record.get("aabb_xz", {})
			var min_xz := Vector2(minf(a_xz.x, b_xz.x), minf(a_xz.y, b_xz.y))
			var max_xz := Vector2(maxf(a_xz.x, b_xz.x), maxf(a_xz.y, b_xz.y))
			if typeof(aabb_record) == TYPE_DICTIONARY:
				var aabb_dict: Dictionary = aabb_record
				if aabb_dict.has("min"):
					min_xz = _vec2_from_array(aabb_dict.get("min", []))
				if aabb_dict.has("max"):
					max_xz = _vec2_from_array(aabb_dict.get("max", []))
			segments.append({
				"segment_index": int(segment_record.get("segment_index", segments.size())),
				"a_xz": a_xz,
				"b_xz": b_xz,
				"inward_normal_xz": inward_normal,
				"aabb_xz": {
					"min": min_xz,
					"max": max_xz,
				},
			})
	var enabled := bool(boundary_record.get("enabled", false)) and not segments.is_empty()
	var grid := _build_boundary_grid(segments, cell_size)
	_apply_boundary_metadata(root, enabled, cell_size, segments, grid)


func _import_route(root: Node3D, manifest: Dictionary, collision_surfaces: Array[Dictionary]) -> void:
	var route_record = manifest.get("route", {})
	if typeof(route_record) != TYPE_DICTIONARY:
		_apply_route_metadata_disabled(root)
		return
	var point_values = route_record.get("points", [])
	var source_points: Array[Dictionary] = []
	if typeof(point_values) == TYPE_ARRAY:
		for point_value in point_values:
			if typeof(point_value) != TYPE_DICTIONARY:
				continue
			var point_record: Dictionary = point_value
			source_points.append({
				"index": int(point_record.get("index", source_points.size())),
				"name": String(point_record.get("name", "")),
				"position_godot_flat": _vec3_from_array(point_record.get("position", [])),
				"route_sequence": int(point_record.get("route_sequence", -1)),
				"route_group": String(point_record.get("route_group", "")),
				"source_chunk_offset": int(point_record.get("source_chunk_offset", -1)),
				"source_record_offset": int(point_record.get("source_record_offset", -1)),
			})
	var source_stats: Dictionary = route_record.get("stats", {})
	var builder = TrackRouteBuilderScript.new()
	builder.add_route_points(root, source_points, collision_surfaces, {
		"build_route": not source_points.is_empty(),
		"route_debug_visible": false,
		"route_debug_height_offset": 1.0,
		"route_loop": true,
	}, source_stats)


func _route_projection_surfaces(surfaces: Array[Dictionary], polygons: Array[Dictionary]) -> Array[Dictionary]:
	var has_road_faces := false
	for surface in surfaces:
		if String(surface.get("category", "")) == "Road":
			var faces: PackedVector3Array = surface.get("faces", PackedVector3Array())
			if not faces.is_empty():
				has_road_faces = true
				break
	if has_road_faces or polygons.is_empty():
		return surfaces

	var out: Array[Dictionary] = []
	for polygon in polygons:
		if not _track_collision_polygon_contributes_to_drive_area(polygon):
			continue
		var points := _godot_points_for_collision_polygon(polygon)
		if points.size() < 3:
			continue
		var faces := PackedVector3Array()
		_append_projection_face(faces, points[0], points[1], points[2])
		if points.size() >= 4:
			_append_projection_face(faces, points[0], points[2], points[3])
		if faces.is_empty():
			continue
		out.append({
			"category": "Road",
			"triangle_count": int(faces.size() / 3),
			"faces": faces,
		})
	return out


func _track_collision_polygon_contributes_to_drive_area(polygon: Dictionary) -> bool:
	if polygon.has("drive_surface"):
		return bool(polygon.get("drive_surface", false))
	return (int(polygon.get("flags", 0)) & 0x0a) == 0


func _track_collision_polygon_role(flags: int) -> String:
	if (flags & 0x02) != 0:
		return "wall_barrier"
	if (flags & 0x08) != 0:
		return "secondary_collision"
	return "road_surface"


func _godot_points_for_collision_polygon(polygon: Dictionary) -> PackedVector3Array:
	var out := PackedVector3Array()
	var points_value = polygon.get("points_ps2", [])
	if typeof(points_value) != TYPE_ARRAY:
		return out
	for point_value in points_value:
		var point := Vector3.ZERO
		if typeof(point_value) == TYPE_VECTOR3:
			point = point_value
		elif typeof(point_value) == TYPE_ARRAY:
			point = _vec3_from_array(point_value)
		out.append(Vector3(point.x, point.z, -point.y))
	return out


func _append_projection_face(faces: PackedVector3Array, a: Vector3, b: Vector3, c: Vector3) -> void:
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


func _apply_boundary_metadata(root: Node3D, enabled: bool, cell_size: float, segments: Array[Dictionary], grid: Dictionary) -> void:
	root.set_meta("eagl_boundary_root", true)
	root.set_meta("eagl_boundary_enabled", enabled)
	root.set_meta("eagl_boundary_segment_count", segments.size())
	root.set_meta("eagl_boundary_cell_size", cell_size)
	root.set_meta("eagl_boundary_segments", segments.duplicate(true))
	root.set_meta("eagl_boundary_grid", grid.duplicate(true))


func _apply_route_metadata_disabled(root: Node3D) -> void:
	root.set_meta("eagl_route_enabled", false)
	root.set_meta("eagl_route_stats", {"enabled": false, "point_count": 0})
	root.set_meta("eagl_route_point_count", 0)
	root.set_meta("eagl_route_points", [])


func _build_boundary_grid(segments: Array[Dictionary], cell_size: float) -> Dictionary:
	var grid := {}
	for segment in segments:
		var aabb_record = segment.get("aabb_xz", {})
		if typeof(aabb_record) != TYPE_DICTIONARY:
			continue
		var aabb_dict: Dictionary = aabb_record
		var min_xz := aabb_dict.get("min", Vector2.ZERO)
		var max_xz := aabb_dict.get("max", Vector2.ZERO)
		if typeof(min_xz) != TYPE_VECTOR2 or typeof(max_xz) != TYPE_VECTOR2:
			continue
		var cell_min_x := int(floor((min_xz as Vector2).x / cell_size))
		var cell_max_x := int(floor((max_xz as Vector2).x / cell_size))
		var cell_min_z := int(floor((min_xz as Vector2).y / cell_size))
		var cell_max_z := int(floor((max_xz as Vector2).y / cell_size))
		for cell_x in range(cell_min_x, cell_max_x + 1):
			for cell_z in range(cell_min_z, cell_max_z + 1):
				var key := _boundary_grid_key(cell_x, cell_z)
				if not grid.has(key):
					grid[key] = []
				var indices: Array = grid[key]
				indices.append(int(segment.get("segment_index", -1)))
				grid[key] = indices
	return grid


func _boundary_grid_key(cell_x: int, cell_z: int) -> String:
	return "%d:%d" % [cell_x, cell_z]


func _vec3_points_from_array(value) -> Array[Vector3]:
	var points: Array[Vector3] = []
	if typeof(value) != TYPE_ARRAY:
		return points
	for point_value in value:
		points.append(_vec3_from_array(point_value))
	return points


func _vec2_from_array(value) -> Vector2:
	if typeof(value) != TYPE_ARRAY:
		return Vector2.ZERO
	var items: Array = value
	if items.size() < 2:
		return Vector2.ZERO
	return Vector2(float(items[0]), float(items[1]))


func _vec3_from_array(value) -> Vector3:
	if typeof(value) != TYPE_ARRAY:
		return Vector3.ZERO
	var items: Array = value
	if items.size() < 3:
		return Vector3.ZERO
	return Vector3(float(items[0]), float(items[1]), float(items[2]))


func _add_static_geometry(manifest: Dictionary, object_entries: Dictionary, static_roots: Dictionary, environment_root: Node3D, marker_root: Node3D, place_scenery: bool, include_debug: bool) -> void:
	var instanced_names := {}
	if place_scenery:
		for instance in manifest.get("scenery_instances", []):
			var instance_record: Dictionary = instance
			var object_name := String(instance_record.get("object_name", ""))
			if object_name != "":
				instanced_names[object_name] = true
	for chunk_offset in object_entries.keys():
		var entry: Dictionary = object_entries[chunk_offset]
		var obj: Dictionary = entry["object"]
		if not _should_render_object(obj):
			continue
		if place_scenery and bool(obj.get("is_scenery_template", false)):
			continue
		if place_scenery and instanced_names.has(String(obj.get("name", ""))):
			continue
		var category := String(obj.get("category", "STATIC_DETAIL"))
		var parent := _parent_for_category(category, static_roots, null, environment_root, marker_root)
		var node := MeshInstance3D.new()
		node.name = _safe_node_name(String(obj.get("name", "Object")))
		var transform := _ps2_rows_to_godot_transform(obj.get("transform", []))
		var mirrored := _transform_is_mirrored(transform)
		node.mesh = _mesh_for_handedness(entry, mirrored)
		node.transform = transform
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if include_debug:
			node.set_meta("eagl_object_name", obj.get("name", ""))
			node.set_meta("eagl_chunk_offset", obj.get("chunk_offset", 0))
			node.set_meta("eagl_source_role", obj.get("source_role", "UNKNOWN"))
			node.set_meta("eagl_placement_kind", "DIRECT_SOLID")
			node.set_meta("bun_category", category)
			node.set_meta("eagl_mirrored_handedness", mirrored)
		parent.add_child(node)


func _add_scenery_instances(manifest: Dictionary, object_entries: Dictionary, static_roots: Dictionary, scenery_roots: Dictionary, environment_root: Node3D, marker_root: Node3D, options: Dictionary, include_debug: bool) -> int:
	var entries_by_hash := {}
	var entries_by_name := {}
	for chunk_offset in object_entries.keys():
		var entry: Dictionary = object_entries[chunk_offset]
		var obj: Dictionary = entry["object"]
		var name_hash := int(obj.get("name_hash", 0))
		if name_hash != 0 and name_hash != 0x11111111 and not entries_by_hash.has(name_hash):
			entries_by_hash[name_hash] = entry
		var object_name := String(obj.get("name", ""))
		if object_name != "" and not entries_by_name.has(object_name):
			entries_by_name[object_name] = entry

	var section_groups := {}
	for instance in manifest.get("scenery_instances", []):
		var instance_record: Dictionary = instance
		var entry = null
		var object_hash := int(instance_record.get("object_hash", 0))
		if object_hash != 0 and entries_by_hash.has(object_hash):
			entry = entries_by_hash[object_hash]
		else:
			entry = entries_by_name.get(String(instance_record.get("object_name", "")))
		if entry == null:
			continue
		var obj: Dictionary = entry["object"]
		if not _should_render_object(obj):
			continue
		var category := String(obj.get("category", "PROP"))
		var bucket := _scenery_bucket_for_name(String(obj.get("name", "")))
		var transform := _ps2_rows_to_godot_transform(instance_record.get("transform", []))
		var mirrored := _transform_is_mirrored(transform)
		var parent := _parent_for_category(category, static_roots, scenery_roots, environment_root, marker_root, bucket)
		var group_section := int(instance_record.get("section_number", -1))
		if bool(options.get("group_scenery_by_section", true)):
			var section_key := "%s:%s:%03d" % [category, bucket, group_section]
			if not section_groups.has(section_key):
				var section_node := Node3D.new()
				section_node.name = "Section_%03d" % group_section
				parent.add_child(section_node)
				section_groups[section_key] = section_node
			parent = section_groups[section_key]
		var node := MeshInstance3D.new()
		node.name = _safe_node_name("%s_i%04d" % [String(obj.get("name", "Scenery")), int(instance_record.get("record_index", 0))])
		node.mesh = _mesh_for_handedness(entry, mirrored)
		node.transform = transform
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if include_debug:
			node.set_meta("eagl_object_name", obj.get("name", ""))
			node.set_meta("eagl_object_hash", object_hash)
			node.set_meta("eagl_instance_count", 1)
			node.set_meta("eagl_section_number", group_section)
			node.set_meta("eagl_placement_kind", "SCENERY_INSTANCE")
			node.set_meta("bun_category", category)
			node.set_meta("eagl_scenery_bucket", bucket)
			node.set_meta("eagl_mirrored_handedness", mirrored)
		parent.add_child(node)

	var placed := 0
	for instance in manifest.get("scenery_instances", []):
		var instance_record: Dictionary = instance
		var object_hash := int(instance_record.get("object_hash", 0))
		if object_hash != 0 and entries_by_hash.has(object_hash):
			placed += 1
		elif entries_by_name.has(String(instance_record.get("object_name", ""))):
			placed += 1
	return placed


func _mesh_for_handedness(entry: Dictionary, mirrored: bool) -> Mesh:
	var mesh: Mesh = entry["mesh"]
	if not mirrored:
		return mesh
	if entry.get("mirrored_mesh") != null:
		return entry["mirrored_mesh"]
	var mirrored_mesh := _build_mirrored_mesh(mesh)
	entry["mirrored_mesh"] = mirrored_mesh
	return mirrored_mesh


func _build_mirrored_mesh(source_mesh: Mesh) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	for surface_index in range(source_mesh.get_surface_count()):
		var arrays: Array = source_mesh.surface_get_arrays(surface_index)
		if arrays.size() > Mesh.ARRAY_INDEX and arrays[Mesh.ARRAY_INDEX] != null:
			arrays[Mesh.ARRAY_INDEX] = _reversed_triangle_indices(arrays[Mesh.ARRAY_INDEX])
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(surface_index, source_mesh.surface_get_material(surface_index))
	return mesh


func _reversed_triangle_indices(indices: PackedInt32Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(indices.size())
	for offset in range(0, indices.size(), 3):
		if offset + 2 >= indices.size():
			break
		out[offset] = indices[offset]
		out[offset + 1] = indices[offset + 2]
		out[offset + 2] = indices[offset + 1]
	return out


func _parent_for_category(category: String, static_roots: Dictionary, scenery_roots, environment_root: Node3D, marker_root: Node3D, scenery_bucket: String = "Props") -> Node3D:
	match category:
		"ROAD":
			return static_roots["Roads"]
		"TERRAIN":
			return static_roots["Terrain"]
		"SHADOW":
			return static_roots["Shadows"]
		"LANDMARK":
			return static_roots["Landmarks"]
		"ENVIRONMENT":
			return environment_root
		"TRACK_MARKER":
			return marker_root
		"PROP":
			if scenery_roots != null:
				return scenery_roots.get(scenery_bucket, scenery_roots["Props"])
	return static_roots["SectionDetails"]


func _should_render_object(obj: Dictionary) -> bool:
	var name := String(obj.get("name", "")).to_upper()
	return name != "SKYDOME_ENVMAP" and not name.contains("ENVMAP")


func _scenery_bucket_for_name(object_name: String) -> String:
	var name := object_name.to_upper()
	if name.begins_with("XB"):
		return "Buildings"
	if name.begins_with("XS"):
		return "Signs"
	if name.begins_with("XT"):
		return "Trees"
	if name.begins_with("XW"):
		return "WallsRails"
	return "Props"


func _ps2_rows_to_godot_transform(matrix_rows: Array) -> Transform3D:
	if matrix_rows.size() < 4:
		return Transform3D.IDENTITY
	var r0: Array = matrix_rows[0]
	var r1: Array = matrix_rows[1]
	var r2: Array = matrix_rows[2]
	var r3: Array = matrix_rows[3]
	var basis := Basis(
		Vector3(float(r0[0]), float(r0[2]), -float(r0[1])),
		Vector3(float(r2[0]), float(r2[2]), -float(r2[1])),
		Vector3(-float(r1[0]), -float(r1[2]), float(r1[1]))
	)
	var origin := Vector3(float(r3[0]), float(r3[2]), -float(r3[1]))
	return Transform3D(basis, origin)


func _transform_is_mirrored(transform: Transform3D) -> bool:
	return transform.basis.determinant() < 0.0


func _safe_node_name(value: String) -> String:
	var out := value
	for token in [":", "/", "\\", "@"]:
		out = out.replace(token, "_")
	return out
