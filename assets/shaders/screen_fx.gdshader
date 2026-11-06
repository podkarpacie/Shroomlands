shader_type canvas_item;

// Screen-space horror grade: a biome tint, a vignette that tightens with danger,
// film grain and a small chromatic split. It samples the rendered frame, so it
// sits on a CanvasLayer below the HUD (layer 5) and above the 3D view.

uniform vec4 tint : source_color = vec4(0.62, 0.86, 0.68, 1.0);
uniform float tint_strength : hint_range(0.0, 0.5) = 0.10;
uniform float vignette_strength : hint_range(0.0, 1.5) = 0.50;
uniform float grain_strength : hint_range(0.0, 0.2) = 0.030;
uniform float pulse : hint_range(0.0, 1.0) = 0.0;
uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	// A tiny split grows with danger; at rest it is barely visible.
	float split = 0.0007 + pulse * 0.0022;
	vec3 scene;
	scene.r = texture(screen_tex, uv + vec2(split, 0.0)).r;
	scene.g = texture(screen_tex, uv).g;
	scene.b = texture(screen_tex, uv - vec2(split, 0.0)).b;

	scene = mix(scene, tint.rgb, tint_strength);

	float distance_from_centre = length(uv - vec2(0.5));
	float vignette = smoothstep(0.30, 0.80, distance_from_centre);
	scene *= 1.0 - vignette * vignette_strength * (1.0 + pulse * 0.55);

	float noise = hash(uv * vec2(1920.0, 1080.0) + vec2(TIME * 37.0, TIME * 23.0));
	scene += (noise - 0.5) * grain_strength * (1.0 + pulse * 0.8);

	COLOR = vec4(scene, 1.0);
}
