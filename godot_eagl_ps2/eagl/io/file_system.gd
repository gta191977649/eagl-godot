class_name EAGLFileSystem
extends RefCounted


static func file_exists(path: String) -> bool:
	return FileAccess.file_exists(path)


static func dir_exists(path: String) -> bool:
	return DirAccess.dir_exists_absolute(path)


static func read_all_bytes(path: String) -> PackedByteArray:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("Could not read file: %s" % path)
		return PackedByteArray()
	return file.get_buffer(file.get_length())


static func first_existing(paths: Array[String]) -> String:
	for path in paths:
		if FileAccess.file_exists(path):
			return path
	return ""
