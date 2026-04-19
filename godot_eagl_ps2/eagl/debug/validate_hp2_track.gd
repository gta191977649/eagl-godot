extends SceneTree

const ConfigScript := preload("res://eagl/core/eagl_config.gd")
const PlatformScript := preload("res://eagl/platforms/ps2/ps2_platform.gd")

const DEFAULT_GAME_ROOT := "/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA"
const TRACK_ID := "64"
const EXPECTED_TEXTURE_MD5 := {
	"SH_CLIFF2SANDBLEND": "81b346071cbcf49221603b93318195be",
	"SHLD_G": "208cb421b957461de7c9387da7ebfb0c",
	"D_TERRAINGRASS": "ee55635c439ece2e294e837139c98a1f",
	"SH_BEACHSAND2OCEAN": "e3439cc36397cca6b8c9eeda8eb602aa",
	"ROAD06": "147ddfbae4580ebc74c3bec7f2d7a61b",
}


func _init() -> void:
	var failed := false
	var game_root := OS.get_environment("EAGL_HP2_GAME_ROOT")
	if game_root == "":
		game_root = DEFAULT_GAME_ROOT

	var config = ConfigScript.new()
	config.target_platform = "EAGL_HOTPUSUIT2_PS2"
	config.game_root = game_root
	config.options = {
		"place_scenery_instances": true,
		"expand_scenery_instances": false,
	}

	var platform = PlatformScript.new()
	platform.initialize(config)
	var asset = platform.load_track_asset(TRACK_ID)
	if asset == null:
		push_error("VALIDATION failed to load TRACKB%s from %s" % [TRACK_ID, game_root])
		quit(1)
		return

	for texture_name in EXPECTED_TEXTURE_MD5.keys():
		var result := _validate_texture(asset.texture_bank, texture_name, EXPECTED_TEXTURE_MD5[texture_name])
		failed = failed or not result

	var scene := platform.load_track(TRACK_ID)
	var skipped: Dictionary = scene.get_meta("eagl_skipped", {})
	var env_count := int(scene.get_meta("eagl_environment_object_count", 0))
	if env_count != 2 or int(skipped.get("non_visible_environment_source", 0)) < 2:
		failed = true
		push_error("VALIDATION expected only SKYDOME/WATER environment rendering, got env=%d skipped=%s" % [env_count, skipped])
	else:
		print("VALIDATION scene env=%d skipped=%s textured=%s fallback=%s" % [
			env_count,
			skipped,
			scene.get_meta("eagl_textured_surface_count", 0),
			scene.get_meta("eagl_fallback_surface_count", 0),
		])

	quit(1 if failed else 0)


func _validate_texture(texture_bank, texture_name: String, expected_md5: String) -> bool:
	for texture_hash in texture_bank.texture_info.keys():
		var info: Dictionary = texture_bank.texture_info[texture_hash]
		if info.get("name", "") != texture_name:
			continue
		var texture: ImageTexture = texture_bank.get_texture(texture_hash)
		var image := texture.get_image()
		var actual_md5 := _md5_text(_base_level_rgba(image))
		var ok: bool = actual_md5 == expected_md5
		var alpha_mode: String = info.get("alpha_mode", "")
		if texture_name == "SHLD_G" and alpha_mode != "MASK":
			ok = false
		if int(info.get("is_any_semitransparency", 0)) != 0 and texture_name != "WATER":
			ok = false
		if ok:
			print("VALIDATION texture %s md5=%s mode=%s semitrans=%s alpha_bits=%s" % [
				texture_name,
				actual_md5,
				alpha_mode,
				info.get("is_any_semitransparency", 0),
				info.get("alpha_bits", 0),
			])
		else:
			push_error("VALIDATION texture %s expected_md5=%s actual_md5=%s mode=%s semitrans=%s alpha_bits=%s" % [
				texture_name,
				expected_md5,
				actual_md5,
				alpha_mode,
				info.get("is_any_semitransparency", 0),
				info.get("alpha_bits", 0),
			])
		return ok

	push_error("VALIDATION missing texture %s" % texture_name)
	return false


func _md5_text(data: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_MD5)
	context.update(data)
	return context.finish().hex_encode()


func _base_level_rgba(image: Image) -> PackedByteArray:
	var data := image.get_data()
	var base_size := image.get_width() * image.get_height() * 4
	return data.slice(0, mini(base_size, data.size()))
