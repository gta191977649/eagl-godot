class_name EaglTextureBank
extends RefCounted

const EaglBigfArchive = preload("res://track_debug/eagl_loader/EaglBigfArchive.gd")
const EaglFshArchive = preload("res://track_debug/eagl_loader/EaglFshArchive.gd")

var textures: Dictionary = {}
var images: Dictionary = {}
var decoded_images = 0
var skipped_images = 0
var errors: Array[String] = []


func reset() -> void:
	textures.clear()
	images.clear()
	decoded_images = 0
	skipped_images = 0
	errors.clear()


func load_for_route(track_dir: String, level_dir: String) -> void:
	load_base(track_dir)
	_load_fsh_file(level_dir.path_join("level.fsh"), "level.fsh", true)


func load_base(track_dir: String) -> void:
	reset()
	_load_persist(track_dir.path_join("persist.viv"))
	_load_fsh_dir(track_dir)
	_load_comp_vivs(track_dir)


func get_texture(name: String) -> Texture2D:
	if name == "":
		return null
	return textures.get(name.to_lower())


func sample_alpha(name: String, uv: Vector2) -> int:
	var image: Image = images.get(name.to_lower())
	if image == null:
		return 255
	var u = fposmod(uv.x, 1.0)
	var v = fposmod(uv.y, 1.0)
	var x = clampi(int(u * float(image.get_width() - 1) + 0.5), 0, image.get_width() - 1)
	var y = clampi(int(v * float(image.get_height() - 1) + 0.5), 0, image.get_height() - 1)
	return int(round(image.get_pixel(x, y).a * 255.0))


func _load_persist(path: String) -> void:
	if not FileAccess.file_exists(path):
		return
	var archive = EaglBigfArchive.new()
	if not archive.load_file(path):
		errors.append(archive.error)
		return
	var preferred = ["track.fsh", "sky.fsh", "flares.fsh", "sun.fsh", "lightglows.fsh", "particle.fsh"]
	for name in preferred:
		if archive.entries.has(name):
			_load_fsh_bytes(archive.entries[name], "persist.viv:%s" % name)
	var entry_names = archive.entries.keys()
	entry_names.sort()
	for name in entry_names:
		if name.ends_with(".fsh") and not preferred.has(name):
			_load_fsh_bytes(archive.entries[name], "persist.viv:%s" % name)


func _load_fsh_dir(path: String) -> void:
	for file_name in _files(path):
		if file_name.ends_with(".fsh"):
			_load_fsh_file(path.path_join(file_name), file_name)


func _load_comp_vivs(path: String) -> void:
	for file_name in _files(path):
		if not (file_name.begins_with("comp") and file_name.ends_with(".viv")):
			continue
		var archive = EaglBigfArchive.new()
		if not archive.load_file(path.path_join(file_name)):
			errors.append(archive.error)
			continue
		var entry_names = archive.entries.keys()
		entry_names.sort()
		for entry_name in entry_names:
			if entry_name.ends_with(".fsh"):
				_load_fsh_bytes(archive.entries[entry_name], "%s:%s" % [file_name, entry_name])


func _load_fsh_file(path: String, source: String, overwrite: bool = false) -> void:
	if FileAccess.file_exists(path):
		_load_fsh_bytes(FileAccess.get_file_as_bytes(path), source, overwrite)


func _load_fsh_bytes(data: PackedByteArray, source: String, overwrite: bool = false) -> void:
	var archive = EaglFshArchive.new()
	if not archive.load_bytes(data, source):
		errors.append(archive.error)
		return
	var decoded = archive.textures()
	var decoded_image_data = archive.decoded_images()
	for key in decoded.keys():
		if overwrite or not textures.has(key):
			textures[key] = decoded[key]
			images[key] = decoded_image_data[key]
	decoded_images += decoded.size()
	skipped_images += max(0, archive.images.size() - decoded.size())


func _files(path: String) -> Array[String]:
	var dir = DirAccess.open(path)
	if dir == null:
		return []
	var out: Array[String] = []
	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if not dir.current_is_dir():
			out.append(file_name)
		file_name = dir.get_next()
	out.sort()
	return out
