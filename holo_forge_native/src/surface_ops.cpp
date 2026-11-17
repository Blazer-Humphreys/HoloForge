#include "surface_ops.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <functional>
#include <map>
#include <memory>
#include <numeric>
#include <optional>
#include <set>
#include <tuple>

#include <BRepAdaptor_Curve.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <BOPAlgo_ArgumentAnalyzer.hxx>
#include <BRepAlgoAPI_Splitter.hxx>
#include <BRepBndLib.hxx>
#include <BRepBuilderAPI_Copy.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepBuilderAPI_MakePolygon.hxx>
#include <BRepBuilderAPI_MakeSolid.hxx>
#include <BRepBuilderAPI_MakeVertex.hxx>
#include <BRepBuilderAPI_MakeWire.hxx>
#include <BRepBuilderAPI_Sewing.hxx>
#include <BRepBuilderAPI_Transform.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRepClass_FaceClassifier.hxx>
#include <BRepExtrema_DistShapeShape.hxx>
#include <BRepFill.hxx>
#include <BRepGProp.hxx>
#include <BRepGProp_Face.hxx>
#include <BRepLib.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRepOffsetAPI_MakeFilling.hxx>
#include <BRepOffsetAPI_MakeOffsetShape.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
#include <BRepTools.hxx>
#include <BRepTools_ReShape.hxx>
#include <BRepTools_WireExplorer.hxx>
#include <BRepTopAdaptor_FClass2d.hxx>
#include <BRep_Builder.hxx>
#include <BRep_Tool.hxx>
#include <BSplCLib.hxx>
#include <Bnd_Box.hxx>
#include <Bnd_Box2d.hxx>
#include <BndLib_Add2dCurve.hxx>
#include <Extrema_ExtPC.hxx>
#include <GCPnts_AbscissaPoint.hxx>
#include <GCPnts_UniformAbscissa.hxx>
#include <GC_MakeArcOfCircle.hxx>
#include <GProp_GProps.hxx>
#include <Geom2d_Curve.hxx>
#include <Geom2d_Line.hxx>
#include <GeomAPI_Interpolate.hxx>
#include <GeomAPI_ProjectPointOnSurf.hxx>
#include <GeomAdaptor_Curve.hxx>
#include <GeomConvert.hxx>
#include <GeomConvert_ApproxCurve.hxx>
#include <GeomConvert_CompCurveToBSplineCurve.hxx>
#include <GeomLib.hxx>
#include <GeomLProp_SLProps.hxx>
#include <GeomLib_IsPlanarSurface.hxx>
#include <Geom_BSplineCurve.hxx>
#include <Geom_BSplineSurface.hxx>
#include <Geom_BezierSurface.hxx>
#include <Geom_BoundedSurface.hxx>
#include <Geom_Conic.hxx>
#include <Geom_Line.hxx>
#include <Geom_OffsetSurface.hxx>
#include <Geom_RectangularTrimmedSurface.hxx>
#include <Geom_SurfaceOfRevolution.hxx>
#include <Geom_TrimmedCurve.hxx>
#include <Poly_Triangulation.hxx>
#include <Precision.hxx>
#include <ShapeAnalysis_Curve.hxx>
#include <ShapeAnalysis_FreeBounds.hxx>
#include <ShapeAnalysis_Surface.hxx>
#include <ShapeExtend_WireData.hxx>
#include <ShapeFix_Face.hxx>
#include <ShapeFix_Wire.hxx>
#include <ShapeUpgrade_UnifySameDomain.hxx>
#include <Standard_Failure.hxx>
#include <TColStd_Array1OfInteger.hxx>
#include <TColStd_Array1OfReal.hxx>
#include <TColStd_Array2OfReal.hxx>
#include <TColStd_HArray1OfReal.hxx>
#include <TColgp_Array1OfPnt.hxx>
#include <TColgp_Array2OfPnt.hxx>
#include <TColgp_HArray1OfPnt.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopTools_HSequenceOfShape.hxx>
#include <TopTools_IndexedDataMapOfShapeListOfShape.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Compound.hxx>
#include <TopoDS_Iterator.hxx>
#include <TopoDS_Shell.hxx>
#include <TopoDS_Solid.hxx>
#include <TopoDS_Vertex.hxx>
#include <TopoDS_Wire.hxx>
#include <gp_Ax1.hxx>
#include <gp_Cone.hxx>
#include <gp_Pln.hxx>
#include <gp_Pnt2d.hxx>
#include <gp_Sphere.hxx>

#include "measure.h"
#include "naming.h"

using namespace godot;

namespace holo_forge::ops
{

namespace
{
gp_Pnt P(const Vector3& v)
{
    return gp_Pnt(v.x, v.y, v.z);
}

gp_Dir D(const Vector3& v)
{
    return v.is_zero_approx() ? gp_Dir(0, 1, 0) : gp_Dir(v.x, v.y, v.z);
}

std::string tag_of(const Dictionary& p, const char* fallback)
{
    return String(p.get("tag", fallback)).utf8().get_data();
}

bool usable(const Shape& s)
{
    return s.is_valid() && !s->is_null();
}

std::string face_name(const CadShape& shape, int index)
{
    return size_t(index) < shape.face_name_list.size() ? shape.face_name_list[index] : "";
}

std::string edge_name(const CadShape& shape, int index)
{
    return size_t(index) < shape.edge_name_list.size() && !shape.edge_name_list[index].empty() ? shape.edge_name_list[index] : "e" + std::to_string(index);
}

/// The faces with these ids (every face when ids is empty).
std::vector<TopoDS_Face> faces_by_id(const Shape& shape, const PackedInt32Array& ids)
{
    const TopTools_IndexedMapOfShape& faces = shape->face_map();
    std::vector<TopoDS_Face> result;
    if (ids.is_empty()) {
        for (int i = 1; i <= faces.Extent(); ++i) {
            result.push_back(TopoDS::Face(faces(i)));
        }
        return result;
    }
    for (int64_t i = 0; i < ids.size(); ++i) {
        if (ids[i] >= 0 && ids[i] < faces.Extent()) {
            result.push_back(TopoDS::Face(faces(ids[i] + 1)));
        }
    }
    return result;
}

std::vector<TopoDS_Edge> edges_by_id(const Shape& shape, const PackedInt32Array& ids)
{
    const TopTools_IndexedMapOfShape& edges = shape->edge_map();
    std::vector<TopoDS_Edge> result;
    for (int64_t i = 0; i < ids.size(); ++i) {
        if (ids[i] >= 0 && ids[i] < edges.Extent()) {
            result.push_back(TopoDS::Edge(edges(ids[i] + 1)));
        }
    }
    return result;
}

TopoDS_Shape compound_of(const std::vector<TopoDS_Shape>& shapes)
{
    if (shapes.size() == 1) {
        return shapes[0];
    }
    BRep_Builder builder;
    TopoDS_Compound compound;
    builder.MakeCompound(compound);
    for (const TopoDS_Shape& s : shapes) {
        builder.Add(compound, s);
    }
    return compound;
}

/// The faces an edge bounds in shape (a seam's face once).
std::vector<TopoDS_Face> faces_of_edge(const Shape& shape, const TopoDS_Edge& edge)
{
    std::vector<TopoDS_Face> result;
    const TopTools_IndexedDataMapOfShapeListOfShape& edge_faces = shape->edge_face_map();
    const int index = edge_faces.FindIndex(edge);
    if (index <= 0) {
        return result;
    }
    for (TopTools_ListOfShape::Iterator it(edge_faces(index)); it.More(); it.Next()) {
        const TopoDS_Face& face = TopoDS::Face(it.Value());
        bool seen = false;
        for (const TopoDS_Face& other : result) {
            seen = seen || other.IsSame(face);
        }
        if (!seen) {
            result.push_back(face);
        }
    }
    return result;
}

/// A new container like s (same kind, orientation and location) holding s's children, each
/// passed through change (null results are left out). Children are taken and added relative to
/// s: BRep_Builder::Add would otherwise reverse and move them again for a reversed or moved s.
TopoDS_Shape with_children(const TopoDS_Shape& s, const std::function<TopoDS_Shape(const TopoDS_Shape&)>& change)
{
    TopoDS_Shape copy = s.EmptyCopied();
    copy.Orientation(TopAbs_FORWARD);
    copy.Location(TopLoc_Location());
    BRep_Builder builder;
    for (TopoDS_Iterator it(s, false, false); it.More(); it.Next()) {
        const TopoDS_Shape child = change(it.Value());
        if (!child.IsNull()) {
            builder.Add(copy, child);
        }
    }
    copy.Orientation(s.Orientation());
    copy.Location(s.Location());
    return copy;
}

/// A result made of parent's faces (and edges), named as they were in parent.
Shape with_names_of(const TopoDS_Shape& s, const CadShape& parent)
{
    Shape out = CadShape::wrap(s);
    naming::copy_names(parent, *out.ptr());
    naming::name_edges(*out.ptr());
    return out;
}

/// A shape's copy with geometry of its own, names carried over (the copy has the same structure).
/// Sewing, OCCT's filling and a face made on edges change the edges and vertices they are given
/// (tolerances, curves), and a body shares those with the document's other shapes: they work on
/// copies.
Shape detached(const Shape& in)
{
    BRepBuilderAPI_Copy copier(in->get_occ_shape(), true, false);
    Shape out = CadShape::wrap(copier.Shape());
    out->face_name_list = in->face_name_list;
    out->edge_name_list = in->edge_name_list;
    return out;
}

/// Copies of shapes (see detached) made together, so faces and edges they share stay shared.
std::vector<Shape> detached_together(const std::vector<Shape>& in)
{
    std::vector<TopoDS_Shape> all;
    std::vector<bool> free;
    for (const Shape& s : in) {
        all.push_back(s->get_occ_shape());
        free.push_back(s->get_occ_shape().TShape()->Free());
    }
    BRepBuilderAPI_Copy copier(compound_of(all), true, false);
    // (Put in a compound to copy, a shape is marked as held by it: it is given back as it was.)
    for (size_t i = 0; i < all.size(); ++i) {
        all[i].TShape()->Free(free[i]);
    }
    // (The copy's parts, in order: one shape's copy is the copy itself.)
    std::vector<TopoDS_Shape> parts;
    if (in.size() == 1) {
        parts.push_back(copier.Shape());
    }
    for (TopoDS_Iterator it(copier.Shape()); in.size() > 1 && it.More(); it.Next()) {
        parts.push_back(it.Value());
    }
    std::vector<Shape> out;
    for (size_t i = 0; i < in.size() && i < parts.size(); ++i) {
        Shape copy = CadShape::wrap(parts[i]);
        copy->face_name_list = in[i]->face_name_list;
        copy->edge_name_list = in[i]->edge_name_list;
        out.push_back(copy);
    }
    return out;
}

/// The parameter tolerance OCCT's projections onto a spline surface are given. (Their search
/// compares it with squared distances: the default, made for millimetres, skips the inside of a
/// face a few centimetres across in metres and settles on its edges.)
constexpr double PROJECTION_TOLERANCE = 1e-11;

double diagonal(const TopoDS_Shape& s)
{
    Bnd_Box box;
    BRepBndLib::Add(s, box);
    return box.IsVoid() ? 1.0 : std::sqrt(box.SquareExtent());
}

/// The outward normal (it follows the face's orientation) at surface parameters u, v; on a
/// collapsed side (a lens patch's end, a pole) the limit from inside the face.
gp_Vec normal_at(const TopoDS_Face& face, double u, double v)
{
    BRepGProp_Face props(face);
    gp_Pnt p;
    gp_Vec n;
    props.Normal(u, v, p, n);
    if (n.Magnitude() <= 1e-12) {
        double u1 = 0.0, u2 = 0.0, v1 = 0.0, v2 = 0.0;
        BRepTools::UVBounds(face, u1, u2, v1, v2);
        props.Normal(u + (0.5 * (u1 + u2) - u) * 1e-7, v + (0.5 * (v1 + v2) - v) * 1e-7, p, n);
    }
    return n.Magnitude() > 1e-30 ? n.Normalized() : gp_Vec(0, 0, 1);
}

/// Merges faces left on one surface across edges not in keep, keeping names.
Shape unify(const Shape& in, const std::string& tag, const TopTools_MapOfShape* keep = nullptr)
{
    ShapeUpgrade_UnifySameDomain unifier(in->get_occ_shape(), true, true, false);
    if (keep != nullptr) {
        unifier.KeepShapes(*keep);
    }
    unifier.Build();
    Shape out = CadShape::wrap(unifier.Shape());
    naming::name_from_history(*out.ptr(), unifier.History(), *in.ptr(), tag);
    return out;
}

/// A copy of an edge of its own, to build a face on: BRepFill adds the face's curves to the edge it
/// is given (and resets its parameter flags), and the picked edge belongs to the picked shape.
/// Sewing joins the copy up with it again.
TopoDS_Edge own_copy(const TopoDS_Edge& edge)
{
    return TopoDS::Edge(BRepBuilderAPI_Copy(edge).Shape());
}

/// A strip (a ruled face, no holes) rebuilt on its plane from the same curves when its surface is
/// flat, so it thickens and offsets as a plane does; any other face as it is.
TopoDS_Face on_plane(const TopoDS_Face& face)
{
    const TopoDS_Face forward = TopoDS::Face(face.Oriented(TopAbs_FORWARD));
    const GeomAbs_SurfaceType type = BRepAdaptor_Surface(forward, false).GetType();
    if (type != GeomAbs_BSplineSurface && type != GeomAbs_BezierSurface && type != GeomAbs_OtherSurface) {
        return face;
    }
    const Handle(Geom_Surface) surface = BRep_Tool::Surface(forward);
    GeomLib_IsPlanarSurface flat(surface, std::max(diagonal(forward) * 1e-7, 1e-12));
    if (!flat.IsPlanar()) {
        return face;
    }
    // The plane faces the way the spline did, so the edges keep their sense.
    double u1 = 0.0, u2 = 0.0, v1 = 0.0, v2 = 0.0;
    BRepTools::UVBounds(forward, u1, u2, v1, v2);
    gp_Pnt point;
    gp_Vec du;
    gp_Vec dv;
    surface->D1(0.5 * (u1 + u2), 0.5 * (v1 + v2), point, du, dv);
    gp_Pln plane = flat.Plan();
    if (du.Crossed(dv).Dot(gp_Vec(plane.Axis().Direction())) < 0.0) {
        plane = gp_Pln(plane.Location(), plane.Axis().Direction().Reversed());
    }
    // On fresh edges from the same curves: the ruled face's edges carry its parameters (a joined
    // offset of a sheet sewn from them comes out broken, at its straight splines above all, which
    // become lines). A closed strip is the ring between its two loops, without its seam.
    auto fresh = [](const TopoDS_Edge& edge) {
        double first = 0.0;
        double last = 0.0;
        const Handle(Geom_Curve) curve = BRep_Tool::Curve(edge, first, last);
        const gp_Pnt a = curve->Value(first);
        const gp_Pnt b = curve->Value(last);
        bool straight = a.Distance(b) > Precision::Confusion();
        for (int i = 1; i < 8 && straight; ++i) {
            straight = gp_Lin(a, gp_Dir(gp_Vec(a, b))).Distance(curve->Value(first + (last - first) * i / 8.0)) < Precision::Confusion();
        }
        TopoDS_Edge made = straight ? BRepBuilderAPI_MakeEdge(a, b).Edge() : BRepBuilderAPI_MakeEdge(curve, first, last).Edge();
        made.Orientation(edge.Orientation());
        return made;
    };
    std::vector<TopoDS_Edge> ring;
    std::map<const TopoDS_TShape*, int> uses;
    for (BRepTools_WireExplorer it(BRepTools::OuterWire(forward), forward); it.More(); it.Next()) {
        double first = 0.0;
        double last = 0.0;
        if (BRep_Tool::Curve(it.Current(), first, last).IsNull()) {
            continue;
        }
        ring.push_back(it.Current());
        ++uses[it.Current().TShape().get()];
    }
    std::vector<TopoDS_Wire> loops;
    BRepBuilderAPI_MakeWire outline;
    for (const TopoDS_Edge& edge : ring) {
        if (uses[edge.TShape().get()] > 1) {
            continue;
        }
        if (BRep_Tool::IsClosed(edge) || TopExp::FirstVertex(edge).IsSame(TopExp::LastVertex(edge))) {
            loops.push_back(BRepBuilderAPI_MakeWire(fresh(edge)).Wire());
            continue;
        }
        outline.Add(fresh(edge));
        if (!outline.IsDone()) {
            return face;
        }
    }
    if (loops.empty()) {
        if (!outline.IsDone()) {
            return face;
        }
        loops.push_back(outline.Wire());
    }
    // The loop round the most area is the outer one.
    auto enclosed = [&](const TopoDS_Wire& wire) {
        GProp_GProps props;
        BRepGProp::SurfaceProperties(BRepBuilderAPI_MakeFace(plane, wire, true).Face(), props);
        return std::abs(props.Mass());
    };
    std::sort(loops.begin(), loops.end(), [&](const TopoDS_Wire& a, const TopoDS_Wire& b) { return enclosed(a) > enclosed(b); });
    BRepBuilderAPI_MakeFace maker(plane, loops[0], loops.size() > 1);
    for (size_t k = 1; k < loops.size() && maker.IsDone(); ++k) {
        maker.Add(loops[k]);
    }
    if (!maker.IsDone()) {
        return face;
    }
    TopoDS_Face rebuilt = maker.Face();
    if (loops.size() > 1) {
        ShapeFix_Face fix(rebuilt);
        fix.Perform();
        rebuilt = fix.Face();
    }
    for (TopExp_Explorer e(rebuilt, TopAbs_EDGE); e.More(); e.Next()) {
        BRepLib::BuildPCurveForEdgeOnPlane(TopoDS::Edge(e.Current()), rebuilt);
    }
    rebuilt.Orientation(face.Orientation());
    return rebuilt;
}

gp_Vec into_face(const TopoDS_Face& face, const TopoDS_Edge& edge, double t);

/// 1 when side (across edge at its parameter t, along face) leads off the face, -1 when into it:
/// by the edge's sense in the face, else by where a step that way lands (a projection can miss a
/// point near a spline face's boundary).
double leaves_face(const TopoDS_Face& face, const TopoDS_Edge& edge, double t, const gp_Vec& side)
{
    const gp_Vec into = into_face(face, edge, t);
    if (into.Magnitude() > 0.5) {
        return side.Dot(into) > 0.0 ? -1.0 : 1.0;
    }
    gp_Pnt point;
    gp_Vec tangent;
    BRepAdaptor_Curve(edge).D1(t, point, tangent);
    GeomAPI_ProjectPointOnSurf projection(point.Translated(side.Normalized() * (diagonal(face) * 1e-3)), BRep_Tool::Surface(face), PROJECTION_TOLERANCE);
    if (projection.NbPoints() > 0) {
        double u = 0.0;
        double v = 0.0;
        projection.LowerDistanceParameters(u, v);
        const TopAbs_State state = BRepClass_FaceClassifier(face, gp_Pnt2d(u, v), Precision::PConfusion()).State();
        if (state == TopAbs_IN || state == TopAbs_ON) {
            return -1.0;
        }
    }
    return 1.0;
}

/// A ruled face from edge (lying on face, which may be null for "direction") to the curve its
/// points reach when moved distance along type's direction, turned by angle about the edge. ends,
/// when given, gets the far points at the edge's first and last vertex (unoriented), and far_out
/// the far edge (running from the first to the last).
TopoDS_Face ruled_strip(const TopoDS_Edge& edge, const TopoDS_Face& face, const String& type, double distance, double angle,
    bool flip, const gp_Dir& fixed, String& error, std::array<gp_Pnt, 2>* ends = nullptr, TopoDS_Edge* far_out = nullptr)
{
    const TopoDS_Edge forward = TopoDS::Edge(edge.Oriented(TopAbs_FORWARD));
    BRepAdaptor_Curve curve(forward);
    const double f = curve.FirstParameter();
    const double l = curve.LastParameter();
    Handle(Geom2d_Curve) pcurve;
    if (!face.IsNull()) {
        double pf = 0.0;
        double pl = 0.0;
        pcurve = BRep_Tool::CurveOnSurface(forward, face, pf, pl);
    }
    if (type != "direction" && pcurve.IsNull()) {
        error = "Pick edges that lie on a face";
        return TopoDS_Face();
    }
    const bool flat = face.IsNull() || BRepAdaptor_Surface(face).GetType() == GeomAbs_Plane;
    const bool straight = curve.GetType() == GeomAbs_Line && (flat || type == "direction");
    const int count = straight ? 1 : 24;
    // Which side of the edge leaves the face gets decided once, mid-edge (tangent strips go that
    // way, and an angle leans normal ones that way).
    const bool turned = std::abs(angle) > 1e-12;
    double away = 1.0;
    auto side_of = [&](double t, const gp_Vec& tangent) {
        const gp_Pnt2d uv = pcurve->Value(t);
        const gp_Vec n = normal_at(face, uv.X(), uv.Y());
        gp_Vec side = tangent.Crossed(n);
        return side.Magnitude() > 1e-12 ? side.Normalized() : n;
    };
    if (type == "tangent" || (type == "normal" && turned)) {
        const double mid = 0.5 * (f + l);
        gp_Pnt pt;
        gp_Vec tangent;
        curve.D1(mid, pt, tangent);
        away = leaves_face(face, edge, mid, side_of(mid, tangent));
    }
    // The way the edge's point at t moves (unit), and the point.
    auto aim = [&](double t, gp_Pnt& pt) {
        gp_Vec tangent;
        curve.D1(t, pt, tangent);
        if (tangent.Magnitude() < 1e-12) {
            tangent = gp_Vec(1, 0, 0);
        }
        gp_Vec d;
        if (type == "direction") {
            d = gp_Vec(fixed);
            if (turned) {
                d.Rotate(gp_Ax1(pt, gp_Dir(tangent)), angle);
            }
        }
        else {
            // An angle turns every strip of a chain the same way: a tangent one up toward the
            // face's normal, a normal one out away from the face.
            const gp_Pnt2d uv = pcurve->Value(t);
            const gp_Vec n = normal_at(face, uv.X(), uv.Y());
            const gp_Vec out = type == "tangent" || turned ? side_of(t, tangent) * away : n;
            d = type == "normal" ? n * std::cos(angle) + out * std::sin(angle) : out * std::cos(angle) + n * std::sin(angle);
        }
        if (flip) {
            d.Reverse();
        }
        return d.Normalized();
    };
    // Points along the edge (24 on a curve), more where the way they move turns (a lens patch's rim
    // near its ends) until neighbours turn by under 2 deg: the far edge runs through theirs.
    std::vector<double> at;
    std::vector<gp_Pnt> near;
    std::vector<gp_Vec> along;
    for (int i = 0; i <= count; ++i) {
        at.push_back(f + (l - f) * double(i) / count);
        near.emplace_back();
        along.push_back(aim(at.back(), near.back()));
    }
    // Between neighbours at and at + 1, a point more where they turn apart or the far edge strays.
    auto refine = [&](const std::function<bool(size_t)>& wanted) {
        std::vector<double> at_more;
        std::vector<gp_Pnt> near_more;
        std::vector<gp_Vec> along_more;
        for (size_t i = 0; i < at.size(); ++i) {
            at_more.push_back(at[i]);
            near_more.push_back(near[i]);
            along_more.push_back(along[i]);
            if (i + 1 < at.size() && at[i + 1] - at[i] > 1e-9 * (l - f) && at.size() < 4000 && wanted(i)) {
                at_more.push_back(0.5 * (at[i] + at[i + 1]));
                near_more.emplace_back();
                along_more.push_back(aim(at_more.back(), near_more.back()));
            }
        }
        const bool grew = at_more.size() > at.size();
        at.swap(at_more);
        near.swap(near_more);
        along.swap(along_more);
        return grew;
    };
    for (int round = 0; round < 12 && !straight && refine([&](size_t i) { return along[i].Angle(along[i + 1]) > M_PI / 90.0; }); ++round) {
    }
    std::vector<gp_Pnt> far;
    for (size_t i = 0; i < at.size(); ++i) {
        far.push_back(near[i].Translated(along[i] * distance));
    }
    // Lines that close in on each other (off a cone's rim toward its apex) cross where the strip
    // folds over: as far as that, and no further.
    double reach = 1e300;
    for (size_t i = 0; i + 1 < near.size(); ++i) {
        const gp_Vec step(near[i], near[i + 1]);
        const double closing = -(along[i + 1] - along[i]).Dot(step);
        if (closing > 1e-12 * step.SquareMagnitude()) {
            reach = std::min(reach, step.SquareMagnitude() / closing);
        }
    }
    if (reach <= distance * (1.0 + 1e-9)) {
        char text[160];
        std::snprintf(text, sizeof(text), "The surface would run past where its straight lines cross (%.2f mm away)", reach * 1000.0);
        error = text;
        return TopoDS_Face();
    }
    // Every point moved the same way (square off a flat face, along a fixed direction): the edge's
    // prism, a plane or a cylinder where a ruled spline would stand in for one. It faces the way a
    // ruled strip does (along the edge, then out to its far edge).
    bool parallel = true;
    for (const gp_Vec& d : along) {
        parallel = parallel && d.IsEqual(along.front(), 1e-12, 1e-9);
    }
    gp_Pnt middle;
    gp_Vec tangent;
    curve.D1(0.5 * (f + l), middle, tangent);
    TopoDS_Edge far_edge;
    TopoDS_Face strip;
    if (parallel && tangent.Crossed(along.front()).Magnitude() > 1e-9 * tangent.Magnitude()) {
        BRepPrimAPI_MakePrism prism(own_copy(forward), along.front() * distance, true);
        if (prism.IsDone() && prism.Shape().ShapeType() == TopAbs_FACE) {
            strip = TopoDS::Face(prism.Shape());
            far_edge = TopoDS::Edge(prism.LastShape());
            double u1 = 0.0, u2 = 0.0, v1 = 0.0, v2 = 0.0;
            BRepTools::UVBounds(strip, u1, u2, v1, v2);
            if (normal_at(strip, 0.5 * (u1 + u2), 0.5 * (v1 + v2)).Dot(tangent.Crossed(along.front())) < 0.0) {
                strip.Reverse();
            }
        }
    }
    if (strip.IsNull()) {
        if (straight) {
            far_edge = BRepBuilderAPI_MakeEdge(far.front(), far.back()).Edge();
        }
        else {
            // Through the far points at the edge's own parameters (the ruled face joins each point
            // of the edge to its own), with points added where it strays between them by over a
            // ten-thousandth of the distance.
            const bool closed = far.front().Distance(far.back()) < 1e-9;
            Handle(Geom_BSplineCurve) built;
            for (int round = 0; round < 6; ++round) {
                const int n = int(far.size()) - (closed ? 1 : 0);
                Handle(TColgp_HArray1OfPnt) points = new TColgp_HArray1OfPnt(1, n);
                double closest = 1e300;
                for (int i = 0; i < n; ++i) {
                    points->SetValue(i + 1, far[i]);
                    closest = std::min(closest, far[i].Distance(far[i + 1 < int(far.size()) ? i + 1 : 0]));
                }
                Handle(TColStd_HArray1OfReal) params = new TColStd_HArray1OfReal(1, int(at.size()));
                for (size_t i = 0; i < at.size(); ++i) {
                    params->SetValue(int(i) + 1, at[i]);
                }
                GeomAPI_Interpolate interpolate(points, params, closed, std::min(1e-9, 0.5 * closest));
                interpolate.Perform();
                if (!interpolate.IsDone()) {
                    built.Nullify();
                    break;
                }
                built = interpolate.Curve();
                if (!refine([&](size_t i) {
                        gp_Pnt pt;
                        const double mid = 0.5 * (at[i] + at[i + 1]);
                        const gp_Vec d = aim(mid, pt);
                        return built->Value(mid).Distance(pt.Translated(d * distance)) > 1e-4 * distance;
                    })) {
                    break;
                }
                far.clear();
                for (size_t i = 0; i < at.size(); ++i) {
                    far.push_back(near[i].Translated(along[i] * distance));
                }
            }
            if (built.IsNull()) {
                error = "The ruled surface's far edge could not be built";
                return TopoDS_Face();
            }
            far_edge = BRepBuilderAPI_MakeEdge(built).Edge();
        }
        strip = BRepFill::Face(own_copy(forward), far_edge);
        if (strip.IsNull()) {
            error = "The ruled surface could not be built";
            return strip;
        }
        strip = on_plane(strip);
    }
    // Moved along itself (a direction along a straight edge), the edge sweeps no area.
    GProp_GProps swept;
    BRepGProp::SurfaceProperties(strip, swept);
    GProp_GProps length;
    BRepGProp::LinearProperties(forward, length);
    if (!(std::abs(swept.Mass()) > 1e-6 * length.Mass() * distance)) {
        error = type == "direction" ? "The direction runs along the edge, so the ruled surface has no width" : "The ruled surface has no width";
        return TopoDS_Face();
    }
    if (ends != nullptr) {
        (*ends)[0] = far.front();
        (*ends)[1] = far.back();
    }
    if (far_out != nullptr) {
        *far_out = far_edge;
    }
    return strip;
}

/// True when face's surface comes to a point at an end of edge, which runs along side of the
/// face's UV box (see iso_side): its derivative across the side vanishes there (a lens patch's
/// rim at the lens's ends).
bool comes_to_point(const TopoDS_Face& face, const TopoDS_Edge& edge, int side)
{
    double f = 0.0;
    double l = 0.0;
    const Handle(Geom2d_Curve) pcurve = BRep_Tool::CurveOnSurface(edge, face, f, l);
    if (pcurve.IsNull()) {
        return false;
    }
    const BRepAdaptor_Surface surface(face, false);
    std::array<double, 9> speed;
    for (int i = 0; i <= 8; ++i) {
        const gp_Pnt2d uv = pcurve->Value(f + (l - f) * i / 8.0);
        gp_Pnt point;
        gp_Vec du;
        gp_Vec dv;
        surface.D1(uv.X(), uv.Y(), point, du, dv);
        speed[i] = (side < 2 ? du : dv).Magnitude();
    }
    const double most = *std::max_element(speed.begin(), speed.end());
    return most > 0.0 && std::min(speed[0], speed[8]) <= 1e-6 * most;
}

double ramp(double x);

/// A band carrying face on past edge by distance, for an edge where the face's surface comes to a
/// point at its ends (comes_to_point): carried on itself, the surface would pinch there. As a
/// natural extension's, its far edge lies distance out along the face's tangent plane, square to
/// the edge, and the band bends as the face does across the edge (its normal curvature there),
/// straightening toward the edge's ends, so bands meeting at a lens's end share a straight side.
/// ends and far_out as ruled_strip's; null when the edge isn't a plain spline (the caller then
/// extends it tangentially).
TopoDS_Face natural_band(const TopoDS_Edge& edge, const TopoDS_Face& face, double distance, std::array<gp_Pnt, 2>* ends, TopoDS_Edge* far_out)
{
    const TopoDS_Edge forward = TopoDS::Edge(edge.Oriented(TopAbs_FORWARD));
    double f = 0.0;
    double l = 0.0;
    const Handle(Geom_Curve) curve = BRep_Tool::Curve(forward, f, l);
    double pf = 0.0;
    double pl = 0.0;
    const Handle(Geom2d_Curve) pcurve = BRep_Tool::CurveOnSurface(forward, face, pf, pl);
    if (curve.IsNull() || pcurve.IsNull() || std::abs(pf - f) > 1e-9 * std::max(1.0, std::abs(l - f)) || std::abs(pl - l) > 1e-9 * std::max(1.0, std::abs(l - f))) {
        return TopoDS_Face();
    }
    const Handle(Geom_BSplineCurve) path = GeomConvert::CurveToBSplineCurve(new Geom_TrimmedCurve(curve, f, l));
    if (path.IsNull() || path->IsRational()) {
        return TopoDS_Face();
    }
    // Which side of the edge leaves the face, decided mid-edge (as ruled_strip does).
    const Handle(Geom_Surface) surface = BRep_Tool::Surface(face);
    gp_Pnt middle;
    gp_Vec midway;
    curve->D1(0.5 * (f + l), middle, midway);
    const gp_Pnt2d mid_uv = pcurve->Value(0.5 * (f + l));
    const gp_Vec side = midway.Crossed(normal_at(face, mid_uv.X(), mid_uv.Y()));
    if (side.Magnitude() < 1e-300) {
        return TopoDS_Face();
    }
    const double away = leaves_face(face, edge, 0.5 * (f + l), side);
    // Across the edge at its Greville points: out along the tangent plane (the limit from inside
    // where the surface collapses), and the bend toward its normal, faded out at the ends.
    const int count = path->NbPoles();
    const int degree = path->Degree();
    TColStd_Array1OfReal flat(1, count + degree + 1);
    path->KnotSequence(flat);
    TColStd_Array1OfReal at(1, count);
    BSplCLib::BuildSchoenbergPoints(degree, flat, at);
    TColgp_Array1OfPnt out(1, count);
    TColgp_Array1OfPnt bend(1, count);
    TColStd_Array1OfInteger contact(1, count);
    contact.Init(0);
    for (int i = 1; i <= count; ++i) {
        gp_Pnt point;
        gp_Vec tangent;
        curve->D1(at(i), point, tangent);
        const gp_Pnt2d uv = pcurve->Value(at(i));
        gp_Vec across = tangent.Crossed(normal_at(face, uv.X(), uv.Y()));
        if (across.Magnitude() < 1e-300) {
            return TopoDS_Face();
        }
        across = across.Normalized() * away;
        double curvature = 0.0;
        gp_Vec toward;
        GeomLProp_SLProps props(surface, uv.X(), uv.Y(), 2, Precision::Confusion());
        if (props.IsCurvatureDefined() && props.IsNormalDefined()) {
            toward = gp_Vec(props.Normal());
            curvature = props.MaxCurvature();
            if (!props.IsUmbilic()) {
                gp_Dir most;
                gp_Dir least;
                props.CurvatureDirections(most, least);
                const double c = across.Dot(gp_Vec(most));
                const double s = across.Dot(gp_Vec(least));
                curvature = props.MaxCurvature() * c * c + props.MinCurvature() * s * s;
            }
        }
        const double x = (at(i) - f) / (l - f);
        const double fade = ramp(x / 0.1) * ramp((1.0 - x) / 0.1);
        out(i) = gp_Pnt((across * distance).XYZ());
        bend(i) = gp_Pnt((toward * (0.5 * distance * distance * curvature * fade)).XYZ());
    }
    int problem = 0;
    BSplCLib::Interpolate(degree, flat, at, contact, out, problem);
    if (problem == 0) {
        BSplCLib::Interpolate(degree, flat, at, contact, bend, problem);
    }
    if (problem != 0) {
        return TopoDS_Face();
    }
    // Across the band a cubic: s out, plus the bend times s^2 - s^3 (in Bezier form 0, 0, 1/3, 0).
    TColgp_Array2OfPnt poles(1, count, 1, 4);
    for (int i = 1; i <= count; ++i) {
        const gp_XYZ p = path->Pole(i).XYZ();
        poles(i, 1) = gp_Pnt(p);
        poles(i, 2) = gp_Pnt(p + out(i).XYZ() / 3.0);
        poles(i, 3) = gp_Pnt(p + out(i).XYZ() * (2.0 / 3.0) + bend(i).XYZ() / 3.0);
        poles(i, 4) = gp_Pnt(p + out(i).XYZ());
    }
    TColStd_Array1OfReal knots(1, path->NbKnots());
    TColStd_Array1OfInteger mults(1, path->NbKnots());
    path->Knots(knots);
    path->Multiplicities(mults);
    TColStd_Array1OfReal across_knots(1, 2);
    across_knots(1) = 0.0;
    across_knots(2) = 1.0;
    TColStd_Array1OfInteger across_mults(1, 2);
    across_mults.Init(4);
    const Handle(Geom_BSplineSurface) band = new Geom_BSplineSurface(poles, knots, across_knots, mults, across_mults, degree, 3);
    BRepBuilderAPI_MakeFace maker(band, Precision::Confusion());
    if (!maker.IsDone()) {
        return TopoDS_Face();
    }
    if (ends != nullptr) {
        (*ends)[0] = band->Value(f, 1.0);
        (*ends)[1] = band->Value(l, 1.0);
    }
    if (far_out != nullptr) {
        *far_out = BRepBuilderAPI_MakeEdge(band->VIso(1.0)).Edge();
    }
    return maker.Face();
}

/// A strip's edge, its far edge (running the same way), the far points at the edge's first and
/// last vertex, the edge's name, and where its face sits in the faces (and roles) list.
struct Strip
{
    TopoDS_Edge edge;
    TopoDS_Edge far_edge;
    std::array<gp_Pnt, 2> far;
    std::string name;
    size_t index = 0;
};

/// The corners where the strips of edges that meet part or cross. Where they part (a convex
/// corner) the gap is filled flat: rounded, by the circular sector about the corner from one
/// strip's end to the other's; mitred, by each strip carried on in its own plane until they meet
/// (out to the corner's bisector when they lie in one plane). Fills are named prefix + "(a|b)".
/// Where they cross (a concave corner) both strips are cut back to the point where their far
/// edges cross, so they meet along the line from the corner to it.
void strip_corners(const std::vector<Strip>& strips, bool rounded, const std::string& prefix, std::vector<TopoDS_Shape>& faces,
    std::vector<naming::Role>& roles)
{
    struct End
    {
        TopoDS_Vertex vertex;
        gp_Vec into;
        gp_Pnt far;
    };
    std::vector<std::array<End, 2>> ends;
    for (const Strip& strip : strips) {
        const TopoDS_Edge forward = TopoDS::Edge(strip.edge.Oriented(TopAbs_FORWARD));
        BRepAdaptor_Curve curve(forward);
        gp_Pnt p;
        gp_Vec first;
        gp_Vec last;
        curve.D1(curve.FirstParameter(), p, first);
        curve.D1(curve.LastParameter(), p, last);
        ends.push_back({End{TopExp::FirstVertex(forward), first, strip.far[0]}, End{TopExp::LastVertex(forward), last.Reversed(), strip.far[1]}});
    }
    // Far-edge parameters a strip is cut back to at its first and last end (none: as it is).
    std::vector<std::array<std::optional<double>, 2>> cuts(strips.size());
    auto closed = [&](size_t i) { return ends[i][0].vertex.IsNull() || ends[i][0].vertex.IsSame(ends[i][1].vertex); };
    for (size_t i = 0; i < strips.size(); ++i) {
        for (size_t j = i + 1; j < strips.size(); ++j) {
            if (closed(i) || closed(j)) {
                continue;
            }
            for (int ai = 0; ai < 2; ++ai) {
                for (int bj = 0; bj < 2; ++bj) {
                    const End& a = ends[i][ai];
                    const End& b = ends[j][bj];
                    if (!a.vertex.IsSame(b.vertex)) {
                        continue;
                    }
                    const gp_Pnt corner = BRep_Tool::Pnt(a.vertex);
                    const gp_Vec va(corner, a.far);
                    const gp_Vec vb(corner, b.far);
                    if (a.far.Distance(b.far) < Precision::Confusion() || va.Magnitude() < Precision::Confusion() || vb.Magnitude() < Precision::Confusion()) {
                        continue;
                    }
                    const double out_a = va.Dot(b.into);
                    const double out_b = vb.Dot(a.into);
                    if (out_a > 0.0 && out_b > 0.0) {
                        // They cross: where their far edges do.
                        BRepExtrema_DistShapeShape crossing(strips[i].far_edge, strips[j].far_edge);
                        if (!crossing.IsDone() || crossing.Value() > std::max(va.Magnitude(), vb.Magnitude()) * 1e-7) {
                            continue;
                        }
                        double nearest = 1e300;
                        for (int s = 1; s <= crossing.NbSolution(); ++s) {
                            const double d = crossing.PointOnShape1(s).Distance(corner);
                            if (d >= nearest || crossing.SupportTypeShape1(s) != BRepExtrema_IsOnEdge || crossing.SupportTypeShape2(s) != BRepExtrema_IsOnEdge) {
                                continue;
                            }
                            nearest = d;
                            double t1 = 0.0;
                            double t2 = 0.0;
                            crossing.ParOnEdgeS1(s, t1);
                            crossing.ParOnEdgeS2(s, t2);
                            cuts[i][ai] = t1;
                            cuts[j][bj] = t2;
                        }
                        continue;
                    }
                    if (out_a >= 0.0 || out_b >= 0.0) {
                        continue;
                    }
                    std::vector<TopoDS_Wire> outlines;
                    if (rounded) {
                        // The sector's plane holds both strips' end lines; it is closed by the arc.
                        if (va.Crossed(vb).Magnitude() < 1e-9 * va.Magnitude() * vb.Magnitude()) {
                            continue;
                        }
                        const gp_Vec middle = (va.Normalized() + vb.Normalized()).Normalized() * (0.5 * (va.Magnitude() + vb.Magnitude()));
                        GC_MakeArcOfCircle arc(a.far, corner.Translated(middle), b.far);
                        if (!arc.IsDone()) {
                            continue;
                        }
                        BRepBuilderAPI_MakeWire wire;
                        wire.Add(BRepBuilderAPI_MakeEdge(corner, a.far).Edge());
                        wire.Add(BRepBuilderAPI_MakeEdge(arc.Value()).Edge());
                        wire.Add(BRepBuilderAPI_MakeEdge(b.far, corner).Edge());
                        if (!wire.IsDone()) {
                            continue;
                        }
                        outlines.push_back(wire.Wire());
                    }
                    else {
                        // Each strip carried on in its own plane to where the planes cross (strips
                        // turned up or out alike meet there at one point of their far lines).
                        const gp_Vec plane_a = a.into.Crossed(va);
                        const gp_Vec plane_b = b.into.Crossed(vb);
                        const double across_a = a.into.Dot(plane_b);
                        const double across_b = b.into.Dot(plane_a);
                        if (plane_a.Crossed(plane_b).Magnitude() > 1e-6 * plane_a.Magnitude() * plane_b.Magnitude()
                            && std::abs(across_a) > 1e-9 * a.into.Magnitude() * plane_b.Magnitude()
                            && std::abs(across_b) > 1e-9 * b.into.Magnitude() * plane_a.Magnitude()) {
                            // a's far line, a.far - s a.into, reaches b's plane at s = va.nb / (a.into.nb).
                            const double sa = va.Dot(plane_b) / across_a;
                            const double sb = vb.Dot(plane_a) / across_b;
                            const gp_Pnt qa = a.far.Translated(a.into * -sa);
                            const gp_Pnt qb = b.far.Translated(b.into * -sb);
                            if (sa > 0.0 && sb > 0.0 && qa.Distance(qb) <= 1e-7 * (va.Magnitude() + vb.Magnitude())) {
                                const gp_Pnt tip(0.5 * (qa.XYZ() + qb.XYZ()));
                                outlines.push_back(BRepBuilderAPI_MakePolygon(corner, a.far, tip, true).Wire());
                                outlines.push_back(BRepBuilderAPI_MakePolygon(corner, tip, b.far, true).Wire());
                            }
                        }
                        if (outlines.empty()) {
                            // One plane (or strips that don't meet so): out to the corner's bisector.
                            const double c = va.Normalized().Dot(vb.Normalized());
                            BRepBuilderAPI_MakePolygon polygon;
                            polygon.Add(corner);
                            polygon.Add(a.far);
                            if (1.0 + c > 0.3) {
                                polygon.Add(corner.Translated((va + vb) / (1.0 + c)));
                            }
                            polygon.Add(b.far);
                            polygon.Close();
                            outlines.push_back(polygon.Wire());
                        }
                    }
                    for (const TopoDS_Wire& outline : outlines) {
                        BRepBuilderAPI_MakeFace face(outline, true);
                        if (face.IsDone()) {
                            faces.push_back(face.Face());
                            roles.push_back({face.Face(), prefix + "(" + strips[i].name + "|" + strips[j].name + ")"});
                        }
                    }
                }
            }
        }
    }
    // Cut back: ruled again from the edge to its far edge between the cuts.
    for (size_t k = 0; k < strips.size(); ++k) {
        if (!cuts[k][0] && !cuts[k][1]) {
            continue;
        }
        double first = 0.0;
        double last = 0.0;
        const Handle(Geom_Curve) curve = BRep_Tool::Curve(strips[k].far_edge, first, last);
        const double from = cuts[k][0].value_or(first);
        const double to = cuts[k][1].value_or(last);
        if (curve.IsNull() || to - from <= 1e-9 * (last - first)) {
            continue;
        }
        const TopoDS_Face strip = BRepFill::Face(own_copy(TopoDS::Edge(strips[k].edge.Oriented(TopAbs_FORWARD))), BRepBuilderAPI_MakeEdge(curve, from, to).Edge());
        if (!strip.IsNull()) {
            faces[strips[k].index] = on_plane(strip);
            roles[strips[k].index].shape = faces[strips[k].index];
        }
    }
}

/// Shapes sewn within tolerance; each role's face becomes the face it turned into.
TopoDS_Shape sew(const std::vector<TopoDS_Shape>& shapes, std::vector<naming::Role>& roles, BRepBuilderAPI_Sewing& sewing)
{
    for (const TopoDS_Shape& s : shapes) {
        sewing.Add(s);
    }
    sewing.Perform();
    // (A face inside a shape sewn is followed by its sub-shape history; Modified only knows the
    // shapes added.)
    for (naming::Role& role : roles) {
        if (role.shape.IsNull()) {
            continue;
        }
        if (sewing.IsModifiedSubShape(role.shape)) {
            role.shape = sewing.ModifiedSubShape(role.shape);
        }
        else if (sewing.IsModified(role.shape)) {
            role.shape = sewing.Modified(role.shape);
        }
    }
    return sewing.SewedShape();
}

/// The side of its face's UV box an edge runs along: 0 u-min, 1 u-max, 2 v-min, 3 v-max, or -1.
int iso_side(const TopoDS_Edge& edge, const TopoDS_Face& face, double u1, double u2, double v1, double v2)
{
    double f = 0.0;
    double l = 0.0;
    Handle(Geom2d_Curve) pcurve = BRep_Tool::CurveOnSurface(edge, face, f, l);
    if (pcurve.IsNull()) {
        return -1;
    }
    const double tu = 1e-6 * std::max(u2 - u1, 1e-9);
    const double tv = 1e-6 * std::max(v2 - v1, 1e-9);
    bool on[4] = {true, true, true, true};
    for (int i = 0; i <= 4; ++i) {
        const gp_Pnt2d uv = pcurve->Value(f + (l - f) * i / 4.0);
        on[0] = on[0] && std::abs(uv.X() - u1) < tu;
        on[1] = on[1] && std::abs(uv.X() - u2) < tu;
        on[2] = on[2] && std::abs(uv.Y() - v1) < tv;
        on[3] = on[3] && std::abs(uv.Y() - v2) < tv;
    }
    for (int side = 0; side < 4; ++side) {
        if (on[side]) {
            return side;
        }
    }
    return -1;
}

/// A spline surface extrapolated past one side of its box (see iso_side) by length, keeping its
/// curvature. GeomLib gives the added span length / speed in parameter, but at most length (as if
/// parameters always ran at least one unit of length per unit): in meters that squeezes the span,
/// and areas (which OCCT integrates at points spread by parameter) then all but miss it. So the
/// surface is extended at a scale where its parameters run fast enough, and scaled back.
void extend_spline(Handle(Geom_BoundedSurface)& surface, double length, int side)
{
    const bool in_u = side < 2;
    const bool after = side == 1 || side == 3;
    double u1 = 0.0, u2 = 0.0, v1 = 0.0, v2 = 0.0;
    surface->Bounds(u1, u2, v1, v2);
    double slowest = 1e300;
    for (int i = 0; i <= 8; ++i) {
        const double u = in_u ? (after ? u2 : u1) : u1 + (u2 - u1) * i / 8.0;
        const double v = in_u ? v1 + (v2 - v1) * i / 8.0 : (after ? v2 : v1);
        gp_Pnt point;
        gp_Vec du;
        gp_Vec dv;
        surface->D1(u, v, point, du, dv);
        slowest = std::min(slowest, (in_u ? du : dv).Magnitude());
    }
    const double scale = std::clamp(100.0 / std::max(slowest, 1e-300), 1.0, 1e6);
    const gp_Pnt center = surface->Value(0.5 * (u1 + u2), 0.5 * (v1 + v2));
    gp_Trsf up;
    up.SetScale(center, scale);
    surface->Transform(up);
    GeomLib::ExtendSurfByLength(surface, length * scale, 2, in_u, after);
    gp_Trsf down;
    down.SetScale(center, 1.0 / scale);
    surface->Transform(down);
}

/// curve between from and to carried on by length past its start and/or end: a line or conic
/// widens its range, another curve is extrapolated keeping its curvature (a strip of it extended as
/// extend_spline extends a surface). from and to get the carried curve's range.
Handle(Geom_Curve) carried_curve(const Handle(Geom_Curve)& curve, double& from, double& to, double length, bool at_start, bool at_end)
{
    Handle(Geom_Curve) basis = curve;
    for (Handle(Geom_TrimmedCurve) trimmed = Handle(Geom_TrimmedCurve)::DownCast(basis); !trimmed.IsNull();
        trimmed = Handle(Geom_TrimmedCurve)::DownCast(basis)) {
        basis = trimmed->BasisCurve();
    }
    if (basis->IsKind(STANDARD_TYPE(Geom_Line)) || basis->IsKind(STANDARD_TYPE(Geom_Conic))) {
        const double start = from;
        const double end = to;
        if (at_start) {
            from -= length / std::max(basis->DN(start, 1).Magnitude(), 1e-12);
        }
        if (at_end) {
            to += length / std::max(basis->DN(end, 1).Magnitude(), 1e-12);
        }
        if (basis->IsPeriodic() && to - from > basis->Period()) {
            from = at_start && !at_end ? to - basis->Period() : from;
            to = from + basis->Period();
        }
        return basis;
    }
    const Handle(Geom_BSplineCurve) spline = GeomConvert::CurveToBSplineCurve(new Geom_TrimmedCurve(curve, from, to));
    const int n = spline->NbPoles();
    TColgp_Array2OfPnt poles(1, n, 1, 2);
    TColStd_Array2OfReal weights(1, n, 1, 2);
    const gp_Vec aside(std::max(spline->StartPoint().Distance(spline->EndPoint()), 1e-6), 0.0, 0.0);
    for (int i = 1; i <= n; ++i) {
        poles(i, 1) = spline->Pole(i);
        poles(i, 2) = spline->Pole(i).Translated(aside);
        weights(i, 1) = spline->Weight(i);
        weights(i, 2) = spline->Weight(i);
    }
    TColStd_Array1OfReal knots(1, spline->NbKnots());
    TColStd_Array1OfInteger mults(1, spline->NbKnots());
    spline->Knots(knots);
    spline->Multiplicities(mults);
    TColStd_Array1OfReal ends(1, 2);
    ends(1) = 0.0;
    ends(2) = 1.0;
    TColStd_Array1OfInteger once(1, 2);
    once.Init(2);
    Handle(Geom_BoundedSurface) strip = new Geom_BSplineSurface(poles, weights, knots, ends, mults, once, spline->Degree(), 1);
    if (at_start) {
        extend_spline(strip, length, 0);
    }
    if (at_end) {
        extend_spline(strip, length, 1);
    }
    const Handle(Geom_BSplineSurface) grown = Handle(Geom_BSplineSurface)::DownCast(strip);
    if (grown.IsNull()) {
        return Handle(Geom_Curve)();
    }
    double v = 0.0;
    double unused = 0.0;
    grown->Bounds(from, to, v, unused);
    return grown->VIso(v);
}

/// face (filling its surface's UV box u1..v2) carried on past its edges, on the given sides of the
/// box (see iso_side), by distance. An analytic surface widens its bounds, in parameter steps
/// measured at each edge's middle; a spline, and an analytic surface past its own end (an
/// extrusion along a spline at the spline's end), is extrapolated keeping its curvature. A surface
/// of revolution carries on along its profile: the profile is carried on and turned again (its
/// spline form, rational round the axis, would carry on askew).
TopoDS_Face grown_face(const TopoDS_Face& face, const std::vector<TopoDS_Edge>& edges, const std::vector<int>& sides, double u1, double u2,
    double v1, double v2, double distance)
{
    Handle(Geom_Surface) basis = BRep_Tool::Surface(face);
    for (Handle(Geom_RectangularTrimmedSurface) trimmed = Handle(Geom_RectangularTrimmedSurface)::DownCast(basis); !trimmed.IsNull();
        trimmed = Handle(Geom_RectangularTrimmedSurface)::DownCast(basis)) {
        basis = trimmed->BasisSurface();
    }
    double bounds[4] = {u1, u2, v1, v2};
    std::vector<std::pair<int, double>> extrapolated;
    const Handle(Geom_SurfaceOfRevolution) turned = Handle(Geom_SurfaceOfRevolution)::DownCast(basis);
    bool along_profile[2] = {false, false};
    if (basis->IsKind(STANDARD_TYPE(Geom_BSplineSurface)) || basis->IsKind(STANDARD_TYPE(Geom_BezierSurface))) {
        for (int side : sides) {
            extrapolated.push_back({side, distance});
        }
    }
    else {
        double ends[4] = {0.0, 0.0, 0.0, 0.0};
        basis->Bounds(ends[0], ends[1], ends[2], ends[3]);
        for (size_t s = 0; s < sides.size(); ++s) {
            double f = 0.0;
            double l = 0.0;
            const gp_Pnt2d mid = BRep_Tool::CurveOnSurface(edges[s], face, f, l)->Value(0.5 * (f + l));
            gp_Pnt point;
            gp_Vec du;
            gp_Vec dv;
            basis->D1(mid.X(), mid.Y(), point, du, dv);
            const int side = sides[s];
            const bool in_u = side < 2;
            if (!turned.IsNull() && !in_u) {
                along_profile[side - 2] = true;
                continue;
            }
            const double sign = side == 0 || side == 2 ? -1.0 : 1.0;
            const double step = distance / std::max((in_u ? du : dv).Magnitude(), 1e-12);
            const double wanted = bounds[side] + sign * step;
            const bool periodic = in_u ? basis->IsUPeriodic() : basis->IsVPeriodic();
            if (periodic || sign * (ends[side] - wanted) >= 0.0) {
                bounds[side] = wanted;
                continue;
            }
            // The surface ends first: up to its end, then the rest extrapolated.
            const double rest = distance * (wanted - ends[side]) / (wanted - bounds[side]);
            bounds[side] = ends[side];
            extrapolated.push_back({side, rest});
        }
        if (basis->IsUPeriodic() && bounds[1] - bounds[0] > basis->UPeriod()) {
            bounds[1] = bounds[0] + basis->UPeriod();
        }
        if (basis->IsVPeriodic() && bounds[3] - bounds[2] > basis->VPeriod()) {
            bounds[3] = bounds[2] + basis->VPeriod();
        }
    }
    if (along_profile[0] || along_profile[1]) {
        double from = bounds[2];
        double to = bounds[3];
        const Handle(Geom_Curve) profile = carried_curve(turned->BasisCurve(), from, to, distance, along_profile[0], along_profile[1]);
        if (!profile.IsNull()) {
            return BRepBuilderAPI_MakeFace(new Geom_SurfaceOfRevolution(profile, turned->Axis()), bounds[0], bounds[1], from, to, Precision::Confusion()).Face();
        }
        for (int side : {2, 3}) {
            if (along_profile[side - 2]) {
                extrapolated.push_back({side, distance});
            }
        }
    }
    if (extrapolated.empty()) {
        return BRepBuilderAPI_MakeFace(basis, bounds[0], bounds[1], bounds[2], bounds[3], Precision::Confusion()).Face();
    }
    Handle(Geom_BoundedSurface) bounded = GeomConvert::SurfaceToBSplineSurface(new Geom_RectangularTrimmedSurface(basis, bounds[0], bounds[1], bounds[2], bounds[3]));
    for (const auto& [side, length] : extrapolated) {
        if (length > Precision::Confusion()) {
            extend_spline(bounded, length, side);
        }
    }
    return BRepBuilderAPI_MakeFace(bounded, Precision::Confusion()).Face();
}

/// The box (u1, u2, v1, v2) on grown's surface (a face's surface carried on past sides of the face's
/// box, see grown_face) of the band between edge, which runs along side, and grown's edge beyond.
std::array<double, 4> band_box(const TopoDS_Face& grown, const TopoDS_Edge& edge, int side)
{
    const Handle(Geom_Surface) surface = BRep_Tool::Surface(grown);
    std::array<double, 4> box = {0.0, 0.0, 0.0, 0.0};
    BRepTools::UVBounds(grown, box[0], box[1], box[2], box[3]);
    // The edge's ends and middle on the carried-on surface: its span along the side (a whole turn
    // for a closed edge) and where the side lies, brought into grown's box on a periodic surface.
    const bool in_u = side < 2;
    BRepAdaptor_Curve curve(edge);
    double along[3] = {0.0, 0.0, 0.0};
    double at = 0.0;
    for (int i = 0; i < 3; ++i) {
        GeomAPI_ProjectPointOnSurf on(curve.Value(curve.FirstParameter() + (curve.LastParameter() - curve.FirstParameter()) * i / 2.0), surface, PROJECTION_TOLERANCE);
        double u = 0.0;
        double v = 0.0;
        if (on.NbPoints() > 0) {
            on.LowerDistanceParameters(u, v);
        }
        along[i] = in_u ? v : u;
        at = i == 1 ? (in_u ? u : v) : at;
    }
    const double tolerance = 1e-9 * (std::abs(box[1] - box[0]) + std::abs(box[3] - box[2]));
    const double* span = in_u ? &box[2] : &box[0];
    const double* across = in_u ? &box[0] : &box[2];
    double lo = std::min(along[0], along[2]);
    double hi = std::max(along[0], along[2]);
    if (BRep_Tool::Pnt(TopExp::FirstVertex(edge)).Distance(BRep_Tool::Pnt(TopExp::LastVertex(edge))) < Precision::Confusion()) {
        lo = span[0];
        hi = span[1];
    }
    else if (in_u ? surface->IsVPeriodic() : surface->IsUPeriodic()) {
        const double period = in_u ? surface->VPeriod() : surface->UPeriod();
        if (along[1] < lo || along[1] > hi) {
            std::swap(lo, hi);
            hi += period;
        }
        for (; lo < span[0] - tolerance; lo += period, hi += period) {
        }
        for (; hi > span[1] + tolerance; lo -= period, hi -= period) {
        }
    }
    if (in_u ? surface->IsUPeriodic() : surface->IsVPeriodic()) {
        const double period = in_u ? surface->UPeriod() : surface->VPeriod();
        for (; at < across[0] - tolerance; at += period) {
        }
        for (; at > across[1] + tolerance; at -= period) {
        }
    }
    const bool before = side == 0 || side == 2;
    const double from = before ? across[0] : at;
    const double to = before ? at : across[1];
    return in_u ? std::array<double, 4>{from, to, lo, hi} : std::array<double, 4>{lo, hi, from, to};
}

/// face with its surface's natural boundary (outer) and/or without holes; drop lists hole loops
/// to remove (TShape matched). Unbounded directions keep the face's extent plus grow (and past it
/// by beyond[side], in parameter). joined: the sides of the face's UV box (see iso_side) along
/// which it meets another face, which stay where they are: the face doesn't grow into its
/// neighbour there, nor wrap round a periodic direction onto it.
TopoDS_Face untrimmed_face(const TopoDS_Face& face, bool outer, bool holes, const std::vector<TopoDS_Shape>& drop, double grow,
    const std::array<bool, 4>& joined, const std::array<double, 4>& beyond, String& error)
{
    const TopoDS_Face forward = TopoDS::Face(face.Oriented(TopAbs_FORWARD));
    const TopoDS_Wire outer_wire = BRepTools::OuterWire(forward);
    auto is_outer = [&](const TopoDS_Shape& wire) { return wire.TShape() == outer_wire.TShape(); };
    auto keep_hole = [&](const TopoDS_Shape& wire) {
        if (holes) {
            return false;
        }
        for (const TopoDS_Shape& d : drop) {
            if (d.TShape() == wire.TShape()) {
                return false;
            }
        }
        return true;
    };
    if (!outer) {
        // Same surface and outer boundary, fewer holes: a copy of the face with fewer wires.
        TopoDS_Face result = TopoDS::Face(with_children(forward, [&](const TopoDS_Shape& child) {
            const bool kept = child.ShapeType() == TopAbs_WIRE && (is_outer(child) || keep_hole(child));
            return kept ? child : TopoDS_Shape();
        }));
        result.Orientation(face.Orientation());
        return result;
    }
    Handle(Geom_Surface) surface = BRep_Tool::Surface(forward);
    double bounds[4] = {0.0, 0.0, 0.0, 0.0};
    surface->Bounds(bounds[0], bounds[1], bounds[2], bounds[3]);
    double own[4] = {0.0, 0.0, 0.0, 0.0};
    if (!measure::uv_bounds(forward, own[0], own[1], own[2], own[3])) {
        BRepTools::UVBounds(forward, own[0], own[1], own[2], own[3]);
    }
    // Where the edges themselves lie on the surface too: a cut's curve on the face can fall short of
    // its edge by the edge's tolerance (a tilted cut of a tube by 0.02 mm), and the face reaches the
    // edge.
    Handle(ShapeAnalysis_Surface) on = new ShapeAnalysis_Surface(surface);
    for (TopExp_Explorer it(forward, TopAbs_EDGE); it.More(); it.Next()) {
        const TopoDS_Edge& edge = TopoDS::Edge(it.Current());
        double f = 0.0;
        double l = 0.0;
        const Handle(Geom2d_Curve) pcurve = BRep_Tool::CurveOnSurface(edge, forward, f, l);
        if (pcurve.IsNull() || BRep_Tool::Degenerated(edge) || !BRep_Tool::IsGeometric(edge)) {
            continue;
        }
        const BRepAdaptor_Curve curve(edge);
        const double tolerance = BRep_Tool::Tolerance(edge);
        for (int i = 0; i <= 32; ++i) {
            const double t = f + (l - f) * i / 32.0;
            const gp_Pnt2d uv = on->NextValueOfUV(pcurve->Value(t), curve.Value(t), tolerance);
            if (on->Gap() <= 10.0 * tolerance) {
                // (A periodic direction keeps its curves' box: a projection can land a turn on.)
                if (!surface->IsUPeriodic()) {
                    own[0] = std::min(own[0], uv.X());
                    own[1] = std::max(own[1], uv.X());
                }
                if (!surface->IsVPeriodic()) {
                    own[2] = std::min(own[2], uv.Y());
                    own[3] = std::max(own[3], uv.Y());
                }
            }
        }
    }
    for (int side = 0; side < 4; ++side) {
        const bool periodic = side < 2 ? surface->IsUPeriodic() : surface->IsVPeriodic();
        const int other = side ^ 1;
        if (periodic && (joined[side] || joined[other])) {
            bounds[side] = own[side];
        }
        else if (Precision::IsInfinite(bounds[side])) {
            bounds[side] = own[side] + (joined[side] ? 0.0 : (side % 2 == 0 ? -grow - beyond[side] : grow + beyond[side]));
        }
    }
    BRepBuilderAPI_MakeFace maker(surface, bounds[0], bounds[1], bounds[2], bounds[3], Precision::Confusion());
    if (!maker.IsDone()) {
        error = "The face's surface has no bounds to go back to";
        return TopoDS_Face();
    }
    TopoDS_Face result = maker.Face();
    std::vector<TopoDS_Wire> kept;
    for (TopExp_Explorer w(forward, TopAbs_WIRE); w.More(); w.Next()) {
        if (!is_outer(w.Current()) && keep_hole(w.Current())) {
            kept.push_back(TopoDS::Wire(w.Current()));
        }
    }
    if (!kept.empty()) {
        BRepBuilderAPI_MakeFace adder(result);
        for (const TopoDS_Wire& wire : kept) {
            adder.Add(wire);
        }
        ShapeFix_Face fix(adder.Face());
        fix.Perform();
        result = fix.Face();
    }
    result.Orientation(face.Orientation());
    return result;
}

/// grown (face given more of its surface, see untrimmed_face) cut along each of face's edges in
/// joints, carried on straight from its ends to grown's box, and the part face lies in: face grown
/// only past its free edges, still bounded by the edges it shares. Null when a joint's line runs
/// through face, or the part along a joint isn't found.
TopoDS_Face cut_along(const TopoDS_Face& face, const TopoDS_Face& grown, const std::vector<TopoDS_Edge>& joints)
{
    const TopoDS_Face forward = TopoDS::Face(face.Oriented(TopAbs_FORWARD));
    const TopoDS_Face base = TopoDS::Face(grown.Oriented(TopAbs_FORWARD));
    const Handle(Geom_Surface) surface = BRep_Tool::Surface(base);
    double box[4] = {0.0, 0.0, 0.0, 0.0};
    BRepTools::UVBounds(base, box[0], box[1], box[2], box[3]);
    const double size = std::max(box[1] - box[0], box[3] - box[2]);
    const double tolerance = 1e-9 * size;
    TopTools_ListOfShape tools;
    for (const TopoDS_Edge& joint : joints) {
        double f = 0.0;
        double l = 0.0;
        const Handle(Geom2d_Curve) pcurve = BRep_Tool::CurveOnSurface(joint, forward, f, l);
        if (pcurve.IsNull()) {
            return TopoDS_Face();
        }
        // The joint itself (so the part keeps the very edge its neighbour has), carried on by lines.
        tools.Append(joint);
        std::vector<std::tuple<Handle(Geom2d_Curve), double, double>> parts;
        for (const bool at_end : {false, true}) {
            gp_Pnt2d p;
            gp_Vec2d d;
            pcurve->D1(at_end ? l : f, p, d);
            if (!at_end) {
                d.Reverse();
            }
            const bool on_box = std::abs(p.X() - box[0]) < tolerance || std::abs(p.X() - box[1]) < tolerance || std::abs(p.Y() - box[2]) < tolerance ||
                                std::abs(p.Y() - box[3]) < tolerance;
            if (on_box || d.Magnitude() < 1e-300) {
                continue;
            }
            const gp_Dir2d along(d);
            double reach = 1e300;
            for (int axis = 0; axis < 2; ++axis) {
                const double a = along.Coord(axis + 1);
                if (std::abs(a) > 1e-15) {
                    reach = std::min(reach, ((a > 0.0 ? box[axis * 2 + 1] : box[axis * 2]) - p.Coord(axis + 1)) / a);
                }
            }
            if (reach > tolerance && reach < 1e299) {
                parts.push_back({new Geom2d_Line(p, along), 0.0, reach});
            }
        }
        for (const auto& [curve, from, to] : parts) {
            BRepBuilderAPI_MakeEdge maker(curve, surface, from, to);
            if (!maker.IsDone()) {
                return TopoDS_Face();
            }
            TopoDS_Edge edge = maker.Edge();
            // Its 3D curve fitted to within a billionth of the face's size (OCCT's default, 10 um,
            // left such a line on a 5 mm cylinder 2 um off it).
            BRepLib::BuildCurves3d(edge, 1e-9 * diagonal(base));
            tools.Append(edge);
        }
    }
    BRepAlgoAPI_Splitter splitter;
    TopTools_ListOfShape arguments;
    arguments.Append(base);
    splitter.SetArguments(arguments);
    splitter.SetTools(tools);
    splitter.Build();
    if (!splitter.IsDone()) {
        return TopoDS_Face();
    }
    // Points well inside face: they must all fall in one part.
    double own[4] = {0.0, 0.0, 0.0, 0.0};
    if (!measure::uv_bounds(forward, own[0], own[1], own[2], own[3])) {
        return TopoDS_Face();
    }
    BRepTopAdaptor_FClass2d in_face(forward, Precision::PConfusion());
    std::vector<gp_Pnt2d> samples;
    for (int i = 1; i < 16; ++i) {
        for (int j = 1; j < 16; ++j) {
            const gp_Pnt2d uv(own[0] + (own[1] - own[0]) * i / 16.0, own[2] + (own[3] - own[2]) * j / 16.0);
            if (in_face.Perform(uv) == TopAbs_IN) {
                samples.push_back(uv);
            }
        }
    }
    if (samples.empty()) {
        return TopoDS_Face();
    }
    TopoDS_Face kept;
    for (TopExp_Explorer it(splitter.Shape(), TopAbs_FACE); it.More(); it.Next()) {
        const TopoDS_Face piece = TopoDS::Face(it.Current().Oriented(TopAbs_FORWARD));
        BRepTopAdaptor_FClass2d in_piece(piece, Precision::PConfusion());
        size_t count = 0;
        for (const gp_Pnt2d& uv : samples) {
            count += in_piece.Perform(uv) == TopAbs_IN ? 1 : 0;
        }
        if (count == 0) {
            continue;
        }
        if (count != samples.size() || !kept.IsNull()) {
            return TopoDS_Face();
        }
        kept = piece;
    }
    if (kept.IsNull()) {
        return TopoDS_Face();
    }
    // Every joint still bounds the part.
    TopoDS_Compound rim;
    BRep_Builder builder;
    builder.MakeCompound(rim);
    for (TopExp_Explorer it(kept, TopAbs_EDGE); it.More(); it.Next()) {
        builder.Add(rim, it.Current());
    }
    for (const TopoDS_Edge& joint : joints) {
        BRepAdaptor_Curve curve(joint);
        const gp_Pnt middle = curve.Value(0.5 * (curve.FirstParameter() + curve.LastParameter()));
        BRepExtrema_DistShapeShape gap(BRepBuilderAPI_MakeVertex(middle).Vertex(), rim);
        if (!gap.IsDone() || gap.Value() > std::max(10.0 * BRep_Tool::Tolerance(joint), 1e-7)) {
            return TopoDS_Face();
        }
    }
    kept.Orientation(face.Orientation());
    return kept;
}

/// s with the shells (and loose faces) that meet at an edge of across put together in one shell,
/// or s itself when no such edge joins two of them. Solids stay as they are.
TopoDS_Shape shells_joined(const TopoDS_Shape& s, const TopTools_MapOfShape& across)
{
    std::vector<TopoDS_Shape> parts;
    TopTools_IndexedMapOfShape faces;
    std::vector<int> part_of;
    auto add_part = [&](const TopoDS_Shape& part) {
        for (TopExp_Explorer f(part, TopAbs_FACE); f.More(); f.Next()) {
            if (faces.Add(f.Current()) > int(part_of.size())) {
                part_of.push_back(int(parts.size()));
            }
        }
        parts.push_back(part);
    };
    for (TopExp_Explorer it(s, TopAbs_SHELL, TopAbs_SOLID); it.More(); it.Next()) {
        add_part(it.Current());
    }
    for (TopExp_Explorer it(s, TopAbs_FACE, TopAbs_SHELL); it.More(); it.Next()) {
        add_part(it.Current());
    }
    std::vector<int> parent(parts.size());
    std::iota(parent.begin(), parent.end(), 0);
    auto root = [&](int i) {
        while (parent[i] != i) {
            parent[i] = parent[parent[i]];
            i = parent[i];
        }
        return i;
    };
    bool joined = false;
    TopTools_IndexedDataMapOfShapeListOfShape edge_faces;
    TopExp::MapShapesAndAncestors(s, TopAbs_EDGE, TopAbs_FACE, edge_faces);
    for (TopTools_MapOfShape::Iterator it(across); it.More(); it.Next()) {
        const int e = edge_faces.FindIndex(it.Key());
        if (e <= 0) {
            continue;
        }
        int first = -1;
        for (TopTools_ListOfShape::Iterator f(edge_faces(e)); f.More(); f.Next()) {
            const int k = faces.FindIndex(f.Value()) - 1;
            if (k < 0) {
                continue;
            }
            const int r = root(part_of[k]);
            if (first < 0) {
                first = r;
            }
            else if (r != first) {
                parent[r] = first;
                joined = true;
            }
        }
    }
    if (!joined) {
        return s;
    }
    std::vector<TopoDS_Shape> result;
    for (TopExp_Explorer it(s, TopAbs_SOLID); it.More(); it.Next()) {
        result.push_back(it.Current());
    }
    std::map<int, std::vector<int>> groups;
    for (size_t k = 0; k < parts.size(); ++k) {
        groups[root(int(k))].push_back(int(k));
    }
    BRep_Builder builder;
    for (const auto& [r, members] : groups) {
        if (members.size() == 1) {
            result.push_back(parts[members[0]]);
            continue;
        }
        TopoDS_Shell shell;
        builder.MakeShell(shell);
        for (int k : members) {
            for (TopExp_Explorer f(parts[k], TopAbs_FACE); f.More(); f.Next()) {
                builder.Add(shell, f.Current());
            }
        }
        shell.Closed(closed_shell(shell));
        result.push_back(shell);
    }
    for (TopExp_Explorer it(s, TopAbs_EDGE, TopAbs_FACE); it.More(); it.Next()) {
        result.push_back(it.Current());
    }
    return compound_of(result);
}

/// Says whether edges lie on a tool shape (within the edge's tolerance, judged at a few points).
/// Only the tool's faces (and loose edges) whose boxes reach an edge are measured, a flat one by
/// its plane first, so a trim's many edges cost little each. The distance is to the tool's
/// faces: an edge inside a solid tool isn't on it.
class ToolProbe
{
public:
    explicit ToolProbe(const TopoDS_Shape& tool)
    {
        auto add = [&](const TopoDS_Shape& part) {
            Part entry;
            entry.shape = part;
            BRepBndLib::Add(part, entry.box);
            if (part.ShapeType() == TopAbs_FACE) {
                BRepAdaptor_Surface surface(TopoDS::Face(part), false);
                entry.flat = surface.GetType() == GeomAbs_Plane;
                if (entry.flat) {
                    entry.plane = surface.Plane();
                }
            }
            parts.push_back(entry);
        };
        for (TopExp_Explorer it(tool, TopAbs_FACE); it.More(); it.Next()) {
            add(it.Current());
        }
        for (TopExp_Explorer it(tool, TopAbs_EDGE, TopAbs_FACE); it.More(); it.Next()) {
            add(it.Current());
        }
        for (TopExp_Explorer it(tool, TopAbs_VERTEX, TopAbs_EDGE); it.More(); it.Next()) {
            add(it.Current());
        }
    }

    /// True when the edge lies on the tool at a quarter, half and three quarters of the way along.
    bool holds(const TopoDS_Edge& edge) const
    {
        const double tolerance = std::max(10.0 * BRep_Tool::Tolerance(edge), Precision::Confusion() * 10.0);
        Bnd_Box edge_box;
        BRepBndLib::Add(edge, edge_box);
        edge_box.Enlarge(tolerance);
        std::vector<const Part*> near;
        for (const Part& part : parts) {
            if (!part.box.IsOut(edge_box)) {
                near.push_back(&part);
            }
        }
        if (near.empty()) {
            return false;
        }
        BRepAdaptor_Curve curve(edge);
        for (const double t : {0.5, 0.25, 0.75}) {
            const gp_Pnt point = curve.Value(curve.FirstParameter() + (curve.LastParameter() - curve.FirstParameter()) * t);
            Bnd_Box around;
            around.Add(point);
            around.Enlarge(tolerance);
            bool close = false;
            for (size_t k = 0; k < near.size() && !close; ++k) {
                const Part& part = *near[k];
                if (part.box.IsOut(around) || (part.flat && part.plane.Distance(point) > tolerance)) {
                    continue;
                }
                BRepExtrema_DistShapeShape distance(BRepBuilderAPI_MakeVertex(point).Vertex(), part.shape);
                close = distance.IsDone() && distance.Value() <= tolerance;
            }
            if (!close) {
                return false;
            }
        }
        return true;
    }

private:
    struct Part
    {
        TopoDS_Shape shape;
        Bnd_Box box;
        bool flat = false;
        gp_Pln plane;
    };
    std::vector<Part> parts;
};

/// How many edges of s bound only one face (a seam bounds its face twice).
int open_edges(const TopoDS_Shape& s)
{
    TopTools_IndexedDataMapOfShapeListOfShape edge_faces;
    TopExp::MapShapesAndAncestors(s, TopAbs_EDGE, TopAbs_FACE, edge_faces);
    int count = 0;
    for (int i = 1; i <= edge_faces.Extent(); ++i) {
        if (!BRep_Tool::Degenerated(TopoDS::Edge(edge_faces.FindKey(i))) && edge_faces(i).Extent() == 1) {
            ++count;
        }
    }
    return count;
}

/// How many solids, shells and loose faces s holds.
int part_count(const TopoDS_Shape& s)
{
    int count = 0;
    for (TopExp_Explorer it(s, TopAbs_SOLID); it.More(); it.Next()) {
        ++count;
    }
    for (TopExp_Explorer it(s, TopAbs_SHELL, TopAbs_SOLID); it.More(); it.Next()) {
        ++count;
    }
    for (TopExp_Explorer it(s, TopAbs_FACE, TopAbs_SHELL); it.More(); it.Next()) {
        ++count;
    }
    return count;
}

/// True when a shape's faces come to a point (a cone's apex, a sphere's pole).
bool has_point(const TopoDS_Shape& s)
{
    for (TopExp_Explorer it(s, TopAbs_EDGE); it.More(); it.Next()) {
        if (BRep_Tool::Degenerated(TopoDS::Edge(it.Current()))) {
            return true;
        }
    }
    return false;
}

/// A boundary edge of a patch: the edge, the shape it belongs to, its continuity (0 G0, 1 G1)
/// and, for G1, the face it carries on from (never one of an outline's own faces).
struct PatchEdge
{
    TopoDS_Edge edge;
    Shape owner;
    int continuity;
    TopoDS_Face support;
    bool outline = false;
};

/// The largest angle (radians) a G1 patch may stray from the faces it is tangent to.
constexpr double MAX_PATCH_ANGLE = 0.05;

/// OCCT's plate and cut have tolerances of their own that suit shapes about this big (their box's
/// diagonal, m) and up: a plate patch over a smaller loop, and a trim of a smaller surface, are made
/// scaled up to it and scaled back.
constexpr double WORK_SIZE = 0.01;

/// Edges meeting within this angle (radians) run on smoothly: one side of a patch, one chain for
/// Extend.
constexpr double SMOOTH_TURN = M_PI / 180.0;

/// Across edge at its parameter t, along face and into it (a face lies to the left of its edges
/// seen from its outward normal); null where that isn't defined.
gp_Vec into_face(const TopoDS_Face& face, const TopoDS_Edge& edge, double t)
{
    TopAbs_Orientation orientation = TopAbs_FORWARD;
    for (TopExp_Explorer it(face, TopAbs_EDGE); it.More(); it.Next()) {
        if (it.Current().IsSame(edge)) {
            orientation = it.Current().Orientation();
            break;
        }
    }
    double f = 0.0;
    double l = 0.0;
    const Handle(Geom2d_Curve) pcurve = BRep_Tool::CurveOnSurface(edge, face, f, l);
    if (pcurve.IsNull()) {
        return gp_Vec();
    }
    gp_Pnt point;
    gp_Vec tangent;
    BRepAdaptor_Curve(edge).D1(t, point, tangent);
    if (orientation == TopAbs_REVERSED) {
        tangent.Reverse();
    }
    const gp_Pnt2d uv = pcurve->Value(t);
    const gp_Vec into = normal_at(face, uv.X(), uv.Y()).Crossed(tangent);
    return into.Magnitude() > 1e-12 ? into.Normalized() : gp_Vec();
}

/// The parameter of an edge's point nearest point (between the edge's ends), and its distance.
/// (OCCT's projection falls back to the whole curve when the nearest point is an end: a point of
/// another arc of the same circle, or further along the same line, would read as on the edge.)
std::pair<double, double> nearest_on(const TopoDS_Edge& edge, const gp_Pnt& point)
{
    if (BRep_Tool::Degenerated(edge)) {
        return {0.0, 1e300};
    }
    const BRepAdaptor_Curve curve(edge);
    double t = curve.FirstParameter();
    double nearest = curve.Value(t).Distance(point);
    const double last = curve.Value(curve.LastParameter()).Distance(point);
    if (last < nearest) {
        nearest = last;
        t = curve.LastParameter();
    }
    const Extrema_ExtPC inside(point, curve);
    for (int i = 1; inside.IsDone() && i <= inside.NbExt(); ++i) {
        const double d = std::sqrt(inside.SquareDistance(i));
        if (d < nearest) {
            nearest = d;
            t = inside.Point(i).Parameter();
        }
    }
    return {t, nearest};
}

/// The largest angle (radians) between a plate patch and the faces its G1 edges carry on from,
/// along each edge between its ends (at a corner two faces meet, and no surface is tangent to
/// both; OCCT's own measures include the corners).
double tangency_gap(const TopoDS_Face& patch, const std::vector<PatchEdge>& constraints)
{
    const Handle(Geom_Surface) surface = BRep_Tool::Surface(patch);
    double worst = 0.0;
    for (const PatchEdge& c : constraints) {
        double f = 0.0;
        double l = 0.0;
        const Handle(Geom2d_Curve) pcurve = c.continuity > 0 && !c.support.IsNull() ? BRep_Tool::CurveOnSurface(c.edge, c.support, f, l) : Handle(Geom2d_Curve)();
        if (pcurve.IsNull()) {
            continue;
        }
        BRepAdaptor_Curve curve(c.edge);
        for (const double s : {0.25, 0.5, 0.75}) {
            const double t = curve.FirstParameter() + (curve.LastParameter() - curve.FirstParameter()) * s;
            GeomAPI_ProjectPointOnSurf on_patch(curve.Value(t), surface, PROJECTION_TOLERANCE);
            if (on_patch.NbPoints() == 0) {
                return M_PI;
            }
            double u = 0.0, v = 0.0;
            on_patch.LowerDistanceParameters(u, v);
            const gp_Pnt2d uv = pcurve->Value(t);
            worst = std::max(worst, std::acos(std::min(1.0, std::abs(normal_at(patch, u, v).Dot(normal_at(c.support, uv.X(), uv.Y()))))));
        }
    }
    return worst;
}

/// True for a face named as a plate patch (see patch): its plate is bent over a rectangle bigger
/// than the patch, so past its edges it has no natural boundary to go back to.
bool plate_face(const std::string& name)
{
    return name.find(":plate") != std::string::npos;
}

/// A wire through the edges in order, sharing vertices where the edges meet (within gap).
TopoDS_Wire joined(const TopoDS_Wire& chain, double gap)
{
    BRepBuilderAPI_MakeWire maker;
    for (TopoDS_Iterator it(chain); it.More(); it.Next()) {
        maker.Add(TopoDS::Edge(it.Value()));
        if (!maker.IsDone()) {
            break;
        }
    }
    if (maker.IsDone()) {
        return maker.Wire();
    }
    Handle(ShapeFix_Wire) fix = new ShapeFix_Wire();
    fix->Load(chain);
    fix->SetPrecision(gap);
    fix->ClosedWireMode() = true;
    fix->FixReorder();
    fix->FixConnected(gap);
    return fix->Wire();
}

/// An edge of a patch's loop, oriented the way the loop runs, with the boundary edge it came from
/// (an index into the boundary; joining the loop can copy an edge onto new vertices) and its
/// length.
struct LoopEdge
{
    TopoDS_Edge edge;
    int constraint;
    double length;
};

std::vector<LoopEdge> loop_edges(const TopoDS_Wire& wire, const std::vector<PatchEdge>& constraints)
{
    std::vector<LoopEdge> loop;
    for (BRepTools_WireExplorer it(wire); it.More(); it.Next()) {
        const TopoDS_Edge edge = TopoDS::Edge(it.Current().Oriented(it.Orientation()));
        if (BRep_Tool::Degenerated(edge)) {
            continue;
        }
        BRepAdaptor_Curve curve(edge);
        const gp_Pnt middle = curve.Value(0.5 * (curve.FirstParameter() + curve.LastParameter()));
        int best = -1;
        double nearest = 1e300;
        for (size_t c = 0; c < constraints.size() && nearest > 0.0; ++c) {
            const double d = constraints[c].edge.IsSame(edge) ? 0.0 : nearest_on(constraints[c].edge, middle).second;
            if (d < nearest) {
                nearest = d;
                best = int(c);
            }
        }
        loop.push_back({edge, best, GCPnts_AbscissaPoint::Length(curve)});
    }
    return loop;
}

/// A loop edge's tangent at its start or end, the way the loop runs.
gp_Vec loop_tangent(const TopoDS_Edge& edge, bool at_end)
{
    BRepAdaptor_Curve curve(edge);
    const bool reversed = edge.Orientation() == TopAbs_REVERSED;
    gp_Pnt point;
    gp_Vec tangent;
    curve.D1(at_end != reversed ? curve.LastParameter() : curve.FirstParameter(), point, tangent);
    return reversed ? tangent.Reversed() : tangent;
}

/// The angle (radians) the loop turns by where loop edge a ends and b starts.
double turn(const TopoDS_Edge& a, const TopoDS_Edge& b)
{
    const gp_Vec out = loop_tangent(a, true);
    const gp_Vec in = loop_tangent(b, false);
    return out.Magnitude() > 1e-12 && in.Magnitude() > 1e-12 ? out.Angle(in) : M_PI;
}

/// The loop's normal (Newell's, not unit), which it runs counterclockwise round: its inside lies
/// to the left of it.
gp_XYZ loop_normal(const std::vector<LoopEdge>& loop)
{
    std::vector<gp_Pnt> points;
    for (const LoopEdge& e : loop) {
        BRepAdaptor_Curve curve(e.edge);
        const bool reversed = e.edge.Orientation() == TopAbs_REVERSED;
        for (int i = 0; i < 8; ++i) {
            const double s = reversed ? 1.0 - i / 8.0 : i / 8.0;
            points.push_back(curve.Value(curve.FirstParameter() + (curve.LastParameter() - curve.FirstParameter()) * s));
        }
    }
    gp_XYZ center;
    for (const gp_Pnt& point : points) {
        center += point.XYZ();
    }
    center /= double(std::max<size_t>(points.size(), 1));
    gp_XYZ normal;
    for (size_t i = 0; i < points.size(); ++i) {
        normal += (points[i].XYZ() - center).Crossed(points[(i + 1) % points.size()].XYZ() - center);
    }
    return normal;
}

/// For each G1 boundary edge, the face the patch carries on from: the edge's only face or, of two
/// (a solid's edge), the one lying away from the loop's inside, so the patch follows the faces
/// around it (a box's walls round its top, a plate's top round a hole through it) and never one
/// it would cover. An edge with no face (a sketch curve's, an outline's) is left G0: returns how
/// many were.
int choose_supports(std::vector<PatchEdge>& constraints, const std::vector<LoopEdge>& loop)
{
    const gp_XYZ normal = loop_normal(loop);
    int dropped = 0;
    for (const LoopEdge& e : loop) {
        if (e.constraint < 0 || constraints[e.constraint].continuity == 0) {
            continue;
        }
        PatchEdge& c = constraints[e.constraint];
        BRepAdaptor_Curve curve(e.edge);
        gp_Pnt point;
        gp_Vec tangent;
        curve.D1(0.5 * (curve.FirstParameter() + curve.LastParameter()), point, tangent);
        if (e.edge.Orientation() == TopAbs_REVERSED) {
            tangent.Reverse();
        }
        const gp_Vec inside = gp_Vec(normal).Crossed(tangent);
        const double t = nearest_on(c.edge, point).first;
        double best = 1e300;
        for (const TopoDS_Face& face : c.outline ? std::vector<TopoDS_Face>() : faces_of_edge(c.owner, c.edge)) {
            const double score = into_face(face, c.edge, t).Dot(inside);
            if (c.support.IsNull() || score < best) {
                c.support = face;
                best = score;
            }
        }
        if (c.support.IsNull()) {
            c.continuity = 0;
            ++dropped;
        }
    }
    return dropped;
}

/// True when every G1 boundary edge's face is flat and in the plane of face (a flat patch then
/// carries on from all of them).
bool in_plane(const std::vector<PatchEdge>& constraints, const TopoDS_Face& face)
{
    const gp_Dir normal = BRepAdaptor_Surface(face).Plane().Axis().Direction();
    for (const PatchEdge& c : constraints) {
        if (c.continuity == 0) {
            continue;
        }
        BRepAdaptor_Surface support(c.support);
        if (support.GetType() != GeomAbs_Plane || !support.Plane().Axis().Direction().IsParallel(normal, 1e-9)) {
            return false;
        }
    }
    return true;
}

double loop_param(const LoopEdge& e, double s);

/// The loop's point at length s (below its length) along it.
gp_Pnt loop_point(const std::vector<LoopEdge>& loop, double s)
{
    for (const LoopEdge& e : loop) {
        if (s <= e.length || &e == &loop.back()) {
            return BRepAdaptor_Curve(e.edge).Value(loop_param(e, std::min(s, e.length)));
        }
        s -= e.length;
    }
    return gp_Pnt();
}

/// Where along the loop (lengths from its start, ascending, below its length) its sides meet:
/// its sharp corners when it has three or four; with fewer, the two ends of a lens (see
/// constrained_patch): its two corners, its corner and the point half way round from it, or
/// (none) the two points half way round from each other that lie farthest apart (smooth is then
/// set); empty when it has more than four.
std::vector<double> side_ends(const std::vector<LoopEdge>& loop, bool& smooth)
{
    std::vector<double> starts;
    double total = 0.0;
    for (const LoopEdge& e : loop) {
        starts.push_back(total);
        total += e.length;
    }
    std::vector<double> corners;
    for (size_t k = 0; k < loop.size(); ++k) {
        if (turn(loop[(k + loop.size() - 1) % loop.size()].edge, loop[k].edge) > SMOOTH_TURN) {
            corners.push_back(starts[k]);
        }
    }
    if (corners.size() > 4 || total <= 0.0) {
        return {};
    }
    smooth = corners.size() < 3;
    std::vector<double> ends = corners;
    if (corners.size() == 1) {
        ends = {corners[0], corners[0] + total / 2.0};
    }
    else if (corners.empty()) {
        // The lens runs the long way (a slot's from end to end).
        double widest = -1.0;
        const int samples = 64;
        for (int i = 0; i < samples; ++i) {
            const double s = 0.5 * total * i / samples;
            const double across = loop_point(loop, s).Distance(loop_point(loop, s + 0.5 * total));
            if (across > widest * (1.0 + 1e-9)) {
                widest = across;
                ends = {s, s + 0.5 * total};
            }
        }
    }
    for (double& end : ends) {
        end = std::fmod(end, total);
    }
    std::sort(ends.begin(), ends.end());
    return ends;
}

/// The parameter of a loop edge at length s from where the loop enters it.
double loop_param(const LoopEdge& e, double s)
{
    BRepAdaptor_Curve curve(e.edge);
    const bool reversed = e.edge.Orientation() == TopAbs_REVERSED;
    const double start = reversed ? curve.LastParameter() : curve.FirstParameter();
    const double end = reversed ? curve.FirstParameter() : curve.LastParameter();
    if (s <= 1e-12 * e.length) {
        return start;
    }
    if (s >= e.length * (1.0 - 1e-12)) {
        return end;
    }
    GCPnts_AbscissaPoint at(curve, reversed ? -s : s, start);
    return at.IsDone() ? at.Parameter() : start + (end - start) * s / e.length;
}

/// The stretch of the loop from length a to length b along it (a < b, at most one lap on) as
/// pieces of its edges: (loop edge, parameter where the piece starts, where it ends).
std::vector<std::tuple<int, double, double>> pieces_between(const std::vector<LoopEdge>& loop, double a, double b)
{
    double total = 0.0;
    for (const LoopEdge& e : loop) {
        total += e.length;
    }
    std::vector<std::tuple<int, double, double>> pieces;
    double lo = 0.0;
    for (int lap = 0; lap < 2; ++lap) {
        for (size_t k = 0; k < loop.size(); ++k) {
            const double hi = lo + loop[k].length;
            const double from = std::max(a, lo);
            const double to = std::min(b, hi);
            if (to - from > 1e-9 * total) {
                pieces.push_back({int(k), loop_param(loop[k], from - lo), loop_param(loop[k], to - lo)});
            }
            lo = hi;
        }
    }
    return pieces;
}

/// curve (bounded) as a non-rational cubic B-spline: exactly for lines and splines of degree three
/// or less, else within tolerance; null when that fails.
Handle(Geom_BSplineCurve) cubic(const Handle(Geom_Curve)& curve, double tolerance)
{
    Handle(Geom_BSplineCurve) spline = GeomConvert::CurveToBSplineCurve(curve);
    if (!spline.IsNull() && !spline->IsRational() && spline->Degree() <= 3) {
        spline->IncreaseDegree(3);
        return spline;
    }
    // (Smoother continuity would need a higher degree: the approximation meets it at its knots.)
    GeomConvert_ApproxCurve approximation(curve, tolerance, GeomAbs_C1, 200, 3);
    return approximation.HasResult() ? approximation.Curve() : Handle(Geom_BSplineCurve)();
}

/// Pieces of the loop (see pieces_between) joined into one cubic B-spline on [0, 1], running as
/// the loop does; null when they don't join.
Handle(Geom_BSplineCurve) side_curve(const std::vector<LoopEdge>& loop, const std::vector<std::tuple<int, double, double>>& pieces, double tolerance)
{
    std::unique_ptr<GeomConvert_CompCurveToBSplineCurve> joiner;
    for (const auto& [k, from, to] : pieces) {
        double f = 0.0;
        double l = 0.0;
        const Handle(Geom_Curve) curve = BRep_Tool::Curve(loop[k].edge, f, l);
        if (curve.IsNull() || std::abs(to - from) < Precision::PConfusion()) {
            continue;
        }
        Handle(Geom_TrimmedCurve) piece = new Geom_TrimmedCurve(curve, std::min(from, to), std::max(from, to));
        if (from > to) {
            piece->Reverse();
        }
        const Handle(Geom_BSplineCurve) spline = cubic(piece, tolerance);
        if (spline.IsNull()) {
            return Handle(Geom_BSplineCurve)();
        }
        if (!joiner) {
            joiner = std::make_unique<GeomConvert_CompCurveToBSplineCurve>(spline);
        }
        else if (!joiner->Add(spline, std::max(tolerance * 100.0, Precision::Confusion()), true)) {
            return Handle(Geom_BSplineCurve)();
        }
    }
    if (!joiner) {
        return Handle(Geom_BSplineCurve)();
    }
    Handle(Geom_BSplineCurve) side = joiner->BSplineCurve();
    TColStd_Array1OfReal knots(1, side->NbKnots());
    side->Knots(knots);
    BSplCLib::Reparametrize(0.0, 1.0, knots);
    side->SetKnots(knots);
    return side;
}

/// Gives cubic curves on [0, 1] the same knots (each keeping its shape); false when they still
/// differ.
bool same_knots(std::vector<Handle(Geom_BSplineCurve)>& curves)
{
    std::vector<std::pair<double, int>> merged;
    for (const Handle(Geom_BSplineCurve)& curve : curves) {
        for (int i = 2; i < curve->NbKnots(); ++i) {
            const double knot = curve->Knot(i);
            auto found = std::find_if(merged.begin(), merged.end(), [&](const std::pair<double, int>& m) { return std::abs(m.first - knot) < 1e-10; });
            if (found == merged.end()) {
                merged.push_back({knot, curve->Multiplicity(i)});
            }
            else {
                found->second = std::max(found->second, curve->Multiplicity(i));
            }
        }
    }
    std::sort(merged.begin(), merged.end());
    if (!merged.empty()) {
        TColStd_Array1OfReal knots(1, int(merged.size()));
        TColStd_Array1OfInteger mults(1, int(merged.size()));
        for (size_t i = 0; i < merged.size(); ++i) {
            knots(int(i) + 1) = merged[i].first;
            mults(int(i) + 1) = merged[i].second;
        }
        for (Handle(Geom_BSplineCurve)& curve : curves) {
            curve->InsertKnots(knots, mults, 1e-10, false);
        }
    }
    for (const Handle(Geom_BSplineCurve)& curve : curves) {
        if (curve->Degree() != 3 || curve->NbPoles() != curves[0]->NbPoles()) {
            return false;
        }
    }
    return true;
}

/// Samples of a field across a patch side: at j / FIELD_STEPS along it, j = 0 .. FIELD_STEPS.
constexpr int FIELD_STEPS = 32;

/// How far along a side (of its length, from each end) the field across it may turn from the
/// bilinear patch's at the corner to the one its edges ask for, shortest first. (Where two G1
/// faces meet at a corner, no surface carries both on there: the patch turns from one way to the
/// other within the ramp, the tighter the shorter it is. Over the shortest the blend of the two
/// sides' fields can pinch the patch near the corner, and fold it over.)
constexpr double CORNER_RAMPS[] = {0.12, 0.15, 0.2};

/// How fast a Coons patch's fields leave its sides (see constrained_patch), fastest first: one that
/// would bulge out past its faces or fold over (over walls leaning in, along a side bowed in) can
/// still fit flatter.
constexpr double PACES[] = {1.0, 0.75, 0.5};

/// The tightest a patch may bend (its smallest radius of curvature, of its size) to take a shorter
/// corner ramp: a cap's shell of about this thickness still fits. Nor may it then face back down
/// past its faces' lean (see cap_problem's sag) by more than SAG.
constexpr double TIGHTEST_BEND = 0.02;
constexpr double SAG = 0.01;

/// A lens's end where its sides turn by less than this (radians) is round, not a corner: the
/// patch's directions there turn a half circle round (see constrained_patch), so it carries G1
/// faces on right up to the end, where its normals turn by the corner's angle (a point Thicken
/// takes, see sharp_point in solid_ops.cpp). At a sharper end that point would be too sharp, so
/// it fans out flat as a corner does.
constexpr double LENS_FAN_TURN = M_PI / 4.0;

/// At a lens's corner, the least ramp (of its sides' mean length; see CORNER_RAMPS).
constexpr double LENS_RAMP = 0.15;

/// 0 up to 0, 1 from 1 on, and flat at both (smootherstep).
double ramp(double x)
{
    if (x <= 0.0) {
        return 0.0;
    }
    if (x >= 1.0) {
        return 1.0;
    }
    return x * x * x * (x * (6.0 * x - 15.0) + 10.0);
}

/// A cubic B-spline on [0, 1] through values[j] at at[j] (ascending from 0 to 1, vectors as
/// points), leaving with derivative start and arriving with derivative end; null when that fails.
Handle(Geom_BSplineCurve) field_curve(const std::vector<double>& at, const std::vector<gp_XYZ>& values, const gp_XYZ& start, const gp_XYZ& end)
{
    const int n = int(values.size()) - 1;
    const int count = n + 3;
    TColStd_Array1OfReal flat(1, count + 4);
    TColStd_Array1OfReal params(1, count);
    TColStd_Array1OfInteger orders(1, count);
    TColgp_Array1OfPnt poles(1, count);
    for (int i = 1; i <= 4; ++i) {
        flat(i) = 0.0;
        flat(count + i) = 1.0;
    }
    for (int j = 1; j < n; ++j) {
        flat(4 + j) = at[j];
    }
    int next = 1;
    auto add = [&](double w, int order, const gp_XYZ& value) {
        params(next) = w;
        orders(next) = order;
        poles(next) = gp_Pnt(value);
        ++next;
    };
    add(0.0, 0, values[0]);
    add(0.0, 1, start);
    for (int j = 1; j < n; ++j) {
        add(at[j], 0, values[j]);
    }
    add(1.0, 1, end);
    add(1.0, 0, values[n]);
    int problem = 0;
    BSplCLib::Interpolate(3, flat, params, orders, poles, problem);
    if (problem != 0) {
        return Handle(Geom_BSplineCurve)();
    }
    TColStd_Array1OfReal knots(1, n + 1);
    TColStd_Array1OfInteger mults(1, n + 1);
    for (int j = 0; j <= n; ++j) {
        knots(j + 1) = at[j];
        mults(j + 1) = j == 0 || j == n ? 4 : 1;
    }
    return new Geom_BSplineCurve(poles, knots, mults, 3);
}

/// How fast (the length of a Hermite end's derivative) a cubic through a circular arc over a chord
/// this long leaves when the arc turns by turning in all: the chord's length when it is straight.
double arc_speed(double chord, double turning)
{
    const double half = 0.5 * std::min(turning, 1.5 * M_PI);
    return half < 1e-6 ? chord : 2.0 * chord * std::tan(0.5 * half) / std::sin(half);
}

/// A cubic B-spline on [0, 1] (vectors as points) from a to b, leaving along lead as a circular arc
/// through both would; start and end get its derivatives at its ends.
Handle(Geom_BSplineCurve) arc_between(const gp_XYZ& a, const gp_XYZ& b, const gp_Vec& lead, gp_XYZ& start, gp_XYZ& end)
{
    const gp_Vec chord(b - a);
    const gp_Vec out = lead.Normalized();
    gp_Vec in = out;
    double speed = chord.Magnitude();
    if (chord.Magnitude() > 1e-300) {
        const gp_Vec along = chord.Normalized();
        speed = arc_speed(chord.Magnitude(), 2.0 * out.Angle(along));
        in = along * (2.0 * out.Dot(along)) - out;
    }
    start = (out * speed).XYZ();
    end = (in * speed).XYZ();
    TColgp_Array1OfPnt poles(1, 4);
    poles(1) = gp_Pnt(a);
    poles(2) = gp_Pnt(a + start / 3.0);
    poles(3) = gp_Pnt(b - end / 3.0);
    poles(4) = gp_Pnt(b);
    TColStd_Array1OfReal knots(1, 2);
    knots(1) = 0.0;
    knots(2) = 1.0;
    TColStd_Array1OfInteger mults(1, 2);
    mults.Init(4);
    return new Geom_BSplineCurve(poles, knots, mults, 3);
}

/// A Coons patch on [0, 1]^2: its sides (c0 at v = 0 and c1 at v = 1 run along u, d0 at u = 0 and
/// d1 at u = 1 along v), their corners, derivatives and twists there (the bilinear Coons patch's,
/// so every field across a side, which starts as that patch's, meets them).
struct Coons
{
    Handle(Geom_BSplineCurve) c0, c1, d0, d1;
    gp_XYZ p[2][2], pu[2][2], pv[2][2], twist[2][2];

    void corners()
    {
        for (int a = 0; a < 2; ++a) {
            for (int b = 0; b < 2; ++b) {
                gp_Pnt point;
                gp_Vec d;
                (b == 0 ? c0 : c1)->D1(a, point, d);
                p[a][b] = point.XYZ();
                pu[a][b] = d.XYZ();
                (a == 0 ? d0 : d1)->D1(b, point, d);
                pv[a][b] = d.XYZ();
            }
        }
        const gp_XYZ mixed = p[0][0] - p[1][0] - p[0][1] + p[1][1];
        for (int a = 0; a < 2; ++a) {
            for (int b = 0; b < 2; ++b) {
                twist[a][b] = pu[a][1] - pu[a][0] + pv[1][b] - pv[0][b] - mixed;
            }
        }
    }

    const Handle(Geom_BSplineCurve)& side(int k) const
    {
        return k == 0 ? c0 : k == 1 ? c1 : k == 2 ? d0 : d1;
    }

    /// The bilinear Coons patch's derivative across side k (0 c0, 1 c1: in v; 2 d0, 3 d1: in u)
    /// at w along it.
    gp_XYZ across(int k, double w) const
    {
        if (k < 2) {
            return c1->Value(w).XYZ() - c0->Value(w).XYZ() + pv[0][k] * (1.0 - w) + pv[1][k] * w - (p[0][1] - p[0][0]) * (1.0 - w) - (p[1][1] - p[1][0]) * w;
        }
        const int a = k - 2;
        return d1->Value(w).XYZ() - d0->Value(w).XYZ() + pu[a][0] * (1.0 - w) + pu[a][1] * w - (p[1][0] - p[0][0]) * (1.0 - w) - (p[1][1] - p[0][1]) * w;
    }

    /// The twists where side k starts and ends.
    gp_XYZ twist_at(int k, bool end) const
    {
        return k < 2 ? twist[end ? 1 : 0][k] : twist[k - 2][end ? 1 : 0];
    }

    /// The surface running along the sides and leaving them with the fields (t0, t1, s0, s1: the
    /// derivatives across c0 and c1 in v, d0 and d1 in u): c0, c1, t0, t1 Hermite-blended in v,
    /// plus d0, d1, s0, s1 blended in u, less the bicubic patch of the corner data. Null when the
    /// curves don't fit together.
    Handle(Geom_BSplineSurface) surface(const std::array<Handle(Geom_BSplineCurve), 4>& fields) const
    {
        auto copy = [](const Handle(Geom_BSplineCurve)& curve) { return Handle(Geom_BSplineCurve)::DownCast(curve->Copy()); };
        std::vector<Handle(Geom_BSplineCurve)> along_u = {copy(c0), copy(c1), copy(fields[0]), copy(fields[1])};
        std::vector<Handle(Geom_BSplineCurve)> along_v = {copy(d0), copy(d1), copy(fields[2]), copy(fields[3])};
        if (!same_knots(along_u) || !same_knots(along_v)) {
            return Handle(Geom_BSplineSurface)();
        }
        const int nu = along_u[0]->NbPoles();
        const int nv = along_v[0]->NbPoles();
        // A Hermite blend as a cubic Bezier: a, a + ta / 3, b - tb / 3, b.
        auto hermite = [](const gp_XYZ& a, const gp_XYZ& b, const gp_XYZ& ta, const gp_XYZ& tb) {
            return std::array<gp_Pnt, 4>{gp_Pnt(a), gp_Pnt(a + ta / 3.0), gp_Pnt(b - tb / 3.0), gp_Pnt(b)};
        };
        TColgp_Array2OfPnt lc(1, nu, 1, 4);
        for (int i = 1; i <= nu; ++i) {
            const auto net = hermite(along_u[0]->Pole(i).XYZ(), along_u[1]->Pole(i).XYZ(), along_u[2]->Pole(i).XYZ(), along_u[3]->Pole(i).XYZ());
            for (int j = 0; j < 4; ++j) {
                lc(i, j + 1) = net[j];
            }
        }
        TColgp_Array2OfPnt ld(1, 4, 1, nv);
        for (int j = 1; j <= nv; ++j) {
            const auto net = hermite(along_v[0]->Pole(j).XYZ(), along_v[1]->Pole(j).XYZ(), along_v[2]->Pole(j).XYZ(), along_v[3]->Pole(j).XYZ());
            for (int i = 0; i < 4; ++i) {
                ld(i + 1, j) = net[i];
            }
        }
        // The corner data in the Hermite basis (positions at 0 and 1, then derivatives there),
        // turned into a Bezier net: C^T M C.
        gp_XYZ m[4][4];
        for (int a = 0; a < 2; ++a) {
            for (int b = 0; b < 2; ++b) {
                m[a][b] = p[a][b];
                m[a][2 + b] = pv[a][b];
                m[2 + a][b] = pu[a][b];
                m[2 + a][2 + b] = twist[a][b];
            }
        }
        const double basis[4][4] = {{1.0, 1.0, 0.0, 0.0}, {0.0, 0.0, 1.0, 1.0}, {0.0, 1.0 / 3.0, 0.0, 0.0}, {0.0, 0.0, -1.0 / 3.0, 0.0}};
        TColgp_Array2OfPnt corner(1, 4, 1, 4);
        for (int i = 0; i < 4; ++i) {
            for (int j = 0; j < 4; ++j) {
                gp_XYZ sum;
                for (int r = 0; r < 4; ++r) {
                    for (int s = 0; s < 4; ++s) {
                        sum += m[r][s] * (basis[r][i] * basis[s][j]);
                    }
                }
                corner(i + 1, j + 1) = gp_Pnt(sum);
            }
        }
        TColStd_Array1OfReal uknots(1, along_u[0]->NbKnots());
        TColStd_Array1OfInteger umults(1, along_u[0]->NbKnots());
        along_u[0]->Knots(uknots);
        along_u[0]->Multiplicities(umults);
        TColStd_Array1OfReal vknots(1, along_v[0]->NbKnots());
        TColStd_Array1OfInteger vmults(1, along_v[0]->NbKnots());
        along_v[0]->Knots(vknots);
        along_v[0]->Multiplicities(vmults);
        TColStd_Array1OfReal ends(1, 2);
        ends(1) = 0.0;
        ends(2) = 1.0;
        TColStd_Array1OfInteger clamped(1, 2);
        clamped(1) = 4;
        clamped(2) = 4;
        Handle(Geom_BSplineSurface) blend_u = new Geom_BSplineSurface(lc, uknots, ends, umults, clamped, 3, 3);
        Handle(Geom_BSplineSurface) blend_v = new Geom_BSplineSurface(ld, ends, vknots, clamped, vmults, 3, 3);
        Handle(Geom_BSplineSurface) blend_corners = new Geom_BSplineSurface(corner, ends, ends, clamped, clamped, 3, 3);
        if (uknots.Length() > 2) {
            const TColStd_Array1OfReal inner(uknots(2), 1, uknots.Length() - 2);
            const TColStd_Array1OfInteger inner_mults(umults(2), 1, umults.Length() - 2);
            blend_v->InsertUKnots(inner, inner_mults, 1e-10, false);
            blend_corners->InsertUKnots(inner, inner_mults, 1e-10, false);
        }
        if (vknots.Length() > 2) {
            const TColStd_Array1OfReal inner(vknots(2), 1, vknots.Length() - 2);
            const TColStd_Array1OfInteger inner_mults(vmults(2), 1, vmults.Length() - 2);
            blend_u->InsertVKnots(inner, inner_mults, 1e-10, false);
            blend_corners->InsertVKnots(inner, inner_mults, 1e-10, false);
        }
        for (const Handle(Geom_BSplineSurface)& s : {blend_u, blend_v, blend_corners}) {
            if (s->NbUPoles() != nu || s->NbVPoles() != nv) {
                return Handle(Geom_BSplineSurface)();
            }
        }
        TColgp_Array2OfPnt poles(1, nu, 1, nv);
        for (int i = 1; i <= nu; ++i) {
            for (int j = 1; j <= nv; ++j) {
                poles(i, j) = gp_Pnt(blend_u->Pole(i, j).XYZ() + blend_v->Pole(i, j).XYZ() - blend_corners->Pole(i, j).XYZ());
            }
        }
        return new Geom_BSplineSurface(poles, uknots, vknots, umults, vmults, 3, 3);
    }
};

/// A patch over a loop of two to four sides meeting at ends (see side_ends): a Coons surface
/// filling [0, 1]^2 (a three-sided loop's sharpest corner is its collapsed fourth side; a lens of
/// two sides, for a loop with fewer corners, has both ends collapsed, so no corner of the patch
/// lies where the loop runs on smoothly). Across each side the surface leaves as the bilinear
/// Coons patch does, except where the side's edges lead: G1 edges carry on from their faces (in
/// their tangent planes, square to the edge), and with the loop split at smooth points (smooth,
/// see side_ends) G0 edges leave straight across; as fast as the opposite side is far (the
/// narrower way across at most), times pace (below 1 a flatter patch, see PACES). Near the corners,
/// where two faces can't both be met, the fields turn back to the bilinear patch's over corner_ramp
/// of each side (see CORNER_RAMPS); ramped is set when the patch has such a corner. steepest gets
/// the largest angle between the patch and the G1 faces at the quarter points of the sides, stray
/// the farthest its sides stray from the boundary edges. Null when it can't be built.
TopoDS_Face constrained_patch(const std::vector<LoopEdge>& loop, const std::vector<double>& ends, bool smooth, const std::vector<PatchEdge>& constraints,
    double tolerance, double corner_ramp, double pace, bool& ramped, double& steepest, double& stray)
{
    // A point the tangency is checked at: w along side, on boundary edge constraint at t.
    struct Check
    {
        int side;
        double w;
        int constraint;
        double t;
    };
    std::vector<Check> checks;
    ramped = false;
    double total = 0.0;
    for (const LoopEdge& e : loop) {
        total += e.length;
    }
    const size_t n = ends.size();
    std::vector<Handle(Geom_BSplineCurve)> sides(n);
    std::vector<std::vector<int>> runs_along(n);
    for (size_t i = 0; i < n; ++i) {
        const auto pieces = pieces_between(loop, ends[i], i + 1 < n ? ends[i + 1] : ends[0] + total);
        sides[i] = side_curve(loop, pieces, tolerance);
        if (sides[i].IsNull()) {
            return TopoDS_Face();
        }
        for (const auto& piece : pieces) {
            const int c = loop[std::get<0>(piece)].constraint;
            if (c >= 0 && std::find(runs_along[i].begin(), runs_along[i].end(), c) == runs_along[i].end()) {
                runs_along[i].push_back(c);
            }
        }
    }
    // Neighbouring sides meet exactly.
    for (size_t i = 0; i < n; ++i) {
        sides[i]->SetPole(sides[i]->NbPoles(), sides[(i + 1) % n]->Pole(1));
    }
    if (n == 3) {
        // The sharpest corner (where side apex ends) becomes the collapsed side, between s1 and s2.
        size_t apex = 0;
        double sharpest = -1.0;
        for (size_t i = 0; i < 3; ++i) {
            gp_Pnt point;
            gp_Vec out;
            gp_Vec in;
            sides[i]->D1(1.0, point, out);
            sides[(i + 1) % 3]->D1(0.0, point, in);
            const double angle = out.Magnitude() > 1e-12 && in.Magnitude() > 1e-12 ? out.Angle(in) : M_PI;
            if (angle > sharpest) {
                sharpest = angle;
                apex = i;
            }
        }
        std::rotate(sides.begin(), sides.begin() + (apex + 2) % 3, sides.end());
        std::rotate(runs_along.begin(), runs_along.begin() + (apex + 2) % 3, runs_along.end());
    }
    auto reversed = [](const Handle(Geom_BSplineCurve)& curve) { return Handle(Geom_BSplineCurve)::DownCast(curve->Reversed()); };
    auto collapsed = [](const gp_Pnt& at) {
        TColgp_Array1OfPnt point(1, 4);
        point.Init(at);
        TColStd_Array1OfReal knots(1, 2);
        knots(1) = 0.0;
        knots(2) = 1.0;
        TColStd_Array1OfInteger mults(1, 2);
        mults.Init(4);
        return Handle(Geom_BSplineCurve)(new Geom_BSplineCurve(point, knots, mults, 3));
    };
    Coons coons;
    coons.c0 = sides[0];
    std::array<const std::vector<int>*, 4> along = {&runs_along[0], nullptr, nullptr, nullptr};
    if (n == 2) {
        // A lens: both sides run from one end to the other, which are collapsed sides.
        coons.c1 = reversed(sides[1]);
        coons.d0 = collapsed(sides[0]->StartPoint());
        coons.d1 = collapsed(sides[0]->EndPoint());
        along[1] = &runs_along[1];
    }
    else if (n == 4) {
        coons.d1 = sides[1];
        coons.c1 = reversed(sides[2]);
        coons.d0 = reversed(sides[3]);
        along = {&runs_along[0], &runs_along[2], &runs_along[3], &runs_along[1]};
    }
    else {
        coons.d1 = sides[1];
        coons.d0 = reversed(sides[2]);
        coons.c1 = collapsed(sides[1]->EndPoint());
        along = {&runs_along[0], nullptr, &runs_along[2], &runs_along[1]};
    }
    coons.corners();
    // The boundary edge nearest a point of a side's (and its parameter there).
    auto owner_of = [&](const std::vector<int>* runs, const gp_Pnt& q, int& owner, double& param) {
        double nearest = 1e300;
        for (int c : *runs) {
            const auto [t, d] = nearest_on(constraints[c].edge, q);
            if (d < nearest) {
                nearest = d;
                owner = c;
                param = t;
            }
        }
    };
    // A lens's ends: a smooth point (or one all but smooth) turns a half circle of directions
    // round, leaving the way the patch does there (along the face a G1 edge carries on from, else
    // into the loop), so the patch leaves its sides that way right up to the ends; a corner fans
    // out flat (in the plane of its sides, so the patch has no point there) from one side's way to
    // the other's, turning as a circular arc does (a bilinear fan between sides that all but run
    // on would all but vanish).
    std::array<Handle(Geom_BSplineCurve), 4> fields;
    std::array<bool, 2> sharp = {true, true};
    std::array<std::array<gp_XYZ, 2>, 2> bent;
    for (int a = 0; a < 2 && n == 2; ++a) {
        const gp_Vec first(coons.pu[a][0]);
        const gp_Vec second(coons.pu[a][1]);
        if (first.Magnitude() < 1e-300 || second.Magnitude() < 1e-300) {
            continue;
        }
        gp_Vec lead;
        sharp[a] = first.Angle(second.Reversed()) > LENS_FAN_TURN;
        if (sharp[a]) {
            lead = second - first.Normalized() * second.Dot(first.Normalized());
        }
        else {
            const gp_Pnt end = coons.c0->Value(a);
            int owner = -1;
            double param = 0.0;
            std::vector<int> runs = runs_along[0];
            runs.insert(runs.end(), runs_along[1].begin(), runs_along[1].end());
            owner_of(&runs, end, owner, param);
            if (owner >= 0 && constraints[owner].continuity > 0) {
                lead = into_face(constraints[owner].support, constraints[owner].edge, param).Reversed();
            }
            else {
                lead = gp_Vec(end, gp_Pnt(0.5 * (coons.c0->Value(0.5).XYZ() + coons.c1->Value(0.5).XYZ())));
                lead -= first.Normalized() * lead.Dot(first.Normalized());
            }
            lead = a == 0 ? lead : lead.Reversed();
        }
        if (lead.Magnitude() < 1e-300) {
            sharp[a] = true;
            continue;
        }
        gp_XYZ start;
        gp_XYZ finish;
        fields[2 + a] = arc_between(coons.pu[a][0], coons.pu[a][1], lead, start, finish);
        // (A flat fan's twists differ from the bilinear patch's the fields across the sides
        // start from: bent says by how much, for them to start the fan's way.)
        if (sharp[a]) {
            bent[a] = {start - (coons.pu[a][1] - coons.pu[a][0]), finish - (coons.pu[a][1] - coons.pu[a][0])};
        }
        coons.twist[a][0] = start;
        coons.twist[a][1] = finish;
    }
    // From a point of a side to the opposite side, straight across: how fast the fields leave (no
    // faster than the narrower way across: the bulges across u and across v add up, so a slot
    // gets a tunnel, not a tower).
    auto chord = [&](int k, double w) {
        return k < 2 ? coons.c1->Value(w).XYZ() - coons.c0->Value(w).XYZ() : coons.d1->Value(w).XYZ() - coons.d0->Value(w).XYZ();
    };
    const double narrow = std::min(chord(0, 0.5).Modulus(), chord(2, 0.5).Modulus());
    // The sides' lengths at w = i / TABLE along them (a fine polyline's): corner ramps are measured
    // along them.
    constexpr int TABLE = 256;
    std::array<std::vector<double>, 4> lengths;
    for (int k = 0; k < 4; ++k) {
        lengths[k].assign(TABLE + 1, 0.0);
        gp_Pnt last = coons.side(k)->Value(0.0);
        for (int i = 1; i <= TABLE; ++i) {
            const gp_Pnt here = coons.side(k)->Value(double(i) / TABLE);
            lengths[k][i] = lengths[k][i - 1] + here.Distance(last);
            last = here;
        }
    }
    auto length_at = [&](int k, double w) {
        const double x = std::clamp(w, 0.0, 1.0) * TABLE;
        const int i = std::min(int(x), TABLE - 1);
        return lengths[k][i] + (lengths[k][i + 1] - lengths[k][i]) * (x - i);
    };
    for (int k = 0; k < 4; ++k) {
        if (n == 2 && k >= 2 && !fields[k].IsNull()) {
            continue;
        }
        const Handle(Geom_BSplineCurve)& curve = coons.side(k);
        const double length = lengths[k][TABLE];
        double ramp_length = std::max(corner_ramp * length, 1e-300);
        if (n == 2) {
            // A lens's short side turns over at least LENS_RAMP of its sides' mean length (a short turn
            // beside a long side folds it over), short of the middle of the side.
            ramp_length = std::min(std::max(ramp_length, LENS_RAMP * 0.5 * (lengths[0][TABLE] + lengths[1][TABLE])), 0.45 * length);
        }
        std::vector<double> at;
        for (int j = 0; j <= FIELD_STEPS; ++j) {
            at.push_back(double(j) / FIELD_STEPS);
        }
        // The boundary edge each sample lies on (and its parameter there).
        std::vector<int> owner(at.size(), -1);
        std::vector<double> param(at.size(), 0.0);
        for (size_t j = 0; j < at.size() && along[k] != nullptr; ++j) {
            owner_of(along[k], curve->Value(at[j]), owner[j], param[j]);
        }
        // The side's own edges lead: G1 edges along their faces; and with the loop split at smooth
        // points (where the bilinear patch leaves along the boundary, not across it) G0 edges
        // straight across. They take over from the bilinear patch past the corners (a lens's
        // smooth ends turn its way already), and fade where the continuity changes.
        auto g1 = [&](size_t j) { return owner[j] >= 0 && constraints[owner[j]].continuity > 0; };
        const bool from_corner = n != 2 || sharp[0];
        const bool to_corner = n != 2 || sharp[1];
        std::vector<double> changes;
        for (size_t j = 0; j + 1 < at.size(); ++j) {
            if (g1(j) != g1(j + 1)) {
                changes.push_back(0.5 * (length_at(k, at[j]) + length_at(k, at[j + 1])));
            }
        }
        std::vector<double> weight(at.size(), 0.0);
        for (size_t j = 0; j < at.size(); ++j) {
            if (owner[j] < 0 || !(g1(j) || smooth)) {
                continue;
            }
            const double s = length_at(k, at[j]);
            double change = 1e300;
            for (const double c : changes) {
                change = std::min(change, std::abs(c - s));
            }
            weight[j] = (from_corner ? ramp(s / ramp_length) : 1.0) * (to_corner ? ramp((length - s) / ramp_length) : 1.0) * ramp(change / ramp_length);
            ramped = ramped || from_corner || to_corner || !changes.empty();
        }
        // Into the patch is +v across c0 and +u across d0; across c1 and d1 it is the other way.
        const double sign = k == 0 || k == 2 ? 1.0 : -1.0;
        std::vector<gp_XYZ> values;
        for (size_t j = 0; j < at.size(); ++j) {
            const double w = at[j];
            gp_XYZ bilinear = coons.across(k, w);
            if (n == 2 && k < 2) {
                // Starting from a flat fan's way (see bent), back to the bilinear one by a ramp on.
                const double s = length_at(k, w);
                bilinear += bent[0][k] * (w * (1.0 - ramp(s / ramp_length))) + bent[1][k] * ((w - 1.0) * (1.0 - ramp((length - s) / ramp_length)));
            }
            gp_XYZ value = bilinear;
            if (weight[j] > 0.0) {
                gp_Vec lead;
                if (g1(j)) {
                    const PatchEdge& c = constraints[owner[j]];
                    lead = into_face(c.support, c.edge, param[j]).Reversed();
                }
                else {
                    gp_Pnt point;
                    gp_Vec tangent;
                    curve->D1(w, point, tangent);
                    lead = gp_Vec(chord(k, w)) * sign;
                    if (tangent.Magnitude() > 1e-12) {
                        lead -= tangent.Normalized() * lead.Dot(tangent.Normalized());
                    }
                }
                // As fast as the opposite side is far: a lens's cross section leaves as the
                // circular arc to the opposite point does (a half circle off walls square to it);
                // a patch's no faster than its narrower way across.
                const gp_Vec across(chord(k, w) * sign);
                const double speed = pace * (n == 2 ? (lead.Magnitude() > 1e-300 && across.Magnitude() > 1e-300 ? arc_speed(across.Magnitude(), 2.0 * lead.Angle(across)) : 0.0)
                                                    : std::min(across.Magnitude(), narrow));
                if (lead.Magnitude() > 1e-12) {
                    value = bilinear * (1.0 - weight[j]) + lead.Normalized().XYZ() * (sign * speed * weight[j]);
                }
            }
            values.push_back(value);
        }
        fields[k] = field_curve(at, values, coons.twist_at(k, false), coons.twist_at(k, true));
        if (fields[k].IsNull()) {
            return TopoDS_Face();
        }
        for (size_t j = 0; j < at.size(); ++j) {
            if ((at[j] == 0.25 || at[j] == 0.5 || at[j] == 0.75) && g1(j) && weight[j] >= 1.0) {
                checks.push_back({k, at[j], owner[j], param[j]});
            }
        }
    }
    const Handle(Geom_BSplineSurface) surface = coons.surface(fields);
    if (surface.IsNull()) {
        return TopoDS_Face();
    }
    // The surface runs along its sides exactly; they stray from the boundary edges as far as
    // approximating them lets them.
    stray = 0.0;
    for (const PatchEdge& c : constraints) {
        BRepAdaptor_Curve curve(c.edge);
        for (int i = 1; i < 6; ++i) {
            const gp_Pnt point = curve.Value(curve.FirstParameter() + (curve.LastParameter() - curve.FirstParameter()) * i / 6.0);
            double nearest = 1e300;
            for (int k = 0; k < 4; ++k) {
                gp_Pnt projected;
                double t = 0.0;
                nearest = std::min(nearest, ShapeAnalysis_Curve().Project(coons.side(k), point, Precision::Confusion(), projected, t));
            }
            stray = std::max(stray, nearest);
        }
    }
    steepest = 0.0;
    for (const Check& check : checks) {
        gp_Pnt point;
        gp_Vec su;
        gp_Vec sv;
        surface->D1(check.side < 2 ? check.w : check.side - 2, check.side < 2 ? check.side : check.w, point, su, sv);
        const PatchEdge& c = constraints[check.constraint];
        double f = 0.0;
        double l = 0.0;
        const Handle(Geom2d_Curve) pcurve = BRep_Tool::CurveOnSurface(c.edge, c.support, f, l);
        const gp_Vec normal = su.Crossed(sv);
        if (pcurve.IsNull() || normal.Magnitude() < 1e-30) {
            steepest = M_PI;
            break;
        }
        const gp_Pnt2d uv = pcurve->Value(check.t);
        steepest = std::max(steepest, std::acos(std::min(1.0, std::abs(normal.Normalized().Dot(normal_at(c.support, uv.X(), uv.Y()))))));
    }
    BRepBuilderAPI_MakeFace maker(surface, 0.0, 1.0, 0.0, 1.0, tolerance);
    return maker.IsDone() ? maker.Face() : TopoDS_Face();
}

/// True when a face fills its surface's own bounds (a Coons patch does): every point of its UV box
/// lies in it.
bool fills_surface(const TopoDS_Face& face)
{
    double u1 = 0.0, u2 = 0.0, v1 = 0.0, v2 = 0.0;
    BRepTools::UVBounds(face, u1, u2, v1, v2);
    double s1 = 0.0, s2 = 0.0, t1 = 0.0, t2 = 0.0;
    BRep_Tool::Surface(face)->Bounds(s1, s2, t1, t2);
    const double tolerance = 1e-9 * std::max(s2 - s1, t2 - t1);
    return face.NbChildren() == 1 && std::abs(u1 - s1) <= tolerance && std::abs(u2 - s2) <= tolerance && std::abs(v1 - t1) <= tolerance && std::abs(v2 - t2) <= tolerance;
}

/// A face's smallest radius of curvature, over a grid of its cells' middles (as offset_fits samples
/// it).
double tightest_bend(const TopoDS_Face& face)
{
    BRepAdaptor_Surface surface(face);
    double u1 = 0.0, u2 = 0.0, v1 = 0.0, v2 = 0.0;
    BRepTools::UVBounds(face, u1, u2, v1, v2);
    BRepTopAdaptor_FClass2d inside(face, Precision::PConfusion());
    const bool whole = fills_surface(face);
    double most = 0.0;
    const int n = 32;
    for (int i = 0; i < n; ++i) {
        for (int j = 0; j < n; ++j) {
            const gp_Pnt2d uv(u1 + (u2 - u1) * (i + 0.5) / n, v1 + (v2 - v1) * (j + 0.5) / n);
            if (!whole && inside.Perform(uv) == TopAbs_OUT) {
                continue;
            }
            gp_Pnt point;
            gp_Vec su, sv, suu, svv, suv;
            surface.D2(uv.X(), uv.Y(), point, su, sv, suu, svv, suv);
            const gp_Vec normal = normal_at(face, uv.X(), uv.Y());
            const double e = su.Dot(su), f = su.Dot(sv), g = sv.Dot(sv);
            const double l = suu.Dot(normal), m = suv.Dot(normal), nn = svv.Dot(normal);
            const double det = e * g - f * f;
            if (det < 1e-30) {
                continue;
            }
            const double mean = (e * nn - 2.0 * f * m + g * l) / (2.0 * det);
            const double gauss = (l * nn - m * m) / det;
            most = std::max(most, std::abs(mean) + std::sqrt(std::max(mean * mean - gauss, 0.0)));
        }
    }
    return most > 0.0 ? 1.0 / most : 1e300;
}

/// A loop edge as cap_problem and tangency_shortfall read it: its curve (reversed: the loop runs
/// against it), its length, the G1 face it carries on (null for G0) with the boundary edge lying on
/// that face (same: it is the loop edge, so their parameters agree), and points along it (by
/// length, parameters ascending) with the loop's way there and, on a G1 edge, the way the patch
/// carries the face on (along it, away from it).
struct RimEdge
{
    Handle(BRepAdaptor_Curve) curve;
    bool reversed = false;
    double length = 0.0;
    TopoDS_Face support;
    TopoDS_Edge on_support;
    Handle(BRepAdaptor_Curve) support_curve;
    Handle(Geom2d_Curve) pcurve;
    TopAbs_Orientation sense = TopAbs_FORWARD;
    bool same = false;
    std::vector<double> at;
    std::vector<gp_Pnt> points;
    std::vector<gp_Vec> tangents;
    std::vector<gp_Vec> leads;
};

/// A G1 rim edge's face at the edge's parameter t (point: the edge's point there): the face's
/// normal, and the way the patch carries the face on. Null vectors on a G0 edge.
std::pair<gp_Vec, gp_Vec> rim_frame(const RimEdge& r, double t, const gp_Pnt& point)
{
    if (r.support.IsNull()) {
        return {gp_Vec(), gp_Vec()};
    }
    const double at = r.same ? t : nearest_on(r.on_support, point).first;
    gp_Pnt p;
    gp_Vec tangent;
    r.support_curve->D1(at, p, tangent);
    if (r.sense == TopAbs_REVERSED) {
        tangent.Reverse();
    }
    const gp_Pnt2d uv = r.pcurve->Value(at);
    const gp_Vec normal = normal_at(r.support, uv.X(), uv.Y());
    const gp_Vec into = normal.Crossed(tangent);
    return {normal, into.Magnitude() > 1e-12 ? into.Normalized().Reversed() : gp_Vec()};
}

/// The loop's way (unit) along a rim edge at its parameter t.
gp_Vec rim_tangent(const RimEdge& r, double t)
{
    gp_Pnt p;
    gp_Vec tangent;
    r.curve->D1(t, p, tangent);
    if (r.reversed) {
        tangent.Reverse();
    }
    return tangent.Magnitude() > 1e-300 ? tangent.Normalized() : tangent;
}

/// The loop's edges as RimEdges, their points no further apart than spacing (24 at least).
std::vector<RimEdge> rim_of(const std::vector<LoopEdge>& loop, const std::vector<PatchEdge>& constraints, double spacing)
{
    std::vector<RimEdge> rim;
    for (const LoopEdge& e : loop) {
        RimEdge r;
        r.curve = new BRepAdaptor_Curve(e.edge);
        r.reversed = e.edge.Orientation() == TopAbs_REVERSED;
        r.length = e.length;
        const PatchEdge* c = e.constraint >= 0 ? &constraints[e.constraint] : nullptr;
        if (c != nullptr && c->continuity > 0 && !c->support.IsNull()) {
            double pf = 0.0;
            double pl = 0.0;
            r.pcurve = BRep_Tool::CurveOnSurface(c->edge, c->support, pf, pl);
            if (!r.pcurve.IsNull()) {
                r.support = c->support;
                r.on_support = c->edge;
                r.same = c->edge.IsSame(e.edge);
                r.support_curve = r.same ? r.curve : Handle(BRepAdaptor_Curve)(new BRepAdaptor_Curve(c->edge));
                for (TopExp_Explorer it(c->support, TopAbs_EDGE); it.More(); it.Next()) {
                    if (it.Current().IsSame(c->edge)) {
                        r.sense = it.Current().Orientation();
                        break;
                    }
                }
            }
        }
        const double f = r.curve->FirstParameter();
        const double l = r.curve->LastParameter();
        const int count = std::clamp(int(std::ceil(e.length / std::max(spacing, 1e-300))), 24, 4000);
        GCPnts_UniformAbscissa even(*r.curve, count + 1, f, l);
        const bool done = even.IsDone() && even.NbPoints() == count + 1;
        for (int i = 0; i <= count; ++i) {
            r.at.push_back(done ? even.Parameter(i + 1) : f + (l - f) * i / count);
            r.points.push_back(r.curve->Value(r.at.back()));
            r.tangents.push_back(rim_tangent(r, r.at.back()));
            r.leads.push_back(rim_frame(r, r.at.back(), r.points.back()).second);
        }
        rim.push_back(r);
    }
    return rim;
}

/// The point of a rim edge nearest point, searched from its point i (the nearest of them) to its
/// neighbours: (parameter, distance).
std::pair<double, double> rim_nearest(const RimEdge& r, size_t i, const gp_Pnt& point)
{
    const double lo = r.at[i > 0 ? i - 1 : 0];
    const double hi = r.at[std::min(i + 1, r.at.size() - 1)];
    double t = r.at[i];
    for (int k = 0; k < 24; ++k) {
        gp_Pnt c;
        gp_Vec d1;
        gp_Vec d2;
        r.curve->D2(t, c, d1, d2);
        const gp_Vec off(point, c);
        const double slope = off.Dot(d1);
        const double bend = d1.SquareMagnitude() + off.Dot(d2);
        const double next = std::clamp(bend > 1e-300 ? t - slope / bend : (slope > 0.0 ? lo : hi), lo, hi);
        const bool settled = std::abs(next - t) <= 1e-12 * std::max(hi - lo, 1e-300);
        t = next;
        if (settled) {
            break;
        }
    }
    double best = t;
    double nearest = r.curve->Value(t).Distance(point);
    for (const double end : {lo, hi}) {
        const double d = r.curve->Value(end).Distance(point);
        if (d < nearest) {
            nearest = d;
            best = end;
        }
    }
    return {best, nearest};
}

/// The place on surface (within its bounds) nearest point, by Gauss-Newton steps from uv (a place
/// near it), and how far that is from point.
std::pair<gp_Pnt2d, double> settle(const BRepAdaptor_Surface& surface, const gp_Pnt& point, gp_Pnt2d uv)
{
    const double u1 = surface.FirstUParameter();
    const double u2 = surface.LastUParameter();
    const double v1 = surface.FirstVParameter();
    const double v2 = surface.LastVParameter();
    for (int k = 0; k < 16; ++k) {
        gp_Pnt at;
        gp_Vec du;
        gp_Vec dv;
        surface.D1(uv.X(), uv.Y(), at, du, dv);
        const gp_Vec off(point, at);
        const double a = du.Dot(du);
        const double b = du.Dot(dv);
        const double c = dv.Dot(dv);
        const double det = a * c - b * b;
        if (!(det > 1e-24 * a * c)) {
            break;
        }
        const double gu = du.Dot(off);
        const double gv = dv.Dot(off);
        const gp_Pnt2d next(std::clamp(uv.X() - (c * gu - b * gv) / det, u1, u2), std::clamp(uv.Y() - (a * gv - b * gu) / det, v1, v2));
        const bool settled = std::abs(next.X() - uv.X()) <= 1e-12 * (u2 - u1) && std::abs(next.Y() - uv.Y()) <= 1e-12 * (v2 - v1);
        uv = next;
        if (settled) {
            break;
        }
    }
    return {uv, surface.Value(uv.X(), uv.Y()).Distance(point)};
}

/// Where a patch face leaves its boundary at point (tangent: the loop's way there): the face's
/// normal (with its orientation) and the way into it, square to the boundary along the face. Each
/// point is found on the face from the last one's place (uv; placed when that was found); false
/// where the face can't tell (the point is off it, or it comes to a point there).
bool leaves(const TopoDS_Face& face, ShapeAnalysis_Surface& on, const BRepAdaptor_Surface& surface, const std::function<bool(double, double)>& inside,
    const gp_Pnt& point, const gp_Vec& tangent, double step, gp_Pnt2d& uv, bool& placed, gp_Vec& normal, gp_Vec& into)
{
    // (Settled from the last point's place; else OCCT's projection, found to a tenth of the step,
    // which tells the way well. It settles to its own tolerance at best: on a patch under a
    // millimetre that is more than the step.)
    double gap = 1e300;
    if (placed) {
        std::tie(uv, gap) = settle(surface, point, uv);
    }
    if (gap > step) {
        uv = on.ValueOfUV(point, 0.1 * step);
        gap = on.Gap();
    }
    placed = gap <= std::max(10.0 * step, 10.0 * Precision::Confusion());
    if (!placed) {
        return false;
    }
    gp_Pnt p;
    gp_Vec du;
    gp_Vec dv;
    surface.D1(uv.X(), uv.Y(), p, du, dv);
    const double e = du.Dot(du);
    const double f = du.Dot(dv);
    const double g = dv.Dot(dv);
    const double det = e * g - f * f;
    normal = du.Crossed(dv);
    gp_Vec across = normal.Crossed(tangent);
    if (det <= 1e-12 * e * g || across.Magnitude() < 1e-300) {
        return false;
    }
    across.Normalize();
    const double a = (g * across.Dot(du) - f * across.Dot(dv)) / det * step;
    const double b = (e * across.Dot(dv) - f * across.Dot(du)) / det * step;
    const bool ahead = inside(uv.X() + a, uv.Y() + b);
    const bool behind = inside(uv.X() - a, uv.Y() - b);
    if (ahead == behind) {
        return false;
    }
    if (face.Orientation() == TopAbs_REVERSED) {
        normal.Reverse();
    }
    normal.Normalize();
    into = ahead ? across : across.Reversed();
    return true;
}

/// Values across [lo, hi] (a face's UV box, along u or v) for the band of samples along a side of
/// cap_problem's grid: GRID even steps, and every knot span of a spline surface split in two (a
/// feature of the boundary as narrow as a span then lies across samples), at most 2 GRID.
std::vector<double> band_values(const BRepAdaptor_Surface& surface, bool along_u, double lo, double hi, int grid)
{
    std::vector<double> values;
    for (int i = 0; i <= grid; ++i) {
        values.push_back(lo + (hi - lo) * i / grid);
    }
    if (surface.GetType() == GeomAbs_BSplineSurface) {
        const Handle(Geom_BSplineSurface) spline = surface.BSpline();
        const int count = along_u ? spline->NbUKnots() : spline->NbVKnots();
        for (int k = 1; k < count; ++k) {
            const double a = along_u ? spline->UKnot(k) : spline->VKnot(k);
            const double b = along_u ? spline->UKnot(k + 1) : spline->VKnot(k + 1);
            for (const double w : {a, 0.5 * (a + b)}) {
                if (w > lo && w < hi) {
                    values.push_back(w);
                }
            }
        }
    }
    std::sort(values.begin(), values.end());
    std::vector<double> kept;
    for (const double w : values) {
        if (kept.empty() || w - kept.back() > 1e-9 * (hi - lo)) {
            kept.push_back(w);
        }
    }
    const size_t most = size_t(2 * grid) + 1;
    if (kept.size() > most) {
        std::vector<double> fewer;
        for (size_t i = 0; i < most; ++i) {
            fewer.push_back(kept[size_t(std::llround(double(i) * double(kept.size() - 1) / double(most - 1)))]);
        }
        kept = fewer;
    }
    return kept;
}

/// What cap_problem found besides its verdict: how far the patch faces back down past its faces'
/// lean (the most its normal sinks below theirs), and where; how far it passes out past one of
/// their planes; and whether its fault is leaving the G1 faces the wrong way (back down along them,
/// or down below its edges), or a crease.
struct CapShape
{
    double sag = 0.0;
    gp_Pnt sag_at;
    // How far it passes out past the plane of one of its G1 faces.
    double outside = 0.0;
    bool wrong_way = false;
    bool creased = false;
};

/// G1 faces leaning out over the loop by more than this (radians) need a patch to rise past
/// upright to carry them on: a plate (which can't) is refused for their lean however it fails.
constexpr double LEAN_OUT = 20.0 * M_PI / 180.0;

/// A patch leaving a G1 edge within this (radians) of straight back along its face runs back down
/// it (see cap_problem).
constexpr double RUN_BACK = 20.0 * M_PI / 180.0;

/// A G1 patch passing out past the plane of one of its faces by more than this (of its size) says
/// how far (past all of them by cap_problem's gap it is refused).
constexpr double OUTSIDE = 1e-4;

/// True when the G1 faces along the loop (rim, see rim_of) lean out over it by more than LEAN_OUT
/// somewhere: a patch carrying them on would face down by that much there (see cap_problem's
/// floor).
bool leans_out(const std::vector<RimEdge>& rim, const std::vector<LoopEdge>& loop)
{
    const gp_XYZ newell = loop_normal(loop);
    if (newell.Modulus() < 1e-300) {
        return false;
    }
    const gp_Vec up(gp_Dir(newell).XYZ());
    for (const RimEdge& r : rim) {
        for (size_t i = 0; i < r.at.size(); ++i) {
            if (r.leads[i].Magnitude() > 0.5 && r.tangents[i].Crossed(r.leads[i]).Dot(up) < -std::sin(LEAN_OUT)) {
                return true;
            }
        }
    }
    return false;
}

/// Why a patch face over loop is wrong (size: the loop's), or "" when it isn't. It is judged on a
/// grid over the face, finer in a band along its boundary (across every knot span of its surface
/// there), at the boundary of a face trimmed from a bigger surface, and wherever its normals turn
/// fast; and at points along its G1 edges no further apart than its gap. It creases (neighbouring
/// normals face apart); it runs back down along a G1 face instead of carrying the face on, or
/// leaves its boundary going down where the face rises up to it (dips below it; bare, a cap with no
/// points or rails over a flat loop, may not reach below the loop at all), near a corner too, where
/// it turns off the face; or it passes out beyond the plane of the G1 face at its nearest point of
/// the loop (curling out over its walls: folding over, when it also faces back down further than its
/// faces lean that way; else bulging out past them). Facing back down within its faces is no fault (a
/// strip of a cylinder bent round past a half turn, a corner of a cap leaning over); shape, when
/// given, gets how far it faces back down past its faces' lean. rim: the loop's edges (see rim_of),
/// their points no further apart than the gap the patch may stray outside its faces' planes by (a
/// 500th of its size): the nearest of them lies on the edge whose nearest point is nearest, or on
/// one about as near.
std::string cap_problem(const TopoDS_Face& face, const std::vector<LoopEdge>& loop, const std::vector<RimEdge>& rim, double size, bool bare,
    CapShape* shape = nullptr)
{
    const gp_XYZ newell = loop_normal(loop);
    if (newell.Modulus() < 1e-300) {
        return "";
    }
    const gp_Vec up(gp_Dir(newell).XYZ());
    const double gap = 2e-3 * size;
    const double slack = std::sin(MAX_PATCH_ANGLE);
    // How far the G1 faces lean back down (floor: the least a patch carrying them on leans up, see
    // sag), and which way they rise to the loop (rise: up, down, or 0 lying across it).
    double floor = 0.0;
    double rising = 0.0;
    int leading = 0;
    for (const RimEdge& r : rim) {
        for (size_t i = 0; i < r.at.size(); ++i) {
            if (r.leads[i].Magnitude() > 0.5) {
                floor = std::min(floor, r.tangents[i].Crossed(r.leads[i]).Dot(up));
                rising += r.leads[i].Dot(up);
                ++leading;
            }
        }
    }
    const bool tangent_any = leading > 0;
    const double rise = rising > 0.1 * leading ? 1.0 : rising < -0.1 * leading ? -1.0 : 0.0;
    double u1 = 0.0, u2 = 0.0, v1 = 0.0, v2 = 0.0;
    BRepTools::UVBounds(face, u1, u2, v1, v2);
    BRepAdaptor_Surface surface(face, false);
    BRepTopAdaptor_FClass2d inside(face, Precision::PConfusion());
    const bool whole = fills_surface(face);
    struct Sample
    {
        gp_Pnt point;
        gp_Vec normal;
        gp_Pnt2d uv;
        bool in = false;
    };
    auto sample_at = [&](double u, double v) {
        Sample s;
        s.uv.SetCoord(u, v);
        if (!whole && inside.Perform(gp_Pnt2d(u, v)) == TopAbs_OUT) {
            return s;
        }
        gp_Vec du;
        gp_Vec dv;
        surface.D1(u, v, s.point, du, dv);
        gp_Vec normal = du.Crossed(dv);
        if (face.Orientation() == TopAbs_REVERSED) {
            normal.Reverse();
        }
        // (On a collapsed side, a lens's end, the limit from inside.)
        const bool collapsed = normal.Magnitude() <= 1e-6 * std::max(du.SquareMagnitude(), dv.SquareMagnitude());
        s.normal = collapsed ? normal_at(face, u, v) : normal.Normalized();
        s.in = true;
        return s;
    };
    auto apart = [](const Sample& a, const Sample& b) { return a.in && b.in && a.normal.Dot(b.normal) < 0.0; };
    auto turns = [](const Sample& a, const Sample& b, const Sample& c, const Sample& d) {
        const std::array<const Sample*, 4> corners = {&a, &b, &c, &d};
        for (int i = 0; i < 4; ++i) {
            for (int j = i + 1; j < 4; ++j) {
                if (corners[i]->in && corners[j]->in && corners[i]->normal.Dot(corners[j]->normal) < std::cos(M_PI / 6.0)) {
                    return true;
                }
            }
        }
        return false;
    };
    // Every sample inside the face, for the tests after the creases.
    std::vector<Sample> kept;
    // Samples on the grid of us by vs, kept; false when neighbours face apart (a crease).
    auto block = [&](const std::vector<double>& us, const std::vector<double>& vs, std::vector<Sample>& made) {
        made.assign(us.size() * vs.size(), Sample());
        for (size_t i = 0; i < us.size(); ++i) {
            for (size_t j = 0; j < vs.size(); ++j) {
                made[i * vs.size() + j] = sample_at(us[i], vs[j]);
            }
        }
        for (size_t i = 0; i < us.size(); ++i) {
            for (size_t j = 0; j < vs.size(); ++j) {
                const Sample& here = made[i * vs.size() + j];
                if ((i + 1 < us.size() && apart(here, made[(i + 1) * vs.size() + j])) || (j + 1 < vs.size() && apart(here, made[i * vs.size() + j + 1]))) {
                    return false;
                }
                if (here.in) {
                    kept.push_back(here);
                }
            }
        }
        return true;
    };
    auto even = [](double lo, double hi, int count) {
        std::vector<double> values;
        for (int i = 0; i <= count; ++i) {
            values.push_back(lo + (hi - lo) * i / count);
        }
        return values;
    };
    // A cell split 4 x 4, and again (twice at most) where its normals still turn fast.
    std::function<bool(double, double, double, double, int)> finer = [&](double a1, double a2, double b1, double b2, int depth) {
        std::vector<Sample> made;
        const std::vector<double> us = even(a1, a2, 4);
        const std::vector<double> vs = even(b1, b2, 4);
        if (!block(us, vs, made)) {
            return false;
        }
        for (size_t i = 0; i < 4 && depth > 0; ++i) {
            for (size_t j = 0; j < 4; ++j) {
                if (turns(made[i * 5 + j], made[(i + 1) * 5 + j], made[i * 5 + j + 1], made[(i + 1) * 5 + j + 1]) && !finer(us[i], us[i + 1], vs[j], vs[j + 1], depth - 1)) {
                    return false;
                }
            }
        }
        return true;
    };
    constexpr int GRID = 48;
    const std::vector<double> us = even(u1, u2, GRID);
    const std::vector<double> vs = even(v1, v2, GRID);
    std::vector<Sample> grid;
    // (Said of how far this patch can follow its boundary, not of every surface: a smooth tangent
    // cap can exist where this one folds, over a side bowed in gently.)
    const std::string fold = tangent_any ? "The patch would fold over itself (it can't follow its boundary where the boundary bends in that far and stay tangent); try G0, or patch the area in pieces"
                                         : "The patch would fold over itself (it can't follow its boundary where the boundary bends in that far); patch the area in pieces";
    auto creases = [&]() {
        if (shape != nullptr) {
            shape->creased = true;
        }
        return fold;
    };
    if (!block(us, vs, grid)) {
        return creases();
    }
    gp_Vec total;
    for (const Sample& s : grid) {
        total += s.in ? s.normal : gp_Vec();
    }
    if (total.Magnitude() < 1e-300) {
        return "";
    }
    for (size_t i = 0; i < size_t(GRID); ++i) {
        for (size_t j = 0; j < size_t(GRID); ++j) {
            const Sample& a = grid[i * (GRID + 1) + j];
            const Sample& b = grid[(i + 1) * (GRID + 1) + j];
            const Sample& c = grid[i * (GRID + 1) + j + 1];
            const Sample& d = grid[(i + 1) * (GRID + 1) + j + 1];
            // A trimmed face's boundary runs through the cells it leaves some corners of.
            const int in = int(a.in) + int(b.in) + int(c.in) + int(d.in);
            const bool edge = !whole && in > 0 && in < 4;
            if ((edge || (in == 4 && turns(a, b, c, d))) && !finer(us[i], us[i + 1], vs[j], vs[j + 1], edge ? 0 : 2)) {
                return creases();
            }
        }
    }
    if (whole) {
        // A band a cell deep along each side, across every knot span along it.
        std::vector<Sample> made;
        const double du = (u2 - u1) / GRID;
        const double dv = (v2 - v1) / GRID;
        const std::vector<double> along_u = band_values(surface, true, u1, u2, GRID);
        const std::vector<double> along_v = band_values(surface, false, v1, v2, GRID);
        if (!block(along_u, even(v1, v1 + dv, 4), made) || !block(along_u, even(v2 - dv, v2, 4), made) || !block(even(u1, u1 + du, 4), along_v, made)
            || !block(even(u2 - du, u2, 4), along_v, made)) {
            return creases();
        }
    }
    // Which way the patch faces up: along its G1 edges as the faces it carries on lean there (the
    // loop's way crossed with the way it leaves them, see floor); only without them by the sum of
    // its normals (which over walls leaning out, a cap like a mushroom's, faces down).
    Handle(ShapeAnalysis_Surface) facing_on = new ShapeAnalysis_Surface(BRep_Tool::Surface(face));
    double facing = 0.0;
    for (const RimEdge& r : rim) {
        const size_t n = r.at.size();
        for (size_t i = n / 16; !r.support.IsNull() && i < n; i += std::max<size_t>(1, n / 8)) {
            if (r.leads[i].Magnitude() > 0.5) {
                const gp_Pnt2d uv = facing_on->ValueOfUV(r.points[i], 1e-3 * gap);
                facing += normal_at(face, uv.X(), uv.Y()).Dot(r.tangents[i].Crossed(r.leads[i]));
            }
        }
    }
    const double way = facing != 0.0 ? (facing > 0.0 ? 1.0 : -1.0) : total.Dot(up) >= 0.0 ? 1.0 : -1.0;
    double sunk = 0.0;
    gp_Pnt sunk_at;
    for (const Sample& s : kept) {
        const double drop = floor - way * s.normal.Dot(up);
        if (drop > sunk) {
            sunk = drop;
            sunk_at = s.point;
        }
    }
    const bool facing_down = sunk > slack;
    if (shape != nullptr) {
        shape->sag = sunk;
        shape->sag_at = sunk_at;
    }
    // Along the G1 edges (a corner's own point lies on two faces: inside them only), the way the
    // patch leaves: never back along the face, nor down where the face rises up to the loop.
    Handle(ShapeAnalysis_Surface) on = new ShapeAnalysis_Surface(BRep_Tool::Surface(face));
    const double step = 1e-3 * size;
    const double rises = std::sin(5.0 * M_PI / 180.0);
    auto wrong_way = [&](const char* why) {
        if (shape != nullptr) {
            shape->wrong_way = true;
        }
        return std::string(why);
    };
    const char* dips = "The patch would dip below its edges instead of rising off those faces; try G0, or patch the area in pieces";
    auto in_face = [&](double u, double v) { return whole ? u > u1 && u < u2 && v > v1 && v < v2 : inside.Perform(gp_Pnt2d(u, v)) == TopAbs_IN; };
    for (const RimEdge& r : rim) {
        bool placed = false;
        gp_Pnt2d uv;
        // (Closer together within a tenth of the edge from its ends, where a corner turns the patch.)
        const size_t n = r.at.size();
        const size_t middle = std::max<size_t>(1, n / 40);
        const size_t ends = std::max<size_t>(1, n / 200);
        for (size_t i = 1; !r.support.IsNull() && i + 1 < n; i += (i < n / 10 || i > n - n / 10) ? ends : middle) {
            gp_Vec normal;
            gp_Vec into;
            if (r.leads[i].Magnitude() < 0.5 || !leaves(face, *on, surface, in_face, r.points[i], r.tangents[i], step, uv, placed, normal, into)) {
                continue;
            }
            // (Within RUN_BACK of straight back along the face: a corner turning flat inward off
            // walls leaning out leaves at a wide angle to them, carrying no face on, but not back.)
            if (into.Dot(r.leads[i]) < -std::cos(RUN_BACK)) {
                return wrong_way(floor < -slack ? "The patch would run back down along those faces instead of carrying them on (they lean out too far for it); try G0"
                                                : "The patch would run back down along those faces instead of carrying them on; try G0, or patch the area in pieces");
            }
            if (rise != 0.0 && rise * r.leads[i].Dot(up) > rises && rise * into.Dot(up) < -slack) {
                return wrong_way(dips);
            }
        }
    }
    if (bare && rise != 0.0) {
        // Over a flat loop it rises off the faces' side of it everywhere.
        gp_XYZ middle;
        size_t count = 0;
        for (const RimEdge& r : rim) {
            for (const gp_Pnt& p : r.points) {
                middle += p.XYZ();
                ++count;
            }
        }
        middle /= double(std::max<size_t>(count, 1));
        double off_plane = 0.0;
        for (const RimEdge& r : rim) {
            for (const gp_Pnt& p : r.points) {
                off_plane = std::max(off_plane, std::abs((p.XYZ() - middle).Dot(up.XYZ())));
            }
        }
        for (size_t k = 0; off_plane <= gap && k < kept.size(); ++k) {
            if (rise * (kept[k].point.XYZ() - middle).Dot(up.XYZ()) < -gap) {
                return wrong_way(dips);
            }
        }
    }
    // The faces may lean the patch out over the loop, but not past their planes: each point stays on
    // the inside of the plane of the G1 face at its nearest point of the loop (of the faces meeting
    // where that is a corner, any one's; a G0 edge, or a face lying across the loop, has no inside).
    // The points are searched in runs of 32, each in its box.
    struct Run
    {
        size_t edge;
        size_t from;
        size_t to;
        gp_XYZ lo;
        gp_XYZ hi;
    };
    std::vector<Run> runs;
    for (size_t k = 0; k < rim.size(); ++k) {
        for (size_t from = 0; from < rim[k].points.size(); from += 32) {
            Run run{k, from, std::min(from + 32, rim[k].points.size()), rim[k].points[from].XYZ(), rim[k].points[from].XYZ()};
            for (size_t i = from; i < run.to; ++i) {
                const gp_XYZ& p = rim[k].points[i].XYZ();
                run.lo.SetCoord(std::min(run.lo.X(), p.X()), std::min(run.lo.Y(), p.Y()), std::min(run.lo.Z(), p.Z()));
                run.hi.SetCoord(std::max(run.hi.X(), p.X()), std::max(run.hi.Y(), p.Y()), std::max(run.hi.Z(), p.Z()));
            }
            runs.push_back(run);
        }
    }
    auto box_gap = [](const Run& run, const gp_XYZ& p) {
        const double x = std::max({run.lo.X() - p.X(), 0.0, p.X() - run.hi.X()});
        const double y = std::max({run.lo.Y() - p.Y(), 0.0, p.Y() - run.hi.Y()});
        const double z = std::max({run.lo.Z() - p.Z(), 0.0, p.Z() - run.hi.Z()});
        return std::sqrt(x * x + y * y + z * z);
    };
    // How far point lies inside the plane of rim edge k's face at its parameter t (point q there);
    // none when the edge has no inside there.
    auto inside_by = [&](size_t k, double t, const gp_Pnt& q, const gp_Pnt& point) -> std::optional<double> {
        const gp_Vec lead = rim_frame(rim[k], t, q).second;
        if (lead.Magnitude() < 0.5) {
            return std::nullopt;
        }
        const gp_Vec inward = up.Crossed(rim_tangent(rim[k], t));
        const gp_Vec in = inward - lead * inward.Dot(lead);
        if (in.Magnitude() <= 0.25) {
            return std::nullopt;
        }
        return gp_Vec(q, point).Dot(in.Normalized());
    };
    std::vector<double> edge_best(rim.size());
    std::vector<size_t> edge_at(rim.size());
    // How far point lies inside the planes of the faces at its nearest point of the loop: inside any
    // one of a corner's (what it is held to), and inside all of them (how far out it passes is told
    // from that); 1e300 well inside, not measured.
    auto inner_of = [&](const gp_Pnt& point) -> std::pair<double, double> {
        const gp_XYZ& p = point.XYZ();
        std::fill(edge_best.begin(), edge_best.end(), 1e300);
        double best = 1e300;
        for (const Run& run : runs) {
            if (box_gap(run, p) > best + gap) {
                continue;
            }
            for (size_t i = run.from; i < run.to; ++i) {
                const double d = rim[run.edge].points[i].XYZ().Subtracted(p).Modulus();
                if (d < edge_best[run.edge]) {
                    edge_best[run.edge] = d;
                    edge_at[run.edge] = i;
                }
                best = std::min(best, d);
            }
        }
        // A point well inside the plane at its nearest point is inside it (between the points the
        // plane turns by a tenth of a radian at most, unless the edge bends round in under a 50th
        // of the size): only nearer calls are measured exactly.
        size_t first = 0;
        for (size_t k = 0; k < rim.size(); ++k) {
            first = edge_best[k] < edge_best[first] ? k : first;
        }
        const RimEdge& near = rim[first];
        const size_t ni = edge_at[first];
        if (near.leads[ni].Magnitude() > 0.5) {
            const gp_Vec inward = up.Crossed(near.tangents[ni]);
            const gp_Vec in = inward - near.leads[ni] * inward.Dot(near.leads[ni]);
            const gp_Vec off(near.points[ni], point);
            if (in.Magnitude() > 0.25 && off.Dot(in.Normalized()) > 0.3 * off.Magnitude() + 0.5 * gap) {
                return {1e300, 1e300};
            }
        }
        else if (best > 4.0 * gap) {
            return {1e300, 1e300};
        }
        // The nearest point of each edge about as near, exactly; outside only when outside the
        // planes of all as near as the nearest (a corner's two faces). How far out it passes is
        // told by the planes of the edges up to twice as far (beside a corner, the other face's).
        std::vector<std::pair<double, std::optional<double>>> found;
        double nearest = 1e300;
        for (size_t k = 0; k < rim.size(); ++k) {
            if (edge_best[k] > 2.0 * best + gap) {
                continue;
            }
            const auto [t, d] = rim_nearest(rim[k], edge_at[k], point);
            found.push_back({d, inside_by(k, t, rim[k].curve->Value(t), point)});
            nearest = std::min(nearest, d);
        }
        double inner = -1e300;
        double all = 1e300;
        for (const auto& [d, by] : found) {
            if (d <= nearest + 1e-9 * size) {
                inner = std::max(inner, by.value_or(1e300));
            }
            if (d <= 2.0 * nearest + gap) {
                all = std::min(all, by.value_or(1e300));
            }
        }
        return {inner, all};
    };
    const char* bulge = "The patch would bulge out past the faces round it; try G0, or patch the area in pieces";
    // The points found outside, the farthest out first, are looked at again on finer grids round
    // them (twice, each a sixth of the last): how far out the patch passes is told from them.
    std::vector<std::pair<double, gp_Pnt2d>> out;
    for (const Sample& s : kept) {
        const auto [inner, all] = inner_of(s.point);
        if (inner < -gap) {
            return facing_down ? fold : bulge;
        }
        if (all < 0.0) {
            out.push_back({all, s.uv});
        }
    }
    std::sort(out.begin(), out.end(), [](const auto& a, const auto& b) { return a.first < b.first; });
    out.resize(std::min<size_t>(out.size(), 6));
    double outside = out.empty() ? 0.0 : -out.front().first;
    for (const auto& [inner, uv] : out) {
        gp_Pnt2d at = uv;
        double step_u = (u2 - u1) / GRID;
        double step_v = (v2 - v1) / GRID;
        for (int level = 0; level < 2; ++level) {
            gp_Pnt2d best_uv = at;
            double best = 1e300;
            for (int i = -3; i <= 3; ++i) {
                for (int j = -3; j <= 3; ++j) {
                    const double u = std::clamp(at.X() + step_u * i / 3.0, u1, u2);
                    const double v = std::clamp(at.Y() + step_v * j / 3.0, v1, v2);
                    if (!whole && inside.Perform(gp_Pnt2d(u, v)) == TopAbs_OUT) {
                        continue;
                    }
                    const auto [inner, all] = inner_of(surface.Value(u, v));
                    if (inner < -gap) {
                        return facing_down ? fold : bulge;
                    }
                    if (all < best) {
                        best = all;
                        best_uv.SetCoord(u, v);
                    }
                }
            }
            outside = std::max(outside, best < 0.0 ? -best : 0.0);
            at = best_uv;
            step_u /= 6.0;
            step_v /= 6.0;
        }
    }
    if (shape != nullptr) {
        shape->outside = outside;
    }
    return "";
}

/// How far a patch falls short of tangency along its G1 edges, at 40 points along each (by
/// length) and more toward its ends (down to a millionth of it): the share of their length along
/// which it is within a degree of tangent, the most it turns off them (radians), and whether every
/// point off lies near a corner of the loop (within 30 % of its side of one).
struct Shortfall
{
    double share = 1.0;
    double worst = 0.0;
    bool cornered = true;
};

Shortfall tangency_shortfall(const TopoDS_Face& face, const std::vector<LoopEdge>& loop, const std::vector<PatchEdge>& constraints, double size)
{
    Shortfall result;
    std::vector<double> starts;
    double total = 0.0;
    for (const LoopEdge& e : loop) {
        starts.push_back(total);
        total += e.length;
    }
    std::vector<double> corners;
    for (size_t k = 0; k < loop.size(); ++k) {
        if (turn(loop[(k + loop.size() - 1) % loop.size()].edge, loop[k].edge) > SMOOTH_TURN) {
            corners.push_back(starts[k]);
        }
    }
    auto near_corner = [&](double at) {
        for (size_t c = 0; c < corners.size(); ++c) {
            const double from = corners[c];
            const double to = c + 1 < corners.size() ? corners[c + 1] : corners[0] + total;
            const double x = at < from ? at + total : at;
            if (x >= from && x <= to) {
                return std::min(x - from, to - x) <= 0.3 * (to - from);
            }
        }
        return false;
    };
    const std::vector<RimEdge> rim = rim_of(loop, constraints, 1e300);
    Handle(ShapeAnalysis_Surface) on = new ShapeAnalysis_Surface(BRep_Tool::Surface(face));
    const BRepAdaptor_Surface surface(face, false);
    double tangent_length = 0.0;
    double length = 0.0;
    for (size_t k = 0; k < rim.size(); ++k) {
        const RimEdge& r = rim[k];
        if (r.support.IsNull()) {
            continue;
        }
        // (40 even points weigh the share; more toward the ends, where a corner can turn the patch
        // off its faces over less than one of their steps, tell how far it turns.)
        std::vector<std::pair<double, double>> samples;
        for (int i = 0; i < 40; ++i) {
            samples.push_back({(i + 0.5) / 40.0 * r.length, r.length / 40.0});
        }
        for (const double end : {1e-6, 1e-5, 3e-5, 1e-4, 3e-4, 1e-3, 4e-3, 1e-2}) {
            samples.push_back({end * r.length, 0.0});
            samples.push_back({(1.0 - end) * r.length, 0.0});
        }
        std::sort(samples.begin(), samples.end());
        // Each point is settled from its neighbour's place (see leaves), from the middle out to
        // each end: at a lens patch's collapsed end the place a projection finds can lie anywhere
        // along the collapsed side, where the normal is a different limit.
        const size_t middle = samples.size() / 2;
        gp_Pnt2d from_middle;
        for (const bool ahead : {true, false}) {
            gp_Pnt2d uv = from_middle;
            bool placed = !ahead;
            for (size_t j = ahead ? middle : middle - 1; j < samples.size(); j = ahead ? j + 1 : j - 1) {
                const auto [s, weight] = samples[j];
                const double t = loop_param(loop[k], s);
                const gp_Pnt point = r.curve->Value(t);
                double gap = 1e300;
                if (placed) {
                    std::tie(uv, gap) = settle(surface, point, uv);
                }
                if (gap > 1e-6 * size) {
                    uv = on->ValueOfUV(point, 1e-6 * size);
                }
                placed = true;
                if (j == middle) {
                    from_middle = uv;
                }
                const double angle = std::acos(std::min(1.0, std::abs(normal_at(face, uv.X(), uv.Y()).Dot(rim_frame(r, t, point).first))));
                length += weight;
                if (angle <= M_PI / 180.0) {
                    tangent_length += weight;
                    continue;
                }
                result.worst = std::max(result.worst, angle);
                result.cornered = result.cornered && near_corner(starts[k] + s);
            }
        }
    }
    result.share = length > 0.0 ? tangent_length / length : 1.0;
    return result;
}

/// True for an edge bounding one face only (not a seam, nor a degenerated edge).
bool open_edge(const Shape& shape, const TopoDS_Edge& edge)
{
    const std::vector<TopoDS_Face> faces = faces_of_edge(shape, edge);
    return faces.size() == 1 && !BRep_Tool::IsClosed(edge, faces[0]) && !BRep_Tool::Degenerated(edge);
}

/// The edges (ids) with every open edge that runs on smoothly from them (within SMOOTH_TURN),
/// through one vertex after another.
std::vector<int> chained(const Shape& shape, const std::vector<int>& ids)
{
    const TopTools_IndexedMapOfShape& edges = shape->edge_map();
    TopTools_IndexedDataMapOfShapeListOfShape vertex_edges;
    TopExp::MapShapesAndAncestors(shape->get_occ_shape(), TopAbs_VERTEX, TopAbs_EDGE, vertex_edges);
    // The direction an edge leaves a vertex in.
    auto leaving = [](const TopoDS_Edge& edge, const TopoDS_Vertex& vertex) {
        BRepAdaptor_Curve curve(edge);
        const gp_Pnt at = BRep_Tool::Pnt(vertex);
        const bool from_start = curve.Value(curve.FirstParameter()).SquareDistance(at) <= curve.Value(curve.LastParameter()).SquareDistance(at);
        gp_Pnt point;
        gp_Vec tangent;
        curve.D1(from_start ? curve.FirstParameter() : curve.LastParameter(), point, tangent);
        return from_start ? tangent : tangent.Reversed();
    };
    std::vector<int> result = ids;
    TopTools_MapOfShape seen;
    for (int id : ids) {
        seen.Add(edges(id + 1));
    }
    for (size_t k = 0; k < result.size(); ++k) {
        const TopoDS_Edge edge = TopoDS::Edge(edges(result[k] + 1));
        for (TopExp_Explorer v(edge, TopAbs_VERTEX); v.More(); v.Next()) {
            const TopoDS_Vertex& vertex = TopoDS::Vertex(v.Current());
            const int index = vertex_edges.FindIndex(vertex);
            const gp_Vec out = leaving(edge, vertex);
            if (index <= 0 || out.Magnitude() < 1e-12) {
                continue;
            }
            for (TopTools_ListOfShape::Iterator it(vertex_edges(index)); it.More(); it.Next()) {
                const TopoDS_Edge& next = TopoDS::Edge(it.Value());
                if (seen.Contains(next) || !open_edge(shape, next)) {
                    continue;
                }
                const gp_Vec on = leaving(next, vertex);
                if (on.Magnitude() > 1e-12 && out.Angle(on.Reversed()) <= SMOOTH_TURN) {
                    seen.Add(next);
                    result.push_back(edges.FindIndex(next) - 1);
                }
            }
        }
    }
    return result;
}

/// How far along the profile of grown (a surface of revolution) past an edge on a side of its box
/// along the profile (see iso_side) the profile reaches the axis; negative when it doesn't within
/// grown.
double profile_to_axis(const TopoDS_Face& grown, const TopoDS_Edge& edge, int side)
{
    Handle(Geom_Surface) carried = BRep_Tool::Surface(grown);
    for (Handle(Geom_RectangularTrimmedSurface) trimmed = Handle(Geom_RectangularTrimmedSurface)::DownCast(carried); !trimmed.IsNull();
        trimmed = Handle(Geom_RectangularTrimmedSurface)::DownCast(carried)) {
        carried = trimmed->BasisSurface();
    }
    const Handle(Geom_SurfaceOfRevolution) turned = Handle(Geom_SurfaceOfRevolution)::DownCast(carried);
    if (turned.IsNull()) {
        return -1.0;
    }
    BRepAdaptor_Curve curve(edge);
    GeomAPI_ProjectPointOnSurf on(curve.Value(0.5 * (curve.FirstParameter() + curve.LastParameter())), turned, PROJECTION_TOLERANCE);
    if (on.NbPoints() == 0) {
        return -1.0;
    }
    double u = 0.0;
    double v = 0.0;
    on.LowerDistanceParameters(u, v);
    double far[4] = {0.0, 0.0, 0.0, 0.0};
    BRepTools::UVBounds(grown, far[0], far[1], far[2], far[3]);
    const Handle(Geom_Curve) profile = turned->BasisCurve();
    const gp_Ax1 axis = turned->Axis();
    const gp_Vec along(axis.Direction());
    // The profile's way out from the axis, and how far out it is that way.
    auto radial = [&](double t) {
        const gp_Vec r(axis.Location(), profile->Value(t));
        return r - along * r.Dot(along);
    };
    const gp_Vec start = radial(v);
    if (start.Magnitude() < Precision::Confusion()) {
        return 0.0;
    }
    const gp_Vec out = start.Normalized();
    auto off_axis = [&](double t) { return radial(t).Dot(out) > start.Magnitude() * 1e-9; };
    const int steps = 256;
    double good = v;
    for (int k = 1; k <= steps; ++k) {
        const double t = v + (far[side] - v) * k / steps;
        if (off_axis(t)) {
            good = t;
            continue;
        }
        double bad = t;
        for (int i = 0; i < 60; ++i) {
            const double mid = 0.5 * (good + bad);
            (off_axis(mid) ? good : bad) = mid;
        }
        return GCPnts_AbscissaPoint::Length(GeomAdaptor_Curve(profile), std::min(v, good), std::max(v, good));
    }
    return -1.0;
}

/// How far past an edge on a side of its face's UV box (see iso_side) the face's surface carries
/// on before it comes to a point (a cone's apex, a sphere's pole, a revolved profile reaching its
/// axis) or folds over; negative when it doesn't within grown (the face carried on past the edge).
/// what names the point.
double point_ahead(const TopoDS_Face& face, const TopoDS_Face& grown, const TopoDS_Edge& edge, int side, std::string& what)
{
    BRepAdaptor_Surface surface(face);
    double bounds[4] = {0.0, 0.0, 0.0, 0.0};
    BRepTools::UVBounds(face, bounds[0], bounds[1], bounds[2], bounds[3]);
    const double toward = side == 0 || side == 2 ? -1.0 : 1.0;
    switch (surface.GetType()) {
        case GeomAbs_Plane:
        case GeomAbs_Cylinder:
            return -1.0;
        case GeomAbs_Cone: {
            // v runs along the cone's lines, from its reference circle; the apex is where the
            // radius R + v sin(angle) runs out.
            const gp_Cone cone = surface.Cone();
            what = "the cone's apex";
            const double ahead = toward * (-cone.RefRadius() / std::sin(cone.SemiAngle()) - bounds[side]);
            return side >= 2 && ahead > 0.0 ? ahead : -1.0;
        }
        case GeomAbs_Sphere:
            what = "the sphere's pole";
            return side >= 2 ? surface.Sphere().Radius() * (M_PI / 2.0 - toward * bounds[side]) : -1.0;
        case GeomAbs_SurfaceOfRevolution:
            what = "the point where the surface meets its axis";
            return side >= 2 ? profile_to_axis(grown, edge, side) : -1.0;
        default:
            break;
    }
    what = surface.GetType() == GeomAbs_Torus ? "the point where the surface meets its axis" : "a fold in the surface";
    // Elsewhere: along the grown surface from the edge's middle out to its far side, until its
    // normal vanishes or turns over.
    BRepAdaptor_Curve curve(edge);
    const Handle(Geom_Surface) carried = BRep_Tool::Surface(grown);
    GeomAPI_ProjectPointOnSurf on(curve.Value(0.5 * (curve.FirstParameter() + curve.LastParameter())), carried, PROJECTION_TOLERANCE);
    if (on.NbPoints() == 0) {
        return -1.0;
    }
    double u = 0.0;
    double v = 0.0;
    on.LowerDistanceParameters(u, v);
    double far[4] = {0.0, 0.0, 0.0, 0.0};
    BRepTools::UVBounds(grown, far[0], far[1], far[2], far[3]);
    const bool in_u = side < 2;
    const double from = in_u ? u : v;
    auto normal = [&](double s, gp_Pnt& point) {
        gp_Vec su;
        gp_Vec sv;
        carried->D1(in_u ? s : u, in_u ? v : s, point, su, sv);
        return su.Crossed(sv);
    };
    gp_Pnt last;
    const gp_Vec start = normal(from, last);
    if (start.Magnitude() < 1e-300) {
        return -1.0;
    }
    auto regular = [&](double s) {
        gp_Pnt point;
        const gp_Vec n = normal(s, point);
        return n.Magnitude() > 1e-6 * start.Magnitude() && n.Dot(start) > 0.0;
    };
    const int steps = 256;
    double length = 0.0;
    double good = from;
    for (int k = 1; k <= steps; ++k) {
        const double s = from + (far[side] - from) * k / steps;
        gp_Pnt point;
        if (!regular(s)) {
            double bad = s;
            for (int i = 0; i < 60; ++i) {
                const double mid = 0.5 * (good + bad);
                (regular(mid) ? good : bad) = mid;
            }
            normal(good, point);
            return length + last.Distance(point);
        }
        normal(s, point);
        length += last.Distance(point);
        last = point;
        good = s;
    }
    return -1.0;
}

/// The point of triangle a, b, c nearest p.
gp_XYZ nearest_in_triangle(const gp_XYZ& p, const gp_XYZ& a, const gp_XYZ& b, const gp_XYZ& c)
{
    const gp_XYZ ab = b - a;
    const gp_XYZ ac = c - a;
    const double d1 = ab.Dot(p - a);
    const double d2 = ac.Dot(p - a);
    if (d1 <= 0.0 && d2 <= 0.0) {
        return a;
    }
    const double d3 = ab.Dot(p - b);
    const double d4 = ac.Dot(p - b);
    if (d3 >= 0.0 && d4 <= d3) {
        return b;
    }
    const double vc = d1 * d4 - d3 * d2;
    if (vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0) {
        return a + ab * (d1 / (d1 - d3));
    }
    const double d5 = ab.Dot(p - c);
    const double d6 = ac.Dot(p - c);
    if (d6 >= 0.0 && d5 <= d6) {
        return c;
    }
    const double vb = d5 * d2 - d1 * d6;
    if (vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0) {
        return a + ac * (d2 / (d2 - d6));
    }
    const double va = d3 * d6 - d5 * d4;
    if (va <= 0.0 && d4 - d3 >= 0.0 && d5 - d6 >= 0.0) {
        return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)));
    }
    const double scale = 1.0 / (va + vb + vc);
    return a + ab * (vb * scale) + ac * (vc * scale);
}

/// The distance from point to a shape's faces measured on their mesh (made with this deflection,
/// then cleared again).
double mesh_gap(const TopoDS_Shape& s, const gp_Pnt& point, double deflection)
{
    BRepMesh_IncrementalMesh mesher(s, deflection, false, 0.1, false);
    double nearest = 1e300;
    for (TopExp_Explorer it(s, TopAbs_FACE); it.More(); it.Next()) {
        TopLoc_Location location;
        const Handle(Poly_Triangulation) mesh = BRep_Tool::Triangulation(TopoDS::Face(it.Current()), location);
        if (mesh.IsNull()) {
            continue;
        }
        const gp_Trsf place = location.Transformation();
        for (int t = 1; t <= mesh->NbTriangles(); ++t) {
            int a = 0;
            int b = 0;
            int c = 0;
            mesh->Triangle(t).Get(a, b, c);
            const gp_XYZ on = nearest_in_triangle(point.XYZ(), mesh->Node(a).Transformed(place).XYZ(), mesh->Node(b).Transformed(place).XYZ(), mesh->Node(c).Transformed(place).XYZ());
            nearest = std::min(nearest, (on - point.XYZ()).Modulus());
        }
    }
    BRepTools::Clean(s);
    return nearest;
}

/// face with the holes (inner wires) of from added, given curves on face's surface where they
/// lack them.
TopoDS_Face with_holes(const TopoDS_Face& face, const TopoDS_Face& from)
{
    const TopoDS_Face forward = TopoDS::Face(from.Oriented(TopAbs_FORWARD));
    const TopoDS_Wire outer = BRepTools::OuterWire(forward);
    BRepBuilderAPI_MakeFace adder(face);
    bool holed = false;
    for (TopExp_Explorer w(forward, TopAbs_WIRE); w.More(); w.Next()) {
        if (w.Current().TShape() != outer.TShape()) {
            adder.Add(TopoDS::Wire(w.Current()));
            holed = true;
        }
    }
    if (!holed) {
        return face;
    }
    ShapeFix_Face fix(adder.Face());
    fix.Perform();
    return fix.Face();
}
}  // namespace

std::vector<std::vector<int>> face_regions(const TopoDS_Shape& owner, const std::vector<TopoDS_Face>& faces, const TopTools_MapOfShape* joining)
{
    TopTools_IndexedMapOfShape index;
    for (const TopoDS_Face& face : faces) {
        index.Add(face);
    }
    std::vector<int> parent(index.Extent());
    std::iota(parent.begin(), parent.end(), 0);
    auto root = [&](int i) {
        while (parent[i] != i) {
            parent[i] = parent[parent[i]];
            i = parent[i];
        }
        return i;
    };
    TopTools_IndexedDataMapOfShapeListOfShape edge_faces;
    TopExp::MapShapesAndAncestors(owner, TopAbs_EDGE, TopAbs_FACE, edge_faces);
    for (int e = 1; e <= edge_faces.Extent(); ++e) {
        if (joining != nullptr && !joining->Contains(edge_faces.FindKey(e))) {
            continue;
        }
        int first = -1;
        for (TopTools_ListOfShape::Iterator it(edge_faces(e)); it.More(); it.Next()) {
            const int k = index.FindIndex(it.Value()) - 1;
            if (k < 0) {
                continue;
            }
            if (first < 0) {
                first = k;
            }
            else {
                parent[root(k)] = root(first);
            }
        }
    }
    // Groups as indices into faces (first appearance), in order of their first face.
    std::map<int, std::vector<int>> by_root;
    std::vector<int> order;
    std::vector<bool> seen(index.Extent(), false);
    for (size_t i = 0; i < faces.size(); ++i) {
        const int k = index.FindIndex(faces[i]) - 1;
        if (k < 0 || seen[k]) {
            continue;
        }
        seen[k] = true;
        const int r = root(k);
        if (by_root.find(r) == by_root.end()) {
            order.push_back(r);
        }
        by_root[r].push_back(int(i));
    }
    std::vector<std::vector<int>> groups;
    for (int r : order) {
        groups.push_back(by_root[r]);
    }
    return groups;
}

TopoDS_Shape assemble_faces(const std::vector<TopoDS_Face>& faces, const std::vector<std::vector<int>>& groups)
{
    // Even a lone face goes in a shell: pieces() tells pieces apart by their shells (two regions
    // of a split surface still share the cut edge).
    BRep_Builder builder;
    std::vector<TopoDS_Shape> parts;
    for (const std::vector<int>& group : groups) {
        TopoDS_Shell shell;
        builder.MakeShell(shell);
        for (int k : group) {
            builder.Add(shell, faces[k]);
        }
        shell.Closed(closed_shell(shell));
        parts.push_back(shell);
    }
    return parts.empty() ? TopoDS_Shape() : compound_of(parts);
}

bool closed_shell(const TopoDS_Shape& shell)
{
    TopTools_IndexedDataMapOfShapeListOfShape edge_faces;
    TopExp::MapShapesAndAncestors(shell, TopAbs_EDGE, TopAbs_FACE, edge_faces);
    if (edge_faces.IsEmpty()) {
        return false;
    }
    for (int i = 1; i <= edge_faces.Extent(); ++i) {
        if (BRep_Tool::Degenerated(TopoDS::Edge(edge_faces.FindKey(i)))) {
            continue;
        }
        if (edge_faces(i).Extent() != 2) {
            return false;
        }
    }
    return true;
}

bool sound(const TopoDS_Shape& s)
{
    if (s.IsNull() || !TopExp_Explorer(s, TopAbs_FACE).More() || !BRepCheck_Analyzer(s).IsValid()) {
        return false;
    }
    // A face whose edges are garbage can pass the topology check: its area and center then come out
    // absurd, far beyond the shape's box.
    Bnd_Box box;
    BRepBndLib::Add(s, box);
    if (box.IsVoid()) {
        return false;
    }
    const double size = std::sqrt(box.SquareExtent());
    GProp_GProps props;
    BRepGProp::SurfaceProperties(s, props);
    const gp_Pnt c = props.CentreOfMass();
    if (!(props.Mass() > 0.0 && props.Mass() < 1e3 * size * size) || !std::isfinite(c.X()) || !std::isfinite(c.Y()) || !std::isfinite(c.Z())) {
        return false;
    }
    box.Enlarge(size);
    return !box.IsOut(c);
}

bool offset_fits(const std::vector<TopoDS_Face>& faces, double distance, String& error)
{
    for (const TopoDS_Face& face : faces) {
        BRepAdaptor_Surface surface(face);
        if (surface.GetType() == GeomAbs_Plane) {
            continue;
        }
        double u1 = 0.0, u2 = 0.0, v1 = 0.0, v2 = 0.0;
        BRepTools::UVBounds(face, u1, u2, v1, v2);
        BRepTopAdaptor_FClass2d inside(face, Precision::PConfusion());
        // (Fine enough to find a G1 patch's tight bends near its corners.)
        const int n = 32;
        for (int i = 0; i < n; ++i) {
            for (int j = 0; j < n; ++j) {
                const gp_Pnt2d uv(u1 + (u2 - u1) * (i + 0.5) / n, v1 + (v2 - v1) * (j + 0.5) / n);
                if (inside.Perform(uv) == TopAbs_OUT) {
                    continue;
                }
                // The principal curvatures toward the face's normal (the way a positive offset
                // goes), from its first and second fundamental forms.
                gp_Pnt point;
                gp_Vec su, sv, suu, svv, suv;
                surface.D2(uv.X(), uv.Y(), point, su, sv, suu, svv, suv);
                const gp_Vec normal = normal_at(face, uv.X(), uv.Y());
                const double e = su.Dot(su), f = su.Dot(sv), g = sv.Dot(sv);
                const double l = suu.Dot(normal), m = suv.Dot(normal), nn = svv.Dot(normal);
                const double det = e * g - f * f;
                if (det < 1e-30) {
                    continue;
                }
                const double mean = (e * nn - 2.0 * f * m + g * l) / (2.0 * det);
                const double gauss = (l * nn - m * m) / det;
                const double spread = std::sqrt(std::max(mean * mean - gauss, 0.0));
                if (distance * (distance > 0.0 ? mean + spread : mean - spread) >= 1.0 - 1e-6) {
                    error = "The surface can't be offset that far (it curves too tightly)";
                    return false;
                }
            }
        }
    }
    return true;
}

bool offset_along(const TopoDS_Shape& source, const TopoDS_Shape& result, double distance)
{
    // (OCCT's simple offset moved a revolved cone against its normal.)
    for (TopExp_Explorer it(source, TopAbs_FACE); it.More(); it.Next()) {
        const TopoDS_Face& face = TopoDS::Face(it.Current());
        double u1 = 0.0, u2 = 0.0, v1 = 0.0, v2 = 0.0;
        BRepTools::UVBounds(face, u1, u2, v1, v2);
        BRepTopAdaptor_FClass2d inside(face, Precision::PConfusion());
        BRepAdaptor_Surface surface(face);
        // The point nearest the middle of the face's box that is on the face (away from the
        // seams, where a joined offset trims its faces).
        const double steps[7] = {0.5, 0.35, 0.65, 0.2, 0.8, 0.05, 0.95};
        bool checked = false;
        for (int i = 0; i < 49 && !checked; ++i) {
            const gp_Pnt2d uv(u1 + (u2 - u1) * steps[i % 7], v1 + (v2 - v1) * steps[i / 7]);
            if (inside.Perform(uv) != TopAbs_IN) {
                continue;
            }
            checked = true;
            const gp_Pnt target = surface.Value(uv.X(), uv.Y()).Translated(normal_at(face, uv.X(), uv.Y()) * distance);
            const double allowed = 0.1 * std::abs(distance) + Precision::Confusion();
            BRepExtrema_DistShapeShape gap(BRepBuilderAPI_MakeVertex(target).Vertex(), result);
            // BRepExtrema misreads the offset of a surface with a collapsed side, as if it weren't
            // there: a simple offset keeps the face's parameters, so its point there is read
            // directly, and failing that the result's mesh is measured (to its deflection).
            if (!gap.IsDone() || gap.Value() > allowed) {
                bool found = false;
                for (TopExp_Explorer f(result, TopAbs_FACE); f.More() && !found; f.Next()) {
                    Handle(Geom_Surface) moved = BRep_Tool::Surface(TopoDS::Face(f.Current()));
                    for (Handle(Geom_RectangularTrimmedSurface) trimmed = Handle(Geom_RectangularTrimmedSurface)::DownCast(moved); !trimmed.IsNull();
                        trimmed = Handle(Geom_RectangularTrimmedSurface)::DownCast(moved)) {
                        moved = trimmed->BasisSurface();
                    }
                    found = moved->IsKind(STANDARD_TYPE(Geom_OffsetSurface)) && moved->Value(uv.X(), uv.Y()).Distance(target) <= allowed;
                }
                const double deflection = std::max({0.05 * std::abs(distance), diagonal(result) * 1e-4, 2.0 * Precision::Confusion()});
                if (!found && mesh_gap(result, target, deflection) > allowed + deflection) {
                    return false;
                }
            }
        }
    }
    return true;
}

namespace
{
/// A face's area and the integrals of its mean and Gaussian curvatures toward its normal (see
/// offset_fits), by the middle points of a grid over the face's box (0 on a plane).
void curvature_integrals(const TopoDS_Face& face, double& whole, double& mean, double& gauss)
{
    whole = std::abs(measure::surface(face).Mass());
    mean = 0.0;
    gauss = 0.0;
    BRepAdaptor_Surface surface(face);
    if (surface.GetType() != GeomAbs_Plane) {
        double u1 = 0.0, u2 = 0.0, v1 = 0.0, v2 = 0.0;
        BRepTools::UVBounds(face, u1, u2, v1, v2);
        BRepTopAdaptor_FClass2d inside(face, Precision::PConfusion());
        const bool whole = fills_surface(face);
        const int n = 48;
        const double du = (u2 - u1) / n;
        const double dv = (v2 - v1) / n;
        for (int i = 0; i < n; ++i) {
            for (int j = 0; j < n; ++j) {
                const gp_Pnt2d uv(u1 + du * (i + 0.5), v1 + dv * (j + 0.5));
                if (!whole && inside.Perform(uv) == TopAbs_OUT) {
                    continue;
                }
                gp_Pnt point;
                gp_Vec su, sv, suu, svv, suv;
                surface.D2(uv.X(), uv.Y(), point, su, sv, suu, svv, suv);
                const gp_Vec normal = normal_at(face, uv.X(), uv.Y());
                const double e = su.Dot(su), f = su.Dot(sv), g = sv.Dot(sv);
                const double l = suu.Dot(normal), m = suv.Dot(normal), nn = svv.Dot(normal);
                const double det = e * g - f * f;
                if (det < 1e-30) {
                    continue;
                }
                const double area = std::sqrt(det) * du * dv;
                mean += (e * nn - 2.0 * f * m + g * l) / (2.0 * det) * area;
                gauss += (l * nn - m * m) / det * area;
            }
        }
    }
}
}  // namespace

double swept_volume(const TopoDS_Face& face, double from, double to)
{
    double whole = 0.0, mean = 0.0, gauss = 0.0;
    curvature_integrals(face, whole, mean, gauss);
    return whole * (to - from) - mean * (to * to - from * from) + gauss * (to * to * to - from * from * from) / 3.0;
}

double offset_area(const TopoDS_Face& face, double distance)
{
    double whole = 0.0, mean = 0.0, gauss = 0.0;
    curvature_integrals(face, whole, mean, gauss);
    return whole - 2.0 * mean * distance + gauss * distance * distance;
}

double seam_change(const TopoDS_Shape& sheet, double distance, bool rounded, double& seams)
{
    seams = 0.0;
    double change = 0.0;
    TopTools_IndexedDataMapOfShapeListOfShape edge_faces;
    TopExp::MapShapesAndAncestors(sheet, TopAbs_EDGE, TopAbs_FACE, edge_faces);
    for (int e = 1; e <= edge_faces.Extent(); ++e) {
        const TopoDS_Edge& edge = TopoDS::Edge(edge_faces.FindKey(e));
        if (edge_faces(e).Extent() < 2 || BRep_Tool::Degenerated(edge)) {
            continue;
        }
        const TopoDS_Face& one = TopoDS::Face(edge_faces(e).First());
        const TopoDS_Face& other = TopoDS::Face(edge_faces(e).Last());
        const double length = measure::length(edge);
        seams += length;
        if (one.IsSame(other)) {
            continue;
        }
        double f1 = 0.0, l1 = 0.0, f2 = 0.0, l2 = 0.0;
        const Handle(Geom2d_Curve) on_one = BRep_Tool::CurveOnSurface(edge, one, f1, l1);
        const Handle(Geom2d_Curve) on_other = BRep_Tool::CurveOnSurface(edge, other, f2, l2);
        if (on_one.IsNull() || on_other.IsNull()) {
            continue;
        }
        // The middles of 16 even pieces of the edge's parameter, each weighted by its length.
        const BRepAdaptor_Curve curve(edge);
        const int n = 16;
        double weight = 0.0;
        double sum = 0.0;
        for (int i = 0; i < n; ++i) {
            const double t = curve.FirstParameter() + (curve.LastParameter() - curve.FirstParameter()) * (i + 0.5) / n;
            gp_Pnt point;
            gp_Vec d1;
            curve.D1(t, point, d1);
            const gp_Pnt2d uv1 = on_one->Value(t);
            const gp_Pnt2d uv2 = on_other->Value(t);
            const gp_Vec n1 = normal_at(one, uv1.X(), uv1.Y());
            const gp_Vec n2 = normal_at(other, uv2.X(), uv2.Y());
            const gp_Vec into = into_face(one, edge, t);
            const double angle = n1.Angle(n2);
            // The other face bends away from the side the sheet moves to (a convex seam there) when
            // its normal points back out of this face.
            const bool convex = n2.Dot(into) * distance < 0.0;
            const double c = convex ? (rounded ? 0.5 * angle : std::tan(0.5 * angle)) : -std::tan(0.5 * angle);
            sum += c * d1.Magnitude();
            weight += d1.Magnitude();
        }
        change += weight > 0.0 ? sum / weight * length : 0.0;
    }
    return change;
}

double work_scale(const std::vector<TopoDS_Face>& faces, double floor, gp_Pnt& middle)
{
    Bnd_Box box;
    double shortest = 1e300;
    for (const TopoDS_Face& face : faces) {
        BRepBndLib::Add(face, box);
        for (TopExp_Explorer it(face, TopAbs_EDGE); it.More(); it.Next()) {
            if (!BRep_Tool::Degenerated(TopoDS::Edge(it.Current()))) {
                shortest = std::min(shortest, measure::length(TopoDS::Edge(it.Current())));
            }
        }
    }
    if (box.IsVoid()) {
        return 1.0;
    }
    middle = gp_Pnt((box.CornerMin().XYZ() + box.CornerMax().XYZ()) * 0.5);
    const double size = std::sqrt(box.SquareExtent());
    if (!(size > 0.0)) {
        return 1.0;
    }
    double factor = size < floor ? floor / size : 1.0;
    if (shortest > 0.0 && shortest < 0.5 * floor) {
        factor = std::max(factor, std::min(0.5 * floor / shortest, 1.0 / size));
    }
    return factor;
}

Shape patch(const Array& boundary, const PackedVector3Array& points, const Dictionary& p, String& error, String& note)
{
    const std::string tag = tag_of(p, "patch");
    bool tangent = false;
    try {
        // The shapes picked are worked on as copies (see detached), one per shape.
        std::map<const CadShape*, Shape> copies;
        auto copy_of = [&](const Shape& source) {
            auto found = copies.find(source.ptr());
            if (found == copies.end()) {
                found = copies.emplace(source.ptr(), detached(source)).first;
            }
            return found->second;
        };
        std::vector<PatchEdge> constraints;
        Bnd_Box box;
        for (int64_t i = 0; i < boundary.size(); ++i) {
            const Dictionary entry = boundary[i];
            Ref<CadShape> source = entry.get("shape", Variant());
            if (!usable(source)) {
                error = "A boundary curve is missing";
                return Shape();
            }
            source = copy_of(source);
            const PackedInt32Array ids = entry.get("edges", PackedInt32Array());
            const int continuity = std::clamp(int(entry.get("continuity", 0)), 0, 2);
            const bool outline = bool(entry.get("outline", false));
            // An edge's own continuity, beside its id in "edges" (the entry's for the rest).
            const PackedInt32Array own = entry.get("edge_continuity", PackedInt32Array());
            std::vector<TopoDS_Edge> edges;
            std::vector<int> orders;
            if (ids.is_empty()) {
                for (int e = 1; e <= source->edge_map().Extent(); ++e) {
                    edges.push_back(TopoDS::Edge(source->edge_map()(e)));
                    orders.push_back(continuity);
                }
            }
            else {
                for (int64_t k = 0; k < ids.size(); ++k) {
                    if (ids[k] >= 0 && ids[k] < source->edge_map().Extent()) {
                        edges.push_back(TopoDS::Edge(source->edge_map()(ids[k] + 1)));
                        orders.push_back(k < own.size() ? std::clamp(int(own[k]), 0, 2) : continuity);
                    }
                }
            }
            for (size_t k = 0; k < edges.size(); ++k) {
                if (BRep_Tool::Degenerated(edges[k])) {
                    continue;
                }
                constraints.push_back({edges[k], source, orders[k], TopoDS_Face(), outline});
                BRepBndLib::AddOptimal(edges[k], box, false, false);
            }
        }
        // Rails: curves inside the patch it runs along.
        std::vector<TopoDS_Edge> rails;
        const Array rail_entries = p.get("rails", Array());
        for (int64_t i = 0; i < rail_entries.size(); ++i) {
            const Dictionary entry = rail_entries[i];
            Ref<CadShape> source = entry.get("shape", Variant());
            if (!usable(source)) {
                error = "A rail curve is missing";
                return Shape();
            }
            source = copy_of(source);
            const PackedInt32Array ids = entry.get("edges", PackedInt32Array());
            for (int e = 1; e <= source->edge_map().Extent(); ++e) {
                const TopoDS_Edge& edge = TopoDS::Edge(source->edge_map()(e));
                if ((ids.is_empty() || ids.has(e - 1)) && !BRep_Tool::Degenerated(edge)) {
                    rails.push_back(edge);
                }
            }
        }
        if (constraints.empty()) {
            error = "Select the curves around the patch";
            return Shape();
        }
        const double size = box.IsVoid() ? 1.0 : std::sqrt(box.SquareExtent());
        const double gap = std::max(size * 1e-6, 1e-7);
        // The boundary must close into one loop.
        Handle(TopTools_HSequenceOfShape) loose = new TopTools_HSequenceOfShape();
        for (const PatchEdge& c : constraints) {
            loose->Append(c.edge);
        }
        Handle(TopTools_HSequenceOfShape) loops = new TopTools_HSequenceOfShape();
        ShapeAnalysis_FreeBounds::ConnectEdgesToWires(loose, gap, false, loops);
        if (loops->Length() != 1) {
            error = "The boundary must be one closed loop of curves";
            return Shape();
        }
        const TopoDS_Wire chain = TopoDS::Wire(loops->Value(1));
        TopoDS_Edge first_edge;
        TopoDS_Edge last_edge;
        for (TopoDS_Iterator it(chain); it.More(); it.Next()) {
            if (first_edge.IsNull()) {
                first_edge = TopoDS::Edge(it.Value());
            }
            last_edge = TopoDS::Edge(it.Value());
        }
        const TopoDS_Vertex start = TopExp::FirstVertex(first_edge, true);
        const TopoDS_Vertex end = TopExp::LastVertex(last_edge, true);
        if (start.IsNull() || end.IsNull() || BRep_Tool::Pnt(start).Distance(BRep_Tool::Pnt(end)) > gap * 10.0) {
            error = "The boundary must be one closed loop of curves";
            return Shape();
        }
        const TopoDS_Wire wire = joined(chain, gap);
        const std::vector<LoopEdge> loop = loop_edges(wire, constraints);
        // What the patch did otherwise than asked, said in note when it is made.
        std::vector<std::string> notes;
        const int dropped = choose_supports(constraints, loop);
        if (dropped > 0) {
            notes.push_back("G1 needs body edges with a face beside them; " + std::to_string(dropped) + (dropped == 1 ? " edge was" : " edges were") + " built G0");
        }
        // Neither construction reaches curvature continuity (G2 is no longer offered; a document
        // that still asks for it along a face gets this, and curves with no face build G0 as above).
        for (const PatchEdge& c : constraints) {
            if (c.continuity > 1) {
                error = "The patch can't match those faces' curvature (the filling only reaches tangency); try G1";
                return Shape();
            }
        }
        auto made = [&](const TopoDS_Face& face, const char* kind) {
            std::string said;
            for (const std::string& line : notes) {
                said += (said.empty() ? "" : "; ") + line;
            }
            note = String::utf8(said.c_str());
            Shape out = CadShape::wrap(face);
            naming::name_result(*out.ptr(), nullptr, {}, tag, {{face, tag + kind}});
            return out;
        };
        bool every = true;
        for (const PatchEdge& c : constraints) {
            tangent = tangent || c.continuity > 0;
            every = every && c.continuity > 0;
        }
        // A G1 patch that falls short of tangency (where two G1 faces meet at a corner no smooth
        // patch carries both on), or faces back down past its faces' lean, says how far.
        auto short_of = [&](const TopoDS_Face& face, const CapShape& cap) {
            if (!tangent) {
                return;
            }
            const Shortfall off = tangency_shortfall(face, loop, constraints, size);
            bool near = false;
            double s = 0.0;
            for (size_t k = 0; k < loop.size(); ++k) {
                if (turn(loop[(k + loop.size() - 1) % loop.size()].edge, loop[k].edge) > SMOOTH_TURN) {
                    near = near || loop_point(loop, s).Distance(cap.sag_at) <= 0.3 * size;
                }
                s += loop[k].length;
            }
            std::string said;
            char text[240];
            if (off.worst > M_PI / 180.0) {
                std::snprintf(text, sizeof(text), "G1 holds along %.0f%% of the %s; %s the patch turns off the faces by up to %.0f deg", std::min(99.0, std::round(off.share * 100.0)),
                    every ? "boundary" : "G1 edges", off.cornered ? "toward the corners" : "in places", off.worst * 180.0 / M_PI);
                said = text;
            }
            if (cap.sag > std::sin(M_PI / 180.0)) {
                const double down = std::asin(std::min(cap.sag, 1.0)) * 180.0 / M_PI;
                if (said.empty()) {
                    std::snprintf(text, sizeof(text), "%s the patch faces down by up to %.0f deg past its G1 faces' lean", near ? "Near a corner" : "In places", down);
                }
                else {
                    std::snprintf(text, sizeof(text), ", and %s it faces down by up to %.0f deg past their lean", near ? "near a corner" : "in places", down);
                }
                said += text;
            }
            if (!said.empty()) {
                notes.push_back(said);
            }
            if (cap.outside > OUTSIDE * size) {
                std::snprintf(text, sizeof(text), "The patch passes out past the planes of its G1 faces by up to %.3f mm", cap.outside * 1000.0);
                notes.push_back(text);
            }
        };
        const bool bare = points.is_empty() && rails.empty();
        if (bare) {
            // A flat loop is filled exactly by its plane (also tangent to G1 faces in that plane).
            BRepBuilderAPI_MakeFace flat(wire, true);
            if (flat.IsDone() && (!tangent || in_plane(constraints, flat.Face()))) {
                ShapeFix_Face fix(flat.Face());
                fix.Perform();
                return made(fix.Face(), ":patch");
            }
        }
        const double tol3d = std::max(size * 1e-5, 1e-7);
        Bnd_Box reach = box;
        for (int64_t i = 0; i < points.size(); ++i) {
            reach.Add(P(points[i]));
        }
        for (const TopoDS_Edge& rail : rails) {
            BRepBndLib::AddOptimal(rail, reach, false, false);
        }
        // A patch that misses its boundary, or flies off wide of it and its points and rails, is
        // refused.
        const std::string beside = bare ? "" : rails.empty() ? " and points (is a point beside the boundary?)"
            : points.is_empty() ? " and rails (is a rail beside the boundary?)" : ", rails and points (is one beside the boundary?)";
        auto strays = [&](const TopoDS_Shape& shape, double boundary_error) {
            const Bnd_Box made_box = measure::box(shape);
            const bool wide = boundary_error > size * 1e-3 || std::sqrt(made_box.SquareExtent()) > 2.0 * std::sqrt(reach.SquareExtent());
            return wide ? "The patch can't pass smoothly through its boundary" + beside : std::string();
        };
        const std::string steep = "The patch can't be made tangent to those faces (they are too steep for it); try G0";
        // Up to four corners: a Coons patch (a lens below three), which fills its own surface (so
        // its natural boundary is the patch's) and leaves G1 edges along their faces by
        // construction; one that would fold over or bulge out is left to the plates below. Its
        // corners take the shortest ramp (see CORNER_RAMPS) that leaves it sound, bending no
        // tighter than TIGHTEST_BEND of its size and facing no way down, else the longest that
        // leaves it sound; at the fastest pace (see PACES) that does, the first's fault told when
        // none does (a crease isn't flattened out: it is told at once).
        bool smooth = false;
        const std::vector<double> ends = bare ? side_ends(loop, smooth) : std::vector<double>();
        // The loop's points for cap_problem (alike for every patch tried).
        std::vector<RimEdge> rim;
        std::string coons_problem;
        std::string coons_error;
        TopoDS_Face kept;
        CapShape kept_cap;
        bool creased = false;
        for (size_t k = 0; kept.IsNull() && coons_error.empty() && !creased && ends.size() >= 2 && ends.size() <= 4 && k < std::size(PACES); ++k) {
            std::string problem;
            for (size_t r = 0; r < std::size(CORNER_RAMPS); ++r) {
                double steepest = 0.0;
                double stray = 0.0;
                bool ramped = false;
                TopoDS_Face face;
                try {
                    face = constrained_patch(loop, ends, smooth, constraints, std::max(size * 1e-7, 1e-12), CORNER_RAMPS[r], PACES[k], ramped, steepest, stray);
                }
                catch (const Standard_Failure&) {
                    // The plate below takes over.
                }
                if (face.IsNull() || !sound(face)) {
                    continue;
                }
                coons_error = strays(face, stray);
                if (coons_error.empty() && steepest > MAX_PATCH_ANGLE) {
                    coons_error = steep;
                }
                if (rim.empty()) {
                    rim = rim_of(loop, constraints, 2e-3 * size);
                }
                CapShape cap;
                problem = coons_error.empty() ? cap_problem(face, loop, rim, size, bare, &cap) : std::string();
                creased = cap.creased;
                if (!coons_error.empty() || !problem.empty()) {
                    if (!ramped) {
                        // (Without corners every ramp makes the same patch.)
                        break;
                    }
                    continue;
                }
                kept = face;
                kept_cap = cap;
                if (!ramped || (cap.sag <= SAG && tightest_bend(face) >= TIGHTEST_BEND * size)) {
                    break;
                }
            }
            if (k == 0) {
                coons_problem = problem;
            }
        }
        if (!kept.IsNull()) {
            short_of(kept, kept_cap);
            return made(kept, ":patch");
        }
        if (!coons_error.empty()) {
            error = String::utf8(coons_error.c_str());
            return Shape();
        }
        // Otherwise (more sides, points or rails, or a Coons patch that can't be built or folds) a
        // plate: a mean plane bent to the constraints, as a face trimmed from a bigger surface.
        // (A plate bent from a Coons cap instead, to rise off steep G1 faces, came out nowhere near
        // tangent to them, so such loops stay refused.) A loop smaller than WORK_SIZE is built
        // scaled up to it and scaled back: OCCT's plate has tolerances of its own, which a small
        // loop comes near (a tent rail on a 3 mm square was missed by more than on a 10 mm one).
        struct Plate
        {
            TopoDS_Face face;
            double boundary_error = 0.0;
            // How near it passes its rails and points.
            double miss = 0.0;
        };
        auto plate = [&](bool tangency) {
            const double scale = size < WORK_SIZE ? WORK_SIZE / size : 1.0;
            const gp_Pnt middle((box.CornerMin().XYZ() + box.CornerMax().XYZ()) * 0.5);
            gp_Trsf grow;
            gp_Trsf shrink;
            if (scale != 1.0) {
                grow.SetScale(middle, scale);
                shrink.SetScale(middle, 1.0 / scale);
            }
            // Everything scaled at once, so edges that meet still share their vertices.
            std::vector<TopoDS_Shape> parts;
            for (const PatchEdge& c : constraints) {
                parts.push_back(tangency && c.continuity > 0 && !c.support.IsNull() ? TopoDS_Shape(c.support) : TopoDS_Shape(c.edge));
            }
            parts.insert(parts.end(), rails.begin(), rails.end());
            std::unique_ptr<BRepBuilderAPI_Transform> moved;
            if (scale != 1.0) {
                moved = std::make_unique<BRepBuilderAPI_Transform>(compound_of(parts), grow, true);
            }
            auto sized = [&](const TopoDS_Shape& s) { return moved ? moved->ModifiedShape(s) : s; };
            BRepOffsetAPI_MakeFilling filling(3, 15, 2, false, 1e-5, std::max(size * scale * 1e-5, 1e-7), 1e-2, 0.1, 8, 9);
            for (const PatchEdge& c : constraints) {
                if (tangency && c.continuity > 0 && !c.support.IsNull()) {
                    filling.Add(TopoDS::Edge(sized(c.edge)), TopoDS::Face(sized(c.support)), GeomAbs_G1, true);
                }
                else {
                    filling.Add(TopoDS::Edge(sized(c.edge)), GeomAbs_C0, true);
                }
            }
            for (const TopoDS_Edge& rail : rails) {
                filling.Add(TopoDS::Edge(sized(rail)), GeomAbs_C0, false);
            }
            for (int64_t i = 0; i < points.size(); ++i) {
                filling.Add(P(points[i]).Transformed(grow));
            }
            filling.Build();
            Plate made_plate;
            if (!filling.IsDone() || filling.Shape().IsNull() || !TopExp_Explorer(filling.Shape(), TopAbs_FACE).More()) {
                return made_plate;
            }
            // How far it lies from its boundary, rails and points is measured at the size it was
            // built (OCCT's distances to a face read a sub-millimetre one wrong).
            const TopoDS_Face built_face = TopoDS::Face(TopExp_Explorer(filling.Shape(), TopAbs_FACE).Current());
            // With rails, the error along the boundary alone (OCCT's per-constraint error writes past
            // its own array once a curve has been sampled more finely), by ShapeAnalysis_Surface: a
            // plain projection can find no point near the surface's edge.
            made_plate.boundary_error = rails.empty() ? filling.G0Error() : 0.0;
            if (!rails.empty()) {
                Handle(ShapeAnalysis_Surface) on = new ShapeAnalysis_Surface(BRep_Tool::Surface(built_face));
                for (const PatchEdge& c : constraints) {
                    BRepAdaptor_Curve curve(TopoDS::Edge(sized(c.edge)));
                    for (int i = 0; i <= 16; ++i) {
                        on->ValueOfUV(curve.Value(curve.FirstParameter() + (curve.LastParameter() - curve.FirstParameter()) * i / 16.0), tol3d * scale);
                        made_plate.boundary_error = std::max(made_plate.boundary_error, on->Gap());
                    }
                }
            }
            for (const TopoDS_Edge& rail : rails) {
                BRepAdaptor_Curve curve(TopoDS::Edge(sized(rail)));
                for (int i = 0; i <= 16; ++i) {
                    const gp_Pnt point = curve.Value(curve.FirstParameter() + (curve.LastParameter() - curve.FirstParameter()) * i / 16.0);
                    BRepExtrema_DistShapeShape distance(BRepBuilderAPI_MakeVertex(point).Vertex(), built_face);
                    made_plate.miss = std::max(made_plate.miss, distance.IsDone() ? distance.Value() : 1e300);
                }
            }
            for (int64_t i = 0; i < points.size(); ++i) {
                BRepExtrema_DistShapeShape distance(BRepBuilderAPI_MakeVertex(P(points[i]).Transformed(grow)).Vertex(), built_face);
                made_plate.miss = std::max(made_plate.miss, distance.IsDone() ? distance.Value() : 1e300);
            }
            made_plate.boundary_error /= scale;
            made_plate.miss /= scale;
            made_plate.face = scale != 1.0 ? TopoDS::Face(BRepBuilderAPI_Transform(built_face, shrink, true).Shape()) : built_face;
            return made_plate;
        };
        try {
            const Plate built = plate(true);
            if (rim.empty()) {
                rim = rim_of(loop, constraints, 2e-3 * size);
            }
            // A plate can't carry on G1 faces leaning out over the loop (see LEAN_OUT): refused for
            // their lean whichever way it fails (missing them, running back down along them, or no
            // plate at all: which a plate shows can hang on its size, OCCT's plate coming out a
            // little different at each).
            const std::string lean = "The patch would run back down along those faces instead of carrying them on (they lean out too far for it); try G0";
            const bool outward = tangent && leans_out(rim, loop);
            // It is the G1 faces it can't reach when, with no points or rails, nothing else can be
            // missed, or when a plate passing them by fits its points and rails.
            auto faces_unreached = [&]() {
                if (!tangent) {
                    return false;
                }
                const Plate loose = bare ? Plate() : plate(false);
                return bare || (!loose.face.IsNull() && strays(loose.face, loose.boundary_error).empty());
            };
            if (built.face.IsNull()) {
                const std::string reason = !coons_problem.empty() ? coons_problem : faces_unreached() ? (outward ? lean : steep) : std::string("The patch could not be built");
                error = String::utf8(reason.c_str());
                return Shape();
            }
            const TopoDS_Face face = built.face;
            // The plate can miss what it was asked for (tangency to steep walls comes out flat, a
            // point beside the boundary flings it wide): such a patch is refused, not returned.
            std::string problem = strays(face, built.boundary_error);
            if (!problem.empty() && faces_unreached()) {
                problem = outward ? lean : steep;
            }
            // Rails and points: a smooth plate can't follow a kink exactly, so it may pass within a
            // hundredth of its size of them (the note says how near); farther (a rail beside the
            // boundary) it is refused.
            const double miss = built.miss;
            if (problem.empty() && miss > 0.01 * size) {
                problem = std::string("The patch can't pass through its ")
                    + (rails.empty() ? "points (is one beside the boundary?)" : points.is_empty() ? "rails (is one beside the boundary, or sharply bent?)" : "rails and points (is one beside the boundary, or sharply bent?)");
            }
            // Leaving its G1 faces the wrong way (back down along them, or down below its edges)
            // says more than missing their tangency, so it comes first.
            CapShape cap;
            if (problem.empty()) {
                const std::string shape_problem = cap_problem(face, loop, rim, size, bare, &cap);
                const bool missed = tangent && tangency_gap(face, constraints) > MAX_PATCH_ANGLE;
                problem = (cap.wrong_way || missed) && outward ? lean : !cap.wrong_way && missed ? steep : shape_problem;
            }
            if (!problem.empty()) {
                // A Coons cap's shape says most about why.
                error = String::utf8((!coons_problem.empty() ? coons_problem : problem).c_str());
                return Shape();
            }
            if (miss > size * 1e-3) {
                char text[120];
                std::snprintf(text, sizeof(text), "The patch passes within %.2f mm of its %s", miss * 1000.0,
                    rails.empty() ? "points" : points.is_empty() ? "rails" : "rails and points");
                notes.push_back(text);
            }
            short_of(face, cap);
            return made(face, ":plate");
        }
        catch (const Standard_Failure&) {
            if (coons_problem.empty()) {
                throw;
            }
            error = String::utf8(coons_problem.c_str());
            return Shape();
        }
    }
    catch (const Standard_Failure& failure) {
        error = tangent ? String("The patch can't be made tangent to those faces; try G0") : String("Patch failed: ") + failure.GetMessageString();
        return Shape();
    }
}

Shape ruled(const Shape& shape, const PackedInt32Array& edge_ids, const Dictionary& p, String& error)
{
    if (!usable(shape) || edge_ids.is_empty()) {
        error = "Pick edges for the ruled surface";
        return Shape();
    }
    const std::string tag = tag_of(p, "ruled");
    const double distance = p.get("distance", 0.01);
    const double angle = p.get("angle", 0.0);
    const String type = p.get("type", "tangent");
    const bool flip = p.get("flip", false);
    const bool alternate = p.get("alternate", false);
    const gp_Dir fixed = D(Vector3(p.get("direction", Vector3(0, 1, 0))).normalized());
    const bool rounded = String(p.get("corner_type", "mitered")) == "rounded";
    if (distance <= 0.0) {
        error = "The ruled distance must be greater than zero";
        return Shape();
    }
    try {
        std::vector<TopoDS_Edge> picked;
        std::vector<int> picked_ids;
        const TopTools_IndexedMapOfShape& edges = shape->edge_map();
        for (int64_t i = 0; i < edge_ids.size(); ++i) {
            const int id = edge_ids[i];
            if (id >= 0 && id < edges.Extent() && !BRep_Tool::Degenerated(TopoDS::Edge(edges(id + 1)))) {
                picked.push_back(TopoDS::Edge(edges(id + 1)));
                picked_ids.push_back(id);
            }
        }
        std::vector<TopoDS_Shape> strips;
        std::vector<naming::Role> roles;
        std::vector<Strip> chain;
        for (size_t i = 0; i < picked.size(); ++i) {
            // An edge rules off its first face, or off the face it shares with a picked edge it
            // meets, so a chain along one face rules off that face; "alternate" takes the other.
            const std::vector<TopoDS_Face> faces = faces_of_edge(shape, picked[i]);
            TopoDS_Face face = faces.empty() ? TopoDS_Face() : faces[0];
            bool settled = false;
            for (size_t j = 0; j < picked.size() && faces.size() > 1 && !settled; ++j) {
                TopoDS_Vertex corner;
                if (j == i || !TopExp::CommonVertex(picked[i], picked[j], corner)) {
                    continue;
                }
                for (const TopoDS_Face& other : faces_of_edge(shape, picked[j])) {
                    for (const TopoDS_Face& own : faces) {
                        if (!settled && own.IsSame(other)) {
                            face = own;
                            settled = true;
                        }
                    }
                }
            }
            if (alternate && faces.size() > 1) {
                face = face.IsSame(faces[0]) ? faces[1] : faces[0];
            }
            std::array<gp_Pnt, 2> far;
            TopoDS_Edge far_edge;
            const TopoDS_Face strip = ruled_strip(picked[i], face, type, distance, angle, flip, fixed, error, &far, &far_edge);
            if (strip.IsNull()) {
                return Shape();
            }
            const std::string name = edge_name(*shape.ptr(), picked_ids[i]);
            chain.push_back({picked[i], far_edge, far, name, strips.size()});
            strips.push_back(strip);
            roles.push_back({strip, tag + ":r(" + name + ")"});
        }
        if (strips.empty()) {
            error = "Pick edges for the ruled surface";
            return Shape();
        }
        // Where the strips of edges that meet part, the corner is filled; where they cross, they
        // are cut back to meet.
        strip_corners(chain, rounded, tag + ":r", strips, roles);
        TopoDS_Shape result = strips[0];
        if (strips.size() > 1) {
            BRepBuilderAPI_Sewing sewing(std::max(diagonal(compound_of(strips)) * 1e-7, 1e-9));
            result = sew(strips, roles, sewing);
        }
        Shape out = CadShape::wrap(result);
        naming::name_result(*out.ptr(), nullptr, {}, tag, roles);
        return out;
    }
    catch (const Standard_Failure& failure) {
        error = String("Ruled surface failed: ") + failure.GetMessageString();
        return Shape();
    }
}

namespace
{
/// offset_surface, at the size the shape is.
Shape offset_at_size(const Shape& shape, const PackedInt32Array& ids, double distance, const std::string& tag, String& error, String& note)
{
    try {
        const std::vector<TopoDS_Face> faces = faces_by_id(shape, ids);
        if (faces.empty()) {
            error = "Pick faces to offset";
            return Shape();
        }
        if (!offset_fits(faces, distance, error)) {
            return Shape();
        }
        std::vector<TopoDS_Shape> parts;
        std::vector<naming::Role> roles;
        for (const std::vector<int>& group : face_regions(shape->get_occ_shape(), faces)) {
            Shape source = with_names_of(assemble_faces(faces, {group}), *shape.ptr());
            // Joined offsets meet at sharp seams; a simple offset is the fallback, also for a
            // joined offset that "succeeds" with a broken face (a cone's apex does that).
            BRepOffsetAPI_MakeOffsetShape joined_offset;
            try {
                joined_offset.PerformByJoin(source->get_occ_shape(), distance, 1e-7, BRepOffset_Skin, false, false, GeomAbs_Intersection);
            }
            catch (const Standard_Failure&) {
            }
            BRepOffsetAPI_MakeOffsetShape simple_offset;
            BRepOffsetAPI_MakeOffsetShape* used = &joined_offset;
            // Its area is checked too: what each face's curvature makes it, and for a joined
            // offset its seams' mitres and overlaps (see seam_change; a curved face's integral is
            // good to about 1 %, a mitre between curved faces bends). A small L sheet's joined
            // offset kept its faces as they were, or left one with no area, and passed the rest.
            double flat_area = 0.0;
            double curved_area = 0.0;
            for (TopExp_Explorer it(source->get_occ_shape(), TopAbs_FACE); it.More(); it.Next()) {
                const TopoDS_Face& face = TopoDS::Face(it.Current());
                (BRepAdaptor_Surface(face, false).GetType() == GeomAbs_Plane ? flat_area : curved_area) += offset_area(face, distance);
            }
            double seams = 0.0;
            const double mitres = 2.0 * std::abs(distance) * seam_change(source->get_occ_shape(), distance, false, seams);
            auto good = [&](BRepOffsetAPI_MakeOffsetShape& offset, bool joined) {
                if (!offset.IsDone() || !sound(offset.Shape()) || !offset_along(source->get_occ_shape(), offset.Shape(), distance)) {
                    return false;
                }
                const double area = measure::surface(offset.Shape()).Mass();
                const double want = flat_area + curved_area + (joined ? mitres : 0.0);
                return std::abs(area - want) <= 1e-6 * (flat_area + curved_area) + 0.01 * curved_area + 0.4 * std::abs(distance) * seams;
            };
            if (!good(joined_offset, true)) {
                try {
                    simple_offset.PerformBySimple(source->get_occ_shape(), distance);
                }
                catch (const Standard_Failure&) {
                }
                if (!good(simple_offset, false)) {
                    error = has_point(source->get_occ_shape()) ? "The surface can't be offset (it comes to a point)" : "The surface can't be offset that far";
                    return Shape();
                }
                used = &simple_offset;
                // Each face moved on its own: where faces meet at an angle they now part or cross.
                if (std::abs(mitres) > 1e-6 * (flat_area + curved_area)) {
                    note = "The offset faces could not be joined where they meet at an angle: each is offset on its own, so they part or overlap at those edges";
                }
            }
            // Each offset face keeps the name of the face it was made from (OCCT lists it as
            // generated from that face, not modified).
            std::vector<naming::Role> made;
            const TopTools_IndexedMapOfShape& source_faces = source->face_map();
            for (int i = 1; i <= source_faces.Extent(); ++i) {
                for (TopTools_ListOfShape::Iterator it(used->Generated(source_faces(i))); it.More(); it.Next()) {
                    made.push_back({it.Value(), face_name(*source.ptr(), i - 1)});
                }
            }
            Shape piece = CadShape::wrap(used->Shape());
            naming::name_result(*piece.ptr(), used, {source.ptr()}, tag, made);
            const TopTools_IndexedMapOfShape& piece_faces = piece->face_map();
            for (int i = 1; i <= piece_faces.Extent(); ++i) {
                roles.push_back({piece_faces(i), face_name(*piece.ptr(), i - 1)});
            }
            parts.push_back(used->Shape());
        }
        Shape out = CadShape::wrap(compound_of(parts));
        naming::name_result(*out.ptr(), nullptr, {}, tag, roles);
        return out;
    }
    catch (const Standard_Failure& failure) {
        error = String("Offset failed: ") + failure.GetMessageString();
        return Shape();
    }
}

/// A shape's copy scaled by trsf, names carried over (the copy has the same structure).
Shape scaled_named(const Shape& in, const gp_Trsf& trsf)
{
    BRepBuilderAPI_Transform mover(in->get_occ_shape(), trsf, true);
    Shape out = CadShape::wrap(mover.Shape());
    out->face_name_list = in->face_name_list;
    out->edge_name_list = in->edge_name_list;
    return out;
}

/// The size (a box diagonal, m) a closed shell is checked for crossings at: OCCT's check of faces
/// that meet tangent (a G1 cap and its tube, a G1 plate and its sphere) takes far longer at some
/// sizes than others. At its own size a G1 cap stitched to a 0.5 mm tube took 15 s (10 mm, 0.26 s);
/// at 100 m a 0.5 mm sphere's G1 plate took 7.6 s; at 1 m every case tried (lids through a box's
/// floor 0.005 mm deep refused, caps, domes and plates closing) took under 0.11 s.
constexpr double CROSSING_CHECK_SIZE = 1.0;

/// True when a closed shell's faces cross each other away from the edges they share: it then
/// bounds no solid (its volume means nothing). Checked on a copy at CROSSING_CHECK_SIZE.
bool self_crossing(const TopoDS_Shape& shell)
{
    Bnd_Box box;
    BRepBndLib::Add(shell, box);
    TopoDS_Shape checked = shell;
    if (!box.IsVoid() && box.SquareExtent() > 0.0) {
        gp_Trsf grow;
        grow.SetScale(gp_Pnt((box.CornerMin().XYZ() + box.CornerMax().XYZ()) * 0.5), CROSSING_CHECK_SIZE / std::sqrt(box.SquareExtent()));
        checked = BRepBuilderAPI_Transform(shell, grow, true).Shape();
    }
    BOPAlgo_ArgumentAnalyzer analyzer;
    analyzer.SetShape1(checked);
    analyzer.ArgumentTypeMode() = false;
    analyzer.SelfInterMode() = true;
    analyzer.SmallEdgeMode() = false;
    analyzer.RebuildFaceMode() = false;
    analyzer.TangentMode() = false;
    analyzer.MergeVertexMode() = false;
    analyzer.MergeEdgeMode() = false;
    analyzer.ContinuityMode() = false;
    analyzer.CurveOnSurfaceMode() = false;
    analyzer.Perform();
    return analyzer.HasFaulty();
}
}  // namespace

Shape offset_surface(const Shape& shape, const PackedInt32Array& ids, double distance, const std::string& tag, String& error, String& note)
{
    if (!usable(shape)) {
        error = "Pick faces to offset";
        return Shape();
    }
    if (std::abs(distance) < 1e-12) {
        error = "The offset distance is zero";
        return Shape();
    }
    // A surface smaller than WORK_SIZE, or with edges shorter than half that, is offset scaled up
    // (work_scale()) and scaled back: OCCT's joined offset has absolute tolerances (an L sheet
    // with 1.2 mm legs came out 8 % off, one with 0.6 mm legs with a face of no area). The size is
    // the picked faces' own (a small L picked in a body with a face 20 mm away came out unjoined),
    // and their narrowest (two such Ls 20 mm apart, both picked, came out 8 % off and unjoined).
    gp_Pnt middle;
    const double factor = work_scale(faces_by_id(shape, ids), WORK_SIZE, middle);
    if (factor == 1.0) {
        return offset_at_size(shape, ids, distance, tag, error, note);
    }
    try {
        gp_Trsf grow;
        grow.SetScale(middle, factor);
        const Shape made = offset_at_size(scaled_named(shape, grow), ids, distance * factor, tag, error, note);
        return usable(made) ? scaled_named(made, grow.Inverted()) : made;
    }
    catch (const Standard_Failure& failure) {
        error = String("Offset failed: ") + failure.GetMessageString();
        return Shape();
    }
}

Shape stitch(const Array& shapes, const Dictionary& p, String& error)
{
    const std::string tag = tag_of(p, "stitch");
    const double tolerance = std::max(double(p.get("tolerance", 1e-5)), 1e-9);
    const bool make_solid = p.get("solid", true);
    try {
        std::vector<TopoDS_Shape> inputs;
        std::vector<naming::Role> roles;
        // Sewing changes the shapes it sews: it sews copies, made together (see detached_together).
        std::vector<Shape> given;
        for (int64_t i = 0; i < shapes.size(); ++i) {
            Ref<CadShape> s = shapes[i];
            if (usable(s)) {
                given.push_back(s);
            }
        }
        if (given.empty()) {
            error = "Select surfaces to stitch";
            return Shape();
        }
        for (const Shape& copy : detached_together(given)) {
            inputs.push_back(copy->get_occ_shape());
            const TopTools_IndexedMapOfShape& faces = copy->face_map();
            for (int k = 1; k <= faces.Extent(); ++k) {
                roles.push_back({faces(k), face_name(*copy.ptr(), k - 1)});
            }
        }
        int open_before = 0;
        int parts_before = 0;
        for (const TopoDS_Shape& input : inputs) {
            open_before += open_edges(input);
            parts_before += part_count(input);
        }
        BRepBuilderAPI_Sewing sewing(tolerance);
        const TopoDS_Shape sewn = sew(inputs, roles, sewing);
        if (sewn.IsNull()) {
            error = "The surfaces could not be stitched";
            return Shape();
        }
        // Closed shells become solids; open ones (and lone faces) stay surfaces. Sewing leaves a
        // lone face (a sphere's, a torus's) out of any shell, though it may close on itself.
        std::vector<TopoDS_Shape> parts;
        bool solid_made = false;
        bool crossing = false;
        auto closed_up = [&](const TopoDS_Shape& faces) -> TopoDS_Shape {
            TopoDS_Shell shell;
            if (faces.ShapeType() == TopAbs_SHELL) {
                shell = TopoDS::Shell(faces);
            }
            else {
                BRep_Builder builder;
                builder.MakeShell(shell);
                builder.Add(shell, faces);
            }
            // A closed shell whose faces cross (a patch through the body it closes) bounds no
            // solid: it came out as one with a volume.
            if (make_solid && closed_shell(shell) && self_crossing(shell)) {
                crossing = true;
                return faces;
            }
            if (make_solid && closed_shell(shell)) {
                BRepBuilderAPI_MakeSolid maker(shell);
                if (maker.IsDone()) {
                    TopoDS_Solid solid = maker.Solid();
                    BRepLib::OrientClosedSolid(solid);
                    solid_made = true;
                    return solid;
                }
            }
            return faces;
        };
        for (TopExp_Explorer it(sewn, TopAbs_SHELL); it.More(); it.Next()) {
            parts.push_back(closed_up(it.Current()));
        }
        for (TopExp_Explorer it(sewn, TopAbs_FACE, TopAbs_SHELL); it.More(); it.Next()) {
            parts.push_back(closed_up(it.Current()));
        }
        if (crossing) {
            error = "The stitched faces cross each other (does a patch pass through the body?), so they don't close a solid";
            return Shape();
        }
        if (parts.empty()) {
            error = "Nothing was left to stitch";
            return Shape();
        }
        if (!solid_made && open_edges(sewn) >= open_before && part_count(sewn) >= parts_before) {
            error = "Nothing was stitched: no open edges meet within the tolerance";
            return Shape();
        }
        Shape out = CadShape::wrap(compound_of(parts));
        naming::name_result(*out.ptr(), nullptr, {}, tag, roles);
        return out;
    }
    catch (const Standard_Failure& failure) {
        error = String("Stitch failed: ") + failure.GetMessageString();
        return Shape();
    }
}

Shape keep_faces(const Shape& shape, const PackedInt32Array& ids, String& error)
{
    if (!usable(shape) || ids.is_empty()) {
        error = "No faces to keep";
        return Shape();
    }
    try {
        const std::vector<TopoDS_Face> faces = faces_by_id(shape, ids);
        if (faces.empty()) {
            error = "No faces to keep";
            return Shape();
        }
        return with_names_of(assemble_faces(faces, face_regions(shape->get_occ_shape(), faces)), *shape.ptr());
    }
    catch (const Standard_Failure& failure) {
        error = String("Keeping faces failed: ") + failure.GetMessageString();
        return Shape();
    }
}

Array pieces(const Shape& shape)
{
    Array result;
    if (!usable(shape)) {
        return result;
    }
    try {
        // Each solid and each shell is a piece (a split surface's regions are shells sharing the
        // cut edges); faces outside shells join up by their edges.
        const TopoDS_Shape& s = shape->get_occ_shape();
        for (TopExp_Explorer it(s, TopAbs_SOLID); it.More(); it.Next()) {
            result.push_back(with_names_of(it.Current(), *shape.ptr()));
        }
        for (TopExp_Explorer it(s, TopAbs_SHELL, TopAbs_SOLID); it.More(); it.Next()) {
            result.push_back(with_names_of(it.Current(), *shape.ptr()));
        }
        std::vector<TopoDS_Face> loose;
        for (TopExp_Explorer it(s, TopAbs_FACE, TopAbs_SHELL); it.More(); it.Next()) {
            loose.push_back(TopoDS::Face(it.Current()));
        }
        for (const std::vector<int>& group : face_regions(s, loose)) {
            result.push_back(with_names_of(assemble_faces(loose, {group}), *shape.ptr()));
        }
    }
    catch (const Standard_Failure&) {
    }
    return result;
}

namespace
{
/// A shape's copy scaled by trsf, names carried over (the copy has the same structure).
Shape scaled(const Shape& in, const gp_Trsf& trsf)
{
    BRepBuilderAPI_Transform mover(in->get_occ_shape(), trsf, true);
    Shape out = CadShape::wrap(mover.Shape());
    out->face_name_list = in->face_name_list;
    out->edge_name_list = in->edge_name_list;
    return out;
}

/// trim, at the size the shapes are.
Shape cut_pieces(const Shape& shape, const Shape& tool, const PackedVector3Array& remove_points, const Dictionary& p, String& error)
{
    const std::string tag = tag_of(p, "trim");
    try {
        // The cut is nearly all of a trim's time on a dense sheet: it runs on OCCT's thread pool
        // (shut down when the extension unloads, see register_types.cpp).
        BRepAlgoAPI_Splitter splitter;
        TopTools_ListOfShape arguments;
        TopTools_ListOfShape tools;
        arguments.Append(shape->get_occ_shape());
        tools.Append(tool->get_occ_shape());
        splitter.SetArguments(arguments);
        splitter.SetTools(tools);
        splitter.SetRunParallel(true);
        // (On copies where it changes them: a body it failed on is left as it was.)
        splitter.SetNonDestructive(true);
        splitter.Build();
        if (!splitter.IsDone() || splitter.Shape().IsNull()) {
            error = "The tool could not cut the surface";
            return Shape();
        }
        Shape split = CadShape::wrap(splitter.Shape());
        naming::name_result(*split.ptr(), &splitter, {shape.ptr()}, tag);
        // A region's faces meet at edges off the tool: the tool's cuts part regions (the edges its
        // faces cut lie on it), and so does an edge of the surface that the tool runs along.
        TopTools_MapOfShape sections;
        for (TopTools_ListOfShape::Iterator it(splitter.SectionEdges()); it.More(); it.Next()) {
            sections.Add(it.Value());
        }
        const ToolProbe probe(tool->get_occ_shape());
        TopTools_MapOfShape joining;
        bool cut = split->face_count() > shape->face_count();
        const TopTools_IndexedDataMapOfShapeListOfShape& edge_faces = split->edge_face_map();
        for (int e = 1; e <= edge_faces.Extent(); ++e) {
            const TopoDS_Edge& edge = TopoDS::Edge(edge_faces.FindKey(e));
            if (edge_faces(e).Extent() < 2 || BRep_Tool::Degenerated(edge)) {
                continue;
            }
            if (sections.Contains(edge) || probe.holds(edge)) {
                cut = true;
            }
            else {
                joining.Add(edge);
            }
        }
        std::vector<TopoDS_Face> faces;
        for (int i = 1; i <= split->face_map().Extent(); ++i) {
            faces.push_back(TopoDS::Face(split->face_map()(i)));
        }
        const std::vector<std::vector<int>> regions = face_regions(split->get_occ_shape(), faces, &joining);
        if (remove_points.is_empty()) {
            // Every region kept, each its own shell (or face), so they read as separate pieces.
            return with_names_of(assemble_faces(faces, regions), *split.ptr());
        }
        if (!cut) {
            error = "The tool doesn't cut the surface";
            return Shape();
        }
        std::vector<int> region_of(faces.size(), -1);
        for (size_t r = 0; r < regions.size(); ++r) {
            for (int f : regions[r]) {
                region_of[f] = int(r);
            }
        }
        std::vector<bool> removed(regions.size(), false);
        std::vector<Bnd_Box> boxes(faces.size());
        for (size_t f = 0; f < faces.size(); ++f) {
            BRepBndLib::Add(faces[f], boxes[f]);
        }
        auto measure = [&](size_t f, const TopoDS_Vertex& point) {
            BRepExtrema_DistShapeShape distance(faces[f], point);
            return distance.IsDone() ? distance.Value() : 1e300;
        };
        for (int64_t k = 0; k < remove_points.size(); ++k) {
            const gp_Pnt p = P(remove_points[k]);
            const TopoDS_Vertex point = BRepBuilderAPI_MakeVertex(p).Vertex();
            // The nearest face (the first of equally near ones, in face order). The face whose box
            // is nearest gives a first bound; a face whose box is farther can't be nearer.
            Bnd_Box at;
            at.Add(p);
            std::vector<double> reach(faces.size(), 0.0);
            size_t guess = 0;
            for (size_t f = 0; f < faces.size(); ++f) {
                reach[f] = boxes[f].Distance(at);
                guess = reach[f] < reach[guess] ? f : guess;
            }
            double best = faces.empty() ? 1e300 : measure(guess, point) * (1.0 + 1e-9) + 1e-30;
            int nearest = -1;
            for (size_t f = 0; f < faces.size(); ++f) {
                if (reach[f] > best) {
                    continue;
                }
                const double d = measure(f, point);
                if (d < best) {
                    best = d;
                    nearest = int(f);
                }
            }
            if (nearest >= 0 && region_of[nearest] >= 0) {
                removed[region_of[nearest]] = true;
            }
        }
        std::vector<TopoDS_Face> kept;
        for (size_t r = 0; r < regions.size(); ++r) {
            if (!removed[r]) {
                for (int f : regions[r]) {
                    kept.push_back(faces[f]);
                }
            }
        }
        if (kept.empty()) {
            error = "Trimming would remove the whole surface";
            return Shape();
        }
        // Kept regions that meet across a cut join back up into one piece.
        return with_names_of(assemble_faces(kept, face_regions(split->get_occ_shape(), kept)), *split.ptr());
    }
    catch (const Standard_Failure& failure) {
        error = String("Trim failed: ") + failure.GetMessageString();
        return Shape();
    }
}
}  // namespace

Shape trim(const Shape& shape, const Shape& tool, const PackedVector3Array& remove_points, const Dictionary& p, String& error)
{
    if (!usable(shape) || !usable(tool)) {
        error = "Trim needs a surface and a trimming tool";
        return Shape();
    }
    // A surface smaller than WORK_SIZE is cut scaled up to it (a 0.5 mm tube's cut face came out
    // 0.24 % too big) and scaled back.
    Bnd_Box box;
    BRepBndLib::Add(shape->get_occ_shape(), box);
    const double size = box.IsVoid() ? WORK_SIZE : std::sqrt(box.SquareExtent());
    if (size >= WORK_SIZE || size <= 0.0) {
        return cut_pieces(shape, tool, remove_points, p, error);
    }
    const gp_Pnt middle((box.CornerMin().XYZ() + box.CornerMax().XYZ()) * 0.5);
    gp_Trsf grow;
    grow.SetScale(middle, WORK_SIZE / size);
    PackedVector3Array points;
    for (int64_t i = 0; i < remove_points.size(); ++i) {
        const gp_Pnt at = P(remove_points[i]).Transformed(grow);
        points.push_back(Vector3(real_t(at.X()), real_t(at.Y()), real_t(at.Z())));
    }
    try {
        const Shape cut = cut_pieces(scaled(shape, grow), scaled(tool, grow), points, p, error);
        return usable(cut) ? scaled(cut, grow.Inverted()) : cut;
    }
    catch (const Standard_Failure& failure) {
        error = String("Trim failed: ") + failure.GetMessageString();
        return Shape();
    }
}

Shape untrim(const Shape& picked, const PackedInt32Array& face_ids, const PackedInt32Array& edge_ids, const Dictionary& p, String& error)
{
    if (!usable(picked)) {
        error = "Pick faces to untrim";
        return Shape();
    }
    const std::string tag = tag_of(p, "untrim");
    const String mode = p.get("mode", "all");
    const double grow = std::max(double(p.get("extend", 0.0)), 0.0);
    try {
        // (On a copy: the faces are sewn back to the ones they met, see detached.)
        const Shape shape = detached(picked);
        struct Job
        {
            TopoDS_Face face;
            bool outer = false;
            bool holes = false;
            std::vector<TopoDS_Shape> drop;
        };
        std::map<int, Job> jobs;
        const TopTools_IndexedMapOfShape& face_map = shape->face_map();
        if (mode == "loops") {
            for (const TopoDS_Edge& edge : edges_by_id(shape, edge_ids)) {
                for (const TopoDS_Face& face : faces_of_edge(shape, edge)) {
                    Job& job = jobs[face_map.FindIndex(face)];
                    job.face = face;
                    const TopoDS_Wire outer = BRepTools::OuterWire(face);
                    for (TopExp_Explorer w(face, TopAbs_WIRE); w.More(); w.Next()) {
                        bool has = false;
                        for (TopExp_Explorer e(w.Current(), TopAbs_EDGE); e.More() && !has; e.Next()) {
                            has = e.Current().IsSame(edge);
                        }
                        if (!has) {
                            continue;
                        }
                        if (w.Current().TShape() == outer.TShape()) {
                            job.outer = true;
                        }
                        else {
                            job.drop.push_back(w.Current());
                        }
                    }
                }
            }
        }
        else if (!face_ids.is_empty()) {
            for (const TopoDS_Face& face : faces_by_id(shape, face_ids)) {
                Job& job = jobs[face_map.FindIndex(face)];
                job.face = face;
                job.outer = mode != "inner";
                job.holes = mode != "outer";
            }
        }
        if (jobs.empty()) {
            error = mode == "loops" ? "Pick edges of the loops to remove" : "Pick faces to untrim";
            return Shape();
        }
        // Said when a face can't grow and stay joined to the one beside it along edge.
        auto joint_error = [&](const TopoDS_Face& face, const TopoDS_Edge& edge) {
            std::string kind = "curved";
            for (const TopoDS_Face& other : faces_of_edge(shape, edge)) {
                if (!other.IsSame(face)) {
                    switch (BRepAdaptor_Surface(other, false).GetType()) {
                        case GeomAbs_Plane:
                            kind = "flat";
                            break;
                        case GeomAbs_Cylinder:
                            kind = "cylindrical";
                            break;
                        case GeomAbs_Cone:
                            kind = "conical";
                            break;
                        case GeomAbs_Sphere:
                            kind = "spherical";
                            break;
                        default:
                            break;
                    }
                }
            }
            return String::utf8(("Untrim can't grow this face past its joint with the " + kind + " face beside it; unstitch it first").c_str());
        };
        BRepTools_ReShape reshape;
        bool rejoin = false;
        TopoDS_Face first_joined;
        TopoDS_Edge first_joint;
        for (auto& [index, job] : jobs) {
            if (job.outer && plate_face(face_name(*shape.ptr(), index - 1))) {
                error = "This patch face has no natural boundary beyond its edges; Untrim can only remove its holes";
                return Shape();
            }
            // The sides of its box along which the face meets others: it stays joined there. An
            // edge it shares that isn't along a side (a slant, a curve) stays an edge of it too:
            // the grown face is cut along it. A box side only such edges reach is taken a tenth of
            // the box further (the cut takes it back), so the cut doesn't just graze it.
            std::array<bool, 4> joined = {false, false, false, false};
            std::array<double, 4> beyond = {0.0, 0.0, 0.0, 0.0};
            std::vector<TopoDS_Edge> slanted;
            for (TopExp_Explorer e(job.face, TopAbs_EDGE); e.More(); e.Next()) {
                const TopoDS_Edge& edge = TopoDS::Edge(e.Current());
                if (faces_of_edge(shape, edge).size() >= 2) {
                    rejoin = rejoin || job.outer;
                    if (first_joint.IsNull()) {
                        first_joined = job.face;
                        first_joint = edge;
                    }
                }
            }
            if (job.outer) {
                double u1 = 0.0, u2 = 0.0, v1 = 0.0, v2 = 0.0;
                if (!measure::uv_bounds(job.face, u1, u2, v1, v2)) {
                    BRepTools::UVBounds(job.face, u1, u2, v1, v2);
                }
                const double reach_tolerance = 1e-7 * std::max(u2 - u1, v2 - v1);
                std::array<bool, 4> free_reach = {false, false, false, false};
                // (Only the outer boundary is given up: a hole kept stays as it is, joined or not,
                // and one removed that was joined parts the face from its neighbour, which is
                // refused below.)
                for (TopExp_Explorer e(BRepTools::OuterWire(job.face), TopAbs_EDGE); e.More(); e.Next()) {
                    const TopoDS_Edge& edge = TopoDS::Edge(e.Current());
                    if (faces_of_edge(shape, edge).size() < 2) {
                        double f = 0.0;
                        double l = 0.0;
                        const Handle(Geom2d_Curve) pcurve = BRep_Tool::CurveOnSurface(edge, job.face, f, l);
                        if (!pcurve.IsNull()) {
                            Bnd_Box2d edge_box;
                            BndLib_Add2dCurve::AddOptimal(pcurve, f, l, 0.0, edge_box);
                            double a = 0.0, b = 0.0, c = 0.0, d = 0.0;
                            edge_box.Get(a, c, b, d);
                            free_reach[0] = free_reach[0] || a <= u1 + reach_tolerance;
                            free_reach[1] = free_reach[1] || b >= u2 - reach_tolerance;
                            free_reach[2] = free_reach[2] || c <= v1 + reach_tolerance;
                            free_reach[3] = free_reach[3] || d >= v2 - reach_tolerance;
                        }
                        continue;
                    }
                    rejoin = true;
                    const int side = iso_side(edge, job.face, u1, u2, v1, v2);
                    if (side >= 0) {
                        joined[side] = true;
                    }
                    else {
                        slanted.push_back(edge);
                    }
                }
                for (int side = 0; side < 4 && !slanted.empty(); ++side) {
                    beyond[side] = free_reach[side] || joined[side] ? 0.0 : 0.1 * (side < 2 ? u2 - u1 : v2 - v1);
                }
            }
            TopoDS_Face face = untrimmed_face(job.face, job.outer, job.holes, job.drop, grow, joined, beyond, error);
            if (face.IsNull()) {
                return Shape();
            }
            if (!slanted.empty()) {
                face = cut_along(job.face, face, slanted);
                if (face.IsNull()) {
                    error = joint_error(job.face, slanted.front());
                    return Shape();
                }
            }
            reshape.Replace(job.face, face);
        }
        const TopoDS_Shape base = reshape.Apply(shape->get_occ_shape());
        std::vector<naming::Role> roles;
        for (int i = 1; i <= face_map.Extent(); ++i) {
            roles.push_back({reshape.Value(face_map(i)), face_name(*shape.ptr(), i - 1)});
        }
        // A face given its natural boundary has edges of its own: it is sewn back to the faces it
        // met, wherever they still meet.
        TopoDS_Shape result = base;
        if (rejoin) {
            BRepBuilderAPI_Sewing sewing(std::max(diagonal(base) * 1e-7, 1e-9));
            result = sew({base}, roles, sewing);
        }
        // Never a sheet split apart: a face that came off what it was joined to is refused.
        auto regions = [](const TopoDS_Shape& s) {
            std::vector<TopoDS_Face> faces;
            for (TopExp_Explorer it(s, TopAbs_FACE); it.More(); it.Next()) {
                faces.push_back(TopoDS::Face(it.Current()));
            }
            return face_regions(s, faces).size();
        };
        if (!first_joint.IsNull() && regions(result) > regions(shape->get_occ_shape())) {
            error = joint_error(first_joined, first_joint);
            return Shape();
        }
        Shape out = CadShape::wrap(result);
        naming::name_result(*out.ptr(), nullptr, {}, tag, roles);
        return out;
    }
    catch (const Standard_Failure& failure) {
        error = String("Untrim failed: ") + failure.GetMessageString();
        return Shape();
    }
}

Shape extend(const Shape& picked, const PackedInt32Array& edge_ids, const Dictionary& p, String& error, String& note)
{
    if (!usable(picked) || edge_ids.is_empty()) {
        error = "Pick the surface edges to extend";
        return Shape();
    }
    const std::string tag = tag_of(p, "extend");
    const double distance = p.get("distance", 0.01);
    const String mode = p.get("mode", "natural");
    if (distance <= 0.0) {
        error = "The extend distance must be greater than zero";
        return Shape();
    }
    try {
        // (On a copy: the bands are sewn on, see detached.)
        const Shape shape = detached(picked);
        const TopTools_IndexedMapOfShape& face_map = shape->face_map();
        const TopTools_IndexedMapOfShape& edge_map = shape->edge_map();
        std::vector<int> picked;
        for (int64_t i = 0; i < edge_ids.size(); ++i) {
            const int id = edge_ids[i];
            if (id < 0 || id >= edge_map.Extent()) {
                continue;
            }
            if (!open_edge(shape, TopoDS::Edge(edge_map(id + 1)))) {
                error = "Extend works on a surface's open edges";
                return Shape();
            }
            if (std::find(picked.begin(), picked.end(), id) == picked.end()) {
                picked.push_back(id);
            }
        }
        if (bool(p.get("chain", false))) {
            picked = chained(shape, picked);
        }
        std::map<int, std::vector<int>> by_face;
        TopTools_MapOfShape extended;
        for (int id : picked) {
            const TopoDS_Edge edge = TopoDS::Edge(edge_map(id + 1));
            by_face[face_map.FindIndex(faces_of_edge(shape, edge)[0])].push_back(id);
            extended.Add(edge);
        }
        if (by_face.empty()) {
            error = "Pick the surface edges to extend";
            return Shape();
        }
        BRepTools_ReShape reshape;
        std::vector<TopoDS_Shape> strips;
        std::vector<naming::Role> strip_roles;
        std::vector<Strip> chain;
        bool rejoin = false;
        int tangential = 0;
        for (const auto& [face_index, ids] : by_face) {
            const TopoDS_Face face = TopoDS::Face(face_map(face_index));
            // A plane carries on as itself, so a tangent extension widens it too.
            const bool flat = BRepAdaptor_Surface(face).GetType() == GeomAbs_Plane;
            const bool natural = mode == "natural" || (mode == "tangent" && flat);
            double u1 = 0.0, u2 = 0.0, v1 = 0.0, v2 = 0.0;
            BRepTools::UVBounds(face, u1, u2, v1, v2);
            std::vector<TopoDS_Edge> edges;
            std::vector<int> sides;
            // Edges where the surface comes to a point at an end (a lens patch's rim): carried on,
            // it would pinch to nothing there, so they get bands of their own (see natural_band).
            std::vector<bool> pointed;
            bool every = natural;
            for (int id : ids) {
                edges.push_back(TopoDS::Edge(edge_map(id + 1)));
                sides.push_back(natural ? iso_side(edges.back(), face, u1, u2, v1, v2) : -1);
                pointed.push_back(sides.back() >= 0 && !flat && comes_to_point(face, edges.back(), sides.back()));
                if (pointed.back()) {
                    sides.back() = -1;
                }
                every = every && sides.back() >= 0;
            }
            // A face that fills its whole UV box (holes aside), extended on edges along its box's
            // sides, becomes the bigger face. Of another face, an edge along a side gets the band of
            // the surface carried on past it (and bands that meet the corner between them) sewn on;
            // a plane's own strips do that.
            bool fills = every;
            if (fills) {
                const TopoDS_Face forward = TopoDS::Face(face.Oriented(TopAbs_FORWARD));
                const TopoDS_Wire outer = BRepTools::OuterWire(forward);
                const TopoDS_Shape outline = with_children(forward, [&](const TopoDS_Shape& wire) { return wire.TShape() == outer.TShape() ? wire : TopoDS_Shape(); });
                GProp_GProps own;
                GProp_GProps box;
                BRepGProp::SurfaceProperties(outline, own);
                BRepGProp::SurfaceProperties(BRepBuilderAPI_MakeFace(BRep_Tool::Surface(face), u1, u2, v1, v2, Precision::Confusion()).Face(), box);
                fills = std::abs(own.Mass() - box.Mass()) <= 1e-6 * std::max(std::abs(box.Mass()), 1e-18);
            }
            if (flat && !fills) {
                sides.assign(sides.size(), -1);
            }
            std::vector<TopoDS_Edge> along;
            std::vector<int> on;
            std::vector<std::string> along_names;
            for (size_t k = 0; k < edges.size(); ++k) {
                if (sides[k] >= 0) {
                    along.push_back(edges[k]);
                    on.push_back(sides[k]);
                    along_names.push_back(edge_name(*shape.ptr(), ids[k]));
                }
            }
            if (!along.empty()) {
                TopoDS_Face grown = grown_face(face, along, on, u1, u2, v1, v2, distance);
                // Carried on through a point (a cone's apex, a sphere's pole) the surface would
                // turn inside out: refused, saying how far it can go.
                for (size_t k = 0; k < along.size(); ++k) {
                    std::string what;
                    const double ahead = point_ahead(face, grown, along[k], on[k], what);
                    if (ahead >= 0.0 && ahead <= distance * (1.0 + 1e-9)) {
                        char text[200];
                        std::snprintf(text, sizeof(text), "The extension would pass %s (%.2f mm away)", what.c_str(), ahead * 1000.0);
                        error = text;
                        return Shape();
                    }
                }
                if (fills) {
                    grown = with_holes(grown, face);
                    grown.Orientation(face.Orientation());
                    reshape.Replace(face, grown);
                    for (TopExp_Explorer e(face, TopAbs_EDGE); e.More() && !rejoin; e.Next()) {
                        rejoin = faces_of_edge(shape, TopoDS::Edge(e.Current())).size() > 1;
                    }
                    continue;
                }
                std::vector<std::array<double, 4>> boxes;
                for (size_t k = 0; k < along.size(); ++k) {
                    boxes.push_back(band_box(grown, along[k], on[k]));
                    TopoDS_Face band = BRepBuilderAPI_MakeFace(BRep_Tool::Surface(grown), boxes[k][0], boxes[k][1], boxes[k][2], boxes[k][3], Precision::Confusion()).Face();
                    band.Orientation(face.Orientation());
                    strips.push_back(band);
                    strip_roles.push_back({band, tag + ":x(" + along_names[k] + ")"});
                }
                for (size_t a = 0; a < along.size(); ++a) {
                    for (size_t b = a + 1; b < along.size(); ++b) {
                        TopoDS_Vertex corner;
                        if ((on[a] < 2) == (on[b] < 2) || !TopExp::CommonVertex(along[a], along[b], corner)) {
                            continue;
                        }
                        const std::array<double, 4>& across_u = on[a] < 2 ? boxes[a] : boxes[b];
                        const std::array<double, 4>& across_v = on[a] < 2 ? boxes[b] : boxes[a];
                        TopoDS_Face fill = BRepBuilderAPI_MakeFace(BRep_Tool::Surface(grown), across_u[0], across_u[1], across_v[2], across_v[3], Precision::Confusion()).Face();
                        fill.Orientation(face.Orientation());
                        strips.push_back(fill);
                        strip_roles.push_back({fill, tag + ":x(" + along_names[a] + "|" + along_names[b] + ")"});
                    }
                }
            }
            // Other edges get a strip: tangent (natural's fallback, said in the note) or square.
            const String type = mode == "perpendicular" ? "normal" : "tangent";
            for (size_t k = 0; k < edges.size(); ++k) {
                if (sides[k] >= 0) {
                    continue;
                }
                std::array<gp_Pnt, 2> far;
                TopoDS_Edge far_edge;
                TopoDS_Face strip = pointed[k] && mode == "natural" ? natural_band(edges[k], face, distance, &far, &far_edge) : TopoDS_Face();
                if (strip.IsNull()) {
                    if (mode == "natural" && !flat) {
                        ++tangential;
                    }
                    strip = ruled_strip(edges[k], face, type, distance, 0.0, false, gp_Dir(0, 1, 0), error, &far, &far_edge);
                }
                if (strip.IsNull()) {
                    return Shape();
                }
                const std::string name = edge_name(*shape.ptr(), ids[k]);
                chain.push_back({edges[k], far_edge, far, name, strips.size()});
                strips.push_back(strip);
                strip_roles.push_back({strip, tag + ":x(" + name + ")"});
            }
        }
        // Strips of edges that meet (on one face or two) leave the corner between them open
        // (filled flat, mitred) or cross (cut back to meet).
        strip_corners(chain, false, tag + ":x", strips, strip_roles);
        if (tangential > 0) {
            note = String::num_int64(tangential) + (tangential == 1 ? " edge was" : " edges were") + " extended tangentially (natural extension needs an untrimmed edge)";
        }
        const TopoDS_Shape base = reshape.Apply(shape->get_occ_shape());
        std::vector<naming::Role> roles;
        for (int i = 1; i <= face_map.Extent(); ++i) {
            roles.push_back({reshape.Value(face_map(i)), face_name(*shape.ptr(), i - 1)});
        }
        if (strips.empty()) {
            // A grown face has edges of its own: it is sewn back to the faces it met.
            TopoDS_Shape result = base;
            if (rejoin) {
                BRepBuilderAPI_Sewing sewing(std::max(diagonal(base) * 1e-7, 1e-9));
                result = sew({base}, roles, sewing);
            }
            Shape out = CadShape::wrap(result);
            naming::name_result(*out.ptr(), nullptr, {}, tag, roles);
            return out;
        }
        roles.insert(roles.end(), strip_roles.begin(), strip_roles.end());
        std::vector<TopoDS_Shape> parts = {base};
        parts.insert(parts.end(), strips.begin(), strips.end());
        BRepBuilderAPI_Sewing sewing(std::max(diagonal(base) * 1e-7, 1e-9));
        const TopoDS_Shape sewn = sew(parts, roles, sewing);
        Shape raw = CadShape::wrap(sewn);
        naming::name_result(*raw.ptr(), nullptr, {}, tag, roles);
        // A strip carries on a flat face as part of it: merge across the extended edges only.
        TopTools_MapOfShape keep;
        for (int e = 1; e <= edge_map.Extent(); ++e) {
            const TopoDS_Shape& edge = edge_map(e);
            if (extended.Contains(edge)) {
                continue;
            }
            const TopoDS_Shape now = reshape.Value(edge);
            keep.Add(sewing.IsModifiedSubShape(now) ? sewing.ModifiedSubShape(now) : now);
        }
        return unify(raw, tag, &keep);
    }
    catch (const Standard_Failure& failure) {
        error = String("Extend failed: ") + failure.GetMessageString();
        return Shape();
    }
}

Shape merge_faces(const Shape& shape, const PackedInt32Array& edge_ids, const PackedInt32Array& face_ids, const std::string& tag, String& error)
{
    if (!usable(shape) || (edge_ids.is_empty() && face_ids.is_empty())) {
        error = "Pick the edges between the faces to merge";
        return Shape();
    }
    try {
        TopTools_MapOfShape mergeable;
        for (const TopoDS_Edge& edge : edges_by_id(shape, edge_ids)) {
            mergeable.Add(edge);
        }
        if (!face_ids.is_empty()) {
            TopTools_MapOfShape picked;
            for (const TopoDS_Face& face : faces_by_id(shape, face_ids)) {
                picked.Add(face);
            }
            const TopTools_IndexedDataMapOfShapeListOfShape& edge_faces = shape->edge_face_map();
            for (int e = 1; e <= edge_faces.Extent(); ++e) {
                int inside = 0;
                for (TopTools_ListOfShape::Iterator it(edge_faces(e)); it.More(); it.Next()) {
                    inside += picked.Contains(it.Value()) ? 1 : 0;
                }
                if (inside >= 2) {
                    mergeable.Add(edge_faces.FindKey(e));
                }
            }
        }
        bool between = false;
        for (TopTools_MapOfShape::Iterator it(mergeable); it.More(); it.Next()) {
            between = between || faces_of_edge(shape, TopoDS::Edge(it.Key())).size() > 1;
        }
        if (!between) {
            error = "Those faces aren't joined by an edge, so they can't be merged";
            return Shape();
        }
        TopTools_MapOfShape keep;
        const TopTools_IndexedMapOfShape& edge_map = shape->edge_map();
        for (int e = 1; e <= edge_map.Extent(); ++e) {
            if (!mergeable.Contains(edge_map(e))) {
                keep.Add(edge_map(e));
            }
        }
        // Faces only merge within a shell: the separate pieces a cut leaves (shells sharing the
        // cut edge) are put in one shell first where they meet at the edges to merge across.
        Shape source = with_names_of(shells_joined(shape->get_occ_shape(), mergeable), *shape.ptr());
        Shape out = unify(source, tag, &keep);
        if (out->face_count() >= shape->face_count()) {
            error = "Those faces don't lie on one surface, so they can't be merged";
            return Shape();
        }
        return out;
    }
    catch (const Standard_Failure& failure) {
        error = String("Merge failed: ") + failure.GetMessageString();
        return Shape();
    }
}

Shape reverse_faces(const Shape& shape, const PackedInt32Array& ids, String& error)
{
    if (!usable(shape)) {
        error = "Pick surfaces to reverse";
        return Shape();
    }
    try {
        TopoDS_Shape result;
        if (ids.is_empty()) {
            result = shape->get_occ_shape().Reversed();
        }
        else {
            // The same shape rebuilt with the picked faces turned over (a re-shape would see the
            // turned face as the same face and keep it). A face turns with every face it is joined
            // to: a sheet that faces two ways can't be thickened or offset as one.
            TopTools_MapOfShape chosen;
            for (const TopoDS_Face& face : faces_by_id(shape, ids)) {
                chosen.Add(face);
            }
            const std::vector<TopoDS_Face> all = faces_by_id(shape, PackedInt32Array());
            std::set<const TopoDS_TShape*> picked;
            for (const std::vector<int>& group : face_regions(shape->get_occ_shape(), all)) {
                bool touched = false;
                for (int k : group) {
                    touched = touched || chosen.Contains(all[k]);
                }
                for (int k = 0; touched && k < int(group.size()); ++k) {
                    picked.insert(all[group[k]].TShape().get());
                }
            }
            std::function<TopoDS_Shape(const TopoDS_Shape&)> rebuild = [&](const TopoDS_Shape& s) -> TopoDS_Shape {
                if (s.ShapeType() == TopAbs_FACE) {
                    return picked.count(s.TShape().get()) > 0 ? s.Reversed() : s;
                }
                return with_children(s, [&](const TopoDS_Shape& child) { return rebuild(child); });
            };
            result = rebuild(shape->get_occ_shape());
        }
        Shape out = CadShape::wrap(result);
        out->face_name_list = shape->face_name_list;
        out->edge_name_list = shape->edge_name_list;
        return out;
    }
    catch (const Standard_Failure& failure) {
        error = String("Reverse Normal failed: ") + failure.GetMessageString();
        return Shape();
    }
}

}  // namespace holo_forge::ops
