shader_type spatial;
render_mode cull_disabled;

// Section analysis: hides everything on the plane normal's side, so the inside shows. Back faces
// seen through the cut are drawn darker.

uniform vec3 plane_origin = vec3(0.0);
uniform vec3 plane_normal = vec3(1.0, 0.0, 0.0);
// The view's world back to the part's space (the plane is given there): identity unless the
// view is moved, as by Passthrough.
uniform mat4 world_to_part = mat4(1.0);
uniform vec3 base_color : source_color = vec3(0.72, 0.74, 0.78);
uniform vec3 inside_color : source_color = vec3(0.3, 0.31, 0.35);

varying vec3 world_position;

void vertex() {
	world_position = (world_to_part * MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	if (dot(world_position - plane_origin, plane_normal) > 0.0) {
		discard;
	}
	ALBEDO = FRONT_FACING ? base_color : inside_color;
	ROUGHNESS = 0.6;
}
