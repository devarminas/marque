shader_type spatial;

uniform vec3 color_a : source_color = vec3(0.36, 0.55, 0.24);
uniform vec3 color_b : source_color = vec3(0.27, 0.44, 0.18);
uniform vec3 color_c : source_color = vec3(0.47, 0.58, 0.26);
uniform float cell_size = 7.0;

varying vec3 world_position;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = world_position.xz / cell_size;
	float broad = value_noise(p);
	float fine = value_noise(p * 5.3 + vec2(17.0, 9.0));
	vec3 base = mix(color_a, color_b, broad);
	ALBEDO = mix(base, color_c, fine * 0.35);
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}
