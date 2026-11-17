@tool
extends RefCounted
## The assembly stored in a document (Holo Forge Phase 8, contracts C1 and C10).
##
## doc.assembly is not a feature and not on the timeline: it is solved after the whole timeline has
## built (core/assembly/solver.gd). An empty Dictionary means "no assembly" (every component at
## identity, nothing grounded, no joints). Readers go through normalized(), which fills every
## missing key with its default; writers store the full normalized form. The dictionary holds no
## Resources, so duplicate(true) copies it fully. All lengths in meters, angles in radians, doubles;
## an xform64 is a PackedFloat64Array of 12 (core/assembly/xform64.gd).
##
## Schema, version 1 (spec C1.2):
## {"version", "placements": {comp_id: xform64} (relative to the parent component; missing =
## identity), "grounded": {comp_id: true} (top-level only), "origins": [...], "joints": [...],
## "rigid_groups": [...], "links": [...], "contact": {"enabled", "tolerance", "step", "precision"},
## "contact_sets": [...], "studies": [...], "counters": {kind: n}}. The entries' keys are in
## the *_DEFAULT constants below.
##
## Every user-facing assembly sentence is a constant here (C10), so the tools, the panels and the
## tests share one literal. Placeholders in <> are filled by fill() with names and with values
## already written in document units (degrees for angles).

const XFORM := preload("res://addons/holo_forge/core/assembly/xform64.gd")

## The schema version this Holo Forge writes. A stored assembly with a greater version was saved
## by a newer Holo Forge: it is shown but never edited (edit_refusal()).
const VERSION := 1

## Joint types and their DOFs, in the order of a joint's "dofs" (spec C2.5).
const DOF_NAMES := {
	"rigid": [],
	"revolute": ["rot_z"],
	"slider": ["slide"],
	"cylindrical": ["slide_z", "rot_z"],
	"pin_slot": ["rot_z", "slide"],
	"planar": ["slide_x", "slide_y", "rot_z"],
	"ball": ["rot_x", "rot_y", "rot_z"],
}
const TYPES := ["rigid", "revolute", "slider", "cylindrical", "pin_slot", "planar", "ball"]
## A new joint's type (the Joint panel's default).
const DEFAULT_TYPE := "revolute"
## The slide axis a slider and a pin-slot start with ("x" | "y" | "z"; pin-slot: "x" | "y").
const DEFAULT_SLIDE_AXIS := {"slider": "z", "pin_slot": "x"}

## Id kinds (new_id) and the list each kind's entries live in.
const KIND_LISTS := {
	"joint": "joints", "origin": "origins", "group": "rigid_groups", "link": "links", "contact": "contact_sets", "study": "studies",
}
## What a new entry of each kind is called before the user renames it (name_for()).
const KIND_NAMES := {
	"joint": "Joint", "origin": "Origin", "group": "Group", "link": "Link", "contact": "Contact Set ", "study": "Motion Study",
}

## Snap kinds (spec C2.3).
const SNAP_KINDS := [
	"face_center", "axis_mid", "axis_start", "axis_end", "sphere_center", "edge_mid", "vertex", "circle_center", "origin",
	"group_center", "group_axis_mid",
]
## A snap with no geometry behind it (core/assembly/snaps.gd FIXED): an as-built joint's side keeps
## its picked frame that way. Not in the spec's C2.3 table (added in Stage 1, reported).
const SNAP_FIXED := "fixed"

## Contact defaults (spec C1.2, 8.2 #5): tolerance 0.01 mm, step 1 mm, precision 0.001 mm.
const CONTACT_DEFAULT := {"enabled": false, "tolerance": 1e-5, "step": 1e-3, "precision": 1e-6}
## One DOF of a joint: its value, its limits (each end on or off) and its rest value.
const DOF_DEFAULT := {"value": 0.0, "min": 0.0, "max": 0.0, "limited_min": false, "limited_max": false, "rest": 0.0}
## A stored snap ("ref" as features store picks, REFERENCES.from_pick; kind "origin" also has
## "origin": an origin id). Its "frame" (the last resolved frame in the body's modelled
## coordinates, an xform64) defaults to identity; a packed array is no constant, so _fill_snap()
## adds it.
const SNAP_DEFAULT := {"kind": "", "body": "", "ref": {}, "at": [0.0, 0.0, 0.0], "normal": [0.0, 0.0, 1.0]}
const SIDE_DEFAULT := {"component": "", "snap": SNAP_DEFAULT}
const JOINT_DEFAULT := {
	"id": "", "name": "", "type": DEFAULT_TYPE, "a": SIDE_DEFAULT, "b": SIDE_DEFAULT,
	"offset": [0.0, 0.0, 0.0], "angle": 0.0, "flip": false, "slide_axis": "z", "dofs": [],
	"suppressed": false, "as_built": false, "visible": true,
}
const ORIGIN_DEFAULT := {
	"id": "", "name": "", "component": "", "snap": SNAP_DEFAULT, "offset": [0.0, 0.0, 0.0], "angle": 0.0, "flip": false, "visible": true,
}
const GROUP_DEFAULT := {"id": "", "name": "", "components": [], "relative": {}, "suppressed": false}
const LINK_DEFAULT := {
	"id": "", "name": "", "driver": {"joint": "", "dof": 0}, "follower": {"joint": "", "dof": 0}, "ratio": 1.0, "offset": 0.0,
}
const CONTACT_SET_DEFAULT := {"id": "", "name": "", "members": [], "enabled": true}
const STUDY_DEFAULT := {"id": "", "name": "", "length": 5.0, "fps": 30, "contact": false, "keys": []}
## The default entry of each list.
const LIST_DEFAULTS := {
	"origins": ORIGIN_DEFAULT, "joints": JOINT_DEFAULT, "rigid_groups": GROUP_DEFAULT, "links": LINK_DEFAULT,
	"contact_sets": CONTACT_SET_DEFAULT, "studies": STUDY_DEFAULT,
}

# --- Sentences (spec C10) ----------------------------------------------------------------------

const S_SAME_UNIT := "Both picks are on <Comp>. A joint connects two different components."
const S_SIDES_SWAPPED := "The first pick is on a fixed part, so <Comp> moves instead."
const S_NESTED_MOVES := "<Nested> moves with its top-level component <Comp>."
const S_MESH_SNAP := "Mesh bodies snap only to flat or round face groups. Pick a face group."
const S_GROUP_NOT_ROUND := "This face group is neither flat nor round enough (<n>% off a cylinder) to place a joint on."
const S_SNAP_LOST := "<Joint> lost its pick on <Body> (the model changed there); it holds its last place. Edit the joint to pick again."
const S_WAITING := "<Joint> waits for <Comp>, which the timeline builds after the rollback marker."
const S_MISSING_COMPONENT := "<Joint> refers to <Comp>, which no longer exists. Edit or delete the joint."
const S_LIMITS_EQUAL := "Min and max are equal. Use a Rigid joint, or set two different limits."
const S_LOOP_OFF := "<Joint> closes a loop and is not solved: it is off by <d> and <a> at this pose."
const S_LOOP_HOLDS := "<Joint> closes a loop; it holds at this pose but is not solved while you drive."
const S_SOLVE_FAULT := "<Joint> could not be placed exactly (off by <d>, <a>). This is a Holo Forge fault; please report it."
const S_PLACE_JOINTED := "<Comp> is held by <Joint>. Drive the joint, or suppress it to place the component."
const S_LIMIT := "<Joint> stops at its limit of <limit> (asked for <target>)."
const S_LINK_LIMIT := "<Joint> stops at <value>: <Follower>, linked <ratio>, reaches its limit of <limit> there."
const S_LINK_SECOND_DRIVER := "<Joint> already follows <Driver>. A joint can follow only one other."
const S_LINK_CIRCLE := "That link would make <Joint> follow itself through <Other>. Links must not close a circle."
const S_LINK_ZERO := "Ratio must not be 0."
const S_STUDY_FOLLOWER := "<Joint> follows <Driver> through <Link>. Put the key on <Driver> instead."
const S_STUDY_CLAMPED := "<Joint>'s key at <time> (<value>) is beyond its limit of <limit>; it plays at the limit."
const S_CONTACT_STOP := "Motion stopped at <value>: <BodyA> touches <BodyB> (<Set>)."
const S_STUDY_STOP := "Motion stopped at <time>: <BodyA> touches <BodyB> (<Set>)."
const S_CONTACT_START := "<BodyA> and <BodyB> already overlap at the start, so contact between them is not checked."
const S_CONTACT_NO_SETS := "Contact is on, but there is no enabled contact set. Right-click components to make one."
const S_CONTACT_THIN := "<Body> is only <t> thick and contact steps are <step>; it could pass through between steps. Set a smaller Step."
const S_CONTACT_STEPS := "This motion needs <n> contact steps; the most is 2,000. Raise Step or drive a shorter way."
const S_CONTACT_TOO_SLOW := "Checking contact for this motion would take about <s> (<n> steps × <p> pairs). Raise Step or take bodies out of the contact set."
const S_CONTACT_TIMEOUT := "Contact checking ran out of time at <value>; the motion stopped there."
## A first look cut short by a deadline that was already used up, not by the look's own time (fix
## round 4); <budget> is the caller's whole contact time.
const S_CONTACT_TIME_USED := "Contact checking had used up its <budget> before this motion could be checked."
const S_CONTACT_DEV := "Round faces are checked within <dev>, so contact closer than <tol> is not seen."
const S_CONTACT_SKIPPED := "<Body> takes no part in contact: <reason>."
const S_CONTACT_NATIVE := "Contact needs a newer Holo Forge native library than the one loaded."
const S_STUDY_TOO_SLOW := "Working out this study would take about <s>; the most is 20 s. Shorten it, lower the frame rate or turn contact off."
const S_MODELLED_VIEW := "Showing modelled positions while this tool is open."
const S_NEWER_ASSEMBLY := "This assembly was saved by a newer Holo Forge; it is shown but cannot be edited here."
const S_BAKE_NO_JOINTS := "Joints are baked only when Component Nodes is RigidBody3D."
const S_BAKE_HULL := "<Body> collides as its convex hull, which is <n>% larger than the body."
const S_BAKE_HALF_LIMIT := "<Joint> has only one limit; Godot needs both, so the open end is set to <value>."
const S_BAKE_CONE_WIDENED := "<Joint>'s limits were widened to a symmetric cone of <swing> and a twist of <twist> for Godot."
const S_BAKE_NOT_JOLT := "Joints were set up for Jolt Physics; with another 3D physics engine, joints fixed to the world may turn the other way."
const S_BAKE_NOT_BAKED := "Not baked (design only): <list>."
const S_EXPORT_POSED := "Bodies are written where the assembly places them."
const S_PLACE_GROUNDED := "<Comp> is grounded. Unground it to place it."
const S_NO_COMPONENTS := "Joints connect components, and this part has none. Make one with New Component."
const S_GROUP_SMALL := "A rigid group needs at least two components."
const S_LIMITS_ORDER := "Min must be below Max."
const S_REST_OUTSIDE := "Rest must lie between Min and Max."
## Not in the spec's C10 table (added in Stage 0, reported): the solver leaves out a stored
## placement that is not a finite rigid move instead of showing a bent or broken body.
const S_PLACEMENT_BAD := "<Comp>'s placement is not a rigid move (off by <d>), so it is shown where it was modelled."
## Not in the spec's C10 table (added in Stage 1, reported): C4.3 says a DOF cannot follow itself
## but gives no sentence for it.
const S_LINK_SELF := "A joint cannot follow itself. Pick another joint to follow."
## Not in the spec's C10 table (added in fix round 1, reported): cases that were silent or gave a
## false sentence before.
const S_CONTACT_THIN_AVERAGE := "<Body> is on average only <t> thick and contact steps are <step>; thin parts of it could pass through between steps. Set a smaller Step."
const S_CONTACT_UNCHECKED := "Motion stopped at <value>: contact between <BodyA> and <BodyB> could not be checked just past there. <Body>: <reason>"
const S_SNAP_FAR := "<Joint>'s pick on <Body> lies <dist> from the origin, where positions are stored only to about <step>, so the joint may be off by that much. Move the model nearer the origin."
const S_SNAP_MOVED := "<Joint>'s pick on <Body> is now in <Comp>, not in <Side>; it holds its last place. Edit the joint to pick again."
const S_SNAP_SUPPRESSED := "<Joint>'s pick is on <Body>, which is suppressed or not built; it holds its last place until <Body> is back."
const S_GROUP_LOOP_HOLDS := "<Group> closes a loop (<Comp> is also placed by a joint or grounding); it holds at this pose but is not kept rigid while you drive."
const S_GROUP_LOOP_OFF := "<Group> closes a loop (<Comp> is also placed by a joint or grounding) and is not kept rigid: <Comp> is off by <d> and <a> at this pose."
const S_LINK_EMPTY := "<Joint> cannot be driven: through its motion links, the limits of <A> and <B> leave no value that suits both. Edit the limits or the link."
const S_LINK_EMPTY_NEW := "That link would leave <Joint> no value that suits the limits of <A> and <B>. Edit the limits or the ratio."
const S_LIMITS_REVERSED := "<Joint>'s Min (<min>) is above its Max (<max>), so it cannot be driven. Edit the joint."
const S_VALUE_CLAMPED := "<Joint>'s stored value <value> is beyond its limit of <limit>; it is held at the limit."
const S_DRIVE_NOT_FINITE := "<Joint> cannot be driven to <value>: that is not a finite number."
const S_LINK_NOT_FINITE := "<Joint> cannot be driven: <Link>'s ratio or offset is not a finite number. Edit the link."
const S_RATIO_NOT_FINITE := "Ratio must be a finite number."
const S_LIMITS_LINKED_EMPTY := "Those limits would leave <Joint> no value that suits the limits of <A> and <B> through its motion links. Edit the limits or the link."
const S_DRIVE_SUPPRESSED := "<Joint> is suppressed. Unsuppress it to drive it."
const S_EXACT_EDITED := "The saved assembly was edited by hand (<n> changed); the edited values are used, the rest as saved."
## Not in the spec's C10 table (added in fix round 2, reported).
const S_STORED_NOT_FINITE := "<Item>'s <key> is <value> in the stored assembly, not a finite number. Edit or delete <Item>."
const S_CONTACT_NOT_FINITE := "Contact's <key> is <value> in the stored assembly, not a finite number. Set it in Contact Settings."
const S_CONTACT_TURNS := "This motion turns parts in contact <turns> in all, and contact is checked at every 5° of that: <n> steps; the most is 2,000. Drive a shorter way or in parts (Step does not change this count)."
const S_STUDY_KEY_TWICE := "<Joint> has two keys at <time> in <Study>; a motion cannot jump. Move or delete one of them."
const S_EXACT_UNREADABLE := "The saved assembly's exact copies could not be read (<why>), so its numbers are at text precision."
const S_EXACT_UNMATCHED := "The saved assembly was edited by hand: <m> could not be matched to their exact copies (an entry was renamed or edited), so they are at text precision; edited values are used, the rest as saved."
const S_EXACT_OLD := "The saved assembly was edited by hand; its exact copies are of an older kind that no longer lines up with it, so every number is at text precision."
## Added in fix round 3 (reported).
const S_CONTACT_THIN_SAMPLED := "<Body> has <n> triangles and its thickness was checked at <rays> of them, so a thin part elsewhere could still pass through between contact steps of <step>."

## Sentence id (as the spec writes it) -> text.
const SENTENCES := {
	"S-SAME-UNIT": S_SAME_UNIT, "S-SIDES-SWAPPED": S_SIDES_SWAPPED, "S-NESTED-MOVES": S_NESTED_MOVES,
	"S-MESH-SNAP": S_MESH_SNAP, "S-GROUP-NOT-ROUND": S_GROUP_NOT_ROUND, "S-SNAP-LOST": S_SNAP_LOST,
	"S-WAITING": S_WAITING, "S-MISSING-COMPONENT": S_MISSING_COMPONENT, "S-LIMITS-EQUAL": S_LIMITS_EQUAL,
	"S-LOOP-OFF": S_LOOP_OFF, "S-LOOP-HOLDS": S_LOOP_HOLDS, "S-SOLVE-FAULT": S_SOLVE_FAULT,
	"S-PLACE-JOINTED": S_PLACE_JOINTED, "S-LIMIT": S_LIMIT, "S-LINK-LIMIT": S_LINK_LIMIT,
	"S-LINK-SECOND-DRIVER": S_LINK_SECOND_DRIVER, "S-LINK-CIRCLE": S_LINK_CIRCLE, "S-LINK-ZERO": S_LINK_ZERO,
	"S-STUDY-FOLLOWER": S_STUDY_FOLLOWER, "S-STUDY-CLAMPED": S_STUDY_CLAMPED, "S-CONTACT-STOP": S_CONTACT_STOP,
	"S-STUDY-STOP": S_STUDY_STOP, "S-CONTACT-START": S_CONTACT_START, "S-CONTACT-NO-SETS": S_CONTACT_NO_SETS,
	"S-CONTACT-THIN": S_CONTACT_THIN, "S-CONTACT-STEPS": S_CONTACT_STEPS, "S-CONTACT-TOO-SLOW": S_CONTACT_TOO_SLOW,
	"S-CONTACT-TIMEOUT": S_CONTACT_TIMEOUT, "S-CONTACT-DEV": S_CONTACT_DEV, "S-CONTACT-SKIPPED": S_CONTACT_SKIPPED,
	"S-CONTACT-NATIVE": S_CONTACT_NATIVE, "S-STUDY-TOO-SLOW": S_STUDY_TOO_SLOW, "S-MODELLED-VIEW": S_MODELLED_VIEW,
	"S-NEWER-ASSEMBLY": S_NEWER_ASSEMBLY, "S-BAKE-NO-JOINTS": S_BAKE_NO_JOINTS, "S-BAKE-HULL": S_BAKE_HULL,
	"S-BAKE-HALF-LIMIT": S_BAKE_HALF_LIMIT, "S-BAKE-CONE-WIDENED": S_BAKE_CONE_WIDENED, "S-BAKE-NOT-JOLT": S_BAKE_NOT_JOLT,
	"S-BAKE-NOT-BAKED": S_BAKE_NOT_BAKED, "S-EXPORT-POSED": S_EXPORT_POSED, "S-PLACE-GROUNDED": S_PLACE_GROUNDED,
	"S-NO-COMPONENTS": S_NO_COMPONENTS, "S-GROUP-SMALL": S_GROUP_SMALL, "S-LIMITS-ORDER": S_LIMITS_ORDER,
	"S-REST-OUTSIDE": S_REST_OUTSIDE, "S-PLACEMENT-BAD": S_PLACEMENT_BAD, "S-LINK-SELF": S_LINK_SELF,
	"S-CONTACT-THIN-AVERAGE": S_CONTACT_THIN_AVERAGE, "S-CONTACT-UNCHECKED": S_CONTACT_UNCHECKED, "S-SNAP-FAR": S_SNAP_FAR,
	"S-SNAP-MOVED": S_SNAP_MOVED, "S-SNAP-SUPPRESSED": S_SNAP_SUPPRESSED, "S-GROUP-LOOP-HOLDS": S_GROUP_LOOP_HOLDS,
	"S-GROUP-LOOP-OFF": S_GROUP_LOOP_OFF, "S-LINK-EMPTY": S_LINK_EMPTY, "S-LINK-EMPTY-NEW": S_LINK_EMPTY_NEW,
	"S-LIMITS-REVERSED": S_LIMITS_REVERSED, "S-VALUE-CLAMPED": S_VALUE_CLAMPED, "S-DRIVE-NOT-FINITE": S_DRIVE_NOT_FINITE,
	"S-LINK-NOT-FINITE": S_LINK_NOT_FINITE, "S-DRIVE-SUPPRESSED": S_DRIVE_SUPPRESSED, "S-EXACT-EDITED": S_EXACT_EDITED,
	"S-RATIO-NOT-FINITE": S_RATIO_NOT_FINITE, "S-LIMITS-LINKED-EMPTY": S_LIMITS_LINKED_EMPTY,
	"S-STORED-NOT-FINITE": S_STORED_NOT_FINITE, "S-CONTACT-NOT-FINITE": S_CONTACT_NOT_FINITE, "S-CONTACT-TURNS": S_CONTACT_TURNS,
	"S-STUDY-KEY-TWICE": S_STUDY_KEY_TWICE, "S-EXACT-UNREADABLE": S_EXACT_UNREADABLE, "S-EXACT-UNMATCHED": S_EXACT_UNMATCHED,
	"S-EXACT-OLD": S_EXACT_OLD, "S-CONTACT-THIN-SAMPLED": S_CONTACT_THIN_SAMPLED, "S-CONTACT-TIME-USED": S_CONTACT_TIME_USED,
}


## "NaN", "INF" or "-INF" for a sentence about a number that is not finite.
static func not_finite_text(value: float) -> String:
	if is_nan(value):
		return "NaN"
	return "INF" if value > 0.0 else "-INF"


## S-STORED-NOT-FINITE for the first number of a joint entry that is not finite and that the solve
## reads (each DOF's value, a limit that is on, the angle, the offset), else "". item names the
## joint (its name when "").
static func joint_not_finite(joint: Dictionary, item := "") -> String:
	var joint_name := item if item != "" else str(joint.get("name", joint.get("id", "")))
	var names: Array = dof_names(str(joint.get("type", DEFAULT_TYPE)))
	var dofs: Array = joint.get("dofs", []) if joint.get("dofs") is Array else []
	for i in dofs.size():
		if not (dofs[i] is Dictionary):
			continue
		var d: Dictionary = dofs[i]
		var prefix := "" if names.size() <= 1 or i >= names.size() else str(names[i]) + " "
		var checks := [["value", true], ["min", bool(d.get("limited_min", false))], ["max", bool(d.get("limited_max", false))]]
		for check: Array in checks:
			var value: Variant = d.get(check[0], 0.0)
			if bool(check[1]) and (value is float or value is int) and not is_finite(float(value)):
				return fill(S_STORED_NOT_FINITE, {"Item": joint_name, "key": prefix + str(check[0]), "value": not_finite_text(float(value))})
	if bool(joint.get("as_built", false)):
		# (An as-built joint reads neither its angle nor its offset.)
		return ""
	var angle: Variant = joint.get("angle", 0.0)
	if (angle is float or angle is int) and not is_finite(float(angle)):
		return fill(S_STORED_NOT_FINITE, {"Item": joint_name, "key": "angle", "value": not_finite_text(float(angle))})
	var offset: Variant = joint.get("offset", [])
	if offset is Array or offset is PackedFloat64Array or offset is PackedFloat32Array or offset is Vector3:
		var list: Array = [offset.x, offset.y, offset.z] if offset is Vector3 else Array(offset)
		for value in list:
			if (value is float or value is int) and not is_finite(float(value)):
				return fill(S_STORED_NOT_FINITE, {"Item": joint_name, "key": "offset", "value": not_finite_text(float(value))})
	return ""


## S-CONTACT-NOT-FINITE for the first contact setting (tolerance, step, precision) that is not
## finite, else "".
static func contact_not_finite(contact: Dictionary) -> String:
	for key in ["tolerance", "step", "precision"]:
		var value: Variant = contact.get(key, CONTACT_DEFAULT[key])
		if (value is float or value is int) and not is_finite(float(value)):
			return fill(S_CONTACT_NOT_FINITE, {"key": key, "value": not_finite_text(float(value))})
	return ""


## sentence with each <key> replaced by str(values[key]). Values are written by the caller in
## document units; keys without a value stay as they are.
static func fill(sentence: String, values: Dictionary) -> String:
	var out := sentence
	for key in values:
		out = out.replace("<%s>" % str(key), str(values[key]))
	return out


# --- Exact doubles in text scenes ----------------------------------------------------------------

## A text scene (.tscn / .tres, where the part's document lives) prints a double that a float32
## holds exactly in float32-shortest form and reads it back as another double; a negative zero and
## the smallest doubles come back as 0 (measured in Stage 0: 0.10000000149011612 came back as
## 0.1). So the document also stores every double of its assembly as bytes (exact_text(), written
## with the scene through doc.assembly_exact) and puts them back after loading (apply_exact()).

## How far a double may come back from text and still be the one stored (float32-shortest keeps
## about 7 significant digits; doubles below float32's range come back as 0).
const EXACT_RELATIVE := 1e-6
const EXACT_ABSOLUTE := 1e-37


## Fix round 1 (P5): the exact copies are kept by path (format 2, "2:" + base64 of var_to_bytes of
## {path: float or PackedFloat64Array}; a path names dictionary keys, and list entries by their
## "id" when it is unique in the list, else by index), and each value is checked on its own: a
## value that is what the text gives for its exact copy (str_to_var(var_to_str(exact)), the text
## scene's own writer) takes the exact copy; any other value was edited by hand and is kept, and
## the load leaves a note (S-EXACT-EDITED, load_notes(), shown in the solve's warnings). Format 1
## (sequential doubles, Stage 0) is still read.
##
## Fix round 2 (PT2): format 3 ("3:" + a digest of the base64 text + ":" + the base64 of format 2)
## is written, so a damaged copy (a changed or missing character) is found before anything is
## decoded; damaged copies of any format, and text that is not base64, leave S-EXACT-UNREADABLE and
## no engine errors. List entries without a unique id that are Motion Study keys ({"joint", "dof",
## "time"}) are named by their joint, DOF and time as the text gives it, so removing or adding a key
## leaves the others matched. An entry whose key has no saved copies (an id renamed by hand) takes
## the saved entry of that list that no current entry claims and whose numbers the text gives
## exactly as they are now (matched by content). Present numbers left without a copy while saved
## copies went unused leave S-EXACT-UNMATCHED. Format 1 copies (kept by position) are used only
## when every number is what the text gives for its copy; else none is (S-EXACT-OLD), since a
## position no longer says which number a copy was.
##
## Fix round 3: format 2 is no longer read. It was written only while Phase 8 was being fixed (no
## user's file has it) and carries no digest, so damage to it could not be told from a hand edit.
## Its copies are left unused: the numbers are what the text gave, used is false and the note is
## S-EXACT-UNREADABLE (EXACT_FORMAT_2_WHY). Nothing of it is decoded, so it prints no engine error.
const EXACT_FORMAT := "3:"
## The format 2 prefix (fix rounds 1 and 2), recognized and not read.
const EXACT_FORMAT_2 := "2:"
## Why format 2 copies are not used (S-EXACT-UNREADABLE's <why>).
const EXACT_FORMAT_2_WHY := "they are of a kind made only while Holo Forge was being built, which it no longer reads"
## Characters of the digest kept in format 3.
const EXACT_DIGEST := 16
## Load notes kept (the oldest dropped).
const NOTES_KEPT := 16
## [[assembly Dictionary, PackedStringArray]]: the notes apply_exact() left for an assembly (found
## by identity: an edit after loading makes a new assembly and the note goes).
static var _notes := []


## Every double in assembly by path, as text for the scene; "" when it holds none.
static func exact_text(assembly: Dictionary) -> String:
	var values := {}
	_collect_paths(assembly, "", values)
	if values.is_empty():
		return ""
	var body := Marshalls.raw_to_base64(var_to_bytes(values))
	return EXACT_FORMAT + body.sha256_text().substr(0, EXACT_DIGEST) + ":" + body


## Puts the exact copies of exact_text() back into assembly (in place): each value the text gave
## from its exact copy takes the copy; a value edited by hand stays (and is counted in a load
## note, S-EXACT-EDITED). Damaged copies leave S-EXACT-UNREADABLE, numbers that lost their copies
## S-EXACT-UNMATCHED, format 1 copies that no longer line up S-EXACT-OLD. True when any exact copy
## was used.
static func apply_exact(assembly: Dictionary, text: String) -> bool:
	if text == "" or assembly.is_empty():
		return false
	var counts := [0, 0, 0]
	var notes := PackedStringArray()
	var decoded := _decode_exact(text)
	if decoded.has("error"):
		notes.append(fill(S_EXACT_UNREADABLE, {"why": decoded.error}))
	elif decoded.has("values"):
		var exact: Dictionary = decoded.values
		var ctx := {"exact": exact, "index": _path_index(exact), "used": {}, "counts": counts}
		_apply_paths(assembly, "", ctx)
		var unused := exact.size() - (ctx.used as Dictionary).size()
		if int(counts[2]) > 0 and unused > 0:
			notes.append(fill(S_EXACT_UNMATCHED, {"m": _numbers(int(counts[2]))}))
		elif int(counts[1]) > 0:
			notes.append(fill(S_EXACT_EDITED, {"n": _numbers(int(counts[1]))}))
	else:
		if not _apply_sequential(assembly, decoded.sequential, counts):
			notes.append(S_EXACT_OLD)
	_set_notes(assembly, notes)
	return int(counts[0]) > 0


## "1 number" or "<n> numbers".
static func _numbers(n: int) -> String:
	return "1 number" if n == 1 else "%d numbers" % n


## The exact copies in text: {"values": {path: value}} (formats 2 and 3), {"sequential":
## PackedFloat64Array} (format 1), or {"error": why} when they can't be read. Nothing damaged is
## decoded: format 3's digest is checked first, and text that is not base64 is refused.
static func _decode_exact(text: String) -> Dictionary:
	var damaged := {"error": "they are damaged"}
	if text.begins_with(EXACT_FORMAT):
		var rest := text.substr(EXACT_FORMAT.length())
		if rest.find(":") != EXACT_DIGEST:
			return damaged
		var body := rest.substr(EXACT_DIGEST + 1)
		if body.sha256_text().substr(0, EXACT_DIGEST) != rest.substr(0, EXACT_DIGEST):
			return damaged
		return _decode_values(body)
	if text.begins_with(EXACT_FORMAT_2):
		# (Fix round 3: format 2 was written only while fix round 2 was made, never in a user's
		# file, and has no digest to find damage by: it is not read, nothing is decoded.)
		return {"error": EXACT_FORMAT_2_WHY}
	if not _is_base64(text):
		return {"error": "they are not in a form this Holo Forge reads"}
	var raw := Marshalls.base64_to_raw(text)
	if raw.size() % 8 != 0:
		return damaged
	return {"sequential": raw.to_float64_array()}


static func _decode_values(body: String) -> Dictionary:
	if not _is_base64(body):
		return {"error": "they are damaged"}
	var decoded: Variant = bytes_to_var(Marshalls.base64_to_raw(body))
	if not (decoded is Dictionary):
		return {"error": "they are damaged"}
	return {"values": decoded}


## True for non-empty base64 text (whole groups of 4, padding only at the end).
static func _is_base64(text: String) -> bool:
	if text.is_empty() or text.length() % 4 != 0:
		return false
	var at := text.length()
	while at > 0 and text[at - 1] == "=":
		at -= 1
	if text.length() - at > 2:
		return false
	for i in at:
		var c := text.unicode_at(i)
		if not ((c >= 65 and c <= 90) or (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 43 or c == 47):
			return false
	return true


## The load notes apply_exact() left for this assembly dictionary (S-EXACT-EDITED), or none.
static func load_notes(assembly: Dictionary) -> PackedStringArray:
	for entry: Array in _notes:
		if is_same(entry[0], assembly):
			return entry[1]
	return PackedStringArray()


static func _set_notes(assembly: Dictionary, notes: PackedStringArray) -> void:
	for i in range(_notes.size() - 1, -1, -1):
		if is_same(_notes[i][0], assembly):
			_notes.remove_at(i)
	if notes.is_empty():
		return
	if _notes.size() >= NOTES_KEPT:
		_notes.remove_at(0)
	_notes.append([assembly, notes])


## Format 1: every double in _collect_doubles() order. Used when every one is what the text gives
## for its copy (or the copy itself); else none is, and false is returned (a position no longer
## says which number a copy was: S-EXACT-OLD).
static func _apply_sequential(assembly: Dictionary, exact: PackedFloat64Array, counts: Array) -> bool:
	var now := PackedFloat64Array()
	_collect_doubles(assembly, now)
	if exact.size() != now.size():
		return false
	for i in now.size():
		# (Format 1 lines up within EXACT_RELATIVE, as it was read in Stage 0: an edit inside that
		# is not seen in a format 1 scene.)
		var e := exact[i]
		if not (_same_double(_text_double(e), now[i]) or _same_double(e, now[i]) or absf(e - now[i]) <= EXACT_RELATIVE * maxf(absf(e), absf(now[i])) + EXACT_ABSOLUTE):
			return false
	_put_doubles(assembly, exact, [0])
	counts[0] = now.size()
	return true


## What a text scene gives back for a double (its own writer and reader).
static func _text_double(value: float) -> float:
	return float(str_to_var(var_to_str(value)))


## The child path of key in a container at path.
static func _child_path(path: String, key: Variant) -> String:
	return "%s/%s" % [path, key if key is String else var_to_str(key)]


## The path keys of a list's entries: "#" + id when the entry has an id unique in the list; a
## Motion Study key ({"joint", "dof", "time"}, no id) "@joint|dof|time" with its time as the text
## gives it ("~n" after it for the n-th repeat); else the index.
static func _list_keys(list: Array) -> Array:
	var seen := {}
	for entry in list:
		if entry is Dictionary and entry.get("id") is String and str(entry.id) != "":
			seen[entry.id] = int(seen.get(entry.id, 0)) + 1
	var keys := []
	var repeats := {}
	for i in list.size():
		var entry: Variant = list[i]
		if entry is Dictionary and entry.get("id") is String and int(seen.get(entry.id, 0)) == 1:
			keys.append("#" + str(entry.id))
		elif entry is Dictionary and not entry.has("id") and entry.get("joint") is String and (entry.get("time") is float or entry.get("time") is int) and (entry.get("dof") is int or entry.get("dof") is float):
			var key := "@%s|%d|%s" % [str(entry.joint), int(entry.dof), var_to_str(_text_double(float(entry.time))).replace("/", "_")]
			var n := int(repeats.get(key, 0))
			repeats[key] = n + 1
			keys.append(key if n == 0 else "%s~%d" % [key, n])
		else:
			keys.append(str(i))
	return keys


static func _collect_paths(value: Variant, path: String, out: Dictionary) -> void:
	match typeof(value):
		TYPE_FLOAT:
			out[path] = value
		TYPE_PACKED_FLOAT64_ARRAY:
			out[path] = PackedFloat64Array(value)
		TYPE_ARRAY:
			var keys := _list_keys(value)
			for i in (value as Array).size():
				_collect_paths(value[i], _child_path(path, keys[i]), out)
		TYPE_DICTIONARY:
			for key in value:
				_collect_paths(value[key], _child_path(path, key), out)


## True when two doubles are the same value (NaN matches NaN).
static func _same_double(a: float, b: float) -> bool:
	return a == b or (is_nan(a) and is_nan(b))


## True when now is what the text gives for the exact copy e (or e itself): a float or a
## PackedFloat64Array of the same size.
static func _text_equal(e: Variant, now: Variant) -> bool:
	if typeof(e) != typeof(now):
		return false
	if e is float:
		return _same_double(_text_double(e), now) or _same_double(e, now)
	if e is PackedFloat64Array:
		var copy := PackedFloat64Array(e)
		var values := PackedFloat64Array(now)
		if copy.size() != values.size():
			return false
		var through: Variant = str_to_var(var_to_str(copy))
		var text: PackedFloat64Array = through if through is PackedFloat64Array and (through as PackedFloat64Array).size() == copy.size() else copy
		for i in copy.size():
			if not (_same_double(text[i], values[i]) or _same_double(copy[i], values[i])):
				return false
		return true
	return false


## The saved paths by parent: {parent path: {child key: true}}.
static func _path_index(exact: Dictionary) -> Dictionary:
	var index := {}
	for p in exact:
		var text := str(p)
		var at := 0
		while at < text.length():
			var next := text.find("/", at + 1)
			var end := next if next >= 0 else text.length()
			var parent := text.substr(0, at)
			if not index.has(parent):
				index[parent] = {}
			index[parent][text.substr(at + 1, end - at - 1)] = true
			if next < 0:
				break
			at = next
	return index


## The saved key of the list at path that no current entry claims and whose saved numbers are
## exactly what entry holds now as the text gives them (an entry whose id was renamed by hand), or
## "" when none or more than one is.
static func _content_match(entry: Variant, path: String, saved: Dictionary, claimed: Dictionary, ctx: Dictionary) -> String:
	if not (entry is Dictionary or entry is Array):
		return ""
	var mine := {}
	_collect_paths(entry, "", mine)
	if mine.is_empty():
		return ""
	var exact: Dictionary = ctx.exact
	var found := ""
	for candidate in saved:
		if claimed.has(candidate):
			continue
		var prefix := _child_path(path, candidate)
		var same := true
		for rel in mine:
			if not exact.has(prefix + str(rel)) or not _text_equal(exact[prefix + str(rel)], mine[rel]):
				same = false
				break
		if not same:
			continue
		var held := 0
		for p in exact:
			if str(p).begins_with(prefix + "/"):
				held += 1
		if held != mine.size():
			continue
		if found != "":
			return ""
		found = str(candidate)
	return found


## value with the exact copies put back where the text gave them. ctx: {"exact": {path: copy},
## "index": _path_index(exact), "used": {path: true} (copies looked at), "counts": [used, edited,
## present numbers without a copy]}. Containers are changed in place; floats and packed arrays are
## returned for the caller to store.
static func _apply_paths(value: Variant, path: String, ctx: Dictionary) -> Variant:
	var exact: Dictionary = ctx.exact
	var counts: Array = ctx.counts
	match typeof(value):
		TYPE_FLOAT:
			var e: Variant = exact.get(path)
			if typeof(e) != TYPE_FLOAT:
				counts[2] += 1
				return value
			ctx.used[path] = true
			if _text_equal(e, value):
				counts[0] += 1
				return e
			counts[1] += 1
			return value
		TYPE_PACKED_FLOAT64_ARRAY:
			var e: Variant = exact.get(path)
			var now := PackedFloat64Array(value)
			if typeof(e) != TYPE_PACKED_FLOAT64_ARRAY:
				counts[2] += now.size()
				return value
			ctx.used[path] = true
			var copy := PackedFloat64Array(e)
			if copy.size() != now.size():
				counts[1] += 1
				return value
			var through: Variant = str_to_var(var_to_str(copy))
			var text: PackedFloat64Array = through if through is PackedFloat64Array and (through as PackedFloat64Array).size() == copy.size() else copy
			for i in now.size():
				if _same_double(text[i], now[i]) or _same_double(copy[i], now[i]):
					counts[0] += 1
					now[i] = copy[i]
				else:
					counts[1] += 1
			return now
		TYPE_ARRAY:
			var list: Array = value
			var keys := _list_keys(list)
			var saved: Dictionary = (ctx.index as Dictionary).get(path, {})
			var claimed := {}
			for key in keys:
				if saved.has(key):
					claimed[key] = true
			for i in list.size():
				var key: String = keys[i]
				if not saved.has(key):
					var found := _content_match(list[i], path, saved, claimed, ctx)
					if found != "":
						claimed[found] = true
						key = found
				list[i] = _apply_paths(list[i], _child_path(path, key), ctx)
		TYPE_DICTIONARY:
			var map: Dictionary = value
			for key in map.keys():
				map[key] = _apply_paths(map[key], _child_path(path, key), ctx)
	return value


static func _collect_doubles(value: Variant, out: PackedFloat64Array) -> void:
	match typeof(value):
		TYPE_FLOAT:
			out.append(value)
		TYPE_PACKED_FLOAT64_ARRAY:
			out.append_array(value)
		TYPE_ARRAY:
			for inner in value:
				_collect_doubles(inner, out)
		TYPE_DICTIONARY:
			for key in _sorted_keys(value):
				_collect_doubles(value[key], out)


## value with its doubles taken from exact, in _collect_doubles() order (cursor = [next index]).
## Containers are changed in place; packed arrays (values) are written back by the caller.
static func _put_doubles(value: Variant, exact: PackedFloat64Array, cursor: Array) -> Variant:
	match typeof(value):
		TYPE_FLOAT:
			cursor[0] += 1
			return exact[cursor[0] - 1]
		TYPE_PACKED_FLOAT64_ARRAY:
			var packed := PackedFloat64Array(value)
			for i in packed.size():
				packed[i] = exact[cursor[0]]
				cursor[0] += 1
			return packed
		TYPE_ARRAY:
			var list: Array = value
			for i in list.size():
				list[i] = _put_doubles(list[i], exact, cursor)
		TYPE_DICTIONARY:
			var map: Dictionary = value
			for key in _sorted_keys(map):
				map[key] = _put_doubles(map[key], exact, cursor)
	return value


static func _sorted_keys(map: Dictionary) -> Array:
	var keys := map.keys()
	keys.sort_custom(func(a: Variant, b: Variant) -> bool: return var_to_str(a) < var_to_str(b))
	return keys


# --- Schema ------------------------------------------------------------------------------------

## A full empty assembly (every key at its default).
static func defaults() -> Dictionary:
	var counters := {}
	for kind in KIND_LISTS:
		counters[kind] = 0
	return {
		"version": VERSION, "placements": {}, "grounded": {}, "origins": [], "joints": [], "rigid_groups": [], "links": [],
		"contact": CONTACT_DEFAULT.duplicate(true), "contact_sets": [], "studies": [], "counters": counters,
	}


## A deep copy of assembly with every missing key filled with its default, down to the entries of
## its lists (a joint's sides and snaps; its "dofs" sized to its type, C2.5). Nothing stored is
## changed or dropped: keys this version does not know are kept, and so is a newer "version" (an
## assembly from a newer Holo Forge only gets its missing top-level keys). Never writes into
## assembly.
static func normalized(assembly: Dictionary) -> Dictionary:
	var out: Dictionary = assembly.duplicate(true)
	var newer := is_newer(out)
	var base := defaults()
	for key in base:
		if not out.has(key):
			out[key] = base[key]
		elif key != "version" and not newer and typeof(out[key]) != typeof(base[key]):
			# A value of the wrong kind cannot be read as this key (a broken file): the default stands in.
			out[key] = base[key]
	if not (out.version is int or out.version is float):
		out["version"] = VERSION
	if newer:
		return out
	_fill_missing(out.contact, CONTACT_DEFAULT)
	_fill_missing(out.counters, base.counters)
	for list_key in LIST_DEFAULTS:
		var entries: Array = out[list_key]
		for i in entries.size():
			if not (entries[i] is Dictionary):
				continue
			var entry: Dictionary = entries[i]
			if list_key == "joints" and not entry.has("slide_axis"):
				# (Before the generic fill, which would give every type JOINT_DEFAULT's "z".)
				entry["slide_axis"] = DEFAULT_SLIDE_AXIS.get(str(entry.get("type", DEFAULT_TYPE)), "z")
			_fill_missing(entry, LIST_DEFAULTS[list_key])
			_fill_snap(entry.get("snap"))
			if list_key == "joints":
				_normalize_joint(entry)
	return out


## True when assembly was saved by a newer Holo Forge (its version is above VERSION).
static func is_newer(assembly: Dictionary) -> bool:
	var version: Variant = assembly.get("version", VERSION)
	return (version is int or version is float) and float(version) > VERSION


## The sentence every assembly edit is refused with, or "" when assembly may be edited.
static func edit_refusal(assembly: Dictionary) -> String:
	return S_NEWER_ASSEMBLY if is_newer(assembly) else ""


## A new id of kind ("joint", "origin", "group", "link", "contact", "study"): the kind and the
## next number of its counter ("joint1", "joint2", ...). The counter is stored in
## assembly.counters, so a deleted entry's id is never given again; ids already in use are skipped
## too. Writes into assembly.
static func new_id(assembly: Dictionary, kind: String) -> String:
	if not KIND_LISTS.has(kind):
		push_error("Holo Forge assembly: unknown id kind \"%s\"." % kind)
		return ""
	if not (assembly.get("counters") is Dictionary):
		assembly["counters"] = {}
	var counters: Dictionary = assembly.counters
	var used := {}
	var entries: Variant = assembly.get(KIND_LISTS[kind], [])
	if entries is Array:
		for entry in entries:
			if entry is Dictionary:
				used[str((entry as Dictionary).get("id", ""))] = true
	var n := int(counters.get(kind, 0))
	var id := ""
	while true:
		n += 1
		id = "%s%d" % [kind, n]
		if not used.has(id):
			break
	counters[kind] = n
	return id


## The display name a new entry with this id starts with ("joint3" -> "Joint3").
static func name_for(kind: String, id: String) -> String:
	return "%s%s" % [KIND_NAMES.get(kind, kind.capitalize()), id.trim_prefix(kind)]


## A component's stored placement as a fresh xform64: identity when it has none, empty when the
## stored value is not 12 numbers (the solver checks that it is a finite rigid move).
static func placement(assembly: Dictionary, component_id: String) -> PackedFloat64Array:
	var placements: Variant = assembly.get("placements", {})
	if not (placements is Dictionary) or not (placements as Dictionary).has(component_id):
		return XFORM.identity()
	var stored: Variant = placements[component_id]
	if stored is PackedFloat64Array or stored is Array or stored is PackedFloat32Array:
		var out := PackedFloat64Array(stored)
		if out.size() == 12:
			return out
	return PackedFloat64Array()


## True when the component is grounded (only top-level components can be; the solver ignores the
## flag on a nested one).
static func is_grounded(assembly: Dictionary, component_id: String) -> bool:
	var grounded: Variant = assembly.get("grounded", {})
	return grounded is Dictionary and bool((grounded as Dictionary).get(component_id, false))


## The DOF names of a joint type (C2.5); empty for an unknown type.
static func dof_names(joint_type: String) -> Array:
	return (DOF_NAMES.get(joint_type, []) as Array).duplicate()


## True for a rotational DOF ("rot_*"), false for a slide.
static func is_rotation(dof_name: String) -> bool:
	return dof_name.begins_with("rot")


## The "dofs" of a joint changed from old_type to new_type: a DOF whose name exists in both
## types keeps its entry, the others start at their defaults (value 0, no limits, rest 0).
static func retype_dofs(old_type: String, old_dofs: Array, new_type: String) -> Array:
	var old_names := dof_names(old_type)
	var out := []
	for dof_name in dof_names(new_type):
		var at := old_names.find(dof_name)
		if at >= 0 and at < old_dofs.size() and old_dofs[at] is Dictionary:
			var kept: Dictionary = (old_dofs[at] as Dictionary).duplicate(true)
			_fill_missing(kept, DOF_DEFAULT)
			out.append(kept)
		else:
			out.append(DOF_DEFAULT.duplicate(true))
	return out


## A joint's sides and snaps get their missing keys, and its "dofs" exactly the length its type
## has (extra entries dropped, missing ones added at their defaults). An unknown type keeps its
## DOFs as they are.
static func _normalize_joint(joint: Dictionary) -> void:
	for side in ["a", "b"]:
		if joint.get(side) is Dictionary:
			_fill_missing(joint[side], SIDE_DEFAULT)
			_fill_snap(joint[side].get("snap"))
	var joint_type := str(joint.get("type", DEFAULT_TYPE))
	if not DOF_NAMES.has(joint_type):
		return
	var dofs: Array = joint.dofs if joint.get("dofs") is Array else []
	var count := (DOF_NAMES[joint_type] as Array).size()
	var out := []
	for i in count:
		var dof: Dictionary = (dofs[i] as Dictionary) if i < dofs.size() and dofs[i] is Dictionary else {}
		_fill_missing(dof, DOF_DEFAULT)
		out.append(dof)
	joint["dofs"] = out


## A stored snap gets its missing keys, "frame" (identity) included.
static func _fill_snap(snap: Variant) -> void:
	if not (snap is Dictionary):
		return
	_fill_missing(snap, SNAP_DEFAULT)
	if not (snap as Dictionary).has("frame"):
		snap["frame"] = XFORM.identity()


## Adds the keys of defaults that target lacks (deep copies; values already there are kept).
static func _fill_missing(target: Variant, defaults_entry: Dictionary) -> void:
	if not (target is Dictionary):
		return
	for key in defaults_entry:
		if not (target as Dictionary).has(key):
			var value: Variant = defaults_entry[key]
			target[key] = value.duplicate(true) if value is Dictionary or value is Array else value
