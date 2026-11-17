cmake_minimum_required(VERSION 3.28)

project(holo_forge_native LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Where the built DLLs are copied (the addon inside the game project).
set(HOLO_FORGE_ADDON_BIN_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/../godot-board-racing/addons/holo_forge/bin"
    CACHE PATH "Destination folder for holo_forge_native.dll and its dependencies")

# --- godot-cpp (editor-only extension, shared MSVC runtime, exceptions on for OpenCASCADE) ---
set(GODOTCPP_TARGET "editor" CACHE STRING "" FORCE)
set(GODOTCPP_API_VERSION "4.7" CACHE STRING "" FORCE)
set(GODOTCPP_USE_STATIC_CPP OFF CACHE BOOL "" FORCE)
set(GODOTCPP_DISABLE_EXCEPTIONS OFF CACHE BOOL "" FORCE)
add_subdirectory(thirdparty/godot-cpp)

# --- Libraries from vcpkg ---
find_package(OpenCASCADE CONFIG REQUIRED)
find_package(Eigen3 CONFIG REQUIRED)
find_package(boost_graph CONFIG REQUIRED)
# OpenSubdiv (Modified Apache 2.0): Catmull-Clark limit surfaces for the Form workspace. Static
# (osdCPU.lib), so no extra DLL ships; its imported target carries no include directories.
find_package(OpenSubdiv CONFIG REQUIRED)
# Mesh workspace libraries, each in its own DLL (pmp.dll, manifold.dll, meshoptimizer.dll):
# pmp-library (MIT; remesh, decimate, fair, smooth), Manifold (Apache 2.0; booleans, plane cuts,
# level sets; Clipper2, BSL-1.0, is static inside manifold.dll) and meshoptimizer (MIT; fast
# simplify). pmp's config names OpenMP::OpenMP_CXX without finding it, so OpenMP comes first.
find_package(OpenMP REQUIRED)
find_package(pmp CONFIG REQUIRED)
find_package(manifold CONFIG REQUIRED)
find_package(meshoptimizer CONFIG REQUIRED)

set(HOLO_FORGE_MSVC_FLAGS /EHsc /bigobj /utf-8 /permissive- /Zc:__cplusplus /MP)

# --- planegcs (FreeCAD sketch solver, LGPL-2.1-or-later) as its own DLL ---
file(GLOB PLANEGCS_SOURCES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/thirdparty/planegcs/App/planegcs/*.cpp")
add_library(planegcs SHARED ${PLANEGCS_SOURCES})
# FreeCAD's solver uses std::unreachable (C++23).
set_target_properties(planegcs PROPERTIES CXX_STANDARD 23)
target_include_directories(planegcs
    PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/thirdparty/planegcs"
    PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/compat")
target_compile_definitions(planegcs
    PRIVATE PLANEGCS_BUILD EIGEN_NO_DEBUG _USE_MATH_DEFINES NOMINMAX)
# Public: planegcs headers include Eigen and Boost.Math, so users of GCS.h need both.
target_link_libraries(planegcs PUBLIC Eigen3::Eigen Boost::graph)
if(MSVC)
    target_compile_options(planegcs PRIVATE ${HOLO_FORGE_MSVC_FLAGS} /W1 /wd4251 /wd4244 /wd4996)
endif()

# --- holo_forge_native (the GDExtension) ---
file(GLOB HOLO_FORGE_SOURCES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/src/*.cpp")
add_library(holo_forge_native SHARED ${HOLO_FORGE_SOURCES})
target_compile_definitions(holo_forge_native PRIVATE _USE_MATH_DEFINES NOMINMAX)
# pmp has no version macro; vcpkg's port version is reported (CadMesh.library_versions).
target_compile_definitions(holo_forge_native PRIVATE HOLO_FORGE_PMP_PORT_VERSION="3.0.0")
# pmp's target brings OpenMP's compile flag with it. Eigen would then run its matrix products on
# OpenMP threads; it stays on the calling thread, as it did before pmp was linked.
target_compile_definitions(holo_forge_native PRIVATE EIGEN_DONT_PARALLELIZE)
target_include_directories(holo_forge_native PRIVATE ${OpenSubdiv_INCLUDE_DIR})
target_link_libraries(holo_forge_native
    PRIVATE
        godot-cpp
        planegcs
        OpenSubdiv::osdCPU_static
        Eigen3::Eigen
        pmp manifold::manifold meshoptimizer::meshoptimizer
        TKernel TKMath TKG2d TKG3d TKGeomBase TKBRep TKGeomAlgo TKTopAlgo
        TKPrim TKBO TKBool TKFillet TKOffset TKFeat TKShHealing TKMesh
        TKXSBase TKDE TKDESTEP TKDEIGES TKDESTL)
if(MSVC)
    target_compile_options(holo_forge_native PRIVATE ${HOLO_FORGE_MSVC_FLAGS} /W3 /wd4251)
endif()
set_target_properties(holo_forge_native PROPERTIES OUTPUT_NAME "holo_forge_native")
if(MSVC)
    # The time bound on OCCT's blends turns a hardware breakpoint into a C++ exception.
    set_source_files_properties("${CMAKE_CURRENT_SOURCE_DIR}/src/occt_guard.cpp" PROPERTIES COMPILE_OPTIONS "/EHa")
endif()

# Copy the extension, planegcs and every runtime DLL it pulls in (OpenCASCADE, ...) into the addon.
add_custom_command(TARGET holo_forge_native POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "${HOLO_FORGE_ADDON_BIN_DIR}"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        $<TARGET_FILE:holo_forge_native>
        $<TARGET_FILE:planegcs>
        $<TARGET_RUNTIME_DLLS:holo_forge_native>
        "${HOLO_FORGE_ADDON_BIN_DIR}"
    COMMAND_EXPAND_LISTS)
