# Third-party notices

Holo Forge ships these libraries as separate DLLs in `bin/`, unchanged unless noted. Each one's license text is in `licenses/`.

| Library | Version | License | Files in `bin/` | Source |
|---|---|---|---|---|
| OpenCASCADE Technology | 8.0.1 | LGPL 2.1 with the OCCT exception | `TK*.dll` | https://github.com/Open-Cascade-SAS/OCCT (tag `V8_0_1`) |
| planegcs (FreeCAD's sketch solver) | from FreeCAD, October 2026 | LGPL 2.1 or later | `planegcs.dll` | in the `lgpl-sources` zip that comes with this release; upstream https://github.com/FreeCAD/FreeCAD (`src/Mod/Sketcher/App/planegcs`) |
| Manifold | 3.5.4 | Apache 2.0 | `manifold.dll` | https://github.com/elalish/manifold |
| Clipper2 (used by Manifold) | 2.0.1 | Boost Software License 1.0 | built into `manifold.dll` | https://github.com/AngusJohnson/Clipper2 |
| OpenSubdiv | 3.5.0 | Modified Apache 2.0 | built into `holo_forge_native.dll` | https://github.com/PixarAnimationStudios/OpenSubdiv |
| pmp-library | 3.0.0 | MIT | `pmp.dll` | https://github.com/pmp-library/pmp-library |
| meshoptimizer | 1.3 | MIT | `meshoptimizer.dll` | https://github.com/zeux/meshoptimizer |
| Eigen | 5.0.1 | MPL 2.0 | headers only, built into the DLLs | https://gitlab.com/libeigen/eigen |
| Boost (graph and its dependencies) | 1.92.0 | Boost Software License 1.0 | `boost_*.dll` | https://www.boost.org |
| godot-cpp | 10.0.0-stable | MIT | built into `holo_forge_native.dll` | https://github.com/godotengine/godot-cpp |
| Microsoft Visual C++ runtime | 14.44 | Microsoft Visual C++ Redistributable terms | `msvcp140.dll`, `vcruntime140.dll`, `vcruntime140_1.dll`, `vcomp140.dll` | shipped so the plugin loads on PCs without the Visual C++ Redistributable installed |

## The LGPL libraries (OpenCASCADE, planegcs)

- They are loaded as separate DLLs. Holo Forge's own `holo_forge_native.dll` links to them dynamically, so you can swap in your own build of the same version (same file names).
- **planegcs:** the source code as built, including the header shims Holo Forge needs, is in `holo_forge-<version>-lgpl-sources.zip`, next to the plugin zip.
- **OpenCASCADE 8.0.1:** built from the official 8.0.1 source with vcpkg (port `opencascade`, no default features). vcpkg applies its own build patches, which change the build files, not the library's code. The sources zip holds the official source archive and that vcpkg port, patches included.
- If you received Holo Forge without the sources zip, ask the seller for it. It must be provided to you at no charge beyond the cost of providing it.
