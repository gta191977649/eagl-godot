class_name EAGLMaterialBuilder
extends RefCounted

const MathUtils := preload("res://eagl/utils/math_utils.gd")

const PS2_VERTEX_COLOR_MODULATE_SCALE := 255.0 / 128.0
const WHEEL_RIM_MATERIAL_HASH := 0x001d38b3
const WHEEL_CAP_MATERIAL_HASH := 0xc8c5a8a4
const BRAKE_DISC_MATERIAL_HASH := 0xcd677a20

var _materials: Dictionary = {}
var texture_bank = null
var _texture_shaders: Dictionary = {}
var _procedural_shaders: Dictionary = {}
var texture_filter_mode := "linear_mipmap"
var use_scene_lighting := true


func material_for_block(object_name: String, block: Dictionary, block_index: int, uses_vertex_colors: bool, texture_hash: int = 0) -> Material:
	var use_lighting := _should_use_lit_material(object_name)
	var fallback_kind := _fallback_material_kind(object_name, texture_hash)
	var texture_info: Dictionary = texture_bank.get_info(texture_hash) if texture_bank != null and texture_hash != 0 and texture_bank.has_texture(texture_hash) else {}
	var texture_uses_vertex_color := uses_vertex_colors and not _should_ignore_texture_vertex_color(object_name, texture_info)
	var texture_repeat_enabled := not _should_clamp_texture_uv(object_name, texture_info)
	var key := "%s:%s:%s:%s:%s" % [
		object_name,
		texture_hash,
		block.get("render_flag", 0),
		texture_filter_mode,
		("%s_%s_%s_%s" % ["lit" if use_lighting else "unlit", "vc" if texture_uses_vertex_color else "flat", "repeat" if texture_repeat_enabled else "clamp", fallback_kind]),
	]
	if _materials.has(key):
		return _materials[key]

	if texture_bank != null and texture_hash != 0 and texture_bank.has_texture(texture_hash):
		var texture = texture_bank.get_texture(texture_hash)
		var info: Dictionary = texture_info
		var alpha_mode: String = info.get("alpha_mode", "")
		var source_alpha_mode := alpha_mode
		var alpha_cutoff: float = float(info.get("alpha_cutoff", 0.5))
		var force_opaque_road_edge := _should_force_opaque_road_edge(object_name, info, int(block.get("render_flag", 0)))
		if force_opaque_road_edge:
			alpha_mode = ""
		var double_sided := _should_double_side_alpha(object_name, info, int(block.get("render_flag", 0)))
		var shader_material := ShaderMaterial.new()
		shader_material.shader = _get_texture_shader(alpha_mode, double_sided, use_lighting, false, texture_repeat_enabled)
		shader_material.resource_name = "EAGL_%s" % info.get("name", "texture")
		shader_material.set_shader_parameter("albedo_texture", texture)
		shader_material.set_shader_parameter("albedo_tint", Color.WHITE)
		shader_material.set_shader_parameter("use_vertex_color", texture_uses_vertex_color)
		shader_material.set_shader_parameter("vertex_color_modulate_scale", PS2_VERTEX_COLOR_MODULATE_SCALE)
		shader_material.set_shader_parameter("alpha_cutoff", alpha_cutoff)
		shader_material.set_meta("eagl_texture_name", info.get("name", ""))
		shader_material.set_meta("eagl_alpha_mode", source_alpha_mode)
		shader_material.set_meta("eagl_effective_alpha_mode", alpha_mode)
		shader_material.set_meta("eagl_alpha_cutoff", alpha_cutoff)
		shader_material.set_meta("eagl_double_sided", double_sided)
		shader_material.set_meta("eagl_texture_filter_mode", texture_filter_mode)
		shader_material.set_meta("eagl_texture_repeat_enabled", texture_repeat_enabled)
		shader_material.set_meta("eagl_use_lighting", use_lighting)
		shader_material.set_meta("eagl_force_opaque_road_edge", force_opaque_road_edge)
		shader_material.set_meta("eagl_vertex_color_modulate_scale", PS2_VERTEX_COLOR_MODULATE_SCALE)
		shader_material.set_meta("eagl_use_vertex_color", texture_uses_vertex_color)
		shader_material.set_meta("eagl_is_any_semitransparency", info.get("is_any_semitransparency", 0))
		shader_material.set_meta("eagl_alpha_bits", info.get("alpha_bits", 0))
		shader_material.set_meta("eagl_alpha_fix", info.get("alpha_fix", 0))
		_materials[key] = shader_material
		return shader_material

	if fallback_kind == "license_plate":
		var plate_material := ShaderMaterial.new()
		plate_material.shader = _get_license_plate_shader(use_lighting)
		plate_material.resource_name = "EAGL_%s_plate" % object_name
		plate_material.set_meta("eagl_fallback_material_kind", fallback_kind)
		_materials[key] = plate_material
		return plate_material
	if fallback_kind == "brake_disc":
		var brake_material := ShaderMaterial.new()
		brake_material.shader = _get_brake_disc_shader(use_lighting)
		brake_material.resource_name = "EAGL_%s_brake_disc" % object_name
		brake_material.set_shader_parameter("use_vertex_color", uses_vertex_colors)
		brake_material.set_shader_parameter("vertex_color_modulate_scale", PS2_VERTEX_COLOR_MODULATE_SCALE)
		brake_material.set_meta("eagl_fallback_material_kind", fallback_kind)
		_materials[key] = brake_material
		return brake_material

	var material := StandardMaterial3D.new()
	material.resource_name = "EAGL_%s_%03d" % [object_name, block_index]
	material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL if use_lighting else BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.texture_filter = _base_material_texture_filter()
	material.vertex_color_use_as_albedo = uses_vertex_colors and fallback_kind == ""
	material.albedo_color = _fallback_material_color(fallback_kind, object_name, block, block_index, uses_vertex_colors)
	material.metallic = _fallback_material_metallic(fallback_kind)
	material.roughness = _fallback_material_roughness(fallback_kind)
	material.set_meta("eagl_fallback_material_kind", fallback_kind)
	_materials[key] = material
	return material


func clear() -> void:
	_materials.clear()
	_texture_shaders.clear()
	_procedural_shaders.clear()


func distance_fade_material(base_material: Material, end_distance: float, fade_window: float) -> Material:
	var shader_material := base_material as ShaderMaterial
	if shader_material == null:
		return base_material
	var material := shader_material.duplicate() as ShaderMaterial
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


func _fallback_color(object_name: String, block: Dictionary, block_index: int) -> Color:
	var seed := hash(object_name) ^ int(block.get("texture_index", 0)) ^ (int(block.get("render_flag", 0)) << 8) ^ block_index
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


func _should_use_lit_material(object_name: String) -> bool:
	if not use_scene_lighting:
		return false
	var name := object_name.to_upper()
	return not (name.begins_with("SKYDOME") or name.contains("ENVMAP") or name == "WATER")


func _should_ignore_texture_vertex_color(object_name: String, texture_info: Dictionary) -> bool:
	var object_upper := object_name.to_upper()
	var texture_name := String(texture_info.get("name", "")).to_upper()
	return object_upper.contains("_TIRE_") and texture_name.ends_with("_TIRE")


func _should_clamp_texture_uv(object_name: String, texture_info: Dictionary) -> bool:
	var object_upper := object_name.to_upper()
	var texture_name := String(texture_info.get("name", "")).to_upper()
	return object_upper.contains("_TIRE_") and texture_name.ends_with("_TIRE")


func _should_use_brake_material(object_name: String) -> bool:
	return object_name.to_upper().contains("_BRAKE_")


func _fallback_material_kind(object_name: String, texture_hash: int) -> String:
	var name := object_name.to_upper()
	if name.contains("LICENSE_PLATE") or name.ends_with("_PLATE") or name.contains("_PLATE_"):
		return "license_plate"
	if _should_use_brake_material(name) or texture_hash == BRAKE_DISC_MATERIAL_HASH:
		return "brake_disc"
	if name.contains("_TIRE_") and texture_hash == WHEEL_RIM_MATERIAL_HASH:
		return "wheel_rim"
	if name.contains("_TIRE_") and texture_hash == WHEEL_CAP_MATERIAL_HASH:
		return "wheel_cap"
	if name.contains("_TIRE_"):
		return "tire_rubber"
	return ""


func _fallback_material_color(fallback_kind: String, object_name: String, block: Dictionary, block_index: int, uses_vertex_colors: bool) -> Color:
	match fallback_kind:
		"brake_disc":
			return Color(0.34, 0.32, 0.29, 1.0)
		"wheel_rim":
			return Color(0.46, 0.47, 0.46, 1.0)
		"wheel_cap":
			return Color(0.05, 0.05, 0.045, 1.0)
		"tire_rubber":
			return Color(0.012, 0.012, 0.011, 1.0)
	return Color.WHITE if uses_vertex_colors else _fallback_color(object_name, block, block_index)


func _fallback_material_metallic(fallback_kind: String) -> float:
	match fallback_kind:
		"brake_disc":
			return 0.55
		"wheel_rim":
			return 0.72
		"wheel_cap":
			return 0.18
		"tire_rubber":
			return 0.0
	return 0.0


func _fallback_material_roughness(fallback_kind: String) -> float:
	match fallback_kind:
		"brake_disc":
			return 0.42
		"wheel_rim":
			return 0.30
		"wheel_cap":
			return 0.68
		"tire_rubber":
			return 0.82
	return 1.0


func _get_texture_shader(alpha_mode: String, double_sided: bool, use_lighting: bool, distance_fade: bool = false, repeat_enabled: bool = true) -> Shader:
	var sampler_filter := _sampler_filter_hint()
	var key := "%s:%s:%s:%s:%s:%s" % [alpha_mode, "double" if double_sided else "single", "lit" if use_lighting else "unlit", sampler_filter, "repeat" if repeat_enabled else "clamp", "distance_fade" if distance_fade else "static"]
	if _texture_shaders.has(key):
		return _texture_shaders[key]
	var shader := Shader.new()
	var cull_mode := "cull_disabled"
	var lighting_mode := "" if use_lighting else "unshaded, "
	var repeat_mode := "repeat_enable" if repeat_enabled else "repeat_disable"
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

uniform sampler2D albedo_texture : source_color, %s, %s;
uniform vec4 albedo_tint : source_color = vec4(1.0);
uniform bool use_vertex_color = true;
uniform float vertex_color_modulate_scale = 1.9921875;
uniform float alpha_cutoff = 0.5;
uniform bool distance_fade_enabled = false;
uniform float distance_fade_end = 0.0;
uniform float distance_fade_window = 0.0;

varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec4 base = albedo_tint * texture(albedo_texture, UV);
	if (use_vertex_color) {
		base.rgb = min(base.rgb * COLOR.rgb * vertex_color_modulate_scale, vec3(1.0));
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
	ROUGHNESS = 1.0;
%s
}
""" % [
	render_mode,
	repeat_mode,
	sampler_filter,
	alpha_lines,
]
	_texture_shaders[key] = shader
	return shader


func _get_license_plate_shader(use_lighting: bool) -> Shader:
	var key := "license_plate:%s" % ["lit" if use_lighting else "unlit"]
	if _procedural_shaders.has(key):
		return _procedural_shaders[key]
	var shader := Shader.new()
	var lighting_mode := "" if use_lighting else "unshaded, "
	shader.code = """
shader_type spatial;
render_mode %scull_disabled, depth_draw_opaque;

void fragment() {
	vec2 uv = clamp(UV, vec2(0.0), vec2(1.0));
	vec3 base = vec3(0.86, 0.84, 0.74);
	float edge = step(uv.x, 0.07) + step(1.0 - uv.x, 0.07) + step(uv.y, 0.12) + step(1.0 - uv.y, 0.12);
	float mid_band = step(abs(uv.y - 0.47), 0.025);
	float glyph_a = step(abs(uv.x - 0.30), 0.035) * step(abs(uv.y - 0.48), 0.18);
	float glyph_b = step(abs(uv.x - 0.50), 0.035) * step(abs(uv.y - 0.48), 0.18);
	float glyph_c = step(abs(uv.x - 0.70), 0.035) * step(abs(uv.y - 0.48), 0.18);
	float ink = clamp(edge + mid_band + glyph_a + glyph_b + glyph_c, 0.0, 1.0);
	ALBEDO = mix(base, vec3(0.025, 0.03, 0.035), ink);
	ROUGHNESS = 0.58;
}
""" % [lighting_mode]
	_procedural_shaders[key] = shader
	return shader


func _get_brake_disc_shader(use_lighting: bool) -> Shader:
	var key := "brake_disc:%s" % ["lit" if use_lighting else "unlit"]
	if _procedural_shaders.has(key):
		return _procedural_shaders[key]
	var shader := Shader.new()
	var lighting_mode := "" if use_lighting else "unshaded, "
	shader.code = """
shader_type spatial;
render_mode %scull_disabled, depth_draw_opaque;

uniform bool use_vertex_color = true;
uniform float vertex_color_modulate_scale = 1.9921875;

void fragment() {
	vec2 uv = clamp(UV, vec2(0.0), vec2(1.0));
	vec2 p = (uv - vec2(0.5)) * 2.0;
	float radius = length(p);
	float angle = atan(p.y, p.x);

	float outer_mask = 1.0 - smoothstep(0.84, 0.90, radius);
	float inner_hub = 1.0 - smoothstep(0.18, 0.22, radius);
	float ring = smoothstep(0.20, 0.27, radius) * (1.0 - smoothstep(0.68, 0.76, radius));
	float slot_wave = abs(sin(angle * 8.0 + radius * 9.0));
	float slot = (1.0 - smoothstep(0.08, 0.18, slot_wave)) * ring;
	float rim_shadow = smoothstep(0.66, 0.78, radius) * (1.0 - smoothstep(0.78, 0.84, radius));

	vec3 disc = mix(vec3(0.20, 0.195, 0.18), vec3(0.52, 0.51, 0.47), smoothstep(0.18, 0.70, radius));
	disc = mix(disc, vec3(0.05, 0.05, 0.045), clamp(slot + rim_shadow * 0.65, 0.0, 1.0));
	disc = mix(disc, vec3(0.40, 0.39, 0.36), inner_hub);
	if (use_vertex_color) {
		disc = min(disc * COLOR.rgb * vertex_color_modulate_scale, vec3(1.0));
	}

	ALBEDO = disc;
	METALLIC = 0.55;
	ROUGHNESS = 0.42;
	ALPHA = outer_mask;
	ALPHA_SCISSOR_THRESHOLD = 0.35;
}
""" % [lighting_mode]
	_procedural_shaders[key] = shader
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
