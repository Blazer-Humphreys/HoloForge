#include "sketch_geometry.h"

#include <cmath>

#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

#include <BRepAdaptor_Curve.hxx>
#include <BRepAlgoAPI_Section.hxx>
#include <BRepAlgoAPI_Splitter.hxx>
#include <BRepBndLib.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepBuilderAPI_MakeWire.hxx>
#include <BRepBuilderAPI_Transform.hxx>
#include <BRepGProp.hxx>
#include <BRepOffsetAPI_MakeOffset.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
#include <BRepProj_Projection.hxx>
#include <BRepTools.hxx>
#include <BRepTools_WireExplorer.hxx>
#include <BRep_Builder.hxx>
#include <BRep_Tool.hxx>
#include <Bnd_Box.hxx>
#include <ElSLib.hxx>
#include <GCE2d_MakeArcOfCircle.hxx>
#include <GCE2d_MakeArcOfEllipse.hxx>
#include <GCE2d_MakeSegment.hxx>
#include <GCPnts_TangentialDeflection.hxx>
#include <GProp_GProps.hxx>
#include <Geom2dAPI_InterCurveCurve.hxx>
#include <Geom2dAPI_Interpolate.hxx>
#include <Geom2dAPI_ProjectPointOnCurve.hxx>
#include <Geom2dAdaptor_Curve.hxx>
#include <Geom2dConvert.hxx>
#include <Geom2d_BSplineCurve.hxx>
#include <Geom2d_BezierCurve.hxx>
#include <Geom2d_Circle.hxx>
#include <Geom2d_Ellipse.hxx>
#include <Geom2d_Line.hxx>
#include <Geom2d_TrimmedCurve.hxx>
#include <GeomAPI.hxx>
#include <GeomAdaptor_Curve.hxx>
#include <GeomProjLib.hxx>
#include <Geom_Curve.hxx>
#include <Geom_Plane.hxx>
#include <Geom_Surface.hxx>
#include <Geom_TrimmedCurve.hxx>
#include <IntRes2d_IntersectionPoint.hxx>
#include <Precision.hxx>
#include <Standard_Failure.hxx>
#include <TColStd_Array1OfInteger.hxx>
#include <TColStd_Array1OfReal.hxx>
#include <TColgp_Array1OfPnt2d.hxx>
#include <TColgp_HArray1OfPnt2d.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <TopTools_ListOfShape.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Compound.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Wire.hxx>
#include <gp_Ax2d.hxx>
#include <gp_Ax3.hxx>
#include <gp_Circ2d.hxx>
#include <gp_Elips2d.hxx>

#include "cad_shape.h"
#include "measure.h"

using namespace godot;

namespace holo_forge::sketch
{

namespace
{
constexpr double TOLERANCE = 1e-9;

gp_Pnt2d to_occ(const Vector2& v)
{
    return gp_Pnt2d(v.x, v.y);
}

Vector2 to_godot(const gp_Pnt2d& p)
{
    return Vector2(real_t(p.X()), real_t(p.Y()));
}

Vector2 plane_coords(const gp_Pln& plane, const gp_Pnt& p)
{
    double u = 0.0, v = 0.0;
    ElSLib::Parameters(plane, p, u, v);
    return Vector2(real_t(u), real_t(v));
}

double wrap_angle(double a)
{
    a = std::fmod(a, 2.0 * M_PI);
    return a < 0.0 ? a + 2.0 * M_PI : a;
}

/// True when angle lies on the counter-clockwise sweep from a0 to a1.
bool on_ccw_sweep(double a0, double a1, double angle)
{
    const double span = wrap_angle(a1 - a0);
    return wrap_angle(angle - a0) <= span + 1e-9;
}

Handle(Geom2d_Curve) first_curve(const Dictionary& curve, String& error)
{
    std::vector<Handle(Geom2d_Curve)> curves = curves_from_dict(curve, error);
    return curves.empty() ? Handle(Geom2d_Curve)() : curves.front();
}

/// Line parameters are scaled to 0..1 so callers need not know the kernel's parameterization.
double normalized_param(const Dictionary& curve, const Handle(Geom2d_Curve)& c, double u)
{
    if (String(curve.get("type", "")) == "line") {
        const double first = c->FirstParameter();
        const double last = c->LastParameter();
        return last - first > TOLERANCE ? (u - first) / (last - first) : 0.0;
    }
    return u;
}

TopTools_IndexedMapOfShape sub_shapes(const TopoDS_Shape& shape, TopAbs_ShapeEnum type)
{
    TopTools_IndexedMapOfShape map;
    TopExp::MapShapes(shape, type, map);
    return map;
}

TopoDS_Shape faces_compound(const TopoDS_Shape& shape, const std::vector<int>& face_ids)
{
    if (face_ids.empty()) {
        return shape;
    }
    TopTools_IndexedMapOfShape faces = sub_shapes(shape, TopAbs_FACE);
    BRep_Builder builder;
    TopoDS_Compound compound;
    builder.MakeCompound(compound);
    for (int id : face_ids) {
        if (id >= 0 && id < faces.Extent()) {
            builder.Add(compound, faces(id + 1));
        }
    }
    return compound;
}

PackedVector3Array sample_edge_3d(const TopoDS_Edge& edge, double deflection)
{
    PackedVector3Array points;
    if (BRep_Tool::Degenerated(edge)) {
        return points;
    }
    BRepAdaptor_Curve curve(edge);
    GCPnts_TangentialDeflection sampler(curve, 0.15, deflection);
    for (int i = 1; i <= sampler.NbPoints(); ++i) {
        const gp_Pnt p = sampler.Value(i);
        points.push_back(Vector3(real_t(p.X()), real_t(p.Y()), real_t(p.Z())));
    }
    if (edge.Orientation() == TopAbs_REVERSED) {
        points.reverse();
    }
    return points;
}

Array polylines_of(const TopoDS_Shape& shape, double deflection)
{
    Array result;
    for (TopExp_Explorer it(shape, TopAbs_EDGE); it.More(); it.Next()) {
        PackedVector3Array points = sample_edge_3d(TopoDS::Edge(it.Current()), deflection);
        if (points.size() > 1) {
            result.push_back(points);
        }
    }
    return result;
}
}  // namespace

gp_Pln to_plane(const Transform3D& plane)
{
    const Vector3 o = plane.origin;
    const Vector3 x = plane.basis.get_column(0).normalized();
    const Vector3 z = plane.basis.get_column(2).normalized();
    return gp_Pln(gp_Ax3(gp_Pnt(o.x, o.y, o.z), gp_Dir(z.x, z.y, z.z), gp_Dir(x.x, x.y, x.z)));
}

std::vector<Handle(Geom2d_Curve)> curves_from_dict(const Dictionary& d, String& error)
{
    std::vector<Handle(Geom2d_Curve)> out;
    const String type = d.get("type", "");
    try {
        if (type == "line") {
            const Vector2 a = d.get("a", Vector2());
            const Vector2 b = d.get("b", Vector2());
            if (a.distance_to(b) < TOLERANCE) {
                error = "A line has zero length";
                return out;
            }
            out.push_back(GCE2d_MakeSegment(to_occ(a), to_occ(b)).Value());
        }
        else if (type == "circle" || type == "arc") {
            const double r = d.get("r", 0.0);
            if (r <= TOLERANCE) {
                error = "A circle needs a positive radius";
                return out;
            }
            gp_Circ2d circle(gp_Ax2d(to_occ(d.get("c", Vector2())), gp_Dir2d(1.0, 0.0)), r);
            if (type == "circle") {
                out.push_back(new Geom2d_Circle(circle));
            }
            else {
                const double a0 = d.get("a0", 0.0);
                double a1 = d.get("a1", 0.0);
                while (a1 <= a0) {
                    a1 += 2.0 * M_PI;
                }
                out.push_back(GCE2d_MakeArcOfCircle(circle, a0, a1, true).Value());
            }
        }
        else if (type == "ellipse" || type == "ellipse_arc") {
            const Vector2 major = d.get("major", Vector2(1, 0));
            const double major_r = major.length();
            const double minor_r = d.get("minor", 0.0);
            if (minor_r <= TOLERANCE || major_r < minor_r) {
                error = "An ellipse needs 0 < minor radius <= major radius";
                return out;
            }
            gp_Elips2d ellipse(gp_Ax2d(to_occ(d.get("c", Vector2())), gp_Dir2d(major.x, major.y)), major_r, minor_r);
            if (type == "ellipse") {
                out.push_back(new Geom2d_Ellipse(ellipse));
            }
            else {
                const double a0 = d.get("a0", 0.0);
                double a1 = d.get("a1", 0.0);
                while (a1 <= a0) {
                    a1 += 2.0 * M_PI;
                }
                out.push_back(GCE2d_MakeArcOfEllipse(ellipse, a0, a1, true).Value());
            }
        }
        else if (type == "bspline") {
            const PackedVector2Array poles_in = d.get("poles", PackedVector2Array());
            const int n = int(poles_in.size());
            const bool periodic = d.get("periodic", false);
            int degree = d.get("degree", 3);
            degree = std::max(1, std::min(degree, n - 1));
            if (n < 2) {
                error = "A spline needs at least 2 points";
                return out;
            }
            TColgp_Array1OfPnt2d poles(1, n);
            TColStd_Array1OfReal weights(1, n);
            const PackedFloat64Array weights_in = d.get("weights", PackedFloat64Array());
            for (int i = 0; i < n; ++i) {
                poles.SetValue(i + 1, to_occ(poles_in[i]));
                weights.SetValue(i + 1, i < weights_in.size() ? weights_in[i] : 1.0);
            }
            const PackedFloat64Array knots_in = d.get("knots", PackedFloat64Array());
            const PackedInt32Array mults_in = d.get("mults", PackedInt32Array());
            if (!knots_in.is_empty() && knots_in.size() == mults_in.size()) {
                TColStd_Array1OfReal knots(1, int(knots_in.size()));
                TColStd_Array1OfInteger mults(1, int(mults_in.size()));
                for (int i = 0; i < knots_in.size(); ++i) {
                    knots.SetValue(i + 1, knots_in[i]);
                    mults.SetValue(i + 1, mults_in[i]);
                }
                out.push_back(new Geom2d_BSplineCurve(poles, weights, knots, mults, degree, periodic));
            }
            else if (periodic) {
                TColStd_Array1OfReal knots(1, n + 1);
                TColStd_Array1OfInteger mults(1, n + 1);
                for (int i = 1; i <= n + 1; ++i) {
                    knots.SetValue(i, double(i - 1));
                    mults.SetValue(i, 1);
                }
                out.push_back(new Geom2d_BSplineCurve(poles, weights, knots, mults, degree, true));
            }
            else {
                // Uniform, clamped: the curve starts and ends on the first and last control points.
                const int count = n - degree + 1;
                TColStd_Array1OfReal knots(1, count);
                TColStd_Array1OfInteger mults(1, count);
                for (int i = 1; i <= count; ++i) {
                    knots.SetValue(i, double(i - 1));
                    mults.SetValue(i, (i == 1 || i == count) ? degree + 1 : 1);
                }
                out.push_back(new Geom2d_BSplineCurve(poles, weights, knots, mults, degree, false));
            }
        }
        else if (type == "interp") {
            const PackedVector2Array points = d.get("points", PackedVector2Array());
            const bool periodic = d.get("periodic", false);
            if (points.size() < 2) {
                error = "A fit-point spline needs at least 2 points";
                return out;
            }
            Handle(TColgp_HArray1OfPnt2d) array = new TColgp_HArray1OfPnt2d(1, int(points.size()));
            for (int i = 0; i < points.size(); ++i) {
                array->SetValue(i + 1, to_occ(points[i]));
            }
            Geom2dAPI_Interpolate interpolate(array, periodic, TOLERANCE);
            interpolate.Perform();
            if (!interpolate.IsDone()) {
                error = "The fit points could not be interpolated";
                return out;
            }
            out.push_back(interpolate.Curve());
        }
        else if (type == "conic") {
            TColgp_Array1OfPnt2d poles(1, 3);
            TColStd_Array1OfReal weights(1, 3);
            poles.SetValue(1, to_occ(d.get("a", Vector2())));
            poles.SetValue(2, to_occ(d.get("shoulder", Vector2())));
            poles.SetValue(3, to_occ(d.get("b", Vector2())));
            weights.SetValue(1, 1.0);
            weights.SetValue(2, std::max(double(d.get("weight", 1.0)), 1e-6));
            weights.SetValue(3, 1.0);
            out.push_back(new Geom2d_BezierCurve(poles, weights));
        }
        else if (type == "polyline") {
            const PackedVector2Array points = d.get("points", PackedVector2Array());
            const bool closed = d.get("closed", false);
            const int count = int(points.size());
            for (int i = 0; i + 1 < count + (closed ? 1 : 0); ++i) {
                const Vector2 a = points[i];
                const Vector2 b = points[(i + 1) % count];
                if (a.distance_to(b) > TOLERANCE) {
                    out.push_back(GCE2d_MakeSegment(to_occ(a), to_occ(b)).Value());
                }
            }
        }
        else {
            error = String("Unknown curve type '") + type + "'";
        }
    }
    catch (const Standard_Failure& failure) {
        error = String("Bad curve: ") + failure.GetMessageString();
        out.clear();
    }
    return out;
}

std::vector<TopoDS_Edge> edges_on_plane(const Array& curves, const gp_Pln& plane, String& error, std::vector<int>* entities)
{
    std::vector<TopoDS_Edge> edges;
    for (int64_t i = 0; i < curves.size(); ++i) {
        String curve_error;
        for (const Handle(Geom2d_Curve)& c : curves_from_dict(curves[i], curve_error)) {
            try {
                Handle(Geom_Curve) c3 = GeomAPI::To3d(c, plane);
                BRepBuilderAPI_MakeEdge maker(c3);
                if (maker.IsDone()) {
                    edges.push_back(maker.Edge());
                    if (entities != nullptr) {
                        entities->push_back(int(Dictionary(curves[i]).get("entity", -1)));
                    }
                }
            }
            catch (const Standard_Failure& failure) {
                curve_error = String("Bad edge: ") + failure.GetMessageString();
            }
        }
        if (curve_error != "") {
            error = curve_error;
        }
    }
    return edges;
}

Dictionary edge_to_curve(const TopoDS_Edge& edge, const gp_Pln& plane)
{
    Dictionary result;
    double first = 0.0, last = 0.0;
    Handle(Geom_Curve) c3 = BRep_Tool::Curve(edge, first, last);
    if (c3.IsNull()) {
        return result;
    }
    Handle(Geom2d_Curve) c2 = GeomAPI::To2d(c3, plane);
    Handle(Geom2d_Curve) basis = c2;
    while (Handle(Geom2d_TrimmedCurve) trimmed = Handle(Geom2d_TrimmedCurve)::DownCast(basis)) {
        basis = trimmed->BasisCurve();
    }
    const bool reversed = edge.Orientation() == TopAbs_REVERSED;
    gp_Pnt2d start = c2->Value(first);
    gp_Pnt2d end = c2->Value(last);
    const gp_Pnt2d middle = c2->Value(0.5 * (first + last));
    if (reversed) {
        std::swap(start, end);
    }
    const bool closed = start.Distance(end) < 1e-9 && std::abs(last - first) > 1e-6;

    if (Handle(Geom2d_Line)::DownCast(basis)) {
        result["type"] = "line";
        result["a"] = to_godot(start);
        result["b"] = to_godot(end);
    }
    else if (Handle(Geom2d_Circle) circle = Handle(Geom2d_Circle)::DownCast(basis)) {
        const gp_Pnt2d c = circle->Location();
        result["c"] = to_godot(c);
        result["r"] = circle->Radius();
        if (closed) {
            result["type"] = "circle";
        }
        else {
            double a0 = std::atan2(start.Y() - c.Y(), start.X() - c.X());
            double a1 = std::atan2(end.Y() - c.Y(), end.X() - c.X());
            const double am = std::atan2(middle.Y() - c.Y(), middle.X() - c.X());
            if (!on_ccw_sweep(a0, a1, am)) {
                std::swap(a0, a1);
            }
            result["type"] = "arc";
            result["a0"] = a0;
            result["a1"] = a1;
        }
    }
    else if (Handle(Geom2d_Ellipse) ellipse = Handle(Geom2d_Ellipse)::DownCast(basis)) {
        const gp_Pnt2d c = ellipse->Location();
        const gp_Dir2d x = ellipse->XAxis().Direction();
        const double major = ellipse->MajorRadius();
        const double minor = ellipse->MinorRadius();
        result["c"] = to_godot(c);
        result["major"] = Vector2(real_t(x.X() * major), real_t(x.Y() * major));
        result["minor"] = minor;
        auto eccentric = [&](const gp_Pnt2d& p) {
            const double dx = p.X() - c.X(), dy = p.Y() - c.Y();
            const double local_x = dx * x.X() + dy * x.Y();
            const double local_y = -dx * x.Y() + dy * x.X();
            return std::atan2(local_y / minor, local_x / major);
        };
        if (closed) {
            result["type"] = "ellipse";
        }
        else {
            double a0 = eccentric(start);
            double a1 = eccentric(end);
            if (!on_ccw_sweep(a0, a1, eccentric(middle))) {
                std::swap(a0, a1);
            }
            result["type"] = "ellipse_arc";
            result["a0"] = a0;
            result["a1"] = a1;
        }
    }
    else {
        Handle(Geom2d_BSplineCurve) spline = Geom2dConvert::CurveToBSplineCurve(new Geom2d_TrimmedCurve(c2, first, last));
        if (reversed) {
            spline->Reverse();
        }
        PackedVector2Array poles;
        PackedFloat64Array weights;
        for (int i = 1; i <= spline->NbPoles(); ++i) {
            poles.push_back(to_godot(spline->Pole(i)));
            weights.push_back(spline->Weight(i));
        }
        PackedFloat64Array knots;
        PackedInt32Array mults;
        for (int i = 1; i <= spline->NbKnots(); ++i) {
            knots.push_back(spline->Knot(i));
            mults.push_back(spline->Multiplicity(i));
        }
        result["type"] = "bspline";
        result["poles"] = poles;
        result["weights"] = weights;
        result["knots"] = knots;
        result["mults"] = mults;
        result["degree"] = spline->Degree();
        result["periodic"] = spline->IsPeriodic();
    }
    return result;
}

Array regions(const Array& curves, const gp_Pln& plane, double deflection, String& error)
{
    Array result;
    std::vector<int> entities;
    std::vector<TopoDS_Edge> edges = edges_on_plane(curves, plane, error, &entities);
    if (edges.empty()) {
        return result;
    }
    try {
        Bnd_Box box;
        for (const TopoDS_Edge& edge : edges) {
            BRepBndLib::Add(edge, box);
        }
        double x0, y0, z0, x1, y1, z1;
        box.Get(x0, y0, z0, x1, y1, z1);
        double umin = 1e30, umax = -1e30, vmin = 1e30, vmax = -1e30;
        for (int i = 0; i < 8; ++i) {
            const Vector2 uv = plane_coords(plane, gp_Pnt(i & 1 ? x1 : x0, i & 2 ? y1 : y0, i & 4 ? z1 : z0));
            umin = std::min(umin, double(uv.x));
            umax = std::max(umax, double(uv.x));
            vmin = std::min(vmin, double(uv.y));
            vmax = std::max(vmax, double(uv.y));
        }
        const double margin = std::max(umax - umin, vmax - vmin) * 0.25 + 1e-3;
        umin -= margin;
        umax += margin;
        vmin -= margin;
        vmax += margin;

        // Split a sheet bigger than the sketch by every curve; each piece that doesn't reach the
        // sheet's border is a closed region (a profile), holes included.
        TopoDS_Face sheet = BRepBuilderAPI_MakeFace(plane, umin, umax, vmin, vmax).Face();
        BRepAlgoAPI_Splitter splitter;
        TopTools_ListOfShape arguments;
        TopTools_ListOfShape tools;
        arguments.Append(sheet);
        for (const TopoDS_Edge& edge : edges) {
            tools.Append(edge);
        }
        splitter.SetArguments(arguments);
        splitter.SetTools(tools);
        splitter.Build();
        if (!splitter.IsDone()) {
            error = "The sketch curves could not be split into profiles";
            return result;
        }
        // Each piece of a sketch curve is named after its entity (s12, or s12#1 when split).
        std::vector<std::pair<TopoDS_Shape, std::string>> piece_names;
        for (size_t k = 0; k < edges.size(); ++k) {
            const std::string base = "s" + std::to_string(entities[k]);
            const TopTools_ListOfShape& pieces = splitter.Modified(edges[k]);
            if (pieces.IsEmpty()) {
                piece_names.push_back({edges[k], base});
                continue;
            }
            int n = 0;
            for (TopTools_ListOfShape::Iterator it(pieces); it.More(); it.Next(), ++n) {
                piece_names.push_back({it.Value(), pieces.Extent() > 1 ? base + "#" + std::to_string(n) : base});
            }
        }
        const double border = margin * 0.01;
        for (TopExp_Explorer it(splitter.Shape(), TopAbs_FACE); it.More(); it.Next()) {
            const TopoDS_Face face = TopoDS::Face(it.Current());
            double u0, u1, v0, v1;
            BRepTools::UVBounds(face, u0, u1, v0, v1);
            if (u0 < umin + border || u1 > umax - border || v0 < vmin + border || v1 > vmax - border) {
                continue;
            }
            const GProp_GProps props = measure::surface(face);
            Array loops;
            const TopoDS_Wire outer = BRepTools::OuterWire(face);
            std::vector<TopoDS_Wire> wires = {outer};
            for (TopExp_Explorer w(face, TopAbs_WIRE); w.More(); w.Next()) {
                if (!w.Current().IsSame(outer)) {
                    wires.push_back(TopoDS::Wire(w.Current()));
                }
            }
            for (const TopoDS_Wire& wire : wires) {
                PackedVector2Array loop;
                for (BRepTools_WireExplorer we(wire, face); we.More(); we.Next()) {
                    PackedVector3Array points = sample_edge_3d(we.Current(), deflection);
                    for (int64_t k = 0; k < points.size(); ++k) {
                        const Vector3 p = points[k];
                        const Vector2 uv = plane_coords(plane, gp_Pnt(p.x, p.y, p.z));
                        if (loop.is_empty() || loop[loop.size() - 1].distance_to(uv) > 1e-9) {
                            loop.push_back(uv);
                        }
                    }
                }
                if (loop.size() > 2) {
                    loops.push_back(loop);
                }
            }
            Ref<CadShape> face_shape = CadShape::wrap(face);
            face_shape->face_name_list = {"profile"};
            TopTools_IndexedMapOfShape face_edges;
            TopExp::MapShapes(face, TopAbs_EDGE, face_edges);
            for (int k = 1; k <= face_edges.Extent(); ++k) {
                std::string name = "s?";
                for (const auto& [piece, piece_name] : piece_names) {
                    if (piece.IsSame(face_edges(k))) {
                        name = piece_name;
                        break;
                    }
                }
                face_shape->edge_name_list.push_back(name);
            }
            Dictionary region;
            region["face"] = face_shape;
            region["area"] = props.Mass();
            region["loops"] = loops;
            result.push_back(region);
        }
    }
    catch (const Standard_Failure& failure) {
        error = String("Profile detection failed: ") + failure.GetMessageString();
    }
    return result;
}

Dictionary intersections(const Dictionary& a, const Dictionary& b, String& error)
{
    Dictionary result;
    PackedVector2Array points;
    PackedFloat64Array params_a;
    PackedFloat64Array params_b;
    try {
        Handle(Geom2d_Curve) ca = first_curve(a, error);
        Handle(Geom2d_Curve) cb = first_curve(b, error);
        if (!ca.IsNull() && !cb.IsNull()) {
            Geom2dAPI_InterCurveCurve inter(ca, cb, 1e-9);
            for (int i = 1; i <= inter.NbPoints(); ++i) {
                const IntRes2d_IntersectionPoint& point = inter.Intersector().Point(i);
                points.push_back(to_godot(point.Value()));
                params_a.push_back(normalized_param(a, ca, point.ParamOnFirst()));
                params_b.push_back(normalized_param(b, cb, point.ParamOnSecond()));
            }
        }
    }
    catch (const Standard_Failure& failure) {
        error = String("Intersection failed: ") + failure.GetMessageString();
    }
    result["points"] = points;
    result["params_a"] = params_a;
    result["params_b"] = params_b;
    return result;
}

Dictionary closest_point(const Dictionary& curve, const Vector2& point, String& error)
{
    Dictionary result;
    try {
        Handle(Geom2d_Curve) c = first_curve(curve, error);
        if (c.IsNull()) {
            return result;
        }
        const gp_Pnt2d p = to_occ(point);
        double best_u = c->FirstParameter();
        double best_d = c->Value(best_u).Distance(p);
        if (!Precision::IsInfinite(c->LastParameter())) {
            const double d = c->Value(c->LastParameter()).Distance(p);
            if (d < best_d) {
                best_d = d;
                best_u = c->LastParameter();
            }
        }
        Geom2dAPI_ProjectPointOnCurve projection(p, c);
        if (projection.NbPoints() > 0 && projection.LowerDistance() < best_d) {
            best_d = projection.LowerDistance();
            best_u = projection.LowerDistanceParameter();
        }
        result["point"] = to_godot(c->Value(best_u));
        result["param"] = normalized_param(curve, c, best_u);
        result["distance"] = best_d;
    }
    catch (const Standard_Failure& failure) {
        error = String("Projection failed: ") + failure.GetMessageString();
    }
    return result;
}

PackedVector2Array sample(const Dictionary& curve, double deflection, String& error)
{
    PackedVector2Array points;
    try {
        for (const Handle(Geom2d_Curve)& c : curves_from_dict(curve, error)) {
            Geom2dAdaptor_Curve adaptor(c);
            GCPnts_TangentialDeflection sampler(adaptor, 0.12, deflection);
            for (int i = 1; i <= sampler.NbPoints(); ++i) {
                // The sampler stores 2D curve points as 3D points with z = 0.
                const gp_Pnt sampled = sampler.Value(i);
                const Vector2 p(real_t(sampled.X()), real_t(sampled.Y()));
                if (points.is_empty() || points[points.size() - 1].distance_to(p) > 1e-12) {
                    points.push_back(p);
                }
            }
        }
    }
    catch (const Standard_Failure& failure) {
        error = String("Sampling failed: ") + failure.GetMessageString();
    }
    return points;
}

Array offset(const Array& chain, double distance, String& error)
{
    Array result;
    const gp_Pln plane(gp::XOY());
    std::vector<TopoDS_Edge> edges = edges_on_plane(chain, plane, error);
    if (edges.empty()) {
        return result;
    }
    try {
        BRepBuilderAPI_MakeWire wire_maker;
        for (const TopoDS_Edge& edge : edges) {
            wire_maker.Add(edge);
        }
        if (!wire_maker.IsDone()) {
            error = "Offset needs curves connected end to end";
            return result;
        }
        const TopoDS_Wire wire = wire_maker.Wire();
        const bool closed = BRep_Tool::IsClosed(wire);
        BRepOffsetAPI_MakeOffset maker;
        maker.Init(GeomAbs_Arc, !closed);
        maker.AddWire(wire);
        maker.Perform(distance);
        if (!maker.IsDone()) {
            error = "The offset could not be computed (distance too large?)";
            return result;
        }
        for (TopExp_Explorer w(maker.Shape(), TopAbs_WIRE); w.More(); w.Next()) {
            for (BRepTools_WireExplorer we(TopoDS::Wire(w.Current())); we.More(); we.Next()) {
                Dictionary curve = edge_to_curve(we.Current(), plane);
                if (!curve.is_empty()) {
                    result.push_back(curve);
                }
            }
        }
    }
    catch (const Standard_Failure& failure) {
        error = String("Offset failed: ") + failure.GetMessageString();
    }
    return result;
}

Array project_edges(const TopoDS_Shape& shape, const std::vector<int>& edge_ids, const gp_Pln& plane, String& error)
{
    Array result;
    TopTools_IndexedMapOfShape edges = sub_shapes(shape, TopAbs_EDGE);
    Handle(Geom_Plane) surface = new Geom_Plane(plane);
    for (int id : edge_ids) {
        if (id < 0 || id >= edges.Extent()) {
            continue;
        }
        const TopoDS_Edge& edge = TopoDS::Edge(edges(id + 1));
        double first = 0.0, last = 0.0;
        Handle(Geom_Curve) c3 = BRep_Tool::Curve(edge, first, last);
        if (c3.IsNull()) {
            continue;
        }
        Dictionary curve;
        try {
            Handle(Geom_Curve) projected = GeomProjLib::ProjectOnPlane(new Geom_TrimmedCurve(c3, first, last), surface, plane.Axis().Direction(), true);
            if (!projected.IsNull() && projected->Value(projected->FirstParameter()).Distance(projected->Value(projected->LastParameter())) + 1e-12 > 0.0) {
                BRepBuilderAPI_MakeEdge maker(projected);
                if (maker.IsDone()) {
                    curve = edge_to_curve(maker.Edge(), plane);
                }
            }
        }
        catch (const Standard_Failure&) {
            curve.clear();
        }
        if (curve.is_empty()) {
            // An edge along the plane's normal projects to a single point.
            curve["type"] = "point";
            curve["p"] = plane_coords(plane, c3->Value(first));
        }
        curve["source_edge"] = id;
        result.push_back(curve);
    }
    if (result.is_empty() && !edge_ids.empty()) {
        error = "No edges could be projected";
    }
    return result;
}

Array section(const TopoDS_Shape& shape, const gp_Pln& plane, String& error)
{
    Array result;
    try {
        BRepAlgoAPI_Section cut(shape, plane, false);
        cut.Approximation(true);
        cut.Build();
        if (!cut.IsDone()) {
            error = "The plane does not cut the body";
            return result;
        }
        for (TopExp_Explorer it(cut.Shape(), TopAbs_EDGE); it.More(); it.Next()) {
            Dictionary curve = edge_to_curve(TopoDS::Edge(it.Current()), plane);
            if (!curve.is_empty()) {
                result.push_back(curve);
            }
        }
    }
    catch (const Standard_Failure& failure) {
        error = String("Section failed: ") + failure.GetMessageString();
    }
    return result;
}

Array project_to_faces(const Array& curves, const gp_Pln& plane, const TopoDS_Shape& shape, const std::vector<int>& face_ids,
    const Vector3& direction, double deflection, String& error)
{
    Array result;
    std::vector<TopoDS_Edge> edges = edges_on_plane(curves, plane, error);
    const TopoDS_Shape target = faces_compound(shape, face_ids);
    const gp_Dir dir = direction.is_zero_approx() ? plane.Axis().Direction() : gp_Dir(direction.x, direction.y, direction.z);
    for (const TopoDS_Edge& edge : edges) {
        try {
            for (BRepProj_Projection projection(edge, target, dir); projection.More(); projection.Next()) {
                Array lines = polylines_of(projection.Current(), deflection);
                for (int64_t i = 0; i < lines.size(); ++i) {
                    result.push_back(lines[i]);
                }
            }
        }
        catch (const Standard_Failure& failure) {
            error = String("Projection to surface failed: ") + failure.GetMessageString();
        }
    }
    return result;
}

Array intersection_curves(const Array& curves, const gp_Pln& plane, const TopoDS_Shape& shape, const std::vector<int>& face_ids,
    double deflection, String& error)
{
    Array result;
    std::vector<TopoDS_Edge> edges = edges_on_plane(curves, plane, error);
    const TopoDS_Shape target = faces_compound(shape, face_ids);
    Bnd_Box box;
    BRepBndLib::Add(target, box);
    if (box.IsVoid()) {
        return result;
    }
    const double reach = std::sqrt(box.SquareExtent()) * 2.0 + 1.0;
    const gp_Dir normal = plane.Axis().Direction();
    for (const TopoDS_Edge& edge : edges) {
        try {
            // Sweep the curve along the sketch normal both ways, then cut the faces with it.
            gp_Trsf shift;
            shift.SetTranslation(gp_Vec(normal) * -reach);
            const TopoDS_Shape start = BRepBuilderAPI_Transform(edge, shift).Shape();
            const TopoDS_Shape wall = BRepPrimAPI_MakePrism(start, gp_Vec(normal) * (2.0 * reach)).Shape();
            BRepAlgoAPI_Section cut(wall, target, false);
            cut.Approximation(true);
            cut.Build();
            if (cut.IsDone()) {
                Array lines = polylines_of(cut.Shape(), deflection);
                for (int64_t i = 0; i < lines.size(); ++i) {
                    result.push_back(lines[i]);
                }
            }
        }
        catch (const Standard_Failure& failure) {
            error = String("Intersection curve failed: ") + failure.GetMessageString();
        }
    }
    return result;
}

Array isocurves(const TopoDS_Shape& shape, int face_id, int direction, const std::vector<double>& params, double deflection, String& error)
{
    Array result;
    TopTools_IndexedMapOfShape faces = sub_shapes(shape, TopAbs_FACE);
    if (face_id < 0 || face_id >= faces.Extent()) {
        error = "Face id out of range";
        return result;
    }
    try {
        const TopoDS_Face face = TopoDS::Face(faces(face_id + 1));
        Handle(Geom_Surface) surface = BRep_Tool::Surface(face);
        double u0, u1, v0, v1;
        BRepTools::UVBounds(face, u0, u1, v0, v1);
        for (double t : params) {
            Handle(Geom_Curve) iso;
            double first = 0.0, last = 0.0;
            if (direction == 0) {
                iso = surface->UIso(u0 + t * (u1 - u0));
                first = v0;
                last = v1;
            }
            else {
                iso = surface->VIso(v0 + t * (v1 - v0));
                first = u0;
                last = u1;
            }
            GeomAdaptor_Curve adaptor(iso, first, last);
            GCPnts_TangentialDeflection sampler(adaptor, 0.15, deflection);
            PackedVector3Array points;
            for (int i = 1; i <= sampler.NbPoints(); ++i) {
                const gp_Pnt p = sampler.Value(i);
                points.push_back(Vector3(real_t(p.X()), real_t(p.Y()), real_t(p.Z())));
            }
            result.push_back(points);
        }
    }
    catch (const Standard_Failure& failure) {
        error = String("Isocurves failed: ") + failure.GetMessageString();
    }
    return result;
}

}  // namespace holo_forge::sketch
