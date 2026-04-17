class_name EaglTrackLoader
extends RefCounted

const EaglGodotSceneBuilder = preload("res://track_debug/eagl_loader/EaglGodotSceneBuilder.gd")
const EaglLayerPolicy = preload("res://track_debug/eagl_loader/EaglLayerPolicy.gd")
const EaglMaterialFactory = preload("res://track_debug/eagl_loader/EaglMaterialFactory.gd")
const EaglTextureBank = preload("res://track_debug/eagl_loader/EaglTextureBank.gd")
const EaglTrackRoute = preload("res://track_debug/eagl_loader/EaglTrackRoute.gd")
const HP2_RENDER_STATE_RADIUS = 1

var route = EaglTrackRoute.new()
var texture_bank = EaglTextureBank.new()
var level_texture_bank = EaglTextureBank.new()
var scene_builder = EaglGodotSceneBuilder.new()
var material_factory = EaglMaterialFactory.new()
var level_material_factory = EaglMaterialFactory.new()
var skipped = {}
var warnings: Array[String] = []
var layer_counts = {}
var frustum_culled_meshes = 0
var loaded_compartments: Dictionary = {}
var level_nodes: Array[Node3D] = []


func load_track(tracks_root: String, track_name: String, level_index: int) -> Node3D:
	_reset()
	if not route.load_route(tracks_root, track_name, level_index):
		return _error_node(route.error)
	texture_bank.load_base(route.track_dir)
	level_texture_bank.load_for_route(route.track_dir, route.level_dir)
	_collect_texture_warnings()
	var root = scene_builder.build_track_root(track_name, level_index)
	_load_compartments(root)
	_load_level_g(root)
	_collect_scene_builder_diagnostics()
	return root


func set_route_visibility(route_index: int, radius: int, layer_mode: String, camera: Camera3D = null, use_frustum_culling: bool = false) -> Array[int]:
	var active = route.unique_compartments() if radius < 0 else route.active_compartments(route_index, max(radius, HP2_RENDER_STATE_RADIUS))
	_apply_route_visibility(active, layer_mode, camera, use_frustum_culling)
	return active


func set_route_visibility_for_indices(route_indices: Array[int], layer_mode: String, camera: Camera3D = null, use_frustum_culling: bool = false) -> Array[int]:
	var active = route.compartments_for_route_indices(route_indices)
	_apply_route_visibility(active, layer_mode, camera, use_frustum_culling)
	return active


func _apply_route_visibility(active: Array[int], layer_mode: String, camera: Camera3D, use_frustum_culling: bool) -> void:
	for comp_id in loaded_compartments.keys():
		loaded_compartments[comp_id].visible = active.has(comp_id)
	_apply_render_visibility(layer_mode, camera, use_frustum_culling)


func stats() -> Dictionary:
	return {
		"skipped": skipped,
		"textures": level_texture_bank.textures.size(),
		"decoded_images": level_texture_bank.decoded_images,
		"skipped_images": level_texture_bank.skipped_images,
		"missing_textures": material_factory.missing_textures + level_material_factory.missing_textures,
		"frustum_culled_meshes": frustum_culled_meshes
	}


func nearest_route_index(position: Vector3) -> int:
	return route.nearest_route_index(position)


func nearest_route_index_from(position: Vector3, current_index: int) -> int:
	return route.nearest_route_index_from(position, current_index)


func _reset() -> void:
	skipped.clear()
	warnings.clear()
	layer_counts.clear()
	frustum_culled_meshes = 0
	loaded_compartments.clear()
	level_nodes.clear()
	texture_bank.reset()
	level_texture_bank.reset()
	scene_builder.reset()
	material_factory.reset()
	level_material_factory.reset()


func _load_compartments(root: Node3D) -> void:
	for comp_id in route.unique_compartments():
		var path: String = route.track_dir.path_join("comp%02d.o" % comp_id)
		if not FileAccess.file_exists(path):
			_count_skip("missing_compartment")
			_warn("missing compartment file %s" % path)
			continue
		var node = scene_builder.build_object(path, {}, texture_bank, material_factory)
		node.name = "comp%02d" % comp_id
		root.add_child(node)
		loaded_compartments[comp_id] = node


func sync_route_node_anchors() -> void:
	# Compartment AABBs are not HP2 route regions; keep drvpath nodes in route-distance order.
	route.use_default_route_node_anchors()


func _load_level_g(root: Node3D) -> void:
	var path: String = route.level_dir.path_join("levelG.o")
	if not FileAccess.file_exists(path):
		_warn("missing level geometry file %s" % path)
		return
	var include = {}
	for model_id in route.levelft_ids:
		include["levelft.%s" % model_id] = true
	var node = scene_builder.build_object(path, include, level_texture_bank, level_material_factory)
	node.name = "levelG_selected"
	root.add_child(node)
	level_nodes.append(node)


func _apply_render_visibility(layer_mode: String, camera: Camera3D, use_frustum_culling: bool) -> void:
	frustum_culled_meshes = 0
	for node in loaded_compartments.values():
		_apply_render_visibility_to(node, layer_mode, node.visible, camera, use_frustum_culling)
	for node in level_nodes:
		_apply_render_visibility_to(node, layer_mode, true, camera, use_frustum_culling)


func _apply_render_visibility_to(node: Node, layer_mode: String, inherited_layer_visible: bool, camera: Camera3D, use_frustum_culling: bool) -> void:
	var layer_visible = inherited_layer_visible
	if node.has_meta("eagl_layer"):
		layer_visible = inherited_layer_visible and EaglLayerPolicy.layer_visible(node.get_meta("eagl_layer"), layer_mode)
		node.visible = layer_visible
	if node is MeshInstance3D:
		var in_frustum = not use_frustum_culling or camera == null or _mesh_in_camera_frustum(node, camera)
		node.visible = layer_visible and in_frustum
		if layer_visible and not in_frustum:
			frustum_culled_meshes += 1
	for child in node.get_children():
		_apply_render_visibility_to(child, layer_mode, layer_visible, camera, use_frustum_culling)


func _mesh_in_camera_frustum(mesh: MeshInstance3D, camera: Camera3D) -> bool:
	var local_bounds = mesh.get_aabb()
	if local_bounds.size == Vector3.ZERO:
		return true
	var bounds = mesh.global_transform * local_bounds
	return _aabb_in_camera_projection(bounds, camera)


func _node_bounds(node: Node3D) -> AABB:
	var bounds = AABB()
	var found = false
	for mesh in node.find_children("*", "MeshInstance3D", true, false):
		var mesh_aabb: AABB = mesh.get_aabb()
		mesh_aabb = mesh.global_transform * mesh_aabb
		if not found:
			bounds = mesh_aabb
			found = true
		else:
			bounds = bounds.merge(mesh_aabb)
	return bounds if found else AABB()


func _aabb_in_camera_projection(bounds: AABB, camera: Camera3D) -> bool:
	var viewport = camera.get_viewport()
	if viewport == null:
		return true
	var rect = Rect2(Vector2.ZERO, viewport.get_visible_rect().size).grow(32.0)
	var corners = _aabb_corners(bounds)
	var all_behind = true
	var has_behind = false
	var any_in_rect = false
	var all_left = true
	var all_right = true
	var all_above = true
	var all_below = true
	for corner in corners:
		if camera.is_position_behind(corner):
			has_behind = true
			continue
		all_behind = false
		var projected = camera.unproject_position(corner)
		if rect.has_point(projected):
			any_in_rect = true
		if projected.x >= rect.position.x:
			all_left = false
		if projected.x <= rect.end.x:
			all_right = false
		if projected.y >= rect.position.y:
			all_above = false
		if projected.y <= rect.end.y:
			all_below = false
	if all_behind:
		return false
	if has_behind:
		return true
	if any_in_rect:
		return true
	return not (all_left or all_right or all_above or all_below)


func _aabb_corners(bounds: AABB) -> Array[Vector3]:
	return [
		bounds.position,
		Vector3(bounds.end.x, bounds.position.y, bounds.position.z),
		Vector3(bounds.position.x, bounds.end.y, bounds.position.z),
		Vector3(bounds.position.x, bounds.position.y, bounds.end.z),
		Vector3(bounds.end.x, bounds.end.y, bounds.position.z),
		Vector3(bounds.end.x, bounds.position.y, bounds.end.z),
		Vector3(bounds.position.x, bounds.end.y, bounds.end.z),
		bounds.end
	]


func _count_skip(reason: String) -> void:
	skipped[reason] = skipped.get(reason, 0) + 1


func _warn(message: String) -> void:
	warnings.append(message)


func _collect_texture_warnings() -> void:
	for message in texture_bank.errors:
		_warn("base texture bank: %s" % message)
	for message in level_texture_bank.errors:
		_warn("level texture bank: %s" % message)


func _collect_scene_builder_diagnostics() -> void:
	for reason in scene_builder.skipped.keys():
		skipped[reason] = skipped.get(reason, 0) + int(scene_builder.skipped[reason])
	for message in scene_builder.warnings:
		_warn(message)
	for layer_name in scene_builder.layer_counts.keys():
		layer_counts[layer_name] = layer_counts.get(layer_name, 0) + int(scene_builder.layer_counts[layer_name])


func _error_node(message: String) -> Node3D:
	var node = Node3D.new()
	node.name = "EaglLoaderError"
	node.set_meta("error", message)
	return node
