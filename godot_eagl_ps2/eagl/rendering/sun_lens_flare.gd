class_name EAGLSunLensFlare
extends CanvasLayer

const PS2_SCREEN_WIDTH := 640.0
const RAY_EPSILON := 0.00001
const MIN_OCCLUDER_DISTANCE := 2.0
const SUN_OCCLUSION_COLLISION_LAYER := 1 << 19

var sun_world_position := Vector3.ZERO
var records: Array[Dictionary] = []
var draw_records: Array[Dictionary] = []
var sprites: Array[TextureRect] = []
var viewport_margin := 0.25
var visibility_factor := 0.0
var occlusion_fade_speed := 4.5
var occluders: Array[GeometryInstance3D] = []
var occluder_root: Node = null
var collider_root: Node = null
var occlusion_shape_cache := {}
var sun_direction := Vector3.ZERO
var sun_distance := 10000.0


func configure(position: Vector3, flare_records: Array[Dictionary], texture_bank) -> void:
	sun_world_position = position
	sun_distance = maxf(position.length(), 1.0)
	sun_direction = position.normalized() if position.length_squared() > RAY_EPSILON else Vector3.ZERO
	records = flare_records.duplicate(true)
	draw_records.clear()
	_clear_sprites()
	for record in records:
		if not bool(record.get("enabled", false)):
			continue
		var texture_hash := int(record.get("texture_hash", 0))
		if texture_hash == 0 or texture_bank == null or not texture_bank.has_texture(texture_hash):
			continue
		var sprite := TextureRect.new()
		sprite.name = "Flare_%02d_%s" % [int(record.get("index", sprites.size())), String(record.get("texture_name", ""))]
		sprite.texture = texture_bank.get_texture(texture_hash)
		sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		sprite.stretch_mode = TextureRect.STRETCH_SCALE
		sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
		sprite.material = _additive_canvas_material()
		add_child(sprite)
		draw_records.append(record)
		sprites.append(sprite)


func _process(delta: float) -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null or sprites.is_empty():
		_set_sprites_visible(false)
		return
	var frame_sun_position := _sun_position_for_camera(camera)
	if camera.is_position_behind(frame_sun_position):
		_set_sprites_visible(false)
		return

	var viewport_size := get_viewport().get_visible_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		_set_sprites_visible(false)
		return

	var sun_screen := camera.unproject_position(frame_sun_position)
	var margin := viewport_size.length() * viewport_margin
	if sun_screen.x < -margin or sun_screen.y < -margin or sun_screen.x > viewport_size.x + margin or sun_screen.y > viewport_size.y + margin:
		_set_sprites_visible(false)
		return

	var target_visibility := 0.0 if _is_sun_occluded(camera) else 1.0
	visibility_factor = move_toward(visibility_factor, target_visibility, delta * occlusion_fade_speed)
	if visibility_factor <= 0.01:
		_set_sprites_visible(false)
		return

	var scale := viewport_size.x / PS2_SCREEN_WIDTH
	var size_visibility := lerpf(0.35, 1.0, visibility_factor)
	for sprite_index in range(sprites.size()):
		var record := draw_records[sprite_index]
		var sprite := sprites[sprite_index]
		var size := maxf(float(record.get("size", 0.0)) * scale * size_visibility, 1.0)
		var offset: Vector2 = record.get("offset", Vector2.ZERO)
		var center := sun_screen + offset * scale
		sprite.size = Vector2(size, size)
		sprite.position = center - sprite.size * 0.5
		sprite.modulate = _record_modulate(record, visibility_factor)
		sprite.rotation = _record_rotation(record)
		sprite.visible = true


func _clear_sprites() -> void:
	for sprite in sprites:
		if sprite != null and is_instance_valid(sprite):
			sprite.queue_free()
	sprites.clear()
	draw_records.clear()


func _set_sprites_visible(visible: bool) -> void:
	for sprite in sprites:
		sprite.visible = visible


func _record_modulate(record: Dictionary, visibility: float) -> Color:
	var color: Color = record.get("color", Color.WHITE)
	var intensity := clampf(float(record.get("intensity", 1.0)), 0.0, 2.0)
	color.r = clampf(color.r * intensity, 0.0, 1.0)
	color.g = clampf(color.g * intensity, 0.0, 1.0)
	color.b = clampf(color.b * intensity, 0.0, 1.0)
	color.a = clampf(color.a * intensity * visibility, 0.0, 1.0)
	return color


func _is_sun_occluded(camera: Camera3D) -> bool:
	var root := get_parent()
	if root == null:
		return false
	var origin := camera.global_transform.origin
	var direction := sun_direction
	if direction.length_squared() <= RAY_EPSILON:
		return false
	direction = direction.normalized()
	_ensure_occlusion_colliders(root)
	var raycast := _occlusion_raycast(root)
	if raycast == null:
		return false
	var ray_length := maxf(camera.far, MIN_OCCLUDER_DISTANCE + 1.0)
	raycast.global_transform = Transform3D(Basis.IDENTITY, origin + direction * MIN_OCCLUDER_DISTANCE)
	raycast.target_position = direction * maxf(ray_length - MIN_OCCLUDER_DISTANCE, 0.01)
	raycast.force_raycast_update()
	return raycast.is_colliding()


func _sun_position_for_camera(camera: Camera3D) -> Vector3:
	if sun_direction.length_squared() <= RAY_EPSILON:
		return sun_world_position
	return camera.global_transform.origin + sun_direction.normalized() * sun_distance


func _occlusion_raycast(root: Node) -> RayCast3D:
	var raycast := root.get_node_or_null("EAGL_SunOcclusionRay") as RayCast3D
	if raycast != null:
		return raycast
	raycast = RayCast3D.new()
	raycast.name = "EAGL_SunOcclusionRay"
	raycast.enabled = true
	raycast.collision_mask = SUN_OCCLUSION_COLLISION_LAYER
	raycast.collide_with_bodies = true
	raycast.collide_with_areas = false
	root.add_child(raycast)
	return raycast


func _occluder_nodes(root: Node) -> Array[GeometryInstance3D]:
	if occluder_root == root and not occluders.is_empty():
		return occluders
	occluder_root = root
	occluders.clear()
	for branch_name in ["StaticGeometry", "Scenery"]:
		var branch := root.get_node_or_null(branch_name)
		if branch == null:
			continue
		for node in branch.find_children("*", "GeometryInstance3D", true, false):
			var geometry := node as GeometryInstance3D
			if geometry != null and not _should_skip_occluder(geometry):
				occluders.append(geometry)
	return occluders


func _should_skip_occluder(geometry: GeometryInstance3D) -> bool:
	var object_name := String(geometry.get_meta("eagl_object_name", geometry.name)).to_upper()
	var category := String(geometry.get_meta("bun_category", "")).to_upper()
	return object_name.begins_with("SKYDOME") or object_name.contains("ENVMAP") or object_name == "WATER" or category == "ENVIRONMENT" or category == "SHADOW" or not _has_eligible_occlusion_material(geometry)


func _has_eligible_occlusion_material(geometry: GeometryInstance3D) -> bool:
	var mesh := _geometry_mesh(geometry)
	if mesh == null:
		return false
	var saw_material := false
	for surface_index in range(mesh.get_surface_count()):
		var material := _geometry_surface_material(geometry, mesh, surface_index)
		if material == null:
			continue
		saw_material = true
		if not _is_non_occluding_material(material):
			return true
	return not saw_material


func _is_non_occluding_material(material: Material) -> bool:
	var texture_name := String(material.get_meta("eagl_texture_name", "")).to_upper()
	if texture_name.contains("CLOUD") or texture_name.contains("SKY") or texture_name.contains("FOG"):
		return true
	var alpha_mode := String(material.get_meta("eagl_effective_alpha_mode", material.get_meta("eagl_alpha_mode", ""))).to_upper()
	return alpha_mode != ""


func _ensure_occlusion_colliders(root: Node) -> void:
	if collider_root == root:
		return
	collider_root = root
	for geometry in _occluder_nodes(root):
		if geometry == null or not is_instance_valid(geometry):
			continue
		_add_occlusion_collider(geometry)


func _add_occlusion_collider(geometry: GeometryInstance3D) -> void:
	if geometry.has_node("EAGL_SunOcclusionBody"):
		return
	var mesh := _geometry_mesh(geometry)
	if mesh == null:
		return
	var shape := _trimesh_shape_for_mesh(mesh)
	if shape == null:
		return
	var body := StaticBody3D.new()
	body.name = "EAGL_SunOcclusionBody"
	body.collision_layer = SUN_OCCLUSION_COLLISION_LAYER
	body.collision_mask = 0
	body.set_meta("eagl_sun_occluder", true)
	geometry.add_child(body)
	if geometry is MultiMeshInstance3D:
		var multimesh := (geometry as MultiMeshInstance3D).multimesh
		if multimesh == null:
			body.queue_free()
			return
		for index in range(_multimesh_instance_count(multimesh)):
			_add_collision_shape(body, shape, multimesh.get_instance_transform(index))
	else:
		_add_collision_shape(body, shape, Transform3D.IDENTITY)


func _add_collision_shape(body: StaticBody3D, shape: Shape3D, transform: Transform3D) -> void:
	var collision_shape := CollisionShape3D.new()
	collision_shape.name = "Shape"
	collision_shape.shape = shape
	collision_shape.transform = transform
	body.add_child(collision_shape)


func _trimesh_shape_for_mesh(mesh: Mesh) -> Shape3D:
	var key := mesh.get_instance_id()
	if occlusion_shape_cache.has(key):
		return occlusion_shape_cache[key]
	var shape := mesh.create_trimesh_shape()
	occlusion_shape_cache[key] = shape
	return shape


func _multimesh_instance_count(multimesh: MultiMesh) -> int:
	if multimesh.visible_instance_count >= 0:
		return mini(multimesh.visible_instance_count, multimesh.instance_count)
	return multimesh.instance_count


func _geometry_mesh(geometry: GeometryInstance3D) -> Mesh:
	if geometry is MeshInstance3D:
		return (geometry as MeshInstance3D).mesh
	if geometry is MultiMeshInstance3D and (geometry as MultiMeshInstance3D).multimesh != null:
		return (geometry as MultiMeshInstance3D).multimesh.mesh
	return null


func _geometry_surface_material(geometry: GeometryInstance3D, mesh: Mesh, surface_index: int) -> Material:
	if geometry is MeshInstance3D:
		var override_material := (geometry as MeshInstance3D).get_surface_override_material(surface_index)
		if override_material != null:
			return override_material
	return mesh.surface_get_material(surface_index)


func _record_rotation(record: Dictionary) -> float:
	var angle := int(record.get("angle_u16", 0))
	if angle == 0:
		return 0.0
	return float(angle) / 65536.0 * TAU


func _additive_canvas_material() -> CanvasItemMaterial:
	var material := CanvasItemMaterial.new()
	material.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	return material
