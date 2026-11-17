# Holo Forge Sketch Dimensions: work order to make them work and look like the other app's

This is a work order for an AI implementer. It compares the other app's sketch dimensioning (from the research pass) with Holo Forge today (from the audit pass, with probes and screenshots). It says exactly what to change so that Holo Forge's Sketch Dimension tool both works and looks like the other app's. You should not need any further research. Research items with low confidence are listed in section 5, together with the decision this spec takes for each.

The user asked for two things: "check how dimensioning works in [the other app]. dimensioning should work similarly", and then "the visual look of dimensions should look similarly as well."

---

## 0. Ground rules (read first)

1. **Coordination.** Another workflow is editing `ui/sketch_editor.gd` and `ui/forge_theme.gd` (the toolbar/palette/dark-mode work, wf_086b5023-551). Start only after it has ended. Then re-read both files. The line numbers in this document were taken on 2026-10-29 and will drift, so find code by function name.
2. **Originality.** Standard drafting conventions are free to use: thin dimension and extension lines with gaps, filled arrowheads, the value on the dimension line, Ø and R prefixes, the degree sign, parentheses for driven values, angle arcs, and radius and diameter leaders. Never copy the other app's UI text, icons, fonts or art. Every string in this spec is our own wording. In code comments, tests, commit messages and anything else that goes into the project, call it "the other app" and never use its name.
3. **Theme.** Every colour comes from `forge_theme.gd` palette tokens (section 1b.4). Never hard-code a colour in drawing code. Both palettes must keep identical key sets, which `tests/holo_forge_theme_test.gd` checks.
4. **Scale.** Every pixel size in this spec is at editor scale 1. Multiply by `S = EditorInterface.get_editor_scale() if Engine.is_editor_hint() else 1.0`, the same expression `floating_panel.gd` and `toolbar.gd` use. Font sizes are `int(round(13 * S))` and so on.
5. **Existing documents** must load, rebuild and solve exactly as before. Every new constraint field is optional, and absence means today's behaviour (section 2, "Risks", in each item).
6. **Undo.** Every user action that changes the document is exactly one undo step, through `workspace.change()` or `workspace.commit_change()`. Trial solves run on scratch copies and never touch the document, its counters or the history.
7. **Tests** never save the user's scenes and never touch the user's project metadata.
8. **Paths and commands:**
   - Project: `D:\Hover_Board_Racing\Godot_Board_Racing\godot-board-racing`
   - Godot: `D:\Hover_Board_Racing\Godot_Board_Racing\Godot_v4.7.1-stable_win64.exe\Godot_v4.7.1-stable_win64_console.exe`
   - Native source (needed only for P3-2): `D:\Hover_Board_Racing\Godot_Board_Racing\holo_forge_native` (`build.ps1`; build output on C:, and the DLL is copied to `addons/holo_forge/bin`).
   - Audit probes, logs and screenshots, for reference: `C:\Users\Blaze\AppData\Local\Temp\claude\D--Hover-Board-Racing\201f9237-6a81-4e60-8b92-09865c66cf8d\scratchpad\dimensions\audit\`. `probe_shots2.gd` is a good template for windowed screenshots. `ws_undo.gd` gives `history()` a real UndoRedo outside the editor.

### File map

| File | Role today | Changes in this work order |
|---|---|---|
| `addons/holo_forge/ui/sketch_editor.gd` | Overlay drawing, tool engine, `_draw_dimensions` (~380), `_format_dimension` (~414), `_dimension_anchor` (~422), `hit` (~510), `handle_key` (~741), `start_tool`/`cancel_tool` (~772/809), `_constraint_or_dimension_click` (~1214), `dimension_spec` (~1238), `open_dimension_edit`/`_open_edit`/`_close_edit`/`_on_edit_submitted` (~1338-1390), `_check_new_constraint` (~1395), `fully_define` (~1460), `apply_theme` (~1685) | Most of the work |
| `addons/holo_forge/core/sketch/dimension_layout.gd` | (new) | Pure functions: measuring, orientation, angle sectors, plane layout, screen layout, number formatting (Appendix A) |
| `addons/holo_forge/core/sketch/sketch_solve.gd` | planegcs bridge, `_add` | Angle `rays` mapping and the measured value for driven angles. P3: `edge`, `linear_diameter` |
| `addons/holo_forge/core/sketch/sketch_data.gd` | Entities and constraints; `add_constraint`, `set_driving` | Document the new optional fields; `set_driving` remembers and reuses the parameter name |
| `addons/holo_forge/core/sketch/sketch_builders.gd` | `fully_define` (~887) | Document-unit expressions, no zero dimensions, placed text |
| `addons/holo_forge/core/units.gd` | `format_value` (4 decimals) | Optional `decimals` parameter |
| `addons/holo_forge/ui/forge_theme.gd` | DARK/LIGHT palettes with `dim_text/dim_back/dim_back_selected/dim_border/dim_leader` | New `dim_*` tokens (section 1b.4) |
| `addons/holo_forge/ui/forge_workspace.gd` | `_open_marking_menu` (~1851), `history()`, `last_step`, `flash()` | Dimension entries in the marking menu; the Delete slot uses the sketch selection while sketching; `var last_flash` set by `flash()` (for tests) |
| `addons/holo_forge/ui/marking_menu.gd` | `_make_button(entry)` | `"checked"` entries |
| `addons/holo_forge/ui/forge_viewport.gd` | `_overlay`, `plane_hit`, `pixels_per_meter_at` | New `focus_view()` (gives `_overlay` the keyboard focus) |
| `tests/holo_forge_dimension_test.gd` | (new, headless) | All the headless assertions below |
| `tests/holo_forge_theme_test.gd` | Palette parity and contrast | New token checks; remove the checks for the deleted tokens |
| `tests/holo_forge_sketch_editor_test.gd` | In-editor hook `--holo-forge-sketch-editor-test` | Updated driven flow, plus the new in-editor checks |
| `tests/holo_forge_workspace_test.gd` | Headless; uses `editor._pending_dimension` and `editor._edit` | Must still pass. Keep those two member names |

---

## 1. Summary of the target behaviour and look

**Behaviour.** There is one Sketch Dimension tool, started with D, from the Sketch CREATE menu, or with Repeat in the marking menu. The tool works out the dimension kind from what you pick:

| You pick | You get |
|---|---|
| A line | Its length |
| Two points (line ends, centres, the sketch origin) | Their distance |
| A point and a line | The perpendicular distance |
| Two parallel lines | The gap between them |
| Two non-parallel lines | An angle |
| A circle | Its diameter |
| An arc | Its radius |
| A circle or arc with another item | The distance from its centre |

After the picks, a full preview dimension follows the cursor until you click to place it:

- **Linear dimensions:** where you pull the text decides horizontal, vertical or aligned.
- **Angles:** where you put the text decides which of the four angles at the crossing you get.

The placing click stores the text position. Then one of two things happens:

- **Over-constraining:** if the new dimension would over-constrain the sketch, you are asked straight away whether to add it as a driven (reference) dimension.
- **Otherwise:** an inline value box opens on the dimension at the text spot. It holds the measured value with its unit, all selected.

**The value box:**

- It takes numbers, units, arithmetic and parameter names. Clicking another dimension inserts that dimension's parameter name.
- Invalid text turns red and can't be committed.
- Enter commits one undo step and the sketch re-solves.
- Esc cancels.
- The tool stays active for the next dimension.

**Afterwards:**

- Double-click reopens the box showing the expression.
- Drag the text to move it.
- Hovering highlights the dimension and shows a small tooltip with its parameter.
- Delete removes the dimension and its parameter.
- Right-click offers options: driven/driving, radius/diameter, and before placing, horizontal/vertical/aligned.
- Edits that over-constrain the sketch or can't be solved are refused, and the geometry stays as it was.

**Look.** Real drafting dimensions replace today's boxed labels and leaders:

- Thin anti-aliased 1 px dimension and extension lines.
- Extension lines leave a 3 px gap at the geometry and run 5 px past the dimension line.
- Slender filled arrowheads, 9 x 3.6 px, with their tips on the extension lines.
- Regular-weight 13 px text that stays the same size on screen at every zoom. It sits 4 px above the dimension line, rotated along it and never upside down. Vertical text reads top to bottom.
- Short dimensions put their arrows outside.
- Angles are drawn as arcs centred on the lines' crossing.
- Radii and diameters get leaders with arrowheads on the curve and a short landing under horizontal text.
- Text formats: `R10.00`, `Ø20.00`, `30.0°`, `(40.00)` for driven, `ƒ 20.00` for expression-driven. No units on the canvas.
- There is no text background box.
- Colours come from theme tokens and read well on the light and the dark canvas:
  - normal: near-black lines on light, pale green on dark;
  - hover and selection: blue;
  - preview: lighter;
  - conflict or unsolvable: red.

---

## 1b. Visual spec: drawing dimensions in the overlay

### 1b.1 Metrics (multiply every pixel value by S)

| Metric | Value at S = 1 | Notes |
|---|---|---|
| Dimension line width | 1.0 px, anti-aliased | `draw_line(a, b, color, 1.0 * S, true)`. A **selected** dimension uses 1.5 px |
| Extension line width | 1.0 px, anti-aliased | Same colour as the dimension line |
| Arrowhead | Filled isosceles triangle, length **9 px**, base width **3.6 px** (half-width 1.8) | The tip lies exactly on the extension line, the curve or the ray. Draw it with `draw_colored_polygon([tip, l, r], c)` and then `draw_polyline([tip, l, r, tip], c, 1.0, true)` so the edges are anti-aliased |
| Extension line gap at the geometry | **3 px** | Measured on screen from the feature point, or from the segment end for line extensions |
| Extension line overshoot past the dimension line | **5 px** | |
| Text font | `overlay.get_theme_default_font()`, **regular** weight, size **13 px** (`int(round(13 * S))`) | Fixed size on screen; never scales with zoom |
| Text offset from the dimension line | Baseline **4 px** above the line, in the text's rotated frame | The line is **not** broken under the text |
| Short dimension threshold | Feet closer than `2 * 9 + 6 = 24 px` on screen | Arrows then go outside (1b.2.3) |
| Outside arrow tail | Dimension line continues **15 px** beyond each foot, outward | The arrow body sits on the first 9 px |
| Text placed beyond an extension line | The dimension line extends from that foot to the far edge of the text **+ 2 px** | |
| Radius/diameter landing | Horizontal on screen, length `max(12 px, text_width + 4 px)` | The text baseline sits 3 px above the landing |
| Angle text | **4 px** outside the arc, rotated along the arc tangent | |
| Display-only default offset | **24 px** | Used when the stored text position lies on the measured geometry (old documents, old Fully Define): the line is drawn 24 px to the plane-up (or plane-left) side. Nothing is stored |
| Hit area of the text | The text box grown by **3 px** on every side (a rotated polygon) | |
| Hit distance of dimension, extension and arc lines | **4 px** | Lower priority than sketch curves |
| Hover tooltip | Font 12 px, padding 6 x 3 px, corner radius 4, top-left 16 px below and 8 px right of the cursor | |
| Value box | Font 13 px, height = font height + 6 px, min width 96 px, width = text width + 24 px, 1 px border, corner radius 2 | Centred on the dimension's text centre |

All the geometry is computed in **plane coordinates** (metres, `SKETCH.to_world` then `viewport.project`). Every pixel quantity above is applied in **screen space** along the projected directions. This keeps dimensions correct when the sketch is seen at an angle. Text stays upright on screen and is not foreshortened (section 4).

### 1b.2 Anatomy by form

Notation: **T** is the stored text position, `_dimension_anchor(s, c) + c.offset`. Its meaning is unchanged, which is why old documents keep their placement. **Feet** are the points where extension lines meet the dimension line.

#### 1b.2.1 Linear: horizontal (`distance_x`), vertical (`distance_y`), aligned (`length`, point-point `distance`)

```
      :                         :        <- extension lines end 5 px past the dimension line
      |          30.00          |        <- text: centred on T along the line, baseline 4 px above it
      |<----------------------->|        <- dimension line 1 px through T; arrows inside, tips on the extension lines
      |                         |
      |                         o        <- feature point; extension line starts 3 px away from it
      |                       /
      o---------------------/            (here a slanted line measured horizontally)
```

- **Measuring direction m:** `distance_x` uses plane +X, `distance_y` uses plane +Y, aligned uses `(b - a).normalized()`.
- **Offset direction k:** `m.orthogonal()`.
- **Dimension line:** parallel to m, passing through T. The feet are `foot_a = a + k * ((T - a)·k)` and `foot_b = b + k * ((T - b)·k)`.
- **Extension lines:** from each feature point toward its foot, starting 3 px from the point and ending 5 px past the foot. If a feature point is within 4 px of its foot on screen, skip that extension line.
- **Text:**
  - The anchor is T projected onto the dimension line, which is T itself.
  - Rotate the text to the dimension line's screen direction, normalised to upright (1b.3).
  - The text sits above the line in the rotated frame.
  - Result: horizontal dimensions have text above the line, and vertical dimensions have text to the right of the line, reading top to bottom.

#### 1b.2.2 Point-to-line, parallel lines, circle/arc centre-to-line (`distance` with a line ref)

```
            |<- 15.00 ->|  (rotated: this dimension line is perpendicular to the measured line)
   ---------+-----------o----              point P; extension line runs from P parallel to the line
            ^
   =========+================              measured line (extended thinly if the foot is off the segment)
```

- **m and k:** m is the measured line's unit normal n, and k is the line's direction u.
- **Feet:**
  - `foot_a` is T projected onto line a.
  - `foot_b` is the point (or circle centre) slid along u to T's along-position, or T projected onto line b for two parallel lines.
- **Extension:** draw one from the point (3 px gap, 5 px overshoot), parallel to the line.
- **Line extensions:**
  - When it is needed: if a foot falls outside its line segment.
  - What to draw: a thin extension along that line, from 3 px beyond the nearer segment end to 5 px past the foot.
  - Width and colour: the extension-line width and the dimension colour.

#### 1b.2.3 Short dimensions and text outside

```
   short:   ---->|   |<----     30.0 above the gap, or beside it if T is outside
   text out:  |<------->|------- 120.00          the dimension line runs on under the text (+2 px)
```

- If the feet are closer than 24 px on screen:
  - Arrows point inward from outside, with their tips on the feet.
  - Tails run 15 px beyond each foot.
  - The text stays at T, above the line.
- If T lies beyond a foot along the line, extend the dimension line from that foot to the far edge of the text + 2 px.

#### 1b.2.4 Angle (`angle`)

```
              \  ray 1
               \
        30.0°   )   <- arc centred on the vertex V, radius |T - V|, arrows at both ends touching the rays
                 )
   V ------------+------  ray 0
```

- **Vertex V:** the crossing of the two infinite lines (`Geometry2D.line_intersects_line`).
- **Sector:**
  - Dimensions with `rays` (section 2, P1-4) use their stored sector: from ray0 = `rays[0] * dir(refs[0])` counter-clockwise to ray1.
  - Legacy angles (no `rays`) use the sector that holds T (Appendix A, `angle_sector`).
- **Arc:**
  - Radius `rho = |T - V|` in plane metres. If it is under 30 px on screen, use 30 px.
  - Sample at most every 3°, with at least 8 segments.
  - Project the samples and draw them as an anti-aliased polyline.
- **Arrows:** one at each arc end, tip on the ray, pointing outward along the arc. On screen, `dir = (s0 - s1).normalized()` at the start and `(sN - sN-1).normalized()` at the end. If the arc's on-screen chord is under 24 px, flip the arrows outside with 10 px straight tails along the tangent.
- **Ray extensions:** a ray needs one when its line segment does not reach radius rho. The segment covers `[t0, t1]` along the ray, from the projections of its ends. If rho > t1, extend from `V + ray * t1` (3 px gap) to `V + ray * rho` (+5 px). If rho < t0, extend from `V + ray * rho` (-5 px) to the segment start (-3 px gap).
- **Text:**
  - Place the text at angle `angle(T - V)`, clamped into the sector, and at radius rho + 4 px outside the arc.
  - Rotate it along the arc tangent at that point, normalised upright, and centre it.

#### 1b.2.5 Radius (`radius`)

```
   text outside:          R10.00            text inside:      ( c ----> R10.00 )
                        ________                               arrow on the arc,
             ----->|----                                       pointing outward
      ( c )  arrow tip on the arc, pointing to the centre
```

- u = `(T - c).normalized()`. If T == c, use `(1, 1).normalized()`.
- **Text outside (|T - c| > r):**
  - The leader runs from the arc point `c + r * u` out to T.
  - The arrowhead's tip is on the arc, and it points toward the centre, with its body outside.
  - At T, draw a horizontal landing toward the side the leader points to (+x on screen if `T.x >= arc_point.x`, otherwise -x).
  - The text is horizontal on screen, sits on the landing, and starts 2 px from T, extending away from the leader.
- **Text inside:**
  - The leader runs from the centre to `c + r * u`, with an arrow at the arc point pointing outward.
  - The text is horizontal and centred at T, 4 px above.
- **Partial arc:** if u's angle lies outside the arc's span (CCW from s to e), draw a thin arc extension along the circle, in the dimension colour, from the nearer arc end to the arrow point plus 4 px.

#### 1b.2.6 Diameter (`diameter`)

```
   text outside:  far arrow --|( ---- c ---- )------ Ø20.00
                                                    ________
   text inside:   |<---- Ø20.00 ---->|   (line through the centre, arrows at both ends pointing outward)
```

- **Text outside:**
  - One line runs from the far point `c - r * u`, through c and the near point `c + r * u`, to T, then a landing as for radius.
  - There is one arrowhead, at the far point. Its tip is on the circle and it points away from the centre (direction -u), with its body inside the circle.
- **Text inside:**
  - The line spans the full diameter, with arrowheads at both ends pointing outward (tips on the circle).
  - The text is horizontal, centred at T, 4 px above.
- **Partial arcs** (a diameter on an arc, P2-5): add arc extensions on the missing side, as for radius.
- The centre itself is the existing centre point; there is no extra centre mark.

### 1b.3 Text

- **Font:** the overlay theme's default font, regular weight. Size 13 px x S for values and 12 px x S for the tooltip. Never bold. This is our editor font, never the other app's font.
- **Upright rule:** take the screen direction v of the dimension line, or of the arc tangent at the text. Set `angle = atan2(v.y, v.x)`:
  - if `angle > PI/2 + 1e-6`, subtract PI;
  - if `angle <= -PI/2 + 1e-6`, add PI.
  - So vertical lines get +PI/2: the text reads top to bottom and sits to the right of the line.
- **Drawing:**

  ```gdscript
  overlay.draw_set_transform(anchor, angle, Vector2.ONE)
  overlay.draw_string(font, Vector2(-w * 0.5, -gap), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)
  overlay.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
  ```

  Here `gap = 4 * S` (the baseline offset), and `w = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x`. Radius, diameter and landing text use angle 0 and left or right alignment.
- **Numbers** (Appendix A, `canvas_number`):
  - **Lengths:** in the document's unit, with no unit shown. Round to 3 decimals, then drop one trailing zero at most, so there are always at least 2 decimals: `40.00`, `12.50`, `13.079`, `5.333`. The same rule applies to inches.
  - **Angles:** degrees with exactly 1 decimal plus `°`: `30.0°`, `126.9°`.
- **Prefixes and suffixes:**
  - Radius: `R10.00`.
  - Diameter: `Ø20.00`. Use **U+00D8** (Ø), which every Latin font has. Today's U+2300 renders small.
  - Angle: `30.0°`.
  - Driven: the whole label in parentheses: `(40.00)`, `(Ø20.00)`, `(30.0°)`.
  - Expression-driven: the expression is not a plain literal (Appendix A, `is_literal`). Draw the marker `ƒ ` (U+0192 plus a space) before the number, as in `ƒ 20.00`. If `font.has_char(0x192)` is false, use `f ` instead. This marker is our own, deliberately not the other app's.
  - A driven label never has the marker.
- **Error values:** the parameter fails to evaluate, or the dimension is conflicting. Show the **measured** geometric value (Appendix A, `measure`) in the error colour, never `0`.

### 1b.4 Colour tokens (add to both DARK and LIGHT in `forge_theme.gd`)

Delete `dim_back`, `dim_back_selected`, `dim_border` and `dim_leader`; nothing else uses them (checked with grep). Keep the name `dim_text` with its new value, because the theme test checks `theme_colors.dim_text`. Update the theme test's contrast checks as in P1-2.

| Token | Role | Light canvas (`#f4f6f9` to `#cdd4de`) | Dark canvas (`#454a53` to `#1d2025`) |
|---|---|---|---|
| `dim_line` | Dimension lines, extension lines, arrowheads, angle arcs, landings | `#1b1f26` | `#b7d39a` (pale green: distinct from white defined geometry, blue free geometry, cyan selection, amber construction and grey-blue centerlines) |
| `dim_text` | Value text, normal state | `#3b414b` (a little lighter than the lines) | `#d9ecc4` (a little lighter than the lines) |
| `dim_preview` | Lines and text of the placing preview | `Color(0.106, 0.122, 0.149, 0.5)` | `Color(0.718, 0.827, 0.604, 0.55)` |
| `dim_hover` | Hovered dimension (lines and text) | `#1a5ccc` | `#8cc4ff` |
| `dim_selected` | Selected dimension, or the one being edited (lines and text) | `#0a4bb8` | `#6be0ff` |
| `dim_error` | Conflicting, unsolvable or broken-parameter dimension | `#a80f0a` | `#ff9a90` |
| `dim_tip_back` | Tooltip and name pill fill (dark on both canvases) | `Color("#2f3238", 0.94)` | `Color("#0f1115", 0.94)` |
| `dim_tip_text` | Tooltip text | `#ffffff` | `#f2f4f7` |
| `dim_box_back` | Value box field | `#ffffff` | `#1b1d21` |
| `dim_box_frame` | Value box 1 px border, unfocused | `#c9ced6` | `#3a3d44` |
| `dim_box_focus` | Value box 1 px border, focused | `#2a74d8` | `#4b9cff` |
| `dim_box_text` | Value box text and caret | `#1f242c` | `#dfe3ea` |
| `dim_box_selection` | Value box selected-text highlight | `Color(0.16, 0.45, 0.85, 0.30)` | `Color(0.30, 0.60, 1.0, 0.40)` |
| `dim_box_invalid` | Value box text while invalid | `#c4160f` | `#ff7a70` |

These contrasts were computed with the WCAG formula, and the theme test must enforce the minimums in brackets:

- **Light canvas (lightest / darkest end):**
  - dim_line 15.3 / 11.1 (>= 2.5)
  - dim_text 9.5 / 6.9 (>= 4.5)
  - dim_hover 5.6 / 4.1 (>= 3.0)
  - dim_selected 7.2 / 5.2 (>= 3.0)
  - dim_error 7.1 / 5.1 (>= 3.0)
  - dim_preview over the canvas 3.2 / 2.9 (>= 2.5)
  - tip text on tip back 10.7 (>= 4.5)
  - box text on box back 15.6 (>= 4.5)
  - invalid text on box back 6.1 (>= 4.5)
- **Dark canvas (`#454a53` / `#1d2025`):**
  - dim_line 5.4 / 10.0
  - dim_text 7.1 / 13.0
  - dim_hover 4.9 / 8.9
  - dim_selected 5.8 / 10.7
  - dim_error 4.4 / 8.0
  - dim_preview 2.8 / 4.0
  - tip text 16.7
  - box text 13.1
  - invalid text 6.7

If the user dislikes the green on dark, use `#c9d1dc` (neutral) for `dim_line` and `#e3e8ef` for `dim_text`. Arrows and the 1 px width still tell dimensions apart from centerlines, which are dashed.

### 1b.5 States (in priority order, highest first)

| State | When | Lines/arrows | Text | Width |
|---|---|---|---|---|
| Error | Constraint id in `state.solve.conflicting`; or its parameter result is not ok; or the sketch did not solve (`state.solve.ok == false`) and the dimension's target differs from its measured value by more than 1e-9 relative | `dim_error` | `dim_error`, measured value | 1.0 |
| Being edited | The value box is open on it (`_edit_constraint == id`), or it is the pending new dimension | `dim_selected` | Hidden (the box covers it) | 1.0 |
| Selected | `selection` has `{kind: "constraint", id}` | `dim_selected` | `dim_selected` | 1.5 |
| Hovered | `hover == {kind: "constraint", id}` | `dim_hover` | `dim_hover`, plus the tooltip (1b.6) | 1.0 |
| Preview | The placing preview (P1-3) | `dim_preview` | `dim_preview` | 1.0 |
| Normal | Otherwise | `dim_line` | `dim_text` | 1.0 |

Notes:

- Driven dimensions use the same colours as driving ones; only the parentheses differ.
- Expression-driven dimensions differ only by the `ƒ ` marker.
- Full definition does not recolour dimensions; geometry colours already show it.
- Picked geometry while dimensioning stays as today: `sketch_select`, 3.2 px.

### 1b.6 Value box, tooltip and name pill

**Value box** (the existing `_edit` LineEdit, restyled in `apply_theme`):

- **Styles:**
  - `normal`: a `StyleBoxFlat` with `bg_color = dim_box_back`, 1 px border `dim_box_frame`, corner radius 2 x S, content margins 6 x S left/right and 2 x S top/bottom.
  - `focus`: a `StyleBoxFlat` with `draw_center = false`, 1 px border `dim_box_focus`, corner radius 2 x S.
  - `read_only`: the same as `normal`.
- **Colour overrides:**
  - `font_color`: `dim_box_text`, or `dim_box_invalid` while the text is invalid.
  - `font_selected_color`: `dim_box_text`.
  - `selection_color`: `dim_box_selection`.
  - `caret_color`: `dim_box_text`.
- **Font size override:** `int(round(13 * S))`.
- **Text:** `alignment = HORIZONTAL_ALIGNMENT_CENTER`, `expand_to_text_length = true`, `custom_minimum_size.x = 96 * S`.
- **Position:** centred on the dimension's `text_center` from the screen layout, then clamped inside the viewport with a 4 px margin. The dimension's lines stay drawn under and beside the box, so the dimension line visibly continues on both sides.
- **Contents:** the text is all selected when the box opens. The unit is shown in the box (for example `50 mm` or `30 deg`) but never on the canvas.

**Name pill** (P2-2):

- Drawn by the overlay, not as a Control, 4 px below the box and centred under it.
- Style: `dim_tip_back` fill with radius 4 (`draw_style_box` with a `StyleBoxFlat`), `dim_tip_text` 12 px text.
- For a new dimension it shows the parameter name it will get: `"d%d" % (int(doc.counters.get("d", 0)) + 1)`.
- For an existing one it shows `d3`.

**Hover tooltip** (P2-2):

- The same pill style, 16 px below and 8 px right of the cursor.
- Text, in our own wording:
  - plain value: `d3 = 40 mm`
  - expression: `d3 = d1 / 2  (20 mm)`
  - driven: `Driven: 40 mm`
  - broken: `d3: <error message from the parameter result>`
- The value uses `UNITS.format_value(value, kind, doc.units)` (4 decimals, with unit).

### 1b.7 Draw order and hit areas

1. **Draw order:** grid, geometry, points, **constraint glyphs**, **then dimensions**, then the tool overlay (picks, preview, snap ring), then the tooltip and name pill. Dimensions now sit above glyphs (today the glyphs cover labels).
2. **Hit registration:** each drawn dimension appends `{"id", "poly": PackedVector2Array (text box + 3 px), "segments": [[a, b], ...], "text_center": Vector2, "text_angle": float}` to a new `_dim_hits` array, which is cleared at the start of `draw()`. Glyphs keep `_label_rects`.
3. **`hit(screen)` order:**
   1. points within 7 px (unchanged);
   2. dimension text polygons (`Geometry2D.is_point_in_polygon`);
   3. glyph rects;
   4. curves within 7 px;
   5. dimension line segments within 4 px.

   Dimension hits return `{"kind": "constraint", "id": id}` as today.
4. **Opening the box on an existing dimension:** `open_dimension_edit` locates the dimension through `_dim_hits` (its `text_center`), not `_label_rects`.

### 1b.8 Today vs target (audit screenshots)

The screenshots are in `...\scratchpad\dimensions\audit\shots\`. Their pixels are 1.2x logical because of Windows display scaling.

| Element | Today | Target |
|---|---|---|
| Every kind (`p2_overview_dark.png`, `p2_overview_light.png`) | A filled box with 13 px text and a 1 px **non-anti-aliased** 50 %-alpha leader to the middle of the measured item. The box sits 10 px right of and about 20 px above the click | Drafting dimension per 1b.2, with the text at the click |
| H / V / aligned on one slanted line (`p2_zoom_slanted_dark.png`, `p2_crop_driven_dark.png`) | Three identical boxes leaving one midpoint; you can't tell what is measured | Three visibly different dimensions: a horizontal line with vertical extension lines, a vertical line with horizontal extension lines, and an aligned line with perpendicular extension lines |
| Angle (`p2_zoom_angle_*.png`, `p2_crop_angle_dark.png`) | Box at the mean of the line midpoints; value from drawing direction (can be the supplement) | Arc at the vertex in the chosen sector, arrows on the rays, `39.8°` |
| Diameter / radius (`p2_crop_diameter_dark.png`, `p2_crop_radius_light.png`) | Box at the 45° point, small `⌀` | Leader with arrowhead on the curve, landing, `Ø20.00` / `R10.00` |
| Driven (`p2_crop_driven_dark.png`) | `(40)` box | `(40.00)` drawn like any dimension |
| Hover (`selected_parallel_hovered_angle_*.png`) | No change | Whole dimension `dim_hover`, plus the tooltip |
| Selected | Blue box fill | Lines and text `dim_selected`, 1.5 px |
| Conflict (`conflict_*.png`) | Red box border | Whole dimension `dim_error` |
| Value box (`p2_placing_value_box_dark.png`, `editing_existing_dark.png`) | Editor-themed LineEdit, 120 px, at click +(6,-12), covers neighbours, `40 mm` | Themed box centred on the dimension text spot, dimension line visible on both sides, measured value with unit, all selected |
| Fully Define (`p2_crowded_fully_defined_*.png`) | Labels stacked on anchors (`30)`, `0)`), `0` dimensions | Staggered dimensions with offsets, no zero dimensions (P2-7) |
| Zoomed out (`zoomed_out_*.png`) | Fixed-size boxes pile onto the geometry | Same text size (fixed); lines scale with the model. Crowding when far out is accepted, as in the other app |
| Dark-mode leader (`p2_crop_length_h_dark.png`) | Leader is close to the grid colour and vanishes along grid lines | Opaque `dim_line` pale green, not grid-coloured |

### 1b.9 Drawing implementation notes (Godot 4.7)

- **Lines:** `overlay.draw_line(a, b, color, 1.0 * S, true)`. A positive width plus `antialiased = true` gives a feathered quad. Never use a negative width.
- **Polylines** (angle arcs, arc extensions): `overlay.draw_polyline(points, color, 1.0 * S, true)`.
- **Arrowheads:** see 1b.1. Compute `perp = dir.orthogonal()`, `base = tip - dir * 9 * S`, `l = base + perp * 1.8 * S`, `r = base - perp * 1.8 * S`.
- **Rotated text:** use `draw_set_transform` as in 1b.3, and always reset it afterwards.
- **Pills:** cache one `StyleBoxFlat` per theme, rebuilt in `apply_theme`, and draw it with `overlay.draw_style_box(style, rect)`.
- **Perspective:** for every projected point, skip the dimension when `project()` returns non-finite, as today.
- **Cost:** layouts are computed every redraw. That is fine for hundreds of dimensions. Never run a solve or trial during drawing or mouse moves; trials run only on clicks and commits.

---

## 2. Gap list (ordered by user impact)

Legend: **P1** is a must-have for "works and looks similarly", **P2** is important, and **P3** is nice to have. Suggested order of work: P1-2 (tokens) and P1-1 (layout and drawing) together with P1-9, then P1-3 and P1-4, then P1-5, P1-6 and P1-7, then P1-8, then the P2 items, then P3.

Unless noted, every headless assertion goes into the new `tests/holo_forge_dimension_test.gd`. That file is an `extends SceneTree` test, run with `godot --headless --path . --script res://tests/holo_forge_dimension_test.gd`. Model it on `tests/holo_forge_workspace_test.gd`:

- create `WORKSPACE.new()` in `root`, set `ws.size = Vector2(1400, 900)` and await 3 frames;
- create a part with `CAD_PART` + `DOCUMENT` and `ws.set_part`;
- create a sketch with `ws.create_sketch(SKETCH_DATA.ORIGIN_PLANES.xy, "xy")`.

Drive the editor with `editor.start_tool`, `editor.tool_click(plane, {}, target)`, `editor.mouse_plane = ...`, `editor.handle_key(...)` and the new hooks named below. Read undo-step names from `ws.last_step.name` (it works without the editor). Print `PASS holo_forge_dimension: ...` or `FAIL ...`, and quit 0 or 1.

In-editor checks go into `tests/holo_forge_sketch_editor_test.gd`, run with `godot --headless --path . --editor -- --holo-forge-sketch-editor-test`.

---

### P1-1 Draw dimensions as drafting dimensions

**Current**

- `_draw_dimensions` draws every kind as a horizontal filled box with a 1 px non-anti-aliased leader from `_dimension_anchor` to the box corner.
- There are no dimension lines, extension lines, arrows, arcs or radius/diameter leaders.
- H, V and aligned dimensions look the same.
- The text is `⌀`/R-prefixed, has up to 4 decimals (`40`, `12.3456`), and angles have 2 decimals.

**Target**

- Every visible dimension constraint is drawn exactly as in sections 1b.1 to 1b.7, in all forms:
  - linear `length`, `distance` (point-point), `distance_x`, `distance_y`;
  - `distance` with a line (point-line, parallel lines, centre-line);
  - `distance` between round items (centre to centre: linear between the centres);
  - `angle`, `radius`, `diameter`.
- Text formatting follows 1b.3, and colours and states follow 1b.4 and 1b.5.
- The geometry for each dimension comes from the pure module `core/sketch/dimension_layout.gd` (Appendix A):
  - `plane_layout(s, c, _dimension_anchor(s, c))`
  - `screen_layout(plane, to_screen, metrics, text_w, ascent, descent)`
  - `canvas_text(c, value, doc.units, expression, marker)`, where marker is `"ƒ "` or `"f "` depending on `font.has_char(0x192)`
  - `measure(s, c)`
- `_draw_dimensions` becomes a thin loop:
  1. choose the state colour;
  2. format the text;
  3. measure it with the font;
  4. compute the layout;
  5. draw the lines, polylines, arrows and text;
  6. append to `_dim_hits`.

**Files and functions**

- New `core/sketch/dimension_layout.gd`.
- In `ui/sketch_editor.gd`:
  - rewrite `_draw_dimensions` and replace `_format_dimension` with a call to `DIM.canvas_text`;
  - add `_dim_hits`, `_ui_scale()`, `_draw_arrow()` and `_draw_text_rotated()`;
  - change the draw order in `draw()`;
  - change `hit()` (1b.7).
- `core/units.gd`: `format_value(value, kind, document_units, decimals := 4)`. Today's callers stay unchanged, and dimensions pass 6 for the value box.
- `_dimension_anchor` stays **unchanged**: it is the reference for stored offsets.

**Data model / solver.** None. The stored `offset` keeps its meaning (`T = anchor + offset`). Old documents get the new look at the same text positions.

**Tests (headless)**

All layout tests use an orthographic `to_screen := func(p: Vector2) -> Vector2: return Vector2(500, 500) + Vector2(p.x, -p.y) * 4000.0`, which is 4 px per mm with Y up. They also use metrics at S = 1, `text_w = 40`, `ascent = 12` and `descent = 3`.

- **`distance_x` on line (0,0)-(30,40) mm with T = (15, 50) mm:**
  - both feet have screen y = `to_screen(T).y` (to 0.01 px);
  - the feet's x values are 500 and 620;
  - the two extension lines are vertical;
  - the extension line from (0,0) starts 3 px from `to_screen((0,0))` and ends 5 px beyond its foot;
  - there are exactly 2 arrows, tips at the feet, `dir` pointing away from each other;
  - `text.angle == 0`;
  - the text anchor's x is 560;
  - the text baseline offset is negative (the text is above).
- **`distance_y`, same line, T = (40, 20) mm:**
  - the dimension line is vertical;
  - `text.angle` equals `PI/2` to 1e-6;
  - the hit polygon's centroid has x greater than the line's x (text to the right).
- **Aligned `length`, T = midpoint + n * 10 mm:**
  - the dimension line is parallel to the line (|cross| < 1e-6 after normalising);
  - the angle is in (-PI/2, PI/2].
- **Short:** a horizontal line 3 mm long (12 px) gives arrows whose `dir` points toward each other, plus two tail segments of at least 15 px.
- **Text outside:** T at x = 45 mm on a 0-30 mm line. The dimension line's max x is at least the text anchor's x + 20 + 2.
- **Angle,** lines (0,0)-(40,0) and (0,0)-(30,30), T = (20, 8):
  - every arc sample lies within 0.5 px of radius `|T| * 4000` around the vertex;
  - the arrow tips are within 0.5 px of the rays;
  - the arc's endpoints are on rays 0° and 45°.
- **Radius outside,** circle centre (0,0), r 10 mm, T = (20, 20) mm:
  - the arrow tip is r * 4000 ± 0.5 px from the centre on screen;
  - `dir · (centre - tip) > 0`;
  - a landing segment is horizontal.
- **Diameter inside** (T inside): two arrows pointing outward, and the line passes within 0.5 px of the centre.
- **Partial arc radius** with T outside the span: the layout has an extension polyline.
- **Upright rule:** screen directions at 100° and -100° both give angles in (-PI/2, PI/2].
- **Editor:** after a frame (or `editor.draw(ws.viewport._overlay)`), `editor._dim_hits.size()` equals the number of dimension constraints, and `editor.hit(_dim_hits[0].text_center)` returns `{kind: "constraint", id}`.

**Tests (in-editor hook).** In the existing sketch-editor test, after the "line becomes 30 mm" step:

- `editor._dim_hits.size() == 1`;
- the hit polygon is non-empty;
- the `editor.hit()` round trip works.

**Visual check** (windowed, not headless; adapt the audit's `probe_shots2.gd` into a scratch script, not in the project):

- Render the fixture in both themes at S = 1 and S = 1.5. The fixture is a 40 mm horizontal line, a 30x40 slanted line with H, V and aligned dimensions, a point-line distance, parallel lines, a 0°/-30° V with an angle, a circle Ø20, an arc R10, a driven dimension, a 3 mm short dimension and one conflicting dimension.
- Compare against 1b.1 to 1b.6 and fix any mismatch:
  - arrow tips touching the extension lines;
  - the 3 px gap;
  - the 5 px overshoot;
  - no text upside down;
  - vertical text reading top to bottom;
  - no background boxes.

**Risks**

- Fonts: Ø (U+00D8) is safe. For ƒ, check `has_char`.
- Perspective: compute everything in the plane and only offset by pixels on screen.
- `hit()` is also called from `snap_at()` (curve snapping). Keep the curve branch returning `kind: entity`, and don't let dimension-line hits change snapping. They return `kind: constraint`, which `snap_at` ignores.
- Large numbers of dimensions: no solving in draw.

### P1-2 Theme tokens for dimensions

**Current.** `dim_text`, `dim_back`, `dim_back_selected`, `dim_border`, `dim_leader`. The leader is a faint 50 % alpha and competes with the grid in dark mode.

**Target.** The token table in 1b.4, in both palettes, with the deleted keys removed. In `apply_theme`, restyle `_edit` (1b.6) and rebuild the cached pill StyleBox, then redraw.

**Files.** `ui/forge_theme.gd` (DARK and LIGHT), `ui/sketch_editor.gd` (`apply_theme`), `tests/holo_forge_theme_test.gd`.

**Tests (headless, in the theme test)**

- Both palettes have the same keys (existing check).
- The new contrast checks with the minimums from 1b.4, against both `view_top` and `view_bottom`:
  - `dim_line` and `dim_preview` (blended with `THEME.over`) >= 2.5;
  - `dim_text` >= 4.5;
  - `dim_hover`, `dim_selected` and `dim_error` >= 3.0;
  - `dim_tip_text` on `over(dim_tip_back, back)` >= 4.5;
  - `dim_box_text` and `dim_box_invalid` on `dim_box_back` >= 4.5.
- In dark mode, `dim_line` must differ from `sketch_defined` and from `sketch_centerline` by hue > 0.1 or luminance > 0.1.
- Remove the `dim_text on dim_back` and `dim_text on dim_back_selected` checks.
- The existing check at about line 195 (`theme_colors.dim_text == p.dim_text`) still passes.
- After `apply_theme`, `editor._edit.get_theme_color("font_color") == palette.dim_box_text`.

**Risks.** The palette-parity test fails if a key is added to only one palette. The other agent's theme work may add keys too, so merge carefully.

### P1-3 Live preview while placing, and the orientation rule

**Current**

- After the picks, nothing shows until the placing click: `_preview()` returns `[]` for the dimension tool.
- The orientation for a slanted line or a point pair comes from a bounding-box test (`by_placement` in `dimension_spec`).
- The placement uses the snapped `mouse_plane`.

**Target**

1. With at least one pick and the value box closed, every mouse move:
   - recomputes `spec = dimension_spec(ids, raw_plane, _dim_overrides)`;
   - draws it as a pseudo-constraint `spec + {"id": -1, "driving": !_dim_overrides.driven}` in the **Preview** state, with its measured value and the full text format (driven parentheses when the Driven override is on).
2. If the picks can't be dimensioned together, there is no preview, and only the click flashes the message.
3. **Raw placement point.** For the dimension tool, the placement point is the **unsnapped** plane point: `s.to_plane(viewport.plane_hit(screen, s.to_world(Vector2.ZERO), s.normal()))`. Store it in a new `mouse_plane_raw` in `handle_mouse`. While the dimension tool has picks, do not draw the snap ring.
4. **Orientation** for a slanted line, or two points (including the origin), uses `DIM.linear_orientation(pa, pb, place, single_line, lock, previous)` (Appendix A). The cursor's direction from the pair's midpoint picks the nearest of three axes (modulo 180°):
   - plane Y, meaning the cursor is above or below → **horizontal** (`distance_x`);
   - plane X, meaning the cursor is left or right → **vertical** (`distance_y`);
   - the pair's normal, meaning the cursor is beside it, perpendicular → **aligned**.

   It has a 4° hysteresis against the previous answer, which is kept in `_dim_last_orientation`. While the cursor is within 10 px of the midpoint on screen, the previous answer is kept.
5. **Level and upright pairs:**
   - A single line within 1 % of level or upright is always `length`, as today.
   - Two points that are level give `distance_x`, and two points that are upright give `distance_y`, unless the orientation is locked (P2-4).
6. The hint flashes `Sketch Dimension: click where the dimension goes (right-click for options).` once the pick set is complete.

**Files and functions**

- `sketch_editor.gd`:
  - `handle_mouse` (`mouse_plane_raw`);
  - `_draw_tool` (preview branch for `TOOLS[tool].dimension`);
  - `dimension_spec(ids, place, overrides := {})` (uses `DIM.linear_orientation` and returns `"orientation"` too);
  - new `_dim_overrides := {"orientation": "", "round": "", "driven": false}`, reset whenever the picks are cleared;
  - `_constraint_or_dimension_click` uses `mouse_plane_raw`.

**Data model.** None (the types already encode the orientation).

**Tests (headless)**

- **Line (0,0)-(30,40) mm picked; `dimension_spec([line], place)`:**
  - with place = midpoint + (0, 30) mm, the type is `distance_x`, the value is 0.030 and the refs are [p1, p2] with x ascending;
  - with midpoint + (30, 0), the type is `distance_y` and the value is 0.040;
  - with midpoint + n * 30 mm and midpoint - n * 30 mm (n the unit normal), the type is `length` and the value is 0.050;
  - the hysteresis call `linear_orientation(..., previous = "distance_x")` with a direction 2° past the H/A boundary still returns `distance_x`.
- **Horizontal line:** `length` at every placement (keeps the existing in-editor assertion).
- **Two level points:** `distance_x` both above and beside.
- **Preview:** after the first pick and a `_mouse_move` to a free spot (a synthetic `InputEventMouseMotion` through `editor.handle_mouse`), a redraw puts one preview entry into the editor's preview record. Expose `editor._preview_dimension` (the last drawn pseudo-constraint) for this. Its type changes from `distance_x` to `distance_y` as the cursor moves from above to the right.

**Tests (in-editor).** Move the real mouse over the view (`_mouse_move` with view coordinates from `viewport.project`). Assert that `_preview_dimension.type` follows the cursor. The existing `_pending_dimension.type == "length"` check for a horizontal line still passes.

**Risks.**

- The decision zones are our own approximation (section 5). Keep `linear_orientation` pure so it is easy to tune.
- The workspace and sketch-editor tests place dimensions with `editor.tool_click(place, {}, {})`, after setting `editor.mouse_plane = place`. Keep that working:
  - change the signature to `_constraint_or_dimension_click(target, plane)`, and use the `plane` passed to `tool_click` as the placement point;
  - in `_mouse_release`, call `tool_click(mouse_plane_raw if TOOLS.get(tool, {}).get("dimension", false) else mouse_plane, ...)`, so real clicks place at the unsnapped point;
  - the preview uses `mouse_plane_raw`.

### P1-4 Angles: quadrant by placement, stored as a positive sweep (fixes the mirror bug)

**Current**

- The value is `da.angle_to(db)`, the signed angle between the lines' drawing directions.
- The box is prefilled with the absolute value, and the solver gets that positive value.
- **Bugs:**
  - Committing the prefill of a clockwise angle mirrors the second line.
  - A V drawn as one chain offers 126.87° instead of the visible 53.13°.
  - Typing the visible angle turns the shape inside out.
  - The placement quadrant is ignored.

**Target**

1. **Sector choice.** At preview and placement, `DIM.angle_sector(a.p1, a.p2, b.p1, b.p2, place)` (Appendix A) finds the sector, out of the four at the crossing, that holds the cursor. The preview arc shows that sector live, and moving the cursor across a line switches sector.
2. **The spec** is `{"type": "angle", "kind": "angle", "refs": [line_of_ray0, line_of_ray1], "rays": [s0, s1], "value": sweep}`:
   - the refs are in counter-clockwise order;
   - `s = +1` when the ray follows that line's p1->p2 direction and -1 when it is reversed;
   - `sweep` is in (0, PI).
3. **Value box.** The prefill is the sweep in degrees (for example `53.130102 deg`), and Enter stores the typed sweep as the expression.
4. **Solver mapping** (in `sketch_solve._add`, `type == "angle"` and `c.has("rays")`):
   - pass the refs in their stored order;
   - pass `value_for_solver = value if rays[0] == rays[1] else value - PI` to the existing two-line `L2LAngle` branch.

   Why this is correct: reversing one ray adds PI to the signed angle between the stored directions. The planegcs error wraps with atan2, so a negative value is fine. **No native rebuild is needed.**
5. **Driven measurement.** After solving, for a driven angle with mixed rays, `measured = fposmod(get_constraint_value(tag) + PI, TAU)`. Otherwise use `fposmod(value, TAU)`.
6. **Legacy angles** (no `rays`) keep today's solver path, so old documents build the same. They are drawn with the sector that holds T, and show the absolute stored value.

   When a legacy angle is **edited** (Enter in the box), upgrade it: compute `angle_sector` from the current geometry and T, then set `refs`, `rays` and the expression in the same undo step. From then on the typed value applies to the visible sector.
7. **Validation.** An angle must satisfy 0 < value < 180°. Otherwise the box refuses it with `An angle between two lines must be more than 0° and less than 180°.`

**Files.** `sketch_editor.gd` (`dimension_spec` angle branch, `_on_edit_submitted`), `core/sketch/sketch_solve.gd` (`_add`, the measured loop), `dimension_layout.gd` (`angle_sector`, `measure`), and the `sketch_data.gd` header comment documenting `rays`.

**Tests (headless)**

- **V at 0° and -30°** (lines (0,0)->(40,0) and (0,0)->(40·cos30°, -40·sin30°)), place inside the opening at (30, -5) mm:
  - the spec value is 30° ± 1e-9;
  - committing the prefilled value leaves both lines' directions unchanged (to 1e-9);
  - committing `45` gives a visible opening of 45° ± 1e-7;
  - the sign of the cross product between the line directions is unchanged (no mirroring).
- **The same lines, placed in each of the 4 sectors:** the values are θ, 180-θ, θ and 180-θ (±1e-9).
- **Chain V** (140,20)->(100,0)->(140,-20) mm, placed inside the V: the spec value is 53.1301°. Commit `60`: the opening is 60° ± 1e-7, and the two far ends stay on their original sides of the bisector.
- **A legacy angle** constraint, hand-built without `rays` in a fixture: the document rebuilds with the same point coordinates as before the change (to 1e-12), and the solver warnings are unchanged.
- **Driven angle:** with the over-constraint flow, the measured value shown equals the sweep.

**Risks.** Do not change the legacy path. `fposmod` is needed because planegcs can settle at an equivalent angle.

### P1-5 The value box: placement, prefill, live validation and commit checks

**Current**

- The box opens at click +(6,-12), 120 px wide, in the editor's control theme.
- The prefill is `format_value` to 4 decimals.
- Nothing is validated:
  - `abc`, `20 deg` on a length, `-10` and `0` are all accepted;
  - a negative value stops the whole sketch solving, with no flash;
  - an impossible edit leaves the label showing the new value while the geometry keeps the old one.
- Empty Enter closes the box and keeps the picks.
- Esc closes the box and keeps the picks.

**Target**

1. **Opening.** After a non-over-constraining placement click (P1-7):
   - set `_pending_dimension = spec`;
   - open the box centred on the dimension's `text_center` (taken from the same screen layout the preview used);
   - prefill it with `UNITS.format_value(absf(spec.value), spec.kind, doc.units, 6)` (for example `50 mm`, `13.078972 mm`, `53.130102 deg`);
   - select all of the text.

   The pending dimension stays drawn in the "being edited" state, with its text hidden under the box.
2. **Live validation** on `text_changed`, with `_validate(text) -> {"ok": bool, "error": String, "value": float}`:
   - parse with `UNITS.evaluate(text, kind, doc.units, vars)`, where `vars` is `_parameter_values()` **without** this dimension's own parameter name (for an edit);
   - the evaluation must succeed (this also covers a wrong unit kind);
   - for `length`, `radius` and `diameter`, the value must be > 0;
   - for `distance`, `distance_x` and `distance_y`, the value must be >= 0;
   - for `angle`, the value must satisfy 0 < value < PI;
   - empty text is invalid.

   While the text is invalid, set the `font_color` override to `dim_box_invalid` and set `_edit.tooltip_text = error`. Otherwise use `dim_box_text`.
3. **Enter** (`_on_edit_submitted`):
   1. **If invalid:** keep the box open with the text unchanged and selected, and `workspace.flash("Dimension: " + error)`. Do not commit.
   2. **If valid:** run a **trial** (P1-7, `_trial`) of the change on a scratch document. If the trial's solve is not ok (`status == 2`), or the new or edited dimension is in `conflicting`, or a parameter error appears, refuse with `That value can't be solved with the sketch's other constraints.` and keep the box open, red.
   3. **Otherwise:** commit through `workspace.change("Sketch: Dimension", ...)` (or `"Sketch: Edit Dimension"`). That is one undo step. Then close the box, clear the picks and overrides, and keep the tool. Call `viewport.focus_view()` so D, L and the other keys work again.
4. **Esc in the box:**
   - **new dimension:** nothing is added, the picks and overrides are cleared, and the tool stays;
   - **edit:** close the box with no change.

   Both return focus to the view.
5. **A click in the view while the box is open** (intercepted at the top of `handle_mouse` for a left press, before anything else):
   - on a **driving** dimension's text or lines: insert its parameter name (P2-1);
   - on a **driven** dimension: flash `Driven dimensions have no parameter to use.`;
   - anywhere else: **accept**. If the text is valid, commit exactly as Enter does. If it is invalid, cancel as Esc does.

   The click is consumed in every case; it never starts a pick or a new placement.
6. **Look:** as in 1b.6.

**Files.** `sketch_editor.gd`: `_open_edit(at_center, text, constraint_id)` (centred, not offset), `_close_edit`, `_on_edit_submitted`, new `_validate`, `_edit.text_changed` connect, `_edit.gui_input` Esc handling, `handle_mouse`. Also `core/units.gd` (decimals) and `ui/forge_viewport.gd` (`focus_view()`).

**Tests (headless)**

- **30x40 line, aligned placement:**
  - `editor._edit.visible`;
  - `editor._edit.text == "50 mm"`;
  - `editor._edit.get_selected_text() == editor._edit.text`;
  - `_edit.position + _edit.size / 2` is within 2 px of the pending layout's `text_center`, before clamping (place it mid-view).
- **Refused submissions:** each of `abc`, `20 deg`, `-10`, `0` and `` (empty) must leave the dimension count unchanged, `_edit.visible == true` and `_edit.get_theme_color("font_color") == dim_box_invalid`. `ws.last_flash` must contain the error. Add `var last_flash := ""` to `forge_workspace.gd` and set it in `flash()`.
- **Accepted submission:** `40` is accepted, the line is 40 mm (1e-9), and `ws.last_step.name == "Sketch: Dimension"`.
- **Impossible edit:**
  1. Draw a 40x30 rectangle (`rect_2pt`).
  2. Dimension its bottom as `40`.
  3. Dimension the two opposite corners (an aligned point-point `distance`) as `50`. The height is free, so this is accepted.
  4. Double-click the diagonal and enter `30`, which is shorter than the 40 mm width. It is refused, the diagonal's expression stays `50`, the corner coordinates are unchanged (1e-12), and `editor.state.solve.ok`.
- **Esc in the box** (`_edit.gui_input.emit(key Esc)`, or call the handler): no constraint is added, `tool_picks.is_empty()` and `tool == "dimension"`.
- **Click away while the box is open:**
  - with the text valid: the dimension is committed;
  - with it invalid: cancelled.

**Tests (in-editor).**

- Type into the real LineEdit: set `_edit.text`, then `_edit.text_submitted.emit(_edit.text)`.
- Check that `ws.history()`'s last action name is `Forge: Sketch: Dimension`.
- Ctrl+Z (`history().undo()`) removes the dimension and its parameter.

**Risks**

- `tests/holo_forge_workspace_test.gd` relies on `_pending_dimension`, `_edit.visible` and the Measure suspend/resume. Keep `suspend()` and `resume()` hiding and re-showing the box.
- Existing callers of `_on_edit_submitted("30")` must keep working. The bare number `30` in mm documents is valid.

### P1-6 Value box lifetime bugs

**Current**

- `cancel_tool()` and `start_tool()` never close the box.
- Esc in the view cancels the tool but leaves the box visible.
- A click in the view doesn't close it.
- An undo that removes the edited dimension leaves the box open.
- Picking geometry while the box is open changes the picks, but the box still commits the old spec.

**Target**

- `cancel_tool()` calls `_close_edit()`. So does `start_tool()`, because it calls `cancel_tool()`.
- `refresh(result)`: if `_edit_constraint >= 0` and that constraint no longer exists, call `_close_edit()`. If `_pending_dimension` refers to an entity that no longer exists, also call `_close_edit()` and clear the picks.
- `handle_key` Esc while the box is visible: treat it as the box's Esc (P1-5 step 4).
- Clicks while the box is open are handled by P1-5 step 5, so picks never change under an open box.
- `suspend()` and `resume()` keep today's behaviour (hide and wait, then show again).

**Files.** `sketch_editor.gd`: `cancel_tool`, `refresh`, `handle_key`, `handle_mouse`.

**Tests (headless)**

- Open the box, then `editor.start_tool("line")`: `_edit.visible == false`, and the tool is `line`.
- Open the box, then `editor.handle_key(Esc)`: the box is closed, the picks are empty and the tool is `dimension`.
- Open an edit on an existing dimension, then run `ws._apply_snapshot(ws.part, before)` (undo without the editor; the same call the history makes): the box is closed.
- The workspace test still passes (Measure hides the box and gives it back).

**Risks.** Do not close the box in `suspend()`.

### P1-7 Over-constraint: ask at the placing click; trial-check every commit and edit

**Current**

- `_check_new_constraint` runs **after** the commit. If the new dimension is conflicting or redundant, it calls `workspace.history().undo()` and re-adds the dimension as driven, dropping the typed value. This is skipped when `history()` is null (outside the editor).
- Edits of existing dimensions, including driven -> driving, skip the check, which leaves the sketch conflicting or unsolved with no message.

**Target**

1. **New helper `_trial(mutate: Callable) -> Dictionary`.** It returns the solve result plus `{"added": [new constraint ids], "param_error": String}`, and never changes the real document, counters, history or selection. Appendix A has the code.
   1. Make a scratch `DOCUMENT.new()` and `restore(workspace.doc.snapshot())`.
   2. Find the sketch feature by `feature_id`.
   3. Call `mutate.call(SKETCH.new(scratch_feature, scratch))`.
   4. Run `PARAMETERS.evaluate(scratch)`.
   5. Run `SOLVE.solve(sketch, values)`.
2. **Over-constrained** means one of these: an id in the trial's `conflicting + redundant` that is not in the current `state.solve.conflicting + redundant`; or a new id in either list.
3. **At the placing click** (after a valid spec), unless the Driven override is on:
   - Trial-add the dimension as **driving** at its measured value. In the trial's input, the expression is the measured value formatted at 9 decimals with the unit.
   - **If it over-constrains**, show a `ConfirmationDialog`, created once and parented to the viewport:
     - title `Sketch Dimension`;
     - text `This dimension conflicts with the sketch's existing constraints.\nAdd it as a driven dimension that only measures?`;
     - OK button `Add Driven`;
     - Cancel button `Cancel`.

     OK adds the dimension driven (`add_constraint(type, refs, "", kind, false)`, with offset and rays) in **one** step, `Sketch: Driven Dimension`, with no value box. Cancel (or Esc, or closing the dialog) adds nothing. Either way, the picks are cleared and the tool stays.
   - **Test hook:** `var driven_answer := ""`. When it is `"ok"` or `"cancel"`, skip the dialog and use that answer. Leave it empty in production.
   - **If the Driven override is on,** add the dimension driven directly with no question.
   - **Otherwise,** open the value box (P1-5).
4. **On Enter** for a new dimension, and on any edit, run the trial check of P1-5 step 3.2.
5. **Driven -> driving** (double-click on a driven dimension, or P2-5's toggle):
   - The box opens prefilled with the measured value and its unit. Today it opens empty.
   - On Enter, the trial runs `set_driving(id, true, expr)`. If that over-constrains, refuse with `That would over-constrain the sketch, so the dimension stays driven.`, close the box and change nothing.
6. **Keep `_check_new_constraint`** as it is for non-dimension constraints (`apply_constraint`). For dimensions it should no longer trigger; leave it as a safety net.

**Files.** `sketch_editor.gd`:

- new `_trial`, `_would_over_constrain(spec)`, `_ask_driven(spec)`, `driven_answer` and `_driven_dialog`;
- `_constraint_or_dimension_click` and `_on_edit_submitted`;
- add `const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")`.

**Tests (headless)**

- **Rectangle (40x30) with its bottom dimensioned:**
  - Dimension the bottom again with `driven_answer = "ok"`:
    - no box opens;
    - exactly 1 driven constraint is added;
    - `ws.last_step.name == "Sketch: Driven Dimension"`;
    - the document's `counters.d` is unchanged by the trial (compare before and after);
    - the bottom stays 40 mm.
  - With `driven_answer = "cancel"`: nothing is added, the picks are empty, and the tool is `dimension`.
- **Driven -> driving at `60`:** refused; it stays driven; `state.solve.ok`; the message contains `stays driven`.
- **Driven override:** the Driven override on a free line adds a driven dimension with no box.
- **Trial isolation:** run `_trial` on a mutate that adds a constraint. Afterwards `workspace.doc.snapshot()` equals the snapshot taken before (compare `features[i].options` and `counters`), and `ws.last_step` is unchanged.

**Tests (in-editor).** Update the existing "second clashing length" block:

1. set `editor.driven_answer = "ok"` before the placement click;
2. remove the `_on_edit_submitted("45")` call;
3. assert one driven dimension and the line still at 30 mm;
4. the undo history's last name is `Forge: Sketch: Driven Dimension`;
5. undo removes it.

**Risks**

- The scratch `DOCUMENT.restore` copies every feature, which costs a few ms. That is fine on a click; never call it on a mouse move.
- planegcs may blame an older constraint for the redundancy. That is why rule 2 compares the sets.
- A sketch that is **already** conflicting before the click: rule 2 only counts new entries, so the user can still add dimensions elsewhere.

### P1-8 Pick flow: placement near geometry, degenerate picks, Esc in stages, hints

**Current**

- Every click on an entity becomes a pick, and a third pick discards the first two.
- A click near the geometry can't place: a click 5 px from a picked line re-picks it.
- The same entity twice, or a line plus its own end point, offers a 0 mm dimension.
- Esc cancels the whole tool, even when there are picks.
- There is one hint for the whole flow.

**Target**

1. **Click with no picks:** on an entity, it becomes the first pick, and the hint becomes `Sketch Dimension: pick a second item, or click where the dimension goes.` On empty space, a constraint or a glyph, it flashes `Sketch Dimension: pick a line, circle, arc or point.`
2. **Click with one pick:**
   - **Becomes a second pick:** the click is on an entity and `_pair_ok(first, second)` holds. That means the second entity is different from the first, isn't one of the first one's own defining points (end points or centre; check with `s.points_of(first)`), and the reverse holds as well. It also means `dimension_spec([first, second], any)` is non-empty.
   - **Otherwise it is a placement click:** this includes a click on the same line, on its own end point, on a dimension or glyph, or on empty space.
3. **Click with two picks:** always a placement click, wherever it is (on geometry, labels or empty space).
4. **Single point plus placement:** flash `Pick a second item to measure a point from.` and clear the picks.
5. **Esc:**
   - with the box open, see P1-5;
   - with picks, clear the picks and overrides, flash the start hint, and keep the tool;
   - with no picks, cancel the tool.
6. **Start hint** (`_tool_hint("dimension")`): `Sketch Dimension: pick a line, circle, arc or point.`

**Files.** `sketch_editor.gd`: `_constraint_or_dimension_click` (split the dimension branch out of the constraint branch), new `_pair_ok`, `handle_key`, `_tool_hint`.

**Tests (headless)**

- **Line picked, then `tool_click(..., {"kind": "entity", "id": same_line})`:** the box opens with spec type `length`, and `tool_picks.size() == 1` at that moment.
- **Line plus its own `p1` as the target:** placement, type `length`.
- **Two points picked, then a click on a third entity:** placement, not a third pick (`tool_picks.size() == 2` until the commit).
- **Esc:**
  - with picks: the picks are empty and the tool is `dimension`;
  - again: the tool is `""`.
- **Same point twice:** placement with a single point gives the flash and empty picks, never a 0 mm box.

**Risks.** The constraint tools share `_constraint_or_dimension_click`, so leave their branch unchanged.

### P1-9 Hover and selection look; hitting dimension lines

**Current.** Hover is computed, but `_draw_dimensions` never reads it. Selection fills the box blue. Only label rects can be hit.

**Target**

- States per 1b.5. Hit areas per 1b.7, so hovering the text **or** any dimension, extension or arc line highlights the whole dimension.
- A single press on a dimension (text or lines) selects it, as today with labels.
- Delete or Backspace removes it and its parameter in one `Sketch: Delete` step (existing).
- Double-click on the text or lines opens the box (existing path through `open_dimension_edit`).

**Files.** `sketch_editor.gd`: `_draw_dimensions`, `hit`, `_mouse_press`.

**Tests (headless)**

- `hover = {kind: constraint, id}`, then draw: the recorded state colour for that id is `dim_hover`. Expose `_dim_draw_log: Dictionary id -> {"state", "color"}`, filled during draw, for tests.
- Selected gives `dim_selected` and width 1.5.
- A point 2 px off the middle of a dimension line hits that constraint.
- A point on a sketch curve under a dimension line hits the curve.

**Risks.** Make sure line hits stay below curves, or picking geometry near dimensions becomes hard.

---

### P2-1 Click a dimension while typing to insert its parameter name

**Current.** A click on a label while the box is open re-runs the placement and resets the text: `d1 * 2` became `40 mm`.

**Target.** With the box open, a left press on a **driving** dimension (P1-5 step 5) does this:

1. Get `name = feature.inputs[c.key].name`. The clicked dimension may belong to another visible sketch, but only the open sketch's dimensions are drawn, so limit this to them.
2. If the box has a selection, replace the selection; otherwise insert at `caret_column`.
3. Spacing:
   - `before = text.substr(0, col).rstrip(" ")` and `after = text.substr(col).lstrip(" ")`;
   - prefix a space unless `before` is empty or ends with `(`;
   - suffix a space unless `after` is empty or starts with `)`;
   - for example, `d1 +` and a click on d2 gives `d1 + d2`.
4. Put the caret right after the name.
5. Re-grab the focus deferred (`_edit.call_deferred("grab_focus")`), because the viewport grabs the overlay focus on press.
6. Validate live.

Clicking the dimension being edited does nothing.

**Files.** `sketch_editor.gd`: `handle_mouse` (box-open branch) and a new `_insert_parameter(name)`.

**Tests (headless)**

- With `d1` existing, place a new dimension, then call `_insert_parameter("d1")` (or simulate the press at d1's `text_center` through `handle_mouse`): the text becomes `d1` (it replaced the selection).
- Type ` * 2`, then submit: the expression is `d1 * 2`, and the value follows d1 (change d1 and the new dimension changes).
- `d1 +` followed by inserting d2 gives `d1 + d2`.

**Risks.** Focus juggling: test in the editor that typing continues after a click (in-editor hook: insert, then `_edit.text` ends with the name and `_edit.has_focus()`).

### P2-2 Hover tooltip and name pill

**Current.** No tooltip. The Parameters dialog is the only place that shows a dimension's name.

**Target.** The tooltip and name pill from 1b.6. The tooltip shows only while hovering a dimension with no mouse button down and no drag.

**Files.** `sketch_editor.gd`: `draw` (after the dimensions) and the new `_dimension_tooltip(c) -> String`.

**Tests (headless)**

- `_dimension_tooltip` gives:
  - `d1 = 40 mm` for a literal;
  - `d2 = d1 / 2  (20 mm)` for an expression;
  - `Driven: 40 mm`;
  - for a broken parameter, it starts with `d3: ` and contains the error.
- The name pill text for a new dimension is `d<counter + 1>`.

**Risks.** None.

### P2-3 Drag dimension text to move it

**Current.** A press on a label selects it, and dragging does nothing. A dimension can only be moved by deleting it and dimensioning again.

**Target**

- With no tool, press on a dimension's text or lines, move more than 4 px, and release.
- Live, `c.offset = (mouse_plane_raw + grab) - _dimension_anchor(s, c)` is written to the live sketch, with redraw only (no solve).
- On release, `workspace.commit_change("Sketch: Move Dimension", before)`, which is one undo step.
- A press without moving just selects.
- For angles with `rays`, the text angle is clamped into the stored sector; the sector itself never changes on drag.
- Moving the text moves the whole dimension (the dimension line passes through T).

**Files.** `sketch_editor.gd`: `_mouse_press` (`_drag = {"type": "dim_text", "id", "start", "before", "grab", "moved": false}`), `_mouse_move` and `_mouse_release`.

**Tests (headless).** Synthetic press, motion and release events via `editor.handle_mouse`, at screen positions from `viewport.project`:

- the offset changes by the dragged plane distance (1e-9);
- `ws.last_step.name == "Sketch: Move Dimension"`;
- a 2 px move only selects.

**Risks.** `commit_change` triggers a rebuild, which is acceptable. Don't record a step when nothing moved.

### P2-4 Right-click options before placing

**Current.** A right-click while dimensioning opens the generic marking menu. There is no way to force H/V/aligned, radius/diameter, or driven.

**Target**

While `tool == "dimension"` and the picks are non-empty, `_open_marking_menu` puts the editor's `context_entries()` first in the overflow list:

| Entries | Shown for | Behaviour |
|---|---|---|
| `Automatic` / `Horizontal` / `Vertical` / `Aligned` | Slanted lines, point pairs, centre pairs | Radio; sets `_dim_overrides.orientation` to `""`, `distance_x`, `distance_y` or `aligned`. The lock holds regardless of the cursor until the picks clear |
| `Radius` / `Diameter` | A single circle or arc | Radio; `_dim_overrides.round` |
| `Driven` | Always | Check box; `_dim_overrides.driven` |

- The checked state uses a new `"checked": bool` key in marking-menu entries. `marking_menu._make_button` sets `toggle_mode = true` and `button_pressed = checked`, and prefixes the label with `✓ ` if the font has U+2713, otherwise `• `. Unchecked entries get no prefix but the same left padding (three spaces).
- The ring slots stay as they are.
- **Centre pairs:** circle/arc plus circle/arc, or point plus circle/arc, now follow the H/V/aligned orientation rule too. For `distance_x` and `distance_y`, the refs become the centre point ids, because the solver needs point pairs for those types. Aligned stays `distance` with the round refs, as today.

**Files.** `sketch_editor.gd` (`context_entries`, `dimension_spec` overrides), `forge_workspace.gd` (`_open_marking_menu`), `marking_menu.gd` (`_make_button`).

**Tests (headless)**

- `editor.context_entries()` labels for a slanted line pick include `Horizontal`, `Vertical`, `Aligned`, `Automatic` and `Driven`.
- Calling the `Vertical` entry's action, then `dimension_spec` at a place directly above the midpoint, gives `distance_y`.
- `ws.marking_menu.labels()` after `ws._open_marking_menu(Vector2(100, 100))` contains them.
- With a circle pick, `Radius` gives a `radius` spec with value r.

**Risks.** The marking menu is shared, so `checked` must default to absent, with no visual change for other entries.

### P2-5 Right-click on a placed dimension: Driven/Driving, Radius/Diameter, Edit, Delete

**Current**

- There is no toggle UI.
- Double-click on a driven dimension opens an empty box.
- The ring's Delete uses the workspace selection, not the sketch selection (`forge_workspace.gd` ~1859).

**Target**

When a dimension is hovered or selected, with no tool or with the dimension tool and no picks, `context_entries()` returns these entries.

**`Edit Value`:** opens the box.

**`Make Driven`** (driving dimensions), as one step `Sketch: Make Driven`:

1. Remember the parameter name in `c["param_name"]`.
2. Call `set_driving(id, false)`.

The expression is dropped, as in the other app.

**`Make Driving`** (driven dimensions):

1. Open the box prefilled with the measured value.
2. On Enter, run the P1-7 trial.
3. If it is ok, `set_driving(id, true, expr)` reuses `c.param_name` when `PARAMETERS.is_valid_name(doc, name)`. Otherwise it gets a new name.

**`Show as Diameter` / `Show as Radius`** (round dimensions), as one step `Sketch: Dimension Type`:

1. Swap `type` between `radius` and `diameter`.
2. Rewrite the expression:
   - a literal is multiplied or divided by 2 and re-formatted at 6 decimals in its own unit;
   - anything else becomes `(expr) * 2` or `(expr) / 2`.
3. Driven dimensions just swap the type.
4. The solver already supports both types on circles and arcs (`cad_sketch_solver.cpp` radius/diameter branch).

**`Delete Dimension`.**

**The ring's `Delete` slot:** while sketching, it is enabled when `sketch_editor.selection` is non-empty, and it calls `sketch_editor.delete_selection()`.

**Files.** `sketch_editor.gd`, `forge_workspace.gd` (`_open_marking_menu` Delete slot and overflow), `sketch_data.gd` (`set_driving` name memory).

**Tests (headless)**

- **Make Driven, then Make Driving `40`:** the parameter is named the same `dN` again, and there are 2 undo steps.
- **Radius `10` -> Show as Diameter:** the expression is `20` (or `20 mm` when it was `10 mm`), and the radius is unchanged (1e-9).
- **Expression `d1 / 2` -> Diameter:** the expression is `(d1 / 2) * 2`.
- **Delete through the marking-menu action** with a sketch dimension selected: removes it.

**Risks.** Renaming collisions are handled by `is_valid_name`. Old documents have no `param_name`, which is fine.

### P2-6 Expression marker and broken-parameter display

**Current.** Expression-driven dimensions look like plain ones. A broken parameter (unknown name, wrong kind, the referenced dimension deleted) shows `0`, and only the status line reports it.

**Target**

- Use `ƒ ` before expression-driven values (1b.3).
- A broken parameter's dimension is drawn in the Error state (1b.5) showing the **measured** value, and its tooltip shows the error.
- **When a dimension is deleted:** if any other parameter's expression references its name as a whole-word match, flash `d1 was used by d2, d5; those now show an error.`

**Files.** `sketch_editor.gd` (`_draw_dimensions`, `delete_selection`), `dimension_layout.gd` (`is_literal`, `measure`).

**Tests (headless)**

- `is_literal` is true for `40`, `40 mm`, ` 2.5in` and `1e-3 m`, and false for `d1`, `40 + 1`, `(40)`, `-4` and `2*3`.
- With d2 = `d1 / 2` and d1 deleted, d2's draw-log state is `error`, and its text equals the measured value (not `0.00`).
- The flash lists `d2`.

**Risks.** Whole-word matching: use `RegEx("\\b" + name + "\\b")`.

### P2-7 Fully Define: clean expressions, no zero dimensions, readable placement

**Current**

- Expressions are written in metres with float noise (`0.039999999 m`).
- It adds `0` dimensions for points on the origin's axes.
- Every offset is (0,0), so labels pile up.

**Target.** `B.fully_define(s, solve, gap := 0.0, units := "")`:

1. **Expressions** use `UNITS.format_value(value, kind, units, 6)` when `units != ""`, for example `40 mm`. Tests that call without units keep metres.
2. **Zero coordinates:** when `|p.x - o.x| < 1e-9`, add `vertical` [origin, p] instead of `distance_x`, and when `|p.y - o.y| < 1e-9`, add `horizontal` [origin, p] instead of `distance_y`. Keep each only if the trial keeps the solve ok with no conflict or redundancy, as today.
3. **Offsets** (plane metres), when `gap > 0`:
   - `length`: perpendicular gap on the side away from the sketch's bounding-box centre;
   - `radius` and `diameter`: text at 45° outside the curve, at r + gap;
   - `distance_x` from the origin: the dimension line at `min(o.y, p.y) - gap * (1 + n_x)`, where `n_x` counts the earlier `distance_x` dimensions in this run, and the text at x = the pair's middle;
   - `distance_y`: at `min(o.x, p.x) - gap * (1 + n_y)`.
4. **The editor** passes `gap = 28 px / viewport.pixels_per_meter_at(s.to_world(sketch bbox centre))` and `units = doc.units`.

**Files.** `core/sketch/sketch_builders.gd` (`fully_define`), `sketch_editor.gd` (`fully_define`).

**Tests (headless)**

- **Rectangle + circle + slanted line** in an mm document:
  - DOF is 0;
  - every new dimension expression matches `^\d+(\.\d{1,6})? mm$` (no `e`, no `99999`);
  - no dimension has the value 0;
  - no two dimensions' screen `text_center`s are within 12 px (after a draw);
  - one `Sketch: Fully Define` step.
- The existing `holo_forge_sketch_tools_test` call `B.fully_define(s, solve)` still passes unchanged.

**Risks.** Adding H/V point constraints instead of 0 dimensions changes which constraints Fully Define makes. This only affects new runs.

---

### P3-1 Edge (tangent) distances for circles and arcs

- **Target:**
  - A right-click before placing offers `Measure to Centre` (default) or `Measure to Edge`, for circle/arc with line, point or another circle/arc.
  - The spec gets `"edge": [bool per ref]`.
  - **Solver:** in `sketch_solve._add` (`distance`), skip the centre mapping for refs flagged edge. The **existing** native branches then apply: P2C, C2C and C2L, which call planegcs `addConstraintP2CDistance`, `addConstraintC2CDistance` and `addConstraintC2LDistance`. They measure to the curve, on the near side.
  - **Drawing:** feature points on the curve nearest the other item.
  - Far-side (maximum) distances are out of scope.
- **Tests:**
  - circle r 10 at (0,0) and line y = 30 with edge on gives value 20, and committing 25 moves them apart to an edge gap of 25 (1e-7);
  - circle-circle edge gap; point-circle edge distance inside and outside.
  - planegcs's internal cases (one circle inside another) are low confidence: test them, and refuse those picks with a flash if the results are wrong.
- **Risk:** low. The flag is absent on old documents.

### P3-2 Three-point angle and arc sweep angle

- **Target:**
  - Picks end point, vertex point, end point give the angle at the middle point.
  - An arc plus right-click `Sweep Angle` gives the arc's sweep.
  - **Native:** add a branch in `holo_forge_native/src/cad_sketch_solver.cpp` `add_constraint`: `t == "angle" && kinds({KIND_POINT, KIND_POINT, KIND_POINT, KIND_POINT})` calls `s.addConstraintL2LAngle(point_ref(r[0]), point_ref(r[1]), point_ref(r[2]), point_ref(r[3]), new_value(tag, value, driving), tag, driving)`. The 4-point overload exists in `thirdparty/planegcs/App/planegcs/GCS.h:335`.
  - Refs are `[vertex, endA, vertex, endB]`, in counter-clockwise order chosen with `angle_sector` logic on the two rays.
  - Rebuild with `build.ps1` and copy the DLL. The user's editor may be open, and copying still works.
  - The pick flow allows a third pick only when the first two are points and the third is a point.
- **Tests:** solver test for the 4-point angle; editor test with points (10,0), (0,0), (0,10) giving 90°, then commit 60.

### P3-3 Linear diameter against centerlines (for revolve profiles)

- **Target:** a `distance`, `distance_x` or `distance_y` dimension whose refs include a line with `centerline: true` is created with `"linear_diameter": true`. It is shown with `Ø` and holds twice the distance. The right-click `Diameter` checkbox turns it on or off before placing. **Solver:** `value * 0.5` in `_add`, and the driven measurement times 2. **Drawing:** a mirrored ghost arrow on the far side of the centerline (an extension line to the mirrored point).
- **Tests:** a point 15 mm from a centerline offers Ø30, and committing 40 puts the point 20 mm away.

### P3-4 `name = value` in the box renames the parameter

- **Target:** typing `width = 40 mm`:
  1. validates `width` with `PARAMETERS.is_valid_name(doc, "width", old_name)`;
  2. sets `inputs[key].name = "width"`;
  3. rewrites whole-word references to the old name in every model and user parameter expression;
  4. sets the expression to `40 mm`.

  All of this is one undo step.
- **Tests:** rename d1 to `width` while d2 = `d1 / 2`, so d2 becomes `width / 2` with the same value.

### P3-5 Heads-up length and angle fields while drawing (Line first)

- The other app shows editable length and angle fields on temporary dimensions while lines, rectangles and circles are being drawn. Tab moves between the fields and Enter locks a value; locked values become driving dimensions.
- This is a separate feature with its own UI loop. **Write a separate work order.** This pass should only make sure `dimension_layout.gd` can draw a pseudo-dimension for a rubber-band segment, which it already does through the preview path.

### P3-6 Smaller items

- **Parameters dialog labels:** model parameter labels say what they size, for example `Sketch1 Length` or `Sketch1 Diameter`, instead of `Sketch1 Dim 13` (`document.gd` `model_parameters`: look up the sketch constraint by key).
- **Favourites list on the value box:** a small `▾` button listing user parameters marked favorite (the Parameters dialog already stores `favorite`). Choosing one inserts its name.
- **Measured geometry highlight:** hovering or selecting a dimension also tints the geometry it measures (`dim_hover` at 60 % on those curves).

---

## 3. What already matches (keep it)

- **One inferred tool:**
  - D shortcut (`catalog.gd`: `Sketch Dimension`, `{"sketch": "dimension", "shortcut": "D"}`);
  - listed in the Sketch CREATE menu;
  - the tool stays active after each dimension;
  - the marking menu's `Repeat <tool>` slot.
- **The inference table** in `dimension_spec`:
  - line -> length;
  - two points -> distance (with H/V/aligned);
  - point + line -> perpendicular distance;
  - parallel lines -> gap;
  - non-parallel lines -> angle;
  - circle -> diameter;
  - arc -> radius;
  - round combinations -> centre distances.

  The sketch origin is a pickable point. Construction lines and centerlines dimension like lines.
- **Parameters:**
  - each driving dimension creates a document-wide model parameter `d<N>` (`doc.make_input`);
  - expressions accept units, arithmetic, functions and other parameter names (`units.gd`, `parameters.gd`), and bare numbers are document units, or degrees for angles;
  - dependants follow when a parameter changes.
- **Driven dimensions:**
  - they show the measured value in parentheses and have no parameter;
  - projected or fixed geometry makes a new dimension driven.
- **One undo step per action** (`Sketch: Dimension`, `Sketch: Edit Dimension`, `Sketch: Delete`, `Sketch: Fully Define`). Undo and redo restore both the constraint and its parameter.
- **Editing and deleting:** double-click a dimension to edit its stored expression; select it and press Delete to remove it and its parameter; deleting geometry removes its dimensions.
- **Display:**
  - the Sketch Palette's `Show Dimensions` checkbox shows or hides all dimensions and their hit areas;
  - units appear only in the value box, never on the canvas;
  - all dimension colours come from the theme (keep that; just change the tokens).
- **Fully Define** exists as one step, and it keeps a trial loop that refuses conflicts.
- **Measure, Curvature Comb and Canvas** suspend the sketch, and the pending dimension box comes back after them (`suspend`/`resume`).

## 4. Out of scope, or deliberately different

- **3D text.** The other app lays text in the sketch plane, foreshortened when orbited. Our text stays upright on screen at a fixed pixel size. Only its rotation follows the projected dimension line.
- **Original assets and wording.** We use the editor's font, our own colours (1b.4), our own `ƒ` marker (not the other app's marker), our own tooltip format (`d3 = 40 mm`), and our own dialog, hint and error wording. No icons or bitmaps.
- **Arc length dimensions.** The other app has none. The solver keeps `arc_length` support, and the tool still doesn't offer it.
- **Far-side (maximum) tangent distances** and **concentric radial-gap** dimensions are left out.
- **Ellipse major and minor radius dimensions:** they need native ellipse axis constraints, so they are left for a later work order.
- **Driven dimensions referenced by expressions.** The other app allows this since 2023. Ours have no parameter, so clicking one while typing explains that and inserts nothing.
- **Preferences** to turn off the value box on creation, auto-scale the sketch on the first dimension, set the dimension text size, or show names or expressions on the canvas: none, as in the other app. The tooltip is the cue.
- **Showing and editing dimensions outside sketch edit:** not now.
- **Sketch axes as pickable lines:** not now. Use the origin point plus H/V orientation.
- **Changing orientation (H/V/aligned) after placement:** not possible, as in the other app. Delete and redo.
- **Driven -> driving by double-click:** kept as a convenience. The other app refuses double-click edits on driven dimensions and uses its right-click toggle. We offer both.
- **Esc with the box open on a new dimension:** cancels the dimension. The other app's behaviour is undocumented (section 5).

## 5. Low-confidence research items, and the decision taken

| Item | Confidence | Decision in this spec |
|---|---|---|
| Exact cursor zones for horizontal/vertical/aligned | Research only says above/below, left/right, perpendicular band | Nearest-axis sector rule from the pair's midpoint, with 4° hysteresis (`linear_orientation`), plus a right-click lock. Tune only that function |
| Which side of a vertical dimension the text sits on | Seen on both sides | Always the right side when reading top to bottom (the upright rule's "above") |
| Esc and Tab inside the value box | Undocumented | Esc cancels a new dimension or abandons an edit. Tab does nothing special |
| A click on empty space while the box is open | Not documented | It accepts a valid value or cancels an invalid one, and the click is consumed |
| Dimension colour on a dark canvas (yellow-green in one official clip) | Low | Our own pale green `#b7d39a` and `#d9ecc4`, with a neutral alternative given (1b.4) |
| Default of "scale the sketch with its first dimension" | Unknown | Not implemented |
| Radius/diameter switch on a **placed** dimension | Medium (one blog post) | Offered (P2-5) |
| Display precision (3 decimals, minimum 2; angles 1 decimal) | Medium (observed defaults) | Implemented as stated (1b.3) |
| Arrowhead and gap pixel sizes | Medium (measured from official GIFs and PNGs) | 9 x 3.6 px arrows, 3 px gap, 5 px overshoot, 4 px text offset, 13 px text at S = 1 |
| Diameter leader with text outside: one arrow on the far side | Medium | As researched (1b.2.6) |
| planegcs edge-distance semantics in internal cases (P3-1) | Medium | Test numerically and refuse the picks if they are wrong |
| What the other app does when you dimension two parallel lines that aren't constrained parallel | Not researched | Unchanged: only the second line's first end is held, as today. Drawn at the text's along-position |

## 6. Verification recipe and definition of done

1. **Headless suites** (all must print PASS):

   ```powershell
   $godot = "D:\Hover_Board_Racing\Godot_Board_Racing\Godot_v4.7.1-stable_win64.exe\Godot_v4.7.1-stable_win64_console.exe"
   $proj  = "D:\Hover_Board_Racing\Godot_Board_Racing\godot-board-racing"
   foreach ($t in "holo_forge_dimension_test","holo_forge_theme_test","holo_forge_workspace_test","holo_forge_sketch_solver_test","holo_forge_sketch_tools_test","holo_forge_profile_test","holo_forge_document_test") {
     & $godot --headless --path $proj --script "res://tests/$t.gd"
   }
   ```

2. **In-editor hooks:** `& $godot --headless --path $proj --editor -- --holo-forge-sketch-editor-test`. Also run `--holo-forge-editor-test` and `--holo-forge-ui-editor-test`, so the marking menu and theme changes are covered.
3. **Visual check** (windowed; a scratch script, not in the project), as in P1-1. Capture these:
   - the fixture in light and dark at S = 1, plus one at S = 1.5;
   - the placing preview in all three orientations;
   - the value box on a new and on an existing dimension, with invalid text in red;
   - a hovered dimension with its tooltip;
   - a selected dimension;
   - a conflicting dimension;
   - the right-click menu with the check marks;
   - a Fully Define result.

   Compare against the checklist in 1b. Send the PNGs to the user if the orchestrator asks for them.
4. **Old documents:** open a document saved before the change that has legacy angle and zero-offset dimensions (build one with today's code first and keep a copy, or use the audit's probe output). Assert the same solved point coordinates (1e-12) and the same feature results, and confirm that the dimensions draw with the new look at their old text positions.
5. **Done when:**
   - every P1 item passes its tests and the visual checklist in both themes;
   - the P2 items are done, or each one the orchestrator skipped is listed;
   - no hard-coded colours remain in the dimension code (grep `Color(` in the new and changed dimension functions);
   - every string added to the project is our own wording;
   - nothing in the project names the other app.

---

## Appendix A: pure helpers for `core/sketch/dimension_layout.gd` (reference implementation)

```gdscript
@tool
extends RefCounted
## Pure geometry for sketch dimensions: what a dimension measures now, which linear orientation
## and which of the four angles the cursor asks for, where its lines, arrows and text go in the
## sketch plane, and the same on screen with fixed pixel sizes. No drawing, no solving.

const UNITS := preload("res://addons/holo_forge/core/units.gd")
const ANGLE_SNAP := 4.0  # degrees of hysteresis between orientation sectors

static var _literal := RegEx.create_from_string("^\\s*\\+?(\\d+\\.?\\d*|\\.\\d+)([eE][+-]?\\d+)?\\s*(mm|cm|m|in|ft|deg|rad|°)?\\s*$")


## A plain number with an optional unit (no names, operators or brackets).
static func is_literal(expression: String) -> bool:
	return _literal.search(expression) != null


## The number on the canvas: lengths in the document unit with 3 decimals, keeping at least 2
## ("40.00", "13.079"); angles in degrees with 1 decimal and "°".
static func canvas_number(value: float, kind: String, document_units: String) -> String:
	if kind == UNITS.KIND_ANGLE:
		return "%.1f°" % rad_to_deg(absf(value))
	var unit := UNITS.display_unit(UNITS.KIND_LENGTH, document_units)
	var text := "%.3f" % (absf(value) / float(UNITS.LENGTH_UNITS.get(unit, 1.0)))
	return text.substr(0, text.length() - 1) if text.ends_with("0") else text


## The full label: prefix (R, Ø), number, the expression marker, driven parentheses.
static func canvas_text(c: Dictionary, value: float, document_units: String, expression: String, marker: String) -> String:
	var text := canvas_number(value, str(c.get("kind", "length")), document_units)
	if c.type == "diameter" or c.get("linear_diameter", false):
		text = "Ø" + text
	elif c.type == "radius":
		text = "R" + text
	if not c.get("driving", true):
		return "(" + text + ")"
	if expression != "" and not is_literal(expression):
		text = marker + text   # marker = "ƒ " or "f "
	return text


static func _mod_pi_gap(a: float, b: float) -> float:
	var g := fposmod(a - b, PI)
	return minf(g, PI - g)


## "distance_x", "distance_y" or "aligned" for a pair of plane points and the cursor.
static func linear_orientation(pa: Vector2, pb: Vector2, place: Vector2, single_line: bool, lock := "", previous := "") -> String:
	if lock != "":
		return lock
	var d := pb - pa
	var length := d.length()
	var level := absf(d.y) <= length * 0.01
	var upright := absf(d.x) <= length * 0.01
	if level or upright:
		if single_line:
			return "aligned"
		return "distance_x" if level else "distance_y"
	var w := place - (pa + pb) * 0.5
	if w.length_squared() < 1e-24:
		return previous if previous != "" else "aligned"
	var axes := {"distance_x": PI * 0.5, "distance_y": 0.0, "aligned": fposmod(d.orthogonal().angle(), PI)}
	var theta := fposmod(w.angle(), PI)
	var best := ""
	var best_gap := INF
	for key in axes:
		var gap := _mod_pi_gap(theta, axes[key])
		if gap < best_gap:
			best_gap = gap
			best = key
	if axes.has(previous) and _mod_pi_gap(theta, axes[previous]) - best_gap < deg_to_rad(ANGLE_SNAP):
		return previous
	return best


## The sector (of four) at two lines' crossing that holds the cursor:
## {"order": [i, j] into [line a, line b] (counter-clockwise), "rays": [s_i, s_j] (+1 = p1->p2),
##  "value": the sector's angle in (0, PI), "vertex": Vector2}; {} for parallel lines.
static func angle_sector(a1: Vector2, a2: Vector2, b1: Vector2, b2: Vector2, place: Vector2) -> Dictionary:
	var da := (a2 - a1).normalized()
	var db := (b2 - b1).normalized()
	var vertex: Variant = Geometry2D.line_intersects_line(a1, da, b1, db)
	if vertex == null:
		return {}
	var w: Vector2 = place - (vertex as Vector2)
	if w.length_squared() < 1e-24:
		w = da + db
	var rays := [[0, 1, da], [0, -1, -da], [1, 1, db], [1, -1, -db]]
	var start: Array = []
	var start_gap := INF
	var finish: Array = []
	var finish_gap := INF
	for r in rays:
		var from_ray := fposmod((r[2] as Vector2).angle_to(w), TAU)   # w is this far CCW of the ray
		if from_ray < start_gap:
			start_gap = from_ray
			start = r
		var to_ray := fposmod(w.angle_to(r[2]), TAU)                   # the ray is this far CCW of w
		if to_ray < finish_gap:
			finish_gap = to_ray
			finish = r
	return {"order": [start[0], finish[0]], "rays": [start[1], finish[1]], "value": start_gap + finish_gap, "vertex": vertex}


## What the dimension measures in the geometry right now (meters or radians, positive).
## length |p2-p1|; distance as dimension_spec computes it (centres for round refs, perpendicular
## for a line ref, b.p1 to line a for two lines); distance_x |xb-xa|; distance_y |yb-ya|;
## radius r; diameter 2r; angle with rays: the CCW sweep from rays[0]*dir(refs[0]) to
## rays[1]*dir(refs[1]) in [0, TAU); legacy angle |da.angle_to(db)|.
static func measure(s: RefCounted, c: Dictionary) -> float:
	pass  # implement per the comment; reuse the formulas in sketch_editor.dimension_spec


## Plane-space layout (see section 1b.2). Returns one of:
## {"form": "linear", "a", "b", "foot_a", "foot_b", "text", "line_ext": [[from, to], ...]}
## {"form": "angle", "vertex", "rays": [Vector2, Vector2], "radius", "sweep", "text", "ray_ranges": [[t0, t1], [t0, t1]]}
## {"form": "radius" | "diameter", "center", "r", "u", "text", "inside": bool, "span": [a0, a1] or []}
static func plane_layout(s: RefCounted, c: Dictionary, anchor: Vector2) -> Dictionary:
	pass


## Screen-space primitives with the pixel metrics m ({"line", "arrow_len", "arrow_half", "ext_gap",
## "ext_over", "text_gap", "short", "tail", "landing", "pad", "default_offset"}, already times S):
## {"lines": [[a, b]], "polylines": [PackedVector2Array], "arrows": [{"tip", "dir"}],
##  "text": {"anchor", "angle", "align": "center"|"left"|"right", "baseline"},
##  "text_center": Vector2, "hit_poly": PackedVector2Array, "hit_segments": [[a, b]]}.
## to_screen: Callable(Vector2 plane) -> Vector2 (non-finite when behind the camera).
static func screen_layout(plane: Dictionary, to_screen: Callable, m: Dictionary, text_w: float, ascent: float, descent: float) -> Dictionary:
	pass


## Text angle that never reads upside down; vertical reads top to bottom.
static func upright(v: Vector2) -> float:
	var angle := atan2(v.y, v.x)
	if angle > PI * 0.5 + 1e-6:
		angle -= PI
	elif angle <= -PI * 0.5 + 1e-6:
		angle += PI
	return angle
```

### `sketch_solve._add` angle mapping (P1-4)

```gdscript
		"angle":
			if c.has("rays") and (c.rays as Array).size() == 2 and int(c.rays[0]) != int(c.rays[1]) and c.get("driving", true):
				value -= PI   # one ray reversed: the stored directions differ by the sweep minus PI
```

Put this before the generic `solver.add_constraint(type, mapped, value, driving)` call. Driven measurement in `solve()`, after `get_constraint_value`:

```gdscript
	for id in driven_tags:
		var v: float = solver.get_constraint_value(driven_tags[id])
		var c: Dictionary = sketch.constraint(id)
		if c.type == "angle" and c.has("rays"):
			v = fposmod(v + (PI if int(c.rays[0]) != int(c.rays[1]) else 0.0), TAU)
		result.measured[id] = v
```

### `_trial` (P1-7)

```gdscript
## Runs mutate(sketch) on a scratch copy of the document and solves the open sketch there; the
## real document, its counters, the undo history and the selection never change.
## Returns the solve result plus {"added": [new constraint ids], "param_error": String}.
func _trial(mutate: Callable) -> Dictionary:
	var scratch: Resource = DOCUMENT.new()
	scratch.restore(workspace.doc.snapshot())
	var feature: Resource = scratch.find_feature(feature_id)
	var live := SKETCH.new(feature, scratch)
	var before: Array = live.constraints().map(func(c: Dictionary) -> int: return int(c.id))
	mutate.call(live)
	var values: Dictionary = PARAMETERS.evaluate(scratch)
	var result: Dictionary = SOLVE.solve(live, values)
	result["added"] = live.constraints().map(func(c: Dictionary) -> int: return int(c.id)).filter(func(id: int) -> bool: return not before.has(id))
	result["param_error"] = ""
	for c in live.constraints():
		if c.has("key") and c.get("driving", true):
			var name := str(feature.inputs.get(c.key, {}).get("name", ""))
			if values.has(name) and not values[name].get("ok", false):
				result["param_error"] = "%s: %s" % [name, values[name].get("error", "")]
	return result


## True when the trial adds a conflict or redundancy the sketch didn't have.
func _over_constrains(trial: Dictionary) -> bool:
	var known := {}
	for id in state.get("solve", {}).get("conflicting", []) + state.get("solve", {}).get("redundant", []):
		known[int(id)] = true
	for id in (trial.conflicting as Array) + (trial.redundant as Array):
		if not known.has(int(id)) or (trial.added as Array).has(int(id)):
			return true
	return false
```

### Constraint fields (all optional; absent means today's behaviour)

| Field | On | Meaning | Item |
|---|---|---|---|
| `offset` (existing) | All dimensions | `T = _dimension_anchor(s, c) + offset` (plane metres) | Unchanged |
| `rays` | `angle` | `[s0, s1]`, ±1 per ref; refs in counter-clockwise order; the value is the positive sweep | P1-4 |
| `param_name` | Driven dimensions that were driving | The name to reuse when made driving again | P2-5 |
| `edge` | `distance` with round refs | Per-ref bool: measure to the curve instead of the centre | P3-1 |
| `linear_diameter` | `distance`, `distance_x`, `distance_y` | Shows and holds twice the distance | P3-3 |

Document this list in the header comment of `core/sketch/sketch_data.gd`, next to the existing `Constraints: {id, type, refs, key, driving, offset}` line.
