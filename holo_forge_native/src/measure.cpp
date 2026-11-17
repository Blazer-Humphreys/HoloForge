#include "measure.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <memory>
#include <tuple>
#include <vector>

#include <Adaptor3d_Curve.hxx>
#include <BRepAdaptor_Curve.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <BRepBndLib.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_Transform.hxx>
#include <BRep_Builder.hxx>
#include <Geom_Curve.hxx>
#include <BRepGProp_Domain.hxx>
#include <BRepGProp_Face.hxx>
#include <BRepGProp_Sinert.hxx>
#include <BRepGProp_Vinert.hxx>
#include <BRepTools.hxx>
#include <BRepTopAdaptor_FClass2d.hxx>
#include <BRep_Tool.hxx>
#include <Bnd_Box2d.hxx>
#include <BndLib_Add2dCurve.hxx>
#include <BndLib_Add3dCurve.hxx>
#include <ElSLib.hxx>
#include <GProp.hxx>
#include <GCPnts_TangentialDeflection.hxx>
#include <Geom2dAdaptor_Curve.hxx>
#include <Geom2d_Curve.hxx>
#include <Geom_Surface.hxx>
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
#include <ShapeFix_Face.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeWire.hxx>
#include <BRepGProp.hxx>
#include <Geom_Curve.hxx>
#include <ShapeAnalysis_FreeBounds.hxx>
#include <TopTools_HSequenceOfShape.hxx>
#include <TopTools_IndexedDataMapOfShapeListOfShape.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <TopTools_ListOfShape.hxx>
#include <TopExp.hxx>
#include <TopoDS_Wire.hxx>
#include <gp_Pln.hxx>
#include <Poly_PolygonOnTriangulation.hxx>
#include <Poly_Triangulation.hxx>
#include <TopLoc_Location.hxx>
#include <Precision.hxx>
#include <Standard_Failure.hxx>
#include <TColStd_Array1OfReal.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Vertex.hxx>
#include <gp.hxx>
#include <gp_Ax3.hxx>
#include <gp_Mat.hxx>
#include <gp_Sphere.hxx>
#include <gp_Torus.hxx>
#include <math.hxx>
#include <math_Vector.hxx>

namespace holo_forge::measure
{

namespace
{
/// Integrals over faces about a point: the mass (volume or area), its first moments and the
/// inertia matrix's entries (the off-diagonal ones negated), as BRepGProp_Gauss sums them.
struct Sums
{
    double m = 0.0;
    double x = 0.0, y = 0.0, z = 0.0;
    double xx = 0.0, yy = 0.0, zz = 0.0, xy = 0.0, yz = 0.0, xz = 0.0;

    void add(const Sums& o, double w)
    {
        m += o.m * w;
        x += o.x * w;
        y += o.y * w;
        z += o.z * w;
        xx += o.xx * w;
        yy += o.yy * w;
        zz += o.zz * w;
        xy += o.xy * w;
        yz += o.yz * w;
        xz += o.xz * w;
    }
};

/// GProp_GProps holding sums made about loc.
class Props: public GProp_GProps
{
public:
    Props(const gp_Pnt& location, const Sums& s)
    {
        loc = location;
        dim = s.m;
        g = std::abs(s.m) >= 1e-30 ? gp_Pnt(s.x / s.m, s.y / s.m, s.z / s.m) : gp_Pnt(0.0, 0.0, 0.0);
        inertia = gp_Mat(gp_XYZ(s.xx, s.xy, s.xz), gp_XYZ(s.xy, s.yy, s.yz), gp_XYZ(s.xz, s.yz, s.zz));
    }
};

/// The sums about loc of properties OCCT integrated.
Sums sums_of(const GProp_GProps& p, const gp_Pnt& loc)
{
    Sums s;
    s.m = p.Mass();
    const gp_XYZ c = p.CentreOfMass().XYZ() - loc.XYZ();
    s.x = c.X() * s.m;
    s.y = c.Y() * s.m;
    s.z = c.Z() * s.m;
    gp_Mat shift;
    GProp::HOperator(gp_Pnt(c), gp::Origin(), s.m, shift);
    const gp_Mat about = p.MatrixOfInertia() + shift;
    s.xx = about(1, 1);
    s.yy = about(2, 2);
    s.zz = about(3, 3);
    s.xy = about(1, 2);
    s.yz = about(2, 3);
    s.xz = about(1, 3);
    return s;
}

/// A face integrated by OCCT's fixed-order rule (for a face whose edges have no curves on it).
Sums occt_sums(const TopoDS_Face& face, const gp_Pnt& loc, bool solid)
{
    BRepGProp_Face surface(face);
    const bool natural = face.NbChildren() == 0;
    BRepGProp_Domain domain;
    if (!natural) {
        domain.Init(face);
    }
    if (solid) {
        BRepGProp_Vinert props;
        props.SetLocation(loc);
        natural ? props.Perform(surface) : props.Perform(surface, domain);
        return sums_of(props, loc);
    }
    BRepGProp_Sinert props;
    props.SetLocation(loc);
    natural ? props.Perform(surface) : props.Perform(surface, domain);
    return sums_of(props, loc);
}

constexpr int MAX_NODES = 40;

/// Gauss-Legendre nodes and weights on [-1, 1].
struct Rule
{
    std::vector<double> x;
    std::vector<double> w;
};

const Rule& gauss(int n)
{
    static const std::vector<Rule> rules = [] {
        std::vector<Rule> all(MAX_NODES + 1);
        for (int k = 1; k <= MAX_NODES; ++k) {
            math_Vector points(1, k);
            math_Vector weights(1, k);
            math::GaussPoints(k, points);
            math::GaussWeights(k, weights);
            for (int i = 1; i <= k; ++i) {
                all[k].x.push_back(points(i));
                all[k].w.push_back(weights(i));
            }
        }
        return all;
    }();
    return rules[std::clamp(n, 1, MAX_NODES)];
}

/// The polynomial degree of a basis curve, -1 when it isn't one.
int curve_degree(const Handle(Adaptor3d_Curve)& curve)
{
    switch (curve->GetType()) {
        case GeomAbs_Line:
            return 1;
        case GeomAbs_BezierCurve:
        case GeomAbs_BSplineCurve:
            return curve->IsRational() ? -1 : curve->Degree();
        default:
            return -1;
    }
}

/// How a surface runs along one of its parameters: where it changes piece (one period of them on a
/// periodic surface), the polynomial degree of its points between (-1 when they aren't one),
/// whether it turns round an axis (an analytic surface's angle: sines and cosines of it), and
/// whether the length of the surface's normal is a polynomial of degree one or less along it (so
/// area terms are polynomials there too).
struct Direction
{
    std::vector<double> knots;
    double period = 0.0;
    int degree = -1;
    bool round = false;
    bool even = false;
};

std::array<Direction, 2> directions(const BRepAdaptor_Surface& surface)
{
    std::array<Direction, 2> out;
    for (int d = 0; d < 2; ++d) {
        const bool in_u = d == 0;
        const int count = in_u ? surface.NbUIntervals(GeomAbs_CN) : surface.NbVIntervals(GeomAbs_CN);
        TColStd_Array1OfReal breaks(1, count + 1);
        if (in_u) {
            surface.UIntervals(breaks, GeomAbs_CN);
        }
        else {
            surface.VIntervals(breaks, GeomAbs_CN);
        }
        for (int i = 1; i <= count + 1; ++i) {
            if (!Precision::IsInfinite(breaks(i))) {
                out[d].knots.push_back(breaks(i));
            }
        }
        if (in_u ? surface.IsUPeriodic() : surface.IsVPeriodic()) {
            out[d].period = in_u ? surface.UPeriod() : surface.VPeriod();
        }
    }
    switch (surface.GetType()) {
        case GeomAbs_Plane:
            out[0].degree = out[1].degree = 1;
            out[0].even = out[1].even = true;
            break;
        case GeomAbs_Cylinder:
        case GeomAbs_Cone:
            out[1].degree = 1;
            out[0].round = out[1].even = true;
            break;
        case GeomAbs_Sphere:
            out[0].round = true;
            break;
        case GeomAbs_Torus:
            out[0].round = out[1].round = true;
            break;
        case GeomAbs_BezierSurface:
        case GeomAbs_BSplineSurface:
            out[0].degree = surface.IsURational() ? -1 : surface.UDegree();
            out[1].degree = surface.IsVRational() ? -1 : surface.VDegree();
            break;
        case GeomAbs_SurfaceOfExtrusion:
            out[0].degree = curve_degree(surface.BasisCurve());
            out[1].degree = 1;
            out[1].even = true;
            break;
        case GeomAbs_SurfaceOfRevolution:
            out[1].degree = curve_degree(surface.BasisCurve());
            out[0].round = true;
            break;
        default:
            break;
    }
    for (Direction& d : out) {
        d.round = d.round && d.period > 0.0;
    }
    return out;
}

/// The knots of a direction strictly between lo and hi (a periodic direction's repeated); with
/// quarters, a periodic direction that isn't polynomial (round) also every quarter turn.
std::vector<double> cuts(const Direction& d, double lo, double hi, bool quarters)
{
    std::vector<double> base = d.knots;
    if (quarters && d.period > 0.0 && d.degree < 0) {
        const double origin = base.empty() ? 0.0 : base.front();
        for (int k = 0; k < 4; ++k) {
            base.push_back(origin + d.period * k / 4.0);
        }
    }
    std::vector<double> out;
    const double margin = 1e-12 * std::max(hi - lo, 1e-300);
    for (const double b : base) {
        if (d.period > 0.0) {
            for (double c = b + std::floor((lo - b) / d.period) * d.period; c < hi; c += d.period) {
                if (c > lo + margin && c < hi - margin) {
                    out.push_back(c);
                }
            }
        }
        else if (b > lo + margin && b < hi - margin) {
            out.push_back(b);
        }
    }
    std::sort(out.begin(), out.end());
    out.erase(std::unique(out.begin(), out.end(), [&](double a, double b) { return b - a <= margin; }), out.end());
    return out;
}

/// Gauss points enough to integrate a face's terms exactly along a direction of this degree (the
/// second moments of a volume run to degree 5p - 1); a direction that isn't polynomial gets 20.
int nodes_for(int degree)
{
    return degree < 0 ? 20 : std::clamp((5 * degree + 1) / 2 + 1, 3, MAX_NODES);
}

/// Gauss points for a face's terms along a direction (volume terms when solid, else area terms):
/// as nodes_for when they are polynomials there; a quarter turn of a round direction (sines and
/// cosines of low degree) takes 10 to within rounding; anything else 20.
int nodes_along(const Direction& d, bool solid)
{
    if (d.degree >= 0 && (solid || d.even)) {
        return nodes_for(d.degree);
    }
    return d.round ? 10 : 20;
}

/// The face's volume terms toward loc (solid) or area terms, by Green's theorem over its UV
/// domain: along each edge's curve on the face, the integral across one parameter from a fixed
/// value up to the curve, both split where the surface or the curve changes piece, with Gauss
/// points enough for each piece. Across u, or across v when the face has many more pieces along u
/// (a wall of a dense spline's: integrating across every piece from every point of the boundary
/// costs their product). False when an edge has no curve on the face.
bool face_sums(const TopoDS_Face& face, const gp_Pnt& loc, bool solid, Sums& out)
{
    const TopoDS_Face forward = TopoDS::Face(face.Oriented(TopAbs_FORWARD));
    const BRepAdaptor_Surface surface(forward, false);
    double lo[2] = {0.0, 0.0};
    double hi[2] = {0.0, 0.0};
    const bool edged = TopExp_Explorer(forward, TopAbs_EDGE).More();
    if (edged) {
        if (!uv_bounds(forward, lo[0], hi[0], lo[1], hi[1])) {
            return false;
        }
    }
    else {
        BRepTools::UVBounds(forward, lo[0], hi[0], lo[1], hi[1]);
    }
    for (int d = 0; d < 2; ++d) {
        if (Precision::IsInfinite(lo[d]) || Precision::IsInfinite(hi[d])) {
            return false;
        }
    }
    const std::array<Direction, 2> dirs = directions(surface);
    // Each direction's knots (where a boundary curve crossing them bends the integrand) and its
    // pieces (with quarter turns) within the face.
    std::array<std::vector<double>, 2> knots;
    std::array<std::vector<double>, 2> pieces;
    double span[2] = {1.0, 1.0};
    for (int d = 0; d < 2; ++d) {
        span[d] = std::max(hi[d] - lo[d], 1e-300);
        knots[d] = cuts(dirs[d], lo[d] - 1e-9 * span[d], hi[d] + 1e-9 * span[d], false);
        pieces[d] = cuts(dirs[d], lo[d], hi[d], true);
    }
    // a: the parameter integrated across; b: the one the boundary is measured along.
    const int a = pieces[0].size() > 2 * pieces[1].size() + 4 ? 1 : 0;
    const int b = 1 - a;
    const std::vector<double> across_cuts = cuts(dirs[a], lo[a] - span[a], hi[a] + span[a], true);
    const Rule& rule_across = gauss(nodes_along(dirs[a], solid));

    Sums total;
    auto add_point = [&](double u, double v, double w) {
        gp_Pnt p;
        gp_Vec du;
        gp_Vec dv;
        surface.D1(u, v, p, du, dv);
        const gp_Vec n = du.Crossed(dv);
        const double x = p.X() - loc.X();
        const double y = p.Y() - loc.Y();
        const double z = p.Z() - loc.Z();
        double d = 0.0;
        if (solid) {
            d = (x * n.X() + y * n.Y() + z * n.Z()) * w;
            total.m += d / 3.0;
            total.x += 0.25 * x * d;
            total.y += 0.25 * y * d;
            total.z += 0.25 * z * d;
            d *= 0.2;
        }
        else {
            d = n.Magnitude() * w;
            total.m += d;
            total.x += x * d;
            total.y += y * d;
            total.z += z * d;
        }
        total.xx += (y * y + z * z) * d;
        total.yy += (x * x + z * z) * d;
        total.zz += (x * x + y * y) * d;
        total.xy -= x * y * d;
        total.yz -= y * z * d;
        total.xz -= x * z * d;
    };
    // The points along the boundary (at: across a; along: along b) with their weights: the
    // integral across from lo[a] to each is taken once they are all known, a piece of the surface
    // at a time and in order along b (a spline surface is evaluated much quicker staying within one
    // of its pieces).
    struct Node
    {
        double at;
        double along;
        double w;
    };
    std::vector<Node> nodes;
    auto integrate = [&](double from, double to, double along, double weight) {
        const double half = 0.5 * (to - from);
        const double mid = 0.5 * (to + from);
        for (size_t j = 0; j < rule_across.x.size(); ++j) {
            const double s = mid + half * rule_across.x[j];
            if (a == 0) {
                add_point(s, along, weight * half * rule_across.w[j]);
            }
            else {
                add_point(along, s, weight * half * rule_across.w[j]);
            }
        }
    };

    if (!edged) {
        // The whole surface: only its side at hi[a] (run along b, the right way round) counts.
        std::vector<double> ends = {lo[b]};
        ends.insert(ends.end(), pieces[b].begin(), pieces[b].end());
        ends.push_back(hi[b]);
        const Rule& rule = gauss(nodes_along(dirs[b], solid));
        for (size_t k = 0; k + 1 < ends.size(); ++k) {
            const double half = 0.5 * (ends[k + 1] - ends[k]);
            const double mid = 0.5 * (ends[k + 1] + ends[k]);
            for (size_t j = 0; j < rule.x.size(); ++j) {
                nodes.push_back({hi[a], mid + half * rule.x[j], half * rule.w[j]});
            }
        }
    }
    // Along a slanted line of the parameters, the terms are polynomials when they are in both
    // directions.
    const bool poly_a = dirs[a].degree >= 0 && (solid || dirs[a].even);
    const bool poly_b = dirs[b].degree >= 0 && (solid || dirs[b].even);
    for (TopExp_Explorer it(forward, TopAbs_EDGE); edged && it.More(); it.Next()) {
        const TopoDS_Edge& edge = TopoDS::Edge(it.Current());
        if (edge.Orientation() != TopAbs_FORWARD && edge.Orientation() != TopAbs_REVERSED) {
            continue;
        }
        double f = 0.0;
        double l = 0.0;
        const Handle(Geom2d_Curve) pcurve = BRep_Tool::CurveOnSurface(edge, forward, f, l);
        if (pcurve.IsNull()) {
            return false;
        }
        if (!(l > f)) {
            continue;
        }
        const Geom2dAdaptor_Curve curve(pcurve, f, l);
        const double turn = edge.Orientation() == TopAbs_REVERSED ? -1.0 : 1.0;
        std::vector<double> ends = {f, l};
        int count = 20;
        const GeomAbs_CurveType type = curve.GetType();
        if (type == GeomAbs_Line) {
            const gp_Dir2d along = curve.Line().Direction();
            if (std::abs(along.Coord(b + 1)) < 1e-15) {
                // Along a: b doesn't change, so nothing is added.
                continue;
            }
            const bool upright = std::abs(along.Coord(a + 1)) < 1e-15;
            count = upright ? nodes_along(dirs[b], solid) : poly_a && poly_b ? std::min(MAX_NODES, nodes_for(dirs[a].degree) + nodes_for(dirs[b].degree)) : 20;
            const double from = curve.Value(f).Coord(b + 1);
            const double to = curve.Value(l).Coord(b + 1);
            for (const double c : pieces[b]) {
                // Along b: break at the surface's pieces (and quarter turns).
                const double t = f + (l - f) * (c - from) / (to - from);
                if (t > f && t < l) {
                    ends.push_back(t);
                }
            }
        }
        else {
            const int parts = curve.NbIntervals(GeomAbs_CN);
            TColStd_Array1OfReal breaks(1, parts + 1);
            curve.Intervals(breaks, GeomAbs_CN);
            for (int i = 2; i <= parts; ++i) {
                ends.push_back(breaks(i));
            }
            if (type == GeomAbs_Circle || type == GeomAbs_Ellipse) {
                for (double t = f + M_PI / 2.0; t < l; t += M_PI / 2.0) {
                    ends.push_back(t);
                }
            }
        }
        std::sort(ends.begin(), ends.end());
        // Where the curve crosses a knot of the surface, the integrand bends: break there too.
        if (!knots[0].empty() || !knots[1].empty()) {
            std::vector<double> crossings;
            for (size_t k = 0; k + 1 < ends.size(); ++k) {
                const int samples = 16;
                double ta = ends[k];
                gp_Pnt2d pa = curve.Value(ta);
                for (int i = 1; i <= samples; ++i) {
                    const double tb = ends[k] + (ends[k + 1] - ends[k]) * i / samples;
                    const gp_Pnt2d pb = curve.Value(tb);
                    for (int d = 0; d < 2; ++d) {
                        for (const double c : knots[d]) {
                            const double fa = pa.Coord(d + 1) - c;
                            const double fb = pb.Coord(d + 1) - c;
                            if (fa * fb >= 0.0) {
                                continue;
                            }
                            double low = ta;
                            double high = tb;
                            for (int iteration = 0; iteration < 60 && high - low > 1e-15 * (l - f); ++iteration) {
                                const double mid = 0.5 * (low + high);
                                if ((curve.Value(mid).Coord(d + 1) - c) * fa > 0.0) {
                                    low = mid;
                                }
                                else {
                                    high = mid;
                                }
                            }
                            crossings.push_back(0.5 * (low + high));
                        }
                    }
                    ta = tb;
                    pa = pb;
                }
            }
            ends.insert(ends.end(), crossings.begin(), crossings.end());
            std::sort(ends.begin(), ends.end());
        }
        const Rule& rule = gauss(count);
        // Across u the boundary is measured by its rise in v; across v, by its run back in u.
        const double sense = a == 0 ? turn : -turn;
        for (size_t k = 0; k + 1 < ends.size(); ++k) {
            const double half = 0.5 * (ends[k + 1] - ends[k]);
            if (!(half > 1e-15 * (l - f))) {
                continue;
            }
            const double mid = 0.5 * (ends[k + 1] + ends[k]);
            for (size_t j = 0; j < rule.x.size(); ++j) {
                gp_Pnt2d uv;
                gp_Vec2d speed;
                curve.D1(mid + half * rule.x[j], uv, speed);
                const double weight = sense * half * rule.w[j] * speed.Coord(b + 1);
                if (weight != 0.0) {
                    nodes.push_back({uv.Coord(a + 1), uv.Coord(b + 1), weight});
                }
            }
        }
    }
    std::sort(nodes.begin(), nodes.end(), [](const Node& p, const Node& q) { return p.along < q.along; });
    double reach = lo[a];
    for (const Node& n : nodes) {
        reach = std::max(reach, n.at);
    }
    std::vector<double> ends = {lo[a]};
    for (const double c : across_cuts) {
        if (c > lo[a] && c < reach) {
            ends.push_back(c);
        }
    }
    ends.push_back(reach);
    for (size_t k = 0; k + 1 < ends.size(); ++k) {
        for (const Node& n : nodes) {
            if (n.at > ends[k]) {
                integrate(ends[k], std::min(ends[k + 1], n.at), n.along, n.w);
            }
        }
    }
    // (A point a hair before lo[a], back to it.)
    for (const Node& n : nodes) {
        double from = n.at;
        for (const double c : across_cuts) {
            if (c > from && c < lo[a]) {
                integrate(from, c, n.along, -n.w);
                from = c;
            }
        }
        if (from < lo[a]) {
            integrate(from, lo[a], n.along, -n.w);
        }
    }
    // The volume terms follow the face's outward normal.
    out.add(total, solid && face.Orientation() == TopAbs_REVERSED ? -1.0 : 1.0);
    return true;
}

/// The mean of a shape's vertices (as OCCT's rough centre): sums are made about it to keep them small.
gp_Pnt middle_of(const TopoDS_Shape& shape)
{
    gp_XYZ sum(0.0, 0.0, 0.0);
    int count = 0;
    for (TopExp_Explorer it(shape, TopAbs_VERTEX); it.More(); it.Next(), ++count) {
        sum += BRep_Tool::Pnt(TopoDS::Vertex(it.Current())).XYZ();
    }
    return gp_Pnt(count > 0 ? sum / double(count) : sum);
}

void add_face(const TopoDS_Face& face, const gp_Pnt& loc, bool solid, Sums& total)
{
    TopLoc_Location where;
    if (BRep_Tool::Surface(face, where).IsNull()) {
        return;
    }
    Sums sums;
    bool done = false;
    try {
        done = face_sums(face, loc, solid, sums);
    }
    catch (const Standard_Failure&) {
        done = false;
    }
    if (!done) {
        sums = occt_sums(face, loc, solid);
    }
    total.add(sums, 1.0);
}

/// True when a face lies within the box of its edges (lines along its surface sweep between them):
/// as BRepBndLib's own test.
bool bounded_by_edges(const Adaptor3d_Surface& surface)
{
    switch (surface.GetType()) {
        case GeomAbs_Plane:
        case GeomAbs_Cylinder:
        case GeomAbs_Cone:
        case GeomAbs_SurfaceOfExtrusion:
            return true;
        case GeomAbs_SurfaceOfRevolution:
            return surface.BasisCurve()->GetType() == GeomAbs_Line;
        case GeomAbs_OffsetSurface:
            return bounded_by_edges(*surface.BasisSurface());
        case GeomAbs_BSplineSurface:
            return (surface.UDegree() == 1 && surface.NbUKnots() == 2) || (surface.VDegree() == 1 && surface.NbVKnots() == 2);
        case GeomAbs_BezierSurface:
            return surface.UDegree() == 1 || surface.VDegree() == 1;
        default:
            return false;
    }
}

/// angle brought into [from, from + 2 pi).
double turned_into(double angle, double from)
{
    return angle - 2.0 * M_PI * std::floor((angle - from) / (2.0 * M_PI));
}

/// The points of a sphere or a torus where its height along a direction can top out (where the
/// surface faces that way or straight back), as parameters; false for other surfaces. A torus seen
/// along its axis tops out along whole circles: a few points of each stand for them (the face's
/// edges cross such a circle wherever the face holds only part of it).
bool critical_points(const BRepAdaptor_Surface& surface, const gp_Dir& direction, std::vector<gp_Pnt2d>& uvs)
{
    if (surface.GetType() == GeomAbs_Sphere) {
        const gp_Sphere sphere = surface.Sphere();
        for (const double sign : {1.0, -1.0}) {
            double u = 0.0;
            double v = 0.0;
            ElSLib::Parameters(sphere, sphere.Location().Translated(gp_Vec(direction) * (sign * sphere.Radius())), u, v);
            uvs.push_back(gp_Pnt2d(u, v));
        }
        return true;
    }
    if (surface.GetType() != GeomAbs_Torus) {
        return false;
    }
    const gp_Torus torus = surface.Torus();
    const gp_Ax3& frame = torus.Position();
    const double ex = direction.Dot(frame.XDirection());
    const double ey = direction.Dot(frame.YDirection());
    const double ez = direction.Dot(frame.Direction());
    const double across = std::hypot(ex, ey);
    if (across < 1e-12) {
        for (int k = 0; k < 8; ++k) {
            for (const double v : {M_PI / 2.0, -M_PI / 2.0}) {
                uvs.push_back(gp_Pnt2d(2.0 * M_PI * k / 8.0, v));
            }
        }
        return true;
    }
    // Facing round the axis toward the direction (or away), then up the tube's section.
    const double toward = std::atan2(ey, ex);
    for (const double side : {1.0, -1.0}) {
        const double u = side > 0.0 ? toward : toward + M_PI;
        const double v = std::atan2(ez, side * across);
        uvs.push_back(gp_Pnt2d(u, v));
        uvs.push_back(gp_Pnt2d(u, v + M_PI));
    }
    return true;
}

/// The box of a face: its edges and corners, and where it bulges past them its own highest and
/// lowest points: on a sphere or a torus those of its surface that lie in it; on anything else
/// climbed to from points sampled inside it (on a grid, and just inside each edge and each corner,
/// where a plate can overshoot its boundary), never stepping out of it.
void face_box(const TopoDS_Face& face, Bnd_Box& box)
{
    Bnd_Box edges;
    for (TopExp_Explorer it(face, TopAbs_EDGE); it.More(); it.Next()) {
        const TopoDS_Edge& edge = TopoDS::Edge(it.Current());
        if (!BRep_Tool::Degenerated(edge) && BRep_Tool::IsGeometric(edge)) {
            BndLib_Add3dCurve::AddOptimal(BRepAdaptor_Curve(edge), 0.0, edges);
        }
    }
    for (TopExp_Explorer it(face, TopAbs_VERTEX); it.More(); it.Next()) {
        edges.Add(BRep_Tool::Pnt(TopoDS::Vertex(it.Current())));
    }
    const TopoDS_Face forward = TopoDS::Face(face.Oriented(TopAbs_FORWARD));
    const BRepAdaptor_Surface surface(forward, false);
    double u1 = 0.0, u2 = 0.0, v1 = 0.0, v2 = 0.0;
    if (bounded_by_edges(surface) && !edges.IsVoid()) {
        box.Add(edges);
        return;
    }
    if (edges.IsVoid() || !uv_bounds(forward, u1, u2, v1, v2) || !(u2 > u1) || !(v2 > v1)) {
        // No edges to go by (a whole surface): OCCT's box of the surface.
        BRepBndLib::AddOptimal(face, box, false, false);
        return;
    }
    double lo[3] = {0.0, 0.0, 0.0};
    double hi[3] = {0.0, 0.0, 0.0};
    edges.Get(lo[0], lo[1], lo[2], hi[0], hi[1], hi[2]);
    for (int i = 0; i < 3; ++i) {
        // (Without the box's gap: the edges' own extremes.)
        lo[i] += edges.GetGap();
        hi[i] -= edges.GetGap();
    }
    BRepTopAdaptor_FClass2d inside(forward, Precision::PConfusion());
    std::vector<gp_Pnt2d> tops;
    for (int axis = 0; axis < 3; ++axis) {
        gp_XYZ along(0.0, 0.0, 0.0);
        along.SetCoord(axis + 1, 1.0);
        if (!critical_points(surface, gp_Dir(along), tops)) {
            break;
        }
    }
    if (!tops.empty()) {
        for (gp_Pnt2d uv : tops) {
            // (In the face's own turn of each periodic direction.)
            if (surface.IsUPeriodic()) {
                uv.SetX(turned_into(uv.X(), u1 - 1e-12));
            }
            if (surface.IsVPeriodic()) {
                uv.SetY(turned_into(uv.Y(), v1 - 1e-12));
            }
            if (inside.Perform(uv) != TopAbs_OUT) {
                edges.Add(surface.Value(uv.X(), uv.Y()));
            }
        }
        edges.Get(lo[0], lo[1], lo[2], hi[0], hi[1], hi[2]);
        box.Update(lo[0] + edges.GetGap(), lo[1] + edges.GetGap(), lo[2] + edges.GetGap(), hi[0] - edges.GetGap(), hi[1] - edges.GetGap(), hi[2] - edges.GetGap());
        return;
    }
    const double size = std::sqrt(edges.SquareExtent());
    std::vector<gp_Pnt2d> seeds;
    const int n = 24;
    for (int i = 0; i < n; ++i) {
        for (int j = 0; j < n; ++j) {
            const gp_Pnt2d uv(u1 + (u2 - u1) * (i + 0.5) / n, v1 + (v2 - v1) * (j + 0.5) / n);
            if (inside.Perform(uv) == TopAbs_IN) {
                seeds.push_back(uv);
            }
        }
    }
    // Points on and just inside the edges, near their ends (the face's corners) too.
    std::vector<double> along_edge;
    for (int i = 0; i < 24; ++i) {
        along_edge.push_back((i + 0.5) / 24.0);
    }
    for (const double near_end : {0.002, 0.006, 0.012}) {
        along_edge.push_back(near_end);
        along_edge.push_back(1.0 - near_end);
    }
    for (TopExp_Explorer it(forward, TopAbs_EDGE); it.More(); it.Next()) {
        const TopoDS_Edge& edge = TopoDS::Edge(it.Current());
        double f = 0.0;
        double l = 0.0;
        const Handle(Geom2d_Curve) pcurve = BRep_Tool::CurveOnSurface(edge, forward, f, l);
        if (pcurve.IsNull() || BRep_Tool::Degenerated(edge)) {
            continue;
        }
        const double turn = edge.Orientation() == TopAbs_REVERSED ? -1.0 : 1.0;
        for (const double s : along_edge) {
            gp_Pnt2d uv;
            gp_Vec2d along;
            pcurve->D1(f + (l - f) * s, uv, along);
            // The face's own edge (its surface there can stray from the edge's curve, within the
            // edge's tolerance: a plate's does by a micron).
            seeds.push_back(gp_Pnt2d(std::clamp(uv.X(), u1, u2), std::clamp(uv.Y(), v1, v2)));
            if (along.Magnitude() < 1e-300) {
                continue;
            }
            // The face lies to the left of its edges, run their way.
            const gp_Vec2d in = gp_Vec2d(-along.Y(), along.X()).Normalized() * turn;
            gp_Pnt p;
            gp_Vec du;
            gp_Vec dv;
            surface.D1(uv.X(), uv.Y(), p, du, dv);
            const double speed = (du * in.X() + dv * in.Y()).Magnitude();
            if (speed < 1e-300) {
                continue;
            }
            for (const double depth : {1e-3, 4e-3, 1e-2, 2e-2, 5e-2}) {
                const gp_Pnt2d near = uv.Translated(in * (depth * size / speed));
                if (near.X() > u1 && near.X() < u2 && near.Y() > v1 && near.Y() < v2 && inside.Perform(near) == TopAbs_IN) {
                    seeds.push_back(near);
                }
            }
        }
    }
    if (seeds.empty()) {
        box.Add(edges);
        return;
    }
    std::vector<gp_Pnt> points;
    for (const gp_Pnt2d& uv : seeds) {
        points.push_back(surface.Value(uv.X(), uv.Y()));
    }
    const double tiny = 1e-13 * std::max(std::abs(u2 - u1), std::abs(v2 - v1));
    for (int axis = 0; axis < 3; ++axis) {
        for (const double sign : {1.0, -1.0}) {
            auto value = [&](const gp_Pnt& p) { return sign * p.Coord(axis + 1); };
            const double edge_top = sign > 0.0 ? hi[axis] : -lo[axis];
            double reached = edge_top;
            // The highest samples, climbed from (a sample is itself a point of the face), those that
            // rise past the edges (where the face tops out on an edge, the edge's box holds it).
            std::vector<size_t> order(points.size());
            for (size_t k = 0; k < order.size(); ++k) {
                order[k] = k;
                reached = std::max(reached, value(points[k]));
            }
            const size_t tops_count = std::min<size_t>(6, order.size());
            std::partial_sort(order.begin(), order.begin() + tops_count, order.end(), [&](size_t a, size_t b) { return value(points[a]) > value(points[b]); });
            for (size_t t = 0; t < tops_count; ++t) {
                if (value(points[order[t]]) <= edge_top) {
                    break;
                }
                double u = seeds[order[t]].X();
                double v = seeds[order[t]].Y();
                double best = value(points[order[t]]);
                for (int iteration = 0; iteration < 60; ++iteration) {
                    gp_Pnt p;
                    gp_Vec su, sv, suu, svv, suv;
                    surface.D2(u, v, p, su, sv, suu, svv, suv);
                    const double gu = sign * su.Coord(axis + 1);
                    const double gv = sign * sv.Coord(axis + 1);
                    const double huu = sign * suu.Coord(axis + 1);
                    const double hvv = sign * svv.Coord(axis + 1);
                    const double huv = sign * suv.Coord(axis + 1);
                    const double det = huu * hvv - huv * huv;
                    double step_u = 0.0;
                    double step_v = 0.0;
                    if (huu < 0.0 && det > 0.0) {
                        step_u = -(hvv * gu - huv * gv) / det;
                        step_v = -(huu * gv - huv * gu) / det;
                    }
                    else {
                        // Not near a top: up the slope, a twentieth of the face at a time.
                        const double slope = std::sqrt(gu * gu / std::max(su.SquareMagnitude(), 1e-300) + gv * gv / std::max(sv.SquareMagnitude(), 1e-300));
                        if (slope < 1e-300) {
                            break;
                        }
                        const double reach = 0.05 * size / slope;
                        step_u = gu / std::max(su.SquareMagnitude(), 1e-300) * reach;
                        step_v = gv / std::max(sv.SquareMagnitude(), 1e-300) * reach;
                    }
                    bool moved = false;
                    for (int halving = 0; halving < 30 && !moved; ++halving) {
                        const double nu = std::clamp(u + step_u, u1, u2);
                        const double nv = std::clamp(v + step_v, v1, v2);
                        const double there = value(surface.Value(nu, nv));
                        // (A step out of the face goes past an edge, whose box holds the face there.)
                        if (there > best && inside.Perform(gp_Pnt2d(nu, nv)) != TopAbs_OUT) {
                            moved = std::abs(nu - u) + std::abs(nv - v) > tiny;
                            u = nu;
                            v = nv;
                            best = there;
                        }
                        step_u *= 0.5;
                        step_v *= 0.5;
                    }
                    if (!moved) {
                        break;
                    }
                }
                reached = std::max(reached, best);
            }
            if (sign > 0.0) {
                hi[axis] = reached;
            }
            else {
                lo[axis] = -reached;
            }
        }
    }
    box.Update(lo[0], lo[1], lo[2], hi[0], hi[1], hi[2]);
}
}  // namespace

GProp_GProps volume(const TopoDS_Shape& shape)
{
    const gp_Pnt loc = middle_of(shape);
    Sums total;
    bool any = false;
    for (TopExp_Explorer shell(shape, TopAbs_SHELL); shell.More(); shell.Next()) {
        // Only closed shells count: an open shell (a surface body) has no inside.
        if (!BRep_Tool::IsClosed(shell.Current())) {
            continue;
        }
        for (TopExp_Explorer it(shell.Current(), TopAbs_FACE); it.More(); it.Next()) {
            const TopoDS_Face& face = TopoDS::Face(it.Current());
            if (face.Orientation() == TopAbs_FORWARD || face.Orientation() == TopAbs_REVERSED) {
                add_face(face, loc, true, total);
                any = true;
            }
        }
    }
    // With nothing measured, the centre is the shape's origin (as OCCT gives it).
    return any ? Props(loc, total) : GProp_GProps(gp::Origin().Transformed(shape.Location().Transformation()));
}

GProp_GProps surface(const TopoDS_Shape& shape)
{
    const gp_Pnt loc = middle_of(shape);
    Sums total;
    bool any = false;
    for (TopExp_Explorer it(shape, TopAbs_FACE); it.More(); it.Next()) {
        add_face(TopoDS::Face(it.Current()), loc, false, total);
        any = true;
    }
    return any ? Props(loc, total) : GProp_GProps(gp::Origin().Transformed(shape.Location().Transformation()));
}

bool uv_bounds(const TopoDS_Face& face, double& u1, double& u2, double& v1, double& v2)
{
    const TopoDS_Face forward = TopoDS::Face(face.Oriented(TopAbs_FORWARD));
    Bnd_Box2d box;
    for (TopExp_Explorer it(forward, TopAbs_EDGE); it.More(); it.Next()) {
        double f = 0.0;
        double l = 0.0;
        const Handle(Geom2d_Curve) pcurve = BRep_Tool::CurveOnSurface(TopoDS::Edge(it.Current()), forward, f, l);
        if (!pcurve.IsNull()) {
            BndLib_Add2dCurve::AddOptimal(pcurve, f, l, 0.0, box);
        }
    }
    if (box.IsVoid()) {
        return false;
    }
    // (Without the box's gap: the curves' own extremes.)
    box.Get(u1, v1, u2, v2);
    u1 += box.GetGap();
    v1 += box.GetGap();
    u2 -= box.GetGap();
    v2 -= box.GetGap();
    TopLoc_Location where;
    const Handle(Geom_Surface) surface = BRep_Tool::Surface(forward, where);
    if (!surface.IsNull()) {
        double su1 = 0.0, su2 = 0.0, sv1 = 0.0, sv2 = 0.0;
        surface->Bounds(su1, su2, sv1, sv2);
        if (!surface->IsUPeriodic()) {
            u1 = std::max(u1, su1);
            u2 = std::min(u2, su2);
        }
        if (!surface->IsVPeriodic()) {
            v1 = std::max(v1, sv1);
            v2 = std::min(v2, sv2);
        }
    }
    return u1 <= u2 && v1 <= v2;
}

Bnd_Box box(const TopoDS_Shape& shape)
{
    Bnd_Box result;
    for (TopExp_Explorer it(shape, TopAbs_FACE); it.More(); it.Next()) {
        try {
            face_box(TopoDS::Face(it.Current()), result);
        }
        catch (const Standard_Failure&) {
            BRepBndLib::Add(it.Current(), result, false);
        }
    }
    for (TopExp_Explorer it(shape, TopAbs_EDGE, TopAbs_FACE); it.More(); it.Next()) {
        const TopoDS_Edge& edge = TopoDS::Edge(it.Current());
        if (!BRep_Tool::Degenerated(edge) && BRep_Tool::IsGeometric(edge)) {
            BndLib_Add3dCurve::AddOptimal(BRepAdaptor_Curve(edge), 0.0, result);
        }
    }
    for (TopExp_Explorer it(shape, TopAbs_VERTEX, TopAbs_EDGE); it.More(); it.Next()) {
        result.Add(BRep_Tool::Pnt(TopoDS::Vertex(it.Current())));
    }
    return result;
}

double length(const TopoDS_Edge& edge)
{
    if (BRep_Tool::Degenerated(edge) || !BRep_Tool::IsGeometric(edge)) {
        return 0.0;
    }
    const BRepAdaptor_Curve curve(edge);
    const double f = curve.FirstParameter();
    const double l = curve.LastParameter();
    switch (curve.GetType()) {
        case GeomAbs_Line:
            return curve.Value(f).Distance(curve.Value(l));
        case GeomAbs_Circle:
            return curve.Circle().Radius() * std::abs(l - f);
        default:
            break;
    }
    std::vector<double> ends = {f, l};
    const int pieces = curve.NbIntervals(GeomAbs_CN);
    TColStd_Array1OfReal breaks(1, pieces + 1);
    curve.Intervals(breaks, GeomAbs_CN);
    for (int i = 2; i <= pieces; ++i) {
        ends.push_back(breaks(i));
    }
    if (curve.GetType() == GeomAbs_Ellipse) {
        for (double t = std::ceil(f / (M_PI / 2.0)) * (M_PI / 2.0); t < l; t += M_PI / 2.0) {
            ends.push_back(t);
        }
    }
    std::sort(ends.begin(), ends.end());
    const Rule& coarse = gauss(10);
    const Rule& fine = gauss(20);
    auto rule_length = [&](const Rule& rule, double a, double b) {
        const double half = 0.5 * (b - a);
        const double mid = 0.5 * (a + b);
        double sum = 0.0;
        for (size_t j = 0; j < rule.x.size(); ++j) {
            gp_Pnt p;
            gp_Vec d;
            curve.D1(mid + half * rule.x[j], p, d);
            sum += d.Magnitude() * half * rule.w[j];
        }
        return sum;
    };
    // Pieces still to measure, with how often they have been halved. A piece is halved until the
    // two rules agree to rounding: of its own length, or of the whole edge's where its points read
    // less closely than that (a high-degree spline's do), at most 30 times and 20000 times in all
    // (a piece whose rules never agree halved every piece to the 30th level: an edge_info call on
    // a 0.5 mm helix never came back).
    std::vector<std::tuple<double, double, int>> pending;
    double whole = 0.0;
    for (size_t k = 0; k + 1 < ends.size(); ++k) {
        if (ends[k + 1] - ends[k] > 1e-15 * (l - f)) {
            pending.push_back({ends[k], ends[k + 1], 0});
            whole += rule_length(fine, ends[k], ends[k + 1]);
        }
    }
    double total = 0.0;
    int halvings = 0;
    while (!pending.empty()) {
        const auto [a, b, depth] = pending.back();
        pending.pop_back();
        const double rough = rule_length(coarse, a, b);
        const double exact = rule_length(fine, a, b);
        const double gap = std::abs(exact - rough);
        if (depth >= 30 || halvings >= 20000 || !(gap > 1e-14 * std::abs(exact)) || gap <= 1e-15 * std::abs(whole)) {
            total += exact;
            continue;
        }
        ++halvings;
        const double mid = 0.5 * (a + b);
        pending.push_back({a, mid, depth + 1});
        pending.push_back({mid, b, depth + 1});
    }
    return total;
}

double parameter_at_length(const TopoDS_Edge& edge, double distance)
{
    const BRepAdaptor_Curve curve(edge);
    const double f = curve.FirstParameter();
    const double l = curve.LastParameter();
    const double whole = length(edge);
    if (!(whole > 0.0) || distance <= 0.0) {
        return f;
    }
    if (distance >= whole) {
        return l;
    }
    if (curve.GetType() == GeomAbs_Line || curve.GetType() == GeomAbs_Circle) {
        return f + (l - f) * distance / whole;
    }
    double first = 0.0;
    double last = 0.0;
    const Handle(Geom_Curve) geometry = BRep_Tool::Curve(edge, first, last);
    if (geometry.IsNull()) {
        return f + (l - f) * distance / whole;
    }
    // Newton's steps on the length from the start, kept inside the bracket found so far (halving
    // it when a step would leave it).
    double lo = f;
    double hi = l;
    double u = f + (l - f) * distance / whole;
    for (int i = 0; i < 60; ++i) {
        const double got = length(BRepBuilderAPI_MakeEdge(geometry, f, u).Edge());
        const double miss = distance - got;
        if (std::abs(miss) <= 1e-13 * whole) {
            break;
        }
        (miss > 0.0 ? lo : hi) = u;
        gp_Pnt p;
        gp_Vec d;
        curve.D1(u, p, d);
        const double next = d.Magnitude() > 1e-300 ? u + miss / d.Magnitude() : 0.5 * (lo + hi);
        u = next > lo && next < hi ? next : 0.5 * (lo + hi);
        if (hi - lo <= 1e-15 * std::abs(l - f)) {
            break;
        }
    }
    return u;
}

TopoDS_Shape scaled_copy(const TopoDS_Shape& shape, const gp_Trsf& trsf)
{
    BRepBuilderAPI_Transform mover(shape, trsf, true);
    BRep_Builder builder;
    for (TopExp_Explorer it(shape, TopAbs_FACE); it.More(); it.Next()) {
        const TopoDS_Shape copy = mover.ModifiedShape(it.Current());
        if (!copy.IsNull() && copy.ShapeType() == TopAbs_FACE) {
            builder.UpdateFace(TopoDS::Face(copy), BRep_Tool::Tolerance(TopoDS::Face(it.Current())));
        }
    }
    return mover.Shape();
}

double mesh_area(const TopoDS_Face& face)
{
    TopLoc_Location location;
    const Handle(Poly_Triangulation) mesh = BRep_Tool::Triangulation(face, location);
    if (mesh.IsNull()) {
        return -1.0;
    }
    const gp_Trsf place = location.Transformation();
    double area = 0.0;
    for (int k = 1; k <= mesh->NbTriangles(); ++k) {
        int a = 0, b = 0, c = 0;
        mesh->Triangle(k).Get(a, b, c);
        const gp_Pnt pa = mesh->Node(a).Transformed(place);
        area += 0.5 * gp_Vec(pa, mesh->Node(b).Transformed(place)).Crossed(gp_Vec(pa, mesh->Node(c).Transformed(place))).Magnitude();
    }
    return area;
}

bool mesh_fits_together(const TopoDS_Shape& shape)
{
    TopTools_IndexedDataMapOfShapeListOfShape edge_faces;
    TopExp::MapShapesAndAncestors(shape, TopAbs_EDGE, TopAbs_FACE, edge_faces);
    std::vector<gp_Pnt> first;
    for (int i = 1; i <= edge_faces.Extent(); ++i) {
        const TopoDS_Edge& edge = TopoDS::Edge(edge_faces.FindKey(i));
        if (BRep_Tool::Degenerated(edge)) {
            continue;
        }
        bool have_first = false;
        TopoDS_Shape first_face;
        for (TopTools_ListOfShape::Iterator it(edge_faces(i)); it.More(); it.Next()) {
            // (A face that has the edge twice, a seam, has it once here.)
            if (have_first && it.Value().IsSame(first_face)) {
                continue;
            }
            TopLoc_Location location;
            const Handle(Poly_Triangulation) mesh = BRep_Tool::Triangulation(TopoDS::Face(it.Value()), location);
            if (mesh.IsNull()) {
                continue;
            }
            const Handle(Poly_PolygonOnTriangulation) polygon = BRep_Tool::PolygonOnTriangulation(edge, mesh, location);
            if (polygon.IsNull()) {
                return false;
            }
            const gp_Trsf place = location.Transformation();
            if (!have_first) {
                have_first = true;
                first_face = it.Value();
                first.clear();
                for (int k = 1; k <= polygon->NbNodes(); ++k) {
                    first.push_back(mesh->Node(polygon->Node(k)).Transformed(place));
                }
                continue;
            }
            if (size_t(polygon->NbNodes()) != first.size()) {
                return false;
            }
            // (The same points of the edge between its ends, to within its tolerance. Its ends are
            // its corners, which a face can hold off the edge (OCCT's thick solid hangs a rim's
            // inner loop on the outer loop's corner, a wall off its curve's ends): the mesh there
            // is the same however often the shape is meshed, and is drawn from pieces
            // (flat_face_pieces) where it matters.)
            const double near = 2.0 * BRep_Tool::Tolerance(edge) + Precision::Confusion();
            for (int k = 2; k < polygon->NbNodes(); ++k) {
                if (mesh->Node(polygon->Node(k)).Transformed(place).SquareDistance(first[size_t(k - 1)]) > near * near) {
                    return false;
                }
            }
        }
    }
    return true;
}

double edge_stray(const TopoDS_Face& face, gp_Pnt* at, bool* corner)
{
    double worst = 0.0;
    TopLoc_Location surface_location;
    const Handle(Geom_Surface) geometry = BRep_Tool::Surface(face, surface_location);
    const gp_Trsf surface_place = surface_location.Transformation();
    auto take = [&](double d, const gp_Pnt& where, bool is_corner) {
        if (d > worst) {
            worst = d;
            if (at != nullptr) {
                *at = where;
            }
            if (corner != nullptr) {
                *corner = is_corner;
            }
        }
    };
    for (TopExp_Explorer it(face, TopAbs_EDGE); it.More(); it.Next()) {
        const TopoDS_Edge& edge = TopoDS::Edge(it.Current());
        if (BRep_Tool::Degenerated(edge)) {
            continue;
        }
        double first = 0.0, last = 0.0;
        TopLoc_Location location;
        const Handle(Geom_Curve) curve = BRep_Tool::Curve(edge, location, first, last);
        if (curve.IsNull()) {
            continue;
        }
        const gp_Trsf place = location.Transformation();
        // Its ends against the corners it joins (either way round).
        TopoDS_Vertex v1, v2;
        TopExp::Vertices(edge, v1, v2);
        if (!v1.IsNull() && !v2.IsNull()) {
            const gp_Pnt a = curve->Value(first).Transformed(place);
            const gp_Pnt b = curve->Value(last).Transformed(place);
            const gp_Pnt p1 = BRep_Tool::Pnt(v1);
            const gp_Pnt p2 = BRep_Tool::Pnt(v2);
            const bool as_is = std::max(a.Distance(p1), b.Distance(p2)) <= std::max(a.Distance(p2), b.Distance(p1));
            const gp_Pnt& at_a = as_is ? p1 : p2;
            const gp_Pnt& at_b = as_is ? p2 : p1;
            take(a.Distance(at_a), at_a, true);
            take(b.Distance(at_b), at_b, true);
        }
        // Its own curve against the face's surface at its curve on it, at the same parameter (as
        // the mesher pairs them).
        double first2 = 0.0, last2 = 0.0;
        const Handle(Geom2d_Curve) on_face = BRep_Tool::CurveOnSurface(edge, face, first2, last2);
        if (on_face.IsNull() || geometry.IsNull()) {
            continue;
        }
        constexpr int STEPS = 16;
        for (int k = 0; k <= STEPS; ++k) {
            const double s = double(k) / STEPS;
            const gp_Pnt on_curve = curve->Value(first + (last - first) * s).Transformed(place);
            const gp_Pnt2d uv = on_face->Value(first2 + (last2 - first2) * s);
            take(on_curve.Distance(geometry->Value(uv.X(), uv.Y()).Transformed(surface_place)), on_curve, false);
        }
    }
    return worst;
}

double fold_area(const TopoDS_Face& face, gp_Pnt* at)
{
    TopLoc_Location location;
    const Handle(Geom_Surface) geometry = BRep_Tool::Surface(face, location);
    double u1 = 0.0, u2 = 0.0, v1 = 0.0, v2 = 0.0;
    if (geometry.IsNull() || !uv_bounds(face, u1, u2, v1, v2) || !(u2 > u1) || !(v2 > v1)) {
        return 0.0;
    }
    constexpr int N = 96;
    std::vector<gp_Vec> normals(size_t(N) * N);
    std::vector<gp_Pnt> points(size_t(N) * N);
    double largest = 0.0;
    for (int i = 0; i < N; ++i) {
        for (int j = 0; j < N; ++j) {
            gp_Vec du, dv;
            geometry->D1(u1 + (u2 - u1) * (i + 0.5) / N, v1 + (v2 - v1) * (j + 0.5) / N, points[size_t(i) * N + j], du, dv);
            normals[size_t(i) * N + j] = du.Crossed(dv);
            largest = std::max(largest, normals[size_t(i) * N + j].Magnitude());
        }
    }
    // (Where the surface comes to a point its normal is next to nothing and points anywhere.)
    const double least = 1e-6 * largest;
    const double cell = (u2 - u1) * (v2 - v1) / (double(N) * N);
    std::unique_ptr<BRepTopAdaptor_FClass2d> inside;
    double folded = 0.0;
    for (int i = 0; i < N; ++i) {
        for (int j = 0; j < N; ++j) {
            const gp_Vec& n = normals[size_t(i) * N + j];
            if (!(n.Magnitude() > least)) {
                continue;
            }
            const gp_Vec* before_u = i > 0 ? &normals[size_t(i - 1) * N + j] : nullptr;
            const gp_Vec* before_v = j > 0 ? &normals[size_t(i) * N + j - 1] : nullptr;
            const bool flips = (before_u != nullptr && before_u->Magnitude() > least && before_u->Dot(n) < 0.0) ||
                               (before_v != nullptr && before_v->Magnitude() > least && before_v->Dot(n) < 0.0);
            if (!flips) {
                continue;
            }
            if (!inside) {
                inside = std::make_unique<BRepTopAdaptor_FClass2d>(TopoDS::Face(face.Oriented(TopAbs_FORWARD)), Precision::PConfusion());
            }
            const TopAbs_State state = inside->Perform(gp_Pnt2d(u1 + (u2 - u1) * (i + 0.5) / N, v1 + (v2 - v1) * (j + 0.5) / N));
            if (state != TopAbs_IN && state != TopAbs_ON) {
                continue;
            }
            if (folded == 0.0 && at != nullptr) {
                *at = points[size_t(i) * N + j].Transformed(location.Transformation());
            }
            folded += n.Magnitude() * cell;
        }
    }
    return folded;
}

namespace
{
/// Whether a face's outline is one plain loop: one wire that passes each of its corners once and
/// uses no edge twice. The mesher fills such a loop as it is; the faces it misread had a hole
/// touching the outer wire, or a loop hung on another's corner (one wire, a figure of eight).
bool simple_outline(const TopoDS_Face& face)
{
    int wires = 0;
    for (TopExp_Explorer it(face, TopAbs_WIRE); it.More(); it.Next()) {
        ++wires;
    }
    if (wires != 1) {
        return false;
    }
    TopTools_IndexedMapOfShape edges;
    TopTools_IndexedMapOfShape corners;
    std::vector<int> uses;
    for (TopExp_Explorer it(face, TopAbs_EDGE); it.More(); it.Next()) {
        const TopoDS_Edge& edge = TopoDS::Edge(it.Current());
        if (BRep_Tool::Degenerated(edge) || edges.Contains(edge)) {
            return false;
        }
        edges.Add(edge);
        TopoDS_Vertex v1, v2;
        TopExp::Vertices(edge, v1, v2);
        if (v1.IsNull() || v2.IsNull()) {
            return false;
        }
        for (const TopoDS_Vertex& v : {v1, v2}) {
            const int at = corners.Add(v);
            if (at > int(uses.size())) {
                uses.push_back(0);
            }
            ++uses[size_t(at - 1)];
        }
    }
    return !uses.empty() && std::all_of(uses.begin(), uses.end(), [](int n) { return n == 2; });
}

/// How far a meshed face's nodes lie from its surface at their own parameters: every node of its
/// edges' polygons (the mesher takes those from the edges' curves and corners, the rest from the
/// surface itself), and up to about a thousand of the others. 0 when the mesh has no parameters.
double node_stray(const TopoDS_Face& face, const Handle(Poly_Triangulation)& mesh, const TopLoc_Location& location)
{
    TopLoc_Location surface_location;
    const Handle(Geom_Surface) geometry = BRep_Tool::Surface(face, surface_location);
    if (mesh.IsNull() || !mesh->HasUVNodes() || geometry.IsNull()) {
        return 0.0;
    }
    const gp_Trsf place = location.Transformation();
    const gp_Trsf surface_place = surface_location.Transformation();
    double worst = 0.0;
    auto check = [&](int n) {
        const gp_Pnt2d uv = mesh->UVNode(n);
        worst = std::max(worst, mesh->Node(n).Transformed(place).Distance(geometry->Value(uv.X(), uv.Y()).Transformed(surface_place)));
    };
    for (TopExp_Explorer it(face, TopAbs_EDGE); it.More(); it.Next()) {
        const Handle(Poly_PolygonOnTriangulation) polygon = BRep_Tool::PolygonOnTriangulation(TopoDS::Edge(it.Current()), mesh, location);
        if (polygon.IsNull()) {
            continue;
        }
        for (int i = 1; i <= polygon->NbNodes(); ++i) {
            const int n = polygon->Node(i);
            if (n >= 1 && n <= mesh->NbNodes()) {
                check(n);
            }
        }
    }
    const int stride = std::max(1, mesh->NbNodes() / 1024);
    for (int n = 1; n <= mesh->NbNodes(); n += stride) {
        check(n);
    }
    return worst;
}
}  // namespace

bool mesh_covers_face(const TopoDS_Face& face, double deflection, double angle, double* face_area, double* meshed, double* stray, double stray_limit,
                      bool every_area)
{
    const double covered = mesh_area(face);
    if (meshed != nullptr) {
        *meshed = covered;
    }
    if (stray != nullptr) {
        *stray = 0.0;
    }
    // (No mesh at all: the face is left out of what is drawn and exported, unless it has no area
    // to speak of.)
    if (covered < 0.0) {
        const double own = surface(face).Mass();
        if (face_area != nullptr) {
            *face_area = own;
        }
        return std::abs(own) <= 4.0 * deflection * deflection;
    }
    bool elementary = false;
    switch (BRepAdaptor_Surface(face, false).GetType()) {
        case GeomAbs_Plane:
        case GeomAbs_Cylinder:
        case GeomAbs_Cone:
        case GeomAbs_Sphere:
        case GeomAbs_Torus:
            elementary = true;
            break;
        default:
            break;
    }
    TopLoc_Location location;
    const Handle(Poly_Triangulation) mesh = BRep_Tool::Triangulation(face, location);
    // What a sound mesh can be off by: its facets' chords across a bend, at most the angle's half
    // each way (an arc's chord polygon is short by about the half angle squared over 6 of its
    // area, on a doubly curved face twice that), and a fiftieth on top; and along each curved
    // edge, the strip between the edge and the chords a mesh at this deflection and angle cuts it
    // into, across the face (a hole's rim on a flat face; not a round's rim on its own round,
    // whose chords cut in under the face, which the facets' part holds). That strip is measured
    // on the edge's own chords at the deflection asked for, at a quarter, half and three quarters
    // of each (a spline edge's bend between two chord ends: a horseshoe's rim), twice over: never
    // on the mesh being judged (a mesh with its rims in a few chords bought itself the room to
    // leave out half the face). At most three tenths of the face either way: a lid or a missing
    // piece is a whole region of the face.
    // (The edges' part, measured only when it is needed.)
    double along = -1.0;
    auto along_edges = [&]() {
        if (along >= 0.0) {
            return along;
        }
        along = 0.0;
        const BRepAdaptor_Surface across(face, false);
        for (TopExp_Explorer it(face, TopAbs_EDGE); it.More(); it.Next()) {
            const TopoDS_Edge& edge = TopoDS::Edge(it.Current());
            if (BRep_Tool::Degenerated(edge)) {
                continue;
            }
            try {
                const BRepAdaptor_Curve curve(edge);
                if (curve.GetType() == GeomAbs_Line) {
                    continue;
                }
                double first = 0.0, last = 0.0;
                const Handle(Geom2d_Curve) on = BRep_Tool::CurveOnSurface(edge, face, first, last);
                const GCPnts_TangentialDeflection chords(curve, std::min(std::abs(angle), M_PI), std::abs(deflection), 2, 1e-9, 1e-12);
                for (int i = 1; i < chords.NbPoints(); ++i) {
                    const gp_Pnt a = chords.Value(i);
                    const gp_Vec ab(a, chords.Value(i + 1));
                    const double span = ab.SquareMagnitude();
                    double off = 0.0;
                    for (const double s : {0.25, 0.5, 0.75}) {
                        const double t = chords.Parameter(i) + s * (chords.Parameter(i + 1) - chords.Parameter(i));
                        const gp_Pnt p = curve.Value(t);
                        const double k = span > 0.0 ? std::clamp(gp_Vec(a, p).Dot(ab) / span, 0.0, 1.0) : 0.0;
                        gp_Vec away(a.Translated(ab * k), p);
                        // (Only its part across the face.)
                        if (!on.IsNull()) {
                            const gp_Pnt2d uv = on->Value(t);
                            gp_Pnt q;
                            gp_Vec du, dv;
                            across.D1(uv.X(), uv.Y(), q, du, dv);
                            const gp_Vec normal = du.Crossed(dv);
                            if (normal.Magnitude() > gp::Resolution()) {
                                const gp_Vec n = normal.Normalized();
                                away -= n * away.Dot(n);
                            }
                        }
                        off = std::max(off, away.Magnitude());
                    }
                    along += 2.0 * off * std::sqrt(span);
                }
            }
            catch (const Standard_Failure&) {
                along += std::abs(deflection) * length(edge);
            }
        }
        return along;
    };
    const double half = 0.5 * std::min(std::abs(angle), M_PI);
    // (Within the facets' part alone first: most faces are, and need no edge measured.)
    auto within = [&](double own) {
        const double area = std::abs(own);
        const double miss = std::abs(covered - area);
        const double facets = (0.02 + half * half / 3.0) * area;
        const double slack = 4.0 * deflection * deflection;
        if (miss <= facets + slack) {
            return true;
        }
        return miss <= std::min(facets + along_edges(), std::max(0.3, 0.02 + half * half / 3.0) * area) + slack;
    };
    if (elementary) {
        const double own = surface(face).Mass();
        if (face_area != nullptr) {
            *face_area = own;
        }
        return within(own);
    }
    // A face of any other kind (a spline, an offset, a swept one): its mesh's nodes must lie on
    // it. The mesher puts a corner's node at the corner and an edge's on the edge's curve, and
    // OCCT's blends at loose tolerances leave corners millimetres off the edges that meet there
    // (see edge_stray): the faces around such a corner are drawn pulled off themselves at every
    // deflection. A few deflections are let be (the edges' own tolerances), or what the caller
    // allows.
    const double off = node_stray(face, mesh, location);
    if (stray != nullptr) {
        *stray = off;
    }
    if (off > (stray_limit < 0.0 ? 4.0 * std::abs(deflection) : stray_limit) + Precision::Confusion()) {
        if (face_area != nullptr) {
            *face_area = surface(face).Mass();
        }
        return false;
    }
    // Its area, as the elementary faces', where the mesher could have misread its wires (or
    // always, when asked): measuring a spline face takes milliseconds (OCCT's own measure more
    // than the exact one), a body of them as long as meshing it.
    if (!every_area && simple_outline(face)) {
        return true;
    }
    const double own = surface(face).Mass();
    if (face_area != nullptr) {
        *face_area = own;
    }
    return within(own);
}

std::vector<TopoDS_Face> flat_face_pieces(const TopoDS_Face& face, double own_area, double deflection, double angle)
{
    std::vector<TopoDS_Face> out;
    BRepAdaptor_Surface adaptor(face, false);
    if (adaptor.GetType() != GeomAbs_Plane || !(own_area > 0.0)) {
        return out;
    }
    try {
        const TopoDS_Face forward = TopoDS::Face(face.Oriented(TopAbs_FORWARD));
        const Handle(Geom_Surface) surface = BRep_Tool::Surface(forward);
        if (surface.IsNull()) {
            return out;
        }
        const gp_Dir normal = adaptor.Plane().Axis().Direction();
        Bnd_Box box;
        BRepBndLib::Add(forward, box);
        const double size = box.IsVoid() ? 1.0 : std::sqrt(box.SquareExtent());
        const double thick = std::max(1e-9, 1e-3 * size);
        auto face_of = [&](const TopoDS_Wire& wire) {
            BRepBuilderAPI_MakeFace make(surface, TopoDS::Wire(wire.Oriented(TopAbs_FORWARD)), Standard_True);
            if (!make.IsDone()) {
                return TopoDS_Face();
            }
            ShapeFix_Face fix(make.Face());
            fix.FixOrientation();
            fix.Perform();
            return fix.Face();
        };
        // Its loops: its edges but those it runs along both ways (a seam bridging two loops on a
        // flat face, as OCCT's thick solid gives the rim round an outline of one closed spline
        // edge: one wire the mesher fills to the outer loop), joined up again; the one holding
        // the most is the outer one, the others holes.
        TopTools_IndexedMapOfShape seen;
        std::vector<int> uses;
        for (TopExp_Explorer it(forward, TopAbs_EDGE); it.More(); it.Next()) {
            const int at = seen.Add(it.Current());
            if (at > int(uses.size())) {
                uses.push_back(0);
            }
            ++uses[size_t(at - 1)];
        }
        Handle(TopTools_HSequenceOfShape) edges = new TopTools_HSequenceOfShape();
        for (int i = 1; i <= seen.Extent(); ++i) {
            if (uses[size_t(i - 1)] == 1 && !BRep_Tool::Degenerated(TopoDS::Edge(seen(i)))) {
                edges->Append(seen(i));
            }
        }
        // (An edge closed on itself is a loop of its own, made afresh from its curve: OCCT's thick
        // solid can hang a rim's inner loop on the outer loop's corner, a wall off its curve's
        // ends, which joins the two loops into one figure of eight.)
        Handle(TopTools_HSequenceOfShape) open_edges = new TopTools_HSequenceOfShape();
        std::vector<TopoDS_Wire> rings;
        for (int i = 1; i <= edges->Length(); ++i) {
            const TopoDS_Edge& edge = TopoDS::Edge(edges->Value(i));
            TopoDS_Vertex v1, v2;
            TopExp::Vertices(edge, v1, v2);
            double first = 0.0, last = 0.0;
            const Handle(Geom_Curve) curve = BRep_Tool::Curve(edge, first, last);
            if (!v1.IsNull() && v1.IsSame(v2) && !curve.IsNull()) {
                BRepBuilderAPI_MakeEdge remade(curve, first, last);
                if (!remade.IsDone()) {
                    return out;
                }
                rings.push_back(BRepBuilderAPI_MakeWire(remade.Edge()).Wire());
                continue;
            }
            open_edges->Append(edge);
        }
        Handle(TopTools_HSequenceOfShape) wires;
        ShapeAnalysis_FreeBounds::ConnectEdgesToWires(open_edges, 1e-7 * size, Standard_True, wires);
        std::vector<TopoDS_Wire> all(rings);
        for (int i = 1; !wires.IsNull() && i <= wires->Length(); ++i) {
            all.push_back(TopoDS::Wire(wires->Value(i)));
        }
        std::vector<std::pair<double, TopoDS_Face>> loops;
        for (const TopoDS_Wire& wire : all) {
            if (!BRep_Tool::IsClosed(wire)) {
                return out;
            }
            const TopoDS_Face loop = face_of(wire);
            if (loop.IsNull()) {
                return out;
            }
            GProp_GProps props;
            BRepGProp::SurfaceProperties(loop, props);
            loops.push_back({std::abs(props.Mass()), loop});
        }
        if (loops.empty()) {
            return out;
        }
        std::sort(loops.begin(), loops.end(), [](const auto& a, const auto& b) { return a.first > b.first; });
        TopoDS_Shape region = loops.front().second;
        for (size_t k = 1; k < loops.size(); ++k) {
            gp_Trsf down;
            down.SetTranslation(gp_Vec(normal) * (-0.5 * thick));
            const TopoDS_Shape slab = BRepPrimAPI_MakePrism(BRepBuilderAPI_Transform(loops[k].second, down, true).Shape(), gp_Vec(normal) * thick, true).Shape();
            BRepAlgoAPI_Cut cut(region, slab);
            if (!cut.IsDone() || cut.Shape().IsNull()) {
                return out;
            }
            region = cut.Shape();
        }
        double total = 0.0;
        std::vector<TopoDS_Face> pieces;
        for (TopExp_Explorer it(region, TopAbs_FACE); it.More(); it.Next()) {
            TopoDS_Face piece = TopoDS::Face(it.Current());
            // (Facing as the face does.)
            const BRepAdaptor_Surface here(piece, false);
            const bool flipped = (here.Plane().Axis().Direction().Dot(normal) < 0.0) != (piece.Orientation() == TopAbs_REVERSED);
            if (flipped) {
                piece.Reverse();
            }
            if (face.Orientation() == TopAbs_REVERSED) {
                piece.Reverse();
            }
            BRepMesh_IncrementalMesh mesher(piece, deflection, Standard_False, angle, Standard_False);
            double area = 0.0;
            if (!mesh_covers_face(piece, deflection, angle, &area)) {
                return out;
            }
            total += area;
            pieces.push_back(piece);
        }
        // (Within a thousandth: a loop made afresh from its curve no longer runs out to the corner
        // it was hung on.)
        if (pieces.empty() || std::abs(total - own_area) > 1e-3 * own_area) {
            return out;
        }
        out = pieces;
    }
    catch (const Standard_Failure&) {
        out.clear();
    }
    return out;
}

bool face_drawable(const TopoDS_Face& face, double deflection, double angle, double* face_area, double* meshed, double* stray, double stray_limit,
                   bool every_area)
{
    double own = 0.0;
    if (mesh_covers_face(face, deflection, angle, &own, meshed, stray, stray_limit, every_area)) {
        if (face_area != nullptr) {
            *face_area = own;
        }
        return true;
    }
    if (face_area != nullptr) {
        *face_area = own;
    }
    return !flat_face_pieces(face, own, deflection, angle).empty();
}

}  // namespace holo_forge::measure
