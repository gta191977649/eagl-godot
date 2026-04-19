class_name PS2AssetResolver
extends RefCounted

var config
var root_path := ""
var tracks_dir := ""
var last_error := ""


func _init(_config = null) -> void:
	if _config != null:
		initialize(_config)


func initialize(_config) -> void:
	config = _config
	root_path = String(config.game_root).trim_suffix("/")
	tracks_dir = _resolve_tracks_dir(root_path)


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
	elif prefix == "TRACKB":
		model_candidates.append(tracks_dir.path_join("TRACKB%s.BUN" % numeric_id))
		model_candidates.append(tracks_dir.path_join("TRACKB%s.LZC" % numeric_id))
	else:
		model_candidates.append(tracks_dir.path_join("TRACKB%s.BUN" % numeric_id))
		model_candidates.append(tracks_dir.path_join("TRACKB%s.LZC" % numeric_id))
		model_candidates.append(tracks_dir.path_join("TRACKA%s.BUN" % numeric_id))

	var model_path := ""
	for candidate in model_candidates:
		if FileAccess.file_exists(candidate):
			model_path = candidate
			break
	if model_path == "":
		last_error = "Could not find TRACKA/B%s bundle in %s" % [numeric_id, tracks_dir]
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
