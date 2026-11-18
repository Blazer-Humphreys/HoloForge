"""Packages Holo Forge for other people's Godot projects.

    python package_release.py [--out <folder>]

Writes two zips and a setup program into --out (default C:/Users/Blaze/Holo Builds/holo_forge):

  holo_forge-<version>-windows.zip       addons/holo_forge/ as it goes into a project: unzip it in
                                        the project folder, or AssetLib > Import... in Godot.
  holo_forge-<version>-lgpl-sources.zip  the source of the LGPL libraries the plugin ships
                                        (planegcs as built, with Holo Forge's header shims and a
                                        CMakeLists.txt; the OpenCASCADE 8.0.1 source archive and the
                                        vcpkg port it was built with).
  holo_forge-<version>-windows-setup.exe the same addon as a Windows installer (installer/
                                        holo_forge_setup.iss, Inno Setup 6.3+): it puts the addon
                                        into a project, turns the plugin on and runs the addon's
                                        self-test. Skipped with --no-installer.

The addon is copied from the game project (godot-board-racing/addons/holo_forge), leaving out what
Godot makes by itself in each project (.import files) and what the editor leaves behind (~ copies
of the loaded library, .TMP files). The Microsoft C++ runtime DLLs the libraries need are added to
bin/ from Visual Studio's redistributable folder, so the plugin loads on PCs without the Visual C++
Redistributable. The version comes from plugin.cfg.

Then it checks the zip: every file is under addons/holo_forge/, plugin.cfg, the .gdextension and
every DLL the .gdextension or the libraries need is there, and nothing points at this PC's folders.
"""

from __future__ import annotations

import argparse
import configparser
import fnmatch
import hashlib
import io
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parent / "godot-board-racing"
ADDON = PROJECT / "addons" / "holo_forge"
DEFAULT_OUT = Path("C:/Users/Blaze/Holo Builds/holo_forge")
INSTALLER_SCRIPT = HERE / "installer" / "holo_forge_setup.iss"
INSTALLER_STAGE = HERE / "build" / "installer_stage"
ISCC_PLACES = [Path.home() / "AppData/Local/Programs/Inno Setup 6/ISCC.exe",
               Path("C:/Program Files (x86)/Inno Setup 6/ISCC.exe"), Path("C:/Program Files/Inno Setup 6/ISCC.exe")]
VS_REDIST = Path("C:/Program Files/Microsoft Visual Studio/2022/Community/VC/Redist/MSVC")
OCCT_ARCHIVE = Path("C:/Users/Blaze/holo_forge_build/vcpkg/downloads/Open-Cascade-SAS-OCCT-V8_0_1.tar.gz")
OCCT_PORT = Path("C:/Users/Blaze/holo_forge_build/vcpkg/ports/opencascade")

# Left out of the addon: Godot makes these in each project, or the editor leaves them behind.
EXCLUDE = ["*.import", "~*", "*.TMP", "*.tmp", "*.pdb", "*.lib", "*.exp", "*.ilk", "__pycache__", ".DS_Store", "Thumbs.db"]
# The C++ runtime the libraries load (dumpbin /dependents): CRT and OpenMP.
RUNTIME = [("Microsoft.VC143.CRT", "msvcp140.dll"), ("Microsoft.VC143.CRT", "vcruntime140.dll"),
           ("Microsoft.VC143.CRT", "vcruntime140_1.dll"), ("Microsoft.VC143.OpenMP", "vcomp140.dll")]
# Text that must not be in a shipped file: this PC's folders.
PRIVATE_PATHS = [re.compile(rb"Hover_Board_Racing", re.I), re.compile(rb"C:[/\\\\]Users[/\\\\]Blaze", re.I)]
PRIVATE_EXEMPT = ["*.dll"]  # (Binaries can hold their build folders in debug strings; checked apart.)

PLANEGCS_CMAKE = """cmake_minimum_required(VERSION 3.25)
project(planegcs CXX)
# planegcs (FreeCAD's sketch solver, LGPL-2.1-or-later) as Holo Forge builds it: planegcs.dll.
# Needs Eigen 3 and Boost.Graph (for example from vcpkg: eigen3, boost-graph).
find_package(Eigen3 CONFIG REQUIRED)
find_package(Boost CONFIG REQUIRED COMPONENTS graph)
file(GLOB PLANEGCS_SOURCES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/planegcs/App/planegcs/*.cpp")
add_library(planegcs SHARED ${PLANEGCS_SOURCES})
set_target_properties(planegcs PROPERTIES CXX_STANDARD 23)
target_include_directories(planegcs
    PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/planegcs"
    PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/compat")
target_compile_definitions(planegcs PRIVATE PLANEGCS_BUILD EIGEN_NO_DEBUG _USE_MATH_DEFINES NOMINMAX)
target_link_libraries(planegcs PUBLIC Eigen3::Eigen Boost::graph)
if(MSVC)
    target_compile_options(planegcs PRIVATE /EHsc /bigobj /utf-8 /permissive- /Zc:__cplusplus /MP /W1 /wd4251 /wd4244 /wd4996)
endif()
"""

SOURCES_README = """# Holo Forge {version}: LGPL library sources

Holo Forge ships two libraries under the GNU Lesser General Public License 2.1 as separate DLLs
(addons/holo_forge/bin). This archive is their source as built, so you can rebuild or change them
and drop your build in place of the shipped DLL (same file name).

- planegcs/ : FreeCAD's sketch constraint solver (LGPL-2.1-or-later), copied from FreeCAD's
  src/Mod/Sketcher/App/planegcs in October 2026, with FreeCAD's license (planegcs/LICENSE).
- compat/ : small header shims Holo Forge adds so planegcs builds outside FreeCAD.
- CMakeLists.txt : builds planegcs.dll (C++23, Eigen 3, Boost.Graph), as Holo Forge does.
- opencascade/Open-Cascade-SAS-OCCT-V8_0_1.tar.gz : the official OpenCASCADE 8.0.1 source
  (LGPL-2.1 with the OCCT exception; upstream https://github.com/Open-Cascade-SAS/OCCT, tag V8_0_1).
- opencascade/vcpkg-port/ : the vcpkg port the TK*.dll files were built with (no default
  features), including vcpkg's build-file patches.
"""


def plugin_version() -> str:
    parser = configparser.ConfigParser()
    parser.read(ADDON / "plugin.cfg", encoding="utf-8")
    return parser["plugin"]["version"].strip().strip('"')


def excluded(path: Path) -> bool:
    return any(fnmatch.fnmatch(part, pattern) for part in path.parts for pattern in EXCLUDE)


def runtime_folder() -> Path:
    # The newest MSVC redistributable folder that has every runtime DLL.
    for folder in sorted(VS_REDIST.iterdir(), reverse=True):
        if all((folder / "x64" / sub / name).is_file() for sub, name in RUNTIME):
            return folder / "x64"
    sys.exit("No Visual C++ redistributable folder with %s under %s" % (", ".join(n for _, n in RUNTIME), VS_REDIST))


def pe_imports(data: bytes) -> list[str]:
    """The DLL names a Windows PE file imports (its import table)."""
    import struct
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        return []
    sections = struct.unpack_from("<H", data, pe + 6)[0]
    optional_size = struct.unpack_from("<H", data, pe + 20)[0]
    optional = pe + 24
    magic = struct.unpack_from("<H", data, optional)[0]
    directories = optional + (112 if magic == 0x20B else 96)
    import_rva = struct.unpack_from("<I", data, directories + 8)[0]
    table = optional + optional_size
    spans = [struct.unpack_from("<IIII", data, table + 40 * i + 8) for i in range(sections)]  # vsize, va, rawsize, rawptr

    def offset(rva: int) -> int:
        for vsize, va, rawsize, rawptr in spans:
            if va <= rva < va + max(vsize, rawsize):
                return rawptr + rva - va
        return -1

    names = []
    at = offset(import_rva)
    while at >= 0:
        entry = struct.unpack_from("<IIIII", data, at)
        if entry == (0, 0, 0, 0, 0):
            break
        name_at = offset(entry[3])
        names.append(data[name_at:data.index(b"\0", name_at)].decode("ascii"))
        at += 20
    return names


# DLLs Windows provides on every supported version (Windows 10 and later).
SYSTEM_DLLS = {"kernel32.dll", "user32.dll", "advapi32.dll", "ole32.dll", "wsock32.dll", "winmm.dll", "gdi32.dll",
               "shell32.dll", "oleaut32.dll", "ws2_32.dll", "bcrypt.dll", "ntdll.dll", "opengl32.dll", "dbghelp.dll"}


def build_addon_zip(out: Path, version: str) -> Path:
    target = out / ("holo_forge-%s-windows.zip" % version)
    runtime = runtime_folder()
    files: dict[str, bytes] = {}
    for path in sorted(ADDON.rglob("*")):
        rel = path.relative_to(ADDON)
        if path.is_file() and not excluded(rel):
            files["addons/holo_forge/" + rel.as_posix()] = path.read_bytes()
    for sub, name in RUNTIME:
        files["addons/holo_forge/bin/" + name] = (runtime / sub / name).read_bytes()
    check_addon(files)
    write_zip(target, files)
    return target


def check_addon(files: dict[str, bytes]) -> None:
    problems = []
    for need in ["plugin.cfg", "plugin.gd", "self_test.gd", "holo_forge.gdextension", "README.md", "LICENSE.md", "THIRD_PARTY_NOTICES.md", "bin/holo_forge_native.dll"]:
        if "addons/holo_forge/" + need not in files:
            problems.append("missing " + need)
    shipped = {name.rsplit("/", 1)[-1].lower() for name in files if name.startswith("addons/holo_forge/bin/")}
    for name, data in files.items():
        if name.lower().endswith(".dll"):
            for dll in pe_imports(data):
                low = dll.lower()
                if low not in shipped and low not in SYSTEM_DLLS and not low.startswith("api-ms-win-"):
                    problems.append("%s needs %s, which is not shipped" % (name, dll))
        elif not any(fnmatch.fnmatch(name, pattern) for pattern in PRIVATE_EXEMPT):
            for pattern in PRIVATE_PATHS:
                if pattern.search(data):
                    problems.append("%s names a folder on this PC (%s)" % (name, pattern.pattern.decode()))
    if problems:
        sys.exit("Not packaged:\n  " + "\n  ".join(problems))


def build_sources_zip(out: Path, version: str) -> Path:
    target = out / ("holo_forge-%s-lgpl-sources.zip" % version)
    files: dict[str, bytes] = {"README.md": SOURCES_README.format(version=version).encode(), "CMakeLists.txt": PLANEGCS_CMAKE.encode()}
    for root, prefix in [(HERE / "thirdparty" / "planegcs", "planegcs/"), (HERE / "compat", "compat/"), (OCCT_PORT, "opencascade/vcpkg-port/")]:
        for path in sorted(root.rglob("*")):
            if path.is_file() and not excluded(path.relative_to(root)):
                files[prefix + path.relative_to(root).as_posix()] = path.read_bytes()
    if not OCCT_ARCHIVE.is_file():
        sys.exit("The OpenCASCADE source archive is missing: %s" % OCCT_ARCHIVE)
    files["opencascade/" + OCCT_ARCHIVE.name] = OCCT_ARCHIVE.read_bytes()
    write_zip(target, files)
    return target


def build_installer(out: Path, version: str, addon_zip: Path) -> Path:
    """The setup program, made by Inno Setup from exactly what is in the addon zip."""
    iscc = next((place for place in ISCC_PLACES if place.is_file()), None) or shutil.which("ISCC")
    if iscc is None:
        sys.exit("Inno Setup 6 (ISCC.exe) isn't installed; install it, or pass --no-installer.")
    if INSTALLER_STAGE.exists():
        shutil.rmtree(INSTALLER_STAGE)
    with zipfile.ZipFile(addon_zip) as archive:
        archive.extractall(INSTALLER_STAGE)
    target = out / ("holo_forge-%s-windows-setup.exe" % version)
    command = [str(iscc), "/Q", "/DAppVersion=" + version, "/DAddonSource=" + str(INSTALLER_STAGE / "addons" / "holo_forge"),
               "/O" + str(out), str(INSTALLER_SCRIPT)]
    run = subprocess.run(command, capture_output=True, text=True)
    if run.returncode != 0 or not target.is_file():
        sys.exit("Inno Setup failed:\n" + run.stdout + run.stderr)
    shutil.rmtree(INSTALLER_STAGE)
    return target


def write_zip(target: Path, files: dict[str, bytes]) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    partial = target.with_suffix(".zip.partial")
    with zipfile.ZipFile(partial, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name in sorted(files):
            info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_STORED if name.endswith(".tar.gz") else zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, files[name])
    with zipfile.ZipFile(partial) as archive:
        bad = archive.testzip()
        if bad is not None:
            sys.exit("The zip is damaged at %s" % bad)
    partial.replace(target)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--no-installer", action="store_true", help="make only the zips")
    args = parser.parse_args()
    version = plugin_version()
    addon_zip = build_addon_zip(args.out, version)
    made = [addon_zip, build_sources_zip(args.out, version)]
    if not args.no_installer:
        made.append(build_installer(args.out, version, addon_zip))
    for path in made:
        if path.suffix == ".zip":
            with zipfile.ZipFile(path) as archive:
                detail = "%d files" % len(archive.namelist())
        else:
            detail = "installer"
        print("%s  %s  %.1f MB  sha256 %s" % (path, detail, path.stat().st_size / 1e6, sha256(path)))


if __name__ == "__main__":
    main()
