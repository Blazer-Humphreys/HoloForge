# Phase 7 native data layer (team N, Stage N1): as built after the third fix round

Team N owns `mesh_data.*`, `mesh_io.cpp`, `mesh_tessellate.cpp`, `mesh_query.cpp`, `mesh_bvh.*` and the
data/IO/Tessellate parts of `cad_mesh.*`. Earlier rounds are recorded in spec 10.2, 10.3 and 10.14.
This file records the rules in force after the third fix round (2026-11-13). Regression test:
`tests/holo_forge_mesh_regress_data_test.gd` (sections "third round", `_check_far_bodies`,
`_check_obj_round3`).

## 1. "Without area" (shared rule, `mesh::without_area`, `mesh_data.cpp`)

- A triangle is without area when two corners are the same vertex, or when
  `twice_area <= longest_edge^2 * 2^-24`: its height is under about a 17-millionth of its longest
  side. The rule looks at the triangle only, never at the body's size or distance from the origin.
- Why: the second round's rule added a floor of 6e-8 x (distance from the origin), so a well-made
  body 50 m or more out had "triangles without area", Faceted refused it, and Stitch kept them
  (W1). With the new rule the drilled block (crossing_holes, turned 1.1 rad about (1,0,1)) has 0
  such triangles at 1 m, 10 m, 50 m, 141.8 m and 1 km; its thinnest triangle is 4e-5 as high as
  long.
- Users of the rule: `check().degenerate_triangles`, Stitch and Remove (N2), Faceted's refusal via
  `count_degenerate` (C), Prismatic's group filter (C), `finish_op`'s "made n triangles without
  area". Not on it: `mesh_convert.cpp` line ~375 (`none = 1e-12 * size^2`, C's) and the
  "more than 1,000 km from the origin" sentence in `mesh_manifold.cpp` (N3's).
- A triangle whose corners are stored at one float32 place (far from the origin) is still without
  area: that is real loss of position, not a judgment.

## 2. Tessellate far from the origin (`mesh_tessellate.cpp`, `cad_mesh.cpp`)

- Nodes that float32 stores at one place are joined into one vertex when that adds no open edge
  and no edge shared by more than two triangles (both meshes are built, the joined one is kept
  only if neither count grows). This removes the needles between such nodes.
- What is left is counted: warning "Tessellate made <n> triangle(s) without area: the body is
  <d> from the origin, where positions are stored only to about <step>. Move the body nearer the
  origin first." (without the distance part when the body is not far: "...without area.").
- "Far" (`mesh::far_note`, declared in `cad_mesh.h`): the float32 step at the box's reach is more
  than a ten-thousandth of the body's size.
- The closed-body refusal of Tessellate names the distance the same way when far, instead of
  "Raise the Refinement.".

## 3. OBJ reader (`mesh_io.cpp`)

### Faces

- A corner named twice in a row, or two corners at one float32 place in a row, is one corner;
  also the first corner repeated at the end. Warned and counted: "<file>: 1 face names / n faces
  name a corner twice in a row (or two corners at one place); the repeat was left out (the first
  is on line L)."
- A face whose triangles are all without area is left out: "<file>: 1 face has no area (its
  corners lie on one line) and was left out (line L)." / "n faces have no area ... (the first is
  on line L)." A file of such faces only is refused: "<file> has no faces with area: the corners
  of every face lie on one line."
- Faces with fewer than 3 corners: left out and counted, as before.

### Splitting polygons

- Ear clipping now treats a reflex corner that lies on a cut's side within float noise as in the
  way, as it already did for flat corners (A4: a tilted staircase prism made 3 triangles 0.6 to
  2.1 nm high; now 0).

### Faces that meet part-way along a side (T-junctions)

- Open edges come from the topology. Each corner of the mesh that lies on another face's open edge
  (within max(noise, 1e-5 x L), L the edge's length) is spliced into that face, then the faces are
  split again; up to 3 passes. This joins partial overlaps, corners at different places on a
  shared side, and boxes whose side faces are split at different heights (A3).
- Edges written twice at the same places under other vertex numbers are not T-junctions; they are
  left to Stitch and Remove, which joins them, and said: "<file>: n edge(s) lie(s) on another whose
  corners are written twice (the same places under other vertex numbers), so the mesh is open
  there; Stitch and Remove can join them."
- A corner near a side but further off than the splice tolerance (up to 1e-2 x L) is not moved:
  "<file>: 1 face has a corner of another face near one of its sides (up to X off) without sharing
  it, so the mesh is open there. Join them in the program that wrote the file."
- The old sentence "...meet others part-way along an edge; Stitch and Remove can join them." is
  gone (Stitch could not do it).
- Over the work budget (5e7 pair tests): "<file>: the mesh has N open edges, too many to check them
  all for faces that meet others part-way along an edge."

## 4. Accepted limits (proposed)

- A tilted comb of 3,000 teeth (6,000 corners in one face) keeps 51 triangles without area: the
  teeth are thinner than float32 can split cleanly once tilted. Warned by `check()`.
- Deep gears of 250,000 corners are refused as not splittable in time (about 2.1 to 2.5 s).
- Corners further off a side than 1e-5 x the side's length are warned of, not moved; the search
  for them reaches at most a quarter of the mean open edge length.
- Tessellate far from the origin can still leave triangles whose corners float32 stores at one
  place (4 at 100 m for a 20 mm ball at Very High, 16 at 300 m, 240 at 10 km); they are counted
  and the distance named.

## 5. Measured (third round, DLL of 2026-11-13 09:47)

| Case | Before | After |
|---|---|---|
| Drilled block turned and moved out 50 / 100 / 141.8 m: Faceted | refused, "5 / 16 / 22 triangles without area"; Stitch kept them | converts; 0 without area at 1 m to 1 km |
| 20 mm ball at Very High, 60 / 100 / 150 / 300 m | 4 / 256 / 850 / 2,125 without area, no word | 0 / 0 / 8 / 16, the last two warned with the distance; Stitch then removes them (0 left) and Faceted's refusal names the distance |
| 20 mm ball at Very High, 1 km / 10 km | 7,472 / not measured, no word | 36 / 240, warned with the distance |
| Tilted staircase prism (OBJ) | 3 triangles 0.6 to 2.1 nm high, no word | 0; Remesh, Reduce, Smooth, Stitch, Faceted and Generate Groups all run on it without a refusal (before: Faceted refused, Stitch kept 3) |
| Sheets meeting part-way along a side (4 layouts) | 2 outlines, or a false Stitch hint | 1 outline, no warning |
| Boxes whose side faces are split at different heights (plain and tilted) | 16 open edges in 4 loops | closed, 12,000 mm3 |
| Faces repeating a corner, faces on a line (R3 a02) | 5 flags (non-manifold edges, triangles without area, nothing said) | 0 flags; mended or left out, and counted |

Timings measured on the C++ harness while other teams' tests ran (one sample each, so rough):
circle of 100,000 corners 0.20 s, star 0.32 s, wobbly 100,000 0.24 s, wobbly 500,000 1.65 s,
deep-gear refusals 2.1 to 2.5 s.
