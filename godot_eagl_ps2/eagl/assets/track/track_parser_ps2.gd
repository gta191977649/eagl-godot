class_name TrackParserPS2
extends RefCounted

const Binary := preload("res://eagl/platforms/ps2/ps2_binary_reader.gd")
const TrackAssetScript := preload("res://eagl/assets/track/track_asset.gd")
const TrackMathUtils := preload("res://eagl/utils/math_utils.gd")

const POSITION_S16_SCALE := 1.0 / 4096.0
const POSITION_S8_SCALE := 1.0 / 128.0

const CHUNK_TRACK_METADATA := 0x00034200
const CHUNK_SUN_FLARE_CONFIG := 0x00034202
const CHUNK_FOG_CONFIG := 0x00034250
const CHUNK_ROUTE_ROOT := 0x80034500
const CHUNK_ROUTE_RADAR := 0x00034510

const SUN_FLARE_TEXTURE_HASHES := [
	0x47beb4b6, # SUNCENTER
	0xd4d26c59, # SUNHALO
	0x1744b82d, # SUNMAJORRAYS
	0xad3c5239, # SUNMINORRAYS
	0xd4d80a65, # SUNRING
]
const SUN_FLARE_TEXTURE_NAMES := [
	"SUNCENTER",
	"SUNHALO",
	"SUNMAJORRAYS",
	"SUNMINORRAYS",
	"SUNRING",
]


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
	asset.environment_config = _parse_environment_config(chunks, bundle)
	asset.unknown_chunks = _collect_unknown_chunks(chunks)
	_build_collision_surfaces(asset, chunks, bundle)
	_parse_route_into(asset, chunks, bundle)


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
		"solid_version": Binary.u16(header_payload, 0x0C) if header_payload.size() >= 0x0E else 0,
		"solid_flags": Binary.u16(header_payload, 0x0E) if header_payload.size() >= 0x10 else 0,
		"num_polys": Binary.s16(header_payload, 0x14) if header_payload.size() >= 0x16 else 0,
		"num_unique_verts": Binary.s16(header_payload, 0x16) if header_payload.size() >= 0x18 else 0,
		"num_textures": Binary.s8(header_payload, 0x19) if header_payload.size() >= 0x1A else 0,
		"num_light_materials": Binary.s8(header_payload, 0x1A) if header_payload.size() >= 0x1B else 0,
		"aabb_min": Vector3(
			Binary.f32(header_payload, 0x40),
			Binary.f32(header_payload, 0x44),
			Binary.f32(header_payload, 0x48)
		) if header_payload.size() >= 0x4C else Vector3.ZERO,
		"aabb_max": Vector3(
			Binary.f32(header_payload, 0x50),
			Binary.f32(header_payload, 0x54),
			Binary.f32(header_payload, 0x58)
		) if header_payload.size() >= 0x5C else Vector3.ZERO,
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


func _build_collision_surfaces(asset, chunks: Array[Dictionary], bundle: PackedByteArray) -> void:
	var surfaces: Array[Dictionary] = []
	var skipped := {}
	var direct_surface_keys := {}
	for obj in asset.objects:
		if bool(obj.get("is_scenery_template", false)):
			continue
		var category := _collision_category_for_object(obj)
		if category == "":
			_count_collision_skip(skipped, "excluded_object")
			continue
		var surface := _collision_surface_for_object(obj, category, obj.get("transform", []), "DIRECT_SOLID", {})
		if surface.is_empty():
			_count_collision_skip(skipped, "empty_source_polygons")
			continue
		surfaces.append(surface)
		direct_surface_keys[int(obj.get("chunk_offset", -1))] = true

	for instance in asset.scenery_instances:
		var object_index := int(instance.get("object_index", -1))
		if object_index < 0 or object_index >= asset.objects.size():
			_count_collision_skip(skipped, "unresolved_scenery_instance")
			continue
		var obj: Dictionary = asset.objects[object_index]
		var category := _collision_category_for_object(obj, true)
		if category == "":
			continue
		var surface := _collision_surface_for_object(obj, category, instance.get("transform", []), "SCENERY_INSTANCE", instance)
		if surface.is_empty():
			_count_collision_skip(skipped, "empty_scenery_polygons")
			continue
		surfaces.append(surface)

	var cs_candidates := _collect_collision_chunk_candidates(chunks, bundle)
	var resolved_cs := 0
	for surface in surfaces:
		if String(surface.get("object_name", "")).to_upper().begins_with("CS_"):
			resolved_cs += 1

	asset.collision_surfaces = surfaces
	asset.collision_stats = _collision_stats_for_surfaces(surfaces, skipped, cs_candidates, resolved_cs, direct_surface_keys.size())


func _collision_surface_for_object(obj: Dictionary, category: String, transform_rows: Array, placement_kind: String, placement: Dictionary) -> Dictionary:
	var faces := PackedVector3Array()
	var block_count := 0
	for block in obj.get("blocks", []):
		var run: Dictionary = block.get("run", {})
		var vertices: Array = run.get("vertices", [])
		if vertices.size() < 3:
			continue
		var transformed := PackedVector3Array()
		for vertex in vertices:
			var ps2_vertex := TrackMathUtils.transform_point_rows(vertex, transform_rows)
			transformed.append(TrackMathUtils.ps2_to_godot_vec3(ps2_vertex))
		var indices := _collision_indices_for_block(block, transformed.size())
		for index in range(0, indices.size() - 2, 3):
			var a := int(indices[index])
			var b := int(indices[index + 1])
			var c := int(indices[index + 2])
			if a < 0 or b < 0 or c < 0 or a >= transformed.size() or b >= transformed.size() or c >= transformed.size():
				continue
			var va := transformed[a]
			var vb := transformed[b]
			var vc := transformed[c]
			if (vb - va).cross(vc - va).length_squared() <= 0.000001:
				continue
			faces.append(va)
			faces.append(vb)
			faces.append(vc)
		block_count += 1
	if faces.is_empty():
		return {}

	var material_kind := _collision_material_kind(category, obj.get("name", ""))
	var source_chunk_offset := int(obj.get("chunk_offset", -1))
	return {
		"category": category,
		"material_kind": material_kind,
		"object_name": obj.get("name", ""),
		"chunk_offset": source_chunk_offset,
		"source_chunk_offset": source_chunk_offset,
		"solid_pack_index": obj.get("solid_pack_index", -1),
		"solid_pack_offset": obj.get("solid_pack_offset", -1),
		"placement_kind": placement_kind,
		"section_number": placement.get("section_number", -1),
		"record_index": placement.get("record_index", -1),
		"triangle_count": int(faces.size() / 3),
		"block_count": block_count,
		"faces": faces,
	}


func _collision_category_for_object(obj: Dictionary, allow_scenery_collision: bool = false) -> String:
	var name := String(obj.get("name", "")).to_upper()
	if _is_collision_excluded_object_name(name):
		return ""
	if name.begins_with("RD_") or name.begins_with("DIRTRD_") or name.begins_with("LI_RD_") or name.contains("ROAD"):
		return "Road"
	if name.begins_with("TRN_") or name.contains("TERRAIN") or name.contains("CLIFF") or name.contains("ROCK") or name.contains("GULLEY"):
		return "Terrain"
	if name.contains("WALL") or name.contains("BARRIER") or name.contains("GUARD") or name.contains("RAIL") or name.contains("FENCE") or name.contains("SEA_WALL") or name.contains("SEAWALL") or name.contains("RAMP"):
		return "WallBarrier"
	if name.begins_with("XW_"):
		return "WallBarrier"
	if name.contains("BRIDGE"):
		return "Road"
	if allow_scenery_collision and (name.begins_with("CS_") or name.begins_with("XS_") or name.begins_with("XB_") or name.begins_with("XH_") or name.begins_with("XF_")):
		return "SceneryCollision"
	if name.begins_with("CS_"):
		return "SceneryCollision"
	return ""


func _is_collision_excluded_object_name(name: String) -> bool:
	if name == "" or name.begins_with("SKYDOME") or name == "WATER" or name.contains("ENVMAP"):
		return true
	if name.begins_with("SHD_") or name.begins_with("SH_") or name.contains("SHAD"):
		return true
	if name.begins_with("TRACK") and name.contains("STARTLINE"):
		return true
	if name.contains("LENS") or name.contains("FLARE") or name.contains("SUN") or name.contains("CAM"):
		return true
	if name.contains("ROUTE") or name.contains("EFFECT") or name.contains("SMOKE"):
		return true
	return false


func _collision_material_kind(category: String, object_name: String) -> String:
	var name := object_name.to_upper()
	if category == "Road":
		if name.contains("DIRT") or name.contains("SAND") or name.contains("GRAVEL"):
			return "loose_road"
		return "road"
	if category == "Terrain":
		return "terrain"
	if category == "WallBarrier":
		if name.contains("RAMP"):
			return "ramp_barrier"
		return "wall_barrier"
	return "scenery_collision"


func _collision_indices_for_block(block: Dictionary, vertex_count: int) -> PackedInt32Array:
	var mode: String = block.get("primitive_mode", "strip")
	if mode == "triangles":
		return _collision_triangle_list_indices(vertex_count)
	if mode == "fan":
		return _collision_fan_indices(vertex_count)
	return _collision_strip_control_indices(block, vertex_count)


func _collision_strip_control_indices(block: Dictionary, vertex_count: int) -> PackedInt32Array:
	var disabled: Array = _collision_adc_disabled_from_vif_control(block.get("run", {}).get("header", []), block.get("run", {}).get("tri_cull", []), vertex_count)
	if disabled.is_empty():
		disabled.resize(vertex_count)
		for i in range(vertex_count):
			disabled[i] = false

	var out := PackedInt32Array()
	var face := 1
	for index in range(vertex_count):
		if bool(disabled[index]):
			face = 1
			continue
		var a := index - 1 - face
		var b := index - 1
		var c := index - 1 + face
		if a >= 0 and b >= 0 and c >= 0 and a < vertex_count and b < vertex_count and c < vertex_count:
			_collision_append_tri(out, a, b, c)
		face = -face
	return out


func _collision_adc_disabled_from_vif_control(header: Array, tri_cull: Array, vertex_count: int) -> Array:
	if header.size() < 2 or tri_cull.size() < 4 or vertex_count <= 0:
		return []
	var num_vertices := int(header[0])
	var mode := int(header[1])
	if num_vertices <= 0 or num_vertices > vertex_count or num_vertices > 32 or mode > 7:
		return []
	var mask := _collision_vif_control_mask(num_vertices, mode, tri_cull)
	var out: Array[bool] = []
	for index in range(vertex_count):
		out.append(((mask >> (31 - index)) & 1) != 0)
	return out


func _collision_vif_control_mask(num_vertices: int, mode: int, tri_cull: Array) -> int:
	var use_upper := mode & 0x04
	var downer_side := (-(((mode & 0x03) + 1) >> 2) << (use_upper >> 2)) & 0x03
	var upper_side := ~(-use_upper)

	var downer := int(tri_cull[downer_side]) if downer_side >= 0 and downer_side < tri_cull.size() else 0
	var upper := int(tri_cull[upper_side]) if upper_side >= 0 and upper_side < tri_cull.size() else 0

	var hi_downer := downer >> 18
	var lo_downer := downer & 0x7FFF
	var hi_downer_swap := hi_downer ^ (lo_downer & 0x1E)
	var hi_upper_swap := ((upper >> 2) | ((mode + 1) >> 1)) & 0x04

	var new_downer := (lo_downer << 4) | (hi_downer_swap >> 1)
	var new_upper := (upper >> 2) ^ (((hi_downer_swap >> 1) & 0x07) << 13) ^ (hi_upper_swap << 18)

	var mask := _collision_shift_left(new_downer, ((mode - 3) << 2) - 3)
	if use_upper != 0:
		mask = (mask & ((0xFFFFFFFF << 13) & 0xFFFFFFFF)) | (new_upper & 0x3FFF)
	mask = _collision_shift_left(mask, (7 - mode) << 2)
	mask = mask & ((0xFFFFFFFF << (32 - num_vertices)) & 0xFFFFFFFF)
	return mask & 0xFFFFFFFF


func _collision_shift_left(value: int, shift: int) -> int:
	if shift >= 0:
		return value << shift
	return value >> -shift


func _collision_triangle_list_indices(count: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in range(0, count - (count % 3), 3):
		_collision_append_tri(out, i, i + 1, i + 2)
	return out


func _collision_fan_indices(count: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in range(1, count - 1):
		_collision_append_tri(out, 0, i, i + 1)
	return out


func _collision_append_tri(out: PackedInt32Array, a: int, b: int, c: int) -> void:
	if a != b and a != c and b != c:
		out.append(a)
		out.append(b)
		out.append(c)


func _collect_collision_chunk_candidates(chunks: Array[Dictionary], bundle: PackedByteArray) -> Array[Dictionary]:
	var candidates: Array[Dictionary] = []
	for chunk in _walk_chunks(chunks):
		var chunk_id := int(chunk.get("id", 0))
		if chunk_id != 0x80034020 and chunk_id != 0x00034026:
			continue
		var payload := _payload(bundle, chunk)
		var name_info := _find_ascii_name(payload)
		var name := String(name_info.get("name", ""))
		if name == "":
			name = _find_collision_candidate_name(payload)
		candidates.append({
			"id": chunk_id,
			"offset": int(chunk.get("offset", -1)),
			"size": int(chunk.get("size", 0)),
			"name": name,
			"is_collision_named": name.to_upper().begins_with("CS_"),
		})
	return candidates


func _find_collision_candidate_name(payload: PackedByteArray) -> String:
	var limit := payload.size()
	for start in range(limit):
		var end := start
		while end < limit:
			var byte: int = payload[end]
			if byte == 0:
				break
			if byte < 0x20 or byte > 0x7E:
				break
			end += 1
		if end - start >= 4 and end < limit and payload[end] == 0:
			var value := Binary.ascii(payload, start, end)
			if value.to_upper().begins_with("CS_"):
				return value
	return ""


func _collision_stats_for_surfaces(surfaces: Array[Dictionary], skipped: Dictionary, cs_candidates: Array[Dictionary], resolved_cs: int, direct_object_count: int) -> Dictionary:
	var by_category := {}
	var total_triangles := 0
	for surface in surfaces:
		var category := String(surface.get("category", "Unknown"))
		if not by_category.has(category):
			by_category[category] = {
				"surfaces": 0,
				"triangles": 0,
				"objects": {},
			}
		by_category[category]["surfaces"] = int(by_category[category]["surfaces"]) + 1
		by_category[category]["triangles"] = int(by_category[category]["triangles"]) + int(surface.get("triangle_count", 0))
		by_category[category]["objects"][String(surface.get("object_name", ""))] = true
		total_triangles += int(surface.get("triangle_count", 0))

	var compact_by_category := {}
	for category in by_category.keys():
		var object_map: Dictionary = by_category[category]["objects"]
		compact_by_category[category] = {
			"surfaces": int(by_category[category]["surfaces"]),
			"triangles": int(by_category[category]["triangles"]),
			"object_count": object_map.size(),
		}

	var named_cs_candidates := 0
	for candidate in cs_candidates:
		if bool(candidate.get("is_collision_named", false)):
			named_cs_candidates += 1

	return {
		"surface_count": surfaces.size(),
		"triangle_count": total_triangles,
		"direct_object_count": direct_object_count,
		"by_category": compact_by_category,
		"skipped": skipped.duplicate(true),
		"cs_chunk_candidate_count": cs_candidates.size(),
		"cs_named_candidate_count": named_cs_candidates,
		"cs_resolved_surface_count": resolved_cs,
		"cs_unresolved_candidate_count": max(named_cs_candidates - resolved_cs, 0),
	}


func _count_collision_skip(skipped: Dictionary, reason: String) -> void:
	skipped[reason] = int(skipped.get(reason, 0)) + 1


func _parse_route_into(asset, chunks: Array[Dictionary], bundle: PackedByteArray) -> void:
	var points: Array[Dictionary] = []
	var source_chunk_offset := -1
	var declared_count := 0
	for chunk in _walk_chunks(chunks):
		if int(chunk.get("id", 0)) != CHUNK_ROUTE_RADAR:
			continue
		source_chunk_offset = int(chunk.get("offset", -1))
		var payload := _payload(bundle, chunk)
		if payload.size() < 4:
			continue
		declared_count = Binary.u32(payload, 0)
		var max_records := int((payload.size() - 4) / 32)
		var count := mini(declared_count, max_records)
		for index in range(count):
			var record_offset := 4 + index * 32
			var name := _ascii_fixed(payload, record_offset, 16)
			var point_ps2_2d := Vector2(
				Binary.f32(payload, record_offset + 16),
				Binary.f32(payload, record_offset + 20)
			)
			var aux := Binary.f32(payload, record_offset + 24)
			points.append({
				"index": index,
				"name": name,
				"position_ps2_2d": point_ps2_2d,
				"position_godot_flat": Vector3(point_ps2_2d.x, 0.0, -point_ps2_2d.y),
				"aux": aux,
				"source_chunk_offset": source_chunk_offset,
				"source_record_offset": record_offset,
			})
		break

	asset.route_points = points
	asset.route_stats = {
		"point_count": points.size(),
		"declared_count": declared_count,
		"source_chunk_offset": source_chunk_offset,
		"source_chunk_id": CHUNK_ROUTE_RADAR if source_chunk_offset >= 0 else 0,
	}


func _ascii_fixed(payload: PackedByteArray, offset: int, length: int) -> String:
	var end := offset
	var limit := mini(offset + length, payload.size())
	while end < limit and payload[end] != 0:
		end += 1
	return Binary.ascii(payload, offset, end)


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


func _parse_environment_config(chunks: Array[Dictionary], bundle: PackedByteArray) -> Dictionary:
	var config := {}
	for chunk in _walk_chunks(chunks):
		var chunk_id := int(chunk.get("id", 0))
		if chunk_id == CHUNK_TRACK_METADATA and not config.has("track_metadata"):
			config["track_metadata"] = _parse_track_metadata(_payload(bundle, chunk), chunk)
		elif chunk_id == CHUNK_SUN_FLARE_CONFIG and not config.has("sun"):
			var sun := _parse_sun_flare_config(_payload(bundle, chunk), chunk)
			if not sun.is_empty():
				config["sun"] = sun
		elif chunk_id == CHUNK_FOG_CONFIG and not config.has("fog"):
			config["fog"] = _parse_fog_config(_payload(bundle, chunk), chunk)
	return config


func _parse_track_metadata(payload: PackedByteArray, chunk: Dictionary) -> Dictionary:
	var name_end := 0
	while name_end < payload.size() and payload[name_end] != 0:
		name_end += 1
	return {
		"name": Binary.ascii(payload, 0, name_end),
		"source_chunk_offset": int(chunk.get("offset", -1)),
		"chunk_size": int(chunk.get("size", 0)),
	}


func _parse_sun_flare_config(payload: PackedByteArray, chunk: Dictionary) -> Dictionary:
	var aligned_offset := _aligned_payload_offset(chunk)
	if aligned_offset + 0x1C > payload.size():
		return {}
	var version := Binary.u32(payload, aligned_offset)
	if version != 2:
		return {
			"source_chunk_offset": int(chunk.get("offset", -1)),
			"chunk_size": int(chunk.get("size", 0)),
			"version": version,
			"enabled": false,
			"records": [],
		}

	var flare_records: Array[Dictionary] = []
	var records_base := aligned_offset + 0x1C
	for index in range(6):
		var record_offset := records_base + index * 0x24
		if record_offset + 0x24 > payload.size():
			break
		var texture_index := Binary.u32(payload, record_offset)
		var mode := Binary.u32(payload, record_offset + 0x04)
		var color := _rgba_color_from_u32(Binary.u32(payload, record_offset + 0x18))
		var texture_hash: int = SUN_FLARE_TEXTURE_HASHES[texture_index] if texture_index < SUN_FLARE_TEXTURE_HASHES.size() else 0
		var texture_name: String = SUN_FLARE_TEXTURE_NAMES[texture_index] if texture_index < SUN_FLARE_TEXTURE_NAMES.size() else ""
		var record := {
			"index": index,
			"raw_offset": record_offset,
			"texture_index": texture_index,
			"texture_hash": texture_hash,
			"texture_name": texture_name,
			"mode": mode,
			"intensity": Binary.f32(payload, record_offset + 0x08),
			"size": Binary.f32(payload, record_offset + 0x0C),
			"offset": Vector2(Binary.f32(payload, record_offset + 0x10), Binary.f32(payload, record_offset + 0x14)),
			"color": color,
			"angle_u16": Binary.u16(payload, record_offset + 0x1C),
			"falloff": Binary.f32(payload, record_offset + 0x20),
		}
		record["enabled"] = _is_sun_flare_record_enabled(record)
		flare_records.append(record)

	var primary_vector := Vector3(
		Binary.f32(payload, aligned_offset + 0x04),
		Binary.f32(payload, aligned_offset + 0x08),
		Binary.f32(payload, aligned_offset + 0x0C)
	)
	var direction_vector := Vector3(
		Binary.f32(payload, aligned_offset + 0x10),
		Binary.f32(payload, aligned_offset + 0x14),
		Binary.f32(payload, aligned_offset + 0x18)
	)
	return {
		"source_chunk_offset": int(chunk.get("offset", -1)),
		"chunk_size": int(chunk.get("size", 0)),
		"version": version,
		"aligned_payload_offset": aligned_offset,
		"primary_vector_ps2": primary_vector,
		"direction_vector_ps2": direction_vector,
		"direction_ps2": direction_vector.normalized() if direction_vector.length() > 0.0 else Vector3.ZERO,
		"enabled": _has_enabled_sun_flare_record(flare_records),
		"records": flare_records,
	}


func _parse_fog_config(payload: PackedByteArray, chunk: Dictionary) -> Dictionary:
	var aligned_offset := _aligned_payload_offset(chunk)
	if aligned_offset + 0x10 > payload.size():
		return {}
	var records: Array[Dictionary] = []
	var version := Binary.u32(payload, aligned_offset)
	var count := Binary.u32(payload, aligned_offset + 0x04)
	var record_offset := aligned_offset + 0x10
	for index in range(count):
		if record_offset + 0x80 > payload.size():
			break
		var name_offset := record_offset + 0x10
		var name_end := name_offset
		while name_end < record_offset + 0x30 and name_end < payload.size() and payload[name_end] != 0:
			name_end += 1
		var color := _rgba_color_from_u32(Binary.u32(payload, record_offset + 0x54))
		records.append({
			"index": index,
			"name": Binary.ascii(payload, name_offset, name_end),
			"color": color,
			"raw_offset": record_offset,
		})
		record_offset += 0x80
	return {
		"source_chunk_offset": int(chunk.get("offset", -1)),
		"chunk_size": int(chunk.get("size", 0)),
		"version": version,
		"declared_count": count,
		"records": records,
	}


func _rgba_color_from_u32(value: int) -> Color:
	var red := float(value & 0xFF) / 255.0
	var green := float((value >> 8) & 0xFF) / 255.0
	var blue := float((value >> 16) & 0xFF) / 255.0
	var alpha_byte := (value >> 24) & 0xFF
	var alpha := clampf(float(alpha_byte) / 128.0, 0.0, 1.0)
	return Color(red, green, blue, alpha)


func _aligned_payload_offset(chunk: Dictionary, boundary: int = 0x10) -> int:
	var chunk_offset := int(chunk.get("offset", 0))
	var data_offset := int(chunk.get("data_offset", chunk_offset + 8))
	return ((chunk_offset + 0x17) & ~(boundary - 1)) - data_offset


func _is_sun_flare_record_enabled(record: Dictionary) -> bool:
	return int(record.get("texture_hash", 0)) != 0 and float(record.get("intensity", 0.0)) > 0.0 and float(record.get("size", 0.0)) > 0.0


func _has_enabled_sun_flare_record(records: Array[Dictionary]) -> bool:
	for record in records:
		if bool(record.get("enabled", false)):
			return true
	return false


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
		CHUNK_ROUTE_ROOT,
		CHUNK_ROUTE_RADAR,
		0x00034520,
		0x00034530,
		CHUNK_TRACK_METADATA,
		0x00034201,
		CHUNK_SUN_FLARE_CONFIG,
		CHUNK_FOG_CONFIG,
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
