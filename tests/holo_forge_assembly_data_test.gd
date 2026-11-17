extends SceneTree
## Holo Forge Phase 8, Stage 0 (spec 5.1): the assembly data and the empty solve.
##
## 1. A new document has no assembly; normalized({}) fills every key with its default.
## 2. snapshot() / restore() carry the assembly; an older snapshot restores an empty one.
## 3. new_id numbers joints and never reuses an id after a delete.
## 4. Doubles in the assembly survive a text .tscn save and load bit for bit.
## 5. An assembly-only change() re-solves without a rebuild; Undo and Redo restore it.
## 6. CadPart._design_text tells apart two designs that differ only in their assembly.
## 7. xform64: inverse, the Transform3D round trip and small angles.
## 8. An assembly saved by a newer Holo Forge loads, is refused for edits and stays unchanged.
## 9. The skeleton solve honours placements (nested ones compose) and grounding.
## 10. Every C10 sentence exists, and fill() puts values into one.
## 11. Hand edits to the saved assembly (fix round 1). 12. Damaged exact copies, the old format,
##     study keys and renamed ids (fix round 2). 13. Format 2 copies are not read (fix round 3).
##
## godot --headless --path . --script res://tests/holo_forge_assembly_data_test.gd

const XFORM := preload("res://addons/holo_forge/core/assembly/xform64.gd")
const DATA := preload("res://addons/holo_forge/core/assembly/assembly_data.gd")
const SOLVER := preload("res://addons/holo_forge/core/assembly/solver.gd")
const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")
const WORKSPACE := preload("res://addons/holo_forge/ui/forge_workspace.gd")
## Generated scenes go here, never into the project (spec 0.4).
const FIXTURES_DIR := "user://holo_forge_assembly_fixtures"
## Every sentence id of spec C10.
const SENTENCE_IDS := [
	"S-SAME-UNIT", "S-SIDES-SWAPPED", "S-NESTED-MOVES", "S-MESH-SNAP", "S-GROUP-NOT-ROUND", "S-SNAP-LOST",
	"S-WAITING", "S-MISSING-COMPONENT", "S-LIMITS-EQUAL", "S-LOOP-OFF", "S-LOOP-HOLDS", "S-SOLVE-FAULT",
	"S-PLACE-JOINTED", "S-LIMIT", "S-LINK-LIMIT", "S-LINK-SECOND-DRIVER", "S-LINK-CIRCLE", "S-LINK-ZERO",
	"S-STUDY-FOLLOWER", "S-STUDY-CLAMPED", "S-CONTACT-STOP", "S-STUDY-STOP", "S-CONTACT-START",
	"S-CONTACT-NO-SETS", "S-CONTACT-THIN", "S-CONTACT-STEPS", "S-CONTACT-TOO-SLOW", "S-CONTACT-TIMEOUT",
	"S-CONTACT-DEV", "S-CONTACT-SKIPPED", "S-CONTACT-NATIVE", "S-STUDY-TOO-SLOW", "S-MODELLED-VIEW",
	"S-NEWER-ASSEMBLY", "S-BAKE-NO-JOINTS", "S-BAKE-HULL", "S-BAKE-HALF-LIMIT", "S-BAKE-CONE-WIDENED",
	"S-BAKE-NOT-JOLT", "S-BAKE-NOT-BAKED", "S-EXPORT-POSED", "S-PLACE-GROUNDED", "S-NO-COMPONENTS",
	"S-GROUP-SMALL", "S-LIMITS-ORDER", "S-REST-OUTSIDE",
]

var failures: Array[String] = []
var ws: Control
var _saved_files: Array[String] = []


func _init() -> void:
	call_deferred("run")


func run() -> void:
	create_timer(120.0).timeout.connect(func() -> void:
		print("FAIL holo_forge_assembly_data: timed out ", failures)
		quit(1))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(FIXTURES_DIR))
	_case("1 new document and normalized defaults", _check_defaults())
	_case("2 snapshot and restore", _check_snapshot())
	_case("3 new_id", _check_new_id())
	_case("4 text save keeps doubles bit for bit", _check_text_round_trip())
	ws = WORKSPACE.new()
	root.add_child(ws)
	ws.size = Vector2(1200, 800)
	for i in 3:
		await process_frame
	_case("5 assembly-only change re-solves without a rebuild", await _check_workspace_change())
	_case("6 design text sees the assembly", _check_design_text())
	_case("7 xform64", _check_xform64())
	_case("8 newer assembly is read-only", await _check_newer_assembly())
	_case("9 skeleton solve", _check_skeleton_solve())
	_case("10 sentences and fill", _check_sentences())
	_case("11 hand edits to the saved assembly", _check_hand_edits())
	_case("12 damaged copies, old format, keys and renamed ids", _check_exact_matching())
	_case("13 format 2 copies are not read", _check_format_2())
	ws.set_part(null)
	ws.queue_free()
	await process_frame
	for path in _saved_files:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	print("PASS holo_forge_assembly_data: all cases" if failures.is_empty() else "FAIL holo_forge_assembly_data: %d failures" % failures.size())
	quit(0 if failures.is_empty() else 1)


# --- 1 ---------------------------------------------------------------------------------------

func _check_defaults() -> bool:
	var ok := true
	var doc: Resource = DOCUMENT.new()
	ok = _expect(doc.assembly is Dictionary and (doc.assembly as Dictionary).is_empty(), "A new document should have assembly == {} (%s)." % [doc.get("assembly")]) and ok
	var n: Dictionary = DATA.normalized({})
	var expected := {
		"version": 1, "placements": {}, "grounded": {}, "origins": [], "joints": [], "rigid_groups": [], "links": [],
		"contact": {"enabled": false, "tolerance": 1e-5, "step": 1e-3, "precision": 1e-6},
		"contact_sets": [], "studies": [],
		"counters": {"joint": 0, "origin": 0, "group": 0, "link": 0, "contact": 0, "study": 0},
	}
	ok = _expect(n == expected, "normalized({}) should be every C1.2 key at its default (%s)." % [n]) and ok
	ok = _expect(int(n.get("version", 0)) == 1 and DATA.VERSION == 1, "The version should be 1.") and ok
	# Missing keys of entries are filled too, and a joint's DOFs fit its type.
	var partial: Dictionary = DATA.normalized({"joints": [{"id": "joint1", "type": "cylindrical"}], "contact": {"enabled": true}})
	var joint: Dictionary = partial.joints[0]
	ok = _expect((joint.dofs as Array).size() == 2 and joint.has("a") and (joint.a as Dictionary).has("snap") and joint.has("suppressed"),
		"A stored joint should get its missing keys and two DOFs for cylindrical (%s)." % [joint]) and ok
	ok = _expect(bool(partial.contact.enabled) and is_equal_approx(float(partial.contact.step), 1e-3), "A partial contact entry should keep what it has and get the rest.") and ok
	# normalized never changes the dictionary it reads.
	var stored := {"joints": [{"id": "joint1"}]}
	DATA.normalized(stored)
	ok = _expect(stored == {"joints": [{"id": "joint1"}]}, "normalized() should not write into its argument.") and ok
	return ok


# --- 2 ---------------------------------------------------------------------------------------

func _check_snapshot() -> bool:
	var ok := true
	var doc: Resource = DOCUMENT.new()
	var asm: Dictionary = DATA.normalized({})
	asm.placements["comp1"] = XFORM.compose(XFORM.translation(0.01, 0.02, 0.03), XFORM.rot_y(0.4))
	asm.grounded["comp2"] = true
	asm.joints.append({"id": DATA.new_id(asm, "joint"), "name": "Joint1", "type": "revolute"})
	asm = DATA.normalized(asm)
	doc.assembly = asm.duplicate(true)
	var state: Dictionary = doc.snapshot()
	ok = _expect(state.has("assembly") and state.assembly == asm, "snapshot() should hold the assembly.") and ok
	# A deep copy: changing the document afterwards leaves the snapshot alone.
	doc.assembly.grounded["comp3"] = true
	(doc.assembly.joints[0] as Dictionary)["name"] = "Changed"
	ok = _expect(not (state.assembly.grounded as Dictionary).has("comp3") and str(state.assembly.joints[0].name) == "Joint1", "The snapshot should be a deep copy.") and ok
	var other: Resource = DOCUMENT.new()
	other.restore(state)
	ok = _expect(other.assembly == asm, "restore() should bring the assembly back deep-equal.") and ok
	state.assembly.grounded["comp4"] = true
	ok = _expect(not (other.assembly.grounded as Dictionary).has("comp4"), "restore() should copy the assembly, not share it.") and ok
	var old_state: Dictionary = DOCUMENT.new().snapshot()
	old_state.erase("assembly")
	var older: Resource = DOCUMENT.new()
	older.assembly = asm.duplicate(true)
	older.restore(old_state)
	ok = _expect(older.assembly == {}, "Restoring a snapshot without an assembly should give {} (%s)." % [older.assembly]) and ok
	return ok


# --- 3 ---------------------------------------------------------------------------------------

func _check_new_id() -> bool:
	var ok := true
	var asm: Dictionary = DATA.normalized({})
	var first := DATA.new_id(asm, "joint")
	asm.joints.append({"id": first})
	var second := DATA.new_id(asm, "joint")
	asm.joints.append({"id": second})
	ok = _expect(first == "joint1" and second == "joint2", "new_id should give joint1, joint2 (%s, %s)." % [first, second]) and ok
	asm.joints.remove_at(1)
	var third := DATA.new_id(asm, "joint")
	ok = _expect(third == "joint3", "An id should not be reused after a delete (%s)." % third) and ok
	ok = _expect(DATA.new_id(asm, "origin") == "origin1" and DATA.new_id(asm, "group") == "group1" and DATA.new_id(asm, "link") == "link1"
		and DATA.new_id(asm, "contact") == "contact1" and DATA.new_id(asm, "study") == "study1", "Each kind should count on its own.") and ok
	# Ids already in use are skipped, also when the counters were lost.
	var hand := {"joints": [{"id": "joint1"}, {"id": "joint2"}]}
	ok = _expect(DATA.new_id(hand, "joint") == "joint3" and int(hand.counters.joint) == 3, "new_id should skip ids in use (%s)." % [hand.get("counters")]) and ok
	return ok


# --- 4 ---------------------------------------------------------------------------------------

func _check_text_round_trip() -> bool:
	var ok := true
	var rng := RandomNumberGenerator.new()
	rng.seed = 4
	var placement := PackedFloat64Array()
	for i in 12:
		placement.append(_random_double(rng) * 20.0 - 10.0)
	var value := 0.1 + 0.2
	var asm: Dictionary = DATA.normalized({})
	asm.placements["comp1"] = placement
	asm.joints.append(DATA.normalized({"joints": [{"id": "joint1", "name": "Joint1", "type": "revolute"}]}).joints[0])
	asm.joints[0].dofs[0]["value"] = value
	asm.joints[0]["angle"] = 1.0 / 3.0
	asm.contact["tolerance"] = 1e-5
	# Hard cases for text: doubles a float32 holds exactly (Phase 6's form cages came back an ulp
	# off near those), their next doubles up, extremes, subnormals and a negative zero, in a packed
	# array and in a plain Array.
	var f32 := float(PackedFloat32Array([0.1]).to_byte_array().decode_float(0))
	var tricky := PackedFloat64Array([f32, _next_up(f32), _next_up(0.5), 0.5, -0.0, 5e-324, 1e-300, 1.7976931348623157e308,
		123456.789, 2.0 / 3.0, PI, -2.5e-9])
	asm.placements["comp2"] = tricky
	asm.joints[0]["offset"] = [f32, _next_up(f32), _next_up(1.0)]
	var doc: Resource = DOCUMENT.new()
	doc.assembly = asm
	var loaded: Resource = _save_and_load(doc, "assembly_data_round_trip")
	if loaded == null:
		return _expect(false, "The text scene should save and load.")
	var back: Dictionary = loaded.assembly
	var back_placement: Variant = (back.get("placements", {}) as Dictionary).get("comp1")
	ok = _expect(back_placement is PackedFloat64Array, "The placement should load as a PackedFloat64Array (%s)." % type_string(typeof(back_placement))) and ok
	if back_placement is PackedFloat64Array:
		ok = _expect((back_placement as PackedFloat64Array).to_byte_array() == placement.to_byte_array(),
			"The placement's 12 doubles should be bit-identical after a text save (%s vs %s)." % [_hex(back_placement), _hex(placement)]) and ok
	var back_value: float = float(back.joints[0].dofs[0].value)
	ok = _expect(_bits(back_value) == _bits(value), "The DOF value 0.1 + 0.2 should be bit-identical (%s vs %s)." % [_bits(back_value), _bits(value)]) and ok
	ok = _expect(_bits(float(back.joints[0].angle)) == _bits(1.0 / 3.0) and _bits(float(back.contact.tolerance)) == _bits(1e-5),
		"Other doubles in the assembly should be bit-identical too.") and ok
	var back_tricky: Variant = back.placements.get("comp2")
	ok = _expect(back_tricky is PackedFloat64Array and (back_tricky as PackedFloat64Array).to_byte_array() == tricky.to_byte_array(),
		"Hard-case doubles in a packed array should be bit-identical (%s vs %s)." % [_hex(back_tricky) if back_tricky is PackedFloat64Array else str(back_tricky), _hex(tricky)]) and ok
	var back_offset: Array = back.joints[0].offset
	var offset_exact := back_offset.size() == 3
	for i in back_offset.size():
		offset_exact = offset_exact and _bits(float(back_offset[i])) == _bits(float(asm.joints[0].offset[i]))
	ok = _expect(offset_exact, "Hard-case doubles in a plain Array should be bit-identical (%s)." % [back_offset]) and ok
	ok = _expect(back == asm, "The whole assembly should load deep-equal.") and ok
	# The exact doubles travel in the scene; a document without an assembly writes neither key, so
	# its scene text is what it was before Phase 8.
	var text := FileAccess.get_file_as_string(_saved_files[_saved_files.size() - 1])
	ok = _expect(text.contains("assembly_exact = \""), "The scene should hold the assembly's exact doubles.") and ok
	_save_and_load(DOCUMENT.new(), "assembly_data_empty")
	var empty_text := FileAccess.get_file_as_string(_saved_files[_saved_files.size() - 1])
	ok = _expect(not empty_text.contains("assembly"), "A document without an assembly should write no assembly key:\n%s" % empty_text) and ok
	print("  text round trip: placement %s, value %s" % ["exact" if back_placement is PackedFloat64Array and (back_placement as PackedFloat64Array).to_byte_array() == placement.to_byte_array() else "changed", "exact" if _bits(back_value) == _bits(value) else "changed"])
	return ok


# --- 5 ---------------------------------------------------------------------------------------

func _check_workspace_change() -> bool:
	var ok := true
	if not ("assembly_refresh_count" in ws) or not ("assembly_solve" in ws):
		return _expect(false, "The workspace should count _refresh_assembly() calls and keep the solve.")
	var doc: Resource = DOCUMENT.new()
	doc.components = {"comp1": {"name": "Lever", "visible": true, "parent": "", "feature": ""}}
	doc.bodies = {"body1": {"name": "Body1", "visible": true, "locked": false, "feature": "", "component": "comp1"}}
	var part: Node3D = CAD_PART.new()
	part.document = doc
	root.add_child(part)
	ws.set_part(part)
	await process_frame
	var rebuilds: int = ws.rebuild_count
	var refreshes: int = ws.assembly_refresh_count
	var placed := XFORM.compose(XFORM.translation(0.01, -0.002, 0.03), XFORM.rot_z(0.3))
	ws.change("Ground Comp1", func() -> void:
		var asm: Dictionary = DATA.normalized(doc.assembly)
		asm.placements["comp1"] = placed
		asm.grounded["comp1"] = true
		doc.assembly = asm)
	var after: Dictionary = doc.assembly.duplicate(true)
	ok = _expect(ws.rebuild_count == rebuilds, "An assembly-only change should not rebuild (%d rebuilds)." % (ws.rebuild_count - rebuilds)) and ok
	ok = _expect(ws.assembly_refresh_count == refreshes + 1, "An assembly-only change should call _refresh_assembly() once (%d)." % (ws.assembly_refresh_count - refreshes)) and ok
	ok = _expect(str(ws.last_step.get("name", "")) == "Ground Comp1", "The undo step should be named as given (%s)." % ws.last_step.get("name", "")) and ok
	ok = _expect(_pose_bytes(ws.assembly_solve, "poses", "comp1") == placed.to_byte_array() and _pose_bytes(ws.assembly_solve, "body_poses", "body1") == placed.to_byte_array(),
		"The workspace's solve should place the grounded component at its placement.") and ok
	# Undo and Redo (what the editor's history calls).
	ws._apply_snapshot(part, ws.last_step.before)
	ok = _expect(doc.assembly == {}, "Undo should give the empty assembly back (%s)." % [doc.assembly]) and ok
	ok = _expect(_pose_bytes(ws.assembly_solve, "poses", "comp1") == XFORM.identity().to_byte_array(), "After Undo the component should be at identity.") and ok
	ws._apply_snapshot(part, ws.last_step.after)
	ok = _expect(doc.assembly == after, "Redo should bring the assembly back.") and ok
	ok = _expect(_pose_bytes(ws.assembly_solve, "poses", "comp1") == placed.to_byte_array(), "After Redo the component should be placed again.") and ok
	ok = _expect(ws.rebuild_count == rebuilds and ws.assembly_refresh_count == refreshes + 3,
		"Undo and Redo should re-solve without a rebuild (%d rebuilds, %d refreshes)." % [ws.rebuild_count - rebuilds, ws.assembly_refresh_count - refreshes]) and ok
	# A model change still rebuilds.
	ws.change("Units", func() -> void: doc.units = "cm")
	ok = _expect(ws.rebuild_count == rebuilds + 1, "A model change should still rebuild (%d)." % (ws.rebuild_count - rebuilds)) and ok
	ws.set_part(null)
	part.queue_free()
	await process_frame
	return ok


# --- 6 ---------------------------------------------------------------------------------------

func _check_design_text() -> bool:
	var a: Resource = DOCUMENT.new()
	var b: Resource = DOCUMENT.new()
	var same: bool = CAD_PART._design_text(a) == CAD_PART._design_text(b)
	var asm: Dictionary = DATA.normalized({})
	asm.grounded["comp1"] = true
	b.assembly = asm
	var differs: bool = CAD_PART._design_text(a) != CAD_PART._design_text(b)
	return _expect(same and differs, "_design_text should be equal for equal designs (%s) and differ when only the assembly does (%s)." % [same, differs])


# --- 7 ---------------------------------------------------------------------------------------

func _check_xform64() -> bool:
	var ok := true
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var worst_basis := 0.0
	var worst_origin := 0.0
	var worst_relative := 0.0
	for i in 1000:
		var a := _random_rigid(rng, 10.0)
		var product := XFORM.compose(a, XFORM.inverse(a))
		var identity := XFORM.identity()
		for k in 9:
			worst_basis = maxf(worst_basis, absf(product[k] - identity[k]))
		var reach := maxf(1.0, sqrt(a[9] * a[9] + a[10] * a[10] + a[11] * a[11]))
		for k in range(9, 12):
			worst_origin = maxf(worst_origin, absf(product[k]))
			worst_relative = maxf(worst_relative, absf(product[k]) / reach)
	print("  compose(a, inverse(a)) over 1000 rigid transforms: basis off by %s, origin off by %s m (%s relative to the translation)" % [_sci(worst_basis), _sci(worst_origin), _sci(worst_relative)])
	ok = _expect(worst_basis <= 1e-15, "compose(a, inverse(a)) should have an identity basis within 1e-15 (%s)." % _sci(worst_basis)) and ok
	# The origin is checked relative to the translation: with translations up to 10 m the origin
	# is a sum of terms near 10 m that cancel, and one double step there is 1.8e-15 m, so an
	# absolute 1e-15 cannot be met by any double arithmetic (measured: 5.3e-15 m, 4.9e-16 relative).
	ok = _expect(worst_relative <= 1e-15,
		"compose(a, inverse(a)) should have a zero origin within 1e-15 relative to the translation (%s m, %s relative)." % [_sci(worst_origin), _sci(worst_relative)]) and ok
	# Transform3D round trip: float32 to double and back is exact.
	var all_exact := true
	for i in 200:
		var axis := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1))
		if axis.length() < 0.01:
			continue
		var t := Transform3D(Basis(axis.normalized(), rng.randf_range(-PI, PI)), Vector3(rng.randf_range(-10, 10), rng.randf_range(-10, 10), rng.randf_range(-10, 10)))
		if XFORM.to_transform(XFORM.from_transform(t)) != t:
			all_exact = false
	ok = _expect(all_exact, "to_transform(from_transform(t)) should equal t exactly.") and ok
	var small := XFORM.angle_between(XFORM.rot_z(1e-9), XFORM.identity())
	ok = _expect(absf(small - 1e-9) <= 1e-18, "angle_between(rot_z(1e-9), identity) should be 1e-9 within 1e-18 (%s)." % _sci(small)) and ok
	# Large angles, up to a half turn, keep their precision too.
	for angle in [0.5, 2.0, 3.0, PI - 1e-7, PI]:
		var got := XFORM.angle_between(XFORM.identity(), XFORM.compose(XFORM.rot_x(0.3), XFORM.compose(XFORM.rot_y(angle), XFORM.rot_x(-0.3))))
		ok = _expect(absf(got - angle) <= 1e-12, "angle_between should give %s (%s)." % [_sci(angle), _sci(got)]) and ok
	# apply, apply_dir, frame, distance, orthonormalize, is_finite.
	var m := XFORM.compose(XFORM.translation(1.0, 2.0, 3.0), XFORM.rot_z(PI / 2.0))
	var p := XFORM.apply(m, PackedFloat64Array([1.0, 0.0, 0.0]))
	var d := XFORM.apply_dir(m, PackedFloat64Array([1.0, 0.0, 0.0]))
	ok = _expect(absf(p[0] - 1.0) < 1e-15 and absf(p[1] - 3.0) < 1e-15 and absf(p[2] - 3.0) < 1e-15 and absf(d[0]) < 1e-15 and absf(d[1] - 1.0) < 1e-15,
		"apply / apply_dir should turn and move points (%s, %s)." % [p, d]) and ok
	var f := XFORM.frame(PackedFloat64Array([0.05, 0.05, 0.01]), PackedFloat64Array([0.0, 0.0, 2.0]))
	ok = _expect(f.size() == 12 and f[0] == 1.0 and f[1] == 0.0 and f[2] == 0.0 and f[4] == 1.0 and f[8] == 1.0 and f[9] == 0.05 and f[11] == 0.01,
		"frame() with Z = +Z should take part X as X (%s)." % [f]) and ok
	var fx := XFORM.frame(PackedFloat64Array([0.0, 0.0, 0.0]), PackedFloat64Array([1.0, 0.0, 0.0]))
	ok = _expect(fx.size() == 12 and absf(fx[1] - 1.0) < 1e-15 and absf(fx[6] - 1.0) < 1e-15 and XFORM.orthonormal_error(fx) <= 1e-15,
		"frame() with Z = +X should take part Y as X (%s)." % [fx]) and ok
	ok = _expect(XFORM.frame(PackedFloat64Array([0.0, 0.0, 0.0]), PackedFloat64Array([0.0, 0.0, 0.0])).is_empty(), "frame() with no direction should give an empty array.") and ok
	ok = _expect(absf(XFORM.distance(XFORM.translation(1.0, 2.0, 2.0), XFORM.identity()) - 3.0) < 1e-15, "distance() should be the origin distance.") and ok
	var bent := XFORM.rot_y(0.7)
	bent[0] += 1e-6
	bent[4] -= 2e-6
	var fixed := XFORM.orthonormalize(bent)
	ok = _expect(XFORM.orthonormal_error(bent) > 1e-7 and XFORM.orthonormal_error(fixed) <= 1e-15, "orthonormalize() should make a basis orthonormal (%s)." % _sci(XFORM.orthonormal_error(fixed))) and ok
	var bad := XFORM.identity()
	bad[10] = NAN
	ok = _expect(XFORM.is_finite(XFORM.identity()) and not XFORM.is_finite(bad) and not XFORM.is_finite(PackedFloat64Array([1.0])), "is_finite() should check size and values.") and ok
	return ok


# --- 8 ---------------------------------------------------------------------------------------

func _check_newer_assembly() -> bool:
	var ok := true
	var newer := {"version": 2, "placements": {"comp1": XFORM.translation(0.01, 0.0, 0.0)}, "grounded": {}, "something_new": {"kept": 0.1 + 0.2}}
	var doc: Resource = DOCUMENT.new()
	doc.components = {"comp1": {"name": "Lever", "visible": true, "parent": "", "feature": ""}}
	doc.assembly = newer.duplicate(true)
	var loaded: Resource = _save_and_load(doc, "assembly_data_newer")
	if loaded == null:
		return _expect(false, "A document with a version 2 assembly should load.")
	ok = _expect(loaded.assembly == newer, "The newer assembly should load untouched (%s)." % [loaded.assembly]) and ok
	ok = _expect(DATA.is_newer(loaded.assembly) and DATA.edit_refusal(loaded.assembly) == DATA.S_NEWER_ASSEMBLY and DATA.edit_refusal({}) == "",
		"Assembly tools should be refused with S-NEWER-ASSEMBLY on a newer assembly only.") and ok
	var read: Dictionary = DATA.normalized(loaded.assembly)
	ok = _expect(int(read.version) == 2 and read.has("something_new") and read.has("joints"), "normalized() should keep a newer version and its unknown keys.") and ok
	# change() through the workspace is refused and records nothing.
	var part: Node3D = CAD_PART.new()
	part.document = loaded
	root.add_child(part)
	ws.set_part(part)
	await process_frame
	ws.last_step = {}
	var rebuilds: int = ws.rebuild_count
	ws.change("Ground Comp1", func() -> void:
		var asm: Dictionary = loaded.assembly
		asm.grounded["comp1"] = true
		asm["version"] = 1)
	ok = _expect(loaded.assembly == newer, "change() should leave a newer assembly as it was (%s)." % [loaded.assembly]) and ok
	ok = _expect(ws.last_message == DATA.S_NEWER_ASSEMBLY, "change() should say S-NEWER-ASSEMBLY (%s)." % ws.last_message) and ok
	ok = _expect(ws.last_step.is_empty() and ws.rebuild_count == rebuilds, "A refused change should record no undo step and rebuild nothing.") and ok
	ws.set_part(null)
	part.queue_free()
	await process_frame
	var again: Resource = _save_and_load(loaded, "assembly_data_newer_again")
	ok = _expect(again != null and again.assembly == newer, "The newer assembly should be unchanged after another save.") and ok
	return ok


# --- 9 ---------------------------------------------------------------------------------------

func _check_skeleton_solve() -> bool:
	var ok := true
	var rng := RandomNumberGenerator.new()
	rng.seed = 9
	var doc: Resource = DOCUMENT.new()
	doc.components = {
		"comp1": {"name": "Base", "visible": true, "parent": "", "feature": ""},
		"comp2": {"name": "Arm", "visible": true, "parent": "", "feature": ""},
		"comp3": {"name": "Hand", "visible": true, "parent": "comp2", "feature": ""},
		"comp4": {"name": "Finger", "visible": true, "parent": "comp3", "feature": ""},
		"comp5": {"name": "Loose", "visible": true, "parent": "", "feature": ""},
	}
	doc.bodies = {
		"body1": {"name": "Body1", "component": "comp1"}, "body2": {"name": "Body2", "component": "comp2"},
		"body3": {"name": "Body3", "component": "comp3"}, "body4": {"name": "Body4", "component": "comp4"},
		"body5": {"name": "Body5", "component": ""}, "body6": {"name": "Body6", "component": "comp5"},
	}
	var p1 := _random_rigid(rng, 0.5)
	var p2 := _random_rigid(rng, 0.5)
	var p3 := _random_rigid(rng, 0.5)
	var p4 := _random_rigid(rng, 0.5)
	var asm: Dictionary = DATA.normalized({})
	asm.placements = {"comp1": p1, "comp2": p2, "comp3": p3, "comp4": p4}
	asm.grounded = {"comp1": true, "comp3": true}
	doc.assembly = asm
	# A result that also holds a body split off body2 (it follows body2's component).
	var result := {"bodies": {"body2.f7.2": {}}}
	var out: Dictionary = SOLVER.solve(doc, result, null)
	for key in ["poses", "body_poses", "transforms", "joints", "units", "warnings", "ms"]:
		ok = _expect(out.has(key), "The solve output should have \"%s\"." % key) and ok
	if not ok:
		return false
	ok = _expect(out.warnings is PackedStringArray and (out.warnings as PackedStringArray).is_empty() and out.ms is float, "warnings should be an empty PackedStringArray and ms a float (%s)." % [out.warnings]) and ok
	ok = _expect(_pose_bytes(out, "poses", "comp1") == p1.to_byte_array() and _pose_bytes(out, "poses", "comp2") == p2.to_byte_array(),
		"Top-level poses should equal their placements exactly.") and ok
	ok = _expect(_pose_bytes(out, "poses", "comp5") == XFORM.identity().to_byte_array() and not (out.poses as Dictionary).has(""), "A component without a placement sits at identity; the ground is not listed.") and ok
	var p23 := _multiply(p2, p3)
	var p234 := _multiply(p23, p4)
	ok = _expect(_close(out.poses.comp3, p23, 1e-15) and _close(out.poses.comp4, p234, 1e-15), "Nested placements should compose within 1e-15.") and ok
	ok = _expect(_pose_bytes(out, "body_poses", "body1") == p1.to_byte_array() and _pose_bytes(out, "body_poses", "body2") == p2.to_byte_array()
		and _pose_bytes(out, "body_poses", "body2.f7.2") == p2.to_byte_array() and _close(out.body_poses.body4, p234, 1e-15)
		and _pose_bytes(out, "body_poses", "body5") == XFORM.identity().to_byte_array() and _pose_bytes(out, "body_poses", "body6") == XFORM.identity().to_byte_array(),
		"Body poses should be their components' poses (ground bodies at identity).") and ok
	var units: Dictionary = out.units
	ok = _expect(units.size() == 3 and bool(units.comp1.fixed) and not bool(units.comp2.fixed) and str(units.comp2.root) == "comp2" and str(units.comp1.root) == ""
		and not units.has("comp3") and str(units.comp2.reached_by) == "", "Units should be the top-level components; only the grounded one is fixed (%s)." % [units]) and ok
	var transforms: Dictionary = out.transforms
	ok = _expect(transforms.comp2 == XFORM.to_transform(p2) and transforms.comp3 == XFORM.to_transform(p3) and transforms.comp4 == XFORM.to_transform(p4),
		"transforms should be local to the parent component.") and ok
	# An empty assembly puts everything at identity with no warnings.
	doc.assembly = {}
	var empty: Dictionary = SOLVER.solve(doc, {}, null)
	var all_identity := true
	for id in empty.poses:
		all_identity = all_identity and (empty.poses[id] as PackedFloat64Array).to_byte_array() == XFORM.identity().to_byte_array()
	for id in empty.body_poses:
		all_identity = all_identity and (empty.body_poses[id] as PackedFloat64Array).to_byte_array() == XFORM.identity().to_byte_array()
	ok = _expect(all_identity and (empty.poses as Dictionary).size() == 5 and (empty.warnings as PackedStringArray).is_empty(), "An empty assembly should place everything at identity.") and ok
	# A placement that is not a rigid move is not used, and says so.
	var squashed := XFORM.identity()
	squashed[0] = 2.0
	doc.assembly = {"placements": {"comp2": squashed}}
	var warned: Dictionary = SOLVER.solve(doc, {}, null)
	ok = _expect(_pose_bytes(warned, "poses", "comp2") == XFORM.identity().to_byte_array() and (warned.warnings as PackedStringArray).size() == 1
		and str(warned.warnings[0]).contains("Arm"), "A broken placement should be left out with a warning (%s)." % [warned.warnings]) and ok
	return ok


# --- 10 --------------------------------------------------------------------------------------

func _check_sentences() -> bool:
	var ok := true
	var missing := []
	for id in SENTENCE_IDS:
		if not (DATA.SENTENCES as Dictionary).has(id) or str(DATA.SENTENCES[id]).is_empty():
			missing.append(id)
	ok = _expect(missing.is_empty(), "Every C10 sentence should exist (%s)." % [missing]) and ok
	var text: String = DATA.fill(DATA.S_LIMIT, {"Joint": "Joint1", "limit": "90°", "target": "120°"})
	ok = _expect(text == "Joint1 stops at its limit of 90° (asked for 120°).", "fill() should put the values in (%s)." % text) and ok
	return ok


# --- helpers ---------------------------------------------------------------------------------

# --- 13 (fix round 3, PT2) ---------------------------------------------------------------------

## Format 2 ("2:" + base64, written only during fix round 2, never in a user's file) is not read: a
## sound one and a damaged one both leave the numbers as the text gave them, used false, and the
## one note S-EXACT-UNREADABLE saying it is a kind this Holo Forge does not read (never "edited").
## (The run's .err must show no engine decode error.)
func _check_format_2() -> bool:
	var ok := true
	var assembly := {"joints": [{"id": "j", "dofs": [{"value": 0.1 + 0.2}]}], "contact": {"tolerance": 1e-5}}
	var paths := {}
	DATA._collect_paths(assembly, "", paths)
	var sound := "2:" + Marshalls.raw_to_base64(var_to_bytes(paths))
	var flipped := sound.substr(0, 12) + ("A" if sound[12] != "A" else "B") + sound.substr(13)
	var head := _s("S_EXACT_UNREADABLE").get_slice("<", 0)
	for spec in [["sound", sound], ["one character changed", flipped]]:
		var read := {"joints": [{"id": "j", "dofs": [{"value": 0.3}]}], "contact": {"tolerance": 1e-5}}
		var used := DATA.apply_exact(read, str(spec[1]))
		var notes := DATA.load_notes(read)
		print("  13: format 2 %s: used %s, value %s, notes %s" % [spec[0], used, var_to_str(read.joints[0].dofs[0].value), notes])
		ok = _expect(not used and float(read.joints[0].dofs[0].value) == 0.3 and notes.size() == 1 and head != "" and notes[0].begins_with(head)
			and notes[0].contains("kind") and not notes[0].contains("edited"), "13: format 2 %s: not read, one S-EXACT-UNREADABLE note (%s, %s)." % [spec[0], used, notes]) and ok
	return ok


# --- 11 (fix round 1, P5) ----------------------------------------------------------------------

## A hand edit to one number of a saved assembly (2.5 → 2.5000001, within the old 1e-6 match, and
## 2.5 → 3) is kept, every other double still comes back bit for bit (float32-exact values, a
## negative zero, 0.1 + 0.2), and the load leaves S-EXACT-EDITED in the solve's warnings; an
## unedited file leaves no note; the Stage 0 sequential format is still read.
func _check_hand_edits() -> bool:
	var doc: Resource = DOCUMENT.new()
	var assembly: Dictionary = DATA.normalized({})
	assembly.placements["c1"] = PackedFloat64Array([1.0, 0.0, -0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, float(PackedFloat32Array([0.1])[0]), 0.1 + 0.2, -1.0 / 3.0])
	for entry in [["link1", 2.5, 0.1 + 0.2], ["link2", float(PackedFloat32Array([0.3])[0]), -0.0]]:
		assembly.links.append({"id": entry[0], "name": entry[0], "driver": {"joint": "j1", "dof": 0}, "follower": {"joint": "j2", "dof": 0}, "ratio": entry[1], "offset": entry[2]})
	doc.assembly = assembly
	var want: Dictionary = doc.assembly.duplicate(true)
	var path := "%s/hand_edit_%d.tres" % [FIXTURES_DIR, OS.get_process_id()]
	_saved_files.append(path)
	var ok := _expect(ResourceSaver.save(doc, path) == OK, "11: the document should save.")
	var text := FileAccess.get_file_as_string(path)
	ok = _expect(text.contains("\"ratio\": 2.5,") or text.contains("\"ratio\": 2.5\n"), "11: the text holds the ratio 2.5.") and ok
	for edit in [["", 2.5, 0], ["2.5000001", 2.5000001, 1], ["3.0", 3.0, 1]]:
		var edited := text if str(edit[0]) == "" else text.replace("\"ratio\": 2.5", "\"ratio\": " + str(edit[0]))
		var file := FileAccess.open(path, FileAccess.WRITE)
		file.store_string(edited)
		file.close()
		var back: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		var expected := want.duplicate(true)
		expected.links[0]["ratio"] = float(edit[1])
		var diffs := _path_diffs(expected, back.assembly)
		var notes := DATA.load_notes(back.assembly)
		var note := DATA.fill(DATA.S_EXACT_EDITED, {"n": "1 number"})
		var solved := SOLVER.solve(back, {"bodies": {}}, null)
		print("  11: ratio edit '%s': %d diffs %s; notes %s" % [edit[0], diffs.size(), diffs, notes])
		ok = _expect(diffs.is_empty(), "11: edit '%s': every double as expected bit for bit (%s)." % [edit[0], diffs]) and ok
		if int(edit[2]) == 0:
			ok = _expect(notes.is_empty(), "11: an unedited file leaves no note (%s)." % [notes]) and ok
		else:
			ok = _expect(notes.size() == 1 and notes[0] == note and (solved.warnings as PackedStringArray).has(note), "11: edit '%s' leaves \"%s\" (%s; solve %s)." % [edit[0], note, notes, solved.warnings]) and ok
	# The Stage 0 sequential format.
	var old := {"x": 0.1 + 0.2, "y": PackedFloat64Array([-0.0])}
	var values := PackedFloat64Array()
	DATA._collect_doubles(old, values)
	var read := {"x": 0.3, "y": PackedFloat64Array([0.0])}
	var used := DATA.apply_exact(read, Marshalls.raw_to_base64(values.to_byte_array()))
	ok = _expect(used and _bits(float(read.x)) == _bits(0.1 + 0.2) and _bits(float((read.y as PackedFloat64Array)[0])) == _bits(-0.0), "11: the sequential format is still read (%s)." % [read]) and ok
	return ok


## PT2 (fix round 2): damaged exact copies (one character changed, cut short, not base64) leave a
## true note and no engine errors; an edited Stage 0 (sequential) copy keeps the unedited values
## exact with a true note, and one whose numbers were added says every number is at text precision;
## removing a study key and renaming a link id keep every other number exact with no note; a renamed
## and edited link leaves a note for the numbers that lost their copies.
func _check_exact_matching() -> bool:
	var ok := true
	var orig := _exact_fixture()
	var exact := DATA.exact_text(orig)
	var mid := exact.length() / 2
	var damaged := {
		"flip": exact.substr(0, mid) + ("A" if exact[mid] != "A" else "B") + exact.substr(mid + 1),
		"truncate": exact.substr(0, exact.length() - 40),
		"garbage 2": "2:@@@not base64@@@",
		"garbage": "@@@not base64@@@",
	}
	var unreadable := _s("S_EXACT_UNREADABLE").get_slice("<", 0)
	for name in damaged:
		var got := _load_like(orig, func(_a: Dictionary) -> void: pass, damaged[name])
		print("  12: damaged (%s): used %s, notes %s" % [name, got[1], got[2]])
		ok = _expect(not bool(got[1]) and unreadable != "" and (got[2] as PackedStringArray).size() == 1 and str(got[2][0]).begins_with(unreadable),
			"12: a damaged copy (%s) leaves the unreadable note (%s, %s)." % [name, got[1], got[2]]) and ok
	# Stage 0 sequential copies.
	var sequential := PackedFloat64Array()
	DATA._collect_doubles(orig, sequential)
	var old_text := Marshalls.raw_to_base64(sequential.to_byte_array())
	var unedited := _load_like(orig, func(_a: Dictionary) -> void: pass, old_text)
	var same := _path_diffs(orig, unedited[0])
	print("  12: format 1, unedited: %d diffs; notes %s" % [same.size(), unedited[2]])
	ok = _expect(same.is_empty() and (unedited[2] as PackedStringArray).is_empty(), "12: an unedited format 1 copy is exact with no note (%s; %s)." % [same, unedited[2]]) and ok
	var old_note := _s("S_EXACT_OLD")
	for change in ["ratio 3", "a link added"]:
		var mutate := (func(a: Dictionary) -> void: a.links[0]["ratio"] = 3.0) if change == "ratio 3" else (func(a: Dictionary) -> void: (a.links as Array).append({"id": "link9", "ratio": 1.5, "offset": 0.0}))
		var edited := _load_like(orig, mutate, old_text)
		print("  12: format 1, %s: ratio %s; notes %s" % [change, edited[0].links[0].ratio, edited[2]])
		ok = _expect(old_note != "" and edited[2] == PackedStringArray([old_note]) and float(edited[0].links[0].ratio) == (3.0 if change == "ratio 3" else 2.5),
			"12: format 1, %s: the edit is kept and the note says every number is at text precision (%s)." % [change, edited[2]]) and ok
	# Structural edits with the current format.
	var cases := {
		"none": [func(_a: Dictionary) -> void: pass, func(_r: Dictionary) -> void: pass],
		"remove study key 0": [func(a: Dictionary) -> void: (a.studies[0].keys as Array).remove_at(0), func(r: Dictionary) -> void: (r.studies[0].keys as Array).remove_at(0)],
		"rename link id": [func(a: Dictionary) -> void: a.links[0]["id"] = "linkX", func(r: Dictionary) -> void: r.links[0]["id"] = "linkX"],
		"reorder joints": [func(a: Dictionary) -> void: (a.joints as Array).reverse(), func(r: Dictionary) -> void: (r.joints as Array).reverse()],
	}
	for name in cases:
		var got := _load_like(orig, cases[name][0])
		var want := orig.duplicate(true)
		(cases[name][1] as Callable).call(want)
		var d := _path_diffs(want, got[0])
		print("  12: %s: %d diffs %s; notes %s" % [name, d.size(), d.slice(0, 3), got[2]])
		ok = _expect(d.is_empty() and (got[2] as PackedStringArray).is_empty(), "12: %s keeps every number exact with no note (%s; %s)." % [name, d, got[2]]) and ok
	var renamed := _load_like(orig, func(a: Dictionary) -> void:
		a.links[0]["id"] = "linkX"
		a.links[0]["ratio"] = 3.0)
	var unmatched := DATA.fill(_s("S_EXACT_UNMATCHED"), {"m": "2 numbers"})
	print("  12: renamed and edited link: notes %s" % [renamed[2]])
	ok = _expect(_s("S_EXACT_UNMATCHED") != "" and renamed[2] == PackedStringArray([unmatched]), "12: a renamed and edited link leaves \"%s\" (%s)." % [unmatched, renamed[2]]) and ok
	return ok


## An assembly whose doubles need their exact copies (float32-exact values, -0.0, the smallest
## doubles, 0.1 + 0.2), with two joints, a link and a study with keys.
func _exact_fixture() -> Dictionary:
	var f32 := func(x: float) -> float: return float(PackedFloat32Array([x])[0])
	var a: Dictionary = DATA.normalized({})
	a.placements["c1"] = PackedFloat64Array([0.0, 1.0, -0.0, -1.0, 0.0, 0.0, 0.0, -0.0, 1.0, 5e-324, f32.call(0.3), 1e-310])
	for id in ["joint1", "joint2"]:
		a.joints.append({"id": id, "name": id, "type": "revolute", "a": {"component": "c1", "snap": {}}, "b": {"component": "", "snap": {}},
			"dofs": [{"value": 0.1 + 0.2 if id == "joint1" else f32.call(0.7), "min": -0.0, "max": f32.call(1.7), "limited_min": false, "limited_max": false, "rest": 0.0}]})
	a.links.append({"id": "link1", "name": "Link1", "driver": {"joint": "joint1", "dof": 0}, "follower": {"joint": "joint2", "dof": 0}, "ratio": 2.5, "offset": f32.call(0.2)})
	a.studies.append({"id": "study1", "name": "S", "length": 5.0, "fps": 30, "contact": false, "keys": [
		{"time": f32.call(0.1), "joint": "joint1", "dof": 0, "value": f32.call(0.25 + 1e-6)},
		{"time": f32.call(0.6), "joint": "joint1", "dof": 0, "value": f32.call(0.9)},
		{"time": 0.1 + 0.2, "joint": "joint1", "dof": 0, "value": f32.call(1.1)}]})
	a.contact["tolerance"] = f32.call(1e-5)
	return DATA.normalized(a)


## What a text scene gives back for an assembly, then the exact copies applied (the load path):
## [assembly, apply_exact()'s result, its load notes].
func _load_like(orig: Dictionary, mutate: Callable, exact := "") -> Array:
	var text_back: Dictionary = str_to_var(var_to_str(orig))
	mutate.call(text_back)
	var used := DATA.apply_exact(text_back, exact if exact != "" else DATA.exact_text(orig))
	return [text_back, used, DATA.load_notes(text_back)]


## A sentence constant of assembly_data.gd by name ("" when it does not exist yet).
func _s(name: String) -> String:
	return str((DATA as Script).get_script_constant_map().get(name, ""))


## The paths whose doubles differ in bits between two assemblies (or exist in only one).
func _path_diffs(a: Dictionary, b: Dictionary) -> Array:
	var pa := {}
	var pb := {}
	DATA._collect_paths(a, "", pa)
	DATA._collect_paths(b, "", pb)
	var out := []
	for key in pa:
		if not pb.has(key) or var_to_bytes(pa[key]) != var_to_bytes(pb[key]):
			out.append("%s %s vs %s" % [key, var_to_str(pa[key]), var_to_str(pb.get(key))])
	for key in pb:
		if not pa.has(key):
			out.append("%s extra" % key)
	return out


func _case(label: String, passed: bool) -> void:
	print(("PASS holo_forge_assembly_data #%s" if passed else "FAIL holo_forge_assembly_data #%s") % label)


func _expect(ok: bool, detail: String) -> bool:
	if not ok:
		failures.append(detail)
		push_error(detail)
		print("FAIL: ", detail)
	return ok


## A double with all 53 mantissa bits random, in [0, 1).
func _random_double(rng: RandomNumberGenerator) -> float:
	var high := int(rng.randi()) & 0x3FFFFFF
	var low := int(rng.randi()) & 0x7FFFFFF
	return float(high * 134217728 + low) / 9007199254740992.0


## A random rigid transform with a translation of up to reach in each axis.
func _random_rigid(rng: RandomNumberGenerator, reach: float) -> PackedFloat64Array:
	var turn := XFORM.compose(XFORM.rot_z(_random_double(rng) * TAU), XFORM.compose(XFORM.rot_y(_random_double(rng) * TAU), XFORM.rot_x(_random_double(rng) * TAU)))
	var move := XFORM.translation((_random_double(rng) * 2.0 - 1.0) * reach, (_random_double(rng) * 2.0 - 1.0) * reach, (_random_double(rng) * 2.0 - 1.0) * reach)
	return XFORM.compose(move, turn)


## a·b computed here, independently of xform64.gd.
func _multiply(a: PackedFloat64Array, b: PackedFloat64Array) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(12)
	for column in 4:
		for row in 3:
			var sum := 0.0
			for k in 3:
				sum += a[k * 3 + row] * b[column * 3 + k]
			if column == 3:
				sum += a[9 + row]
			out[column * 3 + row] = sum
	return out


func _close(a: Variant, b: PackedFloat64Array, tolerance: float) -> bool:
	if not (a is PackedFloat64Array) or (a as PackedFloat64Array).size() != 12:
		return false
	for i in 12:
		if absf(a[i] - b[i]) > tolerance:
			return false
	return true


func _pose_bytes(out: Dictionary, key: String, id: String) -> PackedByteArray:
	var pose: Variant = (out.get(key, {}) as Dictionary).get(id)
	return (pose as PackedFloat64Array).to_byte_array() if pose is PackedFloat64Array else PackedByteArray()


func _sci(value: float) -> String:
	return String.num_scientific(value)


func _bits(value: float) -> String:
	return PackedFloat64Array([value]).to_byte_array().hex_encode()


## The next double above a positive x.
func _next_up(x: float) -> float:
	var bytes := PackedFloat64Array([x]).to_byte_array()
	bytes.encode_s64(0, bytes.decode_s64(0) + 1)
	return bytes.decode_double(0)


func _hex(values: PackedFloat64Array) -> String:
	return values.to_byte_array().hex_encode()


## Saves doc in a CadPart to a text .tscn under FIXTURES_DIR and loads it back (cache ignored).
func _save_and_load(doc: Resource, file_name: String) -> Resource:
	var part: Node3D = CAD_PART.new()
	part.name = "Part"
	part.document = doc
	var packed := PackedScene.new()
	var packed_error := packed.pack(part)
	part.free()
	if packed_error != OK:
		_expect(false, "Packing the part failed (%s)." % error_string(packed_error))
		return null
	var path := "%s/%s_%d.tscn" % [FIXTURES_DIR, file_name, OS.get_process_id()]
	var save_error := ResourceSaver.save(packed, path)
	_saved_files.append(path)
	if save_error != OK:
		_expect(false, "Saving %s failed (%s)." % [path, error_string(save_error)])
		return null
	var loaded := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	if loaded == null:
		return null
	var node := loaded.instantiate()
	var out: Resource = node.get("document")
	node.free()
	return out
