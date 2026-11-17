@tool
extends RefCounted
## How a Create feature's result combines with existing bodies: New Body, Join, Cut, Intersect,
## New Component.
##
## Join/Cut/Intersect act on the feature's picked bodies ("targets"); with none picked, every
## solid body the result touches takes part, as in other CAD apps (surface bodies only when
## picked). Auto (Press Pull on a profile) joins when the result touches a solid body and makes a
## new body when it doesn't. Each feature's tool shape is kept in ctx.tools so feature patterns
## and mirrors can replay it.
##
## Mesh bodies (core/mesh/mesh_body.gd) never take part by themselves, and one picked as a target
## is refused with the gate sentence: Join, Cut and Intersect need B-rep bodies.

const MESH_BODY := preload("res://addons/holo_forge/core/mesh/mesh_body.gd")

const NEW_BODY := "new_body"
const JOIN := "join"
const CUT := "cut"
const INTERSECT := "intersect"
const NEW_COMPONENT := "new_component"
const AUTO := "auto"
const ALL := [NEW_BODY, JOIN, CUT, INTERSECT, NEW_COMPONENT]
const LABELS := {NEW_BODY: "New Body", JOIN: "Join", CUT: "Cut", INTERSECT: "Intersect", NEW_COMPONENT: "New Component", AUTO: "Join or New Body"}
const KERNEL_OPS := {JOIN: 0, CUT: 1, INTERSECT: 2}


static func creates_body(op: String) -> bool:
	return op == NEW_BODY or op == NEW_COMPONENT


## True for operations that may make a body of their own, so the feature keeps a body id.
static func reserves_body(op: String) -> bool:
	return creates_body(op) or op == AUTO


## Applies feature's operation with tool_shape to ctx.bodies. Returns an error, or "".
static func apply(ctx: Dictionary, feature: Resource, tool_shape: RefCounted) -> String:
	var op := str(feature.options.get("operation", NEW_BODY))
	if op == AUTO:
		op = JOIN if not participating(ctx, tool_shape, feature.options.get("targets", []), true).is_empty() else NEW_BODY
	if ctx.has("tools"):
		ctx.tools[feature.id] = {"shape": tool_shape, "operation": op}
	return apply_shape(ctx, feature, tool_shape, op, feature.options.get("targets", []), str(feature.options.get("body_id", "")))


## The operation for any tool shape (patterns and mirrors replay copies through this).
static func apply_shape(ctx: Dictionary, feature: Resource, tool_shape: RefCounted, op: String, picked: Array, body_id: String) -> String:
	var bodies: Dictionary = ctx.bodies
	if creates_body(op):
		if body_id == "":
			return "The feature has no body id"
		bodies[body_id] = {"id": body_id, "shape": tool_shape, "feature": feature.id}
		return ""
	if not KERNEL_OPS.has(op):
		return "Unknown operation '%s'" % op
	var targets := participating(ctx, tool_shape, picked, true)
	var gate := MESH_BODY.gate_ids(ctx, targets)
	if gate != "":
		return gate
	if targets.is_empty():
		if not picked.is_empty():
			return "Body %s no longer exists" % ctx.doc.body_name(str(picked[0]))
		if op == JOIN and feature.options.has("press_pull_pick"):
			# A Press Pull saved before it could make a new body: editing it switches it over.
			return "There's no body here to join: open this feature (double-click it in the timeline) to make it a new body"
		return "The %s doesn't touch any solid body" % str(LABELS[op]).to_lower()
	var kernel: RefCounted = ctx.kernel
	if op == JOIN:
		# Everything picked merges into the first target, as one body (the others go once it has).
		var merged: RefCounted = kernel.boolean(bodies[targets[0]].shape, tool_shape, KERNEL_OPS[op], feature.id)
		for i in range(1, targets.size()):
			if merged != null and not merged.is_null():
				merged = kernel.boolean(merged, bodies[targets[i]].shape, KERNEL_OPS[op], feature.id)
		if merged == null or merged.is_null():
			return "Join failed: %s" % kernel.get_last_error()
		for i in range(1, targets.size()):
			bodies.erase(targets[i])
		bodies[targets[0]].shape = merged
		return ""
	var results := {}
	for target in targets:
		var result: RefCounted = kernel.boolean(bodies[target].shape, tool_shape, KERNEL_OPS[op], feature.id)
		if result == null or result.is_null():
			return "%s failed: %s" % [LABELS[op], kernel.get_last_error()]
		results[target] = result
	for target in results:
		bodies[target].shape = results[target]
	return ""


## The bodies an operation acts on: the picked ones that still exist, or (none picked) every
## body whose bounds overlap the tool's; solids_only leaves surface bodies out of that (a solid's
## Join, Cut or Intersect takes in a surface only when it is picked). Mesh bodies are never taken
## in by their bounds (a picked one is returned, for apply_shape to refuse).
static func participating(ctx: Dictionary, tool_shape: RefCounted, picked: Array, solids_only := false) -> Array:
	var bodies: Dictionary = ctx.bodies
	var result := []
	if not picked.is_empty():
		for target in picked:
			if not bodies.has(target):
				return []
			result.append(target)
		return result
	var reach: AABB = (tool_shape.bbox() as AABB).grow(1e-7)
	for body_id in bodies:
		if MESH_BODY.is_mesh(bodies[body_id]):
			continue
		if solids_only and bodies[body_id].shape.is_surface():
			continue
		if (bodies[body_id].shape.bbox() as AABB).intersects(reach):
			result.append(body_id)
	return result
