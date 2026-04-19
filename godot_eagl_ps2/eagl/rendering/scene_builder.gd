class_name EAGLSceneBuilder
extends RefCounted

const MeshBuilderScript := preload("res://eagl/rendering/mesh_builder.gd")
const EnvironmentBuilderScript := preload("res://eagl/rendering/environment_builder.gd")
const MathUtils := preload("res://eagl/utils/math_utils.gd")

const SUN_LIGHT_CULL_MASK := 1 << 1

var mesh_builder := MeshBuilderScript.new()
var environment_builder := EnvironmentBuilderScript.new()
var skipped: Dictionary = {}
var warnings: Array[String] = []
var scenery_multimesh_count := 0
var environment_object_count := 0
var track_marker_count := 0


func build_track_scene(asset, options: Dictionary = {}) -> Node3D:
	mesh_builder.texture_bank = asset.texture_bank
	mesh_builder.texture_filter_mode = String(options.get("texture_filter_mode", "linear_mipmap"))
	mesh_builder.reset()
	skipped.clear()
	warnings.clear()
	scenery_multimesh_count = 0
	environment_object_count = 0
	track_marker_count = 0

	var root := Node3D.new()
	root.name = "TrackRoot"
	root.set_meta("eagl_asset_type", "track")
	root.set_meta("eagl_track_id", asset.track_id)
	root.set_meta("eagl_source_path", asset.source_path)

	var mesh_library := Node.new()
	mesh_library.name = "MeshLibrary"
	root.add_child(mesh_library)
	var mesh_cache := _build_mesh_library(asset, mesh_library)

	var static_root := Node3D.new()
	static_root.name = "StaticGeometry"
	root.add_child(static_root)
	var static_roots := _create_named_node3d_children(static_root, [
		"Roads",
		"Terrain",
		"Shadows",
		"SectionDetails",
		"Landmarks",
	])

	var scenery_root := Node3D.new()
	scenery_root.name = "Scenery"
	root.add_child(scenery_root)
	var scenery_roots := _create_named_node3d_children(scenery_root, [
		"Buildings",
		"Signs",
		"Trees",
		"WallsRails",
		"Props",
	])

	var environment_root := Node3D.new()
	environment_root.name = "Environment"
	root.add_child(environment_root)

	var marker_root := Node3D.new()
	marker_root.name = "TrackMarkers"
	root.add_child(marker_root)

	var unknown_root := Node.new()
	unknown_root.name = "UnknownChunks"
	root.add_child(unknown_root)
	_add_unknown_chunk_nodes(unknown_root, asset)

	var place_scenery: bool = bool(options.get("place_scenery_instances", true))
	var expand_instances: bool = bool(options.get("expand_scenery_instances", false))
	var built := _add_static_geometry(static_roots, environment_root, marker_root, asset, mesh_cache, place_scenery or expand_instances)
	var placed := 0
	if expand_instances:
		placed = _add_baked_scenery_instances(static_roots, scenery_roots, environment_root, marker_root, asset, mesh_cache)
	elif place_scenery:
		placed = _add_multimesh_scenery(static_roots, scenery_roots, environment_root, marker_root, asset, mesh_cache)

	_assign_sun_light_cull_layer(static_root)
	_assign_sun_light_cull_layer(scenery_root)
	root.set_meta("eagl_sun_light_cull_mask", SUN_LIGHT_CULL_MASK)
	var environment_result := environment_builder.add_track_environment(root, asset)
	_merge_builder_diagnostics()
	var bounds := _node_bounds(root)
	asset.bounds = bounds
	asset.has_bounds = bounds.size != Vector3.ZERO
	root.set_meta("eagl_object_count", asset.objects.size())
	root.set_meta("eagl_solid_pack_count", asset.solid_packs.size())
	root.set_meta("eagl_scenery_section_count", asset.scenery_sections.size())
	root.set_meta("eagl_rendered_object_count", built)
	root.set_meta("eagl_placed_scenery_instance_count", placed)
	root.set_meta("eagl_scenery_multimesh_count", scenery_multimesh_count)
	root.set_meta("eagl_environment_object_count", environment_object_count)
	root.set_meta("eagl_track_marker_count", track_marker_count)
	root.set_meta("eagl_block_count", asset.block_count())
	root.set_meta("eagl_vertex_count", asset.vertex_count())
	root.set_meta("eagl_scenery_instance_count", asset.scenery_instances.size())
	root.set_meta("eagl_unknown_chunk_count", asset.unknown_chunks.size())
	root.set_meta("eagl_has_environment_config", not asset.environment_config.is_empty())
	root.set_meta("eagl_has_sun", not environment_result.is_empty())
	root.set_meta("eagl_bounds", bounds)
	root.set_meta("eagl_skipped", skipped.duplicate(true))
	root.set_meta("eagl_textured_surface_count", mesh_builder.textured_surfaces)
	root.set_meta("eagl_fallback_surface_count", mesh_builder.fallback_surfaces)
	root.set_meta("eagl_uv_surface_count", mesh_builder.uv_surfaces)
	root.set_meta("eagl_textured_missing_uv_surface_count", mesh_builder.textured_missing_uv_surfaces)
	return root


func _build_mesh_library(asset, mesh_library: Node) -> Dictionary:
	var cache := {
		"by_offset": {},
		"by_hash": {},
		"by_name": {},
	}
	for obj in asset.objects:
		var mesh_node := mesh_builder.build_object_mesh(obj, false)
		if mesh_node == null:
			_count_skip("empty_mesh_def")
			continue
		var chunk_offset := int(obj.get("chunk_offset", -1))
		var name_hash := int(obj.get("name_hash", 0))
		var object_name: String = obj.get("name", "")
		var entry := {
			"object": obj,
			"mesh": mesh_node.mesh,
			"materials": _surface_materials(mesh_node),
		}
		if chunk_offset >= 0:
			cache["by_offset"][chunk_offset] = entry
		if name_hash != 0 and name_hash != 0x11111111 and not cache["by_hash"].has(name_hash):
			cache["by_hash"][name_hash] = entry
		if object_name != "" and not cache["by_name"].has(object_name):
			cache["by_name"][object_name] = entry

		var def_node := Node.new()
		def_node.name = _safe_node_name("%s_%08x" % [object_name, name_hash])
		def_node.set_meta("eagl_mesh_name", object_name)
		def_node.set_meta("eagl_name_hash", name_hash)
		def_node.set_meta("eagl_chunk_offset", chunk_offset)
		def_node.set_meta("eagl_solid_pack_index", obj.get("solid_pack_index", -1))
		def_node.set_meta("eagl_is_scenery_template", obj.get("is_scenery_template", false))
		def_node.set_meta("eagl_source_role", _source_role_for_object(obj))
		def_node.set_meta("bun_category", _semantic_category_for_object(obj))
		def_node.set_meta("eagl_mesh", mesh_node.mesh)
		mesh_library.add_child(def_node)
	return cache


func _create_named_node3d_children(parent: Node3D, names: Array[String]) -> Dictionary:
	var out := {}
	for child_name in names:
		var node := Node3D.new()
		node.name = child_name
		parent.add_child(node)
		out[child_name] = node
	return out


func _add_static_geometry(static_roots: Dictionary, environment_root: Node3D, marker_root: Node3D, asset, mesh_cache: Dictionary, using_placements: bool) -> int:
	var built := 0
	var solid_packs: Array = asset.solid_packs
	if solid_packs.is_empty():
		for obj in _static_objects_for_scene(asset.objects, asset, using_placements):
			if _add_static_object(static_roots, environment_root, marker_root, obj, mesh_cache):
				built += 1
		return built

	for pack in solid_packs:
		var pack_objects: Array = pack.get("objects", [])
		var static_objects := _static_objects_for_scene(pack_objects, asset, using_placements)
		if static_objects.is_empty():
			continue
		for obj in static_objects:
			if _add_static_object(static_roots, environment_root, marker_root, obj, mesh_cache):
				built += 1
	return built


func _add_static_object(static_roots: Dictionary, environment_root: Node3D, marker_root: Node3D, obj: Dictionary, mesh_cache: Dictionary) -> bool:
	var object_name: String = obj.get("name", "")
	var entry = mesh_cache["by_offset"].get(int(obj.get("chunk_offset", -1)))
	if entry == null:
		_count_skip("missing_static_mesh_def")
		return false
	var category := _semantic_category_for_object(obj)
	var parent := _parent_for_category(category, static_roots, null, environment_root, marker_root)
	var node := MeshInstance3D.new()
	node.name = _safe_node_name(object_name)
	node.mesh = entry["mesh"]
	_apply_surface_materials(node, entry.get("materials", []))
	node.transform = MathUtils.ps2_rows_to_godot_transform(obj.get("transform", []))
	node.set_meta("eagl_object_name", object_name)
	node.set_meta("eagl_chunk_offset", obj.get("chunk_offset", 0))
	node.set_meta("eagl_solid_pack_index", obj.get("solid_pack_index", -1))
	node.set_meta("eagl_source_role", _source_role_for_object(obj))
	node.set_meta("eagl_placement_kind", "DIRECT_SOLID")
	node.set_meta("bun_category", category)
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
	parent.add_child(node)
	_count_semantic_node(category)
	return true


func _static_objects_for_scene(objects: Array, asset, using_placements: bool) -> Array[Dictionary]:
	if not using_placements or asset.scenery_instances.is_empty():
		var all_static: Array[Dictionary] = []
		for obj in objects:
			if not _should_render_object(obj):
				_count_skip("non_visible_environment_source")
				continue
			all_static.append(obj)
		return all_static

	var instanced_names := _instanced_names(asset)
	var static_objects: Array[Dictionary] = []
	for obj in objects:
		if not _should_render_object(obj):
			_count_skip("non_visible_environment_source")
			continue
		if instanced_names.has(obj.get("name", "")):
			continue
		if asset.scenery_template_offsets.has(obj.get("chunk_offset", -1)):
			continue
		static_objects.append(obj)
	return static_objects


func _add_baked_scenery_instances(static_roots: Dictionary, scenery_roots: Dictionary, environment_root: Node3D, marker_root: Node3D, asset, mesh_cache: Dictionary) -> int:
	var placed := 0
	for instance in asset.scenery_instances:
		var entry = _mesh_entry_for_instance(instance, mesh_cache)
		if entry == null:
			_count_skip("missing_scenery_mesh_def")
			continue
		var obj: Dictionary = entry["object"]
		if not _should_render_object(obj):
			_count_skip("non_visible_environment_source")
			continue
		var category := _semantic_category_for_object(obj, int(instance.get("section_number", -1)))
		var scenery_bucket := _scenery_bucket_for_name(obj.get("name", ""))
		var parent := _parent_for_category(category, static_roots, scenery_roots, environment_root, marker_root, scenery_bucket)
		var node := MeshInstance3D.new()
		node.name = "%s_inst_%03d" % [obj.get("name", "Scenery"), int(instance.get("record_index", 0))]
		node.mesh = entry["mesh"]
		_apply_surface_materials(node, entry.get("materials", []))
		node.transform = MathUtils.ps2_rows_to_godot_transform(instance.get("transform", []))
		node.set_meta("eagl_scenery_instance", true)
		node.set_meta("eagl_scenery_info_index", instance.get("scenery_info_index", -1))
		node.set_meta("eagl_section_number", instance.get("section_number", -1))
		node.set_meta("eagl_source_role", _source_role_for_object(obj))
		node.set_meta("eagl_placement_kind", "SCENERY_INSTANCE")
		node.set_meta("bun_category", category)
		node.set_meta("eagl_scenery_bucket", scenery_bucket)
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
		parent.add_child(node)
		placed += 1
		_count_semantic_node(category)
	return placed


func _add_multimesh_scenery(static_roots: Dictionary, scenery_roots: Dictionary, environment_root: Node3D, marker_root: Node3D, asset, mesh_cache: Dictionary) -> int:
	var groups := {}
	for instance in asset.scenery_instances:
		var entry = _mesh_entry_for_instance(instance, mesh_cache)
		if entry == null:
			_count_skip("missing_scenery_mesh_def")
			continue
		var obj: Dictionary = entry["object"]
		if not _should_render_object(obj):
			_count_skip("non_visible_environment_source")
			continue
		var mesh_hash := int(instance.get("object_hash", obj.get("name_hash", 0)))
		var category := _semantic_category_for_object(obj, int(instance.get("section_number", -1)))
		var scenery_bucket := _scenery_bucket_for_name(obj.get("name", ""))
		var mesh_key: String = ("%08x" % mesh_hash) if mesh_hash != 0 else String(obj.get("name", ""))
		var key := "%s:%s:%s" % [category, scenery_bucket, mesh_key]
		if not groups.has(key):
			groups[key] = {
				"entry": entry,
				"mesh_hash": mesh_hash,
				"category": category,
				"bucket": scenery_bucket,
				"source_role": _source_role_for_object(obj),
				"transforms": [],
			}
		groups[key]["transforms"].append(MathUtils.ps2_rows_to_godot_transform(instance.get("transform", [])))

	var placed := 0
	for key in groups.keys():
		var group: Dictionary = groups[key]
		var entry: Dictionary = group["entry"]
		var transforms: Array = group["transforms"]
		if transforms.is_empty():
			continue
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = entry["mesh"]
		multimesh.instance_count = transforms.size()
		for index in range(transforms.size()):
			multimesh.set_instance_transform(index, transforms[index])

		var obj: Dictionary = entry["object"]
		var category: String = group.get("category", "PROP")
		var scenery_bucket: String = group.get("bucket", "Props")
		var parent := _parent_for_category(category, static_roots, scenery_roots, environment_root, marker_root, scenery_bucket)
		var node := MultiMeshInstance3D.new()
		node.name = _safe_node_name(obj.get("name", "Scenery_%s" % key))
		node.multimesh = multimesh
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
		node.set_meta("eagl_object_name", obj.get("name", ""))
		node.set_meta("eagl_object_hash", group.get("mesh_hash", 0))
		node.set_meta("eagl_instance_count", transforms.size())
		node.set_meta("eagl_source_role", group.get("source_role", "UNKNOWN"))
		node.set_meta("eagl_placement_kind", "SCENERY_INSTANCE")
		node.set_meta("bun_category", category)
		node.set_meta("eagl_scenery_bucket", scenery_bucket)
		parent.add_child(node)
		placed += transforms.size()
		scenery_multimesh_count += 1
		if category == "ENVIRONMENT":
			environment_object_count += transforms.size()
		elif category == "TRACK_MARKER":
			track_marker_count += transforms.size()
	return placed


func _mesh_entry_for_instance(instance: Dictionary, mesh_cache: Dictionary):
	var object_hash := int(instance.get("object_hash", 0))
	if object_hash != 0 and mesh_cache["by_hash"].has(object_hash):
		return mesh_cache["by_hash"][object_hash]
	var object_name: String = instance.get("object_name", "")
	if object_name != "" and mesh_cache["by_name"].has(object_name):
		return mesh_cache["by_name"][object_name]
	return null


func _surface_materials(mesh_node: MeshInstance3D) -> Array[Material]:
	var materials: Array[Material] = []
	for surface_index in range(mesh_node.get_surface_override_material_count()):
		materials.append(mesh_node.get_surface_override_material(surface_index))
	return materials


func _apply_surface_materials(mesh_node: MeshInstance3D, materials: Array) -> void:
	for surface_index in range(materials.size()):
		mesh_node.set_surface_override_material(surface_index, materials[surface_index])


func _add_unknown_chunk_nodes(parent: Node, asset) -> void:
	parent.set_meta("eagl_unknown_chunks", asset.unknown_chunks.duplicate(true))
	for index in range(asset.unknown_chunks.size()):
		var chunk: Dictionary = asset.unknown_chunks[index]
		var node := Node.new()
		node.name = "Chunk_%08x_%04d" % [int(chunk.get("id", 0)), index]
		node.set_meta("eagl_chunk_id", chunk.get("id", 0))
		node.set_meta("eagl_offset", chunk.get("offset", -1))
		node.set_meta("eagl_size", chunk.get("size", 0))
		node.set_meta("eagl_parent_chunk_id", chunk.get("parent_id", 0))
		node.set_meta("eagl_parent_offset", chunk.get("parent_offset", -1))
		parent.add_child(node)


func _instanced_names(asset) -> Dictionary:
	var instanced_names := {}
	for instance in asset.scenery_instances:
		var object_name: String = instance.get("object_name", "")
		if object_name != "":
			instanced_names[object_name] = true
	return instanced_names


func _semantic_category_for_object(obj: Dictionary, _section_number: int = -1) -> String:
	var name := String(obj.get("name", "")).to_upper()
	if name.begins_with("SKYDOME") or name == "WATER" or name.contains("ENVMAP"):
		return "ENVIRONMENT"
	if name.begins_with("TRACK") and name.contains("STARTLINE"):
		return "TRACK_MARKER"
	if name.begins_with("RD_") or name.begins_with("DIRTRD_"):
		return "ROAD"
	if name.begins_with("TRN_"):
		return "TERRAIN"
	if name.begins_with("SHD_") or name.begins_with("SH_"):
		return "SHADOW"
	if name.contains("BRIDGE") or name == "MARTINSPEAK":
		return "LANDMARK"
	if bool(obj.get("is_scenery_template", false)):
		return "PROP"
	if name.begins_with("XS_") or name.begins_with("XT_") or name.begins_with("XW_") or name.begins_with("XB_") or name.begins_with("XH_") or name.begins_with("XF_"):
		return "PROP"
	return "STATIC_DETAIL"


func _should_render_object(obj: Dictionary) -> bool:
	var name := String(obj.get("name", "")).to_upper()
	if name == "SKYDOME_ENVMAP" or name.contains("ENVMAP"):
		return false
	return true


func _source_role_for_object(obj: Dictionary) -> String:
	if obj.has("source_role"):
		return obj.get("source_role", "UNKNOWN")
	if bool(obj.get("is_scenery_template", false)):
		return "TEMPLATE_PALETTE"
	if _semantic_category_for_object(obj) in ["ENVIRONMENT", "TRACK_MARKER"]:
		return "SPECIAL_SOLID_PACK"
	return "STATIC_SOLID_PACK"


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


func _count_semantic_node(category: String) -> void:
	if category == "ENVIRONMENT":
		environment_object_count += 1
	elif category == "TRACK_MARKER":
		track_marker_count += 1


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


func _merge_builder_diagnostics() -> void:
	for reason in mesh_builder.skipped.keys():
		skipped[reason] = skipped.get(reason, 0) + int(mesh_builder.skipped[reason])
	mesh_builder.skipped.clear()
	for message in mesh_builder.warnings:
		warnings.append(message)
	mesh_builder.warnings.clear()


func _count_skip(reason: String) -> void:
	skipped[reason] = skipped.get(reason, 0) + 1


func _assign_sun_light_cull_layer(node: Node) -> void:
	if node is GeometryInstance3D:
		var geometry := node as GeometryInstance3D
		geometry.layers = geometry.layers | SUN_LIGHT_CULL_MASK
	for child in node.get_children():
		_assign_sun_light_cull_layer(child)


func _node_bounds(node: Node3D) -> AABB:
	var result := _node_bounds_recursive(node, Transform3D.IDENTITY)
	return result["bounds"] if bool(result["found"]) else AABB()


func _node_bounds_recursive(node: Node, parent_transform: Transform3D) -> Dictionary:
	var node_transform := parent_transform
	if node is Node3D:
		node_transform = parent_transform * (node as Node3D).transform

	var bounds := AABB()
	var found := false
	if node is MeshInstance3D:
		var mesh_aabb := (node as MeshInstance3D).get_aabb()
		if mesh_aabb.size != Vector3.ZERO:
			bounds = node_transform * mesh_aabb
			found = true
	elif node is MultiMeshInstance3D:
		var multimesh_aabb := (node as MultiMeshInstance3D).get_aabb()
		if multimesh_aabb.size != Vector3.ZERO:
			bounds = node_transform * multimesh_aabb
			found = true

	for child in node.get_children():
		var child_result := _node_bounds_recursive(child, node_transform)
		if not bool(child_result["found"]):
			continue
		if not found:
			bounds = child_result["bounds"]
			found = true
		else:
			bounds = bounds.merge(child_result["bounds"])
	return {
		"found": found,
		"bounds": bounds,
	}


func _safe_node_name(value: String) -> String:
	var out := value
	for token in [":", "/", "\\", "@"]:
		out = out.replace(token, "_")
	return out
