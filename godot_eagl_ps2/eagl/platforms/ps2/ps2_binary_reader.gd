class_name PS2BinaryReader
extends RefCounted


static func load_bundle_bytes(path: String) -> PackedByteArray:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("Could not open PS2 bundle: %s" % path)
		return PackedByteArray()
	var data := file.get_buffer(file.get_length())
	if starts_with_ascii(data, "COMP"):
		return decompress_lzc(data)
	return data


static func starts_with_ascii(data: PackedByteArray, text: String) -> bool:
	if data.size() < text.length():
		return false
	for i in range(text.length()):
		if data[i] != text.unicode_at(i):
			return false
	return true


static func decompress_lzc(data: PackedByteArray) -> PackedByteArray:
	if data.size() < 16 or not starts_with_ascii(data, "COMP"):
		return data
	var decompressed_size := u32(data, 8)
	var compressed_size := u32(data, 12)
	if compressed_size != 0 and compressed_size != data.size():
		push_warning("COMP header compressed size %d does not match file size %d" % [compressed_size, data.size()])
	return ea_comp_decompress_payload(data.slice(16), decompressed_size)


static func ea_comp_decompress_payload(payload: PackedByteArray, decompressed_size: int) -> PackedByteArray:
	var out := PackedByteArray()
	var src := 0
	var flags := 1
	var payload_size := payload.size()

	while src < payload_size and out.size() < decompressed_size:
		if flags == 1:
			if src + 2 > payload_size:
				push_error("Truncated ea_comp flag word")
				return out
			flags = (payload[src] | (payload[src + 1] << 8)) | 0x10000
			src += 2

		var cycles := 1 if (payload_size - 32) < src else 16
		for _cycle in range(cycles):
			if src >= payload_size or out.size() >= decompressed_size:
				break

			if (flags & 1) != 0:
				if src + 2 > payload_size:
					push_error("Truncated ea_comp back-reference")
					return out
				var control: int = payload[src]
				var distance: int = payload[src + 1] | ((control & 0xF0) << 4)
				src += 2
				if distance == 0 or distance > out.size():
					push_error("Invalid ea_comp back-reference distance %d" % distance)
					return out
				var copy_pos := out.size() - distance
				for _copy_index in range((control & 0x0F) + 3):
					out.append(out[copy_pos])
					copy_pos += 1
					if out.size() >= decompressed_size:
						break
			else:
				out.append(payload[src])
				src += 1

			flags = flags >> 1

	if out.size() != decompressed_size:
		push_error("Decompressed %d bytes, expected %d" % [out.size(), decompressed_size])
	return out


static func align(value: int, boundary: int) -> int:
	return (value + boundary - 1) & ~(boundary - 1)


static func u8(data: PackedByteArray, offset: int) -> int:
	if offset < 0 or offset >= data.size():
		return 0
	return data[offset]


static func s8(data: PackedByteArray, offset: int) -> int:
	var value := u8(data, offset)
	return value - 0x100 if value & 0x80 else value


static func u16(data: PackedByteArray, offset: int) -> int:
	if offset + 1 >= data.size():
		return 0
	return data[offset] | (data[offset + 1] << 8)


static func s16(data: PackedByteArray, offset: int) -> int:
	var value := u16(data, offset)
	return value - 0x10000 if value & 0x8000 else value


static func u32(data: PackedByteArray, offset: int) -> int:
	if offset + 3 >= data.size():
		return 0
	return data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16) | (data[offset + 3] << 24)


static func f32(data: PackedByteArray, offset: int) -> float:
	if offset + 3 >= data.size():
		return 0.0
	return data.decode_float(offset)


static func ascii(data: PackedByteArray, start: int, end: int) -> String:
	if start < 0 or end <= start or start >= data.size():
		return ""
	return data.slice(start, min(end, data.size())).get_string_from_ascii()
