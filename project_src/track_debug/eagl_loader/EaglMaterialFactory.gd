class_name EaglMaterialFactory
extends RefCounted

var fallback_material = _make_fallback()
var missing_textures = 0
var material_cache = {}


func reset() -> void:
	missing_textures = 0
	material_cache.clear()


func material_for(primitive: Dictionary, texture_bank) -> Material:
	var shader: String = primitive.shader
	var texture_name = choose_texture(shader, primitive.textures)
	var texture_wrap: Vector2i = _wrap_for_texture(texture_name, primitive.textures, primitive.get("wraps", {}))
	var layer_name: String = primitive.get("layer", "")
	var transparent = _should_use_alpha(layer_name, shader)
	var cache_key = "%s:%s:%s:%s" % [shader, texture_name, str(texture_wrap), str(transparent)]
	if material_cache.has(cache_key):
		return material_cache[cache_key]
	var texture = texture_bank.get_texture(texture_name)
	if texture == null and texture_name != "":
		missing_textures += 1
	var material = _build_material(shader, texture_name, texture, texture_wrap, transparent)
	material_cache[cache_key] = material
	return material


func choose_texture(shader_name: String, textures: Dictionary) -> String:
	if shader_name in ["ShadowTexture", "BlendedWithShadow", "BlendedOverlay"] and textures.has(1):
		return textures[1]
	if textures.has(0):
		return textures[0]
	for key in textures.keys():
		return textures[key]
	return ""


func _wrap_for_texture(texture_name: String, textures: Dictionary, wraps: Dictionary) -> Vector2i:
	for sampler in textures.keys():
		if textures[sampler] == texture_name:
			return wraps.get(sampler, Vector2i(1, 1))
	return Vector2i(1, 1)


func _build_material(shader_name: String, texture_name: String, texture: Texture2D, texture_wrap: Vector2i, transparent: bool) -> StandardMaterial3D:
	if texture == null:
		return fallback_material
	var mat = StandardMaterial3D.new()
	mat.resource_name = "%s [%s]" % [shader_name, texture_name]
	mat.albedo_texture = texture
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.texture_repeat = _should_repeat(texture_wrap)
	mat.roughness = 1.0
	if transparent:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return mat


func _should_repeat(texture_wrap: Vector2i) -> bool:
	return not (texture_wrap.x in [3, 5] or texture_wrap.y in [3, 5])


func _should_use_alpha(layer_name: String, shader_name: String) -> bool:
	if layer_name.begins_with("opaque"):
		return false
	if layer_name.begins_with("alpha"):
		return true
	return shader_name == "BlendedOverlay"


func _make_fallback() -> StandardMaterial3D:
	var mat = StandardMaterial3D.new()
	mat.resource_name = "EAGL missing material"
	mat.albedo_color = Color(1.0, 0.0, 0.75, 1.0)
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat
