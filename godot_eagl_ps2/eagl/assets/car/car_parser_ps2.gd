class_name CarParserPS2
extends "res://eagl/assets/track/track_parser_ps2.gd"

const CarAssetScript = preload("res://eagl/assets/car/car_asset.gd")
const MathUtils = preload("res://eagl/utils/math_utils.gd")

const CHUNK_CAR_METADATA := 0x00034013
const CHUNK_CAR_ASSEMBLY_ROOT := 0x80034020
const CHUNK_CAR_ASSEMBLY_HEADER := 0x00034021
const CHUNK_CAR_ASSEMBLY_ALIGN := 0x00034026
const CHUNK_CAR_PART_BUNDLE := 0x00034030
const HP2_TIRE_DUMMY_FRONT_LEFT := 0xACEC665C
const HP2_TIRE_DUMMY_FRONT_RIGHT := 0x4AE7F96F
const HP2_TIRE_DUMMY_REAR_LEFT := 0x7EFCF06F
const HP2_TIRE_DUMMY_REAR_RIGHT := 0x5F09C5E2
const HP2_TIRE_DUMMY_REAR_LEFT_AUX := 0xBEA9AEE6
const HP2_TIRE_DUMMY_REAR_RIGHT_AUX := 0x944E5339
const HP2_FRONT_WHEEL_LOCATOR_LEFT := 0x05F63788
const HP2_FRONT_WHEEL_LOCATOR_RIGHT := 0xC52BF01B
const HP2_REAR_WHEEL_LOCATOR_LEFT := 0xD947F346
const HP2_REAR_WHEEL_LOCATOR_RIGHT := 0x02B52399

# Derived from HP2_AttachedPartLocatorScan_FUN_00120360:
# the game recognizes fixed locator hash families, then attaches runtime wheel parts to those records.
# We follow the same model instead of using generic position-based fallback.
const ORIGINAL_WHEEL_SLOT_SPECS := [
	{
		"slot_id": "FL",
		"axle": "front",
		"side": "left",
		"families": [
			{"hashes": [HP2_TIRE_DUMMY_FRONT_LEFT], "source": "front_tire_dummy"},
			{"hashes": [HP2_FRONT_WHEEL_LOCATOR_LEFT], "source": "front_wheel_locator"},
		],
	},
	{
		"slot_id": "FR",
		"axle": "front",
		"side": "right",
		"families": [
			{"hashes": [HP2_TIRE_DUMMY_FRONT_RIGHT], "source": "front_tire_dummy"},
			{"hashes": [HP2_FRONT_WHEEL_LOCATOR_RIGHT], "source": "front_wheel_locator"},
		],
	},
	{
		"slot_id": "RL",
		"axle": "rear",
		"side": "left",
		"families": [
			{"hashes": [HP2_TIRE_DUMMY_REAR_LEFT], "source": "rear_tire_dummy"},
			{"hashes": [HP2_REAR_WHEEL_LOCATOR_LEFT], "source": "rear_wheel_locator"},
		],
	},
	{
		"slot_id": "RR",
		"axle": "rear",
		"side": "right",
		"families": [
			{"hashes": [HP2_TIRE_DUMMY_REAR_RIGHT], "source": "rear_tire_dummy"},
			{"hashes": [HP2_REAR_WHEEL_LOCATOR_RIGHT], "source": "rear_wheel_locator"},
		],
	},
]


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
	asset.assembly_tables = _parse_assembly_tables(chunks, bundle)
	_parse_objects_into(asset, chunks, bundle)
	asset.locators = _parse_locator_records(chunks, bundle)
	asset.wheel_slots = _infer_wheel_slots(asset.locators)
	asset.metadata["bundle_size"] = bundle.size()
	asset.metadata["chunk_count"] = _walk_chunks(chunks).size()
	asset.metadata["parser"] = "CarParserPS2"
	asset.metadata["locators"] = asset.locators.duplicate(true)
	asset.metadata["wheel_slots"] = asset.wheel_slots.duplicate(true)
	asset.metadata["assembly_tables"] = asset.assembly_tables.duplicate(true)
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


func _parse_assembly_tables(chunks: Array[Dictionary], bundle: PackedByteArray) -> Dictionary:
	var root := {}
	var root_index := -1
	var chunk_index := 0
	for chunk in chunks:
		if int(chunk.get("id", 0)) == CHUNK_CAR_ASSEMBLY_ROOT:
			root = chunk
			root_index = chunk_index
			break
		chunk_index += 1
	if root.is_empty():
		return {}

	var out := {}
	var header_chunk := _child_with_id(root, CHUNK_CAR_ASSEMBLY_HEADER)
	if not header_chunk.is_empty():
		var payload := _payload(bundle, header_chunk)
		if payload.size() >= 0x30:
			out["header_pairs"] = {
				"translation_keys_and_channels": _u16_pair(Binary.u32(payload, 0x10)),
				"rotation_keys_and_bytes": _u16_pair(Binary.u32(payload, 0x14)),
				"index_count_and_bytes": _u16_pair(Binary.u32(payload, 0x18)),
				"node_count_and_bytes": _u16_pair(Binary.u32(payload, 0x1C)),
				"graph_count_and_bytes": _u16_pair(Binary.u32(payload, 0x20)),
				"offset_pair_0": _u16_pair(Binary.u32(payload, 0x24)),
				"offset_pair_1": _u16_pair(Binary.u32(payload, 0x28)),
				"offset_pair_2": _u16_pair(Binary.u32(payload, 0x2C)),
			}

	var translation_chunk := _child_with_id(root, 0x00034024)
	if not translation_chunk.is_empty():
		out["translation_keys"] = _parse_assembly_translation_keys(_payload(bundle, translation_chunk))

	var rotation_chunk := _child_with_id(root, 0x00034022)
	if not rotation_chunk.is_empty():
		out["rotation_keys"] = _parse_assembly_rotation_keys(_payload(bundle, rotation_chunk))

	var channel_chunk := _child_with_id(root, 0x00034023)
	if not channel_chunk.is_empty():
		out["channel_records"] = _parse_assembly_u32_triplets(_payload(bundle, channel_chunk))

	var graph_chunk := _child_with_id(root, 0x00034025)
	if not graph_chunk.is_empty():
		var payload := _payload(bundle, graph_chunk)
		out["graph_header_words"] = _parse_assembly_u32_words(payload, 0x40)
		out["graph_payload_size"] = payload.size()
		if payload.size() >= 0x70:
			out["body_group_root_word_offsets"] = [
				Binary.u32(payload, 0x34),
				Binary.u32(payload, 0x4C),
				Binary.u32(payload, 0x64),
			]
			out["body_group_root_byte_offsets"] = [
				Binary.u32(payload, 0x34) * 4,
				Binary.u32(payload, 0x4C) * 4,
				Binary.u32(payload, 0x64) * 4,
			]

	var align_chunk := _child_with_id(root, CHUNK_CAR_ASSEMBLY_ALIGN)
	if align_chunk.is_empty() and root_index >= 0 and root_index + 1 < chunks.size():
		var sibling: Dictionary = chunks[root_index + 1]
		if int(sibling.get("id", 0)) == CHUNK_CAR_ASSEMBLY_ALIGN:
			align_chunk = sibling
	if not align_chunk.is_empty():
		out["align_payload"] = _parse_assembly_u32_words(_payload(bundle, align_chunk), 0x10)

	return out


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


func _parse_assembly_translation_keys(payload: PackedByteArray) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if payload.size() < 8:
		return out
	for offset in range(8, payload.size() - 0x13, 0x14):
		out.append({
			"word_00": Binary.u32(payload, offset + 0x00),
			"position_ps2": Vector3(
				Binary.f32(payload, offset + 0x04),
				Binary.f32(payload, offset + 0x08),
				Binary.f32(payload, offset + 0x0C)
			),
			"tag": Binary.u32(payload, offset + 0x10),
		})
	return out


func _parse_assembly_rotation_keys(payload: PackedByteArray) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for offset in range(0, payload.size() - 0x17, 0x18):
		out.append({
			"header": Binary.u32(payload, offset + 0x00),
			"quat_x": Binary.f32(payload, offset + 0x04),
			"quat_y": Binary.f32(payload, offset + 0x08),
			"quat_z": Binary.f32(payload, offset + 0x0C),
			"quat_w": Binary.f32(payload, offset + 0x10),
			"tag": Binary.u32(payload, offset + 0x14),
		})
	return out


func _parse_assembly_u32_triplets(payload: PackedByteArray) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if payload.size() >= 8 and Binary.u32(payload, 0x00) == 0x11111111 and Binary.u32(payload, 0x04) == 0x11111111:
		payload = payload.slice(8)
	for offset in range(0, payload.size() - 0x0B, 0x0C):
		out.append({
			"word_00": Binary.u32(payload, offset + 0x00),
			"word_04": Binary.u32(payload, offset + 0x04),
			"word_08": Binary.u32(payload, offset + 0x08),
		})
	return out


func _parse_assembly_u32_words(payload: PackedByteArray, byte_limit: int) -> Array[int]:
	var out: Array[int] = []
	var limit := mini(payload.size(), byte_limit)
	for offset in range(0, limit - 3, 4):
		out.append(Binary.u32(payload, offset))
	return out


func _u16_pair(value: int) -> Dictionary:
	return {
		"lo": value & 0xFFFF,
		"hi": (value >> 16) & 0xFFFF,
	}


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
	var out: Array[Dictionary] = []
	for spec in ORIGINAL_WHEEL_SLOT_SPECS:
		var slot := _infer_wheel_slot_from_original_locators(locators, spec)
		if not slot.is_empty():
			out.append(slot)
	return out


func _infer_wheel_slot_from_original_locators(locators: Array[Dictionary], spec: Dictionary) -> Dictionary:
	var families: Array = spec.get("families", [])
	for family_variant in families:
		var family: Dictionary = family_variant
		var matches := _slot_locator_matches(locators, spec, family.get("hashes", []))
		if matches.is_empty():
			continue
		var primary_match: Dictionary = matches[0]
		var p := _average_locator_position(matches)
		return {
			"slot_id": String(spec.get("slot_id", "")),
			"axle": String(spec.get("axle", "")),
			"side": String(spec.get("side", "")),
			"source": "original_locator_family_%s" % String(family.get("source", "unknown")),
			"position_ps2": p,
			"position_godot": MathUtils.ps2_to_godot_vec3(p),
			"primary_locator_hash": int(primary_match.get("hash_08", 0)),
			"primary_locator_index": int(primary_match.get("index", -1)),
			"locator_variant_index": int(primary_match.get("locator_variant_index", -1)),
			"locator_orientation_index": int(primary_match.get("locator_orientation_index", -1)),
			"locator_hashes": Array(matches.map(func(locator: Dictionary) -> int: return int(locator.get("hash_08", 0)))),
			"locator_indices": Array(matches.map(func(locator: Dictionary) -> int: return int(locator.get("index", -1)))),
			"match_count": matches.size(),
		}
	return {}


func _slot_locator_matches(locators: Array[Dictionary], spec: Dictionary, hashes: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var side := String(spec.get("side", ""))
	for locator in locators:
		var hash := int(locator.get("hash_08", 0))
		if not hashes.has(hash):
			continue
		var p: Vector3 = locator.get("position_ps2", Vector3.ZERO)
		if side == "left" and p.y <= 0.1:
			continue
		if side == "right" and p.y >= -0.1:
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
