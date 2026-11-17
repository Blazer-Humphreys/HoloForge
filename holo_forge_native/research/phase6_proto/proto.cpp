// Phase 6 research prototype: OpenSubdiv 3.5 Catmull-Clark -> OCCT B-spline patches.
// Measures: cube limit sphericity, patch boundary gaps per end-cap type/isolation level,
// sewing + solid volume, creases, inverse limit solve, performance.
#include <opensubdiv/version.h>
#include <opensubdiv/far/topologyDescriptor.h>
#include <opensubdiv/far/primvarRefiner.h>
#include <opensubdiv/far/patchTableFactory.h>
#include <opensubdiv/far/patchMap.h>
#include <opensubdiv/far/ptexIndices.h>
#include <opensubdiv/far/stencilTableFactory.h>
#include <opensubdiv/bfr/refinerSurfaceFactory.h>
#include <opensubdiv/bfr/surface.h>
#include <opensubdiv/bfr/tessellation.h>

#include <Geom_BSplineSurface.hxx>
#include <Geom_BezierSurface.hxx>
#include <TColgp_Array2OfPnt.hxx>
#include <TColStd_Array1OfReal.hxx>
#include <TColStd_Array1OfInteger.hxx>
#include <TColGeom_Array2OfBezierSurface.hxx>
#include <GeomConvert_CompBezierSurfacesToBSplineSurface.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepBuilderAPI_Sewing.hxx>
#include <BRepBuilderAPI_MakeSolid.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRepGProp.hxx>
#include <GProp_GProps.hxx>
#include <BRepLib.hxx>
#include <BRep_Tool.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Shell.hxx>
#include <TopoDS_Solid.hxx>
#include <TopExp_Explorer.hxx>
#include <ShapeAnalysis_Surface.hxx>
#include <ShapeFix_Shape.hxx>
#include <Bnd_Box.hxx>
#include <Precision.hxx>
#include <gp_Vec.hxx>

#include <Eigen/Sparse>
#include <Eigen/SparseLU>

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <map>
#include <memory>
#include <string>
#include <tuple>
#include <vector>
#include <algorithm>
#include <array>

using namespace OpenSubdiv;

struct V {
    double x = 0, y = 0, z = 0;
    V() = default;
    V(double a, double b, double c) : x(a), y(b), z(c) {}
    void Clear(void * = 0) { x = y = z = 0; }
    void AddWithWeight(V const &s, double w) { x += w * s.x; y += w * s.y; z += w * s.z; }
    V operator+(V const &o) const { return {x + o.x, y + o.y, z + o.z}; }
    V operator-(V const &o) const { return {x - o.x, y - o.y, z - o.z}; }
    V operator*(double s) const { return {x * s, y * s, z * s}; }
    double len() const { return std::sqrt(x * x + y * y + z * z); }
};
static V cross(V a, V b) { return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}; }
static double dot(V a, V b) { return a.x * b.x + a.y * b.y + a.z * b.z; }

static double now_ms() {
    using namespace std::chrono;
    return duration<double, std::milli>(steady_clock::now().time_since_epoch()).count();
}

// ---------------------------------------------------------------- cage
struct Cage {
    std::vector<V> pts;
    std::vector<int> nv, idx;
    std::vector<int> creasePairs;
    std::vector<float> creaseW;
    std::vector<int> cornerIdx;
    std::vector<float> cornerW;
};

// Cube [-1,1]^3 with k x k quads per side (k=1: the 8-vertex cube cage).
static Cage makeCube(int k) {
    Cage c;
    std::map<std::tuple<int, int, int>, int> ids;
    auto vid = [&](int i, int j, int l) {
        auto key = std::make_tuple(i, j, l);
        auto it = ids.find(key);
        if (it != ids.end()) return it->second;
        int id = (int)c.pts.size();
        c.pts.push_back(V(-1 + 2.0 * i / k, -1 + 2.0 * j / k, -1 + 2.0 * l / k));
        ids[key] = id;
        return id;
    };
    // (axis, sign) -> lattice coordinate from (a,b) so that u x v = outward normal.
    for (int f = 0; f < 6; ++f) {
        for (int b = 0; b < k; ++b)
            for (int a = 0; a < k; ++a) {
                int q[4][2] = {{a, b}, {a + 1, b}, {a + 1, b + 1}, {a, b + 1}};
                c.nv.push_back(4);
                for (int n = 0; n < 4; ++n) {
                    int A = q[n][0], B = q[n][1];
                    int i = 0, j = 0, l = 0;
                    switch (f) {
                        case 0: i = k; j = A; l = B; break;  // +X: u=+Y v=+Z
                        case 1: i = 0; l = A; j = B; break;  // -X: u=+Z v=+Y
                        case 2: j = k; l = A; i = B; break;  // +Y: u=+Z v=+X
                        case 3: j = 0; i = A; l = B; break;  // -Y: u=+X v=+Z
                        case 4: l = k; i = A; j = B; break;  // +Z: u=+X v=+Y
                        case 5: l = 0; j = A; i = B; break;  // -Z: u=+Y v=+X
                    }
                    c.idx.push_back(vid(i, j, l));
                }
            }
    }
    return c;
}

static Far::TopologyRefiner *makeRefiner(Cage const &c, Sdc::Options::CreasingMethod cm = Sdc::Options::CREASE_UNIFORM) {
    Sdc::Options o;
    o.SetVtxBoundaryInterpolation(Sdc::Options::VTX_BOUNDARY_EDGE_AND_CORNER);
    o.SetFVarLinearInterpolation(Sdc::Options::FVAR_LINEAR_CORNERS_ONLY);
    o.SetCreasingMethod(cm);
    o.SetTriangleSubdivision(Sdc::Options::TRI_SUB_SMOOTH);
    Far::TopologyDescriptor d;
    d.numVertices = (int)c.pts.size();
    d.numFaces = (int)c.nv.size();
    d.numVertsPerFace = c.nv.data();
    d.vertIndicesPerFace = c.idx.data();
    d.numCreases = (int)c.creaseW.size();
    d.creaseVertexIndexPairs = c.creasePairs.empty() ? nullptr : c.creasePairs.data();
    d.creaseWeights = c.creaseW.empty() ? nullptr : c.creaseW.data();
    d.numCorners = (int)c.cornerW.size();
    d.cornerVertexIndices = c.cornerIdx.empty() ? nullptr : c.cornerIdx.data();
    d.cornerWeights = c.cornerW.empty() ? nullptr : c.cornerW.data();
    using F = Far::TopologyRefinerFactory<Far::TopologyDescriptor>;
    return F::Create(d, F::Options(Sdc::SCHEME_CATMARK, o));
}

static Far::TopologyRefiner::UniformOptions uopt(int L) { Far::TopologyRefiner::UniformOptions o(L); o.fullTopologyInLastLevel = true; return o; }
// ---------------------------------------------------------------- patch table wrapper
struct PT {
    std::unique_ptr<Far::TopologyRefiner> r;
    std::unique_ptr<Far::PatchTable> t;
    std::unique_ptr<Far::PatchMap> m;
    std::vector<V> verts;
    double ms_build = 0;
};

static std::unique_ptr<PT> buildPT(Cage const &c, Far::PatchTableFactory::Options::EndCapType ec, int L,
                                   bool infSharp = true) {
    auto pt = std::make_unique<PT>();
    double t0 = now_ms();
    pt->r.reset(makeRefiner(c));
    Far::PatchTableFactory::Options po(L);
    po.SetPatchPrecision<double>();
    po.useInfSharpPatch = infSharp;
    po.useSingleCreasePatch = false;
    po.generateVaryingTables = false;
    po.generateLegacySharpCornerPatches = false;
    po.SetEndCapType(ec);
    pt->r->RefineAdaptive(po.GetRefineAdaptiveOptions());
    pt->t.reset(Far::PatchTableFactory::Create(*pt->r, po));
    int nRef = pt->r->GetNumVerticesTotal();
    int nLoc = pt->t->GetNumLocalPoints();
    pt->verts.resize(nRef + nLoc);
    for (size_t i = 0; i < c.pts.size(); ++i) pt->verts[i] = c.pts[i];
    Far::PrimvarRefinerReal<double> pr(*pt->r);
    V *src = pt->verts.data();
    for (int lv = 1; lv < pt->r->GetNumLevels(); ++lv) {
        V *dst = src + pt->r->GetLevel(lv - 1).GetNumVertices();
        pr.Interpolate(lv, src, dst);
        src = dst;
    }
    if (nLoc) pt->t->GetLocalPointStencilTable<double>()->UpdateValues(pt->verts.data(), pt->verts.data() + nRef);
    pt->m = std::make_unique<Far::PatchMap>(*pt->t);
    pt->ms_build = now_ms() - t0;
    return pt;
}

static V evalPT(PT const &pt, int face, double u, double v, V *du = nullptr, V *dv = nullptr) {
    auto h = pt.m->FindPatch(face, u, v);
    double w[20], ws[20], wt[20];
    pt.t->EvaluateBasis<double>(*h, u, v, w, ws, wt);
    auto cvs = pt.t->GetPatchVertices(*h);
    V P, Du, Dv;
    for (int i = 0; i < cvs.size(); ++i) {
        P.AddWithWeight(pt.verts[cvs[i]], w[i]);
        Du.AddWithWeight(pt.verts[cvs[i]], ws[i]);
        Dv.AddWithWeight(pt.verts[cvs[i]], wt[i]);
    }
    if (du) *du = Du;
    if (dv) *dv = Dv;
    return P;
}

// ---------------------------------------------------------------- patch -> OCCT
struct OPatch {
    Handle(Geom_BSplineSurface) s;
    Handle(ShapeAnalysis_Surface) sas;
    Bnd_Box box;
    int face = 0, type = 0, depth = 0;
    double u0 = 0, v0 = 0, frac = 1;
};

static Handle(Geom_BSplineSurface) bezierSurf(V const C[4][4] /*[row t][col s]*/) {
    TColgp_Array2OfPnt poles(1, 4, 1, 4);
    for (int r = 0; r < 4; ++r)
        for (int col = 0; col < 4; ++col) poles(col + 1, r + 1) = gp_Pnt(C[r][col].x, C[r][col].y, C[r][col].z);
    TColStd_Array1OfReal k(1, 2);
    k(1) = 0; k(2) = 1;
    TColStd_Array1OfInteger m(1, 2);
    m(1) = 4; m(2) = 4;
    return new Geom_BSplineSurface(poles, k, k, m, m, 3, 3);
}

// Uniform cubic B-spline span -> Bezier: c = M b
static const double MB2Z[4][4] = {{1 / 6.0, 4 / 6.0, 1 / 6.0, 0},
                                  {0, 4 / 6.0, 2 / 6.0, 0},
                                  {0, 2 / 6.0, 4 / 6.0, 0},
                                  {0, 1 / 6.0, 4 / 6.0, 1 / 6.0}};

static void bsplineToBezier(V B[4][4], V C[4][4]) {
    V T[4][4];
    for (int r = 0; r < 4; ++r)  // along s (columns)
        for (int i = 0; i < 4; ++i) {
            V acc;
            for (int j = 0; j < 4; ++j) acc.AddWithWeight(B[r][j], MB2Z[i][j]);
            T[r][i] = acc;
        }
    for (int col = 0; col < 4; ++col)  // along t (rows)
        for (int i = 0; i < 4; ++i) {
            V acc;
            for (int j = 0; j < 4; ++j) acc.AddWithWeight(T[j][col], MB2Z[i][j]);
            C[i][col] = acc;
        }
}

static std::vector<OPatch> extractPatches(PT const &pt, std::map<int, int> *index = nullptr,
                                          int *nSkipped = nullptr) {
    std::vector<OPatch> out;
    int skipped = 0, absIndex = 0;
    for (int a = 0; a < pt.t->GetNumPatchArrays(); ++a) {
        auto desc = pt.t->GetPatchArrayDescriptor(a);
        for (int p = 0; p < pt.t->GetNumPatches(a); ++p) {
            auto cvs = pt.t->GetPatchVertices(a, p);
            auto pp = pt.t->GetPatchParam(a, p);
            V C[4][4];
            Handle(Geom_BSplineSurface) s;
            if (desc.GetType() == Far::PatchDescriptor::REGULAR) {
                V B[4][4];
                for (int r = 0; r < 4; ++r)
                    for (int col = 0; col < 4; ++col) B[r][col] = pt.verts[cvs[4 * r + col]];
                int bnd = pp.GetBoundary();
                // phantom points (same algebra as OpenSubdiv's adjustBSplineBoundaryWeights)
                if (bnd & 8) for (int r = 0; r < 4; ++r) B[r][0] = B[r][1] * 2 - B[r][2];
                if (bnd & 2) for (int r = 0; r < 4; ++r) B[r][3] = B[r][2] * 2 - B[r][1];
                if (bnd & 1) for (int col = 0; col < 4; ++col) B[0][col] = B[1][col] * 2 - B[2][col];
                if (bnd & 4) for (int col = 0; col < 4; ++col) B[3][col] = B[2][col] * 2 - B[1][col];
                bsplineToBezier(B, C);
                s = bezierSurf(C);
            } else if (desc.GetType() == Far::PatchDescriptor::GREGORY_BASIS) {
                static const int bg[12] = {0, 1, 7, 5, 2, 6, 16, 12, 15, 17, 11, 10};
                static const int bs[12] = {0, 1, 2, 3, 0, 3, 0, 3, 0, 1, 2, 3};
                static const int bt[12] = {0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 3, 3};
                for (int i = 0; i < 12; ++i) C[bt[i]][bs[i]] = pt.verts[cvs[bg[i]]];
                C[1][1] = (pt.verts[cvs[3]] + pt.verts[cvs[4]]) * 0.5;
                C[1][2] = (pt.verts[cvs[8]] + pt.verts[cvs[9]]) * 0.5;
                C[2][2] = (pt.verts[cvs[13]] + pt.verts[cvs[14]]) * 0.5;
                C[2][1] = (pt.verts[cvs[18]] + pt.verts[cvs[19]]) * 0.5;
                s = bezierSurf(C);
            } else if (desc.GetType() == Far::PatchDescriptor::QUADS) {
                V q[4] = {pt.verts[cvs[0]], pt.verts[cvs[1]], pt.verts[cvs[2]], pt.verts[cvs[3]]};
                for (int r = 0; r < 4; ++r)
                    for (int col = 0; col < 4; ++col) {
                        double su = col / 3.0, tv = r / 3.0;
                        C[r][col] = q[0] * ((1 - su) * (1 - tv)) + q[1] * (su * (1 - tv)) + q[2] * (su * tv) +
                                    q[3] * ((1 - su) * tv);
                    }
                s = bezierSurf(C);
            } else {
                ++skipped; { static int once = 0; if (once++ < 3) printf("  [skip patch type %d, ncv %d]\n", (int)desc.GetType(), (int)cvs.size()); }
                ++absIndex;
                continue;
            }
            OPatch op;
            op.s = s;
            op.type = desc.GetType();
            op.face = pp.GetFaceId();
            op.depth = pp.GetDepth();
            op.frac = pp.GetParamFraction();
            op.u0 = pp.GetU() * op.frac;
            op.v0 = pp.GetV() * op.frac;
            for (int r = 0; r < 4; ++r)
                for (int col = 0; col < 4; ++col) op.box.Add(gp_Pnt(C[r][col].x, C[r][col].y, C[r][col].z));
            if (index) (*index)[absIndex] = (int)out.size();
            ++absIndex;
            out.push_back(op);
        }
    }
    if (nSkipped) *nSkipped = skipped;
    return out;
}

struct GapStats {
    double maxGap = 0, meanGap = 0, maxAngleDeg = 0, p99Angle = 0, maxGapRR = 0, maxGapE = 0, maxAngRR = 0;
    int samples = 0;
};

// For every boundary sample of every patch: distance to the nearest other patch, and the normal angle there.
static GapStats measureGaps(std::vector<OPatch> const &P, int K = 9, int GR = 16) {
    GapStats g;
    double sum = 0;
    std::vector<double> angles;
    const double enlarge = 5e-2;
    std::vector<Bnd_Box> boxes(P.size());
    // GR: seed grid resolution (parameter)
    std::vector<std::vector<gp_Pnt>> grids(P.size());
    for (size_t i = 0; i < P.size(); ++i) {
        boxes[i] = P[i].box;
        boxes[i].Enlarge(std::min(enlarge, 0.25 * std::sqrt(P[i].box.SquareExtent())) + 1e-9);
        grids[i].resize((GR + 1) * (GR + 1));
        for (int j = 0; j <= GR; ++j)
            for (int k2 = 0; k2 <= GR; ++k2) grids[i][j * (GR + 1) + k2] = P[i].s->Value((double)k2 / GR, (double)j / GR);
    }
    // closest point on patch b: grid seed + clamped Newton on |S(u,v)-p|^2
    auto project = [&](size_t b, gp_Pnt const &p, double &ou, double &ov) {
        double bd = 1e30;
        int bi = 0;
        for (int i = 0; i < (int)grids[b].size(); ++i) {
            double d = grids[b][i].SquareDistance(p);
            if (d < bd) { bd = d; bi = i; }
        }
        double u = (double)(bi % (GR + 1)) / GR, v = (double)(bi / (GR + 1)) / GR;
        for (int it = 0; it < 30; ++it) {
            gp_Pnt S;
            gp_Vec Su, Sv, Suu, Svv, Suv;
            P[b].s->D2(u, v, S, Su, Sv, Suu, Svv, Suv);
            gp_Vec r(p, S);
            double gu = r.Dot(Su), gv = r.Dot(Sv);
            double huu = Su.Dot(Su) + r.Dot(Suu), hvv = Sv.Dot(Sv) + r.Dot(Svv), huv = Su.Dot(Sv) + r.Dot(Suv);
            double det = huu * hvv - huv * huv;
            double du, dv;
            if (std::fabs(det) < 1e-30) { du = -gu / std::max(huu, 1e-30); dv = -gv / std::max(hvv, 1e-30); }
            else { du = -(hvv * gu - huv * gv) / det; dv = -(huu * gv - huv * gu) / det; }
            double nu = std::clamp(u + du, 0.0, 1.0), nv = std::clamp(v + dv, 0.0, 1.0);
            if (std::fabs(nu - u) < 1e-14 && std::fabs(nv - v) < 1e-14) break;
            u = nu; v = nv;
        }
        ou = u; ov = v;
        return P[b].s->Value(u, v).Distance(p);
    };
    for (size_t a = 0; a < P.size(); ++a) {
        for (int e = 0; e < 4; ++e)
            for (int k = 1; k < K; ++k) {  // skip corners (k=0 and K) - corners are shared by 3+ patches
                double t = (double)k / K;
                double u = 0, v = 0;
                switch (e) {
                    case 0: u = t; v = 0; break;
                    case 1: u = 1; v = t; break;
                    case 2: u = t; v = 1; break;
                    case 3: u = 0; v = t; break;
                }
                gp_Pnt p;
                gp_Vec du, dv;
                P[a].s->D1(u, v, p, du, dv);
                gp_Vec na = du.Crossed(dv);
                double best = 1e30;
                int bestB = -1;
                gp_Pnt2d bestUV;
                for (size_t b = 0; b < P.size(); ++b) {
                    if (b == a || boxes[b].IsOut(p)) continue;
                    double pu, pv;
                    double d = project(b, p, pu, pv);
                    if (d < best) {
                        best = d;
                        bestB = (int)b;
                        bestUV = gp_Pnt2d(pu, pv);
                    }
                }
                if (bestB < 0) continue;
                gp_Pnt q;
                gp_Vec du2, dv2;
                P[bestB].s->D1(bestUV.X(), bestUV.Y(), q, du2, dv2);
                gp_Vec nb = du2.Crossed(dv2);
                double ang = 0;
                if (na.Magnitude() > 1e-14 && nb.Magnitude() > 1e-14) ang = na.Angle(nb) * 180.0 / M_PI;
                angles.push_back(ang);
                g.maxGap = std::max(g.maxGap, best);
                bool rr = P[a].type == Far::PatchDescriptor::REGULAR && P[bestB].type == Far::PatchDescriptor::REGULAR;
                if (rr) { g.maxGapRR = std::max(g.maxGapRR, best); g.maxAngRR = std::max(g.maxAngRR, ang); }
                else g.maxGapE = std::max(g.maxGapE, best);
                sum += best;
                g.samples++;
                g.maxAngleDeg = std::max(g.maxAngleDeg, ang);
            }
    }
    g.meanGap = g.samples ? sum / g.samples : 0;
    if (!angles.empty()) {
        std::sort(angles.begin(), angles.end());
        g.p99Angle = angles[(size_t)(0.99 * (angles.size() - 1))];
    }
    return g;
}

// Deviation of the OCCT patches from the reference limit at identical (face,u,v).
static double measureDeviation(std::vector<OPatch> const &P, PT const &ref, int G = 5, double *meanOut = nullptr) {
    double mx = 0, sum = 0;
    int n = 0;
    for (auto const &op : P) {
        for (int i = 0; i <= G; ++i)
            for (int j = 0; j <= G; ++j) {
                double s = (double)i / G, t = (double)j / G;
                gp_Pnt p = op.s->Value(s, t);
                double u = op.u0 + s * op.frac, v = op.v0 + t * op.frac;
                V r = evalPT(ref, op.face, u, v);
                double d = (V(p.X(), p.Y(), p.Z()) - r).len();
                mx = std::max(mx, d);
                sum += d;
                ++n;
            }
    }
    if (meanOut) *meanOut = sum / std::max(n, 1);
    return mx;
}

struct SewResult {
    int faces = 0, freeEdges = 0, multEdges = 0, shells = 0;
    bool closed = false, valid = false;
    double volume = 0, ms = 0;
};

static bool g_sewCutting = true;
static SewResult sewFaces(std::vector<Handle(Geom_BSplineSurface)> const &S, double tol) {
    SewResult r;
    double t0 = now_ms();
    BRepBuilderAPI_Sewing sew(tol, true, true, g_sewCutting, false);
    for (auto const &s : S) {
        BRepBuilderAPI_MakeFace mf(s, Precision::Confusion());
        if (mf.IsDone()) {
            sew.Add(mf.Face());
            r.faces++;
        }
    }
    sew.Perform();
    TopoDS_Shape sh = sew.SewedShape();
    r.freeEdges = sew.NbFreeEdges();
    r.multEdges = sew.NbMultipleEdges();
    TopoDS_Shell shell;
    for (TopExp_Explorer ex(sh, TopAbs_SHELL); ex.More(); ex.Next()) {
        r.shells++;
        shell = TopoDS::Shell(ex.Current());
    }
    if (r.shells == 1) {
        r.closed = BRep_Tool::IsClosed(shell);
        BRepBuilderAPI_MakeSolid ms(shell);
        if (ms.IsDone()) {
            TopoDS_Solid so = ms.Solid();
            BRepLib::OrientClosedSolid(so);
            r.valid = BRepCheck_Analyzer(so).IsValid();
            GProp_GProps gp;
            BRepGProp::VolumeProperties(so, gp, 1e-9);
            r.volume = gp.Mass();
        }
    }
    r.ms = now_ms() - t0;
    return r;
}

static long long g_mergedPoles = 0;
// Merge per base face: grid of 2^D Bezier cells -> one B-spline surface per cage face.
static std::vector<Handle(Geom_BSplineSurface)> mergePerFace(PT const &pt, std::vector<OPatch> const &P,
                                                             std::map<int, int> const &index,
                                                             int nFaces, int *maxSpans = nullptr, int *failures = nullptr) {
    std::vector<Handle(Geom_BSplineSurface)> out;
    std::vector<int> maxDepth(nFaces, 0);
    for (auto const &op : P) maxDepth[op.face] = std::max(maxDepth[op.face], op.depth);
    int ms = 0, fails = 0;
    for (int f = 0; f < nFaces; ++f) {
        int N = 1 << maxDepth[f];
        ms = std::max(ms, N);
        TColGeom_Array2OfBezierSurface grid(1, N, 1, N);
        bool ok = true;
        for (int i = 0; i < N; ++i)
            for (int j = 0; j < N; ++j) {
                double uc = (i + 0.5) / N, vc = (j + 0.5) / N;
                auto h = pt.m->FindPatch(f, uc, vc);
                auto itk = h ? index.find(h->patchIndex) : index.end();
                if (itk == index.end()) { ok = false; continue; }
                OPatch const &op = P[itk->second];
                double s1 = ((double)i / N - op.u0) / op.frac, s2 = ((double)(i + 1) / N - op.u0) / op.frac;
                double t1 = ((double)j / N - op.v0) / op.frac, t2 = ((double)(j + 1) / N - op.v0) / op.frac;
                Handle(Geom_BSplineSurface) c = Handle(Geom_BSplineSurface)::DownCast(op.s->Copy());
                if (s2 - s1 < 1.0 - 1e-12 || t2 - t1 < 1.0 - 1e-12) c->Segment(s1, s2, t1, t2);
                TColgp_Array2OfPnt poles(1, 4, 1, 4);
                c->Poles(poles);
                grid(i + 1, j + 1) = new Geom_BezierSurface(poles);
            }
        if (!ok) { ++fails; continue; }
        GeomConvert_CompBezierSurfacesToBSplineSurface conv(grid, 1e-9, Standard_False);
        if (!conv.IsDone()) {
            ++fails;
            continue;
        }
        Handle(Geom_BSplineSurface) bs = new Geom_BSplineSurface(conv.Poles()->Array2(), conv.UKnots()->Array1(), conv.VKnots()->Array1(),
                                              conv.UMultiplicities()->Array1(), conv.VMultiplicities()->Array1(),
                                              conv.UDegree(), conv.VDegree());
        // own knot removal: interior knots C0 (mult 3) -> try C2 (mult 1), else C1 (mult 2)
        const double ktol = 1e-9;
        for (int i = bs->NbUKnots() - 1; i >= 2; --i)
            if (!bs->RemoveUKnot(i, 1, ktol)) bs->RemoveUKnot(i, 2, ktol);
        for (int i = bs->NbVKnots() - 1; i >= 2; --i)
            if (!bs->RemoveVKnot(i, 1, ktol)) bs->RemoveVKnot(i, 2, ktol);
        g_mergedPoles += bs->NbUPoles() * bs->NbVPoles();
        out.push_back(bs);
    }
    if (maxSpans) *maxSpans = ms;
    if (failures) *failures = fails;
    return out;
}

// Reference volume from a dense sampling of the reference limit.
static double refVolume(PT const &ref, int nFaces, int G) {
    double vol = 0;
    for (int f = 0; f < nFaces; ++f) {
        std::vector<V> g((G + 1) * (G + 1));
        for (int j = 0; j <= G; ++j)
            for (int i = 0; i <= G; ++i) g[j * (G + 1) + i] = evalPT(ref, f, (double)i / G, (double)j / G);
        for (int j = 0; j < G; ++j)
            for (int i = 0; i < G; ++i) {
                V a = g[j * (G + 1) + i], b = g[j * (G + 1) + i + 1], c = g[(j + 1) * (G + 1) + i + 1],
                  d = g[(j + 1) * (G + 1) + i];
                vol += dot(a, cross(b, c)) / 6.0 + dot(a, cross(c, d)) / 6.0;
            }
    }
    return std::fabs(vol);
}

static const char *ecName(int ec) {
    switch (ec) {
        case Far::PatchTableFactory::Options::ENDCAP_BILINEAR_BASIS: return "BILINEAR";
        case Far::PatchTableFactory::Options::ENDCAP_BSPLINE_BASIS: return "BSPLINE";
        case Far::PatchTableFactory::Options::ENDCAP_GREGORY_BASIS: return "GREGORY";
        case Far::PatchTableFactory::Options::ENDCAP_LEGACY_GREGORY: return "LEGACY_GREGORY";
    }
    return "?";
}

// ================================================================ tests
static void testSphere() {
    printf("\n=== 1. Cube cage (8 verts, 6 quads) Catmull-Clark limit sphericity ===\n");
    Cage cube = makeCube(1);
    auto ref = buildPT(cube, Far::PatchTableFactory::Options::ENDCAP_GREGORY_BASIS, 10);
    auto ref8 = buildPT(cube, Far::PatchTableFactory::Options::ENDCAP_GREGORY_BASIS, 8);
    int G = 128;
    double rmin = 1e9, rmax = 0, rsum = 0, r2sum = 0, dref = 0;
    int n = 0;
    for (int f = 0; f < 6; ++f)
        for (int j = 0; j <= G; ++j)
            for (int i = 0; i <= G; ++i) {
                double u = (double)i / G, v = (double)j / G;
                V p = evalPT(*ref, f, u, v);
                V p8 = evalPT(*ref8, f, u, v);
                dref = std::max(dref, (p - p8).len());
                double r = p.len();
                rmin = std::min(rmin, r);
                rmax = std::max(rmax, r);
                rsum += r;
                r2sum += r * r;
                ++n;
            }
    double mean = rsum / n;
    V fc = evalPT(*ref, 0, 0.5, 0.5), em = evalPT(*ref, 0, 0.5, 0.0), co = evalPT(*ref, 0, 0, 0);
    printf("reference = adaptive Gregory isolation 10 (|L10-L8| max = %.3g)\n", dref);
    printf("radius: min %.6f  max %.6f  mean %.6f  (max-min)/mean = %.3f%%\n", rmin, rmax, mean,
           100 * (rmax - rmin) / mean);
    printf("max |r-mean|/mean = %.3f%%\n", 100 * std::max(rmax - mean, mean - rmin) / mean);
    printf("face-center r %.6f   edge-mid r %.6f   corner r %.6f\n", fc.len(), em.len(), co.len());
    // exact limit points via uniform refinement + PrimvarRefiner::Limit
    std::unique_ptr<Far::TopologyRefiner> r(makeRefiner(cube));
    int L = 6;
    r->RefineUniform(uopt(L));
    std::vector<V> buf(r->GetNumVerticesTotal());
    for (int i = 0; i < 8; ++i) buf[i] = cube.pts[i];
    Far::PrimvarRefinerReal<double> pr(*r);
    V *src = buf.data();
    for (int lv = 1; lv <= L; ++lv) {
        V *dst = src + r->GetLevel(lv - 1).GetNumVertices();
        pr.Interpolate(lv, src, dst);
        src = dst;
    }
    int nl = r->GetLevel(L).GetNumVertices();
    std::vector<V> lim(nl);
    { V *dl = lim.data(); pr.Limit(src, dl); }
    double lmin = 1e9, lmax = 0;
    for (auto &p : lim) {
        lmin = std::min(lmin, p.len());
        lmax = std::max(lmax, p.len());
    }
    printf("uniform L%d PrimvarRefiner::Limit (%d exact limit points): r in [%.6f, %.6f]\n", L, nl, lmin, lmax);
    double vref = refVolume(*ref, 6, 256);
    printf("reference volume (256^2 tris/face) = %.6f ; sphere of mean radius = %.6f\n", vref,
           4.0 / 3.0 * M_PI * mean * mean * mean);
}

static void testEndcaps() {
    printf("\n=== 2. End-cap type x isolation level: patches, gaps, G1, deviation, sewing, volume ===\n");
    Cage cube = makeCube(1);
    auto ref = buildPT(cube, Far::PatchTableFactory::Options::ENDCAP_GREGORY_BASIS, 10);
    double vref = refVolume(*ref, 6, 256);
    printf("reference volume %.6f\n", vref);
    printf("%-9s L  patches reg/end  build_ms | maxGap      meanGap    | maxNormalJump p99   | maxDev     meanDev   | "
           "sew(1e-6): free closed valid vol_err%%  ms | sew(1e-4): free closed vol_err%% | merged: faces spans sew "
           "closed valid vol_err%%\n",
           "endcap");
    int ecs[3] = {Far::PatchTableFactory::Options::ENDCAP_BILINEAR_BASIS,
                  Far::PatchTableFactory::Options::ENDCAP_BSPLINE_BASIS,
                  Far::PatchTableFactory::Options::ENDCAP_GREGORY_BASIS};
    for (int ec : ecs)
        for (int L = 1; L <= 6; ++L) {
            if (ec == Far::PatchTableFactory::Options::ENDCAP_BILINEAR_BASIS && L != 2 && L != 4) continue;
            auto pt = buildPT(cube, (Far::PatchTableFactory::Options::EndCapType)ec, L);
            std::map<int, int> index;
            int skipped = 0;
            auto P = extractPatches(*pt, &index, &skipped);
            int nreg = 0, nend = 0;
            for (auto &p : P) (p.type == Far::PatchDescriptor::REGULAR ? nreg : nend)++;
            fprintf(stderr, "  [L%d built %zu patches]\n", L, (size_t)pt->t->GetNumPatchesTotal()); double T0 = now_ms();
            GapStats g = measureGaps(P);
            double T1 = now_ms(); fprintf(stderr, "  [gaps done]\n");
            double meanDev = 0;
            double maxDev = measureDeviation(P, *ref, 5, &meanDev);
            double T2 = now_ms();
            std::vector<Handle(Geom_BSplineSurface)> S;
            for (auto &p : P) S.push_back(p.s);
            SewResult s6 = sewFaces(S, 1e-6);
            double T3 = now_ms(); fprintf(stderr, "  [sew6 done]\n");
            SewResult s4 = sewFaces(S, 1e-4);
            double T4 = now_ms(); fprintf(stderr, "  [sew4 done]\n");
            int spans = 0, fails = 0;
            auto M = mergePerFace(*pt, P, index, 6, &spans, &fails);
            double T5 = now_ms(); fprintf(stderr, "  [merge done]\n");
            SewResult sm = sewFaces(M, 1e-6);
            double T6 = now_ms();
            fprintf(stderr, "   [timing gaps %.0f dev %.0f sew6 %.0f sew4 %.0f merge %.0f sewM %.0f ms; merged poles total %lld]\n", T1 - T0, T2 - T1, T3 - T2, T4 - T3, T5 - T4, T6 - T5, g_mergedPoles);
            g_mergedPoles = 0;
            printf("%-9s %d  %4d %4d/%-4d %7.1f | %.3e  %.3e (RR %.1e E %.1e) | %8.3f° %7.3f° (RR %.3f°) | %.3e  %.3e | %4d %d %d %8.4f %6.0f | %4d %d "
                   "%8.4f | %d %d %d %d %d %8.4f\n",
                   ecName(ec), L, (int)P.size(), nreg, nend, pt->ms_build, g.maxGap, g.meanGap, g.maxGapRR, g.maxGapE, g.maxAngleDeg,
                   g.p99Angle, g.maxAngRR, maxDev, meanDev, s6.freeEdges, s6.closed, s6.valid, 100 * (s6.volume - vref) / vref,
                   s6.ms, s4.freeEdges, s4.closed, 100 * (s4.volume - vref) / vref, (int)M.size(), spans,
                   sm.freeEdges, sm.closed, sm.valid, 100 * (sm.volume - vref) / vref);
            fflush(stdout);
        }
}

static void testCrease() {
    printf("\n=== 3. Creases (cube cage) ===\n");
    for (int variant = 0; variant < 3; ++variant) {
        Cage cube = makeCube(1);
        // the top (+Z) face is cube face index 4: quad (i,j) lattice -> pick the edge shared by +Z and +X faces
        // vertices on x=+1,z=+1: lattice (1,0,1) and (1,1,1)
        int a = -1, b = -1;
        for (int i = 0; i < 8; ++i) {
            V p = cube.pts[i];
            if (p.x > 0 && p.z > 0 && p.y < 0) a = i;
            if (p.x > 0 && p.z > 0 && p.y > 0) b = i;
        }
        const char *name = "smooth";
        if (variant == 1) {
            cube.creasePairs = {a, b};
            cube.creaseW = {10.0f};
            name = "inf-sharp edge (10)";
        } else if (variant == 2) {
            cube.creasePairs = {a, b};
            cube.creaseW = {2.0f};
            name = "semi-sharp edge (2.0)";
        }
        for (int inf = 0; inf < 2; ++inf) {
            auto pt = buildPT(cube, Far::PatchTableFactory::Options::ENDCAP_GREGORY_BASIS, 4, inf == 1);
            std::map<int, int> index;
            auto P = extractPatches(*pt, &index);
            int nreg = 0, nend = 0, nbnd = 0;
            for (int arr = 0; arr < pt->t->GetNumPatchArrays(); ++arr)
                for (int p = 0; p < pt->t->GetNumPatches(arr); ++p)
                    if (pt->t->GetPatchParam(arr, p).GetBoundary()) nbnd++;
            for (auto &p : P) (p.type == Far::PatchDescriptor::REGULAR ? nreg : nend)++;
            // normal jump across the crease: +Z face (4) at (u=1, v=0.5) vs +X face (0) at its matching param
            // find matching point on face 0 by brute force sampling
            V du, dv;
            V pz = evalPT(*pt, 4, 1.0 - 1e-9, 0.5, &du, &dv);
            V nz = cross(du, dv);
            double best = 1e9, bu = 0, bv = 0;
            for (int i = 0; i <= 400; ++i)
                for (int j = 0; j <= 400; j += 1) {
                    double u = i / 400.0, v = j / 400.0;
                    if (u > 0.02 && u < 0.98 && v > 0.02 && v < 0.98) continue;
                    double d = (evalPT(*pt, 0, u, v) - pz).len();
                    if (d < best) { best = d; bu = u; bv = v; }
                }
            V px = evalPT(*pt, 0, bu, bv, &du, &dv);
            V nx = cross(du, dv);
            double ang = std::acos(std::clamp(dot(nz, nx) / (nz.len() * nx.len()), -1.0, 1.0)) * 180 / M_PI;
            std::vector<Handle(Geom_BSplineSurface)> S;
            for (auto &p : P) S.push_back(p.s);
            GapStats g = measureGaps(P);
            SewResult s6 = sewFaces(S, 1e-6);
            int spans = 0, fails = 0;
            auto M = mergePerFace(*pt, P, index, 6, &spans, &fails);
            SewResult sm = sewFaces(M, 1e-6);
            printf("%-22s useInfSharpPatch=%d: patches %d (reg %d, endcap %d, boundary-masked %d), crease mid normal "
                   "jump %.2f° (match dist %.1e), maxGap %.2e, sew free %d closed %d valid %d vol %.5f | merged %d "
                   "faces spans %d free %d closed %d valid %d vol %.5f\n",
                   name, inf, (int)P.size(), nreg, nend, nbnd, ang, best, g.maxGap, s6.freeEdges, s6.closed,
                   s6.valid, s6.volume, (int)M.size(), spans, sm.freeEdges, sm.closed, sm.valid, sm.volume);
        }
    }
}

// Inverse limit solve: find control points so that vertex limit positions hit targets.
static void testInterpolate() {
    printf("\n=== 4. Interpolate: solve control points so limit(vertex) = target (sphere radius 1) ===\n");
    for (int k : {1, 4, 8, 16, 32}) {
        Cage c = makeCube(k);
        int nV = (int)c.pts.size();
        double t0 = now_ms();
        std::unique_ptr<Far::TopologyRefiner> r(makeRefiner(c));
        Far::PatchTableFactory::Options po(4);
        po.SetPatchPrecision<double>();
        po.useInfSharpPatch = true;
        po.SetEndCapType(Far::PatchTableFactory::Options::ENDCAP_GREGORY_BASIS);
        r->RefineAdaptive(po.GetRefineAdaptiveOptions());
        // one location per vertex: corner of an incident base face (all quads -> ptex = face)
        auto const &l0 = r->GetLevel(0);
        std::vector<double> us(nV), vs(nV);
        Far::LimitStencilTableFactoryReal<double>::LocationArrayVec locs(nV);
        static const double cu[4] = {0, 1, 1, 0}, cv[4] = {0, 0, 1, 1};
        for (int v = 0; v < nV; ++v) {
            auto vf = l0.GetVertexFaces(v);
            int f = vf[0];
            auto fv = l0.GetFaceVertices(f);
            int corner = 0;
            for (int i = 0; i < fv.size(); ++i)
                if (fv[i] == v) corner = i;
            us[v] = cu[corner];
            vs[v] = cv[corner];
            locs[v].ptexIdx = f;
            locs[v].numLocations = 1;
            locs[v].s = &us[v];
            locs[v].t = &vs[v];
        }
        Far::LimitStencilTableFactoryReal<double>::Options lo;
        lo.generate1stDerivatives = false;
        std::unique_ptr<Far::LimitStencilTableReal<double> const> lst(
            Far::LimitStencilTableFactoryReal<double>::Create(*r, locs, nullptr, nullptr, lo));
        double t1 = now_ms();
        std::vector<Eigen::Triplet<double>> trip;
        for (int i = 0; i < lst->GetNumStencils(); ++i) {
            auto st = lst->GetStencil(i);
            for (int j = 0; j < st.GetSize(); ++j)
                if (std::fabs(st.GetWeights()[j]) > 1e-14) trip.emplace_back(i, st.GetVertexIndices()[j], st.GetWeights()[j]);
        }
        Eigen::SparseMatrix<double> A(nV, nV);
        A.setFromTriplets(trip.begin(), trip.end());
        Eigen::MatrixXd Q(nV, 3);
        for (int v = 0; v < nV; ++v) {
            V p = c.pts[v];
            double l = p.len();
            Q(v, 0) = p.x / l; Q(v, 1) = p.y / l; Q(v, 2) = p.z / l;
        }
        Eigen::SparseLU<Eigen::SparseMatrix<double>> lu;
        lu.compute(A);
        Eigen::MatrixXd X = lu.solve(Q);
        double t2 = now_ms();
        // verify with PrimvarRefiner::Limit on a fresh uniform refiner (level 1 limit of base verts = exact)
        std::unique_ptr<Far::TopologyRefiner> r2(makeRefiner(c));
        r2->RefineUniform(uopt(1));
        std::vector<V> buf(r2->GetNumVerticesTotal());
        for (int v = 0; v < nV; ++v) buf[v] = V(X(v, 0), X(v, 1), X(v, 2));
        Far::PrimvarRefinerReal<double> pr(*r2);
        { V *s0 = buf.data(), *d1 = buf.data() + nV; pr.Interpolate(1, s0, d1); }
        std::vector<V> lim(r2->GetLevel(1).GetNumVertices());
        { V *s1 = buf.data() + nV, *dl = lim.data(); pr.Limit(s1, dl); }
        // level-1 vertex ordering (default orderVerticesFromFacesFirst=false): child-of-vertex v has index v
        int nF = r2->GetLevel(0).GetNumFaces(), nE = r2->GetLevel(0).GetNumEdges();
        double maxres = 0;
        for (int v = 0; v < nV; ++v) {
            V tgt(Q(v, 0), Q(v, 1), Q(v, 2));
            maxres = std::max(maxres, (lim[v] - tgt).len());
        }
        // how round is the limit after the solve? sample the limit densely using Bfr
        Bfr::RefinerSurfaceFactory<> fac(*r2.get());
        double rmin = 1e9, rmax = 0;
        std::vector<double> mp(nV * 3);
        for (int v = 0; v < nV; ++v) { mp[3 * v] = X(v, 0); mp[3 * v + 1] = X(v, 1); mp[3 * v + 2] = X(v, 2); }
        Bfr::Surface<double> surf;
        std::vector<double> pp;
        for (int f = 0; f < nF; ++f) {
            if (!fac.InitVertexSurface<double>(f, &surf)) continue;
            pp.resize(surf.GetNumPatchPoints() * 3);
            surf.PreparePatchPoints(mp.data(), Bfr::Surface<double>::PointDescriptor(3), pp.data(), Bfr::Surface<double>::PointDescriptor(3));
            for (int i = 0; i <= 8; ++i)
                for (int j = 0; j <= 8; ++j) {
                    double uv[2] = {i / 8.0, j / 8.0}, P[3];
                    surf.Evaluate(uv, pp.data(), Bfr::Surface<double>::PointDescriptor(3), P);
                    double rr = std::sqrt(P[0] * P[0] + P[1] * P[1] + P[2] * P[2]);
                    rmin = std::min(rmin, rr);
                    rmax = std::max(rmax, rr);
                }
        }
        printf("cage %5d faces %5d verts: stencils %.1f ms, assemble+SparseLU %.1f ms (nnz %d), max |limit-target| "
               "%.2e, limit radius after solve [%.5f, %.5f]\n",
               nF, nV, t1 - t0, t2 - t1, (int)A.nonZeros(), maxres, rmin, rmax);
    }
}

static void testPerf() {
    printf("\n=== 5. Performance (cube cages k x k per side) ===\n");
    printf("faces   verts | refiner | uniform L2: refine+interp+limit (verts) | L3 (verts) | stencil-table L3 build / "
           "apply | adaptive Gregory L3 table (patches) | Bfr tess rate 8 (all faces) | convert: patches->faces+sew "
           "(merged faces) closed valid\n");
    for (int k : {1, 4, 8, 16, 29}) {
        Cage c = makeCube(k);
        int nV = (int)c.pts.size(), nF = (int)c.nv.size();
        double t0 = now_ms();
        std::unique_ptr<Far::TopologyRefiner> r0(makeRefiner(c));
        double tRef = now_ms() - t0;
        double tU[2];
        int nU[2];
        for (int L = 2; L <= 3; ++L) {
            double a = now_ms();
            std::unique_ptr<Far::TopologyRefiner> r(makeRefiner(c));
            r->RefineUniform(uopt(L));
            std::vector<V> buf(r->GetNumVerticesTotal());
            for (int i = 0; i < nV; ++i) buf[i] = c.pts[i];
            Far::PrimvarRefinerReal<double> pr(*r);
            V *src = buf.data();
            for (int lv = 1; lv <= L; ++lv) {
                V *dst = src + r->GetLevel(lv - 1).GetNumVertices();
                pr.Interpolate(lv, src, dst);
                src = dst;
            }
            int nl = r->GetLevel(L).GetNumVertices();
            std::vector<V> lp(nl), t1(nl), t2(nl);
            { V *a1 = lp.data(), *a2 = t1.data(), *a3 = t2.data(); pr.Limit(src, a1, a2, a3); }
            tU[L - 2] = now_ms() - a;
            nU[L - 2] = nl;
        }
        // stencil table (refined L3 vertices) build once, apply per edit
        double a = now_ms();
        std::unique_ptr<Far::TopologyRefiner> r(makeRefiner(c));
        r->RefineUniform(uopt(3));
        Far::StencilTableFactoryReal<double>::Options so;
        so.generateIntermediateLevels = false;
        so.generateOffsets = true;
        std::unique_ptr<Far::StencilTableReal<double> const> st(Far::StencilTableFactoryReal<double>::Create(*r, so));
        double tSt = now_ms() - a;
        std::vector<V> out(st->GetNumStencils());
        a = now_ms();
        for (int rep = 0; rep < 10; ++rep) st->UpdateValues(c.pts.data(), out.data());
        double tApply = (now_ms() - a) / 10;
        // adaptive patch table
        auto pt = buildPT(c, Far::PatchTableFactory::Options::ENDCAP_GREGORY_BASIS, 3);
        // Bfr tessellation
        a = now_ms();
        std::unique_ptr<Far::TopologyRefiner> rb(makeRefiner(c));
        Bfr::RefinerSurfaceFactory<> fac(*rb);
        std::vector<double> mp(nV * 3);
        for (int i = 0; i < nV; ++i) { mp[3 * i] = c.pts[i].x; mp[3 * i + 1] = c.pts[i].y; mp[3 * i + 2] = c.pts[i].z; }
        Bfr::Surface<double> surf;
        std::vector<double> pp, coords, pos, du, dv;
        size_t tessPts = 0;
        for (int f = 0; f < nF; ++f) {
            if (!fac.InitVertexSurface<double>(f, &surf)) continue;
            pp.resize(surf.GetNumPatchPoints() * 3);
            surf.PreparePatchPoints(mp.data(), Bfr::Surface<double>::PointDescriptor(3), pp.data(), Bfr::Surface<double>::PointDescriptor(3));
            Bfr::Tessellation tess(surf.GetParameterization(), 8);
            int n = tess.GetNumCoords();
            coords.resize(n * 2);
            tess.GetCoords(coords.data());
            pos.resize(3); du.resize(3); dv.resize(3);
            for (int i = 0; i < n; ++i) surf.Evaluate(&coords[2 * i], pp.data(), Bfr::Surface<double>::PointDescriptor(3), pos.data(), du.data(), dv.data());
            tessPts += n;
        }
        double tBfr = now_ms() - a;
        // convert (merged per face)
        a = now_ms();
        std::map<int, int> index;
        auto P = extractPatches(*pt, &index);
        int spans = 0, fails = 0;
        auto M = mergePerFace(*pt, P, index, nF, &spans, &fails);
        double tMerge = now_ms() - a;
        SewResult sm = sewFaces(M, 1e-6);
        printf("%5d %6d | %6.2f | %7.1f ms (%7d) | %7.1f ms (%8d) | %7.1f ms / %6.2f ms | %7.1f ms (%6d) | %7.1f ms (%zu "
               "pts) | %7.1f + %8.1f ms (%d) %d %d\n",
               nF, nV, tRef, tU[0], nU[0], tU[1], nU[1], tSt, tApply, pt->ms_build, pt->t->GetNumPatchesTotal(), tBfr,
               tessPts, tMerge, sm.ms, (int)M.size(), sm.closed, sm.valid);
        fflush(stdout);
    }
}

#include "stress.inc"
#include "convert.inc"
#include "shell.inc"
#include <Eigen/Dense>
#include "project.inc"

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    std::string which = argc > 1 ? argv[1] : "all";
    try {
    printf("OpenSubdiv %d\n", OPENSUBDIV_VERSION_NUMBER);
    if (which == "all" || which == "sphere") testSphere();
    if (which == "all" || which == "endcaps") testEndcaps();
    if (which == "all" || which == "crease") testCrease();
    if (which == "all" || which == "interp") testInterpolate();
    if (which == "all" || which == "perf") testPerf();
    if (which == "stress") testStress(argc > 2 ? atoi(argv[2]) : 1);
    if (which == "convert") testConvert(argc > 2 ? atoi(argv[2]) : 1);
    if (which == "shell") testShell(argc > 2 ? atoi(argv[2]) : 1);
    if (which == "project") testProject();
    } catch (Standard_Failure const &e) { printf("OCCT exception: %s\n", e.what()); }
    catch (std::exception const &e) { printf("std exception: %s\n", e.what()); }
    return 0;
}
