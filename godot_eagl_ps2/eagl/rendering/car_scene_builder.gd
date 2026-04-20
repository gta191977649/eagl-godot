class_name EAGLCarSceneBuilder
extends RefCounted

const MeshBuilderScript := preload("res://eagl/rendering/mesh_builder.gd")
const MathUtils := preload("res://eagl/utils/math_utils.gd")
const CarControllerScript := preload("res://eagl/assets/car/eagl_car_controller_3d.gd")

var mesh_builder := MeshBuilderScript.new()
var skipped: Dictionary = {}
var warnings: Array[String] = []


func build_car_scene(asset, options: Dictionary = {}) -> Node3D:
	mesh_builder.texture_bank = asset.texture_bank
	mesh_builder.texture_filter_mode = String(options.get("texture_filter_mode", "linear_mipmap"))
	mesh_builder.material_library = asset.material_library
	mesh_builder.generate_lods = bool(options.get("generate_lods", true))
	mesh_builder.reset()
	skipped.clear()
	warnings.clear()

	var root := Node3D.new()
	root.name = "EAGL_Car_%s" % asset.car_id
	root.set_meta("eagl_asset_type", "car")
	root.set_meta("eagl_car_id", asset.car_id)
	root.set_meta("eagl_source_path", asset.source_path)
	root.set_meta("eagl_physics_tuning", asset.physics_tuning.duplicate(true))
	root.set_meta("eagl_handling_data", asset.handling_data.duplicate(true))

	var visual_root := Node3D.new()
	visual_root.name = "Visual"
	root.add_child(visual_root)

	var group_roots := _create_group_roots(visual_root)
	var built := 0
	var hidden_variants := 0
	var show_all_variants := bool(options.get("show_all_car_variants", options.get("show_all_car_lods", false)))
	var show_wheel_blur := bool(options.get("show_wheel_blur", false))
	var tire_objects: Array[Dictionary] = []
	var brake_objects: Array[Dictionary] = []
	for obj in asset.objects:
		if _is_wheel_blur_object(obj) and not show_wheel_blur:
			hidden_variants += 1
			_count_skip("wheel_blur_disabled")
			continue
		if not show_all_variants and not bool(obj.get("render_default", true)):
			hidden_variants += 1
			_count_skip("hidden_car_variant")
			continue
		if not show_all_variants and _is_tire_object(obj):
			tire_objects.append(obj)
			continue
		if not show_all_variants and _is_brake_object(obj):
			brake_objects.append(obj)
			continue
		if _add_object_node(group_roots, obj):
			built += 1
	if not show_all_variants:
		built += _add_wheel_instances(group_roots, asset, tire_objects)
		built += _add_brake_instances(group_roots, asset, brake_objects)
	for obj in asset.dashboard_objects:
		if _add_object_node(group_roots, obj):
			built += 1

	var local_bounds := _node_bounds(visual_root)
	var visual_offset := _normalize_visual_root(visual_root, local_bounds, asset.physics_tuning)
	var bounds := AABB(local_bounds.position + visual_offset, local_bounds.size) if local_bounds.size != Vector3.ZERO else AABB()

	var controller = CarControllerScript.new()
	controller.name = "EAGLCarController3D"
	controller.tuning = asset.physics_tuning.duplicate(true)
	controller.handling_data = asset.handling_data.duplicate(true)
	controller.visual_root_path = NodePath("../Visual")
	root.add_child(controller)
	controller.owner = root.owner

	asset.missing_texture_hashes = mesh_builder.missing_texture_hashes.duplicate()
	asset.missing_texture_surfaces = mesh_builder.missing_texture_surfaces.duplicate(true)
	asset.bounds = bounds
	asset.has_bounds = bounds.size != Vector3.ZERO
	root.set_meta("eagl_visual_offset", visual_offset)
	root.set_meta("eagl_rendered_object_count", built)
	root.set_meta("eagl_hidden_variant_count", hidden_variants)
	root.set_meta("eagl_show_all_car_variants", show_all_variants)
	root.set_meta("eagl_wheel_blur_enabled", show_wheel_blur)
	root.set_meta("eagl_wheel_instance_count", _wheel_instance_count(visual_root))
	root.set_meta("eagl_brake_instance_count", _assembled_instance_count(visual_root, "assembled_brake_instance"))
	root.set_meta("eagl_wheel_slot_count", asset.wheel_slots.size())
	root.set_meta("eagl_wheel_slot_source", asset.wheel_slot_source)
	root.set_meta("eagl_exact_handling_status", asset.exact_handling_status)
	root.set_meta("eagl_runtime_part_counts", asset.runtime_parts.get("counts", {}).duplicate(true))
	root.set_meta("eagl_object_count", asset.objects.size())
	root.set_meta("eagl_dashboard_object_count", asset.dashboard_objects.size())
	root.set_meta("eagl_block_count", asset.block_count())
	root.set_meta("eagl_vertex_count", asset.vertex_count())
	root.set_meta("eagl_texture_ref_count", asset.texture_ref_count())
	root.set_meta("eagl_texture_count", asset.texture_bank.decoded_count if asset.texture_bank != null else 0)
	root.set_meta("eagl_locator_count", asset.locators.size())
	root.set_meta("eagl_locators", asset.locators.duplicate(true))
	root.set_meta("eagl_part_groups", asset.part_groups.duplicate(true))
	root.set_meta("eagl_bounds", bounds)
	root.set_meta("eagl_skipped", skipped.duplicate(true))
	root.set_meta("eagl_textured_surface_count", mesh_builder.textured_surfaces)
	root.set_meta("eagl_fallback_surface_count", mesh_builder.fallback_surfaces)
	root.set_meta("eagl_uv_surface_count", mesh_builder.uv_surfaces)
	root.set_meta("eagl_textured_missing_uv_surface_count", mesh_builder.textured_missing_uv_surfaces)
	root.set_meta("eagl_lod_surface_count", mesh_builder.lod_surface_count)
	root.set_meta("eagl_missing_texture_hashes", mesh_builder.missing_texture_hashes.duplicate())
	root.set_meta("eagl_missing_texture_surface_count", mesh_builder.missing_texture_surfaces.size())
	return root


func _normalize_visual_root(visual_root: Node3D, bounds: AABB, tuning: Dictionary) -> Vector3:
	if bounds.size == Vector3.ZERO:
		return Vector3.ZERO
	var center := bounds.position + bounds.size * 0.5
	var suspension_height := float(tuning.get("suspension_height", 0.75))
	var offset := Vector3(-center.x, -bounds.position.y - suspension_height, -center.z)
	visual_root.position = offset
	return offset


func _create_group_roots(parent: Node3D) -> Dictionary:
	var out := {}
	for group_name in ["Body", "Wheels", "Brakes", "GlassLightsDamage", "ShadowBlur", "Dashboard"]:
		var node := Node3D.new()
		node.name = group_name
		parent.add_child(node)
		out[group_name] = node
	return out


func _add_object_node(group_roots: Dictionary, obj: Dictionary) -> bool:
	var mesh_node := mesh_builder.build_object_mesh(obj, false)
	if mesh_node == null:
		_count_skip("empty_car_mesh")
		return false
	var group: String = obj.get("part_group", "Body")
	var parent: Node3D = group_roots.get(group, group_roots["Body"])
	var object_name: String = obj.get("name", "CarPart")
	var node := MeshInstance3D.new()
	node.name = _safe_node_name(object_name)
	node.mesh = mesh_node.mesh
	for surface_index in range(mesh_node.mesh.get_surface_count()):
		node.set_surface_override_material(surface_index, mesh_node.get_surface_override_material(surface_index))
	node.transform = MathUtils.hp2_car_rows_to_godot_transform(obj.get("transform", []))
	node.set_meta("eagl_object_name", object_name)
	node.set_meta("eagl_chunk_offset", obj.get("chunk_offset", 0))
	node.set_meta("eagl_solid_pack_index", obj.get("solid_pack_index", -1))
	node.set_meta("eagl_part_group", group)
	node.set_meta("eagl_is_dashboard", obj.get("is_dashboard", false))
	node.set_meta("eagl_render_default", obj.get("render_default", true))
	node.set_meta("eagl_variant_role", obj.get("variant_role", ""))
	node.set_meta("eagl_visual_transform_mode", obj.get("visual_transform_mode", ""))
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
	parent.add_child(node)
	return true


func _add_wheel_instances(group_roots: Dictionary, asset, tire_objects: Array[Dictionary]) -> int:
	var wheel_slots: Array = asset.wheel_slots
	if wheel_slots.size() < 4 or tire_objects.is_empty():
		var fallback_count := 0
		for obj in tire_objects:
			if _add_object_node(group_roots, obj):
				fallback_count += 1
		return fallback_count

	var front_obj := _tire_object_for_axle(tire_objects, "front")
	var rear_obj := _tire_object_for_axle(tire_objects, "rear")
	if front_obj.is_empty() and rear_obj.is_empty():
		return 0

	var built := 0
	for slot in wheel_slots:
		var slot_dict: Dictionary = slot
		var axle := String(slot_dict.get("axle", "front"))
		var source_obj := front_obj if axle == "front" else rear_obj
		if source_obj.is_empty():
			source_obj = front_obj if not front_obj.is_empty() else rear_obj
		if source_obj.is_empty():
			continue
		if _add_wheel_instance(group_roots, source_obj, slot_dict):
			built += 1
	return built


func _add_wheel_instance(group_roots: Dictionary, obj: Dictionary, slot: Dictionary) -> bool:
	var mesh_node := mesh_builder.build_object_mesh(obj, false)
	if mesh_node == null:
		_count_skip("empty_wheels_mesh")
		return false
	var parent: Node3D = group_roots.get("Wheels", group_roots["Body"])
	var object_name: String = obj.get("name", "Tire")
	var slot_id := _slot_id(slot)
	var slot_pivot := Node3D.new()
	slot_pivot.name = _safe_node_name("WheelSlot_%s" % slot_id)
	slot_pivot.position = slot.get("position_godot", Vector3.ZERO)
	_set_runtime_slot_meta(slot_pivot, object_name, slot, "Wheels", "wheel", "assembled_wheel_instance")
	parent.add_child(slot_pivot)

	var steer_pivot := Node3D.new()
	steer_pivot.name = "SteerPivot"
	steer_pivot.set_meta("eagl_runtime_part", "wheel")
	steer_pivot.set_meta("eagl_steer_pivot", bool(slot.get("is_front", String(slot.get("axle", "")) == "front")))
	steer_pivot.set_meta("eagl_wheel_slot_id", slot_id)
	steer_pivot.set_meta("eagl_wheel_slot", slot.duplicate(true))
	slot_pivot.add_child(steer_pivot)

	var spin_pivot := Node3D.new()
	spin_pivot.name = "SpinPivot"
	spin_pivot.set_meta("eagl_runtime_part", "wheel")
	spin_pivot.set_meta("eagl_spin_pivot", true)
	spin_pivot.set_meta("eagl_wheel_slot_id", slot_id)
	spin_pivot.set_meta("eagl_wheel_slot", slot.duplicate(true))
	spin_pivot.set_meta("eagl_is_front_wheel", bool(slot.get("is_front", String(slot.get("axle", "")) == "front")))
	spin_pivot.set_meta("eagl_spin_direction", 1.0)
	steer_pivot.add_child(spin_pivot)

	var node := _mesh_instance_from_source(mesh_node, "Mesh")
	var mesh_bounds := node.get_aabb()
	_orient_runtime_mesh(node, slot, mesh_bounds)
	node.set_meta("eagl_runtime_part", "wheel_mesh")
	node.set_meta("eagl_wheel_slot_id", slot_id)
	spin_pivot.add_child(node)
	return true


func _add_brake_instances(group_roots: Dictionary, asset, brake_objects: Array[Dictionary]) -> int:
	var brake_slots: Array = asset.brake_slots
	if brake_slots.size() < 4 or brake_objects.is_empty():
		var fallback_count := 0
		for obj in brake_objects:
			if _add_object_node(group_roots, obj):
				fallback_count += 1
		return fallback_count

	var front_obj := _axle_object_for_token(brake_objects, "BRAKE_FRONT")
	var rear_obj := _axle_object_for_token(brake_objects, "BRAKE_REAR")
	if front_obj.is_empty() and rear_obj.is_empty():
		return 0

	var built := 0
	for slot in brake_slots:
		var slot_dict: Dictionary = slot
		var axle := String(slot_dict.get("axle", "front"))
		var source_obj := front_obj if axle == "front" else rear_obj
		if source_obj.is_empty():
			source_obj = front_obj if not front_obj.is_empty() else rear_obj
		if source_obj.is_empty():
			continue
		if _add_brake_instance(group_roots, source_obj, slot_dict):
			built += 1
	return built


func _add_brake_instance(group_roots: Dictionary, obj: Dictionary, slot: Dictionary) -> bool:
	var mesh_node := mesh_builder.build_object_mesh(obj, false)
	if mesh_node == null:
		_count_skip("empty_brakes_mesh")
		return false
	var parent: Node3D = group_roots.get("Brakes", group_roots["Body"])
	var object_name: String = obj.get("name", "Brake")
	var slot_id := _slot_id(slot)
	var slot_pivot := Node3D.new()
	slot_pivot.name = _safe_node_name("BrakeSlot_%s" % slot_id)
	slot_pivot.position = slot.get("position_godot", Vector3.ZERO)
	_set_runtime_slot_meta(slot_pivot, object_name, slot, "Brakes", "brake", "assembled_brake_instance")
	parent.add_child(slot_pivot)

	var steer_pivot := Node3D.new()
	steer_pivot.name = "SteerPivot"
	steer_pivot.set_meta("eagl_runtime_part", "brake")
	steer_pivot.set_meta("eagl_steer_pivot", bool(slot.get("is_front", String(slot.get("axle", "")) == "front")))
	steer_pivot.set_meta("eagl_wheel_slot_id", slot_id)
	steer_pivot.set_meta("eagl_wheel_slot", slot.duplicate(true))
	slot_pivot.add_child(steer_pivot)

	var node := _mesh_instance_from_source(mesh_node, "Mesh")
	var mesh_bounds := node.get_aabb()
	_orient_runtime_mesh(node, slot, mesh_bounds)
	node.set_meta("eagl_runtime_part", "brake_mesh")
	node.set_meta("eagl_wheel_slot_id", slot_id)
	steer_pivot.add_child(node)
	return true


func _add_assembled_slot_instance(group_roots: Dictionary, obj: Dictionary, slot: Dictionary, group_name: String, variant_role: String) -> bool:
	var mesh_node := mesh_builder.build_object_mesh(obj, false)
	if mesh_node == null:
		_count_skip("empty_%s_mesh" % group_name.to_lower())
		return false
	var parent: Node3D = group_roots.get(group_name, group_roots["Body"])
	var object_name: String = obj.get("name", "Tire")
	var slot_name := String(slot.get("name", "wheel"))
	var pivot := Node3D.new()
	pivot.name = _safe_node_name("%s_%s" % [object_name, slot_name])
	pivot.position = slot.get("position_godot", Vector3.ZERO)
	pivot.set_meta("eagl_object_name", "%s_%s" % [object_name, slot_name.to_upper()])
	pivot.set_meta("eagl_source_object_name", object_name)
	pivot.set_meta("eagl_part_group", group_name)
	pivot.set_meta("eagl_wheel_slot", slot.duplicate(true))
	pivot.set_meta("eagl_variant_role", variant_role)
	parent.add_child(pivot)

	var node := MeshInstance3D.new()
	node.name = "Mesh"
	node.mesh = mesh_node.mesh
	for surface_index in range(mesh_node.mesh.get_surface_count()):
		node.set_surface_override_material(surface_index, mesh_node.get_surface_override_material(surface_index))
	var mesh_bounds := node.get_aabb()
	node.position = -(mesh_bounds.position + mesh_bounds.size * 0.5)
	if String(slot.get("side", "")) == "right":
		node.scale.x = -1.0
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
	pivot.add_child(node)
	return true


func _set_runtime_slot_meta(node: Node3D, object_name: String, slot: Dictionary, group_name: String, runtime_part: String, variant_role: String) -> void:
	var slot_id := _slot_id(slot)
	node.set_meta("eagl_object_name", "%s_%s" % [object_name, slot_id])
	node.set_meta("eagl_source_object_name", object_name)
	node.set_meta("eagl_part_group", group_name)
	node.set_meta("eagl_runtime_part", runtime_part)
	node.set_meta("eagl_wheel_slot_id", slot_id)
	node.set_meta("eagl_wheel_slot", slot.duplicate(true))
	node.set_meta("eagl_variant_role", variant_role)


func _mesh_instance_from_source(mesh_node: MeshInstance3D, node_name: String) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = mesh_node.mesh
	for surface_index in range(mesh_node.mesh.get_surface_count()):
		node.set_surface_override_material(surface_index, mesh_node.get_surface_override_material(surface_index))
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
	return node


func _orient_runtime_mesh(node: MeshInstance3D, slot: Dictionary, mesh_bounds: AABB) -> void:
	var side := String(slot.get("side", "")).to_lower()
	var rotate_outer_face := side == "left"
	node.rotation.y = -PI if rotate_outer_face else 0.0
	node.scale = Vector3.ONE
	var mesh_center := mesh_bounds.position + mesh_bounds.size * 0.5
	node.position = -(node.transform.basis * mesh_center)
	node.set_meta("eagl_runtime_mesh_outer_face_rotation_y", node.rotation.y)
	node.set_meta("eagl_runtime_mesh_center_offset", node.position)


func _slot_id(slot: Dictionary) -> String:
	var existing := String(slot.get("slot_id", ""))
	if existing != "":
		return existing
	var axle := String(slot.get("axle", "front")).to_lower()
	var side := String(slot.get("side", "left")).to_lower()
	if axle == "front":
		return "FR" if side == "right" else "FL"
	return "RR" if side == "right" else "RL"


func _is_tire_object(obj: Dictionary) -> bool:
	var name := String(obj.get("name", "")).to_upper()
	return name.contains("TIRE_FRONT") or name.contains("TIRE_REAR")


func _is_brake_object(obj: Dictionary) -> bool:
	var name := String(obj.get("name", "")).to_upper()
	return name.contains("BRAKE_FRONT") or name.contains("BRAKE_REAR")


func _is_wheel_blur_object(obj: Dictionary) -> bool:
	var name := String(obj.get("name", "")).to_upper()
	return name.contains("WHEEL_BLUR")


func _tire_object_for_axle(tire_objects: Array[Dictionary], axle: String) -> Dictionary:
	var token := "TIRE_FRONT" if axle == "front" else "TIRE_REAR"
	return _axle_object_for_token(tire_objects, token)


func _axle_object_for_token(objects: Array[Dictionary], token: String) -> Dictionary:
	for obj in objects:
		var name := String(obj.get("name", "")).to_upper()
		if name.contains(token) and (name.ends_with("_A") or not (name.ends_with("_B") or name.ends_with("_C") or name.ends_with("_D"))):
			return obj
	for obj in objects:
		var name := String(obj.get("name", "")).to_upper()
		if name.contains(token):
			return obj
	return {}


func _wheel_instance_count(visual_root: Node) -> int:
	return _assembled_instance_count(visual_root, "assembled_wheel_instance")


func _assembled_instance_count(visual_root: Node, variant_role: String) -> int:
	var count := 0
	for node in visual_root.find_children("*", "Node3D", true, false):
		if String(node.get_meta("eagl_variant_role", "")) == variant_role:
			count += 1
	return count


func _node_bounds(root: Node) -> AABB:
	var result := _node_bounds_recursive(root, Transform3D.IDENTITY)
	return result.get("bounds", AABB()) if bool(result.get("has_bounds", false)) else AABB()


func _node_bounds_recursive(node: Node, parent_transform: Transform3D) -> Dictionary:
	var node_transform := parent_transform
	if node is Node3D:
		node_transform = parent_transform * (node as Node3D).transform
	var has_bounds := false
	var bounds := AABB()
	if node is VisualInstance3D:
		var visual := node as VisualInstance3D
		bounds = node_transform * visual.get_aabb()
		has_bounds = true
	for child in node.get_children():
		var child_result := _node_bounds_recursive(child, node_transform)
		if not bool(child_result.get("has_bounds", false)):
			continue
		var child_bounds: AABB = child_result["bounds"]
		if not has_bounds:
			bounds = child_bounds
			has_bounds = true
		else:
			bounds = bounds.merge(child_bounds)
	return {"has_bounds": has_bounds, "bounds": bounds}


func _safe_node_name(value: String) -> String:
	var out := value
	for token in [":", "/", "\\", "@"]:
		out = out.replace(token, "_")
	return out


func _count_skip(reason: String) -> void:
	skipped[reason] = skipped.get(reason, 0) + 1
