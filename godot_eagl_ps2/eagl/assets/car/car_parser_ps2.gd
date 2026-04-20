class_name CarParserPS2
extends RefCounted

const Binary := preload("res://eagl/platforms/ps2/ps2_binary_reader.gd")
const TrackParserPS2Script := preload("res://eagl/assets/track/track_parser_ps2.gd")
const CarAssetScript := preload("res://eagl/assets/car/car_asset.gd")
const HP2CarDataScript := preload("res://eagl/assets/car/hp2_car_data.gd")

const CHUNK_CAR_METADATA := 0x00034013
const CHUNK_GLOBAL_MATERIAL_TABLE := 0x0003401E
const CHUNK_GLOBAL_CAR_TABLE := 0x00034600
const CHUNK_CAR_GEOMETRY_METADATA_BOUNDS := 0x00034024
const CHUNK_SOLID_PACK := 0x80034000
const CHUNK_SOLID_OBJECT := 0x80034002
const HP2_CAR_VERTEX_SCALE := 1.0
const HP2_GLOBALB_ROW_STRIDE := 0x560
const HP2_GLOBALB_CAR_NAME_OFFSET := 0x20
const HP2_GLOBALB_WHEEL_VECTOR_OFFSETS := {
	"FL": 0x120,
	"FR": 0x140,
	"RR": 0x160,
	"RL": 0x180,
}
const HP2_TIRE_DUMMY_SOURCE := "geometry_metadata_0x00034013_runtime_tire_dummies"
const HP2_TIRE_DUMMY_FRONT_LEFT := 0xACEC665C
const HP2_TIRE_DUMMY_FRONT_RIGHT := 0x4AE7F96F
const HP2_TIRE_DUMMY_REAR_LEFT := 0x7EFCF06F
const HP2_TIRE_DUMMY_REAR_RIGHT := 0x5F09C5E2
const HP2_TIRE_DUMMY_REAR_LEFT_AUX := 0xBEA9AEE6
const HP2_TIRE_DUMMY_REAR_RIGHT_AUX := 0x944E5339
const HP2_LOCATOR_HASH_NAMES := {
	0xACEC665C: "TIRE_FRONT_LEFT",
	0x4AE7F96F: "TIRE_FRONT_RIGHT",
	0x7EFCF06F: "TIRE_REAR_LEFT",
	0x5F09C5E2: "TIRE_REAR_RIGHT",
	0xBEA9AEE6: "TIRE_REAR_LEFT_AUX",
	0x944E5339: "TIRE_REAR_RIGHT_AUX",
	0xA7E6EA53: "HEADLIGHT_LEFT",
	0xA532FC46: "HEADLIGHT_RIGHT",
	0xD947F346: "BRAKELIGHT_LEFT",
	0x02B52399: "BRAKELIGHT_RIGHT",
	0x05F63788: "SIDE_MIRROR_LEFT",
	0xC52BF01B: "SIDE_MIRROR_RIGHT",
	0x725758BF: "LICENSE_PLATE_FRONT",
	0x494ED280: "LICENSE_PLATE_REAR",
	0x7B220DDF: "WINDOW_FRONT",
	0xE7E4EF49: "WINDOW_LEFT_FRONT",
	0x60F8B13C: "WINDOW_RIGHT_FRONT",
	0x0AB88F5D: "WINDOW_RIGHT_REAR",
	0x4CDEBFCA: "WINDOW_LEFT_REAR",
	0x1B0763A0: "WINDOW_REAR",
	0x59A55DB5: "ENGINE",
	0x68100815: "RADIATOR",
}

var _track_parser := TrackParserPS2Script.new()
var _hp2_car_data := HP2CarDataScript.new()


func parse(files: Dictionary):
	var asset = CarAssetScript.new()
	asset.car_id = String(files.get("car_id", "")).to_upper()
	asset.source_path = files.get("geometry", "")
	asset.source_files = files.duplicate(true)
	asset.physics_tuning = _default_physics_tuning(asset.car_id)
	asset.material_library = _parse_global_material_library(files)

	if asset.source_path == "":
		asset.add_warning("Car parser received no geometry path")
		return asset

	var bundle := Binary.load_bundle_bytes(asset.source_path)
	if bundle.is_empty():
		asset.add_warning("Car geometry bundle is empty or failed to load: %s" % asset.source_path)
		return asset

	var chunks: Array[Dictionary] = _track_parser._parse_chunks(bundle)
	_parse_geometry_into(asset, chunks, bundle, false)
	asset.locators = _parse_locator_records(chunks, bundle)
	var locator_wheel_slots := _infer_wheel_slots(asset.locators)
	var dummy_wheel_slots := _infer_wheel_slots_from_runtime_dummies(asset.locators)
	var arch_wheel_slots := _infer_wheel_slots_from_geometry_metadata(chunks, bundle, asset, locator_wheel_slots)
	_annotate_slots_with_dummy_source(arch_wheel_slots, dummy_wheel_slots)
	var bounds_wheel_slots := _infer_wheel_slots_from_bounds(asset)
	var fallback_wheel_slots := _merge_wheel_slot_sources([
		arch_wheel_slots,
		dummy_wheel_slots,
		locator_wheel_slots,
		bounds_wheel_slots,
	])
	var runtime_wheel_slots := _parse_globalb_runtime_wheel_slots(files, asset.car_id)
	_apply_hp2_car_data(asset, fallback_wheel_slots, runtime_wheel_slots)
	asset.unknown_chunks.append_array(_collect_unknown_chunks(chunks))

	var dashboard_path: String = files.get("dashboard", "")
	if dashboard_path != "" and FileAccess.file_exists(dashboard_path):
		var dashboard_bundle := Binary.load_bundle_bytes(dashboard_path)
		if dashboard_bundle.is_empty():
			asset.add_warning("Car dashboard bundle is empty or failed to load: %s" % dashboard_path)
		else:
			var dashboard_chunks: Array[Dictionary] = _track_parser._parse_chunks(dashboard_bundle)
			_parse_geometry_into(asset, dashboard_chunks, dashboard_bundle, true)
			for unknown in _collect_unknown_chunks(dashboard_chunks):
				unknown["source"] = "dashboard"
				asset.unknown_chunks.append(unknown)

	asset.part_groups = _build_part_groups(asset)
	asset.runtime_parts = _build_runtime_parts(asset)
	asset.metadata["parser"] = "CarParserPS2"
	asset.metadata["geometry_bundle_size"] = bundle.size()
	asset.metadata["chunk_count"] = _track_parser._walk_chunks(chunks).size()
	asset.metadata["car_vertex_scale"] = HP2_CAR_VERTEX_SCALE
	asset.metadata["car_visual_transform_mode"] = "raw_z_up_vertices_modelulator_legacy_hp2"
	asset.metadata["material_record_count"] = asset.material_library.size()
	return asset


func _apply_hp2_car_data(asset, fallback_wheel_slots: Array[Dictionary], runtime_wheel_slots: Array[Dictionary]) -> void:
	asset.handling_data = _hp2_car_data.data_for_car(asset.car_id, fallback_wheel_slots, runtime_wheel_slots)
	asset.physics_tuning = asset.handling_data.get("handling", _default_physics_tuning(asset.car_id)).duplicate(true)
	asset.exact_handling_status = String(asset.handling_data.get("exact_handling_status", "partial_reverse_estimated_constants"))
	asset.wheel_slots = _typed_dictionary_array(asset.handling_data.get("wheel_slots", []))
	asset.brake_slots = _typed_dictionary_array(asset.handling_data.get("brake_slots", []))
	asset.wheel_slot_source = String(asset.handling_data.get("wheel_slot_source", "unresolved"))
	asset.metadata["wheel_slots"] = asset.wheel_slots.duplicate(true)
	asset.metadata["brake_slots"] = asset.brake_slots.duplicate(true)
	asset.metadata["wheel_slot_source"] = asset.wheel_slot_source
	asset.metadata["exact_handling_status"] = asset.exact_handling_status
	asset.metadata["hp2_reverse_facts"] = asset.handling_data.get("reverse_facts", {}).duplicate(true)
	asset.metadata["runtime_wheel_slots"] = runtime_wheel_slots.duplicate(true)


func _typed_dictionary_array(value: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for item in value:
		var dict: Dictionary = item
		out.append(dict.duplicate(true))
	return out


func _parse_global_material_library(files: Dictionary) -> Dictionary:
	var globalb_path := String(files.get("globalb", ""))
	if globalb_path == "" or not FileAccess.file_exists(globalb_path):
		return {}
	var bundle := Binary.load_bundle_bytes(globalb_path)
	if bundle.is_empty():
		return {}
	var chunks: Array[Dictionary] = _track_parser._parse_chunks(bundle)
	var chunk := _first_chunk(chunks, CHUNK_GLOBAL_MATERIAL_TABLE)
	if chunk.is_empty():
		return {}
	var payload: PackedByteArray = _track_parser._payload(bundle, chunk)
	if payload.size() < 0x18:
		return {}
	var count := Binary.u32(payload, 0x14)
	var record_size := 0x140
	var offset := 0x18
	var out := {}
	for index in range(count):
		if offset + record_size > payload.size():
			break
		var record := payload.slice(offset, offset + record_size)
		var material_hash := Binary.u32(record, 0x08)
		var name := _fixed_ascii(record, 0x0C, 0x2C)
		var values: Array[float] = []
		for value_index in range(16):
			values.append(Binary.f32(record, 0x20 + value_index * 4))
		out[material_hash] = {
			"index": index,
			"name": name,
			"hash": material_hash,
			"word_00": Binary.u32(record, 0x00),
			"word_04": Binary.u32(record, 0x04),
			"values": values,
			"source": "GLOBAL/GLOBALB.BUN chunk 0x0003401E",
			"source_chunk_offset": int(chunk.get("offset", -1)),
		}
		offset += record_size
	return out


func _fixed_ascii(data: PackedByteArray, start: int, end: int) -> String:
	var stop := start
	while stop < end and stop < data.size() and data[stop] != 0:
		stop += 1
	return data.slice(start, stop).get_string_from_ascii()


func _parse_geometry_into(asset, chunks: Array[Dictionary], bundle: PackedByteArray, is_dashboard: bool) -> void:
	var pack_index := 0
	for chunk in _track_parser._walk_chunks(chunks):
		if int(chunk.get("id", 0)) != CHUNK_SOLID_PACK:
			continue
		var pack_objects: Array[Dictionary] = []
		for child in chunk.get("children", []):
			if int(child.get("id", 0)) != CHUNK_SOLID_OBJECT:
				continue
			var obj: Dictionary = _track_parser._parse_mesh_object(child, bundle)
			if obj.is_empty():
				continue
			obj["solid_pack_index"] = pack_index
			obj["solid_pack_offset"] = chunk.get("offset", -1)
			obj["source_role"] = "DASHBOARD" if is_dashboard else "CAR_BODY"
			obj["is_dashboard"] = is_dashboard
			obj["part_group"] = _part_group_for_name(String(obj.get("name", "")), is_dashboard)
			_prepare_visual_object(obj, asset.car_id, is_dashboard)
			if is_dashboard:
				asset.dashboard_objects.append(obj)
			else:
				asset.objects.append(obj)
			pack_objects.append(obj)
		var pack := {
			"index": pack_index,
			"source_chunk_offset": chunk.get("offset", -1),
			"source_role": "DASHBOARD" if is_dashboard else "CAR_BODY",
			"objects": pack_objects,
		}
		if is_dashboard:
			asset.dashboard_solid_packs.append(pack)
		else:
			asset.solid_packs.append(pack)
		pack_index += 1


func _parse_locator_records(chunks: Array[Dictionary], bundle: PackedByteArray) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for chunk in _track_parser._walk_chunks(chunks):
		if int(chunk.get("id", 0)) != CHUNK_CAR_METADATA:
			continue
		var payload: PackedByteArray = _track_parser._payload(bundle, chunk)
		var record_size := 0x20
		if payload.size() < record_size:
			continue
		var start_offset := 8 if payload.size() >= 0x28 and Binary.u32(payload, 0) == 0x11111111 and Binary.u32(payload, 4) == 0x11111111 else 0
		for offset in range(start_offset, payload.size() - (record_size - 1), record_size):
			var record := payload.slice(offset, offset + record_size)
			var hash_08 := Binary.u32(record, 0x08)
			var position_ps2 := Vector3(Binary.f32(record, 0x10), Binary.f32(record, 0x14), Binary.f32(record, 0x18))
			var locator := {
				"index": out.size(),
				"source_chunk_offset": int(chunk.get("offset", -1)),
				"record_offset": offset,
				"word_00": Binary.u32(record, 0x00),
				"word_04": Binary.u32(record, 0x04),
				"hash_08": hash_08,
				"hash_0c": Binary.u32(record, 0x0C),
				"position_ps2": position_ps2,
				"position_godot": Vector3(position_ps2.y, position_ps2.z, -position_ps2.x),
				"name": _locator_display_name(hash_08),
				"display_name": _locator_display_name(hash_08),
				"known_name": HP2_LOCATOR_HASH_NAMES.get(hash_08, ""),
				"word_1c": Binary.u32(record, 0x1C),
				"raw_hex": record.hex_encode(),
				"decode_status": "estimated_0x20_record",
			}
			out.append(locator)
	return out


func _parse_globalb_runtime_wheel_slots(files: Dictionary, car_id: String) -> Array[Dictionary]:
	var globalb_path := String(files.get("globalb", ""))
	if globalb_path == "" or not FileAccess.file_exists(globalb_path):
		return []
	var bundle := Binary.load_bundle_bytes(globalb_path)
	if bundle.is_empty():
		return []
	var chunks: Array[Dictionary] = _track_parser._parse_chunks(bundle)
	var chunk := _first_chunk(chunks, CHUNK_GLOBAL_CAR_TABLE)
	if chunk.is_empty():
		return []
	var table_base := (int(chunk.get("offset", 0)) + 0x17) & ~0xF
	var table_end := int(chunk.get("end_offset", bundle.size()))
	var car_row := -1
	for row_index in range(64):
		var row_offset := table_base + row_index * HP2_GLOBALB_ROW_STRIDE
		if row_offset + HP2_GLOBALB_ROW_STRIDE > table_end:
			break
		if _globalb_car_name(bundle, row_offset) == car_id.to_upper():
			car_row = row_index
			break
	if car_row < 0:
		return []
	var row_base := table_base + car_row * HP2_GLOBALB_ROW_STRIDE
	var out: Array[Dictionary] = []
	for slot_id in ["FL", "FR", "RL", "RR"]:
		var vector_offset := int(HP2_GLOBALB_WHEEL_VECTOR_OFFSETS[slot_id])
		var p := Vector3(
			Binary.f32(bundle, row_base + vector_offset),
			Binary.f32(bundle, row_base + vector_offset + 4),
			Binary.f32(bundle, row_base + vector_offset + 8)
		)
		var radius := Binary.f32(bundle, row_base + vector_offset + 12)
		var axle := "front" if slot_id.begins_with("F") else "rear"
		var side := "left" if slot_id.ends_with("L") else "right"
		out.append({
			"name": slot_id,
			"slot_id": slot_id,
			"axle": axle,
			"side": side,
			"source": "globalb_0x00034600_runtime_wheel_table",
			"position_ps2": p,
			"position_godot": Vector3(p.y, p.z, -p.x),
			"wheel_radius": radius,
			"runtime_row_index": car_row,
			"runtime_table_path": globalb_path,
			"runtime_table_chunk_offset": int(chunk.get("offset", -1)),
			"runtime_table_row_offset": row_base,
			"runtime_vector_offset": vector_offset,
			"runtime_source_function": "FUN_0011e860",
		})
	return out


func _globalb_car_name(bundle: PackedByteArray, row_offset: int) -> String:
	var start := row_offset + HP2_GLOBALB_CAR_NAME_OFFSET
	var end := start
	var max_end := mini(start + 0x20, bundle.size())
	while end < max_end and bundle[end] != 0:
		end += 1
	return Binary.ascii(bundle, start, end).to_upper()


func _locator_display_name(hash: int) -> String:
	if HP2_LOCATOR_HASH_NAMES.has(hash):
		return String(HP2_LOCATOR_HASH_NAMES[hash])
	return "HASH_%08X" % hash


func _build_part_groups(asset) -> Dictionary:
	var groups := {}
	for obj in asset.all_objects():
		var group: String = obj.get("part_group", "Body")
		if not groups.has(group):
			groups[group] = []
		groups[group].append(obj.get("name", ""))
	return groups


func _build_runtime_parts(asset) -> Dictionary:
	var tire_front: Array[String] = []
	var tire_rear: Array[String] = []
	var brake_front: Array[String] = []
	var brake_rear: Array[String] = []
	var wheel_blur: Array[String] = []
	for obj in asset.objects:
		var name := String(obj.get("name", "")).to_upper()
		if name.contains("WHEEL_BLUR"):
			wheel_blur.append(name)
		elif name.contains("TIRE_FRONT"):
			tire_front.append(name)
		elif name.contains("TIRE_REAR"):
			tire_rear.append(name)
		elif name.contains("BRAKE_FRONT"):
			brake_front.append(name)
		elif name.contains("BRAKE_REAR"):
			brake_rear.append(name)
	return {
		"tire_meshes": {
			"front": tire_front,
			"rear": tire_rear,
		},
		"brake_meshes": {
			"front": brake_front,
			"rear": brake_rear,
		},
		"wheel_blur_meshes": wheel_blur,
		"counts": {
			"tire_front": tire_front.size(),
			"tire_rear": tire_rear.size(),
			"brake_front": brake_front.size(),
			"brake_rear": brake_rear.size(),
			"wheel_blur": wheel_blur.size(),
			"wheel_slots": asset.wheel_slots.size(),
			"brake_slots": asset.brake_slots.size(),
		},
	}


func _part_group_for_name(object_name: String, is_dashboard: bool = false) -> String:
	if is_dashboard:
		return "Dashboard"
	var name := object_name.to_upper()
	if name.contains("TIRE") or name.contains("WHEEL"):
		return "Wheels"
	if name.contains("BRAKE"):
		return "Brakes"
	if name.contains("SHADOW") or name.contains("BLUR"):
		return "ShadowBlur"
	if name.contains("GLASS") or name.contains("LIGHT") or name.contains("MIRROR") or name.contains("PLATE") or name.contains("WIPER") or name.contains("SCUFF"):
		return "GlassLightsDamage"
	return "Body"


func _prepare_visual_object(obj: Dictionary, car_id: String, is_dashboard: bool) -> void:
	var object_name := String(obj.get("name", ""))
	obj["source_transform"] = obj.get("transform", []).duplicate(true)
	obj["transform"] = obj["source_transform"].duplicate(true) if _should_apply_source_transform(object_name) else []
	obj["vertex_scale"] = HP2_CAR_VERTEX_SCALE
	obj["coordinate_space"] = "hp2_car_local_x_forward_z_up"
	obj["visual_transform_mode"] = "source_transform_vertices" if _should_apply_source_transform(object_name) else "identity_raw_vertices"
	var part_key := _part_key(object_name.to_upper(), car_id)
	var is_tire := part_key.contains("TIRE_FRONT") or part_key.contains("TIRE_REAR")
	var is_brake := part_key.contains("BRAKE_FRONT") or part_key.contains("BRAKE_REAR")
	var is_wheel_blur := part_key.contains("WHEEL_BLUR")
	obj["disable_vertex_color"] = part_key.contains("TIRE")
	obj["skip_missing_texture_surfaces"] = is_wheel_blur
	obj["runtime_texture_policy"] = "hide_blur_meshes" if is_wheel_blur else "render_with_fallback_material"
	obj["texture_hash_aliases"] = _texture_hash_aliases_for_part(car_id, is_tire, is_brake)
	if is_tire:
		obj["material_role"] = "hp2_car_tire"
	elif is_brake:
		obj["material_role"] = "hp2_car_brake"
	elif is_wheel_blur:
		obj["material_role"] = "hp2_car_wheel_blur"
	else:
		obj["material_role"] = "hp2_car_dashboard" if is_dashboard else "hp2_car_exterior"
	obj["render_default"] = _should_render_default(object_name, car_id, is_dashboard)
	obj["variant_role"] = _variant_role_for_name(object_name, car_id, is_dashboard)


func _should_apply_source_transform(object_name: String) -> bool:
	var name := object_name.to_upper()
	return name.contains("WIPER")


func _texture_hash_aliases_for_part(car_id: String, is_tire: bool, is_brake: bool) -> Dictionary:
	var aliases := {}
	if is_tire:
		aliases[_hp2_name_hash("TIRE")] = _hp2_name_hash("%s_TIRE" % car_id.to_upper())
	if is_brake:
		aliases[_hp2_name_hash("BRAKE")] = _hp2_name_hash("BRAKESFRONT")
		aliases[_hp2_name_hash("BRAKE_FRONT")] = _hp2_name_hash("BRAKESFRONT")
		aliases[_hp2_name_hash("BRAKE_REAR")] = _hp2_name_hash("BRAKESREAR")
	return aliases


func _hp2_name_hash(value: String) -> int:
	var out := 0xFFFFFFFF
	for i in range(value.length()):
		out = int((out * 0x21 + value.unicode_at(i)) & 0xFFFFFFFF)
	return out


func _should_render_default(object_name: String, car_id: String, is_dashboard: bool) -> bool:
	if is_dashboard:
		return true
	var name := object_name.to_upper()
	var part_key := _part_key(name, car_id)
	if part_key.contains("WHEEL_BLUR") or part_key.contains("SHADOW") or part_key.contains("SCUFF"):
		return false
	if part_key == "CV":
		return false
	if part_key.begins_with("TIRE_FRONT") or part_key.begins_with("TIRE_REAR"):
		return _suffix_is_primary(part_key)
	if _is_body_variant_key(part_key):
		return part_key in ["", "A"]
	return true


func _variant_role_for_name(object_name: String, car_id: String, is_dashboard: bool) -> String:
	if is_dashboard:
		return "dashboard"
	var name := object_name.to_upper()
	var part_key := _part_key(name, car_id)
	if part_key.contains("WHEEL_BLUR"):
		return "wheel_blur_hidden_default"
	if part_key.contains("SHADOW"):
		return "shadow_hidden_default"
	if part_key.contains("SCUFF"):
		return "damage_scuff_hidden_default"
	if part_key == "CV":
		return "cockpit_or_view_variant_hidden_default"
	if part_key.begins_with("TIRE_FRONT") or part_key.begins_with("TIRE_REAR"):
		return "primary_tire" if _suffix_is_primary(part_key) else "alternate_tire_hidden_default"
	if _is_body_variant_key(part_key):
		return "primary_body" if part_key in ["", "A"] else "alternate_body_hidden_default"
	return "always_visible"


func _suffix_is_primary(name: String) -> bool:
	if name.ends_with("_B") or name.ends_with("_C") or name.ends_with("_D"):
		return false
	return true


func _part_key(name: String, car_id: String) -> String:
	var id := car_id.to_upper()
	if name == id:
		return ""
	var prefix := id + "_"
	if not name.begins_with(prefix):
		return name
	return name.substr(prefix.length())


func _is_body_variant_key(part_key: String) -> bool:
	return part_key in ["", "A", "B", "C", "D"]


func _infer_wheel_slots(locators: Array[Dictionary]) -> Array[Dictionary]:
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
					"name": "%s_%s" % [axle, side],
					"slot_id": _slot_id_from_axle_side(axle, side),
					"axle": axle,
					"side": side,
					"source": "geometry_locator_0x00034013",
					"position_ps2": p,
					"position_godot": Vector3(p.y, p.z, -p.x),
					"locator_index": best.get("index", -1),
					"hash_08": best.get("hash_08", 0),
					"hash_0c": best.get("hash_0c", 0),
				})
	return slots


func _infer_wheel_slots_from_runtime_dummies(locators: Array[Dictionary]) -> Array[Dictionary]:
	var specs := [
		{
			"slot_id": "FL",
			"axle": "front",
			"side": "left",
			"hashes": [HP2_TIRE_DUMMY_FRONT_LEFT],
		},
		{
			"slot_id": "FR",
			"axle": "front",
			"side": "right",
			"hashes": [HP2_TIRE_DUMMY_FRONT_RIGHT],
		},
		{
			"slot_id": "RL",
			"axle": "rear",
			"side": "left",
			"hashes": [HP2_TIRE_DUMMY_REAR_LEFT, HP2_TIRE_DUMMY_REAR_LEFT_AUX],
		},
		{
			"slot_id": "RR",
			"axle": "rear",
			"side": "right",
			"hashes": [HP2_TIRE_DUMMY_REAR_RIGHT, HP2_TIRE_DUMMY_REAR_RIGHT_AUX],
		},
	]
	var out: Array[Dictionary] = []
	for spec in specs:
		var matches := _runtime_dummy_matches(locators, spec)
		if matches.is_empty():
			continue
		var p := _average_locator_position(matches)
		var hashes: Array[int] = []
		var locator_indices: Array[int] = []
		var positions: Array[Vector3] = []
		for match in matches:
			var locator: Dictionary = match
			var hash := int(locator.get("hash_08", 0))
			if not hashes.has(hash):
				hashes.append(hash)
			locator_indices.append(int(locator.get("index", -1)))
			positions.append(locator.get("position_ps2", Vector3.ZERO))
		out.append({
			"name": "%s_%s" % [String(spec["axle"]), String(spec["side"])],
			"slot_id": String(spec["slot_id"]),
			"axle": String(spec["axle"]),
			"side": String(spec["side"]),
			"source": HP2_TIRE_DUMMY_SOURCE,
			"position_ps2": p,
			"position_godot": Vector3(p.y, p.z, -p.x),
			"locator_index": locator_indices[0] if not locator_indices.is_empty() else -1,
			"dummy_locator_indices": locator_indices,
			"dummy_locator_count": matches.size(),
			"dummy_hashes": hashes,
			"dummy_locator_positions_ps2": positions,
			"runtime_source_function": "FUN_00120360",
			"runtime_source_hash_group": "front_tire" if String(spec["axle"]) == "front" else "rear_tire",
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


func _merge_wheel_slot_sources(sources: Array) -> Array[Dictionary]:
	var by_id := {}
	for source in sources:
		var slots: Array = source
		for slot in slots:
			var slot_dict: Dictionary = slot
			var slot_id := String(slot_dict.get("slot_id", ""))
			if slot_id == "":
				slot_id = _slot_id_from_axle_side(String(slot_dict.get("axle", "")), String(slot_dict.get("side", "")))
			if slot_id == "" or by_id.has(slot_id):
				continue
			by_id[slot_id] = slot_dict.duplicate(true)

	var out: Array[Dictionary] = []
	for slot_id in ["FL", "FR", "RL", "RR"]:
		if by_id.has(slot_id):
			out.append(by_id[slot_id])
	return out


func _annotate_slots_with_dummy_source(slots: Array[Dictionary], dummy_slots: Array[Dictionary]) -> void:
	for slot in slots:
		var slot_id := String(slot.get("slot_id", ""))
		var dummy := _slot_by_id(dummy_slots, slot_id)
		if dummy.is_empty():
			continue
		slot["dummy_position_ps2"] = dummy.get("position_ps2", Vector3.ZERO)
		slot["dummy_position_godot"] = dummy.get("position_godot", Vector3.ZERO)
		slot["dummy_locator_indices"] = dummy.get("dummy_locator_indices", []).duplicate(true)
		slot["dummy_locator_count"] = int(dummy.get("dummy_locator_count", 0))
		slot["dummy_hashes"] = dummy.get("dummy_hashes", []).duplicate(true)
		slot["dummy_locator_positions_ps2"] = dummy.get("dummy_locator_positions_ps2", []).duplicate(true)
		slot["dummy_source"] = dummy.get("source", HP2_TIRE_DUMMY_SOURCE)
		var p: Vector3 = slot.get("position_ps2", Vector3.ZERO)
		var dummy_p: Vector3 = dummy.get("position_ps2", Vector3.ZERO)
		slot["dummy_to_arch_delta_ps2"] = dummy_p - p
		slot["dummy_to_arch_delta_godot"] = Vector3(dummy_p.y - p.y, dummy_p.z - p.z, -(dummy_p.x - p.x))


func _infer_wheel_slots_from_geometry_metadata(chunks: Array[Dictionary], bundle: PackedByteArray, asset, locator_slots: Array[Dictionary]) -> Array[Dictionary]:
	var chunk := _first_chunk(chunks, CHUNK_CAR_GEOMETRY_METADATA_BOUNDS)
	if chunk.is_empty():
		return []
	var body_bounds := _body_bounds_ps2(asset.objects, false)
	if body_bounds.size == Vector3.ZERO:
		return []
	var payload: PackedByteArray = _track_parser._payload(bundle, chunk)
	if payload.size() < 20:
		return []
	var offset := 8 if payload.size() >= 8 and Binary.u32(payload, 0) == 0x11111111 and Binary.u32(payload, 4) == 0x11111111 else 0
	var groups := {
		"FL": [],
		"FR": [],
		"RL": [],
		"RR": [],
	}
	var max_body_side := maxf(absf(body_bounds.position.y), absf(body_bounds.position.y + body_bounds.size.y))
	var min_side := maxf(0.45, max_body_side * 0.55)
	var max_side := max_body_side + 0.45
	var min_abs_axle_x := maxf(absf(body_bounds.position.x), absf(body_bounds.position.x + body_bounds.size.x)) * 0.28
	for byte_offset in range(offset, payload.size() - 11, 4):
		var p := Vector3(Binary.f32(payload, byte_offset), Binary.f32(payload, byte_offset + 4), Binary.f32(payload, byte_offset + 8))
		if not _is_plausible_wheel_arch_point(p, body_bounds, min_side, max_side, min_abs_axle_x):
			continue
		var slot_id := _slot_id_from_ps2_position(p)
		var group: Array = groups[slot_id]
		group.append({
			"position_ps2": p,
			"metadata_byte_offset": byte_offset,
			"source_chunk_offset": int(chunk.get("offset", -1)),
		})

	var out: Array[Dictionary] = []
	for spec in [
		{"slot_id": "FL", "axle": "front", "side": "left"},
		{"slot_id": "FR", "axle": "front", "side": "right"},
		{"slot_id": "RL", "axle": "rear", "side": "left"},
		{"slot_id": "RR", "axle": "rear", "side": "right"},
	]:
		var slot_id: String = spec["slot_id"]
		var group: Array = groups[slot_id]
		var slot := _wheel_slot_from_arch_group(group, spec, locator_slots, asset, body_bounds)
		if not slot.is_empty():
			out.append(slot)
	return out


func _is_plausible_wheel_arch_point(p: Vector3, body_bounds: AABB, min_side: float, max_side: float, min_abs_axle_x: float) -> bool:
	if absf(p.x) > maxf(absf(body_bounds.position.x), absf(body_bounds.position.x + body_bounds.size.x)) + 0.35:
		return false
	if absf(p.x) < min_abs_axle_x:
		return false
	if absf(p.y) < min_side or absf(p.y) > max_side:
		return false
	if p.z < maxf(0.02, body_bounds.position.z - 0.05):
		return false
	if p.z > body_bounds.position.z + body_bounds.size.z + 0.25:
		return false
	return true


func _slot_id_from_ps2_position(p: Vector3) -> String:
	if p.x >= 0.0:
		return "FL" if p.y >= 0.0 else "FR"
	return "RL" if p.y >= 0.0 else "RR"


func _wheel_slot_from_arch_group(group: Array, spec: Dictionary, locator_slots: Array[Dictionary], asset, body_bounds: AABB) -> Dictionary:
	if group.size() < 2:
		return {}
	var min_x := INF
	var max_x := -INF
	var min_y := INF
	var max_y := -INF
	var min_z := INF
	var max_z := -INF
	var source_offsets: Array[int] = []
	for item in group:
		var dict: Dictionary = item
		var p: Vector3 = dict.get("position_ps2", Vector3.ZERO)
		min_x = minf(min_x, p.x)
		max_x = maxf(max_x, p.x)
		min_y = minf(min_y, p.y)
		max_y = maxf(max_y, p.y)
		min_z = minf(min_z, p.z)
		max_z = maxf(max_z, p.z)
		source_offsets.append(int(dict.get("metadata_byte_offset", -1)))
	if absf(max_x - min_x) < 0.25:
		return {}
	var axle := String(spec["axle"])
	var side := String(spec["side"])
	var slot_id := String(spec["slot_id"])
	var locator := _slot_by_id(locator_slots, slot_id)
	var tire_radius := _tire_radius_for_axle(asset.objects, axle)
	var center_x := (min_x + max_x) * 0.5
	var center_y := (min_y + max_y) * 0.5
	var center_z := min_z + tire_radius * 0.78
	if max_z > min_z:
		center_z = clampf(center_z, min_z, max_z)
	center_z = maxf(center_z, body_bounds.position.z + tire_radius * 0.65)
	var p := Vector3(center_x, center_y, center_z)
	return {
		"name": "%s_%s" % [axle, side],
		"slot_id": slot_id,
		"axle": axle,
		"side": side,
		"source": "geometry_metadata_0x00034024_wheel_arch",
		"position_ps2": p,
		"position_godot": Vector3(p.y, p.z, -p.x),
		"arch_bounds_ps2": AABB(Vector3(min_x, min_y, min_z), Vector3(max_x - min_x, max_y - min_y, max_z - min_z)),
		"locator_index": locator.get("locator_index", -1),
		"locator_position_ps2": locator.get("position_ps2", Vector3.ZERO),
		"metadata_byte_offsets": source_offsets,
	}


func _slot_by_id(slots: Array[Dictionary], slot_id: String) -> Dictionary:
	for slot in slots:
		var dict: Dictionary = slot
		var existing := String(dict.get("slot_id", ""))
		if existing == "":
			existing = _slot_id_from_axle_side(String(dict.get("axle", "")), String(dict.get("side", "")))
		if existing == slot_id:
			return dict
	return {}


func _slot_id_from_axle_side(axle: String, side: String) -> String:
	if axle == "front":
		return "FR" if side == "right" else "FL"
	return "RR" if side == "right" else "RL"


func _tire_radius_for_axle(objects: Array[Dictionary], axle: String) -> float:
	var token := "TIRE_FRONT" if axle == "front" else "TIRE_REAR"
	var best := AABB()
	var found := false
	var fallback := AABB()
	for obj in objects:
		var name := String(obj.get("name", "")).to_upper()
		if not name.contains(token):
			continue
		var bounds := _object_bounds_godot(obj)
		if bounds.size == Vector3.ZERO:
			continue
		if fallback.size == Vector3.ZERO:
			fallback = bounds
		if name.ends_with("_A") or not (name.ends_with("_B") or name.ends_with("_C") or name.ends_with("_D")):
			best = bounds
			found = true
			break
	if not found:
		best = fallback
	if best.size == Vector3.ZERO:
		return float(_default_physics_tuning("").get("wheel_radius", 0.36))
	return maxf(best.size.y, best.size.z) * 0.5


func _infer_wheel_slots_from_bounds(asset) -> Array[Dictionary]:
	var body_bounds := _body_bounds_godot(asset.objects, false)
	if body_bounds.size == Vector3.ZERO:
		body_bounds = _body_bounds_godot(asset.objects, true)
	if body_bounds.size == Vector3.ZERO:
		return []

	var left_x := body_bounds.position.x + body_bounds.size.x * 0.82
	var right_x := body_bounds.position.x + body_bounds.size.x * 0.18
	var front_z := body_bounds.position.z + body_bounds.size.z * 0.18
	var rear_z := body_bounds.position.z + body_bounds.size.z * 0.82
	var wheel_y := body_bounds.position.y + body_bounds.size.y * 0.18
	var specs := [
		{"slot_id": "FL", "axle": "front", "side": "left", "position_godot": Vector3(left_x, wheel_y, front_z)},
		{"slot_id": "FR", "axle": "front", "side": "right", "position_godot": Vector3(right_x, wheel_y, front_z)},
		{"slot_id": "RL", "axle": "rear", "side": "left", "position_godot": Vector3(left_x, wheel_y, rear_z)},
		{"slot_id": "RR", "axle": "rear", "side": "right", "position_godot": Vector3(right_x, wheel_y, rear_z)},
	]
	var out: Array[Dictionary] = []
	for spec in specs:
		var slot: Dictionary = spec
		slot["source"] = "geometry_bounds_estimated"
		slot["position_ps2"] = Vector3(-float(slot["position_godot"].z), float(slot["position_godot"].x), float(slot["position_godot"].y))
		out.append(slot)
	return out


func _object_bounds_godot(obj: Dictionary) -> AABB:
	var has_bounds := false
	var bounds := AABB()
	for block in obj.get("blocks", []):
		var run: Dictionary = block.get("run", {})
		for vertex in run.get("vertices", []):
			var source_vertex: Vector3 = vertex * HP2_CAR_VERTEX_SCALE
			var p := Vector3(source_vertex.y, source_vertex.z, -source_vertex.x)
			if not has_bounds:
				bounds = AABB(p, Vector3.ZERO)
				has_bounds = true
			else:
				bounds = bounds.expand(p)
	return bounds if has_bounds else AABB()


func _body_bounds_godot(objects: Array[Dictionary], include_runtime_parts: bool) -> AABB:
	var has_bounds := false
	var bounds := AABB()
	for obj in objects:
		if not include_runtime_parts and not _is_body_bounds_object(obj):
			continue
		for block in obj.get("blocks", []):
			var run: Dictionary = block.get("run", {})
			for vertex in run.get("vertices", []):
				var source_vertex: Vector3 = vertex * HP2_CAR_VERTEX_SCALE
				var p := Vector3(source_vertex.y, source_vertex.z, -source_vertex.x)
				if not has_bounds:
					bounds = AABB(p, Vector3.ZERO)
					has_bounds = true
				else:
					bounds = bounds.expand(p)
	return bounds if has_bounds else AABB()


func _body_bounds_ps2(objects: Array[Dictionary], include_runtime_parts: bool) -> AABB:
	var has_bounds := false
	var bounds := AABB()
	for obj in objects:
		if not include_runtime_parts and not _is_body_bounds_object(obj):
			continue
		for block in obj.get("blocks", []):
			var run: Dictionary = block.get("run", {})
			for vertex in run.get("vertices", []):
				var p: Vector3 = vertex * HP2_CAR_VERTEX_SCALE
				if not has_bounds:
					bounds = AABB(p, Vector3.ZERO)
					has_bounds = true
				else:
					bounds = bounds.expand(p)
	return bounds if has_bounds else AABB()


func _is_body_bounds_object(obj: Dictionary) -> bool:
	if String(obj.get("part_group", "Body")) != "Body":
		return false
	var name := String(obj.get("name", "")).to_upper()
	if name.contains("TIRE") or name.contains("BRAKE") or name.contains("WHEEL_BLUR") or name.contains("SHADOW"):
		return false
	if name.contains("WIPER") or name.contains("MIRROR") or name.contains("LIGHT") or name.contains("PLATE") or name.contains("LICENSE") or name.contains("SCUFF"):
		return false
	return true


func _collect_unknown_chunks(chunks: Array[Dictionary], parent_id: int = 0, parent_offset: int = -1) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for chunk in chunks:
		var chunk_id := int(chunk.get("id", 0))
		if not _is_known_car_chunk(chunk_id):
			out.append({
				"id": chunk_id,
				"offset": int(chunk.get("offset", -1)),
				"size": int(chunk.get("size", 0)),
				"parent_id": parent_id,
				"parent_offset": parent_offset,
				"source": "geometry",
			})
		out.append_array(_collect_unknown_chunks(chunk.get("children", []), chunk_id, int(chunk.get("offset", -1))))
	return out


func _first_chunk(chunks: Array[Dictionary], chunk_id: int) -> Dictionary:
	for chunk in _track_parser._walk_chunks(chunks):
		if int(chunk.get("id", 0)) == chunk_id:
			return chunk
	return {}


func _is_known_car_chunk(chunk_id: int) -> bool:
	return chunk_id in [
		CHUNK_CAR_METADATA,
		0x80034020,
		0x00034021,
		0x00034022,
		0x00034023,
		0x00034024,
		0x00034025,
		0x00034026,
		0x00034030,
		CHUNK_SOLID_PACK,
		0x00034001,
		CHUNK_SOLID_OBJECT,
		0x00034003,
		0x00034004,
		0x00034005,
		0x00034006,
		0x00034012,
		0x0003401D,
		0x00000000,
	]


func _default_physics_tuning(car_id: String) -> Dictionary:
	return {
		"source": "estimated_from_hp2_physicscar_reverse_pass",
		"reverse_notes": "res://eagl/assets/car/reverse_notes.md",
		"car_id": car_id,
		"max_forward_speed": 86.0,
		"max_reverse_speed": 18.0,
		"engine_accel": 34.0,
		"brake_accel": 48.0,
		"reverse_accel": 18.0,
		"linear_drag": 0.42,
		"rolling_drag": 2.0,
		"lateral_grip": 8.5,
		"handbrake_grip_scale": 0.38,
		"steer_rate": 2.6,
		"steer_return_rate": 5.0,
		"max_steer_angle": 0.62,
		"yaw_response": 2.8,
		"yaw_damping": 5.5,
		"gravity": 28.0,
		"suspension_height": 0.75,
		"ground_probe_distance": 1.35,
		"wheel_radius": 0.36,
		"status": "estimated",
	}
