// Close Holes (work order 3.2.1). Each open loop gets our own triangulation between its own
// vertices (a minimal-area-and-dihedral dynamic program for loops up to FILL_DP_MAX_EDGES edges,
// ear clipping on the loop's best plane above that). Smooth and flat fills then refine the patch
// to the loop's edge size; smooth fairs it with pmp on a small sub-mesh of the patch and three
// rings of the triangles around the hole, so a hole's cost depends on that hole only. pmp's own
// fill_hole is never called. Original triangles and vertices are never touched.

#include "cad_mesh.h"
#include "mesh_pmp.h"

#include <godot_cpp/variant/packed_string_array.hpp>

#include <pmp/algorithms/fairing.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <exception>
#include <limits>
#include <queue>
#include <unordered_map>
#include <unordered_set>

using namespace godot;

namespace holo_forge
{

namespace mesh
{
namespace
{
const char* kFillHint = "Close fewer holes at once, or use Wrap.";

struct FillOptions
{
    int fill = 1;  // 0 minimal, 1 smooth, 2 flat
    int64_t max_edges = 0;
    bool refine = true;
    bool loops_given = false;
    std::vector<int32_t> loops;
};

struct FillStats
{
    std::vector<int32_t> filled, too_large, broken, unsmoothed, folded;
    std::vector<int32_t> outline;  // loops that are the outline of an open sheet, not holes
    std::vector<int32_t> outline_closed;  // loops that look like one, but were picked: closed
    std::vector<int32_t> replaced;        // smooth fills that ran away from their hole: the flat fill instead
    double replaced_reach = 0.0, replaced_width = 0.0;  // the furthest of them: how far, and how wide its hole is
    std::vector<int32_t> left_outline;    // smooth fills that ran out of their hole's outline: the flat fill instead
    double left_by = 0.0, left_long = 0.0, left_wide = 0.0;  // the furthest of them: how far out, and its hole's size
    std::vector<int32_t> kept_smooth;     // smooth fills that were kept
    double bulge = 0.0;                   // their volume against the flat fill's (signed, as the body's)
    double rise = 0.0;                    // the furthest any of them lies off its hole's plane
    std::vector<std::string> names;
    size_t new_triangles = 0, new_vertices = 0, filled_edges = 0;
    bool nothing = false;  // no open loop at all
    double triangulate_ms = 0.0, refine_ms = 0.0, fair_ms = 0.0;
    size_t fair_vertices = 0;  // free vertices of the largest fairing solve
};

/// True for a triangle of three points that has no area to speak of: the rule of
/// mesh::without_area (its height over its longest edge is at most 1e-12 x that edge or 6e-8 x
/// its largest coordinate), four times as strict, so that no triangle the fill makes by choice
/// comes near what check() counts.
bool needle(const V3& a, const V3& b, const V3& c)
{
    const double longest2 = std::max(dot(b - a, b - a), std::max(dot(c - b, c - b), dot(a - c, a - c)));
    if (!(longest2 > 0.0)) {
        return true;
    }
    const double longest = std::sqrt(longest2);
    double reach = 0.0;
    for (const V3* p : {&a, &b, &c}) {
        reach = std::max(reach, std::max(std::fabs(p->x), std::max(std::fabs(p->y), std::fabs(p->z))));
    }
    return length(cross(b - a, c - a)) / longest <= 4.0 * std::max(1e-12 * longest, 6e-8 * reach);
}

struct Tri
{
    uint32_t a, b, c;  // into the patch polygon
};

/// The triangulation of the closed polygon q (a hole's loop, in the order the patch runs it)
/// that keeps the largest angle between neighbouring triangles (and to the triangles outside,
/// whose unit normals are outside[i] across the edge q[i] q[i + 1]) smallest, and then the area
/// smallest: a dynamic program over the loop, O(n^3). Before either comes the number of
/// triangles without area (three loop vertices on one straight side): as few as the loop
/// allows, none where a triangulation without one exists; such a triangle bends nothing and
/// adds no area, so the other two measures would pick it gladly, and the vertices along a
/// straight side would never become corners of real triangles. A diagonal in `taken` (two loop vertices
/// the mesh already joins by an edge) is not used: a third triangle on that edge would break
/// the mesh. False when the deadline passed; clean is false when no triangulation without a
/// taken diagonal exists (out is then empty).
bool triangulate_minimal(const std::vector<V3>& q, const std::vector<V3>& outside, const std::unordered_set<uint64_t>& taken, std::vector<Tri>& out, bool& clean,
                         const Deadline& deadline)
{
    const size_t n = q.size();
    const float kTaken = 1e6f;
    clean = true;
    out.clear();
    if (n < 3) {
        return true;
    }
    if (n == 3) {
        out.push_back({0, 1, 2});
        return true;
    }
    // w(i, k): the best way to fill the polygon q[i..k]; kept as (bend, area), the split
    // vertex, and the unit normal of the triangle (i, split, k).
    std::vector<float> bend(n * n, 0.0f);
    std::vector<uint32_t> needles(n * n, 0);  // triangles without area in the best way
    std::vector<double> area(n * n, 0.0);
    std::vector<int32_t> split(n * n, -1);
    std::vector<float> normal(n * n * 3, 0.0f);
    auto at = [n](size_t i, size_t k) { return i * n + k; };
    auto normal_of = [&](size_t i, size_t k) -> V3 {
        if (k == i + 1) {
            return outside[i];
        }
        const float* p = &normal[at(i, k) * 3];
        return V3(p[0], p[1], p[2]);
    };
    auto angle_between = [](const V3& a, const V3& b) -> float {
        // 1 - cos: 0 when flat, 2 when folded back. A triangle without area bends nothing.
        if (dot(a, a) == 0.0 || dot(b, b) == 0.0) {
            return 0.0f;
        }
        return float(1.0 - dot(a, b));
    };
    for (size_t span = 2; span < n; ++span) {
        for (size_t i = 0; i + span < n; ++i) {
            const size_t k = i + span;
            float best_bend = std::numeric_limits<float>::infinity();
            double best_area = std::numeric_limits<double>::infinity();
            uint32_t best_needles = std::numeric_limits<uint32_t>::max();
            bool best_taken = true;
            int32_t best = -1;
            V3 best_normal;
            for (size_t m = i + 1; m < k; ++m) {
                const V3 cr = cross(q[m] - q[i], q[k] - q[i]);
                const double twice = length(cr);
                const bool thin = needle(q[i], q[m], q[k]);
                // (A triangle without area has no direction: it bends nothing.)
                const V3 nrm = twice > 0.0 && !thin ? cr * (1.0 / twice) : V3();
                const uint32_t count = needles[at(i, m)] + needles[at(m, k)] + (thin ? 1u : 0u);
                float b = std::max(bend[at(i, m)], bend[at(m, k)]);
                b = std::max(b, angle_between(nrm, normal_of(i, m)));
                b = std::max(b, angle_between(nrm, normal_of(m, k)));
                if (span == n - 1) {
                    // The whole loop: the closing edge q[n - 1] q[0] has a triangle outside too.
                    b = std::max(b, angle_between(nrm, outside[n - 1]));
                }
                const double a = area[at(i, m)] + area[at(m, k)] + 0.5 * twice;
                // In this order: no diagonal the mesh holds already, the fewest triangles
                // without area, the least bend, the least area.
                const bool over = b >= kTaken;
                const bool better = best < 0 || (over != best_taken ? !over : (count != best_needles ? count < best_needles : (b < best_bend || (b == best_bend && a < best_area))));
                if (better) {
                    best_bend = b;
                    best_area = a;
                    best_needles = count;
                    best_taken = over;
                    best = int32_t(m);
                    best_normal = nrm;
                }
            }
            if (span < n - 1 && !taken.empty() && taken.count((uint64_t(i) << 32) | k) != 0) {
                best_bend = kTaken;
            }
            bend[at(i, k)] = best_bend;
            needles[at(i, k)] = best_needles;
            area[at(i, k)] = best_area;
            split[at(i, k)] = best;
            normal[at(i, k) * 3] = float(best_normal.x);
            normal[at(i, k) * 3 + 1] = float(best_normal.y);
            normal[at(i, k) * 3 + 2] = float(best_normal.z);
        }
        if (deadline.expired()) {
            return false;
        }
    }
    if (bend[at(0, n - 1)] >= kTaken) {
        clean = false;
        return true;
    }
    std::vector<std::pair<uint32_t, uint32_t>> stack;
    stack.push_back({0, uint32_t(n - 1)});
    while (!stack.empty()) {
        const std::pair<uint32_t, uint32_t> range = stack.back();
        stack.pop_back();
        if (range.second < range.first + 2) {
            continue;
        }
        const int32_t m = split[at(range.first, range.second)];
        out.push_back({range.first, uint32_t(m), range.second});
        stack.push_back({range.first, uint32_t(m)});
        stack.push_back({uint32_t(m), range.second});
    }
    return true;
}

/// Ear clipping of the polygon q on its best plane, shortest diagonal first; where the flat
/// picture folds over itself and no ear is left, the rest is closed by the ear of least area in
/// space. Diagonals in `taken` are not used (see triangulate_minimal). False when the deadline
/// passed; clean is false when the loop could not be closed without a taken diagonal.
bool triangulate_ears(const std::vector<V3>& q, const std::unordered_set<uint64_t>& taken, std::vector<Tri>& out, bool& clean, const Deadline& deadline)
{
    const size_t n = q.size();
    clean = true;
    out.clear();
    auto is_taken = [&](uint32_t a, uint32_t c) { return !taken.empty() && taken.count((uint64_t(std::min(a, c)) << 32) | std::max(a, c)) != 0; };
    if (n < 3) {
        return true;
    }
    // The best plane: the polygon's area vector.
    V3 centre, area_vector;
    for (size_t i = 0; i < n; ++i) {
        centre += q[i] * (1.0 / double(n));
    }
    for (size_t i = 0; i < n; ++i) {
        area_vector += cross(q[i] - centre, q[(i + 1) % n] - centre);
    }
    const V3 up = normalized(area_vector);
    V3 x = normalized(cross(up, std::fabs(up.x) < 0.9 ? V3(1, 0, 0) : V3(0, 1, 0)));
    const V3 y = cross(up, x);
    std::vector<double> u(n), v(n);
    for (size_t i = 0; i < n; ++i) {
        u[i] = dot(q[i] - centre, x);
        v[i] = dot(q[i] - centre, y);
    }
    std::vector<uint32_t> prev(n), next(n), version(n, 0);
    std::vector<uint8_t> gone(n, 0);
    for (size_t i = 0; i < n; ++i) {
        prev[i] = uint32_t((i + n - 1) % n);
        next[i] = uint32_t((i + 1) % n);
    }
    auto turn = [&](uint32_t a, uint32_t b, uint32_t c) { return (u[b] - u[a]) * (v[c] - v[a]) - (v[b] - v[a]) * (u[c] - u[a]); };
    // A corner that turns left by more than rounding: three vertices along a straight side do
    // not (an ear cut there would be a triangle without area).
    auto turns_left = [&](uint32_t a, uint32_t b, uint32_t c) { return turn(a, b, c) > 0.0 && !needle(q[a], q[b], q[c]); };
    size_t left = n;
    const bool flat = length(area_vector) > 0.0;
    struct Ear
    {
        double key;
        uint32_t vertex, version;
        bool operator<(const Ear& o) const
        {
            return key != o.key ? key > o.key : vertex > o.vertex;
        }
    };
    if (flat) {
        std::priority_queue<Ear> queue;
        auto offer = [&](uint32_t b) {
            if (turns_left(prev[b], b, next[b])) {
                queue.push({length(q[next[b]] - q[prev[b]]), b, version[b]});
            }
        };
        for (uint32_t i = 0; i < n; ++i) {
            offer(i);
        }
        while (left > 3 && !queue.empty()) {
            const Ear ear = queue.top();
            queue.pop();
            const uint32_t b = ear.vertex;
            if (gone[b] || ear.version != version[b]) {
                continue;
            }
            const uint32_t a = prev[b], c = next[b];
            if (!turns_left(a, b, c) || (left > 3 && is_taken(a, c))) {
                continue;
            }
            // No other corner of what is left may lie inside the ear (only corners that turn
            // the other way can).
            bool empty = true;
            for (uint32_t p = next[c]; p != a; p = next[p]) {
                if (turns_left(prev[p], p, next[p])) {
                    continue;
                }
                if (turn(a, b, p) >= 0.0 && turn(b, c, p) >= 0.0 && turn(c, a, p) >= 0.0) {
                    empty = false;
                    break;
                }
                if (deadline.tick()) {
                    return false;
                }
            }
            if (!empty) {
                continue;
            }
            out.push_back({a, b, c});
            gone[b] = 1;
            next[a] = c;
            prev[c] = a;
            --left;
            ++version[a];
            ++version[c];
            offer(a);
            offer(c);
            if (deadline.tick()) {
                return false;
            }
        }
    }
    if (left > 3) {
        // The rest: least area in space first.
        std::priority_queue<Ear> queue;
        // (Ears without area last: only when nothing else is left.)
        auto offer = [&](uint32_t b) {
            const double twice = length(cross(q[b] - q[prev[b]], q[next[b]] - q[prev[b]]));
            queue.push({needle(q[prev[b]], q[b], q[next[b]]) ? std::numeric_limits<double>::max() : twice, b, version[b]});
        };
        for (uint32_t i = 0; i < n; ++i) {
            if (!gone[i]) {
                offer(i);
            }
        }
        while (left > 3 && !queue.empty()) {
            const Ear ear = queue.top();
            queue.pop();
            const uint32_t b = ear.vertex;
            if (gone[b] || ear.version != version[b]) {
                continue;
            }
            const uint32_t a = prev[b], c = next[b];
            if (left > 3 && is_taken(a, c)) {
                continue;
            }
            out.push_back({a, b, c});
            gone[b] = 1;
            next[a] = c;
            prev[c] = a;
            --left;
            ++version[a];
            ++version[c];
            offer(a);
            offer(c);
            if (deadline.tick()) {
                return false;
            }
        }
    }
    if (left > 3) {
        clean = false;
        out.clear();
        return true;
    }
    if (left == 3) {
        for (uint32_t i = 0; i < n; ++i) {
            if (!gone[i]) {
                out.push_back({prev[i], i, next[i]});
                break;
            }
        }
    }
    return true;
}

double fill_triangulation_estimate(size_t edges)
{
    const double n = double(edges);
    if (edges <= budget::FILL_DP_MAX_EDGES) {
        return budget::FILL_DP_SECONDS_AT_400 * (n / 400.0) * (n / 400.0) * (n / 400.0);
    }
    return budget::FILL_EAR_SECONDS_AT_10K * (n / 1e4) * (n / 1e4);
}

double fair_estimate(double free_vertices)
{
    return budget::FAIR_SECONDS_AT_10K * std::pow(std::max(free_vertices, 1.0) / 1e4, budget::FAIR_POWER);
}

/// Triangles around each vertex.
struct VertexTriangles
{
    std::vector<uint32_t> first, tris;
    void build(const MeshData& m)
    {
        const size_t V = m.vertex_count(), T = m.triangle_count();
        first.assign(V + 1, 0);
        for (const uint32_t v : m.triangles) {
            ++first[size_t(v) + 1];
        }
        for (size_t v = 0; v < V; ++v) {
            first[v + 1] += first[v];
        }
        tris.resize(T * 3);
        std::vector<uint32_t> cursor(first.begin(), first.end() - 1);
        for (size_t t = 0; t < T; ++t) {
            for (int k = 0; k < 3; ++k) {
                tris[cursor[m.triangles[t * 3 + size_t(k)]]++] = uint32_t(t);
            }
        }
    }
};

bool close_holes(State& state, const FillOptions& opt, const Deadline& deadline, MeshData& out, FillStats& stats, std::string& error)
{
    const MeshData& m = state.data;
    const size_t T = m.triangle_count(), V = m.vertex_count();
    const Topology* topo = topology_of(state, &deadline);
    const std::string late = timed_out_text("Close Holes", deadline.limit(), kFillHint);
    if (topo == nullptr) {
        error = late;
        return false;
    }
    if (topo->non_manifold_edges > 0) {
        error = "The mesh has " + counted(uint64_t(topo->non_manifold_edges), "non-manifold edge", "non-manifold edges") + ". Run Stitch and Remove first.";
        return false;
    }
    if (topo->boundary_edges == 0) {
        stats.nothing = true;
        out = m;
        return true;
    }
    const std::vector<BoundaryLoop> loops = boundary_loops(state);
    std::vector<int32_t> wanted;
    if (opt.loops_given) {
        for (const int32_t id : opt.loops) {
            if (id < 0 || size_t(id) >= loops.size()) {
                error = "Hole " + std::to_string(id) + " is not in the mesh (it has " + with_commas(loops.size()) + " open loops). Pick the holes again.";
                return false;
            }
            wanted.push_back(id);
        }
        std::sort(wanted.begin(), wanted.end());
        wanted.erase(std::unique(wanted.begin(), wanted.end()), wanted.end());
    }
    else {
        for (size_t i = 0; i < loops.size(); ++i) {
            wanted.push_back(int32_t(i));
        }
    }
    // Which loops can be closed; and the cost of each, before any work.
    struct Hole
    {
        int32_t id;
        double edge;        // mean edge length of the loop
        double patch_vertices;  // expected new vertices
    };
    std::vector<Hole> holes;
    std::vector<uint32_t> stamp(V, 0);
    uint32_t epoch = 0;
    double estimate = 0.0, new_triangles = 0.0;
    const bool refine = opt.fill != 0 && opt.refine;
    for (const int32_t id : wanted) {
        const BoundaryLoop& loop = loops[size_t(id)];
        const size_t n = loop.vertices.size();
        if (opt.max_edges > 0 && int64_t(n) > opt.max_edges) {
            stats.too_large.push_back(id);
            continue;
        }
        // A loop that does not close, or passes a vertex twice (surfaces that only touch
        // there), cannot be closed by a disc.
        bool sound = loop.closed && n >= 3;
        ++epoch;
        for (size_t i = 0; i < n && sound; ++i) {
            sound = stamp[loop.vertices[i]] != epoch;
            stamp[loop.vertices[i]] = epoch;
        }
        if (!sound) {
            stats.broken.push_back(id);
            continue;
        }
        Hole hole{id, loop.length / double(n), 0.0};
        estimate += fill_triangulation_estimate(n);
        new_triangles += double(n) - 2.0;
        if (refine && hole.edge > 0.0) {
            V3 centre, area_vector;
            for (size_t i = 0; i < n; ++i) {
                centre += point_of(m, loop.vertices[i]) * (1.0 / double(n));
            }
            for (size_t i = 0; i < n; ++i) {
                area_vector += cross(point_of(m, loop.vertices[i]) - centre, point_of(m, loop.vertices[(i + 1) % n]) - centre);
            }
            const double triangles = 0.5 * length(area_vector) / (0.433 * hole.edge * hole.edge);
            hole.patch_vertices = std::max(0.0, 0.5 * (triangles - double(n)));
            if (hole.patch_vertices > double(budget::MAX_FILL_FREE_VERTICES)) {
                error = "A hole of " + with_commas(n) + " edges would need about " + with_commas(uint64_t(hole.patch_vertices)) + " new vertices (limit " +
                        with_commas(budget::MAX_FILL_FREE_VERTICES) + "). Turn off Match Edge Size, use the Minimal fill, or use Wrap.";
                return false;
            }
            new_triangles += 2.0 * hole.patch_vertices;
            estimate += budget::FILL_REFINE_SECONDS_PER_1K_VERTICES * hole.patch_vertices / 1e3;
            if (opt.fill == 1) {
                estimate += fair_estimate(hole.patch_vertices);
            }
        }
        holes.push_back(hole);
    }
    if (holes.empty()) {
        out = m;
        return true;
    }
    if (double(T) + new_triangles > double(budget::MAX_TRIANGLES_MESH)) {
        error = "Close Holes would make about " + with_commas(uint64_t(double(T) + new_triangles)) + " triangles; mesh bodies take up to " + with_commas(budget::MAX_TRIANGLES_MESH) +
                ". Turn off Match Edge Size, or Reduce the body first.";
        return false;
    }
    if (m.group_count() + holes.size() > budget::MAX_GROUPS_MESH) {
        error = "Closing " + with_commas(holes.size()) + " holes would make more face groups than a mesh body takes (" + with_commas(budget::MAX_GROUPS_MESH) + "). " + kFillHint;
        return false;
    }
    // (The triangles around each vertex, once for the body.)
    estimate += post_check_estimate(double(T) + new_triangles, true) + 2.0 * budget::estimate(budget::TOPOLOGY, double(T));
    if (estimate > deadline.limit()) {
        error = too_slow_text("Close Holes", estimate, deadline.limit(), kFillHint);
        return false;
    }

    out = m;
    // The triangle at each open edge, by the edge's two vertices in the triangle's direction.
    std::unordered_map<uint64_t, uint32_t> open_triangle;
    open_triangle.reserve(topo->boundary_edges);
    for (size_t e = 0; e < topo->edge_count(); ++e) {
        if (topo->uses(uint32_t(e)) == 1) {
            const uint32_t he = topo->edge_hes[topo->edge_first[e]];
            open_triangle[(uint64_t(m.triangles[he]) << 32) | m.triangles[he - he % 3 + (he + 1) % 3]] = he / 3;
        }
    }
    std::unordered_set<std::string> taken(m.group_names.begin(), m.group_names.end());
    size_t name_counter = 0;
    VertexTriangles around;
    around.build(m);
    std::vector<uint32_t> tri_stamp(T, 0), sub_index(V, NONE);
    uint32_t tri_epoch = 0;

    const Components* comps = nullptr;  // the pieces and their vertices, when the outline rule needs them
    std::vector<uint32_t> piece_first, piece_vertices;
    for (const Hole& hole : holes) {
        const BoundaryLoop& loop = loops[size_t(hole.id)];
        const size_t n = loop.vertices.size();
        // The patch runs the loop backward (each open edge the other way than its triangle).
        std::vector<uint32_t> ring(n);
        std::vector<V3> q(n);
        for (size_t i = 0; i < n; ++i) {
            ring[i] = loop.vertices[n - 1 - i];
            q[i] = point_of(m, ring[i]);
        }
        // The triangle outside each patch edge q[i] q[i + 1]: found from the half-edge that runs
        // it the other way.
        std::vector<V3> outside(n);
        uint32_t loop_triangle = NONE;  // a triangle of the mesh on this loop
        for (size_t i = 0; i < n; ++i) {
            const auto it = open_triangle.find((uint64_t(ring[(i + 1) % n]) << 32) | ring[i]);
            if (it != open_triangle.end()) {
                outside[i] = normalized(triangle_cross(m, it->second));
                loop_triangle = loop_triangle == NONE ? it->second : loop_triangle;
            }
        }
        // Pairs of loop vertices the mesh already joins by an edge that is not the loop's own.
        std::unordered_set<uint64_t> joined;
        for (size_t i = 0; i < n; ++i) {
            sub_index[ring[i]] = uint32_t(i);
        }
        for (size_t i = 0; i < n; ++i) {
            for (uint32_t a = around.first[ring[i]]; a < around.first[size_t(ring[i]) + 1]; ++a) {
                const uint32_t* tri = &m.triangles[size_t(around.tris[a]) * 3];
                for (int k = 0; k < 3; ++k) {
                    const uint32_t j = sub_index[tri[k]];
                    if (j == NONE || j <= i) {
                        continue;
                    }
                    if (j - i != 1 && !(i == 0 && j == n - 1)) {
                        joined.insert((uint64_t(i) << 32) | j);
                    }
                }
            }
        }
        for (size_t i = 0; i < n; ++i) {
            sub_index[ring[i]] = NONE;
        }
        std::vector<Tri> tris;
        bool clean = true;
        const double triangulate_started = op_now_ms();
        const bool ok = n <= budget::FILL_DP_MAX_EDGES ? triangulate_minimal(q, outside, joined, tris, clean, deadline) : triangulate_ears(q, joined, tris, clean, deadline);
        stats.triangulate_ms += op_now_ms() - triangulate_started;
        if (!ok || deadline.expired()) {
            error = late;
            return false;
        }
        if (!clean) {
            // No disc fits this loop without a third triangle on an edge of the mesh.
            stats.broken.push_back(hole.id);
            continue;
        }
        {
            // The outline of an open sheet is not a hole: a patch across it would fold back over
            // the sheet and only lay a second surface on it (one triangle "closed" this way is
            // two triangles without volume). Two things together tell an outline:
            // - the fill folds back: along 9 loop edges of 10, the fill (its mean normal) lies
            //   within 60 degrees of the sheet's triangle there;
            // - the sheet does not rise out of the loop to one side: taken along the normal of
            //   the loop's best plane, the sheet's vertices stay within the heights of the
            //   loop's own vertices (give or take 0.5 % of the loop's radius), or leave them on
            //   both sides. A shallow cone, a cap or a tray rises to one side: closing it makes
            //   a solid. A flat, wavy, saddle or bent sheet does not.
            // A loop that was picked is closed all the same, and the look of it is said.
            // (The fill's mean normal is taken, not the normal of the fill triangle at each
            // edge: along a side that is straight seen from above but wavy in height those
            // triangles stand upright and say nothing about the fill.)
            V3 fill_area;
            for (const Tri& t : tris) {
                fill_area += cross(q[t.b] - q[t.a], q[t.c] - q[t.a]);
            }
            const V3 mean_normal = normalized(fill_area);
            size_t judged = 0, back = 0;
            for (size_t i = 0; i < n; ++i) {
                if (dot(outside[i], outside[i]) > 0.0) {
                    ++judged;
                    back += dot(mean_normal, outside[i]) < -0.5 ? 1 : 0;
                }
            }
            bool is_outline = judged > 0 && back * 10 >= judged * 9;
            if (is_outline && loop_triangle != NONE) {
                if (comps == nullptr) {
                    comps = components_of(state, &deadline);
                    if (comps == nullptr) {
                        error = late;
                        return false;
                    }
                    // The vertices of each piece, once.
                    std::vector<uint32_t> piece_of(V, NONE);
                    piece_first.assign(comps->list.size() + 1, 0);
                    for (size_t t = 0; t < T; ++t) {
                        for (int k = 0; k < 3; ++k) {
                            const uint32_t v = m.triangles[t * 3 + size_t(k)];
                            if (piece_of[v] == NONE) {
                                piece_of[v] = uint32_t(comps->of_triangle[t]);
                                ++piece_first[size_t(piece_of[v]) + 1];
                            }
                        }
                    }
                    for (size_t c = 0; c < comps->list.size(); ++c) {
                        piece_first[c + 1] += piece_first[c];
                    }
                    piece_vertices.resize(piece_first.back());
                    std::vector<uint32_t> fill_at(piece_first.begin(), piece_first.end() - 1);
                    for (size_t v = 0; v < V; ++v) {
                        if (piece_of[v] != NONE) {
                            piece_vertices[fill_at[piece_of[v]]++] = uint32_t(v);
                        }
                    }
                }
                V3 middle, area;
                for (size_t i = 0; i < n; ++i) {
                    middle += q[i] * (1.0 / double(n));
                }
                for (size_t i = 0; i < n; ++i) {
                    area += cross(q[i] - middle, q[(i + 1) % n] - middle);
                }
                const V3 normal = normalized(area);
                double radius = 0.0, loop_low = std::numeric_limits<double>::infinity(), loop_high = -std::numeric_limits<double>::infinity();
                for (size_t i = 0; i < n; ++i) {
                    radius = std::max(radius, length(q[i] - middle));
                    const double h = dot(q[i] - middle, normal);
                    loop_low = std::min(loop_low, h);
                    loop_high = std::max(loop_high, h);
                }
                double low = loop_low, high = loop_high;
                const size_t piece = size_t(comps->of_triangle[loop_triangle]);
                for (uint32_t i = piece_first[piece]; i < piece_first[piece + 1]; ++i) {
                    const double h = dot(point_of(m, piece_vertices[i]) - middle, normal);
                    low = std::min(low, h);
                    high = std::max(high, h);
                    if (deadline.tick()) {
                        error = late;
                        return false;
                    }
                }
                const double slack = 0.005 * radius;
                const bool above = high - loop_high > slack, below = loop_low - low > slack;
                is_outline = above == below;  // neither side, or both
            }
            if (is_outline) {
                if (!opt.loops_given) {
                    stats.outline.push_back(hole.id);
                    continue;
                }
                stats.outline_closed.push_back(hole.id);
            }
        }
        std::vector<V3> inner;  // new vertices of the patch, after the loop's own
        bool faired = false;
        const double refine_started = op_now_ms();
        if (refine && hole.edge > 0.0 && n > 3) {
            // --- Refine: split the patch's inner edges longer than 1.33 x the loop's mean edge
            // at their middle, flipping edges toward equal angles, until none is left.
            pmp::SurfaceMesh patch;
            try {
                for (const V3& p : q) {
                    patch.add_vertex(pmp::Point(float(p.x), float(p.y), float(p.z)));
                }
                for (const Tri& t : tris) {
                    patch.add_triangle(pmp::Vertex(t.a), pmp::Vertex(t.b), pmp::Vertex(t.c));
                }
            }
            catch (const std::exception&) {
                patch.clear();
            }
            if (patch.n_faces() == tris.size()) {
                const double longest = 1.33 * hole.edge;
                const size_t cap = size_t(std::max(4.0 * hole.patch_vertices + 64.0, 256.0));
                bool capped = false;
                for (int round = 0; round < 40 && !capped; ++round) {
                    bool any = false;
                    const size_t edges = patch.n_edges();
                    for (size_t i = 0; i < edges; ++i) {
                        const pmp::Edge e{pmp::IndexType(i)};
                        if (patch.is_boundary(e)) {
                            continue;
                        }
                        const pmp::Point a = patch.position(patch.vertex(e, 0)), b = patch.position(patch.vertex(e, 1));
                        if (double(pmp::norm(a - b)) > longest) {
                            patch.split(e, (a + b) * 0.5f);
                            any = true;
                            if (patch.n_vertices() - n > cap) {
                                capped = true;
                                break;
                            }
                        }
                        if (deadline.tick()) {
                            error = late;
                            return false;
                        }
                    }
                    for (int sweep = 0; sweep < 3; ++sweep) {
                        bool flipped = false;
                        for (size_t i = 0; i < patch.n_edges(); ++i) {
                            const pmp::Edge e{pmp::IndexType(i)};
                            if (patch.is_boundary(e) || !patch.is_flip_ok(e)) {
                                continue;
                            }
                            const pmp::Halfedge h0 = patch.halfedge(e, 0), h1 = patch.halfedge(e, 1);
                            const pmp::Vertex vc = patch.to_vertex(patch.next_halfedge(h0)), vd = patch.to_vertex(patch.next_halfedge(h1));
                            if (vc.idx() < n && vd.idx() < n) {
                                continue;  // never a new edge between two of the loop's own vertices: the mesh may join them already
                            }
                            const pmp::Point a = patch.position(patch.to_vertex(h0)), b = patch.position(patch.to_vertex(h1));
                            const pmp::Point c = patch.position(vc), d = patch.position(vd);
                            auto corner = [](const pmp::Point& at, const pmp::Point& p, const pmp::Point& r) {
                                const pmp::Point s = p - at, w = r - at;
                                const double ls = pmp::norm(s), lw = pmp::norm(w);
                                return ls > 0.0 && lw > 0.0 ? std::acos(std::min(1.0, std::max(-1.0, double(pmp::dot(s, w)) / (ls * lw)))) : 0.0;
                            };
                            if (corner(c, a, b) + corner(d, a, b) > M_PI + 1e-6) {
                                patch.flip(e);
                                flipped = true;
                            }
                            if (deadline.tick()) {
                                error = late;
                                return false;
                            }
                        }
                        if (!flipped) {
                            break;
                        }
                    }
                    if (!any) {
                        break;
                    }
                }
                // The refined patch back as plain lists (loop vertices first, as they were).
                tris.clear();
                for (const pmp::Face f : patch.faces()) {
                    uint32_t c[3] = {0, 0, 0};
                    int k = 0;
                    for (const pmp::Vertex v : patch.vertices(f)) {
                        if (k < 3) {
                            c[k++] = uint32_t(v.idx());
                        }
                    }
                    tris.push_back({c[0], c[1], c[2]});
                }
                for (size_t v = n; v < patch.n_vertices(); ++v) {
                    const pmp::Point& p = patch.position(pmp::Vertex(pmp::IndexType(v)));
                    inner.push_back(V3(p[0], p[1], p[2]));
                }
            }
        }
        stats.refine_ms += op_now_ms() - refine_started;
        // The loop's best plane, for the flat fill and the fold check.
        V3 centre, area_vector;
        for (size_t i = 0; i < n; ++i) {
            centre += q[i] * (1.0 / double(n));
        }
        for (size_t i = 0; i < n; ++i) {
            area_vector += cross(q[i] - centre, q[(i + 1) % n] - centre);
        }
        const V3 plane_normal = normalized(area_vector);
        double diameter = 0.0;
        for (size_t i = 0; i < n; ++i) {
            diameter = std::max(diameter, 2.0 * length(q[i] - centre));
        }
        // (The refined patch before the smooth solve: what the flat fill is made of.)
        const std::vector<V3> unfaired = opt.fill == 1 ? inner : std::vector<V3>();
        if (opt.fill == 2) {
            for (V3& p : inner) {
                p = p - plane_normal * dot(p - centre, plane_normal);
            }
        }
        else if (opt.fill == 1 && !inner.empty()) {
            // --- Fair: the patch and three rings of the triangles around the loop as one small
            // pmp mesh; only the patch's inner vertices are free. The solve cannot be stopped,
            // so it is not started when the patch came out too large for the time that is left
            // (a loop that is far from flat needs more vertices than its outline promised).
            if (inner.size() > budget::MAX_FILL_FREE_VERTICES) {
                error = "A hole of " + with_commas(n) + " edges needs " + with_commas(inner.size()) + " new vertices (limit " + with_commas(budget::MAX_FILL_FREE_VERTICES) +
                        "). Turn off Match Edge Size, use the Minimal fill, or use Wrap.";
                return false;
            }
            if (deadline.elapsed() + fair_estimate(double(inner.size())) > deadline.limit()) {
                error = stopped_text("Close Holes", deadline.elapsed(), deadline.elapsed() + fair_estimate(double(inner.size())), deadline.limit(), kFillHint);
                return false;
            }
            ++tri_epoch;
            const double fair_started = op_now_ms();
            stats.fair_vertices = std::max(stats.fair_vertices, inner.size());
            std::vector<uint32_t> ring_tris, frontier(ring.begin(), ring.end()), touched;
            for (int level = 0; level < 3; ++level) {
                std::vector<uint32_t> next_frontier;
                for (const uint32_t v : frontier) {
                    for (uint32_t i = around.first[v]; i < around.first[size_t(v) + 1]; ++i) {
                        const uint32_t t = around.tris[i];
                        if (tri_stamp[t] == tri_epoch) {
                            continue;
                        }
                        tri_stamp[t] = tri_epoch;
                        ring_tris.push_back(t);
                        for (int k = 0; k < 3; ++k) {
                            next_frontier.push_back(m.triangles[size_t(t) * 3 + size_t(k)]);
                        }
                    }
                }
                frontier.swap(next_frontier);
            }
            std::sort(ring_tris.begin(), ring_tris.end());
            pmp::SurfaceMesh sub;
            bool built = true;
            try {
                // Loop vertices first (patch vertex i is sub vertex i), then the rings', then
                // the patch's inner ones.
                for (size_t i = 0; i < n; ++i) {
                    sub_index[ring[i]] = uint32_t(i);
                    touched.push_back(ring[i]);
                    sub.add_vertex(pmp::Point(float(q[i].x), float(q[i].y), float(q[i].z)));
                }
                for (const uint32_t t : ring_tris) {
                    for (int k = 0; k < 3; ++k) {
                        const uint32_t v = m.triangles[size_t(t) * 3 + size_t(k)];
                        if (sub_index[v] == NONE) {
                            sub_index[v] = uint32_t(sub.n_vertices());
                            touched.push_back(v);
                            const float* p = &m.positions[size_t(v) * 3];
                            sub.add_vertex(pmp::Point(p[0], p[1], p[2]));
                        }
                    }
                }
                const uint32_t inner_base = uint32_t(sub.n_vertices());
                for (const V3& p : inner) {
                    sub.add_vertex(pmp::Point(float(p.x), float(p.y), float(p.z)));
                }
                for (const uint32_t t : ring_tris) {
                    const uint32_t* tri = &m.triangles[size_t(t) * 3];
                    sub.add_triangle(pmp::Vertex(sub_index[tri[0]]), pmp::Vertex(sub_index[tri[1]]), pmp::Vertex(sub_index[tri[2]]));
                }
                auto map = [&](uint32_t patch_vertex) { return pmp::Vertex(patch_vertex < n ? patch_vertex : inner_base + (patch_vertex - uint32_t(n))); };
                for (const Tri& t : tris) {
                    sub.add_triangle(map(t.a), map(t.b), map(t.c));
                }
                auto selected = sub.add_vertex_property<bool>("v:selected", false);
                for (size_t i = 0; i < inner.size(); ++i) {
                    selected[pmp::Vertex(inner_base + pmp::IndexType(i))] = true;
                }
                pmp::fair(sub, 2);
                std::vector<V3> moved(inner.size());
                for (size_t i = 0; i < inner.size() && built; ++i) {
                    const pmp::Point& p = sub.position(pmp::Vertex(inner_base + pmp::IndexType(i)));
                    built = std::isfinite(p[0]) && std::isfinite(p[1]) && std::isfinite(p[2]);
                    moved[i] = V3(p[0], p[1], p[2]);
                }
                if (built) {
                    inner.swap(moved);
                    faired = true;
                }
            }
            catch (const std::exception&) {
                built = false;
            }
            catch (...) {
                built = false;
            }
            for (const uint32_t v : touched) {
                sub_index[v] = NONE;
            }
            stats.fair_ms += op_now_ms() - fair_started;
            if (!faired) {
                stats.unsmoothed.push_back(hole.id);
            }
            if (deadline.expired()) {
                error = late;
                return false;
            }
        }
        // The smooth fill must stay at its hole. Its solve carries the slope of the surface
        // around the hole on into the fill, and where that slope leans outward (the walls of a
        // shallow tray, a sheet bent along its middle) the fill runs away sideways: measured 287
        // mm on a 40 mm tray, kilometres on a bent plate. No fill vertex may lie further from the
        // loop's middle than the loop is wide (twice its radius); a fill that does is replaced
        // by the flat fill, and that is said, with the distance.
        if (faired) {
            double reach = 0.0;
            for (const V3& p : inner) {
                reach = std::max(reach, length(p - centre));
            }
            // Nor may it leave the hole's outline sideways: where the sheet around the hole leans
            // back under it (the walls of a shallow tray, the long sides of a slot) the solve
            // carries that slope on, out past the rim (a 48 mm tray filled out to 67 mm, a 2 mm
            // slot 44 mm past its end; 0.84 x the loop's width, within the bound above). Seen in
            // the loop's plane, along its two main directions, no fill vertex may lie further
            // outside the loop's box than a quarter of the box's narrower side. (A fill that
            // follows the surface around it, as on a ball or the end of a tube, rises off the
            // plane and stays within the outline.)
            double out_by = 0.0, box_long = 0.0, box_wide = 0.0;
            if (dot(plane_normal, plane_normal) > 0.0 && reach <= diameter) {
                const V3 u = normalized(std::fabs(plane_normal.x) < 0.9 ? cross(plane_normal, V3(1, 0, 0)) : cross(plane_normal, V3(0, 1, 0)));
                const V3 v = cross(plane_normal, u);
                double sxx = 0.0, sxy = 0.0, syy = 0.0;
                for (size_t i = 0; i < n; ++i) {
                    const double x = dot(q[i] - centre, u), y = dot(q[i] - centre, v);
                    sxx += x * x;
                    sxy += x * y;
                    syy += y * y;
                }
                const double angle = 0.5 * std::atan2(2.0 * sxy, sxx - syy);
                const V3 a1 = u * std::cos(angle) + v * std::sin(angle), a2 = v * std::cos(angle) - u * std::sin(angle);
                const double far_away = std::numeric_limits<double>::infinity();
                double lo1 = far_away, hi1 = -far_away, lo2 = far_away, hi2 = -far_away;
                for (size_t i = 0; i < n; ++i) {
                    const double s1 = dot(q[i] - centre, a1), s2 = dot(q[i] - centre, a2);
                    lo1 = std::min(lo1, s1);
                    hi1 = std::max(hi1, s1);
                    lo2 = std::min(lo2, s2);
                    hi2 = std::max(hi2, s2);
                }
                box_long = std::max(hi1 - lo1, hi2 - lo2);
                box_wide = std::min(hi1 - lo1, hi2 - lo2);
                for (const V3& p : inner) {
                    const double s1 = dot(p - centre, a1), s2 = dot(p - centre, a2);
                    out_by = std::max(out_by, std::max(std::max(lo1 - s1, s1 - hi1), std::max(lo2 - s2, s2 - hi2)));
                }
            }
            const bool away = !(reach <= diameter);
            const bool outside = !away && out_by > 0.25 * box_wide;
            if (away || outside) {
                inner = unfaired;
                for (V3& p : inner) {
                    p = p - plane_normal * dot(p - centre, plane_normal);
                }
                if (away) {
                    stats.replaced.push_back(hole.id);
                    if (reach > stats.replaced_reach || stats.replaced.size() == 1) {
                        stats.replaced_reach = reach;
                        stats.replaced_width = diameter;
                    }
                }
                else {
                    stats.left_outline.push_back(hole.id);
                    if (out_by > stats.left_by || stats.left_outline.size() == 1) {
                        stats.left_by = out_by;
                        stats.left_long = box_long;
                        stats.left_wide = box_wide;
                    }
                }
            }
            else {
                // Kept: how much it encloses against the flat fill (the two share the loop, so
                // the difference does not depend on the point the volumes are taken from).
                double smooth_volume = 0.0, flat_volume = 0.0;
                std::vector<V3> flat_inner = unfaired;
                for (V3& p : flat_inner) {
                    p = p - plane_normal * dot(p - centre, plane_normal);
                }
                auto corner = [&](const std::vector<V3>& patch, uint32_t i) { return (i < n ? q[i] : patch[i - n]) - centre; };
                for (const Tri& t : tris) {
                    smooth_volume += dot(corner(inner, t.a), cross(corner(inner, t.b), corner(inner, t.c))) / 6.0;
                    flat_volume += dot(corner(flat_inner, t.a), cross(corner(flat_inner, t.b), corner(flat_inner, t.c))) / 6.0;
                }
                stats.kept_smooth.push_back(hole.id);
                stats.bulge += smooth_volume - flat_volume;
                for (const V3& p : inner) {
                    stats.rise = std::max(stats.rise, std::fabs(dot(p - centre, plane_normal)));
                }
            }
        }
        // A fold: the fill left the hole's plane by more than the hole is wide.
        double off_plane = 0.0;
        for (const V3& p : inner) {
            off_plane = std::max(off_plane, std::fabs(dot(p - centre, plane_normal)));
        }
        if (off_plane > diameter && diameter > 0.0) {
            stats.folded.push_back(hole.id);
        }
        // Into the result: new vertices after all others, new triangles after all others, in
        // a new group fill<k>.
        const uint32_t base = uint32_t(out.vertex_count());
        if (size_t(base) + inner.size() > budget::MAX_VERTICES_MESH) {
            error = "Close Holes would make more than " + with_commas(budget::MAX_VERTICES_MESH) + " vertices. Turn off Match Edge Size, or Reduce the body first.";
            return false;
        }
        for (const V3& p : inner) {
            out.positions.push_back(float(p.x));
            out.positions.push_back(float(p.y));
            out.positions.push_back(float(p.z));
        }
        std::string name;
        do {
            name = "fill" + std::to_string(name_counter++);
        } while (taken.count(name) != 0);
        taken.insert(name);
        const uint32_t group = uint32_t(out.group_names.size());
        out.group_names.push_back(name);
        auto global = [&](uint32_t patch_vertex) { return patch_vertex < n ? ring[patch_vertex] : base + (patch_vertex - uint32_t(n)); };
        for (const Tri& t : tris) {
            out.triangles.push_back(global(t.a));
            out.triangles.push_back(global(t.b));
            out.triangles.push_back(global(t.c));
            out.groups.push_back(group);
        }
        stats.filled.push_back(hole.id);
        stats.names.push_back(name);
        stats.new_triangles += tris.size();
        stats.new_vertices += inner.size();
        stats.filled_edges += n;
    }
    return true;
}

}  // namespace
}  // namespace mesh

Ref<CadMesh> CadMesh::close_holes(const Dictionary& options)
{
    clear_messages();
    const double started = mesh::op_now_ms();
    if (is_null()) {
        fail("There is no mesh to close.");
        return Ref<CadMesh>();
    }
    const mesh::MeshData& m = state->data;
    const size_t T = m.triangle_count();
    mesh::OptionReader reader(options);
    mesh::FillOptions opt;
    opt.fill = reader.choice("fill", "Fill Type", {"minimal", "smooth", "flat"}, 1);
    opt.max_edges = reader.integer("max_edges", "Largest Hole", 0, 0, 100000);
    opt.refine = reader.flag("refine", "Match Edge Size", true);
    if (reader.ok() && options.has("loops")) {
        const Variant v = options["loops"];
        if (v.get_type() == Variant::PACKED_INT32_ARRAY) {
            const PackedInt32Array list = v;
            opt.loops.assign(list.ptr(), list.ptr() + list.size());
            opt.loops_given = list.size() > 0;
        }
        else if (v.get_type() != Variant::NIL) {
            reader.refuse("The holes to close must be given by their numbers.");
        }
    }
    const double limit = reader.time_limit();
    if (!reader.ok()) {
        fail(reader.error());
        return Ref<CadMesh>();
    }
    {
        // Far from the origin positions step by more than a share of an edge: the fill would be
        // made of rounding (triangles without area, places where it crosses itself).
        const double edge = mesh::typical_edge(*state);
        const std::string far = mesh::far_refusal(*state, options, edge, "too coarse to fill between edges of " + mesh::length_text(edge));
        if (!far.empty()) {
            fail(far);
            return Ref<CadMesh>();
        }
    }
    const mesh::Deadline deadline(limit);
    mesh::MeshData data;
    mesh::FillStats stats;
    std::string error;
    bool ok = false;
    try {
        ok = mesh::close_holes(*state, opt, deadline, data, stats, error);
    }
    catch (const std::exception& e) {
        error = mesh::library_error("Close Holes", e.what());
    }
    catch (...) {
        error = mesh::library_error("Close Holes", nullptr);
    }
    if (!ok) {
        fail(error);
        return Ref<CadMesh>();
    }
    auto ids = [](const std::vector<int32_t>& list) {
        PackedInt32Array out;
        for (const int32_t id : list) {
            out.push_back(id);
        }
        return out;
    };
    PackedStringArray warnings;
    auto skipped_text = [&]() {
        if (!stats.too_large.empty()) {
            warnings.push_back(mesh::op_text(mesh::counted(stats.too_large.size(), "hole was larger than Largest Hole and stays open.", "holes were larger than Largest Hole and stay open.")));
        }
        if (!stats.outline.empty()) {
            warnings.push_back(mesh::op_text(mesh::counted(stats.outline.size(), "open loop is the outline of an open sheet, not a hole, and stays open: closing it would only lay a second surface on the sheet.",
                                                           "open loops are the outline of an open sheet, not holes, and stay open: closing one would only lay a second surface on the sheet.")));
        }
        if (!stats.broken.empty()) {
            warnings.push_back(mesh::op_text(mesh::counted(stats.broken.size(), "hole could not be closed and stays open: its edge does not run around once", "holes could not be closed and stay open: their edge does not run around once") +
                                             ", or no patch fits without a third triangle on an edge of the mesh. Use Wrap, or run Stitch and Remove first."));
        }
    };
    if (stats.filled.empty()) {
        // Nothing to do: the mesh as it is, and why.
        if (stats.nothing) {
            warnings.push_back("The mesh has no open edges: there is nothing to close.");
        }
        skipped_text();
        last_warning = String("\n").join(warnings);
        last_report["op"] = "close_holes";
        last_report["ms"] = mesh::op_now_ms() - started;
        last_report["filled_loops"] = PackedInt32Array();
        last_report["skipped_loops"] = ids(stats.too_large);
        last_report["broken_loops"] = ids(stats.broken);
        last_report["outline_loops"] = ids(stats.outline);
        return Ref<CadMesh>(this);
    }
    const int64_t open_before = mesh::topology_of(*state)->boundary_edges;
    Ref<CadMesh> out = finish_op("Close Holes", "close_holes", std::move(data), started, true);
    if (out.is_null()) {
        return out;
    }
    Dictionary checks = last_report.get("checks", Dictionary());
    if (!last_warning.is_empty()) {
        warnings = last_warning.split("\n");
    }
    auto broken = [&](const char* key, const std::string& text) {
        checks[key] = String("fail: ") + mesh::op_text(text);
        last_report["checks"] = checks;
        fail(text);
        return Ref<CadMesh>();
    };
    PackedStringArray names;
    for (const std::string& name : stats.names) {
        names.push_back(mesh::op_text(name));
    }
    last_report["filled_loops"] = ids(stats.filled);
    last_report["skipped_loops"] = ids(stats.too_large);
    last_report["broken_loops"] = ids(stats.broken);
    last_report["outline_loops"] = ids(stats.outline);
    last_report["picked_outline_loops"] = ids(stats.outline_closed);
    last_report["replaced_loops"] = ids(stats.replaced);
    last_report["replaced_reach"] = stats.replaced_reach;
    last_report["outline_replaced_loops"] = ids(stats.left_outline);
    last_report["outline_replaced_by"] = stats.left_by;
    last_report["unsmoothed_loops"] = ids(stats.unsmoothed);
    last_report["folded_loops"] = ids(stats.folded);
    last_report["fill_groups"] = names;
    last_report["new_triangles"] = int64_t(stats.new_triangles);
    last_report["new_vertices"] = int64_t(stats.new_vertices);
    last_report["triangulate_ms"] = stats.triangulate_ms;
    last_report["refine_ms"] = stats.refine_ms;
    last_report["fair_ms"] = stats.fair_ms;
    last_report["largest_fair_vertices"] = int64_t(stats.fair_vertices);
    // Must hold: every hole asked for is closed (its edges are open no more, and no other edge
    // opened), and no edge has more than two triangles.
    const mesh::Topology* after = mesh::topology_of(out->get_state());
    const int64_t open_after = after->boundary_edges;
    if (open_after != open_before - int64_t(stats.filled_edges) || after->non_manifold_edges > 0) {
        return broken("closed", "Close Holes left " + mesh::with_commas(uint64_t(std::max<int64_t>(open_after - (open_before - int64_t(stats.filled_edges)), 0))) + " open edges and " +
                                    mesh::with_commas(after->non_manifold_edges) + " edges with more than two triangles on the holes it filled. Use Wrap, or run Stitch and Remove first.");
    }
    checks["closed"] = "ok";
    // Must hold: the original triangles, bit for bit.
    const mesh::MeshData& r = out->data();
    bool same = r.triangle_count() == T + stats.new_triangles;
    for (size_t i = 0; same && i < T * 3; ++i) {
        same = std::memcmp(&r.positions[size_t(r.triangles[i]) * 3], &m.positions[size_t(m.triangles[i]) * 3], sizeof(float) * 3) == 0;
    }
    if (!same) {
        return broken("original", "Close Holes changed the original triangles (internal error). Please report it.");
    }
    checks["original"] = "ok";
    skipped_text();
    if (!stats.unsmoothed.empty()) {
        const std::string text = mesh::counted(stats.unsmoothed.size(), "hole was filled without smoothing (the mesh around it could not be read by the mesh library).",
                                               "holes were filled without smoothing (the mesh around them could not be read by the mesh library).");
        checks["smoothing"] = String("warn: ") + mesh::op_text(text);
        warnings.push_back(mesh::op_text(text));
    }
    if (!stats.folded.empty()) {
        std::string list;
        for (size_t i = 0; i < stats.folded.size() && i < 8; ++i) {
            list += (i > 0 ? ", " : "") + std::to_string(stats.folded[i]);
        }
        const std::string text = "The fill of " + mesh::counted(stats.folded.size(), "hole", "holes") + " left the hole's plane by more than the hole is wide (" + (stats.folded.size() == 1 ? "hole " : "holes ") + list +
                                 (stats.folded.size() > 8 ? ", ..." : "") + "). Use the Flat or Minimal fill there.";
        checks["folds"] = String("warn: ") + mesh::op_text(text);
        warnings.push_back(mesh::op_text(text));
    }
    auto listed = [](const std::vector<int32_t>& list) {
        std::string text = list.size() == 1 ? "hole " : "holes ";
        for (size_t i = 0; i < list.size() && i < 8; ++i) {
            text += (i > 0 ? ", " : "") + std::to_string(list[i]);
        }
        return text + (list.size() > 8 ? ", ..." : "");
    };
    if (!stats.replaced.empty()) {
        const std::string text = "The smooth fill of " + mesh::counted(stats.replaced.size(), "hole", "holes") + " ran up to " + mesh::length_text(stats.replaced_reach) +
                                 " from the hole's middle (that hole is " + mesh::length_text(stats.replaced_width) + " across) and was replaced by the flat fill (" + listed(stats.replaced) +
                                 "). Use the Minimal fill there if the flat one does not suit.";
        checks["smooth_fill"] = String("warn: ") + mesh::op_text(text);
        warnings.push_back(mesh::op_text(text));
    }
    if (!stats.left_outline.empty()) {
        const std::string text = "The smooth fill of " + mesh::counted(stats.left_outline.size(), "hole", "holes") + " ran up to " + mesh::length_text(stats.left_by) +
                                 " outside the hole's outline (that hole is " + mesh::length_text(stats.left_long) + " by " + mesh::length_text(stats.left_wide) +
                                 ") and was replaced by the flat fill (" + listed(stats.left_outline) + "). Use the Minimal fill there if the flat one does not suit.";
        checks["smooth_outline"] = String("warn: ") + mesh::op_text(text);
        warnings.push_back(mesh::op_text(text));
    }
    {
        // A kept smooth fill that changes the closed body's volume by more than half against
        // the flat fill (a dome over a shallow tray: 9,812 mm3 against 800) is said, with the
        // numbers: it is what the smooth fill does, but rarely what such a hole wants.
        const mesh::Summary closed_after = mesh::summarize(out->get_state());
        if (!stats.kept_smooth.empty() && closed_after.closed) {
            const double with_smooth = closed_after.volume, with_flat = closed_after.volume - stats.bulge;
            last_report["volume_with_flat_fill"] = with_flat;
            if (std::fabs(with_smooth - with_flat) > 0.5 * std::fabs(with_flat)) {
                auto cubic = [](double v) {
                    const double mm3 = std::fabs(v) * 1e9;
                    return (v < 0.0 ? "-" : "") + (mm3 >= 100.0 ? mesh::with_commas(uint64_t(std::llround(mm3))) : mesh::number_text(mm3, "%.3g")) + " mm3";
                };
                const std::string text = "The smooth fill of " + listed(stats.kept_smooth) + " rises up to " + mesh::length_text(stats.rise) + " off the hole's plane: the body encloses " +
                                         cubic(with_smooth) + ", against " + cubic(with_flat) + " with the flat fill. Use the Flat fill if the hole should be closed level.";
                checks["smooth_volume"] = String("warn: ") + mesh::op_text(text);
                warnings.push_back(mesh::op_text(text));
            }
        }
    }
    if (!stats.outline_closed.empty()) {
        const std::string text = mesh::counted(stats.outline_closed.size(), "hole that was picked looks", "holes that were picked look") +
                                 " like the outline of an open sheet, not a hole: the fill spans the outline, so the body now encloses only the space between the sheet and the fill (" +
                                 listed(stats.outline_closed) + ").";
        checks["outline"] = String("warn: ") + mesh::op_text(text);
        warnings.push_back(mesh::op_text(text));
    }
    mesh::note_untested_crossings("Close Holes", last_report, checks, warnings);
    last_report["ms"] = mesh::op_now_ms() - started;  // with the checks above
    last_report["checks"] = checks;
    last_warning = String("\n").join(warnings);
    return out;
}

}  // namespace holo_forge
