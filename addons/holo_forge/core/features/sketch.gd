@tool
extends RefCounted
## The Sketch feature: solves the sketch's constraints, then finds its profiles (closed regions)
## with the kernel. Results go to ctx.sketches[feature id] for display and later features.

const SKETCH_DATA := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")
const SKETCH_SOLVE := preload("res://addons/holo_forge/core/sketch/sketch_solve.gd")
const TEXT_OUTLINE := preload("res://addons/holo_forge/core/sketch/text_outline.gd")

const PROFILE_DEFLECTION := 0.0002


static func build(feature: Resource, ctx: Dictionary) -> String:
	var sketch = SKETCH_DATA.new(feature, ctx.doc)
	var solved := SKETCH_SOLVE.solve(sketch, ctx.values)
	var text := TEXT_OUTLINE.outlines_for(sketch, ctx.kernel)
	var curves: Array = sketch.profile_curves(text)
	var regions: Array = ctx.kernel.sketch_regions(curves, sketch.transform(), PROFILE_DEFLECTION) if not curves.is_empty() else []
	ctx.sketches[feature.id] = {"solve": solved, "regions": regions, "curves": curves, "text": text, "plane": sketch.transform()}
	if not solved.ok and not sketch.constraints().is_empty():
		return "The sketch's constraints could not be solved"
	if not solved.conflicting.is_empty():
		return "Over-constrained: %d conflicting constraint(s)" % solved.conflicting.size()
	for warning in solved.warnings:
		if str(warning).begins_with("Dimension"):
			return str(warning)
	return ""
