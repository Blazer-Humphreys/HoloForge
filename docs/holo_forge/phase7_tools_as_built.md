# Phase 7 Mesh tools as built (team M)

Written 2026-11-12 from team M's Stage 3 report (its sections 3 to 6, unchanged in content). For team U's Stage 4, team C, and the fix round. The section numbers are the report's own.

**Section 7 (the fix round, 2026-11-12) is newer and wins where sections 3 to 6 differ from it.**

## Orchestrator decisions (binding)

a. **Create Mesh Section Sketch.** Team U adds the `MESH_FEATURE.add_section_sketch(doc, result, command.feature)` call in `accept_command` in Stage 4, as team M proposed (section 5, item 1).
b. **`CACHE_ENTRIES` is raised** to 256 in `core/features/mesh.gd`; the 512 MB cap stays (section 5, item 2).
c. **The sentence "<Body> is too large to test for places where it crosses itself in 1 s; if it does, the result is wrong there." stays** (section 6, item 3 of "Not closed").
d. **The items "For team U" 2 to 6** (section 3) go to team U's Stage 4.
e. **The rebuild-wide preview limit** goes to team G's fix round.

## Interfaces other teams use

**The editor checks** (`tests/holo_forge_mesh_editor_checks.gd`, spec 5.5 #13), for U's Stage 4 hook:

```gdscript
const CHECKS := preload("res://tests/holo_forge_mesh_editor_checks.gd")
var failures: Array = await CHECKS.run(workspace)   # [] when all pass
```

- `workspace` is the open Forge workspace with a part and the native mesh kernel.
- Each failure is a string that starts with "Mesh checks: "; it is also printed as `FAIL: Mesh checks: ...`.
- It adds its own model in one undo step ("Mesh Checks Model"), runs one scenario per Mesh tool through `start_command` / `set_command_values` / `accept_command`, and undoes everything at the end.
- Each scenario asserts what the tool made, exactly one undo step named `Mesh: <Title>`, and that undoing it gives the bodies back by digest.
- With an editor it counts steps by the undo history's position (`ws.history()`); without one it reads `ws.last_step` and undoes by restoring the state.
- It does not grep for script errors: the hook does that on its log.
- The Create Mesh Section Sketch scenario fails until decision (a) is in.
- Convert Mesh: Faceted has a scenario (when `core/features/mesh_convert.gd` exists); Prismatic and Organic have none.

**What team C's `core/features/mesh_convert.gd` calls in `core/features/mesh.gd`** (keep these stable): `Run`, `_finish`, `_made_ids`, `_mm`, `_plain`, `named`, `is_time_refusal`, `cache_key`, `time_limit`.

---

## 3. Per tool

**Rules for every tool:**
- Lengths, angles and numbers are `feature.inputs`. An input is read only when the tool's current choices use it; a missing input leaves the native default.
- Angles go to native in degrees. Whole numbers go as int.
- Native option names equal the panel keys unless noted. `algorithm` goes to native as `method`.
- The Manifold and voxel ops get `name` as a token that is replaced on read, so the cache does not depend on the body's name. "The mesh" in N2's sentences becomes the body's name. A sentence that names no body is led by `<Body>: `.

| Tool (`options.method`) | Option keys read, and mapping | Inputs read | 5.2 cases |
|---|---|---|---|
| Insert Mesh (`mesh_import`, `insert.gd`) | `kind`, `linked`, `split`, `units`, `mesh` | placement | #1-4 |
| `tessellate` (G's, unchanged) | | | #5-6 |
| `section_sketch` | `body`, `plane`, `fit` | `tolerance` (0..D/20, checked in the feature) | #7 |
| `close_holes` | `bodies`, `loops` (to native `loops` ids), `fill`, `refine` | `max_edges` | #8-9 |
| `stitch_remove` (native `stitch_and_remove`) | `bodies`, `remove_small`, `remove_inner`, `fix_non_manifold` | `tolerance`; `min_size` only with Remove Small | #10-11 |
| `wrap` | `bodies` (several are merged first; the first body takes the result, the others leave the model) | `detail`, `gap`, `offset` | #12-13, #46 |
| `rebuild` | `bodies`, `algorithm` | `detail` | #14 |
| `generate_groups` | `bodies`, `algorithm` | `angle` (fast), `tolerance` (accurate), `min_size` | #15-16 |
| `combine_groups` (native `regroup({"groups"})`) | `groups` (one body, two or more) | | #17 |
| `create_group` (native `regroup({"triangles"})`) | `selection` (one body) | | #17 |
| `direct_edit` | `bodies`, `mesh`, `input_digest`, `outputs`, `extract_<k>` | | Direct Edit case |
| `remesh` | `bodies`, `selection` (to `triangles`), `mode`, `keep_sharp`, `keep_boundary`, `keep_groups` | uniform: `density`, `edge_length`; adaptive: `min_edge`, `max_edge`, `approx_error`; `iterations`; `sharp_angle` with Keep Sharp | #18-20 |
| `reduce` | `bodies`, `selection`, `target`, `algorithm`, `keep_boundary`, `keep_groups`, `keep_sharp` | the one of `proportion` / `face_count` / `tolerance` the target uses; `sharp_angle` with Keep Sharp | #21-23, #48 |
| `plane_cut` | `bodies`, `plane` (to `origin`, `normal`), `type`, `flip`, `fill` | `offset` | #24-27 |
| `shell` | `bodies`, `direction`, `algorithm` | `thickness`; `detail` for accurate | #28-30 |
| `combine` (native `boolean` or `merge_with`) | `target`, `tools` (B-rep tools tessellated at medium, with the warning), `operation`, `keep_tools`, `new_body`; passes `tool_names` | | #31-33 |
| `smooth` | `bodies`, `selection`, `keep_volume`, `keep_sharp`, `keep_boundary` | `strength`, `iterations`; `sharp_angle` with Keep Sharp | #34-35, #47 |
| `reverse_normal` (native `reverse`) | `mode`, `bodies`, `selection` (to `triangles`, `groups` by name) | | #36 |
| `erase_fill` (native `delete_triangles`, then `close_holes` on `new_loops`) | `selection` (groups become triangles), `fill` | | #37 |
| `align` (native `fit_primitive` + `transformed`) | `source` or `points` (three picks with `at`), `to`, `flip` | `offset` | #38 |
| `texture_extrude` (native `displace`) | `selection` (to `triangles`, and `groups` as ids), `image` (path; the feature loads it), `mapping`, `invert` | `depth`, `tile`, `angle`, `detail` | #39 |
| `separate` | `bodies`, `by` | | #40 |
| `move` (runs `modify.gd _move` through `load()`) | `objects`, `move_type`, `axis`, `from_point`, `to_point`, `copy` | `x y z rx ry rz`, `distance`, `angle` | #41 |
| `scale` (native `transformed`) | `bodies`, `point`, `uniform` | `scale` or `sx sy sz` (0.001..1000, checked in the feature) | #42 |
| `convert_*` | one dispatch to `mesh_convert.gd` when the file exists (`ResourceLoader.exists` + `load`), else "not available in this build" | | C's tests; 5.3 #4 |

**Behaviour decided in the wiring:**
- **Combine.** New Body keeps the target. Tools leave the model unless Keep Tools, B-rep tools included. A cut that takes all of the target away removes the body, with the kernel's warning.
- **Texture Extrude.** Brightness is the mean of red, green and blue (Godot's L8 conversion). The image is kept by path, modified time and size.
- **`reports[feature.id]`.** It holds `op`, `stat`, `warnings` (a list, one sentence each), `bodies` (each op's raw report), and `input.triangles`, `output.triangles`, `output.boundary_edges`, `deviation.max` as plain numbers summed over the bodies. One op on one body also carries the kernel's own report keys.
  - This differs from "the op's `get_last_report()`" on purpose: `separate` reports `output.triangles` as an array, and several bodies need sums. U's stat row reads exactly these keys.
  - `input` and `output` are left out when the open edges cannot be counted in 0.5 s; the panel then counts for itself.
  - A feature that failed has no entry.

**For team U:**
1. **Section Sketch OK** (section 5). The feature's stat line already says "Section: 1 closed and 0 open curves, 54 lines".
2. **Reduce and Smooth have no Sharp Edge Angle field.** Native takes `sharp_angle` (45°, 10..170). The feature reads an input `sharp_angle` (kind angle) when Keep Sharp is on.
3. **Remesh Adaptive, Minimum Edge.** The panel always writes `min_edge` = D/1000. Native refuses a given Minimum Edge that could make more than 150,000 triangles, and only raises its own default. Leave the input out until the user types it, or show the raised value. The feature's stat line prints the `min_edge` / `max_edge` used. Adaptive never fits a 0.5 s preview.
4. **Close Holes, Match Edge Size** is shown only for Smooth, but native uses `refine` for Flat too (Flat without it equals Minimal).
5. **Reduce with a selection.** Proportion and Triangle Count are of the whole body, not of the selection. A selection too small for it is refused: "The selection has 205 of the mesh's 20,480 triangles: it cannot bring the body down to 10,240…". The label does not say this.
6. **A typed value equal to the panel's first automatic value still follows the body.** The Depth showed "1" before a body was picked; I set "1" together with the selection; `adjust_values` took it for untouched and changed it to D/200. Found by the editor checks.
7. The feature adds one check of its own for Remesh: "Maximum Edge (x) must be more than the Minimum Edge (y)." The native sentence named only Minimum Edge.

## 4. Cases changed from the spec's numbers

| Case | Change | Reason |
|---|---|---|
| #7 | The sketch is made by `MESH.add_section_sketch()` after the feature builds. | Section 5. |
| #9 | Largest Hole is the largest hole's edge count minus 1 (38), not 50. | The blob's largest hole has 39 edges, so 50 would close everything. |
| #12 | Detail 1.5 mm, gap 26 mm. The spec's 1 mm / 3 mm is asserted refused ("Wrap would leave about 98 % of Blob out … gaps wider than 6 mm"). | 10.8. |
| #13 | "million cells" is asserted at D/390; D/1000 is asserted as a range refusal ("Detail must be between"). | D/1000 is under the field's range. |
| #13, #20, #47, #48 | "≤ 0.2 s" became a ratio limit. | 5.7. |
| #14 | Rebuild's two kernel warnings (volume change, rounded edges) are listed as expected. | They fire on this fixture by design. |
| #23 | Sentence is "Cube: Triangle Count must be a whole number between 4 and 11." | N2's whole-number form, with the body's name. |
| #26 and 5.3 #2 (Split Body) | One warning is accepted: "Plane Cut made 8 triangles without area." | The z = 10 mm plane passes within a millionth of D of some icosphere corners (N3's documented sliver case). Trim at the same plane is warning-free. |
| #29 | The fast shell of the bracket warns "The wall is off: 85 % of 400 samples…". | This is the "warns" branch of the case. |
| #30 | The fixture is a 20 × 2 × 20 mm slab made with Scale Mesh. | A cube cannot be given a wall thicker than its own range allows. |
| #39 | Tile 10 mm, Detail 0.625 mm. | The default Detail would make about 470,000 triangles on the plate. |
| #44 | 80 values just outside the ranges of 36 fields, stepped 1e-3 relative. `mesh:convert_*` specs are left out. | Those are C's. |
| #45, #46 | Ratio of two rebuilds. | Section 2 of the report: they are ratios of two rebuilds of the same design, not `TIMING.compare`, so `HOLO_FORGE_TIMING_SLOWDOWN` does not apply to them. |
| #48 | Fast Reduce at 1M passes within 2 %, with two honest warnings (80 triangles without area; "crosses itself in 238 places; the input could not be tested in the time left"). | N2's documented behaviour on flat grids. |
| Reduce by 0.01 mm | Asserts the "Nothing could be taken out" outcome. | 10.9. |
| 5.3 #1 | The 0.05 mm tolerance input is present but unused. | The target is proportion; the distance is measured by the test. |

## 5. Wrong or unworkable in the spec

**1. Create Mesh Section Sketch (2.4.1, 3.1.3, C7).**
- **The conflict.** The catalog starts it as a `mesh` feature, but 3.1.3 wants a normal, non-associative `sketch` feature. A feature cannot add another feature while the timeline replays: regen iterates a fixed count, and previews would add sketches too. A `mesh` feature that publishes `ctx.sketches` is not drawn or pickable, because the picker and sketch editor only take `type == "sketch"`.
- **What I built.**
  - The feature computes the section, refuses "The plane does not cut <Body>." and more than 5,000 segments, warns of open curves, and reports. It leaves the body alone.
  - `MESH.add_section_sketch(doc, result, feature, replace := true)` makes the fixed sketch: lines, and arcs with Fit; points shared at joints; note "Made from a section of <Body>". It puts the sketch in the mesh feature's place and removes the mesh feature.
- **Counter-proposal (team U, about three lines in `accept_command`).** For `spec.method == "section_sketch"`, after the final recompute without error and before `commit_change`, call `MESH_FEATURE.add_section_sketch(doc, result, command.feature)`.
- **Until then** the UI's OK leaves a "MeshSection" feature that does nothing visible. The editor check for it fails on purpose with that sentence.

**2. Cache size (2.4.4: 32 entries).** A design with more kept results than that recomputes on every rebuild, because least-recently-used eviction cycles through all of them. Insert Mesh, moved meshes and stored-blob decodes use entries too. I kept the number. Proposal: raise `CACHE_ENTRIES` to a few hundred; the 512 MB cap still bounds memory.

**3. Bodies a tool adds (2.4.3).** Kept to `doc.new_body` and `options.outputs`, with two additions:
- They are registered only on a full-time build. A 0.5 s preview shows them under passing derived ids, so fiddling in a panel registers nothing.
- The allocation table is `options.made` ({slot: ids}), with `made_with` and `made_count`. The "<Feature> now makes n bodies instead of m." warning fires only when the feature's own settings are unchanged (an upstream change took the bodies). After an edit of the feature it counts afresh.

**4. Mesh Align's 1e-9 m.** A `Transform3D` is single precision, so the first move lands a few nanometers off. For a face group the feature measures the residual and takes it out with a second pure shift. The three-point variant is not refined; the test asserts 1e-7 m there.

**5. Plane Cut slivers** on the spec's own acceptance plane (table above).

## 6. Shipping bar: closed, and not closed

**Closed and tested:**
- **Time.** One limit covers the whole feature. Each body's op gets what is left, and the refusal says so: "Two: Rebuild would take about 6.8 s on this mesh (limit 5.405 s). Raise Detail. (The bodies before it used the rest of the feature's 7.096 s: pick fewer bodies at once.)" On error no body changes.
- **Names.** Every kernel error and warning reaches the feature with the body's name.
- **Self-crossing input (10.8 item 6).** Plane Cut, Separate, Merge and Insert's One Body per Piece say "<Body> crosses itself, so the result may be wrong there. Rebuild it first."
- **Replay.** Editing an earlier feature replays the mesh tools after it.
- **Same bodies.** Undo, redo, a rebuild from an empty cache, and save/reload of a `.tres` all give the same digests.
- **Cache.** A second rebuild returns the same instances.
- **Stale picks.** Triangle and hole picks made on an older body are warned, and out-of-range ids are dropped and counted.

**Not closed, or unverified:**
1. Section Sketch from the UI (section 5).
2. The editor checks have not run in a real editor.
3. **Self-crossing test is bounded to 1 s.** On a body too large to test in that time, a full build says "<Body> is too large to test for places where it crosses itself in 1 s; if it does, the result is wrong there." A preview says nothing. That sentence is my addition; it will show on every large Plane Cut or Separate. Folds between neighbouring triangles are not seen by that test at all (10.1 item 8).
4. **Stale hole picks.** Loop ids picked on an older version of a body may now point at other holes. This is warned, not re-found.
5. **No time limit:** `merge_with`, `regroup`, `delete_triangles`, `transformed`, `welded`, and so Move, Scale, Align and Direct Edit (all linear). The report's open-edge count can add up to 0.5 s after the ops.
6. **Plane Cut on several bodies:** one body the plane misses fails the whole feature.
7. **Not value-tested through features:**
   - Texture Extrude's planar and cylindrical mappings and its Rotation.
   - Remesh Adaptive quality (only "builds and is closed").
   - Shell Outside and Both.
   - Close Holes Flat and Minimal on the blob.
   - Combine with more than one tool, and with a component pick.
   - Stitch's Remove Pieces Inside Others.
   - Linked Insert Mesh with a 3MF or glTF file.
   - A Direct Edit blob damaged on disk.
8. **Direct Edit.** The stored mesh is decoded and checksum-checked once a session, then kept by digest.
9. **Name prefix heuristic.** `named()` decides "already names the body" by looking for the name as a word. A body named like a common word could miss its prefix. Cosmetic.
10. **Preview limit is rebuild-wide** (U's finding, 10.10 item 3). With point 2 of section 5, an evicted earlier feature can show a false time refusal in a preview. Not mine to fix.

---

## 7. Fix round (2026-11-12, after the three verifiers)

This section is newer than sections 3 to 6 and wins where they differ. Regression test: `tests/holo_forge_mesh_regress_tools_test.gd` (each case failed before its fix; the failing log is `...\scratchpad\phase7\teamM\logs\mesh_regress_tools_BEFORE.log`).

### 7.1 What changed, per finding

| Finding | Cause | Now |
|---|---|---|
| **F1** Tessellate gave a body another body's face group names | The kept result was keyed by the shape's BRep bytes, which hold no face names | The key also holds a hash of the face names (`_brep_digest`). The same box made by another feature is tessellated afresh and carries its own names |
| **F2** A Direct Edit whose stored mesh file is gone deleted the body, with no error | `options.mesh == null` was read as "every triangle taken out" | A stored mesh that is not there is an error that names the file, and the body stays as it was. "Every triangle taken out" is `options.emptied == true` with no `mesh` key. The same sentence serves Insert Mesh and Direct Edit's extracted pieces |
| **P3** Erase and Fill said it closed a hole it left open | The stat counted the holes asked for; "that hole was filled too" was added whenever the selection touched an open edge | Both are read from Close Holes' own `filled_loops`. A hole left open is counted in the stat; the kernel's warning says why |
| **Stale picks** | A pick with no `digest` was never doubted; a refusal hid the stale-selection sentence | A pick with no digest is checked for triangles the body does not have, and the feature remembers the body it first built on (`options.picked_on`), so a later build on another body warns. A refusal carries the stale-selection sentence behind it |
| **P7** "The bodies before it used the rest…" on one body | The self-crossing test ran before the op and used part of the limit | That test now runs after the op (or the kernel's own count is used). The sentence is added only when earlier bodies took more than 1 % of the limit |
| **Crossing notes** | Only Plane Cut, Separate and Merge were tested | Combine (target and every tool), Shell and Texture Extrude too. Each body is told once, by name; a kernel sentence that names the body stands in place of ours |
| **Separate's report** | No tally was made | `input.triangles`, `output.triangles` and `output.boundary_edges` are published |
| **Reader warnings** | Insert Mesh read only the reader's error | The reader's warning comes through with the file's name, for stored and linked inserts |
| **F6** Linked mesh body over 60,000 triangles switched to Solid | The over-cap case fell into "couldn't be read again", then "holds no triangles" | The true reason, by file name and count |
| **Cache** | A time refusal was kept for what was left of the limit and looked up with the whole limit; a preview's result answered a full-time build | See 7.3 |

### 7.2 Sentences, option keys and report keys that changed (for team U)

**Option keys:**
- `direct_edit`: **`emptied: true`** (with no `mesh` key) now marks "every triangle was taken out". Without it a missing `mesh` is an error. `ui/mesh_direct_edit.gd add_snapshot()` writes neither key for an empty result today, so it must write `"emptied": true` there. (Delete refuses to take every triangle, so the case is hard to reach.)
- `picked_on` (any tool with a triangle or hole pick that has no `digest`): written by the feature on a full-time build, `{"<body id>:<hash of the pick>": digest}`. Panels need not write or read it; picks made in the panels carry a digest and never use it.
- `mesh_import` (mesh body, not linked): `read_warning`, the reader's warning kept with the stored mesh.

**Return values:**
- `INSERT.read_mesh_body()` and `INSERT.add_mesh_import(..., KIND_MESH)` have a `"warning"` key (the reader's, with the file's name; "" for a whole file). The Insert Mesh prompt can show it.

**Report keys (`MESH.reports[feature.id]`):**
- Separate now has `input` and `output`.
- Nothing was removed.

**Sentences:**
- Stored mesh gone: "<Feature> holds no stored mesh: its file <file> is missing or can't be read (<path>). Put the file back, or delete <Feature>." For Direct Edit followed by " <Body> stays as it was before <Feature>." When the design names no file: "<Feature> holds no stored mesh (it was not found with the design). Open a copy of the design that still has it, or delete <Feature>."
- Erase and Fill stat: "Erased 2 triangles, closed 0 of 1 hole (1 stays open)", "Erased 1 triangle, closed 1 hole", "Erased n triangles, no hole to close".
- Erase and Fill warning, new: "The selection touches an open edge of <Body>: the hole it leaves runs into that open edge and was not filled." The old "…; that hole was filled too." is said only when it was.
- Behind a refusal, when the selection is stale: "… <Feature>: the triangle selection was made on an older version of <Body>; it may now cover other triangles. Reselect to be sure."
- A result the kernel counted crossings in, when no other sentence says so: "<Body> crosses itself in <n> places after <Tool>; the result may be wrong there. Rebuild it first."
- A Combine that is refused, when an input crosses itself: the kernel's sentence, then "<Body> crosses itself, so the result may be wrong there. Rebuild it first."
- Linked mesh over the Faceted cap, switched to Solid: "The linked mesh <file> has <n> triangles; a faceted solid takes up to 60000 (keep it a mesh body, or reduce it first)". With a copy kept in the design: "The linked mesh <file> now has <n> triangles (a faceted solid takes up to 60000); the copy kept in the design was used".
- The kernel now says one of a thing in the singular ("1 part is inside-out."); section 4's quoted sentences may differ by that.

### 7.3 The cache, as it is now

- **A result** is kept for the feature's time limit. A build with as much time or less gets it. A build with more computes its own: the post-checks of a result had the time of the build that made it, so its warnings may be fewer. **So OK after a preview computes the op again** (it took under half a second the first time) and gets a new instance with the same content.
- **A refusal by time** is kept for the time the op had. The next rebuild that gives it the same or less answers at once. One body alone always gets the whole limit, so its refusal answers at once.
- A later body refused for lack of time is asked once more on the next build, because the earlier bodies' results are kept by then and it has the whole limit. What that gives is kept.
- **Any other refusal** holds whatever the limit.

### 7.4 Not fixed, or not mine

- **Interference with mesh bodies** (`core/mesh/mesh_body.gd`, team G) still does not read the kernel's warning. `MESH.crossing_count(mesh, seconds)` and `MESH.crossing_note(mesh, name, seconds, tell_untested)` are public for it.
- **A result too large to test** (the kernel's `self_intersections` is -1) gets no sentence from the feature; only the kernel's own ones. A positive count always gets one.
- **Stale hole picks** are still warned, not re-found.
- **F2 in the test** takes the stored mesh out of a loaded feature rather than damaging the file, because loading a scene with a damaged file makes Godot print its own "Parse Error" and "ERROR:" lines. The real case (file deleted, emptied, cut to 100 bytes; for Insert Mesh and Direct Edit) was probed by hand with the same result: `...\scratchpad\phase7\teamM\probe_f2_real.gd`, log `teamM\logs\probe_f2_real.log`.
- **`tests/holo_forge_mesh_gate_test.gd`** failed its one known case (the Low-preset ball, team G's, 10.13) when this round began; it passes on the tree of 2026-11-12 evening.

### 7.5 After the kernel's own fix round (N2 and N3, DLL of 2026-11-12 18:39)

- **The same mesh handed back** (Reduce with nothing to take out, Close Holes on a sheet's outline or a closed body, a selection too small): the body stays as it is, the kernel's warning shows with the body's name, and there is no error. This already held; it now has cases in the regression test.
- **Wrap of several bodies.** The kernel sees one merged mesh and has no names. Its sentences now carry all the picked bodies' names ("About 0.015 % of Block, Speck and Ball's surface is not inside the wrap …"), and the feature adds which body is out, from `left_out_parts[i].first_triangle`: "Speck is not in the wrap at all (about 0.015 % of the wrapped surface)." or "2 parts of Speck are not in the wrap (about 3.1 % of the wrapped surface)."
- **Tessellate of several bodies:** a warning is led by the body's name ("Body2: The mesh's volume is 2.3 % off the body's. …"), as its errors already were. One body: the kernel's sentence as it is.
- **Crossing sentences:** Combine, accurate Shell and Texture Extrude now say theirs in the kernel. The feature uses the kernel's counts and adds its own sentence only for a body no kernel sentence names (in practice Plane Cut, Separate, Merge and fast Shell). Nothing is said twice; the regression test counts one sentence a body.
- **Singular forms** ("1 part is inside-out.") are what the tests expect now.

### 7.6 Two follow-ups from team G's fix round (2026-11-12)

- **Face group picks follow their face.** Every `mesh_group` pick a Mesh tool reads (`_targets` in `core/features/mesh.gd`: Combine Face Groups, Reverse Normal, Erase and Fill, Texture Extrude, Mesh Align's source) goes through `MESH_BODY.resolve_group(mesh, pick)`. When an earlier change handed the picked name to another face, the tool acts on the face that was picked and warns "<Feature>'s face group moved from g5 to g4 after an earlier change."; a pick that can't be found fails the feature with team G's sentence, led by the body's name. A pick without `at` still goes by name. (Plane picks on a face group go through `core/references.gd`, team G's.)
- **For team U:** a group pick is followed best when it carries `normal` (how the surface faced where it was picked) beside `at`; with `at` alone it can only be followed while that point is still on the body.
- **Linked files.** A file's stamp (`_stamp` / `_unchanged` in `core/features/insert.gd`) is now its modified time, its size and an md5 of its content, whatever the file's age (`STAMP_WINDOW` is gone). A file changed under the same modified time is read again; a stamp from before (no size, or no md5) counts as changed, so the file is read once more. Cost: each linked file is hashed on every rebuild that looks at it.

### 7.7 Second fix round (2026-11-13)

**Code:**
- **Options of the wrong kind.** `MESH.option_problem(feature)` runs before any Mesh tool reads its options (Tessellate, Move/Copy and Convert Mesh included). A switch that is not true or false, picks that are not a list, a choice that is not text, or a bookkeeping record of the wrong kind is the feature's error with a sentence, and the body is left alone: "Smooth1: Keep Volume must be on or off (it holds "yes"). Open the feature and set it again.", "Smooth1: its picks under 'bodies' can't be read (they are not a list). Open the feature and pick again.", "Reduce1: Target must be one of its choices (…)", "TextureExtrude1: Image must be a file's path (…)". What a pick holds is checked too: triangles that are not a list of numbers, a hole that is not a number. Triangles given as a plain list of numbers are taken. Switches are strict: 1 or "true" is refused, where the kernel alone took them as on.
- **A damaged stored mesh** says what to do next, in team G's words: "The stored mesh of X is damaged (…). Put back a sound copy of <file>, or delete X.", or "… Open a copy of the design that still has it, or delete X." when the design names no file.
- **Close Holes and the outline of an open sheet.** With no hole picked the feature passes no `loops`, so the kernel's outline rule applies: the holes are closed and the outline stays open with its sentence. Picked holes are passed and always closed (an outline with the "looks like the outline" warning).
- **Erase and Fill at a sheet's border.** The gap the erased triangles leave runs into the outline, and a loop named to Close Holes is always closed, which would lay a second surface on the sheet. The feature reads `picked_outline_loops`, leaves those loops open, closes the other holes again without them, and says: "The selection reaches the open outline of <Body>: the gap it leaves is part of that outline and stays open (filling it would lay a second surface on the sheet)." The stat counts it as left open.

**Tests brought in line with the kernel's second round and team G's pick rule** (no check was weakened):
- `mesh_tools` #9: "Blob: 1 hole was larger than Largest Hole and stays open."
- `mesh_tools` #26 and `mesh` #2 (Split Body): no warning now ("without area" is judged by each triangle's own shape); both parts are checked to hold no triangle without area.
- `mesh_tools` #17, Plane Cut by a flat face group, Erase and Fill of a whole piece, #38, #39, and the group picks of the editor checks: written as the panels write them (name, `at`, `normal`), so they build without "could not be confirmed". Reverse Normal of a face group keeps a name-only pick and expects that sentence.

**For team U:** `"emptied": true` is still needed from `add_snapshot()` for an empty result (7.2). No option, return or report key changed in this round; the sentences above are new.
