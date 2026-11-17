// Texture Extrude (work order 3.3.11): the selection is refined to the Detail edge length (long
// edges split at their middle, pass by pass), then every free vertex moves along its smoothed
// normal by Depth x the image's brightness there. Edges on the selection's border are split
// too, and the triangle outside is split along with them (in its own plane, so the body's shape
// outside the selection stays as it is; no vertex there moves). Leaving the border edges whole
// does not work: a triangle that keeps a long edge can never get short edges, so its splits
// would never end.

#include "cad_mesh.h"
#include "mesh_manifold.h"

#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <unordered_map>
#include <unordered_set>

using namespace godot;

namespace holo_forge
{

namespace
{
using mesh::MeshData;
using mesh::NONE;
const char* const kHint = "Raise Detail or Tile Size.";

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
inline uint64_t edge_key(uint32_t a, uint32_t b)
{
    return (uint64_t(std::min(a, b)) << 32) | uint64_t(std::max(a, b));
}

struct Plan
{
    double diagonal = 0.0;
    double depth = 0.0, tile = 0.0, angle = 0.0, detail = 0.0;
    int mapping = 1;  // 0 planar, 1 box, 2 cylindrical
    bool invert = false, refine = true;
    double depth_default = 0.0, depth_limit = 0.0;
    double tile_default = 0.0, tile_min = 0.0, tile_max = 0.0;
    double detail_default = 0.0, detail_min = 0.0, detail_max = 0.0;
    std::vector<uint8_t> selected;  // per triangle
    size_t selected_count = 0;
    double selected_area = 0.0;
    double made = 0.0;  // triangles the result will have, about
    double seconds = 0.0;
    double limit = 20.0;
    std::string name;
};

double triangle_area(const MeshData& m, size_t t)
{
    double p[3][3], e1[3], e2[3], n[3];
    for (int k = 0; k < 3; ++k) {
        m.point(m.triangles[t * 3 + size_t(k)], p[k]);
    }
    for (int k = 0; k < 3; ++k) {
        e1[k] = p[1][k] - p[0][k];
        e2[k] = p[2][k] - p[0][k];
    }
    cross3(e1, e2, n);
    return 0.5 * std::sqrt(dot3(n, n));
}

bool make_plan(mesh::State& state, const Dictionary& options, mesh::ops::Options& o, Plan& plan)
{
    using namespace mesh::budget;
    const MeshData& m = state.data;
    const mesh::Measures& ms = mesh::measures_of(state);
    const double D = ms.diagonal;
    plan.diagonal = D;
    plan.name = o.name(false);
    plan.limit = o.time_limit();
    if (!(D > 0.0)) {
        o.fail("Texture Extrude needs a body with a size.");
        return false;
    }
    plan.depth_default = D / 200.0;
    plan.depth_limit = D / 10.0;
    plan.tile_default = D / 5.0;
    plan.tile_min = D / 1000.0;
    plan.tile_max = 10.0 * D;
    plan.depth = o.number("depth", "Depth", plan.depth_default);
    plan.mapping = o.choice("mapping", "Mapping", {"planar", "box", "cylindrical"}, 1);
    plan.tile = o.number("tile", "Tile Size", plan.tile_default);
    plan.angle = o.number("angle", "Rotation", 0.0);
    plan.invert = o.flag("invert", "Invert", false);
    plan.refine = o.flag("refine", "Refine", true);
    if (!o.ok()) {
        return false;
    }
    if (!o.range("Depth", plan.depth, -plan.depth_limit, plan.depth_limit, true)) {
        return false;
    }
    if (plan.depth == 0.0) {
        o.fail("Depth must not be 0.");
        return false;
    }
    if (!o.range("Tile Size", plan.tile, plan.tile_min, plan.tile_max, true) || !o.range("Rotation", plan.angle, -360.0, 360.0, false)) {
        return false;
    }
    plan.detail_default = plan.tile / 128.0;
    plan.detail_min = plan.tile / 512.0;
    plan.detail_max = plan.tile / 8.0;
    plan.detail = o.number("detail", "Detail", plan.detail_default);
    if (!o.ok() || !o.range("Detail", plan.detail, plan.detail_min, plan.detail_max, true)) {
        return false;
    }
    // Far from the origin positions step by more than a share of the depth: the texture would
    // be rounding noise. And a result past the limit of a mesh body: both said here.
    {
        const std::string far = mesh::ops::too_far(state, o.name(true), std::fabs(plan.depth) / 8.0, "too coarse for a Depth of " + mesh::ops::length_text(std::fabs(plan.depth)));
        if (!far.empty()) {
            o.fail(far);
            return false;
        }
        const std::string out = mesh::ops::past_limit(state, "Texture Extrude", std::fabs(plan.depth), plan.name);
        if (!out.empty()) {
            o.fail(out);
            return false;
        }
    }
    // The selection: triangles, or whole groups; neither means the whole body.
    const size_t T = m.triangle_count();
    const Variant triangles = options.get(String("triangles"), Variant()), groups = options.get(String("groups"), Variant());
    const bool by_triangles = triangles.get_type() == Variant::PACKED_INT32_ARRAY, by_groups = groups.get_type() == Variant::PACKED_INT32_ARRAY;
    if ((triangles.get_type() != Variant::NIL && !by_triangles) || (groups.get_type() != Variant::NIL && !by_groups)) {
        o.fail("The selection must be a list of triangle or face group numbers.");
        return false;
    }
    if (!by_triangles && !by_groups) {
        plan.selected.assign(T, 1);
    }
    else {
        plan.selected.assign(T, 0);
        if (by_triangles) {
            const PackedInt32Array list = triangles;
            for (int64_t i = 0; i < list.size(); ++i) {
                if (list[i] < 0 || size_t(list[i]) >= T) {
                    o.fail("The selection names triangle " + std::to_string(list[i]) + ", but the body has " + mesh::with_commas(T) + ".");
                    return false;
                }
                plan.selected[size_t(list[i])] = 1;
            }
        }
        if (by_groups) {
            const PackedInt32Array list = groups;
            std::vector<uint8_t> wanted(m.group_count(), 0);
            for (int64_t i = 0; i < list.size(); ++i) {
                if (list[i] < 0 || size_t(list[i]) >= m.group_count()) {
                    o.fail("The selection names face group " + std::to_string(list[i]) + ", but the body has " + mesh::with_commas(m.group_count()) + ".");
                    return false;
                }
                wanted[size_t(list[i])] = 1;
            }
            for (size_t t = 0; t < T; ++t) {
                if (wanted[m.groups[t]] != 0) {
                    plan.selected[t] = 1;
                }
            }
        }
    }
    for (size_t t = 0; t < T; ++t) {
        if (plan.selected[t] != 0) {
            ++plan.selected_count;
            plan.selected_area += triangle_area(m, t);
        }
    }
    if (plan.selected_count == 0 || !(plan.selected_area > 0.0)) {
        o.fail("Texture Extrude needs a selection with triangles.");
        return false;
    }
    // About how many triangles: the selection's area in triangles with Detail edges.
    const double refined = plan.refine ? std::max(double(plan.selected_count), plan.selected_area / (0.433 * plan.detail * plan.detail)) : double(plan.selected_count);
    plan.made = double(T - plan.selected_count) + refined;
    if (plan.made > double(MAX_TRIANGLES_MESH)) {
        o.fail("Texture Extrude would make about " + mesh::with_commas(uint64_t(plan.made)) + " triangles; raise Detail or Tile Size.");
        return false;
    }
    // (The result and the body itself are each tested for crossings, for at most 1 s each.)
    plan.seconds = DISPLACE_SECONDS_PER_MILLION_TRIANGLES * plan.made / 1e6 + estimate(TOPOLOGY, plan.made) + estimate(OP_FINISH, plan.made) +
                   std::min(SELF_INTERSECTION_SECONDS, estimate(BVH_BUILD, plan.made) + estimate(SELF_INTERSECTIONS, plan.made)) +
                   std::min(SELF_INTERSECTION_SECONDS, estimate(BVH_BUILD, double(T)) + estimate(SELF_INTERSECTIONS, double(T)));
    return true;
}

/// Splits every edge of the selection longer than 4/3 of `length` at its middle, pass by pass,
/// until none is left. A triangle outside the selection that shares a split edge is split with
/// it (and stays outside). False when the deadline passed; `over` when the result would not
/// fit a mesh body.
bool refine(MeshData& m, std::vector<uint8_t>& selected, double length, const mesh::Deadline& deadline, bool& over)
{
    over = false;
    const double limit2 = (4.0 / 3.0 * length) * (4.0 / 3.0 * length);
    auto length2 = [&](uint32_t a, uint32_t b) {
        double s = 0.0;
        for (int k = 0; k < 3; ++k) {
            const double d = double(m.positions[size_t(a) * 3 + size_t(k)]) - double(m.positions[size_t(b) * 3 + size_t(k)]);
            s += d * d;
        }
        return s;
    };
    std::unordered_map<uint64_t, uint32_t> middle;
    for (int pass = 0; pass < 64; ++pass) {
        middle.clear();
        const size_t T = m.triangle_count();
        size_t extra = 0;
        for (size_t t = 0; t < T; ++t) {
            if (selected[t] == 0) {
                continue;
            }
            const uint32_t* tri = &m.triangles[t * 3];
            for (int k = 0; k < 3; ++k) {
                const uint32_t a = tri[k], b = tri[(k + 1) % 3];
                if (a == b || !(length2(a, b) > limit2)) {
                    continue;
                }
                const uint64_t key = edge_key(a, b);
                if (middle.find(key) == middle.end()) {
                    const uint32_t id = uint32_t(m.vertex_count());
                    for (int c = 0; c < 3; ++c) {
                        m.positions.push_back(float(0.5 * (double(m.positions[size_t(a) * 3 + size_t(c)]) + double(m.positions[size_t(b) * 3 + size_t(c)]))));
                    }
                    middle.insert({key, id});
                }
            }
            if (deadline.tick()) {
                return false;
            }
        }
        if (middle.empty()) {
            return true;
        }
        // How many triangles this pass adds: one per split edge of every triangle that has it.
        for (size_t t = 0; t < T; ++t) {
            const uint32_t* tri = &m.triangles[t * 3];
            for (int k = 0; k < 3; ++k) {
                if (tri[k] != tri[(k + 1) % 3] && middle.find(edge_key(tri[k], tri[(k + 1) % 3])) != middle.end()) {
                    ++extra;
                }
            }
        }
        if (T + extra > mesh::budget::MAX_TRIANGLES_MESH || m.vertex_count() > mesh::budget::MAX_VERTICES_MESH) {
            over = true;
            return true;
        }
        std::vector<uint32_t> triangles, groups;
        std::vector<uint8_t> flags;
        triangles.reserve((T + extra) * 3);
        groups.reserve(T + extra);
        flags.reserve(T + extra);
        uint8_t flag = 0;  // the parent's: a triangle outside the selection stays outside
        auto emit = [&](uint32_t a, uint32_t b, uint32_t c, uint32_t group) {
            triangles.push_back(a);
            triangles.push_back(b);
            triangles.push_back(c);
            groups.push_back(group);
            flags.push_back(flag);
        };
        for (size_t t = 0; t < T; ++t) {
            const uint32_t v[3] = {m.triangles[t * 3], m.triangles[t * 3 + 1], m.triangles[t * 3 + 2]};
            const uint32_t group = m.groups[t];
            uint32_t mid[3] = {NONE, NONE, NONE};
            int count = 0;
            flag = selected[t];
            for (int k = 0; k < 3; ++k) {
                const auto found = v[k] == v[(k + 1) % 3] ? middle.end() : middle.find(edge_key(v[k], v[(k + 1) % 3]));
                if (found != middle.end()) {
                    mid[k] = found->second;
                    ++count;
                }
            }
            if (count == 0) {
                triangles.insert(triangles.end(), v, v + 3);
                groups.push_back(group);
                flags.push_back(selected[t]);
            }
            else if (count == 3) {
                emit(v[0], mid[0], mid[2], group);
                emit(v[1], mid[1], mid[0], group);
                emit(v[2], mid[2], mid[1], group);
                emit(mid[0], mid[1], mid[2], group);
            }
            else if (count == 1) {
                const int k = mid[0] != NONE ? 0 : (mid[1] != NONE ? 1 : 2);
                const uint32_t a = v[k], b = v[(k + 1) % 3], c = v[(k + 2) % 3];
                emit(a, mid[k], c, group);
                emit(mid[k], b, c, group);
            }
            else {
                // Two split edges meet at one corner: that corner's triangle, and the rest (a
                // quad) along its shorter diagonal.
                const int k = mid[0] == NONE ? 1 : (mid[1] == NONE ? 2 : 0);  // edges k and k + 1 are split
                const uint32_t a = v[k], b = v[(k + 1) % 3], c = v[(k + 2) % 3];
                const uint32_t ab = mid[k], bc = mid[(k + 1) % 3];
                emit(ab, b, bc, group);
                if (length2(a, bc) <= length2(ab, c)) {
                    emit(a, ab, bc, group);
                    emit(a, bc, c, group);
                }
                else {
                    emit(a, ab, c, group);
                    emit(ab, bc, c, group);
                }
            }
            if (deadline.tick()) {
                return false;
            }
        }
        m.triangles.swap(triangles);
        m.groups.swap(groups);
        selected.swap(flags);
    }
    return true;
}

Dictionary plan_dict(const Plan& plan)
{
    Dictionary out;
    out["depth"] = plan.depth_default;
    out["depth_min"] = -plan.depth_limit;
    out["depth_max"] = plan.depth_limit;
    out["mapping"] = "box";
    out["tile"] = plan.tile_default;
    out["tile_min"] = plan.tile_min;
    out["tile_max"] = plan.tile_max;
    out["angle"] = 0.0;
    out["angle_min"] = -360.0;
    out["angle_max"] = 360.0;
    out["invert"] = false;
    out["detail"] = plan.detail_default;
    out["detail_min"] = plan.detail_min;
    out["detail_max"] = plan.detail_max;
    out["triangles"] = plan.made;
    out["seconds"] = plan.seconds;
    return out;
}
}  // namespace

namespace mesh
{
Dictionary displace_defaults(State& state, const Dictionary& options)
{
    ops::Options o(options);
    Plan plan;
    const bool ok = make_plan(state, options, o, plan);
    Dictionary out = plan_dict(plan);
    if (!ok) {
        out["problem"] = ops::text(o.problem());
    }
    return out;
}
}  // namespace mesh

Ref<CadMesh> CadMesh::displace(const Dictionary& options)
{
    clear_messages();
    const double started = mesh::ops::now_ms();
    if (is_null()) {
        fail("There is no mesh to extrude a texture on.");
        return Ref<CadMesh>();
    }
    mesh::ops::Options o(options);
    Plan plan;
    mesh::ops::Phases phases;
    const bool skip_estimate = o.skip_estimate();
    if (!make_plan(*state, options, o, plan) || !o.ok()) {
        fail(o.problem());
        return Ref<CadMesh>();
    }
    // The image: one brightness byte per pixel, rows from the top.
    const Variant image_value = options.get(String("image"), Variant());
    const int64_t width = int64_t(o.number("width", "The image's width", 0.0)), height = int64_t(o.number("height", "The image's height", 0.0));
    if (image_value.get_type() != Variant::PACKED_BYTE_ARRAY || width < 1 || height < 1 || width > 16384 || height > 16384) {
        fail("Texture Extrude needs an image (its brightness as bytes, with a width and a height of 1 to 16,384).");
        return Ref<CadMesh>();
    }
    const PackedByteArray image = image_value;
    if (image.size() != width * height) {
        fail("The image is " + std::to_string(width) + " x " + std::to_string(height) + " pixels but has " + mesh::with_commas(uint64_t(image.size())) + " brightness values.");
        return Ref<CadMesh>();
    }
    if (plan.seconds > plan.limit && !skip_estimate) {
        fail(mesh::ops::too_slow("Texture Extrude", plan.seconds, plan.limit, kHint));
        return Ref<CadMesh>();
    }
    const mesh::Deadline deadline(plan.limit);
    auto late = [&]() {
        fail(mesh::ops::timed_out("Texture Extrude", plan.limit, kHint));
        return Ref<CadMesh>();
    };
    const MeshData& input = state->data;
    const size_t first_vertices = input.vertex_count();
    MeshData m = input;
    std::vector<uint8_t> selected = plan.selected;
    if (plan.refine) {
        bool over = false;
        if (!refine(m, selected, plan.detail, deadline, over)) {
            return late();
        }
        if (over) {
            fail("Texture Extrude would make more than " + mesh::with_commas(mesh::budget::MAX_TRIANGLES_MESH) + " triangles; raise Detail or Tile Size.");
            return Ref<CadMesh>();
        }
    }
    phases.mark("refine");
    const size_t V = m.vertex_count(), T = m.triangle_count();
    // Free vertices: in the selection, not on its border and not on an open edge.
    std::vector<uint8_t> in_selection(V, 0), fixed(V, 0);
    for (size_t t = 0; t < T; ++t) {
        for (int k = 0; k < 3; ++k) {
            const uint32_t v = m.triangles[t * 3 + size_t(k)];
            if (selected[t] != 0) {
                in_selection[v] = 1;
            }
            else {
                fixed[v] = 1;
            }
        }
    }
    {
        mesh::State refined;
        refined.data = std::move(m);
        const mesh::Topology* topo = mesh::topology_of(refined, &deadline);
        if (topo == nullptr) {
            return late();
        }
        for (size_t he = 0; he < topo->he_edge.size(); ++he) {
            const uint32_t e = topo->he_edge[he];
            if (e != NONE && topo->uses(e) == 1) {
                fixed[refined.data.triangles[he]] = 1;
                fixed[refined.data.triangles[(he / 3) * 3 + (he + 1) % 3]] = 1;
            }
        }
        m = std::move(refined.data);
    }
    // Normals: angle-weighted, then averaged once with the neighbours (the selection's edges).
    std::vector<double> normal(V * 3, 0.0);
    double mean_normal[3] = {0, 0, 0}, centroid[3] = {0, 0, 0}, lo[3] = {INFINITY, INFINITY, INFINITY}, hi[3] = {-INFINITY, -INFINITY, -INFINITY};
    double leaning[3] = {0, 0, 0}, area_sum = 0.0;
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
                normal[size_t(v) * 3 + size_t(k)] += angle * n[k] / len;
            }
        }
        if (selected[t] != 0) {
            const double area = 0.5 * len;
            area_sum += area;
            for (int k = 0; k < 3; ++k) {
                mean_normal[k] += 0.5 * n[k];
                leaning[k] += area * std::fabs(n[k] / len);
                centroid[k] += area * (p[0][k] + p[1][k] + p[2][k]) / 3.0;
                for (int c = 0; c < 3; ++c) {
                    lo[k] = std::min(lo[k], p[c][k]);
                    hi[k] = std::max(hi[k], p[c][k]);
                }
            }
        }
        if (deadline.tick()) {
            return late();
        }
    }
    for (size_t v = 0; v < V; ++v) {
        double* n = &normal[v * 3];
        const double len = std::sqrt(dot3(n, n));
        for (int k = 0; k < 3; ++k) {
            n[k] = len > 0.0 ? n[k] / len : 0.0;
        }
    }
    {
        std::vector<double> smooth = normal;
        for (size_t t = 0; t < T; ++t) {
            if (selected[t] == 0) {
                continue;
            }
            for (int k = 0; k < 3; ++k) {
                const uint32_t a = m.triangles[t * 3 + size_t(k)], b = m.triangles[t * 3 + size_t((k + 1) % 3)];
                for (int c = 0; c < 3; ++c) {
                    smooth[size_t(a) * 3 + size_t(c)] += normal[size_t(b) * 3 + size_t(c)];
                    smooth[size_t(b) * 3 + size_t(c)] += normal[size_t(a) * 3 + size_t(c)];
                }
            }
        }
        for (size_t v = 0; v < V; ++v) {
            double* n = &smooth[v * 3];
            const double len = std::sqrt(dot3(n, n));
            if (len > 0.0) {
                for (int k = 0; k < 3; ++k) {
                    normal[v * 3 + size_t(k)] = n[k] / len;
                }
            }
        }
    }
    // The mapping's frame.
    const double turn = plan.angle * 3.14159265358979323846 / 180.0, cs = std::cos(turn), sn = std::sin(turn);
    double centre[3];
    for (int k = 0; k < 3; ++k) {
        centroid[k] /= area_sum;
        centre[k] = 0.5 * (lo[k] + hi[k]);
    }
    double flat_normal[3] = {0, 0, 1};
    {
        const double len = std::sqrt(dot3(mean_normal, mean_normal));
        if (len > 1e-9 * area_sum) {
            for (int k = 0; k < 3; ++k) {
                flat_normal[k] = mean_normal[k] / len;
            }
        }
    }
    const mesh::cut::Frame flat = mesh::cut::make_frame(centroid, flat_normal);
    int around = 0;  // cylindrical: the axis the selection's normals lean on least
    for (int k = 1; k < 3; ++k) {
        if (leaning[k] < leaning[around]) {
            around = k;
        }
    }
    const int r1 = (around + 1) % 3, r2 = (around + 2) % 3;
    double mean_radius = 0.0;
    {
        size_t count = 0;
        for (size_t v = 0; v < V; ++v) {
            if (in_selection[v] != 0) {
                const double x = double(m.positions[v * 3 + size_t(r1)]) - centre[r1], y = double(m.positions[v * 3 + size_t(r2)]) - centre[r2];
                mean_radius += std::sqrt(x * x + y * y);
                ++count;
            }
        }
        mean_radius = count > 0 ? mean_radius / double(count) : 1.0;
    }
    const uint8_t* pixels = image.ptr();
    auto brightness = [&](double s, double t) {
        // Tiled; t runs up, the image's rows run down. Read between the pixel centres.
        const double x = (s - std::floor(s)) * double(width) - 0.5, y = (1.0 - (t - std::floor(t))) * double(height) - 0.5;
        const double fx = std::floor(x), fy = std::floor(y);
        const double ax = x - fx, ay = y - fy;
        const int64_t x0 = ((int64_t(fx) % width) + width) % width, x1 = (x0 + 1) % width;
        const int64_t y0 = ((int64_t(fy) % height) + height) % height, y1 = (y0 + 1) % height;
        const double top = pixels[y0 * width + x0] * (1.0 - ax) + pixels[y0 * width + x1] * ax;
        const double bottom = pixels[y1 * width + x0] * (1.0 - ax) + pixels[y1 * width + x1] * ax;
        const double value = (top * (1.0 - ay) + bottom * ay) / 255.0;
        return plan.invert ? 1.0 - value : value;
    };
    int64_t moved = 0;
    double largest = 0.0;
    for (size_t v = 0; v < V; ++v) {
        if (in_selection[v] == 0 || fixed[v] != 0) {
            continue;
        }
        double p[3];
        m.point(uint32_t(v), p);
        const double* n = &normal[v * 3];
        double s = 0.0, t = 0.0;
        if (plan.mapping == 0) {
            double q[3];
            for (int k = 0; k < 3; ++k) {
                q[k] = p[k] - flat.origin[k];
            }
            s = dot3(q, flat.u);
            t = dot3(q, flat.v);
        }
        else if (plan.mapping == 1) {
            // The world axis the normal leans on most; s to the right and t up, seen from outside.
            int axis = 0;
            for (int k = 1; k < 3; ++k) {
                if (std::fabs(n[k]) > std::fabs(n[axis])) {
                    axis = k;
                }
            }
            const double x = p[0] - centre[0], y = p[1] - centre[1], z = p[2] - centre[2];
            const bool positive = n[axis] >= 0.0;
            if (axis == 0) {
                s = positive ? -z : z;
                t = y;
            }
            else if (axis == 1) {
                s = x;
                t = positive ? -z : z;
            }
            else {
                s = positive ? x : -x;
                t = y;
            }
        }
        else {
            const double x = p[r1] - centre[r1], y = p[r2] - centre[r2];
            s = std::atan2(y, x) * mean_radius;
            t = p[around] - centre[around];
        }
        double ss = s, tt = t;
        if (plan.mapping != 2) {
            ss = cs * s + sn * t;
            tt = -sn * s + cs * t;
        }
        else {
            ss = s + turn * mean_radius;
        }
        const double by = plan.depth * brightness(ss / plan.tile + 0.5, tt / plan.tile + 0.5);
        if (by != 0.0) {
            for (int k = 0; k < 3; ++k) {
                m.positions[v * 3 + size_t(k)] = float(p[k] + by * n[k]);
            }
            ++moved;
            largest = std::max(largest, std::fabs(by));
        }
        if (deadline.tick()) {
            return late();
        }
    }
    // Must hold: every vertex that is not free is the input's to the bit.
    for (size_t v = 0; v < first_vertices; ++v) {
        if ((in_selection[v] == 0 || fixed[v] != 0) && std::memcmp(&m.positions[v * 3], &input.positions[v * 3], sizeof(float) * 3) != 0) {
            fail("Texture Extrude moved a vertex on the selection's border (internal error). Please report it.");
            return Ref<CadMesh>();
        }
    }
    phases.mark("move");
    const mesh::Summary before = mesh::summarize(*state);
    Ref<CadMesh> out = finish_op("Texture Extrude", "displace", std::move(m), started, false);
    phases.mark("finish");
    if (out.is_null()) {
        return out;
    }
    Dictionary checks = last_report["checks"];
    checks["border"] = "ok";
    const mesh::Summary after = mesh::summarize(out->get_state());
    if (before.closed && !after.closed) {
        checks["closed"] = "fail: the closed mesh came out open";
        last_report["checks"] = checks;
        last_warning = String();
        fail("Texture Extrude opened a closed mesh (internal error). Please report it.");
        return Ref<CadMesh>();
    }
    checks["closed"] = "ok";
    PackedStringArray warnings;
    if (!last_warning.is_empty()) {
        warnings.push_back(last_warning);
    }
    // Places where the result crosses itself: counted, and said whenever the count is known
    // (less what the body had before, when that could be counted too).
    const int64_t crossings = mesh::ops::crossings(out->get_state(), deadline);
    last_report["self_intersections"] = crossings;
    if (crossings > 0) {
        const int64_t were = mesh::ops::crossings(*state, deadline);
        const int64_t made = were > 0 ? crossings - were : crossings;
        if (made > 0) {
            warnings.push_back(mesh::ops::text("The extrusion crosses itself in " + mesh::ops::count_text(made, "place", "places") + "; lower the Depth."));
            checks["self_intersections"] = String("warn: the result crosses itself in ") + mesh::ops::text(mesh::ops::count_text(made, "new place", "new places"));
        }
        else {
            checks["self_intersections"] = "ok";
        }
    }
    else if (crossings == 0) {
        checks["self_intersections"] = "ok";
    }
    else {
        warnings.push_back("The extrusion was not tested for places where it crosses itself (the mesh is too large to test in 1 s); lower the Depth if it does.");
        checks["self_intersections"] = "warn: not tested in time";
    }
    last_report["checks"] = checks;
    last_report["moved_vertices"] = moved;
    last_report["max_displacement"] = largest;
    last_report["detail"] = plan.detail;
    phases.mark("crossings");
    last_report["phases"] = phases.ms;
    last_report["estimate"] = plan.seconds;
    last_report["ms"] = mesh::ops::now_ms() - started;
    last_warning = String("\n").join(warnings);
    return out;
}

}  // namespace holo_forge
