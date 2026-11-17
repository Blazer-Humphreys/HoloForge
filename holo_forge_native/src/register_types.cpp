#include <gdextension_interface.h>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

#include "cad_kernel.h"
#include "cad_mesh.h"
#include "cad_shape.h"
#include "cad_sketch_solver.h"
#include "cad_subd.h"

#include <OSD_ThreadPool.hxx>
#include <Standard_Failure.hxx>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#endif

using namespace godot;

namespace
{
void initialize_holo_forge(ModuleInitializationLevel level)
{
    if (level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }
    GDREGISTER_CLASS(holo_forge::CadShape);
    GDREGISTER_CLASS(holo_forge::CadKernel);
    GDREGISTER_CLASS(holo_forge::CadSketchSolver);
    GDREGISTER_CLASS(holo_forge::CadSubD);
    GDREGISTER_CLASS(holo_forge::CadMesh);
}

void uninitialize_holo_forge(ModuleInitializationLevel level)
{
    if (level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }
    // OCCT's thread pool (parallel booleans) is stopped here: left to its static destructor, it
    // waits for its threads while Windows unloads the DLL and deadlocks on the loader lock.
    try {
        OSD_ThreadPool::DefaultPool()->Init(1);
    }
    catch (const Standard_Failure&) {
    }
}
}  // namespace

extern "C"
{
GDExtensionBool GDE_EXPORT holo_forge_library_init(
    GDExtensionInterfaceGetProcAddress get_proc_address,
    const GDExtensionClassLibraryPtr library,
    GDExtensionInitialization* initialization
)
{
#ifdef _WIN32
    // Stay loaded until the process exits (the extension is not reloadable anyway). When Godot
    // FreeLibrary()s us at shutdown, Windows unloads OpenCASCADE's DLLs one by one, dependents
    // first: TKDESTEP/TKDEIGES are unmapped before TKXSBase, whose static controller table
    // (XSControl_Controller's "listad") still holds their STEP/IGES controllers, so its destructor
    // calls through a vtable in an unmapped DLL (an access violation inside the loader). Pinned,
    // the DLLs stay mapped and their static destructors run at process exit like any OCCT app's.
    HMODULE self = nullptr;
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
                       reinterpret_cast<LPCWSTR>(&holo_forge_library_init), &self);
#endif
    GDExtensionBinding::InitObject init_obj(get_proc_address, library, initialization);
    init_obj.register_initializer(initialize_holo_forge);
    init_obj.register_terminator(uninitialize_holo_forge);
    init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
    return init_obj.init();
}
}
