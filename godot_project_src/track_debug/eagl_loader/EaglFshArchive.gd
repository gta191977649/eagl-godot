class_name EaglFshArchive
extends RefCounted

const EaglBinary = preload("res://track_debug/eagl_loader/EaglBinary.gd")
const EaglFshDecoder = preload("res://track_debug/eagl_loader/EaglFshDecoder.gd")

var source = ""
var images: Array[Dictionary] = []
var error = ""


func load_bytes(data: PackedByteArray, source_name: String) -> bool:
	source = source_name
	images.clear()
	if data.size() < 16 or data.slice(0, 4).get_string_from_ascii() != "SHPI":
		error = "Not an FSH archive: %s" % source_name
		return false
	var headers = _read_headers(data)
	for index in range(headers.size()):
		var image = _read_image(data, headers, index)
		if not image.is_empty():
			images.append(image)
	return true


func textures() -> Dictionary:
	var out = {}
	for image in images:
		var rgba = EaglFshDecoder.decode_rgba(image.fmt, image.width, image.height, image.pixels, image.palettes)
		if rgba.is_empty():
			continue
		var img = Image.create_from_data(image.width, image.height, false, Image.FORMAT_RGBA8, rgba)
		out[image.tag.to_lower()] = ImageTexture.create_from_image(img)
	return out


func decoded_images() -> Dictionary:
	var out = {}
	for image in images:
		var rgba = EaglFshDecoder.decode_rgba(image.fmt, image.width, image.height, image.pixels, image.palettes)
		if rgba.is_empty():
			continue
		out[image.tag.to_lower()] = Image.create_from_data(image.width, image.height, false, Image.FORMAT_RGBA8, rgba)
	return out


func _read_headers(data: PackedByteArray) -> Array[Dictionary]:
	var count = EaglBinary.u32(data, 8)
	var out: Array[Dictionary] = []
	var off = 16
	for _index in range(count):
		out.append({
			"tag": EaglBinary.bytes_at(data, off, 4).get_string_from_ascii(),
			"off": EaglBinary.u32(data, off + 4)
		})
		off += 8
	return out


func _read_image(data: PackedByteArray, headers: Array[Dictionary], index: int) -> Dictionary:
	var palettes = {}
	var image_pixels = {}
	var cursor: int = headers[index].off
	while cursor + 4 <= data.size():
		var section_header = EaglBinary.u32(data, cursor)
		var section_id = section_header & 0xff
		var next_off = (section_header >> 8) & 0xffffff
		var size = _section_payload_size(data, headers, index, cursor, next_off)
		var section = _read_pixel_section(data, cursor + 4, size, section_id)
		if section_id in [0x24, 0x2a, 0x3b]:
			palettes[section_id] = section.pixels
		elif image_pixels.is_empty() and not section.is_empty():
			image_pixels = section
		if next_off == 0:
			break
		cursor += next_off
	if image_pixels.is_empty():
		return {}
	image_pixels["tag"] = headers[index].tag
	image_pixels["palettes"] = palettes
	return image_pixels


func _section_payload_size(data: PackedByteArray, headers: Array[Dictionary], index: int, cursor: int, next_off: int) -> int:
	if next_off > 4:
		return next_off - 4
	if next_off == 0:
		var end = headers[index + 1].off if index + 1 < headers.size() else data.size()
		return max(0, end - cursor - 4)
	return 0


func _read_pixel_section(data: PackedByteArray, off: int, size: int, section_id: int) -> Dictionary:
	if size < 12 or section_id in [0x6f, 0x70, 0x69, 0x7c]:
		return {}
	var width = EaglBinary.u16(data, off)
	var height = EaglBinary.u16(data, off + 2)
	var pixels = EaglBinary.bytes_at(data, off + 12, max(0, size - 12))
	return {"fmt": section_id, "width": width, "height": height, "pixels": _top_mip(section_id, width, height, pixels)}


func _top_mip(fmt: int, width: int, height: int, pixels: PackedByteArray) -> PackedByteArray:
	var size = 0
	match fmt:
		0x60:
			size = ((width + 3) / 4) * ((height + 3) / 4) * 8
		0x61:
			size = ((width + 3) / 4) * ((height + 3) / 4) * 16
		0x7b:
			size = width * height
		0x24:
			size = 256 * 3
		0x2a, 0x3b:
			size = 256 * 4
		_:
			size = pixels.size()
	return EaglBinary.bytes_at(pixels, 0, min(size, pixels.size()))
