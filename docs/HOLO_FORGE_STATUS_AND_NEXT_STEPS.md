# Holo Forge: status and next steps (2026-11-11)

This is a work order for whoever continues: you, or a future AI session. Read it top to bottom before starting.

## Where things live

| What | Where |
|---|---|
| Master plan (10 phases) | `C:\Users\Blaze\.claude\plans\can-we-create-a-idempotent-shannon.md`. The plan says `holo_cad`, but the real name is **Holo Forge**: addon `addons/holo_forge`, main-screen tab "Forge". |
| Addon (GDScript) | `godot-board-racing/addons/holo_forge` |
| Native kernel (C++) | `D:\Hover_Board_Racing\Godot_Board_Racing\holo_forge_native\src`. It wraps OpenCASCADE 8.0.1, planegcs and OpenSubdiv 3.5. |
| Build output | `C:\Users\Blaze\holo_forge_build\build`. Build with `& "C:\Program Files\CMake\bin\cmake.exe" --build "C:\Users\Blaze\holo_forge_build\build" --config Release --parallel`. The post-build step copies the DLLs into `addons/holo_forge/bin`. |
| Tests | `tests/holo_forge_*_test.gd`, run headless with `--headless --path . --script res://tests/<name>.gd`. |
| Editor hooks | Run `--headless --path . --editor -- <hook>`, one hook per run. The hooks are `--holo-forge-editor-test`, `-sketch-`, `-solid-`, `-inspect-`, `-insert-`, `-surface-`, `-ui-`, `-form-`, `-mesh-`, `-save-`, `-assemble-` and `-handles-editor-test` (12). |
| Known baseline | `tests/validate_project.gd` fails with exactly 6 Movement Lab violations. They are unrelated to Holo Forge. |
| Long-term notes | Memory file `holo-forge-cad-plugin.md` holds gotchas, the build recipe and decisions. |

## Done

- **Phases 0-5 are complete and verified.**
  - Native kernel, Forge tab, timeline, browser and viewport.
  - Sketch (constraint solver, dimensions), Solid and Construct.
  - Inspect, Insert, appearances and export.
  - The Surface workspace, after five adversarial review rounds.
  - My final check on 2026-10-29: 23/23 headless tests, 7/7 hooks and the render check all passed.
- **UI work requested during Phase 5 (done, tested):**
  - **Toolbar:** pinned icon rows over the group dropdowns, folders, Pin to Toolbar, and a `»` overflow menu.
  - **Icons:** 283 original "Holo" icons, compared against the other app's for originality.
  - **Theme:** Dark, Light and Follow Editor modes.
  - **Sketch palette:** movable and resizable.
  - **Navigation:** the Orbit/Pan buttons no longer break picks.
  - **Dimensions:** they work and look like the other app's.
  - **Press Pull:** a profile Press Pull is now "Join or New Body", so it works in an empty design.
- **Phase 6 (Form workspace, subdivision freeform) is built.**
  - **Spec:** `docs/holo_forge/phase6_form_spec.md`.
  - **Native code:** `cad_subd.*`, `subd_convert.*`, `subd_bvh.*`.
  - **GDScript:**
    - `core/form/*`;
    - `core/features/form.gd`;
    - `ui/form_editor.gd`, `form_gizmo.gd`, `form_display.gd`, `form_tools*.gd`.
  - **Tests:**
    - `holo_forge_subd_native_test`, `form_cage`, `form_ops`, `form`, `form_create`, `form_tools`, `form_fix`;
    - the hook `--holo-forge-form-editor-test`;
    - all of them passed after the build fixer's pass.
  - **First review round (done 2026-11-04, run `wf_cfb07320-b8e`):**
    - **Open items fixed:** the fillet hang (ChFi3d tolerances), the command-panel info-row flood, Form editor buttons/handles/select-through, dotted edge lines on curved bodies, DLL temp files.
    - **Critic findings fixed and verified:**
      - Merge Edge respects frozen vertices;
      - symmetry and frozen vertices (orbit-expanded locked set);
      - dihedral symmetry moves (stabilizer projection);
      - Match links re-follow after topology edits and warn on a missing target;
      - Convert relays its warnings and keeps them on the body (`brep_notes`);
      - re-saving keeps the exact doubles;
      - typed out-of-range values in modify tools are refused with a sentence;
      - broken fillet/chamfer results are detected and refused;
      - `closest_points` at creased corners;
      - checkbox fields reveal their dependent rows.
    - **New test:** `tests/holo_forge_form_critfix_test.gd`. Also `tests/holo_forge_command_panel_layout_test.gd`.
    - **The verifier then found 2 regressions**, being fixed in run `wf_4fcf5c21-5ff` (script `...\workflows\scripts\holo-forge-phase6-regressions-wf_4fcf5c21-5ff.js`):
      1. The new fast Hollow Shell path (`hollow_directly` in `solid_ops.cpp`) builds walls far thinner than asked, with no warning, when the wall is thicker than the body locally (torus 50 mm at t = 10-15 mm, a thin 800 mm plate).
      2. A single-edge fillet/chamfer of 2.5-3.0 mm on the 35 mm test body (`verify_critfix2/verify_tools/ws_cage.txt`) never returns.
      - Same run: thick/impossible shells must refuse fast instead of spending 20 s per rebuild, and create-tool fields (sweep, pipe, loft, extrude face counts, soft faces) must refuse out-of-range input instead of clamping.

## Next steps, in order

1. **Regression rounds.**
   - **Round 2 (run `wf_4fcf5c21-5ff`, done 2026-11-10), verified:**
     - The fillet hang is bounded by `guard::run_bounded` (`occt_guard.cpp`, compiled with /EHa). A watchdog sets hardware breakpoints on OCCT marching functions, and an SE translator unwinds them. It is Windows x64 only; about 8% of O1-body fillets now refuse as "took too long".
     - Closed hollow shells are checked densely: walls must be 0.97-1.03 t. Impossible walls are refused upfront with where and how thick, and refusals are cached. Bodies under 50 mm are hollowed on a scaled-up copy.
     - Filleted boxes hollow via Defeaturing.
     - Create-tool fields have ranges.
     - New tests: `holo_forge_form_regress_test.gd` and `holo_forge_form_shell_regress_test.gd`. All 35 tests and 8 hooks pass.
   - **Round 3 (run `wf_440352c5-6a6`, script `...\workflows\scripts\holo-forge-phase6-r3.js`, issues passed as `args.issues`; text in the session scratchpad `r3_issues.json`). It fixes:**
     - a signal-11 crash in TKShHealing on the scaled (<50 mm) shell/offset path;
     - open-face shells through OCCT's thick solid returning wrong bodies with no warning;
     - `offset_shape` returning empty or zero-volume shapes as success;
     - false refusals of buildable shells (L-bracket, sphere-box intersection).
   - **Round 3 result (done):**
     - The crash is fixed: a null offset result was fed to ConvertToBSpline.
     - Offsets never return empty shapes as success.
     - Convex flat-faced open, outward and chamfered shells are exact (`convex_shell`).
     - Every retry goes through edge-gap and mesh-volume checks.
     - New tests: `holo_forge_shell_offset_regress_test`, `holo_forge_shell_exact_regress_test`. All 37 tests and 8 hooks pass.
   - **Round 4 (run `wf_6c72c45c-fa9`, done and verified 2026-11-11):**
     - The open-shell rim lid is fixed at the source: the rim is cut with a slab.
     - A per-face mesh-against-B-rep area guard (`mesh_covers_face` in `measure.cpp`) is used by the shell/offset checks, by `CadShape::tessellate` (re-mesh or warn) and by STL export.
     - Refusal sentences are true.
     - New test: `holo_forge_shell_face_mesh_test`.
     - The verifier found no silent lid on flat or elementary faces in 378 variations, and no regression in 552 shell/offset reruns or 1440 fillet/chamfer cases.
   - **Final small fixes (done 2026-11-11, DLL built 12:47):**
     1. **Off-surface fillet faces.** Fillets of 2.6-3.9 mm on the converted O1 body were drawn 0.3-2.6 mm off their faces.
        - Cause: at OCCT's loose 0.1 mm fit, ChFi3d leaves corners 1.7-2.6 mm off the edges that meet there and hides it with vertex tolerances of 3-5 mm. The mesher puts a node at the corner, which pulls every face round it off the surface.
        - `blended` has a new attempt at a 0.01 mm fit (warning: "fitted only to within 0.01 mm"). Most of those fillets now build clean.
        - `blend_problem` now refuses a blend whose corner or edge strays (`measure::edge_stray`: over 2 % of the blend size, or 0.1 % on a sliver), whose surface is folded over itself (`measure::fold_area`, over 0.1 % of its area), or whose new faces mesh off themselves.
        - `mesh_covers_face` / `face_drawable` now check spline faces (nodes within 4 deflections of the surface). `tessellate` warns for a spline face drawn off itself.
        - The existing tessellate warning used `%g` with Godot's `vformat`, which has no `%g`; it printed "unsupported format character". It is formatted with `snprintf` now.
        - Thresholds (2 %, 0.1 %, fold) come from the O1 body's data only.
        - Still flagged by a 5 % area rule: a 0.0135 mm2 sliver face (12 um wide) on r = 2.3 mm fillets is 13 % off at viewport deflection. That is chord error, not a defect; left alone.
     2. **Offset sentence.** `empty_offset_reason` says "more than twice" only when no inward ray finds the far side within 2t/0.97 plus two deflections; near the boundary it names the thin spot. `hollow_upfront_problem` searches that far too. Only refusal wording changed.
     - Tests: `form_regress` (`_blend_faces`, 12 O1 fillets), `shell_face_mesh` (`_thin_boundary`, `_saved_blend`), fixture `form_fillet_corner_off_edges.brep`.
     - Known and not changed: the blend's size measure shifts slightly (3.51e-7 to 3.57e-7 tolerance) once a body has been meshed, so a borderline fillet can come out differently before and after the body is first drawn.
     - The same build includes the DLL pin in `register_types.cpp` (see below). With the pin, Godot can't delete its temp copy `bin/~holo_forge_native.dll` on exit; one copy stays and is reused, it does not pile up.
   - **Parallel work done 2026-11-11:**
     - **Heads-up fields:** the Line, Rectangle and Circle tools have heads-up dimension fields (`ui/sketch_editor.gd`, `tests/holo_forge_heads_up_test.gd`).
     - **Form polish:**
       - the Edit Form panel keeps clear of the gizmo;
       - interactive `finish()` shows "Converting form bodies...";
       - ranges on loft weights, pipe tolerance and scales.
     - **Shutdown crash:** a silent access violation at shutdown after a STEP export. TKXSBase's static map outlived TKDESTEP. Fixed by pinning the DLL at init.
     - **Startup crash:** the intermittent `holo_forge_workspace_test` startup signal 11 (2026-11-10, in Godot's GDScript parser teardown) could not be reproduced in 320 runs. Watch for it.
     - **Phase 7:** the spec is written: `docs/holo_forge/phase7_mesh_spec.md`, with measured spike results in its section 8.1a. An agent is folding those into the body.
   - **Accepted limits from rounds 2-3:**
     - Fillets that ChFi3d can't finish are refused after about 3 s. The stop is Windows x64 only.
     - Non-convex shells at 0.1 mm are refused.
     - Outward shells of non-flat bodies under 1 mm are refused.
     - Offsets on curved bodies take 5-9 s.
     - Hollows of the box+sphere union at 1.5 mm and of the sphere-box intersection are refused.
     - One unreproduced signal 11, with only Godot frames, was seen under heavy parallel load.
     - Open-shell rims on bodies of about 0.5 mm are refused (the guard catches a bad rim).
     - The horseshoe spline shell at 0.02-0.05 mm takes 7-12 s because of the added mesh checks.
     - Timing checks in the form tests fail when other Godot processes load the CPU. Run the suite one process at a time on an idle machine.
   - **Final verification (2026-11-11, 13:05-13:26, on the 12:47 DLL, one process at a time, nothing else running):**
     - all 39 headless `holo_forge_*_test.gd` pass;
     - all 8 editor hooks pass;
     - `validate_project` shows only the 6 known Movement Lab violations;
     - no `SCRIPT ERROR`, `Parse Error` or `signal 11` in any log; no startup or exit crash seen.
     - Godot's "RID allocations leaked at exit" and "250 resources still in use at exit" lines in editor runs are old (they are in the 2026-11-04 hook logs), so the DLL pin did not cause them.
     - The script is the session scratchpad's `final_verify/seq.sh`; it takes about 21 minutes.
     - A windowed Form hook run also passed and saved 48 screenshots in `docs/holo_forge/screenshots/phase6/` (the folder has a `.gdignore`).
2. **Known, accepted after round 1** (tell the user at the check-in):
   - Booleans between small converted bodies are bounded at 20 s with an error, not made faster.
   - Shells with an open face on spline bodies are refused (OCCT limit).
   - Small converted bodies refuse small fillets (ChFi3d itself fails).
   - (Fixed 2026-11-11: "Converting form bodies..." is shown by the interactive Finish, and the Edit Form panel keeps clear of the gizmo.)
3. **Phase 6 check-in with the user** (made 2026-11-11; wait for the user's answer before Phase 7).
   - Screenshots: `docs/holo_forge/screenshots/phase6/`.
   - Ask the 6 questions in `docs/holo_forge/phase7_mesh_spec.md` section 8.2.
   - List the known limits:
     - no T-points; "Exact" inserts are refits;
     - BRep face to cage only for 4-sided faces;
     - Pipe chains only, no branches;
     - G1 at valence 8 and up is about 0.09°;
     - shells with an opening on form bodies fail.
4. **Phase 7: Mesh workspace.** The user said "Start Phase 7" on 2026-11-11 (afternoon), without answering the six questions, so the spec's defaults apply.
   - The work order is `docs/holo_forge/phase7_mesh_spec.md`. Follow its section 4 stage order: N0 → N1 → G1 → Stage 2 (N2, N3, U in parallel) → Stage 3 (M, C in parallel) → Stage 4 (hook, verifier, final check).
   - One agent per team, briefed with the spec path, the stage, the facts newer than the spec (39 headless tests, the DLL pin, the old exit leak lines) and the machine rules. Each backs up files it edits to the session scratchpad `phase7\backup\`.
   - Progress (update this list as stages finish):
     - N0 + N1: done and verified 2026-11-11 17:47 (40 headless tests, 8 hooks pass). Decisions and the API as built are in the spec's section 10 (addendum).
     - G1 (plus the `core/inspect.gd` follow-up), N2 and N3: done 2026-11-11 night; each passes its own tests. Decisions are in spec 10.6-10.9; the native ops as built are in `docs/holo_forge/phase7_native_ops_n2.md` and `phase7_native_ops_n3.md`.
     - U Stage 2 (panels, selection, display, Direct Edit, icons) and M (tool wiring; 5.2 and 5.3 pass): done 2026-11-12 morning. As-built files: `docs/holo_forge/phase7_ui_as_built.md`, `phase7_tools_as_built.md`; decisions in spec 10.10-10.11.
     - M and C stalled overnight when the computer slept (keep-awake was denied by the permission system); both were resumed with SendMessage. If agents stall again, check for leftover Godot processes they started and the `build.lock` folder, then resume them.
     - C (Convert Mesh; 5.4 passes): done 2026-11-12. As built: `docs/holo_forge/phase7_convert_as_built.md`; decisions in spec 10.12.
     - Running since 2026-11-12 morning: U Stage 4 (Section Sketch and Form Body output wired into OK, five panel fixes, the `--holo-forge-mesh-editor-test` hook, windowed screenshots into `docs/holo_forge/screenshots/phase7/`), and three adversarial verifiers that change no project file (V1: pmp/meshoptimizer ops; V2: Manifold/voxel ops, data layer, inspect; V3: Convert and the document side). Their probes and logs are in the session scratchpad `phase7erify1..3\`.
     - Verifier results so far (full text in the session scratchpad `phase7\verify1\FINDINGS.md` and `verify2\FINDINGS.md`):
       - V1 (pmp/meshoptimizer ops): 4 broken (Fast Reduce by tolerance breaks the time bound; Stitch and Remove opens bodies that touch face to face; Fast Reduce makes vertex-touching pieces non-manifold; Adaptive Reduce moves kept group borders), 7 partial.
       - V2 (Manifold/voxel, data layer, inspect): accurate Shell crashes Godot (signal 11 in `manifold.dll`) on box-like bodies away from the origin; Separate hangs on thousands of closed pieces; silent wrong results on self-crossing input (Shell, Combine, Interference); Texture Extrude drops its crossing warning above 145k triangles; Rebuild drops thin parts silently; `read_obj` unbounded; damaged STL/OBJ accepted; 9 partial.
     - Fix round started 2026-11-12: N2 (V1's findings), N3 (V2's ops findings), N1 (readers, Tessellate presets and the 1 % rule, mass warnings). Each writes a failing test first. Waiting for V3 (Convert and the document side) before resuming G (interference: warnings, open bodies, one shared deadline; mass warnings shown; preview limit per feature; bake time) and M (Erase and Fill sentences, stale picks without a digest, the "bodies before it" sentence on one body, crossing notes for Combine and Shell, Tessellate presets on small bodies at feature level).
     - Done 2026-11-12 07:40: U Stage 4 (the 9th hook `--holo-forge-mesh-editor-test` passes headless and windowed; 78 screenshots in `docs/holo_forge/screenshots/phase7/`) and N1's fixes (readers, Tessellate presets and the 5 % rule, mass warnings). Details and the open list per team: spec 10.13.
     - Subagents cannot write report files (the harness refuses it), so save a verifier's findings yourself: the two FINDINGS.md files were extracted from the session transcript.
     - V3 (Convert and the document side) reported 2026-11-12 08:00; its findings are in the scratchpad `phase7/verify3/FINDINGS.md`: Faceted runs 26-209 s past a 20 s limit on a merged face with a long outline and repeats it on every rebuild; Prismatic and Organic run past the limit on bodies under about 0.5 mm; Solid Shell on a flat-triangle body is cracked with no message and 2 of 9 rebuilds took about 190 s (Phase 6 kernel code); a wrong Tessellate cache key (face names missing); a missing Direct Edit blob deletes the body silently; face group picks by name point at another face after an earlier edit; plus needless Prismatic/Organic refusals.
     - Fix teams and their lists (briefs are in each agent's transcript; resume by agent id with SendMessage): N2 (verify1), N3 (verify2 ops), C (verify3 Convert), G (document side: gate test, interference, mass flaws, group picks, export of hidden bodies, sidecar repair, preview limit, bake time, save order), M (wiring: cache key, Direct Edit blob, Erase and Fill sentences, stale picks, crossing notes, reader warnings), U (panel placement, Direct Edit arrows, picks when editing a feature, `command_panel.gd`, `mesh_preview_feature`), and the Phase 6 shell fixer (Solid Shell on flat-triangle bodies, `solid_ops.cpp`).
     - All seven were stopped by the account's usage limit at about 08:00 on 2026-11-12 and resumed at 18:30 after the user said "Try again". Seven agents at once use the limit quickly; if it is hit again, resume them the same way (check `build.lock`, leftover Godot processes they started, and that the DLL is newer than the last source edit).
     - Fix reports in by 2026-11-12 20:40: N2, N3, N1, M (twice), G (twice), C and U. Still out: the Phase 6 shell fixer (Solid Shell on flat-triangle bodies). Summary and accepted limits: spec 10.14; per-team detail in the as-built docs' "fix round" sections.
     - **User files and hooks (important):** in Godot 4.7.1 every editor scene save rewrites each loaded `.tres` (and shader) that has sub-resources, with the same bytes and a new modified time; hooks that saved through the editor did this to 18 of the user's files and twice overwrote the fixture scene `tests/holo_forge/forge_editor_test.tscn` (restored, md5 `486c4189...`). Now: `tests/holo_forge_hook_guard.gd` (started by the plugin for every `--holo-forge-*-test` run) snapshots the project, keeps the user's session scenes from opening, restores `.godot/editor/editor_layout.cfg` and `project_metadata.cfg`, and fails the run (exit 1, "FAIL Holo Forge HOOK GUARD") if a file outside the test folders changed. No hook saves through the editor in the real project any more. A windowed editor start rewrites `project.godot` with the same bytes. Never run Godot with `--editor` on the real project outside the hooks, and never in a folder made of junctions (the scratchpad `phase7\shellfix\proj` is junctions into the real project).
     - The plugin no longer saves a scene itself: meshes are externalized by a resource saver (`nodes/cad_part_saver.gd`) during the editor's own save. Tested in a clean throwaway project only.
     - Running since 20:45: two re-verifiers (R1 native ops, R2 Convert and the document side; scratch `phase7\reverify1`, `reverify2`). They return findings as text; save them yourself as `FINDINGS.md` in those folders (extract from the session transcript).
     - Re-verifier R2 (Convert and the document side) reported 2026-11-13 05:30; findings saved as scratchpad `phase7/reverify2/FINDINGS.md`. It confirmed nearly every first-round fix (B1-B3 in time, B4 Shell on Faceted bodies fixed on the 11-12 20:12 DLL, F1, F2, F4-F8, P1-P3). New: (R1, broken) a Prismatic body under 20 mm or over 2 m is drawn and baked with whole faces missing after a Solid Combine; (S1, S2, broken) one Save accepts a swapped sidecar, and a damaged sidecar that cannot be rewritten loses the body; S3-S7 other save faults; F3 still wrong for picks without `normal` (the Mesh panels write `at` only); interference states a bound it does not keep; a 0.5 s preview runs later mesh features with the full limit.
     - Second fix round started 2026-11-13 05:40: C (R1, C1), G (save path S1-S7, interference I1-I3, `resolve_group` honesty), U (write `normal` with every group pick). R1 (native ops re-verifier) stalled overnight when the computer slept and was resumed at 04:55; the shell fixer is still finishing (`solid_ops.cpp` edited 05:09, not yet in the DLL).
     - Re-verifier R1 (native ops) reported 2026-11-13 05:44; findings saved as scratchpad `phase7/reverify1/FINDINGS.md`. It confirmed every first-round native fix (the Shell crash: 0 in 502 cases including the timeline repro; all time bounds held). New: (N1, broken) Close Holes' smooth fill balloons far outside the body with no warning; (N2, broken) `read_obj` makes a non-manifold mesh from polygons with corners along their sides; (N3, broken) Reduce (Adaptive) by tolerance can be 14-16 % over its tolerance silently (20,000-sample check); (N4, regression) Plane Cut refuses cuts through vertices with a "please report it" error (140 of 11,050); Tessellate leaves a degenerate triangle at each sphere pole; several false sentences.
     - Second fix round, all started 2026-11-13 05:40-05:50: N2 (N1, N3, N6, N7, grammar), N3 (N4, N8, N10), N1 (OBJ n-gons, sphere poles, sentences, the zero-area threshold), C (Prismatic display after a boolean, C1), G (save path, interference, `resolve_group`), U (group picks carry `normal`). After they report: one more short re-check of the second-round fixes, then the full sequential suite (update `final_verify/seq.sh`: 10 hooks now, including `mesh-editor` and `save-editor`), windowed screenshots, the check-in.
     - Solid Shell fix (Phase 6 kernel, `solid_ops.cpp`; in the DLL since 2026-11-13 05:40; new test `tests/holo_forge_shell_faceted_regress_test.gd`): convex flat-faced bodies get an exact inner wall built straight from the moved planes, tried before OCCT's offset, in Shell and inward `offset_shape`; a closed body's shell mesh must have no open edge; one time limit per call. Causes: OCCT leaves one corner where 5-6 moved faces no longer meet, the old checks compared the B-rep with its own (equally wrong) mesh, OCCT's offset differs from run to run, and the old exact path was one boolean per face with no bound on the sum (the 3-minute runs).
       - Known limits: non-convex flat-faced bodies (a Faceted bracket) are refused with a sentence, never built; a faceted ball with a small dent can still pass with a wall about 1.5 % too thick; the mesh-closed check skips the Phase 6 horseshoe cases (a slit of 4 open edges at 0.2 and 0.5 mm walls, and hundreds of sub-0.03 mm open edges at 0.02-0.05 mm walls, which three Phase 6 tests require to build); bodies saved cracked before the fix draw without a warning; the time guards are rules of thumb from two ball sizes; `form_critfix` sits on its own 5 s bound and failed under load.
     - U's second-round item is done (every Mesh panel pick stores `at` and `normal`; hook part `anchors`).
     - Second fix round reported by 2026-11-13 07:30 (all six teams; each with failing-first tests; details in the as-built docs: n2 section 8, n3 section 9, convert section 10, tools 7.5-7.7, ui section 9 items 10-12; new tests `holo_forge_mesh_save_faults_test`, `holo_forge_shell_faceted_regress_test`). Highlights: Plane Cut sweep 0 refusals of 11,050; Close Holes fills bounded and straight-sided flat holes clean; Reduce by tolerance measured densely (Fast by tolerance now to about 600k triangles); OBJ polygons with mid-side corners load manifold; Tessellate drops pole triangles; shared `mesh::without_area`; far-from-origin refusals in place of "internal error"; Prismatic bodies leave the op with no triangles (R1 fixed: 4 of 1,343 sweep booleans still draw open at 8 mm, a fragile sliver case); each body of a Convert feature gets the full limit; the save path rewritten around "after any Save a reload gives the same bodies or a clear error" (content-tagged baked files, stand-ins for missing files, no adoption of a swapped blob); previews stop after the previewed feature (`result.preview_stops_at`); `resolve_group` never claims a move it cannot confirm; panels write `at` and `normal`.
     - Running since 2026-11-13 07:35: the kernel fixer again (the tessellate guard passes a face with no triangles and lets a wrong mesh buy its own allowance; Solid Shell crashes in `tkoffset.dll` on a Faceted cross-drilled block at 8 mm with an open face; check whether a tool leaves its input body drawing wrong), and re-verifier R3 (rechecks every second-round finding, attacks the new code, reruns the first round's widest sweeps; scratch `phase7\reverify3`; save its findings yourself).
     - Both were stopped by the usage limit at about 07:50 on 2026-11-13 and resumed at 08:22 after the user said "Try again".
     - Re-verifier R3 reported 2026-11-13 08:50; findings saved as scratchpad `phase7/reverify3/FINDINGS.md`. Most second-round fixes hold (wide sweeps unchanged or better, document stress 0 findings). New broken: Remesh far from the origin overruns its limit or never returns (B1); Plane Cut loses a small cube standing on the cut face silently (B2) and keeps a zero-thickness fin along a U channel's inner wall (B3); the Prismatic-after-Combine display hole is only a console warning (B4); the Convert per-body limit is not a design bound (C2); a failed Save deletes a baked file the old scene uses (D1); S6 on one path; an inherited scene loses the heir's design (D4); the preview bound breaks when kept results are gone (D3). Partial: smooth fill bound too loose (A1), Reduce Fast on a thin plate (A2), Reduce deviation reported low (A6), OBJ hint and zero-area triangles (A3, A4), Tessellate far (A5), Faceted far regression with a looping hint (W1), false sentences (A7, C3-C5, D2), orphaned baked files (D5).
     - Third fix round started 2026-11-13 08:55: N2 (B1, A1, A2, A6, A7), N3 (B2, B3, sentences), N1 (W1, A3-A5), C (C2-C5), G (D1-D5, S6, I1), and the kernel fixer (its brief plus B4).
     - Third fix round reported by 2026-11-13 09:50 (all six; DLL 09:47). Details: spec 10.15 (G), n2 "Third fix round", n3 section 10, convert section 11, the new `phase7_native_data_n1.md` (N1), and the kernel fixer's notes below. Highlights:
       - N2: Remesh, Smooth, Reduce and Close Holes refuse far bodies in 0-16 ms with the distance and step. Smooth fills that leave the hole's outline fall back to the flat fill. Reduce reports its deviation truly (sampled-only warning on Fast above about 70k triangles) and warns on volume changes over 5 %.
       - N3: Plane Cut checks each side against a plain split and recuts with its own clipper (B2 88 of 225 wrong → 0, B3 fins 168 of 244 → 0). Overlapping pieces are cut each on its own, with a warning. `op_defaults` shows the far problem.
       - N1: `without_area` is relative to the triangle (W1 fixed). Tessellate far warns, naming the distance. The OBJ reader splices T-junctions and warns about malformed faces.
       - C: one shared deadline per Convert feature; the cache keeps what the design still uses; far sentences name the distance; no hint loops. Five big plates in one feature are now refused partway with "pick fewer bodies at once".
       - G: no baked file is deleted until the scene is on disk (`_clean_folder` after POST_SAVE); lost baked meshes are re-baked with a warning; inherited scenes keep their own design (`local_document`); previews share a 1 s lead for earlier Mesh features (24 Scales on 1.3M triangles: 21-25 s → 1.3 s); true "now lands on" pick sentence; orphan cleanup; I1 float bound.
       - Kernel fixer: tessellate guard (bare faces re-meshed or warned by name; allowance from geometry, not the judged mesh; faces must agree along shared edges, which fixes inputs drawn wrong after a tool); `guard::run_guarded` catches access violations in every OCCT offset/thick-solid call (crash scan 246 processes, 0 crashes); booleans that make a face failing BRepCheck retry with fuzzy values, then refuse (B4); tessellate warnings reach the feature's timeline warning via `regen.note_drawing`.
       - Main session: test sentences updated for G's D2 (`mesh_editor_test`, `mesh_regress_tools_test`), and `_waiting_features` shows `preview_stopped` with the command's own label.
     - Full sequential run 2026-11-13 10:04-10:57 (DLL 09:47, scratchpad `final_verify/summary.txt`):
       - All 10 hooks pass headless, and 50 of 55 headless tests pass.
       - The other 5 (form_ops, form_regress, form_shell_regress, mesh_native_manifold, mesh_regress_data) failed only timing limits while the user's other apps were busy. All 5 pass when rerun alone (`final_verify/rerun`).
       - `validate_project` shows the known 6 Movement Lab violations.
     - The windowed mesh-editor hook fails:
       - without screenshots, only a hover timing ratio (0.066 against 0.05);
       - with `--holo-forge-screenshots`, a chain starting at Close Holes.
       - Sent to U at 11:05. Cause: the user's real mouse reached the editor window and stole focus (a lost Enter in Close Holes). The hook now sets `mouse_passthrough` on windowed runs, counts real mouse events, and uses a windowed hover limit of 0.12 (GPU noise; headless stays 0.05).
       - Now passes headless, windowed, and windowed with screenshots. 85 refreshed screenshots are in `docs/holo_forge/screenshots/phase7/`.
     - **Phase 7 complete 2026-11-13 ~11:40; check-in made.** Waiting for the user's go-ahead before Phase 8 (Assemble).
     - Known and accepted so far (tell the user at the check-in): non-convex flat-faced bodies do not shell; mesh bodies far from the origin are refused by the voxel ops (a 20 mm body beyond about 256 m) and Plane Cut (beyond about 512 m); Reduce (Adaptive) by tolerance on flat-faced bodies mostly returns "Nothing could be taken out"; deviation figures of Reduce by count and of Remesh rest on 20,000 samples; Remesh can lose a short closed border loop (warned); Prismatic refuses cones, tori and a box with every edge rounded; Organic only suits smooth shapes and refuses Form Body output under 2 mm; sub-millimetre solids are unreliable in any later kernel tessellation; a deep gear polygon of 100,000 corners is refused by the OBJ reader; old name-only group picks warn "could not be confirmed"; the editor's real Save with the new saver was exercised only in a clean project. Added in round 3:
       - Shells and boolean cuts:
         - Faceted bodies refuse Shell and offset (each with a sentence).
         - An OCCT cut that leaves an unsound face is refused, not built (try moving or resizing one body slightly).
         - Some Prismatic/Faceted boolean results still draw with faces missing, now mostly with a warning naming the face and its area.
       - Far from the origin:
         - Tessellate still leaves a few triangles without area (warned with the distance).
         - Organic is not reworded there.
       - Reduce and fills:
         - Fast Reduce by proportion or count on bodies over about 70k triangles gives a sampled deviation (warned).
         - A smooth fill that rises far off a hole's plane is warned, not replaced.
       - Plane Cut and Convert:
         - Overlapping pieces are cut each on its own.
         - Five large plates in one Convert feature are refused partway; one feature per plate works.
       - Inherited scenes:
         - An heir never saved before is not detected.
         - Once an heir keeps its own design, later base edits don't reach it.
       - Smaller items:
         - B-rep features before a previewed Mesh feature aren't bounded by the preview limit.
         - The orphan cleanup costs about 1 s on a Save that drops files.
         - A 3,000-tooth OBJ comb keeps 51 needle triangles (counted).
         - OBJ polygons of 250,000 corners are refused.
     - After the fixes: a fresh verifier re-checks every finding and sweeps again; then the full sequential suite, windowed screenshots, the check-in.
     - Not done yet: no full sequential suite since N1 (run `final_verify/seq.sh` with a new `OUT` once U, M and C report), Stage 4 (the `--holo-forge-mesh-editor-test` hook by U, a fresh adversarial verifier, fixes), windowed screenshots, the check-in.
     - Open items for the fix round: mixed mesh/B-rep interference can take about 30 s (needs one shared deadline); the verifier lists in spec 10.8 item 7 and 10.9.
5. **Phase 8 (Assemble):** the user said "Start Phase 8" on 2026-11-13 (about 11:45). A spec agent is writing the work order `docs/holo_forge/phase8_assemble_spec.md` (same structure as the Phase 7 spec, with its section 10 lessons binding). Then staged teams, verifier rounds, the full sequential run, screenshots and the check-in, as in Phase 7.
   - The spec was written 2026-11-13 12:15 (921 lines). It covers:
     - teams: A (core), N (native `CadMesh.overlap`), V (view/browser), T (tools/hook), K (bake/export);
     - stages 0 (A alone), 1 (A, N, V), 2 (T, A, K), 3 (acceptance, hook, verifier);
     - the 8.2 open questions, whose defaults apply.
   - Addendum 10.0 corrects the DLL risk: the DLL can be replaced while the user's editor is open.
   - Stage 0 (team A) started 12:20; backups go in scratchpad `phase8\backup\`.
   - Stage 0 done 2026-11-13 ~13:05: 5.1 passes, all 55 tests pass, and the editor hook passes. The as-built details are in spec 10.1.
   - Stage 1 started ~13:10 with teams A (solver), N (`CadMesh.overlap`; the only native build) and V (view and browser).
   - Resume any agent with SendMessage by its id:
     - A: a3c0d6bcaeb29b299
     - N: a301697396ea30a8f
     - V: a82b6a8161e2cb808
   - Stage 1 done ~14:30: 5.2 (24 cases), 5.3 (11 cases) and 5.4 (10 cases) pass; the C9 targets are met; the DLL was rebuilt with `CadMesh.overlap`. As-built details are in spec 10.2. The Stage 1 gate (the full sequential run) started ~14:35.
   - The Stage 1 gate passed (13:46-14:15): 59 headless tests, 10 hooks, and `validate_project` at the known 6.
   - Stage 2 started ~14:20:
     - T, tools and panels: a59990fe2b6c2615d
     - A, contact: a3c0d6bcaeb29b299
     - K, bake and export: a0b56963a65bb8957
   - Stage 2 done ~15:40: 5.5 (15 cases), 5.6 (15) and 5.7 (V1-V8 plus 12) pass. Facts and as-built details are in spec 10.3.
   - The Stage 2 gate passed (62 headless tests, 10 hooks, validate at the known 6). The new Assemble icons were checked by eye: original, house style.
   - Stage 3 started ~16:30:
     - A writes the 5.8 acceptance test.
     - T wires contact into Play Motion and the Motion Study panel (the Contact check was stored but did nothing), writes the `--holo-forge-assemble-editor-test` hook, and takes screenshots into `docs/holo_forge/screenshots/phase8/`.
     - Then an adversarial verifier, a fix round, the final gate (11 hooks) and the check-in.
   - Stage 3 done ~18:00:
     - 5.8 passes: hinge limits clamp the drive; a 2:1 link is exact; the bake gives HingeJoint3D with K's limits; undo, redo, save and reload are exact.
     - Contact now works in Play Motion, Drive and the Motion Study panel.
     - The 11th hook, `--holo-forge-assemble-editor-test`, passes headless, windowed and windowed with screenshots. There are 20 PNGs in `docs/holo_forge/screenshots/phase8/`, checked by eye.
     - The hook found and fixed two snap bugs: hover candidates never appeared, and a face centre beat a hole centre.
     - Contact estimates now use measured overlap rates (the tight pin-and-hole case is about 6× N's rate).
     - Gaps to report at the check-in: no Drive or Link slider (added 2026-11-14, item 9), and no joint-origin editing. Motion Study is a panel action, and the joint type is an enum row (both deliberate).
     - `seq.sh` now runs 11 hooks.
   - Verifier V1 started ~18:05 (scratchpad `phase8\verify1`; it edits nothing; save its report yourself as `FINDINGS.md`).
   - Verifier V1 reported: 6 cases are wrong with no warning (B1-B6) and 7 are partial (P1-P7). The report is in `phase8\verify1\FINDINGS.md`.
     - B1: the contact sweep misses motion between its coarse samples (many-turn drives, quick study keys, Play peaks).
     - B2: thin bodies are judged by their bounding box.
     - B3: far snaps lose float32 precision with no warning.
     - B4: posed export and measure lose float32 precision far from the origin.
     - B5: Jolt's fallback inertia for small baked bodies.
     - B6: an empty link interval.
   - Fix round 1 was sent:
     - N: `transform_shape64` / `transformed64`, and the self-crossing sentence. Backups in `backup\NF1`.
     - A: B1, B2, B3, B6, P2-P7, and posed inspect. Backups in `backup\AF1`.
     - T: P1, Play split times and finite guards. Backups in `backup\TF1`.
     - K: B5 inertia and B4 posed export. Backups in `backup\KF1`.
   - After the fixes: a short re-verify, the full `seq.sh` gate (11 hooks), spec 10.4, then the check-in.
   - Fix round 1 reported (~17:25). The reports are saved in `phase8\verify2\report_*.md`.
     - N: `transform_shape64` and `transformed64` (DLL built 17:07), and a self-crossing sentence plus the `self_crossing` key.
       - The first overlap call on 2×20k meshes now takes 81-116 ms, against the C9 target of 90 ms. Accepted: skipping the crossing test would give wrong numbers silently.
     - A: everything fixed. There are 17 new sentence ids, and exact format 2. Spec changes go in 10.4: the thinness rule, sampling marks with `split_times` and `turn_between`, drive refusals, and `limits_refusal`.
     - K: B5 inertia is fixed. Jolt holds no inertia below 1e-6 kg·m², so small parts are raised to that floor with S_BAKE_INERTIA_FLOOR (accepted limit). B4 export is double-precise; STEP writes 13 digits, giving 5e-5 mm at 100 km.
       - Found and still open: primitive Box "position" is a float32 Vector3, so a body built far out is about 8 mm off at 100 km with no warning. This is a pre-Phase-8 issue; raise it at the check-in.
     - T: P1, `split_times`/`turn_between` and the finite guards. Last task, sent ~17:25: wire `limits_refusal`, the drive refusals and S-CONTACT-UNCHECKED into the panels.
   - Verifier 2 started ~17:28. Its scratch is `phase8\verify2`; it edits nothing.
   - Verifier 2 reported ~17:55 (`phase8\verify2\FINDINGS2.md`). Most round-1 fixes hold, and all 10 assembly tests plus the assemble hook pass.
     - Still broken:
       - SB1: whole-turn study marks skip contact.
       - SB2: thinness returns early on a thin strip with a lump.
       - SB3: posed vertex measure is float32.
       - SB4: Play Motion ignores Motion Link followers.
     - New:
       - N1: a study drops a joint's other DOFs.
       - N2: false S-CONTACT-STEPS on gear trains.
       - N3: the "raise Step" advice is false.
       - N4: false S-CONTACT-THIN-AVERAGE on small cubes.
     - Partial:
       - PT1: core finite guards.
       - PT2: corrupted or format-1 exact text, and study keys matched by index.
       - PT3: the posed mass centre is float32.
       - PT4: a refused drive's `reached`.
       - PT5: the S-SNAP-FAR threshold.
   - Fix round 2 sent ~17:58: A (everything except SB4; backups `AF2`) and T (SB4; backups `TF2`). Then a short verifier 3 focused on the round-2 items, the `seq.sh` gate, spec 10.4, and the check-in.
   - Round 2 reported ~18:35, with all tests passing. Spec 10.4 is written. The gate `phase8\gate_r2\seq.sh` started 18:35, alongside verifier 3.
   - Verifier 3 reported ~19:00 (`phase8\verify3\FINDINGS3.md`).
     - Still wrong:
       - a DOF stored at its Max drops out of `_turning()` (the nudge is clamped);
       - Play of a link follower misses its root's turn.
     - New:
       - Play gives a false gearbox refusal;
       - many-key studies run past 20 s (up to 34 s);
       - the play-deadline sentence is misleading.
     - Partial:
       - small regions on big meshes get no rays;
       - the Center of Mass panel prints float32;
       - format-2 decode errors.
   - Fix round 3 sent ~19:05:
     - A: the nudge both ways, `MOTION.turn_rate`, study deadline checks, ray coverage, format 2, NaN `reached`. Backups `AF3`.
     - T: `turn_rate` in Play, the deadline sentence, the panel using `center64`. Backups `TF3`.
   - The gate showed 3 Form timing failures (shell 5.0-5.5 s) while verifier 3 ran alongside. Rerun them alone.
   - Gate r2 (18:35-19:17) results:
     - 61 of 64 tests passed; the 3 Form timing tests passed when rerun alone;
     - all 11 hooks passed;
     - validate_project shows the known 6.
   - Round 3 reported ~19:20. Verifier 4 (`phase8\verify4\FINDINGS4.md`) found nothing still silently wrong. It found one regression, NP1: Play of a two-DOF joint self-linked slide→rotation gets a false refusal or a false out-of-time stop.
   - Round 4 fixed NP1, the out-of-time wording and S-CONTACT-TIME-USED, with tests passing.
   - The final gate `phase8\gate_final\seq.sh` started ~19:55 on an idle machine. Then comes the Phase 8 check-in.
   - **The final gate passed (19:48-20:26):**
     - 63 of 64 headless tests were clean. `mesh_regress_pmp` failed only on a Reduce timing refusal and passed twice when run alone.
     - All 11 editor hooks passed.
     - validate_project shows the known 6.
   - **Phase 8 is complete 2026-11-13 ~20:30; check-in made.** Waiting for the user's go-ahead before Phase 9 (Sheet Metal and Plastic).
     - Open item to offer: float32 primitive placement (pre-Phase 8).
6. **Phase 9 (Sheet Metal and Plastic) is skipped** (user, 2026-11-13: "skip phase 9 then, but keep it as extras if necessary"). It stays in the plan as an optional extra, like Phase 10; build it only if the user asks.
   - A cut-down version is possible: Sheet Metal only (rules, flanges, bends, unfold/flat pattern), without Plastic.
   - The catalog still marks those tools disabled with a "Phase 9" tooltip.
   - Candidate next work: joint-origin dragging. (The Drive/Motion Link sliders are done: item 9.)
7. **Primitive placement in doubles (2026-11-13 ~21:20, done).**
   - **What changed:**
     - New `core/point64.gd`. A point field keeps an exact copy `<key>_64` (3 doubles) next to its float32 Vector3. The copy counts only while the Vector3 is still its float32 rounding, so a handle drag or a hand edit wins. It is stored only when float32 rounds the point, so ordinary documents are unchanged.
     - `ui/command_panel.gd` point fields, `tools/primitive_command.gd` and `tools/feature_command.gd` keep the copy.
     - `core/features/primitive.gd` builds Box, Cylinder, Sphere, Torus and Coil at the origin and places them with `transform_shape64` (`placed()`). `surface.gd`'s surface coil does the same.
     - Backups are in scratchpad `backup_p64\`.
   - **Tests:**
     - New `tests/holo_forge_primitive_far_test.gd`. Written first, it failed with the box about 4 mm off at 100 km; it passes now.
     - The full gate (`scratchpad p64_gate`) ran: 63 of 65 tests clean, all 11 hooks, validate at the known 6.
       - `form_critfix` was a shell-timing failure and passed alone.
       - `mesh_save_faults` crashed once, with Illegal instruction (Godot-only frames) in `cad_part.gd _baked_file_is_sound`, at `ResourceLoader.load` of a deliberately damaged `.res`. It passed 3 of 3 alone. This is an intermittent engine crash on corrupted binary resources; item 8 fixes it.
   - **Still float32 (not in this fix):** fastener, decal and canvas positions; construction geometry; sketch plane frames; Move translations. Sketch coordinates themselves are doubles.
8. **Damaged mesh files are checked before Godot loads them (2026-11-14).**
   - **Why:** Godot's loader can crash (not just fail) on a binary `.res` that was cut short; this is what crashed `mesh_save_faults` once. It did not reproduce in 300 loads in a throwaway project, so it is rare, but it can take the editor down on Save.
   - **What changed:**
     - New `core/resource_file_check.gd` reads the file in plain script first.
       - Uncompressed `RSRC` files must start and end with `RSRC`.
       - Compressed `RSCC` files are checked more fully. The layout was verified on 4.7.1: `RSCC`, then mode, block size and total, then one u32 per block, the blocks, and `RSCC`. The block table must add up to exactly the file size, every block must unpack to its full length, and the unpacked data must end in `RSRC`. It does not start with `RSRC`, because `RSCC` stands in for it.
       - Text files (`.tres`, `.tscn`) are passed through. The file type is told by its first bytes, not its name.
     - This check (`safe_to_load`) runs before the three loads of files Holo Forge may meet damaged. A file that fails counts as missing or damaged, and the bake or Save writes it again from memory.
       - `cad_part.gd _baked_file_is_sound` (baked meshes).
       - `_file_is_sound` (stored mesh blobs).
       - `insert.gd source_bodies` (a linked design). This one gives the error "<file> is damaged (cut short?) and can't be read".
     - Backups are in scratchpad `backup_crashfix\`.
   - **Limit:** every cut-short file is caught. Bytes changed in the middle of a compressed block usually still unpack, because zstd has no checksum there. Those files still reach Godot's loader, as before, and the existing mesh comparison turns them down. Scene loads (`cad_part.gd` lines ~838, 844, 993) are not checked: they read scenes the editor itself just wrote or opened.
   - **Tests:** new `tests/holo_forge_resource_file_check_test.gd`.
     - It checks whole and cut-short files (13 compressed and 7 plain cuts), a wrong end mark, a block table that doesn't add up, a huge block table, a block that no longer unpacks, and junk.
     - A spy `ResourceFormatLoader` proves that the three call sites never load a cut-short file and still load a whole one.
     - The full gate (`scratchpad crash_gate`) passed: 66 of 66 tests, all 11 hooks, validate at the known 6. `mesh_save_faults` also passed 3 of 3 alone afterwards.
9. **Drive Joints and Motion Link sliders (2026-11-14, spec 3.7 and 3.8).**
   - **Panel:** `ui/command_panel.gd` gives any expression field that has `"slider": {"min", "max", "tooltip"}` a slider row under it. The span is given in base units.
     - The slider works in display units (degrees, or the document's length unit). Its step is the power of ten below span/1000, and its ends go out to whole steps.
     - Moving it writes the field as text (`values_changed`, as if typed). Typing moves it.
     - The row hides with its field. `set_slider_range()` overrides the span until the next `setup()`. An empty span turns the slider off.
     - The `slider_drag(key, active)` signal tells when a drag starts and ends. A `setup()` in the middle of a drag ends it.
     - Spans are doubles (`PackedFloat64Array`). A Vector2 is float32 and pushed a 90° limit out to 90.1°.
   - **Shared:** `tools/assemble_command.gd dof_range(joint, i, value)` gives a DOF's limits. An open end goes to ±360° for a turn, or ± the moving unit's box diagonal for a slide (at least 10 mm), and always reaches the current value.
   - **Drive Joints:** each Value row has a slider. Spans are cached per joint (`_slider_spans()`).
     - The workspace's `_on_panel_slider_drag` sets `dragging` when a drag starts. Each event then drives on from the last one with the 0.1 s contact deadline, the same as a ring or slide handle. The end of the drag calls `drag_ended()`.
   - **Motion Link:** a Test row (`TEST_KEY "test"`) holds a value of the driver, with a slider over the driver's range.
     - Moving it drives the driver with the link as it would be made, so the follower moves in the view. It is view-only: OK stores only the link.
     - Picking another driver sets the row up again for that driver, with its kind, span and current value.
     - The test ignores contact sets. When contact is on, a note says so (`S_TEST_NO_CONTACT`). Limits still hold.
   - **Tests:**
     - New `tests/holo_forge_assembly_sliders_test.gd` covers the panel slider, Drive on a limited, an unlimited and a contact joint (a slider drag stops at the Wall), and the Motion Link Test (30° shows Gear2 at 60°, nothing is stored, the driver switch, the contact note).
     - The assemble editor hook now drags the Test slider with the mouse and checks that Drive shows its −360..360 slider.
     - The full gate (`scratchpad sliders_gate`) passed: 67 of 67 tests, all 11 hooks, validate at the known 6.
   - Backups are in scratchpad `backup_sliders\`.
10. **Release package (2026-11-15, at the user's request: "a packageable installer").**
   - **Builder:** `holo_forge_native/package_release.py` writes to `C:/Users/Blaze/Holo Builds/holo_forge/`:
     - `holo_forge-<version>-windows.zip`: the `addons/holo_forge` folder (no `.import`, `~*`, `.pdb`/`.lib`/`.exp`) plus the 4 MSVC runtime DLLs, app-local in `bin/`. The version comes from `plugin.cfg`.
     - `holo_forge-<version>-lgpl-sources.zip`: the planegcs source with a CMakeLists, `compat/`, and the OCCT 8.0.1 source tarball with its vcpkg port and patches.
     - Checks before writing: required files present, every DLL import resolved (shipped or a Windows DLL), and no text file holding this PC's paths. The zips are deterministic and tested after writing.
   - **Shipped docs:** `addons/holo_forge/README.md` (install, update, first part, settings, appearances, Jolt note, files written), `THIRD_PARTY_NOTICES.md`, and `LICENSE.md`, which is a PLACEHOLDER: the user must pick the real license before selling.
   - **Untied from this project:**
     - The board-model export folder is now the Project Setting `holo_forge/export/board_models_folder` (added by `plugin.gd _add_project_settings`). This project's `project.godot` sets it to the Updated board models folder; when it is empty, Save Board Model Version says where to set it.
     - The texture library (`res://materials/material_library`) is not shipped. Without it, the 11 built-in finishes show.
   - **Fixes found by installing into a fresh project:**
     - `ui/timeline.gd` freed its never-parented marker on delete (a ColorRect leaked at exit when no part was open).
     - `ui/forge_viewport.gd fit()` used only the vertical FOV, so Fit cut a part off at the sides in a view narrower than it is tall. `fit_half_angle()` now uses the narrower angle. Checked by `holo_forge_navigation_test` `_check_fit_narrow` (fails on the old code).
     - `holo_forge_mesh_editor_test`'s shorter-panel check accepts rows that fit (a tall view has room for them all).
   - **Fresh-install test** (scratchpad `fresh2`, the zip unzipped into a new project): 66 of 67 tests and all 11 hooks pass. `appearance_test` needs the user's 16 texture sets.
     - The tests need this project's 1600x900 window, Jolt physics, `materials/ridgeway_stunt_wall.tres` (and its shader), and the concrete_wall_03 set. The plugin itself needs none of them.
     - Under Godot Physics, joints still bake, with the existing "set up for Jolt" warning.
   - **Not tested:** a PC without the Visual C++ runtime installed (the DLLs are shipped app-local for that); macOS and Linux (no builds).
   - The full gate on this project (scratchpad `real_gate`) passed after all of this: 67 of 67 tests, all 11 hooks, validate at the known 6.
   - Backups are in scratchpad `backup_package\`.
11. **"Pull the handles" mouse test suite (2026-11-15, at the user's request: "a full suite test where the user will pull on arrows with the mouse button in order to affect the models").**
   - **New hook:** `--holo-forge-handles-editor-test` (`tests/holo_forge_handles_editor_test.gd`, registered in `plugin.gd`). It builds its own scene, `tests/holo_forge/handles_editor_test.tscn`, from the assembly fixtures. Every press, drag and key goes into the editor window with `push_input`, the path a user's mouse takes.
     - Options: `--holo-forge-handles-editor-only=<a,b>` (ends with PARTIAL) and `-skip=`. `--holo-forge-screenshots=<dir>` in a windowed editor saves mid-drag pictures.
     - A `Logger` (`tests/holo_forge_script_error_logger.gd`) turns any GDScript runtime error during the run into a failure, because an error ends only its own function and the section would otherwise report done.
   - **Helpers:** `tests/holo_forge_mouse.gd` (real-event input; `pull()` for view handles, `form_pull()` for Form tool handles, `gizmo_pull()` for the Edit Form gizmo, `clear_view()` to pan a point out from under the panel). Each works out the value a drag should give from the same handle math the view uses.
   - **Sections and checks** (100 drags in about 35 s):
     - **primitives:** Box, Cylinder and Sphere arrows and the position point; Esc after a drag.
     - **features:** Extrude, Offset Face, Press Pull on a face (an edge gives a fillet with no arrow), Offset Plane, Surface Extrude.
     - **insert:** Fastener length and position, Canvas centre, Decal position.
     - **inspect:** Section offset, tilt and spin; Texture Map anchor, Scale U/V, turn dot, and a cylindrical origin.
     - **assemble:** Place Component's 3 arrows and 3 turn dots; Drive on every DOF of every joint type, plus a stop at a limit; the Joint panel's ring and slide.
     - **mesh:** Direct Edit X, Y and Z; Plane Cut pulled below zero.
     - **form:** all six primitives placed with real clicks, then their arrows and face counts (a thin box too); Form Extrude on one and two sides; the Insert Edge, Slide Edge and Smooth sliders; all 16 Edit Form gizmo parts, Shift-snapped rotation included; and a free move by dragging the selected face.
     - **sketch:** the timeline's rollback marker; a free point (the line's other end stays); a click on a point without a drag; a fixed point; a dimension's text.
     - **edges:** a drag over a typed expression writes the number and the field notes what it was; a drag past the minimum stops at 0.01 mm; an arrow seen end-on moves nothing.
     - What every drag checks: the field equals the handle math's value, the model follows (volume, box, pose, mapping, cage against the typed values), OK is one named step, and undo and redo are exact.
   - **Bugs found and fixed.** Each has a check in the suite that fails on the old code (proved by running the old files):
     1. `ui/forge_viewport.gd _handle_at`: point and angle dots lying on an arrow's shaft could not be pressed (Texture Map's anchor, Section's spin dot after a tilt, Place Component's Z turn dot). Dots now come first, nearest within 10 px; arrows stay grabbable along the rest of their length.
     2. `ui/form_editor.gd _handle_at`: the same for the Form tools' face-count and slider knobs, for example a thin Box's Length Faces and Height Faces knobs on the Width and Length arrows.
     3. `ui/sketch_editor.gd`: a click on a sketch point without a drag made an empty "Drag Sketch Geometry" undo step. The point drag now commits only after it moved, as the dimension-text drag already did.
     4. `ui/timeline.gd _marker_input`: the rollback marker took the window's mouse position on release, not the event's. For the editor's root window that is the OS cursor, so pushed events (and pens) rolled back to the start. It now uses the release event's position.
   - **Three behaviours the suite showed, changed 2026-11-16 at the user's choice** (backups in scratchpad `backup_drag_behaviours\`; each has a check in the handles hook):
     - **Rollback marker drag** (`ui/timeline.gd`): while held, the marker follows the mouse from gap to gap and the chips past it fade to `ROLLED_ALPHA`, a preview only; the design rolls back on release as one step. A click with no move changes nothing. `marker_preview()` gives the gap during a drag (-1 otherwise). Checked in the sketch section: the marker in the gap, the fade, nothing rolled back before release.
     - **A drag over an expression** (`ui/forge_workspace.gd drag_replaced`, `ui/command_panel.gd set_hints`): the drag still writes a number (`20 + 5` becomes `31.0998 mm`), as the other app does, but the field's hint now says `was 20 + 5` in amber (`NOTE_COLOR`), with "Undo or type it again to keep the link" on hover. The note stays through later drags and goes when the field is typed in or the command ends; a plain number gets none. Hints take `"note": true` (shown beside a plain number) and `"tooltip"`. Checked in the edges section.
     - **Undo names:** every Forge step now has the `Forge: ` prefix in Edit > Undo History, Mesh tools too (`Forge: Mesh: Reduce`; before, Mesh steps alone had none). `ws.last_step.name` keeps the plain name. The mesh-editor and handles hooks check the new names. ("Forge: Form: Box" is plugin + workspace, not a doubled name.)
   - **Not covered** (out of scope unless asked): ViewCube drag, window select, floating panel moves, Motion Study key drag, Edit By Curve.
   - **Gate (2026-11-15, 21:40-22:10, sequential):** 67/67 headless tests and 12/12 editor hooks pass (handles-editor 35 s), no SCRIPT ERROR in any log, and validate_project shows only the 6 known Movement Lab violations.
   - **Gate after the three behaviour changes (2026-11-16, 06:44-07:21):** the same, 67/67 and 12/12 (handles-editor 103 drags), no SCRIPT ERROR, validate at the known 6.
   - Backups of the four fixed files are in scratchpad `backup_handles\`.

12. **Passthrough (2026-11-18, at the user's request: "see what the object looks like in their scene").**
   - **What it does:** **Display > Passthrough** (`forge_viewport.gd` id `PASSTHROUGH_ITEM` 102) makes the Forge SubViewport render the edited scene's World3D, with the view's `_world` at the part's orthonormalized global transform. Scale is left out and the view says so.
     - The view's WorldEnvironment is taken out while the scene world has an environment (the editor's preview counts).
     - Its head and top lights go off while a visible Light3D outside the view shares that world (the preview sun counts).
     - The grid turns off (Display > Grid brings it back) and comes back as it was.
     - The part's baked nodes are hidden with `RenderingServer.instance_set_visible` only, so `visible`, the undo history and the scene are untouched.
     - Picking still sees only the part.
   - **Glue** (`forge_workspace.gd sync_passthrough`):
     - It attaches when Passthrough is on, the tab is shown and the part is in the edited 3D scene.
     - It detaches on the tab hidden, part or scene changes and plugin exit.
     - It follows the part when it moves and re-hides baked nodes after rebakes (`SceneTree.node_added`).
     - The setting is saved in project metadata `holo_forge/passthrough` (`passthrough_store`).
   - **Part-space rule:** all Forge math is in `_world`-local space.
     - Use the helpers `world_transform()`, `to_world()`, `from_world()`, `camera_transform()`, `camera_position()` and `camera_basis()`.
     - `project()` and `ray_from()` are computed in part space; Godot's float32 path drifts 0.44 px at 400 m.
     - The section shaders take a `world_to_part` uniform.
     - The user argument `--holo-forge-test-world-offset` moves `_world` off its origin. Every test and hook must pass with it too.
   - **Engine gotchas:**
     - Toggling `own_world_3d` in the tree prints "scenario is null", so the view keeps its own `_private_world` and swaps `world_3d`.
     - Far 4000 over a tiny near breaks the frustum ("create_frustum_points") and the scene is culled, so far/near stays within `PASSTHROUGH_DEPTH_RANGE` (2e5): near moves out up to a fifth of the orbit distance, then far comes in.
   - **Tests:**
     - `tests/holo_forge_passthrough_test.gd` (headless, both modes).
     - `tests/holo_forge_passthrough_render_test.gd` (windowed; Forward+ and Compatibility). It covers the scene wall and sky around the part, a scene board in front hiding it, no double draw, and off restoring the view's own background.
     - The new 13th hook `--holo-forge-passthrough-editor-test` builds `tests/holo_forge/passthrough_editor_test.tscn`. It clicks Display, switches to the 3D tab and back, picks the part, and checks for no undo step and the hook guard.
   - **Offset run (2026-11-18):** every headless test and 12 hooks pass with `--holo-forge-test-world-offset`.
     - It found one test assumption, in `holo_forge_form_editor_fix_checks.gd` (window visibility used the camera's global position), and fixed it.
     - Backups from before the change are in scratchpad `backup_passthrough\`.
   - **Gate (2026-11-18, 15:21-15:54, sequential, normal mode):** 67/70 headless tests pass. The other three are the two window-only render tests, which pass windowed, and `mesh_save_faults`, whose 10 parse errors are its deliberate missing files. All 13 editor hooks pass, and all 4 windowed runs (background and passthrough render, Forward+ and Compatibility) pass with no engine errors. validate_project shows the known 6.

**Optional small item:** heads-up length and angle fields while drawing lines. Its work order is `docs/holo_forge/heads_up_fields_work_order.md`. The full dimension spec is `docs/holo_forge/dimension_spec.md`.

## Known limits, already accepted

**Surface (Phase 5):**
- G1 caps can't stay tangent right up to a corner where two G1 edges meet.
- 5+ sided G1 caps on steep walls are refused.
- Natural Extend across trimmed edges falls back to tangent.
- Thickening the banded G1 dome takes about 4 minutes. The rebuild runs on the main thread.
- Boolean volumes carry a pcurve error of about 4e-5.

**Sketch:**
- planegcs gives slightly different results on under-constrained sketches from run to run.

## Working rules for the next session

- Never kill Godot processes you didn't start. The user's editor is often open.
- Don't modify the user's scenes.
- Don't run `.ps1` files with ExecutionPolicy Bypass.
- No Autodesk names or art anywhere in the project. Call it "the other app".
- Reproduce user-reported UI bugs with real input events (`root.push_input`). The editor hooks call tools directly and miss real input bugs.
