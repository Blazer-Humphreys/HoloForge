// Shared parts of the stage N2 mesh ops (see mesh_pmp.h): option reading, messages, and the
// conversion between a mesh body and pmp::SurfaceMesh.

#include "mesh_pmp.h"
#include "mesh_manifold.h"

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include "mesh_bvh.h"

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <exception>

using namespace godot;

namespace holo_forge::mesh
{

double distance_to_segment(const V3& p, const V3& a, const V3& b, double* along)
{
    const V3 d = b - a;
    const double l2 = dot(d, d);
    double t = l2 > 0.0 ? dot(p - a, d) / l2 : 0.0;
    t = std::min(std::max(t, 0.0), 1.0);
    if (along != nullptr) {
        *along = t;
    }
    return length(p - (a + d * t));
}

// ---------------------------------------------------------------- messages

double op_now_ms()
{
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

String op_text(const std::string& s)
{
    return String::utf8(s.c_str(), int64_t(s.size()));
}

namespace
{
/// An estimate that is over the limit, as text that reads as over the limit: two digits,
/// rounded up ("2.04" against a limit of 2 is "2.1", never "2").
std::string seconds_over(double estimate, double limit)
{
    if (!(estimate > 0.0) || !std::isfinite(estimate)) {
        return number_text(estimate);
    }
    const double unit = std::pow(10.0, std::floor(std::log10(estimate)) - 1.0);
    double value = std::ceil(estimate / unit - 1e-9) * unit;
    const std::string limit_text = number_text(limit);
    std::string out = number_text(value, value >= 100.0 ? "%.0f" : "%.2g");
    if (out == limit_text) {
        value += unit;
        out = number_text(value, value >= 100.0 ? "%.0f" : "%.2g");
    }
    return out;
}
}  // namespace

std::string too_slow_text(const char* title, double estimate, double limit, const char* hint)
{
    return std::string(title) + " would take about " + seconds_over(estimate, limit) + " s on this mesh (limit " + number_text(limit) + " s). " + hint;
}

std::string stopped_text(const char* title, double elapsed, double estimate, double limit, const char* hint)
{
    return std::string(title) + " would take about " + seconds_over(std::max(estimate, limit * (1.0 + 1e-9)), limit) + " s on this mesh (limit " + number_text(limit) + " s); it was stopped after " +
           number_text(elapsed, "%.2g") + " s, before a step that would have run past the limit. " + hint;
}

std::string timed_out_text(const char* title, double limit, const char* hint)
{
    return std::string(title) + " took longer than " + number_text(limit) + " s and was stopped. " + hint;
}

// (length_text: the shared one in mesh_data.cpp.)

double post_check_estimate(double triangles, bool self_intersections)
{
    double seconds = 1.5 * budget::estimate(budget::TOPOLOGY, triangles);
    if (self_intersections) {
        seconds += std::min(budget::SELF_INTERSECTION_SECONDS, budget::estimate(budget::BVH_BUILD, triangles) + budget::estimate(budget::SELF_INTERSECTIONS, triangles));
    }
    return seconds;
}

std::string library_error(const char* title, const char* what)
{
    return std::string(title) + " failed inside the mesh library: " + (what != nullptr ? what : "unknown error") + (what != nullptr && *what != 0 && what[std::char_traits<char>::length(what) - 1] == '.' ? "" : ".");
}

void note_untested_crossings(const char* title, const Dictionary& report, Dictionary& checks, PackedStringArray& warnings)
{
    const int64_t crossings = report.get("self_intersections", -1);
    if (crossings > 0 && !checks.has("self_intersections")) {
        const std::string text = std::string(title) + " gave a mesh that crosses itself in " + counted(uint64_t(crossings), "place", "places") +
                                 "; the input could not be tested in the time left, so some may have been there before.";
        checks["self_intersections"] = String("warn: ") + op_text(text);
        warnings.push_back(op_text(text));
    }
}

// ---------------------------------------------------------------- options

namespace
{
std::string value_text(double value, const char* unit)
{
    const std::string u = unit != nullptr ? unit : "";
    if (u == "m") {
        return length_text(value);
    }
    if (u == "deg") {
        return number_text(value) + "\xC2\xB0";
    }
    if (u == "%") {
        return number_text(value) + " %";
    }
    return number_text(value, "%.6g");
}
}  // namespace

bool OptionReader::has(const char* key) const
{
    return options.has(String(key));
}

double OptionReader::time_limit() const
{
    if (!has("time_limit")) {
        return clamp_time_limit(20.0);
    }
    const Variant v = options[String("time_limit")];
    if (v.get_type() != Variant::FLOAT && v.get_type() != Variant::INT) {
        return clamp_time_limit(20.0);
    }
    return clamp_time_limit(double(v));
}

double OptionReader::number(const char* key, const char* label, double fallback, double lo, double hi, const char* unit)
{
    double value = fallback;
    if (has(key)) {
        const Variant v = options[String(key)];
        if (v.get_type() != Variant::FLOAT && v.get_type() != Variant::INT) {
            refuse(std::string(label) + " must be a number.");
            return fallback;
        }
        value = double(v);
    }
    const double slack = 1e-9 * std::max(std::fabs(lo), std::fabs(hi));
    if (!(value == value) || value < lo - slack || value > hi + slack) {
        refuse(std::string(label) + " must be between " + value_text(lo, unit) + " and " + value_text(hi, unit) + ".");
        return fallback;
    }
    return std::min(std::max(value, lo), hi);
}

int64_t OptionReader::integer(const char* key, const char* label, int64_t fallback, int64_t lo, int64_t hi)
{
    double value = double(fallback);
    if (has(key)) {
        const Variant v = options[String(key)];
        if (v.get_type() != Variant::FLOAT && v.get_type() != Variant::INT) {
            refuse(std::string(label) + " must be a number.");
            return fallback;
        }
        value = double(v);
    }
    if (!(value == value) || value < double(lo) || value > double(hi) || value != std::floor(value)) {
        refuse(std::string(label) + " must be a whole number between " + with_commas(uint64_t(std::max<int64_t>(lo, 0))) + " and " + with_commas(uint64_t(std::max<int64_t>(hi, 0))) + ".");
        return fallback;
    }
    return int64_t(value);
}

bool OptionReader::flag(const char* key, const char* label, bool fallback)
{
    if (!has(key)) {
        return fallback;
    }
    const Variant v = options[String(key)];
    // true or false; 1 and 0 too (a checkbox stored as a number). Nothing else: 2 is not "on".
    if (v.get_type() == Variant::BOOL) {
        return bool(v);
    }
    if (v.get_type() == Variant::INT && (int64_t(v) == 0 || int64_t(v) == 1)) {
        return int64_t(v) == 1;
    }
    refuse(std::string(label) + " must be on or off.");
    return fallback;
}

int OptionReader::choice(const char* key, const char* label, std::initializer_list<const char*> names, int fallback)
{
    if (!has(key)) {
        return fallback;
    }
    const Variant v = options[String(key)];
    std::string listed;
    if (v.get_type() == Variant::STRING || v.get_type() == Variant::STRING_NAME) {
        const String wanted = v;
        int index = 0;
        for (const char* name : names) {
            if (wanted == String(name)) {
                return index;
            }
            ++index;
        }
    }
    for (const char* name : names) {
        listed += (listed.empty() ? "" : ", ") + std::string(name);
    }
    refuse(std::string(label) + " must be one of: " + listed + ".");
    return fallback;
}

bool triangle_list(const PackedInt32Array& tris, size_t triangle_count, std::vector<uint32_t>& out, std::string& error)
{
    out.clear();
    out.reserve(size_t(tris.size()));
    const int32_t* r = tris.ptr();
    for (int64_t i = 0; i < tris.size(); ++i) {
        if (r[i] < 0 || size_t(r[i]) >= triangle_count) {
            error = "Triangle " + std::to_string(r[i]) + " is not in the mesh (it has " + with_commas(triangle_count) + " triangles). Select the triangles again.";
            out.clear();
            return false;
        }
        out.push_back(uint32_t(r[i]));
    }
    std::sort(out.begin(), out.end());
    out.erase(std::unique(out.begin(), out.end()), out.end());
    return true;
}

std::vector<uint32_t> OptionReader::triangles(const char* key, size_t triangle_count, bool* given)
{
    std::vector<uint32_t> out;
    if (given != nullptr) {
        *given = false;
    }
    if (!has(key)) {
        return out;
    }
    const Variant v = options[String(key)];
    PackedInt32Array list;
    if (v.get_type() == Variant::PACKED_INT32_ARRAY) {
        list = v;
    }
    else if (v.get_type() == Variant::ARRAY) {
        const Array a = v;
        for (int64_t i = 0; i < a.size(); ++i) {
            if (a[i].get_type() != Variant::INT) {
                refuse("The triangle selection must hold triangle numbers.");
                return out;
            }
            list.push_back(int32_t(int64_t(a[i])));
        }
    }
    else if (v.get_type() == Variant::NIL) {
        return out;
    }
    else {
        refuse("The triangle selection must hold triangle numbers.");
        return out;
    }
    if (given != nullptr) {
        *given = true;
    }
    std::string error;
    if (!triangle_list(list, triangle_count, out, error)) {
        refuse(error);
    }
    return out;
}

// ---------------------------------------------------------------- mesh facts

double mean_edge_length(State& state)
{
    const MeshData& m = state.data;
    const Topology* topo = topology_of(state);
    const size_t E = topo->edge_count();
    if (E == 0) {
        return 0.0;
    }
    double sum = 0.0;
    for (size_t e = 0; e < E; ++e) {
        const uint32_t he = topo->edge_hes[topo->edge_first[e]];
        const uint32_t a = m.triangles[he], b = m.triangles[he - he % 3 + (he + 1) % 3];
        sum += length(point_of(m, a) - point_of(m, b));
    }
    return sum / double(E);
}

double mean_edge_length(State& state, const std::vector<uint32_t>& tris)
{
    const MeshData& m = state.data;
    const Topology* topo = topology_of(state);
    std::vector<uint8_t> seen(topo->edge_count(), 0);
    double sum = 0.0;
    size_t count = 0;
    for (const uint32_t t : tris) {
        for (uint32_t k = 0; k < 3; ++k) {
            const uint32_t he = t * 3 + k;
            const uint32_t e = topo->he_edge[he];
            if (e == NONE || seen[e]) {
                continue;
            }
            seen[e] = 1;
            sum += length(point_of(m, m.triangles[he]) - point_of(m, m.triangles[t * 3 + (k + 1) % 3]));
            ++count;
        }
    }
    return count > 0 ? sum / double(count) : 0.0;
}

std::string pmp_refusal(State& state)
{
    const MeshData& m = state.data;
    const Topology* topo = topology_of(state);
    if (topo->non_manifold_edges > 0) {
        return "The mesh has " + counted(uint64_t(topo->non_manifold_edges), "non-manifold edge", "non-manifold edges") + ". Run Stitch and Remove first.";
    }
    size_t twice = 0;
    for (size_t t = 0; t < m.triangle_count(); ++t) {
        const uint32_t* tri = &m.triangles[t * 3];
        twice += (tri[0] == tri[1] || tri[1] == tri[2] || tri[0] == tri[2]) ? 1 : 0;
    }
    if (twice > 0) {
        return "The mesh has " + counted(uint64_t(twice), "triangle that uses a corner twice", "triangles that use a corner twice") + ". Run Stitch and Remove first.";
    }
    if (topo->inconsistent_edges > 0) {
        return "The mesh has " + counted(uint64_t(topo->inconsistent_edges), "edge whose two triangles face opposite ways", "edges whose two triangles face opposite ways") + ". Run Stitch and Remove first.";
    }
    return std::string();
}

std::string far_refusal(State& state, const godot::Dictionary& options, double scale, const std::string& why)
{
    if (!(scale > 0.0)) {
        return std::string();
    }
    const ops::Options reader(options);
    return ops::too_far(state, reader.name(true), scale / 8.0, why);
}

double typical_edge(State& state)
{
    const size_t T = state.data.triangle_count();
    const double area = measures_of(state).area;
    return T > 0 && area > 0.0 ? std::sqrt(area / double(T) / 0.4330127018922193) : 0.0;
}

std::vector<uint8_t> boundary_vertices(State& state)
{
    const MeshData& m = state.data;
    const Topology* topo = topology_of(state);
    std::vector<uint8_t> flags(m.vertex_count(), 0);
    for (size_t e = 0; e < topo->edge_count(); ++e) {
        if (topo->uses(uint32_t(e)) == 1) {
            const uint32_t he = topo->edge_hes[topo->edge_first[e]];
            flags[m.triangles[he]] = 1;
            flags[m.triangles[he - he % 3 + (he + 1) % 3]] = 1;
        }
    }
    return flags;
}

std::vector<uint8_t> group_border_vertices(const MeshData& m)
{
    std::vector<uint32_t> first(m.vertex_count(), NONE);
    std::vector<uint8_t> flags(m.vertex_count(), 0);
    for (size_t t = 0; t < m.triangle_count(); ++t) {
        const uint32_t g = m.groups[t];
        for (int k = 0; k < 3; ++k) {
            const uint32_t v = m.triangles[t * 3 + size_t(k)];
            if (first[v] == NONE) {
                first[v] = g;
            }
            else if (first[v] != g) {
                flags[v] = 1;
            }
        }
    }
    return flags;
}

double group_border_length(State& state)
{
    const MeshData& m = state.data;
    const Topology* topo = topology_of(state);
    double sum = 0.0;
    for (size_t e = 0; e < topo->edge_count(); ++e) {
        const uint32_t first = topo->edge_first[e], last = topo->edge_first[e + 1];
        if (last - first < 2) {
            continue;
        }
        const uint32_t he = topo->edge_hes[first];
        const uint32_t g = m.groups[he / 3];
        bool border = false;
        for (uint32_t i = first + 1; i < last; ++i) {
            border = border || m.groups[topo->edge_hes[i] / 3] != g;
        }
        if (border) {
            sum += length(point_of(m, m.triangles[he]) - point_of(m, m.triangles[he - he % 3 + (he + 1) % 3]));
        }
    }
    return sum;
}

std::string counted(uint64_t count, const char* one, const char* many)
{
    return with_commas(count) + " " + (count == 1 ? one : many);
}

namespace
{
/// A number for a triangle by its corner positions, the same for every index order that runs
/// the same way round (and for -0 and 0).
uint64_t triangle_key(const MeshData& m, size_t t)
{
    uint32_t bits[3][3];
    for (int k = 0; k < 3; ++k) {
        for (int c = 0; c < 3; ++c) {
            const float value = m.positions[size_t(m.triangles[t * 3 + size_t(k)]) * 3 + size_t(c)] + 0.0f;
            std::memcpy(&bits[k][c], &value, sizeof(float));
        }
    }
    int low = 0;
    for (int k = 1; k < 3; ++k) {
        if (std::memcmp(bits[k], bits[low], sizeof(bits[0])) < 0) {
            low = k;
        }
    }
    uint64_t h = 0x9E3779B97F4A7C15ull;
    for (int k = 0; k < 3; ++k) {
        for (int c = 0; c < 3; ++c) {
            h = (h ^ bits[(low + k) % 3][c]) * 0x100000001B3ull;
            h ^= h >> 29;
        }
    }
    return h;
}
}  // namespace

Distance distance_at_points(State& from, State& to, const Deadline& deadline, size_t point_budget)
{
    Distance out;
    const MeshData& m = from.data;
    const MeshData& other = to.data;
    const TriBvh* bvh = bvh_of(to, &deadline);
    if (bvh == nullptr) {
        out.timed_out = true;
        return out;
    }
    std::vector<uint64_t> keys(other.triangle_count());
    for (size_t t = 0; t < keys.size(); ++t) {
        keys[t] = triangle_key(other, t);
    }
    std::sort(keys.begin(), keys.end());
    std::vector<uint32_t> changed;
    for (size_t t = 0; t < m.triangle_count(); ++t) {
        if (!std::binary_search(keys.begin(), keys.end(), triangle_key(m, t))) {
            changed.push_back(uint32_t(t));
        }
    }
    if (changed.empty() || deadline.expired()) {
        out.timed_out = !changed.empty();
        return out;
    }
    const size_t each = point_budget / changed.size();
    const int n = each >= 43 ? 8 : (each >= 26 ? 6 : (each >= 13 ? 4 : (each >= 8 ? 3 : 2)));
    double sum = 0.0, sum2 = 0.0;
    auto distance_of = [&](const V3& p) {
        const double at[3] = {p.x, p.y, p.z};
        uint32_t nearest = NONE;
        double q[3] = {0, 0, 0};
        bvh->nearest(at, std::numeric_limits<double>::infinity(), nearest, q);
        return nearest == NONE ? 0.0 : length(p - V3(q[0], q[1], q[2]));
    };
    auto note = [&](const V3& p, double d) {
        if (d > out.max) {
            out.max = d;
            out.max_point[0] = p.x;
            out.max_point[1] = p.y;
            out.max_point[2] = p.z;
        }
    };
    // The furthest lattice points, to climb from afterwards: the worst place of a triangle lies
    // where it crosses an edge of the other mesh, between the lattice points (a lattice cut 8
    // ways was seen to read 4 % low).
    struct Peak
    {
        uint32_t triangle;
        double u, v, d;  // the point is corner 0 x u + corner 1 x v + corner 2 x (1 - u - v)
    };
    const size_t kPeaks = 48;
    std::vector<Peak> peaks;
    auto probe = [&](uint32_t t, const V3 corner[3], double u, double v) {
        const V3 p = corner[0] * u + corner[1] * v + corner[2] * (1.0 - u - v);
        const double d = distance_of(p);
        note(p, d);
        sum += d;
        sum2 += d * d;
        ++out.samples;
        if (peaks.size() < kPeaks) {
            peaks.push_back({t, u, v, d});
        }
        else {
            size_t least = 0;
            for (size_t i = 1; i < peaks.size(); ++i) {
                least = peaks[i].d < peaks[least].d ? i : least;
            }
            if (d > peaks[least].d) {
                peaks[least] = {t, u, v, d};
            }
        }
    };
    std::vector<uint8_t> seen(m.vertex_count(), 0);
    for (const uint32_t t : changed) {
        V3 corner[3];
        for (int k = 0; k < 3; ++k) {
            corner[k] = point_of(m, m.triangles[size_t(t) * 3 + size_t(k)]);
        }
        for (int k = 0; k < 3; ++k) {
            const uint32_t v = m.triangles[size_t(t) * 3 + size_t(k)];
            if (!seen[v]) {
                seen[v] = 1;
                probe(t, corner, k == 0 ? 1.0 : 0.0, k == 1 ? 1.0 : 0.0);
            }
        }
        for (int i = 0; i <= n; ++i) {
            for (int j = 0; i + j <= n; ++j) {
                if (i == n || j == n || i + j == 0) {
                    continue;  // a corner
                }
                probe(t, corner, double(i) / double(n), double(j) / double(n));
            }
        }
        if (n == 2) {
            probe(t, corner, 1.0 / 3.0, 1.0 / 3.0);
        }
        if (deadline.tick()) {
            out.timed_out = true;
            return out;
        }
    }
    // Climb from each: steps across the triangle, halved when no neighbour is further.
    for (Peak& peak : peaks) {
        V3 corner[3];
        for (int k = 0; k < 3; ++k) {
            corner[k] = point_of(m, m.triangles[size_t(peak.triangle) * 3 + size_t(k)]);
        }
        double step = 0.5 / double(n);
        for (int round = 0; round < 40 && step > 1e-4; ++round) {
            static const double moves[6][2] = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}, {1, -1}, {-1, 1}};
            bool moved = false;
            for (const auto& move : moves) {
                double u = std::min(std::max(peak.u + move[0] * step, 0.0), 1.0), v = std::min(std::max(peak.v + move[1] * step, 0.0), 1.0);
                if (u + v > 1.0) {
                    const double over = u + v - 1.0;
                    u -= 0.5 * over;
                    v -= 0.5 * over;
                }
                const V3 p = corner[0] * u + corner[1] * v + corner[2] * (1.0 - u - v);
                const double d = distance_of(p);
                if (d > peak.d) {
                    peak.u = u;
                    peak.v = v;
                    peak.d = d;
                    note(p, d);
                    moved = true;
                }
            }
            if (!moved) {
                step *= 0.5;
            }
        }
        if (deadline.tick()) {
            out.timed_out = true;
            return out;
        }
    }
    if (out.samples > 0) {
        out.mean = sum / double(out.samples);
        out.rms = std::sqrt(sum2 / double(out.samples));
    }
    return out;
}

double group_border_deviation(State& a, State& b)
{
    typedef std::vector<std::pair<V3, V3>> Segments;
    auto border_edges = [](State& s, Segments& out) {
        const MeshData& m = s.data;
        const Topology* topo = topology_of(s);
        for (size_t e = 0; e < topo->edge_count(); ++e) {
            const uint32_t first = topo->edge_first[e], last = topo->edge_first[e + 1];
            if (last - first < 2) {
                continue;
            }
            const uint32_t he = topo->edge_hes[first];
            bool border = false;
            for (uint32_t i = first + 1; i < last; ++i) {
                border = border || m.groups[topo->edge_hes[i] / 3] != m.groups[he / 3];
            }
            if (border) {
                out.push_back({point_of(m, m.triangles[he]), point_of(m, m.triangles[he - he % 3 + (he + 1) % 3])});
            }
        }
    };
    Segments of_a, of_b;
    border_edges(a, of_a);
    border_edges(b, of_b);
    if (of_a.empty() && of_b.empty()) {
        return 0.0;
    }
    if (of_a.empty() || of_b.empty()) {
        return std::max(measures_of(a).diagonal, measures_of(b).diagonal);
    }
    auto one_way = [](const Segments& from, const Segments& to) {
        std::vector<subd::Box> boxes(to.size());
        for (size_t i = 0; i < to.size(); ++i) {
            const double p[3] = {to[i].first.x, to[i].first.y, to[i].first.z}, q[3] = {to[i].second.x, to[i].second.y, to[i].second.z};
            boxes[i].add(p);
            boxes[i].add(q);
        }
        subd::Bvh tree;
        tree.build(boxes);
        double worst = 0.0;
        for (const auto& edge : from) {
            const V3 samples[3] = {edge.first, (edge.first + edge.second) * 0.5, edge.second};
            for (const V3& p : samples) {
                const double q[3] = {p.x, p.y, p.z};
                double best2 = std::numeric_limits<double>::infinity();
                tree.nearest(q, best2, [&](int i, double& best) {
                    const double d = distance_to_segment(p, to[size_t(i)].first, to[size_t(i)].second);
                    best = std::min(best, d * d);
                });
                worst = std::max(worst, std::sqrt(best2));
            }
        }
        return worst;
    };
    return std::max(one_way(of_a, of_b), one_way(of_b, of_a));
}

size_t non_manifold_vertex_count(State& state)
{
    const MeshData& m = state.data;
    const Topology* topo = topology_of(state);
    const size_t T = m.triangle_count(), V = m.vertex_count();
    // Corners joined across the edges their triangles share: one set a fan.
    std::vector<uint32_t> parent(T * 3);
    for (size_t i = 0; i < parent.size(); ++i) {
        parent[i] = uint32_t(i);
    }
    auto find = [&](uint32_t x) {
        while (parent[x] != x) {
            parent[x] = parent[parent[x]];
            x = parent[x];
        }
        return x;
    };
    auto join = [&](uint32_t x, uint32_t y) {
        x = find(x);
        y = find(y);
        if (x != y) {
            parent[std::max(x, y)] = std::min(x, y);
        }
    };
    auto next_he = [](uint32_t he) { return he - he % 3 + (he + 1) % 3; };
    for (size_t e = 0; e < topo->edge_count(); ++e) {
        const uint32_t first = topo->edge_first[e], last = topo->edge_first[e + 1];
        for (uint32_t i = first; i + 1 < last; ++i) {
            const uint32_t h1 = topo->edge_hes[i], h2 = topo->edge_hes[size_t(i) + 1];
            if (m.triangles[h1] == m.triangles[h2]) {
                join(h1, h2);
                join(next_he(h1), next_he(h2));
            }
            else {
                join(h1, next_he(h2));
                join(next_he(h1), h2);
            }
        }
    }
    std::vector<uint8_t> fans(V, 0);
    for (size_t t = 0; t < T; ++t) {
        if (topo->he_edge[t * 3] == NONE) {
            continue;
        }
        for (uint32_t c = uint32_t(t * 3); c < uint32_t(t * 3 + 3); ++c) {
            if (find(c) == c && fans[m.triangles[c]] < 2) {
                ++fans[m.triangles[c]];
            }
        }
    }
    size_t count = 0;
    for (size_t v = 0; v < V; ++v) {
        count += fans[v] > 1 ? 1 : 0;
    }
    return count;
}

// ---------------------------------------------------------------- pmp

std::string build_pmp(const MeshData& m, const std::vector<uint32_t>* tris, pmp::SurfaceMesh& out, std::vector<uint32_t>& vertex_of)
{
    const size_t T = tris != nullptr ? tris->size() : m.triangle_count();
    auto triangle = [&](size_t i) { return &m.triangles[size_t(tris != nullptr ? (*tris)[i] : uint32_t(i)) * 3]; };
    std::vector<uint32_t> map(m.vertex_count(), NONE);
    for (size_t i = 0; i < T; ++i) {
        const uint32_t* t = triangle(i);
        map[t[0]] = map[t[1]] = map[t[2]] = 0;
    }
    vertex_of.clear();
    for (size_t v = 0; v < m.vertex_count(); ++v) {
        if (map[v] == 0) {
            map[v] = uint32_t(vertex_of.size());
            vertex_of.push_back(uint32_t(v));
        }
    }
    try {
        out.clear();
        out.reserve(vertex_of.size(), T * 3 / 2 + vertex_of.size() / 8 + 16, T);
        for (const uint32_t v : vertex_of) {
            const float* p = &m.positions[size_t(v) * 3];
            out.add_vertex(pmp::Point(p[0], p[1], p[2]));
        }
        for (size_t i = 0; i < T; ++i) {
            const uint32_t* t = triangle(i);
            out.add_triangle(pmp::Vertex(map[t[0]]), pmp::Vertex(map[t[1]]), pmp::Vertex(map[t[2]]));
        }
    }
    catch (const std::exception&) {
        return "The mesh has corners or edges where surfaces only touch (it is not manifold there). Run Stitch and Remove first.";
    }
    catch (...) {
        return "The mesh could not be read by the mesh library. Run Stitch and Remove first.";
    }
    return std::string();
}

void read_pmp(const pmp::SurfaceMesh& mesh, std::vector<float>& positions, std::vector<uint32_t>& triangles)
{
    positions.resize(mesh.n_vertices() * 3);
    size_t i = 0;
    for (const pmp::Vertex v : mesh.vertices()) {
        const pmp::Point& p = mesh.position(v);
        positions[i++] = p[0];
        positions[i++] = p[1];
        positions[i++] = p[2];
    }
    triangles.clear();
    triangles.reserve(mesh.n_faces() * 3);
    for (const pmp::Face f : mesh.faces()) {
        for (const pmp::Vertex v : mesh.vertices(f)) {
            triangles.push_back(uint32_t(v.idx()));
        }
    }
}

size_t mark_group_borders(pmp::SurfaceMesh& mesh, const pmp::FaceProperty<uint32_t>& group)
{
    auto vfeature = mesh.vertex_property<bool>("v:feature", false);
    auto efeature = mesh.edge_property<bool>("e:feature", false);
    size_t marked = 0;
    for (const pmp::Edge e : mesh.edges()) {
        const pmp::Face f0 = mesh.face(e, 0), f1 = mesh.face(e, 1);
        if (f0.is_valid() && f1.is_valid() && group[f0] != group[f1]) {
            efeature[e] = true;
            vfeature[mesh.vertex(e, 0)] = true;
            vfeature[mesh.vertex(e, 1)] = true;
            ++marked;
        }
    }
    return marked;
}

}  // namespace holo_forge::mesh
