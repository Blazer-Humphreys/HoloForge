extends SceneTree
## Holo Forge documents: parameter expressions keep their units (a bare 20 is 20 mm, "width + 5"
## reads the 5 as mm, angles default to degrees); user parameters resolve in any order and cycles
## are reported; the timeline rebuilds through the kernel (new body, cut, rollback, suppress,
## errors); snapshots undo and redo independently; and a document saves and loads back the same.
##
## godot --headless --path . --script res://tests/holo_forge_document_test.gd

const UNITS := preload("res://addons/holo_forge/core/units.gd")
const PARAMETERS := preload("res://addons/holo_forge/core/parameters.gd")
const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const REGEN := preload("res://addons/holo_forge/core/regen.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("run")


func run() -> void:
	_check_units()
	_check_parameters()
	_check_timeline()
	_check_save_load()
	print("PASS holo_forge_document: unit-aware expressions, parameter order and cycles, timeline rebuild (new body, cut, rollback, suppress, errors), snapshots, save/load." \
		if failures.is_empty() else "FAIL holo_forge_document")
	quit(0 if failures.is_empty() else 1)


func _check_units() -> void:
	var width := {"value": 0.02, "l": 1, "a": 0}
	var vars := {"width": width, "count": {"value": 4.0, "l": 0, "a": 0}}
	for case in [
		["20", "length", 0.02], ["20 mm + 1 cm", "length", 0.03], ["width * 2", "length", 0.04],
		["width + 5", "length", 0.025], ["2 in", "length", 0.0508], ["45", "angle", PI / 4.0],
		["sin(30) * 10", "length", 0.005], ["count * 10", "length", 0.04], ["(width + 1mm) / 3", "length", 0.007],
		["sqrt(width * width)", "length", 0.02], ["max(width, 30)", "length", 0.03], ["1.5e1", "length", 0.015],
		["PI * 2 rad", "angle", TAU], ["2 ^ 3", "number", 8.0],
	]:
		var r := UNITS.evaluate(case[0], case[1], "mm", vars)
		_expect(r.ok and absf(float(r.value) - float(case[2])) < 1e-9, "'%s' as %s should be %s (got %s)" % [case[0], case[1], case[2], r])
	for bad in [["10 / 0", "length"], ["width + 5 deg", "length"], ["foo * 2", "length"], ["width", "angle"], ["(2", "length"], ["", "length"]]:
		var r := UNITS.evaluate(bad[0], bad[1], "mm", vars)
		_expect(not r.ok and str(r.error) != "", "'%s' as %s should be an error (got %s)" % [bad[0], bad[1], r])
	_expect(UNITS.format_value(0.025, "length", "mm") == "25 mm", "0.025 m should display as 25 mm (got %s)" % UNITS.format_value(0.025, "length", "mm"))
	_expect(UNITS.format_value(PI / 2.0, "angle", "mm") == "90 deg", "PI/2 should display as 90 deg")
	var inch := UNITS.evaluate("2", "length", "in", {})
	_expect(inch.ok and absf(float(inch.value) - 0.0508) < 1e-9, "A bare 2 in an inch document should be 2 in")


func _check_parameters() -> void:
	var doc: Resource = DOCUMENT.new()
	doc.user_parameters.append({"name": "deck", "unit": "mm", "expression": "rail * 3", "comment": "", "favorite": false})
	doc.user_parameters.append({"name": "rail", "unit": "mm", "expression": "10", "comment": "", "favorite": false})
	doc.user_parameters.append({"name": "loop_a", "unit": "mm", "expression": "loop_b", "comment": "", "favorite": false})
	doc.user_parameters.append({"name": "loop_b", "unit": "mm", "expression": "loop_a", "comment": "", "favorite": false})
	var values := PARAMETERS.evaluate(doc)
	_expect(values.deck.ok and absf(float(values.deck.value) - 0.03) < 1e-9, "deck = rail * 3 should resolve after rail (got %s)" % values.deck)
	_expect(not values.loop_a.ok and not values.loop_b.ok, "A circular reference should be an error on both parameters")
	_expect(PARAMETERS.is_valid_name(doc, "track_width") and not PARAMETERS.is_valid_name(doc, "rail") and not PARAMETERS.is_valid_name(doc, "mm") and not PARAMETERS.is_valid_name(doc, "2x"),
		"Parameter names must be new identifiers that are not units")


func _check_timeline() -> void:
	var kernel := REGEN.make_kernel()
	_expect(kernel != null, "The native kernel should load for timeline tests.")
	if kernel == null:
		return
	var doc: Resource = DOCUMENT.new()
	doc.user_parameters.append({"name": "size", "unit": "mm", "expression": "100", "comment": "", "favorite": false})
	var box := _add_box(doc, "size", "size / 2", "size", Vector3.ZERO)
	var cut: Resource = doc.add_feature("cylinder", "Cylinder", {"diameter": doc.make_input("20", "length"), "height": doc.make_input("200", "length")},
		{"operation": OPERATIONS.CUT, "targets": [box.options.body_id], "position": Vector3(0, -0.05, 0)})
	var result := REGEN.rebuild(doc, kernel)
	var expected := 0.1 * 0.05 * 0.1 - PI * 0.01 * 0.01 * 0.05
	_expect(result.errors.is_empty() and result.bodies.size() == 1, "Box then cut should give one body without errors (%s)" % result.errors)
	_expect(_volume(result, box.options.body_id) > 0.0 and absf(_volume(result, box.options.body_id) - expected) < 1e-9,
		"The cut box should have volume %f (got %f)" % [expected, _volume(result, box.options.body_id)])

	doc.rollback = 1
	result = REGEN.rebuild(doc, kernel)
	_expect(absf(_volume(result, box.options.body_id) - 0.0005) < 1e-9, "Rolled back before the cut, the box should be whole.")
	doc.rollback = -1
	cut.suppressed = true
	result = REGEN.rebuild(doc, kernel)
	_expect(absf(_volume(result, box.options.body_id) - 0.0005) < 1e-9, "A suppressed cut should not change the box.")
	cut.suppressed = false

	# A new feature added while rolled back lands at the marker.
	doc.rollback = 1
	var sphere: Resource = doc.add_feature("sphere", "Sphere", {"diameter": doc.make_input("10", "length")}, {"operation": OPERATIONS.NEW_BODY, "position": Vector3(1, 0, 0)})
	sphere.options.body_id = doc.new_body(sphere.id)
	_expect(doc.feature_index(sphere.id) == 1 and doc.rollback == 2, "A feature added while rolled back should land at the marker.")
	doc.rollback = -1

	doc.user_parameters[0].expression = "-5"
	result = REGEN.rebuild(doc, kernel)
	_expect(result.errors.has(box.id), "A negative box size should be reported on the box feature.")
	_expect(result.errors.has(cut.id), "The cut should report that its target body is missing.")
	_expect(result.bodies.has(sphere.options.body_id), "Later independent features still build after an error.")
	doc.user_parameters[0].expression = "100"

	# Snapshots are independent copies: undo restores, redo reapplies.
	var before: Dictionary = doc.snapshot()
	_add_box(doc, "10", "10", "10", Vector3(0, 0.2, 0))
	var after: Dictionary = doc.snapshot()
	doc.restore(before)
	_expect(doc.features.size() == 3, "Undo (restore before) should remove the new feature.")
	doc.restore(after)
	_expect(doc.features.size() == 4 and REGEN.rebuild(doc, kernel).bodies.size() == 3, "Redo (restore after) should bring it back.")
	doc.features[0].set_expression("length", "999")
	_expect((after.features[0] as Resource).expression("length") == "size", "Editing the document must not change a snapshot.")


func _check_save_load() -> void:
	var doc: Resource = DOCUMENT.new()
	doc.units = "in"
	doc.user_parameters.append({"name": "w", "unit": "in", "expression": "2", "comment": "deck", "favorite": true})
	_add_box(doc, "w", "1", "3", Vector3(0.1, 0, 0))
	doc.named_views["Side"] = {"target": Vector3.ONE, "yaw": 0.5, "pitch": -0.2, "distance": 3.0, "ortho": true}
	var path := "user://holo_forge_document_test.tres"
	_expect(ResourceSaver.save(doc, path) == OK, "The document should save.")
	var loaded: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	var same: bool = loaded != null and loaded.units == "in" and loaded.features.size() == 1 \
		and loaded.features[0].expression("length") == "w" and loaded.features[0].options.position == Vector3(0.1, 0, 0) \
		and loaded.user_parameters[0].comment == "deck" and loaded.named_views.Side.ortho == true and loaded.bodies.size() == 1
	_expect(same, "The document should load back the same.")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _add_box(doc: Resource, length: String, height: String, width: String, position: Vector3) -> Resource:
	var feature: Resource = doc.add_feature("box", "Box", {
		"length": doc.make_input(length, "length"), "height": doc.make_input(height, "length"), "width": doc.make_input(width, "length"),
	}, {"operation": OPERATIONS.NEW_BODY, "position": position})
	feature.options.body_id = doc.new_body(feature.id)
	return feature


func _volume(result: Dictionary, body_id: String) -> float:
	return float(result.bodies[body_id].shape.volume()) if result.bodies.has(body_id) else -1.0


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)
		print("FAIL: ", message)
