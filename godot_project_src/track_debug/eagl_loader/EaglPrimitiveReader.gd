class_name EaglPrimitiveReader
extends RefCounted

const EaglBinary = preload("res://track_debug/eagl_loader/EaglBinary.gd")
const EaglShaderLibrary = preload("res://track_debug/eagl_loader/EaglShaderLibrary.gd")


func read_primitive(elf, render_descriptor: int) -> Dictionary:
	if render_descriptor == 0:
		return {}
	var render_method = elf.u32(render_descriptor)
	if render_method == 0:
		return {}
	var shader_name = _shader_name(elf, render_method)
	var fields = EaglShaderLibrary.get_fields(shader_name)
	if fields.is_empty():
		return {"skip": "unsupported_shader", "shader": shader_name}
	var info = _read_render_commands(elf, render_descriptor, render_method)
	if not _has_buffers(info):
		return {"skip": "missing_buffers", "shader": shader_name}
	var vertices = _read_vertices(elf, info.vertex_buffer, info.vertex_count, info.vertex_stride, fields)
	var indices = _read_indices(elf, info.index_buffer, info.index_count, info.index_size, info.mode)
	if vertices.is_empty() or indices.size() < 3:
		return {"skip": "empty_mesh", "shader": shader_name}
	info["shader"] = shader_name
	info["fields"] = fields
	info["vertices"] = vertices
	info["indices"] = indices
	return info


func _shader_name(elf, render_method: int) -> String:
	var name = elf.relocation_name(render_method + 8)
	if name.ends_with("__EAGLMicroCode"):
		return name.substr(0, name.length() - 15)
	return ""


func _read_render_commands(elf, render_descriptor: int, render_method: int) -> Dictionary:
	var render_code = elf.u32(render_method)
	var global_params = render_descriptor + 4
	var command_offset = 0
	var num_commands = 0
	var info = {"vertex_count": 0, "vertex_buffer": 0, "vertex_stride": 0, "index_count": 0, "index_buffer": 0, "index_size": 0, "mode": 5, "textures": {}, "wraps": {}}
	while command_offset < elf.data.size():
		var size = elf.u16(render_code + command_offset)
		var cmd_id = elf.u16(render_code + command_offset + 2)
		if size == 0 or cmd_id == 0:
			break
		_apply_command(elf, info, render_code + command_offset, global_params, cmd_id)
		if num_commands != 0:
			global_params += 8
		num_commands += 1
		command_offset += size * 4
	return info


func _apply_command(elf, info: Dictionary, cmd_off: int, global_params: int, cmd_id: int) -> void:
	if cmd_id in [4, 75] and info.vertex_buffer == 0:
		info.vertex_count = elf.u32(global_params)
		info.vertex_buffer = elf.u32(global_params + 4)
		info.vertex_stride = elf.u32(cmd_off + 8)
	elif cmd_id == 7 and info.index_buffer == 0:
		info.index_count = elf.u32(global_params)
		info.index_buffer = elf.u32(global_params + 4)
		info.index_size = elf.u32(cmd_off + 4)
	elif cmd_id == 33:
		var gp_state = elf.u32(global_params + 4)
		if gp_state != 0:
			info.mode = {1: 0, 2: 1, 3: 3, 4: 4, 5: 5, 6: 6}.get(elf.u32(gp_state), info.mode)
	elif cmd_id in [9, 32]:
		var sampler = elf.u32(cmd_off + 4)
		var texture_info = _resolve_texture(elf, global_params)
		var texture = texture_info.name
		if texture != "" and sampler < 8 and not info.textures.has(sampler):
			info.textures[sampler] = texture
			info.wraps[sampler] = texture_info.wrap


func _has_buffers(info: Dictionary) -> bool:
	return info.vertex_buffer != 0 and info.index_buffer != 0 and info.vertex_count > 0 and info.index_count >= 3


func _read_vertices(elf, buffer: int, count: int, stride: int, fields: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for index in range(count):
		out.append(_read_vertex(elf, buffer + index * stride, fields))
	return out


func _read_vertex(elf, base: int, fields: Array) -> Dictionary:
	var vertex = {"color": Color.WHITE}
	var offset = 0
	for field in fields:
		_read_field(elf, vertex, base + offset, field)
		offset += EaglShaderLibrary.field_size(field.type)
	return vertex


func _read_field(elf, vertex: Dictionary, off: int, field: Dictionary) -> void:
	match field.usage:
		"Position":
			vertex.position = Vector3(elf.f32(off), elf.f32(off + 4), elf.f32(off + 8))
		"Normal":
			vertex.normal = Vector3(elf.f32(off), elf.f32(off + 4), elf.f32(off + 8)).normalized()
		"Color0":
			vertex.color = Color(elf.u8(off + 2) / 255.0, elf.u8(off + 1) / 255.0, elf.u8(off) / 255.0, elf.u8(off + 3) / 255.0)
	if field.usage.begins_with("Texcoord"):
		var channel = field.usage.substr(8).to_int()
		var uv = Vector2(elf.f32(off), elf.f32(off + 4))
		vertex["uv%d" % channel] = uv
		if channel == 0:
			vertex.uv = uv


func _resolve_texture_name(elf, global_params: int) -> String:
	return _resolve_texture(elf, global_params).name


func _resolve_texture(elf, global_params: int) -> Dictionary:
	var tar_ptr = elf.u32(global_params + 4)
	if tar_ptr == 0:
		return {"name": "", "wrap": Vector2i(1, 1)}
	var wrap = Vector2i(elf.u32(tar_ptr + 24), elf.u32(tar_ptr + 28))
	var tag = elf.bytes_at(tar_ptr + 4, 4)
	if tag.size() == 4 and EaglBinary.is_printable_ascii(tag):
		return {"name": tag.get_string_from_ascii().strip_edges(), "wrap": wrap}
	var rel = elf.relocation_name(tar_ptr)
	if rel.begins_with("__EAGL::TAR:::"):
		return {"name": rel.substr(14), "wrap": wrap}
	return {"name": "", "wrap": wrap}


func _read_indices(elf, buffer: int, count: int, size: int, mode: int) -> PackedInt32Array:
	var values = _index_values(elf, buffer, count, size)
	if mode == 4:
		return _tri_list(values)
	if mode == 6:
		return _tri_fan(values)
	return _tri_strip(values)


func _index_values(elf, buffer: int, count: int, size: int) -> Array[int]:
	var out: Array[int] = []
	for i in range(count):
		var off = buffer + i * size
		out.append(elf.u8(off) if size == 1 else (elf.u16(off) if size == 2 else elf.u32(off)))
	return out


func _tri_list(values: Array[int]) -> PackedInt32Array:
	var out = PackedInt32Array()
	for i in range(0, values.size() - 2, 3):
		_append_tri(out, values[i], values[i + 2], values[i + 1])
	return out


func _tri_strip(values: Array[int]) -> PackedInt32Array:
	var out = PackedInt32Array()
	for i in range(values.size() - 2):
		_append_tri(out, values[i], values[i + 2] if i % 2 else values[i + 1], values[i + 1] if i % 2 else values[i + 2])
	return out


func _tri_fan(values: Array[int]) -> PackedInt32Array:
	var out = PackedInt32Array()
	for i in range(values.size() - 2):
		_append_tri(out, values[0], values[i + 2], values[i + 1])
	return out


func _append_tri(out: PackedInt32Array, a: int, b: int, c: int) -> void:
	if a != b and a != c and b != c:
		out.append_array(PackedInt32Array([a, b, c]))
