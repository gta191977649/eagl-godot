class_name EAGLMathUtils
extends RefCounted


static func ps2_to_godot_vec3(value: Vector3) -> Vector3:
	return Vector3(value.x, value.z, -value.y)


static func transform_point_rows(point: Vector3, matrix_rows: Array) -> Vector3:
	if matrix_rows.size() < 4:
		return point
	var x := point.x
	var y := point.y
	var z := point.z
	var r0: Array = matrix_rows[0]
	var r1: Array = matrix_rows[1]
	var r2: Array = matrix_rows[2]
	var r3: Array = matrix_rows[3]
	return Vector3(
		x * float(r0[0]) + y * float(r1[0]) + z * float(r2[0]) + float(r3[0]),
		x * float(r0[1]) + y * float(r1[1]) + z * float(r2[1]) + float(r3[1]),
		x * float(r0[2]) + y * float(r1[2]) + z * float(r2[2]) + float(r3[2])
	)


static func ps2_rows_to_godot_transform(matrix_rows: Array) -> Transform3D:
	if matrix_rows.size() < 4:
		return Transform3D.IDENTITY
	var r0: Array = matrix_rows[0]
	var r1: Array = matrix_rows[1]
	var r2: Array = matrix_rows[2]
	var r3: Array = matrix_rows[3]
	var basis := Basis(
		Vector3(float(r0[0]), float(r0[2]), -float(r0[1])),
		Vector3(float(r2[0]), float(r2[2]), -float(r2[1])),
		Vector3(-float(r1[0]), -float(r1[2]), float(r1[1]))
	)
	var origin := Vector3(float(r3[0]), float(r3[2]), -float(r3[1]))
	return Transform3D(basis, origin)


static func merge_bounds(current: AABB, has_current: bool, point: Vector3) -> AABB:
	if not has_current:
		return AABB(point, Vector3.ZERO)
	return current.expand(point)


static func deterministic_color(seed: int, alpha: float = 1.0) -> Color:
	var value := int(seed) & 0xFFFFFFFF
	value = int((value ^ (value >> 16)) * 0x45d9f3b) & 0xFFFFFFFF
	value = int((value ^ (value >> 16)) * 0x45d9f3b) & 0xFFFFFFFF
	value = int(value ^ (value >> 16)) & 0xFFFFFFFF
	var r := 0.35 + float(value & 0xFF) / 255.0 * 0.55
	var g := 0.35 + float((value >> 8) & 0xFF) / 255.0 * 0.55
	var b := 0.35 + float((value >> 16) & 0xFF) / 255.0 * 0.55
	return Color(r, g, b, alpha)
