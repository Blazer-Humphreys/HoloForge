#pragma once
// Phase 8 fix round 1 (verifier B4): rigid moves given in doubles, with no float32 step.
//
// An xform64 (core/assembly/xform64.gd, contract C1.3) is 12 doubles in Godot's Transform3D
// layout: elements 0-2 the basis column X (the image of the X axis), 3-5 the column Y, 6-8 the
// column Z, 9-11 the origin, in meters. A point p moves to
//   p'[k] = m[k] p[0] + m[3 + k] p[1] + m[6 + k] p[2] + m[9 + k].

#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <string>

namespace holo_forge
{
class CadShape;

namespace xform64
{
/// How far the basis may be from orthonormal (|c_i . c_j - delta_ij|) and still count as a rigid
/// turn: xform64.gd composes to about 1e-12, Godot's float32 Transform3D to about 1e-7.
constexpr double RIGID_TOLERANCE = 1e-9;

/// m as 12 doubles when it is a rigid move (12 finite numbers, columns orthonormal within
/// RIGID_TOLERANCE, no mirror); else false and the sentence in error.
bool rigid(const godot::PackedFloat64Array& m, double out[12], std::string& error);

/// The shape moved by m (CadKernel.transform_shape64): null and error when m is not a rigid move
/// or the shape is empty. Face and edge names are kept.
godot::Ref<CadShape> transform_shape(const godot::Ref<CadShape>& shape, const godot::PackedFloat64Array& m, const std::string& tag, godot::String& error);
}  // namespace xform64

}  // namespace holo_forge
