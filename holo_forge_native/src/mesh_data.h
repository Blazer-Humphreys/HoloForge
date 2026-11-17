#pragma once

// The data layer of the Mesh workspace (contract C1): a triangle mesh with face groups as plain
// indexed arrays, its binary form "HFM1", and the read-only structures every query and op builds
// on (edge topology, components with the nesting rule, a triangle hierarchy). No Godot types
// here, so the op files (pmp, Manifold, voxel) can use it as it is.
//
// Winding: triangles are counter-clockwise seen from outside, everywhere in the native code.

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "mesh_deadline.h"

namespace holo_forge::mesh
{

struct TriBvh;

constexpr uint32_t NONE = 0xFFFFFFFFu;

struct MeshData
{
    std::vector<float> positions;          // 3V, meters, part space
    std::vector<uint32_t> triangles;       // 3T, CCW seen from outside
    std::vector<uint32_t> groups;          // T, group id per triangle, < G
    std::vector<std::string> group_names;  // G, unique, 1..64 UTF-8 bytes

    size_t vertex_count() const
    {
        return positions.size() / 3;
    }
    size_t triangle_count() const
    {
        return triangles.size() / 3;
    }
    size_t group_count() const
    {
        return group_names.size();
    }
    void point(uint32_t vertex, double out[3]) const
    {
        const float* p = &positions[size_t(vertex) * 3];
        out[0] = p[0];
        out[1] = p[1];
        out[2] = p[2];
    }
};

// ---------------------------------------------------------------- mesh_data.cpp

/// "" when the mesh keeps every C1 rule (sizes, caps, index and group ranges, finite positions,
/// unique names of 1..64 bytes), else one sentence that names the first problem.
std::string validate(const MeshData& mesh);
/// The size part of validate() alone, from counts: what a constructor checks before it allocates.
std::string validate_sizes(uint64_t vertices, uint64_t triangles, uint64_t groups);
/// Drops unused vertices and empty groups (ids renumbered in order). Triangle order is kept.
void compact(MeshData& mesh);
/// Names that break the C1 rules are repaired in place: empty ones become "g<index>", long ones
/// are shortened with short_group_name(), repeated ones get "~<index>".
void repair_group_names(std::vector<std::string>& names);
/// A name of at most 64 bytes for any text: itself when it fits, else its first bytes, "~" and
/// 16 hex digits of a hash of the whole text. The same text always gives the same name.
std::string short_group_name(const std::string& name);
/// A 64-bit hash of positions, triangles, groups and names. Equal content, equal digest, on any run.
uint64_t digest(const MeshData& mesh);
size_t memory_bytes(const MeshData& mesh);

/// The "HFM1" blob (contract C1.3): its byte count, and the bytes written to out (blob_size bytes).
size_t blob_size(const MeshData& mesh);
void write_blob(const MeshData& mesh, uint8_t* out);
/// Reads a blob. False with an error that names the failed check (magic, version, flags, size,
/// CRC, or a C1 rule).
bool read_blob(const uint8_t* bytes, size_t size, MeshData& mesh, std::string& error);
/// CRC-32 (IEEE 802.3).
uint32_t crc32(const uint8_t* bytes, size_t size);

/// 1234567 -> "1,234,567".
std::string with_commas(uint64_t value);
/// A number for a message ("%.4g" by default); Godot's vformat has no %g.
std::string number_text(double value, const char* format = "%.4g");
/// A length in meters for a sentence: a plain number (never an exponent) of about four digits
/// with the unit that suits it: km from 1,000 m, m from 1 m, mm from 0.001 mm, µm from
/// 0.0001 mm, nm below ("1,000.001 km", "1.732 mm", "0.1 µm", "43.3 nm"). UTF-8.
std::string length_text(double meters);
/// Seconds for a sentence, as a plain number: "0.05", "2.5", "36", "2,400".
std::string seconds_text(double seconds);

/// Has triangle t no area? It names a corner twice, or its height is at most 2^-24 (about
/// 6e-8, float32's step) of its longest edge: thinner than float32 can hold at the triangle's
/// own size. Judged by the triangle alone, never by the size of the body or by its place: a
/// 1 mm triangle 100 m from the origin, with corners on float32's 7.6 um grid there, has area
/// (its corners make a real triangle; only exactly equal or exactly collinear float corners,
/// and needles under that ratio, do not).
bool without_area(const MeshData& mesh, size_t triangle);

/// The mesh moved by a 3x4 matrix (rows of a rotation/scale part and a translation), in doubles
/// from the float positions. A mirroring matrix also flips every triangle.
MeshData transformed(const MeshData& mesh, const double basis[9], const double origin[3]);

/// Welds vertices with bit-equal positions (-0 counts as 0); triangles are re-indexed, vertex
/// order is first use. Returns the number of vertices removed.
size_t weld_exact(MeshData& mesh);

// ---------------------------------------------------------------- mesh_io.cpp

struct FileBytes
{
    const uint8_t* data = nullptr;
    size_t size = 0;
};

/// STL (binary or ASCII, see CadMesh::read_stl) and OBJ from a file's bytes. `label` is the file
/// name for messages. One group "g0" for STL; one per o/g statement that has faces for OBJ.
bool parse_stl(FileBytes file, const std::string& label, double scale, MeshData& mesh, std::string& error);
bool parse_obj(FileBytes file, const std::string& label, double scale, MeshData& mesh, std::string& error);
/// The same, with `warning`: what a damaged file that was still loaded is missing (a text STL
/// without endsolid, a binary STL that holds more than its count names, OBJ faces left out or
/// self-crossing), "" for a whole file. A file that cannot be trusted at all is refused.
bool parse_stl(FileBytes file, const std::string& label, double scale, MeshData& mesh, std::string& error, std::string& warning);
bool parse_obj(FileBytes file, const std::string& label, double scale, MeshData& mesh, std::string& error, std::string& warning);
/// True when the STL bytes are a binary file (by the size rule, never by a leading "solid"). The
/// second form takes the first bytes of a file (84 or more, up to 1,024 are looked at) and its size.
bool stl_is_binary(FileBytes file);
bool stl_is_binary(FileBytes head, uint64_t file_size);
/// The triangle count a binary STL header claims.
uint32_t stl_binary_count(FileBytes file);

// ---------------------------------------------------------------- mesh_query.cpp: structures

/// Edges of the mesh. Half-edge h = 3 t + k runs from corner k of triangle t to corner (k + 1) % 3.
/// Triangles that name a vertex twice have no half-edges (he_edge == NONE).
struct Topology
{
    std::vector<uint32_t> he_edge;     // 3T: the edge of each half-edge, or NONE
    std::vector<uint32_t> edge_first;  // E + 1: offsets into edge_hes
    std::vector<uint32_t> edge_hes;    // each edge's half-edges, ascending
    uint32_t boundary_edges = 0;       // one triangle
    uint32_t non_manifold_edges = 0;   // more than two triangles
    uint32_t inconsistent_edges = 0;   // two triangles that run the edge the same way

    size_t edge_count() const
    {
        return edge_first.empty() ? 0 : edge_first.size() - 1;
    }
    uint32_t uses(uint32_t edge) const
    {
        return edge_first[size_t(edge) + 1] - edge_first[edge];
    }
    /// The other half-edge of a two-triangle edge, else NONE.
    uint32_t twin(uint32_t he) const
    {
        const uint32_t e = he_edge[he];
        if (e == NONE || uses(e) != 2) {
            return NONE;
        }
        const uint32_t a = edge_hes[edge_first[e]];
        return a == he ? edge_hes[size_t(edge_first[e]) + 1] : a;
    }
};

struct Component
{
    uint32_t triangles = 0;
    uint32_t first_triangle = 0;
    bool closed = false;      // every edge has exactly two triangles
    bool consistent = false;  // closed, and the two triangles of every edge run it in opposite directions
    double volume = 0.0;      // signed
    double lo[3] = {0, 0, 0}, hi[3] = {0, 0, 0};
    // The nesting rule (closed and consistent components only; -1 otherwise).
    int depth = -1;
    int parent = -1;
    bool inverted = false;
};

/// Edge-connected components. Triangles without half-edges are in none (-1).
struct Components
{
    std::vector<int32_t> of_triangle;
    std::vector<Component> list;
    bool nested = false;  // depth, parent and inverted are filled
};

/// Sums over all triangles, about the bounding box centre `origin` (doubles).
struct Measures
{
    double lo[3] = {0, 0, 0}, hi[3] = {0, 0, 0};  // bounds of the used vertices
    bool any = false;                              // any used vertex
    double diagonal = 0.0;
    double origin[3] = {0, 0, 0};
    double area = 0.0;
    double area_centre[3] = {0, 0, 0};    // absolute
    double area_second[9] = {0, 0, 0, 0, 0, 0, 0, 0, 0};    // integral of x x^T dA about origin
    double volume = 0.0;                  // signed sum (meaningful when closed)
    double volume_centre[3] = {0, 0, 0};  // absolute (when volume != 0)
    double volume_second[9] = {0, 0, 0, 0, 0, 0, 0, 0, 0};  // integral of x x^T dV about origin
};

/// Triangles of each group.
struct GroupIndex
{
    std::vector<uint32_t> first;  // G + 1
    std::vector<uint32_t> tris;   // ascending within a group
};

/// A mesh and everything derived from it. The derived parts are built on first use and kept: a
/// mesh never changes once made.
struct State
{
    State();
    ~State();

    MeshData data;
    std::unique_ptr<Topology> topology;
    std::unique_ptr<Components> components;
    std::unique_ptr<TriBvh> bvh;
    std::unique_ptr<Measures> measures;
    std::unique_ptr<GroupIndex> group_index;
    bool has_digest = false;
    uint64_t digest_value = 0;
    /// The self-intersection count, once a test has run to its end (self_intersections_within).
    bool has_self_intersections = false;
    int64_t self_intersection_count = 0;
};

// Each returns null when the deadline (may be null: no limit) passed before it was done; nothing
// half-built is kept.
const Topology* topology_of(State& state, const Deadline* deadline = nullptr);
/// Components without nesting.
const Components* components_of(State& state, const Deadline* deadline = nullptr);
/// Components with the nesting rule applied (work order 2.6.3): the one place that decides
/// which closed components are solid shells, voids or inside-out.
const Components* nested_components_of(State& state, const Deadline* deadline = nullptr);
const TriBvh* bvh_of(State& state, const Deadline* deadline = nullptr);
const Measures& measures_of(State& state);
const GroupIndex& group_index_of(State& state);
uint64_t digest_of(State& state);
size_t memory_bytes(const State& state);

// ---------------------------------------------------------------- mesh_query.cpp: queries

/// True when the mesh has triangles, no boundary edge and no non-manifold edge.
bool is_closed(State& state);

struct CheckResult
{
    bool finished = false;  // false: the deadline passed in the basic part (nothing else is valid)
    bool closed = false, manifold = false, oriented = false;
    int64_t boundary_edges = 0, boundary_loops = 0, non_manifold_edges = 0, non_manifold_vertices = 0;
    int64_t degenerate_triangles = 0, duplicate_triangles = 0, unused_vertices = 0;
    int64_t components = 0, closed_components = 0, inverted_components = 0, solid_components = 0;
    int64_t genus = -1;
    int64_t self_intersections = -1;      // -1: not checked in time
    double self_ms = 0.0;                 // what the self-intersection test took (with its hierarchy)
    std::vector<int32_t> pairs;           // the first 64 crossing pairs (2 ids each)
};
/// The whole check. self_seconds bounds the self-intersection test on its own (it is skipped,
/// -1, when its estimate does not fit; a negative self_seconds skips it always).
CheckResult check(State& state, const Deadline& deadline, double self_seconds);

/// Triangles that name a vertex twice or whose area is below 1e-12 x the bounding box diagonal squared.
int64_t count_degenerate(State& state);
/// Crossing pairs of triangles that share no vertex (by index or by position). -1 when the
/// deadline passed. pairs gets the first 64.
int64_t self_intersections(State& state, const Deadline& deadline, std::vector<int32_t>* pairs);
/// The same within `seconds`: not started (-1) when its estimate for this mesh (with the
/// hierarchy, if that is not built yet) does not fit, stopped (-1) when it runs out anyway.
/// elapsed_ms (may be null) gets what it took.
int64_t self_intersections_within(State& state, double seconds, std::vector<int32_t>* pairs, double* elapsed_ms = nullptr);

struct BoundaryLoop
{
    std::vector<uint32_t> vertices;  // in the direction of the boundary half-edges, from the smallest
    double length = 0.0;
    double planar_error = 0.0;       // largest distance from the loop's best plane
    bool closed = true;              // false when the chain could not be followed back to its start
};
/// Open boundary loops, ordered by smallest vertex index.
std::vector<BoundaryLoop> boundary_loops(State& state);

struct Polyline
{
    std::vector<double> points;  // 3 per point
    bool closed = false;
};
/// The cut of the mesh by a plane, chained into polylines in a stable order (by smallest
/// triangle). Closed loops of an outward-facing solid run counter-clockwise seen from the tip of
/// the normal. A vertex exactly on the plane counts as on the normal's side.
std::vector<Polyline> section(State& state, const double origin[3], const double normal[3]);

struct RayHit
{
    bool hit = false;
    double distance = 0.0;
    double point[3] = {0, 0, 0};
    double normal[3] = {0, 0, 0};  // the triangle's own (outward) unit normal
    uint32_t triangle = NONE;
};
/// The nearest triangle on a ray (direction need not be unit; distances are in meters). Back
/// faces count.
RayHit ray_hit(State& state, const double origin[3], const double direction[3], double max_distance);

/// Winding number of each point (signed crossings of a +Z ray). 0 outside.
void winding_numbers(State& state, const double* points, size_t count, std::vector<int32_t>& out);

/// Triangles inside a convex region given by planes (a x + b y + c z <= d is inside, 4 doubles
/// each). all_inside: every corner inside; else any part of the triangle inside.
std::vector<uint32_t> triangles_in_planes(State& state, const double* planes, size_t plane_count, bool all_inside);
/// Triangles with any part within radius of point; connected keeps the patch joined (by edges)
/// to the nearest one.
std::vector<uint32_t> triangles_near(State& state, const double point[3], double radius, bool connected);
/// One ring of edge neighbours added (grow) or peeled off (shrink) per step.
std::vector<uint32_t> grow(State& state, const std::vector<uint32_t>& tris, int steps, bool shrink);
/// Flood fill from tris across edges whose two normals differ by at most max_angle_deg.
std::vector<uint32_t> connected(State& state, const std::vector<uint32_t>& tris, double max_angle_deg);

struct Distance
{
    double max = 0.0, mean = 0.0, rms = 0.0;
    double max_point[3] = {0, 0, 0};
    int64_t samples = 0;
    bool timed_out = false;
};
/// One-sided sampled distance from `from` to the surface of `to`.
Distance distance_between(State& from, State& to, int64_t samples, const Deadline& deadline);

struct GroupInfo
{
    bool valid = false;
    bool planar = false;
    double point[3] = {0, 0, 0};   // area centroid
    double normal[3] = {0, 0, 0};  // area weighted, unit
    double area = 0.0;
    int64_t triangles = 0;
};
GroupInfo group_info(State& state, uint32_t group);
/// The unit normal of the triangle of `group` nearest to point (zero when the group is empty).
void group_normal_at(State& state, uint32_t group, const double point[3], double out[3]);

struct MassProperties
{
    bool closed = false;
    double volume = 0.0, area = 0.0;
    double centre[3] = {0, 0, 0};
    double inertia[9] = {0, 0, 0, 0, 0, 0, 0, 0, 0};  // about the centre, per unit density
    double principal[3] = {0, 0, 0};
    // Flaws that make the numbers above less than the truth (each 0 or false on a sound mesh).
    bool open = false;                // open edges (edges of one triangle): no volume
    int64_t non_manifold_edges = 0;   // edges of more than two triangles: no volume
    int64_t wrong_way_edges = 0;      // edges whose two triangles face opposite ways: no volume
    int64_t inside_out_parts = 0;     // closed parts that face the wrong way for where they sit
    int64_t self_intersections = -1;  // crossings (-1: not tested, or not within the time for it)
};
/// Solid integrals when the mesh is closed and its triangles agree on a side (`closed` true),
/// else those of its surface (volume 0). The volume is never negative: an inside-out mesh gives
/// its size, and inside_out_parts says so. With test_crossings the self-intersection test runs
/// (once per mesh, within SELF_INTERSECTION_SECONDS) unless its count is already known.
MassProperties mass_properties(State& state, bool test_crossings);
MassProperties mass_properties(State& state);

/// The numbers the op report holds for one mesh (work order 2.6.3).
struct Summary
{
    int64_t triangles = 0, vertices = 0, groups = 0;
    bool closed = false;
    int64_t boundary_edges = 0, non_manifold_edges = 0, degenerate_triangles = 0;
    int64_t components = 0, inverted_components = 0;
    double volume = 0.0, area = 0.0;
};
Summary summarize(State& state);

// ---------------------------------------------------------------- mesh_tessellate.cpp

/// The display arrays of contract C6.1, as plain vectors.
struct Tessellation
{
    std::vector<float> positions;    // 3 per split vertex
    std::vector<float> normals;      // 3 per split vertex (angle weighted)
    std::vector<float> uvs;          // 2 per split vertex (box projection, meters)
    std::vector<int32_t> indices;    // 3 per triangle, clockwise (Godot), stored triangle order
    std::vector<int32_t> face_ids;   // group per triangle
    std::vector<float> edge_points;  // 6 per segment
    std::vector<int32_t> edge_ids;   // -1 group border, -2 open boundary
};
void tessellate(State& state, Tessellation& out);

}  // namespace holo_forge::mesh
