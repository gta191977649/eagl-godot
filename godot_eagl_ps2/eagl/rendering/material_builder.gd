class_name EAGLMaterialBuilder
extends RefCounted

const MathUtils := preload("res://eagl/utils/math_utils.gd")

const PS2_VERTEX_COLOR_MODULATE_SCALE := 255.0 / 128.0

var _materials: Dictionary = {}
var texture_bank = null
var _texture_shaders: Dictionary = {}
var texture_filter_mode := "linear_mipmap"


func material_for_block(object_name: String, block: Dictionary, block_index: int, uses_vertex_colors: bool, texture_hash: int = 0) -> Material:
	var use_lighting := _should_use_lit_material(object_name)
	var key := "%s:%s:%s:%s:%s" % [
		object_name,
		texture_hash,
		block.get("render_flag", 0),
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
		shader_material.set_shader_parameter("alpha_cutoff", alpha_cutoff)
		shader_material.set_meta("eagl_texture_name", info.get("name", ""))
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

	var material := StandardMaterial3D.new()
	material.resource_name = "EAGL_%s_%03d" % [object_name, block_index]
	material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL if use_lighting else BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.texture_filter = _base_material_texture_filter()
	material.vertex_color_use_as_albedo = uses_vertex_colors
	material.albedo_color = Color.WHITE if uses_vertex_colors else _fallback_color(object_name, block, block_index)
	material.roughness = 1.0
	_materials[key] = material
	return material


func clear() -> void:
	_materials.clear()
	_texture_shaders.clear()


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
	var name := object_name.to_upper()
	return not (name.begins_with("SKYDOME") or name.contains("ENVMAP") or name == "WATER")


func _get_texture_shader(alpha_mode: String, double_sided: bool, use_lighting: bool) -> Shader:
	var sampler_filter := _sampler_filter_hint()
	var key := "%s:%s:%s:%s" % [alpha_mode, "double" if double_sided else "single", "lit" if use_lighting else "unlit", sampler_filter]
	if _texture_shaders.has(key):
		return _texture_shaders[key]
	var shader := Shader.new()
	var cull_mode := "cull_disabled"
	var lighting_mode := "" if use_lighting else "unshaded, "
	var render_mode := "%s%s, depth_draw_opaque" % [lighting_mode, cull_mode]
	if alpha_mode == "BLEND":
		render_mode = "%s%s, blend_mix, depth_prepass_alpha" % [lighting_mode, cull_mode]
	var alpha_lines := ""
	if alpha_mode == "MASK":
		alpha_lines = "\n\tALPHA = base.a;\n\tALPHA_SCISSOR_THRESHOLD = alpha_cutoff;"
	elif alpha_mode == "BLEND":
		alpha_lines = "\n\tALPHA = base.a;"
	shader.code = """
shader_type spatial;
render_mode %s;

uniform sampler2D albedo_texture : source_color, repeat_enable, %s;
uniform vec4 albedo_tint : source_color = vec4(1.0);
uniform bool use_vertex_color = true;
uniform float vertex_color_modulate_scale = 1.9921875;
uniform float alpha_cutoff = 0.5;

void fragment() {
	vec4 base = albedo_tint * texture(albedo_texture, UV);
	if (use_vertex_color) {
		base.rgb = min(base.rgb * COLOR.rgb * vertex_color_modulate_scale, vec3(1.0));
		base.a *= COLOR.a;
	}
	ALBEDO = base.rgb;
	ROUGHNESS = 1.0;
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
