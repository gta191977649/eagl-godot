class_name CarParserPS2
extends RefCounted

const Binary := preload("res://eagl/platforms/ps2/ps2_binary_reader.gd")
const TrackParserPS2Script := preload("res://eagl/assets/track/track_parser_ps2.gd")
const CarAssetScript := preload("res://eagl/assets/car/car_asset.gd")

const CHUNK_CAR_METADATA := 0x00034013
const CHUNK_SOLID_PACK := 0x80034000
const CHUNK_SOLID_OBJECT := 0x80034002
const HP2_CAR_VERTEX_SCALE := 1.0

var _track_parser := TrackParserPS2Script.new()


func parse(files: Dictionary):
	var asset = CarAssetScript.new()
	asset.car_id = String(files.get("car_id", "")).to_upper()
	asset.source_path = files.get("geometry", "")
	asset.source_files = files.duplicate(true)
	asset.physics_tuning = _default_physics_tuning(asset.car_id)

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
	asset.metadata["wheel_slots"] = _infer_wheel_slots(asset.locators)
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
	asset.metadata["parser"] = "CarParserPS2"
	asset.metadata["geometry_bundle_size"] = bundle.size()
	asset.metadata["chunk_count"] = _track_parser._walk_chunks(chunks).size()
	asset.metadata["car_vertex_scale"] = HP2_CAR_VERTEX_SCALE
	asset.metadata["car_visual_transform_mode"] = "raw_z_up_vertices_modelulator_legacy_hp2"
	return asset


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
			var locator := {
				"index": out.size(),
				"source_chunk_offset": int(chunk.get("offset", -1)),
				"record_offset": offset,
				"word_00": Binary.u32(record, 0x00),
				"word_04": Binary.u32(record, 0x04),
				"hash_08": Binary.u32(record, 0x08),
				"hash_0c": Binary.u32(record, 0x0C),
				"position_ps2": Vector3(Binary.f32(record, 0x10), Binary.f32(record, 0x14), Binary.f32(record, 0x18)),
				"word_1c": Binary.u32(record, 0x1C),
				"raw_hex": record.hex_encode(),
				"decode_status": "estimated_0x20_record",
			}
			out.append(locator)
	return out


func _build_part_groups(asset) -> Dictionary:
	var groups := {}
	for obj in asset.all_objects():
		var group: String = obj.get("part_group", "Body")
		if not groups.has(group):
			groups[group] = []
		groups[group].append(obj.get("name", ""))
	return groups


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
	obj["transform"] = []
	obj["vertex_scale"] = HP2_CAR_VERTEX_SCALE
	obj["coordinate_space"] = "hp2_car_local_x_forward_z_up"
	obj["visual_transform_mode"] = "identity_raw_vertices"
	var part_key := _part_key(object_name.to_upper(), car_id)
	obj["disable_vertex_color"] = part_key.contains("TIRE")
	obj["skip_missing_texture_surfaces"] = part_key.contains("TIRE")
	obj["material_role"] = "hp2_car_dashboard" if is_dashboard else "hp2_car_exterior"
	obj["render_default"] = _should_render_default(object_name, car_id, is_dashboard)
	obj["variant_role"] = _variant_role_for_name(object_name, car_id, is_dashboard)


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
					"axle": axle,
					"side": side,
					"position_ps2": p,
					"position_godot": Vector3(p.y, p.z, -p.x),
					"locator_index": best.get("index", -1),
					"hash_08": best.get("hash_08", 0),
				})
	return slots


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
