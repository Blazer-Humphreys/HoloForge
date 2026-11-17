#pragma once

// Shared parts of the Mesh workspace's own ops and its pmp-library and meshoptimizer ops (work
// order stage N2: Remesh, Reduce, Close Holes, Smooth, Stitch and Remove, Reverse Normal, the
// face group tools): reading an op's options with range refusals, the sentences every op uses
// for its time bound, small vector math, and the way a mesh body becomes a pmp::SurfaceMesh
// and comes back.
//
// pmp has a class named Handle and OpenCASCADE a macro Handle(Class): a file that includes this
// header must not include an OpenCASCADE header before it (cad_mesh.h only names CadShape).

#include "mesh_budget.h"
#include "mesh_data.h"
#include "mesh_deadline.h"

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <pmp/surface_mesh.h>

#include <cmath>
#include <cstdint>
#include <initializer_list>
#include <string>
#include <vector>

namespace holo_forge::mesh
{

// ---------------------------------------------------------------- small vector math (doubles)

struct V3
{
    double x = 0.0, y = 0.0, z = 0.0;

    V3() = default;
    V3(double x, double y, double z) : x(x), y(y), z(z)
    {
    }
    explicit V3(const double* p) : x(p[0]), y(p[1]), z(p[2])
    {
    }
    explicit V3(const float* p) : x(p[0]), y(p[1]), z(p[2])
    {
    }
    double operator[](int k) const
    {
        return k == 0 ? x : (k == 1 ? y : z);
    }
    V3 operator+(const V3& o) const
    {
        return {x + o.x, y + o.y, z + o.z};
    }
    V3 operator-(const V3& o) const
    {
        return {x - o.x, y - o.y, z - o.z};
    }
    V3 operator*(double s) const
    {
        return {x * s, y * s, z * s};
    }
    V3& operator+=(const V3& o)
    {
        x += o.x;
        y += o.y;
        z += o.z;
        return *this;
    }
};
inline double dot(const V3& a, const V3& b)
{
    return a.x * b.x + a.y * b.y + a.z * b.z;
}
inline V3 cross(const V3& a, const V3& b)
{
    return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}
inline double length(const V3& a)
{
    return std::sqrt(dot(a, a));
}
inline V3 normalized(const V3& a)
{
    const double l = length(a);
    return l > 0.0 ? a * (1.0 / l) : V3();
}
inline V3 point_of(const MeshData& m, uint32_t vertex)
{
    return V3(&m.positions[size_t(vertex) * 3]);
}
/// (b - a) x (c - a) of a stored triangle: twice its area along its outward normal.
inline V3 triangle_cross(const MeshData& m, size_t t)
{
    const V3 a = point_of(m, m.triangles[t * 3]), b = point_of(m, m.triangles[t * 3 + 1]), c = point_of(m, m.triangles[t * 3 + 2]);
    return cross(b - a, c - a);
}
/// The distance from p to the segment a b.
double distance_to_segment(const V3& p, const V3& a, const V3& b, double* along = nullptr);

// ---------------------------------------------------------------- messages

double op_now_ms();
godot::String op_text(const std::string& s);
/// "<Title> would take about <n> s on this mesh (limit <limit> s). <hint>"
std::string too_slow_text(const char* title, double estimate, double limit, const char* hint);
/// "<Title> took longer than <limit> s and was stopped. <hint>" (only when the limit has passed).
std::string timed_out_text(const char* title, double limit, const char* hint);
/// For an op that stops before a step it cannot interrupt: "<Title> would take about <n> s on
/// this mesh (limit <limit> s); it was stopped after <t> s, before a step that would have run
/// past the limit. <hint>". `estimate` is the time the whole op would have taken.
std::string stopped_text(const char* title, double elapsed, double estimate, double limit, const char* hint);
/// A length for a message: millimetres ("0.25 mm").
// (length_text(meters) is declared in mesh_data.h.)

/// What the checks every op result gets cost (edge topology, components, the hierarchy and the
/// self-intersection test, which is itself cut off after SELF_INTERSECTION_SECONDS), in seconds.
double post_check_estimate(double triangles, bool self_intersections);

// ---------------------------------------------------------------- options

/// Reads an op's options. A missing key gives the default; a value of the wrong kind or out of
/// range is refused: the first problem is kept as one sentence ("<Field> must be between <a>
/// and <b>."), nothing is clamped in silence.
class OptionReader
{
public:
    explicit OptionReader(const godot::Dictionary& options) : options(options)
    {
    }
    bool ok() const
    {
        return problem.empty();
    }
    const std::string& error() const
    {
        return problem;
    }
    void refuse(const std::string& sentence)
    {
        if (problem.empty()) {
            problem = sentence;
        }
    }
    bool has(const char* key) const;
    /// options.time_limit in seconds: 20 by default, kept within 0.05 .. 120.
    double time_limit() const;
    /// A number within lo..hi. unit: "" (plain), "m" (a length, shown in mm), "deg", "%".
    double number(const char* key, const char* label, double fallback, double lo, double hi, const char* unit = "");
    int64_t integer(const char* key, const char* label, int64_t fallback, int64_t lo, int64_t hi);
    bool flag(const char* key, const char* label, bool fallback);
    /// The index of the chosen name; the names are listed in the refusal.
    int choice(const char* key, const char* label, std::initializer_list<const char*> names, int fallback);
    /// Triangle ids under `key` (a PackedInt32Array), sorted, each once. Ids outside the mesh
    /// are refused. given says whether the key was there at all.
    std::vector<uint32_t> triangles(const char* key, size_t triangle_count, bool* given = nullptr);

private:
    const godot::Dictionary& options;
    std::string problem;
};

/// Triangle ids of a PackedInt32Array, sorted, each once; false with a sentence when one is
/// outside the mesh.
bool triangle_list(const godot::PackedInt32Array& tris, size_t triangle_count, std::vector<uint32_t>& out, std::string& error);

// ---------------------------------------------------------------- mesh facts the ops share

/// Mean length of the mesh's edges (each edge once). 0 for a mesh without edges.
double mean_edge_length(State& state);
/// The same over the edges of some triangles only.
double mean_edge_length(State& state, const std::vector<uint32_t>& tris);

/// "" when a pmp::SurfaceMesh can hold the mesh, else the refusal: edges more than two
/// triangles share, neighbours that face opposite ways, triangles that name a corner twice.
std::string pmp_refusal(State& state);

/// The refusal for a body so far from the origin that its positions (float32) step by more
/// than an eighth of `scale`, the length the op works at: "<Name> is 30 km from the origin,
/// where positions are stored only to about 3.906 mm: <why>. Move it nearer the origin first."
/// (options.name gives the name); "" when it is near enough. Past that the ops make triangles
/// without area out of rounding, and Remesh's library passes, which cannot be stopped, split
/// edges whose middles round onto their ends (a 10 mm ball 30 km out: 22 s against a 2 s limit).
std::string far_refusal(State& state, const godot::Dictionary& options, double scale, const std::string& why);
/// The edge of an equal-sided triangle of the mesh's mean triangle area: a mean edge length to
/// judge by that costs nothing once the mesh's measures are known (a refusal before any work).
double typical_edge(State& state);

/// Per vertex: 1 when the vertex lies on an open edge.
std::vector<uint8_t> boundary_vertices(State& state);
/// Per vertex: 1 when its triangles lie in two or more groups.
std::vector<uint8_t> group_border_vertices(const MeshData& m);
/// Total length of the edges whose two triangles lie in different groups.
double group_border_length(State& state);
/// How far the face group borders of two meshes are apart, both ways: the largest distance from
/// the ends and middles of the border edges of each to the border edges of the other (so a
/// stretch of border that is gone from one of them counts as much as one that strayed). 0 when
/// neither has a border; the meshes' diagonal when only one has.
double group_border_deviation(State& a, State& b);
/// "<count> <one>" for a count of one, "<count> <many>" otherwise ("1 hole was", "3 holes were").
std::string counted(uint64_t count, const char* one, const char* many);
/// One-sided distance from `from` to the surface of `to` for two meshes that share most of
/// their triangles (a mesh and what Reduce made of it: every vertex left is an input vertex).
/// A triangle of `from` that `to` holds too (the same three corner positions, the same way
/// round) is 0 away; every other one is probed at its corners and on a lattice of points across
/// it, as fine as `point_budget` allows for their number: cut 2 ways along each side (the edge
/// middles, and the triangle's middle) up to 8 ways (42 points). The same points on every run.
Distance distance_at_points(State& from, State& to, const Deadline& deadline, size_t point_budget);
/// Vertices whose triangles form more than one fan: surfaces that only touch there.
size_t non_manifold_vertex_count(State& state);

struct SheetStats
{
    size_t non_manifold_before = 0, non_manifold_after = 0, split_vertices = 0;
    std::vector<uint32_t> copied;  // the vertex each copy was made of, in the copies' order
};
/// (mesh_clean.cpp) Takes apart what only touches: around every edge more than two triangles
/// share, the triangles are paired into sheets (each triangle with the next one around the edge
/// that closes material between them; walls that lie on each other stay with their own body),
/// and every vertex gets a copy for each fan of triangles joined across paired edges. Triangles
/// and their order stay; copies are added after the other vertices. False when the deadline passed.
bool split_into_sheets(MeshData& m, SheetStats& stats, const Deadline& deadline);

// ---------------------------------------------------------------- pmp

/// The triangles `tris` of the mesh (all of them when null) as a pmp mesh: face i is tris[i],
/// in the stored winding; pmp vertex i is mesh vertex vertex_of[i] (the used ones, ascending).
/// "" on success, else one sentence (pmp refuses corners where surfaces only touch).
std::string build_pmp(const MeshData& m, const std::vector<uint32_t>* tris, pmp::SurfaceMesh& out, std::vector<uint32_t>& vertex_of);

/// Positions and triangles of a pmp mesh without deleted elements (after garbage_collection()).
void read_pmp(const pmp::SurfaceMesh& mesh, std::vector<float>& positions, std::vector<uint32_t>& triangles);

/// Marks e:feature / v:feature on the edges whose two faces differ in `group` (a face property
/// of uint32_t). Returns the number of edges marked.
size_t mark_group_borders(pmp::SurfaceMesh& mesh, const pmp::FaceProperty<uint32_t>& group);

/// "<Title> failed inside the mesh library: <what>"
std::string library_error(const char* title, const char* what);

/// After CadMesh::finish_op: when the result crosses itself but the input could not be tested in
/// the time left (so finish_op made no claim), the crossings are still said: a result is never
/// handed over with crossings nobody mentioned.
void note_untested_crossings(const char* title, const godot::Dictionary& report, godot::Dictionary& checks, godot::PackedStringArray& warnings);

}  // namespace holo_forge::mesh
