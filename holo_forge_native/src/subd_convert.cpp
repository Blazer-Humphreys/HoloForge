#include "subd_convert.h"

#include "subd_bvh.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <limits>
#include <list>
#include <map>
#include <mutex>
#include <numeric>
#include <tuple>
#include <unordered_map>

#include <opensubdiv/far/error.h>
#include <opensubdiv/far/patchTableFactory.h>
#include <opensubdiv/far/primvarRefiner.h>
#include <opensubdiv/far/ptexIndices.h>
#include <opensubdiv/far/stencilTable.h>
#include <opensubdiv/far/topologyDescriptor.h>

#include <BRepAdaptor_Curve.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <Geom_Surface.hxx>
#include <BRepBuilderAPI_Copy.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepBuilderAPI_MakeSolid.hxx>
#include <BRepBuilderAPI_Sewing.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRepClass_FaceClassifier.hxx>
#include <BRepGProp.hxx>
#include <BRepLProp_SLProps.hxx>
#include <BRepLib.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRepTools.hxx>
#include <BRepTools_WireExplorer.hxx>
#include <BRep_Builder.hxx>
#include <BRep_Tool.hxx>
#include <Bnd_Box.hxx>
#include <BRepBndLib.hxx>
#include <Extrema_ExtPC.hxx>
#include <GCPnts_AbscissaPoint.hxx>
#include <GProp_GProps.hxx>
#include <Geom2d_Curve.hxx>
#include <gp_Vec2d.hxx>
#include <Geom2d_BSplineCurve.hxx>
#include <Geom2d_Line.hxx>
#include <GeomAPI_ProjectPointOnSurf.hxx>
#include <GeomConvert_CompBezierSurfacesToBSplineSurface.hxx>
#include <GeomLProp_SLProps.hxx>
#include <Geom_BSplineSurface.hxx>
#include <Geom_BezierSurface.hxx>
#include <Geom_Curve.hxx>
#include <Poly_Triangulation.hxx>
#include <Precision.hxx>
#include <ShapeAnalysis_Surface.hxx>
#include <ShapeFix_Shell.hxx>
#include <ShapeFix_Solid.hxx>
#include <Standard_Failure.hxx>
#include <TColGeom_Array2OfBezierSurface.hxx>
#include <TColStd_Array1OfInteger.hxx>
#include <TColStd_Array1OfReal.hxx>
#include <TColgp_Array1OfPnt2d.hxx>
#include <TColgp_Array2OfPnt.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopTools_DataMapOfShapeInteger.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Shell.hxx>
#include <TopoDS_Solid.hxx>
#include <TopoDS_Vertex.hxx>
#include <TopoDS_Wire.hxx>
#include <gp_Dir2d.hxx>
#include <gp_Pnt2d.hxx>

namespace holo_forge::subd
{

using namespace OpenSubdiv;

namespace
{
double now_ms()
{
    using namespace std::chrono;
    return duration<double, std::milli>(steady_clock::now().time_since_epoch()).count();
}

std::mutex g_osd_mutex;
std::string g_osd_errors;
std::string g_osd_warnings;

void osd_error(Far::ErrorType, const char* message)
{
    std::lock_guard<std::mutex> lock(g_osd_mutex);
    if (!g_osd_errors.empty()) {
        g_osd_errors += "; ";
    }
    g_osd_errors += message ? message : "error";
}

void osd_warning(const char* message)
{
    std::lock_guard<std::mutex> lock(g_osd_mutex);
    if (!g_osd_warnings.empty()) {
        g_osd_warnings += "; ";
    }
    g_osd_warnings += message ? message : "warning";
}

inline uint64_t edge_key(int a, int b)
{
    if (a > b) {
        std::swap(a, b);
    }
    return (uint64_t(uint32_t(a)) << 32) | uint64_t(uint32_t(b));
}

/// A refined or local point for PrimvarRefiner / stencil tables.
struct V3
{
    double x = 0.0, y = 0.0, z = 0.0;
    void Clear(void* = nullptr) { x = y = z = 0.0; }
    void AddWithWeight(const V3& s, double w)
    {
        x += w * s.x;
        y += w * s.y;
        z += w * s.z;
    }
};

}  // namespace

void install_osd_callbacks()
{
    static std::once_flag once;
    std::call_once(once, []() {
        Far::SetErrorCallback(osd_error);
        Far::SetWarningCallback(osd_warning);
    });
}

std::string take_osd_errors()
{
    std::lock_guard<std::mutex> lock(g_osd_mutex);
    std::string out;
    out.swap(g_osd_errors);
    return out;
}

std::string take_osd_warnings()
{
    std::lock_guard<std::mutex> lock(g_osd_mutex);
    std::string out;
    out.swap(g_osd_warnings);
    return out;
}

// ---------------------------------------------------------------- topology

bool build_topology(CageData& c, std::string& error)
{
    if (c.pos.size() % 3 != 0) {
        error = "Cage positions must hold 3 values per vertex";
        return false;
    }
    c.nV = int(c.pos.size() / 3);
    const int nF = int(c.counts.size());
    c.offsets.assign(size_t(nF) + 1, 0);
    for (int f = 0; f < nF; ++f) {
        if (c.counts[size_t(f)] < 3) {
            error = "Face " + std::to_string(f) + " has fewer than 3 vertices";
            return false;
        }
        c.offsets[size_t(f) + 1] = c.offsets[size_t(f)] + c.counts[size_t(f)];
    }
    if (size_t(c.offsets[size_t(nF)]) != c.indices.size()) {
        error = "Cage face_counts and face_indices disagree in size";
        return false;
    }
    for (size_t i = 0; i < c.indices.size(); ++i) {
        if (c.indices[i] < 0 || c.indices[i] >= c.nV) {
            error = "Cage vertex index " + std::to_string(c.indices[i]) + " is out of range";
            return false;
        }
    }
    for (int f = 0; f < nF; ++f) {
        const int n = c.counts[size_t(f)];
        const int* fv = &c.indices[size_t(c.offsets[size_t(f)])];
        for (int i = 0; i < n; ++i) {
            for (int j = i + 1; j < n; ++j) {
                if (fv[i] == fv[j]) {
                    error = "Face " + std::to_string(f) + " has fewer than 3 distinct vertices";
                    return false;
                }
            }
        }
    }
    // Canonical edges (C1 order) and the directions faces use them in.
    std::unordered_map<uint64_t, int> lookup;
    lookup.reserve(c.indices.size());
    c.edges.clear();
    c.corner_edge.assign(c.indices.size(), -1);
    c.edge_face_count.clear();
    c.edge_first_face.clear();
    c.edge_first_side.clear();
    std::vector<int> forward_uses, backward_uses, first_face_dir;
    for (int f = 0; f < nF; ++f) {
        const int n = c.counts[size_t(f)];
        const int o = c.offsets[size_t(f)];
        for (int k = 0; k < n; ++k) {
            const int a = c.indices[size_t(o + k)];
            const int b = c.indices[size_t(o + (k + 1) % n)];
            const uint64_t key = edge_key(a, b);
            auto it = lookup.find(key);
            int e;
            if (it == lookup.end()) {
                e = int(c.edges.size() / 2);
                lookup.emplace(key, e);
                c.edges.push_back(std::min(a, b));
                c.edges.push_back(std::max(a, b));
                c.edge_face_count.push_back(0);
                c.edge_first_face.push_back(f);
                c.edge_first_side.push_back(k);
                forward_uses.push_back(0);
                backward_uses.push_back(0);
            }
            else {
                e = it->second;
            }
            c.corner_edge[size_t(o + k)] = e;
            c.edge_face_count[size_t(e)] += 1;
            (a < b ? forward_uses : backward_uses)[size_t(e)] += 1;
            if (c.edge_face_count[size_t(e)] > 2) {
                error = "Edge (" + std::to_string(std::min(a, b)) + ", " + std::to_string(std::max(a, b)) +
                        ") has more than two faces (non-manifold)";
                return false;
            }
            if (forward_uses[size_t(e)] > 1 || backward_uses[size_t(e)] > 1) {
                error = "Faces " + std::to_string(c.edge_first_face[size_t(e)]) + " and " + std::to_string(f) +
                        " disagree on orientation at edge (" + std::to_string(std::min(a, b)) + ", " +
                        std::to_string(std::max(a, b)) + ")";
                return false;
            }
        }
    }
    // Crease pairs that are not edges and corners out of range are dropped (C1 forbids them);
    // the counts let set_cage say so.
    c.dropped_creases = 0;
    c.dropped_corners = 0;
    c.unpaired_data = (c.crease_pairs.size() != c.crease_weights.size() * 2) || (c.corners.size() != c.corner_weights.size());
    std::vector<int> pairs;
    std::vector<float> weights;
    for (size_t i = 0; i + 1 < c.crease_pairs.size() && i / 2 < c.crease_weights.size(); i += 2) {
        const int a = c.crease_pairs[i], b = c.crease_pairs[i + 1];
        if (a < 0 || b < 0 || a >= c.nV || b >= c.nV || lookup.find(edge_key(a, b)) == lookup.end()) {
            c.dropped_creases += 1;
            continue;
        }
        pairs.push_back(a);
        pairs.push_back(b);
        weights.push_back(c.crease_weights[i / 2]);
    }
    c.crease_pairs.swap(pairs);
    c.crease_weights.swap(weights);
    std::vector<int> corners;
    std::vector<float> cweights;
    for (size_t i = 0; i < c.corners.size() && i < c.corner_weights.size(); ++i) {
        if (c.corners[i] >= 0 && c.corners[i] < c.nV) {
            corners.push_back(c.corners[i]);
            cweights.push_back(c.corner_weights[i]);
        }
        else {
            c.dropped_corners += 1;
        }
    }
    c.corners.swap(corners);
    c.corner_weights.swap(cweights);

    c.ptex_base.assign(size_t(nF), 0);
    int p = 0;
    for (int f = 0; f < nF; ++f) {
        c.ptex_base[size_t(f)] = p;
        p += c.counts[size_t(f)] == 4 ? 1 : c.counts[size_t(f)];
    }
    c.nPtex = p;
    return true;
}

uint64_t topology_key(const CageData& c)
{
    uint64_t h = 1469598103934665603ull;
    auto mix = [&h](const void* data, size_t bytes) {
        const unsigned char* p = static_cast<const unsigned char*>(data);
        for (size_t i = 0; i < bytes; ++i) {
            h ^= p[i];
            h *= 1099511628211ull;
        }
        h ^= uint64_t(bytes) * 0x9e3779b97f4a7c15ull;
    };
    mix(c.counts.data(), c.counts.size() * sizeof(int));
    mix(c.indices.data(), c.indices.size() * sizeof(int));
    mix(c.crease_pairs.data(), c.crease_pairs.size() * sizeof(int));
    mix(c.crease_weights.data(), c.crease_weights.size() * sizeof(float));
    mix(c.corners.data(), c.corners.size() * sizeof(int));
    mix(c.corner_weights.data(), c.corner_weights.size() * sizeof(float));
    const uint64_t nv = uint64_t(c.nV);
    mix(&nv, sizeof(nv));
    return h;
}

std::unique_ptr<osd::TopologyRefiner> make_refiner(const CageData& c, std::string& error)
{
    install_osd_callbacks();
    Sdc::Options o;
    o.SetVtxBoundaryInterpolation(Sdc::Options::VTX_BOUNDARY_EDGE_AND_CORNER);
    o.SetFVarLinearInterpolation(Sdc::Options::FVAR_LINEAR_CORNERS_ONLY);
    o.SetCreasingMethod(Sdc::Options::CREASE_UNIFORM);
    o.SetTriangleSubdivision(Sdc::Options::TRI_SUB_SMOOTH);
    Far::TopologyDescriptor d;
    d.numVertices = c.nV;
    d.numFaces = c.face_count();
    d.numVertsPerFace = c.counts.data();
    d.vertIndicesPerFace = c.indices.data();
    d.numCreases = int(c.crease_weights.size());
    d.creaseVertexIndexPairs = c.crease_pairs.empty() ? nullptr : c.crease_pairs.data();
    d.creaseWeights = c.crease_weights.empty() ? nullptr : c.crease_weights.data();
    d.numCorners = int(c.corner_weights.size());
    d.cornerVertexIndices = c.corners.empty() ? nullptr : c.corners.data();
    d.cornerWeights = c.corner_weights.empty() ? nullptr : c.corner_weights.data();
    d.isLeftHanded = false;
    take_osd_errors();
    using Factory = Far::TopologyRefinerFactory<Far::TopologyDescriptor>;
    std::unique_ptr<osd::TopologyRefiner> r(Factory::Create(d, Factory::Options(Sdc::SCHEME_CATMARK, o)));
    const std::string err = take_osd_errors();
    if (!r || !err.empty()) {
        error = err.empty() ? std::string("OpenSubdiv could not build the cage topology") : err;
        return nullptr;
    }
    return r;
}

// ---------------------------------------------------------------- conversion

namespace
{

/// A bicubic Bezier patch: P[row v][column u].
struct Bez
{
    gp_Pnt P[4][4];
};

struct PatchRec
{
    Bez bez;
    int ptex = 0;
    double u0 = 0.0, v0 = 0.0, frac = 1.0;
    bool gregory = false;  // an end cap around an extraordinary vertex (only G1 to its neighbours)
};

/// What the graded merge did to one face, for the conversion report.
struct MergeStats
{
    double max_adjust = 0.0;  // largest pole move made to reach C1, relative to the face size
    int c0_knots = 0;         // interior knots left C0 (offsets and shells refuse such faces)
};

/// The patch's contributions to its body's volume (signed, 3x: the integral of S . (Su x Sv))
/// and area. Gauss-Legendre over the patch: 5 points a side integrate the degree-8 volume
/// integrand exactly, 8 points give the area to rounding.
void patch_measures(const Bez& b, double& volume3, double& area)
{
    static const double x5[5] = {-0.9061798459386640, -0.5384693101056831, 0.0, 0.5384693101056831, 0.9061798459386640};
    static const double w5[5] = {0.2369268850561891, 0.4786286704993665, 0.5688888888888889, 0.4786286704993665, 0.2369268850561891};
    static const double x8[8] = {-0.9602898564975363, -0.7966664774136267, -0.5255324099163290, -0.1834346424956498,
                                 0.1834346424956498, 0.5255324099163290, 0.7966664774136267, 0.9602898564975363};
    static const double w8[8] = {0.1012285362903763, 0.2223810344533745, 0.3137066458778873, 0.3626837833783620,
                                 0.3626837833783620, 0.3137066458778873, 0.2223810344533745, 0.1012285362903763};
    auto basis = [](double t, double B[4], double D[4]) {
        const double s = 1.0 - t;
        B[0] = s * s * s;
        B[1] = 3.0 * t * s * s;
        B[2] = 3.0 * t * t * s;
        B[3] = t * t * t;
        D[0] = -3.0 * s * s;
        D[1] = 3.0 * s * s - 6.0 * t * s;
        D[2] = 6.0 * t * s - 3.0 * t * t;
        D[3] = 3.0 * t * t;
    };
    auto eval = [&](double u, double v, gp_XYZ& S, gp_XYZ& Su, gp_XYZ& Sv) {
        double Bu[4], Du[4], Bv[4], Dv[4];
        basis(u, Bu, Du);
        basis(v, Bv, Dv);
        S = Su = Sv = gp_XYZ(0, 0, 0);
        for (int r = 0; r < 4; ++r) {
            for (int c = 0; c < 4; ++c) {
                const gp_XYZ& P = b.P[r][c].XYZ();
                S += P * (Bu[c] * Bv[r]);
                Su += P * (Du[c] * Bv[r]);
                Sv += P * (Bu[c] * Dv[r]);
            }
        }
    };
    volume3 = 0.0;
    area = 0.0;
    gp_XYZ S, Su, Sv;
    for (int i = 0; i < 5; ++i) {
        for (int j = 0; j < 5; ++j) {
            eval(0.5 * (x5[i] + 1.0), 0.5 * (x5[j] + 1.0), S, Su, Sv);
            volume3 += 0.25 * w5[i] * w5[j] * S.Dot(Su.Crossed(Sv));
        }
    }
    for (int i = 0; i < 8; ++i) {
        for (int j = 0; j < 8; ++j) {
            eval(0.5 * (x8[i] + 1.0), 0.5 * (x8[j] + 1.0), S, Su, Sv);
            area += 0.25 * w8[i] * w8[j] * Su.Crossed(Sv).Modulus();
        }
    }
}

const double MB2Z[4][4] = {{1 / 6.0, 4 / 6.0, 1 / 6.0, 0},
                           {0, 4 / 6.0, 2 / 6.0, 0},
                           {0, 2 / 6.0, 4 / 6.0, 0},
                           {0, 1 / 6.0, 4 / 6.0, 1 / 6.0}};

void bspline_to_bezier(const V3 B[4][4], Bez& out)
{
    V3 T[4][4];
    for (int r = 0; r < 4; ++r) {
        for (int i = 0; i < 4; ++i) {
            V3 acc;
            for (int j = 0; j < 4; ++j) {
                acc.AddWithWeight(B[r][j], MB2Z[i][j]);
            }
            T[r][i] = acc;
        }
    }
    for (int col = 0; col < 4; ++col) {
        for (int i = 0; i < 4; ++i) {
            V3 acc;
            for (int j = 0; j < 4; ++j) {
                acc.AddWithWeight(T[j][col], MB2Z[i][j]);
            }
            out.P[i][col] = gp_Pnt(acc.x, acc.y, acc.z);
        }
    }
}

Handle(Geom_BezierSurface) bezier_surface(const Bez& b)
{
    TColgp_Array2OfPnt poles(1, 4, 1, 4);
    for (int r = 0; r < 4; ++r) {
        for (int col = 0; col < 4; ++col) {
            poles(col + 1, r + 1) = b.P[r][col];
        }
    }
    return new Geom_BezierSurface(poles);
}

/// Graded merge of one ptex face's patches into one B-spline surface over [0,1]^2.
///
/// The patches are laid out as a composite Bezier net (C0 knots of multiplicity 3). Regular
/// patches meet each other C2, but a Gregory end cap meets its neighbours only G1 (and only
/// approximately, after its rational interior is replaced by a bicubic one), so those knots
/// could not be removed and the face stayed C0, which offsets, shells and fillets refuse. So
/// before knot removal the end cap's poles next to an interior knot line are put on the C1
/// continuation of the regular neighbour (two end caps facing each other share the correction).
/// The poles on the face's own boundary follow the same rule from boundary data only, so the
/// face across the edge makes the identical change and the shell stays watertight.
Handle(Geom_BSplineSurface) merge_face(const std::vector<PatchRec>& patches, const std::vector<int>& ids, MergeStats* stats = nullptr)
{
    if (ids.empty()) {
        return nullptr;
    }
    if (ids.size() == 1) {
        const PatchRec& p = patches[size_t(ids[0])];
        if (std::fabs(p.frac - 1.0) > 1e-12) {
            return nullptr;
        }
        TColgp_Array2OfPnt poles(1, 4, 1, 4);
        for (int r = 0; r < 4; ++r) {
            for (int col = 0; col < 4; ++col) {
                poles(col + 1, r + 1) = p.bez.P[r][col];
            }
        }
        TColStd_Array1OfReal k(1, 2);
        k(1) = 0.0;
        k(2) = 1.0;
        TColStd_Array1OfInteger m(1, 2);
        m(1) = 4;
        m(2) = 4;
        return new Geom_BSplineSurface(poles, k, k, m, m, 3, 3);
    }
    std::vector<double> U, Vv;
    for (int k : ids) {
        const PatchRec& p = patches[size_t(k)];
        U.push_back(p.u0);
        U.push_back(p.u0 + p.frac);
        Vv.push_back(p.v0);
        Vv.push_back(p.v0 + p.frac);
    }
    std::sort(U.begin(), U.end());
    U.erase(std::unique(U.begin(), U.end()), U.end());
    std::sort(Vv.begin(), Vv.end());
    Vv.erase(std::unique(Vv.begin(), Vv.end()), Vv.end());
    const int nu = int(U.size()) - 1, nv = int(Vv.size()) - 1;
    if (nu < 1 || nv < 1 || std::fabs(U.front()) > 1e-12 || std::fabs(Vv.front()) > 1e-12 ||
        std::fabs(U.back() - 1.0) > 1e-12 || std::fabs(Vv.back() - 1.0) > 1e-12) {
        return nullptr;
    }
    // The composite Bezier net: pole (3i + col, 3j + row) is pole (row, col) of cell (i, j).
    const int NU = 3 * nu + 1, NV = 3 * nv + 1;
    std::vector<gp_XYZ> Q(size_t(NU) * size_t(NV));
    auto at = [&](int iu, int iv) -> gp_XYZ& { return Q[size_t(iu) * size_t(NV) + size_t(iv)]; };
    std::vector<char> greg(size_t(nu) * size_t(nv), 0);
    std::vector<int> cell_patch(size_t(nu) * size_t(nv), -1);
    for (int i = 0; i < nu; ++i) {
        for (int j = 0; j < nv; ++j) {
            const double uc = 0.5 * (U[size_t(i)] + U[size_t(i) + 1]);
            const double vc = 0.5 * (Vv[size_t(j)] + Vv[size_t(j) + 1]);
            int found = -1;
            for (int k : ids) {
                const PatchRec& p = patches[size_t(k)];
                if (uc > p.u0 && uc < p.u0 + p.frac && vc > p.v0 && vc < p.v0 + p.frac) {
                    found = k;
                    break;
                }
            }
            if (found < 0) {
                return nullptr;
            }
            cell_patch[size_t(i) * size_t(nv) + size_t(j)] = found;
            greg[size_t(i) * size_t(nv) + size_t(j)] = patches[size_t(found)].gregory ? 1 : 0;
        }
    }
    // End caps first, regular cells last: a pole shared by both takes the regular cell's value,
    // so every regular cell keeps its exact poles (the C1 correction below builds on them).
    for (int pass = 0; pass < 2; ++pass) {
        for (int i = 0; i < nu; ++i) {
            for (int j = 0; j < nv; ++j) {
                if ((greg[size_t(i) * size_t(nv) + size_t(j)] != 0) != (pass == 0)) {
                    continue;
                }
                const PatchRec& p = patches[size_t(cell_patch[size_t(i) * size_t(nv) + size_t(j)])];
                const double s1 = (U[size_t(i)] - p.u0) / p.frac, s2 = (U[size_t(i) + 1] - p.u0) / p.frac;
                const double t1 = (Vv[size_t(j)] - p.v0) / p.frac, t2 = (Vv[size_t(j) + 1] - p.v0) / p.frac;
                Handle(Geom_BezierSurface) b = bezier_surface(p.bez);
                if (s2 - s1 < 1.0 - 1e-12 || t2 - t1 < 1.0 - 1e-12) {
                    b->Segment(s1, s2, t1, t2);
                }
                for (int row = 0; row < 4; ++row) {
                    for (int col = 0; col < 4; ++col) {
                        at(3 * i + col, 3 * j + row) = b->Pole(col + 1, row + 1).XYZ();
                    }
                }
            }
        }
    }
    double size = 0.0;
    {
        gp_XYZ lo = Q[0], hi = Q[0];
        for (const gp_XYZ& x : Q) {
            lo.SetCoord(std::min(lo.X(), x.X()), std::min(lo.Y(), x.Y()), std::min(lo.Z(), x.Z()));
            hi.SetCoord(std::max(hi.X(), x.X()), std::max(hi.Y(), x.Y()), std::max(hi.Z(), x.Z()));
        }
        size = std::max((hi - lo).Modulus(), 1e-300);
    }
    auto is_greg = [&](int i, int j) { return greg[size_t(i) * size_t(nv) + size_t(j)] != 0; };
    double max_adjust = 0.0;
    auto move_to = [&](gp_XYZ& pole, const gp_XYZ& target) {
        max_adjust = std::max(max_adjust, (target - pole).Modulus());
        pole = target;
    };
    // One pass of C1 corrections across every interior knot line in u (across_u) or v.
    auto c1_pass = [&](bool across_u) {
        const int nk = across_u ? nu : nv;          // cells across the knot lines
        const int nl = across_u ? NV : NU;          // poles along a knot line
        const int ncells_along = across_u ? nv : nu;
        const std::vector<double>& K = across_u ? U : Vv;
        for (int k = 1; k < nk; ++k) {
            const int c = 3 * k;
            const double hl = K[size_t(k)] - K[size_t(k) - 1], hr = K[size_t(k) + 1] - K[size_t(k)];
            for (int r = 0; r < nl; ++r) {
                // The cells along the line that hold pole row r (two at a cell border).
                const int j0 = std::max(0, (r % 3 == 0 ? r / 3 - 1 : r / 3));
                const int j1 = std::min(ncells_along - 1, r / 3);
                bool gl = false, gr = false;
                for (int j = j0; j <= j1; ++j) {
                    gl = gl || (across_u ? is_greg(k - 1, j) : is_greg(j, k - 1));
                    gr = gr || (across_u ? is_greg(k, j) : is_greg(j, k));
                }
                if (!gl && !gr) {
                    continue;  // regular patches meet C2 already
                }
                gp_XYZ& L = across_u ? at(c - 1, r) : at(r, c - 1);
                gp_XYZ& M = across_u ? at(c, r) : at(r, c);
                gp_XYZ& R = across_u ? at(c + 1, r) : at(r, c + 1);
                if (gl && !gr) {
                    move_to(L, M + (M - R) * (hl / hr));
                }
                else if (gr && !gl) {
                    move_to(R, M + (M - L) * (hr / hl));
                }
                else {
                    const gp_XYZ d = M - (L * hr + R * hl) / (hl + hr);
                    move_to(L, L + d);
                    move_to(R, R + d);
                }
            }
        }
    };
    const std::vector<gp_XYZ> before = Q;
    for (int pass = 0; pass < 2; ++pass) {
        c1_pass(true);
        c1_pass(false);
    }
    // The end cap's interior poles that touch no interior knot line (the one next to the
    // extraordinary vertex) move back by the mean of the corrections: the cap's cross-boundary
    // tangents along the face edges then stay closest to the Gregory patch's (measured: the
    // normal jump across face edges near a valence-3 vertex at isolation 6 drops from 0.038 to
    // 0.016 degrees, valence 8 from 0.27 to 0.19). Those poles touch no knot, so C1 holds.
    {
        constexpr double alpha = -1.0;
        {
            for (int i = 0; i < nu; ++i) {
                for (int j = 0; j < nv; ++j) {
                    if (!is_greg(i, j)) {
                        continue;
                    }
                    gp_XYZ sum(0, 0, 0);
                    int moved = 0;
                    std::vector<std::pair<int, int>> still;
                    for (int a = 1; a <= 2; ++a) {
                        for (int b = 1; b <= 2; ++b) {
                            // A pole next to an interior knot line carries a C1 condition; only
                            // the others (next to the face's own boundary on both sides) move.
                            const bool on_knot = (a == 1 && i > 0) || (a == 2 && i < nu - 1) || (b == 1 && j > 0) || (b == 2 && j < nv - 1);
                            if (on_knot) {
                                sum += at(3 * i + a, 3 * j + b) - before[size_t(3 * i + a) * size_t(NV) + size_t(3 * j + b)];
                                ++moved;
                            }
                            else {
                                still.push_back({3 * i + a, 3 * j + b});
                            }
                        }
                    }
                    if (moved > 0) {
                        for (auto [a, b] : still) {
                            at(a, b) += sum * (alpha / moved);
                        }
                    }
                }
            }
        }
    }
    TColgp_Array2OfPnt poles(1, NU, 1, NV);
    for (int iu = 0; iu < NU; ++iu) {
        for (int iv = 0; iv < NV; ++iv) {
            poles(iu + 1, iv + 1) = gp_Pnt(at(iu, iv));
        }
    }
    TColStd_Array1OfReal UK(1, nu + 1), VK(1, nv + 1);
    TColStd_Array1OfInteger UM(1, nu + 1), VM(1, nv + 1);
    for (int i = 0; i <= nu; ++i) {
        UK(i + 1) = U[size_t(i)];
        UM(i + 1) = (i == 0 || i == nu) ? 4 : 3;
    }
    for (int j = 0; j <= nv; ++j) {
        VK(j + 1) = Vv[size_t(j)];
        VM(j + 1) = (j == 0 || j == nv) ? 4 : 3;
    }
    Handle(Geom_BSplineSurface) bs = new Geom_BSplineSurface(poles, UK, VK, UM, VM, 3, 3);
    // Interior knots back to C2 where the patches allow it, else C1 (exact up to rounding now).
    const double ktol = std::max(1e-10 * size, 1e-15);
    int c0 = 0;
    for (int i = bs->NbUKnots() - 1; i >= 2; --i) {
        if (!bs->RemoveUKnot(i, 1, ktol) && !bs->RemoveUKnot(i, 2, ktol) && !bs->RemoveUKnot(i, 2, std::min(1e-7 * size, 1e-8))) {
            ++c0;
        }
    }
    for (int i = bs->NbVKnots() - 1; i >= 2; --i) {
        if (!bs->RemoveVKnot(i, 1, ktol) && !bs->RemoveVKnot(i, 2, ktol) && !bs->RemoveVKnot(i, 2, std::min(1e-7 * size, 1e-8))) {
            ++c0;
        }
    }
    if (stats) {
        stats->max_adjust = std::max(stats->max_adjust, max_adjust / size);
        stats->c0_knots += c0;
    }
    return bs;
}

/// Ptex face: a quad of the cage (sub = -1) or sub-face k of an n-gon.
struct PFace
{
    int face = 0;
    int sub = -1;
    Handle(Geom_BSplineSurface) surf;
};

// Topological vertex keys: (kind, a, b): 0 = cage vertex a; 1 = midpoint of edge (a, b), a < b;
// 2 = centre of face a.
using VKey = std::tuple<int, int, int>;
// Edge pieces: (kind, a, b, c): 0 = whole cage edge (a, b); 1 = half of edge (a, b) next to the
// end with half index c (0 = a, 1 = b); 2 = spoke c of face a (edge-k midpoint to centre).
using PKey = std::tuple<int, int, int, int>;

struct SidePiece
{
    PKey key;
    double ta = 0.0, tb = 1.0;  // range along the side, t from the side's start corner
    VKey va, vb;                // keys at ta and tb
};

/// Point of a side at local t (side s runs corner s -> corner s+1 of the unit square).
gp_Pnt2d side_uv(int s, double t)
{
    switch (s) {
        case 0:
            return gp_Pnt2d(t, 0.0);
        case 1:
            return gp_Pnt2d(1.0, t);
        case 2:
            return gp_Pnt2d(1.0 - t, 1.0);
        default:
            return gp_Pnt2d(0.0, 1.0 - t);
    }
}

struct Piece
{
    TopoDS_Edge edge;
    double e0 = 0.0, e1 = 1.0;
    VKey start, end;
    int uses = 0;
};

struct ShellBuild
{
    TopoDS_Shape shape;
    std::vector<TopoDS_Face> faces;  // per ptex face of the component, in order
    bool closed = false;
    bool solid = false;
    int free_edges = 0;
};

/// The sides of a ptex face as edge pieces, and its corner keys.
void ptex_sides(const CageData& c, const PFace& pf, const std::vector<char>& split, std::vector<SidePiece> sides[4])
{
    const int f = pf.face;
    const int n = c.counts[size_t(f)];
    const int* fv = &c.indices[size_t(c.offsets[size_t(f)])];
    auto half_of = [](int x, int a, int b) { return x == std::min(a, b) ? 0 : 1; };
    auto mid = [](int a, int b) { return VKey(1, std::min(a, b), std::max(a, b)); };
    auto vk = [](int v) { return VKey(0, v, 0); };
    for (int s = 0; s < 4; ++s) {
        sides[s].clear();
    }
    if (pf.sub < 0) {
        for (int s = 0; s < 4; ++s) {
            const int a = fv[s], b = fv[(s + 1) % 4];
            const int e = c.corner_edge[size_t(c.offsets[size_t(f)] + s)];
            const int lo = std::min(a, b), hi = std::max(a, b);
            if (split[size_t(e)]) {
                sides[s].push_back({PKey(1, lo, hi, half_of(a, a, b)), 0.0, 0.5, vk(a), mid(a, b)});
                sides[s].push_back({PKey(1, lo, hi, half_of(b, a, b)), 0.5, 1.0, mid(a, b), vk(b)});
            }
            else {
                sides[s].push_back({PKey(0, lo, hi, 0), 0.0, 1.0, vk(a), vk(b)});
            }
        }
        return;
    }
    const int k = pf.sub;
    const int a = fv[k], next = fv[(k + 1) % n], prev = fv[(k + n - 1) % n];
    const VKey centre(2, f, 0);
    sides[0].push_back({PKey(1, std::min(a, next), std::max(a, next), half_of(a, a, next)), 0.0, 1.0, vk(a), mid(a, next)});
    sides[1].push_back({PKey(2, f, k, 0), 0.0, 1.0, mid(a, next), centre});
    sides[2].push_back({PKey(2, f, (k + n - 1) % n, 0), 0.0, 1.0, centre, mid(prev, a)});
    sides[3].push_back({PKey(1, std::min(prev, a), std::max(prev, a), half_of(a, prev, a)), 0.0, 1.0, mid(prev, a), vk(a)});
}

/// Direct shell: shared edges and vertices, iso-line pcurves (no sewing).
bool direct_shell(const CageData& c, const std::vector<PFace>& pfaces, const std::vector<int>& comp_ptex,
                  const std::vector<char>& split, double tol, ShellBuild& out, std::string& error)
{
    BRep_Builder B;
    std::map<VKey, TopoDS_Vertex> verts;
    std::map<PKey, Piece> pieces;
    TopoDS_Shell shell;
    B.MakeShell(shell);
    out.faces.clear();
    std::vector<SidePiece> sides[4];
    for (int pi : comp_ptex) {
        const PFace& pf = pfaces[size_t(pi)];
        ptex_sides(c, pf, split, sides);
        const Handle(Geom_BSplineSurface)& S = pf.surf;
        TopoDS_Face F;
        B.MakeFace(F, S, tol);
        TopoDS_Wire W;
        B.MakeWire(W);
        for (int s = 0; s < 4; ++s) {
            for (const SidePiece& sp : sides[s]) {
                auto it = pieces.find(sp.key);
                if (it == pieces.end()) {
                    Handle(Geom_Curve) C3 = (s == 0 || s == 2) ? S->VIso(s == 0 ? 0.0 : 1.0) : S->UIso(s == 1 ? 1.0 : 0.0);
                    Piece p;
                    const bool increasing = s == 0 || s == 1;
                    p.e0 = increasing ? sp.ta : 1.0 - sp.tb;
                    p.e1 = increasing ? sp.tb : 1.0 - sp.ta;
                    p.start = increasing ? sp.va : sp.vb;
                    p.end = increasing ? sp.vb : sp.va;
                    B.MakeEdge(p.edge, C3, tol);
                    B.Range(p.edge, p.e0, p.e1);
                    for (int end = 0; end < 2; ++end) {
                        const VKey& key = end == 0 ? p.start : p.end;
                        const double param = end == 0 ? p.e0 : p.e1;
                        auto vit = verts.find(key);
                        if (vit == verts.end()) {
                            TopoDS_Vertex v;
                            B.MakeVertex(v, C3->Value(param), tol);
                            vit = verts.emplace(key, v).first;
                        }
                        TopoDS_Vertex v = vit->second;
                        v.Orientation(end == 0 ? TopAbs_FORWARD : TopAbs_REVERSED);
                        B.Add(p.edge, v);
                        B.UpdateVertex(v, param, p.edge, tol);
                    }
                    it = pieces.emplace(sp.key, p).first;
                }
                Piece& p = it->second;
                // This face's pcurve: the edge parameter runs linearly along the side piece.
                bool forward;
                if (p.start == sp.va && p.end == sp.vb) {
                    forward = true;
                }
                else if (p.start == sp.vb && p.end == sp.va) {
                    forward = false;
                }
                else {
                    error = "Edge piece ends disagree between faces";
                    return false;
                }
                const gp_Pnt2d uv0 = side_uv(s, forward ? sp.ta : sp.tb);
                const gp_Pnt2d uv1 = side_uv(s, forward ? sp.tb : sp.ta);
                const double len = uv0.Distance(uv1);
                const double span = p.e1 - p.e0;
                Handle(Geom2d_Curve) pc;
                if (std::fabs(len - span) <= 1e-14) {
                    const gp_Dir2d dir(uv1.X() - uv0.X(), uv1.Y() - uv0.Y());
                    pc = new Geom2d_Line(gp_Pnt2d(uv0.X() - p.e0 * dir.X(), uv0.Y() - p.e0 * dir.Y()), dir);
                }
                else {
                    TColgp_Array1OfPnt2d poles(1, 2);
                    poles(1) = uv0;
                    poles(2) = uv1;
                    TColStd_Array1OfReal knots(1, 2);
                    knots(1) = p.e0;
                    knots(2) = p.e1;
                    TColStd_Array1OfInteger mults(1, 2);
                    mults(1) = 2;
                    mults(2) = 2;
                    pc = new Geom2d_BSplineCurve(poles, knots, mults, 1);
                }
                B.UpdateEdge(p.edge, pc, F, tol);
                p.uses += 1;
                TopoDS_Edge oriented = p.edge;
                oriented.Orientation(forward ? TopAbs_FORWARD : TopAbs_REVERSED);
                B.Add(W, oriented);
            }
        }
        W.Closed(Standard_True);
        B.Add(F, W);
        B.Add(shell, F);
        out.faces.push_back(F);
    }
    bool closed = true;
    out.free_edges = 0;
    for (auto& kv : pieces) {
        Piece& p = kv.second;
        B.Range(p.edge, p.e0, p.e1);
        B.SameParameter(p.edge, Standard_True);
        B.SameRange(p.edge, Standard_True);
        if (p.uses < 2) {
            closed = false;
            out.free_edges += 1;
        }
    }
    shell.Closed(closed && BRep_Tool::IsClosed(shell));
    out.closed = shell.Closed();
    if (out.closed) {
        TopoDS_Solid solid;
        B.MakeSolid(solid);
        B.Add(solid, shell);
        BRepLib::OrientClosedSolid(solid);
        out.shape = solid;
        out.solid = true;
    }
    else {
        out.shape = shell;
        out.solid = false;
    }
    return true;
}

/// Fallback: sew the faces of the component, fix the shell, make a solid when closed.
bool sewn_shell(const std::vector<PFace>& pfaces, const std::vector<int>& comp_ptex, double tol, ShellBuild& out,
                TopTools_DataMapOfShapeInteger& face_ptex)
{
    BRepBuilderAPI_Sewing sew(1e-6, Standard_True, Standard_True, Standard_True, Standard_False);
    std::vector<TopoDS_Face> made;
    for (int pi : comp_ptex) {
        BRepBuilderAPI_MakeFace mf(pfaces[size_t(pi)].surf, tol);
        if (!mf.IsDone()) {
            return false;
        }
        made.push_back(mf.Face());
        sew.Add(mf.Face());
    }
    sew.Perform();
    TopoDS_Shape sewn = sew.SewedShape();
    out.free_edges = sew.NbFreeEdges();
    for (size_t i = 0; i < made.size(); ++i) {
        TopoDS_Shape m = sew.IsModified(made[i]) ? sew.Modified(made[i]) : made[i];
        for (TopExp_Explorer ex(m, TopAbs_FACE); ex.More(); ex.Next()) {
            face_ptex.Bind(ex.Current(), comp_ptex[i]);
        }
    }
    TopoDS_Shell shell;
    int shells = 0;
    for (TopExp_Explorer ex(sewn, TopAbs_SHELL); ex.More(); ex.Next()) {
        shell = TopoDS::Shell(ex.Current());
        ++shells;
    }
    if (shells != 1) {
        out.shape = sewn;
        out.closed = false;
        out.solid = false;
        return !sewn.IsNull();
    }
    ShapeFix_Shell fix(shell);
    fix.Perform();
    shell = fix.Shell();
    out.closed = BRep_Tool::IsClosed(shell);
    if (out.closed) {
        BRepBuilderAPI_MakeSolid ms(shell);
        if (ms.IsDone()) {
            TopoDS_Solid solid = ms.Solid();
            ShapeFix_Solid fs(solid);
            fs.Perform();
            TopoDS_Shape fixed = fs.Solid();
            TopoDS_Solid result;
            for (TopExp_Explorer ex(fixed, TopAbs_SOLID); ex.More(); ex.Next()) {
                result = TopoDS::Solid(ex.Current());
                break;
            }
            if (!result.IsNull()) {
                BRepLib::OrientClosedSolid(result);
                out.shape = result;
                out.solid = true;
                return true;
            }
        }
    }
    out.shape = shell;
    out.solid = false;
    return true;
}

std::string face_name(const std::string& prefix, const PFace& pf)
{
    std::string base = prefix.empty() ? std::string() : prefix + "/";
    base += "f" + std::to_string(pf.face);
    if (pf.sub >= 0) {
        base += "." + std::to_string(pf.sub);
    }
    return base;
}

}  // namespace

bool convert(const CageData& c, const ConvertParams& params, ConvertResult& result, std::string& error)
{
    const double t_start = now_ms();
    result = ConvertResult();
    const int L = std::clamp(params.isolation, 1, 10);
    const double tol = params.tolerance > 0.0 ? params.tolerance : 1e-7;
    const int nF = c.face_count();
    if (nF == 0) {
        error = "The cage has no faces";
        return false;
    }
    try {
        // 1. Patch table (isolation L, Gregory end caps, infinitely sharp patches).
        std::unique_ptr<osd::TopologyRefiner> r = make_refiner(c, error);
        if (!r) {
            return false;
        }
        Far::PatchTableFactory::Options po(static_cast<unsigned>(L));
        po.SetPatchPrecision<double>();
        po.useInfSharpPatch = true;
        po.useSingleCreasePatch = false;
        po.generateVaryingTables = false;
        po.generateLegacySharpCornerPatches = false;
        po.SetEndCapType(Far::PatchTableFactory::Options::ENDCAP_GREGORY_BASIS);
        r->RefineAdaptive(po.GetRefineAdaptiveOptions());
        std::unique_ptr<Far::PatchTable> table(Far::PatchTableFactory::Create(*r, po));
        if (!table) {
            error = "OpenSubdiv could not build the patch table";
            return false;
        }
        const int nRef = r->GetNumVerticesTotal();
        const int nLoc = table->GetNumLocalPoints();
        std::vector<V3> verts(static_cast<size_t>(nRef) + size_t(nLoc));
        for (int v = 0; v < c.nV; ++v) {
            verts[size_t(v)] = {c.pos[size_t(v) * 3], c.pos[size_t(v) * 3 + 1], c.pos[size_t(v) * 3 + 2]};
        }
        Far::PrimvarRefinerReal<double> pr(*r);
        V3* src = verts.data();
        for (int lv = 1; lv < r->GetNumLevels(); ++lv) {
            V3* dst = src + r->GetLevel(lv - 1).GetNumVertices();
            pr.Interpolate(lv, src, dst);
            src = dst;
        }
        if (nLoc > 0) {
            const Far::StencilTableReal<double>* local = table->GetLocalPointStencilTable<double>();
            if (local) {
                local->UpdateValues(verts.data(), verts.data() + nRef);
            }
        }
        Far::PtexIndices ptexIndices(*r);
        std::vector<PFace> pfaces(static_cast<size_t>(ptexIndices.GetNumFaces()));
        for (int f = 0; f < nF; ++f) {
            const int base = ptexIndices.GetFaceId(f);
            if (base != c.ptex_base[size_t(f)]) {
                error = "Ptex numbering differs from the cage's";
                return false;
            }
            if (c.counts[size_t(f)] == 4) {
                pfaces[size_t(base)] = {f, -1, nullptr};
            }
            else {
                for (int k = 0; k < c.counts[size_t(f)]; ++k) {
                    pfaces[size_t(base + k)] = {f, k, nullptr};
                }
            }
        }

        // 2. Patches to bicubic Bezier.
        std::vector<PatchRec> patches;
        patches.reserve(size_t(table->GetNumPatchesTotal()));
        for (int a = 0; a < table->GetNumPatchArrays(); ++a) {
            const Far::PatchDescriptor desc = table->GetPatchArrayDescriptor(a);
            for (int p = 0; p < table->GetNumPatches(a); ++p) {
                const Far::ConstIndexArray cvs = table->GetPatchVertices(a, p);
                const Far::PatchParam pp = table->GetPatchParam(a, p);
                PatchRec rec;
                if (desc.GetType() == Far::PatchDescriptor::REGULAR) {
                    V3 B[4][4];
                    for (int row = 0; row < 4; ++row) {
                        for (int col = 0; col < 4; ++col) {
                            B[row][col] = verts[size_t(cvs[4 * row + col])];
                        }
                    }
                    const int bnd = pp.GetBoundary();
                    auto lin = [](const V3& x, const V3& y) { return V3{2 * x.x - y.x, 2 * x.y - y.y, 2 * x.z - y.z}; };
                    if (bnd & 8) {
                        for (int row = 0; row < 4; ++row) {
                            B[row][0] = lin(B[row][1], B[row][2]);
                        }
                    }
                    if (bnd & 2) {
                        for (int row = 0; row < 4; ++row) {
                            B[row][3] = lin(B[row][2], B[row][1]);
                        }
                    }
                    if (bnd & 1) {
                        for (int col = 0; col < 4; ++col) {
                            B[0][col] = lin(B[1][col], B[2][col]);
                        }
                    }
                    if (bnd & 4) {
                        for (int col = 0; col < 4; ++col) {
                            B[3][col] = lin(B[2][col], B[1][col]);
                        }
                    }
                    bspline_to_bezier(B, rec.bez);
                }
                else if (desc.GetType() == Far::PatchDescriptor::GREGORY_BASIS) {
                    static const int bg[12] = {0, 1, 7, 5, 2, 6, 16, 12, 15, 17, 11, 10};
                    static const int bs[12] = {0, 1, 2, 3, 0, 3, 0, 3, 0, 1, 2, 3};
                    static const int bt[12] = {0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 3, 3};
                    auto P = [&](int i) {
                        const V3& v = verts[size_t(cvs[i])];
                        return gp_Pnt(v.x, v.y, v.z);
                    };
                    auto avg = [&](int i, int j) {
                        const V3& x = verts[size_t(cvs[i])];
                        const V3& y = verts[size_t(cvs[j])];
                        return gp_Pnt(0.5 * (x.x + y.x), 0.5 * (x.y + y.y), 0.5 * (x.z + y.z));
                    };
                    for (int i = 0; i < 12; ++i) {
                        rec.bez.P[bt[i]][bs[i]] = P(bg[i]);
                    }
                    rec.bez.P[1][1] = avg(3, 4);
                    rec.bez.P[1][2] = avg(8, 9);
                    rec.bez.P[2][2] = avg(13, 14);
                    rec.bez.P[2][1] = avg(18, 19);
                    rec.gregory = true;
                }
                else {
                    error = "Unsupported patch type " + std::to_string(int(desc.GetType()));
                    return false;
                }
                rec.ptex = pp.GetFaceId();
                rec.frac = pp.GetParamFraction();
                rec.u0 = pp.GetU() * rec.frac;
                rec.v0 = pp.GetV() * rec.frac;
                patches.push_back(rec);
            }
        }
        const double t_patches = now_ms();
        result.ms_patches = t_patches - t_start;

        // 3. One B-spline surface per ptex face.
        std::vector<std::vector<int>> by_ptex(pfaces.size());
        for (int i = 0; i < int(patches.size()); ++i) {
            if (patches[size_t(i)].ptex < 0 || patches[size_t(i)].ptex >= int(pfaces.size())) {
                error = "A patch refers to a missing face";
                return false;
            }
            by_ptex[size_t(patches[size_t(i)].ptex)].push_back(i);
        }
        for (const PatchRec& p : patches) {
            for (int r = 0; r < 4; ++r) {
                for (int col = 0; col < 4; ++col) {
                    const gp_Pnt& q = p.bez.P[r][col];
                    if (!std::isfinite(q.X()) || !std::isfinite(q.Y()) || !std::isfinite(q.Z())) {
                        error = "The surface could not be evaluated (a vertex position is not a finite number)";
                        return false;
                    }
                }
            }
        }
        MergeStats mstats;
        for (size_t pi = 0; pi < pfaces.size(); ++pi) {
            pfaces[pi].surf = merge_face(patches, by_ptex[pi], &mstats);
            if (pfaces[pi].surf.IsNull()) {
                error = "Could not merge the patches of face " + std::to_string(pfaces[pi].face);
                return false;
            }
        }
        const double t_merge = now_ms();
        result.ms_merge = t_merge - t_patches;
        result.c1_adjust = mstats.max_adjust;
        result.c0_knots = mstats.c0_knots;
        if (mstats.c0_knots > 0) {
            result.warnings.push_back(std::to_string(mstats.c0_knots) +
                                      " patch seams stay sharp-parameterized (C0); offsets and shells of this body may fail");
        }

        // 4. Edge-connected components, ordered by lowest face.
        std::vector<int> parent(static_cast<size_t>(nF));
        std::iota(parent.begin(), parent.end(), 0);
        auto find = [&](int x) {
            while (parent[size_t(x)] != x) {
                parent[size_t(x)] = parent[size_t(parent[size_t(x)])];
                x = parent[size_t(x)];
            }
            return x;
        };
        std::vector<int> edge_face(size_t(c.edge_count()), -1);
        for (int f = 0; f < nF; ++f) {
            for (int k = 0; k < c.counts[size_t(f)]; ++k) {
                const int e = c.corner_edge[size_t(c.offsets[size_t(f)] + k)];
                if (edge_face[size_t(e)] < 0) {
                    edge_face[size_t(e)] = f;
                }
                else {
                    const int ra = find(edge_face[size_t(e)]), rb = find(f);
                    if (ra != rb) {
                        parent[size_t(std::max(ra, rb))] = std::min(ra, rb);
                    }
                }
            }
        }
        std::map<int, std::vector<int>> comps;  // root (= lowest face) -> ptex faces
        for (int f = 0; f < nF; ++f) {
            std::vector<int>& list = comps[find(f)];
            const int base = c.ptex_base[size_t(f)];
            const int n = c.counts[size_t(f)] == 4 ? 1 : c.counts[size_t(f)];
            for (int k = 0; k < n; ++k) {
                list.push_back(base + k);
            }
        }
        // Edges next to a non-quad face are split at their midpoints.
        std::vector<char> split(size_t(c.edge_count()), 0);
        for (int f = 0; f < nF; ++f) {
            if (c.counts[size_t(f)] != 4) {
                for (int k = 0; k < c.counts[size_t(f)]; ++k) {
                    split[size_t(c.corner_edge[size_t(c.offsets[size_t(f)] + k)])] = 1;
                }
            }
        }

        // Volume and area straight from the patches (the faces are exactly these patches).
        std::map<int, std::pair<double, double>> measures;  // root -> (3 x signed volume, area)
        const double t_measure = now_ms();
        for (const PatchRec& p : patches) {
            double v3 = 0.0, a = 0.0;
            patch_measures(p.bez, v3, a);
            auto& m = measures[find(pfaces[size_t(p.ptex)].face)];
            m.first += v3;
            m.second += a;
        }
        result.ms_props += now_ms() - t_measure;

        // 5. Shells.
        for (auto& kv : comps) {
            const std::vector<int>& comp_ptex = kv.second;
            ConvertComponent out;
            ShellBuild build;
            const double t0 = now_ms();
            std::string shell_error;
            bool ok = !params.force_sewing && direct_shell(c, pfaces, comp_ptex, split, tol, build, shell_error);
            if (params.force_sewing) {
                shell_error = "sewing asked for";
            }
            const double t1 = now_ms();
            result.ms_shell += t1 - t0;
            bool valid = ok;
            if (ok && params.check) {
                valid = BRepCheck_Analyzer(build.shape).IsValid();
            }
            result.ms_check += now_ms() - t1;
            TopTools_DataMapOfShapeInteger face_ptex;
            if (ok) {
                for (size_t i = 0; i < build.faces.size(); ++i) {
                    face_ptex.Bind(build.faces[i], comp_ptex[i]);
                }
            }
            if (!ok || !valid) {
                ShellBuild sewn;
                TopTools_DataMapOfShapeInteger sewn_ptex;
                const double t2 = now_ms();
                if (sewn_shell(pfaces, comp_ptex, tol, sewn, sewn_ptex)) {
                    build = sewn;
                    face_ptex = sewn_ptex;
                    valid = params.check ? BRepCheck_Analyzer(build.shape).IsValid() : true;
                    out.sewn = true;
                    result.warnings.push_back("Component with face " + std::to_string(kv.first) +
                                              " converted by sewing (slower path)" +
                                              (shell_error.empty() ? std::string() : ": " + shell_error));
                }
                else if (!ok) {
                    error = shell_error.empty() ? std::string("Could not build the surface faces") : shell_error;
                    return false;
                }
                result.ms_shell += now_ms() - t2;
            }
            const double t3 = now_ms();
            if (params.regularity > 0.0) {
                BRepLib::EncodeRegularity(build.shape, params.regularity);
            }
            result.ms_regularity += now_ms() - t3;
            out.shape = build.shape;
            out.closed = build.closed;
            out.solid = build.solid;
            out.valid = valid;
            out.free_edges = build.free_edges;
            out.volume = out.solid ? std::fabs(measures[kv.first].first) / 3.0 : 0.0;
            out.area = measures[kv.first].second;
            TopTools_IndexedMapOfShape faces;
            TopExp::MapShapes(build.shape, TopAbs_FACE, faces);
            out.faces = faces.Extent();
            for (int i = 1; i <= faces.Extent(); ++i) {
                int pi = -1;
                if (face_ptex.Find(faces(i), pi) && pi >= 0) {
                    out.face_names.push_back(face_name(params.prefix, pfaces[size_t(pi)]));
                }
                else {
                    out.face_names.push_back((params.prefix.empty() ? std::string() : params.prefix + "/") + "f?" +
                                             std::to_string(i - 1));
                }
            }
            result.components.push_back(out);
        }
    }
    catch (const Standard_Failure& failure) {
        error = std::string("Conversion failed: ") + (failure.GetMessageString() ? failure.GetMessageString() : "OCCT error");
        return false;
    }
    result.ms = now_ms() - t_start;
    return true;
}

// ---------------------------------------------------------------- B-rep helpers

namespace
{

/// A triangulated copy of a shape's faces with a triangle hierarchy, kept for the last few
/// shapes asked about (strong references, so a freed shape's address can't be mistaken for a
/// new one).
struct ShapeMesh
{
    TopoDS_Shape shape;
    std::vector<TopoDS_Face> faces;  // the shape's faces in face map order
    std::vector<double> verts;       // 3 per node
    std::vector<double> uvs;         // 2 per node (on its face)
    std::vector<int> tris;           // 3 per triangle
    std::vector<int> tri_face;
    Bvh bvh;
    double deflection = 0.0;
};

std::mutex g_mesh_mutex;
std::list<std::shared_ptr<ShapeMesh>> g_meshes;

std::shared_ptr<ShapeMesh> mesh_for(const TopoDS_Shape& shape)
{
    {
        std::lock_guard<std::mutex> lock(g_mesh_mutex);
        for (auto it = g_meshes.begin(); it != g_meshes.end(); ++it) {
            if ((*it)->shape.IsEqual(shape)) {
                auto hit = *it;
                g_meshes.erase(it);
                g_meshes.push_front(hit);
                return hit;
            }
        }
    }
    auto m = std::make_shared<ShapeMesh>();
    m->shape = shape;
    TopTools_IndexedMapOfShape faces;
    TopExp::MapShapes(shape, TopAbs_FACE, faces);
    Bnd_Box box;
    BRepBndLib::Add(shape, box);
    const double diag = box.IsVoid() ? 1.0 : std::sqrt(box.SquareExtent());
    m->deflection = std::max(1e-3 * diag, 1e-9);
    // Mesh a copy, so the caller's shape keeps the triangulation it had (display meshes).
    BRepBuilderAPI_Copy copier(shape, Standard_False, Standard_False);
    const TopoDS_Shape copy = copier.Shape();
    BRepMesh_IncrementalMesh mesher(copy, m->deflection, Standard_False, 0.2, Standard_False);
    std::vector<Box> boxes;
    for (int fi = 1; fi <= faces.Extent(); ++fi) {
        const TopoDS_Face& face = TopoDS::Face(faces(fi));
        m->faces.push_back(face);
        const TopoDS_Shape& mod = copier.ModifiedShape(face);
        if (mod.IsNull() || mod.ShapeType() != TopAbs_FACE) {
            continue;
        }
        TopLoc_Location loc;
        Handle(Poly_Triangulation) tri = BRep_Tool::Triangulation(TopoDS::Face(mod), loc);
        if (tri.IsNull()) {
            continue;
        }
        const gp_Trsf trsf = loc.Transformation();
        const int base = int(m->verts.size() / 3);
        for (int n = 1; n <= tri->NbNodes(); ++n) {
            const gp_Pnt p = tri->Node(n).Transformed(trsf);
            m->verts.push_back(p.X());
            m->verts.push_back(p.Y());
            m->verts.push_back(p.Z());
            const gp_Pnt2d uv = tri->HasUVNodes() ? tri->UVNode(n) : gp_Pnt2d(0.0, 0.0);
            m->uvs.push_back(uv.X());
            m->uvs.push_back(uv.Y());
        }
        for (int t = 1; t <= tri->NbTriangles(); ++t) {
            int a = 0, b = 0, cc = 0;
            tri->Triangle(t).Get(a, b, cc);
            m->tris.push_back(base + a - 1);
            m->tris.push_back(base + b - 1);
            m->tris.push_back(base + cc - 1);
            m->tri_face.push_back(fi - 1);
            Box bb;
            bb.add(&m->verts[size_t(base + a - 1) * 3]);
            bb.add(&m->verts[size_t(base + b - 1) * 3]);
            bb.add(&m->verts[size_t(base + cc - 1) * 3]);
            boxes.push_back(bb);
        }
    }
    m->bvh.build(boxes);
    std::lock_guard<std::mutex> lock(g_mesh_mutex);
    g_meshes.push_front(m);
    while (g_meshes.size() > 8) {
        g_meshes.pop_back();
    }
    return m;
}

struct FaceHit
{
    double dist = std::numeric_limits<double>::infinity();
    gp_Pnt point;
    gp_Pnt2d uv;
    bool on_surface = false;
};

/// Closest point on one trimmed face: projections onto its surface kept when inside the face,
/// else the nearest point of its boundary. near_bound: the distance to the face's triangles
/// minus nothing (the mesh lies within `slack` of the surface); a polished seeded projection
/// strictly inside the face and no farther than near_bound + slack is taken without the global
/// search (the common case, about 30x faster).
FaceHit closest_on_face(const TopoDS_Face& face, const gp_Pnt& p, const gp_Pnt2d& seed, double near_bound = -1.0, double slack = 0.0)
{
    FaceHit best;
    TopLoc_Location loc;
    Handle(Geom_Surface) surf = BRep_Tool::Surface(face, loc);
    if (surf.IsNull()) {
        return best;
    }
    const gp_Trsf trsf = loc.Transformation();
    const gp_Pnt local = p.Transformed(trsf.Inverted());
    double u0, u1, v0, v1;
    BRepTools::UVBounds(face, u0, u1, v0, v1);
    const double ftol = std::max(BRep_Tool::Tolerance(face), 1e-9);
    // Newton on |S(u,v) - p|^2 (Gauss-Newton where the Hessian isn't positive definite), kept
    // inside the face's bounds: parameters to rounding where GeomAPI stops near 1e-8.
    auto polish = [&](double& u, double& v) {
        for (int it = 0; it < 30; ++it) {
            gp_Pnt P;
            gp_Vec Du, Dv, Duu, Dvv, Duv;
            surf->D2(u, v, P, Du, Dv, Duu, Dvv, Duv);
            const gp_Vec r(local, P);
            const double g0 = r.Dot(Du), g1 = r.Dot(Dv);
            double h00 = Du.Dot(Du) + r.Dot(Duu), h01 = Du.Dot(Dv) + r.Dot(Duv), h11 = Dv.Dot(Dv) + r.Dot(Dvv);
            double det = h00 * h11 - h01 * h01;
            if (!(det > 0.0) || !(h00 > 0.0)) {
                h00 = Du.Dot(Du);
                h01 = Du.Dot(Dv);
                h11 = Dv.Dot(Dv);
                det = h00 * h11 - h01 * h01;
            }
            if (!(std::fabs(det) > 1e-300)) {
                return;
            }
            const double su = -(h11 * g0 - h01 * g1) / det;
            const double sv = -(h00 * g1 - h01 * g0) / det;
            const double nu = std::clamp(u + su, u0, u1), nv = std::clamp(v + sv, v0, v1);
            const double moved = std::fabs(nu - u) + std::fabs(nv - v);
            u = nu;
            v = nv;
            if (moved <= 1e-15 * (1.0 + std::fabs(u) + std::fabs(v))) {
                return;
            }
        }
    };
    auto consider = [&](double u, double v, bool fast = false) {
        polish(u, v);
        BRepClass_FaceClassifier cls(face, gp_Pnt2d(u, v), ftol);
        const TopAbs_State st = cls.State();
        if (st != TopAbs_IN && st != TopAbs_ON) {
            return false;
        }
        const gp_Pnt q = surf->Value(u, v).Transformed(trsf);
        const double d = q.Distance(p);
        if (d < best.dist) {
            best.dist = d;
            best.point = q;
            best.uv = gp_Pnt2d(u, v);
            best.on_surface = true;
        }
        return fast && st == TopAbs_IN && near_bound >= 0.0 && d <= near_bound + slack;
    };
    // Seeded projection (fast, exact near the seed).
    ShapeAnalysis_Surface sas(surf);
    const gp_Pnt2d near = sas.NextValueOfUV(seed, local, 1e-12);
    if (consider(near.X(), near.Y(), true)) {
        return best;
    }
    // Every extremum over the face's bounds.
    GeomAPI_ProjectPointOnSurf proj;
    proj.Init(local, surf, u0, u1, v0, v1, 1e-12);
    if (proj.IsDone()) {
        for (int i = 1; i <= proj.NbPoints(); ++i) {
            double u = 0.0, v = 0.0;
            proj.Parameters(i, u, v);
            consider(u, v);
        }
    }
    // The boundary (when the surface's nearest point lies outside the trim, or closer).
    for (TopExp_Explorer ex(face, TopAbs_EDGE); ex.More(); ex.Next()) {
        const TopoDS_Edge& edge = TopoDS::Edge(ex.Current());
        if (BRep_Tool::Degenerated(edge)) {
            continue;
        }
        BRepAdaptor_Curve curve(edge);
        Extrema_ExtPC ext(p, curve, 1e-12);
        auto take = [&](const gp_Pnt& q) {
            const double d = q.Distance(p);
            if (d < best.dist - 1e-15) {
                best.dist = d;
                best.point = q;
                best.on_surface = false;
            }
        };
        if (ext.IsDone()) {
            for (int i = 1; i <= ext.NbExt(); ++i) {
                take(ext.Point(i).Value());
            }
        }
        take(curve.Value(curve.FirstParameter()));
        take(curve.Value(curve.LastParameter()));
    }
    if (!best.on_surface && best.dist < std::numeric_limits<double>::infinity()) {
        const gp_Pnt2d uv = sas.ValueOfUV(best.point.Transformed(trsf.Inverted()), 1e-12);
        best.uv = uv;
    }
    return best;
}

}  // namespace

bool project_to_shape(const TopoDS_Shape& shape, const std::vector<double>& points, double max_distance,
                      ProjectResult& result, std::string& error)
{
    result = ProjectResult();
    if (shape.IsNull()) {
        error = "The shape is null";
        return false;
    }
    try {
        std::shared_ptr<ShapeMesh> m = mesh_for(shape);
        if (m->bvh.empty()) {
            error = "The shape has no faces to project onto";
            return false;
        }
        const size_t n = points.size() / 3;
        result.positions.resize(n * 3);
        result.normals.assign(n * 3, 0.0);
        result.faces.assign(n, -1);
        result.distances.assign(n, std::numeric_limits<double>::infinity());
        for (size_t i = 0; i < n; ++i) {
            const double* p = &points[i * 3];
            // Nearest triangle, then every face with a triangle near enough to hold a closer point.
            double best2 = std::numeric_limits<double>::infinity();
            m->bvh.nearest(p, best2, [&](int t, double& b2) {
                double q[3], w1, w2;
                const int* tri = &m->tris[size_t(t) * 3];
                const double d2 = closest_on_triangle(p, &m->verts[size_t(tri[0]) * 3], &m->verts[size_t(tri[1]) * 3],
                                                      &m->verts[size_t(tri[2]) * 3], q, w1, w2);
                if (d2 < b2) {
                    b2 = d2;
                }
            });
            const double reach = std::sqrt(best2) + 4.0 * m->deflection;
            if (max_distance < std::numeric_limits<double>::infinity() && std::sqrt(best2) - 4.0 * m->deflection > max_distance) {
                result.positions[i * 3] = p[0];
                result.positions[i * 3 + 1] = p[1];
                result.positions[i * 3 + 2] = p[2];
                continue;
            }
            std::map<int, std::pair<double, gp_Pnt2d>> candidates;  // face -> (triangle distance, seed uv)
            double r2 = reach * reach;
            m->bvh.nearest(p, r2, [&](int t, double&) {
                double q[3], w1, w2;
                const int* tri = &m->tris[size_t(t) * 3];
                const double d2 = closest_on_triangle(p, &m->verts[size_t(tri[0]) * 3], &m->verts[size_t(tri[1]) * 3],
                                                      &m->verts[size_t(tri[2]) * 3], q, w1, w2);
                if (d2 > reach * reach) {
                    return;
                }
                const int f = m->tri_face[size_t(t)];
                const double* ua = &m->uvs[size_t(tri[0]) * 2];
                const double* ub = &m->uvs[size_t(tri[1]) * 2];
                const double* uc = &m->uvs[size_t(tri[2]) * 2];
                const gp_Pnt2d seed((1 - w1 - w2) * ua[0] + w1 * ub[0] + w2 * uc[0], (1 - w1 - w2) * ua[1] + w1 * ub[1] + w2 * uc[1]);
                auto it = candidates.find(f);
                if (it == candidates.end() || d2 < it->second.first) {
                    candidates[f] = {d2, seed};
                }
            });
            FaceHit best;
            int best_face = -1;
            // Nearest triangles first; a face whose triangles lie farther than the best point so
            // far (less the mesh's slack) can't hold a closer one.
            std::vector<std::pair<double, int>> order;
            for (auto& kv : candidates) {
                order.push_back({kv.second.first, kv.first});
            }
            std::sort(order.begin(), order.end());
            for (const auto& [d2, face] : order) {
                if (std::sqrt(d2) - 2.0 * m->deflection > best.dist) {
                    break;
                }
                const auto& kv = *candidates.find(face);
                const FaceHit h = closest_on_face(m->faces[size_t(kv.first)], gp_Pnt(p[0], p[1], p[2]), kv.second.second,
                                                  std::sqrt(kv.second.first), 2.0 * m->deflection);
                if (h.dist < best.dist) {
                    best = h;
                    best_face = kv.first;
                }
            }
            if (best_face < 0 || best.dist > max_distance) {
                result.positions[i * 3] = p[0];
                result.positions[i * 3 + 1] = p[1];
                result.positions[i * 3 + 2] = p[2];
                continue;
            }
            result.positions[i * 3] = best.point.X();
            result.positions[i * 3 + 1] = best.point.Y();
            result.positions[i * 3 + 2] = best.point.Z();
            result.faces[i] = best_face;
            result.distances[i] = best.dist;
            const TopoDS_Face& face = m->faces[size_t(best_face)];
            BRepLProp_SLProps props(BRepAdaptor_Surface(face), best.uv.X(), best.uv.Y(), 1, 1e-12);
            if (props.IsNormalDefined()) {
                gp_Dir nd = props.Normal();
                if (face.Orientation() == TopAbs_REVERSED) {
                    nd.Reverse();
                }
                result.normals[i * 3] = nd.X();
                result.normals[i * 3 + 1] = nd.Y();
                result.normals[i * 3 + 2] = nd.Z();
            }
        }
    }
    catch (const Standard_Failure& failure) {
        error = std::string("Projection failed: ") + (failure.GetMessageString() ? failure.GetMessageString() : "OCCT error");
        return false;
    }
    return true;
}

FaceGridResult face_grid(const TopoDS_Shape& shape, int face_index, int nu, int nv)
{
    FaceGridResult out;
    if (shape.IsNull()) {
        out.error = "The shape is null";
        return out;
    }
    if (nu < 1 || nv < 1) {
        out.error = "The grid needs at least one span each way";
        return out;
    }
    try {
        TopTools_IndexedMapOfShape faces;
        TopExp::MapShapes(shape, TopAbs_FACE, faces);
        if (face_index < 0 || face_index >= faces.Extent()) {
            out.error = "No face " + std::to_string(face_index);
            return out;
        }
        const TopoDS_Face face = TopoDS::Face(faces(face_index + 1));
        int wires = 0;
        for (TopExp_Explorer ex(face, TopAbs_WIRE); ex.More(); ex.Next()) {
            ++wires;
        }
        const TopoDS_Wire outer = BRepTools::OuterWire(face);
        std::vector<TopoDS_Edge> edges;
        if (!outer.IsNull()) {
            for (BRepTools_WireExplorer ex(outer, face); ex.More(); ex.Next()) {
                const TopoDS_Edge& e = ex.Current();
                if (BRep_Tool::Degenerated(e) || BRep_Tool::IsClosed(e, face)) {
                    continue;
                }
                edges.push_back(e);
            }
        }
        // Corners: every junction of a 4-edge wire, else the tangent breaks between edges.
        const size_t ne = edges.size();
        std::vector<char> corner_after(ne, 0);  // junction between edge i and edge i + 1
        bool four = false;
        if (wires == 1 && ne == 4) {
            four = true;
            std::fill(corner_after.begin(), corner_after.end(), 1);
        }
        else if (wires == 1 && ne > 4) {
            int breaks = 0;
            for (size_t i = 0; i < ne; ++i) {
                const TopoDS_Edge& a = edges[i];
                const TopoDS_Edge& b = edges[(i + 1) % ne];
                BRepAdaptor_Curve ca(a), cb(b);
                gp_Pnt pa, pb;
                gp_Vec ta, tb;
                const double la = a.Orientation() == TopAbs_REVERSED ? ca.FirstParameter() : ca.LastParameter();
                const double fb = b.Orientation() == TopAbs_REVERSED ? cb.LastParameter() : cb.FirstParameter();
                ca.D1(la, pa, ta);
                cb.D1(fb, pb, tb);
                if (a.Orientation() == TopAbs_REVERSED) {
                    ta.Reverse();
                }
                if (b.Orientation() == TopAbs_REVERSED) {
                    tb.Reverse();
                }
                if (ta.Magnitude() > 1e-12 && tb.Magnitude() > 1e-12 && ta.Angle(tb) > 0.5 * M_PI / 180.0) {
                    ++breaks;
                    corner_after[i] = 1;
                }
            }
            four = breaks == 4;
        }
        out.four_sided = four;
        out.reversed = face.Orientation() == TopAbs_REVERSED;
        if (!four) {
            out.error = "Only four-sided faces can become a cage in this version";
            return out;
        }
        // The four sides as chains of edges between corners, each walked by arc length; a point
        // of a side is found on its edges' curves on the face (pcurves), so the grid comes from
        // the face's own boundary, whatever the shape of its parameter rectangle.
        struct GridPiece
        {
            Handle(Geom2d_Curve) pc;
            TopoDS_Edge edge;
            double start = 0.0, end = 1.0;  // traversal along the side
            double length = 0.0;
        };
        struct GridSide
        {
            std::vector<GridPiece> pieces;
            double length = 0.0;
        };
        size_t first = 0;
        while (!corner_after[first]) {
            ++first;
        }
        std::vector<GridSide> sides;
        GridSide current;
        for (size_t n = 1; n <= ne; ++n) {
            const size_t i = (first + n) % ne;
            const TopoDS_Edge& e = edges[i];
            GridPiece piece;
            double f = 0.0, l = 0.0;
            piece.pc = BRep_Tool::CurveOnSurface(e, face, f, l);
            if (piece.pc.IsNull()) {
                out.error = "The face's edges have no curves on its surface";
                return out;
            }
            piece.edge = e;
            const bool rev = e.Orientation() == TopAbs_REVERSED;
            piece.start = rev ? l : f;
            piece.end = rev ? f : l;
            {
                BRepAdaptor_Curve curve(e);
                piece.length = GCPnts_AbscissaPoint::Length(curve, std::min(f, l), std::max(f, l));
            }
            current.length += piece.length;
            current.pieces.push_back(piece);
            if (corner_after[i]) {
                sides.push_back(current);
                current = GridSide();
            }
        }
        if (sides.size() != 4) {
            out.error = "Only four-sided faces can become a cage in this version";
            return out;
        }
        // UV of a side at fraction x (0 = its start corner).
        auto side_uv = [&](const GridSide& s, double x) -> gp_Pnt2d {
            double want = std::clamp(x, 0.0, 1.0) * s.length;
            for (size_t k = 0; k < s.pieces.size(); ++k) {
                const GridPiece& pc = s.pieces[k];
                if (want <= pc.length || k + 1 == s.pieces.size()) {
                    double param = pc.start;
                    if (want >= pc.length) {
                        param = pc.end;
                    }
                    else if (want > 0.0 && pc.length > 0.0) {
                        const double sign = pc.end >= pc.start ? 1.0 : -1.0;
                        BRepAdaptor_Curve curve(pc.edge);
                        GCPnts_AbscissaPoint ap(curve, sign * want, pc.start);
                        param = ap.IsDone() ? ap.Parameter() : pc.start + (pc.end - pc.start) * want / pc.length;
                    }
                    return pc.pc->Value(param);
                }
                want -= pc.length;
            }
            return s.pieces.back().pc->Value(s.pieces.back().end);
        };
        // Sides in counter-clockwise order in UV (the grid's u x v along the surface's normal,
        // as callers expect), starting with the side that runs most along +U.
        int order[4] = {0, 1, 2, 3};
        bool reversed_sides = false;
        {
            gp_Pnt2d c[4];
            for (int k = 0; k < 4; ++k) {
                c[k] = side_uv(sides[size_t(k)], 0.0);
            }
            double area = 0.0;
            for (int k = 0; k < 4; ++k) {
                area += c[k].X() * c[(k + 1) % 4].Y() - c[(k + 1) % 4].X() * c[k].Y();
            }
            reversed_sides = area < 0.0;
        }
        // Side k of the oriented loop: (side index, walked backwards?).
        auto oriented = [&](int k, int& index, bool& back) {
            if (!reversed_sides) {
                index = k;
                back = false;
            }
            else {
                index = (4 - 1 - k) % 4;
                back = true;
            }
        };
        auto loop_uv = [&](int k, double x) {
            int index;
            bool back;
            oriented(k, index, back);
            return side_uv(sides[size_t(index)], back ? 1.0 - x : x);
        };
        int start = 0;
        double best_dot = -2.0;
        for (int k = 0; k < 4; ++k) {
            const gp_Pnt2d a = loop_uv(k, 0.0), b = loop_uv(k, 1.0);
            const gp_Vec2d d(a, b);
            if (d.Magnitude() > 0.0) {
                const double dot = d.X() / d.Magnitude();
                if (dot > best_dot + 1e-9) {
                    best_dot = dot;
                    start = k;
                }
            }
        }
        for (int k = 0; k < 4; ++k) {
            order[k] = (start + k) % 4;
        }
        // Coons patch in UV: bottom B(s) = side 0, right R(t) = side 1, top T(s) = side 2
        // backwards, left L(t) = side 3 backwards.
        auto B = [&](double s) { return loop_uv(order[0], s); };
        auto R = [&](double t) { return loop_uv(order[1], t); };
        auto T = [&](double s) { return loop_uv(order[2], 1.0 - s); };
        auto Lf = [&](double t) { return loop_uv(order[3], 1.0 - t); };
        const gp_XY c00 = B(0.0).XY(), c10 = B(1.0).XY(), c11 = T(1.0).XY(), c01 = T(0.0).XY();
        TopLoc_Location loc;
        Handle(Geom_Surface) surf = BRep_Tool::Surface(face, loc);
        const gp_Trsf trsf = loc.Transformation();
        const double ftol = std::max(BRep_Tool::Tolerance(face), 1e-9);
        std::vector<gp_XY> bottom(size_t(nu) + 1), top(size_t(nu) + 1), left(size_t(nv) + 1), right(size_t(nv) + 1);
        for (int i = 0; i <= nu; ++i) {
            const double s = double(i) / nu;
            bottom[size_t(i)] = B(s).XY();
            top[size_t(i)] = T(s).XY();
        }
        for (int j = 0; j <= nv; ++j) {
            const double t = double(j) / nv;
            left[size_t(j)] = Lf(t).XY();
            right[size_t(j)] = R(t).XY();
        }
        out.positions.reserve(size_t(nu + 1) * size_t(nv + 1) * 3);
        for (int j = 0; j <= nv; ++j) {
            const double t = double(j) / nv;
            for (int i = 0; i <= nu; ++i) {
                const double s = double(i) / nu;
                gp_XY uv;
                if (j == 0) {
                    uv = bottom[size_t(i)];
                }
                else if (j == nv) {
                    uv = top[size_t(i)];
                }
                else if (i == 0) {
                    uv = left[size_t(j)];
                }
                else if (i == nu) {
                    uv = right[size_t(j)];
                }
                else {
                    uv = bottom[size_t(i)] * (1.0 - t) + top[size_t(i)] * t + left[size_t(j)] * (1.0 - s) + right[size_t(j)] * s -
                         (c00 * ((1.0 - s) * (1.0 - t)) + c10 * (s * (1.0 - t)) + c01 * ((1.0 - s) * t) + c11 * (s * t));
                    BRepClass_FaceClassifier cls(face, gp_Pnt2d(uv), ftol);
                    if (cls.State() == TopAbs_OUT) {
                        out.positions.clear();
                        out.error = "This face is too irregular to sample as a grid";
                        return out;
                    }
                }
                const gp_Pnt q = surf->Value(uv.X(), uv.Y()).Transformed(trsf);
                out.positions.push_back(q.X());
                out.positions.push_back(q.Y());
                out.positions.push_back(q.Z());
            }
        }
        out.ok = true;
    }
    catch (const Standard_Failure& failure) {
        out.ok = false;
        out.error = std::string("Face sampling failed: ") + (failure.GetMessageString() ? failure.GetMessageString() : "OCCT error");
    }
    return out;
}

}  // namespace holo_forge::subd
