// Remesh (work order 3.3.2). pmp's incremental remeshing, one pass a call with its own
// projection off; after every pass each free vertex is put back on the original surface with
// our triangle hierarchy (contract C5.1: the one schedule; the time limit is checked between
// passes). Face group borders and open edges that are to be kept are kept exactly: their
// vertices are put back on the original border lines after every pass, and at the end every
// corner of an original border line the new edges would cut is put back in.

#include "cad_mesh.h"
#include "mesh_bvh.h"
#include "mesh_pmp.h"

#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>

#include <pmp/algorithms/curvature.h>
#include <pmp/algorithms/features.h>
#include <pmp/algorithms/remeshing.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <exception>
#include <limits>
#include <unordered_map>
#include <unordered_set>

using namespace godot;

namespace holo_forge
{

namespace mesh
{
namespace
{
const char* kRemeshHint = "Lower Passes or Density.";
constexpr double kInf = std::numeric_limits<double>::infinity();

struct RemeshOptions
{
    bool adaptive = false;
    double edge_length = 0.0;  // uniform: the target
    double min_edge = 0.0, max_edge = 0.0, approx_error = 0.0;
    bool min_edge_given = false, max_edge_given = false;
    int iterations = 10;
    bool keep_sharp = true;
    double sharp_angle = 45.0;
    bool keep_boundary = true, keep_groups = true;
    bool selection = false;
    std::vector<uint32_t> triangles;
};

struct RemeshStats
{
    int passes = 0;
    bool nothing_free = false;
    size_t corners_restored = 0;
    size_t caps_mended = 0;      // border edges the library flipped, put back
    double estimate = 0.0;       // seconds, as estimated at the start
    size_t part_triangles = 0;   // triangles of the remeshed part in the result
    double mean_edge = 0.0;      // of the remeshed part
    double estimated_triangles = 0.0;
    size_t nearest_groups = 0;   // triangles whose group came from the nearest original triangle
    double build_ms = 0.0;
    double curvature_ms = 0.0;                // adaptive: the analysis of the whole part, once, for the size estimate
    double min_edge = 0.0, max_edge = 0.0;    // adaptive: the edges used (the defaults may have been raised to fit)
    std::vector<double> pass_ms, project_ms;  // each pass: the library call, then our projection
    std::vector<int64_t> pass_triangles;      // the triangles after each pass
};

/// The border lines that must stay where they are: chains of original edges between corners
/// where three or more of them meet (or one ends), and closed loops.
struct BorderLines
{
    std::vector<V3> points;        // chain after chain
    std::vector<uint32_t> first;   // chain c holds points[first[c] .. first[c + 1])
    std::vector<uint8_t> closed;   // its last point is its first again
    std::vector<double> along;     // length from the chain's start, per point
    std::vector<uint32_t> segment_chain, segment_point;  // per segment: its chain and first point
    /// What each chain is the border of: the two groups it lies between (kind_of), or kOpen for
    /// an open edge. Lines of different kinds can lie close to each other or share both their
    /// ends (the four arcs in which two crossing holes meet): a vertex or an edge is matched
    /// to the lines of its own kind only.
    std::vector<uint64_t> chain_kind;
    static constexpr uint64_t kAnyKind = ~uint64_t(0);
    static constexpr uint64_t kOpen = ~uint64_t(0) - 1;
    static uint64_t kind_of(uint32_t group_a, uint32_t group_b)
    {
        return (uint64_t(std::min(group_a, group_b)) << 32) | std::max(group_a, group_b);
    }
    subd::Bvh tree;

    bool empty() const
    {
        return segment_chain.empty();
    }
    size_t chains() const
    {
        return closed.size();
    }
    double chain_length(uint32_t c) const
    {
        return along[size_t(first[c + 1]) - 1];
    }

    /// `kinds` holds the kind of each edge.
    void build(const std::vector<V3>& positions, const std::vector<std::pair<uint32_t, uint32_t>>& edges, const std::vector<uint64_t>& kinds)
    {
        // Neighbours along the lines, per vertex.
        std::unordered_map<uint32_t, std::vector<uint32_t>> next;
        std::unordered_map<uint64_t, uint64_t> edge_kind;
        auto key = [](uint32_t a, uint32_t b) { return (uint64_t(std::min(a, b)) << 32) | std::max(a, b); };
        for (size_t i = 0; i < edges.size(); ++i) {
            const auto& e = edges[i];
            next[e.first].push_back(e.second);
            next[e.second].push_back(e.first);
            edge_kind[key(e.first, e.second)] = kinds[i];
        }
        std::unordered_set<uint64_t> used;
        first.push_back(0);
        auto walk = [&](uint32_t start, uint32_t second) {
            std::vector<uint32_t> chain = {start, second};
            used.insert(key(start, second));
            const uint64_t kind = edge_kind[key(start, second)];
            chain_kind.push_back(kind);
            uint32_t before = start, at = second;
            while (at != start) {
                const std::vector<uint32_t>& n = next[at];
                if (n.size() != 2) {
                    break;  // a corner: the chain ends here
                }
                const uint32_t onward = n[0] == before ? n[1] : n[0];
                if (used.count(key(at, onward)) != 0 || edge_kind[key(at, onward)] != kind) {
                    break;
                }
                used.insert(key(at, onward));
                chain.push_back(onward);
                before = at;
                at = onward;
            }
            double length_so_far = 0.0;
            for (size_t i = 0; i < chain.size(); ++i) {
                if (i > 0) {
                    length_so_far += length(positions[chain[i]] - positions[chain[i - 1]]);
                    segment_chain.push_back(uint32_t(closed.size()));
                    segment_point.push_back(uint32_t(points.size()) - 1);
                }
                points.push_back(positions[chain[i]]);
                along.push_back(length_so_far);
            }
            closed.push_back(chain.size() > 2 && chain.front() == chain.back() ? 1 : 0);
            first.push_back(uint32_t(points.size()));
        };
        // From every corner first (in vertex order, so the chains are the same on every run),
        // then what is left: loops without corners.
        std::vector<uint32_t> vertices;
        for (const auto& entry : next) {
            vertices.push_back(entry.first);
        }
        std::sort(vertices.begin(), vertices.end());
        for (const uint32_t v : vertices) {
            std::vector<uint32_t>& n = next[v];
            std::sort(n.begin(), n.end());
        }
        for (const uint32_t v : vertices) {
            if (next[v].size() == 2) {
                continue;
            }
            for (const uint32_t w : next[v]) {
                if (used.count(key(v, w)) == 0) {
                    walk(v, w);
                }
            }
        }
        for (const uint32_t v : vertices) {
            for (const uint32_t w : next[v]) {
                if (used.count(key(v, w)) == 0) {
                    walk(v, w);
                }
            }
        }
        std::vector<subd::Box> boxes(segment_chain.size());
        for (size_t s = 0; s < boxes.size(); ++s) {
            const V3& a = points[segment_point[s]];
            const V3& b = points[size_t(segment_point[s]) + 1];
            const double pa[3] = {a.x, a.y, a.z}, pb[3] = {b.x, b.y, b.z};
            boxes[s].add(pa);
            boxes[s].add(pb);
        }
        tree.build(boxes);
    }

    struct Hit
    {
        uint32_t segment = NONE;
        double t = 0.0;        // along the segment, 0..1
        double distance = kInf;
        V3 point;
    };
    /// The nearest point on the lines (on chain `only` alone when that is not NONE; on the
    /// chains of one kind alone when `kind` is not kAnyKind).
    Hit nearest(const V3& p, uint32_t only = NONE, uint64_t kind = kAnyKind) const
    {
        Hit hit;
        const double q[3] = {p.x, p.y, p.z};
        double best2 = kInf;
        tree.nearest(q, best2, [&](int s, double& best) {
            if (only != NONE && segment_chain[size_t(s)] != only) {
                return;
            }
            if (kind != kAnyKind && chain_kind[segment_chain[size_t(s)]] != kind) {
                return;
            }
            const V3& a = points[segment_point[size_t(s)]];
            const V3& b = points[size_t(segment_point[size_t(s)]) + 1];
            double t = 0.0;
            const double d = distance_to_segment(p, a, b, &t);
            if (d * d < best) {
                best = d * d;
                hit.segment = uint32_t(s);
                hit.t = t;
                hit.distance = d;
                hit.point = a + (b - a) * t;
            }
        });
        return hit;
    }
    /// Length along its chain of a hit.
    double along_of(const Hit& hit) const
    {
        const uint32_t i = segment_point[hit.segment];
        return along[i] + (along[size_t(i) + 1] - along[i]) * hit.t;
    }
};

/// Seconds one curvature analysis of pmp takes on that many triangles (adaptive remeshing runs
/// one at the start of every call, so once a pass): from the measured points in mesh_budget.h,
/// a straight line between them on log-log axes, linear below the first, the last slope above
/// the last.
double curvature_estimate(double triangles)
{
    const int n = budget::ADAPTIVE_CURVATURE_POINTS;
    const double* x = budget::ADAPTIVE_CURVATURE_TRIANGLES;
    const double* y = budget::ADAPTIVE_CURVATURE_SECONDS;
    if (!(triangles > 0.0)) {
        return 0.0;
    }
    if (triangles <= x[0]) {
        return y[0] * triangles / x[0];
    }
    int i = 0;
    while (i + 2 < n && triangles > x[i + 1]) {
        ++i;
    }
    const double slope = std::log(y[i + 1] / y[i]) / std::log(x[i + 1] / x[i]);
    return y[i] * std::pow(triangles / x[i], slope);
}

bool remesh(State& state, const RemeshOptions& opt, const Deadline& deadline, MeshData& out, RemeshStats& stats, std::string& error)
{
    const MeshData& m = state.data;
    const size_t T = m.triangle_count(), V = m.vertex_count();
    const std::string late = timed_out_text("Remesh", deadline.limit(), kRemeshHint);
    const std::string refusal = pmp_refusal(state);
    if (!refusal.empty()) {
        error = refusal;
        return false;
    }
    const std::vector<uint32_t>* tris = opt.selection ? &opt.triangles : nullptr;
    const size_t part = opt.selection ? opt.triangles.size() : T;
    double part_area = 0.0;
    for (size_t i = 0; i < part; ++i) {
        part_area += 0.5 * length(triangle_cross(m, tris != nullptr ? (*tris)[i] : i));
    }
    // (For the time, the result is taken a third larger than area / (0.433 L^2) says: pmp's
    // edges come out a little under the target, and measured results held 13 to 38 % more
    // triangles than that count.)
    const double kMoreTriangles = 1.35;
    // Adaptive: nothing bounds what a pass makes but the Minimum Edge (a body of flat faces and
    // sharp edges was seen to go from 36 triangles towards millions), and a pass cannot be
    // stopped. So the Minimum Edge must be large enough that even a result of that edge
    // everywhere stays within what the adaptive type can work on. The default is raised to
    // fit (as the cell sizes of the voxel tools are); a value that was given is refused.
    double min_edge = opt.min_edge, max_edge = opt.max_edge;
    if (opt.adaptive) {
        const double fit = std::sqrt(kMoreTriangles * part_area / (0.433 * double(budget::MAX_ADAPTIVE_REMESH_TRIANGLES)));
        if (min_edge < fit) {
            if (opt.min_edge_given) {
                error = "With a Minimum Edge of " + length_text(min_edge) + ", Remesh (Adaptive) could make about " +
                        with_commas(uint64_t(kMoreTriangles * part_area / (0.433 * min_edge * min_edge))) + " triangles (it works on up to " +
                        with_commas(budget::MAX_ADAPTIVE_REMESH_TRIANGLES) + "). Raise the Minimum Edge to " + length_text(fit * 1.001) + " or more, or use the Uniform type.";
                return false;
            }
            min_edge = fit;
        }
        if (!(min_edge < max_edge)) {
            if (opt.max_edge_given) {
                error = "Maximum Edge must be larger than the Minimum Edge, which is " + length_text(min_edge) + " on this body (smaller edges could make more triangles than Remesh (Adaptive) works on).";
                return false;
            }
            max_edge = 2.0 * min_edge;
        }
    }
    stats.min_edge = min_edge;
    stats.max_edge = max_edge;
    const double worst_size = opt.adaptive ? std::max(double(part), kMoreTriangles * part_area / (0.433 * min_edge * min_edge)) : 0.0;
    // Up-front, before any heavy work: the size of the result and the time of the passes.
    const double target = opt.adaptive ? max_edge : opt.edge_length;
    double expected = part_area / (0.433 * target * target);
    auto over_cap = [&](double triangles) {
        if (triangles + double(T - part) > double(budget::MAX_TRIANGLES_MESH)) {
            error = "Remesh would make about " + with_commas(uint64_t(triangles + double(T - part))) + " triangles; lower the Density.";
            return true;
        }
        return false;
    };
    // (Adaptive: every call starts with pmp's curvature analysis of the mesh as it then is.)
    auto pass_estimate = [&](double triangles) {
        return budget::estimate(budget::PMP_REMESH_PASS_WITH_PROJECTION, triangles) + (opt.adaptive ? curvature_estimate(triangles) : 0.0);
    };
    auto whole_estimate = [&](double expected_triangles) {
        const double triangles = kMoreTriangles * expected_triangles;
        const double work = std::max(double(part), triangles);
        // The first pass works on the larger of the two sizes, the later ones on the result's
        // (a part that gets coarser shrinks pass by pass: a quarter of its size is assumed at least).
        const double later = std::max(triangles, 0.25 * double(part));
        return budget::estimate(budget::PMP_SURFACE_MESH_BUILD, double(part)) + budget::estimate(budget::BVH_BUILD, double(T)) + pass_estimate(work) +
               (opt.iterations - 1) * pass_estimate(later) + (opt.adaptive ? curvature_estimate(double(part)) : 0.0) + post_check_estimate(triangles + double(T - part), true) +
               budget::estimate(budget::BVH_BUILD, triangles + double(T - part));
    };
    if (over_cap(expected)) {
        return false;
    }
    auto adaptive_too_big = [&](double triangles) {
        if (opt.adaptive && std::max(double(part), triangles) > double(budget::MAX_ADAPTIVE_REMESH_TRIANGLES)) {
            error = "Remesh (Adaptive) works on up to " + with_commas(budget::MAX_ADAPTIVE_REMESH_TRIANGLES) + " triangles (this would be about " +
                    with_commas(uint64_t(std::max(double(part), triangles))) + "). Use the Uniform type, or Reduce the body first.";
            return true;
        }
        return false;
    };
    if (adaptive_too_big(expected)) {
        return false;
    }
    // (Adaptive: any one pass may cost what a pass on the worst case costs.)
    const double worst_pass = opt.adaptive ? pass_estimate(worst_size) : 0.0;
    // One number, the same at every limit: the passes on the expected size, and for the adaptive
    // type at least one pass on the worst case.
    double need = whole_estimate(expected);
    if (opt.adaptive) {
        need = std::max(need, budget::estimate(budget::PMP_SURFACE_MESH_BUILD, double(part)) + curvature_estimate(double(part)) + worst_pass + post_check_estimate(worst_size + double(T - part), true));
    }
    stats.estimate = need;
    const char* slow_hint = opt.adaptive ? "Raise the Minimum Edge, lower Passes, or use the Uniform type." : kRemeshHint;
    if (need > deadline.limit()) {
        error = too_slow_text("Remesh", need, deadline.limit(), slow_hint);
        return false;
    }

    pmp::SurfaceMesh pm;
    std::vector<uint32_t> vertex_of;
    const double build_started = op_now_ms();
    const std::string problem = build_pmp(m, tris, pm, vertex_of);
    stats.build_ms = op_now_ms() - build_started;
    if (!problem.empty()) {
        error = problem;
        return false;
    }
    auto group = pm.add_face_property<uint32_t>("f:group", NONE);
    for (size_t i = 0; i < part; ++i) {
        group[pmp::Face(pmp::IndexType(i))] = m.groups[tris != nullptr ? (*tris)[i] : uint32_t(i)];
    }
    // Vertices of a selection's rim (unselected triangles use them too) stay as they are, and
    // keep their place in the mesh.
    auto origin = pm.add_vertex_property<uint32_t>("v:origin", NONE);
    pmp::VertexProperty<bool> selected;
    if (opt.selection) {
        std::vector<uint8_t> in_part(T, 0), rim(V, 0);
        for (const uint32_t t : opt.triangles) {
            in_part[t] = 1;
        }
        for (size_t t = 0; t < T; ++t) {
            if (!in_part[t]) {
                rim[m.triangles[t * 3]] = rim[m.triangles[t * 3 + 1]] = rim[m.triangles[t * 3 + 2]] = 1;
            }
        }
        // (Selected by default, so the vertices a pass adds are free in the next one.)
        selected = pm.add_vertex_property<bool>("v:selected", true);
        size_t free = 0;
        for (size_t i = 0; i < vertex_of.size(); ++i) {
            const pmp::Vertex v{pmp::IndexType(i)};
            if (rim[vertex_of[i]]) {
                origin[v] = vertex_of[i];
                selected[v] = false;
            }
            else {
                ++free;
            }
        }
        if (free == 0) {
            // (With nothing selected pmp would remesh everything.)
            stats.nothing_free = true;
            out = m;
            return true;
        }
    }

    // Features. Sharp edges are pmp's own: vertices slide along them. Group borders and open
    // edges that are kept are features too, and exact on top of that (below).
    if (opt.keep_sharp) {
        pmp::detect_features(pm, float(opt.sharp_angle));
    }
    auto vfeature = pm.vertex_property<bool>("v:feature", false);
    auto efeature = pm.edge_property<bool>("e:feature", false);
    if (opt.keep_groups) {
        mark_group_borders(pm, group);
    }
    if (opt.keep_boundary) {
        for (const pmp::Edge e : pm.edges()) {
            if (pm.is_boundary(e)) {
                efeature[e] = true;
                vfeature[pm.vertex(e, 0)] = true;
                vfeature[pm.vertex(e, 1)] = true;
            }
        }
    }
    auto is_exact = [&](pmp::Edge e) {
        const pmp::Face f0 = pm.face(e, 0), f1 = pm.face(e, 1);
        if (!f0.is_valid() || !f1.is_valid()) {
            return opt.keep_boundary;
        }
        return opt.keep_groups && group[f0] != group[f1] && group[f0] != NONE && group[f1] != NONE;
    };
    // The kind of an exact edge: the two groups it lies between, or an open edge.
    auto kind_of = [&](pmp::Edge e) {
        const pmp::Face f0 = pm.face(e, 0), f1 = pm.face(e, 1);
        return f0.is_valid() && f1.is_valid() ? BorderLines::kind_of(group[f0], group[f1]) : BorderLines::kOpen;
    };
    BorderLines lines;
    {
        std::vector<V3> positions(pm.n_vertices());
        for (const pmp::Vertex v : pm.vertices()) {
            const pmp::Point& p = pm.position(v);
            positions[v.idx()] = V3(p[0], p[1], p[2]);
        }
        std::vector<std::pair<uint32_t, uint32_t>> edges;
        std::vector<uint64_t> kinds;
        for (const pmp::Edge e : pm.edges()) {
            if (is_exact(e)) {
                edges.push_back({uint32_t(pm.vertex(e, 0).idx()), uint32_t(pm.vertex(e, 1).idx())});
                kinds.push_back(kind_of(e));
            }
        }
        if (!edges.empty()) {
            lines.build(positions, edges, kinds);
        }
    }

    // (No closer estimate from the curvature here: the analysis alone took half a second on
    // 80,000 triangles, before any refusal, and gave a second number for the same call. The
    // passes below are each held against the worst case instead.)
    stats.estimated_triangles = expected;

    const TriBvh* surface = bvh_of(state, &deadline);
    if (surface == nullptr) {
        error = late;
        return false;
    }

    // New faces (made by splits) take the group of a neighbour across an edge that is no
    // feature: group borders are features, so a group never leaks.
    auto label_new_faces = [&]() {
        if (!opt.keep_groups) {
            return;
        }
        std::vector<pmp::Face> queue;
        for (const pmp::Face f : pm.faces()) {
            if (group[f] != NONE) {
                queue.push_back(f);
            }
        }
        for (size_t i = 0; i < queue.size(); ++i) {
            const pmp::Face f = queue[i];
            for (const pmp::Halfedge h : pm.halfedges(f)) {
                if (efeature[pm.edge(h)]) {
                    continue;
                }
                const pmp::Face g = pm.face(pm.opposite_halfedge(h));
                if (g.is_valid() && group[g] == NONE) {
                    group[g] = group[f];
                    queue.push_back(g);
                }
            }
            if (deadline.tick()) {
                return;  // (the caller sees the deadline passed)
            }
        }
    };

    // The last step of a library pass flips an edge when a corner across it is nearly on it (a
    // "cap"). When that edge is a feature and the corner is not, the library moves the corner
    // onto the edge's middle and flips the edge all the same, and the feature mark stays on the
    // flipped edge: the feature line a c now runs a - (nothing) - c with a marked edge sticking
    // out of it, and a group would leak through the gap (measured: borders 5.9 mm off on a body
    // with two crossing holes, a group's area changed by 74.5 %). Put right here, after every
    // pass: the mark goes to the two edges a v and v c, and the two triangles at the flipped
    // edge, which now both lie on the far side of the line, get the group of that side.
    auto mend_flipped_caps = [&]() {
        std::vector<pmp::Edge> flipped;
        for (const pmp::Edge e : pm.edges()) {
            if (efeature[e] && !pm.is_boundary(e) && (!vfeature[pm.vertex(e, 0)] || !vfeature[pm.vertex(e, 1)])) {
                flipped.push_back(e);
            }
            if (deadline.tick()) {
                return;  // (the caller sees the deadline passed)
            }
        }
        for (const pmp::Edge e : flipped) {
            if (!efeature[e] || deadline.tick()) {
                continue;
            }
            const pmp::Halfedge h0 = pm.halfedge(e, 0), h1 = pm.halfedge(e, 1);
            const pmp::Vertex a = pm.to_vertex(pm.next_halfedge(h0)), c = pm.to_vertex(pm.next_halfedge(h1));
            // The corner the library moved: the end of the edge that is no feature vertex (when
            // neither is, the one on the middle of a c).
            pmp::Vertex v = pm.vertex(e, 0), other = pm.vertex(e, 1);
            const pmp::Point middle = (pm.position(a) + pm.position(c)) * 0.5f;
            if (vfeature[v] || (!vfeature[other] && pmp::norm(pm.position(other) - middle) < pmp::norm(pm.position(v) - middle))) {
                std::swap(v, other);
            }
            const pmp::Edge ea = pm.find_edge(v, a), ec = pm.find_edge(v, c);
            if (vfeature[v] || !ea.is_valid() || !ec.is_valid()) {
                continue;
            }
            efeature[e] = false;
            efeature[ea] = true;
            efeature[ec] = true;
            vfeature[v] = true;
            ++stats.caps_mended;
            if (opt.keep_groups) {
                const pmp::Face f0 = pm.face(h0), f1 = pm.face(h1);
                const uint32_t l0 = group[f0], l1 = group[f1];
                if (l0 != l1) {
                    // The near side's group is across a v (outside the two triangles).
                    uint32_t near_group = NONE;
                    for (int k = 0; k < 2; ++k) {
                        const pmp::Face f = pm.face(ea, k);
                        if (f.is_valid() && f != f0 && f != f1) {
                            near_group = group[f];
                        }
                    }
                    // (Not told apart: left without a group, and the flood below gives them a
                    // neighbour's across an edge that is no feature.)
                    const uint32_t far_group = near_group == NONE ? NONE : (l0 == near_group ? l1 : (l1 == near_group ? l0 : NONE));
                    group[f0] = far_group;
                    group[f1] = far_group;
                }
            }
        }
    };

    // After a pass: free vertices back onto the original surface, vertices of exact lines back
    // onto those lines (and onto a corner of the line when one is close).
    const double snap = 0.1 * (opt.adaptive ? min_edge : opt.edge_length);
    auto project = [&]() -> bool {
        std::vector<uint8_t> exact_edges(pm.n_vertices(), 0);
        std::vector<uint64_t> vertex_kind;  // the kind of the line a vertex is on
        if (!lines.empty()) {
            vertex_kind.assign(pm.n_vertices(), BorderLines::kAnyKind);
            for (const pmp::Edge e : pm.edges()) {
                if (is_exact(e)) {
                    const uint64_t kind = kind_of(e);
                    for (int k = 0; k < 2; ++k) {
                        const size_t v = pm.vertex(e, k).idx();
                        uint8_t& count = exact_edges[v];
                        count = uint8_t(std::min<int>(count + 1, 3));
                        if (vertex_kind[v] == BorderLines::kAnyKind) {
                            vertex_kind[v] = kind;
                        }
                        else if (vertex_kind[v] != kind) {
                            count = 3;  // lines of two kinds meet here: a corner
                        }
                    }
                }
            }
        }
        std::unordered_set<uint64_t> claimed;  // corners of the lines a vertex sits on already
        for (const pmp::Vertex v : pm.vertices()) {
            if (selected && !selected[v]) {
                continue;
            }
            const pmp::Point& at = pm.position(v);
            const V3 p(at[0], at[1], at[2]);
            const uint8_t on_lines = exact_edges[v.idx()];
            if (on_lines > 0) {
                if (on_lines != 2) {
                    continue;  // a corner where lines meet: pmp keeps it
                }
                BorderLines::Hit hit = lines.nearest(p, NONE, vertex_kind[v.idx()]);
                if (hit.segment == NONE) {
                    continue;
                }
                V3 q = hit.point;
                // A corner of the line within reach: sit on it (one vertex a corner; the ends
                // of a chain belong to the vertices pmp keeps there).
                const uint32_t i = lines.segment_point[hit.segment];
                const uint32_t c = lines.segment_chain[hit.segment];
                for (int end = 0; end < 2; ++end) {
                    const uint32_t point = i + uint32_t(end);
                    const bool chain_end = !lines.closed[c] && (point == lines.first[c] || point + 1 == lines.first[c + 1]);
                    if (chain_end || length(lines.points[point] - q) > snap) {
                        continue;
                    }
                    // (The first and last point of a closed chain are one corner.)
                    const uint64_t id = (lines.closed[c] && point + 1 == lines.first[c + 1]) ? lines.first[c] : point;
                    if (claimed.insert(id).second) {
                        q = lines.points[point];
                        break;
                    }
                }
                pm.position(v) = pmp::Point(float(q.x), float(q.y), float(q.z));
            }
            else if (!pm.is_boundary(v)) {
                const double from[3] = {p.x, p.y, p.z};
                uint32_t triangle = NONE;
                double q[3];
                surface->nearest(from, kInf, triangle, q);
                if (triangle != NONE) {
                    pm.position(v) = pmp::Point(float(q[0]), float(q[1]), float(q[2]));
                }
            }
            if (deadline.tick()) {
                return false;
            }
        }
        return true;
    };

    for (int pass = 0; pass < opt.iterations; ++pass) {
        // A pass cannot be stopped: it is not started when it would end after the limit.
        const double now = double(pm.n_faces());
        const double chunk = opt.adaptive ? worst_pass : pass_estimate(std::max(now, pass == 0 ? kMoreTriangles * expected : now));
        if ((pass > 0 || opt.adaptive) && deadline.elapsed() + chunk > deadline.limit()) {
            error = stopped_text("Remesh", deadline.elapsed(), std::max(need, deadline.elapsed() + chunk * (opt.iterations - pass)), deadline.limit(), slow_hint);
            return false;
        }
        const double pass_started = op_now_ms();
        try {
            if (opt.adaptive) {
                pmp::adaptive_remeshing(pm, float(min_edge), float(max_edge), float(opt.approx_error), 1, false);
            }
            else {
                pmp::uniform_remeshing(pm, float(opt.edge_length), 1, false);
            }
        }
        catch (const std::exception& e) {
            error = library_error("Remesh", e.what());
            return false;
        }
        catch (...) {
            error = library_error("Remesh", nullptr);
            return false;
        }
        if (pm.n_faces() + (T - part) > budget::MAX_TRIANGLES_MESH) {
            error = "Remesh made " + with_commas(pm.n_faces() + (T - part)) + " triangles, more than a mesh body takes; lower the Density.";
            return false;
        }
        // (pmp drops the feature marks it made itself when the mesh had none before.)
        vfeature = pm.vertex_property<bool>("v:feature", false);
        efeature = pm.edge_property<bool>("e:feature", false);
        const double project_started = op_now_ms();
        stats.pass_ms.push_back(project_started - pass_started);
        mend_flipped_caps();
        label_new_faces();
        if (deadline.expired() || !project()) {
            error = late;
            return false;
        }
        stats.project_ms.push_back(op_now_ms() - project_started);
        stats.pass_triangles.push_back(int64_t(pm.n_faces()));
        ++stats.passes;
        if (deadline.expired()) {
            error = late;
            return false;
        }
    }

    // Every corner of an original line that a new edge would cut goes back in: the edge is
    // split there, so the lines are the original lines again.
    if (!lines.empty()) {
        struct Job
        {
            pmp::Vertex from, to;
            std::vector<V3> corners;  // in order from `from` to `to`
        };
        std::vector<Job> jobs;
        const double flat = 1e-7 * measures_of(state).diagonal;
        for (const pmp::Edge e : pm.edges()) {
            if (!is_exact(e)) {
                continue;
            }
            const pmp::Vertex v0 = pm.vertex(e, 0), v1 = pm.vertex(e, 1);
            if (selected && !selected[v0] && !selected[v1]) {
                continue;  // an edge of the rim: as it was
            }
            const pmp::Point& a = pm.position(v0);
            const pmp::Point& b = pm.position(v1);
            const V3 pa(a[0], a[1], a[2]), pb(b[0], b[1], b[2]);
            const BorderLines::Hit middle = lines.nearest((pa + pb) * 0.5, NONE, kind_of(e));
            if (middle.segment == NONE) {
                continue;
            }
            const uint32_t c = lines.segment_chain[middle.segment];
            const BorderLines::Hit ha = lines.nearest(pa, c), hb = lines.nearest(pb, c);
            if (ha.segment == NONE || hb.segment == NONE) {
                continue;
            }
            double sa = lines.along_of(ha), sb = lines.along_of(hb);
            const double total = lines.chain_length(c);
            const uint32_t begin = lines.first[c], end = lines.first[c + 1];
            // Along the chain from the lower to the higher length; a closed chain may be shorter
            // the other way round.
            const bool swapped = sa > sb;
            const double lo = std::min(sa, sb), hi = std::max(sa, sb);
            const bool around = lines.closed[c] && (hi - lo) > 0.5 * total;
            std::vector<V3> between;
            const double eps = 1e-9 * std::max(total, 1e-30);
            if (!around) {
                for (uint32_t i = begin; i < end; ++i) {
                    if (lines.along[i] > lo + eps && lines.along[i] < hi - eps) {
                        between.push_back(lines.points[i]);
                    }
                }
                if (swapped) {
                    std::reverse(between.begin(), between.end());
                }
            }
            else {
                // From the higher one on to the end, then from the start up to the lower one.
                for (uint32_t i = begin; i + 1 < end; ++i) {
                    if (lines.along[i] > hi + eps) {
                        between.push_back(lines.points[i]);
                    }
                }
                for (uint32_t i = begin; i + 1 < end; ++i) {
                    if (lines.along[i] < lo - eps) {
                        between.push_back(lines.points[i]);
                    }
                }
                if (!swapped) {
                    std::reverse(between.begin(), between.end());
                }
            }
            // Corners the straight edge passes through anyway stay out.
            Job job{v0, v1, {}};
            for (const V3& p : between) {
                if (distance_to_segment(p, pa, pb) > flat) {
                    job.corners.push_back(p);
                }
            }
            if (!job.corners.empty()) {
                jobs.push_back(std::move(job));
            }
        }
        for (const Job& job : jobs) {
            pmp::Vertex from = job.from;
            for (const V3& p : job.corners) {
                const pmp::Edge e = pm.find_edge(from, job.to);
                if (!e.is_valid()) {
                    break;
                }
                const pmp::Vertex added = pm.add_vertex(pmp::Point(float(p.x), float(p.y), float(p.z)));
                pm.split(e, added);
                vfeature[added] = true;
                const pmp::Edge e0 = pm.find_edge(from, added), e1 = pm.find_edge(added, job.to);
                if (e0.is_valid()) {
                    efeature[e0] = true;
                }
                if (e1.is_valid()) {
                    efeature[e1] = true;
                }
                from = added;
                ++stats.corners_restored;
                if (pm.n_faces() + (T - part) > budget::MAX_TRIANGLES_MESH) {
                    error = "Remesh made more triangles than a mesh body takes while keeping the face group borders; lower the Density.";
                    return false;
                }
            }
            if (deadline.tick()) {
                error = late;
                return false;
            }
        }
        label_new_faces();
        if (deadline.expired()) {
            error = late;
            return false;
        }
    }
    pm.garbage_collection();

    // Back to plain arrays: the triangles outside a selection first, as they were.
    out.positions = m.positions;
    out.group_names = m.group_names;
    out.triangles.clear();
    out.groups.clear();
    if (opt.selection) {
        std::vector<uint8_t> in_part(T, 0);
        for (const uint32_t t : opt.triangles) {
            in_part[t] = 1;
        }
        for (size_t t = 0; t < T; ++t) {
            if (!in_part[t]) {
                out.triangles.insert(out.triangles.end(), m.triangles.begin() + t * 3, m.triangles.begin() + t * 3 + 3);
                out.groups.push_back(m.groups[t]);
            }
        }
    }
    std::vector<uint32_t> index(pm.n_vertices(), NONE);
    for (const pmp::Vertex v : pm.vertices()) {
        if (origin[v] != NONE) {
            index[v.idx()] = origin[v];
            continue;
        }
        index[v.idx()] = uint32_t(out.vertex_count());
        const pmp::Point& p = pm.position(v);
        out.positions.push_back(p[0]);
        out.positions.push_back(p[1]);
        out.positions.push_back(p[2]);
    }
    if (out.vertex_count() > budget::MAX_VERTICES_MESH + V) {
        error = "Remesh made more vertices than a mesh body takes; lower the Density.";
        return false;
    }
    for (const pmp::Face f : pm.faces()) {
        uint32_t corner[3] = {0, 0, 0};
        V3 centre;
        int k = 0;
        for (const pmp::Vertex v : pm.vertices(f)) {
            if (k < 3) {
                corner[k++] = index[v.idx()];
                const pmp::Point& p = pm.position(v);
                centre += V3(p[0], p[1], p[2]) * (1.0 / 3.0);
            }
        }
        uint32_t g = opt.keep_groups ? group[f] : NONE;
        if (g == NONE) {
            // The group of the original triangle nearest to the middle.
            const double from[3] = {centre.x, centre.y, centre.z};
            uint32_t triangle = NONE;
            double q[3];
            surface->nearest(from, kInf, triangle, q);
            g = triangle != NONE ? m.groups[triangle] : 0;
            ++stats.nearest_groups;
        }
        out.triangles.insert(out.triangles.end(), corner, corner + 3);
        out.groups.push_back(g);
        if (deadline.tick()) {
            error = late;
            return false;
        }
    }
    stats.part_triangles = pm.n_faces();
    double sum = 0.0;
    for (const pmp::Edge e : pm.edges()) {
        sum += double(pmp::norm(pm.position(pm.vertex(e, 0)) - pm.position(pm.vertex(e, 1))));
    }
    stats.mean_edge = pm.n_edges() > 0 ? sum / double(pm.n_edges()) : 0.0;
    return true;
}

/// Edges whose two triangles face nearly opposite ways (the surface folds back on itself).
int64_t folded_edges(State& s)
{
    const MeshData& m = s.data;
    const Topology* topo = topology_of(s);
    const double limit = std::cos(170.0 * M_PI / 180.0);
    int64_t count = 0;
    for (size_t e = 0; e < topo->edge_count(); ++e) {
        if (topo->uses(uint32_t(e)) != 2) {
            continue;
        }
        const uint32_t h0 = topo->edge_hes[topo->edge_first[e]], h1 = topo->edge_hes[size_t(topo->edge_first[e]) + 1];
        const V3 n0 = normalized(triangle_cross(m, h0 / 3)), n1 = normalized(triangle_cross(m, h1 / 3));
        if (dot(n0, n0) == 0.0 || dot(n1, n1) == 0.0) {
            continue;
        }
        const double sign = m.triangles[h0] == m.triangles[h1] ? -1.0 : 1.0;
        count += sign * dot(n0, n1) < limit ? 1 : 0;
    }
    return count;
}

}  // namespace
}  // namespace mesh

Ref<CadMesh> CadMesh::remesh(const Dictionary& options)
{
    clear_messages();
    const double started = mesh::op_now_ms();
    if (is_null()) {
        fail("There is no mesh to remesh.");
        return Ref<CadMesh>();
    }
    const mesh::MeshData& m = state->data;
    const size_t T = m.triangle_count();
    const double D = mesh::measures_of(*state).diagonal;
    mesh::OptionReader reader(options);
    mesh::RemeshOptions opt;
    opt.adaptive = reader.choice("mode", "Type", {"uniform", "adaptive"}, 0) == 1;
    const double density = reader.number("density", "Density", 0.5, 0.01, 1.0);
    double edge_length = 0.0;
    if (reader.ok() && options.has("edge_length")) {
        const Variant v = options["edge_length"];
        if (v.get_type() != Variant::FLOAT && v.get_type() != Variant::INT) {
            reader.refuse("Edge Length must be a number.");
        }
        else {
            edge_length = double(v);
            if (edge_length != 0.0 && !(edge_length >= D / 2000.0 * (1.0 - 1e-9) && edge_length <= D / 5.0 * (1.0 + 1e-9))) {
                reader.refuse("Edge Length must be 0 (to use the Density), or between " + mesh::length_text(D / 2000.0) + " and " + mesh::length_text(D / 5.0) + ".");
            }
        }
    }
    opt.max_edge_given = options.has("max_edge");
    opt.min_edge_given = options.has("min_edge");
    opt.max_edge = reader.number("max_edge", "Maximum Edge", D / 50.0, D * 1e-6, D / 5.0, "m");
    opt.min_edge = reader.number("min_edge", "Minimum Edge", std::min(D / 1000.0, 0.5 * opt.max_edge), D * 1e-7, opt.max_edge, "m");
    opt.approx_error = reader.number("approx_error", "Shape Error", D / 2000.0, D * 1e-6, D / 20.0, "m");
    opt.iterations = int(reader.integer("iterations", "Passes", 10, 1, 50));
    opt.keep_sharp = reader.flag("keep_sharp", "Keep Sharp Edges", true);
    opt.sharp_angle = reader.number("sharp_angle", "Sharp Edge Angle", 45.0, 10.0, 170.0, "deg");
    opt.keep_boundary = reader.flag("keep_boundary", "Keep Open Edges", true);
    opt.keep_groups = reader.flag("keep_groups", "Keep Face Group Borders", true);
    opt.triangles = reader.triangles("triangles", T, &opt.selection);
    const double limit = reader.time_limit();
    if (reader.ok() && opt.adaptive && !(opt.min_edge < opt.max_edge)) {
        reader.refuse("Minimum Edge must be smaller than Maximum Edge (" + mesh::length_text(opt.max_edge) + ").");
    }
    if (!reader.ok()) {
        fail(reader.error());
        return Ref<CadMesh>();
    }
    if (opt.selection && opt.triangles.empty()) {
        fail("Select the triangles to remesh, or remesh the whole body.");
        return Ref<CadMesh>();
    }
    if (opt.selection && opt.triangles.size() == T) {
        opt.selection = false;
    }
    const double mean_in = opt.selection ? mesh::mean_edge_length(*state, opt.triangles) : mesh::mean_edge_length(*state);
    if (!(mean_in > 0.0)) {
        fail("The mesh has no edges with length to remesh.");
        return Ref<CadMesh>();
    }
    // Density to edge length: 0.5 keeps the size, 1 is 4 x finer, 0 is 4 x coarser.
    opt.edge_length = edge_length != 0.0 ? edge_length : mean_in * std::pow(2.0, 2.0 - 4.0 * density);
    {
        // Far from the origin positions step by more than a share of an edge: a library pass,
        // which cannot be stopped, splits edges whose middles round back onto their ends (a 10
        // mm ball 30 km out took 22 s against a 2 s limit, and once 36 minutes), and what comes
        // back is triangles without area. Refused up front, with the distance and the step.
        const double finest = opt.adaptive ? opt.min_edge : opt.edge_length;
        const double scale = std::min(finest, mean_in);
        const std::string why = scale < mean_in ? (opt.adaptive ? "too coarse for a Minimum Edge of " : "too coarse for edges of ") + mesh::length_text(scale)
                                                : "too coarse for its edges of " + mesh::length_text(scale);
        const std::string far = mesh::far_refusal(*state, options, scale, why);
        if (!far.empty()) {
            fail(far);
            return Ref<CadMesh>();
        }
    }
    const mesh::Deadline deadline(limit);
    mesh::MeshData data;
    mesh::RemeshStats stats;
    std::string error;
    bool ok = false;
    try {
        ok = mesh::remesh(*state, opt, deadline, data, stats, error);
    }
    catch (const std::exception& e) {
        error = mesh::library_error("Remesh", e.what());
    }
    catch (...) {
        error = mesh::library_error("Remesh", nullptr);
    }
    if (!ok) {
        fail(error);
        return Ref<CadMesh>();
    }
    if (stats.nothing_free) {
        last_warning = "The selection is too small to remesh; grow it.";
        last_report["op"] = "remesh";
        last_report["ms"] = mesh::op_now_ms() - started;
        last_report["passes"] = int64_t(0);
        return Ref<CadMesh>(this);
    }
    const mesh::Summary before = mesh::summarize(*state);
    Ref<CadMesh> out = finish_op("Remesh", "remesh", std::move(data), started, true);
    if (out.is_null()) {
        return out;
    }
    Dictionary checks = last_report.get("checks", Dictionary());
    PackedStringArray warnings;
    if (!last_warning.is_empty()) {
        warnings = last_warning.split("\n");
    }
    auto broken = [&](const char* key, const std::string& text) {
        checks[key] = String("fail: ") + mesh::op_text(text);
        last_report["checks"] = checks;
        fail(text);
        return Ref<CadMesh>();
    };
    auto warn = [&](const char* key, const std::string& text) {
        checks[key] = String("warn: ") + mesh::op_text(text);
        warnings.push_back(mesh::op_text(text));
    };
    mesh::State& result = out->get_state();
    const mesh::Summary after = mesh::summarize(result);
    const double L = opt.adaptive ? stats.max_edge : opt.edge_length;
    if (opt.adaptive) {
        // (The defaults may have been raised to fit this body: a panel shows these.)
        last_report["min_edge"] = stats.min_edge;
        last_report["max_edge"] = stats.max_edge;
    }
    last_report["passes"] = int64_t(stats.passes);
    last_report["edge_length"] = L;
    last_report["mean_edge"] = stats.mean_edge;
    last_report["estimated_triangles"] = stats.estimated_triangles;
    last_report["corners_restored"] = int64_t(stats.corners_restored);
    last_report["mended_caps"] = int64_t(stats.caps_mended);
    last_report["estimate_s"] = stats.estimate;
    {
        // Where the time went (for the cost rates in mesh_budget.h).
        PackedFloat64Array pass_ms, project_ms;
        PackedInt64Array pass_triangles;
        for (size_t i = 0; i < stats.pass_ms.size(); ++i) {
            pass_ms.push_back(stats.pass_ms[i]);
            project_ms.push_back(stats.project_ms[i]);
            pass_triangles.push_back(stats.pass_triangles[i]);
        }
        last_report["build_ms"] = stats.build_ms;
        last_report["curvature_ms"] = stats.curvature_ms;
        last_report["pass_ms"] = pass_ms;
        last_report["project_ms"] = project_ms;
        last_report["pass_triangles"] = pass_triangles;
    }

    // Must hold: the result lies on the input. One way: from the result to the input.
    const mesh::Distance forward = mesh::distance_between(result, *state, 20000, deadline);
    const mesh::Distance backward = mesh::distance_between(*state, result, 20000, deadline);
    const double fail_at = opt.adaptive ? std::max(0.5 * L, opt.approx_error) : 0.5 * L;
    const double warn_at = opt.adaptive ? std::max(0.25 * L, opt.approx_error) : 0.25 * L;
    if (forward.timed_out) {
        return broken("deviation", mesh::timed_out_text("Remesh", limit, mesh::kRemeshHint));
    }
    Dictionary deviation;
    deviation["result_to_input"] = forward.max;
    deviation["max"] = backward.timed_out ? forward.max : std::max(forward.max, backward.max);
    deviation["mean"] = backward.timed_out ? forward.mean : 0.5 * (forward.mean + backward.mean);
    deviation["samples"] = forward.samples + backward.samples;
    if (!backward.timed_out) {
        deviation["input_to_result"] = backward.max;
    }
    last_report["deviation"] = deviation;
    if (forward.max > fail_at) {
        return broken("deviation", "Remesh moved the surface by " + mesh::length_text(forward.max) + " (limit " + mesh::length_text(fail_at) + "). Raise the Density or lower the Edge Length.");
    }
    if (backward.timed_out) {
        warn("deviation", "The deviation from the input to the result could not be measured in the time left.");
    }
    else if (std::max(forward.max, backward.max) > warn_at) {
        warn("deviation", "The new edges of " + mesh::length_text(L) + " are too long to follow the input everywhere (it is rougher, or curves more tightly, than they are long); deviation " +
                              mesh::length_text(std::max(forward.max, backward.max)) + ".");
    }
    else {
        checks["deviation"] = "ok";
    }
    // Must hold: the open loops with Keep Open Edges, the groups with Keep Face Group Borders.
    if (opt.keep_boundary && (before.boundary_edges > 0 || after.boundary_edges > 0)) {
        const size_t loops_before = mesh::boundary_loops(*state).size(), loops_after = mesh::boundary_loops(result).size();
        if (loops_before != loops_after) {
            return broken("boundary", "Remesh changed the number of open loops from " + mesh::with_commas(loops_before) + " to " + mesh::with_commas(loops_after) + ". Raise the Density.");
        }
    }
    checks["boundary"] = "ok";
    if (opt.keep_groups) {
        if (after.groups != before.groups) {
            return broken("groups", "Remesh lost " + mesh::counted(uint64_t(std::llabs(before.groups - after.groups)), "face group though its borders were", "face groups though their borders were") + " to be kept. Raise the Density.");
        }
        checks["groups"] = "ok";
        // (Both ways: a stretch of border that is gone from the result counts as one that strayed.)
        const double off = mesh::group_border_deviation(*state, result);
        last_report["border_deviation"] = off;
        if (off > 1e-6 * D) {
            warn("borders", "Face group borders moved by up to " + mesh::length_text(off) + ".");
        }
        else {
            checks["borders"] = "ok";
        }
    }
    // The volume of a closed body: said above 2 % (new edges that are long for the body's curves
    // cut them short: a ball remeshed at a fifth of its size loses 15 %, inside the 0.5 L promise).
    if (before.closed && after.closed && before.volume != 0.0) {
        const double change = (after.volume - before.volume) / std::fabs(before.volume);
        last_report["volume_change"] = change;
        if (std::fabs(change) > 0.02) {
            warn("volume", std::string("Remesh changed the volume by ") + (change < 0.0 ? "-" : "+") + mesh::number_text(100.0 * std::fabs(change), "%.3g") +
                                   " % (the new edges are long for the body's curves). Raise the Density or lower the Edge Length.");
        }
        else {
            checks["volume"] = "ok";
        }
    }
    // Folds between neighbours (the crossing test does not see them).
    const int64_t folds = mesh::folded_edges(result) - mesh::folded_edges(*state);
    last_report["folded_edges"] = std::max<int64_t>(folds, 0);
    if (folds > 0) {
        warn("folds", "Remesh folded the surface back on itself at " + mesh::counted(uint64_t(folds), "edge", "edges") + ". Raise the Density or lower the Edge Length.");
    }
    else {
        checks["folds"] = "ok";
    }
    // Edge length.
    if (!opt.adaptive && stats.mean_edge > 0.0 && std::fabs(stats.mean_edge - L) > 0.2 * L) {
        warn("edge_length", "Edges average " + mesh::length_text(stats.mean_edge) + "; asked for " + mesh::length_text(L) + " (sharp edges and borders limit it).");
    }
    else {
        checks["edge_length"] = "ok";
    }
    mesh::note_untested_crossings("Remesh", last_report, checks, warnings);
    last_report["ms"] = mesh::op_now_ms() - started;  // with the checks above
    last_report["checks"] = checks;
    last_warning = String("\n").join(warnings);
    return out;
}

}  // namespace holo_forge
