#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/transform3d.hpp>

#include "cad_shape.h"

namespace holo_forge
{

/// Stateless modeling operations on CadShape. Coordinates are Godot's (Y up).
/// Every operation returns null and pushes an error when the kernel fails.
class CadKernel: public godot::RefCounted
{
    GDCLASS(CadKernel, godot::RefCounted)

public:
    enum BooleanOp
    {
        BOOLEAN_FUSE = 0,
        BOOLEAN_CUT = 1,
        BOOLEAN_COMMON = 2,
    };

    godot::String version() const;

    godot::Ref<CadShape> make_box(const godot::Vector3& size, const godot::Vector3& origin, const godot::String& tag) const;
    godot::Ref<CadShape> make_cylinder(
        double radius,
        double height,
        const godot::Vector3& origin,
        const godot::Vector3& axis,
        const godot::String& tag
    ) const;
    godot::Ref<CadShape> make_sphere(double radius, const godot::Vector3& center, const godot::String& tag) const;

    godot::Ref<CadShape> boolean(
        const godot::Ref<CadShape>& target,
        const godot::Ref<CadShape>& tool,
        int operation,
        const godot::String& tag
    ) const;

    // --- Solid features (options per solid_ops.h; every result carries face/edge names) ---
    godot::Ref<CadShape> extrude(const godot::Ref<CadShape>& profile, const godot::Dictionary& params) const;
    godot::Ref<CadShape> revolve(const godot::Ref<CadShape>& profile, const godot::Dictionary& params) const;
    godot::Ref<CadShape> sweep(const godot::Ref<CadShape>& profile, const godot::Ref<CadShape>& path, const godot::Dictionary& params) const;
    godot::Ref<CadShape> loft(const godot::Array& sections, const godot::Dictionary& params) const;
    godot::Ref<CadShape> helix(const godot::Dictionary& params) const;
    godot::Ref<CadShape> coil(const godot::Dictionary& params) const;
    godot::Ref<CadShape> pipe(const godot::Ref<CadShape>& path, const godot::Dictionary& params) const;
    godot::Ref<CadShape> thread(const godot::Dictionary& params) const;
    godot::Ref<CadShape> torus(const godot::Dictionary& params) const;
    godot::Ref<CadShape> fillet(const godot::Ref<CadShape>& shape, const godot::PackedInt32Array& edges, const godot::Dictionary& params) const;
    godot::Ref<CadShape> chamfer(const godot::Ref<CadShape>& shape, const godot::PackedInt32Array& edges, const godot::Dictionary& params) const;
    godot::Ref<CadShape> shell(const godot::Ref<CadShape>& shape, const godot::PackedInt32Array& faces, const godot::Dictionary& params) const;
    godot::Ref<CadShape> draft(const godot::Ref<CadShape>& shape, const godot::PackedInt32Array& faces, const godot::Dictionary& params) const;
    godot::Ref<CadShape> transform_shape(const godot::Ref<CadShape>& shape, const godot::Transform3D& xform, const godot::String& tag) const;
    /// Phase 8 fix round 1 (transform64.cpp): the shape moved by a rigid move given in doubles, with
    /// no float32 step. m is an xform64 (core/assembly/xform64.gd): 12 doubles, elements 0-2 the
    /// basis column X (the image of the X axis), 3-5 the column Y, 6-8 the column Z, 9-11 the
    /// origin, in meters. Only a rigid move is taken (finite, columns orthonormal within 1e-9, no
    /// mirror); anything else gives null and a sentence in get_last_error(). Face and edge names
    /// are kept.
    godot::Ref<CadShape> transform_shape64(const godot::Ref<CadShape>& shape, const godot::PackedFloat64Array& m, const godot::String& tag) const;
    godot::Ref<CadShape> offset_faces(const godot::Ref<CadShape>& shape, const godot::PackedInt32Array& faces, double distance, const godot::String& tag) const;
    godot::Ref<CadShape> offset_shape(const godot::Ref<CadShape>& shape, double distance, const godot::String& tag) const;
    godot::Ref<CadShape> split_body(const godot::Ref<CadShape>& shape, const godot::Ref<CadShape>& tool, const godot::Dictionary& params) const;
    godot::Ref<CadShape> split_faces(const godot::Ref<CadShape>& shape, const godot::PackedInt32Array& faces, const godot::Ref<CadShape>& tool, const godot::String& tag) const;
    godot::Ref<CadShape> thicken(const godot::Ref<CadShape>& shape, const godot::PackedInt32Array& faces, const godot::Dictionary& params) const;
    godot::Ref<CadShape> replace_faces(const godot::Ref<CadShape>& shape, const godot::PackedInt32Array& faces, const godot::Ref<CadShape>& target, const godot::Dictionary& params) const;
    godot::Ref<CadShape> boundary_fill(const godot::Array& tools, const godot::PackedVector3Array& keep_points, const godot::String& tag) const;
    godot::Ref<CadShape> rib(const godot::Ref<CadShape>& shape, const godot::Ref<CadShape>& wire, const godot::Dictionary& params) const;
    godot::Ref<CadShape> wire_from_edges(const godot::Ref<CadShape>& shape, const godot::PackedInt32Array& edges) const;
    godot::Ref<CadShape> sketch_wire(const godot::Array& curves, const godot::Transform3D& plane) const;
    godot::Ref<CadShape> offset_profile(const godot::Ref<CadShape>& face, double distance) const;
    godot::Ref<CadShape> wire_outline(const godot::Ref<CadShape>& wire, double half_width, const godot::Vector3& normal) const;
    godot::Ref<CadShape> mirror_shape(const godot::Ref<CadShape>& shape, const godot::Vector3& origin, const godot::Vector3& normal, const godot::String& tag) const;
    godot::Ref<CadShape> plane_face(const godot::Vector3& origin, const godot::Vector3& normal, double size, const godot::String& tag) const;
    godot::Ref<CadShape> make_vertex(const godot::Vector3& point) const;
    godot::Ref<CadShape> make_compound(const godot::Array& shapes) const;
    godot::Dictionary closest_points(const godot::Ref<CadShape>& a, const godot::Ref<CadShape>& b) const;
    /// The cross-section of a solid by the plane through origin square to normal, as flat faces (none
    /// when the plane misses it); null with an error when it can't be made exactly.
    godot::Ref<CadShape> section_faces(const godot::Ref<CadShape>& solid, const godot::Vector3& origin, const godot::Vector3& normal) const;

    // --- Surfaces (options per surface_ops.h) ---
    godot::Ref<CadShape> patch(const godot::Array& boundary, const godot::PackedVector3Array& points, const godot::Dictionary& params) const;
    godot::Ref<CadShape> ruled(const godot::Ref<CadShape>& shape, const godot::PackedInt32Array& edges, const godot::Dictionary& params) const;
    godot::Ref<CadShape> offset_surface(const godot::Ref<CadShape>& shape, const godot::PackedInt32Array& faces, double distance, const godot::String& tag) const;
    godot::Ref<CadShape> stitch(const godot::Array& shapes, const godot::Dictionary& params) const;
    godot::Ref<CadShape> keep_faces(const godot::Ref<CadShape>& shape, const godot::PackedInt32Array& faces) const;
    godot::Array pieces(const godot::Ref<CadShape>& shape) const;
    godot::Ref<CadShape> trim(const godot::Ref<CadShape>& shape, const godot::Ref<CadShape>& tool, const godot::PackedVector3Array& remove_points, const godot::Dictionary& params) const;
    godot::Ref<CadShape> untrim(const godot::Ref<CadShape>& shape, const godot::PackedInt32Array& faces, const godot::PackedInt32Array& edges, const godot::Dictionary& params) const;
    godot::Ref<CadShape> extend_surface(const godot::Ref<CadShape>& shape, const godot::PackedInt32Array& edges, const godot::Dictionary& params) const;
    godot::Ref<CadShape> merge_faces(const godot::Ref<CadShape>& shape, const godot::PackedInt32Array& edges, const godot::PackedInt32Array& faces, const godot::String& tag) const;
    godot::Ref<CadShape> reverse_faces(const godot::Ref<CadShape>& shape, const godot::PackedInt32Array& faces) const;

    // --- Data exchange (see exchange.h: STEP/IGES/STL in millimeters, BREP in meters) ---
    godot::Ref<CadShape> import_file(const godot::String& path, const godot::String& tag) const;
    bool export_file(const godot::Array& shapes, const godot::String& path) const;
    godot::Ref<CadShape> mesh_to_shape(const godot::PackedVector3Array& positions, const godot::PackedInt32Array& indices, const godot::String& tag) const;
    /// Curvature along a sketch curve dictionary: {"points", "curvature" (signed: positive turns
    /// left), "normals" (toward the left)} at count evenly spaced parameters.
    godot::Dictionary curve_curvature(const godot::Dictionary& curve, int count) const;

    /// Rounds the given edges (ids match CadShape.tessellate edge_ids) with a constant radius.
    godot::Ref<CadShape> fillet_edges(
        const godot::Ref<CadShape>& shape,
        const godot::PackedInt32Array& edge_ids,
        double radius
    ) const;

    // --- Sketch geometry (see sketch_geometry.h for the curve dictionaries) ---

    /// Closed regions (profiles) the curves bound: [{"face", "area", "loops"}].
    godot::Array sketch_regions(const godot::Array& curves, const godot::Transform3D& plane, double deflection) const;
    /// The curves as exact edges on the plane, in one compound.
    godot::Ref<CadShape> sketch_edges(const godot::Array& curves, const godot::Transform3D& plane) const;
    godot::Dictionary curve_intersections(const godot::Dictionary& a, const godot::Dictionary& b) const;
    godot::Dictionary curve_closest_point(const godot::Dictionary& curve, const godot::Vector2& point) const;
    godot::PackedVector2Array sample_curve(const godot::Dictionary& curve, double deflection) const;
    godot::Array offset_curves(const godot::Array& chain, double distance) const;
    godot::Array project_edges(const godot::Ref<CadShape>& shape, const godot::PackedInt32Array& edge_ids, const godot::Transform3D& plane) const;
    godot::Array section_curves(const godot::Ref<CadShape>& shape, const godot::Transform3D& plane) const;
    godot::Array project_curves_to_faces(const godot::Array& curves, const godot::Transform3D& plane, const godot::Ref<CadShape>& shape,
        const godot::PackedInt32Array& face_ids, const godot::Vector3& direction, double deflection) const;
    godot::Array intersection_curves(const godot::Array& curves, const godot::Transform3D& plane, const godot::Ref<CadShape>& shape,
        const godot::PackedInt32Array& face_ids, double deflection) const;
    godot::Array isocurves(const godot::Ref<CadShape>& shape, int face_id, int direction, const godot::PackedFloat64Array& params, double deflection) const;

    /// What went wrong in the last sketch geometry call ("" when it worked).
    godot::String get_last_error() const;
    /// A note on how the last operation went when it did something other than asked (an Extend
    /// that fell back to tangent strips, a Patch that built G1 edges G0 or passes near its rails);
    /// "" otherwise. Cleared wherever the error is reported.
    godot::String get_last_warning() const;
    /// The longest (seconds) a boolean, an offset or a shell runs before it is stopped and refused
    /// with an error (20 by default; shared by every kernel).
    static void set_time_limit(double seconds);
    static double get_time_limit();

protected:
    static void _bind_methods();

private:
    void report(const godot::String& error) const;
    mutable godot::String last_error;
    mutable godot::String last_warning;
};

}  // namespace holo_forge

VARIANT_ENUM_CAST(holo_forge::CadKernel::BooleanOp);
