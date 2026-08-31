shader_type spatial;

// World-space checker (NOTES.md, "Color as semantics"). The pattern is driven by
// world position, not UVs, so a 1m square stays a 1m square no matter how the
// mesh is scaled or tiled. Untextured primitives get a readable sense of scale.
//
// Lit rather than unlit: this unit has to show that the lighting works, and a
// shadow on a flat gray plane is the cheapest proof of that.

uniform vec3 color_a : source_color = vec3(0.44, 0.44, 0.45);
uniform vec3 color_b : source_color = vec3(0.33, 0.33, 0.34);
uniform float square_size = 1.0;

varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 cell = floor(world_position.xz / square_size);
	float checker = mod(cell.x + cell.y, 2.0);
	ALBEDO = mix(color_a, color_b, checker);
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}
