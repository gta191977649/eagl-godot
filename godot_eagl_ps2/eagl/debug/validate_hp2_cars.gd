extends SceneTree

const ConfigScript := preload("res://eagl/core/eagl_config.gd")
const PlatformScript := preload("res://eagl/platforms/ps2/ps2_platform.gd")

const DEFAULT_GAME_ROOT := "/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA"
const SAMPLE_CARS := ["MCLAREN", "F50", "BMWM5", "CORVETTE", "BUS", "FIRETRUCK", "4DR_SEDAN", "TAXI"]


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

	var scene := platform.load_car("MCLAREN")
	if scene == null or scene.get_meta("error", "") != "":
		failed = true
		push_error("VALIDATION failed to build MCLAREN car scene")
	else:
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
		var invalid_brake_count := brake_instances > 0 and brake_instances < 4
		if rendered <= 0 or not part_groups.has("Wheels") or wheel_instances < 4 or invalid_brake_count or wheel_slot_count < 4 or spin_pivots != 4 or steer_pivots < 2 or wheels_group_tagged or wheel_blur_enabled:
			failed = true
			push_error("VALIDATION MCLAREN scene missing assembled parts: rendered=%d wheels=%d brakes=%d slots=%d spin=%d steer=%d wheels_group_tagged=%s wheel_blur_enabled=%s groups=%s" % [rendered, wheel_instances, brake_instances, wheel_slot_count, spin_pivots, steer_pivots, str(wheels_group_tagged), str(wheel_blur_enabled), part_groups.keys()])
		elif String(scene.get_meta("eagl_exact_handling_status", "")) == "" or String(scene.get_meta("eagl_wheel_slot_source", "")) == "":
			failed = true
			push_error("VALIDATION MCLAREN scene missing handling/slot metadata")
		elif not _validate_controller_smoke(scene):
			failed = true
		else:
			print("VALIDATION scene MCLAREN rendered=%d wheels=%d brakes=%d slots=%d spin=%d steer=%d textured=%s fallback=%s missing_hashes=%s groups=%s" % [
				rendered,
				wheel_instances,
				brake_instances,
				wheel_slot_count,
				spin_pivots,
				steer_pivots,
				scene.get_meta("eagl_textured_surface_count", 0),
				scene.get_meta("eagl_fallback_surface_count", 0),
				scene.get_meta("eagl_missing_texture_hashes", []).size(),
				part_groups.keys(),
			])

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
	return true


func _first_meta_node(root: Node, meta_name: String, expected):
	for node in root.find_children("*", "Node", true, false):
		if node.has_meta(meta_name) and node.get_meta(meta_name) == expected:
			return node
	return null
