# Holo Forge

Parametric CAD inside the Godot editor. Holo Forge adds a **Forge** tab next to 2D / 3D / Script. In it you can sketch with constraints and dimensions, model solids and surfaces, sculpt subdivision forms, edit meshes and build jointed assemblies. Your parts are then used in the game as ordinary baked meshes.

- **Real CAD kernel:** OpenCASCADE 8.0.1 for solids, and the planegcs constraint solver for sketches.
- **Tools:**
  - Sketch;
  - Solid (Extrude, Revolve, Sweep, Loft, Fillet, Shell, patterns, Hole, Thread...);
  - Construct, Inspect, Insert (SVG, DXF, STEP, IGES, meshes, decals, canvases);
  - Surface;
  - Form (subdivision);
  - Mesh;
  - Assemble (joints, limits, motion links, contact, motion studies).
- **Appearances:** textures and appearances on bodies and faces.
- **Baked output:** every body bakes as its own `MeshInstance3D`, and every component as its own node. Collision and Godot joints are optional.
- **Export:** STEP, IGES, STL, OBJ, 3MF, GLB and `.tscn`.

## Requirements

- Godot **4.7** or newer, **Windows 64-bit** editor. This release has no macOS or Linux build.
- The CAD kernel runs **in the editor only**. A game you export uses the baked meshes and never loads the kernel, so exports stay small and work on every platform Godot supports.
- Baked assembly joints are tuned for **Jolt Physics** (**Project Settings > Physics > 3D > Physics Engine**). With Godot Physics they still bake, but Holo Forge warns that joints fixed to the world may turn the other way.

## Install

**With the installer (easiest):**

1. Close Godot.
2. Run `holo_forge-<version>-windows-setup.exe`. Windows may say "Windows protected your PC", because the installer isn't code-signed: click **More info > Run anyway**.
3. Pick your project's folder (the one with `project.godot`) and your Godot editor program (4.7 or newer).
4. Setup copies the addon into `addons/holo_forge`, imports the project, turns the plugin on and runs a quick self-test. An older Holo Forge in the project is moved to `holo_forge_backup/` first.
5. Open the project: a **Forge** tab appears at the top of the editor.

**From the zip (any project):**

1. Close the project in Godot if it is open.
2. Unzip `holo_forge-<version>-windows.zip` into your project's folder. You should end up with `<your project>/addons/holo_forge/plugin.cfg`.
   - Or, in Godot: **AssetLib** tab > **Import...** > pick the zip > **Install**.
3. Open the project. Godot imports the icons and loads the kernel library (the first import takes a few seconds).
4. **Project > Project Settings > Plugins**: tick **Holo Forge**.
5. A **Forge** tab appears at the top of the editor.

**To update:** run the new installer, or close Godot, delete `addons/holo_forge`, unzip the new version, and open the project again. Your parts are kept: they live in your scenes and in the `<scene>_forge` folders next to them.

**Check an install:** **Project > Tools > Holo Forge: Run Self-Test** sketches, extrudes, fillets and bakes a small part and shows what passed. If something fails, post the report in #bug-reports on the Holo Forge Discord.

## First part

1. Open or make a 3D scene, then add a **CadPart** node (Add Child Node > CadPart).
2. Select it and open the **Forge** tab.
3. **Create Sketch**: click a plane, draw a rectangle (R), add dimensions (D), then click **Finish Sketch**.
4. **Extrude** (E): pick the profile, type a distance, then press OK.
5. Save the scene. The part bakes into your scene as a `MeshInstance3D` for each body, which the game uses as it is.

Press **S** in the Forge tab to search every command by name.

## Settings

**Project Settings > Holo Forge > Export > Board Models Folder** is the folder that **Save Board Model Version** saves versioned models into. Leave it empty if you don't use that command.

## Appearances

The Appearance library starts with 11 built-in finishes: plastics, paints, metals, rubber, glass and carbon. To add your own texture sets, put each one in its own folder under `res://materials/material_library/<Set Name>/`. Holo Forge recognises the usual map names: Color/BaseColor/albedo, Normal/NRM, Roughness, Metallic/Metalness, AO and Gloss. You can also drag any Godot `Material` onto a body.

## Files it writes

- **Your scene (`.tscn`):** the part's design, plus small references to its baked meshes.
- **`<scene>_forge/` next to the scene:** the baked meshes (`.res`) and large stored meshes. Keep this folder with the scene, and commit it to version control.
- **`addons/holo_forge/bin/~holo_forge_native.dll`:** Godot's working copy of the kernel library while the editor is open. It is safe to delete once Godot is closed. Add `~*.dll` to your `.gitignore`.

## Licenses

Holo Forge itself: see `LICENSE.md`. The libraries it ships are under their own licenses: see `THIRD_PARTY_NOTICES.md` and the `licenses/` folder. OpenCASCADE and planegcs are LGPL. They are separate DLLs in `bin/`, and you may replace them with your own builds.
