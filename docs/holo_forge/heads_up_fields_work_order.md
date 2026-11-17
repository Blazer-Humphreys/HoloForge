# Work order: heads-up length and angle fields while drawing (Line first)

For an AI implementer. Holo Forge sketch mode, Godot 4.7.1, GDScript addon at `addons/holo_forge`. Read `ui/sketch_editor.gd` (tool engine, `_draw_tool`, `_draw_dimension`, `_layout_for`, the value box `_edit` and its `_style_edit`) and `core/sketch/dimension_layout.gd` first. Same ground rules as the dimension work order (`dimension_spec.md`, section 0): theme tokens only, one undo step per action, tests never save scenes, call the reference CAD app "the other app", own wording only.

## Goal

While the Line tool has its first point placed, show two temporary dimensions on the rubber band and let the user type them:

1. **Length**: an aligned dimension along the rubber band, text 24 px to its left side (plane-up for level lines).
2. **Angle**: from the previous segment of the chain (or plane +X for the first segment) to the rubber band, drawn as an angle arc at the start point in the sector the band sweeps.

## Behaviour

- Both are drawn in the `preview` state (`DIM_STATE_COLORS.preview`) with their measured values, every mouse move. Nothing is stored.
- Typing a digit (or `-`, `.`) while the Line tool has a first point opens an inline field on the **length** dimension (reuse the `_edit` LineEdit styling, but a second LineEdit, `_heads_up`, so the dimension value box keeps its own lifetime). Tab moves to the **angle** field and back; the active field has the `dim_box_focus` frame.
- Enter in a field **locks** its value: the rubber band then keeps that length (or angle) while the mouse sets the rest. A locked field shows its value in `dim_selected`.
- The click (or Enter with both locked) that places the end point adds the segment as usual (one undo step `Sketch: Line`) **plus** a driving `length` dimension for a locked length and a driving `angle` (with rays, as `_angle_spec` builds them) for a locked angle, in the **same** step. Their text goes where the heads-up dimensions were drawn.
- Esc with a field open closes the field (no lock); Esc again ends the chain as today.
- Invalid text (same rules as `_validate`) turns the field `dim_box_invalid` and Enter is refused.

## Implementation notes

- The pseudo-dimensions need entities: build them on the scratch copy `_preview()` already makes (`SKETCH.new(real.feature.copy(), null)` plus the rubber-band line from `_build`), then call `_draw_dimension(overlay, scratch, pseudo, text, "preview")`. `holo_forge_dimension_test._check_small_items` already proves `_layout_for(scratch, {"type": "length", "refs": [band], ...})` lays out (this pass checked it).
- Locked values change the mouse point: length lock `p = start + (mouse - start).normalized() * L`; angle lock `p = start + dir(angle) * |mouse - start|`; both locked: fully determined.
- Add the dimensions inside the same `workspace.change` as the segment (extend `_commit_tool` for `line` with the locks), through `_add_dimension(sketch, spec, expression, true)`.
- Then rectangles (two lengths) and circles (diameter) the same way, as a follow-up. **Done 2026-11-11** (`HEADS_UP_TOOLS` in `sketch_editor.gd`): 2-point and centre rectangles show width and height (driving `distance_x`/`distance_y` on the edges through the moving corner); the 3-point rectangle shows its first edge's length, then its height (driving `length` on its first two edges; the width lock carries into the height step); centre and 2-point circles show a diameter (driving `diameter`). The 3-point circle has no single size to type, so it has no fields. Tests: `holo_forge_heads_up_test.gd` (real input) and `_check_heads_up_shapes` in the in-editor test.

## Tests

- Headless (`tests/holo_forge_dimension_test.gd`): after the first Line click and a mouse move, the draw log has two preview entries (length and angle) with the measured values; typing `40` + Enter, then a click elsewhere, makes a 40 mm line with a driving length dimension in one `Sketch: Line` step; Tab, `30`, Enter locks the angle and the second segment is 30° from the first; invalid text is refused.
- In-editor (`--holo-forge-sketch-editor-test`): the field takes real key events and focus returns to the view after the segment.
