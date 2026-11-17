shader_type spatial;
render_mode cull_disabled;

// Surface bodies (open shells) in the Forge view: the front in one color and the back in another,
// so which way a surface faces (Reverse Normal) shows at a glance. Back faces are lit from their
// own side (Godot turns their normal over when culling is off).
uniform vec4 front_color : source_color = vec4(0.93, 0.76, 0.45, 1.0);
uniform vec4 back_color : source_color = vec4(0.55, 0.46, 0.70, 1.0);

void fragment() {
	ALBEDO = FRONT_FACING ? front_color.rgb : back_color.rgb;
	ROUGHNESS = 0.5;
	METALLIC = 0.05;
}
