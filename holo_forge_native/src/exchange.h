#pragma once

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

#include "cad_shape.h"

namespace holo_forge::exchange
{

/// Reading and writing other CAD formats. Holo Forge works in meters; STEP, IGES and STL files
/// are read and written in millimeters (STEP and IGES readers convert the file's own unit first),
/// BREP files stay in meters.
using Shape = godot::Ref<CadShape>;

/// .step/.stp, .iges/.igs, .brep or .stl. Faces are named "<tag>:f#k".
Shape import_file(const godot::String& path, const std::string& tag, godot::String& error);
/// Writes the shapes (one compound) to .step/.stp, .iges/.igs, .brep or .stl (binary).
bool export_file(const godot::Array& shapes, const godot::String& path, godot::String& error);
/// A triangle mesh as a shape of flat faces: a solid when the mesh is closed, else a shell.
Shape mesh_to_shape(const godot::PackedVector3Array& positions, const godot::PackedInt32Array& indices, const std::string& tag, godot::String& error);

}  // namespace holo_forge::exchange
