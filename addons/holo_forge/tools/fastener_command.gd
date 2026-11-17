@tool
extends "res://addons/holo_forge/tools/feature_command.gd"
## Insert Fastener: an ISO metric bolt, nut or washer as a "fastener" timeline feature (built by
## core/features/insert.gd), from the "fastener" spec in feature_specs.gd.
##
## Place On: a hole's round edge puts it on the hole's center, along the hole; a face puts it
## where you clicked (the face's middle when the pick came from elsewhere); a point puts it on the
## point. Direction "From the Pick" sends bolts into the picked surface and stands nuts and
## washers on it; the other choices are fixed directions. The pick is kept as a reference
## (options follow), so every rebuild finds it again and the fastener moves with it (a taller box
## keeps its washer on top; INSERT.fastener_placement); Position is where on the face it sits.
## When the pick can't be found it stays at its last position and axis, with a warning. Clearing
## Place On leaves it where it is, by coordinates.

const INSERT := preload("res://addons/holo_forge/core/features/insert.gd")

const DIRECTIONS := {
	"down": Vector3.DOWN, "up": Vector3.UP, "+x": Vector3.RIGHT, "-x": Vector3.LEFT, "+z": Vector3.BACK, "-z": Vector3.FORWARD,
}


func _init(_key := "fastener") -> void:
	super("fastener")


func defaults() -> Dictionary:
	var values := super()
	values["length"] = _default_length(str(values.get("kind", "")), str(values.get("size", "")))
	return values


func create_feature(doc: Resource, values: Dictionary) -> Resource:
	var placed := _placement(values, [])
	super(doc, values)
	_after_write(doc, values, placed, "", not placed.is_empty())
	return feature


func read_values() -> Dictionary:
	var values := super()
	# A fastener riding on geometry shows where it sits now (the face may have moved since).
	var now := _followed()
	if not now.is_empty():
		values["position"] = now.position
	return values


func write_values(doc: Resource, values: Dictionary) -> void:
	var old_name := _auto_name(str(feature.options.get("kind", "")), str(feature.options.get("size", "")))
	var before: Array = feature.options.get("place", [])
	var placed := _placement(values, before)
	var changed := not placed.is_empty()
	if (values.get("place", []) as Array).is_empty() and not before.is_empty():
		# Place On cleared: the fastener stays where it sat, now by its coordinates.
		var now := _followed()
		if not now.is_empty():
			values["position"] = now.position
			changed = true
	# A bolt of another size starts at that size's usual length while the length is untouched.
	var old_kind := str(feature.options.get("kind", ""))
	var old_size := str(feature.options.get("size", ""))
	if (old_kind != str(values.get("kind", "")) or old_size != str(values.get("size", ""))) \
			and str(values.get("length", "")) == _default_length(old_kind, old_size):
		values["length"] = _default_length(str(values.get("kind", "")), str(values.get("size", "")))
		changed = true
	super(doc, values)
	_after_write(doc, values, placed, old_name, changed)


## The axis the fastener's shank (or a nut's / washer's rise) follows for these values.
func axis_for(values: Dictionary) -> Vector3:
	var axis: Vector3 = DIRECTIONS.get(str(values.get("direction", "auto")), Vector3.ZERO)
	if axis == Vector3.ZERO:
		var n: Vector3 = feature.options.get("pick_normal", Vector3.ZERO) if feature != null else Vector3.ZERO
		if n.length() > 1e-9:
			# Bolts go into the surface; nuts and washers stand on it.
			axis = -n.normalized() if str(values.get("kind", "")) in INSERT.BOLTS else n.normalized()
		else:
			axis = feature.options.get("base_axis", Vector3.DOWN) if feature != null else Vector3.DOWN
	return -axis if bool(values.get("flip", false)) else axis


func manipulators(values: Dictionary, evaluated: Dictionary) -> Array[Dictionary]:
	var handles: Array[Dictionary] = []
	if feature == null:
		return handles
	var p: Vector3 = values.get("position", Vector3.ZERO)
	var axis := (feature.options.get("axis", Vector3.DOWN) as Vector3).normalized()
	var now := _followed()
	if not now.is_empty():
		p = now.position
		axis = (now.axis as Vector3).normalized()
	if str(values.get("kind", "")) in INSERT.BOLTS and evaluated.has("length"):
		var length := float(evaluated.length)
		handles.append({"type": "arrow", "key": "length", "origin": p + axis * length, "direction": axis, "factor": 1.0, "base": length})
	handles.append({"type": "point", "key": "position", "position": p, "normal": axis})
	return handles


# --- Helpers ---------------------------------------------------------------------------------

## A new pick in Place On moves the fastener there: {"position", "normal"} (and the position is
## written into values), or {} when the pick didn't change.
func _placement(values: Dictionary, before: Array) -> Dictionary:
	var place: Array = values.get("place", [])
	if place.is_empty() or not place[0] is Dictionary or str(place) == str(before):
		return {}
	var found := _resolve(place[0])
	if not found.is_empty():
		values["position"] = found.position
	return found


## Stores the axis and names the body; changed: values were rewritten here, so the panel shows them.
func _after_write(doc: Resource, values: Dictionary, placed: Dictionary, old_name: String, changed: bool) -> void:
	if not feature.options.has("base_axis"):
		# Fasteners made elsewhere (INSERT.add_fastener) keep their own axis as the fixed one.
		feature.options["base_axis"] = feature.options.get("axis", Vector3.DOWN)
	if placed.has("normal"):
		feature.options["pick_normal"] = placed.normal
	# A new pick is followed from now on; without a pick the position is plain coordinates.
	if placed.has("position"):
		feature.options["follow"] = true
	elif (values.get("place", []) as Array).is_empty():
		feature.options.erase("follow")
	if _anchor_place(values):
		changed = true
	feature.options["axis"] = axis_for(values)
	var body_id := str(feature.options.get("body_id", ""))
	var name := _auto_name(str(values.get("kind", "")), str(values.get("size", "")))
	if doc.bodies.has(body_id):
		var current := str(doc.bodies[body_id].get("name", ""))
		# A body the user renamed keeps its name.
		if old_name == "" or current == old_name:
			doc.bodies[body_id]["name"] = name
	if changed and workspace != null:
		workspace.panel.set_values(values)


## Anchors a followed face reference at the stored position: its sig is taken again from the
## latest rebuild and its "at" set to options.position, so INSERT.place_on carries that spot along
## when the face later moves or turns (a reference whose "at" isn't the position is taken as it
## is). The panel's values get the same reference, so the next write doesn't take it for a new
## pick. Returns true when values["place"] was rewritten.
func _anchor_place(values: Dictionary) -> bool:
	var place: Array = feature.options.get("place", [])
	if not bool(feature.options.get("follow", false)) or place.is_empty() or not place[0] is Dictionary or str(place[0].get("kind", "")) != "face":
		return false
	if not OPERATIONS.creates_body(str(feature.options.get("operation", OPERATIONS.NEW_BODY))):
		return false
	if workspace == null or workspace.doc == null or result.is_empty():
		return false
	var found := REFERENCES.face(place[0], INSPECT.context(result, workspace.doc, workspace.kernel))
	if found.has("error"):
		return false
	var ref: Dictionary = (place[0] as Dictionary).duplicate(true)
	ref["sig"] = REFERENCES.face_signature(found.shape, found.index)
	ref["at"] = feature.options.get("position", Vector3.ZERO)
	place = place.duplicate()
	place[0] = ref
	feature.options["place"] = place
	if str(values.get("place", [])) == str(place):
		return false
	values["place"] = place.duplicate(true)
	return true


## {"position", "normal" (outward; zero when the pick has none)} for a Place On reference.
func _resolve(ref: Dictionary) -> Dictionary:
	if workspace == null or workspace.doc == null:
		return {}
	var ctx := INSPECT.context(result, workspace.doc, workspace.kernel)
	var near := Vector3.ZERO
	if str(ref.get("kind", "")) == "face":
		# Where you clicked, else the face's middle (the nearest point on the face is used).
		var found := REFERENCES.face(ref, ctx)
		if found.has("error"):
			return {}
		near = found.shape.face_info(found.index).point
		var clicked: Variant = workspace.picker.click_point(ref)
		if clicked is Vector3:
			near = clicked
	var at := INSERT.place_on(ref, ctx, near)
	return {} if at.has("error") else {"position": at.position, "normal": at.normal}


## Where the fastener sits now when it rides on geometry: {"position", "axis"} from the latest
## rebuild, or {} (not following, no workspace, or the pick is lost). A fastener joined or cut
## into the body it sits on changed that body, so it shows its stored placement instead.
func _followed() -> Dictionary:
	if feature == null or workspace == null or workspace.doc == null or result.is_empty():
		return {}
	if not OPERATIONS.creates_body(str(feature.options.get("operation", OPERATIONS.NEW_BODY))):
		return {}
	var now := INSERT.fastener_placement(feature, INSPECT.context(result, workspace.doc, workspace.kernel))
	return now if bool(now.followed) else {}


## A bolt's usual length as panel text in document units ("" for nuts and washers).
func _default_length(kind: String, size: String) -> String:
	var spec := INSERT.fastener_size(kind, size)
	var meters := float(spec.get("default_length", 0.0))
	if meters <= 0.0:
		return str(hints.get("default_size", "20")) if kind in INSERT.BOLTS else "20"
	return UNITS.format_value(meters, UNITS.KIND_LENGTH, str(hints.get("units", "mm"))).split(" ")[0]


static func _auto_name(kind: String, size: String) -> String:
	var spec := INSERT.fastener_size(kind, size)
	return "%s %s" % [size, spec.label] if not spec.is_empty() else ""
