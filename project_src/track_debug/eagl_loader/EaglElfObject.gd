class_name EaglElfObject
extends RefCounted

const EaglBinary = preload("res://track_debug/eagl_loader/EaglBinary.gd")

var path = ""
var file_bytes = PackedByteArray()
var data = PackedByteArray()
var data_index = -1
var symbols: Array[Dictionary] = []
var relocations: Dictionary = {}
var error = ""


func load_file(file_path: String) -> bool:
	path = file_path
	file_bytes = FileAccess.get_file_as_bytes(file_path)
	if file_bytes.size() < 52 or file_bytes.slice(0, 4) != PackedByteArray([0x7f, 0x45, 0x4c, 0x46]):
		error = "Not an ELF object: %s" % file_path
		return false
	return _parse()


func u8(off: int) -> int:
	return EaglBinary.u8(data, off)


func u16(off: int) -> int:
	return EaglBinary.u16(data, off)


func u32(off: int) -> int:
	return EaglBinary.u32(data, off)


func f32(off: int) -> float:
	return EaglBinary.f32(data, off)


func bytes_at(off: int, length: int) -> PackedByteArray:
	return EaglBinary.bytes_at(data, off, length)


func cstring(off: int) -> String:
	return EaglBinary.cstring(data, off)


func data_symbol(prefix: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for sym in symbols:
		if sym.name.begins_with(prefix) and (sym.info & 0xf) != 0 and sym.shndx == data_index:
			out.append(sym)
	return out


func relocation_name(off: int) -> String:
	var sym = relocations.get(off)
	return sym.name if sym != null else ""


func _parse() -> bool:
	var sections = _read_sections()
	var symtab = _find_section(sections, 2)
	var relsec = _find_section(sections, 9)
	_select_data_section(sections)
	if data.is_empty() or symtab.is_empty():
		error = "Missing required ELF sections: %s" % path
		return false
	_read_symbols(sections, symtab)
	if not relsec.is_empty():
		_read_relocations(relsec)
	return true


func _read_sections() -> Array[Dictionary]:
	var shoff = EaglBinary.u32(file_bytes, 0x20)
	var shentsize = EaglBinary.u16(file_bytes, 0x2e)
	var shnum = EaglBinary.u16(file_bytes, 0x30)
	var sections: Array[Dictionary] = []
	for index in range(shnum):
		var off = shoff + index * shentsize
		sections.append({
			"type": EaglBinary.u32(file_bytes, off + 4),
			"offset": EaglBinary.u32(file_bytes, off + 16),
			"size": EaglBinary.u32(file_bytes, off + 20),
			"link": EaglBinary.u32(file_bytes, off + 24)
		})
	return sections


func _select_data_section(sections: Array[Dictionary]) -> void:
	for index in range(sections.size()):
		var sec = sections[index]
		if sec.size > 0 and sec.type == 1:
			data = EaglBinary.bytes_at(file_bytes, sec.offset, sec.size)
			data_index = index
			return


func _find_section(sections: Array[Dictionary], type_id: int) -> Dictionary:
	for sec in sections:
		if sec.size > 0 and sec.type == type_id:
			return sec
	return {}


func _read_symbols(sections: Array[Dictionary], symtab: Dictionary) -> void:
	var strings_sec: Dictionary = sections[symtab.link]
	var strings = EaglBinary.bytes_at(file_bytes, strings_sec.offset, strings_sec.size)
	for index in range(symtab.size / 16):
		var off: int = symtab.offset + index * 16
		var st_name = EaglBinary.u32(file_bytes, off)
		symbols.append({
			"name": EaglBinary.cstring(strings, st_name),
			"value": EaglBinary.u32(file_bytes, off + 4),
			"size": EaglBinary.u32(file_bytes, off + 8),
			"info": EaglBinary.u8(file_bytes, off + 12),
			"shndx": EaglBinary.u16(file_bytes, off + 14)
		})


func _read_relocations(relsec: Dictionary) -> void:
	for index in range(relsec.size / 8):
		var off: int = relsec.offset + index * 8
		var r_offset = EaglBinary.u32(file_bytes, off)
		var sym_id = EaglBinary.u32(file_bytes, off + 4) >> 8
		if sym_id < symbols.size():
			relocations[r_offset] = symbols[sym_id]
