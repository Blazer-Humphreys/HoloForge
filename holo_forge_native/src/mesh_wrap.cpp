// Wrap and Rebuild (work order 3.2.3, 3.2.4): a sampled function on our own voxel grid, turned
// into a closed mesh by Manifold's LevelSet.
//   Wrap     closes gaps: the outside is what a flood from the grid's border reaches while
//            staying farther than Gap from the triangles; the surface lies Gap inside it.
//   Rebuild  remakes a closed mesh: inside is where the winding number is not 0, the function
//            is the distance to the triangles with that sign.

#include "cad_mesh.h"
#include "mesh_bvh.h"
#include "mesh_manifold.h"
#include "mesh_voxel.h"

#include <algorithm>
#include <cmath>
#include <exception>

using namespace godot;

namespace holo_forge::mesh::mf
{

manifold::Manifold level_set(manifold::ExecutionContext& ctx, const voxel::Grid& grid, const std::vector<float>& values, double& guard_below)
{
    const voxel::Field field{&grid, values.data()};
    const double h = grid.h;
    // The bounds reach four cells below the grid in x: room for the guard (see mesh_manifold.h).
    const manifold::vec3 lo(grid.origin[0] - 4.0 * h, grid.origin[1], grid.origin[2]);
    const manifold::vec3 hi(grid.top(0), grid.top(1), grid.top(2));
    // Manifold's own lattice over these bounds, by its own arithmetic (CreateLevelSet): points
    // at lo + spacing x index, and a second set half a step off. The guard is centred on the
    // first point of that second set, (0.5, 0.5, 0.5) steps from lo. Its function is 1 there,
    // -0.2 at the eight lattice points around it (half a step off on every axis) and below
    // -1/3 everywhere farther: LevelSet then makes its first surface points at those eight,
    // all of them inside the first cell, before it has looked at anything else. With those
    // made, a full table is doubled; without any, it read vertPos[-1] and sized the new table
    // from garbage.
    const manifold::vec3 dim = hi - lo;
    const double sx = dim.x / double(int(dim.x / h + 1.0) - 1), sy = dim.y / double(int(dim.y / h + 1.0) - 1), sz = dim.z / double(int(dim.z / h + 1.0) - 1);
    const double cx = lo.x + 0.5 * sx, cy = lo.y + 0.5 * sy, cz = lo.z + 0.5 * sz;
    const double from_x = grid.origin[0] - 0.5 * h;
    guard_below = grid.origin[0] - 2.0 * h;
    return ctx.LevelSet(
        [=](manifold::vec3 p) {
            if (p.x < from_x) {
                const double ux = (p.x - cx) / sx, uy = (p.y - cy) / sy, uz = (p.z - cz) / sz;
                return 1.0 - 1.386 * std::sqrt(ux * ux + uy * uy + uz * uz);
            }
            return field.at(p.x, p.y, p.z);
        },
        manifold::Box(lo, hi), h, 0.0, -1.0, false);
}

bool only_guard(const manifold::Manifold& solid, double guard_below)
{
    return solid.IsEmpty() || solid.BoundingBox().max.x < guard_below;
}

void drop_guard(Import& imported, double guard_below)
{
    MeshData& m = imported.mesh;
    const size_t T = m.triangle_count();
    size_t kept = 0;
    for (size_t t = 0; t < T; ++t) {
        bool guard = true;
        for (int k = 0; k < 3; ++k) {
            guard = guard && double(m.positions[size_t(m.triangles[t * 3 + size_t(k)]) * 3]) < guard_below;
        }
        if (guard) {
            continue;
        }
        if (kept != t) {
            for (int k = 0; k < 3; ++k) {
                m.triangles[kept * 3 + size_t(k)] = m.triangles[t * 3 + size_t(k)];
            }
            m.groups[kept] = m.groups[t];
            imported.foreign[kept] = imported.foreign[t];
            imported.run[kept] = imported.run[t];
        }
        ++kept;
    }
    m.triangles.resize(kept * 3);
    m.groups.resize(kept);
    imported.foreign.resize(kept);
    imported.run.resize(kept);
    imported.foreign_triangles = 0;
    for (const uint8_t f : imported.foreign) {
        imported.foreign_triangles += f;
    }
}

double level_set_seconds(double cells, double surface_area, double h)
{
    using namespace budget;
    // The surface comes out at about LEVEL_SET_TRIANGLES_PER_CELL_AREA triangles per h x h of it.
    const double triangles = std::min(LEVEL_SET_TRIANGLES_PER_CELL_AREA * surface_area / (h * h), 2e6);
    return cells / 1e6 * LEVEL_SET_SECONDS_PER_MILLION_CELLS + estimate(MF_EXPORT, triangles) + estimate(OP_FINISH, triangles) +
           std::min(SELF_INTERSECTION_SECONDS, estimate(BVH_BUILD, triangles) + estimate(SELF_INTERSECTIONS, triangles));
}

double voxel_seconds(double cells, double band, double h)
{
    using namespace budget;
    return cells / 1e6 * (VOXEL_SECONDS_PER_MILLION_CELLS + VOXEL_SECONDS_PER_MILLION_CELLS_PER_BAND_CELL * band / h);
}

}  // namespace holo_forge::mesh::mf

namespace holo_forge
{

namespace
{
using mesh::MeshData;

struct Plan
{
    bool rebuild = false;
    double diagonal = 0.0;
    double lo[3] = {0, 0, 0}, hi[3] = {0, 0, 0};
    double detail = 0.0, gap = 0.0, offset = 0.0;
    int method = 0;  // Rebuild: 0 union, 1 exact_surface
    double detail_default = 0.0, detail_min = 0.0, detail_max = 0.0;
    double gap_min = 0.0, gap_max = 0.0, offset_min = 0.0, offset_max = 0.0;
    double margin = 0.0;
    double cells = 0.0;
    double seconds = 0.0;
    double limit = 20.0;
    std::string name, name_start;
};

bool make_plan(mesh::State& state, mesh::ops::Options& o, Plan& plan, bool rebuild)
{
    using namespace mesh::budget;
    const char* title = rebuild ? "Rebuild" : "Wrap";
    const mesh::Measures& ms = mesh::measures_of(state);
    plan.rebuild = rebuild;
    plan.diagonal = ms.diagonal;
    plan.name = o.name(false);
    plan.name_start = o.name(true);
    plan.limit = o.time_limit();
    for (int k = 0; k < 3; ++k) {
        plan.lo[k] = ms.lo[k];
        plan.hi[k] = ms.hi[k];
    }
    const double D = ms.diagonal;
    if (!(D > 0.0)) {
        o.fail(std::string(title) + " needs a body with a size.");
        return false;
    }
    plan.detail_min = D / (rebuild ? 600.0 : 400.0);
    plan.detail_max = D / 10.0;
    const bool gap_given = !rebuild && o.has("gap");
    double gap = rebuild ? 0.0 : o.number("gap", "Close Gaps Up To", 0.0);
    plan.offset = rebuild ? 0.0 : o.number("offset", "Offset", 0.0);
    plan.method = rebuild ? o.choice("method", "Method", {"union", "exact_surface"}, 0) : 0;
    // The grid reaches margin past the bounds: the gap and an outward offset (Wrap), and 2 cells.
    const double fixed_margin = (gap_given ? gap : 0.0) + std::max(plan.offset, 0.0);
    const double margin_cells = 2.0 + (!rebuild && !gap_given ? 2.0 : 0.0);
    const double fit = mesh::voxel::fitting_cell(plan.lo, plan.hi, fixed_margin, margin_cells, double(MAX_VOXEL_SAMPLES));
    // The default cell size, raised to the smallest that fits the grid cap.
    plan.detail_default = std::min(std::max(D / (rebuild ? 250.0 : 150.0), fit), plan.detail_max);
    plan.detail = o.number("detail", "Detail", plan.detail_default);
    if (!o.ok() || !o.range("Detail", plan.detail, plan.detail_min, plan.detail_max, true)) {
        return false;
    }
    if (!rebuild) {
        plan.gap_min = plan.detail;
        plan.gap_max = D / 4.0;
        plan.gap = gap_given ? gap : std::min(2.0 * plan.detail, plan.gap_max);
        if (!o.range("Close Gaps Up To", plan.gap, plan.gap_min, plan.gap_max, true)) {
            return false;
        }
        plan.offset_min = -plan.gap;
        plan.offset_max = D / 10.0;
        if (!o.range("Offset", plan.offset, plan.offset_min, plan.offset_max, true)) {
            return false;
        }
    }
    // Far from the origin positions step by more than a share of a cell: the result would be
    // cells of rounding noise (it used to come back with thousands of triangles without area,
    // or end as an "internal error"). And a result past the limit of a mesh body: said here.
    {
        const std::string far = mesh::ops::too_far(state, plan.name_start, plan.detail / 8.0, "too coarse for a Detail of " + mesh::ops::length_text(plan.detail));
        if (!far.empty()) {
            o.fail(far);
            return false;
        }
        const std::string out = mesh::ops::past_limit(state, title, std::max(plan.offset, 0.0) + plan.detail, plan.name);
        if (!out.empty()) {
            o.fail(out);
            return false;
        }
    }
    plan.margin = plan.gap + std::max(plan.offset, 0.0) + 2.0 * plan.detail;
    plan.cells = mesh::voxel::sample_count(plan.lo, plan.hi, plan.margin, plan.detail);
    if (plan.cells > double(MAX_VOXEL_SAMPLES)) {
        o.fail(std::string(title) + " needs " + mesh::ops::plain_number(plan.cells / 1e6, 3) + " million cells; raise Detail to " + mesh::ops::length_text(fit) + ".");
        return false;
    }
    const double T = double(state.data.triangle_count());
    // (The same band the fields below use.)
    const double band = (rebuild ? 0.0 : std::max(plan.gap, plan.offset)) + 2.5 * plan.detail;
    // (The hierarchy is counted whether or not the mesh has one already: the same options must
    // give the same estimate every time.)
    plan.seconds = estimate(BVH_BUILD, T) + estimate(TOPOLOGY, T) + mesh::mf::voxel_seconds(plan.cells, band, plan.detail) +
                   mesh::mf::level_set_seconds(plan.cells, ms.area, plan.detail) + COVERAGE_SECONDS;
    if (rebuild && plan.method == 1) {
        plan.seconds += estimate(NEAREST_PER_VERTEX, std::min(2.0 * LEVEL_SET_TRIANGLES_PER_CELL_AREA * ms.area / (plan.detail * plan.detail), 2e6));
    }
    return true;
}

/// Wrap's function on the grid: positive inside the wrap.
bool wrap_field(const mesh::TriBvh& bvh, const mesh::voxel::Grid& grid, const Plan& plan, std::vector<float>& f, const mesh::Deadline& deadline, mesh::ops::Phases& phases)
{
    const double R = plan.gap, h = grid.h;
    // The distance has to be right up to the gap (and an outward offset) plus the cells the
    // surface is read from.
    const double band = std::max(R, plan.offset) + 2.5 * h;
    std::vector<float> d;
    if (!mesh::voxel::distance_field(bvh, grid, band, d, deadline)) {
        return false;
    }
    phases.mark("distance_field");
    std::vector<uint8_t> outside;
    if (!mesh::voxel::flood_from_border(grid, d, float(R), outside, deadline)) {
        return false;
    }
    phases.mark("flood");
    std::vector<int32_t> source;
    if (!mesh::voxel::nearest_in_set(grid, outside, source, deadline)) {
        return false;
    }
    phases.mark("distance_transform");
    // s: how deep a sample lies inside the region the flood did not reach (negative outside it).
    // Outside it is R - d. Inside it is the distance to the nearest outside sample q, less how
    // far q itself is from the region's edge (d(q) - R): no sample gives less than the true
    // depth, and the least over q and its neighbours is within a small part of a cell of it.
    const int nx = grid.n[0], ny = grid.n[1], nz = grid.n[2];
    const size_t row = size_t(nx), slab = row * size_t(ny);
    f.assign(grid.count(), 0.0f);
    const double level = R - plan.offset;
    size_t at = 0;
    for (int k = 0; k < nz; ++k) {
        for (int j = 0; j < ny; ++j) {
            for (int i = 0; i < nx; ++i, ++at) {
                double s;
                if (outside[at] != 0) {
                    s = R - double(d[at]);
                }
                else if (source[at] < 0) {
                    s = band;
                }
                else {
                    const size_t q = size_t(source[at]);
                    const int qi = int(q % row), qj = int((q / row) % size_t(ny)), qk = int(q / slab);
                    auto depth = [&](int a, int b, int c, size_t index) {
                        const double dx = double(a - i), dy = double(b - j), dz = double(c - k);
                        return std::sqrt(dx * dx + dy * dy + dz * dz) * h - (double(d[index]) - R);
                    };
                    s = depth(qi, qj, qk, q);
                    if (s - level < 3.0 * h) {
                        for (int c = std::max(qk - 1, 0); c <= std::min(qk + 1, nz - 1); ++c) {
                            for (int b = std::max(qj - 1, 0); b <= std::min(qj + 1, ny - 1); ++b) {
                                for (int a = std::max(qi - 1, 0); a <= std::min(qi + 1, nx - 1); ++a) {
                                    const size_t index = grid.index(a, b, c);
                                    if (outside[index] != 0) {
                                        s = std::min(s, depth(a, b, c, index));
                                    }
                                }
                            }
                        }
                    }
                    s = std::max(s, 0.0);
                }
                f[at] = float(s - level);
                if (deadline.tick()) {
                    return false;
                }
            }
        }
    }
    // A sheet with nothing behind it (an open part the flood went around, or a wall thinner
    // than a cell) is a ridge of this function that just reaches the level: its true height is
    // 0, and what the estimate above adds (it never gives less than the true depth) would come
    // out as crumbs along the sheet. So a sample that is inside by less than a quarter cell
    // and has no neighbour that is inside by more is put outside. A real surface is untouched:
    // one cell further in, its samples are inside by far more than that.
    const double shallow = 0.25 * h;
    std::vector<uint32_t> crumbs;
    at = 0;
    for (int k = 0; k < nz; ++k) {
        for (int j = 0; j < ny; ++j) {
            for (int i = 0; i < nx; ++i, ++at) {
                if (!(f[at] > 0.0f) || double(f[at]) >= shallow) {
                    continue;
                }
                bool backed = false;
                for (int c = std::max(k - 1, 0); c <= std::min(k + 1, nz - 1) && !backed; ++c) {
                    for (int b = std::max(j - 1, 0); b <= std::min(j + 1, ny - 1) && !backed; ++b) {
                        for (int a = std::max(i - 1, 0); a <= std::min(i + 1, nx - 1); ++a) {
                            if (double(f[grid.index(a, b, c)]) >= shallow) {
                                backed = true;
                                break;
                            }
                        }
                    }
                }
                if (!backed) {
                    crumbs.push_back(uint32_t(at));
                }
            }
        }
        if (deadline.expired()) {
            return false;
        }
    }
    for (const uint32_t index : crumbs) {
        f[index] = float(-1e-3 * h);
    }
    return true;
}

double largest_opening(mesh::State& state);

/// The refusal when the outside reaches around (most of) the body, so that there is nothing
/// behind its surface to enclose. `share` is "all" or "about 98 %".
std::string left_out_sentence(mesh::State& state, const Plan& plan, const std::string& share)
{
    const double opening = largest_opening(state);
    std::string advice = "Raise Close Gaps Up To";
    if (opening > 0.0) {
        advice += " (its largest opening is about " + mesh::ops::length_text(opening) + " across)";
    }
    return "Wrap would leave " + share + " of " + plan.name + " out: it is open to the outside through gaps wider than " + mesh::ops::length_text(2.0 * plan.gap) +
           " (twice Close Gaps Up To), or thinner than " + mesh::ops::length_text(plan.detail) + ". " + advice + ", or add an Offset.";
}

/// The refusal when (most of) the body is thinner than Rebuild's cells. `share` is "all" or "about 98 %".
std::string lost_sentence(const Plan& plan, const std::string& share)
{
    return "Rebuild would lose " + share + " of " + plan.name + ": its parts are thinner than " + mesh::ops::length_text(plan.detail) +
           " (the cell size), so no cell lies inside them. Lower Detail.";
}

/// About how wide the body's largest opening is: the largest open loop's size (0 when there is none).
double largest_opening(mesh::State& state)
{
    double widest = 0.0;
    for (const mesh::BoundaryLoop& loop : mesh::boundary_loops(state)) {
        double lo[3] = {INFINITY, INFINITY, INFINITY}, hi[3] = {-INFINITY, -INFINITY, -INFINITY};
        for (const uint32_t v : loop.vertices) {
            double p[3];
            state.data.point(v, p);
            for (int k = 0; k < 3; ++k) {
                lo[k] = std::min(lo[k], p[k]);
                hi[k] = std::max(hi[k], p[k]);
            }
        }
        // (A round opening's bounding box has two sides of its width: the middle one of the three.)
        double side[3] = {hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2]};
        std::sort(side, side + 3);
        widest = std::max(widest, side[1]);
    }
    return widest;
}

/// Rebuild's function: the distance to the triangles, positive inside. Inside is where the
/// winding number is not 0; for a mesh whose triangles do not agree about their sides
/// (by_parity), where an odd number of them lies above.
bool rebuild_field(const mesh::TriBvh& bvh, const mesh::voxel::Grid& grid, bool by_parity, std::vector<float>& f, const mesh::Deadline& deadline, mesh::ops::Phases& phases)
{
    if (!mesh::voxel::distance_field(bvh, grid, 2.5 * grid.h, f, deadline)) {
        return false;
    }
    phases.mark("distance_field");
    std::vector<uint8_t> inside;
    if (!mesh::voxel::winding_field(bvh, grid, by_parity, inside, deadline)) {
        return false;
    }
    for (size_t i = 0; i < f.size(); ++i) {
        if (inside[i] == 0) {
            f[i] = -f[i];
        }
    }
    return true;
}

/// Exact Surface: every vertex within reach of the input moves onto it, unless that would turn
/// a triangle over (those vertices stay where the level set put them).
bool snap_to_input(MeshData& m, const mesh::TriBvh& bvh, double reach, int64_t& snapped, const mesh::Deadline& deadline)
{
    const size_t V = m.vertex_count(), T = m.triangle_count();
    const std::vector<float> before = m.positions;
    std::vector<float> target = m.positions;
    std::vector<uint8_t> moved(V, 0);
    for (size_t v = 0; v < V; ++v) {
        double p[3], q[3];
        m.point(uint32_t(v), p);
        uint32_t triangle = mesh::NONE;
        bvh.nearest(p, reach * reach, triangle, q);
        if (triangle != mesh::NONE) {
            for (int k = 0; k < 3; ++k) {
                target[v * 3 + size_t(k)] = float(q[k]);
            }
            moved[v] = 1;
        }
        if (deadline.tick()) {
            return false;
        }
    }
    auto normal = [&](const std::vector<float>& positions, const std::vector<uint8_t>* flags, size_t t, double n[3]) {
        double p[3][3];
        for (int c = 0; c < 3; ++c) {
            const uint32_t v = m.triangles[t * 3 + size_t(c)];
            const std::vector<float>& from = (flags != nullptr && (*flags)[v] != 0) ? target : positions;
            for (int k = 0; k < 3; ++k) {
                p[c][k] = from[size_t(v) * 3 + size_t(k)];
            }
        }
        const double e1[3] = {p[1][0] - p[0][0], p[1][1] - p[0][1], p[1][2] - p[0][2]}, e2[3] = {p[2][0] - p[0][0], p[2][1] - p[0][1], p[2][2] - p[0][2]};
        n[0] = e1[1] * e2[2] - e1[2] * e2[1];
        n[1] = e1[2] * e2[0] - e1[0] * e2[2];
        n[2] = e1[0] * e2[1] - e1[1] * e2[0];
    };
    for (int pass = 0; pass < 16; ++pass) {
        bool changed = false;
        for (size_t t = 0; t < T; ++t) {
            const uint32_t* tri = &m.triangles[t * 3];
            if (moved[tri[0]] == 0 && moved[tri[1]] == 0 && moved[tri[2]] == 0) {
                continue;
            }
            double n0[3], n1[3];
            normal(before, nullptr, t, n0);
            normal(before, &moved, t, n1);
            const double dot = n0[0] * n1[0] + n0[1] * n1[1] + n0[2] * n1[2];
            const double l0 = std::sqrt(n0[0] * n0[0] + n0[1] * n0[1] + n0[2] * n0[2]), l1 = std::sqrt(n1[0] * n1[0] + n1[1] * n1[1] + n1[2] * n1[2]);
            // Turned by more than about 78 degrees, or squeezed to (almost) nothing.
            if (!(dot > 0.2 * l0 * l1) || !(l1 > 0.05 * l0)) {
                moved[tri[0]] = moved[tri[1]] = moved[tri[2]] = 0;
                changed = true;
            }
            if (deadline.tick()) {
                return false;
            }
        }
        if (!changed) {
            break;
        }
        if (pass == 15) {
            std::fill(moved.begin(), moved.end(), uint8_t(0));  // (never seen: give the level set's own result)
        }
    }
    snapped = 0;
    for (size_t v = 0; v < V; ++v) {
        if (moved[v] != 0) {
            for (int k = 0; k < 3; ++k) {
                m.positions[v * 3 + size_t(k)] = target[v * 3 + size_t(k)];
            }
            ++snapped;
        }
    }
    return true;
}

/// How much of the input the result left out: points spread over the input by area (every
/// connected part gets at least four), each tested for lying outside the result and farther
/// than `allowed` from it.
struct LeftOut
{
    bool finished = false;
    double share = 0.0;      // of the input's area
    double farthest = 0.0;   // of the points left out, from the result
    int64_t samples = 0;
    int64_t parts = 0, parts_out = 0;  // connected parts with area; those more than half out
    Array list;              // [{"first_triangle", "triangles", "area_share"}], the first 100 parts out
};

LeftOut left_out(mesh::State& input, mesh::State& output, double allowed, const mesh::Deadline& deadline)
{
    LeftOut result;
    const MeshData& m = input.data;
    const mesh::Components* comps = mesh::components_of(input, &deadline);
    if (comps == nullptr) {
        return result;
    }
    const size_t T = m.triangle_count(), C = comps->list.size();
    std::vector<double> area(T, 0.0), part_area(C, 0.0);
    double total = 0.0;
    for (size_t t = 0; t < T; ++t) {
        const int32_t c = comps->of_triangle[t];
        if (c < 0) {
            continue;
        }
        double p[3][3], e1[3], e2[3];
        for (int k = 0; k < 3; ++k) {
            m.point(m.triangles[t * 3 + size_t(k)], p[k]);
        }
        for (int k = 0; k < 3; ++k) {
            e1[k] = p[1][k] - p[0][k];
            e2[k] = p[2][k] - p[0][k];
        }
        const double n[3] = {e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0]};
        area[t] = 0.5 * std::sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
        part_area[size_t(c)] += area[t];
        total += area[t];
    }
    if (!(total > 0.0)) {
        result.finished = true;
        return result;
    }
    const bool nothing = output.data.triangle_count() == 0;
    const mesh::TriBvh* bvh = nothing ? nullptr : mesh::bvh_of(output, &deadline);
    if (!nothing && bvh == nullptr) {
        return result;
    }
    // 20,000 points by area; at least four on every part (up to 20,000 parts).
    const int floor_points = C <= 20000 ? 4 : 0;
    std::vector<double> step(C, 0.0), carried(C, 0.0);
    std::vector<int64_t> tested(C, 0), out(C, 0);
    for (size_t c = 0; c < C; ++c) {
        if (part_area[c] > 0.0) {
            const double wanted = std::max(double(floor_points), 20000.0 * part_area[c] / total);
            step[c] = part_area[c] / std::max(wanted, 1e-9);
            carried[c] = 0.5 * step[c];
            ++result.parts;
        }
    }
    uint64_t seed = 0x9E3779B97F4A7C15ull;
    auto random = [&seed]() {
        seed += 0x9E3779B97F4A7C15ull;
        uint64_t z = seed;
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
        z ^= z >> 31;
        return double(z >> 11) * (1.0 / 9007199254740992.0);
    };
    for (size_t t = 0; t < T; ++t) {
        const int32_t c = comps->of_triangle[t];
        if (c < 0 || !(step[size_t(c)] > 0.0)) {
            continue;
        }
        carried[size_t(c)] += area[t];
        while (carried[size_t(c)] >= step[size_t(c)]) {
            carried[size_t(c)] -= step[size_t(c)];
            double p[3][3], q[3], nearest[3];
            for (int k = 0; k < 3; ++k) {
                m.point(m.triangles[t * 3 + size_t(k)], p[k]);
            }
            double u = random(), v = random();
            if (u + v > 1.0) {
                u = 1.0 - u;
                v = 1.0 - v;
            }
            for (int k = 0; k < 3; ++k) {
                q[k] = p[0][k] + u * (p[1][k] - p[0][k]) + v * (p[2][k] - p[0][k]);
            }
            ++tested[size_t(c)];
            ++result.samples;
            bool outside = nothing;
            double distance = 0.0;
            if (!nothing) {
                uint32_t triangle = mesh::NONE;
                const double d2 = bvh->nearest(q, INFINITY, triangle, nearest);
                if (d2 > allowed * allowed) {
                    int winding = 0;
                    bvh->column(q, [&](uint32_t, int sign) { winding += sign; });
                    outside = winding == 0;
                    distance = std::sqrt(d2);
                }
            }
            if (outside) {
                ++out[size_t(c)];
                result.farthest = std::max(result.farthest, distance);
            }
            if (deadline.tick()) {
                return result;
            }
        }
    }
    for (size_t c = 0; c < C; ++c) {
        if (tested[c] == 0) {
            continue;
        }
        result.share += part_area[c] / total * double(out[c]) / double(tested[c]);
        if (out[c] * 2 > tested[c]) {
            ++result.parts_out;
            if (result.list.size() < 100) {
                Dictionary d;
                d["first_triangle"] = int64_t(comps->list[c].first_triangle);
                d["triangles"] = int64_t(comps->list[c].triangles);
                d["area_share"] = part_area[c] / total;
                result.list.push_back(d);
            }
        }
    }
    result.finished = true;
    return result;
}

Dictionary plan_dict(const Plan& plan)
{
    Dictionary out;
    out["detail"] = plan.detail_default;
    out["detail_min"] = plan.detail_min;
    out["detail_max"] = plan.detail_max;
    if (plan.rebuild) {
        out["method"] = "union";
    }
    else {
        out["gap"] = std::min(2.0 * plan.detail, plan.diagonal / 4.0);
        out["gap_min"] = plan.detail;
        out["gap_max"] = plan.diagonal / 4.0;
        out["offset"] = 0.0;
        out["offset_min"] = -plan.gap;
        out["offset_max"] = plan.diagonal / 10.0;
    }
    out["cells"] = plan.cells;
    out["seconds"] = plan.seconds;
    return out;
}
}  // namespace

namespace mesh
{
Dictionary wrap_defaults(State& state, const Dictionary& options, bool rebuild)
{
    ops::Options o(options);
    Plan plan;
    if (!make_plan(state, o, plan, rebuild)) {
        // Still the defaults of a plain call, with the problem said.
        const Dictionary empty;
        ops::Options plain_options(empty);
        Plan plain_plan;
        Dictionary out;
        if (make_plan(state, plain_options, plain_plan, rebuild)) {
            out = plan_dict(plain_plan);
        }
        out["problem"] = ops::text(o.problem());
        return out;
    }
    return plan_dict(plan);
}
}  // namespace mesh

Ref<CadMesh> CadMesh::wrap_op(const Dictionary& options)
{
    clear_messages();
    const double started = mesh::ops::now_ms();
    const char* const hint = "Raise Detail.";
    if (is_null()) {
        fail("There is no mesh to wrap.");
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
    if (plan.seconds > plan.limit && !skip_estimate) {
        fail(mesh::ops::too_slow("Wrap", plan.seconds, plan.limit, hint));
        return Ref<CadMesh>();
    }
    const mesh::Deadline deadline(plan.limit);
    auto late = [&]() {
        fail(mesh::ops::timed_out("Wrap", plan.limit, hint));
        return Ref<CadMesh>();
    };
    const mesh::TriBvh* bvh = mesh::bvh_of(*state, &deadline);
    if (bvh == nullptr) {
        return late();
    }
    const mesh::voxel::Grid grid = mesh::voxel::make_grid(plan.lo, plan.hi, plan.margin, plan.detail);
    phases.mark("hierarchy");
    std::vector<float> f;
    if (!wrap_field(*bvh, grid, plan, f, deadline, phases)) {
        return late();
    }
    phases.mark("field");  // (what is left of our own part: Wrap's function, Rebuild's winding columns)
    mesh::mf::Import imported;
    try {
        manifold::ExecutionContext ctx;
        const mesh::mf::Watchdog watchdog(ctx, deadline);
        double guard_below = 0.0;
        const manifold::Manifold solid = mesh::mf::level_set(ctx, grid, f, guard_below);
        const mesh::mf::Status status = solid.Status();
        phases.mark("level_set");
        if (status == mesh::mf::Status::Cancelled || deadline.expired()) {
            return late();
        }
        if (status != mesh::mf::Status::NoError) {
            fail(mesh::mf::status_text(status, "Wrap"));
            return Ref<CadMesh>();
        }
        if (mesh::mf::only_guard(solid, guard_below)) {
            // Nothing lies deeper than a cell behind the body's surface: the flood went around it.
            fail(left_out_sentence(*state, plan, "all"));
            return Ref<CadMesh>();
        }
        std::string error;
        if (!mesh::mf::from_gl(solid.GetMeshGL64(), {}, {}, "wrap0", imported, error)) {
            fail("Wrap failed: " + error + ". Raise Detail.");
            return Ref<CadMesh>();
        }
        mesh::mf::drop_guard(imported, guard_below);
    }
    catch (const std::exception& e) {
        fail(std::string("Wrap failed inside the mesh library: ") + e.what());
        return Ref<CadMesh>();
    }
    catch (...) {
        fail("Wrap failed inside the mesh library.");
        return Ref<CadMesh>();
    }
    phases.mark("export");
    Ref<CadMesh> out = finish_op("Wrap", "wrap", std::move(imported.mesh), started, true);
    phases.mark("finish");
    if (out.is_null()) {
        return out;
    }
    Dictionary checks = last_report["checks"];
    PackedStringArray warnings;
    if (!last_warning.is_empty()) {
        warnings.push_back(last_warning);
    }
    // Must hold: closed, manifold, facing out.
    const mesh::Summary after = mesh::summarize(out->get_state());
    if (after.boundary_edges > 0 || after.non_manifold_edges > 0 || after.inverted_components > 0 || !(after.volume > 0.0)) {
        const std::string sentence = "Wrap made a mesh that is not a closed solid (" + mesh::ops::count_text(after.boundary_edges, "open edge", "open edges") + ", " +
                                     mesh::ops::count_text(after.non_manifold_edges, "edge", "edges") + " shared by more than two triangles, " +
                                     mesh::ops::count_text(after.inverted_components, "part", "parts") + " inside-out). Please report it.";
        checks["closed"] = String("fail: ") + mesh::ops::text(sentence);
        last_report["checks"] = checks;
        last_warning = String();
        fail(sentence);
        return Ref<CadMesh>();
    }
    checks["closed"] = "ok";
    // How far the input lies from the wrap (the other way round is large wherever a gap was closed).
    const mesh::Distance away = mesh::distance_between(*state, out->get_state(), 20000, deadline);
    Dictionary deviation;
    deviation["max"] = away.max;
    deviation["mean"] = away.mean;
    deviation["samples"] = away.samples;
    last_report["deviation"] = deviation;
    // Everything of the input must lie in or on the wrap. What does not (an open part the
    // outside reaches around, a wall thinner than a cell) is measured by surface area and said,
    // with how much, how far, and which connected parts are out altogether.
    const LeftOut left = left_out(*state, out->get_state(), std::max(-plan.offset, 0.0) + 1.5 * plan.detail, deadline);
    if (!left.finished) {
        return late();
    }
    last_report["left_out"] = left.share;
    last_report["left_out_parts"] = left.list;
    last_report["parts"] = left.parts;
    if (left.share > 0.5) {
        // More than half of the body's surface is not in the wrap: that is no wrap of it.
        const std::string sentence = left_out_sentence(*state, plan, "about " + mesh::number_text(100.0 * left.share, "%.0f") + " %");
        checks["covered"] = String("fail: ") + mesh::ops::text(sentence);
        last_report["checks"] = checks;
        last_warning = String();
        fail(sentence);
        return Ref<CadMesh>();
    }
    if (left.share > 0.0) {
        std::string sentence = mesh::ops::share_text(left.share) + " of " + plan.name + "'s surface is not inside the wrap (up to " + mesh::ops::length_text(left.farthest) +
                               " outside it): those parts are thinner than " + mesh::ops::length_text(plan.detail) + ", or open to the outside through gaps wider than " +
                               mesh::ops::length_text(2.0 * plan.gap) + ".";
        if (left.parts_out > 0 && left.parts > 1) {
            sentence += " " + mesh::with_commas(uint64_t(left.parts_out)) + " of its " + mesh::with_commas(uint64_t(left.parts)) + " separate parts " +
                        (left.parts_out == 1 ? "is" : "are") + " not in the wrap at all.";
        }
        warnings.push_back(mesh::ops::text(sentence + " Raise Close Gaps Up To, lower Detail, or add an Offset."));
        checks["covered"] = "warn: parts of the input are outside the wrap";
    }
    else {
        checks["covered"] = "ok";
    }
    // Voids inside the body are not reached by the outside, so they are filled: said, too.
    int64_t voids = 0;
    if (const mesh::Components* nested = mesh::nested_components_of(*state, &deadline)) {
        for (const mesh::Component& c : nested->list) {
            voids += (c.consistent && c.depth % 2 == 1 && c.volume < 0.0) ? 1 : 0;
        }
    }
    last_report["filled_voids"] = voids;
    if (voids > 0) {
        warnings.push_back(mesh::ops::text("Wrap filled " + mesh::ops::count_text(voids, "inner void", "inner voids") + " of " + plan.name + "."));
        checks["voids"] = "warn: inner voids were filled";
    }
    warnings.push_back(mesh::ops::text("Edges are rounded to about " + mesh::ops::length_text(plan.detail) + "."));
    checks["rounded"] = "warn: edges are rounded to about the cell size";
    last_report["checks"] = checks;
    last_report["cells"] = plan.cells;
    last_report["detail"] = plan.detail;
    last_report["gap"] = plan.gap;
    last_report["offset"] = plan.offset;
    phases.mark("covered");
    last_report["phases"] = phases.ms;
    last_report["estimate"] = plan.seconds;
    last_report["ms"] = mesh::ops::now_ms() - started;
    last_warning = String("\n").join(warnings);
    return out;
}

Ref<CadMesh> CadMesh::rebuild(const Dictionary& options)
{
    clear_messages();
    const double started = mesh::ops::now_ms();
    const char* const hint = "Raise Detail.";
    if (is_null()) {
        fail("There is no mesh to rebuild.");
        return Ref<CadMesh>();
    }
    mesh::ops::Options o(options);
    Plan plan;
    mesh::ops::Phases phases;
    const bool skip_estimate = o.skip_estimate();
    if (!make_plan(*state, o, plan, true) || !o.ok()) {
        fail(o.problem());
        return Ref<CadMesh>();
    }
    if (plan.seconds > plan.limit && !skip_estimate) {
        fail(mesh::ops::too_slow("Rebuild", plan.seconds, plan.limit, hint));
        return Ref<CadMesh>();
    }
    const mesh::Deadline deadline(plan.limit);
    auto late = [&]() {
        fail(mesh::ops::timed_out("Rebuild", plan.limit, hint));
        return Ref<CadMesh>();
    };
    const mesh::TriBvh* bvh = mesh::bvh_of(*state, &deadline);
    if (bvh == nullptr) {
        return late();
    }
    const mesh::Summary before = mesh::summarize(*state);
    const mesh::voxel::Grid grid = mesh::voxel::make_grid(plan.lo, plan.hi, plan.margin, plan.detail);
    phases.mark("hierarchy");
    std::vector<float> f;
    // Triangles that face the wrong way make the winding number useless (below a ball whose
    // lower half is flipped it is 2): such a mesh is rebuilt by counting crossings.
    const bool by_parity = mesh::topology_of(*state)->inconsistent_edges > 0;
    if (!rebuild_field(*bvh, grid, by_parity, f, deadline, phases)) {
        return late();
    }
    phases.mark("field");  // (what is left of our own part: Wrap's function, Rebuild's winding columns)
    mesh::mf::Import imported;
    try {
        manifold::ExecutionContext ctx;
        const mesh::mf::Watchdog watchdog(ctx, deadline);
        double guard_below = 0.0;
        const manifold::Manifold solid = mesh::mf::level_set(ctx, grid, f, guard_below);
        const mesh::mf::Status status = solid.Status();
        phases.mark("level_set");
        if (status == mesh::mf::Status::Cancelled || deadline.expired()) {
            return late();
        }
        if (status != mesh::mf::Status::NoError) {
            fail(mesh::mf::status_text(status, "Rebuild"));
            return Ref<CadMesh>();
        }
        if (mesh::mf::only_guard(solid, guard_below)) {
            // No sample of the grid is inside. A closed body has an inside: it is thinner than
            // the cells everywhere. An open one has none to find.
            if (before.boundary_edges == 0 && std::fabs(before.volume) > 0.0) {
                fail(lost_sentence(plan, "all"));
            }
            else {
                fail("Rebuild found no inside in " + plan.name + " (its triangles enclose nothing). Use Wrap.");
            }
            return Ref<CadMesh>();
        }
        std::string error;
        if (!mesh::mf::from_gl(solid.GetMeshGL64(), {}, {}, "rebuild0", imported, error)) {
            fail("Rebuild failed: " + error + ". Raise Detail.");
            return Ref<CadMesh>();
        }
        mesh::mf::drop_guard(imported, guard_below);
    }
    catch (const std::exception& e) {
        fail(std::string("Rebuild failed inside the mesh library: ") + e.what());
        return Ref<CadMesh>();
    }
    catch (...) {
        fail("Rebuild failed inside the mesh library.");
        return Ref<CadMesh>();
    }
    phases.mark("export");
    int64_t snapped = 0;
    if (plan.method == 1 && !snap_to_input(imported.mesh, *bvh, 0.5 * plan.detail, snapped, deadline)) {
        return late();
    }
    phases.mark("snap");
    Ref<CadMesh> out = finish_op("Rebuild", "rebuild", std::move(imported.mesh), started, true);
    phases.mark("finish");
    if (out.is_null()) {
        return out;
    }
    Dictionary checks = last_report["checks"];
    PackedStringArray warnings;
    if (!last_warning.is_empty()) {
        warnings.push_back(last_warning);
    }
    // Must hold: closed and manifold.
    const mesh::Summary after = mesh::summarize(out->get_state());
    if (after.boundary_edges > 0 || after.non_manifold_edges > 0) {
        const std::string sentence = "Rebuild made a mesh that is not closed (" + mesh::ops::count_text(after.boundary_edges, "open edge", "open edges") + ", " +
                                     mesh::ops::count_text(after.non_manifold_edges, "edge", "edges") + " shared by more than two triangles). Please report it.";
        checks["closed"] = String("fail: ") + mesh::ops::text(sentence);
        last_report["checks"] = checks;
        last_warning = String();
        fail(sentence);
        return Ref<CadMesh>();
    }
    checks["closed"] = "ok";
    // What the result lost: parts thinner than a cell have no sample inside them and are gone.
    // Measured like Wrap's coverage (points on the input, by area, that lie outside the result
    // and more than a cell and a half from it), and how far the input lies from the result.
    const mesh::Distance away = mesh::distance_between(*state, out->get_state(), 20000, deadline);
    Dictionary deviation;
    deviation["max"] = away.max;
    deviation["mean"] = away.mean;
    deviation["samples"] = away.samples;
    last_report["deviation"] = deviation;
    const LeftOut left = left_out(*state, out->get_state(), 1.5 * plan.detail, deadline);
    if (!left.finished) {
        return late();
    }
    last_report["left_out"] = left.share;
    last_report["left_out_parts"] = left.list;
    last_report["parts"] = left.parts;
    if (left.share > 0.5) {
        const std::string sentence = lost_sentence(plan, "about " + mesh::number_text(100.0 * left.share, "%.0f") + " %");
        checks["covered"] = String("fail: ") + mesh::ops::text(sentence);
        last_report["checks"] = checks;
        last_warning = String();
        fail(sentence);
        return Ref<CadMesh>();
    }
    if (by_parity) {
        warnings.push_back(mesh::ops::text(plan.name_start + " has triangles that face the wrong way, so Rebuild went by counting the surfaces it crosses: where parts of it overlap, " +
                                           "the result may be hollow. Run Reverse Normal first for a better result."));
        checks["input_sides"] = "warn: the input's triangles do not agree about their sides";
    }
    else if (before.inverted_components > 0) {
        warnings.push_back(mesh::ops::text(plan.name_start + " has " + mesh::ops::count_text(before.inverted_components, "part that is", "parts that are") +
                                           " inside-out: where they overlap other parts, the result may be hollow. Reverse Normal can fix them first."));
        checks["input_sides"] = "warn: the input has parts that are inside-out";
    }
    if (left.share > 0.0) {
        std::string sentence = mesh::ops::share_text(left.share) + " of " + plan.name + "'s surface is not in the result (up to " + mesh::ops::length_text(left.farthest) +
                               " from it): parts thinner than " + mesh::ops::length_text(plan.detail) + " were lost.";
        if (left.parts_out > 0 && left.parts > 1) {
            sentence += " " + mesh::with_commas(uint64_t(left.parts_out)) + " of its " + mesh::with_commas(uint64_t(left.parts)) + " separate parts " +
                        (left.parts_out == 1 ? "is" : "are") + " gone.";
        }
        warnings.push_back(mesh::ops::text(sentence + " Lower Detail."));
        checks["covered"] = "warn: parts thinner than the cell were lost";
    }
    else {
        checks["covered"] = "ok";
    }
    if (before.boundary_edges > 0) {
        warnings.push_back(mesh::ops::text(plan.name_start + " has open edges; Rebuild treats them as closed by the nearest surface. Close Holes first for a better result."));
        checks["input_open"] = "warn: the input has open edges";
    }
    else if (!(std::fabs(before.volume) > 0.0)) {
        // (No open edge, and still no volume to compare with: edges shared by more than two
        // triangles, say. A percentage of nothing says nothing.)
        warnings.push_back(mesh::ops::text(plan.name_start + " had no volume that could be measured (it is not a clean closed body); the result has " +
                                           mesh::ops::plain_number(after.volume * 1e9, 6) + " mm3."));
        checks["volume"] = "warn: the input had no volume to compare with";
    }
    else if (std::fabs(after.volume - before.volume) > 0.02 * std::fabs(before.volume)) {
        const double percent = 100.0 * (after.volume - before.volume) / std::fabs(before.volume);
        // (Why it changed is said only where it is known: overlaps count once when nothing was lost.)
        const bool overlaps = percent < 0.0 && !(left.share > 0.0) && !by_parity;
        const std::string change = (percent > 0.0 ? "+" : "") + (std::fabs(percent) < 100.0 ? mesh::ops::plain_number(percent, 3) : mesh::ops::plain_number(std::round(percent), 9));
        warnings.push_back(mesh::ops::text("Rebuild changed the volume by " + change + " % (from " + mesh::ops::plain_number(before.volume * 1e9, 6) + " mm3 to " +
                                           mesh::ops::plain_number(after.volume * 1e9, 6) + " mm3)" + (overlaps ? "; parts that overlapped count once now." : ".")));
        checks["volume"] = "warn: the volume changed by more than 2 %";
    }
    else {
        checks["volume"] = "ok";
    }
    warnings.push_back(mesh::ops::text("Edges are rounded to about " + mesh::ops::length_text(plan.detail) + "."));
    checks["rounded"] = "warn: edges are rounded to about the cell size";
    last_report["checks"] = checks;
    last_report["cells"] = plan.cells;
    last_report["detail"] = plan.detail;
    last_report["snapped_vertices"] = snapped;
    phases.mark("covered");
    last_report["phases"] = phases.ms;
    last_report["estimate"] = plan.seconds;
    last_report["ms"] = mesh::ops::now_ms() - started;
    last_warning = String("\n").join(warnings);
    return out;
}

}  // namespace holo_forge
