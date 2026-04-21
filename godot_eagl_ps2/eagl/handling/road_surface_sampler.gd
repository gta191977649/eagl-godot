class_name RoadSurfaceSampler
extends RefCounted

const MathUtils = preload("res://eagl/utils/math_utils.gd")

const GS_PRIM_TRIANGLE = 3
const GS_PRIM_TRIANGLE_STRIP = 4
const GS_PRIM_TRIANGLE_FAN = 5
const SURFACE_EPSILON = 0.0001

var cell_size = 8.0
var up_normal_threshold = 0.05

var _cells = {}
var _triangles: Array[Dictionary] = []


func clear() -> void:
	_cells.clear()
	_triangles.clear()


func build_from_flat_plane(width: float, depth: float, height_z: float = 0.0, material_id: int = 0) -> void:
	clear()
	var half_width = width * 0.5
	var half_depth = depth * 0.5
	var a = Vector3(-half_width, -half_depth, height_z)
	var b = Vector3(half_width, -half_depth, height_z)
	var c = Vector3(half_width, half_depth, height_z)
	var d = Vector3(-half_width, half_depth, height_z)
	_add_triangle(a, b, c, material_id)
	_add_triangle(a, c, d, material_id)


func build_from_track_asset(asset) -> void:
	clear()
	if asset == null:
		return

	for obj in asset.objects:
		if bool(obj.get("is_scenery_template", false)):
			continue
		var name = String(obj.get("name", "")).to_upper()
		if name.begins_with("SKYDOME") or name.contains("ENVMAP") or name == "WATER":
			continue

		var transform_rows: Array = obj.get("transform", [])
		var blocks: Array = obj.get("blocks", [])
		var texture_hashes: Array = obj.get("texture_hashes", [])
		for block_index in range(blocks.size()):
			var block: Dictionary = blocks[block_index]
			var run: Dictionary = block.get("run", {})
			var raw_vertices: Array = run.get("vertices", [])
			if raw_vertices.size() < 3:
				continue

			var transformed: Array[Vector3] = []
			transformed.resize(raw_vertices.size())
			for vertex_index in range(raw_vertices.size()):
				transformed[vertex_index] = MathUtils.transform_point_rows(raw_vertices[vertex_index], transform_rows)

			var indices = _indices_for_block(block, transformed.size())
			if indices.size() < 3:
				continue

			var material_id = _material_id_for(obj, block, block_index, texture_hashes)
			for index in range(0, indices.size() - 2, 3):
				var a_index = int(indices[index])
				var b_index = int(indices[index + 1])
				var c_index = int(indices[index + 2])
				if a_index < 0 or b_index < 0 or c_index < 0:
					continue
				if a_index >= transformed.size() or b_index >= transformed.size() or c_index >= transformed.size():
					continue
				_add_triangle(transformed[a_index], transformed[b_index], transformed[c_index], material_id)


func sample_surface(sample_point_ps2: Vector3) -> Dictionary:
	if _triangles.is_empty():
		return {}

	var cell_x = int(floor(sample_point_ps2.x / cell_size))
	var cell_y = int(floor(sample_point_ps2.y / cell_size))
	var best = {}
	var best_height = -INF

	for offset_x in range(-1, 2):
		for offset_y in range(-1, 2):
			var key = _cell_key(cell_x + offset_x, cell_y + offset_y)
			var candidates: Array = _cells.get(key, [])
			for triangle_index in candidates:
				var triangle: Dictionary = _triangles[triangle_index]
				if sample_point_ps2.x < float(triangle["min_x"]) - SURFACE_EPSILON:
					continue
				if sample_point_ps2.x > float(triangle["max_x"]) + SURFACE_EPSILON:
					continue
				if sample_point_ps2.y < float(triangle["min_y"]) - SURFACE_EPSILON:
					continue
				if sample_point_ps2.y > float(triangle["max_y"]) + SURFACE_EPSILON:
					continue

				var bary = _barycentric_xy(
					sample_point_ps2,
					triangle["a"],
					triangle["b"],
					triangle["c"]
				)
				if bary.is_empty():
					continue

				var height_z = float(bary["u"]) * triangle["a"].z + float(bary["v"]) * triangle["b"].z + float(bary["w"]) * triangle["c"].z
				if height_z <= best_height:
					continue

				best_height = height_z
				best = {
					"height_z": height_z,
					"point": Vector3(sample_point_ps2.x, sample_point_ps2.y, height_z),
					"normal": triangle["normal"],
					"material_id": triangle["material_id"],
				}

	return best


func _add_triangle(a: Vector3, b: Vector3, c: Vector3, material_id: int) -> void:
	var normal = (b - a).cross(c - a)
	if normal.length_squared() <= SURFACE_EPSILON:
		return
	if normal.z < 0.0:
		var swap = b
		b = c
		c = swap
		normal = (b - a).cross(c - a)
	if normal.length_squared() <= SURFACE_EPSILON:
		return
	normal = normal.normalized()
	if normal.z < up_normal_threshold:
		return

	var triangle = {
		"a": a,
		"b": b,
		"c": c,
		"normal": normal,
		"material_id": material_id,
		"min_x": minf(a.x, minf(b.x, c.x)),
		"max_x": maxf(a.x, maxf(b.x, c.x)),
		"min_y": minf(a.y, minf(b.y, c.y)),
		"max_y": maxf(a.y, maxf(b.y, c.y)),
	}

	var triangle_index = _triangles.size()
	_triangles.append(triangle)

	var min_cell_x = int(floor(float(triangle["min_x"]) / cell_size))
	var max_cell_x = int(floor(float(triangle["max_x"]) / cell_size))
	var min_cell_y = int(floor(float(triangle["min_y"]) / cell_size))
	var max_cell_y = int(floor(float(triangle["max_y"]) / cell_size))
	for cell_x in range(min_cell_x, max_cell_x + 1):
		for cell_y in range(min_cell_y, max_cell_y + 1):
			var key = _cell_key(cell_x, cell_y)
			if not _cells.has(key):
				_cells[key] = []
			_cells[key].append(triangle_index)


func _barycentric_xy(point: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Dictionary:
	var ab = Vector2(b.x - a.x, b.y - a.y)
	var ac = Vector2(c.x - a.x, c.y - a.y)
	var ap = Vector2(point.x - a.x, point.y - a.y)
	var denom = ab.x * ac.y - ab.y * ac.x
	if absf(denom) <= SURFACE_EPSILON:
		return {}

	var v = (ap.x * ac.y - ap.y * ac.x) / denom
	var w = (ab.x * ap.y - ab.y * ap.x) / denom
	var u = 1.0 - v - w
	if u < -SURFACE_EPSILON or v < -SURFACE_EPSILON or w < -SURFACE_EPSILON:
		return {}
	return {
		"u": u,
		"v": v,
		"w": w,
	}


func _material_id_for(obj: Dictionary, block: Dictionary, block_index: int, texture_hashes: Array) -> int:
	var name_hash = int(obj.get("name_hash", 0))
	var texture_index = int(block.get("texture_index", -1))
	if texture_index >= 0 and texture_index < texture_hashes.size():
		return int(texture_hashes[texture_index])
	return name_hash + block_index


func _cell_key(cell_x: int, cell_y: int) -> String:
	return "%d:%d" % [cell_x, cell_y]


func _indices_for_block(block: Dictionary, vertex_count: int) -> PackedInt32Array:
	var primitive_mode: String = block.get("primitive_mode", "strip")
	var prim_type = _gs_prim_type_for_mode(primitive_mode)
	if prim_type == GS_PRIM_TRIANGLE_STRIP:
		return _strip_control_indices(block, vertex_count)
	if prim_type == GS_PRIM_TRIANGLE:
		return _triangle_list_indices(vertex_count)
	if prim_type == GS_PRIM_TRIANGLE_FAN:
		return _fan_indices(vertex_count)
	return PackedInt32Array()


func _strip_control_indices(block: Dictionary, vertex_count: int) -> PackedInt32Array:
	var disabled: Array = _adc_disabled_from_vif_control(block.get("run", {}).get("header", []), block.get("run", {}).get("tri_cull", []), vertex_count)
	if disabled.is_empty():
		disabled.resize(vertex_count)
		for index in range(vertex_count):
			disabled[index] = false

	var out = PackedInt32Array()
	var face = 1
	for index in range(vertex_count):
		if bool(disabled[index]):
			face = 1
			continue
		var a = index - 1 - face
		var b = index - 1
		var c = index - 1 + face
		if a >= 0 and b >= 0 and c >= 0 and a < vertex_count and b < vertex_count and c < vertex_count:
			_append_tri(out, a, b, c)
		face = -face
	return out


func _adc_disabled_from_vif_control(header: Array, tri_cull: Array, vertex_count: int) -> Array:
	if header.size() < 2 or tri_cull.size() < 4 or vertex_count <= 0:
		return []
	var num_vertices = int(header[0])
	var mode = int(header[1])
	if num_vertices <= 0 or num_vertices > vertex_count or num_vertices > 32 or mode > 7:
		return []
	var mask = _vif_control_mask(num_vertices, mode, tri_cull)
	var out: Array[bool] = []
	for index in range(vertex_count):
		out.append(((mask >> (31 - index)) & 1) != 0)
	return out


func _vif_control_mask(num_vertices: int, mode: int, tri_cull: Array) -> int:
	var use_upper = mode & 0x04
	var downer_side = (-(((mode & 0x03) + 1) >> 2) << (use_upper >> 2)) & 0x03
	var upper_side = ~(-use_upper)

	var downer = int(tri_cull[downer_side]) if downer_side >= 0 and downer_side < tri_cull.size() else 0
	var upper = int(tri_cull[upper_side]) if upper_side >= 0 and upper_side < tri_cull.size() else 0

	var hi_downer = downer >> 18
	var lo_downer = downer & 0x7FFF
	var hi_downer_swap = hi_downer ^ (lo_downer & 0x1E)
	var hi_upper_swap = ((upper >> 2) | ((mode + 1) >> 1)) & 0x04

	var new_downer = (lo_downer << 4) | (hi_downer_swap >> 1)
	var new_upper = (upper >> 2) ^ (((hi_downer_swap >> 1) & 0x07) << 13) ^ (hi_upper_swap << 18)

	var mask = _shift_left(new_downer, ((mode - 3) << 2) - 3)
	if use_upper != 0:
		mask = (mask & ((0xFFFFFFFF << 13) & 0xFFFFFFFF)) | (new_upper & 0x3FFF)
	mask = _shift_left(mask, (7 - mode) << 2)
	mask = mask & ((0xFFFFFFFF << (32 - num_vertices)) & 0xFFFFFFFF)
	return mask & 0xFFFFFFFF


func _shift_left(value: int, shift: int) -> int:
	if shift >= 0:
		return value << shift
	return value >> -shift


func _triangle_list_indices(count: int) -> PackedInt32Array:
	var out = PackedInt32Array()
	for index in range(0, count - (count % 3), 3):
		_append_tri(out, index, index + 1, index + 2)
	return out


func _fan_indices(count: int) -> PackedInt32Array:
	var out = PackedInt32Array()
	for index in range(1, count - 1):
		_append_tri(out, 0, index, index + 1)
	return out


func _append_tri(out: PackedInt32Array, a: int, b: int, c: int) -> void:
	if a != b and a != c and b != c:
		out.append(a)
		out.append(b)
		out.append(c)


func _gs_prim_type_for_mode(mode: String) -> int:
	if mode == "triangles":
		return GS_PRIM_TRIANGLE
	if mode == "fan":
		return GS_PRIM_TRIANGLE_FAN
	if mode == "strip":
		return GS_PRIM_TRIANGLE_STRIP
	return 0
