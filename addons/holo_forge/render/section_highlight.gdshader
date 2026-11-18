shader_type spatial;
render_mode unshaded, blend_mix, cull_back;

// Section analysis: a selection or hover highlight over a sectioned body, hidden on the plane
// normal's side like the body under it (section_clip.gdshader), and grown a hair off the surface
// like the view's plain highlight material.

uniform vec3 plane_origin = vec3(0.0);
uniform vec3 plane_normal = vec3(1.0, 0.0, 0.0);
// The view's world back to the part's space (the plane is given there): identity unless the
// view is moved, as by Passthrough.
uniform mat4 world_to_part = mat4(1.0);
uniform vec4 color : source_color = vec4(0.15, 0.45, 1.0, 0.45);
uniform float grow_amount = 0.00015;

varying vec3 world_position;

void vertex() {
	VERTEX += NORMAL * grow_amount;
	world_position = (world_to_part * MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	if (dot(world_position - plane_origin, plane_normal) > 0.0) {
		discard;
	}
	ALBEDO = color.rgb;
	ALPHA = color.a;
}
