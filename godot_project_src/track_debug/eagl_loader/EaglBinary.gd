class_name EaglBinary
extends RefCounted

static func u8(data: PackedByteArray, off: int) -> int:
	if off < 0 or off >= data.size():
		return 0
	return data[off]


static func u16(data: PackedByteArray, off: int) -> int:
	if off + 1 >= data.size():
		return 0
	return data[off] | (data[off + 1] << 8)


static func u32(data: PackedByteArray, off: int) -> int:
	if off + 3 >= data.size():
		return 0
	return data[off] | (data[off + 1] << 8) | (data[off + 2] << 16) | (data[off + 3] << 24)


static func s32(data: PackedByteArray, off: int) -> int:
	var value = u32(data, off)
	if value & 0x80000000:
		return value - 0x100000000
	return value


static func u32be(data: PackedByteArray, off: int) -> int:
	if off + 3 >= data.size():
		return 0
	return (data[off] << 24) | (data[off + 1] << 16) | (data[off + 2] << 8) | data[off + 3]


static func f32(data: PackedByteArray, off: int) -> float:
	if off + 3 >= data.size():
		return 0.0
	return data.decode_float(off)


static func bytes_at(data: PackedByteArray, off: int, length: int) -> PackedByteArray:
	if off < 0 or off >= data.size() or length <= 0:
		return PackedByteArray()
	return data.slice(off, min(off + length, data.size()))


static func cstring(data: PackedByteArray, off: int) -> String:
	if off < 0 or off >= data.size():
		return ""
	var end = off
	while end < data.size() and data[end] != 0:
		end += 1
	return data.slice(off, end).get_string_from_ascii()


static func fixed_string(data: PackedByteArray, off: int, length: int) -> String:
	return cstring(bytes_at(data, off, length), 0)


static func is_printable_ascii(data: PackedByteArray) -> bool:
	for value in data:
		if value != 0 and (value < 32 or value >= 127):
			return false
	return true
