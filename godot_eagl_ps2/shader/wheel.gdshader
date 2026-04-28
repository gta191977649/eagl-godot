shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled;

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 albedo_tint : source_color = vec4(1.0);
uniform bool use_vertex_color = true;
uniform float vertex_color_modulate_scale = 1.9921875;
uniform float metallic = 0.2;
uniform float roughness = 0.8;
uniform float specular = 0.5;

varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec4 base = albedo_tint * texture(albedo_texture, UV);
	if (use_vertex_color) {
		base.rgb = min(base.rgb * COLOR.rgb * vertex_color_modulate_scale, vec3(1.0));
		base.a *= COLOR.a;
	}
	ALBEDO = base.rgb;
	METALLIC = metallic;
	ROUGHNESS = roughness;
	SPECULAR = specular;
}
