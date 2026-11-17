# Holo Forge Phase 6: the Form workspace (subdivision freeform modelling)

Work order for executing AI agents. You get only this document, the approved plan (`C:\Users\Blaze\.claude\plans\can-we-create-a-idempotent-shannon.md`) and the code. Everything you must agree on with the other teams is written as a **contract** (marked C1 to C9). Do not change a contract on your own. If you find one that cannot work, stop and report it with a concrete counter-proposal.

Written 2026-10-29 from three research reports: the other app's Form behaviour, an OpenSubdiv prototype with measured numbers, and an integration audit of the Holo Forge code.

---

## 0. Ground rules (read first)

### 0.1 Paths and names (the plan's names are out of date)

The plan says `holo_cad`, a "CAD" tab and `holo_cad_form_test`. The real code uses these names instead:

| What | Path / name |
|---|---|
| Addon root (**A**) | `D:\Hover_Board_Racing\Godot_Board_Racing\godot-board-racing\addons\holo_forge` (main-screen tab "Forge") |
| Native root (**N**) | `D:\Hover_Board_Racing\Godot_Board_Racing\holo_forge_native` (CMakeLists.txt, vcpkg.json, build.ps1, src/) |
| Tests | `D:\Hover_Board_Racing\Godot_Board_Racing\godot-board-racing\tests\holo_forge_*_test.gd` |
| vcpkg packages | `C:\Users\Blaze\holo_forge_build\vcpkg_installed\x64-windows-release` (OpenSubdiv 3.5.0 static `OpenSubdiv::osdCPU_static`, Eigen3, OCCT 8.0.1; pmp 2.0.1 is installed but will **not** be linked) |
| Godot | `D:\Hover_Board_Racing\Godot_Board_Racing\Godot_v4.7.1-stable_win64.exe\Godot_v4.7.1-stable_win64_console.exe` |
| New native class | `CadSubD` (files `N\src\cad_subd.h`, `N\src\cad_subd.cpp`, optional `N\src\subd_convert.cpp/.h`) |
| New headless acceptance test | `tests/holo_forge_form_test.gd` |
| New editor hook | `--holo-forge-form-editor-test`, running `tests/holo_forge_form_editor_test.gd` |

Line numbers below come from the 2026-10-29 audit and can drift. Find code by **function name** and treat a line number only as a hint. One known example: `core/regen.gd` is 72 lines long, `HANDLERS` is at about :22 and `rebuild()` at about :46.

### 0.2 Code rules (existing conventions, mandatory)

- **Class cache.** Every addon script starts with `@tool` and has **no** `class_name`. Other scripts are reached only through `const X := preload("res://addons/holo_forge/...")`. Native classes are reached only through `ClassDB.class_exists("CadSubD")` and `ClassDB.instantiate("CadSubD")`, held in variables typed `RefCounted` (pattern: `core/regen.gd make_kernel()`). Never write `CadSubD.new()` or `: CadSubD`. Scripts must still parse when the DLL is absent.
- **Editor-only calls.** Guard every `EditorInterface` call with `Engine.is_editor_hint()`. The headless workspace test builds `WORKSPACE.new()` without an editor.
- **Packed arrays inside Dictionaries are values.** After you change a Packed array you read from a Dictionary, write it back: `var p: PackedFloat64Array = cage.positions; p[0] = 1.0; cage.positions = p`.
- **Edge identity.** An edge is the unordered vertex pair `(min, max)`, never an edge index. Edge indices are only valid for one `Topo` build.
- **Units.** Cage positions are in **meters**, in the part's space, like every kernel value. Panel fields show document units through the existing expression fields.

### 0.3 Originality and branding

- Behaviour may match the other app. Never copy its text, icons, art or help wording.
- In anything that goes into the project (code, comments, UI strings, tests, docs, commit messages), refer to it only as "the other app". Strip any URL that contains its brand name.
- Don't use its proprietary surface technology's name in UI strings. Say "smooth surface", "cage" or "subdivision". This document names that technology only to explain the differences.
- The one exception is the OpenSubdiv NOTICE in `A/licenses/`. It lists that project's contributors, among them the other app's maker, and is a legal attribution required by the licence. Keep it verbatim, and only there.
- Option names in this spec ("Reduced Star", "Exact", "Soft Modification") describe behaviour. They are short CAD vocabulary, which is fine as UI labels. Write every tooltip, hint and flash text yourself; never paste help text.
- Toolbar icons are the existing original Holo-style SVGs at `A/icons/tools/<slug>.svg`. The one new icon needed is `A/icons/tools/form/finish_form.svg`. Model it on `A/icons/tools/sketch/finish_sketch.svg`: a 24x24 viewBox, 1.6 stroke, round caps. Draw a small dashed rounded-cage outline in `#dfe3ea` at 0.7 opacity with the green check `#3fb26a`. The Form accent colour used by the existing Form icons is `#22b8cc`.

### 0.4 Machine rules

- **Disk.** Build trees live on C: (`C:\Users\Blaze\holo_forge_build`). Never put build output on D:.
- **DLL lock.** The GDExtension is `reloadable=false`. **Close every Godot instance before `build.ps1`.** Otherwise the copy fails and leaves `~holo_forge_native.dll~RF*.TMP` files in `A/bin`. Delete those leftovers when you see them.
- **Build:** `powershell -NoProfile -ExecutionPolicy Bypass -File D:\Hover_Board_Racing\Godot_Board_Racing\holo_forge_native\build.ps1`
- **Headless test:** `& $godot --headless --path D:\Hover_Board_Racing\Godot_Board_Racing\godot-board-racing --script res://tests/<name>.gd`
- **Editor hook:** `& $godot --headless --path <project> --editor -- --holo-forge-form-editor-test`
- **Runner scripts.** Scratchpad copies are in `C:\Users\Blaze\AppData\Local\Temp\claude\D--Hover-Board-Racing\201f9237-6a81-4e60-8b92-09865c66cf8d\scratchpad\run_headless.ps1` and `run_editor.ps1`. Add `holo_forge_form_editor_test` to `$editorOnly` and `--holo-forge-form-editor-test` to the hook list.
- **Scenes.** Don't modify the user's scenes. Check the Godot title bar for `*` before any scene write. New test scenes go under `tests/holo_forge/`.
- **Regression.** `tests/validate_project.gd` must show no violations beyond the 6 known Movement Lab ones.
- **Run commands yourself.** Run builds, tests and exports yourself. Never hand the user commands to run.
- **Plugin reloads.** After editing plugin scripts, restart the editor or toggle the plugin so `_enter_tree` runs again.

### 0.5 Reference prototype (may disappear)

The C++ prototype is in `C:\Users\Blaze\AppData\Local\Temp\claude\D--Hover-Board-Racing\201f9237-6a81-4e60-8b92-09865c66cf8d\scratchpad\phase6\proto`: `proto.cpp`, `convert.inc`, `shell.inc`, `project.inc`, `stress.inc`, `CMakeLists.txt` and the `out_*.txt` results. It measured every number quoted here.

The scratchpad is temporary, so team N should copy `proto.cpp`, `convert.inc`, `shell.inc` and `project.inc` into `N\research\phase6_proto\` (not compiled; CMake globs only `src/*.cpp`) before starting. The algorithms you need are also restated in section 2.4, in enough detail to work without the prototype.

---

## 1. Target behaviour (our own words) and deliberate differences

### 1.1 What the user gets

**Entering and leaving.** The **Form** environment is a contextual mode of the Forge tab for sculpting smooth freeform bodies by pushing and pulling a coarse control cage.
- The user clicks **Create Form** in the Solid Create group. One timeline feature, `Form1`, appears at the timeline marker, and the toolbar switches to the Form tools (the switcher shows "Form" and is locked).
- While the form is open, features after it are temporarily skipped. The rest of the model stays visible.
- **FINISH FORM** (toolbar block at the far right, plus a button on a small floating palette) converts every body in the form into exact BRep geometry: B-spline faces, a solid when closed, a surface body when open. It then rebuilds the rest of the timeline and returns to the user's workspace.
- Double-clicking the Form feature in the timeline (or Edit in its context menu) opens it again.

**Bodies.** One Form feature can hold several bodies. Each body is a **cage**: a polygon mesh of mostly quads, plus triangles and n-gons, with optional creases.
- The smooth surface shown and converted is the **Catmull-Clark limit surface** of the cage.
- Creased edges stay sharp. Open boundaries stay sharp and interpolate their boundary curve.

**Display.** Each body has its own display mode:
- **Box**: only the cage, flat-shaded.
- **Control Frame**: the smooth surface plus the cage wireframe and points.
- **Smooth**: only the smooth surface, with the cage edges drawn as curves on it.

Alt+1, Alt+2 and Alt+3 switch the mode of the selected bodies (of all form bodies when nothing is selected).

**Selection and editing.**
- The user selects cage vertices, edges, faces or whole bodies, honouring the toolbar's selection filters, priority and window/freeform/paint mode.
- Helpers: loop, ring, grow, shrink, range, invert and feature selection, with keyboard shortcuts and double-click rules.
- **Edit Form** shows a combined move/rotate/scale gizmo at the selection.
  - **Soft modification** drags nearby vertices with a falloff.
  - **Alt-drag** extrudes faces or extends open boundary edges. **Alt+Ctrl-drag** does the same and keeps creases.
  - Typed values apply exact transforms.
- Every other Modify, Symmetry and Utilities tool is a one-shot edit with a panel: inputs, options and a live preview. **OK** applies it as one undo step.

**Symmetry.**
- Mirror and circular symmetry can be stored inside a body ("internal"), or made by duplicating a body across a plane or around an axis ("duplicate").
- Every later edit, both moves and topology changes, is mirrored exactly.
- Isolate excludes chosen elements from symmetry. Clear removes all symmetry from a body.

### 1.2 Deliberate differences from the other app (keep them; tests rely on them)

| Topic | The other app | Holo Forge Form |
|---|---|---|
| Surface type | T-splines (T-points, star points, knot intervals) | Catmull-Clark subdivision (OpenSubdiv 3.5) |
| T-points | Local inserts end in T-points | A "Simple" insert that ends inside the cage puts the new vertex into the neighbouring face, which becomes an n-gon |
| "Exact" inserts | Shape preserved exactly | **Exact** = Simple + local least-squares refit of the limit surface (approximate, max deviation reported). One exception: subdividing **every** face of a component 2x2 with Exact is one Catmull-Clark step, which is exact |
| Crease | Binary | Binary in the UI. Stored as an OpenSubdiv sharpness (10.0 = infinitely sharp), so semi-sharp weights could be added later. Vertex creases (sharp corners) are allowed on **any** vertex, not only outside corners |
| Tangent handles at creases and boundary ends | Exist | Not provided (Catmull-Clark has no equivalent). Users move the next ring of vertices instead |
| Undo granularity in Edit Form | Not documented | **Every drag release is one undo step.** Every other tool's OK is one step |
| Display mode | Per body, not part of history | Per body, saved in the form feature, recorded as a **view-only** undo step (no rebuild) |
| Convert output faces | Split at star points | One BRep face per cage quad and **n faces per n-gon** (OpenSubdiv's sub-faces). Each face is one B-spline surface, exact to the limit at the chosen isolation level |
| Freeze | Frozen elements plus a darker buffer | Same idea. The buffer is exactly the vertices whose motion would change the frozen surface (the 1-ring of the frozen vertices) |
| Match | Optional associative link | Associative links are stored in the cage and replayed during rebuilds (targets must come from features **before** the form) |
| Thicken on a closed body | Separate offset surface | Separate offset body (a second connected component, converted to its own body) |
| Pipe | Branching networks | Chains of connected curves. Branches (3 or more path ends meeting) are refused with a clear message in this phase |
| BRep face to cage | Any face (quad remesh) | Four-sided faces only in this phase (exact grid fit). General faces need a quad remesher, which is deferred |
| Display quality toggle | "Better performance" / "better display" | A palette **Display quality** choice: Draft (rate halved, approx level 2) / Fine (default) |
| Edit Face, direct-mode Convert, TSM import/export | Present | Not in scope |
| Gizmo pivot | Not movable | Not movable (pivot = selection centroid) |

---

## 2. Architecture and contracts

### 2.1 Overview

```
Solid toolbar "Create Form" --> workspace.create_form() --> change("Create Form"): doc.add_feature("form", "Form", {}, FORM.new_options())
                                                         --> form_editor.begin(feature)

form_editor (ui/form_editor.gd)  owns: selection, picking, CadSubD instances per body, display meshes, gizmo, tool engine
   |-- reads/writes cages in  feature.options.bodies[body_id]   (C1, C2)
   |-- pure topology:   core/form/cage.gd       (C4)  -- Topo half-edge adjacency, low-level topology ops
   |-- pure tools:      core/form/form_ops.gd   (C5)  -- every Modify/Symmetry/Utility tool as cage -> cage
   |-- primitives:      core/form/primitives.gd (C5)
   |-- sketch creates:  core/form/form_create.gd (Stage 3)
   |-- native fits:     core/form/form_fit.gd   (Stage 3; Pull/Match/Interpolate/Exact/Convert via CadSubD)
   |-- tool registry:   ui/form_tools.gd        (C7)
   |-- gizmo:           ui/form_gizmo.gd
   |-- display meshes:  ui/form_display.gd  --> viewport.set_form_meshes()  (C8)
   `-- native:          CadSubD (N/src/cad_subd.*) (C3) -- limit tessellation, eval, ray hit, closest point, interpolate/fit, BRep conversion

regen (core/regen.gd) --> HANDLERS["form"] = core/features/form.gd (C2)
   preview mode (form open):  no conversion, timeline stops after the open form
   normal mode:               CadSubD.to_shapes() per body (LRU cache by cage content), bodies into ctx.bodies
```

### 2.2 C1: the cage (one body's data, stored in the document)

A cage is a plain `Dictionary` (no Objects, so it serializes inside the embedded `CadDocument` resource).

```gdscript
{
  "version": 1,
  # Vertex positions in meters, xyz interleaved, doubles: vertex v is (p[3v], p[3v+1], p[3v+2]).
  "positions": PackedFloat64Array,
  # Faces: face f has face_counts[f] vertices (>= 3), listed counter-clockwise when seen from
  # outside (right-hand normal points out), stored consecutively in face_indices.
  "face_counts": PackedInt32Array,
  "face_indices": PackedInt32Array,
  # Creased edges: pairs (a, b) with a < b, sorted ascending by (a, b); one weight per pair.
  # The UI writes 10.0 (OpenSubdiv SHARPNESS_INFINITE) for "creased"; 0 never stored (remove pair).
  "crease_edges": PackedInt32Array,      # size 2*k
  "crease_weights": PackedFloat32Array,  # size k
  # Sharp vertices (vertex crease): sorted vertex ids, one weight each (10.0).
  "corners": PackedInt32Array,
  "corner_weights": PackedFloat32Array,
  # Frozen vertices (sorted, unique). See "Locked set" below.
  "frozen": PackedInt32Array,
  # Symmetry entries, applied in order (see below). Empty array = no symmetry.
  "symmetry": [ <entry>, ... ],
  # Vertices excluded from symmetry (sorted, unique): they neither drive nor follow partners.
  "sym_isolated": PackedInt32Array,
  # Associative Match links (Stage 3; empty until then). See tool "Match".
  "links": [ <link>, ... ],
}
```

**Symmetry entry:**

```gdscript
# Mirror: reflection through the plane (origin, unit normal).
{"type": "mirror", "origin": PackedFloat64Array(3), "normal": PackedFloat64Array(3),
 "map": PackedInt32Array}   # size nV: map[v] = partner vertex, map[v] == v on the plane, -1 = no partner (broken)
# Circular: rotation by +step radians about the axis (origin, unit axis), right-handed.
{"type": "circular", "origin": PackedFloat64Array(3), "axis": PackedFloat64Array(3),
 "count": int,              # copies in a full orbit (>= 2)
 "step": float,             # radians between neighbours; 2*PI/count for full circles
 "open": bool,              # true for a partial arc (Circular - Duplicate with an angle): orbits don't wrap
 "map": PackedInt32Array}   # size nV: map[v] = the vertex v moves to under +step; map[v] == v on the axis; -1 = end of an open orbit or broken
```

Plane and axis data are doubles (`PackedFloat64Array(3)`), so that reflections are exact to about 1e-15 relative.

**Link entry (Stage 3, Match):**

```gdscript
{"edges": PackedInt32Array (vertex pairs along the matched chain, in chain order),
 "target": <reference dict from core/references.gd (edge) or {"kind":"sketch_curve","sketch":id,"curve":id}>,
 "continuity": "g0"|"g1"|"g2", "spacing": "uniform"|"curvature"}
```

**Invariants.** `CAGE.validate(c)` returns a list of violations, and every op must return a cage with none:
- Every index is in range.
- Every face has at least 3 distinct vertices.
- Each edge has 1 or 2 incident faces (manifold).
- The two faces of an edge use it in opposite directions (consistent orientation).
- No vertex is unused. Use `compact()` after deletions.
- Crease pairs are existing edges and are sorted.
- Corner, frozen and sym_isolated lists are sorted and unique.
- Every symmetry map has size nV.

**Positions are doubles.** GDScript `float` is 64-bit, but `Vector3` is 32-bit in this Godot build. So:
- (a) The canonical store is `PackedFloat64Array`.
- (b) Ops may compute moves with `Vector3`, but must write back **only the vertices they change**. Untouched vertices keep their bits.
- (c) Symmetry reflection and rotation, interpolation results and native results are computed and stored in doubles (scalar math in GDScript, double in C++).

**Locked set (derived, never stored).** `locked = frozen ∪ { every vertex of every face incident to a frozen vertex }`. This is exactly the set of vertices that position the limit surface over frozen faces and edges.
- Geometry ops never move a locked vertex.
- Topology ops refuse to delete, split or modify any face that contains a locked vertex. The error text is `"That would change frozen geometry; unfreeze it first."`.
- A face counts as frozen when all its vertices are in `frozen`. An edge counts as frozen when both ends are.

**Per-body display mode** lives in the form feature, not in the cage, so changing it never changes the cage's content hash (see C2).

**Canonical edge order** (used by native tessellation `edge_pairs` and by `Topo`): walk faces in order, and within each face its corners `k = 0..n-1`. For each pair `(face[k], face[(k+1) % n])` the first time the unordered pair is seen, append `(min, max)`. Native and GDScript must produce identical lists. A test compares them.

### 2.3 C2: the "form" feature, timeline, undo, regen, cache, save/load

**Feature.** Type `"form"`, label `"Form<n>"`, `inputs = {}` (Form is direct modelling, not parametric). `core/features/form.gd` provides `static func new_options() -> Dictionary`:

```gdscript
{
  "form_version": 1,
  "bodies": {},        # body_id -> cage (C1); insertion order = creation order
  "display": {},       # body_id -> "box" | "frame" | "smooth"   (missing = "smooth")
  "quality": "standard",  # conversion isolation: "draft" = 4, "standard" = 6, "high" = 8
  "breps": {},         # body_id -> PackedByteArray (to_brep_bytes): bodies converted inside the form with Utilities > Convert (fixed BRep, no cage)
}
```

Each body is registered with `doc.new_body(feature.id)`, so `doc.remove_feature` cleans it up. A body id appears in exactly one of `bodies` or `breps`.

**Timeline.**
- One feature per Create Form session, inserted at the timeline marker (`doc.add_feature`).
- The timeline chip icon is `"form": "SoftBody3D"`, added to the icon map in `ui/timeline.gd`.
- Double-click or the Edit context entry calls `workspace.edit_feature(id)`, which runs `form_editor.begin(feature)` for type `form`.
- While a form is open, **features created by other commands are inserted just before the form feature**: Construct planes and axes, Create Sketch, Insert Mesh. In preview, regen stops after the form, so anything placed after it would not exist yet.
  - Implement this in `forge_workspace.start_command()`, right after the command's `create_feature()`: if `form_editor.active` and the command made a feature, move it with `doc.features.erase(f); doc.features.insert(doc.feature_index(form_id), f)`.
  - `create_sketch()` does the same (Stage 3).

**Undo (one step per edit).**
- Create Form = 1 step (`change("Create Form", ...)`).
- Each form tool's OK = 1 step, `workspace.change("Form: <Tool title>", mutate)`.
- Each Edit Form drag = 1 step `"Form: Edit Form"`. Snapshot on press, mutate the cage positions in place during the drag with no recompute, then `workspace.commit_change("Form: Edit Form", before)` on release. This is the sketch-drag pattern (`sketch_editor.gd` handle_mouse drag code around :1137-1180).
- Typed numeric transforms = 1 step each.
- Display-mode changes = 1 **view-only** step. To make that work, `forge_workspace._model_of()` must ignore `options.display` of form features: for `feature.type == "form"`, use `var o = feature.options.duplicate(); o.erase("display")` (shallow, so it's cheap). Then `commit_change` sees a view-only change, records the step and calls `_refresh_for()` without a rebuild. `_refresh_view_data()` must call `form_editor.refresh_view()` so the meshes update.
- Finish Form makes **no** undo step. It changes no data, only leaves the environment.
- Undo or redo while the environment is open calls `_apply_snapshot`, then `recompute()`, then `form_editor.refresh(result)`. That call must:
  - drop selection indices that no longer exist;
  - rebuild CadSubD for bodies whose cage changed;
  - call `end()` if the form feature no longer exists.

**Regen (`core/regen.gd`).** Change the signature to `static func rebuild(doc, kernel, options := {}) -> Dictionary`. Existing callers keep working.
- Add `"forms": {}` to the result and to `ctx`, and `ctx.form_preview = str(options.get("form_preview", ""))`.
- Register `"form": FORM` in `HANDLERS` (`const FORM := preload("res://addons/holo_forge/core/features/form.gd")`).
- After a handler runs for the feature whose id equals `form_preview`, **break** the loop.

`form.gd build(feature, ctx) -> String`:
1. Write `result.forms[feature.id] = {"preview": bool, "bodies": [cage body ids], "outputs": {body_id: [result body ids]}, "errors": {body_id: text}}`.
2. For every `breps` entry, load a CadShape (`load_brep_bytes`) and set `ctx.bodies[body_id] = {"id", "shape", "feature": feature.id}`.
3. **Preview** (`ctx.form_preview == feature.id`): do nothing else. The cage bodies are drawn by the form editor, not by regen. Return `""`.
4. **Normal:** for each cage body:
   - First take `cage = FORM.effective_cage(stored_cage, ctx)`. This is a `static func` in `form.gd`. E writes it in Stage 2 to return the stored cage unchanged when `links` is empty, and otherwise to call `_apply_links(cage, ctx)` (a stub returning the cage until M2 implements associative Match). The form editor uses the same function before `set_cage` / `set_positions`, so display and conversion always agree. The stored cage is never modified by links.
   - Build `key = str(CAGE.content_hash(cage)) + ":" + quality + ":" + feature.id + ":" + body_id`.
   - On a cache hit, compare the stored cage with `==` and reuse the stored `Array` of CadShapes (**same instances**, so `workspace.recompute` skips re-tessellation through its `is_same` check).
   - On a miss: `ClassDB.instantiate("CadSubD")`, `set_cage(cage)`, then `to_shapes({"isolation": L, "name_prefix": feature.id + "/" + body_id})`.
   - Component 0 gets `body_id`. Component k ≥ 1 gets `UTIL.derived_body_id(body_id, feature.id, k + 1)`.
   - If a body fails, record `errors[body_id]` and continue with the next body.
   - The feature's error string, if any body failed, is `"<Body name>: <native error>"` (several joined with `"; "`).
   - An open component becomes a surface body (the shell). `CadShape.is_surface()` already treats it as two-sided.
5. Warnings, such as `"Body2 converted by sewing (slower path)"` or `"Body3: 2 faces self-intersect"`, go into `ctx.warnings` through `UTIL.add_warning` semantics.

**Cache.** `form.gd` keeps `static var _cache := {}` as an LRU of at most 16 entries: key, then `{"cage": cage copy, "shapes": Array, "report": Dictionary}`. Add `static func clear_cache()` for tests.
- The key is the cage **content**, never `get_instance_id()`. `document.restore` copies features, so instance ids miss after every undo.
- `CAGE.content_hash(c) = hash([c.positions, c.face_counts, c.face_indices, c.crease_edges, c.crease_weights, c.corners, c.corner_weights])`. Symmetry, frozen, display and links don't change the surface, so they are excluded.

**Workspace preview plumbing.**
- `forge_workspace` gets `var form_preview := ""`.
- `recompute()` calls `REGEN.rebuild(doc, kernel, {"form_preview": form_preview})`.
- While `form_preview != ""`, recompute **skips `part.apply_result()`**. Baking a preview would delete the baked MeshInstance3D nodes of form bodies that are absent from the result, together with the user's materials and scripts on them.
- Finish Form sets `form_preview = ""` and calls `recompute()`, which converts and bakes.

**Save/load.** A document without form features is byte-for-byte unaffected:
- no new document fields;
- `rebuild` defaults keep old behaviour;
- `snapshot`/`restore` are unchanged, since options are deep-copied already.

Cages are stored inside the scene (`CadPart.document` is embedded). A 5000-face cage adds about 0.4 MB of text to the `.tscn`. That is accepted for now (see Risks).

**Preview result for other code.**
- In preview, `result.bodies` holds bodies from features before the form plus the form's `breps` bodies. The browser receives `result.bodies.keys() + form_editor.body_ids()`, so form bodies are listed.
- Analyses, Measure and references don't see cage bodies while the form is open. That is acceptable and stated in the editor's flash message on entry.

### 2.4 C3: native API, the `CadSubD` class

`CadSubD` is a stateful `RefCounted` that holds one cage. Register it in `register_types.cpp` with `GDREGISTER_CLASS(holo_forge::CadSubD)`, next to the existing classes. Follow the binding style of `cad_kernel.cpp`:
- `ClassDB::bind_method(D_METHOD(...), &..., DEFVAL(...))`;
- the `report("")` / `last_error` pattern;
- every OCCT call wrapped in `try { } catch (const Standard_Failure&)`;
- results wrapped with `CadShape::wrap`.

Every method returns an empty value (`false`, `{}`, an empty array or `null`) on failure and sets `get_last_error()`.

#### 2.4.1 Methods (exact arguments and return dictionaries)

```
bool   set_cage(Dictionary cage)
```
- Reads C1 keys `positions`, `face_counts`, `face_indices`, `crease_edges`, `crease_weights`, `corners`, `corner_weights` and ignores the rest.
- Builds:
  - `Far::TopologyDescriptor` with crease pairs/weights and corner indices/weights, `isLeftHanded=false`;
  - `Sdc::Options`: `VtxBoundaryInterpolation=VTX_BOUNDARY_EDGE_AND_CORNER`, `CreasingMethod=CREASE_UNIFORM`, `TriangleSubdivision=TRI_SUB_SMOOTH`, `FVarLinearInterpolation=FVAR_LINEAR_CORNERS_ONLY`;
  - a base `Far::TopologyRefiner` (scheme `SCHEME_CATMARK`) for Bfr. Keep a second, adaptively refined copy built lazily for patch tables and limit stencils.
- Installs `Far::SetErrorCallback` / `SetWarningCallback` once, capturing messages into `last_error` / `last_warning` instead of stdout.
- Computes a topology key (hash of faces, crease and corner data). If it equals the current key, behaves like `set_positions` and keeps every cache.
- Returns false on: index out of range, face with fewer than 3 vertices, non-manifold or inconsistently oriented topology (refiner creation fails or warns), or `positions.size() % 3 != 0`.

```
bool   set_positions(PackedFloat64Array positions)       # same vertex count; keeps topology caches; marks geometry dirty
int    get_vertex_count() / get_face_count() / get_edge_count() / get_ptex_count()
String osd_version()                                      # "3.5.0"
```

```
Dictionary tessellate(Dictionary options = {})
```
Options:

| Key | Default | Meaning |
|---|---|---|
| `"rate"` | 0 = auto | Bfr tessellation rate per face edge. Auto = `clamp(floor(sqrt(150000.0 / nF)), 2, 12)` |
| `"approx_level"` | 4 | `SetApproxLevelSmooth`. Draft display passes 2 |
| `"weights"` | empty | One float per cage vertex; when given, interpolated through the same surface |
| `"edges"` | true | Also return the limit edge curves |

Returns (key-compatible with `CadShape.tessellate`, so `core/picking.gd` works on it unchanged):

```
{
  "positions": PackedVector3Array,  # per tess vertex; vertices are NOT shared between cage faces (crisp crease normals)
  "normals":   PackedVector3Array,  # normalize(Du x Dv), pointing outward for the cage orientation
  "uvs":       PackedVector2Array,  # per tess vertex: the Bfr face coordinate (u, v) of its cage face
  "indices":   PackedInt32Array,    # triangles; winding identical to CadShape::tessellate for outward faces (read cad_shape.cpp and match it)
  "face_ids":  PackedInt32Array,    # per TRIANGLE: the cage face index
  "vertex_faces": PackedInt32Array, # per tess vertex: cage face index
  "edge_points": PackedVector3Array,# segment pairs (2 points per segment) along each cage edge's limit curve
  "edge_ids":  PackedInt32Array,    # per segment: canonical cage edge index (C1 order)
  "edge_pairs": PackedInt32Array,   # 2 per canonical cage edge: (a, b), a < b
  "vertices":  PackedVector3Array,  # limit point of every cage vertex (index = cage vertex)
  "weights":   PackedFloat32Array,  # only with options.weights: per tess vertex
  "rate": int, "approx_level": int,
}
```

Cache and drag contract:
- When the topology key and options are unchanged since the last call, only positions changed. In that case reuse the face tessellation patterns and evaluation stencils: Bfr `Surface::EvaluateStencil` weights or a `Far::LimitStencilTableReal<double>` at the tess locations, with P, Du and Dv.
- So a drag frame costs one stencil application plus normals.
- Rebuild the BVH used by `ray_hit` and `visible` lazily on their next call.

```
Dictionary limit_points()
  -> {"positions": PackedFloat64Array (3 per cage vertex, doubles), "normals": PackedVector3Array}
```
Exact limit positions, via `Far::PrimvarRefinerReal<double>::Limit` on a uniform level-1 refinement or Bfr at a face corner.

```
Dictionary evaluate(PackedInt32Array faces, PackedVector2Array uvs)
  -> {"positions": PackedFloat64Array (3 per point), "normals": PackedVector3Array, "du": PackedVector3Array, "dv": PackedVector3Array}
```
A location is `(cage face, Bfr face coordinate)`:
- quads use (u, v) in [0,1]², with corner k of the face at (0,0), (1,0), (1,1), (0,1);
- non-quads use Bfr's `QUAD_SUBFACES` coordinates.

The helper `Vector2 subface_uv(int face, int subface, float s, float t)` converts the normalized sub-face coordinate (s, t) of sub-face k of an n-gon to that face coordinate. Sub-face k has its (0,0) at corner k, (1,0) at the midpoint of edge (k, k+1), (1,1) at the face centre and (0,1) at the midpoint of edge (k-1, k). Verify this with `Bfr::Parameterization::ConvertCoordToNormalizedSubFace` and document what you find.

```
Dictionary ray_hit(Vector3 from, Vector3 dir, int mode = 0)
  -> {"hit": bool, "face": int, "uv": Vector2, "point": Vector3, "normal": Vector3, "distance": float}
```
- `mode 0`: against the limit surface. Uses a BVH over the last tessellation; with `refine=true` (default), 3 Newton steps on the hit face.
- `mode 1`: against the cage polygons (fan triangles), for Box and Control Frame picking.

```
PackedByteArray visible(PackedVector3Array points, Vector3 eye, Vector3 view_dir = Vector3(), float tolerance = 1e-4, int mode = 0)
```
- 1 = visible. A point is hidden when the segment from the eye (or, for an orthographic camera, the ray `point - view_dir * far`) hits the surface in `mode` more than `tolerance` (meters) before reaching it.
- Used for window selection and hover of points and edges.

```
Dictionary closest_points(PackedVector3Array points, float max_distance = INF)
  -> {"positions": PackedFloat64Array, "normals": PackedVector3Array, "faces": PackedInt32Array, "uvs": PackedVector2Array, "distances": PackedFloat64Array}
```
Closest point on the limit surface. Algorithm (production version of the prototype):
1. A BVH over the display triangles, which carry `(face, uv)` per vertex, gives the nearest triangle.
2. Clamped Newton on |S(u,v) - p|² for that face, using `Surface::Evaluate` P, Du, Dv, Duu, Duv, Dvv. Fall back to Gauss-Newton when the Hessian is not positive definite.
3. If Newton clamps on a face border, hop to the face across that cage edge. Also try every face whose BVH bound lies within `d_min + 1e-9`.
4. Keep the best result.

Target: 0 failures in 300 random near-surface queries on the noisy-cube and 240-quad cages, checked against dense rate-48 sampling. The parameter is accurate to 1e-12.

```
PackedFloat64Array interpolate(PackedFloat64Array targets, PackedInt32Array free = PackedInt32Array(), float regularize = 1e-8)
```
Returns new positions (3 per vertex, doubles) such that `limit(v) = target(v)` for every free vertex v (all vertices when `free` is empty). Non-free vertices keep their current positions.
- Matrix A (nV x nV, about 9 non-zeros per row) is built from `Far::LimitStencilTableFactoryReal<double>::Create` with one location per vertex: the vertex's corner of one incident face. Use ptex = that face (sub-face k for n-gons) and corner (0,0) of that ptex face. The refiner must be adaptively refined first, and isolation 2 is enough for corner locations.
- Solve the free block `A_ff x_f = T_f - A_fx x_x` in least squares with Tikhonov regularisation toward the current positions: `(A_ffᵀA_ff + λI) x_f = A_ffᵀ(T_f - A_fx x_x) + λ x0_f` with `Eigen::SimplicialLDLT`.
- The plain 8-vertex cube matrix is singular (checkerboard mode, condition 7e16), so λ must never be 0. Default λ = 1e-8 times the mean squared row norm.
- Report the residual through `get_last_warning()` when it exceeds 1e-9 times the cage size.

```
PackedFloat64Array fit(PackedInt32Array faces, PackedVector2Array uvs, PackedFloat64Array targets, PackedInt32Array free, float regularize = 1e-6)
```
Generic least-squares fit: move only the `free` vertices so the limit at each location `(faces[i], uvs[i])` approaches `targets[i]`. Same regularised normal equations, with limit stencils at arbitrary locations. Used by the Exact modes, Edit By Curve "surface points", Flatten/Straighten "surface points", Make Uniform and BRep face to cage.

```
Array to_shapes(Dictionary params)        # Array of CadShape, one per connected component (ordered by lowest face index); empty on failure
Dictionary get_last_report()
```
`params`:

| Key | Default | Meaning |
|---|---|---|
| `"isolation"` | 6 | Clamped to 1..10 |
| `"name_prefix"` | `""` | Prefix for face names |
| `"tolerance"` | 1e-7 | BRep tolerance |
| `"check"` | true | Run BRepCheck_Analyzer |
| `"regularity"` | 3e-3 | Angle (rad) for `BRepLib::EncodeRegularity`; 0 = skip |

`get_last_report()` returns:

```
{"components": [{"faces": int, "closed": bool, "solid": bool, "valid": bool, "method": "direct"|"sewing",
                 "free_edges": int, "volume": float, "area": float}],
 "problem_faces": PackedInt32Array, "warnings": PackedStringArray, "ms": float}
```

```
Dictionary check_cage(Dictionary cage, bool self_intersections = true)
  -> {"ok": bool, "errors": PackedStringArray, "non_manifold_edges": PackedInt32Array (pairs),
      "flipped_faces": PackedInt32Array, "degenerate_faces": PackedInt32Array, "self_intersecting_faces": PackedInt32Array}
```
- Works on any cage dictionary, without `set_cage`, so it can diagnose cages that `set_cage` rejects. It does not change the loaded cage.
- Self-intersection is a triangle-triangle test on cage fan triangles of non-adjacent faces (BVH).
- It is used by Repair Body. `to_shapes` reports self-intersecting faces as a warning in `problem_faces`.

```
Dictionary project_to_shape(RefCounted shape, PackedVector3Array points, float max_distance = INF)
  -> {"positions": PackedFloat64Array, "normals": PackedVector3Array, "faces": PackedInt32Array (BRep face index), "distances": PackedFloat64Array}
```
Batch closest points on a BRep shape (a CadShape), used by Pull, Make Uniform and Match targets on faces.
- Build a BVH over `BRepMesh` triangles, cached per shape instance via a weak cache keyed by the TopoDS_TShape pointer.
- Seed `GeomAPI_ProjectPointOnSurf` on the nearest faces, and keep the best result inside the face (use `BRepClass_FaceClassifier` to reject points outside the trimmed face, falling back to the nearest boundary edge).
- The existing `CadKernel.closest_points(a, b)` is shape-to-shape only, so it does not replace this.

```
Dictionary face_grid(RefCounted shape, int face_index, int nu, int nv)
  -> {"ok": bool, "four_sided": bool, "positions": PackedFloat64Array ((nu+1)*(nv+1)*3, row-major v then u), "error": String}
```
Samples the face's surface over `BRepTools::UVBounds` on a grid, for BRep face to cage. `four_sided` = the outer wire has exactly 4 edges (or 4 G1 breaks) and no inner wires. If not four-sided, `ok` is false with error `"Only four-sided faces can become a cage in this version"`.

```
String get_last_error() / get_last_warning()
```

#### 2.4.2 Conversion pipeline (`to_shapes`), measured in the prototype

1. **Components.** Union-find over faces sharing an edge. Each component is converted on its own. The patch table is built once for the whole cage.
2. **Patch table.** Configure `Far::PatchTableFactory::Options po(L)` as follows:
   - `SetPatchPrecision<double>()`;
   - `useInfSharpPatch = true` (**mandatory**: with false, creases are rounded inside a 2^-L band and the "crease stays sharp" test fails with a 0° normal jump);
   - `useSingleCreasePatch = false`, `generateVaryingTables = false`, `generateLegacySharpCornerPatches = false`;
   - `SetEndCapType(ENDCAP_GREGORY_BASIS)`.

   Then `RefineAdaptive(po.GetRefineAdaptiveOptions())` and `PatchTableFactory::Create`.

   The vertex buffer holds `GetNumVerticesTotal()` refined vertices plus `GetNumLocalPoints()`. Fill it level by level with `PrimvarRefinerReal<double>::Interpolate`, then call `GetLocalPointStencilTable<double>()->UpdateValues(verts, verts + nRefined)`.

   Gotchas found in the prototype:
   - `PatchHandle::patchIndex` is the **absolute** patch index across all arrays.
   - The default level-1 vertex order puts vertex children first, so the child of base vertex v is at index v.
3. **Patch to bicubic Bezier.**
   - **REGULAR** (16 CVs, `cvs[4*row+col]`, col along u, row along v):
     - Phantom points first. If boundary bit3 (u=0) is set, column 0 = 2·col1 - col2. Bit1 (u=1): column 3 = 2·col2 - col1. Apply the column phantoms first, then the rows: bit0 (v=0) row 0 = 2·row1 - row2; bit2 (v=1) row 3 = 2·row2 - row1.
     - Then convert the uniform B-spline span to Bezier with `M = (1/6)[[1,4,1,0],[0,4,2,0],[0,2,4,0],[0,1,4,1]]` applied along u, then along v. This is exact.
   - **GREGORY_BASIS** (20 CVs):
     - Bezier boundary: row v=0 from cvs {0,1,7,5}; row 1 ends {2, 6}; row 2 ends {16, 12}; row 3 from {15,17,11,10}.
     - Interior: C11 = (cv3+cv4)/2, C12 = (cv8+cv9)/2, C22 = (cv13+cv14)/2, C21 = (cv18+cv19)/2.
     - The boundary is exact (watertight). Only the rational interior is approximated: G1 jump 0.015° at L6, valence 3.
   - Any other patch type means a bug or an unsupported option. Fail with `"Unsupported patch type <n>"`.
   - Patch placement in its ptex face: `frac = GetParamFraction()`, origin = `(GetU(), GetV()) * frac`. `GetFaceId()` is the **ptex** face. Map it to the cage face with `Far::PtexIndices(refiner).GetFaceId(face)` (first ptex index; an n-gon owns n consecutive ones).
4. **Graded merge: one B-spline surface per ptex face.** Do NOT merge onto a uniform 2^L grid; the prototype hung with RemoveKnots and exploded the pole count. Instead:
   1. The knots in u and v are the sorted, unique union of all patch boundary parameters inside the ptex face.
   2. For each knot cell, find the patch containing the cell centre, `Segment` it to the cell (when smaller than the whole patch) and take its 4x4 poles.
   3. Assemble with `GeomConvert_CompBezierSurfacesToBSplineSurface(grid, UKnots, VKnots, GeomAbs_C0, GeomAbs_C0, 1e-9)`.
   4. Build a `Geom_BSplineSurface`, then for each interior knot, from last to first: `if (!RemoveUKnot(i, 1, 1e-9)) RemoveUKnot(i, 2, 1e-9)`. Same for V.

   Exact to 7e-16 against the patches. Cube at L6: 2166 poles in 4 ms.
5. **Direct shell build (no sewing).** Use `BRep_Builder`, tolerance 1e-7:
   - One `TopoDS_Vertex` per cage vertex at its limit point. For n-gon components, also one per n-gon centre (sub-face (1,1)) and one per midpoint of every cage edge that touches a non-quad face (sub-face (1,0) / (0,1)).
   - One `TopoDS_Edge` per **edge piece**, keyed by `(min(a,b), max(a,b), half)`:
     - `half = -1` when both adjacent faces are quads (the whole edge);
     - `half = 0 / 1` for the two halves when either adjacent face is a non-quad;
     - interior n-gon spokes are keyed `(face, k)` (from the midpoint of edge (k, k+1) to the centre).
   - The 3D curve is the boundary iso (`UIso`/`VIso`) of the first face that creates the edge, with `B.Range(e, t0, t1)` set to that face's parameter range for the piece.
   - Every face gets a pcurve for every piece it uses: a degree-1 `Geom2d_BSplineCurve` (or a `Geom2d_Line` when its parameter speed equals the 3D curve's), mapping the edge parameter linearly onto the face's iso line. Reverse it when the piece runs the other way on that face. A quad whose neighbour is an n-gon therefore uses two pieces with pcurves over [0, 0.5] and [0.5, 1].
   - Wire order follows the face's corners (k = 0..n-1 for quads; for sub-faces: corner, edge midpoint, centre, previous edge midpoint). Edge orientation is FORWARD when the piece starts at the loop vertex.
   - Set `B.SameParameter(e, true)` and `B.SameRange(e, true)` for all edges.
   - A component whose every piece has 2 faces is closed: `MakeSolid` + `BRepLib::OrientClosedSolid`. Otherwise output the shell (open, surface body).
   - Run `BRepCheck_Analyzer`. If it is invalid, **fall back** to `BRepBuilderAPI_Sewing(1e-6, true, true, true, false)` of the merged faces, plus `ShapeFix_Shell` / `ShapeFix_Solid`, then MakeSolid when closed. Report `"method": "sewing"`.
   - Prototype timings: direct build is 37-95x faster than sewing. Cube 3 ms; 240 faces 93 ms + 39 ms check; 5046 faces 1.45 s + 1.09 s check.
6. **Regularity.** `BRepLib::EncodeRegularity(shape, params.regularity)`, so edges between smooth faces count as G1 for later fillets and offsets. Creased edges stay sharp.
7. **Names.**
   - Face of cage quad f: `"<prefix>/f<f>"`.
   - Sub-face k of an n-gon f: `"<prefix>/f<f>.<k>"`.
   - Apply with `CadShape::set_face_names`, then `name_edges_from_faces`.
8. **Report.** Fill in the components array. Compute volume with `BRepGProp::VolumeProperties(s, props, 1e-9)`, the adaptive overload; the default integration was 0.02% off on multi-span faces.

#### 2.4.3 Accuracy and timing targets (dev machine; tests use ratios, see 5.6)

| Measure | Target (prototype value) |
|---|---|
| Limit deviation of converted BRep vs isolation-10 limit, cube cage, L6 / L8 | ≤ 4e-4 / ≤ 6e-5 relative to cage half-size (2.85e-4 / 4.8e-5) |
| Patch boundary gaps | ≤ 1e-12 (7e-15) |
| G1 jump at Gregory end-cap borders, L6 | ≤ 0.05° (0.015°) |
| Converted volume vs triangulated fine limit (rate 64) | within 0.1% (0.0016%) |
| `set_cage` + `tessellate` (auto rate), 100 / 1000 / 5000 faces | ≤ 10 / 40 / 150 ms |
| Drag frame (`set_positions` + cached `tessellate`), 1000 / 5000 faces | ≤ 8 / 30 ms |
| `to_shapes` at L6 incl. BRepCheck: cube / 240 faces / 1000 faces (8 EVs) / 5000 faces | ≤ 50 ms / 400 ms / 1.5 s / 6 s |
| `interpolate`, 6146 vertices | ≤ 120 ms (stencils 7 ms + solve 42-60 ms) |
| `closest_points`, per query | ≤ 50 µs (BVH version) |

#### 2.4.4 CMake, licenses, smoke test

In `N/CMakeLists.txt`:

```cmake
find_package(OpenSubdiv CONFIG REQUIRED)          # after find_package(boost_graph ...)
...
target_include_directories(holo_forge_native PRIVATE ${OpenSubdiv_INCLUDE_DIR})   # the imported target has no include dirs
target_link_libraries(holo_forge_native PRIVATE ... OpenSubdiv::osdCPU_static Eigen3::Eigen)
```

- `osdCPU.lib` is static, so no new DLL ships.
- **pmp is not linked.** Cage topology lives in GDScript (`cage.gd`). Leave `pmp-library` in vcpkg.json for Phase 7.
- If any OCCT toolkit is missing at link time, add it. `GeomConvert` is in TKGeomBase and `ShapeFix` in TKShHealing; both are already linked.
- Add `A/licenses/OpenSubdiv-Modified-Apache-2.0.txt`. Copy it from `C:\Users\Blaze\holo_forge_build\vcpkg_installed\x64-windows-release\share\opensubdiv\copyright` and append the OpenSubdiv NOTICE text, which Apache section 4(d) requires: copyright 2013 Pixar, contributors Pixar, DreamWorks Animation, Autodesk, Google, DigitalFish. If the copyright file lacks the NOTICE, take it from the OpenSubdiv source in `C:\Users\Blaze\holo_forge_build\vcpkg\buildtrees\opensubdiv\src` when present, or write the attribution list above verbatim.
- `tests/holo_forge_native_smoke_test.gd`: add `CadSubD` to the class check and its PASS line.

### 2.5 C4: `core/form/cage.gd` (pure topology library; Stage 1 team T)

`const CAGE := preload("res://addons/holo_forge/core/form/cage.gd")`. Everything is `static`. Nothing touches the editor or native classes.

#### 2.5.1 Data helpers

```gdscript
static func empty() -> Dictionary                                          # all C1 keys, empty arrays, version 1
static func make(positions: PackedFloat64Array, face_counts: PackedInt32Array, face_indices: PackedInt32Array) -> Dictionary
static func from_vectors(points: PackedVector3Array, faces: Array) -> Dictionary  # faces: Array of Array/PackedInt32Array
static func copy(c: Dictionary) -> Dictionary                              # deep copy (duplicate(true))
static func vertex_count(c) -> int
static func face_count(c) -> int
static func face_offsets(c) -> PackedInt32Array                            # size nF+1
static func face_vertices(c, f: int) -> PackedInt32Array
static func position(c, v: int) -> Vector3                                 # float32 view (display/math)
static func position_d(c, v: int) -> PackedFloat64Array                    # (x, y, z) doubles
static func set_position(c, v: int, p: Vector3) -> void                   # writes back into c.positions
static func set_position_d(c, v: int, x: float, y: float, z: float) -> void
static func positions_v3(c) -> PackedVector3Array
static func bounds(c) -> AABB
static func mean_edge_length(c, topo = null) -> float
static func content_hash(c) -> int                                         # see C2
static func topology_hash(c) -> int                                        # faces + crease/corner data only
static func validate(c) -> PackedStringArray                               # C1 invariants; [] when valid
static func compact(c) -> Dictionary        # {"cage", "vertex_map": PackedInt32Array old->new (-1 removed)}; remaps creases, corners, frozen, sym_isolated, symmetry maps, links
static func append(c, other) -> Dictionary  # {"cage", "offset": int}; disjoint union, other's indices shifted; symmetry of other dropped
static func is_crease(c, a: int, b: int) -> bool
static func set_crease(c, a: int, b: int, weight: float) -> void          # weight 0 removes; keeps sorted order
static func set_corner(c, v: int, weight: float) -> void
static func locked_vertices(c, topo) -> PackedByteArray                    # C1 locked set, 1 = locked
```

#### 2.5.2 `class Topo` (half-edge adjacency; build with `CAGE.topology(c)`)

Half-edge `h` = corner `k` of face `f`, with `h = face_offsets[f] + k`. Its origin is `face_indices[h]` and it goes to the face's next corner. So the half-edge arrays align with `face_indices`.

Fields:

| Field | Meaning |
|---|---|
| `nV`, `nF`, `nE` | Counts |
| `face_offsets` | Per face, as in `face_offsets(c)` |
| `he_face` | Per half-edge: its face |
| `he_twin` | Per half-edge: the opposite half-edge, -1 on boundary |
| `he_edge` | Per half-edge: its canonical edge |
| `edges` | `PackedInt32Array`, 2 per edge, (a<b), canonical order |
| `edge_he` | Per edge: its first half-edge |
| `vertex_he` | Per vertex: one outgoing half-edge; a boundary vertex stores the one whose twin is -1 |
| `edge_lookup` | Dictionary from int key `(a << 32) | b` to edge |

Queries:

```gdscript
func he_origin(h) -> int;  func he_dest(h) -> int;  func he_next(h) -> int;  func he_prev(h) -> int
func edge_index(a, b) -> int                          # -1 when no such edge
func edge_vertices(e) -> Vector2i
func edge_faces(e) -> PackedInt32Array                # 1 or 2 faces
func is_boundary_edge(e) -> bool;  func is_boundary_vertex(v) -> bool;  func valence(v) -> int
func vertex_faces(v) -> PackedInt32Array              # in rotational order
func vertex_edges(v) -> PackedInt32Array;  func vertex_neighbors(v) -> PackedInt32Array
func face_edges(f) -> PackedInt32Array;  func face_neighbors(f) -> PackedInt32Array
func components() -> PackedInt32Array                 # face -> component id (0..k-1, by lowest face)
func component_vertices(comp) -> PackedInt32Array
func boundary_loops() -> Array                        # Array[PackedInt32Array] of vertex loops, each in boundary half-edge order
func boundary_loop_of_edge(e) -> PackedInt32Array
func is_closed() -> bool;  func non_manifold_edges() -> PackedInt32Array
func face_by_vertices(verts: PackedInt32Array) -> int # face with exactly that vertex set (any order), -1
func face_normal(c, f) -> Vector3;  func vertex_normal(c, v) -> Vector3   # area-weighted cage normals
```

Selection helpers (used by the editor and by tools). A **regular** vertex is an interior vertex with valence 4.

| Function | Behaviour |
|---|---|
| `edge_loop(e)` | Walks both ways. At a regular vertex, continue with the edge opposite e (two edges away in rotational order). Stop at irregular vertices or on returning to e. On a boundary edge, follow the boundary loop instead. Returns ordered edges |
| `edge_ring(e)` | Walks across quads to the opposite edge, both ways. Stops at non-quads, boundaries or e. Returns ordered edges |
| `face_loop(f_a, f_b)` | `f_a` and `f_b` adjacent: walk from `f_a` through `f_b` crossing opposite edges of quads. Stops at non-quads, boundaries or start |
| `vertex_loop(a, b)` | a, b adjacent: the vertices of `edge_loop(edge(a,b))` |
| `grow(kind, sel)` / `shrink(kind, sel)` | Faces: add or remove faces sharing a vertex with the set boundary. Edges and vertices: by vertex adjacency |
| `loop_grow(edges)` | Extend each selected loop by one edge at each open end |
| `ring_grow(edges)` / `ring_shrink(edges)` | Same along rings |
| `range_select(kind, a, b)` | Elements between a and b along the shortest loop or ring path containing both. Empty when they don't share one |
| `invert(kind, sel)` | Everything of that kind not in sel |
| `feature_faces(f)` | The closed face loop through f with the smaller face count (a band around a strut or hole). Then repeatedly add each adjacent parallel closed face loop whose perimeter (sum of its edge lengths) is within ±35% of the first band's. Empty when no closed loop passes through f |

#### 2.5.3 Low-level topology ops

Every op is a static function that **never mutates its input**. It returns:

```gdscript
{"cage": Dictionary, "error": String,                 # error "" on success; cage = input copy on error
 "new_vertices": PackedInt32Array, "new_edges": PackedInt32Array (vertex pairs), "new_faces": PackedInt32Array,
 "vertex_map": PackedInt32Array}                       # old -> new vertex ids when ids were compacted; empty when unchanged
```

Every op also:
- carries creases, corners, frozen and symmetry data through, remapping indices;
- drops crease pairs that stop being edges;
- extends symmetry maps with -1 for new vertices. Callers then run `rebuild_symmetry` (C5).

| Op | Behaviour |
|---|---|
| `delete_faces(c, faces: PackedInt32Array)` | Remove faces, then `compact()` |
| `dissolve_edges(c, pairs: PackedInt32Array)` | Interior edge: merge its two faces into one polygon. Boundary edge: delete its face. Afterwards, dissolve vertices left with valence 2 that sit inside a merged face. Refuse when two faces would share more than one edge chain |
| `dissolve_vertices(c, verts)` | Valence-2 vertex: remove it from both faces. Otherwise merge its incident faces into one polygon (its link must be a simple loop). Refuse otherwise |
| `split_edge(c, a, b, t: float)` | New vertex at `lerp(p_a, p_b, t)` (doubles), inserted into both faces. A crease on (a,b) is copied to both halves |
| `split_face(c, f, va, vb)` | Connect two non-adjacent vertices of f with a new edge |
| `insert_edge_loop(c, items: Array, t: float, both: bool)` | `items` = `[{"edge": Vector2i(a,b), "side": face}]`. See Insert Edge (3.3.3) for the exact rule |
| `subdivide_faces(c, faces, nu: int, nv: int)` | Quads become nu x nv grids, bilinear in doubles. Non-quads become n quads around the centroid via edge midpoints. Edges shared by two selected faces are split the same way. Edges shared with unselected faces put the new vertices into those faces (they gain vertices and become n-gons) |
| `catmull_clark_step(c)` | One full Catmull-Clark step with OpenSubdiv's infinitely-sharp rules. Smooth: face point = centroid; edge point = (a+b+f0+f1)/4; vertex = (F + 2R + (n-3)P)/n. Crease or boundary edge point = midpoint. Crease vertex (exactly 2 crease or boundary edges) = (e0 + 6P + e1)/8. Corner vertex (3+ crease edges, a corner weight, or a boundary valence-2 vertex) = P. Creases propagate to both child edges; corners stay corners. Used by exact whole-body subdivide and Make Uniform. **Its limit must equal the parent's limit within 1e-9.** That is a test |
| `extrude_faces(c, faces)` | Duplicate the region's boundary vertices. Region vertices keep their positions (the caller moves them). Insert one side quad per region-boundary edge. Interior region vertices are reused. Returns the region's new boundary edges and the region faces as `new_faces` |
| `extend_boundary(c, pairs)` | Duplicate the chain's vertices and add one quad per boundary edge beyond the boundary. The new outer chain is `new_edges` |
| `fill_hole(c, loop: PackedInt32Array, mode: String)` | See Fill Hole (3.3.8) |
| `bridge_loops(c, loop_a, loop_b, segments: int, twist: int)` | Loops given as boundary vertex loops of equal count, or counts that are whole multiples of each other. See Bridge |
| `weld(c, pairs: Array)` | `[Vector2i(keep, remove)]`: the second vertex merges into the first. Faces that become degenerate are removed. Duplicate faces are removed. Refuse non-manifold results |
| `unweld_edges(c, pairs)` | For each vertex on the cut, its incident faces are split into fans separated by cut or boundary edges. Every fan after the first gets a duplicated vertex |
| `flip_faces(c, faces)` | Reverse winding |
| `merge_triangle_pairs(c, max_angle_deg := 30.0)` | Greedily merge adjacent triangles into quads when the merged quad is convex and the two normals differ less than `max_angle_deg`. Best pairs first: smallest quad-corner deviation from 90° |
| `split_to_quads(c, faces)` | Triangles and n-gons become n quads (centroid + edge midpoints). Neighbours gain midpoint vertices: none when the whole component is processed |
| `orient_consistently(c)` | BFS per component flips faces to agree with the first face. Then makes the signed volume positive for closed components |

Performance (GDScript, dev machine): `topology()` ≤ 60 ms and any single op ≤ 120 ms on a 5000-face cage.

### 2.6 C5: `core/form/form_ops.gd`, `core/form/primitives.gd`, symmetry

`const FORM_OPS := preload("res://addons/holo_forge/core/form/form_ops.gd")`.

#### 2.6.1 Common signature

```gdscript
# sel: {"vertices": PackedInt32Array, "edges": PackedInt32Array (vertex pairs), "faces": PackedInt32Array}
static func <tool>(c: Dictionary, sel: Dictionary, opts: Dictionary) -> Dictionary
# returns {"ok": bool, "cage": Dictionary, "selection": <sel of the new/affected elements>,
#          "warnings": PackedStringArray, "error": String, "info": Dictionary (tool-specific numbers, e.g. max deviation)}
```

Every tool wrapper:
1. Rejects selections it cannot use, with a sentence the editor can flash.
2. Applies the **locked-set rule** (C1).
3. Applies **symmetry propagation** (2.6.3).
4. Runs `CAGE.validate()` on the result in debug (`OS.is_debug_build()`) and fails the op if it returns violations.

Tools that need native evaluation live in `core/form/form_fit.gd` (Stage 3), with the same signature plus a `subd: RefCounted` argument.

#### 2.6.2 Geometry helpers (doubles)

```gdscript
static func xf_identity() -> PackedFloat64Array                       # 12 doubles: row-major 3x3 basis + translation
static func xf_from(basis: Basis, origin: Vector3) -> PackedFloat64Array
static func xf_compose(a, b) -> PackedFloat64Array                    # a after b
static func xf_apply(xf, x: float, y: float, z: float) -> PackedFloat64Array
static func reflect_d(p: PackedFloat64Array, origin: PackedFloat64Array, normal: PackedFloat64Array) -> PackedFloat64Array
static func rotate_d(p, origin, axis, angle: float) -> PackedFloat64Array     # Rodrigues, doubles
static func transform_vertices(c, verts: PackedInt32Array, weights: PackedFloat32Array, xf: PackedFloat64Array, pivots := PackedFloat64Array()) -> Dictionary
    # p' = p + w * (xf(p - pivot) + pivot - p); pivots: per-vertex pivot (Local Per Entity) or empty (xf already about the pivot)
static func soft_weights(c, topo, selected: PackedInt32Array, opts: Dictionary) -> PackedFloat32Array   # see Edit Form
static func best_fit_plane(points) -> Dictionary                      # {"origin", "normal"} via PCA (smallest eigenvalue)
static func best_fit_line(points) -> Dictionary                       # {"origin", "direction"} via PCA (largest eigenvalue)
```

#### 2.6.3 Symmetry (part of `form_ops.gd`)

```gdscript
static func orbit(c, v: int) -> Dictionary
static func partner_selection(c, sel) -> Dictionary
static func apply_symmetry(c, primary: PackedInt32Array) -> Dictionary
static func rebuild_symmetry(c, tolerance: float) -> Dictionary
static func detect_mirror(c, hint_faces: PackedInt32Array, tolerance: float) -> Array
static func detect_circular(c, hint_faces: PackedInt32Array, tolerance: float) -> Array
static func symmetrize(c, entry: Dictionary, tolerance: float) -> Dictionary
```

- **`orbit(c, v) -> Dictionary`**: `w -> xf` (12 doubles) taking v's position to w's.
  - Built by BFS over every symmetry entry's map. A mirror contributes its reflection. A circular entry contributes rotation by ±step: inverse lookup for -step, and an open orbit stops at -1.
  - Isolated vertices have no orbit beyond themselves.
- **`partner_selection(c, sel) -> Dictionary`**: sel united with the partners of each element, all symmetry entries applied repeatedly.
  - A vertex maps through the map.
  - An edge maps to the edge between its mapped endpoints, if it exists.
  - A face maps to `face_by_vertices` of its mapped vertices.
  - Elements whose partner doesn't exist are left alone and add the warning `"Symmetry is broken here; some partners were skipped"`.
- **`apply_symmetry(c, primary) -> Dictionary`**: writes partner positions from the primary vertices.
  1. For each orbit containing primary vertices, compute a representative in v's frame: the average of `xf_{w→v}(p_w)` over the primary members w.
  2. Set every non-isolated, non-locked member u to `xf_{v→u}(rep)`.
  3. A vertex that maps to itself under a mirror is projected onto the plane. A vertex on a circular axis (`map[v] == v`) is projected onto the axis line.
  4. All in doubles.
  - Result: `|reflect(p_v) - p_partner| ≤ 1e-12 · size`. That is a test.
- **`rebuild_symmetry(c, tolerance) -> Dictionary`**: after topology ops, rebuild each entry's map geometrically.
  - For each vertex, find the nearest vertex to `T(p_v)` with a spatial hash (cell = 4 · tolerance), accepted within `tolerance`.
  - Default tolerance = `1e-4 · bounds diagonal`.
  - Vertices with no partner get -1, and the result gets the warning `"Symmetry broken at <n> vertices"`.
- **`detect_mirror(c, hint_faces, tolerance) -> Array`**: candidates `[{"origin", "normal", "label"}]` that map **every** vertex.
  - Try first the bisector plane of the two hint faces' centroids (when 2 faces are given).
  - Then the 3 PCA planes through the vertex centroid.
  - Then the world YZ, XZ and XY planes through the bounds centre.
  - Deduplicate planes whose normals are within 1e-6 and origins within the tolerance.
- **`detect_circular(c, hint_faces, tolerance) -> Array`**: candidates `[{"origin", "axis", "count", "label"}]`.
  - Axes: the PCA axis with the most distinct eigenvalue through the centroid, then world X, Y and Z through the bounds centre.
  - For each axis, keep every count n in 2..64 for which rotating by 2π/n maps every vertex within tolerance.
- **`symmetrize(c, entry, tolerance) -> Dictionary`**: make a nearly symmetric cage exactly symmetric under the entry (pairs averaged), then build the map.

**Topology ops under symmetry.**
1. Expand the selection with `partner_selection`.
2. Run the op on the union.
3. Directional options (Insert Edge side and sign, Slide Edge sign, Bevel) are **per element**: the partner element's side face is the mapped side face, so mirrored sides come out mirrored and not flipped.
4. Afterwards, `apply_symmetry` with the original side's new vertices as primary.
5. Then `rebuild_symmetry`.

#### 2.6.4 `core/form/primitives.gd` (pure cage builders; Stage 1 T)

Each builder returns a valid cage in local coordinates (centred as described), with outward counter-clockwise faces.
- The caller transforms it by the placement frame with `transform_vertices` and an `xf`.
- Then it adds symmetry entries with `primitive_symmetry(...)`.
- Exact counts are in 3.2.

```gdscript
static func box(size: Vector3, counts: Vector3i) -> Dictionary                  # centred at origin; counts = faces along x, y, z
static func plane(size: Vector2, counts: Vector2i) -> Dictionary                # in XY, centred, normal +Z
static func cylinder(diameter: float, height: float, around: int, rows: int, caps := "pole") -> Dictionary   # axis +Z, base at z=0; caps "pole" | "ngon" | "open"
static func sphere(diameter: float, around: int, rows: int) -> Dictionary       # centre at origin, poles on ±Z (triangle fans)
static func torus(major_diameter: float, minor_diameter: float, around: int, tube: int) -> Dictionary  # in XY around Z
static func quadball(diameter: float, span: int) -> Dictionary                  # cube span x span per side, vertices projected onto the sphere
static func primitive_symmetry(c, kind: String, frame: Transform3D, axes: Vector3i, circular_count: int) -> Dictionary
```

`primitive_symmetry` adds mirror entries for the flagged local axes (plane through the frame origin, normal = that frame axis) or one circular entry (axis = frame Z) with the given count. It then runs `rebuild_symmetry`.

### 2.7 C6: `ui/form_editor.gd` (the Form environment; Stage 2 team E)

A `RefCounted`, constructed as `FORM_EDITOR.new(workspace, viewport)` right after the sketch editor in `forge_workspace._init`. It mirrors the sketch editor's public API, so the workspace hooks look alike.

#### State

```gdscript
var active := false
var suspended := false
var feature: Resource                  # the open form feature (always re-found by id after a recompute)
var feature_id := ""
var selection: Array[Dictionary] = []  # {"kind": "vertex"|"edge"|"face"|"body", "body": body_id, "index": int, "pair": Vector2i (edges)}
var hover := {}                        # same shape, or {}
var tool := ""                         # running tool id ("" = none); "edit_form" while the gizmo is up
var tool_values := {}
var tool_picks := {}                   # pick key -> Array of picks
var _subd := {}                        # body_id -> {"subd": RefCounted, "topo_hash": int, "content_hash": int, "tess": Dictionary, "topo": CAGE.Topo}
var _preview := {}                     # body_id -> scratch cage shown instead of the stored one while a tool previews
var _drag := {}                        # gizmo / rubber-band drag state
```

#### API (called by the workspace)

| Function | Behaviour |
|---|---|
| `begin(f)` | If the feature lies after the timeline marker (index ≥ `doc.active_count()`), flash `"Move the timeline marker past <label> to edit it."` and return. Otherwise set the feature and set `workspace.form_preview = f.id`. If the last recompute was not a preview of this form, call `workspace.recompute()`. Set `viewport.mouse_handler = handle_mouse`. Call `workspace.toolbar.set_workspace("Form", true)` (locked). Show the palette. `refresh(workspace.result)`. Flash `"Form: select cage faces, edges or vertices. Finish Form converts the bodies."` |
| `end()` | Cancel the tool. Commit a pending drag. Clear the meshes (`viewport.set_form_meshes([])`). Reset `mouse_handler`. Hide the palette. `toolbar.set_workspace(workspace.workspace)`. `workspace.form_preview = ""`. `workspace.recompute()` (converts and bakes). `active = false`. Flash the conversion result: `"Form finished: 2 bodies converted"`, or the error |
| `suspend()` / `resume()` | When a workspace command opens over the form (Measure, Construct plane, ...). Like the sketch editor: keep the meshes and release the mouse handler. On `resume()`, take the handler back |
| `refresh(result)` | Called at the end of every `recompute`. Re-find the feature by id (call `end()` without recompute if it is gone). Sync `_subd` using `FORM.effective_cage(stored, ctx)`: new body → instantiate `CadSubD`; topology hash changed → `set_cage`; content changed → `set_positions`; removed body → drop. Bodies hidden in the browser (`doc.body_visible(id) == false`) are neither drawn nor pickable. Prune the selection to existing elements. Rebuild the display. Redraw the overlay |
| `refresh_view()` | Display-mode change only: rebuild the display meshes without touching the subd caches |
| `body_ids() -> Array` | Cage body ids of the open form |
| `draw(overlay: Control)` | Overlay drawing (section 6). Called from the workspace's `viewport.draw_handler` lambda. **Never set `draw_handler` yourself** |
| `handle_mouse(event) -> bool` | Returns true for every left press, release and motion it consumes, so the viewport does no body picking of its own. Returns false for middle and right buttons and wheel, so navigation and the marking menu keep working. When a tool requests a body, face, edge, plane or sketch pick, call `viewport.pick_at()` or `workspace.picker` |
| `handle_key(event) -> bool` | Called **before** the workspace's ctrl/alt/meta guard |
| `start_tool(id)`, `cancel_tool()`, `tool_ok()`, `on_panel_values(values)` | The tool engine (C7) |
| `delete_selection() -> bool`, `select_all()`, `invert_selection()`, `clear_selection()` | Routed from `run_action` while active |
| `context_entries(at) -> Array[Dictionary]` | Marking-menu entries: Edit Form, Insert Edge, Subdivide, Crease, UnCrease, Display Box / Control Frame / Smooth, Finish Form |
| `apply_theme(colors: Dictionary)` | Store tokens, rebuild materials and the palette style |

#### Selection model and picking (algorithm; meets the hover budget of ≤ 4 ms on 5000 faces)

- A selection item references a body plus a vertex index, a face index or an **edge vertex pair** (`pair`).
- The `index` of an edge is only a cache for the current `Topo`.
- Selection is editor state. It is never stored in the document and never placed in `workspace.selection`.

Picking honours `viewport.filters` (vertex, edge, face, body), `viewport.priority`, `viewport.select_mode` and `viewport.select_through`. It works per body, by display mode:
1. **Face.** `subd.ray_hit(from, dir, mode)` with mode 0 for Smooth and mode 1 for Box or Control Frame. Keep the nearest hit over all visible form bodies.
2. **Vertex.** Project candidate points with `viewport.project`:
   - Box and Frame use cage positions; Smooth uses `tess.vertices` (limit points).
   - Candidates are the hit face's vertices plus every vertex within `PICK_RADIUS_PX` on screen. A global scan of projected positions is cheap for 5000 vertices.
   - Reject hidden points with `subd.visible()` unless select-through is on.
3. **Edge.** Box and Frame: screen distance to the projected cage segments of the hit face's edges and its neighbours. Without a face hit, or near a silhouette, scan every edge's projected midpoint within 3·radius first, then measure the segments. Smooth: the same with the limit polylines from `tess.edge_points` / `edge_ids`.
4. Resolve priority with `core/picking.gd PRIORITY_ORDER`. Body = the hit body.

Clicks and drags:

| Input | Effect |
|---|---|
| Click | Replace the selection |
| Shift-click or Ctrl-click | Toggle |
| Click on empty space | Clear |
| Drag from empty space | Region selection, `viewport.select_mode` window/freeform/paint. Left-to-right takes items fully inside; right-to-left takes any item crossed. Test visibility with `subd.visible()` in one batched call |
| Double-click edge | `edge_loop` |
| Double-click face with nothing else selected | Whole body (`kind: "body"`) |
| Face selected, then double-click an adjacent face | `face_loop(first, second)` |
| Shift+double-click a vertex adjacent to the selected one | `vertex_loop` |
| Shift+double-click a non-adjacent element in the same row | `range_select` |

Partners: selecting an element also draws its symmetry partners in the partner colour (section 6). Partners are not added to the selection, because the tools propagate on their own.

Keys while active (handled before the workspace guard):

| Key | Action |
|---|---|
| Alt+1 / Alt+2 / Alt+3 | Display Box / Control Frame / Smooth for the bodies of the selection, or all bodies |
| Alt+P | Loop |
| Alt+O | Loop grow |
| Alt+L | Ring |
| Alt+K | Ring grow |
| Alt+J | Ring shrink |
| Shift+Up / Shift+Down | Grow / shrink |
| Alt+M | Range |
| Alt+N | Invert |
| Alt+H | Feature selection |
| Ctrl+A | Select all |
| Delete | Delete (3.3.27) |
| Enter | `tool_ok` |
| Esc | Cancel drag, then cancel tool, then clear selection, then nothing (staged like the sketch editor) |

The workspace's `tool_for_key()` looks up `CATALOG.for_shortcut("Form", letter)` while active.

#### Display (`ui/form_display.gd`, a helper the editor owns)

The editor turns each body's tessellation and cage into mesh entries for `viewport.set_form_meshes()` (C8). Section 6 has colours and materials.

| Mode | What is drawn |
|---|---|
| Box | Cage faces fan-triangulated, flat normals, `form_box_face`. Cage edges as a 3D line mesh in `form_cage_line` (depth-tested) plus a hidden-edge pass in `form_cage_hidden` (no depth test) |
| Control Frame | Limit surface (`form_surface`, smooth normals from `tess.normals`). Cage edge lines (both passes). Cage points as a POINTS mesh when the vertex filter is on |
| Smooth | Limit surface. Limit edge curves (`tess.edge_points`) as a line mesh in `form_cage_line` with `render_priority` 1 and a 1e-4 x bounds-diagonal offset along the normal |

Always drawn as well, in every mode:
- crease edges (`form_crease`), boundary edges (`form_boundary`);
- frozen faces/edges (`form_frozen`) and buffer vertices (`form_frozen_buffer`);
- isolated faces (`form_isolated` tint);
- symmetry planes as translucent quads sized to the body bounds x 1.2 (`form_symmetry_plane`), and seams (the cage edges whose both ends lie on a mirror plane, or the boundary of circular sectors) in `form_symmetry_line`;
- selection highlights:
  - faces: a mesh built from `tess` triangles whose `face_ids` are selected (Smooth/Frame) or from cage fans (Box), in `form_select_face`;
  - edges and vertices: on the 2D overlay.

Rebuild ArrayMeshes **only when the tessellation changed**. During a drag, tessellate at `rate = max(2, auto_rate / 2)` (the "drag rate"). On release, retessellate at full rate.

**Soft modification preview.** When soft modification is on, call `tessellate({"weights": w})` and colour the surface with vertex colours lerped from `form_surface` to `form_soft_high` by weight. Cage points get the same colours.

#### Palette (floating, like the sketch palette)

`FLOATING_PANEL` with title "FORM" and `set_store(FLOATING_PANEL.default_store(), "form_palette")`, moved under the command panel. Content:
- **Display**: three toggle buttons Box / Frame / Smooth, acting on the selected bodies or all.
- **Display quality**: Draft / Fine.
- **Show symmetry**: checkbox, default on.
- **Conversion quality**: Draft (L4) / Standard (L6) / High (L8). Writes `options.quality` through `workspace.change("Form: Conversion Quality", ...)`.
- Footer: a green **FINISH FORM** button calling `workspace.run_action("finish_form")`.

#### Edit Form gizmo (`ui/form_gizmo.gd`, preloaded by the editor)

The gizmo is drawn and hit-tested on the 2D overlay, **not** as viewport handles. `forge_workspace._on_manipulator_changed` recomputes on every motion, which is too slow here.
- The pivot is the selection centroid (mean of the selected vertex positions).
- The frame depends on the coordinate space:
  - **World**: identity.
  - **View**: camera basis.
  - **Selection**: Z = mean limit normal of the selected faces (or the vertices' limit normals); X = the PCA major axis of the selected positions projected onto the Z plane; Y = Z × X.
  - **Local per entity**: each element moves in its own frame, Z = its normal, about its own centroid.
- Sizes are in pixels (multiply by `viewport._world_per_pixel()` at the pivot depth). All rings and arrows use `axis_x`, `axis_y` and `axis_z`; the hovered handle draws in `handle`, and fills use `handle_fill`.

| Handle (16) | Drawn | Drag effect |
|---|---|---|
| 3 axis arrows | Line from the pivot to 70 px, arrowhead 10 px | Translate along the axis (closest point between the mouse ray and the axis line; `manipulator_math.closest_on_line`). Negative travel allowed |
| 3 plane squares | 10 px squares at (24 px, 24 px) in each axis pair | Translate in that plane (`on_plane`) |
| 3 rotation rings | Circle of radius 55 px in each axis plane; knob 7 px at the ring point nearest the camera-up projection. Hit anywhere within 6 px of the projected ring | Rotate about the axis by the angle swept around the pivot (`angle_on_plane`). Shift snaps to 15° |
| 3 axis scale bars | 12 px dash perpendicular to each axis at 45 px | Scale along the axis: factor = 1 + travel / (45 px in world units). Clamp to ≥ 0.01 |
| 3 plane scale brackets | L-brackets at (38 px, 38 px) in each axis pair | Scale both axes of the plane |
| 1 centre circle | Radius 9 px | Uniform scale: factor = exp(dx_px / 120) |

Rules for every drag:
- Dragging a **selected element itself** (no handle) moves it in the view plane (an addition).
- Grid snapping uses `viewport.snap_step` on translation distances.
- Every drag computes the transform from the **drag-start positions**, never incrementally, so long drags don't accumulate error.

Each motion event:
1. `xf` = the handle's transform about the pivot (Local per entity: per element).
2. Weights: 1 for selected vertices; with soft modification on, `soft_weights` for the others, computed once at drag start; locked vertices 0.
3. `transform_vertices` from the start positions.
4. `apply_symmetry(primary = moved vertices)`.
5. Write the positions into the document cage in place.
6. `subd.set_positions`, `tessellate` (drag rate), update meshes, `viewport.redraw_overlay()`.

On release: `commit_change("Form: Edit Form", before)`.

**Alt-drag.** On the first motion past `DRAG_START_PX` with `event.alt_pressed`:
- **Faces selected**: `extrude_faces` on the doc cage. The new selection is the moved region faces.
- **Boundary edges selected** (all selected edges boundary): `extend_boundary`. The new selection is the outer chain.
- **Ctrl also held**: keep creases. Edges of the moved copy keep the crease flags of the edges they copy, and old region-boundary creases stay on the original rim. Without Ctrl, the moved copies are uncreased.
- Then `subd.set_cage`, and continue the drag on the new vertices. Topology and move are one undo step (the snapshot was taken on press).
- With symmetry, extrude the partner selection too, then `rebuild_symmetry`.
- Alt is only honoured with the translate handles (arrows, squares, free drag) and the plane-scale brackets (scale an extruded ring for inset-like rings).

**Numeric input.** The Edit Form panel carries these fields, all applied as one transform about the pivot on Enter or OK (one undo step each), then reset to neutral:
- X/Y/Z Distance (length);
- X/Y/Z Angle (angle);
- X/Y/Z Scale (number, 1);
- XY/YZ/ZX Plane Scale (number, 1);
- Uniform Scale (number, 1).

Typed scale factors must lie in 0.01..1000 (`FORM_TOOLS.SCALE_RANGE`, also Edit By Curve's); out of range they are refused with a sentence ("X Scale must be from 0.01 to 1000."), never clamped.

**Command panel and gizmo.** The command panel sits top right under the view cube. While Edit Form runs it keeps off the gizmo's screen rectangle (`form_gizmo.screen_rect`): when the gizmo is under it, `form_editor.keep_panel_clear` moves it to the left side (beside or under the palette), else under the gizmo (shorter, its rows scroll), else just left of the gizmo. A new gizmo place (selection, mode, frame) puts it back at its own spot when that is clear; a camera move only moves it when the gizmo runs under it. The command panel can't be dragged, so there is no user position to keep.

### 2.8 C7: the tool engine and `ui/form_tools.gd` registry

The registry is split so that Stage-3 sub-teams never edit the same file:
- `ui/form_tools.gd` (E) holds E's tools. Its `static func spec(id)`, `has_tool(id)` and `run(id, ...)` also look up the `TOOLS` dictionaries of `ui/form_tools_create.gd` (owned by M1) and `ui/form_tools_modify.gd` (owned by M2).
- E creates both of those files in Stage 2 as stubs: `@tool`, `extends RefCounted`, `const TOOLS := {}`.
- Each registry script implements its own `run_<id>` functions. `form_tools.gd` dispatches to the script that declares the id.
- `tools/catalog.gd` preloads `form_tools.gd` (see C9), so the three registry scripts must **never** preload `catalog.gd`, `forge_workspace.gd` or `form_editor.gd`: that would be a cyclic preload. They receive the editor and workspace as arguments.

A spec maps a tool id to:

```gdscript
{
  "title": "Insert Edge",
  "picks": [ {"key": "edges", "label": "Edges", "kinds": ["edge"], "count": -1, "required": true} ],
  #   kinds: "vertex" | "edge" | "face" | "body" (form cage elements) |
  #          "profile" | "sketch_curve" | "model_edge" | "model_face" | "model_body" | "plane" | "axis" | "point" (model picks via viewport.pick_at / workspace.picker)
  "fields": [ ...tools/command.gd field dicts: "expression" (kind length|angle|number), "enum", "bool", "selection", "info", "button" ],
  "defaults": {"location": "0.5", "side": "single", "mode": "simple"},
  "uses_selection": true,      # a current cage selection pre-fills the first pick
  "preview": true,             # live preview on a scratch cage on every value/pick change
  "native": false,             # true: needs CadSubD (disabled with a message when the DLL is absent)
  "repeat": false,             # true: after OK the tool restarts with fresh picks (Face, Insert Point, Weld Vertices)
  "interact": false,           # true: the editor forwards mouse events and drawing to the declaring script:
                               #   static func handle_mouse_<id>(editor, event) -> bool   (true = consumed)
                               #   static func draw_<id>(editor, overlay: Control) -> void
                               # (Face clicks, Insert Point clicks, Edit By Curve control points, Pipe stations, Bridge arrows)
  "handles": false,            # true: static func handles_<id>(editor, values) -> Array of {"type": "arrow"|"count", "key", "origin", "direction", "factor"} drawn and dragged by the editor (distance and count handles)
}
```

Every `run_<id>` has the signature `static func run_<id>(ctx: Dictionary, picks: Dictionary, values: Dictionary) -> Dictionary`.

`ctx` holds `{"feature", "doc", "cages": {body_id: cage}, "subd": Callable(body_id) -> RefCounted, "kernel", "result", "values" (evaluated expressions in meters/radians)}`.

`run_<id>` returns:

```
{"ok": bool, "error": String, "warnings": PackedStringArray,
 "cages": {body_id: cage}            # changed bodies
 "new_bodies": [cage, ...]           # bodies to register (display mode "smooth")
 "removed_bodies": [body_id, ...]
 "breps": {body_id: PackedByteArray} # Convert form -> BRep
 "selection": [selection items], "info": Dictionary}
```

Engine (in `form_editor.gd`), modelled on `sketch_editor` start_tool / `_show_tool_panel` / tool_ok:
- **`start_tool(id)`**: if the spec is native and CadSubD is missing, flash `"<Title> needs the Holo Forge kernel."`. Otherwise:
  1. Pre-fill picks from the selection.
  2. `workspace.panel.setup(title, fields, values, doc.units)`, `set_ok_text("OK")`, `set_hints({})`, `panel.visible = true`, `workspace.place_panel()`.
  3. Flash a one-line hint naming the next pick.
- **Pick routing.**
  - Cage picks come from the editor's own picking.
  - Model picks go through `viewport.pick_at()` (body, face, edge), `start_plane_pick(on_plane, prompt)` for planes (which must **not** end the form, see C9), and `workspace.picker` for profiles, sketch curves and axes.
  - The active pick slot is the first unfilled required pick, or the one the user clicks in the panel.
- **Preview.** Each value or pick change runs the tool's `run_*` on scratch copies and puts the result into `_preview`. Display shows preview cages instead of stored ones, and `info` text goes to `panel.set_info`. Errors are flashed and OK is greyed (`panel.set_hints({"ok_enabled": false})` if supported; otherwise just flash on OK).
- **OK.** Runs the tool once more on the real cages inside `workspace.change("Form: " + title, mutate)`. The mutate closure:
  - writes changed cages;
  - registers new bodies with `doc.new_body(feature.id)` (display default);
  - removes bodies from `options.bodies` and from `doc.bodies`;
  - writes breps.

  Then set the selection from the result, and restart the same tool with fresh picks if the spec has `"repeat": true` (Face, Insert Point, Weld Vertices). Otherwise `cancel_tool()`.
- **Cancel.** Clear `_preview` and hide the panel. Nothing changed in the document.
- **Panel routing.** The workspace forwards OK, Cancel and panel changes to the form editor while `command == null and form_editor.active` (beside the sketch-editor branches in `accept_command`, `cancel_command` and `_on_panel_values_changed`).

### 2.9 C8: viewport API additions (`ui/forge_viewport.gd`, Stage 2 team E)

```gdscript
## Replaces the Form meshes, reusing MeshInstance3D nodes by key: [{"key": String, "mesh": Mesh, "material": Material, "visible": bool}].
func set_form_meshes(entries: Array) -> void
## Swaps one entry's mesh in place (drag updates) without touching the others.
func update_form_mesh(key: String, mesh: Mesh) -> void
```

- Use a dedicated `_form_root` Node3D in `_world`. Never touch `_extra_root` (sketch) or `_command_root` (commands).
- Shadows off.
- `set_sketch_dim(false)` is unaffected. Form bodies are not dimmed.

### 2.10 C9: workspace, catalog, toolbar and plugin wiring (Stage 2 team E; one checklist)

#### `ui/forge_workspace.gd` (find by function name)

1. **`_init`**: `form_editor = FORM_EDITOR.new(self, viewport)` after the sketch editor. Call `form_editor.draw(overlay)` inside the `viewport.draw_handler` lambda.
2. **`set_part`**: `form_editor.end_without_recompute()`, a variant of `end()` that skips the recompute and the bake, used when the part changes.
3. **`recompute`**: pass `{"form_preview": form_preview}` to `REGEN.rebuild`. Skip `part.apply_result` while `form_preview != ""`. Call `form_editor.refresh(result)` next to `sketch_editor.refresh`. Pass form body ids to `browser.refresh`.
4. **`run_tool`**: add a `tool.form` branch before `tool.command`.
   - If `form_editor.active`: `form_editor.start_tool(tool.form)`.
   - Otherwise, when the tool's group is Create: run `create_form()` first, then `start_tool`. Other Form tools flash `"Open a form first: Create Form (Solid > Create) or double-click a Form in the timeline."`.
   - A non-Form tool from another workspace while a form is open: commands of the shared Construct, Inspect and Insert groups run over the form (suspend/resume, like `_runs_in_sketch`). Anything else calls `form_editor.end()` first.
5. **`start_command` / `_end_command`**: suspend and resume the form editor. Restore `viewport.mouse_handler = form_editor.handle_mouse` when active. Move newly created features before the form (C2).
6. **`accept_command` / `cancel_command` / `_on_panel_values_changed`**: forward to the form editor when `command == null and form_editor.active`.
7. **`edit_feature`**: `if feature.type == "form":` end the sketch editor and any command, then `form_editor.begin(feature)`.
8. **`run_action`** gains:

   | Action | Effect |
   |---|---|
   | `create_form` | `create_form()` |
   | `finish_form` | `form_editor.end()` |
   | `form_display_box` / `form_display_frame` / `form_display_smooth` | Display modes |
   | `delete` | Routes to `form_editor.delete_selection()` while active |
   | `select_all`, `invert_selection`, `clear_selection` | Route to the form editor while active |
9. **`start_plane_pick`**: don't call `form_editor.end()`. **`_end_plane_pick`**: restore `form_editor.handle_mouse` when the form is active, and the sketch handler otherwise.
10. **`create_form()`**: new, modelled on `create_sketch`. The preview id must be set **inside** the mutate closure, because `change()` recomputes before returning:

    ```gdscript
    func create_form() -> Resource:
        var created := [""]
        change("Create Form", func() -> void:
            var f: Resource = doc.add_feature("form", "Form", {}, FORM.new_options())
            created[0] = f.id
            form_preview = f.id)
        var feature: Resource = doc.find_feature(created[0])
        if feature != null:
            form_editor.begin(feature)
        return feature
    ```
11. **`handle_key`**: `if form_editor.active and form_editor.handle_key(event): return true` **before** the ctrl/alt/meta guard.
12. **`tool_for_key`**: Form shortcuts while active. `command_search.open(...)` receives "Form" while active.
13. **`_open_marking_menu`**: add `form_editor.context_entries(at)` while active. When a body made by a form feature is selected outside the environment, add an "Edit Form" entry that opens its feature.
14. **`apply_theme`**: `form_editor.apply_theme(c)`.
15. **`_model_of`**: strip `options.display` of form features (C2). **`_refresh_view_data`**: call `form_editor.refresh_view()` when active.

#### `tools/catalog.gd`

- `IMPLEMENTED_PHASE := 6`.
- In Stage 2, add `const PHASE6 := { "<tool name>": "<form id>" }` for **all 47** Form tools (ids below).
- In `all_tools()`, for phase-6 specs without command or action, set `extra["form"]`. Add `"form": str(extra.get("form", ""))` to the tool dictionary.
- `is_enabled()`: a tool with a non-empty `form` is enabled only when `FORM_TOOLS.has_tool(tool.form)`. Use `const FORM_TOOLS := preload("res://addons/holo_forge/ui/form_tools.gd")`; it is a pure static script, so the catalog stays loadable headless. This way Stage-3 teams enable a tool just by registering it and never edit the catalog.
- **Stage 2** registers:

  | Tool name | `form` id |
  |---|---|
  | Box | `box` |
  | Plane | `plane` |
  | Cylinder | `cylinder` |
  | Sphere | `sphere` |
  | Torus | `torus` |
  | Quadball | `quadball` |
  | Edit Form | `edit_form` |
  | Display Mode | `display_mode` |
  | Crease / UnCrease | `crease` / `uncrease` |
  | Freeze / Unfreeze | `freeze` / `unfreeze` |
  | Clear Symmetry | `clear_symmetry` |
- **Stage 3** registers the rest. Pipe, Face and Extrude / Revolve / Sweep / Loft go in `form_tools_create.gd` (M1). Everything else below goes in `form_tools_modify.gd` (M2):

  | Tool name | `form` id |
  |---|---|
  | Pipe | `pipe` |
  | Face | `face` |
  | Extrude / Revolve / Sweep / Loft | `extrude` / `revolve` / `sweep` / `loft` |
  | Edit By Curve | `edit_by_curve` |
  | Insert Edge | `insert_edge` |
  | Subdivide | `subdivide` |
  | Insert Point | `insert_point` |
  | Merge Edge | `merge_edge` |
  | Bridge | `bridge` |
  | Fill Hole | `fill_hole` |
  | Erase and Fill | `erase_and_fill` |
  | Weld Vertices | `weld_vertices` |
  | UnWeld Edges | `unweld_edges` |
  | Bevel Edge | `bevel_edge` |
  | Slide Edge | `slide_edge` |
  | Smooth | `smooth` |
  | Cylindrify | `cylindrify` |
  | Pull | `pull` |
  | Flatten | `flatten` |
  | Straighten | `straighten` |
  | Match | `match` |
  | Interpolate | `interpolate` |
  | Thicken | `thicken` |
  | Mirror - Internal | `mirror_internal` |
  | Circular - Internal | `circular_internal` |
  | Mirror - Duplicate | `mirror_duplicate` |
  | Circular - Duplicate | `circular_duplicate` |
  | Isolate Symmetry | `isolate_symmetry` |
  | Repair Body | `repair_body` |
  | Make Uniform | `make_uniform` |
  | Convert | `convert` |

  Stage-3 tools stay disabled until they are registered. `run_tool`'s flash for a disabled phase-6 tool reads `"<Tool> isn't wired yet."` instead of "arrives in Phase 6".
- Never give Form tools a `type`. Bare `box` or `extrude` would match solid features in `edit_feature`'s lookup.
- Solid > Create: `["Create Form", 6, {"action": "create_form"}]`.
- `_GROUPS.Form`: add `"Finish": [["Finish Form", 6, {"action": "finish_form"}]]` as the last group. The icon resolves to `icons/tools/form/finish_form.svg`.
- Stage 2 adds `["Create Sketch", 2, {"action": "create_sketch", "icon": "Path2D"}]` as the first entry of Form > Create.
  - While a form is open, `create_sketch()` inserts the sketch **before** the form feature, then calls `form_editor.suspend()` and begins the sketch.
  - `finish_sketch` returns to the form with `form_editor.resume()` and recomputes in preview.
- Stage 2 makes Form's Select group `_SHARED_SELECT` plus `["Select Loop", 6, {"action": "form_select_loop"}]`, `["Select Ring", 6, {"action": "form_select_ring"}]`, `["Grow Selection", 6, {"action": "form_select_grow"}]`, `["Shrink Selection", 6, {"action": "form_select_shrink"}]`, `["Select Range", 6, {"action": "form_select_range"}]` and `["Feature Selection", 6, {"action": "form_select_feature"}]`. Each needs an icon or stand-in for the toolbar test; use editor icons via the `icon` key.
- Keep `"Form"` in `WORKSPACES`. `editor_test.gd` expects 7 switcher entries.

#### Other files

- **`ui/toolbar.gd`**: `set_workspace(value: String, locked := false)`. When locked, show the value and disable the switcher even if the value is in `WORKSPACES`.
- **`ui/timeline.gd`**: icon `"form": "SoftBody3D"`.
- **`ui/forge_theme.gd`**: the tokens in section 6, added to `DARK` and `LIGHT` **in the same order** (`holo_forge_theme_test.gd` compares the key arrays).
- **`plugin.gd`**: an editor-test hook constant plus a loader block for `--holo-forge-form-editor-test`, copying the existing hook pattern.
- **Existing tests that must flip** when `IMPLEMENTED_PHASE` becomes 6, because they assert Form is disabled (find these asserts):
  - `holo_forge_editor_test.gd` (Create Form greyed);
  - `holo_forge_insert_editor_test.gd` (form.create.box disabled; keep its Mesh check);
  - `holo_forge_inspect_editor_test.gd`;
  - `holo_forge_surface_editor_test.gd` (3 places);
  - `holo_forge_toolbar_test.gd` (`["Solid", "Create Form", false]` and its "Phase 6" tooltip).

  Change them to assert that Create Form is enabled and that a not-yet-wired Stage-3 tool (until Stage 3) or a Phase-7 Mesh tool is disabled. The toolbar test also requires an icon for every catalog tool, including Finish Form.

---

## 3. Tool-by-tool behaviour

### Conventions used in this section

- **Undo.** Every tool is one undo step named `"Form: <Title>"`, applied on OK, unless stated otherwise.
- **Symmetry.** "Sym" means standard propagation (2.6.3):
  - geometry tools call `apply_symmetry` on the moved vertices;
  - topology tools expand the selection with `partner_selection`, then `apply_symmetry`, then `rebuild_symmetry`.
- **Locked.** "Locked" means the C1 locked-set rule applies.
- **Counts.** Counts are written V/E/F (vertices, edges, faces).
- **Default size `S`.** S is the workspace's `hints.default_size` that Solid primitives use (normally 50 mm). The placement frame is the picked plane: origin at the click, X and Y the plane axes, Z the normal.
- **Ownership.** T = Stage 1 pure ops (`cage.gd`, `form_ops.gd`, `primitives.gd`). E = Stage 2 UI. M = Stage 3 wiring, native-backed parts and sketch creates.

### 3.1 Create Form (Solid > Create) and Finish Form

**Create Form** (action `create_form`):
- Asks for nothing.
- Adds the Form feature at the timeline marker (one step, "Create Form") and enters the environment with an empty form.
- The Form toolbar shows. Create tools start immediately on click.
- If a sketch is open, it is finished first. If a command runs, it is cancelled.

**Finish Form** (action `finish_form`, toolbar Finish block, palette button, marking menu):
1. Ends any tool and commits any drag.
2. Leaves the environment, then runs `recompute()` without preview. This converts every cage body, rebuilds later features and bakes.
3. While converting (more than 300 ms), the status shows `"Converting form bodies..."`. The rebuild is synchronous, so the interactive paths (the palette button, the toolbar's Finish Form, the marking menu) call `form_editor.finish()`: it leaves the environment, flashes the message and converts `FINISH_DELAY_FRAMES` (2) frames later, so the message is drawn first. `form_editor.end()` and `run_action("finish_form")` stay synchronous for the workspace's other callers and the tests.
4. Result:
   - **Success:** flash `"Form finished: <n> bodies converted"` (or `"Form finished (empty)"` for a form with no bodies; the feature stays and warns "Form1 has no bodies").
   - **Failure of any body:** the feature shows its error in the timeline, the other bodies still convert, and the flash names the failing bodies and suggests Repair Body.

Finish makes no undo step.

**Re-entering.**
- Double-click the Form chip in the timeline, or its context menu Edit.
- Or the "Edit Form" marking-menu entry on a selected converted body.

### 3.2 Create tools

All create tools are **editor tools** with a scratch preview. OK adds one body (`doc.new_body(feature.id)`, display "smooth") with the built cage, as one undo step "Form: <Title>".

**Placement (primitives)**
1. The tool asks for a plane through `workspace.start_plane_pick(on_plane, "<Title>: pick a plane or flat face")`: an origin plane, a construction plane or a planar model face.
2. First click: centre (or first corner for 2-Point). Moving the mouse sizes the base. The second click fixes it.
3. Height follows the mouse along the normal; the third click fixes it.
4. All values stay editable in the panel until OK. Typed values update the preview.
5. Arrow handles for distances and double-arrow count handles are drawn by the editor. Counts change by 1 per 20 px of drag.
6. **OK before any click** places the primitive at the origin of the picked plane, or of the XY origin plane when no plane was picked, using the panel values. Headless tests rely on this.
7. Every primitive (and every sketch-based create) has a **Body** field: New Body (default), or one of the form's existing cage bodies. With an existing body, the new cage is appended to it as a separate component (`CAGE.append`), so it can later be bridged or welded.

**Common field: Symmetry.** Values: None / Mirror / Circular (only where listed). Mirror adds per-axis toggles. Circular adds a "Symmetric faces" count that must divide the around count.

| Tool | Fields (defaults) | Cage (local frame) | V / E / F |
|---|---|---|---|
| **Box** | Rectangle Center / 2-Point (Center); Length X (S), Width Y (S), Height Z (S); Length/Width/Height Faces (2/2/2, 1..64); Direction One Side / Symmetric (One Side: base on the plane, height along +Z); Symmetry None / Mirror (Length, Width, Height toggles) | `primitives.box`. Mirror planes pass through the box centre, normals = the toggled frame axes | (nx+1)(ny+1)(nz+1) - (nx-1)(ny-1)(nz-1) / V+F-2 / 2(nx·ny + ny·nz + nz·nx). 1,1,1 → 8/12/6. 2,2,2 → 26/48/24 |
| **Plane** | Rectangle Center / 2-Point; Length (S), Width (S); Length/Width Faces (2/2); Symmetry None / Mirror (Length, Width) | `primitives.plane` in the frame's XY. Open (converts to a surface body) | (nx+1)(ny+1) / nx(ny+1) + ny(nx+1) / nx·ny. 2x2 → 9/12/4 |
| **Cylinder** | Diameter (S), Height (S); Diameter Faces (8, ≥3); Height Faces (2, ≥1); Direction One Side / Symmetric; Symmetry None / Mirror (3) / Circular (count, default = Diameter Faces) | `primitives.cylinder(caps = "pole")`. Each cap is a triangle fan around a pole vertex | n(h+1)+2 / n(2h+3) / n(h+2). n=8, h=2 → 26/56/32 |
| **Sphere** | Diameter (S); Longitude Faces (8, ≥3); Latitude Faces (4, ≥2); Symmetry None / Mirror (3) / Circular | `primitives.sphere`. Vertices on the sphere; poles are triangle fans | n(L-1)+2 / n(2L-1) / n·L. 8,4 → 26/56/32 |
| **Torus** | Diameter 1 (S), Diameter 2 (S/4); Diameter 1 Faces (8), Diameter 2 Faces (6); Symmetry None / Mirror / Circular | `primitives.torus` | n1·n2 / 2·n1·n2 / n1·n2. 8,6 → 48/96/48 |
| **Quadball** | Diameter (S); Span Faces (2, ≥1); Symmetry None / Mirror (3) | `primitives.quadball` (cube grid projected onto the sphere) | 6s²+2 / 12s² / 6s². s=1 → 8/12/6. s=2 → 26/48/24 |

Edge cases: a size of 0 or less greys OK. A circular count that does not divide the around count shows `"Symmetric faces must divide <n>"`.

**Sketch-based creates (Stage 3, M; builders in `core/form/form_create.gd`)**

All sketch-based creates share these rules:
- **Curve chains** come from `workspace.picker` kinds `profile` / `sketch_curve` / `model_edge`, sampled with `kernel.sample_curve(curve, 1e-6)` (2D polylines mapped to 3D by the sketch frame, as `core/sketch/sketch_data.gd` does) or `CadShape.edge_point_at`.
- **Spacing:**
  - **Uniform:** equal arc length.
  - **Curvature:** equal steps of ∫(1 + (L/2π)|κ|) ds, where L is the chain length.
  - Vertices are always placed at sharp corners of the chain (tangent break above 10°).
- **Keep Creases** (default on): edges generated from sharp profile corners get creases along the sweep direction.
- **Fit surface to curves** (default on; only with the kernel): after building, `subd.interpolate` with targets = the curve samples for the vertices built from them, and all other vertices free. The limit then passes through the curves at the samples. This goes beyond the other app.

| Tool | Picks | Fields (defaults) | Result | V / E / F |
|---|---|---|---|---|
| **Extrude** | profile chain | Distance (S); Direction One Side / Two Sides / Symmetric; Distance 2 (S); Angle (0°, taper); Spacing Uniform / Curvature; Faces around the profile (closed 8, open 4); Front Faces (1); Keep Creases; Fit | Profile copies stepped along the profile plane normal. **Ends stay open** (use Fill Hole) | closed k, m: k(m+1) / k(2m+1) / k·m |
| **Revolve** | profile chain, axis (sketch line, construction axis, linear model edge) | Type Full / Angle (Full); Angle (90°); Direction One Side / Two Sides / Symmetric; Spacing; Profile Faces (4); Around Faces (8); Weld (on: profile samples within 1e-6·size of the axis become one pole, and faces touching it become triangles); Symmetry None / Circular (count = Around Faces); Keep Creases; Fit | Rings around the axis. Angle type gives an open sweep | open profile k segments, both ends on the axis, full, weld: (k-1)n+2 / (2k-1)n / k·n |
| **Sweep** | profile, path chain | Profile Faces (8); Path Faces (8); Spacing (each); Orientation Perpendicular / Parallel; Distance (1.0, fraction of the path); Keep Creases; Fit | Perpendicular frames are rotation-minimizing (double-reflection method) from the profile's plane. A closed path closes the surface along it | k(m+1) / ... / k·m (open path) |
| **Loft** | 2+ profiles (ordered; sketch curves, model edges or points); optional rails (any number) or one centerline | Guide None / Rails / Centerline; Closed (off); Length Faces per span (2); Width Faces (8, or the profile count); Spacing; End condition per profile: Free (default) / Direction (takeoff angle 0°, weight 1.0, 0..10) / Point tip (only for point profiles: pole with a fan); Fit | Every profile is resampled to the same count. Closed profiles are rotated to the start offset with the least twist. Between sections: Hermite interpolation through the sections, displaced to follow rails or oriented along the centerline frames | rings · width as for Extrude |
| **Pipe** | path chain(s) (connected sketch curves or edges) | Global Diameter (S/5); Around Faces (8); Density (segments per curve, default max(2, round(length / diameter))); Start End / End End: Open / Square / Spike (Open); Curve Tolerance (0.01 mm, gap allowed between chained pieces; 0.0001 mm..100 mm); Sections: "Add Section" button, then click on the path; up to 8 stations, each with Position (0..1), Diameter and Angle (twist) fields; Fit | Tube along rotation-minimizing frames. Diameter and twist are cubic-interpolated between stations. **Square**: n-gon cap with its rim creased. **Spike**: one more ring segment converging to a pole at diameter/2 beyond the end. **Branching** (3 or more path ends meeting) is refused: `"Branching pipes aren't supported yet; make one pipe per branch and Bridge them"` | open ends, n around, m segments: n(m+1) / n(2m+1) / n·m. +1 F per square end; +1 V and +n F per spike end |
| **Face** (repeat) | clicks | Mode Simple / Edge / Chain (Simple); Sides Four / Multiple (Four) | See below | +1 face per OK |

**Face tool details.**
- Points are clicks on the active plane (picked first; default = the plane of the face under the first click, else XY) or snaps to existing cage vertices of the open form (within 6 px).
- **Four** sides: 4 clicks. **Multiple**: click until the first point is clicked again (at least 3).
- **Edge** mode: pick a boundary edge (it supplies two corners, reversed for consistent orientation), then 2 clicks.
- **Chain** mode: pick a boundary edge chain, then click an offset point. This gives `extend_boundary` with the new chain moved by (click - chain start).
- Snapped corners reuse vertices. Faces joining two bodies merge them. No snapped corner means a new body.
- The new face's orientation agrees with its neighbours, or faces the camera when standalone.
- A non-manifold result is refused.

### 3.3 Modify tools

#### 3.3.1 Edit Form (E)

Picks: any cage selection (vertices, edges, faces, bodies).

Fields:

| Field | Values (default) |
|---|---|
| Transform Mode | Multi / Translate / Rotate / Scale (Multi) |
| Coordinate Space | World / View / Selection / Local Per Entity (World) |
| Soft Modification | bool (off) |
| Extent | Distance / Face Count / Rectangular Face Count (Distance) |
| Distance | length (2 x the mean length of edges touching the selection) |
| Faces | 2 |
| U Faces / V Faces | 2 / 2 |
| Transition | Smooth / Linear / Bulge (Smooth) |
| Weight | 0..1 (1.0) |
| Numeric | the fields of 2.7 |

**Soft weights** (`form_ops.soft_weights`). Selected vertices get w = 1. Every other vertex gets `w = weight · f(t)`, clamped to 0 at t ≥ 1:
- `f`:
  - Smooth: 1 - (3t² - 2t³);
  - Linear: 1 - t;
  - Bulge: 1 - t².
- Distance extent: t = d / R, where d is the Euclidean distance (doubles) to the nearest selected vertex.
- Face Count extent: t = k / (N+1), where k is the face-ring BFS distance (vertices sharing a face).
- Rectangular: t = max(|du| / Ru, |dv| / Rv) in the Selection-space X/Y frame, with Ru = U·mean edge and Rv = V·mean edge, measured from the nearest selected vertex.
- Locked vertices get 0.

**Result.** Positions only, unless Alt-drag (2.7). Each drag release or numeric apply is one step. Sym. Locked vertices don't move. If every selected vertex is locked, flash `"Those vertices are frozen."`.

Edge cases:
- An empty selection hides the gizmo and flashes `"Select cage faces, edges or vertices to edit."`.
- A body selection moves all its vertices.
- Mixing bodies is allowed: each body's cage is updated.

#### 3.3.2 Edit By Curve (M)

Picks: an open chain of 2 or more connected edges with no branches. A closed loop shows `"Pick an open chain of edges"`.

Fields:

| Field | Values (default) |
|---|---|
| Degree | 1..7 (3) |
| Distribution | Uniform / Edge Length (Edge Length) |
| Planar | off |
| Curve Fit | Control Points / Surface Points (Control Points) |
| Numeric | Distance X/Y/Z, Angle X/Y/Z, Scale X/Y/Z, Plane Scale XY/YZ/ZX (applied to the selected curve control points about their centroid) |

Process:
1. Chain vertices p0..pm in chain order. Parameters ti: i/m (Uniform) or normalized cumulative edge length.
2. Fit a degree-d Bezier curve C (d+1 control points) by least squares to (ti, pi). With Planar on, project onto the best-fit plane first and keep the control points in that plane.
3. Draw C and its control points (overlay).
4. The user selects control points (click, Shift adds) and drags them with a mini gizmo. Translate arrows and plane squares are always shown; rotate and scale only with 2 or more control points.
5. δ(t) = C'(t) - C(t).
   - **Control Points:** pi += δ(ti) for unlocked chain vertices.
   - **Surface Points** (kernel): targets = current limit points + δ(ti), then `subd.fit` (or `interpolate`) with free = the chain vertices and their 1-ring.
   - Sym.

We use deltas (not snapping the chain onto the fitted curve), so the cage doesn't jump when the tool starts.

Undo: clearing the edge selection while the tool is open commits the current chain as one step, and the user can pick another chain. OK commits the last chain.

#### 3.3.3 Insert Edge (T Simple; M Exact)

Picks: 1 or more edges on one body (a loop, ring or partial run).

Fields:

| Field | Values (default) |
|---|---|
| Insertion Mode | Simple / Exact (Simple) |
| Insert Location | -1..1 (0.5); arrow handle along the first rail |
| Insert Side | Single / Both (Single) |

**Side rule (deterministic).**
1. Group the selected edges into connected chains.
2. For each chain, take its edge with the smallest (min, max) pair and orient it a→b so that half-edge a→b lies in that edge's lower-index face. Propagate the direction along the chain.
3. The **positive side face** of each edge is the face that contains its oriented half-edge. Negative locations use the twin's face.
4. Edges with no face on the chosen side are skipped with a warning.

**Simple insert** (`CAGE.insert_edge_loop`). For side face F with the selected edge at corners i (a) and i+1 (b):
- The **rails** are the two edges of F adjacent to the selected edge: (a, F[i-1]) and (b, F[i+2]).
- New points r_a = lerp(a, F[i-1], |t|) and r_b = lerp(b, F[i+2], |t|), in doubles.
- F splits into the quad (a, b, r_b, r_a) and the rest (r_a, r_b, F[i+2], ..., F[i-1]):
  - a quad stays two quads;
  - a triangle becomes a quad plus a triangle;
  - an n-gon becomes a quad plus an (n)-gon.
- Consecutive chain faces share rail points.
- A rail edge whose other face is not in the strip (the end of a partial run) gets the new point inserted into that face, which becomes an n-gon.
- Creases: creased rails stay creased on both halves. The new edge is smooth.
- **Both**: rails on both sides at |t| in one op.

**Exact** (kernel):
1. Simple first.
2. Then 2 iterations of: sample the new limit at 5x5 points in every face touching a new vertex; take `old_subd.closest_points(samples)` as targets; call `subd.fit` with free = the new vertices plus the vertices of the faces touching them.
3. `info.max_deviation` goes to the panel.

Target: a full loop at 0.5 on a regular grid deviates by ≤ 1% of the mean face size.

Counts:
- 1x1x1 cube, one edge, Single 0.5: 8/12/6 → 10/15/7, and the two side faces become pentagons.
- 2x2x2 box, equator loop (8 edges) Single: 26/48/24 → 34/64/32. Both: 42/80/40.

Sym (per-element side faces map). Locked.

#### 3.3.4 Subdivide (T Simple; M Exact)

Picks: faces.

Fields:

| Field | Values (default) |
|---|---|
| Insert Mode | Simple / Exact (Simple; Exact needs the kernel) |
| Specify | off; when on: Length Faces 2 / Width Faces 2 (1..16; applies to quads) |

Result:
- `subdivide_faces`: quads become grids; n-gons and triangles become n quads around the centroid.
- **Exact:** when the picked faces are **all** faces of a component and the counts are 2x2, apply `catmull_clark_step` to that component. This is exact; the limit is unchanged within 1e-9. Otherwise, Simple followed by the Exact fit of 3.3.3.

Counts:
- One face of a 1x1x1 cube, 2x2, Simple: 13/20/9, and 4 neighbours become pentagons.
- Whole cube, Exact: 26/48/24.
- A pentagon becomes 5 quads.

Sym. Locked.

#### 3.3.5 Insert Point (T Simple; M Exact) (repeat)

Picks: a sequence of clicks on cage edges.
- In Smooth mode, a click on a limit edge curve maps to t on its cage edge by polyline arc-length fraction.
- Snaps:
  - within 6 px of an edge midpoint, t = 0.5 (marker dot in `form_preview`);
  - within 6 px of an endpoint, the existing vertex.

Fields: Insertion Mode Simple / Exact.

Result:
- Each new point is created with `split_edge` when it is not a vertex.
- When it shares a face with the previous point, connect them with `split_face`.
- If they share no face, the previous point is dropped and a new chain starts, with the flash `"Points must share a face"`.
- Enter, double-click or OK applies the whole chain as one step.

Counts: two midpoints on opposite edges of one cube face: 8/12/6 → 10/15/7.

Sym. Locked.

#### 3.3.6 Merge Edge (M)

Picks: Edge Group One (a boundary chain), Edge Group Two (a boundary chain, same or another body).

Fields: Maintain Crease Edges (on).

Rules:
- Equal edge counts are required: `"Both groups need the same number of edges"`.
- Pair the vertices along the chains, choosing the direction with the smaller total distance.
- Group-one vertices move onto group two, then `weld`.
- When the two sides would disagree in orientation, flip group one's component first.
- Another body is appended into group two's body; group one's body id is removed.
- Maintain: seam edges are creased when either original edge was.

Counts: two 1x1 planes merged along an edge: 4/4/1 + 4/4/1 → 6/7/2.

Sym. Locked.

#### 3.3.7 Bridge (M)

Picks: Side One and Side Two. Each side is faces (a region with one boundary loop; the faces are removed) or boundary edges (a chain or loop).

Fields:

| Field | Values (default) |
|---|---|
| Faces | segments, 1..64 (1) |
| Twist | integer (0) |
| Follow Curve | optional curve pick |
| Flip Direction 1 / Flip Direction 2 | off / off |
| Maintain Crease Edges | on |

Rules:
- Counts must be equal or whole multiples of each other: `"The sides need the same number of edges, or one a multiple of the other"`.
- Alignment: loop 2 runs against loop 1. Rotate its start to the vertex nearest loop 1's start, plus Twist steps. The flips reverse each side's order.
- Ring positions, for s = j/segments:
  - cubic Hermite from P1_i to P2_i;
  - tangents T1 = n1·D and T2 = -n2·D, where D is the centroid distance;
  - n is the side's outward direction: the removed faces' mean normal, or for edges the in-surface direction pointing away from the adjacent faces.
  - With Follow Curve, the ring centres follow the curve, and the ring shapes are interpolated in rotation-minimizing frames along it.
- Multiples k: the dense side sets the ring count. Faces touching the sparse side are (k+3)-gons.
- Two bodies are merged into one.

Counts: open cylinder n=8, h=1 (16/24/8), bridging its two loops with Faces = 2 gives 24/48/24 (a torus: V - E + F = 0).

Sym. Locked.

#### 3.3.8 Fill Hole (T)

Picks: one boundary edge (selects its loop of n vertices).

Fields:

| Field | Values (default) |
|---|---|
| Fill Mode | Reduced Star / Fill Star / Collapse (Reduced Star) |
| Keep Creases | on (off removes rim creases) |

Modes:
- **Fill Star:** one n-gon.
- **Collapse:** a pole at the loop centroid with n triangles.
- **Reduced Star:**
  - n=3: one triangle. n=4: one quad.
  - Even n ≥ 6: a Coons-patch grid a x b with a = floor(n/4) and b = n/2 - a. Choose the 4 corner vertices by trying every rotation of the side pattern (a, b, a, b) and keeping the one with the largest summed turning angle. For a self-symmetric hole, prefer a rotation that keeps the patch symmetric.
  - Odd n ≥ 5: replace the shortest rim edge's two vertices (vj, vj+1) by a virtual vertex g at their midpoint, moved 25% toward the centroid. Add the triangle (vj, vj+1, g), then grid the virtual even loop of n-1 vertices.
  - Interior positions come from the Coons patch.

Counts on an open cylinder n=8, h=2 (24/40/16), one end:
- Fill Star: 24/40/17.
- Collapse: 25/48/24.
- Reduced: 25/44/20.

For n=6, Reduced adds 0 V, 1 E and 2 F.

Sym: a partner hole is filled too. Locked.

#### 3.3.9 Erase and Fill (M)

Picks: faces. A "Feature" button runs Alt+H feature selection.

Fields: Fill Mode Reduced Star / Fill Star (Reduced).

Result: `delete_faces`, then fill every boundary loop the deletion created. Loops that existed before are left open.

Erasing one face of a 2x2x2 box with Reduced gives back 26/48/24.

Sym. Locked.

#### 3.3.10 Weld Vertices (M) (repeat)

Fields:

| Field | Values (default) |
|---|---|
| Weld Mode | Vertex to Vertex / Vertex to Midpoint / Weld to Tolerance (Vertex to Vertex) |
| Weld Tolerance | length (1% of the mean edge length, shown in document units) |
| Maintain Crease Edges | on |

Picks: two vertices in turn (Vertex to Vertex or Midpoint; any bodies), or many vertices (Weld to Tolerance). Window selection includes hidden vertices because select-through is forced on.

Result:
- **Vertex to Vertex:** the first vertex moves onto the second, then they merge.
- **Vertex to Midpoint:** both move to the midpoint.
- **Weld to Tolerance:** union-find clusters by distance ≤ tolerance, each merged at its average.
- Then `weld`. Bodies are merged when the vertices belong to different bodies.
- Non-manifold results are refused: `"Welding these vertices would make an edge with three faces"`.

Counts: two 1x1 planes side by side with coincident vertices, Weld to Tolerance: 6/7/2.

Sym. Locked.

#### 3.3.11 UnWeld Edges (T)

Picks: edges (double-click selects a loop).

Result: `unweld_edges`. Finish converts each connected component to its own body.

Counts:
- Open cylinder n=8, h=2, middle loop: 24/40/16 → 32/48/16, 2 components.
- One interior edge of a grid: E+1, giving a slit with a 2-edge boundary.

Sym. Locked.

#### 3.3.12 Crease / UnCrease (T)

Picks: edges and/or vertices.

Result:
- Crease: edges get weight 10.0 in `crease_edges`; vertices get weight 10.0 in `corners`.
- UnCrease removes them.
- Already creased or uncreased elements are a no-op, and OK reports `"Nothing to change"` without an undo step.
- V/E/F unchanged.

Sym.

Display: a hint line in the panel says `"Short crease fade near star points and poles"`. Mark the faces around extraordinary vertices that touch a creased edge with the `form_warning` tint while the tool is open.

#### 3.3.13 Bevel Edge (M; topology from T ops)

Picks: edge chains or loops. Every interior chain vertex must be interior with valence 4, otherwise: `"Bevel works along edge loops through four-edge vertices"`.

Fields:

| Field | Values (default) |
|---|---|
| Distance Mode | Ratio / Width (Ratio) |
| Ratio | 0.01..0.99 (0.25) |
| Width | length (0.25 x the mean adjacent edge length) |
| Segments | 1..16 (1) |
| Spacing | Uniform / Parametric (Uniform) |
| Crown | 0..2 (1.0) |

Process:
1. `insert_edge_loop(both=true)` at t = ratio. In Width mode, t per rail = clamp((width/2) / rail length, 0.01, 0.99). This gives outer loops A and B with the original loop O between them.
2. Profile: P(u) = (1-u)²A + 2u(1-u)Q + u²B, with M = (A+B)/2 and Q = M + crown·(O - M). Crown 0 is flat, 1 is rounded, 2 is more convex.
3. Inner loops at ui = i/s (Uniform) or (1 - cos(π·i/s))/2 (Parametric):
   - s = 1: dissolve loop O (`dissolve_edges` on O's chain, then `dissolve_vertices` on its now valence-2 vertices).
   - s = 2: move O to P(0.5).
   - s ≥ 3: insert s-2 more loops along O, then place all inner loops.
4. The original edge's crease is dropped. The new loops are smooth.

Counts on the 2x2x2 box equator loop:
- s=1: 34/64/32.
- s=2: 42/80/40.
- s=3: 50/96/48.

Sym. Locked.

#### 3.3.14 Slide Edge (T)

Picks: edges (works best on loops).

Fields: Slide -1..1 (0), with an arrow handle.

Result:
- Each chain vertex v moves to lerp(v, n, |s|), where n is the rail neighbour on the positive side face (the side rule of 3.3.3). Negative values use the other side.
- Boundary vertices with no rail on that side stay put.
- Topology is unchanged.

Sym. Locked.

#### 3.3.15 Smooth (T)

Picks: faces.

Fields: Amount 0..1 (0.5), with a handle.

Result:
- Vertices = vertices of the picked faces, minus region-boundary vertices (also used by unpicked faces), minus locked vertices.
- 3 iterations of p += amount·(mean(neighbours) - p).
- Crease vertices average only their two crease neighbours. Corners are fixed.

Sym.

#### 3.3.16 Cylindrify (T)

Picks: faces.

Fields: Auto Feature Selection (on: each picked face expands with `feature_faces`).

Per connected band:
1. Axis = the eigenvector of the smallest eigenvalue of Σ area·n nᵀ over the band's faces, through the least-squares centre.
2. Rings = closed edge loops in the band whose edges are most perpendicular to the axis.
3. Per ring of n vertices: centre on the axis at the ring's mean axial coordinate. Radius = the band's mean cage radius. Angles θk = θ0 + 2πk/n, with θ0 the circular mean of (θk_current - 2πk/n) and the order kept.
4. Axial coordinates are kept.

The limit ring radius then equals R·(4 + 2cos(2π/n))/6 at the vertices (uniform cubic B-spline). The test checks this.

Sym. Locked.

#### 3.3.17 Pull (M)

Picks: vertices; Target Bodies (model bodies, when "Select").

Fields:

| Field | Values (default) |
|---|---|
| Target | Auto / Select (Auto: every body in `result.bodies` other than form cages) |
| Pull Type | Control Points / Surface Points (Control Points) |

Result:
- **Control:** `subd.project_to_shape(target, cage points)` for each target, keeping the nearest.
- **Surface:** 3 iterations: limit points of the selected vertices, then targets = projections, then `subd.interpolate(targets, free = selected)`.
- Locked vertices are skipped.
- No targets: `"There is no body to pull to"`.

Sym.

#### 3.3.18 Flatten (T Control; M Surface)

Picks: vertices (at least 3 for Fit, 1 for Plane, 1 for Parallel); a plane (construction plane, origin plane or planar model face) for Plane and Parallel.

Fields: Direction Fit / Select Plane / Select Parallel Plane (Fit); Flatten Type Control Points / Surface Points (Control).

Result:
- Fit = PCA plane of the selected positions. Parallel = the picked normal through the selection centroid.
- **Control:** project vertices onto the plane. Every flattened vertex then lies within 1e-12·size of the plane.
- **Surface:** project the limit points and solve with `interpolate(free = selected)`.

Sym. Locked.

#### 3.3.19 Straighten (T Control; M Surface)

Picks: vertices (at least 2); a Line (sketch line, construction axis or linear model edge) or Two Points as the direction requires.

Fields: Direction Fit / Select Line / Select Parallel Line / Two Points (Fit); Straighten Type Control / Surface (Control); a "Range" button that fills in the vertices between the first and last with `range_select`.

Result: the same pattern as Flatten, onto a line (PCA line for Fit). Points end within 1e-12·size of the line.

Sym. Locked.

#### 3.3.20 Match (M)

Picks: form edges (a boundary chain); Match Edges (sketch curves or model edges, chained).

Fields:

| Field | Values (default) |
|---|---|
| Continuity | G0 / G1 / G2 (G0; G1 and G2 need model edges with an adjacent face) |
| Spacing | Uniform / Curvature (Uniform) |
| Falloff Rows | 0..3 (1) |
| Associative | off |
| Alternate Alignment | button: reverse the mapping |

Process:
1. Sample the target at the chain's vertex parameters, by arc length or curvature spacing. Sketch curves use `kernel.sample_curve(curve, 1e-6)`; model edges use `CadShape.edge_point_at`.
2. **G0:** `subd.interpolate(targets, free = chain vertices)`. The boundary limit then passes through the samples within 1e-9.
3. **G1:** set the first inner row to q1 = p + |d|·t, where d is the old inner-minus-boundary vector and t is the unit direction in the target face's tangent plane, perpendicular to the curve, signed like d.
4. **G2:** also place the second row along t.
5. Falloff rows blend the displacement linearly to 0.
6. **Associative:** append a link to `cage.links`. `form.gd` (both modes) and the editor's display re-apply all links before tessellating or converting, using the current target geometry. The targets must come from features before the form; otherwise `"Associative targets must come before the form in the timeline"`.

Sym. Locked.

#### 3.3.21 Interpolate (M)

Picks: bodies (or a vertex subset).

Fields: Mode Through Cage Points / Cage Onto Surface (Through).

Result:
- **Through:** `subd.interpolate(targets = current cage positions)`. The limit point of each vertex then equals its old position (residual ≤ 1e-9·size on non-singular cages; reported otherwise).
- **Onto:** positions = `limit_points()`.

Sym (symmetric input stays symmetric). Locked vertices are excluded from the free set.

#### 3.3.22 Thicken (T)

Picks: body (or faces of it).

Fields:

| Field | Values (default) |
|---|---|
| Thickness | length (max(1 mm, 0.05 x the bounds diagonal)) |
| Type | Sharp / Soft / No Edge (Sharp) |
| Direction | Normal / Axis (Normal) |
| Axis | axis pick |
| Flip | off |

Result:
- **Open cage:** copy the faces reversed and offset the copy by thickness along the area-weighted cage vertex normals (or the axis; Flip negates). Connect each boundary loop pair with one quad strip.
  - Sharp: crease both rims.
  - Soft: no creases.
  - No Edge: no strip; the copy is a second component.
- **Closed cage:** an offset copy (inward by default, i.e. along -normal unless Flip), not reversed, as a second component. It becomes its own body on Finish.

Counts:
- 1x1 plane, Sharp: 4/4/1 → 8/12/6 with 8 crease pairs.
- 2x2 plane: 9/12/4 → 18/32/16.

Sym. Locked vertices are not offset; refused when any boundary vertex is locked.

#### 3.3.23 Freeze / Unfreeze (T)

Picks: faces, edges or vertices. Unfreeze also has an "All" button.

Result: add or remove their vertices in `frozen`. The display shows frozen and buffer colours immediately. No geometry change.

#### 3.3.24 Delete (Delete key and context menu; T)

| Selection | Effect |
|---|---|
| Faces | `delete_faces` |
| Edges | `dissolve_edges` (a boundary edge deletes its face) |
| Vertices | `dissolve_vertices` |
| Body | Remove it from `options.bodies` and `doc.bodies` |

One step `"Form: Delete"`. Sym. Locked.

Deleting one face of a cube gives 8/12/5 (open). Dissolving an interior edge of a 2x2 plane gives 9/11/3.

### 3.4 Symmetry tools

#### 3.4.1 Mirror - Internal (M)

Picks: Face 1 and Face 2 (one on each side). Optional Edge 1/2 and Vertex 1/2 refine the hint.

Fields:

| Field | Values (default) |
|---|---|
| Possible Symmetries | enum, filled from `detect_mirror` (first = best) |
| Tolerance | length (1e-4 x the bounds diagonal) |
| Snap Exactly | on: `symmetrize` |

Result: append a mirror entry and build its map. Vertices on the plane are projected onto it.

If nothing is found: `"No mirror symmetry found within the tolerance; pick a face on each side"`. Several entries per body are allowed.

#### 3.4.2 Circular - Internal (M)

Picks: Face (1 or 2).

Fields: Possible Symmetries (`"<n> around <axis label>"` from `detect_circular`), Tolerance, Snap Exactly.

Result: a circular entry with `count = n`, `step = 2π/n`, `open = false`.

#### 3.4.3 Mirror - Duplicate (M)

Picks: body; Mirror Plane (origin plane, construction plane or planar model face).

Fields: Weld (on); Weld Tolerance (1% of the mean edge length).

Result:
1. Append the reflected copy with reversed faces.
2. With Weld, vertices within the tolerance of the plane snap onto it, and each such vertex is welded to its mirror.
3. Add the mirror entry (map v ↔ v', with v ↔ v for welded vertices).
4. Existing entries are rebuilt. Entries left with broken vertices are dropped, with a warning.

Counts: a 1x1 plane with one edge on the plane, Weld: 6/7/2, and the two seam vertices map to themselves.

#### 3.4.4 Circular - Duplicate (M)

Picks: body; Axis.

Fields:

| Field | Values (default) |
|---|---|
| Quantity | 2..64 (4) |
| Angular Spacing | Full / Angle (Full) |
| Total Angle | 180° |
| Weld | on |
| Weld Tolerance | 1% of the mean edge length |

Result:
- Copies k = 1..n-1, rotated by k·step. Full: step = 2π/n. Angle: step = total/(n-1).
- Seam vertices are welded within the tolerance.
- Entry: `count n`, `step`, `open = (Angle and total < 360°)`. The map takes each vertex to its counterpart in the next copy.

Counts: a separate 1x1 plane piece, Quantity 4, no welds: 16/16/4, 4 components.

#### 3.4.5 Clear Symmetry (E)

Picks: bodies (default: the bodies of the selection, else all).

Fields: Separate Bodies (on).

Result: `symmetry = []` and `sym_isolated = []`. With Separate, each extra connected component becomes its own body (new id with `doc.new_body`, its own cage). The first component keeps the id.

#### 3.4.6 Isolate Symmetry (M)

Picks: faces, edges or vertices.

Fields: Mode Isolate / Restore (Isolate).

Result: add or remove their vertices in `sym_isolated`. Isolated faces draw in `form_isolated`.

### 3.5 Utilities

#### 3.5.1 Display Mode (E)

Picks: bodies (optional; none means all).

Fields: Mode Box / Control Frame / Smooth.

Result: OK writes `options.display` as a **view-only** step `"Form: Display Mode"`, with no rebuild (`rebuild_count` unchanged). The same happens through Alt+1/2/3 and the palette.

#### 3.5.2 Repair Body (M; pure parts in T)

Picks: body.

Fields:

| Field | Values (default) |
|---|---|
| Mode | Fix / Report (Fix) |
| Weld Tolerance | 1e-6 x the bounds diagonal |
| Merge Triangles into Quads | off |

Checks, in order (each fix counted in `info`):
1. Degenerate faces: repeated vertices collapse; faces with fewer than 3 distinct vertices or area below 1e-12·diag² are removed.
2. Duplicate faces are removed.
3. Coincident vertices within the tolerance are welded.
4. **T-junctions:** a vertex lying inside a boundary edge of a face it isn't in (within the tolerance) is inserted into that face (zips the seam).
5. Non-manifold edges (3 or more faces) are split by duplicating vertices.
6. `orient_consistently`.
7. `compact`.
8. Crease, corner and frozen cleanup.
9. Symmetry rebuild; broken entries are dropped with a warning.
10. Native `check()`: self-intersections are reported, not fixed.
11. Optional triangle-pair merge.

Markers, drawn while the panel is open:

| Severity | Colour | Labels |
|---|---|---|
| error | `form_error` | Degenerate face, Non-manifold edge, Self-intersection, Flipped face |
| warning | `form_warning` | T-junction, Star point (valence n), Triangle, N-gon (n) |
| info | — | Pole |

**Report** mode changes nothing. **Fix** applies on OK.

#### 3.5.3 Make Uniform (M)

Picks: body.

Fields: Quads Only (on); Even Spacing (off); Iterations 1..20 (5).

Result:
- **Quads Only:** `split_to_quads` on triangles and n-gons. Afterwards no face of the body has a count other than 4.
- **Even Spacing:** each iteration moves every free vertex by p += 0.5·(mean - p), projected into its vertex-normal plane. Then 2 refit iterations (targets = `old_subd.closest_points(new limit samples)`, then `fit`) keep the shape. `info.max_deviation` is reported.

Sym. Locked.

#### 3.5.4 Convert (M)

Fields: Direction Form to BRep / Mesh to Form / Face to Form (Form to BRep).

**Form to BRep.**
- Picks: form bodies.
- Result: `subd.to_shapes(...)`. Each component's `to_brep_bytes()` goes to `options.breps` (the first under body_id, the rest under derived ids), and the cage is removed from `options.bodies`.
- The body now shows as a fixed BRep body (pickable as a target, not editable by form tools).
- One step.

**Mesh to Form.**
- Picks: a model body made by an Insert Mesh (`mesh_import`) feature.
- Fields: Merge Triangles to Quads (on); Weld Tolerance.
- Reads the feature's source file with polygons kept. Add `mesh_import.read_polygons(path) -> {"points", "faces"}` in `core/import/mesh_import.gd`. Today OBJ polygons are fanned into triangles; keep the existing path unchanged and add this one. OBJ keeps n-gons; STL and PLY triangles go through `merge_triangle_pairs`.
- Then weld, orient, validate, and add a new cage body. The source body stays.

**Face to Form.**
- Picks: model faces.
- Fields: Grid U and Grid V (auto = clamp(ceil(edge length / (0.15·diag)), 3, 16)); Fit (on).
- Result: `subd.face_grid(...)` gives a grid cage. With Fit, `interpolate` over all vertices so the limit passes through the samples; boundary interpolation makes the boundary curves pass through the edge samples.
- Faces that aren't four-sided give the error from `face_grid`.
- Several faces give separate bodies, unless coincident boundary samples weld them (within the tolerance) into one.

### 3.6 Selection helpers (E; logic in T's Topo)

Loop, Loop Grow, Ring, Ring Grow, Ring Shrink, Grow, Shrink, Range, Invert and Feature are available:
- as keys (2.7);
- as entries in the Form > Select group: add `["Select Loop", 6, {"action": "form_select_loop"}]` and the like to `_GROUPS.Form.Select` in Stage 2;
- as buttons in the Edit Form panel ("button" fields).

Each changes only the editor selection. No undo step.

---

## 4. Stages, teams and file ownership

A team may edit **only** the files listed for it in its stage. If you need a change in another team's file, write the request in your report and stub around it.

Stages run in order: 1, then 2, then 3. Inside a stage, the teams run in parallel. Each stage ends with every listed test passing, plus every pre-existing `holo_forge_*` test and `validate_project.gd` (6 known violations only).

### Stage 1 (two teams in parallel)

#### Team N: native subdivision, conversion, CMake

| Files | |
|---|---|
| Edit | `N/CMakeLists.txt`, `N/src/register_types.cpp`, `tests/holo_forge_native_smoke_test.gd` (CadSubD check only) |
| New | `N/src/cad_subd.h`, `N/src/cad_subd.cpp`, optional `N/src/subd_convert.h/.cpp` and `N/src/subd_bvh.h/.cpp`, `N/research/phase6_proto/*` (copied from the scratchpad, not compiled), `A/licenses/OpenSubdiv-Modified-Apache-2.0.txt`, `tests/holo_forge_subd_native_test.gd` |

- **Relies on:** C1 (the cage dictionary) only. Build the test cages inline in the test as literals: cube, pentagonal prism, 2x2 plane, 8x6 torus, noisy 3x3 cube with seeded offsets, two disjoint cubes, a non-manifold fan.
- **Delivers:** C3 in full.
- **Order:**
  1. `set_cage` + `tessellate` + `limit_points` + `evaluate`.
  2. `to_shapes` (direct shell for quads first, then n-gon halves, then the sewing fallback).
  3. `ray_hit`, `visible`, `closest_points`.
  4. `interpolate`, `fit`.
  5. `project_to_shape`, `face_grid`, `check_cage`.
- **Close Godot before every build.**

#### Team T: pure topology and tools (GDScript, headless)

| Files | |
|---|---|
| New | `A/core/form/cage.gd`, `A/core/form/form_ops.gd`, `A/core/form/primitives.gd`, `tests/holo_forge_form_cage_test.gd`, `tests/holo_forge_form_ops_test.gd` |

- **Relies on:** C1 only. No native calls.
- **Delivers:**
  - C4 in full.
  - C5 in full: every pure tool function named in section 3 for T, with the signature of 2.6.1, plus the symmetry and primitives code.
  - The function names used by the editor: `form_ops.edit_transform`, `extrude_region`, `extend_edges`, `insert_edge`, `subdivide`, `insert_point`, `fill_hole`, `unweld`, `crease`, `uncrease`, `slide_edge`, `smooth`, `cylindrify`, `flatten`, `straighten`, `thicken`, `freeze`, `unfreeze`, `delete_elements`, `clear_symmetry`, `isolate_symmetry`, `mirror_duplicate`, `circular_duplicate`, `add_mirror`, `add_circular`, `repair` (pure parts), `bridge`, `merge_edge`, `weld_vertices`, `erase_and_fill`, `bevel_edge`.

  T writes the pure topology for Bridge, Merge Edge, Weld, Erase and Fill and Bevel too. M2 only wires them and adds the native parts.

### Stage 2 (team E: the environment)

| Files | |
|---|---|
| New | `A/core/features/form.gd`, `A/ui/form_editor.gd`, `A/ui/form_gizmo.gd`, `A/ui/form_display.gd`, `A/ui/form_tools.gd`, `A/ui/form_tools_create.gd` (stub), `A/ui/form_tools_modify.gd` (stub), `A/icons/tools/form/finish_form.svg`, `tests/holo_forge_form_test.gd`, `tests/holo_forge_form_editor_test.gd`, `tests/holo_forge_form_editor_create_checks.gd` (stub), `tests/holo_forge_form_editor_modify_checks.gd` (stub) |
| Edit | `A/core/regen.gd`, `A/ui/forge_workspace.gd`, `A/ui/forge_viewport.gd`, `A/ui/forge_theme.gd`, `A/ui/toolbar.gd`, `A/ui/timeline.gd`, `A/tools/catalog.gd`, `A/core/manipulator_math.gd` (add `ring_hit(screen_pos, center, axis, radius_px, project) -> bool` and a scale-factor helper), `A/plugin.gd`, the five existing tests listed in C9, both runner scripts |

- **Relies on:** C1-C5 from Stage 1 (merged).
- **Delivers:** C2, C6, C7 (engine, registry and stubs), C8 and C9.
- **Tools registered:** Box, Plane, Cylinder, Sphere, Torus, Quadball, Edit Form (with soft modification, Alt-drag, numeric input), Display Mode, Crease, UnCrease, Freeze, Unfreeze, Clear Symmetry, Delete. Also the selection helpers, Create Form, Finish Form, Create Sketch inside a form, and the palette.
- The check stubs are `RefCounted` scripts with `static func run(ws) -> Array` (failure strings). The editor test calls them and merges their failures, so Stage-3 teams add in-editor checks without editing E's test.

### Stage 3 (team M: remaining tools; may split into M1 and M2 in parallel)

#### M1: sketch-based creates

| Files | |
|---|---|
| New | `A/core/form/form_create.gd`, `tests/holo_forge_form_create_test.gd` |
| Edit | `A/ui/form_tools_create.gd`, `tests/holo_forge_form_editor_create_checks.gd` |

Tools: Extrude, Revolve, Sweep, Loft, Pipe, Face.

#### M2: modify, symmetry, utilities and Convert

| Files | |
|---|---|
| New | `A/core/form/form_fit.gd`, `tests/holo_forge_form_tools_test.gd` |
| Edit | `A/ui/form_tools_modify.gd`, `A/core/import/mesh_import.gd` (add `read_polygons` only), `A/core/features/form.gd` (only the body of the `_apply_links(cage, ctx)` stub, for associative Match; the rest of E's code stays), `tests/holo_forge_form_editor_modify_checks.gd` |

Tools: Edit By Curve, Insert Edge, Subdivide, Insert Point, Merge Edge, Bridge, Fill Hole, Erase and Fill, Weld Vertices, UnWeld Edges, Bevel Edge, Slide Edge, Smooth, Cylindrify, Pull, Flatten, Straighten, Match, Interpolate, Thicken, Mirror - Internal, Circular - Internal, Mirror - Duplicate, Circular - Duplicate, Isolate Symmetry, Repair Body, Make Uniform, Convert. This includes the Exact modes and surface-point modes, through `form_fit.gd`.

Rules for both sub-teams:
- **Relies on:** C3 (native, incl. `fit`, `closest_points`, `project_to_shape`, `face_grid`, `check_cage`), C4, C5 and C7's registry, interact and handles hooks.
- **Bug fixes** in Stage 1/2 files during Stage 3 go through one owner per file. M2 owns `cage.gd` and `form_ops.gd`. M1 owns `form_editor.gd` and `forge_workspace.gd`. Each owner keeps the earlier stages' tests green.

---

## 5. Acceptance tests (numbers to assert)

Every headless test:
- extends `SceneTree`, runs from `_init() -> call_deferred("run")`;
- uses preload consts only;
- prints exactly one `PASS holo_forge_<name>: ...` or `FAIL holo_forge_<name>` line plus the failure reasons;
- calls `quit(0|1)`.

Native-dependent checks skip with a printed note when `ClassDB.class_exists("CadSubD")` is false. They must not be skipped on the dev machine. **The PASS line must list what was checked.**

### 5.1 `tests/holo_forge_subd_native_test.gd` (N)

| # | Check | Assertion |
|---|---|---|
| 1 | **Sphere-like limit** (the acceptance item). Cube cage [-1,1]³ (8 vertices, 6 quads), `tessellate({"rate": 16})` | Every vertex radius r satisfies \|r - 0.852766\| / 0.852766 ≤ 0.02. Also min r ≥ 0.8394 and max r ≤ 0.8661 (true range 0.839506..0.866025) |
| 2 | Exact limit values | `limit_points()`: every corner = (±0.5, ±0.5, ±0.5) within 1e-9 per coordinate. `evaluate` at the centre (0.5, 0.5) of the +X face = (68/81, 0, 0) within 1e-9 |
| 3 | **Crease stays sharp** (acceptance). Same cube, crease weight 10 on one edge. Evaluate the normals of the two adjacent faces at the edge midpoint (each face's boundary uv) | Angle ≥ 60° (prototype 81.3°). Without the crease: ≤ 0.5° |
| 4 | Crease survives conversion | Converted BRep `face_normal_at` the edge midpoint on the two named faces: angle ≥ 60° |
| 5 | **Convert gives a closed solid** (acceptance). Cube cage, isolation 6 | `to_shapes` returns 1 shape. Report: `closed`, `solid` and `valid` true, `method == "direct"`. `solid_count() == 1`, `is_surface() == false`. 6 faces named `<prefix>/f0..f5` |
| 6 | Volume matches the limit | Within **0.1%** of the fine-mesh volume (`tessellate` rate 64, divergence theorem in GDScript), and 2.620419 within 0.05% |
| 7 | N-gons. Pentagonal prism (2 pentagons + 5 quads) | Closed valid solid, 15 faces (5 quad faces + 2x5 sub-faces named `f<i>.<k>`), volume within 0.1% of the fine mesh |
| 8 | Open cage. 2x2 plane | One shape with `is_surface() == true`, 4 faces, report `closed == false`, `free_edges == 8` |
| 9 | Torus 8x6 | Closed valid solid, volume within 0.1% of the fine mesh |
| 10 | Components. Two disjoint cubes | 2 shapes, both valid solids |
| 11 | Tessellate contract | All keys present. `edge_pairs` equals the canonical order computed in GDScript. `face_ids` in range. Every normal of the cube cage has dot(normal, position) > 0 (outward). Winding matches `CadShape.tessellate` of a box (the same triangle orientation test) |
| 12 | `ray_hit` from (5,0,0) direction (-1,0,0) | Hits the +X face. distance = 5 - 68/81 within 1e-6; point within 1e-6 |
| 13 | `closest_points`: 300 seeded random points within ±0.2 of the noisy 3x3 cube's limit | 0 failures against dense rate-48 sampling (excess ≤ 1e-6) |
| 14 | `interpolate`: sphere cage (8x4 primitive literal, 26 vertices) with targets on the unit sphere | Max \|limit - target\| ≤ 1e-9 |
| 15 | `interpolate` on the singular cube | Finite result, residual ≤ 1e-6, minimal move ≤ 2.0 (prototype 1.732) |
| 16 | `fit`: 3x3 plane cage, targets lifted by +0.1 in z at 16 locations, all vertices free | Residual ≤ 1e-6 |
| 17 | `project_to_shape` onto `kernel.make_box` | Points above a face land on it within 1e-9 |
| 18 | `face_grid` on a box face | `four_sided == true`, all samples on the face plane within 1e-9. A disc face (`make_sphere`) gives `ok == false` |
| 19 | `check_cage` on the non-manifold fan | `ok == false`, with the shared edge in `non_manifold_edges`. `set_cage` returns false with a non-empty `get_last_error()` |
| 20 | Timing (5.6) | `set_cage` + `tessellate` (1000-face grid cube); cached drag frame (`set_positions` + `tessellate`); `to_shapes` (cube and 1000-face cube) |

### 5.2 `tests/holo_forge_form_cage_test.gd` (T)

- **Primitive counts** (section 3.2 table), each with `validate() == []`:

  | Primitive | V / E / F |
  |---|---|
  | box 1,1,1 | 8/12/6 |
  | box 2,2,2 | 26/48/24 |
  | plane 2x2 | 9/12/4 |
  | cylinder 8,2 | 26/56/32 |
  | sphere 8,4 | 26/56/32 |
  | torus 8,6 | 48/96/48 |
  | quadball 1 | 8/12/6 |
  | quadball 2 | 26/48/24 |

  Outward orientation: signed volume > 0 for the closed ones.
- **Topo:**
  - cube: 12 edges, every valence 3, `is_closed`;
  - 2x2 plane: one boundary loop of 8 vertices;
  - box 2,2,2: the equator `edge_loop` has 8 edges and is closed, an `edge_ring` from an equator edge has 4 edges, and `face_loop` around the middle has 8 faces;
  - `components` of two appended cubes = 2;
  - canonical edge order of the test's numbered cube equals an explicit expected list written in the test.
- **Op counts:** every V/E/F in section 3 that belongs to a pure op. Insert Edge (both cases), Subdivide one face, `catmull_clark_step` (26/48/24), extrude one cube face (12/20/10), `extend_boundary` of one plane edge (1x1 plane: 6/7/2), Insert Point, Fill Hole (3 modes, n=8 and n=6), Bridge (24/48/24), Merge Edge (6/7/2), Weld (6/7/2), UnWeld (32/48/16), Bevel (s = 1/2/3), Thicken (8/12/6 and 18/32/16), Mirror Duplicate weld (6/7/2), Circular Duplicate (16/16/4), Delete (8/12/5 and 9/11/3). Each result must pass `validate()`.
- `compact` remaps creases, frozen, symmetry and isolated vertices (built on purpose with removed vertices).

### 5.3 `tests/holo_forge_form_ops_test.gd` (T)

- **Symmetry mirrors exactly** (acceptance):
  1. Box 2,2,2 with an X mirror (`primitive_symmetry`).
  2. `edit_transform` moves one +X vertex by (0.013, 0.021, -0.007).
  3. Its partner equals `reflect_d` of it within **1e-12** per coordinate, and every other vertex is unchanged bit-for-bit.
  4. Then `insert_edge` on a +X edge: the partner side gets the mirrored loop (counts as for two loops), and `rebuild_symmetry` leaves 0 entries of -1.
  5. Then `extrude_region` on a +X face: the partner face is extruded too, and the map is complete.
- **Circular.** Cylinder 8,2 with circular count 8: moving one ring vertex rotates the other 7 within 1e-12. Isolate one vertex: moving it changes no other vertex, and moving its partner leaves it unchanged.
- **Detection.** `detect_mirror` on box 2,2,2 returns 3 planes (the x, y, z planes through the centre). `detect_circular` on cylinder 8,2 includes counts 2, 4 and 8.
- **Locked.** Freeze one top face of box 2,2,2:
  - the locked set = its 4 vertices plus their 1-ring (the vertices of all faces touching them);
  - `edit_transform` of a locked vertex leaves it unchanged;
  - `insert_edge` through a face with a locked vertex returns the frozen error.
- **Geometry:**
  - Flatten: all points within 1e-12·size of the plane.
  - Straighten: within 1e-12 of the line.
  - Smooth lowers the umbrella-Laplacian energy of the region and keeps region-boundary vertices bit-exact.
  - Cylindrify: ring radii equal within 1e-12; angles equal within 1e-12.
  - Slide 0.5 moves each chain vertex halfway along its rail.
  - Crease and UnCrease round-trip leaves `crease_edges` empty.
- **Soft weights.** Distance extent with R = 1 on a line of vertices at distances 0, 0.25, 0.5, 1.0: Smooth gives 1, 0.84375, 0.5, 0. Linear gives 1, 0.75, 0.5, 0. Bulge gives 1, 0.9375, 0.75, 0.
- **Purity.** No op mutates its input: compare `content_hash` before and after on the input dictionary.

### 5.4 `tests/holo_forge_form_test.gd` (E; the Phase 6 acceptance test, `holo_cad_form_test` in the plan)

1. **Regen.** A document with one Form feature holding the cube cage, scaled to 10 mm half-size.
   - `REGEN.rebuild(doc, kernel)` gives `result.bodies[body_id]` with `solid_count() == 1`.
   - Volume within 0.05% of 2.620419e-6 m³ (half-size 0.01 m: 2.620419 x 0.01³).
   - `result.forms[id].preview == false`.
2. **Preview.** Add a Box feature after the form.
   - `rebuild(doc, kernel, {"form_preview": form_id})`: the cage body is absent, the box body is absent (timeline stops), and `result.forms[id].preview == true`.
   - Normal rebuild: both present.
3. **Cache.** Two rebuilds return the **same** CadShape instance (`is_same`). After `doc.restore(doc.snapshot())` the same instance again. After moving one vertex, a different instance.
4. **Crease end-to-end.** Creased cube edge: the converted faces either side of the edge midpoint differ by ≥ 60°.
5. **Symmetry end-to-end.** Box 2,2,2 with an X mirror, an edit through `form_ops`, conversion: the body's centre of mass has \|x\| ≤ 1e-9 m for a 20 mm box.
6. **Catmull-Clark exactness.** The limit of the cube and of `catmull_clark_step(cube)` agree: 100 random `evaluate` points of the parent are within 1e-9 of the child's limit, by `closest_points` distance.
7. **Headless workspace** (`WORKSPACE.new()` as in `holo_forge_workspace_test.gd`; undo steps read from `ws.last_step`):
   - `create_form()`: last feature type `form`, `last_step.name == "Create Form"`, `form_preview == id`.
   - Box through the tool engine (`form_editor.start_tool("box")`, set values, `tool_ok()`): `last_step.name == "Form: Box"`, exactly one step added.
   - Display mode change: `rebuild_count` unchanged, `last_step.name == "Form: Display Mode"`.
   - `doc.restore(last_step.before)` brings back the earlier display value.
   - `run_action("finish_form")`: `form_preview == ""` and the body is in `result.bodies`.
8. **Old documents unchanged.**
   - Build a document with Box + Fillet + Sketch + Extrude using the same helpers as `holo_forge_solid_features_test.gd`.
   - Record the body ids and volumes from `REGEN.rebuild(doc, kernel)`.
   - The same document rebuilt again (with the new code path and empty options) gives identical ids and volumes (relative 1e-12).
   - `doc.snapshot().keys()` equals the pre-Phase-6 key list written in the test.
   - A saved test resource without forms loads and rebuilds with no warnings.

### 5.5 Editor hook `--holo-forge-form-editor-test` (E, plus M check files)

1. Open `res://tests/holo_forge/forge_editor_test.tscn`, then `set_main_screen_editor("Forge")`, then `ws.add_part_to_scene()`.
2. Solid > Create Form is enabled. Running it puts Form1 in the timeline, shows the Form toolbar (switcher shows "Form" and is disabled) and shows the palette.
3. **Box by synthesized input:** plane pick on XY, then clicks at `viewport.project(...)` points, then OK. The cage has 26 vertices, and `_form_root` has the surface and line meshes.
4. Alt+1, Alt+2, Alt+3 change `options.display` and the mesh set.
5. Click a face at its projected centre: selection kind face. Double-click an equator edge: 8 edges selected.
6. **Edit Form drag** (synthesized press, motion, release on the +Z arrow): the selected face's vertices move by the expected amount (± one pixel's worth). `history()` gains exactly one action. Undo restores the positions exactly. Redo re-applies them.
7. **Alt-drag** on one face of box 2,2,2: V +4, E +8, F +4, as one undo step.
8. **Soft modification** on with Distance R: an unselected vertex at distance R/2 moves by 0.5 x the drag (Smooth transition).
9. **Symmetry:** a box with Length mirror; drag a +X vertex; its partner mirrors within 1e-9 m.
10. **Finish Form:** the part gains a baked MeshInstance3D named after the body. The timeline shows no error. The toolbar returns to Solid.
11. Double-click the Form chip: the environment reopens with the same cage.
12. Undo Create Form while the environment is open: the editor ends cleanly, with no script errors.
13. Switch the theme dark, then light: no errors, and the form materials take the new tokens.
14. **Performance:** 1000-face cage, the editor-side drag frame (handle_mouse motion, through mesh update) measured as a ratio (5.6). Target ≤ 33 ms on the dev machine.
15. Run `holo_forge_form_editor_create_checks.gd` and `holo_forge_form_editor_modify_checks.gd` (M): one in-editor scenario per tool, each asserting the 3.x counts and one undo step.

### 5.6 Timing method

- Use `tests/holo_forge_timing.gd compare(op, calibration)`.
- Calibration for native timings: `kernel.make_sphere(...)` followed by `CadShape.tessellate(...)`. Calibration for GDScript timings: a fixed 200k-iteration float loop.
- At implementation time, measure the op on the dev machine. It must meet the target in 2.4.3 (or 2.5.3 / 5.5).
- Then set the ratio limit to 2 x the measured ratio, and record both the measured milliseconds and the ratio in the test's comment.
- `HOLO_FORGE_TIMING_SLOWDOWN=3` must make each timing check fail. Verify that once.

### 5.7 `tests/holo_forge_form_create_test.gd` (M1) and `tests/holo_forge_form_tools_test.gd` (M2)

- **M1:**
  - Each create's counts from the 3.2 tables on a scripted sketch: a circle profile, a rectangle profile, an arc, a line path, a 3-section loft.
  - Revolve with weld produces poles (valence n).
  - Fit-to-curves: the limit at the sample vertices lies on the curve within 1e-6.
  - A branching pipe is refused with its message.
- **M2:**
  - Every tool in 3.3, 3.4 and 3.5 not covered by T, with its counts.
  - Insert Edge Exact: deviation ≤ 1% of the mean face size (full loop at 0.5 on box 4,4,4).
  - Subdivide Exact on a whole component = `catmull_clark_step` (bit-identical counts, limit within 1e-9).
  - Pull Control: vertices on the target face within 1e-9.
  - Pull Surface: limit points on it within 1e-6.
  - Match G0: boundary limit at the vertex parameters on the target within 1e-6.
  - Match associative: moving the target sketch and rebuilding moves the form boundary.
  - Interpolate Through: residual ≤ 1e-9 (sphere cage).
  - Repair: a crafted broken cage (a duplicate face, a flipped face, an unused vertex, a T-junction, a degenerate face) gives `validate() == []` with the right per-category counts.
  - Make Uniform Quads Only leaves no face with a count other than 4.
  - Convert Form to BRep moves the body into `breps`, and a rebuild shows the same volume.
  - Convert Face to Form on a box face: limit within 1e-9 of the samples.
  - Convert Mesh to Form: an OBJ of 6 quads becomes 8/12/6.

---

## 6. Visual spec (both Forge themes)

### 6.1 New `forge_theme.gd` tokens

Add these after `"profile_hover"`, in this exact order, in **both** `DARK` and `LIGHT`:

| Token | Role | DARK | LIGHT |
|---|---|---|---|
| `form_surface` | Smooth limit surface (lit) | `Color(0.47, 0.50, 0.56)` | `Color(0.70, 0.73, 0.78)` |
| `form_box_face` | Box-mode cage faces (flat, lit) | `Color(0.36, 0.39, 0.45)` | `Color(0.80, 0.83, 0.87)` |
| `form_cage_line` | Cage edges / limit edge curves | `Color(0.82, 0.86, 0.93, 0.85)` | `Color(0.12, 0.14, 0.18, 0.85)` |
| `form_cage_hidden` | Cage edges behind the surface | `Color(0.82, 0.86, 0.93, 0.16)` | `Color(0.12, 0.14, 0.18, 0.14)` |
| `form_point` | Cage vertices | `Color(0.92, 0.94, 0.98)` | `Color(0.10, 0.11, 0.14)` |
| `form_select_face` | Selected faces | `Color(0.12, 0.45, 1.0, 0.55)` | `Color(0.06, 0.33, 0.90, 0.55)` |
| `form_hover_face` | Hovered face | `Color(0.60, 0.80, 1.0, 0.20)` | `Color(0.55, 0.80, 1.0, 0.32)` |
| `form_select_line` | Selected edges and vertices | `Color(0.36, 0.72, 1.0)` | `Color(0.10, 0.45, 0.95)` |
| `form_hover_line` | Hovered edge or vertex | `Color(0.58, 0.84, 1.0)` | `Color(0.25, 0.58, 1.0)` |
| `form_partner` | Symmetry partners of the selection | `Color(0.36, 0.72, 1.0, 0.45)` | `Color(0.10, 0.45, 0.95, 0.40)` |
| `form_crease` | Creased edges, sharp vertices | `Color("#ff8f40")` | `Color("#c8560f")` |
| `form_boundary` | Open boundary edges | `Color("#c9a6ff")` | `Color("#6b3fc2")` |
| `form_symmetry_line` | Symmetry seams | `Color("#3ee0b0")` | `Color("#0f9a74")` |
| `form_symmetry_plane` | Symmetry plane fill | `Color(0.24, 0.88, 0.69, 0.07)` | `Color(0.06, 0.60, 0.45, 0.08)` |
| `form_isolated` | Faces excluded from symmetry (tint) | `Color(1.0, 0.35, 0.42, 0.35)` | `Color(0.85, 0.10, 0.18, 0.30)` |
| `form_frozen` | Frozen faces, edges, vertices | `Color("#7fd8ff")` | `Color("#1b8fc4")` |
| `form_frozen_buffer` | Locked buffer vertices and edges | `Color("#3d7fb8")` | `Color("#0d4f80")` |
| `form_soft_high` | Full soft-modification influence | `Color("#ff7043")` | `Color("#e8501f")` |
| `form_preview` | Tool previews (insert lines, midpoint snap dot) | `Color("#57e389")` | `Color("#13994a")` |
| `form_error` | Repair errors, failed faces | `Color("#ff4d4d")` | `Color("#c41616")` |
| `form_warning` | Repair warnings, short crease fade | `Color("#ffd23f")` | `Color("#a87a00")` |

The gizmo reuses `axis_x`, `axis_y`, `axis_z`, `handle` and `handle_fill`. Region selection reuses `window_box` and `crossing_box`. Run `holo_forge_theme_test.gd` after adding the tokens.

### 6.2 Materials (built in `form_display.gd`, rebuilt on `apply_theme`)

| Material | Settings |
|---|---|
| Surface | `StandardMaterial3D`, albedo `form_surface`, roughness 0.55, cull back, two-sided off. Open bodies use `cull_disabled` with the back face in `surface_back`, like surface bodies elsewhere. With soft preview on, `vertex_color_use_as_albedo = true` and colours from the per-vertex weights |
| Box faces | Same with `form_box_face`, flat shading (per-face normals in the mesh) |
| Lines (visible) | Unshaded, `form_cage_line`, depth test on, `render_priority` 1 |
| Lines (hidden pass) | Unshaded, `no_depth_test = true`, `form_cage_hidden`, `render_priority` 0 |
| Points | Unshaded, `use_point_size = true`, `point_size` 5 (frame mode, vertex filter on), `form_point` |
| Selected faces | Unshaded, transparent, `form_select_face`, cull disabled, depth test on, `render_priority` 2. Mesh offset along normals by 1e-4 x the bounds diagonal |
| Symmetry plane | Unshaded, transparent, cull disabled, `form_symmetry_plane`, no shadows (like the sketch profile material) |

### 6.3 Overlay drawing (2D, in `form_editor.draw`, every frame)

Order, bottom to top:
1. Symmetry seams: 2 px `form_symmetry_line`.
2. Crease edges: 2.5 px `form_crease`. Sharp vertices: diamonds 7 px.
3. Boundary edges: 2 px `form_boundary`.
4. Frozen elements: 2 px `form_frozen`. Buffer vertices: 4 px dots `form_frozen_buffer`.
5. Hover: an edge 3 px `form_hover_line`; a vertex as a 9 px ring.
6. Selection: edges 3 px `form_select_line`; vertices as 7 px filled dots with a 1 px `handle_fill` outline; partners in `form_partner` with the same shapes.
7. Tool previews in `form_preview`: Insert Edge lines 2 px dashed (6 on, 4 off); Insert Point midpoint dot 6 px; Bridge direction arrows; Edit By Curve curve 2 px with control points as 8 px squares (selected filled `handle`).
8. Repair markers: 10 px circles, `form_error` or `form_warning`, with a short label in `note_text` on `note_back`.
9. Soft modification: a circle of radius R at the pivot (Distance extent) drawn 1.5 px `form_soft_high` at 0.6 alpha. Cage points are coloured by weight, lerping `form_point` to `form_soft_high`.
10. The Edit Form gizmo (2.7). The active handle draws in `handle` with a `handle_fill` fill; the other handles in their axis colours at 0.9 alpha.

**Per-draw budget.** Only the selection, hover, previews and gizmo are recomputed per frame. Crease, boundary, seam and frozen polylines are cached in screen space per camera change (`viewport.camera_changed`) and per refresh.

### 6.4 Display-mode look summary

| Mode | What shows |
|---|---|
| Box | Flat cage polygons with crisp `form_cage_line` edges and faint hidden edges. No limit surface |
| Control Frame | Smooth surface, cage edges floating around it (visible and hidden passes), cage points when the vertex filter is on |
| Smooth | Smooth surface with thin limit edge curves. No cage polygon lines |

---

## 7. Risks and decisions

| # | Risk or open question (research confidence) | Decision |
|---|---|---|
| 1 | T-splines are proprietary; Catmull-Clark has no T-points (high) | Catmull-Clark with OpenSubdiv. Simple inserts make n-gons in neighbours. Exact = local least-squares fit (approximate, deviation reported). Whole-component 2x2 subdivide uses an exact CC step |
| 2 | Crease weight in the other app is binary (medium) | UI binary, stored as weight 10.0 (infinitely sharp) in OpenSubdiv format. Vertex creases allowed anywhere |
| 3 | Tangent handles at creases and boundaries (high that they exist) | Not provided |
| 4 | Undo granularity inside Edit Form undocumented (medium) | One step per drag release |
| 5 | Exact converted geometry near extraordinary vertices (high, measured) | Gregory end caps converted to bicubic (watertight; G1 jump ≤ 0.015° at L6). Default isolation 6, "High" 8, "Draft" 4. `EncodeRegularity` at 3e-3 rad |
| 6 | Sewing is slow (37-95x) and fails on n-gon half-edges (high) | Direct BRep_Builder shell with edge pieces keyed by (edge, half). Sewing + ShapeFix only as a reported fallback. **The n-gon direct build was not prototyped**: N must test the prism first, and if it fails, sewing is the reported path for cages containing n-gons until fixed |
| 7 | Vertex-limit matrix is singular for some cages (8-vertex cube) (high) | Tikhonov-regularised normal equations, λ never 0. Residual reported |
| 8 | Closest point robustness (medium) | BVH + Newton + face hopping. Test: 0/300 failures on two cages |
| 9 | Limit stencils at isolation 6 cost 576 ms on EV-dense cages (high); isolation 2 not measured (low) | Use isolation 2 for vertex-corner locations (the Gregory corner equals the limit point). N measures and reports it. If inexact, use `PrimvarRefiner::Limit` stencils via a sparse-weight primvar |
| 10 | Display vs converted mismatch (default Bfr approx level 2 is about 1e-2 off) (high) | Display uses approx level 4 (≤ 0.1% of the bounds diagonal vs conversion). Draft display uses 2 |
| 11 | Cage topology in pmp vs GDScript (plan said pmp) | GDScript `cage.gd` (testable headless, no DLL dependency). pmp not linked in Phase 6. GDScript performance budget: topology ≤ 60 ms and ops ≤ 120 ms at 5000 faces. If exceeded, move the hot loop into `CadSubD` with the same API |
| 12 | Float32 `Vector3` precision (high) | Positions stored as `PackedFloat64Array`. Symmetry math in doubles. Untouched vertices never round-trip through `Vector3` |
| 13 | Large cages bloat the embedded `.tscn` (high) | Accepted for Phase 6 (about 0.4 MB per 5000-face cage). Externalizing cages into a sidecar resource is a follow-up |
| 14 | Conversion cost on every rebuild (high) | Content-keyed LRU cache (16 entries) in `form.gd`, and no conversion in preview |
| 15 | Preview bake would delete baked form bodies and their user materials (high) | No bake while previewing. Bake on Finish |
| 16 | Features created while a form is open would land after it and not exist in preview (high) | Inserted before the form feature (start_command and create_sketch) |
| 17 | Symmetry detection: the other app detects topologically (medium) | Geometric detection with tolerance plus Snap Exactly. Maps rebuilt geometrically after every topology op. Broken partners are reported |
| 18 | Pipe branch junction topology (medium) | Chains only in Phase 6. Branches refused with guidance (Bridge separate pipes) |
| 19 | BRep face to cage for trimmed or general faces needs a quad remesher (high; QuadriFlow MIT is not in vcpkg) | Four-sided faces only in Phase 6. QuadriFlow vendoring is a follow-up (MIT; its deps are Boost/LEMON BSL and pcg32 Apache-2.0, so licences go in `A/licenses`) |
| 20 | Loft G1/G2 end conditions to model faces (medium) | Free, Direction and Point tip only in Phase 6. Tangent/Smooth end conditions are a follow-up |
| 21 | Associative Match ordering (medium) | Links stored in the cage and replayed in regen and display. Only targets from features before the form |
| 22 | Default face counts and soft-modification defaults undocumented (low) | Box 2x2x2, Plane 2x2, Cylinder 8x2, Sphere 8x4, Torus 8x6, Quadball 2. Soft modification off, Distance = 2 x mean edge, Smooth, weight 1 |
| 23 | Crease line style in the other app (dashed?) (low) | Solid orange 2.5 px overlay (our own style) |
| 24 | Gizmo pivot relocation (low that one exists) | Not provided |
| 25 | Audit line numbers drift; regen.gd numbers were wrong (high) | Locate by function name |
| 26 | Rebuild cost: every tool OK replays the whole timeline before the form (medium) | Accepted (same as sketch edits). Drags never recompute until release |
| 27 | Godot point size and line width (lines are 1 px in 3D) (high) | 3D lines for the cage; widths for emphasis come from 2D overlay polylines |
| 28 | Licences | Add OpenSubdiv Modified Apache 2.0 + NOTICE. No pmp licence needed (not linked). Eigen MPL2 is already present |

---

## 8. Report back (every team, end of stage)

- The stage and team completed, and the files touched. **Confirm you touched no file outside your list.**
- The PASS/FAIL lines of every test run, new and pre-existing, plus `validate_project.gd`.
- Build time and DLL size (N).
- Measured milliseconds and ratios for every timing check.
- Each decision in section 7 you could not follow, with the reason.
- Screenshots of the Forge tab in the Form environment, in both themes (E, M).
