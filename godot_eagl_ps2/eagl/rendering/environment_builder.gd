class_name EAGLEnvironmentBuilder
extends RefCounted

const MathUtils := preload("res://eagl/utils/math_utils.gd")
const SunLensFlareScript := preload("res://eagl/rendering/sun_lens_flare.gd")

const SUN_DISTANCE := 10000.0
const AMBIENT_FILL_COLOR := Color(0.72, 0.78, 0.82, 1.0)
const AMBIENT_FILL_ENERGY := 1.65
const DEFAULT_SUN_LIGHT_CULL_MASK := 1 << 1


func add_track_environment(root: Node3D, asset) -> Dictionary:
	var env_config: Dictionary = asset.environment_config
	var world_environment := _add_world_environment(root, env_config)
	var sun_config: Dictionary = env_config.get("sun", {})
	if sun_config.is_empty():
		return {"world_environment": world_environment}

	var direction_ps2: Vector3 = sun_config.get("direction_ps2", Vector3.ZERO)
	if direction_ps2 == Vector3.ZERO:
		return {"world_environment": world_environment}

	var sun_direction := MathUtils.ps2_to_godot_vec3(direction_ps2).normalized()
	var sun_position := sun_direction * SUN_DISTANCE
	var light := _add_directional_sun(root, sun_direction, sun_config, int(root.get_meta("eagl_sun_light_cull_mask", DEFAULT_SUN_LIGHT_CULL_MASK)))
	var flare: CanvasLayer = _add_lens_flare(root, sun_position, sun_config, asset.texture_bank)
	root.set_meta("eagl_sun_direction_ps2", direction_ps2)
	root.set_meta("eagl_sun_direction_godot", sun_direction)
	root.set_meta("eagl_sun_flare_enabled", flare != null)
	root.set_meta("eagl_environment_config", env_config.duplicate(true))
	return {
		"sun_direction_ps2": direction_ps2,
		"sun_direction_godot": sun_direction,
		"world_environment": world_environment,
		"sun_light": light,
		"lens_flare": flare,
	}


func _add_world_environment(root: Node3D, env_config: Dictionary) -> WorldEnvironment:
	var world_environment := WorldEnvironment.new()
	world_environment.name = "EAGL_WorldEnvironment"
	var environment := Environment.new()
	environment.background_mode = Environment.BG_CLEAR_COLOR
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = _ambient_fill_color(env_config)
	environment.ambient_light_energy = AMBIENT_FILL_ENERGY
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	world_environment.environment = environment
	world_environment.set_meta("eagl_ambient_light_color", environment.ambient_light_color)
	world_environment.set_meta("eagl_ambient_light_source", "fog_main_color" if _has_fog_main_color(env_config) else "fallback")
	root.add_child(world_environment)
	return world_environment


func _add_directional_sun(root: Node3D, sun_direction: Vector3, sun_config: Dictionary, light_cull_mask: int) -> DirectionalLight3D:
	var light := DirectionalLight3D.new()
	light.name = "EAGL_Sun"
	light.light_energy = _sun_light_energy(sun_config)
	light.light_color = _sun_light_color(sun_config)
	light.light_cull_mask = light_cull_mask
	light.shadow_enabled = true
	light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	light.directional_shadow_max_distance = 12000.0
	light.directional_shadow_split_1 = 0.08
	light.directional_shadow_split_2 = 0.20
	light.directional_shadow_split_3 = 0.45
	light.shadow_bias = 0.01
	light.shadow_normal_bias = 0.20
	light.look_at_from_position(sun_direction * SUN_DISTANCE, Vector3.ZERO, Vector3.UP)
	light.set_meta("eagl_sun_direction_godot", sun_direction)
	light.set_meta("eagl_sun_config_source_chunk", sun_config.get("source_chunk_offset", -1))
	light.set_meta("eagl_enabled_light_energy", light.light_energy)
	light.set_meta("eagl_light_cull_mask", light_cull_mask)
	root.add_child(light)
	return light


func _add_lens_flare(root: Node3D, sun_position: Vector3, sun_config: Dictionary, texture_bank) -> CanvasLayer:
	var records: Array = sun_config.get("records", [])
	if records.is_empty() or texture_bank == null:
		return null
	var flare := SunLensFlareScript.new()
	flare.name = "EAGL_SunLensFlare"
	flare.configure(sun_position, records, texture_bank)
	root.add_child(flare)
	return flare


func _sun_light_color(sun_config: Dictionary) -> Color:
	for record in sun_config.get("records", []):
		if bool(record.get("enabled", false)):
			var color: Color = record.get("color", Color.WHITE)
			return Color(color.r, color.g, color.b, 1.0)
	return Color(1.0, 0.95, 0.86, 1.0)


func _ambient_fill_color(env_config: Dictionary) -> Color:
	var fog_color := _fog_main_color(env_config)
	if fog_color.a > 0.0:
		return Color(fog_color.r, fog_color.g, fog_color.b, 1.0)
	return AMBIENT_FILL_COLOR


func _has_fog_main_color(env_config: Dictionary) -> bool:
	return _fog_main_color(env_config).a > 0.0


func _fog_main_color(env_config: Dictionary) -> Color:
	var fog: Dictionary = env_config.get("fog", {})
	for record in fog.get("records", []):
		var name := String(record.get("name", "")).to_upper()
		if name.contains("MAIN"):
			return record.get("color", Color.TRANSPARENT)
	return Color.TRANSPARENT


func _sun_light_energy(sun_config: Dictionary) -> float:
	if not bool(sun_config.get("enabled", false)):
		return 1.0
	var direction: Vector3 = sun_config.get("direction_ps2", Vector3.ZERO)
	var elevation := maxf(direction.z, 0.0)
	return clampf(2.2 + elevation * 3.2, 2.4, 4.2)
