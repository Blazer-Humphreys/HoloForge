#include "cad_kernel.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include "sketch_geometry.h"
#include "solid_ops.h"
#include "surface_ops.h"
#include "exchange.h"
#include "transform64.h"
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <Geom2d_Curve.hxx>

#include <BRepAlgoAPI_Common.hxx>
#include <BRep_Builder.hxx>
#include <TopoDS_Compound.hxx>
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepAlgoAPI_Fuse.hxx>
#include <BRepFilletAPI_MakeFillet.hxx>
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <BRepPrimAPI_MakeSphere.hxx>
#include <Standard_Failure.hxx>
#include <Standard_Version.hxx>
#include <Precision.hxx>
#include <TopExp.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Edge.hxx>
#include <gp_Ax2.hxx>

using namespace godot;

namespace holo_forge
{

namespace
{
gp_Pnt to_occ_point(const Vector3& v)
{
    return gp_Pnt(v.x, v.y, v.z);
}

bool valid_shape(const Ref<CadShape>& shape, const char* op)
{
    if (shape.is_null() || shape->is_null()) {
        UtilityFunctions::push_error("CadKernel.", op, ": shape is null");
        return false;
    }
    return true;
}
}  // namespace

String CadKernel::version() const
{
    return String("OpenCASCADE ") + OCC_VERSION_COMPLETE;
}

static std::string utf8(const String& s)
{
    return s.utf8().get_data();
}

Ref<CadShape> CadKernel::make_box(const Vector3& size, const Vector3& origin, const String& tag) const
{
    report("");
    if (size.x <= 0.0 || size.y <= 0.0 || size.z <= 0.0) {
        report("Every box size must be positive");
        UtilityFunctions::push_error("CadKernel.make_box: every size component must be positive");
        return Ref<CadShape>();
    }
    try {
        return ops::box(size, origin, tag == "" ? "box" : utf8(tag));
    }
    catch (const Standard_Failure& failure) {
        UtilityFunctions::push_error("CadKernel.make_box failed: ", failure.GetMessageString());
        return Ref<CadShape>();
    }
}

Ref<CadShape> CadKernel::make_cylinder(double radius, double height, const Vector3& origin, const Vector3& axis, const String& tag) const
{
    report("");
    if (radius <= 0.0 || height <= 0.0 || axis.is_zero_approx()) {
        UtilityFunctions::push_error("CadKernel.make_cylinder: radius, height and axis must be non-zero");
        return Ref<CadShape>();
    }
    try {
        return ops::cylinder(radius, height, origin, axis, tag == "" ? "cylinder" : utf8(tag));
    }
    catch (const Standard_Failure& failure) {
        UtilityFunctions::push_error("CadKernel.make_cylinder failed: ", failure.GetMessageString());
        return Ref<CadShape>();
    }
}

Ref<CadShape> CadKernel::make_sphere(double radius, const Vector3& center, const String& tag) const
{
    report("");
    if (radius <= 0.0) {
        UtilityFunctions::push_error("CadKernel.make_sphere: radius must be positive");
        return Ref<CadShape>();
    }
    try {
        return ops::sphere(radius, center, tag == "" ? "sphere" : utf8(tag));
    }
    catch (const Standard_Failure& failure) {
        UtilityFunctions::push_error("CadKernel.make_sphere failed: ", failure.GetMessageString());
        return Ref<CadShape>();
    }
}

Ref<CadShape> CadKernel::boolean(const Ref<CadShape>& target, const Ref<CadShape>& tool, int operation, const String& tag) const
{
    report("");
    if (!valid_shape(target, "boolean") || !valid_shape(tool, "boolean")) {
        return Ref<CadShape>();
    }
    String error;
    Ref<CadShape> result = ops::boolean(target, tool, operation, tag == "" ? "boolean" : utf8(tag), error);
    report(error);
    return result;
}

Ref<CadShape> CadKernel::fillet_edges(const Ref<CadShape>& shape, const PackedInt32Array& edge_ids, double radius) const
{
    Dictionary params;
    params["radius"] = radius;
    return fillet(shape, edge_ids, params);
}

#define HOLO_FORGE_OP(call)        \
    report("");                    \
    String error;                  \
    Ref<CadShape> result = call;   \
    report(error);                 \
    return result;

Ref<CadShape> CadKernel::extrude(const Ref<CadShape>& profile, const Dictionary& params) const { HOLO_FORGE_OP(ops::extrude(profile, params, error)) }
Ref<CadShape> CadKernel::revolve(const Ref<CadShape>& profile, const Dictionary& params) const { HOLO_FORGE_OP(ops::revolve(profile, params, error)) }
// Fitted ops: what they couldn't fit as closely as asked is the last warning.
#define HOLO_FORGE_NOTED_OP(call) \
    report("");                   \
    String error;                 \
    String note;                  \
    Ref<CadShape> result = call;  \
    report(error);                \
    last_warning = note;          \
    return result;

Ref<CadShape> CadKernel::sweep(const Ref<CadShape>& profile, const Ref<CadShape>& path, const Dictionary& params) const { HOLO_FORGE_NOTED_OP(ops::sweep(profile, path, params, error, note)) }
Ref<CadShape> CadKernel::loft(const Array& sections, const Dictionary& params) const { HOLO_FORGE_NOTED_OP(ops::loft(sections, params, error, note)) }
Ref<CadShape> CadKernel::helix(const Dictionary& params) const { HOLO_FORGE_OP(ops::helix(params, error)) }
Ref<CadShape> CadKernel::coil(const Dictionary& params) const { HOLO_FORGE_NOTED_OP(ops::coil(params, error, note)) }
Ref<CadShape> CadKernel::pipe(const Ref<CadShape>& path, const Dictionary& params) const { HOLO_FORGE_NOTED_OP(ops::pipe(path, params, error, note)) }
Ref<CadShape> CadKernel::thread(const Dictionary& params) const { HOLO_FORGE_NOTED_OP(ops::thread(params, error, note)) }
Ref<CadShape> CadKernel::torus(const Dictionary& params) const { HOLO_FORGE_OP(ops::torus(params, error)) }
Ref<CadShape> CadKernel::fillet(const Ref<CadShape>& shape, const PackedInt32Array& edges, const Dictionary& params) const { HOLO_FORGE_NOTED_OP(ops::fillet(shape, edges, params, error, note)) }
Ref<CadShape> CadKernel::chamfer(const Ref<CadShape>& shape, const PackedInt32Array& edges, const Dictionary& params) const { HOLO_FORGE_NOTED_OP(ops::chamfer(shape, edges, params, error, note)) }
Ref<CadShape> CadKernel::shell(const Ref<CadShape>& shape, const PackedInt32Array& faces, const Dictionary& params) const { HOLO_FORGE_OP(ops::shell(shape, faces, params, error)) }
Ref<CadShape> CadKernel::draft(const Ref<CadShape>& shape, const PackedInt32Array& faces, const Dictionary& params) const { HOLO_FORGE_OP(ops::draft(shape, faces, params, error)) }
Ref<CadShape> CadKernel::transform_shape(const Ref<CadShape>& shape, const Transform3D& xform, const String& tag) const { HOLO_FORGE_OP(ops::transform(shape, xform, utf8(tag), error)) }
Ref<CadShape> CadKernel::transform_shape64(const Ref<CadShape>& shape, const PackedFloat64Array& m, const String& tag) const { HOLO_FORGE_OP(xform64::transform_shape(shape, m, utf8(tag), error)) }
Ref<CadShape> CadKernel::offset_faces(const Ref<CadShape>& shape, const PackedInt32Array& faces, double distance, const String& tag) const { HOLO_FORGE_OP(ops::offset_faces(shape, faces, distance, utf8(tag), error)) }
Ref<CadShape> CadKernel::offset_shape(const Ref<CadShape>& shape, double distance, const String& tag) const { HOLO_FORGE_OP(ops::offset_shape(shape, distance, utf8(tag), error)) }
Ref<CadShape> CadKernel::split_body(const Ref<CadShape>& shape, const Ref<CadShape>& tool, const Dictionary& params) const { HOLO_FORGE_OP(ops::split_body(shape, tool, params, error)) }
Ref<CadShape> CadKernel::split_faces(const Ref<CadShape>& shape, const PackedInt32Array& faces, const Ref<CadShape>& tool, const String& tag) const { HOLO_FORGE_OP(ops::split_faces(shape, faces, tool, utf8(tag), error)) }
Ref<CadShape> CadKernel::thicken(const Ref<CadShape>& shape, const PackedInt32Array& faces, const Dictionary& params) const { HOLO_FORGE_OP(ops::thicken(shape, faces, params, error)) }
Ref<CadShape> CadKernel::replace_faces(const Ref<CadShape>& shape, const PackedInt32Array& faces, const Ref<CadShape>& target, const Dictionary& params) const { HOLO_FORGE_OP(ops::replace_faces(shape, faces, target, params, error)) }
Ref<CadShape> CadKernel::boundary_fill(const Array& tools, const PackedVector3Array& keep_points, const String& tag) const { HOLO_FORGE_OP(ops::boundary_fill(tools, keep_points, utf8(tag), error)) }
Ref<CadShape> CadKernel::rib(const Ref<CadShape>& shape, const Ref<CadShape>& wire, const Dictionary& params) const { HOLO_FORGE_OP(ops::rib(shape, wire, params, error)) }
Ref<CadShape> CadKernel::wire_from_edges(const Ref<CadShape>& shape, const PackedInt32Array& edges) const { HOLO_FORGE_OP(ops::wire_from_edges(shape, edges, error)) }

Ref<CadShape> CadKernel::offset_profile(const Ref<CadShape>& face, double distance) const { HOLO_FORGE_OP(ops::offset_profile(face, distance, error)) }
Ref<CadShape> CadKernel::wire_outline(const Ref<CadShape>& wire, double half_width, const Vector3& normal) const { HOLO_FORGE_OP(ops::wire_outline(wire, half_width, normal, error)) }
Ref<CadShape> CadKernel::mirror_shape(const Ref<CadShape>& shape, const Vector3& origin, const Vector3& normal, const String& tag) const { HOLO_FORGE_OP(ops::mirror(shape, origin, normal, utf8(tag), error)) }

Ref<CadShape> CadKernel::import_file(const String& path, const String& tag) const { HOLO_FORGE_OP(exchange::import_file(path, tag == "" ? "import" : utf8(tag), error)) }
Ref<CadShape> CadKernel::mesh_to_shape(const PackedVector3Array& positions, const PackedInt32Array& indices, const String& tag) const { HOLO_FORGE_OP(exchange::mesh_to_shape(positions, indices, tag == "" ? "mesh" : utf8(tag), error)) }

bool CadKernel::export_file(const Array& shapes, const String& path) const
{
    String error;
    const bool ok = exchange::export_file(shapes, path, error);
    report(error);
    return ok;
}

Dictionary CadKernel::curve_curvature(const Dictionary& curve, int count) const
{
    Dictionary result;
    String error;
    const std::vector<Handle(Geom2d_Curve)> parts = sketch::curves_from_dict(curve, error);
    report(error);
    PackedVector2Array points, normals;
    PackedFloat64Array curvature;
    if (parts.empty() || count < 2) {
        return result;
    }
    const int per_part = std::max(2, count / int(parts.size()));
    for (const Handle(Geom2d_Curve)& part : parts) {
        const double f = part->FirstParameter();
        const double l = part->LastParameter();
        if (Precision::IsInfinite(f) || Precision::IsInfinite(l)) {
            continue;
        }
        for (int i = 0; i < per_part; ++i) {
            gp_Pnt2d p;
            gp_Vec2d d1, d2;
            part->D2(f + (l - f) * i / (per_part - 1), p, d1, d2);
            const double speed = d1.Magnitude();
            const double k = speed > 1e-12 ? (d1.X() * d2.Y() - d1.Y() * d2.X()) / (speed * speed * speed) : 0.0;
            points.push_back(Vector2(real_t(p.X()), real_t(p.Y())));
            curvature.push_back(k);
            normals.push_back(speed > 1e-12 ? Vector2(real_t(-d1.Y() / speed), real_t(d1.X() / speed)) : Vector2());
        }
    }
    result["points"] = points;
    result["curvature"] = curvature;
    result["normals"] = normals;
    return result;
}

Ref<CadShape> CadKernel::sketch_wire(const Array& curves, const Transform3D& plane) const
{
    String error;
    std::vector<TopoDS_Edge> edges = sketch::edges_on_plane(curves, sketch::to_plane(plane), error);
    BRep_Builder builder;
    TopoDS_Compound compound;
    builder.MakeCompound(compound);
    for (const TopoDS_Edge& edge : edges) {
        builder.Add(compound, edge);
    }
    Ref<CadShape> holder = CadShape::wrap(compound);
    PackedInt32Array all;
    for (int i = 0; i < int(edges.size()); ++i) {
        all.push_back(i);
    }
    Ref<CadShape> result = ops::wire_from_edges(holder, all, error);
    report(error);
    return result;
}

Ref<CadShape> CadKernel::plane_face(const Vector3& origin, const Vector3& normal, double size, const String& tag) const
{
    report("");
    return ops::plane_face(origin, normal, size, tag == "" ? "plane" : utf8(tag));
}

Ref<CadShape> CadKernel::make_vertex(const Vector3& point) const
{
    report("");
    return ops::vertex(point);
}

Ref<CadShape> CadKernel::make_compound(const Array& shapes) const
{
    report("");
    return ops::compound(shapes);
}

Dictionary CadKernel::closest_points(const Ref<CadShape>& a, const Ref<CadShape>& b) const
{
    String error;
    Dictionary result = ops::closest_points(a, b, error);
    report(error);
    return result;
}
Ref<CadShape> CadKernel::section_faces(const Ref<CadShape>& solid, const Vector3& origin, const Vector3& normal) const { HOLO_FORGE_OP(ops::section(solid, origin, normal, error)) }

Ref<CadShape> CadKernel::patch(const Array& boundary, const PackedVector3Array& points, const Dictionary& params) const
{
    String error;
    String note;
    Ref<CadShape> result = ops::patch(boundary, points, params, error, note);
    report(error);
    last_warning = note;
    return result;
}
Ref<CadShape> CadKernel::ruled(const Ref<CadShape>& shape, const PackedInt32Array& edges, const Dictionary& params) const { HOLO_FORGE_OP(ops::ruled(shape, edges, params, error)) }
Ref<CadShape> CadKernel::offset_surface(const Ref<CadShape>& shape, const PackedInt32Array& faces, double distance, const String& tag) const { HOLO_FORGE_NOTED_OP(ops::offset_surface(shape, faces, distance, utf8(tag), error, note)) }
Ref<CadShape> CadKernel::stitch(const Array& shapes, const Dictionary& params) const { HOLO_FORGE_OP(ops::stitch(shapes, params, error)) }
Ref<CadShape> CadKernel::keep_faces(const Ref<CadShape>& shape, const PackedInt32Array& faces) const { HOLO_FORGE_OP(ops::keep_faces(shape, faces, error)) }
Ref<CadShape> CadKernel::trim(const Ref<CadShape>& shape, const Ref<CadShape>& tool, const PackedVector3Array& remove_points, const Dictionary& params) const { HOLO_FORGE_OP(ops::trim(shape, tool, remove_points, params, error)) }
Ref<CadShape> CadKernel::untrim(const Ref<CadShape>& shape, const PackedInt32Array& faces, const PackedInt32Array& edges, const Dictionary& params) const { HOLO_FORGE_OP(ops::untrim(shape, faces, edges, params, error)) }
Ref<CadShape> CadKernel::extend_surface(const Ref<CadShape>& shape, const PackedInt32Array& edges, const Dictionary& params) const
{
    String error;
    String note;
    Ref<CadShape> result = ops::extend(shape, edges, params, error, note);
    report(error);
    last_warning = note;
    return result;
}
Ref<CadShape> CadKernel::merge_faces(const Ref<CadShape>& shape, const PackedInt32Array& edges, const PackedInt32Array& faces, const String& tag) const { HOLO_FORGE_OP(ops::merge_faces(shape, edges, faces, utf8(tag), error)) }
Ref<CadShape> CadKernel::reverse_faces(const Ref<CadShape>& shape, const PackedInt32Array& faces) const { HOLO_FORGE_OP(ops::reverse_faces(shape, faces, error)) }

Array CadKernel::pieces(const Ref<CadShape>& shape) const
{
    report("");
    return ops::pieces(shape);
}

void CadKernel::report(const String& error) const
{
    last_error = error;
    last_warning = "";
}

String CadKernel::get_last_error() const
{
    return last_error;
}

String CadKernel::get_last_warning() const
{
    return last_warning;
}

void CadKernel::set_time_limit(double seconds)
{
    ops::set_time_limit(seconds);
}

double CadKernel::get_time_limit()
{
    return ops::time_limit();
}

Array CadKernel::sketch_regions(const Array& curves, const Transform3D& plane, double deflection) const
{
    String error;
    Array result = sketch::regions(curves, sketch::to_plane(plane), deflection > 0.0 ? deflection : 0.0005, error);
    report(error);
    return result;
}

Ref<CadShape> CadKernel::sketch_edges(const Array& curves, const Transform3D& plane) const
{
    String error;
    std::vector<TopoDS_Edge> edges = sketch::edges_on_plane(curves, sketch::to_plane(plane), error);
    report(error);
    BRep_Builder builder;
    TopoDS_Compound compound;
    builder.MakeCompound(compound);
    for (const TopoDS_Edge& edge : edges) {
        builder.Add(compound, edge);
    }
    return CadShape::wrap(compound);
}

Dictionary CadKernel::curve_intersections(const Dictionary& a, const Dictionary& b) const
{
    String error;
    Dictionary result = sketch::intersections(a, b, error);
    report(error);
    return result;
}

Dictionary CadKernel::curve_closest_point(const Dictionary& curve, const Vector2& point) const
{
    String error;
    Dictionary result = sketch::closest_point(curve, point, error);
    report(error);
    return result;
}

PackedVector2Array CadKernel::sample_curve(const Dictionary& curve, double deflection) const
{
    String error;
    PackedVector2Array result = sketch::sample(curve, deflection > 0.0 ? deflection : 0.0002, error);
    report(error);
    return result;
}

Array CadKernel::offset_curves(const Array& chain, double distance) const
{
    String error;
    Array result = sketch::offset(chain, distance, error);
    report(error);
    return result;
}

static std::vector<int> to_ids(const PackedInt32Array& ids)
{
    std::vector<int> result;
    for (int64_t i = 0; i < ids.size(); ++i) {
        result.push_back(ids[i]);
    }
    return result;
}

Array CadKernel::project_edges(const Ref<CadShape>& shape, const PackedInt32Array& edge_ids, const Transform3D& plane) const
{
    report("");
    if (!valid_shape(shape, "project_edges")) {
        return Array();
    }
    String error;
    Array result = sketch::project_edges(shape->get_occ_shape(), to_ids(edge_ids), sketch::to_plane(plane), error);
    report(error);
    return result;
}

Array CadKernel::section_curves(const Ref<CadShape>& shape, const Transform3D& plane) const
{
    report("");
    if (!valid_shape(shape, "section_curves")) {
        return Array();
    }
    String error;
    Array result = sketch::section(shape->get_occ_shape(), sketch::to_plane(plane), error);
    report(error);
    return result;
}

Array CadKernel::project_curves_to_faces(const Array& curves, const Transform3D& plane, const Ref<CadShape>& shape,
    const PackedInt32Array& face_ids, const Vector3& direction, double deflection) const
{
    report("");
    if (!valid_shape(shape, "project_curves_to_faces")) {
        return Array();
    }
    String error;
    Array result = sketch::project_to_faces(curves, sketch::to_plane(plane), shape->get_occ_shape(), to_ids(face_ids), direction,
        deflection > 0.0 ? deflection : 0.0005, error);
    report(error);
    return result;
}

Array CadKernel::intersection_curves(const Array& curves, const Transform3D& plane, const Ref<CadShape>& shape,
    const PackedInt32Array& face_ids, double deflection) const
{
    report("");
    if (!valid_shape(shape, "intersection_curves")) {
        return Array();
    }
    String error;
    Array result = sketch::intersection_curves(curves, sketch::to_plane(plane), shape->get_occ_shape(), to_ids(face_ids),
        deflection > 0.0 ? deflection : 0.0005, error);
    report(error);
    return result;
}

Array CadKernel::isocurves(const Ref<CadShape>& shape, int face_id, int direction, const PackedFloat64Array& params, double deflection) const
{
    report("");
    if (!valid_shape(shape, "isocurves")) {
        return Array();
    }
    std::vector<double> values;
    for (int64_t i = 0; i < params.size(); ++i) {
        values.push_back(params[i]);
    }
    String error;
    Array result = sketch::isocurves(shape->get_occ_shape(), face_id, direction, values, deflection > 0.0 ? deflection : 0.0005, error);
    report(error);
    return result;
}

void CadKernel::_bind_methods()
{
    ClassDB::bind_method(D_METHOD("sketch_regions", "curves", "plane", "deflection"), &CadKernel::sketch_regions, DEFVAL(0.0));
    ClassDB::bind_method(D_METHOD("sketch_edges", "curves", "plane"), &CadKernel::sketch_edges);
    ClassDB::bind_method(D_METHOD("curve_intersections", "a", "b"), &CadKernel::curve_intersections);
    ClassDB::bind_method(D_METHOD("curve_closest_point", "curve", "point"), &CadKernel::curve_closest_point);
    ClassDB::bind_method(D_METHOD("sample_curve", "curve", "deflection"), &CadKernel::sample_curve, DEFVAL(0.0));
    ClassDB::bind_method(D_METHOD("offset_curves", "chain", "distance"), &CadKernel::offset_curves);
    ClassDB::bind_method(D_METHOD("project_edges", "shape", "edge_ids", "plane"), &CadKernel::project_edges);
    ClassDB::bind_method(D_METHOD("section_curves", "shape", "plane"), &CadKernel::section_curves);
    ClassDB::bind_method(
        D_METHOD("project_curves_to_faces", "curves", "plane", "shape", "face_ids", "direction", "deflection"),
        &CadKernel::project_curves_to_faces,
        DEFVAL(Vector3()),
        DEFVAL(0.0)
    );
    ClassDB::bind_method(
        D_METHOD("intersection_curves", "curves", "plane", "shape", "face_ids", "deflection"),
        &CadKernel::intersection_curves,
        DEFVAL(0.0)
    );
    ClassDB::bind_method(
        D_METHOD("isocurves", "shape", "face_id", "direction", "params", "deflection"),
        &CadKernel::isocurves,
        DEFVAL(0.0)
    );
    ClassDB::bind_method(D_METHOD("get_last_error"), &CadKernel::get_last_error);
    ClassDB::bind_method(D_METHOD("get_last_warning"), &CadKernel::get_last_warning);
    ClassDB::bind_static_method("CadKernel", D_METHOD("set_time_limit", "seconds"), &CadKernel::set_time_limit);
    ClassDB::bind_static_method("CadKernel", D_METHOD("get_time_limit"), &CadKernel::get_time_limit);

    ClassDB::bind_method(D_METHOD("version"), &CadKernel::version);
    ClassDB::bind_method(D_METHOD("make_box", "size", "origin", "tag"), &CadKernel::make_box, DEFVAL(Vector3()), DEFVAL(""));
    ClassDB::bind_method(
        D_METHOD("make_cylinder", "radius", "height", "origin", "axis", "tag"),
        &CadKernel::make_cylinder,
        DEFVAL(Vector3()),
        DEFVAL(Vector3(0, 1, 0)),
        DEFVAL("")
    );
    ClassDB::bind_method(D_METHOD("make_sphere", "radius", "center", "tag"), &CadKernel::make_sphere, DEFVAL(Vector3()), DEFVAL(""));
    ClassDB::bind_method(D_METHOD("boolean", "target", "tool", "operation", "tag"), &CadKernel::boolean, DEFVAL(""));
    ClassDB::bind_method(D_METHOD("extrude", "profile", "params"), &CadKernel::extrude);
    ClassDB::bind_method(D_METHOD("revolve", "profile", "params"), &CadKernel::revolve);
    ClassDB::bind_method(D_METHOD("sweep", "profile", "path", "params"), &CadKernel::sweep);
    ClassDB::bind_method(D_METHOD("loft", "sections", "params"), &CadKernel::loft);
    ClassDB::bind_method(D_METHOD("helix", "params"), &CadKernel::helix);
    ClassDB::bind_method(D_METHOD("coil", "params"), &CadKernel::coil);
    ClassDB::bind_method(D_METHOD("pipe", "path", "params"), &CadKernel::pipe);
    ClassDB::bind_method(D_METHOD("thread", "params"), &CadKernel::thread);
    ClassDB::bind_method(D_METHOD("torus", "params"), &CadKernel::torus);
    ClassDB::bind_method(D_METHOD("fillet", "shape", "edges", "params"), &CadKernel::fillet);
    ClassDB::bind_method(D_METHOD("chamfer", "shape", "edges", "params"), &CadKernel::chamfer);
    ClassDB::bind_method(D_METHOD("shell", "shape", "faces", "params"), &CadKernel::shell);
    ClassDB::bind_method(D_METHOD("draft", "shape", "faces", "params"), &CadKernel::draft);
    ClassDB::bind_method(D_METHOD("transform_shape", "shape", "xform", "tag"), &CadKernel::transform_shape, DEFVAL("move"));
    // Phase 8 fix round 1: m is an xform64, 12 doubles (basis columns X, Y, Z, then the origin).
    ClassDB::bind_method(D_METHOD("transform_shape64", "shape", "m", "tag"), &CadKernel::transform_shape64, DEFVAL("move"));
    ClassDB::bind_method(D_METHOD("offset_faces", "shape", "faces", "distance", "tag"), &CadKernel::offset_faces, DEFVAL("offset"));
    ClassDB::bind_method(D_METHOD("offset_shape", "shape", "distance", "tag"), &CadKernel::offset_shape, DEFVAL("offset"));
    ClassDB::bind_method(D_METHOD("split_body", "shape", "tool", "params"), &CadKernel::split_body);
    ClassDB::bind_method(D_METHOD("split_faces", "shape", "faces", "tool", "tag"), &CadKernel::split_faces, DEFVAL("split"));
    ClassDB::bind_method(D_METHOD("thicken", "shape", "faces", "params"), &CadKernel::thicken);
    ClassDB::bind_method(D_METHOD("replace_faces", "shape", "faces", "target", "params"), &CadKernel::replace_faces);
    ClassDB::bind_method(D_METHOD("boundary_fill", "tools", "keep_points", "tag"), &CadKernel::boundary_fill, DEFVAL("fill"));
    ClassDB::bind_method(D_METHOD("rib", "shape", "wire", "params"), &CadKernel::rib);
    ClassDB::bind_method(D_METHOD("wire_from_edges", "shape", "edges"), &CadKernel::wire_from_edges);
    ClassDB::bind_method(D_METHOD("sketch_wire", "curves", "plane"), &CadKernel::sketch_wire);
    ClassDB::bind_method(D_METHOD("import_file", "path", "tag"), &CadKernel::import_file, DEFVAL("import"));
    ClassDB::bind_method(D_METHOD("export_file", "shapes", "path"), &CadKernel::export_file);
    ClassDB::bind_method(D_METHOD("mesh_to_shape", "positions", "indices", "tag"), &CadKernel::mesh_to_shape, DEFVAL("mesh"));
    ClassDB::bind_method(D_METHOD("curve_curvature", "curve", "count"), &CadKernel::curve_curvature, DEFVAL(64));
    ClassDB::bind_method(D_METHOD("offset_profile", "face", "distance"), &CadKernel::offset_profile);
    ClassDB::bind_method(D_METHOD("wire_outline", "wire", "half_width", "normal"), &CadKernel::wire_outline, DEFVAL(Vector3()));
    ClassDB::bind_method(D_METHOD("mirror_shape", "shape", "origin", "normal", "tag"), &CadKernel::mirror_shape, DEFVAL("mirror"));
    ClassDB::bind_method(D_METHOD("plane_face", "origin", "normal", "size", "tag"), &CadKernel::plane_face, DEFVAL("plane"));
    ClassDB::bind_method(D_METHOD("make_vertex", "point"), &CadKernel::make_vertex);
    ClassDB::bind_method(D_METHOD("make_compound", "shapes"), &CadKernel::make_compound);
    ClassDB::bind_method(D_METHOD("closest_points", "a", "b"), &CadKernel::closest_points);
    ClassDB::bind_method(D_METHOD("section_faces", "solid", "origin", "normal"), &CadKernel::section_faces);
    ClassDB::bind_method(D_METHOD("fillet_edges", "shape", "edge_ids", "radius"), &CadKernel::fillet_edges);
    ClassDB::bind_method(D_METHOD("patch", "boundary", "points", "params"), &CadKernel::patch);
    ClassDB::bind_method(D_METHOD("ruled", "shape", "edges", "params"), &CadKernel::ruled);
    ClassDB::bind_method(D_METHOD("offset_surface", "shape", "faces", "distance", "tag"), &CadKernel::offset_surface, DEFVAL("offset"));
    ClassDB::bind_method(D_METHOD("stitch", "shapes", "params"), &CadKernel::stitch);
    ClassDB::bind_method(D_METHOD("keep_faces", "shape", "faces"), &CadKernel::keep_faces);
    ClassDB::bind_method(D_METHOD("pieces", "shape"), &CadKernel::pieces);
    ClassDB::bind_method(D_METHOD("trim", "shape", "tool", "remove_points", "params"), &CadKernel::trim);
    ClassDB::bind_method(D_METHOD("untrim", "shape", "faces", "edges", "params"), &CadKernel::untrim);
    ClassDB::bind_method(D_METHOD("extend_surface", "shape", "edges", "params"), &CadKernel::extend_surface);
    ClassDB::bind_method(D_METHOD("merge_faces", "shape", "edges", "faces", "tag"), &CadKernel::merge_faces, DEFVAL("merge"));
    ClassDB::bind_method(D_METHOD("reverse_faces", "shape", "faces"), &CadKernel::reverse_faces);

    BIND_ENUM_CONSTANT(BOOLEAN_FUSE);
    BIND_ENUM_CONSTANT(BOOLEAN_CUT);
    BIND_ENUM_CONSTANT(BOOLEAN_COMMON);
}

}  // namespace holo_forge
