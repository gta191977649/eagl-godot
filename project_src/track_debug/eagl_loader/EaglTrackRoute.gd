class_name EaglTrackRoute
extends RefCounted

const EaglBinary = preload("res://track_debug/eagl_loader/EaglBinary.gd")

var track_dir = ""
var level_dir = ""
var compartment_ids: Array[int] = []
var levelft_ids: Array[String] = []
var route_points: PackedVector3Array = PackedVector3Array()
var ai_route_points: PackedVector3Array = PackedVector3Array()
var ai_route_segments: Array[PackedVector3Array] = []
var route_node_positions: PackedVector3Array = PackedVector3Array()
var error = ""
var _route_lengths = PackedFloat32Array()
var _route_node_distances = PackedFloat32Array()
var _route_total_length = 0.0


func load_route(tracks_root: String, track_name: String, level_index: int) -> bool:
	track_dir = tracks_root.path_join(track_name)
	level_dir = track_dir.path_join("level%02d" % level_index)
	compartment_ids = _parse_drvpath(level_dir.path_join("drvpath.ini"))
	var level_data = _parse_level_dat(level_dir.path_join("level.dat"))
	levelft_ids.assign(level_data.levelft)
	route_points = level_data.points
	_rebuild_route_lengths()
	var ai_data = _parse_aipaths(level_dir.path_join("aipaths.dat"))
	ai_route_points = ai_data["points"]
	ai_route_segments.assign(ai_data["segments"])
	_rebuild_default_route_nodes()
	if compartment_ids.is_empty():
		error = "No compartments found in %s" % level_dir
		return false
	return true


func unique_compartments() -> Array[int]:
	var seen = {}
	var out: Array[int] = []
	for comp_id in compartment_ids:
		if seen.has(comp_id):
			continue
		seen[comp_id] = true
		out.append(comp_id)
	return out


func active_compartments(route_index: int, radius: int) -> Array[int]:
	var out: Array[int] = []
	if compartment_ids.is_empty():
		return out
	for offset in range(-radius, radius + 1):
		var comp_id = compartment_ids[_wrapped_index(route_index + offset)]
		if not out.has(comp_id):
			out.append(comp_id)
	return out


func compartments_for_route_indices(route_indices: Array[int]) -> Array[int]:
	var out: Array[int] = []
	if compartment_ids.is_empty():
		return out
	for route_index in route_indices:
		var comp_id = compartment_ids[_wrapped_index(route_index)]
		if not out.has(comp_id):
			out.append(comp_id)
	return out


func set_route_node_anchors_from_compartment_bounds(_compartment_bounds: Dictionary) -> void:
	use_default_route_node_anchors()


func use_default_route_node_anchors() -> void:
	_rebuild_default_route_nodes()


func nearest_route_index(position: Vector3) -> int:
	if route_points.is_empty() or compartment_ids.is_empty():
		return 0
	return route_index_at_distance_for_direction(route_distance_along(position), 0)


func nearest_route_index_from(position: Vector3, current_index: int) -> int:
	if compartment_ids.is_empty():
		return 0
	var distance_along = route_distance_along(position)
	var proposed = route_index_near_current(distance_along, current_index, 0, 0.0)
	return limited_route_index_from(current_index, proposed)


func route_index_nearest_anchor(position: Vector3, current_index: int = -1, hysteresis: float = 0.0) -> int:
	if compartment_ids.is_empty():
		return 0
	if route_node_positions.size() != compartment_ids.size():
		return _nearest_point_index(position) % compartment_ids.size() if not route_points.is_empty() else 0
	var best_index = _wrapped_index(max(0, current_index)) if current_index >= 0 else 0
	var best_distance = INF
	for index in range(route_node_positions.size()):
		var distance = _xz_distance_squared(position, route_node_positions[index])
		if distance < best_distance:
			best_index = index
			best_distance = distance
	if current_index >= 0 and current_index < route_node_positions.size() and hysteresis > 0.0:
		var current_distance = sqrt(_xz_distance_squared(position, route_node_positions[current_index]))
		var best_linear_distance = sqrt(best_distance)
		if current_distance <= best_linear_distance + hysteresis:
			return current_index
	return best_index


func route_index_near_current(distance_along: float, current_index: int, direction: int, hysteresis: float) -> int:
	if compartment_ids.is_empty() or _route_total_length <= 0.0:
		return 0
	if current_index < 0 or current_index >= compartment_ids.size():
		return route_index_at_distance_for_direction(distance_along, direction)
	if _route_node_distances.size() != compartment_ids.size():
		return route_index_at_distance_for_direction(distance_along, direction)
	var current_distance = absf(route_distance_delta(_route_node_distances[current_index], distance_along))
	var next_index = _wrapped_index(current_index + 1)
	var previous_index = _wrapped_index(current_index - 1)
	if direction > 0:
		return _closer_neighbor_or_current(current_index, next_index, current_distance, distance_along, hysteresis)
	if direction < 0:
		return _closer_neighbor_or_current(current_index, previous_index, current_distance, distance_along, hysteresis)
	return _closest_current_or_adjacent(current_index, previous_index, next_index, current_distance, distance_along, hysteresis)


func route_index_at_distance_for_direction(distance_along: float, direction: int) -> int:
	if compartment_ids.is_empty() or _route_total_length <= 0.0:
		return 0
	if _route_node_distances.size() != compartment_ids.size():
		return _route_index_at_equal_distance_bin(distance_along, direction)
	var best_index = 0
	var best_abs_delta = INF
	var best_direction_delta = INF
	for index in range(_route_node_distances.size()):
		var delta = route_distance_delta(_route_node_distances[index], distance_along)
		var abs_delta = absf(delta)
		var direction_delta = absf(delta) if direction == 0 or signf(delta) == float(direction) else absf(delta) + 1.0
		if abs_delta < best_abs_delta - 0.001 or (absf(abs_delta - best_abs_delta) <= 0.001 and direction_delta < best_direction_delta):
			best_index = index
			best_abs_delta = abs_delta
			best_direction_delta = direction_delta
	return best_index


func limited_route_index_from(current_index: int, proposed: int) -> int:
	if current_index < 0 or current_index >= compartment_ids.size():
		return _wrapped_index(proposed)
	var delta = _wrapped_delta(current_index, proposed)
	if abs(delta) <= 1:
		return _wrapped_index(proposed)
	if abs(delta) <= 2:
		return _wrapped_index(current_index + signi(delta))
	return current_index


func route_distance_along(position: Vector3) -> float:
	if route_points.is_empty() or _route_total_length <= 0.0:
		return 0.0
	return _nearest_route_distance_along(position)


func route_distance_along_near(position: Vector3, previous_distance: float, max_xz_distance: float = 140.0) -> float:
	if route_points.is_empty() or _route_total_length <= 0.0:
		return 0.0
	if previous_distance < 0.0:
		return _nearest_route_distance_along(position)
	var candidates = _route_distance_candidates(position)
	if candidates.is_empty():
		return 0.0
	var best_xz_distance = INF
	for candidate in candidates:
		best_xz_distance = min(best_xz_distance, candidate["xz_distance"])
	var max_candidate_distance = best_xz_distance + max_xz_distance
	var best_along = candidates[0]["along"]
	var best_continuity = INF
	var best_distance = INF
	for candidate in candidates:
		var candidate_distance = float(candidate["xz_distance"])
		if candidate_distance > max_candidate_distance:
			continue
		var continuity = absf(route_distance_delta(previous_distance, candidate["along"]))
		if continuity < best_continuity - 0.001 or (absf(continuity - best_continuity) <= 0.001 and candidate_distance < best_distance):
			best_along = candidate["along"]
			best_continuity = continuity
			best_distance = candidate_distance
	return best_along


func route_distance_delta(from_distance: float, to_distance: float) -> float:
	if _route_total_length <= 0.0:
		return to_distance - from_distance
	var delta = to_distance - from_distance
	if delta > _route_total_length * 0.5:
		delta -= _route_total_length
	elif delta < -_route_total_length * 0.5:
		delta += _route_total_length
	return delta


func route_tangent_at_distance(distance_along: float) -> Vector3:
	if route_points.size() < 2:
		return Vector3.FORWARD
	var target = clampf(distance_along, 0.0, _route_total_length)
	for index in range(route_points.size() - 1):
		var segment_length = route_points[index].distance_to(route_points[index + 1])
		if segment_length <= 0.000001:
			continue
		if target <= _route_lengths[index] + segment_length or index == route_points.size() - 2:
			return (route_points[index + 1] - route_points[index]).normalized()
	return (route_points[1] - route_points[0]).normalized()


func projected_position(position: Vector3) -> Vector3:
	if route_points.is_empty():
		return position
	if _route_total_length <= 0.0:
		return route_points[_nearest_point_index(position)]
	return _point_at_distance(_nearest_route_distance_along(position))


func route_position_for_index(route_index: int) -> Vector3:
	if route_points.is_empty() or compartment_ids.is_empty():
		return Vector3.ZERO
	if route_node_positions.size() == compartment_ids.size():
		return route_node_positions[_wrapped_index(route_index)]
	if _route_total_length <= 0.0:
		return route_points[_wrapped_index(route_index) % route_points.size()]
	return _point_at_distance(_route_total_length * float(_wrapped_index(route_index)) / float(compartment_ids.size()))


func _route_index_at_distance(distance_along: float) -> int:
	if compartment_ids.is_empty() or _route_total_length <= 0.0:
		return 0
	return route_index_at_distance_for_direction(distance_along, 0)


func _route_index_at_equal_distance_bin(distance_along: float, direction: int) -> int:
	var alpha = clampf(distance_along / _route_total_length, 0.0, 0.999999) * float(compartment_ids.size())
	if direction < 0:
		return _wrapped_index(int(ceil(alpha - 0.000001)))
	return int(floor(alpha)) % compartment_ids.size()


func _closer_neighbor_or_current(current_index: int, neighbor_index: int, current_distance: float, distance_along: float, hysteresis: float) -> int:
	var neighbor_distance = absf(route_distance_delta(_route_node_distances[neighbor_index], distance_along))
	if neighbor_distance + hysteresis < current_distance:
		return neighbor_index
	return current_index


func _closest_current_or_adjacent(current_index: int, previous_index: int, next_index: int, current_distance: float, distance_along: float, hysteresis: float) -> int:
	var best_index = current_index
	var best_distance = current_distance
	var previous_distance = absf(route_distance_delta(_route_node_distances[previous_index], distance_along))
	if previous_distance + hysteresis < best_distance:
		best_index = previous_index
		best_distance = previous_distance
	var next_distance = absf(route_distance_delta(_route_node_distances[next_index], distance_along))
	if next_distance + hysteresis < best_distance:
		best_index = next_index
	return best_index


func _point_at_distance(distance_along: float) -> Vector3:
	var target = clampf(distance_along, 0.0, _route_total_length)
	for index in range(max(0, route_points.size() - 1)):
		var start_length = _route_lengths[index]
		var segment_length = route_points[index].distance_to(route_points[index + 1])
		if segment_length <= 0.000001:
			continue
		if target <= start_length + segment_length or index == route_points.size() - 2:
			var t = clampf((target - start_length) / segment_length, 0.0, 1.0)
			return route_points[index].lerp(route_points[index + 1], t)
	return route_points[0]


func _nearest_point_index(position: Vector3) -> int:
	var best_index = 0
	var best_distance = INF
	for index in range(route_points.size()):
		var point = route_points[index]
		var distance = _xz_distance_squared(position, point)
		if distance < best_distance:
			best_distance = distance
			best_index = index
	return best_index


func _xz_distance_squared(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length_squared()


func _nearest_route_distance_along(position: Vector3) -> float:
	var candidates = _route_distance_candidates(position)
	if candidates.is_empty():
		return 0.0
	var best_candidate = candidates[0]
	for candidate in candidates:
		if candidate["xz_distance"] < best_candidate["xz_distance"]:
			best_candidate = candidate
	return best_candidate["along"]


func _route_distance_candidates(position: Vector3) -> Array:
	var out = []
	for index in range(max(0, route_points.size() - 1)):
		var a = route_points[index]
		var b = route_points[index + 1]
		var ab = Vector2(b.x - a.x, b.z - a.z)
		var ap = Vector2(position.x - a.x, position.z - a.z)
		var segment_length_sq = ab.length_squared()
		if segment_length_sq <= 0.000001:
			continue
		var t = clampf(ap.dot(ab) / segment_length_sq, 0.0, 1.0)
		var projected = Vector2(a.x, a.z) + ab * t
		out.append({
			"along": _route_lengths[index] + route_points[index].distance_to(route_points[index + 1]) * t,
			"xz_distance": Vector2(position.x, position.z).distance_to(projected)
		})
	return out


func _rebuild_route_lengths() -> void:
	_route_lengths = PackedFloat32Array()
	_route_total_length = 0.0
	for index in range(route_points.size()):
		_route_lengths.append(_route_total_length)
		if index + 1 < route_points.size():
			_route_total_length += route_points[index].distance_to(route_points[index + 1])


func _rebuild_default_route_nodes() -> void:
	route_node_positions = PackedVector3Array()
	_route_node_distances = PackedFloat32Array()
	for index in range(compartment_ids.size()):
		_append_default_route_node(index)


func _append_default_route_node(index: int) -> void:
	if route_points.is_empty():
		_route_node_distances.append(0.0)
		route_node_positions.append(Vector3.ZERO)
		return
	var distance_along = 0.0
	if _route_total_length > 0.0 and not compartment_ids.is_empty():
		distance_along = _route_total_length * float(_wrapped_index(index)) / float(compartment_ids.size())
	_route_node_distances.append(distance_along)
	route_node_positions.append(_point_at_distance(distance_along) if _route_total_length > 0.0 else route_points[index % route_points.size()])


func _wrapped_index(index: int) -> int:
	var count = compartment_ids.size()
	return ((index % count) + count) % count


func _wrapped_delta(from_index: int, to_index: int) -> int:
	var count = compartment_ids.size()
	var delta = _wrapped_index(to_index) - _wrapped_index(from_index)
	if delta > count / 2:
		delta -= count
	elif delta < -count / 2:
		delta += count
	return delta


func _parse_drvpath(path: String) -> Array[int]:
	var out: Array[int] = []
	var node_count = -1
	var node_compartment_ids = {}
	var current_section = ""
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return out
	while not file.eof_reached():
		var line = file.get_line().strip_edges()
		if line.begins_with("[") and line.ends_with("]"):
			current_section = line.substr(1, line.length() - 2)
			continue
		var parts = line.split("=", false, 1)
		if parts.size() != 2:
			continue
		var key = parts[0].strip_edges().to_lower()
		var value = parts[1].strip_edges()
		var section = current_section.to_lower()
		if section == "path" and key == "nodenum":
			node_count = value.to_int()
		elif section.begins_with("node") and key == "compartmentid":
			var index_text = section.substr(4)
			if index_text.is_valid_int():
				node_compartment_ids[index_text.to_int()] = value.to_int()
	if node_count < 0:
		node_count = node_compartment_ids.size()
	elif node_count >= 0x40:
		node_count = 0x3f
	for index in range(node_count):
		if node_compartment_ids.has(index):
			out.append(int(node_compartment_ids[index]))
	return out


func _parse_level_dat(path: String) -> Dictionary:
	var data = FileAccess.get_file_as_bytes(path)
	var out = {"levelft": [], "points": PackedVector3Array()}
	var off = 0
	var sizes = [0x24, 0x14, 0x78, 0x38, 0x44, 0x74, 0x10, 0x24, 0x0c]
	for table_index in range(sizes.size()):
		if off + 4 > data.size():
			return out
		var count = EaglBinary.u32(data, off)
		off += 4
		if table_index == 3:
			for _i in range(count):
				out.levelft.append(EaglBinary.fixed_string(data, off, 0x0c))
				off += sizes[table_index]
		elif table_index == 8:
			out.points = _read_points(data, off, count)
			off += count * sizes[table_index]
		else:
			off += count * sizes[table_index]
	return out


func _read_points(data: PackedByteArray, offset: int, count: int) -> PackedVector3Array:
	var out = PackedVector3Array()
	for index in range(count):
		var off = offset + index * 0x0c
		if off + 12 > data.size():
			break
		out.append(Vector3(EaglBinary.f32(data, off), EaglBinary.f32(data, off + 4), EaglBinary.f32(data, off + 8)))
	return out


func _parse_aipaths(path: String) -> Dictionary:
	var data = FileAccess.get_file_as_bytes(path)
	var segments: Array[PackedVector3Array] = []
	if data.size() < 8:
		return {"points": PackedVector3Array(), "segments": segments}
	var name_offsets = _find_aipath_center_records(data)
	for name_offset in name_offsets:
		var points = _read_aipath_record_points(data, name_offset)
		if points.size() > 1:
			segments.append(points)
	if not segments.is_empty() and _route_total_length > 0.0:
		var drive_segments = _select_drive_route_segments(segments)
		if not drive_segments.is_empty():
			segments = drive_segments
	return {"points": _flatten_segments(segments), "segments": segments}


func _select_drive_route_segments(segments: Array[PackedVector3Array]) -> Array[PackedVector3Array]:
	var records = []
	for segment in segments:
		var metrics = _ai_segment_route_metrics(segment)
		if metrics.is_empty():
			continue
		records.append(metrics)
	if records.is_empty():
		return segments
	records.sort_custom(func(a, b): return a["start"] < b["start"])
	var route_start = records[0]["start"]
	var target_end = route_start + _route_total_length - 1.0
	var current = route_start
	var selected = []
	var used = {}
	var guard = 0
	while current < target_end and guard < records.size() * 2:
		guard += 1
		var choice = {}
		var choice_index = -1
		for index in range(records.size()):
			if used.has(index):
				continue
			var record = records[index]
			var start = _unwrap_route_distance(record["start"], route_start)
			var end = _unwrap_route_distance(record["end"], route_start)
			if end <= start:
				end += _route_total_length
			if start > current + 80.0 or end <= current + 1.0:
				continue
			if choice.is_empty() or _ai_record_is_better(record, start, end, choice, choice["unwrapped_start"], choice["unwrapped_end"]):
				choice = record
				choice["unwrapped_start"] = start
				choice["unwrapped_end"] = end
				choice_index = index
		if choice.is_empty():
			var nearest_index = -1
			var nearest_start = INF
			for index in range(records.size()):
				if used.has(index):
					continue
				var start = _unwrap_route_distance(records[index]["start"], route_start)
				if start >= current and start < nearest_start:
					nearest_start = start
					nearest_index = index
			if nearest_index == -1:
				break
			choice = records[nearest_index]
			choice["unwrapped_start"] = nearest_start
			choice["unwrapped_end"] = _unwrap_route_distance(choice["end"], route_start)
			if choice["unwrapped_end"] <= choice["unwrapped_start"]:
				choice["unwrapped_end"] += _route_total_length
			choice_index = nearest_index
		used[choice_index] = true
		selected.append(choice["segment"])
		current = max(current, choice["unwrapped_end"])
	var out: Array[PackedVector3Array] = []
	out.assign(selected)
	return out


func _ai_segment_route_metrics(segment: PackedVector3Array) -> Dictionary:
	if segment.size() < 2:
		return {}
	var max_distance = 0.0
	var total_distance = 0.0
	for point in segment:
		var projected = _point_at_distance(route_distance_along(point))
		var distance = sqrt(_xz_distance_squared(point, projected))
		max_distance = max(max_distance, distance)
		total_distance += distance
	return {
		"segment": segment,
		"start": route_distance_along(segment[0]),
		"end": route_distance_along(segment[segment.size() - 1]),
		"max_distance": max_distance,
		"avg_distance": total_distance / float(segment.size())
	}


func _unwrap_route_distance(distance: float, origin: float) -> float:
	var out = distance
	while out < origin:
		out += _route_total_length
	return out


func _ai_record_is_better(candidate: Dictionary, candidate_start: float, candidate_end: float, current: Dictionary, current_start: float, current_end: float) -> bool:
	if candidate["avg_distance"] < current["avg_distance"] - 0.001:
		return true
	if candidate["avg_distance"] > current["avg_distance"] + 0.001:
		return false
	if candidate["max_distance"] < current["max_distance"] - 0.001:
		return true
	if candidate["max_distance"] > current["max_distance"] + 0.001:
		return false
	var candidate_length = candidate_end - candidate_start
	var current_length = current_end - current_start
	if candidate_length > current_length + 0.001:
		return true
	if candidate_length < current_length - 0.001:
		return false
	return candidate_start < current_start


func _find_aipath_center_records(data: PackedByteArray) -> Array[int]:
	var pattern = PackedByteArray([65, 73, 95, 99, 101, 110, 116, 101, 114])
	var offsets: Array[int] = []
	for offset in range(max(0, data.size() - pattern.size() + 1)):
		var matches = true
		for index in range(pattern.size()):
			if data[offset + index] != pattern[index]:
				matches = false
				break
		if matches:
			offsets.append(offset)
	return offsets


func _read_aipath_record_points(data: PackedByteArray, name_offset: int) -> PackedVector3Array:
	var out = PackedVector3Array()
	var point_count_offset = name_offset + 0x20
	var point_offset = name_offset + 0x24
	if point_count_offset + 4 > data.size() or point_offset >= data.size():
		return out
	var point_count = EaglBinary.u32(data, point_count_offset)
	if point_count <= 0 or point_count > 4096:
		return out
	var max_count = mini(point_count, int((data.size() - point_offset) / 28))
	for index in range(max_count):
		var offset = point_offset + index * 28
		_append_unique_point(out, Vector3(
			EaglBinary.f32(data, offset),
			EaglBinary.f32(data, offset + 4),
			EaglBinary.f32(data, offset + 8)
		))
	return out


func _flatten_segments(segments: Array[PackedVector3Array]) -> PackedVector3Array:
	var out = PackedVector3Array()
	for segment in segments:
		for point in segment:
			_append_unique_point(out, point)
	return out


func _append_unique_point(out: PackedVector3Array, point: Vector3) -> void:
	if not is_finite(point.x) or not is_finite(point.y) or not is_finite(point.z):
		return
	if absf(point.x) > 100000.0 or absf(point.y) > 100000.0 or absf(point.z) > 100000.0:
		return
	if not out.is_empty() and out[out.size() - 1].distance_squared_to(point) < 0.0001:
		return
	out.append(point)
