class_name EaglGodotSceneBuilder
extends RefCounted

const EaglElfObject = preload("res://track_debug/eagl_loader/EaglElfObject.gd")
const EaglMeshBuilder = preload("res://track_debug/eagl_loader/EaglMeshBuilder.gd")
const EaglObjectModel = preload("res://track_debug/eagl_loader/EaglObjectModel.gd")
const EaglPrimitiveReader = preload("res://track_debug/eagl_loader/EaglPrimitiveReader.gd")

var primitive_reader = EaglPrimitiveReader.new()
var mesh_builder = EaglMeshBuilder.new()
var skipped = {}
var warnings: Array[String] = []
var layer_counts = {}


func reset() -> void:
	skipped.clear()
	warnings.clear()
	layer_counts.clear()


func build_track_root(track_name: String, level_index: int) -> Node3D:
	var root = Node3D.new()
	root.name = "EaglTrack_%s_level%02d" % [track_name, level_index]
	return root


func build_object(path: String, include_models: Dictionary, bank, factory) -> Node3D:
	var elf = EaglElfObject.new()
	if not elf.load_file(path):
		_count_skip("bad_elf")
		_warn("bad ELF object %s: %s" % [path, elf.error])
		return error_node(elf.error)
	var root = Node3D.new()
	var models = EaglObjectModel.collect_models(elf, include_models)
	if models.is_empty():
		_count_skip("empty_model_set")
		_warn("no models loaded from %s include=%s" % [path, str(include_models.keys())])
	for model in models:
		root.add_child(_build_model_node(elf, path.get_file().get_basename(), model, bank, factory))
	return root


func error_node(message: String) -> Node3D:
	var node = Node3D.new()
	node.name = "EaglLoaderError"
	node.set_meta("error", message)
	return node


func _build_model_node(elf, comp_name: String, model: Dictionary, bank, factory) -> Node3D:
	var model_node = Node3D.new()
	model_node.name = model.name
	for layer in model.layers:
		var layer_node = _build_layer_node(elf, comp_name, layer, bank, factory)
		if layer_node.get_child_count() > 0:
			model_node.add_child(layer_node)
		else:
			layer_node.free()
	return model_node


func _build_layer_node(elf, comp_name: String, layer: Dictionary, bank, factory) -> Node3D:
	var layer_node = Node3D.new()
	layer_node.name = layer.name
	layer_node.set_meta("eagl_layer", layer.name)
	for prim_index in range(layer.primitive_count):
		var rd = EaglObjectModel.render_descriptor_for(elf, layer, prim_index)
		var prim = primitive_reader.read_primitive(elf, rd)
		if prim.has("skip") or prim.is_empty():
			_count_skip(prim.get("skip", "empty_primitive"))
			continue
		prim.layer = layer.name
		_apply_overlay_mask(prim, bank, factory)
		var material = factory.material_for(prim, bank)
		var name = "%s:%s_prim_%03d" % [comp_name, layer.name, prim_index]
		var mesh_node = mesh_builder.build_primitive_node(name, prim, material)
		_configure_geometry_instance(mesh_node)
		layer_node.add_child(mesh_node)
	if layer_node.get_child_count() > 0:
		layer_counts[layer.name] = layer_counts.get(layer.name, 0) + 1
	return layer_node


func _configure_geometry_instance(node: Node3D) -> void:
	var geometry := node as GeometryInstance3D
	if geometry != null:
		geometry.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON


func _apply_overlay_mask(prim: Dictionary, bank, factory) -> void:
	if prim.shader != "BlendedOverlay":
		return
	if factory.choose_texture(prim.shader, prim.textures) != prim.textures.get(0, ""):
		return
	var mask_name = prim.textures.get(2, "")
	if mask_name == "":
		return
	for vertex in prim.vertices:
		if not vertex.has("uv2"):
			return
	for vertex in prim.vertices:
		var color: Color = vertex.get("color", Color.WHITE)
		color.a *= bank.sample_alpha(mask_name, vertex.uv2) / 255.0
		vertex.color = color


func _count_skip(reason: String) -> void:
	skipped[reason] = skipped.get(reason, 0) + 1


func _warn(message: String) -> void:
	warnings.append(message)
