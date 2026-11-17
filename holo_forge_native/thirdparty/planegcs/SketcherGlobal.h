// Holo Forge shim: replaces FreeCAD's Mod/Sketcher/SketcherGlobal.h so planegcs builds standalone.
// planegcs is compiled into its own planegcs.dll (LGPL-2.1-or-later stays dynamically linked).
#pragma once

#if defined(_WIN32)
#  if defined(PLANEGCS_BUILD)
#    define SketcherExport __declspec(dllexport)
#  else
#    define SketcherExport __declspec(dllimport)
#  endif
#else
#  define SketcherExport __attribute__((visibility("default")))
#endif
