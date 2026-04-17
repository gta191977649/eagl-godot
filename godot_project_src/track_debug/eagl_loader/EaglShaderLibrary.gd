class_name EaglShaderLibrary
extends RefCounted

const SHADERS = {
	"BlendedOverlay": [
		{"type": "Float3", "usage": "Position"}, {"type": "D3DColor", "usage": "Color0"},
		{"type": "Float2", "usage": "Texcoord0"}, {"type": "Float2", "usage": "Texcoord1"},
		{"type": "Float2", "usage": "Texcoord2"}
	],
	"BlendedWithShadow": [
		{"type": "Float3", "usage": "Position"}, {"type": "D3DColor", "usage": "Color0"},
		{"type": "Float2", "usage": "Texcoord0"}, {"type": "Float2", "usage": "Texcoord1"},
		{"type": "Float2", "usage": "Texcoord2"}, {"type": "Float2", "usage": "Texcoord3"}
	],
	"Mirror": [
		{"type": "Float3", "usage": "Position"}, {"type": "D3DColor", "usage": "Color0"},
		{"type": "Float2", "usage": "Texcoord0"}
	],
	"NamedGouraud": [
		{"type": "Float3", "usage": "Position"}, {"type": "D3DColor", "usage": "Color0"}
	],
	"NamedTexture": [
		{"type": "Float3", "usage": "Position"}, {"type": "D3DColor", "usage": "Color0"},
		{"type": "Float2", "usage": "Texcoord0"}
	],
	"ScrollTexture": [
		{"type": "Float3", "usage": "Position"}, {"type": "D3DColor", "usage": "Color0"},
		{"type": "Float2", "usage": "Texcoord0"}
	],
	"ShadowTexture": [
		{"type": "Float3", "usage": "Position"}, {"type": "D3DColor", "usage": "Color0"},
		{"type": "Float2", "usage": "Texcoord0"}, {"type": "Float2", "usage": "Texcoord1"}
	],
	"TwoShadows": [
		{"type": "Float3", "usage": "Position"}, {"type": "D3DColor", "usage": "Color0"},
		{"type": "Float2", "usage": "Texcoord0"}, {"type": "Float2", "usage": "Texcoord1"},
		{"type": "Float2", "usage": "Texcoord2"}
	]
}


static func get_fields(shader_name: String) -> Array:
	return SHADERS.get(shader_name, [])


static func field_size(field_type: String) -> int:
	match field_type:
		"Float2":
			return 8
		"Float3":
			return 12
		"Float4":
			return 16
		"D3DColor", "UByte4":
			return 4
		_:
			return 0


static func stride(fields: Array) -> int:
	var out = 0
	for field in fields:
		out += field_size(field.type)
	return out
