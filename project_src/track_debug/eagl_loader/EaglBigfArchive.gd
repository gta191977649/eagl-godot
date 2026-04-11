class_name EaglBigfArchive
extends RefCounted

const EaglBinary = preload("res://track_debug/eagl_loader/EaglBinary.gd")

var path = ""
var entries: Dictionary = {}
var error = ""


func load_file(file_path: String) -> bool:
	path = file_path
	entries.clear()
	var data = FileAccess.get_file_as_bytes(file_path)
	if data.size() < 16 or data.slice(0, 4).get_string_from_ascii() != "BIGF":
		error = "Not a BIGF archive: %s" % file_path
		return false
	var count = EaglBinary.u32be(data, 8)
	var off = 16
	for _index in range(count):
		var entry_off = EaglBinary.u32be(data, off)
		var entry_size = EaglBinary.u32be(data, off + 4)
		off += 8
		var name_end = off
		while name_end < data.size() and data[name_end] != 0:
			name_end += 1
		var name = data.slice(off, name_end).get_string_from_ascii()
		off = name_end + 1
		entries[name] = EaglBinary.bytes_at(data, entry_off, entry_size)
	return true
