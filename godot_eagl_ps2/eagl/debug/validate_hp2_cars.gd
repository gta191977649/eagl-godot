extends SceneTree

const ConfigScript := preload("res://eagl/core/eagl_config.gd")
const PlatformScript := preload("res://eagl/platforms/ps2/ps2_platform.gd")
const MathUtils := preload("res://eagl/utils/math_utils.gd")

const DEFAULT_GAME_ROOT := "/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA"
const SAMPLE_CARS := ["MCLAREN", "F50", "BMWM5", "CORVETTE", "BUS", "FIRETRUCK", "4DR_SEDAN", "TAXI"]
const DUMMY_WHEEL_SLOT_SOURCE := "geometry_metadata_0x00034013_runtime_tire_dummies"


func _init() -> void:
	var failed := false
	var game_root := OS.get_environment("EAGL_HP2_GAME_ROOT")
	if game_root == "":
		game_root = DEFAULT_GAME_ROOT

	var config = ConfigScript.new()
	config.target_platform = "EAGL_HOTPUSUIT2_PS2"
	config.game_root = game_root
	config.options = {
		"texture_filter_mode": "nearest_mipmap",
		"generate_lods": true,
	}

	var platform = PlatformScript.new()
	platform.initialize(config)
	for car_id in SAMPLE_CARS:
		var asset = platform.load_car_asset(car_id)
		if asset == null:
			failed = true
			push_error("VALIDATION failed to load car asset %s from %s" % [car_id, game_root])
			continue
		var ok := _validate_asset(car_id, asset)
		failed = failed or not ok

	for car_id in SAMPLE_CARS:
		var scene := platform.load_car(car_id)
		if scene == null or scene.get_meta("error", "") != "":
			failed = true
			push_error("VALIDATION failed to build %s car scene" % car_id)
			continue
		var ok := _validate_scene(car_id, scene)
		failed = failed or not ok
		scene.free()

	if not _validate_hp2_car_transform_math():
		failed = true

	platform.clear_cache()
	quit(1 if failed else 0)


func _validate_asset(car_id: String, asset) -> bool:
	var ok := true
	var object_count := int(asset.summary().get("object_count", 0))
	var block_count := int(asset.summary().get("block_count", 0))
	var vertex_count := int(asset.summary().get("vertex_count", 0))
	var texture_refs := int(asset.summary().get("texture_ref_count", 0))
	var runtime_counts: Dictionary = asset.summary().get("runtime_part_counts", {})
	var tire_count := int(runtime_counts.get("tire_front", 0)) + int(runtime_counts.get("tire_rear", 0))
	if object_count <= 0 or block_count <= 0 or vertex_count <= 0:
		ok = false
		push_error("VALIDATION %s expected nonzero object/block/vertex counts, got objects=%d blocks=%d vertices=%d" % [car_id, object_count, block_count, vertex_count])
	if texture_refs <= 0:
		ok = false
		push_error("VALIDATION %s expected nonzero texture refs" % car_id)
	if car_id == "F50" and int(asset.summary().get("dashboard_object_count", 0)) <= 0:
		ok = false
		push_error("VALIDATION F50 expected dashboard geometry")
	if tire_count > 0 and int(asset.summary().get("wheel_slot_count", 0)) < 4:
		ok = false
		push_error("VALIDATION %s expected at least 4 wheel slots for tire runtime parts, got %d" % [car_id, int(asset.summary().get("wheel_slot_count", 0))])
	if String(asset.summary().get("exact_handling_status", "")) == "":
		ok = false
		push_error("VALIDATION %s expected handling status metadata" % car_id)
	if not _validate_globalb_handling_asset(car_id, asset):
		ok = false
	if ok:
		print("VALIDATION car %s objects=%d dashboard=%s blocks=%d vertices=%d texture_refs=%d textures=%s locators=%s slots=%s slot_source=%s handling=%s" % [
			car_id,
			object_count,
			asset.summary().get("dashboard_object_count", 0),
			block_count,
			vertex_count,
			texture_refs,
			asset.summary().get("texture_count", 0),
			asset.summary().get("locator_count", 0),
			asset.summary().get("wheel_slot_count", 0),
			asset.summary().get("wheel_slot_source", ""),
			asset.summary().get("exact_handling_status", ""),
		])
	return ok


func _validate_scene(car_id: String, scene: Node) -> bool:
	var ok := true
	var part_groups: Dictionary = scene.get_meta("eagl_part_groups", {})
	var rendered := int(scene.get_meta("eagl_rendered_object_count", 0))
	var wheel_instances := int(scene.get_meta("eagl_wheel_instance_count", 0))
	var brake_instances := int(scene.get_meta("eagl_brake_instance_count", 0))
	var wheel_slot_count := int(scene.get_meta("eagl_wheel_slot_count", 0))
	var spin_pivots := _count_meta(scene, "eagl_spin_pivot", true)
	var steer_pivots := _count_meta(scene, "eagl_steer_pivot", true)
	var wheels_group := scene.get_node_or_null("Visual/Wheels")
	var wheels_group_tagged := wheels_group != null and (
		(wheels_group.has_meta("eagl_spin_pivot") and bool(wheels_group.get_meta("eagl_spin_pivot")))
		or (wheels_group.has_meta("eagl_steer_pivot") and bool(wheels_group.get_meta("eagl_steer_pivot")))
		or (wheels_group.has_meta("eagl_runtime_part") and String(wheels_group.get_meta("eagl_runtime_part")) != "")
	)
	var wheel_blur_enabled := bool(scene.get_meta("eagl_wheel_blur_enabled", true))
	var runtime_counts: Dictionary = scene.get_meta("eagl_runtime_part_counts", {})
	var tire_count := int(runtime_counts.get("tire_front", 0)) + int(runtime_counts.get("tire_rear", 0))
	var brake_mesh_count := int(runtime_counts.get("brake_front", 0)) + int(runtime_counts.get("brake_rear", 0))
	var has_runtime_wheels := tire_count > 0
	var locators: Array = scene.get_meta("eagl_locators", [])
	var locator_count := int(scene.get_meta("eagl_locator_count", 0))
	if rendered <= 0:
		ok = false
		push_error("VALIDATION %s scene expected rendered objects" % car_id)
	if locators.size() != locator_count:
		ok = false
		push_error("VALIDATION %s scene locator metadata mismatch: count=%d records=%d" % [car_id, locator_count, locators.size()])
	for locator in locators:
		var locator_dict: Dictionary = locator
		if String(locator_dict.get("display_name", "")) == "" or not locator_dict.has("position_godot"):
			ok = false
			push_error("VALIDATION %s locator missing debug display data: %s" % [car_id, locator_dict])
			break
	if has_runtime_wheels and not part_groups.has("Wheels"):
		ok = false
		push_error("VALIDATION %s scene expected Wheels group for tire runtime parts" % car_id)
	if has_runtime_wheels and (wheel_instances != 4 or wheel_slot_count < 4 or spin_pivots != 4 or steer_pivots < 2):
		ok = false
		push_error("VALIDATION %s scene wheel assembly mismatch: wheels=%d slots=%d spin=%d steer=%d" % [car_id, wheel_instances, wheel_slot_count, spin_pivots, steer_pivots])
	if brake_mesh_count > 0 and brake_instances != 4:
		ok = false
		push_error("VALIDATION %s scene brake assembly mismatch: brake_meshes=%d brakes=%d" % [car_id, brake_mesh_count, brake_instances])
	if wheels_group_tagged:
		ok = false
		push_error("VALIDATION %s Visual/Wheels group must not be tagged as an animated wheel node" % car_id)
	if wheel_blur_enabled:
		ok = false
		push_error("VALIDATION %s wheel blur should be hidden by default" % car_id)
	if String(scene.get_meta("eagl_exact_handling_status", "")) == "" or String(scene.get_meta("eagl_wheel_slot_source", "")) == "":
		ok = false
		push_error("VALIDATION %s scene missing handling/slot metadata" % car_id)
	if has_runtime_wheels and not _validate_runtime_wheel_hierarchy(car_id, scene):
		ok = false
	if brake_mesh_count > 0 and not _validate_runtime_brake_hierarchy(car_id, scene):
		ok = false
	if has_runtime_wheels and not _validate_runtime_mesh_textures(car_id, scene, "wheel_mesh", ["TIRE", "TIREBACK"], "_TIRE"):
		ok = false
	if brake_mesh_count > 0 and not _validate_runtime_mesh_textures(car_id, scene, "brake_mesh", ["BRAKESFRONT", "BRAKESREAR"], ""):
		ok = false
	if not _validate_hp2_car_shader_materials(car_id, scene):
		ok = false
	if not _validate_visual_transform_policy(car_id, scene):
		ok = false
	if car_id == "MCLAREN" and not _validate_controller_smoke(scene):
		ok = false
	if ok:
		print("VALIDATION scene %s rendered=%d wheels=%d brakes=%d slots=%d spin=%d steer=%d textured=%s fallback=%s missing_hashes=%s slot_source=%s groups=%s" % [
			car_id,
			rendered,
			wheel_instances,
			brake_instances,
			wheel_slot_count,
			spin_pivots,
			steer_pivots,
			scene.get_meta("eagl_textured_surface_count", 0),
			scene.get_meta("eagl_fallback_surface_count", 0),
			scene.get_meta("eagl_missing_texture_hashes", []).size(),
			scene.get_meta("eagl_wheel_slot_source", ""),
			part_groups.keys(),
		])
	return ok


func _validate_globalb_handling_asset(car_id: String, asset) -> bool:
	var ok := true
	var handling: Dictionary = asset.summary().get("handling_data", {})
	var row: Dictionary = handling.get("globalb_row", {})
	if row.is_empty():
		push_error("VALIDATION %s expected decoded GLOBALB handling row" % car_id)
		return false
	if int(row.get("row_stride", 0)) != 0x560:
		ok = false
		push_error("VALIDATION %s GLOBALB row stride mismatch: %s" % [car_id, row.get("row_stride", 0)])
	if int(row.get("row_count", 0)) != 64:
		ok = false
		push_error("VALIDATION %s expected 64 GLOBALB rows, got %s" % [car_id, row.get("row_count", 0)])
	if String(row.get("schema", "")) != "hp2_globalb_car_row_0x560":
		ok = false
		push_error("VALIDATION %s unexpected GLOBALB schema: %s" % [car_id, row.get("schema", "")])
	if String(handling.get("exact_handling_status", "")).find("globalb_row") < 0:
		ok = false
		push_error("VALIDATION %s expected globalb row handling status, got %s" % [car_id, handling.get("exact_handling_status", "")])
	var name_field: Dictionary = row.get("name", {})
	if String(name_field.get("confidence", "")) != "verified" or int(name_field.get("offset", -1)) != 0x20:
		ok = false
		push_error("VALIDATION %s GLOBALB name field missing verified offset metadata" % car_id)
	var vehicle_type: Dictionary = row.get("vehicle_type", {})
	if String(vehicle_type.get("confidence", "")) != "verified" or int(vehicle_type.get("offset", -1)) != 0x538:
		ok = false
		push_error("VALIDATION %s GLOBALB vehicle_type missing verified offset metadata" % car_id)
	var fields: Dictionary = row.get("inferred_float_fields", {})
	for required in ["mass", "engine_peak_rpm", "engine_redline_rpm", "aero_drag", "steering_response", "gear_count", "final_drive_ratio", "reverse_gear_ratio", "gear_ratio_1"]:
		var field: Dictionary = fields.get(required, {})
		if field.is_empty() or String(field.get("confidence", "")) == "" or int(field.get("offset", -1)) < 0:
			ok = false
			push_error("VALIDATION %s decoded field %s missing source/confidence metadata" % [car_id, required])
	var dimensions: Dictionary = row.get("vehicle_dimensions", {})
	for required in ["wheelbase", "front_track", "rear_track"]:
		var field: Dictionary = dimensions.get(required, {})
		if field.is_empty() or String(field.get("confidence", "")) == "":
			ok = false
			push_error("VALIDATION %s decoded dimension %s missing confidence metadata" % [car_id, required])
	if car_id == "MCLAREN":
		var slots: Array = row.get("wheel_slots", [])
		var front_radius := _row_slot_radius(slots, "FL")
		var rear_radius := _row_slot_radius(slots, "RL")
		if absf(front_radius - 0.322) > 0.002:
			ok = false
			push_error("VALIDATION MCLAREN expected front GLOBALB radius 0.322, got %.4f" % front_radius)
		if absf(rear_radius - 0.358) > 0.002:
			ok = false
			push_error("VALIDATION MCLAREN expected rear GLOBALB radius 0.358, got %.4f" % rear_radius)
		var gear_count_field: Dictionary = fields.get("gear_count", {})
		var final_drive_field: Dictionary = fields.get("final_drive_ratio", {})
		var sixth_ratio_field: Dictionary = fields.get("gear_ratio_6", {})
		if int(gear_count_field.get("value", 0)) != 6:
			ok = false
			push_error("VALIDATION MCLAREN expected integer gear_count 6 at row+0x288, got %s" % gear_count_field)
		if absf(float(final_drive_field.get("value", 0.0)) - 4.0) > 0.001:
			ok = false
			push_error("VALIDATION MCLAREN expected drivetrain scalar/final drive 4.0 at row+0x28c, got %s" % final_drive_field)
		if absf(float(sixth_ratio_field.get("value", 0.0)) - 0.93) > 0.002:
			ok = false
			push_error("VALIDATION MCLAREN expected sixth gear ratio 0.93, got %s" % sixth_ratio_field)
	return ok


func _row_slot_radius(slots: Array, slot_id: String) -> float:
	for slot in slots:
		var dict: Dictionary = slot
		if String(dict.get("slot_id", "")) == slot_id:
			return float(dict.get("wheel_radius", 0.0))
	return 0.0


func _validate_hp2_car_transform_math() -> bool:
	var rows := [
		[0.0, 1.0, 0.0, 0.0],
		[-1.0, 0.0, 0.0, 0.0],
		[0.0, 0.0, 1.0, 0.0],
		[2.0, 3.0, 4.0, 1.0],
	]
	var point_ps2 := Vector3(5.0, 6.0, 7.0)
	var expected := MathUtils.hp2_car_to_godot_vec3(MathUtils.transform_point_rows(point_ps2, rows))
	var actual := MathUtils.hp2_car_rows_to_godot_transform(rows) * MathUtils.hp2_car_to_godot_vec3(point_ps2)
	if actual.distance_to(expected) > 0.001:
		push_error("VALIDATION HP2 car transform mismatch: expected=%s actual=%s" % [expected, actual])
		return false
	print("VALIDATION HP2 car transform math ok")
	return true


func _validate_runtime_wheel_hierarchy(car_id: String, scene: Node) -> bool:
	var ok := true
	var wheel_slots: Array[Node] = []
	var slot_positions: Array[Vector3] = []
	for node in scene.find_children("WheelSlot_*", "Node3D", true, false):
		wheel_slots.append(node)
		slot_positions.append((node as Node3D).position)
	if wheel_slots.size() != 4:
		push_error("VALIDATION %s expected 4 WheelSlot nodes, got %d" % [car_id, wheel_slots.size()])
		return false
	for node in wheel_slots:
		var slot_node := node as Node3D
		var steer := slot_node.get_node_or_null("SteerPivot")
		if steer == null:
			ok = false
			push_error("VALIDATION %s %s missing SteerPivot" % [car_id, slot_node.name])
			continue
		var spin := steer.get_node_or_null("SpinPivot")
		if spin == null:
			ok = false
			push_error("VALIDATION %s %s missing SpinPivot" % [car_id, slot_node.name])
			continue
		if not bool(spin.get_meta("eagl_spin_pivot", false)):
			ok = false
			push_error("VALIDATION %s %s SpinPivot missing spin metadata" % [car_id, slot_node.name])
		var slot: Dictionary = slot_node.get_meta("eagl_wheel_slot", {})
		var slot_id := String(slot_node.get_meta("eagl_wheel_slot_id", ""))
		var p_ps2: Vector3 = slot.get("position_ps2", Vector3.ZERO)
		var p_godot: Vector3 = slot.get("position_godot", Vector3.ZERO)
		if p_godot.distance_to(Vector3(p_ps2.y, p_ps2.z, -p_ps2.x)) > 0.01:
			ok = false
			push_error("VALIDATION %s %s slot position_godot does not match PS2 coordinate conversion" % [car_id, slot_id])
		var source := String(slot.get("source", ""))
		if source == DUMMY_WHEEL_SLOT_SOURCE and not _validate_runtime_dummy_slot(car_id, slot_id, slot):
			ok = false
		if source == "geometry_metadata_0x00034024_wheel_arch":
			var arch: AABB = slot.get("arch_bounds_ps2", AABB())
			var center_x := arch.position.x + arch.size.x * 0.5
			var center_y := arch.position.y + arch.size.y * 0.5
			if absf(p_ps2.x - center_x) > 0.03:
				ok = false
				push_error("VALIDATION %s %s wheel pivot should be centered in 0x34024 arch x-range" % [car_id, slot_id])
			if absf(p_ps2.y - center_y) > 0.03:
				ok = false
				push_error("VALIDATION %s %s wheel pivot should be centered in 0x34024 arch y-range" % [car_id, slot_id])
		if slot_id.ends_with("L") and p_ps2.y <= 0.0:
			ok = false
			push_error("VALIDATION %s %s left wheel slot has non-left PS2 lateral position %.3f" % [car_id, slot_id, p_ps2.y])
		if slot_id.ends_with("R") and p_ps2.y >= 0.0:
			ok = false
			push_error("VALIDATION %s %s right wheel slot has non-right PS2 lateral position %.3f" % [car_id, slot_id, p_ps2.y])
		var mesh := spin.get_node_or_null("Mesh") as MeshInstance3D
		if mesh == null:
			ok = false
			push_error("VALIDATION %s %s missing wheel mesh" % [car_id, slot_node.name])
		elif not _validate_runtime_mesh_transform(car_id, slot_id, mesh, true):
			ok = false
	for i in range(slot_positions.size()):
		for j in range(i + 1, slot_positions.size()):
			if slot_positions[i].distance_to(slot_positions[j]) < 0.45:
				ok = false
				push_error("VALIDATION %s wheel slot pivots are collapsed: %s and %s" % [car_id, wheel_slots[i].name, wheel_slots[j].name])
	return ok


func _validate_runtime_dummy_slot(car_id: String, slot_id: String, slot: Dictionary) -> bool:
	var ok := true
	var locator_count := int(slot.get("dummy_locator_count", 0))
	var hashes: Array = slot.get("dummy_hashes", [])
	var positions: Array = slot.get("dummy_locator_positions_ps2", [])
	if locator_count <= 0 or hashes.is_empty() or positions.is_empty():
		push_error("VALIDATION %s %s runtime dummy slot missing dummy source metadata" % [car_id, slot_id])
		return false
	var total := Vector3.ZERO
	for position in positions:
		var p: Vector3 = position
		total += p
	var average := total / maxf(1.0, float(positions.size()))
	var p_ps2: Vector3 = slot.get("position_ps2", Vector3.ZERO)
	if average.distance_to(p_ps2) > 0.01:
		ok = false
		push_error("VALIDATION %s %s runtime dummy slot position is not the dummy average: avg=%s slot=%s" % [car_id, slot_id, average, p_ps2])
	return ok


func _validate_runtime_brake_hierarchy(car_id: String, scene: Node) -> bool:
	var ok := true
	var brake_slots: Array[Node] = []
	for node in scene.find_children("BrakeSlot_*", "Node3D", true, false):
		brake_slots.append(node)
	if brake_slots.size() != 4:
		push_error("VALIDATION %s expected 4 BrakeSlot nodes, got %d" % [car_id, brake_slots.size()])
		return false
	for node in brake_slots:
		var slot_node := node as Node3D
		var steer := slot_node.get_node_or_null("SteerPivot")
		if steer == null:
			ok = false
			push_error("VALIDATION %s %s missing brake SteerPivot" % [car_id, slot_node.name])
			continue
		var spin := steer.get_node_or_null("SpinPivot")
		if spin != null:
			ok = false
			push_error("VALIDATION %s %s brake must not contain SpinPivot" % [car_id, slot_node.name])
		var slot: Dictionary = slot_node.get_meta("eagl_wheel_slot", {})
		var slot_id := String(slot_node.get_meta("eagl_wheel_slot_id", ""))
		var p_ps2: Vector3 = slot.get("position_ps2", Vector3.ZERO)
		var p_godot: Vector3 = slot.get("position_godot", Vector3.ZERO)
		if p_godot.distance_to(Vector3(p_ps2.y, p_ps2.z, -p_ps2.x)) > 0.01:
			ok = false
			push_error("VALIDATION %s %s brake slot position_godot does not match PS2 coordinate conversion" % [car_id, slot_id])
		if slot_node.position.distance_to(p_godot) > 0.01:
			ok = false
			push_error("VALIDATION %s %s brake slot node is not placed at decoded slot position" % [car_id, slot_id])
		var mesh := steer.get_node_or_null("Mesh") as MeshInstance3D
		if mesh == null:
			ok = false
			push_error("VALIDATION %s %s missing brake mesh" % [car_id, slot_node.name])
		elif not _validate_runtime_mesh_transform(car_id, slot_id, mesh, false):
			ok = false
	return ok


func _validate_runtime_mesh_transform(car_id: String, slot_id: String, mesh: MeshInstance3D, check_outer_face: bool) -> bool:
	var ok := true
	var transformed_bounds := mesh.transform * mesh.get_aabb()
	var transformed_center := transformed_bounds.position + transformed_bounds.size * 0.5
	if transformed_center.length() > 0.035:
		ok = false
		push_error("VALIDATION %s %s runtime mesh is not centered on its slot pivot: center=%s" % [car_id, slot_id, transformed_center])
	if mesh.scale.distance_to(Vector3.ONE) > 0.001:
		ok = false
		push_error("VALIDATION %s %s runtime mesh should use rotation, not negative side scale: scale=%s" % [car_id, slot_id, mesh.scale])
	if check_outer_face:
		var expected_y := -PI if slot_id.ends_with("L") else 0.0
		if absf(wrapf(mesh.rotation.y - expected_y, -PI, PI)) > 0.01:
			ok = false
			push_error("VALIDATION %s %s wheel outer face rotation mismatch: got %.3f expected %.3f" % [car_id, slot_id, mesh.rotation.y, expected_y])
	return ok


func _validate_runtime_mesh_textures(car_id: String, scene: Node, runtime_part: String, exact_names: Array[String], suffix_name: String) -> bool:
	var ok := true
	var mesh_count := 0
	for node in scene.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		if String(mesh.get_meta("eagl_runtime_part", "")) != runtime_part:
			continue
		mesh_count += 1
		var texture_names := _surface_texture_names(mesh)
		if texture_names.is_empty():
			ok = false
			push_error("VALIDATION %s %s has no resolved runtime texture materials" % [car_id, mesh.name])
			continue
		var matched := false
		for texture_name in texture_names:
			if exact_names.has(texture_name) or (suffix_name != "" and texture_name.ends_with(suffix_name)):
				matched = true
				break
		if not matched:
			ok = false
			push_error("VALIDATION %s %s resolved unexpected runtime textures: %s" % [car_id, mesh.name, texture_names])
	if mesh_count <= 0:
		push_error("VALIDATION %s expected runtime meshes for %s textures" % [car_id, runtime_part])
		return false
	return ok


func _surface_texture_names(mesh: MeshInstance3D) -> Array[String]:
	var names: Array[String] = []
	var surface_count := mesh.get_surface_override_material_count()
	if mesh.mesh != null:
		surface_count = maxi(surface_count, mesh.mesh.get_surface_count())
	for surface_index in range(surface_count):
		var material: Material = mesh.get_surface_override_material(surface_index)
		if material == null and mesh.mesh != null:
			material = mesh.mesh.surface_get_material(surface_index)
		if material == null:
			continue
		var texture_name := String(material.get_meta("eagl_texture_name", "")).to_upper()
		if texture_name != "":
			names.append(texture_name)
	return names


func _validate_hp2_car_shader_materials(car_id: String, scene: Node) -> bool:
	var ok := true
	var checked := 0
	for node in scene.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		var surface_count := mesh.get_surface_override_material_count()
		if mesh.mesh != null:
			surface_count = maxi(surface_count, mesh.mesh.get_surface_count())
		for surface_index in range(surface_count):
			var material: Material = mesh.get_surface_override_material(surface_index)
			if material == null and mesh.mesh != null:
				material = mesh.mesh.surface_get_material(surface_index)
			if material == null:
				continue
			var role := String(material.get_meta("eagl_material_role", ""))
			if not role.begins_with("hp2_car"):
				continue
			checked += 1
			if not bool(material.get_meta("eagl_hp2_car_shader", false)):
				ok = false
				push_error("VALIDATION %s car material did not use HP2 shader: %s surface=%d role=%s" % [car_id, mesh.name, surface_index, role])
				continue
			var shader_path := String(material.get_meta("eagl_shader_path", ""))
			if not shader_path.begins_with("res://eagl/shader/hp2_car_"):
				ok = false
				push_error("VALIDATION %s car material used unexpected shader path: %s" % [car_id, shader_path])
	if checked <= 0:
		push_error("VALIDATION %s expected HP2 car shader materials" % car_id)
		return false
	return ok


func _validate_visual_transform_policy(car_id: String, scene: Node) -> bool:
	var ok := true
	for node in scene.find_children("*", "MeshInstance3D", true, false):
		var object_name := String(node.get_meta("eagl_object_name", "")).to_upper()
		var mode := String(node.get_meta("eagl_visual_transform_mode", ""))
		if object_name.contains("WHEEL_BLUR"):
			ok = false
			push_error("VALIDATION %s should not render wheel blur by default: %s" % [car_id, object_name])
		if object_name.contains("WIPER") and mode != "source_transform_vertices":
			ok = false
			push_error("VALIDATION %s wiper should keep source object transform: %s mode=%s" % [car_id, object_name, mode])
		if not object_name.contains("WIPER") and mode == "source_transform_vertices":
			ok = false
			push_error("VALIDATION %s non-wiper object should not receive source object transform: %s" % [car_id, object_name])
	return ok


func _count_meta(root: Node, meta_name: String, expected) -> int:
	var count := 0
	for node in root.find_children("*", "Node", true, false):
		if node.has_meta(meta_name) and node.get_meta(meta_name) == expected:
			count += 1
	return count


func _validate_controller_smoke(scene: Node) -> bool:
	var controller = scene.get_node_or_null("EAGLCarController3D")
	if controller == null:
		push_error("VALIDATION MCLAREN missing controller")
		return false
	controller._ready()
	var state: Dictionary = controller.debug_state()
	if int(state.get("spin_pivot_count", 0)) != 4 or int(state.get("steer_pivot_count", 0)) < 2:
		push_error("VALIDATION controller did not cache wheel pivots: %s" % state)
		return false
	var first_spin := _first_meta_node(scene, "eagl_spin_pivot", true) as Node3D
	var first_steer := _first_meta_node(scene, "eagl_steer_pivot", true) as Node3D
	if first_spin == null or first_steer == null:
		push_error("VALIDATION controller smoke could not find pivot nodes")
		return false
	controller.local_longitudinal_speed = 12.0
	controller.steer = 0.5
	controller._update_wheel_visuals(0.1)
	if absf(first_spin.rotation.x) <= 0.001 or absf(first_steer.rotation.y) <= 0.001:
		push_error("VALIDATION controller smoke expected spin and steer pivot movement, got spin=%.4f steer=%.4f" % [first_spin.rotation.x, first_steer.rotation.y])
		return false
	state = controller.debug_state()
	var wheel_states: Dictionary = state.get("wheel_states", {})
	if wheel_states.size() != 4:
		push_error("VALIDATION controller expected 4 decoded wheel states, got %s" % wheel_states.keys())
		return false
	var ackermann: Dictionary = state.get("ackermann", {})
	var fl_angle := absf(float(ackermann.get("FL", 0.0)))
	var fr_angle := absf(float(ackermann.get("FR", 0.0)))
	if fl_angle <= fr_angle:
		push_error("VALIDATION controller Ackermann expected left/inner wheel angle > right/outer angle for left steer, got FL=%.4f FR=%.4f" % [fl_angle, fr_angle])
		return false
	for required in ["normal_force", "aero_force", "rolling_force", "suspension_force", "engine_rpm", "gear", "gear_ratio", "drivetrain_mode", "engine_torque", "wheel_torque", "engine_brake_force"]:
		if not state.has(required):
			push_error("VALIDATION controller missing force telemetry %s: %s" % [required, state])
			return false
	if not _validate_controller_drivetrain(controller):
		return false
	if not _validate_controller_tire_force_budget(controller):
		return false
	return true


func _validate_controller_drivetrain(controller) -> bool:
	controller.reset_motion()
	controller.throttle = 1.0
	controller.brake = 0.0
	controller.local_longitudinal_speed = 16.0
	controller.engine_rpm = controller._engine_redline_rpm() * 0.96
	controller.current_gear = 1
	controller.shift_timer = 0.0
	controller._update_drivetrain(1.0 / 60.0)
	if int(controller.current_gear) <= 1:
		push_error("VALIDATION controller drivetrain expected automatic upshift near redline, got gear=%s rpm=%.1f" % [controller.current_gear, controller.engine_rpm])
		return false
	controller.reset_motion()
	controller.throttle = 1.0
	controller.current_gear = 1
	var target_gear := mini(4, controller._gear_count())
	for gear in range(1, target_gear):
		controller.shift_timer = 0.0
		controller.local_longitudinal_speed = controller._gear_upshift_speed(controller.current_gear, controller._gear_count()) + 1.0
		controller.engine_rpm = controller._engine_peak_rpm()
		controller._update_drivetrain(1.0 / 60.0)
	if int(controller.current_gear) < target_gear:
		push_error("VALIDATION controller drivetrain expected speed-window upshift to gear %d, got gear=%s" % [target_gear, controller.current_gear])
		return false
	controller.reset_motion()
	controller.throttle = 0.0
	controller.brake = 1.0
	controller.local_longitudinal_speed = 0.0
	controller.reverse_hold_timer = float(controller.tuning.get("reverse_hold_delay", 0.10))
	controller._update_drivetrain(1.0 / 60.0)
	if int(controller.current_gear) != -1:
		push_error("VALIDATION controller drivetrain expected reverse engagement, got gear=%s mode=%s" % [controller.current_gear, controller.drivetrain_mode])
		return false
	var state: Dictionary = controller.debug_state()
	if String(state.get("gear_label", "")) != "R" or float(state.get("engine_rpm", 0.0)) <= 0.0:
		push_error("VALIDATION controller drivetrain debug state missing reverse/RPM telemetry: %s" % state)
		return false
	return true


func _validate_controller_tire_force_budget(controller) -> bool:
	controller.reset_motion()
	controller._init_wheel_states()
	controller.velocity = Vector3(24.0, 0.0, -50.0)
	controller.angular_velocity = Vector3.ZERO
	controller.throttle = 1.0
	controller.brake = 0.25
	controller.handbrake = false
	controller.steer = 0.85
	controller._update_ackermann_steering()
	var wheel_states: Dictionary = controller.wheel_states
	var state: Dictionary = wheel_states.get("FL", {})
	if state.is_empty():
		push_error("VALIDATION controller tire budget missing FL wheel state")
		return false
	state["grounded"] = true
	state["contact_normal"] = Vector3.UP
	state["normal_force"] = 3500.0
	state["longitudinal_force"] = 0.0
	state["lateral_force"] = 0.0
	wheel_states["FL"] = state
	controller.wheel_states = wheel_states
	var result: Dictionary = controller._resolve_wheel_force("FL", Basis.IDENTITY, controller._mass(), 1.0 / 60.0)
	state = controller.wheel_states.get("FL", {})
	var longitudinal_grip := float(controller.tuning.get("front_longitudinal_grip", controller.tuning.get("rear_longitudinal_grip", 7.0)))
	var lateral_grip := float(controller.tuning.get("front_lateral_grip", controller.tuning.get("lateral_grip", 8.0)))
	var long_limit := maxf(float(state.get("normal_force", 0.0)) * longitudinal_grip, 1.0)
	var lat_limit := maxf(float(state.get("normal_force", 0.0)) * lateral_grip * float(state.get("tire_slip_falloff", 1.0)), 1.0)
	var saturation := sqrt(pow(float(state.get("longitudinal_force", 0.0)) / long_limit, 2.0) + pow(float(state.get("lateral_force", 0.0)) / lat_limit, 2.0))
	if saturation > 1.001:
		push_error("VALIDATION controller tire force exceeded combined grip budget: %.4f state=%s result=%s" % [saturation, state, result])
		return false
	if absf(float(result.get("yaw_torque", 0.0))) > 10000000.0:
		push_error("VALIDATION controller tire yaw torque is unstable: %s" % result)
		return false
	return true


func _first_meta_node(root: Node, meta_name: String, expected):
	for node in root.find_children("*", "Node", true, false):
		if node.has_meta(meta_name) and node.get_meta(meta_name) == expected:
			return node
	return null
