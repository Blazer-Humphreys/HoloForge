# Phase 7 Convert Mesh as built (team C)

The orchestrator accepted every difference from the spec listed here (2026-11-12). Team U wires the Form Body output into OK and prints `report.stat` in the stat row (Stage 4). `mesh.gd` must keep `_cross` and `BODY_TOKEN` stable besides the nine functions team M listed.

Sections 3 to 8 are team C's Stage 3 report (2026-11-12), with the sentences, caps, times and checks that the fix round changed brought up to date in place (marked "fix round"). Section 9 lists what the fix round changed and why; section 10 what the second fix round (2026-11-13, re-verifier R2's findings) changed. The section numbers are the report's own.

---

## 3. Interface

**Entry point for M's dispatch:** `static func build(feature, ctx) -> String` in `core/features/mesh_convert.gd`. M's `mesh.gd` already calls exactly that; no change needed there.

**What my file calls in `mesh.gd`:** the nine functions M listed in `phase7_tools_as_built.md` (`Run`, `_finish`, `_made_ids`, `_mm`, `_plain`, `named`, `is_time_refusal`, `cache_key`, `time_limit`), plus two not on that list: **`_cross`** and the const **`BODY_TOKEN`**. Please keep those stable too.

**Feature options and inputs** (as U's panels write them; a missing input takes the default):

| Method | Options | Inputs |
|---|---|---|
| `convert_faceted` | `bodies`, `merge_flat` [true], `result` | `flat_tolerance` [D×1e-6; 0 .. D/100]; read only when `merge_flat` is on |
| `convert_prismatic` | `bodies`, `allow_spheres` [true], `result` | `tolerance` [D/1000; D×1e-6 .. D/20] |
| `convert_organic` | `body` (exactly one), `output` brep / form_body [brep], `result` | `faces` [500; whole, 24 .. 5,000], `tolerance` [D/500; >0 .. D/10] |

- `result`: `new_body` [default] or `replace`.
- New bodies are B-rep entries (no `kind`), named `<Body> Solid` or `<Body> Surface`, registered and listed in `options.outputs` / `options.made` by M's own bookkeeping. A preview registers nothing.
- New Body hides the mesh body once, on the full-time build that first registers the converted body. Replace erases the mesh body's entry.
- If one body fails, the feature adds none.
- Fix round: `output` form_body takes bodies of 2 mm across and more (`MESH_CONVERT.FORM_BODY_MIN`); see section 9, B3.

**Native methods (bound on `CadMesh`):**
- `to_faceted(options) -> CadShape`: `merge_flat`, `flat_tolerance`, `time_limit`, `name`, `skip_estimate` (tests only).
- `to_prismatic(options) -> CadShape`: `tolerance`, `allow_spheres`, `time_limit`, `name`, `skip_estimate`.
- `convert_defaults(method, options) -> Dictionary`, with `method` `"faceted"` or `"prismatic"`: defaults, `<field>_min` / `<field>_max`, `seconds`, `problem`; Prismatic also gives `surfaces`, `planes`, `cylinders`, `spheres`, `crossing_pairs`, `corners`. It leaves the mesh's messages untouched.
- Reports follow 2.6.3 where it applies, plus `phases`, `estimate`, `volume_change`. `output` is `{faces, solids, closed, valid, volume, area, ...}`. Prismatic adds `surfaces`, `crossing_pairs`, `corners`, `cells`, `kept_cells`, `mixed_cells`, `unknown_cells`, `unused_surfaces`, and `deviation {max, mean, samples, mesh_to_result, result_to_mesh, allowed}`.
- Fix round: a Prismatic report (a refusal's too) also holds `scale` (the copy it worked on against the body), `touching`, `equal_radii`, `meeting_axes`, `skipped_groups`, `unmeshed_cell_faces`, and `output.drawn_deflection`. All lengths, volumes and areas in the report are the body's own, whatever the scale.

**GDScript helpers:**
- `MESH_CONVERT.add_convert(doc, method, body_ids, options := {}, inputs := {}) -> {feature, error}`
- `MESH_CONVERT.clear_cache()`, `MESH_CONVERT.cache_hits`
- `MESH_CONVERT.form_body(doc, feature) -> {feature, body, error, note}`
- `ORGANIC.convert(mesh, options) -> {error, warning, cage, shape, report}`, `ORGANIC.refusal(mesh, options)`, `ORGANIC.seconds_after_remesh(faces)`

**Two things for team U:**
1. **Output Form Body is not wired into OK.** A feature cannot add a feature during a rebuild, so the convert feature shows the cage's solid and warns "The Form Body output is not in the timeline yet: <Feature> shows its solid." `MESH_CONVERT.form_body(doc, feature)` swaps it for a Form feature holding the cage, in the same timeline position. U must call it in `accept_command` after the full-time recompute and before `commit_change`, when `options.output == "form_body"` and the feature has no error. It is tested headless only (5.4 #8).
2. **The stat row does not show my `stat` line.** I publish `MESH.reports[feature.id]` with `stat`, `warnings`, `bodies` and no `input` / `output` (a converted body has faces, not triangles). U's `stat_text` then prints only "Bodies made: 1". It should also print `report.stat` in that branch.

**Refusal sentences** (`<Body>` is the body's name; M's `named()` puts it in). Sentences the fix round added or changed are marked (fix round).

- *Faceted, before any work*
  - "<Body> has no triangles."
  - "<Body> has n triangles; Convert Mesh: Faceted takes up to 60,000. Reduce it first."
  - "<Body> has n edges that more than two triangles share. Run Stitch and Remove first."
  - "<Body> has triangles that face the wrong way (at n edges). Run Reverse Normal first."
  - "<Body> has n triangles without area. Run Stitch and Remove first."
  - (third fix round) When the body lies farther from the origin than its size and those triangles are thinner than a ten-thousandth of the position step there: "<Body> is d from the origin, where positions are stored only to about s: n of its triangles are thinner than that and have no area. Convert the mesh before it is placed this far from the origin, then move the converted body there." (Stitch and Remove is not named: it keeps such triangles when taking them out would open the mesh.) When only some are: "<Body> has n triangles without area. It is d from the origin, ..., and m of them are thinner than that. Run Stitch and Remove first, and convert the mesh before it is placed this far from the origin."
  - (third fix round) "<Body> is d from the origin, where positions are stored only to about s, a hundredth of its size or more: its corners have run together and it encloses no volume. Convert the mesh before ..." in place of "encloses no volume" when the place is the cause (Prismatic too).
  - "<Body> has n edges shorter than 0.0005 mm, which a solid cannot hold. Run Stitch and Remove with a larger Stitch Tolerance first."
  - (fix round) "<Body> has 1 piece with no volume (triangles that lie back to back). Run Stitch and Remove first." ("n pieces"). Stitch and Remove with its defaults takes such a piece out (tested).
  - (fix round) "<Body> encloses no volume (its triangles lie back to back): there is nothing to make a solid of." When every piece is such a piece. Prismatic and Organic refuse such a body with the same sentence.
  - (fix round) "<Body> has 1 part that is inside-out. Reverse Normal can fix it." / "<Body> has n parts that are inside-out. Reverse Normal can fix them."
  - "Flat Tolerance must be between 0 mm and x mm." / "Merge Flat Face Groups must be on or off."
  - "Convert Mesh: Faceted would take about n s on this mesh (limit l s). Reduce the body first."
- *Faceted, after work*
  - "Convert Mesh: Faceted took longer than l s and was stopped. Reduce the body first." (True again since the fix round: a merged body now converts faster than the same body with Merge Flat off; section 9, B1.)
  - "The converted body failed the solid check [at n faces]. Turn off Merge Flat Face Groups, or run Stitch and Remove on <body> first."
  - "The converted body's volume is off by x % from <body>'s (limit y %). Lower the Flat Tolerance."
  - "n faces of the converted body would be drawn wrong (...)."
- *Faceted warnings*
  - "<Body> is open, so the result is a surface body."
  - "<Body> crosses itself, so the result may be wrong there. Rebuild it first." (M's sentence, from the feature.)
  - (fix round) "1 piece of <body> lies in the same place as another piece, so the result holds it twice. Run Stitch and Remove first." ("n pieces ... hold them twice"). Stitch and Remove with its defaults leaves one (tested).
  - (fix round) "n flat areas of <body> were not merged: this far from the origin the mesh's corners are stored only to about x, more than the Flat Tolerance. Raise the Flat Tolerance to x or more." When x is more than the field's largest value (D / 100), the tail is "..., more than the Flat Tolerance can be (y). Move the body nearer the origin first."
- *Prismatic, before any kernel call*
  - "Generate Face Groups first, so each flat or round area is its own group." (Fix round: only when the body's one face group is not one flat or round area; a ball in one group converts.) Third fix round: Prismatic runs Generate Face Groups (Accurate) on its working copy to see whether it would split the group (up to 2 s of the limit). When it would: "Generate Face Groups (Accurate) first, so ...". When it would not (a coarse ball: Accurate gives one group, so "Generate Face Groups first" and "Accurate" pointed at each other): "<Body> is one smooth area that no plane, cylinder or sphere follows within t (best: sphere, off by x): a Fit Tolerance that wide would change its volume by about p %. Use Convert Mesh: Faceted, or Organic for a smooth solid." (or "... Raise the Fit Tolerance to x or more, or use Convert Mesh: Faceted, or Organic for a smooth solid." when x would pass). When it cannot be found out in time, the second round's sentence stands.
  - "<Body> has n triangles; Convert Mesh: Prismatic takes up to 200,000. Reduce it first."
  - N3's "unfit" sentences (open, non-manifold, wrong way, inside-out).
  - "<Body> has n face groups; Convert Mesh: Prismatic looks at up to 1,500. ..."
  - "<Body> is n separate solids; Convert Mesh: Prismatic takes one at a time. Separate it first."
  - (third fix round) When the group is off its best surface by no more than the body's stored corners can hold where it lies (the body far from the origin): "Face Group n is not flat or round within <tol> (best: cylinder, off by <x>): <body> is d from the origin, where positions are stored only to about s. Raise the Fit Tolerance to x or more, or convert the mesh before it is placed this far from the origin and move the converted body there." (without the first step when x would not pass). No grouping step is named: none changes it.
  - "Face Group n is not flat or round within <tol> (best: cylinder, off by <x>). Use Generate Face Groups (Accurate) or Convert Mesh: Faceted." (Fix round: when nothing at all could be fitted the bracket reads "(no plane, cylinder or sphere could be fitted to it)"; a group whose triangles have no area is skipped, not refused.)
  - (second fix round) The same refusal ends "... Raise the Fit Tolerance to <x> or more, use Generate Face Groups (Accurate), or Convert Mesh: Faceted." when the group is all but flat or round: x is a value the field takes (at most D / 20) and the result would still hold the body's volume (0.6 × the group's area × x is at most 0.4 % of the volume). A body of one such group gets this sentence instead of "Generate Face Groups first". Tested: the tolerance named converts a ball.
  - (fix round) "Face Group a and Face Group b are x apart, the two sides of a wall no thicker than the Fit Tolerance (t). Lower the Fit Tolerance below x."
  - "<Body> needs more than 150 surfaces; Prismatic takes up to 150. Combine face groups to make fewer surfaces, or use Convert Mesh: Faceted."
  - "Convert Mesh: Prismatic would take about n s on <body> (limit l s): p pairs of round holes cross. Use Convert Mesh: Faceted." When the corners dominate, the tail is "its n surfaces cut each other into too many cells. Combine face groups ...".
  - "Fit Tolerance must be between a and b." / "Allow Spheres must be on or off."
- *Prismatic, after work*
  - "Convert Mesh: Prismatic took longer than l s and was stopped. Combine face groups to make fewer surfaces, or use Faceted."
  - "The surfaces of <body>'s face groups close no cells / do not close one solid (<why>). ..."
  - (fix round) "None of the cells the surfaces of <body>'s face groups close lies inside it. Lower the Fit Tolerance, use Generate Face Groups (Accurate), or Convert Mesh: Faceted."
  - "The result failed the solid check. ..."
  - "The result's volume is off by x % from <body>'s (limit 0.5 %). ..." (Third fix round: for a body of one face group that Generate Face Groups (Accurate) leaves whole, these sentences after work end "Use Convert Mesh: Faceted, or Organic for a smooth solid." instead of naming the Fit Tolerance or a grouping, which give the same body back.)
  - "The result is up to x away from <body> (allowed y), near Face Group n. ..."
  - "n faces of the result would be drawn wrong ...".
  - (fix round) "The result would be drawn with a gap: n edges of the triangles drawn for the result would stay open (the kernel's mesher fails on it at this size and place). Use Convert Mesh: Faceted." (Or "n faces of the result are not covered by the triangles drawn for them".)
- *Prismatic warnings*
  - "n surfaces of <body>'s face groups left no face on the result (...)."
  - (second fix round) "Face Group a (radius x) was given the radius of Face Group b (y): Convert Mesh: Prismatic cannot tell radii d apart here. Lower the Fit Tolerance below t[, or move the body nearer the origin,] to keep them apart." Said when two cylinders whose radii differ by more than a tenth of the Fit Tolerance were given one radius (section 7, item 13); t is four times the difference. Tested: under the tolerance named the radii stay apart.
- *Organic*
  - "<Body> has n triangles; Convert Mesh: Organic takes up to 200,000. Reduce the body first (Fast method)."
  - "<Body> is not closed. Close Holes or Wrap it first."
  - "<Body> is n separate solids; ..."
  - (fix round) "<Body> is hollow (n closed surfaces); Convert Mesh: Organic makes one smooth surface. Use Convert Mesh: Faceted."
  - "Target Cage Faces must be a whole number between 24 and 5,000." (Fix round: also for a value that is no number.)
  - "Allowed Deviation must be more than 0 and at most x mm."
  - "Convert Mesh: Organic would take about n s on <body> (limit l s). Lower Target Cage Faces." (Third fix round: also when the cage's own count, after the remesh, puts the rest over the time left; it said "took longer than l s and was stopped" after 0.1 to 0.4 s.) Called on its own (not through the feature), Organic names "the mesh" (option `name`), not "{body}".
  - Remesh's time refusal, with "(the first step of Convert Mesh: Organic) Reduce the body first (Fast method)."
  - (fix round; in place of Remesh's own sentences about Edge Length and Density) "A cage of n faces cannot follow <body>: its even triangles would lie too far off it. Raise Target Cage Faces, or use Convert Mesh: Faceted." / "Convert Mesh: Organic could not remesh <body> into the even triangles of a cage of n faces. Try another Target Cage Faces, or use Convert Mesh: Faceted."
  - "The smooth surface is up to x away from the mesh (allowed y). Raise Target Cage Faces or Allowed Deviation."
  - "The solid is up to x away from the mesh ...", "n faces of the solid ... would be drawn wrong".
  - (fix round) "The solid's volume is off by x % from <body>'s (limit 5 %). Lower Allowed Deviation or raise Target Cage Faces."
  - Warning between 1× and 4× tolerance: "The smooth surface is up to x away from <body> (Allowed Deviation y)."
  - (fix round) Warning when the cage came out with more than twice the faces asked for: "The cage of <body> has n faces (Target Cage Faces m): fewer would need edges longer than a fifth of the body."
- *Feature level*
  - "<Body> is not a mesh body: there is nothing to convert."
  - "Body <x> no longer exists" / "Select a mesh body"
  - "Result must be New Body or Replace." / "Output must be Solid Body or Form Body."
  - "Convert Mesh: Organic takes one mesh body at a time."
  - (fix round) "<Body> is x across: a form body that small rebuilds too slowly (Form takes bodies of 2 mm and more). Use Output: Solid Body."
  - (second fix round) Behind a refusal for lack of time when the feature's bodies before this one used part of its time (third fix round: on full-time builds too): " (The bodies before it used the rest of the feature's l s: pick fewer bodies at once.)" (team M's sentence).
  - (third fix round) "<Body>: Convert Mesh: Faceted would take about n s on <Body> (limit l s). Reduce the body first. (The bodies before it ...)" for a kept body that took more than the time the bodies before it leave (section 4).
  - (third fix round) Warning: "<Body> was converted again: its kept result had been let go to stay within 512 MB of kept results." ("256 kept results"). Said on the feature whose body was converted again because its kept result was let go by that cap. Replaces the second round's "Convert Mesh keeps the results of 256 bodies (512 MB) and this design has more: ... and will be on every rebuild", which named the count when the bytes were the cause and is no longer true: nothing a rebuild holds is let go.

## 4. Measured times and caps

Dev machine, one run each, other teams' tests running at times; stored × 1.5.

**Faceted:** 0.13 to 0.20 ms per triangle.

| Triangles | Time |
|---|---|
| 4,800 | 0.62 s |
| 19,200 | 2.8 s |
| 20,480 | 3.8 s |
| 58,800 | 11.5 s |

- Three quarters is the kernel's per-face validity check, which can be stopped.
- The estimate (third fix round) counts the faces the result will have, after the flat patches are found (a few milliseconds): 0.22 s per 1,000 faces plus 0.10 s per 1,000 edges of the merged faces' outlines. It is the expected time, not padded, and refuses only what would not fit, since the rest stops on time (0.13 to 0.15 s past limits of 1 to 5 s). Before, it was 0.30 s per 1,000 triangles: a flat 39,762-triangle plate that merges into one face in 0.02 s was refused at 9 s ("about 12 s"). The cap is 60,000 triangles.
- A preview (0.5 s) skips a body whose result would have more than about 2,200 faces.
- Fix round, flat plates with one long outline (the verifier's `p12`, `p14`; 20 s limit; before the fix in brackets):

| Body | Outline edges | Merge Flat on | Merge Flat off |
|---|---|---|---|
| comb plate, 20,000 triangles | 10,202 | 0.69 s (26.3 s, stopped) | 4.6 s |
| perforated plate, 20,000 triangles | 10,300 | 1.06 s (40.5 s, stopped) | 4.7 s |
| stripes plate, 20,000 triangles | 10,300 | 1.83 s | 5.1 s |
| comb plate, 57,800 triangles | 29,242 | 2.1 s (208.7 s, stopped) | 13.1 s |
| perforated plate, 57,800 triangles | 29,410 | 3.2 s | 14.0 s |
| stripes plate, 57,800 triangles | 29,410 | 6.2 s | 13.9 s |
| kernel plate with 196 round holes, 38,428 triangles (through the feature) | | 5.5 s (22.1 s, stopped) | 9.4 s |
| kernel plate with 289 round holes, 56,656 triangles (through the feature) | | 7.4 s (25.1 s, stopped) | 13.6 s |

- Third fix round: the estimate now counts these plates' outline edges (about 1.0 s for the 20,000-triangle comb, 2.9 s for the 57,800 one), so a merged body is no longer refused up front at a limit it would fit in.

**Prismatic** (whole op, with the cell pick and every check):

| Body | Time |
|---|---|
| L-bracket (9 surfaces) | 0.04 s |
| 21 surfaces, nothing crossing | 0.29 s |
| 4 crossing pairs | 0.25 to 0.4 s |
| 15 pairs | 1.2 s |
| 50 pairs | 3.2 s |
| 120 pairs | 7.7 to 10.1 s |
| 200 pairs, 145 surfaces | 15.3 to 16.0 s |
| Waffle, 256 corners / 147 cells | 0.33 s |
| Waffle, 784 corners | 1.25 s |
| Waffle, 1,936 corners / 1,323 cells | 3.3 s |

- That is 0.045 to 0.076 s per crossing pair (the spike's 0.22 s was not seen again), about 0.005 s per surface, and 0.9 to 1.6 ms per corner where three flat surfaces meet.
- Estimate: `0.5 s × T/100k + 0.01 × surfaces + 0.11 × crossing pairs + 0.0024 × corners`.
- Caps: 200,000 triangles, 150 surfaces, 1,500 face groups (new), exactly one solid part.
- Fix round: two crossing cylinders of one radius now cost 0.02 s for their cells (0.1 s before), three such 0.08 s (0.48 s): they are cut in ellipses. The box with four rounds at 0.16 mm and 0.08 mm long: 0.2 to 0.5 s at limits of 2, 5 and 20 s (16 to 29 s before).

**Organic:**

| Cage faces | Time after the remesh |
|---|---|
| 277 | 1.1 s |
| 648 | 2.3 s |
| 2,628 | 10.1 s |

- Estimate: 0.4 s + 6 ms per target face. Above about 3,300 faces at 20 s it is refused before any work, so **the panel's 5,000 maximum can only be reached with a longer time limit**.
- Caps: 200,000 triangles, 5,000 cage faces.
- Fix round: a ball of 5,120 triangles at 200 faces takes 1.2 to 1.6 s at every radius from 50 mm down to 0.025 mm (27 s at 0.1 mm and 58 s at 0.025 mm before); at 500 faces and 0.1 mm 3.5 s (69 s before).

**Kept results** (fix round): up to 256 converted bodies and 512 MB (4 KB counted per face), least recently used first out (12 bodies before). A refusal for lack of time is kept and answers the next rebuild; it is tried again only when the time on offer is more than 1.1 × what it had + 0.05 s. Third fix round: a kept body that a rebuild's bodies still hold (the design open, or the one being built; told by its reference count) is never let go, since dropping it frees nothing and the next rebuild would convert it again; so the caps bound only what the cache alone holds, and a design of any size rebuilds without converting anything. A body converted again because its kept result was let go says so, naming the cap ("Plate0 was converted again: its kept result had been let go to stay within 512 MB of kept results.").

**A feature's time over its bodies** (third fix round; the second round's "every body gets the whole limit" made a feature take up to its bodies × the limit while the panel says "up to 20 s"): a feature's bodies share its limit. Each body gets the limit less what the bodies before it are charged, and never more than is left. A body converted now is charged what it took. On a full-time build a kept body is charged what it took when it was converted, and a kept result that took more than 1.1 × what the body has now + 0.05 s is refused with the time sentence, as a build from scratch would refuse it; so a design builds the same from scratch as in the session and the feature takes no longer than its limit. A preview charges a kept body nothing (it answers at once). A body refused for time after others used some gets team M's sentence.

**Time bound:**
- Prismatic stopped 0.00 to 0.02 s after its limit at every limit from 0.5 to 6 s on the 120-pair body.
- Faceted stopped 1.05 s into a 1 s limit; the 57,800-triangle comb and perforated plates, made to run at a 2 s limit, stopped after 2.06 and 2.08 s (fix round).
- Not stoppable, guarded by estimates only: Faceted's shell/solid check and measuring (about 2 s at 60k faces), Prismatic's face merging, and Organic's cage fit and Phase 6 `to_shapes`. The kernel's mesher cannot be stopped inside one face either: Prismatic and Organic keep it from running away by working at a size it handles (section 9, B2 and B3).

## 5. Post-checks and what a failed check does

**Faceted** (a failure refuses, except the warnings):
- Every shell closed, for a closed mesh; solids and voids assembled by the nesting rule.
- The kernel's validity check of every face, then of each shell (one piece, closed, oriented) and each solid.
- Fix round: a merged face whose outline has more than 400 edges is checked piece by piece instead (every edge by the kernel; every wire in one piece and closed), because the kernel's check of a whole face grows with the square of the outline and cannot be stopped. What that check would add is covered another way: the outline's loops do not cross each other or themselves (tested edge against nearby edge when the patch is found; a patch that fails stays triangles), they enclose the patch's flat area, and the face's triangles cover it. When the squared outlines add up to more than 4 million, the shell's "every edge between two faces, in opposite directions" is checked in one pass of our own rather than by the kernel's, for the same reason.
- Fix round: a closed piece with no volume is refused before any work.
- Closed body: B-rep volume against the mesh volume. Allowed is `min(1 %, 1e-4 + what the merged faces' deviation explains)`.
- Open body: B-rep area against the expected area, to 1e-6.
- Every merged face's drawn triangles must cover the face (`measure::face_drawable`).
- Every corner of a merged patch lies within the Flat Tolerance of its plane; the measured deviation goes into the face, edge and vertex tolerances.
- Face names are unique (fix round: a group named like another group's triangle face gets a name of its own).
- Warnings: open body; body that crosses itself; the same piece twice in one place (fix round); flat areas left unmerged because the stored corners are coarser than the Flat Tolerance (fix round).

**Prismatic** (every failure refuses):
- Each face group's distance from its surface, measured at corners, edge middles and triangle middles, at most the tolerance.
- Exactly one solid; shells closed; the kernel's validity check (one ShapeFix attempt, then the same check again).
- Volume within 0.5 % of the mesh.
- Every face meshed at the viewport's deflection and covered by its mesh.
- Every face lies on one fitted surface.
- Distance both ways, limit 3 × tolerance: about 4,000 points on the result's faces to the mesh, and up to 2,000 mesh points (corners and area-spread points) to the result's faces.
- Fix round, as changed in the second fix round: the finished body, at its own size and place and with no triangles on it (as the viewport gets it), is meshed as the viewport meshes it; every face must be covered and the drawn triangles must close (every edge between two of them). If not, the body is refused with "The result would be drawn with a gap". The triangles are then taken off again: **no triangles leave Prismatic**. The body goes out as the kernel's own tools hand theirs out, geometry only, and is moved back from the working copy the way the kernel's own Move and Scale move a body (section 10, R1).
- Warning only: a surface that left no face.

**Organic** (every failure refuses, except the two warnings):
- The smooth surface against the mesh both ways, 20,000 samples each: refused above 4 × tolerance, warned above 1 ×.
- The solid itself: one closed solid; Phase 6's own validity notes; every face drawable.
- The solid's drawn triangles against the mesh both ways, limit 4 × tolerance + the display deflection.
- Volume from the welded drawn triangles. If those do not close, the volume check is skipped with a warning. Fix round: a volume more than 5 % off the mesh's is refused.

## 6. Extra results from probes

Not in the test file; logs are in `...\scratchpad\phase7\teamC\` (`probe3.log`, `probe4.log`, `probe7.log`, `probe8.log`).
- Prismatic also converted: a plate with 4 and 12 holes, a stepped block, a chamfered box, a through slot with round ends, and a box with one fillet.
- Both the Prismatic and the Faceted L-bracket took a kernel cut, join and fillet, a BRep byte round trip, and Tessellate back. For Prismatic all 9 group names came back.
- A box with every edge filleted (12 cylinders, 8 sphere corners, 64 crossing pairs) was **refused after 7.2 s** with "they close 2 separate solids". No wrong body, but that shape does not convert.
- Fix round (`...\teamC\fix\probe_cross_3.log`): two crossing pipes of one radius and a block with two crossing holes of one radius, each at 18 sizes from × 0.01 to × 1,000 and turned by 0, 0.3 and 0.7 rad: 108 of 108 converted and drew closed.
- Fix round: the verifier's own probes run again on the fixed build, logs in `...\teamC\fix\v3after\`. Its Prismatic sweep (`p20`, 1,378 cases): 763 converted clean (the rest are refusals, mostly "Face Group n is not flat or round" on its tolerance and noise ladders); its placement sweep (234 cases): 207 converted, against 172 before; every refusal left there is a cone, a torus, a one-group torus or the box with every edge rounded.

## 7. Differences from the spec, each with its reason

1. **5.4 #9 uses a 0.3 s limit, not 1.0 s.** With the measured pair rate, the crossing-holes body estimates at 0.58 s and really takes 0.25 to 0.4 s, so 1.0 s no longer refuses it.
2. **Faceted does not use `exchange::mesh_shape`, MakeShapeOnMesh, sewing or UnifySameDomain.** I build vertices, edges and faces from the mesh's own topology. Reasons: every loop can be stopped; merged faces need no loosened unify tolerance; nothing is healed silently.
3. **Faceted faces carry the mesh's own triangles as their drawn mesh.** The mesher is never asked; the display shows exactly the converted triangles and `CadShape.tessellate` reuses them (triangle counts equal in the test).
4. **Merge Flat works per edge-connected flat patch of a group.** Names: `<group>` when the group is one patch, else `<group>/p<k>`; other triangles `<group>/t<k>`. A group that is not flat is not split into flat parts, so a one-group cube stays 12 faces.
5. **Prismatic's fit error includes edge middles and triangle middles on round groups.** A coarse round group is therefore refused with its real chord height instead of converting to a body whose volume is off.
6. **Prismatic does not fuse cells.** Kept cells share faces, so the solid is the set of faces that only one kept cell has. ShapeFix runs only when the validity check fails.
7. **Cell pick points are mid-chord** (halfway from a face triangle to the cell's far wall), not a 1e-3 step. A thin cell and a point near the mesh surface cannot mislead it. Fix round: of up to sixteen such points per cell, the five that lie inside the cell and farthest from its walls are asked (section 9, P1a).
8. **New Prismatic refusals:** more than 1,500 groups (each `fit_primitive` call allocates per vertex), and bodies that are not exactly one solid part.
9. **Fitted normals and axes snap** to a coordinate axis or an already-used direction when that costs the fit under a tenth of the tolerance. `fit_primitive` returns float32 vectors; plane offsets are recomputed in doubles. Prismatic applies its own tolerance to the three fits' errors and does not read `fit_primitive`'s `winner`. Fix round: a direction all but square to one or two already in use is set exactly square to them, under the same rule (section 9, P1b).
10. **Organic aims at 1.55 triangles per cage face, not 2.** About a third of the triangles find no partner, and 2 gave 30 % more faces than asked.
11. **Organic's exact B-rep volume is not computed.** `CadShape.volume()` took about 20 s on 3,900 spline faces.
12. **Fix round: Prismatic works on a copy of the body** with its middle at the origin, brought to 0.2 m across when the body is under 20 mm or over 2 m; the solid goes back to the body's place and size at the end, and messages and reports speak in the body's own lengths. (Second fix round: it goes back as geometry only, by the same call the kernel's own Move and Scale use; no triangles go along.)
13. **Fix round: Prismatic sets surfaces that all but touch to touch exactly**, within `snap = min(tolerance / 4, max(D × 2e-5, four steps of the stored corners))` and only while every group still lies on its surface within the tolerance: a cylinder onto a plane it touches along a line (a rounded edge), cylinders of all but one radius to one radius, and the axes of two crossing cylinders of one radius to meet.
14. **Fix round: Organic converts a body under 10 mm across on a copy at 100 mm** and brings the cage and the solid back; Output Form Body is refused under 2 mm (section 9, B3).

## 8. Unfinished, unverified, and risks I could not close

- **No UI run of any kind.** Not tested in the editor: the `form_body()` call in OK, the stat row, previews of converts, hiding the mesh body on commit and undo of that.
- **Faceted near the cap under load.** 58,800 triangles took 11.5 s in one run and 19.6 s in another that also had display work and other load. At 50,000 to 60,000 triangles on a busy machine it can end in the time-out sentence after 20 s rather than an up-front refusal.
- **Organic's time bound rests on estimates.** A slow `to_shapes` would run past the limit. Measured on balls only; a harder cage may cost more per face. (Fix round: the one cause the verifier found, bodies under a few millimeters, is closed by converting on an enlarged copy.)
- **Organic quality is narrow.** It worked on a ball at 200 to 2,000 faces. It refused a bumpy blob at 200 and 500 faces (3 to 4 mm against an allowed 1.4 mm), passed it at 2,000 with a warning, and refuses sharp-edged parts. Honest refusals, but it is only useful on smooth shapes. A needle (100 × 8 × 8 mm) is refused at 200, 400, 800 and 1,500 faces and converts at 3,000 with a warning: "Raise Target Cage Faces" is true there only in the long run.
- **Prismatic deviation check at shallow edges.** A mesh corner within tolerance of two planes that meet at a shallow angle can be farther than 3 × tolerance from the sharp edge; that gives a refusal, not a wrong body.
- **Mixed cells are only reported** (`mixed_cells`). They are kept at 4 of 5 votes and the volume and deviation checks are the guard; the rounded box had 2 mixed cells and came out right.
- **Not tested:** cylinder-sphere and sphere-sphere crossings beyond one ball-on-post case; more than one void in Prismatic; `convert_defaults` from a panel.
- **Faceted bodies of self-crossing meshes** are overlapping solids, with M's "crosses itself" warning. That test is M's `crossing_note`, which says nothing about coplanar overlaps. (Fix round: the same piece twice in one place is now warned of by Faceted itself.)
- **Mirror in `mesh.gd`:** I added no caps there. `MAX_PRISMATIC_GROUPS` (1,500) lives only in `mesh_convert.cpp`; Organic's constants live in `organic.gd`.
- An earlier 330 s outlier in one probe was the machine sleeping, not a defect; it did not reproduce in three reruns.
- **Fix round, still open:**
  - The kernel's mesher cannot be stopped inside one face. Prismatic's cells are meshed at a size where no run-away was found (every body is between 20 mm and 2 m when it is meshed); a face that runs away at that size would still take Prismatic past its limit.
  - A Form feature's own rebuild of a cage under about a millimeter takes tens of seconds and cannot be stopped (Phase 6's conversion: 3.3 s at 0.9 mm, 29 s at 0.35 mm). Convert Mesh no longer makes such a feature, but a form body scaled down by other means would.
  - Bodies of about 0.2 mm made by the kernel itself draw with open edges at the viewport's smallest deflection (0.01 mm): a 0.2 mm plate with a hole 16, a 0.1 mm one 18. That is the kernel's mesher on any body of that size, not Convert Mesh. A Prismatic result is meshed by the same mesher as every other body (second fix round: it carries no triangles of its own), and is refused when what the viewport would draw of it does not close.
  - Faceted's estimate is per triangle and too high for bodies that merge well (section 4).

## 9. Fix round (2026-11-12): verifier V3's findings

Tests: `tests/holo_forge_mesh_regress_convert_test.gd` (each case is the verifier's smallest input; parts can be picked with `HOLO_FORGE_MESH_REGRESS_ONLY`), and one changed case in `tests/holo_forge_mesh_convert_test.gd` (#5 uses a one-group cube, since a one-group ball converts).

- **B1, Faceted past its limit on one flat face with a long outline.** Cause: the kernel's check of a whole face looks every edge up among all the face's edges and compares every wire with every other (and its check of a shell looks every edge up among its faces' edges), which grows with the square of the outline and cannot be stopped. Change: long outlines are checked piece by piece and the shell in one pass (section 5). The time-out was paid again on every rebuild because the kept refusal was dropped when the next rebuild offered a hair more time; it is now kept and retried only with clearly more time (section 4). The hint "Reduce the body first" is true again: with the quadratic check gone, a merged body converts faster than the same body with Merge Flat off (table in section 4), so no hint names Merge Flat.
- **B2, Prismatic past its limit on a 0.16 mm body.** Cause: the kernel's tolerances are absolute (0.1 micrometer); on a body that small a round of a few micrometers is lost in them and meshing its cells did not end. Change: the copy at 0.2 m (section 7, item 12).
- **B3, Organic past its limit on tiny balls.** Cause: Phase 6's conversion of a cage to a solid slows down steeply under a few millimeters and cannot be stopped. Change: bodies under 10 mm are converted on a copy at 100 mm and brought back. Output Form Body would hand the small cage to a Form feature, which rebuilds it at the body's own size; it is refused under 2 mm with what to pick instead.
- **B5, a Prismatic body drawn with a hole.** Cause: two cylinders of all but one radius leave a neck a hair wide between their faces, and the kernel's mesher left a triangle out of it at some sizes; the op checked each face's cover but not that the drawn triangles close. Change: equal radii and meeting axes (section 7, item 13), so such cylinders are cut in two ellipses and no neck is made; and the drawn-triangles check with its refusal (section 5; the two repairs by a finer mesh that the first fix round had were taken out in the second, with the triangles they left on the body).
- **P1a, crossing holes of equal radius refused.** Cause: not the holes. A sample point of the cell pick ended exactly on a hole's wall: the ray from a third of the way along the block's side brushed a hole of radius 5 in a 30 mm block, was not counted as a hit, and its halfway point fell on the wall, where the winding number says "outside". Two of five points were lost that way. Change: section 7, item 7.
- **P1b, P1c, rounds refused far from the origin and on small bodies.** Cause: far away and turned, the fitted directions of a square part's faces are each a hair off square, so a round's cylinder met its flat faces a hair short or a hair inside and the round was lost (the check then refused: 1.24 mm is the round as a sharp corner); on small bodies the same hair was lost in the kernel's absolute tolerances. Change: the copy at the origin and at 0.2 m, directions set square, and the cylinder set to touch.
- **P1d, a ball.** A one-group body that is one flat or round area converts; groups without area are skipped; a refusal for a group that fits nothing always says how far off the best fit is, or that nothing could be fitted.
- **P1e, a hole touching a step's riser:** converts (the cylinder is set to touch the riser's plane).
- **P1f, a wall no thicker than the Fit Tolerance:** refused before any kernel work with the wall's thickness and "Lower the Fit Tolerance below x".
- **P2, Organic's sentences:** its own fields only; a hollow body is refused as hollow.
- **P3, N1, N2, N3:** the warning and refusals in section 3; unique face names.
- **N7:** Organic refuses a solid more than 5 % off the mesh's volume (the verifier's disc: 26.8 %).
- **N8:** the warning in section 3; the Flat Tolerance it names merges every flat group (tested at 138 m).
- **N9:** kernel bodies of that size draw open too (section 8).
- **F8:** kept results (section 4).

## 10. Second fix round (2026-11-13): re-verifier R2's findings

Tests: three new parts in `tests/holo_forge_mesh_regress_convert_test.gd` (`r1`, `c1`, `notes2`). Probes and logs: `...\scratchpad\phase7\teamC\fix2\`.

- **R1, a Prismatic body under 20 mm or over 2 m drawn with faces missing after a Combine.**
  - Cause: the first fix round moved the solid back from the working copy with its triangles (the kernel's transform with "copy the mesh" on) so that very small bodies would draw closed. A later Combine keeps the faces it leaves alone as they are, triangles included, and makes their neighbours new; the kernel's mesher then meshed those neighbours wrong against the carried ones (a whole cylinder at 4 % or 58 % of its area). It never happened without a scale (60 mm, 0.2 m), where no carried triangle crossed a change of size.
  - Change: nothing is carried. The solid goes back as geometry only, by the call the kernel's own Move and Scale use; the drawn-closed check meshes it the way the viewport does and takes the triangles off again (section 5). A Prismatic body now leaves the op holding no triangles at all.
  - Faceted keeps the mesh's own triangles on its faces. They are exact (flat faces, straight edges, never made at another size), and its bodies gave the same results after a STEP round trip, which carries no triangles, as before it. Organic's small-body copy comes back through the kernel's own Move and never carried any.
  - What this costs: a body of a fraction of a millimeter whose own drawing does not close is refused again ("The result would be drawn with a gap"), as before the first fix round; the finer-mesh repair went with the carried triangles.
- **Why the display's own guard said nothing** (`CadShape::tessellate` and `measure::mesh_covers_face`; not changed here, told to the orchestrator):
  1. A face the mesher gave no triangles at all counts as covered (`mesh_area` answers -1 and `mesh_covers_face` returns true at once), and `tessellate` then skips the face without a word.
  2. For a face with a short mesh, the area the guard allows to be missing grows with how far the mesh's own edge chords lie off the face's curved edges, measured on the mesh under test: a mesh that is badly wrong along an edge buys itself the allowance (a cylinder drawn at 58 % of its area passed).
- **C1, a feature on two large bodies failed from scratch and worked on the next rebuild.** On a full-time build every body now gets the feature's whole limit (section 4), so the two builds are the same. A preview keeps sharing its time and says team M's sentence when earlier bodies used it.
- **Notes:** the raise-the-tolerance ending and the radii warning (section 3); the warning on a feature whose bodies are converted again because more than 256 are kept (section 3).
- **One rule for "a triangle without area"** (team N1's `mesh::without_area`): the outline's crossing test (three corners on one line) and Prismatic's leaving out of a group without area go by it, as `check()` and Faceted's refusal already did.
- **Sweep** (`fix2\probe_sweep2.gd`; every tool on a body made anew; judged on the viewport's own triangles against the kernel's own body under the same tool): numbers in the round's report. What is left at 8 mm, and only on bodies with two crossing cylinders of one radius: a cut whose plane passes within a hair of the point where the two cylinders' cut lines cross gives sliver faces the mesher leaves out (Prismatic: 4 of 1,224 results; the kernel's own cross does the same in 10 of 108 such cuts, the converted one in 89). Faceted bodies of 8 mm are refused by a few Combines the kernel's own body takes, and one cut leaves a sliver face undrawn; these are the same after a STEP round trip, so they are not the carried triangles.
- **Found on the way, not Convert Mesh's:** Solid Shell on a Faceted cross-drilled block of 8 mm (338 faces, one face removed, wall 0.24 mm) crashes the process inside the kernel's offset (`fix2\probe_shell_crash.gd`).

## 11. Third fix round (2026-11-13): re-verifier R3's findings C2 to C5

Tests: `c1` rewritten and a new part `r3` in `tests/holo_forge_mesh_regress_convert_test.gd`; `notes2` updated (the cube's sentence, the cap). Probes and logs: `...\scratchpad\phase7\teamC\fix3\` (`probe_c2.gd`, `probe_faceted_time.gd`, and R3's `c06_area_far.gd`, `c10_ball_hint.gd`, `c08b_organic_time.gd` rerun).

- **C2, a feature's time is not the panel's bound.**
  - Cause: the second round gave every body of a full-time build the feature's whole limit (to make from-scratch and in-session builds agree), so five 39,762-triangle plates took 75 to 85 s under a promise of "up to 20 s". The cache counted 4 KB a face, so the five results (about 814 MB by that count) passed its 512 MB, and the least recently used went out on every rebuild: the next rebuild converted them again (62 to 78 s, or a time-out after an earlier success) and the warning named the 256-body count.
  - Change: one shared limit per feature, with kept bodies charged what they took on full-time builds (section 4); the cache never lets go of a body a rebuild's bodies hold, nor one the feature being built has converted so far (a single feature of 259 beads let its first 3 go, and every next rebuild converted those again), and the warning names the cap that let a result go (section 3); the shared time sentence's "on this mesh" names the body, so a kept body refused on a full build and the same body refused from scratch say the same words; the Faceted estimate counts the result's faces and outline edges and is the expected time, not padded (section 4).
  - Measured with five to eight other Godot runs going (`fix3\logs\c2_five.log`, `c2_two_many.log`): five plates in one feature: a full build stops after 13.3 to 15.4 s with "Plate2: ... would take about 8.7 s on Plate2 (limit 4.8 s) ... (The bodies before it used the rest of the feature's 20 s: pick fewer bodies at once.)", the same body refused from scratch, on the next rebuild (0.0 s) and restored into a new document; a 9 s preview takes 6.6 to 7.0 s (one plate converts, the next is refused with the same tail). Two plates in one feature: 16.7 to 18.9 s, both converted, the same from scratch, on the next rebuild (0.07 to 0.09 s) and restored. Five plates, a feature each: 39 s for five features, the next rebuild 0.18 s with all five kept (776 MB by the cache's count), nothing converted again. 259 beads, then another 259, then the first again: the third build converts the first design's beads again and each says why.
- **C3, Organic sentences.** "{body}": the direct API now names "the mesh" (option `name`); through the feature the body's name was already put in. "took longer than l s and was stopped" after 0.1 to 0.4 s: that was the estimate made once the cage's face count is known, which now says "would take about n s on <body> (limit l s)".
- **C4, far from the origin.** N1 changed the shared rule while this round ran (09:04): a triangle is without area when its height is under 2^-24 of its longest edge, wherever it lies, so the bracket and the crossing holes at 50 to 138 m convert again. What is still refused far away is refused with the distance named (section 3): Faceted when the triangles without area are thinner than the position step there; Prismatic when a group is off its best surface by no more than the stored corners hold there; both when the corners have run together. The step named is "convert the mesh before it is placed this far from the origin, then move the converted body there", which works (the test converts a plate near the origin and moves it 20 km out); Stitch and Remove and Generate Face Groups are not named there.
- **C5, the coarse ball's hints pointed at each other.** Prismatic now asks Generate Face Groups (Accurate) itself whether it would split a one-group body, and names it only when it would (section 3). A coarse ball (80, 320 or 1,280 triangles) is told it is one smooth area, with the volume a sphere through it would change (12.6 %, 3.25 %, 0.82 %; the result's own: 14.5 %, 3.5 %, 0.87 %), and sent to Faceted or Organic; at a wider Fit Tolerance its volume refusal does the same.

Proposed accepted limits from this round:

- A body whose sliver triangles were already exactly flat before it was placed far away (a true needle) gets the far-away sentence too: once stored, the two cannot be told apart. The sentence says only what is true of both ("thinner than that and has no area").
- A body with genuine needles near the origin is still sent to Stitch and Remove; whether Stitch then clears them is N1's (Stitch).
- Organic far away is not reworded: at 20 km the remesh fails ("could not remesh"), and at 1 km the result is only warned that its drawn triangles do not close.
- Five 39,762-triangle plates in one feature are now refused (the third plate, with the reason and "pick fewer bodies at once") rather than converted in 75 to 85 s: a feature now keeps to its limit. One feature per plate converts them all.
- A Fast-grouped coarse ball is sent to Generate Face Groups (Accurate), which then makes it one group and the one-smooth-area sentence follows: two steps, but no loop.
- Times were measured with three to eight other Godot runs going; the estimates are per face and per outline edge from those runs.
- The new tests were written after the code: the failing-first evidence is R3's logs (`reverify3\c\logs`), since the previous DLL is gone.
