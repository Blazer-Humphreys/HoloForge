# Phase 7 native ops as built: Manifold and voxel ops (team N3)

Sections 4 to 7 of team N3's stage report (2026-11-11), for team M to wire the tools from. The section numbers are the report's own.

**Updated 2026-11-13 after the third fix round** (re-verifier R3's Plane Cut findings B2, B3 and notes): see section 10.

**Updated 2026-11-13 after the second fix round** (re-verifier R1's N4, N8, N10 and notes): see section 9.

**Updated 2026-11-12 after the fix round** (verifier V2's findings B1 to B6, P1 to P4, P8, P9 and its notes). Every change is marked "fix round" where it applies, and section 8 lists them in one place with the report keys and sentences that are new.

## Orchestrator decisions on section 6, items 1 to 4

1. **Wrap tests use a gap of at least 22 mm on the holed blob**, and Wrap is not expected to close holes much wider than the gap. 5.1 #32 and 5.2 #12 change accordingly.
2. **A positive Wrap offset is outward.**
3. **The Shell wall check by nearest point stays.**
4. **Plane Cut by two trims stays.**

No code changes follow from these decisions.

---

## 4. Bound methods (for team M)

Common to every op:
- `time_limit` (default 20, clamped to 0.05..120).
- `name`: the body's name for messages. When missing it is "the body" (or "The body" at the start of a sentence).
- `skip_estimate` (bool, tests only): the op starts even when its own estimate does not fit, so the watchdog and deadline are what stop it. Tools must not pass it.
- A value of the wrong kind is refused: "<Label> must be a number." / "<Label> must be on or off." / "<Label> must be one of: a, b, c."
- Ranges are refused with "<Label> must be between <a> and <b>." Lengths are printed in mm below 10 m, in m below 1 km and in km above, as plain numbers with four digits and never an exponent ("0.0000866 mm", "43.3 m", "1.732 km"; second fix round). Each bound gives by one millionth of its own size, so range tests should step outside by at least 1e-4 relative.
- Time: "<Op> would take about <n> s on this mesh (limit <l> s). <hint>" before work; "<Op> took longer than <l> s and was stopped. <hint>" after.
- Every report has `phases` ({step: ms}) and `estimate` (s) besides the 2.6.3 keys.
- Shared refusals for a body Manifold cannot take (the "unfit" sentences, each starting with the body's name):
  - "<Body> is not closed (<n> open edges). Close Holes or Wrap it first."
  - "<Body> has <n> edges that more than two triangles share. Run Stitch and Remove first."
  - "<Body> has triangles that face the wrong way (at <n> edges). Run Reverse Normal first."
  - "<Body> has <n> parts that are inside-out. Reverse Normal can fix them."
  - "<Body> has no triangles." / "<Body> has no triangles with area. Run Stitch and Remove first."
- **One of a thing is said in the singular (fix round):** "(1 open edge)", "has 1 edge that more than two triangles share", "(at 1 edge)", "has 1 part that is inside-out. Reverse Normal can fix it.", "<Op> made 1 triangle without area.", "<Op> made 1 place where the mesh crosses itself.", "1 part is inside-out.", "1 cut edge stays open". Tests that match these sentences must allow both forms.
- **Bodies that cross themselves (fix round):** every op that needs a clear inside now tests its inputs itself, with up to 1 s per body out of the time limit. The count goes into the report (`input_self_intersections`; -1 means the test could not finish in that time, which happens above roughly 150,000 to 300,000 triangles). The op's own estimate includes that time.

### `boolean(tools: Array, options := {}) -> CadMesh`
- **Options:** `operation` join / cut / intersect (default join); `tool_names` (PackedStringArray or Array; default "Tool body <i>").
- **Groups:** the target's names, then each tool's. A name already taken becomes `name (2)`, `(3)`.
- **Refusals:** "Combine needs at least one tool body."; "Combine needs mesh bodies: item <i> is not one."; "Combine needs <n> triangles in all; mesh bodies take up to 2,000,000. Reduce the bodies first."; the unfit sentences for the target and each tool. Time hint: "Reduce the bodies first."
- **Empty result:**
  - Intersect: returns null with "The result is empty (the bodies do not overlap)." and `get_last_report()` = `{"op": "boolean", "empty": true, "checks": {...}, "ms"}`.
  - Cut: returns an empty CadMesh (`is_null()` true) with the warning "The result is empty (the tool bodies cut all of <body> away)." and `"empty": true`.
  - A result with triangles has `"empty": false`. A refusal for any other reason has no `empty` key.
- **Must hold (null with the sentence):** closed and manifold; every triangle from an input; volume (join between the largest input and the sum, cut at most the target's, intersect at most the smallest, tolerance 1e-6 of the largest input plus what rounding the result to float32 can move: 1.2e-7 x the largest coordinate x the result's area); Manifold's own volume equals ours after the way back (1e-5 of the largest input plus the same rounding allowance; it was relative to the result, which failed on thin leftovers).
- **Warnings (changed in the fix round):**
  - "<Name> crosses itself, so the result may be wrong there. Rebuild it first." for every input (target or tool, by its name) whose own test finds crossings, at any size, whatever the result's count does.
  - "<Name> could not be tested for places where it crosses itself in the time left (it is too large to test in 1 s); if it does, the result may be wrong there." when that input's test could not finish.
  - "Combine made <n> places where the mesh crosses itself." only when every input was tested clean.
  - "The joined body is still <n> separate pieces: bodies that only touch, or do not meet, are not fused." Join only, when the result has more solid pieces than it could have if every tool had fused with something (the inputs' pieces together, less one per tool). Two cubes that touch on a face give this (Manifold leaves them as two shells); a tool that fuses with one of a target's two pieces does not.
  - The shared `finish_op` sentences ("Combine made <n> triangles without area.").
- **Report extras:** `empty`, `groups_lost`, `pieces` (closed shells of the result with a volume above zero), `input_self_intersections` (PackedInt64Array, target first, -1 = not tested), `self_intersections` (the result's count, -1 = not tested).
- Open bodies, wrong-way triangles and inside-out parts are refused by the unfit sentences, so G's interference case will see those as errors, not as "empty".

### `merge_with(others: Array) -> CadMesh`
- No options. Arrays are put one after the other, unchanged, with no weld. Name clashes as in `boolean`.
- **Refusals:** "Merge needs at least one other mesh body."; "Merge needs mesh bodies: item <i> is not one."; "Merge needs mesh bodies with triangles: item <i> has none."; "Merge would make <t> triangles, <v> vertices and <g> face groups; mesh bodies take up to 2,000,000, 2,000,000 and 100,000. Reduce the bodies first."

### `plane_cut(options) -> Array`
- Returns `[above, below]`; either may be null; `[]` on failure. "Above" is the side the normal points to.
- **Options:** `origin` Vector3 (default 0,0,0); `normal` Vector3 (required); `offset` (-D..D, default 0, along the normal); `type` trim / split_body / split_faces (default trim); `flip` (default false: trim keeps above); `fill` none / uniform / minimal (default uniform).
- **Results by type:** trim gives `[above, null]`, or `[null, below]` with flip. split_faces gives `[mesh, null]`.
- **New groups:** the cut face is `cut<k>` (the first free number, the same name on both parts). split_faces puts the upper side of each crossed group into `<name>_cut`.
- **Refusals:** "Plane Cut needs a plane (its normal is missing)."; "The plane's normal must have a length."; "The plane does not cut <body>." (before work, when all used vertices lie on one side within 1e-7 D, and again if a side comes back empty); "Plane Cut would make <n> triangles; mesh bodies take up to 2,000,000. Reduce the body first." (split_faces). Time hint: "Reduce the body first."
- **Must hold (solid input, fill not none):** each part closed and manifold; split volumes sum to the input within 1e-6 plus a float32 allowance of 3e-8 x area x D; trim volume at most the input's and not below zero by more than that allowance; export volume check (1e-5 of the body's volume plus the rounding allowance; it was relative to the part, which failed on thin slivers).
- **Fix round:**
  - A plane that passes between the pieces of one body, or along a face two pieces share, is no error any more: each piece goes to its side whole, with no cut group, and the warning "The plane passes between the pieces of <body>: nothing was cut, each piece went to its side." (`checks.cut`). Trim gives the pieces on the kept side.
  - A side on which nothing with a thickness is left gives "The plane does not cut <body>." (also after the work).
  - A plane that lies on a wall of the body (a void's wall) gives the same part on every axis: the wall, which Manifold returns back to back with the cut face on some axes, is taken out with the cut face and the cut is filled again from its rim. The false "1 parts are inside-out." is gone with it. A wall counts as on the plane within 4.8e-7 x the body's largest coordinate, and only triangles more than 1,000 times larger than that.
- **Warnings:**
  - "<n> cut edges stay open (the body was open there)."
  - "The cut could not be filled (<n> cut edges stay open). <unfit sentence>" for a body with no open edge that is still no solid.
  - "The cut face kept its plain fill (it could not be filled evenly)."
  - "The cut face was filled with triangles larger than the body's (<x>) to stay under 2,000,000 triangles."
  - "Plane Cut made <n> triangles without area." appears when the plane clips a corner within about 1e-6 D of a vertex. These are real slivers. With Split Body both parts' counts are one sentence (third fix round): "Plane Cut made 5 triangles without area (3 in the upper part, 2 in the lower)."
  - "Each piece of <body> was cut on its own: pieces that touch or overlap each other stay so (Rebuild makes one solid of them)." (third fix round)
  - "Plane Cut left <a> mm2 of a face of <body> that lies on the plane as a wall without thickness. Move the plane off that face a little first." (`checks.fin`; third fix round, not reached by any known input)
- **Report extras:** `parts` (one report per side), `cut_group`, `cap_triangles`, `through_manifold`.

### `wrap(options := {}) -> CadMesh` (C++ name `wrap_op`)
- **Options:** `detail` (D/400..D/10, default max(D/150, the smallest cell that fits 2,000,000 samples)); `gap` (detail..D/4, default 2 x detail); `offset` (-gap..D/10, default 0, positive is outward).
- **Result:** one group `wrap0`.
- **Refusals:**
  - "Wrap needs <n> million cells; raise Detail to <x>."
  - "Wrap would leave all of <body> out: it is open to the outside through gaps wider than <2 gap> (twice Close Gaps Up To), or thinner than <detail>. Raise Close Gaps Up To (its largest opening is about <x> across), or add an Offset." The same with "about <p> %" when more than half of the input's **surface area** is outside the result (fix round: it was the share of vertices). This one comes after the work, not before.
  - Time hint: "Raise Detail."
- **Must hold:** closed, manifold, no inside-out part, positive volume.
- **How "left out" is measured (fix round):** 20,000 points spread over the input by area, at least four on every connected part; a point is out when it lies outside the wrap and more than 1.5 x detail (plus an inward offset) from it. `left_out` is the area share of those points.
- **Warnings:**
  - always "Edges are rounded to about <detail>."
  - "<Share> of <body>'s surface is not inside the wrap (up to <x> outside it): those parts are thinner than <detail>, or open to the outside through gaps wider than <2 gap>. [<k> of its <m> separate parts are not in the wrap at all.] Raise Close Gaps Up To, lower Detail, or add an Offset." <Share> is "About 27 %", "About 0.31 %" (two digits below 10 %), or "Less than 0.01 %". The bracketed sentence appears when the body has more than one connected part and at least one is more than half out.
  - "Wrap filled <n> inner voids of <body>." (fix round) when the body has voids the outside does not reach.
- **Report extras:** `deviation` {max, mean, samples} from the input to the wrap; `left_out` (area share, 0..1); `left_out_parts` (the first 100 connected parts that are more than half out, each `{first_triangle, triangles, area_share}`; the native side has no body names, so a tool that merged several bodies maps `first_triangle` back to its body); `parts` (connected parts with area); `filled_voids`; `cells`, `detail`, `gap`, `offset`.

### `rebuild(options := {}) -> CadMesh`
- **Options:** `detail` (D/600..D/10, default max(D/250, fit)); `method` union / exact_surface (default union).
- **Result:** one group `rebuild0`.
- **Refusals:**
  - "Rebuild needs <n> million cells; raise Detail to <x>."
  - "Rebuild found no inside in <body> (its triangles enclose nothing). Use Wrap." Now only for a body that is open or has no volume.
  - (fix round) "Rebuild would lose all of <body>: its parts are thinner than <detail> (the cell size), so no cell lies inside them. Lower Detail." for a closed body in which no cell is inside, and the same with "about <p> %" when more than half of its surface area is not in the result. This one comes after the work.
- **Must hold:** closed and manifold.
- **What was lost is measured (fix round),** the way Wrap measures what it left out (points by area, out when outside the result and more than 1.5 x detail from it), and the distance from the input to the result is in the report.
- **Warnings:**
  - (fix round) "<Share> of <body>'s surface is not in the result (up to <x> from it): parts thinner than <detail> were lost. [<k> of its <m> separate parts are gone.] Lower Detail." (`checks.covered`).
  - "<Body> has open edges; Rebuild treats them as closed by the nearest surface. Close Holes first for a better result."
  - "Rebuild changed the volume by <p> % (from <a> mm3 to <b> mm3); parts that overlapped count once now." This fires on the self_crossing fixture (-15.6 %), as the spec's 2 % rule makes it. Since the fix round the clause about overlaps is there only when the volume fell, nothing was lost and the body's sides agree; otherwise the sentence ends after the numbers.
  - "<Body> has triangles that face the wrong way, so Rebuild went by counting the surfaces it crosses: where parts of it overlap, the result may be hollow. Run Reverse Normal first for a better result."
  - "<Body> has <n> parts that are inside-out: where they overlap other parts, the result may be hollow. Reverse Normal can fix them first."
  - always "Edges are rounded to about <detail>."
- **Report extras:** `cells`, `detail`, `snapped_vertices`; (fix round) `deviation` {max, mean, samples} from the input to the result, `left_out`, `left_out_parts`, `parts` as for Wrap.

### `shell(options := {}) -> CadMesh`
- **Options:** `thickness` (D/2000..D/4, default D/50); `direction` inside / outside / both (default inside); `method` fast / accurate (default accurate); `detail` (accurate only: t/10..t/2, default max(t/4, fit)).
- **Groups:** the input's names stay on the surface that lies on the input (for fast Both, on the outer one). The new wall is `shell<k>`; the fast rim along open edges is the next `shell<k+1>`. Accurate Both is all `shell0`.
- **Refusals:**
  - "A <t> wall does not fit in <body> (thinnest part about <x>)." Closed bodies, inside or both, both methods, before work.
  - "An open body has no inside; use Both, or Close Holes first." (accurate)
  - The unfit sentences (accurate inside/outside); the non-manifold and wrong-way sentences (fast).
  - "Shell needs <n> million cells; raise Detail to <x>."
  - "Shell needs <n> million cells for a <t> wall on this body; use the Fast method, or a wall of at least <x>." This fires when no cell size both resolves the wall and fits the grid, for example a 1 mm wall on a 100 mm ball.
  - "Shell would make <n> triangles; mesh bodies take up to 2,000,000. Reduce the body first." (fast)
  - "A <t> wall leaves no room inside <body>. Use a thinner wall."
  - (fix round, replaces "so its shell would too") "<Body> crosses itself in <n> places, so it has no clear inside to shell. Rebuild it first." Accurate inside and outside, before the work, whenever the body's own test finds crossings. Accurate Both and Fast still run on such a body.
  - (fix round) "Shell made a wall of <a> mm3 on a body of <b> mm3, which cannot be right: <body> may cross itself or have parts that face the wrong way. Rebuild it first." An accurate shell whose volume is not above zero never passes, nor an inside shell with more volume than the body it was cut from.
  - (fix round) "The shell crosses itself in <n> places: <body> may cross itself (it is too large to test in 1 s). Rebuild it first." when the result crosses itself and the body could not be tested.
  - Time hints: "Raise Detail, or use the Fast method." (accurate), "Reduce the body first." (fast).
- **Must hold:** closed and manifold. Accurate also needs the wall check to pass and no new crossings.
- **Warnings (accurate, fix round):**
  - "<Body>'s <n> face groups became one (shell0): Both makes a new surface on each side." Both, when the body had more than one group.
  - "<Body> could not be tested for places where it crosses itself (it is too large to test in 1 s); if it does, the shell is wrong there." Inside and outside.
- **Warnings (fast only; the result is kept):**
  - "The fast shell crosses itself in <n> places; use Accurate."
  - "The wall is off: <p> % of 400 samples are within 0.7 to 1.3 x <t> (measured <a> to <b>). Use Accurate."
  - "The fast shell was not tested for places where it crosses itself (the mesh is too large to test in 1 s); use Accurate to be sure."
- **Report extras:** `wall` {samples, within, min, max, mean, target}, `cells`, `detail`, `thickness`; (fix round) `input_self_intersections` (-1 = not tested), `self_intersections`.
- **Fix round, the crash away from the origin:** the level set is now built with a guard (see "Fix round" below), so no input reaches the fault in the mesh library. The same guard is in Wrap and Rebuild.

### `separate(options := {}) -> Array`
- Returns the pieces ordered by smallest triangle index; `[]` on failure.
- **Options:** `by` components / groups (default components).
- Each piece keeps the input's vertex order, triangle order, positions (to the bit) and group names.
- One piece: the array holds the input instance itself, with the warning "<Body> is one piece; nothing to separate."
- **Warning:** "<n> pieces are inside-out. Reverse Normal can fix them." ("1 piece is inside-out. Reverse Normal can fix it.")
- **Refusal (not in the spec):** more than 1,000 pieces: "<Body> has <n> separate pieces; Separate makes up to 1,000 bodies. Run Stitch and Remove first to drop the small ones." Since the fix round the pieces are counted first (the body's connected parts, less the voids that go to a parent), so this comes back in milliseconds and before any work in the mesh library; `by: groups` with more than 1,000 groups is refused the same way.
- **Fix round, the time limit:** the mesh library's own split (`Decompose`) cannot be stopped and costs about parts x triangles x 6.5e-8 s, so it now runs only when parts x triangles is at most 20,000,000 (about 2 s); the estimate counts it. Since the second fix round it also runs only when it fits the time limit (section 9); otherwise it is left out, not refused. Above that the pieces are the body's connected parts with their voids, which is what was returned before too (the library's split could only ever join them); `checks.decompose` then reads "ok: left out (too many parts for it); the pieces are the body's connected parts".
- **Report:** `output` {pieces, triangles: PackedInt32Array}, `through_manifold`, `voids_attached`, `manifold_parts`.

### `displace(options) -> CadMesh` (Texture Extrude)
- **Options:**
  - `image` PackedByteArray (brightness, rows from the top), `width`, `height` (1..16,384)
  - `depth` (-D/10..D/10, not 0, default D/200)
  - `mapping` planar / box / cylindrical (default box)
  - `tile` (D/1000..10 D, default D/5)
  - `angle` in degrees (-360..360, default 0)
  - `invert` (default false)
  - `detail` (tile/512..tile/8, default tile/128)
  - `triangles` and/or `groups` (PackedInt32Array; neither means the whole body)
  - `refine` (default true; false moves the existing vertices only)
- **Refusals:** "Texture Extrude needs an image (its brightness as bytes, with a width and a height of 1 to 16,384)."; "The image is <w> x <h> pixels but has <n> brightness values."; "Depth must not be 0."; "Texture Extrude needs a selection with triangles."; "The selection names triangle <i>, but the body has <n>." (the same for face group); "Texture Extrude would make about <n> triangles; raise Detail or Tile Size." (before work); "Texture Extrude would make more than 2,000,000 triangles; raise Detail or Tile Size." Time hint: "Raise Detail or Tile Size."
- **Must hold:** every vertex that is not free is the input's to the bit; closed stays closed.
- **Warnings (fix round: the op tests its result itself, up to 1 s, at any size):**
  - "The extrusion crosses itself in <n> places; lower the Depth." whenever the count is known (less the crossings the body had before, when those could be counted).
  - "The extrusion was not tested for places where it crosses itself (the mesh is too large to test in 1 s); lower the Depth if it does." when the test could not finish.
- **Report extras:** `moved_vertices`, `max_displacement`, `detail`; `self_intersections` (-1 = not tested) and `checks.self_intersections` ("ok", "warn: the result crosses itself in <n> new places", "warn: not tested in time").

### `op_defaults(method: String, options := {}) -> Dictionary` (extra, not in C4)
- For "wrap", "rebuild", "shell", "plane_cut", "displace", "boolean" (which takes `options.tools`).
- Returns the default of every field, with voxel defaults already raised to fit the grid; `<field>_min` / `<field>_max` as the native side checks them; `cells`; `seconds` (the op's own estimate, for the 0.5 s preview rule); and `problem` when the given options would be refused.
- This is how the panel can show the raised default (2.6.2). It touches no error state.

## 5. Measurements and constants

All are in the N3 block of `mesh_budget.h`, with the raw numbers in comments. Sizes are about 100k / 500k / 2M triangles on `large_grid` boxes; seconds, one run.

| What | Measured | Stored (x 1.5) |
|---|---|---|
| Ingest of one body (our MeshGL64 copy + `ctx.FromMeshGL`) | 0.090 / 0.49 / 2.28 | `MF_INGEST {0.14, 0.74, 3.4}` |
| Union after ingest, by all triangles | 0.089 / 0.48 / 1.56 | `MF_UNION {0.31, 0.87, 3.50}` (the spike's numbers kept, see below) |
| Subtract, the same | 0.054 / 0.28 / 0.86 | `MF_SUBTRACT {0.41, 0.47, 2.50}` (spike kept) |
| One plane trim after ingest | 0.081 / 0.44 / 2.14 | `MF_TRIM_BY_PLANE {0.13, 0.66, 3.3}` |
| Result back as a mesh body | 0.0075 / 0.057 / 0.16 | `MF_EXPORT {0.012, 0.086, 0.24}` |
| `finish_op` without the self-intersection test | 0.036 / 0.21 / 0.85 | `OP_FINISH {0.054, 0.32, 1.3}` |
| Decompose and parts read back | 0.043 / 0.23 / 0.78 | `MANIFOLD_DECOMPOSE {0.065, 0.34, 1.2}` |
| Own plane clipper | 0.019 / 0.10 / 0.42 | `PLANE_CLIP {0.03, 0.15, 0.65}` |
| Shell fast | 0.031 / 0.16 / (0.64 extrapolated) | `SHELL_FAST {0.047, 0.24, 0.96}` |
| Even cap fill, per million triangles made | 0.47-0.76 s | `CAP_FILL_SECONDS_PER_MILLION_TRIANGLES 1.2` |
| Texture Extrude, per million result triangles | 0.31-0.39 s | `DISPLACE_SECONDS_PER_MILLION_TRIANGLES 0.6` |
| LevelSet triangles per h x h of surface | 5.4-5.7 | `LEVEL_SET_TRIANGLES_PER_CELL_AREA 6.0` |

- **Fix round constants:** `DECOMPOSE_MAX_PARTS_X_TRIANGLES 2e7` (above it Separate leaves the library's split out), `DECOMPOSE_SECONDS_PER_PART_TRIANGLE 1e-7` (measured 6.5e-8: 10,000 tetrahedra took 26 s), `COVERAGE_SECONDS 0.5` (the left-out measure of Wrap and Rebuild, in their estimates).
- **Booleans:** my boxes cross along a few lines and measured well below the spike's bumpy-torus halves, so the spike's larger numbers stay for the boolean itself.
- **Whole ops at 2M triangles:** boolean join 3.9-4.1 s, plane cut trim 5.0-5.3 s, split body with even fill 8.5 s, separate 2.8 s.

**Own voxel code, seconds per million grid samples (the item section 4 asked for; quiet machine):**
- Distance field: 0.21-0.91 at a band of 2.5-4.5 cells; 1.67 at 12.5 cells. It costs by the samples within its band of the surface, so the stored rate grows with the band: `VOXEL_SECONDS_PER_MILLION_CELLS 0.4` + `VOXEL_SECONDS_PER_MILLION_CELLS_PER_BAND_CELL 0.22` x band in cells.
- Exact distance transform: 0.022-0.028.
- Flood: 0.002-0.009.
- Winding columns: 0.013-0.027.
- Wrap's function: 0.016-0.033.
- `LevelSet` itself measured 0.69-2.0 in 14 runs. The stored 4.6 stays as the spec says, so the estimate for a 1.9M-cell wrap is about 13 s for a 2.8 s run. Previews will often be skipped.

**Cancel latency (8.1 row 23), measured as how long after its limit the whole op was back, clean-up included:**
- `LevelSet`: 2-50 ms.
- Boolean of 2 x 995k: 0.21-0.30 s. This differs from the spike's 45 ms; mine includes freeing two 1M-triangle solids and ran under load.
- Plane trim of 2M: 0.48-0.76 s.
- During `ctx.FromMeshGL`: up to 0.52 s on a 1M body and 0.86 s on a 2M body. It checks for the cancel only between its steps. The "+1 s" bound held in every run but with little room at 2M, so the rule that a limit below the ingest estimate is refused up front must stay.
- `Decompose` and `GetMeshGL64` take no context and cannot be stopped; they measured under 0.8 s at 2M.

## 6. Differences from the spec, each with its reason

**Decisions needed:**

1. **5.1 #32 cannot pass as written.** The holed blob's holes are 6 to 40 mm across, and a 3 mm gap closes openings up to about 6 mm, so the flood reaches inside and nothing is enclosed. My test uses gap 26 mm with detail 1.5 mm (ratio 0.9943), a 6 mm hole with a 4 mm gap (ratio 1.0012), and asserts that the spec's own numbers are refused with the "gaps wider than 6 mm" sentence. 5.2 #12 needs the same change. Counter-proposal: test with gap at least 22 mm, or decide that Wrap should also close holes much wider than the gap, which needs a different inside test (I did not build that).
2. **Wrap offset sign.** The spec's formula makes a positive offset shrink the wrap, while its grid rule ("grown by gap + offset") only makes sense if positive is outward. I implemented positive as outward, with the same numeric range. If inward was meant, it is a one-line flip.
3. **Shell wall check measure.** The spec's ray along the inward normal fails on a correct shell of a box: near an edge the ray runs inside the neighbouring wall and exits the far side (about 14 % of a cube's area at D/50, so under 95 %). I measure 400 area-weighted samples on the new surface against the nearest point of the input, with the same 0.8..1.2 / 0.7..1.3 and 95 % rules. The test also checks the ball's wall independently by the sphere formula.
4. **Plane Cut uses two `TrimByPlane` calls, not `SplitByPlane`.** Measured: `SplitByPlane` does its work inside the call where no context reaches, and a 2M split came back 2.2 s after its limit. Trims are deferred and stop. The cost is that Split Body is two booleans (4.2-4.5 s at 2M instead of 2.6 s). Caps still come in a run with a foreign id, and volume sums stay within 1e-8.

**Other differences:**

5. **Separate** always builds pieces from the input's own arrays. Manifold `Decompose` is run on closed solids as the contract says (the triangle index travels as faceID), but it can only join our edge-connected components, never split them. Voids go to the first positive shell up the nesting rule's parent chain. Since the fix round `Decompose` runs only when parts x triangles is at most 20,000,000, because it cannot be stopped and its time grows with that product.
6. **Texture Extrude** does its own refinement (long edges split at the middle, pass by pass), not N2's remesh. Border edges are split too, and the one ring of triangles outside the selection is split in place along them. Leaving border edges whole never terminates: a triangle that keeps a long edge can never get short edges (I hit this on the L-bracket). No vertex outside the selection moves, but "triangles outside the selection are bitwise unchanged" does not hold for that ring. `refine: false` lets M chain N2's `remesh` instead.
7. **Rebuild on flipped triangles.** The spec's "winding along +Z, inside = not 0" gave 1.27 x the ball's volume on `flipped_half` (below the ball the winding is 2). When the mesh has wrong-way edges I count crossings by parity instead and warn; result 519,003 against 519,093 mm3.
8. **Plane Cut fill on open bodies** uses Manifold's `TriangulateIdx` on the closed cut loops (it handles holes), not N2's Close Holes code. The result is checked by area before it is used.
9. **Even cap fill** uses the body's mean edge length on a square grid, at least half a cell from the outline, then Delaunay flips. It removes the zero-area cap triangles Manifold's own fill leaves.
10. **Wrap field.** A plain distance transform to the outside samples biases the surface outward by about half a cell (about 3 % volume on the test). I correct it with each outside sample's own distance to the surface, searched over the nearest sample and its 26 neighbours.
11. `skip_estimate`, `op_defaults` and the 1,000-piece cap are additions.

## 7. Unfinished, unverified, and known risks

- **Self-crossing inputs** (changed in the fix round): Combine tests every input and names the ones that cross themselves; accurate Shell inside and outside refuses them; Texture Extrude tests its result. Each test has 1 s; above roughly 150,000 to 300,000 triangles with many crossings (or on a busy machine) it cannot finish, and the op then says that the body was not tested instead of saying nothing. Plane Cut and Separate still say nothing natively: their result is as wrong as the input (the feature layer adds its own note for those).
- **Wrap and Rebuild can return a partial result with only a warning** when under half of the input's surface is left out. Over half is an error. That refusal comes after the full run (1.8-4.5 s on the test), not before.
- **The level-set guard depends on how Manifold 3.5.4 walks its grid** (see section 8, B1). A newer Manifold needs the off-origin scan run again.
- **Shell's "does not fit" estimate is coarse.** It is the smallest of the three axis-wise longest chords over 20 rays. It catches plates, not a thin leg on a thick part; there the accurate shell still runs and its wall check passes because the wall is correct where it exists.
- **Texture Extrude mappings are my own definitions** (planar by the selection's mean normal, box by each vertex's dominant normal axis, cylindrical about the world axis the normals lean on least). Only box on the plate and planar on a ball cap are tested for values.
- **Rebuild Exact Surface** can in principle create crossings when it snaps; the shared check warns. Its default detail gives 240k-330k triangles from small inputs, which is the spec's D/250.
- **Time bound gaps:** `finish_op` and my post-checks have no deadline of their own (they are linear and in the estimates). A deadline that expires during a 2M-triangle ingest came back up to 0.86 s late under load.
- **Not tested at all:** more than 100k groups in a merged result, group names near 64 bytes through `_cut` / `(2)` suffixes, Plane Cut's "coarser fill" warning, and the watchdog on Shell's boolean step specifically.
- **Budget mirror:** I did not touch `core/features/mesh.gd`; no cap changed, only rates.
- The copies in `...\scratchpad\phase7\teamN3\src\` are early drafts; the files in `holo_forge_native\src` are the real ones.

## 8. Fix round, 2026-11-12 (verifier V2)

Tests: `tests/holo_forge_mesh_regress_manifold_test.gd` (new; every case is the verifier's input; the crash cases each run in a child process) and `tests/holo_forge_mesh_native_manifold_test.gd`.

| Finding | What changed | Where to read it |
|---|---|---|
| B1 Accurate Shell crashed away from the origin | The crash is in Manifold 3.5.4's level set: its vertex table starts small, and when it fills before the first surface vertex has been made the code reads the entry before the first one, sizes the next table from that and writes outside it. A flat face that lies midway between two layers of the grid does it; the origin only decides how the faces fall on the grid. Our level set now carries a guard: four cells of room below the grid in x and a small blob at the first point Manifold visits, so the first vertices exist before the table can fill. The guard's triangles are taken out again before the result is used. Wrap and Rebuild use the same code. | Shell, Wrap, Rebuild |
| B2 Separate ignored its time limit on many closed pieces | Pieces are counted first and more than 1,000 are refused at once. The library's own split, which cannot be stopped, runs only when parts x triangles is at most 20,000,000 and is in the estimate. | Separate |
| B3 Accurate Shell on a body that crosses itself | The body is tested first; inside and outside refuse it by name. A shell with no volume, or an inside shell larger than its body, never passes. | Shell |
| B4 Texture Extrude dropped its crossing warning on large results | The op runs its own test at any size and says so when the test could not finish. | Texture Extrude |
| B5 Combine said nothing about inputs that cross themselves | Every input is tested and named; "could not be tested" when the test did not finish. | Combine |
| B6, P8 Rebuild lost thin parts in silence | What was lost is measured by area and said with how far and how much; `deviation`, `left_out`, `left_out_parts` in the report; a body whose parts are all thinner than the cell is refused for that reason. | Rebuild |
| P1 Plane Cut between pieces | The pieces come back on their sides with a warning. | Plane Cut |
| P2 Plane Cut thin sliver | The way-back check is relative to the body, with an allowance for float32 rounding. | Plane Cut, Combine |
| P3 Plane Cut on a void's wall | The wall is taken out with the cut face and the cut refilled: the same part on every axis, no false warning. | Plane Cut |
| P4 Wrap's "left out" share | Measured by surface area; the connected parts that are out are listed in `left_out_parts` and counted in the sentence. | Wrap |
| P9 Singular forms | "1 part is", "1 triangle", "1 place", "1 cut edge stays", "1 open edge", "1 edge". | Common |
| Notes | Join that leaves separate pieces says so (`pieces`); estimates no longer depend on what the mesh has cached; accurate Shell Both says the groups became one; Wrap says when it filled inner voids (`filled_voids`); `transformed` refuses a move that makes more than half of the triangles fall together ("The move is not valid: at that distance or size <n> of the mesh's <m> triangles would fall together into a line or a point (positions keep about 7 digits).") or shrinks the mesh below 0.000001 mm ("The move is not valid: it would shrink the mesh to less than 0.000001 mm across, smaller than a mesh body can be."). | Combine, Shell, Wrap |

**For team M:**
- Sentences that changed and that a test may match exactly: every "1 parts are" / "made 1 triangles" / "made 1 places" / "1 cut edges stay" form; Shell's "so its shell would too" sentence is gone; Rebuild's volume sentence ends after the numbers unless overlaps are the known cause; Wrap's left-out sentence now starts with the share ("About 27 % of <body>'s surface is not inside the wrap ...").
- New report keys: Combine `pieces`, `input_self_intersections`; Shell `input_self_intersections`; Wrap `left_out_parts`, `parts`, `filled_voids` (and `left_out` is an area share now); Rebuild `deviation`, `left_out`, `left_out_parts`, `parts`; Texture Extrude `checks.self_intersections`; Separate `checks.decompose`.
- Wrap on several bodies merged into one: `left_out_parts[i].first_triangle` tells which merged body a left-out part came from; the native side has no body names.
- Plane Cut can now return parts with no cut group (the plane passed between pieces).

**Off-origin scan after the fix** (one process per case; shift (a, 0.7 a, 0.3 a) for a = 0.3, 1.7, 13, 211 m; default options): cube, 6x6-grid cube, hollow cube and L bracket through Wrap, Rebuild (both methods), Shell accurate inside / outside / both, Shell fast and Texture Extrude: 144 cases, 0 crashes, every result closed. Before the fix the verifier counted 22 crashes in 36 accurate Shell cases on the first three bodies. At 211 m positions step by 0.015 mm, so volumes there are off by about 0.1 % (accurate Both: 0.8 %).

## 9. Second fix round, 2026-11-13 (re-verifier R1)

Tests: four new checks in `tests/holo_forge_mesh_regress_manifold_test.gd` (`_check_plane_cut_through_vertices`, `_check_far_from_origin_reasons`, `_check_separate_preview`, `_check_plain_numbers`).

### N4. Plane Cut through vertices (regression of the first fix round)
- **Cause:** the first round's fix for a plane on a void's wall (`mend_skin`) took any original triangle whose three corners lie on the plane for such a wall. Where the plane passes through a vertex or along an edge, or within about 1e-7 D of one, the clipped triangles come back as long slivers along the plane; they were taken out with the cut face and the new fill then shared edges with what was left.
- **Change:** a wall must be more than 1,000 tolerances long, more than 100 tolerances high over its longest edge, and face along the plane's normal to within 0.999. After the new fill the part is tested edge by edge; if any edge does not have exactly two triangles that run it opposite ways, the part stays as the mesh library made it.
- **Result:** the first round's sweep of 11,050 cuts: 0 refused (140 before), 0 wrong volumes. The 4 flags left are the ones the sweep had in the first round too: the tip of an open plate, 0.000000002 mm2 in area, whose area differs after rounding to float32. The re-verifier's 468 centre planes: 0 refused (108 before); its 240 near-vertex cuts (two rounds of 120): 0 refused (28 before).

### N8. Far from the origin: the true reason, before the work
Positions are float32, so at a coordinate of size R they step by about R / 8,000,000 (0.015 mm at 130 to 260 m, 0.06 mm at 1 km).
- **Refusal, every voxel op, fast Shell, Texture Extrude and Plane Cut:** "<Body> is <d> from the origin, where positions are stored only to about <step>: <why>. Move it nearer the origin first." <d> is the distance of the body's box centre. It fires when the step is more than:

| Op | Limit | <why> |
|---|---|---|
| Wrap, Rebuild | Detail / 8 | "too coarse for a Detail of <detail>" |
| Shell accurate | Detail / 8 | "too coarse for a wall of <t> (built from cells of <detail>)" |
| Shell fast | Thickness / 8 | "too coarse for a wall of <t>" |
| Texture Extrude | Depth / 8 | "too coarse for a Depth of <depth>" |
| Plane Cut | D / 1,000 | "too coarse to cut a body <D> across" |

- With default options a 20 mm body is refused by the voxel ops once its largest coordinate passes 256 m and by Plane Cut once it passes 512 m; a 1.3 mm body by the voxel ops beyond 16 m. `op_defaults` returns the same sentence as `problem`.
- **Past the 1,000 km limit:** "<Op> would put the mesh more than 1,000 km from the origin, farther than a mesh body can be. Move <body> nearer the origin first." for Shell outside and both, Wrap, Rebuild and Texture Extrude, when the body's box grown by the wall, the offset plus a cell, or the depth passes the limit. It replaces "made a broken mesh (internal error)".
- **Plane Cut** now allows two position steps when it checks that the cut's triangles lie on the plane, and its volume check allows for rounding at the body's distance.
- **Warning, Combine and Plane Cut:** "<Name> is <d> from the origin, where positions are stored only to about <step> (<p> % of its size), so the result is rounded by about that much. Move it nearer the origin first for an exact result." when the step is more than a ten-thousandth of the body's size (a 20 mm body beyond about 32 m). Combine names the input that loses most. `checks.precision`.
- "internal error ... Please report it" stays only on checks that no known input reaches.

### N10. Separate and the time limit
The library's split is left out when it would not fit the time limit, and the pieces are the body's connected parts with their voids (the same pieces). `checks.decompose` then reads "ok: left out (it would not fit the time limit); the pieces are the body's connected parts". Separate still refuses when its own part does not fit ("would take about 0.69 s (limit 0.5 s)" on 634,880 triangles; the run takes 0.27 s, so that estimate is about 2.5 times high).

### Numbers in sentences
- Lengths: see the common rules at the top. "Shell needs 12,400 million cells for a 0.00008662 mm wall", "Thickness must be between 0.0000866 mm and 0.0433 mm.", "measured 0.00006727 mm to 1 mm".
- Rebuild on a body with no measurable volume (no open edge, but edges that more than two triangles share): "<Body> had no volume that could be measured (it is not a clean closed body); the result has <v> mm3." It replaces a percentage of zero.

### For team M
- A test that pins "made <n> triangles without area" on a Plane Cut near vertices depends on what counts as "without area" in the shared summary, which another team changed on 2026-11-13 05:58 (each triangle by its own shape). The same geometry now gives other counts.
- Voxel ops and Plane Cut on small bodies far from the origin are now refused where they used to return rounded results; the sentence names the distance and the step.

## 10. Third fix round, 2026-11-13 (re-verifier R3)

Tests: three new checks in `tests/holo_forge_mesh_regress_manifold_test.gd` (`_check_plane_cut_on_shared_face`, `_check_plane_cut_inner_wall`, `_check_plane_cut_sentences`). Before the change they failed: 88 of 450 cuts wrong and 88 refused, flakes and "1 part is inside-out" on the turned copy, 168 of 244 U-channel cuts with a fin, 27 of 120 split warnings with a sentence twice, and an exponent in the volume refusal.

### How a solid is cut now
Each side Manifold gives is checked against the **plain cut**: the body's triangles split by the plane exactly, with no fill. Taken about a point of the plane, a cut face adds no volume, so the plain cut gives each side's volume whatever the fill. A face that lies on the plane (all corners within 4 float32 steps of the largest coordinate) goes whole to the side it bounds.

A side fails when:
- its volume differs from the plain cut's by more than 1e-6 of the body, plus float32 rounding over the body's area, plus the snap distance over the area near the plane;
- on-plane triangles face the way no face of that side can (along the normal on the upper part) with more than 16 x the tolerance x the cut's length in area;
- with fill, an edge does not have exactly two opposite triangles;
- with Fill None, its open edges are not as long as the plain cut's, or its area along the normal differs.

A failed side is cut again with our own clipper, the one open bodies use, with the wider snap. That result is kept if it passes the same checks; `checks.own_cut` then says so, and `through_manifold` is false.

If our own cut fails too:
- **Volume:** refused with "Plane Cut could not cut <body> cleanly: on the side it keeps the body has <a> mm3, but the cut came out with <b> mm3. Check <body> for pieces that cross or overlap each other."
- **Wall without thickness:** Manifold's part is kept, with the `checks.fin` warning.
- **Not closed:** the existing closed check refuses it.

No known input reaches any of these three.

Cost: the extra passes over the triangles. The estimate gains a third of a clip. `mesh_native_manifold`'s 1M plane cut ratio is 469 (limit 980; it was 466).

### B2. A small cube standing on a big one, cut on the face between them
- **Cause:** the body is two pieces that touch face to face. Manifold takes them for one solid, and its trim then moved a corner of the small cube onto the big cube's face. The kept part was a closed 12-triangle box of 156 to 210 mm3 instead of 216 mm3. Turned, a flake of zero volume came back as an inside-out part. With Fill None the big cube came back with a ring of walls 0.000001 mm high around where the small cube stood.
- **Change:**
  - The plain cut's volume catches the lost volume.
  - The wrong-facing area catches the flake.
  - The open-edge length catches the ring.
  - Our own cut then gives each cube to its side whole.
- **Result:** the re-verifier's 225 positions: 0 wrong (88 before). Split Body: 0 refused (88 before). The turned copy gives the two cubes with no flake. All three fills now give the same parts, with "The plane passes between the pieces of Body: nothing was cut, each piece went to its side."
- Two cubes that overlap (a pair the library unites) are now cut piece by piece. The volumes add up to the body's, with the warning that each piece was cut on its own. Before, Split Body refused with exponents, and Trim kept a union of a different volume with no word.

### B3. The inner wall of a U channel
- **Cause:** with the plane on the wall, Manifold kept some or all of that wall back to back with the cut face. That is a fin of up to 10 x 10 mm, closed and with the right volume, so `check()` passed it. Whether it happened depended on rounding, which is why it varied with placement. The first round's mend did not take it out when the wall came back split into slivers.
- **Change:** the wrong-facing area check catches it, and our own cut gives the wall to the side it bounds.
- **Result:** 61 placements x Trim and Split Body x 2 fills: 0 fins (168 of 244 before). Every kept part is 3,000 mm3 and 1,400 mm2.

### Sentences
- With Split Body both parts' sentences go into one list, each said once. Counted sentences add up: "Plane Cut made 50 triangles without area (20 in the upper part, 30 in the lower)." This covers triangles without area, edges shared by more than two triangles, inside-out parts and places where the mesh crosses itself. Before, two counts stood side by side, and the same count from both parts was said once.
- Volumes in Plane Cut's sentences are in mm3, as plain numbers with as many digits as it takes to tell them apart:
  - "Plane Cut's two parts have <a> mm3 together, but the body had <b> mm3. Check <body> for pieces that cross or overlap each other."
  - "Plane Cut kept <a> mm3 of a body of <b> mm3. ..."
  - "... (volume <a> mm3 became <b> mm3). Please report it."

### Unchanged checks
The first round's sweep of 11,050 cuts: 0 refused, 0 wrong volumes. It still has the 4 open-plate area flags from round 1. The re-verifier's 468 centre planes (r08b): 0 refused, 0 wrong. Its near-vertex cuts (r08) give the same parts as before; only the merged sentences differ.

### op_defaults for team N2's ops
Remesh, Smooth, Reduce and Close Holes refuse a body that is too far from the origin before any work. They do this through team N2's `mesh::far_refusal` at the length each one works at:
- **Smooth, Reduce, Close Holes:** `mesh::typical_edge`.
- **Remesh:** the finest edge it is asked for, or the body's own (its selection's) mean edge when that is finer.

`op_defaults("remesh" | "smooth" | "reduce" | "close_holes", options)` now gives the same sentence as `{"problem": ...}` before the op runs, built with N2's helpers and reasons. It gives `{}` when the body is near enough; these ops have no other defaults here.

Test: `_check_far_defaults` checks a 10 mm ball 30 km out, with three Remesh option sets. Before the change `op_defaults` gave `{}` for all six calls.

### Proposed accepted limits
- The plain cut takes a body as its triangles say. Pieces that overlap are cut each on its own and stay overlapping; the warning says so and names Rebuild.
- A fin smaller than 16 x the tolerance x the cut's length in area is not caught. With the tolerance at 4.8e-7 of the largest coordinate, that is about 0.006 mm2 for a 20 mm cube cut across near the origin.
- When both the library and our own cut fail, the part is refused (volume) or kept with the fin warning. No known input does this.
