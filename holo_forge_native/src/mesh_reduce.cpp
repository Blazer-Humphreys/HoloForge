// Reduce (work order 3.3.3). Adaptive: pmp's decimate in a fixed staircase of calls, with locks
// and features for open edges, group borders and sharp edges. Fast: meshoptimizer on the welded
// mesh with vertex locks. Both keep every surviving vertex where it was.

#include "cad_mesh.h"
#include "mesh_bvh.h"
#include "mesh_pmp.h"

#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>

#include <meshoptimizer.h>
#include <pmp/algorithms/decimation.h>
#include <pmp/algorithms/features.h>

#include <algorithm>
#include <cmath>
#include <memory>
#include <cstdio>
#include <cstring>
#include <exception>
#include <limits>
#include <unordered_map>

using namespace godot;

namespace holo_forge
{

namespace mesh
{
namespace
{
const char* kAdaptiveHint = "Use the Fast method, or Reduce a smaller body.";
const char* kFastHint = "Reduce a smaller body or a selection.";

struct ReduceOptions
{
    int target = 0;  // 0 proportion, 1 face count, 2 tolerance
    double tolerance = 0.0;
    bool adaptive = true;
    bool keep_boundary = true, keep_groups = true, keep_sharp = false;
    double sharp_angle = 45.0;
    bool selection = false;
    std::vector<uint32_t> triangles;
    bool tolerance_features = false;  // by Maximum Deviation: sharp edges are features (see CadMesh::reduce)
    double measure_estimate = 0.0;    // by Maximum Deviation: seconds the check at every vertex and middle takes
};

struct ReduceStats
{
    int calls = 0;
    size_t locked_vertices = 0;
    size_t free_vertices = 0;
    size_t welded = 0;
    bool nothing_free = false;
    bool unchanged = false;            // the library took nothing out: the input is the result
    size_t touching = 0;               // vertices where pieces only touch (fast: kept apart)
    bool corrections_skipped = false;
    double build_ms = 0.0;             // making the library's mesh
    std::vector<double> call_ms;       // each library call
    std::vector<int64_t> call_start;   // the triangles each call started from
    std::vector<int64_t> call_target;  // the triangles each call was asked to leave
    double library_error = 0.0;  // meshoptimizer's own error (absolute)
};

/// Seconds one pmp decimate call takes on `triangles` triangles when it takes out `removed` of
/// them (the measured curve is for one call to 50 %; a call costs a base part for its queue
/// plus a part by what it removes).
double decimate_call_estimate(double triangles, double removed, bool hausdorff)
{
    const double half = budget::estimate(budget::PMP_DECIMATE_HALF, triangles);
    const double share = triangles > 0.0 ? std::min(std::max(removed / triangles, 0.0), 1.0) : 0.0;
    return half * (budget::DECIMATE_BASE_SHARE + (1.0 - budget::DECIMATE_BASE_SHARE) * share / 0.5) * (hausdorff ? budget::DECIMATE_HAUSDORFF_FACTOR : 1.0);
}

bool reduce_adaptive(State& state, const ReduceOptions& opt, size_t target_total, double tolerance_share, const Deadline& deadline, MeshData& out, ReduceStats& stats,
                     std::string& error)
{
    const MeshData& m = state.data;
    const size_t T = m.triangle_count(), V = m.vertex_count();
    const std::string refusal = pmp_refusal(state);
    if (!refusal.empty()) {
        error = refusal;
        return false;
    }
    const std::vector<uint32_t>* tris = opt.selection ? &opt.triangles : nullptr;
    const size_t part = opt.selection ? opt.triangles.size() : T;
    const size_t outside = T - part;
    const bool by_tolerance = opt.target == 2;
    // The target for the part that is reduced.
    const size_t part_target = by_tolerance ? 0 : (target_total > outside ? target_total - outside : 0);
    const double to_remove = by_tolerance ? double(part) : double(part > part_target ? part - part_target : 0);

    // Up-front: the whole staircase, the build and the checks at the end.
    double staircase = 0.0;
    {
        const int steps = by_tolerance ? 1 : budget::DECIMATE_STEPS;
        double now = double(part);
        for (int i = 0; i < steps; ++i) {
            const double removed = to_remove / steps;
            staircase += decimate_call_estimate(now, removed, by_tolerance);
            now -= removed;
        }
    }
    const double after = double(T) - to_remove;
    const double whole = budget::estimate(budget::PMP_SURFACE_MESH_BUILD, double(part)) + staircase + post_check_estimate(after, true) + budget::estimate(budget::BVH_BUILD, double(T)) +
                         budget::estimate(budget::BVH_BUILD, after) + opt.measure_estimate;
    if (whole > deadline.limit()) {
        error = too_slow_text("Reduce", whole, deadline.limit(), kAdaptiveHint);
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
    auto origin = pm.add_vertex_property<uint32_t>("v:origin", NONE);
    for (size_t i = 0; i < vertex_of.size(); ++i) {
        origin[pmp::Vertex(pmp::IndexType(i))] = vertex_of[i];
    }
    auto group = pm.add_face_property<uint32_t>("f:group", 0);
    for (size_t i = 0; i < part; ++i) {
        group[pmp::Face(pmp::IndexType(i))] = m.groups[tris != nullptr ? (*tris)[i] : uint32_t(i)];
    }

    // Features: collapses run along them only. Sharp edges first, then group borders.
    // (By Maximum Deviation sharp edges are features too when a first try came out too far off:
    // a collapse across a sharp edge cuts a corner off, and pmp's own deviation check, made from
    // the corners it took out, does not see it. Measured on an L-bracket: 4.7 mm off at every
    // tolerance. Not from the start: on a rough scan most edges are that sharp.)
    if (opt.keep_sharp || (by_tolerance && opt.tolerance_features)) {
        pmp::detect_features(pm, float(opt.sharp_angle));
    }
    if (opt.keep_groups) {
        mark_group_borders(pm, group);
    }
    // Locks: a vertex that is not "selected" is never taken out (and no vertex ever moves).
    auto selected = pm.add_vertex_property<bool>("v:selected", true);
    if (opt.selection) {
        // The rim of the selection: vertices that unselected triangles use too.
        std::vector<uint8_t> in_part(T, 0), rim(V, 0);
        for (const uint32_t t : opt.triangles) {
            in_part[t] = 1;
        }
        for (size_t t = 0; t < T; ++t) {
            if (!in_part[t]) {
                rim[m.triangles[t * 3]] = rim[m.triangles[t * 3 + 1]] = rim[m.triangles[t * 3 + 2]] = 1;
            }
        }
        for (const pmp::Vertex v : pm.vertices()) {
            if (rim[origin[v]]) {
                selected[v] = false;
            }
        }
    }
    if (opt.keep_boundary) {
        const std::vector<uint8_t> open = boundary_vertices(state);
        for (const pmp::Vertex v : pm.vertices()) {
            if (open[origin[v]]) {
                selected[v] = false;
            }
        }
    }
    if (opt.keep_groups) {
        // Keep Face Group Borders: the vertices on a border stay, as with Fast. (A collapse along
        // a border straightens it: measured 2 to 4 mm on a ball of 50 mm grouped by octants.)
        for (const pmp::Edge e : pm.edges()) {
            const pmp::Face f0 = pm.face(e, 0), f1 = pm.face(e, 1);
            if (f0.is_valid() && f1.is_valid() && group[f0] != group[f1]) {
                selected[pm.vertex(e, 0)] = false;
                selected[pm.vertex(e, 1)] = false;
            }
        }
    }
    {
        auto vfeature = pm.get_vertex_property<bool>("v:feature");
        auto efeature = pm.get_edge_property<bool>("e:feature");
        if (vfeature && efeature) {
            // Where features meet or end, the corner stays (a collapse along one feature would
            // drag the others).
            for (const pmp::Vertex v : pm.vertices()) {
                if (!vfeature[v]) {
                    continue;
                }
                int count = 0;
                for (const pmp::Halfedge h : pm.halfedges(v)) {
                    count += efeature[pm.edge(h)] ? 1 : 0;
                }
                if (count != 2) {
                    selected[v] = false;
                }
            }
        }
    }
    for (const pmp::Vertex v : pm.vertices()) {
        stats.free_vertices += selected[v] ? 1 : 0;
    }
    stats.locked_vertices = pm.n_vertices() - stats.free_vertices;
    if (stats.free_vertices == 0) {
        // (With nothing selected pmp would lock nothing at all.)
        stats.nothing_free = true;
        out = m;
        return true;
    }

    const float hausdorff = by_tolerance ? float(opt.tolerance * tolerance_share) : 0.0f;
    // The staircase may not make an edge longer than DECIMATE_EDGE_FACTOR x the mean edge the
    // target count gives: without that limit pmp leaves long triangles, which sit further from
    // a curved surface (measured on a sphere at 50 %: 0.065 mm without, 0.043 mm with). The
    // guard calls after it run without the limit, so the limit never keeps the count up.
    const double mean_out = (opt.selection ? mean_edge_length(state, opt.triangles) : mean_edge_length(state)) * std::sqrt(double(part) / std::max(1.0, double(part) - to_remove));
    const double mean_in = mean_out / std::sqrt(double(part) / std::max(1.0, double(part) - to_remove));
    // (Never below what one collapse needs: taking a vertex out about doubles an edge.)
    const float edge_limit = by_tolerance ? 0.0f : float(std::max(budget::DECIMATE_EDGE_FACTOR * mean_out, budget::DECIMATE_EDGE_FLOOR * mean_in));
    auto call = [&](size_t vertices_to_remove, bool limit_edges) {
        const size_t have = pm.n_vertices();
        const size_t goal = vertices_to_remove >= have ? 4 : std::max<size_t>(have - vertices_to_remove, 4);
        const double call_started = op_now_ms();
        stats.call_start.push_back(int64_t(pm.n_faces()));
        pmp::decimate(pm, static_cast<unsigned int>(goal), 10.0f, limit_edges ? edge_limit : 0.0f, 0, 60.0f, hausdorff, 1e-2f, 1.0f);
        stats.call_ms.push_back(op_now_ms() - call_started);
        ++stats.calls;
    };
    try {
        if (by_tolerance) {
            call(pm.n_vertices(), false);
        }
        else {
            // A collapse inside the surface takes out one vertex and two triangles.
            for (int step = 0; step < budget::DECIMATE_STEPS; ++step) {
                const size_t have = pm.n_faces();
                if (have <= part_target) {
                    break;
                }
                const size_t excess = have - part_target;
                const size_t vertices = (excess + size_t(2 * (budget::DECIMATE_STEPS - step)) - 1) / size_t(2 * (budget::DECIMATE_STEPS - step));
                // A call cannot be stopped: it is not started when it would end after the limit.
                const double next = decimate_call_estimate(double(have), double(vertices) * 2.0, false);
                if (step > 0 && deadline.elapsed() + next > deadline.limit()) {
                    error = stopped_text("Reduce", deadline.elapsed(), deadline.elapsed() + next * (budget::DECIMATE_STEPS - step), deadline.limit(), kAdaptiveHint);
                    return false;
                }
                call(vertices, true);
            }
            // The guard: still more than 2 % above the target (collapses along open edges take
            // out one triangle each), up to two more calls.
            for (int extra = 0; extra < 2; ++extra) {
                const size_t have = pm.n_faces();
                if (double(have + outside) <= double(target_total) * 1.02 || have <= part_target) {
                    break;
                }
                const size_t vertices = (have - part_target + 1) / 2;
                if (deadline.elapsed() + decimate_call_estimate(double(have), double(vertices) * 2.0, false) > deadline.limit()) {
                    stats.corrections_skipped = true;
                    break;
                }
                const size_t before = pm.n_faces();
                call(vertices, false);
                if (pm.n_faces() == before) {
                    break;  // nothing more can go
                }
            }
        }
    }
    catch (const std::exception& e) {
        error = library_error("Reduce", e.what());
        return false;
    }
    catch (...) {
        error = library_error("Reduce", nullptr);
        return false;
    }

    if (pm.n_faces() >= part) {
        // Nothing went: the input is the result.
        stats.unchanged = true;
        out = m;
        return true;
    }
    // Back: the triangles outside a selection as they were, then the reduced part. Every vertex
    // left is an input vertex.
    out.positions = m.positions;
    out.group_names = m.group_names;
    out.triangles.clear();
    out.groups.clear();
    out.triangles.reserve((outside + pm.n_faces()) * 3);
    out.groups.reserve(outside + pm.n_faces());
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
    for (const pmp::Face f : pm.faces()) {
        for (const pmp::Vertex v : pm.vertices(f)) {
            out.triangles.push_back(origin[v]);
        }
        out.groups.push_back(group[f]);
    }
    return true;
}

/// `welded_state` comes back holding the mesh the library worked on (the input welded): the
/// reference for the border checks. `error_limit` is the library's limit by Maximum Deviation;
/// `free_limit` one that never binds (the body's diagonal).
bool reduce_fast(State& state, std::unique_ptr<State>& welded_state, const ReduceOptions& opt, size_t target_total, double error_limit, double free_limit, const Deadline& deadline,
                 MeshData& out, ReduceStats& stats, std::string& error)
{
    // Always on the welded mesh: vertices split along a group border would let the border drift.
    welded_state = std::make_unique<State>();
    welded_state->data = state.data;
    stats.welded = weld_exact(welded_state->data);
    {
        State& welded = *welded_state;
        // weld_exact writes -0 as 0. Every vertex left must be an input vertex bit for bit, so
        // each welded vertex gets the bits of the first input vertex that became it back (the
        // welded vertices are numbered in that order).
        std::vector<float>& kept_positions = welded.data.positions;
        const size_t kept_vertices = kept_positions.size() / 3;
        size_t next = 0;
        for (size_t v = 0; v < state.data.vertex_count() && next < kept_vertices; ++v) {
            const float* p = &state.data.positions[v * 3];
            const float q[3] = {p[0] + 0.0f, p[1] + 0.0f, p[2] + 0.0f};
            if (std::memcmp(q, &kept_positions[next * 3], sizeof(q)) == 0) {
                std::memcpy(&kept_positions[next * 3], p, sizeof(q));
                ++next;
            }
        }
    }
    // Welding by position also joins what only touches: two bodies corner to corner, edge to
    // edge or face to face become one surface that is not manifold there, and the library, which
    // takes such a corner for an ordinary one, drags both bodies along. Where welding made such
    // places they are taken apart again (the vertices split by face groups or the like stay
    // welded), and the vertices there stay.
    std::vector<uint32_t> touching;
    if (stats.welded > 0) {
        const Topology* joined = topology_of(*welded_state, &deadline);
        const Topology* given = topology_of(state, &deadline);
        if (joined == nullptr || given == nullptr) {
            error = timed_out_text("Reduce", deadline.limit(), kFastHint);
            return false;
        }
        if (joined->non_manifold_edges > given->non_manifold_edges || non_manifold_vertex_count(*welded_state) > non_manifold_vertex_count(state)) {
            auto apart = std::make_unique<State>();
            apart->data = std::move(welded_state->data);
            welded_state = std::move(apart);
            const size_t before = welded_state->data.vertex_count();
            SheetStats sheets;
            if (!split_into_sheets(welded_state->data, sheets, deadline)) {
                error = timed_out_text("Reduce", deadline.limit(), kFastHint);
                return false;
            }
            touching = sheets.copied;
            for (size_t i = 0; i < sheets.copied.size(); ++i) {
                touching.push_back(uint32_t(before + i));
            }
            stats.touching = touching.size();
        }
    }
    State& welded = *welded_state;
    const MeshData& d = welded.data;
    const size_t T = d.triangle_count(), V = d.vertex_count();
    const Topology* topo = topology_of(welded, &deadline);
    if (topo == nullptr) {
        error = timed_out_text("Reduce", deadline.limit(), kFastHint);
        return false;
    }
    // Locks: group-border vertices, open-edge vertices, sharp-edge vertices, everything a
    // selection does not hold alone.
    std::vector<unsigned char> lock(V, 0);
    const std::vector<uint8_t> border = group_border_vertices(d);
    if (opt.keep_groups) {
        for (size_t v = 0; v < V; ++v) {
            lock[v] = border[v] ? meshopt_SimplifyVertex_Lock : 0;
        }
    }
    if (opt.keep_boundary) {
        const std::vector<uint8_t> open = boundary_vertices(welded);
        for (size_t v = 0; v < V; ++v) {
            if (open[v]) {
                lock[v] = meshopt_SimplifyVertex_Lock;
            }
        }
    }
    if (opt.keep_sharp) {
        const double sharp = std::cos(opt.sharp_angle * M_PI / 180.0);
        for (size_t e = 0; e < topo->edge_count(); ++e) {
            if (topo->uses(uint32_t(e)) != 2) {
                continue;
            }
            const uint32_t h0 = topo->edge_hes[topo->edge_first[e]], h1 = topo->edge_hes[size_t(topo->edge_first[e]) + 1];
            const double sign = d.triangles[h0] == d.triangles[h1] ? -1.0 : 1.0;
            if (sign * dot(normalized(triangle_cross(d, h0 / 3)), normalized(triangle_cross(d, h1 / 3))) < sharp) {
                lock[d.triangles[h0]] = meshopt_SimplifyVertex_Lock;
                lock[d.triangles[h0 - h0 % 3 + (h0 + 1) % 3]] = meshopt_SimplifyVertex_Lock;
            }
        }
    }
    if (opt.selection) {
        std::vector<uint8_t> in_part(T, 0);
        for (const uint32_t t : opt.triangles) {
            in_part[t] = 1;
        }
        for (size_t t = 0; t < T; ++t) {
            if (!in_part[t]) {
                lock[d.triangles[t * 3]] = lock[d.triangles[t * 3 + 1]] = lock[d.triangles[t * 3 + 2]] = meshopt_SimplifyVertex_Lock;
            }
        }
    }
    for (const uint32_t v : touching) {
        lock[v] = meshopt_SimplifyVertex_Lock;
    }
    std::vector<uint8_t> used(V, 0);
    for (const uint32_t v : d.triangles) {
        used[v] = 1;
    }
    for (size_t v = 0; v < V; ++v) {
        if (used[v]) {
            stats.locked_vertices += lock[v] ? 1 : 0;
            stats.free_vertices += lock[v] ? 0 : 1;
        }
    }
    if (stats.free_vertices == 0) {
        stats.nothing_free = true;
        out = state.data;
        return true;
    }
    if (deadline.expired()) {
        error = timed_out_text("Reduce", deadline.limit(), kFastHint);
        return false;
    }
    std::vector<unsigned int> kept(T * 3);
    float result_error = 0.0f;
    const char* broken_list = "Reduce failed inside the mesh library: it gave back a broken triangle list.";
    // One library call from the welded input down to `target_triangles`, with an error limit
    // that never binds. (No Regularize: it shortens jagged group borders.)
    auto simplify = [&](size_t target_triangles, std::vector<unsigned int>& into, float& library_error) {
        const double call_started = op_now_ms();
        stats.call_start.push_back(int64_t(T));
        stats.call_target.push_back(int64_t(target_triangles));
        const size_t got = meshopt_simplifyWithAttributes(into.data(), d.triangles.data(), T * 3, d.positions.data(), V, sizeof(float) * 3, nullptr, 0, nullptr, 0, lock.data(), target_triangles * 3,
                                                          float(free_limit), meshopt_SimplifyErrorAbsolute, &library_error);
        stats.call_ms.push_back(op_now_ms() - call_started);
        ++stats.calls;
        return got;
    };
    size_t count = T * 3;
    if (opt.target != 2) {
        count = simplify(target_total, kept, result_error);
        if (count % 3 != 0 || count > T * 3) {
            error = broken_list;
            return false;
        }
    }
    else {
        // By Maximum Deviation: the smallest count whose library error is within the limit,
        // found by halving between counts, every call to a count and from the input again.
        // (The library's own error limit is not used: with a limit near what its float sums can
        // tell apart, one call makes passes that each take a handful of triangles out, thousands
        // of them, and cannot be stopped: measured 13 s on 99,372 triangles of a flat grid body
        // and over 500 s on a million. A call to a count makes a few passes whatever the mesh.)
        // The search stops when the count is known to a sixteenth of itself or of what went.
        const double probe = budget::MESHOPT_PROBE_FACTOR * budget::estimate(budget::MESHOPT_SIMPLIFY_HALF, double(T));
        std::vector<unsigned int> trial(T * 3);
        size_t lo = 0, hi = T;
        for (int i = 0; i < budget::MESHOPT_MAX_PROBES; ++i) {
            if (hi - lo <= std::max<size_t>(2, std::min(T - lo, hi) / 16)) {
                break;
            }
            // A call cannot be stopped: it is not started when it would end after the limit.
            if (deadline.elapsed() + probe > deadline.limit()) {
                error = stopped_text("Reduce", deadline.elapsed(), deadline.elapsed() + 2.0 * probe, deadline.limit(), kFastHint);
                return false;
            }
            const size_t mid = lo + (hi - lo) / 2;
            float trial_error = 0.0f;
            const size_t got = simplify(mid, trial, trial_error);
            if (got % 3 != 0 || got > T * 3) {
                error = broken_list;
                return false;
            }
            if (double(trial_error) <= error_limit) {
                kept.swap(trial);
                count = got;
                result_error = trial_error;
                hi = std::min(mid, got / 3);
                if (got / 3 > mid) {
                    break;  // locks and the mesh's shape let no more go: a lower count gives the same
                }
            }
            else {
                lo = mid;
            }
        }
    }
    stats.library_error = result_error;
    if (count >= T * 3) {
        // Nothing went: the input is the result (not its welded copy).
        stats.unchanged = true;
        out = state.data;
        return true;
    }
    const size_t kept_count = count / 3;
    out.positions = d.positions;
    out.group_names = d.group_names;
    out.triangles.assign(kept.begin(), kept.begin() + count);
    out.groups.resize(kept_count);

    // The group of each triangle left: that of a corner inside one group; when all three lie on
    // group borders, that of the input triangle with the same corners, else of the nearest one.
    std::vector<uint32_t> group_of(V, NONE);
    for (size_t t = 0; t < T; ++t) {
        for (int k = 0; k < 3; ++k) {
            const uint32_t v = d.triangles[t * 3 + size_t(k)];
            if (group_of[v] == NONE) {
                group_of[v] = d.groups[t];
            }
        }
    }
    auto key_of = [](uint32_t a, uint32_t b, uint32_t c) {
        if (a > b) {
            std::swap(a, b);
        }
        if (b > c) {
            std::swap(b, c);
        }
        if (a > b) {
            std::swap(a, b);
        }
        uint64_t h = uint64_t(a) * 0x9E3779B97F4A7C15ull;
        h = (h ^ (h >> 29)) + uint64_t(b) * 0xC2B2AE3D27D4EB4Full;
        h = (h ^ (h >> 31)) + uint64_t(c) * 0x165667B19E3779F9ull;
        return h ^ (h >> 32);
    };
    std::unordered_multimap<uint64_t, uint32_t> on_borders;  // input triangles with three border corners
    bool mapped = false;
    const TriBvh* bvh = nullptr;
    for (size_t t = 0; t < kept_count; ++t) {
        const uint32_t* tri = &out.triangles[t * 3];
        uint32_t g = NONE;
        for (int k = 0; k < 3 && g == NONE; ++k) {
            if (!border[tri[k]]) {
                g = group_of[tri[k]];
            }
        }
        if (g == NONE) {
            if (!mapped) {
                for (size_t s = 0; s < T; ++s) {
                    const uint32_t* in = &d.triangles[s * 3];
                    if (border[in[0]] && border[in[1]] && border[in[2]]) {
                        on_borders.emplace(key_of(in[0], in[1], in[2]), uint32_t(s));
                    }
                }
                mapped = true;
            }
            const auto range = on_borders.equal_range(key_of(tri[0], tri[1], tri[2]));
            for (auto it = range.first; it != range.second && g == NONE; ++it) {
                const uint32_t* in = &d.triangles[size_t(it->second) * 3];
                const bool same = (tri[0] == in[0] || tri[0] == in[1] || tri[0] == in[2]) && (tri[1] == in[0] || tri[1] == in[1] || tri[1] == in[2]) &&
                                  (tri[2] == in[0] || tri[2] == in[1] || tri[2] == in[2]);
                if (same) {
                    g = d.groups[it->second];
                }
            }
        }
        if (g == NONE) {
            if (bvh == nullptr) {
                bvh = bvh_of(welded, &deadline);
                if (bvh == nullptr) {
                    error = timed_out_text("Reduce", deadline.limit(), kFastHint);
                    return false;
                }
            }
            const V3 c = (point_of(d, tri[0]) + point_of(d, tri[1]) + point_of(d, tri[2])) * (1.0 / 3.0);
            const double p[3] = {c.x, c.y, c.z};
            uint32_t nearest = NONE;
            double q[3];
            bvh->nearest(p, std::numeric_limits<double>::infinity(), nearest, q);
            g = nearest != NONE ? d.groups[nearest] : 0;
        }
        out.groups[t] = g;
        if (deadline.tick()) {
            error = timed_out_text("Reduce", deadline.limit(), kFastHint);
            return false;
        }
    }
    return true;
}

}  // namespace
}  // namespace mesh

Ref<CadMesh> CadMesh::reduce(const Dictionary& options)
{
    clear_messages();
    const double started = mesh::op_now_ms();
    if (is_null()) {
        fail("There is no mesh to reduce.");
        return Ref<CadMesh>();
    }
    const mesh::MeshData& m = state->data;
    const size_t T = m.triangle_count();
    const double D = mesh::measures_of(*state).diagonal;
    if (T <= 4) {
        fail("The mesh has only " + mesh::with_commas(T) + " triangles; there is nothing to reduce.");
        return Ref<CadMesh>();
    }
    mesh::OptionReader reader(options);
    mesh::ReduceOptions opt;
    opt.target = reader.choice("target", "Reduce By", {"proportion", "face_count", "tolerance"}, 0);
    const double proportion = reader.number("proportion", "Keep", 50.0, 1.0, 99.0, "%");
    const int64_t face_count = reader.integer("face_count", "Triangle Count", int64_t(T / 2), 4, int64_t(T) - 1);
    opt.tolerance = reader.number("tolerance", "Maximum Deviation", D / 2000.0, D * 1e-6, D / 10.0, "m");
    opt.adaptive = reader.choice("method", "Method", {"adaptive", "fast"}, 0) == 0;
    opt.keep_boundary = reader.flag("keep_boundary", "Keep Open Edges", true);
    opt.keep_groups = reader.flag("keep_groups", "Keep Face Group Borders", true);
    opt.keep_sharp = reader.flag("keep_sharp", "Keep Sharp Edges", false);
    opt.sharp_angle = reader.number("sharp_angle", "Sharp Edge Angle", 45.0, 10.0, 170.0, "deg");
    opt.triangles = reader.triangles("triangles", T, &opt.selection);
    const double limit = reader.time_limit();
    if (!reader.ok()) {
        fail(reader.error());
        return Ref<CadMesh>();
    }
    if (opt.selection && opt.triangles.empty()) {
        fail("Select the triangles to reduce, or reduce the whole body.");
        return Ref<CadMesh>();
    }
    if (opt.selection && opt.triangles.size() == T) {
        opt.selection = false;
    }
    {
        // Far from the origin positions step by more than a share of an edge: the result would
        // be made of rounding (triangles without area, a volume change that is only noise).
        const double edge = mesh::typical_edge(*state);
        const std::string far = mesh::far_refusal(*state, options, edge, "too coarse for its edges of " + mesh::length_text(edge));
        if (!far.empty()) {
            fail(far);
            return Ref<CadMesh>();
        }
    }
    const size_t target = opt.target == 0 ? size_t(std::llround(double(T) * proportion / 100.0)) : (opt.target == 1 ? size_t(face_count) : 0);
    const size_t outside = opt.selection ? T - opt.triangles.size() : 0;
    if (opt.target != 2 && opt.selection && target <= outside) {
        fail("The selection has " + mesh::with_commas(opt.triangles.size()) + " of the mesh's " + mesh::with_commas(T) + " triangles: it cannot bring the body down to " +
             mesh::with_commas(target) + ". Grow the selection or keep more triangles.");
        return Ref<CadMesh>();
    }
    const char* hint = opt.adaptive ? mesh::kAdaptiveHint : mesh::kFastHint;
    if (!opt.adaptive) {
        // (By Maximum Deviation the library is called several times: see reduce_fast.)
        const double calls = opt.target == 2 ? mesh::budget::MESHOPT_TOLERANCE_PROBES * mesh::budget::MESHOPT_PROBE_FACTOR : 2.0;
        const double estimate = calls * mesh::budget::estimate(mesh::budget::MESHOPT_SIMPLIFY_HALF, double(T)) + mesh::budget::estimate(mesh::budget::REDUCE_FAST_SETUP, double(T)) +
                                mesh::post_check_estimate(double(T), true) + 2.0 * mesh::budget::estimate(mesh::budget::BVH_BUILD, double(T));
        if (estimate > limit) {
            fail(mesh::too_slow_text("Reduce", estimate, limit, hint));
            return Ref<CadMesh>();
        }
    }
    // (By Maximum Deviation: the check at the points of the triangles that changed, at most 4.5 points an input triangle each way.)
    opt.measure_estimate = opt.target == 2 ? mesh::budget::POINT_DISTANCE_SECONDS_PER_MILLION * 9.0 * double(T) / 1e6 : 0.0;
    if (opt.target == 2 && !opt.adaptive) {
        const double estimate = mesh::budget::MESHOPT_TOLERANCE_PROBES * mesh::budget::MESHOPT_PROBE_FACTOR * mesh::budget::estimate(mesh::budget::MESHOPT_SIMPLIFY_HALF, double(T)) +
                                mesh::budget::estimate(mesh::budget::REDUCE_FAST_SETUP, double(T)) + mesh::post_check_estimate(double(T), true) +
                                2.0 * mesh::budget::estimate(mesh::budget::BVH_BUILD, double(T)) + opt.measure_estimate;
        if (estimate > limit) {
            fail(mesh::too_slow_text("Reduce", estimate, limit, hint));
            return Ref<CadMesh>();
        }
    }
    const mesh::Deadline deadline(limit);
    const mesh::Distance none;
    mesh::Distance forward = none, backward = none;
    double measure_ms = 0.0;
    // By proportion or face count the same measure as by Maximum Deviation (20,000 samples each
    // way read low: 0.000873 mm for a true 0.001746 after one collapse), when it fits in what the
    // work order allows Reduce on this many triangles (Fast 2 s a million, Adaptive 6 s per
    // 100,000) after the reduction itself, or takes a second at most; and in the time limit.
    // When it does not (Fast on large bodies: it would take five times the reduction), the
    // samples alone, and that is said.
    const double lattice_seconds = mesh::budget::POINT_DISTANCE_SECONDS_PER_MILLION * 9.0 * double(T) / 1e6;
    const double allowed_seconds = opt.adaptive ? 6.0 * double(T) / 1e5 : 2.0 * double(T) / 1e6;
    bool sampled_only = false;
    bool lattice_skipped = false;  // (not tried: it would not fit; else it ran out of time)
    auto measure = [&](mesh::State& result) {
        // Both ways, 20,000 samples each (work order 2.6.3).
        forward = mesh::distance_between(result, *state, 20000, deadline);
        backward = mesh::distance_between(*state, result, 20000, deadline);
        if (forward.timed_out || backward.timed_out) {
            return false;
        }
        if (opt.target != 2) {
            sampled_only = true;
            if (lattice_seconds > std::max(1.0, allowed_seconds - deadline.elapsed()) || deadline.elapsed() + lattice_seconds > 0.9 * limit) {
                lattice_skipped = true;
                return true;
            }
            const mesh::Distance at_result = mesh::distance_at_points(result, *state, deadline, 4 * T);
            const mesh::Distance at_input = at_result.timed_out ? at_result : mesh::distance_at_points(*state, result, deadline, 4 * T);
            if (!at_result.timed_out && !at_input.timed_out) {
                forward.max = std::max(forward.max, at_result.max);
                backward.max = std::max(backward.max, at_input.max);
                forward.samples += at_result.samples;
                backward.samples += at_input.samples;
                sampled_only = false;
            }
            return true;
        }
        if (opt.target == 2) {
            // By Maximum Deviation the result is promised to be within it, and 20,000 samples
            // miss the worst place (measured on a blob: 0.086 mm sampled, 0.102 mm at the worst
            // triangle middle). So also on a lattice of points across every triangle that is
            // not in both meshes, with its corners (the input's corners that went are where the
            // surface moved most; a large new triangle has its worst place inside): the fewer
            // triangles changed, the finer the lattice, up to 4 points an input triangle each way.
            const double measure_started = mesh::op_now_ms();
            const mesh::Distance at_result = mesh::distance_at_points(result, *state, deadline, 4 * T), at_input = mesh::distance_at_points(*state, result, deadline, 4 * T);
            measure_ms += mesh::op_now_ms() - measure_started;
            if (at_result.timed_out || at_input.timed_out) {
                return false;
            }
            forward.max = std::max(forward.max, at_result.max);
            backward.max = std::max(backward.max, at_input.max);
            forward.samples += at_result.samples;
            backward.samples += at_input.samples;
        }
        return true;
    };
    mesh::MeshData data;
    mesh::ReduceStats stats;
    std::string error;
    bool ok = false;
    bool measured = false;
    bool nothing_within = false;  // by Maximum Deviation: no attempt came out within it
    std::unique_ptr<mesh::State> welded;
    try {
        // By tolerance each library's own error is a guide only (pmp checks the corners it took
        // out, meshoptimizer a float sum of squares): the result is measured both ways, and when
        // it is over, the work is done again with a smaller limit, and only while there is time
        // for it: three tries for Fast; six for Adaptive, the last two with sharp edges as
        // features.
        double share = opt.adaptive ? mesh::budget::DECIMATE_TOLERANCE_SHARE : mesh::budget::MESHOPT_TOLERANCE_SHARE;
        const int tries = opt.adaptive ? 6 : 3;
        for (int attempt = 0; attempt < tries; ++attempt) {
            opt.tolerance_features = attempt >= 4;
            const double attempt_started = deadline.elapsed();
            stats = mesh::ReduceStats();
            data = mesh::MeshData();
            if (opt.adaptive) {
                ok = mesh::reduce_adaptive(*state, opt, target, share, deadline, data, stats, error);
            }
            else {
                ok = mesh::reduce_fast(*state, welded, opt, target, opt.tolerance * share, D, deadline, data, stats, error);
            }
            if (!ok || opt.target != 2 || stats.nothing_free || stats.unchanged) {
                break;
            }
            mesh::State trial;
            trial.data = data;
            mesh::compact(trial.data);
            if (trial.data.triangle_count() == 0) {
                break;
            }
            if (!measure(trial)) {
                ok = false;
                error = mesh::timed_out_text("Reduce", limit, hint);
                break;
            }
            measured = true;
            const double worst = std::max(forward.max, backward.max);
            // (Within 98 % of it: what is left between the measured points after the climb.)
            if (worst <= mesh::budget::TOLERANCE_MARGIN * opt.tolerance) {
                break;
            }
            measured = false;
            share *= 0.8 * opt.tolerance / worst;
            const double took = deadline.elapsed() - attempt_started;
            if (attempt == tries - 1) {
                // Every try, each with a smaller limit for the library, came out further off
                // than asked: nothing can be taken out within it this way.
                nothing_within = true;
                break;
            }
            if (deadline.elapsed() + 1.5 * took > limit) {
                ok = false;
                error = mesh::stopped_text("Reduce", deadline.elapsed(), deadline.elapsed() + 1.5 * took, limit, hint);
                break;
            }
        }
    }
    catch (const std::exception& e) {
        error = mesh::library_error("Reduce", e.what());
        ok = false;
    }
    catch (...) {
        error = mesh::library_error("Reduce", nullptr);
        ok = false;
    }
    if (!ok) {
        fail(error);
        return Ref<CadMesh>();
    }
    if (stats.nothing_free || stats.unchanged || nothing_within) {
        // Nothing was taken out: the mesh itself, and why.
        std::string text;
        if (stats.nothing_free && opt.selection) {
            text = "The selection is too small to reduce; grow it.";
        }
        else if (opt.target == 2) {
            if (stats.nothing_free) {
                text = "Nothing can be taken out: every vertex lies on an open edge, a group border or a sharp edge that is kept.";
            }
            else {
                text = "Nothing could be taken out within the Maximum Deviation of " + mesh::length_text(opt.tolerance) + ".";
                if (!opt.adaptive && (nothing_within || opt.tolerance < 1e-3 * D)) {
                    text += " (Fast cannot tell deviations below about " + mesh::length_text(1e-3 * D) + " apart on this body; the Adaptive method can.)";
                }
            }
        }
        else {
            text = "Reduce kept " + mesh::with_commas(T) + " triangles (100 %) instead of " + mesh::with_commas(target) + ": " +
                   (stats.nothing_free ? "every vertex lies on an open edge, a group border or a sharp edge that is kept." : "open edges, group borders and sharp edges limit it.");
        }
        last_warning = mesh::op_text(text);
        last_report["op"] = "reduce";
        last_report["ms"] = mesh::op_now_ms() - started;
        last_report["method"] = opt.adaptive ? "adaptive" : "fast";
        last_report["target"] = int64_t(target);
        last_report["calls"] = int64_t(stats.calls);
        last_report["unchanged"] = true;
        return Ref<CadMesh>(this);
    }
    if (data.triangle_count() == 0) {
        fail("Reduce would leave nothing of the mesh. Keep more triangles.");
        return Ref<CadMesh>();
    }
    const mesh::Summary before = mesh::summarize(*state);
    // (Fast works on the welded input: its borders are the reference there.)
    mesh::State& reference = !opt.adaptive && welded ? *welded : *state;
    const double border_before = opt.keep_groups && !opt.adaptive ? mesh::group_border_length(reference) : 0.0;
    const size_t touching_before = !opt.adaptive ? mesh::non_manifold_vertex_count(*state) : 0;
    Ref<CadMesh> out = finish_op("Reduce", "reduce", std::move(data), started, true);
    if (out.is_null()) {
        return out;
    }
    Dictionary checks = last_report.get("checks", Dictionary());
    PackedStringArray warnings;
    if (!last_warning.is_empty()) {
        // The non-manifold count has its own sentence for Fast, below.
        for (const String& line : last_warning.split("\n")) {
            if (opt.adaptive || !line.contains("edges that more than two triangles share")) {
                warnings.push_back(line);
            }
        }
    }
    auto broken = [&](const char* key, const std::string& text) {
        checks[key] = String("fail: ") + mesh::op_text(text);
        last_report["checks"] = checks;
        fail(text);
        return Ref<CadMesh>();
    };
    const mesh::Summary after = mesh::summarize(out->get_state());
    const size_t got = size_t(after.triangles);
    last_report["method"] = opt.adaptive ? "adaptive" : "fast";
    last_report["target"] = int64_t(target);
    last_report["calls"] = int64_t(stats.calls);
    last_report["locked_vertices"] = int64_t(stats.locked_vertices);
    {
        // Where the time went (for the cost rates in mesh_budget.h).
        PackedFloat64Array call_ms;
        PackedInt64Array call_start, call_target;
        for (size_t i = 0; i < stats.call_ms.size(); ++i) {
            call_ms.push_back(stats.call_ms[i]);
            call_start.push_back(stats.call_start[i]);
        }
        for (const int64_t wanted : stats.call_target) {
            call_target.push_back(wanted);
        }
        last_report["build_ms"] = stats.build_ms;
        last_report["call_ms"] = call_ms;
        last_report["call_triangles"] = call_start;
        last_report["call_targets"] = call_target;
        last_report["library_error"] = stats.library_error;
        last_report["measure_ms"] = measure_ms;
    }

    // Must hold: a closed body gets no open edges; adaptive keeps it manifold too.
    if (before.closed && after.boundary_edges > 0) {
        return broken("boundary", std::string("Reduce opened ") + mesh::counted(uint64_t(after.boundary_edges), "edge", "edges") + " of a closed body." +
                                      (opt.adaptive ? " Please report it (internal error)." : " Use the Adaptive method."));
    }
    checks["boundary"] = "ok";
    if (opt.adaptive && after.non_manifold_edges > before.non_manifold_edges) {
        return broken("non_manifold", "Reduce made " + mesh::with_commas(uint64_t(after.non_manifold_edges - before.non_manifold_edges)) +
                                          " edges that more than two triangles share (internal error). Please report it.");
    }
    if (!opt.adaptive && after.non_manifold_edges > before.non_manifold_edges) {
        const std::string text = "Fast left " + mesh::counted(uint64_t(after.non_manifold_edges - before.non_manifold_edges), "edge shared by more than two triangles. Stitch and Remove can fix it, or use Adaptive.",
                                                              "edges shared by more than two triangles. Stitch and Remove can fix them, or use Adaptive.");
        checks["non_manifold"] = String("warn: ") + mesh::op_text(text);
        warnings.push_back(mesh::op_text(text));
    }
    if (!opt.adaptive) {
        // ... and corners where surfaces only touch (the library does not keep a mesh manifold).
        const size_t touching_after = mesh::non_manifold_vertex_count(out->get_state());
        last_report["touching_corners_before"] = int64_t(touching_before);
        last_report["touching_corners_after"] = int64_t(touching_after);
        if (touching_after > touching_before) {
            const std::string text = "Fast left " + mesh::counted(uint64_t(touching_after - touching_before), "corner where surfaces only touch (the mesh is not manifold there). Stitch and Remove can fix it, or use Adaptive.",
                                                                  "corners where surfaces only touch (the mesh is not manifold there). Stitch and Remove can fix them, or use Adaptive.");
            checks["touching_corners"] = String("warn: ") + mesh::op_text(text);
            warnings.push_back(mesh::op_text(text));
        }
        else {
            checks["touching_corners"] = "ok";
        }
    }
    // Must hold: the group count with Keep Face Group Borders.
    if (opt.keep_groups && after.groups != before.groups) {
        return broken("groups", "Reduce lost " + mesh::counted(uint64_t(std::llabs(before.groups - after.groups)), "face group though its borders were", "face groups though their borders were") +
                                    " to be kept. Keep more triangles" + (opt.adaptive ? "." : ", or use the Adaptive method."));
    }
    checks["groups"] = "ok";
    if (opt.keep_groups && !opt.adaptive) {
        // A check on our own lock array: the borders must be where they were.
        const double border_after = mesh::group_border_length(out->get_state());
        last_report["border_length_before"] = border_before;
        last_report["border_length_after"] = border_after;
        if (std::fabs(border_after - border_before) > 0.01 * std::max(border_before, 1e-30) && border_before > 0.0) {
            return broken("borders", "Fast cannot keep face group borders on this mesh; use Adaptive.");
        }
        checks["borders"] = "ok";
    }
    if (opt.keep_groups) {
        // Where the borders are, both ways (0 when they are the input's own edges).
        const double moved = mesh::group_border_deviation(reference, out->get_state());
        last_report["border_deviation"] = moved;
        if (moved > 1e-6 * D) {
            const std::string text = "Face group borders moved by up to " + mesh::length_text(moved) + "." + (opt.adaptive ? "" : " Use the Adaptive method.");
            checks["border_deviation"] = String("warn: ") + mesh::op_text(text);
            warnings.push_back(mesh::op_text(text));
        }
        else {
            checks["border_deviation"] = "ok";
        }
    }
    // The deviation, both ways.
    if (!measured && !measure(out->get_state())) {
        const std::string text = "The deviation could not be measured in the time left.";
        if (opt.target == 2) {
            return broken("deviation", mesh::timed_out_text("Reduce", limit, hint));
        }
        checks["deviation"] = String("warn: ") + mesh::op_text(text);
        warnings.push_back(mesh::op_text(text));
    }
    else {
        Dictionary deviation;
        deviation["max"] = std::max(forward.max, backward.max);
        deviation["mean"] = 0.5 * (forward.mean + backward.mean);
        deviation["samples"] = forward.samples + backward.samples;
        deviation["result_to_input"] = forward.max;
        deviation["input_to_result"] = backward.max;
        deviation["sampled_only"] = sampled_only;
        last_report["deviation"] = deviation;
        const double worst = std::max(forward.max, backward.max);
        if (sampled_only) {
            const std::string text = "The deviation was measured at " + mesh::with_commas(uint64_t(forward.samples + backward.samples)) + " sample points only (" +
                                     (lattice_skipped ? "measuring at every changed triangle would take about " + mesh::number_text(lattice_seconds, "%.2g") + " s more" : std::string("no time was left to measure at every changed triangle")) +
                                     "), so the " + mesh::length_text(worst) + " reported may be under the true one.";
            checks["deviation_measure"] = String("warn: ") + mesh::op_text(text);
            warnings.push_back(mesh::op_text(text));
        }
        if (opt.target == 2 && worst > opt.tolerance) {
            return broken("deviation", "Reduce moved the surface by " + mesh::length_text(worst) + " (limit " + mesh::length_text(opt.tolerance) + "). " +
                                           (opt.adaptive ? "Raise the Maximum Deviation, or reduce by proportion." : "Use the Adaptive method."));
        }
        if (opt.target != 2 && worst > 0.02 * D) {
            // No tolerance was asked for, but a move this large is said (a few triangles cannot
            // hold a shape: a 12-triangle cube reduced to 8 loses a third of its volume).
            const std::string text = "Reduce moved the surface by up to " + mesh::length_text(worst) + " (" + mesh::number_text(100.0 * worst / D, "%.3g") + " % of the body's size). Keep more triangles.";
            checks["deviation"] = String("warn: ") + mesh::op_text(text);
            warnings.push_back(mesh::op_text(text));
        }
        else {
            checks["deviation"] = "ok";
        }
    }
    // The volume of a closed body: said above 5 % (a Maximum Deviation over the body's thickness
    // lets its sides meet: a closed plate 0.2 mm thick lost two thirds of its volume within 1 mm).
    if (before.closed && after.boundary_edges == 0 && before.volume != 0.0) {
        const double volume_after = mesh::measures_of(out->get_state()).volume;
        const double change = (volume_after - before.volume) / std::fabs(before.volume);
        last_report["volume_change"] = change;
        if (std::fabs(change) > 0.05) {
            const Dictionary deviation = last_report.get("deviation", Dictionary());
            const double moved = double(deviation.get("max", -1.0));
            const std::string text = std::string("Reduce changed the volume by ") + (change < 0.0 ? "-" : "+") + mesh::number_text(100.0 * std::fabs(change), "%.3g") + " %" +
                                     (moved >= 0.0 ? " (the surface moved by up to " + mesh::length_text(moved) + ")" : std::string()) + ". " +
                                     (opt.target == 2 ? (opt.adaptive ? "Lower the Maximum Deviation." : "Lower the Maximum Deviation, or use the Adaptive method.") : "Keep more triangles.");
            checks["volume"] = String("warn: ") + mesh::op_text(text);
            warnings.push_back(mesh::op_text(text));
        }
        else {
            checks["volume"] = "ok";
        }
    }
    // The count.
    if (opt.target != 2) {
        if (double(got) > double(target) * 1.02) {
            const std::string text = "Reduce kept " + mesh::with_commas(got) + " triangles (" + mesh::number_text(100.0 * double(got) / double(T), "%.3g") + " %) instead of " +
                                     mesh::with_commas(target) + ": open edges, group borders and sharp edges limit it.";
            checks["count"] = String("warn: ") + mesh::op_text(text);
            warnings.push_back(mesh::op_text(text));
        }
        else if (double(got) < double(target) * 0.98) {
            const std::string text = "Reduce went down to " + mesh::with_commas(got) + " triangles, below the " + mesh::with_commas(target) + " asked for.";
            checks["count"] = String("warn: ") + mesh::op_text(text);
            warnings.push_back(mesh::op_text(text));
        }
        else {
            checks["count"] = "ok";
        }
    }
    else if (got == T) {
        const std::string text = "Nothing could be taken out within the Maximum Deviation of " + mesh::length_text(opt.tolerance) + ".";
        checks["count"] = String("warn: ") + mesh::op_text(text);
        warnings.push_back(mesh::op_text(text));
    }
    mesh::note_untested_crossings("Reduce", last_report, checks, warnings);
    last_report["ms"] = mesh::op_now_ms() - started;  // with the checks above
    last_report["checks"] = checks;
    last_warning = String("\n").join(warnings);
    return out;
}

}  // namespace holo_forge
