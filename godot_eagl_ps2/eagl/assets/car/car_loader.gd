class_name CarLoader
extends RefCounted

const CarParserPS2Script = preload("res://eagl/assets/car/car_parser_ps2.gd")
const MeshBuilderScript = preload("res://eagl/rendering/mesh_builder.gd")
const MathUtils = preload("res://eagl/utils/math_utils.gd")

const SLOT_IDS := ["FL", "FR", "RL", "RR"]
const TIRE_DETAIL_SUFFIXES := ["A", "B", "C"]
const VISUAL_PIVOT_MAX_LONGITUDINAL_DELTA_PS2 := 0.18
const VISUAL_PIVOT_MAX_LATERAL_DELTA_PS2 := 0.18
const VISUAL_PIVOT_MAX_VERTICAL_DELTA_PS2 := 0.14

var parser = CarParserPS2Script.new()
var mesh_builder = MeshBuilderScript.new()
var root_path := ""
var last_error := ""


func _init(_root_path: String = "") -> void:
	root_path = _root_path


func load(car_id: String, config = null):
	var asset = load_asset(car_id)
	if asset == null:
		return null
	return build_scene(asset, config)


func load_asset(car_id: String):
	last_error = ""
	var model_path := _resolve_car_model_path(car_id)
	if model_path == "":
		if last_error == "":
			last_error = "Could not resolve car model for %s" % car_id
		push_error(last_error)
		return null
	return parser.parse({
		"car_id": _normalized_car_id(car_id),
		"model": model_path,
	})


func build_scene(asset, config = null) -> Node3D:
	mesh_builder.texture_bank = null
	mesh_builder.generate_lods = false
	mesh_builder.reset()

	var root := Node3D.new()
	root.name = "CarVisual"
	root.set_meta("eagl_car_id", asset.car_id)
	root.set_meta("eagl_source_path", asset.source_path)
	root.set_meta("eagl_assembly_summary", asset.assembly_summary)
	root.set_meta("eagl_wheel_slots", asset.wheel_slots.duplicate(true))
	var primary_body_variant := _pick_primary_body_variant(asset)
	root.set_meta("eagl_primary_body_variant", primary_body_variant)
	if config != null:
		root.set_meta("eagl_vehicle_type_id", int(config.globalb_vehicle_type_id))
		root.set_meta("eagl_vehicle_class_id", int(config.globalb_vehicle_class_id))
		root.set_meta("eagl_handling_profile_id", int(config.globalb_handling_profile_id))
		root.set_meta("eagl_handling_profile_count", int(config.globalb_handling_profile_count))
		root.set_meta("eagl_handling_profile_sequence", Array(config.globalb_handling_profile_sequence))

	var body_root := Node3D.new()
	body_root.name = "Body"
	if config != null:
		body_root.position = _body_visual_offset_godot(config)
	root.add_child(body_root)

	var wheels_root := Node3D.new()
	wheels_root.name = "WheelPivots"
	root.add_child(wheels_root)

	var dummies_root := Node3D.new()
	dummies_root.name = "Dummies"
	root.add_child(dummies_root)

	var tire_meshes := _collect_named_meshes(asset, [
		"_TIRE_FRONT_A",
		"_TIRE_FRONT_B",
		"_TIRE_FRONT_C",
		"_TIRE_REAR_A",
		"_TIRE_REAR_B",
		"_TIRE_REAR_C",
	])
	var brake_meshes := _collect_named_meshes(asset, [
		"_BRAKE_FRONT",
		"_BRAKE_REAR",
	])
	var wheel_visual_selection := _select_normal_wheel_visuals(asset, tire_meshes, config)
	root.set_meta("eagl_wheel_visual_selection", _wheel_visual_selection_summary(wheel_visual_selection))

	for obj in asset.objects:
		var name := String(obj.get("name", ""))
		if not _should_include_static_mesh(name, asset.car_id, primary_body_variant):
			continue
		var node := mesh_builder.build_object_mesh(obj, false)
		if node == null:
			continue
		body_root.add_child(node)

	if config != null:
		_build_runtime_pivots(root, wheels_root, dummies_root, wheel_visual_selection, brake_meshes, asset.wheel_slots, config)

	root.set_meta("eagl_body_mesh_count", body_root.get_child_count())
	root.set_meta("eagl_wheel_pivot_names", _child_name_list(wheels_root))
	root.set_meta("eagl_dummy_names", _child_name_list(dummies_root))
	return root


func _build_runtime_pivots(root: Node3D, wheels_root: Node3D, dummies_root: Node3D, wheel_visual_selection: Dictionary, brake_meshes: Dictionary, wheel_slots: Array, config) -> void:
	var slot_metadata := _wheel_slot_metadata_by_id(wheel_slots, config)
	for index in range(SLOT_IDS.size()):
		if index >= config.wheel_local_positions_ps2.size():
			continue
		var slot_id: String = SLOT_IDS[index]
		var slot_info: Dictionary = slot_metadata.get(slot_id, {})
		var pivot_position_ps2: Vector3 = slot_info.get("resolved_visual_position_ps2", config.wheel_local_positions_ps2[index])
		var wheel_root := Node3D.new()
		wheel_root.name = slot_id
		wheel_root.position = MathUtils.ps2_to_godot_vec3(pivot_position_ps2)
		wheels_root.add_child(wheel_root)

		var suspension_root := Node3D.new()
		suspension_root.name = "Suspension"
		wheel_root.add_child(suspension_root)

		var steer_root := Node3D.new()
		steer_root.name = "Steer"
		suspension_root.add_child(steer_root)

		var roll_root := Node3D.new()
		roll_root.name = "Roll"
		var initial_base_yaw := _wheel_base_yaw(slot_info)
		roll_root.rotation.y = initial_base_yaw
		roll_root.set_meta("eagl_base_yaw", initial_base_yaw)
		roll_root.set_meta("eagl_slot_side", String(slot_info.get("side", "")))
		roll_root.set_meta("eagl_locator_orientation_index", int(slot_info.get("locator_orientation_index", -1)))
		steer_root.add_child(roll_root)

		var spin_root := Node3D.new()
		spin_root.name = "Spin"
		var spin_direction := _wheel_spin_direction(slot_info)
		spin_root.set_meta("eagl_spin_direction", spin_direction)
		spin_root.set_meta("eagl_slot_side", String(slot_info.get("side", "")))
		spin_root.set_meta("eagl_locator_orientation_index", int(slot_info.get("locator_orientation_index", -1)))
		roll_root.add_child(spin_root)

		var tire_selection: Dictionary = wheel_visual_selection.get(slot_id, {})
		var tire_template: MeshInstance3D = tire_selection.get("template", null)
		if tire_template != null:
			var tire_node := _duplicate_mesh_instance(tire_template, "Tire")
			tire_node.transform = _canonical_wheel_part_transform(tire_template)
			_match_tire_visual_radius(tire_node, float(config.wheel_radii[index]))
			tire_node.set_meta("eagl_source_object", tire_selection.get("object_name", ""))
			tire_node.set_meta("eagl_detail_suffix", tire_selection.get("detail_suffix", ""))
			tire_node.set_meta("eagl_detail_level", tire_selection.get("detail_level", -1))
			spin_root.add_child(tire_node)

		var brake_template: MeshInstance3D = _brake_template_for_slot(brake_meshes, slot_id)
		if brake_template != null:
			var brake_node := _duplicate_mesh_instance(brake_template, "Brake")
			steer_root.add_child(brake_node)

		var dummy := Node3D.new()
		dummy.name = "%s_PIVOT" % slot_id
		dummy.position = MathUtils.ps2_to_godot_vec3(pivot_position_ps2)
		dummies_root.add_child(dummy)

	var center_dummy := Node3D.new()
	center_dummy.name = "BODY_CENTER"
	center_dummy.position = _body_visual_offset_godot(config)
	dummies_root.add_child(center_dummy)


func _wheel_slot_metadata_by_id(wheel_slots: Array, config) -> Dictionary:
	var by_id := {}
	for slot in wheel_slots:
		var slot_dict: Dictionary = slot
		var slot_id := String(slot_dict.get("slot_id", ""))
		if slot_id == "":
			continue
		var merged := slot_dict.duplicate(true)
		var slot_index := SLOT_IDS.find(slot_id)
		var physics_position_ps2: Vector3 = config.wheel_local_positions_ps2[slot_index] if slot_index >= 0 and slot_index < config.wheel_local_positions_ps2.size() else Vector3.ZERO
		var visual_position_ps2: Vector3 = merged.get("position_ps2", physics_position_ps2)
		var resolved_visual_position_ps2 := _resolved_visual_pivot_position_ps2(physics_position_ps2, visual_position_ps2)
		merged["physics_position_ps2"] = physics_position_ps2
		merged["physics_position_godot"] = MathUtils.ps2_to_godot_vec3(physics_position_ps2)
		merged["visual_position_ps2"] = visual_position_ps2
		merged["visual_position_godot"] = MathUtils.ps2_to_godot_vec3(visual_position_ps2)
		merged["resolved_visual_position_ps2"] = resolved_visual_position_ps2
		merged["resolved_visual_position_godot"] = MathUtils.ps2_to_godot_vec3(resolved_visual_position_ps2)
		merged["position_ps2"] = resolved_visual_position_ps2
		merged["position_godot"] = MathUtils.ps2_to_godot_vec3(resolved_visual_position_ps2)
		merged["visual_position_source_resolved"] = "locator" if resolved_visual_position_ps2.is_equal_approx(visual_position_ps2) else "physics_hardpoint"
		by_id[slot_id] = merged
	for index in range(SLOT_IDS.size()):
		var slot_id: String = SLOT_IDS[index]
		if by_id.has(slot_id):
			continue
		var side := "right" if slot_id.ends_with("R") else "left"
		var axle := "rear" if slot_id.begins_with("R") else "front"
		var position_ps2: Vector3 = config.wheel_local_positions_ps2[index] if index < config.wheel_local_positions_ps2.size() else Vector3.ZERO
		by_id[slot_id] = {
			"slot_id": slot_id,
			"axle": axle,
			"side": side,
			"physics_position_ps2": position_ps2,
			"physics_position_godot": MathUtils.ps2_to_godot_vec3(position_ps2),
			"visual_position_ps2": position_ps2,
			"visual_position_godot": MathUtils.ps2_to_godot_vec3(position_ps2),
			"resolved_visual_position_ps2": position_ps2,
			"resolved_visual_position_godot": MathUtils.ps2_to_godot_vec3(position_ps2),
			"position_ps2": position_ps2,
			"position_godot": MathUtils.ps2_to_godot_vec3(position_ps2),
			"visual_position_source_resolved": "config_fallback",
			"source": "config_fallback",
			"locator_orientation_index": 0 if axle == "front" else 1,
		}
	return by_id


func _resolved_visual_pivot_position_ps2(physics_position_ps2: Vector3, locator_position_ps2: Vector3) -> Vector3:
	var delta := locator_position_ps2 - physics_position_ps2
	if absf(delta.x) > VISUAL_PIVOT_MAX_LONGITUDINAL_DELTA_PS2:
		return physics_position_ps2
	if absf(delta.y) > VISUAL_PIVOT_MAX_LATERAL_DELTA_PS2:
		return physics_position_ps2
	if absf(delta.z) > VISUAL_PIVOT_MAX_VERTICAL_DELTA_PS2:
		return physics_position_ps2
	return locator_position_ps2


func _body_visual_offset_ps2(config) -> Vector3:
	if config != null:
		# GEOMETRY.BIN body solids and locator records already share the same authored local space.
		# Until the 0x34020 body-root graph is decoded, applying GLOBALB body-center values here only
		# introduces extra shell drift relative to the original geometry-local wheel references.
		return Vector3.ZERO
	return Vector3.ZERO


func _body_visual_offset_godot(config) -> Vector3:
	return MathUtils.ps2_to_godot_vec3(_body_visual_offset_ps2(config))


func _collect_named_meshes(asset, suffixes: Array[String]) -> Dictionary:
	var meshes := {}
	for obj in asset.objects:
		var object_name: String = obj.get("name", "")
		for suffix in suffixes:
			if not object_name.ends_with(suffix):
				continue
			if meshes.has(suffix):
				continue
			var mesh_node := mesh_builder.build_object_mesh(obj, false)
			if mesh_node != null:
				mesh_node.transform = _runtime_part_local_transform(obj)
				mesh_node.set_meta("eagl_runtime_part_transform_mode", "source_rotation_only")
				meshes[suffix] = mesh_node
	return meshes


func _duplicate_mesh_instance(template: MeshInstance3D, node_name: String) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = template.mesh
	node.transform = template.transform
	for surface_index in range(template.get_surface_override_material_count()):
		node.set_surface_override_material(surface_index, template.get_surface_override_material(surface_index))
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
	return node


func _select_normal_wheel_visuals(asset, tire_meshes: Dictionary, config = null) -> Dictionary:
	var detail_choices := _resolved_tire_detail_choices(asset, tire_meshes, config)
	var front_choice := _best_tire_choice_for_axle(detail_choices.get("front", {}), config, "front")
	var rear_choice := _best_tire_choice_for_axle(detail_choices.get("rear", {}), config, "rear")
	var selection := {}
	for slot_id in SLOT_IDS:
		var choice := front_choice if slot_id in ["FL", "FR"] else rear_choice
		selection[slot_id] = choice
	return selection


func _resolved_tire_detail_choices(asset, tire_meshes: Dictionary, config = null) -> Dictionary:
	var front_choices := {}
	var rear_choices := {}
	for suffix in TIRE_DETAIL_SUFFIXES:
		front_choices[suffix] = _named_tire_choice(asset, tire_meshes, "front", suffix)
		rear_choices[suffix] = _named_tire_choice(asset, tire_meshes, "rear", suffix)

	if config != null and int(config.globalb_vehicle_type_id) == 2:
		front_choices["C"] = _retarget_tire_choice(front_choices.get("B", {}), "front", "C", "vehicle_type_2_front_c_uses_front_b")
		rear_choices["C"] = _retarget_tire_choice(rear_choices.get("B", {}), "rear", "C", "vehicle_type_2_rear_c_uses_rear_b")

	if Dictionary(rear_choices.get("A", {})).is_empty():
		rear_choices["A"] = _retarget_tire_choice(front_choices.get("A", {}), "rear", "A", "rear_a_falls_back_to_front_a")
	if Dictionary(rear_choices.get("B", {})).is_empty():
		rear_choices["B"] = _retarget_tire_choice(front_choices.get("B", {}), "rear", "B", "rear_b_falls_back_to_front_b")
	if Dictionary(rear_choices.get("C", {})).is_empty():
		rear_choices["C"] = _retarget_tire_choice(front_choices.get("C", {}), "rear", "C", "rear_c_falls_back_to_front_c")

	return {
		"front": front_choices,
		"rear": rear_choices,
	}


func _named_tire_choice(asset, tire_meshes: Dictionary, axle: String, detail_suffix: String) -> Dictionary:
	var object_name := "_TIRE_%s_%s" % [axle.to_upper(), detail_suffix]
	if not tire_meshes.has(object_name):
		return {}
	var template: MeshInstance3D = tire_meshes[object_name]
	if template == null:
		return {}
	return {
		"axle": axle,
		"source_axle": axle,
		"detail_suffix": detail_suffix,
		"detail_level": TIRE_DETAIL_SUFFIXES.find(detail_suffix),
		"actual_detail_suffix": detail_suffix,
		"object_name": _full_object_name(asset.car_id, object_name),
		"template": template,
	}


func _retarget_tire_choice(choice: Dictionary, axle: String, detail_suffix: String, reason: String) -> Dictionary:
	if choice.is_empty():
		return {}
	var out := choice.duplicate(true)
	out["axle"] = axle
	out["detail_suffix"] = detail_suffix
	out["detail_level"] = TIRE_DETAIL_SUFFIXES.find(detail_suffix)
	out["selection_reason"] = reason
	if not out.has("actual_detail_suffix"):
		out["actual_detail_suffix"] = String(choice.get("detail_suffix", ""))
	return out


func _best_tire_choice_for_axle(choices: Dictionary, config, axle: String) -> Dictionary:
	var expected_diameter := _expected_wheel_diameter(config, axle)
	var best_choice := {}
	var best_score := INF
	for suffix in TIRE_DETAIL_SUFFIXES:
		var choice: Dictionary = choices.get(suffix, {})
		if choice.is_empty():
			continue
		var template: MeshInstance3D = choice.get("template", null)
		var score := _wheel_template_score(template, expected_diameter, int(choice.get("detail_level", -1)))
		if score < best_score:
			best_score = score
			best_choice = choice
	return best_choice


func _expected_wheel_diameter(config, axle: String) -> float:
	if config == null or config.wheel_radii.is_empty():
		return 0.0
	var indices := [0, 1] if axle == "front" else [2, 3]
	var total := 0.0
	var count := 0
	for index in indices:
		if index >= config.wheel_radii.size():
			continue
		total += float(config.wheel_radii[index]) * 2.0
		count += 1
	return total / float(count) if count > 0 else 0.0


func _wheel_template_score(template: MeshInstance3D, expected_diameter: float, detail_level: int) -> float:
	if template == null or template.mesh == null:
		return INF
	var local_size := template.mesh.get_aabb().size.abs()
	var basis := template.transform.basis
	var transformed_size := Vector3(
		absf(basis.x.x) * local_size.x + absf(basis.y.x) * local_size.y + absf(basis.z.x) * local_size.z,
		absf(basis.x.y) * local_size.x + absf(basis.y.y) * local_size.y + absf(basis.z.y) * local_size.z,
		absf(basis.x.z) * local_size.x + absf(basis.y.z) * local_size.y + absf(basis.z.z) * local_size.z
	)
	var largest_dimension := maxf(transformed_size.x, maxf(transformed_size.y, transformed_size.z))
	if expected_diameter <= 0.0001:
		return -largest_dimension + float(detail_level) * 0.01
	var dimension_error := absf(largest_dimension - expected_diameter)
	var tiny_penalty := 10.0 if largest_dimension < expected_diameter * 0.35 else 0.0
	return dimension_error + tiny_penalty + float(detail_level) * 0.01


func _runtime_part_local_transform(obj: Dictionary) -> Transform3D:
	var source_transform := MathUtils.ps2_rows_to_godot_transform(obj.get("transform", []))
	var basis := source_transform.basis.orthonormalized()
	if basis.determinant() < 0.0:
		basis = Basis(-basis.x, basis.y, basis.z).orthonormalized()
	return Transform3D(basis, Vector3.ZERO)


func _canonical_wheel_part_transform(template: MeshInstance3D) -> Transform3D:
	if template == null:
		return Transform3D.IDENTITY
	var basis := template.transform.basis.orthonormalized()
	if template.mesh == null:
		return Transform3D(basis, Vector3.ZERO)
	var axle_direction := _wheel_mesh_axle_direction(template.mesh.get_aabb().size.abs(), basis)
	if axle_direction.length_squared() <= 0.000001:
		return Transform3D(basis, Vector3.ZERO)
	var correction := _rotation_between_vectors(axle_direction, Vector3.RIGHT)
	return Transform3D((correction * basis).orthonormalized(), Vector3.ZERO)


func _match_tire_visual_radius(tire_node: MeshInstance3D, expected_radius: float) -> void:
	if tire_node == null or tire_node.mesh == null:
		return
	if expected_radius <= 0.0001:
		return
	var local_aabb: AABB = tire_node.transform * tire_node.mesh.get_aabb()
	var visual_radius := maxf(local_aabb.size.y, local_aabb.size.z) * 0.5
	if visual_radius <= 0.0001:
		return
	var uniform_scale := expected_radius / visual_radius
	tire_node.scale = Vector3.ONE * uniform_scale


func _wheel_mesh_axle_direction(mesh_size: Vector3, basis: Basis) -> Vector3:
	var axle_axis := 0
	var smallest := mesh_size.x
	if mesh_size.y < smallest:
		axle_axis = 1
		smallest = mesh_size.y
	if mesh_size.z < smallest:
		axle_axis = 2
	match axle_axis:
		1:
			return basis.y.normalized()
		2:
			return basis.z.normalized()
		_:
			return basis.x.normalized()


func _rotation_between_vectors(from: Vector3, to: Vector3) -> Basis:
	var from_dir := from.normalized()
	var to_dir := to.normalized()
	var dot := clampf(from_dir.dot(to_dir), -1.0, 1.0)
	if dot >= 0.9999:
		return Basis.IDENTITY
	if dot <= -0.9999:
		var axis := from_dir.cross(Vector3.UP)
		if axis.length_squared() <= 0.000001:
			axis = from_dir.cross(Vector3.FORWARD)
		return Basis(axis.normalized(), PI)
	var axis := from_dir.cross(to_dir).normalized()
	return Basis(axis, acos(dot))


func _wheel_base_yaw(slot_info: Dictionary) -> float:
	var side := String(slot_info.get("side", ""))
	if side == "right":
		return -PI * 0.5
	return PI * 0.5


func _wheel_spin_direction(slot_info: Dictionary) -> float:
	var side := String(slot_info.get("side", ""))
	return -1.0 if side == "right" else 1.0




func _full_object_name(car_id: String, suffix: String) -> String:
	return "%s%s" % [String(car_id).to_upper(), suffix]


func _brake_template_for_slot(brake_meshes: Dictionary, slot_id: String) -> MeshInstance3D:
	var suffix := "_BRAKE_FRONT" if slot_id in ["FL", "FR"] else "_BRAKE_REAR"
	return brake_meshes.get(suffix, brake_meshes.get("_BRAKE_FRONT", null))


func _wheel_visual_selection_summary(wheel_visual_selection: Dictionary) -> Dictionary:
	var summary := {}
	for slot_id in wheel_visual_selection.keys():
		var choice: Dictionary = wheel_visual_selection[slot_id]
		summary[slot_id] = {
			"axle": choice.get("axle", ""),
			"source_axle": choice.get("source_axle", ""),
			"detail_suffix": choice.get("detail_suffix", ""),
			"detail_level": choice.get("detail_level", -1),
			"object_name": choice.get("object_name", ""),
		}
	return summary


func _is_runtime_wheel_part(object_name: String) -> bool:
	var name := object_name.to_upper()
	return name.contains("_TIRE_") or name.contains("_BRAKE_") or name.ends_with("_WHEEL_BLUR")


func _should_include_static_mesh(object_name: String, car_id: String, primary_body_variant: String) -> bool:
	var name := object_name.to_upper()
	var normalized_car_id := car_id.to_upper()
	if _is_runtime_wheel_part(name):
		return false
	if name.ends_with("_SCUFFS") or name.ends_with("_CV"):
		return false
	if primary_body_variant != "" and name == primary_body_variant:
		return true
	if name.ends_with("_SIDE_MIRROR_LE") or name.ends_with("_SIDE_MIRROR_RI"):
		return true
	if name.ends_with("_WIPER_LEFT") or name.ends_with("_WIPER_RIGHT"):
		return true
	if name.ends_with("_LICENSE_PLATE_"):
		return true
	if normalized_car_id != "" and name.begins_with("%s_" % normalized_car_id):
		return false
	return true


func _pick_primary_body_variant(asset) -> String:
	var car_id := String(asset.car_id).to_upper()
	if car_id == "":
		return ""
	var available := {}
	for obj in asset.objects:
		available[String(obj.get("name", "")).to_upper()] = true
	for suffix in ["_A", "_B", "_C", "_D"]:
		var candidate := "%s%s" % [car_id, suffix]
		if available.has(candidate):
			return candidate
	return ""


func _resolve_car_model_path(car_id: String) -> String:
	var value := car_id.strip_edges()
	if value.ends_with(".BIN") or value.ends_with(".LZC"):
		var direct_file := FileAccess.open(value, FileAccess.READ)
		if direct_file != null:
			direct_file.close()
			return value
		return ""

	var normalized: String = _normalized_car_id(value)
	var cars_dir := _resolve_cars_dir(root_path)
	if cars_dir == "":
		last_error = "Could not locate CARS under game root: %s" % root_path
		return ""
	var roots: Array[String] = [
		cars_dir,
	]
	for root_path: String in roots:
		if root_path == "":
			continue
		for extension: String in ["BIN", "LZC"]:
			var candidate: String = root_path.path_join(normalized).path_join("GEOMETRY.%s" % extension)
			var file := FileAccess.open(candidate, FileAccess.READ)
			if file != null:
				file.close()
				return candidate
	last_error = "Could not find %s/GEOMETRY.BIN or GEOMETRY.LZC under %s" % [normalized, cars_dir]
	return ""


func _normalized_car_id(car_id: String) -> String:
	return car_id.strip_edges().trim_suffix("/").get_file().to_upper()


func _resolve_cars_dir(root: String) -> String:
	var normalized := root.trim_suffix("/")
	if normalized == "":
		return ""
	var candidates := [
		normalized.path_join("ZZDATA").path_join("CARS"),
		normalized.path_join("CARS"),
		normalized,
	]
	for candidate in candidates:
		if not DirAccess.dir_exists_absolute(candidate):
			continue
		if candidate.get_file().to_upper() == "CARS":
			return candidate
		var nested: String = candidate.path_join("CARS")
		if DirAccess.dir_exists_absolute(nested):
			return nested
	return ""


func _child_name_list(node: Node) -> PackedStringArray:
	var names := PackedStringArray()
	for child in node.get_children():
		names.append(String(child.name))
	return names
