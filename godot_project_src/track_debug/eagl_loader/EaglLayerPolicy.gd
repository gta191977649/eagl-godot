class_name EaglLayerPolicy
extends RefCounted

const MODES = ["normal_only", "lod_only", "raw_all_layers"]


static func is_lod_layer(layer_name: String) -> bool:
	return layer_name.ends_with("LOD")


static func is_normal_layer(layer_name: String) -> bool:
	return layer_name in ["opaque", "alpha1", "alpha2", "alpha3", "alpha4", "alpha5"] or layer_name.begins_with("levelft.")


static func layer_visible(layer_name: String, mode: String) -> bool:
	match mode:
		"normal_only":
			return is_normal_layer(layer_name)
		"lod_only":
			return is_lod_layer(layer_name)
		"raw_all_layers":
			return true
		_:
			return is_normal_layer(layer_name)


static func next_mode(mode: String) -> String:
	var index = MODES.find(mode)
	return MODES[(index + 1) % MODES.size()] if index >= 0 else MODES[0]
