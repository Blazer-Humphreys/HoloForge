#include "cad_subd.h"

#include "subd_bvh.h"
#include "subd_convert.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <opensubdiv/bfr/parameterization.h>
#include <opensubdiv/bfr/refinerSurfaceFactory.h>
#include <opensubdiv/bfr/surface.h>
#include <opensubdiv/bfr/tessellation.h>
#include <opensubdiv/far/primvarRefiner.h>
#include <opensubdiv/version.h>

#include <Eigen/Sparse>
#include <Eigen/SparseCholesky>

#include <Standard_Failure.hxx>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <functional>
#include <numeric>
#include <limits>
#include <map>
#include <thread>
#include <unordered_map>

using namespace godot;

namespace holo_forge
{

namespace subd
{

using namespace OpenSubdiv;
using Surf = Bfr::Surface<double>;
using PD = Surf::PointDescriptor;

/// Approximation level of the surfaces used for evaluation, fits and closest points: the
/// patch tree around extraordinary vertices goes this deep (the deepest OpenSubdiv allows), so
/// only a 2^-10 corner region of a face is approximated.
constexpr int PRECISE_LEVEL = 10;
constexpr double kInf = std::numeric_limits<double>::infinity();

struct SurfaceSet
{
    int smooth = -1;
    int sharp = -1;
    uint64_t serial = 0;  // topology serial the surfaces were made for
    std::unique_ptr<Bfr::RefinerSurfaceFactory<>> factory;
    std::vector<Surf> surfaces;
    std::vector<char> valid;
    std::vector<std::vector<double>> pp;  // patch points per face
    uint64_t pp_version = ~0ull;
};

struct Pattern
{
    std::vector<double> coords;  // 2 per point; boundary points first, corner k at k * rate
    std::vector<int> facets;     // 3 per triangle, counter-clockwise in (u, v)
};

struct TessCache
{
    bool valid = false;
    uint64_t serial = 0;
    int rate = 0;
    int approx = 0;
    std::vector<int> face_offset;    // per face + 1: first tess vertex
    std::vector<double> coords;      // 2 per tess vertex (the face's Bfr coordinate)
    std::vector<int> vertex_face;
    std::vector<int> tris;           // 3 per triangle, Godot winding
    std::vector<int> tri_face;
    std::vector<int> seg;            // 2 tess vertices per edge segment
    std::vector<int> seg_edge;
    std::vector<int> vertex_corner;  // per cage vertex: tess vertex at its corner, -1 if unused
    PackedVector2Array g_uvs;
    PackedInt32Array g_indices, g_face_ids, g_vertex_faces, g_edge_ids, g_edge_pairs;
    std::vector<double> P, N;        // 3 per tess vertex
    uint64_t version = ~0ull;
    Bvh bvh;                         // over blocks of up to TESS_BLOCK triangles of one face
    std::vector<int> blocks;         // 2 per block: first triangle, count
    uint64_t bvh_version = ~0ull;
};

/// Triangles per tessellation BVH leaf primitive: a few hundred thousand display triangles build
/// a hierarchy in a few milliseconds (the first pick after an edit doesn't stall).
constexpr int TESS_BLOCK = 8;

struct Patch
{
    int face = 0;
    int sub = -1;  // -1 = the quad itself
};

struct Seeds
{
    uint64_t version = ~0ull;
    std::vector<Patch> patches;
    std::vector<int> face_first;   // per face + 1: first patch
    std::vector<double> P;         // 3 per seed
    std::vector<double> st;        // 2 per seed
    std::vector<int> seed_patch;
    std::vector<double> rho;       // per patch: its longest seed-cell diagonal (every point of the patch lies closer than this to a seed)
    Bvh seed_bvh;
    Bvh face_bvh;
    double margin = 0.0;
};

struct State
{
    CageData cage;
    bool loaded = false;
    uint64_t topo = 0;
    uint64_t serial = 0;   // bumps when the topology changes
    uint64_t version = 0;  // bumps when anything changes
    std::unique_ptr<Far::TopologyRefiner> refiner;   // base level (Bfr)
    std::unique_ptr<Far::TopologyRefiner> uniform1;  // one uniform level (exact vertex limits)
    uint64_t uniform1_serial = 0;
    SurfaceSet tess_set;
    SurfaceSet precise_set;
    std::map<int, Pattern> patterns;
    TessCache tess;
    Bvh cage_bvh;
    std::vector<int> cage_tris;
    std::vector<int> cage_tri_face;
    uint64_t cage_version = ~0ull;
    Seeds seeds;
};

namespace
{

double now_ms()
{
    using namespace std::chrono;
    return duration<double, std::milli>(steady_clock::now().time_since_epoch()).count();
}

template <class F>
void parallel_for(int n, int64_t work, F&& fn)
{
    const unsigned hw = std::thread::hardware_concurrency();
    const int threads = int(std::min<unsigned>(hw == 0 ? 1u : hw, 8u));
    if (work < 40000 || threads <= 1 || n < threads * 2) {
        fn(0, n);
        return;
    }
    std::vector<std::thread> pool;
    const int chunk = (n + threads - 1) / threads;
    for (int i = 0; i < threads; ++i) {
        const int b = i * chunk, e = std::min(n, b + chunk);
        if (b >= e) {
            break;
        }
        pool.emplace_back([&fn, b, e]() { fn(b, e); });
    }
    for (std::thread& t : pool) {
        t.join();
    }
}

inline void cross3(const double* a, const double* b, double* r)
{
    r[0] = a[1] * b[2] - a[2] * b[1];
    r[1] = a[2] * b[0] - a[0] * b[2];
    r[2] = a[0] * b[1] - a[1] * b[0];
}
inline double dot3(const double* a, const double* b)
{
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}
inline double norm3(const double* a)
{
    return std::sqrt(dot3(a, a));
}

bool read_doubles(const Variant& v, std::vector<double>& out)
{
    out.clear();
    switch (v.get_type()) {
        case Variant::NIL:
            return true;
        case Variant::PACKED_FLOAT64_ARRAY: {
            const PackedFloat64Array a = v;
            out.assign(a.ptr(), a.ptr() + a.size());
            return true;
        }
        case Variant::PACKED_FLOAT32_ARRAY: {
            const PackedFloat32Array a = v;
            out.assign(a.ptr(), a.ptr() + a.size());
            return true;
        }
        case Variant::PACKED_INT32_ARRAY: {
            const PackedInt32Array a = v;
            out.assign(a.ptr(), a.ptr() + a.size());
            return true;
        }
        case Variant::ARRAY: {
            const Array a = v;
            out.reserve(size_t(a.size()));
            for (int64_t i = 0; i < a.size(); ++i) {
                out.push_back(double(a[i]));
            }
            return true;
        }
        default:
            return false;
    }
}

bool read_ints(const Variant& v, std::vector<int>& out)
{
    out.clear();
    switch (v.get_type()) {
        case Variant::NIL:
            return true;
        case Variant::PACKED_INT32_ARRAY: {
            const PackedInt32Array a = v;
            out.assign(a.ptr(), a.ptr() + a.size());
            return true;
        }
        case Variant::PACKED_INT64_ARRAY: {
            const PackedInt64Array a = v;
            for (int64_t i = 0; i < a.size(); ++i) {
                out.push_back(int(a[i]));
            }
            return true;
        }
        case Variant::ARRAY: {
            const Array a = v;
            out.reserve(size_t(a.size()));
            for (int64_t i = 0; i < a.size(); ++i) {
                out.push_back(int(a[i]));
            }
            return true;
        }
        default:
            return false;
    }
}

bool read_floats(const Variant& v, std::vector<float>& out)
{
    std::vector<double> d;
    if (!read_doubles(v, d)) {
        return false;
    }
    out.assign(d.begin(), d.end());
    return true;
}

/// Reads the C1 keys of a cage dictionary (no topology checks).
bool parse_cage(const Dictionary& cage, CageData& c, std::string& error)
{
    if (!read_doubles(cage.get("positions", Variant()), c.pos)) {
        error = "Cage positions must be a PackedFloat64Array";
        return false;
    }
    if (!read_ints(cage.get("face_counts", Variant()), c.counts) || !read_ints(cage.get("face_indices", Variant()), c.indices)) {
        error = "Cage faces must be PackedInt32Arrays";
        return false;
    }
    if (!read_ints(cage.get("crease_edges", Variant()), c.crease_pairs) ||
        !read_floats(cage.get("crease_weights", Variant()), c.crease_weights) ||
        !read_ints(cage.get("corners", Variant()), c.corners) ||
        !read_floats(cage.get("corner_weights", Variant()), c.corner_weights)) {
        error = "Cage creases and corners must be packed arrays";
        return false;
    }
    if (c.pos.size() % 3 != 0) {
        error = "Cage positions must hold 3 values per vertex";
        return false;
    }
    c.nV = int(c.pos.size() / 3);
    return true;
}

Bfr::Parameterization param_of(int n)
{
    return Bfr::Parameterization(Sdc::SCHEME_CATMARK, n);
}

}  // namespace

// ---------------------------------------------------------------- cached surfaces

static void ensure_set(State& st, SurfaceSet& set, int smooth, int sharp)
{
    if (set.factory && set.smooth == smooth && set.sharp == sharp && set.serial == st.serial) {
        return;
    }
    Bfr::SurfaceFactory::Options options;
    options.SetApproxLevelSmooth(smooth);
    options.SetApproxLevelSharp(sharp);
    set.factory = std::make_unique<Bfr::RefinerSurfaceFactory<>>(*st.refiner, options);
    const int nF = st.cage.face_count();
    set.surfaces.assign(size_t(nF), Surf());
    set.valid.assign(size_t(nF), 0);
    for (int f = 0; f < nF; ++f) {
        set.valid[size_t(f)] = set.factory->InitVertexSurface<double>(f, &set.surfaces[size_t(f)]) ? 1 : 0;
    }
    set.pp.assign(size_t(nF), std::vector<double>());
    set.pp_version = ~0ull;
    set.smooth = smooth;
    set.sharp = sharp;
    set.serial = st.serial;
}

static void ensure_patch_points(State& st, SurfaceSet& set)
{
    if (set.pp_version == st.version) {
        return;
    }
    const int nF = st.cage.face_count();
    parallel_for(nF, int64_t(nF) * 64, [&](int b, int e) {
        for (int f = b; f < e; ++f) {
            if (!set.valid[size_t(f)]) {
                continue;
            }
            const Surf& s = set.surfaces[size_t(f)];
            std::vector<double>& pp = set.pp[size_t(f)];
            pp.resize(size_t(s.GetNumPatchPoints()) * 3);
            s.PreparePatchPoints(st.cage.pos.data(), PD(3), pp.data(), PD(3));
        }
    });
    set.pp_version = st.version;
}

static SurfaceSet& precise(State& st)
{
    ensure_set(st, st.precise_set, PRECISE_LEVEL, PRECISE_LEVEL);
    ensure_patch_points(st, st.precise_set);
    return st.precise_set;
}

static const Pattern& pattern_for(State& st, int n, int rate)
{
    const int key = n * 4096 + rate;
    auto it = st.patterns.find(key);
    if (it != st.patterns.end()) {
        return it->second;
    }
    Pattern p;
    Bfr::Tessellation tess(param_of(n), rate);
    p.coords.resize(size_t(tess.GetNumCoords()) * 2);
    tess.GetCoords(p.coords.data());
    p.facets.resize(size_t(tess.GetNumFacets()) * 3);
    tess.GetFacets(p.facets.data());
    return st.patterns.emplace(key, std::move(p)).first->second;
}

/// Evaluates position (and first derivatives) on a patch at its normalized coordinate (s, t):
/// a quad's own (u, v), or sub-face k of an n-gon. Derivatives are with respect to (s, t).
static void eval_patch(const SurfaceSet& set, const CageData& c, const Patch& p, double s, double t, double* P, double* Ds,
                       double* Dt, double* Dss = nullptr, double* Dst = nullptr, double* Dtt = nullptr)
{
    const Surf& surf = set.surfaces[size_t(p.face)];
    const double* pp = set.pp[size_t(p.face)].data();
    double uv[2] = {s, t};
    double scale = 1.0;
    if (p.sub >= 0) {
        const double st[2] = {s, t};
        param_of(c.counts[size_t(p.face)]).ConvertNormalizedSubFaceToCoord(p.sub, st, uv);
        scale = 0.5;
    }
    if (Dss) {
        surf.Evaluate(uv, pp, PD(3), P, Ds, Dt, Dss, Dst, Dtt);
        for (int k = 0; k < 3; ++k) {
            Ds[k] *= scale;
            Dt[k] *= scale;
            Dss[k] *= scale * scale;
            Dst[k] *= scale * scale;
            Dtt[k] *= scale * scale;
        }
    }
    else {
        surf.Evaluate(uv, pp, PD(3), P, Ds, Dt);
        for (int k = 0; k < 3; ++k) {
            Ds[k] *= scale;
            Dt[k] *= scale;
        }
    }
}

/// The patch and normalized coordinate of a face's Bfr coordinate.
static Patch patch_of(const CageData& c, int face, const double uv[2], double st[2])
{
    Patch p;
    p.face = face;
    if (c.counts[size_t(face)] == 4) {
        st[0] = uv[0];
        st[1] = uv[1];
        p.sub = -1;
        return p;
    }
    p.sub = param_of(c.counts[size_t(face)]).ConvertCoordToNormalizedSubFace(uv, st);
    return p;
}

static void face_coord(const CageData& c, const Patch& p, double s, double t, double uv[2])
{
    if (p.sub < 0) {
        uv[0] = s;
        uv[1] = t;
        return;
    }
    const double st[2] = {s, t};
    param_of(c.counts[size_t(p.face)]).ConvertNormalizedSubFaceToCoord(p.sub, st, uv);
}

// ---------------------------------------------------------------- tessellation

static void build_tess_pattern(State& st, int rate, int approx)
{
    TessCache& T = st.tess;
    const CageData& c = st.cage;
    const int nF = c.face_count();
    T.face_offset.assign(size_t(nF) + 1, 0);
    for (int f = 0; f < nF; ++f) {
        int count = 0;
        if (st.tess_set.valid[size_t(f)]) {
            count = int(pattern_for(st, c.counts[size_t(f)], rate).coords.size() / 2);
        }
        T.face_offset[size_t(f) + 1] = T.face_offset[size_t(f)] + count;
    }
    const int nT = T.face_offset[size_t(nF)];
    T.coords.resize(size_t(nT) * 2);
    T.vertex_face.resize(size_t(nT));
    T.tris.clear();
    T.tri_face.clear();
    for (int f = 0; f < nF; ++f) {
        if (!st.tess_set.valid[size_t(f)]) {
            continue;
        }
        const Pattern& p = pattern_for(st, c.counts[size_t(f)], rate);
        const int base = T.face_offset[size_t(f)];
        std::copy(p.coords.begin(), p.coords.end(), T.coords.begin() + ptrdiff_t(base) * 2);
        std::fill(T.vertex_face.begin() + base, T.vertex_face.begin() + T.face_offset[size_t(f) + 1], f);
        for (size_t i = 0; i + 2 < p.facets.size(); i += 3) {
            // Bfr facets wind counter-clockwise around the outward normal; Godot front faces are
            // clockwise (as CadShape.tessellate writes them).
            T.tris.push_back(base + p.facets[i]);
            T.tris.push_back(base + p.facets[i + 2]);
            T.tris.push_back(base + p.facets[i + 1]);
            T.tri_face.push_back(f);
        }
    }
    // Limit edge curves: each canonical edge from the first face using it.
    T.seg.clear();
    T.seg_edge.clear();
    for (int e = 0; e < c.edge_count(); ++e) {
        const int f = c.edge_first_face[size_t(e)];
        const int k = c.edge_first_side[size_t(e)];
        if (!st.tess_set.valid[size_t(f)]) {
            continue;
        }
        const int n = c.counts[size_t(f)];
        const int nb = n * rate;
        const int base = T.face_offset[size_t(f)];
        for (int i = 0; i < rate; ++i) {
            T.seg.push_back(base + (k * rate + i) % nb);
            T.seg.push_back(base + (k * rate + i + 1) % nb);
            T.seg_edge.push_back(e);
        }
    }
    T.vertex_corner.assign(size_t(c.nV), -1);
    for (int f = 0; f < nF; ++f) {
        if (!st.tess_set.valid[size_t(f)]) {
            continue;
        }
        const int* fv = &c.indices[size_t(c.offsets[size_t(f)])];
        for (int k = 0; k < c.counts[size_t(f)]; ++k) {
            if (T.vertex_corner[size_t(fv[k])] < 0) {
                T.vertex_corner[size_t(fv[k])] = T.face_offset[size_t(f)] + k * rate;
            }
        }
    }
    T.g_uvs.resize(nT);
    Vector2* uvw = T.g_uvs.ptrw();
    for (int i = 0; i < nT; ++i) {
        uvw[i] = Vector2(real_t(T.coords[size_t(i) * 2]), real_t(T.coords[size_t(i) * 2 + 1]));
    }
    T.g_indices.resize(int64_t(T.tris.size()));
    std::copy(T.tris.begin(), T.tris.end(), T.g_indices.ptrw());
    T.g_face_ids.resize(int64_t(T.tri_face.size()));
    std::copy(T.tri_face.begin(), T.tri_face.end(), T.g_face_ids.ptrw());
    T.g_vertex_faces.resize(nT);
    std::copy(T.vertex_face.begin(), T.vertex_face.end(), T.g_vertex_faces.ptrw());
    T.g_edge_ids.resize(int64_t(T.seg_edge.size()));
    std::copy(T.seg_edge.begin(), T.seg_edge.end(), T.g_edge_ids.ptrw());
    T.g_edge_pairs.resize(int64_t(c.edges.size()));
    std::copy(c.edges.begin(), c.edges.end(), T.g_edge_pairs.ptrw());
    T.rate = rate;
    T.approx = approx;
    T.serial = st.serial;
    T.valid = true;
    T.version = ~0ull;
    T.bvh_version = ~0ull;
}

static void update_tess_positions(State& st)
{
    TessCache& T = st.tess;
    if (T.version == st.version) {
        return;
    }
    const CageData& c = st.cage;
    const SurfaceSet& set = st.tess_set;
    const int nF = c.face_count();
    const int nT = T.face_offset[size_t(nF)];
    T.P.resize(size_t(nT) * 3);
    T.N.resize(size_t(nT) * 3);
    parallel_for(nF, nT, [&](int b, int e) {
        std::vector<double> pp;
        for (int f = b; f < e; ++f) {
            if (!set.valid[size_t(f)]) {
                continue;
            }
            const Surf& s = set.surfaces[size_t(f)];
            pp.resize(size_t(s.GetNumPatchPoints()) * 3);
            s.PreparePatchPoints(c.pos.data(), PD(3), pp.data(), PD(3));
            double centre[2];
            s.GetParameterization().GetCenterCoord(centre);
            for (int i = T.face_offset[size_t(f)]; i < T.face_offset[size_t(f) + 1]; ++i) {
                double* P = &T.P[size_t(i) * 3];
                double* N = &T.N[size_t(i) * 3];
                double du[3], dv[3];
                s.Evaluate(&T.coords[size_t(i) * 2], pp.data(), PD(3), P, du, dv);
                cross3(du, dv, N);
                double len = norm3(N);
                if (!(len > 1e-300)) {
                    // A degenerate point: take the normal a little way toward the face centre.
                    double uv[2], q[3];
                    for (int k = 0; k < 2; ++k) {
                        uv[k] = T.coords[size_t(i) * 2 + size_t(k)] + 1e-4 * (centre[k] - T.coords[size_t(i) * 2 + size_t(k)]);
                    }
                    s.Evaluate(uv, pp.data(), PD(3), q, du, dv);
                    cross3(du, dv, N);
                    len = norm3(N);
                }
                if (len > 1e-300) {
                    N[0] /= len;
                    N[1] /= len;
                    N[2] /= len;
                }
            }
        }
    });
    T.version = st.version;
}

static bool ensure_tess(State& st)
{
    if (!st.tess.valid || st.tess.serial != st.serial) {
        const int nF = std::max(1, st.cage.face_count());
        const int rate = std::clamp(int(std::floor(std::sqrt(150000.0 / nF))), 2, 12);
        ensure_set(st, st.tess_set, 4, 6);
        build_tess_pattern(st, rate, 4);
    }
    else {
        ensure_set(st, st.tess_set, st.tess.approx, std::max(6, st.tess.approx));
    }
    update_tess_positions(st);
    return true;
}

static void ensure_tess_bvh(State& st)
{
    TessCache& T = st.tess;
    if (T.bvh_version == st.version) {
        return;
    }
    T.blocks.clear();
    const int nt = int(T.tri_face.size());
    for (int t = 0; t < nt;) {
        int e = t + 1;
        while (e < nt && e - t < TESS_BLOCK && T.tri_face[size_t(e)] == T.tri_face[size_t(t)]) {
            ++e;
        }
        T.blocks.push_back(t);
        T.blocks.push_back(e - t);
        t = e;
    }
    std::vector<Box> boxes(T.blocks.size() / 2);
    parallel_for(int(boxes.size()), int64_t(nt), [&](int b, int e) {
        for (int i = b; i < e; ++i) {
            const int first = T.blocks[size_t(i) * 2], count = T.blocks[size_t(i) * 2 + 1];
            for (int t = first; t < first + count; ++t) {
                for (int k = 0; k < 3; ++k) {
                    boxes[size_t(i)].add(&T.P[size_t(T.tris[size_t(t) * 3 + size_t(k)]) * 3]);
                }
            }
        }
    });
    T.bvh.build(boxes);
    T.bvh_version = st.version;
}

static void ensure_cage_bvh(State& st)
{
    if (st.cage_version == st.version) {
        return;
    }
    const CageData& c = st.cage;
    st.cage_tris.clear();
    st.cage_tri_face.clear();
    std::vector<Box> boxes;
    for (int f = 0; f < c.face_count(); ++f) {
        const int* fv = &c.indices[size_t(c.offsets[size_t(f)])];
        for (int k = 1; k + 1 < c.counts[size_t(f)]; ++k) {
            const int tri[3] = {fv[0], fv[k], fv[k + 1]};
            Box b;
            for (int v : tri) {
                st.cage_tris.push_back(v);
                b.add(&c.pos[size_t(v) * 3]);
            }
            st.cage_tri_face.push_back(f);
            boxes.push_back(b);
        }
    }
    st.cage_bvh.build(boxes);
    st.cage_version = st.version;
}

static double cage_diagonal(const CageData& c)
{
    Box b;
    for (int v = 0; v < c.nV; ++v) {
        b.add(&c.pos[size_t(v) * 3]);
    }
    if (b.empty()) {
        return 1.0;
    }
    const double d[3] = {b.hi[0] - b.lo[0], b.hi[1] - b.lo[1], b.hi[2] - b.lo[2]};
    return std::max(norm3(d), 1e-12);
}

// ---------------------------------------------------------------- closest points

static void ensure_seeds(State& st)
{
    Seeds& S = st.seeds;
    if (S.version == st.version) {
        return;
    }
    const CageData& c = st.cage;
    SurfaceSet& set = precise(st);
    const int nF = c.face_count();
    S.patches.clear();
    S.face_first.assign(size_t(nF) + 1, 0);
    for (int f = 0; f < nF; ++f) {
        S.face_first[size_t(f)] = int(S.patches.size());
        if (!set.valid[size_t(f)]) {
            continue;
        }
        if (c.counts[size_t(f)] == 4) {
            S.patches.push_back({f, -1});
        }
        else {
            for (int k = 0; k < c.counts[size_t(f)]; ++k) {
                S.patches.push_back({f, k});
            }
        }
    }
    S.face_first[size_t(nF)] = int(S.patches.size());
    constexpr int G = 4;
    const size_t per = size_t(G + 1) * size_t(G + 1);
    S.P.resize(S.patches.size() * per * 3);
    S.st.resize(S.patches.size() * per * 2);
    S.seed_patch.resize(S.patches.size() * per);
    for (size_t pi = 0; pi < S.patches.size(); ++pi) {
        size_t n = pi * per;
        for (int j = 0; j <= G; ++j) {
            for (int i = 0; i <= G; ++i, ++n) {
                const double s = double(i) / G, t = double(j) / G;
                double ds[3], dt[3];
                eval_patch(set, c, S.patches[pi], s, t, &S.P[n * 3], ds, dt);
                S.st[n * 2] = s;
                S.st[n * 2 + 1] = t;
                S.seed_patch[n] = int(pi);
            }
        }
    }
    std::vector<Box> boxes(S.seed_patch.size());
    for (size_t i = 0; i < boxes.size(); ++i) {
        boxes[i].add(&S.P[i * 3]);
    }
    S.seed_bvh.build(boxes);
    S.rho.assign(S.patches.size(), 0.0);
    for (size_t pi = 0; pi < S.patches.size(); ++pi) {
        const size_t base = pi * per;
        for (int j = 0; j < G; ++j) {
            for (int i = 0; i < G; ++i) {
                const double* a = &S.P[(base + size_t(j) * (G + 1) + size_t(i)) * 3];
                const double* b = &S.P[(base + size_t(j + 1) * (G + 1) + size_t(i + 1)) * 3];
                const double* c2 = &S.P[(base + size_t(j) * (G + 1) + size_t(i + 1)) * 3];
                const double* d = &S.P[(base + size_t(j + 1) * (G + 1) + size_t(i)) * 3];
                const double d1[3] = {a[0] - b[0], a[1] - b[1], a[2] - b[2]};
                const double d2[3] = {c2[0] - d[0], c2[1] - d[1], c2[2] - d[2]};
                S.rho[pi] = std::max(S.rho[pi], std::max(norm3(d1), norm3(d2)));
            }
        }
    }
    // Each face's limit surface lies inside the hull of its control points.
    std::vector<Box> fboxes(static_cast<size_t>(nF));
    std::vector<int> idx;
    for (int f = 0; f < nF; ++f) {
        if (!set.valid[size_t(f)]) {
            continue;
        }
        const Surf& s = set.surfaces[size_t(f)];
        idx.resize(size_t(s.GetNumControlPoints()));
        s.GetControlPointIndices(idx.data());
        for (int v : idx) {
            fboxes[size_t(f)].add(&c.pos[size_t(v) * 3]);
        }
    }
    S.margin = 1e-6 * cage_diagonal(c);
    for (Box& b : fboxes) {
        if (!b.empty()) {
            b.expand(S.margin);
        }
    }
    S.face_bvh.build(fboxes);
    S.version = st.version;
}

struct Closest
{
    double d = kInf;
    Patch patch;
    double s = 0.0, t = 0.0;
    double P[3] = {0, 0, 0};
    double N[3] = {0, 0, 0};
};

/// Clamped Newton on |S(s,t) - p|^2 over one patch, from (s, t); Gauss-Newton where the Hessian
/// isn't positive definite; active-set handling at the patch borders.
static Closest newton_closest(const SurfaceSet& set, const CageData& c, const Patch& patch, const double* p, double s, double t)
{
    Closest out;
    out.patch = patch;
    double P[3], Ds[3], Dt[3], Dss[3], Dst[3], Dtt[3];
    auto eval = [&](double a, double b) { eval_patch(set, c, patch, a, b, P, Ds, Dt, Dss, Dst, Dtt); };
    auto dist2 = [&](double a, double b) {
        double q[3], x[3], y[3];
        eval_patch(set, c, patch, a, b, q, x, y);
        const double r[3] = {q[0] - p[0], q[1] - p[1], q[2] - p[2]};
        return dot3(r, r);
    };
    eval(s, t);
    double f = 0.0;
    {
        const double r[3] = {P[0] - p[0], P[1] - p[1], P[2] - p[2]};
        f = dot3(r, r);
    }
    for (int it = 0; it < 60; ++it) {
        const double r[3] = {P[0] - p[0], P[1] - p[1], P[2] - p[2]};
        const double g[2] = {dot3(r, Ds), dot3(r, Dt)};
        double H[2][2] = {{dot3(Ds, Ds) + dot3(r, Dss), dot3(Ds, Dt) + dot3(r, Dst)},
                          {dot3(Ds, Dt) + dot3(r, Dst), dot3(Dt, Dt) + dot3(r, Dtt)}};
        double det = H[0][0] * H[1][1] - H[0][1] * H[1][0];
        if (!(det > 0.0) || !(H[0][0] > 0.0)) {
            H[0][0] = dot3(Ds, Ds);
            H[1][1] = dot3(Dt, Dt);
            H[0][1] = H[1][0] = dot3(Ds, Dt);
            det = H[0][0] * H[1][1] - H[0][1] * H[1][0];
        }
        // Active set: coordinates on a border whose gradient points outward stay there.
        const double x[2] = {s, t};
        bool fixed[2] = {false, false};
        for (int k = 0; k < 2; ++k) {
            if ((x[k] <= 0.0 && g[k] > 0.0) || (x[k] >= 1.0 && g[k] < 0.0)) {
                fixed[k] = true;
            }
        }
        double step[2] = {0.0, 0.0};
        if (!fixed[0] && !fixed[1]) {
            if (std::fabs(det) < 1e-300) {
                break;
            }
            step[0] = -(H[1][1] * g[0] - H[0][1] * g[1]) / det;
            step[1] = -(H[0][0] * g[1] - H[1][0] * g[0]) / det;
        }
        else if (!fixed[0]) {
            step[0] = H[0][0] > 1e-300 ? -g[0] / H[0][0] : 0.0;
        }
        else if (!fixed[1]) {
            step[1] = H[1][1] > 1e-300 ? -g[1] / H[1][1] : 0.0;
        }
        // Damped: halve until the distance drops.
        double ns = s, nt = t, nf = f;
        double lambda = 1.0;
        bool moved = false;
        for (int ls = 0; ls < 30; ++ls) {
            ns = std::clamp(s + lambda * step[0], 0.0, 1.0);
            nt = std::clamp(t + lambda * step[1], 0.0, 1.0);
            nf = dist2(ns, nt);
            if (nf <= f) {
                moved = true;
                break;
            }
            lambda *= 0.5;
        }
        if (!moved) {
            break;
        }
        const double ds = std::fabs(ns - s), dt = std::fabs(nt - t);
        s = ns;
        t = nt;
        f = nf;
        eval(s, t);
        if (ds < 1e-15 && dt < 1e-15) {
            break;
        }
    }
    out.s = s;
    out.t = t;
    out.d = std::sqrt(f);
    out.P[0] = P[0];
    out.P[1] = P[1];
    out.P[2] = P[2];
    cross3(Ds, Dt, out.N);
    const double len = norm3(out.N);
    if (len > 1e-300) {
        for (double& v : out.N) {
            v /= len;
        }
    }
    return out;
}

static Closest closest_point(State& st, const double* p, double max_distance)
{
    Seeds& S = st.seeds;
    const SurfaceSet& set = st.precise_set;
    const CageData& c = st.cage;
    Closest best;
    if (S.seed_bvh.empty()) {
        return best;
    }
    int seed = -1;
    double best2 = kInf;
    S.seed_bvh.nearest(p, best2, [&](int i, double& b2) {
        const double* q = &S.P[size_t(i) * 3];
        const double r[3] = {q[0] - p[0], q[1] - p[1], q[2] - p[2]};
        const double d2 = dot3(r, r);
        if (d2 < b2) {
            b2 = d2;
            seed = i;
        }
    });
    if (seed < 0) {
        return best;
    }
    std::vector<int> tried;
    auto try_patch = [&](int pi) {
        if (std::find(tried.begin(), tried.end(), pi) != tried.end()) {
            return;
        }
        tried.push_back(pi);
        // Nearest seed of the patch.
        constexpr int per = 25;
        int bi = pi * per;
        double bd = kInf;
        for (int k = pi * per; k < (pi + 1) * per; ++k) {
            const double* q = &S.P[size_t(k) * 3];
            const double r[3] = {q[0] - p[0], q[1] - p[1], q[2] - p[2]};
            const double d2 = dot3(r, r);
            if (d2 < bd) {
                bd = d2;
                bi = k;
            }
        }
        // A patch whose nearest seed lies farther than the best distance so far plus its seed
        // spacing holds no closer point.
        if (best.d < kInf && std::sqrt(bd) - S.rho[size_t(pi)] > best.d) {
            return;
        }
        Closest h = newton_closest(set, c, S.patches[size_t(pi)], p, S.st[size_t(bi) * 2], S.st[size_t(bi) * 2 + 1]);
        // Newton started on a patch border can stall there: at a fully creased (sharp) corner the
        // patch's parameter derivatives vanish, so a point on the flat face next to it found the
        // corner (up to 0.07 m off on a box 2,2,2 with a creased top). A corner answer that isn't
        // on the surface is tried again from the patch's nearest interior seed.
        if (h.d > S.margin && (h.s <= 0.0 || h.s >= 1.0) && (h.t <= 0.0 || h.t >= 1.0)) {
            constexpr int G = 4;
            int ii = -1;
            double id = kInf;
            for (int j = 1; j < G; ++j) {
                for (int i = 1; i < G; ++i) {
                    const int k = pi * per + j * (G + 1) + i;
                    const double* q = &S.P[size_t(k) * 3];
                    const double r[3] = {q[0] - p[0], q[1] - p[1], q[2] - p[2]};
                    const double d2 = dot3(r, r);
                    if (d2 < id) {
                        id = d2;
                        ii = k;
                    }
                }
            }
            if (ii >= 0 && ii != bi) {
                const Closest again = newton_closest(set, c, S.patches[size_t(pi)], p, S.st[size_t(ii) * 2], S.st[size_t(ii) * 2 + 1]);
                if (again.d < h.d) {
                    h = again;
                }
            }
        }
        if (h.d < best.d) {
            best = h;
        }
    };
    try_patch(S.seed_patch[size_t(seed)]);
    (void)max_distance;
    double bound = (best.d + S.margin) * (best.d + S.margin);
    S.face_bvh.nearest(p, bound, [&](int f, double& b2) {
        for (int pi = S.face_first[size_t(f)]; pi < S.face_first[size_t(f) + 1]; ++pi) {
            try_patch(pi);
        }
        b2 = (best.d + S.margin) * (best.d + S.margin);
    });
    return best;
}

// ---------------------------------------------------------------- least squares

/// Solves min |A_f x_f - (T - A_x x_x)|^2 + lambda |x_f - x0_f|^2 by regularised normal
/// equations (lambda = regularize * mean squared row norm, never 0), then refines it a few
/// times (each step re-centres the regulariser on the last solution), so well-determined
/// directions converge to the exact solution and singular ones keep their minimal move.
static bool solve_limit_system(int m, int nV, const std::vector<Eigen::Triplet<double>>& trip, const std::vector<double>& T,
                               const std::vector<char>& is_free, const std::vector<double>& x0, double regularize, int iterations,
                               std::vector<double>& out, double& residual, std::string& error)
{
    std::vector<int> col(size_t(nV), -1);
    int nf = 0;
    for (int v = 0; v < nV; ++v) {
        if (is_free[size_t(v)]) {
            col[size_t(v)] = nf++;
        }
    }
    out = x0;
    residual = 0.0;
    if (nf == 0 || m == 0) {
        return true;
    }
    Eigen::MatrixXd b(m, 3);
    for (int r = 0; r < m; ++r) {
        for (int k = 0; k < 3; ++k) {
            b(r, k) = T[size_t(r) * 3 + size_t(k)];
        }
    }
    std::vector<Eigen::Triplet<double>> ft;
    ft.reserve(trip.size());
    for (const auto& tr : trip) {
        const int v = tr.col();
        if (col[size_t(v)] >= 0) {
            ft.emplace_back(tr.row(), col[size_t(v)], tr.value());
        }
        else {
            for (int k = 0; k < 3; ++k) {
                b(tr.row(), k) -= tr.value() * x0[size_t(v) * 3 + size_t(k)];
            }
        }
    }
    Eigen::SparseMatrix<double> A(m, nf);
    A.setFromTriplets(ft.begin(), ft.end());
    double rows = 0.0;
    {
        Eigen::VectorXd norms = Eigen::VectorXd::Zero(m);
        for (int k = 0; k < A.outerSize(); ++k) {
            for (Eigen::SparseMatrix<double>::InnerIterator it(A, k); it; ++it) {
                norms(it.row()) += it.value() * it.value();
            }
        }
        rows = norms.mean();
    }
    const double reg = regularize > 0.0 ? regularize : 1e-8;
    const double lambda = rows > 0.0 ? reg * rows : reg;
    Eigen::SparseMatrix<double> At = A.transpose();
    Eigen::SparseMatrix<double> N = At * A;
    Eigen::SparseMatrix<double> I(nf, nf);
    I.setIdentity();
    N += lambda * I;
    Eigen::SimplicialLDLT<Eigen::SparseMatrix<double>> ldlt(N);
    if (ldlt.info() != Eigen::Success) {
        error = "The fit's normal equations could not be factorised";
        return false;
    }
    Eigen::MatrixXd x(nf, 3);
    for (int v = 0; v < nV; ++v) {
        if (col[size_t(v)] >= 0) {
            for (int k = 0; k < 3; ++k) {
                x(col[size_t(v)], k) = x0[size_t(v) * 3 + size_t(k)];
            }
        }
    }
    const Eigen::MatrixXd Atb = At * b;
    double prev = kInf;
    Eigen::MatrixXd best = x;
    double best_res = kInf;
    for (int it = 0; it < std::max(1, iterations); ++it) {
        Eigen::MatrixXd next = ldlt.solve(Atb + lambda * x);
        if (!next.allFinite()) {
            break;
        }
        const double res = (A * next - b).rowwise().norm().maxCoeff();
        x = next;
        if (res < best_res) {
            best_res = res;
            best = x;
        }
        if (res <= 1e-15 || res > 0.7 * prev) {
            break;
        }
        prev = res;
    }
    if (!(best_res < kInf)) {
        error = "The fit did not give finite positions";
        return false;
    }
    for (int v = 0; v < nV; ++v) {
        if (col[size_t(v)] >= 0) {
            for (int k = 0; k < 3; ++k) {
                out[size_t(v) * 3 + size_t(k)] = best(col[size_t(v)], k);
            }
        }
    }
    residual = best_res;
    return true;
}

/// Adds the limit stencil at a face's Bfr coordinate as row r.
static bool stencil_row(const SurfaceSet& set, int face, const double uv[2], int row, std::vector<Eigen::Triplet<double>>& trip)
{
    if (!set.valid[size_t(face)]) {
        return false;
    }
    const Surf& s = set.surfaces[size_t(face)];
    const int n = s.GetNumControlPoints();
    std::vector<int> idx(static_cast<size_t>(n));
    std::vector<double> w(static_cast<size_t>(n));
    s.GetControlPointIndices(idx.data());
    s.EvaluateStencil(uv, w.data());
    for (int i = 0; i < n; ++i) {
        if (w[size_t(i)] != 0.0) {
            trip.emplace_back(row, idx[size_t(i)], w[size_t(i)]);
        }
    }
    return true;
}

}  // namespace subd

using namespace subd;

// ---------------------------------------------------------------- CadSubD

CadSubD::CadSubD()
    : state(std::make_unique<State>())
{
    install_osd_callbacks();
}

CadSubD::~CadSubD() = default;

void CadSubD::report(const String& error) const
{
    last_error = error;
    last_warning = "";
}

String CadSubD::get_last_error() const
{
    return last_error;
}

String CadSubD::get_last_warning() const
{
    return last_warning;
}

static String gstr(const std::string& s)
{
    return String::utf8(s.c_str());
}

/// A number for messages: two significant digits ("0.023", "2.3e-05").
static String num_text(double x)
{
    char buf[64];
    std::snprintf(buf, sizeof(buf), "%.2g", x);
    return String(buf);
}

/// The first vertex with a non-finite coordinate, or -1.
static int first_non_finite(const double* pos, size_t count)
{
    for (size_t i = 0; i < count; ++i) {
        if (!std::isfinite(pos[i])) {
            return int(i / 3);
        }
    }
    return -1;
}

/// True when uv is a coordinate of the face (quads: [0,1]^2; n-gons: inside one of their
/// sub-face tiles, Bfr QUAD_SUBFACES), within a small tolerance for float32 input.
static bool in_face_domain(const CageData& c, int face, const double uv[2])
{
    constexpr double tol = 1e-6;
    if (!std::isfinite(uv[0]) || !std::isfinite(uv[1])) {
        return false;
    }
    const int n = c.counts[size_t(face)];
    if (n == 4) {
        return uv[0] >= -tol && uv[0] <= 1.0 + tol && uv[1] >= -tol && uv[1] <= 1.0 + tol;
    }
    if (uv[0] < -tol || uv[1] < -tol) {
        return false;
    }
    double st[2];
    const int sub = param_of(n).ConvertCoordToNormalizedSubFace(uv, st);
    return sub >= 0 && sub < n && st[0] >= -tol && st[0] <= 1.0 + tol && st[1] >= -tol && st[1] <= 1.0 + tol;
}

bool CadSubD::set_cage(const Dictionary& cage)
{
    report("");
    try {
        CageData c;
        std::string error;
        if (!parse_cage(cage, c, error)) {
            report(gstr(error));
            return false;
        }
        if (c.nV == 0 || c.counts.empty()) {
            report(c.nV == 0 ? "The cage is empty: it has no vertices" : "The cage has no faces");
            return false;
        }
        const int bad = first_non_finite(c.pos.data(), c.pos.size());
        if (bad >= 0) {
            report(vformat("Vertex %d has a non-finite coordinate", bad));
            return false;
        }
        if (!build_topology(c, error)) {
            report(gstr(error));
            return false;
        }
        String dropped;
        if (c.dropped_creases > 0) {
            dropped = vformat("Ignored %d crease pair(s) that are not cage edges", c.dropped_creases);
        }
        if (c.dropped_corners > 0) {
            dropped += String(dropped.is_empty() ? "" : "; ") + vformat("ignored %d corner index(es) out of range", c.dropped_corners);
        }
        if (c.unpaired_data) {
            dropped += String(dropped.is_empty() ? "" : "; ") + "crease or corner weights don't match their lists";
        }
        const uint64_t key = topology_key(c);
        State& st = *state;
        if (st.loaded && key == st.topo && c.nV == st.cage.nV && c.counts == st.cage.counts && c.indices == st.cage.indices) {
            st.cage.pos = std::move(c.pos);
            st.version++;
            last_warning = dropped;
            return true;
        }
        std::unique_ptr<Far::TopologyRefiner> refiner = make_refiner(c, error);
        if (!refiner) {
            report(gstr(error));
            return false;
        }
        st.cage = std::move(c);
        st.refiner = std::move(refiner);
        st.uniform1.reset();
        st.topo = key;
        st.serial++;
        st.version++;
        st.loaded = true;
        st.tess.valid = false;
        st.tess_set = SurfaceSet();
        st.precise_set = SurfaceSet();
        const std::string warnings = take_osd_warnings();
        last_warning = dropped;
        if (!warnings.empty()) {
            last_warning += String(dropped.is_empty() ? "" : "; ") + gstr(warnings);
        }
        return true;
    }
    catch (const std::exception& e) {
        report(String("Could not load the cage: ") + e.what());
        return false;
    }
}

bool CadSubD::set_positions(const PackedFloat64Array& positions)
{
    report("");
    State& st = *state;
    if (!st.loaded) {
        report("No cage is loaded");
        return false;
    }
    if (positions.size() != int64_t(st.cage.pos.size())) {
        report("set_positions needs 3 values for each of the cage's vertices");
        return false;
    }
    const int bad = first_non_finite(positions.ptr(), size_t(positions.size()));
    if (bad >= 0) {
        report(vformat("Vertex %d has a non-finite coordinate", bad));
        return false;
    }
    std::copy(positions.ptr(), positions.ptr() + positions.size(), st.cage.pos.begin());
    st.version++;
    return true;
}

int CadSubD::get_vertex_count() const
{
    return state->loaded ? state->cage.nV : 0;
}

int CadSubD::get_face_count() const
{
    return state->loaded ? state->cage.face_count() : 0;
}

int CadSubD::get_edge_count() const
{
    return state->loaded ? state->cage.edge_count() : 0;
}

int CadSubD::get_ptex_count() const
{
    return state->loaded ? state->cage.nPtex : 0;
}

String CadSubD::osd_version() const
{
    const int n = OPENSUBDIV_VERSION_NUMBER;
    return vformat("%d.%d.%d", n / 10000, (n / 100) % 100, n % 100);
}

Dictionary CadSubD::tessellate(const Dictionary& options)
{
    report("");
    State& st = *state;
    if (!st.loaded) {
        report("No cage is loaded");
        return Dictionary();
    }
    const CageData& c = st.cage;
    const int nF = std::max(1, c.face_count());
    int rate = int(options.get("rate", 0));
    if (rate <= 0) {
        rate = std::clamp(int(std::floor(std::sqrt(150000.0 / nF))), 2, 12);
    }
    rate = std::min(rate, 128);
    const int approx = std::clamp(int(options.get("approx_level", 4)), 0, 10);
    const bool want_edges = bool(options.get("edges", true));
    std::vector<double> weights;
    read_doubles(options.get("weights", Variant()), weights);
    const bool want_weights = !weights.empty();
    if (want_weights && int(weights.size()) != c.nV) {
        report("tessellate weights need one value per cage vertex");
        return Dictionary();
    }
    ensure_set(st, st.tess_set, approx, std::max(6, approx));
    TessCache& T = st.tess;
    if (!T.valid || T.serial != st.serial || T.rate != rate || T.approx != approx) {
        build_tess_pattern(st, rate, approx);
    }
    update_tess_positions(st);
    const int nT = T.face_offset[size_t(c.face_count())];
    PackedVector3Array positions, normals, edge_points, vertices;
    positions.resize(nT);
    normals.resize(nT);
    Vector3* pw = positions.ptrw();
    Vector3* nw = normals.ptrw();
    for (int i = 0; i < nT; ++i) {
        const double* P = &T.P[size_t(i) * 3];
        const double* N = &T.N[size_t(i) * 3];
        pw[i] = Vector3(real_t(P[0]), real_t(P[1]), real_t(P[2]));
        nw[i] = Vector3(real_t(N[0]), real_t(N[1]), real_t(N[2]));
    }
    if (want_edges) {
        edge_points.resize(int64_t(T.seg.size()));
        Vector3* ew = edge_points.ptrw();
        for (size_t i = 0; i < T.seg.size(); ++i) {
            const double* P = &T.P[size_t(T.seg[i]) * 3];
            ew[i] = Vector3(real_t(P[0]), real_t(P[1]), real_t(P[2]));
        }
    }
    vertices.resize(c.nV);
    Vector3* vw = vertices.ptrw();
    for (int v = 0; v < c.nV; ++v) {
        const int t = T.vertex_corner[size_t(v)];
        const double* P = t >= 0 ? &T.P[size_t(t) * 3] : &c.pos[size_t(v) * 3];
        vw[v] = Vector3(real_t(P[0]), real_t(P[1]), real_t(P[2]));
    }
    Dictionary out;
    out["positions"] = positions;
    out["normals"] = normals;
    out["uvs"] = T.g_uvs;
    out["indices"] = T.g_indices;
    out["face_ids"] = T.g_face_ids;
    out["vertex_faces"] = T.g_vertex_faces;
    out["edge_points"] = edge_points;
    out["edge_ids"] = want_edges ? T.g_edge_ids : PackedInt32Array();
    out["edge_pairs"] = T.g_edge_pairs;
    out["vertices"] = vertices;
    if (want_weights) {
        PackedFloat32Array w;
        w.resize(nT);
        float* ww = w.ptrw();
        const SurfaceSet& set = st.tess_set;
        std::vector<double> wpp;
        for (int f = 0; f < c.face_count(); ++f) {
            if (!set.valid[size_t(f)]) {
                continue;
            }
            const Surf& s = set.surfaces[size_t(f)];
            wpp.resize(size_t(s.GetNumPatchPoints()));
            s.PreparePatchPoints(weights.data(), PD(1), wpp.data(), PD(1));
            for (int i = T.face_offset[size_t(f)]; i < T.face_offset[size_t(f) + 1]; ++i) {
                double value = 0.0;
                s.Evaluate(&T.coords[size_t(i) * 2], wpp.data(), PD(1), &value);
                ww[i] = float(value);
            }
        }
        out["weights"] = w;
    }
    out["rate"] = rate;
    out["approx_level"] = approx;
    return out;
}

Dictionary CadSubD::limit_points()
{
    report("");
    State& st = *state;
    if (!st.loaded) {
        report("No cage is loaded");
        return Dictionary();
    }
    const CageData& c = st.cage;
    std::string error;
    if (!st.uniform1 || st.uniform1_serial != st.serial) {
        st.uniform1 = make_refiner(c, error);
        if (!st.uniform1) {
            report(gstr(error));
            return Dictionary();
        }
        Far::TopologyRefiner::UniformOptions uo(1);
        uo.fullTopologyInLastLevel = true;
        st.uniform1->RefineUniform(uo);
        st.uniform1_serial = st.serial;
    }
    struct V
    {
        double x = 0.0, y = 0.0, z = 0.0;
        void Clear(void* = nullptr) { x = y = z = 0.0; }
        void AddWithWeight(const V& s, double w)
        {
            x += w * s.x;
            y += w * s.y;
            z += w * s.z;
        }
    };
    const int n1 = st.uniform1->GetLevel(1).GetNumVertices();
    std::vector<V> buf(static_cast<size_t>(c.nV) + size_t(n1));
    for (int v = 0; v < c.nV; ++v) {
        buf[size_t(v)] = {c.pos[size_t(v) * 3], c.pos[size_t(v) * 3 + 1], c.pos[size_t(v) * 3 + 2]};
    }
    Far::PrimvarRefinerReal<double> pr(*st.uniform1);
    V* l0 = buf.data();
    V* l1 = buf.data() + c.nV;
    pr.Interpolate(1, l0, l1);
    std::vector<V> lim(static_cast<size_t>(n1));
    V* dst = lim.data();
    pr.Limit(l1, dst);
    // Normals from the limit surface at each vertex's corner of its first face.
    SurfaceSet& set = precise(st);
    std::vector<int> first_face(size_t(c.nV), -1), first_corner(size_t(c.nV), 0);
    for (int f = 0; f < c.face_count(); ++f) {
        for (int k = 0; k < c.counts[size_t(f)]; ++k) {
            const int v = c.indices[size_t(c.offsets[size_t(f)] + k)];
            if (first_face[size_t(v)] < 0) {
                first_face[size_t(v)] = f;
                first_corner[size_t(v)] = k;
            }
        }
    }
    PackedFloat64Array positions;
    PackedVector3Array normals;
    positions.resize(int64_t(c.nV) * 3);
    normals.resize(c.nV);
    double* pw = positions.ptrw();
    Vector3* nw = normals.ptrw();
    // Level-1 vertices are ordered children-of-vertices first: base vertex v's child is v.
    for (int v = 0; v < c.nV; ++v) {
        const int f = first_face[size_t(v)];
        if (f < 0) {
            pw[v * 3] = c.pos[size_t(v) * 3];
            pw[v * 3 + 1] = c.pos[size_t(v) * 3 + 1];
            pw[v * 3 + 2] = c.pos[size_t(v) * 3 + 2];
            nw[v] = Vector3();
            continue;
        }
        pw[v * 3] = lim[size_t(v)].x;
        pw[v * 3 + 1] = lim[size_t(v)].y;
        pw[v * 3 + 2] = lim[size_t(v)].z;
        if (set.valid[size_t(f)]) {
            double uv[2], P[3], du[3], dv[3], n[3];
            set.surfaces[size_t(f)].GetParameterization().GetVertexCoord(first_corner[size_t(v)], uv);
            set.surfaces[size_t(f)].Evaluate(uv, set.pp[size_t(f)].data(), PD(3), P, du, dv);
            cross3(du, dv, n);
            const double len = norm3(n);
            nw[v] = len > 1e-300 ? Vector3(real_t(n[0] / len), real_t(n[1] / len), real_t(n[2] / len)) : Vector3();
        }
    }
    Dictionary out;
    out["positions"] = positions;
    out["normals"] = normals;
    return out;
}

Dictionary CadSubD::evaluate(const PackedInt32Array& faces, const PackedVector2Array& uvs)
{
    report("");
    State& st = *state;
    if (!st.loaded) {
        report("No cage is loaded");
        return Dictionary();
    }
    if (faces.size() != uvs.size()) {
        report("evaluate needs one uv per face index");
        return Dictionary();
    }
    const CageData& c = st.cage;
    SurfaceSet& set = precise(st);
    const int64_t n = faces.size();
    PackedFloat64Array positions;
    PackedVector3Array normals, du, dv;
    positions.resize(n * 3);
    normals.resize(n);
    du.resize(n);
    dv.resize(n);
    double* pw = positions.ptrw();
    for (int64_t i = 0; i < n; ++i) {
        const int f = faces[i];
        if (f < 0 || f >= c.face_count() || !set.valid[size_t(f)]) {
            report(vformat("evaluate: face %d has no limit surface", f));
            return Dictionary();
        }
        const double uv[2] = {double(uvs[i].x), double(uvs[i].y)};
        if (!in_face_domain(c, f, uv)) {
            report(vformat("Face coordinate (%s, %s) is outside face %d", num_text(uv[0]), num_text(uv[1]), f));
            return Dictionary();
        }
        double P[3], Du[3], Dv[3], N[3];
        set.surfaces[size_t(f)].Evaluate(uv, set.pp[size_t(f)].data(), PD(3), P, Du, Dv);
        cross3(Du, Dv, N);
        const double len = norm3(N);
        pw[i * 3] = P[0];
        pw[i * 3 + 1] = P[1];
        pw[i * 3 + 2] = P[2];
        normals.set(i, len > 1e-300 ? Vector3(real_t(N[0] / len), real_t(N[1] / len), real_t(N[2] / len)) : Vector3());
        du.set(i, Vector3(real_t(Du[0]), real_t(Du[1]), real_t(Du[2])));
        dv.set(i, Vector3(real_t(Dv[0]), real_t(Dv[1]), real_t(Dv[2])));
    }
    Dictionary out;
    out["positions"] = positions;
    out["normals"] = normals;
    out["du"] = du;
    out["dv"] = dv;
    return out;
}

Vector2 CadSubD::subface_uv(int face, int subface, double s, double t) const
{
    const State& st = *state;
    if (!st.loaded || face < 0 || face >= st.cage.face_count()) {
        return Vector2();
    }
    const int n = st.cage.counts[size_t(face)];
    if (n == 4) {
        return Vector2(real_t(s), real_t(t));
    }
    const double in[2] = {s, t};
    double uv[2];
    param_of(n).ConvertNormalizedSubFaceToCoord(((subface % n) + n) % n, in, uv);
    return Vector2(real_t(uv[0]), real_t(uv[1]));
}

Dictionary CadSubD::ray_hit(const Vector3& from, const Vector3& dir, int mode, bool refine)
{
    report("");
    Dictionary out;
    out["hit"] = false;
    State& st = *state;
    if (!st.loaded) {
        report("No cage is loaded");
        return out;
    }
    const CageData& c = st.cage;
    double o[3] = {from.x, from.y, from.z};
    double d[3] = {dir.x, dir.y, dir.z};
    const double dl = norm3(d);
    if (!(dl > 0.0)) {
        report("ray_hit needs a direction");
        return out;
    }
    for (double& x : d) {
        x /= dl;
    }
    int best_tri = -1;
    double best_t = kInf, b1 = 0.0, b2 = 0.0;
    if (mode == 1) {
        ensure_cage_bvh(st);
        st.cage_bvh.ray(o, d, kInf, [&](int t, double& tmax) {
            const int* tri = &st.cage_tris[size_t(t) * 3];
            double tt, u, v;
            if (ray_triangle(o, d, &c.pos[size_t(tri[0]) * 3], &c.pos[size_t(tri[1]) * 3], &c.pos[size_t(tri[2]) * 3], 0.0, tmax, tt, u, v)) {
                tmax = tt;
                best_t = tt;
                best_tri = t;
                b1 = u;
                b2 = v;
            }
            return true;
        });
        if (best_tri < 0) {
            return out;
        }
        const int f = st.cage_tri_face[size_t(best_tri)];
        const int* tri = &st.cage_tris[size_t(best_tri) * 3];
        double e1[3], e2[3], n[3];
        for (int k = 0; k < 3; ++k) {
            e1[k] = c.pos[size_t(tri[1]) * 3 + size_t(k)] - c.pos[size_t(tri[0]) * 3 + size_t(k)];
            e2[k] = c.pos[size_t(tri[2]) * 3 + size_t(k)] - c.pos[size_t(tri[0]) * 3 + size_t(k)];
        }
        cross3(e1, e2, n);
        const double len = norm3(n);
        Vector2 uv;
        if (c.counts[size_t(f)] == 4) {
            // Fan triangles (0,1,2) and (0,2,3) of the quad, mapped onto its corners' (u, v).
            const int* fv = &c.indices[size_t(c.offsets[size_t(f)])];
            const bool first = tri[1] == fv[1];
            uv = first ? Vector2(real_t(b1 + b2), real_t(b2)) : Vector2(real_t(b1), real_t(b1 + b2));
        }
        else {
            double centre[2];
            param_of(c.counts[size_t(f)]).GetCenterCoord(centre);
            uv = Vector2(real_t(centre[0]), real_t(centre[1]));
        }
        out["hit"] = true;
        out["face"] = f;
        out["uv"] = uv;
        out["point"] = Vector3(real_t(o[0] + best_t * d[0]), real_t(o[1] + best_t * d[1]), real_t(o[2] + best_t * d[2]));
        out["normal"] = len > 0.0 ? Vector3(real_t(n[0] / len), real_t(n[1] / len), real_t(n[2] / len)) : Vector3();
        out["distance"] = best_t;
        return out;
    }
    ensure_tess(st);
    ensure_tess_bvh(st);
    const TessCache& T = st.tess;
    T.bvh.ray(o, d, kInf, [&](int blk, double& tmax) {
        const int first = T.blocks[size_t(blk) * 2], count = T.blocks[size_t(blk) * 2 + 1];
        for (int t = first; t < first + count; ++t) {
            const int* tri = &T.tris[size_t(t) * 3];
            double tt, u, v;
            if (ray_triangle(o, d, &T.P[size_t(tri[0]) * 3], &T.P[size_t(tri[1]) * 3], &T.P[size_t(tri[2]) * 3], 0.0, tmax, tt, u, v)) {
                tmax = tt;
                best_t = tt;
                best_tri = t;
                b1 = u;
                b2 = v;
            }
        }
        return true;
    });
    if (best_tri < 0) {
        return out;
    }
    const int f = T.tri_face[size_t(best_tri)];
    const int* tri = &T.tris[size_t(best_tri) * 3];
    const double w[3] = {1.0 - b1 - b2, b1, b2};
    double hit[3];
    double nrm[3] = {0, 0, 0};
    double uvo[2];
    for (int k = 0; k < 3; ++k) {
        hit[k] = o[k] + best_t * d[k];
    }
    for (int j = 0; j < 3; ++j) {
        for (int k = 0; k < 3; ++k) {
            nrm[k] += w[j] * T.N[size_t(tri[j]) * 3 + size_t(k)];
        }
    }
    // Start parameters: the nearest triangle corner's patch, its corners' coordinates blended
    // when they share it.
    int near = 0;
    for (int j = 1; j < 3; ++j) {
        if (w[j] > w[near]) {
            near = j;
        }
    }
    double st0[2];
    const Patch patch = patch_of(c, f, &T.coords[size_t(tri[near]) * 2], st0);
    {
        double acc[2] = {0, 0};
        bool same = true;
        for (int j = 0; j < 3; ++j) {
            double sj[2];
            const Patch pj = patch_of(c, f, &T.coords[size_t(tri[j]) * 2], sj);
            if (pj.sub != patch.sub) {
                same = false;
                break;
            }
            acc[0] += w[j] * sj[0];
            acc[1] += w[j] * sj[1];
        }
        if (same) {
            st0[0] = acc[0];
            st0[1] = acc[1];
        }
    }
    face_coord(c, patch, st0[0], st0[1], uvo);
    double dist = best_t;
    int hit_face = f;
    if (refine && precise(st).valid[size_t(f)]) {
        // Newton on S(s, t) = o + lambda d, on the nearest corner's patch first, then on the other
        // corners' (an n-gon triangle can reach across sub-faces).
        SurfaceSet& set = precise(st);
        std::vector<std::pair<Patch, std::array<double, 2>>> tries;
        tries.push_back({patch, {st0[0], st0[1]}});
        for (int j = 0; j < 3; ++j) {
            double sj[2];
            const Patch pj = patch_of(c, f, &T.coords[size_t(tri[j]) * 2], sj);
            bool seen = false;
            for (const auto& tr : tries) {
                seen = seen || tr.first.sub == pj.sub;
            }
            if (!seen) {
                tries.push_back({pj, {sj[0], sj[1]}});
            }
        }
        const double scale = cage_diagonal(c);
        // Newton on S(s, t) - (o + lambda d) = 0 from (s, t, lambda); true when it converged onto
        // the surface in front of the eye.
        auto newton = [&](const Patch& tp, double& s, double& t, double& lambda, double* P, double* Ds, double* Dt) {
            for (int it = 0; it < 30; ++it) {
                eval_patch(set, c, tp, s, t, P, Ds, Dt);
                const double F[3] = {P[0] - o[0] - lambda * d[0], P[1] - o[1] - lambda * d[1], P[2] - o[2] - lambda * d[2]};
                // Solve [Ds Dt -d] x = -F by Cramer's rule.
                const double md[3] = {-d[0], -d[1], -d[2]};
                double cdt[3], c2[3], c3[3];
                cross3(Dt, md, cdt);
                const double det = dot3(Ds, cdt);
                if (std::fabs(det) < 1e-300) {
                    return false;
                }
                const double nF[3] = {-F[0], -F[1], -F[2]};
                double x0 = dot3(nF, cdt) / det;
                cross3(nF, md, c2);
                double x1 = dot3(Ds, c2) / det;
                cross3(Dt, nF, c3);
                double x2 = dot3(Ds, c3) / det;
                // Damped: at most half the patch per step (a coarse start can be far off).
                const double big = std::max(std::fabs(x0), std::fabs(x1));
                if (big > 0.5) {
                    x0 *= 0.5 / big;
                    x1 *= 0.5 / big;
                    x2 *= 0.5 / big;
                }
                s = std::clamp(s + x0, 0.0, 1.0);
                t = std::clamp(t + x1, 0.0, 1.0);
                lambda += x2;
                if (std::fabs(x0) + std::fabs(x1) < 1e-15) {
                    break;
                }
            }
            eval_patch(set, c, tp, s, t, P, Ds, Dt);
            const double F[3] = {P[0] - o[0] - lambda * d[0], P[1] - o[1] - lambda * d[1], P[2] - o[2] - lambda * d[2]};
            return norm3(F) < 1e-9 * scale && lambda > 0.0;
        };
        bool refined = false;
        for (const auto& [tp, start] : tries) {
            double s = start[0], t = start[1], lambda = best_t;
            double P[3], Ds[3], Dt[3];
            if (!newton(tp, s, t, lambda, P, Ds, Dt)) {
                continue;
            }
            double chord = 0.0;
            for (int k = 0; k < 3; ++k) {
                chord = std::max(chord, std::fabs(P[k] - hit[k]));
            }
            if (chord < 0.05 * scale) {
                for (int k = 0; k < 3; ++k) {
                    hit[k] = P[k];
                }
                cross3(Ds, Dt, nrm);
                dist = lambda;
                face_coord(c, tp, s, t, uvo);
                refined = true;
                break;
            }
        }
        // A coarse (drag-rate) tessellation can be far from the surface: start Newton from a grid
        // over each patch of a face and keep the nearest crossing; the hit face first, then (when
        // the coarse triangle lay over a neighbour's part of the surface) the faces next to it.
        auto multi_start = [&](int face, double& best_l) {
            const int nsub = c.counts[size_t(face)] == 4 ? 1 : c.counts[size_t(face)];
            bool found = false;
            for (int sub = 0; sub < nsub; ++sub) {
                Patch tp;
                tp.face = face;
                tp.sub = c.counts[size_t(face)] == 4 ? -1 : sub;
                for (int gi = 0; gi < 3; ++gi) {
                    for (int gj = 0; gj < 3; ++gj) {
                        double s = (gi + 0.5) / 3.0, t = (gj + 0.5) / 3.0, lambda = best_t;
                        double P[3], Ds[3], Dt[3];
                        if (newton(tp, s, t, lambda, P, Ds, Dt) && lambda < best_l) {
                            best_l = lambda;
                            for (int k = 0; k < 3; ++k) {
                                hit[k] = P[k];
                            }
                            cross3(Ds, Dt, nrm);
                            dist = lambda;
                            face_coord(c, tp, s, t, uvo);
                            hit_face = face;
                            found = true;
                        }
                    }
                }
            }
            return found;
        };
        if (!refined) {
            double best_l = kInf;
            refined = multi_start(f, best_l);
            if (!refined) {
                for (int k = 0; k < c.counts[size_t(f)]; ++k) {
                    const int e = c.corner_edge[size_t(c.offsets[size_t(f)] + k)];
                    for (int g = 0; g < c.face_count(); ++g) {
                        if (g == f || !set.valid[size_t(g)]) {
                            continue;
                        }
                        for (int h = c.offsets[size_t(g)]; h < c.offsets[size_t(g) + 1]; ++h) {
                            if (c.corner_edge[size_t(h)] == e) {
                                refined = multi_start(g, best_l) || refined;
                                break;
                            }
                        }
                    }
                }
            }
        }
        out["refined"] = refined;
    }
    const double nl = norm3(nrm);
    out["hit"] = true;
    out["face"] = hit_face;
    out["uv"] = Vector2(real_t(uvo[0]), real_t(uvo[1]));
    out["point"] = Vector3(real_t(hit[0]), real_t(hit[1]), real_t(hit[2]));
    out["normal"] = nl > 0.0 ? Vector3(real_t(nrm[0] / nl), real_t(nrm[1] / nl), real_t(nrm[2] / nl)) : Vector3();
    out["distance"] = dist;
    return out;
}

PackedByteArray CadSubD::visible(const PackedVector3Array& points, const Vector3& eye, const Vector3& view_dir, double tolerance, int mode)
{
    report("");
    PackedByteArray out;
    State& st = *state;
    if (!st.loaded) {
        report("No cage is loaded");
        return out;
    }
    const CageData& c = st.cage;
    const double* verts = nullptr;
    const std::vector<int>* tris = nullptr;
    const Bvh* bvh = nullptr;
    const std::vector<int>* blocks = nullptr;  // tessellation: BVH primitives are triangle blocks
    if (mode == 1) {
        ensure_cage_bvh(st);
        verts = c.pos.data();
        tris = &st.cage_tris;
        bvh = &st.cage_bvh;
    }
    else {
        ensure_tess(st);
        ensure_tess_bvh(st);
        verts = st.tess.P.data();
        tris = &st.tess.tris;
        bvh = &st.tess.bvh;
        blocks = &st.tess.blocks;
    }
    out.resize(points.size());
    uint8_t* ow = out.ptrw();
    const bool ortho = view_dir.length_squared() > 0.0;
    double vd[3] = {view_dir.x, view_dir.y, view_dir.z};
    if (ortho) {
        const double l = norm3(vd);
        for (double& x : vd) {
            x /= l;
        }
    }
    Box all;
    for (int v = 0; v < c.nV; ++v) {
        all.add(&c.pos[size_t(v) * 3]);
    }
    const double centre[3] = {0.5 * (all.lo[0] + all.hi[0]), 0.5 * (all.lo[1] + all.hi[1]), 0.5 * (all.lo[2] + all.hi[2])};
    const double diag = cage_diagonal(c);
    for (int64_t i = 0; i < points.size(); ++i) {
        const double p[3] = {points[i].x, points[i].y, points[i].z};
        double o[3], d[3], len;
        if (ortho) {
            const double r[3] = {p[0] - centre[0], p[1] - centre[1], p[2] - centre[2]};
            len = 2.0 * (diag + norm3(r)) + 1.0;
            for (int k = 0; k < 3; ++k) {
                o[k] = p[k] - vd[k] * len;
                d[k] = vd[k];
            }
        }
        else {
            for (int k = 0; k < 3; ++k) {
                o[k] = eye[k];
                d[k] = p[k] - o[k];
            }
            len = norm3(d);
            if (!(len > 0.0)) {
                ow[i] = 1;
                continue;
            }
            for (double& x : d) {
                x /= len;
            }
        }
        const double limit = len - tolerance;
        bool hidden = false;
        if (limit > 0.0) {
            bvh->ray(o, d, limit, [&](int prim, double&) {
                const int first = blocks ? (*blocks)[size_t(prim) * 2] : prim;
                const int count = blocks ? (*blocks)[size_t(prim) * 2 + 1] : 1;
                for (int t = first; t < first + count; ++t) {
                    const int* tri = &(*tris)[size_t(t) * 3];
                    double tt, u, v;
                    if (ray_triangle(o, d, &verts[size_t(tri[0]) * 3], &verts[size_t(tri[1]) * 3], &verts[size_t(tri[2]) * 3], 0.0, limit, tt, u, v)) {
                        hidden = true;
                        return false;
                    }
                }
                return true;
            });
        }
        ow[i] = hidden ? 0 : 1;
    }
    return out;
}

Dictionary CadSubD::closest_points(const PackedVector3Array& points, double max_distance)
{
    report("");
    State& st = *state;
    if (!st.loaded) {
        report("No cage is loaded");
        return Dictionary();
    }
    const CageData& c = st.cage;
    precise(st);
    ensure_seeds(st);
    const int64_t n = points.size();
    PackedFloat64Array positions, distances, uvs_d;
    PackedVector3Array normals;
    PackedInt32Array faces;
    PackedVector2Array uvs;
    positions.resize(n * 3);
    distances.resize(n);
    uvs_d.resize(n * 2);
    normals.resize(n);
    faces.resize(n);
    uvs.resize(n);
    double* pw = positions.ptrw();
    double* dw = distances.ptrw();
    double* uw = uvs_d.ptrw();
    for (int64_t i = 0; i < n; ++i) {
        const double p[3] = {points[i].x, points[i].y, points[i].z};
        const Closest h = closest_point(st, p, max_distance);
        if (!(h.d <= max_distance)) {
            pw[i * 3] = p[0];
            pw[i * 3 + 1] = p[1];
            pw[i * 3 + 2] = p[2];
            dw[i] = kInf;
            faces.set(i, -1);
            normals.set(i, Vector3());
            uvs.set(i, Vector2());
            uw[i * 2] = 0.0;
            uw[i * 2 + 1] = 0.0;
            continue;
        }
        double uv[2];
        face_coord(c, h.patch, h.s, h.t, uv);
        pw[i * 3] = h.P[0];
        pw[i * 3 + 1] = h.P[1];
        pw[i * 3 + 2] = h.P[2];
        dw[i] = h.d;
        faces.set(i, h.patch.face);
        normals.set(i, Vector3(real_t(h.N[0]), real_t(h.N[1]), real_t(h.N[2])));
        uvs.set(i, Vector2(real_t(uv[0]), real_t(uv[1])));
        uw[i * 2] = uv[0];
        uw[i * 2 + 1] = uv[1];
    }
    Dictionary out;
    out["positions"] = positions;
    out["normals"] = normals;
    out["faces"] = faces;
    out["uvs"] = uvs;
    out["uvs_d"] = uvs_d;
    out["distances"] = distances;
    return out;
}

PackedFloat64Array CadSubD::interpolate(const PackedFloat64Array& targets, const PackedInt32Array& free, double regularize)
{
    report("");
    State& st = *state;
    if (!st.loaded) {
        report("No cage is loaded");
        return PackedFloat64Array();
    }
    const CageData& c = st.cage;
    if (targets.size() != int64_t(c.pos.size())) {
        report("interpolate needs 3 target values per cage vertex");
        return PackedFloat64Array();
    }
    if (first_non_finite(targets.ptr(), size_t(targets.size())) >= 0) {
        report("interpolate: a target is not a finite number");
        return PackedFloat64Array();
    }
    SurfaceSet& set = precise(st);
    std::vector<char> is_free(size_t(c.nV), free.is_empty() ? 1 : 0);
    for (int64_t i = 0; i < free.size(); ++i) {
        if (free[i] < 0 || free[i] >= c.nV) {
            report(vformat("interpolate: vertex %d is out of range", free[i]));
            return PackedFloat64Array();
        }
        is_free[size_t(free[i])] = 1;
    }
    std::vector<int> first_face(size_t(c.nV), -1), first_corner(size_t(c.nV), 0);
    for (int f = 0; f < c.face_count(); ++f) {
        for (int k = 0; k < c.counts[size_t(f)]; ++k) {
            const int v = c.indices[size_t(c.offsets[size_t(f)] + k)];
            if (first_face[size_t(v)] < 0 && set.valid[size_t(f)]) {
                first_face[size_t(v)] = f;
                first_corner[size_t(v)] = k;
            }
        }
    }
    std::vector<Eigen::Triplet<double>> trip;
    std::vector<double> T;
    int m = 0;
    for (int v = 0; v < c.nV; ++v) {
        if (!is_free[size_t(v)]) {
            continue;
        }
        const int f = first_face[size_t(v)];
        if (f < 0) {
            trip.emplace_back(m, v, 1.0);
        }
        else {
            double uv[2];
            set.surfaces[size_t(f)].GetParameterization().GetVertexCoord(first_corner[size_t(v)], uv);
            stencil_row(set, f, uv, m, trip);
        }
        for (int k = 0; k < 3; ++k) {
            T.push_back(targets[int64_t(v) * 3 + k]);
        }
        ++m;
    }
    std::vector<double> result;
    double residual = 0.0;
    std::string error;
    if (!solve_limit_system(m, c.nV, trip, T, is_free, c.pos, regularize, 30, result, residual, error)) {
        report(gstr(error));
        return PackedFloat64Array();
    }
    const double diag = cage_diagonal(c);
    if (residual > 1e-9 * diag) {
        last_warning = "The limit misses its targets by up to " + num_text(residual) + " m (the cage may be singular here)";
    }
    PackedFloat64Array out;
    out.resize(int64_t(result.size()));
    std::copy(result.begin(), result.end(), out.ptrw());
    return out;
}

PackedFloat64Array CadSubD::fit(const PackedInt32Array& faces, const PackedVector2Array& uvs, const PackedFloat64Array& targets,
                                const PackedInt32Array& free, double regularize)
{
    report("");
    State& st = *state;
    if (!st.loaded) {
        report("No cage is loaded");
        return PackedFloat64Array();
    }
    const CageData& c = st.cage;
    if (faces.size() != uvs.size() || targets.size() != faces.size() * 3) {
        report("fit needs one uv and three target values per location");
        return PackedFloat64Array();
    }
    if (first_non_finite(targets.ptr(), size_t(targets.size())) >= 0) {
        report("fit: a target is not a finite number");
        return PackedFloat64Array();
    }
    SurfaceSet& set = precise(st);
    std::vector<char> is_free(size_t(c.nV), free.is_empty() ? 1 : 0);
    for (int64_t i = 0; i < free.size(); ++i) {
        if (free[i] < 0 || free[i] >= c.nV) {
            report(vformat("fit: vertex %d is out of range", free[i]));
            return PackedFloat64Array();
        }
        is_free[size_t(free[i])] = 1;
    }
    std::vector<Eigen::Triplet<double>> trip;
    std::vector<double> T(static_cast<size_t>(targets.size()));
    std::copy(targets.ptr(), targets.ptr() + targets.size(), T.begin());
    for (int64_t i = 0; i < faces.size(); ++i) {
        const int f = faces[i];
        const double uv[2] = {double(uvs[i].x), double(uvs[i].y)};
        if (f < 0 || f >= c.face_count() || !set.valid[size_t(f)]) {
            report(vformat("fit: face %d has no limit surface", f));
            return PackedFloat64Array();
        }
        if (!in_face_domain(c, f, uv)) {
            report(vformat("Face coordinate (%s, %s) is outside face %d", num_text(uv[0]), num_text(uv[1]), f));
            return PackedFloat64Array();
        }
        if (!stencil_row(set, f, uv, int(i), trip)) {
            report(vformat("fit: face %d has no limit surface", f));
            return PackedFloat64Array();
        }
    }
    std::vector<double> result;
    double residual = 0.0;
    std::string error;
    if (!solve_limit_system(int(faces.size()), c.nV, trip, T, is_free, c.pos, regularize, 30, result, residual, error)) {
        report(gstr(error));
        return PackedFloat64Array();
    }
    last_warning = "";
    if (residual > 1e-9 * cage_diagonal(c)) {
        last_warning = "The fit misses its targets by up to " + num_text(residual) + " m";
    }
    PackedFloat64Array out;
    out.resize(int64_t(result.size()));
    std::copy(result.begin(), result.end(), out.ptrw());
    return out;
}

static Dictionary check_data(const CageData& c, bool self_intersections);

Array CadSubD::to_shapes(const Dictionary& params)
{
    report("");
    last_report = Dictionary();
    Array shapes;
    State& st = *state;
    if (!st.loaded) {
        report("No cage is loaded");
        return shapes;
    }
    ConvertParams p;
    p.isolation = std::clamp(int(params.get("isolation", 6)), 1, 10);
    p.prefix = String(params.get("name_prefix", "")).utf8().get_data();
    p.tolerance = double(params.get("tolerance", 1e-7));
    p.check = bool(params.get("check", true));
    // Above the largest normal jump measured where end caps meet their neighbours (0.52 deg at
    // isolation 4 next to a valence-16 vertex; 0.48 deg at 6), so smooth seams count as smooth.
    p.regularity = double(params.get("regularity", 1.75e-2));
    p.force_sewing = bool(params.get("force_sewing", false));
    ConvertResult result;
    std::string error;
    const double t0 = now_ms();
    if (!convert(st.cage, p, result, error)) {
        report(gstr(error));
        return shapes;
    }
    Array components;
    PackedStringArray warnings;
    for (const std::string& w : result.warnings) {
        warnings.push_back(gstr(w));
    }
    const double diag = cage_diagonal(st.cage);
    for (const ConvertComponent& comp : result.components) {
        if (comp.faces == 0 || comp.shape.IsNull()) {
            report("The conversion made a component without faces (the cage is degenerate); try Repair Body");
            last_report = Dictionary();
            return Array();
        }
        if (comp.closed && comp.volume < 1e-6 * diag * diag * diag) {
            warnings.push_back("A closed part of the body encloses almost no volume (" + num_text(comp.volume) + " m3); its cage is flat or folded");
        }
        Ref<CadShape> shape = CadShape::wrap(comp.shape);
        PackedStringArray names;
        for (const std::string& n : comp.face_names) {
            names.push_back(gstr(n));
        }
        shape->set_face_names(names);
        shape->name_edges_from_faces();
        shapes.push_back(shape);
        Dictionary d;
        d["faces"] = comp.faces;
        d["closed"] = comp.closed;
        d["solid"] = comp.solid;
        d["valid"] = comp.valid;
        d["method"] = comp.sewn ? "sewing" : "direct";
        d["free_edges"] = comp.free_edges;
        // Integrated over the bicubic patches the faces are made of (exact for the volume).
        d["volume"] = comp.volume;
        d["area"] = comp.area;
        components.push_back(d);
    }
    // Self-intersecting, degenerate (no area) faces and pinched vertices are reported, not fixed.
    PackedInt32Array problem;
    const Dictionary check = check_data(st.cage, true);
    const PackedInt32Array crossing = check.get("self_intersecting_faces", PackedInt32Array());
    const PackedInt32Array degenerate = check.get("degenerate_faces", PackedInt32Array());
    const PackedInt32Array pinched = check.get("non_manifold_vertices", PackedInt32Array());
    if (!degenerate.is_empty()) {
        warnings.push_back(vformat("%d face(s) have no area (degenerate cage faces)", degenerate.size()));
    }
    if (!crossing.is_empty()) {
        warnings.push_back(vformat("%d faces self-intersect", crossing.size()));
    }
    if (!pinched.is_empty()) {
        warnings.push_back(vformat("%d vertex(es) pinch separate fans of faces together (non-manifold)", pinched.size()));
    }
    {
        std::vector<int> all;
        for (int64_t i = 0; i < degenerate.size(); ++i) {
            all.push_back(degenerate[i]);
        }
        for (int64_t i = 0; i < crossing.size(); ++i) {
            all.push_back(crossing[i]);
        }
        std::sort(all.begin(), all.end());
        all.erase(std::unique(all.begin(), all.end()), all.end());
        for (int f : all) {
            problem.push_back(f);
        }
    }
    Dictionary rep;
    rep["components"] = components;
    rep["problem_faces"] = problem;
    rep["warnings"] = warnings;
    rep["ms"] = now_ms() - t0;
    rep["ms_patches"] = result.ms_patches;
    rep["ms_merge"] = result.ms_merge;
    rep["ms_shell"] = result.ms_shell;
    rep["ms_check"] = result.ms_check;
    rep["ms_regularity"] = result.ms_regularity;
    rep["ms_props"] = result.ms_props;
    rep["ms_convert"] = result.ms;
    rep["c1_adjust"] = result.c1_adjust;
    rep["c0_knots"] = result.c0_knots;
    last_report = rep;
    if (!warnings.is_empty()) {
        last_warning = warnings[0];
    }
    return shapes;
}

Dictionary CadSubD::get_last_report() const
{
    return last_report;
}

Dictionary CadSubD::check_cage(const Dictionary& cage, bool self_intersections) const
{
    // Works on the given dictionary only: the loaded cage is left alone.
    CageData c;
    std::string error;
    if (!parse_cage(cage, c, error)) {
        PackedStringArray errors;
        errors.push_back(gstr(error));
        Dictionary out;
        out["ok"] = false;
        out["errors"] = errors;
        out["non_manifold_edges"] = PackedInt32Array();
        out["flipped_faces"] = PackedInt32Array();
        out["degenerate_faces"] = PackedInt32Array();
        out["self_intersecting_faces"] = PackedInt32Array();
        return out;
    }
    return check_data(c, self_intersections);
}

static Dictionary check_data(const CageData& c, bool self_intersections)
{
    PackedStringArray errors;
    PackedInt32Array non_manifold, flipped, degenerate, crossing;
    Dictionary out;
    const int nF = int(c.counts.size());
    std::vector<int> offsets(size_t(nF) + 1, 0);
    bool sizes_ok = true;
    for (int f = 0; f < nF; ++f) {
        offsets[size_t(f) + 1] = offsets[size_t(f)] + std::max(0, c.counts[size_t(f)]);
    }
    if (size_t(offsets[size_t(nF)]) != c.indices.size()) {
        errors.push_back("face_counts and face_indices disagree in size");
        sizes_ok = false;
    }
    std::vector<char> bad_face(size_t(nF), 0);
    const double cage_diag = c.nV > 0 && c.pos.size() == size_t(c.nV) * 3 ? cage_diagonal(c) : 1.0;
    PackedInt32Array non_finite, pinched;
    if (c.nV == 0 || nF == 0) {
        errors.push_back(c.nV == 0 ? "The cage is empty: it has no vertices" : "The cage has no faces");
    }
    std::vector<char> bad_vertex(size_t(c.nV), 0);
    for (int v = 0; v < c.nV && size_t(v) * 3 + 2 < c.pos.size(); ++v) {
        if (!std::isfinite(c.pos[size_t(v) * 3]) || !std::isfinite(c.pos[size_t(v) * 3 + 1]) || !std::isfinite(c.pos[size_t(v) * 3 + 2])) {
            non_finite.push_back(v);
            bad_vertex[size_t(v)] = 1;
        }
    }
    if (!non_finite.is_empty()) {
        errors.push_back(vformat("Vertex %d has a non-finite coordinate", non_finite[0]) +
                         (non_finite.size() > 1 ? vformat(" (%d vertices in all)", non_finite.size()) : String()));
    }
    // Crease and corner data (C1): pairs are cage edges, one weight per pair or corner.
    if (c.crease_pairs.size() % 2 != 0 || c.crease_pairs.size() != c.crease_weights.size() * 2) {
        errors.push_back(vformat("Crease data is unpaired: %d vertex index(es) and %d weight(s)", int(c.crease_pairs.size()), int(c.crease_weights.size())));
    }
    if (c.corners.size() != c.corner_weights.size()) {
        errors.push_back(vformat("Corner data is unpaired: %d corner(s) and %d weight(s)", int(c.corners.size()), int(c.corner_weights.size())));
    }
    for (size_t i = 0; i < c.corners.size(); ++i) {
        if (c.corners[i] < 0 || c.corners[i] >= c.nV) {
            errors.push_back(vformat("Corner vertex %d is out of range", c.corners[i]));
            break;
        }
    }
    if (sizes_ok) {
        for (int f = 0; f < nF; ++f) {
            const int n = c.counts[size_t(f)];
            const int* fv = &c.indices[size_t(offsets[size_t(f)])];
            bool range = n >= 3;
            for (int k = 0; k < n; ++k) {
                if (fv[k] < 0 || fv[k] >= c.nV) {
                    range = false;
                }
            }
            if (!range) {
                errors.push_back(vformat("Face %d has an index out of range or fewer than 3 vertices", f));
                bad_face[size_t(f)] = 1;
                degenerate.push_back(f);
                continue;
            }
            bool finite = true;
            for (int k = 0; k < n; ++k) {
                finite = finite && !bad_vertex[size_t(fv[k])];
            }
            if (!finite) {
                bad_face[size_t(f)] = 1;
                degenerate.push_back(f);
                continue;
            }
            int distinct = 0;
            for (int i = 0; i < n; ++i) {
                bool dup = false;
                for (int j = 0; j < i; ++j) {
                    dup = dup || fv[j] == fv[i];
                }
                distinct += dup ? 0 : 1;
            }
            // Area by the Newell normal.
            double nrm[3] = {0, 0, 0};
            for (int i = 0; i < n; ++i) {
                const double* a = &c.pos[size_t(fv[i]) * 3];
                const double* b = &c.pos[size_t(fv[(i + 1) % n]) * 3];
                nrm[0] += (a[1] - b[1]) * (a[2] + b[2]);
                nrm[1] += (a[2] - b[2]) * (a[0] + b[0]);
                nrm[2] += (a[0] - b[0]) * (a[1] + b[1]);
            }
            const double area = 0.5 * norm3(nrm);
            if (distinct < 3 || area < 1e-12 * cage_diag * cage_diag) {
                errors.push_back(vformat("Face %d is degenerate", f));
                bad_face[size_t(f)] = 1;
                degenerate.push_back(f);
            }
        }
        // Edges: faces per edge and the directions they use it in.
        struct Use
        {
            int face;
            bool forward;
            int corner;  // face corner (offsets[face] + k) where the edge starts
        };
        std::unordered_map<uint64_t, std::vector<Use>> uses;
        std::vector<uint64_t> order;
        for (int f = 0; f < nF; ++f) {
            if (bad_face[size_t(f)]) {
                continue;
            }
            const int n = c.counts[size_t(f)];
            const int* fv = &c.indices[size_t(offsets[size_t(f)])];
            for (int k = 0; k < n; ++k) {
                const int a = fv[k], b = fv[(k + 1) % n];
                const uint64_t key = (uint64_t(uint32_t(std::min(a, b))) << 32) | uint64_t(uint32_t(std::max(a, b)));
                auto& list = uses[key];
                if (list.empty()) {
                    order.push_back(key);
                }
                list.push_back({f, a < b, offsets[size_t(f)] + k});
            }
        }
        // Orientation: flood each component from its first face; faces that end up reversed
        // relative to their neighbours are the smaller group of the component.
        std::vector<int> sign(size_t(nF), 0), comp(size_t(nF), -1);
        std::vector<std::vector<std::pair<int, bool>>> adj(static_cast<size_t>(nF));  // neighbour, same direction?
        for (uint64_t key : order) {
            const auto& list = uses[key];
            if (list.size() > 2) {
                non_manifold.push_back(int(key >> 32));
                non_manifold.push_back(int(key & 0xffffffffu));
                errors.push_back(vformat("Edge (%d, %d) has %d faces (non-manifold)", int(key >> 32), int(key & 0xffffffffu), int(list.size())));
                continue;
            }
            if (list.size() == 2) {
                adj[size_t(list[0].face)].push_back({list[1].face, list[0].forward == list[1].forward});
                adj[size_t(list[1].face)].push_back({list[0].face, list[0].forward == list[1].forward});
            }
        }
        // Crease pairs that are not edges.
        for (size_t i = 0; i + 1 < c.crease_pairs.size(); i += 2) {
            const int a = c.crease_pairs[i], b = c.crease_pairs[i + 1];
            const uint64_t key = (uint64_t(uint32_t(std::min(a, b))) << 32) | uint64_t(uint32_t(std::max(a, b)));
            if (a < 0 || b < 0 || a >= c.nV || b >= c.nV || uses.find(key) == uses.end()) {
                errors.push_back(vformat("Crease (%d, %d) is not a cage edge", a, b));
                break;
            }
        }
        // Pinched vertices: the faces around a vertex must form one fan (joined through the
        // edges at the vertex). Corners of faces are joined across shared edges.
        {
            std::vector<int> dsu(c.indices.size());
            std::iota(dsu.begin(), dsu.end(), 0);
            std::function<int(int)> root = [&](int x) {
                while (dsu[size_t(x)] != x) {
                    dsu[size_t(x)] = dsu[size_t(dsu[size_t(x)])];
                    x = dsu[size_t(x)];
                }
                return x;
            };
            auto corner_of = [&](const Use& u, int vtx) {
                const int f = u.face;
                const int n = c.counts[size_t(f)];
                const int k = u.corner - offsets[size_t(f)];
                return c.indices[size_t(u.corner)] == vtx ? u.corner : offsets[size_t(f)] + (k + 1) % n;
            };
            for (uint64_t key : order) {
                const auto& list = uses[key];
                if (list.size() != 2) {
                    continue;
                }
                for (int vtx : {int(key >> 32), int(key & 0xffffffffu)}) {
                    const int ra = root(corner_of(list[0], vtx)), rb = root(corner_of(list[1], vtx));
                    if (ra != rb) {
                        dsu[size_t(std::max(ra, rb))] = std::min(ra, rb);
                    }
                }
            }
            std::vector<int> first_root(size_t(c.nV), -1);
            std::vector<char> flagged(size_t(c.nV), 0);
            for (int f = 0; f < nF; ++f) {
                if (bad_face[size_t(f)]) {
                    continue;
                }
                for (int h = offsets[size_t(f)]; h < offsets[size_t(f) + 1]; ++h) {
                    const int vtx = c.indices[size_t(h)];
                    const int r = root(h);
                    if (first_root[size_t(vtx)] < 0) {
                        first_root[size_t(vtx)] = r;
                    }
                    else if (first_root[size_t(vtx)] != r && !flagged[size_t(vtx)]) {
                        flagged[size_t(vtx)] = 1;
                        pinched.push_back(vtx);
                    }
                }
            }
            if (!pinched.is_empty()) {
                errors.push_back(vformat("Vertex %d joins separate fans of faces (non-manifold)", pinched[0]) +
                                 (pinched.size() > 1 ? vformat(" (%d vertices in all)", pinched.size()) : String()));
            }
        }
        int ncomp = 0;
        bool conflict_any = false;
        for (int f0 = 0; f0 < nF; ++f0) {
            if (bad_face[size_t(f0)] || comp[size_t(f0)] >= 0) {
                continue;
            }
            std::vector<int> stack = {f0}, members;
            comp[size_t(f0)] = ncomp;
            sign[size_t(f0)] = 1;
            while (!stack.empty()) {
                const int f = stack.back();
                stack.pop_back();
                members.push_back(f);
                for (const auto& [g, same] : adj[size_t(f)]) {
                    const int want = same ? -sign[size_t(f)] : sign[size_t(f)];
                    if (comp[size_t(g)] < 0) {
                        comp[size_t(g)] = ncomp;
                        sign[size_t(g)] = want;
                        stack.push_back(g);
                    }
                    else if (sign[size_t(g)] != want) {
                        conflict_any = true;
                    }
                }
            }
            int minus = 0;
            for (int f : members) {
                minus += sign[size_t(f)] < 0 ? 1 : 0;
            }
            const int flip_sign = minus * 2 <= int(members.size()) ? -1 : 1;
            for (int f : members) {
                if (sign[size_t(f)] == flip_sign) {
                    flipped.push_back(f);
                }
            }
            ++ncomp;
        }
        if (!flipped.is_empty()) {
            errors.push_back(vformat("%d faces are flipped against their neighbours", flipped.size()));
        }
        else if (conflict_any) {
            errors.push_back("The faces can't be oriented consistently (a one-sided surface)");
        }
        if (self_intersections) {
            // Cage fan triangles of faces that share no vertex.
            std::vector<int> tris, tri_face;
            std::vector<Box> boxes;
            for (int f = 0; f < nF; ++f) {
                if (bad_face[size_t(f)]) {
                    continue;
                }
                const int* fv = &c.indices[size_t(offsets[size_t(f)])];
                for (int k = 1; k + 1 < c.counts[size_t(f)]; ++k) {
                    Box b;
                    for (int v : {fv[0], fv[k], fv[k + 1]}) {
                        tris.push_back(v);
                        b.add(&c.pos[size_t(v) * 3]);
                    }
                    tri_face.push_back(f);
                    b.expand(1e-10 * cage_diag);
                    boxes.push_back(b);
                }
            }
            Bvh bvh;
            bvh.build(boxes);
            std::vector<char> crossed(size_t(nF), 0);
            // Faces count as neighbours when they share a vertex or a vertex position (the seam
            // of an unwelded or duplicated piece touches without crossing).
            std::vector<int> pos_id(size_t(c.nV), -1);
            {
                std::map<std::array<double, 3>, int> ids;
                for (int v = 0; v < c.nV; ++v) {
                    const std::array<double, 3> key = {c.pos[size_t(v) * 3], c.pos[size_t(v) * 3 + 1], c.pos[size_t(v) * 3 + 2]};
                    pos_id[size_t(v)] = ids.emplace(key, int(ids.size())).first->second;
                }
            }
            auto shares_vertex = [&](int fa, int fb) {
                const int* a = &c.indices[size_t(offsets[size_t(fa)])];
                const int* b = &c.indices[size_t(offsets[size_t(fb)])];
                for (int i = 0; i < c.counts[size_t(fa)]; ++i) {
                    for (int j = 0; j < c.counts[size_t(fb)]; ++j) {
                        if (a[i] == b[j] || pos_id[size_t(a[i])] == pos_id[size_t(b[j])]) {
                            return true;
                        }
                    }
                }
                return false;
            };
            const double touch_eps = 1e-10 * cage_diag;
            for (size_t t = 0; t < tri_face.size(); ++t) {
                bvh.overlap(boxes[t], [&](int u) {
                    if (size_t(u) <= t) {
                        return;
                    }
                    const int fa = tri_face[t], fb = tri_face[size_t(u)];
                    if (fa == fb || (crossed[size_t(fa)] && crossed[size_t(fb)]) || shares_vertex(fa, fb)) {
                        return;
                    }
                    const int* A = &tris[t * 3];
                    const int* B = &tris[size_t(u) * 3];
                    if (triangles_cross(&c.pos[size_t(A[0]) * 3], &c.pos[size_t(A[1]) * 3], &c.pos[size_t(A[2]) * 3],
                                        &c.pos[size_t(B[0]) * 3], &c.pos[size_t(B[1]) * 3], &c.pos[size_t(B[2]) * 3], touch_eps)) {
                        crossed[size_t(fa)] = 1;
                        crossed[size_t(fb)] = 1;
                    }
                });
            }
            for (int f = 0; f < nF; ++f) {
                if (crossed[size_t(f)]) {
                    crossing.push_back(f);
                }
            }
            if (!crossing.is_empty()) {
                errors.push_back(vformat("%d faces self-intersect", crossing.size()));
            }
        }
    }
    out["ok"] = errors.is_empty();
    out["errors"] = errors;
    out["non_manifold_edges"] = non_manifold;
    out["flipped_faces"] = flipped;
    out["degenerate_faces"] = degenerate;
    out["self_intersecting_faces"] = crossing;
    out["non_finite_vertices"] = non_finite;
    out["non_manifold_vertices"] = pinched;
    return out;
}

Dictionary CadSubD::project_to_shape(const Ref<CadShape>& shape, const PackedVector3Array& points, double max_distance)
{
    report("");
    if (shape.is_null() || shape->is_null()) {
        report("project_to_shape needs a shape");
        return Dictionary();
    }
    std::vector<double> pts(size_t(points.size()) * 3);
    for (int64_t i = 0; i < points.size(); ++i) {
        pts[size_t(i) * 3] = points[i].x;
        pts[size_t(i) * 3 + 1] = points[i].y;
        pts[size_t(i) * 3 + 2] = points[i].z;
    }
    ProjectResult r;
    std::string error;
    if (!subd::project_to_shape(shape->get_occ_shape(), pts, max_distance, r, error)) {
        report(gstr(error));
        return Dictionary();
    }
    PackedFloat64Array positions, distances;
    PackedVector3Array normals;
    PackedInt32Array faces;
    positions.resize(int64_t(r.positions.size()));
    std::copy(r.positions.begin(), r.positions.end(), positions.ptrw());
    distances.resize(int64_t(r.distances.size()));
    std::copy(r.distances.begin(), r.distances.end(), distances.ptrw());
    faces.resize(int64_t(r.faces.size()));
    std::copy(r.faces.begin(), r.faces.end(), faces.ptrw());
    normals.resize(int64_t(r.faces.size()));
    for (size_t i = 0; i < r.faces.size(); ++i) {
        normals.set(int64_t(i), Vector3(real_t(r.normals[i * 3]), real_t(r.normals[i * 3 + 1]), real_t(r.normals[i * 3 + 2])));
    }
    Dictionary out;
    out["positions"] = positions;
    out["normals"] = normals;
    out["faces"] = faces;
    out["distances"] = distances;
    return out;
}

Dictionary CadSubD::face_grid(const Ref<CadShape>& shape, int face_index, int nu, int nv)
{
    report("");
    Dictionary out;
    if (shape.is_null() || shape->is_null()) {
        report("face_grid needs a shape");
        out["ok"] = false;
        out["four_sided"] = false;
        out["positions"] = PackedFloat64Array();
        out["error"] = "face_grid needs a shape";
        return out;
    }
    const FaceGridResult r = subd::face_grid(shape->get_occ_shape(), face_index, nu, nv);
    PackedFloat64Array positions;
    positions.resize(int64_t(r.positions.size()));
    std::copy(r.positions.begin(), r.positions.end(), positions.ptrw());
    out["ok"] = r.ok;
    out["four_sided"] = r.four_sided;
    out["reversed"] = r.reversed;
    out["positions"] = positions;
    out["error"] = gstr(r.error);
    if (!r.ok) {
        report(gstr(r.error));
    }
    return out;
}

void CadSubD::_bind_methods()
{
    ClassDB::bind_method(D_METHOD("set_cage", "cage"), &CadSubD::set_cage);
    ClassDB::bind_method(D_METHOD("set_positions", "positions"), &CadSubD::set_positions);
    ClassDB::bind_method(D_METHOD("get_vertex_count"), &CadSubD::get_vertex_count);
    ClassDB::bind_method(D_METHOD("get_face_count"), &CadSubD::get_face_count);
    ClassDB::bind_method(D_METHOD("get_edge_count"), &CadSubD::get_edge_count);
    ClassDB::bind_method(D_METHOD("get_ptex_count"), &CadSubD::get_ptex_count);
    ClassDB::bind_method(D_METHOD("osd_version"), &CadSubD::osd_version);
    ClassDB::bind_method(D_METHOD("tessellate", "options"), &CadSubD::tessellate, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("limit_points"), &CadSubD::limit_points);
    ClassDB::bind_method(D_METHOD("evaluate", "faces", "uvs"), &CadSubD::evaluate);
    ClassDB::bind_method(D_METHOD("subface_uv", "face", "subface", "s", "t"), &CadSubD::subface_uv);
    ClassDB::bind_method(D_METHOD("ray_hit", "from", "dir", "mode", "refine"), &CadSubD::ray_hit, DEFVAL(0), DEFVAL(true));
    ClassDB::bind_method(D_METHOD("visible", "points", "eye", "view_dir", "tolerance", "mode"), &CadSubD::visible,
                         DEFVAL(Vector3()), DEFVAL(1e-4), DEFVAL(0));
    ClassDB::bind_method(D_METHOD("closest_points", "points", "max_distance"), &CadSubD::closest_points, DEFVAL(kInf));
    ClassDB::bind_method(D_METHOD("interpolate", "targets", "free", "regularize"), &CadSubD::interpolate,
                         DEFVAL(PackedInt32Array()), DEFVAL(1e-8));
    ClassDB::bind_method(D_METHOD("fit", "faces", "uvs", "targets", "free", "regularize"), &CadSubD::fit, DEFVAL(1e-6));
    ClassDB::bind_method(D_METHOD("to_shapes", "params"), &CadSubD::to_shapes, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("get_last_report"), &CadSubD::get_last_report);
    ClassDB::bind_method(D_METHOD("check_cage", "cage", "self_intersections"), &CadSubD::check_cage, DEFVAL(true));
    ClassDB::bind_method(D_METHOD("project_to_shape", "shape", "points", "max_distance"), &CadSubD::project_to_shape, DEFVAL(kInf));
    ClassDB::bind_method(D_METHOD("face_grid", "shape", "face_index", "nu", "nv"), &CadSubD::face_grid);
    ClassDB::bind_method(D_METHOD("get_last_error"), &CadSubD::get_last_error);
    ClassDB::bind_method(D_METHOD("get_last_warning"), &CadSubD::get_last_warning);
}

}  // namespace holo_forge
