shader_type sky;

// The Forge view's background: a gradient fixed to the screen, top_color at the top to
// bottom_color at the bottom, whichever way the camera turns. The ambient light and reflections
// come from a soft sky of their own, so bodies are lit the same in every theme.
//
// The gradient runs on FRAGCOORD over view_height (the view's height in pixels, which
// forge_viewport.gd keeps up to date), not SCREEN_UV: the Compatibility renderer has no SCREEN_UV
// in sky shaders and drew the view black.

uniform vec3 top_color : source_color = vec3(0.957, 0.965, 0.976);
uniform float view_height = 1.0;
uniform vec3 bottom_color : source_color = vec3(0.804, 0.831, 0.871);
uniform vec3 ambient_top : source_color = vec3(0.62, 0.68, 0.76);
uniform vec3 ambient_horizon : source_color = vec3(0.9, 0.91, 0.93);
uniform vec3 ambient_ground : source_color = vec3(0.72, 0.74, 0.78);

void sky() {
	if (AT_CUBEMAP_PASS) {
		float up = EYEDIR.y;
		COLOR = up >= 0.0 ? mix(ambient_horizon, ambient_top, sqrt(up)) : mix(ambient_horizon, ambient_ground, sqrt(-up));
	} else {
		COLOR = mix(top_color, bottom_color, clamp(FRAGCOORD.y / max(view_height, 1.0), 0.0, 1.0));
	}
}
