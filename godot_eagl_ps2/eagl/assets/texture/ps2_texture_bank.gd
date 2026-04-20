class_name PS2TextureBank
extends RefCounted

const Binary := preload("res://eagl/platforms/ps2/ps2_binary_reader.gd")

var textures: Dictionary = {}
var texture_info: Dictionary = {}
var decoded_count := 0
var skipped_count := 0
var errors: Array[String] = []


func load_for_track(files: Dictionary) -> void:
	clear()
	for key in ["texture_location", "texture_track"]:
		var path: String = files.get(key, "")
		if path != "" and FileAccess.file_exists(path):
			_read_ps2_tpk(path)


func load_paths(paths: Array[String]) -> void:
	clear()
	for path in paths:
		if path != "" and FileAccess.file_exists(path):
			_read_ps2_tpk(path)


func load_for_car(files: Dictionary) -> void:
	var paths: Array[String] = []
	var global_path: String = files.get("globalb", "")
	if global_path != "":
		paths.append(global_path)
	var texture_path: String = files.get("texture_car", "")
	if texture_path != "":
		paths.append(texture_path)
	load_paths(paths)


func clear() -> void:
	textures.clear()
	texture_info.clear()
	decoded_count = 0
	skipped_count = 0
	errors.clear()


func has_texture(texture_hash: int) -> bool:
	return textures.has(texture_hash)


func get_texture(texture_hash: int):
	return textures.get(texture_hash)


func get_info(texture_hash: int) -> Dictionary:
	return texture_info.get(texture_hash, {})


func _read_ps2_tpk(path: String) -> void:
	var data := _read_file(path)
	if data.is_empty():
		_add_error("empty texture file %s" % path)
		return

	var chunks := _parse_chunks(data)
	var flat := _walk_chunks(chunks)
	var entry_chunk := _first_chunk_with_id(flat, 0x30300003)
	var data_chunk := _first_chunk_with_id(flat, 0x30300004)
	if entry_chunk.is_empty() or data_chunk.is_empty():
		_add_error("missing texture entry/data chunks in %s" % path)
		return

	var entries := _payload(data, entry_chunk)
	if entries.size() % 0xA4 != 0:
		_add_error("unexpected texture entry table size %d in %s" % [entries.size(), path])
		return

	var data_base := Binary.align(int(data_chunk["data_offset"]), 0x80)
	var count := int(entries.size() / 0xA4)
	for index in range(count):
		var entry := entries.slice(index * 0xA4, index * 0xA4 + 0xA4)
		_decode_entry(path, data, data_base, entry)


func _decode_entry(path: String, data: PackedByteArray, data_base: int, entry: PackedByteArray) -> void:
	var name := _entry_name(entry)
	var texture_hash := Binary.u32(entry, 0x20)
	var width := Binary.u16(entry, 0x24)
	var height := Binary.u16(entry, 0x26)
	var bit_depth := Binary.u8(entry, 0x28)
	var data_offset := Binary.u32(entry, 0x30)
	var palette_offset := Binary.u32(entry, 0x34)
	var data_size := Binary.u32(entry, 0x38)
	var palette_size := Binary.u32(entry, 0x3C)
	var shift_width := Binary.u8(entry, 0x48)
	var shift_height := Binary.u8(entry, 0x49)
	var pixel_storage_mode := Binary.u8(entry, 0x4A)
	var clut_pixel_storage_mode := Binary.u8(entry, 0x4B)
	var texture_fx := Binary.u8(entry, 0x4E)
	var semitransparency := Binary.u8(entry, 0x4F)
	var is_swizzled := Binary.u8(entry, 0x55) != 0
	var alpha_bits := Binary.u8(entry, 0x76)
	var alpha_fix := Binary.u8(entry, 0x77)

	if name == "" or texture_hash == 0 or width <= 0 or height <= 0 or data_size <= 0 or palette_size <= 0:
		skipped_count += 1
		return

	var image_start := data_base + data_offset
	var palette_start := data_base + palette_offset
	if image_start + data_size > data.size() or palette_start + palette_size > data.size():
		skipped_count += 1
		_add_error("texture %s points outside %s" % [name, path])
		return

	var indexed := data.slice(image_start, image_start + data_size)
	var palette := data.slice(palette_start, palette_start + palette_size)
	var rgba := _decode_indexed_texture(
		width,
		height,
		indexed,
		palette,
		bit_depth,
		shift_width,
		shift_height,
		pixel_storage_mode,
		is_swizzled
	)
	if rgba.is_empty():
		skipped_count += 1
		_add_error("could not decode texture %s in %s" % [name, path])
		return

	var image := Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, rgba)
	image.generate_mipmaps()
	var texture := ImageTexture.create_from_image(image)
	var alpha_props := _material_alpha_properties_for_rgba(rgba, semitransparency)
	textures[texture_hash] = texture
	texture_info[texture_hash] = {
		"name": name,
		"hash": texture_hash,
		"width": width,
		"height": height,
		"source_path": path,
		"has_alpha": alpha_props.get("mode", "") != "",
		"alpha_mode": alpha_props.get("mode", ""),
		"alpha_cutoff": alpha_props.get("cutoff", 0.0),
		"bit_depth": bit_depth,
		"shift_width": shift_width,
		"shift_height": shift_height,
		"pixel_storage_mode": pixel_storage_mode,
		"clut_pixel_storage_mode": clut_pixel_storage_mode,
		"is_swizzled": is_swizzled,
		"texture_fx": texture_fx,
		"alpha_bits": alpha_bits,
		"alpha_fix": alpha_fix,
		"is_any_semitransparency": semitransparency,
	}
	decoded_count += 1


func _decode_indexed_texture(
	width: int,
	height: int,
	image: PackedByteArray,
	palette: PackedByteArray,
	bit_depth: int,
	shift_width: int,
	shift_height: int,
	pixel_storage_mode: int,
	is_swizzled: bool
) -> PackedByteArray:
	var depth := _indexed_bit_depth(bit_depth, pixel_storage_mode, palette.size())
	if depth != 4 and depth != 8:
		return PackedByteArray()

	var color_count := int(palette.size() / 4)
	if color_count <= 0:
		return PackedByteArray()
	var colors := _decode_palette(palette, _psm_type_index(pixel_storage_mode) == 3)

	var buffer_width := 1 << shift_width
	var buffer_height := 1 << shift_height
	if width <= 0 or height <= 0 or buffer_width <= 0 or buffer_height <= 0:
		return PackedByteArray()

	var words := _u32_words(image)
	if is_swizzled:
		var scale := int(32 / depth)
		var scale_mask := scale - 1
		var scale_x := (_adjust_with_mask(scale_mask, 1, 2, 1) | _adjust_with_mask(scale_mask, 1, 0, 0)) + 1
		var scale_y := (_adjust_with_mask(scale_mask, 1, 3, 1) | _adjust_with_mask(scale_mask, 1, 1, 0)) + 1
		words = _legacy_ps2_rw_buffer(words, "write", 0, 32, int(width / scale_y), int(height / scale_x))
		words = _legacy_ps2_rw_buffer(words, "read", pixel_storage_mode, depth, width, height)

	var indices: Array[int] = []
	var index_mask := (1 << depth) - 1
	for word in words:
		for shift in range(0, 32, depth):
			indices.append((int(word) >> shift) & index_mask)

	if is_swizzled:
		var cropped_indices: Array[int] = []
		for y in range(height):
			var row := y * buffer_width
			for x in range(width):
				var source := row + x
				cropped_indices.append(indices[source] if source < indices.size() else 0)
		indices = cropped_indices

	var final_indices: Array[int] = []
	for y in range(height - 1, -1, -1):
		var row := y * width
		for x in range(width):
			var source := row + x
			final_indices.append(indices[source] if source < indices.size() else 0)

	var rgba := PackedByteArray()
	for i in range(mini(width * height, final_indices.size())):
		var color: PackedByteArray = colors[int(final_indices[i]) % color_count]
		rgba.append_array(color)
	return rgba


func _indexed_bit_depth(bit_depth: int, pixel_storage_mode: int, palette_size: int) -> int:
	var psm_index := _psm_type_index(pixel_storage_mode)
	if psm_index > 0:
		return 32 >> maxi(psm_index - 1, 0)
	if bit_depth == 4 or bit_depth == 8:
		return bit_depth
	if palette_size == 0x40:
		return 4
	if palette_size == 0x80 or palette_size == 0x400:
		return 8
	return 0


func _psm_type_index(pixel_storage_mode: int) -> int:
	return pixel_storage_mode & 0x07


func _u32_words(data: PackedByteArray) -> Array[int]:
	var words: Array[int] = []
	for offset in range(0, data.size(), 4):
		var value := 0
		for byte_index in range(4):
			if offset + byte_index < data.size():
				value |= int(data[offset + byte_index]) << (byte_index * 8)
		words.append(value)
	return words


func _legacy_ps2_rw_buffer(
	image_data: Array[int],
	mode: String,
	pixel_storage_mode: int,
	bit_depth: int,
	width: int,
	height: int
) -> Array[int]:
	var scale := int(32 / bit_depth)
	var scale_mask := scale - 1
	var scale_x := (_adjust_with_mask(scale_mask, 1, 2, 1) | _adjust_with_mask(scale_mask, 1, 0, 0)) + 1
	var scale_y := (_adjust_with_mask(scale_mask, 1, 3, 1) | _adjust_with_mask(scale_mask, 1, 1, 0)) + 1

	var physical_width := int(width / scale_y)
	var physical_height := int(height / scale_x)
	var physical_buffer_width := _align_power_of_two_max(physical_width)
	var physical_buffer_height := _align_power_of_two_max(physical_height)
	var buffer_width := _align_power_of_two_max(width)
	var buffer_height := _align_power_of_two_max(height)
	var data: Array[int] = []
	data.resize(physical_buffer_width * physical_buffer_height)
	for i in range(data.size()):
		data[i] = 0

	var type_index := _adjust_with_mask(pixel_storage_mode, 3, 0)
	var type_mode := _adjust_with_mask(pixel_storage_mode, 2, 4)
	var type_flag := _adjust_with_mask(pixel_storage_mode, 1, 3) != 0

	var swap_xy := (((type_mode == 0) or (type_mode == 3)) and type_index == 2) or (type_mode == 1 and type_index == 4)
	var z_buffer := type_mode == 3
	var shifted := ((type_mode == 0) or (type_mode == 3)) and type_index == 2 and type_flag

	var column_width := 8 * scale_x
	var column_height := 2 * scale_y
	var page_height := 1 << (1 if swap_xy else 0)
	var page_width := (page_height ^ 0x03) << 2
	page_height <<= 2
	var texture_buffer_width := int(width / (page_width * column_width))
	if texture_buffer_width <= 0:
		texture_buffer_width = 1

	var input_address := 0
	var from_offset_w := 0

	for index in range(buffer_width * buffer_height):
		var y := int(index / buffer_width)
		var x := index - y * buffer_width

		var page_x := int(x / (page_width * column_width))
		var page_y := int(y / (page_height * 4 * column_height))
		var page := page_x + page_y * texture_buffer_width

		var px := x - page_x * (page_width * column_width)
		var py := y - page_y * (page_height * 4 * column_height)
		var block_x := int(px / column_width)
		var block_y := int(py / (4 * column_height))
		var block := _legacy_ps2_block_address(block_x + block_y * page_width, swap_xy, z_buffer, shifted)

		var bx := px - block_x * column_width
		var by := py - block_y * (4 * column_height)
		var column_y := int(by / column_height)
		var column := column_y

		var cx := bx
		var cy := by - column_y * column_height
		var pixel := _legacy_ps2_swizzle(cx + cy * column_width, bit_depth, true)

		var word := int(pixel / scale)
		var offset := pixel & scale_mask
		if bit_depth < 16:
			word ^= (column & 0x01) << 2
		word = (_rotate_bits(word >> 1, -1, 3) << 1) | (word & 0x01)

		var output_address := (page << 11) | (block << 6) | (column << 4) | word
		var address_a := 0
		var address_b := 0
		var source_shift := 0
		var target_shift := 0
		if mode == "read":
			address_a = input_address
			address_b = output_address
			source_shift = bit_depth * offset
			target_shift = bit_depth * from_offset_w
		else:
			address_a = output_address
			address_b = input_address
			source_shift = bit_depth * from_offset_w
			target_shift = bit_depth * offset

		var input_value := int(image_data[address_b]) if address_b >= 0 and address_b < image_data.size() else 0
		var pixel_data := _adjust_with_mask(input_value, bit_depth, source_shift, target_shift)
		if address_a >= 0 and address_a < data.size():
			data[address_a] = int(data[address_a]) | pixel_data

		from_offset_w += 1
		if from_offset_w > 0 and (from_offset_w & scale_mask) == 0:
			input_address += 1
		from_offset_w &= scale_mask

	return data


func _adjust_with_mask(src: int, mask_width: int, mask_position: int = 0, adjustment: int = 0) -> int:
	return ((src >> mask_position) & ((1 << mask_width) - 1)) << adjustment


func _rotate_bits(value: int, shift: int, width: int) -> int:
	shift = posmod(shift, width)
	var mask := (1 << width) - 1
	value &= mask
	return ((value << shift) | (value >> (width - shift))) & mask


func _align_power_of_two_max(value: int) -> int:
	if value <= 1:
		return 1
	var out := 1
	while out < value:
		out <<= 1
	return out


func _legacy_ps2_swizzle(pixel_index: int, bit_depth: int, mode_flag: bool) -> int:
	if bit_depth == 4:
		return _legacy_ps2_swizzle_psmt4(pixel_index, mode_flag)
	if bit_depth == 8:
		return _legacy_ps2_swizzle_psmt8(pixel_index, mode_flag)
	if bit_depth == 16:
		return _legacy_ps2_swizzle_psmt16(pixel_index, mode_flag)
	return _legacy_ps2_swizzle_psmt32(pixel_index, mode_flag)


func _legacy_ps2_swizzle_psmt4(pixel_index: int, mode_flag: bool) -> int:
	var ax := (pixel_index >> 0) & 0x01
	var ay := (pixel_index >> 1) & 0x01
	var bx := (pixel_index >> 2) & 0x01
	var by := (pixel_index >> 3) & 0x01
	var cx := (pixel_index >> 4) & 0x01
	var cy := (pixel_index >> 5) & 0x01
	var dx := (pixel_index >> 6) & 0x01
	var result := 0
	result ^= dx << 0
	result ^= by << 1
	result ^= cx << 2
	result ^= ax << 3
	result ^= ay << 4
	result ^= bx << 5
	result ^= ax << 7
	result ^= cy << (3 + 3 * int(mode_flag))
	result >>= 0 if mode_flag else 1
	result ^= dx << 5
	return result & 0x7F


func _legacy_ps2_swizzle_psmt8(pixel_index: int, mode_flag: bool) -> int:
	var ax := (pixel_index >> 0) & 0x01
	var ay := (pixel_index >> 1) & 0x01
	var bx := (pixel_index >> 2) & 0x01
	var by := (pixel_index >> 3) & 0x01
	var cx := (pixel_index >> 4) & 0x01
	var cy := (pixel_index >> 5) & 0x01
	var result := 0
	result ^= ax << 0
	result ^= cy << 1
	result = _rotate_bits(result, 5 + int(mode_flag), 7)
	result ^= bx << (0 + 4 * int(mode_flag))
	result ^= cx << (2 + 3 * int(mode_flag))
	result ^= by << 1
	result ^= ax << 2
	result ^= ay << 3
	result ^= cy << 4
	return result & 0x3F


func _legacy_ps2_swizzle_psmt16(pixel_index: int, mode_flag: bool) -> int:
	var ax := (pixel_index >> 0) & 0x01
	var ay := (pixel_index >> 1) & 0x01
	var bx := (pixel_index >> 2) & 0x01
	var by := (pixel_index >> 3) & 0x01
	var cx := (pixel_index >> 4) & 0x01
	var result := 0
	result ^= ay << 0
	result ^= bx << 1
	result ^= by << 2
	result ^= ax << 3
	result = _rotate_bits(result, 2 * int(mode_flag), 4)
	result ^= cx << 4
	return result & 0x1F


func _legacy_ps2_swizzle_psmt32(pixel_index: int, mode_flag: bool) -> int:
	var ax := (pixel_index >> 0) & 0x01
	var ay := (pixel_index >> 1) & 0x01
	var bx := (pixel_index >> 2) & 0x01
	var by := (pixel_index >> 3) & 0x01
	var result := 0
	result ^= ay << 0
	result ^= bx << 1
	result ^= by << 2
	result = _rotate_bits(result, 2 + int(mode_flag), 3)
	result = (result << 1) ^ ax
	return result & 0x0F


func _legacy_ps2_block_address(block_index: int, swap_xy: bool, flip_xy: bool, shifted: bool) -> int:
	var swap := int(swap_xy)
	swap = (swap << 0) ^ (swap << 1)
	block_index = _rotate_bits(block_index, swap, 5)
	var ax := (block_index >> 0) & 0x01
	var ay := (block_index >> 3) & 0x01
	var bx := (block_index >> 1) & 0x01
	var by := (block_index >> 4) & 0x01
	var cx := (block_index >> 2) & 0x01
	var result := 0
	result ^= bx << 0
	result ^= by << 1
	result ^= cx << 2
	result = _rotate_bits(result, int(shifted), 3)
	result ^= (0x03 * int(flip_xy)) << 1
	result = (result << 2) ^ (ax << 0) ^ (ay << 1)
	return result & 0x1F


func _decode_palette(palette: PackedByteArray, swizzle: bool) -> Array[PackedByteArray]:
	var colors: Array[PackedByteArray] = []
	for index in range(int(palette.size() / 4)):
		var source_index := _unswizzle_palette_index(index) if swizzle else index
		var off := source_index * 4
		var color := PackedByteArray()
		color.append(palette[off])
		color.append(palette[off + 1])
		color.append(palette[off + 2])
		color.append(_decode_ps2_alpha(palette[off + 3]))
		colors.append(color)
	return colors


func _decode_ps2_alpha(value: int) -> int:
	var expanded := maxi((value << 1) - ((value ^ 1) & 0x01), 0)
	return expanded if expanded <= 0xFF else value


func _unswizzle_palette_index(index: int) -> int:
	var block := index & ~0x1F
	var pos := index & 0x1F
	if pos >= 8 and pos < 16:
		pos += 8
	elif pos >= 16 and pos < 24:
		pos -= 8
	return block + pos


func _alpha_properties_for_rgba(rgba: PackedByteArray) -> Dictionary:
	var alphas := {}
	for offset in range(3, rgba.size(), 4):
		alphas[int(rgba[offset])] = true
	var non_opaque := {}
	for alpha in alphas.keys():
		if int(alpha) < 250:
			non_opaque[int(alpha)] = true
	if non_opaque.is_empty():
		return {"mode": "", "cutoff": 0.0}
	var only_cutout := true
	var max_cutout := 0
	var min_opaque := 255
	var has_opaque := false
	for alpha in non_opaque.keys():
		if int(alpha) > 2:
			only_cutout = false
		max_cutout = maxi(max_cutout, int(alpha))
	for alpha in alphas.keys():
		if int(alpha) >= 250:
			has_opaque = true
			min_opaque = mini(min_opaque, int(alpha))
	if only_cutout:
		var cutoff := 0.5
		if has_opaque:
			cutoff = (float(max_cutout + min_opaque) / 2.0) / 255.0
		return {"mode": "MASK", "cutoff": cutoff}
	return {"mode": "BLEND", "cutoff": 0.0}


func _material_alpha_properties_for_rgba(rgba: PackedByteArray, is_any_semitransparency: int) -> Dictionary:
	var props := _alpha_properties_for_rgba(rgba)
	if props.get("mode", "") != "BLEND" or is_any_semitransparency != 0:
		return props

	var alphas := {}
	for offset in range(3, rgba.size(), 4):
		alphas[int(rgba[offset])] = true
	if alphas.is_empty():
		return {"mode": "", "cutoff": 0.0}
	for alpha in alphas.keys():
		if int(alpha) != 0 and int(alpha) < 0x80:
			return props
	return {"mode": "MASK", "cutoff": 0.5} if alphas.has(0) else {"mode": "", "cutoff": 0.0}


func _entry_name(entry: PackedByteArray) -> String:
	var end := 0x08
	while end < 0x20 and end < entry.size() and entry[end] != 0:
		end += 1
	return Binary.ascii(entry, 0x08, end).strip_edges()


func _read_file(path: String) -> PackedByteArray:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_add_error("could not open texture file %s" % path)
		return PackedByteArray()
	return file.get_buffer(file.get_length())


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
			_add_error("chunk 0x%08x at 0x%x ends beyond texture region" % [chunk_id, pos])
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
	return chunks


func _walk_chunks(chunks: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for chunk in chunks:
		out.append(chunk)
		out.append_array(_walk_chunks(chunk.get("children", [])))
	return out


func _first_chunk_with_id(chunks: Array[Dictionary], chunk_id: int) -> Dictionary:
	for chunk in chunks:
		if chunk.get("id", 0) == chunk_id:
			return chunk
	return {}


func _payload(data: PackedByteArray, chunk: Dictionary) -> PackedByteArray:
	return data.slice(chunk["data_offset"], chunk["end_offset"])


func _add_error(message: String) -> void:
	errors.append(message)
	push_warning(message)
