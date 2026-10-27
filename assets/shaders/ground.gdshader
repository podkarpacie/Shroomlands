shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

// Mossy mycelium ground. Everything is sampled in world XZ, so the big plain and
// the mounds share one continuous surface with no texture seams or per-mesh UVs.
// Two large-scale noises paint moss and spore patches; two small-scale ones add
// grain and thin pale "thread" lines.

uniform sampler2D macro_noise : repeat_enable, filter_linear_mipmap;
uniform sampler2D detail_noise : repeat_enable, filter_linear_mipmap;

uniform vec3 moss_dark : source_color = vec3(0.135, 0.265, 0.135);
uniform vec3 moss_light : source_color = vec3(0.30, 0.47, 0.19);
uniform vec3 spore_tint : source_color = vec3(0.12, 0.38, 0.34);
uniform vec3 thread_color : source_color = vec3(0.62, 0.66, 0.46);

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = world_pos.xz;
	float big = texture(macro_noise, p * 0.011).r;
	float mid = texture(macro_noise, p * 0.043 + vec2(17.3, 5.1)).r;
	float grain = texture(detail_noise, p * 0.85).r;
	float fine = texture(detail_noise, p * 3.4 + vec2(3.7, 9.2)).r;

	float patch = smoothstep(0.20, 0.85, big * 0.6 + mid * 0.4);
	vec3 col = mix(moss_dark, moss_light, patch);

	// Cool, spore-dusted patches where the second noise runs high.
	col = mix(col, spore_tint, smoothstep(0.60, 0.86, mid) * 0.55);

	// Thin pale threads (mycelium) along the zero-crossings of the grain noise.
	float thread = 1.0 - smoothstep(0.0, 0.03, abs(grain - 0.5));
	col = mix(col, thread_color, thread * 0.10 * smoothstep(0.35, 0.65, big));

	// Grain and fine speckle break up the flat colour up close.
	col *= 0.84 + 0.24 * grain + 0.07 * (fine - 0.5);

	ALBEDO = col;
	ROUGHNESS = 0.95 - 0.12 * fine;
	SPECULAR = 0.25;
}
