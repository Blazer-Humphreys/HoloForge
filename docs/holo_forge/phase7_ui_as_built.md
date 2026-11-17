# Phase 7 Mesh UI as built (team U)

Written 2026-11-11 from team U's Stage 2 report (its sections 3 to 8). Brought up to date on 2026-11-12 for Stage 4 and the fix round: the table in section 3 and the lists in sections 4, 7 and 8 now say what the code does, and section 9 lists what changed and why. For team M, who wires the Mesh features against this table, and for the verifier.

## Orchestrator decisions (binding)

1. The Method choice of Rebuild, Generate Face Groups, Reduce and Shell is stored as `options.algorithm`. M passes it to the native op as `method`.
2. M publishes `static var reports` in `core/features/mesh.gd`: `reports[feature.id]` = the op's `get_last_report()` plus an optional `"stat"` string. The panel's stat row reads it.
3. The rebuild-wide preview limit and the 1.45 s bake of a 1M-triangle body go to team G in the fix round.
4. Tessellate's 1 % volume rule against the Low preset goes to team N in the fix round (it will become a warning below 5 %).

---

## 3. Per Mesh tool (for team M)

Shared rules for every tool below:
- Feature type `"mesh"`, `options.method` = the part after `mesh:`.
- **Inputs** are `feature.inputs` expressions (length in meters, angle in radians, number plain). An input exists only once its field has been shown. Everything else is in `feature.options`.
- Body slots store `{"kind": "body", "body": id}` picks, as G's Tessellate does. Read them with `r.bodies(key, true, true)`.
- Other pick formats:
  - `mesh_group`: `{"kind": "mesh_group", "body", "group", "at", "normal"}`
  - `mesh_triangles`: `{"kind": "mesh_triangles", "body", "triangles": PackedInt32Array (sorted), "digest", "at", "normal"}`, one reference per body. Mesh Align's `points` are one reference per click, each with one triangle, `at`, and `weights` (a Vector3: the point's weights at the triangle's three corners; the UI uses it to draw the point on a body the preview has moved, handlers can ignore it).
  - `mesh_boundary`: `{"kind": "mesh_boundary", "body", "loop": boundary_loops() id, "edges", "digest", "at", "normal"}`
  - **`at` and `normal`** are a point on what was picked and the unit facing of the surface there. Every pick a Mesh panel stores has both: a clicked one from the ray's hit, one taken over from the selection from the middle of its first selected triangle that has an area (per face group: the first in that group), a hole from the rim point clicked and a triangle beside it. `MESH_BODY.resolve_group` needs the name and both to follow a face group that an earlier change renamed. A triangle pick's `at`/`normal` are of the triangle clicked last, or of the first one left after a click took one out. The panel does not count `at` and `normal` when it asks whether two picks are the same.
- **Which mesh a pick is made on.** A pick is of the body as the tool works on it: the mesh the body had when the tool started, or, when an existing feature is opened from the timeline, the mesh before that feature (the workspace replays the timeline up to it). `digest` is that mesh's. The preview on screen shows the tool's result, so the same ray is cast at the input mesh; a click that only hits the preview is refused with "That spot is only in the preview...".
- For "Bodies, or a triangle selection" tools, `bodies` can be empty when `selection` is filled: take the body from the selection picks.
- `D` = diagonal of the first picked body (all picked bodies together for Wrap); `T` = its triangle count. Until a body is picked, D is a view-sized fallback and D/T range bounds are not checked.
- `(1)` = single slot. Angle ranges are in degrees in the spec table, radians in the input.

| Tool | Key | Picks (option key: kinds) | Options and defaults | Inputs: default, range |
|---|---|---|---|---|
| Tessellate | `mesh:tessellate` | `bodies`: body | `quality` medium, `relative` false, `keep_original` true | `linear` 0.1 mm, 0.001 mm..D/10; `angular` 15, 1..45 (both custom only) |
| Create Mesh Section Sketch | `mesh:section_sketch` | `body`(1): mesh_body; `plane`(1): plane, mesh_group | `fit` false | `tolerance` D/2000, 0..D/20 |
| Close Holes | `mesh:close_holes` | `bodies`: mesh_body; `loops`: mesh_boundary | `fill` smooth, `refine` true (shown for smooth and flat) | `max_edges` 0, 0..100000 whole |
| Stitch and Remove | `mesh:stitch_remove` | `bodies`: mesh_body | `remove_small` true, `remove_inner` false, `fix_non_manifold` true | `tolerance` D×1e-5, 0..D/100; `min_size` 1, 0..50 |
| Wrap | `mesh:wrap` | `bodies`: mesh_body | none | `detail` D/150 raised to fit the grid, D/400..D/10; `gap` 2×detail, detail..D/4; `offset` 0, −gap..D/10 |
| Rebuild | `mesh:rebuild` | `bodies`: mesh_body | `algorithm` union | `detail` D/250 raised, D/600..D/10 |
| Generate Face Groups | `mesh:generate_groups` | `bodies`: mesh_body | `algorithm` accurate | `angle` 20, 1..90 (fast); `tolerance` D/2000, D×1e-6..D/20 (accurate); `min_size` 10, 1..100000 whole |
| Combine Face Groups | `mesh:combine_groups` | `groups`: mesh_group | none | none |
| Create Face Group | `mesh:create_group` | `selection`: mesh_triangles | none | none |
| Remesh | `mesh:remesh` | `bodies`: mesh_body; `selection`: mesh_triangles | `mode` uniform, `keep_sharp` true, `keep_boundary` true, `keep_groups` true | `density` 0.5, 0.01..1; `edge_length` 0, 0 or D/2000..D/5; `min_edge` empty ("auto": no input while the field is empty, so the kernel keeps its own default), >0 and <max_edge once typed; `max_edge` D/50, >min_edge..D/5; `approx_error` D/2000, D×1e-6..D/20; `iterations` 10, 1..50 whole; `sharp_angle` 45, 10..170 |
| Reduce | `mesh:reduce` | `bodies`: mesh_body; `selection`: mesh_triangles | `target` proportion, `algorithm` adaptive, `keep_boundary` true, `keep_groups` true, `keep_sharp` false | `proportion` 50, 1..99; `face_count` T/2, 4..T−1 whole; `tolerance` D/2000, D×1e-6..D/10; `sharp_angle` 45, 10..170 (with `keep_sharp`) |
| Plane Cut | `mesh:plane_cut` | `bodies`: mesh_body; `plane`(1): plane, mesh_group (flat only) | `type` trim, `flip` false, `fill` uniform | `offset` 0, −D..D (arrow handle, may go negative) |
| Shell | `mesh:shell` | `bodies`: mesh_body | `direction` inside, `algorithm` accurate | `thickness` D/50, D/2000..D/4; `detail` thickness/4 raised, thickness/10..thickness/2 |
| Combine | `mesh:combine` | `target`(1): mesh_body; `tools`: mesh_body, body | `operation` join, `keep_tools` false, `new_body` false | none |
| Smooth | `mesh:smooth` | `bodies`: mesh_body; `selection`: mesh_triangles | `keep_volume` true, `keep_sharp` false, `keep_boundary` true | `strength` 0.5, 0..1; `iterations` 5, 1..50 whole; `sharp_angle` 45, 10..170 (with `keep_sharp`) |
| Reverse Normal | `mesh:reverse_normal` | `bodies`: mesh_body (whole, auto); `selection`: mesh_group, mesh_triangles (selection) | `mode` auto | none |
| Erase and Fill | `mesh:erase_fill` | `selection`: mesh_triangles, mesh_group | `fill` smooth | none |
| Mesh Align | `mesh:align` | `source`(1): mesh_group; `points`: mesh_triangles, one reference per click with `at`, 3 at most; `to`(1): plane | `flip` false | `offset` 0 |
| Texture Extrude | `mesh:texture_extrude` | `selection`: mesh_group, mesh_triangles | `image` "" (a file path; M loads it), `mapping` box, `invert` false | `depth` D/200, −D/10..D/10 not 0; `tile` D/5, D/1000..10D; `angle` 0, −360..360; `detail` tile/128, tile/512..tile/8 |
| Separate | `mesh:separate` | `bodies`: mesh_body | `by` components | none |
| Move/Copy | `mesh:move` | `objects`: mesh_body; `axis`(1), `from_point`(1), `to_point`(1) | `move_type` free, `copy` false (Solid Move's own keys, so `modify.gd move` can be shared) | `x y z rx ry rz` 0; `distance`; `angle` 90 |
| Scale Mesh | `mesh:scale` | `bodies`: mesh_body; `point`(1): point | `uniform` true | `scale`, `sx`, `sy`, `sz` 1, 0.001..1000 |
| Convert Mesh: Faceted | `mesh:convert_faceted` | `bodies`: mesh_body | `merge_flat` true, `result` new_body | `flat_tolerance` D×1e-6, 0..D/100 |
| Convert Mesh: Prismatic | `mesh:convert_prismatic` | `bodies`: mesh_body | `allow_spheres` true, `result` new_body | `tolerance` D/1000, D×1e-6..D/20 |
| Convert Mesh: Organic | `mesh:convert_organic` | `body`(1): mesh_body | `output` brep, `result` new_body | `faces` 500, 24..5000 whole; `tolerance` D/500, >0..D/10 |

**Exercised end to end (Stage 2):** Tessellate only. Since Stage 4 every tool runs in the editor hook `tests/holo_forge_mesh_editor_test.gd`, by real input for the ones listed in section 9 and through team M's 24 scenarios for the rest.
- Prefilled from the selection; preview with stat row `Triangles: 12 / Open edges: 0`; Keep Original off; Enter; undo step `Mesh: Tessellate`; edit from the timeline.
- A custom refinement gave `Tessellate would take about 16 s on this body (limit 0.5 s)...`; the stat row said `Preview skipped (too slow); press OK to compute.` in 21 to 33 ms; OK then computed it in 8.8 to 12.7 s with the full limit.
- Range refusals, in degrees and document units.

**Panel-only in Stage 2**, because their handlers answered "not available in this build" then (all are wired now):
- All 25: panel opens, every row exists, stat row present, feature has the right method, shown expression fields are inputs, notes and buttons are not written as options, Cancel leaves nothing.
- Reduce: defaults follow the body (T/2 = 6, D/2000); typing 150 into Keep with real keys is kept as typed, refused with `Keep must be between 1 and 99.`, OK off.
- Wrap: Detail at least D/150; an untouched Gap follows a typed Detail.
- Shell: a real click picks the mesh body and Thickness becomes D/50.
- Close Holes: a real click near an open edge picks its loop.
- Create Face Group: starts with the window-selected triangles; a click adds one, the same click takes it out.
- Plane Cut: plane pick; arrow dragged below zero; the removed side drawn; Keep Other Side shows the other part; a round face group refused.
- Convert Faceted and Reduce: opened from the body menus with the body picked.

**Other panel behaviour:**
- The stat row is an `"info"` row with key `"stat"`, replaced through `panel.set_info`. It reads `MESH.reports[feature.id]`: `Triangles: a → b (p%)` from `input`/`output`, `Open edges`, `Max deviation`, then the report's `stat` line and the feature's warning. A convert (no `input`/`output`) shows `Bodies made: n` and its `stat` line. A preview refused for time shows `Preview skipped (too slow); press OK to compute.` and is not shown as an error in the status line.
- An "optional" field (Remesh's Minimum Edge) may stay empty; its placeholder and hint say "auto" (with the value the kernel used, when a report has it).
- A typed value is the user's, also one typed the same as the value the panel had chosen (`mark_typed`, `set_command_values(values, typed := [])`); an untouched one follows the picked body.
- Undo step names are exactly `Mesh: <Title>`, with no `Forge: ` prefix. A mesh-kind Insert Mesh is `Mesh: Insert Mesh`.
- A Mesh tool's rebuilds pass `mesh_time_limit = PREVIEW_SECONDS` and `mesh_preview_feature` = the id of the tool's feature (so only that feature gets the short limit, once `core/regen.gd` reads it); OK rebuilds once with the full limit before checking errors. `ws.last_mesh_limit` shows which was used.
- OK of Create Mesh Section Sketch calls `MESH.add_section_sketch(doc, result, feature)`; OK of Convert Mesh: Organic with Output Form Body calls `MESH_CONVERT.form_body(doc, feature)`. Both after the full-time rebuild and before the commit: one undo step each.
- While a Mesh tool is open the workspace skips the bake; OK's own rebuild bakes.
- A Mesh panel with no visible text field gives the keyboard to the view, so Enter and Escape work.

## 4. APIs

**`ui/mesh_selection.gd`** (RefCounted; `workspace.mesh_selection`; shapes are passed in as `{body id: CadMesh}` from `workspace.mesh_shapes()`):
- `mode` is `"groups"` or `"triangles"`; `set_mode(value, shapes)`; `signal changed`; `hover`.
- Stored as triangles per body, sorted and unique, with the mesh digest. In group mode every change is grown to whole groups.
- `click(pick, shift, ctrl, shape)`: plain toggles, Shift adds, Ctrl removes, an empty click clears.
- `add`, `remove`, `set_triangles(body, triangles, shape)`.
- `select_region(body, shape, planes, crossing, remove)`, `paint(body, shape, point, radius)`.
- `grow(shapes)`, `shrink(shapes)`, `connected(shapes, angle = 30)`, `boundary(shapes) -> loops taken`.
- `as_picks(shapes)`, `static triangle_pick(body, triangles, shape)`, `prune(shapes)`.
- `clear()`, `is_empty()`, `count()`, `bodies()`, `triangles_of(body)`, `groups_of(body, shape)`, `static triangle_groups(shape)`.

**`ui/mesh_display.gd`** (RefCounted; `viewport.mesh_display`):
- `apply_theme(palette)`; `materials`: `surface`, `surface_open`, `group_0..7`, `wire`, `border`, `boundary`, `selected`, `hover`, `removed`, `fill`, `preview`. All are StandardMaterial3D; no custom shader.
- `group_colors(shape)`: greedy, in group order, neighbours differ. `group_mesh(tess, shape)`: up to 8 surfaces, one per colour, kept by digest. `group_mesh_colors(mesh)`, `static group_neighbours`.
- Static: `border_mesh`, `boundary_mesh`, `boundary_count`, `boundary_segments`, `selection_mesh(tess, triangles)` (up to 4,096 triangles as a mesh of their own corners, so a hovered triangle of a million-triangle body costs 0.35 ms, not 35), `wire_mesh`.

**Viewport additions:** `mesh_wire`, `last_region`, `region_planes(rect)`, `mesh_hit_at`, `mesh_surface_material`, `mesh_line_nodes`, `mesh_highlights()`, `boundary_overlay_count()`, `drag_kind()`, `mesh_triangle_points(body, triangle)`. Highlights accept `mesh_group`, `mesh_triangle` and `mesh_triangles` picks.

**Workspace additions:** `mesh_shapes()`, `active_kinds()`, `refresh_picks()`, `set_mesh_hover(ref)`, `run_mesh_select(action)`, `toggle_mesh_face_groups()`, `start_direct_edit()`, `delete_mesh_triangles()`, `mesh_body_entries(body)`, `run_tool_on_body(name, body)`, `refresh_bodies()`, `show_bodies_with(overrides)`, `mesh_face_groups`, `last_mesh_limit`, `set_command_values(values, typed := [])`, `bodies_before(feature_id)` (the model before a feature: the timeline replayed up to it on a scratch copy), `mesh_tool_rect()` (the screen rectangle of the bodies the open Mesh tool works on), `static counted(value, one, many := "")`.

**Command (`tools/feature_command.gd`) additions:** `mark_typed(key)`, `is_untouched(key, values)`, `auto_hint(field, values)`, `note_input(before)` (an edited feature's input bodies), `picked_bodies(values)`, `shown_point(ref)`, `triangles_shown(body, pick)`, `preview_meshes(values)` (looks `removed`, `fill`, `selected`), `static counted(...)`; sentences `ONLY_IN_PREVIEW`, `PREVIEW_SKIPPED`, `NOT_A_MESH`, `NOT_FLAT`, `NEAR_AN_EDGE`.

**Panel (`ui/command_panel.gd`, U's since the fix round):** `set_values(values, changed_elsewhere := [])`, `ensure_row_visible(key)`; a click on the active slot leaves it active.

**Timeline:** `refresh(features, active, errors, warnings := {})`; `static wrapped(text, width := 78)`.

**What Direct Edit stores** (`ui/mesh_direct_edit.gd`, `static add_snapshot(doc, body, mesh, input_digest, steps, pieces)`): one feature, type `"mesh"`, label `DirectEdit<n>`, with:
- `method`: `"direct_edit"`
- `bodies`: `[{"kind": "body", "body": id}]`
- `mesh`: MeshBlob of the result
- `input_digest`: the body's digest when the tool opened
- `steps`: PackedStringArray of `delete`, `fill`, `flip`, `extract`, `move`
- `outputs`: ids of the bodies Extract made, registered in the document
- `extract_<k>`: one MeshBlob per output, at top level so `save_mesh_blobs` sees it

Undo steps: `Mesh: Direct Edit`; Delete with triangles selected outside the tool stores the same with steps `["delete"]` as `Mesh: Delete Triangles`.

In the probe: delete, fill (closed only the new hole), Ctrl+Z, flip, extract, move, Done, Escape-cancel and Delete all worked on the working mesh. In the hook: delete, fill, Ctrl+Z, a dragged Move arrow and Done, as one feature in one undo step.

Limits of Direct Edit as built:
- Move is three axis arrows that start at the middle of the selection, not a free gizmo. It is applied through `get_arrays`/`set_arrays` in GDScript.
- Fill is minimal only.

## 5. Icons

I drew all 8 files of 6.3 in the house style (24x24, stroke 1.6, round caps, ink `#dfe3ea`).

**Accent:** the spec says the existing mesh icons use `#e0a526`, but `remesh.svg`, `reduce.svg`, `close_holes.svg` and the rest use `#22b8cc`. I matched the files (cyan), with `#d14fc0` for arrows as the house does, and `#ff5d8f` for the boundary dash.

**What I compared:**
- Rendered side by side at 96 px and 24 px, dark and light ink, with the house's `shell`, `combine`, `remesh`, `reduce`, `close_holes`, `window_selection`, `paint_selection`, `select_all`, `generate_face_groups` and `display_mesh_face_groups` (`teamU\shots\icons_*.png`).
- Against the other app's icons from memory only. I had no screenshots from the user and downloaded nothing. As I recall them, its mesh Shell and Combine show shaded 3D solids (a hollowed body, two overlapping solids) and its selection tools are not strip drawings. Mine are flat line drawings: a five-triangle dome with an inner outline, two circles with three chords each, a three-cell triangle strip with a cursor, arrows or ripples, and a dashed pink outer edge. I found none close.

Nothing was redrawn for closeness. One redraw was for legibility: picked triangles are now drawn over the lines at 0.75 opacity. The cursor glyph is the house's own, from `window_selection.svg`.

## 6. Contract problems and decisions needed

1. **`method` key clash.** 2.4.1 puts the tool in `options.method`, and section 3 names the Method choice of Rebuild, Generate Face Groups, Reduce and Shell `method` too. The panel would overwrite the tool name. I store those four as `options.algorithm` (label "Method"). M must pass it to the native op as `"method"`.
2. **No channel for the op report.** The stat row should be filled from `last_report`, but nothing carries it from the handler to the panel. The panel already reads `MESH.reports[feature.id]` if `core/features/mesh.gd` has a `static var reports`: the `get_last_report()` dictionary plus an optional `"stat"` string (for example Stitch's "Welded n vertices..."). Until M publishes it, the row falls back to counting triangles on the result bodies and open edges through `check(0.25)`. Please have M add it.
3. **The preview limit is rebuild-wide.** While a Mesh tool previews, every mesh feature in the timeline gets 0.5 s. Earlier features answer from the cache; if one was evicted (32 entries, 512 MB) it would show a "would take" error in the preview only. Counter-proposal for G: pass the id of the previewed feature and give only that one the short limit.
4. **Low refinement on a sphere is refused.** Tessellate at Low on a 50 mm sphere gave `The mesh's volume is 2.3 % off the body's (more than 1 %). Raise the Refinement.` The Low preset and the 1 % must-hold disagree. Orchestrator, N or G to decide.

For G, not a contract problem: `nodes/cad_part.gd apply_result` (the bake) takes about 1.45 s per rebuild for a 1M-triangle mesh body. I avoid it only during Mesh tool previews; every other rebuild still pays it.

## 7. Deviations I chose

- **Pick-time gate.** It fires for Solid and Surface feature commands (types not in `REGEN.MESH_AWARE`) on a click that hits a mesh body. Exceptions: inspect commands; MESH_AWARE types; a flat face group for a plane slot (a round one gets "isn't flat", an axis slot gets `AXIS_GATE`). Checked with Fillet and Offset Plane. Tessellate refuses a mesh body at pick time with `ALREADY_MESH`.
- **Mode toggles.** "Shows as pressed" is done from the workspace: a pinned Select Face Groups or Select Triangles button is toggled, and the SELECT menu items get radio ticks. I did not add them to the default pins (C7 says keep the pins), so by default the mode shows only as a tick in the menu and in the status line.
- **Six selection tools.** Greyed without a mesh body; outside the Mesh workspace they flash where they work.
- **Select Boundary.** `shrink` does not treat an open edge as a boundary, so I use `boundary_loops()` plus `triangles_near` at each loop point: the triangles touching open-edge vertices.
- **Window and lasso.** They use `triangles_in_frustum` on the region; a lasso is its bounding frustum filtered by the outline in GDScript. Without Select Through, back-facing triangles are dropped, and hidden ones only up to 20,000 triangles and only against their own body.
- **Wide open-edge lines.** Drawn on the overlay only up to 1,500 segments per body, hidden only by their own body. The thin 3D lines are always there.
- **Private members of a file I do not own.** The browser's body menu is extended through `browser._context` and `_context_meta`. It works and is fragile; a public accessor in `browser.gd` would be better. (`command_panel.gd` is U's now; the workspace still reads `panel._editors` to watch typing.)
- **Shift+F.** The catalog shortcut is `"Shift+F"`; the workspace handles it only in the Mesh and Utilities workspaces. Elsewhere Shift+F still reaches Fillet as before.
- **Insert Mesh.** From the Mesh workspace (Create or Insert group) the prompt starts on Mesh Body and has a Body Type row. Export STL's dialog also offers OBJ and 3MF; the status line names skipped bodies. `files.export_cad_report()` is new.
- **Extra files, as decision 2 says.**
  - Measure describes mesh bodies, face groups and triangles, shows `note`, and adds the click point as `at` to a mesh body reference.
  - Center of Mass shows the open-mesh `warning`.
  - Interference passes `doc`, shows `note`, and Create Bodies leaves mesh overlaps out with a sentence.
  - A decal on a mesh body is refused with `DECAL_GATE`.
  - `create_base_feature()` gives the gate sentence.

## 8. Unfinished or unverified (as of the fix round, 2026-11-12)

- **Panel placement** uses the bodies' bounding boxes on screen, so a round body counts as wider than it looks. Where no place is clear (the body fills the view, or the room under it is less than the short panel's least height) the panel stays whole inside the view at its own spot, or at the left side when that covers less.
- **Mesh Align's dots** follow a preview that only moved the body's points (same triangle count and face group names). After a preview that changes the triangles they stay where they were picked.
- **Editing an existing feature** replays the timeline up to that feature once when it is opened. That costs about one rebuild of the design. Stale hole picks are still only warned by the feature, not found again.
- **A handle drag and the focused field.** A press in the view takes the keyboard from the panel's field, so a mouse drag never meets a focused field in the Mesh panels. `set_values(values, changed_elsewhere)` covers values set from code. The Form environment's own `panel.set_values(tool_values)` calls (`ui/form_editor.gd`, not U's) do not pass the dragged keys.
- **Section Sketch** draws no section curve in its preview (the spec does not ask for one), and has no hook check of its own beyond team M's scenario.
- **The hook's save part does not save through the editor.** It writes the part's files with `CadPart.save_mesh_blobs(folder)` and its mesh files, packs the scene and writes a copy with `ResourceSaver` into `tests/holo_forge/`; the scene shown keeps its path and its nodes hear of no save. Reason: an editor scene save also rewrites every resource marked as edited in the session (18 files of the project on 2026-11-12, same bytes), and a part's own "save once more" saved the test scene under its own name with the hook's part in it (restored from a copy). The part refuses when another scene is shown and fails when any other file of the project, the test scene or the files beside it change (sources and build output are left out of the project check). So it covers the stored mesh going beside a scene and loading back, not the editor's save path, which is team G's `--holo-forge-save-editor-test`. `--holo-forge-mesh-editor-skip=save` leaves it out (the run then ends with PARTIAL).
- **The hook in a real window** sets the editor window to embed its sub-windows for the run (and puts it back): the editor otherwise works out what the mouse is over from where the real cursor is, so with the cursor resting over the window no pushed click reached a Button. A headless run sets the window to 1920 x 1080 and puts it back. The hook also checks after each part that `project.godot` was not written (a windowed editor start itself rewrites it, same bytes, before the hook runs).
- **Not covered by the hook:** Direct Edit's Flip and Extract by real input; 3MF export (filter only); the light theme beyond the material tokens and screenshots; Organic on anything but a ball; Faceted near its triangle cap.
- **The browser's body menu** is still extended through `browser._context` and `_context_meta` (private members of `ui/browser.gd`).

## 9. What Stage 4 and the fix round changed (2026-11-12)

**Stage 4**
- `accept_command` swaps Create Mesh Section Sketch for its fixed sketch and Organic's Form Body output for a Form feature (one undo step each).
- Reduce and Smooth: Sharp Edge Angle. Reduce's labels say the counts are of the whole body. Close Holes shows Match Edge Size for Flat too. Remesh's Minimum Edge is an empty "auto" field.
- A typed value equal to the panel's own stays the user's.
- The stat row reads `MESH.reports`; converts show their `stat` line.
- Picks made while the preview shows the tool's result resolve on the mesh the tool started on (holes at a fill's rim, triangles after the first was erased). Mesh Align's points are told apart by position, so three fit on a face of two triangles.
- Hover on a million triangles in triangle mode: 35 ms to 0.35 ms (`selection_mesh`).
- The command panel moves left when it grows past the view's edge. File dialogs carry their own titles. A picked hole reads "Hole (11 edges)". A preview refused for time is no red status line.
- The hook `tests/holo_forge_mesh_editor_test.gd` and its `plugin.gd` line.

**Fix round**
1. **Panel placement.** A Mesh tool's panel keeps off the screen rectangle of the bodies the tool works on (`mesh_tool_rect()`), with the Form environment's places (`form_editor.panel_spot()`): the left side, under the bodies (shorter, rows scroll), beside them. It is placed again when other bodies are picked, and moves when the view turns, the preview moves the body or the panel grows until it no longer covers them. It never runs out of the view. It stays put while a handle is dragged. The result row is "pinned": it sits under the scrolling rows, so a short panel still shows it.
2. **Direct Edit's Move arrows** start at the middle of the selection. **Mesh Align's points** are numbered dots (`shown_point()`), drawn on the body as shown.
3. **Editing an existing Mesh feature.** `bodies_before(feature_id)` replays the timeline up to the feature on a scratch copy; `note_input()` gives the command those bodies. Picks, the Removed and Selected overlays and the stat row's "before" are of them.
4. **`ui/command_panel.gd`.** `set_values(values, changed_elsewhere)` shows a value changed from outside also in the field that has the keyboard; a typed value is left alone. A click on the active slot leaves it active, and a click on another slot un-presses the one before. `ensure_row_visible(key)`, `set_ok_enabled(on)`, "pinned" rows.
5. **Preview limit.** Preview rebuilds pass `mesh_preview_feature`; `core/regen.gd` reads it.
6. **Warnings.** Mass prints each entry's `warning`, `note`, `error`, the counts (`wrong_way_edges`, `inside_out_parts`, `self_intersections`) and any flaw the warning does not name; the result's own `warnings` for bodies not listed. Interference prints `note`, `warning`, `error` of every entry and pairs left out for time (`timed_out`) or with an open body (`open`) in their own sentence; it no longer adds "The volume is approximate." itself (the `note` says it, with the percent). Measure prints `note`, `warning`, `error`. Insert Mesh shows the reader's warning in its prompt (files up to 96 MB are read once for it), in the status line after the insert, and the feature's chip keeps any warning in its tooltip ("Note: ...", wrapped). The status line wraps inside the view. A Mesh tool that built with a warning says it after OK.
7. **Grammar.** `counted(n, "triangle")` gives "1 triangle" / "2,700 triangles"; used for triangles, face groups and picks in U's sentences.
8. **After team G's fix round.** A picked face group of a mesh body (a `mesh_group` pick in the view selection) is an appearance target of its own (`face:<body>:<group>`); `apply_appearance` keeps `APPEARANCE.face_anchor(pick)` (`at`, `normal`) in the entry, so the appearance follows its group when the groups are renumbered. What `APPEARANCE.build_mesh(...).notes` says is in the status line (`workspace.appearance_notes`). Export's `note` (skipped and hidden bodies) is in the export's message, as before.
9. **After team M's fix round.** Direct Edit writes `"emptied": true` (no `mesh` key) when no triangle is left, and stores every extracted part before it adds the feature. OK from the panel or Enter first shows "Computing <Tool> with the full time limit (up to 20 s)..." with OK taken away, draws two frames, then rebuilds (`accept_from_ui()`; `accept_command()` itself is still one call).
10. **Picks hold a point and a facing (2026-11-13, the re-verifier's finding).** `tools/feature_command.gd` wrote a clicked face group with `at` and no `normal`, and a group taken over from the selection with the name only. Now `mesh_pick_at()` adds the hit's normal (also for triangles), `_prefill()` adds `_group_anchors()` / `_first_anchor()` (a selected triangle's middle and its facing, asked of the mesh with a short ray), and a clicked hole gets the facing of a triangle at its rim point. `ui/command_panel.gd` `_same()` leaves `normal` out as it does `at`. Hook part `anchors`: the stored picks have both, and Reverse Normal made each way stays on the +X face and says "face group moved from g5 to g4" when a Plane Cut is put before Generate Face Groups. With the taken-over anchor left out the same part fails (the tool turned the wrong face round, with no warning).
11. **A preview stops after its feature (2026-11-13, after team G's second round).** `REGEN.rebuild` with `mesh_preview_feature` no longer runs the features after the previewed one; its result names it in `preview_stops_at`. The workspace then:
    - shows every body as it leaves the previewed feature;
    - keeps what only the later features make as the last whole rebuild left it (`_hold_later_features()`: their bodies, sketches, construction geometry, threads and forms; `result.preview_held` lists the bodies, `result.preview_later` the features), so the view, the browser, the selection and the picks do not lose them;
    - dims the later chips a little and says "Not shown during the preview of <feature>: worked out again on OK or Cancel." in their tooltips (meta `waiting`); they carry no error;
    - says in the status line what the preview leaves out;
    - refuses a click on a held body for the tool ("... is made later in the timeline (by ...), so ... can't work on it.", `later_body_refusal()`);
    - does not move decals and canvases to follow the stopped model, and does not bake from it;
    - rebuilds the whole timeline when the tool closes: OK as before, Cancel also when nothing was changed (`_refresh_for()`).
    A body that a later feature would take away shows during the preview (it is there as the previewed feature leaves the model). Hook part `later`: an early Scale Mesh with Reduce, Smooth, Remesh and a later Insert Mesh; the preview answered 139 ms after the typed key against 3.6 s for the whole timeline.
12. **Interference, pairs that nearly touch.** An entry with `"unseen": true` is no clash: `take()` sorts it into `unseen`, and `describe()` prints its note under the list ("<A> / <B>: No overlap was found, but ..."); alone it reads "No interference found." Create Bodies never sees it.
