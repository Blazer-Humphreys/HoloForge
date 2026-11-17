// Smooth (work order 3.3.7). A whole body without locks goes through pmp's implicit smoothing,
// one pass a call so the time limit is checked between passes; a selection, Keep Sharp Edges
// or free open edges go through our own Laplacian with locked vertices.

#include "cad_mesh.h"
#include "mesh_pmp.h"

#include <godot_cpp/variant/packed_float64_array.hpp>

#include <pmp/algorithms/smoothing.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <exception>

using namespace godot;

namespace holo_forge
{

namespace mesh
{
namespace
{
const char* kSmoothHint = "Lower Passes, smooth a selection, or Reduce the body first.";

struct SmoothOptions
{
    double strength = 0.5;
    int iterations = 5;
    bool keep_volume = true;
    bool keep_sharp = false;
    double sharp_angle = 45.0;
    bool keep_boundary = true;
    bool selection = false;
    std::vector<uint32_t> triangles;
};

struct SmoothStats
{
    bool used_library = false;
    bool volume_kept = false;       // Keep Volume was applied
    bool volume_skipped = false;    // asked for, but open edges are free to move
    size_t free_vertices = 0;
    size_t locked_vertices = 0;
    int passes = 0;
    bool nothing_free = false;
    bool fell_back = false;         // pmp's solve failed: our own Laplacian did the work
    bool step_too_long = false;     // ... because one pass took more than half of a shell's volume away
    size_t closed_shells = 0;       // closed pieces whose volume Keep Volume held
    double worst_shell_change = 0.0;  // the largest |volume change| / |volume| among them
    double build_ms = 0.0;
    std::vector<double> pass_ms;
};

/// Signed volume sum of the triangles about `origin`, on double positions.
double signed_volume(const std::vector<double>& x, const std::vector<uint32_t>& tris, const V3& origin)
{
    double sum = 0.0;
    for (size_t t = 0; t + 2 < tris.size(); t += 3) {
        const V3 a = V3(&x[size_t(tris[t]) * 3]) - origin, b = V3(&x[size_t(tris[t + 1]) * 3]) - origin, c = V3(&x[size_t(tris[t + 2]) * 3]) - origin;
        sum += dot(a, cross(b, c));
    }
    return sum / 6.0;
}

/// A piece of the mesh joined by shared vertices. Keep Volume holds each one's own volume: a
/// void inside a body is a shell of its own, and the body's total says nothing about it (the
/// void may close up while the outside grows by as much).
struct Shell
{
    std::vector<uint32_t> tris;      // its triangles' corners, three a triangle
    std::vector<uint32_t> vertices;
    bool closed = true;              // no open edge
    double volume0 = 0.0;            // signed, about the measures' origin, before the op
};

std::vector<Shell> shells_of(const MeshData& m, const std::vector<uint8_t>& on_boundary)
{
    const size_t V = m.vertex_count(), T = m.triangle_count();
    std::vector<uint32_t> parent(V);
    for (size_t v = 0; v < V; ++v) {
        parent[v] = uint32_t(v);
    }
    auto find = [&](uint32_t v) {
        while (parent[v] != v) {
            parent[v] = parent[parent[v]];
            v = parent[v];
        }
        return v;
    };
    for (size_t t = 0; t < T; ++t) {
        const uint32_t a = find(m.triangles[t * 3]);
        for (int k = 1; k < 3; ++k) {
            const uint32_t b = find(m.triangles[t * 3 + size_t(k)]);
            if (a != b) {
                parent[b] = a;
            }
        }
    }
    std::vector<uint32_t> shell_of(V, NONE);
    std::vector<Shell> shells;
    for (size_t t = 0; t < T; ++t) {
        const uint32_t root = find(m.triangles[t * 3]);
        if (shell_of[root] == NONE) {
            shell_of[root] = uint32_t(shells.size());
            shells.emplace_back();
        }
        Shell& shell = shells[shell_of[root]];
        shell.tris.insert(shell.tris.end(), &m.triangles[t * 3], &m.triangles[t * 3] + 3);
    }
    for (size_t v = 0; v < V; ++v) {
        const uint32_t index = shell_of[find(uint32_t(v))];
        if (index != NONE) {
            shells[index].vertices.push_back(uint32_t(v));
            shells[index].closed = shells[index].closed && !on_boundary[v];
        }
    }
    return shells;
}

double area_of(const std::vector<double>& x, const std::vector<uint32_t>& tris)
{
    double sum = 0.0;
    for (size_t t = 0; t + 2 < tris.size(); t += 3) {
        const V3 a(&x[size_t(tris[t]) * 3]), b(&x[size_t(tris[t + 1]) * 3]), c(&x[size_t(tris[t + 2]) * 3]);
        sum += length(cross(b - a, c - a));
    }
    return sum * 0.5;
}

/// Moves the free vertices of a shell along their normals by one common distance, so that its
/// signed volume is its `volume0` again (work order 3.3.7: one number, solved in closed form;
/// done again, up to 8 times, for the part a first-order step leaves, which is large on a coarse
/// mesh). `normal` is scratch, one entry a vertex of the mesh.
void restore_volume(std::vector<double>& x, const Shell& shell, const std::vector<uint8_t>& free, const V3& origin, std::vector<V3>& normal)
{
    const std::vector<uint32_t>& tris = shell.tris;
    const double target = shell.volume0;
    for (int round = 0; round < 8; ++round) {
        const double missing = target - signed_volume(x, tris, origin);
        if (std::fabs(missing) <= 1e-10 * std::fabs(target)) {
            return;
        }
        for (const uint32_t v : shell.vertices) {
            normal[v] = V3();
        }
        for (size_t t = 0; t + 2 < tris.size(); t += 3) {
            const V3 a(&x[size_t(tris[t]) * 3]), b(&x[size_t(tris[t + 1]) * 3]), c(&x[size_t(tris[t + 2]) * 3]);
            const V3 n = cross(b - a, c - a) * 0.5;
            normal[tris[t]] += n;
            normal[tris[t + 1]] += n;
            normal[tris[t + 2]] += n;
        }
        // dV = d x the sum of |N_i| / 3 over the free vertices.
        double gain = 0.0;
        for (const uint32_t v : shell.vertices) {
            if (free[v]) {
                gain += length(normal[v]) / 3.0;
            }
        }
        if (!(gain > 0.0)) {
            return;
        }
        const double d = missing / gain;
        if (!std::isfinite(d) || d == 0.0) {
            return;
        }
        for (const uint32_t v : shell.vertices) {
            if (free[v]) {
                const V3 n = normalized(normal[v]);
                x[size_t(v) * 3] += n.x * d;
                x[size_t(v) * 3 + 1] += n.y * d;
                x[size_t(v) * 3 + 2] += n.z * d;
            }
        }
    }
}

/// Scales a closed shell about its own centroid so that its volume is its `volume0` again.
void rescale_shell(std::vector<double>& x, const Shell& shell, const V3& origin)
{
    V3 centre;
    double weight = 0.0;
    for (size_t t = 0; t + 2 < shell.tris.size(); t += 3) {
        const V3 a = V3(&x[size_t(shell.tris[t]) * 3]) - origin, b = V3(&x[size_t(shell.tris[t + 1]) * 3]) - origin, c = V3(&x[size_t(shell.tris[t + 2]) * 3]) - origin;
        const double det = dot(a, cross(b, c));
        centre += (a + b + c) * (det / 24.0);
        weight += det / 6.0;
    }
    if (weight == 0.0 || !(shell.volume0 / weight > 0.0)) {
        return;
    }
    const double scale = std::cbrt(shell.volume0 / weight);
    centre = origin + centre * (1.0 / weight);
    for (const uint32_t v : shell.vertices) {
        for (int k = 0; k < 3; ++k) {
            x[size_t(v) * 3 + size_t(k)] = centre[k] + (x[size_t(v) * 3 + size_t(k)] - centre[k]) * scale;
        }
    }
}

bool smooth(State& state, const SmoothOptions& opt, const Deadline& deadline, MeshData& out, SmoothStats& stats, std::string& error)
{
    const MeshData& m = state.data;
    const size_t T = m.triangle_count(), V = m.vertex_count();
    const Topology* topo = topology_of(state, &deadline);
    if (topo == nullptr) {
        error = timed_out_text("Smooth", deadline.limit(), kSmoothHint);
        return false;
    }
    const Measures& ms = measures_of(state);
    const V3 origin(ms.origin);
    const bool closed = is_closed(state);
    std::vector<double> x(m.positions.begin(), m.positions.end());
    const std::vector<uint8_t> on_boundary = boundary_vertices(state);
    std::vector<Shell> shells;
    std::vector<V3> scratch;
    // (Made when first needed, after the refusals at the start: it is work by the triangle,
    // and a refusal must cost nothing. Called while x still holds the input.)
    auto make_shells = [&]() {
        if (!shells.empty()) {
            return;
        }
        shells = shells_of(m, on_boundary);
        for (Shell& shell : shells) {
            shell.volume0 = signed_volume(x, shell.tris, origin);
        }
        scratch.resize(V);
    };
    const double tiny_volume = 1e-9 * ms.diagonal * ms.diagonal * ms.diagonal;

    stats.used_library = !opt.selection && !opt.keep_sharp && (closed || opt.keep_boundary);
    std::vector<uint8_t> free(V, 0);
    if (stats.used_library) {
        // --- pmp: (M - t L) X = M X once a call. Open edges stay where they are.
        const std::string refusal = pmp_refusal(state);
        if (!refusal.empty()) {
            error = refusal;
            return false;
        }
        const double pass = budget::estimate(budget::PMP_IMPLICIT_SMOOTHING_PASS, double(T));
        const double whole = budget::estimate(budget::PMP_SURFACE_MESH_BUILD, double(T)) + pass * opt.iterations + post_check_estimate(double(T), true);
        if (whole > deadline.limit()) {
            error = too_slow_text("Smooth", whole, deadline.limit(), kSmoothHint);
            return false;
        }
        pmp::SurfaceMesh pm;
        std::vector<uint32_t> vertex_of;
        const double build_started = op_now_ms();
        const std::string problem = build_pmp(m, nullptr, pm, vertex_of);
        stats.build_ms = op_now_ms() - build_started;
        if (!problem.empty()) {
            error = problem;
            return false;
        }
        for (const uint32_t v : vertex_of) {
            free[v] = on_boundary[v] ? 0 : 1;
        }
        make_shells();
        std::vector<double> shell_volume(shells.size());
        for (size_t i = 0; i < shells.size(); ++i) {
            shell_volume[i] = shells[i].volume0;
        }
        const double edge = mean_edge_length(state);
        const float timestep = float(opt.strength * edge * edge);
        for (int i = 0; i < opt.iterations; ++i) {
            // A pass cannot be stopped: it is not started when it would end after the limit.
            if (deadline.elapsed() + pass > deadline.limit() && i > 0) {
                error = stopped_text("Smooth", deadline.elapsed(), deadline.elapsed() + pass * (opt.iterations - i) + post_check_estimate(double(T), true), deadline.limit(), kSmoothHint);
                return false;
            }
            const double pass_started = op_now_ms();
            const double area_before = area_of(x, m.triangles);
            // pmp's solve fails on meshes with very thin or lopsided triangles (its matrix is
            // then not positive definite: a 12-triangle cube is enough). Then our own Laplacian
            // below does the job, from the input again.
            try {
                pmp::implicit_smoothing(pm, timestep, 1, false, false);
                stats.pass_ms.push_back(op_now_ms() - pass_started);
            }
            catch (const std::exception&) {
                stats.fell_back = true;
            }
            catch (...) {
                stats.fell_back = true;
            }
            for (size_t k = 0; k < vertex_of.size() && !stats.fell_back; ++k) {
                const pmp::Point& p = pm.position(pmp::Vertex(pmp::IndexType(k)));
                if (!std::isfinite(p[0]) || !std::isfinite(p[1]) || !std::isfinite(p[2])) {
                    stats.fell_back = true;
                }
            }
            if (stats.fell_back) {
                break;
            }
            for (size_t k = 0; k < vertex_of.size(); ++k) {
                const pmp::Point& p = pm.position(pmp::Vertex(pmp::IndexType(k)));
                if (free[vertex_of[k]]) {
                    x[size_t(vertex_of[k]) * 3] = p[0];
                    x[size_t(vertex_of[k]) * 3 + 1] = p[1];
                    x[size_t(vertex_of[k]) * 3 + 2] = p[2];
                }
            }
            // Smoothing takes area away. A pass that adds area is the solve gone wrong without
            // saying so (its matrix is indefinite on triangles with wide angles: the surface
            // then runs off by many times the body's size). Our own Laplacian takes over.
            if (area_of(x, m.triangles) > area_before * 1.001) {
                stats.fell_back = true;
                break;
            }
            // Nor is a pass that takes more than half of a closed shell's volume away: the step
            // is then too long for this mesh (a few long triangles: one pass reaches across the
            // whole body and draws it together; Keep Volume would only blow the rest up again.
            // Measured on an L-bracket of 78 mm: 130 mm of movement). Our own Laplacian, which
            // moves a vertex no further than its neighbours, takes over.
            bool collapsed = false;
            for (size_t i = 0; i < shells.size() && !collapsed; ++i) {
                if (!shells[i].closed || !(std::fabs(shells[i].volume0) > tiny_volume)) {
                    continue;
                }
                const double now = signed_volume(x, shells[i].tris, origin);
                collapsed = !(now / (opt.keep_volume ? shells[i].volume0 : shell_volume[i]) > 0.5);
                shell_volume[i] = now;
            }
            if (collapsed) {
                stats.fell_back = true;
                stats.step_too_long = true;
                break;
            }
            if (opt.keep_volume) {
                // Shell by shell: a closed one is scaled about its own centroid by
                // (V0 / V) ^ (1/3); one with (kept) open edges moves along its normals.
                for (const Shell& shell : shells) {
                    if (shell.closed) {
                        rescale_shell(x, shell, origin);
                    }
                    else {
                        restore_volume(x, shell, free, origin, scratch);
                    }
                }
                stats.volume_kept = true;
                // The next pass starts from the corrected positions.
                for (size_t k = 0; k < vertex_of.size(); ++k) {
                    const double* p = &x[size_t(vertex_of[k]) * 3];
                    pm.position(pmp::Vertex(pmp::IndexType(k))) = pmp::Point(float(p[0]), float(p[1]), float(p[2]));
                }
            }
            ++stats.passes;
        }
        (void)closed;
        if (stats.fell_back) {
            stats.used_library = false;
            stats.passes = 0;
            stats.volume_kept = false;
            stats.pass_ms.clear();
            x.assign(m.positions.begin(), m.positions.end());
            std::fill(free.begin(), free.end(), uint8_t(0));
        }
    }
    if (!stats.used_library) {
        // --- Our own Laplacian with locks.
        std::vector<uint8_t> selected;
        if (opt.selection) {
            selected.assign(T, 0);
            for (const uint32_t t : opt.triangles) {
                selected[t] = 1;
            }
        }
        std::vector<uint8_t> used(V, 0);
        for (size_t t = 0; t < T; ++t) {
            const uint32_t* tri = &m.triangles[t * 3];
            for (int k = 0; k < 3; ++k) {
                // 1: only selected triangles so far; 2: an unselected one touches it.
                const uint8_t mark = (!opt.selection || selected[t]) ? 1 : 2;
                used[tri[k]] = std::max(used[tri[k]], mark);
            }
        }
        bool free_boundary = false;
        for (size_t v = 0; v < V; ++v) {
            free[v] = used[v] == 1 ? 1 : 0;
            if (free[v] && on_boundary[v]) {
                if (opt.keep_boundary) {
                    free[v] = 0;
                }
                else {
                    free_boundary = true;
                }
            }
        }
        const double sharp = std::cos(opt.sharp_angle * M_PI / 180.0);
        for (size_t e = 0; e < topo->edge_count(); ++e) {
            const uint32_t first = topo->edge_first[e], uses = topo->uses(uint32_t(e));
            const uint32_t h0 = topo->edge_hes[first];
            bool lock = uses > 2;
            if (!lock && uses == 2 && opt.keep_sharp) {
                const uint32_t h1 = topo->edge_hes[first + 1];
                const V3 n0 = normalized(triangle_cross(m, h0 / 3)), n1 = normalized(triangle_cross(m, h1 / 3));
                const double sign = m.triangles[h0] == m.triangles[h1] ? -1.0 : 1.0;
                lock = sign * dot(n0, n1) < sharp;
            }
            if (lock) {
                free[m.triangles[h0]] = 0;
                free[m.triangles[h0 - h0 % 3 + (h0 + 1) % 3]] = 0;
            }
        }
        // The triangles that hold a free vertex.
        std::vector<uint32_t> active;
        for (size_t t = 0; t < T; ++t) {
            const uint32_t* tri = &m.triangles[t * 3];
            if (tri[0] != tri[1] && tri[1] != tri[2] && tri[0] != tri[2] && (free[tri[0]] || free[tri[1]] || free[tri[2]])) {
                active.push_back(uint32_t(t));
            }
        }
        for (size_t v = 0; v < V; ++v) {
            stats.free_vertices += free[v];
        }
        if (stats.free_vertices == 0) {
            stats.nothing_free = true;
            out = m;
            return true;
        }
        const double whole = opt.iterations * budget::estimate(budget::LAPLACIAN_PASS, double(active.size())) + post_check_estimate(double(T), true);
        if (whole > deadline.limit()) {
            error = too_slow_text("Smooth", whole, deadline.limit(), kSmoothHint);
            return false;
        }
        // (The volume a surface encloses means something only when no open edge moves and all
        // triangles face one way.)
        const bool keep_volume = opt.keep_volume && !free_boundary && topo->inconsistent_edges == 0;
        stats.volume_skipped = opt.keep_volume && !keep_volume;
        if (keep_volume) {
            make_shells();
        }
        const double step = opt.strength * 0.5;
        std::vector<double> weight(V), target(V * 3);
        for (int i = 0; i < opt.iterations; ++i) {
            const double pass_started = op_now_ms();
            std::fill(weight.begin(), weight.end(), 0.0);
            std::fill(target.begin(), target.end(), 0.0);
            for (const uint32_t t : active) {
                const uint32_t* tri = &m.triangles[size_t(t) * 3];
                const V3 p[3] = {V3(&x[size_t(tri[0]) * 3]), V3(&x[size_t(tri[1]) * 3]), V3(&x[size_t(tri[2]) * 3])};
                for (int k = 0; k < 3; ++k) {
                    // The angle at corner k weighs the edge across from it (cotangent, never negative).
                    const V3 u = p[(k + 1) % 3] - p[k], w = p[(k + 2) % 3] - p[k];
                    const double s = length(cross(u, w));
                    const double cot = s > 0.0 ? std::min(std::max(dot(u, w) / s, 0.0), 1e3) : 0.0;
                    const uint32_t a = tri[(k + 1) % 3], b = tri[(k + 2) % 3];
                    weight[a] += cot;
                    weight[b] += cot;
                    for (int c = 0; c < 3; ++c) {
                        target[size_t(a) * 3 + size_t(c)] += cot * p[(k + 2) % 3][c];
                        target[size_t(b) * 3 + size_t(c)] += cot * p[(k + 1) % 3][c];
                    }
                }
                if (deadline.tick()) {
                    error = timed_out_text("Smooth", deadline.limit(), kSmoothHint);
                    return false;
                }
            }
            for (size_t v = 0; v < V; ++v) {
                if (free[v] && weight[v] > 0.0) {
                    for (int c = 0; c < 3; ++c) {
                        const double goal = target[v * 3 + size_t(c)] / weight[v];
                        x[v * 3 + size_t(c)] += step * (goal - x[v * 3 + size_t(c)]);
                    }
                }
            }
            if (keep_volume) {
                for (const Shell& shell : shells) {
                    restore_volume(x, shell, free, origin, scratch);
                }
                stats.volume_kept = true;
            }
            stats.pass_ms.push_back(op_now_ms() - pass_started);
            ++stats.passes;
            if (deadline.expired()) {
                error = timed_out_text("Smooth", deadline.limit(), kSmoothHint);
                return false;
            }
        }
    }
    out = m;
    for (size_t v = 0; v < V; ++v) {
        if (!free[v]) {
            continue;  // locked: bit for bit as it was
        }
        for (int k = 0; k < 3; ++k) {
            out.positions[v * 3 + size_t(k)] = float(x[v * 3 + size_t(k)]);
        }
    }
    stats.free_vertices = 0;
    for (size_t v = 0; v < V; ++v) {
        stats.free_vertices += free[v];
    }
    stats.locked_vertices = V - stats.free_vertices;
    if (stats.volume_kept) {
        // What Keep Volume held, on the positions as they are stored: every closed shell.
        const std::vector<double> y(out.positions.begin(), out.positions.end());
        for (const Shell& shell : shells) {
            if (!shell.closed || !(std::fabs(shell.volume0) > tiny_volume)) {
                continue;
            }
            ++stats.closed_shells;
            stats.worst_shell_change = std::max(stats.worst_shell_change, std::fabs(signed_volume(y, shell.tris, origin) - shell.volume0) / std::fabs(shell.volume0));
        }
    }
    return true;
}

}  // namespace
}  // namespace mesh

Ref<CadMesh> CadMesh::smooth(const Dictionary& options)
{
    clear_messages();
    const double started = mesh::op_now_ms();
    if (is_null()) {
        fail("There is no mesh to smooth.");
        return Ref<CadMesh>();
    }
    const mesh::MeshData& m = state->data;
    const size_t T = m.triangle_count();
    mesh::OptionReader reader(options);
    mesh::SmoothOptions opt;
    opt.strength = reader.number("strength", "Smoothness", 0.5, 0.0, 1.0);
    opt.iterations = int(reader.integer("iterations", "Passes", 5, 1, 50));
    opt.keep_volume = reader.flag("keep_volume", "Keep Volume", true);
    opt.keep_sharp = reader.flag("keep_sharp", "Keep Sharp Edges", false);
    opt.sharp_angle = reader.number("sharp_angle", "Sharp Edge Angle", 45.0, 10.0, 170.0, "deg");
    opt.keep_boundary = reader.flag("keep_boundary", "Keep Open Edges", true);
    opt.triangles = reader.triangles("triangles", T, &opt.selection);
    const double limit = reader.time_limit();
    if (!reader.ok()) {
        fail(reader.error());
        return Ref<CadMesh>();
    }
    if (opt.selection && opt.triangles.empty()) {
        fail("Select the triangles to smooth, or smooth the whole body.");
        return Ref<CadMesh>();
    }
    if (opt.selection && opt.triangles.size() == T) {
        opt.selection = false;
    }
    {
        // Far from the origin positions step by more than a share of an edge: the result would
        // be made of rounding (triangles without area, a volume change that is only noise).
        const double edge = mesh::typical_edge(*state);
        const std::string far = mesh::far_refusal(*state, options, edge, "too coarse to smooth edges of " + mesh::length_text(edge));
        if (!far.empty()) {
            fail(far);
            return Ref<CadMesh>();
        }
    }
    const mesh::Deadline deadline(limit);
    mesh::MeshData data;
    mesh::SmoothStats stats;
    std::string error;
    bool ok = false;
    try {
        ok = mesh::smooth(*state, opt, deadline, data, stats, error);
    }
    catch (const std::exception& e) {
        error = mesh::library_error("Smooth", e.what());
    }
    catch (...) {
        error = mesh::library_error("Smooth", nullptr);
    }
    if (!ok) {
        fail(error);
        return Ref<CadMesh>();
    }
    if (stats.nothing_free) {
        // Nothing may move: the mesh as it is, with a warning.
        last_warning = opt.selection ? "The selection is too small to smooth; grow it." : "Nothing can move: every vertex lies on a sharp or an open edge that is kept.";
        last_report["op"] = "smooth";
        last_report["ms"] = mesh::op_now_ms() - started;
        last_report["free_vertices"] = int64_t(0);
        return Ref<CadMesh>(this);
    }
    const bool was_closed = mesh::is_closed(*state);
    const double volume_before = mesh::measures_of(*state).volume;
    const double area_before = mesh::measures_of(*state).area;
    const double diagonal = mesh::measures_of(*state).diagonal;
    Ref<CadMesh> out = finish_op("Smooth", "smooth", std::move(data), started, true);
    if (out.is_null()) {
        return out;
    }
    Dictionary checks = last_report.get("checks", Dictionary());
    PackedStringArray warnings;
    if (!last_warning.is_empty()) {
        warnings = last_warning.split("\n");
    }
    const mesh::MeshData& r = out->data();
    last_report["method"] = stats.used_library ? "implicit" : "laplacian";
    last_report["passes"] = int64_t(stats.passes);
    last_report["free_vertices"] = int64_t(stats.free_vertices);
    last_report["locked_vertices"] = int64_t(stats.locked_vertices);
    {
        PackedFloat64Array pass_ms;
        for (const double ms : stats.pass_ms) {
            pass_ms.push_back(ms);
        }
        last_report["build_ms"] = stats.build_ms;
        last_report["pass_ms"] = pass_ms;
    }
    auto broken = [&](const char* key, const std::string& text) {
        checks[key] = String("fail: ") + mesh::op_text(text);
        last_report["checks"] = checks;
        fail(text);
        return Ref<CadMesh>();
    };
    // Must hold: the triangles and their order are the input's.
    if (r.triangle_count() != T || r.vertex_count() > m.vertex_count()) {
        return broken("connectivity", "Smooth changed the triangles (internal error). Please report it.");
    }
    checks["connectivity"] = "ok";
    // Triangles turned over (a fold between neighbours, which the crossing test cannot see), and
    // the largest move.
    int64_t turned = 0;
    double largest = 0.0;
    for (size_t t = 0; t < T; ++t) {
        const mesh::V3 before = mesh::triangle_cross(m, t), after = mesh::triangle_cross(r, t);
        if (mesh::dot(before, after) < 0.0) {
            ++turned;
        }
        for (int k = 0; k < 3; ++k) {
            largest = std::max(largest, mesh::length(mesh::point_of(m, m.triangles[t * 3 + size_t(k)]) - mesh::point_of(r, r.triangles[t * 3 + size_t(k)])));
        }
    }
    last_report["max_move"] = largest;
    last_report["turned_triangles"] = turned;
    if (turned > 0) {
        const std::string text = "Smooth turned " + mesh::counted(uint64_t(turned), "triangle", "triangles") + " over (the surface folds there). Lower the Smoothness or Passes.";
        checks["folds"] = String("warn: ") + mesh::op_text(text);
        warnings.push_back(mesh::op_text(text));
    }
    else {
        checks["folds"] = "ok";
    }
    // How far the surface went. (A vertex's move bounds the surface's.) Said above 2 % of the
    // body's size, as Reduce does: Smooth on a coarse or a CAD-like mesh rounds the whole shape.
    {
        const double area_after = mesh::measures_of(out->get_state()).area;
        last_report["area_change"] = area_before > 0.0 ? (area_after - area_before) / area_before : 0.0;
    }
    if (largest > 0.5 * diagonal) {
        // (Not a smoothed body any more: on a mesh of a few long triangles one pass reaches
        // across the whole body, and Keep Volume then blows the rest up again. Measured on an
        // L-bracket: 130 mm on a body of 78 mm.)
        return broken("move", "Smooth would move the surface by up to " + mesh::length_text(largest) + " (" + mesh::number_text(100.0 * largest / diagonal, "%.0f") +
                                  " % of the body's size): the mesh is too coarse for this much smoothing. Lower the Smoothness or Passes, or Remesh the body first.");
    }
    if (largest > 0.02 * diagonal) {
        const std::string text = "Smooth moved the surface by up to " + mesh::length_text(largest) + " (" + mesh::number_text(100.0 * largest / diagonal, "%.3g") +
                                 " % of the body's size). Lower the Smoothness or Passes.";
        checks["move"] = String("warn: ") + mesh::op_text(text);
        warnings.push_back(mesh::op_text(text));
    }
    else {
        checks["move"] = "ok";
    }
    // Must hold: the volume of every closed shell within 0.5 % with Keep Volume. (The body's
    // total is reported, signed: negative when it shrank.)
    if (was_closed) {
        const double volume_after = mesh::measures_of(out->get_state()).volume;
        last_report["volume_change"] = volume_before != 0.0 ? (volume_after - volume_before) / std::fabs(volume_before) : 0.0;
    }
    if (opt.keep_volume && stats.volume_kept) {
        last_report["closed_shells"] = int64_t(stats.closed_shells);
        last_report["shell_volume_change"] = stats.worst_shell_change;
        if (stats.worst_shell_change > 0.005) {
            return broken("volume", "Smooth changed the volume" + std::string(stats.closed_shells > 1 ? " of one of the body's " + mesh::with_commas(stats.closed_shells) + " closed shells" : "") + " by " +
                                        mesh::number_text(100.0 * stats.worst_shell_change, "%.3g") + " % (limit 0.5 %). Lower the Smoothness or Passes.");
        }
        checks["volume"] = "ok";
    }
    if (stats.fell_back) {
        // (The library's step is set by the body's mean edge: too long for a part with long
        // triangles for its size, or for a small part beside a large one.)
        const std::string text = stats.step_too_long
                                         ? "The mesh library's smoothing step is too long for a part of this body (one pass would take more than half of that part's volume away: its triangles "
                                           "are long for its size, or it is much smaller than the rest); the step-by-step smoothing was used instead, which smooths less a pass."
                                         : "The smoothing solve failed on this mesh (it has very thin or lopsided triangles); the step-by-step smoothing was used instead, which smooths less a pass.";
        checks["method"] = String("warn: ") + mesh::op_text(text);
        warnings.push_back(mesh::op_text(text));
    }
    if (stats.volume_skipped) {
        const std::string text = "Keep Volume was not applied: it needs a closed body or kept open edges, with all triangles facing one way.";
        checks["volume"] = String("warn: ") + mesh::op_text(text);
        warnings.push_back(mesh::op_text(text));
    }
    mesh::note_untested_crossings("Smooth", last_report, checks, warnings);
    last_report["ms"] = mesh::op_now_ms() - started;  // with the checks above
    last_report["checks"] = checks;
    last_warning = String("\n").join(warnings);
    return out;
}

}  // namespace holo_forge
