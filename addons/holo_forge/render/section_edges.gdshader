shader_type spatial;
render_mode unshaded;

// Section analysis: a body's edge lines, hidden on the plane normal's side like its faces.

uniform vec3 plane_origin = vec3(0.0);
uniform vec3 plane_normal = vec3(1.0, 0.0, 0.0);
// The view's world back to the part's space (the plane is given there): identity unless the
// view is moved, as by Passthrough.
uniform mat4 world_to_part = mat4(1.0);
uniform vec3 color : source_color = vec3(0.08, 0.09, 0.11);

varying vec3 world_position;

void vertex() {
	world_position = (world_to_part * MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	if (dot(world_position - plane_origin, plane_normal) > 0.0) {
		discard;
	}
	ALBEDO = color;
}
