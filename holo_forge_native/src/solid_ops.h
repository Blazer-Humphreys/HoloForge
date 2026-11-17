#pragma once

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/transform3d.hpp>

#include "cad_shape.h"

namespace holo_forge::ops
{

/// Solid modeling operations behind the Create and Modify tools. Each takes its options as a
/// Dictionary (including "tag", the feature id used to name new faces), returns a named shape,
/// and sets error (leaving the result null) when the kernel can't do it.
using Shape = godot::Ref<CadShape>;

Shape named(const TopoDS_Shape& shape, const std::string& tag);
Shape box(const godot::Vector3& size, const godot::Vector3& origin, const std::string& tag);
Shape cylinder(double radius, double height, const godot::Vector3& origin, const godot::Vector3& axis, const std::string& tag);
Shape sphere(double radius, const godot::Vector3& center, const std::string& tag);
Shape torus(const godot::Dictionary& p, godot::String& error);
/// target joined with (0), cut by (1) or intersected with (2) tool; refused when the result of solids
/// comes out wrong by their volumes (OCCT can report success with the target left uncut, emptied or
/// grown). The shapes given are left as they were.
Shape boolean(const Shape& target, const Shape& tool, int operation, const std::string& tag, godot::String& error);

Shape extrude(const Shape& profile, const godot::Dictionary& p, godot::String& error);
Shape revolve(const Shape& profile, const godot::Dictionary& p, godot::String& error);
/// Sweeps, lofts, coils, pipes and threads are fitted to within a ten-millionth of their profile's
/// size; one that could only be built looser says how near it came in note. Sweeps (guided ones
/// too), pipes and coils that would fold over a bend or overlap where the path comes back near
/// itself (a coil's next turn) are refused, saying by how much. A loft along a rail keeps its
/// sections where they are drawn, the rail shaping the walls between them.
Shape sweep(const Shape& profile, const Shape& path, const godot::Dictionary& p, godot::String& error, godot::String& note);
Shape loft(const godot::Array& sections, const godot::Dictionary& p, godot::String& error, godot::String& note);
Shape helix(const godot::Dictionary& p, godot::String& error);
Shape coil(const godot::Dictionary& p, godot::String& error, godot::String& note);
Shape pipe(const Shape& path, const godot::Dictionary& p, godot::String& error, godot::String& note);
Shape thread(const godot::Dictionary& p, godot::String& error, godot::String& note);

/// Fillets and chamfers are built with tolerances for the part's size; one that only OCCT's own
/// tolerances (0.1 mm) would build says so in note.
Shape fillet(const Shape& shape, const godot::PackedInt32Array& edges, const godot::Dictionary& p, godot::String& error, godot::String& note);
Shape chamfer(const Shape& shape, const godot::PackedInt32Array& edges, const godot::Dictionary& p, godot::String& error, godot::String& note);
Shape shell(const Shape& shape, const godot::PackedInt32Array& faces, const godot::Dictionary& p, godot::String& error);
Shape draft(const Shape& shape, const godot::PackedInt32Array& faces, const godot::Dictionary& p, godot::String& error);
Shape transform(const Shape& shape, const godot::Transform3D& xform, const std::string& tag, godot::String& error);
Shape offset_faces(const Shape& shape, const godot::PackedInt32Array& faces, double distance, const std::string& tag, godot::String& error);
Shape offset_shape(const Shape& shape, double distance, const std::string& tag, godot::String& error);
/// The longest (seconds) a boolean, an offset or a shell may run before it is stopped and refused
/// with an error (20 by default): OCCT's algorithms look for a stop between their steps.
double time_limit();
void set_time_limit(double seconds);
Shape split_body(const Shape& shape, const Shape& tool, const godot::Dictionary& p, godot::String& error);
Shape split_faces(const Shape& shape, const godot::PackedInt32Array& faces, const Shape& tool, const std::string& tag, godot::String& error);
Shape thicken(const Shape& shape, const godot::PackedInt32Array& faces, const godot::Dictionary& p, godot::String& error);
/// A solid's flat faces (facing one way) moved onto target (a surface, a face or a big plane face):
/// each point of them to the target's crossing of its normal line nearest it (a closed target's
/// near side), the solid growing out to it or cut back to it, the faces round them (which must
/// run along their normal; refused naming one that doesn't) carried on. The faces on the target
/// take the first replaced face's name.
Shape replace_faces(const Shape& shape, const godot::PackedInt32Array& faces, const Shape& target, const godot::Dictionary& p, godot::String& error);
Shape boundary_fill(const godot::Array& tools, const godot::PackedVector3Array& keep_points, const std::string& tag, godot::String& error);
Shape rib(const Shape& shape, const Shape& wire, const godot::Dictionary& p, godot::String& error);

Shape wire_from_edges(const Shape& shape, const godot::PackedInt32Array& edges, godot::String& error);
/// A flat profile grown (positive) or shrunk within its plane, holes included.
Shape offset_profile(const Shape& face, double distance, godot::String& error);
/// A closed outline half_width around an open (or closed) wire lying in the plane with this normal,
/// with round ends, as a flat face.
Shape wire_outline(const Shape& wire, double half_width, const godot::Vector3& normal, godot::String& error);
Shape mirror(const Shape& shape, const godot::Vector3& origin, const godot::Vector3& normal, const std::string& tag, godot::String& error);
Shape plane_face(const godot::Vector3& origin, const godot::Vector3& normal, double size, const std::string& tag);
Shape vertex(const godot::Vector3& point);
Shape compound(const godot::Array& shapes);
godot::Dictionary closest_points(const Shape& a, const Shape& b, godot::String& error);
/// A solid's cross-section by the plane through origin square to normal, as flat faces (none when
/// the plane misses it). Made scaled up when small, and checked against the plane's crossing of
/// the solid's faces: refused (with error) when, beside that crossing, the faces don't cover the
/// plane exactly where the solid is, or their outline runs past it. A plane along a face or touching
/// a side along a line is sectioned as any other.
Shape section(const Shape& solid, const godot::Vector3& origin, const godot::Vector3& normal, godot::String& error);

}  // namespace holo_forge::ops
