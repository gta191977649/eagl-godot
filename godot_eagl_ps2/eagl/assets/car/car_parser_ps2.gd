class_name CarParserPS2
extends "res://eagl/assets/track/track_parser_ps2.gd"

const CarAssetScript = preload("res://eagl/assets/car/car_asset.gd")

const CHUNK_CAR_ASSEMBLY_ROOT := 0x80034020
const CHUNK_CAR_ASSEMBLY_HEADER := 0x00034021
const CHUNK_CAR_PART_BUNDLE := 0x00034030


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
	asset.metadata["bundle_size"] = bundle.size()
	asset.metadata["chunk_count"] = _walk_chunks(chunks).size()
	asset.metadata["parser"] = "CarParserPS2"
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
