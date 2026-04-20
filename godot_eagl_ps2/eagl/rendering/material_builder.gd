class_name EAGLMaterialBuilder
extends RefCounted

const MathUtils := preload("res://eagl/utils/math_utils.gd")

const PS2_VERTEX_COLOR_MODULATE_SCALE := 255.0 / 128.0

var _materials: Dictionary = {}
var texture_bank = null
var _texture_shaders: Dictionary = {}
var texture_filter_mode := "linear_mipmap"


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

	if material_role.begins_with("hp2_car") and uses_vertex_colors:
		var fallback_shader_material := ShaderMaterial.new()
		fallback_shader_material.shader = _get_flat_color_shader(use_lighting)
		fallback_shader_material.resource_name = "EAGL_%s_%03d" % [object_name, block_index]
		fallback_shader_material.set_shader_parameter("albedo_tint", _fallback_color(object_name, block, block_index, material_role, light_material_hash))
		fallback_shader_material.set_shader_parameter("use_vertex_color", uses_vertex_colors)
		fallback_shader_material.set_shader_parameter("vertex_color_modulate_scale", PS2_VERTEX_COLOR_MODULATE_SCALE)
		fallback_shader_material.set_shader_parameter("vertex_color_floor", _vertex_color_floor_for_role(material_role))
		fallback_shader_material.set_shader_parameter("surface_roughness", _roughness_for_role(material_role))
		fallback_shader_material.set_meta("eagl_light_material_hash", light_material_hash)
		fallback_shader_material.set_meta("eagl_material_role", material_role)
		fallback_shader_material.set_meta("eagl_missing_texture_hash", texture_hash)
		_materials[key] = fallback_shader_material
		return fallback_shader_material

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
	if material_role.begins_with("hp2_car"):
		return 0.22
	return 0.0


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
