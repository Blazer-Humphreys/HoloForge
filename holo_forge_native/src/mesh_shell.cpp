// Shell (work order 3.3.5).
//   fast      every vertex moved along its normal; the second surface is added (and a rim
//             along open edges). Quick, but it can cross itself in tight places.
//   accurate  the offset surface comes from our voxel grid through Manifold's LevelSet, and is
//             cut out of (or wrapped around) the body with a Manifold boolean.
// Both end with the wall check: samples on the new surface must lie one wall away from the
// surface they were offset from.

#include "cad_mesh.h"
#include "mesh_bvh.h"
#include "mesh_manifold.h"
#include "mesh_voxel.h"

#include <algorithm>
#include <cmath>
#include <exception>

using namespace godot;

namespace holo_forge
{

namespace
{
using mesh::MeshData;
using mesh::NONE;

inline double dot3(const double* a, const double* b)
{
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}
inline void cross3(const double* a, const double* b, double* r)
{
    r[0] = a[1] * b[2] - a[2] * b[1];
    r[1] = a[2] * b[0] - a[0] * b[2];
    r[2] = a[0] * b[1] - a[1] * b[0];
}

struct Plan
{
    double diagonal = 0.0;
    double lo[3] = {0, 0, 0}, hi[3] = {0, 0, 0};
    double thickness = 0.0, detail = 0.0;
    int direction = 0;  // 0 inside, 1 outside, 2 both
    int method = 1;     // 0 fast, 1 accurate
    double thickness_min = 0.0, thickness_max = 0.0, thickness_default = 0.0;
    double detail_min = 0.0, detail_max = 0.0, detail_default = 0.0;
    bool open = false;
    double reach = 0.0;   // how far the new surface lies outside the body
    double margin = 0.0;
    double cells = 0.0;
    double seconds = 0.0;
    double limit = 20.0;
    std::string name, name_start;
};

/// About how thick the body is where it is thinnest: along each bounding box axis the longest
/// stretch a ray runs inside the body (20 rays in all), and of those three the shortest.
/// Infinite when no ray found an inside.
double thinnest_extent(mesh::State& state, const Plan& plan)
{
    const mesh::TriBvh* bvh = mesh::bvh_of(state);
    static const double spots[7][2] = {{0.5, 0.5}, {0.35, 0.35}, {0.65, 0.35}, {0.35, 0.65}, {0.65, 0.65}, {0.5, 0.25}, {0.5, 0.75}};
    double thinnest = INFINITY;
    std::vector<std::pair<double, int>> hits;
    for (int axis = 0; axis < 3; ++axis) {
        const int a1 = (axis + 1) % 3, a2 = (axis + 2) % 3;
        double longest = 0.0;
        for (int r = 0; r < (axis == 2 ? 6 : 7); ++r) {
            double o[3], d[3] = {0, 0, 0};
            o[axis] = plan.lo[axis] - 0.01 * plan.diagonal;
            o[a1] = plan.lo[a1] + spots[r][0] * (plan.hi[a1] - plan.lo[a1]);
            o[a2] = plan.lo[a2] + spots[r][1] * (plan.hi[a2] - plan.lo[a2]);
            d[axis] = 1.0;
            hits.clear();
            bvh->bvh.ray(o, d, INFINITY, [&](int prim, double&) {
                double a[3], b[3], c[3], t = 0.0, b1 = 0.0, b2 = 0.0;
                bvh->corners(uint32_t(prim), a, b, c);
                if (subd::ray_triangle(o, d, a, b, c, 0.0, INFINITY, t, b1, b2)) {
                    double e1[3], e2[3], n[3];
                    for (int k = 0; k < 3; ++k) {
                        e1[k] = b[k] - a[k];
                        e2[k] = c[k] - a[k];
                    }
                    cross3(e1, e2, n);
                    hits.push_back({t, n[axis] < 0.0 ? 1 : -1});  // +1: the ray goes in
                }
                return true;
            });
            std::sort(hits.begin(), hits.end());
            // (A ray through an edge meets both its triangles at one distance: counted once.)
            int depth = 0;
            double entered = 0.0, last_t = -INFINITY;
            int last_sign = 0;
            for (const std::pair<double, int>& hit : hits) {
                if (hit.second == last_sign && hit.first - last_t <= 1e-9 * plan.diagonal) {
                    continue;
                }
                last_t = hit.first;
                last_sign = hit.second;
                if (hit.second > 0) {
                    if (depth == 0) {
                        entered = hit.first;
                    }
                    ++depth;
                }
                else if (depth > 0) {
                    --depth;
                    if (depth == 0) {
                        longest = std::max(longest, hit.first - entered);
                    }
                }
            }
        }
        if (longest > 0.0) {
            thinnest = std::min(thinnest, longest);
        }
    }
    return thinnest;
}

bool make_plan(mesh::State& state, mesh::ops::Options& o, Plan& plan, bool for_defaults)
{
    using namespace mesh::budget;
    const mesh::Measures& ms = mesh::measures_of(state);
    const double D = ms.diagonal;
    plan.diagonal = D;
    plan.name = o.name(false);
    plan.name_start = o.name(true);
    plan.limit = o.time_limit();
    for (int k = 0; k < 3; ++k) {
        plan.lo[k] = ms.lo[k];
        plan.hi[k] = ms.hi[k];
    }
    if (!(D > 0.0)) {
        o.fail("Shell needs a body with a size.");
        return false;
    }
    plan.thickness_min = D / 2000.0;
    plan.thickness_max = D / 4.0;
    plan.thickness_default = D / 50.0;
    plan.thickness = o.number("thickness", "Thickness", plan.thickness_default);
    plan.direction = o.choice("direction", "Direction", {"inside", "outside", "both"}, 0);
    plan.method = o.choice("method", "Method", {"fast", "accurate"}, 1);
    if (!o.ok() || !o.range("Thickness", plan.thickness, plan.thickness_min, plan.thickness_max, true)) {
        return false;
    }
    const double t = plan.thickness;
    // A wall that would reach past the limit of a mesh body: said here, before the work.
    {
        const std::string out = mesh::ops::past_limit(state, "Shell", plan.direction == 0 ? 0.0 : t, plan.name);
        if (!out.empty()) {
            o.fail(out);
            return false;
        }
    }
    const mesh::Topology* topo = mesh::topology_of(state);
    plan.open = topo->boundary_edges > 0;
    plan.reach = plan.direction == 1 ? t : (plan.direction == 2 ? 0.5 * t : 0.0);
    plan.detail_min = t / 10.0;
    plan.detail_max = t / 2.0;
    const double fit = mesh::voxel::fitting_cell(plan.lo, plan.hi, plan.reach, 2.0, double(MAX_VOXEL_SAMPLES));
    plan.detail_default = std::max(t / 4.0, fit);
    const double T = double(state.data.triangle_count());
    if (plan.method == 0) {
        // Fast: the normals need a mesh whose triangles agree about their sides.
        if (topo->non_manifold_edges > 0) {
            o.fail(plan.name_start + " has " + mesh::ops::count_text(topo->non_manifold_edges, "edge", "edges") + " that more than two triangles share. Run Stitch and Remove first.");
            return false;
        }
        if (topo->inconsistent_edges > 0) {
            o.fail(plan.name_start + " has triangles that face the wrong way (at " + mesh::ops::count_text(topo->inconsistent_edges, "edge", "edges") + "). Run Reverse Normal first.");
            return false;
        }
        if (T * 2.0 + double(topo->boundary_edges) * 2.0 > double(MAX_TRIANGLES_MESH) || 2 * state.data.vertex_count() > MAX_VERTICES_MESH) {
            o.fail("Shell would make " + mesh::with_commas(uint64_t(T * 2.0) + uint64_t(topo->boundary_edges) * 2) + " triangles; mesh bodies take up to " +
                   mesh::with_commas(MAX_TRIANGLES_MESH) + ". Reduce the body first.");
            return false;
        }
        // Far from the origin positions step by more than a share of the wall: no wall of
        // this thickness can be stored there.
        {
            const std::string far = mesh::ops::too_far(state, plan.name_start, t / 8.0, "too coarse for a wall of " + mesh::ops::length_text(t));
            if (!far.empty()) {
                o.fail(far);
                return false;
            }
        }
        plan.detail = plan.detail_default;
        // (The hierarchy is counted whether or not the mesh has one already: the same options
        // must give the same estimate every time. The result and the body are each tested for
        // crossings, for at most 1 s each.)
        plan.seconds = estimate(SHELL_FAST, T) + estimate(BVH_BUILD, T) + estimate(OP_FINISH, 2.0 * T) +
                       std::min(SELF_INTERSECTION_SECONDS, estimate(BVH_BUILD, 2.0 * T) + estimate(SELF_INTERSECTIONS, 2.0 * T)) +
                       std::min(SELF_INTERSECTION_SECONDS, estimate(SELF_INTERSECTIONS, T));
    }
    else {
        if (plan.direction != 2) {
            if (plan.open) {
                o.fail("An open body has no inside; use Both, or Close Holes first.");
                return false;
            }
            const std::string problem = mesh::mf::unfit(state, plan.name_start);
            if (!problem.empty()) {
                o.fail(problem);
                return false;
            }
        }
        const bool detail_given = o.has("detail");
        plan.detail = o.number("detail", "Detail", plan.detail_default);
        if (!o.ok()) {
            return false;
        }
        if (!detail_given && plan.detail > plan.detail_max * (1.0 + 1e-6)) {
            // No cell size both resolves this wall and fits the grid.
            const double finest = mesh::voxel::sample_count(plan.lo, plan.hi, plan.reach + 2.0 * plan.detail_max, plan.detail_max);
            o.fail("Shell needs " + mesh::ops::plain_number(finest / 1e6, 3) + " million cells for a " + mesh::ops::length_text(t) +
                   " wall on this body; use the Fast method, or a wall of at least " + mesh::ops::length_text(2.0 * fit) + ".");
            return false;
        }
        if (!o.range("Detail", plan.detail, plan.detail_min, plan.detail_max, true)) {
            return false;
        }
        // Far from the origin positions step by more than a share of a cell: the shell would
        // be rounding noise (it used to end as "crosses itself in 18,488 places (internal
        // error)").
        {
            const std::string far = mesh::ops::too_far(state, plan.name_start, plan.detail / 8.0,
                                                       "too coarse for a wall of " + mesh::ops::length_text(t) + " (built from cells of " + mesh::ops::length_text(plan.detail) + ")");
            if (!far.empty()) {
                o.fail(far);
                return false;
            }
        }
        plan.margin = plan.reach + 2.0 * plan.detail;
        plan.cells = mesh::voxel::sample_count(plan.lo, plan.hi, plan.margin, plan.detail);
        if (plan.cells > double(MAX_VOXEL_SAMPLES)) {
            o.fail("Shell needs " + mesh::ops::plain_number(plan.cells / 1e6, 3) + " million cells; raise Detail to " + mesh::ops::length_text(fit) +
                   (fit > plan.detail_max ? " (and the Thickness with it), or use the Fast method." : "."));
            return false;
        }
        const double band = (plan.direction == 2 ? 0.5 * t : t) + 2.5 * plan.detail;
        plan.seconds = estimate(BVH_BUILD, T) + estimate(TOPOLOGY, T) + mesh::mf::voxel_seconds(plan.cells, band, plan.detail) +
                       mesh::mf::level_set_seconds(plan.cells, ms.area, plan.detail) + std::min(SELF_INTERSECTION_SECONDS, estimate(SELF_INTERSECTIONS, T));
        if (plan.direction != 2) {
            const double made = std::min(LEVEL_SET_TRIANGLES_PER_CELL_AREA * ms.area / (plan.detail * plan.detail), 2e6);
            plan.seconds += estimate(MF_INGEST, T) + estimate(MF_SUBTRACT, T + made) + estimate(OP_FINISH, T);
        }
    }
    (void)for_defaults;
    return true;
}

// ---------------------------------------------------------------- the wall check

struct Wall
{
    int64_t samples = 0, within = 0;
    double least = INFINITY, most = 0.0, mean = 0.0;
    double target = 0.0;
    bool passed = false;
};

/// 400 points spread evenly by area (a fixed seed) over the triangles `pick` lets through; from
/// each the distance to the nearest point of `reference`. The wall passes when 95 % of them lie
/// within low .. high times the target.
template <class F>
Wall measure_wall(const MeshData& m, F&& pick, mesh::State& reference, double target, double low, double high)
{
    Wall wall;
    wall.target = target;
    const size_t T = m.triangle_count();
    std::vector<double> cumulative;
    std::vector<uint32_t> ids;
    double total = 0.0;
    for (size_t t = 0; t < T; ++t) {
        if (!pick(uint32_t(t))) {
            continue;
        }
        double p[3][3], e1[3], e2[3], n[3];
        for (int k = 0; k < 3; ++k) {
            m.point(m.triangles[t * 3 + size_t(k)], p[k]);
        }
        for (int k = 0; k < 3; ++k) {
            e1[k] = p[1][k] - p[0][k];
            e2[k] = p[2][k] - p[0][k];
        }
        cross3(e1, e2, n);
        total += 0.5 * std::sqrt(dot3(n, n));
        cumulative.push_back(total);
        ids.push_back(uint32_t(t));
    }
    if (ids.empty() || !(total > 0.0)) {
        return wall;
    }
    const mesh::TriBvh* bvh = mesh::bvh_of(reference);
    uint64_t seed = 0x9E3779B97F4A7C15ull;
    auto random = [&seed]() {
        seed += 0x9E3779B97F4A7C15ull;
        uint64_t z = seed;
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
        z ^= z >> 31;
        return double(z >> 11) * (1.0 / 9007199254740992.0);
    };
    double sum = 0.0;
    for (int i = 0; i < 400; ++i) {
        const double pickat = random() * total;
        const size_t index = std::min(size_t(std::lower_bound(cumulative.begin(), cumulative.end(), pickat) - cumulative.begin()), ids.size() - 1);
        const uint32_t t = ids[index];
        double p[3][3], q[3], closest[3];
        for (int k = 0; k < 3; ++k) {
            m.point(m.triangles[size_t(t) * 3 + size_t(k)], p[k]);
        }
        double u = random(), v = random();
        if (u + v > 1.0) {
            u = 1.0 - u;
            v = 1.0 - v;
        }
        for (int k = 0; k < 3; ++k) {
            q[k] = p[0][k] + u * (p[1][k] - p[0][k]) + v * (p[2][k] - p[0][k]);
        }
        uint32_t triangle = NONE;
        const double d = std::sqrt(bvh->nearest(q, INFINITY, triangle, closest));
        ++wall.samples;
        sum += d;
        wall.least = std::min(wall.least, d);
        wall.most = std::max(wall.most, d);
        wall.within += (d >= low * target && d <= high * target) ? 1 : 0;
    }
    wall.mean = sum / double(wall.samples);
    wall.passed = double(wall.within) >= 0.95 * double(wall.samples);
    return wall;
}

Dictionary wall_dict(const Wall& wall)
{
    Dictionary d;
    d["samples"] = wall.samples;
    d["within"] = wall.samples > 0 ? double(wall.within) / double(wall.samples) : 0.0;
    d["min"] = wall.samples > 0 ? wall.least : 0.0;
    d["max"] = wall.most;
    d["mean"] = wall.mean;
    d["target"] = wall.target;
    return d;
}

std::string wall_sentence(const Wall& wall, double low, double high, const char* advice)
{
    return "The wall is off: " + mesh::number_text(100.0 * double(wall.within) / double(std::max<int64_t>(wall.samples, 1)), "%.0f") + " % of " +
           std::to_string(wall.samples) + " samples are within " + mesh::number_text(low) + " to " + mesh::number_text(high) + " x " + mesh::ops::length_text(wall.target) +
           " (measured " + mesh::ops::length_text(wall.least) + " to " + mesh::ops::length_text(wall.most) + "). " + advice;
}

// ---------------------------------------------------------------- fast

/// The fast shell. Groups: the input's own on the surface that lies on the input (for Both: on
/// the outer one), surface_name on the other surface, rim_name on the strips along open edges.
bool fast_shell(mesh::State& state, const Plan& plan, const std::string& surface_name, const std::string& rim_name, MeshData& out, const mesh::Deadline& deadline)
{
    const MeshData& m = state.data;
    const size_t V = m.vertex_count(), T = m.triangle_count();
    const mesh::Topology* topo = mesh::topology_of(state);
    // Angle-weighted vertex normals, and at each vertex the smallest cosine between that normal
    // and the triangles around it: moving by t / cos keeps those triangles' planes t apart.
    std::vector<double> normal(V * 3, 0.0), face(T * 3, 0.0);
    for (size_t t = 0; t < T; ++t) {
        double p[3][3], e1[3], e2[3], n[3];
        for (int k = 0; k < 3; ++k) {
            m.point(m.triangles[t * 3 + size_t(k)], p[k]);
        }
        for (int k = 0; k < 3; ++k) {
            e1[k] = p[1][k] - p[0][k];
            e2[k] = p[2][k] - p[0][k];
        }
        cross3(e1, e2, n);
        const double len = std::sqrt(dot3(n, n));
        if (!(len > 0.0)) {
            continue;
        }
        for (int k = 0; k < 3; ++k) {
            face[t * 3 + size_t(k)] = n[k] / len;
        }
        for (int c = 0; c < 3; ++c) {
            double a[3], b[3];
            for (int k = 0; k < 3; ++k) {
                a[k] = p[(c + 1) % 3][k] - p[c][k];
                b[k] = p[(c + 2) % 3][k] - p[c][k];
            }
            const double la = std::sqrt(dot3(a, a)), lb = std::sqrt(dot3(b, b));
            if (!(la > 0.0) || !(lb > 0.0)) {
                continue;
            }
            const double angle = std::acos(std::min(1.0, std::max(-1.0, dot3(a, b) / (la * lb))));
            const uint32_t v = m.triangles[t * 3 + size_t(c)];
            for (int k = 0; k < 3; ++k) {
                normal[size_t(v) * 3 + size_t(k)] += angle * face[t * 3 + size_t(k)];
            }
        }
        if (deadline.tick()) {
            return false;
        }
    }
    std::vector<double> least(V, 1.0);
    for (size_t v = 0; v < V; ++v) {
        double* n = &normal[v * 3];
        const double len = std::sqrt(dot3(n, n));
        for (int k = 0; k < 3; ++k) {
            n[k] = len > 0.0 ? n[k] / len : 0.0;
        }
    }
    for (size_t t = 0; t < T; ++t) {
        const double* f = &face[t * 3];
        if (f[0] == 0.0 && f[1] == 0.0 && f[2] == 0.0) {
            continue;
        }
        for (int c = 0; c < 3; ++c) {
            const uint32_t v = m.triangles[t * 3 + size_t(c)];
            least[v] = std::min(least[v], dot3(&normal[size_t(v) * 3], f));
        }
    }
    // Two surfaces: A at +outer along the normal (the input's way round), B at -inner (turned over).
    const double t = plan.thickness;
    const double outer = plan.direction == 1 ? t : (plan.direction == 2 ? 0.5 * t : 0.0);
    const double inner = plan.direction == 0 ? t : (plan.direction == 2 ? 0.5 * t : 0.0);
    auto moved = [&](double by, std::vector<float>& positions) {
        positions.resize(V * 3);
        for (size_t v = 0; v < V; ++v) {
            const double step = by / std::max(0.5, least[v]);
            for (int k = 0; k < 3; ++k) {
                positions[v * 3 + size_t(k)] = float(double(m.positions[v * 3 + size_t(k)]) + step * normal[v * 3 + size_t(k)]);
            }
        }
    };
    std::vector<float> a_positions, b_positions;
    moved(outer, a_positions);
    moved(-inner, b_positions);
    out.positions = a_positions;
    out.positions.insert(out.positions.end(), b_positions.begin(), b_positions.end());
    out.group_names = m.group_names;
    const uint32_t surface_group = uint32_t(out.group_names.size());
    out.group_names.push_back(surface_name);
    const uint32_t rim_group = uint32_t(out.group_names.size());
    out.group_names.push_back(rim_name);
    // The surface that lies on the input (or, for Both, the outer one) keeps the input's groups.
    const bool a_keeps = outer == 0.0 || plan.direction == 2;
    const uint32_t base = uint32_t(V);
    out.triangles.reserve(T * 6);
    for (size_t i = 0; i < T; ++i) {
        const uint32_t* tri = &m.triangles[i * 3];
        out.triangles.push_back(tri[0]);
        out.triangles.push_back(tri[1]);
        out.triangles.push_back(tri[2]);
        out.groups.push_back(a_keeps ? m.groups[i] : surface_group);
    }
    for (size_t i = 0; i < T; ++i) {
        const uint32_t* tri = &m.triangles[i * 3];
        out.triangles.push_back(tri[0] + base);
        out.triangles.push_back(tri[2] + base);
        out.triangles.push_back(tri[1] + base);
        out.groups.push_back(a_keeps ? surface_group : m.groups[i]);
    }
    // The rim: one strip of two triangles along every open edge, joining the two surfaces.
    for (size_t he = 0; he < topo->he_edge.size(); ++he) {
        const uint32_t e = topo->he_edge[he];
        if (e == NONE || topo->uses(e) != 1) {
            continue;
        }
        const uint32_t a = m.triangles[he], b = m.triangles[(he / 3) * 3 + (he + 1) % 3];
        // The input triangle runs a -> b; the rim runs it b -> a, down to B and back.
        out.triangles.insert(out.triangles.end(), {b, a, a + base, b, a + base, b + base});
        out.groups.push_back(rim_group);
        out.groups.push_back(rim_group);
    }
    return true;
}

Dictionary plan_dict(const Plan& plan)
{
    Dictionary out;
    out["thickness"] = plan.thickness_default;
    out["thickness_min"] = plan.thickness_min;
    out["thickness_max"] = plan.thickness_max;
    out["direction"] = "inside";
    out["method"] = "accurate";
    out["detail"] = plan.detail_default;
    out["detail_min"] = plan.detail_min;
    out["detail_max"] = plan.detail_max;
    out["cells"] = plan.cells;
    out["seconds"] = plan.seconds;
    return out;
}
}  // namespace

namespace mesh
{
Dictionary shell_defaults(State& state, const Dictionary& options)
{
    ops::Options o(options);
    Plan plan;
    const bool ok = make_plan(state, o, plan, true);
    Dictionary out = plan_dict(plan);
    if (!ok) {
        out["problem"] = ops::text(o.problem());
    }
    return out;
}
}  // namespace mesh

Ref<CadMesh> CadMesh::shell(const Dictionary& options)
{
    clear_messages();
    const double started = mesh::ops::now_ms();
    const char* const hint = "Raise Detail, or use the Fast method.";
    if (is_null()) {
        fail("There is no mesh to shell.");
        return Ref<CadMesh>();
    }
    mesh::ops::Options o(options);
    Plan plan;
    mesh::ops::Phases phases;
    const bool skip_estimate = o.skip_estimate();
    if (!make_plan(*state, o, plan, false) || !o.ok()) {
        fail(o.problem());
        return Ref<CadMesh>();
    }
    const double t = plan.thickness;
    // A wall thicker than half the body's thinnest extent leaves nothing inside.
    if (!plan.open && plan.direction != 1) {
        const double thinnest = thinnest_extent(*state, plan);
        const double needs = plan.direction == 0 ? 2.0 * t : t;
        if (needs > thinnest) {
            fail("A " + mesh::ops::length_text(t) + " wall does not fit in " + plan.name + " (thinnest part about " + mesh::ops::length_text(thinnest) + ").");
            return Ref<CadMesh>();
        }
    }
    phases.mark("checks");
    if (plan.seconds > plan.limit && !skip_estimate) {
        fail(mesh::ops::too_slow("Shell", plan.seconds, plan.limit, plan.method == 0 ? "Reduce the body first." : hint));
        return Ref<CadMesh>();
    }
    const mesh::Deadline deadline(plan.limit);
    auto late = [&]() {
        fail(mesh::ops::timed_out("Shell", plan.limit, plan.method == 0 ? "Reduce the body first." : hint));
        return Ref<CadMesh>();
    };
    const MeshData& input = state->data;
    const size_t input_groups = input.group_count();
    // Does the body cross itself? Inside and Outside (accurate) need its inside: where it
    // crosses itself there is no true one, and the boolean's answer is wrong without any sign
    // of it (two crossing cubes gave a wall of negative volume). Such a body is refused; one
    // too large to test in the time is shelled with a warning.
    const int64_t input_crossings = mesh::ops::crossings(*state, deadline);
    if (plan.method == 1 && plan.direction != 2 && input_crossings > 0) {
        fail(plan.name_start + " crosses itself in " + mesh::ops::count_text(input_crossings, "place", "places") + ", so it has no clear inside to shell. Rebuild it first.");
        return Ref<CadMesh>();
    }
    phases.mark("crossings");
    std::unordered_set<std::string> taken(input.group_names.begin(), input.group_names.end());
    const std::string surface_name = mesh::ops::numbered_name("shell", input.group_names);
    taken.insert(surface_name);
    std::vector<std::string> with_surface = input.group_names;
    with_surface.push_back(surface_name);
    const std::string rim_name = mesh::ops::numbered_name("shell", with_surface);

    MeshData made;
    if (plan.method == 0) {
        if (!fast_shell(*state, plan, surface_name, rim_name, made, deadline)) {
            return late();
        }
        phases.mark("offset");
    }
    else {
        const mesh::TriBvh* bvh = mesh::bvh_of(*state, &deadline);
        if (bvh == nullptr) {
            return late();
        }
        const mesh::voxel::Grid grid = mesh::voxel::make_grid(plan.lo, plan.hi, plan.margin, plan.detail);
        const double reach = (plan.direction == 2 ? 0.5 * t : t) + 2.5 * plan.detail;
        std::vector<float> f;
        if (!mesh::voxel::distance_field(*bvh, grid, reach, f, deadline)) {
            return late();
        }
        if (plan.direction == 2) {
            // Both: the band within half a wall of the surface (no inside needed).
            for (float& value : f) {
                value = float(0.5 * t - double(value));
            }
        }
        else {
            std::vector<uint8_t> inside;
            if (!mesh::voxel::winding_field(*bvh, grid, false, inside, deadline)) {
                return late();
            }
            // Inside: what lies deeper than the wall. Outside: everything up to a wall away.
            for (size_t i = 0; i < f.size(); ++i) {
                const double signed_distance = inside[i] != 0 ? double(f[i]) : -double(f[i]);
                f[i] = float(plan.direction == 0 ? signed_distance - t : signed_distance + t);
            }
        }
        phases.mark("field");
        std::string error;
        mesh::mf::Import imported;
        try {
            manifold::ExecutionContext ctx;
            const mesh::mf::Watchdog watchdog(ctx, deadline);
            double guard_below = 0.0;
            const manifold::Manifold level = mesh::mf::level_set(ctx, grid, f, guard_below);
            mesh::mf::Status status = level.Status();
            phases.mark("level_set");
            if (status == mesh::mf::Status::Cancelled || deadline.expired()) {
                return late();
            }
            if (status != mesh::mf::Status::NoError) {
                fail(mesh::mf::status_text(status, "Shell"));
                return Ref<CadMesh>();
            }
            if (mesh::mf::only_guard(level, guard_below)) {
                fail("A " + mesh::ops::length_text(t) + " wall leaves no room inside " + plan.name + ". Use a thinner wall.");
                return Ref<CadMesh>();
            }
            manifold::Manifold result = level;
            std::vector<uint32_t> run_ids;
            if (plan.direction != 2) {
                const uint32_t run_id = manifold::Manifold::ReserveIDs(1);
                run_ids.push_back(run_id);
                const manifold::Manifold body = ctx.FromMeshGL(mesh::mf::to_gl(input, run_id, 0));
                status = body.Status();
                phases.mark("ingest");
                if (status == mesh::mf::Status::Cancelled || deadline.expired()) {
                    return late();
                }
                if (status != mesh::mf::Status::NoError) {
                    fail(mesh::mf::status_text(status, "Shell"));
                    return Ref<CadMesh>();
                }
                result = (plan.direction == 0 ? body.Boolean(level, manifold::OpType::Subtract) : level.Boolean(body, manifold::OpType::Subtract)).WithContext(ctx);
                status = result.Status();
                phases.mark("boolean");
                if (status == mesh::mf::Status::Cancelled || deadline.expired()) {
                    return late();
                }
                if (status != mesh::mf::Status::NoError) {
                    fail(mesh::mf::status_text(status, "Shell"));
                    return Ref<CadMesh>();
                }
            }
            if (!mesh::mf::from_gl(result.GetMeshGL64(), run_ids, plan.direction == 2 ? std::vector<std::string>() : input.group_names, surface_name, imported, error)) {
                fail("Shell failed: " + error + ". Raise Detail.");
                return Ref<CadMesh>();
            }
            mesh::mf::drop_guard(imported, guard_below);
        }
        catch (const std::exception& e) {
            fail(std::string("Shell failed inside the mesh library: ") + e.what());
            return Ref<CadMesh>();
        }
        catch (...) {
            fail("Shell failed inside the mesh library.");
            return Ref<CadMesh>();
        }
        made = std::move(imported.mesh);
        phases.mark("export");
    }
    if (deadline.expired()) {
        return late();
    }
    // The wall, measured on the new surface before the result is packed (group ids are still
    // the input's, then the new surface, then the rim).
    const bool every = plan.direction == 2;
    const uint32_t surface_group = plan.method == 1 && every ? 0u : uint32_t(input_groups);
    const double target = every ? 0.5 * t : t;
    const double low = plan.method == 1 ? 0.8 : 0.7, high = plan.method == 1 ? 1.2 : 1.3;
    const Wall wall = measure_wall(
        made,
        [&](uint32_t tri) {
            const uint32_t g = made.groups[tri];
            if (plan.method == 1) {
                return every || g == surface_group;
            }
            return every ? g <= surface_group : g == surface_group;  // (fast: never the rim)
        },
        *state, target, low, high);

    phases.mark("wall");
    Ref<CadMesh> out = finish_op("Shell", "shell", std::move(made), started, false);
    phases.mark("finish");
    if (out.is_null()) {
        return out;
    }
    Dictionary checks = last_report["checks"];
    PackedStringArray warnings;
    auto broken = [&](const char* key, const std::string& sentence) {
        checks[key] = String("fail: ") + mesh::ops::text(sentence);
        last_report["checks"] = checks;
        last_warning = String();
        fail(sentence);
        return Ref<CadMesh>();
    };
    last_report["wall"] = wall_dict(wall);
    const mesh::Summary before = mesh::summarize(*state);
    const mesh::Summary after = mesh::summarize(out->get_state());
    // Must hold: closed and manifold (a shell of an open body is closed too: the rim, or the band).
    if (after.boundary_edges > 0 || after.non_manifold_edges > 0) {
        return broken("closed", "Shell made a mesh that is not closed (" + mesh::ops::count_text(after.boundary_edges, "open edge", "open edges") + ", " +
                                    mesh::ops::count_text(after.non_manifold_edges, "edge", "edges") + " shared by more than two triangles). Please report it.");
    }
    checks["closed"] = "ok";
    // Must hold (accurate): a wall has volume, and an inside wall less than the body it is cut from.
    if (plan.method == 1 && (!(after.volume > 0.0) || (plan.direction == 0 && before.closed && before.volume > 0.0 && after.volume > before.volume * (1.0 + 1e-6)))) {
        return broken("volume", "Shell made a wall of " + mesh::ops::plain_number(after.volume * 1e9, 6) + " mm3 on a body of " + mesh::ops::plain_number(before.volume * 1e9, 6) +
                                    " mm3, which cannot be right: " + plan.name + " may cross itself or have parts that face the wrong way. Rebuild it first.");
    }
    checks["volume"] = "ok";
    // Crossings in the result, less those the body had (when both could be counted).
    const int64_t crossings = mesh::ops::crossings(out->get_state(), deadline);
    last_report["self_intersections"] = crossings;
    last_report["input_self_intersections"] = input_crossings;
    // (Both, accurate, is a level set alone: any crossing in it is its own.)
    const bool level_set_alone = plan.method == 1 && plan.direction == 2;
    const int64_t made_crossings = crossings > 0 ? (input_crossings > 0 && !level_set_alone ? crossings - input_crossings : crossings) : 0;
    if (!last_warning.is_empty()) {
        // (finish_op's own sentences: parts inside-out, new triangles without area.)
        warnings.push_back(last_warning);
    }
    if (plan.method == 1) {
        if (made_crossings > 0) {
            if (input_crossings < 0 && !level_set_alone) {
                return broken("self_intersections", "The shell crosses itself in " + mesh::ops::count_text(made_crossings, "place", "places") + ": " + plan.name +
                                                        " may cross itself (it is too large to test in 1 s). Rebuild it first.");
            }
            return broken("self_intersections", "The accurate shell crosses itself in " + mesh::ops::count_text(made_crossings, "place", "places") + " (internal error). Please report it.");
        }
        if (!wall.passed) {
            return broken("wall", wall_sentence(wall, low, high, "Lower Detail, or use a thicker wall."));
        }
        checks["wall"] = "ok";
        checks["self_intersections"] = crossings < 0 ? "warn: not tested in time" : "ok";
        if (plan.direction != 2 && input_crossings < 0) {
            warnings.push_back(mesh::ops::text(plan.name_start + " could not be tested for places where it crosses itself (it is too large to test in 1 s); if it does, the shell is wrong there."));
            checks["self_intersections"] = "warn: the input could not be tested in time";
        }
        if (plan.direction == 2 && input_groups > 1) {
            // Both makes a new surface on each side of the body's: none of it is the body's own.
            warnings.push_back(mesh::ops::text(plan.name_start + "'s " + mesh::with_commas(input_groups) + " face groups became one (" + surface_name +
                                               "): Both makes a new surface on each side."));
            checks["groups"] = "warn: the face groups became one";
        }
    }
    else {
        // Fast was the user's choice: what is off is said, with numbers, and the result is kept.
        if (made_crossings > 0) {
            warnings.push_back(mesh::ops::text("The fast shell crosses itself in " + mesh::ops::count_text(made_crossings, "place", "places") + "; use Accurate."));
            checks["self_intersections"] = "warn: the fast shell crosses itself";
        }
        else if (crossings < 0) {
            warnings.push_back("The fast shell was not tested for places where it crosses itself (the mesh is too large to test in 1 s); use Accurate to be sure.");
            checks["self_intersections"] = "warn: not tested in time";
        }
        else {
            checks["self_intersections"] = "ok";
        }
        if (!wall.passed) {
            warnings.push_back(mesh::ops::text(wall_sentence(wall, low, high, "Use Accurate.")));
            checks["wall"] = "warn: the wall is off";
        }
        else {
            checks["wall"] = "ok";
        }
    }
    last_report["checks"] = checks;
    last_report["cells"] = plan.cells;
    last_report["detail"] = plan.detail;
    last_report["thickness"] = t;
    phases.mark("crossings");
    last_report["phases"] = phases.ms;
    last_report["estimate"] = plan.seconds;
    last_report["ms"] = mesh::ops::now_ms() - started;
    last_warning = String("\n").join(warnings);
    return out;
}

}  // namespace holo_forge
