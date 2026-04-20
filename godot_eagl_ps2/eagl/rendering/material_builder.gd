class_name EAGLMaterialBuilder
extends RefCounted

const MathUtils := preload("res://eagl/utils/math_utils.gd")
const HP2CarOpaqueShader := preload("res://eagl/shader/hp2_car_opaque.gdshader")
const HP2CarAlphaShader := preload("res://eagl/shader/hp2_car_alpha.gdshader")

const PS2_VERTEX_COLOR_MODULATE_SCALE := 255.0 / 128.0
const HP2_CARLIGHT_MIN := Vector3(0.58, 0.59, 0.58)
const HP2_CARLIGHT_MAX := Vector3(2.0, 2.0, 2.0)
const HP2_CAR_GLASS_TEXTURE_HASHES := {
	0x7B220DDF: "WINDOW_FRONT",
	0xE7E4EF49: "WINDOW_LEFT_FRONT",
	0x60F8B13C: "WINDOW_RIGHT_FRONT",
	0x0AB88F5D: "WINDOW_RIGHT_REAR",
	0x4CDEBFCA: "WINDOW_LEFT_REAR",
	0x1B0763A0: "WINDOW_REAR",
}

var _materials: Dictionary = {}
var texture_bank = null
var _texture_shaders: Dictionary = {}
var texture_filter_mode := "linear_mipmap"
var material_library: Dictionary = {}


func material_for_block(object_name: String, block: Dictionary, block_index: int, uses_vertex_colors: bool, texture_hash: int = 0, light_material_hash: int = 0, material_role: String = "") -> Material:
	var use_lighting := _should_use_lit_material(object_name, material_role)
	var key := "%s:%s:%s:%s:%s" % [
		object_name,
		texture_hash,
		"%s:%s:%s" % [block.get("render_flag", 0), light_material_hash, material_role],
		texture_filter_mode,
		("%s_%s" % ["lit" if use_lighting else "unlit", "vc" if uses_vertex_colors else "flat"]),
	]
	if _materials.has(key):
		return _materials[key]

	if texture_bank != null and texture_hash != 0 and texture_bank.has_texture(texture_hash):
		var texture = texture_bank.get_texture(texture_hash)
		var info: Dictionary = texture_bank.get_info(texture_hash)
		var alpha_mode: String = info.get("alpha_mode", "")
		var source_alpha_mode := alpha_mode
		var alpha_cutoff: float = float(info.get("alpha_cutoff", 0.5))
		var force_opaque_road_edge := _should_force_opaque_road_edge(object_name, info, int(block.get("render_flag", 0)))
		if force_opaque_road_edge:
			alpha_mode = ""
		var double_sided := _should_double_side_alpha(object_name, info, int(block.get("render_flag", 0)))
		if material_role.begins_with("hp2_car"):
			var car_material := _create_hp2_car_material(
				object_name,
				block,
				block_index,
				uses_vertex_colors,
				texture_hash,
				light_material_hash,
				material_role,
				texture,
				info,
				alpha_mode,
				source_alpha_mode,
				alpha_cutoff,
				double_sided,
				force_opaque_road_edge
			)
			_materials[key] = car_material
			return car_material
		var shader_material := ShaderMaterial.new()
		shader_material.shader = _get_texture_shader(alpha_mode, double_sided, use_lighting)
		shader_material.resource_name = "EAGL_%s" % info.get("name", "texture")
		shader_material.set_shader_parameter("albedo_texture", texture)
		shader_material.set_shader_parameter("albedo_tint", Color.WHITE)
		shader_material.set_shader_parameter("use_vertex_color", uses_vertex_colors)
		shader_material.set_shader_parameter("vertex_color_modulate_scale", PS2_VERTEX_COLOR_MODULATE_SCALE)
		shader_material.set_shader_parameter("vertex_color_floor", _vertex_color_floor_for_role(material_role))
		shader_material.set_shader_parameter("alpha_cutoff", alpha_cutoff)
		shader_material.set_shader_parameter("surface_roughness", _roughness_for_role(material_role))
		shader_material.set_meta("eagl_texture_name", info.get("name", ""))
		shader_material.set_meta("eagl_light_material_hash", light_material_hash)
		shader_material.set_meta("eagl_material_role", material_role)
		shader_material.set_meta("eagl_alpha_mode", source_alpha_mode)
		shader_material.set_meta("eagl_effective_alpha_mode", alpha_mode)
		shader_material.set_meta("eagl_alpha_cutoff", alpha_cutoff)
		shader_material.set_meta("eagl_double_sided", double_sided)
		shader_material.set_meta("eagl_texture_filter_mode", texture_filter_mode)
		shader_material.set_meta("eagl_use_lighting", use_lighting)
		shader_material.set_meta("eagl_force_opaque_road_edge", force_opaque_road_edge)
		shader_material.set_meta("eagl_vertex_color_modulate_scale", PS2_VERTEX_COLOR_MODULATE_SCALE)
		shader_material.set_meta("eagl_is_any_semitransparency", info.get("is_any_semitransparency", 0))
		shader_material.set_meta("eagl_alpha_bits", info.get("alpha_bits", 0))
		shader_material.set_meta("eagl_alpha_fix", info.get("alpha_fix", 0))
		_materials[key] = shader_material
		return shader_material

	if material_role.begins_with("hp2_car"):
		var fallback_car_material := _create_hp2_car_material(
			object_name,
			block,
			block_index,
			uses_vertex_colors,
			texture_hash,
			light_material_hash,
			material_role,
			null,
			{},
			"BLEND" if _should_use_alpha_car_shader(object_name, material_role, "", texture_hash) else "",
			"",
			0.5,
			true,
			false
		)
		fallback_car_material.set_meta("eagl_missing_texture_hash", texture_hash)
		_materials[key] = fallback_car_material
		return fallback_car_material

	var material := StandardMaterial3D.new()
	material.resource_name = "EAGL_%s_%03d" % [object_name, block_index]
	material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL if use_lighting else BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.texture_filter = _base_material_texture_filter()
	material.vertex_color_use_as_albedo = uses_vertex_colors
	material.albedo_color = Color.WHITE if uses_vertex_colors else _fallback_color(object_name, block, block_index, material_role, light_material_hash)
	material.roughness = _roughness_for_role(material_role)
	material.set_meta("eagl_light_material_hash", light_material_hash)
	material.set_meta("eagl_material_role", material_role)
	_materials[key] = material
	return material


func clear() -> void:
	_materials.clear()
	_texture_shaders.clear()


func distance_fade_material(base_material: Material, end_distance: float, fade_window: float) -> Material:
	var shader_material := base_material as ShaderMaterial
	if shader_material == null:
		return base_material
	var material := shader_material.duplicate() as ShaderMaterial
	if bool(shader_material.get_meta("eagl_hp2_car_shader", false)):
		material.shader = HP2CarAlphaShader
	else:
		material.shader = _get_texture_shader(
			"BLEND",
			bool(shader_material.get_meta("eagl_double_sided", true)),
			bool(shader_material.get_meta("eagl_use_lighting", true)),
			true
		)
	material.set_shader_parameter("distance_fade_enabled", true)
	material.set_shader_parameter("distance_fade_end", end_distance)
	material.set_shader_parameter("distance_fade_window", fade_window)
	material.set_meta("eagl_distance_fade", true)
	material.set_meta("eagl_distance_fade_end", end_distance)
	material.set_meta("eagl_distance_fade_window", fade_window)
	return material


func _create_hp2_car_material(
	object_name: String,
	block: Dictionary,
	block_index: int,
	uses_vertex_colors: bool,
	texture_hash: int,
	light_material_hash: int,
	material_role: String,
	texture,
	texture_info: Dictionary,
	alpha_mode: String,
	source_alpha_mode: String,
	alpha_cutoff: float,
	double_sided: bool,
	force_opaque_road_edge: bool
) -> ShaderMaterial:
	var use_texture := texture != null
	var is_glass := _is_hp2_glass_surface(object_name, texture_hash)
	var effective_role := "hp2_car_glass" if is_glass else material_role
	var effective_alpha_mode := "BLEND" if is_glass and alpha_mode == "" else alpha_mode
	var use_alpha := _should_use_alpha_car_shader(object_name, material_role, effective_alpha_mode, texture_hash)
	var material := ShaderMaterial.new()
	material.shader = HP2CarAlphaShader if use_alpha else HP2CarOpaqueShader
	material.resource_name = "EAGL_%s" % texture_info.get("name", "%s_%03d" % [object_name, block_index])
	material.set_shader_parameter("use_texture", use_texture)
	if use_texture:
		material.set_shader_parameter("albedo_texture", texture)
	material.set_shader_parameter("albedo_tint", _car_albedo_tint(object_name, block, block_index, material_role, light_material_hash, use_texture, texture_hash))
	material.set_shader_parameter("use_vertex_color", uses_vertex_colors and not is_glass)
	material.set_shader_parameter("vertex_color_modulate_scale", PS2_VERTEX_COLOR_MODULATE_SCALE)
	material.set_shader_parameter("vertex_color_floor", _vertex_color_floor_for_role(effective_role))
	material.set_shader_parameter("vertex_color_blend", _vertex_color_blend_for_car_surface(object_name, effective_role))
	material.set_shader_parameter("alpha_cutoff", alpha_cutoff)
	material.set_shader_parameter("surface_roughness", _roughness_for_role(effective_role))
	if use_alpha:
		material.set_shader_parameter("use_alpha_scissor", effective_alpha_mode == "MASK")
	_apply_hp2_car_shader_profile(material, object_name, effective_role, texture_hash, light_material_hash)
	material.set_meta("eagl_hp2_car_shader", true)
	material.set_meta("eagl_shader_path", material.shader.resource_path)
	material.set_meta("eagl_texture_name", texture_info.get("name", ""))
	if is_glass and String(material.get_meta("eagl_texture_name", "")) == "":
		material.set_meta("eagl_texture_name", HP2_CAR_GLASS_TEXTURE_HASHES.get(texture_hash, "GLASS"))
	material.set_meta("eagl_light_material_hash", light_material_hash)
	material.set_meta("eagl_material_role", effective_role)
	material.set_meta("eagl_source_material_role", material_role)
	material.set_meta("eagl_alpha_mode", source_alpha_mode)
	material.set_meta("eagl_effective_alpha_mode", effective_alpha_mode)
	material.set_meta("eagl_alpha_cutoff", alpha_cutoff)
	material.set_meta("eagl_double_sided", double_sided)
	material.set_meta("eagl_texture_filter_mode", texture_filter_mode)
	material.set_meta("eagl_use_lighting", false)
	material.set_meta("eagl_force_opaque_road_edge", force_opaque_road_edge)
	material.set_meta("eagl_vertex_color_modulate_scale", PS2_VERTEX_COLOR_MODULATE_SCALE)
	material.set_meta("eagl_is_any_semitransparency", texture_info.get("is_any_semitransparency", 0))
	material.set_meta("eagl_alpha_bits", texture_info.get("alpha_bits", 0))
	material.set_meta("eagl_alpha_fix", texture_info.get("alpha_fix", 0))
	return material


func _apply_hp2_car_shader_profile(material: ShaderMaterial, object_name: String, material_role: String, texture_hash: int = 0, light_material_hash: int = 0) -> void:
	var profile := _hp2_material_profile(light_material_hash, material_role, object_name, texture_hash)
	var name := object_name.to_upper()
	var role := material_role.to_lower()
	var diffuse_color: Vector3 = profile["diffuse_color"]
	var specular_color: Vector3 = profile["specular_color"]
	var fill := HP2_CARLIGHT_MIN
	var key := HP2_CARLIGHT_MAX
	var reflection := specular_color
	var ambient_floor := 0.76
	var material_exposure := 1.38
	var shade_strength := 1.0
	var diffuse := 1.0
	var top_light := 0.32
	var reflection_strength := clampf(float(profile.get("reflection_strength", 0.0)) * 0.95, 0.0, 1.6)
	var fresnel_scaler := clampf(float(profile.get("fresnel_scaler", 1.6)), 0.4, 4.0)
	var specular_strength := clampf(float(profile.get("specular_strength", 0.0)), 0.0, 2.0)
	var specular_power := clampf(float(profile.get("specular_power", 8.0)), 1.0, 80.0)
	var specular_hotspot_exponent := clampf(specular_power * 4.0, 8.0, 80.0)
	var specular_sun_intensity := 0.0
	var reflection_mask_floor := clampf(float(profile.get("reflection_floor", 0.0)), 0.0, 0.85)
	var roughness := _roughness_from_specular_exponent(specular_power)
	if role.contains("tire"):
		ambient_floor = 0.46
		material_exposure = 1.05
		reflection_strength *= 0.35
		specular_strength *= 0.35
		reflection_mask_floor = 0.0
	elif role.contains("brake"):
		ambient_floor = 0.54
		material_exposure = 1.12
		reflection_strength *= 0.55
		reflection_mask_floor = 0.02
	elif role.contains("dashboard"):
		ambient_floor = 0.52
		material_exposure = 1.08
		reflection_strength *= 0.35
		specular_strength *= 0.35
		reflection_mask_floor = 0.0
	elif _is_hp2_glass_surface(name, texture_hash) or role.contains("glass"):
		ambient_floor = 0.58
		material_exposure = 1.18
		reflection_strength = maxf(reflection_strength, 1.0)
		specular_strength = maxf(specular_strength, 0.85)
		reflection_mask_floor = maxf(reflection_mask_floor, 0.65)
	else:
		ambient_floor = maxf(ambient_floor, 0.72 + float(profile.get("reflection_floor", 0.0)) * 0.18)
		specular_strength = maxf(specular_strength, 0.45)
		reflection_strength = maxf(reflection_strength, 0.18)
		if name.contains("LIGHT") or name.contains("LAMP"):
			reflection_strength = maxf(reflection_strength, 0.75)
			specular_strength = maxf(specular_strength, 0.65)
			reflection_mask_floor = 0.16
		elif name.contains("MIRROR") or name.contains("PLATE"):
			reflection_strength = maxf(reflection_strength, 0.72)
			specular_strength = maxf(specular_strength, 0.7)
			reflection_mask_floor = 0.18
	roughness = _roughness_from_specular_exponent(specular_power)
	fill = fill.max(diffuse_color * 0.42)
	material.set_shader_parameter("fill_light_color", fill)
	material.set_shader_parameter("key_light_color", key)
	material.set_shader_parameter("reflection_color", reflection)
	material.set_shader_parameter("ambient_floor", ambient_floor)
	material.set_shader_parameter("material_exposure", material_exposure)
	material.set_shader_parameter("shade_strength", shade_strength)
	material.set_shader_parameter("diffuse_strength", diffuse)
	material.set_shader_parameter("top_light_strength", top_light)
	material.set_shader_parameter("reflection_strength", reflection_strength)
	material.set_shader_parameter("fresnel_scaler", fresnel_scaler)
	material.set_shader_parameter("specular_color", specular_color)
	material.set_shader_parameter("specular_strength", specular_strength)
	material.set_shader_parameter("specular_power", specular_power)
	material.set_shader_parameter("specular_hotspot_exponent", specular_hotspot_exponent)
	material.set_shader_parameter("specular_sun_intensity", specular_sun_intensity)
	material.set_shader_parameter("reflection_mask_floor", reflection_mask_floor)
	material.set_shader_parameter("surface_roughness", roughness)
	material.set_meta("eagl_ps2_material_profile", {
		"source_material_hash": light_material_hash,
		"source_material_name": profile.get("name", ""),
		"source": profile.get("source", ""),
		"diffuse_color": diffuse_color,
		"specular_color": specular_color,
		"specular_power": specular_power,
		"specular_hotspot_exponent": specular_hotspot_exponent,
		"fresnel_scaler": fresnel_scaler,
		"carlight_min": HP2_CARLIGHT_MIN,
		"carlight_max": HP2_CARLIGHT_MAX,
	})


func _hp2_material_profile(light_material_hash: int, material_role: String, object_name: String, texture_hash: int = 0) -> Dictionary:
	var record := _hp2_material_record(light_material_hash)
	if record.is_empty():
		record = _fallback_material_record(material_role, object_name, texture_hash)
	var values: Array = record.get("values", [])
	return {
		"name": record.get("name", ""),
		"hash": record.get("hash", light_material_hash),
		"source": record.get("source", ""),
		"diffuse_color": _hp2_material_vec3(values, 4, Vector3.ONE),
		"reflection_floor": _hp2_material_float(values, 7, 0.18),
		"specular_color": _hp2_material_vec3(values, 8, Vector3.ONE),
		"reflection_strength": _hp2_material_float(values, 11, 0.18),
		"specular_power": _hp2_material_float(values, 12, 8.0),
		"fresnel_scaler": _hp2_material_float(values, 13, 1.6),
		"specular_strength": maxf(_hp2_material_float(values, 7, 0.18), _hp2_material_float(values, 11, 0.18)),
	}


func _hp2_material_record(light_material_hash: int) -> Dictionary:
	if material_library.has(light_material_hash):
		return material_library[light_material_hash]
	return {}


func _fallback_material_record(material_role: String, object_name: String, texture_hash: int = 0) -> Dictionary:
	var role := material_role.to_lower()
	var name := object_name.to_upper()
	if role.contains("tire"):
		return _hp2_named_material_record("Rubber")
	if role.contains("brake"):
		return _hp2_named_material_record("Brakes")
	if role.contains("dashboard"):
		return _hp2_named_material_record("Interior")
	if _is_hp2_glass_surface(name, texture_hash) or role.contains("glass"):
		var glass := _hp2_named_material_record("Window911B")
		return glass if not glass.is_empty() else _hp2_named_material_record("Window911")
	if name.contains("LIGHT") or name.contains("LAMP"):
		return _hp2_named_material_record("Refheadlight")
	if name.contains("MIRROR"):
		return _hp2_named_material_record("Mirror")
	var default_record := _hp2_named_material_record("Default")
	if default_record.is_empty():
		default_record = {
			"name": "Fallback",
			"hash": 0,
			"source": "built-in material fallback",
			"values": [0.0, 0.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.25, 1.0, 1.0, 1.0, 0.25, 8.0, 1.6, 1.0, 1.0],
		}
	return default_record


func _hp2_named_material_record(material_name: String) -> Dictionary:
	for record in material_library.values():
		if String(record.get("name", "")).to_lower() == material_name.to_lower():
			return record
	return {}


func _hp2_material_vec3(values: Array, index: int, fallback: Vector3) -> Vector3:
	if values.size() <= index + 2:
		return fallback
	return Vector3(float(values[index]), float(values[index + 1]), float(values[index + 2]))


func _hp2_material_float(values: Array, index: int, fallback: float) -> float:
	if values.size() <= index:
		return fallback
	return float(values[index])


func _roughness_from_specular_exponent(exponent: float) -> float:
	return clampf(sqrt(2.0 / maxf(exponent + 2.0, 0.0001)), 0.08, 0.7)


func _car_albedo_tint(object_name: String, block: Dictionary, block_index: int, material_role: String, light_material_hash: int, use_texture: bool, texture_hash: int = 0) -> Color:
	if _is_hp2_glass_surface(object_name, texture_hash):
		return Color(0.38, 0.62, 0.76, 0.38)
	if use_texture:
		return Color.WHITE
	return _fallback_color(object_name, block, block_index, material_role, light_material_hash)


func _should_use_alpha_car_shader(object_name: String, material_role: String, alpha_mode: String, texture_hash: int = 0) -> bool:
	if alpha_mode == "MASK" or alpha_mode == "BLEND":
		return true
	var name := object_name.to_upper()
	return _is_hp2_glass_surface(name, texture_hash) or material_role.to_lower().contains("wheel_blur")


func _is_hp2_glass_surface(object_name: String, texture_hash: int = 0) -> bool:
	if HP2_CAR_GLASS_TEXTURE_HASHES.has(texture_hash):
		return true
	return _is_glass_like_name(object_name.to_upper())


func _is_glass_like_name(name: String) -> bool:
	return name.contains("GLASS") or name.contains("WINDOW") or name.contains("WINDSHIELD")


func _fallback_color(object_name: String, block: Dictionary, block_index: int, material_role: String = "", light_material_hash: int = 0) -> Color:
	if material_role.begins_with("hp2_car"):
		var name := object_name.to_upper()
		if name.contains("TIRE"):
			return Color(0.42, 0.42, 0.4, 1.0)
		if name.contains("BRAKE"):
			return Color(0.18, 0.18, 0.17, 1.0)
		if name.contains("GLASS") or name.contains("WINDOW"):
			return Color(0.08, 0.1, 0.12, 0.85)
		if name.begins_with("MCLAREN") or name.begins_with("F50"):
			return Color(0.78, 0.06, 0.08, 1.0)
	var seed := hash(object_name) ^ int(block.get("texture_index", 0)) ^ (int(block.get("render_flag", 0)) << 8) ^ block_index ^ light_material_hash
	return MathUtils.deterministic_color(seed)


func _should_double_side_alpha(object_name: String, texture_info: Dictionary, render_flag: int) -> bool:
	var alpha_mode: String = texture_info.get("alpha_mode", "")
	if alpha_mode == "":
		return true
	var name := object_name.to_upper()
	if name in ["WATER", "SKYDOME", "SKYDOME_ENVMAP"]:
		return false
	if name.begins_with("RD_") or name.begins_with("RDDRT_") or name.begins_with("TRN_") or name.begins_with("LI_") or name.begins_with("TRACK_HELICOPTER"):
		return false
	if render_flag == 0x4041 or render_flag == 0xC180:
		return false
	return true


func _should_force_opaque_road_edge(object_name: String, texture_info: Dictionary, render_flag: int) -> bool:
	if String(texture_info.get("alpha_mode", "")) == "":
		return false
	if int(texture_info.get("is_any_semitransparency", 0)) != 0:
		return false
	if render_flag == 0x4041 or render_flag == 0xC180:
		return true

	var object_name_upper := object_name.to_upper()
	if object_name_upper.begins_with("RD_") or object_name_upper.begins_with("RDDRT_") or object_name_upper.begins_with("DIRTRD_") or object_name_upper.begins_with("TRN_"):
		return true

	var texture_name := String(texture_info.get("name", "")).to_upper()
	return (
		texture_name.begins_with("ROAD")
		or texture_name.begins_with("W_ROAD")
		or texture_name.begins_with("T_ROAD")
		or texture_name.begins_with("T_DIRTRD")
		or texture_name.begins_with("SHLD_")
		or texture_name.begins_with("D_TERRAIN")
		or texture_name.begins_with("A_DIRT")
	)


func _should_use_lit_material(object_name: String, material_role: String = "") -> bool:
	if material_role.begins_with("hp2_car"):
		return false
	var name := object_name.to_upper()
	return not (name.begins_with("SKYDOME") or name.contains("ENVMAP") or name == "WATER")


func _roughness_for_role(material_role: String) -> float:
	if material_role.begins_with("hp2_car"):
		return 0.45
	return 1.0


func _vertex_color_floor_for_role(material_role: String) -> float:
	if material_role == "hp2_car_tire":
		return 0.3
	if material_role == "hp2_car_brake":
		return 0.34
	if material_role == "hp2_car_dashboard":
		return 0.36
	if material_role.begins_with("hp2_car"):
		return 0.55
	return 0.0


func _vertex_color_blend_for_car_surface(object_name: String, material_role: String) -> float:
	var role := material_role.to_lower()
	var name := object_name.to_upper()
	if role.contains("glass"):
		return 0.0
	if role.contains("tire") or role.contains("brake") or role.contains("dashboard"):
		return 1.0
	if name.contains("LIGHT") or name.contains("LAMP"):
		return 0.45
	return 0.08


func _get_flat_color_shader(use_lighting: bool) -> Shader:
	var key := "flat:%s" % ["lit" if use_lighting else "unlit"]
	if _texture_shaders.has(key):
		return _texture_shaders[key]
	var shader := Shader.new()
	var lighting_mode := "" if use_lighting else "unshaded, "
	shader.code = """
shader_type spatial;
render_mode %scull_disabled, depth_draw_opaque;

uniform vec4 albedo_tint : source_color = vec4(1.0);
uniform bool use_vertex_color = true;
uniform float vertex_color_modulate_scale = 1.9921875;
uniform float vertex_color_floor = 0.0;
uniform float surface_roughness = 1.0;

void fragment() {
	vec4 base = albedo_tint;
	if (use_vertex_color) {
		vec3 lit_color = min(base.rgb * COLOR.rgb * vertex_color_modulate_scale, vec3(1.0));
		base.rgb = max(lit_color, base.rgb * vertex_color_floor);
		base.a *= COLOR.a;
	}
	ALBEDO = base.rgb;
	ALPHA = base.a;
	ROUGHNESS = surface_roughness;
}
""" % lighting_mode
	_texture_shaders[key] = shader
	return shader


func _get_texture_shader(alpha_mode: String, double_sided: bool, use_lighting: bool, distance_fade: bool = false) -> Shader:
	var sampler_filter := _sampler_filter_hint()
	var key := "%s:%s:%s:%s:%s" % [alpha_mode, "double" if double_sided else "single", "lit" if use_lighting else "unlit", sampler_filter, "distance_fade" if distance_fade else "static"]
	if _texture_shaders.has(key):
		return _texture_shaders[key]
	var shader := Shader.new()
	var cull_mode := "cull_disabled"
	var lighting_mode := "" if use_lighting else "unshaded, "
	var render_mode := "%s%s, depth_draw_opaque" % [lighting_mode, cull_mode]
	if alpha_mode == "BLEND" or distance_fade:
		render_mode = "%s%s, blend_mix, depth_prepass_alpha" % [lighting_mode, cull_mode]
	var alpha_lines := ""
	if alpha_mode == "MASK":
		alpha_lines = "\n\tALPHA = base.a;\n\tALPHA_SCISSOR_THRESHOLD = alpha_cutoff;"
	elif alpha_mode == "BLEND" or distance_fade:
		alpha_lines = "\n\tALPHA = base.a;"
	shader.code = """
shader_type spatial;
render_mode %s;

uniform sampler2D albedo_texture : source_color, repeat_enable, %s;
uniform vec4 albedo_tint : source_color = vec4(1.0);
uniform bool use_vertex_color = true;
uniform float vertex_color_modulate_scale = 1.9921875;
uniform float vertex_color_floor = 0.0;
uniform float alpha_cutoff = 0.5;
uniform bool distance_fade_enabled = false;
uniform float distance_fade_end = 0.0;
uniform float distance_fade_window = 0.0;
uniform float surface_roughness = 1.0;

varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec4 base = albedo_tint * texture(albedo_texture, UV);
	if (use_vertex_color) {
		vec3 lit_color = min(base.rgb * COLOR.rgb * vertex_color_modulate_scale, vec3(1.0));
		base.rgb = max(lit_color, base.rgb * vertex_color_floor);
		base.a *= COLOR.a;
	}
	if (distance_fade_enabled && distance_fade_end > 0.0) {
		float camera_distance = distance(CAMERA_POSITION_WORLD, world_position);
		float fade_alpha = camera_distance <= distance_fade_end
			? 1.0
			: clamp((distance_fade_end + max(distance_fade_window, 0.0) - camera_distance) / max(distance_fade_window, 0.0001), 0.0, 1.0);
		base.a *= fade_alpha;
	}
	ALBEDO = base.rgb;
	ROUGHNESS = surface_roughness;
%s
}
""" % [
	render_mode,
	sampler_filter,
	alpha_lines,
]
	_texture_shaders[key] = shader
	return shader


func _sampler_filter_hint() -> String:
	match texture_filter_mode:
		"nearest":
			return "filter_nearest"
		"linear":
			return "filter_linear"
		"nearest_mipmap":
			return "filter_nearest_mipmap"
		"nearest_mipmap_anisotropic":
			return "filter_nearest_mipmap_anisotropic"
		"linear_mipmap_anisotropic":
			return "filter_linear_mipmap_anisotropic"
	return "filter_linear_mipmap"


func _base_material_texture_filter() -> int:
	match texture_filter_mode:
		"nearest":
			return BaseMaterial3D.TEXTURE_FILTER_NEAREST
		"linear":
			return BaseMaterial3D.TEXTURE_FILTER_LINEAR
		"nearest_mipmap":
			return BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
		"nearest_mipmap_anisotropic":
			return BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS_ANISOTROPIC
		"linear_mipmap_anisotropic":
			return BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
