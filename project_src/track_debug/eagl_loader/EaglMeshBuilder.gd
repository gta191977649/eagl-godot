class_name EaglMeshBuilder
extends RefCounted


func build_primitive_node(name: String, primitive: Dictionary, material: Material) -> MeshInstance3D:
	var mesh = ArrayMesh.new()
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _positions(primitive.vertices)
	arrays[Mesh.ARRAY_COLOR] = _colors(primitive.vertices)
	arrays[Mesh.ARRAY_TEX_UV] = _uvs(primitive.vertices)
	arrays[Mesh.ARRAY_INDEX] = primitive.indices
	var normals = _normals(primitive.vertices)
	if not normals.is_empty():
		arrays[Mesh.ARRAY_NORMAL] = normals
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)
	var node = MeshInstance3D.new()
	node.name = name
	node.mesh = mesh
	return node


func _positions(vertices: Array) -> PackedVector3Array:
	var out = PackedVector3Array()
	for vertex in vertices:
		out.append(vertex.position)
	return out


func _colors(vertices: Array) -> PackedColorArray:
	var out = PackedColorArray()
	for vertex in vertices:
		out.append(vertex.get("color", Color.WHITE))
	return out


func _uvs(vertices: Array) -> PackedVector2Array:
	var out = PackedVector2Array()
	for vertex in vertices:
		out.append(vertex.get("uv0", vertex.get("uv", Vector2.ZERO)))
	return out


func _normals(vertices: Array) -> PackedVector3Array:
	var out = PackedVector3Array()
	for vertex in vertices:
		if not vertex.has("normal"):
			return PackedVector3Array()
		out.append(vertex.normal)
	return out
