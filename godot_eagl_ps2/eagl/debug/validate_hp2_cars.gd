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
		if rendered <= 0 or not part_groups.has("Wheels") or wheel_instances < 4 or brake_instances < 4:
			failed = true
			push_error("VALIDATION MCLAREN scene missing assembled parts: rendered=%d wheels=%d brakes=%d groups=%s" % [rendered, wheel_instances, brake_instances, part_groups.keys()])
		else:
			print("VALIDATION scene MCLAREN rendered=%d wheels=%d brakes=%d textured=%s fallback=%s groups=%s" % [
				rendered,
				wheel_instances,
				brake_instances,
				scene.get_meta("eagl_textured_surface_count", 0),
				scene.get_meta("eagl_fallback_surface_count", 0),
				part_groups.keys(),
			])

	quit(1 if failed else 0)


func _validate_asset(car_id: String, asset) -> bool:
	var ok := true
	var object_count := int(asset.summary().get("object_count", 0))
	var block_count := int(asset.summary().get("block_count", 0))
	var vertex_count := int(asset.summary().get("vertex_count", 0))
	var texture_refs := int(asset.summary().get("texture_ref_count", 0))
	if object_count <= 0 or block_count <= 0 or vertex_count <= 0:
		ok = false
		push_error("VALIDATION %s expected nonzero object/block/vertex counts, got objects=%d blocks=%d vertices=%d" % [car_id, object_count, block_count, vertex_count])
	if texture_refs <= 0:
		ok = false
		push_error("VALIDATION %s expected nonzero texture refs" % car_id)
	if car_id == "F50" and int(asset.summary().get("dashboard_object_count", 0)) <= 0:
		ok = false
		push_error("VALIDATION F50 expected dashboard geometry")
	if ok:
		print("VALIDATION car %s objects=%d dashboard=%s blocks=%d vertices=%d texture_refs=%d textures=%s locators=%s" % [
			car_id,
			object_count,
			asset.summary().get("dashboard_object_count", 0),
			block_count,
			vertex_count,
			texture_refs,
			asset.summary().get("texture_count", 0),
			asset.summary().get("locator_count", 0),
		])
	return ok
