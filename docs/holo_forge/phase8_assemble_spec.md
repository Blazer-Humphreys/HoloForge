# Holo Forge Phase 8: Assemble (components, joints, motion)

Work order for executing AI agents. You get only this document, the approved plan (`C:\Users\Blaze\.claude\plans\can-we-create-a-idempotent-shannon.md`, section "Phase 8" and the Assemble rows of the tool matrix) and the code. Everything the teams must agree on is written as a **contract** (C1 to C10). Do not change a contract on your own. If one cannot work, stop and report it with a concrete counter-proposal.

Written 2026-11-13 from:
- an audit of the Holo Forge code after Phase 7 (complete 2026-11-13; 55 headless tests, 10 editor hooks);
- the Phase 7 spec (`docs/holo_forge/phase7_mesh_spec.md`), whose structure this file copies and whose section 10 lessons are binding here (0.5);
- the Godot 4.7 class reference for `Joint3D`, `HingeJoint3D`, `SliderJoint3D`, `ConeTwistJoint3D` and `Generic6DOFJoint3D` (read 2026-11-13; facts in C8.1, unverified items marked **verify**);
- `project.godot`: the 3D physics engine is **Jolt Physics** (`3d/physics_engine="Jolt Physics"`).

No Phase 8 code exists yet. Every timing number is a **target to measure**. Section 8.1 lists what is still unverified.

---

## 0. Ground rules (read first)

### 0.1 Paths and names (the plan's names are out of date)

The plan says `holo_cad`, a "CAD" tab and `holo_cad_assembly_test`. The real names are:

| What | Path / name |
|---|---|
| Addon root (**A**) | `D:\Hover_Board_Racing\Godot_Board_Racing\godot-board-racing\addons\holo_forge` (main-screen tab "Forge") |
| Native root (**N**) | `D:\Hover_Board_Racing\Godot_Board_Racing\holo_forge_native` (CMakeLists.txt, vcpkg.json, src/) |
| Build tree | `C:\Users\Blaze\holo_forge_build\build` |
| Build lock | `C:\Users\Blaze\holo_forge_build\build.lock` (a folder; see 0.5 #9) |
| Backups | `C:\Users\Blaze\holo_forge_build\phase8_backup\<team>\<path relative to the project or to N>` (0.5 #10) |
| Tests | `D:\Hover_Board_Racing\Godot_Board_Racing\godot-board-racing\tests\holo_forge_*_test.gd` |
| Godot | `D:\Hover_Board_Racing\Godot_Board_Racing\Godot_v4.7.1-stable_win64.exe\Godot_v4.7.1-stable_win64_console.exe` |
| New GDScript | `A\core\assembly\*.gd`, `A\tools\assemble_*.gd`, `A\ui\assembly_*.gd`, `A\ui\motion_study_panel.gd` |
| New native code | `N\src\mesh_contact.cpp`, `N\src\mesh_contact.h` (one new `CadMesh` method, C5.1) |
| New icons | `A\icons\assemble\*.svg` (6.3) |
| New headless acceptance test | `tests/holo_forge_assembly_test.gd` (the plan's `holo_cad_assembly_test`) |
| New editor hook | `--holo-forge-assemble-editor-test`, running `tests/holo_forge_assembly_editor_test.gd` |

Line numbers in this document are hints only. Find code by **function name**.

### 0.2 Code rules (existing conventions, mandatory)

- **Class cache.** Every addon script starts with `@tool` and has **no** `class_name`. Other scripts are reached only through `const X := preload("res://addons/holo_forge/...")`.
- **Native classes.** Reach them only through `ClassDB.class_exists(...)` and `ClassDB.instantiate(...)`. Hold them in variables typed `RefCounted`. Every script must still parse when the DLL is missing. If an older DLL without `CadMesh.overlap` is loaded (`ClassDB.class_has_method("CadMesh", "overlap")` is false), contact is off with the sentence `S-CONTACT-NATIVE` (C10) and everything else works.
- **Editor-only calls.** Guard every `EditorInterface` call with `Engine.is_editor_hint()`. The headless tests build `WORKSPACE.new()` without an editor.
- **Packed arrays in Dictionaries are values.** After you change a Packed array read from a Dictionary, write it back.
- **Resources in Dictionaries are shared by `duplicate(true)`.** The assembly dictionary holds no Resources (C1), so `duplicate(true)` copies it fully.
- **Precision. All assembly math is in doubles.** Godot `Vector3`, `Basis` and `Transform3D` are float32 in this build. The solver, snaps, limits, links and contact sweep work on `PackedFloat64Array(12)` transforms through `core/assembly/xform64.gd` (C1.3) and on plain `float` (GDScript `float` is a double). Convert to `Transform3D` only at the edge: viewport holders, the bake, and the inspect calls that take `Transform3D`. Never round-trip a stored value through `Vector3`.
- **Text resources.** A double written to a text `.tscn`/`.tres` may come back one ulp off (the `form.gd` `store_exact` lesson). Stage 0 must prove that a `PackedFloat64Array` and a `float` inside the `assembly` Dictionary survive `ResourceSaver.save` + `load` of a text scene **bit for bit** (5.1 #4). If they do not, store every double as text with the existing exact-storage helper in `core/features/form.gd` (find `store_exact` by name) and say so in the report.
- **Units.** Lengths in **meters**, angles in **radians**, in the part's space, like every kernel value. Panels show document units and degrees through the existing expression fields.
- **Sentences** (user-facing text) are constants in `core/assembly/assembly_data.gd` (C10), so tests and UI share one literal.

### 0.3 Originality and branding

- Behaviour may match the other app. Never copy its text, icons, art or help wording.
- In anything that goes into the project (code, comments, UI strings, tests, docs, commit messages), call it only "the other app". Strip URLs that contain its brand name.
- Tool names in the catalog ("Joint", "As-built Joint", "Motion Link", "Contact Sets", "Motion Study") are plain CAD words. Keep them. Joint type names (Rigid, Revolute, Slider, Cylindrical, Pin-slot, Planar, Ball) are plain engineering words. Write every tooltip, hint and message yourself.
- Icons: see 6.3. The 9 existing Assemble icons must be re-checked for originality before Stage 2 ends (the "UI art must be original" rule: compare at 96 and 24 px against the house icons, and from memory against the other app's; redraw any that echo it).

### 0.4 Machine rules

- **The user's editor is open** (PID 32448 at the time of writing). **Never kill a Godot process you did not start.** If the user's editor holds the DLL, stop and report.
- **Disk.** Build trees stay on C:. Never put build output on D:.
- **DLL lock.** The GDExtension has `reloadable=false`. Close every Godot instance **you started** before building.
- **Build:** `& "C:\Program Files\CMake\bin\cmake.exe" --build "C:\Users\Blaze\holo_forge_build\build" --config Release --parallel` (only team N, Stage 1; take the build lock first, 0.5 #9). Adding `mesh_contact.cpp` needs a reconfigure once: `& "C:\Program Files\CMake\bin\cmake.exe" -S D:\Hover_Board_Racing\Godot_Board_Racing\holo_forge_native -B C:\Users\Blaze\holo_forge_build\build`.
- **Do not run `.ps1` files with `-ExecutionPolicy Bypass`.** Call cmake and Godot directly.
- **Leftovers.** Delete `~*.dll~RF*.TMP` files in `A\bin` when you see them.
- **Headless test:** `& $godot --headless --path D:\Hover_Board_Racing\Godot_Board_Racing\godot-board-racing --script res://tests/<name>.gd`
- **Editor hook:** `& $godot --headless --path <project> --editor -- --holo-forge-assemble-editor-test`. One hook per process. Only teams that own a hook run it (T in Stage 3, the verifier, the orchestrator).
- **Hooks save nothing through the editor in the real project** (Phase 7 10.14, hard rule). The hook guard (`tests/holo_forge_hook_guard.gd`, started by `plugin.gd` for any `--holo-forge-*-test` argument) snapshots every `.tscn`/`.tres`/`.res` outside its own folders (`res://.godot/`, `res://tests/holo_forge/`, `res://addons/holo_forge/bin/`) and fails the run if any changed. A hook saves only its own scene under `res://tests/holo_forge/` with `ResourceSaver.save`, never with `EditorInterface.save_scene()`, never while a scene outside `tests/holo_forge/` is shown, and leaves `.godot/editor/editor_layout.cfg` and `project_metadata.cfg` as it found them.
- **Scenes.** Don't modify the user's scenes or resources. New test scenes go under `tests/holo_forge/`. Generated fixtures go to `user://holo_forge_assembly_fixtures/`, never into the repo.
- **Regression.** `tests/validate_project.gd` must show no violations beyond the 6 known Movement Lab ones. Every pre-existing Holo Forge test and hook must still pass (5.10 lists the ones that change on purpose).
- **The project is not a git repo.** Backups are the only way back (0.5 #10).
- **Run commands yourself.** Never hand the user commands to run.
- **Grep every output** for `SCRIPT ERROR`, `Parse Error`, `signal 11` and `ERROR:` before you call a run green.

### 0.5 Lessons from Phases 6 and 7 (binding rules for every op and every team)

1. **Every op is bounded in time.** No call may run longer than its limit plus 1 s. A call made of parts shares **one deadline** (Phase 7 10.7: nested limits that each restart their clock broke the rule). Budgets are in C9.
2. **Nothing returns a wrong result without a warning.** An op returns a result that passed its post-checks, or a result with a warning that names what is off and by how much, or nothing with an error. Never a wrong result with no message. Each tool's section in 3 says which outcome applies to which failed check.
3. **Dense post-checks.** The solver checks every solved joint (C3.6); contact checks every pair of every step (C5.4); the bake reads back every joint it wrote (C8.5).
4. **Ratio timing.** Timing tests use `tests/holo_forge_timing.gd compare(op, calibration, rounds, label)` against a calibration, never raw milliseconds (5.9).
5. **Real input for UI.** Reproduce UI behaviour with `root.push_input` events in the hook. Direct tool calls miss real input bugs.
6. **Refusals are fast and true.** A refusal comes before the expensive work when it can be predicted (≤ 0.2 s), and its text says what to change.
7. **Failing tests first.** Write each acceptance case before the code that makes it pass and see it fail once (or not run, for a missing method). For a bug fix, the regression case is written and seen failing before the fix.
8. **As-built notes.** When the built code differs from a contract, the report says how (9). The orchestrator folds accepted differences into section 10 of this file; later teams build on section 10, not on the body, where they differ.
9. **One native build at a time.** Before `cmake --build`, take the lock with `mkdir C:\Users\Blaze\holo_forge_build\build.lock` (it fails if another team holds it; wait 20 s and try again, for up to 15 minutes, then report). Remove the folder right after your build ends, pass or fail. Never leave it behind.
10. **Backups.** Before your first edit of any existing file, copy it to `C:\Users\Blaze\holo_forge_build\phase8_backup\<team>\<relative path>` (keep the folder structure). Never overwrite a backup that already exists (another round may have made it).
11. **Parallel teams** (Phase 7 10.5): each team has its own test files; a team edits only the files 4 gives it; shared files get small, re-read-just-before edits that add rather than change; keep the tree compiling (only save a native file in a state that compiles; a build failing in a file that is not yours: wait, retry 3 times, then report); a DLL copy can fail while another team's Godot test runs (wait and rebuild); timing checks under load are rerun alone before being called a defect, and the report says which were measured under load. Do not run the full suite; run your own tests and the existing tests your change could affect. The orchestrator runs the full sequential suite alone after each stage.
12. **Hooks that save** follow 0.4's hard rule.

---

## 1. Target behaviour (our own words) and deliberate differences

### 1.1 What the user gets

1. **Components move.** Every top-level component of a part is a rigid unit that can be placed, grounded (fixed) and connected by joints. Bodies that belong to no component are the fixed ground. A component's bodies are modelled where they are; the assembly only moves the finished bodies (an **as-built placement** of identity means "where it was modelled").
2. **Activate / deactivate** works as before (the active component receives new bodies). New: **Ground / Unground**, **Place Component** (move a free component with the move handles), **Reset Placement**, and **Move to Active Component** for bodies, from the browser.
3. **Joint** (J): pick a snap point on the moving component, then one on the base component; choose a type; the moving component jumps so the two snap frames meet (faces meet face to face). Snaps: face centres, edge midpoints, vertices, circle centres, the axis of round faces, Joint Origins, and (on mesh bodies) flat or round face groups. Offsets (X, Y, Z, angle) and Flip adjust the meeting.
4. **As-built Joint**: connect two components where they already are, about one picked origin.
5. **Joint Origin**: a named frame on a component that joints can snap to.
6. **Rigid Group**: lock several components together as they are.
7. **Joint types**: Rigid, Revolute, Slider, Cylindrical, Pin-slot, Planar, Ball, each with per-DOF **limits** (min, max, rest).
8. **Drive Joints**: set a joint's values (typed, slider, or dragged in the view); values stop at limits with a sentence that says so.
9. **Motion Link**: one joint DOF follows another by a ratio (2:1 gears, rack and pinion as degrees to millimetres).
10. **Contact Sets**: when contact is on, driving stops at the last position where the bodies of a contact set do not overlap, and says which bodies touched.
11. **Motion Study**: keyframe joint values on a time line and play the motion in the viewport.
12. **Game export**: the bake can make each top-level component a `RigidBody3D` and each joint a matching Godot `Joint3D` (Revolute to `HingeJoint3D`, Slider to `SliderJoint3D`, Ball to `ConeTwistJoint3D`, the rest to `Generic6DOFJoint3D` with locked axes), with node paths that work in a running game.

### 1.2 Deliberate differences from the other app (keep them; tests rely on them)

1. **Joints are not timeline features.** The assembly is stored beside the timeline (C1) and is solved after the whole timeline has built. Editing a joint never rebuilds the model.
2. **Features always see modelled positions.** Sketches, features, Form and Direct Edit work on bodies where they were modelled. While one of those tools is open, the viewport shows modelled positions with a status note (`S-MODELLED-VIEW`). There is no "capture position" prompt.
3. **Closed loops are not solved.** The solver walks a tree out from the ground. A joint that would close a loop is reported with how far off it is at the current pose, not enforced.
4. **Nested components move with their top-level component.** Joints connect top-level components (or the ground) only.
5. **The first pick is the moving side.** The second pick stays put (unless it is free and the first is fixed: then the sides swap with a sentence).
6. **No automatic animation** when a joint is made. The panel has a Play Motion button.
7. **Motion Study is linear** between keys (no ease curves in this phase).
8. **Contact stops motion; it does not slide along.**
9. **Dragging a jointed component drives its joint** through DOF handles (rings and arrows), never a free drag.
10. **Pin-slot, Planar, Cylindrical and Rigid export as `Generic6DOFJoint3D`.**
11. **Joint values and limits are not model parameters** (they do not appear in Change Parameters). They take expressions in the panel fields, evaluated once.

---

## 2. Architecture and contracts

### 2.0 Overview

```
document.gd ──► regen.rebuild() ──► result (bodies in part space, "modelled")
     │                                   │
     └── assembly (C1, not a feature) ───┤
                                         ▼
                  core/assembly/solver.gd  solve(doc, result, kernel, overrides)  (C3)
                                         │  poses (doubles), joint states, warnings
               ┌─────────────────────────┼──────────────────────────────┐
               ▼                         ▼                              ▼
   ui/assembly_display.gd       core/assembly/motion.gd           nodes/cad_part.gd bake
   (holder transforms, glyphs)  drive / links / study (C4, C6)    + core/assembly/bake_joints.gd (C8)
                                         │
                              core/assembly/contact.gd (C5) ──► CadMesh.overlap (native, C5.1)
```

- An assembly-only change never runs `regen`; it re-solves (≤ 5 ms for 50 joints, C9) and re-poses the view.
- A model change runs `regen` as before, then re-solves against the new result.

### 2.1 C1: storage (document, undo, save, load)

**C1.1 Where.** `core/document.gd` gets `@export var assembly: Dictionary = {}`. It is **not** a feature and not on the timeline. `snapshot()` copies it with `duplicate(true)`; `restore()` reads it with `.get("assembly", {})` so older snapshots and older saved documents load with an empty assembly. An empty Dictionary means "no assembly": every component sits at identity, nothing is grounded, no joints. `core/assembly/assembly_data.gd normalized(doc.assembly) -> Dictionary` fills every missing key with its default (C1.2); all readers go through it, writers store the full normalized form.

**C1.2 Schema, version 1.** All lengths in meters, angles in radians, doubles. `xform64` is `PackedFloat64Array` of 12 (C1.3). Ids are strings made from `counters` (`"joint1"`, `"origin1"`, `"group1"`, `"link1"`, `"contact1"`, `"study1"`); display names are separate and editable.

```
assembly = {
  "version": 1,
  "placements": { comp_id: xform64 },        # relative to the parent component's pose; missing = identity
  "grounded":   { comp_id: true },           # top-level only
  "origins": [ { "id", "name", "component", "snap": SNAP, "offset": [x,y,z], "angle": a, "flip": false, "visible": true } ],
  "joints": [ {
      "id", "name",
      "type": "rigid" | "revolute" | "slider" | "cylindrical" | "pin_slot" | "planar" | "ball",
      "a": { "component": comp_id or "", "snap": SNAP },      # a = the moving side (first pick)
      "b": { "component": comp_id or "", "snap": SNAP },      # b = the base side (second pick)
      "offset": [x, y, z], "angle": a, "flip": false,         # O, C2.4
      "slide_axis": "z",                                      # slider: "x"|"y"|"z"; pin_slot: "x"|"y"
      "dofs": [ { "value": v, "min": m, "max": M, "limited_min": false, "limited_max": false, "rest": r } ],
      "suppressed": false, "as_built": false, "visible": true } ],
  "rigid_groups": [ { "id", "name", "components": [comp_id...], "relative": { comp_id: xform64 }, "suppressed": false } ],
  "links": [ { "id", "name", "driver": { "joint": id, "dof": i }, "follower": { "joint": id, "dof": i }, "ratio": r, "offset": o } ],
  "contact": { "enabled": false, "tolerance": 1e-5, "step": 1e-3, "precision": 1e-6 },
  "contact_sets": [ { "id", "name", "members": [ {"component": id} | {"body": id} ], "enabled": true } ],
  "studies": [ { "id", "name", "length": 5.0, "fps": 30, "contact": false,
                 "keys": [ { "time": t, "joint": id, "dof": i, "value": v } ] } ],
  "counters": { "joint": n, "origin": n, "group": n, "link": n, "contact": n, "study": n }
}
SNAP = { "kind": KIND, "body": body_id, "ref": <stored pick, as features store it>,
         "at": [x,y,z], "normal": [x,y,z], "frame": xform64, "origin": origin_id (kind "origin" only) }
```

- `dofs` has exactly the length C2.5 gives for the type. Changing the type rebuilds `dofs` with defaults (value 0, no limits, rest 0), keeping a DOF whose name exists in both types.
- `snap.frame` is the last resolved frame in **modelled** coordinates of that body. It is the fallback when the ref no longer resolves (C2.3).
- `rigid_groups[].relative[c]` is `P_first⁻¹ · P_c` captured when the group was made.

**C1.3 `core/assembly/xform64.gd`** (static functions, no state). Layout, same as Godot's `Transform3D`: elements 0-2 = basis column X (the image of the X axis), 3-5 = basis column Y, 6-8 = basis column Z, 9-11 = origin. Functions: `identity()`, `compose(a, b)` (a·b), `inverse(a)` (rigid: transpose + back-rotated origin; assert orthonormal within 1e-12 in debug), `apply(a, p: PackedFloat64Array(3))`, `apply_dir`, `from_transform(t: Transform3D)`, `to_transform(a) -> Transform3D`, `translation(x,y,z)`, `rot_x(r)`, `rot_y(r)`, `rot_z(r)`, `frame(origin, z_dir, x_hint)` (C2.2), `distance(a, b)` (origin distance), `angle_between(a, b)` (rotation angle of a⁻¹·b, computed with `atan2` of the vector part and `1 + trace`, not `acos`, so small angles keep their precision), `orthonormalize(a)`, `is_finite(a)`.

**C1.4 Undo.** Every assembly change goes through `workspace.change(name, mutate)` like other document changes. Undo names: `Forge: Joint`, `Forge: As-built Joint`, `Forge: Edit Joint1`, `Forge: Drive Joint1`, `Forge: Delete Joint1`, `Forge: Suppress Joint1`, `Forge: Joint Origin`, `Forge: Rigid Group`, `Forge: Motion Link`, `Forge: Contact Set`, `Forge: Contact On` / `Forge: Contact Off`, `Forge: Motion Study1`, `Forge: Ground Comp1`, `Forge: Unground Comp1`, `Forge: Place Comp1`, `Forge: Reset Placement Comp1`, `Forge: Move to Comp1` (bodies; this one is a model change because `bodies[id].component` changes, 3.2.5). Previews (drag, typed values before OK, Play Motion, study playback) are **view-only** and never touch the document.

**C1.5 No rebuild for assembly-only changes.** `forge_workspace.gd _model_of()` gains `"assembly"` in the excluded keys (today `VIEW_KEYS = ["analyses", "canvases", "decals"]`; add a separate `ASSEMBLY_KEYS := ["assembly"]` so view data and assembly stay distinguishable). `_refresh_for()`: when only the assembly differs, call `_refresh_assembly()` (re-solve, re-pose, refresh glyphs and browser), not `recompute()`.

**C1.6 Save and load.** The assembly is saved with the document (it is an `@export`). `nodes/cad_part.gd _design_text(doc)` adds `"assembly"` to its key list, so a design changed only in its assembly counts as changed (inheriting scenes keep their own copy, Phase 7 10.15 D4). Loading a document whose `assembly.version` is greater than 1 shows `S-NEWER-ASSEMBLY` and keeps the data untouched (read-only: every assembly tool is refused with the same sentence).

**C1.7 Timeline and rollback.** The solver runs on the result the workspace shows. When the rollback marker hides a component, joints on it are in state `waiting` (not an error, `S-WAITING`). Deleting a feature that made a component leaves its joints in state `unresolved` with `S-MISSING-COMPONENT`; they are not deleted (Undo of the delete brings everything back). `Delete` on the joint deletes it.

### 2.2 C2: units of motion, snaps and frames

**C2.1 Units.** A **unit** is a top-level component (`components[c].parent == ""`) with all its nested components and their bodies. The **ground** is the virtual unit `""`: every body whose component is `""`. A grounded unit is fixed at its placement. The pose of a unit `u` is `P_u` (xform64, part space). A nested component `n` with parent `p` has pose `P_n = P_p · placement[n]` (identity if absent). A body's pose is its component's pose (`""` → identity). Posed point = `P · modelled point`.

**C2.2 Frames.** A snap frame is a right-handed orthonormal xform64 in the **modelled** coordinates of its body:
- origin = the snap point; Z = the snap direction (below);
- X = the first of part X, part Y whose `|dot(axis, Z)| < 0.9`, projected onto the plane normal to Z and normalized (for an edge midpoint: the edge tangent projected, if `|dot(tangent, Z)| < 0.9`);
- Y = Z × X.

**C2.3 Snap kinds** (`snap.kind`), all from existing native queries (`CadShape.face_info`, `edge_info`, `vertex_position`; `CadMesh` group `face_info` and `fit_primitive`):

| Kind | Picked on | Origin | Z |
|---|---|---|---|
| `face_center` | plane face | `face_info.point` (area centroid) | outward `face_info.normal` |
| `axis_mid`, `axis_start`, `axis_end` | cylinder or cone face | point on `face_info.axis` at the middle / start / end of the face's extent along the axis | axis, oriented out of the material at the picked end (start/end) or along `face_info.axis` (mid) |
| `sphere_center` | sphere face | `face_info.center` | outward normal at the picked point |
| `edge_mid` | line or curve edge | `edge_info.midpoint` | outward normal of the face the pick came through; else the first planar face in `edge_info.faces` |
| `vertex` | vertex | `vertex_position` | outward normal of the face the pick came through; else the first face's normal at the vertex |
| `circle_center` | circle or arc edge | `edge_info.center` | `edge_info.axis`, oriented to point out of the material of the planar face beside the edge (the pick's face, or the first planar face in `edge_info.faces`) |
| `origin` | a Joint Origin glyph | the origin's frame (C2.6) | its Z |
| `group_center` | flat mesh face group | group area centroid | group normal (flat groups only) |
| `group_axis_mid` | round mesh face group | middle of the `fit_primitive` cylinder axis over the group | fitted axis; refused when the fit's radius error is over 1% (`S-GROUP-NOT-ROUND`) |

- Mesh bodies offer only `group_center` and `group_axis_mid`; edges and vertices on mesh bodies are refused (`S-MESH-SNAP`).
- **Form bodies** take part through their built body in the result, like any B-rep body. The cage is not pickable for joints.
- `snap.ref` is stored exactly the way feature options store picks (the output of `REFERENCES.from_pick`), and resolved with the same resolver features use (find it in `core/references.gd` by name). When the ref no longer resolves, the solver uses `snap.frame` and adds `S-SNAP-LOST` (state `ok` but warned).
- **Snap candidates**: while a snap slot is active, hovering a face shows its candidates (centre, the axis points, the edges' midpoints and circle centres, its vertices) as glyphs; the one nearest the cursor in screen space is highlighted; clicking takes it. Candidate lists are cached per (result, body, face).

**C2.4 Joint relation.** Side `a` moves, side `b` is the base. With `F_a`, `F_b` the resolved snap frames, `R_x(π)` turning side `a` over so the faces meet:

```
F'_a = F_a · R_x(π)                                  (Z reversed: face meets face)
O    = T(offset) · R_z(angle) · (flip ? R_x(π) : I)
P_a · F'_a = P_b · F_b · O · M(v)                    (the joint relation)
```

So when `b` is placed first: `P_a = P_b · F_b · O · M(v) · F'_a⁻¹`. When `a` is placed first (it is nearer the ground): `P_b = P_a · F'_a · M(v)⁻¹ · O⁻¹ · F_b⁻¹`. At `v = 0`, zero offsets and no flip, the two snap points coincide and their Z axes are opposite in the posed result (face to face).

**As-built joints** pick one world point and direction `W` (a snap on either component, resolved in the current pose). Then `F_b = P_b⁻¹ · W`, `F'_a = P_a⁻¹ · W` (no turn-over), `O = I`, all DOF values 0: the relation holds at the current pose by construction. `as_built: true` marks it so the panel hides Offset and Flip. Rigid as-built joints need no pick (W = the moving unit's bounding-box centre with part axes).

**C2.5 Motion `M(v)` per type** (DOF order is the `dofs` order):

| Type | DOFs | M(v) |
|---|---|---|
| rigid | none | I |
| revolute | `rot_z` | R_z(θ) |
| slider | `slide` | T(s · axis), axis = `slide_axis` (default z) |
| cylindrical | `slide_z`, `rot_z` | T(0, 0, s) · R_z(θ) |
| pin_slot | `rot_z`, `slide` | T(s · axis) · R_z(θ), axis = `slide_axis` (default x) |
| planar | `slide_x`, `slide_y`, `rot_z` | T(u, v, 0) · R_z(θ) |
| ball | `rot_x`, `rot_y`, `rot_z` | R_x(α) · R_y(β) · R_z(γ) |

Rotations are unwrapped: 720° stays 720° (no modulo). A limited DOF obeys `min ≤ value ≤ max` with `min ≤ rest ≤ max`; `min < max` strictly when both are set (equal limits are refused, `S-LIMITS-EQUAL`: use Rigid or lock it otherwise).

**C2.6 Joint Origins.** An origin's frame in its component's modelled coordinates is `F · O_origin` with `O_origin = T(offset) · R_z(angle) · (flip ? R_x(π) : I)`. It moves with its component.

**C2.7 Which side moves.** The first pick is side `a` (moving). If side `a` is the ground or grounded and side `b` is free, the tool swaps the sides and says `S-SIDES-SWAPPED`. If both are fixed, the joint is made and the solver reports it as a loop (C3.4). A pick on a nested component maps to its top-level unit with `S-NESTED-MOVES` shown once in the panel. Both picks in the same unit are refused: `S-SAME-UNIT`.

### 2.3 C3: the solver (`core/assembly/solver.gd`)

**C3.1 Entry point.**

```
static func solve(doc: Resource, result: Dictionary, kernel: RefCounted, overrides := {}) -> Dictionary
  overrides = { joint_id: { dof_index: value } }     # previews, drives, studies; never stored
returns {
  "poses":      { comp_id: xform64 },               # every component, part space ("" not listed: identity)
  "body_poses": { body_id: xform64 },
  "transforms": { comp_id: Transform3D },            # float32 copies for the view and the bake (local to the parent component)
  "joints":     { joint_id: { "state": STATE, "values": PackedFloat64Array, "residual_m": d, "residual_rad": r,
                              "frame_a": xform64, "frame_b": xform64, "world": xform64, "sentence": String } },
  "units":      { comp_id: { "fixed": bool, "root": unit_id or "", "reached_by": joint_id or "" } },
  "warnings":   PackedStringArray,
  "ms":         float }
STATE = "ok" | "loop" | "unresolved" | "waiting" | "suppressed" | "error"
```

`world` is the joint frame `P_b · F_b · O` in part space (used by glyphs and the bake).

**C3.2 Algorithm** (no iteration, O(units + joints)):
1. Normalize the assembly; resolve snaps (cached per result identity and snap); joints whose sides cannot be found are `unresolved`/`waiting` and take no part.
2. Graph: nodes = ground + units; edges = unsuppressed, resolved joints between different units (in stored order) + rigid groups (an edge from the first member to each other member with the stored `relative`).
3. Fixed set: ground, grounded units. Each fixed unit's pose = its placement (ground: identity).
4. Breadth-first search from the fixed set (fixed units in browser order, edges in stored order). Each edge that reaches an unvisited unit sets its pose with C2.4 (forward or reversed form). An edge whose both ends are visited is a **loop edge** (C3.4).
5. Units not reached from any fixed unit: each connected group is rooted at its first unit in browser order, posed at its placement, and searched the same way. Their `units[c].fixed` is false and `root` names the root unit.
6. Nested components: `P_n = P_parent · placement[n]`.
7. Post-check (C3.6). Build `body_poses` and `transforms`.

**C3.3 Values.** A DOF value is `overrides` if given, else `dofs[i].value`; then clamped to its limits (a stored value is always inside its limits; overrides may not be, and C4 clamps before calling solve). Values are doubles; no float32 anywhere in the chain.

**C3.4 Loops.** A loop edge is not enforced. The solver measures how far its relation is from holding: `R = (P_b · F_b · O)⁻¹ · (P_a · F'_a)`; the translation residual is the part of `R.origin` not along the type's slide directions; the angle residual is the angle of `R.basis` not about the type's rotation axes (revolute, cylindrical, pin_slot, planar: the angle between `R.basis.z` and Z; ball: none; rigid and slider: the whole rotation angle). DOF ranges are checked against the implied values. State `loop`; sentence `S-LOOP-OFF` with both numbers in document units, or `S-LOOP-HOLDS` when both residuals are ≤ 1e-9 (m, rad). The Joint is still drawn, with the warning colour.

**C3.5 Placement of jointed units.** A unit reached through a joint ignores its own placement (its pose comes from the joint). `Place Component` on such a unit is refused (`S-PLACE-JOINTED`). Grounding a unit stores its current pose as its placement first, so it does not jump.

**C3.6 Post-check.** For every joint in state `ok`, recompute both sides of the C2.4 relation from the final poses and compare: translation ≤ 1e-9 m and rotation ≤ 1e-9 rad. A failure is a Holo Forge fault: state `error`, sentence `S-SOLVE-FAULT` with the numbers; the poses are still shown. Every pose must be finite and orthonormal within 1e-12 (`xform64.is_finite`, column dot products); a pose that is not is replaced by its unit's placement with `S-SOLVE-FAULT`.

**C3.7 Budget.** Solve has no time limit of its own because it is linear and has no loops; C9 gives its target. Snap resolution uses only cached `face_info`/`edge_info` (one native call per face the first time).

### 2.4 C4: drive, limits and links (`core/assembly/motion.gd`)

**C4.1 `drive(doc, result, kernel, joint_id, dof, target, options := {}) -> Dictionary`**: returns `{ "values": { joint_id: PackedFloat64Array }, "reached": float, "clamped": bool, "stopped_by": "" | "limit" | "link" | "contact" | "time", "sentence": String, "solve": <C3 output at the reached values>, "ms" }`. It never writes the document; the Drive tool writes `values` on OK.

**C4.2 Limits.** `reached = clamp(target, min, max)` for limited ends. When clamped, `reached` is **exactly** the stored limit (assignment, no arithmetic) and the sentence is `S-LIMIT` ("Joint1 stops at its limit of 90° (asked for 120°)."). Unlimited ends never clamp.

**C4.3 Links.** `follower = ratio · driver + offset`. `offset` is captured when the link is made (`offset = follower_now − ratio · driver_now`), so making a link moves nothing. Rules:
- A follower has one driver (`S-LINK-SECOND-DRIVER`). Links must not close a circle (`S-LINK-CIRCLE`). Ratio 0 is refused (`S-LINK-ZERO`). A DOF cannot follow itself. Rotational and linear DOFs may be linked to each other; the ratio's unit is follower unit per driver unit (shown as °/°, mm/°, °/mm or mm/mm).
- Chains compose: C follows B follows A gives `C = r_BC·(r_AB·A + o_AB) + o_BC`.
- Driving a follower drives the chain's root driver inversely: `driver = (value − offset) / ratio`, then everything downstream follows.
- Before moving, the allowed driver interval is the intersection of its own limits with every follower's limits mapped back through its composed (ratio, offset). The driver is clamped to that interval. When a follower's limit binds, the sentence is `S-LINK-LIMIT` ("Joint1 stops at 45°: Joint2, linked 2:1, reaches its limit of 90° there."). The follower then holds exactly its stored limit (assign it, do not recompute it through the ratio).
- Motion Study keys on a follower are refused (`S-STUDY-FOLLOWER`).

**C4.4 Contact.** When contact is enabled, `drive` sweeps from the current values to the clamped target through C5 and stops early on interference (`stopped_by: "contact"`).

**C4.5 Play Motion** (Joint and Drive panels) is a view-only animation over 2 s: a limited DOF goes min → max → rest; an unlimited rotation goes one full turn and back to its value; an unlimited slide goes ±(bounding-box diagonal of the moving unit)/2 and back. With contact on, it stops where C5 stops.

### 2.5 C5: contact

**C5.1 Native: `CadMesh.overlap`** (team N, `N\src\mesh_contact.cpp/.h`, bound next to the other `CadMesh` methods):

```
overlap(other: CadMesh, other_to_this: PackedFloat64Array /*12, C1.3 layout*/, options: Dictionary) -> Dictionary
  options: { "time_limit": 1.0 }   # seconds; one deadline for the whole call
returns { "overlap": bool, "volume": float /*m3*/, "area": float /*m2, surface of the overlap solid*/,
          "thickness": float /*m, 2*volume/area, 0 when no overlap*/, "point": PackedFloat64Array /*3, centre of the overlap's bounding box, this mesh's space*/,
          "timed_out": bool, "early_out": bool /*true when the box test answered*/, "ms": float, "error": String }
```
- Each `CadMesh` caches its Manifold the first time `overlap` needs it (cleared by every mutation that already invalidates the mesh's caches). The cache counts toward the Phase 7 mesh cache cap; it is dropped with the mesh.
- Bounding-box early-out first (the other mesh's box transformed by `other_to_this`): no box overlap returns `overlap: false` with no Manifold work.
- The intersection is `this ∩ other.Transform(other_to_this)` with Manifold's own boolean, under the same cancel/deadline mechanism Phase 7 N3 uses (see `docs/holo_forge/phase7_native_ops_n3.md`). It does **not** run the 1 s self-crossing tests of `boolean` (too slow for a sweep).
- Open, inside-out or empty meshes are refused with `error` ("Contact needs closed bodies: the mesh is open.", "...: the mesh is inside out."). The GDScript side puts the body name in.
- Add a rate for `overlap` to `mesh_budget.h` (microseconds per triangle pair, measured) so C5.5 can estimate.

**C5.2 Contact meshes** (`core/assembly/contact.gd`). Mesh bodies use their `CadMesh` directly. B-rep bodies use `MESH.tessellated(shape, "high", limit)` (cached by the existing mesh cache). Each contact mesh has a deviation `dev`: 0 when every face of the body is planar, else the High preset's linear deflection (D/5000, D = the body's bounding-box diagonal). Bodies whose tessellation fails or is refused take no part, with `S-CONTACT-SKIPPED` naming them.

**C5.3 Interference.** Two bodies interfere when `thickness > tol_eff`, `tol_eff = tolerance + dev_a + dev_b` (tolerance default 0.01 mm). This keeps a pin turning in an exact-fit hole from stopping on the facets of the round faces. It means: contact closer than `tol_eff` is not seen, and a compact poke (a corner into a face) is seen only once it is about 4 × `tol_eff` deep (thickness = 2V/A is small for compact overlaps). When `dev > 0` the Drive panel's contact row shows `S-CONTACT-DEV` ("Round faces are checked within 0.02 mm, so contact closer than 0.03 mm is not seen.").

**C5.4 The sweep** (`contact.gd sweep(doc, result, kernel, path: Callable, v0, v1, options) -> Dictionary`), where `path(v) -> body_poses` is a drive or study parameterization:
1. **Pairs:** for each enabled contact set, every pair of member bodies in different units whose relative pose changes between `v0` and `v1`. A component member stands for all its bodies (nested included). With no enabled set: `S-CONTACT-NO-SETS`, nothing checked.
2. **Start:** pairs that already interfere at `v0` are left out for this sweep, with `S-CONTACT-START` naming them.
3. **Steps:** the step between samples is chosen so that (a) no corner of any moving body's bounding box moves more than `step` (default 1 mm) between them, and (b) no unit turns more than 5° between them. (The farthest any point of a body moves under a rigid motion is reached at a corner of its box, since the displacement is affine in the point; the 5° cap keeps the arc within 0.1% of the chord.) At most 2,000 steps; more is refused up front (`S-CONTACT-STEPS`).
4. **Thin bodies:** when a contact body's smallest box dimension is under 2 × step, the sweep warns `S-CONTACT-THIN` (it could pass through between samples).
5. **Bisection:** at the first sample with interference, bisect between the last clear value and it until the farthest corner travel between the two is ≤ `precision` (default 0.001 mm), at most 24 halvings. The result is the **last clear value** (never an interfering one).
6. **Result:** `{ "reached", "stopped": bool, "pair": [body_a, body_b], "set": set_id, "point", "sentence", "timed_out", "checked_pairs", "steps", "ms" }`; sentences `S-CONTACT-STOP` ("Motion stopped at 10.009 mm: Block touches Wall (Contact Set 1).") or, for studies, `S-STUDY-STOP` ("Motion stopped at 1.27 s: Lever touches Stop.").

**C5.5 Bounds.** One deadline per drive: `CONTACT_SECONDS = 5.0` (study: shares `STUDY_SECONDS`, C6). Before sweeping, estimate `steps × Σ pair cost` from the `mesh_budget.h` rate; over the budget → refused in ≤ 0.2 s with `S-CONTACT-TOO-SLOW` (gives the estimate and what to change). A sweep that runs out of time stops at the last clear sample with `S-CONTACT-TIMEOUT` (the stop is true: that value was checked clear).

### 2.6 C6: Motion Study (`core/assembly/motion.gd`)

- A study has `length` (s, 0.1..60), `fps` (10..60, default 30), `contact` (bool) and `keys`. Keys are per (joint, dof), sorted by time; between keys the value is linear; before the first key it holds the first, after the last it holds the last. DOFs without keys stay at their stored value. Followers follow (C4.3).
- `study_frames(doc, result, kernel, study_id) -> { "frames": Array[{ "time", "body_poses", "values" }], "stopped_at": time or -1, "sentence", "warnings", "ms" }`. Frames are computed up front (`ceil(length · fps) + 1`). A key outside a limit plays clamped with `S-STUDY-CLAMPED`.
- With `contact`, the sweep runs along time through the frames (C5.4 with `v` = time); after a stop every later frame holds the stopped pose.
- Bound: `STUDY_SECONDS = 20.0`, one deadline; estimate first and refuse (`S-STUDY-TOO-SLOW`) when it cannot fit.
- Playback is view-only: the panel's Play / Pause / Loop / scrub set holder transforms from the frames; closing the panel restores the stored pose.

### 2.7 C7: view, picking, inspect

**C7.1 Display** (`ui/assembly_display.gd`, owned by V). `apply(viewport, solve_out)` sets each body holder's transform (`_body_nodes[id].holder` in `forge_viewport.gd`) to `to_transform(body_poses[id])`. Analyses, decals and section caps already live under the holders, so they move with the body. Setting 200 holders ≤ 2 ms (C9). Glyphs (6.2) are drawn by the same script under one `AssemblyGlyphs` node.

**C7.2 Modelled view.** While a feature command, a sketch, the Form workspace, Direct Edit or a mesh tool is open, `assembly_display.gd` sets every holder to identity and shows `S-MODELLED-VIEW` in the status line. Closing the tool re-poses. Inspect tools, the Assemble tools and the browser keep the posed view.

**C7.3 Picking.** `core/picking.gd` and the viewport's ray cast transform the ray into each body's modelled space by the inverse of its pose before testing. Picks keep **modelled** points and normals (so stored refs and snaps stay valid); a pick in the posed view also carries `"world_point"` and `"world_normal"`. Float32 is acceptable here (1e-6 m), because the stored snap re-resolves from the ref in doubles.

**C7.4 Inspect on posed bodies.** `INSPECT.measure`, `INSPECT.interference` and `INSPECT.mass_properties` (and `ANALYSIS.mass_properties`) accept poses: `ctx.poses` / an optional `poses := {}` argument, `body_id → xform64`. Posed B-rep shapes come from `kernel.transform_shape(shape, xform, tag)`, posed mesh bodies from `MESH.transformed(mesh, xform)`, both cached by (body, pose bytes). With no poses the results are byte-identical to today. The Measure, Interference and Mass Properties commands pass the current poses when the view is posed.

**C7.5 Browser** (V builds the structure in Stage 1, T adds the context items in Stage 2): the existing empty "Joints" folder lists joints (type icon, state badge for `loop`/`unresolved`/`error`/`waiting`, eye = glyph visibility); new folders "Joint Origins", "Rigid Groups", "Motion Links", "Contact Sets", "Motion Studies" (hidden while empty). Components get a ground button (`BUTTON_GROUND := 3`, after the existing `BUTTON_EYE`, `BUTTON_LOCK`, `BUTTON_ACTIVATE`) showing the ground icon when grounded. Selecting a joint highlights both units; double-click opens Edit.

### 2.8 C8: bake and game export

**C8.1 Godot 4.7.1 joint facts** (from the class reference, read 2026-11-13; **verify** items are checked by `tests/holo_forge_assembly_bake_test.gd` V1-V8 before the bake code depends on them).

| Fact | Status |
|---|---|
| `Joint3D` has `node_a`, `node_b` (NodePath, default empty), `exclude_nodes_from_collision` (default true), `solver_priority` (default 1; ignored by Jolt). An empty path attaches that side to a fixed point in the world. | docs |
| With Jolt, when only one body is assigned it is treated as `node_b` and `node_a` is the world (Godot Physics treats it as `node_a`, which inverts limits; Project Settings > Physics > Jolt Physics 3D > Joints > World Node controls this). | docs |
| `HingeJoint3D`: `angular_limit/enable` (false), `angular_limit/lower` (−π/2), `angular_limit/upper` (π/2), `motor/enable`, `motor/target_velocity`, `motor/max_impulse`; `set_param(Param, v)` (`PARAM_LIMIT_UPPER = 1`, `PARAM_LIMIT_LOWER = 2`), `set_flag(Flag, b)` (`FLAG_USE_LIMIT = 0`, `FLAG_ENABLE_MOTOR = 1`). `angular_limit/bias`, `softness`, `relaxation` and `params/bias` are not supported by Jolt. | docs |
| The hinge turns about the joint node's **local Z** axis. | **verify** (V1) |
| Hinge limits are radians, measured from the relative pose the bodies had when the joint was set up. | **verify** (V2) |
| `SliderJoint3D`: slides along the joint's local **X** axis; `linear_limit/upper_distance` (1.0), `linear_limit/lower_distance` (−1.0); `PARAM_LINEAR_LIMIT_UPPER = 0`, `PARAM_LINEAR_LIMIT_LOWER = 1`. Under Jolt the slider does not turn about its axis; the `angular_*` and the softness/restitution/damping params are not supported. | docs (axis: **verify** V3) |
| `ConeTwistJoint3D`: twist about the joint's local **X** axis, swing in the plane normal to it; `swing_span` (π/4), `twist_span` (π); values under 0.05 lock. `bias`, `relaxation`, `softness` not supported by Jolt. | docs (**verify** V4: twist axis and the meaning of an asymmetric request) |
| `Generic6DOFJoint3D`: per axis `linear_limit_x/enabled`, `lower_distance`, `upper_distance`, `angular_limit_x/enabled`, `lower_angle`, `upper_angle` (and `_y`, `_z`); defaults: limits enabled at 0..0 (locked). `set_flag_x/y/z(FLAG_ENABLE_LINEAR_LIMIT = 0 / FLAG_ENABLE_ANGULAR_LIMIT = 1, b)`, `set_param_x/y/z(PARAM_LINEAR_LOWER_LIMIT = 0, PARAM_LINEAR_UPPER_LIMIT = 1, PARAM_ANGULAR_LOWER_LIMIT = 10, PARAM_ANGULAR_UPPER_LIMIT = 11, v)`. Jolt ignores the limit softness, restitution, damping and erp params. | docs |
| Under Jolt a limited 6DOF rotation about Z keeps a range wider than ±90°. | **verify** (V5). If not, map the limited rotation axis to 6DOF X (twist) instead and say so in the report. |
| A `CollisionShape3D` must be a direct child of its `CollisionObject3D`. Moving bodies use convex shapes (`ConvexPolygonShape3D`); a `ConcavePolygonShape3D` in a moving `RigidBody3D` is not supported. | first: docs; second: **verify** (V6). The bake uses convex shapes either way. |
| `Mesh.create_convex_shape(clean := true, simplify := false)` returns a `ConvexPolygonShape3D`. | **verify** (V7) |
| Physics steps in a `--headless --script` `SceneTree` run (awaiting `physics_frame`). | **verify** (V8). If not, the Jolt simulation case moves into the editor hook. |

**C8.2 New `CadPart` exports** (`nodes/cad_part.gd`, team K):
- `component_nodes: int` (enum `COMPONENT_NODE3D = 0` default, `COMPONENT_RIGID_BODY = 1`), shown as "Component Nodes: Node3D / RigidBody3D".
- `bake_joints: bool = true` (only used with RigidBody3D).
- `bake_pose: int` (`BAKE_POSE_CURRENT = 0` default, `BAKE_POSE_REST = 1`: every DOF at its rest value).
Changing any of them rebakes.

**C8.3 Node3D mode** (default). Component `Node3D` transforms = `solve.transforms` (local to the parent component's node; top-level: the pose). Body meshes stay in modelled coordinates under their component node, so the baked scene shows the posed assembly. **With an empty assembly every transform is identity and the baked scene is identical to Phase 7's** (5.8 #1 compares). No joints are baked in this mode (`S-BAKE-NO-JOINTS` in the inspector hint).

**C8.4 RigidBody3D mode.**
- Each top-level component bakes as a `RigidBody3D` named like the component (nested components stay `Node3D` children). Its transform is the unit pose at the bake pose. Grounded units: `freeze = true`, `freeze_mode = RigidBody3D.FREEZE_MODE_STATIC`.
- Mass: sum of the unit's bodies' masses from `INSPECT.mass_properties` (physical materials; bodies without a material use the default density the inspect code uses); `center_of_mass_mode = CENTER_OF_MASS_MODE_CUSTOM`, `center_of_mass` = the unit's centre of mass in the body's local frame. `inertia` is left at zero (Godot computes it from the shapes); the report says so.
- Collision: for each body of the unit (nested included) one `CollisionShape3D` named `<Body>Shape`, a **direct child** of the `RigidBody3D`, with the body's local transform, holding the convex hull of the baked mesh. A body whose hull adds more than 5% volume gets the warning `S-BAKE-HULL` ("Bracket collides as its convex hull, which is 18% larger than the body."). The existing per-body `Collision` `StaticBody3D` option is not used for units in this mode.
- Ground bodies (component `""`) go under one `StaticBody3D` named `Ground` with one trimesh `CollisionShape3D` per body (the existing collision code).
- **Joints** (when `bake_joints`): under a `Node3D` named `Joints`, direct child of the `CadPart`, at identity; one node per resolved, unsuppressed joint, named like the joint (unique-ified the way node names are). Loop joints are baked too (physics solves loops), with a note when their residual is over 1e-6 m or 1e-6 rad. Rigid groups bake as `Generic6DOFJoint3D` nodes named `<Group>_<Comp>` locking each member to the first.
- `node_a` = side `b` (base), `node_b` = side `a` (moving), as relative paths from the joint node: `NodePath("../../<CompName>")`. A side on the ground: `node_a = NodePath("")` (Jolt: the world). If both sides are bodies, both are set. The joint node's transform = `world · R_map` (C3.1 `world`, at the bake pose, times the axis remap below).
- When the project's physics engine is not Jolt, the bake adds `S-BAKE-NOT-JOLT` (world-fixed joints may turn the other way).
- Links, contact sets and studies are not baked (`S-BAKE-NOT-BAKED` lists what was left out, once per bake). `.glb` exports carry the posed nodes but no joints.

**C8.5 Type mapping** (limits are shifted by the value `v_b` the DOF has at the bake pose, because Godot measures from the setup pose: `lower = min − v_b`, `upper = max − v_b`).

| Our type | Godot node | `R_map` | Settings |
|---|---|---|---|
| revolute | `HingeJoint3D` | identity (hinge = local Z, V1) | limited: `angular_limit/enable = true`, `lower`/`upper` shifted; one end unlimited: that end becomes −π or +π (relative to the bake pose; hinge limits are taken to lie in [−π, π], **verify** V2), warned `S-BAKE-HALF-LIMIT`; a shifted range that leaves [−π, π] is clipped to it with the same sentence; unlimited: `enable = false` |
| slider | `SliderJoint3D` | turns the slide axis onto local X | `linear_limit/lower_distance`, `upper_distance` shifted; unlimited: ±1e4 m with `S-BAKE-HALF-LIMIT` for half-limited (there is no off switch) |
| ball | `ConeTwistJoint3D` | turns our Z onto local X | `twist_span` = max(|min|, |max|) of `rot_z` (unlimited: π); `swing_span` = max over `rot_x`, `rot_y` of max(|min|, |max|) (unlimited: π); any asymmetric or unequal limits are widened to that symmetric cone with `S-BAKE-CONE-WIDENED` |
| rigid | `Generic6DOFJoint3D` | identity | all six axes locked (enabled, 0..0) |
| cylindrical | `Generic6DOFJoint3D` | identity | linear Z and angular Z free (disabled) or limited (enabled, shifted); the rest locked |
| pin_slot | `Generic6DOFJoint3D` | identity | linear on `slide_axis` and angular Z free or limited; the rest locked |
| planar | `Generic6DOFJoint3D` | identity | linear X, Y and angular Z free or limited; linear Z, angular X, Y locked |

Never set a parameter Jolt does not support (C8.1); leave them at their defaults. After baking, the bake reads back every property it set and compares (1e-6) — a mismatch is an error in the bake report, not silent.

**C8.6 Export** (`core/export.gd`, team K). CAD exports (STEP, STL, OBJ, 3MF) write bodies **where the assembly places them** (the posed view the user sees), through `kernel.transform_shape` / `MESH.transformed`. With an empty assembly the output is byte-identical to today. The export report adds `S-EXPORT-POSED` when any pose is not identity.

### 2.9 C9: time bounds and budgets (all targets, to be measured; ratio limits per 5.9)

| Op | Target (dev machine, single thread) | Bound |
|---|---|---|
| `solve`, 50 joints, snaps cached | ≤ 5 ms | none (linear) |
| `solve`, 200-unit chain | ≤ 20 ms | none (linear) |
| snap candidates for one face (cached `face_info`) | ≤ 2 ms | none |
| `CadMesh.overlap` 2 × 12 triangles, boxes overlapping | ≤ 1 ms | `time_limit` |
| `overlap` 2 × 20k | ≤ 30 ms (first call with Manifold build ≤ 3 × that) | `time_limit` |
| `overlap` 2 × 200k | ≤ 400 ms | `time_limit` |
| drive with contact, two boxes, 10 mm at 1 mm steps | ≤ 0.2 s | `CONTACT_SECONDS` 5 s, one deadline |
| study precompute 10 s, 30 fps, 5 joints, no contact | ≤ 0.5 s | `STUDY_SECONDS` 20 s |
| set 200 holder transforms | ≤ 2 ms | none |
| RigidBody3D bake, 20 units, joints, excluding mesh baking | ≤ 1 s | none |
| any refusal | ≤ 0.2 s | — |

### 2.10 C10: sentences (constants in `core/assembly/assembly_data.gd`)

Placeholders in `<>` are filled with names and values in document units (degrees for angles, the document length unit with up to 4 significant decimals). Tests match the fixed words, not the numbers' formatting.

| Id | Text |
|---|---|
| `S-SAME-UNIT` | "Both picks are on <Comp>. A joint connects two different components." |
| `S-SIDES-SWAPPED` | "The first pick is on a fixed part, so <Comp> moves instead." |
| `S-NESTED-MOVES` | "<Nested> moves with its top-level component <Comp>." |
| `S-MESH-SNAP` | "Mesh bodies snap only to flat or round face groups. Pick a face group." |
| `S-GROUP-NOT-ROUND` | "This face group is neither flat nor round enough (<n>% off a cylinder) to place a joint on." |
| `S-SNAP-LOST` | "<Joint> lost its pick on <Body> (the model changed there); it holds its last place. Edit the joint to pick again." |
| `S-WAITING` | "<Joint> waits for <Comp>, which the timeline builds after the rollback marker." |
| `S-MISSING-COMPONENT` | "<Joint> refers to <Comp>, which no longer exists. Edit or delete the joint." |
| `S-LIMITS-EQUAL` | "Min and max are equal. Use a Rigid joint, or set two different limits." |
| `S-LOOP-OFF` | "<Joint> closes a loop and is not solved: it is off by <d> and <a> at this pose." |
| `S-LOOP-HOLDS` | "<Joint> closes a loop; it holds at this pose but is not solved while you drive." |
| `S-SOLVE-FAULT` | "<Joint> could not be placed exactly (off by <d>, <a>). This is a Holo Forge fault; please report it." |
| `S-PLACE-JOINTED` | "<Comp> is held by <Joint>. Drive the joint, or suppress it to place the component." |
| `S-LIMIT` | "<Joint> stops at its limit of <limit> (asked for <target>)." |
| `S-LINK-LIMIT` | "<Joint> stops at <value>: <Follower>, linked <ratio>, reaches its limit of <limit> there." |
| `S-LINK-SECOND-DRIVER` | "<Joint> already follows <Driver>. A joint can follow only one other." |
| `S-LINK-CIRCLE` | "That link would make <Joint> follow itself through <Other>. Links must not close a circle." |
| `S-LINK-ZERO` | "Ratio must not be 0." |
| `S-STUDY-FOLLOWER` | "<Joint> follows <Driver> through <Link>. Put the key on <Driver> instead." |
| `S-STUDY-CLAMPED` | "<Joint>'s key at <time> (<value>) is beyond its limit of <limit>; it plays at the limit." |
| `S-CONTACT-STOP` | "Motion stopped at <value>: <BodyA> touches <BodyB> (<Set>)." |
| `S-STUDY-STOP` | "Motion stopped at <time>: <BodyA> touches <BodyB> (<Set>)." |
| `S-CONTACT-START` | "<BodyA> and <BodyB> already overlap at the start, so contact between them is not checked." |
| `S-CONTACT-NO-SETS` | "Contact is on, but there is no enabled contact set. Right-click components to make one." |
| `S-CONTACT-THIN` | "<Body> is only <t> thick and contact steps are <step>; it could pass through between steps. Set a smaller Step." |
| `S-CONTACT-STEPS` | "This motion needs <n> contact steps; the most is 2,000. Raise Step or drive a shorter way." |
| `S-CONTACT-TOO-SLOW` | "Checking contact for this motion would take about <s> (<n> steps × <p> pairs). Raise Step or take bodies out of the contact set." |
| `S-CONTACT-TIME-USED` | "Contact checking had used up its <budget> before this motion could be checked." (fix round 4) |
| `S-CONTACT-TIMEOUT` | "Contact checking ran out of time at <value>; the motion stopped there." |
| `S-CONTACT-DEV` | "Round faces are checked within <dev>, so contact closer than <tol> is not seen." |
| `S-CONTACT-SKIPPED` | "<Body> takes no part in contact: <reason>." |
| `S-CONTACT-NATIVE` | "Contact needs a newer Holo Forge native library than the one loaded." |
| `S-STUDY-TOO-SLOW` | "Working out this study would take about <s>; the most is 20 s. Shorten it, lower the frame rate or turn contact off." |
| `S-MODELLED-VIEW` | "Showing modelled positions while this tool is open." |
| `S-NEWER-ASSEMBLY` | "This assembly was saved by a newer Holo Forge; it is shown but cannot be edited here." |
| `S-BAKE-NO-JOINTS` | "Joints are baked only when Component Nodes is RigidBody3D." |
| `S-BAKE-HULL` | "<Body> collides as its convex hull, which is <n>% larger than the body." |
| `S-BAKE-HALF-LIMIT` | "<Joint> has only one limit; Godot needs both, so the open end is set to <value>." |
| `S-BAKE-CONE-WIDENED` | "<Joint>'s limits were widened to a symmetric cone of <swing> and a twist of <twist> for Godot." |
| `S-BAKE-NOT-JOLT` | "Joints were set up for Jolt Physics; with another 3D physics engine, joints fixed to the world may turn the other way." |
| `S-BAKE-NOT-BAKED` | "Not baked (design only): <list>." |
| `S-EXPORT-POSED` | "Bodies are written where the assembly places them." |
| `S-PLACE-GROUNDED` | "<Comp> is grounded. Unground it to place it." |
| `S-NO-COMPONENTS` | "Joints connect components, and this part has none. Make one with New Component." |
| `S-GROUP-SMALL` | "A rigid group needs at least two components." |
| `S-LIMITS-ORDER` | "Min must be below Max." |
| `S-REST-OUTSIDE` | "Rest must lie between Min and Max." |

---

## 3. Tool-by-tool behaviour

### Conventions used in this section

- Every Assemble tool is a command that makes **no timeline feature**. `tools/assemble_command.gd` extends `tools/inspect_command.gd` and returns `true` from `changes_document()`, so OK is one undo step (C1.4) and Cancel restores the document as it was. Previews are view-only.
- Catalog ids follow the existing pattern (`solid.assemble.joint`, slug `as-built_joint`, ...). Every workspace that lists the shared Assemble group (Solid, Surface, Mesh, Sheet Metal, Plastic) maps the same commands; find how `New Component` (Phase 3) is mapped across workspaces in `tools/catalog.gd` and copy it.
- **Command types**: `assemble:joint`, `assemble:as_built_joint`, `assemble:joint_origin`, `assemble:rigid_group`, `assemble:drive`, `assemble:motion_link`, `assemble:motion_study`, `assemble:place` (browser only), `assemble:contact_settings` (browser only). **Actions**: `toggle_contact_sets`, `ground_component`, `unground_component`, `reset_placement`, `move_to_active_component`, `new_contact_set`.
- "Snap slot" = a selection slot whose hover shows snap candidates (C2.3); Esc clears it; Tab moves to the next slot.
- Every refusal is shown in the panel's status row in red, and OK stays disabled while one stands. Every warning is shown in amber and does not block OK.
- Fields take expressions in document units; angles in degrees.

### 3.1 New Component (exists, Phase 3)

Unchanged. A new component has identity placement and is not grounded. Insert Component's derived bodies keep their derive placement in the modelled geometry, as today.

### 3.2 Component actions (browser right-click on a component; T adds them in Stage 2)

1. **Activate** (exists).
2. **Ground / Unground** (also the browser's ground button): top-level only (nested: item disabled with tooltip "Nested components move with their top-level component."). Ground stores the current pose as the placement (C3.5), then sets `grounded[c] = true`. Undo `Forge: Ground Comp1` / `Forge: Unground Comp1`.
3. **Place Component...** (`assemble:place`): move handles (three `"arrow"` and three `"angle"` manipulators, the existing types) at the unit's bounding-box centre, plus fields Move X, Y, Z and Turn X, Y, Z (deltas from where it was when the tool opened). Live preview; OK stores `placements[c]` (`Forge: Place Comp1`). Refused on a jointed unit (`S-PLACE-JOINTED`) or a grounded one (`S-PLACE-GROUNDED`). Nested components are placed relative to their parent.
4. **Reset Placement**: placement back to identity (`Forge: Reset Placement Comp1`); disabled when it is identity.
5. **New Contact Set** (on a selection of components and/or bodies): makes a set of the selection (`Forge: Contact Set`).

On a body: **Move to Active Component** sets `bodies[id].component` to the active component. This is a model change (it rebuilds, like the existing component edits) with undo `Forge: Move to Comp1`. Refused when the body already belongs to it.

### 3.3 Joint (`assemble:joint`, shortcut J)

**Panel (top to bottom):**
| Row | Control | Default | Notes |
|---|---|---|---|
| Type | 7 icon buttons (6.3) with names | Revolute | changing it rebuilds the Motion rows (C1.2) |
| Component 1 (moves) | snap slot | active | C2.3 kinds; Joint Origins too |
| Component 2 (stays) | snap slot | — | |
| Offset X / Y / Z | length fields | 0 | along the base snap frame's axes |
| Angle | angle field | 0° | about the base snap's Z |
| Flip | toggle button | off | turns the moving side over |
| Slide Axis | X / Y / Z (slider), X / Y (pin-slot) | Z / X | hidden for other types |
| Motion | one row per DOF: Value, Min (check + field), Max (check + field), Rest | 0, off, off, 0 | Value previews live |
| Play Motion | button | — | C4.5, view-only |
| Name | text | `Joint<n>` | |

**Flow.** With both slots set, the moving unit is shown where the new joint puts it (a view-only solve with the candidate joint appended). The joint glyph (6.2) sits at the joint frame; the limits arc or bar shows when limits are on. Every field change re-solves within one frame.

**OK** appends the joint (`Forge: Joint`). If the new joint ends in state `loop`, the panel shows `S-LOOP-OFF`/`S-LOOP-HOLDS` in amber before OK; OK is still allowed. **Edit** (browser double-click or context Edit) opens the same panel filled from the stored joint; OK is `Forge: Edit Joint1`.

**Refusals:** `S-NO-COMPONENTS` (on opening, when the part has no component), `S-SAME-UNIT`, `S-MESH-SNAP`, `S-GROUP-NOT-ROUND`, `S-LIMITS-ORDER`, `S-LIMITS-EQUAL`, `S-REST-OUTSIDE`, a Value outside its limits (`S-LIMIT` shown and the field clamps on OK). **Notes:** `S-SIDES-SWAPPED`, `S-NESTED-MOVES`.

### 3.4 As-built Joint (`assemble:as_built_joint`)

Rows: Type; Component 1 (any face of it; selects the unit); Component 2 (same); Origin (snap slot on either component, or a Joint Origin; hidden for Rigid); Slide Axis; Motion (values start at 0 = "as it is now", limits relative to now); Play Motion; Name. No Offset, Angle or Flip. Nothing moves on OK (C2.4; 5.5 #4 asserts it). Undo `Forge: As-built Joint`. Same refusals as 3.3.

### 3.5 Joint Origin (`assemble:joint_origin`)

Rows: Snap (snap slot; the component is the snap's unit, nested allowed), Offset X/Y/Z, Angle, Flip, Name (`Origin<n>`). Shows a frame glyph (6.2). OK appends to `origins` (`Forge: Joint Origin`). Joints pick it as snap kind `origin`. Deleting an origin that a joint uses is allowed: the joint keeps the origin's last frame (`S-SNAP-LOST`).

### 3.6 Rigid Group (`assemble:rigid_group`)

Rows: Components (multi-pick of top-level units: click any body, or select in the browser), Name (`Group<n>`). OK stores `relative` from the current poses (`Forge: Rigid Group`). Refused with fewer than two (`S-GROUP-SMALL`) or with the ground in it (the ground is already fixed: "The fixed bodies cannot join a rigid group; ground the components instead.").

### 3.7 Drive Joints (`assemble:drive`)

Rows: Joint (pick a glyph or a browser item; preset when one is selected), one row per DOF with a Value field and a slider (limited: min..max; unlimited rotation: −360°..360°; unlimited slide: ±the moving unit's bounding-box diagonal), Play Motion, Contact row (on/off state of the global switch with the `S-CONTACT-DEV` note when it applies), status row (the last stop sentence).

- **Viewport handles** at the joint frame: revolute an `"angle"` ring about Z; slider an `"arrow"` along the slide axis; cylindrical arrow + ring; pin-slot arrow + ring; planar two arrows + ring; ball three rings. Dragging drives (C4) live. With contact on, each drag event sweeps from the last reached value with its own short deadline of 0.1 s; when it cannot finish, the motion holds at the last clear value and the status row says `S-CONTACT-TIMEOUT`.
- Typing a value drives from the current value to it (with the full `CONTACT_SECONDS` budget).
- **OK** stores the reached values of the joint and of every follower (`Forge: Drive Joint1`). **Cancel** restores the pose.

### 3.8 Motion Link (`assemble:motion_link`)

Rows: Driver (joint + DOF dropdown when it has more than one), Follower (same), Ratio (expression; unit label from the two DOF kinds: °/°, mm/°, °/mm, mm/mm), Test slider (drives the driver across its range, view-only, so the user sees the follower move), Name (`Link<n>`). OK stores the link with the captured offset (`Forge: Motion Link`). Refusals `S-LINK-SECOND-DRIVER`, `S-LINK-CIRCLE`, `S-LINK-ZERO`, and "A joint cannot follow itself." (same joint and DOF).

### 3.9 Enable Contact Sets (action `toggle_contact_sets`) and contact sets

- The toolbar button is a toggle (pressed = `contact.enabled`); clicking it is one undo step (`Forge: Contact On` / `Forge: Contact Off`).
- Contact sets are made from the browser (3.2 #5). A set's context menu: Enable / Disable, Rename, Add Selected, Remove Selected, Delete. The Contact Sets folder's context menu: **Contact Settings...** (`assemble:contact_settings`): Tolerance (0..1 mm, default 0.01 mm), Step (0.01..10 mm, default 1 mm), Precision (0.0001 mm .. Step/10, default 0.001 mm).

### 3.10 Motion Study (`assemble:motion_study`)

Opens `ui/motion_study_panel.gd`, a floating panel docked under the viewport (reuse `ui/floating_panel.gd`):
- Study dropdown + New Study + Delete Study; Length (s), Frame Rate, Contact (check).
- One track per (joint, DOF) that has keys, plus an "Add track" dropdown; keys drawn as diamonds (6.2); a playhead; a time ruler.
- Add Key: for the chosen track at the playhead, with a value field (default: the DOF's value at that time). Drag a key in time; Delete removes the selected key.
- Play / Pause / Loop and scrubbing play the precomputed frames (C6), view-only. The status line shows `S-STUDY-STOP`, clamps and warnings.
- Each edit is one undo step (`Forge: Motion Study1`) and recomputes the frames (bounded by `STUDY_SECONDS`). Closing the panel restores the stored pose.

### 3.11 Selection, delete and suppress

- Joint glyphs are pickable in the viewport (they win over the bodies behind them within 8 px). Selecting one highlights both units and selects it in the browser.
- Delete key on a selected joint, origin, group, link, set or study deletes it (`Forge: Delete Joint1`, ...). Links that use a deleted joint are deleted with it (same undo step) and the status line says so.
- Suppress / Unsuppress (browser) sets `suppressed` (`Forge: Suppress Joint1`). A suppressed joint takes no part in solving or baking and is drawn dimmed.

### 3.12 Inspect tools on posed bodies

Measure, Interference and Mass Properties work on the posed bodies when the view is posed (C7.4). Section Analysis and the other analyses stay attached to their bodies (they live under the holders). Their behaviour with an empty assembly is unchanged (byte-identical results).

---

## 4. Stages, teams and file ownership

Teams: **A** (assembly core), **N** (native contact), **V** (view and browser structure), **T** (tools, panels, catalog, icons, hook), **K** (bake and export), plus an adversarial **verifier** in Stage 3. A team edits only the files listed for it in its stage. New files are owned by the team that makes them. Anything else: report it, do not edit it.

### Stage 0 (team A, alone): data and the empty solve

| Files | Work |
|---|---|
| new `core/assembly/xform64.gd` | C1.3 |
| new `core/assembly/assembly_data.gd` | schema, `normalized`, defaults, id/counter helpers (`new_id(assembly, kind)`), the C10 sentences, `fill(sentence, values: Dictionary) -> String` |
| new `core/assembly/solver.gd` (skeleton) | `solve()` with the full output contract (C3.1), honouring placements and grounding only (no joints yet) |
| `core/document.gd` | `assembly` export, `snapshot`/`restore` (C1.1) |
| `nodes/cad_part.gd` | **only** `_design_text`: add `"assembly"` (C1.6) |
| `ui/forge_workspace.gd` | **only** `_model_of` exclusion, `_refresh_for` branch and a `_refresh_assembly()` that calls the solver and, if the viewport has `set_body_poses`, hands it the result (C1.5) |
| new `tests/holo_forge_assembly_data_test.gd` | 5.1 |

Gate: 5.1 passes; all 55 existing headless tests pass; one hook (`--holo-forge-editor-test`) passes (orchestrator runs it).

### Stage 1 (three teams in parallel)

| Team | Files | Work |
|---|---|---|
| **A** | new `core/assembly/joint_math.gd` (M(v), O, frames, residuals, DOF tables), new `core/assembly/snaps.gd` (C2.3, candidates, cache), `core/assembly/solver.gd` (full C3), new `core/assembly/motion.gd` (C4 and C6 without contact), new `tests/holo_forge_assembly_fixtures.gd` (5.0), new `tests/holo_forge_assembly_solver_test.gd` (5.2) | the core |
| **N** | new `N\src\mesh_contact.cpp/.h`, `N\src\cad_mesh.h/.cpp` (bind `overlap`, the Manifold cache; small edits), `N\src\mesh_budget.h` (rate), `N\CMakeLists.txt` (add the source), new `tests/holo_forge_assembly_contact_native_test.gd` (5.3), `tests/holo_forge_native_smoke_test.gd` (one added check that `CadMesh` has `overlap`) | C5.1; the only native build in Phase 8 |
| **V** | `ui/forge_viewport.gd` (`set_body_poses`, glyph layer hook, DOF handles placement API), `core/picking.gd` (C7.3), `ui/forge_workspace.gd` (modelled view switch C7.2, posed picks), `ui/browser.gd` (folders, joint items, ground button C7.5), `ui/forge_theme.gd` (6.1), new `ui/assembly_display.gd` (C7.1, glyphs 6.2), new `ui/assembly_ui.gd` (skeleton: panel row builders for snap slots and DOF rows; T owns it from Stage 2), new `tests/holo_forge_assembly_view_test.gd` (5.4) | V codes against the C3.1 output dictionary and builds solve outputs by hand in its test until A's solver lands |

Gate: 5.2, 5.3, 5.4 pass; existing tests pass; the orchestrator runs the 10 hooks.

### Stage 2 (three teams in parallel)

| Team | Files | Work |
|---|---|---|
| **T** | `tools/catalog.gd` (`IMPLEMENTED_PHASE := 8`, the Phase 8 command map, 3 conventions), new `tools/assemble_command.gd`, new `tools/assemble_joint_command.gd` (Joint and As-built Joint), new `tools/assemble_origin_command.gd`, new `tools/assemble_rigid_group_command.gd`, new `tools/assemble_drive_command.gd`, new `tools/assemble_link_command.gd`, new `tools/assemble_place_command.gd`, new `tools/assemble_contact_command.gd` (settings), `ui/assembly_ui.gd`, new `ui/motion_study_panel.gd`, `ui/forge_workspace.gd` (actions, command routing, Delete key), `ui/browser.gd` (context items 3.2, 3.9, 3.11), `ui/timeline.gd` only if needed for icons (nothing goes on the timeline), `tools/measure_command.gd`, `tools/interference_command.gd`, `tools/mass_command.gd` (pass poses), new `icons/assemble/*.svg` (6.3) and redraws of the 9 existing Assemble icons if the originality check fails, the existing test flips (5.10), new `tests/holo_forge_assembly_tools_test.gd` (5.5) | the tools |
| **A** | new `core/assembly/contact.gd` (C5.2-C5.5), `core/assembly/motion.gd` (contact in drive and study), `core/inspect.gd` and `core/analysis.gd` (poses, C7.4), new `tests/holo_forge_assembly_contact_test.gd` (5.6) | contact |
| **K** | `nodes/cad_part.gd` (C8.2-C8.4), new `core/assembly/bake_joints.gd` (C8.5), `core/export.gd` (C8.6), new `tests/holo_forge_assembly_bake_test.gd` (5.7, V1-V8 first) | bake and export |

T needs `contact.gd` only through `motion.gd drive()`; until A lands contact, T's tests run with contact off. K uses `solve()` from Stage 1.

Gate: 5.5, 5.6, 5.7 pass; all existing tests pass (with the 5.10 flips); the orchestrator runs the 10 hooks.

### Stage 3: acceptance, hook, verifier

| Team | Files | Work |
|---|---|---|
| **A** | new `tests/holo_forge_assembly_test.gd` (5.8) | the plan's acceptance test |
| **T** | new `tests/holo_forge_assembly_editor_test.gd` (5.11), `plugin.gd` (`ASSEMBLE_TEST_ARG := "--holo-forge-assemble-editor-test"` and the loader branch, copying the existing pattern), new `tests/holo_forge/assembly_editor_test.tscn` (made by the hook itself, its own folder), screenshots to `docs/holo_forge/screenshots/phase8/` | the hook |
| **Verifier** | probe scripts in its own scratch folder only; edits nothing in the project | tries to break every contract (C1-C10), the time bounds, the "no wrong result without a warning" rule, undo/redo, save/reload, the bake under Jolt, and the hook guard; reports findings with repro steps and numbers |

Then a fix round (each finding goes to the owning team), then the orchestrator's final sequential run: every headless test (55 old + 8 new), all **11** hooks, `validate_project`, screenshots checked.

---

## 5. Acceptance tests (numbers to assert)

Test format (as every existing headless test): `extends SceneTree`, `_init()` calls `call_deferred("run")`, one `PASS ...` or `FAIL ...` line per case, `quit(0)` when all pass, `quit(1)` otherwise. A case that needs the native library prints `SKIP <case>: native library missing` when `ClassDB.class_exists("CadMesh")` is false (it never counts as a pass in the final run, where the library is present). Lengths below are in mm for reading; tests compare in meters. "Exact" means `==` on doubles.

### 5.0 Fixtures (`tests/holo_forge_assembly_fixtures.gd`, a helper, not a test; team A, Stage 1)

Built through the real document, real features and `REGEN.rebuild` (not hand-made results). Other teams may **add** functions; never change an existing one. Boxes are given by min and max corners (mm, part space).

| Function | Contents |
|---|---|
| `stack()` | ground body Base (0,0,0)-(100,100,10); component Cube with body (40,40,40)-(60,60,60) |
| `lever()` | ground body Base (−50,−50,0)-(50,50,10) with a Ø10 through hole on axis Z at (0,0); component Lever with body (−10,−10,10)-(95,10,20) and a Ø10 through hole on axis Z at (0,0). Lever tip point (95, 0, 15) |
| `lever_stop()` | `lever()` plus ground body Stop (40,20,10)-(60,50,20) |
| `gears()` | ground body Base (−50,−50,0)-(80,50,10) with Ø4 holes at (0,0) and (30,0); components Gear1 (cylinder r 20, z 10..20, axis Z at (0,0)) and Gear2 (cylinder r 10, z 10..20, axis Z at (30,0)); revolute joints Joint1 (Gear1) and Joint2 (Gear2) at the bottom circle centres on the hole circles |
| `slider_wall()` | ground body Base (−20,−50,0)-(200,50,10); ground body Wall (30,−30,0)-(40,30,40); component Block with body (0,−10,10)-(20,10,30); an as-built slider on the Block's bottom face centre with slide axis X (positive moves toward the Wall; the gap is 10 mm); contact set {Block, Wall}; contact on |
| `pin_hole()` | `lever()`'s Base; component Pin, cylinder r 5 (exact fit), z −5..25 on axis Z at (0,0); revolute on the circle centres; contact set {Pin, Base}; contact on |
| `chain(n)` | ground body Base 10 mm cube; components C1..Cn, 10 mm cubes in a row along X, each joined to the previous by a revolute at the shared face centre |
| `four_bar()` | ground with two pivots 60 mm apart; links of 20, 50 and 40 mm (components) joined by four revolutes; the fourth closes the loop |
| `all_types()` | one component per joint type on a common Base, each type's joint with limits on every DOF (values in 5.7 #4) |
| `mesh_block()` | `slider_wall()` with the Block converted to a mesh body (Tessellate, High) |

### 5.1 `tests/holo_forge_assembly_data_test.gd` (A, Stage 0)

1. A new document has `assembly == {}`; `normalized({})` has every C1.2 key with its default; `version == 1`.
2. `snapshot()` / `restore()` round-trip the assembly (deep equal); restoring a snapshot that has no `"assembly"` key gives `{}`.
3. `new_id` gives `joint1`, `joint2`, ... and never reuses an id after a delete.
4. Save a document with an assembly holding a placement `xform64` of 12 random doubles (seeded) and a DOF value of `0.1 + 0.2` to a text `.tscn` under `user://holo_forge_assembly_fixtures/` with `ResourceSaver`, load it with `CACHE_MODE_IGNORE`: every double is **bit-identical**. If not, the exact-storage fallback in 0.2 is used and this case then passes on it.
5. Workspace: an assembly-only `change()` does not call `recompute()` (count with a test seam on the workspace) and does call `_refresh_assembly()`; Undo/Redo restore it; the undo name is the one given.
6. `CadPart._design_text` differs for two documents that differ only in `assembly`.
7. `xform64`: `compose(a, inverse(a))` is identity within 1e-15 for 1,000 random rigid transforms (translations up to 10 m); `to_transform(from_transform(t)) == t` exactly; `angle_between` of `rot_z(1e-9)` and identity is 1e-9 within 1e-18.
8. A document with `assembly.version == 2` loads; every assembly tool and `change()` on it is refused with `S-NEWER-ASSEMBLY`; the data is unchanged after a save.
9. Skeleton solve: placements and grounding give `poses`/`body_poses` equal (exact) to the stored placements; nested placement composes (1e-15).

### 5.2 `tests/holo_forge_assembly_solver_test.gd` (A, Stage 1)

1. Empty assembly: every pose identity, no warnings.
2. Free unit with placement T(10, 0, 0): its body pose equals the placement exactly.
3. `stack()`, rigid joint, a = Cube bottom face centre, b = Base top face centre: Cube pose is translation (0, 0, −30) within 1e-12 m and rotation identity within 1e-12.
4. `lever()`, revolute on the hole circles (a = Lever's bottom hole circle, b = Base's top hole circle), value 30°: the tip (95, 0, 15) goes to (95 cos 30°, 95 sin 30°, 15) within 1e-12 m.
5. Every type, 100 random samples each (`RandomNumberGenerator.seed = 8`): random rigid snap frames on two units, random offsets (±50 mm), angles, flips and values (rotations ±2π, slides ±0.1 m): the C2.4 relation holds within 1e-12 m and 1e-12 rad.
6. Reversed traversal: the case-4 joint with the Lever grounded and the Base made a free component instead: the relation holds within 1e-12 and the Base moves.
7. Offset (1, 2, 3) mm, angle 90°, flip on `stack()`: the Cube's bottom face centre lands at the analytic point (computed in the test from C2.4) within 1e-12 m, and the Cube is turned over.
8. Snaps on the fixtures (1e-8 m, 1e-9 rad): Base top `face_center` (50, 50, 10) with Z = +Z and X = part X; hole `circle_center` (0, 0, 10) with Z = +Z; hole `axis_mid` (0, 0, 5); an `edge_mid` and a `vertex` of the Base top face; a face with Z = +X gets X = part Y.
9. `mesh_block()`: `group_center` of the Block's top group within 1e-7 m (float32 mesh); a fitted round group (tessellated Pin): radius within 0.5%, axis within 0.1°; an edge pick on the mesh body is refused with `S-MESH-SNAP`.
10. Same unit refused (`S-SAME-UNIT`); first pick on the ground swaps sides (`S-SIDES-SWAPPED`); a nested pick says `S-NESTED-MOVES` and moves the top-level unit.
11. Limits (`lever()`, min −30°, max 90°): drive to 120° gives a value **exactly equal** to the stored max and `S-LIMIT`; drive to −45° gives exactly the stored min.
12. Unlimited: drive to 720° stores 4π (within 1e-15 relative) and the pose equals `rot_z(4π)` within 1e-12.
13. `gears()`, link ratio 2: drive Joint1 to 30° gives Joint2 = 2 × 30° (exact in doubles, to 1e-15 relative).
14. Joint2 max 90°: drive Joint1 to 60° gives Joint1 = 45° (1e-15 relative), Joint2 exactly its stored max, and `S-LINK-LIMIT`.
15. Chain A→B ratio −0.5, B→C ratio 2: C = −A within 1e-15 relative for 10 values.
16. Driving the follower: Joint2 to 40° gives Joint1 20°.
17. Link refusals: `S-LINK-SECOND-DRIVER`, `S-LINK-CIRCLE`, `S-LINK-ZERO`, self link; each in ≤ 0.2 s.
18. `four_bar()` as built: the closing joint says `S-LOOP-HOLDS` (residuals ≤ 1e-9); after driving the first joint by 10°: state `loop`, `S-LOOP-OFF`, translation residual > 1e-4 m.
19. Lost snap: change the Base's height feature so the snapped face is gone: `S-SNAP-LOST`, the pose equals the one before the change within 1e-12 (it used the stored frame).
20. Delete the Lever's feature: the joint is `unresolved` with `S-MISSING-COMPONENT`; Undo restores state `ok`. Roll back before the Lever's feature: state `waiting`, `S-WAITING`.
21. Rigid group of three components, the first jointed: the relative poses stay as captured within 1e-12 for 10 drive values.
22. Post-check works: with the test seam `SOLVER.debug_corrupt = true` (adds 1e-6 m to one pose after solving), the joint is `error` with `S-SOLVE-FAULT`.
23. Motion Study: keys (0 s, 0°) and (2 s, 90°): at 1 s 45° within 1e-12; at 3 s 90° (held); frame count `ceil(length × fps) + 1`; a key on a follower is refused (`S-STUDY-FOLLOWER`); a key at 120° plays at 90° with `S-STUDY-CLAMPED`.
24. Timing (5.9): `solve` on `chain(50)` and `chain(200)`; study precompute of 10 s at 30 fps with 5 keyed joints.

### 5.3 `tests/holo_forge_assembly_contact_native_test.gd` (N, Stage 1)

Meshes are made with the existing `CadMesh` constructors (boxes from 12 triangles, spheres from the existing fixture code).
1. Two 20 mm cubes overlapping 1 mm along X (faces 20 × 20): `volume` 400 mm³, `area` 880 mm², `thickness` 0.909090... mm (= 800/880), each within 1e-9 relative.
2. Touching face to face (gap 0): `volume` ≤ 1e-15 m³ and `thickness` ≤ 1e-9 m.
3. 1 mm apart: `overlap == false`, `early_out == true`.
4. `other_to_this` = R_z(90°) + T(5, 0, 0) mm gives the same volume (1e-9 relative) as the same meshes pre-placed with `transformed`.
5. Cache: the second call on the same two 20k-triangle spheres takes ≤ 30% of the first.
6. Bound: two 200k-triangle meshes, `time_limit` 0.05: returns `timed_out` in ≤ 1.05 s.
7. Open mesh and inside-out mesh: refused with the C5.1 errors.
8. A mutation of a mesh drops its cached Manifold: an overlap after the change reflects the new geometry.
9. Timing (5.9): 2 × 12, 2 × 20k, 2 × 200k.

### 5.4 `tests/holo_forge_assembly_view_test.gd` (V, Stage 1)

1. `set_body_poses` with a hand-made solve output: each holder's transform equals `to_transform(pose)` exactly.
2. A ray at the posed Lever tip face returns the **modelled** point within 1e-6 m and `world_point` within 1e-6 m of the posed point.
3. Opening a feature command: every holder is identity and the status line holds `S-MODELLED-VIEW`; closing it re-poses exactly.
4. An analysis and a decal on the Lever follow the pose (their nodes are under the holder).
5. Browser: the Joints folder lists joints with their type icons and state badges; empty new folders are hidden; the ground button (`BUTTON_GROUND = 3`) shows for top-level components only.
6. Glyphs: one per visible joint, none for `visible: false`, dimmed for suppressed; snap candidate glyphs for one face.
7. Theme: every 6.1 token exists in both themes (the existing theme test pattern).
8. Timing (5.9): `set_body_poses` with 200 bodies.

### 5.5 `tests/holo_forge_assembly_tools_test.gd` (T, Stage 2; headless `WORKSPACE.new()`)

1. Catalog: `IMPLEMENTED_PHASE == 8`; every Assemble tool is enabled in every workspace that lists the group; a Phase 9 tool (Flange; find its id in `catalog.gd`) is greyed.
2. Joint through the command with pick dictionaries: OK adds one joint, undo name `Forge: Joint`; Undo removes it; Redo brings it back (deep equal).
3. Cancel: the document's assembly is deep-equal to before and the view pose is restored.
4. As-built Joint: OK changes no body pose (every pose equal before and after within 1e-12).
5. Joint Origin, then a joint snapped to it: the joint frame equals the origin frame within 1e-12.
6. Rigid Group: two components; refused with one (`S-GROUP-SMALL`).
7. Drive: typed 120° on the limited Lever: the status row shows `S-LIMIT`; OK stores exactly 90°; undo name `Forge: Drive Joint1`.
8. Motion Link: made through the panel; each refusal sentence shows in the status row and blocks OK.
9. Contact: `toggle_contact_sets` flips `contact.enabled` with one undo step; New Contact Set from a browser selection; Contact Settings refuses Step 0.
10. Motion Study panel: add two keys, frames computed, playback sets the holders; each edit is one undo step.
11. Ground / Unground / Place Component / Reset Placement / Move to Active Component (the last one rebuilds; the others do not).
12. Delete and Suppress a joint; deleting a joint deletes its links in the same undo step.
13. `S-NO-COMPONENTS` on opening Joint in a part without components; `S-SAME-UNIT`.
14. Measure between the posed Lever tip vertex and the Base's corner vertex gives the posed distance within 1e-6 m; Mass Properties' centre of mass follows the pose.
15. Every Assemble catalog entry and every 6.3 file has an SVG that loads.

### 5.6 `tests/holo_forge_assembly_contact_test.gd` (A, Stage 2)

1. `slider_wall()`: drive the slider to 50 mm: it stops at s with **10.0090 mm ≤ s ≤ 10.0101 mm** (crossing at 10.01001 mm for tolerance 0.01 mm, precision 0.001 mm); `S-CONTACT-STOP` names Block, Wall and the set; at s the pair's thickness is ≤ `tol_eff` (the stop is clear).
2. `lever_stop()`: drive the Lever to 60°: θ_touch is computed in the test in doubles as the smallest positive θ at which a vertical edge of the Stop reaches the Lever's side plane (about 9.34°, at the Stop's (60, 20) edge); assert θ_touch ≤ θ_stop ≤ θ_touch + 0.1°.
3. `pin_hole()`: drive 360°: no stop (reached exactly 2π); `checked_pairs == 1`; no `S-CONTACT-START`.
4. A pair that overlaps at the start is left out with `S-CONTACT-START`, and the drive reaches its target.
5. Contact on with no enabled set: `S-CONTACT-NO-SETS`, the target is reached.
6. A 0.6 mm plate in a set with Step 1 mm: `S-CONTACT-THIN`.
7. Step 0.01 mm over 100 mm (10,000 steps): refused with `S-CONTACT-STEPS` in ≤ 0.2 s.
8. Two 200k-triangle bodies over 100 steps: refused with `S-CONTACT-TOO-SLOW` in ≤ 0.2 s (unless the estimate fits, then the test picks a size that does not, from the measured rate).
9. Timeout: with the test seam `CONTACT.debug_budget_seconds = 0.05`, the drive ends with `S-CONTACT-TIMEOUT` in ≤ 1.05 s, and the reached value is clear.
10. Study with contact on `lever_stop()`: keys 0° at 0 s and 30° at 2 s: `stopped_at` is within one bisection of the time where θ = θ_touch (within the 0.1° window of case 2 mapped to time), and every later frame equals the stopped pose.
11. Links with contact: a follower that collides stops the driver; the sentence names the follower's bodies.
12. `mesh_block()`: case 1 holds with the mesh Block.
13. Inspect with poses: `INSPECT.interference` with the posed Lever over the Stop reports the overlap, and without poses reports none; with an empty assembly every inspect result is byte-identical to the Phase 7 result (compare `var_to_str`).
14. Contact off: the drive reaches its target with no contact work (`checked_pairs == 0`).
15. Timing (5.9): `slider_wall()` drive with contact.

### 5.7 `tests/holo_forge_assembly_bake_test.gd` (K, Stage 2)

**V1-V8 first** (engine facts, plain Godot nodes, no Holo Forge code): V1 hinge axis (two bodies, hinge at identity, impulses about X, Y, Z: only the Z one turns freely); V2 hinge limit units, zero and range (set up at a turned pose, check the limits are measured from it; try ±π); V3 slider axis; V4 cone twist axis and spans; V5 6DOF angular Z limit of ±120° holds under Jolt; V6 a concave shape in a moving `RigidBody3D` (what Jolt does); V7 `create_convex_shape`; V8 physics steps in a `--script` run. Each prints its answer in its PASS line; K writes the answers into the report.

1. Empty assembly, Node3D mode: the baked tree equals the Phase 7 bake (node names, classes, transforms, mesh digests).
2. Node3D mode, posed `lever()` at 30°: the Lever node's transform equals `solve.transforms` exactly; nested components are local to their parent.
3. RigidBody3D mode on `lever()`: Lever is a `RigidBody3D`, the Base is under a `StaticBody3D` named `Ground`; a grounded component is a frozen static `RigidBody3D`; each body has one `CollisionShape3D` named `<Body>Shape`, a direct child, with a `ConvexPolygonShape3D`; mass equals `INSPECT.mass_properties` within 1e-6 relative; centre of mass within 1e-6 m.
4. `all_types()`: per joint the node class (C8.5), the path `Joints/<Name>`, `node_a` (`""` for the ground) and `node_b` (`"../../<Comp>"`), `get_node(node_b)` is the right `RigidBody3D`, and every flag and limit of C8.5 read back within 1e-6; the hinge's local Z, the slider's and cone twist's local X are the joint's axis in part space within 1e-6.
5. Shifted limits: Lever baked at 30° with limits −30°..90° has lower −60°, upper 60°.
6. Half-limited hinge and slider: `S-BAKE-HALF-LIMIT`; an asymmetric ball: `S-BAKE-CONE-WIDENED`.
7. `bake_pose = REST`: transforms are those of the rest values.
8. **Jolt simulation** (the plan's "the game gets working joints"): `lever()` baked as RigidBody3D with the hinge on part axis Z, run with Godot's default gravity (−Y), which lies in the Lever's plane, so the Lever swings about the hinge: after 60 physics frames the Lever's angular velocity about X and Y is < 1e-3 rad/s, its hinge angle is within its limits + 1°, and its hole centre stays within 1 mm of the joint origin.
9. Save the baked scene to `user://holo_forge_assembly_fixtures/` with `ResourceSaver`, reload: every joint's `node_a`/`node_b` resolves, properties equal.
10. With the engine-name test seam set to "Godot Physics", the bake adds `S-BAKE-NOT-JOLT`.
11. Export: STL of the posed Lever has the posed bounding box (1e-6 m); with an empty assembly every export format writes byte-identical files to the Phase 7 export.
12. Timing (5.9): RigidBody3D bake of `chain(20)` (excluding the mesh bake).

### 5.8 `tests/holo_forge_assembly_test.gd` (A, Stage 3; the plan's acceptance test)

One script, through the workspace and the document as a user would (commands, not internal calls), on `lever()` + `gears()`:
1. **Revolute limits clamp a drive:** Lever revolute −30°..90°; Drive Joints to 120° stops exactly at 90° with `S-LIMIT`; to −45° stops exactly at −30°.
2. **A 2:1 link is honoured:** Gear1 → Gear2 ratio 2; drive Gear1 to 30°: Gear2 is 60° (1e-15 relative); with Gear2 max 90°, driving Gear1 to 60° stops it at 45° with `S-LINK-LIMIT`.
3. **The bake makes matching Joint3D types and node paths:** RigidBody3D mode: `Joints/Joint1` is a `HingeJoint3D` with `node_a == NodePath("")` and `node_b == NodePath("../../Lever")`; the gear joints are `HingeJoint3D` too; `get_node(node_b)` is a `RigidBody3D` for each.
4. Undo to the start gives the empty assembly; Redo gives it all back; save and reload (own `user://` scene) gives a deep-equal assembly and the same poses (exact).

### 5.9 Timing method

- `tests/holo_forge_timing.gd compare(op, calibration, rounds, label)`.
- GDScript calibration (solver, motion, view, bake): the fixed 200k-iteration float loop. Native calibration (overlap): `kernel.make_sphere(...)` then `CadShape.tessellate(...)`, as in Phase 7.
- Measure each op on the dev machine at implementation time; set the ratio limit to 2 × the measured ratio; put the measured milliseconds and the ratio in the test's comment. C9 gives the targets; if a target is missed, report the split (ours / library / post-check). Never skip a post-check to meet a target.
- `HOLO_FORGE_TIMING_SLOWDOWN=3` must make each timing check fail. Check that once per test file.

### 5.10 Existing tests to update (team T, Stage 2)

Found by grep on 2026-11-13; re-grep for `IMPLEMENTED_PHASE`, `Phase 8`, `Joint` and `assemble.` before editing:
- `tests/holo_forge_editor_test.gd` (about line 78): checks that Joint is greyed. Change it to check that Joint is enabled and a Phase 9 tool (Flange) is greyed.
- `tests/holo_forge_insert_editor_test.gd` (about lines 91-92 and the PASS text near 628, "Phase 8 Joint off"): same flip; new PASS text.
- `tests/holo_forge_inspect_editor_test.gd` (about lines 85-86 and 736): same.
- `tests/holo_forge_surface_editor_test.gd` (about lines 57, 67-68 and 205): same.
- `tests/holo_forge_mesh_editor_test.gd` (about lines 653-657, "phase <= 7" / "> 7"): use `CATALOG.IMPLEMENTED_PHASE` instead of the literal 7.
- `tests/holo_forge_toolbar_test.gd`: generic; must still pass unchanged (its Flange check is Phase 9).
- `tests/holo_forge_native_smoke_test.gd`: N adds the `overlap` method check (Stage 1).
- `tests/holo_forge_bake_test.gd`, `tests/holo_forge_export_test.gd`, `tests/holo_forge_inspect_test.gd`: no change; they must still pass (the empty-assembly paths are byte-identical).
The five hook files above are hooks: the orchestrator runs them after Stage 2.

### 5.11 Editor hook `--holo-forge-assemble-editor-test` (T, Stage 3)

`tests/holo_forge_assembly_editor_test.gd`, started by `plugin.gd` like the other hooks; the hook guard applies. It builds its own scene `tests/holo_forge/assembly_editor_test.tscn` (a `CadPart` with the `lever()`, `gears()` and `slider_wall()` designs), saves it only with `ResourceSaver`, and opens it. Every step uses real input (`root.push_input`: mouse motion, clicks, drags, keys) unless it says otherwise. `--holo-forge-assemble-editor-only=a,b` runs named parts and ends with `PARTIAL`. Screenshots (both themes) go to `docs/holo_forge/screenshots/phase8/`.
1. Press J: the Joint panel opens with Revolute chosen.
2. Hover the Lever's hole edge: candidate glyphs show; the hovered one grows; click takes `circle_center`. Click the Base's hole edge. Type Min −30 and Max 90 (real key events). OK. The browser's Joints folder shows Joint1; Edit > Undo's name is `Forge: Joint`.
3. Right-click Joint1 in the browser: the menu has Edit, Drive, Rename, Suppress, Delete.
4. Drive: drag the ring handle about 120°: the Lever stops at 90°, the status row shows `S-LIMIT`. OK. Ctrl+Z returns to 0°; Ctrl+Y back to 90°.
5. Gears: make a 2:1 Motion Link in its panel; drive Gear1 to 30° by typing: Gear2's holder is at 60° (1e-5 rad from its transform).
6. Contact: click the Enable Contact Sets button (pressed state shows); select Block and Wall in the browser, right-click > New Contact Set; drive the slider to 50 mm: it stops near 10.01 mm with `S-CONTACT-STOP` shown.
7. Motion Study: open it, add keys 0° at 0 s and 90° at 2 s on Joint1, press Play; after the playhead passes 1 s (pause there), the Lever's holder equals the 1 s frame within 1e-6.
8. Open Extrude: the view shows modelled positions and `S-MODELLED-VIEW`; Esc: posed again.
9. Click a component's ground button: the icon changes; Undo.
10. Select the CadPart, set Component Nodes to RigidBody3D in the Inspector (property set through the inspector's own editor control): the scene tree has `Lever` as `RigidBody3D` and `Joints/Joint1` as `HingeJoint3D`.
11. Save the hook's own scene with `ResourceSaver`, reload it: the assembly is deep-equal and the poses are the same.
12. The hook guard reports no change outside the hook's folders.

---

## 6. Visual spec (both Forge themes)

### 6.1 New `ui/forge_theme.gd` tokens (dark / light)

| Token | Dark | Light | Use |
|---|---|---|---|
| `assembly_joint` | `#f0a33a` | `#b86e00` | joint badges, axes, candidate dots, key diamonds |
| `assembly_joint_selected` | `#4aa3ff` | `#0b5fd1` | selected or hovered joint and candidate (use the existing selection token instead if one exists with this role) |
| `assembly_limit` | `assembly_joint` at alpha 0.18 | same rule | limit sectors and bars |
| `assembly_warning` | `#ffd23f` | `#a87a00` | loop state, amber panel rows (reuse `mesh_warning` if it is the same hue; say which in the report) |
| `assembly_unresolved` | `#ff4d4d` | `#c41616` | unresolved / error state |
| `assembly_ground` | `#9aa4b2` | `#5a6472` | ground glyph and browser icon tint |
| `assembly_contact` | `#ff5d8f` | `#c2185b` | contact-stop flash and point |
| `assembly_ghost` | `Color(0.6, 0.8, 1.0, 0.25)` | `Color(0.1, 0.35, 0.7, 0.25)` | the moving unit's start position during Joint and Drive previews |
| (existing) `axis_x`, `axis_y`, `axis_z` | as today | as today | Joint Origin triads, joint frames |

Text on panels keeps the existing tokens. The theme test's contrast rules apply to every new token used for text or thin lines.

### 6.2 Viewport glyphs (built in `ui/assembly_display.gd`, rebuilt on `apply_theme`)

- **Joint badge**: a 22 px screen-constant rounded hexagon billboard at the joint frame origin, `assembly_joint` outline on a dark/light panel fill, with the type pictogram (6.3) inside; drawn on top of bodies. State dot at its upper right: amber (`loop`), red (`unresolved`, `error`), grey (`waiting`). Suppressed: 40% opacity.
- **Joint axis**: a line along the joint Z, length 0.15 × the moving unit's bounding-box diagonal (at least 24 px on screen), with an open arrowhead; slide axes get a double-headed arrow.
- **Limits**: revolute: a filled sector in `assembly_limit` from min to max about Z, radius 0.12 × diagonal, with a short tick at rest and a needle at the value; slides: a bar from min to max with a rest tick and a value marker; open ends fade out.
- **Snap candidates**: 6 px marks in `assembly_joint`: face centre filled circle, edge midpoint small diamond, vertex small square, circle centre open ring, axis points plus sign. The hovered one 10 px in `assembly_joint_selected`.
- **Joint Origin**: a triad in the axis colours (0.08 × diagonal, at least 24 px) with a small open circle at the origin.
- **Ground glyph**: a short base line with three slanted ticks under a small block, in `assembly_ground`, shown under a grounded unit only while its browser item is hovered or selected.
- **Contact stop**: both bodies' outlines flash in `assembly_contact` for 1 s; a 8 px dot marks `point`.
- **Ghost**: during Joint and Drive previews, the moving unit's starting place is drawn in `assembly_ghost` (unshaded, no depth write).

### 6.3 Icons (new, original; `A\icons\assemble\`)

House style: 24 × 24 viewBox, stroke width 1.6, round caps and joins, ink `#dfe3ea`, accents `#22b8cc` and `#d14fc0`. Draw them yourself. Compare each at 96 and 24 px with the house icons, and from memory against the other app's; redraw any that echo it.

| File | Pictogram (our own) |
|---|---|
| `joint_rigid.svg` | two overlapping squares crossed by one bold bar (accent) |
| `joint_revolute.svg` | a disc with a centre dot and a three-quarter arc arrow (accent) around it |
| `joint_slider.svg` | two parallel rails with a block between them and a double-headed accent arrow along the rails |
| `joint_cylindrical.svg` | an upright rod through a ring, an accent arc around the ring and an accent arrow along the rod |
| `joint_pin_slot.svg` | a long rounded slot outline with a dot inside and a small accent arc around the dot |
| `joint_planar.svg` | a slanted plate with a puck on it and two accent arrows lying in the plate |
| `joint_ball.svg` | a ball resting in an open cup with two short accent arcs |
| `ground.svg` | a block standing on a base line with three slanted ticks |
| `unground.svg` | the same block lifted off the base line with an accent up arrow |
| `contact_set.svg` | two blocks meeting at one corner with three short accent spark lines at the meeting point |

Play, Pause and Loop in the Motion Study panel use the editor's own icons (`get_theme_icon("Play", "EditorIcons")` and so on, guarded by `Engine.is_editor_hint()`; plain text buttons headless). The 9 existing Assemble icons (`joint`, `as-built_joint`, `joint_origin`, `rigid_group`, `drive_joints`, `motion_link`, `enable_contact_sets`, `motion_study`, `new_component`) are re-checked under 0.3.

---

## 7. Licensing

- No new third-party code. Contact uses Manifold 3.5.4 (Apache-2.0), already linked and listed since Phase 7. The joint and bake code uses only Godot (MIT) classes.
- Nothing changes in the third-party notices. A team that wants to add a library stops and reports first.
- Icons and sentences are original (0.3).

---

## 8. Risks, decisions and open questions

### 8.1 Risks and decisions

1. **The user's editor holds the DLL.** The user's editor (PID 32448) is open and loads `A\bin`'s DLL, so N's POST_BUILD copy will fail while it runs. N compiles, runs its native test only if the copy succeeded, and otherwise reports "built, not installed"; the orchestrator arranges the install with the user. Nobody kills the editor.
2. **Godot joint facts are partly unverified** (C8.1 V1-V8). K runs them first; if one differs, K changes only `R_map` or the limit mapping and reports it; the C8.5 table is then corrected in section 10.
3. **Float32 at the edges.** Holder and bake transforms are float32 (about 1e-7 relative); the core stays in doubles, and stored data never passes through float32.
4. **Contact is approximate by design** (C5.3): contact closer than `tol_eff` is not seen, compact pokes are seen only a few `tol_eff` deep, and thin bodies can pass between steps. Each case is warned (`S-CONTACT-DEV`, `S-CONTACT-THIN`) rather than hidden. Decision: stop at the last clear value, never at an overlapping one.
5. **Contact cost on large meshes.** Estimated and refused up front (`S-CONTACT-TOO-SLOW`); one deadline per drive; the Manifold cache counts against the mesh cache cap.
6. **Snap refs after model edits.** Refs re-resolve like feature picks; when they cannot, the stored frame is used with `S-SNAP-LOST` (never a silent jump).
7. **Loops are measured, not solved.** Decision (1.2 #3). A later phase may add an iterative solver; the schema already stores everything it would need.
8. **Posed CAD export** changes what an export writes only when the assembly is not empty (Q6 below).
9. **Convex collision** for moving bodies: concave bodies collide as their hulls, warned (`S-BAKE-HULL`). Convex decomposition is out of scope.
10. **Half-limited joints** have no exact Godot form; baked with the open end at a bound and warned (`S-BAKE-HALF-LIMIT`).
11. **Ball to ConeTwist** (as the plan says): Godot's cone is symmetric, so asymmetric limits are widened and warned (`S-BAKE-CONE-WIDENED`). Decision: keep ConeTwist, not Generic6DOF, for Ball.
12. **The editor reopens the user's last scenes** in every hook run; the hook guard and the save rule in 0.4 protect them.
13. **Driving with contact while dragging** gets a 0.1 s deadline per drag event; on large sets the drag may hold early with `S-CONTACT-TIMEOUT`. Typing a value uses the full budget.
14. **Decisions made by this spec**: the assembly is document data, not a feature (C1); joints connect top-level units (C2.1); tree solve from the ground (C3); contact by `CadMesh.overlap` thickness (C5); bake default Node3D with RigidBody3D opt-in (C8.2); posed CAD export (C8.6).

### 8.2 Open questions for the user (do not block on them; the defaults apply until the user answers)

1. **Closed loops** (a four-bar linkage): measured and warned but not solved? **Default: yes, warn with the residual; no loop solving in Phase 8.**
2. **Joints between nested components**: should a nested component be able to move inside its parent? **Default: no; joints connect top-level components, nested ones move with their top-level component.**
3. **Pose while modelling**: while a sketch, feature, Form or Direct Edit is open, show the bodies where they were modelled? **Default: yes, modelled positions with a status note.**
4. **Bake**: keep plain `Node3D` components as the default and make `RigidBody3D` + joints an opt-in per part? **Default: yes; joints are baked only in RigidBody3D mode.**
5. **Contact defaults**: tolerance 0.01 mm, step 1 mm, precision 0.001 mm, B-rep contact meshes at the High tessellation preset? **Default: yes.**
6. **CAD exports** (STEP, STL, OBJ, 3MF) of a posed assembly: write bodies where the assembly places them, or where they were modelled? **Default: where the assembly places them, with a note in the export report.**

---

## 9. Report back (every team, end of stage)

Subagents cannot write report files; the report is your final message to the orchestrator. It holds:
1. Files created and changed, and the backup folder used (0.5 #10).
2. Tests and hooks run, with their PASS/FAIL lines quoted, which ran under load, and the `ERROR:`/`SCRIPT ERROR` grep result.
3. **As-built differences** from the contracts, by contract id (C1-C10), with the reason; changed or new sentences with their ids.
4. Measured timings: milliseconds, ratio, the limit set, and any C9 target missed with its split.
5. Verify items answered (K: V1-V8 with the observed facts; A/V: the 5.1 #4 text round trip).
6. What is not done or not verified, and items for the verifier.
7. A confirmation that no Godot process you did not start was stopped, no user scene or resource was touched, the build lock is gone, and (hooks) the hook guard was clean.

The orchestrator folds accepted differences into section 10; it overrides the body where they differ.

---

## 10. Addendum (binding; written by the orchestrator after each stage)

### 10.0 Orchestrator decisions before Stage 0 (2026-11-13)

1. **The user said "Start Phase 8" without answering 8.2**, so the 8.2 defaults apply. They will be raised again at the check-in.
2. **Risk 8.1 #1 is wrong; it is replaced by this.** Godot loads a copy of the GDExtension DLL (`bin\~holo_forge_native.dll`), so the DLL in `A\bin` can be replaced while the user's editor (PID 32448) is open. Phase 7's teams installed new DLLs dozens of times that way.
   - What really blocks the copy is a headless test or hook Godot process holding the DLL. Retry the copy under `build.lock` until it goes through, as N1 did in Phase 7.
   - N installs and tests its build like any Phase 7 native team. "Built, not installed" is not an acceptable end state.
3. **Several Phase 7 lessons apply here too:**
   - Never edit another team's native files in place while a build may run; edit a WIP copy and swap it in under `build.lock`.
   - After a build that overlapped your save, recompile your files.
   - `CadMesh.check()` clears `get_last_warning()`, so read the warning first.
   - Timing failures under load must be rerun alone before being reported as real.
   - Windowed hooks set `mouse_passthrough` (see `holo_forge_mesh_editor_test.gd`), because the user's real mouse can steal focus.

### 10.1 After Stage 0 (team A, 2026-11-13; accepted)

1. **Snapshot keys.** `snapshot()` carries `"assembly"` only when it is not empty; `restore()` reads a missing key as `{}`.
2. **Exact doubles.** Godot's text save does not round-trip every double: float32-exact values, `-0.0` and subnormals come back changed.
   - The exact values live in `doc.assembly_exact`, an `@export_storage String` declared after `assembly`. Its getter is computed from `assembly`; its setter re-applies the values on load when they match within text rounding.
   - No save hook is involved. An empty assembly writes neither key.
3. **Tolerances.** xform64 tolerances are relative to the translation (5.1 #7): an absolute 1e-15 m is impossible at 10 m.
4. **Newer-version guard.** `change()` in `forge_workspace.gd` refuses edits to a newer-version assembly (`S-NEWER-ASSEMBLY`). Tools call `ASSEMBLY_DATA.edit_refusal()`.
5. **Solver output (C3.1 as built):**
   - `units` lists top-level components only; `root` is `""` for a fixed unit.
   - A nested component's `transforms` entry is local to its parent.
   - `body_poses` covers split bodies via their source body's component.
   - The new sentence `S-PLACEMENT-BAD` covers a placement that is not rigid.
   - The internal note `STAGE0_NOT_SOLVED` must be deleted by A in Stage 1.
6. **Extras in `assembly_data.gd`:** `DOF_NAMES`, `TYPES`, `KIND_NAMES`/`name_for`, `retype_dofs`, `is_newer`, `edit_refusal`, `placement`, `is_grounded`, `is_rotation`, `exact_text`/`apply_exact`, and the `SENTENCES` id map.
7. **Assigned follow-ups:**
   - **V (Stage 1):** call `_refresh_assembly()` at the end of `recompute()` so poses are not stale after a model change.
   - **T (Stage 2):** `_with_view_change` must merge `ASSEMBLY_KEYS` too, or an assembly-only change made under an open restore-on-Cancel command is dropped on Cancel; show `S-NEWER-ASSEMBLY` on document load too.

### 10.2 After Stage 1 (teams A, N and V, 2026-11-13; accepted)

**Team A: the solver core**
1. **C3.1 output additions:** `joints[id].lost`, `joints[id].implied` (loop joints), and `out.split` (the C9 split). `frame_a`/`frame_b` are resolved snap frames in each snap body's modelled coordinates; `world = P_b·F_b·O`.
2. **The meaning of `units[c].fixed`:** true for any unit hanging from the ground or a grounded unit. Read `assembly.grounded` for "grounded" itself.
3. **Memo.** `solve()` memoizes its last inputs by content, with the result compared by identity. Code must never mutate a result's bodies in place.
4. **Joint rules:**
   - A joint with both sides in one unit is a loop: measured, not enforced.
   - A rigid group closing a loop is ignored.
   - Waiting means a side component created at or after `active_count`.
5. **Snaps:**
   - Snap points are float32-exact only, because native `face_info`/`edge_info` return Vector3; frames are doubles from there.
   - New snap kind `fixed` (as-built sides).
   - New optional snap keys `face` and `at_pick`.
   - A ref resolved only by repair counts as lost.
6. **Sentences:**
   - New: `S-LINK-SELF`.
   - Times are written "2 s", angles "90°".
   - Link limits: `S-LIMIT` when the driven DOF binds, `S-LINK-LIMIT` when another DOF in the chain binds.
7. **Motion study:** `frame_count = ceil(length·fps − 1e-9) + 1`.

**Team N: `CadMesh.overlap`** (`mesh_contact.cpp`; C9 targets met)
1. Call order: options and placement checks, then closed-body refusals (before the box early-out), then the box test, then cached Manifolds, then the intersection under one deadline, then the post-checks.
2. **A timeout returns `timed_out: true` with `overlap false`. `contact.gd` MUST check `timed_out` first.**
3. **Extra keys:** `built`, `refused` ("this"/"other"), `warning`, `step` (float32 step at the place), `estimate`. Option `estimate_only`. `time_limit` defaults to 1.0 and is clamped to 0.05-120.
4. **Far from the origin:** a warning (Phase 7's `rounding_note`), not a refusal. `contact.gd` compares `step` with `tol_eff`.
5. **Rates** (`mesh_budget.h` N8): 300 µs per call, 0.5 µs per triangle cached, 1.4 µs per triangle to build. `contact.gd` copies these or asks `estimate_only`.
6. **Cache memory:** the Manifold cache's memory (about 4.6 MB for a 20k mesh) counts against the mesh cache cap only when an entry is stored again. A decides whether `contact.gd` re-reads `memory_bytes()`.

**Team V: view and browser**
1. **Followers.** Analyses, decals, section caps and highlights are follower nodes (meta `follow_body`/`follow_local`) that the viewport moves with the body's pose. Section planes get a per-body material copy.
   - Analysis entries follow only with a `"body"` key: **A adds it in `analysis.gd` (Stage 2, C7.4).**
   - 5.4 #4 reads "their global transforms follow the pose".
2. **Glyphs and the modelled view:**
   - The glyph layer is a 2D Control (`AssemblyGlyphs`) drawn through `set_glyph_drawer`.
   - The modelled-view switch is a workspace `_process` poll, plus calls in `start_command`, `_end_command`, `edit_feature` and `_refresh_assembly`.
3. **Picks:** face picks carry `world_point` and `world_normal`; edge, vertex and region picks carry `world_point`.
4. **Ground button:** `forge_workspace._toggle_ground` does the full ground/unground. **T's 3.2 menu item reuses it.**
5. **Browser:** new signals `component_ground_toggled`, `joint_clicked`, `joint_edit_requested`, `assembly_visibility_toggled`.
6. **Left for T:** "Selecting a joint highlights both units".
7. **For the verifier:** the glyphs and DOF handles are tested as data only and need a windowed check.

### 10.3 After Stage 2 (teams A and K, 2026-11-13; accepted; T pending)

**Team A: contact** (5.6, 15 cases; Phase 7 inspect bytes are unchanged for unposed bodies)
1. **Contact meshes.** `contact_mesh(doc, result, body_id)` returns `{mesh, dev, error}`. B-rep contact meshes are cached by shape instance (64 entries).
2. **Sweep:**
   - The sweep samples 8-64 coarse points, then places steps evenly on max(arc travel / step, turn / 5°).
   - Its estimate uses N's rates plus one `path()` cost.
   - A pair that `overlap` refuses mid-sweep counts as clear.
   - New sentence `S_CONTACT_FAR`.
   - Re-storing to count the Manifold cache memory: not done (documented).
3. **`drive()` and the study:**
   - `drive()` keeps its signature. Options: `contact`, `deadline_seconds` (drags pass 0.1). Result keys: `contact`, `warnings`, `refused`.
   - The study sweeps first under the shared deadline.
4. **Posed inspect:**
   - `measure` takes `ctx.poses`.
   - `interference(..., time_limit, poses)` and both `mass_properties` take `poses`.
   - Mass on posed bodies moves the modelled result exactly (centre by the pose, I → R·I·Rᵀ).
   - Analysis entries carry `"body"`.
5. **Rate gap (for the verifier and N):** `overlap` on a pin turning in a tight hole takes about 4.3 ms per call, against about 0.7 ms predicted. Contact estimates for overlapping round parts run about 6× low; the deadline still bounds them.

**Team K: bake and export** (5.7, V1-V8 plus 12 cases; the project already uses Jolt)
1. **Godot 4.7.1 facts (V1-V8)** replace C8.1's "verify" marks:
   - V1: the hinge axis is the joint node's local Z.
   - V2: hinge limits are radians from the setup pose, with the **opposite sign**: positive means node_b turning about −Z relative to node_a.
   - V3: the slider moves along local X; linear limits are not inverted.
   - V4: ConeTwist twists about X and swings about Y/Z, with symmetric half-angles only.
   - V5: 6DOF angular limits are inverted like the hinge's; 6DOF linear limits are not.
   - V6: a ConcavePolygonShape3D on a moving RigidBody3D works under Jolt.
   - V7: `create_convex_shape(true, false)` works.
   - V8: physics steps in `--headless --script` runs.
2. **Limit mapping.** Hinge and 6DOF angular: lower = v_b − max, upper = v_b − min. The joint transform is W·T(t(v_b))·R_map.
3. **Exports on `CadPart`:**
   - `component_node_type` (0 Node3D, 1 RigidBody3D);
   - `bake_joints` (default true);
   - `bake_pose` (0 Current, 1 Rest).
4. **Baking details:**
   - Rigid groups bake as locked Generic6DOF joints.
   - In rigid mode, ground bodies always get trimesh collision under a "Ground" StaticBody3D.
   - A zero mass becomes 1 kg, with a note.
5. **New sentences** (in `bake_joints.gd`/`cad_part.gd`): `S-BAKE-LOOP-OFF`, `S-BAKE-SKIPPED`, `S-BAKE-READBACK`, `S-BAKE-GROUND-MOVES`, `S-BAKE-NO-MASS`, `S-BAKE-NO-HULL`.
6. **New API:** `part.bake_assembly(result)` and `solve_for_bake(result)`. **T calls `bake_assembly` from `_refresh_assembly`.**
7. **Posed export.** It skips near-identity poses; .glb/.gltf exports leave out the Joints node. Unposed export bytes equal Phase 7's, apart from the STEP session counter.
8. **Known:** a Jolt hinge swinging into its −30° limit overshoots to −41.5° and settles at −30.8° (case 8).


### 10.4 After Stage 3 and fix rounds 1-2 (all teams, 2026-11-13)
**Stage 3 (T and A):** 5.8 passes. Contact is wired into Play Motion, Drive and the Motion Study panel. The 11th hook, `--holo-forge-assemble-editor-test`, passes headless and windowed, and wrote 20 screenshots to `screenshots/phase8/`. Verifier 1 (`scratchpad phase8\verify1\FINDINGS.md`) and verifier 2 (`verify2\FINDINGS2.md`) drove two fix rounds. These items are now binding:

1. **Double-precision moves (N).**
   - `CadKernel.transform_shape64(shape, m: PackedFloat64Array, tag := "move")` and `CadMesh.transformed64(m)`.
   - The layout of `m` is xform64's: basis columns X, Y and Z, then the origin, in metres.
   - Only rigid moves are allowed. On failure the result is null and `get_last_error()` holds the sentence.
   - Posed export (K), posed inspect, measure and the mass centre (A, including `INSPECT.center64()` and `point64`/`at64`) all use them. A float32 `Transform3D` must not be used for any posed result.
2. **Overlap on self-crossing meshes (N).**
   - Every `CadMesh.overlap` result has `self_crossing`. When it is true there is no number, and the sentence names the mesh and the repair (Mesh > Repair > Rebuild).
   - The one-time crossing test makes the first call on 2×20k meshes take 81-116 ms, against the C9 target of 90 ms. This is accepted as a C9 change, because the alternative is a silently wrong overlap.
   - The sweep stops at the last pose it checked clear and says S-CONTACT-UNCHECKED.
3. **Contact sampling replaces C5.4/C5.5's coarse rule.** COARSE_TURN is removed.
   - Each sweep is sampled at marks: v0, an even grid, 7 golden-ratio points, `split_times` and v1.
   - Every mark interval is cut so that no unit turns more than 5° between samples. The turn comes from the `turn_between: Callable(a, b)` option, or from `turn`, and goes through Motion Links.
   - A pair counts as still only after checking the marks and each interval's first cut.
   - More than 2,000 points is refused up front: S-CONTACT-STEPS when travel sets the count, S-CONTACT-TURNS when turning does.
   - Only rotation DOFs that change some contact pair's relative pose count (`motion._turning()`, nudged both ways so a DOF at a limit still counts). `MOTION.turn_rate(doc, result, kernel, joint_id, dof, assembly := {})` gives that turn per unit of a played DOF, through its link root, for Play.
   - The first look is built under the sweep's deadline (`seconds`, `deadline_usec`). It stops at the first movement when it will be refused anyway, and runs out of time with S-CONTACT-TOO-SLOW. When the look's own estimate fits the caller's whole contact time (`limit_seconds`, else `seconds`), the deadline is the reason, so the refusal is S-CONTACT-TIME-USED instead (fix round 4): "Contact checking had used up its <budget> before this motion could be checked." Its `estimate` and `estimate_again` stay in the result. Track values and turns are found by bisection, so studies with thousands of keys end within their limit.
   - Studies pass their key times. Play Motion sweeps leg by leg between key times under one deadline, and a refused leg refuses the play.
4. **Thinness replaces C5.4 #4, which judged thinness from the bounding box.** `contact.local_thickness()` casts rays from triangle centroids, up to 20,000 per mesh. S-CONTACT-THIN gives the thinnest width found; S-CONTACT-THIN-AVERAGE is only a fallback.
   - A mesh with more than 20,000 triangles gets rays in every connected piece and face group first (at least 4 each when there are not too many), then the rest by area.
   - When such a mesh is found not thin, the sweep warns S-CONTACT-THIN-SAMPLED: how many triangles were looked at (`contact.thickness_coverage()`).
5. **Refusals change C4.1.** A refused drive returns `refused: true` with the sentence and `reached` equal to the stored value, and nothing moves. When that stored value is not finite, `reached` is 0 and `values` has no entry for the joint (the sentence names the value). These cases are refused:
   - a suppressed or waiting joint, or a missing component;
   - an empty link interval (S-LINK-EMPTY);
   - reversed limits;
   - any non-finite target, stored value, limit, ratio, offset or contact setting.

   `MOTION.limits_refusal`, `link_refusal` and `study_refusal` check before a value is stored. The panels show the refusals, and the tools' `assemble_finite.gd` names the bad value.
6. **Solver warnings.** These are now warned:
   - rigid-group loops (S-GROUP-LOOP-HOLDS/OFF);
   - snap bodies moved to another component (S-SNAP-MOVED, the joint is lost);
   - suppressed picks (S-SNAP-SUPPRESSED);
   - far snaps (S-SNAP-FAR), when the float32 step 2^(floor(log2 d)−23) is above `contact.tolerance`;
   - clamped stored values (S-VALUE-CLAMPED).
7. **Exact text format 3:** `"3:" + 16-hex sha256 + ":" + base64(var_to_bytes({path: value}))`.
   - Format 1 is still read.
   - Format 2 is not read: it existed only during the fix rounds and has no digest. Its numbers stay at text precision with S-EXACT-UNREADABLE ("a kind ... it no longer reads"), and nothing is decoded, so no engine errors are printed.
   - Hand edits are kept per value. The notes are S-EXACT-EDITED, S-EXACT-UNREADABLE, S-EXACT-OLD and S-EXACT-UNMATCHED.
   - Study keys are matched by joint, DOF and time; renamed entries are matched by content.
   - Duplicate-time study keys are refused (S-STUDY-KEY-TWICE).
8. **Bake inertia (K).**
   - The RigidBody3D bake sets `inertia` from mass properties: the diagonal, taken about the unit's centre of mass.
   - Dropped products of inertia warn S_BAKE_INERTIA_PRODUCTS.
   - Jolt holds no inertia below 1e-6 kg·m² (this is the length of the moment vector), so smaller units are raised to that floor with S_BAKE_INERTIA_FLOOR. This is an accepted engine limit.
   - A read-back after 2 frames warns S_BAKE_INERTIA on a mismatch over 10%.
9. **Play Motion (T).**
   - Tracks start and end at the current value: [value, max, min, value].
   - Followers move through `MOTION.move()` link solves.
   - A slide → rotation link counts its turn.
10. **Known, not fixed here:**
    - Primitive placement options (for example Box "position") are float32 `Vector3`s, so a body built far out is off by about 8 mm at 100 km. This comes from before Phase 8 and is raised at the check-in.
    - STEP writes 13 significant digits, about 5e-5 mm at 100 km.
