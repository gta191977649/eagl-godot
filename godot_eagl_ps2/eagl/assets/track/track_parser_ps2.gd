class_name TrackParserPS2
extends RefCounted

const Binary := preload("res://eagl/platforms/ps2/ps2_binary_reader.gd")
const TrackAssetScript := preload("res://eagl/assets/track/track_asset.gd")

const POSITION_S16_SCALE := 1.0 / 4096.0
const POSITION_S8_SCALE := 1.0 / 128.0


func parse(files: Dictionary):
	var asset = TrackAssetScript.new()
	asset.track_id = files.get("track_id", "")
	asset.source_path = files.get("model", "")
	asset.source_files = files.duplicate(true)
	if asset.source_path == "":
		asset.add_warning("Track parser received no model path")
		return asset

	var bundle := Binary.load_bundle_bytes(asset.source_path)
	if bundle.is_empty():
		asset.add_warning("Track bundle is empty or failed to load: %s" % asset.source_path)
		return asset

	var chunks := _parse_chunks(bundle)
	_parse_scene_into(asset, chunks, bundle)
	asset.metadata["bundle_size"] = bundle.size()
	asset.metadata["chunk_count"] = _walk_chunks(chunks).size()
	asset.metadata["parser"] = "TrackParserPS2"
	return asset


func _parse_chunks(data: PackedByteArray, start: int = 0, end: int = -1) -> Array[Dictionary]:
	if end < 0:
		end = data.size()
	var chunks: Array[Dictionary] = []
	var pos := start
	while pos + 8 <= end:
		var chunk_id := Binary.u32(data, pos)
		var size := Binary.u32(data, pos + 4)
		var data_offset := pos + 8
		var chunk_end := data_offset + size
		if chunk_end > end:
			push_error("Chunk 0x%08x at 0x%x ends beyond parent region" % [chunk_id, pos])
			return chunks
		var children: Array[Dictionary] = []
		if (chunk_id & 0x80000000) != 0:
			children = _parse_chunks(data, data_offset, chunk_end)
		chunks.append({
			"id": chunk_id,
			"size": size,
			"offset": pos,
			"data_offset": data_offset,
			"end_offset": chunk_end,
			"children": children,
		})
		pos = chunk_end
	if pos != end:
		push_warning("Chunk region ended at 0x%x, expected 0x%x" % [pos, end])
	return chunks


func _parse_scene_into(asset, chunks: Array[Dictionary], bundle: PackedByteArray) -> void:
	var primary_objects: Array[Dictionary] = []
	var solid_pack_index := 0

	for chunk in _walk_chunks(chunks):
		if chunk.get("id", 0) != 0x80034000:
			continue
		var is_template_palette := solid_pack_index == 0
		var pack_objects: Array[Dictionary] = []
		for child in chunk.get("children", []):
			if child.get("id", 0) != 0x80034002:
				continue
			var obj := _parse_mesh_object(child, bundle)
			if obj.is_empty():
				continue
			obj["solid_pack_index"] = solid_pack_index
			obj["solid_pack_offset"] = chunk.get("offset", -1)
			obj["is_scenery_template"] = is_template_palette
			asset.objects.append(obj)
			pack_objects.append(obj)
			if is_template_palette:
				primary_objects.append(obj)
				asset.scenery_template_offsets[obj["chunk_offset"]] = true
		asset.solid_packs.append({
			"index": solid_pack_index,
			"source_chunk_offset": chunk.get("offset", -1),
			"is_scenery_template_palette": is_template_palette,
			"objects": pack_objects,
		})
		solid_pack_index += 1

	_assign_source_roles(asset.solid_packs)
	asset.scenery_sections = _parse_scenery_sections(chunks, bundle, asset.objects, primary_objects)
	asset.scenery_instances.clear()
	for section in asset.scenery_sections:
		asset.scenery_instances.append_array(section.get("instances", []))
	asset.unknown_chunks = _collect_unknown_chunks(chunks)


func _parse_mesh_object(object_chunk: Dictionary, bundle: PackedByteArray) -> Dictionary:
	var header_chunk := _child_with_id(object_chunk, 0x00034003)
	var run_metadata_chunk := _child_with_id(object_chunk, 0x00034004)
	var vif_data_chunk := _child_with_id(object_chunk, 0x00034005)
	var texture_refs_chunk := _child_with_id(object_chunk, 0x00034006)
	if header_chunk.is_empty() or vif_data_chunk.is_empty():
		return {}

	var header_payload := _payload(bundle, header_chunk)
	var name_info := _find_ascii_name(header_payload)
	if name_info.is_empty():
		return {}

	var vif_payload := _strip_vif_prefix(_payload(bundle, vif_data_chunk))
	var metadata_payload := PackedByteArray()
	if not run_metadata_chunk.is_empty():
		metadata_payload = _payload(bundle, run_metadata_chunk)
	var blocks: Array[Dictionary] = _extract_blocks_from_strip_entries(vif_payload, metadata_payload, name_info["name"])
	if blocks.is_empty():
		var fallback_runs := _extract_vif_vertex_runs(vif_payload)
		for run in fallback_runs:
			blocks.append({
				"run": run,
				"primitive_mode": "strip",
				"expected_face_count": 0,
				"topology_code": 0,
				"texture_index": -1,
				"render_flag": 0,
				"source_offset": -1,
				"source_qword_size": -1,
				"strip_entry": {},
			})
	if blocks.is_empty():
		return {}

	var texture_hashes: Array[int] = []
	if not texture_refs_chunk.is_empty():
		texture_hashes = _read_texture_hashes(_payload(bundle, texture_refs_chunk))

	return {
		"name": name_info["name"],
		"chunk_offset": object_chunk["offset"],
		"transform": _read_transform(header_payload, name_info["start"]),
		"blocks": blocks,
		"texture_hashes": texture_hashes,
		"name_hash": Binary.u32(header_payload, 0x08) if header_payload.size() >= 0x0C else 0,
	}


func _assign_source_roles(solid_packs: Array[Dictionary]) -> void:
	for pack in solid_packs:
		var role := "STATIC_SOLID_PACK"
		var pack_objects: Array = pack.get("objects", [])
		if bool(pack.get("is_scenery_template_palette", false)):
			role = "TEMPLATE_PALETTE"
		else:
			for obj in pack_objects:
				if _is_special_solid_object_name(obj.get("name", "")):
					role = "SPECIAL_SOLID_PACK"
					break
		pack["source_role"] = role
		for obj in pack_objects:
			obj["source_role"] = role


func _is_special_solid_object_name(object_name: String) -> bool:
	var name := object_name.to_upper()
	return name.begins_with("SKYDOME") or name.contains("ENVMAP") or name == "WATER" or (name.begins_with("TRACK") and name.contains("STARTLINE"))


func _extract_blocks_from_strip_entries(vif_payload: PackedByteArray, metadata_payload: PackedByteArray, _object_name: String) -> Array[Dictionary]:
	var clean_metadata := _strip_vif_prefix(metadata_payload)
	var record_count := clean_metadata.size() / 0x40
	if record_count <= 0:
		return []

	var blocks: Array[Dictionary] = []
	for record_index in range(record_count):
		var record := clean_metadata.slice(record_index * 0x40, record_index * 0x40 + 0x40)
		var strip_entry := _parse_strip_entry_record(record)
		var vif_offset: int = strip_entry["vif_offset"]
		var qword_size: int = strip_entry["qword_size"]
		if qword_size <= 0 or vif_offset < 0 or vif_offset + qword_size > vif_payload.size():
			return []
		var decoded := _extract_vif_vertex_runs(vif_payload.slice(vif_offset, vif_offset + qword_size))
		if decoded.size() != 1:
			return []
		var texture_index_raw: int = strip_entry["texture_index_raw"]
		blocks.append({
			"run": decoded[0],
			"primitive_mode": "strip",
			"expected_face_count": strip_entry["count_byte"],
			"topology_code": strip_entry["topology_code"],
			"texture_index": texture_index_raw if texture_index_raw != 0xFFFFFFFF else -1,
			"render_flag": strip_entry["render_flags"],
			"source_offset": vif_offset,
			"source_qword_size": qword_size,
			"strip_entry": strip_entry,
		})
	return blocks


func _parse_strip_entry_record(record: PackedByteArray) -> Dictionary:
	var texture_index_raw := Binary.u32(record, 0)
	var qword_word := Binary.u32(record, 0x0C)
	var word_1c := Binary.u32(record, 0x1C)
	var qword_count := qword_word & 0xFFFF
	return {
		"raw": record,
		"texture_index_raw": texture_index_raw,
		"vif_offset": Binary.u32(record, 0x08),
		"qword_count": qword_count,
		"qword_size": qword_count * 16,
		"render_flags": (qword_word >> 16) & 0xFFFF,
		"word_1c": word_1c,
		"topology_code": word_1c & 0xFF,
		"packed_material_or_render_index": word_1c & 0xFF,
		"vertex_count_byte": (word_1c >> 8) & 0xFF,
		"count_byte": (word_1c >> 16) & 0xFF,
		"packed_ff_or_zero": (word_1c >> 24) & 0xFF,
	}


func _extract_vif_vertex_runs(payload: PackedByteArray) -> Array[Dictionary]:
	payload = _strip_vif_prefix(payload)

	var runs: Array[Dictionary] = []
	var rows: Array = []
	var texcoords: Array[Vector2] = []
	var packed_values: Array[int] = []
	var current_header: Array[int] = []
	var current_tri_cull: Array[int] = []
	var pos := 0

	while pos + 4 <= payload.size():
		var imm := Binary.u16(payload, pos)
		var count := Binary.u8(payload, pos + 2)
		var command := Binary.u8(payload, pos + 3)
		pos += 4
		var size := _vif_command_payload_size(command, count, imm)
		if size < 0:
			if command == 0x14 or command != 0x00:
				_flush_rows(runs, rows, texcoords, packed_values, current_header, current_tri_cull)
				current_header = []
				current_tri_cull = []
			continue
		if pos + size > payload.size():
			break

		if not _is_unpack_command(command):
			if command == 0x14:
				_flush_rows(runs, rows, texcoords, packed_values, current_header, current_tri_cull)
				current_header = []
				current_tri_cull = []
			pos += size
			continue

		var base_command := _base_unpack_command(command)
		if base_command == 0x6E and imm == 0x8000 and count == 1 and size >= 4:
			_flush_rows(runs, rows, texcoords, packed_values, current_header, current_tri_cull)
			current_header = [payload[pos], payload[pos + 1], payload[pos + 2], payload[pos + 3]]
			current_tri_cull = []
		elif base_command == 0x6C and imm == 0xC001 and count == 1 and size >= 16:
			current_tri_cull = [
				Binary.u32(payload, pos),
				Binary.u32(payload, pos + 4),
				Binary.u32(payload, pos + 8),
				Binary.u32(payload, pos + 12),
			]
		elif imm >= 0xC002 and imm < 0xC020 and _has_position_layout(base_command):
			_append_position_rows(rows, command, count, payload, pos)
		elif imm >= 0xC020 and imm < 0xC034 and base_command in [0x60, 0x64, 0x68, 0x6C]:
			_append_texcoord_pairs(texcoords, command, count, payload, pos)
		elif imm >= 0xC034 and imm < 0xC040 and base_command == 0x6F:
			for i in range(count):
				packed_values.append(Binary.u16(payload, pos + i * 2))

		pos += size

	_flush_rows(runs, rows, texcoords, packed_values, current_header, current_tri_cull)
	return runs


func _flush_rows(runs: Array[Dictionary], rows: Array, texcoords: Array[Vector2], packed_values: Array[int], header: Array[int], tri_cull: Array[int]) -> void:
	if rows.size() < 3:
		rows.clear()
		texcoords.clear()
		packed_values.clear()
		return

	var vertices: Array[Vector3] = []
	var row_index := 0
	while row_index + 2 < rows.size():
		var x_row: Array = rows[row_index]
		var y_row: Array = rows[row_index + 1]
		var z_row: Array = rows[row_index + 2]
		var width: int = mini(x_row.size(), mini(y_row.size(), z_row.size()))
		for lane in range(width):
			vertices.append(Vector3(float(x_row[lane]), float(y_row[lane]), float(z_row[lane])))
		row_index += 3

	rows.clear()
	if vertices.is_empty():
		texcoords.clear()
		packed_values.clear()
		return

	if not header.is_empty() and int(header[0]) > 0 and int(header[0]) < vertices.size():
		vertices.resize(int(header[0]))

	var texcoord_pairs: Array[Vector2] = []
	for i in range(min(texcoords.size(), vertices.size())):
		texcoord_pairs.append(texcoords[i])
	var packed_tuple: Array[int] = []
	for i in range(min(packed_values.size(), vertices.size())):
		packed_tuple.append(packed_values[i])

	texcoords.clear()
	packed_values.clear()

	runs.append({
		"vertices": vertices,
		"texcoords": texcoord_pairs,
		"packed_values": packed_tuple,
		"header": header.duplicate(),
		"tri_cull": tri_cull.duplicate(),
	})


func _append_position_rows(rows: Array, command: int, count: int, payload: PackedByteArray, offset: int) -> void:
	rows.append_array(_decode_position_values(command, count, payload, offset))


func _decode_position_values(command: int, count: int, payload: PackedByteArray, offset: int) -> Array:
	var base_command := _base_unpack_command(command)
	var layout := _position_layout(base_command)
	if layout.is_empty():
		return []
	var component_count: int = layout["components"]
	var value_kind: String = layout["kind"]
	var total_value_count := count * component_count
	var values: Array[float] = []
	if value_kind == "f32":
		for i in range(total_value_count):
			values.append(Binary.f32(payload, offset + i * 4))
	elif value_kind == "s16":
		for i in range(total_value_count):
			values.append(float(Binary.s16(payload, offset + i * 2)) * POSITION_S16_SCALE)
	else:
		for i in range(total_value_count):
			values.append(float(Binary.s8(payload, offset + i)) * POSITION_S8_SCALE)

	var out: Array = []
	for row_start in range(0, values.size(), component_count):
		var row: Array[float] = []
		for column in range(component_count):
			row.append(values[row_start + column])
		out.append(row)
	return out


func _append_texcoord_pairs(texcoords: Array[Vector2], command: int, count: int, payload: PackedByteArray, offset: int) -> void:
	var base_command := _base_unpack_command(command)
	if base_command == 0x6C:
		for row_offset in range(count):
			var base := offset + row_offset * 16
			var row: Array[float] = [
				Binary.f32(payload, base),
				Binary.f32(payload, base + 4),
				Binary.f32(payload, base + 8),
				Binary.f32(payload, base + 12),
			]
			texcoords.append(Vector2(row[0], row[1]))
			texcoords.append(Vector2(row[3], row[2]))
	elif base_command == 0x64:
		for pair_offset in range(count):
			var base := offset + pair_offset * 8
			texcoords.append(Vector2(Binary.f32(payload, base), Binary.f32(payload, base + 4)))
	elif base_command == 0x68:
		for row_offset in range(count):
			var base := offset + row_offset * 12
			texcoords.append(Vector2(Binary.f32(payload, base), Binary.f32(payload, base + 4)))
	elif base_command == 0x60:
		var values: Array[float] = []
		for i in range(count):
			values.append(Binary.f32(payload, offset + i * 4))
		for pair_offset in range(0, values.size() - 1, 2):
			texcoords.append(Vector2(values[pair_offset], values[pair_offset + 1]))


func _vif_command_payload_size(command: int, count: int, imm: int) -> int:
	var unpack_size := _unpack_data_size(command, count)
	if unpack_size >= 0:
		return unpack_size
	if command in [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x10, 0x11, 0x13, 0x14, 0x15, 0x17]:
		return 0
	if command == 0x20:
		return 4
	if command in [0x30, 0x31]:
		return 16
	if command == 0x4A:
		return (count if count > 0 else 0x100) * 8
	if command in [0x50, 0x51]:
		return (imm if imm > 0 else 0x10000) * 16
	return -1


func _unpack_data_size(command: int, count: int) -> int:
	if not _is_unpack_command(command) or _unpack_format_name(command) == "":
		return -1
	var vn := (command >> 2) & 0x03
	var vl := command & 0x03
	return Binary.align(((0x08 >> vl) * (vn + 1) * count) >> 1, 4)


func _unpack_format_name(command: int) -> String:
	match command & 0x0F:
		0x0:
			return "S32"
		0x1:
			return "S16"
		0x2:
			return "S8"
		0x4:
			return "V2_32"
		0x5:
			return "V2_16"
		0x6:
			return "V2_8"
		0x8:
			return "V3_32"
		0x9:
			return "V3_16"
		0xA:
			return "V3_8"
		0xC:
			return "V4_32"
		0xD:
			return "V4_16"
		0xE:
			return "V4_8"
		0xF:
			return "V4_5"
	return ""


func _position_layout(base_command: int) -> Dictionary:
	match base_command:
		0x60:
			return {"components": 1, "kind": "f32"}
		0x61:
			return {"components": 1, "kind": "s16"}
		0x62:
			return {"components": 1, "kind": "s8"}
		0x64:
			return {"components": 2, "kind": "f32"}
		0x65:
			return {"components": 2, "kind": "s16"}
		0x66:
			return {"components": 2, "kind": "s8"}
		0x68:
			return {"components": 3, "kind": "f32"}
		0x69:
			return {"components": 3, "kind": "s16"}
		0x6A:
			return {"components": 3, "kind": "s8"}
		0x6C:
			return {"components": 4, "kind": "f32"}
		0x6D:
			return {"components": 4, "kind": "s16"}
		0x6E:
			return {"components": 4, "kind": "s8"}
	return {}


func _has_position_layout(base_command: int) -> bool:
	return not _position_layout(base_command).is_empty()


func _base_unpack_command(command: int) -> int:
	return command & 0xEF


func _is_unpack_command(command: int) -> bool:
	return command >= 0x60 and command <= 0x7F


func _extract_scenery_instances(chunks: Array[Dictionary], bundle: PackedByteArray, objects: Array[Dictionary], primary_objects: Array[Dictionary]) -> Array[Dictionary]:
	var instances: Array[Dictionary] = []
	for section in _parse_scenery_sections(chunks, bundle, objects, primary_objects):
		instances.append_array(section.get("instances", []))
	return instances


func _parse_scenery_sections(chunks: Array[Dictionary], bundle: PackedByteArray, objects: Array[Dictionary], primary_objects: Array[Dictionary]) -> Array[Dictionary]:
	if objects.is_empty() and primary_objects.is_empty():
		return []
	var object_indices_by_hash := _object_indices_by_hash(objects)
	var object_indices_by_chunk_offset := _object_indices_by_chunk_offset(objects)
	var sections: Array[Dictionary] = []
	var section_index := 0
	for chunk in _walk_chunks(chunks):
		if chunk.get("id", 0) != 0x80034100:
			continue
		var info_table := _read_scenery_info_table(chunk, bundle)
		var section_instances: Array[Dictionary] = []
		var instance_chunk := _child_with_id(chunk, 0x00034103)
		if not instance_chunk.is_empty():
			var payload := _payload(bundle, instance_chunk)
			var record_index := 0
			for offset in range(0, payload.size() - 0x2F, 0x30):
				var scenery_info_index := Binary.s16(payload, offset + 0x0C)
				var object_index := -1
				var object_hash := 0
				if scenery_info_index >= 0 and scenery_info_index < info_table.size():
					for candidate_hash in info_table[scenery_info_index]:
						if object_indices_by_hash.has(candidate_hash):
							object_hash = candidate_hash
							object_index = object_indices_by_hash[candidate_hash]
							break
				if object_index < 0 and info_table.is_empty() and scenery_info_index >= 0 and scenery_info_index < primary_objects.size():
					var primary_obj: Dictionary = primary_objects[scenery_info_index]
					object_index = object_indices_by_chunk_offset.get(primary_obj.get("chunk_offset", -1), -1)
				if object_index >= 0:
					var obj: Dictionary = objects[object_index]
					section_instances.append({
						"object_index": object_index,
						"object_name": obj.get("name", ""),
						"transform": _read_scenery_instance_transform(payload, offset),
						"source_chunk_offset": instance_chunk["offset"],
						"record_index": record_index,
						"section_index": section_index,
						"section_number": section_index,
						"section_chunk_offset": chunk.get("offset", -1),
						"scenery_info_index": scenery_info_index,
						"object_hash": object_hash,
					})
				record_index += 1
		sections.append({
			"section_index": section_index,
			"section_number": section_index,
			"source_chunk_offset": chunk.get("offset", -1),
			"info_table": info_table,
			"instances": section_instances,
		})
		section_index += 1
	return sections


func _object_indices_by_chunk_offset(objects: Array[Dictionary]) -> Dictionary:
	var indices := {}
	for index in range(objects.size()):
		var obj: Dictionary = objects[index]
		var chunk_offset := int(obj.get("chunk_offset", -1))
		if chunk_offset >= 0 and not indices.has(chunk_offset):
			indices[chunk_offset] = index
	return indices


func _object_indices_by_hash(objects: Array[Dictionary]) -> Dictionary:
	var indices := {}
	for index in range(objects.size()):
		var obj: Dictionary = objects[index]
		var name_hash := int(obj.get("name_hash", 0))
		if name_hash == 0 or name_hash == 0x11111111:
			continue
		if not indices.has(name_hash):
			indices[name_hash] = index
	return indices


func _read_scenery_info_table(section_chunk: Dictionary, bundle: PackedByteArray) -> Array:
	var info_chunk := _child_with_id(section_chunk, 0x00034102)
	if info_chunk.is_empty():
		return []
	var payload := _payload(bundle, info_chunk)
	var table: Array = []
	for offset in range(0, payload.size() - 0x27, 0x28):
		table.append([
			Binary.u32(payload, offset),
			Binary.u32(payload, offset + 4),
			Binary.u32(payload, offset + 8),
		])
	return table


func _read_scenery_instance_transform(payload: PackedByteArray, offset: int) -> Array:
	var scale := 1.0 / 16384.0
	var rows: Array = []
	var short_offset := offset + 0x1C
	for row in range(3):
		var base := short_offset + row * 6
		rows.append([
			float(Binary.s16(payload, base)) * scale,
			float(Binary.s16(payload, base + 2)) * scale,
			float(Binary.s16(payload, base + 4)) * scale,
			0.0,
		])
	rows.append([
		Binary.f32(payload, offset + 0x10),
		Binary.f32(payload, offset + 0x14),
		Binary.f32(payload, offset + 0x18),
		1.0,
	])
	return rows


func _collect_unknown_chunks(chunks: Array[Dictionary], parent_id: int = 0, parent_offset: int = -1) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for chunk in chunks:
		var chunk_id := int(chunk.get("id", 0))
		if not _is_known_track_chunk(chunk_id):
			out.append({
				"id": chunk_id,
				"offset": int(chunk.get("offset", -1)),
				"size": int(chunk.get("size", 0)),
				"parent_id": parent_id,
				"parent_offset": parent_offset,
			})
		out.append_array(_collect_unknown_chunks(chunk.get("children", []), chunk_id, int(chunk.get("offset", -1))))
	return out


func _is_known_track_chunk(chunk_id: int) -> bool:
	return chunk_id in [
		0x80034000,
		0x00034001,
		0x80034002,
		0x00034003,
		0x00034004,
		0x00034005,
		0x00034006,
		0x80034100,
		0x00034101,
		0x00034102,
		0x00034103,
		0x00034104,
	]


func _find_ascii_name(payload: PackedByteArray) -> Dictionary:
	var limit: int = mini(0x34, payload.size() - 4)
	for start in range(0x10, limit, 4):
		var end := start
		while end < payload.size():
			var byte: int = payload[end]
			if byte == 0:
				break
			if byte < 0x20 or byte > 0x7E:
				break
			end += 1
		if end - start >= 4 and end < payload.size() and payload[end] == 0:
			return {"name": Binary.ascii(payload, start, end), "start": start}
	return {}


func _read_transform(payload: PackedByteArray, name_start: int) -> Array:
	var matrix_offset := name_start + 0x50
	if matrix_offset + 64 > payload.size():
		return _identity4()
	var rows: Array = []
	for row in range(4):
		var row_offset := matrix_offset + row * 16
		rows.append([
			Binary.f32(payload, row_offset),
			Binary.f32(payload, row_offset + 4),
			Binary.f32(payload, row_offset + 8),
			Binary.f32(payload, row_offset + 12),
		])
	return rows


func _identity4() -> Array:
	return [
		[1.0, 0.0, 0.0, 0.0],
		[0.0, 1.0, 0.0, 0.0],
		[0.0, 0.0, 1.0, 0.0],
		[0.0, 0.0, 0.0, 1.0],
	]


func _read_texture_hashes(payload: PackedByteArray) -> Array[int]:
	var hashes: Array[int] = []
	for offset in range(0, payload.size() - 3, 8):
		var value := Binary.u32(payload, offset)
		if value != 0:
			hashes.append(value)
	return hashes


func _strip_vif_prefix(payload: PackedByteArray) -> PackedByteArray:
	if payload.size() >= 8:
		var all_prefix := true
		for i in range(8):
			if payload[i] != 0x11:
				all_prefix = false
				break
		if all_prefix:
			return payload.slice(8)
	return payload


func _child_with_id(chunk: Dictionary, chunk_id: int) -> Dictionary:
	for child in chunk.get("children", []):
		if child.get("id", 0) == chunk_id:
			return child
	return {}


func _payload(bundle: PackedByteArray, chunk: Dictionary) -> PackedByteArray:
	return bundle.slice(chunk["data_offset"], chunk["end_offset"])


func _walk_chunks(chunks: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for chunk in chunks:
		out.append(chunk)
		out.append_array(_walk_chunks(chunk.get("children", [])))
	return out
