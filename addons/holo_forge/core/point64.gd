@tool
extends RefCounted
## Points kept in doubles beside their float32 Vector3.
##
## Godot's Vector3 is single precision in this build, so a point typed 100 km out is rounded to
## the nearest float32 (steps of about 8 mm there). A point field keeps an exact copy next to the
## Vector3 under "<key>_64": a PackedFloat64Array of 3, in meters. The copy counts only while the
## Vector3 is still its float32 rounding: a handle drag or a hand edit that changes the Vector3
## makes the Vector3 the value again. A copy is stored only when float32 rounds the point, so
## documents with ordinary points are unchanged. Static functions, no state.

const SUFFIX := "_64"


## The point at values[key] in doubles: the exact copy when it still matches the Vector3,
## otherwise the Vector3's own values.
static func exact(values: Dictionary, key: String) -> PackedFloat64Array:
	var v = values.get(key, Vector3.ZERO)
	var p: Vector3 = v if v is Vector3 else Vector3.ZERO
	var e = values.get(key + SUFFIX)
	if e is PackedFloat64Array and (e as PackedFloat64Array).size() == 3:
		var d: PackedFloat64Array = e
		if is_finite(d[0]) and is_finite(d[1]) and is_finite(d[2]) and Vector3(d[0], d[1], d[2]) == p:
			return d.duplicate()
	return PackedFloat64Array([p.x, p.y, p.z])


## Sets one axis of values[key] to a double, keeping the Vector3 and the exact copy in step.
static func set_axis(values: Dictionary, key: String, axis: int, value: float) -> void:
	var d := exact(values, key)
	d[axis] = value
	values[key] = Vector3(d[0], d[1], d[2])
	values[key + SUFFIX] = d


## Writes values[key] into target: the Vector3, plus the exact copy when float32 rounds it
## (and no copy otherwise).
static func store(target: Dictionary, key: String, values: Dictionary) -> void:
	var d := exact(values, key)
	var p := Vector3(d[0], d[1], d[2])
	target[key] = p
	if float(p.x) != d[0] or float(p.y) != d[1] or float(p.z) != d[2]:
		target[key + SUFFIX] = d
	else:
		target.erase(key + SUFFIX)


## Copies key's exact copy from source into values, when source holds one.
static func read(values: Dictionary, key: String, source: Dictionary) -> void:
	if source.has(key + SUFFIX):
		values[key + SUFFIX] = (source[key + SUFFIX] as PackedFloat64Array).duplicate() if source[key + SUFFIX] is PackedFloat64Array else source[key + SUFFIX]
