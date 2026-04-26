extends SceneTree

const CarLoaderScript := preload("res://eagl/assets/car/car_loader.gd")

const DEFAULT_GAME_ROOT := "/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA"
const DEFAULT_OUT_DIR := "res://tmp/uv_overlays"
const SLOT_COLORS := [
	Color(1.0, 0.08, 0.08, 1.0),
	Color(0.1, 0.95, 0.25, 1.0),
	Color(0.1, 0.45, 1.0, 1.0),
	Color(1.0, 0.92, 0.12, 1.0),
	Color(1.0, 0.25, 0.95, 1.0),
	Color(0.0, 0.95, 0.95, 1.0),
]


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var car_id := _arg_value(args, "--car", "CORVETTE").to_upper()
	var game_root := _arg_value(args, "--root", DEFAULT_GAME_ROOT)
	var out_dir := _arg_value(args, "--out", DEFAULT_OUT_DIR)
	var source_filter := _arg_value(args, "--filter", "all")
	var scale := int(_arg_value(args, "--scale", "4"))
	var max_blocks := int(_arg_value(args, "--max-blocks", "0"))

	var loader = CarLoaderScript.new(game_root)
	var asset = loader.load_asset(car_id)
	if asset == null:
		push_error("Could not load car asset: %s" % car_id)
		quit(1)
		return
	if asset.texture_bank == null:
		push_error("No texture bank loaded for: %s" % car_id)
		quit(1)
		return

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))
	var overlays := _collect_tire_overlays(asset, max_blocks, source_filter)
	var written := []
	for texture_hash in overlays.keys():
		var info: Dictionary = asset.texture_bank.get_info(texture_hash)
		var texture = asset.texture_bank.get_texture(texture_hash)
		if texture == null:
			continue
		var image: Image = texture.get_image()
		if image == null or image.is_empty():
			continue
		image.convert(Image.FORMAT_RGBA8)
		var base_size := image.get_size()
		if scale > 1:
			image.resize(base_size.x * scale, base_size.y * scale, Image.INTERPOLATE_NEAREST)
		_draw_overlay(image, overlays[texture_hash], base_size, scale)
		var texture_name := _safe_file_part(String(info.get("name", "texture")))
		var file_name := "%s_%s_%08x_%s_uv_overlay.png" % [car_id, source_filter, texture_hash, texture_name]
		var path := out_dir.path_join(file_name)
		var err := image.save_png(path)
		if err == OK:
			written.append(ProjectSettings.globalize_path(path))

	for path in written:
		print(path)
	_print_overlay_summary(asset, overlays)
	quit(0)


func _collect_tire_overlays(asset, max_blocks: int, source_filter: String) -> Dictionary:
	var overlays := {}
	var block_counter := 0
	for obj in asset.objects:
		var object_dict: Dictionary = obj
		var object_name := String(object_dict.get("name", ""))
		if not object_name.to_upper().contains("_TIRE_"):
			continue
		var hashes: Array = object_dict.get("texture_hashes", [])
		var blocks: Array = object_dict.get("blocks", [])
		for block_index in range(blocks.size()):
			if max_blocks > 0 and block_counter >= max_blocks:
				return overlays
			var block: Dictionary = blocks[block_index]
			var texture_hash := _texture_hash_for_block(hashes, block)
			var source_hash := _source_texture_hash_for_block(hashes, block)
			if source_filter == "native" and source_hash != texture_hash:
				continue
			if source_filter == "alias" and source_hash == texture_hash:
				continue
			if texture_hash == 0 or asset.texture_bank == null or not asset.texture_bank.has_texture(texture_hash):
				continue
			var run: Dictionary = block.get("run", {})
			var texcoords: Array = run.get("texcoords", [])
			var vertices: Array = run.get("vertices", [])
			if texcoords.size() < vertices.size() or vertices.size() < 3:
				continue
			var uvs := _resolved_uvs(block, vertices.size())
			var indices := _indices_for_block(block, vertices.size())
			if uvs.size() != vertices.size() or indices.size() < 3:
				continue
			if not overlays.has(texture_hash):
				overlays[texture_hash] = []
			overlays[texture_hash].append({
				"object_name": object_name,
				"block_index": block_index,
				"source_hash": source_hash,
				"resolved_hash": texture_hash,
				"resolved_name": block.get("resolved_texture_name", ""),
				"alias": block.get("resolved_texture_alias", ""),
				"uvs": uvs,
				"indices": indices,
				"color": SLOT_COLORS[block_counter % SLOT_COLORS.size()],
			})
			block_counter += 1
	return overlays


func _texture_hash_for_block(hashes: Array, block: Dictionary) -> int:
	var resolved := int(block.get("resolved_texture_hash", 0))
	if resolved != 0:
		return resolved
	return _source_texture_hash_for_block(hashes, block)


func _source_texture_hash_for_block(hashes: Array, block: Dictionary) -> int:
	var texture_index := int(block.get("texture_index", -1))
	if texture_index >= 0 and texture_index < hashes.size():
		return int(hashes[texture_index])
	return 0


func _resolved_uvs(block: Dictionary, vertex_count: int) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var run: Dictionary = block.get("run", {})
	var texcoords: Array = run.get("texcoords", [])
	for i in range(vertex_count):
		var uv: Vector2 = texcoords[i]
		var u := 1.0 - uv.x if bool(block.get("resolved_texture_mirror_u", false)) else uv.x
		var v := uv.y if bool(block.get("resolved_texture_preserve_v", false)) else 1.0 - uv.y
		if block.has("resolved_texture_uv_offset") and block.has("resolved_texture_uv_scale"):
			var uv_offset: Vector2 = block["resolved_texture_uv_offset"]
			var uv_scale: Vector2 = block["resolved_texture_uv_scale"]
			u = uv_offset.x + u * uv_scale.x
			v = uv_offset.y + v * uv_scale.y
		out.append(Vector2(u, v))
	return out


func _indices_for_block(block: Dictionary, vertex_count: int) -> PackedInt32Array:
	var mode := String(block.get("primitive_mode", "strip"))
	if mode == "triangles":
		var triangles := PackedInt32Array()
		for i in range(0, vertex_count - (vertex_count % 3), 3):
			_append_tri(triangles, i, i + 1, i + 2)
		return triangles
	if mode == "fan":
		var fan := PackedInt32Array()
		for i in range(1, vertex_count - 1):
			_append_tri(fan, 0, i, i + 1)
		return fan
	return _strip_indices(block, vertex_count)


func _strip_indices(block: Dictionary, vertex_count: int) -> PackedInt32Array:
	var disabled := _adc_disabled_from_vif_control(block.get("run", {}).get("header", []), block.get("run", {}).get("tri_cull", []), vertex_count)
	if disabled.is_empty():
		disabled.resize(vertex_count)
		for i in range(vertex_count):
			disabled[i] = false
	var out := PackedInt32Array()
	var face := 1
	for index in range(vertex_count):
		if bool(disabled[index]):
			face = 1
			continue
		var a := index - 1 - face
		var b := index - 1
		var c := index - 1 + face
		if a >= 0 and b >= 0 and c >= 0 and a < vertex_count and b < vertex_count and c < vertex_count:
			_append_tri(out, a, b, c)
		face = -face
	return out


func _append_tri(out: PackedInt32Array, a: int, b: int, c: int) -> void:
	if a != b and a != c and b != c:
		out.append(a)
		out.append(b)
		out.append(c)


func _adc_disabled_from_vif_control(header: Array, tri_cull: Array, vertex_count: int) -> Array:
	if header.size() < 2 or tri_cull.size() < 4 or vertex_count <= 0:
		return []
	var num_vertices := int(header[0])
	var mode := int(header[1])
	if num_vertices <= 0 or num_vertices > vertex_count or num_vertices > 32 or mode > 7:
		return []
	var mask := _vif_control_mask(num_vertices, mode, tri_cull)
	var out: Array[bool] = []
	for index in range(vertex_count):
		out.append(((mask >> (31 - index)) & 1) != 0)
	return out


func _vif_control_mask(num_vertices: int, mode: int, tri_cull: Array) -> int:
	var use_upper := mode & 0x04
	var downer_side := (-(((mode & 0x03) + 1) >> 2) << (use_upper >> 2)) & 0x03
	var upper_side := ~(-use_upper)
	var downer := int(tri_cull[downer_side]) if downer_side >= 0 and downer_side < tri_cull.size() else 0
	var upper := int(tri_cull[upper_side]) if upper_side >= 0 and upper_side < tri_cull.size() else 0
	var hi_downer := downer >> 18
	var lo_downer := downer & 0x7FFF
	var hi_downer_swap := hi_downer ^ (lo_downer & 0x1E)
	var hi_upper_swap := ((upper >> 2) | ((mode + 1) >> 1)) & 0x04
	var new_downer := (lo_downer << 4) | (hi_downer_swap >> 1)
	var new_upper := (upper >> 2) ^ (((hi_downer_swap >> 1) & 0x07) << 13) ^ (hi_upper_swap << 18)
	var mask := _shift_left(new_downer, ((mode - 3) << 2) - 3)
	if use_upper != 0:
		mask = (mask & ((0xFFFFFFFF << 13) & 0xFFFFFFFF)) | (new_upper & 0x3FFF)
	mask = _shift_left(mask, (7 - mode) << 2)
	mask = mask & ((0xFFFFFFFF << (32 - num_vertices)) & 0xFFFFFFFF)
	return mask & 0xFFFFFFFF


func _shift_left(value: int, shift: int) -> int:
	if shift >= 0:
		return value << shift
	return value >> -shift


func _draw_overlay(image: Image, blocks: Array, base_size: Vector2i, scale: int) -> void:
	for block in blocks:
		var color: Color = block["color"]
		var uvs: Array = block["uvs"]
		var indices: PackedInt32Array = block["indices"]
		for i in range(0, indices.size() - 2, 3):
			var a := _uv_to_pixel(uvs[int(indices[i])], base_size, scale)
			var b := _uv_to_pixel(uvs[int(indices[i + 1])], base_size, scale)
			var c := _uv_to_pixel(uvs[int(indices[i + 2])], base_size, scale)
			_draw_line(image, a, b, color)
			_draw_line(image, b, c, color)
			_draw_line(image, c, a, color)


func _print_overlay_summary(asset, overlays: Dictionary) -> void:
	for texture_hash in overlays.keys():
		var info: Dictionary = asset.texture_bank.get_info(texture_hash)
		print("texture=%s hash=%08x block_count=%d" % [String(info.get("name", "")), int(texture_hash), Array(overlays[texture_hash]).size()])
		for block in overlays[texture_hash]:
			var uv_bounds := _uv_bounds(block["uvs"])
			print("%s block=%d source=%08x alias=%s uv_min=(%.3f,%.3f) uv_max=(%.3f,%.3f)" % [
				String(block["object_name"]),
				int(block["block_index"]),
				int(block["source_hash"]),
				String(block["alias"]),
				float(uv_bounds["min"].x),
				float(uv_bounds["min"].y),
				float(uv_bounds["max"].x),
				float(uv_bounds["max"].y),
			])


func _uv_bounds(uvs: Array) -> Dictionary:
	var min_value := Vector2(INF, INF)
	var max_value := Vector2(-INF, -INF)
	for uv in uvs:
		var p: Vector2 = uv
		min_value.x = minf(min_value.x, p.x)
		min_value.y = minf(min_value.y, p.y)
		max_value.x = maxf(max_value.x, p.x)
		max_value.y = maxf(max_value.y, p.y)
	return {
		"min": min_value,
		"max": max_value,
	}


func _uv_to_pixel(uv: Vector2, base_size: Vector2i, scale: int) -> Vector2i:
	var wrapped := Vector2(uv.x - floorf(uv.x), uv.y - floorf(uv.y))
	var width: int = base_size.x * scale
	var height: int = base_size.y * scale
	return Vector2i(
		clampi(int(round(wrapped.x * float(width - 1))), 0, width - 1),
		clampi(int(round(wrapped.y * float(height - 1))), 0, height - 1)
	)


func _draw_line(image: Image, a: Vector2i, b: Vector2i, color: Color) -> void:
	var dx: int = absi(b.x - a.x)
	var dy: int = -absi(b.y - a.y)
	var sx: int = 1 if a.x < b.x else -1
	var sy: int = 1 if a.y < b.y else -1
	var err: int = dx + dy
	var x: int = a.x
	var y: int = a.y
	while true:
		_blend_pixel(image, x, y, color)
		_blend_pixel(image, x + 1, y, color)
		_blend_pixel(image, x, y + 1, color)
		if x == b.x and y == b.y:
			break
		var e2: int = 2 * err
		if e2 >= dy:
			err += dy
			x += sx
		if e2 <= dx:
			err += dx
			y += sy


func _blend_pixel(image: Image, x: int, y: int, color: Color) -> void:
	if x < 0 or y < 0 or x >= image.get_width() or y >= image.get_height():
		return
	var base := image.get_pixel(x, y)
	image.set_pixel(x, y, base.lerp(color, 0.82))


func _arg_value(args: PackedStringArray, name: String, fallback: String) -> String:
	var index := args.find(name)
	if index >= 0 and index + 1 < args.size():
		return args[index + 1]
	return fallback


func _safe_file_part(value: String) -> String:
	var out := value.strip_edges()
	for token in [":", "/", "\\", " ", "@"]:
		out = out.replace(token, "_")
	return out
