class_name CarParserPS2
extends "res://eagl/assets/track/track_parser_ps2.gd"

const CarAssetScript = preload("res://eagl/assets/car/car_asset.gd")
const MathUtils = preload("res://eagl/utils/math_utils.gd")

const CHUNK_CAR_METADATA := 0x00034013
const CHUNK_CAR_ASSEMBLY_ROOT := 0x80034020
const CHUNK_CAR_ASSEMBLY_HEADER := 0x00034021
const CHUNK_CAR_PART_BUNDLE := 0x00034030
const HP2_TIRE_DUMMY_FRONT_LEFT := 0xACEC665C
const HP2_TIRE_DUMMY_FRONT_RIGHT := 0x4AE7F96F
const HP2_TIRE_DUMMY_REAR_LEFT := 0x7EFCF06F
const HP2_TIRE_DUMMY_REAR_RIGHT := 0x5F09C5E2
const HP2_TIRE_DUMMY_REAR_LEFT_AUX := 0xBEA9AEE6
const HP2_TIRE_DUMMY_REAR_RIGHT_AUX := 0x944E5339


func parse(files: Dictionary):
	var asset = CarAssetScript.new()
	asset.car_id = files.get("car_id", "")
	asset.source_path = files.get("model", "")
	asset.source_files = files.duplicate(true)
	if asset.source_path == "":
		asset.add_warning("Car parser received no model path")
		return asset

	var bundle = Binary.load_bundle_bytes(asset.source_path)
	if bundle.is_empty():
		asset.add_warning("Car bundle is empty or failed to load: %s" % asset.source_path)
		return asset

	var chunks = _parse_chunks(bundle)
	asset.part_bundles = _parse_part_bundles(chunks, bundle)
	asset.assembly_summary = _parse_assembly_summary(chunks, bundle)
	_parse_objects_into(asset, chunks, bundle)
	asset.locators = _parse_locator_records(chunks, bundle)
	asset.wheel_slots = _infer_wheel_slots(asset.locators)
	asset.metadata["bundle_size"] = bundle.size()
	asset.metadata["chunk_count"] = _walk_chunks(chunks).size()
	asset.metadata["parser"] = "CarParserPS2"
	asset.metadata["locators"] = asset.locators.duplicate(true)
	asset.metadata["wheel_slots"] = asset.wheel_slots.duplicate(true)
	return asset


func _parse_objects_into(asset, chunks: Array[Dictionary], bundle: PackedByteArray) -> void:
	for chunk in _walk_chunks(chunks):
		if int(chunk.get("id", 0)) != 0x80034000:
			continue
		for child in chunk.get("children", []):
			if int(child.get("id", 0)) != 0x80034002:
				continue
			var obj = _parse_mesh_object(child, bundle)
			if obj.is_empty():
				continue
			obj["attachment_refs"] = _read_attachment_refs(_child_with_id(child, 0x0003401d), bundle)
			obj["has_animation_payload"] = not _child_with_id(child, 0x00034012).is_empty()
			asset.objects.append(obj)


func _parse_part_bundles(chunks: Array[Dictionary], bundle: PackedByteArray) -> Array[Dictionary]:
	var bundles: Array[Dictionary] = []
	for chunk in chunks:
		if int(chunk.get("id", 0)) != CHUNK_CAR_PART_BUNDLE:
			continue
		var payload = _payload(bundle, chunk)
		var name_info = _find_ascii_name(payload)
		if name_info.is_empty():
			continue
		bundles.append({
			"name": name_info["name"],
			"name_hash": Binary.u32(payload, 0x30) if payload.size() >= 0x34 else 0,
			"source_chunk_offset": int(chunk.get("offset", -1)),
			"payload_size": payload.size(),
		})
	return bundles


func _parse_assembly_summary(chunks: Array[Dictionary], bundle: PackedByteArray) -> Dictionary:
	var root = {}
	for chunk in chunks:
		if int(chunk.get("id", 0)) != CHUNK_CAR_ASSEMBLY_ROOT:
			continue
		root = chunk
		break
	if root.is_empty():
		return {}

	var header_chunk := _child_with_id(root, CHUNK_CAR_ASSEMBLY_HEADER)
	if header_chunk.is_empty():
		return {}

	var payload = _payload(bundle, header_chunk)
	if payload.size() < 0x34:
		return {}

	return {
		"body_group_count": Binary.u32(payload, 0x00),
		"wheel_group_count": Binary.u32(payload, 0x04),
		"brake_group_count": Binary.u32(payload, 0x08),
		"variant_name": _find_ascii_name(payload).get("name", ""),
	}


func _read_attachment_refs(chunk: Dictionary, bundle: PackedByteArray) -> Array[int]:
	if chunk.is_empty():
		return []
	var payload = _payload(bundle, chunk)
	var refs: Array[int] = []
	for offset in range(0, payload.size() - 3, 8):
		var value := Binary.u32(payload, offset)
		if value != 0 and value != 0x11111111:
			refs.append(value)
	return refs


func _parse_locator_records(chunks: Array[Dictionary], bundle: PackedByteArray) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for chunk in _walk_chunks(chunks):
		if int(chunk.get("id", 0)) != CHUNK_CAR_METADATA:
			continue
		var payload := _payload(bundle, chunk)
		var record_size := 0x20
		if payload.size() < record_size:
			continue
		var start_offset := 8 if payload.size() >= 0x28 and Binary.u32(payload, 0) == 0x11111111 and Binary.u32(payload, 4) == 0x11111111 else 0
		for offset in range(start_offset, payload.size() - (record_size - 1), record_size):
			var record := payload.slice(offset, offset + record_size)
			var position_ps2 := Vector3(Binary.f32(record, 0x10), Binary.f32(record, 0x14), Binary.f32(record, 0x18))
			out.append({
				"index": out.size(),
				"source_chunk_offset": int(chunk.get("offset", -1)),
				"record_offset": offset,
				"word_00": Binary.u32(record, 0x00),
				"word_04": Binary.u32(record, 0x04),
				"hash_08": Binary.u32(record, 0x08),
				"hash_0c": Binary.u32(record, 0x0C),
				"position_ps2": position_ps2,
				"position_godot": MathUtils.ps2_to_godot_vec3(position_ps2),
				"word_1c": Binary.u32(record, 0x1C),
				"locator_variant_index": int(record[0x1C]),
				"locator_orientation_index": int(record[0x1D]),
			})
	return out


func _infer_wheel_slots(locators: Array[Dictionary]) -> Array[Dictionary]:
	var by_id := {}
	for source_slots in [_infer_wheel_slots_from_runtime_dummies(locators), _infer_wheel_slots_from_locator_positions(locators)]:
		for slot in source_slots:
			var slot_dict: Dictionary = slot
			var slot_id := String(slot_dict.get("slot_id", ""))
			if slot_id == "" or by_id.has(slot_id):
				continue
			by_id[slot_id] = slot_dict
	var out: Array[Dictionary] = []
	for slot_id in ["FL", "FR", "RL", "RR"]:
		if by_id.has(slot_id):
			out.append(by_id[slot_id])
	return out


func _infer_wheel_slots_from_runtime_dummies(locators: Array[Dictionary]) -> Array[Dictionary]:
	var specs := [
		{"slot_id": "FL", "axle": "front", "side": "left", "hashes": [HP2_TIRE_DUMMY_FRONT_LEFT]},
		{"slot_id": "FR", "axle": "front", "side": "right", "hashes": [HP2_TIRE_DUMMY_FRONT_RIGHT]},
		{"slot_id": "RL", "axle": "rear", "side": "left", "hashes": [HP2_TIRE_DUMMY_REAR_LEFT, HP2_TIRE_DUMMY_REAR_LEFT_AUX]},
		{"slot_id": "RR", "axle": "rear", "side": "right", "hashes": [HP2_TIRE_DUMMY_REAR_RIGHT, HP2_TIRE_DUMMY_REAR_RIGHT_AUX]},
	]
	var out: Array[Dictionary] = []
	for spec in specs:
		var matches := _runtime_dummy_matches(locators, spec)
		if matches.is_empty():
			continue
		var primary_match: Dictionary = matches[0]
		for locator in matches:
			var hash := int(locator.get("hash_08", 0))
			if hash == int(spec.get("hashes", [0])[0]):
				primary_match = locator
				break
		var p := _average_locator_position(matches)
		out.append({
			"slot_id": String(spec.get("slot_id", "")),
			"axle": String(spec.get("axle", "")),
			"side": String(spec.get("side", "")),
			"source": "geometry_metadata_0x00034013_runtime_tire_dummies",
			"position_ps2": p,
			"position_godot": MathUtils.ps2_to_godot_vec3(p),
			"primary_locator_hash": int(primary_match.get("hash_08", 0)),
			"primary_locator_index": int(primary_match.get("index", -1)),
			"locator_variant_index": int(primary_match.get("locator_variant_index", -1)),
			"locator_orientation_index": int(primary_match.get("locator_orientation_index", -1)),
		})
	return out


func _runtime_dummy_matches(locators: Array[Dictionary], spec: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var hashes: Array = spec.get("hashes", [])
	var side := String(spec.get("side", ""))
	for locator in locators:
		var hash := int(locator.get("hash_08", 0))
		if not hashes.has(hash):
			continue
		var p: Vector3 = locator.get("position_ps2", Vector3.ZERO)
		if side == "left" and p.y <= 0.0:
			continue
		if side == "right" and p.y >= 0.0:
			continue
		if absf(p.x) > 20.0 or absf(p.y) > 20.0 or absf(p.z) > 5.0:
			continue
		out.append(locator)
	return out


func _average_locator_position(locators: Array[Dictionary]) -> Vector3:
	var total := Vector3.ZERO
	for locator in locators:
		var p: Vector3 = locator.get("position_ps2", Vector3.ZERO)
		total += p
	return total / maxf(1.0, float(locators.size()))


func _infer_wheel_slots_from_locator_positions(locators: Array[Dictionary]) -> Array[Dictionary]:
	var candidates: Array[Dictionary] = []
	for locator in locators:
		var p: Vector3 = locator.get("position_ps2", Vector3.ZERO)
		if absf(p.y) < 0.45 or p.z > 0.45:
			continue
		if absf(p.x) > 20.0 or absf(p.y) > 20.0 or absf(p.z) > 5.0:
			continue
		candidates.append(locator)
	if candidates.size() < 4:
		return []

	var min_x := INF
	var max_x := -INF
	for locator in candidates:
		var p: Vector3 = locator.get("position_ps2", Vector3.ZERO)
		min_x = minf(min_x, p.x)
		max_x = maxf(max_x, p.x)
	var mid_x := (min_x + max_x) * 0.5

	var slots: Array[Dictionary] = []
	for axle in ["front", "rear"]:
		for side in ["left", "right"]:
			var best: Dictionary = {}
			var best_score := -INF
			for locator in candidates:
				var p: Vector3 = locator.get("position_ps2", Vector3.ZERO)
				if axle == "front" and p.x < mid_x:
					continue
				if axle == "rear" and p.x >= mid_x:
					continue
				if side == "left" and p.y < 0.0:
					continue
				if side == "right" and p.y >= 0.0:
					continue
				var axle_target := max_x if axle == "front" else min_x
				var score := absf(p.y) * 10.0 - absf(p.z) - absf(p.x - axle_target) * 0.25
				if score > best_score:
					best = locator
					best_score = score
			if not best.is_empty():
				var p: Vector3 = best.get("position_ps2", Vector3.ZERO)
				slots.append({
					"slot_id": _slot_id_from_axle_side(axle, side),
					"axle": axle,
					"side": side,
					"source": "geometry_locator_0x00034013",
					"position_ps2": p,
					"position_godot": MathUtils.ps2_to_godot_vec3(p),
					"locator_index": best.get("index", -1),
					"primary_locator_hash": int(best.get("hash_08", 0)),
					"locator_variant_index": int(best.get("locator_variant_index", -1)),
					"locator_orientation_index": int(best.get("locator_orientation_index", -1)),
				})
	return slots


func _slot_id_from_axle_side(axle: String, side: String) -> String:
	if axle == "front":
		return "FR" if side == "right" else "FL"
	return "RR" if side == "right" else "RL"
