class_name EaglFshDecoder
extends RefCounted

const EaglBinary = preload("res://track_debug/eagl_loader/EaglBinary.gd")


static func decode_rgba(fmt: int, width: int, height: int, pixels: PackedByteArray, palettes: Dictionary) -> PackedByteArray:
	match fmt:
		0x60:
			return _decode_dxt1(width, height, pixels)
		0x61:
			return _decode_dxt3(width, height, pixels)
		0x62:
			return _decode_dxt5(width, height, pixels)
		0x6d:
			return _decode_4444(width, height, pixels)
		0x78:
			return _decode_565(width, height, pixels)
		0x7b:
			return _decode_pal8(width, height, pixels, palettes)
		0x7d:
			return _decode_argb8888(width, height, pixels)
		0x7e:
			return _decode_5551(width, height, pixels)
		0x7f:
			return _decode_bgr888(width, height, pixels)
		_:
			return PackedByteArray()


static func _decode_dxt1(width: int, height: int, data: PackedByteArray) -> PackedByteArray:
	var out = _alloc(width, height)
	var cursor = 0
	for by in range((height + 3) / 4):
		for bx in range((width + 3) / 4):
			var c0 = EaglBinary.u16(data, cursor)
			var c1 = EaglBinary.u16(data, cursor + 2)
			var bits = EaglBinary.u32(data, cursor + 4)
			cursor += 8
			var colors = _dxt1_palette(c0, c1)
			for py in range(4):
				for px in range(4):
					var x: int = bx * 4 + px
					var y: int = by * 4 + py
					if x < width and y < height:
						_write_color(out, width, x, y, colors[(bits >> (2 * (py * 4 + px))) & 3])
	return out


static func _decode_dxt3(width: int, height: int, data: PackedByteArray) -> PackedByteArray:
	var out = _alloc(width, height)
	var cursor = 0
	for by in range((height + 3) / 4):
		for bx in range((width + 3) / 4):
			var alpha = _read_u64_low(data, cursor)
			cursor += 8
			var c0 = EaglBinary.u16(data, cursor)
			var c1 = EaglBinary.u16(data, cursor + 2)
			var bits = EaglBinary.u32(data, cursor + 4)
			cursor += 8
			var colors = _dxt_color_palette(c0, c1)
			for py in range(4):
				for px in range(4):
					var p = py * 4 + px
					var x: int = bx * 4 + px
					var y: int = by * 4 + py
					if x < width and y < height:
						var color: Array = colors[(bits >> (2 * p)) & 3].duplicate()
						color[3] = ((alpha >> (4 * p)) & 0xf) * 17
						_write_color(out, width, x, y, color)
	return out


static func _decode_dxt5(width: int, height: int, data: PackedByteArray) -> PackedByteArray:
	var out = _alloc(width, height)
	var cursor = 0
	for by in range((height + 3) / 4):
		for bx in range((width + 3) / 4):
			var a0 = EaglBinary.u8(data, cursor)
			var a1 = EaglBinary.u8(data, cursor + 1)
			var alpha_bits = _read_u48(data, cursor + 2)
			cursor += 8
			var c0 = EaglBinary.u16(data, cursor)
			var c1 = EaglBinary.u16(data, cursor + 2)
			var bits = EaglBinary.u32(data, cursor + 4)
			cursor += 8
			var alpha_palette = _dxt5_alpha_palette(a0, a1)
			var colors = _dxt_color_palette(c0, c1)
			for py in range(4):
				for px in range(4):
					var p = py * 4 + px
					var x: int = bx * 4 + px
					var y: int = by * 4 + py
					if x < width and y < height:
						var color: Array = colors[(bits >> (2 * p)) & 3].duplicate()
						color[3] = alpha_palette[(alpha_bits >> (3 * p)) & 7]
						_write_color(out, width, x, y, color)
	return out


static func _decode_argb8888(width: int, height: int, data: PackedByteArray) -> PackedByteArray:
	var out = _alloc(width, height)
	for i in range(min(width * height, int(data.size() / 4))):
		var src = i * 4
		var dst = i * 4
		out[dst] = EaglBinary.u8(data, src + 2)
		out[dst + 1] = EaglBinary.u8(data, src + 1)
		out[dst + 2] = EaglBinary.u8(data, src)
		out[dst + 3] = EaglBinary.u8(data, src + 3)
	return out


static func _decode_bgr888(width: int, height: int, data: PackedByteArray) -> PackedByteArray:
	var out = _alloc(width, height)
	for i in range(min(width * height, int(data.size() / 3))):
		var src = i * 3
		var dst = i * 4
		out[dst] = EaglBinary.u8(data, src + 2)
		out[dst + 1] = EaglBinary.u8(data, src + 1)
		out[dst + 2] = EaglBinary.u8(data, src)
		out[dst + 3] = 255
	return out


static func _decode_4444(width: int, height: int, data: PackedByteArray) -> PackedByteArray:
	var out = _alloc(width, height)
	for i in range(min(width * height, int(data.size() / 2))):
		var value = EaglBinary.u16(data, i * 2)
		var dst = i * 4
		out[dst] = ((value >> 8) & 0xf) * 17
		out[dst + 1] = ((value >> 4) & 0xf) * 17
		out[dst + 2] = (value & 0xf) * 17
		out[dst + 3] = ((value >> 12) & 0xf) * 17
	return out


static func _decode_5551(width: int, height: int, data: PackedByteArray) -> PackedByteArray:
	var out = _alloc(width, height)
	for i in range(min(width * height, int(data.size() / 2))):
		var value = EaglBinary.u16(data, i * 2)
		var dst = i * 4
		out[dst] = ((value >> 10) & 31) * 255 / 31
		out[dst + 1] = ((value >> 5) & 31) * 255 / 31
		out[dst + 2] = (value & 31) * 255 / 31
		out[dst + 3] = 255 if (value & 0x8000) else 0
	return out


static func _decode_565(width: int, height: int, data: PackedByteArray) -> PackedByteArray:
	var out = _alloc(width, height)
	for i in range(min(width * height, int(data.size() / 2))):
		var color = _rgb565(EaglBinary.u16(data, i * 2))
		_write_color(out, width, i % width, int(i / width), color)
	return out


static func _decode_pal8(width: int, height: int, data: PackedByteArray, palettes: Dictionary) -> PackedByteArray:
	var palette: PackedByteArray = palettes.get(0x2a, PackedByteArray())
	var step = 4
	if palette.is_empty():
		palette = palettes.get(0x24, PackedByteArray())
		step = 3
	if palette.is_empty():
		return PackedByteArray()
	var out = _alloc(width, height)
	for i in range(min(width * height, data.size())):
		var src = data[i] * step
		var dst = i * 4
		out[dst] = EaglBinary.u8(palette, src)
		out[dst + 1] = EaglBinary.u8(palette, src + 1)
		out[dst + 2] = EaglBinary.u8(palette, src + 2)
		out[dst + 3] = EaglBinary.u8(palette, src + 3) if step == 4 else 255
	return out


static func _dxt1_palette(c0: int, c1: int) -> Array:
	var colors = _dxt_color_palette(c0, c1)
	if c0 <= c1:
		colors[2] = _mix(colors[0], colors[1], 1, 1, 2)
		colors[3] = [0, 0, 0, 0]
	return colors


static func _dxt_color_palette(c0: int, c1: int) -> Array:
	var a = _rgb565(c0)
	var b = _rgb565(c1)
	return [a, b, _mix(a, b, 2, 1, 3), _mix(a, b, 1, 2, 3)]


static func _dxt5_alpha_palette(a0: int, a1: int) -> Array:
	var values = [a0, a1]
	if a0 > a1:
		values.append_array([
			(6 * a0 + a1) / 7,
			(5 * a0 + 2 * a1) / 7,
			(4 * a0 + 3 * a1) / 7,
			(3 * a0 + 4 * a1) / 7,
			(2 * a0 + 5 * a1) / 7,
			(a0 + 6 * a1) / 7,
		])
	else:
		values.append_array([
			(4 * a0 + a1) / 5,
			(3 * a0 + 2 * a1) / 5,
			(2 * a0 + 3 * a1) / 5,
			(a0 + 4 * a1) / 5,
			0,
			255,
		])
	return values


static func _rgb565(value: int) -> Array:
	return [((value >> 11) & 31) * 255 / 31, ((value >> 5) & 63) * 255 / 63, (value & 31) * 255 / 31, 255]


static func _mix(a: Array, b: Array, aw: int, bw: int, div: int) -> Array:
	return [(aw * a[0] + bw * b[0]) / div, (aw * a[1] + bw * b[1]) / div, (aw * a[2] + bw * b[2]) / div, 255]


static func _alloc(width: int, height: int) -> PackedByteArray:
	var out = PackedByteArray()
	out.resize(width * height * 4)
	return out


static func _write_color(out: PackedByteArray, width: int, x: int, y: int, color: Array) -> void:
	var dst = (y * width + x) * 4
	out[dst] = int(color[0])
	out[dst + 1] = int(color[1])
	out[dst + 2] = int(color[2])
	out[dst + 3] = int(color[3])


static func _read_u64_low(data: PackedByteArray, off: int) -> int:
	return EaglBinary.u32(data, off) | (EaglBinary.u32(data, off + 4) << 32)


static func _read_u48(data: PackedByteArray, off: int) -> int:
	var value = 0
	for i in range(6):
		value |= EaglBinary.u8(data, off + i) << (8 * i)
	return value
