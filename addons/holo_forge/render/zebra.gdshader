shader_type spatial;
render_mode unshaded, cull_disabled;

// Zebra analysis: stripes of a world-fixed environment reflected in the surface. Smooth stripes
// across a seam mean the faces meet smoothly; kinks mean a tangency break, jumps a crease. Both
// sides draw: a surface is seen from behind too (Godot turns a back face's normal over).

uniform float stripes = 12.0;
uniform bool vertical = false;
uniform vec3 dark_color : source_color = vec3(0.05, 0.05, 0.06);
uniform vec3 light_color : source_color = vec3(0.95, 0.95, 0.95);

void fragment() {
	vec3 r = (INV_VIEW_MATRIX * vec4(reflect(-VIEW, NORMAL), 0.0)).xyz;
	float s = vertical ? atan(r.x, r.z) / PI : asin(clamp(r.y, -1.0, 1.0)) / PI;
	ALBEDO = mix(dark_color, light_color, step(0.5, fract(s * stripes)));
}
