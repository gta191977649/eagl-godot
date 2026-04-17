class_name EaglObjectModel
extends RefCounted


static func collect_models(elf, include_models: Dictionary = {}) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var syms = elf.data_symbol("__Model:::")
	for sym in syms:
		var label: String = sym.name.substr(10)
		if not include_models.is_empty() and not include_models.has(label):
			continue
		var model = _read_model(elf, sym, label)
		if not model.is_empty():
			out.append(model)
	return out


static func _read_model(elf, sym: Dictionary, label: String) -> Dictionary:
	var num_layers = elf.u32(sym.value + 0x9c)
	var names_ptr = elf.u32(sym.value + 0xa0)
	var layers_ptr = elf.u32(sym.value + 0xcc)
	if layers_ptr == 0:
		return {}
	if num_layers == 0 and elf.u32(layers_ptr) == 0xa0000000:
		return {"name": label, "layers": [_read_segmented_layer(elf, layers_ptr, label)]}
	if num_layers == 0:
		return {}
	return {"name": label, "layers": _read_layers(elf, label, num_layers, names_ptr, layers_ptr)}


static func _read_layers(elf, label: String, num_layers: int, names_ptr: int, layers_ptr: int) -> Array[Dictionary]:
	var cursor = layers_ptr
	var old_format = elf.u32(cursor) == 0xa0000000
	cursor += 4
	if old_format:
		cursor += 8
	var out: Array[Dictionary] = []
	for layer_index in range(num_layers):
		var layer_name = _layer_name(elf, label, names_ptr, layer_index)
		var local = cursor + (8 if old_format else 0)
		var prim_count = elf.u32(local)
		if old_format:
			prim_count = int(prim_count / 2)
		var entries_base = local + 4
		out.append({
			"name": layer_name,
			"entries_base": entries_base,
			"primitive_count": prim_count,
			"old_format": old_format
		})
		cursor = entries_base + prim_count * (8 if old_format else 4)
	return out


static func _read_segmented_layer(elf, layers_ptr: int, label: String) -> Dictionary:
	var raw_count = elf.u32(layers_ptr + 8)
	return {
		"name": label,
		"entries_base": layers_ptr + 12,
		"primitive_count": int(raw_count / 2),
		"old_format": true
	}


static func _layer_name(elf, label: String, names_ptr: int, layer_index: int) -> String:
	if names_ptr != 0:
		var name_ptr = elf.u32(names_ptr + layer_index * 4)
		if name_ptr != 0:
			return elf.cstring(name_ptr)
	return "%s_layer_%d" % [label, layer_index]


static func render_descriptor_for(elf, layer: Dictionary, prim_index: int) -> int:
	var stride = 8 if layer.old_format else 4
	var offset = 4 if layer.old_format else 0
	return elf.u32(layer.entries_base + prim_index * stride + offset)
