# Phase 7 native ops as built: pmp-library, meshoptimizer and own-code ops (team N2)

The orchestrator accepted every difference from the spec listed here (2026-11-11); 5.1 #19 asserts the 'Nothing could be taken out' outcome at 0.01 mm, and 5.1 #18 Fast asserts at most 0.12 mm. 5.2 and 5.3 cases with those numbers change the same way.

Updated 2026-11-12 after the fix round on verifier V1's findings: section 3 holds the options, sentences and report keys as they are now; section 8 lists what changed and why.

## 3. Bound methods (for team M)

Common to all:
- Every op returns a new `CadMesh`, or `null` with `get_last_error()`. `<Body>` in every sentence is the literal "The mesh"; M substitutes the body name.
- `options.time_limit`: default 20, clamped 0.05..120.
- Range refusal: `"<Label> must be between <a> and <b>."` (lengths in mm, angles with °, percent with " %"); integers: `"<Label> must be a whole number between a and b."`; enums: `"<Label> must be one of: x, y."`; bools: `"<Label> must be on or off."` (true, false, 1 and 0 are taken; 2, -1, 0.5 and text are refused). Nothing is clamped.
- Time, three sentences:
  - up front: `"<Op> would take about <n> s on this mesh (limit <l> s). <hint>"`. `<n>` is rounded up to two digits, so it always reads as more than `<l>`.
  - before a step that cannot be stopped and would end after the limit (a pmp pass, a decimate call, a meshoptimizer call, a fair solve): `"<Op> would take about <n> s on this mesh (limit <l> s); it was stopped after <t> s, before a step that would have run past the limit. <hint>"`. It holds both "would take about" and "(limit", so it reads as a time refusal.
  - `"<Op> took longer than <l> s and was stopped. <hint>"` only when the limit really has passed.
- Lengths are written by the shared `mesh::length_text` (mesh_data.cpp, since 2026-11-13): four digits, in mm, and in µm / nm, m or km outside 0.001 mm to 1 m; never with an exponent.
- A count of one reads as one in every sentence ("1 hole was larger than Largest Hole and stays open.", "fixed 1 non-manifold edge."); the plural forms below stand for both.
- Triangle ids out of range: `"Triangle <i> is not in the mesh (it has <T> triangles). Select the triangles again."`
- pmp-based ops (remesh, reduce adaptive, whole-body smooth, close_holes) refuse with one of: `"The mesh has <n> non-manifold edges. Run Stitch and Remove first."`, `"The mesh has <n> triangles that use a corner twice. ..."`, `"The mesh has <n> edges whose two triangles face opposite ways. ..."`, `"The mesh has corners or edges where surfaces only touch (it is not manifold there). ..."`.
- When the result crosses itself but `finish_op` could not test the input in time (so it made no claim), my ops add: `"<Op> gave a mesh that crosses itself in <n> places; the input could not be tested in the time left, so some may have been there before."`
- In "nothing to do" cases the **same instance** comes back with a warning (listed per op).
- Reports carry extra keys beyond 2.6.3 (listed per op).

**`welded() -> CadMesh`**
- Through `mesh::weld_exact` (which writes −0 as 0). Groups kept.
- Report: `welded_vertices`, `vertices_before`.

**`delete_triangles(tris: PackedInt32Array) -> CadMesh`**
- Remaining triangles keep their order and corner positions bit for bit.
- Report: `deleted_triangles`, `new_loops`, `merged_loops` (PackedInt32Array of ids into the **result's** `boundary_loops()`). `new_loops` are loops holding an edge the deletion opened; `merged_loops` is the subset that also runs along an edge that was open before.
- Erase and Fill: `delete_triangles`, then `close_holes({"loops": new_loops, "fill": ...})`; warn "The selection touches an open edge; that hole was filled too." when `merged_loops` is not empty.
- Refusals: `"Select the triangles to delete."`, `"Deleting every triangle would leave nothing of the mesh. Delete the body instead."`

**`reverse(options := {}) -> CadMesh`**
- `mode`: whole / selection / auto (default auto). `triangles`: PackedInt32Array. `groups`: group names.
- Auto: each piece made one-way (the way most of its area faces), then closed pieces turned by the nesting rule.
- Report: `flipped_triangles`, `flipped_pieces`; selection mode also `disagreeing_edges`.
- Warnings: `"<n> edges could not be made to agree: the surface is one-sided there."`; selection mode: `"The reversed triangles now face the other way than their neighbours along <n> edges."`
- Refusal: `"Select the triangles or face groups to reverse."`

**`stitch_and_remove(options := {}) -> CadMesh`**
- `tolerance` (D×1e-5; 0..D/100), `remove_small` (true), `min_size` (1; 0..50 %), `remove_inner` (false), `fix_non_manifold` (true).
- A double triangle is one with the same three corners the same way round. Two triangles on the same corners that face opposite ways (the walls of two bodies that touch, or of a sheet without thickness) both stay.
- Bodies that touch (corner to corner, edge to edge, face to face, or brought together by the Stitch Tolerance) stay separate closed bodies: around an edge more than two triangles share, each triangle is paired with the next one that closes material, and walls lying on each other stay with their own body.
- Report: `welded_vertices`, `removed_triangles`, `removed_duplicates`, `removed_degenerate`, `kept_degenerate`, `removed_fins`, `removed_pieces`, `removed_inner_pieces`, `fixed_non_manifold_edges`, `split_vertices`, `flipped_triangles`, `flipped_pieces`, `removed_area`, `weld_area_change`, `open_edges_before`, `open_edges_after`, and `summary` = the stat-row sentence `"Welded <n> vertices, removed <m> triangles and <k> pieces, fixed <j> non-manifold edges."`
- Warnings: `"Stitching moved the surface: the area of the kept triangles changed by <x> %. ..."`; `"<n> edges are still shared by more than two triangles (they could not be split into sheets)."`; `"<n> triangles without area were kept: taking them out would open the mesh."`; the one-sided sentence.
- Warning: `"<n> triangles lie exactly on other ones that face the same way (pieces of the body lie on each other): the volume counts them twice. Delete one of the pieces."` (report `coincident_triangles`).
- Warning on a body that was open already: `"The mesh has <n> more open edges than before (<a> -> <b>): taking out double and fin triangles, or splitting edges that more than two triangles share, opened them."`
- Errors: `"Stitch and Remove made <n> edges that more than two triangles share. Lower the Stitch Tolerance."` (since 2026-11-13 the hint is `"Lower the Stitch Tolerance; if the body touches itself there, Rebuild makes a clean body of it."`, and at tolerance 0 `"The body touches itself there (parts of its surface lie on each other); Rebuild makes a clean body of it."`; with Fix Non-Manifold Edges off the sentence ends `"Turn Fix Non-Manifold Edges on (it keeps bodies that touch apart), or lower the Stitch Tolerance."`, which is what bodies that touch get then); `"Stitch and Remove would open a closed body (<n> open edges). Lower the Stitch Tolerance."` (checked on every result: a body without open or non-manifold edges never comes back with open ones); `"Stitch and Remove would leave nothing of the mesh. ..."`

**`regroup(tris_or_groups: Dictionary) -> CadMesh`**
- `{"groups": names or ids}` (two or more): all take the first one's name.
- `{"triangles": PackedInt32Array, "name": optional}`: new group `user<k>` (first free k).
- Report: `group`, `combined_groups` or `group_triangles`.
- Refusals: `"Pick two or more face groups to combine."`, `"Face group '<name>' is not in the mesh."`, `"Pick the triangles of the new face group."`, `"Pick either face groups to combine or triangles for a new face group."`

**`generate_groups(options := {}) -> CadMesh`**
- `method` fast / accurate (accurate), `angle` (20; 1..90°), `tolerance` (D/2000; D×1e-6..D/20), `min_size` (10; 1..100,000).
- Names `g0..gN` by smallest triangle. Same result every run.
- Report: `groups`, `planes`, `cylinders`, `spheres`, `freeform`, `merged_small`. The four kinds describe the result: each group counts as what its largest region fits, so `planes + cylinders + spheres + freeform == groups` (accurate; all 0 with fast).
- Refusal: `"Too many groups (<n>); raise the Angle Threshold or Smallest Group."` (fast) / `"...; raise the Fit Tolerance or Smallest Group."` (accurate).

**`fit_primitive(tris: PackedInt32Array) -> Dictionary`**
- `{"triangles", "points", "area", "size", "winner": "plane"|"cylinder"|"sphere"|"", "plane": {"valid", "point", "normal", "rms", "max", "max_at_middles"}, "cylinder": {"valid", "point", "axis", "radius", "rms", "max", "max_at_middles"}, "sphere": {"valid", "center", "radius", "rms", "max", "max_at_middles"}}`.
- `rms` and `max` are distances of the triangles' corners; `max_at_middles` is the largest distance of a triangle's middle (the 8 corners of a cube lie on a sphere and on a cylinder; its faces do not). `size` is the largest distance of a corner from the corners' mean. Corners on one line give no plane (`valid` false).
- Winner rule. A primitive's error is e = max(`max`, `max_at_middles`). With best = the smallest e of the three and floor = 1e-6 × D, the winner is the simplest primitive (plane, then cylinder, then sphere) with e ≤ min(max(floor, 1.5 × best), max(floor, 0.05 × `size`)). So `winner` is "" when even the best fit is off by more than 5 % of the patch's half-size: a cube, two faces of a cube, a cone, a torus patch, a triangle without area. Measured: the L-bracket's groups still give 8 planes and 1 cylinder, a 20° cylinder tessellation a cylinder, a ball patch a sphere, one triangle a plane. Team C should still apply its own tolerance to the `max` values.
- `{}` with an error on bad input.

**`smooth(options := {}) -> CadMesh`**
- `strength` (0.5; 0..1), `iterations` (5; 1..50), `keep_volume` (true), `keep_sharp` (false), `sharp_angle` (45; 10..170°), `keep_boundary` (true), `triangles`.
- pmp implicit smoothing when: whole body, no Keep Sharp, and (closed or Keep Open Edges). Otherwise our Laplacian with locks.
- Keep Volume holds the volume of every closed shell on its own (a void inside a body keeps its volume; before, only the total was held). Checked per closed shell at 0.5 %.
- Our Laplacian also takes over (with the "solve failed" warning) when a pmp pass adds area, or takes more than half of a closed shell's volume away (the step is too long for a mesh of a few long triangles).
- Report: `method` ("implicit" / "laplacian"), `passes`, `free_vertices`, `locked_vertices`, `max_move`, `turned_triangles`, `volume_change` (signed: (after - before) / |before|, closed bodies), `area_change` (signed), `closed_shells`, `shell_volume_change` (the largest |change| of one closed shell, with Keep Volume), `build_ms`, `pass_ms`.
- Warnings: `"Smooth moved the surface by up to <x> (<y> % of the body's size). Lower the Smoothness or Passes."` (above 2 % of D); `"Smooth turned <n> triangles over (the surface folds there). Lower the Smoothness or Passes."`; `"The smoothing solve failed on this mesh (it has very thin or lopsided triangles); the step-by-step smoothing was used instead, which smooths less a pass."` or, when a pass would have taken more than half of a closed shell's volume away, `"The mesh library's smoothing step is too long for a part of this body (one pass would take more than half of that part's volume away: its triangles are long for its size, or it is much smaller than the rest); the step-by-step smoothing was used instead, which smooths less a pass."`; `"Keep Volume was not applied: it needs a closed body or kept open edges, with all triangles facing one way."`
- Same instance: `"The selection is too small to smooth; grow it."` / `"Nothing can move: every vertex lies on a sharp or an open edge that is kept."`
- Errors: `"Smooth would move the surface by up to <x> (<y> % of the body's size): the mesh is too coarse for this much smoothing. Lower the Smoothness or Passes, or Remesh the body first."` (above 50 % of D); `"Smooth changed the volume by <x> % (limit 0.5 %). Lower the Smoothness or Passes."` (with several closed shells: `"Smooth changed the volume of one of the body's <n> closed shells by ..."`)
- Hint: "Lower Passes, smooth a selection, or Reduce the body first."

**`reduce(options := {}) -> CadMesh`**
- `target` proportion / face_count / tolerance (proportion), `proportion` (50; 1..99 %), `face_count` (T/2; 4..T−1), `tolerance` (D/2000; D×1e-6..D/10), `method` adaptive / fast (adaptive), `keep_boundary` (true), `keep_groups` (true), `keep_sharp` (false), `sharp_angle` (45; 10..170°, my addition), `triangles`.
- Every vertex left is an input vertex, bit for bit, with both methods.
- Keep Face Group Borders, both methods: the vertices on a group border stay, so the borders are the input's own edges (measured 0). When that keeps the count up, the count warning says so.
- Fast works on the welded mesh. Where welding by position joins what only touches (two bodies corner to corner, edge to edge, face to face), those places are taken apart again and their vertices stay.
- By Maximum Deviation the result is measured both ways, and a result comes back only when it is within 98 % of the tolerance; otherwise the mesh itself comes back with "Nothing could be taken out". How it is measured: 20,000 random points each way, and for every triangle that is not in both meshes its corners and a lattice of points across it (cut 2 to 8 ways a side, the finer the fewer triangles changed; at most about 4.5 points an input triangle each way), and from the 48 furthest of those points a climb across their triangles to the furthest place nearby. Triangles that both meshes hold are 0 apart. This is a measurement, not a proof: against 400,000 random points each way its number was the larger one in every case tried (0.0520 against 0.0505 mm, 0.2445 against 0.2331, 0.8326 against 0.8299, 7.0245 against 7.0245), and the 2 % is the margin for what a climb can still miss. Adaptive tries up to four times (smaller library limit each time; the last two with edges sharper than Sharp Edge Angle as features, along which collapses run). Fast searches the count by halving, with up to 16 library calls, each to a count (see 8, B1), and tries up to three times.
- Report: `method`, `target`, `calls`, `locked_vertices`, `deviation` {`max`, `mean`, `samples`, `result_to_input`, `input_to_result`} (always measured, 20,000 each way), `border_deviation` (with Keep Face Group Borders: the largest distance between the old and the new border lines, both ways), `build_ms`, `call_ms`, `call_triangles`, `call_targets`, `library_error`, `border_length_before/after` (fast with groups), `touching_corners_before/after` (fast).
- Warnings: `"Reduce kept <n> triangles (<p> %) instead of <t>: open edges, group borders and sharp edges limit it."`; `"Fast left <n> edges shared by more than two triangles. Stitch and Remove can fix them, or use Adaptive."`; `"Fast left <n> corners where surfaces only touch (the mesh is not manifold there). Stitch and Remove can fix them, or use Adaptive."`; `"Face group borders moved by up to <x>."` (above 1e-6 × D; fast adds `" Use the Adaptive method."`); `"Reduce moved the surface by up to <x> (<y> % of the body's size). Keep more triangles."` (above 2 % of D; my addition).
- Same instance (nothing was taken out; report `unchanged: true`):
  - by count: `"Reduce kept <T> triangles (100 %) instead of <t>: every vertex lies on an open edge, a group border or a sharp edge that is kept."` or `"...: open edges, group borders and sharp edges limit it."`
  - by Maximum Deviation: `"Nothing can be taken out: every vertex lies on an open edge, a group border or a sharp edge that is kept."` or `"Nothing could be taken out within the Maximum Deviation of <x>."`; Fast adds `" (Fast cannot tell deviations below about <1e-3 × D> apart on this body; the Adaptive method can.)"` when the tolerance is below that or its tries came out too far off.
  - `"The selection is too small to reduce; grow it."`
- Errors: `"Fast cannot keep face group borders on this mesh; use Adaptive."`; `"Reduce opened <n> edges of a closed body. ..."`; `"Reduce lost <n> face groups ..."`; `"The mesh has only <n> triangles; there is nothing to reduce."` (The two "moved the surface by <x> (limit <y>)" refusals of the first round are gone: that case is now the "Nothing could be taken out" outcome.)
- Hints: adaptive "Use the Fast method, or Reduce a smaller body."; fast "Reduce a smaller body or a selection."

**`close_holes(options := {}) -> CadMesh`**
- `fill` minimal / smooth / flat (smooth), `max_edges` (0; 0..100,000), `refine` (true), `loops`: PackedInt32Array of `boundary_loops()` ids (missing or empty = all).
- New groups `fill<k>` (first free numbers).
- The outline of an open sheet is not a hole. A loop is an outline when both hold: the fill folds back over the sheet (its mean normal within 60° of opposite to the sheet's triangles on 9 of 10 loop edges), and the sheet does not rise out of the loop to one side (along the normal of the loop's best plane, the vertices of the loop's piece stay within the heights of the loop's own vertices give or take 0.5 % of the loop's radius, or leave them on both sides). So a flat, wavy, saddle or bent sheet keeps its outline open; a shallow cone, a cap or a tray closes into a solid. A plate with a hole: the hole closes, the outline stays.
- A loop named in `loops` is closed even when it is an outline, with the warning below.
- The smooth fill stays at its hole: when a fill vertex would lie further from the loop's middle than the loop is wide, that hole gets the flat fill instead, and the warning says how far the smooth one ran.
- Report: `filled_loops`, `skipped_loops`, `broken_loops`, `outline_loops`, `picked_outline_loops`, `replaced_loops`, `replaced_reach`, `unsmoothed_loops`, `folded_loops`, `fill_groups`, `new_triangles`, `new_vertices`, `triangulate_ms`, `refine_ms`, `fair_ms`, `largest_fair_vertices`.
- Warnings: `"<n> holes were larger than Largest Hole and stay open."`; `"<n> holes could not be closed and stay open: their edge does not run around once, or no patch fits without a third triangle on an edge of the mesh. Use Wrap, or run Stitch and Remove first."`; `"<n> holes were filled without smoothing (...)"`; `"The fill of <n> holes left the hole's plane by more than the hole is wide (holes ...). Use the Flat or Minimal fill there."`
- Warnings: `"<n> open loops are the outline of an open sheet, not holes, and stay open: closing one would only lay a second surface on the sheet."`; `"<n> holes that were picked look like the outline of an open sheet: the fill lies back on the sheet and encloses next to nothing (holes <ids>)."`; `"The smooth fill of <n> holes ran up to <x> from the hole's middle (that hole is <y> across) and was replaced by the flat fill (holes <ids>). Use the Minimal fill there if the flat one does not suit."`
- Same instance: `"The mesh has no open edges: there is nothing to close."`; also when every loop asked for was skipped (too large, broken, or an outline), with those warnings.
- Refusals: `"Hole <id> is not in the mesh (it has <n> open loops). Pick the holes again."`; `"A hole of <n> edges would need about <m> new vertices (limit 150,000). Turn off Match Edge Size, use the Minimal fill, or use Wrap."`; `"Close Holes would make about <n> triangles; mesh bodies take up to 2,000,000. ..."`
- Hint: "Close fewer holes at once, or use Wrap."

**`remesh(options := {}) -> CadMesh`**
- `mode` uniform / adaptive (uniform), `density` (0.5; 0.01..1), `edge_length` (0, or D/2000..D/5), `min_edge` (D/1000), `max_edge` (D/50; ≤ D/5), `approx_error` (D/2000; D×1e-6..D/20), `iterations` (10; 1..50), `keep_sharp` (true), `sharp_angle` (45; 10..170°), `keep_boundary` (true), `keep_groups` (true), `triangles`.
- Report: `passes`, `edge_length`, `mean_edge`, `estimated_triangles`, `corners_restored`, `deviation` {`result_to_input`, `input_to_result`, `max`, `mean`, `samples`}, `border_deviation` (both ways: a stretch of border that is gone from the result counts as much as one that strayed), `mended_caps`, `estimate_s`, `folded_edges`, `build_ms`, `pass_ms`, `project_ms`, `pass_triangles`, and for adaptive `min_edge`, `max_edge` (the values used; the panel should show them), `curvature_ms` (always 0 now).
- Adaptive gives one time estimate for one call whatever the limit (the larger of the passes on the expected size and one pass on the worst case), and refuses before any work (2 ms at 82k; it took 0.5 s).
- Warnings: `"The input is rougher than the new edges; deviation <x>."`; `"Edges average <x>; asked for <y> (sharp edges and borders limit it)."`; `"Face group borders moved by up to <x>."` (above 1e-6 × D); `"Remesh changed the volume by <+/-x> % (the new edges are long for the body's curves). Raise the Density or lower the Edge Length."` (closed bodies, above 2 %; report `volume_change`, signed); `"Remesh folded the surface back on itself at <n> edges. Raise the Density or lower the Edge Length."`
- Same instance: `"The selection is too small to remesh; grow it."`
- Errors: `"Remesh moved the surface by <x> (limit <y>). Raise the Density or lower the Edge Length."`; `"Remesh would make about <n> triangles; lower the Density."`; `"Remesh changed the number of open loops from a to b. ..."`; `"Remesh lost <n> face groups ..."`; `"Edge Length must be 0 (to use the Density), or between a and b."`; adaptive: `"Remesh (Adaptive) works on up to 150,000 triangles (this would be about <n>). Use the Uniform type, or Reduce the body first."` and `"With a Minimum Edge of <x>, Remesh (Adaptive) could make about <n> triangles (it works on up to 150,000). Raise the Minimum Edge to <y> or more, or use the Uniform type."`
- Hint: "Lower Passes or Density."

## 4. Differences from C4 / section 3, with reasons

1. **Generate Face Groups, small groups.** The literal rule gives 4 groups on the L-bracket, not 9 (its flat faces have 2 to 8 triangles, under the default 10). Now a small group merges only into a neighbour whose mean normal is within 2 × Angle Threshold (fast) or 40° (accurate).
2. **Reduce adaptive, selection.** The spec's "mark the border as features" lets pmp collapse along the border, which would crack it. I lock the rim through pmp's `v:selected` (read in `decimation.cpp`: an unselected vertex is never removed). Vertices where features meet or end are locked the same way.
3. **Reduce adaptive, edge limit.** With the spec's parameters the 50% sphere result is 0.065 mm off (limit 0.05). The staircase calls now carry a longest-edge limit (1.6 × the mean edge of the target count, never under 2.0 × the input's); the guard calls run without it. Result: 0.0426 mm. The margin is thin.
4. **Reduce by tolerance.** One call (the 3-call staircase would reset pmp's error memory three times). pmp's own limit is not a bound: 0.060 mm measured at a 0.05 mm limit. So pmp gets 0.8 × the tolerance, the result is measured both ways, and the work is redone with less up to twice if time allows; otherwise the "moved the surface" error.
5. **Reduce fast.** Absolute error mode at 0.5 × the tolerance with the same measure-and-retry. Keep Open Edges locks boundary vertices (both methods). Keep Sharp Edges locks sharp-edge vertices.
6. **Close Holes.**
   - Refine target is the loop's own mean edge, not the body's ē.
   - "flat" is the refined patch with its inner vertices on the loop's plane; with `refine` off it equals minimal.
   - A patch never uses a diagonal between two loop vertices the mesh already joins (it made 119 non-manifold edges on a jagged hole before that).
   - Free-vertex cap lowered from 200,000 to 150,000.
7. **Remesh, borders.** pmp alone does not keep borders within 1e-6 (collapses along a curved border cut its corners). Border vertices are put back on the original border lines after every pass and every cut corner is re-inserted at the end. With Keep Open Edges, open edges are only ever split, never coarsened.
8. **Remesh, groups.** With Keep Groups, groups travel as a face property (new faces take a neighbour's group across non-feature edges); nearest-triangle is only the fallback.
9. **Remesh adaptive** (see 6.3): size limit 150,000, default Minimum Edge raised to fit and reported, a given one refused.
10. **Smooth.** Falls back to our Laplacian when pmp's solve fails (a 36-triangle hollow cube is enough). The selection volume correction runs up to 8 rounds.
11. **Stitch.** A triangle without area but with three distinct corners is removed only when that opens no closed edge; otherwise kept and counted.
12. **`fit_primitive`** clears and sets the error (10.2 says queries do not).

## 5. Measured rates and constants in `mesh_budget.h`

Fixtures: noisy icospheres of 81,920 / 327,680 / 1,310,720 triangles and grid cubes of 99,372 / 499,392 / 1,009,200. Stored × 1.5 at 100k / 500k / 2M. Every timing here was measured while other teams loaded the machine (calibration 4.2 to 4.9 ms against N1's 3.4 ms), one run each.

| Constant | Stored | Measured | Spike |
|---|---|---|---|
| `PMP_DECIMATE_HALF` | 1.43 / 7.1 / 28.5 s | about (4 + 11 × share removed) µs per start triangle per call | 3.08 / 9.54 / 50.3 |
| `PMP_REMESH_PASS_WITH_PROJECTION` | 0.54 / 3.0 / 15.8 s | 0.22 s at 82k, 0.90 s at 328k, 6.3 to 6.8 s at 1.31M | 1.39 / 3.46 / 8.32 |
| `PMP_IMPLICIT_SMOOTHING_PASS` | 0.68 / 12.6 / 123 s | 0.32 / 4.0 / 38 to 42 s at the three sizes | 0.79 / 6.79 / 73.6 |
| `MESHOPT_SIMPLIFY_HALF` | spike values kept | 0.020 / 0.105 / 0.43 s | 0.047 / 0.60 / 1.75 |
| `PMP_SURFACE_MESH_BUILD` | spike values kept | 0.020 / 0.085 / 0.31 s | 0.052 / 0.278 / 0.834 |
| `STITCH` | 0.20 / 1.45 / 6.6 | whole op 164 / 761 / 3,433 ms | |
| `ORIENT` | 0.07 / 0.54 / 2.2 | whole op 44 / 256 / 1,045 ms | |
| `GROUPS_FAST`, `GROUPS_ACCURATE` | 0.06 / 0.47 / 2.0; 0.30 / 2.0 / 7.1 | 33 / 200 / 863 ms; 165 / 884 / 3,116 ms | |
| `LAPLACIAN_PASS` | 0.015 / 0.085 / 0.27 | 8 / 36 / 113 to 122 ms a pass | |

- My decimate and remesh numbers are 3 to 5 times faster than the spike's. I cannot explain the gap; both are in the comments.
- Other constants: `DECIMATE_BASE_SHARE` 0.42, `DECIMATE_HAUSDORFF_FACTOR` 2.5, `DECIMATE_TOLERANCE_SHARE` 0.8, `MESHOPT_TOLERANCE_SHARE` 0.5, `DECIMATE_EDGE_FACTOR` 1.6, `DECIMATE_EDGE_FLOOR` 2.0, `REDUCE_FAST_SETUP`, `FILL_DP_MAX_EDGES` 400, `FILL_DP_SECONDS_AT_400` 0.48, `FILL_EAR_SECONDS_AT_10K` 1.0 (a guess), `FILL_REFINE_SECONDS_PER_1K_VERTICES` 0.017, `FAIR_SECONDS_AT_10K` 0.18, `FAIR_POWER` 1.6, `MAX_FILL_FREE_VERTICES` 150,000, `MAX_ADAPTIVE_REMESH_TRIANGLES` 150,000, `ADAPTIVE_CURVATURE_*` (table). `DECIMATE_STEPS` stays 3.
- The caps mirrored in `core/features/mesh.gd` may want the two new maxima.

**What the spike did not measure:**
- 3-step decimate staircase to 50%: 0.72 s at 82k, 3.2 s at 328k, 11.5 s at 1.31M (first call 43 to 45%). A single call to 50% was not timed alone, so `DECIMATE_STAIRCASE_FACTOR` 1.63 is from the per-call model, not a direct measurement.
- pmp `fair` on a hole sub-mesh (free vertices: ms): 395: 2.4; 4,727: 39; 17,653: 231; 58,603: 1,367; 74,152: 2,686; 148,941: 7,096.
- Hole triangulation: the dynamic program takes 1 ms at 59 edges, 7 at 114, 35 to 48 at about 215, 214 to 295 at 375 to 390. Ear clipping takes 1 to 4 ms at 747 to 1,193 edges of a round hole.
- Whole ops with post-checks (ms at 82k / 328k / 1.31M): Reduce fast 156 / 657 / 1,666; Reduce adaptive 50% 869 / 3,677 / 13,006; Remesh 3 passes 877 / 3,282 / 19,871; Smooth pmp 2 passes 724 / 8,479 / 81,709; Close Holes minimal on a 1.31M body about 1.1 to 1.4 s (so there is a per-body term, mostly the post-check).

**Working sizes at 20 s (above these the op refuses up front):**
- Reduce adaptive 50%: about 750k triangles. 1,009,200 is refused, as 5.2 #48 needs.
- Remesh uniform, 10 passes: about 300k at the same size.
- Remesh adaptive: 150,000.
- Smooth whole body, 5 passes: about 250k.
- Reduce fast by count, Stitch, Generate Face Groups, Reverse, our Laplacian: up to the 2M cap.
- Reduce fast by Maximum Deviation: about 600,000 (499,392 runs 4.5 to 5.5 s; 750,000 and up are refused at the start; the check of the changed triangles costs about 1.3 µs a point, up to 9 points an input triangle).
- Close Holes: by hole size (150,000 new vertices a hole).

## 6. Wrong or unworkable in the spec

1. **5.1 #19 cannot be met.** At 0.01 mm nothing can leave icosphere s5: removing one vertex moves the surface about 0.03 mm, and pmp removes nothing at 0.01 or 0.02 mm. My test asserts the honest outcome (20,480 triangles, deviation 0, the "Nothing could be taken out" warning), plus working cases at 0.1 and 0.3 mm. 5.2 or 5.3 cases with that number need the same change.
2. **5.1 #18, Fast.** meshoptimizer gives 0.085 mm on that sphere, not 0.05; I assert ≤ 0.12 mm. Its float sums also make collapses it reports as error 0 that move the surface 0.083 mm, so Fast by a small tolerance ends in the "moved the surface" refusal after measuring.
3. **Remesh adaptive against rule 0.5.1.** A 328k adaptive remesh ran 48 s against a 20 s limit before I fixed it. Two causes:
   - pmp runs a curvature analysis at the start of every call, so once a pass under the C5.1 schedule. Its cost has a cliff: 0.21 s at 59k, 1.5 s at 173k, 5.4 s at 235k, 52 s at 327k. I could not explain it, and small patches of a slow mesh are fast, so it cannot be sampled.
   - Nothing bounds a pass's output but the Minimum Edge (a 36-triangle hollow cube headed for millions of triangles).

   Now the cost is a table of measured points, there is a 150,000 limit, the default Minimum Edge is raised to fit, and no pass starts unless a worst-case pass fits. Adaptive therefore never previews at 0.5 s.
4. 3.2.5's small-group rule against the L-bracket acceptance (4.1 above).
5. 3.3.3's "mark its border edges as features (so they stay)" is wrong for pmp (4.2 above).
6. C4.2 refers to a section 2.5.6 that does not exist; I took the fit rules from 3.4.2 step 1.
7. 3.2.1 "no per-body term" holds for the fill only; the op still has the linear per-body post-check.

## 7. Unfinished, unverified, known risks

- **Time bound.** A probe of 180 calls (13 op variants, 7 limits, 82k and 328k) found the adaptive overrun above. After the fix an adaptive-only re-probe showed the worst case 0.5 s over the limit. The other ops were not re-probed after the last changes.
- **Adaptive remesh quality is unverified.** The spike checked the one-pass schedule against pmp's own multi-pass call for uniform only. With adaptive the sizing is recomputed from the changed mesh each pass, so results may drift.
- **Remesh can fold triangles next to a jagged group border** when a re-inserted corner lies beyond the neighbouring triangle (6 to 8 folded edges on a two-group ball split along a zigzag). It is counted and warned, not prevented.
- **Generate Face Groups (accurate)** does only what 3.2.5 says. A region where a plane runs tangent into a cylinder stays one group; no seeded growing inside it.
- **Close Holes on the outline of an open sheet**: fixed 2026-11-12 (section 8, P5).
- **Reduce on a few triangles** destroys the shape (a hollow cube with island at 50% loses two thirds of its volume). The inside-out, crossing, large-move and count warnings all fire; it is not prevented.
- **Reduce fast on flat grids** leaves triangles without area and coplanar crossings (80 and 238 at 1M), warned.
- **Not measured:** ear clipping's worst case (a loop with many inward corners; the loop is deadline-checked), `fair` above 149k free vertices, a single decimate call to 50%.
- `finish_op`'s linear parts (topology, components, hierarchy) have no deadline, as in N1.
- Not exercised: Stitch's handling of surfaces pinched along an edge within one fan (it would leave the edge and warn), and `remove_inner` on open pieces.

## 8. Fix round 2026-11-12 (verifier V1's findings)

Tests: `tests/holo_forge_mesh_regress_pmp_test.gd` (one section a finding; `N2_ONLY=b1,b2,...` runs some of them), new fixtures at the end of `tests/holo_forge_mesh_fixtures.gd` (`raw`, `cube`, `shifted`, `joined`, `octant_groups`, `cone_patch`, `torus_patch`).

- **B1, Reduce (Fast) by Maximum Deviation and the time limit.** Cause: one meshoptimizer call with an error limit near what its float sums can tell apart makes thousands of passes that each take a handful of triangles out, and cannot be stopped (13 s on 99,372 triangles, over 500 s on a million). Now the library's error limit is never the stopping rule: the smallest count whose library error is within 0.5 × the tolerance is found by halving between counts, each call from the input to a count (a few passes whatever the mesh), at most 16 calls, with the deadline checked before each. The result is measured both ways as before. Constants: `MESHOPT_PROBE_FACTOR` 2.0 (one call against `MESHOPT_SIMPLIFY_HALF`; measured 1.7 to 2.1 × a call to 50 %), `MESHOPT_TOLERANCE_PROBES` 8, `MESHOPT_MAX_PROBES` 16. Measured: 99,372 triangles 0.34 to 0.70 s, 499,392 1.8 to 4.0 s, 1,009,200 3.3 to 7.7 s. Working size at 20 s: about 1 million triangles (1,310,720 is refused up front with "about 23 s"); it was the 2M cap.
- **B2, Stitch and Remove on bodies that touch.** Cause: the two walls of bodies that touch face to face were taken for doubles (same corners), one was removed and the other split open. See `stitch_and_remove` above.
- **B3, Reduce (Fast) where pieces touch.** Cause: welding by position joined the pieces at the shared corner, and the library dragged both along. See `reduce` above. "Nothing could be taken out" now always comes with the mesh itself.
- **B4, Reduce (Adaptive) with Keep Face Group Borders.** Cause: borders were pmp features, along which collapses run, which straightens a border. Border vertices are now locked.
- **P1, Remesh `border_deviation`.** Both ways now. Also: border lines are matched by the two groups they lie between (lines of different borders that share both ends were mixed up), and a feature edge the library flips in its cap removal is put back (`mended_caps`).
- **P2, Reduce (Adaptive) by Maximum Deviation.** See `reduce` above.
- **P4, Smooth.** See `smooth` above.
- **P5, Close Holes on a sheet's outline.** See `close_holes` above.
- **P6, P7 and the notes** (group counts, time sentences, on/off options, `fit_primitive`, Reverse Normal on a selection): see section 3.

Known and not fixed:
- **Remesh loses a short closed border loop when the Edge Length is much larger than the loop** (the saddle loop where a 6 mm hole meets an 8 mm hole, remeshed at 10 mm: 5.9 mm). Cause: pmp leaves three vertices on such a loop and draws them together, and putting them back on the nearest point of the line lands them all near one spot, so the loop's far side is never restored. It is now measured and warned ("Face group borders moved by up to 5.919 mm", with the crossing and fold warnings). A fix would place line vertices by their length along the line, in order, instead of by nearest point.
- **Smooth on a body of a few long triangles** (the L-bracket at the defaults) gives a rounded, self-crossing result with three warnings (move 19.7 mm = 25 % of D, 3,633 crossings, 172 turned triangles); above 50 % of D it is refused.
- **Reduce (Adaptive) by Maximum Deviation on bodies of flat faces** mostly ends in "Nothing could be taken out" (L-bracket at every tolerance; the crossing holes below D/20): their vertices lie on sharp edges, and pmp's own deviation check cannot be trusted across those.

### Second fix round, 2026-11-13 (re-verifier R1)

Tests: sections `n1`, `n3`, `n6`, `n7`, `n9`, `more` of `tests/holo_forge_mesh_regress_pmp_test.gd`; new fixtures `flipped`, `deformed`, `grid_plate`, `tray`, `cone_sheet`, `voxels`.

- **N1, the smooth fill ballooned.** Cause: pmp's fair solve carries the slope of the triangles around the hole on into the fill; where they lean outward (a shallow tray's walls, a sheet bent along its middle) the fill runs away sideways, and the old check looked at the distance from the hole's plane only. Now no fill vertex may lie further from the loop's middle than the loop is wide; otherwise the flat fill is used and named (see `close_holes`). Tray 40 to 80 mm: was 287 x 17.5 x 136 mm and 38,172 mm3 with no word, now 80 x 0.5 x 80 mm and 1,867 mm3 with the warning.
- **N3, Reduce by Maximum Deviation over its tolerance.** Cause: 20,000 samples each way miss the worst place. Even every vertex, edge middle and triangle middle read up to 8 % low: the worst place of a new triangle lies where it crosses an old edge. Now `mesh::distance_at_points` (lattice on the changed triangles, then a climb from the 48 furthest points; see `reduce`), a 2 % margin (`TOLERANCE_MARGIN` 0.98), and up to six tries for Adaptive (it was four). `POINT_DISTANCE_SECONDS_PER_MILLION` 1.5 (measured 1.2 to 1.3) goes into the estimate at the start. Holed blob at 0.08887 mm: was 0.0973 mm off (400,000 samples each way), now 4,765 triangles at 0.0505; at 0.88865 mm: was 0.946, now 3,891 triangles at 0.233 (the tries that reduce further come out over the tolerance).
- **Deviation numbers that still rest on 20,000 samples each way** (plus nothing else): Reduce by proportion or count (the `deviation` key and the "moved the surface by up to" warning); Remesh (the `deviation` key, the "rougher" warning at 0.25 L and the refusal at 0.5 L). Exact, not sampled: Smooth's `max_move` (vertex moves), `border_deviation` of Reduce and Remesh (ends and middles of every border edge), Stitch's area change, Close Holes' fill reach.
- **N6, the outline rule**, and **N7, N9, the notes**: see section 3.

### Flat holes with straight sides, and "without area" in Stitch (2026-11-13)

Tests: sections `flat` and `area` of `tests/holo_forge_mesh_regress_pmp_test.gd`.

- **Close Holes on a flat hole with straight sides** (a patch of grid triangles taken out of a flat plate) made triangles of three loop vertices on one side: "made 6 triangles without area", "made 10 places where the mesh crosses itself" on a square hole of 4 squares a side, with every fill type. Cause: for the hole's triangulation such a triangle bends nothing and adds no area, so the two measures it is chosen by (least bend, then least area) took it gladly. Now the dynamic program puts the number of triangles without area first (after "no diagonal the mesh already holds"): as few as the loop allows, none where a triangulation without one exists. The ear clipper for loops over 400 edges does not cut an ear at a corner that turns by rounding only, and its last resort takes ears without area last. "Without area" here is the shared rule of `mesh::without_area`, four times as strict. Measured: 5 holes (square of 16 squares, one square, 32 by 4, L-shaped, one square wide across 12) x 3 places (flat, tilted, tilted 100 m from the origin) x 5 option sets (minimal, flat, smooth, minimal without Match Edge Size, both loops picked): 47 of 75 calls had triangles without area before, none now, and no crossing.
- **Stitch and Remove** judged "without area" by the body's size (twice the area under 2e-12 x D^2: on a 100 m body every loose triangle under 10,000 mm2 went). It now uses `mesh::without_area`, as `check()` does: on a 100 m body the 2 needles go and four loose 0.1 mm triangles stay (before: 6 of the 7 triangles were removed).

### Third fix round, 2026-11-13 (re-verifier R3)

Tests: sections `r3far`, `r3fill`, `r3thin`, `r3count`, `r3outline` of `tests/holo_forge_mesh_regress_pmp_test.gd` (51 failures on the DLL before the change, none after).

- **B1, ops far from the origin.** Remesh on a 10 mm ball 20 to 100 km out ran 8 to 22 s against a 2 s limit (once 36 minutes at 20 s), and at 10 km on the diagonal said "made a broken mesh (internal error)". Cause: positions are float32, so out there they step by about an edge (3.9 mm at 100 km for 0.75 mm edges). A pmp pass, which cannot be stopped, splits edges whose middles round back onto their ends, and the mesh grows many times over within one pass. Smooth, Reduce and Close Holes did not overrun, but gave triangles without area (up to 1,968), crossings, or false reasons ("changed the volume by 2.54 %"). Now Remesh, Smooth, Reduce and Close Holes refuse up front when the float32 step at the body's largest coordinate is over an eighth of the edge length they work at, with the shared sentence of `ops::too_far`: "Ball is 30 km from the origin, where positions are stored only to about 1.953 mm: too coarse for its edges of 0.8809 mm. Move it nearer the origin first." (`mesh::far_refusal`, mesh_pmp.cpp). The edge: Remesh takes the smaller of its target edge (Adaptive: the Minimum Edge) and the input's mean edge; the others take `mesh::typical_edge` (from the mesh's area and triangle count, so the refusal costs nothing on a million triangles). Remesh also checks the deadline inside the cap mending and the group flood after each pass. Measured on the 10 mm ball: refused in 0 to 16 ms at 3, 10, 20, 30 and 100 km (x and diagonal); at 1 km all five ops work cleanly; a 120 mm ball at 10 km, a 1 m ball at 100 km and a 400 mm ball at 30 km remesh in about 0.1 s with no triangle without area.
- **A1, smooth fills kept although they left the hole.** The reach bound (the loop's width from its middle) let fills run out sideways by up to 0.84 x the loop's width: a 48 mm tray filled out to 67 mm (9,920 mm3 against 971 with the flat fill), a 2 mm slot 44 mm past its end. Now the fill must also stay within the loop's box in its own plane (along its two main directions), give or take a quarter of the box's narrower side; otherwise the flat fill is used and said: "The smooth fill of 1 hole ran up to 19.26 mm outside the hole's outline (that hole is 48 mm by 48 mm) and was replaced by the flat fill (hole 0)." (`outline_replaced_loops`, `outline_replaced_by`). A kept smooth fill that changes a closed body's volume by more than half against the flat fill is said with the numbers ("rises up to 9.71 mm off the hole's plane: the body encloses 9,812 mm3, against 800 mm3 with the flat fill. Use the Flat fill if the hole should be closed level."; report `volume_with_flat_fill`). A ball without its cap and the end of a 20 mm tube keep their smooth fills with no word.
- **A2, Reduce on a thin closed plate.** Fast at a 1 mm Maximum Deviation on a 0.2 mm plate lost 66.7 % (or all) of its volume, within the deviation, with no word. Reduce now says any volume change of a closed body over 5 %: "Reduce changed the volume by -66.7 % (the surface moved by up to 0.2 mm). Lower the Maximum Deviation, or use the Adaptive method." (report `volume_change`). The result itself is unchanged: it is within what was asked.
- **A6, Reduce's deviation by proportion or face count read low.** It came from 20,000 samples each way (one collapse on the crossing holes: 0.000873 mm for a true 0.001746). Now it is measured as by Maximum Deviation (`distance_at_points` both ways) when that fits within what the work order allows Reduce on that many triangles after the reduction (Fast 2 s a million, Adaptive 6 s per 100,000), or within 1 s, and within the time limit. Otherwise the samples alone are used and that is said ("The deviation was measured at 40,000 sample points only (measuring at every changed triangle would take about 14 s more), so the ... reported may be under the true one."; `deviation.sampled_only`). This is Fast on bodies over about 70,000 triangles; measuring them in full would take five times the reduction and break the 2 s for a million. After: crossing holes to 3,634: report 0.00187 against 0.00175 mm measured with 400,000 samples each way; to 1,090: 0.08728 against 0.08679; L-bracket to 382: 0.01217 against 0.01194; holed blob (Fast) to 479: 1.7402 against 1.7231. The Adaptive timing limit in `holo_forge_mesh_native_pmp_test.gd` rose from 370 to 765 (82k triangles: 0.87 s became 1.5 s, 0.7 s of it the measure).
- **A7, "encloses next to nothing".** This was N2's sentence for a picked outline, and false for bent sheets (3,036 and 8,166 mm3). Now: "1 hole that was picked looks like the outline of an open sheet, not a hole: the fill spans the outline, so the body now encloses only the space between the sheet and the fill (hole 0)."
- **Remesh at defaults on a tessellated cylinder** (r 5 mm, 30 mm, tessellated at 0.02 mm: 196 long triangles; the default Density keeps the input's size, here an Edge Length of 12.57 mm on a 10 mm cylinder). The volume warning is accurate: "Remesh changed the volume by -98.3 %", and the measured change is -98.27 % (-66.56 % in both at a 0.1 mm tessellation). The reason it gives (edges long for the body's curves) is the cause. The deviation sentence beside it said "The input is rougher than the new edges", which is false for a clean cylinder. It now reads "The new edges of 12.57 mm are too long to follow the input everywhere (it is rougher, or curves more tightly, than they are long); deviation 8.402 mm."

Proposed accepted limits: Fast Reduce by proportion or count on bodies over about 70,000 triangles reports a sampled deviation, and says so. The smooth fill's volume statement is a warning, not a replacement: a dome over upright walls is what the smooth fill is for (a tube's end) and only the body's volume shows that it is out of place.
