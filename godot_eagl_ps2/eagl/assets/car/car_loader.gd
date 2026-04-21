class_name CarLoader
extends RefCounted

const CarParserPS2Script = preload("res://eagl/assets/car/car_parser_ps2.gd")
const MeshBuilderScript = preload("res://eagl/rendering/mesh_builder.gd")
const MathUtils = preload("res://eagl/utils/math_utils.gd")

const SLOT_IDS := ["FL", "FR", "RL", "RR"]
const TIRE_DETAIL_SUFFIXES := ["A", "B", "C"]

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
	var primary_body_variant := _pick_primary_body_variant(asset)
	root.set_meta("eagl_primary_body_variant", primary_body_variant)

	var body_root := Node3D.new()
	body_root.name = "Body"
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
	], false)
	var brake_meshes := _collect_named_meshes(asset, [
		"_BRAKE_FRONT",
		"_BRAKE_REAR",
	], false)
	var wheel_visual_selection := _select_normal_wheel_visuals(asset, tire_meshes)
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
		_build_runtime_pivots(root, wheels_root, dummies_root, wheel_visual_selection, brake_meshes, config)

	root.set_meta("eagl_body_mesh_count", body_root.get_child_count())
	root.set_meta("eagl_wheel_pivot_names", _child_name_list(wheels_root))
	root.set_meta("eagl_dummy_names", _child_name_list(dummies_root))
	return root


func _build_runtime_pivots(root: Node3D, wheels_root: Node3D, dummies_root: Node3D, wheel_visual_selection: Dictionary, brake_meshes: Dictionary, config) -> void:
	for index in range(SLOT_IDS.size()):
		if index >= config.wheel_local_positions_ps2.size():
			break
		var slot_id: String = SLOT_IDS[index]
		var wheel_root := Node3D.new()
		wheel_root.name = slot_id
		wheel_root.position = MathUtils.ps2_to_godot_vec3(config.wheel_local_positions_ps2[index])
		wheels_root.add_child(wheel_root)

		var suspension_root := Node3D.new()
		suspension_root.name = "Suspension"
		wheel_root.add_child(suspension_root)

		var steer_root := Node3D.new()
		steer_root.name = "Steer"
		suspension_root.add_child(steer_root)

		var roll_root := Node3D.new()
		roll_root.name = "Roll"
		steer_root.add_child(roll_root)

		var tire_selection: Dictionary = wheel_visual_selection.get(slot_id, {})
		var tire_template: MeshInstance3D = tire_selection.get("template", null)
		if tire_template != null:
			var tire_node := _duplicate_mesh_instance(tire_template, "Tire")
			if slot_id in ["FR", "RR"]:
				tire_node.rotation.y = PI
			tire_node.set_meta("eagl_source_object", tire_selection.get("object_name", ""))
			tire_node.set_meta("eagl_detail_suffix", tire_selection.get("detail_suffix", ""))
			tire_node.set_meta("eagl_detail_level", tire_selection.get("detail_level", -1))
			roll_root.add_child(tire_node)

		var brake_template: MeshInstance3D = _brake_template_for_slot(brake_meshes, slot_id)
		if brake_template != null:
			var brake_node := _duplicate_mesh_instance(brake_template, "Brake")
			if slot_id in ["FR", "RR"]:
				brake_node.rotation.y = PI
			steer_root.add_child(brake_node)

		var dummy := Node3D.new()
		dummy.name = "%s_PIVOT" % slot_id
		dummy.position = MathUtils.ps2_to_godot_vec3(config.wheel_local_positions_ps2[index])
		dummies_root.add_child(dummy)

	var center_dummy := Node3D.new()
	center_dummy.name = "BODY_CENTER"
	center_dummy.position = MathUtils.ps2_to_godot_vec3(config.center_of_mass_ps2)
	dummies_root.add_child(center_dummy)


func _collect_named_meshes(asset, suffixes: Array[String], apply_transform: bool) -> Dictionary:
	var meshes := {}
	for obj in asset.objects:
		var object_name: String = obj.get("name", "")
		for suffix in suffixes:
			if not object_name.ends_with(suffix):
				continue
			var mesh_node := mesh_builder.build_object_mesh(obj, apply_transform)
			if mesh_node != null and not meshes.has(suffix):
				meshes[suffix] = mesh_node
	return meshes


func _duplicate_mesh_instance(template: MeshInstance3D, node_name: String) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = template.mesh
	for surface_index in range(template.get_surface_override_material_count()):
		node.set_surface_override_material(surface_index, template.get_surface_override_material(surface_index))
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
	return node


func _select_normal_wheel_visuals(asset, tire_meshes: Dictionary) -> Dictionary:
	var front_choice := _best_tire_choice(asset, tire_meshes, "front")
	var rear_choice := _best_tire_choice(asset, tire_meshes, "rear")
	if rear_choice.is_empty():
		rear_choice = front_choice
	var selection := {}
	for slot_id in SLOT_IDS:
		var choice := front_choice if slot_id in ["FL", "FR"] else rear_choice
		selection[slot_id] = choice
	return selection


func _best_tire_choice(asset, tire_meshes: Dictionary, axle: String) -> Dictionary:
	var prefix := "_TIRE_FRONT_" if axle == "front" else "_TIRE_REAR_"
	var detail_level := 0
	for suffix in TIRE_DETAIL_SUFFIXES:
		var object_name := "%s%s" % [prefix, suffix]
		if tire_meshes.has(object_name):
			return {
				"axle": axle,
				"source_axle": axle,
				"detail_suffix": suffix,
				"detail_level": detail_level,
				"object_name": _full_object_name(asset.car_id, object_name),
				"template": tire_meshes[object_name],
			}
		detail_level += 1

	if axle == "rear":
		var fallback := _best_tire_choice(asset, tire_meshes, "front")
		if not fallback.is_empty():
			fallback = fallback.duplicate(true)
			fallback["axle"] = "rear"
			fallback["source_axle"] = "front"
		return fallback
	return {}


func _full_object_name(car_id: String, suffix: String) -> String:
	return "%s%s" % [String(car_id).to_upper(), suffix]


func _brake_template_for_slot(brake_meshes: Dictionary, slot_id: String) -> MeshInstance3D:
	if slot_id in ["FL", "FR"]:
		return brake_meshes.get("_BRAKE_FRONT", null)
	return brake_meshes.get("_BRAKE_REAR", brake_meshes.get("_BRAKE_FRONT", null))


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
