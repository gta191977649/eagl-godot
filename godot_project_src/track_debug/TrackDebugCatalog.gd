class_name TrackDebugCatalog
extends RefCounted


static func track_names(tracks_root: String) -> Array[String]:
	var dir = DirAccess.open(tracks_root)
	var out: Array[String] = []
	if dir == null:
		return out
	dir.list_dir_begin()
	var name = dir.get_next()
	while name != "":
		if dir.current_is_dir() and not name.begins_with("."):
			out.append(name)
		name = dir.get_next()
	out.sort()
	return out


static func level_indices(tracks_root: String, track_name: String) -> Array[int]:
	var dir = DirAccess.open(tracks_root.path_join(track_name))
	var out: Array[int] = []
	if dir == null:
		return out
	dir.list_dir_begin()
	var entry = dir.get_next()
	while entry != "":
		var suffix = entry.substr(5)
		if dir.current_is_dir() and entry.begins_with("level") and suffix.is_valid_int():
			var level_dir = tracks_root.path_join(track_name).path_join(entry)
			if FileAccess.file_exists(level_dir.path_join("drvpath.ini")) and FileAccess.file_exists(level_dir.path_join("level.dat")):
				out.append(suffix.to_int())
		entry = dir.get_next()
	out.sort()
	return out
