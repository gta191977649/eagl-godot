class_name EAGLMeshBuilder
extends RefCounted

const MathUtils := preload("res://eagl/utils/math_utils.gd")
const MaterialBuilderScript := preload("res://eagl/rendering/material_builder.gd")

const GS_PRIM_TRIANGLE := 3
const GS_PRIM_TRIANGLE_STRIP := 4
const GS_PRIM_TRIANGLE_FAN := 5

var material_builder := MaterialBuilderScript.new()
var texture_bank = null:
	set(value):
		texture_bank = value
		material_builder.texture_bank = value
var texture_filter_mode := "linear_mipmap":
	set(value):
		texture_filter_mode = value
		material_builder.texture_filter_mode = value
var skipped: Dictionary = {}
var warnings: Array[String] = []
var textured_surfaces := 0
var fallback_surfaces := 0
var uv_surfaces := 0
var textured_missing_uv_surfaces := 0


func reset() -> void:
	material_builder.clear()
	material_builder.texture_bank = texture_bank
	material_builder.texture_filter_mode = texture_filter_mode
	skipped.clear()
	warnings.clear()
	textured_surfaces = 0
	fallback_surfaces = 0
	uv_surfaces = 0
	textured_missing_uv_surfaces = 0


func build_object_mesh(obj: Dictionary, apply_object_transform: bool = true) -> MeshInstance3D:
	var mesh := ArrayMesh.new()
	var object_name: String = obj.get("name", "EAGL_Object")
	var emitted_surfaces := 0
	var surface_materials: Array[Material] = []
	var blocks: Array = obj.get("blocks", [])
	for block_index in range(blocks.size()):
		var block: Dictionary = blocks[block_index]
		var vertices := _transformed_vertices(obj, block, apply_object_transform)
		if vertices.size() < 3:
			_count_skip("tiny_block")
			continue
		var indices := _indices_for_block(block, vertices.size())
		if indices.size() < 3:
			_count_skip("empty_indices")
			continue

		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_INDEX] = indices
		arrays[Mesh.ARRAY_NORMAL] = _normal_array(vertices, indices)

		var uvs := _uv_array(block, vertices.size())
		var has_uvs := uvs.size() == vertices.size()
		if has_uvs:
			arrays[Mesh.ARRAY_TEX_UV] = uvs
			uv_surfaces += 1

		var colors := _color_array(block, vertices.size())
		if colors.size() == vertices.size():
			arrays[Mesh.ARRAY_COLOR] = colors

		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var surface_index := mesh.get_surface_count() - 1
		var texture_hash := _texture_hash_for_block(obj, block_index)
		if texture_bank != null and texture_hash != 0 and texture_bank.has_texture(texture_hash):
			textured_surfaces += 1
			if not has_uvs:
				textured_missing_uv_surfaces += 1
		else:
			fallback_surfaces += 1
		var material := material_builder.material_for_block(object_name, block, block_index, colors.size() == vertices.size(), texture_hash)
		mesh.surface_set_material(surface_index, material)
		surface_materials.append(material)
		emitted_surfaces += 1

	if emitted_surfaces == 0:
		return null

	var node := MeshInstance3D.new()
	node.name = _safe_node_name(object_name)
	node.mesh = mesh
	for surface_index in range(surface_materials.size()):
		node.set_surface_override_material(surface_index, surface_materials[surface_index])
	node.set_meta("eagl_object_name", object_name)
	node.set_meta("eagl_chunk_offset", obj.get("chunk_offset", 0))
	node.set_meta("eagl_surface_material_count", surface_materials.size())
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
	return node


func _transformed_vertices(obj: Dictionary, block: Dictionary, apply_object_transform: bool = true) -> PackedVector3Array:
	var out := PackedVector3Array()
	var transform_rows: Array = obj.get("transform", [])
	var run: Dictionary = block.get("run", {})
	for vertex in run.get("vertices", []):
		var ps2_vertex: Vector3 = MathUtils.transform_point_rows(vertex, transform_rows) if apply_object_transform else vertex
		out.append(MathUtils.ps2_to_godot_vec3(ps2_vertex))
	return out


func _uv_array(block: Dictionary, vertex_count: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	var run: Dictionary = block.get("run", {})
	var texcoords: Array = run.get("texcoords", [])
	if texcoords.size() < vertex_count:
		return out
	for i in range(vertex_count):
		var uv: Vector2 = texcoords[i]
		out.append(Vector2(uv.x, 1.0 - uv.y))
	return out


func _color_array(block: Dictionary, vertex_count: int) -> PackedColorArray:
	var out := PackedColorArray()
	var run: Dictionary = block.get("run", {})
	var packed_values: Array = run.get("packed_values", [])
	if packed_values.size() < vertex_count:
		return out
	for i in range(vertex_count):
		out.append(_decode_vif_color_5551(int(packed_values[i])))
	return out


func _normal_array(vertices: PackedVector3Array, indices: PackedInt32Array) -> PackedVector3Array:
	var accum: Array[Vector3] = []
	accum.resize(vertices.size())
	for vertex_index in range(vertices.size()):
		accum[vertex_index] = Vector3.ZERO

	for index in range(0, indices.size() - 2, 3):
		var a := int(indices[index])
		var b := int(indices[index + 1])
		var c := int(indices[index + 2])
		if a < 0 or b < 0 or c < 0 or a >= vertices.size() or b >= vertices.size() or c >= vertices.size():
			continue
		var normal := (vertices[b] - vertices[a]).cross(vertices[c] - vertices[a])
		if normal.length_squared() <= 0.000001:
			continue
		normal = normal.normalized()
		accum[a] += normal
		accum[b] += normal
		accum[c] += normal

	var out := PackedVector3Array()
	out.resize(vertices.size())
	for vertex_index in range(vertices.size()):
		var normal := accum[vertex_index]
		out[vertex_index] = normal.normalized() if normal.length_squared() > 0.000001 else Vector3.UP
	return out


func _indices_for_block(block: Dictionary, vertex_count: int) -> PackedInt32Array:
	var primitive_mode: String = block.get("primitive_mode", "strip")
	var prim_type := _gs_prim_type_for_mode(primitive_mode)
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
			_append_tri(out, a, b, c)
		face = -face
	return out


func _adc_disabled_from_vif_control(header: Array, tri_cull: Array, vertex_count: int) -> Array:
	if header.size() < 2 or tri_cull.size() < 4 or vertex_count <= 0:
		return []
	var num_vertices := int(header[0])
	var mode := int(header[1])
	if num_vertices <= 0 or num_vertices > vertex_count or num_vertices > 32 or mode > 7:
		return []
	var mask := _vif_control_mask(num_vertices, mode, tri_cull)
	var out: Array[bool] = []
	for index in range(vertex_count):
		out.append(((mask >> (31 - index)) & 1) != 0)
	return out


func _vif_control_mask(num_vertices: int, mode: int, tri_cull: Array) -> int:
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

	var mask := _shift_left(new_downer, ((mode - 3) << 2) - 3)
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
	var out := PackedInt32Array()
	for i in range(0, count - (count % 3), 3):
		_append_tri(out, i, i + 1, i + 2)
	return out


func _fan_indices(count: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in range(1, count - 1):
		_append_tri(out, 0, i, i + 1)
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


func _decode_vif_color_5551(value: int) -> Color:
	var red := float((value & 0x1F) << 3) / 255.0
	var green := float(((value >> 5) & 0x1F) << 3) / 255.0
	var blue := float(((value >> 10) & 0x1F) << 3) / 255.0
	return Color(red, green, blue, 1.0)


func _texture_hash_for_block(obj: Dictionary, block_index: int) -> int:
	var hashes: Array = obj.get("texture_hashes", [])
	if hashes.is_empty():
		return 0
	var blocks: Array = obj.get("blocks", [])
	if block_index < blocks.size():
		var block: Dictionary = blocks[block_index]
		var texture_index := int(block.get("texture_index", -1))
		if texture_index >= 0 and texture_index < hashes.size():
			return int(hashes[texture_index])
	return int(hashes[mini(block_index, hashes.size() - 1)])


func _safe_node_name(value: String) -> String:
	var out := value
	for token in [":", "/", "\\", "@"]:
		out = out.replace(token, "_")
	return out


func _count_skip(reason: String) -> void:
	skipped[reason] = skipped.get(reason, 0) + 1
