#include "solid_ops.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <functional>
#include <map>
#include <limits>
#include <memory>
#include <mutex>
#include <set>
#include <thread>
#include <tuple>

#include <BOPAlgo_MakerVolume.hxx>
#include <BRepAdaptor_CompCurve.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <BRepAlgoAPI_BuilderAlgo.hxx>
#include <BRepAlgoAPI_Common.hxx>
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepAlgoAPI_Defeaturing.hxx>
#include <BRepAlgoAPI_Fuse.hxx>
#include <BRepAlgoAPI_Section.hxx>
#include <BRepAlgoAPI_Splitter.hxx>
#include <BRepBndLib.hxx>
#include <BRepBuilderAPI_Copy.hxx>
#include <BRepBuilderAPI_NurbsConvert.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRepBuilderAPI_Sewing.hxx>
#include <BRepBuilderAPI_GTransform.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepBuilderAPI_MakePolygon.hxx>
#include <BRepBuilderAPI_MakeSolid.hxx>
#include <BRepBuilderAPI_MakeVertex.hxx>
#include <BRepBuilderAPI_MakeWire.hxx>
#include <BRepBuilderAPI_Transform.hxx>
#include <BRepClass3d_SolidClassifier.hxx>
#include <BRepClass_FaceClassifier.hxx>
#include <BRepExtrema_DistShapeShape.hxx>
#include <BRepExtrema_SelfIntersection.hxx>
#include <BRepExtrema_TriangleSet.hxx>
#include <BRepExtrema_ShapeProximity.hxx>
#include <BRepFeat_MakeLinearForm.hxx>
#include <BRepFeat_SplitShape.hxx>
#include <BRepFilletAPI_MakeFillet.hxx>
#include <BRepGProp.hxx>
#include <BRepGProp_Face.hxx>
#include <BRepLib.hxx>
#include <BRepLib_FindSurface.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <IMeshTools_Parameters.hxx>
#include <BRepOffsetAPI_DraftAngle.hxx>
#include <BRepOffsetAPI_MakeOffset.hxx>
#include <BRepOffsetAPI_MakeOffsetShape.hxx>
#include <BRepOffsetAPI_MakePipeShell.hxx>
#include <BRepOffsetAPI_MakeThickSolid.hxx>
#include <BRepOffsetAPI_ThruSections.hxx>
#include <BRepOffset_MakeOffset.hxx>
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
#include <BRepPrimAPI_MakeRevol.hxx>
#include <BRepPrimAPI_MakeSphere.hxx>
#include <BRepPrimAPI_MakeTorus.hxx>
#include <BRepTools.hxx>
#include <BRepTopAdaptor_FClass2d.hxx>
#include <BRepTools_ReShape.hxx>
#include <BRepTools_WireExplorer.hxx>
#include <BRep_Builder.hxx>
#include <BRep_Tool.hxx>
#include <Bnd_Box.hxx>
#include <ChFi3d_ChBuilder.hxx>
#include <ElCLib.hxx>
#include <ElSLib.hxx>
#include <GCE2d_MakeSegment.hxx>
#include <GCPnts_AbscissaPoint.hxx>
#include <GC_MakeArcOfCircle.hxx>
#include <BRepAdaptor_Curve.hxx>
#include <GProp_GProps.hxx>
#include <Geom2d_Line.hxx>
#include <GeomAPI_Interpolate.hxx>
#include <GeomAdaptor_Curve.hxx>
#include <GeomConvert.hxx>
#include <GeomConvert_ApproxCurve.hxx>
#include <GeomLib_IsPlanarSurface.hxx>
#include <GeomLProp_SLProps.hxx>
#include <Geom_OffsetSurface.hxx>
#include <Geom_RectangularTrimmedSurface.hxx>
#include <Geom_Circle.hxx>
#include <Geom_ConicalSurface.hxx>
#include <Geom_CylindricalSurface.hxx>
#include <Geom_Line.hxx>
#include <Geom_OffsetCurve.hxx>
#include <Geom_BSplineCurve.hxx>
#include <Geom_Conic.hxx>
#include <Geom_Plane.hxx>
#include <Geom_SurfaceOfRevolution.hxx>
#include <Geom_TrimmedCurve.hxx>
#include <IntAna2d_AnaIntersection.hxx>
#include <IntCurvesFace_ShapeIntersector.hxx>
#include <Law_Linear.hxx>
#include <Message_ProgressIndicator.hxx>
#include <Message_ProgressScope.hxx>
#include <Poly_Triangulation.hxx>
#include <Precision.hxx>
#include <ShapeAnalysis_Curve.hxx>
#include <ShapeAnalysis_FreeBounds.hxx>
#include <ShapeCustom.hxx>
#include <ShapeFix_Face.hxx>
#include <ShapeUpgrade_UnifySameDomain.hxx>
#include <Standard_Failure.hxx>
#include <TColStd_HArray1OfReal.hxx>
#include <TColgp_HArray1OfPnt.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopOpeBRepBuild_HBuilder.hxx>
#include <TopTools_HSequenceOfShape.hxx>
#include <TopTools_IndexedDataMapOfShapeListOfShape.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <TopTools_ListOfShape.hxx>
#include <TopTools_MapOfShape.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Compound.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Iterator.hxx>
#include <TopoDS_Shell.hxx>
#include <TopoDS_Solid.hxx>
#include <TopoDS_Vertex.hxx>
#include <TopoDS_Wire.hxx>
#include <gp_Ax2.hxx>
#include <gp_Ax3.hxx>
#include <gp_Circ.hxx>
#include <gp_Circ2d.hxx>
#include <gp_GTrsf.hxx>
#include <gp_Lin.hxx>
#include <gp_Lin2d.hxx>
#include <gp_Pln.hxx>

// (Some OCCT headers pull in windows.h, whose near and far macros break ordinary names.)
#ifdef near
#undef near
#endif
#ifdef far
#undef far
#endif

#include "measure.h"
#include "naming.h"
#include "occt_guard.h"
#include "subd_bvh.h"
#include "surface_ops.h"

using namespace godot;

namespace holo_forge::ops
{

namespace
{
/// How closely what OCCT approximates (sweeps, lofts, fillets) is fitted, as a fraction of the
/// part's size: OCCT's defaults are absolute and meant for millimetres (0.1 mm for sweeps and
/// fillets, 1 um for lofts), and Holo Forge works in meters.
constexpr double FIT = 1e-7;
/// The same for a curve on a surface (a helix, a spiral), as a fraction of its radius.
constexpr double CURVE_FIT = 1e-9;

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

TopTools_IndexedMapOfShape map_of(const TopoDS_Shape& s, TopAbs_ShapeEnum type)
{
    TopTools_IndexedMapOfShape map;
    TopExp::MapShapes(s, type, map);
    return map;
}

/// Names a fresh primitive's faces by their direction (planes) or as its round surface.
Shape primitive(const TopoDS_Shape& s, const std::string& tag, const gp_Dir* axis = nullptr)
{
    Shape out = CadShape::wrap(s);
    TopTools_IndexedMapOfShape faces = map_of(s, TopAbs_FACE);
    std::vector<naming::Role> roles;
    for (int i = 1; i <= faces.Extent(); ++i) {
        const TopoDS_Face& face = TopoDS::Face(faces(i));
        BRepAdaptor_Surface surface(face);
        std::string role;
        if (surface.GetType() == GeomAbs_Plane) {
            gp_Dir n = surface.Plane().Axis().Direction();
            if (face.Orientation() == TopAbs_REVERSED) {
                n.Reverse();
            }
            if (axis != nullptr && std::abs(n.Dot(*axis)) > 0.999) {
                role = n.Dot(*axis) > 0 ? "top" : "bottom";
            }
            else {
                role = naming::direction_name(n);
            }
        }
        else {
            role = surface.GetType() == GeomAbs_Cylinder ? "side" : "surface";
        }
        roles.push_back({face, tag + ":" + role});
    }
    naming::name_result(*out.ptr(), nullptr, {}, tag, roles);
    return out;
}

/// Merges coplanar / co-cylindrical faces left behind by booleans, keeping names.
Shape unify(const Shape& in, const std::string& tag)
{
    ShapeUpgrade_UnifySameDomain unifier(in->get_occ_shape(), true, true, true);
    unifier.Build();
    // A face it merged must be sound: merging the pieces of a round face around its seam can give
    // one face whose hole runs out across its outer wire (a converted pipe cross, cut: the big
    // pipe's face, which OCCT's mesher then gives no triangles, 40 % of the body left undrawn).
    // Then the faces are left as the boolean made them.
    TopTools_IndexedMapOfShape before;
    TopExp::MapShapes(in->get_occ_shape(), TopAbs_FACE, before);
    for (TopExp_Explorer it(unifier.Shape(), TopAbs_FACE); it.More(); it.Next()) {
        if (!before.Contains(it.Current()) && !BRepCheck_Analyzer(it.Current()).IsValid()) {
            return in;
        }
    }
    Shape out = CadShape::wrap(unifier.Shape());
    naming::name_from_history(*out.ptr(), unifier.History(), *in.ptr(), tag);
    return out;
}

/// A shape's copy, moved; names carry over (the copy has the same structure).
Shape moved(const Shape& in, const gp_Trsf& trsf)
{
    BRepBuilderAPI_Transform mover(in->get_occ_shape(), trsf, true);
    Shape out = CadShape::wrap(mover.Shape());
    out->face_name_list = in->face_name_list;
    out->edge_name_list = in->edge_name_list;
    return out;
}

/// A shape's copy with geometry of its own, names carried over, for algorithms that change the
/// shape they work on.
Shape detached(const Shape& in)
{
    BRepBuilderAPI_Copy copier(in->get_occ_shape(), true, false);
    Shape out = CadShape::wrap(copier.Shape());
    out->face_name_list = in->face_name_list;
    out->edge_name_list = in->edge_name_list;
    return out;
}

std::vector<TopoDS_Face> faces_of(const TopoDS_Shape& s)
{
    std::vector<TopoDS_Face> result;
    for (TopExp_Explorer it(s, TopAbs_FACE); it.More(); it.Next()) {
        result.push_back(TopoDS::Face(it.Current()));
    }
    return result;
}

std::vector<TopoDS_Face> pick_faces(const Shape& shape, const PackedInt32Array& ids)
{
    TopTools_IndexedMapOfShape faces = map_of(shape->get_occ_shape(), TopAbs_FACE);
    std::vector<TopoDS_Face> result;
    for (int64_t i = 0; i < ids.size(); ++i) {
        if (ids[i] >= 0 && ids[i] < faces.Extent()) {
            result.push_back(TopoDS::Face(faces(ids[i] + 1)));
        }
    }
    return result;
}

std::vector<TopoDS_Edge> pick_edges(const Shape& shape, const PackedInt32Array& ids)
{
    TopTools_IndexedMapOfShape edges = map_of(shape->get_occ_shape(), TopAbs_EDGE);
    std::vector<TopoDS_Edge> result;
    for (int64_t i = 0; i < ids.size(); ++i) {
        if (ids[i] >= 0 && ids[i] < edges.Extent()) {
            result.push_back(TopoDS::Edge(edges(ids[i] + 1)));
        }
    }
    return result;
}

TopoDS_Shape make_compound(const std::vector<TopoDS_Shape>& shapes)
{
    BRep_Builder builder;
    TopoDS_Compound compound;
    builder.MakeCompound(compound);
    for (const TopoDS_Shape& s : shapes) {
        builder.Add(compound, s);
    }
    return compound;
}

gp_Dir face_normal(const TopoDS_Face& face)
{
    BRepGProp_Face props(face);
    double u0, u1, v0, v1;
    props.Bounds(u0, u1, v0, v1);
    gp_Pnt p;
    gp_Vec n;
    props.Normal(0.5 * (u0 + u1), 0.5 * (v0 + v1), p, n);
    return n.Magnitude() > 1e-12 ? gp_Dir(n) : gp_Dir(0, 0, 1);
}

double diagonal(const TopoDS_Shape& s)
{
    Bnd_Box box;
    BRepBndLib::Add(s, box);
    return box.IsVoid() ? 1.0 : std::sqrt(box.SquareExtent());
}

/// A wire made of the given edges, joined end to end in order.
TopoDS_Wire connect(const TopoDS_Shape& edges_shape, String& error)
{
    if (edges_shape.ShapeType() == TopAbs_WIRE) {
        return TopoDS::Wire(edges_shape);
    }
    Handle(TopTools_HSequenceOfShape) edges = new TopTools_HSequenceOfShape();
    for (TopExp_Explorer it(edges_shape, TopAbs_EDGE); it.More(); it.Next()) {
        edges->Append(it.Current());
    }
    Handle(TopTools_HSequenceOfShape) wires = new TopTools_HSequenceOfShape();
    ShapeAnalysis_FreeBounds::ConnectEdgesToWires(edges, 1e-6, false, wires);
    if (wires->IsEmpty()) {
        error = "The path's edges don't connect";
        return TopoDS_Wire();
    }
    return TopoDS::Wire(wires->Value(1));
}

/// A closed profile shape in the plane through point, spanned by u and v (section of coils and pipes).
TopoDS_Wire section_wire(const String& kind, const gp_Pnt& center, const gp_Dir& normal, const gp_Dir& u, double size)
{
    const gp_Dir v = normal.Crossed(u);
    auto at = [&](double a, double b) { return center.Translated(gp_Vec(u) * a + gp_Vec(v) * b); };
    if (kind == "square") {
        const double h = size * 0.5;
        BRepBuilderAPI_MakePolygon polygon(at(-h, -h), at(h, -h), at(h, h), at(-h, h), true);
        return polygon.Wire();
    }
    if (kind == "triangle_out" || kind == "triangle_in") {
        // (Both run the same way round, so both sweep out solids the right way out.)
        const double h = size * 0.5;
        const double s = kind == "triangle_out" ? 1.0 : -1.0;
        BRepBuilderAPI_MakePolygon polygon(at(-s * h, -s * h), at(s * h, 0.0), at(-s * h, s * h), true);
        return polygon.Wire();
    }
    gp_Circ circle(gp_Ax2(center, normal, u), size * 0.5);
    return BRepBuilderAPI_MakeWire(BRepBuilderAPI_MakeEdge(circle).Edge()).Wire();
}

/// A pipe shell along spine (setup gives it its mode and sections) fitted to within FIT of size
/// (its profile's): OCCT's default fit, 0.1 mm, put a 10 mm coil 0.02 % short and a 100-turn
/// one at half its volume. It may take as many pieces as its spine has; one that can't be built
/// that close is tried 10 and 100 times looser, then at OCCT's own fit, and note then says how
/// near it came (what: "sweep", "coil", ...). Null when it can't be built at all.
std::unique_ptr<BRepOffsetAPI_MakePipeShell> fitted_pipe(const TopoDS_Wire& spine, double size, bool solid, double angular,
    const std::function<void(BRepOffsetAPI_MakePipeShell&)>& setup, const char* what, String& note, double scaled_by = 1.0)
{
    int pieces = 0;
    for (TopExp_Explorer it(spine, TopAbs_EDGE); it.More(); it.Next()) {
        pieces += BRepAdaptor_Curve(TopoDS::Edge(it.Current())).NbIntervals(GeomAbs_CN);
    }
    const int segments = std::clamp(8 * pieces, 100, 5000);
    for (const double fit : {FIT, 10.0 * FIT, 100.0 * FIT, 0.0}) {
        auto pipe = std::make_unique<BRepOffsetAPI_MakePipeShell>(spine);
        setup(*pipe);
        if (fit > 0.0) {
            pipe->SetTolerance(fit * size, fit * size, angular);
        }
        pipe->SetMaxSegments(segments);
        try {
            pipe->Build();
            if (!pipe->IsDone() || (solid && !pipe->MakeSolid())) {
                continue;
            }
        }
        catch (const Standard_Failure&) {
            if (fit == 0.0) {
                throw;
            }
            continue;
        }
        if (pipe->ErrorOnSurface() > 10.0 * FIT * size) {
            char text[160];
            std::snprintf(text, sizeof(text), "The %s is fitted to within %.3g mm of its exact shape (a closer fit could not be built)", what, pipe->ErrorOnSurface() / scaled_by * 1000.0);
            note = text;
        }
        return pipe;
    }
    return nullptr;
}

/// A loft through sections (wires or vertices, in order) made by OCCT at one size whatever theirs
/// (LOFT_SIZE across, about their middle) and scaled back: it turns circles and ellipses into
/// splines to within an absolute 1e-7, which put a 2 mm frustum lofted through three circles 1e-5
/// short, and the same loft at 10 and 500 mm 6.6e-5 apart. Fitted to within FIT of their size
/// (OCCT's default, 1 um, put a twisted 4 mm square 0.004 % off); tried at that default when it
/// can't be built so close, and note then says so.
struct Loft
{
    std::unique_ptr<BRepOffsetAPI_ThruSections> maker;
    std::unique_ptr<BRepBuilderAPI_Transform> grow;
    std::unique_ptr<BRepBuilderAPI_Transform> shrink;
    /// The scaling up to LOFT_SIZE.
    gp_Trsf up;

    TopoDS_Shape shape() const { return shrink->Shape(); }
    TopoDS_Shape first() const { return scaled_back(maker->FirstShape()); }
    TopoDS_Shape last() const { return scaled_back(maker->LastShape()); }

    /// A part of the loft at its own size (null for none: a loft to a point has no end face).
    TopoDS_Shape scaled_back(const TopoDS_Shape& part) const { return part.IsNull() ? part : shrink->ModifiedShape(part); }

    /// The faces made along an edge of a section.
    std::vector<TopoDS_Shape> generated(const TopoDS_Shape& edge) const
    {
        std::vector<TopoDS_Shape> made;
        for (TopTools_ListOfShape::Iterator it(maker->Generated(grow->ModifiedShape(edge))); it.More(); it.Next()) {
            made.push_back(scaled_back(it.Value()));
        }
        return made;
    }
};

/// The size (in OCCT's units, the millimetres its tolerances suit) every loft is made at.
constexpr double LOFT_SIZE = 100.0;

/// The loft through sections (see Loft; closed: back to the first; compatible: OCCT matches loops
/// of different edge counts); null when it can't be built at all.
std::unique_ptr<Loft> fitted_loft(bool solid, bool ruled, const std::vector<TopoDS_Shape>& sections, bool closed, bool compatible, const char* what, String& note)
{
    const TopoDS_Shape all = make_compound(sections);
    Bnd_Box box;
    BRepBndLib::Add(all, box);
    const double size = box.IsVoid() ? 1.0 : std::sqrt(box.SquareExtent());
    const double factor = LOFT_SIZE / std::max(size, 1e-12);
    const gp_Pnt middle = box.IsVoid() ? gp::Origin() : gp_Pnt((box.CornerMin().XYZ() + box.CornerMax().XYZ()) * 0.5);
    gp_Trsf up;
    up.SetScale(middle, factor);
    auto loft = std::make_unique<Loft>();
    loft->up = up;
    // (One copy of them all, so sections that share edges still do.)
    loft->grow = std::make_unique<BRepBuilderAPI_Transform>(all, up, true);
    // (A part's copy is kept facing as the part's shape does: a section turned round, to run the
    // way the one before does, stays turned.)
    auto scaled = [&](const TopoDS_Shape& section) {
        const TopoDS_Shape copy = loft->grow->ModifiedShape(section);
        return copy.Oriented(TopAbs::Compose(copy.Orientation(), section.Orientation()));
    };
    for (int attempt = 0; attempt < 2; ++attempt) {
        const double fit = attempt == 0 ? FIT * size : 1e-6;
        loft->maker = std::make_unique<BRepOffsetAPI_ThruSections>(solid, ruled, fit * factor);
        for (const TopoDS_Shape& section : sections) {
            if (section.ShapeType() == TopAbs_VERTEX) {
                loft->maker->AddVertex(BRepBuilderAPI_MakeVertex(BRep_Tool::Pnt(TopoDS::Vertex(section)).Transformed(up)).Vertex());
            }
            else {
                loft->maker->AddWire(TopoDS::Wire(scaled(section)));
            }
        }
        if (closed && sections.front().ShapeType() == TopAbs_WIRE) {
            loft->maker->AddWire(TopoDS::Wire(scaled(sections.front())));
        }
        loft->maker->CheckCompatibility(compatible);
        try {
            loft->maker->Build();
        }
        catch (const Standard_Failure&) {
            if (attempt == 1) {
                throw;
            }
            continue;
        }
        if (loft->maker->IsDone()) {
            if (attempt == 1 && fit > 10.0 * FIT * size) {
                char text[160];
                std::snprintf(text, sizeof(text), "The %s is fitted to within %.3g mm of its sections (a closer fit could not be built)", what, fit * 1000.0);
                note = text;
            }
            gp_Trsf down;
            down.SetScale(middle, 1.0 / factor);
            loft->shrink = std::make_unique<BRepBuilderAPI_Transform>(loft->maker->Shape(), down, true);
            return loft;
        }
    }
    return nullptr;
}

Shape sweep_wire(const TopoDS_Wire& spine, const TopoDS_Wire& profile, const gp_Dir* binormal, const std::string& tag, const char* what, String& error, String& note, bool solid = true)
{
    auto pipe = fitted_pipe(spine, diagonal(profile), solid, 1e-2, [&](BRepOffsetAPI_MakePipeShell& maker) {
        if (binormal != nullptr) {
            maker.SetMode(*binormal);
        }
        else {
            maker.SetMode(false);
        }
        maker.Add(profile, false, true);
    }, what, note);
    if (!pipe) {
        error = "The sweep could not be built";
        return Shape();
    }
    return named(pipe->Shape(), tag);
}

/// A wire through a chain's edges that shares vertices where they meet.
TopoDS_Wire rejoined(const TopoDS_Wire& chain)
{
    BRepBuilderAPI_MakeWire maker;
    for (TopoDS_Iterator it(chain); it.More(); it.Next()) {
        maker.Add(TopoDS::Edge(it.Value()));
        if (!maker.IsDone()) {
            return chain;
        }
    }
    return maker.IsDone() ? maker.Wire() : chain;
}

/// What a surface feature sweeps: every wire of the profile's faces (holes flagged), and its loose
/// edges joined end to end into wires.
struct ProfileWire
{
    TopoDS_Wire wire;
    bool hole;
};
std::vector<ProfileWire> profile_wires(const TopoDS_Shape& s)
{
    std::vector<ProfileWire> wires;
    for (TopExp_Explorer f(s, TopAbs_FACE); f.More(); f.Next()) {
        const TopoDS_Wire outer = BRepTools::OuterWire(TopoDS::Face(f.Current()));
        for (TopExp_Explorer w(f.Current(), TopAbs_WIRE); w.More(); w.Next()) {
            wires.push_back({TopoDS::Wire(w.Current()), !w.Current().IsSame(outer)});
        }
    }
    Handle(TopTools_HSequenceOfShape) loose = new TopTools_HSequenceOfShape();
    for (TopExp_Explorer e(s, TopAbs_EDGE, TopAbs_FACE); e.More(); e.Next()) {
        loose->Append(e.Current());
    }
    if (!loose->IsEmpty()) {
        Handle(TopTools_HSequenceOfShape) chains = new TopTools_HSequenceOfShape();
        ShapeAnalysis_FreeBounds::ConnectEdgesToWires(loose, 1e-6, false, chains);
        for (int i = 1; i <= chains->Length(); ++i) {
            wires.push_back({rejoined(TopoDS::Wire(chains->Value(i))), false});
        }
    }
    return wires;
}

TopoDS_Shape wires_shape(const std::vector<ProfileWire>& wires)
{
    std::vector<TopoDS_Shape> shapes;
    for (const ProfileWire& w : wires) {
        shapes.push_back(w.wire);
    }
    return shapes.size() == 1 ? shapes[0] : make_compound(shapes);
}

bool has_solid(const TopoDS_Shape& s)
{
    return TopExp_Explorer(s, TopAbs_SOLID).More();
}

int edge_count(const TopoDS_Shape& s)
{
    int count = 0;
    for (TopExp_Explorer it(s, TopAbs_EDGE); it.More(); it.Next()) {
        ++count;
    }
    return count;
}

/// A closed edge (a loop on its own) offset in its plane: grown by a positive distance. The new
/// edge has the same parameters and runs the same way, so a ruled loft pairs each point with its
/// offset: a circle exactly, any other curve as one spline along its offset curve.
TopoDS_Edge offset_closed_edge(const TopoDS_Edge& edge, double distance, String& error)
{
    BRepAdaptor_Curve adaptor(edge);
    const double f = adaptor.FirstParameter();
    const double l = adaptor.LastParameter();
    TopoDS_Edge grown;
    if (adaptor.GetType() == GeomAbs_Circle) {
        gp_Circ circle = adaptor.Circle();
        if (circle.Radius() + distance <= 1e-9) {
            error = "The taper is too steep for this profile";
            return TopoDS_Edge();
        }
        circle.SetRadius(circle.Radius() + distance);
        grown = BRepBuilderAPI_MakeEdge(circle, f, l).Edge();
    }
    else {
        double first = 0.0;
        double last = 0.0;
        Handle(Geom_Curve) curve = BRep_Tool::Curve(edge, first, last);
        if (curve.IsNull() || curve->Continuity() == GeomAbs_C0) {
            return TopoDS_Edge();
        }
        // The loop's plane, facing the way the curve's parameter runs round it (Newell's normal).
        const int samples = 256;
        std::vector<gp_Pnt> points;
        for (int i = 0; i < samples; ++i) {
            points.push_back(curve->Value(first + (last - first) * i / samples));
        }
        gp_Vec around(0.0, 0.0, 0.0);
        for (int i = 0; i < samples; ++i) {
            around += gp_Vec(points[i].XYZ()).Crossed(gp_Vec(points[(i + 1) % samples].XYZ()));
        }
        if (around.Magnitude() < 1e-30) {
            return TopoDS_Edge();
        }
        const gp_Dir normal(around);
        // The offset curve moves along tangent x normal, outward: it folds over itself where it
        // moves toward a center of curvature by the radius or more.
        for (int i = 0; i < samples; ++i) {
            gp_Pnt p;
            gp_Vec d1;
            gp_Vec d2;
            curve->D2(first + (last - first) * i / samples, p, d1, d2);
            const double speed = d1.SquareMagnitude();
            if (speed < 1e-30) {
                continue;
            }
            const gp_Vec outward = d1.Crossed(gp_Vec(normal)).Normalized();
            if (distance * d2.Dot(outward) / speed >= 1.0 - 1e-6) {
                error = "The taper is too steep for this profile";
                return TopoDS_Edge();
            }
        }
        Handle(Geom_Curve) offset = new Geom_OffsetCurve(curve, distance, normal);
        GeomConvert_ApproxCurve approx(Handle(Adaptor3d_Curve)(new GeomAdaptor_Curve(offset, first, last)), Precision::Confusion() * 0.1, GeomAbs_C1, 100, 9);
        if (!approx.HasResult() || approx.MaxError() > Precision::Confusion()) {
            return TopoDS_Edge();
        }
        grown = BRepBuilderAPI_MakeEdge(approx.Curve()).Edge();
        TopoDS_Vertex start;
        TopoDS_Vertex end;
        TopExp::Vertices(grown, start, end);
        if (start.IsNull() || !start.IsSame(end)) {
            return TopoDS_Edge();
        }
    }
    grown.Orientation(edge.Orientation());
    return grown;
}

/// True when a sheet's faces face one way: each edge between two of them runs one way in one face
/// and the other way in the other.
bool facing_one_way(const TopoDS_Shape& sheet)
{
    TopTools_IndexedDataMapOfShapeListOfShape edge_faces;
    TopExp::MapShapesAndAncestors(sheet, TopAbs_EDGE, TopAbs_FACE, edge_faces);
    for (int i = 1; i <= edge_faces.Extent(); ++i) {
        const TopTools_ListOfShape& faces = edge_faces(i);
        if (faces.Extent() != 2 || faces.First().IsSame(faces.Last())) {
            continue;
        }
        TopAbs_Orientation ways[2] = {TopAbs_EXTERNAL, TopAbs_EXTERNAL};
        int k = 0;
        for (TopTools_ListOfShape::Iterator it(faces); it.More(); it.Next(), ++k) {
            for (TopExp_Explorer e(it.Value(), TopAbs_EDGE); e.More(); e.Next()) {
                if (e.Current().IsSame(edge_faces.FindKey(i))) {
                    ways[k] = e.Current().Orientation();
                    break;
                }
            }
        }
        if ((ways[0] == TopAbs_FORWARD || ways[0] == TopAbs_REVERSED) && ways[0] == ways[1]) {
            return false;
        }
    }
    return true;
}

/// A flat wire's copy offset distance to its left (up x the way it runs; up is the normal of its
/// plane) edge for edge: lines and arcs exactly, other curves as splines along their offset.
/// Neighbours that meet at a corner (lines and arcs) are carried on or cut back to where they
/// cross; a closed wire's last edge meets its first so. The copy starts where the wire does.
TopoDS_Wire offset_chain(const TopoDS_Wire& wire, const gp_Dir& up, double distance, String& error)
{
    struct Part
    {
        TopoDS_Edge edge;
        Handle(Geom_Curve) curve;
        double first = 0.0;
        double last = 0.0;
        bool reversed = false;
        int kind = 0;
        Handle(Geom_Curve) offset;
        // The offset's parameters where it starts and ends, the way the wire runs.
        double start = 0.0;
        double end = 0.0;
    };
    std::vector<Part> parts;
    for (BRepTools_WireExplorer it(wire); it.More(); it.Next()) {
        Part part;
        part.edge = it.Current();
        part.curve = BRep_Tool::Curve(part.edge, part.first, part.last);
        if (part.curve.IsNull()) {
            error = "A curve to taper has no shape";
            return TopoDS_Wire();
        }
        part.reversed = part.edge.Orientation() == TopAbs_REVERSED;
        part.start = part.reversed ? part.last : part.first;
        part.end = part.reversed ? part.first : part.last;
        parts.push_back(part);
    }
    if (parts.empty()) {
        error = "Pick curves to extrude";
        return TopoDS_Wire();
    }
    const bool closed = parts.size() > 1 && BRep_Tool::IsClosed(wire);
    const gp_Vec normal(up);
    for (Part& part : parts) {
        GeomAdaptor_Curve adaptor(part.curve, part.first, part.last);
        gp_Pnt p;
        gp_Vec d1;
        part.curve->D1(0.5 * (part.first + part.last), p, d1);
        const gp_Vec left = normal.Crossed(part.reversed ? d1.Reversed() : d1).Normalized();
        if (adaptor.GetType() == GeomAbs_Line) {
            part.offset = new Geom_Line(adaptor.Line().Translated(left * distance));
            continue;
        }
        if (adaptor.GetType() == GeomAbs_Circle && adaptor.Circle().Axis().Direction().IsParallel(up, 1e-9)) {
            gp_Circ circle = adaptor.Circle();
            const double radius = circle.Radius() + (left.Dot(gp_Vec(p, circle.Location())) > 0.0 ? -distance : distance);
            if (radius <= 1e-9 * circle.Radius()) {
                error = "The taper is too steep for this curve";
                return TopoDS_Wire();
            }
            circle.SetRadius(radius);
            part.kind = 1;
            part.offset = new Geom_Circle(circle);
            continue;
        }
        // Other curves: along the offset curve (which moves along tangent x normal, against the
        // left of the curve's own direction), unless it folds over itself on the way.
        part.kind = 2;
        const double toward = part.reversed ? distance : -distance;
        for (int i = 0; i <= 64; ++i) {
            gp_Pnt q;
            gp_Vec v1;
            gp_Vec v2;
            part.curve->D2(part.first + (part.last - part.first) * i / 64.0, q, v1, v2);
            const double speed = v1.SquareMagnitude();
            if (speed > 1e-30 && toward * v2.Dot(v1.Crossed(normal).Normalized()) / speed >= 1.0 - 1e-6) {
                error = "The taper is too steep for this curve";
                return TopoDS_Wire();
            }
        }
        Handle(Geom_Curve) offset = new Geom_OffsetCurve(new Geom_TrimmedCurve(part.curve, part.first, part.last), toward, up);
        GeomConvert_ApproxCurve approx(Handle(Adaptor3d_Curve)(new GeomAdaptor_Curve(offset, part.first, part.last)), Precision::Confusion() * 0.1, GeomAbs_C1, 100, 9);
        if (!approx.HasResult() || approx.MaxError() > Precision::Confusion()) {
            error = "The tapered curve's offset could not be built";
            return TopoDS_Wire();
        }
        part.offset = approx.Curve();
    }
    // Where neighbours meet: a smooth join's offsets meet where the curves' do; at a corner they
    // carry on or are cut back to where they cross (the crossing nearest the corner).
    std::vector<gp_Pnt> joints(parts.size() + 1);
    std::vector<double> slack(parts.size() + 1, 0.0);
    joints.front() = parts.front().offset->Value(parts.front().start);
    joints.back() = parts.back().offset->Value(parts.back().end);
    const gp_Ax3 frame(parts.front().curve->Value(parts.front().start), up);
    auto flat = [&](const gp_Pnt& q) {
        const gp_Vec v(frame.Location(), q);
        return gp_Pnt2d(v.Dot(gp_Vec(frame.XDirection())), v.Dot(gp_Vec(frame.YDirection())));
    };
    auto lifted = [&](const gp_Pnt2d& q) {
        return frame.Location().Translated(gp_Vec(frame.XDirection()) * q.X() + gp_Vec(frame.YDirection()) * q.Y());
    };
    auto line_of = [&](const Part& part) {
        const gp_Lin line = Handle(Geom_Line)::DownCast(part.offset)->Lin();
        return gp_Lin2d(flat(line.Location()), gp_Dir2d(line.Direction().Dot(frame.XDirection()), line.Direction().Dot(frame.YDirection())));
    };
    auto circle_of = [&](const Part& part) {
        const gp_Circ circle = Handle(Geom_Circle)::DownCast(part.offset)->Circ();
        return gp_Circ2d(gp_Ax2d(flat(circle.Location()), gp_Dir2d(1.0, 0.0)), circle.Radius());
    };
    for (size_t k = 0; k < (closed ? parts.size() : parts.size() - 1); ++k) {
        Part& a = parts[k];
        Part& b = parts[(k + 1) % parts.size()];
        gp_Pnt corner;
        gp_Vec in;
        gp_Vec out;
        a.curve->D1(a.end, corner, in);
        b.curve->D1(b.start, corner, out);
        if (a.reversed) {
            in.Reverse();
        }
        if (b.reversed) {
            out.Reverse();
        }
        const double turn = in.Magnitude() > 1e-30 && out.Magnitude() > 1e-30 ? in.Angle(out) : 0.0;
        IntAna2d_AnaIntersection meet;
        if (turn > 1e-9 && (a.kind == 2 || b.kind == 2)) {
            if (turn > 1e-6) {
                error = "A tapered open curve can turn sharp corners only between lines and arcs";
                return TopoDS_Wire();
            }
        }
        else if (turn > 1e-9) {
            if (a.kind == 0 && b.kind == 0) {
                meet.Perform(line_of(a), line_of(b));
            }
            else if (a.kind == 0) {
                meet.Perform(line_of(a), circle_of(b));
            }
            else if (b.kind == 0) {
                meet.Perform(line_of(b), circle_of(a));
            }
            else {
                meet.Perform(circle_of(a), circle_of(b));
            }
        }
        const bool met = meet.IsDone() && !meet.IsEmpty() && !meet.IdenticalElements() && !meet.ParallelElements() && meet.NbPoints() > 0;
        if (!met) {
            if (turn > M_PI / 180.0) {
                error = "The tapered curves' offsets don't meet at a corner";
                return TopoDS_Wire();
            }
            // Smooth: both offsets end where the curves' offset does (all but a hair).
            const gp_Pnt from = a.offset->Value(a.end);
            const gp_Pnt to = b.offset->Value(b.start);
            joints[k + 1] = gp_Pnt(0.5 * (from.XYZ() + to.XYZ()));
            slack[k + 1] = from.Distance(to);
            continue;
        }
        gp_Pnt best;
        double nearest = 1e300;
        for (int i = 1; i <= meet.NbPoints(); ++i) {
            const gp_Pnt q = lifted(meet.Point(i).Value());
            if (q.Distance(corner) < nearest) {
                nearest = q.Distance(corner);
                best = q;
            }
        }
        joints[k + 1] = best;
        // The offsets' parameters there (an arc's within half a turn of where it was).
        for (Part* part : {&a, &b}) {
            double& at = part == &a ? a.end : b.start;
            if (part->kind == 0) {
                at = ElCLib::Parameter(Handle(Geom_Line)::DownCast(part->offset)->Lin(), best);
            }
            else {
                at = ElCLib::InPeriod(ElCLib::Parameter(Handle(Geom_Circle)::DownCast(part->offset)->Circ(), best), at - M_PI, at + M_PI);
            }
        }
    }
    std::vector<TopoDS_Vertex> vertices;
    for (size_t k = 0; k < joints.size(); ++k) {
        if (closed && k + 1 == joints.size()) {
            vertices.push_back(vertices.front());
            break;
        }
        vertices.push_back(BRepBuilderAPI_MakeVertex(closed && k == 0 ? joints.back() : joints[k]).Vertex());
        const double hair = closed && k == 0 ? slack.back() : slack[k];
        if (hair > Precision::Confusion()) {
            BRep_Builder().UpdateVertex(vertices.back(), hair);
        }
    }
    BRepBuilderAPI_MakeWire maker;
    for (size_t k = 0; k < parts.size(); ++k) {
        const Part& part = parts[k];
        const double length = part.reversed ? part.start - part.end : part.end - part.start;
        if (length <= 1e-9 * std::max(part.last - part.first, 1e-12)) {
            error = "The taper is too steep for this curve's corners";
            return TopoDS_Wire();
        }
        BRepBuilderAPI_MakeEdge edge = part.reversed ? BRepBuilderAPI_MakeEdge(part.offset, vertices[k + 1], vertices[k], part.end, part.start)
                                                     : BRepBuilderAPI_MakeEdge(part.offset, vertices[k], vertices[k + 1], part.start, part.end);
        if (!edge.IsDone()) {
            error = "The tapered curve's offset could not be built";
            return TopoDS_Wire();
        }
        maker.Add(part.reversed ? TopoDS::Edge(edge.Edge().Reversed()) : edge.Edge());
        if (!maker.IsDone()) {
            error = "The tapered curve's offset could not be built";
            return TopoDS_Wire();
        }
    }
    return maker.Wire();
}

/// Points along a wire's edges the way it runs: count on each edge from its start, then the end.
std::vector<gp_Pnt> wire_points(const TopoDS_Wire& wire, int count)
{
    std::vector<gp_Pnt> points;
    gp_Pnt end;
    for (BRepTools_WireExplorer it(wire); it.More(); it.Next()) {
        BRepAdaptor_Curve curve(it.Current());
        const double f = curve.FirstParameter();
        const double l = curve.LastParameter();
        const bool reversed = it.Current().Orientation() == TopAbs_REVERSED;
        for (int i = 0; i < count; ++i) {
            points.push_back(curve.Value(reversed ? l - (l - f) * i / count : f + (l - f) * i / count));
        }
        end = curve.Value(reversed ? f : l);
    }
    if (!points.empty()) {
        points.push_back(end);
    }
    return points;
}

/// An open flat wire's copy offset distance to its left, seen from the side shift goes to (see
/// offset_chain). A straight wire's plane is the one square to shift.
TopoDS_Wire offset_open(const TopoDS_Wire& wire, const gp_Vec& shift, double distance, String& error)
{
    const std::vector<gp_Pnt> samples = wire_points(wire, 16);
    if (samples.empty()) {
        error = "Pick curves to extrude";
        return TopoDS_Wire();
    }
    // The curves' plane: Newell's normal of the chain closed by its chord.
    gp_XYZ middle(0.0, 0.0, 0.0);
    for (const gp_Pnt& p : samples) {
        middle += p.XYZ() / double(samples.size());
    }
    gp_Vec around(0.0, 0.0, 0.0);
    double span = 0.0;
    for (size_t i = 0; i < samples.size(); ++i) {
        const gp_Vec a(samples[i].XYZ() - middle);
        around += a.Crossed(gp_Vec(samples[(i + 1) % samples.size()].XYZ() - middle));
        span = std::max(span, a.Magnitude());
    }
    gp_Vec normal;
    if (around.Magnitude() > 1e-9 * span * span) {
        normal = around.Normalized();
        for (const gp_Pnt& p : samples) {
            if (std::abs(gp_Vec(p.XYZ() - middle).Dot(normal)) > std::max(1e-7 * span, 1e-12)) {
                error = "A tapered extrude needs its open curves to lie in one plane";
                return TopoDS_Wire();
            }
        }
    }
    else {
        const gp_Vec along = gp_Vec(samples.front(), samples.back()).Normalized();
        normal = shift - along * shift.Dot(along);
        if (normal.Magnitude() < 1e-9 * shift.Magnitude()) {
            error = "The extrude runs along the curve, so it can't be tapered";
            return TopoDS_Wire();
        }
        normal.Normalize();
    }
    if (normal.Dot(shift) < 0.0) {
        normal.Reverse();
    }
    if (normal.Dot(shift) < 1e-9 * shift.Magnitude()) {
        error = "The extrude runs in the curves' plane, so it can't be tapered";
        return TopoDS_Wire();
    }
    return offset_chain(wire, gp_Dir(normal), distance, error);
}

/// A flat closed loop grown (positive distance) or shrunk in its plane: the far end of a taper.
/// Lines and arcs are offset exactly, edge for edge (so a wall between straight edges is a true
/// plane), when that gives the loop OCCT's 2D offset gives; other loops are that 2D offset. A
/// one-edge loop is offset along its own curve (the 2D offset crashes on a one-edge circle and
/// splits other one-edge loops into several edges starting somewhere else).
TopoDS_Wire offset_loop(const TopoDS_Wire& wire, double distance, String& error)
{
    std::vector<TopoDS_Edge> edges;
    for (TopExp_Explorer it(wire, TopAbs_EDGE); it.More(); it.Next()) {
        edges.push_back(TopoDS::Edge(it.Current()));
    }
    if (edges.size() == 1) {
        const TopoDS_Edge grown = offset_closed_edge(edges[0], distance, error);
        if (!grown.IsNull()) {
            return BRepBuilderAPI_MakeWire(grown).Wire();
        }
        if (!error.is_empty()) {
            return TopoDS_Wire();
        }
    }
    BRepOffsetAPI_MakeOffset offsetter(BRepBuilderAPI_MakeFace(wire, true).Face(), GeomAbs_Intersection);
    offsetter.Perform(distance);
    if (!offsetter.IsDone()) {
        error = "The taper is too steep for this profile";
        return TopoDS_Wire();
    }
    TopoDS_Wire offset;
    int count = 0;
    for (TopExp_Explorer w(offsetter.Shape(), TopAbs_WIRE); w.More(); w.Next(), ++count) {
        offset = offset.IsNull() ? TopoDS::Wire(w.Current()) : offset;
    }
    if (offset.IsNull()) {
        error = "The taper is too steep for this profile";
        return TopoDS_Wire();
    }
    bool exact = count == 1 && edges.size() > 1 && edge_count(offset) == int(edges.size());
    for (const TopoDS_Edge& edge : edges) {
        const GeomAbs_CurveType type = BRepAdaptor_Curve(edge).GetType();
        exact = exact && (type == GeomAbs_Line || type == GeomAbs_Circle);
    }
    if (exact) {
        // The loop turns counterclockwise about its Newell normal: its left is inside, so it
        // grows to the right.
        const std::vector<gp_Pnt> points = wire_points(wire, 16);
        gp_XYZ middle(0.0, 0.0, 0.0);
        for (const gp_Pnt& p : points) {
            middle += p.XYZ() / double(points.size());
        }
        gp_Vec around(0.0, 0.0, 0.0);
        for (size_t i = 0; i < points.size(); ++i) {
            around += gp_Vec(points[i].XYZ() - middle).Crossed(gp_Vec(points[(i + 1) % points.size()].XYZ() - middle));
        }
        String unused;
        const TopoDS_Wire same = around.Magnitude() > 1e-30 ? offset_chain(wire, gp_Dir(around), -distance, unused) : TopoDS_Wire();
        if (!same.IsNull()) {
            return same;
        }
    }
    return offset;
}

/// s with every face whose spline surface is flat rebuilt on its plane from the same edges, so it
/// stays joined to its neighbours (a tapered wall between straight edges comes out of a ruled loft
/// as a bilinear spline). reshape records each replacement.
TopoDS_Shape true_planes(const TopoDS_Shape& s, BRepTools_ReShape& reshape)
{
    // OCCT's flatness test reads the spread of the spline's poles off their plane from the square
    // root of an eigenvalue, so an exactly flat wall that is turned off the axes reads ~1e-8 of
    // its size: the tolerance sits above that.
    const double tolerance = std::max(diagonal(s) * 1e-7, 1e-12);
    bool changed = false;
    TopTools_MapOfShape seen;
    for (TopExp_Explorer it(s, TopAbs_FACE); it.More(); it.Next()) {
        const TopoDS_Face face = TopoDS::Face(it.Current().Oriented(TopAbs_FORWARD));
        const GeomAbs_SurfaceType type = BRepAdaptor_Surface(face, false).GetType();
        if (!seen.Add(face) || (type != GeomAbs_BSplineSurface && type != GeomAbs_BezierSurface)) {
            continue;
        }
        const Handle(Geom_Surface) surface = BRep_Tool::Surface(face);
        GeomLib_IsPlanarSurface flat(surface, tolerance);
        if (!flat.IsPlanar()) {
            continue;
        }
        // The plane faces the way the spline did, so the face's wires keep their sense.
        double u1 = 0.0, u2 = 0.0, v1 = 0.0, v2 = 0.0;
        BRepTools::UVBounds(face, u1, u2, v1, v2);
        gp_Pnt point;
        gp_Vec du;
        gp_Vec dv;
        surface->D1(0.5 * (u1 + u2), 0.5 * (v1 + v2), point, du, dv);
        gp_Pln plane = flat.Plan();
        if (du.Crossed(dv).Dot(gp_Vec(plane.Axis().Direction())) < 0.0) {
            plane = gp_Pln(plane.Location(), plane.Axis().Direction().Reversed());
        }
        const TopoDS_Wire outer = BRepTools::OuterWire(face);
        BRepBuilderAPI_MakeFace maker(plane, outer, false);
        for (TopExp_Explorer w(face, TopAbs_WIRE); w.More(); w.Next()) {
            if (!w.Current().IsSame(outer)) {
                maker.Add(TopoDS::Wire(w.Current()));
            }
        }
        if (!maker.IsDone()) {
            continue;
        }
        const TopoDS_Face rebuilt = maker.Face();
        for (TopExp_Explorer e(rebuilt, TopAbs_EDGE); e.More(); e.Next()) {
            BRepLib::BuildPCurveForEdgeOnPlane(TopoDS::Edge(e.Current()), rebuilt);
        }
        reshape.Replace(face, rebuilt);
        changed = true;
    }
    return changed ? reshape.Apply(s) : s;
}

/// The side of a tapered extrude: a ruled loft from a flat loop (or open curves) to its offset
/// moved by shift, with every wall between straight edges a true plane. face() gives what became
/// of a face the loft names (GeneratedFace, FirstShape, LastShape).
struct TaperSide
{
    BRepOffsetAPI_ThruSections loft;
    BRepTools_ReShape trued;
    TopoDS_Shape shape;

    explicit TaperSide(bool solid) : loft(solid, true) {}

    TopoDS_Shape face(const TopoDS_Shape& made)
    {
        return made.IsNull() ? made : trued.Value(made);
    }
};

/// Builds side from wire to its offset: a closed loop grown by distance (negative shrinks it), open
/// curves leaned distance to their left (see offset_open). False after error.
bool taper_side(TaperSide& side, const TopoDS_Wire& wire, double distance, const gp_Vec& shift, String& error)
{
    const TopoDS_Wire offset = BRep_Tool::IsClosed(wire) ? offset_loop(wire, distance, error) : offset_open(wire, shift, distance, error);
    if (offset.IsNull()) {
        return false;
    }
    gp_Trsf far;
    far.SetTranslation(shift);
    side.loft.AddWire(wire);
    side.loft.AddWire(TopoDS::Wire(BRepBuilderAPI_Transform(offset, far, true).Shape()));
    // The loops pair up edge for edge, from the same start; only an offset that came out with
    // other edges needs OCCT to match them up.
    side.loft.CheckCompatibility(edge_count(wire) != edge_count(offset));
    side.loft.Build();
    if (!side.loft.IsDone()) {
        error = "The tapered extrude could not be built";
        return false;
    }
    side.shape = true_planes(side.loft.Shape(), side.trued);
    return true;
}

/// True when a loop turns a sharp corner where an arc meets another edge: a ruled loft to its offset
/// would join their walls along a straight edge, where a drafted wall (a cone) meets its
/// neighbour along a curve.
bool arc_corner(const TopoDS_Wire& wire)
{
    std::vector<TopoDS_Edge> edges;
    for (BRepTools_WireExplorer it(wire); it.More(); it.Next()) {
        edges.push_back(it.Current());
    }
    auto tangent = [](const TopoDS_Edge& edge, bool at_end) {
        BRepAdaptor_Curve curve(edge);
        const bool reversed = edge.Orientation() == TopAbs_REVERSED;
        gp_Pnt point;
        gp_Vec d;
        curve.D1(at_end != reversed ? curve.LastParameter() : curve.FirstParameter(), point, d);
        return reversed ? d.Reversed() : d;
    };
    for (size_t k = 0; k < edges.size() && edges.size() > 1; ++k) {
        const TopoDS_Edge& a = edges[k];
        const TopoDS_Edge& b = edges[(k + 1) % edges.size()];
        const bool round = BRepAdaptor_Curve(a).GetType() == GeomAbs_Circle || BRepAdaptor_Curve(b).GetType() == GeomAbs_Circle;
        const gp_Vec out = tangent(a, true);
        const gp_Vec in = tangent(b, false);
        if (round && out.Magnitude() > 1e-12 && in.Magnitude() > 1e-12 && out.Angle(in) > 1e-6) {
            return true;
        }
    }
    return false;
}

/// A flat face extruded by shift with its walls drafted by taper about the face's plane (inward;
/// holes widen), as a draft of the straight prism: walls of lines stay planes and of arcs become
/// cones, meeting their neighbours along their true intersections. walls gets each edge of the
/// face with its wall, caps the start and end faces. Null when OCCT can't draft it (a wall that
/// isn't a plane or a cylinder: an extrude askew).
TopoDS_Shape drafted_prism(const TopoDS_Face& face, const gp_Vec& shift, double taper, std::vector<std::pair<TopoDS_Shape, TopoDS_Shape>>& walls,
    std::array<TopoDS_Shape, 2>& caps)
{
    BRepPrimAPI_MakePrism prism(face, shift, true);
    if (!prism.IsDone()) {
        return TopoDS_Shape();
    }
    BRepOffsetAPI_DraftAngle draft(prism.Shape());
    const gp_Pln neutral = BRepAdaptor_Surface(face).Plane();
    std::vector<std::pair<TopoDS_Shape, TopoDS_Shape>> made;
    for (TopExp_Explorer e(face, TopAbs_EDGE); e.More(); e.Next()) {
        const TopTools_ListOfShape& generated = prism.Generated(e.Current());
        if (generated.IsEmpty()) {
            continue;
        }
        const TopoDS_Face wall = TopoDS::Face(generated.First());
        made.push_back({e.Current(), wall});
        draft.Add(wall, gp_Dir(shift), taper, neutral);
        if (!draft.AddDone()) {
            return TopoDS_Shape();
        }
    }
    draft.Build();
    if (!draft.IsDone()) {
        return TopoDS_Shape();
    }
    for (const auto& [edge, wall] : made) {
        walls.push_back({edge, draft.ModifiedShape(wall)});
    }
    caps = {draft.ModifiedShape(prism.FirstShape()), draft.ModifiedShape(prism.LastShape())};
    return draft.Shape();
}

/// A closed section re-made to start where rail touches it (at a new vertex when that is partway
/// along an edge), and that vertex; an open section as it is, with a vertex where the rail touches
/// it; a null wire when the rail misses it.
TopoDS_Wire started_at(const TopoDS_Wire& section, const TopoDS_Wire& rail, TopoDS_Vertex& touch)
{
    // Found at LOFT_SIZE (OCCT's distances at 0.5 mm split a circle off the rail, its loft 9e-6
    // off), the touch then placed on the section's own edge.
    const double factor = LOFT_SIZE / std::max(diagonal(make_compound({section, rail})), 1e-12);
    gp_Trsf up;
    up.SetScale(gp::Origin(), factor);
    BRepBuilderAPI_Transform big(section, up, true);
    BRepExtrema_DistShapeShape contact(big.Shape(), BRepBuilderAPI_Transform(rail, up, true).Shape());
    if (!contact.IsDone() || contact.NbSolution() == 0 || contact.Value() / factor > std::max(diagonal(section) * 1e-7, Precision::Confusion())) {
        return TopoDS_Wire();
    }
    const gp_Pnt at = contact.PointOnShape1(1).Transformed(up.Inverted());
    if (!BRep_Tool::IsClosed(section)) {
        touch = BRepBuilderAPI_MakeVertex(at).Vertex();
        return section;
    }
    std::vector<TopoDS_Edge> edges;
    std::vector<TopoDS_Vertex> starts;
    for (BRepTools_WireExplorer it(section); it.More(); it.Next()) {
        edges.push_back(it.Current());
        starts.push_back(it.CurrentVertex());
    }
    size_t first = edges.size();
    if (contact.SupportTypeShape1(1) == BRepExtrema_IsVertex) {
        for (size_t k = 0; k < starts.size() && first == edges.size(); ++k) {
            if (big.ModifiedShape(starts[k]).IsSame(contact.SupportOnShape1(1))) {
                touch = starts[k];
                first = k;
            }
        }
    }
    else if (contact.SupportTypeShape1(1) == BRepExtrema_IsOnEdge) {
        // Split there: the edge's two parts, in the order the wire runs.
        TopoDS_Edge split;
        for (const TopoDS_Edge& edge : edges) {
            split = split.IsNull() && big.ModifiedShape(edge).IsSame(contact.SupportOnShape1(1)) ? edge : split;
        }
        double f = 0.0;
        double l = 0.0;
        const Handle(Geom_Curve) curve = split.IsNull() ? Handle(Geom_Curve)() : BRep_Tool::Curve(split, f, l);
        double t = f;
        if (!curve.IsNull()) {
            gp_Pnt on;
            ShapeAnalysis_Curve().Project(curve, at, 1e-9 * diagonal(section), on, t, f, l, false);
            // At one of its ends (where a split would leave next to nothing): that vertex.
            const double near = std::max(diagonal(section) * 1e-7, Precision::Confusion());
            for (size_t k = 0; k < starts.size() && first == edges.size(); ++k) {
                if (BRep_Tool::Pnt(starts[k]).Distance(at) <= near) {
                    touch = starts[k];
                    first = k;
                }
            }
        }
        for (size_t k = 0; k < edges.size() && first == edges.size() && !curve.IsNull(); ++k) {
            if (!edges[k].IsSame(split)) {
                continue;
            }
            const TopoDS_Edge forward = TopoDS::Edge(split.Oriented(TopAbs_FORWARD));
            touch = BRepBuilderAPI_MakeVertex(curve->Value(t)).Vertex();
            TopoDS_Edge a = BRepBuilderAPI_MakeEdge(curve, TopExp::FirstVertex(forward), touch, f, t).Edge();
            TopoDS_Edge b = BRepBuilderAPI_MakeEdge(curve, touch, TopExp::LastVertex(forward), t, l).Edge();
            if (edges[k].Orientation() == TopAbs_REVERSED) {
                std::swap(a, b);
                a.Reverse();
                b.Reverse();
            }
            edges[k] = b;
            edges.insert(edges.begin() + long(k), a);
            first = k + 1;
        }
    }
    if (first == edges.size()) {
        return TopoDS_Wire();
    }
    BRepBuilderAPI_MakeWire maker;
    for (size_t k = 0; k < edges.size(); ++k) {
        maker.Add(edges[(first + k) % edges.size()]);
    }
    return maker.IsDone() ? maker.Wire() : TopoDS_Wire();
}

/// The part of a rail (a wire) between the points on it nearest a and b, running the way the rail
/// does: the rail itself when those are its ends.
TopoDS_Wire rail_between(const TopoDS_Wire& rail, const gp_Pnt& a, const gp_Pnt& b)
{
    // Each edge's curve, and its parameters where the rail enters and leaves it.
    struct Run
    {
        Handle(Geom_Curve) curve;
        double start;
        double end;
    };
    std::vector<Run> runs;
    for (BRepTools_WireExplorer it(rail); it.More(); it.Next()) {
        double f = 0.0;
        double l = 0.0;
        const Handle(Geom_Curve) curve = BRep_Tool::Curve(it.Current(), f, l);
        if (curve.IsNull()) {
            return rail;
        }
        const bool reversed = it.Current().Orientation() == TopAbs_REVERSED;
        runs.push_back({curve, reversed ? l : f, reversed ? f : l});
    }
    // Where along the rail a point lies: its edge, and how far along that edge (0 to 1). (To a
    // billionth of the rail's size: OCCT's 0.1 um trimmed a 0.5 mm rail short of its sections.)
    const double precision = 1e-9 * diagonal(rail);
    auto locate = [&](const gp_Pnt& point) {
        std::pair<size_t, double> best(0, 0.0);
        double nearest = 1e300;
        for (size_t k = 0; k < runs.size(); ++k) {
            const double lo = std::min(runs[k].start, runs[k].end);
            const double hi = std::max(runs[k].start, runs[k].end);
            gp_Pnt projected;
            double t = lo;
            const double d = ShapeAnalysis_Curve().Project(runs[k].curve, point, precision, projected, t, lo, hi, false);
            if (d < nearest) {
                nearest = d;
                best = {k, (t - runs[k].start) / (runs[k].end - runs[k].start)};
            }
        }
        return best;
    };
    if (runs.empty()) {
        return rail;
    }
    std::pair<size_t, double> from = locate(a);
    std::pair<size_t, double> to = locate(b);
    if (to < from) {
        std::swap(from, to);
    }
    const double tiny = 1e-9;
    if ((from.first == 0 && from.second <= tiny && to.first + 1 == runs.size() && to.second >= 1.0 - tiny) || from == to) {
        return rail;
    }
    BRepBuilderAPI_MakeWire maker;
    for (size_t k = from.first; k <= to.first; ++k) {
        const double s0 = k == from.first ? from.second : 0.0;
        const double s1 = k == to.first ? to.second : 1.0;
        if (s1 - s0 <= tiny) {
            continue;
        }
        const double t0 = runs[k].start + (runs[k].end - runs[k].start) * s0;
        const double t1 = runs[k].start + (runs[k].end - runs[k].start) * s1;
        TopoDS_Edge piece = BRepBuilderAPI_MakeEdge(runs[k].curve, std::min(t0, t1), std::max(t0, t1)).Edge();
        if (t0 > t1) {
            piece.Reverse();
        }
        maker.Add(piece);
        if (!maker.IsDone()) {
            return rail;
        }
    }
    return maker.IsDone() ? maker.Wire() : rail;
}

/// The middle and normal of a flat loop as OCCT's loft matching takes them: a lone circle's or
/// ellipse's centre, else the middle of its length. False when the loop isn't flat.
bool loop_plane(const TopoDS_Wire& loop, gp_Pnt& middle, gp_Vec& normal)
{
    BRepLib_FindSurface found(loop, -1, true);
    if (!found.Found()) {
        return false;
    }
    Handle(Geom_Surface) surface = found.Surface();
    if (!found.Location().IsIdentity()) {
        surface = Handle(Geom_Surface)::DownCast(surface->Transformed(found.Location().Transformation()));
    }
    const Handle(Geom_Plane) plane = Handle(Geom_Plane)::DownCast(surface);
    if (plane.IsNull()) {
        return false;
    }
    normal = gp_Vec(plane->Pln().Axis().Direction());
    if (edge_count(loop) == 1) {
        double f = 0.0;
        double l = 0.0;
        const Handle(Geom_Curve) curve = BRep_Tool::Curve(TopoDS::Edge(TopoDS_Iterator(loop).Value()), f, l);
        GeomAdaptor_Curve adaptor(curve);
        if (adaptor.GetType() == GeomAbs_Circle || adaptor.GetType() == GeomAbs_Ellipse) {
            middle = adaptor.GetType() == GeomAbs_Circle ? adaptor.Circle().Location() : adaptor.Ellipse().Location();
            return true;
        }
    }
    GProp_GProps props;
    BRepGProp::LinearProperties(loop, props);
    middle = props.CentreOfMass();
    return true;
}

/// The move that carries a loop whose plane is at from, facing from_normal, into the plane at to,
/// facing to_normal, as OCCT's loft matching carries corners from loop to loop.
gp_Trsf carrying(const gp_Pnt& from, gp_Vec from_normal, const gp_Pnt& to, gp_Vec to_normal)
{
    gp_Trsf move;
    move.SetTranslation(from, to);
    if (from_normal.IsParallel(to_normal, 1e-4)) {
        return move;
    }
    const gp_Vec shift(from, to);
    if (shift.Dot(from_normal) < -1e-7) {
        from_normal *= -1.0;
    }
    if (shift.Dot(to_normal) < 1e-7) {
        to_normal *= -1.0;
    }
    const gp_Vec turn_axis = from_normal ^ to_normal;
    gp_Vec sign_of;
    sign_of.SetLinearForm(shift.Dot(from_normal), to_normal, -shift.Dot(to_normal), from_normal);
    const double alpha = sign_of.Dot(from_normal);
    const double beta = sign_of.Dot(to_normal);
    const double sign = alpha * beta > 0.0 && std::abs(alpha) > 1e-4 && std::abs(beta) > 1e-4 ? -1.0 : 1.0;
    gp_Trsf turn;
    turn.SetRotation(gp_Ax1(to, turn_axis), sign * from_normal.AngleWithRef(to_normal, turn_axis));
    return turn * move;
}

/// point (of a loop whose plane is at from, facing from_normal) carried into the plane at to,
/// facing to_normal (see carrying).
gp_Pnt carried_into(const gp_Pnt& point, const gp_Pnt& from, const gp_Vec& from_normal, const gp_Pnt& to, const gp_Vec& to_normal)
{
    return point.Transformed(carrying(from, from_normal, to, to_normal));
}

/// Which way a flat loop runs round middle from where it starts: (start - middle) x its heading
/// there. Zero when it has no edge.
gp_Vec loop_turn(const TopoDS_Wire& loop, const gp_Pnt& middle)
{
    const BRepTools_WireExplorer first(loop);
    if (!first.More()) {
        return gp_Vec(0.0, 0.0, 0.0);
    }
    const TopoDS_Edge& edge = first.Current();
    const BRepAdaptor_Curve curve(edge);
    const bool reversed = edge.Orientation() == TopAbs_REVERSED;
    gp_Pnt start;
    gp_Vec heading;
    curve.D1(reversed ? curve.LastParameter() : curve.FirstParameter(), start, heading);
    if (reversed) {
        heading.Reverse();
    }
    return gp_Vec(middle, start).Crossed(heading);
}

/// A loop of edges remade to start at the corner, and run the way round, that puts its corners
/// nearest previous's (as many), carried by carry (into its plane, see carrying): the loop itself
/// when it already does.
TopoDS_Wire corner_aligned(const TopoDS_Wire& loop, const TopoDS_Wire& previous, const gp_Trsf& carry)
{
    std::vector<TopoDS_Edge> edges;
    std::vector<gp_Pnt> corners;
    for (BRepTools_WireExplorer it(loop); it.More(); it.Next()) {
        edges.push_back(it.Current());
        corners.push_back(BRep_Tool::Pnt(it.CurrentVertex()));
    }
    std::vector<gp_Pnt> targets;
    for (BRepTools_WireExplorer it(previous); it.More(); it.Next()) {
        targets.push_back(BRep_Tool::Pnt(it.CurrentVertex()).Transformed(carry));
    }
    const size_t n = edges.size();
    if (n < 2 || targets.size() != n) {
        return loop;
    }
    double best = 1e300;
    size_t start = 0;
    bool backward = false;
    for (const bool back : {false, true}) {
        for (size_t k = 0; k < n; ++k) {
            double cost = 0.0;
            for (size_t i = 0; i < n; ++i) {
                cost += targets[i].SquareDistance(corners[back ? (k + n - i) % n : (k + i) % n]);
            }
            // (A tie keeps the loop as it was drawn.)
            if (cost < best * (1.0 - 1e-9)) {
                best = cost;
                start = k;
                backward = back;
            }
        }
    }
    if (start == 0 && !backward) {
        return loop;
    }
    BRepBuilderAPI_MakeWire maker;
    for (size_t i = 0; i < n; ++i) {
        maker.Add(backward ? TopoDS::Edge(edges[(start + n - 1 - i) % n].Reversed()) : edges[(start + i) % n]);
    }
    return maker.IsDone() ? maker.Wire() : loop;
}

/// A loop of one round edge (a circle, an ellipse, a periodic spline) remade to start where the
/// ray from middle toward at (in its plane, facing normal) meets it, running the same way; the
/// loop itself when it is anything else or the ray misses it.
TopoDS_Wire round_started(const TopoDS_Wire& loop, const gp_Pnt& middle, const gp_Vec& normal, const gp_Pnt& at)
{
    if (edge_count(loop) != 1) {
        return loop;
    }
    const TopoDS_Edge edge = TopoDS::Edge(TopoDS_Iterator(loop).Value());
    double f = 0.0;
    double l = 0.0;
    const Handle(Geom_Curve) curve = BRep_Tool::Curve(edge, f, l);
    if (curve.IsNull() || !curve->IsPeriodic() || std::abs(l - f - curve->Period()) > 1e-9 * curve->Period()) {
        return loop;
    }
    Handle(Geom_Curve) basis = curve;
    for (Handle(Geom_TrimmedCurve) trimmed = Handle(Geom_TrimmedCurve)::DownCast(basis); !trimmed.IsNull(); trimmed = Handle(Geom_TrimmedCurve)::DownCast(basis)) {
        basis = trimmed->BasisCurve();
    }
    const Handle(Geom_BSplineCurve) spline = Handle(Geom_BSplineCurve)::DownCast(basis);
    if (!basis->IsKind(STANDARD_TYPE(Geom_Conic)) && spline.IsNull()) {
        return loop;
    }
    gp_Vec toward(middle, at);
    toward -= normal.Normalized() * toward.Dot(normal.Normalized());
    if (toward.Magnitude() < 1e-12) {
        return loop;
    }
    const gp_Dir x(toward);
    const gp_Dir y(normal.Normalized().Crossed(gp_Vec(x)));
    auto angle = [&](double t) {
        const gp_Vec d(middle, curve->Value(t));
        return std::atan2(d.Dot(gp_Vec(y)), d.Dot(gp_Vec(x)));
    };
    // Where the angle round the middle passes zero (not where it wraps round at a half turn): a
    // point already on the ray is taken as it is (halving toward the side the angle starts on put
    // a loop starting on the ray, its angle 0, a sample further round).
    const int samples = 72;
    double before = f;
    double was = angle(f);
    double start = f;
    bool found = false;
    for (int i = 1; i <= samples && !found; ++i) {
        const double t = f + (l - f) * i / samples;
        const double now = angle(t);
        if (std::abs(was) <= 1e-12) {
            start = before;
            found = true;
        }
        else if (((was < 0.0 && now >= 0.0) || (was > 0.0 && now <= 0.0)) && std::abs(now - was) < M_PI) {
            double lo = before;
            double hi = t;
            for (int k = 0; k < 60; ++k) {
                const double mid = 0.5 * (lo + hi);
                const double there = angle(mid);
                if ((there < 0.0) == (was < 0.0) && there != 0.0) {
                    lo = mid;
                }
                else {
                    hi = mid;
                }
            }
            start = 0.5 * (lo + hi);
            found = true;
        }
        before = t;
        was = now;
    }
    if (!found) {
        return loop;
    }
    TopoDS_Edge remade;
    if (spline.IsNull()) {
        remade = BRepBuilderAPI_MakeEdge(basis, start, start + (l - f)).Edge();
    }
    else {
        const Handle(Geom_BSplineCurve) turned = Handle(Geom_BSplineCurve)::DownCast(spline->Copy());
        turned->SetOrigin(start, Precision::PConfusion());
        remade = BRepBuilderAPI_MakeEdge(turned, turned->FirstParameter(), turned->LastParameter()).Edge();
    }
    if (edge.Orientation() == TopAbs_REVERSED) {
        remade.Reverse();
    }
    BRepBuilderAPI_MakeWire wire(remade);
    return wire.IsDone() ? wire.Wire() : loop;
}

/// What became of a face in a boolean: itself, the faces it was cut into, or nothing.
TopoDS_Shape carried(BRepBuilderAPI_MakeShape& op, const TopoDS_Shape& face)
{
    if (face.IsNull()) {
        return face;
    }
    const TopTools_ListOfShape& modified = op.Modified(face);
    if (!modified.IsEmpty()) {
        std::vector<TopoDS_Shape> pieces;
        for (TopTools_ListOfShape::Iterator it(modified); it.More(); it.Next()) {
            pieces.push_back(it.Value());
        }
        return make_compound(pieces);
    }
    return op.IsDeleted(face) ? TopoDS_Shape() : face;
}

/// The finest deflection the checks mesh to: OCCT's mesher refuses one (and half of it, the
/// smallest triangle side asked for) under its confusion tolerance (a 0.5 mm box offset in by
/// 5 um was refused as "it could not be checked" for it).
constexpr double MESH_DEFLECTION_FLOOR = 2.0 * 1e-7;

/// A solid's volume from a fine mesh of its faces (OCCT's volume integral reads some broken solids
/// far off), or -1 when a face has no mesh. The mesh is cleared again.
double mesh_volume(const TopoDS_Shape& s, double deflection)
{
    BRepMesh_IncrementalMesh mesher(s, std::max(deflection, MESH_DEFLECTION_FLOOR), false, 0.1, false);
    double total = 0.0;
    bool meshed = true;
    for (TopExp_Explorer it(s, TopAbs_FACE); it.More() && meshed; it.Next()) {
        const TopoDS_Face& face = TopoDS::Face(it.Current());
        TopLoc_Location location;
        const Handle(Poly_Triangulation) mesh = BRep_Tool::Triangulation(face, location);
        if (mesh.IsNull()) {
            meshed = false;
            break;
        }
        const gp_Trsf place = location.Transformation();
        const bool reversed = face.Orientation() == TopAbs_REVERSED;
        for (int t = 1; t <= mesh->NbTriangles(); ++t) {
            int a = 0;
            int b = 0;
            int c = 0;
            mesh->Triangle(t).Get(a, b, c);
            if (reversed) {
                std::swap(b, c);
            }
            const gp_XYZ pa = mesh->Node(a).Transformed(place).XYZ();
            const gp_XYZ pb = mesh->Node(b).Transformed(place).XYZ();
            const gp_XYZ pc = mesh->Node(c).Transformed(place).XYZ();
            total += pa.Dot(pb.Crossed(pc)) / 6.0;
        }
    }
    BRepTools::Clean(s);
    return meshed ? total : -1.0;
}

/// True when a face comes to a sharp point (a cone's apex): next to one of its degenerate edges the
/// surface's normal turns round the point and back, or turns too far. A sphere's pole is smooth
/// (its normals there agree); a lens patch's round end turns them by its corner's angle only, from
/// one side's face's way to the other's, and thickens true.
bool sharp_point(const TopoDS_Face& face)
{
    BRepAdaptor_Surface surface(face);
    double u1 = 0.0, u2 = 0.0, v1 = 0.0, v2 = 0.0;
    BRepTools::UVBounds(face, u1, u2, v1, v2);
    const gp_XY middle(0.5 * (u1 + u2), 0.5 * (v1 + v2));
    for (TopExp_Explorer e(face, TopAbs_EDGE); e.More(); e.Next()) {
        const TopoDS_Edge& edge = TopoDS::Edge(e.Current());
        double f = 0.0;
        double l = 0.0;
        const Handle(Geom2d_Curve) pcurve = BRep_Tool::Degenerated(edge) ? BRep_Tool::CurveOnSurface(edge, face, f, l) : Handle(Geom2d_Curve)();
        if (pcurve.IsNull()) {
            continue;
        }
        std::vector<gp_Dir> normals;
        for (int i = 0; i <= 8; ++i) {
            const gp_XY at = pcurve->Value(f + (l - f) * i / 8.0).XY();
            const gp_XY in = at + (middle - at) * 1e-3;
            gp_Pnt p;
            gp_Vec du;
            gp_Vec dv;
            surface.D1(in.X(), in.Y(), p, du, dv);
            if (du.Crossed(dv).Magnitude() > 1e-30) {
                normals.push_back(gp_Dir(du.Crossed(dv)));
            }
        }
        double spread = 0.0;
        for (size_t i = 0; i < normals.size(); ++i) {
            for (size_t j = i + 1; j < normals.size(); ++j) {
                spread = std::max(spread, normals[i].Angle(normals[j]));
            }
        }
        const bool back = normals.size() > 1 && normals.front().Angle(normals.back()) < M_PI / 180.0;
        if (spread > 5.0 * M_PI / 180.0 && (back || spread > 50.0 * M_PI / 180.0)) {
            return true;
        }
    }
    return false;
}

/// True when every shell of s is closed and manifold: each edge (but degenerate ones) joins two
/// faces, or is a seam of one; false for a shape without shells.
bool shells_closed(const TopoDS_Shape& s)
{
    bool any = false;
    for (TopExp_Explorer sh(s, TopAbs_SHELL); sh.More(); sh.Next()) {
        any = true;
        TopTools_IndexedDataMapOfShapeListOfShape edge_faces;
        TopExp::MapShapesAndAncestors(sh.Current(), TopAbs_EDGE, TopAbs_FACE, edge_faces);
        for (int i = 1; i <= edge_faces.Extent(); ++i) {
            const TopoDS_Edge& edge = TopoDS::Edge(edge_faces.FindKey(i));
            if (BRep_Tool::Degenerated(edge)) {
                continue;
            }
            std::vector<TopoDS_Shape> faces;
            for (TopTools_ListOfShape::Iterator it(edge_faces(i)); it.More(); it.Next()) {
                if (std::none_of(faces.begin(), faces.end(), [&](const TopoDS_Shape& f) { return f.IsSame(it.Value()); })) {
                    faces.push_back(it.Value());
                }
            }
            if (faces.size() > 2 || (faces.size() == 1 && !BRep_Tool::IsClosed(edge, TopoDS::Face(faces[0])))) {
                return false;
            }
        }
    }
    return any;
}

/// A progress indicator that asks OCCT's algorithms to stop once a time budget is spent: those
/// that look for a user break between their steps (booleans, offsets, thick solids). One step
/// can't be cut short, so a stop comes at the end of the step running then.
class Deadline: public Message_ProgressIndicator
{
public:
    explicit Deadline(double seconds) : end(std::chrono::steady_clock::now() + std::chrono::duration_cast<std::chrono::steady_clock::duration>(std::chrono::duration<double>(seconds)))
    {
    }

    bool UserBreak() override
    {
        if (!passed.load() && std::chrono::steady_clock::now() > end) {
            passed.store(true);
        }
        return passed.load();
    }

    void Show(const Message_ProgressScope&, const bool) override
    {
    }

    bool expired() const
    {
        return passed.load();
    }

private:
    std::chrono::steady_clock::time_point end;
    // (OCCT may ask from its worker threads.)
    std::atomic<bool> passed{false};
};

double g_time_limit = 20.0;

/// "The cut took too long (over 20 s) and was stopped": the error for an operation its deadline
/// stopped.
String too_long(const char* what)
{
    char text[200];
    std::snprintf(text, sizeof(text), "The %s took too long (over %.0f s) and was stopped", what, g_time_limit);
    return String::utf8(text);
}

/// What a refusal says when the geometry kernel faulted inside an operation and was caught
/// (guard::run_guarded): OCCT's offset reads through a null pointer on some bodies of flat facets
/// (an access violation in its topology library, in about half the runs of a 338-face block with
/// crossing holes shelled from one face), which took the editor down with it.
const char* const KERNEL_FAULT = "the geometry kernel broke down on this body (a fault inside it was caught and it was stopped; the body is as it was)";

/// Runs one OCCT call that can fault (its offsets and thick solids): false when it did, and what
/// it was building must then be let go of unused, not destroyed (it may be half made).
bool survived(const std::function<void()>& work)
{
    return guard::run_guarded(0.0, work) != guard::Outcome::crashed;
}

/// The error for an operation stopped before its later steps (making its walls, or the checks of
/// what it made) because they would not have fitted in what was left of the time limit: seconds
/// is how long it had run.
String too_long_ahead(const char* what, double seconds)
{
    char text[240];
    std::snprintf(text, sizeof(text), "The %s was stopped after %.0f s: the rest of it would have run past the %.0f s time limit (a body of fewer faces takes less)", what,
                  seconds, g_time_limit);
    return String::utf8(text);
}

/// The box of a mesh of s made within deflection and angle (on a copy that shares its geometry,
/// so s keeps whatever mesh it had): the mesh's points lie on the faces, and the true box is about
/// the deflection wider at most. (OCCT's optimal box of a converted form body's spline faces took
/// 3 to 8 s, and of single faces it used their whole parameter range, which a blend's faces can
/// overrun by millimetres; this takes a tenth of a second.) meshed, when given, takes the meshed
/// copy.
Bnd_Box mesh_box(const TopoDS_Shape& s, double deflection, double angle, double min_size, bool& stopped, TopoDS_Shape* meshed = nullptr)
{
    Bnd_Box box;
    stopped = false;
    if (s.IsNull()) {
        return box;
    }
    BRepBuilderAPI_Copy copier(s, false, false);
    const TopoDS_Shape copy = copier.Shape();
    if (meshed != nullptr) {
        *meshed = copy;
    }
    IMeshTools_Parameters params;
    deflection = std::max(deflection, MESH_DEFLECTION_FLOOR);
    min_size = std::max(min_size, 0.5 * MESH_DEFLECTION_FLOOR);
    params.Deflection = deflection;
    params.DeflectionInterior = deflection;
    params.Angle = angle;
    params.AngleInterior = angle;
    // Bounded: a fine angle alone once meshed a blend's sliver face for 200 s.
    params.MinSize = min_size;
    // Measured against the faces themselves on every kind of surface: by default only some kinds
    // are, and a chamfer face 0.1 mm out past a flat cap was meshed flat.
    params.ControlSurfaceDeflection = true;
    params.EnableControlSurfaceDeflectionAllSurfaces = true;
    params.InParallel = false;
    const Handle(Deadline) clock = new Deadline(std::min(2.0, g_time_limit));
    BRepMesh_IncrementalMesh mesher(copy, params, clock->Start());
    if (clock->expired()) {
        stopped = true;
        return Bnd_Box();
    }
    for (TopExp_Explorer it(copy, TopAbs_FACE); it.More(); it.Next()) {
        const TopoDS_Face& face = TopoDS::Face(it.Current());
        TopLoc_Location location;
        const Handle(Poly_Triangulation) mesh = BRep_Tool::Triangulation(face, location);
        if (mesh.IsNull() || mesh->NbNodes() == 0) {
            // (No mesh: the face's own box, which is never smaller than the face.)
            BRepBndLib::Add(face, box, false);
            continue;
        }
        const gp_Trsf place = location.Transformation();
        for (int n = 1; n <= mesh->NbNodes(); ++n) {
            box.Add(mesh->Node(n).Transformed(place));
        }
    }
    return box;
}

/// The deflection and smallest triangle side (of the body's size) that a blend's body and the faces it
/// made are meshed to for their boxes (at 0.1 rad): about a tenth of a second for a converted form body.
constexpr double BLEND_BOX_DEFLECTION = 5e-4;

/// The fit of the attempt before OCCT's own tolerances (see blended): a tenth of them. Where the
/// closer fits build nothing, OCCT's own 0.1 mm fit of its surfaces leaves corners millimetres off
/// their edges on a 20 mm spline body's 2.6 to 3.9 mm fillets (blend_problem refuses those); at
/// 0.01 mm the same fillets come out sound, their corners within 0.02 mm of their edges. (At 1 um
/// and at 0.03 mm they ran out of time or came out as broken.)
constexpr double BLEND_TENTH_FIT = 1e-5;

/// The time a fillet or chamfer may take in all (s), and more for each edge (see blended).
constexpr double BLEND_SECONDS = 3.0;
constexpr double BLEND_SECONDS_PER_EDGE = 0.5;

/// What a blend's result is checked against: the body before it.
struct BlendReference
{
    int solids = 0;
    bool closed = false;
    bool valid = false;
    double volume = 0.0;
    double size = 1.0;
    Bnd_Box box;
    TopTools_IndexedMapOfShape faces;
    std::vector<const Geom_Surface*> surfaces;  // its faces' surfaces, sorted
};

BlendReference blend_reference(const TopoDS_Shape& shape)
{
    BlendReference r;
    r.solids = map_of(shape, TopAbs_SOLID).Extent();
    r.closed = r.solids > 0 && shells_closed(shape);
    r.valid = BRepCheck_Analyzer(shape).IsValid();
    r.volume = r.solids > 0 ? measure::volume(shape).Mass() : 0.0;
    r.size = diagonal(shape);
    bool stopped = false;
    r.box = mesh_box(shape, BLEND_BOX_DEFLECTION * r.size, 0.1, BLEND_BOX_DEFLECTION * r.size, stopped);
    r.faces = map_of(shape, TopAbs_FACE);
    for (int i = 1; i <= r.faces.Extent(); ++i) {
        r.surfaces.push_back(BRep_Tool::Surface(TopoDS::Face(r.faces(i))).get());
    }
    std::sort(r.surfaces.begin(), r.surfaces.end());
    return r;
}

/// The box of the faces of after that before didn't have (the ones a blend made or changed: the
/// only ones that can reach outside), from a mesh of just those (stopped when that ran too long;
/// meshed, when given, takes those faces' meshed copy).
Bnd_Box new_faces_box(const BlendReference& before, const TopoDS_Shape& after, bool& stopped, TopoDS_Shape* meshed = nullptr)
{
    stopped = false;
    std::vector<TopoDS_Shape> fresh;
    for (TopExp_Explorer it(after, TopAbs_FACE); it.More(); it.Next()) {
        if (!before.faces.Contains(it.Current())) {
            fresh.push_back(it.Current());
        }
    }
    if (fresh.empty()) {
        return Bnd_Box();
    }
    return mesh_box(make_compound(fresh), BLEND_BOX_DEFLECTION * before.size, 0.1, BLEND_BOX_DEFLECTION * before.size, stopped, meshed);
}

/// How far a face a blend made or changed may have its edges stray from it (measure::edge_stray),
/// of the blend's size (its radius or distance): past this the blend is broken. OCCT's blends at
/// its own loose tolerances leave corners 1.7 to 2.6 mm off the edges that meet there on a 20 mm
/// spline body's 2.6 to 3.9 mm fillets (corners with tolerances of 3 to 5 mm, so its own check
/// passes them); the sound ones stay within 0.3 % of the blend's size at the close fits and 0.8 %
/// at a tenth of OCCT's own.
constexpr double BLEND_STRAY = 0.02;

/// A stray this small (of the blend's size) is never looked at, and above it a face is broken
/// when its edges' stray could throw its area off by more than this part of it (the stray along
/// half its outline): a sliver a blend left at a corner, 0.26 mm2 with a corner 6 um off its
/// edges, meshes 7 % over its area at every deflection.
constexpr double BLEND_STRAY_FLOOR = 1e-3;
constexpr double BLEND_STRAY_AREA = 0.02;

/// How much of a face a blend made may lie folded over itself (measure::fold_area), of its area:
/// a fillet's surface fitted with a wrinkle had 3 % of it back to front, while a sound chamfer's
/// surface pinched to nothing at one corner turns over there on less than a millionth of it.
constexpr double BLEND_FOLD = 1e-3;

/// Why a fillet's or chamfer's result can't be right, or "". OCCT's ChFi3d can report success and
/// hand back a broken body, most of all on spline bodies (converted form bodies): faces tens of
/// metres outside a 50 mm part with a negative volume, a chamfer face sticking out past a flat cap,
/// or a shell left open (a 'solid' of no volume). A blend only takes material off an edge or fills
/// a corner between faces, so its result keeps the body's solids, stays closed and valid when the
/// body was, has a volume above 0, and stays inside the body's box (to within slack).
/// It can also hand back a body its own check passes whose corners lie millimetres off the edges
/// that meet there (their tolerances made to match): the mesh of every face around such a corner
/// is pulled off the face, so the body shows and exports wrong at any deflection. The faces the
/// blend made or changed must have their edges on them (to within BLEND_STRAY of blend_size, the
/// blend's radius or distance, and less on a sliver: BLEND_STRAY_AREA), the surfaces it made must
/// not fold over themselves (measure::fold_area: a fillet's surface fitted with a wrinkle in it),
/// and their mesh must cover them (measure::face_drawable).
std::string blend_problem(const BlendReference& before, const TopoDS_Shape& after, double slack, double blend_size)
{
    if (after.IsNull()) {
        return "it came out empty";
    }
    if (map_of(after, TopAbs_SOLID).Extent() != before.solids) {
        return "it changed how many solids the body has";
    }
    if (before.closed && !shells_closed(after)) {
        return "its faces don't close";
    }
    if (before.solids > 0) {
        const double volume = measure::volume(after).Mass();
        double box_volume = 0.0;
        if (!before.box.IsVoid()) {
            double x0, y0, z0, x1, y1, z1;
            before.box.Get(x0, y0, z0, x1, y1, z1);
            const double pad = 2.0 * (slack + BLEND_BOX_DEFLECTION * before.size);
            box_volume = (x1 - x0 + pad) * (y1 - y0 + pad) * (z1 - z0 + pad);
        }
        if (!(volume > 1e-9 * std::abs(before.volume)) || (box_volume > 0.0 && volume > box_volume)) {
            return "its volume came out wrong";
        }
    }
    if (!before.box.IsVoid()) {
        // The body's box is of a mesh, whose points lie on its faces: it reaches them only to
        // within the deflection, so just what is out by more (and slack) counts.
        const double deflection = BLEND_BOX_DEFLECTION * before.size;
        bool stopped = false;
        TopoDS_Shape fresh_meshed;
        const Bnd_Box box = new_faces_box(before, after, stopped, &fresh_meshed);
        // (When meshing the faces ran too long they go unchecked here; the other checks hold.)
        if (!stopped && box.IsVoid()) {
            return before.faces.Extent() == map_of(after, TopAbs_FACE).Extent() ? "it changed nothing" : "it came out empty";
        }
        if (!stopped) {
            double a0, b0, c0, a1, b1, c1, x0, y0, z0, x1, y1, z1;
            before.box.Get(a0, b0, c0, a1, b1, c1);
            box.Get(x0, y0, z0, x1, y1, z1);
            const double out = std::max({a0 - x0, b0 - y0, c0 - z0, x1 - a1, y1 - b1, z1 - c1});
            if (out > slack + deflection) {
                char text[160];
                std::snprintf(text, sizeof(text), "it reaches %.3g mm outside the body", out * 1000.0);
                return text;
            }
        }
        // The new faces' edges on them, and their mesh on them.
        const double size = std::abs(blend_size);
        for (TopExp_Explorer it(after, TopAbs_FACE); size > 0.0 && it.More(); it.Next()) {
            if (before.faces.Contains(it.Current())) {
                continue;
            }
            const TopoDS_Face& face = TopoDS::Face(it.Current());
            gp_Pnt at;
            bool corner = false;
            const double stray = measure::edge_stray(face, &at, &corner);
            if (!(stray > BLEND_STRAY_FLOOR * size)) {
                continue;
            }
            double area = 0.0;
            bool broken = stray > BLEND_STRAY * size;
            if (!broken) {
                double outline = 0.0;
                for (TopExp_Explorer edge(face, TopAbs_EDGE); edge.More(); edge.Next()) {
                    outline += measure::length(TopoDS::Edge(edge.Current()));
                }
                area = std::abs(measure::surface(face).Mass());
                broken = 0.5 * stray * outline > BLEND_STRAY_AREA * area;
            }
            if (broken) {
                char text[256];
                if (area > 0.0) {
                    std::snprintf(text, sizeof(text), "%s of its sliver of a face (%.3g mm2) around (%.1f, %.1f, %.1f) mm lies %.3g mm off %s, too far for a face so narrow",
                                  corner ? "a corner" : "an edge", area * 1e6, at.X() * 1000.0, at.Y() * 1000.0, at.Z() * 1000.0, stray * 1000.0,
                                  corner ? "the edges that meet there" : "the face");
                }
                else {
                    std::snprintf(text, sizeof(text), "%s of it at (%.1f, %.1f, %.1f) mm lies %.3g mm off %s", corner ? "a corner" : "an edge", at.X() * 1000.0,
                                  at.Y() * 1000.0, at.Z() * 1000.0, stray * 1000.0, corner ? "the edges that meet there" : "the face it bounds");
                }
                return text;
            }
        }
        // The surfaces the blend made (not the body's own, trimmed anew) must not fold.
        for (TopExp_Explorer it(after, TopAbs_FACE); it.More(); it.Next()) {
            if (before.faces.Contains(it.Current())) {
                continue;
            }
            const TopoDS_Face& face = TopoDS::Face(it.Current());
            const GeomAbs_SurfaceType kind = BRepAdaptor_Surface(face, false).GetType();
            if (kind == GeomAbs_Plane || kind == GeomAbs_Cylinder || kind == GeomAbs_Cone || kind == GeomAbs_Sphere || kind == GeomAbs_Torus ||
                std::binary_search(before.surfaces.begin(), before.surfaces.end(), BRep_Tool::Surface(face).get())) {
                continue;
            }
            gp_Pnt at;
            const double folded = measure::fold_area(face, &at);
            if (folded > 0.0 && folded > BLEND_FOLD * std::abs(measure::surface(face).Mass())) {
                char text[200];
                std::snprintf(text, sizeof(text), "its face at (%.1f, %.1f, %.1f) mm is folded over itself", at.X() * 1000.0, at.Y() * 1000.0, at.Z() * 1000.0);
                return text;
            }
        }
        for (TopExp_Explorer it(fresh_meshed, TopAbs_FACE); !stopped && it.More(); it.Next()) {
            const TopoDS_Face& face = TopoDS::Face(it.Current());
            double own = 0.0, covered = 0.0, off = 0.0;
            const double stray_limit = std::max(4.0 * deflection, BLEND_STRAY * size);
            if (!measure::face_drawable(face, deflection, 0.1, &own, &covered, &off, stray_limit, true)) {
                const gp_Pnt at = measure::surface(face).CentreOfMass();
                char text[256];
                if (off > stray_limit) {
                    std::snprintf(text, sizeof(text), "its face around (%.1f, %.1f, %.1f) mm meshes up to %.3g mm off the face", at.X() * 1000.0, at.Y() * 1000.0,
                                  at.Z() * 1000.0, off * 1000.0);
                }
                else {
                    std::snprintf(text, sizeof(text), "its face around (%.1f, %.1f, %.1f) mm meshes to %.4g mm2 against the face's own %.4g mm2", at.X() * 1000.0,
                                  at.Y() * 1000.0, at.Z() * 1000.0, covered * 1e6, std::abs(own) * 1e6);
                }
                return text;
            }
        }
    }
    if (before.valid && !BRepCheck_Analyzer(after).IsValid()) {
        return "its faces don't fit together";
    }
    return "";
}

/// A fillet or chamfer of shape (add gives it its edges, edges of them) built with tolerances for
/// its size: within FIT of it, then 10 and 100 times looser, then at a tenth of OCCT's own
/// (BLEND_TENTH_FIT) and at OCCT's own (0.1 mm for points and fitted surfaces, 1 mm for its
/// marching step), which refused to round a dome's rim, a spline wall's edge or a cut torus' at
/// any size, and built the rest less closely; note says so when only one of those two worked.
/// Null when none did. The spatial and fit tolerances never go below OCCT's
/// Precision::Confusion (0.1 um, the smallest tolerance its geometry works to), and an attempt
/// whose tolerance came out as the one before (a body under a metre) isn't run again.
/// ChFi3d takes no progress range, and on spline bodies (converted form bodies) it can march and
/// fit its surface for many minutes at any of these tolerances (a 35 mm body's single-edge fillet
/// at 2.9 mm never returned; at 1 um other edges and radii did), so every attempt runs under a time
/// bound (guard::run_bounded): one that runs out counts as failed, and stopped says so when that is
/// why none was built. The whole blend gets BLEND_SECONDS plus a little per edge.
/// Every result OCCT reports done is checked (blend_problem): a broken one counts as a failed
/// attempt, and when no attempt gives a sound result, problem says what was wrong with the last.
/// blend_size is the blend's smallest radius or distance (see blend_problem).
template <typename Maker>
std::unique_ptr<Maker> blended(const TopoDS_Shape& shape, const std::function<void(Maker&)>& add, int edges, double blend_size, const char* what, String& note,
                               std::string& problem, bool& stopped)
{
    const auto start = std::chrono::steady_clock::now();
    const double budget = std::min(g_time_limit, BLEND_SECONDS + BLEND_SECONDS_PER_EDGE * std::max(edges, 1));
    const BlendReference reference = blend_reference(shape);
    const double size = reference.size;
    problem.clear();
    stopped = false;
    double previous = -1.0;
    for (int attempt = 0; attempt < 5; ++attempt) {
        // OCCT's own tolerances (the last attempt) fit its points and surfaces to 0.1 mm.
        const bool tenth = attempt == 3;
        const bool own = attempt == 4;
        double tolerance = 1e-4;
        double fit = 0.0;
        if (attempt < 3) {
            fit = FIT * std::pow(10.0, attempt) * size;
            tolerance = std::max(fit, Precision::Confusion());
            if (tolerance == previous) {
                continue;
            }
            previous = tolerance;
        }
        else if (tenth) {
            // (Not when the attempts before were as loose already: a body of metres.)
            tolerance = BLEND_TENTH_FIT;
            if (tolerance <= previous) {
                continue;
            }
        }
        const double left = budget - std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
        if (left <= 0.05) {
            stopped = true;
            break;
        }
        auto maker = std::make_unique<Maker>(shape);
        if (attempt < 3) {
            maker->SetParams(1e-2, tolerance, 1e-5, tolerance, 1e-5, 1e3 * fit);
        }
        else if (tenth) {
            maker->SetParams(1e-2, tolerance, 1e-5, tolerance, 1e-5, 1e-3);
        }
        add(*maker);
        bool failed = false;
        // (Half of what is left, all of it for OCCT's own tolerances: a later attempt gets a turn.)
        const guard::Outcome outcome = guard::run_guarded(own ? left : 0.5 * left, [&] {
            try {
                maker->Build();
            }
            catch (const Standard_Failure&) {
                failed = true;
            }
        });
        if (outcome == guard::Outcome::crashed) {
            // (A fault inside OCCT's blend, caught: a failed attempt, its builder let go of as it is.)
            (void)maker.release();
            problem = "the geometry kernel broke down while building it";
            continue;
        }
        if (outcome == guard::Outcome::stopped) {
            stopped = true;
            continue;
        }
        if (failed) {
            continue;
        }
        if (maker->IsDone()) {
            const std::string wrong = blend_problem(reference, maker->Shape(), (attempt < 3 ? 10.0 : 1.0) * tolerance + 1e-6 * size, blend_size);
            if (!wrong.empty()) {
                problem = wrong;
                continue;
            }
            if (tenth) {
                note = String("The ") + what + " is fitted only to within 0.01 mm (a closer fit could not be built)";
            }
            if (own) {
                note = String("The ") + what + " is fitted only to within 0.1 mm (a closer fit could not be built)";
            }
            return maker;
        }
    }
    return nullptr;
}

/// The error for a fillet or chamfer whose every attempt ran out of time (blended).
String blend_too_long(const char* what, const char* size_word)
{
    return String("The ") + what + " took too long on this body and was stopped, so it was refused; try another " + size_word + " or fewer edges";
}

/// The error for a fillet or chamfer that wasn't built: what was wrong with the result OCCT gave
/// (problem), or that none was built, hinting at the size when it is big for the edges and the
/// body, or small for the body (a converted form body has short edges near its extraordinary
/// vertices, so the edges alone said "too big" of a 2.5 um fillet).
String blend_error(const char* what, const char* size_word, const std::string& problem, double size, const std::vector<TopoDS_Edge>& edges, double body_size)
{
    if (!problem.empty()) {
        return String::utf8((std::string("The ") + what + " came out broken on this body (" + problem + "), so it was refused; try another " + size_word +
                             " or fewer edges").c_str());
    }
    double shortest = 0.0;
    for (const TopoDS_Edge& edge : edges) {
        if (BRep_Tool::Degenerated(edge)) {
            continue;
        }
        GProp_GProps props;
        BRepGProp::LinearProperties(edge, props);
        shortest = shortest == 0.0 ? props.Mass() : std::min(shortest, props.Mass());
    }
    if (shortest > 0.0 && size > 0.25 * shortest && size > 0.02 * body_size) {
        return String("The ") + what + " could not be built (" + size_word + " too big?)";
    }
    if (size < 2e-3 * body_size || size < 100.0 * Precision::Confusion()) {
        return String("The ") + what + " could not be built (" + size_word + " too small for this body? try a bigger one)";
    }
    return String("The ") + what + " could not be built on these edges at that " + size_word + " (try another " + size_word + ")";
}

/// OCCT's chamfer (BRepFilletAPI_MakeChamfer, whose builder is its own, so its tolerances can't
/// be set) with its builder open: Build and the history are as that class's.
class ChamferMaker: public BRepBuilderAPI_MakeShape
{
public:
    explicit ChamferMaker(const TopoDS_Shape& shape) : builder(shape)
    {
    }

    void SetParams(double angular, double space, double param, double fit, double fit_param, double step)
    {
        builder.SetParams(angular, space, param, fit, fit_param, step);
    }

    void Build(const Message_ProgressRange& = Message_ProgressRange()) override
    {
        builder.Compute();
        if (builder.IsDone()) {
            Done();
            myShape = builder.Shape();
            for (TopExp_Explorer it(myShape, TopAbs_FACE); it.More(); it.Next()) {
                kept.Add(it.Current());
            }
        }
    }

    const TopTools_ListOfShape& Generated(const TopoDS_Shape& shape) override
    {
        return builder.Generated(shape);
    }

    const TopTools_ListOfShape& Modified(const TopoDS_Shape& face) override
    {
        myGenerated.Clear();
        for (const TopAbs_State side : {TopAbs_OUT, TopAbs_IN, TopAbs_ON}) {
            if (builder.Builder()->IsSplit(face, side)) {
                for (TopTools_ListOfShape::Iterator it(builder.Builder()->Splits(face, side)); it.More(); it.Next()) {
                    myGenerated.Append(it.Value());
                }
            }
        }
        return myGenerated;
    }

    bool IsDeleted(const TopoDS_Shape& face) override
    {
        return !(kept.Contains(face) || builder.Builder()->IsSplit(face, TopAbs_OUT) || builder.Builder()->IsSplit(face, TopAbs_IN) ||
                 builder.Builder()->IsSplit(face, TopAbs_ON));
    }

    ChFi3d_ChBuilder builder;

private:
    TopTools_MapOfShape kept;
};
}  // namespace

Shape named(const TopoDS_Shape& shape, const std::string& tag)
{
    Shape out = CadShape::wrap(shape);
    naming::name_result(*out.ptr(), nullptr, {}, tag);
    return out;
}

Shape box(const Vector3& size, const Vector3& origin, const std::string& tag)
{
    return primitive(BRepPrimAPI_MakeBox(P(origin), size.x, size.y, size.z).Shape(), tag);
}

Shape cylinder(double radius, double height, const Vector3& origin, const Vector3& axis, const std::string& tag)
{
    const gp_Dir dir = D(axis.normalized());
    return primitive(BRepPrimAPI_MakeCylinder(gp_Ax2(P(origin), dir), radius, height).Shape(), tag, &dir);
}

Shape sphere(double radius, const Vector3& center, const std::string& tag)
{
    return primitive(BRepPrimAPI_MakeSphere(P(center), radius).Shape(), tag);
}

Shape torus(const Dictionary& p, String& error)
{
    const double major = p.get("major_radius", 0.02);
    const double minor = p.get("minor_radius", 0.005);
    if (minor <= 0.0 || major <= 0.0) {
        error = "Torus radii must be positive";
        return Shape();
    }
    const gp_Dir axis = D(Vector3(p.get("axis", Vector3(0, 1, 0))).normalized());
    return primitive(BRepPrimAPI_MakeTorus(gp_Ax2(P(p.get("center", Vector3())), axis), major, minor).Shape(), tag_of(p, "torus"), &axis);
}

namespace
{

/// A shape's vertices and points along its edges and inside its faces (a few each): what tells
/// whether it reaches into a solid.
std::vector<gp_Pnt> sample_points(const TopoDS_Shape& s)
{
    std::vector<gp_Pnt> points;
    TopTools_IndexedMapOfShape vertices;
    TopExp::MapShapes(s, TopAbs_VERTEX, vertices);
    for (int i = 1; i <= vertices.Extent(); ++i) {
        points.push_back(BRep_Tool::Pnt(TopoDS::Vertex(vertices(i))));
    }
    TopTools_IndexedMapOfShape edges;
    TopExp::MapShapes(s, TopAbs_EDGE, edges);
    for (int i = 1; i <= edges.Extent(); ++i) {
        if (BRep_Tool::Degenerated(TopoDS::Edge(edges(i)))) {
            continue;
        }
        const BRepAdaptor_Curve curve(TopoDS::Edge(edges(i)));
        for (const double t : {0.25, 0.5, 0.75}) {
            points.push_back(curve.Value(curve.FirstParameter() + (curve.LastParameter() - curve.FirstParameter()) * t));
        }
    }
    for (TopExp_Explorer it(s, TopAbs_FACE); it.More(); it.Next()) {
        const TopoDS_Face& face = TopoDS::Face(it.Current());
        double u1 = 0.0, u2 = 0.0, v1 = 0.0, v2 = 0.0;
        BRepTools::UVBounds(face, u1, u2, v1, v2);
        const BRepAdaptor_Surface surface(face);
        for (int i = 1; i < 4; ++i) {
            for (int j = 1; j < 4; ++j) {
                const gp_Pnt2d uv(u1 + (u2 - u1) * i / 4.0, v1 + (v2 - v1) * j / 4.0);
                if (BRepClass_FaceClassifier(face, uv, Precision::PConfusion()).State() == TopAbs_IN) {
                    points.push_back(surface.Value(uv.X(), uv.Y()));
                }
            }
        }
    }
    return points;
}

/// True when one of points lies in state (inside or outside solid, clear of its faces).
bool any_point(const TopoDS_Shape& solid, const std::vector<gp_Pnt>& points, TopAbs_State state)
{
    BRepClass3d_SolidClassifier classifier(solid);
    const double tolerance = std::max(1e-6 * diagonal(solid), Precision::Confusion());
    for (const gp_Pnt& point : points) {
        classifier.Perform(point, tolerance);
        if (classifier.State() == state) {
            return true;
        }
    }
    return false;
}

/// Why a boolean's result of solids can't be right, or "": OCCT can report success where the shapes
/// meet in ways its intersections get wrong, with the target left as it was, emptied or grown. Told
/// by volumes (to within a 10000th, the error a boolean's curves leave) and, where nothing seems to
/// have changed, by whether the shapes overlap at all.
std::string wrong_boolean(const TopoDS_Shape& target, const TopoDS_Shape& tool, const TopoDS_Shape& result, int operation)
{
    if (!has_solid(target) || !has_solid(tool)) {
        return "";
    }
    const double a = measure::volume(target).Mass();
    const double b = measure::volume(tool).Mass();
    const double r = has_solid(result) ? measure::volume(result).Mass() : 0.0;
    const double slack = 1e-4 * (std::abs(a) + std::abs(b));
    auto unchanged = [](double x, double y) { return std::abs(x - y) <= 1e-7 * std::max(std::abs(x), std::abs(y)); };
    auto overlap = [&]() { return any_point(target, sample_points(tool), TopAbs_IN) || any_point(tool, sample_points(target), TopAbs_IN); };
    switch (operation) {
        case 0:
            if (r < std::max(a, b) - slack) {
                return "it lost part of the bodies";
            }
            if (r > a + b + slack || (unchanged(r, a + b) && overlap())) {
                return "it didn't merge where they overlap";
            }
            return "";
        case 1:
            if (r > a + slack) {
                return "the body grew";
            }
            if (r < a - b - slack || (r <= slack && any_point(tool, sample_points(target), TopAbs_OUT))) {
                return "it removed more than the cutting shape holds";
            }
            if (unchanged(r, a) && overlap()) {
                return "it left the body uncut";
            }
            return "";
        default:
            if (r > std::min(a, b) + slack) {
                return "it came out bigger than either shape";
            }
            if (r <= 1e-7 * std::min(a, b) && overlap()) {
                return "it came out empty where the shapes overlap";
            }
            return "";
    }
}

}  // namespace

Shape boolean(const Shape& target, const Shape& tool, int operation, const std::string& tag, String& error)
{
    if (!usable(target) || !usable(tool)) {
        error = "Boolean needs two shapes";
        return Shape();
    }
    const char* what = operation == 0 ? "join" : operation == 1 ? "cut" : "intersect";
    std::unique_ptr<BRepAlgoAPI_BooleanOperation> op;
    // Bounded: OCCT can take minutes over curved bodies that nearly touch or are very small
    // (converted form bodies of a few millimetres), and the timeline rebuild waits for it.
    const Handle(Deadline) clock = new Deadline(g_time_limit);
    auto build = [&](double fuzzy) {
        switch (operation) {
            case 0:
                op = std::make_unique<BRepAlgoAPI_Fuse>();
                break;
            case 1:
                op = std::make_unique<BRepAlgoAPI_Cut>();
                break;
            default:
                op = std::make_unique<BRepAlgoAPI_Common>();
                break;
        }
        TopTools_ListOfShape arguments;
        arguments.Append(target->get_occ_shape());
        TopTools_ListOfShape tools;
        tools.Append(tool->get_occ_shape());
        op->SetArguments(arguments);
        op->SetTools(tools);
        // (Left as they were: OCCT otherwise raises the tolerances of the shapes it is given where
        // they meet, and a body that a boolean failed on then fails the next.)
        op->SetNonDestructive(true);
        if (fuzzy > 0.0) {
            op->SetFuzzyValue(fuzzy);
        }
        op->Build(clock->Start());
    };
    // A face it made must be sound: OCCT's intersections can miss where a loop of one shape's
    // edges crosses the other's (a converted pipe cross cut across where its pipes meet: the big
    // pipe's face kept the meeting's loop whole as a hole running out across its cut edge, which
    // OCCT's mesher gives no triangles, so 40 % of the body was left undrawn and unexported, with
    // no word). Then the boolean is tried again with the shapes taken as touching a little further
    // apart; failing that, it is refused.
    TopTools_IndexedMapOfShape given;
    TopExp::MapShapes(target->get_occ_shape(), TopAbs_FACE, given);
    TopExp::MapShapes(tool->get_occ_shape(), TopAbs_FACE, given);
    auto unsound = [&](const TopoDS_Shape& made) {
        for (TopExp_Explorer it(made, TopAbs_FACE); it.More(); it.Next()) {
            if (!given.Contains(it.Current()) && !BRepCheck_Analyzer(it.Current()).IsValid()) {
                return true;
            }
        }
        return false;
    };
    const double size = std::max(diagonal(target->get_occ_shape()), diagonal(tool->get_occ_shape()));
    bool sound = false;
    for (const double fuzzy : {0.0, 1e-6 * size, 1e-5 * size}) {
        build(fuzzy);
        if (clock->expired()) {
            error = too_long(what) + "; curved bodies that are very small or nearly touch are slow to combine (try moving or resizing one slightly)";
            return Shape();
        }
        if (!op->IsDone() || op->Shape().IsNull()) {
            if (fuzzy == 0.0) {
                error = "The boolean operation failed";
                return Shape();
            }
            continue;
        }
        if (!unsound(op->Shape())) {
            sound = true;
            break;
        }
    }
    if (!sound) {
        error = String::utf8(("The " + std::string(what) +
                              " came out with a face the geometry kernel left unsound where the shapes meet (it would be drawn and exported with a hole there); try moving or "
                              "resizing one of them slightly")
                                 .c_str());
        return Shape();
    }
    Shape raw = CadShape::wrap(op->Shape());
    naming::name_result(*raw.ptr(), op.get(), {target.ptr(), tool.ptr()}, tag);
    Shape out = unify(raw, tag);
    // (Judged after merging faces: a result OCCT left with stray faces can merge back into the
    // target as it was.)
    const std::string wrong = wrong_boolean(target->get_occ_shape(), tool->get_occ_shape(), out->get_occ_shape(), operation);
    if (!wrong.empty()) {
        error = String::utf8(("The " + std::string(what) + " came out wrong where the shapes meet (" + wrong + "); try moving or resizing one of them slightly").c_str());
        return Shape();
    }
    return out;
}

Shape extrude(const Shape& profile, const Dictionary& p, String& error)
{
    if (!usable(profile)) {
        error = "Pick a profile to extrude";
        return Shape();
    }
    const std::string tag = tag_of(p, "extrude");
    const gp_Vec dir(D(Vector3(p.get("direction", Vector3(0, 1, 0))).normalized()));
    const double d1 = p.get("distance", 0.01);
    const double d2 = p.get("distance2", 0.0);
    const double taper = p.get("taper", 0.0);
    const double start = p.get("start_offset", 0.0);
    const bool surface = p.get("surface", false);
    const double total = d1 + d2;
    if (std::abs(total) < 1e-12) {
        error = "The extrude distance is zero";
        return Shape();
    }
    try {
        gp_Trsf shift;
        shift.SetTranslation(dir * (start - d2));
        Shape base = moved(profile, shift);
        if (surface) {
            // Surfaces: the profile's loops and curves sweep out walls, with no caps.
            const std::vector<ProfileWire> wires = profile_wires(base->get_occ_shape());
            if (wires.empty()) {
                error = "Pick curves or profiles to extrude";
                return Shape();
            }
            if (std::abs(taper) < 1e-9) {
                BRepPrimAPI_MakePrism prism(wires_shape(wires), dir * total, true);
                if (!prism.IsDone()) {
                    error = "The extrude could not be built";
                    return Shape();
                }
                Shape out = CadShape::wrap(prism.Shape());
                naming::name_result(*out.ptr(), &prism, {base.ptr()}, tag);
                return out;
            }
            // Tapered walls: each loop lofted to its offset copy at the far end (closed loops
            // shrink, holes grow; open curves lean to their left, seen from the far end), named by
            // the profile edges they rise from (as without a taper, so a taper keeps the names).
            std::vector<TopoDS_Shape> walls;
            std::vector<naming::Role> roles;
            const TopTools_IndexedMapOfShape& base_edges = base->edge_map();
            const double inset = std::abs(total) * std::tan(taper);
            for (const ProfileWire& loop : wires) {
                const bool closed = BRep_Tool::IsClosed(loop.wire);
                // A closed loop where an arc meets another edge at a corner: the walls of its
                // drafted prism (a hole's loop drafted the other way, so it widens).
                std::vector<std::pair<TopoDS_Shape, TopoDS_Shape>> drafted_walls;
                std::array<TopoDS_Shape, 2> drafted_caps;
                if (closed && arc_corner(loop.wire)) {
                    BRepBuilderAPI_MakeFace flat(loop.wire, true);
                    if (flat.IsDone()) {
                        ShapeFix_Face fix(flat.Face());
                        fix.FixOrientation();
                        drafted_prism(fix.Face(), dir * total, loop.hole ? -taper : taper, drafted_walls, drafted_caps);
                    }
                }
                if (!drafted_walls.empty()) {
                    BRep_Builder builder;
                    TopoDS_Shell shell;
                    builder.MakeShell(shell);
                    for (const auto& [edge, wall] : drafted_walls) {
                        builder.Add(shell, wall);
                        const int index = base_edges.FindIndex(edge);
                        if (index > 0) {
                            roles.push_back({wall, tag + ":g(" + (size_t(index - 1) < base->edge_name_list.size() ? base->edge_name_list[index - 1] : "e" + std::to_string(index - 1)) + ")"});
                        }
                    }
                    walls.push_back(shell);
                    continue;
                }
                TaperSide side(false);
                if (!taper_side(side, loop.wire, !closed || loop.hole ? inset : -inset, dir * total, error)) {
                    return Shape();
                }
                for (TopExp_Explorer e(loop.wire, TopAbs_EDGE); e.More(); e.Next()) {
                    const int index = base_edges.FindIndex(e.Current());
                    if (index > 0) {
                        const std::string edge_name = size_t(index - 1) < base->edge_name_list.size() ? base->edge_name_list[index - 1] : "e" + std::to_string(index - 1);
                        roles.push_back({side.face(side.loft.GeneratedFace(e.Current())), tag + ":g(" + edge_name + ")"});
                    }
                }
                walls.push_back(side.shape);
            }
            Shape out = CadShape::wrap(walls.size() == 1 ? walls[0] : make_compound(walls));
            naming::name_result(*out.ptr(), nullptr, {}, tag, roles);
            return out;
        }
        if (std::abs(taper) < 1e-9) {
            BRepPrimAPI_MakePrism prism(base->get_occ_shape(), dir * total, true);
            if (!prism.IsDone()) {
                error = "The extrude could not be built";
                return Shape();
            }
            Shape out = CadShape::wrap(prism.Shape());
            naming::name_result(*out.ptr(), &prism, {base.ptr()}, tag,
                {{prism.FirstShape(), tag + ":start"}, {prism.LastShape(), tag + ":end"}});
            return out;
        }
        // Tapered: loft each loop to its offset copy at the far end; holes are cut back out (the
        // caps carry their names through the cuts).
        TopTools_IndexedMapOfShape base_edges = map_of(base->get_occ_shape(), TopAbs_EDGE);
        std::vector<TopoDS_Shape> solids;
        std::vector<naming::Role> roles;
        const double inset = std::abs(total) * std::tan(taper);
        for (const TopoDS_Face& face : faces_of(base->get_occ_shape())) {
            // Where an arc meets another edge at a corner, a draft of the straight prism is exact.
            bool cornered = false;
            for (TopExp_Explorer w(face, TopAbs_WIRE); w.More(); w.Next()) {
                cornered = cornered || arc_corner(TopoDS::Wire(w.Current()));
            }
            std::vector<std::pair<TopoDS_Shape, TopoDS_Shape>> drafted_walls;
            std::array<TopoDS_Shape, 2> drafted_caps;
            const TopoDS_Shape drafted = cornered ? drafted_prism(face, dir * total, taper, drafted_walls, drafted_caps) : TopoDS_Shape();
            if (!drafted.IsNull()) {
                for (const auto& [edge, wall] : drafted_walls) {
                    const int index = base_edges.FindIndex(edge);
                    roles.push_back({wall, tag + ":g(" + (index > 0 && size_t(index - 1) < base->edge_name_list.size() ? base->edge_name_list[index - 1] : "e") + ")"});
                }
                roles.push_back({drafted_caps[0], tag + ":start"});
                roles.push_back({drafted_caps[1], tag + ":end"});
                solids.push_back(drafted);
                continue;
            }
            const TopoDS_Wire outer = BRepTools::OuterWire(face);
            TopoDS_Shape body;
            std::vector<naming::Role> caps;
            std::vector<TopoDS_Wire> loops = {outer};
            for (TopExp_Explorer w(face, TopAbs_WIRE); w.More(); w.Next()) {
                if (!w.Current().IsSame(outer)) {
                    loops.push_back(TopoDS::Wire(w.Current()));
                }
            }
            for (const TopoDS_Wire& wire : loops) {
                const bool is_outer = wire.IsSame(outer);
                TaperSide side(true);
                if (!taper_side(side, wire, is_outer ? -inset : inset, dir * total, error)) {
                    return Shape();
                }
                for (TopExp_Explorer e(wire, TopAbs_EDGE); e.More(); e.Next()) {
                    const int index = base_edges.FindIndex(e.Current());
                    const std::string edge_name = index > 0 && size_t(index - 1) < base->edge_name_list.size() ? base->edge_name_list[index - 1] : "e";
                    roles.push_back({side.face(side.loft.GeneratedFace(e.Current())), tag + ":g(" + edge_name + ")"});
                }
                if (is_outer) {
                    caps = {{side.face(side.loft.FirstShape()), tag + ":start"}, {side.face(side.loft.LastShape()), tag + ":end"}};
                    body = side.shape;
                    continue;
                }
                BRepAlgoAPI_Cut cut(body, side.shape);
                for (naming::Role& cap : caps) {
                    cap.shape = carried(cut, cap.shape);
                }
                body = cut.Shape();
            }
            roles.insert(roles.end(), caps.begin(), caps.end());
            solids.push_back(body);
        }
        const TopoDS_Shape result = solids.size() == 1 ? solids[0] : make_compound(solids);
        // A side that didn't close around the profile leaves an open solid with no volume.
        GProp_GProps props;
        BRepGProp::VolumeProperties(result, props, true);
        if (!(std::abs(props.Mass()) > 0.0)) {
            error = "The tapered extrude could not be built";
            return Shape();
        }
        Shape out = CadShape::wrap(result);
        naming::name_result(*out.ptr(), nullptr, {}, tag, roles);
        return out;
    }
    catch (const Standard_Failure& failure) {
        error = String("Extrude failed: ") + failure.GetMessageString();
        return Shape();
    }
}

Shape revolve(const Shape& profile, const Dictionary& p, String& error)
{
    if (!usable(profile)) {
        error = "Pick a profile to revolve";
        return Shape();
    }
    const std::string tag = tag_of(p, "revolve");
    const gp_Ax1 axis(P(p.get("axis_origin", Vector3())), D(Vector3(p.get("axis", Vector3(0, 1, 0))).normalized()));
    const double a1 = p.get("angle", 2.0 * M_PI);
    const double a2 = p.get("angle2", 0.0);
    const double total = std::min(a1 + a2, 2.0 * M_PI);
    if (total <= 1e-9) {
        error = "The revolve angle is zero";
        return Shape();
    }
    try {
        gp_Trsf turn;
        turn.SetRotation(axis, -a2);
        Shape base = moved(profile, turn);
        // Surfaces turn the profile's loops and curves (walls, no ends).
        const bool surface = p.get("surface", false);
        TopoDS_Shape source = base->get_occ_shape();
        if (surface) {
            const std::vector<ProfileWire> wires = profile_wires(source);
            if (wires.empty()) {
                error = "Pick curves or profiles to revolve";
                return Shape();
            }
            source = wires_shape(wires);
        }
        BRepPrimAPI_MakeRevol revol(source, axis, total, true);
        if (!revol.IsDone()) {
            error = "The revolve could not be built (does the profile cross the axis?)";
            return Shape();
        }
        Shape out = CadShape::wrap(revol.Shape());
        std::vector<naming::Role> roles;
        if (!surface && total < 2.0 * M_PI - 1e-9) {
            roles = {{revol.FirstShape(), tag + ":start"}, {revol.LastShape(), tag + ":end"}};
        }
        naming::name_result(*out.ptr(), &revol, {base.ptr()}, tag, roles);
        return out;
    }
    catch (const Standard_Failure& failure) {
        error = String("Revolve failed: ") + failure.GetMessageString();
        return Shape();
    }
}

/// A curve winding round spine distance away, turning by twist (radians) from its start to its end
/// (evenly along its length) about a frame carried along spine without turning (rotation
/// minimizing, by double reflection): a pipe shell's auxiliary spine turns its section with it,
/// so the section twists as asked and is otherwise carried as along a plain path. It turns from
/// angle from to angle to; across is the frame's start (any direction square to the path's start;
/// a zero vector for its own), and comes back as its end, so a following leg carries on. Null
/// when it can't be fitted.
TopoDS_Wire twist_guide(const TopoDS_Wire& spine, double from, double to, double distance, gp_Vec& across)
{
    const double twist = to - from;
    BRepAdaptor_CompCurve curve(spine);
    const double f = curve.FirstParameter();
    const double l = curve.LastParameter();
    const double length = GCPnts_AbscissaPoint::Length(curve);
    const int count = std::clamp(64 * (1 + int(std::ceil(std::abs(twist) / M_PI))) + 16 * curve.NbIntervals(GeomAbs_C2), 64, 2000);
    Handle(TColgp_HArray1OfPnt) points = new TColgp_HArray1OfPnt(1, count + 1);
    Handle(TColStd_HArray1OfReal) params = new TColStd_HArray1OfReal(1, count + 1);
    gp_Pnt at;
    gp_Vec tangent;
    curve.D1(f, at, tangent);
    tangent.Normalize();
    across -= tangent * across.Dot(tangent);
    if (across.Magnitude() < 1e-9) {
        across = std::abs(gp_Dir(tangent).Dot(gp::DZ())) < 0.9 ? gp_Vec(tangent).Crossed(gp_Vec(gp::DZ())) : gp_Vec(tangent).Crossed(gp_Vec(gp::DX()));
    }
    across.Normalize();
    double run = 0.0;
    for (int i = 0; i <= count; ++i) {
        const double t = f + (l - f) * i / count;
        gp_Pnt next;
        gp_Vec heading;
        curve.D1(t, next, heading);
        heading.Normalize();
        if (i > 0) {
            const gp_Vec step(at, next);
            const double c1 = step.SquareMagnitude();
            if (c1 > 1e-300) {
                const gp_Vec reflected = across - step * (2.0 / c1 * step.Dot(across));
                const gp_Vec turned = tangent - step * (2.0 / c1 * step.Dot(tangent));
                const gp_Vec rest = heading - turned;
                const double c2 = rest.SquareMagnitude();
                across = c2 > 1e-300 ? reflected - rest * (2.0 / c2 * rest.Dot(reflected)) : reflected;
                across.Normalize();
            }
            run += i == count ? 0.0 : GCPnts_AbscissaPoint::Length(curve, f + (l - f) * (i - 1) / count, t);
        }
        const double angle = from + twist * (i == count ? 1.0 : run / length);
        const gp_Vec side = heading.Crossed(across);
        points->SetValue(i + 1, next.Translated((across * std::cos(angle) + side * std::sin(angle)) * distance));
        params->SetValue(i + 1, t);
        at = next;
        tangent = heading;
    }
    GeomAPI_Interpolate fit(points, params, false, Precision::Confusion() * 1e-3);
    fit.Perform();
    if (!fit.IsDone()) {
        return TopoDS_Wire();
    }
    return BRepBuilderAPI_MakeWire(BRepBuilderAPI_MakeEdge(fit.Curve()).Edge()).Wire();
}

namespace
{
/// A closed wire opened where it starts: the same edges, its last one ending on a vertex of its
/// own at the same point (a sweep round it then ends there, capped, instead of closing on itself).
TopoDS_Wire opened(const TopoDS_Wire& wire)
{
    std::vector<TopoDS_Edge> edges;
    for (BRepTools_WireExplorer it(wire); it.More(); it.Next()) {
        edges.push_back(it.Current());
    }
    if (edges.empty()) {
        return wire;
    }
    const TopoDS_Edge last = edges.back();
    double f = 0.0;
    double l = 0.0;
    const Handle(Geom_Curve) curve = BRep_Tool::Curve(last, f, l);
    if (curve.IsNull()) {
        return wire;
    }
    TopoDS_Vertex at_f;
    TopoDS_Vertex at_l;
    TopExp::Vertices(TopoDS::Edge(last.Oriented(TopAbs_FORWARD)), at_f, at_l);
    const bool forward = last.Orientation() != TopAbs_REVERSED;
    const TopoDS_Vertex fresh = BRepBuilderAPI_MakeVertex(curve->Value(forward ? l : f)).Vertex();
    // (OCCT won't end an edge closed on itself, a circle, on two vertices: it is halved first.)
    std::vector<std::pair<double, double>> pieces = {{f, l}};
    TopoDS_Vertex half;
    if (at_f.IsSame(at_l)) {
        pieces = {{f, 0.5 * (f + l)}, {0.5 * (f + l), l}};
        half = BRepBuilderAPI_MakeVertex(curve->Value(0.5 * (f + l))).Vertex();
    }
    std::vector<TopoDS_Edge> remade;
    for (size_t k = 0; k < pieces.size(); ++k) {
        const bool first_piece = k == 0;
        const bool last_piece = k + 1 == pieces.size();
        // Each piece's vertices at its parameters' ends: the fresh one where the wire now ends.
        const TopoDS_Vertex from = first_piece ? (forward ? at_f : fresh) : half;
        const TopoDS_Vertex to = last_piece ? (forward ? fresh : at_l) : half;
        BRepBuilderAPI_MakeEdge piece(curve, from, to, pieces[k].first, pieces[k].second);
        if (!piece.IsDone()) {
            return wire;
        }
        remade.push_back(TopoDS::Edge(piece.Edge().Oriented(last.Orientation())));
    }
    if (!forward) {
        std::reverse(remade.begin(), remade.end());
    }
    edges.pop_back();
    edges.insert(edges.end(), remade.begin(), remade.end());
    BRepBuilderAPI_MakeWire maker;
    for (const TopoDS_Edge& edge : edges) {
        maker.Add(edge);
    }
    return maker.IsDone() ? maker.Wire() : wire;
}

/// A closed wire started again at its point nearest near: the same loop, the edge there split in
/// two (or the edges turned round to start at the vertex there). As it was when that is its start.
TopoDS_Wire restarted(const TopoDS_Wire& wire, const gp_Pnt& near)
{
    std::vector<TopoDS_Edge> edges;
    for (BRepTools_WireExplorer it(wire); it.More(); it.Next()) {
        edges.push_back(it.Current());
    }
    if (edges.empty()) {
        return wire;
    }
    double length = 0.0;
    for (const TopoDS_Edge& edge : edges) {
        length += measure::length(edge);
    }
    // The nearest point: on which edge, at which parameter.
    double best = 1e300;
    size_t on = 0;
    double at = 0.0;
    for (size_t k = 0; k < edges.size(); ++k) {
        double f = 0.0;
        double l = 0.0;
        const Handle(Geom_Curve) curve = BRep_Tool::Curve(edges[k], f, l);
        if (curve.IsNull()) {
            continue;
        }
        gp_Pnt nearest;
        double t = 0.0;
        const double distance = ShapeAnalysis_Curve().Project(curve, near, Precision::Confusion(), nearest, t, f, l, false);
        if (distance < best) {
            best = distance;
            on = k;
            at = t;
        }
    }
    double f = 0.0;
    double l = 0.0;
    const Handle(Geom_Curve) curve = BRep_Tool::Curve(edges[on], f, l);
    const bool backward = edges[on].Orientation() == TopAbs_REVERSED;
    // How far along the edge, the way the wire runs.
    const double from_start = backward ? GCPnts_AbscissaPoint::Length(GeomAdaptor_Curve(curve), at, l) : GCPnts_AbscissaPoint::Length(GeomAdaptor_Curve(curve), f, at);
    const double edge_length = measure::length(edges[on]);
    const double tolerance = 1e-9 * length;
    std::vector<TopoDS_Edge> order;
    if (from_start <= tolerance || from_start >= edge_length - tolerance) {
        // At a vertex: the edges from there on, then the ones before.
        const size_t first = from_start <= tolerance ? on : (on + 1) % edges.size();
        if (first == 0) {
            return wire;
        }
        for (size_t k = 0; k < edges.size(); ++k) {
            order.push_back(edges[(first + k) % edges.size()]);
        }
    }
    else {
        TopoDS_Vertex vf;
        TopoDS_Vertex vl;
        TopExp::Vertices(TopoDS::Edge(edges[on].Oriented(TopAbs_FORWARD)), vf, vl);
        const TopoDS_Vertex cut = BRepBuilderAPI_MakeVertex(curve->Value(at)).Vertex();
        BRepBuilderAPI_MakeEdge low(curve, vf, cut, f, at);
        BRepBuilderAPI_MakeEdge high(curve, cut, vl, at, l);
        if (!low.IsDone() || !high.IsDone()) {
            return wire;
        }
        const TopoDS_Edge before = backward ? TopoDS::Edge(high.Edge().Reversed()) : low.Edge();
        const TopoDS_Edge after = backward ? TopoDS::Edge(low.Edge().Reversed()) : high.Edge();
        order.push_back(after);
        for (size_t k = 1; k < edges.size(); ++k) {
            order.push_back(edges[(on + k) % edges.size()]);
        }
        order.push_back(before);
    }
    BRepBuilderAPI_MakeWire maker;
    for (const TopoDS_Edge& edge : order) {
        maker.Add(edge);
    }
    return maker.IsDone() ? maker.Wire() : wire;
}

/// Points along a wire, about count of them, at even parameters on each edge.
std::vector<gp_Pnt> sampled(const TopoDS_Wire& wire, int count)
{
    std::vector<gp_Pnt> points;
    int edges = 0;
    for (TopExp_Explorer it(wire, TopAbs_EDGE); it.More(); it.Next()) {
        ++edges;
    }
    const int per_edge = std::max(8, count / std::max(edges, 1));
    for (TopExp_Explorer it(wire, TopAbs_EDGE); it.More(); it.Next()) {
        const TopoDS_Edge& edge = TopoDS::Edge(it.Current());
        if (BRep_Tool::Degenerated(edge)) {
            continue;
        }
        const BRepAdaptor_Curve curve(edge);
        for (int i = 0; i <= per_edge; ++i) {
            points.push_back(curve.Value(curve.FirstParameter() + (curve.LastParameter() - curve.FirstParameter()) * i / per_edge));
        }
    }
    return points;
}

/// The smallest turn between two edges of a path taken as a sharp corner (radians). (OCCT's pipe
/// mitres only turns over 1e-2 and bends its frame round smaller ones, which put a 0.3 deg corner
/// 6.8e-6 off: mitred_pipe() says so. Under 1e-4 that comes to under 3e-9.)
constexpr double SHARP_TURN = 1e-4;

/// The size (model units, the millimetres OCCT's tolerances suit) a pipe round sharp corners is
/// made at, about its middle: its corners' mitres came out 6.6e-5 short at 10 mm, 2e-8 at 1 m.
constexpr double CORNER_SIZE = 1.0;

/// The size (a profile's diagonal) a smaller twisted sweep is made at.
constexpr double TWIST_SIZE = 0.002;

/// A sharp corner of a path: where one edge ends heading one way (in) and the next starts heading
/// another (out), more than SHARP_TURN apart; run is how far along the path it is.
struct Corner
{
    gp_Pnt at;
    double run = 0.0;
    gp_Vec in;
    gp_Vec out;
    double turn = 0.0;
};

/// An edge's unit heading at its start (first) or its end, the way its wire runs.
gp_Vec edge_heading(const TopoDS_Edge& edge, bool first)
{
    const BRepAdaptor_Curve curve(edge);
    const bool backward = edge.Orientation() == TopAbs_REVERSED;
    gp_Pnt point;
    gp_Vec heading;
    curve.D1(first != backward ? curve.FirstParameter() : curve.LastParameter(), point, heading);
    if (backward) {
        heading.Reverse();
    }
    return heading.Magnitude() > 1e-300 ? heading.Normalized() : heading;
}

/// A path's sharp corners in order (a closed one's last where it closes, at its whole length).
std::vector<Corner> sharp_corners(const TopoDS_Wire& wire, bool closed)
{
    std::vector<TopoDS_Edge> edges;
    for (BRepTools_WireExplorer it(wire); it.More(); it.Next()) {
        if (!BRep_Tool::Degenerated(it.Current())) {
            edges.push_back(it.Current());
        }
    }
    std::vector<Corner> corners;
    double run = 0.0;
    for (size_t k = 0; k < edges.size(); ++k) {
        run += measure::length(edges[k]);
        if (k + 1 == edges.size() && !closed) {
            break;
        }
        Corner corner;
        corner.in = edge_heading(edges[k], false);
        corner.out = edge_heading(edges[(k + 1) % edges.size()], true);
        if (corner.in.Magnitude() < 0.5 || corner.out.Magnitude() < 0.5) {
            continue;
        }
        corner.turn = corner.in.Angle(corner.out);
        if (corner.turn > SHARP_TURN) {
            corner.at = BRep_Tool::Pnt(TopExp::LastVertex(edges[k], true));
            corner.run = run;
            corners.push_back(corner);
        }
    }
    return corners;
}

/// A vector turned about axis by angle (Rodrigues).
gp_Vec turned_about(const gp_Vec& v, const gp_Vec& axis, double angle)
{
    if (axis.Magnitude() < 1e-300 || std::abs(angle) < 1e-300) {
        return v;
    }
    const gp_Vec k = axis.Normalized();
    return v * std::cos(angle) + k.Crossed(v) * std::sin(angle) + k * (k.Dot(v) * (1.0 - std::cos(angle)));
}

/// What a profile (outer; a skin's curve when skin) swept square to a path with sharp corners must
/// come to, mitred at its corners as OCCT's right-corner pipe makes them: its area (a skin's
/// length) times how far its centroid travels -- the path's length less, where it bends, the
/// centroid's offset toward the bend's centre times the bend (Pappus), and at each corner twice
/// its offset into the corner times tan(turn / 2). The profile is carried along turning as little
/// as the path lets it (see folds()). Empty, with expected set, when every stretch between corners
/// is long enough for the mitres at its ends (each point of the profile is cut back by its offset
/// into a corner times tan(turn / 2)); otherwise a reason.
std::string mitred(const TopoDS_Wire& spine, const TopoDS_Wire& outer, bool skin, bool closed, const std::vector<Corner>& corners, double& expected)
{
    expected = -1.0;
    GProp_GProps props;
    if (skin) {
        BRepGProp::LinearProperties(outer, props);
    }
    else {
        BRepBuilderAPI_MakeFace face(outer, true);
        if (!face.IsDone()) {
            return "";
        }
        BRepGProp::SurfaceProperties(face.Face(), props);
    }
    const double amount = std::abs(props.Mass());
    std::vector<TopoDS_Edge> edges;
    for (BRepTools_WireExplorer it(spine); it.More(); it.Next()) {
        if (!BRep_Tool::Degenerated(it.Current())) {
            edges.push_back(it.Current());
        }
    }
    if (edges.empty() || !(amount > 0.0)) {
        return "";
    }
    // The profile's points and centroid from the path's start, square to it, in the frame (e1, e2).
    const gp_Pnt start = BRep_Tool::Pnt(TopExp::FirstVertex(edges.front(), true));
    gp_Vec tangent = edge_heading(edges.front(), true);
    gp_Vec across = std::abs(tangent.Dot(gp_Vec(gp::DZ()))) < 0.9 ? tangent.Crossed(gp_Vec(gp::DZ())) : tangent.Crossed(gp_Vec(gp::DX()));
    across.Normalize();
    auto local = [&](const gp_Pnt& q) {
        gp_Vec v(start, q);
        v -= tangent * v.Dot(tangent);
        return std::pair<double, double>{v.Dot(across), v.Dot(tangent.Crossed(across))};
    };
    std::vector<std::pair<double, double>> points;
    for (const gp_Pnt& q : sampled(outer, 96)) {
        points.push_back(local(q));
    }
    const std::pair<double, double> centroid = local(props.CentreOfMass());
    // Walked edge by edge: the centroid's travel, and each corner's inside direction in the frame.
    struct Cut
    {
        double run;
        double x;
        double y;
        double t;
        double turn;
    };
    std::vector<Cut> cuts;
    double travel = 0.0;
    double run = 0.0;
    size_t next_corner = 0;
    for (size_t k = 0; k < edges.size(); ++k) {
        const BRepAdaptor_Curve curve(edges[k]);
        const bool backward = edges[k].Orientation() == TopAbs_REVERSED;
        const bool straight = curve.GetType() == GeomAbs_Line;
        const int count = straight ? 2 : 2 * std::clamp(32 * curve.NbIntervals(GeomAbs_C2), 64, 1000);
        const double f = curve.FirstParameter();
        const double l = curve.LastParameter();
        double integral = 0.0;
        gp_Pnt at;
        for (int i = 0; i <= count; ++i) {
            const double t = backward ? l - (l - f) * i / count : f + (l - f) * i / count;
            gp_Pnt next;
            gp_Vec d1;
            gp_Vec d2;
            curve.D2(t, next, d1, d2);
            const double speed = d1.Magnitude();
            const gp_Vec now = speed > 1e-300 ? (backward ? -d1 : d1) / speed : tangent;
            if (i > 0) {
                const gp_Vec step(at, next);
                const double c1 = step.SquareMagnitude();
                if (c1 > 1e-300) {
                    const gp_Vec reflected = across - step * (2.0 / c1 * step.Dot(across));
                    const gp_Vec turned = tangent - step * (2.0 / c1 * step.Dot(tangent));
                    const gp_Vec rest = now - turned;
                    const double c2 = rest.SquareMagnitude();
                    across = c2 > 1e-300 ? reflected - rest * (2.0 / c2 * rest.Dot(reflected)) : reflected;
                    across.Normalize();
                }
            }
            else {
                // Where an edge meets the one before, the frame turns with the path there.
                across = turned_about(across, tangent.Crossed(now), tangent.Angle(now));
                across -= now * across.Dot(now);
                across.Normalize();
            }
            at = next;
            tangent = now;
            const gp_Vec bend = speed > 1e-300 ? (d2 - now * d2.Dot(now)) / (speed * speed) : gp_Vec();
            const gp_Vec offset = across * centroid.first + now.Crossed(across) * centroid.second;
            const double weight = (i == 0 || i == count) ? 1.0 : (i % 2 == 1 ? 4.0 : 2.0);
            integral += weight * speed * (1.0 - offset.Dot(bend));
        }
        const double length = measure::length(edges[k]);
        travel += straight ? length : integral * (l - f) / count / 3.0;
        run += length;
        // A corner at this edge's end: the centroid's offset into it, and its inside direction.
        if (next_corner < corners.size() && std::abs(corners[next_corner].run - run) <= 1e-9 * std::max(run, 1e-300)) {
            const Corner& corner = corners[next_corner++];
            gp_Vec inside = corner.out - corner.in * corner.in.Dot(corner.out);
            if (inside.Magnitude() > 1e-300) {
                inside.Normalize();
            }
            const double t = std::tan(0.5 * corner.turn);
            const gp_Vec side = tangent.Crossed(across);
            const double x = inside.Dot(across);
            const double y = inside.Dot(side);
            travel -= 2.0 * t * (centroid.first * x + centroid.second * y);
            cuts.push_back({corner.run, x, y, t, corner.turn});
        }
    }
    expected = amount * travel;
    // Each stretch between cuts (a closed path's last running round to its first).
    const double whole = run;
    auto reach = [&](const Cut* a, const Cut* b) {
        double most = -1e300;
        for (const auto& [x, y] : points) {
            most = std::max(most, (a ? a->t * (a->x * x + a->y * y) : 0.0) + (b ? b->t * (b->x * x + b->y * y) : 0.0));
        }
        return most;
    };
    for (size_t k = 0; k <= cuts.size(); ++k) {
        const Cut* a = k > 0 ? &cuts[k - 1] : (closed && !cuts.empty() ? &cuts.back() : nullptr);
        const Cut* b = k < cuts.size() ? &cuts[k] : (closed && !cuts.empty() ? &cuts.front() : nullptr);
        if (closed && k == cuts.size()) {
            continue;
        }
        double stretch = (b ? b->run : whole) - (k > 0 ? a->run : 0.0);
        if (closed && k == 0) {
            stretch = b->run + whole - a->run;
        }
        if (reach(a, b) >= stretch * (1.0 - 1e-9)) {
            const Cut* sharp = a && (!b || a->turn > b->turn) ? a : b;
            char text[300];
            std::snprintf(text, sizeof(text), "The path turns %.3g deg at a sharp corner only %.3g mm from %s: the profile's mitred ends would cross there (make the profile smaller, or move the corners apart or round them off)",
                sharp->turn * 180.0 / M_PI, stretch * 1000.0, a && b ? "the next corner" : a ? "the path's end" : "the path's start");
            return text;
        }
    }
    return "";
}

/// A pipe of outer swept square to spine round its sharp corners, mitred there (OCCT's
/// right-corner pipe), a solid or a skin; made at CORNER_SIZE about its middle and scaled back,
/// and checked against what it must come to (mitred()). Null with error when its mitres would
/// cross or it can't be made or comes out wrong; note says how near a fit or the result came.
/// (With OCCT's default transition a circle swept round an L came out the first leg alone, and
/// round a closed square or a U with no volume at all.)
TopoDS_Shape mitred_pipe(const TopoDS_Wire& spine, const TopoDS_Wire& outer, bool solid, bool closed, const std::vector<Corner>& corners, const char* what, String& error, String& note)
{
    double expected = -1.0;
    const std::string crossing = mitred(spine, outer, !solid, closed, corners, expected);
    if (!crossing.empty()) {
        error = String::utf8(crossing.c_str());
        return TopoDS_Shape();
    }
    Bnd_Box box;
    BRepBndLib::Add(spine, box);
    BRepBndLib::Add(outer, box);
    const double factor = CORNER_SIZE / std::max(std::sqrt(box.SquareExtent()), 1e-300);
    gp_Trsf grow;
    grow.SetScale(gp_Pnt((box.CornerMin().XYZ() + box.CornerMax().XYZ()) * 0.5), factor);
    const TopoDS_Wire spine_up = TopoDS::Wire(BRepBuilderAPI_Transform(spine, grow, true).Shape());
    const TopoDS_Wire outer_up = TopoDS::Wire(BRepBuilderAPI_Transform(outer, grow, true).Shape());
    std::unique_ptr<BRepOffsetAPI_MakePipeShell> pipe;
    for (const bool correct : {true, false}) {
        try {
            pipe = fitted_pipe(spine_up, diagonal(outer_up), solid, 1e-2, [&](BRepOffsetAPI_MakePipeShell& maker) {
                maker.SetMode(false);
                maker.SetTransitionMode(BRepBuilderAPI_RightCorner);
                maker.Add(outer_up, false, correct);
            }, what, note, factor);
        }
        catch (const Standard_Failure&) {
            if (!correct) {
                throw;
            }
        }
        if (pipe) {
            break;
        }
    }
    if (!pipe) {
        error = String("The ") + what + " round the path's sharp corners could not be built";
        return TopoDS_Shape();
    }
    const TopoDS_Shape made = BRepBuilderAPI_Transform(pipe->Shape(), grow.Inverted(), true).Shape();
    if (expected > 0.0) {
        const double got = solid ? measure::volume(made).Mass() : measure::surface(made).Mass();
        const double off = std::abs(got - expected) / expected;
        char text[260];
        if (off > 1e-3) {
            std::snprintf(text, sizeof(text), "The %s round the path's sharp corners came out wrong (its %s %.3g %% off what its profile and path make)", what, solid ? "volume" : "area", off * 100.0);
            error = text;
            return TopoDS_Shape();
        }
        if (off > 1e-6) {
            std::snprintf(text, sizeof(text), "The %s round the path's sharp corners is within %.3g %% of the %s its profile and path make", what, off * 100.0, solid ? "volume" : "area");
            note = text;
        }
    }
    return made;
}

/// Where a profile swept along spine would fold over itself: carried square to the path (turning
/// as little as the path lets it, as OCCT's corrected Frenet frame does), turned by twist in all and
/// scaled from 1 to scale from start to end, no point of it may reach the centre of the path's bend
/// (the swept skin turns back on itself there). Empty when it doesn't; otherwise a reason.
std::string folds(const TopoDS_Wire& spine, const TopoDS_Wire& profile, double twist, double scale)
{
    BRepAdaptor_CompCurve curve(spine);
    const double f = curve.FirstParameter();
    const double l = curve.LastParameter();
    const double length = GCPnts_AbscissaPoint::Length(curve);
    if (!(length > 0.0)) {
        return "";
    }
    gp_Pnt start;
    gp_Vec heading;
    curve.D1(f, start, heading);
    if (heading.Magnitude() < 1e-300) {
        return "";
    }
    heading.Normalize();
    // The profile's points, from the path's start, square to it.
    std::vector<gp_Vec> offsets;
    for (const gp_Pnt& q : sampled(profile, 96)) {
        gp_Vec v(start, q);
        offsets.push_back(v - heading * v.Dot(heading));
    }
    gp_Vec across = std::abs(heading.Dot(gp_Vec(gp::DZ()))) < 0.9 ? heading.Crossed(gp_Vec(gp::DZ())) : heading.Crossed(gp_Vec(gp::DX()));
    across.Normalize();
    std::vector<std::pair<double, double>> local;
    for (const gp_Vec& v : offsets) {
        local.push_back({v.Dot(across), v.Dot(heading.Crossed(across))});
    }
    const int count = std::clamp(32 * curve.NbIntervals(GeomAbs_C2) + 256, 256, 4000);
    gp_Pnt at = start;
    gp_Vec tangent = heading;
    double run = 0.0;
    double worst = 0.0;
    double worst_reach = 0.0;
    double worst_radius = 0.0;
    for (int i = 0; i <= count; ++i) {
        const double t = f + (l - f) * i / count;
        gp_Pnt next;
        gp_Vec d1;
        gp_Vec d2;
        curve.D2(t, next, d1, d2);
        const double speed = d1.Magnitude();
        if (speed < 1e-300) {
            continue;
        }
        const gp_Vec now = d1 / speed;
        if (i > 0) {
            // The frame carried on by double reflection (see twist_guide).
            const gp_Vec step(at, next);
            const double c1 = step.SquareMagnitude();
            if (c1 > 1e-300) {
                const gp_Vec reflected = across - step * (2.0 / c1 * step.Dot(across));
                const gp_Vec turned = tangent - step * (2.0 / c1 * step.Dot(tangent));
                const gp_Vec rest = now - turned;
                const double c2 = rest.SquareMagnitude();
                across = c2 > 1e-300 ? reflected - rest * (2.0 / c2 * rest.Dot(reflected)) : reflected;
                across.Normalize();
            }
            run += GCPnts_AbscissaPoint::Length(curve, f + (l - f) * (i - 1) / count, t);
        }
        at = next;
        tangent = now;
        // The bend: curvature times the unit normal toward its centre.
        const gp_Vec bend = (d2 - now * d2.Dot(now)) / (speed * speed);
        const double kappa = bend.Magnitude();
        if (kappa < 1e-300) {
            continue;
        }
        const double share = std::min(run / length, 1.0);
        const double angle = twist * share;
        const double grow = 1.0 + (scale - 1.0) * share;
        const gp_Vec side = now.Crossed(across);
        const gp_Vec e1 = across * std::cos(angle) + side * std::sin(angle);
        const gp_Vec e2 = side * std::cos(angle) - across * std::sin(angle);
        for (const auto& [a, b] : local) {
            const double reach = (e1 * a + e2 * b).Dot(bend) / kappa * grow;
            if (reach * kappa > worst) {
                worst = reach * kappa;
                worst_reach = reach;
                worst_radius = 1.0 / kappa;
            }
        }
    }
    if (worst < 1.0 - 1e-9) {
        return "";
    }
    char text[240];
    std::snprintf(text, sizeof(text), "The profile reaches %.3g mm toward the centre of a bend in the path only %.3g mm round: the sweep would cross itself there (make the profile smaller or the bend wider)",
        worst_reach * 1000.0, worst_radius * 1000.0);
    return text;
}

/// Where a profile swept along spine would overlap itself away from its bends: where the path comes
/// back near itself (a helix's next turn, a loop passing over itself) no two of its sections
/// further apart along it than pi times the profile's reach (a bend that doesn't fold, folds()'s
/// check, can't bring nearer ones together) may come closer than they reach toward each other
/// (each section's farthest point that way). The profile is carried square to the path as folds()
/// carries it, turned by twist and scaled, or kept as it is (parallel); a closed path's ends are
/// neighbours. Sampled a third of the profile's reach apart (at most 8000 sections); a pair that
/// comes within that spacing of touching is looked at again where the path's two stretches come
/// closest (sampled pairs a turn apart on a helix are a pitch apart, its turns
/// only the pitch times the cosine of its lead: a 4 mm circle built overlapping 0.008 mm at a
/// 4 mm pitch). Sections either side of one sharp corner (corners) are mitred apart there, by the
/// plane halving the corner, and aren't compared. Empty when none; otherwise a reason saying by
/// how much. (Only local folds were checked: a 4 mm circle swept along a helix of pitch 3 mm built
/// with its turns overlapping 1 mm, counted twice in its volume.)
std::string overlaps(const TopoDS_Wire& spine, const TopoDS_Wire& profile, double twist, double scale, bool parallel, bool closed, const std::vector<Corner>& corners = {})
{
    BRepAdaptor_CompCurve curve(spine);
    const double length = GCPnts_AbscissaPoint::Length(curve);
    if (!(length > 0.0)) {
        return "";
    }
    gp_Pnt start;
    gp_Vec heading;
    curve.D1(curve.FirstParameter(), start, heading);
    if (heading.Magnitude() < 1e-300) {
        return "";
    }
    heading.Normalize();
    gp_Vec across = std::abs(heading.Dot(gp_Vec(gp::DZ()))) < 0.9 ? heading.Crossed(gp_Vec(gp::DZ())) : heading.Crossed(gp_Vec(gp::DX()));
    across.Normalize();
    // The profile's points from the path's start: square to it in the frame (across, heading x
    // across), or as they are when it is kept parallel.
    std::vector<gp_Vec> offsets;
    double reach = 0.0;
    for (const gp_Pnt& q : sampled(profile, 96)) {
        gp_Vec v(start, q);
        if (!parallel) {
            v -= heading * v.Dot(heading);
            v = gp_Vec(v.Dot(across), v.Dot(heading.Crossed(across)), 0.0);
        }
        offsets.push_back(v);
        reach = std::max(reach, v.Magnitude());
    }
    if (!(reach > 0.0)) {
        return "";
    }
    const double widest = reach * std::max(1.0, scale);
    const double apart = M_PI * widest;
    if ((closed ? 0.5 * length : length) <= apart) {
        return "";
    }
    // Sampled at even parameters along each edge, about a third of the profile's reach apart (at
    // most about 8000 in all), how far along by the chords between them; each sample keeps its
    // edge and its parameter there.
    const double spacing = std::max(reach * std::min(1.0, scale) / 3.0, length / 8000.0);
    struct Sample
    {
        gp_Pnt at;
        gp_Vec heading;
        int edge;
        double t;
    };
    std::vector<std::unique_ptr<BRepAdaptor_Curve>> edges;
    std::vector<bool> backwards;
    std::vector<Sample> along_path;
    for (BRepTools_WireExplorer it(spine); it.More(); it.Next()) {
        if (BRep_Tool::Degenerated(it.Current())) {
            continue;
        }
        edges.push_back(std::make_unique<BRepAdaptor_Curve>(it.Current()));
        const BRepAdaptor_Curve& edge = *edges.back();
        const bool backward = it.Current().Orientation() == TopAbs_REVERSED;
        backwards.push_back(backward);
        const int pieces = std::max(1, int(std::ceil(GCPnts_AbscissaPoint::Length(edge) / spacing)));
        for (int k = along_path.empty() ? 0 : 1; k <= pieces; ++k) {
            const double s = double(k) / pieces;
            const double t = backward ? edge.LastParameter() - s * (edge.LastParameter() - edge.FirstParameter()) : edge.FirstParameter() + s * (edge.LastParameter() - edge.FirstParameter());
            gp_Pnt p;
            gp_Vec d;
            edge.D1(t, p, d);
            along_path.push_back({p, backward ? -d : d, int(edges.size()) - 1, t});
        }
    }
    double total = 0.0;
    for (size_t i = 1; i < along_path.size(); ++i) {
        total += along_path[i - 1].at.Distance(along_path[i].at);
    }
    if (along_path.size() < 2 || !(total > 0.0)) {
        return "";
    }
    // Each section: where it is, how far along, its heading, frame (e1, e2) and size.
    struct Section
    {
        gp_Pnt at;
        double run;
        gp_Vec heading;
        gp_Vec e1;
        gp_Vec e2;
        double grow;
    };
    std::vector<Section> sections;
    gp_Pnt at = start;
    gp_Vec tangent = heading;
    double run = 0.0;
    const int count = int(along_path.size()) - 1;
    for (int i = 0; i <= count; ++i) {
        const gp_Pnt next = along_path[i].at;
        const gp_Vec d1 = along_path[i].heading;
        const gp_Vec now = d1.Magnitude() > 1e-300 ? d1.Normalized() : tangent;
        run += i > 0 ? at.Distance(next) : 0.0;
        if (i > 0) {
            // The frame carried on by double reflection (see twist_guide).
            const gp_Vec step(at, next);
            const double c1 = step.SquareMagnitude();
            if (c1 > 1e-300) {
                const gp_Vec reflected = across - step * (2.0 / c1 * step.Dot(across));
                const gp_Vec turned = tangent - step * (2.0 / c1 * step.Dot(tangent));
                const gp_Vec rest = now - turned;
                const double c2 = rest.SquareMagnitude();
                across = c2 > 1e-300 ? reflected - rest * (2.0 / c2 * rest.Dot(reflected)) : reflected;
                across.Normalize();
            }
        }
        at = next;
        tangent = now;
        const double share = std::min(run / total, 1.0);
        const double angle = twist * share;
        const gp_Vec side = now.Crossed(across);
        sections.push_back({next, run, now, across * std::cos(angle) + side * std::sin(angle), side * std::cos(angle) - across * std::sin(angle), 1.0 + (scale - 1.0) * share});
    }
    // How far a section reaches along direction, its frame turned from its own heading to facing
    // (where it is looked at a little way along).
    auto toward = [&](const Section& s, const gp_Vec& direction, const gp_Vec& facing) {
        if (parallel) {
            double most = -1e300;
            for (const gp_Vec& v : offsets) {
                most = std::max(most, v.Dot(direction));
            }
            return most * s.grow;
        }
        const gp_Vec axis = s.heading.Crossed(facing);
        const double turn = s.heading.Angle(facing);
        const double x = turned_about(s.e1, axis, turn).Dot(direction);
        const double y = turned_about(s.e2, axis, turn).Dot(direction);
        double most = -1e300;
        for (const gp_Vec& v : offsets) {
            most = std::max(most, v.X() * x + v.Y() * y);
        }
        return most * s.grow;
    };
    // Where two stretches of the path come closest near samples a and b: damped Newton steps on
    // the squared distance between their edges' curves (the stretches run nearly side by side),
    // kept on each edge. Gives the points and headings there.
    auto closest = [&](const Sample& a, const Sample& b, gp_Pnt& pa, gp_Vec& ha, gp_Pnt& pb, gp_Vec& hb) {
        const BRepAdaptor_Curve& ca = *edges[a.edge];
        const BRepAdaptor_Curve& cb = *edges[b.edge];
        double s = a.t;
        double t = b.t;
        gp_Vec a1, a2, b1, b2;
        for (int iteration = 0; iteration < 12; ++iteration) {
            ca.D2(s, pa, a1, a2);
            cb.D2(t, pb, b1, b2);
            const gp_Vec d(pb, pa);
            const double g1 = d.Dot(a1);
            const double g2 = -d.Dot(b1);
            double h11 = a1.Dot(a1) + d.Dot(a2);
            double h22 = b1.Dot(b1) - d.Dot(b2);
            const double h12 = -a1.Dot(b1);
            const double damping = 1e-6 * (std::abs(h11) + std::abs(h22));
            h11 += damping;
            h22 += damping;
            const double det = h11 * h22 - h12 * h12;
            if (!(std::abs(det) > 1e-300)) {
                break;
            }
            double ds = -(h22 * g1 - h12 * g2) / det;
            double dt = -(h11 * g2 - h12 * g1) / det;
            // (At most two samples' spacing a step along each curve.)
            const double sa = a1.Magnitude() * std::abs(ds);
            const double sb = b1.Magnitude() * std::abs(dt);
            if (sa > 2.0 * spacing) {
                ds *= 2.0 * spacing / sa;
            }
            if (sb > 2.0 * spacing) {
                dt *= 2.0 * spacing / sb;
            }
            s = std::clamp(s + ds, ca.FirstParameter(), ca.LastParameter());
            t = std::clamp(t + dt, cb.FirstParameter(), cb.LastParameter());
            if (std::abs(ds) * a1.Magnitude() < 1e-12 * length && std::abs(dt) * b1.Magnitude() < 1e-12 * length) {
                break;
            }
        }
        ca.D1(s, pa, a1);
        cb.D1(t, pb, b1);
        ha = backwards[a.edge] ? -a1 : a1;
        hb = backwards[b.edge] ? -b1 : b1;
        ha = ha.Magnitude() > 1e-300 ? ha.Normalized() : a.heading;
        hb = hb.Magnitude() > 1e-300 ? hb.Normalized() : b.heading;
    };
    // The one sharp corner between two sections (by how far along each is, the short way round a
    // closed path): its index, -1 for none, -2 for more than one.
    auto corner_between = [&](double from, double to, bool wrapped) {
        int found = -1;
        for (size_t c = 0; c < corners.size(); ++c) {
            const double r = corners[c].run * total / length;
            if (wrapped ? (r > to || r < from) : (r > from && r < to)) {
                if (found != -1) {
                    return -2;
                }
                found = int(c);
            }
        }
        return found;
    };
    // True when a section lies wholly on its own side of a corner's halving plane (before or after
    // it), or so near the corner that the mitre there cuts it back.
    auto own_side = [&](const Section& s, const Corner& corner, bool before) {
        gp_Vec halving = corner.in + corner.out;
        if (halving.Magnitude() < 1e-300) {
            return false;
        }
        halving.Normalize();
        const double r = corner.run * total / length;
        const double cut = widest * std::tan(0.5 * std::min(corner.turn, M_PI - 1e-9)) + 2.0 * spacing;
        if (std::abs(s.run - r) <= cut || std::abs(std::abs(s.run - r) - total) <= cut) {
            return true;
        }
        const gp_Vec from_corner(corner.at, s.at);
        return before ? -from_corner.Dot(halving) >= toward(s, halving, s.heading) : from_corner.Dot(halving) >= toward(s, -halving, s.heading);
    };
    // Sections near each other found through a grid of cubes 2 reaches across.
    const double cell = 2.0 * widest;
    auto key = [&](const gp_Pnt& p) {
        return std::array<long long, 3>{(long long)std::floor(p.X() / cell), (long long)std::floor(p.Y() / cell), (long long)std::floor(p.Z() / cell)};
    };
    std::map<std::array<long long, 3>, std::vector<int>> grid;
    for (int i = 0; i <= count; ++i) {
        grid[key(sections[i].at)].push_back(i);
    }
    double worst = 0.0;
    double worst_gap = 0.0;
    double worst_along = 0.0;
    for (int i = 0; i <= count; ++i) {
        const Section& a = sections[i];
        const std::array<long long, 3> k = key(a.at);
        for (long long dx = -1; dx <= 1; ++dx) {
            for (long long dy = -1; dy <= 1; ++dy) {
                for (long long dz = -1; dz <= 1; ++dz) {
                    const auto found = grid.find({k[0] + dx, k[1] + dy, k[2] + dz});
                    if (found == grid.end()) {
                        continue;
                    }
                    for (const int j : found->second) {
                        if (j <= i) {
                            continue;
                        }
                        const Section& b = sections[j];
                        const double forward = b.run - a.run;
                        const bool wrapped = closed && total - forward < forward;
                        const double along = wrapped ? total - forward : forward;
                        if (along <= apart) {
                            continue;
                        }
                        // (Sampled points lie up to a spacing further apart than the stretches
                        // they stand for come.)
                        const gp_Vec gap(a.at, b.at);
                        const double distance = gap.Magnitude();
                        if (distance >= reach * (a.grow + b.grow) + spacing) {
                            continue;
                        }
                        if (!corners.empty()) {
                            const int c = corner_between(a.run, b.run, wrapped);
                            // (The short way round a closed path, b comes before the corner.)
                            if (c >= 0 && own_side(wrapped ? b : a, corners[c], true) && own_side(wrapped ? a : b, corners[c], false)) {
                                continue;
                            }
                        }
                        double over = distance < 1e-12 * length ? reach * (a.grow + b.grow) : toward(a, gap / distance, a.heading) + toward(b, -gap / distance, b.heading) - distance;
                        if (!parallel && over > -spacing) {
                            gp_Pnt pa;
                            gp_Pnt pb;
                            gp_Vec ha;
                            gp_Vec hb;
                            closest(along_path[i], along_path[j], pa, ha, pb, hb);
                            const gp_Vec near(pa, pb);
                            const double d = near.Magnitude();
                            if (d > 1e-12 * length) {
                                over = std::max(over, toward(a, near / d, ha) + toward(b, -near / d, hb) - d);
                            }
                        }
                        if (over > worst) {
                            worst = over;
                            worst_gap = distance;
                            worst_along = along;
                        }
                    }
                }
            }
        }
    }
    if (worst <= 1e-4 * reach) {
        return "";
    }
    char text[300];
    std::snprintf(text, sizeof(text), "The sweep would overlap itself by %.3g mm where the path comes back within %.3g mm of itself (%.3g mm further along), closer than the profile reaches across (make the profile smaller or move those parts of the path apart)",
        worst * 1000.0, worst_gap * 1000.0, worst_along * 1000.0);
    return text;
}

/// Where a profile swept along spine without turning (parallel) would fold over itself: the path
/// must keep going through the profile's plane the way it starts. Empty when it does.
std::string folds_parallel(const TopoDS_Wire& spine)
{
    BRepAdaptor_CompCurve curve(spine);
    const double f = curve.FirstParameter();
    const double l = curve.LastParameter();
    gp_Pnt p;
    gp_Vec start;
    curve.D1(f, p, start);
    if (start.Magnitude() < 1e-300) {
        return "";
    }
    start.Normalize();
    const int count = std::clamp(32 * curve.NbIntervals(GeomAbs_C2) + 256, 256, 4000);
    for (int i = 1; i <= count; ++i) {
        gp_Vec d;
        curve.D1(f + (l - f) * i / count, p, d);
        if (d.Magnitude() > 1e-300 && d.Dot(start) / d.Magnitude() <= 1e-6) {
            return "The path turns until it runs along the profile's plane, so a parallel sweep would cross itself (choose Perpendicular)";
        }
    }
    return "";
}

TopoDS_Wire split_at_shares(const TopoDS_Wire& wire, const std::vector<double>& shares);

/// A wire in count parts of even length, each a wire of its own (empty when it can't be split).
std::vector<TopoDS_Wire> in_parts(const TopoDS_Wire& wire, int count)
{
    std::vector<double> shares;
    for (int k = 1; k < count; ++k) {
        shares.push_back(double(k) / count);
    }
    const TopoDS_Wire cut = split_at_shares(wire, shares);
    if (cut.IsNull()) {
        return {};
    }
    double whole = 0.0;
    for (BRepTools_WireExplorer it(cut); it.More(); it.Next()) {
        whole += measure::length(it.Current());
    }
    std::vector<BRepBuilderAPI_MakeWire> makers(count);
    double run = 0.0;
    for (BRepTools_WireExplorer it(cut); it.More(); it.Next()) {
        const double length = measure::length(it.Current());
        // (Placed by its middle: its ends lie on the cuts.)
        const int part = std::clamp(int(std::floor((run + 0.5 * length) / whole * count)), 0, count - 1);
        makers[part].Add(it.Current());
        run += length;
    }
    std::vector<TopoDS_Wire> parts;
    for (BRepBuilderAPI_MakeWire& maker : makers) {
        if (!maker.IsDone()) {
            return {};
        }
        parts.push_back(maker.Wire());
    }
    return parts;
}

/// True when every vertex and edge middle of a lies within tolerance of b (a pipe's first section
/// where the pipe before it ended).
bool coincide(const TopoDS_Shape& a, const TopoDS_Shape& b, double tolerance)
{
    if (a.IsNull() || b.IsNull()) {
        return false;
    }
    std::vector<gp_Pnt> points;
    for (TopExp_Explorer it(a, TopAbs_VERTEX); it.More(); it.Next()) {
        points.push_back(BRep_Tool::Pnt(TopoDS::Vertex(it.Current())));
    }
    for (TopExp_Explorer it(a, TopAbs_EDGE); it.More(); it.Next()) {
        const BRepAdaptor_Curve curve(TopoDS::Edge(it.Current()));
        points.push_back(curve.Value(0.5 * (curve.FirstParameter() + curve.LastParameter())));
    }
    for (const gp_Pnt& point : points) {
        const BRepExtrema_DistShapeShape distance(BRepBuilderAPI_MakeVertex(point).Vertex(), b);
        if (!distance.IsDone() || distance.NbSolution() == 0 || distance.Value() > tolerance) {
            return false;
        }
    }
    return true;
}

/// An edge turned, if need be, to run the way along does (a piece of it, or a copy).
TopoDS_Edge same_way(const TopoDS_Edge& edge, const TopoDS_Edge& along)
{
    const BRepAdaptor_Curve curve(edge);
    gp_Pnt middle;
    gp_Vec heading;
    curve.D1(0.5 * (curve.FirstParameter() + curve.LastParameter()), middle, heading);
    if (edge.Orientation() == TopAbs_REVERSED) {
        heading.Reverse();
    }
    double f = 0.0;
    double l = 0.0;
    const Handle(Geom_Curve) on = BRep_Tool::Curve(along, f, l);
    if (on.IsNull()) {
        return edge;
    }
    gp_Pnt nearest;
    double at = 0.0;
    ShapeAnalysis_Curve().Project(on, middle, Precision::Confusion(), nearest, at, f, l, false);
    gp_Vec way;
    on->D1(at, nearest, way);
    if (along.Orientation() == TopAbs_REVERSED) {
        way.Reverse();
    }
    return heading.Dot(way) < 0.0 ? TopoDS::Edge(edge.Reversed()) : edge;
}

/// The halves of a twisted solid sweep round a closed path (the second carrying on from the
/// first's end; ends: each half's first and last cap) as one solid: their faces sewn together,
/// less the caps where they meet, and where the ring closes what of each end the other doesn't
/// cover (the ends lie in one plane there, turned against each other by the twist; where they
/// overlap the ring runs on through). Sewn, not fused: fusing the halves' walls, which meet
/// tangent along the section between them, took 12 to 130 s. Null when that doesn't close up
/// into one sound solid of the halves' volume.
TopoDS_Shape ring_closed(const std::vector<TopoDS_Shape>& halves, const std::vector<std::array<TopoDS_Shape, 2>>& ends, double size)
{
    const TopoDS_Shape start = ends.front()[0];
    const TopoDS_Shape finish = ends.back()[1];
    if (start.IsNull() || finish.IsNull() || start.ShapeType() != TopAbs_FACE || finish.ShapeType() != TopAbs_FACE) {
        return TopoDS_Shape();
    }
    TopTools_MapOfShape caps;
    double whole = 0.0;
    for (size_t k = 0; k < halves.size(); ++k) {
        caps.Add(ends[k][0]);
        caps.Add(ends[k][1]);
        whole += measure::volume(halves[k]).Mass();
    }
    // The two ends split against each other (a general fuse): the pieces of each that the other
    // doesn't cover, and the ends' outlines cut where they cross. The walls along those outlines
    // take the cut edges in place of their own, so walls and pieces share them (each end cut by
    // the other left the walls' edges whole for sewing to cut where the pieces' stop).
    BRepAlgoAPI_BuilderAlgo split;
    TopTools_ListOfShape both;
    both.Append(start);
    both.Append(finish);
    split.SetArguments(both);
    split.SetNonDestructive(true);
    split.Build();
    if (!split.IsDone() || split.HasErrors()) {
        return TopoDS_Shape();
    }
    auto images = [&](const TopoDS_Shape& s) {
        TopTools_MapOfShape out;
        for (TopTools_ListOfShape::Iterator it(split.Modified(s)); it.More(); it.Next()) {
            out.Add(it.Value());
        }
        if (out.IsEmpty() && !split.IsDeleted(s)) {
            out.Add(s);
        }
        return out;
    };
    BRepTools_ReShape reshape;
    for (const TopoDS_Shape& end : {start, finish}) {
        for (TopExp_Explorer it(end, TopAbs_EDGE); it.More(); it.Next()) {
            const TopoDS_Edge edge = TopoDS::Edge(it.Current().Oriented(TopAbs_FORWARD));
            const TopTools_ListOfShape& parts = split.Modified(edge);
            // (An edge the other end only lies along, uncut, is left for sewing to match: taken
            // from the other end, the wall's edge strayed off its face, and a box cut from a ring
            // twisted a full turn came out 5e-6 big.)
            if (parts.Extent() < 2 || reshape.IsRecorded(edge)) {
                continue;
            }
            TopoDS_Compound along;
            BRep_Builder builder;
            builder.MakeCompound(along);
            for (TopTools_ListOfShape::Iterator part(parts); part.More(); part.Next()) {
                builder.Add(along, same_way(TopoDS::Edge(part.Value()), edge));
            }
            reshape.Replace(edge, along);
        }
    }
    std::vector<TopoDS_Shape> faces;
    for (const TopoDS_Shape& half : halves) {
        for (TopExp_Explorer it(half, TopAbs_FACE); it.More(); it.Next()) {
            if (!caps.Contains(it.Current())) {
                faces.push_back(reshape.Apply(it.Current()));
            }
        }
    }
    const double cap_area = measure::surface(start).Mass();
    const TopTools_MapOfShape of_start = images(start);
    const TopTools_MapOfShape of_finish = images(finish);
    for (const auto& [kept, other] : {std::pair<const TopTools_MapOfShape*, const TopTools_MapOfShape*>{&of_start, &of_finish}, {&of_finish, &of_start}}) {
        for (TopTools_MapOfShape::Iterator it(*kept); it.More(); it.Next()) {
            if (!other->Contains(it.Value()) && measure::surface(it.Value()).Mass() > 1e-9 * cap_area) {
                faces.push_back(it.Value());
            }
        }
    }
    BRepBuilderAPI_Sewing sewing(1e-7 * size);
    for (const TopoDS_Shape& face : faces) {
        sewing.Add(face);
    }
    sewing.Perform();
    const TopTools_IndexedMapOfShape shells = map_of(sewing.SewedShape(), TopAbs_SHELL);
    if (shells.Extent() != 1 || !closed_shell(shells(1))) {
        return TopoDS_Shape();
    }
    BRepBuilderAPI_MakeSolid maker(TopoDS::Shell(shells(1)));
    if (!maker.IsDone()) {
        return TopoDS_Shape();
    }
    TopoDS_Solid solid = maker.Solid();
    BRepLib::OrientClosedSolid(solid);
    if (!sound(solid) || std::abs(measure::volume(solid).Mass() - whole) > 1e-7 * whole) {
        return TopoDS_Shape();
    }
    return solid;
}

}  // namespace

Shape sweep(const Shape& profile, const Shape& path, const Dictionary& p, String& error, String& note)
{
    if (!usable(profile) || !usable(path)) {
        error = "Sweep needs a profile and a path";
        return Shape();
    }
    const std::string tag = tag_of(p, "sweep");
    const double twist = p.get("twist", 0.0);
    const double scale = p.get("scale", 1.0);
    const String orientation = p.get("orientation", "perpendicular");
    Ref<CadShape> guide = p.get("guide", Variant());
    const bool surface = p.get("surface", false);
    const bool guided = guide.is_valid() && !guide->is_null();
    if (std::abs(twist) > 1e-9 && (guided || orientation == "parallel")) {
        // (The twisted sweep turns the profile by an auxiliary spine of its own: a guide rail, or a
        // profile kept parallel, would be dropped.)
        error = guided ? "A twisted sweep can't follow a guide rail too (the rail sets how the profile turns): set Twist to 0 or remove the guide rail"
                       : "A twisted sweep turns the profile about the path, so it can't keep it parallel: set Twist to 0 or choose Perpendicular";
        return Shape();
    }
    try {
        TopoDS_Wire spine = connect(path->get_occ_shape(), error);
        if (spine.IsNull()) {
            return Shape();
        }
        const bool loop = BRep_Tool::IsClosed(spine) || spine.Closed();
        // Solids sweep each profile's outer loop; surfaces every loop and curve, as open skins.
        std::vector<TopoDS_Wire> loops;
        if (surface) {
            for (const ProfileWire& w : profile_wires(profile->get_occ_shape())) {
                loops.push_back(w.wire);
            }
        }
        else {
            for (const TopoDS_Face& face : faces_of(profile->get_occ_shape())) {
                loops.push_back(BRepTools::OuterWire(face));
            }
        }
        if (loops.empty()) {
            error = "Pick a profile to sweep";
            return Shape();
        }
        // A closed path starts where the profile sits on it, its point nearest the profile's
        // middle (drawn on a circle half way round from where the circle starts, the profile was
        // measured from there and refused as reaching 41 mm across a 20 mm ring).
        gp_Pnt middle;
        gp_Vec facing;
        if (loop && loop_plane(loops.front(), middle, facing)) {
            spine = restarted(spine, middle);
        }
        // Sharp corners are mitred where the profile is carried square round them (mitred_pipe());
        // a profile turned, scaled or guided along the path can't be.
        const bool kept_parallel = !guided && orientation == "parallel" && std::abs(twist) <= 1e-9;
        const std::vector<Corner> corners = kept_parallel ? std::vector<Corner>() : sharp_corners(spine, loop);
        if (!corners.empty() && (std::abs(twist) > 1e-9 || std::abs(scale - 1.0) > 1e-9 || guided)) {
            double sharpest = 0.0;
            for (const Corner& corner : corners) {
                sharpest = std::max(sharpest, corner.turn);
            }
            char text[300];
            std::snprintf(text, sizeof(text), "A %s sweep can't carry its profile round the path's sharp corners (it turns %.3g deg at one): round the corners off, or %s",
                std::abs(twist) > 1e-9 ? "twisted" : guided ? "guided" : "scaled", sharpest * 180.0 / M_PI, std::abs(twist) > 1e-9 ? "set Twist to 0" : guided ? "remove the guide rail" : "set Scale to 1");
            error = text;
            return Shape();
        }
        // A twist can't close on itself round a closed path (a square turned 45 deg doesn't meet its
        // start): the path is opened where it starts, and the sweep capped at both ends there.
        const bool ring = std::abs(twist) > 1e-9 && loop;
        if (ring) {
            spine = opened(spine);
        }
        std::vector<TopoDS_Shape> solids;
        for (const TopoDS_Wire& outer : loops) {
            // A profile reaching past the centre of a bend (or a parallel one the path turns along)
            // sweeps a skin that crosses itself: such a solid came out with a negative volume. A
            // guided one is checked as a plain one is (a 0.2 mm square guided round a 0.05 mm bend
            // built with no volume, unchecked). Where the path comes back near itself its
            // sections may overlap too (overlaps()).
            std::string fold = kept_parallel ? folds_parallel(spine) : folds(spine, outer, twist, scale);
            if (fold.empty()) {
                fold = overlaps(spine, outer, twist, scale, kept_parallel, loop, corners);
            }
            if (!fold.empty()) {
                error = String::utf8(fold.c_str());
                return Shape();
            }
            if (std::abs(twist) > 1e-9) {
                // Twisted: swept as a plain path is, the section turned by an auxiliary spine wound
                // round the path (a loft through turned copies cut corners between them: a square
                // turned 1080 deg came out 38 % big, and along a helix any twist lost 0.4 %). The
                // spine runs close (a hundredth of the section): the pipe finds it in each plane
                // square to the path, which a wide one round a coiled path crosses more than once.
                // Round a ring that plane at its ends crosses the spine's start and its end, both
                // beside the path there (the fit came out 1 mm off a 2 mm square): a ring is swept
                // in thirds, each carrying on from the one before's end, and joined. (In halves,
                // the plane at a half's start runs through its far end too: on a turned ring, one
                // in six, the pipe found the wound spine there and set the second half's section
                // turned against the first's end, which then took the slow fuse, up to 130 s.)
                // A small one is made at TWIST_SIZE and scaled back (a 0.1 mm rectangle round a
                // 2 mm ring twisted 1 deg came out a third short where its ends were joined).
                Bnd_Box box;
                BRepBndLib::Add(spine, box);
                BRepBndLib::Add(outer, box);
                const double factor = diagonal(outer) < TWIST_SIZE ? TWIST_SIZE / diagonal(outer) : 1.0;
                gp_Trsf grow;
                if (factor != 1.0) {
                    grow.SetScale(gp_Pnt((box.CornerMin().XYZ() + box.CornerMax().XYZ()) * 0.5), factor);
                }
                auto up = [&](const TopoDS_Wire& wire) { return factor != 1.0 ? TopoDS::Wire(BRepBuilderAPI_Transform(wire, grow, true).Shape()) : wire; };
                const TopoDS_Wire spine_up = up(spine);
                const double size = factor * diagonal(outer);
                std::vector<TopoDS_Wire> legs = {spine_up};
                if (ring) {
                    legs = in_parts(spine_up, 3);
                    if (legs.empty()) {
                        error = "The twisted sweep round the closed path could not be built";
                        return Shape();
                    }
                }
                // A profile square to the path at its start stays where it is.
                gp_Pnt profile_middle;
                gp_Vec profile_normal;
                gp_Pnt first;
                gp_Vec heading;
                BRepAdaptor_CompCurve(spine).D1(BRepAdaptor_CompCurve(spine).FirstParameter(), first, heading);
                const bool square_start = loop_plane(outer, profile_middle, profile_normal) && heading.Magnitude() > 1e-300 &&
                    std::abs(profile_normal.Normalized().Dot(heading.Normalized())) > 1.0 - 1e-9;
                const double length = GCPnts_AbscissaPoint::Length(BRepAdaptor_CompCurve(spine_up));
                gp_Vec across;
                double done = 0.0;
                TopoDS_Wire section = up(outer);
                std::vector<TopoDS_Shape> pieces;
                std::vector<std::array<TopoDS_Shape, 2>> ends;
                TopoDS_Shape pipe_end;
                for (const TopoDS_Wire& leg : legs) {
                    const double run = GCPnts_AbscissaPoint::Length(BRepAdaptor_CompCurve(leg));
                    const double grow_from = 1.0 + (scale - 1.0) * done / length;
                    const double grow_to = 1.0 + (scale - 1.0) * (done + run) / length;
                    const TopoDS_Wire wound = twist_guide(leg, twist * done / length, twist * (done + run) / length, 0.01 * size, across);
                    std::unique_ptr<BRepOffsetAPI_MakePipeShell> pipe;
                    String fitted;
                    bool displaced = false;
                    for (const bool correct : {true, false}) {
                        if (wound.IsNull() || pipe) {
                            break;
                        }
                        try {
                            pipe = fitted_pipe(leg, size, !surface, 1e-2, [&](BRepOffsetAPI_MakePipeShell& maker) {
                                maker.SetMode(wound, false, BRepFill_NoContact);
                                if (std::abs(grow_to / grow_from - 1.0) > 1e-9) {
                                    Handle(Law_Linear) law = new Law_Linear();
                                    law->Set(0.0, 1.0, 1.0, grow_to / grow_from);
                                    maker.SetLaw(section, law, false, correct);
                                }
                                else {
                                    maker.Add(section, false, correct);
                                }
                            }, "twisted sweep", fitted, factor);
                        }
                        catch (const Standard_Failure&) {
                            if (!correct) {
                                throw;
                            }
                        }
                        // Each part after the first starts where the one before ended (and the
                        // first where the profile is, when that is square to the path): corrected
                        // square to the path, OCCT turned that end, already square, by up to a
                        // seventh of the section on a turned ring (a step in the twist there).
                        if (pipe && (!pieces.empty() || square_start) && !coincide(pipe->FirstShape(), pieces.empty() ? TopoDS_Shape(section) : pipe_end, 1e-6 * size)) {
                            pipe.reset();
                            displaced = true;
                        }
                    }
                    if (!pipe) {
                        error = !displaced                 ? "The twisted sweep could not be built"
                            : pieces.empty() ? "The twisted sweep could not be built from where the profile is (is the profile at the start of the path?)"
                                             : "The twisted sweep round the closed path could not be built evenly (one part of it came out turned against the next)";
                        return Shape();
                    }
                    pipe_end = pipe->LastShape();
                    note = fitted.is_empty() ? note : fitted;
                    pieces.push_back(pipe->Shape());
                    ends.push_back({surface ? TopoDS_Shape() : pipe->FirstShape(), surface ? TopoDS_Shape() : pipe->LastShape()});
                    done += run;
                    // The next half starts from where this one ends.
                    const TopoDS_Shape end = pipe->LastShape();
                    section = end.ShapeType() == TopAbs_FACE ? BRepTools::OuterWire(TopoDS::Face(end))
                        : end.ShapeType() == TopAbs_WIRE    ? TopoDS::Wire(end)
                                                            : BRepBuilderAPI_MakeWire(TopoDS::Edge(TopExp_Explorer(end, TopAbs_EDGE).Current())).Wire();
                }
                auto down = [&](const TopoDS_Shape& shape) { return factor != 1.0 ? BRepBuilderAPI_Transform(shape, grow.Inverted(), true).Shape() : shape; };
                if (pieces.size() == 1) {
                    solids.push_back(down(pieces[0]));
                    continue;
                }
                TopoDS_Shape joined;
                if (surface) {
                    BRepBuilderAPI_Sewing sewing(1e-7 * size);
                    for (const TopoDS_Shape& piece : pieces) {
                        sewing.Add(piece);
                    }
                    sewing.Perform();
                    joined = sewing.SewedShape();
                }
                else {
                    joined = ring_closed(pieces, ends, size);
                    if (joined.IsNull()) {
                        // (The slow way, as round 4 joined them.)
                        TopTools_ListOfShape first;
                        first.Append(pieces[0]);
                        TopTools_ListOfShape rest;
                        for (size_t k = 1; k < pieces.size(); ++k) {
                            rest.Append(pieces[k]);
                        }
                        BRepAlgoAPI_Fuse all;
                        all.SetArguments(first);
                        all.SetTools(rest);
                        all.Build();
                        joined = all.IsDone() ? all.Shape() : TopoDS_Shape();
                    }
                }
                if (joined.IsNull() || (!surface && map_of(joined, TopAbs_SOLID).Extent() != 1)) {
                    error = "The twisted sweep round the closed path could not be joined up";
                    return Shape();
                }
                solids.push_back(down(joined));
                continue;
            }
            if (!corners.empty()) {
                const TopoDS_Shape mitre = mitred_pipe(spine, outer, !surface, loop, corners, "sweep", error, note);
                if (mitre.IsNull()) {
                    return Shape();
                }
                solids.push_back(mitre);
                continue;
            }
            // The profile is turned square to the path where it has a plane to turn; an open
            // curve that has none (one straight line) is swept as it lies.
            TopoDS_Shape swept;
            for (const bool correct : {true, false}) {
                try {
                    const auto pipe = fitted_pipe(spine, diagonal(outer), !surface, 1e-2, [&](BRepOffsetAPI_MakePipeShell& maker) {
                        if (guide.is_valid() && !guide->is_null()) {
                            maker.SetMode(connect(guide->get_occ_shape(), error), true, BRepFill_ContactOnBorder);
                        }
                        else if (orientation == "parallel") {
                            gp_Pnt p0;
                            gp_Vec t0;
                            BRepAdaptor_CompCurve(spine).D1(BRepAdaptor_CompCurve(spine).FirstParameter(), p0, t0);
                            maker.SetMode(gp_Ax2(p0, gp_Dir(t0)));
                        }
                        else {
                            maker.SetMode(false);
                        }
                        if (std::abs(scale - 1.0) > 1e-9) {
                            Handle(Law_Linear) law = new Law_Linear();
                            law->Set(0.0, 1.0, 1.0, scale);
                            maker.SetLaw(outer, law, false, correct);
                        }
                        else {
                            maker.Add(outer, false, correct);
                        }
                    }, "sweep", note);
                    if (pipe) {
                        swept = pipe->Shape();
                        break;
                    }
                }
                catch (const Standard_Failure&) {
                    if (!surface || !correct) {
                        throw;
                    }
                }
                if (!surface) {
                    break;
                }
            }
            if (swept.IsNull()) {
                error = "The sweep could not be built (is the profile at the start of the path?)";
                return Shape();
            }
            solids.push_back(swept);
        }
        for (const TopoDS_Shape& solid : solids) {
            GProp_GProps props;
            BRepGProp::VolumeProperties(solid, props, true);
            if (!surface && props.Mass() < 0.0) {
                error = "The sweep would cross itself (it came out inside out)";
                return Shape();
            }
        }
        return named(solids.size() == 1 ? solids[0] : make_compound(solids), tag);
    }
    catch (const Standard_Failure& failure) {
        error = String("Sweep failed: ") + failure.GetMessageString();
        return Shape();
    }
}

namespace
{
/// A rail (a wire) measured by length along it, the way it runs.
struct RailCurve
{
    std::vector<Handle(BRepAdaptor_Curve)> curves;
    std::vector<bool> reversed;
    /// How far along the rail each edge starts; the last is the rail's length.
    std::vector<double> starts{0.0};

    explicit RailCurve(const TopoDS_Wire& wire)
    {
        for (BRepTools_WireExplorer it(wire); it.More(); it.Next()) {
            if (BRep_Tool::Degenerated(it.Current())) {
                continue;
            }
            Handle(BRepAdaptor_Curve) curve = new BRepAdaptor_Curve(it.Current());
            curves.push_back(curve);
            reversed.push_back(it.Current().Orientation() == TopAbs_REVERSED);
            starts.push_back(starts.back() + GCPnts_AbscissaPoint::Length(*curve));
        }
    }

    double length() const { return starts.back(); }

    /// The edge run along the rail lies on: of two meeting there, the one ending there (side < 0)
    /// or the one starting there.
    size_t edge_at(double run, int side) const
    {
        for (size_t k = 0; k < curves.size(); ++k) {
            if (side < 0 ? run <= starts[k + 1] : run < starts[k + 1]) {
                return k;
            }
        }
        return curves.size() - 1;
    }

    /// The point run along the rail, and (heading) the way the rail runs there, on the edge ending
    /// there when side < 0.
    gp_Pnt point(double run, gp_Vec* heading = nullptr, int side = 1) const
    {
        const size_t k = edge_at(run, side);
        const BRepAdaptor_Curve& curve = *curves[k];
        const double d = std::clamp(run - starts[k], 0.0, starts[k + 1] - starts[k]);
        double t = reversed[k] ? curve.LastParameter() : curve.FirstParameter();
        if (d > 0.0) {
            t = GCPnts_AbscissaPoint(curve, reversed[k] ? -d : d, t).Parameter();
        }
        gp_Pnt p;
        gp_Vec v;
        curve.D1(t, p, v);
        if (heading != nullptr) {
            if (reversed[k]) {
                v.Reverse();
            }
            *heading = v.Magnitude() > 1e-300 ? v.Normalized() : gp_Vec(0.0, 0.0, 0.0);
        }
        return p;
    }

    /// How far along the rail the point on it nearest point lies.
    double locate(const gp_Pnt& point) const
    {
        double best = 1e300;
        double run = 0.0;
        for (size_t k = 0; k < curves.size(); ++k) {
            const BRepAdaptor_Curve& curve = *curves[k];
            gp_Pnt on;
            double t = curve.FirstParameter();
            const double d = ShapeAnalysis_Curve().Project(curve, point, 1e-9 * length(), on, t, false);
            if (d < best) {
                best = d;
                run = starts[k] + (reversed[k] ? GCPnts_AbscissaPoint::Length(curve, t, curve.LastParameter()) : GCPnts_AbscissaPoint::Length(curve, curve.FirstParameter(), t));
            }
        }
        return run;
    }

    /// How far along the rail it turns at a corner (where one edge meets the next off its heading).
    std::vector<double> corners() const
    {
        std::vector<double> found;
        for (size_t k = 1; k < curves.size(); ++k) {
            gp_Vec before;
            gp_Vec after;
            point(starts[k], &before, -1);
            point(starts[k], &after, 1);
            if (before.Magnitude() > 0.0 && after.Magnitude() > 0.0 && before.Angle(after) > 1e-6) {
                found.push_back(starts[k]);
            }
        }
        return found;
    }

    /// How far it turns (radians) between from and to along it.
    double turn(double from, double to) const
    {
        double total = 0.0;
        gp_Vec was;
        point(from, &was, 1);
        for (int i = 1; i <= 32; ++i) {
            gp_Vec now;
            point(from + (to - from) * i / 32, &now, i == 32 ? -1 : 1);
            if (was.Magnitude() > 0.0 && now.Magnitude() > 0.0) {
                total += was.Angle(now);
            }
            was = now;
        }
        return total;
    }
};

/// A loop (or an open wire) run the other way from the same start (an open one: from its other end).
TopoDS_Wire reversed_loop(const TopoDS_Wire& loop)
{
    std::vector<TopoDS_Edge> edges;
    for (BRepTools_WireExplorer it(loop); it.More(); it.Next()) {
        edges.push_back(it.Current());
    }
    BRepBuilderAPI_MakeWire maker;
    for (auto it = edges.rbegin(); it != edges.rend(); ++it) {
        maker.Add(TopoDS::Edge(it->Reversed()));
    }
    return maker.IsDone() ? maker.Wire() : loop;
}

/// Where a wire's vertices lie, by length from its start as a share of its whole (0 first).
std::vector<double> vertex_shares(const TopoDS_Wire& wire)
{
    std::vector<double> lengths;
    double whole = 0.0;
    for (BRepTools_WireExplorer it(wire); it.More(); it.Next()) {
        lengths.push_back(measure::length(it.Current()));
        whole += lengths.back();
    }
    std::vector<double> shares;
    double run = 0.0;
    for (const double l : lengths) {
        shares.push_back(whole > 0.0 ? run / whole : 0.0);
        run += l;
    }
    return shares;
}

/// The wire with its edges split so that it has a vertex at each share (by length from its start,
/// of its whole; ones it has are kept).
TopoDS_Wire split_at_shares(const TopoDS_Wire& wire, const std::vector<double>& shares)
{
    std::vector<TopoDS_Edge> edges;
    std::vector<double> lengths;
    double whole = 0.0;
    for (BRepTools_WireExplorer it(wire); it.More(); it.Next()) {
        edges.push_back(it.Current());
        lengths.push_back(measure::length(it.Current()));
        whole += lengths.back();
    }
    BRepBuilderAPI_MakeWire maker;
    double run = 0.0;
    for (size_t k = 0; k < edges.size(); ++k) {
        const TopoDS_Edge& edge = edges[k];
        const bool backward = edge.Orientation() == TopAbs_REVERSED;
        std::vector<double> params;
        for (const double share : shares) {
            const double d = share * whole - run;
            if (d > 1e-9 * whole && d < lengths[k] - 1e-9 * whole) {
                params.push_back(measure::parameter_at_length(edge, backward ? lengths[k] - d : d));
            }
        }
        run += lengths[k];
        if (params.empty()) {
            maker.Add(edge);
            continue;
        }
        std::sort(params.begin(), params.end());
        double f = 0.0;
        double l = 0.0;
        const Handle(Geom_Curve) curve = BRep_Tool::Curve(edge, f, l);
        TopoDS_Vertex from;
        TopoDS_Vertex to;
        TopExp::Vertices(TopoDS::Edge(edge.Oriented(TopAbs_FORWARD)), from, to);
        std::vector<TopoDS_Edge> pieces;
        double a = f;
        TopoDS_Vertex at = from;
        for (const double t : params) {
            const TopoDS_Vertex cut = BRepBuilderAPI_MakeVertex(curve->Value(t)).Vertex();
            pieces.push_back(BRepBuilderAPI_MakeEdge(curve, at, cut, a, t).Edge());
            a = t;
            at = cut;
        }
        pieces.push_back(BRepBuilderAPI_MakeEdge(curve, at, to, a, l).Edge());
        if (backward) {
            std::reverse(pieces.begin(), pieces.end());
            for (TopoDS_Edge& piece : pieces) {
                piece.Reverse();
            }
        }
        for (const TopoDS_Edge& piece : pieces) {
            maker.Add(piece);
        }
    }
    return maker.IsDone() ? maker.Wire() : TopoDS_Wire();
}

/// How far an edge turns (radians) along it.
double edge_turn(const TopoDS_Edge& edge)
{
    const BRepAdaptor_Curve curve(edge);
    double total = 0.0;
    gp_Vec was;
    for (int i = 0; i <= 32; ++i) {
        gp_Pnt p;
        gp_Vec now;
        curve.D1(curve.FirstParameter() + (curve.LastParameter() - curve.FirstParameter()) * i / 32, p, now);
        if (i > 0 && was.Magnitude() > 1e-300 && now.Magnitude() > 1e-300) {
            total += was.Angle(now);
        }
        was = now;
    }
    return total;
}

/// Points along each edge of a wire (in the order and the way it runs): counts[e] + 1 of them at
/// even parameters, the ends exactly at its vertices.
std::vector<std::vector<gp_Pnt>> wire_samples(const TopoDS_Wire& wire, const std::vector<int>& counts)
{
    std::vector<std::vector<gp_Pnt>> out;
    size_t e = 0;
    for (BRepTools_WireExplorer it(wire); it.More() && e < counts.size(); it.Next(), ++e) {
        const TopoDS_Edge& edge = it.Current();
        const BRepAdaptor_Curve curve(edge);
        const bool backward = edge.Orientation() == TopAbs_REVERSED;
        TopoDS_Vertex first;
        TopoDS_Vertex last;
        TopExp::Vertices(edge, first, last, true);
        std::vector<gp_Pnt> points;
        const int n = counts[e];
        for (int k = 0; k <= n; ++k) {
            const double s = double(k) / n;
            points.push_back(k == 0 ? BRep_Tool::Pnt(first) : k == n ? BRep_Tool::Pnt(last)
                : curve.Value(backward ? curve.LastParameter() - s * (curve.LastParameter() - curve.FirstParameter())
                                       : curve.FirstParameter() + s * (curve.LastParameter() - curve.FirstParameter())));
        }
        out.push_back(points);
    }
    return out;
}

/// A wire through points given edge by edge (as wire_samples gives them): a straight edge where they
/// lie on a line, else a spline through them at even parameters; each edge starts where the one
/// before ends (closed: the last ends where the first starts). Null when one can't be made.
TopoDS_Wire wire_through(const std::vector<std::vector<gp_Pnt>>& columns, bool closed, double size)
{
    std::vector<TopoDS_Vertex> corners;
    for (const std::vector<gp_Pnt>& points : columns) {
        corners.push_back(BRepBuilderAPI_MakeVertex(points.front()).Vertex());
    }
    corners.push_back(closed ? corners.front() : BRepBuilderAPI_MakeVertex(columns.back().back()).Vertex());
    BRepBuilderAPI_MakeWire maker;
    for (size_t e = 0; e < columns.size(); ++e) {
        const std::vector<gp_Pnt>& points = columns[e];
        const gp_Vec chord(points.front(), points.back());
        bool straight = chord.Magnitude() > 1e-12 * size;
        for (const gp_Pnt& p : points) {
            straight = straight && gp_Vec(points.front(), p).Crossed(chord).Magnitude() <= 1e-12 * size * chord.Magnitude();
        }
        TopoDS_Edge edge;
        if (straight) {
            edge = BRepBuilderAPI_MakeEdge(corners[e], corners[e + 1]).Edge();
        }
        else {
            // A loop of one edge closes smoothly on itself (periodic), its start given once.
            const bool periodic = closed && columns.size() == 1;
            const int count = int(points.size()) - (periodic ? 1 : 0);
            Handle(TColgp_HArray1OfPnt) through = new TColgp_HArray1OfPnt(1, count);
            Handle(TColStd_HArray1OfReal) params = new TColStd_HArray1OfReal(1, count + (periodic ? 1 : 0));
            for (int k = 0; k < count; ++k) {
                through->SetValue(k + 1, points[k]);
            }
            for (int k = 0; k < params->Length(); ++k) {
                params->SetValue(k + 1, double(k) / (points.size() - 1));
            }
            GeomAPI_Interpolate fit(through, params, periodic, 1e-12 * size);
            fit.Perform();
            if (!fit.IsDone()) {
                return TopoDS_Wire();
            }
            BRepBuilderAPI_MakeEdge made(fit.Curve(), corners[e], corners[e + 1], 0.0, 1.0);
            if (!made.IsDone()) {
                return TopoDS_Wire();
            }
            edge = made.Edge();
        }
        maker.Add(edge);
        if (!maker.IsDone()) {
            return TopoDS_Wire();
        }
    }
    return maker.Wire();
}

/// The weights at x of the values at knots (increasing) in the natural cubic spline through them
/// (linear between two).
std::vector<double> spline_weights(const std::vector<double>& knots, double x)
{
    const size_t n = knots.size();
    std::vector<double> weights(n, 0.0);
    size_t i = 0;
    while (i + 2 < n && x > knots[i + 1]) {
        ++i;
    }
    const double h = knots[i + 1] - knots[i];
    const double a = (knots[i + 1] - x) / h;
    const double b = (x - knots[i]) / h;
    weights[i] += a;
    weights[i + 1] += b;
    if (n < 3) {
        return weights;
    }
    // Second derivatives for each unit value (the spline is linear in its values): natural ends,
    // the rest from the tridiagonal system, solved by elimination.
    for (size_t j = 0; j < n; ++j) {
        std::vector<double> rhs(n, 0.0);
        auto value = [&](size_t k) { return k == j ? 1.0 : 0.0; };
        for (size_t k = 1; k + 1 < n; ++k) {
            rhs[k] = 6.0 * ((value(k + 1) - value(k)) / (knots[k + 1] - knots[k]) - (value(k) - value(k - 1)) / (knots[k] - knots[k - 1]));
        }
        std::vector<double> diag(n, 1.0);
        std::vector<double> upper(n, 0.0);
        std::vector<double> m(n, 0.0);
        for (size_t k = 1; k + 1 < n; ++k) {
            const double lower = knots[k] - knots[k - 1];
            diag[k] = 2.0 * (knots[k + 1] - knots[k - 1]) - (k > 1 ? lower * upper[k - 1] : 0.0);
            upper[k] = (knots[k + 1] - knots[k]) / diag[k];
            rhs[k] = (rhs[k] - (k > 1 ? lower * rhs[k - 1] : 0.0)) / diag[k];
        }
        for (size_t k = n - 2; k >= 1; --k) {
            m[k] = rhs[k] - upper[k] * m[k + 1];
            if (k == 1) {
                break;
            }
        }
        weights[j] += (a * a * a - a) * h * h / 6.0 * m[i] + (b * b * b - b) * h * h / 6.0 * m[i + 1];
    }
    return weights;
}

/// A loft along one rail (see loft()): through each section where it is drawn, the rail shaping the
/// walls between them. Each section is taken as its offset from where the rail touches it; between
/// sections that offset blends (a natural cubic spline along the rail's length, linear between two)
/// and is carried along the rail, so the touching point follows the rail exactly. Where the rail
/// runs straight from section to section the walls are ruled (two circles on a rail straight
/// between them make their frustum); where it curves, sections are made along it (one every 5 deg
/// it turns, at least 4) and swept along the rail as far as it runs on smoothly, held as they are
/// (it is split at its corners and joined there). (A pipe along the rail turned the sections with
/// the rail and kinked them at its corners: r 5, 4 and 5 mm circles on a rail bent at the middle
/// one came out 7.2 % short of their two frustums.) loops: a chain's loop (or point) per section;
/// keep: it starts where the rail touches it (else it is started as the one before, as an unrailed
/// loft matches them); on: where the rail touches each section; rail: from the first section's
/// touch to the last's. Null with error when it can't be made; note says how near the rail it
/// passes when that is off more than its fit.
TopoDS_Shape lofted_along(const std::vector<TopoDS_Shape>& loops, const std::vector<bool>& keep, const std::vector<gp_Pnt>& on, const TopoDS_Wire& rail, bool solid,
    TopoDS_Shape& first_cap, TopoDS_Shape& last_cap, String& error, String& note)
{
    const size_t n = loops.size();
    const bool touching = std::any_of(keep.begin(), keep.end(), [](bool k) { return k; });
    std::vector<TopoDS_Shape> all = loops;
    all.push_back(rail);
    const double size = diagonal(make_compound(all));
    for (size_t s = 1; s + 1 < n; ++s) {
        if (loops[s].ShapeType() == TopAbs_VERTEX) {
            error = "Only the first or last loft profile can be a point";
            return TopoDS_Shape();
        }
    }
    TopoDS_Wire spine = rail;
    if (RailCurve(spine).locate(on.front()) > RailCurve(spine).locate(on.back())) {
        spine = TopoDS::Wire(spine.Reversed());
    }
    const RailCurve curve(spine);
    if (curve.curves.empty()) {
        error = "The loft's rail has no length";
        return TopoDS_Shape();
    }
    const double length = curve.length();
    std::vector<double> at;
    for (const gp_Pnt& point : on) {
        at.push_back(curve.locate(point));
    }
    for (size_t s = 1; s < n; ++s) {
        if (!(at[s] > at[s - 1] + 1e-9 * length)) {
            error = "The loft's profiles must touch the rail one after another, in the order they are listed";
            return TopoDS_Shape();
        }
    }
    // Every loop runs the way the one before does; one the rail doesn't start starts as the one
    // before does (carried into its plane, as an unrailed loft matches them).
    std::vector<TopoDS_Shape> ready = loops;
    bool open = false;
    bool closed = false;
    for (const TopoDS_Shape& loop : loops) {
        if (loop.ShapeType() == TopAbs_WIRE) {
            (BRep_Tool::IsClosed(loop) ? closed : open) = true;
        }
    }
    if (open && closed) {
        error = "A loft's profiles must be all closed or all open";
        return TopoDS_Shape();
    }
    int before = -1;
    for (size_t s = 0; s < n; ++s) {
        if (ready[s].ShapeType() != TopAbs_WIRE) {
            continue;
        }
        TopoDS_Wire loop = TopoDS::Wire(ready[s]);
        if (before >= 0) {
            const TopoDS_Wire previous = TopoDS::Wire(ready[before]);
            gp_Pnt middle;
            gp_Vec normal;
            gp_Pnt before_middle;
            gp_Vec before_normal;
            const bool flat = loop_plane(loop, middle, normal) && loop_plane(previous, before_middle, before_normal);
            const gp_Trsf carry = flat ? carrying(before_middle, before_normal, middle, normal) : gp_Trsf();
            if (closed && flat) {
                if (!keep[s]) {
                    loop = edge_count(loop) == 1 ? round_started(loop, middle, normal, BRep_Tool::Pnt(BRepTools_WireExplorer(previous).CurrentVertex()).Transformed(carry))
                                                 : corner_aligned(loop, previous, carry);
                }
                if (loop_turn(loop, middle).Dot(loop_turn(previous, before_middle).Transformed(carry)) < 0.0) {
                    loop = reversed_loop(loop);
                }
            }
            else if (open) {
                TopoDS_Vertex a;
                TopoDS_Vertex b;
                TopoDS_Vertex c;
                TopoDS_Vertex d;
                TopExp::Vertices(loop, a, b);
                TopExp::Vertices(previous, c, d);
                if (gp_Vec(BRep_Tool::Pnt(a), BRep_Tool::Pnt(b)).Dot(gp_Vec(BRep_Tool::Pnt(c), BRep_Tool::Pnt(d)).Transformed(carry)) < 0.0) {
                    loop = reversed_loop(loop);
                }
            }
        }
        ready[s] = loop;
        before = int(s);
    }
    // Loops of as many edges pair up edge for edge; others are split where the others have corners,
    // by their share of the way along (as OCCT's loft splits loops of different counts).
    std::vector<int> counts;
    for (const TopoDS_Shape& loop : ready) {
        if (loop.ShapeType() == TopAbs_WIRE) {
            counts.push_back(edge_count(loop));
        }
    }
    if (std::any_of(counts.begin(), counts.end(), [&](int c) { return c != counts.front(); })) {
        std::vector<double> shares;
        for (const TopoDS_Shape& loop : ready) {
            if (loop.ShapeType() == TopAbs_WIRE) {
                const std::vector<double> own = vertex_shares(TopoDS::Wire(loop));
                shares.insert(shares.end(), own.begin(), own.end());
            }
        }
        std::sort(shares.begin(), shares.end());
        std::vector<double> distinct;
        for (const double share : shares) {
            if (distinct.empty() || share > distinct.back() + 1e-9) {
                distinct.push_back(share);
            }
        }
        for (TopoDS_Shape& loop : ready) {
            if (loop.ShapeType() == TopAbs_WIRE) {
                loop = split_at_shares(TopoDS::Wire(loop), distinct);
                if (loop.IsNull() || edge_count(loop) != int(distinct.size())) {
                    error = "The loft's profiles could not be matched up along the rail";
                    return TopoDS_Shape();
                }
            }
        }
    }
    // Each section's offset from where the rail touches it, sampled edge by edge (more where an
    // edge turns: a full circle 68 times, its spline through them within 4e-8 of its radius).
    size_t edges = 0;
    for (const TopoDS_Shape& loop : ready) {
        edges = loop.ShapeType() == TopAbs_WIRE ? size_t(edge_count(loop)) : edges;
    }
    std::vector<int> samples(edges, 2);
    for (const TopoDS_Shape& loop : ready) {
        if (loop.ShapeType() != TopAbs_WIRE) {
            continue;
        }
        size_t e = 0;
        for (BRepTools_WireExplorer it(TopoDS::Wire(loop)); it.More() && e < edges; it.Next(), ++e) {
            const double turned = edge_turn(it.Current()) * 180.0 / M_PI;
            samples[e] = std::max(samples[e], turned < 1e-9 ? 2 : std::clamp(8 + int(std::ceil(turned / 6.0)), 8, 128));
        }
    }
    std::vector<std::vector<std::vector<gp_Vec>>> offsets(n);
    for (size_t s = 0; s < n; ++s) {
        const std::vector<std::vector<gp_Pnt>> points = ready[s].ShapeType() == TopAbs_WIRE ? wire_samples(TopoDS::Wire(ready[s]), samples) : std::vector<std::vector<gp_Pnt>>();
        offsets[s].resize(edges);
        for (size_t e = 0; e < edges; ++e) {
            for (int k = 0; k <= samples[e]; ++k) {
                offsets[s][e].push_back(points.empty() ? gp_Vec(0.0, 0.0, 0.0) : gp_Vec(on[s], points[e][k]));
            }
        }
    }
    // Pieces of the rail between sections and its own corners: straight, or curved (with how far
    // it turns).
    std::vector<double> breaks = at;
    for (const double corner : curve.corners()) {
        if (corner > at.front() + 1e-9 * length && corner < at.back() - 1e-9 * length
            && std::none_of(at.begin(), at.end(), [&](double a) { return std::abs(a - corner) <= 1e-9 * length; })) {
            breaks.push_back(corner);
        }
    }
    std::sort(breaks.begin(), breaks.end());
    // Runs of pieces lofted as one: straight pieces in a row (ruled, corners and all), or curved
    // ones that carry on smoothly one into the next; each a list of where along the rail its
    // sections lie (drawn: the section's index, or -1 for one made along the rail).
    struct Station
    {
        double run;
        int drawn;
    };
    struct Run
    {
        bool straight;
        std::vector<Station> stations;
    };
    auto drawn_at = [&](double run) {
        for (size_t s = 0; s < n; ++s) {
            if (std::abs(at[s] - run) <= 1e-9 * length) {
                return int(s);
            }
        }
        return -1;
    };
    std::vector<Run> runs;
    for (size_t b = 0; b + 1 < breaks.size(); ++b) {
        const double from = breaks[b];
        const double to = breaks[b + 1];
        const gp_Pnt a = curve.point(from);
        const gp_Pnt z = curve.point(to);
        const gp_Vec chord(a, z);
        bool straight = chord.Magnitude() > 0.0;
        for (int i = 1; i < 16 && straight; ++i) {
            straight = gp_Vec(a, curve.point(from + (to - from) * i / 16)).Crossed(chord).Magnitude() <= 1e-9 * size * chord.Magnitude();
        }
        gp_Vec into;
        gp_Vec out_of;
        curve.point(from, &into, -1);
        curve.point(from, &out_of, 1);
        const bool smooth = b > 0 && into.Magnitude() > 0.0 && out_of.Magnitude() > 0.0 && into.Angle(out_of) <= 1e-6;
        if (runs.empty() || runs.back().straight != straight || (!straight && !smooth)) {
            runs.push_back({straight, {{from, drawn_at(from)}}});
        }
        if (!straight) {
            const int steps = std::clamp(int(std::ceil(curve.turn(from, to) / (5.0 * M_PI / 180.0))), 4, 64);
            for (int i = 1; i < steps; ++i) {
                runs.back().stations.push_back({from + (to - from) * i / steps, -1});
            }
        }
        runs.back().stations.push_back({to, drawn_at(to)});
    }
    // Each run's sections: drawn ones as they are (matched up above), the rest made from the
    // blended offsets carried to the rail. A straight run is a ruled loft through them; a curved
    // one is swept along the rail itself, the sections held as they are (a fixed frame, not
    // turned with the rail) and blended from one to the next, so its touching point runs along
    // the rail exactly (a loft through sections made along an S rail strayed up to 0.014 mm from
    // it between them, 50 mm long).
    struct Made
    {
        TopoDS_Shape shape;
        TopoDS_Shape first;
        TopoDS_Shape last;
    };
    std::vector<Made> lofts;
    double off_rail = 0.0;
    // Sections all alike (each the first carried along the rail): a curved run is the one section
    // swept along the rail held as it is, not made again every 5 deg the rail turns (two 10 mm
    // circles on an arc rail took 0.3 s that way, three on an S rail 0.8 s and up to 7 s).
    bool alike = std::all_of(ready.begin(), ready.end(), [](const TopoDS_Shape& loop) { return loop.ShapeType() == TopAbs_WIRE; });
    for (size_t s = 1; s < n && alike; ++s) {
        for (size_t e = 0; e < edges && alike; ++e) {
            for (size_t k = 0; k < offsets[s][e].size() && alike; ++k) {
                alike = (offsets[s][e][k] - offsets[0][e][k]).Magnitude() <= FIT * size;
            }
        }
    }
    for (const Run& run : runs) {
        std::vector<TopoDS_Shape> shapes;
        for (const Station& station : run.stations) {
            if (alike && !run.straight && !shapes.empty()) {
                break;
            }
            if (station.drawn >= 0) {
                shapes.push_back(ready[station.drawn]);
                continue;
            }
            const gp_Pnt touch = curve.point(station.run);
            const std::vector<double> weights = spline_weights(at, station.run);
            std::vector<std::vector<gp_Pnt>> columns(edges);
            for (size_t e = 0; e < edges; ++e) {
                for (int k = 0; k <= samples[e]; ++k) {
                    gp_Vec offset(0.0, 0.0, 0.0);
                    for (size_t s = 0; s < n; ++s) {
                        offset += offsets[s][e][k] * weights[s];
                    }
                    columns[e].push_back(touch.Translated(offset));
                }
            }
            // (A loop's ends made one point exactly.)
            if (closed) {
                columns.back().back() = columns.front().front();
            }
            const TopoDS_Wire made = wire_through(columns, closed, size);
            if (made.IsNull()) {
                error = "The loft's sections along the rail could not be made";
                return TopoDS_Shape();
            }
            shapes.push_back(made);
        }
        if (run.straight) {
            const std::unique_ptr<Loft> loft = fitted_loft(solid, true, shapes, false, false, "loft", note);
            if (!loft) {
                error = "The loft along the rail could not be built";
                return TopoDS_Shape();
            }
            lofts.push_back({loft->shape(), solid ? loft->first() : TopoDS_Shape(), solid ? loft->last() : TopoDS_Shape()});
            continue;
        }
        // The rail's stretch for the run, and where on it each section sits; made at LOFT_SIZE and
        // scaled back (as fitted_loft is).
        const TopoDS_Wire stretch = rail_between(spine, curve.point(run.stations.front().run), curve.point(run.stations.back().run));
        std::vector<TopoDS_Shape> all = shapes;
        all.push_back(stretch);
        std::vector<TopoDS_Shape> seats;
        for (size_t k = 0; k < shapes.size(); ++k) {
            seats.push_back(shapes[k].ShapeType() == TopAbs_VERTEX ? shapes[k] : TopoDS_Shape(BRepBuilderAPI_MakeVertex(curve.point(run.stations[k].run)).Vertex()));
            all.push_back(seats.back());
        }
        Bnd_Box box;
        BRepBndLib::Add(make_compound(all), box);
        const gp_Pnt middle = box.IsVoid() ? gp::Origin() : gp_Pnt((box.CornerMin().XYZ() + box.CornerMax().XYZ()) * 0.5);
        const double factor = LOFT_SIZE / std::max(size, 1e-12);
        gp_Trsf up;
        up.SetScale(middle, factor);
        BRepBuilderAPI_Transform grow(make_compound(all), up, true);
        auto big = [&](const TopoDS_Shape& part) {
            const TopoDS_Shape copy = grow.ModifiedShape(part);
            return copy.Oriented(TopAbs::Compose(copy.Orientation(), part.Orientation()));
        };
        const auto pipe = fitted_pipe(TopoDS::Wire(big(stretch)), size * factor, solid, 1e-3, [&](BRepOffsetAPI_MakePipeShell& maker) {
            maker.SetMode(gp_Ax2(gp::Origin(), gp::DZ(), gp::DX()));
            for (size_t k = 0; k < shapes.size(); ++k) {
                maker.Add(big(shapes[k]), TopoDS::Vertex(big(seats[k])), false, false);
            }
        }, "loft", note, factor);
        if (!pipe) {
            error = "The loft along the rail could not be built";
            return TopoDS_Shape();
        }
        // How near the rail its walls pass between the sections (of the loops it touches: a hole
        // riding along keeps its distance).
        std::vector<TopoDS_Shape> walls;
        for (TopExp_Explorer it(pipe->Shape(), TopAbs_FACE); it.More(); it.Next()) {
            walls.push_back(it.Current());
        }
        const TopoDS_Shape skin = make_compound(walls);
        // (Six looks at most, each a search over the walls' surfaces: one every gap took 0.4 s.)
        const size_t gaps = touching ? run.stations.size() - 1 : 0;
        const size_t stride = std::max<size_t>(1, (gaps + 5) / 6);
        for (size_t g = 0; g < gaps; g += stride) {
            const gp_Pnt mid = curve.point(0.5 * (run.stations[g].run + run.stations[g + 1].run)).Transformed(up);
            BRepExtrema_DistShapeShape distance(BRepBuilderAPI_MakeVertex(mid).Vertex(), skin);
            if (distance.IsDone() && distance.NbSolution() > 0) {
                off_rail = std::max(off_rail, distance.Value() / factor);
            }
        }
        gp_Trsf down;
        down.SetScale(middle, 1.0 / factor);
        BRepBuilderAPI_Transform shrink(pipe->Shape(), down, true);
        // (A loft to a point has no end face.)
        auto small = [&](const TopoDS_Shape& part) {
            try {
                return part.IsNull() || !solid ? TopoDS_Shape() : shrink.ModifiedShape(part);
            }
            catch (const Standard_Failure&) {
                return TopoDS_Shape();
            }
        };
        lofts.push_back({shrink.Shape(), small(pipe->FirstShape()), small(pipe->LastShape())});
    }
    if (off_rail > 10.0 * FIT * size) {
        char text[200];
        std::snprintf(text, sizeof(text), "The loft follows its rail to within %.3g mm (a closer fit could not be built)", off_rail * 1000.0);
        note = note.is_empty() ? String(text) : note + "; " + String(text);
    }
    if (lofts.size() == 1) {
        first_cap = lofts[0].first;
        last_cap = lofts[0].last;
        return lofts[0].shape;
    }
    // Runs joined where they meet (their shared sections' caps left out).
    TopTools_MapOfShape inside;
    for (size_t r = 0; r < lofts.size() && solid; ++r) {
        if (r > 0 && !lofts[r].first.IsNull()) {
            inside.Add(lofts[r].first);
        }
        if (r + 1 < lofts.size() && !lofts[r].last.IsNull()) {
            inside.Add(lofts[r].last);
        }
    }
    BRepBuilderAPI_Sewing sewing(1e-7 * size);
    for (const Made& loft : lofts) {
        for (TopExp_Explorer it(loft.shape, TopAbs_FACE); it.More(); it.Next()) {
            if (!inside.Contains(it.Current())) {
                sewing.Add(it.Current());
            }
        }
    }
    sewing.Perform();
    const TopoDS_Shape sewn = sewing.SewedShape();
    const TopTools_IndexedMapOfShape shells = map_of(sewn, TopAbs_SHELL);
    if (!solid) {
        return sewn;
    }
    if (shells.Extent() != 1 || !closed_shell(shells(1))) {
        error = "The loft along the rail could not be joined up where the rail turns";
        return TopoDS_Shape();
    }
    BRepBuilderAPI_MakeSolid maker(TopoDS::Shell(shells(1)));
    if (!maker.IsDone()) {
        error = "The loft along the rail could not be joined up where the rail turns";
        return TopoDS_Shape();
    }
    TopoDS_Solid joined = maker.Solid();
    BRepLib::OrientClosedSolid(joined);
    first_cap = lofts.front().first.IsNull() ? TopoDS_Shape() : sewing.Modified(lofts.front().first);
    last_cap = lofts.back().last.IsNull() ? TopoDS_Shape() : sewing.Modified(lofts.back().last);
    return joined;
}
}  // namespace

Shape loft(const Array& sections, const Dictionary& p, String& error, String& note)
{
    const std::string tag = tag_of(p, "loft");
    if (sections.size() < 2) {
        error = "Loft needs at least two profiles";
        return Shape();
    }
    const bool closed = p.get("closed", false);
    const bool ruled = p.get("ruled", false);
    const bool surface = p.get("surface", false);
    Ref<CadShape> centerline = p.get("centerline", Variant());
    Ref<CadShape> rail = p.get("rail", Variant());
    try {
        // Each section's pieces: a face's outer loop with its holes, a wire, or a point.
        struct Piece
        {
            TopoDS_Shape outer;
            std::vector<TopoDS_Shape> holes;
        };
        std::vector<std::vector<Piece>> layers;
        for (int64_t i = 0; i < sections.size(); ++i) {
            Ref<CadShape> s = sections[i];
            if (!usable(s)) {
                error = "A loft profile is missing";
                return Shape();
            }
            const TopoDS_Shape& occ = s->get_occ_shape();
            std::vector<Piece> layer;
            if (occ.ShapeType() == TopAbs_VERTEX || occ.ShapeType() == TopAbs_WIRE) {
                layer.push_back({occ, {}});
            }
            else {
                const std::vector<TopoDS_Face> faces = faces_of(occ);
                if (faces.empty()) {
                    const TopoDS_Wire wire = connect(occ, error);
                    if (wire.IsNull()) {
                        return Shape();
                    }
                    layer.push_back({wire, {}});
                }
                for (const TopoDS_Face& face : faces) {
                    Piece piece{BRepTools::OuterWire(face), {}};
                    for (TopExp_Explorer w(face, TopAbs_WIRE); w.More(); w.Next()) {
                        if (!w.Current().IsSame(piece.outer)) {
                            piece.holes.push_back(w.Current());
                        }
                    }
                    layer.push_back(piece);
                }
            }
            layers.push_back(layer);
        }
        // Every section needs as many pieces, each with as many holes. Pieces pair up with the
        // nearest one in the next section (measured from each section's middle, so a section moved
        // sideways pairs the same), holes with the nearest in the paired piece (from its middle).
        auto center = [](const TopoDS_Shape& s) {
            if (s.ShapeType() == TopAbs_VERTEX) {
                return BRep_Tool::Pnt(TopoDS::Vertex(s)).XYZ();
            }
            GProp_GProps props;
            BRepGProp::LinearProperties(s, props);
            return props.CentreOfMass().XYZ();
        };
        // match[k]: the index in b nearest a[k], closest pairs first.
        auto pair_up = [](const std::vector<gp_XYZ>& a, const std::vector<gp_XYZ>& b) {
            std::vector<std::tuple<double, size_t, size_t>> pairs;
            for (size_t i = 0; i < a.size(); ++i) {
                for (size_t j = 0; j < b.size(); ++j) {
                    pairs.push_back({(a[i] - b[j]).Modulus(), i, j});
                }
            }
            std::sort(pairs.begin(), pairs.end());
            std::vector<int> match(a.size(), -1);
            std::vector<bool> taken(b.size(), false);
            for (const auto& [d, i, j] : pairs) {
                if (match[i] < 0 && !taken[j]) {
                    match[i] = int(j);
                    taken[j] = true;
                }
            }
            return match;
        };
        auto from_middle = [&](const std::vector<TopoDS_Shape>& shapes, const gp_XYZ& middle) {
            std::vector<gp_XYZ> points;
            for (const TopoDS_Shape& s : shapes) {
                points.push_back(center(s) - middle);
            }
            return points;
        };
        const size_t count = layers.front().size();
        if (count == 0) {
            error = "A loft profile is missing";
            return Shape();
        }
        for (const std::vector<Piece>& layer : layers) {
            if (layer.size() != count) {
                error = String("Every loft profile needs as many separate pieces (") + String::num_int64(int64_t(count)) + " and " + String::num_int64(int64_t(layer.size())) + " here)";
                return Shape();
            }
        }
        // chains[c][s]: piece c's part in section s.
        std::vector<std::vector<const Piece*>> chains(count);
        for (size_t c = 0; c < count; ++c) {
            chains[c].push_back(&layers[0][c]);
        }
        for (size_t s = 1; s < layers.size(); ++s) {
            std::vector<TopoDS_Shape> before;
            std::vector<TopoDS_Shape> now;
            for (size_t c = 0; c < count; ++c) {
                before.push_back(chains[c].back()->outer);
                now.push_back(layers[s][c].outer);
            }
            auto middle = [&](const std::vector<TopoDS_Shape>& shapes) {
                gp_XYZ sum(0.0, 0.0, 0.0);
                for (const TopoDS_Shape& shape : shapes) {
                    sum += center(shape);
                }
                return sum / double(shapes.size());
            };
            const std::vector<int> match = pair_up(from_middle(before, middle(before)), from_middle(now, middle(now)));
            for (size_t c = 0; c < count; ++c) {
                chains[c].push_back(&layers[s][match[c]]);
            }
        }
        // holes[c][h][s]: hole h of piece c in section s.
        std::vector<std::vector<std::vector<TopoDS_Shape>>> holes(count);
        for (size_t c = 0; c < count; ++c) {
            const size_t hole_count = chains[c].front()->holes.size();
            for (const Piece* piece : chains[c]) {
                if (piece->holes.size() != hole_count) {
                    error = String("Every loft profile needs the same holes (") + String::num_int64(int64_t(hole_count)) + " and " + String::num_int64(int64_t(piece->holes.size())) + " here)";
                    return Shape();
                }
            }
            holes[c].resize(hole_count);
            for (size_t h = 0; h < hole_count; ++h) {
                holes[c][h].push_back(chains[c].front()->holes[h]);
            }
            for (size_t s = 1; s < chains[c].size() && hole_count > 0; ++s) {
                std::vector<TopoDS_Shape> before;
                for (size_t h = 0; h < hole_count; ++h) {
                    before.push_back(holes[c][h].back());
                }
                const std::vector<int> match = pair_up(from_middle(before, center(chains[c][s - 1]->outer)), from_middle(chains[c][s]->holes, center(chains[c][s]->outer)));
                for (size_t h = 0; h < hole_count; ++h) {
                    holes[c][h].push_back(chains[c][s]->holes[match[h]]);
                }
            }
        }
        // Along one rail exactly: in each section the loop the rail touches is re-made to start
        // there (so that point follows the rail), and every loop of the section rides along with
        // it, kept where it is drawn (lofted_along).
        TopoDS_Wire spine;
        std::vector<TopoDS_Vertex> placed(layers.size());
        std::vector<TopoDS_Shape> touched(layers.size());
        std::vector<TopoDS_Wire> started(layers.size());
        if (rail.is_valid() && !rail->is_null()) {
            spine = connect(rail->get_occ_shape(), error);
            if (spine.IsNull()) {
                return Shape();
            }
            for (size_t s = 0; s < layers.size(); ++s) {
                std::vector<TopoDS_Shape> loops;
                for (const Piece& piece : layers[s]) {
                    loops.push_back(piece.outer);
                    loops.insert(loops.end(), piece.holes.begin(), piece.holes.end());
                }
                for (const TopoDS_Shape& loop : loops) {
                    if (loop.ShapeType() == TopAbs_WIRE && started[s].IsNull()) {
                        started[s] = started_at(TopoDS::Wire(loop), spine, placed[s]);
                        touched[s] = loop;
                    }
                }
                // A point section (first or last) lies on the rail and is placed where it is.
                const bool point = loops.front().ShapeType() == TopAbs_VERTEX;
                if (point) {
                    BRepExtrema_DistShapeShape contact(loops.front(), spine);
                    if (contact.IsDone() && contact.Value() <= std::max(diagonal(spine) * 1e-7, Precision::Confusion())) {
                        placed[s] = TopoDS::Vertex(loops.front());
                    }
                }
                if (point ? placed[s].IsNull() : started[s].IsNull()) {
                    error = "Every loft profile must touch the rail";
                    return Shape();
                }
            }
            // The loft runs along the rail from the first section to the last, not past them.
            spine = rail_between(spine, BRep_Tool::Pnt(placed.front()), BRep_Tool::Pnt(placed.back()));
        }
        // One loft through a chain of loops (or points), section by section; caps gets its start
        // and end, sides its walls named by the edges they follow (see below).
        auto loft_through = [&](const std::vector<TopoDS_Shape>& parts, bool solid, std::vector<naming::Role>* caps, std::vector<naming::Role>* sides) -> TopoDS_Shape {
            const double size = diagonal(make_compound(parts));
            if (!spine.IsNull()) {
                // Through the sections where they are drawn, the rail shaping the walls between
                // them (lofted_along).
                std::vector<TopoDS_Shape> chain;
                std::vector<bool> keep;
                std::vector<gp_Pnt> on;
                for (size_t s = 0; s < parts.size(); ++s) {
                    const bool own = parts[s].IsSame(touched[s]) && !started[s].IsNull();
                    chain.push_back(own ? started[s] : parts[s]);
                    keep.push_back(own);
                    on.push_back(BRep_Tool::Pnt(placed[s]));
                }
                TopoDS_Shape first_cap;
                TopoDS_Shape last_cap;
                const TopoDS_Shape made = lofted_along(chain, keep, on, spine, solid, first_cap, last_cap, error, note);
                if (!made.IsNull() && caps != nullptr && solid) {
                    *caps = {{first_cap, tag + ":start"}, {last_cap, tag + ":end"}};
                }
                return made;
            }
            if (centerline.is_valid() && !centerline->is_null()) {
                const TopoDS_Wire path = connect(centerline->get_occ_shape(), error);
                if (path.IsNull()) {
                    return TopoDS_Shape();
                }
                const auto pipe = fitted_pipe(path, size, solid, 1e-2, [&](BRepOffsetAPI_MakePipeShell& maker) {
                    maker.SetMode(false);
                    for (const TopoDS_Shape& part : parts) {
                        if (part.ShapeType() == TopAbs_WIRE) {
                            maker.Add(part, false, true);
                        }
                    }
                }, "loft", note);
                if (!pipe) {
                    error = "The loft along the centerline could not be built";
                    return TopoDS_Shape();
                }
                return pipe->Shape();
            }
            // Loops of as many edges pair up edge for edge from where they start. Others (a square
            // to a circle) OCCT splits to match, at the rays from each loop's middle through the
            // other loops' corners, so a circle's start split a square's side in two wherever it
            // was drawn: a loop of one round edge starts on the ray through the first corner of
            // the loop with the most edges instead, and the walls follow that loop's edges and are
            // named by them (so their names don't hang on where a circle starts).
            std::vector<int> counts;
            int most = -1;
            for (const TopoDS_Shape& part : parts) {
                counts.push_back(part.ShapeType() == TopAbs_WIRE ? edge_count(part) : -1);
                if (counts.back() >= 0 && (most < 0 || counts.back() > counts[most])) {
                    most = int(counts.size()) - 1;
                }
            }
            bool matched = true;
            for (const int n : counts) {
                matched = matched && (n < 0 || most < 0 || n == counts[most]);
            }
            std::vector<TopoDS_Shape> loops = parts;
            gp_Pnt middle;
            gp_Vec normal;
            if (!matched && loop_plane(TopoDS::Wire(parts[most]), middle, normal)) {
                const BRepTools_WireExplorer first(TopoDS::Wire(parts[most]));
                const gp_Pnt corner = BRep_Tool::Pnt(first.CurrentVertex());
                for (size_t s = 0; s < parts.size(); ++s) {
                    gp_Pnt own_middle;
                    gp_Vec own_normal;
                    if (int(s) != most && counts[s] == 1 && loop_plane(TopoDS::Wire(parts[s]), own_middle, own_normal)) {
                        loops[s] = round_started(TopoDS::Wire(parts[s]), own_middle, own_normal, carried_into(corner, middle, normal, own_middle, own_normal));
                    }
                }
            }
            else if (matched && most >= 0 && counts[most] == 1) {
                // Loops of one edge pair up from where they start, so two circles drawn from
                // different points twisted the loft: each round loop starts on the ray through the
                // start of the loop before it, carried into its plane as above, and runs the same
                // way round.
                int before = -1;
                gp_Pnt before_middle;
                gp_Vec before_normal;
                for (size_t s = 0; s < loops.size(); ++s) {
                    gp_Pnt own_middle;
                    gp_Vec own_normal;
                    if (counts[s] != 1 || !loop_plane(TopoDS::Wire(loops[s]), own_middle, own_normal)) {
                        continue;
                    }
                    if (before >= 0) {
                        const TopoDS_Wire previous = TopoDS::Wire(loops[before]);
                        const gp_Trsf carry = carrying(before_middle, before_normal, own_middle, own_normal);
                        const BRepTools_WireExplorer first(previous);
                        const gp_Pnt start = BRep_Tool::Pnt(first.CurrentVertex());
                        TopoDS_Wire started = round_started(TopoDS::Wire(loops[s]), own_middle, own_normal, start.Transformed(carry));
                        if (loop_turn(started, own_middle).Dot(loop_turn(previous, before_middle).Transformed(carry)) < 0.0) {
                            started = TopoDS::Wire(started.Reversed());
                        }
                        loops[s] = started;
                    }
                    before = int(s);
                    before_middle = own_middle;
                    before_normal = own_normal;
                }
            }
            else if (matched && most >= 0) {
                // Loops of as many edges pair up corner for corner from where they start, the way
                // they run: two rectangles drawn from different corners twisted the loft, and a
                // face's loop facing the other way (a box's bottom) flattened it. Each starts at the
                // corner, and runs the way round, that lies nearest the loop before's corners,
                // carried into its plane as above.
                int before = -1;
                gp_Pnt before_middle;
                gp_Vec before_normal;
                for (size_t s = 0; s < loops.size(); ++s) {
                    gp_Pnt own_middle;
                    gp_Vec own_normal;
                    if (counts[s] < 2 || !loop_plane(TopoDS::Wire(loops[s]), own_middle, own_normal)) {
                        continue;
                    }
                    if (before >= 0) {
                        loops[s] = corner_aligned(TopoDS::Wire(loops[s]), TopoDS::Wire(loops[before]), carrying(before_middle, before_normal, own_middle, own_normal));
                    }
                    before = int(s);
                    before_middle = own_middle;
                    before_normal = own_normal;
                }
            }
            const auto maker = fitted_loft(solid, ruled, loops, closed, !matched, "loft", note);
            GProp_GProps props;
            if (maker && solid) {
                BRepGProp::VolumeProperties(maker->shape(), props);
            }
            if (!maker || (solid && !(std::abs(props.Mass()) > 0.0))) {
                error = "The loft could not be built";
                return TopoDS_Shape();
            }
            if (caps != nullptr && !closed && solid) {
                *caps = {{maker->first(), tag + ":start"}, {maker->last(), tag + ":end"}};
            }
            if (sides != nullptr && !matched) {
                const Ref<CadShape> section = sections[most];
                int k = 0;
                for (BRepTools_WireExplorer e(TopoDS::Wire(parts[most])); e.More(); e.Next(), ++k) {
                    const int index = section.is_valid() ? section->edge_map().FindIndex(e.Current()) : 0;
                    const std::string edge_name = index > 0 && size_t(index - 1) < section->edge_name_list.size() && !section->edge_name_list[index - 1].empty()
                                                      ? section->edge_name_list[index - 1]
                                                      : "e" + std::to_string(k);
                    int n = 0;
                    for (const TopoDS_Shape& made : maker->generated(e.Current())) {
                        sides->push_back({made, tag + ":g(" + edge_name + ")" + (n > 0 ? "#" + std::to_string(n) : "")});
                        ++n;
                    }
                }
            }
            return maker->shape();
        };
        // A surface loft is every wall; a solid one each piece's loft with its holes' lofts cut out.
        std::vector<TopoDS_Shape> results;
        std::vector<naming::Role> roles;
        for (size_t c = 0; c < count; ++c) {
            std::vector<TopoDS_Shape> outers;
            for (const Piece* piece : chains[c]) {
                outers.push_back(piece->outer);
            }
            std::vector<naming::Role> caps;
            std::vector<naming::Role> sides;
            TopoDS_Shape body = loft_through(outers, !surface, &caps, &sides);
            if (body.IsNull()) {
                return Shape();
            }
            std::vector<TopoDS_Shape> walls;
            for (const std::vector<TopoDS_Shape>& hole : holes[c]) {
                const TopoDS_Shape wall = loft_through(hole, !surface, nullptr, &sides);
                if (wall.IsNull()) {
                    return Shape();
                }
                if (surface) {
                    walls.push_back(wall);
                    continue;
                }
                BRepAlgoAPI_Cut cut(body, wall);
                if (!cut.IsDone()) {
                    error = "The loft's hole could not be cut";
                    return Shape();
                }
                for (naming::Role& cap : caps) {
                    cap.shape = carried(cut, cap.shape);
                }
                for (naming::Role& side : sides) {
                    side.shape = carried(cut, side.shape);
                }
                body = cut.Shape();
            }
            results.push_back(body);
            results.insert(results.end(), walls.begin(), walls.end());
            roles.insert(roles.end(), caps.begin(), caps.end());
            roles.insert(roles.end(), sides.begin(), sides.end());
        }
        Shape out = CadShape::wrap(results.size() == 1 ? results[0] : make_compound(results));
        naming::name_result(*out.ptr(), nullptr, {}, tag, roles);
        return out;
    }
    catch (const Standard_Failure& failure) {
        error = String("Loft failed: ") + failure.GetMessageString();
        return Shape();
    }
}

Shape helix(const Dictionary& p, String& error)
{
    const gp_Pnt origin = P(p.get("origin", Vector3()));
    const gp_Dir axis = D(Vector3(p.get("axis", Vector3(0, 1, 0))).normalized());
    const double radius = p.get("radius", 0.01);
    const double pitch = p.get("pitch", 0.002);
    const double turns = p.get("turns", 5.0);
    const double taper = p.get("taper", 0.0);
    const bool left = p.get("left", false);
    if (radius <= 0.0 || turns <= 0.0) {
        error = "A helix needs a positive radius and turns";
        return Shape();
    }
    try {
        gp_Ax3 frame(origin, axis);
        // A straight line on a surface (rising by pitch every turn of its u, the angle round the
        // axis): a helix on a cylinder or a cone, and a flat (Archimedean) spiral on the plane
        // through origin given by angle and distance from the axis.
        Handle(Geom_Surface) surface;
        gp_Pnt2d start(0.0, 0.0);
        double rise = pitch;
        if (bool(p.get("spiral", false))) {
            surface = new Geom_SurfaceOfRevolution(new Geom_Line(origin, frame.XDirection()), gp_Ax1(origin, axis));
            start.SetY(radius);
        }
        else if (std::abs(taper) > 1e-9) {
            surface = new Geom_ConicalSurface(frame, taper, radius);
            rise = pitch / std::cos(taper);
        }
        else {
            surface = new Geom_CylindricalSurface(frame, radius);
        }
        const gp_Dir2d direction(left ? -2.0 * M_PI : 2.0 * M_PI, rise);
        Handle(Geom2d_Line) line = new Geom2d_Line(start, direction);
        const double length = turns * std::sqrt(4.0 * M_PI * M_PI + rise * rise);
        TopoDS_Edge edge = BRepBuilderAPI_MakeEdge(line, surface, 0.0, length).Edge();
        // Its 3D curve fitted to within CURVE_FIT of the radius, smooth and four pieces a turn:
        // OCCT's default fit (10 um, 30 pieces in all) put a 10 mm helix 7 um off its cylinder and
        // a 200-turn one 30 mm off. (The spiral was a curve through 64 points a turn, 77 nm off at
        // 10 mm.) Checked against its surface, 16 points a turn.
        BRepLib::BuildCurves3d(edge, CURVE_FIT * radius, GeomAbs_C2, 14, 30 + int(std::ceil(4.0 * turns)));
        double first = 0.0;
        double last = 0.0;
        const Handle(Geom_Curve) curve = BRep_Tool::Curve(edge, first, last);
        double worst = curve.IsNull() ? 1e300 : 0.0;
        const int samples = 16 * int(std::ceil(turns));
        for (int i = 0; i <= samples && !curve.IsNull(); ++i) {
            const double t = length * i / samples;
            const gp_Pnt2d uv = line->Value(t);
            worst = std::max(worst, curve->Value(t).Distance(surface->Value(uv.X(), uv.Y())));
        }
        if (!(worst <= 100.0 * CURVE_FIT * radius)) {
            error = "The helix could not be built to within a ten-millionth of its radius (too many turns?)";
            return Shape();
        }
        return named(BRepBuilderAPI_MakeWire(edge).Wire(), tag_of(p, "helix"));
    }
    catch (const Standard_Failure& failure) {
        error = String("Helix failed: ") + failure.GetMessageString();
        return Shape();
    }
}

Shape coil(const Dictionary& p, String& error, String& note)
{
    const std::string tag = tag_of(p, "coil");
    const gp_Pnt origin = P(p.get("origin", Vector3()));
    const gp_Dir axis = D(Vector3(p.get("axis", Vector3(0, 1, 0))).normalized());
    const double size = p.get("section_size", 0.002);
    const String position = p.get("section_position", "on");
    const bool solid = !bool(p.get("surface", false));
    double radius = double(p.get("diameter", 0.02)) * 0.5;
    if (position == "inside") {
        radius -= size * 0.5;
    }
    else if (position == "outside") {
        radius += size * 0.5;
    }
    // The section must stay clear of the axis (and a spiral's of the centre of its first turn's
    // bend): past it the coil crosses itself, and came out with a negative volume.
    const double pitch = p.get("pitch", 0.002);
    const double turns = p.get("turns", 5.0);
    const double taper = p.get("taper", 0.0);
    const bool spiral = p.get("spiral", false);
    const double reach = size * 0.5;
    if (spiral) {
        const double a = pitch / (2.0 * M_PI);
        const double bend = radius > 0.0 ? (radius * radius + 2.0 * a * a) / std::pow(radius * radius + a * a, 1.5) : 1e300;
        if (radius <= reach || reach * bend >= 1.0) {
            char text[200];
            std::snprintf(text, sizeof(text), "The spiral starts too tight for its section (%.3g mm): it would cross itself at its centre (make the diameter bigger or the section smaller)", size * 1000.0);
            error = text;
            return Shape();
        }
    }
    else if (turns > 0.0) {
        const double end = radius + turns * pitch * std::tan(taper);
        if (std::min(radius, end) <= reach) {
            char text[200];
            if (end < radius) {
                std::snprintf(text, sizeof(text), "The coil narrows to %.3g mm across by its end, less than its section (%.3g mm): it would cross its axis", std::max(2.0 * end, 0.0) * 1000.0, size * 1000.0);
            }
            else {
                std::snprintf(text, sizeof(text), "The coil's section (%.3g mm) is as wide as its diameter at the section's centre (%.3g mm) or wider: it would cross its axis", size * 1000.0, std::max(2.0 * radius, 0.0) * 1000.0);
            }
            error = text;
            return Shape();
        }
    }
    // Its turns must clear each other: each lies a pitch on from the one before (along the axis,
    // out along the cone on a taper, outward on a spiral), so the section, in the plane through the
    // axis, may not overlap its copy moved that far (a 4 mm section at a 3 mm pitch built with its
    // turns overlapping 1 mm, counted twice in its volume). Two convex outlines overlap unless one
    // of their sides' normals separates them (a circle's: the move's own direction).
    if (turns > 1.0 && pitch > 0.0) {
        const double h = size * 0.5;
        const String kind = p.get("section", "circle");
        std::vector<gp_XY> corners;
        if (kind == "square") {
            corners = {gp_XY(-h, -h), gp_XY(h, -h), gp_XY(h, h), gp_XY(-h, h)};
        }
        else if (kind == "triangle_out" || kind == "triangle_in") {
            const double s = kind == "triangle_out" ? 1.0 : -1.0;
            corners = {gp_XY(-s * h, -s * h), gp_XY(s * h, 0.0), gp_XY(-s * h, s * h)};
        }
        // (Out from the axis, along it.)
        const gp_XY step = spiral ? gp_XY(pitch, 0.0) : gp_XY(pitch * std::tan(taper), pitch);
        std::vector<gp_XY> normals;
        for (size_t i = 0; i < corners.size(); ++i) {
            const gp_XY side = corners[(i + 1) % corners.size()] - corners[i];
            normals.push_back(gp_XY(-side.Y(), side.X()) / side.Modulus());
        }
        if (corners.empty() && step.Modulus() > 0.0) {
            normals.push_back(step / step.Modulus());
        }
        double depth = 1e300;
        double needed = 1e300;
        for (const gp_XY& normal : normals) {
            double lo = corners.empty() ? -h : 1e300;
            double hi = corners.empty() ? h : -1e300;
            for (const gp_XY& corner : corners) {
                lo = std::min(lo, corner.Dot(normal));
                hi = std::max(hi, corner.Dot(normal));
            }
            const double moved = std::abs(step.Dot(normal));
            depth = std::min(depth, (hi - lo) - moved);
            if (moved > 1e-300) {
                needed = std::min(needed, pitch * (hi - lo) / moved);
            }
        }
        if (!normals.empty() && depth > 1e-9 * size) {
            char text[240];
            std::snprintf(text, sizeof(text), "The coil's turns would overlap each other by %.3g mm: a %.3g mm section needs a pitch of at least %.3g mm (it is %.3g mm)",
                depth * 1000.0, size * 1000.0, needed * 1000.0, pitch * 1000.0);
            error = text;
            return Shape();
        }
    }
    Dictionary h = p.duplicate();
    h["radius"] = radius;
    Shape spine = helix(h, error);
    if (!usable(spine)) {
        return Shape();
    }
    try {
        // The section sits at the helix start, in the plane through the axis.
        gp_Ax3 frame(origin, axis);
        const gp_Dir radial = frame.XDirection();
        const gp_Pnt start = origin.Translated(gp_Vec(radial) * radius);
        const gp_Dir around = axis.Crossed(radial);
        if (bool(p.get("spiral", false))) {
            // The spiral leaves its start along around, drifting outward by pitch per turn.
            const double side = bool(p.get("left", false)) ? -1.0 : 1.0;
            const gp_Dir tangent(gp_Vec(around) * (side * radius) + gp_Vec(radial) * (double(p.get("pitch", 0.002)) / (2.0 * M_PI)));
            const TopoDS_Wire flat = section_wire(p.get("section", "circle"), start, tangent, tangent.Crossed(axis), size);
            return sweep_wire(TopoDS::Wire(spine->get_occ_shape()), flat, &axis, tag, "coil", error, note, solid);
        }
        const String kind = p.get("section", "circle");
        const TopoDS_Wire section = section_wire(kind, start, around, radial, size);
        Shape made = sweep_wire(TopoDS::Wire(spine->get_occ_shape()), section, &axis, tag, "coil", error, note, solid);
        if (usable(made) && std::abs(taper) > 1e-9) {
            // On a cone the section is held square to the path as it drifts outward (OCCT's frames
            // all follow the path's tangent), so it leans out of the plane through the axis, most
            // where the coil is narrowest: that lean, and in a solid the volume against the coil
            // whose section stays in that plane (the section's area times how far its centre goes
            // round the axis).
            const double drift = pitch * std::tan(taper) / (2.0 * M_PI);
            const double end = radius + turns * pitch * std::tan(taper);
            const double turn = std::atan(std::abs(drift) / std::min(radius, end)) * 180.0 / M_PI;
            const double h = size * 0.5;
            const double area = kind == "square" ? size * size : kind == "triangle_out" || kind == "triangle_in" ? 2.0 * h * h : M_PI * h * h;
            const double centre = radius + (kind == "triangle_out" ? -h / 3.0 : kind == "triangle_in" ? h / 3.0 : 0.0);
            const double want = area * 2.0 * M_PI * turns * (centre + 0.5 * turns * pitch * std::tan(taper));
            const double off = solid ? (measure::volume(made->get_occ_shape()).Mass() - want) / want : 0.0;
            if (solid ? std::abs(off) > 1e-6 : turn > 2e-3) {
                char text[240];
                if (solid) {
                    std::snprintf(text, sizeof(text), "The tapered coil's section leans up to %.2g deg out of the plane through its axis, so its volume is %.2g %% %s a coil whose section stays in that plane",
                        turn, std::abs(off) * 100.0, off > 0.0 ? "over" : "under");
                }
                else {
                    std::snprintf(text, sizeof(text), "The tapered coil's section leans up to %.2g deg out of the plane through its axis", turn);
                }
                note = note.is_empty() ? String(text) : note + "; " + String(text);
            }
        }
        return made;
    }
    catch (const Standard_Failure& failure) {
        error = String("Coil failed: ") + failure.GetMessageString();
        return Shape();
    }
}

Shape pipe(const Shape& path, const Dictionary& p, String& error, String& note)
{
    if (!usable(path)) {
        error = "Pick a path for the pipe";
        return Shape();
    }
    const std::string tag = tag_of(p, "pipe");
    const double size = p.get("size", 0.005);
    try {
        const TopoDS_Wire spine = connect(path->get_occ_shape(), error);
        if (spine.IsNull()) {
            return Shape();
        }
        BRepAdaptor_CompCurve curve(spine);
        gp_Pnt p0;
        gp_Vec t0;
        curve.D1(curve.FirstParameter(), p0, t0);
        const gp_Dir tangent(t0);
        const gp_Dir u = std::abs(tangent.Dot(gp_Dir(0, 1, 0))) < 0.9 ? tangent.Crossed(gp_Dir(0, 1, 0)) : tangent.Crossed(gp_Dir(1, 0, 0));
        const TopoDS_Wire section = section_wire(p.get("section", "circle"), p0, tangent, u, size);
        const bool closed = BRep_Tool::IsClosed(spine) || spine.Closed();
        const std::vector<Corner> corners = sharp_corners(spine, closed);
        std::string fold = folds(spine, section, 0.0, 1.0);
        if (fold.empty()) {
            fold = overlaps(spine, section, 0.0, 1.0, false, closed, corners);
        }
        if (!fold.empty()) {
            error = String::utf8(fold.c_str());
            return Shape();
        }
        // Round sharp corners mitred (see mitred_pipe()).
        auto piped = [&](const TopoDS_Wire& around, const std::string& name) {
            if (corners.empty()) {
                return sweep_wire(spine, around, nullptr, name, "pipe", error, note);
            }
            const TopoDS_Shape mitre = mitred_pipe(spine, around, true, closed, corners, "pipe", error, note);
            return mitre.IsNull() ? Shape() : named(mitre, name);
        };
        Shape outer = piped(section, tag);
        if (!usable(outer) || !bool(p.get("hollow", false))) {
            return outer;
        }
        const double wall = p.get("thickness", size * 0.1);
        Shape inner = piped(section_wire(p.get("section", "circle"), p0, tangent, u, size - 2.0 * wall), tag + ":inner");
        return usable(inner) ? boolean(outer, inner, 1, tag, error) : outer;
    }
    catch (const Standard_Failure& failure) {
        error = String("Pipe failed: ") + failure.GetMessageString();
        return Shape();
    }
}

Shape thread(const Dictionary& p, String& error, String& note)
{
    // A helical groove (60-degree V) to cut into a cylinder (external) or a hole (internal).
    const std::string tag = tag_of(p, "thread");
    const gp_Pnt origin = P(p.get("origin", Vector3()));
    const gp_Dir axis = D(Vector3(p.get("axis", Vector3(0, 1, 0))).normalized());
    const double radius = p.get("radius", 0.005);
    const double pitch = p.get("pitch", 0.001);
    const double length = p.get("length", 0.01);
    const double depth = p.get("depth", pitch * 0.6134);
    const bool internal = p.get("internal", false);
    const double half_base = std::min(depth * std::tan(M_PI / 6.0), pitch * 0.45);
    try {
        Dictionary h;
        h["origin"] = p.get("origin", Vector3());
        h["axis"] = p.get("axis", Vector3(0, 1, 0));
        h["radius"] = radius;
        h["pitch"] = pitch;
        h["turns"] = length / pitch;
        h["left"] = p.get("left", false);
        Shape spine = helix(h, error);
        if (!usable(spine)) {
            return Shape();
        }
        gp_Ax3 frame(origin, axis);
        const gp_Dir radial = frame.XDirection();
        auto at = [&](double r, double a) { return origin.Translated(gp_Vec(radial) * r + gp_Vec(axis) * a); };
        // The V's open side reaches past the surface so the cut is clean.
        const double surface_r = internal ? radius - depth * 0.1 : radius + depth * 0.1;
        const double tip_r = internal ? radius + depth : radius - depth;
        BRepBuilderAPI_MakePolygon polygon(at(surface_r, -half_base), at(tip_r, 0.0), at(surface_r, half_base), true);
        return sweep_wire(TopoDS::Wire(spine->get_occ_shape()), polygon.Wire(), &axis, tag, "thread", error, note);
    }
    catch (const Standard_Failure& failure) {
        error = String("Thread failed: ") + failure.GetMessageString();
        return Shape();
    }
}

Shape fillet(const Shape& shape, const PackedInt32Array& edges, const Dictionary& p, String& error, String& note)
{
    if (!usable(shape) || edges.is_empty()) {
        error = "Pick edges to fillet";
        return Shape();
    }
    const std::string tag = tag_of(p, "fillet");
    const double r1 = p.get("radius", 0.001);
    const double r2 = p.get("radius2", r1);
    const String type = p.get("type", "constant");
    try {
        const std::vector<TopoDS_Edge> list = pick_edges(shape, edges);
        std::string problem;
        bool stopped = false;
        // (A chord's radius is at least half of it.)
        const double blend_size = type == "variable" ? std::min(std::abs(r1), std::abs(r2)) : type == "chord" ? 0.5 * std::abs(r1) : std::abs(r1);
        const auto maker = blended<BRepFilletAPI_MakeFillet>(shape->get_occ_shape(), [&](BRepFilletAPI_MakeFillet& made) {
            for (size_t i = 0; i < list.size(); ++i) {
                if (type == "variable") {
                    made.Add(r1, r2, list[i]);
                }
                else if (type == "chord") {
                    // A chord length across the fillet: radius = chord / (2 sin(dihedral / 2)).
                    const Dictionary info = shape->edge_info(edges[int64_t(i)]);
                    const double dihedral = info.get("dihedral", M_PI * 0.5);
                    made.Add(r1 / (2.0 * std::sin(std::max(dihedral, 1e-3) * 0.5)), list[i]);
                }
                else {
                    made.Add(r1, list[i]);
                }
            }
        }, int(list.size()), blend_size, "fillet", note, problem, stopped);
        if (!maker) {
            error = stopped && problem.empty() ? blend_too_long("fillet", "radius")
                                               : blend_error("fillet", "radius", problem, std::max(r1, r2), list, diagonal(shape->get_occ_shape()));
            return Shape();
        }
        Shape out = CadShape::wrap(maker->Shape());
        naming::name_result(*out.ptr(), maker.get(), {shape.ptr()}, tag);
        return out;
    }
    catch (const Standard_Failure& failure) {
        error = String("Fillet failed: ") + failure.GetMessageString();
        return Shape();
    }
}

Shape chamfer(const Shape& shape, const PackedInt32Array& edges, const Dictionary& p, String& error, String& note)
{
    if (!usable(shape) || edges.is_empty()) {
        error = "Pick edges to chamfer";
        return Shape();
    }
    const std::string tag = tag_of(p, "chamfer");
    const double d1 = p.get("distance", 0.001);
    const double d2 = p.get("distance2", d1);
    const double angle = p.get("angle", M_PI * 0.25);
    const String type = p.get("type", "equal");
    try {
        TopTools_IndexedDataMapOfShapeListOfShape edge_faces;
        TopExp::MapShapesAndAncestors(shape->get_occ_shape(), TopAbs_EDGE, TopAbs_FACE, edge_faces);
        const std::vector<TopoDS_Edge> list = pick_edges(shape, edges);
        std::string problem;
        bool stopped = false;
        const double blend_size = type == "two" ? std::min(std::abs(d1), std::abs(d2))
                                  : type == "angle" ? std::abs(d1) * std::min(1.0, std::abs(std::tan(angle)))
                                                    : std::abs(d1);
        const auto maker = blended<ChamferMaker>(shape->get_occ_shape(), [&](ChamferMaker& made) {
            for (const TopoDS_Edge& edge : list) {
                const TopoDS_Face face = TopoDS::Face(edge_faces.FindFromKey(edge).First());
                if (type == "two") {
                    made.builder.Add(d1, d2, edge, face);
                }
                else if (type == "angle") {
                    made.builder.AddDA(d1, angle, edge, face);
                }
                else {
                    made.builder.Add(d1, edge);
                }
            }
        }, int(list.size()), blend_size, "chamfer", note, problem, stopped);
        if (!maker) {
            error = stopped && problem.empty() ? blend_too_long("chamfer", "distance")
                                               : blend_error("chamfer", "distance", problem, std::max(d1, d2), list, diagonal(shape->get_occ_shape()));
            return Shape();
        }
        Shape out = CadShape::wrap(maker->Shape());
        naming::name_result(*out.ptr(), maker.get(), {shape.ptr()}, tag);
        return out;
    }
    catch (const Standard_Failure& failure) {
        error = String("Chamfer failed: ") + failure.GetMessageString();
        return Shape();
    }
}

namespace
{

/// Bodies smaller than this (their box's diagonal) are offset scaled up to it and the offset
/// scaled back. OCCT's offset works to fixed tolerances (1e-7 m and its own 1e-6 m
/// approximations), so on a millimetre body they are a large part of a thin wall: it takes
/// edges between smooth spline faces for creases and puts round joins on them, pipes of the wall's
/// radius that stick out of the body (a converted 1 mm sphere at a 0.04 mm wall: its inner wall
/// 1.0 wall outside the body in 200 places), and takes many seconds over a 0.5 mm one. Scaled,
/// the same body and wall come out as they do at that size.
constexpr double OFFSET_REFERENCE_SIZE = 0.05;

/// A shape made on a copy scaled up (by trsf's inverse), scaled back by trsf (or only made splines,
/// with the identity), names carried over.
/// Its offset faces are made splines first, at the larger size: OCCT evaluates an offset surface
/// to fixed tolerances on its derivatives, and on a millimetre one takes most points for
/// singular ones, so meshing it crawls (a 0.5 mm sphere's inner wall: 21 s for 5000 points
/// instead of 0.1 s; as a spline 1e-6 of the 50 mm size off at most).
Shape scaled_back(const Shape& made, const gp_Trsf& trsf)
{
    // (OCCT's shape healing reads the shape's type first and dies on an empty one: never hand it
    // one, whatever the caller checked.)
    if (!usable(made)) {
        return Shape();
    }
    Shape converted = made;
    try {
        const TopoDS_Shape splines = ShapeCustom::ConvertToBSpline(made->get_occ_shape(), false, false, true, false);
        if (!splines.IsNull() && map_of(splines, TopAbs_FACE).Extent() == map_of(made->get_occ_shape(), TopAbs_FACE).Extent()) {
            converted = CadShape::wrap(splines);
            converted->face_name_list = made->face_name_list;
            converted->edge_name_list = made->edge_name_list;
        }
    }
    catch (const Standard_Failure&) {
        // (Kept with its offset faces: slower to mesh, the same shape.)
        converted = made;
    }
    return moved(converted, trsf);
}

/// What offset_result_problem says of an offset OCCT handed back with nothing in it.
const char* const OFFSET_EMPTY = "it comes out empty";

/// Why an offset OCCT reports as done (made, of body by distance) is no offset at all, or "":
/// OCCT's offset says it is done and hands back nothing, a solid without faces, faces of no
/// volume or a solid inside out where the offset collapses the body or a round in it (a box
/// 10 mm thick offset in by 6 mm: an empty shape; a 1 mm round offset in by 1 mm: six faces of no
/// volume; a 1 mm sphere offset in by 0.6 mm: a negative volume).
std::string offset_result_problem(const TopoDS_Shape& body, const TopoDS_Shape& made, double distance)
{
    if (made.IsNull() || map_of(made, TopAbs_FACE).Extent() == 0) {
        return OFFSET_EMPTY;
    }
    // (Only a closed body's offset has a volume to check: the offset of a face or an open shell
    // is a surface.)
    const bool solid_body = map_of(body, TopAbs_SOLID).Extent() > 0 && shells_closed(body);
    if (!solid_body) {
        return "";
    }
    // (A solid, or a closed shell: OCCT hands back the offset of an L-shaped box as its shell.)
    if (!shells_closed(made)) {
        return "it does not come out as a closed body";
    }
    const double before = measure::volume(body).Mass();
    const double after = measure::volume(made).Mass();
    if (!std::isfinite(after) || !(after > 1e-9 * std::abs(before))) {
        return after < 0.0 ? "it comes out inside out" : "it comes out with no volume";
    }
    if (distance < 0.0 ? !(after < before) : !(after > before)) {
        return "it comes out no smaller or larger than the body";
    }
    return "";
}

/// The offset of a whole shape (every face distance along its normal, arcs at the edges), on a
/// copy scaled up by factor about the middle of its box first when factor isn't 1 (and the offset
/// scaled back), stopped at the time limit or after seconds when given (stopped set then). An offset OCCT reports as done
/// but that isn't one (offset_result_problem) is refused, error saying why.
Shape offset_whole(const Shape& picked, double distance, double factor, const std::string& tag, String& error, bool& stopped, double seconds = -1.0)
{
    stopped = false;
    try {
        // (On a copy: see shell.)
        Shape shape = detached(picked);
        const double scale = factor > 0.0 ? factor : 1.0;
        gp_Trsf up;
        if (scale != 1.0) {
            Bnd_Box box;
            BRepBndLib::Add(shape->get_occ_shape(), box);
            up.SetScale(box.IsVoid() ? gp_Pnt() : gp_Pnt(0.5 * (box.CornerMin().XYZ() + box.CornerMax().XYZ())), scale);
            shape = moved(shape, up);
        }
        // (On the heap: when OCCT faults inside it, it is let go of as it is, half made.)
        auto made = std::make_unique<BRepOffsetAPI_MakeOffsetShape>();
        BRepOffsetAPI_MakeOffsetShape& maker = *made;
        const Handle(Deadline) clock = new Deadline(seconds > 0.0 ? seconds : g_time_limit);
        if (!survived([&] {
                maker.PerformByJoin(shape->get_occ_shape(), distance * scale, 1e-7, BRepOffset_Skin, false, false, GeomAbs_Arc, false, clock->Start());
            })) {
            (void)made.release();
            error = String("The offset could not be built: ") + KERNEL_FAULT;
            return Shape();
        }
        if (clock->expired()) {
            stopped = true;
            error = too_long("offset");
            return Shape();
        }
        if (!maker.IsDone()) {
            error = "The offset could not be built";
            return Shape();
        }
        const std::string bad = offset_result_problem(shape->get_occ_shape(), maker.Shape(), distance * scale);
        if (!bad.empty()) {
            error = String::utf8(("The offset could not be built at that distance: " + bad).c_str());
            return Shape();
        }
        Shape out = CadShape::wrap(maker.Shape());
        naming::name_result(*out.ptr(), &maker, {shape.ptr()}, tag);
        return scale != 1.0 ? scaled_back(out, up.Inverted()) : out;
    }
    catch (const Standard_Failure& failure) {
        const char* said = failure.GetMessageString();
        error = String("The offset could not be built: the geometry kernel failed on this body") +
                (said != nullptr && said[0] != 0 ? String(" (") + said + ")" : String());
        return Shape();
    }
}

/// The factor offset_whole scales a body by: up to OFFSET_REFERENCE_SIZE when it is smaller (by
/// its box's diagonal), 1 otherwise.
double offset_factor(const TopoDS_Shape& s)
{
    const double size = diagonal(s);
    return size > 0.0 && size < OFFSET_REFERENCE_SIZE ? OFFSET_REFERENCE_SIZE / size : 1.0;
}

/// The one shell of a shape that has exactly one (null otherwise).
TopoDS_Shell only_shell(const TopoDS_Shape& s)
{
    const TopTools_IndexedMapOfShape shells = map_of(s, TopAbs_SHELL);
    return shells.Extent() == 1 ? TopoDS::Shell(shells(1)) : TopoDS_Shell();
}

TopoDS_Solid solid_of(const TopoDS_Shell& shell)
{
    BRep_Builder builder;
    TopoDS_Solid solid;
    builder.MakeSolid(solid);
    builder.Add(solid, shell);
    return solid;
}

/// A shape's faces as one triangle mesh with a box tree over it, for distances to its surface and
/// rays through it. It is made from a meshed copy (meshed_copy), so the shape keeps its own mesh;
/// triangles wind with the faces' orientation (outward on a solid).
struct SurfaceMesh
{
    std::vector<std::array<double, 3>> points;
    std::vector<std::array<int, 3>> triangles;
    subd::Bvh tree;

    void add(const TopoDS_Shape& meshed)
    {
        for (TopExp_Explorer it(meshed, TopAbs_FACE); it.More(); it.Next()) {
            const TopoDS_Face& face = TopoDS::Face(it.Current());
            TopLoc_Location location;
            const Handle(Poly_Triangulation) mesh = BRep_Tool::Triangulation(face, location);
            if (mesh.IsNull()) {
                continue;
            }
            const gp_Trsf place = location.Transformation();
            const int base = int(points.size());
            for (int n = 1; n <= mesh->NbNodes(); ++n) {
                const gp_Pnt p = mesh->Node(n).Transformed(place);
                points.push_back({p.X(), p.Y(), p.Z()});
            }
            const bool reversed = face.Orientation() == TopAbs_REVERSED;
            for (int k = 1; k <= mesh->NbTriangles(); ++k) {
                int a, b, c;
                mesh->Triangle(k).Get(a, b, c);
                triangles.push_back(reversed ? std::array<int, 3>{base + a - 1, base + c - 1, base + b - 1} : std::array<int, 3>{base + a - 1, base + b - 1, base + c - 1});
            }
        }
    }

    void build()
    {
        std::vector<subd::Box> boxes(triangles.size());
        for (size_t i = 0; i < triangles.size(); ++i) {
            for (int k = 0; k < 3; ++k) {
                boxes[i].add(points[size_t(triangles[i][size_t(k)])].data());
            }
        }
        tree.build(boxes);
    }

    const double* corner(size_t tri, int k) const
    {
        return points[size_t(triangles[tri][size_t(k)])].data();
    }

    /// The triangle's outward unit normal (zero when it has no area).
    gp_Vec normal(size_t tri) const
    {
        const double* a = corner(tri, 0);
        const double* b = corner(tri, 1);
        const double* c = corner(tri, 2);
        const gp_Vec n = gp_Vec(b[0] - a[0], b[1] - a[1], b[2] - a[2]).Crossed(gp_Vec(c[0] - a[0], c[1] - a[1], c[2] - a[2]));
        const double m = n.Magnitude();
        return m > 0.0 ? n / m : gp_Vec();
    }

    /// The distance from p to the mesh, or reach when nothing is nearer.
    double distance(const gp_Pnt& p, double reach) const
    {
        int tri = -1;
        gp_Pnt at;
        return distance(p, reach, tri, at);
    }

    /// The same, with the nearest triangle (or -1) and the nearest point on it.
    double distance(const gp_Pnt& p, double reach, int& nearest_tri, gp_Pnt& at) const
    {
        const double q[3] = {p.X(), p.Y(), p.Z()};
        double best2 = reach * reach;
        nearest_tri = -1;
        tree.nearest(q, best2, [&](int tri, double& b2) {
            double out[3], u, v;
            const double d2 = subd::closest_on_triangle(q, corner(size_t(tri), 0), corner(size_t(tri), 1), corner(size_t(tri), 2), out, u, v);
            if (d2 < b2) {
                b2 = d2;
                nearest_tri = tri;
                at.SetCoord(out[0], out[1], out[2]);
            }
        });
        return std::sqrt(best2);
    }

    /// Whether p, d from the mesh with its nearest point at on triangle tri, is outside the closed
    /// mesh: by the side of tri it is on when that is clear (the nearest point inside a triangle,
    /// or on an edge, where either triangle tells), by rays otherwise (beside a corner, or level
    /// with the triangle). (An outside point is checked by rays too: it is what matters.)
    bool outside(const gp_Pnt& p, double d, int tri, const gp_Pnt& at) const
    {
        if (tri < 0 || !(d > 0.0)) {
            return !inside(p);
        }
        const double side = gp_Vec(at, p).Dot(normal(size_t(tri))) / d;
        if (side < -0.3) {
            return false;
        }
        return !inside(p);
    }

    /// The nearest triangle the ray o + s d leaves the mesh through (its outward normal along d)
    /// for s in (from, to), or -1; s is set to where.
    int exit(const gp_Pnt& o, const gp_Dir& d, double from, double to, double& s) const
    {
        const double q[3] = {o.X(), o.Y(), o.Z()};
        const double dir[3] = {d.X(), d.Y(), d.Z()};
        int found = -1;
        double at = to;
        tree.ray(q, dir, to, [&](int tri, double& tmax) {
            double t, u, v;
            if (subd::ray_triangle(q, dir, corner(size_t(tri), 0), corner(size_t(tri), 1), corner(size_t(tri), 2), from, tmax, t, u, v) &&
                normal(size_t(tri)).Dot(gp_Vec(d)) > 0.0) {
                tmax = t;
                at = t;
                found = tri;
            }
            return true;
        });
        s = at;
        return found;
    }

    /// Whether p is inside the closed mesh: the parity of the crossings of three rays, by majority
    /// (a ray through an edge or a corner can count one twice).
    bool inside(const gp_Pnt& p) const
    {
        static const double dirs[3][3] = {{0.5773502, 0.6123724, 0.5400617}, {-0.7071068, 0.3015113, 0.6396021}, {0.2672612, -0.8017837, -0.5345225}};
        const double q[3] = {p.X(), p.Y(), p.Z()};
        int votes = 0;
        for (const auto& dir : dirs) {
            int crossings = 0;
            tree.ray(q, dir, std::numeric_limits<double>::infinity(), [&](int tri, double&) {
                double t, u, v;
                if (subd::ray_triangle(q, dir, corner(size_t(tri), 0), corner(size_t(tri), 1), corner(size_t(tri), 2), 0.0, std::numeric_limits<double>::infinity(), t, u, v)) {
                    ++crossings;
                }
                return true;
            });
            votes += crossings % 2;
        }
        return votes >= 2;
    }
};

/// How far the meshed shape's triangles stray from their faces: the most, over every triangle,
/// of the gap between its middle and the face's point at its middle's parameters (0 when no face
/// has parameters on its nodes).
double mesh_gap(const TopoDS_Shape& meshed)
{
    double worst = 0.0;
    for (TopExp_Explorer it(meshed, TopAbs_FACE); it.More(); it.Next()) {
        const TopoDS_Face& face = TopoDS::Face(it.Current());
        TopLoc_Location location;
        const Handle(Poly_Triangulation) mesh = BRep_Tool::Triangulation(face, location);
        TopLoc_Location surface_location;
        const Handle(Geom_Surface) surface = BRep_Tool::Surface(face, surface_location);
        if (mesh.IsNull() || !mesh->HasUVNodes() || surface.IsNull()) {
            continue;
        }
        const gp_Trsf place = location.Transformation();
        const gp_Trsf surface_place = surface_location.Transformation();
        for (int k = 1; k <= mesh->NbTriangles(); ++k) {
            int a, b, c;
            mesh->Triangle(k).Get(a, b, c);
            const gp_Pnt middle = gp_Pnt((mesh->Node(a).XYZ() + mesh->Node(b).XYZ() + mesh->Node(c).XYZ()) / 3.0).Transformed(place);
            const gp_XY uv = (mesh->UVNode(a).XY() + mesh->UVNode(b).XY() + mesh->UVNode(c).XY()) / 3.0;
            worst = std::max(worst, middle.Distance(surface->Value(uv.X(), uv.Y()).Transformed(surface_place)));
        }
    }
    return worst;
}

/// A copy of s (sharing its geometry) meshed within deflection; null when that ran past seconds.
/// OCCT's mesh of a face extruded from a spline can cut far across its bends (triangles from one
/// end of a horseshoe's bend to the other, 0.7 mm off its face asked for 0.002 mm), which would
/// put every check made on the mesh off by as much: when its triangles stray more than a few
/// deflections from their faces, a copy with every face turned into splines (the same shape, when
/// no face is an offset, which would only come out near it) is meshed instead, if that comes out
/// closer. Only when splines is set (the copy's faces' kinds change), for the bodies a check
/// measures from: the points it measures are taken on the faces themselves, not their mesh.
TopoDS_Shape meshed_copy(const TopoDS_Shape& s, double deflection, double seconds, bool splines = false)
{
    const auto start = std::chrono::steady_clock::now();
    deflection = std::max(deflection, MESH_DEFLECTION_FLOOR);
    IMeshTools_Parameters params;
    params.Deflection = deflection;
    params.DeflectionInterior = deflection;
    params.Angle = 0.5;
    params.AngleInterior = 0.5;
    params.MinSize = 0.5 * deflection;
    // (Faces in parallel: OCCT's own worker threads, done when this returns.)
    params.InParallel = true;
    BRepBuilderAPI_Copy copier(s, false, false);
    const TopoDS_Shape copy = copier.Shape();
    {
        const Handle(Deadline) clock = new Deadline(seconds);
        BRepMesh_IncrementalMesh mesher(copy, params, clock->Start());
        if (clock->expired()) {
            return TopoDS_Shape();
        }
    }
    if (!splines) {
        return copy;
    }
    const double gap = mesh_gap(copy);
    if (!(gap > 4.0 * deflection)) {
        return copy;
    }
    const double left = seconds - std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    if (!(left > 0.0)) {
        return copy;
    }
    // (Offset faces would be turned into splines only near them: the measure would be off.)
    for (TopExp_Explorer it(s, TopAbs_FACE); it.More(); it.Next()) {
        Handle(Geom_Surface) surface = BRep_Tool::Surface(TopoDS::Face(it.Current()));
        while (!surface.IsNull() && surface->IsKind(STANDARD_TYPE(Geom_RectangularTrimmedSurface))) {
            surface = Handle(Geom_RectangularTrimmedSurface)::DownCast(surface)->BasisSurface();
        }
        if (surface.IsNull() || surface->IsKind(STANDARD_TYPE(Geom_OffsetSurface))) {
            return copy;
        }
    }
    try {
        BRepBuilderAPI_NurbsConvert convert(s, true);
        if (!convert.IsDone() || convert.Shape().IsNull()) {
            return copy;
        }
        const TopoDS_Shape converted = convert.Shape();
        const Handle(Deadline) clock = new Deadline(left);
        BRepMesh_IncrementalMesh mesher(converted, params, clock->Start());
        if (clock->expired()) {
            return TopoDS_Shape();
        }
        return mesh_gap(converted) < gap ? converted : copy;
    }
    catch (const Standard_Failure&) {
        return copy;
    }
}

/// How the places and lengths in a refusal are told while hollow_closed works on a scaled copy
/// of a small body (ReportScale): back to the body's own, with as many decimals as its size needs.
thread_local gp_Trsf g_report_place;
thread_local double g_report_scale = 1.0;
thread_local int g_report_decimals = 1;

struct ReportScale
{
    ReportScale(const gp_Trsf& back, double size)
    {
        g_report_place = back;
        g_report_scale = back.ScaleFactor();
        g_report_decimals = size < 0.002 ? 3 : size < 0.02 ? 2 : 1;
    }
    ~ReportScale()
    {
        g_report_place = gp_Trsf();
        g_report_scale = 1.0;
        g_report_decimals = 1;
    }
};

/// "(12.3, -4.5, 6.0) mm"
std::string where_mm(const gp_Pnt& at)
{
    const gp_Pnt p = at.Transformed(g_report_place);
    char text[128];
    const int d = g_report_decimals;
    std::snprintf(text, sizeof(text), "(%.*f, %.*f, %.*f) mm", d, p.X() * 1000.0, d, p.Y() * 1000.0, d, p.Z() * 1000.0);
    return text;
}

/// "2.5 mm" to three figures.
std::string mm(double metres)
{
    char text[48];
    std::snprintf(text, sizeof(text), "%.3g mm", metres * g_report_scale * 1000.0);
    return text;
}

/// The wall a closed body's hollow shell is checked to (of the thickness): every point of the
/// inner wall lies at least HOLLOW_NEAR and at most HOLLOW_FAR thicknesses from the outside.
constexpr double HOLLOW_NEAR = 0.97;
constexpr double HOLLOW_FAR = 1.03;

/// How close (in thicknesses) the offset of a point where the outside bends round tighter than
/// the wall may come to the outside before the wall is refused without building it (a converted
/// plate's 3.7 mm rims at a 7.7 mm wall: walls at 0.6 of it). Between this and HOLLOW_NEAR the
/// full check on the built offset decides.
constexpr double HOLLOW_UPFRONT = 0.8;

/// Rounds of a fixed radius under this many walls are taken off for the wall in from a body
/// (hollow_closed): a round of the wall's radius or a little more offsets to nothing, or to a
/// sliver OCCT turns inside out, and the sharp corner's wall in lies within HOLLOW_NEAR of the
/// round's (at a corner round, r - (r - t) * sqrt(3) >= 0.97 t up to r = 1.04 t).
constexpr double HOLLOW_TIGHT = 1.04;

/// How much thicker than asked the offset of a retried inner wall is made (hollow_closed): OCCT's
/// offset of some bodies fails at one distance and works a hair from it, and a wall this much
/// thicker is well within HOLLOW_NEAR..HOLLOW_FAR of the thickness.
constexpr double HOLLOW_STRETCH = 0.005;

/// What a closed hollow's refusal says when OCCT's offset made no inner wall at all.
const char* const NO_INNER_WALL = "its inner wall (the body's offset in by the wall) could not be made";

/// How far (in thicknesses) a wall made with sharp joins may lie from the outside: at an inside
/// corner of the body the walls' planes meet a wall's thickness from each (1.41 of it from the
/// corner's edge at a right angle, 2 at 120 degrees).
constexpr double HOLLOW_SHARP_FAR = 2.0;

/// Faces narrower than this many walls are taken off for a retried wall in from a body
/// (narrow_faces): the wall in closes up a 45 degree chamfer 1.2 times its width in.
constexpr double HOLLOW_NARROW = 2.0;

/// Why a closed body can't be hollowed with a wall of thickness, found cheaply before any offset
/// is built, or "" (outer: the body's mesh; meshed: the body's meshed copy). OCCT's offset of a
/// spline face moves each point along its normal and never trims what that folds or crosses, so
/// the inner wall comes out wrong (and, cut out, slowly: 10 to 20 s) wherever
/// - the body is thinner than two walls: an inward ray meets the far side (facing back along the
///   ray) less than twice the thickness in, or
/// - the outside bends round tighter than the wall (a convex curvature radius under the
///   thickness) and the point a wall in from there comes within HOLLOW_UPFRONT walls of the
///   outside: a fold, not a lone spike of curvature (a converted sphere's poles have spikes of
///   a sixth of its radius that fold nothing).
/// (Where a ray meets a side at a slant, as across a sharp convex edge, the walls are trimmed
/// against each other, which OCCT does do; the full check on the offset, hollow_wall_problem,
/// covers those.)
/// Folds only at faces of a fixed radius (cylinders, spheres, tori, cones: the kernel's fillets
/// and rounds) are listed in tight instead of refused (tight_only set): the wall in from a convex
/// round tighter than the wall is the wall in from the sharp body without it, which OCCT does
/// build (hollow_closed). thinnest is the body's least thickness found (where: thinnest_at),
/// looked for up to a little past two walls (two walls over HOLLOW_NEAR, and the mesh's two
/// deflections): infinite when the body is clearly more than twice the wall thick everywhere, and
/// about twice the wall when it is only about that thick somewhere (a search up to just two walls
/// called a body of exactly twice the wall "more than twice the wall thick everywhere").
struct HollowUpfront
{
    std::string problem;
    double thinnest = std::numeric_limits<double>::infinity();
    gp_Pnt thinnest_at;
    std::vector<int> tight;  // body face indices (1-based) of fixed-radius faces tighter than the wall
    bool tight_only = false;  // the only problem is folds at those faces
};

HollowUpfront hollow_upfront_problem(const SurfaceMesh& outer, const TopoDS_Shape& meshed, double thickness, double deflection)
{
    HollowUpfront result;
    // The mesh's nodes (on the faces themselves; at most about 20000).
    size_t nodes = 0;
    for (TopExp_Explorer it(meshed, TopAbs_FACE); it.More(); it.Next()) {
        TopLoc_Location location;
        const Handle(Poly_Triangulation) mesh = BRep_Tool::Triangulation(TopoDS::Face(it.Current()), location);
        nodes += mesh.IsNull() ? 0 : size_t(mesh->NbNodes());
    }
    const int node_stride = int(std::max<size_t>(1, nodes / 20000));
    // Inward rays from the nodes along the faces' own normals (a triangle's normal can lean
    // 25 degrees off on a sphere's thin triangles, which cut a 50 mm sphere's rays to 45.6 mm).
    double thinnest = std::numeric_limits<double>::infinity();
    gp_Pnt thinnest_at;
    for (TopExp_Explorer it(meshed, TopAbs_FACE); it.More(); it.Next()) {
        const TopoDS_Face& face = TopoDS::Face(it.Current());
        TopLoc_Location location;
        const Handle(Poly_Triangulation) mesh = BRep_Tool::Triangulation(face, location);
        TopLoc_Location surface_location;
        const Handle(Geom_Surface) surface = BRep_Tool::Surface(face, surface_location);
        if (mesh.IsNull() || !mesh->HasUVNodes() || surface.IsNull()) {
            continue;
        }
        const bool reversed = face.Orientation() == TopAbs_REVERSED;
        const gp_Trsf surface_place = surface_location.Transformation();
        for (int n = 1; n <= mesh->NbNodes(); n += node_stride) {
            const gp_Pnt2d uv = mesh->UVNode(n);
            GeomLProp_SLProps props(surface, uv.X(), uv.Y(), 1, 1e-9);
            if (!props.IsNormalDefined()) {
                continue;
            }
            gp_Vec normal(props.Normal());
            if (!reversed) {
                normal.Reverse();
            }
            normal.Transform(surface_place);
            const gp_Pnt p = props.Value().Transformed(surface_place);
            const gp_Dir in(normal);
            double s = 0.0;
            const int hit = outer.exit(p, in, 2.0 * deflection, 2.0 * thickness / HOLLOW_NEAR + 2.0 * deflection, s);
            // (Facing back along the ray within 25 degrees: the far side of a slab, not a slanted one.)
            if (hit >= 0 && outer.normal(size_t(hit)).Dot(gp_Vec(in)) > 0.9 && s < thinnest) {
                thinnest = s;
                thinnest_at = p;
            }
        }
    }
    result.thinnest = thinnest;
    result.thinnest_at = thinnest_at;
    // (The mesh lies within the deflection of the faces, so the body is at most two deflections
    // thicker than found there: thinner than two walls for sure.)
    if (thinnest + 2.0 * deflection < 2.0 * thickness) {
        result.problem = "the wall is thicker than the body allows at " + where_mm(thinnest_at) + ", where the body is only about " + mm(thinnest) +
                         " thick (a hollow body's walls take twice the wall thickness); try a wall under " + mm(0.5 * HOLLOW_NEAR * thinnest);
        return result;
    }
    // Folds: convex curvature at the mesh's nodes (dense where the faces bend), checked by the
    // offset point.
    double closest = std::numeric_limits<double>::infinity();
    double closest_radius = 0.0;
    gp_Pnt closest_at;
    // The closest of the folds at faces of other kinds (splines), which can't be mended.
    double closest_other = std::numeric_limits<double>::infinity();
    const TopTools_IndexedMapOfShape faces = map_of(meshed, TopAbs_FACE);
    for (TopExp_Explorer it(meshed, TopAbs_FACE); it.More(); it.Next()) {
        const TopoDS_Face& face = TopoDS::Face(it.Current());
        const GeomAbs_SurfaceType kind = BRepAdaptor_Surface(face, false).GetType();
        const bool fixed_radius = kind == GeomAbs_Cylinder || kind == GeomAbs_Sphere || kind == GeomAbs_Torus || kind == GeomAbs_Cone;
        const int face_index = faces.FindIndex(face);
        bool listed = false;
        TopLoc_Location location;
        const Handle(Poly_Triangulation) mesh = BRep_Tool::Triangulation(face, location);
        TopLoc_Location surface_location;
        const Handle(Geom_Surface) surface = BRep_Tool::Surface(face, surface_location);
        if (mesh.IsNull() || !mesh->HasUVNodes() || surface.IsNull()) {
            continue;
        }
        const bool reversed = face.Orientation() == TopAbs_REVERSED;
        const gp_Trsf surface_place = surface_location.Transformation();
        // The centre of curvature lies inside (away from the outward normal) when the curvature
        // is negative on a face along its surface, positive on a reversed one.
        auto convex_radius = [&](GeomLProp_SLProps& props) {
            double radius = std::numeric_limits<double>::infinity();
            for (const double k : {props.MaxCurvature(), props.MinCurvature()}) {
                const double convex = reversed ? k : -k;
                if (convex > 0.0) {
                    radius = std::min(radius, 1.0 / convex);
                }
            }
            return radius;
        };
        if (fixed_radius) {
            // (Listed by its middle too, which the nodes below may step over.)
            double u0, u1, v0, v1;
            BRepTools::UVBounds(face, u0, u1, v0, v1);
            GeomLProp_SLProps middle(surface, 0.5 * (u0 + u1), 0.5 * (v0 + v1), 2, 1e-9);
            if (middle.IsCurvatureDefined() && convex_radius(middle) < HOLLOW_TIGHT * thickness) {
                result.tight.push_back(face_index);
                listed = true;
            }
        }
        for (int n = 1; n <= mesh->NbNodes(); n += node_stride) {
            const gp_Pnt2d uv = mesh->UVNode(n);
            GeomLProp_SLProps props(surface, uv.X(), uv.Y(), 2, 1e-9);
            if (!props.IsCurvatureDefined() || !props.IsNormalDefined()) {
                continue;
            }
            const double radius = convex_radius(props);
            if (fixed_radius && !listed && radius < HOLLOW_TIGHT * thickness) {
                result.tight.push_back(face_index);
                listed = true;
            }
            if (!(radius < thickness)) {
                continue;
            }
            gp_Vec normal(props.Normal());
            if (reversed) {
                normal.Reverse();
            }
            normal.Transform(surface_place);
            const gp_Pnt p = props.Value().Transformed(surface_place);
            const double d = outer.distance(p.Translated(-thickness * normal), thickness);
            if (d < closest) {
                closest = d;
                closest_radius = radius;
                closest_at = p;
            }
            if (!fixed_radius) {
                closest_other = std::min(closest_other, d);
            }
        }
    }
    if (closest < HOLLOW_UPFRONT * thickness) {
        result.problem = "the wall is thicker than the body's curve at " + where_mm(closest_at) + ", which bends round with a radius of about " + mm(closest_radius) +
                         ": its inner wall would fold to within " + mm(closest) + " of the outside there; try a wall under " + mm(closest_radius);
        result.tight_only = !result.tight.empty() && !(closest_other < HOLLOW_UPFRONT * thickness);
    }
    return result;
}

/// The area of a meshed shape's triangles, or -1 when a face has no mesh.
double meshed_area(const TopoDS_Shape& meshed)
{
    double area = 0.0;
    for (TopExp_Explorer it(meshed, TopAbs_FACE); it.More(); it.Next()) {
        TopLoc_Location location;
        const Handle(Poly_Triangulation) mesh = BRep_Tool::Triangulation(TopoDS::Face(it.Current()), location);
        if (mesh.IsNull()) {
            return -1.0;
        }
        for (int k = 1; k <= mesh->NbTriangles(); ++k) {
            int a, b, c;
            mesh->Triangle(k).Get(a, b, c);
            area += 0.5 * gp_Vec(mesh->Node(a), mesh->Node(b)).Crossed(gp_Vec(mesh->Node(a), mesh->Node(c))).Magnitude();
        }
    }
    return area;
}

/// Points on a meshed face for a wall check, appended to points: its mesh's nodes, then a grid
/// on each of its triangles about spacing apart, on the face itself through its parameters. With
/// inside_only, only the grid's points inside the face's bounds are kept: OCCT's mesh of a narrow
/// curved face (a shell's rim) can have triangles reaching out across its bends.
void sample_face(const TopoDS_Face& face, double spacing, std::vector<gp_Pnt>& points, bool inside_only = false)
{
    TopLoc_Location location;
    const Handle(Poly_Triangulation) mesh = BRep_Tool::Triangulation(face, location);
    if (mesh.IsNull()) {
        return;
    }
    const gp_Trsf place = location.Transformation();
    TopLoc_Location surface_location;
    const Handle(Geom_Surface) surface = BRep_Tool::Surface(face, surface_location);
    const gp_Trsf surface_place = surface_location.Transformation();
    for (int n = 1; n <= mesh->NbNodes(); ++n) {
        points.push_back(mesh->Node(n).Transformed(place));
    }
    if (!mesh->HasUVNodes() || surface.IsNull()) {
        return;
    }
    std::unique_ptr<BRepTopAdaptor_FClass2d> bounds;
    if (inside_only) {
        bounds = std::make_unique<BRepTopAdaptor_FClass2d>(face, 1e-9);
    }
    for (int k = 1; k <= mesh->NbTriangles(); ++k) {
        int a, b, c;
        mesh->Triangle(k).Get(a, b, c);
        const gp_Pnt pa = mesh->Node(a), pb = mesh->Node(b), pc = mesh->Node(c);
        const double longest = std::max({pa.Distance(pb), pb.Distance(pc), pc.Distance(pa)});
        const double tri_area = 0.5 * gp_Vec(pa, pb).Crossed(gp_Vec(pa, pc)).Magnitude();
        // (A sliver's grid goes by its width, not its length: about its area's worth of points.)
        const int steps = std::min(32, int(std::ceil(std::min(longest, 2.0 * std::sqrt(tri_area)) / spacing)));
        if (steps < 2) {
            continue;
        }
        const gp_XY ua = mesh->UVNode(a).XY(), ub = mesh->UVNode(b).XY(), uc = mesh->UVNode(c).XY();
        // The points of a triangular grid of steps parts a side but its corners (the nodes).
        for (int i = 0; i <= steps; ++i) {
            for (int j = 0; i + j <= steps; ++j) {
                if ((i == 0 && j == 0) || i == steps || j == steps) {
                    continue;
                }
                const double s = double(i) / steps, t = double(j) / steps;
                const gp_XY uv = ua * (1.0 - s - t) + ub * s + uc * t;
                if (bounds != nullptr && bounds->Perform(gp_Pnt2d(uv)) != TopAbs_IN) {
                    continue;
                }
                points.push_back(surface->Value(uv.X(), uv.Y()).Transformed(surface_place));
            }
        }
    }
}

/// Why the inward offset wall (the one closed shell of the offset, wall_meshed its meshed copy)
/// isn't the inner wall of a hollow body of the given thickness, or "": it must face outward (an
/// offset that came back inside out is wrong, not to be turned round), lie inside the body, and
/// every point of it, sampled densely (the mesh's nodes and points between them on the faces
/// themselves, a half thickness or less apart), must lie HOLLOW_NEAR to HOLLOW_FAR thicknesses
/// from the outside (outer, meshed within deflection, a hundredth of the thickness or less).
/// OCCT's own checks and the mesh proximity test pass an inner wall that folds or crosses where
/// the body is thin (a converted torus' walls at a quarter of the thickness, a plate's at 0.6 of
/// it), so this is what decides whether a hollow is right.
std::string hollow_wall_problem(const SurfaceMesh& outer, const TopoDS_Shape& wall, const TopoDS_Shape& wall_meshed, double thickness, double deflection,
                                double far = HOLLOW_FAR, double* touches = nullptr)
{
    if (touches != nullptr) {
        *touches = std::numeric_limits<double>::infinity();
    }
    for (TopExp_Explorer it(wall, TopAbs_SHELL); it.More(); it.Next()) {
        if (!(measure::volume(solid_of(TopoDS::Shell(it.Current()))).Mass() > 0.0)) {
            return "its inner wall came out inside out";
        }
    }
    const double area = meshed_area(wall_meshed);
    if (area < 0.0) {
        return "its inner wall could not be meshed for the check";
    }
    // A half thickness apart, or as close as about 300000 points allow on a big wall.
    const double spacing = std::max(0.5 * thickness, std::sqrt(area / 300000.0));
    const double reach = far * thickness + 2.0 * deflection;
    // The points first (the mesh's nodes, then a grid on each triangle), measured after.
    std::vector<gp_Pnt> points;
    for (TopExp_Explorer it(wall_meshed, TopAbs_FACE); it.More(); it.Next()) {
        sample_face(TopoDS::Face(it.Current()), spacing, points);
    }
    // The distances and sides, on a few threads (the mesh and its tree are only read). Every
    // point's side is checked: an offset can put part of a wall out through the outside, about a
    // wall from it (round joins on edges it took for creases), which the distance alone passes.
    struct Extremes
    {
        double nearest = std::numeric_limits<double>::infinity();
        size_t nearest_at = 0;
        double farthest = 0.0;
        size_t farthest_at = 0;
        size_t outside = 0;
        size_t outside_at = 0;
    };
    const size_t workers = std::max<size_t>(1, std::min<size_t>(8, std::min<size_t>(std::thread::hardware_concurrency(), points.size() / 2000 + 1)));
    std::vector<Extremes> found(workers);
    auto measure_part = [&](size_t part) {
        Extremes& e = found[part];
        for (size_t i = part; i < points.size(); i += workers) {
            int tri = -1;
            gp_Pnt at;
            const double d = outer.distance(points[i], reach, tri, at);
            if (outer.outside(points[i], d, tri, at) && e.outside++ == 0) {
                e.outside_at = i;
            }
            if (d < e.nearest) {
                e.nearest = d;
                e.nearest_at = i;
            }
            if (d > e.farthest) {
                e.farthest = d;
                e.farthest_at = i;
            }
        }
    };
    std::vector<std::thread> threads;
    for (size_t part = 1; part < workers; ++part) {
        threads.emplace_back(measure_part, part);
    }
    measure_part(0);
    for (std::thread& t : threads) {
        t.join();
    }
    Extremes all;
    for (const Extremes& e : found) {
        if (e.outside > 0 && all.outside == 0) {
            all.outside_at = e.outside_at;
        }
        all.outside += e.outside;
        if (e.nearest < all.nearest) {
            all.nearest = e.nearest;
            all.nearest_at = e.nearest_at;
        }
        if (e.farthest > all.farthest) {
            all.farthest = e.farthest;
            all.farthest_at = e.farthest_at;
        }
    }
    if (points.empty()) {
        return "its inner wall could not be meshed for the check";
    }
    if (touches != nullptr) {
        *touches = all.nearest;
    }
    if (all.outside > 0) {
        return "its inner wall would come out through the outside at " + where_mm(points[all.outside_at]) + " (" + std::to_string(all.outside) + " of the " +
               std::to_string(points.size()) + " points checked on it lie outside the body)";
    }
    const double nearest = all.nearest;
    if (touches != nullptr) {
        *touches = nearest;
    }
    const gp_Pnt nearest_at = points[all.nearest_at];
    const double farthest = all.farthest;
    const gp_Pnt farthest_at = points[all.farthest_at];
    if (nearest < HOLLOW_NEAR * thickness) {
        return "its inner wall would come within " + mm(nearest) + " of the outside at " + where_mm(nearest_at) + " instead of " + mm(thickness) +
               " (the body is too thin or bends too tightly there for that wall)";
    }
    if (farthest >= reach * (1.0 - 1e-9)) {
        return "its inner wall would lie more than " + mm(farthest) + " from the outside at " + where_mm(farthest_at) + ", farther than the " + mm(thickness) +
               " wall (the offset came out wrong)";
    }
    return "";
}

/// A compound of the faces (null when there are none).
TopoDS_Shape compound_of(const std::vector<TopoDS_Face>& faces)
{
    if (faces.empty()) {
        return TopoDS_Shape();
    }
    BRep_Builder builder;
    TopoDS_Compound compound;
    builder.MakeCompound(compound);
    for (const TopoDS_Face& face : faces) {
        builder.Add(compound, face);
    }
    return compound;
}

/// "12.3 mm3" to four figures (in the body's own size while a scaled copy is worked on).
std::string mm2(double square_metres)
{
    char text[48];
    std::snprintf(text, sizeof(text), "%.4g mm2", square_metres * g_report_scale * g_report_scale * 1e6);
    return text;
}

std::string mm3(double cubic_metres)
{
    char text[48];
    std::snprintf(text, sizeof(text), "%.4g mm3", cubic_metres * g_report_scale * g_report_scale * g_report_scale * 1e9);
    return text;
}

/// The farthest an edge's curve ends from the corners (vertices) it joins, over every edge of s.
/// OCCT's offset keeps a body's edges and corners where the offset needs new ones (the wall in
/// from a box's chamfered corner: the corner's face no longer meets the box's faces there) and
/// joins the old corners to edges that end a sixth of the wall or more away, held together only
/// by the corners' tolerances: a body its own checks pass that meshes and measures wrong.
double edge_end_gap(const TopoDS_Shape& s)
{
    double worst = 0.0;
    const TopTools_IndexedMapOfShape edges = map_of(s, TopAbs_EDGE);
    for (int i = 1; i <= edges.Extent(); ++i) {
        const TopoDS_Edge& edge = TopoDS::Edge(edges(i));
        if (BRep_Tool::Degenerated(edge)) {
            continue;
        }
        double first = 0.0, last = 0.0;
        TopLoc_Location location;
        const Handle(Geom_Curve) curve = BRep_Tool::Curve(edge, location, first, last);
        TopoDS_Vertex v1, v2;
        TopExp::Vertices(edge, v1, v2);
        if (curve.IsNull() || v1.IsNull() || v2.IsNull()) {
            continue;
        }
        const gp_Trsf place = location.Transformation();
        const gp_Pnt a = curve->Value(first).Transformed(place);
        const gp_Pnt b = curve->Value(last).Transformed(place);
        // (A closed loop's one corner is let be: OCCT's thick solid of a prism open at the top
        // can hang the inner rim's loop on the outer rim's corner, a wall off with a tolerance
        // to match, the loop itself where it belongs; the mesh check covers what that would
        // throw off.)
        if (v1.IsSame(v2) && a.Distance(b) <= std::max(BRep_Tool::Tolerance(v1), Precision::Confusion())) {
            continue;
        }
        const gp_Pnt p1 = BRep_Tool::Pnt(v1);
        const gp_Pnt p2 = BRep_Tool::Pnt(v2);
        worst = std::max(worst, std::min(std::max(a.Distance(p1), b.Distance(p2)), std::max(a.Distance(p2), b.Distance(p1))));
    }
    return worst;
}

/// The volume a meshed shape's triangles enclose (by their faces' orientation), NaN when a face
/// has no mesh.
double meshed_volume(const TopoDS_Shape& meshed)
{
    Bnd_Box box;
    BRepBndLib::Add(meshed, box);
    const gp_XYZ c = box.IsVoid() ? gp_XYZ() : 0.5 * (box.CornerMin().XYZ() + box.CornerMax().XYZ());
    double six = 0.0;
    for (TopExp_Explorer it(meshed, TopAbs_FACE); it.More(); it.Next()) {
        const TopoDS_Face& face = TopoDS::Face(it.Current());
        TopLoc_Location location;
        const Handle(Poly_Triangulation) mesh = BRep_Tool::Triangulation(face, location);
        if (mesh.IsNull()) {
            return std::numeric_limits<double>::quiet_NaN();
        }
        const gp_Trsf place = location.Transformation();
        const bool reversed = face.Orientation() == TopAbs_REVERSED;
        for (int k = 1; k <= mesh->NbTriangles(); ++k) {
            int a, b, d;
            mesh->Triangle(k).Get(a, b, d);
            if (reversed) {
                std::swap(b, d);
            }
            const gp_XYZ pa = mesh->Node(a).Transformed(place).XYZ() - c;
            const gp_XYZ pb = mesh->Node(b).Transformed(place).XYZ() - c;
            const gp_XYZ pd = mesh->Node(d).Transformed(place).XYZ() - c;
            six += pa.Dot(pb.Crossed(pd));
        }
    }
    return six / 6.0;
}

/// Why a body an offset, a shell or a hollow made with a wall (or distance) of thickness can't be
/// handed back, though every check of its walls passed, or "": its edges must end at their
/// corners (edge_end_gap; within a twentieth of the wall), and its mesh must hold the volume its
/// faces do (within a fiftieth of its area times the wall, past what the mesh's own deflection
/// accounts for). The walls' checks measure the mesh, which OCCT makes from the edges' curves
/// and can come out right where the body's faces aren't (a chamfered box's hollow: the body 6%
/// of its area times the wall more than its mesh), or wrong where they are (a rim made with a
/// hole the mesher left out: the opening closed over in the mesh shown and exported).
std::string edge_gap_problem(const TopoDS_Shape& made, double thickness)
{
    const double t = std::abs(thickness);
    if (made.IsNull() || !(t > 0.0)) {
        return "";
    }
    const double gap = edge_end_gap(made);
    if (gap > 0.05 * t) {
        return "its faces don't meet where they should (edges end up to " + mm(gap) +
               " from their corners: the geometry kernel kept the body's corners where the wall needs new ones)";
    }
    return "";
}

/// The edges left open in a meshed body's mesh: its faces' triangles, their corners as the
/// viewport and the STL export get them (single precision), an edge open when an odd number of
/// triangles use it. The faces in pieced (drawn from pieces instead, measure::flat_face_pieces:
/// their own mesh is the lid or the spike the pieces are there to replace) are left out, and so
/// are the mesh edges of the others along an edge they share with one: there the pieces' own
/// chords of the edge meet the neighbour's, a hairline at most as wide as the neighbour's mesh
/// strays from the edge (a rim drawn from pieces beside a spline wall), which stays as it was.
/// widest, when given, takes the width of the widest crack: for an open edge,
/// how far the nearer of its ends lies from the nearest other open edge that doesn't start there
/// (the edge the face beside it was meshed with instead); the first 512 tell. A sound body's
/// faces share the mesh points of their edges and corners, so none is open. OCCT's offset of a
/// body of flat triangles keeps one corner where several faces' planes, moved in, no longer meet
/// in one point, each face's edges ending a few hundredths of a millimetre from it, and the
/// mesher then ends some faces' edges at one place and their neighbours' at another: 36 open
/// edges on a 320-triangle ball's hollow, 388 on a 1280-triangle one's, 0.02 to 0.07 mm wide at
/// a 0.5 to 2 mm wall, in the viewport and the STL export, every check of the walls passing.
int mesh_open_edges(const TopoDS_Shape& meshed, const TopTools_IndexedMapOfShape& pieced, double* widest = nullptr)
{
    TopTools_IndexedMapOfShape beside_pieces;
    for (int i = 1; i <= pieced.Extent(); ++i) {
        TopExp::MapShapes(pieced(i), TopAbs_EDGE, beside_pieces);
    }
    struct Key
    {
        float x, y, z;
        bool operator<(const Key& o) const
        {
            return std::tie(x, y, z) < std::tie(o.x, o.y, o.z);
        }
    };
    std::map<Key, int> ids;
    std::vector<gp_Pnt> points;
    std::map<std::pair<int, int>, int> uses;
    std::set<std::pair<int, int>> let_be;
    for (TopExp_Explorer it(meshed, TopAbs_FACE); it.More(); it.Next()) {
        if (pieced.Contains(it.Current())) {
            continue;
        }
        TopLoc_Location location;
        const Handle(Poly_Triangulation) mesh = BRep_Tool::Triangulation(TopoDS::Face(it.Current()), location);
        if (mesh.IsNull()) {
            continue;
        }
        const gp_Trsf place = location.Transformation();
        std::vector<int> corner(size_t(mesh->NbNodes()) + 1, -1);
        for (int k = 1; k <= mesh->NbTriangles(); ++k) {
            int n[3];
            mesh->Triangle(k).Get(n[0], n[1], n[2]);
            int c[3];
            for (int e = 0; e < 3; ++e) {
                if (corner[size_t(n[e])] < 0) {
                    const gp_Pnt q = mesh->Node(n[e]).Transformed(place);
                    const auto found = ids.emplace(Key{float(q.X()), float(q.Y()), float(q.Z())}, int(points.size()));
                    if (found.second) {
                        points.push_back(q);
                    }
                    corner[size_t(n[e])] = found.first->second;
                }
                c[e] = corner[size_t(n[e])];
            }
            for (int e = 0; e < 3; ++e) {
                const int a = c[e];
                const int b = c[(e + 1) % 3];
                if (a != b) {
                    ++uses[{std::min(a, b), std::max(a, b)}];
                }
            }
        }
        for (TopExp_Explorer edge(it.Current(), TopAbs_EDGE); beside_pieces.Extent() > 0 && edge.More(); edge.Next()) {
            if (!beside_pieces.Contains(edge.Current())) {
                continue;
            }
            const Handle(Poly_PolygonOnTriangulation) polygon = BRep_Tool::PolygonOnTriangulation(TopoDS::Edge(edge.Current()), mesh, location);
            for (int k = 1; !polygon.IsNull() && k < polygon->NbNodes(); ++k) {
                const int n1 = polygon->Node(k);
                const int n2 = polygon->Node(k + 1);
                if (n1 >= 1 && n2 >= 1 && size_t(n1) < corner.size() && size_t(n2) < corner.size() && corner[size_t(n1)] >= 0 && corner[size_t(n2)] >= 0) {
                    let_be.insert({std::min(corner[size_t(n1)], corner[size_t(n2)]), std::max(corner[size_t(n1)], corner[size_t(n2)])});
                }
            }
        }
    }
    std::vector<std::pair<int, int>> cracks;
    for (const auto& [edge, count] : uses) {
        if (count % 2 != 0 && let_be.count(edge) == 0) {
            cracks.push_back(edge);
        }
    }
    if (widest != nullptr) {
        *widest = 0.0;
        auto apart = [&](int corner, const std::pair<int, int>& edge) {
            const gp_XYZ a = points[size_t(edge.first)].XYZ();
            const gp_XYZ ab = points[size_t(edge.second)].XYZ() - a;
            const gp_XYZ ap = points[size_t(corner)].XYZ() - a;
            const double along = ab.SquareModulus() > 0.0 ? std::clamp(ap.Dot(ab) / ab.SquareModulus(), 0.0, 1.0) : 0.0;
            return (ap - ab * along).Modulus();
        };
        auto nearest = [&](int corner) {
            double best = std::numeric_limits<double>::infinity();
            for (const std::pair<int, int>& other : cracks) {
                if (other.first != corner && other.second != corner) {
                    best = std::min(best, apart(corner, other));
                }
            }
            return best;
        };
        for (size_t k = 0; k < cracks.size() && k < 512; ++k) {
            const double width = std::min(nearest(cracks[k].first), nearest(cracks[k].second));
            // (An open edge with no other anywhere: a face left out, as wide as it is long.)
            *widest = std::max(*widest, std::isfinite(width) ? width : points[size_t(cracks[k].first)].Distance(points[size_t(cracks[k].second)]));
        }
    }
    return int(cracks.size());
}

/// Whether an edge of s closed on itself is hung on a corner off its own curve: OCCT's thick solid
/// of a prism open at the top hangs the inner rim's loop on the outer rim's corner, a wall off
/// (edge_end_gap lets that be). The mesher then draws a slit a wall long from that corner to the
/// loop, on every such body the shell has ever made, so the open edges of one aren't counted.
bool has_hung_loop(const TopoDS_Shape& s)
{
    const TopTools_IndexedMapOfShape edges = map_of(s, TopAbs_EDGE);
    for (int i = 1; i <= edges.Extent(); ++i) {
        const TopoDS_Edge& edge = TopoDS::Edge(edges(i));
        if (BRep_Tool::Degenerated(edge)) {
            continue;
        }
        TopoDS_Vertex v1, v2;
        TopExp::Vertices(edge, v1, v2);
        double first = 0.0, last = 0.0;
        TopLoc_Location location;
        const Handle(Geom_Curve) curve = BRep_Tool::Curve(edge, location, first, last);
        if (curve.IsNull() || v1.IsNull() || v2.IsNull() || !v1.IsSame(v2)) {
            continue;
        }
        const gp_Pnt a = curve->Value(first).Transformed(location.Transformation());
        const gp_Pnt b = curve->Value(last).Transformed(location.Transformation());
        if (a.Distance(b) <= Precision::Confusion() && BRep_Tool::Pnt(v1).Distance(a) > 10.0 * Precision::Confusion()) {
            return true;
        }
    }
    return false;
}

/// How far the corners of a flat face lie from the mesh of the pieces it is drawn from instead
/// (measure::flat_face_pieces): the most, over its corners (vertices), of the distance to the
/// nearest node of the pieces' meshes. The faces beside it are drawn to those corners, so that
/// far apart the drawn mesh is open along the edges between them (a face of a body whose corners
/// the geometry kernel left off their edges, see mesh_open_edges, whose mesh misses its own area
/// by over a fiftieth besides: its pieces end at its own edges). Where a rim's loop is hung on
/// another loop's corner the pieces still reach that corner: 0 there.
double pieces_off_corners(const TopoDS_Face& face, const std::vector<TopoDS_Face>& pieces)
{
    double worst = 0.0;
    const TopTools_IndexedMapOfShape corners = map_of(face, TopAbs_VERTEX);
    for (int k = 1; k <= corners.Extent(); ++k) {
        const gp_Pnt corner = BRep_Tool::Pnt(TopoDS::Vertex(corners(k)));
        double nearest = std::numeric_limits<double>::infinity();
        for (const TopoDS_Face& piece : pieces) {
            TopLoc_Location location;
            const Handle(Poly_Triangulation) mesh = BRep_Tool::Triangulation(piece, location);
            if (mesh.IsNull()) {
                continue;
            }
            const gp_Trsf place = location.Transformation();
            for (int n = 1; n <= mesh->NbNodes(); ++n) {
                nearest = std::min(nearest, corner.SquareDistance(mesh->Node(n).Transformed(place)));
            }
        }
        if (std::isfinite(nearest)) {
            worst = std::max(worst, std::sqrt(nearest));
        }
    }
    return worst;
}

/// The mesh half of made_consistency_problem, on made's meshed copy (meshed within deflection):
/// where the mesh strays from its faces (OCCT's mesh of a face extruded from a spline can cut
/// across its bends), by as much more. A closed body's mesh must be closed (mesh_open_edges), and
/// a face drawn from pieces must be drawn to its own corners, where the faces beside it are
/// drawn to (pieces_off_corners), or the body shows and exports with cracks.
std::string mesh_volume_problem(const TopoDS_Shape& made, const TopoDS_Shape& meshed, double thickness, double deflection,
                                double known_volume = std::numeric_limits<double>::quiet_NaN())
{
    const double t = std::abs(thickness);
    const double vm = meshed_volume(meshed);
    if (!std::isfinite(vm)) {
        return "it could not be meshed for the check of its faces";
    }
    // Each face must be drawn as it is: a rim whose hole the mesher misread came out with a lid
    // over the opening (or a piece of it left out) in the mesh shown and exported, which holds
    // almost the volume the faces do. A flat face the viewport and the STL export draw from
    // pieces the mesher reads right passes (measure::face_drawable). Spline faces are checked too
    // (their mesh's nodes on them, and their area).
    int cracked = 0;
    double widest = 0.0;
    TopTools_IndexedMapOfShape pieced;
    for (TopExp_Explorer it(meshed, TopAbs_FACE); it.More(); it.Next()) {
        const TopoDS_Face& face = TopoDS::Face(it.Current());
        double own = 0.0, covered = 0.0, off = 0.0;
        // (A spline face's mesh on it to within a twentieth of the wall, as the edges' ends are
        // to their corners (edge_gap_problem), or the mesh's own few deflections when those are more.)
        const double stray_limit = std::max(4.0 * std::max(deflection, MESH_DEFLECTION_FLOOR), 0.05 * t);
        // (As measure::face_drawable, keeping what is drawn: the face, or its pieces.)
        if (measure::mesh_covers_face(face, std::max(deflection, MESH_DEFLECTION_FLOOR), 0.5, &own, &covered, &off, stray_limit)) {
            continue;
        }
        const std::vector<TopoDS_Face> pieces = measure::flat_face_pieces(face, own, std::max(deflection, MESH_DEFLECTION_FLOOR), 0.5);
        if (!pieces.empty()) {
            pieced.Add(face);
            // (Past the mesh's own accuracy: a crack.)
            const double apart = pieces_off_corners(face, pieces);
            if (apart > 1.5 * std::max(deflection, MESH_DEFLECTION_FLOOR)) {
                ++cracked;
                widest = std::max(widest, apart);
            }
        }
        if (pieces.empty()) {
            const gp_Pnt at = measure::surface(face).CentreOfMass();
            if (off > stray_limit) {
                // (A spline face with a corner or an edge off it: see measure::mesh_covers_face.)
                return "its face around " + where_mm(at) + " meshes up to " + mm(off) + " off the face (a corner or an edge of it is not on it), so it would show and export wrong";
            }
            return "its face around " + where_mm(at) + " meshes to " + mm2(covered) + " against the face's own " + mm2(own) +
                   " (a lid over an opening, or part of the face left out), so it would show and export wrong";
        }
    }
    // (Looked for only where an edge ends off its corner at all, which is what lets the mesher end
    // two faces' edges at different places: the census takes 50 to 85 ms on a converted form
    // body's fine mesh, whose edges end on their corners to rounding.)
    if (cracked == 0 && edge_end_gap(made) > Precision::Confusion() && shells_closed(made) && !has_hung_loop(made)) {
        // (Any at all: a sound body's faces share their edges' and corners' mesh points, and a
        // 1280-triangle ball's hollow came out with 388 open edges 0.005 mm wide at a 0.5 mm wall.)
        double width = 0.0;
        const int open = mesh_open_edges(meshed, pieced, &width);
        if (open > 0) {
            return "its mesh comes out open along " + std::to_string(open) + " edges (cracks up to " + mm(width) +
                   " wide: the geometry kernel left its faces' corners off their own edges, and the faces round such a corner are meshed to different places), so it would show "
                   "and export with cracks";
        }
    }
    if (cracked > 0) {
        return "it would be drawn with cracks beside " + std::to_string(cracked) + " of its faces" + " (their corners lie up to " + mm(widest) +
               " from where the faces beside them are drawn to: the geometry kernel left its faces' corners off their own edges), so it would show and export open";
    }
    // (Its area from the mesh: the allowance needs no more, and a spline wall's own takes long.)
    const double vb = std::isnan(known_volume) ? measure::volume(made).Mass() : known_volume;
    const double area = meshed_area(meshed);
    const double stray = std::max(deflection, mesh_gap(meshed));
    if (!std::isfinite(vb) || std::abs(vb - vm) > area * (0.02 * t + stray) + 1e-9 * std::abs(vb)) {
        return "its faces and its mesh hold different volumes (" + mm3(vb) + " against " + mm3(vm) +
               "), so it would show and export wrong";
    }
    return "";
}

std::string made_consistency_problem(const TopoDS_Shape& made, double thickness)
{
    const double t = std::abs(thickness);
    if (made.IsNull() || !(t > 0.0)) {
        return "";
    }
    const std::string gap = edge_gap_problem(made, t);
    if (!gap.empty()) {
        return gap;
    }
    const double deflection = std::max(0.01 * t, 5e-6 * diagonal(made));
    const TopoDS_Shape meshed = meshed_copy(made, deflection, std::min(5.0, g_time_limit));
    if (meshed.IsNull()) {
        return "it took too long to mesh for the check of its faces";
    }
    return mesh_volume_problem(made, meshed, t, deflection);
}

/// A flat face's plane: a point on it and its outward normal.
struct FacePlane
{
    gp_Pnt p;
    gp_Dir n;
};

/// The planes of a convex body's faces (in the order of its face map) when it is one closed
/// solid of flat faces only, every corner of it on or behind every face's plane; empty otherwise.
/// Such a body's walls are exact without OCCT's offset: the wall in from it (sharp joins or round,
/// the same) is the solid behind every face's plane moved in by the wall (convex_region), which
/// OCCT's offset gets wrong where a face shrinks away (a chamfered box's corner faces).
std::vector<FacePlane> convex_planes(const TopoDS_Shape& body)
{
    if (map_of(body, TopAbs_SOLID).Extent() != 1 || map_of(body, TopAbs_SHELL).Extent() != 1 || !shells_closed(body)) {
        return {};
    }
    const TopTools_IndexedMapOfShape faces = map_of(body, TopAbs_FACE);
    const TopTools_IndexedMapOfShape corners = map_of(body, TopAbs_VERTEX);
    const double tol = 1e-9 + 1e-7 * diagonal(body);
    const gp_Pnt middle = measure::volume(body).CentreOfMass();
    std::vector<gp_XYZ> points;
    points.reserve(size_t(corners.Extent()));
    for (int k = 1; k <= corners.Extent(); ++k) {
        points.push_back(BRep_Tool::Pnt(TopoDS::Vertex(corners(k))).XYZ());
    }
    std::vector<FacePlane> planes;
    for (int i = 1; i <= faces.Extent(); ++i) {
        const TopoDS_Face& face = TopoDS::Face(faces(i));
        const BRepAdaptor_Surface surface(face, false);
        if (surface.GetType() != GeomAbs_Plane) {
            return {};
        }
        const FacePlane plane{surface.Plane().Location(), face_normal(face)};
        if (!(gp_Vec(plane.p, middle).Dot(gp_Vec(plane.n)) < 0.0)) {
            return {};
        }
        const gp_XYZ n = plane.n.XYZ();
        const double h = n.Dot(plane.p.XYZ()) + tol;
        for (const gp_XYZ& q : points) {
            if (n.Dot(q) > h) {
                return {};
            }
        }
        planes.push_back(plane);
    }
    return planes;
}

/// The solid behind the planes moved out along their normals by offsets (in when negative; a NaN
/// offset leaves that plane out), within the cube of half side 2 reach about centre, built
/// straight from the planes: each plane's face is a large square on it cut back by every other
/// plane (a convex polygon cut by one half-space at a time), the faces' corners joined where they
/// fall within weld of each other, and the faces put together sharing those corners and their
/// edges, so the solid is closed as it is made. status: 1 made, 0 nothing is behind all of the
/// planes (the region is empty), -1 the faces didn't close up (corners that near-parallel planes
/// leave too far apart to join), -2 it ran past seconds (every plane is tried against every
/// other). OCCT's common of a box per plane, the way this was made before,
/// took 11 s for a 320-face ball of flat triangles and over three minutes for a 1280-face one
/// (each common inside its own time bound, their sum far outside the time limit); this takes a
/// few hundredths of a second.
TopoDS_Shape half_space_polyhedron(const std::vector<FacePlane>& planes, const std::vector<double>& offsets, const gp_Pnt& centre, double reach, double seconds, int& status)
{
    status = -1;
    const auto started = std::chrono::steady_clock::now();
    auto late = [&]() {
        return std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count() > seconds;
    };
    struct Side
    {
        gp_XYZ n;  // n.x <= h
        double h;
    };
    std::vector<Side> sides;
    for (size_t i = 0; i < planes.size() && i < offsets.size(); ++i) {
        if (!std::isnan(offsets[i])) {
            const gp_XYZ n = planes[i].n.XYZ();
            sides.push_back({n, n.Dot(planes[i].p.XYZ()) + offsets[i]});
        }
    }
    const double bound = 2.0 * reach;
    // (Corners nearer than this are one corner: OCCT's own smallest length at the size these
    // bodies are worked at, and well over what the planes of a mesh stored in single precision
    // leave between the corners of faces that should meet in one.)
    const double weld = std::max(Precision::Confusion(), 2e-6 * reach);
    // Planes that are one plane (a flat patch of several triangles) count once: the one farther in.
    std::vector<bool> dropped(sides.size(), false);
    for (size_t i = 0; i < sides.size(); ++i) {
        if (i % 256 == 0 && late()) {
            status = -2;
            return TopoDS_Shape();
        }
        for (size_t j = i + 1; j < sides.size() && !dropped[i]; ++j) {
            if (!dropped[j] && sides[i].n.Dot(sides[j].n) > 1.0 - 1e-12 && std::abs(sides[i].h - sides[j].h) <= 0.1 * weld) {
                dropped[sides[i].h <= sides[j].h ? j : i] = true;
            }
        }
    }
    std::vector<Side> kept;
    for (size_t i = 0; i < sides.size(); ++i) {
        if (!dropped[i]) {
            kept.push_back(sides[i]);
        }
    }
    for (int axis = 0; axis < 3; ++axis) {
        gp_XYZ n(0.0, 0.0, 0.0);
        n.SetCoord(axis + 1, 1.0);
        kept.push_back({n, centre.Coord(axis + 1) + bound});
        kept.push_back({n.Reversed(), -(centre.Coord(axis + 1) - bound)});
    }
    // Each side's face: a square on its plane, counter-clockwise seen from outside, cut back.
    std::vector<std::vector<gp_XYZ>> polygons(kept.size());
    std::vector<gp_XYZ> cut;
    std::vector<double> behind;
    for (size_t i = 0; i < kept.size(); ++i) {
        if (i % 64 == 0 && late()) {
            status = -2;
            return TopoDS_Shape();
        }
        const gp_XYZ& n = kept[i].n;
        const gp_XYZ on = centre.XYZ() + n * (kept[i].h - n.Dot(centre.XYZ()));
        const gp_Dir in(n.Reversed());
        const gp_XYZ x = (std::abs(in.X()) < 0.6 ? in.Crossed(gp_Dir(1, 0, 0)) : in.Crossed(gp_Dir(0, 1, 0))).XYZ();
        const gp_XYZ y = n.Crossed(x);
        const double side = 8.0 * bound;
        std::vector<gp_XYZ>& polygon = polygons[i];
        polygon = {on - x * side - y * side, on + x * side - y * side, on + x * side + y * side, on - x * side + y * side};
        // (A ball round what is left of the face: a plane it lies wholly behind, as nearly all
        // do once the face's neighbours have cut it down, costs one product instead of one a
        // corner. The planes are taken from the next one on, a mesh's neighbours being mostly
        // near each other in its order, so the face is small early.)
        gp_XYZ middle = on;
        double radius = side * 1.5;
        for (size_t step = 1; step < kept.size() && polygon.size() >= 3; ++step) {
            const size_t j = (i + step) % kept.size();
            const double from_middle = kept[j].n.Dot(middle) - kept[j].h;
            if (from_middle + radius <= 0.0) {
                continue;
            }
            behind.resize(polygon.size());
            bool any_out = false;
            bool any_in = false;
            for (size_t k = 0; k < polygon.size(); ++k) {
                behind[k] = kept[j].n.Dot(polygon[k]) - kept[j].h;
                any_out = any_out || behind[k] > 0.0;
                any_in = any_in || behind[k] <= 0.0;
            }
            if (!any_out) {
                continue;
            }
            if (!any_in) {
                polygon.clear();
                break;
            }
            cut.clear();
            for (size_t k = 0; k < polygon.size(); ++k) {
                const size_t next = (k + 1) % polygon.size();
                if (behind[k] <= 0.0) {
                    cut.push_back(polygon[k]);
                }
                if ((behind[k] <= 0.0) != (behind[next] <= 0.0)) {
                    const double t = behind[k] / (behind[k] - behind[next]);
                    cut.push_back(polygon[k] + (polygon[next] - polygon[k]) * t);
                }
            }
            polygon.swap(cut);
            middle = gp_XYZ(0.0, 0.0, 0.0);
            for (const gp_XYZ& q : polygon) {
                middle += q;
            }
            if (!polygon.empty()) {
                middle /= double(polygon.size());
            }
            radius = 0.0;
            for (const gp_XYZ& q : polygon) {
                radius = std::max(radius, (q - middle).Modulus());
            }
        }
        if (polygon.size() < 3) {
            polygon.clear();
        }
    }
    // The corners, joined where they fall within weld of each other (through chains of them).
    std::vector<gp_XYZ> points;
    std::vector<std::vector<int>> loops(kept.size());
    for (size_t i = 0; i < polygons.size(); ++i) {
        for (const gp_XYZ& q : polygons[i]) {
            loops[i].push_back(int(points.size()));
            points.push_back(q);
        }
    }
    if (points.empty()) {
        status = 0;
        return TopoDS_Shape();
    }
    std::vector<int> parent(points.size());
    for (size_t i = 0; i < parent.size(); ++i) {
        parent[i] = int(i);
    }
    auto root = [&](int i) {
        while (parent[size_t(i)] != i) {
            parent[size_t(i)] = parent[size_t(parent[size_t(i)])];
            i = parent[size_t(i)];
        }
        return i;
    };
    {
        std::map<std::tuple<long long, long long, long long>, std::vector<int>> cells;
        auto cell_of = [&](const gp_XYZ& q) {
            return std::make_tuple((long long)std::floor(q.X() / weld), (long long)std::floor(q.Y() / weld), (long long)std::floor(q.Z() / weld));
        };
        for (size_t i = 0; i < points.size(); ++i) {
            const auto [cx, cy, cz] = cell_of(points[i]);
            for (long long dx = -1; dx <= 1; ++dx) {
                for (long long dy = -1; dy <= 1; ++dy) {
                    for (long long dz = -1; dz <= 1; ++dz) {
                        const auto found = cells.find(std::make_tuple(cx + dx, cy + dy, cz + dz));
                        if (found == cells.end()) {
                            continue;
                        }
                        for (const int other : found->second) {
                            if ((points[size_t(other)] - points[i]).Modulus() <= weld) {
                                parent[size_t(root(int(i)))] = root(other);
                            }
                        }
                    }
                }
            }
            cells[std::make_tuple(cx, cy, cz)].push_back(int(i));
        }
    }
    std::vector<int> corner_of(points.size(), -1);
    std::vector<gp_XYZ> sums;
    std::vector<int> counts;
    for (size_t i = 0; i < points.size(); ++i) {
        const int r = root(int(i));
        if (corner_of[size_t(r)] < 0) {
            corner_of[size_t(r)] = int(sums.size());
            sums.push_back(gp_XYZ(0.0, 0.0, 0.0));
            counts.push_back(0);
        }
        corner_of[i] = corner_of[size_t(r)];
        sums[size_t(corner_of[i])] += points[i];
        ++counts[size_t(corner_of[i])];
    }
    std::vector<gp_Pnt> corners(sums.size());
    for (size_t c = 0; c < sums.size(); ++c) {
        corners[c] = gp_Pnt(sums[c] / double(counts[c]));
    }
    // Each face's loop of corners: no corner twice running, no edge run out and straight back.
    int faces_left = 0;
    for (std::vector<int>& loop : loops) {
        for (int& at : loop) {
            at = corner_of[size_t(at)];
        }
        bool changed = true;
        while (changed && loop.size() >= 3) {
            changed = false;
            for (size_t k = 0; k < loop.size() && loop.size() >= 3; ++k) {
                const size_t next = (k + 1) % loop.size();
                const size_t after = (k + 2) % loop.size();
                if (loop[k] == loop[next]) {
                    loop.erase(loop.begin() + long(next));
                    changed = true;
                    break;
                }
                if (loop[k] == loop[after]) {
                    // (k, next, k: a spike. Its tip and one of the two go.)
                    if (after > next) {
                        loop.erase(loop.begin() + long(after));
                        loop.erase(loop.begin() + long(next));
                    }
                    else {
                        loop.erase(loop.begin() + long(next));
                        loop.erase(loop.begin() + long(after));
                    }
                    changed = true;
                    break;
                }
            }
        }
        if (loop.size() < 3) {
            loop.clear();
        }
        faces_left += loop.empty() ? 0 : 1;
    }
    if (faces_left < 4) {
        status = 0;
        return TopoDS_Shape();
    }
    // Closed: every edge of a face is run the other way by exactly one other face.
    std::map<std::pair<int, int>, int> runs;
    for (const std::vector<int>& loop : loops) {
        for (size_t k = 0; k < loop.size(); ++k) {
            ++runs[{loop[k], loop[(k + 1) % loop.size()]}];
        }
    }
    for (const auto& [edge, count] : runs) {
        const auto back = runs.find({edge.second, edge.first});
        if (count != 1 || back == runs.end() || back->second != 1) {
            return TopoDS_Shape();
        }
    }
    BRep_Builder builder;
    std::vector<TopoDS_Vertex> vertices(corners.size());
    std::vector<bool> used(corners.size(), false);
    for (const std::vector<int>& loop : loops) {
        for (const int c : loop) {
            used[size_t(c)] = true;
        }
    }
    for (size_t c = 0; c < corners.size(); ++c) {
        if (used[c]) {
            builder.MakeVertex(vertices[c], corners[c], weld);
        }
    }
    std::map<std::pair<int, int>, TopoDS_Edge> edges;  // from the lower corner to the higher
    TopoDS_Shell shell;
    builder.MakeShell(shell);
    for (size_t i = 0; i < loops.size(); ++i) {
        const std::vector<int>& loop = loops[i];
        if (loop.empty()) {
            continue;
        }
        TopoDS_Wire wire;
        builder.MakeWire(wire);
        for (size_t k = 0; k < loop.size(); ++k) {
            const int a = loop[k];
            const int b = loop[(k + 1) % loop.size()];
            const std::pair<int, int> key{std::min(a, b), std::max(a, b)};
            auto found = edges.find(key);
            if (found == edges.end()) {
                BRepBuilderAPI_MakeEdge edge(vertices[size_t(key.first)], vertices[size_t(key.second)]);
                if (!edge.IsDone()) {
                    return TopoDS_Shape();
                }
                builder.UpdateEdge(edge.Edge(), weld);
                found = edges.emplace(key, edge.Edge()).first;
            }
            builder.Add(wire, a < b ? found->second : TopoDS::Edge(found->second.Reversed()));
        }
        wire.Closed(true);
        const gp_Pnt on(centre.XYZ() + kept[i].n * (kept[i].h - kept[i].n.Dot(centre.XYZ())));
        BRepBuilderAPI_MakeFace face(gp_Pln(on, gp_Dir(kept[i].n)), wire, true);
        if (!face.IsDone()) {
            return TopoDS_Shape();
        }
        builder.Add(shell, face.Face());
    }
    shell.Closed(true);
    TopoDS_Solid solid;
    builder.MakeSolid(solid);
    builder.Add(solid, shell);
    if (!shells_closed(solid)) {
        return TopoDS_Shape();
    }
    double volume = measure::volume(solid).Mass();
    if (volume < 0.0) {
        solid.Reverse();
        volume = -volume;
    }
    if (!(volume > 0.0)) {
        status = 0;
        return TopoDS_Shape();
    }
    status = 1;
    return solid;
}

/// The solid behind the planes moved out along their normals by offsets (in when negative; a NaN
/// offset leaves that plane out), as it is within reach of centre: built straight from the planes
/// (half_space_polyhedron), or, when its faces don't close up that way, the common of a box behind
/// each moved plane, large enough to hold that ball, inside what is left of the time limit (it
/// takes a common a plane, each slower than the one before). Null when it is empty (empty set
/// then, when given) or can't be made.
TopoDS_Shape half_space_region(const std::vector<FacePlane>& planes, const std::vector<double>& offsets, const gp_Pnt& centre, double reach, bool* empty = nullptr)
{
    if (empty != nullptr) {
        *empty = false;
    }
    int status = -1;
    const TopoDS_Shape direct = half_space_polyhedron(planes, offsets, centre, reach, 0.5 * g_time_limit, status);
    if (status == 1) {
        return direct;
    }
    if (status == 0) {
        if (empty != nullptr) {
            *empty = true;
        }
        return TopoDS_Shape();
    }
    if (status == -2) {
        // (Too many planes for the time: a common a plane would take far longer still.)
        return TopoDS_Shape();
    }
    const auto started = std::chrono::steady_clock::now();
    const double side = 4.0 * reach;
    TopoDS_Shape region;
    for (size_t i = 0; i < planes.size() && i < offsets.size(); ++i) {
        if (std::isnan(offsets[i])) {
            continue;
        }
        const gp_Dir& n = planes[i].n;
        const gp_Pnt on = planes[i].p.Translated(gp_Vec(n) * offsets[i]);
        // (centre, projected onto the moved plane: the box's top face is centred over it.)
        const gp_Pnt over = centre.Translated(gp_Vec(n) * gp_Vec(centre, on).Dot(gp_Vec(n)));
        const gp_Dir in = n.Reversed();
        const gp_Dir x = std::abs(in.X()) < 0.6 ? in.Crossed(gp_Dir(1, 0, 0)) : in.Crossed(gp_Dir(0, 1, 0));
        const gp_Dir y = in.Crossed(x);
        const gp_Pnt corner = over.Translated(gp_Vec(x) * (-0.5 * side) + gp_Vec(y) * (-0.5 * side));
        const TopoDS_Shape box = BRepPrimAPI_MakeBox(gp_Ax2(corner, in, x), side, side, side).Shape();
        if (region.IsNull()) {
            region = box;
            continue;
        }
        BRepAlgoAPI_Common common;
        TopTools_ListOfShape arguments, tools;
        arguments.Append(region);
        tools.Append(box);
        common.SetArguments(arguments);
        common.SetTools(tools);
        // (All of them together inside half the time limit: each had its own 5 s before, and a
        // body of hundreds of faces took minutes.)
        const double left = 0.5 * g_time_limit - std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count();
        if (!(left > 0.0)) {
            return TopoDS_Shape();
        }
        const Handle(Deadline) clock = new Deadline(std::min(5.0, left));
        common.Build(clock->Start());
        if (clock->expired() || !common.IsDone() || common.Shape().IsNull() || map_of(common.Shape(), TopAbs_SOLID).Extent() != 1) {
            return TopoDS_Shape();
        }
        region = common.Shape();
    }
    if (region.IsNull()) {
        return TopoDS_Shape();
    }
    ShapeUpgrade_UnifySameDomain unifier(region, true, true, true);
    unifier.Build();
    const TopoDS_Shape merged = unifier.Shape();
    const TopoDS_Shape result = !merged.IsNull() && map_of(merged, TopAbs_SOLID).Extent() == 1 && shells_closed(merged) ? merged : region;
    if (map_of(result, TopAbs_SOLID).Extent() != 1 || !shells_closed(result) || !(measure::volume(result).Mass() > 0.0)) {
        return TopoDS_Shape();
    }
    return TopoDS::Solid(map_of(result, TopAbs_SOLID)(1));
}

/// Whether the solid behind the planes moved out along their normals by offsets (a NaN offset
/// leaves that plane out) holds any of body's box grown by its size on every side: a corner of
/// it (where three of those planes or the box's sides meet) lies behind all of them. 1 when it
/// does, 0 when it is empty, -1 when there are too many planes to tell quickly.
int half_spaces_meet(const TopoDS_Shape& body, const std::vector<FacePlane>& planes, const std::vector<double>& offsets)
{
    Bnd_Box box;
    BRepBndLib::Add(body, box);
    if (box.IsVoid()) {
        return -1;
    }
    const double size = std::sqrt(box.SquareExtent());
    std::vector<std::pair<gp_XYZ, double>> sides;  // n.x <= h
    for (size_t i = 0; i < planes.size() && i < offsets.size(); ++i) {
        if (!std::isnan(offsets[i])) {
            const gp_XYZ n = planes[i].n.XYZ();
            sides.push_back({n, n.Dot(planes[i].p.XYZ()) + offsets[i]});
        }
    }
    const gp_XYZ lo = box.CornerMin().XYZ() - gp_XYZ(size, size, size);
    const gp_XYZ hi = box.CornerMax().XYZ() + gp_XYZ(size, size, size);
    for (int axis = 0; axis < 3; ++axis) {
        gp_XYZ n(0.0, 0.0, 0.0);
        n.SetCoord(axis + 1, 1.0);
        sides.push_back({n, hi.Coord(axis + 1)});
        sides.push_back({n.Reversed(), -lo.Coord(axis + 1)});
    }
    if (sides.size() > 64) {
        return -1;
    }
    const double tol = 1e-9 * size;
    for (size_t a = 0; a < sides.size(); ++a) {
        for (size_t b = a + 1; b < sides.size(); ++b) {
            const gp_XYZ ab = sides[a].first.Crossed(sides[b].first);
            for (size_t c = b + 1; c < sides.size(); ++c) {
                const double det = sides[c].first.Dot(ab);
                if (std::abs(det) < 1e-9) {
                    continue;
                }
                const gp_XYZ x = (sides[a].second * sides[b].first.Crossed(sides[c].first) + sides[b].second * sides[c].first.Crossed(sides[a].first) +
                                  sides[c].second * ab) /
                                 det;
                bool behind = true;
                for (size_t k = 0; k < sides.size() && behind; ++k) {
                    behind = sides[k].first.Dot(x) <= sides[k].second + tol;
                }
                if (behind) {
                    return 1;
                }
            }
        }
    }
    return 0;
}

/// half_space_region for a convex body of flat faces (its convex_planes), on a copy scaled up to
/// OFFSET_REFERENCE_SIZE when it is smaller (OCCT's common works to fixed tolerances), scaled back;
/// its faces named afresh by tag. Null when it is empty (empty set then, when given: known for
/// sure only when the region was built straight from the planes) or can't be made.
Shape convex_region(const TopoDS_Shape& body, const std::vector<FacePlane>& planes, const std::vector<double>& offsets, const std::string& tag, bool* empty = nullptr)
{
    if (empty != nullptr) {
        *empty = false;
    }
    Bnd_Box box;
    BRepBndLib::Add(body, box);
    if (box.IsVoid()) {
        return Shape();
    }
    const gp_Pnt centre(0.5 * (box.CornerMin().XYZ() + box.CornerMax().XYZ()));
    const double size = std::sqrt(box.SquareExtent());
    const double scale = size > 0.0 && size < OFFSET_REFERENCE_SIZE ? OFFSET_REFERENCE_SIZE / size : 1.0;
    double farthest = 0.0;
    std::vector<FacePlane> scaled;
    std::vector<double> moved_by;
    for (size_t i = 0; i < planes.size() && i < offsets.size(); ++i) {
        scaled.push_back({gp_Pnt(centre.XYZ() + scale * (planes[i].p.XYZ() - centre.XYZ())), planes[i].n});
        moved_by.push_back(offsets[i] * scale);
        if (!std::isnan(offsets[i])) {
            farthest = std::max(farthest, std::abs(offsets[i]));
        }
    }
    try {
        bool nothing = false;
        const auto started = std::chrono::steady_clock::now();
        TopoDS_Shape region = half_space_region(scaled, moved_by, centre, scale * (size + farthest), &nothing);
        if (nothing) {
            if (empty != nullptr) {
                *empty = true;
            }
            return Shape();
        }
        // (Again only when the first try gave up quickly: one that ran out of time would again.)
        if (region.IsNull() && std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count() < 0.25 * g_time_limit) {
            // (OCCT's common can fail on one order of the boxes and size of them and not another.)
            std::reverse(scaled.begin(), scaled.end());
            std::reverse(moved_by.begin(), moved_by.end());
            region = half_space_region(scaled, moved_by, centre, 1.37 * scale * (size + farthest));
        }
        if (region.IsNull()) {
            return Shape();
        }
        if (scale != 1.0) {
            gp_Trsf back;
            back.SetScale(centre, 1.0 / scale);
            region = BRepBuilderAPI_Transform(region, back, true).Shape();
        }
        Shape out = CadShape::wrap(region);
        naming::name_result(*out.ptr(), nullptr, {}, tag);
        return out;
    }
    catch (const Standard_Failure&) {
        return Shape();
    }
}

/// The shell of a convex body of flat faces (convex_planes) with the open faces (0-based) left
/// open, its walls thickness thick in, out or both ways (half each), made exactly from the moved
/// planes (convex_region) instead of OCCT's thick solid, which gets it wrong where a face shrinks
/// away in the wall (a chamfered box: walls with slivers of material in the hollow) or two open
/// faces meet. In: the body less the solid behind every kept face's plane a wall in (so it runs out
/// through the openings); out: the solid behind every kept face's plane a wall out and the open
/// faces' own, less the body; both: the body grown by half the wall less the solid behind the
/// kept faces' planes half a wall in. Checked (one closed solid, holding less than the body when
/// in, its faces and mesh agreeing: made_consistency_problem). Null when the body isn't such a one
/// (error left empty) or the shell can't be made so (error saying why).
Shape convex_shell(const Shape& shape, const PackedInt32Array& open, double thickness, const String& direction, const std::string& tag, String& error)
{
    const TopoDS_Shape& body = shape->get_occ_shape();
    const std::vector<FacePlane> planes = convex_planes(body);
    if (planes.empty() || !(thickness > 0.0)) {
        return Shape();
    }
    std::vector<bool> is_open(planes.size(), false);
    for (int64_t i = 0; i < open.size(); ++i) {
        if (open[i] >= 0 && size_t(open[i]) < planes.size()) {
            is_open[size_t(open[i])] = true;
        }
    }
    if (std::none_of(is_open.begin(), is_open.end(), [](bool b) { return b; }) || std::all_of(is_open.begin(), is_open.end(), [](bool b) { return b; })) {
        return Shape();
    }
    const double none = std::numeric_limits<double>::quiet_NaN();
    const bool out_only = direction == "outside";
    const bool both = direction == "both";
    std::vector<double> outer(planes.size()), inner(planes.size());
    for (size_t i = 0; i < planes.size(); ++i) {
        outer[i] = both ? 0.5 * thickness : is_open[i] ? 0.0 : thickness;
        inner[i] = is_open[i] ? none : both ? -0.5 * thickness : -thickness;
    }
    const std::string prefix = "The shell with an opening could not be built at that thickness: ";
    Shape grown = shape;
    if (out_only || both) {
        grown = convex_region(body, planes, outer, tag + ":outer");
        if (!usable(grown)) {
            error = String::utf8((prefix + "its outer wall could not be made").c_str());
            return Shape();
        }
    }
    String why;
    Shape made;
    if (out_only) {
        made = boolean(grown, shape, 1, tag, why);
    }
    else {
        bool nothing = false;
        const Shape hollow = convex_region(body, planes, inner, tag + ":inner", &nothing);
        if (!usable(hollow)) {
            error = String::utf8((prefix + (nothing || half_spaces_meet(body, planes, inner) == 0
                                                ? "its walls would fill the whole body (the wall is thicker than half the body allows); try a thinner wall"
                                                : "the geometry kernel could not make its hollow (the solid behind its kept faces moved in by the wall), "
                                                  "though the walls leave room for one; try a slightly different thickness"))
                                       .c_str());
            return Shape();
        }
        made = boolean(grown, hollow, 1, tag, why);
    }
    if (!usable(made)) {
        // (The boolean's own advice is for shapes the user placed; these are the shell's walls.)
        error = String::utf8((prefix + (why.begins_with("The cut took too long") ? std::string("cutting its hollow out took too long; try another thickness")
                                                                                 : std::string(out_only ? "the geometry kernel could not cut the body out of its outer wall; try a slightly different thickness"
                                                                                                        : "the geometry kernel could not cut its hollow out of the body; try a slightly different thickness")))
                                 .c_str());
        return Shape();
    }
    const TopoDS_Shape& result = made->get_occ_shape();
    const double v = measure::volume(result).Mass();
    const double v_body = measure::volume(body).Mass();
    if (map_of(result, TopAbs_SOLID).Extent() != 1 || !shells_closed(result) || !(v > 1e-9 * v_body) ||
        (!out_only && !both && !(v < v_body * (1.0 - 1e-9)))) {
        error = String::utf8((prefix + "it did not come out as one closed body with its walls").c_str());
        return Shape();
    }
    const std::string wrong = made_consistency_problem(result, thickness);
    if (!wrong.empty()) {
        error = String::utf8((prefix + wrong).c_str());
        return Shape();
    }
    return made;
}

/// Why points of a wall made thickness off a surface (from, its meshed faces) aren't where they
/// should be, or "": every point must lie HOLLOW_NEAR to far thicknesses from from, and, when side
/// is given (the closed body, meshed), inside it (want_inside) or outside it, except points within
/// a twentieth of the thickness of side's surface (where a wall meets an opening). subject names
/// the wall in the sentence ("its inner wall").
std::string wall_points_problem(const SurfaceMesh& from, const SurfaceMesh* side, bool want_inside, const std::vector<gp_Pnt>& points, double thickness,
                                double far, double deflection, const std::string& subject)
{
    if (points.empty()) {
        return subject + " could not be meshed for the check";
    }
    const double reach = far * thickness + 2.0 * deflection;
    double nearest = std::numeric_limits<double>::infinity();
    size_t nearest_at = 0;
    double farthest = 0.0;
    size_t farthest_at = 0;
    size_t wrong_side = 0;
    size_t wrong_side_at = 0;
    for (size_t i = 0; i < points.size(); ++i) {
        const double d = from.distance(points[i], reach);
        if (d < nearest) {
            nearest = d;
            nearest_at = i;
        }
        if (d > farthest) {
            farthest = d;
            farthest_at = i;
        }
        if (side != nullptr && side->distance(points[i], 0.05 * thickness) >= 0.05 * thickness && side->inside(points[i]) != want_inside &&
            wrong_side++ == 0) {
            wrong_side_at = i;
        }
    }
    if (wrong_side > 0) {
        return subject + (want_inside ? " would come out through the outside at " : " would come inside the body at ") + where_mm(points[wrong_side_at]) +
               " (" + std::to_string(wrong_side) + " of the " + std::to_string(points.size()) + " points checked on it)";
    }
    if (nearest < HOLLOW_NEAR * thickness) {
        return subject + " would come within " + mm(nearest) + " of the outside at " + where_mm(points[nearest_at]) + " instead of " + mm(thickness) +
               " (the body is too thin or bends too tightly there for that wall)";
    }
    if (farthest >= reach * (1.0 - 1e-9)) {
        return subject + " would lie more than " + mm(farthest) + " from the outside at " + where_mm(points[farthest_at]) + ", farther than the " +
               mm(thickness) + " wall (the offset came out wrong)";
    }
    return "";
}

/// Why made, OCCT's offset of body by distance, isn't one, or "": every point of it, sampled
/// densely, must lie the distance from body (HOLLOW_NEAR to far of it), on the right side of a
/// closed body. OCCT's offset can come back as a body of the right kind with faces only half the
/// distance off (a box with 1 mm rounds offset in by 2 mm).
std::string offset_points_problem(const TopoDS_Shape& body, const TopoDS_Shape& made, double distance, double far, const std::string& subject)
{
    const double t = std::abs(distance);
    if (!(t > 0.0)) {
        return "";
    }
    const double deflection = std::max(0.01 * t, 5e-6 * diagonal(body));
    const double seconds = std::min(5.0, g_time_limit);
    const TopoDS_Shape body_meshed = meshed_copy(body, deflection, seconds, true);
    const TopoDS_Shape made_meshed = meshed_copy(made, deflection, seconds);
    if (body_meshed.IsNull() || made_meshed.IsNull()) {
        return subject + " took too long to mesh for the check";
    }
    SurfaceMesh from;
    from.add(body_meshed);
    from.build();
    const double area = meshed_area(made_meshed);
    if (from.triangles.empty() || area < 0.0) {
        return subject + " could not be meshed for the check";
    }
    const double spacing = std::max(0.5 * t, std::sqrt(area / 300000.0));
    std::vector<gp_Pnt> points;
    for (TopExp_Explorer it(made_meshed, TopAbs_FACE); it.More(); it.Next()) {
        sample_face(TopoDS::Face(it.Current()), spacing, points);
    }
    const bool closed = map_of(body, TopAbs_SOLID).Extent() > 0 && shells_closed(body);
    return wall_points_problem(from, closed ? &from : nullptr, distance < 0.0, points, t, far, deflection, subject);
}

/// Why made, OCCT's thick solid of base with the faces open taken out and its walls offset by
/// offset (in when negative, sharp joins), isn't that shell, or "". OCCT checks no more than that
/// it has more faces and (in) less volume, and passes walls that come within a third of the
/// thickness of the outside, walls inside out and openings closed over (a box with every edge
/// chamfered, its top open: a body of 0.4 mm3, or the whole body less a sliver). So, densely as
/// for a closed hollow: it must be one closed solid holding more than nothing; every face of it
/// that isn't on the body's own faces (kept) nor across an opening (a rim: on an open face, or
/// its plane) is a wall, every point of which lies a thickness (to HOLLOW_SHARP_FAR of it at the
/// sharp inside corners) from the kept faces, on the side it was offset to; and every point of a
/// rim lies within that of the kept faces too, so an opening isn't closed over.
std::string open_shell_problem(const TopoDS_Shape& base, const std::vector<TopoDS_Face>& open, const TopoDS_Shape& made, double offset)
{
    const double t = std::abs(offset);
    if (made.IsNull() || map_of(made, TopAbs_SOLID).Extent() != 1 || !shells_closed(made)) {
        return "it did not come out as one closed body";
    }
    const double v_base = measure::volume(base).Mass();
    const double v = measure::volume(made).Mass();
    if (!(v > 1e-9 * std::abs(v_base))) {
        return v < 0.0 ? "it came out inside out" : "it came out with no volume";
    }
    std::vector<TopoDS_Face> kept;
    for (TopExp_Explorer it(base, TopAbs_FACE); it.More(); it.Next()) {
        const TopoDS_Face& face = TopoDS::Face(it.Current());
        if (std::none_of(open.begin(), open.end(), [&](const TopoDS_Face& o) { return o.IsSame(face); })) {
            kept.push_back(face);
        }
    }
    const double deflection = std::max(0.01 * t, 5e-6 * diagonal(base));
    const double seconds = std::min(5.0, g_time_limit);
    const TopoDS_Shape kept_meshed = meshed_copy(compound_of(kept), deflection, seconds, true);
    const TopoDS_Shape open_meshed = meshed_copy(compound_of(open), deflection, seconds, true);
    const TopoDS_Shape base_meshed = meshed_copy(base, deflection, seconds, true);
    const TopoDS_Shape made_meshed = meshed_copy(made, deflection, seconds);
    if (kept_meshed.IsNull() || open_meshed.IsNull() || base_meshed.IsNull() || made_meshed.IsNull()) {
        return "it took too long to mesh for the check of its walls";
    }
    SurfaceMesh from, opening, body;
    from.add(kept_meshed);
    from.build();
    opening.add(open_meshed);
    opening.build();
    body.add(base_meshed);
    body.build();
    const double area = meshed_area(made_meshed);
    if (from.triangles.empty() || opening.triangles.empty() || body.triangles.empty() || area < 0.0) {
        return "it could not be meshed for the check of its walls";
    }
    const double spacing = std::max(0.5 * t, std::sqrt(area / 300000.0));
    const double on = 0.02 * t + 2.0 * deflection;
    std::vector<gp_Pnt> wall, rim;
    for (TopExp_Explorer it(made_meshed, TopAbs_FACE); it.More(); it.Next()) {
        const TopoDS_Face& face = TopoDS::Face(it.Current());
        TopLoc_Location location;
        const Handle(Poly_Triangulation) mesh = BRep_Tool::Triangulation(face, location);
        if (mesh.IsNull()) {
            return "it could not be meshed for the check of its walls";
        }
        // A face of the body's own (every node on a kept face), or of a rim (every node on an
        // open face, or on the plane of a flat one, which a rim outward lies on past it).
        bool on_kept = true;
        bool on_open = true;
        for (int n = 1; n <= mesh->NbNodes() && (on_kept || on_open); ++n) {
            const gp_Pnt p = mesh->Node(n).Transformed(location.Transformation());
            on_kept = on_kept && from.distance(p, on) < on;
            if (on_open) {
                bool near_open = opening.distance(p, on) < on;
                for (size_t k = 0; k < open.size() && !near_open; ++k) {
                    const BRepAdaptor_Surface o(open[k], false);
                    near_open = o.GetType() == GeomAbs_Plane && o.Plane().Distance(p) < on;
                }
                on_open = near_open;
            }
        }
        if (on_kept) {
            continue;
        }
        sample_face(face, spacing, on_open ? rim : wall, on_open);
    }
    const std::string subject = offset < 0.0 ? "its inner wall" : "its outer wall";
    if (wall.empty()) {
        return subject + " was not found (it came out as the body)";
    }
    const std::string problem = wall_points_problem(from, &body, offset < 0.0, wall, t, HOLLOW_SHARP_FAR, deflection, subject);
    if (!problem.empty()) {
        return problem;
    }
    const double reach = HOLLOW_SHARP_FAR * t + 2.0 * deflection;
    for (const gp_Pnt& p : rim) {
        if (from.distance(p, reach) >= reach * (1.0 - 1e-9)) {
            return "an opening would be closed over at " + where_mm(p) + " (the offset came out wrong)";
        }
    }
    return "";
}

/// Refusals of closed hollow shells already given, by body and thickness, so a rebuild that asks
/// again gets the same answer at once instead of the same seconds of trying (the body is kept
/// here, so another body can't come to look the same).
struct ShellRefusal
{
    TopoDS_Shape body;
    double thickness = 0.0;
    double limit = 0.0;
    String error;
};

std::mutex g_shell_refusals_lock;
std::vector<ShellRefusal> g_shell_refusals;
constexpr size_t SHELL_REFUSALS_KEPT = 16;

bool known_shell_refusal(const TopoDS_Shape& body, double thickness, String& error)
{
    std::lock_guard<std::mutex> held(g_shell_refusals_lock);
    for (const ShellRefusal& r : g_shell_refusals) {
        if (r.body.IsEqual(body) && r.thickness == thickness && r.limit == g_time_limit) {
            error = r.error;
            return true;
        }
    }
    return false;
}

void remember_shell_refusal(const TopoDS_Shape& body, double thickness, const String& error)
{
    std::lock_guard<std::mutex> held(g_shell_refusals_lock);
    if (g_shell_refusals.size() >= SHELL_REFUSALS_KEPT) {
        g_shell_refusals.erase(g_shell_refusals.begin());
    }
    g_shell_refusals.push_back({body, thickness, g_time_limit, error});
}

/// A closed body hollowed by its inward offset inner (thickness in), built straight from the two
/// walls: the body's own shell and the offset's shell turned inside out, in one solid. That is
/// what cutting inner from the body gives when the walls don't meet, and OCCT's boolean takes
/// seconds to minutes to find that out on spline bodies (a 5 mm converted form box: 184 s; an
/// 800 mm one: 5 s; a kernel sphere: 4 ms). The caller has checked the inner wall against the
/// outside already (hollow_wall_problem: every point about the thickness in, inside, facing
/// out), which a mesh proximity test of the two walls can't do (it passed walls a quarter of the
/// thickness apart, and failed sound ones); here the inner wall must not run through itself (on
/// a mesh within a tenth of the thickness: fatal set, since cutting it out can't be right either)
/// and the two walls must make one solid holding the body less the inner wall. Null with why set
/// when they don't (the caller then cuts the inner wall out, unless fatal).
Shape hollow_directly(const Shape& body, const Shape& inner, double thickness, const std::string& tag, std::string& why, bool& fatal,
                      double known_inner_volume = std::numeric_limits<double>::quiet_NaN())
{
    fatal = false;
    const TopoDS_Shape& outer_shape = body->get_occ_shape();
    if (map_of(outer_shape, TopAbs_SOLID).Extent() != 1 || map_of(inner->get_occ_shape(), TopAbs_SOLID).Extent() > 1) {
        why = "not one solid";
        return Shape();
    }
    const TopoDS_Shell outer = only_shell(outer_shape);
    const TopoDS_Shell wall = only_shell(inner->get_occ_shape());
    if (outer.IsNull() || wall.IsNull() || !shells_closed(outer) || !shells_closed(wall)) {
        why = "the walls aren't single closed shells";
        return Shape();
    }
    const double v_out = measure::volume(solid_of(outer)).Mass();
    const double v_in = std::isnan(known_inner_volume) ? measure::volume(solid_of(wall)).Mass() : known_inner_volume;
    // An offset solid's shell faces outward: one that came back facing in is wrong.
    if (!(v_in > 0.0) || !(v_out > 0.0) || !(v_in < v_out)) {
        why = !(v_in > 0.0) ? "the inner wall came out inside out" : "the inner wall holds no less than the body";
        fatal = true;
        return Shape();
    }
    {
        // (On a copy, so the inner wall keeps no fine mesh.)
        const TopoDS_Shape meshed = meshed_copy(wall, std::max(0.1 * thickness, 1e-5 * diagonal(outer_shape)), std::min(5.0, g_time_limit));
        if (meshed.IsNull()) {
            why = "the inner wall took too long to mesh for the check";
            return Shape();
        }
        BRepExtrema_SelfIntersection self(meshed, 0.0);
        self.Perform();
        if (!self.IsDone()) {
            why = "the inner wall could not be checked for running through itself";
            return Shape();
        }
        // Triangles of faces that meet (at an edge or a corner) touch there, at a node both
        // have: triangles of two faces that cross each other with no node in common are a wall
        // running through itself. (By the triangles, not by whether their faces share an edge or
        // corner: OCCT's offset of the same converted body comes out with its faces in another
        // order from one run to the next, and round a converted sphere's poles faces that share
        // a corner in one run don't in the next, which made the same wall pass or fail by turns.)
        // Fixed-radius and flat faces that meet are let be: their offsets are exact, and where
        // a round meets a flat face tangent, their meshes graze each other along it.
        const Handle(BRepExtrema_TriangleSet)& triangles = self.ElementSet();
        std::map<int, TopTools_IndexedMapOfShape> corners;
        auto corners_of = [&](int id) -> const TopTools_IndexedMapOfShape& {
            auto found = corners.find(id);
            if (found == corners.end()) {
                found = corners.emplace(id, TopTools_IndexedMapOfShape()).first;
                TopExp::MapShapes(self.GetSubShape(id), TopAbs_VERTEX, found->second);
            }
            return found->second;
        };
        auto exact_kind = [&](int id) {
            const GeomAbs_SurfaceType kind = BRepAdaptor_Surface(TopoDS::Face(self.GetSubShape(id)), false).GetType();
            return kind == GeomAbs_Plane || kind == GeomAbs_Cylinder || kind == GeomAbs_Sphere || kind == GeomAbs_Torus || kind == GeomAbs_Cone;
        };
        auto exact_and_meet = [&](int a, int b) {
            if (!exact_kind(a) || !exact_kind(b)) {
                return false;
            }
            const TopTools_IndexedMapOfShape& ca = corners_of(a);
            const TopTools_IndexedMapOfShape& cb = corners_of(b);
            for (int k = 1; k <= ca.Extent(); ++k) {
                if (cb.Contains(ca(k))) {
                    return true;
                }
            }
            return false;
        };
        const double same = 1e-6 * thickness;
        auto share_a_node = [&](int i, int j) {
            BVH_Vec3d p[3], q[3];
            triangles->GetVertices(i, p[0], p[1], p[2]);
            triangles->GetVertices(j, q[0], q[1], q[2]);
            for (const BVH_Vec3d& u : p) {
                for (const BVH_Vec3d& w : q) {
                    if ((u - w).Modulus() <= same) {
                        return true;
                    }
                }
            }
            return false;
        };
        // Two faces' crossing triangles are checked on the faces themselves: their section must
        // run off their shared edges and corners (meshes of faces that meet tangent, a corner
        // blend's and the rounds beside it, graze each other along the edge, as the flat and
        // round ones above do: a filleted L's sound inner wall was refused for it, at one
        // placement of the body and not another). Unchecked in time, a crossing counts.
        const auto check_start = std::chrono::steady_clock::now();
        const double check_seconds = std::min(3.0, 0.25 * g_time_limit);
        std::map<std::pair<int, int>, bool> checked;
        auto faces_cross = [&](int a, int b) {
            const std::pair<int, int> key = std::minmax(a, b);
            const auto found = checked.find(key);
            if (found != checked.end()) {
                return found->second;
            }
            bool crosses = true;
            const double left = check_seconds - std::chrono::duration<double>(std::chrono::steady_clock::now() - check_start).count();
            if (left > 0.0) {
                try {
                    const TopoDS_Face& fa = TopoDS::Face(self.GetSubShape(a));
                    const TopoDS_Face& fb = TopoDS::Face(self.GetSubShape(b));
                    TopTools_IndexedMapOfShape edges_b, corners_b;
                    TopExp::MapShapes(fb, TopAbs_EDGE, edges_b);
                    TopExp::MapShapes(fb, TopAbs_VERTEX, corners_b);
                    std::vector<TopoDS_Shape> shared;
                    for (TopExp_Explorer e(fa, TopAbs_EDGE); e.More(); e.Next()) {
                        if (edges_b.Contains(e.Current())) {
                            shared.push_back(e.Current());
                        }
                    }
                    for (TopExp_Explorer v(fa, TopAbs_VERTEX); v.More(); v.Next()) {
                        if (corners_b.Contains(v.Current())) {
                            shared.push_back(v.Current());
                        }
                    }
                    BRepAlgoAPI_Section section(fa, fb, false);
                    const Handle(Deadline) clock = new Deadline(left);
                    section.Build(clock->Start());
                    if (!clock->expired() && section.IsDone() && !section.HasErrors()) {
                        // (Every point of the section within a twentieth of the wall of where the
                        // faces meet: they only touch there.)
                        const TopoDS_Shape boundary = make_compound(shared);
                        const double near = 0.05 * thickness;
                        auto on_boundary = [&](const gp_Pnt& q) {
                            if (shared.empty()) {
                                return false;
                            }
                            BRepExtrema_DistShapeShape d(BRepBuilderAPI_MakeVertex(q).Vertex(), boundary);
                            return d.IsDone() && d.Value() <= near;
                        };
                        crosses = false;
                        for (TopExp_Explorer e(section.Shape(), TopAbs_EDGE); e.More() && !crosses; e.Next()) {
                            BRepAdaptor_Curve curve(TopoDS::Edge(e.Current()));
                            for (int k = 0; k <= 4 && !crosses; ++k) {
                                crosses = !on_boundary(curve.Value(curve.FirstParameter() + (curve.LastParameter() - curve.FirstParameter()) * k / 4.0));
                            }
                        }
                        for (TopExp_Explorer v(section.Shape(), TopAbs_VERTEX); v.More() && !crosses; v.Next()) {
                            crosses = !on_boundary(BRep_Tool::Pnt(TopoDS::Vertex(v.Current())));
                        }
                    }
                }
                catch (const Standard_Failure&) {
                    crosses = true;
                }
            }
            checked[key] = crosses;
            return crosses;
        };
        gp_Pnt crossing;
        for (NCollection_DataMap<int, TColStd_PackedMapOfInteger>::Iterator it(self.OverlapElements()); it.More() && !fatal; it.Next()) {
            const int a = triangles->GetFaceID(it.Key());
            for (TColStd_PackedMapOfInteger::Iterator other(it.Value()); other.More(); other.Next()) {
                const int b = triangles->GetFaceID(other.Key());
                if (a == b || share_a_node(it.Key(), other.Key()) || exact_and_meet(a, b) || !faces_cross(a, b)) {
                    continue;
                }
                BVH_Vec3d p1, p2, p3;
                triangles->GetVertices(it.Key(), p1, p2, p3);
                crossing = gp_Pnt((p1.x() + p2.x() + p3.x()) / 3.0, (p1.y() + p2.y() + p3.y()) / 3.0, (p1.z() + p2.z() + p3.z()) / 3.0);
                fatal = true;
                break;
            }
        }
        if (fatal) {
            why = "the inner wall the geometry kernel made (the body's offset in by the wall) runs through itself at " + where_mm(crossing);
            return Shape();
        }
    }
    BRep_Builder builder;
    TopoDS_Solid solid;
    builder.MakeSolid(solid);
    builder.Add(solid, outer);
    builder.Add(solid, TopoDS::Shell(wall.Reversed()));
    const double v = measure::volume(solid).Mass();
    if (std::abs(v - (v_out - v_in)) > 1e-6 * v_out) {
        why = "the hollow body's volume came out wrong";
        return Shape();
    }
    Shape out = CadShape::wrap(solid);
    // Both walls' faces are kept as they are, names and all.
    naming::name_result(*out.ptr(), nullptr, {body.ptr(), inner.ptr()}, tag);
    return out;
}

/// The faces of body (1-based indices) narrower than HOLLOW_NARROW walls of thickness (by twice
/// their area over their boundary's length, which a strip's width is), unless that is all of
/// them: the chamfers and small corner faces a wall in from the body closes up.
std::vector<int> narrow_faces(const Shape& body, double thickness)
{
    const TopTools_IndexedMapOfShape faces = map_of(body->get_occ_shape(), TopAbs_FACE);
    std::vector<int> narrow;
    for (int i = 1; i <= faces.Extent(); ++i) {
        GProp_GProps area;
        BRepGProp::SurfaceProperties(faces(i), area);
        GProp_GProps length;
        BRepGProp::LinearProperties(faces(i), length);
        if (length.Mass() > 0.0 && 2.0 * area.Mass() / length.Mass() < HOLLOW_NARROW * thickness) {
            narrow.push_back(i);
        }
    }
    if (int(narrow.size()) == faces.Extent()) {
        narrow.clear();
    }
    return narrow;
}

/// A copy of body with the faces listed (1-based indices) taken out and their neighbours grown
/// over the gaps (OCCT's defeaturing, which is meant for taking off rounds), names carried over;
/// null when that can't be done in a few seconds or doesn't give one closed solid.
Shape without_faces(const Shape& body, const std::vector<int>& faces, const std::string& tag)
{
    const TopTools_IndexedMapOfShape all = map_of(body->get_occ_shape(), TopAbs_FACE);
    BRepAlgoAPI_Defeaturing remover;
    remover.SetShape(body->get_occ_shape());
    for (const int i : faces) {
        if (i >= 1 && i <= all.Extent()) {
            remover.AddFaceToRemove(all(i));
        }
    }
    remover.SetToFillHistory(true);
    const Handle(Deadline) clock = new Deadline(std::min(5.0, g_time_limit));
    remover.Build(clock->Start());
    if (clock->expired() || !remover.IsDone() || remover.HasWarnings() || remover.Shape().IsNull() || map_of(remover.Shape(), TopAbs_SOLID).Extent() != 1 ||
        !shells_closed(remover.Shape()) || !(measure::volume(remover.Shape()).Mass() > 0.0)) {
        return Shape();
    }
    Shape out = CadShape::wrap(remover.Shape());
    naming::name_result(*out.ptr(), &remover, {body.ptr()}, tag);
    return out;
}

/// A closed body hollowed with a wall of thickness (a shell without open faces), checked: either
/// every point of its inner wall lies about the thickness from the outside (hollow_wall_problem)
/// or it is refused, error saying why and where. Impossible walls (thicker than half the body, or
/// than its curves) are refused from the body's mesh before any offset (hollow_upfront_problem),
/// in well under a second; an offset that fails its check is never cut out (cutting a wrong wall
/// out only gives a wrong body, slowly). Where the only curves tighter than the wall are rounds
/// of a fixed radius (the kernel's fillets), the inner wall is the offset of the body without
/// them: the wall in from a convex round of a radius under the wall is the wall in from the sharp
/// corner it rounds (a filleted box's inner wall is a sharp box), checked against the body itself.
Shape hollow_closed_as_is(const Shape& shape, double thickness, const std::string& tag, String& error, bool splines = false)
{
    const TopoDS_Shape& body = shape->get_occ_shape();
    const double size = diagonal(body);
    // (A hundredth of the thickness: the distances on the mesh are that close to the faces'.)
    const double deflection = std::max(0.01 * thickness, 5e-6 * size);
    const double mesh_seconds = std::min(5.0, g_time_limit);
    // (The time limit is the whole call's: meshing the body for the checks counts too.)
    const auto started = std::chrono::steady_clock::now();
    auto refuse = [&](const std::string& why) {
        error = String::utf8(("The shell could not be built: " + why).c_str());
        return Shape();
    };
    const TopoDS_Shape outer_meshed = meshed_copy(body, deflection, mesh_seconds);
    if (outer_meshed.IsNull()) {
        return refuse("the body took too long to mesh for the check of its walls; try a thicker wall");
    }
    SurfaceMesh outer;
    outer.add(outer_meshed);
    outer.build();
    if (outer.triangles.empty()) {
        return refuse("the body could not be meshed for the check of its walls");
    }
    const HollowUpfront upfront = hollow_upfront_problem(outer, outer_meshed, thickness, deflection);
    // A fold only at fixed-radius rounds: the wall in from the body without them, at once.
    const bool rounds_first = !upfront.problem.empty();
    if (rounds_first && !upfront.tight_only) {
        return refuse(upfront.problem);
    }
    // A wall about half the body's thickness or more (but not surely more, which the check
    // above refuses) leaves the offset nothing or less to make: what goes wrong then says so.
    // (The mesh's two deflections on the side of saying so: thinnest is infinite past that.)
    const bool near_half = upfront.thinnest < 2.0 * thickness / HOLLOW_NEAR + 2.0 * deflection;
    auto refuse_offset = [&](const std::string& why) {
        if (rounds_first || why.empty()) {
            return refuse(upfront.problem.empty() ? std::string("its inner wall (the body's offset in by the wall) could not be made; try a thinner wall") : upfront.problem);
        }
        if (near_half) {
            return refuse("the wall is about as thick as the body allows at " + where_mm(upfront.thinnest_at) + ", where the body is only about " + mm(upfront.thinnest) +
                          " thick (a hollow body's walls take twice the wall thickness, and " + why + "); try a wall under " + mm(0.5 * HOLLOW_NEAR * upfront.thinnest));
        }
        if (why == NO_INNER_WALL && !std::isfinite(upfront.thinnest)) {
            // (No inward ray met the far side within a little more than two walls (thinnest
            // stays infinite) and the body bends no tighter than the wall: OCCT's offset fails on it, at this wall and the
            // retries around it. It does on a sphere cut by flat faces whose circles cross the
            // sphere's seam, at every wall.)
            return refuse(why + " by the geometry kernel at that wall or a hair from it, although the body is more than twice the wall thick everywhere "
                                "(it fails like this on some bodies at every wall, a sphere cut by flat faces among them, and on others only at some "
                                "walls, so another thickness may or may not work)");
        }
        return refuse(why + "; try another thickness");
    };
    // The wall in from the body as it is; when OCCT's offset of that fails or comes out wrong (it
    // does on a box with a slot through it at some walls and not others, its walls at the slot's
    // ends running out to the outside), the same at a hair thicker wall or on copies two and four
    // times the size or half of it; when the body has rounds of about the wall's radius or less (a round of just the
    // wall's radius offsets to nothing), from the body without them; and when it has faces narrow
    // enough for the wall in to close them up (a 1 mm chamfer at a 2 mm wall), from the body
    // without those. Every one is checked against the body itself, so a try that leaves out
    // what it shouldn't is refused like any other wrong wall.
    struct Try
    {
        int base;  // 0 the body, 1 without its tight rounds, 2 without its narrow faces, 3 exact (convex, flat faces)
        double factor;  // scaled up by this for the offset
        double stretch;  // the offset's distance, of the wall
    };
    // A convex body of flat faces has its inner wall exact (convex_region), tried first: OCCT's
    // offset of it keeps the body's corners where a face shrinks away in the wall (a chamfered
    // box's corner faces) or where the faces round a corner, moved in, no longer meet in one point
    // (a ball of flat triangles: every corner), and comes out with faces that don't meet, a wall
    // 1 to 2 % too thick in all, and not the same from one run to the next.
    const std::vector<FacePlane> planes = convex_planes(body);
    // (Such a body's shell takes about five times as long in all as it has taken to get here,
    // meshing the body for the checks: 1 s of 6 for a ball of 5,000 flat triangles, 5.4 s of 30
    // for one of 20,000. Past a fifth of the time limit here it won't fit, and it is told now
    // instead of after the other four fifths.)
    if (!planes.empty() && std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count() > 0.2 * g_time_limit) {
        error = too_long_ahead("shell", std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count());
        return Shape();
    }
    std::vector<Try> tries;
    if (!rounds_first) {
        if (!planes.empty()) {
            tries.push_back({3, 1.0, 1.0});
        }
        tries.push_back({0, 1.0, 1.0});
        tries.push_back({0, 1.0, 1.0 + HOLLOW_STRETCH});
        tries.push_back({0, 2.0, 1.0});
        tries.push_back({0, 4.0, 1.0});
        tries.push_back({0, 2.0, 1.0 + HOLLOW_STRETCH});
        tries.push_back({0, 0.5, 1.0});
    }
    tries.push_back({1, 1.0, 1.0});
    tries.push_back({1, 1.0, 1.0 + HOLLOW_STRETCH});
    tries.push_back({2, 1.0, 1.0});
    tries.push_back({2, 1.0, 1.0 + HOLLOW_STRETCH});
    Shape bases[4] = {shape, Shape(), Shape(), shape};
    bool base_tried[4] = {true, false, false, true};
    std::string why;
    std::string first_wrong;
    bool retry_only_built = false;
    for (const Try& attempt : tries) {
        if (!base_tried[attempt.base]) {
            base_tried[attempt.base] = true;
            if (attempt.base == 1 && !upfront.tight.empty()) {
                bases[1] = without_faces(shape, upfront.tight, tag + ":sharp");
            }
            else if (attempt.base == 2) {
                const std::vector<int> narrow = narrow_faces(shape, thickness);
                if (!narrow.empty()) {
                    bases[2] = without_faces(shape, narrow, tag + ":sharp");
                }
            }
        }
        const Shape& base = bases[attempt.base];
        if (!usable(base)) {
            continue;
        }
        // (The first try always runs, with what is left of the time limit; the others only while
        // half of it is left, and within that.)
        const bool first = &attempt == &tries.front();
        const double left = g_time_limit - std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count();
        if (!first && left < 0.5 * g_time_limit) {
            break;
        }
        if (!first && retry_only_built && attempt.base == 0) {
            continue;
        }
        bool stopped = false;
        String offset_error;
        double touches = std::numeric_limits<double>::infinity();
        Shape candidate;
        if (attempt.base == 3) {
            candidate = convex_region(body, planes, std::vector<double>(planes.size(), -thickness), tag + ":inner");
        }
        else {
            candidate = offset_whole(base, -thickness * attempt.stretch, attempt.factor, tag + ":inner", offset_error, stopped, std::max(left, 1.0));
        }
        // (What follows, the checks of the wall and putting the two walls together, takes about a
        // third as long again as it took to get here: past three quarters of the time limit it
        // isn't started. A ball of 20,000 flat triangles got its exact inner wall after 16 s and
        // was handed back after 30.)
        if (std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count() > 0.75 * g_time_limit) {
            error = too_long_ahead("shell", std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count());
            return Shape();
        }
        if (splines && usable(candidate) && attempt.factor == 1.0 && attempt.base != 3) {
            // (On a small body's scaled copy: its offset faces made splines now, as scaling back
            // does, since meshing them for the check crawls otherwise; a converted 0.5 mm sphere's
            // inner wall took 8 s instead of 1.)
            candidate = scaled_back(candidate, gp_Trsf());
        }
        if (stopped) {
            if (!first && !first_wrong.empty()) {
                break;
            }
            error = too_long("shell");
            return Shape();
        }
        std::string wrong;
        double inner_volume = std::numeric_limits<double>::quiet_NaN();
        if (!usable(candidate)) {
            wrong = NO_INNER_WALL;
        }
        else {
            // Its edges must end at its corners first, and once its walls pass, its faces must hold
            // what its mesh does (made_consistency_problem, on the mesh made for the check; the
            // body's own being what it is): the check measures the mesh, which comes out right
            // where OCCT kept corners the wall needed replaced.
            const std::string gap = edge_gap_problem(candidate->get_occ_shape(), thickness);
            if (!gap.empty()) {
                wrong = "its inner wall came out wrong: " + gap;
            }
            else {
                const TopoDS_Shape inner_meshed = meshed_copy(candidate->get_occ_shape(), deflection, mesh_seconds);
                if (inner_meshed.IsNull()) {
                    return refuse("its inner wall took too long to mesh for the check; try a thicker wall");
                }
                wrong = hollow_wall_problem(outer, candidate->get_occ_shape(), inner_meshed, thickness, deflection, HOLLOW_FAR, &touches);
                if (wrong.empty()) {
                    const TopoDS_Shell inner_shell = only_shell(candidate->get_occ_shape());
                    inner_volume = measure::volume(inner_shell.IsNull() ? candidate->get_occ_shape() : TopoDS_Shape(solid_of(inner_shell))).Mass();
                    const std::string inconsistent = mesh_volume_problem(candidate->get_occ_shape(), inner_meshed, thickness, deflection, inner_volume);
                    if (!inconsistent.empty()) {
                        wrong = "its inner wall came out wrong: " + inconsistent;
                    }
                }
            }
        }
        if (wrong.empty() && std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count() > 0.75 * g_time_limit) {
            error = too_long_ahead("shell", std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count());
            return Shape();
        }
        if (wrong.empty()) {
            bool fatal = false;
            Shape hollow = hollow_directly(shape, candidate, thickness, tag, why, fatal, inner_volume);
            bool inconsistent = false;
            if (usable(hollow)) {
                return hollow;
            }
            if (!fatal) {
                // The inner wall is right but the two don't make one solid straight away (it
                // isn't one closed shell, or couldn't be checked for running through itself in
                // time): cut it out, and the cut must hold what the walls do.
                String cut_error;
                const Shape cut = boolean(shape, candidate, 1, tag, cut_error);
                if (!usable(cut) && cut_error.begins_with("The cut took too long")) {
                    error = too_long("shell") + String::utf8((" (" + why + ", so it was cut out, which is slow); try another thickness").c_str());
                    return Shape();
                }
                if (usable(cut)) {
                    const double v_out = measure::volume(body).Mass();
                    const double v_in = measure::volume(candidate->get_occ_shape()).Mass();
                    const double v = measure::volume(cut->get_occ_shape()).Mass();
                    if (std::abs(v - (v_out - v_in)) <= 1e-4 * std::abs(v_out) && shells_closed(cut->get_occ_shape())) {
                        const std::string problem = made_consistency_problem(cut->get_occ_shape(), thickness);
                        if (problem.empty()) {
                            return cut;
                        }
                        why = "its inner wall came out wrong: " + problem;
                        inconsistent = true;
                    }
                }
                if (!inconsistent) {
                    why = "cutting out its inner wall came out wrong (" + why + ")";
                }
            }
            wrong = why;
        }
        // The same body is tried again at another size or wall only where OCCT's offset went wrong
        // as it does on a slot (made nothing, came out inside out, put part of the wall onto the
        // outside itself, or walls that don't make a solid): an inner wall that comes nearer the
        // outside or lies farther from it, but not on it, is the body's shape, which another try
        // won't change, and a try on a spline body takes a second or more.
        if (first && std::isfinite(touches) && touches >= 0.05 * thickness && !wrong.empty() && wrong.rfind("its inner wall would", 0) == 0) {
            retry_only_built = true;
        }
        // (The reason told is the first try's, unless that is only that OCCT made nothing and a
        // later try on the body itself finds where it goes wrong.)
        const bool none_made = wrong == NO_INNER_WALL;
        if (first_wrong.empty() || (first_wrong == NO_INNER_WALL && !none_made && attempt.base == 0)) {
            first_wrong = wrong;
        }
    }
    return refuse_offset(first_wrong);
}

/// Why a body's offset in by distance came out empty, from its thickness: where it is thinner
/// than twice the distance (the offset leaves nothing there) or only about that thick (it leaves
/// next to nothing), or that it is clearly thicker everywhere (the geometry kernel failed on it):
/// that is said only when no inward ray meets the far side within twice the distance over
/// HOLLOW_NEAR and the mesh's two deflections more (hollow_upfront_problem's thinnest stays
/// infinite). A 20 mm L 4 mm thick offset in by 2 to 2.015 mm was told it was "more than twice
/// the distance thick everywhere". "" when it can't be measured.
std::string empty_offset_reason(const TopoDS_Shape& body, double distance)
{
    const double t = std::abs(distance);
    const double deflection = std::max(0.01 * t, 5e-6 * diagonal(body));
    const TopoDS_Shape meshed = meshed_copy(body, deflection, std::min(5.0, g_time_limit));
    if (meshed.IsNull()) {
        return "";
    }
    SurfaceMesh outer;
    outer.add(meshed);
    outer.build();
    if (outer.triangles.empty()) {
        return "";
    }
    const HollowUpfront upfront = hollow_upfront_problem(outer, meshed, t, deflection);
    if (std::isfinite(upfront.thinnest) && upfront.thinnest + 2.0 * deflection < 2.0 * t) {
        return "it comes out empty where the body is only about " + mm(upfront.thinnest) + " thick, at " + where_mm(upfront.thinnest_at) +
               " (an offset in takes twice the distance); try a distance under " + mm(0.5 * HOLLOW_NEAR * upfront.thinnest);
    }
    if (std::isfinite(upfront.thinnest)) {
        // (Within the mesh's reach of twice the distance, or a little over it: the thin spot.)
        return "it comes out empty where the body is only about " + mm(upfront.thinnest) + " thick, at " + where_mm(upfront.thinnest_at) +
               ", which is about twice the distance (an offset in takes twice the distance, so next to nothing is left there); try a distance under " +
               mm(0.5 * HOLLOW_NEAR * upfront.thinnest);
    }
    if (!upfront.problem.empty()) {
        return "the geometry kernel's offset came out empty (" + upfront.problem + ")";
    }
    return "the geometry kernel's offset came out empty, although the body is more than twice the distance thick everywhere (it fails like this on some "
           "bodies at some distances); try a slightly different distance";
}

/// What a refused shell or inward offset (refusal) of a body of flat facets is told besides, or "": a closed
/// body of FACET_BODY_FACES flat faces or more that isn't convex (a mesh turned into a solid
/// facet by facet). Convex ones are made exactly (convex_region); on the others OCCT's offset
/// rarely works (a bracket with its hole in 180 strips, a block with crossing holes in 2900:
/// corners kept where the wall needs new ones, walls inside out, nothing at all), at any
/// thickness, so "try another thickness" alone would send the user round in circles.
constexpr int FACET_BODY_FACES = 50;

String facet_body_hint(const TopoDS_Shape& body, const String& refusal)
{
    // (Not where the refusal is that the body is too thin for the wall: that is the reason.)
    if (refusal.is_empty() || refusal.contains("thicker than the body") || refusal.contains("as thick as the body allows") || refusal.contains("where the body is only about") ||
        refusal.contains("thinner than twice")) {
        return String();
    }
    const TopTools_IndexedMapOfShape faces = map_of(body, TopAbs_FACE);
    if (faces.Extent() < FACET_BODY_FACES || map_of(body, TopAbs_SOLID).Extent() == 0) {
        return String();
    }
    for (int i = 1; i <= faces.Extent(); ++i) {
        if (BRepAdaptor_Surface(TopoDS::Face(faces(i)), false).GetType() != GeomAbs_Plane) {
            return String();
        }
    }
    if (!convex_planes(body).empty()) {
        return String();
    }
    char text[320];
    std::snprintf(text, sizeof(text),
                  ". This body is made of %d flat facets and is not convex, which the geometry kernel's offset rarely gets right at any thickness: where the "
                  "facets stand for holes or rounds, a body with those as true curved faces usually works",
                  faces.Extent());
    return String::utf8(text);
}

/// hollow_closed_as_is, on a copy scaled up to OFFSET_REFERENCE_SIZE when the body is smaller
/// (see there: OCCT's fixed tolerances, and its mesher's, are a large part of a millimetre body's
/// wall; a converted 0.5 mm sphere's inner wall took over 5 s to mesh), scaled back after; a
/// refusal tells the body's own places and sizes.
Shape hollow_closed(const Shape& shape, double thickness, const std::string& tag, String& error)
{
    Bnd_Box box;
    BRepBndLib::Add(shape->get_occ_shape(), box);
    const double size = box.IsVoid() ? 0.0 : std::sqrt(box.SquareExtent());
    if (!(size > 0.0) || size >= OFFSET_REFERENCE_SIZE) {
        return hollow_closed_as_is(shape, thickness, tag, error);
    }
    const double scale = OFFSET_REFERENCE_SIZE / size;
    gp_Trsf up;
    up.SetScale(gp_Pnt(0.5 * (box.CornerMin().XYZ() + box.CornerMax().XYZ())), scale);
    const gp_Trsf back = up.Inverted();
    Shape hollow;
    {
        const ReportScale report(back, size);
        hollow = hollow_closed_as_is(moved(shape, up), thickness * scale, tag, error, true);
    }
    return usable(hollow) ? scaled_back(hollow, back) : Shape();
}

/// A face of a hollow body's inner wall under an open face (open_from_hollow): its open face's
/// outward normal and how far under that face's plane it lies (the wall, or a hair more where the
/// inner wall was retried a hair thicker: HOLLOW_STRETCH).
struct UnderOpening
{
    TopoDS_Face face;
    gp_Dir n;
    double depth = 0.0;
};

/// The hollow body with its openings made straight from faces, without a boolean (OCCT's cut of
/// a hollow body, a solid of two shells, takes off more than the cutter or nothing at all on a
/// box with every edge chamfered): the hollow's faces but the open faces and the inner wall's
/// faces under them (unders: each with its open face's outward normal), the sides of a prism a
/// wall high on each of those (the opening's sides, facing into it), and each open face less that
/// prism's top (the rim), sewn into one solid. Null when they don't make one closed solid.
Shape opened_directly(const Shape& hollow, const std::vector<TopoDS_Face>& removed, const std::vector<UnderOpening>& unders, const std::string& tag)
{
    const double size = diagonal(hollow->get_occ_shape());
    BRepBuilderAPI_Sewing sewing(std::max(1e-7, 1e-6 * size));
    std::vector<naming::Role> roles;
    const TopTools_IndexedMapOfShape faces = map_of(hollow->get_occ_shape(), TopAbs_FACE);
    std::vector<std::pair<TopoDS_Shape, std::string>> kept;
    for (TopExp_Explorer it(hollow->get_occ_shape(), TopAbs_FACE); it.More(); it.Next()) {
        const TopoDS_Shape& face = it.Current();
        const bool open = std::any_of(removed.begin(), removed.end(), [&](const TopoDS_Face& f) { return f.IsSame(face); });
        const bool under = std::any_of(unders.begin(), unders.end(), [&](const UnderOpening& u) { return u.face.IsSame(face); });
        if (open || under) {
            continue;
        }
        sewing.Add(face);
        const int i = faces.FindIndex(face);
        if (i > 0 && size_t(i - 1) < hollow->face_name_list.size()) {
            kept.push_back({face, hollow->face_name_list[size_t(i - 1)]});
        }
    }
    for (const UnderOpening& u : unders) {
        // (Found under exactly one open face.)
        const TopoDS_Face base = TopoDS::Face(u.face.Oriented(TopAbs_FORWARD));
        BRepPrimAPI_MakePrism prism(base, gp_Vec(u.n) * u.depth, true);
        const TopoDS_Shape top = prism.LastShape();
        const bool inverted = measure::volume(prism.Shape()).Mass() < 0.0;
        for (TopExp_Explorer it(prism.Shape(), TopAbs_FACE); it.More(); it.Next()) {
            if (it.Current().IsSame(prism.FirstShape()) || it.Current().IsSame(top)) {
                continue;
            }
            // (A side of the prism faces out of it, into the shell's wall: the opening's side
            // faces into the opening.)
            sewing.Add(inverted ? it.Current() : it.Current().Reversed());
        }
        bool found = false;
        for (const TopoDS_Face& face : removed) {
            GProp_GProps props;
            BRepGProp::SurfaceProperties(top, props);
            BRepClass_FaceClassifier middle(face, props.CentreOfMass(), 1e-7 + 1e-7 * size);
            if (middle.State() != TopAbs_IN) {
                continue;
            }
            const TopoDS_Face forward = TopoDS::Face(face.Oriented(TopAbs_FORWARD));
            const TopoDS_Wire hole = TopoDS::Wire(BRepTools::OuterWire(TopoDS::Face(top)).Oriented(TopAbs_FORWARD));
            // (The top lies inside the open face when its corners and its edges' middles do; where
            // the opening runs up to a wall that rises from the open face's edge, the top reaches
            // that edge, and a hole touching the outer wire is a face the mesher misreads: a lid
            // over the opening or a piece of the rim left out, while the face's area is right.)
            bool inside = true;
            for (TopExp_Explorer v(hole, TopAbs_VERTEX); v.More() && inside; v.Next()) {
                inside = BRepClass_FaceClassifier(forward, BRep_Tool::Pnt(TopoDS::Vertex(v.Current())), 1e-7 + 1e-7 * size).State() == TopAbs_IN;
            }
            for (TopExp_Explorer e(hole, TopAbs_EDGE); e.More() && inside; e.Next()) {
                BRepAdaptor_Curve curve(TopoDS::Edge(e.Current()));
                inside = BRepClass_FaceClassifier(forward, curve.Value(0.5 * (curve.FirstParameter() + curve.LastParameter())), 1e-7 + 1e-7 * size).State() == TopAbs_IN;
            }
            std::vector<TopoDS_Shape> pieces;
            if (inside) {
                // (The open face with the prism's top as a hole: OCCT's cut of one face by another
                // in its plane can hand back the face whole.)
                BRepBuilderAPI_MakeFace rim(forward);
                rim.Add(hole);
                if (!rim.IsDone()) {
                    return Shape();
                }
                ShapeFix_Face fix(rim.Face());
                fix.FixOrientation();
                fix.Perform();
                pieces.push_back(fix.Face());
            }
            else {
                // (The open face less a slab through it the top's shape: its pieces outside, each
                // bounded by one wire, joined to the wall rising from its edge by the sewing.)
                gp_Trsf down;
                down.SetTranslation(gp_Vec(u.n) * (-0.5 * u.depth));
                const TopoDS_Shape lowered = BRepBuilderAPI_Transform(top, down, true).Shape();
                TopoDS_Shape slab = BRepPrimAPI_MakePrism(lowered, gp_Vec(u.n) * u.depth, true).Shape();
                BRepAlgoAPI_Cut cut(forward, slab);
                if (!cut.IsDone() || cut.Shape().IsNull()) {
                    return Shape();
                }
                for (TopExp_Explorer it(cut.Shape(), TopAbs_FACE); it.More(); it.Next()) {
                    pieces.push_back(it.Current());
                }
                if (pieces.empty()) {
                    return Shape();
                }
            }
            GProp_GProps open_area, rim_area;
            BRepGProp::SurfaceProperties(face, open_area);
            BRepGProp::SurfaceProperties(make_compound(pieces), rim_area);
            // (The hole must be one: the rim holds the open face less the top.)
            if (std::abs(rim_area.Mass() - (open_area.Mass() - props.Mass())) > 1e-6 * open_area.Mass()) {
                return Shape();
            }
            for (const TopoDS_Shape& made : pieces) {
                sewing.Add(face.Orientation() == TopAbs_REVERSED ? made.Reversed() : made);
            }
            found = true;
            break;
        }
        if (!found) {
            return Shape();
        }
    }
    sewing.Perform();
    const TopoDS_Shape sewn = sewing.SewedShape();
    const TopTools_IndexedMapOfShape shells = map_of(sewn, TopAbs_SHELL);
    if (shells.Extent() != 1 || !shells_closed(sewn) || sewing.NbFreeEdges() > 0) {
        return Shape();
    }
    TopoDS_Solid solid = solid_of(TopoDS::Shell(shells(1)));
    if (measure::volume(solid).Mass() < 0.0) {
        solid.Reverse();
    }
    for (const auto& [face, name] : kept) {
        if (!name.empty() && sewing.IsModified(face)) {
            roles.push_back({sewing.Modified(face), name});
        }
        else if (!name.empty()) {
            roles.push_back({face, name});
        }
    }
    Shape out = CadShape::wrap(solid);
    naming::name_result(*out.ptr(), nullptr, {}, tag, roles);
    return out;
}

/// A shell with flat open faces, made from the closed hollow body where OCCT's thick solid fails
/// (it does on a box with every edge rounded, at any thickness): the closed hollow (hollow_closed,
/// checked), cut through each open face above the inner wall's face under it (the open face's
/// plane a wall in, which every wall in from a flat face is), straight out past the open face.
/// The cut must take just that face's area times the wall. Null with error set when it can't be
/// made that way.
Shape open_from_hollow(const Shape& shape, const PackedInt32Array& open, double thickness, const std::string& tag, String& error)
{
    const std::vector<TopoDS_Face> removed = pick_faces(shape, open);
    if (removed.empty()) {
        return Shape();
    }
    for (const TopoDS_Face& face : removed) {
        if (BRepAdaptor_Surface(face, false).GetType() != GeomAbs_Plane) {
            return Shape();
        }
    }
    Shape hollow = hollow_closed(shape, thickness, tag + ":closed", error);
    if (!usable(hollow)) {
        return Shape();
    }
    const double size = diagonal(shape->get_occ_shape());
    const double tol = 1e-7 + 1e-7 * size;
    // The inner wall's faces under the open faces (a wall under their planes, or a hair more), and
    // what the opening takes there.
    std::vector<UnderOpening> unders;
    double expected = 0.0;
    for (const TopoDS_Face& face : removed) {
        const gp_Dir n = face_normal(face);
        const gp_Pln plane = BRepAdaptor_Surface(face, false).Plane();
        bool found = false;
        for (TopExp_Explorer it(hollow->get_occ_shape(), TopAbs_FACE); it.More(); it.Next()) {
            const TopoDS_Face& inner = TopoDS::Face(it.Current());
            BRepAdaptor_Surface surface(inner, false);
            if (surface.GetType() != GeomAbs_Plane || std::abs(std::abs(surface.Plane().Axis().Direction().Dot(n)) - 1.0) > 1e-9) {
                continue;
            }
            const double depth = gp_Vec(surface.Plane().Location(), plane.Location()).Dot(gp_Vec(n));
            if (depth < thickness - tol || depth > thickness * (1.0 + HOLLOW_STRETCH) + tol) {
                continue;
            }
            // (Under the open face: a point of it, projected up, lies on it. Its middle, or when
            // that is in a hole of it, a point of a grid over it.)
            GProp_GProps props;
            BRepGProp::SurfaceProperties(inner, props);
            gp_Pnt on = props.CentreOfMass();
            if (BRepClass_FaceClassifier(inner, on, tol).State() != TopAbs_IN) {
                double u0, u1, v0, v1;
                BRepTools::UVBounds(inner, u0, u1, v0, v1);
                bool any = false;
                for (int i = 1; i < 16 && !any; ++i) {
                    for (int j = 1; j < 16 && !any; ++j) {
                        const gp_Pnt2d uv(u0 + (u1 - u0) * i / 16.0, v0 + (v1 - v0) * j / 16.0);
                        BRepClass_FaceClassifier grid(inner, uv, tol);
                        if (grid.State() == TopAbs_IN) {
                            on = surface.Value(uv.X(), uv.Y());
                            any = true;
                        }
                    }
                }
                if (!any) {
                    continue;
                }
            }
            BRepClass_FaceClassifier classify(face, on.Translated(depth * gp_Vec(n)), tol);
            if (classify.State() != TopAbs_IN) {
                continue;
            }
            unders.push_back({inner, n, depth});
            // (What the opening takes, measured as the volumes it is checked by are: OCCT's
            // volume of a wall's face a wall high can differ from its area times the wall by a
            // hundredth where the face's edges are approximated curves.)
            expected += std::abs(measure::volume(BRepPrimAPI_MakePrism(TopoDS::Face(inner.Oriented(TopAbs_FORWARD)), gp_Vec(n) * depth, true).Shape()).Mass());
            found = true;
        }
        if (!found) {
            error = "The shell with an opening could not be built at that thickness: the wall in from an open face was not found";
            return Shape();
        }
    }
    // Every other face of the inner wall beside those must lie under a kept face, a wall in: one
    // that doesn't lies in the opening, where no wall is (the round OCCT's offset puts along an
    // edge where two open faces meet inward: cutting the prisms out leaves it standing in the
    // hollow, a post the wall thick), and is refused.
    {
        std::vector<TopoDS_Face> kept_faces;
        for (TopExp_Explorer it(shape->get_occ_shape(), TopAbs_FACE); it.More(); it.Next()) {
            if (std::none_of(removed.begin(), removed.end(), [&](const TopoDS_Face& f) { return f.IsSame(it.Current()); })) {
                kept_faces.push_back(TopoDS::Face(it.Current()));
            }
        }
        const TopoDS_Shape kept = compound_of(kept_faces);
        TopTools_IndexedMapOfShape under_edges;
        for (const UnderOpening& u : unders) {
            TopExp::MapShapes(u.face, TopAbs_EDGE, under_edges);
        }
        for (TopExp_Explorer it(hollow->get_occ_shape(), TopAbs_FACE); it.More() && !kept.IsNull(); it.Next()) {
            const TopoDS_Face& face = TopoDS::Face(it.Current());
            if (std::any_of(unders.begin(), unders.end(), [&](const UnderOpening& u) { return u.face.IsSame(face); })) {
                continue;
            }
            bool beside = false;
            for (TopExp_Explorer e(face, TopAbs_EDGE); e.More() && !beside; e.Next()) {
                beside = under_edges.Contains(e.Current());
            }
            if (!beside) {
                continue;
            }
            // (A point on the face: the middle of its parameters, or of a grid over them.)
            double u0, u1, v0, v1;
            BRepTools::UVBounds(face, u0, u1, v0, v1);
            const BRepAdaptor_Surface surface(face, false);
            bool found = false;
            gp_Pnt on;
            for (int i = 0; i < 15 * 15 + 1 && !found; ++i) {
                const gp_Pnt2d uv = i == 0 ? gp_Pnt2d(0.5 * (u0 + u1), 0.5 * (v0 + v1)) : gp_Pnt2d(u0 + (u1 - u0) * ((i - 1) % 15 + 1) / 16.0, v0 + (v1 - v0) * ((i - 1) / 15 + 1) / 16.0);
                if (BRepClass_FaceClassifier(face, uv, tol).State() == TopAbs_IN) {
                    on = surface.Value(uv.X(), uv.Y());
                    found = true;
                }
            }
            if (!found) {
                continue;
            }
            BRepExtrema_DistShapeShape distance(BRepBuilderAPI_MakeVertex(on).Vertex(), kept);
            if (distance.IsDone() && distance.Value() > 1.5 * thickness) {
                error = String::utf8(("The shell with an opening could not be built at that thickness: part of its inner wall at " + where_mm(on) +
                                      " would stay standing in the opening (where open faces meet inward, the closed hollow's wall there lies under no kept "
                                      "face); try leaving one of those faces closed")
                                         .c_str());
                return Shape();
            }
        }
    }
    // Cut straight out from those faces past the open faces; when OCCT's cut fails on the cutter
    // lying on the inner wall's face, from a little under it (in the hollow, so it takes the
    // same), and the cut must take just the faces' area times the wall either way.
    const double v_hollow = measure::volume(hollow->get_occ_shape()).Mass();
    const double v_body = std::abs(measure::volume(shape->get_occ_shape()).Mass());
    // The open faces as the hollow has them (its own faces: they are copies when it was made on
    // a scaled copy of a small body), by plane, area and middle.
    std::vector<TopoDS_Face> removed_here;
    for (const TopoDS_Face& face : removed) {
        const gp_Dir n = face_normal(face);
        GProp_GProps props;
        BRepGProp::SurfaceProperties(face, props);
        for (TopExp_Explorer it(hollow->get_occ_shape(), TopAbs_FACE); it.More(); it.Next()) {
            const TopoDS_Face& candidate = TopoDS::Face(it.Current());
            if (BRepAdaptor_Surface(candidate, false).GetType() != GeomAbs_Plane || face_normal(candidate).Dot(n) < 1.0 - 1e-9) {
                continue;
            }
            GProp_GProps here;
            BRepGProp::SurfaceProperties(candidate, here);
            if (std::abs(here.Mass() - props.Mass()) <= 1e-6 * props.Mass() && here.CentreOfMass().Distance(props.CentreOfMass()) <= 1e-6 * size + 1e-9) {
                removed_here.push_back(candidate);
                break;
            }
        }
    }
    // Where the inner wall's faces under two open faces meet (two open faces side by side: a
    // box's top and a side), the prisms on them leave the wall's corner between them standing, a
    // bar the wall's section along their edge bridging the openings: it is cut too, a block on
    // that edge, the walls under both open faces deep. Only where that block is the corner
    // exactly: the two faces square to each other and the faces at its ends square to the edge
    // (otherwise it would take too much or too little, and that is refused).
    std::vector<TopoDS_Shape> corners;
    for (size_t i = 0; i < unders.size(); ++i) {
        const TopTools_IndexedMapOfShape edges_i = map_of(unders[i].face, TopAbs_EDGE);
        for (size_t j = i + 1; j < unders.size(); ++j) {
            for (TopExp_Explorer e(unders[j].face, TopAbs_EDGE); e.More(); e.Next()) {
                const TopoDS_Edge& edge = TopoDS::Edge(e.Current());
                if (!edges_i.Contains(edge) || BRep_Tool::Degenerated(edge)) {
                    continue;
                }
                const char* const slanted = "The shell with an opening could not be built at that thickness: two of its open faces meet at a slant, which the "
                                            "shell made from the closed hollow can't open between them; try opening one of them";
                BRepAdaptor_Curve line(edge);
                if (line.GetType() != GeomAbs_Line || std::abs(unders[i].n.Dot(unders[j].n)) > 1e-9) {
                    error = slanted;
                    return Shape();
                }
                const gp_Dir along = line.Line().Direction();
                TopoDS_Vertex v1, v2;
                TopExp::Vertices(edge, v1, v2);
                for (const TopoDS_Vertex& end : {v1, v2}) {
                    for (TopExp_Explorer f(hollow->get_occ_shape(), TopAbs_FACE); f.More(); f.Next()) {
                        const TopoDS_Face& other = TopoDS::Face(f.Current());
                        if (other.IsSame(unders[i].face) || other.IsSame(unders[j].face) || !map_of(other, TopAbs_VERTEX).Contains(end)) {
                            continue;
                        }
                        const BRepAdaptor_Surface plane(other, false);
                        if (plane.GetType() != GeomAbs_Plane || std::abs(std::abs(plane.Plane().Axis().Direction().Dot(along)) - 1.0) > 1e-9) {
                            error = slanted;
                            return Shape();
                        }
                    }
                }
                // (Twice as deep as the walls, out past the open faces into the air, as the prisms
                // are; it takes the walls' depths times the edge's length of the wall.)
                const TopoDS_Shape strip = BRepPrimAPI_MakePrism(edge, gp_Vec(unders[i].n) * (2.0 * unders[i].depth), true).Shape();
                TopoDS_Shape block = BRepPrimAPI_MakePrism(strip, gp_Vec(unders[j].n) * (2.0 * unders[j].depth), true).Shape();
                if (measure::volume(block).Mass() < 0.0) {
                    block.Reverse();
                }
                corners.push_back(block);
                expected += unders[i].depth * unders[j].depth * GCPnts_AbscissaPoint::Length(line);
            }
        }
    }
    // (A result the prisms and blocks took the right volume from, its faces and mesh agreeing;
    // inconsistent says why when only the latter fails.)
    std::string inconsistent;
    auto sound = [&](const Shape& made) {
        if (!usable(made) || map_of(made->get_occ_shape(), TopAbs_SOLID).Extent() != 1 || !shells_closed(made->get_occ_shape())) {
            return false;
        }
        const double v = measure::volume(made->get_occ_shape()).Mass();
        if (!(std::abs((v_hollow - v) - expected) <= 1e-6 * v_body)) {
            return false;
        }
        inconsistent = made_consistency_problem(made->get_occ_shape(), thickness);
        return inconsistent.empty();
    };
    if (removed_here.size() == removed.size() && corners.empty()) {
        const Shape direct = opened_directly(hollow, removed_here, unders, tag);
        if (sound(direct)) {
            error = "";
            return direct;
        }
    }
    for (const double below : {0.0, 0.05}) {
        std::vector<TopoDS_Shape> cutters;
        for (const UnderOpening& u : unders) {
            const gp_Dir& n = u.n;
            TopoDS_Face from = TopoDS::Face(u.face.Oriented(TopAbs_FORWARD));
            if (below > 0.0) {
                gp_Trsf down;
                down.SetTranslation(gp_Vec(n) * (-below * thickness));
                from = TopoDS::Face(BRepBuilderAPI_Transform(from, down, true).Shape());
            }
            TopoDS_Shape prism = BRepPrimAPI_MakePrism(from, gp_Vec(n) * ((2.0 + below) * thickness), true).Shape();
            if (measure::volume(prism).Mass() < 0.0) {
                prism.Reverse();
            }
            cutters.push_back(prism);
        }
        cutters.insert(cutters.end(), corners.begin(), corners.end());
        Shape tool = CadShape::wrap(make_compound(cutters));
        if (!corners.empty()) {
            // (One solid: OCCT's cut by a compound of solids that touch takes their shared faces
            // for walls of their own.)
            BRepAlgoAPI_Fuse fuse;
            TopTools_ListOfShape arguments, tools;
            arguments.Append(cutters.front());
            for (size_t k = 1; k < cutters.size(); ++k) {
                tools.Append(cutters[k]);
            }
            fuse.SetArguments(arguments);
            fuse.SetTools(tools);
            const Handle(Deadline) clock = new Deadline(std::min(5.0, g_time_limit));
            fuse.Build(clock->Start());
            if (!clock->expired() && fuse.IsDone() && !fuse.Shape().IsNull()) {
                tool = unify(CadShape::wrap(fuse.Shape()), tag + ":opening");
            }
        }
        String cut_error;
        Shape cut = boolean(hollow, tool, 1, tag, cut_error);
        if (!usable(cut)) {
            // (The boolean's own advice is for shapes the user placed; these are the shell's.)
            error = cut_error.begins_with("The cut took too long")
                        ? String("The shell with an opening could not be built at that thickness: cutting the opening out of the hollow body took too long; try another thickness")
                        : String("The shell with an opening could not be built at that thickness: the geometry kernel could not cut the opening out of the hollow body; try "
                                 "another thickness");
            continue;
        }
        if (sound(cut)) {
            error = "";
            return cut;
        }
        error = inconsistent.empty() ? String("The shell with an opening could not be built at that thickness: the geometry kernel's cut of the opening out of the hollow body came out wrong; try another thickness")
                                     : String::utf8(("The shell with an opening could not be built at that thickness: " + inconsistent).c_str());
    }
    return Shape();
}

/// The error for a shell with an opening that OCCT's thick solid couldn't build: on spline bodies
/// (converted form bodies) it fails at any thickness, so the thickness isn't what to change there.
String open_shell_error(const TopoDS_Shape& body)
{
    for (TopExp_Explorer it(body, TopAbs_FACE); it.More(); it.Next()) {
        const GeomAbs_SurfaceType type = BRepAdaptor_Surface(TopoDS::Face(it.Current())).GetType();
        if (type == GeomAbs_BSplineSurface || type == GeomAbs_BezierSurface) {
            return "The shell with an opening could not be built at that thickness: on curved spline faces like this body's it fails at any thickness, so try a hollow shell without open faces";
        }
    }
    return "The shell could not be built at that thickness (try another thickness)";
}

}  // namespace

namespace
{
Shape offset_shape_unguarded(const Shape& picked, double distance, const std::string& tag, String& error);
Shape shell_unguarded(const Shape& picked, const PackedInt32Array& faces, const Dictionary& p, String& error);
}  // namespace

/// offset_shape_unguarded with any fault in the geometry kernel caught (its offset calls are
/// each guarded themselves; this is for a fault in what runs around them, its meshing and
/// checks): a refusal, never a crash.
Shape offset_shape(const Shape& picked, double distance, const std::string& tag, String& error)
{
    Shape out;
    String why;
    if (guard::run_guarded(0.0, [&] { out = offset_shape_unguarded(picked, distance, tag, why); }) == guard::Outcome::crashed) {
        error = String("The offset could not be built: ") + KERNEL_FAULT;
        return Shape();
    }
    error = why;
    return out;
}

/// shell_unguarded with any fault in the geometry kernel caught (see offset_shape).
Shape shell(const Shape& picked, const PackedInt32Array& faces, const Dictionary& p, String& error)
{
    Shape out;
    String why;
    if (guard::run_guarded(0.0, [&] { out = shell_unguarded(picked, faces, p, why); }) == guard::Outcome::crashed) {
        error = String("The shell could not be built: ") + KERNEL_FAULT + "; try another thickness";
        return Shape();
    }
    error = why;
    return out;
}

namespace
{

Shape offset_shape_unguarded(const Shape& picked, double distance, const std::string& tag, String& error)
{
    if (!usable(picked)) {
        error = "Pick a body to offset";
        return Shape();
    }
    // OCCT's offset, checked densely (offset_points_problem: it hands back faces half the distance
    // off as done); when it fails or comes out wrong, again on a copy twice the size (it fails on
    // some bodies at one size and not at another). A refusal says why.
    const auto started = std::chrono::steady_clock::now();
    // A convex body of flat faces offset in: exact, the solid behind its faces' planes moved in
    // (sharp joins and round ones are the same inward there), tried first: OCCT's offset keeps
    // corners a face shrinking away needs replaced (a chamfered box's) and corners where the
    // faces round them, moved in, no longer meet in one point (a ball of flat triangles), and
    // hands back faces that don't meet, not the same from one run to the next.
    String exact_error;
    if (distance < 0.0) {
        try {
            const std::vector<FacePlane> planes = convex_planes(picked->get_occ_shape());
            if (!planes.empty()) {
                const std::vector<double> offsets(planes.size(), distance);
                bool empty = false;
                const Shape exact = convex_region(picked->get_occ_shape(), planes, offsets, tag, &empty);
                if (usable(exact)) {
                    if (std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count() > 0.6 * g_time_limit) {
                        // (Its check takes most of as long again as making it did: a ball of 20,000
                        // flat triangles, made after 11 s, is handed back after 19.)
                        error = too_long_ahead("offset", std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count());
                        return Shape();
                    }
                    if (made_consistency_problem(exact->get_occ_shape(), distance).empty()) {
                        return exact;
                    }
                }
                else if (empty) {
                    // (Nothing lies behind all of the moved planes: no offset of it can be right.)
                    error = "The offset could not be built at that distance: it comes out empty (the body is thinner than twice the distance)";
                    return Shape();
                }
                else {
                    exact_error = half_spaces_meet(picked->get_occ_shape(), planes, offsets) == 0
                                      ? String("The offset could not be built at that distance: it comes out empty (the body is thinner than twice the distance)")
                                      : String("The offset could not be built at that distance: the geometry kernel could not make it (the solid behind the body's faces "
                                               "moved in), though the body is thick enough for it; try a slightly different distance");
                }
            }
        }
        catch (const Standard_Failure&) {
            // (OCCT's offset next.)
        }
    }
    const double factor = offset_factor(picked->get_occ_shape());
    String first;
    for (const double extra : {1.0, 2.0}) {
        // (One time limit for both tries: each had the whole of it, and a body of 2900 flat facets
        // the kernel fails on after 17 s was refused after 35 s. The second runs only while half
        // of it is left, within that.)
        const double left = g_time_limit - std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count();
        if (extra != 1.0 && left < 0.5 * g_time_limit) {
            break;
        }
        bool stopped = false;
        String why;
        const Shape out = offset_whole(picked, distance, factor * extra, tag, why, stopped, std::max(left, 1.0));
        if (stopped) {
            error = why;
            return Shape();
        }
        if (usable(out)) {
            std::string wrong;
            try {
                wrong = offset_points_problem(picked->get_occ_shape(), out->get_occ_shape(), distance, HOLLOW_FAR, "the offset");
                if (wrong.empty()) {
                    // (The points checked are its mesh's: its faces must hold what that does.)
                    wrong = made_consistency_problem(out->get_occ_shape(), distance);
                }
            }
            catch (const Standard_Failure&) {
                wrong = "the geometry kernel failed while it was being checked";
            }
            if (wrong.empty()) {
                return out;
            }
            why = String::utf8(("The offset could not be built at that distance: " + wrong).c_str());
        }
        if (first.is_empty()) {
            first = why;
        }
    }
    // (The exact one's refusal, where it was tried and nothing could be made of it either.)
    if (!exact_error.is_empty()) {
        error = exact_error;
        return Shape();
    }
    error = first.is_empty() ? String("The offset could not be built") : first;
    if (distance < 0.0 && error.contains(OFFSET_EMPTY)) {
        // (Whether the body leaves room for it: OCCT's offset also comes out empty on bodies it
        // just fails on, an L-shaped box 4 mm thick offset in by 0.1 mm among them.)
        try {
            const std::string why = empty_offset_reason(picked->get_occ_shape(), -distance);
            if (!why.empty()) {
                error = String::utf8(("The offset could not be built at that distance: " + why).c_str());
            }
        }
        catch (const Standard_Failure&) {
            // (The refusal as it was.)
        }
    }
    if (distance < 0.0) {
        error += facet_body_hint(picked->get_occ_shape(), error);
    }
    return Shape();
}

Shape shell_unguarded(const Shape& picked, const PackedInt32Array& faces, const Dictionary& p, String& error)
{
    if (!usable(picked)) {
        error = "Pick a body to shell";
        return Shape();
    }
    const std::string tag = tag_of(p, "shell");
    const double thickness = p.get("thickness", 0.001);
    const String direction = p.get("direction", "inside");
    try {
        // OCCT's offsets change the edges and vertices they work on (tolerances, curves), failing
        // or not, and a body shares those with the document's other shapes: they work on a copy.
        const Shape shape = detached(picked);
        if (faces.is_empty()) {
            // No open faces: a closed hollow body, the body less its inward offset. A refusal is
            // kept, so the rebuilds after it don't spend the same seconds again.
            if (known_shell_refusal(picked->get_occ_shape(), thickness, error)) {
                return Shape();
            }
            Shape hollow;
            try {
                hollow = hollow_closed(shape, thickness, tag, error);
            }
            catch (const Standard_Failure&) {
                error = "The shell could not be built at that thickness (try another thickness)";
            }
            if (!usable(hollow)) {
                error += facet_body_hint(picked->get_occ_shape(), error);
                remember_shell_refusal(picked->get_occ_shape(), thickness, error);
            }
            return hollow;
        }
        // A convex body of flat faces (a box, chamfered or not) when OCCT's thick solid of it is
        // refused: exact from its faces' planes moved (convex_shell). Its error, when it can't be
        // made so, is the one told.
        auto exact_or = [&](const String& otherwise) {
            String why;
            Shape exact;
            try {
                exact = convex_shell(detached(picked), faces, thickness, direction, tag, why);
            }
            catch (const Standard_Failure&) {
                exact = Shape();
            }
            if (usable(exact)) {
                error = "";
                return exact;
            }
            error = why.is_empty() ? otherwise : why;
            return Shape();
        };
        Shape base = shape;
        PackedInt32Array open = faces;
        double offset = direction == "outside" ? thickness : -thickness;
        if (direction == "both") {
            // Grow by half first, then hollow by the full thickness from there.
            auto grown_by = std::make_unique<BRepOffsetAPI_MakeOffsetShape>();
            BRepOffsetAPI_MakeOffsetShape& grow = *grown_by;
            const Handle(Deadline) clock = new Deadline(g_time_limit);
            if (!survived([&] {
                    grow.PerformByJoin(shape->get_occ_shape(), thickness * 0.5, 1e-7, BRepOffset_Skin, false, false, GeomAbs_Intersection, false, clock->Start());
                })) {
                (void)grown_by.release();
                return exact_or(String("The shell could not grow outward: ") + KERNEL_FAULT);
            }
            if (clock->expired()) {
                error = too_long("shell");
                return Shape();
            }
            if (!grow.IsDone()) {
                return exact_or("The shell could not grow outward");
            }
            Shape grown = CadShape::wrap(grow.Shape());
            naming::name_result(*grown.ptr(), &grow, {shape.ptr()}, tag);
            TopTools_IndexedMapOfShape grown_faces = map_of(grow.Shape(), TopAbs_FACE);
            open = PackedInt32Array();
            for (const TopoDS_Face& face : pick_faces(shape, faces)) {
                // (OCCT's offset tells the face it made from a face as generated, not modified.)
                for (const TopTools_ListOfShape* made : {&grow.Modified(face), &grow.Generated(face)}) {
                    for (TopTools_ListOfShape::Iterator it(*made); it.More(); it.Next()) {
                        const int index = grown_faces.FindIndex(it.Value()) - 1;
                        if (index >= 0 && !open.has(index)) {
                            open.push_back(index);
                        }
                    }
                }
            }
            if (open.is_empty()) {
                return exact_or("The shell could not grow outward (its open faces were lost)");
            }
            base = grown;
            offset = -thickness;
        }
        TopTools_ListOfShape closing;
        for (const TopoDS_Face& face : pick_faces(base, open)) {
            closing.Append(face);
        }
        auto thick = std::make_unique<BRepOffsetAPI_MakeThickSolid>();
        BRepOffsetAPI_MakeThickSolid& maker = *thick;
        // Sharp (intersection) joins: outside walls keep square corners like other CAD shells.
        const Handle(Deadline) clock = new Deadline(g_time_limit);
        // (A fault inside it counts as no thick solid: the other ways to the shell follow.)
        const bool whole = survived([&] {
            maker.MakeThickSolidByJoin(base->get_occ_shape(), closing, offset, 1e-7, BRepOffset_Skin, false, false, GeomAbs_Intersection, false, clock->Start());
        });
        if (!whole) {
            (void)thick.release();
        }
        if (whole && clock->expired()) {
            error = too_long("shell");
            return Shape();
        }
        // OCCT can report success and hand back the body as it was (a spline-walled prism at
        // 0.05 mm, a loft at 0.2 mm): a shell has walls on both sides, so more faces, and hollowed
        // inward it holds less than the body.
        const bool hollowed = whole && maker.IsDone() && !maker.Shape().IsNull() && map_of(maker.Shape(), TopAbs_FACE).Extent() > map_of(base->get_occ_shape(), TopAbs_FACE).Extent() &&
                              (offset > 0.0 || measure::volume(maker.Shape()).Mass() < measure::volume(base->get_occ_shape()).Mass() * (1.0 - 1e-9));
        // And what it hands back must be the shell, checked densely (open_shell_problem): it
        // passes walls a third of the thickness from the outside and openings closed over.
        std::string wrong;
        if (!whole) {
            wrong = KERNEL_FAULT;
        }
        if (hollowed) {
            // (First that its faces and mesh agree: the walls' points checked next are its
            // mesh's, and OCCT's thick solid can keep the body's corners where the walls need new
            // edges, a box's outer wall at under 1 mm running up to the open face's corners with
            // no rim, which would be told as a wall too close to the outside.)
            wrong = made_consistency_problem(maker.Shape(), thickness);
            if (wrong.empty()) {
                wrong = open_shell_problem(base->get_occ_shape(), pick_faces(base, open), maker.Shape(), offset);
            }
            if (wrong.empty() && direction == "both") {
                wrong = offset_points_problem(shape->get_occ_shape(), base->get_occ_shape(), 0.5 * thickness, HOLLOW_SHARP_FAR, "its outer wall");
            }
        }
        if (!hollowed || !wrong.empty()) {
            const String refusal = wrong.empty() ? open_shell_error(base->get_occ_shape())
                                                 : String::utf8(("The shell with an opening could not be built at that thickness: " + wrong + "; try another thickness").c_str());
            if (!convex_planes(picked->get_occ_shape()).empty()) {
                return exact_or(refusal);
            }
            if (direction == "inside") {
                String why;
                // (On a fresh copy: the thick solid above changed the edges of the one it had.)
                Shape opened = open_from_hollow(detached(picked), faces, thickness, tag, why);
                if (usable(opened)) {
                    return opened;
                }
                if (!why.is_empty()) {
                    error = why;
                    return Shape();
                }
            }
            error = refusal;
            return Shape();
        }
        Shape out = CadShape::wrap(maker.Shape());
        naming::name_result(*out.ptr(), &maker, {base.ptr()}, tag);
        return out;
    }
    catch (const Standard_Failure&) {
        // (OCCT's offset can throw where it can't move a face that far, as it can fail.)
        error = faces.is_empty() ? String("The shell could not be built at that thickness (try another thickness)") : open_shell_error(picked->get_occ_shape());
        return Shape();
    }
}

}  // namespace

double time_limit()
{
    return g_time_limit;
}

void set_time_limit(double seconds)
{
    g_time_limit = seconds > 0.0 ? seconds : 20.0;
}

Shape draft(const Shape& shape, const PackedInt32Array& faces, const Dictionary& p, String& error)
{
    if (!usable(shape) || faces.is_empty()) {
        error = "Pick faces to draft";
        return Shape();
    }
    const std::string tag = tag_of(p, "draft");
    try {
        BRepOffsetAPI_DraftAngle maker(shape->get_occ_shape());
        const gp_Dir pull = D(Vector3(p.get("pull", Vector3(0, 1, 0))).normalized());
        const gp_Pln neutral(P(p.get("neutral_origin", Vector3())), D(Vector3(p.get("neutral_normal", Vector3(0, 1, 0))).normalized()));
        const double angle = p.get("angle", M_PI / 36.0);
        for (const TopoDS_Face& face : pick_faces(shape, faces)) {
            maker.Add(face, pull, angle, neutral);
            if (!maker.AddDone()) {
                error = "A face can't be drafted that way (does the pull direction lie along it?)";
                return Shape();
            }
        }
        maker.Build();
        if (!maker.IsDone()) {
            error = "The draft could not be built";
            return Shape();
        }
        Shape out = CadShape::wrap(maker.Shape());
        naming::name_result(*out.ptr(), &maker, {shape.ptr()}, tag);
        return out;
    }
    catch (const Standard_Failure& failure) {
        error = String("Draft failed: ") + failure.GetMessageString();
        return Shape();
    }
}

Shape transform(const Shape& shape, const Transform3D& xform, const std::string& tag, String& error)
{
    if (!usable(shape)) {
        error = "Nothing to move";
        return Shape();
    }
    try {
        const Basis& b = xform.basis;
        const Vector3 x = b.get_column(0), y = b.get_column(1), z = b.get_column(2);
        // Godot's 32-bit floats make a turn rigid to about 1e-7, not exactly: within 1e-6 it is
        // rigid (gp_Trsf orthogonalizes it), so faces keep their kind and their names.
        const double s = (double(x.length()) + y.length() + z.length()) / 3.0;
        const double tol = 1e-6 * s;
        const bool uniform = s > 1e-12 && std::abs(x.length() - s) < tol && std::abs(y.length() - s) < tol && std::abs(z.length() - s) < tol
            && std::abs(x.dot(y)) < tol * s && std::abs(y.dot(z)) < tol * s && std::abs(x.dot(z)) < tol * s;
        if (uniform) {
            gp_Trsf rotation;
            rotation.SetValues(x.x / s, y.x / s, z.x / s, 0.0, x.y / s, y.y / s, z.y / s, 0.0, x.z / s, y.z / s, z.z / s, 0.0);
            gp_Trsf scaling;
            scaling.SetScale(gp_Pnt(), s);
            gp_Trsf shift;
            shift.SetTranslation(gp_Vec(xform.origin.x, xform.origin.y, xform.origin.z));
            BRepBuilderAPI_Transform maker(shape->get_occ_shape(), shift * rotation * scaling, true);
            Shape out = CadShape::wrap(maker.Shape());
            out->face_name_list = shape->face_name_list;
            out->edge_name_list = shape->edge_name_list;
            return out;
        }
        gp_GTrsf general;
        general.SetValue(1, 1, x.x);
        general.SetValue(2, 1, x.y);
        general.SetValue(3, 1, x.z);
        general.SetValue(1, 2, y.x);
        general.SetValue(2, 2, y.y);
        general.SetValue(3, 2, y.z);
        general.SetValue(1, 3, z.x);
        general.SetValue(2, 3, z.y);
        general.SetValue(3, 3, z.z);
        general.SetTranslationPart(gp_XYZ(xform.origin.x, xform.origin.y, xform.origin.z));
        BRepBuilderAPI_GTransform maker(shape->get_occ_shape(), general, true);
        Shape out = CadShape::wrap(maker.Shape());
        naming::name_result(*out.ptr(), &maker, {shape.ptr()}, tag);
        return out;
    }
    catch (const Standard_Failure& failure) {
        error = String("Transform failed: ") + failure.GetMessageString();
        return Shape();
    }
}

Shape offset_faces(const Shape& shape, const PackedInt32Array& faces, double distance, const std::string& tag, String& error)
{
    if (!usable(shape) || faces.is_empty()) {
        error = "Pick faces to offset";
        return Shape();
    }
    try {
        Shape current = shape;
        std::vector<TopoDS_Face> picked = pick_faces(shape, faces);
        bool all_planar = true;
        for (const TopoDS_Face& face : picked) {
            all_planar = all_planar && BRepAdaptor_Surface(face).GetType() == GeomAbs_Plane;
        }
        // Slabs only make sense on solids; a surface's faces move by the offset algorithm.
        if (all_planar && has_solid(shape->get_occ_shape())) {
            // Flat faces: add (or remove) a slab the face sweeps through.
            for (size_t i = 0; i < picked.size(); ++i) {
                // face_normal already points out of the material (it follows the face's orientation).
                gp_Vec n(face_normal(picked[i]));
                BRepPrimAPI_MakePrism slab(picked[i], n * distance, true);
                Shape tool = CadShape::wrap(slab.Shape());
                naming::name_result(*tool.ptr(), nullptr, {}, tag + ":slab");
                const std::string name = size_t(faces[int64_t(i)]) < shape->face_name_list.size() ? shape->face_name_list[faces[int64_t(i)]] : "";
                // The slab's far face takes the moved face's name.
                TopTools_IndexedMapOfShape slab_faces = map_of(slab.Shape(), TopAbs_FACE);
                const int far = slab_faces.FindIndex(slab.LastShape());
                if (far > 0 && !name.empty()) {
                    tool->face_name_list[far - 1] = name;
                }
                current = boolean(current, tool, distance > 0.0 ? 0 : 1, tag, error);
                if (!usable(current)) {
                    return Shape();
                }
            }
            return current;
        }
        if (!has_solid(shape->get_occ_shape())) {
            // A surface moves sheet by sheet: a face moved alone would tear away from the faces
            // it is joined to (OCCT neither trims nor stretches them to meet it).
            const TopTools_IndexedMapOfShape& face_ids = shape->face_map();
            std::vector<TopoDS_Face> all;
            for (int i = 1; i <= face_ids.Extent(); ++i) {
                all.push_back(TopoDS::Face(face_ids(i)));
            }
            TopTools_MapOfShape chosen;
            for (const TopoDS_Face& face : picked) {
                chosen.Add(face);
            }
            PackedInt32Array moving;
            std::vector<TopoDS_Face> resting;
            for (const std::vector<int>& group : face_regions(shape->get_occ_shape(), all)) {
                int count = 0;
                for (int k : group) {
                    count += chosen.Contains(all[k]) ? 1 : 0;
                }
                if (count > 0 && count < int(group.size())) {
                    error = "Pick every face of the surface: moving only some would tear it apart (Offset in the Surface workspace makes a moved copy)";
                    return Shape();
                }
                for (int k : group) {
                    if (count > 0) {
                        moving.push_back(k);
                    }
                    else {
                        resting.push_back(all[k]);
                    }
                }
            }
            String apart;
            Shape moved = offset_surface(shape, moving, distance, tag, error, apart);
            if (usable(moved) && !apart.is_empty()) {
                error = "The faces can't be moved that far together: they would part or overlap where they meet at an angle";
                return Shape();
            }
            if (!usable(moved) || resting.empty()) {
                return moved;
            }
            std::vector<naming::Role> roles;
            const TopTools_IndexedMapOfShape& moved_faces = moved->face_map();
            for (int i = 1; i <= moved_faces.Extent(); ++i) {
                roles.push_back({moved_faces(i), size_t(i - 1) < moved->face_name_list.size() ? moved->face_name_list[i - 1] : ""});
            }
            const TopTools_IndexedMapOfShape& shape_faces = shape->face_map();
            for (const TopoDS_Face& face : resting) {
                const int index = shape_faces.FindIndex(face);
                roles.push_back({face, index > 0 && size_t(index - 1) < shape->face_name_list.size() ? shape->face_name_list[index - 1] : ""});
            }
            Shape out = CadShape::wrap(make_compound({moved->get_occ_shape(), assemble_faces(resting, face_regions(shape->get_occ_shape(), resting))}));
            naming::name_result(*out.ptr(), nullptr, {}, tag, roles);
            return out;
        }
        BRepOffset_MakeOffset maker;
        maker.Initialize(shape->get_occ_shape(), 0.0, 1e-7, BRepOffset_Skin, false, false, GeomAbs_Arc);
        for (const TopoDS_Face& face : picked) {
            maker.SetOffsetOnFace(face, distance);
        }
        maker.MakeOffsetShape();
        if (!maker.IsDone() || !sound(maker.Shape())) {
            error = "The faces could not be offset";
            return Shape();
        }
        return named(maker.Shape(), tag);
    }
    catch (const Standard_Failure& failure) {
        error = String("Offset Face failed: ") + failure.GetMessageString();
        return Shape();
    }
}

Shape split_body(const Shape& shape, const Shape& tool, const Dictionary& p, String& error)
{
    if (!usable(shape) || !usable(tool)) {
        error = "Split Body needs a body and a splitting tool";
        return Shape();
    }
    const std::string tag = tag_of(p, "split");
    if (!has_solid(shape->get_occ_shape())) {
        // A surface splits into regions along the cuts, each its own shell (see pieces()).
        return trim(shape, tool, PackedVector3Array(), p, error);
    }
    try {
        BRepAlgoAPI_Splitter splitter;
        TopTools_ListOfShape arguments;
        TopTools_ListOfShape tools;
        arguments.Append(shape->get_occ_shape());
        tools.Append(tool->get_occ_shape());
        splitter.SetArguments(arguments);
        splitter.SetTools(tools);
        splitter.Build();
        if (!splitter.IsDone()) {
            error = "The body could not be split";
            return Shape();
        }
        Shape out = CadShape::wrap(splitter.Shape());
        naming::name_result(*out.ptr(), &splitter, {shape.ptr(), tool.ptr()}, tag);
        return out;
    }
    catch (const Standard_Failure& failure) {
        error = String("Split Body failed: ") + failure.GetMessageString();
        return Shape();
    }
}

Shape split_faces(const Shape& shape, const PackedInt32Array& faces, const Shape& tool, const std::string& tag, String& error)
{
    if (!usable(shape) || !usable(tool) || faces.is_empty()) {
        error = "Split Face needs faces and a splitting tool";
        return Shape();
    }
    try {
        std::vector<TopoDS_Face> picked = pick_faces(shape, faces);
        BRepFeat_SplitShape splitter(shape->get_occ_shape());
        int added = 0;
        for (const TopoDS_Face& face : picked) {
            BRepAlgoAPI_Section section(face, tool->get_occ_shape(), false);
            section.ComputePCurveOn1(true);
            section.Approximation(true);
            section.Build();
            for (TopExp_Explorer it(section.Shape(), TopAbs_EDGE); it.More(); it.Next()) {
                splitter.Add(TopoDS::Edge(it.Current()), face);
                added++;
            }
        }
        if (added == 0) {
            error = "The tool doesn't cross the faces";
            return Shape();
        }
        splitter.Build();
        if (!splitter.IsDone()) {
            error = "The faces could not be split";
            return Shape();
        }
        Shape out = CadShape::wrap(splitter.Shape());
        naming::name_result(*out.ptr(), &splitter, {shape.ptr()}, tag);
        return out;
    }
    catch (const Standard_Failure& failure) {
        error = String("Split Face failed: ") + failure.GetMessageString();
        return Shape();
    }
}

namespace
{
/// The size (a box diagonal, m) below which a thicken is made scaled up to it and scaled back:
/// OCCT's joined offset has absolute tolerances, and an L sheet with 1.2 mm legs thickened by
/// 0.1 mm came out 12 % short (from 2 mm up it was exact).
constexpr double OFFSET_SIZE = 0.01;

/// A shape's copy scaled by trsf, names carried over (the copy has the same structure, so the same
/// face and edge ids).
Shape rescaled(const Shape& in, const gp_Trsf& trsf)
{
    BRepBuilderAPI_Transform mover(in->get_occ_shape(), trsf, true);
    Shape out = CadShape::wrap(mover.Shape());
    out->face_name_list = in->face_name_list;
    out->edge_name_list = in->edge_name_list;
    return out;
}

Shape thickened(const Shape& shape, const PackedInt32Array& faces, const Dictionary& p, String& error)
{
    const std::string tag = tag_of(p, "thicken");
    const double thickness = p.get("thickness", 0.001);
    const bool symmetric = p.get("symmetric", false);
    // Rounded: where faces meet at a convex seam the outside is rounded over, not mitred.
    const bool rounded = String(p.get("type", "sharp")) == "rounded";
    try {
        std::vector<TopoDS_Face> picked = faces.is_empty() ? faces_of(shape->get_occ_shape()) : pick_faces(shape, faces);
        // Refused up front: a sharp point (OCCT's offset leaves the region round it wrong), and
        // growing to a centre of curvature or past it (the surface would turn inside out), on
        // each side the solid grows to.
        for (const TopoDS_Face& face : picked) {
            if (sharp_point(face)) {
                error = "The surface comes to a sharp point (a cone's apex), which can't be thickened";
                return Shape();
            }
        }
        const double reach = symmetric ? thickness * 0.5 : thickness;
        if (!offset_fits(picked, reach, error) || (symmetric && !offset_fits(picked, -reach, error))) {
            error = "The surface curves too tightly to be thickened that much";
            return Shape();
        }
        // Faces that share edges thicken together as one sheet, so their seams don't overlap (each a
        // copy: OCCT's offsets change the edges they work on, failing or not).
        std::vector<TopoDS_Shape> sheets;
        for (const std::vector<int>& group : face_regions(shape->get_occ_shape(), picked)) {
            sheets.push_back(BRepBuilderAPI_Copy(assemble_faces(picked, {group}), true, false).Shape());
        }
        // OCCT's simple offset (of a sheet, or into a thick solid) moves some faces against their
        // normal (a revolved cone's): offset the other way round, it lands where asked.
        auto simply = [&](const TopoDS_Shape& base, double t, bool into_solid) {
            TopoDS_Shape made;
            for (const double way : {t, -t}) {
                if (into_solid) {
                    BRepOffsetAPI_MakeThickSolid maker;
                    maker.MakeThickSolidBySimple(base, way);
                    made = maker.IsDone() ? maker.Shape() : TopoDS_Shape();
                }
                else {
                    BRepOffsetAPI_MakeOffsetShape maker;
                    maker.PerformBySimple(base, way);
                    made = maker.IsDone() ? maker.Shape() : TopoDS_Shape();
                }
                if (made.IsNull() || offset_along(base, made, t)) {
                    break;
                }
            }
            return made;
        };
        // A sheet grown by t along its normals into a solid (null when OCCT can't): several faces
        // join at their seams (the simple offset would leave the walls crossing), and so does a
        // closed sheet (a sphere's one face); one face, or a joined offset that fails, goes simple.
        auto thick = [&](const TopoDS_Shape& base, double t, bool several, GeomAbs_JoinType join) {
            TopoDS_Shape solid;
            if (several) {
                try {
                    BRepOffset_MakeOffset joined;
                    joined.Initialize(base, t, 1e-7, BRepOffset_Skin, false, false, join, true);
                    joined.MakeOffsetShape();
                    if (joined.IsDone() && !joined.Shape().IsNull() && has_solid(joined.Shape())) {
                        solid = joined.Shape();
                    }
                }
                catch (const Standard_Failure&) {
                }
            }
            if (solid.IsNull()) {
                solid = simply(base, t, true);
                if (solid.IsNull()) {
                    return TopoDS_Shape();
                }
            }
            // Thickening against the face's normal can leave the solid inside out.
            GProp_GProps props;
            BRepGProp::VolumeProperties(solid, props);
            if (props.Mass() < 0.0) {
                solid.Reverse();
            }
            return solid;
        };
        std::vector<TopoDS_Shape> solids;
        for (const TopoDS_Shape& sheet : sheets) {
            if (!facing_one_way(sheet)) {
                error = "The surface's faces face different ways: turn it with Reverse Normal so they face one way";
                return Shape();
            }
            const bool several = (TopExp_Explorer(sheet, TopAbs_FACE).More() && map_of(sheet, TopAbs_FACE).Extent() > 1) || closed_shell(sheet);
            TopoDS_Shape solid;
            if (symmetric && rounded && several) {
                // Each side on its own, rounded over where it is convex, then joined.
                const TopoDS_Shape outside = thick(sheet, thickness * 0.5, true, GeomAbs_Arc);
                const TopoDS_Shape inside = thick(sheet, -thickness * 0.5, true, GeomAbs_Arc);
                if (!outside.IsNull() && !inside.IsNull()) {
                    BRepAlgoAPI_Fuse both(outside, inside);
                    if (both.IsDone()) {
                        ShapeUpgrade_UnifySameDomain unifier(both.Shape(), true, true, true);
                        unifier.Build();
                        solid = unifier.Shape();
                    }
                }
            }
            else {
                TopoDS_Shape base = sheet;
                if (symmetric) {
                    BRepOffsetAPI_MakeOffsetShape joined_shift;
                    if (several) {
                        try {
                            joined_shift.PerformByJoin(sheet, -thickness * 0.5, 1e-7, BRepOffset_Skin, false, false, GeomAbs_Intersection);
                        }
                        catch (const Standard_Failure&) {
                        }
                    }
                    if (several && joined_shift.IsDone() && !joined_shift.Shape().IsNull()) {
                        base = joined_shift.Shape();
                    }
                    else {
                        const TopoDS_Shape shifted = simply(sheet, -thickness * 0.5, false);
                        if (!shifted.IsNull()) {
                            base = shifted;
                        }
                    }
                }
                solid = thick(base, thickness, several, rounded ? GeomAbs_Arc : GeomAbs_Intersection);
            }
            if (solid.IsNull()) {
                error = "A face could not be thickened";
                return Shape();
            }
            // Checked: sound, with a volume what its faces sweep agrees with (their curvatures give
            // it; seams, mitred or overlapped, change it by up to about t^2 a unit of their length
            // each), or else its mesh, and grown the way asked. The mesh lies within its deflection
            // of the faces, so it can miss by up to their area times that; it is made only when
            // needed (meshing an offset finely takes minutes, and can break up: a dome's, with bands
            // on its rim).
            const GProp_GProps props = measure::volume(solid);
            double swept = 0.0;
            double curved = 0.0;
            for (TopExp_Explorer it(sheet, TopAbs_FACE); it.More(); it.Next()) {
                const TopoDS_Face& face = TopoDS::Face(it.Current());
                const double part = swept_volume(face, symmetric ? -reach : 0.0, symmetric ? reach : thickness);
                swept += part;
                curved += BRepAdaptor_Surface(face, false).GetType() == GeomAbs_Plane ? 0.0 : std::abs(part);
            }
            swept = std::abs(swept);
            // Its seams' mitres (or rounds) and overlaps, exactly where flat faces meet along
            // straight seams; a curved face's sweep is integrated on a grid (to about 1 %), and a
            // seam's mitre between curved faces bends (allowed a fifth of t^2 a unit of length).
            double seams = 0.0;
            const double joins = symmetric ? reach * reach * (seam_change(sheet, reach, rounded, seams) + seam_change(sheet, -reach, rounded, seams))
                                           : thickness * thickness * seam_change(sheet, thickness, rounded, seams);
            // Flat faces with no corner where three meet sweep exactly that: nothing else may vouch
            // for it (a 0.6 mm wide L 30 mm long came out 74 % short, and its own mesh agreed).
            bool exact = curved == 0.0;
            if (exact) {
                TopTools_IndexedDataMapOfShapeListOfShape vertex_faces;
                TopExp::MapShapesAndAncestors(sheet, TopAbs_VERTEX, TopAbs_FACE, vertex_faces);
                for (int i = 1; i <= vertex_faces.Extent() && exact; ++i) {
                    TopTools_MapOfShape meeting;
                    for (TopTools_ListOfShape::Iterator it(vertex_faces(i)); it.More(); it.Next()) {
                        meeting.Add(it.Value());
                    }
                    exact = meeting.Extent() < 3;
                }
            }
            bool measured = props.Mass() > 0.0 &&
                std::abs(props.Mass() - (swept + joins)) <= (exact ? 1e-6 * (swept + std::abs(joins)) : 1e-6 * swept + 0.01 * curved + 0.2 * thickness * thickness * seams);
            if (!measured && !exact) {
                const double deflection = several ? std::max({std::abs(thickness) * 5e-3, diagonal(solid) * 1e-5, 2.0 * Precision::Confusion()})
                                                  : std::max({std::abs(thickness) * 5e-2, diagonal(solid) * 2e-4, 2.0 * Precision::Confusion()});
                const double meshed = mesh_volume(solid, deflection);
                const double skin = measure::surface(solid).Mass();
                auto agrees = [&](double volume) { return volume > 0.0 && (meshed < 0.0 || std::abs(meshed - volume) <= 0.01 * volume + skin * deflection); };
                measured = agrees(props.Mass()) || (!several && agrees(swept));
            }
            const bool along = symmetric ? offset_along(sheet, solid, reach) && offset_along(sheet, solid, -reach) : offset_along(sheet, solid, thickness);
            if (!sound(solid) || !measured || !along) {
                error = "The surface could not be thickened that way (the solid came out broken)";
                return Shape();
            }
            solids.push_back(solid);
        }
        return named(solids.size() == 1 ? solids[0] : make_compound(solids), tag);
    }
    catch (const Standard_Failure& failure) {
        error = String("Thicken failed: ") + failure.GetMessageString();
        return Shape();
    }
}
}  // namespace

Shape thicken(const Shape& shape, const PackedInt32Array& faces, const Dictionary& p, String& error)
{
    if (!usable(shape)) {
        error = "Pick faces to thicken";
        return Shape();
    }
    // Sized by the picked faces alone (a small L picked in a body with a face 20 mm away came out
    // broken unscaled), and by their narrowest (an L with 0.6 mm legs 30 mm long came out 74 %
    // short): see work_scale().
    gp_Pnt middle;
    const double factor = work_scale(faces.is_empty() ? faces_of(shape->get_occ_shape()) : pick_faces(shape, faces), OFFSET_SIZE, middle);
    if (factor == 1.0) {
        return thickened(shape, faces, p, error);
    }
    try {
        gp_Trsf grow;
        grow.SetScale(middle, factor);
        Dictionary q = p.duplicate();
        q["thickness"] = double(p.get("thickness", 0.001)) * factor;
        const Shape made = thickened(rescaled(shape, grow), faces, q, error);
        return usable(made) ? rescaled(made, grow.Inverted()) : made;
    }
    catch (const Standard_Failure& failure) {
        error = String("Thicken failed: ") + failure.GetMessageString();
        return Shape();
    }
}

namespace
{
/// True when a face runs along direction everywhere (its normal stays square to it): a wall
/// carried on along direction stays on its surface.
bool runs_along(const TopoDS_Face& face, const gp_Dir& direction)
{
    BRepAdaptor_Surface surface(face);
    if (surface.GetType() == GeomAbs_Plane) {
        return std::abs(surface.Plane().Axis().Direction().Dot(direction)) < 1e-9;
    }
    double u1 = 0.0, u2 = 0.0, v1 = 0.0, v2 = 0.0;
    BRepTools::UVBounds(face, u1, u2, v1, v2);
    for (int i = 0; i <= 4; ++i) {
        for (int j = 0; j <= 4; ++j) {
            gp_Pnt p;
            gp_Vec du;
            gp_Vec dv;
            surface.D1(u1 + (u2 - u1) * i / 4.0, v1 + (v2 - v1) * j / 4.0, p, du, dv);
            const gp_Vec normal = du.Crossed(dv);
            if (normal.Magnitude() > 1e-30 && std::abs(normal.Normalized().Dot(gp_Vec(direction))) > 1e-7) {
                return false;
            }
        }
    }
    return true;
}

/// A point inside a solid: its centre of mass when that is inside, else a point just inside one of
/// its faces. False when none is found.
bool inside_point(const TopoDS_Shape& solid, gp_Pnt& point)
{
    const double size = diagonal(solid);
    GProp_GProps props;
    BRepGProp::VolumeProperties(solid, props);
    point = props.CentreOfMass();
    if (BRepClass3d_SolidClassifier(solid, point, size * 1e-9).State() == TopAbs_IN) {
        return true;
    }
    for (TopExp_Explorer it(solid, TopAbs_FACE); it.More(); it.Next()) {
        const TopoDS_Face& face = TopoDS::Face(it.Current());
        double u1 = 0.0, u2 = 0.0, v1 = 0.0, v2 = 0.0;
        BRepTools::UVBounds(face, u1, u2, v1, v2);
        gp_Pnt on;
        gp_Vec normal;
        BRepGProp_Face(face).Normal(0.5 * (u1 + u2), 0.5 * (v1 + v2), on, normal);
        if (normal.Magnitude() < 1e-12) {
            continue;
        }
        point = on.Translated(normal.Normalized() * (-size * 1e-4));
        if (BRepClass3d_SolidClassifier(solid, point, size * 1e-9).State() == TopAbs_IN) {
            return true;
        }
    }
    return false;
}
}  // namespace

Shape replace_faces(const Shape& shape, const PackedInt32Array& ids, const Shape& target, const Dictionary& p, String& error)
{
    if (!usable(shape) || ids.is_empty() || !usable(target)) {
        error = "Replace Face needs the faces to replace and a target";
        return Shape();
    }
    if (!has_solid(shape->get_occ_shape())) {
        error = "Replace Face onto a surface works on solid bodies";
        return Shape();
    }
    const std::string tag = tag_of(p, "replace");
    try {
        const std::vector<TopoDS_Face> picked = pick_faces(shape, ids);
        if (picked.empty()) {
            error = "Pick the faces to replace";
            return Shape();
        }
        const gp_Dir n = face_normal(picked[0]);
        for (const TopoDS_Face& face : picked) {
            if (BRepAdaptor_Surface(face).GetType() != GeomAbs_Plane || face_normal(face).Dot(n) < 1.0 - 1e-9) {
                error = "Replace Face onto a surface needs flat faces that face one way";
                return Shape();
            }
        }
        // The faces round them are carried on to the target along their normal: they must run
        // along it.
        TopTools_MapOfShape replaced;
        for (const TopoDS_Face& face : picked) {
            replaced.Add(face);
        }
        const TopTools_IndexedDataMapOfShapeListOfShape& edge_faces = shape->edge_face_map();
        const TopTools_IndexedMapOfShape& face_ids = shape->face_map();
        for (const TopoDS_Face& face : picked) {
            for (TopExp_Explorer e(face, TopAbs_EDGE); e.More(); e.Next()) {
                const int index = edge_faces.FindIndex(e.Current());
                if (index <= 0) {
                    continue;
                }
                for (TopTools_ListOfShape::Iterator it(edge_faces(index)); it.More(); it.Next()) {
                    const TopoDS_Face& side = TopoDS::Face(it.Value());
                    if (replaced.Contains(side) || runs_along(side, n)) {
                        continue;
                    }
                    const int id = face_ids.FindIndex(side) - 1;
                    const std::string name = id >= 0 && size_t(id) < shape->face_name_list.size() ? shape->face_name_list[id] : "a side face";
                    error = String("Replace Face can't carry ") + name.c_str() + " on to the target: it doesn't run along the replaced faces' normal";
                    return Shape();
                }
            }
        }
        // The target carried on (naturally) well past the faces, so it reaches across them all.
        Bnd_Box box;
        for (const TopoDS_Face& face : picked) {
            BRepBndLib::Add(face, box);
        }
        BRepBndLib::Add(target->get_occ_shape(), box);
        const double size = std::sqrt(box.SquareExtent());
        TopoDS_Shape cutter = target->get_occ_shape();
        PackedInt32Array open;
        const TopTools_IndexedMapOfShape& target_edges = target->edge_map();
        const TopTools_IndexedDataMapOfShapeListOfShape& target_edge_faces = target->edge_face_map();
        for (int e = 1; e <= target_edges.Extent(); ++e) {
            const TopoDS_Edge& edge = TopoDS::Edge(target_edges(e));
            const int index = target_edge_faces.FindIndex(edge);
            if (index > 0 && target_edge_faces(index).Extent() == 1 && !BRep_Tool::Degenerated(edge)
                && !BRep_Tool::IsClosed(edge, TopoDS::Face(target_edge_faces(index).First()))) {
                open.push_back(e - 1);
            }
        }
        if (!open.is_empty()) {
            Dictionary grow;
            grow["distance"] = size;
            grow["mode"] = "natural";
            grow["tag"] = String(tag.c_str());
            String grow_error;
            String note;
            const Shape grown = extend(target, open, grow, grow_error, note);
            if (usable(grown)) {
                cutter = grown->get_occ_shape();
            }
        }
        // Every part of the faces must see the target along their normal, one way or the other.
        const double reach = size * 4.0;
        IntCurvesFace_ShapeIntersector hits;
        hits.Load(cutter, Precision::Confusion());
        auto crosses = [&](const gp_Pnt& from, double lo, double hi) {
            hits.Perform(gp_Lin(from, n), lo, hi);
            return hits.IsDone() && hits.NbPnt() > 0;
        };
        for (const TopoDS_Face& face : picked) {
            double u1 = 0.0, u2 = 0.0, v1 = 0.0, v2 = 0.0;
            BRepTools::UVBounds(face, u1, u2, v1, v2);
            BRepClass_FaceClassifier inside;
            BRepAdaptor_Surface surface(face);
            for (int i = 0; i <= 4; ++i) {
                for (int j = 0; j <= 4; ++j) {
                    const gp_Pnt2d uv(u1 + (u2 - u1) * (0.05 + 0.9 * i / 4.0), v1 + (v2 - v1) * (0.05 + 0.9 * j / 4.0));
                    inside.Perform(face, uv, Precision::PConfusion());
                    if (inside.State() == TopAbs_IN && !crosses(surface.Value(uv.X(), uv.Y()), -reach, reach)) {
                        error = "The target doesn't reach across all of the faces to replace";
                        return Shape();
                    }
                }
            }
        }
        // Each face's prism out (+n) and in (-n), cut by the target. Every point of a face moves
        // along n to the target's crossing of its normal line nearest the face (a closed target,
        // a rod or a sphere, crosses it twice): what lies out short of that crossing is added,
        // what lies in short of it is cut away.
        auto moves = [&](const gp_Pln& plane, const gp_Pnt& point) {
            const double height = gp_Vec(plane.Location(), point).Dot(gp_Vec(n));
            hits.Perform(gp_Lin(point, n), -reach, reach);
            double nearest = 0.0;
            for (int i = 1; hits.IsDone() && i <= hits.NbPnt(); ++i) {
                const double crossing = height + hits.WParameter(i);
                nearest = nearest == 0.0 || std::abs(crossing) < std::abs(nearest) ? crossing : nearest;
            }
            return nearest != 0.0 && (height > 0.0 ? height < nearest : height > nearest);
        };
        std::vector<TopoDS_Shape> adds;
        std::vector<TopoDS_Shape> cuts;
        for (const TopoDS_Face& face : picked) {
            const gp_Pln plane = BRepAdaptor_Surface(face).Plane();
            for (const double way : {1.0, -1.0}) {
                const TopoDS_Shape prism = BRepPrimAPI_MakePrism(face, gp_Vec(n) * (way * reach), true).Shape();
                BRepAlgoAPI_Splitter splitter;
                TopTools_ListOfShape arguments;
                TopTools_ListOfShape tools;
                arguments.Append(prism);
                tools.Append(cutter);
                splitter.SetArguments(arguments);
                splitter.SetTools(tools);
                splitter.Build();
                if (!splitter.IsDone()) {
                    error = "The target could not cut through the faces' prisms";
                    return Shape();
                }
                for (TopExp_Explorer it(splitter.Shape(), TopAbs_SOLID); it.More(); it.Next()) {
                    gp_Pnt point;
                    if (inside_point(it.Current(), point) && moves(plane, point)) {
                        (way > 0.0 ? adds : cuts).push_back(it.Current());
                    }
                }
            }
        }
        if (adds.empty() && cuts.empty()) {
            error = "The faces already lie on the target";
            return Shape();
        }
        Shape result = shape;
        if (!adds.empty()) {
            result = boolean(result, named(make_compound(adds), tag + ":add"), 0, tag, error);
        }
        if (usable(result) && !cuts.empty()) {
            result = boolean(result, named(make_compound(cuts), tag + ":cut"), 1, tag, error);
        }
        if (!usable(result)) {
            return Shape();
        }
        // The faces now on the target take the replaced faces' name.
        const std::string name = size_t(ids[0]) < shape->face_name_list.size() ? shape->face_name_list[ids[0]] : tag + ":target";
        const TopTools_IndexedMapOfShape& faces = result->face_map();
        int moved = 0;
        for (int i = 1; i <= faces.Extent(); ++i) {
            const TopoDS_Face& face = TopoDS::Face(faces(i));
            double u1 = 0.0, u2 = 0.0, v1 = 0.0, v2 = 0.0;
            BRepTools::UVBounds(face, u1, u2, v1, v2);
            BRepClass_FaceClassifier inside;
            BRepAdaptor_Surface surface(face);
            for (int k = 0; k < 9; ++k) {
                const gp_Pnt2d uv(u1 + (u2 - u1) * (0.1 + 0.4 * (k % 3)), v1 + (v2 - v1) * (0.1 + 0.4 * (k / 3)));
                inside.Perform(face, uv, Precision::PConfusion());
                if (inside.State() != TopAbs_IN) {
                    continue;
                }
                BRepExtrema_DistShapeShape gap(BRepBuilderAPI_MakeVertex(surface.Value(uv.X(), uv.Y())).Vertex(), cutter);
                if (gap.IsDone() && gap.Value() < size * 1e-7) {
                    result->face_name_list[i - 1] = moved == 0 ? name : name + "#" + std::to_string(moved);
                    ++moved;
                }
                break;
            }
        }
        naming::name_edges(*result.ptr());
        return result;
    }
    catch (const Standard_Failure& failure) {
        error = String("Replace Face failed: ") + failure.GetMessageString();
        return Shape();
    }
}

Shape boundary_fill(const Array& tools, const PackedVector3Array& keep_points, const std::string& tag, String& error)
{
    try {
        BOPAlgo_MakerVolume maker;
        TopTools_ListOfShape arguments;
        for (int64_t i = 0; i < tools.size(); ++i) {
            Ref<CadShape> tool = tools[i];
            if (usable(tool)) {
                arguments.Append(tool->get_occ_shape());
            }
        }
        maker.SetArguments(arguments);
        maker.SetIntersect(true);
        maker.Perform();
        if (maker.HasErrors()) {
            error = "No closed cells were found";
            return Shape();
        }
        std::vector<TopoDS_Shape> kept;
        for (TopExp_Explorer it(maker.Shape(), TopAbs_SOLID); it.More(); it.Next()) {
            bool keep = keep_points.is_empty();
            for (int64_t k = 0; k < keep_points.size() && !keep; ++k) {
                BRepClass3d_SolidClassifier classifier(it.Current(), P(keep_points[k]), 1e-7);
                keep = classifier.State() == TopAbs_IN;
            }
            if (keep) {
                kept.push_back(it.Current());
            }
        }
        if (kept.empty()) {
            error = "No cells were chosen";
            return Shape();
        }
        return named(kept.size() == 1 ? kept[0] : make_compound(kept), tag);
    }
    catch (const Standard_Failure& failure) {
        error = String("Boundary Fill failed: ") + failure.GetMessageString();
        return Shape();
    }
}

Shape rib(const Shape& shape, const Shape& wire, const Dictionary& p, String& error)
{
    if (!usable(shape) || !usable(wire)) {
        error = "Rib needs a body and an open curve";
        return Shape();
    }
    const std::string tag = tag_of(p, "rib");
    try {
        // A thin slab in the rib's plane, minus the body, split along the curve: the piece the
        // body's faces and the curve close in (it doesn't reach the slab's edge) is the rib.
        const gp_Pnt origin = P(p.get("plane_origin", Vector3()));
        const gp_Dir normal = D(Vector3(p.get("plane_normal", Vector3(0, 0, 1))).normalized());
        const double thickness = p.get("thickness", 0.002);
        const bool symmetric = p.get("symmetric", true);
        const double reach = diagonal(shape->get_occ_shape()) * 2.0 + 0.01;
        const gp_Pln plane(origin, normal);
        TopoDS_Face sheet = BRepBuilderAPI_MakeFace(plane, -reach, reach, -reach, reach).Face();
        gp_Trsf shift;
        shift.SetTranslation(gp_Vec(normal) * (symmetric ? -thickness * 0.5 : 0.0));
        const TopoDS_Shape slab = BRepPrimAPI_MakePrism(BRepBuilderAPI_Transform(sheet, shift, true).Shape(), gp_Vec(normal) * thickness).Shape();
        const TopoDS_Shape empty_space = BRepAlgoAPI_Cut(slab, shape->get_occ_shape()).Shape();
        gp_Trsf back;
        back.SetTranslation(gp_Vec(normal) * (-thickness * 2.0));
        const TopoDS_Shape wall = BRepPrimAPI_MakePrism(BRepBuilderAPI_Transform(wire->get_occ_shape(), back, true).Shape(), gp_Vec(normal) * (thickness * 4.0)).Shape();
        BRepAlgoAPI_Splitter splitter;
        TopTools_ListOfShape arguments;
        TopTools_ListOfShape tools;
        arguments.Append(empty_space);
        tools.Append(wall);
        splitter.SetArguments(arguments);
        splitter.SetTools(tools);
        splitter.Build();
        if (!splitter.IsDone()) {
            error = "The rib's region could not be found";
            return Shape();
        }
        Bnd_Box slab_box;
        BRepBndLib::Add(slab, slab_box);
        double sx0, sy0, sz0, sx1, sy1, sz1;
        slab_box.Get(sx0, sy0, sz0, sx1, sy1, sz1);
        const double edge_gap = reach * 0.05;
        std::vector<TopoDS_Shape> pieces;
        for (TopExp_Explorer it(splitter.Shape(), TopAbs_SOLID); it.More(); it.Next()) {
            Bnd_Box box;
            BRepBndLib::Add(it.Current(), box);
            double x0, y0, z0, x1, y1, z1;
            box.Get(x0, y0, z0, x1, y1, z1);
            // The slab is thin along the normal; check only its wide directions.
            auto reaches = [&](double lo, double hi, double slab_lo, double slab_hi) {
                return slab_hi - slab_lo > reach && (lo < slab_lo + edge_gap || hi > slab_hi - edge_gap);
            };
            if (reaches(x0, x1, sx0, sx1) || reaches(y0, y1, sy0, sy1) || reaches(z0, z1, sz0, sz1)) {
                continue;
            }
            BRepExtrema_DistShapeShape touch(it.Current(), wire->get_occ_shape());
            if (touch.IsDone() && touch.Value() < thickness) {
                pieces.push_back(it.Current());
            }
        }
        if (pieces.empty()) {
            error = "The curve doesn't close off a region against the body (do its ends touch the body?)";
            return Shape();
        }
        Shape rib_body = named(pieces.size() == 1 ? pieces[0] : make_compound(pieces), tag);
        return boolean(shape, rib_body, 0, tag, error);
    }
    catch (const Standard_Failure& failure) {
        error = String("Rib failed: ") + failure.GetMessageString();
        return Shape();
    }
}
Shape wire_from_edges(const Shape& shape, const PackedInt32Array& edges, String& error)
{
    std::vector<TopoDS_Shape> list;
    for (const TopoDS_Edge& edge : pick_edges(shape, edges)) {
        list.push_back(edge);
    }
    TopoDS_Wire wire = connect(make_compound(list), error);
    return wire.IsNull() ? Shape() : CadShape::wrap(wire);
}

Shape offset_profile(const Shape& face, double distance, String& error)
{
    if (!usable(face)) {
        error = "No profile to offset";
        return Shape();
    }
    try {
        std::vector<TopoDS_Shape> faces;
        for (const TopoDS_Face& f : faces_of(face->get_occ_shape())) {
            BRepOffsetAPI_MakeOffset maker(f, GeomAbs_Arc);
            maker.Perform(distance);
            if (!maker.IsDone()) {
                error = "The profile can't be offset that far";
                return Shape();
            }
            // The outer result wire bounds the new face; any others are its holes.
            Handle(Geom_Surface) surface = BRep_Tool::Surface(f);
            TopoDS_Face built;
            std::vector<TopoDS_Wire> wires;
            for (TopExp_Explorer w(maker.Shape(), TopAbs_WIRE); w.More(); w.Next()) {
                wires.push_back(TopoDS::Wire(w.Current()));
            }
            double biggest = -1.0;
            size_t outer = 0;
            for (size_t i = 0; i < wires.size(); ++i) {
                GProp_GProps props;
                BRepGProp::SurfaceProperties(BRepBuilderAPI_MakeFace(wires[i], true).Face(), props);
                if (std::abs(props.Mass()) > biggest) {
                    biggest = std::abs(props.Mass());
                    outer = i;
                }
            }
            if (wires.empty()) {
                continue;
            }
            BRepBuilderAPI_MakeFace builder(BRepBuilderAPI_MakeFace(wires[outer], true).Face());
            TopoDS_Shape result = builder.Face();
            for (size_t i = 0; i < wires.size(); ++i) {
                if (i != outer) {
                    result = BRepAlgoAPI_Cut(result, BRepBuilderAPI_MakeFace(wires[i], true).Face()).Shape();
                }
            }
            for (TopExp_Explorer it(result, TopAbs_FACE); it.More(); it.Next()) {
                faces.push_back(it.Current());
            }
        }
        if (faces.empty()) {
            error = "The offset profile vanished";
            return Shape();
        }
        return named(faces.size() == 1 ? faces[0] : make_compound(faces), "profile");
    }
    catch (const Standard_Failure& failure) {
        error = String("Profile offset failed: ") + failure.GetMessageString();
        return Shape();
    }
}

Shape wire_outline(const Shape& wire, double half_width, const Vector3& normal, String& error)
{
    if (!usable(wire)) {
        error = "No curve to thicken";
        return Shape();
    }
    try {
        const TopoDS_Wire spine = connect(wire->get_occ_shape(), error);
        if (spine.IsNull()) {
            return Shape();
        }
        std::vector<TopoDS_Edge> edges;
        for (TopExp_Explorer it(spine, TopAbs_EDGE); it.More(); it.Next()) {
            edges.push_back(TopoDS::Edge(it.Current()));
        }
        if (edges.size() == 1 && BRepAdaptor_Curve(edges[0]).GetType() == GeomAbs_Line && Vector3(normal).length() > 1e-9) {
            // One straight line has no plane of its own: build its slot outline directly.
            BRepAdaptor_Curve line(edges[0]);
            const gp_Pnt a = line.Value(line.FirstParameter());
            const gp_Pnt b = line.Value(line.LastParameter());
            const gp_Vec along = gp_Vec(a, b).Normalized();
            const gp_Vec side = gp_Vec(D(normal.normalized())).Crossed(along).Normalized() * half_width;
            const gp_Pnt a1 = a.Translated(side);
            const gp_Pnt b1 = b.Translated(side);
            const gp_Pnt b2 = b.Translated(-side);
            const gp_Pnt a2 = a.Translated(-side);
            BRepBuilderAPI_MakeWire outline;
            outline.Add(BRepBuilderAPI_MakeEdge(a1, b1).Edge());
            outline.Add(BRepBuilderAPI_MakeEdge(GC_MakeArcOfCircle(b1, b.Translated(along * half_width), b2).Value()).Edge());
            outline.Add(BRepBuilderAPI_MakeEdge(b2, a2).Edge());
            outline.Add(BRepBuilderAPI_MakeEdge(GC_MakeArcOfCircle(a2, a.Translated(-along * half_width), a1).Value()).Edge());
            return named(BRepBuilderAPI_MakeFace(outline.Wire(), true).Face(), "outline");
        }
        BRepOffsetAPI_MakeOffset maker;
        maker.Init(GeomAbs_Arc, false);
        maker.AddWire(spine);
        maker.Perform(half_width);
        if (!maker.IsDone()) {
            error = "The curve can't be thickened that much";
            return Shape();
        }
        for (TopExp_Explorer w(maker.Shape(), TopAbs_WIRE); w.More(); w.Next()) {
            return named(BRepBuilderAPI_MakeFace(TopoDS::Wire(w.Current()), true).Face(), "outline");
        }
        error = "The thickened curve has no outline";
        return Shape();
    }
    catch (const Standard_Failure& failure) {
        error = String("Thickening the curve failed: ") + failure.GetMessageString();
        return Shape();
    }
}

Shape mirror(const Shape& shape, const Vector3& origin, const Vector3& normal, const std::string& tag, String& error)
{
    if (!usable(shape)) {
        error = "Nothing to mirror";
        return Shape();
    }
    try {
        gp_Trsf reflection;
        reflection.SetMirror(gp_Ax2(P(origin), D(normal.normalized())));
        BRepBuilderAPI_Transform maker(shape->get_occ_shape(), reflection, true);
        Shape out = CadShape::wrap(maker.Shape());
        naming::name_result(*out.ptr(), &maker, {shape.ptr()}, tag);
        return out;
    }
    catch (const Standard_Failure& failure) {
        error = String("Mirror failed: ") + failure.GetMessageString();
        return Shape();
    }
}

Shape plane_face(const Vector3& origin, const Vector3& normal, double size, const std::string& tag)
{
    const gp_Pln plane(P(origin), D(normal.normalized()));
    Shape out = CadShape::wrap(BRepBuilderAPI_MakeFace(plane, -size, size, -size, size).Face());
    out->face_name_list = {tag};
    naming::name_edges(*out.ptr());
    return out;
}

Shape vertex(const Vector3& point)
{
    return CadShape::wrap(BRepBuilderAPI_MakeVertex(P(point)).Vertex());
}

Shape compound(const Array& shapes)
{
    std::vector<TopoDS_Shape> list;
    std::vector<std::string> faces;
    std::vector<std::string> edges;
    for (int64_t i = 0; i < shapes.size(); ++i) {
        Ref<CadShape> s = shapes[i];
        if (usable(s)) {
            list.push_back(s->get_occ_shape());
        }
    }
    Shape out = CadShape::wrap(make_compound(list));
    // Names follow each part (the compound's maps list parts in order).
    TopTools_IndexedMapOfShape all = map_of(out->get_occ_shape(), TopAbs_FACE);
    out->face_name_list.assign(all.Extent(), "");
    for (int64_t i = 0; i < shapes.size(); ++i) {
        Ref<CadShape> s = shapes[i];
        if (!usable(s)) {
            continue;
        }
        TopTools_IndexedMapOfShape part = map_of(s->get_occ_shape(), TopAbs_FACE);
        for (int k = 1; k <= part.Extent(); ++k) {
            const int j = all.FindIndex(part(k));
            if (j > 0 && size_t(k - 1) < s->face_name_list.size()) {
                out->face_name_list[j - 1] = s->face_name_list[k - 1];
            }
        }
    }
    naming::name_edges(*out.ptr());
    TopTools_IndexedMapOfShape all_edges = map_of(out->get_occ_shape(), TopAbs_EDGE);
    for (int64_t i = 0; i < shapes.size(); ++i) {
        Ref<CadShape> s = shapes[i];
        if (!usable(s)) {
            continue;
        }
        TopTools_IndexedMapOfShape part = map_of(s->get_occ_shape(), TopAbs_EDGE);
        for (int k = 1; k <= part.Extent(); ++k) {
            const int j = all_edges.FindIndex(part(k));
            if (j > 0 && size_t(k - 1) < s->edge_name_list.size() && !s->edge_name_list[k - 1].empty()) {
                out->edge_name_list[j - 1] = s->edge_name_list[k - 1];
            }
        }
    }
    return out;
}

Dictionary closest_points(const Shape& a, const Shape& b, String& error)
{
    Dictionary result;
    if (!usable(a) || !usable(b)) {
        error = "Two shapes are needed";
        return result;
    }
    try {
        // Measured in millimetres: OCCT's search on a spline face compares squared distances
        // against its parameter tolerance, which on a face a few centimetres across in metres
        // skips the face's inside and settles on its edges. (Each face keeps its tolerance, see
        // scaled_copy.)
        gp_Trsf up;
        up.SetScale(gp::Origin(), 1000.0);
        BRepExtrema_DistShapeShape distance(measure::scaled_copy(a->get_occ_shape(), up), measure::scaled_copy(b->get_occ_shape(), up));
        if (!distance.IsDone() || distance.NbSolution() == 0) {
            error = "No distance found";
            return result;
        }
        const gp_Pnt pa(distance.PointOnShape1(1).XYZ() / 1000.0);
        const gp_Pnt pb(distance.PointOnShape2(1).XYZ() / 1000.0);
        result["distance"] = distance.Value() / 1000.0;
        result["a"] = Vector3(real_t(pa.X()), real_t(pa.Y()), real_t(pa.Z()));
        result["b"] = Vector3(real_t(pb.X()), real_t(pb.Y()), real_t(pb.Z()));
    }
    catch (const Standard_Failure& failure) {
        error = String("Distance failed: ") + failure.GetMessageString();
    }
    return result;
}

Shape section(const Shape& solid, const Vector3& origin, const Vector3& normal, String& error)
{
    if (!usable(solid)) {
        error = "Pick a solid to section";
        return Shape();
    }
    if (normal.length() < 1e-12) {
        error = "The section plane needs a direction";
        return Shape();
    }
    try {
        Bnd_Box box;
        BRepBndLib::Add(solid->get_occ_shape(), box);
        if (box.IsVoid()) {
            return named(make_compound({}), "section");
        }
        // Worked on at least OFFSET_SIZE across: OCCT's common of a stitched G1 cap 0.5 mm across
        // and a plane came out empty, and of a thickened one 2 mm across without its hole.
        const double size = std::sqrt(box.SquareExtent());
        const gp_Pnt middle((box.CornerMin().XYZ() + box.CornerMax().XYZ()) * 0.5);
        const double factor = size < OFFSET_SIZE ? OFFSET_SIZE / std::max(size, 1e-12) : 1.0;
        gp_Trsf grow;
        if (factor != 1.0) {
            grow.SetScale(middle, factor);
        }
        const TopoDS_Shape body = factor != 1.0 ? BRepBuilderAPI_Transform(solid->get_occ_shape(), grow, true).Shape() : solid->get_occ_shape();
        // A square of the plane about the body's middle dropped onto it, wider than the body.
        const gp_Dir n = D(normal);
        const gp_Pnt on = P(origin).Transformed(grow);
        const gp_Pnt centre = middle.Translated(gp_Vec(n) * gp_Vec(middle, on).Dot(gp_Vec(n)));
        const double half = size * factor;
        const TopoDS_Face plane = BRepBuilderAPI_MakeFace(gp_Pln(centre, n), -half, half, -half, half).Face();
        BRepAlgoAPI_Common common(body, plane);
        BRepAlgoAPI_Section crossing(body, plane);
        if (!common.IsDone() || !crossing.IsDone()) {
            error = "The section through this body could not be made";
            return Shape();
        }
        // Its faces that meet along an edge merged into one, as a boolean's are: where the plane only
        // touches a hole along a line, OCCT splits the face there along a curve it can only place
        // to within a few micrometres, and on a turned body the faces either side of it came out
        // overlapping by a strip too thin to see (a stepped block 5e-5 big) or parted by one
        // (refused). Merged, the face ends at the body's outline alone.
        ShapeUpgrade_UnifySameDomain merged(common.Shape(), true, true, true);
        merged.Build();
        std::vector<TopoDS_Face> faces;
        for (TopExp_Explorer it(merged.Shape(), TopAbs_FACE); it.More(); it.Next()) {
            faces.push_back(TopoDS::Face(it.Current()));
        }
        // Checked on both sides of every curve where the plane crosses the body's faces (a short
        // step across it, in the plane): the faces made cover the plane there exactly where the body
        // is (a lost face or hole shows as a side the body fills and no face covers, or the other
        // way round). Points the body or a face only touches (within tolerance) aren't counted: a
        // plane along a face (a step's top), or touching a hole or a side along a line, crosses
        // there without either side changing. And their edges run no longer than those crossings
        // (a stray face adds outline). (Round 4 matched the outline against the crossings that
        // close into loops, which a plane along a step's top or a hole's side doesn't make.)
        std::vector<std::unique_ptr<BRepClass3d_SolidClassifier>> solids;
        for (TopExp_Explorer it(body, TopAbs_SOLID); it.More(); it.Next()) {
            solids.push_back(std::make_unique<BRepClass3d_SolidClassifier>(it.Current()));
        }
        const double tolerance = std::max(Precision::Confusion(), 1e-9 * half);
        const double step = 1e-4 * half;
        // (Each face's plane, to find a point's place on it directly: projecting each onto a face
        // with a hundred holes doubled the time.)
        std::vector<Handle(Geom_Plane)> planes;
        for (const TopoDS_Face& face : faces) {
            planes.push_back(Handle(Geom_Plane)::DownCast(BRep_Tool::Surface(face)));
        }
        double crossed = 0.0;
        double wrong = 0.0;
        TopoDS_Shape skin;
        int crossing_edges = 0;
        for (TopExp_Explorer it(crossing.Shape(), TopAbs_EDGE); it.More(); it.Next()) {
            ++crossing_edges;
        }
        // (Three looks along each crossing, or one where there are many: a plate with 100 holes.)
        const std::vector<double> along = crossing_edges <= 64 ? std::vector<double>{0.2, 0.5, 0.8} : std::vector<double>{0.5};
        for (TopExp_Explorer it(crossing.Shape(), TopAbs_EDGE); it.More(); it.Next()) {
            const TopoDS_Edge& edge = TopoDS::Edge(it.Current());
            if (BRep_Tool::Degenerated(edge)) {
                continue;
            }
            const double length = measure::length(edge);
            crossed += length;
            const BRepAdaptor_Curve curve(edge);
            for (const double share : along) {
                gp_Pnt at;
                gp_Vec heading;
                curve.D1(curve.FirstParameter() + (curve.LastParameter() - curve.FirstParameter()) * share, at, heading);
                const gp_Vec across = gp_Vec(n).Crossed(heading);
                if (across.Magnitude() < 1e-12 * heading.Magnitude() || heading.Magnitude() < 1e-300) {
                    continue;
                }
                for (const double side : {1.0, -1.0}) {
                    const gp_Pnt point = at.Translated(across.Normalized() * (side * step));
                    bool touched = false;
                    bool inside = false;
                    for (const auto& solid : solids) {
                        solid->Perform(point, tolerance);
                        touched = touched || solid->State() == TopAbs_ON;
                        inside = inside || solid->State() == TopAbs_IN;
                    }
                    bool covered = false;
                    for (size_t f = 0; f < faces.size(); ++f) {
                        BRepClass_FaceClassifier on_face;
                        if (planes[f].IsNull()) {
                            on_face.Perform(faces[f], point, tolerance);
                        }
                        else {
                            double u = 0.0;
                            double v = 0.0;
                            ElSLib::Parameters(planes[f]->Pln(), point, u, v);
                            on_face.Perform(faces[f], gp_Pnt2d(u, v), tolerance);
                        }
                        touched = touched || on_face.State() == TopAbs_ON;
                        covered = covered || on_face.State() == TopAbs_IN;
                    }
                    if (!touched && inside != covered) {
                        // (Measured, where they disagree: the classifier's rays graze a face the
                        // plane is tangent to, and a point a nanometre above a turned hole's top
                        // read as outside the body.)
                        // (Measured to its faces: to the solid, a point read as inside is at 0.)
                        if (skin.IsNull()) {
                            const std::vector<TopoDS_Face> body_faces = faces_of(body);
                            skin = make_compound(std::vector<TopoDS_Shape>(body_faces.begin(), body_faces.end()));
                        }
                        const BRepExtrema_DistShapeShape gap(BRepBuilderAPI_MakeVertex(point).Vertex(), skin);
                        touched = gap.IsDone() && gap.NbSolution() > 0 && gap.Value() <= tolerance;
                    }
                    if (!touched && inside != covered) {
                        wrong += length / (2.0 * double(along.size()));
                    }
                }
            }
        }
        TopoDS_Shape made = make_compound(std::vector<TopoDS_Shape>(faces.begin(), faces.end()));
        TopTools_IndexedMapOfShape rims;
        TopExp::MapShapes(made, TopAbs_EDGE, rims);
        double rim = 0.0;
        for (int i = 1; i <= rims.Extent(); ++i) {
            rim += measure::length(TopoDS::Edge(rims(i)));
        }
        // (Each finds the crossing curves on its own, to about 1e-5 of their length.)
        if (wrong > 1e-6 * crossed || rim > crossed * (1.0 + 1e-3) + 1e-9 * half) {
            char text[260];
            if (wrong > 1e-6 * crossed) {
                std::snprintf(text, sizeof(text), "The section through this body could not be made exactly (its faces miss or overrun the body along %.3g mm of the %.6g mm where the plane crosses it)",
                    wrong * 1000.0 / factor, crossed * 1000.0 / factor);
            }
            else {
                std::snprintf(text, sizeof(text), "The section through this body could not be made exactly (its outline, %.6g mm long, runs past where the plane crosses the body, %.6g mm)",
                    rim * 1000.0 / factor, crossed * 1000.0 / factor);
            }
            error = text;
            return Shape();
        }
        if (factor != 1.0) {
            made = BRepBuilderAPI_Transform(made, grow.Inverted(), true).Shape();
        }
        return named(made, "section");
    }
    catch (const Standard_Failure& failure) {
        error = String("Section failed: ") + failure.GetMessageString();
        return Shape();
    }
}

}  // namespace holo_forge::ops
