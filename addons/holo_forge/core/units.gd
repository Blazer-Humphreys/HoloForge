@tool
extends RefCounted
## Units and parameter expressions for Holo Forge.
##
## Everything is stored in base units: lengths in meters (Godot units), angles in radians.
## Expressions carry dimensions, so "width * 2" stays a length and "width + 5" reads the 5 in the
## document's length unit, the way CAD parameter tables behave. Bare numbers are "promotable":
## a plain "20" in a length field means 20 document units, and in an angle field 20 degrees.

const LENGTH_UNITS := {"mm": 0.001, "cm": 0.01, "m": 1.0, "in": 0.0254, "ft": 0.3048}
const ANGLE_UNITS := {"deg": PI / 180.0, "rad": 1.0}
const FUNCTIONS := ["sin", "cos", "tan", "asin", "acos", "atan", "sqrt", "abs", "floor", "ceil", "round", "min", "max", "pow"]

## Field kinds: a length, an angle, or a plain number.
const KIND_LENGTH := "length"
const KIND_ANGLE := "angle"
const KIND_NUMBER := "number"


static func unit_kind(unit: String) -> String:
	if LENGTH_UNITS.has(unit):
		return KIND_LENGTH
	if ANGLE_UNITS.has(unit):
		return KIND_ANGLE
	return KIND_NUMBER


## The display unit for a kind in a document whose length unit is document_units.
static func display_unit(kind: String, document_units: String) -> String:
	match kind:
		KIND_LENGTH:
			return document_units
		KIND_ANGLE:
			return "deg"
	return ""


## A base-unit value written in the document's display unit, e.g. 0.02 -> "20 mm", with at most
## decimals digits after the point (trailing zeros dropped).
static func format_value(value: float, kind: String, document_units: String, decimals := 4) -> String:
	var unit := display_unit(kind, document_units)
	var shown := value
	if kind == KIND_LENGTH:
		shown = value / float(LENGTH_UNITS.get(unit, 1.0))
	elif kind == KIND_ANGLE:
		shown = rad_to_deg(value)
	var text := String.num(snappedf(shown, pow(10.0, -decimals)), decimals)
	if text.contains("."):
		text = text.rstrip("0").rstrip(".")
	return text + (" " + unit if unit != "" else "")


## Evaluates an expression into base units. variables maps names to
## {"value": float, "l": int, "a": int} (as returned by this function for other parameters).
## Returns {"ok": bool, "value": float, "l": int, "a": int, "error": String}.
static func evaluate(expression: String, kind: String, document_units: String, variables: Dictionary) -> Dictionary:
	var parser := _Parser.new(expression, document_units, variables)
	var result: Dictionary = parser.parse()
	if not result.get("ok", false):
		return result
	return _coerce(result, kind, document_units)


## Converts a dimensional result to the field kind, promoting bare numbers to document units.
static func _coerce(q: Dictionary, kind: String, document_units: String) -> Dictionary:
	var l: int = q.l
	var a: int = q.a
	var value: float = q.v
	match kind:
		KIND_LENGTH:
			if l == 0 and a == 0 and q.bare:
				value *= float(LENGTH_UNITS.get(document_units, 0.001))
				l = 1
			if l != 1 or a != 0:
				return _fail("Expected a length")
		KIND_ANGLE:
			if l == 0 and a == 0 and q.bare:
				value *= ANGLE_UNITS.deg
				a = 1
			if a != 1 or l != 0:
				return _fail("Expected an angle")
		_:
			if l != 0 or a != 0:
				return _fail("Expected a plain number")
	if is_nan(value) or is_inf(value):
		return _fail("The result is not a finite number")
	return {"ok": true, "value": value, "l": l, "a": a, "error": ""}


static func _fail(message: String) -> Dictionary:
	return {"ok": false, "value": 0.0, "l": 0, "a": 0, "error": message}


## Recursive-descent parser over quantities {v, l, a, bare}:
## v is the base-unit value, l the length power, a the angle power, and bare marks values built
## only from unitless numbers (they adopt the units of whatever they are added to).
class _Parser:
	extends RefCounted

	var text: String
	var pos := 0
	var units: String
	var variables: Dictionary
	var error := ""

	func _init(p_text: String, p_units: String, p_variables: Dictionary) -> void:
		text = p_text
		units = p_units
		variables = p_variables

	func parse() -> Dictionary:
		if text.strip_edges() == "":
			return {"ok": false, "error": "Empty expression"}
		var q := _sum()
		_skip_space()
		if error == "" and pos < text.length():
			error = "Unexpected '%s'" % text[pos]
		if error != "":
			return {"ok": false, "value": 0.0, "l": 0, "a": 0, "error": error}
		q["ok"] = true
		return q

	func _skip_space() -> void:
		while pos < text.length() and text[pos] in [" ", "\t"]:
			pos += 1

	func _peek() -> String:
		_skip_space()
		return text[pos] if pos < text.length() else ""

	func _sum() -> Dictionary:
		var left := _product()
		while error == "":
			var op := _peek()
			if op != "+" and op != "-":
				break
			pos += 1
			var right := _product()
			left = _add(left, right, op == "-")
		return left

	func _product() -> Dictionary:
		var left := _power()
		while error == "":
			var op := _peek()
			if op != "*" and op != "/":
				break
			pos += 1
			var right := _power()
			if op == "*":
				left = {"v": left.v * right.v, "l": left.l + right.l, "a": left.a + right.a, "bare": left.bare and right.bare}
			else:
				if is_zero_approx(right.v):
					error = "Division by zero"
					return left
				left = {"v": left.v / right.v, "l": left.l - right.l, "a": left.a - right.a, "bare": left.bare and right.bare}
		return left

	func _power() -> Dictionary:
		var base := _unary()
		if error == "" and _peek() == "^":
			pos += 1
			var exponent := _unary()
			base = _pow(base, exponent)
		return base

	func _unary() -> Dictionary:
		var op := _peek()
		if op == "-" or op == "+":
			pos += 1
			var q := _unary()
			if op == "-":
				q.v = -q.v
			return q
		return _atom()

	func _atom() -> Dictionary:
		var c := _peek()
		if c == "":
			error = "Unexpected end of expression"
			return _bare(0.0)
		if c == "(":
			pos += 1
			var inner := _sum()
			if _peek() != ")":
				error = "Missing ')'"
				return inner
			pos += 1
			return inner
		if c.is_valid_int() or c == ".":
			return _number()
		if _is_name_char(c, true):
			return _name()
		error = "Unexpected '%s'" % c
		return _bare(0.0)

	func _number() -> Dictionary:
		var start := pos
		while pos < text.length() and (text[pos].is_valid_int() or text[pos] == "."):
			pos += 1
		# Exponent, e.g. 1.5e-3, but not a unit or name that starts with "e".
		if pos < text.length() and text[pos] in ["e", "E"] and pos + 1 < text.length() \
				and (text[pos + 1].is_valid_int() or (text[pos + 1] in ["+", "-"] and pos + 2 < text.length() and text[pos + 2].is_valid_int())):
			pos += 2
			while pos < text.length() and text[pos].is_valid_int():
				pos += 1
		var literal := text.substr(start, pos - start)
		if not literal.is_valid_float():
			error = "Bad number '%s'" % literal
			return _bare(0.0)
		var value := literal.to_float()
		# An optional unit right after the number: "20mm", "20 mm", "45 deg".
		var save := pos
		_skip_space()
		var unit := _read_name()
		if LENGTH_UNITS.has(unit):
			return {"v": value * float(LENGTH_UNITS[unit]), "l": 1, "a": 0, "bare": false}
		if ANGLE_UNITS.has(unit):
			return {"v": value * float(ANGLE_UNITS[unit]), "l": 0, "a": 1, "bare": false}
		pos = save
		return _bare(value)

	func _name() -> Dictionary:
		var name := _read_name()
		if name == "PI" or name == "pi":
			return _bare(PI)
		if name in FUNCTIONS:
			return _call(name)
		if variables.has(name):
			var known: Dictionary = variables[name]
			return {"v": float(known.value), "l": int(known.get("l", 0)), "a": int(known.get("a", 0)), "bare": int(known.get("l", 0)) == 0 and int(known.get("a", 0)) == 0}
		error = "Unknown name '%s'" % name
		return _bare(0.0)

	func _call(name: String) -> Dictionary:
		if _peek() != "(":
			error = "'%s' needs '('" % name
			return _bare(0.0)
		pos += 1
		var args: Array[Dictionary] = [_sum()]
		while error == "" and _peek() == ",":
			pos += 1
			args.append(_sum())
		if error != "":
			return _bare(0.0)
		if _peek() != ")":
			error = "Missing ')' after %s(" % name
			return _bare(0.0)
		pos += 1
		var x: Dictionary = args[0]
		match name:
			"sin", "cos", "tan":
				var angle := _as_angle(x)
				var v := sin(angle) if name == "sin" else (cos(angle) if name == "cos" else tan(angle))
				return _bare(v)
			"asin", "acos", "atan":
				if x.l != 0 or x.a != 0:
					error = "%s needs a plain number" % name
				var v := asin(x.v) if name == "asin" else (acos(x.v) if name == "acos" else atan(x.v))
				return {"v": v, "l": 0, "a": 1, "bare": false}
			"sqrt":
				if x.l % 2 != 0 or x.a % 2 != 0 or x.v < 0.0:
					error = "sqrt needs a non-negative square quantity"
					return _bare(0.0)
				return {"v": sqrt(x.v), "l": x.l / 2, "a": x.a / 2, "bare": x.bare}
			"abs":
				return {"v": absf(x.v), "l": x.l, "a": x.a, "bare": x.bare}
			"floor", "ceil", "round":
				var v := floorf(x.v) if name == "floor" else (ceilf(x.v) if name == "ceil" else roundf(x.v))
				return {"v": v, "l": x.l, "a": x.a, "bare": x.bare}
			"min", "max":
				var best: Dictionary = args[0]
				for i in range(1, args.size()):
					var candidate := _unify(args[i], best)
					best = _unify(best, candidate)
					if error != "":
						return best
					if (name == "min" and candidate.v < best.v) or (name == "max" and candidate.v > best.v):
						best = candidate
				return best
			"pow":
				if args.size() != 2:
					error = "pow needs two arguments"
					return _bare(0.0)
				return _pow(args[0], args[1])
		error = "Unknown function '%s'" % name
		return _bare(0.0)

	func _read_name() -> String:
		var start := pos
		while pos < text.length() and _is_name_char(text[pos], pos == start):
			pos += 1
		return text.substr(start, pos - start)

	func _is_name_char(c: String, first: bool) -> bool:
		if c == "_" or (c >= "a" and c <= "z") or (c >= "A" and c <= "Z"):
			return true
		return not first and c.is_valid_int()

	func _bare(value: float) -> Dictionary:
		return {"v": value, "l": 0, "a": 0, "bare": true}

	func _as_angle(q: Dictionary) -> float:
		if q.a == 1 and q.l == 0:
			return q.v
		if q.a == 0 and q.l == 0:
			return q.v * ANGLE_UNITS.deg
		error = "Expected an angle"
		return 0.0

	## Gives q the dimensions of other when q is a bare number (e.g. the 5 in "width + 5").
	func _unify(q: Dictionary, other: Dictionary) -> Dictionary:
		if q.l == other.l and q.a == other.a:
			return q
		if q.bare and q.l == 0 and q.a == 0:
			var scale := pow(float(LENGTH_UNITS.get(units, 0.001)), other.l) * pow(ANGLE_UNITS.deg, other.a)
			return {"v": q.v * scale, "l": other.l, "a": other.a, "bare": false}
		if other.bare and other.l == 0 and other.a == 0:
			return q
		error = "Inconsistent units"
		return q

	func _add(left: Dictionary, right: Dictionary, subtract: bool) -> Dictionary:
		var a := _unify(left, right)
		var b := _unify(right, a)
		if error != "":
			return left
		return {"v": a.v - b.v if subtract else a.v + b.v, "l": a.l, "a": a.a, "bare": left.bare and right.bare}

	func _pow(base: Dictionary, exponent: Dictionary) -> Dictionary:
		if exponent.l != 0 or exponent.a != 0:
			error = "Exponents must be plain numbers"
			return base
		var n: float = exponent.v
		if (base.l != 0 or base.a != 0) and not is_equal_approx(n, roundf(n)):
			error = "Units can only be raised to whole powers"
			return base
		return {"v": pow(base.v, n), "l": int(base.l * n), "a": int(base.a * n), "bare": base.bare}
