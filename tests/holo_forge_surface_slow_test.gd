extends SceneTree
## Holo Forge Phase 5 checks that take OCCT over a minute, kept out of holo_forge_surface_test.gd:
## - a G1 box dome extended 1 mm square to it on all four edges thickens 0.1 mm (OCCT's offset of it
##   joins its seams slowly; a fine mesh of the offset breaks up, so Thicken takes the solid's volume
##   against what its faces sweep, and the mesh only when that disagrees): the solid holds area x t
##   within 2 %;
## - lens caps (ellipse, slot, egg) 0.5, 10 and 500 mm long have their rims extended square to them,
##   tangent and naturally to their full width all round (round 6: square bands were 12 % narrow at
##   an ellipse cap's ends);
## - Untrim Outer on a half cylinder cut by a tilted plane, joined to the plane's piece: the lines
##   carrying the joint on keep to the cylinder (round 7: OCCT's default fit left them 2 um off).
##
## godot --headless --path . --script res://tests/holo_forge_surface_slow_test.gd

const REGEN := preload("res://addons/holo_forge/core/regen.gd")

const MM := 1e-3
const MM2 := 1e-6
const MM3 := 1e-9

var failures: Array[String] = []
var kernel


func _init() -> void:
	call_deferred("run")


func run() -> void:
	kernel = REGEN.make_kernel()
	_expect(kernel != null, "The native kernel should load.")
	if kernel != null:
		_check_banded_dome()
		_check_lens_bands()
		_check_untrim_lines()
	if failures.is_empty():
		print("PASS holo_forge_surface_slow: a G1 box dome with perpendicular bands thickens 0.1 mm to area x t within 2 %; lens caps' bands keep their full width in every mode at 0.5, 10 and 500 mm; untrimmed lines keep to their cylinder")
	else:
		for failure in failures:
			print("  - ", failure)
		print("FAIL holo_forge_surface_slow")
	quit(0 if failures.is_empty() else 1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


## A half cylinder (r 5 mm, 10 mm tall) cut by a plane tilted 30 deg through z = 5 mm, sewn to the
## plane's half-ellipse along the cut: Untrim Outer on the cylinder face carries the joint (a
## slanted edge) on along its tangents to the face's natural bounds. Those lines are made on the
## cylinder and their curves fitted to a billionth of the face's size (OCCT's default fit, 10 um,
## left them 2 um off it).
func _check_untrim_lines() -> void:
	var tilt := Vector3(0, -sin(deg_to_rad(30.0)), cos(deg_to_rad(30.0)))
	var arc = kernel.sketch_edges([{"type": "arc", "c": Vector2.ZERO, "r": 5 * MM, "a0": 0.0, "a1": PI}], Transform3D.IDENTITY)
	var strip = kernel.extrude(arc, {"direction": Vector3(0, 0, 1), "distance": 10 * MM, "surface": true})
	var below = kernel.trim(strip, kernel.plane_face(Vector3(0, 0, 5) * MM, tilt, 0.1, "t"), PackedVector3Array([Vector3(0, 5, 9.9) * MM]), {})
	var lid = kernel.trim(kernel.plane_face(Vector3(0, 0, 5) * MM, tilt, 0.02, "l"), kernel.make_cylinder(5 * MM, 40 * MM, Vector3(0, 0, -20) * MM, Vector3(0, 0, 1), "c"), PackedVector3Array(), {})
	var inner = null
	for piece in kernel.pieces(lid) if lid != null else []:
		var middle: Vector3 = (piece.bbox() as AABB).get_center()
		inner = piece if Vector2(middle.x, middle.y).length() < 1 * MM and piece.area() < 1e-4 else inner
	var half = kernel.trim(inner, kernel.plane_face(Vector3.ZERO, Vector3(0, 1, 0), 0.1, "h"), PackedVector3Array([Vector3(0, -2, 5) * MM]), {}) if inner != null else null
	var sheet = kernel.stitch([below, half], {"tolerance": 1e-6, "solid": false}) if below != null and half != null else null
	_expect(sheet != null and kernel.pieces(sheet).size() == 1, "The cut half cylinder and the plane's half-ellipse should stitch into one sheet (%s)." % kernel.get_last_error())
	if sheet == null:
		return
	var face := -1
	for f in sheet.face_count():
		face = f if str(sheet.face_info(f).type) == "cylinder" else face
	var grown = kernel.untrim(sheet, PackedInt32Array([face]), PackedInt32Array(), {"mode": "outer", "extend": 2 * MM})
	_expect(grown != null, "Untrim Outer on the joined half cylinder should build (%s)." % kernel.get_last_error())
	if grown == null:
		return
	var worst := 0.0
	var lines := 0
	for e in grown.edge_count():
		var info: Dictionary = grown.edge_info(e)
		if not (str(info.get("type", "")) in ["bspline", "other"]):
			continue
		var on_cylinder := false
		for f in info.get("faces", PackedInt32Array()):
			on_cylinder = on_cylinder or str(grown.face_info(f).type) == "cylinder"
		if not on_cylinder:
			continue
		lines += 1
		for k in 201:
			var q: Vector3 = grown.edge_point_at(e, k / 200.0).point
			worst = maxf(worst, absf(Vector2(q.x, q.y).length() - 5 * MM))
	# (Points are single precision: about 1 nm at 5 mm.)
	_expect(lines >= 1 and worst <= 1e-8, "The lines carrying the joint on should keep to the cylinder within 10 nm (%d of them, %s m off)." % [lines, worst])


## NEW-patch-6: the G1 dome over a 10 mm open box, its four rim edges extended 1 mm square to it,
## thickened 0.1 mm (round 4 refused it as broken: its fine mesh read 22.3 mm3 for 24.6).
func _check_banded_dome() -> void:
	var curves := []
	var corners := [Vector2(0, 0), Vector2(10, 0), Vector2(10, 10), Vector2(0, 10)]
	for i in 4:
		curves.append({"type": "line", "a": corners[i] * MM, "b": corners[(i + 1) % 4] * MM})
	var walls = kernel.extrude(kernel.sketch_edges(curves, Transform3D.IDENTITY), {"direction": Vector3(0, 0, 1), "distance": 10 * MM, "surface": true})
	var rim := PackedInt32Array()
	for e in walls.edge_count():
		if absf((walls.edge_info(e).midpoint as Vector3).z - 10 * MM) < 1e-9:
			rim.append(e)
	var dome = kernel.patch([{"shape": walls, "edges": rim, "continuity": 1}], PackedVector3Array(), {"tag": "p"})
	_expect(dome != null, "The G1 box dome should build (%s)." % kernel.get_last_error())
	if dome == null:
		return
	var edges := PackedInt32Array()
	for e in dome.edge_count():
		edges.append(e)
	var banded = kernel.extend_surface(dome, edges, {"distance": 1 * MM, "mode": "perpendicular", "chain": false})
	_expect(banded != null and banded.face_count() == 5, "The dome extended 1 mm square to it on all four edges should be 5 faces (%s)." % kernel.get_last_error())
	if banded == null:
		return
	var thick = kernel.thicken(banded, PackedInt32Array(), {"thickness": 0.1 * MM})
	_expect(thick != null and thick.solid_count() == 1, "The banded dome should thicken 0.1 mm (%s)." % kernel.get_last_error())
	if thick != null:
		# (Round 6: the bands now follow the dome's normal exactly where it turns at the corners;
		# their far edges cut across it, 0.07 mm off, and the solid came 2.3 % under area x t. The
		# dome's bend and the crease where the bands meet it move it by a percent or two.)
		var shell: float = banded.area() / MM2 * 0.1
		_expect(absf(thick.volume() / MM3 - shell) < 0.02 * shell, "Its volume should be within 2 %% of area x t (%s mm3, %s)." % [thick.volume() / MM3, shell])


## Round 6, A6: ellipse, slot and egg lens caps (G1 on walls a third of their length tall) 0.5, 10
## and 500 mm long, their rims extended a 30th of that square to them, tangent and naturally: every
## band as wide as asked, within 1 %, all round (from points along the rim to the nearest of many
## points along the open edges: a square band's far edge ran through 25 points by its own length,
## and cut across an ellipse cap's ends, 12 % narrow).
func _check_lens_bands() -> void:
	var egg := [Vector2(-6, 0), Vector2(-3, -3.5), Vector2(3, -3), Vector2(6, 0), Vector2(3, 3), Vector2(-3, 3.5)]
	for length in [0.5, 10.0, 500.0]:
		var ellipse := PackedVector2Array()
		for k in 24:
			ellipse.append(Vector2(cos(TAU * k / 24.0) * 15.0, sin(TAU * k / 24.0) * 3.0) * MM * length / 30.0)
		var eggs := PackedVector2Array()
		for p in egg:
			eggs.append(p * MM * length / 12.0)
		var s: float = MM * length / 14.0
		var slot := [{"type": "line", "a": Vector2(-5, -2) * s, "b": Vector2(5, -2) * s}, {"type": "arc", "c": Vector2(5, 0) * s, "r": 2 * s, "a0": -PI / 2, "a1": PI / 2},
			{"type": "line", "a": Vector2(5, 2) * s, "b": Vector2(-5, 2) * s}, {"type": "arc", "c": Vector2(-5, 0) * s, "r": 2 * s, "a0": PI / 2, "a1": PI * 1.5}]
		for spec in [[[{"type": "interp", "points": ellipse, "periodic": true}], "ellipse"], [slot, "slot"], [[{"type": "interp", "points": eggs, "periodic": true}], "egg"]]:
			var walls = kernel.extrude(kernel.sketch_edges(spec[0], Transform3D.IDENTITY), {"direction": Vector3(0, 0, 1), "distance": length / 3.0 * MM, "surface": true})
			var top := PackedInt32Array()
			for e in walls.edge_count() if walls != null else 0:
				if absf((walls.edge_info(e).midpoint as Vector3).z - length / 3.0 * MM) < 1e-7 * maxf(length, 1.0) and str(walls.edge_info(e).type) != "degenerate":
					top.append(e)
			var cap = kernel.patch([{"shape": walls, "edges": top, "continuity": 1}], PackedVector3Array(), {"tag": "p"}) if walls != null else null
			_expect(cap != null, "A G1 cap on a %s %s mm long should build (%s)." % [spec[1], length, kernel.get_last_error()])
			if cap == null:
				continue
			var rim := PackedInt32Array()
			for e in cap.edge_count():
				if str(cap.edge_info(e).type) != "degenerate":
					rim.append(e)
			var distance: float = length / 30.0 * MM
			for mode in ["perpendicular", "tangent", "natural"]:
				var banded = kernel.extend_surface(cap, PackedInt32Array([rim[0]]), {"distance": distance, "mode": mode, "chain": true})
				_expect(banded != null, "The %s %s mm cap's rim should extend %s (%s)." % [spec[1], length, mode, kernel.get_last_error()])
				if banded == null:
					continue
				var far := PackedVector3Array()
				for e in banded.edge_count():
					var info: Dictionary = banded.edge_info(e)
					if str(info.type) != "degenerate" and (info.faces as PackedInt32Array).size() == 1:
						for k in 601:
							far.append(banded.edge_point_at(e, k / 600.0).point)
				var lo := INF
				var hi := 0.0
				for e in rim:
					for k in 33:
						var p: Vector3 = cap.edge_point_at(e, k / 32.0).point
						var d := INF
						for q in far:
							d = minf(d, q.distance_to(p))
						lo = minf(lo, d / distance)
						hi = maxf(hi, d / distance)
				_expect(lo > 0.99 and hi < 1.01, "The %s %s mm cap's rim extended %s should be as wide as asked all round (%.4f..%.4f of it)." % [spec[1], length, mode, lo, hi])
