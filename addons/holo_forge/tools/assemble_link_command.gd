@tool
extends "res://addons/holo_forge/tools/assemble_command.gd"
## Motion Link (spec 3.8): one joint DOF follows another, follower = ratio · driver + offset (C4.3).
##
## Driver and Follower pick a joint DOF each ("<joint id>|<dof>"); Ratio is a plain number. The
## offset is taken from the stored values, so making the link moves nothing. Refused, in the
## status row with OK off: ratio 0 (S-LINK-ZERO), a DOF following itself (S-LINK-SELF), a second
## driver (S-LINK-SECOND-DRIVER), a circle (S-LINK-CIRCLE), a link whose tree the limits leave no
## value (S-LINK-EMPTY-NEW) and a ratio that is not finite (S-RATIO-NOT-FINITE) (motion.gd
## link_refusal()).
##
## Test (spec 3.8): a value of the driver, with a slider over its range (dof_range()). Moving it
## drives the driver there with the link as it would be made, so the follower moves too; it is
## view-only: OK stores only the link, and the view goes back to the stored poses. The test does
## not stop at contact sets (a note says so when they are on); limits hold as in a drive.

const TEST_KEY := "test"
const S_TEST_NO_CONTACT := "Test shows the link only: it does not stop where the contact sets' bodies touch."

## The driver ("<joint>|<dof>") the Test row is set up for.
var _test_driver := ""
## The Test slider's span per driver ("<joint>|<dof>" -> PackedFloat64Array [low, high]).
var _test_spans := {}


func title() -> String:
	return "Motion Link"


func action_name() -> String:
	return "Motion Link"


## Every joint DOF as an option: ["<joint>|<dof>", "<Joint name> <DOF label>"].
func _dof_options() -> Array:
	var out := []
	for joint in _stored_assembly().joints:
		if not (joint is Dictionary):
			continue
		var names := DATA.dof_names(str(joint.get("type", "")))
		for i in names.size():
			var label := str(joint.get("name", joint.id))
			if names.size() > 1:
				label += " " + str(UI.DOF_LABELS.get(names[i], names[i]))
			out.append(["%s|%d" % [str(joint.id), i], label])
	return out


func fields() -> Array[Dictionary]:
	var options := _dof_options()
	var out: Array[Dictionary] = [
		{"key": "driver", "label": "Driver", "type": "enum", "options": options},
		{"key": "follower", "label": "Follower", "type": "enum", "options": options, "default": options[1][0] if options.size() > 1 else null},
		{"key": "ratio", "label": "Ratio", "type": "expression", "kind": UNITS.KIND_NUMBER, "default": 1.0},
	]
	var test := _test_field(str(current_values.get("driver", options[0][0] if not options.is_empty() else "")))
	if not test.is_empty():
		out.append(test)
	out.append(UI.status_field())
	return out


## The Test row for a driver ({} when it is not a joint DOF): an angle or a length, at the driver's
## value now, with a slider over its range.
func _test_field(driver: String) -> Dictionary:
	if workspace == null or workspace.doc == null:
		return {}
	var node := node_of(driver)
	var joint := entry_of(_stored_assembly(), "joints", str(node.joint))
	var names := DATA.dof_names(str(joint.get("type", "")))
	if joint.is_empty() or int(node.dof) >= names.size():
		return {}
	var value := _driver_value(node)
	if not _test_spans.has(driver):
		_test_spans[driver] = dof_range(joint, int(node.dof), value)
	var span: PackedFloat64Array = _test_spans[driver]
	return {
		"key": TEST_KEY, "label": "Test", "type": "expression", "kind": UI.dof_kind(str(names[int(node.dof)])), "default": value,
		"slider": {"min": span[0], "max": span[1], "tooltip": "Drag to try the link: the driver moves and the follower follows it. Nothing is stored."},
	}


## Where a driver DOF is now (the stored solve's value, which is clamped).
func _driver_value(node: Dictionary) -> float:
	var id := str(node.joint)
	var solved: Dictionary = (workspace.assembly_solve.get("joints", {}) as Dictionary).get(id, {})
	var values: PackedFloat64Array = solved.get("values", JOINT_MATH.joint_values(entry_of(_stored_assembly(), "joints", id)))
	return values[int(node.dof)] if int(node.dof) < values.size() else 0.0


func defaults() -> Dictionary:
	var options := _dof_options()
	_test_driver = str(options[0][0]) if not options.is_empty() else ""
	return values_for({})


func write_values(_doc: Resource, values: Dictionary) -> void:
	var driver := str(values.get("driver", ""))
	if driver != _test_driver and driver != "" and workspace != null:
		# Another driver: the Test row is set up again for it (an angle or a length, its own
		# range), at its value now.
		_test_driver = driver
		current_values = values.duplicate(true)
		values.erase(TEST_KEY)
		var test := _test_field(driver)
		if not test.is_empty():
			remember(values, TEST_KEY, float(test.default), str(test.kind))
		current_values = values.duplicate(true)
		workspace.panel.setup(title(), fields(), values, doc_units())
		workspace.call_deferred("place_panel")
	current_values = values.duplicate(true)


## A "<joint>|<dof>" value as {"joint", "dof"}.
static func node_of(value: Variant) -> Dictionary:
	var parts := str(value).split("|")
	return {"joint": parts[0], "dof": int(parts[1]) if parts.size() > 1 else 0}


## A Ratio that is not finite (only code or a stored value can give one) gets link_refusal()'s own
## sentence, S-RATIO-NOT-FINITE, instead of the general field one.
func finite_refusal() -> String:
	if _shown.has("ratio") and str(_shown.ratio[0]) == str(current_values.get("ratio", "")) and not is_finite(float(_shown.ratio[1])):
		return DATA.S_RATIO_NOT_FINITE
	return super()


func check() -> void:
	if _dof_options().size() < 2:
		prompt = "A link needs two joint motions. Make the joints first."
		return
	var ratio := value_of(current_values, "ratio", UNITS.KIND_NUMBER, 0.0)
	refusal = MOTION.link_refusal(_stored_assembly(), node_of(current_values.get("driver")), node_of(current_values.get("follower")), ratio)
	if refusal == "":
		_test(ratio)


## Shows the Test value: the driver driven there with the link made (view-only). Nothing shows
## while Test is at the driver's value now.
func _test(ratio: float) -> void:
	var driver := node_of(current_values.get("driver"))
	var test := _test_field(str(current_values.get("driver", "")))
	if test.is_empty():
		return
	var now := _driver_value(driver)
	var target := value_of(current_values, TEST_KEY, str(test.kind), now)
	if target == now:
		return
	var candidate := _stored_assembly()
	if not MOTION.new_link(candidate, driver, node_of(current_values.get("follower")), ratio).has("link"):
		return
	candidate = DATA.normalized(candidate)
	var doc: Resource = workspace.doc
	var kept: Dictionary = doc.assembly
	doc.assembly = candidate
	var out := MOTION.drive(doc, workspace.result, workspace.kernel, str(driver.joint), int(driver.dof), target, {"contact": false})
	doc.assembly = kept
	if bool(out.get("refused", false)) and str(out.get("stopped_by", "")) == "":
		if str(out.get("sentence", "")) != "":
			notes.append(str(out.sentence))
		return
	var working := candidate.duplicate(true)
	for id in out.get("values", {}):
		var moved := entry_of(working, "joints", str(id))
		var list: PackedFloat64Array = out.values[id]
		for d in mini(list.size(), (moved.get("dofs", []) as Array).size()):
			moved.dofs[d]["value"] = list[d]
	if str(out.get("sentence", "")) != "":
		notes.append(str(out.sentence))
	if bool((candidate.get("contact", {}) as Dictionary).get("enabled", false)):
		notes.append(S_TEST_NO_CONTACT)
	show_solve(solve_with(working), working)


func apply_document(doc: Resource) -> void:
	var stored := _stored_assembly()
	var made := MOTION.new_link(stored, node_of(current_values.get("driver")), node_of(current_values.get("follower")), value_of(current_values, "ratio", UNITS.KIND_NUMBER, 0.0))
	if made.has("link"):
		doc.assembly = DATA.normalized(stored)
