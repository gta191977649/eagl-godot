shader_type spatial;
render_mode cull_disabled, blend_mix, depth_prepass_alpha;

uniform sampler2D albedo_texture : source_color, repeat_enable, filter_nearest_mipmap;
uniform bool use_texture = true;
uniform vec4 albedo_tint : source_color = vec4(1.0);
uniform bool use_vertex_color = true;
uniform float vertex_color_modulate_scale = 1.9921875;
uniform float vertex_color_floor = 0.0;
uniform float vertex_color_blend = 1.0;
uniform float surface_roughness = 0.45;
uniform vec3 key_light_direction = vec3(-0.35, 0.82, 0.42);
uniform vec3 fill_light_color : source_color = vec3(0.05, 0.08, 0.09);
uniform vec3 key_light_color : source_color = vec3(1.0, 1.0, 0.9);
uniform vec3 reflection_color : source_color = vec3(0.65, 0.95, 1.0);
uniform float ambient_floor = 0.35;
uniform float material_exposure = 1.15;
uniform float shade_strength = 0.45;
uniform float diffuse_strength = 0.68;
uniform float top_light_strength = 0.45;
uniform float reflection_strength = 0.24;
uniform float fresnel_scaler = 3.0;
uniform vec3 specular_color : source_color = vec3(0.78, 0.78, 0.78);
uniform float specular_strength = 0.34;
uniform float specular_power = 38.0;
uniform float specular_hotspot_exponent = 55.0;
uniform float specular_sun_intensity = 0.0;
uniform float reflection_mask_floor = 0.0;
uniform float alpha_cutoff = 0.5;
uniform bool use_alpha_scissor = false;
uniform bool distance_fade_enabled = false;
uniform float distance_fade_end = 0.0;
uniform float distance_fade_window = 0.0;

varying vec3 world_position;
varying vec3 world_normal;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_NORMAL_MATRIX * NORMAL).xyz);
}

void fragment() {
	vec4 base = albedo_tint;
	if (use_texture) {
		base *= texture(albedo_texture, UV);
	}
	if (use_vertex_color) {
		vec3 lit_color = min(base.rgb * COLOR.rgb * vertex_color_modulate_scale, vec3(1.0));
		base.rgb = mix(base.rgb, max(lit_color, base.rgb * vertex_color_floor), vertex_color_blend);
		base.a *= COLOR.a;
	}
	vec3 source_rgb = base.rgb;

	vec3 normal = normalize(world_normal);
	vec3 view_dir = normalize(CAMERA_POSITION_WORLD - world_position);
	vec3 light_dir = normalize(key_light_direction);
	float ndotl = max(dot(normal, light_dir), 0.0);
	float top_light = smoothstep(0.2, 0.95, normal.y);
	float fresnel = clamp((1.0 - max(dot(normal, view_dir), 0.0)) * fresnel_scaler, 0.0, 1.0);
	float reflected_sun = max(dot(reflect(-light_dir, normal), view_dir), 0.0);
	float specular = pow(reflected_sun, specular_power) * specular_strength;
	float hotspot = pow(reflected_sun, specular_hotspot_exponent) * specular_sun_intensity;

	float light_factor = clamp(ndotl * diffuse_strength + top_light * top_light_strength, 0.0, 1.0);
	vec3 lighting = mix(fill_light_color, key_light_color, light_factor);
	lighting = max(lighting, vec3(ambient_floor));
	float reflect_mask = max(reflection_mask_floor, smoothstep(0.12, 0.75, max(max(source_rgb.r, source_rgb.g), source_rgb.b)));
	vec3 shaded = source_rgb * lighting;
	vec3 reflected = reflection_color * fresnel * reflection_strength * reflect_mask;
	vec3 fixed_specular = specular_color * (specular + hotspot) * reflect_mask;
	base.rgb = mix(source_rgb, shaded, shade_strength) * material_exposure
		+ reflected
		+ fixed_specular;

	if (distance_fade_enabled && distance_fade_end > 0.0) {
		float camera_distance = distance(CAMERA_POSITION_WORLD, world_position);
		float fade_alpha = camera_distance <= distance_fade_end
			? 1.0
			: clamp((distance_fade_end + max(distance_fade_window, 0.0) - camera_distance) / max(distance_fade_window, 0.0001), 0.0, 1.0);
		base.a *= fade_alpha;
	}

	ALBEDO = clamp(base.rgb, vec3(0.0), vec3(1.0));
	EMISSION = reflected + fixed_specular;
	SPECULAR = clamp(specular_strength, 0.0, 1.0);
	ALPHA = base.a;
	if (use_alpha_scissor) {
		ALPHA_SCISSOR_THRESHOLD = alpha_cutoff;
	}
	ROUGHNESS = surface_roughness;
}
