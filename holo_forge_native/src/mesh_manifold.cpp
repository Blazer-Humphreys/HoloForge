#include "mesh_manifold.h"

#include "cad_mesh.h"
#include "mesh_bvh.h"
#include "mesh_pmp.h"

#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>

using namespace godot;

namespace holo_forge::mesh::ops
{

double now_ms()
{
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

String text(const std::string& s)
{
    return String::utf8(s.c_str(), int64_t(s.size()));
}

std::string plain(const String& s)
{
    const CharString utf8 = s.utf8();
    return std::string(utf8.get_data(), size_t(utf8.length()));
}

std::string plain_number(double value, int digits)
{
    if (!std::isfinite(value)) {
        return "a value that is not a number";
    }
    if (value == 0.0) {
        return "0";
    }
    const double size = std::fabs(value);
    int exponent = int(std::floor(std::log10(size)));
    // Rounded to `digits` significant digits first (9999.6 is 10,000, not 9999.6).
    const double unit = std::pow(10.0, double(exponent - digits + 1));
    double rounded = std::round(size / unit) * unit;
    if (rounded >= std::pow(10.0, double(exponent + 1))) {
        ++exponent;
    }
    std::string body;
    if (exponent >= digits - 1 && rounded < 1.8e19) {
        // No decimals left: a whole number (with thousands separators from 10,000 on).
        const uint64_t whole = uint64_t(std::llround(rounded));
        body = whole >= 10000 ? with_commas(whole) : std::to_string(whole);
    }
    else if (exponent >= digits - 1) {
        char text[64];
        std::snprintf(text, sizeof(text), "%.0f", rounded);
        body = text;
    }
    else {
        const int decimals = std::min(digits - 1 - exponent, 30);
        char text[96];
        std::snprintf(text, sizeof(text), "%.*f", decimals, rounded);
        body = text;
        // Trailing zeros after the point say nothing.
        while (!body.empty() && body.back() == '0') {
            body.pop_back();
        }
        if (!body.empty() && body.back() == '.') {
            body.pop_back();
        }
    }
    return (value < 0.0 ? "-" : "") + body;
}

std::string length_text(double meters)
{
    const double size = std::fabs(meters);
    if (size >= 1000.0) {
        return plain_number(meters / 1000.0) + " km";
    }
    if (size >= 10.0) {
        return plain_number(meters) + " m";
    }
    return plain_number(meters * 1e3) + " mm";
}

double float_step(double reach)
{
    const float at = float(std::fabs(reach));
    return double(std::nextafter(at, std::numeric_limits<float>::infinity())) - double(at);
}

Place place_of(State& state)
{
    Place place;
    const Measures& ms = measures_of(state);
    if (!ms.any) {
        return place;
    }
    double centre2 = 0.0;
    for (int k = 0; k < 3; ++k) {
        place.reach = std::max(place.reach, std::max(std::fabs(ms.lo[k]), std::fabs(ms.hi[k])));
        const double c = 0.5 * (ms.lo[k] + ms.hi[k]);
        centre2 += c * c;
    }
    place.distance = std::sqrt(centre2);
    place.step = float_step(place.reach);
    place.diagonal = ms.diagonal;
    return place;
}

std::string too_far(State& state, const std::string& name_start, double finest, const std::string& why)
{
    const Place place = place_of(state);
    if (!(place.step > finest)) {
        return std::string();
    }
    return name_start + " is " + length_text(place.distance) + " from the origin, where positions are stored only to about " + length_text(place.step) + ": " + why +
           ". Move it nearer the origin first.";
}

std::string past_limit(State& state, const char* title, double grow, const std::string& name)
{
    const Measures& ms = measures_of(state);
    if (!ms.any) {
        return std::string();
    }
    double reach = 0.0;
    for (int k = 0; k < 3; ++k) {
        reach = std::max(reach, std::max(std::fabs(ms.lo[k]), std::fabs(ms.hi[k])));
    }
    // (One float32 step of room: the result's points are rounded to it.)
    if (!(reach + std::max(grow, 0.0) + float_step(reach) > budget::MAX_COORDINATE)) {
        return std::string();
    }
    return std::string(title) + " would put the mesh more than " + with_commas(uint64_t(budget::MAX_COORDINATE / 1000.0)) +
           " km from the origin, farther than a mesh body can be. Move " + name + " nearer the origin first.";
}

std::string rounding_note(State& state, const std::string& name_start)
{
    const Place place = place_of(state);
    if (!(place.diagonal > 0.0) || !(place.step > 1e-4 * place.diagonal)) {
        return std::string();
    }
    return name_start + " is " + length_text(place.distance) + " from the origin, where positions are stored only to about " + length_text(place.step) + " (" +
           plain_number(100.0 * place.step / place.diagonal, 2) + " % of its size), so the result is rounded by about that much. Move it nearer the origin first for an exact result.";
}

std::string count_text(int64_t count, const char* one, const char* many)
{
    return with_commas(uint64_t(count < 0 ? 0 : count)) + " " + (count == 1 ? one : many);
}

std::string share_text(double share)
{
    const double percent = 100.0 * share;
    if (percent < 0.01) {
        return "Less than 0.01 %";
    }
    return "About " + plain_number(percent, 2) + " %";
}

int64_t crossings(State& state, const Deadline& deadline)
{
    return self_intersections_within(state, std::min(budget::SELF_INTERSECTION_SECONDS, deadline.remaining()), nullptr);
}

std::string too_slow(const char* title, double seconds, double limit, const char* hint)
{
    return std::string(title) + " would take about " + (seconds < 10.0 ? plain_number(seconds, 2) : plain_number(std::round(seconds), 6)) + " s on this mesh (limit " + plain_number(limit) + " s). " + hint;
}

std::string timed_out(const char* title, double limit, const char* hint)
{
    return std::string(title) + " took longer than " + plain_number(limit) + " s and was stopped. " + hint;
}

std::string unique_name(const std::string& base, std::unordered_set<std::string>& taken)
{
    std::string name = short_group_name(base.empty() ? std::string("g") : base);
    for (int k = 2; taken.count(name) != 0; ++k) {
        const std::string tail = " (" + std::to_string(k) + ")";
        std::string head = base.empty() ? std::string("g") : base;
        if (head.size() + tail.size() > budget::MAX_GROUP_NAME_BYTES) {
            // Shortened so that the number still fits (never cut inside a UTF-8 character).
            size_t keep = budget::MAX_GROUP_NAME_BYTES - tail.size();
            while (keep > 0 && (static_cast<unsigned char>(head[keep]) & 0xC0) == 0x80) {
                --keep;
            }
            head = head.substr(0, keep);
        }
        name = head + tail;
    }
    taken.insert(name);
    return name;
}

std::string numbered_name(const char* prefix, const std::vector<std::string>& names)
{
    for (int k = 0;; ++k) {
        const std::string name = std::string(prefix) + std::to_string(k);
        if (std::find(names.begin(), names.end(), name) == names.end()) {
            return name;
        }
    }
}

Dictionary summary_dict(const Summary& s, bool output)
{
    Dictionary d;
    d["triangles"] = s.triangles;
    d["vertices"] = s.vertices;
    d["groups"] = s.groups;
    d["closed"] = s.closed;
    d["boundary_edges"] = s.boundary_edges;
    d["volume"] = s.volume;
    d["area"] = s.area;
    if (output) {
        d["non_manifold_edges"] = s.non_manifold_edges;
        d["degenerate_triangles"] = s.degenerate_triangles;
        d["components"] = s.components;
    }
    return d;
}

bool Options::has(const char* key) const
{
    const Variant k = String(key);
    return dict.has(k) && dict.get(k, Variant()).get_type() != Variant::NIL;
}

double Options::number(const char* key, const char* label, double fallback)
{
    if (!has(key)) {
        return fallback;
    }
    const Variant value = dict.get(String(key), Variant());
    if (value.get_type() != Variant::FLOAT && value.get_type() != Variant::INT) {
        fail(std::string(label) + " must be a number.");
        return fallback;
    }
    const double x = double(value);
    if (!std::isfinite(x)) {
        fail(std::string(label) + " must be a number.");
        return fallback;
    }
    return x;
}

bool Options::flag(const char* key, const char* label, bool fallback)
{
    if (!has(key)) {
        return fallback;
    }
    const Variant value = dict.get(String(key), Variant());
    if (value.get_type() != Variant::BOOL) {
        fail(std::string(label) + " must be on or off.");
        return fallback;
    }
    return bool(value);
}

int Options::choice(const char* key, const char* label, std::initializer_list<const char*> words, int fallback)
{
    if (!has(key)) {
        return fallback;
    }
    const Variant value = dict.get(String(key), Variant());
    std::string list;
    if (value.get_type() == Variant::STRING || value.get_type() == Variant::STRING_NAME) {
        const std::string word = plain(String(value));
        int index = 0;
        for (const char* w : words) {
            if (word == w) {
                return index;
            }
            ++index;
        }
    }
    for (const char* w : words) {
        list += (list.empty() ? "" : ", ") + std::string(w);
    }
    fail(std::string(label) + " must be one of: " + list + ".");
    return fallback;
}

bool Options::vector(const char* key, const char* label, double out[3])
{
    if (!has(key)) {
        return false;
    }
    const Variant value = dict.get(String(key), Variant());
    if (value.get_type() != Variant::VECTOR3) {
        fail(std::string(label) + " must be a point (three numbers).");
        return false;
    }
    const Vector3 v = value;
    if (!std::isfinite(v.x) || !std::isfinite(v.y) || !std::isfinite(v.z)) {
        fail(std::string(label) + " must be a point (three numbers).");
        return false;
    }
    out[0] = v.x;
    out[1] = v.y;
    out[2] = v.z;
    return true;
}

std::string Options::name(bool sentence_start) const
{
    if (has("name")) {
        const Variant value = dict.get(String("name"), Variant());
        if (value.get_type() == Variant::STRING || value.get_type() == Variant::STRING_NAME) {
            const std::string given = plain(String(value));
            if (!given.empty()) {
                return given;
            }
        }
    }
    return sentence_start ? "The body" : "the body";
}

double Options::time_limit()
{
    return clamp_time_limit(number("time_limit", "Time Limit", 20.0));
}

bool Options::skip_estimate()
{
    return flag("skip_estimate", "Skip Estimate", false);
}

bool Options::range(const char* label, double value, double lo, double hi, bool length)
{
    // (Each bound gives by a millionth of its own size.)
    if (value >= lo - 1e-6 * std::fabs(lo) && value <= hi + 1e-6 * std::fabs(hi)) {
        return true;
    }
    if (length) {
        fail(std::string(label) + " must be between " + length_text(lo) + " and " + length_text(hi) + ".");
    }
    else {
        fail(std::string(label) + " must be between " + plain_number(lo, 6) + " and " + plain_number(hi, 6) + ".");
    }
    return false;
}

}  // namespace holo_forge::mesh::ops

namespace holo_forge::mesh::mf
{

std::string status_text(Status status, const char* title)
{
    const char* what = "an unknown error";
    switch (status) {
        case Status::NoError:
            return std::string();
        case Status::NonFiniteVertex:
            what = "a vertex is not a finite number";
            break;
        case Status::NotManifold:
            what = "the mesh is not a closed solid (an edge without exactly two triangles that run it opposite ways)";
            break;
        case Status::VertexOutOfBounds:
            what = "a triangle points at a vertex that is not there";
            break;
        case Status::PropertiesWrongLength:
        case Status::MissingPositionProperties:
        case Status::MergeVectorsDifferentLengths:
        case Status::MergeIndexOutOfBounds:
        case Status::TransformWrongLength:
        case Status::RunIndexWrongLength:
        case Status::FaceIDWrongLength:
            what = "the mesh arrays handed over have the wrong sizes (internal error)";
            break;
        case Status::InvalidConstruction:
            what = "the solid could not be built";
            break;
        case Status::ResultTooLarge:
            what = "the result is too large";
            break;
        case Status::InvalidTangents:
            what = "the tangents are not valid (internal error)";
            break;
        case Status::Cancelled:
            what = "it was stopped";
            break;
    }
    return std::string(title) + " failed inside the mesh library: " + what + ".";
}

Watchdog::Watchdog(const manifold::ExecutionContext& context, const Deadline& deadline) : ctx(context)
{
    const double seconds = std::max(deadline.remaining(), 0.0);
    thread = std::thread([this, seconds] {
        std::unique_lock<std::mutex> held(lock);
        if (!changed.wait_for(held, std::chrono::duration<double>(seconds), [this] { return done; })) {
            ctx.Cancel();
        }
    });
}

Watchdog::~Watchdog()
{
    {
        std::lock_guard<std::mutex> held(lock);
        done = true;
    }
    changed.notify_all();
    if (thread.joinable()) {
        thread.join();
    }
}

std::string unfit(State& state, const std::string& name)
{
    if (state.data.triangle_count() == 0) {
        return name + " has no triangles.";
    }
    const Topology* topo = topology_of(state);
    if (topo->edge_count() == 0) {
        return name + " has no triangles with area. Run Stitch and Remove first.";
    }
    if (topo->boundary_edges > 0) {
        return name + " is not closed (" + ops::count_text(topo->boundary_edges, "open edge", "open edges") + "). Close Holes or Wrap it first.";
    }
    if (topo->non_manifold_edges > 0) {
        return name + " has " + ops::count_text(topo->non_manifold_edges, "edge", "edges") + " that more than two triangles share. Run Stitch and Remove first.";
    }
    if (topo->inconsistent_edges > 0) {
        return name + " has triangles that face the wrong way (at " + ops::count_text(topo->inconsistent_edges, "edge", "edges") + "). Run Reverse Normal first.";
    }
    int64_t inverted = 0;
    for (const Component& c : nested_components_of(state)->list) {
        inverted += c.inverted ? 1 : 0;
    }
    if (inverted > 0) {
        return name + " has " + ops::count_text(inverted, "part that is", "parts that are") + " inside-out. Reverse Normal can fix " + (inverted == 1 ? "it." : "them.");
    }
    return std::string();
}

manifold::MeshGL64 to_gl(const MeshData& mesh, uint32_t run_id, uint32_t group_offset, bool by_triangle)
{
    manifold::MeshGL64 gl;
    gl.numProp = 3;
    gl.tolerance = 0.0;  // measured: with 0 no triangle is dropped (work order 2.9)
    const size_t V = mesh.vertex_count(), T = mesh.triangle_count();
    gl.vertProperties.resize(V * 3);
    for (size_t i = 0; i < V * 3; ++i) {
        gl.vertProperties[i] = double(mesh.positions[i]);
    }
    gl.triVerts.reserve(T * 3);
    gl.faceID.reserve(T);
    for (size_t t = 0; t < T; ++t) {
        const uint32_t* tri = &mesh.triangles[t * 3];
        if (tri[0] == tri[1] || tri[1] == tri[2] || tri[0] == tri[2]) {
            continue;
        }
        gl.triVerts.push_back(tri[0]);
        gl.triVerts.push_back(tri[1]);
        gl.triVerts.push_back(tri[2]);
        gl.faceID.push_back(by_triangle ? uint32_t(t) : mesh.groups[t] + group_offset);
    }
    gl.runIndex = {0u, uint32_t(gl.triVerts.size())};
    gl.runOriginalID = {run_id};
    return gl;
}

bool from_gl(const manifold::MeshGL64& gl, const std::vector<uint32_t>& own_runs, const std::vector<std::string>& names, const std::string& foreign_name, Import& out,
             std::string& error)
{
    out = Import();
    const size_t stride = size_t(gl.numProp);
    if (stride < 3 || gl.vertProperties.size() % stride != 0 || gl.triVerts.size() % 3 != 0) {
        error = "the mesh library gave arrays of the wrong sizes";
        return false;
    }
    const size_t V = gl.vertProperties.size() / stride, T = gl.triVerts.size() / 3;
    if (V > budget::MAX_VERTICES_MESH || T > budget::MAX_TRIANGLES_MESH) {
        error = "the result has " + with_commas(T) + " triangles and " + with_commas(V) + " vertices; mesh bodies take up to " + with_commas(budget::MAX_TRIANGLES_MESH) +
                " of each";
        return false;
    }
    if (!gl.faceID.empty() && gl.faceID.size() != T) {
        error = "the mesh library gave face ids of the wrong length";
        return false;
    }
    if (gl.runIndex.size() != gl.runOriginalID.size() + 1 && !(gl.runIndex.empty() && gl.runOriginalID.empty())) {
        error = "the mesh library gave runs of the wrong length";
        return false;
    }
    MeshData& m = out.mesh;
    m.positions.resize(V * 3);
    for (size_t v = 0; v < V; ++v) {
        for (size_t k = 0; k < 3; ++k) {
            m.positions[v * 3 + k] = float(gl.vertProperties[v * stride + k]);
        }
    }
    // Vertices Manifold lists apart but says are one (it does that when vertices carry more
    // than positions; ours do not, so this is normally empty).
    std::vector<uint32_t> merged;
    if (!gl.mergeFromVert.empty() && gl.mergeFromVert.size() == gl.mergeToVert.size()) {
        merged.resize(V);
        for (size_t v = 0; v < V; ++v) {
            merged[v] = uint32_t(v);
        }
        auto find = [&](uint32_t x) {
            while (merged[x] != x) {
                merged[x] = merged[merged[x]];
                x = merged[x];
            }
            return x;
        };
        for (size_t i = 0; i < gl.mergeFromVert.size(); ++i) {
            if (gl.mergeFromVert[i] >= V || gl.mergeToVert[i] >= V) {
                error = "the mesh library gave a merge list that points past the vertices";
                return false;
            }
            const uint32_t a = find(uint32_t(gl.mergeFromVert[i])), b = find(uint32_t(gl.mergeToVert[i]));
            if (a != b) {
                merged[std::max(a, b)] = std::min(a, b);
            }
        }
        for (size_t v = 0; v < V; ++v) {
            merged[v] = find(uint32_t(v));
        }
    }
    m.triangles.resize(T * 3);
    for (size_t i = 0; i < T * 3; ++i) {
        const uint64_t v = gl.triVerts[i];
        if (v >= V) {
            error = "the mesh library gave a triangle that points past the vertices";
            return false;
        }
        m.triangles[i] = merged.empty() ? uint32_t(v) : merged[size_t(v)];
    }
    const uint32_t foreign_group = uint32_t(names.size());
    m.groups.assign(T, foreign_group);
    out.foreign.assign(T, 1);
    out.run.assign(T, NONE);
    const size_t runs = gl.runOriginalID.size();
    for (size_t r = 0; r < runs; ++r) {
        const size_t first = size_t(gl.runIndex[r]) / 3, last = size_t(gl.runIndex[r + 1]) / 3;
        if (first > last || last > T) {
            error = "the mesh library gave a run that points past the triangles";
            return false;
        }
        const auto own = std::find(own_runs.begin(), own_runs.end(), gl.runOriginalID[r]);
        if (own == own_runs.end()) {
            continue;
        }
        if (gl.faceID.empty()) {
            error = "the mesh library lost the face group ids";
            return false;
        }
        for (size_t t = first; t < last; ++t) {
            const uint64_t id = gl.faceID[t];
            if (id >= names.size()) {
                error = "the mesh library gave a face group id that no input has";
                return false;
            }
            m.groups[t] = uint32_t(id);
            out.foreign[t] = 0;
            out.run[t] = uint32_t(own - own_runs.begin());
        }
    }
    for (size_t t = 0; t < T; ++t) {
        out.foreign_triangles += out.foreign[t];
    }
    m.group_names = names;
    m.group_names.push_back(foreign_name);
    return true;
}

}  // namespace holo_forge::mesh::mf

namespace holo_forge
{

namespace
{
/// Remesh, Smooth, Reduce and Close Holes (team N2's ops) refuse a body too far from the origin
/// before any work, through mesh::far_refusal at the length each works at. The same problem for
/// a panel, before the op runs: {"problem": sentence} when far, {} when not. (The lengths and
/// reasons are the ops' own; Remesh's from its options as the op reads them.)
Dictionary pmp_far_defaults(mesh::State& state, const String& method, const Dictionary& options)
{
    Dictionary out;
    double scale = mesh::typical_edge(state);
    std::string why;
    if (method == "smooth") {
        why = "too coarse to smooth edges of " + mesh::length_text(scale);
    }
    else if (method == "reduce") {
        why = "too coarse for its edges of " + mesh::length_text(scale);
    }
    else if (method == "close_holes") {
        why = "too coarse to fill between edges of " + mesh::length_text(scale);
    }
    else {
        // Remesh: the finest edge it is asked for, or the body's own when that is finer.
        const double D = mesh::measures_of(state).diagonal;
        const size_t T = state.data.triangle_count();
        auto number = [&](const char* key, double fallback) {
            if (!options.has(key)) {
                return fallback;
            }
            const Variant v = options[key];
            return v.get_type() == Variant::FLOAT || v.get_type() == Variant::INT ? double(v) : fallback;
        };
        double mean_in = mesh::mean_edge_length(state);
        if (options.has("triangles") && options["triangles"].get_type() == Variant::PACKED_INT32_ARRAY) {
            const PackedInt32Array given = options["triangles"];
            std::vector<uint32_t> tris;
            for (int64_t i = 0; i < given.size(); ++i) {
                if (given[i] >= 0 && size_t(given[i]) < T) {
                    tris.push_back(uint32_t(given[i]));
                }
            }
            if (!tris.empty() && tris.size() < T) {
                mean_in = mesh::mean_edge_length(state, tris);
            }
        }
        const bool adaptive = options.has("mode") && String(options["mode"]) == "adaptive";
        const double density = number("density", 0.5);
        const double edge_length = number("edge_length", 0.0);
        const double max_edge = number("max_edge", D / 50.0);
        const double min_edge = number("min_edge", std::min(D / 1000.0, 0.5 * max_edge));
        const double length = edge_length != 0.0 ? edge_length : mean_in * std::pow(2.0, 2.0 - 4.0 * density);
        const double finest = adaptive ? min_edge : length;
        scale = std::min(finest, mean_in);
        why = scale < mean_in ? (adaptive ? "too coarse for a Minimum Edge of " : "too coarse for edges of ") + mesh::length_text(scale)
                              : "too coarse for its edges of " + mesh::length_text(scale);
    }
    const std::string far = mesh::far_refusal(state, options, scale, why);
    if (!far.empty()) {
        out["problem"] = mesh::ops::text(far);
    }
    return out;
}
}  // namespace

// The one extra method beyond contract C4 (Stage N3): what a panel needs before the op runs.
Dictionary CadMesh::op_defaults(const String& method, const Dictionary& options)
{
    // (A plain query: it leaves get_last_error() and the report alone.)
    if (is_null()) {
        return Dictionary();
    }
    if (method == "wrap") {
        return mesh::wrap_defaults(*state, options, false);
    }
    if (method == "rebuild") {
        return mesh::wrap_defaults(*state, options, true);
    }
    if (method == "shell") {
        return mesh::shell_defaults(*state, options);
    }
    if (method == "plane_cut") {
        return mesh::plane_cut_defaults(*state, options);
    }
    if (method == "displace") {
        return mesh::displace_defaults(*state, options);
    }
    if (method == "boolean") {
        return mesh::boolean_defaults(*state, options);
    }
    if (method == "remesh" || method == "smooth" || method == "reduce" || method == "close_holes") {
        return pmp_far_defaults(*state, method, options);
    }
    return Dictionary();
}

}  // namespace holo_forge
