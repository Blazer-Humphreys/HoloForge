// Convert Mesh (work order 3.4.1 and 3.4.2): a mesh body turned into a B-rep body.
//
// Faceted (CadMesh::to_faceted): every triangle becomes a flat face, and with Merge Flat Face
// Groups every flat patch of a face group becomes one face. The faces are built here from the
// mesh's own vertices and edges (each mesh edge is one shared B-rep edge), so nothing is sewn
// or healed, and every loop of ours can be stopped.
//
// Prismatic (CadMesh::to_prismatic): a plane, a cylinder or a sphere is fitted to every face
// group; the surfaces, as large faces, cut space into cells (BOPAlgo_MakerVolume); the cells
// inside the mesh are kept; their outer faces make the solid.
//
// OpenCASCADE reports success on wrong bodies, so neither result is handed over unchecked:
// closed shells, the kernel's own validity check, the volume and the area against the mesh's,
// every face meshed and covered by its mesh (measure::face_drawable), and for Prismatic the
// distance between the result and the mesh both ways, sampled over the whole body.

#include "mesh_convert.h"

#include "cad_mesh.h"
#include "mesh_bvh.h"
#include "mesh_manifold.h"

#include "cad_shape.h"
#include "measure.h"
#include "naming.h"
#include "occt_guard.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/variant.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <BOPAlgo_MakerVolume.hxx>
#include <BOPTools_AlgoTools.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <BRepBndLib.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepBuilderAPI_MakeVertex.hxx>
#include <BRepBuilderAPI_Transform.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRepCheck_Shell.hxx>
#include <BRepCheck_Solid.hxx>
#include <BRepCheck_Wire.hxx>
#include <BRepExtrema_DistShapeShape.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRepTopAdaptor_FClass2d.hxx>
#include <BRepTools.hxx>
#include <BRep_Builder.hxx>
#include <BRep_Tool.hxx>
#include <Bnd_Box.hxx>
#include <ElSLib.hxx>
#include <GeomAbs_SurfaceType.hxx>
#include <Geom_CylindricalSurface.hxx>
#include <Geom_Line.hxx>
#include <Geom_Plane.hxx>
#include <Geom_SphericalSurface.hxx>
#include <IMeshTools_Parameters.hxx>
#include <Message_ProgressIndicator.hxx>
#include <Message_ProgressScope.hxx>
#include <NCollection_Array1.hxx>
#include <Poly_PolygonOnTriangulation.hxx>
#include <Poly_Triangle.hxx>
#include <Poly_Triangulation.hxx>
#include <Precision.hxx>
#include <ShapeFix_Shape.hxx>
#include <ShapeUpgrade_UnifySameDomain.hxx>
#include <Standard_Failure.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopLoc_Location.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <TopTools_ListOfShape.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Compound.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Iterator.hxx>
#include <TopoDS_Shell.hxx>
#include <TopoDS_Solid.hxx>
#include <TopoDS_Vertex.hxx>
#include <TopoDS_Wire.hxx>
#include <gp_Ax3.hxx>
#include <gp_Cylinder.hxx>
#include <gp_Dir.hxx>
#include <gp_Lin.hxx>
#include <gp_Pln.hxx>
#include <gp_Pnt.hxx>
#include <gp_Pnt2d.hxx>
#include <gp_Sphere.hxx>
#include <gp_Trsf.hxx>
#include <gp_Vec.hxx>

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <exception>
#include <functional>
#include <limits>
#include <memory>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

using namespace godot;

namespace holo_forge
{

namespace mesh
{

// ---------------------------------------------------------------- costs

namespace convert
{
double faceted_seconds(double faces, double outline_edges)
{
    return budget::FACETED_SECONDS_PER_1K_FACES * faces / 1000.0 + budget::FACETED_SECONDS_PER_1K_OUTLINE_EDGES * outline_edges / 1000.0;
}

double prismatic_seconds(double triangles, double surfaces, double crossing_pairs, double corners)
{
    return budget::PRISMATIC_SECONDS_PER_100K_TRIANGLES * triangles / 1e5 + budget::PRISMATIC_SECONDS_PER_SURFACE * surfaces +
           budget::PRISMATIC_SECONDS_PER_CROSSING_PAIR * crossing_pairs + budget::PRISMATIC_SECONDS_PER_CORNER * corners;
}
}  // namespace convert

namespace
{
using ops::Options;
using ops::Phases;

constexpr double kInf = std::numeric_limits<double>::infinity();
constexpr double kPi = 3.14159265358979323846;
const char* const FACETED = "Convert Mesh: Faceted";
const char* const PRISMATIC = "Convert Mesh: Prismatic";
/// A mesh edge shorter than this cannot be told from a point at the kernel's own precision.
constexpr double MIN_EDGE = 5e-7;
/// The tolerance of the vertices, edges and faces built here (OpenCASCADE's own default).
constexpr double BUILD_TOLERANCE = 1e-7;
/// The viewport's angle for meshing a body (core/tessellate.gd ANGULAR_DEFLECTION): a result
/// is checked on the very mesh it will be drawn with.
constexpr double DISPLAY_ANGLE = 0.3;
/// A merged face goes through the kernel's own check of a face up to this many outline edges
/// (0.05 s at 400; 0.5 s at 1,700; 18 s at 6,600: it grows with the square of the outline and
/// cannot be stopped). A longer outline is checked piece by piece (long_face_valid).
constexpr uint32_t MAX_OUTLINE_FOR_KERNEL_CHECK = 400;
/// The kernel's check of a shell looks every edge up among the edges of its two faces (12 ns
/// to 19 ns per squared outline edge, not stoppable): up to this sum of squared outlines it
/// is used (0.1 s), past it the same is checked in one pass (shell_sound).
constexpr double MAX_OUTLINE_SQUARES_FOR_KERNEL_SHELL = 4e6;
/// How many face groups Prismatic looks at (each is fitted on its own).
constexpr size_t MAX_PRISMATIC_GROUPS = 1500;

struct P3
{
    double x = 0.0, y = 0.0, z = 0.0;

    P3() = default;
    P3(double x, double y, double z) : x(x), y(y), z(z)
    {
    }
    P3 operator+(const P3& o) const
    {
        return {x + o.x, y + o.y, z + o.z};
    }
    P3 operator-(const P3& o) const
    {
        return {x - o.x, y - o.y, z - o.z};
    }
    P3 operator*(double s) const
    {
        return {x * s, y * s, z * s};
    }
    P3& operator+=(const P3& o)
    {
        x += o.x;
        y += o.y;
        z += o.z;
        return *this;
    }
};
inline double dot(const P3& a, const P3& b)
{
    return a.x * b.x + a.y * b.y + a.z * b.z;
}
inline P3 cross(const P3& a, const P3& b)
{
    return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}
inline double length(const P3& a)
{
    return std::sqrt(dot(a, a));
}
inline P3 normalized(const P3& a)
{
    const double l = length(a);
    return l > 0.0 ? a * (1.0 / l) : P3();
}
inline P3 point_of(const MeshData& m, uint32_t vertex)
{
    const float* p = &m.positions[size_t(vertex) * 3];
    return {double(p[0]), double(p[1]), double(p[2])};
}
inline P3 triangle_cross(const MeshData& m, size_t t)
{
    const P3 a = point_of(m, m.triangles[t * 3]), b = point_of(m, m.triangles[t * 3 + 1]), c = point_of(m, m.triangles[t * 3 + 2]);
    return cross(b - a, c - a);
}
inline gp_Pnt pnt(const P3& p)
{
    return gp_Pnt(p.x, p.y, p.z);
}
inline P3 p3(const gp_Pnt& p)
{
    return {p.X(), p.Y(), p.Z()};
}
inline P3 p3(const Vector3& v)
{
    return {double(v.x), double(v.y), double(v.z)};
}
inline uint32_t next_corner(uint32_t c)
{
    return c - c % 3 + (c + 1) % 3;
}
/// Two unit vectors across n, with u x v = n.
void frame_across(const P3& n, P3& u, P3& v)
{
    u = normalized(cross(n, std::fabs(n.x) < 0.9 ? P3(1, 0, 0) : P3(0, 1, 0)));
    v = cross(n, u);
}

/// The deflection the viewport meshes a body of this size with (core/tessellate.gd).
double display_deflection(double diagonal)
{
    return std::min(std::max(diagonal * 0.0015, 0.00001), 0.01);
}

std::string percent_text(double fraction)
{
    return number_text(fraction * 100.0, "%.3g") + " %";
}

/// OpenCASCADE's progress hook as the op's deadline: its algorithms ask between their steps.
class Clock: public Message_ProgressIndicator
{
public:
    explicit Clock(const Deadline& deadline) : deadline(deadline)
    {
    }
    bool UserBreak() override
    {
        // (elapsed() only reads the clock: OpenCASCADE may ask from another thread.)
        if (!passed.load() && deadline.elapsed() >= deadline.limit()) {
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
    const Deadline& deadline;
    std::atomic<bool> passed{false};
};

/// Runs OpenCASCADE work within what is left of the deadline (guard::run_bounded stops its
/// root finding and classification; the Clock stops what takes a progress range). False when
/// it was stopped or the time ran out; the kernel's own exceptions pass through.
bool bounded(const Deadline& deadline, const std::function<void()>& work)
{
    const double left = deadline.remaining();
    if (!(left > 0.0)) {
        return false;
    }
    const bool finished = guard::run_bounded(left, work);
    return finished && !deadline.expired();
}

/// Meshes a result as the viewport will (so the triangles checked are the ones drawn, and the
/// viewport finds them already made). False when the deadline stopped it.
bool mesh_result(const TopoDS_Shape& shape, double linear, double angle, const Deadline& deadline)
{
    IMeshTools_Parameters params;
    params.Deflection = linear;
    params.Angle = angle;
    params.Relative = false;
    params.InParallel = false;
    const Handle(Clock) clock = new Clock(deadline);
    const bool finished = bounded(deadline, [&] { BRepMesh_IncrementalMesh mesher(shape, params, clock->Start()); });
    return finished && !clock->expired();
}

std::string kernel_error(const char* title, const Standard_Failure& failure)
{
    const char* what = failure.what();
    return std::string(title) + " failed inside the CAD kernel: " + (what != nullptr && what[0] != '\0' ? what : "unknown error") + ".";
}

// ---------------------------------------------------------------- Faceted

/// A flat patch of a face group: edge-connected triangles of one group that lie in one plane
/// and face one way, with a boundary that runs through every vertex once.
struct Patch
{
    uint32_t group = 0;
    P3 point, normal;
    double deviation = 0.0;  // the most a corner of it lies off the plane
    double area = 0.0;       // of its triangles
    double flat_area = 0.0;  // of its face: the triangles' area seen along the plane's normal
    size_t outline = 0;      // edges of its boundary
    std::vector<uint32_t> tris;                // ascending
    std::vector<std::vector<uint32_t>> loops;  // boundary half-edges in order, the outer loop first
};

/// Whether three corners of a mesh span no area (they lie on one line, or two are one): the
/// shared rule for a triangle without area (mesh::without_area, which check() and Faceted's
/// refusal go by), asked of three corners that need not be one triangle's.
bool span_no_area(const MeshData& m, uint32_t a, uint32_t b, uint32_t c)
{
    if (a == b || b == c || a == c) {
        return true;
    }
    thread_local MeshData three;
    if (three.positions.size() != 9) {
        three.positions.assign(9, 0.0f);
        three.triangles = {0, 1, 2};
    }
    const uint32_t corners[3] = {a, b, c};
    for (int k = 0; k < 3; ++k) {
        std::memcpy(&three.positions[size_t(k) * 3], &m.positions[size_t(corners[k]) * 3], 3 * sizeof(float));
    }
    return without_area(three, 0);
}

/// Whether two segments of an outline (in its plane) touch or cross. The segments run between
/// the mesh corners va0, va1 and vb0, vb1; three of them on one line are judged by the shared
/// rule (span_no_area), not by the size of the outline.
bool segments_meet(const MeshData& m, const double* a0, const double* a1, const double* b0, const double* b1, uint32_t va0, uint32_t va1, uint32_t vb0, uint32_t vb1)
{
    auto side = [&](const double* p, const double* q, const double* r, uint32_t vp, uint32_t vq, uint32_t vr) {
        if (span_no_area(m, vp, vq, vr)) {
            return 0;
        }
        const double d = (q[0] - p[0]) * (r[1] - p[1]) - (q[1] - p[1]) * (r[0] - p[0]);
        return d > 0.0 ? 1 : (d < 0.0 ? -1 : 0);
    };
    auto within = [](const double* p, const double* q, const double* r) {
        return std::min(p[0], q[0]) <= r[0] && r[0] <= std::max(p[0], q[0]) && std::min(p[1], q[1]) <= r[1] && r[1] <= std::max(p[1], q[1]);
    };
    const int d1 = side(b0, b1, a0, vb0, vb1, va0), d2 = side(b0, b1, a1, vb0, vb1, va1), d3 = side(a0, a1, b0, va0, va1, vb0), d4 = side(a0, a1, b1, va0, va1, vb1);
    if (d1 * d2 < 0 && d3 * d4 < 0) {
        return true;
    }
    return (d1 == 0 && within(b0, b1, a0)) || (d2 == 0 && within(b0, b1, a1)) || (d3 == 0 && within(a0, a1, b0)) || (d4 == 0 && within(a0, a1, b1));
}

/// Whether the loops of a flat patch's outline are simple and apart: no two of its edges touch
/// or cross, but for neighbours at the corner they share. This is what makes the patch one
/// face (the kernel's own test of a face's wires compares every edge with every other and
/// cannot be stopped: 18 s on an outline of 6,600 edges). xy: the outline's corners in the
/// plane, loop after loop; first: where each loop starts (and the end); corner: each corner's
/// mesh vertex. timed_out is set when the deadline passed.
bool outline_simple(const MeshData& m, const std::vector<double>& xy, const std::vector<uint32_t>& first, const std::vector<uint32_t>& corner, const Deadline& deadline,
                    bool& timed_out)
{
    const size_t n = corner.size();
    if (n < 3) {
        return false;
    }
    // Segment i runs from corner i to the next corner of its loop.
    std::vector<uint32_t> next(n);
    for (size_t l = 0; l + 1 < first.size(); ++l) {
        for (uint32_t i = first[l]; i < first[l + 1]; ++i) {
            next[i] = i + 1 < first[l + 1] ? i + 1 : first[l];
        }
    }
    double lo[2] = {kInf, kInf}, hi[2] = {-kInf, -kInf};
    for (size_t i = 0; i < n; ++i) {
        for (int k = 0; k < 2; ++k) {
            lo[k] = std::min(lo[k], xy[i * 2 + size_t(k)]);
            hi[k] = std::max(hi[k], xy[i * 2 + size_t(k)]);
        }
    }
    const double width = hi[0] - lo[0], height = hi[1] - lo[1];
    const double size = std::max(width, height);
    if (!(size > 0.0)) {
        return false;
    }
    const uint32_t cells = uint32_t(std::min<size_t>(1024, std::max<size_t>(1, size_t(std::ceil(std::sqrt(double(n)))))));
    auto cell_of = [&](double value, int k) {
        const double span = k == 0 ? width : height;
        if (!(span > 0.0)) {
            return uint32_t(0);
        }
        const double at = (value - lo[k]) / span * double(cells);
        return uint32_t(std::min<double>(double(cells - 1), std::max(0.0, std::floor(at))));
    };
    // Each segment into the cells its box covers; a segment that covers very many goes on a
    // list of its own and is compared with every other.
    std::vector<std::pair<uint32_t, uint32_t>> placed;  // cell, segment
    std::vector<uint32_t> wide;
    placed.reserve(n * 2);
    for (uint32_t i = 0; i < n; ++i) {
        const double* a = &xy[size_t(i) * 2];
        const double* b = &xy[size_t(next[i]) * 2];
        const uint32_t x0 = cell_of(std::min(a[0], b[0]), 0), x1 = cell_of(std::max(a[0], b[0]), 0);
        const uint32_t y0 = cell_of(std::min(a[1], b[1]), 1), y1 = cell_of(std::max(a[1], b[1]), 1);
        if (size_t(x1 - x0 + 1) * size_t(y1 - y0 + 1) > 4 * size_t(cells)) {
            wide.push_back(i);
            continue;
        }
        for (uint32_t y = y0; y <= y1; ++y) {
            for (uint32_t x = x0; x <= x1; ++x) {
                placed.emplace_back(y * cells + x, i);
            }
        }
        if (deadline.tick()) {
            timed_out = true;
            return false;
        }
    }
    std::sort(placed.begin(), placed.end());
    auto meet = [&](uint32_t i, uint32_t j) {
        if (i == j || corner[i] == corner[j] || corner[i] == corner[next[j]] || corner[next[i]] == corner[j] || corner[next[i]] == corner[next[j]]) {
            return false;  // the same edge, or neighbours at a corner
        }
        return segments_meet(m, &xy[size_t(i) * 2], &xy[size_t(next[i]) * 2], &xy[size_t(j) * 2], &xy[size_t(next[j]) * 2], corner[i], corner[next[i]], corner[j], corner[next[j]]);
    };
    for (size_t at = 0; at < placed.size();) {
        size_t end = at;
        while (end < placed.size() && placed[end].first == placed[at].first) {
            ++end;
        }
        for (size_t i = at; i < end; ++i) {
            for (size_t j = i + 1; j < end; ++j) {
                if (meet(placed[i].second, placed[j].second)) {
                    return false;
                }
                if (deadline.tick()) {
                    timed_out = true;
                    return false;
                }
            }
        }
        at = end;
    }
    for (const uint32_t i : wide) {
        for (uint32_t j = 0; j < n; ++j) {
            if (meet(i, j)) {
                return false;
            }
            if (deadline.tick()) {
                timed_out = true;
                return false;
            }
        }
    }
    return true;
}

/// The flat patches of at least two triangles, and for every triangle its patch (NONE: the
/// triangle stays a face of its own). False when the deadline passed. near_flat counts the
/// patches left unmerged that are flat to within `floor` (what the mesh's stored corners can
/// hold where the body lies) but not to within the tolerance.
bool find_patches(State& state, const Topology& topo, double flat_tolerance, double floor, const Deadline& deadline, std::vector<Patch>& patches, std::vector<uint32_t>& patch_of,
                  size_t& near_flat)
{
    const MeshData& m = state.data;
    const size_t T = m.triangle_count(), V = m.vertex_count();
    patch_of.assign(T, NONE);
    std::vector<uint32_t> seen(T, NONE);  // the candidate a triangle was reached in
    std::vector<uint32_t> out_he(V, NONE);
    std::vector<uint32_t> stack, touched, border;
    uint32_t candidates = 0;
    for (size_t seed = 0; seed < T; ++seed) {
        if (seen[seed] != NONE) {
            continue;
        }
        const uint32_t id = candidates++;
        Patch patch;
        patch.group = m.groups[seed];
        stack.assign(1, uint32_t(seed));
        seen[seed] = id;
        while (!stack.empty()) {
            const uint32_t t = stack.back();
            stack.pop_back();
            patch.tris.push_back(t);
            for (uint32_t k = 0; k < 3; ++k) {
                const uint32_t twin = topo.twin(t * 3 + k);
                if (twin == NONE) {
                    continue;
                }
                const uint32_t n = twin / 3;
                if (seen[n] == NONE && m.groups[n] == patch.group) {
                    seen[n] = id;
                    stack.push_back(n);
                }
            }
            if (deadline.tick()) {
                return false;
            }
        }
        if (patch.tris.size() < 2) {
            continue;
        }
        std::sort(patch.tris.begin(), patch.tris.end());
        // Its plane: the summed normal, through the middle of the corners' range along it.
        P3 sum, centre;
        double area = 0.0;
        for (const uint32_t t : patch.tris) {
            const P3 cr = triangle_cross(m, t);
            const double a = 0.5 * length(cr);
            sum += cr;
            area += a;
            centre += (point_of(m, m.triangles[size_t(t) * 3]) + point_of(m, m.triangles[size_t(t) * 3 + 1]) + point_of(m, m.triangles[size_t(t) * 3 + 2])) * (a / 3.0);
        }
        if (!(length(sum) > 0.0) || !(area > 0.0)) {
            continue;
        }
        const P3 n = normalized(sum);
        double lo = kInf, hi = -kInf, flat_area = 0.0;
        bool one_way = true;
        for (const uint32_t t : patch.tris) {
            const P3 cr = triangle_cross(m, t);
            if (!(dot(cr, n) > 0.5 * length(cr))) {
                one_way = false;
                break;
            }
            flat_area += 0.5 * dot(cr, n);
            for (uint32_t k = 0; k < 3; ++k) {
                const double d = dot(point_of(m, m.triangles[size_t(t) * 3 + k]), n);
                lo = std::min(lo, d);
                hi = std::max(hi, d);
            }
        }
        if (!one_way || 0.5 * (hi - lo) > flat_tolerance) {
            near_flat += one_way && 0.5 * (hi - lo) <= floor ? 1 : 0;
            continue;
        }
        centre = centre * (1.0 / area);
        patch.normal = n;
        patch.point = centre + n * (0.5 * (lo + hi) - dot(centre, n));
        patch.deviation = 0.5 * (hi - lo);
        patch.area = area;
        // Its boundary: the half-edges whose other side is not in the patch. One leaves every
        // boundary vertex (two would be a pinch, which a face's wire cannot hold).
        bool clean = true;
        touched.clear();
        border.clear();
        for (const uint32_t t : patch.tris) {
            for (uint32_t k = 0; k < 3; ++k) {
                const uint32_t he = t * 3 + k;
                const uint32_t twin = topo.twin(he);
                if (twin != NONE && seen[twin / 3] == id) {
                    continue;
                }
                const uint32_t a = m.triangles[he];
                if (out_he[a] != NONE) {
                    clean = false;
                }
                else {
                    out_he[a] = he;
                    touched.push_back(a);
                }
                border.push_back(he);
            }
        }
        if (clean) {
            for (const uint32_t start : border) {
                if (out_he[m.triangles[start]] != start) {
                    continue;  // already in a loop
                }
                std::vector<uint32_t> loop;
                uint32_t cur = start;
                for (;;) {
                    loop.push_back(cur);
                    out_he[m.triangles[cur]] = NONE;
                    const uint32_t dest = m.triangles[next_corner(cur)];
                    if (dest == m.triangles[start]) {
                        break;
                    }
                    cur = out_he[dest];
                    if (cur == NONE || loop.size() > border.size()) {
                        clean = false;
                        break;
                    }
                }
                if (!clean) {
                    break;
                }
                patch.loops.push_back(std::move(loop));
            }
        }
        for (const uint32_t v : touched) {
            out_he[v] = NONE;
        }
        if (!clean || patch.loops.empty()) {
            continue;
        }
        // In the plane: one loop runs counter-clockwise around the patch (the outer one), the
        // others clockwise (holes), each turning once; together they enclose the patch's area.
        P3 u, v;
        frame_across(n, u, v);
        size_t outer = 0, outers = 0;
        double enclosed = 0.0;
        bool simple = true;
        std::vector<double> outline_xy;
        std::vector<uint32_t> outline_first(1, 0), outline_corner;
        for (size_t l = 0; l < patch.loops.size() && simple; ++l) {
            const std::vector<uint32_t>& loop = patch.loops[l];
            const size_t count = loop.size();
            if (count < 3) {
                simple = false;
                break;
            }
            std::vector<double> xy(count * 2);
            for (size_t i = 0; i < count; ++i) {
                const P3 q = point_of(m, m.triangles[loop[i]]) - patch.point;
                xy[i * 2] = dot(q, u);
                xy[i * 2 + 1] = dot(q, v);
                outline_corner.push_back(m.triangles[loop[i]]);
            }
            outline_xy.insert(outline_xy.end(), xy.begin(), xy.end());
            outline_first.push_back(uint32_t(outline_corner.size()));
            double twice = 0.0, turning = 0.0;
            for (size_t i = 0; i < count; ++i) {
                const size_t j = (i + 1) % count, k = (i + 2) % count;
                twice += xy[i * 2] * xy[j * 2 + 1] - xy[j * 2] * xy[i * 2 + 1];
                const double e1x = xy[j * 2] - xy[i * 2], e1y = xy[j * 2 + 1] - xy[i * 2 + 1];
                const double e2x = xy[k * 2] - xy[j * 2], e2y = xy[k * 2 + 1] - xy[j * 2 + 1];
                turning += std::atan2(e1x * e2y - e1y * e2x, e1x * e2x + e1y * e2y);
            }
            const double sign = twice > 0.0 ? 1.0 : -1.0;
            if (twice == 0.0 || std::fabs(turning - sign * 2.0 * kPi) > 0.5) {
                simple = false;
                break;
            }
            enclosed += 0.5 * twice;
            if (twice > 0.0) {
                outer = l;
                ++outers;
            }
        }
        if (!simple || outers != 1 || std::fabs(enclosed - flat_area) > 1e-6 * flat_area) {
            continue;
        }
        bool timed_out = false;
        if (!outline_simple(m, outline_xy, outline_first, outline_corner, deadline, timed_out)) {
            if (timed_out) {
                return false;
            }
            continue;
        }
        patch.flat_area = enclosed;
        patch.outline = outline_corner.size();
        std::swap(patch.loops[0], patch.loops[outer]);
        for (const uint32_t t : patch.tris) {
            patch_of[t] = uint32_t(patches.size());
        }
        patches.push_back(std::move(patch));
    }
    return true;
}

enum class Outcome { Ok, TimedOut, Failed };

/// A merged face with a long outline, checked piece by piece: every edge by the kernel, every
/// wire in one piece and closed. (The kernel's check of a whole face looks every edge up among
/// all the face's edges and compares every wire with every other. What that would add is
/// checked another way: the wires do not cross each other or themselves (outline_simple, when
/// the patch was found), they enclose the patch's flat area, and the face's own triangles
/// cover it (measure::face_drawable).)
bool long_face_valid(const TopoDS_Face& face, const Deadline& deadline, bool& timed_out)
{
    for (TopoDS_Iterator w(face); w.More(); w.Next()) {
        if (w.Value().ShapeType() != TopAbs_WIRE) {
            continue;
        }
        for (TopoDS_Iterator e(w.Value()); e.More(); e.Next()) {
            if (!BRepCheck_Analyzer(e.Value(), false).IsValid()) {
                return false;
            }
            if (deadline.tick()) {
                timed_out = true;
                return false;
            }
        }
        const Handle(BRepCheck_Wire) wire = new BRepCheck_Wire(TopoDS::Wire(w.Value()));
        if (wire->Status().First() != BRepCheck_NoError || wire->Closed() != BRepCheck_NoError) {
            return false;
        }
    }
    return true;
}

/// Every edge of a shell used by two of its faces, in opposite directions (by one face where
/// an open body ends): what BRepCheck_Shell's Closed and Orientation check, in one pass.
bool shell_sound(const TopoDS_Shell& shell, bool closed)
{
    struct Uses
    {
        uint32_t forward = 0, reversed = 0;
    };
    std::unordered_map<const void*, Uses> uses;
    for (TopoDS_Iterator f(shell); f.More(); f.Next()) {
        // (The explorer gives each edge its direction in the face as the shell holds it.)
        for (TopExp_Explorer e(f.Value(), TopAbs_EDGE); e.More(); e.Next()) {
            Uses& u = uses[e.Current().TShape().get()];
            if (e.Current().Orientation() == TopAbs_FORWARD) {
                ++u.forward;
            }
            else if (e.Current().Orientation() == TopAbs_REVERSED) {
                ++u.reversed;
            }
            else {
                return false;
            }
        }
    }
    for (const auto& entry : uses) {
        const Uses& u = entry.second;
        const bool shared = u.forward == 1 && u.reversed == 1;
        const bool free = u.forward + u.reversed == 1;
        if (!(shared || (!closed && free))) {
            return false;
        }
    }
    return true;
}

struct Faceted
{
    TopoDS_Shape shape;
    std::vector<TopoDS_Face> faces;  // in the order made
    std::vector<std::string> names;
    std::vector<uint8_t> merged;  // 1: the face of a flat patch
    std::vector<uint32_t> outline;  // the edges of a merged face's outline (0 for a triangle)
    size_t solids = 0, shells = 0, edges = 0;
    size_t repeated = 0;  // pieces that lie in the same place as another piece
    double merged_area = 0.0, max_deviation = 0.0;
    double area = 0.0;  // what the faces should measure: the triangles', and each merged face's flat area
};

/// The B-rep of the mesh: a vertex per used mesh vertex, a straight edge per mesh edge that
/// is not inside a flat patch, a flat face per patch and per other triangle, a shell per
/// connected piece, and for a closed mesh a solid per solid piece with its voids (the nesting
/// rule decides which shell is which).
Outcome build_faceted(State& state, const Topology& topo, const std::vector<Patch>& patches, const std::vector<uint32_t>& patch_of, bool closed, const Deadline& deadline,
                      Faceted& out, std::string& error)
{
    const MeshData& m = state.data;
    const size_t T = m.triangle_count(), V = m.vertex_count(), G = m.group_count();
    const Components* comps = closed ? nested_components_of(state, &deadline) : components_of(state, &deadline);
    if (comps == nullptr) {
        return Outcome::TimedOut;
    }
    // Names: a group that is one flat patch gives its name to the face; other faces are
    // <group>/p<k> (its k-th patch) and <group>/t<k> (its k-th triangle).
    std::vector<uint32_t> group_patches(G, 0), group_singles(G, 0), rank(T, 0), patch_rank(patches.size(), 0);
    {
        std::vector<uint32_t> next(G, 0);
        for (size_t t = 0; t < T; ++t) {
            rank[t] = next[m.groups[t]]++;
            if (patch_of[t] == NONE) {
                ++group_singles[m.groups[t]];
            }
        }
        for (size_t p = 0; p < patches.size(); ++p) {
            patch_rank[p] = group_patches[patches[p].group]++;
        }
    }
    // (A group may be named like another group's face, "g0/t9" beside "g0": no two faces share
    // a name.)
    std::unordered_set<std::string> used;
    auto unused = [&](const std::string& wanted) {
        std::string name = wanted;
        for (int k = 2; !used.insert(name).second; ++k) {
            name = wanted + "#" + std::to_string(k);
        }
        return name;
    };
    BRep_Builder builder;
    std::vector<TopoDS_Vertex> vertices(V);
    std::vector<TopoDS_Edge> edges(topo.edge_count());
    auto vertex_of = [&](uint32_t v) -> const TopoDS_Vertex& {
        if (vertices[v].IsNull()) {
            builder.MakeVertex(vertices[v], pnt(point_of(m, v)), BUILD_TOLERANCE);
        }
        return vertices[v];
    };
    // An edge runs the way its first half-edge does.
    auto edge_of = [&](uint32_t he) -> TopoDS_Edge {
        const uint32_t e = topo.he_edge[he];
        const uint32_t first = topo.edge_hes[topo.edge_first[e]];
        if (edges[e].IsNull()) {
            const uint32_t a = m.triangles[first], b = m.triangles[next_corner(first)];
            const P3 pa = point_of(m, a), pb = point_of(m, b);
            const P3 d = pb - pa;
            const Handle(Geom_Line) line = new Geom_Line(pnt(pa), gp_Dir(d.x, d.y, d.z));
            builder.MakeEdge(edges[e], line, BUILD_TOLERANCE);
            TopoDS_Vertex va = vertex_of(a), vb = vertex_of(b);
            va.Orientation(TopAbs_FORWARD);
            vb.Orientation(TopAbs_REVERSED);
            builder.Add(edges[e], va);
            builder.Add(edges[e], vb);
            builder.Range(edges[e], 0.0, length(d));
            ++out.edges;
        }
        TopoDS_Edge oriented = edges[e];
        oriented.Orientation(he == first ? TopAbs_FORWARD : TopAbs_REVERSED);
        return oriented;
    };
    // The line an edge is drawn with on a face's mesh: its two ends, as nodes of that mesh, in
    // the edge's own direction (from and to are the half-edge's).
    auto add_polygon = [&](const TopoDS_Edge& edge, const Handle(Poly_Triangulation)& drawn, int from, int to, uint32_t he) {
        const bool forward = edge.Orientation() == TopAbs_FORWARD;
        NCollection_Array1<int> ends(1, 2);
        ends.SetValue(1, forward ? from : to);
        ends.SetValue(2, forward ? to : from);
        NCollection_Array1<double> at(1, 2);
        at.SetValue(1, 0.0);
        at.SetValue(2, length(point_of(m, m.triangles[he]) - point_of(m, m.triangles[next_corner(he)])));
        const Handle(Poly_PolygonOnTriangulation) polygon = new Poly_PolygonOnTriangulation(ends, at);
        polygon->Deflection(0.0);
        builder.UpdateEdge(edge, polygon, drawn);
    };
    std::vector<uint32_t> local(V, 0), local_stamp(V, 0);
    uint32_t stamp = 0;
    const size_t C = comps->list.size();
    std::vector<TopoDS_Shell> shells(C);
    for (TopoDS_Shell& shell : shells) {
        builder.MakeShell(shell);
    }
    out.faces.reserve(T);
    out.names.reserve(T);
    out.merged.reserve(T);
    for (size_t t = 0; t < T; ++t) {
        if (deadline.tick()) {
            return Outcome::TimedOut;
        }
        const int32_t comp = comps->of_triangle[t];
        if (comp < 0) {
            error = std::string(FACETED) + " found a triangle that is in no piece (internal error). Please report it.";
            return Outcome::Failed;
        }
        const std::string& group_name = m.group_names[m.groups[t]];
        TopoDS_Face face;
        if (patch_of[t] == NONE) {
            const P3 a = point_of(m, m.triangles[t * 3]);
            const P3 n = triangle_cross(m, t);
            const Handle(Geom_Plane) plane = new Geom_Plane(gp_Pln(pnt(a), gp_Dir(n.x, n.y, n.z)));
            builder.MakeFace(face, plane, BUILD_TOLERANCE);
            // Its drawn mesh is the triangle itself.
            const Handle(Poly_Triangulation) drawn = new Poly_Triangulation(3, 1, true, true);
            const gp_Dir normal(n.x, n.y, n.z);
            for (int k = 0; k < 3; ++k) {
                const gp_Pnt corner = pnt(point_of(m, m.triangles[t * 3 + size_t(k)]));
                double pu = 0.0, pv = 0.0;
                ElSLib::Parameters(plane->Pln(), corner, pu, pv);
                drawn->SetNode(k + 1, corner);
                drawn->SetUVNode(k + 1, gp_Pnt2d(pu, pv));
                drawn->SetNormal(k + 1, normal);
            }
            drawn->SetTriangle(1, Poly_Triangle(1, 2, 3));
            drawn->Deflection(0.0);
            builder.UpdateFace(face, drawn);
            TopoDS_Wire wire;
            builder.MakeWire(wire);
            for (uint32_t k = 0; k < 3; ++k) {
                const uint32_t he = uint32_t(t) * 3 + k;
                const TopoDS_Edge edge = edge_of(he);
                builder.Add(wire, edge);
                add_polygon(edge, drawn, int(k) + 1, int((k + 1) % 3) + 1, he);
            }
            wire.Closed(true);
            builder.Add(face, wire);
            out.names.push_back(unused(group_name + "/t" + std::to_string(rank[t])));
            out.merged.push_back(0);
            out.outline.push_back(0);
            out.area += 0.5 * length(n);
        }
        else {
            const Patch& patch = patches[patch_of[t]];
            if (patch.tris[0] != t) {
                continue;  // the patch's face was made at its first triangle
            }
            P3 u, v;
            frame_across(patch.normal, u, v);
            const Handle(Geom_Plane) plane =
                    new Geom_Plane(gp_Ax3(pnt(patch.point), gp_Dir(patch.normal.x, patch.normal.y, patch.normal.z), gp_Dir(u.x, u.y, u.z)));
            // The patch's corners lie within its deviation of the plane: the face, its edges
            // and its corners say so in their tolerances.
            const double tolerance = std::max(BUILD_TOLERANCE, patch.deviation * 1.05 + 1e-12);
            builder.MakeFace(face, plane, tolerance);
            // Its drawn mesh is the patch's own triangles (the mesher is never asked: what is
            // drawn is the mesh that was converted).
            ++stamp;
            uint32_t nodes = 0;
            for (const uint32_t pt : patch.tris) {
                for (size_t k = 0; k < 3; ++k) {
                    const uint32_t vertex = m.triangles[size_t(pt) * 3 + k];
                    if (local_stamp[vertex] != stamp) {
                        local_stamp[vertex] = stamp;
                        local[vertex] = ++nodes;
                    }
                }
            }
            const Handle(Poly_Triangulation) drawn = new Poly_Triangulation(int(nodes), int(patch.tris.size()), true, true);
            const gp_Dir normal(patch.normal.x, patch.normal.y, patch.normal.z);
            int filled = 0;
            for (const uint32_t pt : patch.tris) {
                int corner[3];
                for (size_t k = 0; k < 3; ++k) {
                    const uint32_t vertex = m.triangles[size_t(pt) * 3 + k];
                    corner[k] = int(local[vertex]);
                    const gp_Pnt at = pnt(point_of(m, vertex));
                    double pu = 0.0, pv = 0.0;
                    ElSLib::Parameters(plane->Pln(), at, pu, pv);
                    drawn->SetNode(corner[k], at);
                    drawn->SetUVNode(corner[k], gp_Pnt2d(pu, pv));
                    drawn->SetNormal(corner[k], normal);
                }
                drawn->SetTriangle(++filled, Poly_Triangle(corner[0], corner[1], corner[2]));
            }
            drawn->Deflection(patch.deviation);
            builder.UpdateFace(face, drawn);
            for (const std::vector<uint32_t>& loop : patch.loops) {
                TopoDS_Wire wire;
                builder.MakeWire(wire);
                for (const uint32_t he : loop) {
                    const TopoDS_Edge edge = edge_of(he);
                    builder.Add(wire, edge);
                    add_polygon(edge, drawn, int(local[m.triangles[he]]), int(local[m.triangles[next_corner(he)]]), he);
                    if (tolerance > BUILD_TOLERANCE) {
                        builder.UpdateEdge(edge, tolerance);
                        builder.UpdateVertex(vertex_of(m.triangles[he]), tolerance);
                    }
                }
                wire.Closed(true);
                builder.Add(face, wire);
                if (deadline.tick()) {
                    return Outcome::TimedOut;
                }
            }
            const bool whole = group_patches[patch.group] == 1 && group_singles[patch.group] == 0;
            out.names.push_back(unused(whole ? group_name : group_name + "/p" + std::to_string(patch_rank[patch_of[t]])));
            out.merged.push_back(1);
            out.outline.push_back(uint32_t(patch.outline));
            out.merged_area += patch.area;
            out.area += patch.flat_area;
            out.max_deviation = std::max(out.max_deviation, patch.deviation);
        }
        builder.Add(shells[size_t(comp)], face);
        out.faces.push_back(face);
    }
    for (TopoDS_Shell& shell : shells) {
        shell.Closed(BRep_Tool::IsClosed(shell));
    }
    out.shells = C;
    {
        // Pieces with the same box, size and volume: the same piece twice in one place.
        std::vector<std::array<double, 8>> keys;
        keys.reserve(C);
        for (const Component& c : comps->list) {
            keys.push_back({c.lo[0], c.lo[1], c.lo[2], c.hi[0], c.hi[1], c.hi[2], double(c.triangles), c.volume});
        }
        std::sort(keys.begin(), keys.end());
        for (size_t i = 1; i < keys.size(); ++i) {
            out.repeated += keys[i] == keys[i - 1] ? 1 : 0;
        }
    }
    std::vector<TopoDS_Shape> parts;
    if (closed) {
        for (size_t c = 0; c < C; ++c) {
            if (!shells[c].Closed() || comps->list[c].depth < 0) {
                error = std::string(FACETED) + " made a shell that is not closed (internal error). Please report it.";
                return Outcome::Failed;
            }
        }
        for (size_t c = 0; c < C; ++c) {
            if (comps->list[c].depth % 2 != 0) {
                continue;  // a void: it goes into the solid around it
            }
            TopoDS_Solid solid;
            builder.MakeSolid(solid);
            builder.Add(solid, shells[c]);
            for (size_t d = 0; d < C; ++d) {
                if (comps->list[d].depth % 2 == 1 && comps->list[d].parent == int(c)) {
                    builder.Add(solid, shells[d]);
                }
            }
            parts.push_back(solid);
        }
        out.solids = parts.size();
    }
    else {
        for (const TopoDS_Shell& shell : shells) {
            parts.push_back(shell);
        }
    }
    if (parts.empty()) {
        error = std::string(FACETED) + " made no body (internal error). Please report it.";
        return Outcome::Failed;
    }
    if (parts.size() == 1) {
        out.shape = parts[0];
    }
    else {
        TopoDS_Compound compound;
        builder.MakeCompound(compound);
        for (const TopoDS_Shape& part : parts) {
            builder.Add(compound, part);
        }
        out.shape = compound;
    }
    return Outcome::Ok;
}

/// Mesh edges shorter than MIN_EDGE.
size_t count_short_edges(const MeshData& m, const Topology& topo)
{
    size_t count = 0;
    for (size_t e = 0; e < topo.edge_count(); ++e) {
        const uint32_t he = topo.edge_hes[topo.edge_first[e]];
        if (length(point_of(m, m.triangles[he]) - point_of(m, m.triangles[next_corner(he)])) < MIN_EDGE) {
            ++count;
        }
    }
    return count;
}

/// What the stored corners can hold where the body lies: four steps of a float at its farthest
/// coordinate.
double faceted_floor(const Measures& ms)
{
    double farthest = 0.0;
    for (int k = 0; k < 3; ++k) {
        farthest = std::max(farthest, std::max(std::fabs(ms.lo[k]), std::fabs(ms.hi[k])));
    }
    return 4.0 * 1.1920929e-7 * farthest;
}

/// What Faceted is expected to take (seconds) for these patches: a face per patch and per
/// triangle in none, and the patches' outline edges.
double faceted_estimate(const std::vector<Patch>& patches, const std::vector<uint32_t>& patch_of)
{
    size_t faces = patches.size(), outline = 0;
    for (const Patch& patch : patches) {
        outline += patch.outline;
    }
    for (const uint32_t p : patch_of) {
        faces += p == NONE ? 1 : 0;
    }
    return convert::faceted_seconds(double(faces), double(outline));
}

/// What helps when the distance from the origin is what refuses a convert: a mesh's corners
/// keep their shape only nearer the origin, and a converted body keeps its shape anywhere.
const char* const CONVERT_NEARER = "Convert the mesh before it is placed this far from the origin, then move the converted body there.";

/// Of the triangles without area (the shared rule, mesh::without_area), how many the body's
/// distance from the origin flattened: the body lies farther from the origin than its own size,
/// and positions there step by more than a ten-thousandth of the triangle (a thin triangle's
/// corners were rounded onto one line when the mesh was placed there). A triangle that names a
/// corner twice never counts.
size_t count_far_only(State& state)
{
    const MeshData& m = state.data;
    const ops::Place place = ops::place_of(state);
    if (!(place.distance > place.diagonal) || !(place.step > 0.0)) {
        return 0;
    }
    size_t count = 0;
    const size_t T = m.triangle_count();
    for (size_t t = 0; t < T; ++t) {
        const uint32_t* c = &m.triangles[t * 3];
        if (c[0] == c[1] || c[1] == c[2] || c[0] == c[2] || !without_area(m, t)) {
            continue;
        }
        double p[3][3];
        for (int k = 0; k < 3; ++k) {
            m.point(c[k], p[k]);
        }
        double longest = 0.0;
        for (int k = 0; k < 3; ++k) {
            const double* a = p[k];
            const double* b = p[(k + 1) % 3];
            longest = std::max(longest, std::sqrt((b[0] - a[0]) * (b[0] - a[0]) + (b[1] - a[1]) * (b[1] - a[1]) + (b[2] - a[2]) * (b[2] - a[2])));
        }
        count += place.step > 1e-4 * longest ? 1 : 0;
    }
    return count;
}

/// "<Name> is <d> from the origin, ... a hundredth of its size or more: its corners have run
/// together", when the body's place, not its shape, takes its volume; else "".
std::string far_no_volume(State& state, const std::string& name_start)
{
    const ops::Place place = ops::place_of(state);
    if (!(place.distance > place.diagonal) || !(place.step >= 0.01 * place.diagonal)) {
        return std::string();
    }
    return name_start + " is " + ops::length_text(place.distance) + " from the origin, where positions are stored only to about " + ops::length_text(place.step) +
           ", a hundredth of its size or more: its corners have run together and it encloses no volume. " + CONVERT_NEARER;
}

/// "<Name> is <d> from the origin, where positions are stored only to about <step>", the
/// Mesh tools' own words for a body that far (ops::too_far).
std::string far_words(State& state, const std::string& name_start)
{
    const ops::Place place = ops::place_of(state);
    return name_start + " is " + ops::length_text(place.distance) + " from the origin, where positions are stored only to about " + ops::length_text(place.step);
}

/// What Faceted says of a mesh it cannot take, before any work ("" when it can). `name`
/// starts a sentence.
std::string faceted_refusal(State& state, const std::string& name)
{
    const MeshData& m = state.data;
    const size_t T = m.triangle_count();
    if (T == 0) {
        return name + " has no triangles.";
    }
    if (T > budget::MAX_TRIANGLES_FACETED) {
        return name + " has " + with_commas(T) + " triangles; Convert Mesh: Faceted takes up to " + with_commas(budget::MAX_TRIANGLES_FACETED) + ". Reduce it first.";
    }
    const Topology* topo = topology_of(state);
    if (topo->non_manifold_edges > 0) {
        return name + " has " + (topo->non_manifold_edges == 1 ? std::string("1 edge") : with_commas(topo->non_manifold_edges) + " edges") +
               " that more than two triangles share. Run Stitch and Remove first.";
    }
    if (topo->inconsistent_edges > 0) {
        return name + " has triangles that face the wrong way (at " + (topo->inconsistent_edges == 1 ? std::string("1 edge") : with_commas(topo->inconsistent_edges) + " edges") +
               "). Run Reverse Normal first.";
    }
    const int64_t flat = count_degenerate(state);
    if (flat > 0) {
        const auto counted = [](uint64_t n) { return n == 1 ? std::string("1 triangle") : with_commas(n) + " triangles"; };
        const size_t far = count_far_only(state);
        if (far > 0 && int64_t(far) >= flat) {
            // Thinner than positions are stored where the body lies: placed there, thin triangles
            // are rounded flat. Stitch and Remove keeps such triangles when taking them out would
            // open the mesh, so it is not named. (A triangle drawn flat on purpose and placed far
            // away is told the same: the two cannot be told apart once stored.)
            return far_words(state, name) + ": " + with_commas(uint64_t(flat)) + " of its triangles " + (flat == 1 ? "is" : "are") + " thinner than that and " +
                   (flat == 1 ? "has" : "have") + " no area. " + CONVERT_NEARER;
        }
        if (far > 0) {
            return name + " has " + counted(uint64_t(flat)) + " without area. " + far_words(state, "It") + ", and " + with_commas(far) + " of them " +
                   (far == 1 ? "is" : "are") + " thinner than that. Run Stitch and Remove first, and convert the mesh before it is placed this far from the origin.";
        }
        return name + " has " + counted(uint64_t(flat)) + " without area. Run Stitch and Remove first.";
    }
    const size_t tiny = count_short_edges(m, *topo);
    if (tiny > 0) {
        return name + " has " + (tiny == 1 ? std::string("1 edge") : with_commas(tiny) + " edges") + " shorter than " + ops::length_text(MIN_EDGE) +
               ", which a solid cannot hold. Run Stitch and Remove with a larger Stitch Tolerance first.";
    }
    if (topo->boundary_edges == 0) {
        int64_t inverted = 0, empty = 0, pieces = 0;
        const double diagonal = measures_of(state).diagonal;
        for (const Component& c : nested_components_of(state)->list) {
            ++pieces;
            inverted += c.inverted ? 1 : 0;
            empty += c.closed && std::fabs(c.volume) <= 1e-12 * diagonal * diagonal * diagonal ? 1 : 0;
        }
        if (empty > 0 && empty == pieces) {
            // (Stitch and Remove takes such a piece out from beside others, not when it is all there is.)
            const std::string far = far_no_volume(state, name);
            return !far.empty() ? far : name + " encloses no volume (its triangles lie back to back): there is nothing to make a solid of.";
        }
        if (empty > 0) {
            return name + " has " + (empty == 1 ? std::string("1 piece") : with_commas(uint64_t(empty)) + " pieces") +
                   " with no volume (triangles that lie back to back). Run Stitch and Remove first.";
        }
        if (inverted > 0) {
            return inverted == 1 ? name + " has 1 part that is inside-out. Reverse Normal can fix it."
                                 : name + " has " + with_commas(uint64_t(inverted)) + " parts that are inside-out. Reverse Normal can fix them.";
        }
    }
    return std::string();
}

// ---------------------------------------------------------------- Prismatic: fits

/// One fitted primitive.
struct Prim
{
    int kind = -1;   // 0 plane, 1 cylinder, 2 sphere
    P3 point, axis;  // plane: a point and the normal; cylinder: an axis point and direction; sphere: the centre
    double radius = 0.0;

    double distance(const P3& p) const
    {
        const P3 q = p - point;
        if (kind == 0) {
            return std::fabs(dot(q, axis));
        }
        if (kind == 1) {
            return std::fabs(length(q - axis * dot(q, axis)) - radius);
        }
        return std::fabs(length(q) - radius);
    }
};

const char* kind_word(int kind)
{
    return kind == 0 ? "plane" : (kind == 1 ? "cylinder" : (kind == 2 ? "sphere" : "none"));
}

/// How far the triangles lie off the primitive: the most over their corners, the middles of
/// their edges and their own middles (a chord across a round surface is farthest there, so a
/// coarse round group counts as far off as it is).
double prim_error(const MeshData& m, const uint32_t* tris, size_t count, const Prim& prim)
{
    double worst = 0.0;
    for (size_t i = 0; i < count; ++i) {
        const size_t t = tris[i];
        const P3 a = point_of(m, m.triangles[t * 3]), b = point_of(m, m.triangles[t * 3 + 1]), c = point_of(m, m.triangles[t * 3 + 2]);
        worst = std::max(worst, prim.distance(a));
        worst = std::max(worst, prim.distance(b));
        worst = std::max(worst, prim.distance(c));
        if (prim.kind != 0) {
            worst = std::max(worst, prim.distance((a + b) * 0.5));
            worst = std::max(worst, prim.distance((b + c) * 0.5));
            worst = std::max(worst, prim.distance((c + a) * 0.5));
            worst = std::max(worst, prim.distance((a + b + c) * (1.0 / 3.0)));
        }
    }
    return worst;
}

/// A plane with this normal through the middle of the corners' range along it.
void recentre_plane(const MeshData& m, const uint32_t* tris, size_t count, Prim& plane)
{
    double lo = kInf, hi = -kInf;
    for (size_t i = 0; i < count; ++i) {
        for (size_t k = 0; k < 3; ++k) {
            const double d = dot(point_of(m, m.triangles[size_t(tris[i]) * 3 + k]) - plane.point, plane.axis);
            lo = std::min(lo, d);
            hi = std::max(hi, d);
        }
    }
    if (lo <= hi) {
        plane.point = plane.point + plane.axis * (0.5 * (lo + hi));
    }
}

/// One surface of the solid: a primitive and the face groups that lie on it.
struct Surface
{
    Prim prim;
    std::vector<uint32_t> groups;
    double area = 0.0;
    double error = 0.0;  // the most any of its groups lies off it
};

/// What Prismatic works out before any CAD kernel call.
struct Plan
{
    std::string problem;  // the refusal, "" when the plan stands
    double tolerance = 0.0;
    bool allow_spheres = true;
    double diagonal = 0.0;
    std::vector<Surface> surfaces;
    std::vector<int32_t> surface_of_group;
    size_t planes = 0, cylinders = 0, spheres = 0;
    size_t crossing_pairs = 0;
    size_t corners = 0;  // points where three flat surfaces meet near the body
    double seconds = 0.0;
    bool timed_out = false;
    // The plan is made on a copy of the body at a size and place the kernel works well at
    // (Workplace below). unit: meters of the body for one of the copy's (lengths in messages
    // are the body's). numbers: each face group's number in the body. snap: how far a round
    // surface may lie from touching a flat one and still be taken to touch it.
    double unit = 1.0;
    std::vector<uint32_t> numbers;
    double snap = 0.0;
    size_t skipped_groups = 0;  // face groups without area
    size_t touching = 0;        // round surfaces set to touch a flat one exactly
    size_t equal_radii = 0;     // cylinders given the radius of another, all but equal, one
    // Those of them whose radii differed by more than a tenth of the tolerance: the group whose
    // radius changed, its own radius, the group whose radius it took, and that radius.
    struct MadeEqual
    {
        uint32_t changed = 0, kept = 0;
        double was = 0.0, now = 0.0;
    };
    std::vector<MadeEqual> made_equal;
    bool far = false;           // the stored corners, not the body's size, set the snap distance
    size_t meeting_axes = 0;    // cylinders whose axis was set to meet another's exactly
    // What the stored corners can hold (the copy's meters), and "<Body> is <d> from the origin,
    // where positions are stored only to about <step>" (far_words): a group that misses its
    // surface by no more than that misses it because of where the body lies.
    double floor = 0.0;
    std::string far_text, far_start;  // ... with the name as the body's, and as a sentence's start
    // The body is one face group (with area) that no surface fitted: its best fit, and whether
    // a Fit Tolerance the field takes would let it pass with the volume kept (nearly).
    bool one_group = false;
    bool nearly = false;
    int best_kind = 0;
    double best_error = 0.0;
    double best_volume_change = 0.0;  // about what a surface that far off moves the volume by

    std::string mm(double length) const
    {
        return ops::length_text(length * unit);
    }
    std::string group_number(uint32_t group) const
    {
        return std::to_string(group < numbers.size() ? numbers[group] : group + 1);
    }
};

/// A copy of a body for Prismatic to work on: its middle at the origin, and brought to a
/// size of 0.2 m when it is smaller than 20 mm or larger than 2 m. The kernel's tolerances
/// are absolute (0.1 micrometer): on a body of 0.2 mm a round of a few micrometers is lost in
/// them and meshing its cells does not end; kilometres from the origin its numbers lose the
/// digits a touching round needs.
struct Workplace
{
    Ref<CadMesh> mesh;
    double unit = 1.0;       // the body's meters for one of the copy's
    double centre[3] = {0, 0, 0};
    double floor = 0.0;      // what the body's stored corners can hold, in the copy's meters
    std::vector<uint32_t> numbers;
    std::string problem;
};

Workplace workplace_of(State& state)
{
    Workplace w;
    const Measures& ms = measures_of(state);
    const double D = ms.diagonal;
    double farthest = 0.0;
    for (int k = 0; k < 3; ++k) {
        w.centre[k] = 0.5 * (ms.lo[k] + ms.hi[k]);
        farthest = std::max(farthest, std::max(std::fabs(ms.lo[k]), std::fabs(ms.hi[k])));
    }
    const double scale = D > 0.0 && (D < 0.02 || D > 2.0) ? 0.2 / D : 1.0;
    w.unit = 1.0 / scale;
    w.floor = 4.0 * 1.1920929e-7 * farthest * scale;
    const double basis[9] = {scale, 0, 0, 0, scale, 0, 0, 0, scale};
    const double origin[3] = {-scale * w.centre[0], -scale * w.centre[1], -scale * w.centre[2]};
    std::string error;
    w.mesh = CadMesh::wrap(transformed(state.data, basis, origin), &error);
    if (w.mesh.is_null()) {
        w.problem = error;
        return w;
    }
    // (The copy has no empty face groups: each of its groups keeps the body's number, by name.)
    const MeshData& here = w.mesh->data();
    std::unordered_map<std::string, uint32_t> by_name;
    for (size_t g = 0; g < state.data.group_names.size(); ++g) {
        by_name[state.data.group_names[g]] = uint32_t(g + 1);
    }
    for (size_t g = 0; g < here.group_names.size(); ++g) {
        const auto found = by_name.find(here.group_names[g]);
        w.numbers.push_back(found != by_name.end() ? found->second : uint32_t(g + 1));
    }
    return w;
}

/// The grown box of the body (work order 3.4.2 step 4): its middle and the half-length every
/// large face reaches from there.
struct Reach
{
    P3 centre;
    double radius = 0.0;
};

Reach reach_of(State& state)
{
    const Measures& ms = measures_of(state);
    Reach r;
    r.centre = P3(0.5 * (ms.lo[0] + ms.hi[0]), 0.5 * (ms.lo[1] + ms.hi[1]), 0.5 * (ms.lo[2] + ms.hi[2]));
    // Half the diagonal, grown by half.
    r.radius = 0.75 * ms.diagonal;
    return r;
}

/// Fits, merges and counts (3.4.2 steps 1 to 3). fit is CadMesh::fit_primitive on a group's
/// triangles. `name` starts a sentence, `body` is the name inside one.
void make_plan(State& state, const std::function<Dictionary(const PackedInt32Array&)>& fit, double tolerance, bool allow_spheres, double time_limit, const std::string& name,
               const std::string& body, const Deadline& deadline, Plan& plan)
{
    const MeshData& m = state.data;
    const size_t T = m.triangle_count(), G = m.group_count();
    plan.tolerance = tolerance;
    plan.allow_spheres = allow_spheres;
    plan.diagonal = measures_of(state).diagonal;
    if (T > budget::MAX_PRISMATIC_TRIANGLES) {
        plan.problem = name + " has " + with_commas(T) + " triangles; Convert Mesh: Prismatic takes up to " + with_commas(budget::MAX_PRISMATIC_TRIANGLES) + ". Reduce it first.";
        return;
    }
    const std::string unfit = mf::unfit(state, name);
    if (!unfit.empty()) {
        plan.problem = unfit;
        return;
    }
    {
        const Measures& whole = measures_of(state);
        if (std::fabs(whole.volume) <= 1e-12 * whole.diagonal * whole.diagonal * whole.diagonal) {
            // (The plan works on a copy at the origin: how far the body lies comes with the plan.)
            const bool run_together = plan.far && plan.floor / 4.0 >= 0.01 * whole.diagonal;
            plan.problem = run_together ? plan.far_start + ", a hundredth of its size or more: its corners have run together and it encloses no volume. " + CONVERT_NEARER
                                        : name + " encloses no volume (its triangles lie back to back): there is nothing to make a solid of.";
            return;
        }
    }
    if (G > MAX_PRISMATIC_GROUPS) {
        plan.problem = name + " has " + with_commas(G) + " face groups; Convert Mesh: Prismatic looks at up to " + with_commas(MAX_PRISMATIC_GROUPS) +
                       ". Use Generate Face Groups (Accurate), or Convert Mesh: Faceted.";
        return;
    }
    int64_t solid_parts = 0;
    for (const Component& c : nested_components_of(state)->list) {
        solid_parts += c.depth >= 0 && c.depth % 2 == 0 ? 1 : 0;
    }
    if (solid_parts != 1) {
        plan.problem = name + " is " + with_commas(uint64_t(solid_parts)) + " separate solids; Convert Mesh: Prismatic takes one at a time. Separate it first.";
        return;
    }
    const GroupIndex& gi = group_index_of(state);
    // Largest groups first: the largest group on a surface decides where the surface lies.
    std::vector<double> areas(G, 0.0);
    for (size_t t = 0; t < T; ++t) {
        areas[m.groups[t]] += 0.5 * length(triangle_cross(m, t));
    }
    std::vector<uint32_t> order(G);
    for (size_t g = 0; g < G; ++g) {
        order[g] = uint32_t(g);
    }
    std::stable_sort(order.begin(), order.end(), [&](uint32_t a, uint32_t b) { return areas[a] > areas[b]; });
    plan.surface_of_group.assign(G, -1);
    // Which way each group faces (its triangles' summed normal), and where each flat group's
    // own plane lies: two sides of a thin wall must not fall on one surface.
    std::vector<P3> facing(G);
    for (size_t t = 0; t < T; ++t) {
        facing[m.groups[t]] += triangle_cross(m, t);
    }
    std::vector<Prim> own(G);
    // Directions already in use (the axes first): a new normal or axis next to one of them
    // takes it, when that costs the fit next to nothing. Parts that were drawn square come
    // out square.
    std::vector<P3> directions = {P3(1, 0, 0), P3(0, 1, 0), P3(0, 0, 1)};
    auto snapped = [&](const P3& d, bool& found) {
        found = false;
        P3 best = d;
        double most = std::cos(0.02);
        for (const P3& known : directions) {
            const double c = dot(d, known);
            if (std::fabs(c) > most) {
                most = std::fabs(c);
                best = c > 0.0 ? known : known * -1.0;
                found = true;
            }
        }
        return best;
    };
    // ... or square to them: a direction all but across one already in use is set exactly
    // across it (across two of them: along the line across both). The fits of a square part's
    // faces are each a hair off (as much as the mesh's stored corners are); a round that
    // touches a flat face touches it along a line only when its axis lies exactly in it.
    auto squared = [&](const P3& d, bool& found) {
        found = false;
        const double least = std::sin(0.02);
        const P3* first = nullptr;
        const P3* second = nullptr;
        for (const P3& known : directions) {
            if (std::fabs(dot(d, known)) >= least) {
                continue;
            }
            if (first == nullptr) {
                first = &known;
            }
            else if (std::fabs(dot(*first, known)) < 0.999) {
                second = &known;
                break;
            }
        }
        if (first == nullptr) {
            return d;
        }
        P3 out = second != nullptr ? cross(*first, *second) : d - *first * dot(d, *first);
        if (!(length(out) > 1e-9)) {
            return d;
        }
        out = normalized(out);
        found = true;
        return dot(out, d) < 0.0 ? out * -1.0 : out;
    };
    for (const uint32_t g : order) {
        if (deadline.expired()) {
            plan.timed_out = true;
            return;
        }
        const uint32_t* tris = &gi.tris[gi.first[g]];
        const size_t count = gi.first[size_t(g) + 1] - gi.first[g];
        if (count == 0) {
            continue;
        }
        bool any_area = false;
        for (size_t k = 0; k < count && !any_area; ++k) {
            any_area = !without_area(m, tris[k]);
        }
        if (!any_area || !(areas[g] > 0.0)) {
            // A group of triangles without area (by the shared rule, mesh::without_area) is no
            // surface of its own; their corners lie on their neighbours'.
            ++plan.skipped_groups;
            continue;
        }
        PackedInt32Array list;
        list.resize(int64_t(count));
        std::memcpy(list.ptrw(), tris, count * sizeof(uint32_t));
        const Dictionary fitted = fit(list);
        Prim candidates[3];
        double errors[3] = {kInf, kInf, kInf};
        {
            const Dictionary plane = fitted.get("plane", Dictionary());
            if (bool(plane.get("valid", false))) {
                candidates[0].kind = 0;
                candidates[0].point = p3(Vector3(plane["point"]));
                candidates[0].axis = normalized(p3(Vector3(plane["normal"])));
                recentre_plane(m, tris, count, candidates[0]);
                errors[0] = prim_error(m, tris, count, candidates[0]);
            }
            const Dictionary cylinder = fitted.get("cylinder", Dictionary());
            if (bool(cylinder.get("valid", false))) {
                candidates[1].kind = 1;
                candidates[1].point = p3(Vector3(cylinder["point"]));
                candidates[1].axis = normalized(p3(Vector3(cylinder["axis"])));
                candidates[1].radius = double(cylinder["radius"]);
                errors[1] = prim_error(m, tris, count, candidates[1]);
            }
            const Dictionary sphere = fitted.get("sphere", Dictionary());
            if (allow_spheres && bool(sphere.get("valid", false))) {
                candidates[2].kind = 2;
                candidates[2].point = p3(Vector3(sphere["center"]));
                candidates[2].radius = double(sphere["radius"]);
                errors[2] = prim_error(m, tris, count, candidates[2]);
            }
        }
        // The simplest primitive within the tolerance: plane, then cylinder, then sphere.
        int chosen = -1;
        for (int k = 0; k < 3 && chosen < 0; ++k) {
            if (errors[k] <= tolerance) {
                chosen = k;
            }
        }
        if (chosen < 0) {
            int best = 0;
            for (int k = 1; k < 3; ++k) {
                if (errors[k] < errors[best]) {
                    best = k;
                }
            }
            // The group is all but flat or round when a larger Fit Tolerance (one the field
            // takes) would let it pass, and the result would still hold the body's volume: what
            // the group lies off its surface by, over its area, against the 0.5 % of the check.
            const Measures& whole = measures_of(state);
            const bool nearly = std::isfinite(errors[best]) && errors[best] <= whole.diagonal / 20.0 && 0.6 * areas[g] * errors[best] <= 0.004 * std::fabs(whole.volume);
            const std::string not_fit = "Face Group " + plan.group_number(g) + " is not flat or round within " + plan.mm(tolerance) +
                                        (std::isfinite(errors[best]) ? std::string(" (best: ") + kind_word(best) + ", off by " + plan.mm(errors[best]) + ")"
                                                                     : std::string(" (no plane, cylinder or sphere could be fitted to it)"));
            if (plan.far && std::isfinite(errors[best]) && errors[best] <= plan.floor) {
                // Off by no more than the stored corners can hold where the body lies: the
                // distance from the origin is the cause, and no grouping changes it.
                plan.problem = not_fit + ": " + plan.far_text + "." +
                               (nearly ? " Raise the Fit Tolerance to " + plan.mm(errors[best] * 1.0005) + " or more, or convert the mesh before it is placed this far from the origin and move the converted body there."
                                       : std::string(" ") + CONVERT_NEARER);
                return;
            }
            if (G - plan.skipped_groups < 2 && plan.surfaces.empty()) {
                // One face group: what helps depends on whether Generate Face Groups (Accurate)
                // would split it, which settle_one_group() finds out (the sentence here stands
                // when it cannot).
                plan.one_group = true;
                plan.nearly = nearly;
                plan.best_kind = best;
                plan.best_error = errors[best];
                plan.best_volume_change = std::fabs(whole.volume) > 0.0 ? 0.6 * areas[g] * errors[best] / std::fabs(whole.volume) : 1.0;
            }
            if (G - plan.skipped_groups < 2 && plan.surfaces.empty() && !nearly) {
                // One face group that is not one flat or round area.
                plan.problem = "Generate Face Groups first, so each flat or round area is its own group.";
                return;
            }
            plan.problem = not_fit;
            if (nearly) {
                plan.problem += ". Raise the Fit Tolerance to " + plan.mm(errors[best] * 1.0005) + " or more, use Generate Face Groups (Accurate), or Convert Mesh: Faceted.";
            }
            else {
                plan.problem += ". Use Generate Face Groups (Accurate) or Convert Mesh: Faceted.";
            }
            return;
        }
        Prim prim = candidates[chosen];
        double error = errors[chosen];
        own[g] = prim;
        // A surface that is already there, when the group lies on it within the tolerance
        // (coplanar planes, coaxial equal cylinders, equal spheres).
        int joined = -1;
        double least = kInf;
        for (size_t s = 0; s < plan.surfaces.size(); ++s) {
            const Prim& other = plan.surfaces[s].prim;
            if (other.kind != prim.kind) {
                continue;
            }
            if (prim.kind != 2 && std::fabs(dot(other.axis, prim.axis)) < 0.999) {
                continue;
            }
            if (prim.kind != 0 && std::fabs(other.radius - prim.radius) > 2.0 * tolerance) {
                continue;
            }
            const double e = prim_error(m, tris, count, other);
            if (e <= tolerance && e < least) {
                least = e;
                joined = int(s);
            }
        }
        if (joined >= 0 && prim.kind == 0) {
            // Two flat groups that face opposite ways and lie apart, on one plane: the two
            // sides of a wall (or a gap) no thicker than the tolerance.
            const uint32_t first = plan.surfaces[size_t(joined)].groups[0];
            const double apart = std::fabs(dot(own[g].point - own[first].point, plan.surfaces[size_t(joined)].prim.axis));
            if (dot(facing[g], facing[first]) < 0.0 && apart > 0.05 * tolerance) {
                plan.problem = "Face Group " + plan.group_number(first) + " and Face Group " + plan.group_number(g) + " are " + plan.mm(apart) +
                               " apart, the two sides of a wall no thicker than the Fit Tolerance (" + plan.mm(tolerance) + "). Lower the Fit Tolerance below " +
                               plan.mm(apart) + ".";
                return;
            }
        }
        if (joined >= 0) {
            Surface& surface = plan.surfaces[size_t(joined)];
            surface.groups.push_back(g);
            surface.area += areas[g];
            surface.error = std::max(surface.error, least);
            plan.surface_of_group[g] = joined;
            continue;
        }
        if (prim.kind != 2) {
            bool found = false;
            Prim square = prim;
            square.axis = snapped(prim.axis, found);
            if (!found) {
                square.axis = squared(prim.axis, found);
            }
            if (found) {
                if (square.kind == 0) {
                    recentre_plane(m, tris, count, square);
                }
                const double e = prim_error(m, tris, count, square);
                if (e <= tolerance && e <= error + 0.1 * tolerance) {
                    prim = square;
                    error = e;
                }
            }
            bool known = false;
            for (const P3& d : directions) {
                known = known || std::fabs(dot(d, prim.axis)) > 1.0 - 1e-15;
            }
            if (!known) {
                directions.push_back(prim.axis);
            }
        }
        Surface surface;
        surface.prim = prim;
        surface.groups.push_back(g);
        surface.area = areas[g];
        surface.error = error;
        plan.surface_of_group[g] = int32_t(plan.surfaces.size());
        plan.surfaces.push_back(std::move(surface));
        if (plan.surfaces.size() > budget::MAX_PRISMATIC_SURFACES) {
            // (There may be more: the count stops here.)
            plan.problem = name + " needs more than " + with_commas(budget::MAX_PRISMATIC_SURFACES) + " surfaces; Prismatic takes up to " +
                           with_commas(budget::MAX_PRISMATIC_SURFACES) + ". Combine face groups to make fewer surfaces, or use Convert Mesh: Faceted.";
            return;
        }
    }
    if (plan.surfaces.empty()) {
        plan.problem = name + " has no face group with area.";
        return;
    }
    // Whether every group of a surface lies on a changed primitive within the tolerance.
    auto still_fits = [&](const Surface& surface, const Prim& changed, double& worst) {
        worst = 0.0;
        for (const uint32_t g : surface.groups) {
            const double e = prim_error(m, &gi.tris[gi.first[g]], gi.first[size_t(g) + 1] - gi.first[g], changed);
            worst = std::max(worst, e);
            if (!(e <= tolerance)) {
                return false;
            }
        }
        return true;
    };
    // Cylinders of all but one radius get one radius (holes of one drill, pipes of one size):
    // two crossing cylinders of exactly one radius whose axes meet cut each other in two
    // ellipses, which the kernel knows as such; a hair apart they leave a neck a hair wide,
    // which neither the cells nor the mesher can be trusted with. Within plan.snap only.
    for (size_t j = 0; j < plan.surfaces.size(); ++j) {
        Surface& later = plan.surfaces[j];
        if (later.prim.kind != 1) {
            continue;
        }
        for (size_t i = 0; i < j; ++i) {
            const Prim& first = plan.surfaces[i].prim;
            if (first.kind != 1 || first.radius == later.prim.radius || std::fabs(first.radius - later.prim.radius) > plan.snap) {
                continue;
            }
            Prim same = later.prim;
            same.radius = first.radius;
            double worst = 0.0;
            if (still_fits(later, same, worst)) {
                if (std::fabs(first.radius - later.prim.radius) > 0.1 * tolerance) {
                    Plan::MadeEqual told;
                    told.changed = later.groups[0];
                    told.kept = plan.surfaces[i].groups[0];
                    told.was = later.prim.radius;
                    told.now = first.radius;
                    plan.made_equal.push_back(told);
                }
                later.prim = same;
                later.error = worst;
                ++plan.equal_radii;
            }
            break;
        }
    }
    std::vector<uint8_t> touched(plan.surfaces.size(), 0);
    // A round surface that all but touches a flat one along a line (a rounded edge) is set to
    // touch it exactly: the fits leave them a hair apart or a hair into each other (as much
    // as the mesh's stored corners are off), and the cells then lose the round or gain a
    // sliver. Only within plan.snap, far less than the tolerance, and only when every group
    // of the round surface still lies on it.
    for (Surface& round : plan.surfaces) {
        if (round.prim.kind != 1) {
            continue;
        }
        Prim moved = round.prim;
        P3 u, v;
        frame_across(moved.axis, u, v);
        // Least squares over the flat surfaces it touches, for the axis' place across itself.
        double a11 = 0.0, a12 = 0.0, a22 = 0.0, b1 = 0.0, b2 = 0.0;
        size_t touches = 0;
        for (const Surface& flat : plan.surfaces) {
            if (flat.prim.kind != 0 || std::fabs(dot(flat.prim.axis, moved.axis)) > 1e-6) {
                continue;
            }
            const double d = dot(moved.point - flat.prim.point, flat.prim.axis);
            const double gap = std::fabs(d) - moved.radius;
            if (std::fabs(gap) > plan.snap) {
                continue;
            }
            // Move the axis along the plane's normal by -gap on its own side.
            const double side = d >= 0.0 ? 1.0 : -1.0;
            const double nu = dot(flat.prim.axis, u) * side, nv = dot(flat.prim.axis, v) * side;
            a11 += nu * nu;
            a12 += nu * nv;
            a22 += nv * nv;
            b1 += nu * -gap;
            b2 += nv * -gap;
            ++touches;
        }
        if (touches == 0) {
            continue;
        }
        // (A hair on the diagonal: with one plane, or parallel ones, only the move along their
        // normal is asked for, and the axis stays where it is across it.)
        const double hair = 1e-9 * (a11 + a22);
        a11 += hair;
        a22 += hair;
        const double det = a11 * a22 - a12 * a12;
        const double du = (b1 * a22 - b2 * a12) / det;
        const double dv = (a11 * b2 - a12 * b1) / det;
        moved.point = moved.point + u * du + v * dv;
        bool holds = std::sqrt(du * du + dv * dv) <= 2.0 * plan.snap;
        double worst = 0.0;
        for (size_t k = 0; k < round.groups.size() && holds; ++k) {
            const uint32_t g = round.groups[k];
            const double e = prim_error(m, &gi.tris[gi.first[g]], gi.first[size_t(g) + 1] - gi.first[g], moved);
            worst = std::max(worst, e);
            holds = e <= tolerance;
        }
        if (holds) {
            round.prim = moved;
            round.error = worst;
            ++plan.touching;
            touched[size_t(&round - plan.surfaces.data())] = 1;
        }
    }
    // ... and the axes of two crossing cylinders of one radius, when they all but meet, are set
    // to meet (the later, smaller one moves; one that was set to touch a flat surface stays).
    for (size_t j = 0; j < plan.surfaces.size(); ++j) {
        Surface& later = plan.surfaces[j];
        if (later.prim.kind != 1 || touched[j] != 0) {
            continue;
        }
        P3 u, v;
        frame_across(later.prim.axis, u, v);
        double a11 = 0.0, a12 = 0.0, a22 = 0.0, b1 = 0.0, b2 = 0.0;
        size_t meets = 0;
        for (size_t i = 0; i < j; ++i) {
            const Prim& first = plan.surfaces[i].prim;
            if (first.kind != 1 || first.radius != later.prim.radius) {
                continue;
            }
            const P3 across = cross(first.axis, later.prim.axis);
            const double sine = length(across);
            if (sine < 1e-6) {
                continue;
            }
            const P3 n = across * (1.0 / sine);
            // How far the axes pass each other, along the line across both.
            const double gap = dot(later.prim.point - first.point, n);
            if (gap == 0.0 || std::fabs(gap) > plan.snap) {
                continue;
            }
            const double nu = dot(n, u), nv = dot(n, v);
            a11 += nu * nu;
            a12 += nu * nv;
            a22 += nv * nv;
            b1 += nu * -gap;
            b2 += nv * -gap;
            ++meets;
        }
        if (meets == 0) {
            continue;
        }
        const double hair = 1e-9 * (a11 + a22);
        a11 += hair;
        a22 += hair;
        const double det = a11 * a22 - a12 * a12;
        const double du = (b1 * a22 - b2 * a12) / det;
        const double dv = (a11 * b2 - a12 * b1) / det;
        Prim moved = later.prim;
        moved.point = moved.point + u * du + v * dv;
        double worst = 0.0;
        if (std::sqrt(du * du + dv * dv) <= 2.0 * plan.snap && still_fits(later, moved, worst)) {
            later.prim = moved;
            later.error = worst;
            ++plan.meeting_axes;
        }
    }
    for (const Surface& s : plan.surfaces) {
        plan.planes += s.prim.kind == 0 ? 1 : 0;
        plan.cylinders += s.prim.kind == 1 ? 1 : 0;
        plan.spheres += s.prim.kind == 2 ? 1 : 0;
    }
    // What the cell building will cost: by the pairs of round surfaces whose intersection is a
    // curve OpenCASCADE has to walk (two cylinders that are not parallel and pass within
    // r1 + r2; a cylinder and a sphere that cut each other), and by the corners where three
    // flat surfaces meet near the body (each closes cells).
    const Reach reach = reach_of(state);
    const size_t S = plan.surfaces.size();
    for (size_t i = 0; i < S; ++i) {
        const Prim& a = plan.surfaces[i].prim;
        if (a.kind == 0) {
            continue;
        }
        for (size_t j = i + 1; j < S; ++j) {
            const Prim& b = plan.surfaces[j].prim;
            if (b.kind == 0) {
                continue;
            }
            if (a.kind == 1 && b.kind == 1) {
                const P3 across = cross(a.axis, b.axis);
                const double sine = length(across);
                if (sine < 1e-6) {
                    continue;  // parallel: they meet in straight lines, if at all
                }
                const P3 between = b.point - a.point;
                if (std::fabs(dot(between, across)) / sine >= a.radius + b.radius) {
                    continue;
                }
                // Where the axes pass each other: only inside the faces' reach.
                const double along = dot(cross(between, b.axis), across) / (sine * sine);
                if (length(a.point + a.axis * along - reach.centre) > reach.radius + a.radius + b.radius) {
                    continue;
                }
                ++plan.crossing_pairs;
            }
            else if (a.kind == 2 && b.kind == 2) {
                continue;  // two spheres meet in a circle
            }
            else {
                const Prim& cyl = a.kind == 1 ? a : b;
                const Prim& sph = a.kind == 1 ? b : a;
                const P3 q = sph.point - cyl.point;
                const double off = length(q - cyl.axis * dot(q, cyl.axis));
                if (off < cyl.radius + sph.radius && off + sph.radius > cyl.radius && off > 1e-9 * (cyl.radius + sph.radius)) {
                    ++plan.crossing_pairs;
                }
            }
        }
    }
    {
        std::vector<const Prim*> flat;
        for (const Surface& s : plan.surfaces) {
            if (s.prim.kind == 0) {
                flat.push_back(&s.prim);
            }
        }
        const size_t P = flat.size();
        for (size_t i = 0; i < P; ++i) {
            for (size_t j = i + 1; j < P; ++j) {
                const P3 nij = cross(flat[i]->axis, flat[j]->axis);
                if (length(nij) < 1e-6) {
                    continue;
                }
                for (size_t k = j + 1; k < P; ++k) {
                    const double det = dot(nij, flat[k]->axis);
                    if (std::fabs(det) < 1e-6) {
                        continue;
                    }
                    // The point on all three planes.
                    const double di = dot(flat[i]->axis, flat[i]->point), dj = dot(flat[j]->axis, flat[j]->point), dk = dot(flat[k]->axis, flat[k]->point);
                    const P3 x = (cross(flat[j]->axis, flat[k]->axis) * di + cross(flat[k]->axis, flat[i]->axis) * dj + nij * dk) * (1.0 / det);
                    if (length(x - reach.centre) <= reach.radius) {
                        ++plan.corners;
                    }
                }
            }
            if (deadline.expired()) {
                plan.timed_out = true;
                return;
            }
        }
    }
    plan.seconds = convert::prismatic_seconds(double(T), double(S), double(plan.crossing_pairs), double(plan.corners));
    if (plan.seconds > time_limit) {
        plan.problem = std::string(PRISMATIC) + " would take about " + number_text(plan.seconds, plan.seconds < 10.0 ? "%.2g" : "%.0f") + " s on " + body + " (limit " +
                       number_text(time_limit) + " s): ";
        const double by_pairs = budget::PRISMATIC_SECONDS_PER_CROSSING_PAIR * double(plan.crossing_pairs);
        if (plan.crossing_pairs > 0 && by_pairs >= 0.5 * plan.seconds) {
            plan.problem += with_commas(plan.crossing_pairs) + (plan.crossing_pairs == 1 ? " pair of round holes crosses" : " pairs of round holes cross") + ". Use Convert Mesh: Faceted.";
        }
        else {
            plan.problem += "its " + with_commas(S) + " surfaces cut each other into too many cells. Combine face groups to make fewer surfaces, or use Convert Mesh: Faceted.";
        }
    }
}

// ---------------------------------------------------------------- Prismatic: cells

/// Each surface as a large face (3.4.2 step 4): planes as squares, cylinders along their axis,
/// spheres whole, all reaching past the body's grown box. The squares are turned and sized a
/// little differently from each other, so that no two of their outlines lie on each other.
TopTools_ListOfShape large_faces(const Plan& plan, const Reach& reach, std::vector<Handle(Geom_Surface)>& geometry)
{
    TopTools_ListOfShape faces;
    geometry.clear();
    size_t index = 0;
    for (const Surface& s : plan.surfaces) {
        const Prim& prim = s.prim;
        const double size = reach.radius * (1.0 + 0.013 * double(index % 7));
        ++index;
        if (prim.kind == 0) {
            const P3 origin = reach.centre - prim.axis * dot(reach.centre - prim.point, prim.axis);
            P3 u, v;
            frame_across(prim.axis, u, v);
            const double turn = 0.3 + 0.61803398875 * double(index);
            const P3 x = u * std::cos(turn) + v * std::sin(turn);
            const Handle(Geom_Plane) plane = new Geom_Plane(gp_Ax3(pnt(origin), gp_Dir(prim.axis.x, prim.axis.y, prim.axis.z), gp_Dir(x.x, x.y, x.z)));
            faces.Append(BRepBuilderAPI_MakeFace(plane, -size, size, -size, size, BUILD_TOLERANCE).Face());
            geometry.push_back(plane);
        }
        else if (prim.kind == 1) {
            const P3 origin = prim.point + prim.axis * dot(reach.centre - prim.point, prim.axis);
            P3 u, v;
            frame_across(prim.axis, u, v);
            const Handle(Geom_CylindricalSurface) cylinder =
                    new Geom_CylindricalSurface(gp_Ax3(pnt(origin), gp_Dir(prim.axis.x, prim.axis.y, prim.axis.z), gp_Dir(u.x, u.y, u.z)), prim.radius);
            faces.Append(BRepBuilderAPI_MakeFace(cylinder, 0.0, 2.0 * kPi, -size, size, BUILD_TOLERANCE).Face());
            geometry.push_back(cylinder);
        }
        else {
            const Handle(Geom_SphericalSurface) sphere = new Geom_SphericalSurface(gp_Ax3(pnt(prim.point), gp_Dir(0, 0, 1), gp_Dir(1, 0, 0)), prim.radius);
            faces.Append(BRepBuilderAPI_MakeFace(sphere, BUILD_TOLERANCE).Face());
            geometry.push_back(sphere);
        }
    }
    return faces;
}

/// How often the ray o + t d (t > 0) passes through triangles (9 doubles each).
size_t crossings(const std::vector<double>& tris, const P3& o, const P3& d)
{
    size_t found = 0;
    const size_t count = tris.size() / 9;
    for (size_t i = 0; i < count; ++i) {
        const double* t = &tris[i * 9];
        const P3 a(t[0], t[1], t[2]), e1(t[3] - t[0], t[4] - t[1], t[5] - t[2]), e2(t[6] - t[0], t[7] - t[1], t[8] - t[2]);
        const P3 h = cross(d, e2);
        const double det = dot(e1, h);
        if (std::fabs(det) < 1e-300) {
            continue;
        }
        const double inv = 1.0 / det;
        const P3 s = o - a;
        const double u = dot(s, h) * inv;
        if (u < 0.0 || u > 1.0) {
            continue;
        }
        const P3 q = cross(s, e1);
        const double v = dot(d, q) * inv;
        if (v < 0.0 || u + v > 1.0) {
            continue;
        }
        found += dot(e2, q) * inv > 0.0 ? 1 : 0;
    }
    return found;
}

/// How far a point is from triangles (9 doubles each).
double clearance(const std::vector<double>& tris, const P3& p)
{
    const double at[3] = {p.x, p.y, p.z};
    double least = kInf;
    const size_t count = tris.size() / 9;
    for (size_t i = 0; i < count; ++i) {
        const double* t = &tris[i * 9];
        double on[3], b1 = 0.0, b2 = 0.0;
        least = std::min(least, subd::closest_on_triangle(at, t, t + 3, t + 6, on, b1, b2));
    }
    return std::sqrt(least);
}

/// The first hit of the ray o + t d (t > least) on triangles (9 doubles each), skipping one.
double first_hit(const std::vector<double>& tris, size_t skip, const P3& o, const P3& d, double least)
{
    double best = kInf;
    const size_t count = tris.size() / 9;
    for (size_t i = 0; i < count; ++i) {
        if (i == skip) {
            continue;
        }
        const double* t = &tris[i * 9];
        const P3 a(t[0], t[1], t[2]), e1(t[3] - t[0], t[4] - t[1], t[5] - t[2]), e2(t[6] - t[0], t[7] - t[1], t[8] - t[2]);
        const P3 h = cross(d, e2);
        const double det = dot(e1, h);
        if (std::fabs(det) < 1e-300) {
            continue;
        }
        const double inv = 1.0 / det;
        const P3 s = o - a;
        const double u = dot(s, h) * inv;
        if (u < 0.0 || u > 1.0) {
            continue;
        }
        const P3 q = cross(s, e1);
        const double v = dot(d, q) * inv;
        if (v < 0.0 || u + v > 1.0) {
            continue;
        }
        const double at = dot(e2, q) * inv;
        if (at > least && at < best) {
            best = at;
        }
    }
    return best;
}

struct CellPick
{
    size_t cells = 0, kept = 0, mixed = 0, unknown = 0;
    size_t unmeshed_faces = 0;  // faces of cells the mesher gave no triangles
};

/// Picks the cells inside the mesh (3.4.2 step 5): five points per cell, each halfway along
/// a ray from the middle of a triangle of one of its faces (largest faces first) to the
/// cell's far wall; of up to sixteen such points, the five farthest from the cell's walls
/// that lie inside the cell (a ray that only brushes a wall can end on it: a point there says
/// nothing). A cell is kept when at least four of five lie inside the mesh by its winding
/// number. The cells' faces must be meshed. False when the deadline passed.
bool pick_cells(State& state, const TopoDS_Shape& cells, const Deadline& deadline, std::vector<TopoDS_Shape>& kept, CellPick& pick)
{
    std::vector<double> points;         // 3 per sample
    std::vector<uint32_t> sample_cell;  // the cell of each sample
    std::vector<TopoDS_Shape> solids;
    for (TopExp_Explorer it(cells, TopAbs_SOLID); it.More(); it.Next()) {
        solids.push_back(it.Current());
    }
    pick.cells = solids.size();
    std::vector<uint32_t> asked(solids.size(), 0);
    std::vector<double> tris;
    struct Candidate
    {
        size_t triangle;
        size_t face;
        double area;
    };
    std::vector<Candidate> all;
    std::vector<double> face_area;
    for (size_t c = 0; c < solids.size(); ++c) {
        if (deadline.expired()) {
            return false;
        }
        tris.clear();
        all.clear();
        face_area.clear();
        double lo[3] = {kInf, kInf, kInf}, hi[3] = {-kInf, -kInf, -kInf};
        double volume6 = 0.0;
        bool complete = true;
        for (TopExp_Explorer it(solids[c], TopAbs_FACE); it.More(); it.Next()) {
            const TopoDS_Face& face = TopoDS::Face(it.Current());
            if (face.Orientation() != TopAbs_FORWARD && face.Orientation() != TopAbs_REVERSED) {
                continue;
            }
            TopLoc_Location location;
            const Handle(Poly_Triangulation) mesh = BRep_Tool::Triangulation(face, location);
            if (mesh.IsNull() || mesh->NbTriangles() == 0) {
                complete = false;
                ++pick.unmeshed_faces;
                continue;
            }
            const gp_Trsf trsf = location.Transformation();
            const bool reversed = face.Orientation() == TopAbs_REVERSED;
            const size_t f = face_area.size();
            face_area.push_back(0.0);
            for (int t = 1; t <= mesh->NbTriangles(); ++t) {
                int ia = 0, ib = 0, ic = 0;
                mesh->Triangle(t).Get(ia, ib, ic);
                if (reversed) {
                    std::swap(ib, ic);
                }
                const P3 a = p3(mesh->Node(ia).Transformed(trsf)), b = p3(mesh->Node(ib).Transformed(trsf)), cc = p3(mesh->Node(ic).Transformed(trsf));
                const double area = 0.5 * length(cross(b - a, cc - a));
                if (!(area > 0.0)) {
                    continue;
                }
                all.push_back({tris.size() / 9, f, area});
                for (const P3& q : {a, b, cc}) {
                    tris.push_back(q.x);
                    tris.push_back(q.y);
                    tris.push_back(q.z);
                    lo[0] = std::min(lo[0], q.x);
                    lo[1] = std::min(lo[1], q.y);
                    lo[2] = std::min(lo[2], q.z);
                    hi[0] = std::max(hi[0], q.x);
                    hi[1] = std::max(hi[1], q.y);
                    hi[2] = std::max(hi[2], q.z);
                }
                face_area[f] += area;
                volume6 += dot(a, cross(b, cc));
            }
        }
        if (all.empty()) {
            ++pick.unknown;
            continue;
        }
        // Which way is in: the faces of a cell face out of it when its volume counts positive.
        // (A cell with a face the mesher left out has no volume to count: its faces face out
        // of it, as the cell building orients them.)
        const double inward = !complete || volume6 >= 0.0 ? -1.0 : 1.0;
        const double diagonal = std::sqrt((hi[0] - lo[0]) * (hi[0] - lo[0]) + (hi[1] - lo[1]) * (hi[1] - lo[1]) + (hi[2] - lo[2]) * (hi[2] - lo[2]));
        // Largest faces first, the largest triangle of each; then the largest triangles left.
        std::sort(all.begin(), all.end(), [&](const Candidate& x, const Candidate& y) {
            if (x.face != y.face) {
                return face_area[x.face] > face_area[y.face] || (face_area[x.face] == face_area[y.face] && x.face < y.face);
            }
            return x.area > y.area || (x.area == y.area && x.triangle < y.triangle);
        });
        const size_t wanted = 5, tried = 16;
        std::vector<size_t> chosen;
        for (size_t i = 0; i < all.size() && chosen.size() < tried / 2; ++i) {
            if (i == 0 || all[i].face != all[i - 1].face) {
                chosen.push_back(i);
            }
        }
        if (chosen.size() < tried && chosen.size() < all.size()) {
            std::vector<size_t> rest;
            for (size_t i = 0; i < all.size(); ++i) {
                if (std::find(chosen.begin(), chosen.end(), i) == chosen.end()) {
                    rest.push_back(i);
                }
            }
            const size_t take = std::min(rest.size(), tried - chosen.size());
            std::partial_sort(rest.begin(), rest.begin() + std::ptrdiff_t(take), rest.end(),
                              [&](size_t x, size_t y) { return all[x].area > all[y].area || (all[x].area == all[y].area && x < y); });
            for (size_t i = 0; i < take; ++i) {
                chosen.push_back(rest[i]);
            }
        }
        struct Sample
        {
            P3 at;
            double clear;
            bool inside;
        };
        std::vector<Sample> samples;
        // (Two fixed directions that lie along nothing in particular.)
        const P3 look_a = normalized(P3(0.5711, 0.3137, 0.7583)), look_b = normalized(P3(-0.4127, 0.8311, -0.3719));
        for (size_t k = 0; k < chosen.size(); ++k) {
            const size_t i = chosen[k];
            const double* t = &tris[all[i].triangle * 9];
            const P3 a(t[0], t[1], t[2]), b(t[3], t[4], t[5]), cc(t[6], t[7], t[8]);
            const P3 middle = (a + b + cc) * (1.0 / 3.0);
            const P3 direction = normalized(cross(b - a, cc - a)) * inward;
            const double wall = first_hit(tris, all[i].triangle, middle, direction, 1e-9 * diagonal);
            const double step = std::isfinite(wall) ? 0.5 * wall : 1e-3 * diagonal;
            Sample sample;
            sample.at = middle + direction * step;
            sample.clear = clearance(tris, sample.at);
            // Inside the cell: a ray from the point leaves through its walls an odd number of
            // times (asked twice; a cell with a wall missing cannot be asked).
            sample.inside = !complete || (crossings(tris, sample.at, look_a) % 2 == 1 && crossings(tris, sample.at, look_b) % 2 == 1);
            samples.push_back(sample);
            // (The first five as they come are enough when they are well inside.)
            if (k + 1 == wanted) {
                bool all_good = true;
                for (const Sample& one : samples) {
                    all_good = all_good && one.inside && one.clear > 1e-3 * diagonal;
                }
                if (all_good) {
                    break;
                }
            }
        }
        std::stable_sort(samples.begin(), samples.end(), [](const Sample& x, const Sample& y) {
            if (x.inside != y.inside) {
                return x.inside;
            }
            return x.clear > y.clear;
        });
        // (When none could be shown to lie inside, the points are asked as they are.)
        const bool any_inside = !samples.empty() && samples[0].inside;
        for (size_t k = 0; k < samples.size() && asked[c] < wanted; ++k) {
            if (any_inside && !samples[k].inside) {
                break;
            }
            points.push_back(samples[k].at.x);
            points.push_back(samples[k].at.y);
            points.push_back(samples[k].at.z);
            sample_cell.push_back(uint32_t(c));
            ++asked[c];
        }
    }
    if (points.empty()) {
        return true;
    }
    if (bvh_of(state, &deadline) == nullptr) {
        return false;
    }
    std::vector<int32_t> winding;
    winding_numbers(state, points.data(), points.size() / 3, winding);
    std::vector<uint32_t> inside(solids.size(), 0);
    for (size_t i = 0; i < sample_cell.size(); ++i) {
        inside[sample_cell[i]] += winding[i] != 0 ? 1 : 0;
    }
    for (size_t c = 0; c < solids.size(); ++c) {
        if (asked[c] == 0) {
            continue;
        }
        // Four of five (and all of fewer).
        if (inside[c] * 5 >= asked[c] * 4) {
            kept.push_back(solids[c]);
            ++pick.kept;
        }
        if (inside[c] > 0 && inside[c] < asked[c]) {
            ++pick.mixed;
        }
    }
    return true;
}

/// The solid the kept cells make together: the faces that only one kept cell has are its
/// boundary (cells from one cell building share the faces between them), put together as
/// shells; the shell that counts positive is the outside, the others are voids. "" on success.
std::string solid_of_cells(const std::vector<TopoDS_Shape>& kept, TopoDS_Shape& out, size_t& positive_shells)
{
    TopTools_IndexedMapOfShape faces;
    std::vector<int> uses;
    std::vector<TopoDS_Shape> oriented;
    for (const TopoDS_Shape& cell : kept) {
        for (TopExp_Explorer it(cell, TopAbs_FACE); it.More(); it.Next()) {
            const TopoDS_Shape& face = it.Current();
            if (face.Orientation() != TopAbs_FORWARD && face.Orientation() != TopAbs_REVERSED) {
                continue;
            }
            const int index = faces.Add(face);
            if (size_t(index) > uses.size()) {
                uses.push_back(0);
                oriented.push_back(face);
            }
            ++uses[size_t(index - 1)];
        }
    }
    BRep_Builder builder;
    TopoDS_Compound boundary;
    builder.MakeCompound(boundary);
    size_t count = 0;
    for (size_t i = 0; i < uses.size(); ++i) {
        if (uses[i] == 1) {
            builder.Add(boundary, oriented[i]);
            ++count;
        }
    }
    if (count == 0) {
        return "no face is left on the outside";
    }
    TopTools_ListOfShape blocks;
    BOPTools_AlgoTools::MakeConnexityBlocks(boundary, TopAbs_EDGE, TopAbs_FACE, blocks);
    std::vector<TopoDS_Shell> outer, voids;
    for (TopTools_ListOfShape::Iterator it(blocks); it.More(); it.Next()) {
        TopoDS_Shell shell;
        builder.MakeShell(shell);
        for (TopExp_Explorer f(it.Value(), TopAbs_FACE); f.More(); f.Next()) {
            builder.Add(shell, f.Current());
        }
        shell.Closed(BRep_Tool::IsClosed(shell));
        if (!shell.Closed()) {
            return "the faces that are left do not close";
        }
        (measure::volume(shell).Mass() > 0.0 ? outer : voids).push_back(shell);
    }
    positive_shells = outer.size();
    if (outer.size() != 1) {
        return outer.empty() ? "the faces that are left enclose nothing" : "they close " + std::to_string(outer.size()) + " separate solids";
    }
    TopoDS_Solid solid;
    builder.MakeSolid(solid);
    builder.Add(solid, outer[0]);
    for (const TopoDS_Shell& shell : voids) {
        builder.Add(solid, shell);
    }
    out = solid;
    return std::string();
}

// ---------------------------------------------------------------- Prismatic: checks

/// A face of the result, ready for distances from points.
struct FaceProbe
{
    TopoDS_Face face;
    int kind = -1;
    gp_Pln plane;
    gp_Cylinder cylinder;
    gp_Sphere sphere;
    std::unique_ptr<BRepTopAdaptor_FClass2d> inside;
    double lo[3] = {0, 0, 0}, hi[3] = {0, 0, 0};
    int surface = -1;  // the fitted surface it lies on
};

/// No point of the face is nearer to p than this: the distance to the face's box, or to its
/// whole surface, whichever is more.
double least_distance(const FaceProbe& f, const P3& p)
{
    const double dx = std::max(std::max(f.lo[0] - p.x, p.x - f.hi[0]), 0.0);
    const double dy = std::max(std::max(f.lo[1] - p.y, p.y - f.hi[1]), 0.0);
    const double dz = std::max(std::max(f.lo[2] - p.z, p.z - f.hi[2]), 0.0);
    double least = std::sqrt(dx * dx + dy * dy + dz * dz);
    const gp_Pnt point = pnt(p);
    if (f.kind == 0) {
        least = std::max(least, f.plane.Distance(point));
    }
    else if (f.kind == 1) {
        least = std::max(least, std::fabs(gp_Lin(f.cylinder.Axis()).Distance(point) - f.cylinder.Radius()));
    }
    else if (f.kind == 2) {
        least = std::max(least, std::fabs(f.sphere.Location().Distance(point) - f.sphere.Radius()));
    }
    return least;
}

/// The distance from p to the face where the nearest point of its surface lies in the face;
/// infinite where it does not (the nearest point of the face is then on its outline).
double surface_distance(const FaceProbe& f, const P3& p)
{
    if (f.inside == nullptr) {
        return kInf;
    }
    const gp_Pnt point = pnt(p);
    double u = 0.0, v = 0.0;
    gp_Pnt foot;
    if (f.kind == 0) {
        ElSLib::Parameters(f.plane, point, u, v);
        foot = ElSLib::Value(u, v, f.plane);
    }
    else if (f.kind == 1) {
        ElSLib::Parameters(f.cylinder, point, u, v);
        foot = ElSLib::Value(u, v, f.cylinder);
    }
    else if (f.kind == 2) {
        ElSLib::Parameters(f.sphere, point, u, v);
        foot = ElSLib::Value(u, v, f.sphere);
    }
    else {
        return kInf;
    }
    const TopAbs_State state = f.inside->Perform(gp_Pnt2d(u, v), true);
    return state == TopAbs_IN || state == TopAbs_ON ? point.Distance(foot) : kInf;
}

/// The distance from p to the face, outline and all (the kernel's own search).
double outline_distance(const FaceProbe& f, const P3& p)
{
    BRepExtrema_DistShapeShape search(BRepBuilderAPI_MakeVertex(pnt(p)).Vertex(), f.face);
    return search.IsDone() ? search.Value() : kInf;
}

/// The fitted surface a face of the result lies on, -1 when it lies on none.
int surface_of_face(const BRepAdaptor_Surface& adaptor, const Plan& plan, double diagonal)
{
    const double close = 1e-7 * std::max(diagonal, 1e-9), parallel = 1.0 - 1e-12;
    int found = -1;
    double least = kInf;
    for (size_t s = 0; s < plan.surfaces.size(); ++s) {
        const Prim& prim = plan.surfaces[s].prim;
        double off = kInf;
        if (prim.kind == 0 && adaptor.GetType() == GeomAbs_Plane) {
            const gp_Pln plane = adaptor.Plane();
            const P3 n = p3(gp_Pnt(plane.Axis().Direction().XYZ()));
            if (std::fabs(dot(n, prim.axis)) >= parallel) {
                off = std::fabs(dot(p3(plane.Location()) - prim.point, prim.axis));
            }
        }
        else if (prim.kind == 1 && adaptor.GetType() == GeomAbs_Cylinder) {
            const gp_Cylinder cylinder = adaptor.Cylinder();
            const P3 d = p3(gp_Pnt(cylinder.Axis().Direction().XYZ()));
            if (std::fabs(dot(d, prim.axis)) >= parallel) {
                const P3 q = p3(cylinder.Location()) - prim.point;
                off = length(q - prim.axis * dot(q, prim.axis)) + std::fabs(cylinder.Radius() - prim.radius);
            }
        }
        else if (prim.kind == 2 && adaptor.GetType() == GeomAbs_Sphere) {
            const gp_Sphere sphere = adaptor.Sphere();
            off = length(p3(sphere.Location()) - prim.point) + std::fabs(sphere.Radius() - prim.radius);
        }
        if (off <= close && off < least) {
            least = off;
            found = int(s);
        }
    }
    return found;
}

/// The i-th of a run of points spread evenly in a triangle, as the weights of its corners (a
/// low-discrepancy sequence folded into the triangle; the same points on every run).
void spread(uint32_t i, double& wa, double& wb, double& wc)
{
    double u = std::fmod(0.5 + 0.7548776662466927 * double(i + 1), 1.0), v = std::fmod(0.5 + 0.5698402909980532 * double(i + 1), 1.0);
    if (u + v > 1.0) {
        u = 1.0 - u;
        v = 1.0 - v;
    }
    wa = 1.0 - u - v;
    wb = u;
    wc = v;
}

/// What the viewport will draw of a body: its faces meshed with the viewport's own settings
/// (CadShape.tessellate and core/tessellate.gd: this deflection, DISPLAY_ANGLE, not relative,
/// one thread), each face covered by its mesh, and the drawn triangles closed (every edge
/// between two of them; corners at the same place are one).
struct Drawn
{
    bool finished = false;
    size_t unmeshed = 0, uncovered = 0, open_edges = 0, triangles = 0;
};

Drawn drawn_check(const TopoDS_Shape& shape, double linear, const Deadline& deadline)
{
    Drawn out;
    if (!mesh_result(shape, linear, DISPLAY_ANGLE, deadline)) {
        return out;
    }
    struct Key
    {
        double x, y, z;
        bool operator==(const Key& o) const
        {
            return x == o.x && y == o.y && z == o.z;
        }
    };
    struct Hash
    {
        size_t operator()(const Key& k) const
        {
            uint64_t bits[3];
            std::memcpy(bits, &k, 24);
            uint64_t h = 0x51ED270B7F4A7C15ull;
            for (int i = 0; i < 3; ++i) {
                h = (h ^ bits[i]) * 0x9E3779B97F4A7C15ull;
                h ^= h >> 29;
            }
            return size_t(h);
        }
    };
    std::unordered_map<Key, uint32_t, Hash> corners;
    std::vector<std::pair<uint32_t, uint32_t>> edges;
    for (TopExp_Explorer it(shape, TopAbs_FACE); it.More(); it.Next()) {
        const TopoDS_Face& face = TopoDS::Face(it.Current());
        TopLoc_Location location;
        const Handle(Poly_Triangulation) mesh = BRep_Tool::Triangulation(face, location);
        if (mesh.IsNull() || mesh->NbTriangles() == 0) {
            ++out.unmeshed;
            continue;
        }
        if (!measure::face_drawable(face, linear, DISPLAY_ANGLE)) {
            ++out.uncovered;
        }
        const gp_Trsf trsf = location.Transformation();
        std::vector<uint32_t> ids(static_cast<size_t>(mesh->NbNodes()));
        for (int n = 1; n <= mesh->NbNodes(); ++n) {
            const gp_Pnt at = mesh->Node(n).Transformed(trsf);
            const Key key{at.X() + 0.0, at.Y() + 0.0, at.Z() + 0.0};
            ids[size_t(n - 1)] = corners.emplace(key, uint32_t(corners.size())).first->second;
        }
        for (int t = 1; t <= mesh->NbTriangles(); ++t) {
            int a = 0, b = 0, c = 0;
            mesh->Triangle(t).Get(a, b, c);
            const uint32_t v[3] = {ids[size_t(a - 1)], ids[size_t(b - 1)], ids[size_t(c - 1)]};
            if (v[0] == v[1] || v[1] == v[2] || v[2] == v[0]) {
                continue;
            }
            ++out.triangles;
            for (int k = 0; k < 3; ++k) {
                edges.emplace_back(std::min(v[k], v[(k + 1) % 3]), std::max(v[k], v[(k + 1) % 3]));
            }
        }
        if (deadline.expired()) {
            return out;
        }
    }
    std::sort(edges.begin(), edges.end());
    for (size_t at = 0; at < edges.size();) {
        size_t end = at;
        while (end < edges.size() && edges[end] == edges[at]) {
            ++end;
        }
        out.open_edges += end - at == 2 ? 0 : 1;
        at = end;
    }
    out.finished = true;
    return out;
}

String joined(const PackedStringArray& lines)
{
    return String("\n").join(lines);
}

/// How many face groups have a triangle with area.
size_t groups_with_area(const MeshData& m)
{
    std::vector<uint8_t> seen(m.group_count(), 0);
    size_t count = 0;
    for (size_t t = 0; t < m.triangle_count(); ++t) {
        const uint32_t g = m.groups[t];
        if (g < seen.size() && seen[g] == 0 && !without_area(m, t)) {
            seen[g] = 1;
            ++count;
        }
    }
    return count;
}

/// Whether Generate Face Groups (Accurate), at its defaults, splits a body (Prismatic's working
/// copy) into more than one group: 1 it does, 0 it leaves it whole, -1 not found out (no time
/// left, or it failed).
int accurate_splits(const Ref<CadMesh>& copy, const Deadline& deadline)
{
    const double seconds = std::min(deadline.remaining(), 2.0);
    if (copy.is_null() || !(seconds > 0.05)) {
        return -1;
    }
    Dictionary options;
    options["method"] = "accurate";
    options["time_limit"] = seconds;
    const Ref<CadMesh> grouped = copy->generate_groups(options);
    if (grouped.is_null()) {
        return -1;
    }
    return groups_with_area(grouped->get_state().data) > 1 ? 1 : 0;
}

/// The plan's sentence for a body of one face group that no surface fitted, once it is known
/// whether Generate Face Groups (Accurate) would split it: a sentence never sends the user to a
/// step that gives the same body back (a coarse ball stays one group, so "Generate Face Groups"
/// and "Accurate" pointed at each other).
void settle_one_group(Plan& plan, const Ref<CadMesh>& copy, const std::string& name, const Deadline& deadline)
{
    if (!plan.one_group || plan.problem.empty() || plan.timed_out) {
        return;
    }
    const int splits = accurate_splits(copy, deadline);
    if (splits < 0) {
        return;
    }
    if (splits > 0) {
        if (!plan.nearly) {
            plan.problem = "Generate Face Groups (Accurate) first, so each flat or round area is its own group.";
        }
        return;
    }
    std::string text = name + " is one smooth area that no plane, cylinder or sphere follows within " + plan.mm(plan.tolerance);
    const bool fitted = std::isfinite(plan.best_error);
    if (fitted) {
        text += std::string(" (best: ") + kind_word(plan.best_kind) + ", off by " + plan.mm(plan.best_error) + ")";
    }
    if (plan.nearly) {
        text += ". Raise the Fit Tolerance to " + plan.mm(plan.best_error * 1.0005) + " or more, or use Convert Mesh: Faceted, or Organic for a smooth solid.";
    }
    else if (fitted && plan.best_error <= plan.diagonal / 20.0) {
        text += ": a Fit Tolerance that wide would change its volume by about " + percent_text(plan.best_volume_change) +
                ". Use Convert Mesh: Faceted, or Organic for a smooth solid.";
    }
    else {
        text += ". Use Convert Mesh: Faceted, or Organic for a smooth solid.";
    }
    plan.problem = text;
}

/// A plan's place: the working copy's numbers, snap distance and how far the body lies.
void place_plan(Plan& plan, const Workplace& place, State& model, double local_tolerance, const std::string& name, const std::string& body)
{
    plan.unit = place.unit;
    plan.numbers = place.numbers;
    const double D = measures_of(place.mesh->get_state()).diagonal;
    plan.snap = std::min(0.25 * local_tolerance, std::max(2e-5 * D, 4.0 * place.floor));
    plan.far = 4.0 * place.floor > 2e-5 * D;
    plan.floor = place.floor;
    plan.far_text = far_words(model, body);
    plan.far_start = far_words(model, name);
}

}  // namespace
}  // namespace mesh

// ---------------------------------------------------------------- CadMesh: Faceted

Ref<CadShape> CadMesh::to_faceted(const Dictionary& options)
{
    using namespace mesh;
    clear_messages();
    const double started = ops::now_ms();
    Options o(options);
    const double limit = o.time_limit();
    const bool merge_flat = o.flag("merge_flat", "Merge Flat Face Groups", true);
    const std::string name = o.name(true), body = o.name(false);
    const std::string refusal = faceted_refusal(*state, name);
    if (!refusal.empty()) {
        fail(refusal);
        return Ref<CadShape>();
    }
    const Measures& ms = measures_of(*state);
    const double D = ms.diagonal;
    const double flat_tolerance = o.number("flat_tolerance", "Flat Tolerance", D * 1e-6);
    if (o.ok()) {
        o.range("Flat Tolerance", flat_tolerance, 0.0, D / 100.0, true);
    }
    if (!o.ok()) {
        fail(o.problem());
        return Ref<CadShape>();
    }
    const size_t T = state->data.triangle_count();
    // (With or without Merge Flat: a merged face costs less than its triangles as faces would,
    // now that a long outline is checked in one pass. Fewer triangles is what helps.)
    const char* hint = "Reduce the body first.";
    const Deadline deadline(limit);
    Phases phases;
    const Topology* topo = topology_of(*state, &deadline);
    if (topo == nullptr) {
        fail(ops::timed_out(FACETED, limit, hint));
        return Ref<CadShape>();
    }
    const bool closed = topo->boundary_edges == 0;
    std::vector<Patch> patches;
    std::vector<uint32_t> patch_of(T, NONE);
    const double floor = faceted_floor(ms);
    size_t near_flat = 0;
    if (merge_flat && !find_patches(*state, *topo, flat_tolerance, floor, deadline, patches, patch_of, near_flat)) {
        fail(ops::timed_out(FACETED, limit, hint));
        return Ref<CadShape>();
    }
    phases.mark("patches");
    // The estimate, from the faces the result will have (the patches are found in a few
    // milliseconds): refused here only when even the expected time would not fit, since the
    // rest stops on time.
    const double estimate = faceted_estimate(patches, patch_of);
    if (estimate > limit && !o.skip_estimate()) {
        fail(ops::too_slow(FACETED, estimate, limit, hint));
        return Ref<CadShape>();
    }
    Faceted made;
    Dictionary checks;
    PackedStringArray warnings;
    double brep_volume = 0.0, brep_area = 0.0;
    size_t undrawable = 0, unmeshed = 0;
    try {
        std::string error;
        const Outcome outcome = build_faceted(*state, *topo, patches, patch_of, closed, deadline, made, error);
        if (outcome != Outcome::Ok) {
            fail(outcome == Outcome::TimedOut ? ops::timed_out(FACETED, limit, hint) : error);
            return Ref<CadShape>();
        }
        phases.mark("build");
        const double F = double(made.faces.size());
        // The kernel's own check, face by face (each with its wires, edges and corners), so
        // that it can be stopped; then the shells and solids as a whole, which cannot be, and
        // is not started when it would not fit.
        // (A merged face with a long outline is checked piece by piece: the kernel's check of
        // a whole face cannot be stopped and grows with the square of the outline.)
        size_t bad = 0;
        double outline_squares = 0.0;
        for (size_t i = 0; i < made.faces.size(); ++i) {
            const TopoDS_Face& face = made.faces[i];
            outline_squares += double(made.outline[i]) * double(made.outline[i]);
            bool stopped = false;
            if (made.outline[i] <= MAX_OUTLINE_FOR_KERNEL_CHECK) {
                bad += BRepCheck_Analyzer(face, true).IsValid() ? 0 : 1;
            }
            else {
                bad += long_face_valid(face, deadline, stopped) || stopped ? 0 : 1;
            }
            if (stopped || deadline.expired()) {
                fail(ops::timed_out(FACETED, limit, hint));
                return Ref<CadShape>();
            }
        }
        phases.mark("valid_faces");
        if (budget::FACETED_CHECK_SECONDS_PER_1K_FACES * F / 1000.0 > deadline.remaining()) {
            fail(ops::timed_out(FACETED, limit, hint));
            return Ref<CadShape>();
        }
        // (The kernel's check of the shells and solids themselves: every shell in one piece,
        // closed where the mesh is, its faces all facing one way; every solid's shells in
        // their places. The whole-shape analyzer would check every face a second time.)
        bool whole = true;
        const bool long_outlines = outline_squares > MAX_OUTLINE_SQUARES_FOR_KERNEL_SHELL;
        for (TopExp_Explorer it(made.shape, TopAbs_SHELL); it.More() && whole; it.Next()) {
            const TopoDS_Shell& piece = TopoDS::Shell(it.Current());
            const Handle(BRepCheck_Shell) shell = new BRepCheck_Shell(piece);
            whole = shell->Status().First() == BRepCheck_NoError;
            if (whole && long_outlines) {
                whole = shell_sound(piece, closed);
            }
            else if (whole) {
                whole = (!closed || shell->Closed() == BRepCheck_NoError) && shell->Orientation() == BRepCheck_NoError;
            }
        }
        for (TopExp_Explorer it(made.shape, TopAbs_SOLID); it.More() && whole; it.Next()) {
            const Handle(BRepCheck_Solid) solid = new BRepCheck_Solid(TopoDS::Solid(it.Current()));
            whole = solid->Status().First() == BRepCheck_NoError;
        }
        if (bad > 0 || !whole) {
            fail("The converted body failed the solid check" + (bad > 0 ? " at " + with_commas(bad) + (bad == 1 ? " face" : " faces") : std::string()) + ". " +
                 (merge_flat && !patches.empty() ? "Turn off Merge Flat Face Groups, or run Stitch and Remove on " : "Run Stitch and Remove on ") + body + " first.");
            checks["valid"] = "fail: the kernel's validity check";
            last_report["op"] = "to_faceted";
            last_report["checks"] = checks;
            return Ref<CadShape>();
        }
        checks["valid"] = "ok";
        phases.mark("valid");
        if (deadline.expired()) {
            fail(ops::timed_out(FACETED, limit, hint));
            return Ref<CadShape>();
        }
        // Volume and area against the mesh's: the same triangles, so they agree to rounding,
        // but for what merged faces moved (at most their area times how far their corners
        // lie off their planes).
        if (budget::FACETED_MEASURE_SECONDS_PER_1K_FACES * F / 1000.0 > deadline.remaining()) {
            fail(ops::timed_out(FACETED, limit, hint));
            return Ref<CadShape>();
        }
        // (A closed body by its volume, an open one by its area: each is a pass over every
        // face.)
        if (closed) {
            brep_volume = measure::volume(made.shape).Mass();
        }
        else {
            brep_area = measure::surface(made.shape).Mass();
        }
        phases.mark("measure");
        const double moved = 2.0 * made.merged_area * made.max_deviation;
        if (closed) {
            const double reference = std::fabs(ms.volume);
            const double off = std::fabs(brep_volume - ms.volume);
            const double allowed = std::min(0.01 * reference, 1e-4 * reference + moved);
            if (!(off <= allowed)) {
                const std::string text = "The converted body's volume is off by " + percent_text(reference > 0.0 ? off / reference : 1.0) + " from " + body + "'s (limit " +
                                         percent_text(reference > 0.0 ? allowed / reference : 0.0) + "). " +
                                         (made.max_deviation > 0.0 ? "Lower the Flat Tolerance." : "Please report it.");
                fail(text);
                checks["volume"] = String("fail: ") + ops::text(text);
                last_report["op"] = "to_faceted";
                last_report["checks"] = checks;
                return Ref<CadShape>();
            }
            checks["volume"] = "ok";
        }
        else {
            // (An open body by its area: the triangles', with each merged face flat.)
            const double off = std::fabs(brep_area - made.area);
            if (!(off <= 1e-6 * made.area)) {
                const std::string text = "The converted body's surface is off by " + percent_text(made.area > 0.0 ? off / made.area : 1.0) + " from " + body + "'s (internal error). Please report it.";
                fail(text);
                checks["area"] = String("fail: ") + ops::text(text);
                last_report["op"] = "to_faceted";
                last_report["checks"] = checks;
                return Ref<CadShape>();
            }
            checks["area"] = "ok";
        }
        // Every face has its drawn mesh already (the mesh's own triangles); a merged face's
        // must cover the face its wires enclose.
        const double linear = display_deflection(D);
        for (size_t i = 0; i < made.faces.size(); ++i) {
            TopLoc_Location location;
            const Handle(Poly_Triangulation) drawn = BRep_Tool::Triangulation(made.faces[i], location);
            if (drawn.IsNull() || drawn->NbTriangles() == 0) {
                ++unmeshed;
            }
            else if (made.merged[i] != 0 && !measure::face_drawable(made.faces[i], linear, DISPLAY_ANGLE)) {
                ++undrawable;
            }
            if (deadline.tick()) {
                fail(ops::timed_out(FACETED, limit, hint));
                return Ref<CadShape>();
            }
        }
        phases.mark("coverage");
        if (unmeshed + undrawable > 0) {
            const size_t n = unmeshed + undrawable;
            const std::string text = with_commas(n) + (n == 1 ? " face" : " faces") + " of the converted body would be drawn wrong (" +
                                     (unmeshed > 0 ? with_commas(unmeshed) + " got no triangles" : std::string()) + (unmeshed > 0 && undrawable > 0 ? ", " : "") +
                                     (undrawable > 0 ? with_commas(undrawable) + " not covered by theirs" : std::string()) + "). " +
                                     (undrawable > 0 ? "Turn off Merge Flat Face Groups." : "Run Stitch and Remove on " + body + " first.");
            fail(text);
            checks["coverage"] = String("fail: ") + ops::text(text);
            last_report["op"] = "to_faceted";
            last_report["checks"] = checks;
            return Ref<CadShape>();
        }
        checks["coverage"] = "ok";
    }
    catch (const Standard_Failure& failure) {
        fail(kernel_error(FACETED, failure));
        return Ref<CadShape>();
    }
    catch (const std::exception& e) {
        fail(std::string(FACETED) + " failed: " + e.what() + ".");
        return Ref<CadShape>();
    }
    if (!closed) {
        const std::string text = name + " is open, so the result is a surface body.";
        warnings.push_back(ops::text(text));
        checks["closed"] = String("warn: ") + ops::text(text);
    }
    else {
        checks["closed"] = "ok";
    }
    if (made.repeated > 0) {
        const std::string text = (made.repeated == 1 ? std::string("1 piece of ") + body + " lies" : with_commas(made.repeated) + " pieces of " + body + " lie") +
                                 " in the same place as another piece, so the result holds " + (made.repeated == 1 ? "it" : "them") +
                                 " twice. Run Stitch and Remove first.";
        warnings.push_back(ops::text(text));
        checks["repeated"] = String("warn: ") + ops::text(text);
    }
    if (near_flat > 0) {
        const std::string text = (near_flat == 1 ? std::string("1 flat area of ") : with_commas(near_flat) + " flat areas of ") + body +
                                 (near_flat == 1 ? " was" : " were") + " not merged: this far from the origin the mesh's corners are stored only to about " +
                                 ops::length_text(floor) +
                                 (floor <= D / 100.0 ? ", more than the Flat Tolerance. Raise the Flat Tolerance to " + ops::length_text(floor) + " or more."
                                                     : ", more than the Flat Tolerance can be (" + ops::length_text(D / 100.0) + "). Move the body nearer the origin first.");
        warnings.push_back(ops::text(text));
        checks["flat"] = String("warn: ") + ops::text(text);
    }
    // The faces' names, in the order the shape lists its faces.
    Ref<CadShape> result = CadShape::wrap(made.shape);
    {
        std::unordered_map<const void*, size_t> index;
        index.reserve(made.faces.size() * 2);
        for (size_t i = 0; i < made.faces.size(); ++i) {
            index[made.faces[i].TShape().get()] = i;
        }
        const TopTools_IndexedMapOfShape& listed = result->face_map();
        result->face_name_list.assign(size_t(listed.Extent()), std::string());
        for (int i = 1; i <= listed.Extent(); ++i) {
            const auto found = index.find(listed(i).TShape().get());
            result->face_name_list[size_t(i - 1)] = found != index.end() ? made.names[found->second] : "f" + std::to_string(i - 1);
        }
        naming::name_edges(*result.ptr());
    }
    phases.mark("names");
    size_t merged_faces = 0;
    for (const uint8_t flag : made.merged) {
        merged_faces += flag;
    }
    Dictionary output;
    output["faces"] = int64_t(made.faces.size());
    output["merged_faces"] = int64_t(merged_faces);
    output["triangle_faces"] = int64_t(made.faces.size() - merged_faces);
    output["edges"] = int64_t(made.edges);
    output["solids"] = int64_t(made.solids);
    output["shells"] = int64_t(made.shells);
    output["closed"] = closed;
    output["valid"] = true;
    output["volume"] = brep_volume;
    output["area"] = closed ? made.area : brep_area;
    Dictionary deviation;
    deviation["max"] = made.max_deviation;
    deviation["mean"] = 0.0;
    deviation["samples"] = int64_t(state->data.vertex_count());
    last_report["op"] = "to_faceted";
    last_report["input"] = ops::summary_dict(summarize(*state), false);
    last_report["output"] = output;
    last_report["deviation"] = deviation;
    last_report["volume_change"] = closed && ms.volume != 0.0 ? (brep_volume - ms.volume) / std::fabs(ms.volume) : 0.0;
    last_report["checks"] = checks;
    last_report["phases"] = phases.ms;
    last_report["estimate"] = estimate;
    last_report["ms"] = ops::now_ms() - started;
    if (!warnings.is_empty()) {
        last_warning = joined(warnings);
    }
    return result;
}

// ---------------------------------------------------------------- CadMesh: Prismatic

Ref<CadShape> CadMesh::to_prismatic(const Dictionary& options)
{
    using namespace mesh;
    clear_messages();
    const double started = ops::now_ms();
    Options o(options);
    const double limit = o.time_limit();
    const bool allow_spheres = o.flag("allow_spheres", "Allow Spheres", true);
    const std::string name = o.name(true), body = o.name(false);
    if (is_null()) {
        fail(name + " has no triangles.");
        return Ref<CadShape>();
    }
    const double D_model = measures_of(*state).diagonal;
    const double tolerance_model = o.number("tolerance", "Fit Tolerance", D_model / 1000.0);
    if (o.ok()) {
        o.range("Fit Tolerance", tolerance_model, D_model * 1e-6, D_model / 20.0, true);
    }
    const bool skip_estimate = o.skip_estimate();
    if (!o.ok()) {
        fail(o.problem());
        return Ref<CadShape>();
    }
    const char* hint = "Combine face groups to make fewer surfaces, or use Faceted.";
    const Deadline deadline(limit);
    Phases phases;
    // Everything below works on a copy of the body with its middle at the origin, at a size
    // the kernel works well at; the solid goes back to the body's place and size at the end.
    const Workplace place = workplace_of(*state);
    if (place.mesh.is_null()) {
        fail(std::string(PRISMATIC) + " could not copy " + body + " (" + place.problem + "). Please report it.");
        return Ref<CadShape>();
    }
    State& st = place.mesh->get_state();
    const double unit = place.unit;
    const Measures& ms = measures_of(st);
    const double D = ms.diagonal;
    const double tolerance = tolerance_model / unit;
    auto mm = [&](double length) { return ops::length_text(length * unit); };
    Plan plan;
    place_plan(plan, place, *state, tolerance, name, body);
    make_plan(
            st, [&](const PackedInt32Array& tris) { return place.mesh->fit_primitive(tris); }, tolerance, allow_spheres, skip_estimate ? kInf : limit, name, body, deadline, plan);
    settle_one_group(plan, place.mesh, name, deadline);
    // What helps when the surfaces do not make a good solid: another grouping, unless the body
    // is one face group that Generate Face Groups (Accurate) leaves whole (then a Fit Tolerance
    // only decides whether the one surface is taken, and neither step changes the result).
    const bool lone = groups_with_area(st.data) < 2;
    int lone_splits = -2;
    auto regroup = [&](bool lower) -> std::string {
        if (lone) {
            if (lone_splits == -2) {
                lone_splits = accurate_splits(place.mesh, deadline);
            }
            if (lone_splits == 0) {
                return "Use Convert Mesh: Faceted, or Organic for a smooth solid.";
            }
            if (lone_splits == 1) {
                return "Use Generate Face Groups (Accurate), or Convert Mesh: Faceted.";
            }
        }
        return lower ? "Lower the Fit Tolerance, use Generate Face Groups (Accurate), or Convert Mesh: Faceted." : "Use Generate Face Groups (Accurate), or Convert Mesh: Faceted.";
    };
    Dictionary checks;
    CellPick pick;
    auto plan_report = [&]() {
        last_report["op"] = "to_prismatic";
        last_report["surfaces"] = int64_t(plan.surfaces.size());
        last_report["planes"] = int64_t(plan.planes);
        last_report["cylinders"] = int64_t(plan.cylinders);
        last_report["spheres"] = int64_t(plan.spheres);
        last_report["crossing_pairs"] = int64_t(plan.crossing_pairs);
        last_report["corners"] = int64_t(plan.corners);
        last_report["estimate"] = plan.seconds;
        last_report["tolerance"] = tolerance_model;
        last_report["scale"] = 1.0 / unit;
        last_report["touching"] = int64_t(plan.touching);
        last_report["equal_radii"] = int64_t(plan.equal_radii);
        last_report["meeting_axes"] = int64_t(plan.meeting_axes);
        last_report["cells"] = int64_t(pick.cells);
        last_report["kept_cells"] = int64_t(pick.kept);
        last_report["mixed_cells"] = int64_t(pick.mixed);
        last_report["unknown_cells"] = int64_t(pick.unknown);
        last_report["unmeshed_cell_faces"] = int64_t(pick.unmeshed_faces);
        last_report["skipped_groups"] = int64_t(plan.skipped_groups);
        last_report["checks"] = checks;
        last_report["phases"] = phases.ms;
        last_report["ms"] = ops::now_ms() - started;
    };
    auto refuse = [&](const std::string& sentence, const char* check = nullptr) {
        fail(sentence);
        if (check != nullptr) {
            checks[check] = String("fail: ") + ops::text(sentence);
        }
        plan_report();
        return Ref<CadShape>();
    };
    if (plan.timed_out) {
        return refuse(ops::timed_out(PRISMATIC, limit, hint));
    }
    if (!plan.problem.empty()) {
        return refuse(plan.problem);
    }
    phases.mark("fit");
    const Reach reach = reach_of(st);
    TopoDS_Shape solid;
    PackedStringArray warnings;
    double brep_volume = 0.0, brep_area = 0.0;
    double mesh_to_result = 0.0, result_to_mesh = 0.0, mesh_to_result_sum = 0.0;
    int64_t mesh_samples = 0, result_samples = 0;
    std::vector<std::string> face_names;
    size_t result_planes = 0, result_cylinders = 0, result_spheres = 0, unused_surfaces = 0;
    double drawn_linear = 0.0;
    const MeshData& m = st.data;
    try {
        // --- Step 4: the cells.
        std::vector<Handle(Geom_Surface)> geometry;
        const TopTools_ListOfShape faces = large_faces(plan, reach, geometry);
        BOPAlgo_MakerVolume maker;
        maker.SetArguments(faces);
        maker.SetIntersect(true);
        maker.SetRunParallel(false);
        maker.SetAvoidInternalShapes(true);
        const Handle(Clock) clock = new Clock(deadline);
        const bool finished = bounded(deadline, [&] { maker.Perform(clock->Start()); });
        if (!finished || clock->expired()) {
            return refuse(ops::timed_out(PRISMATIC, limit, hint));
        }
        if (maker.HasErrors()) {
            return refuse("The surfaces of " + body + "'s face groups close no cells. " + regroup(false), "cells");
        }
        const TopoDS_Shape cells = maker.Shape();
        phases.mark("cells");
        // --- Step 5: the cells inside the mesh.
        const double cell_linear = std::min(std::max(tolerance, D / 5000.0), D / 500.0);
        if (!mesh_result(cells, cell_linear, DISPLAY_ANGLE, deadline)) {
            return refuse(ops::timed_out(PRISMATIC, limit, hint));
        }
        phases.mark("cell_mesh");
        std::vector<TopoDS_Shape> kept;
        if (!pick_cells(st, cells, deadline, kept, pick)) {
            return refuse(ops::timed_out(PRISMATIC, limit, hint));
        }
        phases.mark("cell_pick");
        if (kept.empty()) {
            return refuse("None of the cells the surfaces of " + body +
                                  "'s face groups close lies inside it. " + regroup(true),
                          "cells");
        }
        // --- Step 6: one solid from the kept cells, its faces merged per surface.
        size_t positive = 0;
        const std::string trouble = solid_of_cells(kept, solid, positive);
        if (!trouble.empty()) {
            return refuse("The surfaces of " + body + "'s face groups do not close one solid (" + trouble + "). " + regroup(false),
                          "closed");
        }
        phases.mark("solid");
        if (deadline.expired() || budget::PRISMATIC_UNIFY_SECONDS_PER_100_CELLS * double(pick.kept) / 100.0 > deadline.remaining()) {
            return refuse(ops::timed_out(PRISMATIC, limit, hint));
        }
        {
            ShapeUpgrade_UnifySameDomain unifier(solid, true, true, false);
            const bool unified = bounded(deadline, [&] { unifier.Build(); });
            if (!unified) {
                return refuse(ops::timed_out(PRISMATIC, limit, hint));
            }
            solid = unifier.Shape();
        }
        phases.mark("unify");
        // --- The checks.
        size_t solids = 0;
        bool shells_closed = true;
        for (TopExp_Explorer it(solid, TopAbs_SOLID); it.More(); it.Next()) {
            ++solids;
        }
        for (TopExp_Explorer it(solid, TopAbs_SHELL); it.More(); it.Next()) {
            shells_closed = shells_closed && BRep_Tool::IsClosed(it.Current());
        }
        if (solids != 1 || !shells_closed) {
            return refuse("The surfaces of " + body + "'s face groups do not close one solid (" + (solids != 1 ? std::to_string(solids) + " solids came out" : "a shell stays open") +
                                  "). " + regroup(false),
                          "closed");
        }
        checks["closed"] = "ok";
        bool valid = BRepCheck_Analyzer(solid).IsValid();
        if (!valid && !deadline.expired()) {
            // The kernel's own repair (tolerances, wire order), then the same check again.
            const Handle(ShapeFix_Shape) fixer = new ShapeFix_Shape(solid);
            const bool fixed = bounded(deadline, [&] { fixer->Perform(); });
            if (fixed && !fixer->Shape().IsNull() && BRepCheck_Analyzer(fixer->Shape()).IsValid()) {
                solid = fixer->Shape();
                valid = true;
                size_t again = 0;
                for (TopExp_Explorer it(solid, TopAbs_SOLID); it.More(); it.Next()) {
                    ++again;
                }
                valid = again == 1;
            }
        }
        if (!valid) {
            return refuse("The result failed the solid check. " + regroup(false), "valid");
        }
        checks["valid"] = "ok";
        phases.mark("valid");
        if (deadline.expired()) {
            return refuse(ops::timed_out(PRISMATIC, limit, hint));
        }
        brep_volume = measure::volume(solid).Mass();
        brep_area = measure::surface(solid).Mass();
        {
            const double reference = std::fabs(ms.volume);
            const double off = std::fabs(brep_volume - ms.volume);
            if (!(off <= 0.005 * reference)) {
                return refuse("The result's volume is off by " + percent_text(reference > 0.0 ? off / reference : 1.0) + " from " + body +
                                      "'s (limit 0.5 %). " + regroup(true),
                              "volume");
            }
            checks["volume"] = "ok";
        }
        phases.mark("measure");
        // Every face meshed as the viewport will, and covered by its mesh.
        const double linear = display_deflection(D);
        if (!mesh_result(solid, linear, DISPLAY_ANGLE, deadline)) {
            return refuse(ops::timed_out(PRISMATIC, limit, hint));
        }
        phases.mark("mesh");
        TopTools_IndexedMapOfShape listed;
        TopExp::MapShapes(solid, TopAbs_FACE, listed);
        const int F = listed.Extent();
        std::vector<FaceProbe> probes(static_cast<size_t>(F));
        size_t undrawable = 0, stray_faces = 0;
        std::vector<uint8_t> surface_used(plan.surfaces.size(), 0);
        // Points on the result's faces, spread by area (the surface's own point at the middle
        // of a triangle of the face's mesh), at least one per face.
        std::vector<double> on_result;
        std::vector<uint32_t> on_result_face;
        double total_area = 0.0;
        for (int i = 1; i <= F; ++i) {
            TopLoc_Location location;
            const Handle(Poly_Triangulation) drawn = BRep_Tool::Triangulation(TopoDS::Face(listed(i)), location);
            if (!drawn.IsNull()) {
                const gp_Trsf trsf = location.Transformation();
                for (int t = 1; t <= drawn->NbTriangles(); ++t) {
                    int a = 0, b = 0, c = 0;
                    drawn->Triangle(t).Get(a, b, c);
                    const P3 pa = p3(drawn->Node(a).Transformed(trsf)), pb = p3(drawn->Node(b).Transformed(trsf)), pc = p3(drawn->Node(c).Transformed(trsf));
                    total_area += 0.5 * length(cross(pb - pa, pc - pa));
                }
            }
        }
        const double spacing = total_area / 4000.0;
        for (int i = 1; i <= F; ++i) {
            if (deadline.expired()) {
                return refuse(ops::timed_out(PRISMATIC, limit, hint));
            }
            const TopoDS_Face& face = TopoDS::Face(listed(i));
            FaceProbe& probe = probes[size_t(i - 1)];
            probe.face = face;
            const BRepAdaptor_Surface adaptor(face);
            switch (adaptor.GetType()) {
                case GeomAbs_Plane:
                    probe.kind = 0;
                    probe.plane = adaptor.Plane();
                    ++result_planes;
                    break;
                case GeomAbs_Cylinder:
                    probe.kind = 1;
                    probe.cylinder = adaptor.Cylinder();
                    ++result_cylinders;
                    break;
                case GeomAbs_Sphere:
                    probe.kind = 2;
                    probe.sphere = adaptor.Sphere();
                    ++result_spheres;
                    break;
                default:
                    break;
            }
            probe.surface = surface_of_face(adaptor, plan, D);
            if (probe.surface < 0) {
                ++stray_faces;
            }
            else {
                surface_used[size_t(probe.surface)] = 1;
            }
            probe.inside = std::make_unique<BRepTopAdaptor_FClass2d>(face, Precision::PConfusion());
            Bnd_Box box;
            BRepBndLib::Add(face, box);
            if (!box.IsVoid()) {
                box.Get(probe.lo[0], probe.lo[1], probe.lo[2], probe.hi[0], probe.hi[1], probe.hi[2]);
            }
            TopLoc_Location location;
            const Handle(Poly_Triangulation) drawn = BRep_Tool::Triangulation(face, location);
            if (drawn.IsNull() || drawn->NbTriangles() == 0 || !measure::face_drawable(face, linear, DISPLAY_ANGLE)) {
                ++undrawable;
                continue;
            }
            const gp_Trsf trsf = location.Transformation();
            double carried = 0.5 * spacing, largest = -1.0;
            int largest_at = 0;
            bool any = false;
            auto sample = [&](int t, double wa, double wb, double wc) {
                int a = 0, b = 0, c = 0;
                drawn->Triangle(t).Get(a, b, c);
                gp_Pnt at;
                if (drawn->HasUVNodes()) {
                    const gp_Pnt2d ua = drawn->UVNode(a), ub = drawn->UVNode(b), uc = drawn->UVNode(c);
                    at = adaptor.Value(wa * ua.X() + wb * ub.X() + wc * uc.X(), wa * ua.Y() + wb * ub.Y() + wc * uc.Y());
                }
                else {
                    const gp_XYZ sum = wa * drawn->Node(a).Transformed(trsf).XYZ() + wb * drawn->Node(b).Transformed(trsf).XYZ() + wc * drawn->Node(c).Transformed(trsf).XYZ();
                    at = gp_Pnt(sum);
                }
                on_result.push_back(at.X());
                on_result.push_back(at.Y());
                on_result.push_back(at.Z());
                on_result_face.push_back(uint32_t(i - 1));
            };
            for (int t = 1; t <= drawn->NbTriangles(); ++t) {
                int a = 0, b = 0, c = 0;
                drawn->Triangle(t).Get(a, b, c);
                const P3 pa = p3(drawn->Node(a).Transformed(trsf)), pb = p3(drawn->Node(b).Transformed(trsf)), pc = p3(drawn->Node(c).Transformed(trsf));
                const double area = 0.5 * length(cross(pb - pa, pc - pa));
                if (area > largest) {
                    largest = area;
                    largest_at = t;
                }
                // (A large triangle takes several points, spread over it.)
                carried += area;
                uint32_t taken = 0;
                while (carried >= spacing && spacing > 0.0) {
                    carried -= spacing;
                    double wa = 1.0 / 3.0, wb = 1.0 / 3.0, wc = 1.0 / 3.0;
                    if (taken > 0) {
                        spread(taken, wa, wb, wc);
                    }
                    sample(t, wa, wb, wc);
                    ++taken;
                    any = true;
                }
            }
            if (!any && largest_at > 0) {
                sample(largest_at, 1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0);
            }
        }
        if (undrawable > 0) {
            return refuse(with_commas(undrawable) + (undrawable == 1 ? " face" : " faces") +
                                  " of the result would be drawn wrong (the triangles do not cover the face). " + regroup(false),
                          "coverage");
        }
        checks["coverage"] = "ok";
        if (stray_faces > 0) {
            return refuse(with_commas(stray_faces) + (stray_faces == 1 ? " face" : " faces") +
                                  " of the result lie on none of the fitted surfaces (internal error). Please report it; Convert Mesh: Faceted still works.",
                          "surfaces");
        }
        checks["surfaces"] = "ok";
        for (const uint8_t used : surface_used) {
            unused_surfaces += used != 0 ? 0 : 1;
        }
        phases.mark("coverage");
        // The result against the mesh: every sampled point of the result within 3 x the
        // tolerance of the mesh. Each face is also named here, after the face group nearest to
        // most of its points among the groups of its surface.
        const TriBvh* bvh = bvh_of(st, &deadline);
        if (bvh == nullptr) {
            return refuse(ops::timed_out(PRISMATIC, limit, hint));
        }
        const double allowed = 3.0 * tolerance;
        uint32_t worst_result_group = NONE;
        std::vector<std::unordered_map<uint32_t, uint32_t>> votes(static_cast<size_t>(F));
        std::vector<P3> face_middle(static_cast<size_t>(F));
        std::vector<uint32_t> face_points(static_cast<size_t>(F), 0);
        for (size_t s = 0; s < on_result_face.size(); ++s) {
            if (deadline.tick()) {
                return refuse(ops::timed_out(PRISMATIC, limit, hint));
            }
            const double p[3] = {on_result[s * 3], on_result[s * 3 + 1], on_result[s * 3 + 2]};
            uint32_t triangle = NONE;
            double q[3];
            const double d2 = bvh->nearest(p, kInf, triangle, q);
            const double d = triangle == NONE ? kInf : std::sqrt(d2);
            if (d > result_to_mesh) {
                result_to_mesh = d;
                worst_result_group = triangle == NONE ? NONE : m.groups[triangle];
            }
            const uint32_t f = on_result_face[s];
            face_middle[f] += P3(p[0], p[1], p[2]);
            ++face_points[f];
            const std::vector<uint32_t>& groups = plan.surfaces[size_t(probes[f].surface)].groups;
            if (groups.size() == 1) {
                continue;
            }
            // (Several groups share the surface: the nearest triangle of one of them.)
            uint32_t own = NONE;
            double own_q[3];
            bvh->nearest(p, kInf, own, own_q, [&](uint32_t t) { return plan.surface_of_group[m.groups[t]] == probes[f].surface; });
            if (own != NONE) {
                ++votes[f][m.groups[own]];
            }
        }
        result_samples = int64_t(on_result_face.size());
        phases.mark("result_to_mesh");
        // The mesh against the result: corners and triangle middles spread over the body,
        // each to the nearest face of the result.
        uint32_t worst_mesh_group = NONE;
        {
            const size_t V = m.vertex_count(), T = m.triangle_count();
            std::vector<P3> samples;
            std::vector<uint32_t> sample_group;
            // A vertex's group: any triangle of it.
            std::vector<uint32_t> vertex_group(V, NONE);
            for (size_t t = 0; t < T; ++t) {
                for (size_t k = 0; k < 3; ++k) {
                    vertex_group[m.triangles[t * 3 + k]] = m.groups[t];
                }
            }
            const size_t vertex_step = std::max<size_t>(1, (V + 999) / 1000);
            for (size_t v = 0; v < V; v += vertex_step) {
                if (vertex_group[v] != NONE) {
                    samples.push_back(point_of(m, uint32_t(v)));
                    sample_group.push_back(vertex_group[v]);
                }
            }
            const double share = ms.area / 1000.0;
            double carried = 0.5 * share;
            for (size_t t = 0; t < T; ++t) {
                carried += 0.5 * length(triangle_cross(m, t));
                uint32_t taken = 0;
                while (carried >= share && share > 0.0) {
                    carried -= share;
                    double wa = 1.0 / 3.0, wb = 1.0 / 3.0, wc = 1.0 / 3.0;
                    if (taken > 0) {
                        spread(taken, wa, wb, wc);
                    }
                    samples.push_back(point_of(m, m.triangles[t * 3]) * wa + point_of(m, m.triangles[t * 3 + 1]) * wb + point_of(m, m.triangles[t * 3 + 2]) * wc);
                    sample_group.push_back(m.groups[t]);
                    ++taken;
                }
            }
            std::vector<std::pair<double, uint32_t>> nearby;
            for (size_t s = 0; s < samples.size(); ++s) {
                if (deadline.expired()) {
                    return refuse(ops::timed_out(PRISMATIC, limit, hint));
                }
                nearby.clear();
                for (size_t f = 0; f < probes.size(); ++f) {
                    nearby.emplace_back(least_distance(probes[f], samples[s]), uint32_t(f));
                }
                std::sort(nearby.begin(), nearby.end());
                // First the faces whose surface's nearest point lies in the face (a point on
                // the body is on one of them); the search along outlines only for a point that
                // is still far, and only on faces that could be nearer.
                double best = kInf;
                for (const auto& candidate : nearby) {
                    if (candidate.first >= best) {
                        break;
                    }
                    best = std::min(best, surface_distance(probes[candidate.second], samples[s]));
                }
                if (best > 0.25 * tolerance) {
                    for (const auto& candidate : nearby) {
                        if (candidate.first >= best) {
                            break;
                        }
                        best = std::min(best, outline_distance(probes[candidate.second], samples[s]));
                    }
                }
                mesh_to_result_sum += std::isfinite(best) ? best : 0.0;
                if (best > mesh_to_result) {
                    mesh_to_result = best;
                    worst_mesh_group = sample_group[s];
                }
            }
            mesh_samples = int64_t(samples.size());
        }
        phases.mark("mesh_to_result");
        const double worst = std::max(mesh_to_result, result_to_mesh);
        if (!(worst <= allowed)) {
            const uint32_t group = mesh_to_result >= result_to_mesh ? worst_mesh_group : worst_result_group;
            return refuse("The result is up to " + (std::isfinite(worst) ? mm(worst) : std::string("a body's width")) + " away from " + body + " (allowed " +
                                  mm(allowed) + ")" + (group != NONE ? ", near Face Group " + plan.group_number(group) : std::string()) +
                                  ". " + regroup(true),
                          "deviation");
        }
        checks["deviation"] = "ok";
        // Names: the face group of the face's surface (the most voted one when several share
        // it); a name used twice gets "#k", in order of where the faces lie.
        face_names.assign(static_cast<size_t>(F), std::string());
        for (int i = 0; i < F; ++i) {
            const std::vector<uint32_t>& groups = plan.surfaces[size_t(probes[size_t(i)].surface)].groups;
            uint32_t group = groups[0];
            uint32_t most = 0;
            for (const auto& vote : votes[size_t(i)]) {
                if (vote.second > most || (vote.second == most && vote.first < group)) {
                    most = vote.second;
                    group = vote.first;
                }
            }
            face_names[size_t(i)] = m.group_names[group];
        }
        {
            std::unordered_map<std::string, std::vector<size_t>> same;
            for (size_t i = 0; i < face_names.size(); ++i) {
                same[face_names[i]].push_back(i);
            }
            for (auto& entry : same) {
                std::vector<size_t>& list = entry.second;
                if (list.size() < 2) {
                    continue;
                }
                auto key = [&](size_t f) {
                    const double n = std::max<double>(1.0, face_points[f]);
                    const P3 c = face_middle[f] * (1.0 / n);
                    return std::array<double, 3>{std::round(c.x * 1e6), std::round(c.y * 1e6), std::round(c.z * 1e6)};
                };
                std::sort(list.begin(), list.end(), [&](size_t a, size_t b) {
                    const auto ka = key(a), kb = key(b);
                    return ka < kb || (ka == kb && a < b);
                });
                for (size_t k = 0; k < list.size(); ++k) {
                    face_names[list[k]] = entry.first + "#" + std::to_string(k);
                }
            }
        }
        phases.mark("names");
        // --- Back to the body's place and size.
        if (unit != 1.0 || place.centre[0] != 0.0 || place.centre[1] != 0.0 || place.centre[2] != 0.0) {
            gp_Trsf back;
            if (unit != 1.0) {
                back.SetScale(gp_Pnt(0.0, 0.0, 0.0), unit);
            }
            back.SetTranslationPart(gp_Vec(place.centre[0], place.centre[1], place.centre[2]));
            // (The geometry only, as the kernel's own Move and Scale make their copies: no
            // triangles go along. Triangles carried across a scale were kept by a later Combine
            // on the faces it left alone, and the mesher then drew their neighbours wrong.)
            BRepBuilderAPI_Transform mover(solid, back, true);
            const TopoDS_Shape placed = mover.Shape();
            std::unordered_map<const void*, std::string> by_face;
            for (int i = 1; i <= F; ++i) {
                by_face[mover.ModifiedShape(listed(i)).TShape().get()] = face_names[size_t(i - 1)];
            }
            TopTools_IndexedMapOfShape relisted;
            TopExp::MapShapes(placed, TopAbs_FACE, relisted);
            if (placed.IsNull() || relisted.Extent() != F) {
                return refuse(std::string(PRISMATIC) + " could not put the result back in " + body + "'s place (internal error). Please report it.", "placed");
            }
            std::vector<std::string> renamed(static_cast<size_t>(F));
            for (int i = 1; i <= F; ++i) {
                const auto found = by_face.find(relisted(i).TShape().get());
                renamed[size_t(i - 1)] = found != by_face.end() ? found->second : face_names[size_t(i - 1)];
            }
            face_names = renamed;
            solid = placed;
        }
        // --- What the viewport will draw of it, where it lies: the body without any triangles
        // (as the viewport gets it), meshed as the viewport meshes it; every face must be
        // covered and the drawn triangles must close. The triangles are taken off again: the
        // body leaves as a kernel body does, geometry only, so every later tool and the
        // display treat it as one.
        BRepTools::Clean(solid);
        drawn_linear = display_deflection(D_model);
        const Drawn drawn = drawn_check(solid, drawn_linear, deadline);
        BRepTools::Clean(solid);
        if (!drawn.finished) {
            return refuse(ops::timed_out(PRISMATIC, limit, hint));
        }
        phases.mark("drawn");
        if (drawn.unmeshed + drawn.uncovered + drawn.open_edges > 0) {
            std::string what;
            if (drawn.unmeshed + drawn.uncovered > 0) {
                const size_t n = drawn.unmeshed + drawn.uncovered;
                what = with_commas(n) + (n == 1 ? " face of the result is" : " faces of the result are") + " not covered by the triangles drawn for " + (n == 1 ? "it" : "them");
            }
            else {
                what = with_commas(drawn.open_edges) + (drawn.open_edges == 1 ? " edge" : " edges") + " of the triangles drawn for the result would stay open";
            }
            return refuse("The result would be drawn with a gap: " + what + " (the kernel's mesher fails on it at this size and place). Use Convert Mesh: Faceted.", "drawn");
        }
        checks["drawn"] = "ok";
    }
    catch (const Standard_Failure& failure) {
        return refuse(kernel_error(PRISMATIC, failure));
    }
    catch (const std::exception& e) {
        return refuse(std::string(PRISMATIC) + " failed: " + e.what() + ".");
    }
    Ref<CadShape> result = CadShape::wrap(solid);
    {
        const TopTools_IndexedMapOfShape& listed = result->face_map();
        result->face_name_list.assign(size_t(listed.Extent()), std::string());
        for (int i = 1; i <= listed.Extent(); ++i) {
            result->face_name_list[size_t(i - 1)] = size_t(i - 1) < face_names.size() ? face_names[size_t(i - 1)] : "f" + std::to_string(i - 1);
        }
        naming::name_edges(*result.ptr());
    }
    phases.mark("edge_names");
    for (const Plan::MadeEqual& told : plan.made_equal) {
        const std::string text = "Face Group " + plan.group_number(told.changed) + " (radius " + mm(told.was) + ") was given the radius of Face Group " +
                                 plan.group_number(told.kept) + " (" + mm(told.now) + "): Convert Mesh: Prismatic cannot tell radii " + mm(std::fabs(told.was - told.now)) +
                                 " apart here. Lower the Fit Tolerance below " + mm(4.0 * std::fabs(told.was - told.now)) +
                                 (plan.far ? ", or move the body nearer the origin," : "") + " to keep them apart.";
        warnings.push_back(ops::text(text));
        checks["radii"] = String("warn: ") + ops::text(text);
    }
    if (unused_surfaces > 0) {
        const std::string text = with_commas(unused_surfaces) + (unused_surfaces == 1 ? " surface of " : " surfaces of ") + body +
                                 "'s face groups left no face on the result (they are smaller than the Fit Tolerance allows to tell).";
        warnings.push_back(ops::text(text));
        checks["surfaces"] = String("warn: ") + ops::text(text);
    }
    Dictionary output;
    output["faces"] = int64_t(result->face_count());
    output["planes"] = int64_t(result_planes);
    output["cylinders"] = int64_t(result_cylinders);
    output["spheres"] = int64_t(result_spheres);
    output["solids"] = int64_t(1);
    output["closed"] = true;
    output["valid"] = true;
    output["volume"] = brep_volume * unit * unit * unit;
    output["area"] = brep_area * unit * unit;
    output["drawn_deflection"] = drawn_linear;
    Dictionary deviation;
    deviation["max"] = std::max(mesh_to_result, result_to_mesh) * unit;
    deviation["mean"] = (mesh_samples > 0 ? mesh_to_result_sum / double(mesh_samples) : 0.0) * unit;
    deviation["samples"] = mesh_samples + result_samples;
    deviation["mesh_to_result"] = mesh_to_result * unit;
    deviation["result_to_mesh"] = result_to_mesh * unit;
    deviation["allowed"] = 3.0 * tolerance_model;
    plan_report();
    last_report["input"] = ops::summary_dict(summarize(*state), false);
    last_report["output"] = output;
    last_report["deviation"] = deviation;
    last_report["volume_change"] = ms.volume != 0.0 ? (brep_volume - ms.volume) / std::fabs(ms.volume) : 0.0;
    last_report["unused_surfaces"] = int64_t(unused_surfaces);
    last_report["phases"] = phases.ms;
    last_report["ms"] = ops::now_ms() - started;
    if (!warnings.is_empty()) {
        last_warning = joined(warnings);
    }
    return result;
}

// ---------------------------------------------------------------- CadMesh: before the op

Dictionary CadMesh::convert_defaults(const String& method, const Dictionary& options)
{
    using namespace mesh;
    // (A panel's question: the mesh's own messages stay as they are.)
    const String kept_error = last_error, kept_warning = last_warning;
    const Dictionary kept_report = last_report;
    Dictionary out;
    Options o(options);
    const double limit = o.time_limit();
    const std::string name = o.name(true), body = o.name(false);
    const double D = is_null() ? 0.0 : measures_of(*state).diagonal;
    if (method == String("faceted")) {
        out["merge_flat"] = true;
        out["flat_tolerance"] = D * 1e-6;
        out["flat_tolerance_min"] = 0.0;
        out["flat_tolerance_max"] = D / 100.0;
        out["max_triangles"] = int64_t(budget::MAX_TRIANGLES_FACETED);
        const size_t T = is_null() ? 0 : state->data.triangle_count();
        // The faces the result will have, as the op itself counts them (all triangles when the
        // patches cannot be found within a short time).
        double seconds = convert::faceted_seconds(double(T), 0.0);
        std::string problem = is_null() ? std::string(name + " has no triangles.") : faceted_refusal(*state, name);
        if (problem.empty()) {
            const bool merge = o.flag("merge_flat", "Merge Flat Face Groups", true);
            const double flat = o.number("flat_tolerance", "Flat Tolerance", D * 1e-6);
            if (o.ok()) {
                o.range("Flat Tolerance", flat, 0.0, D / 100.0, true);
            }
            problem = o.problem();
            if (problem.empty() && merge) {
                const Deadline quick(std::min(limit, 1.0));
                const Topology* topo = topology_of(*state, &quick);
                std::vector<Patch> patches;
                std::vector<uint32_t> patch_of(T, NONE);
                size_t near_flat = 0;
                if (topo != nullptr && find_patches(*state, *topo, flat, faceted_floor(measures_of(*state)), quick, patches, patch_of, near_flat)) {
                    seconds = faceted_estimate(patches, patch_of);
                }
            }
        }
        out["seconds"] = seconds;
        if (problem.empty() && seconds > limit) {
            problem = ops::too_slow(FACETED, seconds, limit, "Reduce the body first.");
        }
        if (!problem.empty()) {
            out["problem"] = ops::text(problem);
        }
    }
    else if (method == String("prismatic")) {
        out["tolerance"] = D / 1000.0;
        out["tolerance_min"] = D * 1e-6;
        out["tolerance_max"] = D / 20.0;
        out["allow_spheres"] = true;
        out["max_triangles"] = int64_t(budget::MAX_PRISMATIC_TRIANGLES);
        out["max_surfaces"] = int64_t(budget::MAX_PRISMATIC_SURFACES);
        const bool allow_spheres = o.flag("allow_spheres", "Allow Spheres", true);
        const double tolerance = o.number("tolerance", "Fit Tolerance", D / 1000.0);
        if (o.ok() && !is_null()) {
            o.range("Fit Tolerance", tolerance, D * 1e-6, D / 20.0, true);
        }
        if (is_null()) {
            out["problem"] = ops::text(name + " has no triangles.");
        }
        else if (!o.ok()) {
            out["problem"] = ops::text(o.problem());
        }
        else {
            const Deadline deadline(limit);
            Plan plan;
            const Workplace place = workplace_of(*state);
            if (place.mesh.is_null()) {
                plan.problem = std::string(PRISMATIC) + " could not copy " + body + " (" + place.problem + "). Please report it.";
            }
            else {
                const double local = tolerance / place.unit;
                place_plan(plan, place, *state, local, name, body);
                make_plan(
                        place.mesh->get_state(), [&](const PackedInt32Array& tris) { return place.mesh->fit_primitive(tris); }, local, allow_spheres, limit, name, body, deadline, plan);
                settle_one_group(plan, place.mesh, name, deadline);
            }
            out["surfaces"] = int64_t(plan.surfaces.size());
            out["planes"] = int64_t(plan.planes);
            out["cylinders"] = int64_t(plan.cylinders);
            out["spheres"] = int64_t(plan.spheres);
            out["crossing_pairs"] = int64_t(plan.crossing_pairs);
            out["corners"] = int64_t(plan.corners);
            out["seconds"] = plan.seconds;
            if (plan.timed_out) {
                out["problem"] = ops::text(ops::timed_out(PRISMATIC, limit, "Combine face groups to make fewer surfaces, or use Faceted."));
            }
            else if (!plan.problem.empty()) {
                out["problem"] = ops::text(plan.problem);
            }
        }
    }
    else {
        out["problem"] = String("Convert Mesh has no method '") + method + String("'.");
    }
    last_error = kept_error;
    last_warning = kept_warning;
    last_report = kept_report;
    return out;
}

void CadMesh::bind_convert_methods()
{
    // Stage C: Convert Mesh (Faceted, Prismatic), and what their panels ask before the op.
    ClassDB::bind_method(D_METHOD("to_faceted", "options"), &CadMesh::to_faceted, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("to_prismatic", "options"), &CadMesh::to_prismatic, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("convert_defaults", "method", "options"), &CadMesh::convert_defaults, DEFVAL(Dictionary()));
}

}  // namespace holo_forge
