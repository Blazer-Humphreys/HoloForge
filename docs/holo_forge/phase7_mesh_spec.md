# Holo Forge Phase 7: the Mesh workspace (triangle mesh bodies)

**Revised 2026-11-11 after the library spike.** The measured answers in 8.1a are folded into the body. Read the body top to bottom; 8.1a is only the evidence record.

Work order for executing AI agents. You get only this document, the approved plan (`C:\Users\Blaze\.claude\plans\can-we-create-a-idempotent-shannon.md`, section "Phase 7" and the Mesh rows of the tool matrix) and the code. Everything the teams must agree on is written as a **contract** (C1 to C8). Do not change a contract on your own. If one cannot work, stop and report it with a concrete counter-proposal.

Written 2026-11-11 from:
- an audit of the Holo Forge code after Phase 6, regression round 3;
- the installed vcpkg headers, CMake configs and DLL exports of pmp-library, Manifold and meshoptimizer;
- the Phase 6 lessons (bounded ops, dense post-checks, ratio timing, real input in UI tests);
- a library spike (8.1a) that built a scratch program against the installed libraries and measured the open library questions and the library call times.

No Phase 7 code exists yet. Numbers marked **measured** come from the spike: library calls only, on the dev machine, single thread, one run, ±15%. Every other timing number is a **target to measure**. Section 8.1 lists what is still unverified.

---

## 0. Ground rules (read first)

### 0.1 Paths and names (the plan's names are out of date)

The plan says `holo_cad`, a "CAD" tab and `holo_cad_mesh_test`. The real names are:

| What | Path / name |
|---|---|
| Addon root (**A**) | `D:\Hover_Board_Racing\Godot_Board_Racing\godot-board-racing\addons\holo_forge` (main-screen tab "Forge") |
| Native root (**N**) | `D:\Hover_Board_Racing\Godot_Board_Racing\holo_forge_native` (CMakeLists.txt, vcpkg.json, src/) |
| Build tree | `C:\Users\Blaze\holo_forge_build\build` (Visual Studio 17 2022 generator, vcpkg toolchain, `VCPKG_INSTALLED_DIR = C:/Users/Blaze/holo_forge_build/vcpkg_installed`) |
| vcpkg packages (**V**) | `C:\Users\Blaze\holo_forge_build\vcpkg_installed\x64-windows-release` (dynamic triplet). Already installed and listed in `N\vcpkg.json`, **not linked yet**: pmp-library, manifold, meshoptimizer. |
| Tests | `D:\Hover_Board_Racing\Godot_Board_Racing\godot-board-racing\tests\holo_forge_*_test.gd` |
| Godot | `D:\Hover_Board_Racing\Godot_Board_Racing\Godot_v4.7.1-stable_win64.exe\Godot_v4.7.1-stable_win64_console.exe` |
| New native class | `CadMesh` (files `N\src\cad_mesh.h`, `N\src\cad_mesh.cpp`, plus `N\src\mesh_*.cpp/.h`, see 4) |
| New GDScript | `A\core\mesh\*.gd`, `A\core\features\mesh.gd`, `A\ui\mesh_*.gd`, `A\tools\mesh_*.gd` |
| New headless acceptance test | `tests/holo_forge_mesh_test.gd` |
| New editor hook | `--holo-forge-mesh-editor-test`, running `tests/holo_forge_mesh_editor_test.gd` |

Line numbers in this document are hints only. Find code by **function name**.

### 0.2 Code rules (existing conventions, mandatory)

- **Class cache.** Every addon script starts with `@tool` and has **no** `class_name`. Other scripts are reached only through `const X := preload("res://addons/holo_forge/...")`.
- **Native classes.** Reach them only through `ClassDB.class_exists("CadMesh")` and `ClassDB.instantiate("CadMesh")`. Hold them in variables typed `RefCounted`. Never write `CadMesh.new()` or `: CadMesh`. Every script must still parse when the DLL is missing.
- **Editor-only calls.** Guard every `EditorInterface` call with `Engine.is_editor_hint()`. The headless tests build `WORKSPACE.new()` without an editor.
- **Packed arrays in Dictionaries are values.** After you change a Packed array read from a Dictionary, write it back.
- **Resources in Dictionaries are shared by `duplicate(true)`.** In Godot 4.7.1 `Dictionary.duplicate(true)` copies nested Dictionaries and Arrays but **shares** every Resource value, at any depth (measured, 8.1a). `duplicate_deep(Resource.DEEP_DUPLICATE_INTERNAL)` and `DEEP_DUPLICATE_ALL` copy the Resources. `DEEP_DUPLICATE_NONE` shares them. Undo relies on the sharing (2.2.4).
- **Units.** Mesh positions are in **meters**, in the part's space, like every kernel value. Panel fields show document units through the existing expression fields.
- **Precision.** Godot `Vector3` is float32 in this build. Mesh positions are float32 on purpose (C1). Never round-trip B-rep data through `Vector3` when doubles exist.
- **Winding.** Native code and the stored blob use **counter-clockwise seen from outside** (Manifold's rule). Godot draws **clockwise** front faces. `CadMesh.tessellate()` and `get_arrays()` return Godot order, the same as `CadShape.tessellate()`. `set_arrays()` takes a `winding` argument. Only these three functions flip.

### 0.3 Originality and branding

- Behaviour may match the other app. Never copy its text, icons, art or help wording.
- In anything that goes into the project (code, comments, UI strings, tests, docs, commit messages), call it only "the other app". Strip URLs that contain its brand name.
- Tool names in the catalog ("Plane Cut", "Erase and Fill", "Convert Mesh: Prismatic") are plain CAD words. Keep them. Write every tooltip, hint and message yourself.
- Icons: the existing original Holo SVGs in `A\icons\tools\<slug>.svg` cover every Mesh tool. Four new icons are listed in 6.3. Draw them yourself in the house style. Do not trace or redraw any icon from the other app.

### 0.4 Machine rules

- **Disk.** Build trees stay on C:. Never put build output on D:.
- **DLL lock.** The GDExtension has `reloadable=false`. Close every Godot instance **you started** before building. Never kill a Godot process you did not start: the user's editor is often open. If the user's editor holds the DLL, stop and report.
- **Build:** `& "C:\Program Files\CMake\bin\cmake.exe" --build "C:\Users\Blaze\holo_forge_build\build" --config Release --parallel`. The POST_BUILD step copies `$<TARGET_RUNTIME_DLLS:holo_forge_native>` into `A\bin`, so new DLLs (pmp.dll, manifold.dll, meshoptimizer.dll) land there by themselves.
- **Reconfigure** (needed once after the CMakeLists change): `& "C:\Program Files\CMake\bin\cmake.exe" -S D:\Hover_Board_Racing\Godot_Board_Racing\holo_forge_native -B C:\Users\Blaze\holo_forge_build\build`. The cache keeps the toolchain and the installed dir.
- **Do not run `.ps1` files with `-ExecutionPolicy Bypass`.** Call cmake and Godot directly.
- **Leftovers.** Delete `~*.dll~RF*.TMP` files in `A\bin` when you see them.
- **Headless test:** `& $godot --headless --path D:\Hover_Board_Racing\Godot_Board_Racing\godot-board-racing --script res://tests/<name>.gd`
- **Editor hook:** `& $godot --headless --path <project> --editor -- --holo-forge-mesh-editor-test`. One hook per process.
- **Scenes.** Don't modify the user's scenes. New test scenes go under `tests/holo_forge/`. Generated fixtures go to `user://holo_forge_mesh_fixtures/`, never into the repo (5.0).
- **Regression.** `tests/validate_project.gd` must show no violations beyond the 6 known Movement Lab ones. Every pre-existing Holo Forge test and hook must still pass.
- **Run commands yourself.** Never hand the user commands to run.
- **Grep every output** for `SCRIPT ERROR`, `Parse Error`, `signal 11` and `ERROR:` before you call a run green.

### 0.5 Phase 6 lessons (mandatory rules for every op)

1. **Every op is bounded in time.** No call may run longer than its budget plus 1 s. See C5.
2. **No silent wrong results.** An op either returns a result that passed its post-checks, or a result with a warning that names what is off and by how much, or nothing with an error. Never a wrong result with no message. Each tool's section says which outcome applies to which failed check.
3. **Dense post-checks.** Checks sample the whole result, not one point. See C5.3.
4. **Ratio timing.** Timing tests use `tests/holo_forge_timing.gd compare` against a calibration, never raw milliseconds (5.7).
5. **Real input for UI.** Reproduce UI behaviour with `root.push_input` events. Direct tool calls miss real input bugs.
6. **Refusals are fast and true.** A refusal comes before the expensive work when it can be predicted, and its text says what to change.

---

## 1. Target behaviour (our own words) and deliberate differences

### 1.1 What the user gets

- A **mesh body** is a new kind of body: a triangle mesh with **face groups**. It lives in the same browser, timeline, viewport, bake and export as B-rep bodies.
- The **Mesh workspace** (already in the switcher, tools greyed out) becomes live. Its groups are Create, Prepare, Modify, plus the shared Assemble, Construct, Inspect, Insert and Select groups.
- Mesh tools work only on mesh bodies. Solid and Surface tools refuse mesh bodies with one clear sentence and point to **Convert Mesh**.
- Every Mesh tool except Direct Edit is a **timeline feature**. Editing an earlier feature replays the mesh tools after it.
- **Convert Mesh** turns a mesh body into a B-rep body in three ways: Faceted (one flat face per triangle or per flat group), Prismatic (planes and cylinders fitted per group) and Organic (experimental, through a Form cage).
- **Tessellate** goes the other way: B-rep body to mesh body, one face group per B-rep face.

### 1.2 Deliberate differences from the other app (keep them; tests rely on them)

| Topic | Holo Forge Phase 7 |
|---|---|
| Direct Edit | It is stored as a **snapshot** feature (like a Base Feature). Changes made earlier in the timeline to that body stop flowing through it. The feature warns about this. |
| Insert Mesh from Solid > Insert | Keeps today's behaviour (a faceted B-rep) when the workspace is not Mesh. The panel gains a **Body Type** choice. Old documents keep their B-rep bodies. |
| Triangle cap | 2,000,000 triangles per mesh body. Larger inputs are refused at once. |
| Slow tools on big bodies | Reduce (Adaptive), Remesh and whole-body Smooth cannot finish a 2,000,000-triangle body in 20 s. They refuse up front above a few hundred thousand triangles, with a sentence that says what to do (2.6.2). Reduce (Fast), Combine and Plane Cut work up to the cap. |
| Faceted convert cap | 60,000 triangles (today's `MAX_TRIANGLES` in `exchange::mesh_shape` and `insert.gd`). |
| Quads and n-gons | Not stored. Mesh bodies are triangles only. OBJ polygons are triangulated on read (fan for convex, ear clipping otherwise). |
| Vertex colours, UVs, normals | Not stored. Display normals are computed. Face groups are the only per-triangle data. |
| Organic convert | Experimental, capped at 5,000 cage faces. It may refuse. |
| Preview | Tools preview only when the op fits the 0.5 s preview budget. Otherwise the panel says "Preview skipped (too slow); press OK to compute". |
| Booleans with solids | Mesh Combine accepts B-rep tool bodies by tessellating them (with a warning). It never takes a B-rep target. |
| Edges | Mesh bodies have no B-rep edges. Group borders and open boundaries are drawn as lines but are not pickable edges in Phase 7. |

---

## 2. Architecture and contracts

### 2.1 Overview

```
Mesh tool panel (tools/feature_command.gd + mesh specs)
        |  options + picks
        v
core/features/mesh.gd  (feature type "mesh", options.method)
        |  input CadMesh(es) from ctx.bodies, LRU cache by content digest
        v
CadMesh (native, RefCounted, immutable after construction)
   |-- own code: IO, check, BVH, ray/region select, section, voxel SDF, fit
   |-- pmp-library 3.0 (pmp.dll): remesh, decimate, fair, smoothing, features
   |-- meshoptimizer 1.3 (meshoptimizer.dll): fast simplify
   |-- Manifold 3.5.4 (manifold.dll): booleans, plane split, level set, decompose
   '-- OCCT 8.0.1 (existing): tessellate B-rep, faceted/prismatic convert
        |
        v  new CadMesh  (or null + get_last_error())
ctx.bodies[id] = {"id", "shape": CadMesh, "feature", "kind": "mesh"}
        |
        v
forge_workspace.recompute -> CadMesh.tessellate() -> forge_viewport / cad_part bake / export
```

Key choices:
- The **stored form** is plain indexed arrays (C1). A pmp `SurfaceMesh` cannot hold non-manifold input, so library meshes are built per op and thrown away.
- A `CadMesh` is **immutable**. Every op returns a new instance. This makes caching, undo and preview safe.
- A mesh body uses the **same body entry shape** as a B-rep body, plus `"kind": "mesh"`. `CadMesh` answers the read-only subset of `CadShape` that display, pick, bake, measure and export need (C2.2).

### 2.2 C1: mesh data (triangles, face groups, binary storage)

#### 2.2.1 In memory (native)

```
struct MeshData {
    std::vector<float>    positions;   // 3V, meters, part space
    std::vector<uint32_t> triangles;   // 3T, CCW seen from outside
    std::vector<uint32_t> groups;      // T, group id per triangle, < G
    std::vector<std::string> group_names; // G, unique, 1..64 UTF-8 bytes
};
```

Rules:
- V ≤ 2,000,000 and T ≤ 2,000,000 (`MAX_TRIANGLES_MESH`). G ≤ 100,000.
- Every index is < V. Every group id is < G. Every position is finite. `set_arrays` and `from_blob` reject anything else with an error.
- Degenerate and duplicate triangles **are allowed** in storage (imports have them). `check()` counts them. Ops that need clean input say so in their own checks.
- Unused vertices are allowed in storage. Every op output is compacted (no unused vertices).
- An empty group (no triangles) is dropped on output, and the remaining ids are renumbered in order.

#### 2.2.2 Face group names (references depend on them)

- Names must be stable across rebuilds when the input is the same.
- **Tessellate** uses the B-rep face names (`get_face_names()`), so a reference made before Tessellate can still be followed.
- **Insert Mesh** names one group `g0`, or one per OBJ `o`/`g` statement or 3MF object (`g0`, `g1`, ... in file order; the file's own name goes in the browser label only).
- **Generate Face Groups** names groups `g0..gN` ordered by each group's smallest triangle index. Same input gives the same names.
- **Ops that keep groups** keep the names. New groups made by an op are named `<method><k>` (`cut0`, `fill0`, `wrap0`).
- The UI label is "Face Group <n>" where n = index + 1. The name is the stored identity.

#### 2.2.3 Binary blob "HFM1" (little endian, uncompressed form)

| Offset | Type | Content |
|---|---|---|
| 0 | 4 bytes | ASCII `HFM1` |
| 4 | u32 | version = 1 |
| 8 | u32 | flags = 0 (reserved; readers reject unknown bits) |
| 12 | u32 | V |
| 16 | u32 | T |
| 20 | u32 | G |
| 24 | f32 × 3V | positions |
| … | u32 × 3T | triangles (CCW) |
| … | u32 × T | group ids |
| … | G records | u16 byte length, then UTF-8 name bytes |
| end − 4 | u32 | CRC-32 (IEEE 802.3) of every byte before it |

- `CadMesh.to_blob()` writes it. `CadMesh.from_blob(bytes)` reads it and checks the magic, version, flags, sizes (the byte count must match exactly) and CRC. On any mismatch it returns false with an error that says which check failed.
- Compression happens in GDScript: `blob.compress(FileAccess.COMPRESSION_ZSTD)` and `data.decompress(size, FileAccess.COMPRESSION_ZSTD)`.

#### 2.2.4 `A\core\mesh\mesh_blob.gd` (a Resource, no `class_name`)

```gdscript
@tool
extends Resource
@export var format := "HFM1"
@export var digest := ""        # SHA-256 hex of the UNCOMPRESSED blob (HashingContext)
@export var size := 0           # uncompressed byte count
@export var vertices := 0
@export var triangles := 0
@export var data := PackedByteArray()   # zstd-compressed HFM1 bytes
static func from_mesh(mesh: RefCounted) -> Resource   # CadMesh -> blob
func to_mesh() -> RefCounted                          # blob -> new CadMesh, or null (error in last_error)
var last_error := ""
```

- A MeshBlob is **immutable** once made. Never change `data` in place. Make a new one.
- Feature options hold it under the key `"mesh"`: `feature.options.mesh = MeshBlob`.
- **Saving:** small blobs (compressed `data` ≤ 256 KB) stay embedded in the scene as a sub-resource. Text scenes use `format=4`, which stores PackedByteArray as base64 (checked in project .tscn files).
- **Sidecar files:** a new `cad_part.gd externalize_mesh_blobs()` runs next to `externalize_meshes()` (the plugin calls both before save). It saves each larger blob with `ResourceSaver.save(blob, path, ResourceSaver.FLAG_COMPRESS)` to `<scene>_forge/<part>_mesh_<digest first 16>.res` and calls `take_over_path`. The name comes from the content, so saving twice writes nothing new, and undo states that share a blob share the file.
- **Load check:** `to_mesh()` checks the SHA-256 digest before decoding. A mismatch is an error on the feature: "The stored mesh of <Feature> is damaged (checksum mismatch)."
- **Undo:** `document.snapshot()` uses `options.duplicate(true)`. That call **shares** Resource values (0.2; measured in Godot 4.7.1 for blobs at the top level, nested in Dictionaries, inside Arrays, built in memory and loaded from a `.res`). So every undo snapshot holds the same MeshBlob instance and undo costs no blob memory. Sharing is safe because blobs are immutable. Keep `duplicate(true)`. Never switch `snapshot()` to `duplicate_deep(Resource.DEEP_DUPLICATE_INTERNAL)` or `DEEP_DUPLICATE_ALL`: they copy every blob on every snapshot. Stage G1 asserts the sharing with `is_same` in the gate test (5.6 #6).

#### 2.2.5 Which features store a blob

| Feature | Stores a blob? |
|---|---|
| Insert Mesh, Body Type Mesh, not linked | Yes: the mesh read from the file, already in meters and placed. |
| Insert Mesh, linked | No: the file is read on every rebuild, through the cache. |
| Direct Edit | Yes: the edited result (the snapshot). |
| Every other Mesh feature | No: it is recomputed from its inputs. |

### 2.3 C2: mesh body entries, the CadShape subset and the gate

#### 2.3.1 Body entry

`ctx.bodies[id] = {"id": String, "shape": CadMesh, "feature": String, "kind": "mesh"}`.
- B-rep entries have no `"kind"` key. Read it with `entry.get("kind", "brep")`.
- New helper in `A\core\mesh\mesh_body.gd`: `static func is_mesh(entry_or_shape) -> bool`. It accepts either an entry Dictionary or a shape (`shape.has_method("is_mesh") and shape.is_mesh()`). Use it everywhere. Never test the class name as a string.

#### 2.3.2 The `CadShape` subset `CadMesh` must answer

These are the calls that display, pick, bake, measure and export make on `entry.shape` today (from the call-site audit). Same names, same argument lists, same return types:

| Method | CadMesh meaning |
|---|---|
| `is_null() -> bool` | true when T == 0 |
| `shape_type() -> String` | `"MESH"` |
| `bbox() -> AABB` | exact bounds of the used vertices |
| `tessellate(linear, angular) -> Dictionary` | the stored triangles; arguments ignored (C6.1) |
| `volume() -> float` | signed divergence sum in doubles; 0.0 when not closed |
| `area() -> float` | sum of triangle areas |
| `center_of_mass() -> Vector3` | volume centroid when closed, area centroid otherwise |
| `mass_properties(density = 1000.0) -> Dictionary` | keys `volume, area, mass, center, inertia, principal_moments`, like CadShape; solid integrals when closed, else thin-shell with `volume` 0 and a `"warning"` key |
| `face_count() -> int` | G (groups are the faces) |
| `get_face_names() -> PackedStringArray` | group names |
| `find_face(name) -> int` | group index or -1 |
| `face_info(i) -> Dictionary` | keys `type` (`"plane"` when the group is flat within 1e-6 × bbox diagonal, else `"mesh_group"`), `planar`, `point` (area centroid), `area`, `normal` (area-weighted, unit), `edges` (empty), `triangles` (count) |
| `face_normal_at(i, point) -> Vector3` | normal of the group triangle nearest to `point` |
| `edge_count() -> int` | 0 |
| `get_edge_names() -> PackedStringArray` | empty |
| `edge_info(i) -> Dictionary` | empty |
| `vertex_count() -> int` | V |
| `is_surface() -> bool` | true when not closed (any boundary or non-manifold edge) |
| `solid_count() -> int` | number of closed, consistently oriented connected components that are **not voids** (the nesting rule, 2.6.3). A hollow cube answers 1, not 2 |
| `copy() -> RefCounted` | the same instance (immutable), so callers that copy before change still work |

Plus `is_mesh() -> bool` (true). Everything else on CadShape (`face_shape`, `edge_shape`, `solids`, `to_brep_bytes`, `surface_curvatures`, `face_uv_metric`, `face_isocurves`, ...) is **not** on CadMesh. The gate below must stop every caller before it reaches one of them. A missing method must never be the error path, because Godot prints a script error.

#### 2.3.3 The gate (one sentence, one place)

- New constant in `A\core\features\util.gd`: `const MESH_GATE := "%s is a mesh body. Convert it first (Mesh > Modify > Convert Mesh)."` where `%s` is the body name.
- New `static func mesh_gate(doc, entries: Array) -> String`. It returns "" when no entry is a mesh, else the gate text for the first mesh entry.
- Call it in these Reader paths, **before** any CadShape-only call: `bodies_of`, `_checked`, `faces_or_bodies`, `tool_shape`, `model_size`, `replace`. Call it also in `core/references.gd` (face and edge refs on mesh bodies from B-rep features) and in `core/operations.gd` (join/cut/intersect targets).
- Callers that **accept** mesh bodies pass `allow_mesh := true`. That is only: `core/features/mesh.gd`; `modify.gd` `move` (Move/Copy), `remove`; the Delete action; appearance by body; Inspect `measure`, `center_of_mass`, `interference`, zebra, draft, accessibility (tess-based); Section Analysis (through `CadMesh.section`); export (C6.4); bake.
- **Pick time:** in the viewport filter, a selection field whose `filter` has no mesh kind (`"mesh_body"`, `"mesh_group"`, `"mesh_triangles"`) cannot pick a mesh body. The click flashes the gate text instead. The build-time gate still runs, for old documents and scripted features.
- `analysis.gd`: curvature map, minimum radius, isocurve and curvature comb refuse mesh bodies with "Not available on mesh bodies. Convert the body first." Section uses `CadMesh.section` for mesh bodies (C4.3).
- `appearance.gd` `face_uv_metric` and `placed_decal`: decals refuse mesh bodies with "Decals need a B-rep face. Convert the body first." Per-face appearances work through group names. Test both.

### 2.4 C3: features, timeline, regen, cache, undo, save and load

#### 2.4.1 Feature type `"mesh"`

- Type `"mesh"`, method in `options.method` (the Phase 5 Surface pattern). Spec keys in `tools/feature_specs.gd` are `"mesh:<method>"`.
- `core/regen.gd HANDLERS` gains `"mesh": MESH` with `const MESH := preload("res://addons/holo_forge/core/features/mesh.gd")`.
- Handler signature, like every other: `static func build(feature: Resource, ctx: Dictionary) -> String` (returns the error, "" on success). Warnings go through the existing `_warn` pattern into `ctx.warnings[feature.id]`.
- When `ClassDB.class_exists("CadMesh")` is false, `build` returns "The Holo Forge mesh kernel is not loaded".
- `ui/timeline.gd ICONS` gains one entry per `"mesh:<method>"` key (the key is `type:method`). Use the tool's own SVG from `icons/tools/`.

Methods (one per tool; 3 gives each tool's options):

```
tessellate, close_holes, stitch_remove, wrap, rebuild, generate_groups, combine_groups,
create_group, direct_edit, remesh, reduce, plane_cut, shell, combine, smooth, reverse_normal,
erase_fill, align, texture_extrude, separate, move, scale, section_sketch (makes a sketch),
convert_faceted, convert_prismatic, convert_organic
```

#### 2.4.2 Insert Mesh: the `kind` option

- `mesh_import` stays handled by `core/features/insert.gd`. It gains `options.kind`: `"mesh"` or `"solid"`. **A missing key means `"solid"`**, so old documents build exactly as before.
- `kind == "solid"`: today's path, unchanged (`add_mesh_import`, `kernel.mesh_to_shape`, 60,000 triangle cap).
- `kind == "mesh"`: builds a `CadMesh`. Not linked: from `options.mesh` (the MeshBlob). Linked: from the file, through the cache. The old `positions`/`indices` keys are not written for `kind == "mesh"`.
- The panel (`feature_specs.gd` spec `"mesh_import"`) gains `choice("kind", "Body Type", [["mesh", "Mesh Body"], ["solid", "Solid (faceted)"]], "solid")`, with `"unset": "solid"`. Mesh > Create > Insert Mesh starts the same command with `kind = "mesh"`. Solid > Insert > Insert Mesh keeps `"solid"` as its default.

#### 2.4.3 Inputs, outputs and body ownership

- **Modify-style methods** (most) take `options.bodies` (body ids, filter `"mesh_body"`) and replace each body's entry in place: same id, new CadMesh, `feature` set to this feature. This matches how `modify.gd` replaces B-rep bodies.
- **Create-style methods** (`tessellate`, `separate`, `plane_cut` with Split Body, `combine` with New Body, `convert_*` with New Body) add bodies with `doc.new_body(feature.id)` on first build and keep the ids in `options.outputs` (Array of ids) so rebuilds reuse them. When a rebuild makes fewer bodies than before, the extra ids get no entry and the feature warns "<Feature> now makes <n> bodies instead of <m>."
- **Group picks** are `{"body": id, "group": name}`. **Triangle picks** are `{"body": id, "triangles": PackedInt32Array, "digest": <input CadMesh digest>}`. If the input digest differs on rebuild, the feature keeps the ids that are still in range and warns "<Feature>: the triangle selection was made on an older version of <Body>; it may now cover other triangles. Reselect to be sure." Ids out of range are dropped and counted in the warning.

#### 2.4.4 Cache

- `core/features/mesh.gd` keeps a content-keyed LRU of results. The key is `method + "|" + JSON of options (minus picks that hold triangles, which are hashed) + "|" + input digests`. `CadMesh.digest()` is a fast 64-bit hash (C4.2).
- Budget: **512 MB** of cached result bytes (sum of `CadMesh.memory_bytes()`), and at most 32 entries. Evict the least recently used.
- Refusals are cached too (the error text), like the Phase 6 shell refusals, so an impossible op does not cost 20 s on every rebuild.
- `static func clear_cache()`, as in `form.gd`. Tests call it.

#### 2.4.5 Undo, preview and save

- Every Mesh tool's OK is one undo step named `"Mesh: <Title>"`. It goes through the existing feature command path.
- Preview runs the feature with `time_limit = PREVIEW_SECONDS` (0.5). OK runs it with `OK_SECONDS` (20). Both are constants in `core/features/mesh.gd`. See C5.
- The bake (`cad_part.apply_result`) uses `CadMesh.tessellate()` like any body. `externalize_meshes()` already saves baked meshes as sidecars. `externalize_mesh_blobs()` (2.2.4) saves the large blobs.

### 2.5 C4: the native class `CadMesh`

`class CadMesh : public RefCounted`, registered with `GDREGISTER_CLASS(CadMesh)` in `register_types.cpp`. It follows the `CadSubD` pattern: state in a `std::unique_ptr<mesh::State>`, an empty value on failure, and `get_last_error()`, `get_last_warning()`, `get_last_report()`.

**Error contract.** Every method that can fail:
- sets `last_error` (one sentence for the user) on failure and returns `false`, `null` or an empty value;
- sets `last_warning` (may hold several sentences separated by newlines) on a result that passed but is off from what was asked;
- sets `last_report` (a Dictionary, C5.3) on every op;
- clears all three at the start of the call.
- Never prints with `push_error` for user mistakes. `push_error` is for programmer errors only (wrong argument types).
- Wraps library calls in `try { } catch (const std::exception&) { } catch (...) { }`. pmp throws `pmp::TopologyException`, `pmp::InvalidInputException` and others, all deriving from `std::exception`. A caught exception becomes `last_error` = "<Op> failed inside the mesh library: <what()>".

#### 2.5.1 Construction and IO

| Method | Returns | Notes |
|---|---|---|
| `set_arrays(positions: PackedVector3Array, indices: PackedInt32Array, groups := PackedInt32Array(), group_names := PackedStringArray(), winding := "godot") -> bool` | true on success | `winding` is `"godot"` (clockwise front, flipped on input) or `"ccw"`. Empty `groups` means all 0 with name `g0`. Validates C1 rules. Only valid on a fresh instance: a second call returns false ("A mesh cannot change once made."). |
| `from_blob(bytes: PackedByteArray) -> bool` | | HFM1 uncompressed (2.2.3). Fresh instance only. |
| `to_blob() -> PackedByteArray` | | HFM1 uncompressed. |
| `read_stl(path: String, scale: float) -> bool` | | Native reader. Binary is detected by size: read n at offset 80; the file is binary when `84 + 50·n <= file size` and it does not parse as ASCII (`solid` then `facet` within the first 1 KB). Never decide by a leading `solid` alone (some binary files start with it). Padded binary files (extra bytes at the end) are binary; `tests/holo_forge_import_test.gd` already has one. ASCII otherwise. Welds bit-equal positions. `scale` turns file units into meters. Refuses over the cap before allocating. Fresh instance only. |
| `read_obj(path: String, scale: float) -> bool` | | Native reader. `v`, `f` (with `/` forms and negative indices), `o`/`g` as groups. Polygons triangulated (fan if convex, ear clipping otherwise). Other statements are ignored. |
| `from_shape(shape: CadShape, linear: float, angular: float, relative: bool, time_limit: float) -> bool` | | Tessellate (3.1.2). |
| `get_arrays() -> Dictionary` | `{"positions": PackedVector3Array, "indices": PackedInt32Array (Godot order), "groups": PackedInt32Array, "group_names": PackedStringArray}` | Used by export and tests. |
| `library_versions() -> Dictionary` | `{"pmp": "3.0.0", "manifold": "3.5.4", "meshoptimizer": "1.3", "clipper2": "2.0.1"}` | Strings filled from version macros where they exist (`MANIFOLD_VERSION_*`, `MESHOPTIMIZER_VERSION`), else from a CMake define set from the vcpkg port version (pmp, 8.1 row 1). Used by the smoke test. |

3MF and glTF keep using the existing GDScript readers in `core/import/mesh_import.gd`; their arrays go through `set_arrays`. Do not use `pmp::read`: its STL binary test only looks at the leading `solid`, and it does not catch topology exceptions.

#### 2.5.2 Queries (read-only)

| Method | Returns |
|---|---|
| The C2.2 subset | as in the table |
| `is_mesh() -> bool` | true |
| `triangle_count() -> int`, `group_count() -> int` | |
| `digest() -> String` | 16 hex chars, a 64-bit hash of positions, triangles, groups and names. Same content gives the same digest across runs. |
| `memory_bytes() -> int` | bytes held, for the cache |
| `check(time_limit := 2.0) -> Dictionary` | `{"closed": bool, "manifold": bool, "oriented": bool, "boundary_edges": int, "boundary_loops": int, "non_manifold_edges": int, "non_manifold_vertices": int, "degenerate_triangles": int, "duplicate_triangles": int, "unused_vertices": int, "components": int, "closed_components": int, "inverted_components": int, "genus": int (-1 if not closed), "self_intersections": int (-1 if not checked in time), "self_intersection_pairs": PackedInt32Array (first 64 pairs)}`. `inverted_components` counts closed components whose sign is wrong for their nesting depth (2.6.3). A correct void (negative volume inside a solid shell) is **not** inverted. `oriented` is true when every component is consistently oriented and `inverted_components` is 0. |
| `boundary_loops() -> Array` | one Dictionary per open loop: `{"id": int, "vertices": PackedInt32Array, "points": PackedVector3Array, "length": float, "edges": int, "planar_error": float}`. Loop ids are ordered by smallest vertex index (stable). |
| `group_triangles(group: int) -> PackedInt32Array` | |
| `ray_hit(origin: Vector3, direction: Vector3, max_distance := INF) -> Dictionary` | `{"hit": bool, "distance": float, "point": Vector3, "normal": Vector3, "triangle": int, "group": int}`. BVH. Back faces count (open meshes). |
| `triangles_in_frustum(planes: Array[Plane], mode: String) -> PackedInt32Array` | `mode` `"inside"` (all 3 vertices in) or `"crossing"` (any part in). For window and freeform select. |
| `triangles_near(point: Vector3, radius: float, connected: bool) -> PackedInt32Array` | Paint select. `connected` keeps only the patch reached from the nearest triangle. |
| `grow(tris: PackedInt32Array, steps: int) -> PackedInt32Array`, `shrink(...)` | One ring of edge-neighbours per step. |
| `connected(tris: PackedInt32Array, max_angle_deg: float) -> PackedInt32Array` | Flood fill across edges whose dihedral angle ≤ max_angle. 180 means whole component. |
| `section(origin: Vector3, normal: Vector3) -> Array` | Polylines: `[{"points": PackedVector3Array, "closed": bool}]`, in part space, chained and in a stable order. |
| `distance_to(other: CadMesh, samples: int, time_limit: float) -> Dictionary` | `{"max": float, "mean": float, "rms": float, "max_point": Vector3, "samples": int, "timed_out": bool}`. One-sided: from samples on this mesh (all vertices, plus area-weighted random points with a fixed seed, up to `samples`) to the nearest point on `other`. Hausdorff = max of both directions. |
| `fit_primitive(tris: PackedInt32Array) -> Dictionary` | Best plane, cylinder and sphere fits (2.5.6), with rms and max errors and the winner. |
| `winding_inside(points: PackedVector3Array) -> PackedByteArray` | 1 when inside (winding number ≠ 0 along a +Z ray, signed crossings), else 0. |

#### 2.5.3 Ops (each returns a new CadMesh, or `null` with `last_error`)

Every op takes an `options: Dictionary`. Every op reads `options.time_limit` (seconds, default 20.0, clamp 0.05..120). Option keys and ranges are in each tool's section (3). The native side **checks every range again** and refuses out-of-range values with a sentence (Phase 6 lesson: never clamp in silence).

| Method | Library | Tool |
|---|---|---|
| `close_holes(options) -> CadMesh` | own triangulation and refine + pmp `fair` on a local sub-mesh (never pmp `fill_hole`) | Close Holes |
| `stitch_and_remove(options) -> CadMesh` | own | Stitch and Remove |
| `wrap(options) -> CadMesh` | own voxel + Manifold `LevelSet` | Wrap |
| `rebuild(options) -> CadMesh` | own voxel + Manifold `LevelSet` | Rebuild |
| `generate_groups(options) -> CadMesh` | own + `fit_primitive` | Generate Face Groups |
| `regroup(tris_or_groups: Dictionary) -> CadMesh` | own | Combine Face Groups, Create Face Group |
| `remesh(options) -> CadMesh` | pmp `uniform_remeshing` / `adaptive_remeshing`, own projection | Remesh |
| `reduce(options) -> CadMesh` | pmp `decimate`, meshopt `meshopt_simplify` / `meshopt_simplifyWithAttributes` | Reduce |
| `plane_cut(options) -> Array` | Manifold `SplitByPlane` (closed, caps found by `runOriginalID`) or own clip (open) | Plane Cut. Returns `[CadMesh above, CadMesh below]`, either may be null. |
| `shell(options) -> CadMesh` | own offset, or voxel + Manifold `LevelSet` + Boolean | Shell |
| `boolean(tools: Array, options) -> CadMesh` | Manifold `BatchBoolean` / `Boolean` | Combine |
| `smooth(options) -> CadMesh` | pmp `implicit_smoothing` (whole body), own Laplacian (selections) | Smooth |
| `reverse(options) -> CadMesh` | own | Reverse Normal |
| `delete_triangles(tris: PackedInt32Array) -> CadMesh` | own | Direct Edit, Erase and Fill, Delete in selections |
| `transformed(xform: Transform3D) -> CadMesh` | own, doubles | Move/Copy, Mesh Align, Scale Mesh. A mirroring transform (det < 0) also flips every triangle so normals stay outward. |
| `displace(options) -> CadMesh` | own | Texture Extrude |
| `separate(options) -> Array` | Manifold `Decompose` plus our own void re-attach (closed), or own components (open) | Separate |
| `merge_with(others: Array) -> CadMesh` | own | Combine "Merge" (no boolean) |
| `to_faceted(options) -> CadShape` | OCCT (`exchange::mesh_shape`) | Convert Mesh: Faceted |
| `to_prismatic(options) -> CadShape` | own fits + OCCT `BOPAlgo_MakerVolume` | Convert Mesh: Prismatic |

`to_faceted` and `to_prismatic` return a `CadShape` (made inside the native code, like `CadKernel` does), or null with `last_error`.

#### 2.5.4 Threading

- Every method runs **on the calling thread** (the main thread in the editor), like `CadKernel`. No Godot API is called from any other thread.
- Manifold is built with `MANIFOLD_PAR=-1` (no TBB). It runs on the calling thread.
- pmp has no `#pragma omp` in its sources, so its output is deterministic (measured: repeated remesh and decimate runs are bitwise identical). It still links OpenMP (`VCOMP140.DLL`, present in System32). Do not call `omp_set_num_threads`.
- The only extra thread is the **watchdog** in C5.1. It sleeps on a condition variable and only calls `ExecutionContext::Cancel()` or sets an atomic flag. It never touches mesh data.
- `CadMesh` instances are immutable, so two instances can be read at the same time, but no test needs it.

### 2.6 C5: time bounds, budgets and post-checks

#### 2.6.1 Four layers of time bounds

Every op uses all layers that apply. The op stops at `time_limit` and returns null with `last_error` = "<Op> took longer than <limit> s and was stopped. <hint>". The hint is tool-specific (each tool lists it). No partial result is ever returned as success.

1. **Up-front budget.** Before any heavy work, the op estimates its cost from its size (triangles, voxels, hole edges, groups) and a per-op rate constant (`mesh_budget.h`). If the estimate is over the limit, it refuses at once: "<Op> would take about <n> s on this mesh (limit <limit> s). <hint>". Rate constants are measured in Stage N2/N3 on the dev machine and stored with a 1.5× safety factor. 2.6.2 gives the spike's measured numbers to start from. The preview uses the same estimate against 0.5 s.
2. **Deadline checks in our own loops.** A `mesh::Deadline` object (`steady_clock` based, `bool expired()`) is checked at least every 4,096 iterations in every loop we write (voxel fill, BVH builds, flood fills, clipping, fits, self-intersection tests).
3. **Chunked library calls with a fixed schedule.** pmp functions have no cancel hook. Call them in chunks whose single cost is bounded, and check the deadline between chunks:
   - `uniform_remeshing` / `adaptive_remeshing`: one iteration per call (`iterations = 1`, `use_projection = false`), then our own BVH nearest-point projection of every free, non-boundary vertex onto the **original** surface. This is the only schedule. The spike measured it against pmp's own 10-pass call: same quality within 10% on every test mesh, the same connectivity on smooth inputs, and 3% to 37% faster (8.1a). Never chunk with pmp's own projection: pmp rebuilds its reference mesh and a kd-tree from the already changed mesh on every call, so the result drifts. That measured worse and slower. The fixed schedule (the iteration count) is part of the result, so a slow machine gives the same result or a refusal, never a different mesh.
   - `decimate`: a fixed staircase of `DECIMATE_STEPS` (3) calls, in equal vertex-count steps towards the target. Do not use more: each call rebuilds its queue (O(n log n)), and 8 calls measured 1.6× to 2.6× the cost of one call. One call already lands on the target vertex count exactly (measured), so the steps are not needed for accuracy. They exist only so the deadline is checked between them.
   - Hole filling: pmp `fill_hole` is **not used** (2.9: it always refines and fairs the patch, wipes `v:selected` and costs O(V) per hole). Our own hole triangulation and patch refine have deadline checks (layer 2). pmp `fair` runs once per hole on a small local sub-mesh (3.2.1), bounded by the up-front budget on that hole's free vertices (≤ 200,000, a provisional cap: the spike did not time `fair`, so N2 measures it and may lower the cap).
   - `implicit_smoothing`: one call per iteration. The cost of one call grows faster than the triangle count (2.6.2).
   - **A chunk cannot be stopped, and a chunk is not small.** Measured single chunks at 100k / 500k / 2M triangles: one remesh pass with projection about 1.4 / 3.5 / 8.3 s, one `decimate` call to 50% about 3.1 / 9.5 / 50 s, one `implicit_smoothing` pass about 0.8 / 6.8 / 74 s. So for pmp ops the up-front budget (layer 1) is what keeps rule 0.5.1, and it must be right. Two rules follow. (a) Refuse up front whenever the estimate for the whole schedule is over the limit. (b) Before each chunk, estimate that chunk alone. If it would end after the deadline, stop there with the time-out error and do not start it.
4. **Library cancel hooks.**
   - **Manifold:** create one `manifold::ExecutionContext ctx` per op. Build inputs with `ctx.FromMeshGL(mesh)`, level sets with `ctx.LevelSet(...)`, and evaluate boolean trees with `(a - b).WithContext(ctx).Status()`. The watchdog calls `ctx.Cancel()` at the deadline. A `Status()` of `Error::Cancelled` becomes the time-out error. **Measured (8.1a):** a single boolean stops within about 45 ms of `Cancel()` (a 2 × 1M-triangle union that runs 5.3 s uncancelled: cancel at 50 ms, back at 95 ms), and `LevelSet` stops within about 22 ms. So a boolean does **not** run to its end, and the watchdog bounds booleans and level sets to about 50 ms over the limit. Keep the up-front budget for these ops anyway: it is there to refuse fast (0.5 lesson 6), not to bound the time. One gap: the spike did not time a cancel during `ctx.FromMeshGL` (the ingest, 2.8 s at 2M triangles). Until N3 measures that, the up-front estimate of every Manifold op must include the ingest, and a limit below the ingest estimate is refused up front.
   - **OCCT:** reuse the existing Deadline `Message_ProgressIndicator` (in `solid_ops.cpp`, about line 1701) for `BRepMesh_IncrementalMesh`, `BRepBuilderAPI_MakeShapeOnMesh`, `BOPAlgo_MakerVolume` and sewing, which all take a `Message_ProgressRange`. Wrap OCCT calls in `guard::run_bounded(seconds, work)` (`occt_guard.h`) as Phase 6 does for fillets. Measured on `BOPAlgo_MakerVolume`: a 1.0 s Deadline stopped it at 1,015 ms and a 0.2 s Deadline at 200 ms.

#### 2.6.2 Budgets (constants in `N\src\mesh_budget.h`, mirrored in `core/features/mesh.gd`)

| Name | Value |
|---|---|
| `MAX_TRIANGLES_MESH` | 2,000,000 |
| `MAX_TRIANGLES_FACETED` | 60,000 |
| `MAX_VOXEL_SAMPLES` | 2,000,000 (for example 125³). Not 4,000,000: `LevelSet` alone took 15 to 18 s at 3.9M cells (measured) |
| `MAX_PRISMATIC_SURFACES` | 150. This count is safe only when no cylinders cross, so Convert Prismatic also needs the time estimate below |
| `MAX_PRISMATIC_TRIANGLES` | 200,000 |
| `MAX_ORGANIC_FACES` | 5,000 cage faces |
| `MAX_SECTION_SEGMENTS` | 5,000 sketch lines |
| `DECIMATE_STEPS` | 3 (C5.1 layer 3). N2 may lower it to 2 after measuring. It is a constant, never chosen at run time |
| `PREVIEW_SECONDS` | 0.5 |
| `OK_SECONDS` | 20.0 |
| `SELF_INTERSECTION_SECONDS` | 1.0 (inside every post-check) |

**Voxel defaults must fit the grid cap.** Wrap, Rebuild and Shell (accurate) give a default cell size as a fraction of D or of the thickness. When that default would need more than `MAX_VOXEL_SAMPLES` on this body, the default is raised to the smallest cell size that fits, and the panel shows the raised value. A cell size the user typed is never changed: it is refused with the tool's "million cells" sentence.

**Starting numbers for the up-front estimates (measured, 8.1a).** Dev machine, single thread, one run, ±15%, library call only. N2, N3 and C measure them again inside the real ops (with our own code and the post-check) and store the results with the 1.5× factor.

| Library call | 100k triangles | 500k | 2M |
|---|---|---|---|
| pmp `decimate` to 50%, one call | 3.08 s | 9.54 s | 50.3 s |
| `meshopt_simplify` to 50% (`LockBorder` costs the same) | 47 ms | 0.60 s | 1.75 s |
| One remesh pass (no projection) plus our BVH projection | 1.39 s | 3.46 s | 8.32 s |
| pmp remesh, 10 passes, own projection | 9.05 s | 37.7 s | not run |
| pmp `implicit_smoothing`, one pass | 0.79 s | 6.79 s | 73.6 s |
| Manifold `FromMeshGL` (ingest; part of every Manifold op) | 0.30 s | 0.87 s | 2.77 s |
| Manifold union of two halves, after ingest | 0.31 s | 0.87 s | 3.50 s |
| Manifold subtract of two halves, after ingest | 0.41 s | 0.47 s | 2.50 s |
| Manifold `SplitByPlane`, after ingest | 0.94 s | 1.80 s | 5.61 s |
| Our BVH (naive): build, then one nearest-point query per vertex | 0.3 + 0.3 s | 0.7 + 1.2 s | 2.1 + 2.8 s |

How to turn them into estimates:

- **By triangle count (every row above).** Interpolate between the three measured sizes on log-log axes. Below 100k scale down linearly from the 100k point. Above 2M does not happen (the cap). Do not use one flat per-triangle rate: the cost per triangle changes with size.
- **Reduce adaptive.** One-call time for the input size, times a staircase factor of 1.5 for `DECIMATE_STEPS` = 3. The factor is **provisional and unmeasured** (8 steps measured 1.6× to 2.6×). N2 measures it.
- **Remesh.** The 10-pass row, scaled by `iterations / 10`, at max(input triangles, estimated output triangles). Past 500k, extend the 100k to 500k slope.
- **Smooth, whole body.** The estimate is **superlinear**: 20× the triangles cost 93× the time (0.79 s to 73.6 s per pass). Interpolate the `implicit_smoothing` row as above and multiply by `iterations`. A linear rate taken from a small mesh would let a 2M-triangle body start a 74 s pass.
- **Combine, Plane Cut and every other Manifold op.** Ingest plus the op row. Plane Cut is about 2.7 s at 500k, 4.4 to 4.7 s at 1M (interpolated, not measured) and 8.4 s at 2M.
- **Voxel ops (Wrap, Rebuild, Shell accurate).** `LevelSet` cost goes by grid cells, not triangles: 0.5 to 0.7 s at 0.26M cells (64³), 2.0 to 2.5 s at 1.0M (100³), 5.7 s at 2.1M (128³), 14.8 to 18.0 s at 3.9M (158³). It does not rise steadily, so do not interpolate. Use **4.6 s per million cells** (the worst rate seen) as the stored `LevelSet` rate, with no extra factor: it is already 1.7× the worst rate seen at 2.1M cells and below. Add our own distance field and distance transform, which the spike did not time (N3 measures them). `canParallel` makes no difference (no TBB).
- **Close Holes.** Per hole, from the hole's edge count and its estimated patch vertices (3.2.1). There is no per-body term, because every hole is worked on a local sub-mesh. The spike did not time our own fill or pmp `fair` (N2 measures them).
- **Convert Prismatic.** `0.01 s × surfaces + 0.25 s × crossing cylinder pairs` (3.4.2 step 3). Measured: 150 surfaces with no crossing cylinders take 0.91 s in `BOPAlgo_MakerVolume` and 1.5 s for the whole chain. 100 surfaces with about 120 crossing pairs take 28.1 s, and 150 with about 200 pairs take 44.8 s. That is about 0.22 s per crossing pair. The face count alone says almost nothing.

**Working sizes (from the measured numbers, at `OK_SECONDS` = 20, before the 1.5× factor).** Reduce adaptive: about 400k triangles with the old 8-step staircase, more with 3 steps. Remesh at 10 passes: about 200k. Smooth whole body at 5 passes: about 250k. Reduce fast, Combine and Plane Cut: up to the 2M cap. Close Holes is limited by the hole sizes, not the body size (by design, 3.2.1; not measured). Above its working size a tool refuses up front. That is allowed, but the refusal must name a way out (each tool's hint).

#### 2.6.3 Post-checks and the op report

Every op ends with `post_check()` on its result. It fills `last_report`:

```
{"op": String, "ms": float,
 "input":  {"triangles", "vertices", "groups", "closed", "boundary_edges", "volume", "area"},
 "output": {"triangles", "vertices", "groups", "closed", "boundary_edges", "non_manifold_edges",
            "degenerate_triangles", "volume", "area", "components"},
 "deviation": {"max", "mean", "samples"} | {},   # when the op promises a tolerance
 "self_intersections": int (-1 = not checked in time),
 "checks": {name: "ok" | "warn: <text>" | "fail: <text>"}}
```

Checks that run on every result:
- all positions finite, all indices valid (else **fail**: a bug, the op returns null with "<Op> made a broken mesh (internal error). Please report it.");
- no unused vertices, no empty groups (fix them, they are not failures);
- degenerate triangles (area < 1e-12 × bbox diagonal²): **warn** with the count when the op created new ones;
- non-manifold edges: **warn** when the op created new ones;
- boundary edges: compared with what the op promises (each tool says);
- orientation: closed components that are **inverted by the nesting rule below**: **warn** "n parts are inside-out" when the op created them. A void with negative volume is correct and must not be counted;
- volume change: compared with what the op promises;
- deviation: sampled Hausdorff (`distance_to`, both directions, 20,000 samples) when the op promises a tolerance. Remesh is the one exception: it fails on the output-to-input direction only (3.3.2);
- self-intersections: a BVH triangle-triangle test bounded by `SELF_INTERSECTION_SECONDS`. If it runs out, `-1`, and no claim is made. New self-intersections that the input did not have are a **warn**.

A **fail** in a check that the tool promises (listed in each tool's "Must hold" row) turns the result into null with that check's text as the error. Other checks become warnings.

**The nesting rule (hollow bodies; one rule, one place).** A hollow body is an outer shell plus one or more void shells. A void shell faces inward, so its signed volume is **negative**. That is correct, not inside-out. Manifold agrees: `Decompose` returns each void as its own part with negative volume (measured, 8.1a). Any rule that says "a closed component with negative volume is wrong" breaks hollow bodies, so no code may use that test. Use this instead, everywhere:

- Work per closed, consistently oriented, edge-connected component. Open components have no depth and are skipped.
- **B contains A** when every one of up to 64 vertices of A (evenly spaced by index) is inside B. Test with `winding_inside` against B's triangles alone; it works whether B faces out or in. Check the bounding boxes first (B's box must hold A's box). Mixed answers mean the two shells cross: then neither contains the other.
- The **nesting depth** of A is the number of closed components that contain A. Its **parent** is the smallest of them by absolute volume.
- **Even depth** (0, 2, ...) is a solid shell: an outermost shell, or an island inside a void. It must have **positive** volume. **Odd depth** is a void. It must have **negative** volume.
- A component is **inverted** only when its sign does not match its depth.

One native helper in `mesh_query.cpp` implements this, with deadline checks. These all call it and never test the sign alone: `check()` (`inverted_components`, `oriented`), `solid_count()`, the orientation post-check above, Stitch and Remove step 4 (3.2.2), Reverse Normal auto (3.3.8) and Separate (3.3.12).

### 2.7 C6: display, picking, selection, bake and export

#### 2.7.1 `CadMesh.tessellate(linear, angular)` contract

Returns the same keys as `CadShape.tessellate`, so `forge_viewport.set_bodies`, `cad_part.apply_result` and `core/tessellate.gd` need no special case for drawing:

| Key | Content for a mesh body |
|---|---|
| `positions` | PackedVector3Array. Vertices are **split per group border and at sharp edges** (dihedral > 30°) so flat shading looks right, and shared elsewhere. |
| `normals` | angle-weighted vertex normals per split vertex |
| `uvs` | PackedVector2Array, box projection by the dominant normal axis, in meters (so appearances tile at a fixed size) |
| `indices` | Godot winding. **Triangle order is the stored order**, so triangle k of the tessellation is stored triangle k. Picking and selection rely on this. |
| `face_ids` | PackedInt32Array, one per **triangle**: its group id. This matches `CadShape.tessellate`, which pushes one face id per triangle (checked in `cad_shape.cpp`). |
| `edge_points` | line segments for group borders and open boundaries (pairs of points) |
| `edge_ids` | per segment: -1 for a group border, -2 for an open boundary. Never a pickable edge id. |
| `vertices` | empty (no pickable vertices on mesh bodies in Phase 7) |
| `warnings` | not set |

`core/tessellate.gd tessellate(shape)` calls `shape.bbox()` and `shape.tessellate(linear, 0.3)`. That works unchanged. `surface_mesh`, `face_subset_mesh`, `edge_mesh` and `collision_faces` must take the mesh path through `face_ids`. Check each one with a mesh body in the gate test.

`forge_workspace.recompute` reuses tessellations by `is_same(shape)`. CadMesh results are new instances only when the content changed or the cache missed, so this keeps working.

#### 2.7.2 Picking

- `core/picking.gd` today loops over all triangles in GDScript. For mesh bodies (`MESH_BODY.is_mesh(shape)`), call `shape.ray_hit(origin, dir)` instead and map the result to the existing pick dictionary: kind `"mesh_group"` (or `"mesh_triangle"` in triangle mode), `body`, `group` (name), `triangle`, `point`, `normal`.
- `nearest_edge` and `nearest_vertex` skip mesh bodies (no edges, no vertices).
- Hover budget: ≤ 4 ms per hover on a 1,000,000-triangle body (BVH ray). Test with the ratio method.

#### 2.7.3 Selection model (Mesh workspace only)

- **Two pick modes:** "Face Groups" (default) and "Triangles". The mode is a workspace setting shown as two toggle tools in Mesh > Select (6.3 icons, 3.6).
- In group mode a click selects a whole group. In triangle mode a click selects one triangle. Shift adds, Ctrl removes, as in other workspaces.
- Window, Freeform and Paint selection (existing shared tools) work in both modes through `triangles_in_frustum` and `triangles_near`. In group mode, a group is selected when any of its triangles is.
- Grow, Shrink, Connected and Select Boundary act on the triangle selection (3.6).
- The selection is stored in the workspace as `{"body": id, "triangles": PackedInt32Array}` or group names. Panels copy it into their picks (2.4.3).
- Highlight: selected triangles draw as an overlay mesh (`face_subset_mesh` with the triangle list) in `mesh_selected`. Hover in `mesh_hover`.

#### 2.7.4 Bake and export

- Bake: `cad_part.apply_result` tessellates every body. Mesh bodies bake like any other. `generate_collision` uses `collision_faces` (check it takes `face_ids`).
- `.glb` export: unchanged (uses the bake).
- `core/export.gd export_cad`:
  - STL, OBJ, 3MF: mesh bodies write their **exact** triangles (from `get_arrays()`), not a re-tessellation. B-rep bodies are unchanged.
  - STEP, IGES, BREP: mesh bodies are **refused** with "<Body> is a mesh body; STEP/IGES need B-rep bodies. Convert it first, or export STL/OBJ/3MF." The other bodies still export, and the export result lists the skipped ones.

### 2.8 C7: workspace, catalog, toolbar and plugin wiring (one checklist)

#### `tools/catalog.gd`
- `IMPLEMENTED_PHASE := 7`.
- New `const PHASE7 := {"Tessellate": "mesh:tessellate", "Create Mesh Section Sketch": "mesh:section_sketch", "Close Holes": "mesh:close_holes", "Stitch and Remove": "mesh:stitch_remove", "Wrap": "mesh:wrap", "Rebuild": "mesh:rebuild", "Generate Face Groups": "mesh:generate_groups", "Combine Face Groups": "mesh:combine_groups", "Create Face Group": "mesh:create_group", "Direct Edit": "action:mesh_direct_edit", "Remesh": "mesh:remesh", "Reduce": "mesh:reduce", "Plane Cut": "mesh:plane_cut", "Shell": "mesh:shell", "Combine": "mesh:combine", "Smooth": "mesh:smooth", "Reverse Normal": "mesh:reverse_normal", "Erase and Fill": "mesh:erase_fill", "Mesh Align": "mesh:align", "Texture Extrude": "mesh:texture_extrude", "Separate": "mesh:separate", "Move/Copy": "mesh:move", "Scale Mesh": "mesh:scale", "Convert Mesh: Faceted": "mesh:convert_faceted", "Convert Mesh: Prismatic": "mesh:convert_prismatic", "Convert Mesh: Organic": "mesh:convert_organic", "Insert Mesh": "action:insert_mesh_body", "Display Mesh Face Groups": "action:mesh_face_groups"}`.
- In `all_tools()`, add a phase-7 branch like the phase-5 one: an `"action:"` target sets `extra["action"]`, anything else sets `extra["command"] = FEATURE` and `extra["type"] = target`.
- Mesh "Select" group: `_SHARED_SELECT + [["Select Face Groups", 7, {"action": "mesh_pick_groups"}], ["Select Triangles", 7, {"action": "mesh_pick_triangles"}], ["Grow Selection", 7, {"action": "mesh_grow"}], ["Shrink Selection", 7, {"action": "mesh_shrink"}], ["Select Connected", 7, {"action": "mesh_connected"}], ["Select Boundary", 7, {"action": "mesh_boundary"}]]`. Only in the Mesh workspace.
- Keep the existing Mesh folders and default pins.
- Display Mesh Face Groups shortcut Shift+F, only if `for_shortcut` shows no clash. Otherwise no shortcut.

#### `tools/feature_specs.gd`
- New `static func _add_mesh_specs()` called from `_build()`. One `_add("mesh:<method>", ...)` per tool with the fields in section 3. Default op `""` (mesh features own their bodies), except where 3 says otherwise.
- New selection filter kinds: `"mesh_body"`, `"mesh_group"`, `"mesh_triangles"`, `"mesh_boundary"` (a boundary loop, picked by clicking near its line).
- The `kind` choice on `"mesh_import"` (2.4.2).

#### `tools/feature_command.gd`
- Picks of kind `mesh_*` read from the Mesh selection model (2.7.3).
- A `"stat"` info row type for mesh tools: a read-only line showing "Triangles: 20,480 → 10,240 (50.0%)", "Open edges: 0", "Max deviation: 0.012 mm". It is filled from `last_report` after each preview. The Phase 6 info-row flood fix applies: replace the row, never append.
- When the preview is skipped (over budget), the stat row says "Preview skipped (too slow); press OK to compute."

#### `ui/forge_workspace.gd` (find by function name)
- `recompute`: no change for drawing (C6.1). Body entries carry `kind`.
- Browser: mesh bodies show the icon `ArrayMesh` and the triangle count in the tooltip.
- Actions: `insert_mesh_body` (Insert Mesh with `kind = "mesh"`), `mesh_direct_edit` (3.3.1), `mesh_face_groups` (toggle, 3.5.1), the six selection actions.
- Context menu on a mesh body: "Convert Mesh..." (opens Convert Mesh: Faceted), "Reduce...", "Close Holes...". On a B-rep body in the Mesh workspace: "Tessellate...".

#### `ui/forge_viewport.gd`
- `set_bodies` gains the face-group colouring path (3.5.1) and the selection overlay. Use the existing mesh-key reuse.

#### `ui/timeline.gd`, `ui/forge_theme.gd`
- Icons per `mesh:<method>` (2.4.1). Theme tokens in 6.1.

#### `plugin.gd`
- `const MESH_TEST_ARG := "--holo-forge-mesh-editor-test"`, loading `res://tests/holo_forge_mesh_editor_test.gd` and calling `.run.call_deferred(self)` in `_enter_tree`, exactly like `FORM_TEST_ARG`.
- Call `cad_part.externalize_mesh_blobs()` next to `externalize_meshes()` before save.

#### `nodes/cad_part.gd`
- `externalize_mesh_blobs()` (2.2.4).

### 2.9 C8: library facts (verified on 2026-11-11 in V; build on these)

Facts marked **measured** come from the spike (8.1a), which ran the installed DLLs. The others come from the headers, the sources and dumpbin.

#### pmp-library (`find_package(pmp CONFIG REQUIRED)`, target `pmp`, SHARED `pmp.dll`)
- **Version:** vcpkg port and buildtree say 3.0.0. The source's own `project(VERSION 2.0.1)` and `share/pmp/pmpConfigVersion.cmake` say 2.0.1, and its CHANGELOG top section is "Unreleased". So this is a post-2.0.1 snapshot that vcpkg calls 3.0.0. Trust the **signatures below**, not the number.
- The target's `INTERFACE_LINK_LIBRARIES` is `OpenMP::OpenMP_CXX`, but its config does not call `find_dependency`. **Call `find_package(OpenMP REQUIRED)` before `find_package(pmp)`.**
- `Scalar` is `float` (`PMP_SCALAR_TYPE_64` not set). Indices are 32-bit.
- Exported signatures (checked with dumpbin, float arguments):
  - `decimate(SurfaceMesh&, unsigned n_vertices, Scalar aspect_ratio, Scalar edge_length, unsigned max_valence, Scalar normal_deviation, Scalar hausdorff_error, Scalar seam_threshold, Scalar seam_angle_deviation)`
  - `uniform_remeshing(SurfaceMesh&, Scalar edge_length, unsigned iterations = 10, bool use_projection = true)`
  - `adaptive_remeshing(SurfaceMesh&, Scalar min_edge_length, Scalar max_edge_length, Scalar approx_error, unsigned iterations = 10, bool use_projection = true)`
  - `fill_hole(SurfaceMesh&, Halfedge)`; `fair(SurfaceMesh&, unsigned k = 2)`; `explicit_smoothing(SurfaceMesh&, unsigned iters, bool use_uniform_laplace)`; `implicit_smoothing(SurfaceMesh&, Scalar timestep, unsigned iters, bool use_uniform_laplace, bool rescale = true)`; `detect_features(SurfaceMesh&, Scalar angle)`; `triangulate(SurfaceMesh&)`.
- Behaviour from the sources:
  - Remeshing locks vertices **not** in `v:selected` only when that property exists **and at least one vertex is selected**. With the property present but no vertex selected, nothing is locked and the whole mesh is remeshed. It keeps `e:feature` / `v:feature`.
  - Remeshing with `use_projection = true` builds its reference mesh and a kd-tree inside every call (`Remeshing::preprocessing`). So calling it pass by pass projects onto the already changed mesh. Use `use_projection = false` and our own projection (C5.1). **Measured:** that matches pmp's own 10-pass call.
  - Remesh and decimate are deterministic. **Measured:** repeated runs are bitwise identical.
  - Decimation keeps feature edges. **Measured:** `decimate` lands on the target vertex count exactly, with one call or with a staircase, also with 45° features marked.
  - `fill_hole` is **not used by Holo Forge**. From `hole_filling.cpp` and **measured**: it never stops at the minimal triangulation. It always triangulates, then runs 10 rounds of split / collapse / flip / relax inside the patch, then fairs it. It added 522 to 26,017 vertices per hole. It writes and then **removes** a `v:selected` property, so a caller's `v:selected` is lost. It first marks every vertex and edge of the **whole mesh** as locked, so each hole costs O(V + E): a 100-edge hole took 0.46 s on 100k triangles and 4.89 s on 2M, and an 800-edge hole took 152.9 s on 2M. It throws `InvalidInputException` ("fill_hole: Not a boundary halfedge.") for a non-boundary or non-manifold hole.
  - `fair` keeps unselected vertices fixed through `v:selected` and needs fixed constraints (a closed component with every vertex selected fails).
  - Smoothing fixes boundary vertices only. It cannot lock other vertices. `implicit_smoothing` must be called with `rescale = false` (rescale moves and scales the whole mesh). **Measured:** one pass is a sparse solve whose cost grows faster than the mesh: 0.79 s at 100k triangles, 6.79 s at 500k, 73.6 s at 2M.
  - `add_face` throws `TopologyException` ("Complex vertex" / "Complex edge") on non-manifold input (**measured:** a third face on one edge gives "SurfaceMesh::add_face: Complex edge."). Building a `SurfaceMesh` therefore needs a clean, manifold triangle set: run our own cleanup first, and catch the exception.
  - `pmp.dll` imports `VCOMP140.DLL` (checked with dumpbin `/dependents`).

#### Manifold (`find_package(manifold CONFIG REQUIRED)`, target `manifold::manifold`, SHARED `manifold.dll`)
- **Version 3.5.4** (`version.h` and config). Defines `MANIFOLD_CROSS_SECTION`, `MANIFOLD_PAR=-1`. It finds Clipper2 2.0.1 itself (static, inside manifold.dll, BSL-1.0). No TBB. `manifoldc` is not needed.
- `ExecutionContext`: `Cancel()` (any thread), `Cancelled()`, `Progress()`, `FromMeshGL(const MeshGL&)` / `(const MeshGL64&)`, `Smooth(...)`, `LevelSet(sdf, Box, edgeLength, level = 0, tolerance = -1, canParallel = true)`.
- `Manifold::WithContext(ctx)`: only `Status()` and eager ops (Refine, Hull, Minkowski) observe it. Booleans are deferred: use `(a - b).WithContext(ctx).Status()`.
- **Cancel (measured):** `Cancel()` stops a single running boolean within about 45 ms and a running `ctx.LevelSet` within about 22 ms. The result's `Status()` is `Cancelled`. A cancel during `ctx.FromMeshGL` was not timed.
- `Manifold::Error`: NoError, NonFiniteVertex, NotManifold, VertexOutOfBounds, PropertiesWrongLength, MissingPositionProperties, MergeVectorsDifferentLengths, MergeIndexOutOfBounds, TransformWrongLength, RunIndexWrongLength, FaceIDWrongLength, InvalidConstruction, ResultTooLarge, InvalidTangents, Cancelled. `ToString` exists only under `MANIFOLD_DEBUG`, so **write our own messages** (`mesh_manifold.cpp manifold_error_text`).
- `MeshGL` / `MeshGL64`: `numProp` (3 = positions only), `vertProperties`, `triVerts` (CCW from outside), `faceID` (per triangle; kept through ops; "Simplification will maintain all edges between triangles with different faceIDs"), `runIndex`, `runOriginalID`, `tolerance`, `Merge()`. On output **triangles are reordered into runs**. Edges shorter than the tolerance may be collapsed. **Measured:** with `tolerance = 0` the baseline is 1e-12 × the bbox scale and no triangle is dropped by `FromMeshGL`, a union or `SplitByPlane`, even with 1e-7 m edges or 5 m × 3 mm slivers. Keep `tolerance = 0`.
- **Run IDs (measured).** Set `runOriginalID` on input from `Manifold::ReserveIDs(n)`. Output runs carry the value we set. Read it from the output MeshGL: `Manifold::OriginalID()` of a MeshGL-built Manifold returns −1. Input runs keep their `runOriginalID` and their `faceID` through ops.
- **Plane cuts (measured).** Every cap triangle from `SplitByPlane` / `TrimByPlane` sits in a run with a **fresh** `runOriginalID` that matches no input. Each cut call makes a new one. The cap `faceID` is **always 2**, so it can collide with our group 2: never use it. `TrimByPlane` keeps the side the normal points to. A plane that lies on an outer face gives an empty result on one side with status `NoError`. The two halves of a split sum to the input volume exactly.
- **Voids (measured).** `Decompose()` returns each void as its **own manifold with negative volume** (status `NoError`). Voids do not stay with their outer shell. A solid inside a void is its own positive part. `FromMeshGL` also accepts a lone inside-out shell (`NoError`, negative volume). See the nesting rule (2.6.3).
- Other calls used: `SplitByPlane(normal, originOffset) -> pair(+side, -side)`, `TrimByPlane`, `Boolean`/`BatchBoolean(OpType::Add/Subtract/Intersect)`, `Decompose()`, `Volume()`, `SurfaceArea()`, `Genus()`, `Slice()`, `Simplify(tol)`, `SetTolerance`, `GetMeshGL64()`.
- `LevelSet` SDF is **positive inside**. It uses marching tetrahedra on a body-centred cubic grid. **Measured:** the SDF is called about 2 × the cell count. The cost goes by the grid, not by the triangle count, and it does not rise steadily (2.6.2). `canParallel` makes no difference.
- `manifold.dll` imports only the MSVC runtime and KERNEL32 (no TBB; checked with dumpbin).

#### meshoptimizer (`find_package(meshoptimizer CONFIG REQUIRED)`, target `meshoptimizer::meshoptimizer`, SHARED `meshoptimizer.dll`)
- **Version 1.3** (`MESHOPTIMIZER_VERSION 1030`). The import define `MESHOPTIMIZER_API=__declspec(dllimport)` comes from the target.
- `size_t meshopt_simplify(unsigned* destination, const unsigned* indices, size_t index_count, const float* vertex_positions, size_t vertex_count, size_t vertex_positions_stride, size_t target_index_count, float target_error, unsigned options, float* result_error)`. `destination` needs `index_count` space.
- Options: `meshopt_SimplifyLockBorder`, `Sparse`, `ErrorAbsolute`, `Prune`, `Regularize`, `Permissive`, `RegularizeLight`, `PreserveFolds`, `ErrorClamped`.
- `size_t meshopt_simplifyWithAttributes(unsigned* destination, const unsigned* indices, size_t index_count, const float* vertex_positions, size_t vertex_count, size_t vertex_positions_stride, const float* vertex_attributes, size_t vertex_attributes_stride, const float* attribute_weights, size_t attribute_count, const unsigned char* vertex_lock, size_t target_index_count, float target_error, unsigned options, float* result_error)`. `vertex_lock` holds one byte per vertex with the flags `meshopt_SimplifyVertex_Lock`, `_Protect`, `_Priority`. The spike called it with `attribute_count = 0`.
- **Group borders (measured).** `meshopt_SimplifyLockBorder` locks **open edges only**. It has no effect on attribute seams (vertices split along a border): results are identical with and without it. Split seams keep the group topology but vertices still collapse **along** the border, so curved borders drift (up to 0.056% of D at a 10% target). `vertex_lock = meshopt_SimplifyVertex_Lock` on every group-border vertex of the **welded** mesh gives zero drift (1e-16) and still hits the target count exactly. A welded mesh with no locks destroys the borders (border length +54% to +154%). `meshopt_SimplifyRegularize` shortened a jagged border by 22.6%: never pass it when borders must stay.
- **Open edges (measured).** With `LockBorder` an open sphere at a 10% target keeps its 400 open edges. Without it 117 are left.
- **Output quality (measured).** The output can contain non-manifold edges: 1 to 6 near the poles of a UV sphere in every run without `Regularize`. The post-check must count them (3.3.3).
- It may stop above the target (it hit 100.0% of the target in all 30 spike runs). Its asserts are off in release builds, so **validate the input first** (indices in range, count divisible by 3).
- `meshoptimizer.dll` imports only the MSVC runtime and KERNEL32.

#### OCCT 8.0.1 (already linked)
- `BRepMesh_IncrementalMesh`, `BRepBuilderAPI_MakeShapeOnMesh`, `BOPAlgo_MakerVolume` and `BRepBuilderAPI_Sewing` take a `Message_ProgressRange`.
- `IMeshTools_Parameters` has no maximum edge length (confirmed in the header: Angle, Deflection, AngleInterior, DeflectionInterior, MinSize and flags). So Tessellate has no "max edge length" field. The panel points to Remesh for that.
- **`BOPAlgo_MakerVolume` (measured).** Its cost goes by **crossing cylinder pairs**, not by the face count: about 0.006 s per surface when no cylinders cross, and about 0.22 s more per pair of crossing cylinders (2.6.2). The Deadline progress indicator stops it on time (C5.1).
- **`BRepClass3d_SolidClassifier` (measured).** Using it to pick the cells of a `MakerVolume` result cost another 7.5 to 10.5 s on a part with crossing holes. Do not use it to pick cells (3.4.2 step 5).

#### CMake change (Stage N0)

```cmake
find_package(OpenMP REQUIRED)            # pmp's config needs it first
find_package(pmp CONFIG REQUIRED)
find_package(manifold CONFIG REQUIRED)
find_package(meshoptimizer CONFIG REQUIRED)
target_link_libraries(holo_forge_native PRIVATE pmp manifold::manifold meshoptimizer::meshoptimizer)
target_compile_definitions(holo_forge_native PRIVATE HOLO_FORGE_PMP_PORT_VERSION="3.0.0")
```

- **Eigen.** pmp's imported target does **not** carry Eigen's include path, but pmp's public headers include `Eigen/Dense`. A target that uses pmp without Eigen fails with "Cannot open include file: 'Eigen/Dense'" (seen in the spike build). **N** already calls `find_package(Eigen3 CONFIG REQUIRED)` and links `Eigen3::Eigen`, so the block above needs no extra line. Keep that link. Any other target that includes a pmp header (a test tool, a benchmark) must link `Eigen3::Eigen` itself.
- The `src/*.cpp` glob picks up the new files.
- The DLLs are copied by the existing `TARGET_RUNTIME_DLLS` step. Check that `A\bin` gains exactly `pmp.dll`, `manifold.dll` and `meshoptimizer.dll`.
- No new LGPL code. LGPL stays in its separate DLLs (OCCT TK*.dll, planegcs.dll). Do **not** link anything static that is LGPL.
- The `.gdextension` `[dependencies]` block is empty today and the DLLs load from `A\bin` beside `holo_forge_native.dll`. Keep it that way (the extension is editor-only).

---

## 3. Tool-by-tool behaviour

### Conventions used in this section

- **Undo.** Every tool is one undo step `"Mesh: <Title>"` on OK, unless stated.
- **Picks.** "Bodies" = filter `"mesh_body"`. "Selection" = the Mesh selection (groups or triangles). If a tool needs a selection and none is made when it starts, it uses the current workspace selection; if that is empty, the panel waits for picks.
- **Fields.** Lengths are expression fields in document units (`_LEN`), stored in meters. Ranges are checked on OK **and** in native code. Out-of-range values are refused with "<Field> must be between <a> and <b>." Never clamp in silence.
- **D** is the body's bounding-box diagonal. **ē** is its mean edge length.
- **Rows per tool:** Inputs, Fields, Algorithm, Must hold (checks that turn into errors), Warn (checks that turn into warnings), Messages, Acceptance (test numbers in 5).
- **Ownership.** N = native, G = integration, U = UI, M = tool wiring, C = convert.

### 3.1 Create

#### 3.1.1 Insert Mesh (M, on G's `insert.gd` change)

- **Inputs:** a file (STL, OBJ, 3MF, glTF/GLB).
- **Fields:** existing ones (File, units, Z-up, Linked, One Body per Piece, placement) plus **Body Type** (Mesh Body / Solid (faceted)). From the Mesh workspace the default is Mesh Body.
- **Algorithm (Mesh Body):** STL and OBJ through `read_stl`/`read_obj` with `scale` from the units. 3MF and glTF through the GDScript readers, then `set_arrays`. Then the placement transform (`transformed`). "One Body per Piece" uses `separate({"by": "components"})`.
- **After reading,** run `check()`. If the mesh is not closed, warn: "<Body> has <n> open edges in <k> holes. Prepare > Close Holes can fix them." Non-manifold edges: "<n> edges are shared by more than two triangles. Stitch and Remove can fix them."
- **Must hold:** T ≤ 2,000,000 before allocation ("<File> has <n> triangles; mesh bodies take up to 2,000,000."). All indices valid.
- **Acceptance:** 5.2 #1-4, 5.5 #3.

#### 3.1.2 Tessellate (N `from_shape`, M)

- **Inputs:** B-rep bodies (filter `"body"`; mesh bodies refused: "<Body> is already a mesh body.").
- **Fields:**

| Key | Label | Type | Default | Range |
|---|---|---|---|---|
| `quality` | Refinement | enum low / medium / high / very_high / custom | medium | |
| `linear` | Surface Deviation | length, visible for custom | 0.1 mm | 0.001 mm .. D/10 |
| `angular` | Normal Deviation | angle, visible for custom | 15° | 1° .. 45° |
| `relative` | Relative to Size | bool, visible for custom | false | |
| `keep_original` | Keep Original Body | bool | true | |

  Presets (linear as a fraction of D, angular): low 1/200 and 30°, medium 1/1000 and 15°, high 1/5000 and 8°, very high 1/20000 and 4°.
- **Algorithm:** `BRepMesh_IncrementalMesh` with the Deadline progress range and `run_bounded`. Each B-rep face becomes one group named after the face. Nodes along shared edges are bit-equal in OCCT (edges are discretised once), so weld by exact double position before the float conversion. Faces with no triangulation are an error ("Face <name> could not be tessellated.").
- **Output:** a new mesh body per input body (create-style). The original is hidden when Keep Original is off (the body is removed from ctx like `remove`).
- **Must hold:** a closed B-rep solid gives a closed mesh (0 boundary edges, 0 non-manifold edges). Mesh volume within 1% of the B-rep volume.
- **Warn:** a surface body gives an open mesh (expected; no warning). More than 2,000,000 triangles: refuse "Tessellate would make about <n> triangles; lower the Refinement."
- **Note in the panel:** "For a maximum edge length, Remesh the result."
- **Acceptance:** 5.2 #5-6, 5.3 #1.

#### 3.1.3 Create Mesh Section Sketch (N `section`, M)

- **Inputs:** one mesh body, one plane (origin, construction or planar face).
- **Fields:** `tolerance` (Simplify Tolerance, length, default D/2000, range 0 .. D/20), `fit` (Fit Lines and Arcs, bool, default false: plain line chains).
- **Algorithm:** `section(origin, normal)` gives polylines. Douglas-Peucker with the tolerance. With Fit on, runs of points that fit a circle within the tolerance become arcs (3 points minimum, angle ≥ 15°). The result is a new sketch feature on that plane holding the curves, **fixed** (no dimensions, no constraints other than coincident joints between consecutive pieces). Its feature is a normal `sketch` feature; it is not associative to the mesh (a note in the sketch: "Made from a section of <Body>").
- **Must hold:** ≤ 5,000 segments ("The section has <n> segments; raise the Simplify Tolerance."). A plane that misses the body: "The plane does not cut <Body>."
- **Warn:** open polylines (open mesh, or the plane runs along a hole): "<n> section curves are open."
- **Acceptance:** 5.2 #7.

### 3.2 Prepare

#### 3.2.1 Close Holes (N `close_holes`, M)

- **Inputs:** Bodies, optional boundary loops (filter `"mesh_boundary"`). No loops picked means all holes.
- **Fields:**

| Key | Label | Type | Default | Range |
|---|---|---|---|---|
| `fill` | Fill Type | enum minimal / smooth / flat | smooth | |
| `max_edges` | Largest Hole (edges, 0 = any) | number | 0 | 0 .. 100,000 |
| `refine` | Match Edge Size | bool, for smooth | true | |

- **Algorithm:** (pmp `fill_hole` is never called. It cannot give a minimal fill, it wipes `v:selected` and it costs O(V) per hole; 2.9.)
  1. `boundary_loops()`; drop loops over `max_edges` (counted for the warning).
  2. **Minimal triangulation, our own code, for every fill type.** Loops ≤ 400 edges: the minimal-area-and-dihedral triangulation of the loop (a dynamic program over the loop, O(n³) in its edge count, with deadline checks). Larger: our own ear clipping on the loop projected to its best-fit plane, with a 3D minimum-area fallback when the projection folds. This step only adds triangles between existing loop vertices. It adds no vertex and moves none.
  3. minimal: stop after step 2. flat: project patch vertices to the loop's best plane. smooth, per hole:
     1. With Match Edge Size on, refine the patch to ē (split edges longer than 1.33 ē, our code). With it off, skip the refine.
     2. Build a **local sub-mesh**: the patch plus 3 rings of original triangles around the loop. Its size depends on the hole, not on the body.
     3. Build a pmp `SurfaceMesh` from the sub-mesh only. Put the patch's interior vertices in `v:selected` and call `fair(submesh, 2)`. Loop and ring vertices are unselected, so they stay fixed and give `fair` its constraints.
     4. Copy back **only** the positions of the patch's interior vertices. Never write a loop vertex or a ring vertex.
     A patch with no interior vertex has nothing to fair: skip the sub-mesh.
  4. New triangles go to a new group `fill<k>` per hole.
- **Why a sub-mesh:** pmp works on the whole mesh it is given. `fill_hole` on the whole body cost O(V) for every hole (measured: 4.9 s for one 100-edge hole on 2M triangles), and "Close all holes" on a scan with many small holes would multiply that. On a sub-mesh no pmp call can cost more than the hole's own size. One hole's cost must depend on that hole only.
- **Up-front:** estimate each hole from its edge count (step 2) and its expected patch vertices (step 3: patch area / (0.433 ē²) triangles, half as many vertices), and sum the holes. There is no per-body term. Over the limit: refuse with the standard sentence and the hint below.
- The sub-mesh given to pmp must be manifold. Keep the simple rule for the whole body: if it has non-manifold edges, refuse: "<Body> has <n> non-manifold edges. Run Stitch and Remove first."
- **Must hold:** every hole that was asked for is closed (boundary edges of those loops = 0). Original triangles unchanged (bitwise).
- **Warn:** skipped loops ("<n> holes were larger than Largest Hole and stay open."). New self-intersections. Holes whose fill left the hole's plane by more than its diameter (a fold) are listed.
- **Time-out hint:** "Close fewer holes at once, or use Wrap."
- **Acceptance:** 5.3 #3 (the plan item), 5.2 #8-9.

#### 3.2.2 Stitch and Remove (N `stitch_and_remove`, M)

- **Inputs:** Bodies.
- **Fields:**

| Key | Label | Type | Default | Range |
|---|---|---|---|---|
| `tolerance` | Stitch Tolerance | length | D × 1e-5 | 0 .. D/100 |
| `remove_small` | Remove Small Pieces | bool | true | |
| `min_size` | Smallest Piece to Keep (% of the largest piece's area) | number | 1 | 0 .. 50 |
| `remove_inner` | Remove Pieces Inside Others | bool | false | |
| `fix_non_manifold` | Fix Non-Manifold Edges | bool | true | |

- **Algorithm (own code):**
  1. Weld vertices closer than the tolerance (uniform grid hash, union-find, pick the lowest index).
  2. Drop degenerate and duplicate triangles (same vertex set).
  3. Non-manifold edges: drop "fin" triangles (both other edges free) first, then split the remaining non-manifold edges so each side keeps a consistent pair. Non-manifold vertices are split by fan.
  4. Orient each component consistently (BFS on the dual graph). Then flip only the closed components that are **inverted by the nesting rule** (2.6.3): a shell at even depth must end with positive volume, a void (odd depth) with negative volume. Never flip a component just because its volume is negative: that would turn the void of a hollow body into a solid that overlaps its outer shell.
  5. Remove pieces under the area threshold. Remove inner pieces when asked (a piece whose `winding_inside` sample points are all inside another closed piece). This removes voids too, so a hollow body becomes solid; that is what the option asks for.
- **Must hold:** no new non-manifold edges. Total area changes only by removed pieces and degenerate triangles (check the sum). With Remove Pieces Inside Others off, a correct hollow body keeps its voids and its volume.
- **Report** in the stat row: "Welded <n> vertices, removed <m> triangles and <k> pieces, fixed <j> non-manifold edges."
- **Acceptance:** 5.2 #10-11.

#### 3.2.3 Wrap (N `wrap`, M)

Makes a closed shell around anything, even with holes and gaps. It closes gaps up to about 2 × Gap.

- **Inputs:** Bodies (several are wrapped into one body).
- **Fields:**

| Key | Label | Type | Default | Range |
|---|---|---|---|---|
| `detail` | Detail (cell size) | length | D/150 (raised to fit the grid cap, 2.6.2) | D/400 .. D/10, and the grid ≤ `MAX_VOXEL_SAMPLES` (2M samples) |
| `gap` | Close Gaps Up To | length | 2 × detail | detail .. D/4 |
| `offset` | Offset | length | 0 | −gap .. D/10 |

- **Algorithm (morphological closing):**
  1. Grid over the bounds grown by gap + offset + 2 cells. Refuse up front if over `MAX_VOXEL_SAMPLES` (2M samples) ("Wrap needs <n> million cells; raise Detail to <x>."). Then the time estimate: `LevelSet` at 4.6 s per million cells plus our own steps 2 to 4 (2.6.2).
  2. Unsigned distance `d` to the triangles at each sample (BVH nearest, narrow band of gap + 2 cells, larger values clamped).
  3. Outside set O = flood fill from the grid border through samples with `d > gap`.
  4. `f(x) = dist(x, O) − gap − offset` with an exact Euclidean distance transform (Felzenszwalb-Huttenlocher, linear time) over the grid. Positive inside.
  5. `ctx.LevelSet(f trilinear, bounds, edgeLength = detail, level = 0)`.
  6. `Simplify(detail / 4)` is not used (it may move sharp edges); output as is. One group `wrap0`.
- **Must hold:** closed, manifold, one or more closed components, oriented outward.
- **Warn:** sharp edges are rounded by about one cell (always add the note "Edges are rounded to about <detail>."). Deviation from the input, report max.
- **Time-out hint:** "Raise Detail."
- **Acceptance:** 5.2 #12-13.

#### 3.2.4 Rebuild (N `rebuild`, M)

Remakes a closed but messy mesh (self-intersections, overlapping shells, flipped bits) as one clean closed mesh.

- **Inputs:** Bodies.
- **Fields:** `detail` (Detail, length, default D/250, raised to fit the grid cap (2.6.2), range D/600 .. D/10, grid ≤ `MAX_VOXEL_SAMPLES` (2M)), `method` (Method: union / exact_surface, default union). On a cube-like body D/250 needs about 3.3M cells, so there the default is raised.
- **Algorithm:**
  1. Grid as in Wrap. Inside/outside per sample by **winding along +Z columns**: one ray per grid column through the BVH, sort the hits, accumulate signed crossings (sign from the triangle normal's z). Inside = winding ≠ 0. This handles overlaps and self-intersections.
  2. Signed distance = ±(unsigned distance), sign from step 1.
  3. `ctx.LevelSet` at level 0, edge length = detail.
  4. `exact_surface`: then snap output vertices to the nearest input point when that point is within detail/2 and the move keeps the output manifold (check per triangle normal flip). Union: no snap.
- **Must hold:** closed and manifold.
- **Warn:** input not closed: "<Body> has open edges; Rebuild treats them as closed by the nearest surface. Close Holes first for a better result." Volume change over 2%: report it. Rounded edges note as Wrap.
- **Acceptance:** 5.2 #14.

#### 3.2.5 Generate Face Groups (N `generate_groups`, M)

- **Inputs:** Bodies.
- **Fields:**

| Key | Label | Type | Default | Range |
|---|---|---|---|---|
| `method` | Method | enum fast / accurate | accurate | |
| `angle` | Angle Threshold (fast) | angle | 20° | 1° .. 90° |
| `tolerance` | Fit Tolerance (accurate) | length | D/2000 | D × 1e-6 .. D/20 |
| `min_size` | Smallest Group (triangles) | number | 10 | 1 .. 100,000 |

- **Algorithm:**
  - fast: flood fill across edges with dihedral angle < threshold. Then merge groups under `min_size` into the neighbour with the closest mean normal.
  - accurate: start from fast with 40°, then for each region fit plane, cylinder and sphere (`fit_primitive`). Grow regions triangle by triangle into neighbours that fit the region's primitive within the tolerance, best fit first (a priority queue). Split regions that fit nothing (rms > tolerance) by fast at 10° and retry once. Small groups merge as in fast.
  - Names: `g0..gN` by smallest triangle index (2.2.2).
- **Must hold:** every triangle in exactly one group. Triangles and positions unchanged (only groups change).
- **Warn:** groups over 100,000 refused ("Too many groups (<n>); raise the Angle Threshold or Smallest Group.").
- **Acceptance:** 5.2 #15-16 (L-bracket gives exactly 9 groups: 8 flat and 1 cylinder).

#### 3.2.6 Combine Face Groups (N `regroup`, M)

- **Inputs:** two or more groups of one body (filter `"mesh_group"`).
- **Algorithm:** all picked groups take the name of the first picked one.
- **Must hold:** triangle count and positions unchanged. Group count drops by picks − 1.
- **Acceptance:** 5.2 #17.

#### 3.2.7 Create Face Group (N `regroup`, M)

- **Inputs:** triangles of one body (triangle mode or paint).
- **Algorithm:** the picked triangles leave their groups and form a new group `user<k>`. Groups left empty are dropped.
- **Acceptance:** 5.2 #17.

### 3.3 Modify

#### 3.3.1 Direct Edit (U, M, N ops)

- An **editor tool** (action `mesh_direct_edit`), not a feature panel. It opens a small floating panel over the view, like the sketch palette.
- **Buttons:** Delete (selected triangles), Fill Holes (holes made by Delete, minimal fill), Flip (selected triangles), Extract (selected triangles to a new body), Move (a gizmo moves the selected triangles' vertices; shared border vertices move too), Done, Cancel.
- Each button applies at once to a working CadMesh (no timeline replay). Ctrl+Z inside the tool undoes the last button step (a local stack).
- **Done** writes one feature `mesh:direct_edit` holding the result blob (`options.mesh`) and the body id. One undo step "Mesh: Direct Edit". Cancel writes nothing.
- On later rebuilds the feature **replaces** the body with its snapshot. If an earlier feature's change to that body is lost because of this, the feature warns: "Direct Edit1 holds a copy of <Body>; changes made to it earlier in the timeline no longer reach it." Detect it by comparing the stored input digest with the incoming body's digest.
- **Must hold:** Delete and Extract keep the other triangles bitwise.
- **Acceptance:** 5.5 #8.

#### 3.3.2 Remesh (N `remesh`, M)

- **Inputs:** Bodies, or a triangle selection (then only those triangles change).
- **Fields:**

| Key | Label | Type | Default | Range |
|---|---|---|---|---|
| `mode` | Type | enum uniform / adaptive | uniform | |
| `density` | Density | number 0..1, uniform | 0.5 | 0.01 .. 1 |
| `edge_length` | Edge Length (overrides Density when not 0) | length | 0 | 0, or D/2000 .. D/5 |
| `min_edge` | Minimum Edge (adaptive) | length | D/1000 | > 0, < max_edge |
| `max_edge` | Maximum Edge (adaptive) | length | D/50 | ≤ D/5 |
| `approx_error` | Shape Error (adaptive) | length | D/2000 | D × 1e-6 .. D/20 |
| `iterations` | Passes | number | 10 | 1 .. 50 |
| `keep_sharp` | Keep Sharp Edges | bool | true | |
| `sharp_angle` | Sharp Edge Angle | angle | 45° | 10° .. 170° |
| `keep_boundary` | Keep Open Edges | bool | true | |
| `keep_groups` | Keep Face Group Borders | bool | true | |

  Density to edge length: `L = ē_in × 2^(2 − 4 × density)` (density 0.5 keeps about the same size, 1 is 4× finer, 0 is 4× coarser).
- **Up-front:** estimated output triangles ≈ area / (0.433 L²). Over 2,000,000: refuse "Remesh would make about <n> triangles; lower the Density."
- **Algorithm:** build a pmp `SurfaceMesh` (needs manifold input; refuse otherwise, as Close Holes). Mark `e:feature` from `detect_features(sharp_angle)` when Keep Sharp, plus group borders when Keep Groups. Selection: `v:selected` on the selection's interior vertices (pmp then locks the rest). pmp locks the rest **only when at least one vertex is selected** (2.9). So if the selection has no interior vertex, do not call pmp: it would remesh the whole body. Return the input unchanged with the warning "The selection is too small to remesh; grow it." Then the chunked schedule from C5.1: `iterations` calls of one pass each with `use_projection = false`, each followed by our BVH projection of every free, non-boundary vertex onto the **original** mesh. There is no other schedule and no fallback: this one was measured against pmp's own 10-pass call and matches it (8.1a). Group per new triangle: the group of the original triangle nearest to its centroid (borders are features, so this is exact when Keep Groups is on).
- **Must hold:** the **output-to-input** distance is at most 0.5 L for uniform, or max(0.5 L, approx_error) for adaptive. It is one-sided: sample the result and measure to the original (`result.distance_to(original)`, max). Over the limit is a fail: "Remesh moved the surface by <x> (limit <y>). Raise the Density or lower the Edge Length." Boundary loop count unchanged when Keep Open Edges. Group count unchanged when Keep Groups.
- **Warn (deviation):** the two-sided sampled Hausdorff is over 0.25 L for uniform, or over max(0.25 L, approx_error) for adaptive: "The input is rougher than the new edges; deviation <x>." This is never a failure. On a noisy scan the input-to-output part is the noise that remeshing smooths away, and it breaks 0.25 L with any method. Measured on a noisy scan-like torus at L = ē: 0.71 L two-sided but 0.32 L output-to-input, the same with pmp's own 10-pass call and with ours.
- **Warn (edge length):** mean edge length more than 20% off the target: "Edges average <x>; asked for <y> (sharp edges and borders limit it)." Measured on the L-bracket with 45° features: 7.5% under the target.
- **Time-out hint:** "Lower Passes or Density."
- **Acceptance:** 5.2 #18-20.

#### 3.3.3 Reduce (N `reduce`, M)

- **Inputs:** Bodies, or a triangle selection.
- **Fields:**

| Key | Label | Type | Default | Range |
|---|---|---|---|---|
| `target` | Reduce By | enum proportion / face_count / tolerance | proportion | |
| `proportion` | Keep (% of triangles) | number | 50 | 1 .. 99 |
| `face_count` | Triangle Count | number | T/2 | 4 .. T − 1 |
| `tolerance` | Maximum Deviation | length | D/2000 | D × 1e-6 .. D/10 |
| `method` | Method | enum adaptive / fast | adaptive | |
| `keep_boundary` | Keep Open Edges | bool | true | |
| `keep_groups` | Keep Face Group Borders | bool | true | |
| `keep_sharp` | Keep Sharp Edges | bool | false | |

- **Algorithm:**
  - **adaptive (pmp):** target vertices from Euler: closed genus g, `V* = (T* + 4 − 4g) / 2`; open, use the current ratio `V* = T* × V / T`. Mark group borders and sharp edges as `e:feature`. Run the fixed staircase of `DECIMATE_STEPS` (3) `decimate` calls (C5.1) with `aspect_ratio 10`, `normal_deviation 60°`, `hausdorff_error` = tolerance when `target == tolerance` else 0 (off). After the staircase, if the triangle count is above T* × 1.02, run up to 2 correction calls with a recomputed V*. Measured: `decimate` lands on its vertex target exactly, so the correction calls are a guard that should not run. With `target == tolerance`, decimate down to 4 vertices with the Hausdorff limit on, so the result stops where the error says.
  - **fast (meshoptimizer):** `target_index_count = 3 T*`, `target_error` = tolerance / D (relative) or 1.0 for counts. Always run it on the **welded** mesh. Never split vertices along group borders into seams.
    - Keep Groups off: `meshopt_simplify`, with the option `meshopt_SimplifyLockBorder` when Keep Open Edges.
    - Keep Groups on: `meshopt_simplifyWithAttributes` with `attribute_count = 0`, null attribute pointers and a `vertex_lock` array. Set `meshopt_SimplifyVertex_Lock` for every **group-border vertex** (a vertex whose triangles lie in two or more groups) and 0 for the rest. With Keep Open Edges, also lock every open-edge vertex, or pass `meshopt_SimplifyLockBorder`. Measured: zero border drift and the exact target count in every run. `LockBorder` alone does not keep group borders, and seams let borders drift (2.9).
    - Never pass `meshopt_SimplifyRegularize` or `meshopt_SimplifyRegularizeLight` with Keep Groups. Regularize shortened a jagged border by 22.6% (measured).
    - Group of an output triangle: the group of any of its vertices that is not a group-border vertex (such a vertex touches one group only). If all three are border vertices, the group of the input triangle nearest to its centroid, as in Remesh.
    - Guard: compare the total group-border length before and after. A change over 1% refuses Keep Groups with "Fast cannot keep face group borders on this mesh; use Adaptive." With vertex locks this should never fire. It stays as a check on our own lock array.
    - meshopt can leave a few non-manifold edges (measured: 1 to 6 on a UV sphere, with and without locks). Count them in the post-check. They are a warning, below.
  - Selection: only selected triangles may collapse. Do not rely on any selection lock inside pmp's decimate. Extract the selection as a sub-mesh, mark its border edges as features (so they stay), decimate it, then stitch it back along the unchanged border.
- **Must hold (the plan item):** for proportion and face count, the result is within **±2%** of the target count, unless features limit it (then a warning, below). Deviation ≤ the tolerance when `target == tolerance`. A closed body gets no open edges. Adaptive: closed stays closed and manifold. Group count unchanged when Keep Groups.
- **Warn:** stopped above target: "Reduce kept <n> triangles (<p>%) instead of <t>: open edges, group borders and sharp edges limit it." This is a warning, not success in silence. Fast with new non-manifold edges: "Fast left <n> edges shared by more than two triangles. Stitch and Remove can fix them, or use Adaptive."
- **Up-front:** adaptive costs about 3 s per 100k triangles for one call and cannot be stopped inside a call (2.6.2). Over the limit: refuse with the hint "Use the Fast method, or Reduce a smaller body." Fast works up to the 2M cap (measured: 1.75 s at 2M).
- **Report:** max deviation in the stat row.
- **Acceptance:** 5.3 #1 (plan item), 5.2 #21-23.

#### 3.3.4 Plane Cut (N `plane_cut`, M)

- **Inputs:** Bodies, a plane (origin, construction or planar face, or a planar mesh group). An arrow handle offsets the plane (`offset` field).
- **Fields:**

| Key | Label | Type | Default | Range |
|---|---|---|---|---|
| `type` | Cut Type | enum trim / split_body / split_faces | trim | |
| `offset` | Offset | length | 0 | −D .. D |
| `flip` | Keep Other Side | bool | false | |
| `fill` | Fill | enum none / uniform / minimal | uniform | |

- **Algorithm:**
  - **Closed body:** Manifold. Build the input MeshGL with `faceID` = group id and **one run**: `runIndex = {0, 3T}` and `runOriginalID = {id}`, where `id = Manifold::ReserveIDs(1)`. Then `ctx.FromMeshGL(mesh)` and `SplitByPlane(normal, originOffset)` (trim and split body), evaluated through `WithContext(ctx).Status()`. Manifold always closes the cut, so `fill == none` deletes the cap runs afterwards. `minimal` keeps Manifold's cap. `uniform` re-triangulates the cap with interior points on a grid of ē (Manifold `Triangulate` on the cap outline plus our own interior points and Delaunay flips).
  - **Cap detection (by ID, measured):** in each output MeshGL, a cap triangle is a triangle in a run whose `runOriginalID` is **not** the input's `id`. Manifold gives the cap of each cut a fresh run ID. All other triangles are in the input's run and keep their group through `faceID`. Cap triangles go to a new group `cut<k>`.
    - Do **not** use the cap's `faceID`. It is always 2, so it collides with group 2.
    - Do **not** detect caps by position ("3 vertices on the plane and normal ±plane normal"). When the input already has triangles on the plane, that test marks original triangles as cap (measured on a cube cut at its bottom face).
    - Keep the position test only as an assertion on the triangles found by ID. If one of them is off the plane, that is an internal error.
  - **Open body:** our own clipper. Split triangles that cross the plane, keep one side (trim) or both (split body). `fill` needs closed loops on the plane: fill each closed cut loop with the Close Holes ear-clipping fill (uniform adds interior points). Open loops stay open with a warning.
  - **split_faces:** split crossing triangles along the plane (own clipper on any body), keep everything, and put the triangles on the positive side of each crossed group into a new group `<name>_cut`. No fill.
- **Must hold (the plan item):** closed input with trim or split body and fill ≠ none gives **closed, manifold** output (0 boundary edges). Split body: the two volumes sum to the input volume within 1e-6 relative.
- **Warn:** the plane misses the body: refuse "The plane does not cut <Body>." The same refusal fires when one side comes back empty because the plane lies on an outer face (Manifold returns an empty result with no error there). Open loops on the cut of an open body: "<n> cut edges stay open (the body was open there)."
- **Time (measured, library calls):** ingest plus split takes about 2.7 s at 500k triangles and 8.4 s at 2M. The limit at 1M is 5 s (5.7).
- **Acceptance:** 5.3 #2 (plan item), 5.2 #24-27.

#### 3.3.5 Shell (N `shell`, M)

- **Inputs:** Bodies.
- **Fields:**

| Key | Label | Type | Default | Range |
|---|---|---|---|---|
| `thickness` | Thickness | length | D/50 | D/2000 .. D/4 |
| `direction` | Direction | enum inside / outside / both | inside | |
| `method` | Method | enum fast / accurate | accurate | |
| `detail` | Detail (accurate) | length | thickness/4 (raised to fit the grid cap, 2.6.2) | thickness/10 .. thickness/2, grid ≤ `MAX_VOXEL_SAMPLES` (2M) |

- **Algorithm:**
  - **fast:** offset each vertex along its angle-weighted normal by the thickness, scaled by `1 / max(0.5, cos θ)` to keep the wall close to the thickness at creases. For an open body, add a wall strip along each boundary loop. For a closed body, the inner surface is reversed and added (a hollow). That inner surface is a void with negative volume, which is correct (the nesting rule, 2.6.3). Fast does not remove self-intersections, so its post-check measures them and the wall thickness.
  - **accurate:** voxel grid (as Wrap). Signed distance with the Rebuild sign. Inside shell: `inner = ctx.LevelSet(sd − thickness)` then `body − inner` through Manifold. Outside: `outer = LevelSet(sd + thickness)` then `outer − body`. Both: band `|sd| ≤ thickness/2` directly from LevelSet. For an open body, only "both" is allowed (refuse inside/outside: "An open body has no inside; use Both, or Close Holes first.").
- **Wall check (dense):** 400 samples on the outer surface (area-weighted, fixed seed). From each, a ray along the inward normal hits the inner surface. The measured wall must be within 0.8 .. 1.2 × thickness for accurate and 0.7 .. 1.3 for fast, at 95% of samples.
- **Must hold:** closed and manifold for closed input. The wall check passes.
- **Warn (fast):** new self-intersections: "The fast shell crosses itself in <n> places; use Accurate." This is a warning because the user picked Fast. Accurate output with self-intersections is a **fail** (a bug).
- **Up-front refuse:** the thickness is more than half the body's smallest extent: "A <t> wall does not fit in <Body> (thinnest part about <x>)." Use 20 rays across the bounding box axes for the estimate.
- **Acceptance:** 5.2 #28-30.

#### 3.3.6 Combine (N `boolean` / `merge_with`, M)

- **Inputs:** target (one mesh body), tool bodies (mesh bodies, or B-rep bodies, which are tessellated at medium with the warning "<Body> was tessellated for Combine.").
- **Fields:** `operation` (join / cut / intersect / merge, default join), `keep_tools` (Keep Tools, default false), `new_body` (New Body, default false).
- **Algorithm:** join/cut/intersect: Manifold, `faceID` = global group id (target groups 0..Ga−1, then each tool's groups after them), `runOriginalID` = one ID per input from `Manifold::ReserveIDs(n)` (not a raw index: Manifold hands out its own run IDs from the same counter, 2.9). `BatchBoolean` for join of many; `Boolean` otherwise. Evaluate with `WithContext(ctx).Status()`. Groups come back by `faceID`; names follow (tools' names get a ` (2)` suffix on clashes). merge: put the triangles together with no boolean (`merge_with`), open or closed.
- **Up-front:** join/cut/intersect need closed manifold inputs: refuse with "<Body> is not closed (<n> open edges). Close Holes or Wrap it first." Total triangles over 2M: refuse.
- **Must hold:** output closed and manifold for join/cut/intersect. Volume check: join ≥ max input volume − tol, intersect ≤ min input volume + tol, cut ≤ target volume + tol (tol = 1e-6 relative).
- **Warn:** empty result: "The result is empty (the bodies do not overlap)." That is an error for intersect, and a warning for cut (the target vanished).
- **Acceptance:** 5.2 #31-33.

#### 3.3.7 Smooth (N `smooth`, M)

- **Inputs:** Bodies, or a triangle selection.
- **Fields:** `strength` (Smoothness, 0..1, default 0.5), `iterations` (Passes, 1..50, default 5), `keep_volume` (Keep Volume, default true), `keep_sharp` (Keep Sharp Edges, default false, angle 45°), `keep_boundary` (default true).
- **Algorithm:**
  - Whole body, no Keep Sharp: pmp `implicit_smoothing(mesh, timestep = strength × ē², iters = 1, uniform = false, rescale = false)`, called `iterations` times with deadline checks between.
  - Selection or Keep Sharp: our own explicit Laplacian with locks (cotangent weights clamped ≥ 0, step `strength × 0.5`), with locked vertices (outside the selection, on sharp edges, on boundaries).
  - Keep Volume: after each pass, scale about the centroid by `(V0/V)^(1/3)` for whole closed bodies. For selections, move the free vertices along their normals by the uniform amount that restores the volume (one scalar, solved in closed form).
- **Up-front:** the whole-body path is a sparse solve per pass, and its cost grows faster than the mesh (measured per pass: 0.79 s at 100k triangles, 6.79 s at 500k, 73.6 s at 2M). Use the superlinear estimate in 2.6.2, times `iterations`. Never use a linear rate. At 5 passes the working size is about 250k triangles. Over the limit: refuse with the hint below. Our own Laplacian (selection or Keep Sharp) is linear and has deadline checks.
- **Must hold:** triangle count and connectivity unchanged. Locked vertices bitwise unchanged. Volume within 0.5% when Keep Volume on a closed body.
- **Warn:** new self-intersections.
- **Time-out hint:** "Lower Passes, smooth a selection, or Reduce the body first."
- **Acceptance:** 5.2 #34-35.

#### 3.3.8 Reverse Normal (N `reverse`, M)

- **Inputs:** Bodies, or groups, or triangles.
- **Fields:** `mode` (whole / selection / auto, default auto). Auto orients each component consistently and then fixes closed components by the nesting rule (2.6.3): solid shells face outward, voids face inward.
- **Must hold:** positions unchanged. In auto, no closed component is inverted by the nesting rule: every outermost shell and every island has positive volume, and every void has negative volume. Auto on a correct hollow body changes nothing. Do not use "every closed component has positive volume": that would flip voids into solids.
- **Acceptance:** 5.2 #36.

#### 3.3.9 Erase and Fill (N `delete_triangles` + `close_holes`, M)

- **Inputs:** a triangle or group selection on one body.
- **Fields:** `fill` (minimal / smooth / flat, default smooth).
- **Algorithm:** delete the selection, then Close Holes on **only the new loops** (loops whose vertices all touch deleted triangles). Old holes stay as they were.
- **Must hold:** the new loops are closed. Triangles outside the selection are bitwise unchanged.
- **Warn:** the selection reaches an existing open edge, so a new loop merges with an old hole: "The selection touches an open edge; that hole was filled too."
- **Acceptance:** 5.2 #37.

#### 3.3.10 Mesh Align (N `fit_primitive` + `transformed`, M)

- **Inputs:** a source: a flat mesh group, or 3 points on the mesh. A target: an origin plane, construction plane or planar face.
- **Fields:** `flip` (Flip, default false), `offset` (Offset along the target normal, length, 0).
- **Algorithm:** fit a plane to the source (PCA, area-weighted). Build the rigid transform that puts the source plane's centroid on the target plane and its normal opposite the target normal (face to face; Flip makes it the same direction). The rotation about the normal keeps the smallest twist.
- **Must hold:** source group rms planarity ≤ D/1000, else refuse: "That face group is not flat (off by <x>); pick a flat group or three points." After the move, the source centroid lies on the target plane within 1e-9 m.
- **Acceptance:** 5.2 #38.

#### 3.3.11 Texture Extrude (N `displace`, M)

- **Inputs:** a selection (groups or triangles) on one body, an image file (PNG or JPG, read with `Image.load_from_file` in GDScript, sent as `PackedByteArray` luminance + width + height).
- **Fields:**

| Key | Label | Type | Default | Range |
|---|---|---|---|---|
| `image` | Image | text + Choose File | | |
| `depth` | Depth | length | D/200 | −D/10 .. D/10, ≠ 0 |
| `mapping` | Mapping | enum planar / box / cylindrical | box | |
| `tile` | Tile Size | length | D/5 | D/1000 .. 10 D |
| `angle` | Rotation | angle | 0 | −360 .. 360 |
| `invert` | Invert | bool | false | |
| `detail` | Detail (edge length) | length | tile/128 | tile/512 .. tile/8 |

- **Algorithm:** remesh the selection uniformly to `detail` (3.3.2 path, selection only). Compute each free vertex's image coordinate by the mapping. Bilinear sample of the luminance (0..1, inverted if asked). Move each vertex along its smoothed normal by `depth × value`, fading to 0 on the selection border over one ring.
- **Up-front:** new triangles ≈ selection area / (0.433 detail²). Over 2M total: refuse "Texture Extrude would make about <n> triangles; raise Detail or Tile Size."
- **Must hold:** border vertices bitwise unchanged. Closed stays closed.
- **Warn:** new self-intersections (deep extrusions on tight curves): "The extrusion crosses itself in <n> places; lower the Depth."
- **Acceptance:** 5.2 #39 (fixture: a generated 64×64 checker PNG).

#### 3.3.12 Separate (N `separate`, M)

- **Inputs:** Bodies.
- **Fields:** `by` (components / groups, default components).
- **Algorithm:** components, closed bodies: Manifold `Decompose`, then a **required** re-attach step. `Decompose` returns every void as its own part with negative volume (measured), so without this step a hollow body would fall apart into a solid and an inside-out shell.
  1. Split the parts into positive (volume > 0) and negative.
  2. Attach each negative part to the **smallest positive part that contains it** (containment as in the nesting rule, 2.6.3; smallest by volume). The two become one piece.
  3. A positive part that lies inside a void (an island) stays its own piece.
  4. A negative part that no positive part contains is an inside-out piece. Keep it as its own piece and warn: "<n> pieces are inside-out. Reverse Normal can fix them."
  Open bodies: our own edge-connected components (no voids to attach). Groups: one body per group.
- **Output:** create-style. The first piece keeps the original body id. The others are new bodies named `<Body> (2)`, `(3)`, ... ordered by smallest triangle index.
- **Must hold:** triangle count sum equals the input. Positions bitwise unchanged. No void is left alone: every negative part that some positive part contains ends in that part's piece, and that piece has positive volume.
- **Warn:** one piece only: "<Body> is one piece; nothing to separate." (feature still valid). A hollow body with one outer shell is one piece.
- **Acceptance:** 5.2 #40.

#### 3.3.13 Move/Copy (N `transformed`, M)

- **Inputs:** Bodies.
- **Fields:** the existing Solid Move fields (free move gizmo, translate X/Y/Z, rotate, point to point), plus `copy` (Create Copy, default false).
- **Algorithm:** `transformed(xform)` in doubles from the float32 positions. Copy adds a new body.
- Solid's Move/Copy on a mesh body takes the same path (`modify.gd move` branches on `is_mesh`).
- **Must hold:** a pure translation by (1, 2, 3) m moves every vertex by exactly the float32 sum (the test compares to `Vector3` arithmetic).
- **Acceptance:** 5.2 #41.

#### 3.3.14 Scale Mesh (N `transformed`, M)

- **Inputs:** Bodies, a point (default: the body's bbox centre).
- **Fields:** `uniform` (default true), `scale` (0.001 .. 1000), `sx`, `sy`, `sz` (non-uniform, same range).
- **Must hold:** volume scales by `sx·sy·sz` within 1e-6 relative.
- **Acceptance:** 5.2 #42.

#### 3.3.15 Delete

The existing action (`action delete`). Mesh bodies and selected mesh triangles both work. A triangle selection is deleted as a `mesh:direct_edit` snapshot with only a Delete step (one undo step "Mesh: Delete Triangles").

### 3.4 Convert Mesh

All three are create-style with a `result` field: `new_body` (default; the mesh body is hidden) or `replace` (the mesh body is removed). Output bodies are B-rep (no `"kind"`). Convert of a body that is not closed makes a surface body (faceted) or refuses (prismatic, organic), as each says.

#### 3.4.1 Convert Mesh: Faceted (N `to_faceted`, C)

- **Inputs:** Bodies.
- **Fields:** `merge_flat` (Merge Flat Face Groups, default true), `flat_tolerance` (D × 1e-6, range 0 .. D/100).
- **Algorithm:** `exchange::mesh_shape` (MakeShapeOnMesh, then solidify, then the sewing fallback), as Solid's Insert Mesh does today, with the Deadline progress range. Merge Flat: groups whose triangles are all within the flat tolerance of one plane become one B-rep face each (`ShapeUpgrade_UnifySameDomain` limited to those faces). Face names follow the group names (merged) or `<group>/t<k>` (per triangle).
- **Must hold (the plan item):** closed input gives one valid solid whose **volume is within 1% of the mesh volume** (expected ≤ 1e-4 relative: same triangles). T ≤ 60,000 before starting ("<Body> has <n> triangles; Convert Mesh: Faceted takes up to 60,000. Reduce it first.").
- **Warn:** open input gives a surface body: "<Body> is open, so the result is a surface body."
- **Acceptance:** 5.3 #4 (plan item), 5.4 #1-3.

#### 3.4.2 Convert Mesh: Prismatic (N `to_prismatic`, C)

For machined parts: flat faces and round holes.

- **Inputs:** Bodies with face groups (run Generate Face Groups first; a body with one group is refused: "Generate Face Groups first, so each flat or round area is its own group.").
- **Fields:** `tolerance` (Fit Tolerance, default D/1000, range D × 1e-6 .. D/20), `allow_spheres` (default true).
- **Algorithm:**
  1. For each group, `fit_primitive`: plane (PCA), cylinder (axis = smallest eigenvector of the normals' covariance, then a circle fit of the points projected on the axis plane, then 5 Gauss-Newton steps on all parameters), sphere (algebraic fit, then Gauss-Newton). Pick the simplest primitive whose max error ≤ tolerance (plane, then cylinder, then sphere).
  2. A group that fits nothing: refuse with "Face Group <n> is not flat or round within <tol> (best: cylinder, off by <x>). Use Generate Face Groups (Accurate) or Convert Mesh: Faceted."
  3. Merge coplanar planes and coaxial equal cylinders (within the tolerance) into one surface each. More than 150 surfaces: refuse ("<n> surfaces; Prismatic takes up to 150."). Then the **time estimate**, before any OCCT call: `0.01 s × surfaces + 0.25 s × crossing cylinder pairs`. A crossing pair is two cylinders whose axes are not parallel and pass within r1 + r2 of each other. Over `time_limit`: refuse "Convert Mesh: Prismatic would take about <n> s on <Body> (limit <limit> s): <p> pairs of round holes cross. Use Convert Mesh: Faceted." The surface cap alone does not bound the time. Measured: 150 surfaces take 0.9 s when no cylinders cross and 45 s with about 200 crossing pairs (about 0.22 s per pair).
  4. Make each surface a large bounded face (bbox grown by 50%). `BOPAlgo_MakerVolume` on all faces, with the Deadline range and `run_bounded`. Steps 4 to 6 share **one** Deadline.
  5. Pick the cells **inside that same Deadline** (check it for every cell). For each cell, take 5 interior points: triangulate the cell's faces (`BRepMesh_IncrementalMesh` with the Deadline range), take one triangle centroid from each of up to 5 different faces, largest faces first (a cell with fewer faces gives more triangles from its largest face), and move each centroid into the cell along the inward face normal by a small step (start with 1e-3 × the cell's bbox diagonal; C tunes it). Keep the cell when our `winding_inside` says at least 4 of the 5 are inside the mesh. **Never** use `BRepClass3d_SolidClassifier` on random sample points here: it cost another 7.5 to 10.5 s on the crossing-hole part (measured).
  6. Fuse kept cells (with the glue option, since the cells share faces exactly), `ShapeUpgrade_UnifySameDomain`, `ShapeFix`. Name each face after the group whose primitive it lies on. Measured: on a 150-surface plate with no crossing holes, steps 4 to 6 take 1.5 s and give one valid solid.
- **Must hold:** one valid closed solid. Volume within 0.5% of the mesh volume. Sampled distance from the mesh to the result ≤ 3 × tolerance (2,000 samples). Face types match the fits (8 planes + 1 cylinder on the L-bracket).
- **Time-out hint:** "Combine face groups to make fewer surfaces, or use Faceted." (The crossing-hole refusal in step 3 has its own sentence.)
- **Acceptance:** 5.4 #4-6.

#### 3.4.3 Convert Mesh: Organic (experimental; C, with the Phase 6 Form code)

For smooth sculpted shapes. It may refuse. The panel shows "(experimental)" in the title.

- **Inputs:** one closed mesh body, ≤ 200,000 triangles. Step 1 is a Remesh, so Remesh's up-front budget applies (2.6.2: about 200k triangles at 10 passes, less after the 1.5× factor). Near the cap it may refuse. Then pass Remesh's refusal on with the hint "Reduce the body first (Fast method)."
- **Fields:** `faces` (Target Cage Faces, default 500, range 24 .. 5,000), `output` (form_body / brep, default brep), `tolerance` (Allowed Deviation, default D/500).
- **Algorithm (GDScript in `core/mesh/organic.gd`, native calls only):**
  1. `remesh` uniform to an edge length that gives about 2 × faces triangles (L from the area).
  2. `CAGE.merge_triangle_pairs(cage, 30.0)` to make mostly quads (`core/form/cage.gd`).
  3. `FORM_FIT.mesh_to_cage(points, faces, {"merge": true, "tolerance": ...})`, then fit the cage so its limit surface passes near the original: `CadSubD.interpolate` at the cage vertices' closest points on the original mesh (as `ui/form_tools_modify.gd _mesh_to_form` does today; reuse that code, don't copy it: move the shared part into `core/form/` if needed, and tell the Form owners).
  4. Measure: `CadSubD.tessellate` at rate 8, then `distance_to` both ways against the original mesh.
  5. form_body: a new Form feature with this cage (one undo step). brep: `CadSubD.to_shapes` (Phase 6 pipeline), one valid closed solid.
- **Must hold:** brep: one valid closed solid. Deviation max ≤ 4 × tolerance, else refuse: "The smooth surface is up to <x> away from the mesh (allowed <y>). Raise Target Cage Faces or Allowed Deviation." Deviation between tolerance and 4 × tolerance is a warning with the number.
- **Acceptance:** 5.4 #7-8.

### 3.5 Shared groups on mesh bodies

#### 3.5.1 Display Mesh Face Groups (Utilities > Display, and Shift+F in Mesh)

- A view-only toggle (action `mesh_face_groups`). Not in the timeline, no undo.
- On: each mesh body draws each group in a colour from `mesh_group_palette` (8 colours). Colours come from a **greedy graph colouring** of the group adjacency (neighbours differ), in group order, so they are stable.
- Group borders draw in `mesh_group_border`, open edges in `mesh_boundary`. Off: plain `mesh_surface`.
- **Acceptance:** 5.5 #6.

#### 3.5.2 Inspect, Insert, Construct, Assemble

- Measure: picks on mesh groups give `face_info`. A flat group measures like a plane. Distances use `ray_hit` points.
- Section Analysis: `CadMesh.section` lines, drawn as today.
- Interference: between mesh bodies, Manifold intersect volume. Between a mesh and a B-rep: the B-rep is tessellated (medium) with a note.
- Center of Mass: `mass_properties`. Open bodies show the thin-shell warning.
- Construct: planes from flat mesh groups work through `face_info` (`type == "plane"`). Axes through mesh cylinders are not in Phase 7 (refuse "Pick a B-rep face; mesh groups give only planes.").
- Assemble (Phase 8): no change.

### 3.6 Selection tools (U, N queries)

| Tool | Action | Behaviour |
|---|---|---|
| Select Face Groups | `mesh_pick_groups` | Pick mode groups (toggle, shows as pressed) |
| Select Triangles | `mesh_pick_triangles` | Pick mode triangles |
| Grow Selection | `mesh_grow` | `grow(tris, 1)`. In group mode, adds the neighbour groups |
| Shrink Selection | `mesh_shrink` | `shrink(tris, 1)` |
| Select Connected | `mesh_connected` | `connected(tris, 30°)`; Shift+click on the tool uses 180° |
| Select Boundary | `mesh_boundary` | selects the triangles along open edges near the selection, or all boundary loops when nothing is selected |

All six are disabled outside the Mesh workspace and when no mesh body exists.

---

## 4. Stages, teams and file ownership

Each team touches **only** its files. A file needed by two teams has one owner, and the other team asks.

### Stage N0 (team N, alone): link and smoke

- **Files:** `N\CMakeLists.txt`, `N\src\register_types.cpp`, `N\src\cad_mesh.h/.cpp` (empty class with `library_versions()`, `is_mesh()`), `A\licenses\*` (7), `tests\holo_forge_native_smoke_test.gd` (add the CadMesh line).
- **Acceptance:**
  - Reconfigure and build succeed. `A\bin` gains `pmp.dll`, `manifold.dll`, `meshoptimizer.dll` and nothing else new.
  - The smoke test prints the four library versions and passes.
  - All 37 existing tests, all 8 hooks (one per process) and validate_project (6 known) pass. Grep for `SCRIPT ERROR`, `Parse Error`, `signal 11`.
  - The editor starts with the plugin on, with no new output lines.

### Stage N1 (team N): data, IO, queries

- **Files:** `cad_mesh.*`, `mesh_data.h/.cpp` (MeshData, blob, validate, compact, digest), `mesh_io.cpp` (STL, OBJ), `mesh_query.cpp` (check, boundary loops, section, components, the nesting rule of 2.6.3), `mesh_bvh.h/.cpp` (reuse `subd_bvh.h`'s `holo_forge::subd::Box/Bvh` by including it; do not fork it), `mesh_budget.h`, `mesh_deadline.h`, `mesh_tessellate.cpp` (`from_shape`, `tessellate()` contract), `tests\holo_forge_mesh_native_test.gd` (part 1), `tests\holo_forge_mesh_fixtures.gd`.
- **Acceptance:** 5.1 #1-14 pass. 1M-triangle STL read and `tessellate()` timings recorded (5.7).

### Stage G1 (team G, after N1): integration and the gate

- **Files:** `A\core\mesh\mesh_blob.gd`, `A\core\mesh\mesh_body.gd`, `A\core\features\mesh.gd` (handler skeleton, cache, `tessellate` method only), `A\core\features\insert.gd` (kind option), `A\core\features\util.gd` (gate), `A\core\references.gd`, `A\core\operations.gd`, `A\core\features\modify.gd` (move, remove branches), `A\core\regen.gd`, `A\core\tessellate.gd`, `A\core\picking.gd`, `A\core\analysis.gd`, `A\core\appearance.gd`, `A\core\export.gd`, `A\nodes\cad_part.gd`, `A\plugin.gd` (externalize call only), `tests\holo_forge_mesh_gate_test.gd`.
- **Acceptance:** 5.6 all pass. Every existing test still passes (old documents unchanged).

### Stage 2 (three teams in parallel)

#### N2: pmp and meshoptimizer ops
- **Files:** `mesh_pmp.cpp/.h` (SurfaceMesh build/back, features, selection props), `mesh_remesh.cpp`, `mesh_reduce.cpp`, `mesh_fill.cpp` (close holes: our own minimal triangulation, ear clipping, patch refine, pmp `fair` on a local sub-mesh; no `fill_hole`), `mesh_smooth.cpp`, `mesh_groups.cpp` (generate, regroup, fit_primitive), `mesh_clean.cpp` (stitch and remove, reverse), test part 2 in `holo_forge_mesh_native_test.gd` (append a section; N owns the file).
- **Acceptance:** 5.1 #15-26. Rate constants measured and written to `mesh_budget.h`. Start from the spike's numbers (2.6.2). Also measure what the spike did not: the 3-step decimate staircase, pmp `fair` on a hole sub-mesh, our own hole triangulation, and every whole op with its post-check.

#### N3: Manifold and voxel ops
- **Files:** `mesh_manifold.cpp/.h` (MeshGL in/out, faceID mapping, error text, watchdog), `mesh_voxel.cpp/.h` (grid, unsigned distance, winding columns, EDT), `mesh_cut.cpp` (plane cut, own clipper), `mesh_shell.cpp`, `mesh_wrap.cpp` (wrap, rebuild), `mesh_boolean.cpp`, `mesh_separate.cpp`, `mesh_displace.cpp`.
- N2 and N3 both edit `cad_mesh.cpp` bindings. Rule: N2 binds in `bind_pmp_methods()`, N3 in `bind_manifold_methods()`, both called from `_bind_methods`. Each team owns its function.
- **Acceptance:** 5.1 #27-36. Rate constants as N2. Also measure what the spike did not: a cancel during `ctx.FromMeshGL` (8.1 row 23), and our own distance field and distance transform per million cells.

#### U: specs, catalog, panels, selection, theme, icons
- **Files:** `A\tools\feature_specs.gd`, `A\tools\catalog.gd`, `A\tools\feature_command.gd` (stat row, mesh picks), `A\ui\forge_workspace.gd` (actions, browser, context menu), `A\ui\forge_viewport.gd`, `A\ui\mesh_selection.gd` (new: the selection model), `A\ui\mesh_display.gd` (new: group colours, overlays), `A\ui\mesh_direct_edit.gd` (new), `A\ui\timeline.gd`, `A\ui\forge_theme.gd`, `A\icons\tools\mesh\*.svg`, `tests\holo_forge_editor_test.gd` (flip the "Remesh greyed out" check, see 5.8).
- **Acceptance:** every Mesh tool is enabled and opens its panel. The catalog test and the toolbar tests pass. Theme switch has no errors.

### Stage 3 (two teams in parallel)

#### M: tool wiring
- **Files:** `A\core\features\mesh.gd` (every method but convert), `tests\holo_forge_mesh_tools_test.gd`, `tests\holo_forge_mesh_test.gd`, `tests\holo_forge_mesh_editor_checks.gd`.
- **Acceptance:** 5.2 and 5.3 all pass.

#### C: Convert Mesh
- **Files:** `N\src\mesh_convert.cpp/.h` (faceted, prismatic), `A\core\mesh\organic.gd`, `A\core\features\mesh_convert.gd` (preloaded by `mesh.gd`; M adds the one dispatch line on C's request), `tests\holo_forge_mesh_convert_test.gd`.
- **Acceptance:** 5.4 all pass. Measure the Prismatic time estimate (2.6.2) again inside the real op, with the cell pick.

### Stage 4: hook, polish and an adversarial verifier

- **U:** `tests\holo_forge_mesh_editor_test.gd`, `plugin.gd` hook line. 5.5 passes headless, and once windowed with screenshots.
- **V (verifier, a fresh agent that did not write the code):** tries to break each tool with the adversarial fixtures (5.0) and hand-made cases: huge inputs, open inputs, zero-area triangles, flipped halves, self-intersections, extreme field values, undo/redo during preview, save and reload. Every finding gets a failing test first, then a fix by the owning team.
- **Final check (any team, last):** build; every headless test; all 9 hooks one per process; validate_project; grep for `SCRIPT ERROR`, `Parse Error`, `signal 11`.

---

## 5. Acceptance tests (numbers to assert)

Every headless test:
- extends `SceneTree`, runs from `_init() -> call_deferred("run")`;
- uses preload consts only;
- prints exactly one `PASS holo_forge_<name>: ...` or `FAIL holo_forge_<name>` line plus the failure reasons, and the PASS line lists what was checked;
- calls `quit(0|1)`;
- skips native checks with a printed note when `ClassDB.class_exists("CadMesh")` is false (they must not skip on the dev machine);
- calls `MESH_FEATURE.clear_cache()` before each case that measures time.

### 5.0 Fixtures (`tests/holo_forge_mesh_fixtures.gd`, a helper, not a test)

Pure GDScript, deterministic, no random without a fixed seed. Each function returns `{"positions": PackedVector3Array, "indices": PackedInt32Array (Godot winding), "groups": PackedInt32Array, "names": PackedStringArray}` in meters. `write_stl(fixture, path)`, `write_obj(fixture, path)` and `write_png_checker(path, size)` write into `user://holo_forge_mesh_fixtures/`.

| Function | Shape |
|---|---|
| `icosphere(r, s)` | r = 0.05 m, s = 5 gives 20,480 triangles; s = 4 gives 5,120 |
| `holed_blob()` | icosphere s = 4, r = 0.05, displaced radially by `0.004·sin(3θ)·cos(2φ) + 0.002·sin(5φ)`, then 5 holes removed (triangles within geodesic disks of 3, 5, 8, 12 and 20 mm around fixed points). Also returns `reference` = the same blob before the holes |
| `l_bracket()` | built in the kernel: an L profile 60 × 40 × 10 mm extruded 30 mm, a 10 mm through hole, then `CadMesh.from_shape` high. 9 groups: 8 planes, 1 cylinder (check the face count; if OCCT splits the hole into 2 faces, it is 10 and the tests use the real count) |
| `cube_debris()` | a 20 mm cube (12 triangles, welded) plus 30 tiny triangles 0.01 mm away, 5 duplicate triangles, one fin triangle on an edge, 3 vertices split by 1e-7 m |
| `two_cubes(offset)` | two 20 mm cubes, the second moved by `offset` |
| `open_plate()` | a 40 × 40 mm grid plate, 32 × 32 squares, open |
| `flipped_half()` | icosphere s = 3 with every triangle with z < 0 flipped |
| `self_crossing()` | two icospheres s = 3 of r = 0.02 with centres 0.02 apart, merged into one mesh with no boolean |
| `large_grid(n)` | a closed box with n × n quads per face (n = 290 gives about 1M triangles), for timing |
| `hollow_cube(island)` | a 20 mm cube with a 10 mm cube-shaped void at its centre. The void's 12 triangles face **inward** (into the void), so the mesh volume is 7,000 mm³. 24 triangles, 2 closed components. With `island = true`, also a 4 mm cube inside the void (36 triangles, 3 components, 7,064 mm³) |
| `with_noise(fixture, sigma)` | the fixture with every vertex moved along its normal by Gaussian noise of `sigma` × ē (fixed seed) |
| `crossing_holes()` | built in the kernel: a 60 × 60 × 30 mm block with 2 through holes along Z and 2 along X, each X hole crossing both Z holes (4 crossing cylinder pairs), then `CadMesh.from_shape` high |
| `write_png_checker(path, 64)` | an 8 × 8 black and white checker |

### 5.1 `tests/holo_forge_mesh_native_test.gd` (N)

| # | Check | Assertion |
|---|---|---|
| 1 | `set_arrays` on icosphere s4 | true, T = 5,120, V = 2,562, G = 1 |
| 2 | Validation | index out of range, NaN, wrong groups length, a second `set_arrays`: each false with a non-empty `get_last_error()` naming the problem |
| 3 | Winding | `tessellate()` indices of a cube equal Godot order: the same orientation test as `CadShape.tessellate` of `kernel.make_box` (signed volume of the Godot-order triangles has the same sign) |
| 4 | Blob round trip | `to_blob` → `from_blob` gives equal arrays (bitwise) and equal `digest()`. Flip one byte: false, error says "CRC" |
| 5 | Blob layout | header bytes match 2.2.3 for a 1-triangle mesh (exact byte count 24 + 36 + 12 + 4 + 2 + 2 + 4) |
| 6 | STL read | binary and ASCII cube from `tests/holo_forge/cube_10mm.stl` with scale 0.001: closed, T = 12, V = 8 after welding. A binary STL whose header starts with `solid` reads as binary |
| 7 | OBJ read | `cube_2cm.obj` gives 12 triangles. An OBJ with a concave pentagon gives 3 triangles with positive area |
| 8 | `check()` | icosphere: closed, manifold, oriented, genus 0. `open_plate`: boundary_loops 1, boundary_edges 128. `cube_debris`: degenerate, duplicate and non-manifold counts as built. `self_crossing`: self_intersections > 0. `hollow_cube(false)`: closed, closed_components 2, inverted_components 0, oriented, `solid_count()` 1, volume 7,000 mm³ within 1e-6 relative. The same with the void's triangles flipped: inverted_components 1. `hollow_cube(true)`: inverted_components 0, `solid_count()` 2 |
| 9 | Volume and area | icosphere s5: volume within 1e-6 relative of the exact polyhedron volume computed in GDScript (doubles); area likewise |
| 10 | `ray_hit` | from (1, 0, 0) toward −X on the icosphere: distance = 1 − (hit x) within 1e-6, normal · (1,0,0) > 0.99 |
| 11 | `section` | icosphere at z = 0: one closed polyline; every point within 1e-6 m of z = 0; every point's radius between r·cos(θ/2) and r, where θ is the fixture's largest edge angle |
| 12 | `from_shape` | `kernel.make_box(0.02, 0.02, 0.02)`: 6 groups named like the box faces, closed, volume 8e-6 within 1e-9 |
| 13 | `distance_to` | a mesh to itself: max ≤ 1e-9. Icosphere s4 vs s5: max within 10% of the analytic sagitta bound |
| 14 | Budgets | a 2,000,001-triangle `set_arrays` refuses before allocating more than the input (error names 2,000,000) |
| 15 | `remesh` uniform | icosphere s4 (a clean fixture), edge length 2 mm: mean edge within 10% of 2 mm, two-sided deviation ≤ 0.5 mm (0.25 L), no deviation warning, closed. `with_noise(icosphere s4, 0.2)` at L = ē: a result, not a failure; output-to-input ≤ 0.5 L; the deviation warning is present exactly when the two-sided deviation is over 0.25 L, and it carries that number |
| 16 | `remesh` keeps groups | L-bracket: same group count and names; every group border edge of the result lies within 1e-6 of an original border |
| 17 | `reduce` adaptive 50% | icosphere s5: T within ±2% of 10,240; Hausdorff (both ways) ≤ 0.05 mm; closed |
| 18 | `reduce` fast 50% | same, ±2%, or a warning whose numbers match the result. 0 open edges. Non-manifold edges only together with the warning that counts them. With Keep Groups on an icosphere s5 split into two groups at z = 0: ±2%, 2 groups, every group-border vertex bitwise unchanged, border length change ≤ 1e-6 relative |
| 19 | `reduce` tolerance | icosphere s5, tolerance 0.01 mm: deviation ≤ 0.01 mm and T < 20,480 |
| 20 | `close_holes` | holed blob: closed, 0 boundary edges, original triangles bitwise unchanged |
| 21 | `close_holes` big hole | a 600-edge hole (the ear-clipping path): closed |
| 22 | `stitch_and_remove` | cube_debris → 12 triangles, closed, report counts match the fixture. `hollow_cube(false)` with the defaults: 24 triangles, volume still 7,000 mm³ (the void is not flipped). With the void's triangles flipped on input: the void is flipped back, volume 7,000 mm³ |
| 23 | `generate_groups` | L-bracket after merging its groups into one: accurate gives the original group count; fast 20° gives the same count |
| 24 | `fit_primitive` | the hole group: cylinder, radius within 0.5% of 5 mm, axis within 0.1° |
| 25 | `smooth` | icosphere s4 with noise: volume within 0.5% with Keep Volume; triangle count unchanged |
| 26 | Time-out | `remesh` on `large_grid(290)` with `time_limit = 0.05`: returns null within 1.05 s, error says "would take about" or "took longer than". One pass on 1M triangles is several seconds and cannot be stopped, so the op must not start it |
| 27 | `boolean` | two_cubes(10 mm): join volume = 12,000 mm³ within 1e-6 relative; cut 4,000; intersect 4,000; all closed |
| 28 | `boolean` groups | join keeps both inputs' group names; no group lost |
| 29 | `plane_cut` closed | icosphere s5 at z = 0.01 m, trim, fill uniform: closed, manifold; volume within 0.5% of π h²(3r − h)/3 with h = 0.04. Caps by ID: the 6-group box of #12 cut at half height, trim, fill minimal: one new group `cut0` whose triangles all lie on the plane; the 5 remaining face groups keep their names and none of their triangles is in `cut0`. The same box cut exactly on its bottom face: refused with "does not cut" |
| 30 | `plane_cut` split | the two parts' volumes sum to the input within 1e-6 relative |
| 31 | `plane_cut` open | open_plate cut by x = 0: two open parts; triangle areas sum to the input within 1e-9 |
| 32 | `wrap` | holed blob, detail 1 mm, gap 3 mm: closed; volume within 3% of the reference blob |
| 33 | `rebuild` | self_crossing: closed, manifold, 0 self-intersections; volume within 2% of the union volume (computed with `boolean` join of the two spheres) |
| 34 | `shell` accurate | icosphere s5 inside, 2 mm: closed; wall check 0.8..1.2 t at ≥ 95% of samples |
| 35 | Manifold cancel | `boolean` of two `large_grid` boxes with `time_limit = 0.05`: null within 1.05 s; error says "took longer than" or "would take about". It must not run to the end of the boolean (a single boolean cancels in about 45 ms) |
| 36 | `separate` | two_cubes(30 mm) merged: 2 meshes of 12 triangles each. `hollow_cube(false)`: 1 mesh of 24 triangles, volume 7,000 mm³ (the void stays with its outer shell). `hollow_cube(true)`: 2 meshes, 24 triangles at 7,000 mm³ and 12 triangles at 64 mm³ |

### 5.2 `tests/holo_forge_mesh_tools_test.gd` (M; through features and `regen`, not native calls)

For each row: build the fixture as an Insert Mesh feature (kind mesh, from the MeshBlob), add the tool feature with the listed options, `regen.rebuild`, then assert. Every case also asserts "no error, and warnings exactly as listed".

| # | Tool and case | Assertion |
|---|---|---|
| 1 | Insert Mesh STL, kind mesh | one mesh body, `kind == "mesh"`, T = 12 |
| 2 | Insert Mesh, kind missing (old feature) | a B-rep solid, as before (the old `positions`/`indices` path) |
| 3 | Insert Mesh linked | changing the file and rebuilding changes the body (digest differs) |
| 4 | Insert Mesh open file | warning names the open edges and Close Holes |
| 5 | Tessellate box | 6 groups, closed, volume within 1% |
| 6 | Tessellate Keep Original off | the B-rep body is gone from `result.bodies` |
| 7 | Section Sketch | a sketch feature with ≥ 1 closed profile whose area is within 1% of the section polygon area |
| 8 | Close Holes all | closed; warning-free |
| 9 | Close Holes Largest Hole 50 | the 20 mm hole stays open; warning counts it |
| 10 | Stitch and Remove | cube_debris → 12 triangles |
| 11 | Stitch: Remove Small off | the debris triangles remain (degenerate and duplicates are still removed) |
| 12 | Wrap | closed; note about rounded edges present |
| 13 | Wrap over budget | detail D/1000: refused fast (≤ 0.2 s) with "million cells" |
| 14 | Rebuild | self_crossing → closed, 0 self-intersections |
| 15 | Generate Face Groups | L-bracket single-group → 9 groups (or the real count, 5.0) |
| 16 | Generate stable names | rebuilding twice gives the same names in the same order |
| 17 | Combine / Create Face Group | counts as in 3.2.6 and 3.2.7 |
| 18 | Remesh | mean edge within 10%. On a clean fixture: two-sided deviation ≤ 0.25 L and no deviation warning |
| 19 | Remesh selection | triangles outside the selection bitwise unchanged |
| 20 | Remesh over budget | Density 1 on large_grid(290): refused before work |
| 21 | Reduce 50% | ±2% (also in 5.3) |
| 22 | Reduce Keep Groups on L-bracket | groups unchanged; if above target, the warning text has the real numbers |
| 23 | Reduce face count 100 on the cube | refuses or warns honestly (the cube has 12 triangles; face_count range check: "Triangle Count must be between 4 and 11.") |
| 24 | Plane Cut trim + fill | closed (also in 5.3) |
| 25 | Plane Cut Fill None | boundary edges = the cut loop's edge count |
| 26 | Plane Cut Split Body | 2 bodies, `options.outputs` has 2 ids; rebuild keeps the ids |
| 27 | Plane Cut misses | error "does not cut". The same error with the plane on an outer face of a cube |
| 28 | Shell accurate | wall check passes |
| 29 | Shell fast on a concave fixture | either passes the wall check or warns with the self-intersection count; never neither |
| 30 | Shell too thick | refused up front, message has the thinnest size |
| 31 | Combine join | volume as 5.1 #27 |
| 32 | Combine with a B-rep tool | works with the tessellation warning |
| 33 | Combine open target | refused with "is not closed" |
| 34 | Smooth Keep Volume | volume within 0.5% |
| 35 | Smooth selection | locked vertices bitwise unchanged |
| 36 | Reverse Normal auto on flipped_half | the one closed component has positive volume. Auto on `hollow_cube(false)`: no triangle changes (outer shell positive, void negative, volume 7,000 mm³) |
| 37 | Erase and Fill | new loop closed, the old holes unchanged |
| 38 | Mesh Align | the source group centroid on the target plane within 1e-9 m, normals opposite within 1e-6 |
| 39 | Texture Extrude on the open plate | max displacement = depth within 1%, border bitwise unchanged |
| 40 | Separate | two_cubes merged → 2 bodies. `hollow_cube(false)` → 1 body with the "one piece" warning. `hollow_cube(true)` → 2 bodies |
| 41 | Move/Copy | exact float32 translation; Copy adds a body |
| 42 | Scale Mesh | volume × 8 for scale 2 within 1e-6 relative |
| 43 | Gate | Solid Fillet on a mesh body: error is exactly the gate text with the body name |
| 44 | Range refusal | every numeric field of every mesh spec, set to (min − ε) and (max + ε): refused with the field's name in the text (loop over `feature_specs`) |
| 45 | Cache | a second rebuild of the same document takes < 10% of the first (ratio), and returns `is_same` CadMesh instances |
| 46 | Refusal cache | a refused Wrap rebuilt twice: the second rebuild takes < 5% of the first |
| 47 | Smooth over budget | whole-body Smooth, 5 passes, on large_grid(290): refused before work (≤ 0.2 s) with "would take about" (the estimate is superlinear) |
| 48 | Reduce over budget | Adaptive 50% on large_grid(290): refused before work (≤ 0.2 s). Fast 50% on the same body: works, ±2% |

### 5.3 `tests/holo_forge_mesh_test.gd` (M; the Phase 7 acceptance test, `holo_cad_mesh_test` in the plan)

| # | Plan item | Assertion |
|---|---|---|
| 1 | Reduce to 50% hits the target ±2% with Hausdorff under tolerance | icosphere s5 (20,480 tris), Reduce proportion 50 adaptive, tolerance field 0.05 mm: T in [10,036, 10,444] (10,240 ± 2%); Hausdorff both ways ≤ 0.05 mm (20,000 samples); closed |
| 2 | Plane Cut with Fill gives a watertight result | icosphere s5, plane z = 10 mm, Trim, Fill Uniform: `check()` closed, manifold, 0 boundary edges, oriented; volume within 0.5% of the cap formula. Repeat with Split Body: both parts closed |
| 3 | Make Closed fixes a holed bunny-like fixture | `holed_blob`, Close Holes all, Smooth fill: closed, manifold, 0 boundary edges; volume within 1% of `reference`; original triangles bitwise unchanged |
| 4 | Faceted convert volume within 1% of the mesh volume | icosphere s4 and the L-bracket, Convert Mesh: Faceted: one valid solid each; \|V_brep − V_mesh\| / V_mesh ≤ 0.01 (expected ≤ 1e-4; print the real value) |
| 5 | Save and reload | the document of #1-4 saved to `user://` as `.tres` and reloaded: the rebuild gives the same digests |

### 5.4 `tests/holo_forge_mesh_convert_test.gd` (C)

| # | Check | Assertion |
|---|---|---|
| 1 | Faceted, Merge Flat | the L-bracket mesh gives faces = 8 merged planes + the cylinder's triangle faces; valid solid |
| 2 | Faceted cap | a 60,001-triangle mesh: refused with "Reduce it first" before OCCT runs (≤ 0.2 s) |
| 3 | Faceted open | open_plate gives a surface body with a warning |
| 4 | Prismatic L-bracket | one valid closed solid; 9 faces (8 `plane`, 1 `cylinder` from `face_info`); hole radius within 0.5%; volume within 0.5% of the original B-rep |
| 5 | Prismatic one group | refused with "Generate Face Groups first" |
| 6 | Prismatic no fit | the icosphere with groups from fast 20°: refused naming a group and its best fit error |
| 7 | Organic sphere | icosphere s5, 200 faces, brep: one valid solid; deviation ≤ 4 × tolerance; reported |
| 8 | Organic form body | output form_body adds a Form feature whose cage has ≤ 5,000 faces |
| 9 | Prismatic crossing holes | `crossing_holes` with `time_limit = 1.0`: refused before any OCCT call (≤ 0.2 s); the text has the estimate and "4 pairs" (0.25 s × 4 pairs plus the surfaces is over 1 s) |

### 5.5 Editor hook `--holo-forge-mesh-editor-test`

Use real input events (`root.push_input`) for every click and key, as the Phase 6 lessons say.

1. Open `res://tests/holo_forge/forge_editor_test.tscn`, `set_main_screen_editor("Forge")`, `ws.add_part_to_scene()`. Do not save the scene.
2. Switch to the Mesh workspace with the switcher (a real click). Every Mesh tool in the catalog is enabled except those still at phase > 7.
3. Mesh > Create > Insert Mesh with the generated `user://.../holed_blob.stl` (set the path field, OK). One mesh body in the browser with the `ArrayMesh` icon. The open-edge warning is on the feature.
4. Close Holes (all), OK: the body has 0 open edges; one undo step. Undo restores 5 holes. Redo closes them.
5. Click on the body in group mode: one group selected (overlay mesh visible). Switch to triangle mode, click: one triangle. Grow twice: 1 + ring counts.
6. Shift+F: group colours on; the material set changes; neighbours differ in colour. Shift+F again: off.
7. Reduce panel: type 50 in Keep; the stat row shows the preview numbers within 1 s; OK; ±2% on the body.
8. Direct Edit: select 10 triangles, Delete, Fill Holes, Done: one `mesh:direct_edit` feature; one undo step.
9. Plane Cut with a construction plane; drag the arrow handle with real mouse events; OK: closed.
10. Convert Mesh: Faceted on a reduced copy: a B-rep body appears; Solid > Fillet on it is allowed; Solid > Fillet on the mesh body flashes the gate text.
11. Theme dark, then light: no errors; mesh materials take the new tokens.
12. Save a copy of the scene to `res://tests/holo_forge/_mesh_hook_tmp.tscn` with a ≥ 256 KB blob: the `_forge` folder gets one `_mesh_<digest>.res`; reload the copy; same digest. Delete the copy and its `_forge` folder at the end.
13. Run `tests/holo_forge_mesh_editor_checks.gd` (M): one in-editor scenario per Mesh tool, each asserting one undo step and no script errors.
14. Performance (ratio method): hover pick on `large_grid(290)` ≤ 4 ms target.

### 5.6 `tests/holo_forge_mesh_gate_test.gd` (G)

1. Every Reader path in `util.gd`, `references.gd` and `operations.gd` returns the gate text for a mesh body (one case per function).
2. Every `allow_mesh` path works on a mesh body: move, copy, remove, appearance by body and by group name, measure, center of mass, interference, section analysis, zebra, export STL/OBJ/3MF (exact triangle count), bake (a MeshInstance3D with the same triangle count), collision faces.
3. Every refused analysis returns its sentence (curvature map, minimum radius, isocurve, comb, decals, STEP export lists the mesh body as skipped).
4. Old documents: every fixture document under `tests/holo_forge/` loads and rebuilds with the same body count and volumes as before (compare with values computed by the same test on the old code path, recorded in the test).
5. MeshBlob: embedded below 256 KB, externalized above, digest checked on load, a damaged file gives the checksum error.
6. Undo: `snapshot()` then `restore()` keeps the blob. Assert `is_same(snapshot blob, original blob)`: `duplicate(true)` shares Resource values (2.2.4), so undo holds no second copy. Also assert equal content.
7. Without the DLL (simulate by a handler call with `ClassDB.class_exists` false through a test seam): the feature error is "The Holo Forge mesh kernel is not loaded".

### 5.7 Timing method

- Use `tests/holo_forge_timing.gd compare(op, calibration)`.
- Native calibration: `kernel.make_sphere(...)` then `CadShape.tessellate(...)`. GDScript calibration: a fixed 200k-iteration float loop.
- At implementation time, measure each op on the dev machine. Set the ratio limit to 2 × the measured ratio. Put the measured milliseconds and the ratio in the test's comment.
- `HOLO_FORGE_TIMING_SLOWDOWN=3` must make each timing check fail. Check that once.
- Limits to meet on the dev machine (Ryzen 9 5900HX, single thread). The **Spike** column is **measured** (8.1a): the library call only, one run, ±15%. The **Limit** is for the whole op, with our own code and the post-check. **Status** says what is measured and what is still a target. Change a limit only with a note in the report.

| Op | Spike (measured, library call only) | Limit (whole op) | Status |
|---|---|---|---|
| `read_stl` 1M triangles | not measured | ≤ 1.5 s | target, unmeasured |
| `tessellate()` 1M triangles | not measured | ≤ 0.8 s | target, unmeasured |
| `ray_hit` on 1M (BVH built) | not measured | ≤ 4 ms | target, unmeasured |
| `check()` 1M | not measured | ≤ 1.5 s | target, unmeasured |
| Reduce fast 1M → 50% | 0.60 s at 500k, 1.75 s at 2M (about 1 s at 1M) | ≤ 2 s | measured, met |
| Reduce adaptive 100k → 50% | 3.08 s as one call, 5.09 s as 8 calls | ≤ 6 s | measured. The 3-step staircase itself is not measured; it lies between the two |
| Reduce adaptive 1M → 50% | one call: 9.54 s at 500k, 50.3 s at 2M. About 45 s at 1M as 8 calls (estimated) | no time limit: it must be **refused up front** in ≤ 0.2 s (5.2 #48) | measured. The old target "≤ 15 s" cannot be met and is dropped |
| Remesh uniform 100k, 10 passes | 9.05 s (output 115k triangles) | ≤ 12 s | measured. The old 10 s limit was met by under 1 s, which is inside the ±15% spread, so the limit is now 12 s |
| Boolean join 2 × 200k | about 1.8 s with ingest (the spike's estimate; the measured points are 0.6 s at 100k and 1.7 s at 500k total triangles, ingest plus union) | ≤ 3 s | measured, met |
| Wrap at 2M cells | `LevelSet` alone: 5.7 s at 2.1M cells (128³) | ≤ 15 s | `LevelSet` measured; our distance field and distance transform are not. The old row "Wrap at 4M cells ≤ 15 s" is dropped: `LevelSet` alone took 14.8 to 18.0 s at 3.9M cells, and the grid cap is now 2M |
| Plane Cut 1M | ingest plus split: 2.7 s at 500k, 8.4 s at 2M. About 4.4 s at 1M (estimated) | ≤ 5 s | measured at 500k and 2M. The old target "≤ 3 s" was missed |

- The spike timed library calls only. A whole op adds building the library mesh (pmp `SurfaceMesh`: 52 ms / 278 ms / 834 ms at 100k / 500k / 2M), our BVH (naive: 0.3 / 0.7 / 2.1 s to build) and the post-check (up to 1 s for self-intersections). If a whole op misses its limit only because of that overhead, report the split. Do not skip the post-check to meet a limit.
- Sizes that no longer have a timing row because the op refuses there (2.6.2): Reduce adaptive above about 400k triangles, Remesh at 10 passes above about 200k, whole-body Smooth at 5 passes above about 250k. Test the refusal, not the time.

### 5.8 Existing tests to update

- `tests/holo_forge_editor_test.gd` (about line 77) checks that "Phase 7 Mesh tools (Remesh) should stay greyed out". Change it to check a Phase 8 tool (for example `solid.assemble.joint`) instead. Grep all tests for `mesh.` tool ids and `IMPLEMENTED_PHASE` and fix any other phase-7-disabled assumption the same way.
- `tests/holo_forge_native_smoke_test.gd`: add the CadMesh class and `library_versions()` check.
- `tests/holo_forge_import_test.gd`: no change. It must still pass (old Insert Mesh path).

---

## 6. Visual spec (both Forge themes)

### 6.1 New `ui/forge_theme.gd` tokens

Add after `"form_warning"`, in the **same order** in DARK and LIGHT, with a comment line like the Form block.

| Token | DARK | LIGHT |
|---|---|---|
| `mesh_surface` | `Color(0.55, 0.58, 0.63)` | `Color(0.68, 0.71, 0.76)` |
| `mesh_wire` | `Color(0.85, 0.88, 0.94, 0.25)` | `Color(0.10, 0.12, 0.16, 0.22)` |
| `mesh_group_border` | `Color("#e6e9ef")` | `Color("#22262e")` |
| `mesh_boundary` | `Color("#ff5d8f")` | `Color("#c2185b")` |
| `mesh_selected` | `Color(0.12, 0.45, 1.0, 0.55)` | `Color(0.06, 0.33, 0.90, 0.55)` |
| `mesh_hover` | `Color(0.60, 0.80, 1.0, 0.25)` | `Color(0.55, 0.80, 1.0, 0.32)` |
| `mesh_preview` | `Color("#57e389")` | `Color("#13994a")` |
| `mesh_removed` | `Color(1.0, 0.35, 0.42, 0.30)` | `Color(0.85, 0.10, 0.18, 0.25)` |
| `mesh_fill` | `Color("#ffb347")` | `Color("#c26a00")` |
| `mesh_warning` | `Color("#ffd23f")` | `Color("#a87a00")` |
| `mesh_group_palette` | 8 colours: `#7aa2f7 #9ece6a #e0af68 #bb9af7 #7dcfff #f7768e #73daca #c0caf5` | `#2e5cb8 #3d7a1f #9a6a10 #6b3fc2 #0f7fa8 #b3263e #1f8a70 #4a5378` |

`mesh_group_palette` is an `Array` of `Color` (check that the theme code tolerates a non-Color value; if not, store 8 tokens `mesh_group_0..7` instead).

### 6.2 Materials (built in `ui/mesh_display.gd`, rebuilt on `apply_theme`)

- Surface: the existing body material, flat-looking because of the split normals at sharp edges.
- Group colours: one `StandardMaterial3D` per palette colour, unshaded off, roughness as the body material. Built by splitting the body mesh into up to 8 surfaces by colour (not per group).
- Borders and boundary: line meshes with `mesh_group_border` (1 px) and `mesh_boundary` (drawn twice as wide through the 2D overlay polyline, like Form creases).
- Selection overlay: `face_subset_mesh` with `mesh_selected`, depth test on, a small polygon offset toward the camera.
- Preview: removed parts in `mesh_removed` (Plane Cut kept-away side, Erase selection), fills in `mesh_fill`.

### 6.3 Icons (new, original)

House style: 24×24 viewBox, stroke 1.6, round caps and joins, ink `#dfe3ea`. Mesh accent: `#e0a526` (the existing mesh icons use it; check `remesh.svg` and match). Other accents in use: `#22b8cc`, `#d14fc0`, `#f05a5a`, `#8d74f0`, `#3fb26a`.

| File | Drawing |
|---|---|
| `A\icons\tools\mesh\shell.svg` | a triangulated dome outline (5 triangles) with a parallel inner outline in the accent, 2 px apart. The Solid `shell.svg` stays for Solid. |
| `A\icons\tools\mesh\combine.svg` | two overlapping triangulated circles (3 visible chords each), the overlap filled with the accent at 0.35 opacity |
| `A\icons\tools\mesh\select_face_groups.svg` | a 3 × 2 triangle strip, two adjacent triangles filled in the accent, a small arrow cursor at the lower right |
| `A\icons\tools\mesh\select_triangles.svg` | the same strip, one triangle filled, the cursor |
| `A\icons\tools\mesh\grow_selection.svg`, `shrink_selection.svg`, `select_connected.svg`, `select_boundary.svg` | the strip with outward arrows, inward arrows, a flood ring, and a dashed outer edge in `mesh_boundary` pink `#ff5d8f` |

`toolbar.gd` looks in `ICON_DIR + slug(workspace) + "/" + file` first, so `icons/tools/mesh/*.svg` overrides the shared one in the Mesh workspace only. Make sure Godot imports each new SVG (`.import` files appear after the editor scans).

**Originality check:** before committing, put each new icon side by side with the other app's closest icon (from memory or the user's screenshots, never downloaded art) and redraw any that look close. Report which you compared.

---

## 7. Licensing

LGPL code stays in its own DLLs (OCCT `TK*.dll`, `planegcs.dll`). The three new libraries are permissive and also ship as their own DLLs. Add these files to `A\licenses\` (copy the text exactly; do not edit it):

| New file | Copy from | Notes |
|---|---|---|
| `pmp-library-MIT.txt` | `V\share\pmp-library\copyright` (all 54 lines) | "MIT License with employer disclaimer", copyright the Polygon Mesh Processing Library developers |
| `Manifold-Apache-2.0.txt` | `V\share\manifold\copyright` (all 201 lines) | Apache 2.0. The source has no NOTICE file, so none is needed. Its AUTHORS file is not a licence requirement |
| `meshoptimizer-MIT.txt` | `V\share\meshoptimizer\copyright`, **only** the `LICENSE.md` MIT block (the lines from "MIT License" through "SOFTWARE.", about lines 6-26, "Copyright (c) 2016-2026 Arseny Kapoulkine") | The rest of that file covers gltfpack's vendored code, which we do not ship |
| `Clipper2-BSL-1.0.txt` | `V\share\clipper2\copyright` (23 lines) | Inside manifold.dll (static). Add a first line "Clipper2 2.0.1, Copyright Angus Johnson 2010-2025 (from clipper.h), used by Manifold." The Boost licence text is already present for Boost, but Clipper2 needs its own attribution line |

No other licence changes. Eigen (MPL-2.0) is already present and pmp uses it header-only.

---

## 8. Risks, decisions and open questions

### 8.1 Risks and decisions

| # | Risk or question (confidence) | Decision |
|---|---|---|
| 1 | pmp version label: vcpkg says 3.0.0, the source and CMake config say 2.0.1 (high, checked) | Build against the signatures in C8. `library_versions()` reports the port version with a note. Re-check the signatures if the port is updated |
| 2 | pmp needs manifold input and throws on complex vertices (high). **Confirmed by the spike (8.1a row 2)** | Our own cleanup before every pmp call, and `try/catch`. Refuse with "Run Stitch and Remove first" |
| 3 | pmp has no cancel hook (high). A single chunk is seconds long on a big mesh (measured, C5.1 layer 3) | Chunked calls with a fixed schedule plus up-front budgets (C5.1). Never start a chunk that would end after the deadline |
| 4 | pmp remesh in single passes with our own projection against pmp's own 10-pass call. **Resolved (8.1a row 4):** they match within 10% on every mesh, and ours is faster | Keep the C5.1 schedule. There is no fallback. Chunking with pmp's own projection measured worse and is forbidden |
| 5 | Does Manifold cancel only between sub-booleans? **Resolved (8.1a row 5):** no. A single boolean cancels within about 45 ms and `LevelSet` within about 22 ms | The watchdog bounds Manifold booleans and level sets (C5.1 layer 4). The up-front budget stays only to refuse fast. The ingest is row 23 |
| 6 | Manifold may collapse edges shorter than its tolerance. **Resolved (8.1a row 6):** with `tolerance = 0` no triangle is dropped | Keep `MeshGL.tolerance = 0`. The post-check reports triangle count changes. Faces with different `faceID` keep their shared edges |
| 7 | Manifold's cap faces after `SplitByPlane`. **Resolved (8.1a row 7):** caps get a fresh `runOriginalID`; their `faceID` is always 2 | Detect caps by `runOriginalID` (3.3.4). Never by `faceID`, never by position |
| 8 | Manifold `Decompose` and void shells. **Resolved (8.1a row 8):** every void comes out as its own part with negative volume | The re-attach step in Separate is required (3.3.12). Every orientation rule uses the nesting rule (2.6.3) |
| 9 | meshopt keeping group borders. **Resolved (8.1a row 9):** seams let borders drift and `LockBorder` ignores them; vertex locks on the welded mesh keep borders exactly | `meshopt_simplifyWithAttributes` with `vertex_lock`, no seams, no Regularize (3.3.3). The border-length check stays as a guard |
| 10 | Float32 storage (high) | Fine for meshes (0.12 µm at 1 m). All math in doubles inside ops. Faceted convert reads float32 into doubles, so B-rep vertices are float32-exact |
| 11 | Large meshes in scenes (high) | Sidecar MeshBlob files above 256 KB (2.2.4). Content-named, so undo and save stay cheap |
| 12 | `Dictionary.duplicate(true)` and Resources in Godot 4.7.1. **Resolved (8.1a row 12):** it shares them; `duplicate_deep` copies them | Keep `duplicate(true)` in `snapshot()` (2.2.4). G1 asserts `is_same` (5.6 #6) |
| 13 | `BOPAlgo_MakerVolume` cost with about 150 large faces. **Resolved (8.1a row 13):** the cost goes by crossing cylinder pairs (about 0.22 s per pair), not by the face count | Cap 150 plus an up-front estimate by crossing pairs (3.4.2 step 3). The Deadline range stops it on time. The cell pick stays inside the Deadline and does not use OCCT's solid classifier (3.4.2 step 5) |
| 14 | Organic convert quality (medium) | Experimental label, deviation check, refusal above 4 × tolerance |
| 15 | GDScript picking on big meshes (high) | Native `ray_hit` for mesh bodies |
| 16 | The main thread blocks during OK (high) | Accepted, as in Phase 6. The 20 s cap bounds it. Background threads are a follow-up |
| 17 | Direct Edit breaks the history chain (high, by design) | Snapshot feature with a warning (1.2) |
| 18 | VCOMP140.DLL for pmp (high, present in System32). **Confirmed (8.1a row 18)** | Note it in the smoke test output. Exported games do not load the extension |
| 19 | Tessellate has no max edge length (high, OCCT). **Confirmed (8.1a row 19)** | No field; a note pointing to Remesh |
| 20 | Reduce ±2% with features locked. **Resolved (8.1a row 20):** pmp and meshopt hit the target exactly in every run | Correction calls stay as a guard, then an honest warning (never silent). A 3-step staircase, not 8 |
| 21 | Timing numbers. **Partly resolved (8.1a row 21 and its timing table):** the library calls are measured; three old targets were missed and are replaced (5.7) | Budgets start from the measured numbers (2.6.2). Our own code, whole ops and the first four rows of 5.7 are still unmeasured (row 24) |
| 22 | pmp `fill_hole` cannot give a minimal fill, wipes `v:selected` and costs O(V) per hole (high, measured and read in the source; 8.1a "C8 extra") | Not used. Our own triangulation, and pmp `fair` on a local sub-mesh for the smooth fill (3.2.1) |
| 23 | A cancel during Manifold ingest (`ctx.FromMeshGL`) was not timed (medium, **unverified**) | The up-front estimate of every Manifold op includes the ingest (C5.1 layer 4). N3 measures the cancel |
| 24 | Costs the spike did not time: the 3-step decimate staircase, pmp `fair` on a hole sub-mesh, our own hole triangulation, our distance field and distance transform, and whole ops with their post-checks (medium, **unverified**) | Provisional numbers in 2.6.2 and 5.7. N2 and N3 measure them and report |
| 25 | Remesh on a noisy scan breaks a two-sided 0.25 L limit with any method (high, measured; 8.1a row 4) | Fail only when the output-to-input distance is over 0.5 L. Warn above 0.25 L two-sided (3.3.2) |
| 26 | meshopt can leave a few non-manifold edges (high, measured; 8.1a row 9) | The post-check counts them. Reduce (Fast) keeps the result with a warning that counts them (3.3.3) |
| 27 | The slow tools cannot reach the 2M cap in 20 s (high, measured; 8.1a timing consequence 1) | Up-front refusals with a way out, and working sizes in 2.6.2. See 8.2 question 2 |
| 28 | The nesting rule on shells that cross each other (medium, **unverified**) | Mixed containment answers count as "not contained" (2.6.3). The verifier tests `self_crossing` through Stitch and Remove and Reverse Normal: neither sphere may be flipped |

### 8.2 Open questions for the user (do not block on them; the defaults above apply until the user answers)

1. **Insert Mesh default.** Should Solid > Insert > Insert Mesh also make mesh bodies by default (as the other app does), or keep making faceted solids? Default here: keep solids outside the Mesh workspace, so old habits and tests stay.
2. **Triangle cap.** Is 2,000,000 triangles per body enough for the user's scans and models? Larger caps need background threads. Measured since: a body can be that big, but the slow tools cannot work on it in 20 s. Reduce (Adaptive) works up to about 400k triangles, Remesh (10 passes) to about 200k and whole-body Smooth (5 passes) to about 250k. Fast Reduce, Combine and Plane Cut work up to 2M. So the usual path for a big scan is Reduce (Fast) first. Is that acceptable, or should `OK_SECONDS` be raised for these tools?
3. **Organic convert.** Is an experimental Organic convert worth shipping in Phase 7, or should it wait for a quad remesher (for example a vendored MIT one, as noted in Phase 6 risk 19)?
4. **Direct Edit as a snapshot.** Is it fine that Direct Edit stops earlier changes from reaching the body (with a warning)? The other option is to refuse Direct Edit on bodies that have history before it.
5. **Prismatic surfaces.** Planes, cylinders and spheres only. Are cones and tori needed now?
6. **Face group colours.** The palette in 6.1 is ours. Does the user want a different look?

---

## 9. Report back (every team, end of stage)

- The stage and team, and the files touched. **Confirm you touched no file outside your list.**
- The PASS/FAIL lines of every test run, new and old, plus `validate_project.gd` and the hooks (one per process).
- Measured timings and ratios (5.7), and the rate constants written to `mesh_budget.h`.
- Answers to the unverified items in 8.1 that your stage covers (rows 23, 24 and 28). The spike already answered rows 4 to 9, 12, 13 and 18 to 20 (8.1a). If your measurement differs from the spike, report both numbers.
- Any contract you had to question, with your counter-proposal. Do not change a contract on your own.
- For the icon work: which icons you compared for originality and what you redrew.

---

## 8.1a Spike results (2026-11-11)

**Status: evidence record only.** Every consequence in this section is folded into the body (revised 2026-11-11). The body is the instruction. Where the "Consequence for the spec" column or the "Timing consequences" list gives a choice, the body has made it. If this section and the body ever differ, follow the body and report the difference.

A research spike measured the unverified rows of 8.1 before any Phase 7 code was written. Nothing in **A**, **N** or the build tree was touched.

- **Spike program:** `C:\Users\Blaze\AppData\Local\Temp\claude\4dcecb28999dc62d\201f9237-6a81-4e60-8b92-09865c66cf8d\scratchpad\phase7_spike` (`CMakeLists.txt`, `src\*.cpp`, raw output in `results\*.txt`, Godot probe in `godot_probe\`). It is a scratch folder and may be cleaned, so the numbers below are the record.
- **Build:** standalone CMake + MSVC 19.38, Release, linked straight against **V** (`CMAKE_PREFIX_PATH`, no vcpkg toolchain, so nothing was installed): pmp-library (port 3.0.0), Manifold 3.5.4, meshoptimizer 1.3 (1030), OCCT 8.0.1.
- **Machine:** the dev machine (Ryzen 9 5900HX, 16 threads, 64 GB). Every time below is single-threaded unless it says "parallel". Times are wall clock from one run; expect ±15%.
- **Test meshes:** closed bumpy tori sized to 100k / 501,760 / 1,998,090 triangles (genus 1). Icospheres s4 to s6, plain and bumpy. A noisy, anisotropic, scan-like torus (3:1 triangles, normal noise σ = 0.2 ē). An L-bracket (two boxes minus two 96-segment holes, refined to a CAD-like tessellation with slivers down to 0.01°). UV spheres and tori with face groups.

### Answers

| 8.1 row | Question | Answer (measured) | Evidence | Consequence for the spec |
|---|---|---|---|---|
| 9 | Does meshopt keep face-group borders when the groups are split into seams? | **Yes for topology, with a small chord drift. Vertex locks keep borders exactly.** Split seams: 0 triangles mix groups, group count kept, 0 new border vertices, on 3 meshes at 50% and 10%. Seam vertices still collapse *along* the border, so curved borders are re-chorded. `meshopt_SimplifyLockBorder` has **no effect on seams**: results are identical with and without it. It locks only open edges. `meshopt_simplifyWithAttributes(attribute_count = 0, vertex_lock = meshopt_SimplifyVertex_Lock on every group-border vertex)` on the **welded** mesh gives **zero drift** and still hits the target exactly. | Seams, worst case (10%): border drift ≤ 0.056% of the bbox diagonal (1.9e-3 on D ≈ 3.4), border length change −0.003% to −0.071%. Vertex lock: drift 1e-16, length change 0.000%, 100.0% of the target count in all 6 runs. Welded with no locks: border length +54% to +154%. `Regularize` with seams on a jagged border: −22.6% border length (fails the 1% check). Open sphere at 10%: open edges 400 → 400 with LockBorder, 400 → 117 without. The UV sphere output had 1 to 6 non-manifold edges near the poles in every variant without Regularize. (`results\q1_meshopt.txt`) | **3.3.3 fast, Keep Groups, must change:** replace "split vertices along group borders before the call (borders become attribute seams), then weld back" with "call `meshopt_simplifyWithAttributes` on the welded mesh with `vertex_lock = Lock` on every group-border vertex (and on open-edge vertices, or `LockBorder`, when Keep Open Edges)". Never pass `Regularize` with Keep Groups. Keep the 1% border-length check as a guard. The refusal sentence stays, but should never fire. **2.9 meshoptimizer:** add "LockBorder ignores attribute seams; use `vertex_lock`" and "the output can contain non-manifold edges; the post-check must count them". Row 9 is closed. |
| 7 | What `faceID` / `runOriginalID` do the caps from `SplitByPlane` / `TrimByPlane` get? Can caps be found by ID? | **Yes, by `runOriginalID`. Not by `faceID`.** Every cap triangle sits in a run whose `runOriginalID` is a **fresh ID** that matches no input. Each cut call makes a new one: the first cut's cap is 4 and a second cut on that piece gives 9, with the first cap still 4. Input runs keep their own `runOriginalID` and `faceID`. The cap `faceID` was **always 2** (6 cases, with and without input faceIDs), so it can collide with group 2. Geometric detection is **wrong** when the input already has faces on the plane: trimming a cube at its bottom-face plane flags 2 original triangles (faceID 104, input run) as cap. `TrimByPlane` keeps the side the normal points to. A plane on the top face gives an empty result with status NoError. | Icosphere s4, faceIDs 0/7, `runOriginalID` set from `ReserveIDs`. Split at z = 0.3: cap 172 tris, run id 4, faceID 2, on both halves. Volumes: the two halves sum to the input with rel. diff 0.0. Cube with faceIDs 100..105, oblique trim: cap run 19, faceID 2. Note: `OriginalID()` of a MeshGL-built Manifold returns −1 even when `runOriginalID` is set, but output runs carry the value we set. (`results\manifold_caps.txt`) | **3.3.4 Cap detection must change:** "Give the input MeshGL one `runOriginalID` from `Manifold::ReserveIDs(1)` (`runIndex = {0, 3T}`). Cap triangles are those in output runs whose `runOriginalID` is not the input's. Do not use the cap `faceID` (always 2)." Keep the on-plane test only as an assertion on the triangles found by ID. Also, `fill == none` deletes the cap runs. **8.1 row 7** is closed. **2.9 Manifold:** add the cap-ID facts. The refusal "The plane does not cut <Body>" must also fire when one side is empty because the plane lies on a face. |
| 8 | How does `Decompose` handle void shells? | **Voids come out as separate manifolds with negative volume** (an inside-out shell, status NoError). They do not stay with their outer shell. An island solid inside a void is its own positive part. `FromMeshGL` also accepts a lone inverted shell (NoError, volume −1). | Hollow cube 2 − 1: parts +8 and −1. Hollow sphere: +4.165 and −0.896. Hollow cube + sphere in the void: +8, −1, +0.111. Two hollow cubes + one solid: 5 parts. (`results\manifold_decompose.txt`) | **3.3.12** must make the re-attach step part of the algorithm, not a fallback: "attach each negative-volume part to the smallest positive part that contains it (`winding_inside` on a vertex); parts inside a void stay separate bodies". Spec contradictions this exposes (a void shell is its own edge-connected component with negative signed volume): **2.6.3** orientation check ("closed components with negative signed volume: warn n parts are inside-out") must skip components enclosed by a positive one (odd nesting depth). **3.2.2 step 4** ("Flip closed components with negative volume") would flip voids into overlapping solids: it must flip only components whose nesting depth parity is wrong. **3.3.8 auto** "Must hold: every closed component has positive volume" must read "every outermost component positive, every void negative". |
| 4 | Does one pass at a time with our own projection match pmp's own 10-pass call? | **Yes.** B = 10 × `uniform_remeshing(L, 1, false)`, each followed by our BVH nearest-point projection of every non-boundary vertex onto the original. It matches A = `uniform_remeshing(L, 10, true)` within the 10% rule on every mesh, and is 3% to 37% faster. On smooth inputs B even gives A's exact connectivity. The 8.1 fallback C (5 × 2 passes with pmp's projection) is **worse** than B: 1.06× to 2.05× A's Hausdorff on the clean meshes (about equal on the noisy one), and 1.1× to 1.6× slower. 10 × 1 passes with pmp's projection (D) is worse again: the reference is re-copied from the drifting mesh each call, which the source confirms (`Remeshing::preprocessing` builds `refmesh_` and a kd-tree per call). Repeated runs of remesh and decimate are **bitwise identical**. **New problem:** on the noisy scan, both A and B break 3.3.2's "deviation ≤ 0.25 L". | Bumpy icosphere s6 at L = ē: A and B have the same connectivity, vertices within 1.8e-6, Hausdorff 0.017 L both. Icosphere s4: identical stats. L-bracket with 45° features, L = ē: mean edge 0.03755 / 0.03756 (−7.5% vs target), Hausdorff 1.100e-3 / 1.101e-3, min angle 20.90° / 21.18°. At L = ē/2: Hausdorff 3.33e-4 / 3.88e-4. Noisy torus at L = ē: min angle 33.27° / 33.22°, two-sided Hausdorff **0.714 L / 0.738 L**, output→input 0.317 L / 0.305 L. At L = 2ē: min angle 31.83° / 28.91° (−9%), two-sided 0.425 L / 0.449 L, output→input 0.256 L / 0.263 L. The input→output part is input noise that remeshing smooths away. (`results\q4_pmp_remesh.txt`, `results\q4_pmp_remesh_onesided.txt`, `results\pmp_det.txt`) | **Row 4 is closed.** Keep the C5.1 schedule and delete the fallback ("use pmp's projection with iterations = 2 chunks"). **3.3.2 Must hold must change:** a two-sided sampled Hausdorff ≤ 0.25 L fails on any noisy scan, whatever the method. Proposed: **fail** only when output→input max > 0.5 L. **Warn** with the number when the two-sided max exceeds 0.25 L ("The input is rougher than the new edges; deviation <x>"). Acceptance 5.2 #18-20 must use clean fixtures for the 0.25 L assertion. |
| 13 | How long does `BOPAlgo_MakerVolume` take with about 150 large planar/cylindrical faces? | **It depends on cylinder-cylinder crossings, not on the face count.** Synthetic plate 200 × 100 × 20 with a pocket (11 planes) and vertical through holes: 150 surfaces in **0.91 s** (0.71 s parallel). The full Convert Prismatic chain (MakerVolume, cell pick, fuse with glue, `UnifySameDomain`) takes 1.5 s and gives 1 valid solid. Add 14 horizontal holes that cross the vertical rows: 100 surfaces take **28.1 s**, 150 take **44.8 s** (29.8 s parallel). About **0.22 s per crossing cylinder pair** (≈120 pairs at N = 100, ≈200 at N = 150). In that case, picking the cells with OCCT's solid classifier costs another 7.5 to 10.5 s. The existing Deadline progress indicator stops MakerVolume on time. | Vertical only: N = 50 / 101 / 151 → 0.29 / 0.58 / 0.91 s, with 96 / 198 / 318 cells. Mixed: N = 100 → 28.1 s, 530 cells. N = 150 → 44.8 s, 794 cells, total chain 56.8 s. Deadline 1.0 s → stopped at 1015 ms. Deadline 0.2 s → stopped at 200 ms. (`results\q5_occt.txt`, `results\q5_occt_deadline.txt`) | **2.6.2 `MAX_PRISMATIC_SURFACES = 150` is safe only without crossing cylinders.** Add an up-front estimate to **3.4.2** step 3: `0.01 s × surfaces + 0.25 s × (pairs of non-parallel cylinders whose axes pass within r1 + r2)`, refused against `time_limit`. The time bound itself holds through the Deadline range. **3.4.2 step 5** must sit inside the same Deadline and must not call `BRepClass3d_SolidClassifier` per random sample (seconds on curved cells). Take interior points from each cell's face triangulation, offset inward, then test them with our `winding_inside`. Row 13 is closed. |
| 21 / 5.7 | Timings at 100k, 500k, 2M | See the timing table below. **Met:** Reduce fast, Boolean join 2 × 200k, Remesh 100k (just). **Missed:** Reduce adaptive 1M, Wrap at 4M cells, Plane Cut 1M (about 4 s, estimated). Smooth and Close Holes are far slower than their budgets assume. | Table below. (`results\q6_timing_*.txt`, `results\q6_levelset_sweep.txt`) | See "Timing consequences". |
| 5 | Manifold cancels only between sub-booleans? | **No. A single boolean cancels within about 45 ms.** `LevelSet` cancels within 22 ms. | 2 × 1M-triangle union (5.3 s uncancelled): `Cancel()` at 50 ms → `Status() = Cancelled` returned at 95 ms. At 300 ms → returned at 335 ms. `ctx.LevelSet` at 158³: cancel at 0.5 / 2 / 6 s → returned at 0.512 / 2.011 / 6.022 s. (`results\manifold_cancel.txt`, `results\manifold_lscancel.txt`) | **C5.1 layer 4 and 8.1 row 5:** delete "so one single boolean may run to its end. The up-front budget must therefore cover a single boolean". The watchdog bounds Manifold ops to about 50 ms over the limit. Keep the up-front budget only to refuse fast (Phase 6 lesson 6). |
| 6 | Does `MeshGL.tolerance = 0` keep every triangle? | **Yes.** The baseline tolerance is 1e-12 × the bbox scale (1e-15 at r = 1 mm, 1e-9 at r = 1 km). No triangle was dropped by `FromMeshGL`, by a union or by `SplitByPlane`, even with 1e-7 m edges or 5 m × 3 mm slivers. | Icosphere s5 at r = 1e-3 / 1 / 1e3, a torus with 400 edges of 1e-7 m and 1e-5 m, a 2000-segment CAD cylinder: input = ingest = union triangle counts. (`results\manifold_tolerance.txt`) | Row 6 is closed. Keep `tolerance = 0`. |
| 12 | Does `Dictionary.duplicate(true)` copy Resource values (Godot 4.7.1)? | **No. It shares them.** This holds at the top level, nested in Dictionaries and inside Arrays, for built-in blobs and for blobs loaded from a `.res`. `duplicate_deep(Resource.DEEP_DUPLICATE_INTERNAL)` and `DEEP_DUPLICATE_ALL` do copy (`DEEP_DUPLICATE_NONE` shares). Also confirmed: zstd `compress`/`decompress` round trip; a text `.tres` uses `format=4` and stores `PackedByteArray("…base64…")`. | Headless `--script` in a throwaway project, 1 MB blob: `is_same(copy.mesh, blob) == true` in all six cases. (`godot_probe\probe.gd`, `godot_probe\out.txt`) | **2.2.4 Undo:** snapshots share blobs, so undo costs no blob memory. Keep using `duplicate(true)`. Never switch `snapshot()` to `duplicate_deep(INTERNAL/ALL)`, which would copy every blob. G1 can assert `is_same` instead of only recording it. Row 12 is closed. |
| 18 | VCOMP140.DLL | **Confirmed.** `pmp.dll` imports `VCOMP140.DLL` (present in System32). `manifold.dll` and `meshoptimizer.dll` import only the MSVC runtime and KERNEL32 (no TBB). | dumpbin `/dependents` | None. |
| 19 | Tessellate max edge length | **Confirmed absent.** `IMeshTools_Parameters` has Angle, Deflection, AngleInterior, DeflectionInterior, MinSize and flags, but no maximum edge length. | header | None. |
| 20 | Reduce ±2% with features locked | **Target hit exactly** in every case measured. pmp `decimate` on the L-bracket with 45° features at 50% and 10% of the vertices: V on the target to the vertex (+0.00%), with 1 call and with the 8-call staircase. meshopt: 100.0% of the target in all 30 Q1 runs. | `results\pmp_dec.txt`, `results\q1_meshopt.txt` | Keep the correction calls as a guard. The staircase costs 1.6× to 2.6× one call (below) and is not needed for accuracy. |
| 2 | pmp exceptions on bad input | **Confirmed.** A third face on one edge → `TopologyException` "SurfaceMesh::add_face: Complex edge.". `fill_hole` on an interior halfedge → `InvalidInputException` "fill_hole: Not a boundary halfedge.". | `results\pmp_exc.txt` | None. |
| C8 extra | pmp `fill_hole` behaviour (source + measurement) | `fill_hole` does **not** stop at the minimal triangulation. It always runs triangulate, then 10 rounds of split/collapse/flip/relax inside the patch, then `minimize_curvature` fairing. It added 522 to 26,017 vertices per hole. It writes **and then removes** a `v:selected` property (any caller's `v:selected` is lost). It marks every vertex and edge of the **whole mesh** as locked first, so each hole has an O(V + E) cost. Original vertices are bitwise unchanged and the hole closes (0 open edges). | Source `hole_filling.cpp` (`HoleFilling::fill_hole`, `refine`, `fairing`). Timing table below. | **3.2.1 must change:** pmp `fill_hole` cannot give "minimal" (step 2) or the patch our step 3 refines. Use our own minimal-area triangulation for **minimal** and **flat**, and for the first stage of **smooth**. Use pmp only as a whole "smooth" fill if wanted. Run any pmp hole call on a **local sub-mesh** (the hole loop plus about 3 rings) to remove the O(V) per-hole cost. Lower the pmp hole limit from 400 edges to about 200 unless the sub-mesh timing says otherwise. **2.9 pmp:** add these facts, plus "Remeshing locks unselected vertices only when at least one vertex is selected". |
| C8 extra | CMake | pmp's imported target does **not** carry Eigen's include path: a consumer without `Eigen3::Eigen` fails with "Cannot open include file: 'Eigen/Dense'". | spike build | No change for **N** (it already links `Eigen3::Eigen`). Add a note to the 2.9 CMake block. |

### Timing table (dev machine, single thread)

| Op (library call) | 100k | 500k | 2M | 5.7 target | Verdict |
|---|---|---|---|---|---|
| pmp `SurfaceMesh` build (`add_triangle`) | 52 ms | 278 ms | 834 ms | | |
| pmp `decimate` → 50% triangles, 1 call | 3.08 s | 9.54 s | 50.3 s | | |
| pmp `decimate` → 50%, 8-call staircase (C5.1) | 5.09 s | 24.4 s | 78.3 s | Reduce adaptive 1M ≤ 15 s | **Missed** (1M about 45 s, estimated) |
| `meshopt_simplify` → 50% (LockBorder: same cost) | 47 ms | 0.60 s | 1.75 s | Reduce fast 1M ≤ 2 s | Met (about 1 s) |
| pmp `uniform_remeshing` 10 passes (own projection) | 9.05 s | 37.7 s | (not run) | Remesh 100k, 10 passes ≤ 10 s | Met, just (output 115k triangles) |
| one remesh pass (no projection) + our BVH projection | 1.08 + 0.31 s | 2.25 + 1.21 s | 5.54 + 2.78 s | | 2M × 10 passes ≈ 83 s |
| pmp `implicit_smoothing`, 1 iteration | 0.79 s | 6.79 s | **73.6 s** | | Superlinear (sparse solve) |
| Manifold `FromMeshGL` (ingest) | 0.30 s | 0.87 s | 2.77 s | | Counts in every Manifold op |
| Manifold union, 2 × N/2 (after ingest) | 0.31 s | 0.87 s | 3.50 s | Boolean join 2 × 200k ≤ 3 s | Met (about 1.8 s with ingest) |
| Manifold subtract, 2 × N/2 | 0.41 s | 0.47 s | 2.50 s | | |
| Manifold `SplitByPlane` (after ingest) | 0.94 s | 1.80 s | 5.61 s | Plane Cut 1M ≤ 3 s | **Missed** (1M about 2.8 s + 1.6 s ingest) |
| pmp `fill_hole`, 100-edge hole | 0.46 s | 1.14 s | 4.89 s | | O(V) per hole |
| pmp `fill_hole`, 400-edge hole | (n/a) | 5.61 s | 8.68 s | | |
| pmp `fill_hole`, 800-edge hole | (n/a) | 27.9 s | **152.9 s** | | |
| Manifold `LevelSet` at 3.9M cells (158³), sphere or trilinear-grid SDF | | | | Wrap at 4M cells ≤ 15 s | **Missed** by `LevelSet` alone (14.8–18.0 s in 4 runs) |

`LevelSet` by grid (cells per axis over the box, cost not tied to triangle count): 64³ 0.26M cells 0.5–0.7 s; 100³ 1.0M 2.0–2.5 s; 128³ 2.1M 5.7 s; 150³ 3.4M 7.3 s; 158³ 3.9M 14.8–18.0 s; 180³ 5.8M 13.4 s; 200³ 8.0M 12.3–15.0 s; 256³ 16.8M 24.2 s. The cost does **not** rise steadily with the cell count. SDF calls ≈ 2 × cells (body-centred grid). `canParallel` makes no difference (no TBB).

Other measured costs: `BOPAlgo_MakerVolume` (row 13 above). Our naive BVH: build 0.3 / 0.7 / 2.1 s and one nearest-point query per vertex 0.3 / 1.2 / 2.8 s (an optimized BVH will be faster).

### Timing consequences (which sections must change)

1. **2.6.2 / 8.2 question 2:** with `OK_SECONDS = 20`, Reduce adaptive, Remesh, Smooth (whole body) and large Close Holes cannot run anywhere near `MAX_TRIANGLES_MESH = 2M`. Their up-front budgets will refuse, which is allowed. But the user should know the real working size for those tools: about 400k triangles for Reduce adaptive (8-step staircase), about 200k for Remesh at 10 passes, about 250k for Smooth at 5 passes. Fast Reduce, Combine and Plane Cut work up to 2M.
2. **C5.1 decimate staircase:** 8 calls cost 1.6× to 2.6× one call and pmp cannot be stopped inside a call. Use at most 2 to 3 steps, and size each step's cost with the up-front rate (single call: about 25 µs per input triangle at 2M, 31 µs at 100k).
3. **3.3.7 Smooth:** `implicit_smoothing` grows faster than linear (0.79 s → 73.6 s for 20× the triangles). The budget needs a superlinear estimate, or use the explicit Laplacian above about 200k triangles.
4. **3.2.3 Wrap / 3.2.4 Rebuild / `MAX_VOXEL_SAMPLES`:** `LevelSet` alone takes 15–18 s at 3.9M cells, before our distance field and EDT. Lower `MAX_VOXEL_SAMPLES` to 2,000,000 (≤ 6 s observed) or retune the 15 s target. Base the up-front estimate on the worst observed rate (≈ 4.6 s per million cells). The cancel hook (≤ 22 ms) keeps the hard bound either way.
5. **3.3.4 Plane Cut:** ingest plus split is about 4.4 s at 1M, estimated (2.7 s at 500k, 8.4 s at 2M). Retune the 5.7 row to ≤ 5 s, or let the open-body clipper (our code) handle closed bodies too when only `fill = none` is asked.
6. **3.2.1 Close Holes:** per-hole cost has an O(V) part (4.9 s for a 100-edge hole at 2M) and grows fast with hole size (800 edges: 28 s at 500k, 153 s at 2M). Use the local sub-mesh (C8 extra row) and budget per hole. "Close all holes" on a large scan with many small holes would otherwise multiply the O(V) cost.

---

## 10. Addendum after N0 + N1 (2026-11-11, binding; it overrides the body where they differ)

Stages N0 and N1 are done and verified (40 headless tests, 8 hooks, validate_project at the 6 known). Read this before coding against `CadMesh`.

### 10.1 Orchestrator decisions

1. **Group names stay at 64 bytes (C1).** B-rep face names can be longer. `from_shape` shortens a long name to its first 47 bytes + `~` + 16 hex digits of a hash of the whole name (the same on every run). `CadMesh.group_name_for(face_name: String) -> String` gives that mapping. Any code that follows a B-rep face name into a mesh group must go through it.
2. **Tessellate is limited by the B-rep mesher.** About 300,000 triangles on one curved face fit in 20 s. `from_shape` refuses up front: "Tessellate would take about n s on this body (limit n s). Lower the Refinement." Accepted. Tests must not expect large single-face tessellations.
3. **5.6 #2 "interference" needs `boolean` (N3).** G1 writes that case guarded by `mesh.has_method("boolean")` and prints a note when it skips. M removes the guard in Stage 3 and the final check must show it running.
4. **Owners of the two unowned methods:** `delete_triangles` belongs to **N2** (`mesh_clean.cpp`, bound in `bind_pmp_methods()`); `merge_with` belongs to **N3** (`mesh_boolean.cpp`, bound in `bind_manifold_methods()`).
5. **Welding of glTF and 3MF input.** `set_arrays` does not weld (contract). **N2** adds `welded() -> CadMesh` (exact-position weld through the existing `mesh::weld_exact`, groups kept, in `mesh_clean.cpp`). **M** calls it in Insert Mesh after `set_arrays` for 3MF and glTF/GLB input, so split vertices along UV seams do not read as open edges.
6. **Nesting rule.** Implemented as written: a positive shell wholly inside another positive shell is reported inside-out. Crossing shells are not marked (the `self_crossing` fixture: 0 inverted, 2 solids). The verifier still tests 8.1 row 28 through Stitch and Remove and Reverse Normal.
7. **Queries without a time argument** (`tessellate`, `section`, `boundary_loops`, selections, `solid_count`, volume, area, the first `ray_hit`) have no deadline. They are linear and measured at under 0.5 s for 2,000,000 triangles. Accepted.
8. **Self-intersection test:** triangle pairs that share a vertex are not tested, so a fold between neighbours is not seen. Ops that can fold neighbours (Smooth, Remesh, Texture Extrude, Shell) must not rely on `check()` alone for that; use their own post-checks (C5.3).

### 10.2 `CadMesh` as built (differences from C4)

- `transformed(xform: Transform3D) -> CadMesh` already exists (built in N1 for G1).
- `check(time_limit := 2.0)`: the self-intersection part uses what is left of `time_limit`, and reports -1 when it was skipped. If the linear part cannot finish, it returns `{}` and sets the error.
- `tessellate()` also splits vertices where the box projection changes axis. Normals stay continuous there. Triangle order, `face_ids` and edge ids follow C6.1.
- `mass_properties` on an open mesh: `volume` 0, `mass` 0, `center` = area centroid, plus `warning`.
- `distance_to(other, samples, time_limit)`: `samples` 1..10,000,000; an evenly spaced subset of used vertices when there are more.
- `triangles_in_frustum(planes: Array, mode: String)`: `planes` is an Array of `Plane` (at most 32), normals pointing out of the region, as `Camera3D.get_frustum()` gives.
- `set_arrays` with groups but no names names them `g0..gN`.
- `from_shape(shape, linear, angular, relative, time_limit)`: with `relative` the linear value is a fraction, 0.00001..0.1. Out-of-range values are refused by field name.
- `volume()` is signed (negative for an inside-out closed mesh).
- `ray_hit` normal is the triangle's own outward normal, also on back-face hits.
- `copy()` returns the same instance (meshes are immutable).
- Only `set_arrays`, `from_blob`, `read_*`, `from_shape`, `check`, `distance_to`, `transformed` and `library_versions` clear and set the error/warning. Other queries never touch them.
- Extra: `memory_bytes() -> int`, `group_name_for(face_name) -> String`.

### 10.3 Native notes for N2, N3 and C

- `static Ref<CadMesh> CadMesh::wrap(mesh::MeshData&&, std::string* error)` compacts and validates op output. `finish_op(title, op, MeshData&&, started_ms, test_self_intersections)` is the shared end of every op and fills `last_report` (2.6.3); each op adds its own promises.
- `bind_pmp_methods()` (N2) and `bind_manifold_methods()` (N3) exist, empty, called from `_bind_methods`.
- `mesh_data.h`: `MeshData`, `State`, cached topology, components with the nesting rule, measures, group index, every query as a free function. `mesh_bvh.h`: `TriBvh` (closest hit, filtered nearest point, winding column). Measured: build 0.011 / 0.068 / 0.28 s and one nearest query per vertex 0.053 / 0.31 / 1.3 s at 100k / 500k / 2M triangles (much faster than the spike's naive tree; use these for remesh projection estimates).
- `mesh_budget.h` holds measured `Curve{100k, 500k, 2M}` constants with `estimate()`, and the spike's library numbers marked for re-measuring.
- **Header clash:** pmp has a class `Handle`; OCCT defines a macro `Handle(Class)`. A file that includes both needs `#pragma push_macro("Handle")`, `#undef Handle`, the pmp includes, then `#pragma pop_macro("Handle")`. `cad_mesh.h` only forward-declares `CadShape`.
- The OCCT Deadline progress indicator in `solid_ops.cpp` is in an anonymous namespace; `mesh_tessellate.cpp` has its own copy. C may copy it again or ask N to move it to a shared header.
- `EIGEN_DONT_PARALLELIZE` is defined for the target (pmp's OpenMP flag would otherwise thread Eigen in the Form code).
- Neither Godot's `vformat` nor GDScript's `%` has `%g` or `%e`. Format with `snprintf` in C++ and `%s`/`%f` in GDScript.

### 10.4 Small corrections

- 5.1 #6: the STL fixture is in `tests/holo_forge/fixtures/`, not `tests/holo_forge/`.
- Section 4 "licenses (7)" means the 4 license files of section 7 (all present).
- Test counts: 40 headless tests after N1 (the spec's "37" is out of date).

### 10.5 Rules for teams that run at the same time (G1, N2, N3 run together; then U; then M and C)

- **Separate native test files.** N2 writes `tests/holo_forge_mesh_native_pmp_test.gd` (5.1 #15-26) and N3 writes `tests/holo_forge_mesh_native_manifold_test.gd` (5.1 #27-36). Do not edit `tests/holo_forge_mesh_native_test.gd` (N1's part) except to fix a bug you report. Both may add fixtures to `tests/holo_forge_mesh_fixtures.gd`: add new functions only, never change an existing one.
- **Shared native files** (`cad_mesh.h/.cpp`, `mesh_budget.h`, `mesh_data.h/.cpp`): another team may be editing them right now. Re-read the exact lines just before each edit, make small edits (never rewrite the file), and add rather than change. If you need to change something another team's code uses, report it instead.
- **One build at a time.** Before `cmake --build`, take the lock with `mkdir C:\Users\Blaze\holo_forge_build\build.lock` (it fails if another team holds it; wait 20 s and try again, for up to 15 minutes, then report). Remove the folder right after your build ends, pass or fail. Never leave it behind.
- **Keep the tree compiling.** Only save a native file in a state that compiles. If the build fails in a file that is not yours, wait a few minutes and rebuild; if it still fails after 3 tries, report the error text and carry on with what you can.
- **A DLL copy can fail** while another team's Godot test is running (the DLL is loaded). Wait and rebuild. Never kill a Godot process you did not start.
- **Timing checks** can fail while other teams load the CPU. Rerun a failed timing check alone a few minutes later before calling it a defect, and say in your report which results were measured under load. The orchestrator runs the full sequential suite alone after each stage, so do not run the 21-minute full suite yourself; run your own tests and the existing tests your change could affect.

### 10.6 After G1 (2026-11-11 evening, binding): helper API and decisions

G1 is done: 5.6 passes in `tests/holo_forge_mesh_gate_test.gd`; the existing tests and 8 hooks still pass.

**"Is this a mesh body?"** `MESH_BODY.is_mesh(entry_or_shape)` with `const MESH_BODY := preload("res://addons/holo_forge/core/mesh/mesh_body.gd")`. It takes a regen entry or a shape. The file preloads nothing, so any script can preload it.

**`core/mesh/mesh_body.gd`**
- consts `KIND`, `GATE`, `ANALYSIS_GATE`, `DECAL_GATE`, `EXPORT_GATE`, `AXIS_GATE`, `ALREADY_MESH`, `KERNEL_MISSING`, `GROUP_REF` ("mesh_group"), `TRIANGLES_REF` ("mesh_triangles"), `FILTER_KINDS`; `static var force_missing` (test seam)
- `available() -> bool`, `new_mesh() -> RefCounted`, `is_mesh(entry_or_shape) -> bool`, `kind_of(item: Dictionary) -> String`
- `entry(body_id, mesh, feature_id) -> Dictionary`, `body_name(doc, body_id) -> String`, `group_label(shape, group) -> String` ("Face Group n")
- `gate(doc, entries: Array) -> String`, `gate_ids(ctx, ids: Array) -> String`, `gate_ref(ref, ctx) -> String`
- inspect forms: `shape_kind(shape)`, `solid_volume(shape)`, `mass_properties(shape, density)`, `measure(a, b, ctx) -> Dictionary` (`{}` when `a` is not on a mesh body), `interference(a, b, time_limit := 20.0) -> Dictionary`

**`core/mesh/mesh_blob.gd`** (Resource): exports `format, digest, size, vertices, triangles, data`; `last_error`; `static from_mesh(mesh) -> Resource`; `to_mesh() -> RefCounted`; `is_large()`; `short_digest()`; `static sha256_hex(bytes)`; `EMBED_LIMIT` (256 KB).

**`core/features/mesh.gd`**
- `build(feature, ctx) -> String`: only `tessellate` is implemented. Any other method returns "The Mesh tool '<m>' is not available in this build". **M adds branches to the `match`.**
- consts: the C5 budgets, `PREVIEW_SECONDS`, `OK_SECONDS`, `CACHE_BYTES`, `CACHE_ENTRIES`, `TESSELLATE_PRESETS`; `time_limit(ctx) -> float` (reads `ctx.mesh_time_limit`)
- cache: `cache_key(method, options, digests) -> String`, `lookup(key, limit := OK_SECONDS) -> Dictionary`, `store(key, meshes: Array, error := "", warning := "", report := {}, limit := OK_SECONDS) -> Dictionary`, `clear_cache()`, `cache_stats()`, `static var cache_hits`. A refusal stored with a short limit does not answer a lookup with a longer one.
- `transformed(mesh, xform) -> RefCounted` (cached), `output_ids(feature, doc, count, source_names := [], suffix := "") -> Array`, `set_body(ctx, body_id, mesh, feature_id)`, `replace_body(r, body_id, mesh)`, `warn(r, text)`
- `blob_mesh(feature, key := "mesh") -> {"mesh"} | {"error"}`, `check_warnings(mesh, body_name) -> PackedStringArray`, `add_tessellate(doc, body_ids, options := {}, inputs := {}) -> {"feature", "error", "bodies"}`

**`core/features/util.gd`**: `const MESH_GATE`; `static mesh_gate(doc, entries) -> String`; `Reader.bodies(key, required := true, allow_mesh := false)`; `Reader.bodies_of(picks, required := true, allow_mesh := false)`; `Reader.gated(body_ids: Array) -> bool`.

**`core/regen.gd`**: handler `"mesh": MESH`; rebuild option `"mesh_time_limit"` (U passes `MESH.PREVIEW_SECONDS` for previews); `MESH_AWARE` lists the feature types allowed to pick mesh bodies (**M and C must add any new non-"mesh" type there**); `mesh_gate(feature, bodies, doc)`. A feature whose type is not in `MESH_AWARE` and whose options hold a pick on a mesh body is not run; its error is the gate sentence.

**`core/references.gd`**: `mesh_group(ref, ctx)`; `plane()` accepts a flat `mesh_group`; `axis()` on one gives `AXIS_GATE`; `from_pick()` turns `mesh_group` / `mesh_triangle` / `face` picks on a mesh body into `{"kind": "mesh_group", "body", "group", "at"}` or `{"kind": "mesh_triangles", "body", "triangles", "digest", "at"}`.

**`core/tessellate.gd`**: a mesh body's tessellation carries `tess["cad_mesh"]` (`MESH_KEY`); `MESH_GROUP_BORDER` (-1), `MESH_OPEN_EDGE` (-2) edge ids; `triangle_subset_mesh(tess, triangles)`.

**`core/picking.gd`**: `prepare(body_id, tess, shape := null)`; mesh picks are `{"kind": "mesh_group" | "mesh_triangle", "body", "index", "group", "triangle", "point", "normal"}`. `filters.mesh_triangle = true` selects triangle mode. A filter set without `"mesh_group"` follows its `"face"` filter. `window_select` takes mesh bodies only for kind `"body"`.

**`core/analysis.gd`**: `mass_properties(doc, result, body_ids)`, `mesh_section(shape, origin, normal) -> {"lines", "area", "open"}`. **`core/appearance.gd`**: `decal_gate(shape) -> String`; `placed_decal` returns `"error"` and `"lost"` for a mesh body. **`core/export.gd`**: `export_cad(kernel, result, body_ids, path, doc := null) -> String`; `export_cad_report(...) -> {"error", "written", "skipped", "note"}`; `MESH_ONLY_FORMATS` (`obj`, `3mf`). **`core/features/insert.gd`**: `KIND_SOLID`, `KIND_MESH`; `mesh_kind(feature)`; `add_mesh_import(doc, path, units := "", linked := false, kind := KIND_SOLID)`; `read_mesh_body(path, units := "") -> {"mesh", "error", "triangles", "units"}`. **`nodes/cad_part.gd`**: `externalize_mesh_blobs() -> Array`, `save_mesh_blobs(folder) -> Array`.

**Decisions**
1. **`core/inspect.gd` belongs to team G** (it was on no list). G patches it so `INSPECT.shape_kind`, `shape_mass_properties`, `area_center`, `measure` and `interference` work with mesh bodies, adds mesh-against-B-rep interference (3.5.2), and tests through `INSPECT.*`.
2. **Unowned UI files go to team U:** `tools/measure_command.gd`, `tools/mass_command.gd`, `tools/interference_command.gd`, `tools/image_command.gd` (block a decal on a mesh body with `APPEARANCE.decal_gate`), `ui/forge_files.gd` (pass `doc` to `export_cad`, use `export_cad_report`, offer OBJ and 3MF), and `forge_workspace.gd create_base_feature()` (it calls `to_brep_bytes()` on every selected body; a mesh body must get the gate sentence instead).
3. **`model_size` is not gated** (2.3.3 listed it). It only reads `bbox()`, and gating it would break "through all" extents in any design with a mesh body.
4. **The gate sentence literal lives in `mesh_body.gd`** (`util.gd` cannot be preloaded by `references.gd`/`operations.gd`). `UTIL.MESH_GATE` and `UTIL.mesh_gate()` exist as the contract says.
5. **Stored blobs are in meters and unplaced;** the placement is applied at build with `transformed`, and `options.mesh_units` keeps the unit the blob was read with.
6. **Section on a mesh body draws outlines, not filled caps.** Accepted.
7. **Interference result:** `mesh_body.gd interference()` matches N3's error text ("empty" / "do not overlap") to mean "no interference". N3 must expose that as a flag in `get_last_report()` (`"empty": true`), and G then reads the flag.

### 10.7 After G's inspect follow-up (2026-11-11 night, binding)

- `core/inspect.gd` works with mesh bodies. B-rep results are byte-identical to before (170 comparisons).
- `INSPECT.interference(kernel, bodies, body_ids, doc: Resource = null) -> Array`. A pair with a mesh body has a `CadMesh` as `"shape"`; `"note"` when a B-rep body was tessellated for it; `"error"` (and `"unavailable": true`) when it cannot be worked out. Volumes against curved B-rep bodies are approximate (under 1 % low in the test); the note is the signal.
- `INSPECT.measure(a, b, ctx)`: with a mesh reference the result can carry `"note"`. A face group, or a mesh reference with `"at"` (the picked point), is measured **from that one point** to the other geometry. A whole mesh body with no picked point is refused with `MESH_BODY.MEASURE_WHOLE`. It is not the least distance between the surfaces.
- `INSPECT.mass_properties`: an open mesh body's entry has `"warning"`.
- `MESH_BODY.geometry(ref, ctx) -> Dictionary`, `MESH_BODY.area_center(shape) -> Vector3`, `MESH.tessellated(shape, quality := "medium", limit := OK_SECONDS) -> {"mesh", "warning"} | {"error"}` are new.
- `boolean` sets `"empty": true|false` in `get_last_report()`; `MESH_BODY.interference` reads it.
- **For U:** `REFERENCES.from_pick` puts `"at"` on mesh group and triangle picks, not on a mesh **body** pick. In `tools/measure_command.gd`, add the hit point as `"at"` to a mesh body reference (or pick groups), so Measure from a mesh body works from the view.
- **Open, for the verifier and the final fix round:** one mixed mesh/B-rep interference pair can take up to about 30 s in the worst case (two tessellation tries of 10 s, then the boolean's own limit). That breaks the 20 s + 1 s rule (0.5 #1); it needs one shared deadline.

### 10.8 After N3 (2026-11-11 night, binding)

N3 is built and passes `tests/holo_forge_mesh_native_manifold_test.gd`. **The bound methods, option keys, defaults, ranges, refusal and warning sentences, measured rates and known risks are in `docs/holo_forge/phase7_native_ops_n3.md`. Team M wires the tools from that file, not from section 3, where they differ.**

Decisions:
1. **Wrap tests.** 5.1 #32 and 5.2 #12 cannot pass as written: the holed blob's holes are 6 to 40 mm across and a 3 mm gap closes openings up to about 6 mm. Test with a gap of at least 22 mm (N3 uses 26 mm with detail 1.5 mm), and assert that the spec's old numbers are refused with the "gaps wider than" sentence. Wrap is not expected to close holes much wider than the gap.
2. **Wrap offset:** positive is outward.
3. **Shell wall check:** 400 area-weighted samples on the new surface against the nearest point of the input (the ray rule in section 3 fails on a correct box shell near edges). Same 0.8..1.2 / 0.7..1.3 and 95 % rules.
4. **Plane Cut** uses two `TrimByPlane` calls (a `SplitByPlane` could not be stopped and came back 2.2 s late at 2M triangles).
5. **Extras that stay:** `op_defaults(method, options) -> Dictionary` (defaults, `<field>_min`/`_max`, `cells`, `seconds` for the 0.5 s preview rule, `problem`); the test-only `skip_estimate` option (tools must never pass it); Separate refuses more than 1,000 pieces; Texture Extrude refines by itself and has `refine: false` so M can chain Remesh; the bound name of Wrap is `wrap` (C++ `wrap_op`).
6. **For M (shipping bar):** Plane Cut and Separate say nothing when the input crosses itself, and their result is then as wrong as the input. In the feature, warn before those two tools (and Combine's Merge) when the input's `check()` reports self-intersections: "<Body> crosses itself, so the result may be wrong there. Rebuild it first."
7. **For the verifier:** a Wrap that leaves under half of the input outside returns a partial result with a warning; the "does not fit" estimate of Shell misses a thin leg on a thick part; Texture Extrude's cylindrical mapping and planar/box on other shapes are untested for values; group names near 64 bytes through `_cut` / `(2)` suffixes are untested; a deadline that expires during a 2M-triangle ingest came back up to 0.86 s late.

### 10.9 After N2 (2026-11-11 night, binding)

N2 is built and passes `tests/holo_forge_mesh_native_pmp_test.gd`. **The bound methods (`welded`, `delete_triangles`, `reverse`, `stitch_and_remove`, `regroup`, `generate_groups`, `fit_primitive`, `smooth`, `reduce`, `close_holes`, `remesh`), their option keys, defaults, ranges, sentences, report keys, measured rates, working sizes and known risks are in `docs/holo_forge/phase7_native_ops_n2.md`. Team M wires the tools from that file, not from section 3, where they differ.** Every difference listed there is accepted.

- `<Body>` in N2's sentences is the literal "The mesh"; the feature puts the body's name in. N3's ops take `options.name` instead.
- Changed acceptance numbers: 5.1 #19 (reduce by a 0.01 mm tolerance on icosphere s5) asserts the "Nothing could be taken out" outcome; 5.1 #18 Fast asserts at most 0.12 mm. Cases in 5.2 and 5.3 that use those numbers change the same way.
- Working sizes at 20 s (refused up front above them): Reduce adaptive about 750k triangles; Remesh uniform (10 passes) about 300k; Remesh adaptive 150,000 (it never fits the 0.5 s preview); whole-body Smooth (5 passes) about 250k; Reduce fast, Stitch, Generate Face Groups, Reverse: up to the 2M cap.
- **Feature option keys.** Panels (team U) write the option keys of section 3. Team M maps them to the native option names inside `core/features/mesh.gd`. Where the native side has a field, default or range that section 3 does not have (for example Reduce `sharp_angle`, Remesh adaptive's raised `min_edge`, `op_defaults` for the voxel tools), M wires it with the native name and lists it in its report so U can add the field in Stage 4.
- **For the verifier:** Close Holes on the outline of an open sheet makes a double surface (warned); Reduce on a body of a few triangles destroys the shape (warned); Remesh can fold triangles next to a jagged group border (warned); adaptive Remesh quality is unverified; the ops other than adaptive Remesh were not re-probed for the time bound after the last changes.

### 10.10 After U's Stage 2 (2026-11-12, binding)

The Mesh panels, selection, display, Direct Edit and icons are built. **The per-tool table (spec key, pick kinds, option keys, defaults, inputs and ranges), the selection/display/workspace APIs, what Direct Edit stores, and U's unfinished and unverified items are in `docs/holo_forge/phase7_ui_as_built.md`.** Only Tessellate ran end to end; every other tool was panel-only until M's handlers.

Decisions:
1. The Method choice of Rebuild, Generate Face Groups, Reduce and Shell is stored as `options.algorithm` (`options.method` holds the tool name). M passes it to the native op as `method`.
2. M publishes `static var reports` in `core/features/mesh.gd` (`reports[feature.id]` = the op's `get_last_report()` plus an optional `"stat"` string). U's stat row reads it.
3. **Fix round, team G:** the preview limit is rebuild-wide (every mesh feature gets 0.5 s while one previews, so an evicted earlier feature shows a false "would take" error); pass the previewed feature's id and give only that one the short limit. Also the bake (`cad_part.gd apply_result`) takes about 1.45 s per rebuild for a 1M-triangle mesh body.
4. **Fix round, team N:** Tessellate at the Low preset on a 50 mm sphere is refused by the 1 % volume rule (2.3 % off). The rule becomes: keep the result with a warning that gives the percent up to 5 %, refuse above 5 %.
5. Icons: the mesh icons' accent is `#22b8cc` as in the existing files (the spec's `#e0a526` was wrong). U drew 8 icon files, compared at 96 and 24 px against the house icons, and from memory against the other app's.
6. U changed four more tests under 5.8 (`insert_editor`, `inspect_editor`, `surface_editor`, `toolbar`): the "Mesh disabled" checks now expect Mesh enabled and a Phase 8/9 tool greyed.
7. **Stage 4 hook must cover** (never run in a real editor yet): the browser's mesh icon, timeline chips for `mesh:<method>`, undo names without the `Forge: ` prefix, a real right-click on the browser, the file dialogs (Body Type row, OBJ/3MF filters), Shift+F, the pinned-button pressed state, the "Removed" and "Fill" preview overlays, Mesh Align's three-point slot, Combine's mixed tool slot, Texture Extrude's Choose File, Scale Mesh's point slot, and the stat row with a real report.

### 10.11 After M's Stage 3 (2026-11-12, binding)

Every Mesh tool but Convert is wired as a timeline feature; 5.2 (`tests/holo_forge_mesh_tools_test.gd`) and 5.3 (`tests/holo_forge_mesh_test.gd`) pass through features and `regen`. **The per-tool wiring, the changed test cases, the shipping-bar items closed and not closed, and the editor-checks interface are in `docs/holo_forge/phase7_tools_as_built.md`.**

Decisions:
1. **Create Mesh Section Sketch.** A feature cannot add another feature during replay. The `mesh` feature computes and checks the section; `MESH.add_section_sketch(doc, result, feature, replace := true)` makes the fixed sketch and removes the mesh feature. Team U calls it in `accept_command` (Stage 4).
2. `CACHE_ENTRIES` goes from 32 to 256 (the 512 MB cap stays): with 32, a design with more kept results recomputes on every rebuild.
3. Bodies a tool adds are registered only on a full-time build; previews show them under passing ids. Accepted.
4. Mesh Align: 1e-9 m holds for a face group (a second pure shift takes out the float32 residual); the three-point variant holds 1e-7 m. Accepted.
5. The 1 s self-crossing test: on a body too large to test, a full build says so in a warning. Accepted.
6. **For the verifier and the fix round** (M's "not closed" list): stale hole picks are warned, not re-found; Plane Cut on several bodies fails the whole feature when the plane misses one; Move, Scale, Align, Direct Edit, Merge and the group tools have no time limit (linear); and the list of things not value-tested through features (Texture Extrude planar/cylindrical and Rotation, adaptive Remesh quality, Shell Outside and Both, Close Holes Flat and Minimal, Combine with several tools or a component pick, Remove Pieces Inside Others, linked Insert Mesh of 3MF/glTF, a damaged Direct Edit blob).

### 10.12 After C's Stage 3 (2026-11-12, binding)

Convert Mesh is built; 5.4 #1-9 pass in `tests/holo_forge_mesh_convert_test.gd`. **The interface, every sentence, the caps, measured times, post-checks and open risks are in `docs/holo_forge/phase7_convert_as_built.md`.** Every difference listed there is accepted:
- 5.4 #9 uses a 0.3 s limit (the crossing-holes body really takes 0.25 to 0.4 s; the pair rate is 0.11 s stored, not the spike's 0.22 s).
- Faceted builds its own vertices, edges and faces from the mesh topology (no sewing, no unify, nothing healed silently); faces carry the mesh's own triangles as their drawn mesh.
- Prismatic refuses more than 1,500 face groups and bodies that are not exactly one solid part. A box with every edge filleted is refused after about 7 s ("they close 2 separate solids").
- Organic: the Form Body output is swapped in by `MESH_CONVERT.form_body(doc, feature)`, called by U in `accept_command`. Above about 3,300 target faces the 20 s estimate refuses it. It is useful on smooth shapes only.
- **For the verifier:** Faceted at 50,000-60,000 triangles under load can end in the time-out sentence after 20 s instead of an up-front refusal; Organic's time bound rests on estimates (`to_shapes` cannot be stopped); Prismatic mixed cells are only reported; a merged Faceted face with a very long outline has one unstoppable validity check.

### 10.13 After U's Stage 4 and the first fix reports (2026-11-12, binding)

- The hook `--holo-forge-mesh-editor-test` (`tests/holo_forge_mesh_editor_test.gd`) passes headless and windowed; it covers 5.5 #1-14, 10.10 item 7, the Stage 4 panel fixes and Convert (Faceted, Prismatic, Organic to a solid and to a Form Body). `--holo-forge-mesh-editor-only=a,b` runs named parts and ends with PARTIAL. 78 screenshots are in `docs/holo_forge/screenshots/phase7/`. There are now **9 hooks**.
- Section Sketch and the Organic Form Body output are swapped in by `accept_command` (one undo step each). Remesh Minimum Edge is an empty "auto" field (no input while empty). Reduce and Smooth have Sharp Edge Angle. `set_command_values(values, typed := [])`.
- `docs/holo_forge/phase7_ui_as_built.md` is out of date on those points; U updates it in the fix round.
- **N1's fixes (done):** OBJ polygons triangulate in near-linear time and are refused when they cannot be split in time; damaged STL/OBJ files are refused when they provably stop mid-item and loaded with a counted warning otherwise (`read_stl`/`read_obj` now set `get_last_warning()`); coordinates beyond 1,000 km and NUL in group names are refused; Tessellate's Surface Deviation range is `min(0.001 mm, D/20,000)`..`D/10`, clamped to the mesher's 0.0001 mm floor with a warning; a volume 1-5 % off is kept with a warning, above 5 % refused; `mass_properties` never returns a negative mass or volume and adds `warning`, `flaws` (subset of `open`, `wrong_way`, `no_volume`, `inside_out`, `self_crossing`), `wrong_way_edges`, `inside_out_parts`, `self_intersections`. New test: `tests/holo_forge_mesh_regress_data_test.gd`.
- **Open for the fix round:**
  - **G:** `tests/holo_forge_mesh_gate_test.gd` fails one case on purpose (it expects the old refusal of a Low-preset ball; now a 2.3 % warning) and the "refusal is kept" check after it no longer tests a refusal; `mesh_body.gd mass_properties()` forwards only `warning` (add `flaws` and the counts); interference (verify2 B7); the rebuild-wide preview limit; the bake time; the save order: the editor calls `_save_external_data` after the scene file is written and before the scene has its new path, so the first save keeps every baked mesh and blob inside the `.tscn` (5.98 MB against 255 KB) and a Save As writes the `.res` files beside the old scene.
  - **M:** Insert Mesh reads only the error after `read_stl`/`read_obj`: pass the new reader warnings on; verify1 P3 (Erase and Fill sentences) and the stale-pick notes; verify2 P7; the crossing note for Combine and Shell at feature level.
  - **U:** the command panel covers part of the body in some tools (Reduce screenshot); Direct Edit's move arrows start about 100 px from the selection; Align's points show as triangles, not dots; when an existing Mesh feature is edited, picks resolve on the result; `command_panel.gd set_values` seems to leave the focused field's text alone (unowned file: U takes it).

### 10.14 Fix round results so far (2026-11-12 evening, binding)

- **N2, N3, N1, M and G have reported their fix rounds.** Changed sentences, report keys and outcomes are in section 8 of `phase7_native_ops_n2.md`, section 8 of `phase7_native_ops_n3.md`, and section 7 of `phase7_tools_as_built.md`. New regression tests: `holo_forge_mesh_regress_pmp_test`, `holo_forge_mesh_regress_manifold_test`, `holo_forge_mesh_regress_data_test`, `holo_forge_mesh_regress_tools_test`, `holo_forge_mesh_regress_doc_test`. A new hook `--holo-forge-save-editor-test` (10 hooks now).
- **Known and accepted after the fixes** (warned, not removed): Remesh can lose a short closed stretch of group border (it now reports the move both ways); Reduce (Adaptive) by Maximum Deviation on flat-faced bodies mostly returns "Nothing could be taken out"; the L-bracket does not reduce with Keep Face Group Borders on; Reduce (Fast) by tolerance works to about 1M triangles; self-crossing tests have 1 s each, so large bodies get "not tested" sentences; Wrap and Rebuild find "would lose all" only after the run; the Shell crash guard depends on Manifold 3.5.4 internals (rerun the off-origin scan after any Manifold update).
- **G's new API:** `REGEN.rebuild` option `mesh_preview_feature`; `MESH_BODY.resolve_group(shape, ref)` and `moved_note(label, from, to)` (group picks follow a renumbered group through `at` and `normal`); `INSPECT.interference(..., doc = null, time_limit := 20)` with entry keys `warning`, `approximate`, `timed_out`, `open`; mass flaw keys and `warnings`; `EXPORT.export_cad_report(..., include_hidden := false)` with `hidden`; `MeshBlob.check()`; unchanged mesh bodies keep their baked mesh (1M triangles: about 2 s once, then under 1 ms); meshes are externalized on `NOTIFICATION_EDITOR_POST_SAVE` with one re-save (the first save is 2.6 KB instead of 3.6 MB; Save As writes beside the new scene).
- **Rule for every hook that saves (new, hard):** a hook run on 2026-11-12 19:14 rewrote eight of the user's `.tres` files (same bytes, new modified time), and one run overwrote the fixture scene (restored). The editor reopens the user's last session, so their scenes are open in every hook run. A hook must snapshot every `.tscn`/`.tres`/`.res` outside its own test folder before it saves and FAIL if any changed, must never save while a scene outside `tests/holo_forge/` is shown, and must leave `.godot/editor/editor_layout.cfg` and `project_metadata.cfg` as it found them. Team G is finding the cause and adding the guard.
- **Still open:** C (Convert fixes), U (panel placement; the mesh-editor hook is red in its Convert section until then), the Phase 6 shell fixer (Solid Shell on flat-triangle bodies), M (group picks inside `mesh.gd` through `resolve_group`; md5 in the linked-file stamp). Not planned: appearances carried onto a converted body.

### 10.15 After G's third fix round (2026-11-13, binding)

Re-verifier R3's items D1, D-S6, D2, D3, D4, D5 and I1 (part). Tests: `tests/holo_forge_mesh_save_faults_test.gd` (14 cases; new: failed same second, baked lost unbuilt, no orphans, inherited changed) and the third-round checks in `tests/holo_forge_mesh_regress_doc_test.gd`.

- **No file is deleted on a Save any more until that Save is on disk (D1, D5).** The old "replaced file" bookkeeping (`_replaced`, `_written_at`, `_clean_beside`) is gone. After POST_SAVE, `CadPart._clean_folder(scene_root, scene_path)` runs once per Save (key: scene path and a save counter) and removes only files named like the parts write them (`<part>_<body>_<12 hex>.res`, `<part>_mesh_<16 hex>.res`) in `<scene>_forge` that nothing points at: no part of the open scene (also unsaved changes), not the scene's own file as it is on disk now (after a failed Save that is still the old scene, so its files stay), and no other `.tscn/.scn/.tres/.res` file (under `res://` for a project scene, in the scene's folder for a `user://` scene; `_forge` and dot folders skipped; dependencies cached by modified time and size). The scan only runs when a Save left candidates. Cost in the real project (1,531 scene/resource files): about 0.2 s to list them, 0.9 s to read their dependencies the first time, then about 0.7 s to check the cached stamps, per Save that dropped a file.
- **Lost baked meshes are baked again (D-S6).** A body whose baked file is deleted, cut short, zero bytes or a folder loads with no mesh. At editor `_ready` (deferred) and again at PRE_SAVE, `_bake_lost_meshes()` rebuilds the part when any body has no mesh and warns "Holo Forge: the baked mesh of X in Part was missing or damaged on disk; it was baked again from the design." (an error if no kernel is there). So a Save without a rebuild writes the bodies again; after any Save a reload gives the same bodies or a clear error.
- **A design changed in an inheriting scene is kept in that scene (D4).** The part has a new stored property `local_document` (`@export_storage`). At PRE_SAVE, if the part's document belongs to a base scene (its `resource_path` is `base.tscn::...`) and its design (`_design_text`: features, inputs, options, blob digests) differs from what the base file holds, a copy of the document is stored as `local_document` and the console says "the design of X was changed in heir.tscn, which inherits it from base.tscn: from this Save on heir.tscn keeps its own copy of the design (base.tscn keeps its own)." On load the setter makes it the part's `document`. Its baked meshes and blobs go beside the heir. Limits: an heir that was never saved before is not seen as inheriting; a base scene open in another tab shares the in-memory design (Godot's own sharing of sub-resources); once an heir keeps its own copy, later base edits no longer reach it (as Make Unique). The base is read with `CACHE_MODE_IGNORE` (IGNORE_DEEP reloads scripts mid-call and crashes).
- **A preview stays near its limit (D3).** With `mesh_preview_feature` and a `mesh_time_limit` under `MESH.OK_SECONDS`, the Mesh features before the previewed one (`REGEN.PREVIEW_TIMED`, now `["mesh"]`) share `REGEN.PREVIEW_LEAD_SECONDS` (1.0 s): each gets what is left as its limit; none starts once it is spent. When one does not fit, the preview stops before it and does not keep that refusal as an error: `result.preview_stops_at` names the feature before it, and the new key **`result.preview_stopped`** (also appended to the previewed feature's warning) is `REGEN.PREVIEW_STOPPED_FEATURE` ("Smooth2 is not previewed: Remesh1, earlier in the timeline, has to be worked out again (its kept result is gone) and takes longer than a preview may. Click OK to build it in full.") or `PREVIEW_STOPPED_TIME`. `preview_stops_at` is no longer set when every later feature is suppressed. Measured: Smooth after a lost Remesh 0.09 s (was 5-6 s); 16 Scales on 330,672 triangles with nothing kept 1.05 s. B-rep features before the previewed one are not bounded; the worst case is about the lead plus one Mesh operation's overrun plus the preview limit.
- **Pick sentence (D2).** `MESH_BODY.GROUP_MOVED` / `moved_note(label, from, to)`: "X's pick of face group g3 now lands on face group g0, which is where it was picked (an earlier change renumbered the face groups or moved the body). Pick it again if g3 is meant." The appearance note says the same. The pick still follows the place (at + normal); "moved from ... to ..." is gone. `resolve_group`'s `"moved": true` now documents "the pick lands on another group than the one of its name" (renumbered, or the body moved: which is not known), not "renumbered" (R3's d20 probe still counts the flag; its timeline sentence checks pass).
- **Results after install (real project, 2026-11-13 09:21-09:36):** R3's D-probes: d05 same second 2 findings to 0; d03 s6 5 to 0; d04 inherited 2 to 0 (d02's load-only rerun of d04 reports 1, against a record d04 takes before its own step 3 changes the heir: an artefact of the probe); d20 50 to 48 (the 2 sentence checks pass; the 48 count the `moved` flag after rigid moves); d30 a-c 5 to 0; d30 d 1 to 0 (24 Scales on 1.3M triangles: 1.15-1.34 s, was 21-25.5 s); d40 5 to 0; d03 orphans 1 to 0 (20 edits: 5 files / 4,529 KB, was 25 / 20,193 KB).
- **Mesh-to-mesh interference bound (I1).** `INSPECT._mesh_interference` adds `_rounding` (3 x sqrt(3) x largest coordinate x 2^-24 x overlap area: float corners of both bodies and of the overlap) to every overlap's bound. An overlap is marked `approximate` when a side is round or the bound is at least 0.01 % (`ROUNDING_PERCENT`); flat-only ones say "within about X % (the triangles' corners are kept to float precision, and the overlap is thin)"; under 1 % the percent has two decimals. The bound is loose but true (R3's 0.001-0.01 mm overlaps on 2 m cubes are inside it).
- **For M and U:** tests that look for "face group moved from" must look for "now lands on face group" (`tests/holo_forge_mesh_editor_test.gd`, U; `tests/holo_forge_mesh_regress_tools_test.gd`, M). U may show `result.preview_stopped`, and must expect `preview_stops_at` to name a feature before the previewed one: `forge_workspace.gd _waiting_features()` labels the left-out features with the feature `preview_stops_at` names, which after a stopped preview is the wrong one (use the command's own feature's label). `_hold_later_features()` already holds what the features after `preview_stops_at` made.
