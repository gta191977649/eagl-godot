class_name EAGLDebugUtils
extends RefCounted


static func summarize_track(asset) -> Dictionary:
	if asset == null or not asset.has_method("summary"):
		return {}
	return asset.summary()


static func dump_track(asset, max_objects: int = 8) -> void:
	var summary := summarize_track(asset)
	print("EAGL track summary: ", summary)
	if asset == null:
		return
	for i in range(min(max_objects, asset.objects.size())):
		var obj: Dictionary = asset.objects[i]
		print("[%04d] %s blocks=%d" % [i, obj.get("name", ""), obj.get("blocks", []).size()])


static func dump_mesh(mesh_data: Dictionary, max_blocks: int = 8) -> Dictionary:
	var blocks: Array = mesh_data.get("blocks", [])
	var out := {
		"name": mesh_data.get("name", ""),
		"block_count": blocks.size(),
		"vertices": 0,
		"faces_expected": 0,
	}
	for i in range(min(max_blocks, blocks.size())):
		var block: Dictionary = blocks[i]
		out["vertices"] += block.get("run", {}).get("vertices", []).size()
		out["faces_expected"] += block.get("expected_face_count", 0)
	print("EAGL mesh dump: ", out)
	return out


static func compare_with_reference(actual: Dictionary, reference: Dictionary) -> Dictionary:
	var keys := {}
	for key in actual.keys():
		keys[key] = true
	for key in reference.keys():
		keys[key] = true
	var differences := {}
	for key in keys.keys():
		if actual.get(key) != reference.get(key):
			differences[key] = {"actual": actual.get(key), "reference": reference.get(key)}
	return differences
