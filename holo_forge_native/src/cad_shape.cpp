#include "cad_shape.h"

#include <cstdio>
#include <cstring>
#include <sstream>
#include <utility>
#include <vector>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>

#include <godot_cpp/variant/packed_string_array.hpp>

#include <BRepAdaptor_Curve.hxx>
#include <BRepLProp_SLProps.hxx>
#include <gp_Mat.hxx>
#include <GProp_PrincipalProps.hxx>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <BRepAdaptor_Surface.hxx>
#include <BRepBuilderAPI_MakeVertex.hxx>
#include <BRepExtrema_DistShapeShape.hxx>
#include <BRepGProp_Face.hxx>
#include <Geom2d_Curve.hxx>
#include <GeomAPI_ProjectPointOnSurf.hxx>
#include <Geom_Surface.hxx>
#include <ShapeAnalysis_Curve.hxx>
#include <TopExp_Explorer.hxx>
#include <TopTools_IndexedDataMapOfShapeListOfShape.hxx>
#include <TopTools_ListOfShape.hxx>
#include <gp_Circ.hxx>

#include "measure.h"
#include "naming.h"
#include <BRepClass_FClassifier.hxx>
#include <BRepClass_FaceExplorer.hxx>
#include <BRepTools.hxx>
#include <Precision.hxx>
#include <gp_Pnt2d.hxx>
#include <BRepBndLib.hxx>
#include <BRepGProp.hxx>
#include <BRepLib_ToolTriangulatedShape.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRep_Builder.hxx>
#include <BRep_Tool.hxx>
#include <Poly_Triangle.hxx>
#include <Standard_Failure.hxx>
#include <BinTools.hxx>
#include <Bnd_Box.hxx>
#include <GCPnts_TangentialDeflection.hxx>
#include <GProp_GProps.hxx>
#include <Poly_PolygonOnTriangulation.hxx>
#include <Poly_Triangulation.hxx>
#include <TColStd_Array1OfInteger.hxx>
#include <Standard_Failure.hxx>
#include <TopExp.hxx>
#include <TopLoc_Location.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Vertex.hxx>
#include <Geom2dAdaptor_Curve.hxx>
#include <Geom2dHatch_Hatcher.hxx>
#include <Geom2dHatch_Intersector.hxx>
#include <Geom2d_Line.hxx>
#include <HatchGen_Domain.hxx>
#include <gp_Dir2d.hxx>

using namespace godot;

namespace holo_forge
{

namespace
{
Vector3 to_godot(const gp_Pnt& p)
{
    return Vector3(real_t(p.X()), real_t(p.Y()), real_t(p.Z()));
}

Vector3 to_godot(const gp_Vec& v)
{
    return Vector3(real_t(v.X()), real_t(v.Y()), real_t(v.Z()));
}

/// The parts of a face's iso lines inside it, from OCCT's hatcher (as its own iso display finds
/// them): for each fixed value, the sorted (start, end) parameter ranges along the line (v for
/// lines of constant u, direction 0; u otherwise) where the line is inside the face, clamped to
/// [run0, run1]. Exact where the line crosses the boundary, with no sampling or bisection. False
/// when the hatcher can't do it (the caller then samples).
bool hatch_isolines(const TopoDS_Face& face, int direction, const std::vector<double>& fixed_values, double run0, double run1,
                    std::vector<std::vector<std::pair<double, double>>>& domains)
{
    const TopoDS_Face forward = TopoDS::Face(face.Oriented(TopAbs_FORWARD));
    Geom2dHatch_Hatcher hatcher(Geom2dHatch_Intersector(1e-10, 1e-10), 1e-8, 1e-8, true, false);
    int elements = 0;
    for (TopExp_Explorer it(forward, TopAbs_EDGE); it.More(); it.Next()) {
        const TopoDS_Edge& edge = TopoDS::Edge(it.Current());
        double first = 0.0, last = 0.0;
        const Handle(Geom2d_Curve) pcurve = BRep_Tool::CurveOnSurface(edge, forward, first, last);
        if (pcurve.IsNull()) {
            return false;
        }
        if (first == last) {
            continue;
        }
        hatcher.AddElement(Geom2dAdaptor_Curve(pcurve, first, last), edge.Orientation());
        ++elements;
    }
    if (elements == 0) {
        return false;
    }
    std::vector<int> ids;
    for (const double fixed : fixed_values) {
        const gp_Pnt2d origin = direction == 0 ? gp_Pnt2d(fixed, 0.0) : gp_Pnt2d(0.0, fixed);
        const gp_Dir2d along = direction == 0 ? gp_Dir2d(0.0, 1.0) : gp_Dir2d(1.0, 0.0);
        const int id = hatcher.AddHatching(Geom2dAdaptor_Curve(new Geom2d_Line(origin, along)));
        hatcher.Trim(id);
        ids.push_back(id);
    }
    domains.assign(fixed_values.size(), {});
    for (size_t k = 0; k < ids.size(); ++k) {
        hatcher.ComputeDomains(ids[k]);
        if (!hatcher.IsDone(ids[k])) {
            return false;
        }
        for (int d = 1; d <= hatcher.NbDomains(ids[k]); ++d) {
            const HatchGen_Domain& domain = hatcher.Domain(ids[k], d);
            const double a = std::max(domain.HasFirstPoint() ? domain.FirstPoint().Parameter() : run0, run0);
            const double b = std::min(domain.HasSecondPoint() ? domain.SecondPoint().Parameter() : run1, run1);
            if (b > a) {
                domains[k].push_back({a, b});
            }
        }
        std::sort(domains[k].begin(), domains[k].end());
    }
    return true;
}

int count_sub_shapes(const TopoDS_Shape& shape, TopAbs_ShapeEnum type)
{
    if (shape.IsNull()) {
        return 0;
    }
    TopTools_IndexedMapOfShape map;
    TopExp::MapShapes(shape, type, map);
    return map.Extent();
}
}  // namespace

Ref<CadShape> CadShape::wrap(const TopoDS_Shape& shape)
{
    Ref<CadShape> result;
    result.instantiate();
    result->set_occ_shape(shape);
    return result;
}

const TopTools_IndexedMapOfShape& CadShape::face_map() const
{
    if (!face_map_cache) {
        face_map_cache = std::make_unique<TopTools_IndexedMapOfShape>();
        if (!shape.IsNull()) {
            TopExp::MapShapes(shape, TopAbs_FACE, *face_map_cache);
        }
    }
    return *face_map_cache;
}

const TopTools_IndexedMapOfShape& CadShape::edge_map() const
{
    if (!edge_map_cache) {
        edge_map_cache = std::make_unique<TopTools_IndexedMapOfShape>();
        if (!shape.IsNull()) {
            TopExp::MapShapes(shape, TopAbs_EDGE, *edge_map_cache);
        }
    }
    return *edge_map_cache;
}

const TopTools_IndexedMapOfShape& CadShape::vertex_map() const
{
    if (!vertex_map_cache) {
        vertex_map_cache = std::make_unique<TopTools_IndexedMapOfShape>();
        if (!shape.IsNull()) {
            TopExp::MapShapes(shape, TopAbs_VERTEX, *vertex_map_cache);
        }
    }
    return *vertex_map_cache;
}

const TopTools_IndexedDataMapOfShapeListOfShape& CadShape::edge_face_map() const
{
    if (!edge_faces_cache) {
        edge_faces_cache = std::make_unique<TopTools_IndexedDataMapOfShapeListOfShape>();
        if (!shape.IsNull()) {
            TopExp::MapShapesAndAncestors(shape, TopAbs_EDGE, TopAbs_FACE, *edge_faces_cache);
        }
    }
    return *edge_faces_cache;
}

void CadShape::reset_maps()
{
    bbox_cache.reset();
    volume_cache.reset();
    surface_cache.reset();
    face_area_cache.clear();
    face_map_cache.reset();
    edge_map_cache.reset();
    vertex_map_cache.reset();
    edge_faces_cache.reset();
}

bool CadShape::is_null() const
{
    return shape.IsNull();
}

String CadShape::shape_type() const
{
    if (shape.IsNull()) {
        return "NULL";
    }
    switch (shape.ShapeType()) {
        case TopAbs_COMPOUND:
            return "COMPOUND";
        case TopAbs_COMPSOLID:
            return "COMPSOLID";
        case TopAbs_SOLID:
            return "SOLID";
        case TopAbs_SHELL:
            return "SHELL";
        case TopAbs_FACE:
            return "FACE";
        case TopAbs_WIRE:
            return "WIRE";
        case TopAbs_EDGE:
            return "EDGE";
        case TopAbs_VERTEX:
            return "VERTEX";
        default:
            return "SHAPE";
    }
}

double CadShape::volume() const
{
    if (shape.IsNull()) {
        return 0.0;
    }
    // Only closed shells count: an open shell (a surface body) has no inside, and OCCT would
    // otherwise report a made-up volume from its open faces.
    return volume_props().Mass();
}

double CadShape::area() const
{
    if (shape.IsNull()) {
        return 0.0;
    }
    return surface_props().Mass();
}

Vector3 CadShape::center_of_mass() const
{
    if (shape.IsNull()) {
        return Vector3();
    }
    return to_godot(volume_props().CentreOfMass());
}

Vector3 CadShape::area_center() const
{
    if (shape.IsNull()) {
        return Vector3();
    }
    return to_godot(surface_props().CentreOfMass());
}

const GProp_GProps& CadShape::volume_props() const
{
    if (!volume_cache) {
        volume_cache = std::make_unique<GProp_GProps>(measure::volume(shape));
    }
    return *volume_cache;
}

const GProp_GProps& CadShape::surface_props() const
{
    if (!surface_cache) {
        surface_cache = std::make_unique<GProp_GProps>(measure::surface(shape));
    }
    return *surface_cache;
}

AABB CadShape::bbox() const
{
    if (shape.IsNull()) {
        return AABB();
    }
    if (bbox_cache) {
        return *bbox_cache;
    }
    // The box of the geometry itself, never of a mesh made earlier (BRepBndLib::Add takes one when
    // it finds it, so the box changed once a shape was drawn), and never smaller than the shape
    // (see measure::box). It finds a flat face's zero thickness only to within rounding: there the
    // plain box (a flat face's edges, a spline's control points) is taken where it is tighter by
    // no more than that.
    const Bnd_Box precise = measure::box(shape);
    Bnd_Box plain;
    BRepBndLib::Add(shape, plain, false);
    if (precise.IsVoid() || plain.IsVoid()) {
        return AABB();
    }
    // Bnd_Box adds a small gap around the shape; it is removed so sizes are exact.
    double lo[3], hi[3], plain_lo[3], plain_hi[3];
    precise.Get(lo[0], lo[1], lo[2], hi[0], hi[1], hi[2]);
    plain.Get(plain_lo[0], plain_lo[1], plain_lo[2], plain_hi[0], plain_hi[1], plain_hi[2]);
    const double rounding = 1e-12 * std::sqrt(precise.SquareExtent()) + 1e-15;
    for (int i = 0; i < 3; ++i) {
        lo[i] += precise.GetGap();
        hi[i] -= precise.GetGap();
        const double plain_low = plain_lo[i] + plain.GetGap();
        const double plain_high = plain_hi[i] - plain.GetGap();
        if (plain_low > lo[i] && plain_low <= lo[i] + rounding) {
            lo[i] = plain_low;
        }
        if (plain_high < hi[i] && plain_high >= hi[i] - rounding) {
            hi[i] = plain_high;
        }
        // A flat shape (a surface) can come out a hair below zero thick: it is zero.
        if (hi[i] < lo[i]) {
            lo[i] = hi[i] = 0.5 * (lo[i] + hi[i]);
        }
    }
    bbox_cache = std::make_unique<AABB>(
        Vector3(real_t(lo[0]), real_t(lo[1]), real_t(lo[2])),
        Vector3(real_t(hi[0] - lo[0]), real_t(hi[1] - lo[1]), real_t(hi[2] - lo[2]))
    );
    return *bbox_cache;
}

int CadShape::face_count() const
{
    return face_map().Extent();
}

int CadShape::edge_count() const
{
    return edge_map().Extent();
}

int CadShape::vertex_count() const
{
    return vertex_map().Extent();
}

Dictionary CadShape::tessellate(double linear_deflection, double angular_deflection) const
{
    Dictionary out;
    PackedVector3Array positions;
    PackedVector3Array normals;
    PackedVector2Array uvs;
    PackedInt32Array indices;
    PackedInt32Array face_ids;
    PackedVector3Array edge_points;
    PackedInt32Array edge_ids;
    PackedVector3Array vertices;

    if (shape.IsNull()) {
        return out;
    }

    try {
        PackedStringArray warnings;
        bool meshed_again = false;
        if (!test_mesh_frozen) {
            // Single-threaded on purpose: OCCT's parallel mode starts a thread pool that deadlocks
            // against the Windows loader lock when Godot unloads the DLL at exit.
            BRepMesh_IncrementalMesh mesher(shape, linear_deflection, Standard_False, angular_deflection, Standard_False);
            // The mesher leaves a face be when it finds it meshed finely enough already. A face
            // this shape shares with another (a tool's result keeps the faces the tool left
            // alone) may have been meshed again there, finer: its mesh then runs through other
            // points of its edges than the meshes of this shape's faces beside it, and the shape
            // would be drawn with open edges all along them. Then the whole shape is meshed afresh.
            if (!measure::mesh_fits_together(shape)) {
                BRepTools::Clean(shape);
                BRepMesh_IncrementalMesh again(shape, linear_deflection, Standard_False, angular_deflection, Standard_False);
                meshed_again = true;
                if (!measure::mesh_fits_together(shape)) {
                    const String warning = "the meshes of its faces don't meet along some of their edges, so it is drawn and exported with open edges there";
                    warnings.push_back(warning);
                    UtilityFunctions::push_warning("CadShape.tessellate: ", warning);
                }
            }
        }

        const TopTools_IndexedMapOfShape& faces = face_map();
        // Each face's mesh must cover the face: one whose wires the mesher misreads (a hole
        // touching its outer wire) is meshed with a lid over the hole or a piece left out. A face
        // with no mesh at all (the mesher gave up on it, or left it be) or a curved one meshed
        // wrong has the whole shape meshed afresh, once. Then a flat one is meshed again from
        // pieces it reads right; any other is warned of, by name. So is a spline face whose mesh
        // lies off it (a corner of it off the edges that meet there, as OCCT's blends can leave
        // them: the mesh around the corner is pulled off the face; meshing it again won't help).
        struct Judged {
            bool covers = true;
            bool bare = false;
            double own = 0.0, covered = 0.0, stray = 0.0;
        };
        std::vector<Judged> judged(size_t(faces.Extent()));
        auto judge = [&]() {
            bool again = false;
            for (int fi = 1; fi <= faces.Extent(); ++fi) {
                const TopoDS_Face& face = TopoDS::Face(faces(fi));
                Judged& j = judged[size_t(fi - 1)];
                j = Judged();
                j.covers = measure::mesh_covers_face(face, linear_deflection, angular_deflection, &j.own, &j.covered, &j.stray);
                j.bare = j.covered < 0.0;
                if (!j.covers &&
                    (j.bare || (BRepAdaptor_Surface(face, false).GetType() != GeomAbs_Plane && j.stray <= 4.0 * std::abs(linear_deflection)))) {
                    again = true;
                }
            }
            return again;
        };
        if (judge() && !meshed_again && !test_remesh_blocked) {
            BRepTools::Clean(shape);
            BRepMesh_IncrementalMesh again(shape, linear_deflection, Standard_False, angular_deflection, Standard_False);
            judge();
        }
        for (int fi = 1; fi <= faces.Extent(); ++fi) {
            const TopoDS_Face& whole = TopoDS::Face(faces(fi));
            std::vector<TopoDS_Face> parts{whole};
            const Judged& j = judged[size_t(fi - 1)];
            const double own = j.own, covered = j.covered, stray = j.stray;
            if (!j.covers && j.bare) {
                char text[256];
                std::snprintf(text, sizeof(text), "face %d has no mesh (the mesher gave it no triangles), so its %.4g mm2 are left out of what is drawn and exported", fi - 1,
                              own * 1e6);
                const String warning = String::utf8(text);
                warnings.push_back(warning);
                UtilityFunctions::push_warning("CadShape.tessellate: ", warning);
                continue;
            }
            if (!j.covers) {
                std::vector<TopoDS_Face> remade = measure::flat_face_pieces(whole, own, linear_deflection, angular_deflection);
                if (!remade.empty()) {
                    parts = remade;
                }
                else {
                    // (Formatted here: Godot's vformat has no %g, and the warning came out as
                    // "unsupported format character".)
                    char text[256];
                    if (stray > 4.0 * std::abs(linear_deflection)) {
                        std::snprintf(text, sizeof(text),
                                      "face %d's mesh lies up to %.4g mm off the face (a corner or an edge of it is not on it) and covers %.4g mm2 of its %.4g mm2, "
                                      "so it is drawn and exported wrong there",
                                      fi - 1, stray * 1e3, covered * 1e6, own * 1e6);
                    }
                    else {
                        std::snprintf(text, sizeof(text), "face %d's mesh covers %.4g mm2 of its %.4g mm2, so it is drawn and exported wrong there", fi - 1, covered * 1e6,
                                      own * 1e6);
                    }
                    const String warning = String::utf8(text);
                    warnings.push_back(warning);
                    UtilityFunctions::push_warning("CadShape.tessellate: ", warning);
                }
            }
            for (const TopoDS_Face& face : parts) {
            TopLoc_Location location;
            Handle(Poly_Triangulation) tri = BRep_Tool::Triangulation(face, location);
            if (tri.IsNull()) {
                continue;
            }
            if (!tri->HasNormals()) {
                BRepLib_ToolTriangulatedShape::ComputeNormals(face, tri);
            }
            const gp_Trsf trsf = location.Transformation();
            const bool reversed = face.Orientation() == TopAbs_REVERSED;
            const int base = int(positions.size());

            for (int n = 1; n <= tri->NbNodes(); ++n) {
                positions.push_back(to_godot(tri->Node(n).Transformed(trsf)));
                gp_Vec normal(tri->Normal(n));
                normal.Transform(trsf);
                if (reversed) {
                    normal.Reverse();
                }
                normals.push_back(to_godot(normal));
                if (tri->HasUVNodes()) {
                    const gp_Pnt2d uv = tri->UVNode(n);
                    uvs.push_back(Vector2(real_t(uv.X()), real_t(uv.Y())));
                }
                else {
                    uvs.push_back(Vector2());
                }
            }

            // The outward normals of each node's triangles, summed (area weighted).
            std::vector<gp_Vec> around(size_t(tri->NbNodes()), gp_Vec(0.0, 0.0, 0.0));
            for (int t = 1; t <= tri->NbTriangles(); ++t) {
                int a = 0, b = 0, c = 0;
                tri->Triangle(t).Get(a, b, c);
                if (reversed) {
                    std::swap(b, c);
                }
                // OCCT winds counter-clockwise around the outward normal; Godot front faces are
                // clockwise, so b and c trade places.
                indices.push_back(base + a - 1);
                indices.push_back(base + c - 1);
                indices.push_back(base + b - 1);
                face_ids.push_back(fi - 1);
                const gp_Pnt pa = tri->Node(a).Transformed(trsf);
                const gp_Vec outward = gp_Vec(pa, tri->Node(b).Transformed(trsf)).Crossed(gp_Vec(pa, tri->Node(c).Transformed(trsf)));
                around[size_t(a - 1)] += outward;
                around[size_t(b - 1)] += outward;
                around[size_t(c - 1)] += outward;
            }
            // At a singular point (a sphere's pole, a cone's apex) the surface has no normal of
            // its own, and the one OCCT falls back to can be zero or point inward (a dark or
            // bright dot when lit): there the node takes its triangles' mean normal instead.
            for (int n = 0; n < tri->NbNodes(); ++n) {
                const gp_Vec& mean = around[size_t(n)];
                if (mean.SquareMagnitude() <= 0.0) {
                    continue;
                }
                const Vector3 current = normals[base + n];
                const gp_Vec given(current.x, current.y, current.z);
                if (given.SquareMagnitude() < 1e-12 || given.Dot(mean) <= 0.0) {
                    normals.set(base + n, to_godot(mean.Normalized()));
                }
            }
            }
        }
        if (!warnings.is_empty()) {
            out["warnings"] = warnings;
        }

        // Each edge's line runs through its face's mesh nodes (the mesher shares an edge's nodes
        // between the faces on either side), so it lies exactly on the drawn facets. Sampled
        // from the curve on its own, a curved edge between curved faces wandered in front of and
        // behind the facets' chords and drew dotted (a converted form body's patch borders).
        const TopTools_IndexedMapOfShape& edges = edge_map();
        const TopTools_IndexedDataMapOfShapeListOfShape& edge_faces = edge_face_map();
        for (int ei = 1; ei <= edges.Extent(); ++ei) {
            const TopoDS_Edge& edge = TopoDS::Edge(edges(ei));
            if (BRep_Tool::Degenerated(edge)) {
                continue;
            }
            bool meshed = false;
            const int at = edge_faces.FindIndex(edge);
            if (at > 0) {
                for (TopTools_ListOfShape::Iterator it(edge_faces(at)); it.More() && !meshed; it.Next()) {
                    TopLoc_Location location;
                    const Handle(Poly_Triangulation) tri = BRep_Tool::Triangulation(TopoDS::Face(it.Value()), location);
                    if (tri.IsNull()) {
                        continue;
                    }
                    const Handle(Poly_PolygonOnTriangulation) polygon = BRep_Tool::PolygonOnTriangulation(edge, tri, location);
                    if (polygon.IsNull() || polygon->NbNodes() < 2) {
                        continue;
                    }
                    const gp_Trsf trsf = location.Transformation();
                    const TColStd_Array1OfInteger& nodes = polygon->Nodes();
                    for (int i = nodes.Lower(); i < nodes.Upper(); ++i) {
                        edge_points.push_back(to_godot(tri->Node(nodes(i)).Transformed(trsf)));
                        edge_points.push_back(to_godot(tri->Node(nodes(i + 1)).Transformed(trsf)));
                        edge_ids.push_back(ei - 1);
                    }
                    meshed = true;
                }
            }
            if (meshed) {
                continue;
            }
            // A free edge (a wire, a face the mesher skipped): sampled from its curve.
            BRepAdaptor_Curve curve(edge);
            GCPnts_TangentialDeflection sampler(curve, angular_deflection, linear_deflection);
            for (int i = 1; i < sampler.NbPoints(); ++i) {
                edge_points.push_back(to_godot(sampler.Value(i)));
                edge_points.push_back(to_godot(sampler.Value(i + 1)));
                edge_ids.push_back(ei - 1);
            }
        }

        const TopTools_IndexedMapOfShape& verts = vertex_map();
        for (int vi = 1; vi <= verts.Extent(); ++vi) {
            vertices.push_back(to_godot(BRep_Tool::Pnt(TopoDS::Vertex(verts(vi)))));
        }
    }
    catch (const Standard_Failure& failure) {
        UtilityFunctions::push_error("CadShape.tessellate failed: ", failure.GetMessageString());
        return Dictionary();
    }

    out["positions"] = positions;
    out["normals"] = normals;
    out["uvs"] = uvs;
    out["indices"] = indices;
    out["face_ids"] = face_ids;
    out["edge_points"] = edge_points;
    out["edge_ids"] = edge_ids;
    out["vertices"] = vertices;
    return out;
}

Dictionary CadShape::face_info(int face_id) const
{
    Dictionary info;
    if (shape.IsNull()) {
        return info;
    }
    const TopTools_IndexedMapOfShape& faces = face_map();
    if (face_id < 0 || face_id >= faces.Extent()) {
        return info;
    }
    try {
        const TopoDS_Face& face = TopoDS::Face(faces(face_id + 1));
        BRepAdaptor_Surface surface(face);
        String type = "other";
        switch (surface.GetType()) {
            case GeomAbs_Plane:
                type = "plane";
                break;
            case GeomAbs_Cylinder:
                type = "cylinder";
                break;
            case GeomAbs_Cone:
                type = "cone";
                break;
            case GeomAbs_Sphere:
                type = "sphere";
                break;
            case GeomAbs_Torus:
                type = "torus";
                break;
            default:
                break;
        }
        info["type"] = type;
        info["planar"] = type == "plane";
        auto axis_info = [&](const gp_Ax1& axis) {
            info["axis_origin"] = to_godot(axis.Location());
            const gp_Dir d = axis.Direction();
            info["axis"] = Vector3(real_t(d.X()), real_t(d.Y()), real_t(d.Z()));
        };
        if (type == "cylinder") {
            axis_info(surface.Cylinder().Axis());
            info["radius"] = surface.Cylinder().Radius();
        }
        else if (type == "cone") {
            axis_info(surface.Cone().Axis());
            info["radius"] = surface.Cone().RefRadius();
            info["half_angle"] = surface.Cone().SemiAngle();
        }
        else if (type == "sphere") {
            info["center"] = to_godot(surface.Sphere().Location());
            info["radius"] = surface.Sphere().Radius();
        }
        else if (type == "torus") {
            axis_info(surface.Torus().Axis());
            info["center"] = to_godot(surface.Torus().Location());
            info["radius"] = surface.Torus().MajorRadius();
            info["minor_radius"] = surface.Torus().MinorRadius();
        }
        if (face_area_cache.size() != size_t(face_map().Extent())) {
            face_area_cache.assign(size_t(face_map().Extent()), {-1.0, Vector3()});
        }
        std::pair<double, Vector3>& measured = face_area_cache[size_t(face_id)];
        if (measured.first < 0.0) {
            const GProp_GProps props = measure::surface(face);
            measured = {props.Mass(), to_godot(props.CentreOfMass())};
        }
        info["point"] = measured.second;
        info["area"] = measured.first;
        if (type == "plane") {
            gp_Dir normal = surface.Plane().Axis().Direction();
            if (face.Orientation() == TopAbs_REVERSED) {
                normal.Reverse();
            }
            info["normal"] = Vector3(real_t(normal.X()), real_t(normal.Y()), real_t(normal.Z()));
        }
        const TopTools_IndexedMapOfShape& all_edges = edge_map();
        PackedInt32Array edge_ids;
        for (TopExp_Explorer it(face, TopAbs_EDGE); it.More(); it.Next()) {
            const int id = all_edges.FindIndex(it.Current()) - 1;
            if (id >= 0 && !edge_ids.has(id)) {
                edge_ids.push_back(id);
            }
        }
        info["edges"] = edge_ids;
    }
    catch (const Standard_Failure& failure) {
        UtilityFunctions::push_error("CadShape.face_info failed: ", failure.GetMessageString());
        info.clear();
    }
    return info;
}

Dictionary CadShape::edge_info(int edge_id) const
{
    Dictionary info;
    const TopTools_IndexedMapOfShape& edges = edge_map();
    if (shape.IsNull() || edge_id < 0 || edge_id >= edges.Extent()) {
        return info;
    }
    try {
        const TopoDS_Edge& edge = TopoDS::Edge(edges(edge_id + 1));
        if (BRep_Tool::Degenerated(edge)) {
            info["type"] = "degenerate";
            return info;
        }
        BRepAdaptor_Curve curve(edge);
        const double f = curve.FirstParameter();
        const double l = curve.LastParameter();
        gp_Pnt middle;
        gp_Vec tangent;
        curve.D1(0.5 * (f + l), middle, tangent);
        String type = "other";
        switch (curve.GetType()) {
            case GeomAbs_Line:
                type = "line";
                break;
            case GeomAbs_Circle: {
                type = "circle";
                const gp_Circ circle = curve.Circle();
                info["center"] = to_godot(circle.Location());
                info["radius"] = circle.Radius();
                const gp_Dir axis = circle.Axis().Direction();
                info["axis"] = Vector3(real_t(axis.X()), real_t(axis.Y()), real_t(axis.Z()));
                break;
            }
            case GeomAbs_Ellipse:
                type = "ellipse";
                info["center"] = to_godot(curve.Ellipse().Location());
                break;
            case GeomAbs_BSplineCurve:
            case GeomAbs_BezierCurve:
                type = "bspline";
                break;
            default:
                break;
        }
        gp_Pnt start = curve.Value(f);
        gp_Pnt end = curve.Value(l);
        if (edge.Orientation() == TopAbs_REVERSED) {
            std::swap(start, end);
            tangent.Reverse();
        }
        info["type"] = type;
        info["start"] = to_godot(start);
        info["end"] = to_godot(end);
        info["midpoint"] = to_godot(middle);
        info["tangent"] = tangent.Magnitude() > 1e-12 ? to_godot(gp_Vec(tangent.Normalized())) : Vector3();
        info["length"] = measure::length(edge);
        info["closed"] = BRep_Tool::IsClosed(edge) || start.Distance(end) < 1e-9;
        // Faces on either side, and whether the edge is convex (an outside corner).
        const TopTools_IndexedDataMapOfShapeListOfShape& edge_faces = edge_face_map();
        const TopTools_IndexedMapOfShape& all_faces = face_map();
        PackedInt32Array face_ids;
        std::vector<TopoDS_Face> adjacent;
        const int key = edge_faces.FindIndex(edge);
        if (key > 0) {
            for (TopTools_ListOfShape::Iterator it(edge_faces(key)); it.More(); it.Next()) {
                const int id = all_faces.FindIndex(it.Value()) - 1;
                if (id >= 0 && !face_ids.has(id)) {
                    face_ids.push_back(id);
                    adjacent.push_back(TopoDS::Face(it.Value()));
                }
            }
        }
        info["faces"] = face_ids;
        if (adjacent.size() == 2) {
            // Convex when each face's normal points away from the other face's side.
            const Vector3 n0 = face_normal_at(face_ids[0], to_godot(middle));
            const Vector3 n1 = face_normal_at(face_ids[1], to_godot(middle));
            GProp_GProps p1;
            BRepGProp::SurfaceProperties(adjacent[1], p1);
            const Vector3 toward = (to_godot(p1.CentreOfMass()) - to_godot(middle)).normalized();
            info["convex"] = n0.dot(toward) < 1e-6 && n0.dot(n1) < 0.999999;
            info["dihedral"] = std::acos(std::clamp(double(n0.dot(n1)), -1.0, 1.0));
        }
    }
    catch (const Standard_Failure& failure) {
        UtilityFunctions::push_error("CadShape.edge_info failed: ", failure.GetMessageString());
        info.clear();
    }
    return info;
}

Vector3 CadShape::face_normal_at(int face_id, const Vector3& point) const
{
    const TopTools_IndexedMapOfShape& faces = face_map();
    if (shape.IsNull() || face_id < 0 || face_id >= faces.Extent()) {
        return Vector3();
    }
    try {
        TopoDS_Face face = TopoDS::Face(faces(face_id + 1));
        gp_Pnt target(point.x, point.y, point.z);
        // A spline (or other free-form) face is worked on as a copy a centimetre across: the
        // projection and distances below have OCCT's absolute tolerances, which missed points inside
        // a 0.5 mm cap and on a 500 mm plate's rim (their normals came out up to 90 deg off).
        // Scaling keeps directions.
        switch (BRepAdaptor_Surface(face, false).GetType()) {
            case GeomAbs_Plane:
            case GeomAbs_Cylinder:
            case GeomAbs_Cone:
            case GeomAbs_Sphere:
            case GeomAbs_Torus:
                break;
            default: {
                Bnd_Box box;
                BRepBndLib::Add(face, box);
                const double size = box.IsVoid() ? 0.0 : std::sqrt(box.SquareExtent());
                const double factor = size > 0.0 ? 0.01 / size : 1.0;
                if (factor < 0.5 || factor > 2.0) {
                    gp_Trsf normalize;
                    normalize.SetScale(gp_Pnt((box.CornerMin().XYZ() + box.CornerMax().XYZ()) * 0.5), factor);
                    face = TopoDS::Face(measure::scaled_copy(face, normalize));
                    target.Transform(normalize);
                }
                break;
            }
        }
        Handle(Geom_Surface) surface = BRep_Tool::Surface(face);
        double u = 0.0, v = 0.0;
        // (A tight parameter tolerance: OCCT compares it with squared distances, and its default
        // skips the inside of a spline face a few centimetres across.)
        GeomAPI_ProjectPointOnSurf projection(target, surface, 1e-11);
        bool found = projection.NbPoints() > 0 && projection.LowerDistance() <= Precision::Confusion();
        if (found) {
            projection.LowerDistanceParameters(u, v);
        }
        // A point the projection doesn't find on the surface, on one of the face's edges, is placed by
        // the edge's curve on the face (the exact distance below can settle on a vertex there, a lens
        // patch's collapsed end beside its side, whose place on the face is any of a whole side).
        double nearest_edge = 1e300;
        for (TopExp_Explorer it(face, TopAbs_EDGE); !found && it.More(); it.Next()) {
            const TopoDS_Edge& edge = TopoDS::Edge(it.Current());
            double f = 0.0, l = 0.0, pf = 0.0, pl = 0.0;
            const Handle(Geom_Curve) curve = BRep_Tool::Degenerated(edge) ? Handle(Geom_Curve)() : BRep_Tool::Curve(edge, f, l);
            const Handle(Geom2d_Curve) pcurve = curve.IsNull() ? Handle(Geom2d_Curve)() : BRep_Tool::CurveOnSurface(edge, face, pf, pl);
            if (pcurve.IsNull()) {
                continue;
            }
            gp_Pnt at;
            double t = f;
            const double d = ShapeAnalysis_Curve().Project(curve, target, Precision::Confusion(), at, t, f, l, false);
            if (d < nearest_edge && d <= std::max(10.0 * BRep_Tool::Tolerance(edge), Precision::Confusion())) {
                nearest_edge = d;
                pcurve->Value(t).Coord(u, v);
            }
        }
        found = found || nearest_edge < 1e300;
        // On a spline face's boundary the projection can miss the point (it only finds extrema
        // inside the surface's bounds): the exact distance to the face finds it there.
        if (!found) {
            BRepExtrema_DistShapeShape nearest(BRepBuilderAPI_MakeVertex(target).Vertex(), face);
            if (nearest.IsDone() && nearest.NbSolution() > 0 && (projection.NbPoints() == 0 || nearest.Value() < projection.LowerDistance())) {
                const TopoDS_Shape support = nearest.SupportOnShape2(1);
                if (nearest.SupportTypeShape2(1) == BRepExtrema_IsInFace) {
                    nearest.ParOnFaceS2(1, u, v);
                    found = true;
                }
                else if (nearest.SupportTypeShape2(1) == BRepExtrema_IsOnEdge) {
                    double t = 0.0, f = 0.0, l = 0.0;
                    nearest.ParOnEdgeS2(1, t);
                    const Handle(Geom2d_Curve) pcurve = BRep_Tool::CurveOnSurface(TopoDS::Edge(support), face, f, l);
                    if (!pcurve.IsNull()) {
                        pcurve->Value(t).Coord(u, v);
                        found = true;
                    }
                }
                else {
                    BRep_Tool::Parameters(TopoDS::Vertex(support), face).Coord(u, v);
                    found = true;
                }
            }
            if (!found && projection.NbPoints() > 0) {
                projection.LowerDistanceParameters(u, v);
                found = true;
            }
        }
        if (!found) {
            return Vector3();
        }
        BRepGProp_Face props(face);
        gp_Pnt p;
        gp_Vec normal;
        props.Normal(u, v, p, normal);
        gp_Vec du;
        gp_Vec dv;
        BRepAdaptor_Surface(face).D1(u, v, p, du, dv);
        if (normal.Magnitude() <= 1e-6 * std::max(du.SquareMagnitude(), dv.SquareMagnitude())) {
            // A collapsed side (a pole) has its normal as the limit from inside the face.
            double u1 = 0.0, u2 = 0.0, v1 = 0.0, v2 = 0.0;
            BRepTools::UVBounds(face, u1, u2, v1, v2);
            props.Normal(u + (0.5 * (u1 + u2) - u) * 1e-7, v + (0.5 * (v1 + v2) - v) * 1e-7, p, normal);
        }
        if (normal.Magnitude() < 1e-30) {
            return Vector3();
        }
        normal.Normalize();
        return Vector3(real_t(normal.X()), real_t(normal.Y()), real_t(normal.Z()));
    }
    catch (const Standard_Failure&) {
        return Vector3();
    }
}

Dictionary CadShape::edge_point_at_length(int edge_id, double fraction) const
{
    Dictionary result;
    const TopTools_IndexedMapOfShape& edges = edge_map();
    if (shape.IsNull() || edge_id < 0 || edge_id >= edges.Extent()) {
        return result;
    }
    try {
        const TopoDS_Edge& edge = TopoDS::Edge(edges(edge_id + 1));
        const bool reversed = edge.Orientation() == TopAbs_REVERSED;
        const double share = std::clamp(reversed ? 1.0 - fraction : fraction, 0.0, 1.0);
        const double u = measure::parameter_at_length(edge, share * measure::length(edge));
        gp_Pnt p;
        gp_Vec d;
        BRepAdaptor_Curve(edge).D1(u, p, d);
        if (reversed) {
            d.Reverse();
        }
        result["point"] = to_godot(p);
        result["tangent"] = d.Magnitude() > 1e-12 ? to_godot(gp_Vec(d.Normalized())) : Vector3();
    }
    catch (const Standard_Failure& failure) {
        UtilityFunctions::push_error("CadShape.edge_point_at_length failed: ", failure.GetMessageString());
        result.clear();
    }
    return result;
}

Dictionary CadShape::edge_point_at(int edge_id, double t) const
{
    Dictionary result;
    const TopTools_IndexedMapOfShape& edges = edge_map();
    if (shape.IsNull() || edge_id < 0 || edge_id >= edges.Extent()) {
        return result;
    }
    const TopoDS_Edge& edge = TopoDS::Edge(edges(edge_id + 1));
    BRepAdaptor_Curve curve(edge);
    double f = curve.FirstParameter();
    double l = curve.LastParameter();
    if (edge.Orientation() == TopAbs_REVERSED) {
        std::swap(f, l);
    }
    gp_Pnt p;
    gp_Vec d;
    curve.D1(f + (l - f) * t, p, d);
    if (edge.Orientation() == TopAbs_REVERSED) {
        d.Reverse();
    }
    result["point"] = to_godot(p);
    result["tangent"] = d.Magnitude() > 1e-12 ? to_godot(gp_Vec(d.Normalized())) : Vector3();
    return result;
}

Dictionary CadShape::mass_properties(double density) const
{
    Dictionary result;
    if (shape.IsNull()) {
        return result;
    }
    const GProp_GProps& volume = volume_props();
    const GProp_GProps& surface = surface_props();
    const gp_Mat inertia = volume.MatrixOfInertia();
    PackedFloat64Array values;
    for (int r = 1; r <= 3; ++r) {
        for (int c = 1; c <= 3; ++c) {
            values.push_back(inertia(r, c) * density);
        }
    }
    double i1 = 0.0, i2 = 0.0, i3 = 0.0;
    volume.PrincipalProperties().Moments(i1, i2, i3);
    result["volume"] = volume.Mass();
    result["area"] = surface.Mass();
    result["mass"] = volume.Mass() * density;
    result["center"] = to_godot(volume.CentreOfMass());
    result["inertia"] = values;
    result["principal_moments"] = Vector3(real_t(i1 * density), real_t(i2 * density), real_t(i3 * density));
    return result;
}

Dictionary CadShape::surface_curvatures(int face_id, const PackedVector2Array& uvs) const
{
    Dictionary result;
    const TopTools_IndexedMapOfShape& faces = face_map();
    if (shape.IsNull() || face_id < 0 || face_id >= faces.Extent()) {
        return result;
    }
    PackedFloat64Array k1, k2, gaussian, mean;
    PackedVector3Array dir1, normals;
    try {
        const TopoDS_Face& face = TopoDS::Face(faces(face_id + 1));
        // OCCT's curvature signs follow the surface normal; outward faces flip it when reversed.
        const double side = face.Orientation() == TopAbs_REVERSED ? 1.0 : -1.0;
        BRepAdaptor_Surface surface(face);
        BRepLProp_SLProps props(surface, 2, 1e-9);
        double u1 = 0.0, u2 = 0.0, v1 = 0.0, v2 = 0.0;
        BRepTools::UVBounds(face, u1, u2, v1, v2);
        for (int64_t i = 0; i < uvs.size(); ++i) {
            // On a collapsed side (a pole) one derivative vanishes and OCCT's normal there is a
            // guess: the values are the limits from inside the face.
            gp_Pnt at;
            gp_Vec du;
            gp_Vec dv;
            surface.D1(uvs[i].x, uvs[i].y, at, du, dv);
            const bool collapsed = du.Crossed(dv).Magnitude() <= 1e-6 * std::max(du.SquareMagnitude(), dv.SquareMagnitude());
            props.SetParameters(collapsed ? uvs[i].x + (0.5 * (u1 + u2) - uvs[i].x) * 1e-4 : uvs[i].x, collapsed ? uvs[i].y + (0.5 * (v1 + v2) - uvs[i].y) * 1e-4 : uvs[i].y);
            double a = 0.0, b = 0.0;
            gp_Dir d1(1, 0, 0), d2(0, 1, 0), n(0, 0, 1);
            if (props.IsCurvatureDefined()) {
                a = props.MaxCurvature() * side;
                b = props.MinCurvature() * side;
                if (!props.IsUmbilic()) {
                    props.CurvatureDirections(d1, d2);
                }
                if (a < b) {
                    std::swap(a, b);
                    std::swap(d1, d2);
                }
            }
            if (props.IsNormalDefined()) {
                n = props.Normal();
                if (face.Orientation() == TopAbs_REVERSED) {
                    n.Reverse();
                }
            }
            k1.push_back(a);
            k2.push_back(b);
            gaussian.push_back(a * b);
            mean.push_back(0.5 * (a + b));
            dir1.push_back(Vector3(real_t(d1.X()), real_t(d1.Y()), real_t(d1.Z())));
            normals.push_back(Vector3(real_t(n.X()), real_t(n.Y()), real_t(n.Z())));
        }
    }
    catch (const Standard_Failure& failure) {
        UtilityFunctions::push_error("CadShape.surface_curvatures failed: ", failure.GetMessageString());
    }
    result["k1"] = k1;
    result["k2"] = k2;
    result["gaussian"] = gaussian;
    result["mean"] = mean;
    result["dir1"] = dir1;
    result["normals"] = normals;
    return result;
}

Vector2 CadShape::face_uv_metric(int face_id) const
{
    const TopTools_IndexedMapOfShape& faces = face_map();
    if (shape.IsNull() || face_id < 0 || face_id >= faces.Extent()) {
        return Vector2(1, 1);
    }
    try {
        BRepAdaptor_Surface surface(TopoDS::Face(faces(face_id + 1)));
        const double u = 0.5 * (surface.FirstUParameter() + surface.LastUParameter());
        const double v = 0.5 * (surface.FirstVParameter() + surface.LastVParameter());
        gp_Pnt p;
        gp_Vec du, dv;
        surface.D1(u, v, p, du, dv);
        return Vector2(real_t(du.Magnitude()), real_t(dv.Magnitude()));
    }
    catch (const Standard_Failure&) {
        return Vector2(1, 1);
    }
}

Dictionary CadShape::edge_curvature(int edge_id, int count) const
{
    Dictionary result;
    const TopTools_IndexedMapOfShape& edges = edge_map();
    if (shape.IsNull() || edge_id < 0 || edge_id >= edges.Extent() || count < 2) {
        return result;
    }
    PackedVector3Array points, normals;
    PackedFloat64Array curvature;
    try {
        BRepAdaptor_Curve curve(TopoDS::Edge(edges(edge_id + 1)));
        const double f = curve.FirstParameter();
        const double l = curve.LastParameter();
        for (int i = 0; i < count; ++i) {
            gp_Pnt p;
            gp_Vec d1, d2;
            curve.D2(f + (l - f) * i / (count - 1), p, d1, d2);
            const double speed = d1.Magnitude();
            double k = 0.0;
            gp_Vec toward(0, 0, 0);
            if (speed > 1e-12) {
                k = d1.Crossed(d2).Magnitude() / (speed * speed * speed);
                const gp_Vec t = d1 / speed;
                toward = d2 - t * d2.Dot(t);
                if (toward.Magnitude() > 1e-12) {
                    toward.Normalize();
                }
            }
            points.push_back(to_godot(p));
            curvature.push_back(k);
            normals.push_back(to_godot(toward));
        }
    }
    catch (const Standard_Failure& failure) {
        UtilityFunctions::push_error("CadShape.edge_curvature failed: ", failure.GetMessageString());
    }
    result["points"] = points;
    result["curvature"] = curvature;
    result["normals"] = normals;
    return result;
}

Array CadShape::face_isocurves(int face_id, int u_count, int v_count, int samples) const
{
    Array result;
    const TopTools_IndexedMapOfShape& faces = face_map();
    if (shape.IsNull() || face_id < 0 || face_id >= faces.Extent()) {
        return result;
    }
    samples = std::max(samples, 2);
    try {
        const TopoDS_Face& face = TopoDS::Face(faces(face_id + 1));
        // The adaptor applies the face's location: points and derivatives come out in place.
        BRepAdaptor_Surface surface(face);
        double u0 = 0.0, u1 = 0.0, v0 = 0.0, v1 = 0.0;
        BRepTools::UVBounds(face, u0, u1, v0, v1);
        if (!(u1 > u0) || !(v1 > v0)) {
            return result;
        }
        // One explorer for every query (the classifier only re-walks its wires).
        BRepClass_FaceExplorer explorer(face);
        explorer.SetMaxTolerance(0.1);
        BRepClass_FClassifier classifier;
        const double tolerance = Precision::PConfusion();
        // A flat face's lines are cut exactly where they cross its boundary (OCCT's hatcher)
        // instead of by classifying every sample and bisecting each end: a mesh body has
        // thousands of flat faces, and that took tens of seconds.
        const bool flat = surface.GetType() == GeomAbs_Plane;
        for (int direction = 0; direction < 2; ++direction) {
            // direction 0: lines of constant u, running along v.
            const int count = direction == 0 ? u_count : v_count;
            const double fixed0 = direction == 0 ? u0 : v0;
            const double fixed1 = direction == 0 ? u1 : v1;
            const double run0 = direction == 0 ? v0 : u0;
            const double run1 = direction == 0 ? v1 : u1;
            const double span = run1 - run0;
            std::vector<double> fixed_values;
            for (int line = 0; line < count; ++line) {
                fixed_values.push_back(fixed0 + (fixed1 - fixed0) * double(line + 1) / double(count + 1));
            }
            std::vector<std::vector<std::pair<double, double>>> hatched;
            const bool exact = flat && count > 0 && hatch_isolines(face, direction, fixed_values, run0, run1, hatched);
            for (int line = 0; line < count; ++line) {
                const double fixed = fixed_values[size_t(line)];
                auto uv = [&](double t) {
                    return direction == 0 ? gp_Pnt2d(fixed, t) : gp_Pnt2d(t, fixed);
                };
                auto inside = [&](double t) {
                    classifier.Perform(explorer, uv(t), tolerance);
                    const TopAbs_State state = classifier.State();
                    return state == TopAbs_IN || state == TopAbs_ON;
                };
                // The boundary between an inside and an outside parameter, from the inside.
                auto boundary = [&](double in_t, double out_t) {
                    for (int k = 0; k < 64 && std::abs(out_t - in_t) > 1e-14 * span; ++k) {
                        const double middle = 0.5 * (in_t + out_t);
                        if (inside(middle)) {
                            in_t = middle;
                        }
                        else {
                            out_t = middle;
                        }
                    }
                    return in_t;
                };
                std::vector<double> params(size_t(samples), 0.0);
                for (int i = 0; i < samples; ++i) {
                    params[i] = run0 + span * double(i) / double(samples - 1);
                }
                // The runs: each one's parameters, ends on the boundary and the samples between.
                std::vector<std::vector<double>> runs;
                if (exact) {
                    for (const std::pair<double, double>& domain : hatched[size_t(line)]) {
                        std::vector<double> run{domain.first};
                        for (const double t : params) {
                            if (t - run.back() > 1e-12 * span && domain.second - t > 1e-12 * span) {
                                run.push_back(t);
                            }
                        }
                        if (domain.second - run.back() > 1e-12 * span) {
                            run.push_back(domain.second);
                        }
                        runs.push_back(run);
                    }
                }
                else {
                    std::vector<char> in(size_t(samples), 0);
                    for (int i = 0; i < samples; ++i) {
                        in[i] = inside(params[i]) ? 1 : 0;
                    }
                    int i = 0;
                    while (i < samples) {
                        if (!in[i]) {
                            ++i;
                            continue;
                        }
                        std::vector<double> run;
                        if (i > 0) {
                            run.push_back(boundary(params[i], params[i - 1]));
                        }
                        int j = i;
                        for (; j < samples && in[j]; ++j) {
                            if (run.empty() || params[j] - run.back() > 1e-12 * span) {
                                run.push_back(params[j]);
                            }
                        }
                        if (j < samples) {
                            const double end = boundary(params[j - 1], params[j]);
                            if (end - run.back() > 1e-12 * span) {
                                run.push_back(end);
                            }
                        }
                        i = j;
                        runs.push_back(run);
                    }
                }
                for (const std::vector<double>& run : runs) {
                    if (run.size() < 2) {
                        continue;
                    }
                    PackedVector3Array points, normals;
                    PackedFloat64Array curvature;
                    for (const double t : run) {
                        const gp_Pnt2d at = uv(t);
                        gp_Pnt p;
                        gp_Vec du, dv, duu, dvv, duv;
                        surface.D2(at.X(), at.Y(), p, du, dv, duu, dvv, duv);
                        // The iso curve's own derivatives: along v for constant u, along u otherwise.
                        const gp_Vec d1 = direction == 0 ? dv : du;
                        const gp_Vec d2 = direction == 0 ? dvv : duu;
                        const double speed = d1.Magnitude();
                        double k = 0.0;
                        gp_Vec toward(0, 0, 0);
                        if (speed > 1e-12) {
                            k = d1.Crossed(d2).Magnitude() / (speed * speed * speed);
                            const gp_Vec tangent = d1 / speed;
                            toward = d2 - tangent * d2.Dot(tangent);
                            // Straight (a radius over 10^12 m): no curvature, no direction.
                            if (k > 1e-12 && toward.Magnitude() > 1e-300) {
                                toward.Normalize();
                            }
                            else {
                                k = 0.0;
                                toward = gp_Vec(0, 0, 0);
                            }
                        }
                        points.push_back(to_godot(p));
                        curvature.push_back(k);
                        normals.push_back(to_godot(toward));
                    }
                    Dictionary entry;
                    entry["points"] = points;
                    entry["curvature"] = curvature;
                    entry["normals"] = normals;
                    entry["direction"] = direction == 0 ? "u" : "v";
                    result.push_back(entry);
                }
            }
        }
    }
    catch (const Standard_Failure& failure) {
        UtilityFunctions::push_error("CadShape.face_isocurves failed: ", failure.GetMessageString());
        result.clear();
    }
    return result;
}

Vector3 CadShape::vertex_position(int vertex_id) const
{
    const TopTools_IndexedMapOfShape& vertices = vertex_map();
    if (shape.IsNull() || vertex_id < 0 || vertex_id >= vertices.Extent()) {
        return Vector3();
    }
    return to_godot(BRep_Tool::Pnt(TopoDS::Vertex(vertices(vertex_id + 1))));
}

PackedStringArray CadShape::get_face_names() const
{
    PackedStringArray names;
    for (const std::string& n : face_name_list) {
        names.push_back(String::utf8(n.c_str()));
    }
    return names;
}

PackedStringArray CadShape::get_edge_names() const
{
    PackedStringArray names;
    for (const std::string& n : edge_name_list) {
        names.push_back(String::utf8(n.c_str()));
    }
    return names;
}

void CadShape::set_face_names(const PackedStringArray& names)
{
    face_name_list.clear();
    for (int64_t i = 0; i < names.size(); ++i) {
        face_name_list.push_back(names[i].utf8().get_data());
    }
}

void CadShape::set_edge_names(const PackedStringArray& names)
{
    edge_name_list.clear();
    for (int64_t i = 0; i < names.size(); ++i) {
        edge_name_list.push_back(names[i].utf8().get_data());
    }
}

int CadShape::find_face(const String& name) const
{
    const std::string wanted = name.utf8().get_data();
    for (size_t i = 0; i < face_name_list.size(); ++i) {
        if (face_name_list[i] == wanted) {
            return int(i);
        }
    }
    return -1;
}

int CadShape::find_edge(const String& name) const
{
    const std::string wanted = name.utf8().get_data();
    for (size_t i = 0; i < edge_name_list.size(); ++i) {
        if (edge_name_list[i] == wanted) {
            return int(i);
        }
    }
    return -1;
}

void CadShape::name_edges_from_faces()
{
    naming::name_edges(*this);
}

Array CadShape::solids() const
{
    Array result;
    if (shape.IsNull()) {
        return result;
    }
    for (TopExp_Explorer it(shape, TopAbs_SOLID); it.More(); it.Next()) {
        Ref<CadShape> part = wrap(it.Current());
        naming::copy_names(*this, *part.ptr());
        result.push_back(part);
    }
    return result;
}

Ref<CadShape> CadShape::face_shape(int face_id) const
{
    const TopTools_IndexedMapOfShape& faces = face_map();
    if (shape.IsNull() || face_id < 0 || face_id >= faces.Extent()) {
        return Ref<CadShape>();
    }
    Ref<CadShape> part = wrap(faces(face_id + 1));
    naming::copy_names(*this, *part.ptr());
    return part;
}

Ref<CadShape> CadShape::edge_shape(int edge_id) const
{
    const TopTools_IndexedMapOfShape& edges = edge_map();
    if (shape.IsNull() || edge_id < 0 || edge_id >= edges.Extent()) {
        return Ref<CadShape>();
    }
    Ref<CadShape> part = wrap(edges(edge_id + 1));
    naming::copy_names(*this, *part.ptr());
    return part;
}

int CadShape::solid_count() const
{
    return count_sub_shapes(shape, TopAbs_SOLID);
}

bool CadShape::is_surface() const
{
    return !shape.IsNull() && count_sub_shapes(shape, TopAbs_SOLID) == 0 && count_sub_shapes(shape, TopAbs_FACE) > 0;
}

Ref<CadShape> CadShape::copy() const
{
    Ref<CadShape> other = wrap(shape);
    other->face_name_list = face_name_list;
    other->edge_name_list = edge_name_list;
    return other;
}

bool CadShape::test_damage_mesh(int face_id, double keep, double coarse_deflection, bool block_remesh)
{
    const TopTools_IndexedMapOfShape& faces = face_map();
    if (face_id < 0 || face_id >= faces.Extent()) {
        return false;
    }
    try {
        if (coarse_deflection > 0.0) {
            BRepTools::Clean(shape);
            BRepMesh_IncrementalMesh coarse(shape, coarse_deflection, Standard_False, 2.0, Standard_False);
        }
        const TopoDS_Face& face = TopoDS::Face(faces(face_id + 1));
        TopLoc_Location location;
        const Handle(Poly_Triangulation) mesh = BRep_Tool::Triangulation(face, location);
        if (mesh.IsNull()) {
            return false;
        }
        if (keep < 0.0) {
            BRep_Builder().UpdateFace(face, Handle(Poly_Triangulation)());
        }
        else {
            auto area_of = [&](int k) {
                int a = 0, b = 0, c = 0;
                mesh->Triangle(k).Get(a, b, c);
                return 0.5 * gp_Vec(mesh->Node(a), mesh->Node(b)).Crossed(gp_Vec(mesh->Node(a), mesh->Node(c))).Magnitude();
            };
            double total = 0.0;
            for (int k = 1; k <= mesh->NbTriangles(); ++k) {
                total += area_of(k);
            }
            double kept = 0.0;
            for (int k = 1; k <= mesh->NbTriangles(); ++k) {
                const double area = area_of(k);
                if (kept + area <= keep * total) {
                    kept += area;
                    continue;
                }
                int a = 0, b = 0, c = 0;
                mesh->Triangle(k).Get(a, b, c);
                mesh->SetTriangle(k, Poly_Triangle(a, a, a));
            }
        }
        test_mesh_frozen = true;
        test_remesh_blocked = block_remesh;
        return true;
    }
    catch (const Standard_Failure&) {
        return false;
    }
}

PackedByteArray CadShape::to_brep_bytes() const
{
    PackedByteArray bytes;
    if (shape.IsNull()) {
        return bytes;
    }
    try {
        std::ostringstream stream(std::ios::out | std::ios::binary);
        // Triangulation is not stored: meshes are rebuilt at the deflection the caller asks for.
        BinTools::Write(shape, stream, false, false, BinTools_FormatVersion_CURRENT);
        const std::string data = stream.str();
        bytes.resize(int64_t(data.size()));
        std::memcpy(bytes.ptrw(), data.data(), data.size());
    }
    catch (const Standard_Failure& failure) {
        UtilityFunctions::push_error("CadShape.to_brep_bytes failed: ", failure.GetMessageString());
        bytes.clear();
    }
    return bytes;
}

bool CadShape::load_brep_bytes(const PackedByteArray& bytes)
{
    reset_maps();
    if (bytes.is_empty()) {
        shape.Nullify();
        return false;
    }
    try {
        std::istringstream stream(
            std::string(reinterpret_cast<const char*>(bytes.ptr()), size_t(bytes.size())),
            std::ios::in | std::ios::binary
        );
        TopoDS_Shape loaded;
        BinTools::Read(loaded, stream);
        shape = loaded;
        reset_maps();
        return !shape.IsNull();
    }
    catch (const Standard_Failure& failure) {
        UtilityFunctions::push_error("CadShape.load_brep_bytes failed: ", failure.GetMessageString());
        shape.Nullify();
        reset_maps();
        return false;
    }
}

void CadShape::_bind_methods()
{
    ClassDB::bind_method(D_METHOD("is_null"), &CadShape::is_null);
    ClassDB::bind_method(D_METHOD("shape_type"), &CadShape::shape_type);
    ClassDB::bind_method(D_METHOD("volume"), &CadShape::volume);
    ClassDB::bind_method(D_METHOD("area"), &CadShape::area);
    ClassDB::bind_method(D_METHOD("center_of_mass"), &CadShape::center_of_mass);
    ClassDB::bind_method(D_METHOD("area_center"), &CadShape::area_center);
    ClassDB::bind_method(D_METHOD("bbox"), &CadShape::bbox);
    ClassDB::bind_method(D_METHOD("face_count"), &CadShape::face_count);
    ClassDB::bind_method(D_METHOD("edge_count"), &CadShape::edge_count);
    ClassDB::bind_method(D_METHOD("vertex_count"), &CadShape::vertex_count);
    ClassDB::bind_method(
        D_METHOD("tessellate", "linear_deflection", "angular_deflection"),
        &CadShape::tessellate,
        DEFVAL(0.1),
        DEFVAL(0.5)
    );
    ClassDB::bind_method(D_METHOD("face_info", "face_id"), &CadShape::face_info);
    ClassDB::bind_method(D_METHOD("edge_info", "edge_id"), &CadShape::edge_info);
    ClassDB::bind_method(D_METHOD("face_normal_at", "face_id", "point"), &CadShape::face_normal_at);
    ClassDB::bind_method(D_METHOD("edge_point_at", "edge_id", "t"), &CadShape::edge_point_at);
    ClassDB::bind_method(D_METHOD("edge_point_at_length", "edge_id", "fraction"), &CadShape::edge_point_at_length);
    ClassDB::bind_method(D_METHOD("mass_properties", "density"), &CadShape::mass_properties, DEFVAL(1000.0));
    ClassDB::bind_method(D_METHOD("surface_curvatures", "face_id", "uvs"), &CadShape::surface_curvatures);
    ClassDB::bind_method(D_METHOD("face_uv_metric", "face_id"), &CadShape::face_uv_metric);
    ClassDB::bind_method(D_METHOD("edge_curvature", "edge_id", "count"), &CadShape::edge_curvature);
    ClassDB::bind_method(
        D_METHOD("face_isocurves", "face_id", "u_count", "v_count", "samples"),
        &CadShape::face_isocurves,
        DEFVAL(64)
    );
    ClassDB::bind_method(D_METHOD("vertex_position", "vertex_id"), &CadShape::vertex_position);
    ClassDB::bind_method(D_METHOD("get_face_names"), &CadShape::get_face_names);
    ClassDB::bind_method(D_METHOD("get_edge_names"), &CadShape::get_edge_names);
    ClassDB::bind_method(D_METHOD("set_face_names", "names"), &CadShape::set_face_names);
    ClassDB::bind_method(D_METHOD("set_edge_names", "names"), &CadShape::set_edge_names);
    ClassDB::bind_method(D_METHOD("find_face", "name"), &CadShape::find_face);
    ClassDB::bind_method(D_METHOD("find_edge", "name"), &CadShape::find_edge);
    ClassDB::bind_method(D_METHOD("name_edges_from_faces"), &CadShape::name_edges_from_faces);
    ClassDB::bind_method(D_METHOD("solids"), &CadShape::solids);
    ClassDB::bind_method(D_METHOD("solid_count"), &CadShape::solid_count);
    ClassDB::bind_method(D_METHOD("is_surface"), &CadShape::is_surface);
    ClassDB::bind_method(D_METHOD("face_shape", "face_id"), &CadShape::face_shape);
    ClassDB::bind_method(D_METHOD("edge_shape", "edge_id"), &CadShape::edge_shape);
    ClassDB::bind_method(D_METHOD("copy"), &CadShape::copy);
    ClassDB::bind_method(D_METHOD("to_brep_bytes"), &CadShape::to_brep_bytes);
    ClassDB::bind_method(D_METHOD("load_brep_bytes", "bytes"), &CadShape::load_brep_bytes);
    ClassDB::bind_method(D_METHOD("test_damage_mesh", "face_id", "keep", "coarse_deflection", "block_remesh"), &CadShape::test_damage_mesh);
}

}  // namespace holo_forge
