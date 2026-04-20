class_name PS2AssetResolver
extends RefCounted

var config
var root_path := ""
var tracks_dir := ""
var cars_dir := ""
var last_error := ""


func _init(_config = null) -> void:
	if _config != null:
		initialize(_config)


func initialize(_config) -> void:
	config = _config
	root_path = String(config.game_root).trim_suffix("/")
	tracks_dir = _resolve_tracks_dir(root_path)
	cars_dir = _resolve_cars_dir(root_path)


func resolve_track(track_id: String) -> Dictionary:
	last_error = ""
	if tracks_dir == "":
		last_error = "Could not locate ZZDATA/TRACKS under game root: %s" % root_path
		push_error(last_error)
		return {}

	var normalized := _normalize_track_id(track_id)
	var numeric_id: String = normalized["numeric_id"]
	var prefix: String = normalized["prefix"]
	var model_candidates: Array[String] = []
	if prefix == "TRACKA":
		model_candidates.append(tracks_dir.path_join("TRACKA%s.BUN" % numeric_id))
		model_candidates.append(tracks_dir.path_join("TRACKA%s.LZC" % numeric_id))
		model_candidates.append(tracks_dir.path_join("TRACKB%s.BUN" % numeric_id))
		model_candidates.append(tracks_dir.path_join("TRACKB%s.LZC" % numeric_id))
	elif prefix == "TRACKB":
		model_candidates.append(tracks_dir.path_join("TRACKB%s.BUN" % numeric_id))
		model_candidates.append(tracks_dir.path_join("TRACKB%s.LZC" % numeric_id))
	else:
		model_candidates.append(tracks_dir.path_join("TRACKB%s.BUN" % numeric_id))
		model_candidates.append(tracks_dir.path_join("TRACKB%s.LZC" % numeric_id))
		model_candidates.append(tracks_dir.path_join("TRACKA%s.BUN" % numeric_id))
		model_candidates.append(tracks_dir.path_join("TRACKA%s.LZC" % numeric_id))

	var model_path := ""
	for candidate in model_candidates:
		if _file_has_data(candidate):
			model_path = candidate
			break
	if model_path == "":
		last_error = "Could not find non-empty TRACKA/B%s bundle in %s" % [numeric_id, tracks_dir]
		push_error(last_error)
		return {}

	return {
		"track_id": numeric_id,
		"source_id": track_id,
		"model": model_path,
		"tracks_dir": tracks_dir,
		"texture_track": tracks_dir.path_join("TEX%sTRACK.BIN" % numeric_id),
		"texture_location": tracks_dir.path_join("TEX%sLOCATION.BIN" % numeric_id),
	}


func resolve_car(car_id: String) -> Dictionary:
	last_error = ""
	if cars_dir == "":
		last_error = "Could not locate ZZDATA/CARS under game root: %s" % root_path
		push_error(last_error)
		return {}

	var normalized := _normalize_car_id(car_id)
	var car_dir := _find_car_dir(normalized)
	if car_dir == "":
		last_error = "Could not find car directory for %s in %s" % [normalized, cars_dir]
		push_error(last_error)
		return {}

	var geometry := car_dir.path_join("GEOMETRY.BIN")
	if not _file_has_data(geometry):
		geometry = car_dir.path_join("GEOMETRY.LZC")
	if not _file_has_data(geometry):
		last_error = "Could not find non-empty GEOMETRY.BIN/LZC for %s in %s" % [normalized, car_dir]
		push_error(last_error)
		return {}

	var dashboard := ""
	for candidate in [car_dir.path_join("DASHGEOM.BIN"), car_dir.path_join("DASHGEOM.LZC")]:
		if _file_has_data(candidate):
			dashboard = candidate
			break

	return {
		"car_id": car_dir.get_file().to_upper(),
		"source_id": car_id,
		"geometry": geometry,
		"dashboard": dashboard,
		"cars_dir": cars_dir,
		"globalb": _resolve_global_file("GLOBALB"),
		"texture_car": cars_dir.path_join("TEXTURES.BIN"),
	}


func _resolve_tracks_dir(root: String) -> String:
	var candidates := [
		root.path_join("ZZDATA").path_join("TRACKS"),
		root.path_join("TRACKS"),
		root,
	]
	for candidate in candidates:
		if DirAccess.dir_exists_absolute(candidate):
			if candidate.get_file().to_upper() == "TRACKS":
				return candidate
			if DirAccess.dir_exists_absolute(candidate.path_join("TRACKS")):
				return candidate.path_join("TRACKS")
	return ""


func _resolve_cars_dir(root: String) -> String:
	var candidates := [
		root.path_join("ZZDATA").path_join("CARS"),
		root.path_join("CARS"),
		root,
	]
	for candidate in candidates:
		if DirAccess.dir_exists_absolute(candidate):
			if candidate.get_file().to_upper() == "CARS":
				return candidate
			if DirAccess.dir_exists_absolute(candidate.path_join("CARS")):
				return candidate.path_join("CARS")
	return ""


func _resolve_global_file(base_name: String) -> String:
	var candidates := [
		root_path.path_join("ZZDATA").path_join("GLOBAL"),
		root_path.path_join("GLOBAL"),
		root_path,
	]
	for dir_path in candidates:
		if not DirAccess.dir_exists_absolute(dir_path):
			continue
		for extension in ["BUN", "LZC"]:
			var path: String = dir_path.path_join("%s.%s" % [base_name, extension])
			if _file_has_data(path):
				return path
	return ""


func _file_has_data(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	return file.get_length() > 0


func _normalize_track_id(track_id: String) -> Dictionary:
	var value := track_id.strip_edges().to_upper()
	var prefix := ""
	if value.begins_with("TRACKA"):
		prefix = "TRACKA"
		value = value.substr(6)
	elif value.begins_with("TRACKB"):
		prefix = "TRACKB"
		value = value.substr(6)
	elif value.begins_with("A") and value.length() >= 3:
		prefix = "TRACKA"
		value = value.substr(1)
	elif value.begins_with("B") and value.length() >= 3:
		prefix = "TRACKB"
		value = value.substr(1)

	var digits := ""
	for i in range(value.length()):
		var ch := value.substr(i, 1)
		if ch >= "0" and ch <= "9":
			digits += ch
	if digits == "":
		digits = "61"
	if digits.length() == 1:
		digits = "0%s" % digits
	elif digits.length() > 2:
		digits = digits.substr(digits.length() - 2)
	return {"numeric_id": digits, "prefix": prefix}


func _normalize_car_id(car_id: String) -> String:
	var value := car_id.strip_edges().to_upper()
	value = value.replace("\\", "/")
	if value.contains("/"):
		value = value.get_file()
	return value


func _find_car_dir(car_id: String) -> String:
	var direct := cars_dir.path_join(car_id)
	if DirAccess.dir_exists_absolute(direct):
		return direct
	var dir := DirAccess.open(cars_dir)
	if dir == null:
		return ""
	dir.list_dir_begin()
	while true:
		var entry := dir.get_next()
		if entry == "":
			break
		if dir.current_is_dir() and not entry.begins_with(".") and entry.to_upper() == car_id:
			dir.list_dir_end()
			return cars_dir.path_join(entry)
	dir.list_dir_end()
	return ""
