@tool
extends RefCounted
## Box, Cylinder, Sphere, Torus, Coil and Pipe. options.position is the base center (box,
## cylinder, coil) or the center (sphere, torus), in meters; sizes are length inputs. The position
## is read in doubles (core/point64.gd: options.position_64 while it matches the Vector3), and each
## primitive is built at the origin and moved into place with transform_shape64, so one placed
## 100 km out sits where it was typed instead of on the nearest float32 (steps of about 8 mm).
##
## Coil: options coil_type (revolution_height | revolution_pitch | height_pitch | spiral),
## section (circle | square | triangle_out | triangle_in), section_position (inside | on |
## outside), left; inputs diameter, turns, height, pitch, taper, section_size.
## Pipe: options path, section, hollow; inputs diameter, thickness.

const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")
const UTIL := preload("res://addons/holo_forge/core/features/util.gd")
const POINT64 := preload("res://addons/holo_forge/core/point64.gd")

## Turns the kernel's sphere (poles on Z) so its poles lie on +Y. Exact values keep
## transform_shape on its rigid path: the face stays an analytic sphere with the same names.
const SPHERE_POLES_ON_Y := Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0))


static func build(feature: Resource, ctx: Dictionary) -> String:
	var r := UTIL.Reader.new(feature, ctx)
	var at := POINT64.exact(feature.options, "position")
	var kernel: RefCounted = ctx.kernel
	var shape: RefCounted
	match feature.type:
		"box":
			var size := Vector3(r.num("length", null, "positive"), r.num("height", null, "positive"), r.num("width", null, "positive"))
			if not r.ok():
				return r.error
			shape = placed(kernel, kernel.make_box(size, Vector3(-size.x * 0.5, 0.0, -size.z * 0.5), feature.id), Basis.IDENTITY, at, feature.id)
		"cylinder":
			var diameter := r.num("diameter", null, "positive")
			var height := r.num("height", null, "positive")
			if not r.ok():
				return r.error
			shape = placed(kernel, kernel.make_cylinder(diameter * 0.5, height, Vector3.ZERO, Vector3.UP, feature.id), Basis.IDENTITY, at, feature.id)
		"sphere":
			var diameter := r.num("diameter", null, "positive")
			if not r.ok():
				return r.error
			# Poles on +Y, so a spherical texture mapping about its default axis meets real pole
			# vertices instead of smearing across off-pole triangles.
			var ball: RefCounted = kernel.make_sphere(diameter * 0.5, Vector3.ZERO, feature.id)
			shape = placed(kernel, ball, SPHERE_POLES_ON_Y, at, feature.id)
		"torus":
			var diameter := r.num("diameter", null, "positive")
			var section := r.num("section", null, "positive")
			if r.ok() and section >= diameter:
				r.fail("The torus' section must be smaller than its diameter")
			if not r.ok():
				return r.error
			shape = placed(kernel, kernel.torus({"major_radius": diameter * 0.5, "minor_radius": section * 0.5, "center": Vector3.ZERO, "axis": Vector3.UP, "tag": feature.id}), Basis.IDENTITY, at, feature.id)
		"coil":
			shape = _coil(r, at)
			if shape == null:
				return r.error
		"pipe":
			var path := r.path("path")
			var diameter := r.num("diameter", null, "positive")
			var hollow := bool(r.opt("hollow", false))
			var thickness := r.num("thickness", null, "positive") if hollow else 0.0
			if r.ok() and hollow and thickness * 2.0 >= diameter:
				r.fail("The pipe's wall is thicker than its radius")
			if not r.ok():
				return r.error
			shape = r.noted(kernel.pipe(path, {"size": diameter, "section": str(r.opt("section", "circle")), "hollow": hollow, "thickness": thickness, "tag": feature.id}), "Pipe")
		_:
			return "Unknown primitive '%s'" % feature.type
	return UTIL.finish(r, shape, feature.type.capitalize())


## shape (built at the origin) turned by basis and moved to at (3 doubles, meters), in doubles
## when the kernel has transform_shape64. An unturned shape at the origin is returned as built;
## null stays null.
static func placed(kernel: RefCounted, shape: RefCounted, basis: Basis, at: PackedFloat64Array, tag: String) -> RefCounted:
	if shape == null or (basis == Basis.IDENTITY and at[0] == 0.0 and at[1] == 0.0 and at[2] == 0.0):
		return shape
	if kernel.has_method("transform_shape64"):
		return kernel.call("transform_shape64", shape, PackedFloat64Array([
			basis.x.x, basis.x.y, basis.x.z, basis.y.x, basis.y.y, basis.y.z, basis.z.x, basis.z.y, basis.z.z, at[0], at[1], at[2]]), tag)
	return kernel.transform_shape(shape, Transform3D(basis, Vector3(at[0], at[1], at[2])), tag)


## The coil's shape (surface: its skin alone, open at the ends) with its base center at at
## (3 doubles, meters), or null after r.fail().
static func coil_shape(r: UTIL.Reader, at: PackedFloat64Array, surface := false) -> RefCounted:
	return _coil(r, at, surface)


static func _coil(r: UTIL.Reader, at: PackedFloat64Array, surface := false) -> RefCounted:
	var coil_type := str(r.opt("coil_type", "revolution_height"))
	var turns := 0.0
	var pitch := 0.0
	match coil_type:
		"revolution_height":
			turns = r.num("turns", null, "positive")
			pitch = r.num("height", null, "positive") / maxf(turns, 1e-9)
		"revolution_pitch", "spiral":
			turns = r.num("turns", null, "positive")
			pitch = r.num("pitch", null, "positive")
		"height_pitch":
			pitch = r.num("pitch", null, "positive")
			turns = r.num("height", null, "positive") / maxf(pitch, 1e-9)
	var diameter := r.num("diameter", null, "positive")
	var section_size := r.num("section_size", null, "positive")
	if r.ok() and section_size >= pitch:
		r.fail("The section is bigger than the %s: the turns would overlap" % ("spiral's spacing" if coil_type == "spiral" else "pitch"))
	if not r.ok():
		return null
	return placed(r.kernel, r.noted(r.kernel.coil({
		"origin": Vector3.ZERO, "axis": Vector3.UP, "diameter": diameter, "pitch": pitch, "turns": turns,
		"taper": r.num("taper", 0.0), "section": str(r.opt("section", "circle")), "section_size": section_size,
		"section_position": str(r.opt("section_position", "on")), "left": bool(r.opt("left", false)),
		"spiral": coil_type == "spiral", "tag": r.feature.id, "surface": surface,
	}), "Coil"), Basis.IDENTITY, at, r.feature.id)
