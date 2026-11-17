extends SceneTree
## Primitives placed far from the origin keep their position in doubles.
##
## Godot's Vector3 is single precision, so a position typed 100 km out used to be rounded to the
## nearest float32 (steps of about 8 mm there) before the kernel saw it. Positions now carry an
## exact copy, "<key>_64" (3 doubles), next to the float32 Vector3; the primitive is built at the
## origin and moved into place with transform_shape64. The float32 value wins whenever the two
## disagree (a handle drag or a hand edit changed it), and no copy is written when the float32
## value is already exact.
##
## godot --headless --path . --script res://tests/holo_forge_primitive_far_test.gd

const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const REGEN := preload("res://addons/holo_forge/core/regen.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")
const POINT64 := preload("res://addons/holo_forge/core/point64.gd")
const XFORM := preload("res://addons/holo_forge/core/assembly/xform64.gd")
const PRIMITIVE_COMMAND := preload("res://addons/holo_forge/tools/primitive_command.gd")
const FEATURE_COMMAND := preload("res://addons/holo_forge/tools/feature_command.gd")

## 100 km out on X and Z, 33 km on Y, with digits float32 can't hold.
const FAR := [100000.0123456, -33000.0004321, 99999.9876543]
## Bounding boxes of the same body at the origin and far out (moved back in doubles) must agree
## to this (meters). A float32 position 100 km out is off by up to about 4e-3 m.
const BOX_TOLERANCE := 1e-7

var failures: Array[String] = []
var kernel
var doc


func _init() -> void:
	call_deferred("run")


func run() -> void:
	kernel = REGEN.make_kernel()
	_expect(kernel != null and kernel.has_method("transform_shape64"), "The native kernel with transform_shape64 should load.")
	if kernel != null and kernel.has_method("transform_shape64"):
		_check_point64()
		_check_far_primitives()
		_check_old_and_edited()
		_check_commands()
	print("PASS holo_forge_primitive_far: box, cylinder, sphere, torus and coil 100 km out sit where typed (in doubles), old and hand-edited positions still build, and the commands keep the exact copy" \
		if failures.is_empty() else "FAIL holo_forge_primitive_far")
	quit(0 if failures.is_empty() else 1)


# --- POINT64 ---------------------------------------------------------------------------------

func _check_point64() -> void:
	var values := {"position": Vector3(1, 2, 3)}
	var e := POINT64.exact(values, "position")
	_expect(e == PackedFloat64Array([1.0, 2.0, 3.0]), "A plain Vector3 should read as its own doubles, got %s." % e)
	POINT64.set_axis(values, "position", 0, FAR[0])
	e = POINT64.exact(values, "position")
	_expect(e[0] == FAR[0] and e[1] == 2.0 and e[2] == 3.0, "set_axis should keep the typed double, got %s." % e)
	_expect((values.position as Vector3).x == float(Vector3(FAR[0], 0, 0).x), "set_axis should keep the float32 Vector3 in step.")
	# A handle drag sets only the Vector3: the stale copy is ignored.
	values.position = Vector3(5, 2, 3)
	_expect(POINT64.exact(values, "position") == PackedFloat64Array([5.0, 2.0, 3.0]), "A changed Vector3 should win over a stale exact copy.")
	var options := {}
	POINT64.store(options, "position", {"position": Vector3(0.25, 0.5, 0)})
	_expect(not options.has("position" + POINT64.SUFFIX), "No exact copy should be stored when the float32 value is already exact.")
	var far := {}
	POINT64.set_axis(far, "position", 2, FAR[2])
	POINT64.store(options, "position", far)
	_expect(options.has("position" + POINT64.SUFFIX) and (options["position" + POINT64.SUFFIX] as PackedFloat64Array)[2] == FAR[2], "The exact copy should be stored when float32 rounds the value.")
	var broken := {"position": Vector3(1, 1, 1), "position_64": PackedFloat64Array([NAN, 1, 1])}
	_expect(POINT64.exact(broken, "position") == PackedFloat64Array([1.0, 1.0, 1.0]), "A non-finite exact copy should be ignored.")


# --- Far primitives --------------------------------------------------------------------------

func _new_doc() -> void:
	doc = DOCUMENT.new()


func _add(type: String, inputs: Dictionary, at: PackedFloat64Array, exact := true) -> Resource:
	var made := {}
	for key in inputs:
		var spec = inputs[key]
		made[key] = doc.make_input(spec[0], spec[1]) if spec is Array else doc.make_input(str(spec), "length")
	var options := {"position": Vector3(at[0], at[1], at[2]), "operation": OPERATIONS.NEW_BODY}
	if exact:
		options["position" + POINT64.SUFFIX] = at.duplicate()
	var feature: Resource = doc.add_feature(type, type.capitalize(), made, options)
	feature.options["body_id"] = doc.new_body(feature.id)
	return feature


## The body's bounding box after moving it by -at in doubles (so it reads near the origin).
func _local_box(feature: Resource, at: PackedFloat64Array) -> Variant:
	var result: Dictionary = REGEN.rebuild(doc, kernel)
	var body_id: String = feature.options.body_id
	if not result.bodies.has(body_id):
		failures.append("%s: no body (%s)." % [feature.type, result.errors.get(feature.id, "")])
		return null
	var back: RefCounted = kernel.call("transform_shape64", result.bodies[body_id].shape, XFORM.translation(-at[0], -at[1], -at[2]), "check")
	if back == null:
		failures.append("%s: moving back failed: %s" % [feature.type, kernel.get_last_error()])
		return null
	return {"box": back.bbox(), "names": result.bodies[body_id].shape.get_face_names(), "volume": back.volume()}


func _check_far_primitives() -> void:
	var cases := [
		["box", {"length": "10 mm", "height": "20 mm", "width": "30 mm"}],
		["cylinder", {"diameter": "10 mm", "height": "20 mm"}],
		["sphere", {"diameter": "10 mm"}],
		["torus", {"diameter": "20 mm", "section": "4 mm"}],
		["coil", {"diameter": "20 mm", "turns": ["3", "number"], "height": "15 mm", "section_size": "2 mm"}],
	]
	var far := PackedFloat64Array(FAR)
	var zero := PackedFloat64Array([0.0, 0.0, 0.0])
	for c in cases:
		_new_doc()
		var near_feature := _add(c[0], c[1], zero)
		var near = _local_box(near_feature, zero)
		_new_doc()
		var far_feature := _add(c[0], c[1], far)
		var away = _local_box(far_feature, far)
		if near == null or away == null:
			continue
		var a: AABB = near.box
		var b: AABB = away.box
		var off := maxf((a.position - b.position).abs()[(a.position - b.position).abs().max_axis_index()], (a.end - b.end).abs()[(a.end - b.end).abs().max_axis_index()])
		_expect(off <= BOX_TOLERANCE, "%s 100 km out should sit where typed: its box is %s m off the same %s at the origin (limit %s m)." % [c[0], str(off), c[0], str(BOX_TOLERANCE)])
		_expect(absf(float(near.volume) - float(away.volume)) <= 1e-6 * absf(float(near.volume)), "%s 100 km out should keep its volume (%s against %s m3)." % [c[0], str(away.volume), str(near.volume)])
		_expect(near.names == away.names, "%s 100 km out should keep its face names (%s against %s)." % [c[0], away.names, near.names])


func _check_old_and_edited() -> void:
	# A document saved before the exact copy existed: the Vector3 alone.
	_new_doc()
	var old := _add("box", {"length": "10 mm", "height": "20 mm", "width": "30 mm"}, PackedFloat64Array([0.1, 0.0, 0.0]), false)
	var got = _local_box(old, PackedFloat64Array([0.0, 0.0, 0.0]))
	if got != null:
		var b: AABB = got.box
		_expect(b.position.distance_to(Vector3(0.095, 0, -0.015)) < 1e-7 and b.size.distance_to(Vector3(0.01, 0.02, 0.03)) < 1e-7, "An old box at (0.1, 0, 0) should build as before, got %s." % b)
	# A hand edit of the Vector3 with a stale exact copy: the Vector3 wins.
	_new_doc()
	var edited := _add("box", {"length": "10 mm", "height": "20 mm", "width": "30 mm"}, PackedFloat64Array(FAR))
	edited.options["position"] = Vector3(1, 2, 3)
	got = _local_box(edited, PackedFloat64Array([1.0, 2.0, 3.0]))
	if got != null:
		var b: AABB = got.box
		_expect(b.position.distance_to(Vector3(-0.005, 0, -0.015)) < 1e-6, "A hand-edited position should win over a stale exact copy, got %s." % b)


# --- Commands --------------------------------------------------------------------------------

func _check_commands() -> void:
	_new_doc()
	var command = PRIMITIVE_COMMAND.new("box")
	var values: Dictionary = command.defaults()
	for axis in 3:
		POINT64.set_axis(values, "position", axis, FAR[axis])
	var feature: Resource = command.create_feature(doc, values)
	var stored: Variant = feature.options.get("position" + POINT64.SUFFIX)
	_expect(stored is PackedFloat64Array and stored == PackedFloat64Array(FAR), "The Box command should store the exact position, got %s." % [stored])
	var back: Dictionary = command.read_values()
	_expect(POINT64.exact(back, "position") == PackedFloat64Array(FAR), "The Box command should read the exact position back, got %s." % POINT64.exact(back, "position"))
	# Generic feature command (Torus).
	_new_doc()
	var torus = FEATURE_COMMAND.new("torus")
	var tv: Dictionary = torus.defaults()
	for axis in 3:
		POINT64.set_axis(tv, "position", axis, FAR[axis])
	var tf: Resource = torus.create_feature(doc, tv)
	stored = tf.options.get("position" + POINT64.SUFFIX)
	_expect(stored is PackedFloat64Array and stored == PackedFloat64Array(FAR), "The Torus command should store the exact position, got %s." % [stored])
	torus.feature = tf
	var tback: Dictionary = torus.read_values()
	_expect(POINT64.exact(tback, "position") == PackedFloat64Array(FAR), "The Torus command should read the exact position back, got %s." % POINT64.exact(tback, "position"))


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		print("  fail: " + message)
