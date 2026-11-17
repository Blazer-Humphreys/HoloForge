#pragma once

// The bridge between the Mesh workspace and the Manifold library (work order, Stage N3), and the
// small tools every Stage N3 op shares:
//   ops::   reading an op's options Dictionary, the sentences every op says the same way
//   mf::    MeshData <-> manifold::MeshGL64 (face group ids travel as faceID, each input as one
//           run with an id from Manifold::ReserveIDs), our own text for Manifold's status codes,
//           and the watchdog thread that cancels a Manifold call at the op's deadline
//   cut::   filling a planar cut (the cap) with even triangles
// The ops themselves are CadMesh methods in mesh_boolean.cpp, mesh_cut.cpp, mesh_wrap.cpp,
// mesh_shell.cpp, mesh_separate.cpp and mesh_displace.cpp.

#include "mesh_budget.h"
#include "mesh_data.h"
#include "mesh_deadline.h"

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <manifold/manifold.h>

#include <condition_variable>
#include <initializer_list>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_set>
#include <vector>

namespace holo_forge::mesh::voxel
{
struct Grid;
}

namespace holo_forge::mesh::ops
{

double now_ms();
godot::String text(const std::string& s);
std::string plain(const godot::String& s);

/// A number for a message with `digits` significant digits and never an exponent:
/// "0.00006727", "12.5", "12,400".
std::string plain_number(double value, int digits = 4);
/// A length for a message in a unit that fits it: "1.25 mm", "0.00006727 mm", "12.5 m",
/// "1.7 km".
std::string length_text(double meters);

/// Where a body lies and what that costs: positions are float32, so they step by about one
/// eight-millionth of the largest coordinate.
struct Place
{
    double reach = 0.0;     // the largest coordinate of the body, as a size
    double distance = 0.0;  // of the body's box centre from the origin
    double step = 0.0;      // the float32 step at `reach`
    double diagonal = 0.0;
};
Place place_of(State& state);
/// The float32 step at a coordinate of this size.
double float_step(double reach);
/// "<Name> is <d> from the origin, where positions are stored only to about <step>: <why>.
/// Move it nearer the origin first." when the step there is larger than `finest`; else empty.
std::string too_far(State& state, const std::string& name_start, double finest, const std::string& why);
/// "<Title> would put the mesh more than 1,000 km from the origin, farther than a mesh body
/// can be. Move <name> nearer the origin first." when the body's box grown by `grow` passes the
/// limit; else empty.
std::string past_limit(State& state, const char* title, double grow, const std::string& name);
/// "<Name> is <d> from the origin, where positions are stored only to about <step> (<p> % of
/// its size), so the result is rounded by about that much. Move it nearer the origin first for
/// an exact result." when the step is more than a ten-thousandth of the body's size; else empty.
std::string rounding_note(State& state, const std::string& name_start);
/// A count with its noun: "1 open edge", "3,200 open edges".
std::string count_text(int64_t count, const char* one, const char* many);
/// A share for a message: "About 12 %", "About 0.31 %", "Less than 0.01 %".
std::string share_text(double share);
/// How many places the mesh crosses itself, tested for at most SELF_INTERSECTION_SECONDS and
/// never past the deadline: -1 when it could not be tested in that time.
int64_t crossings(State& state, const Deadline& deadline);

/// "<Op> would take about <n> s on this mesh (limit <limit> s). <hint>"
std::string too_slow(const char* title, double seconds, double limit, const char* hint);
/// "<Op> took longer than <limit> s and was stopped. <hint>"
std::string timed_out(const char* title, double limit, const char* hint);

/// `base` when no group has that name yet, else `base (2)`, `base (3)`, ...; never longer than
/// 64 bytes. The name it gives is added to taken.
std::string unique_name(const std::string& base, std::unordered_set<std::string>& taken);
/// The first of <prefix>0, <prefix>1, ... that no group has yet ("cut0", "wrap0").
std::string numbered_name(const char* prefix, const std::vector<std::string>& names);

/// The numbers of one mesh as the op report holds them (work order 2.6.3).
godot::Dictionary summary_dict(const Summary& s, bool output);

/// What each step of an op took, for its report ("phases": {name: ms}); the rates in
/// mesh_budget.h are measured from these.
struct Phases
{
    double last = now_ms();
    godot::Dictionary ms;
    void mark(const char* name)
    {
        const double now = now_ms();
        ms[name] = double(ms.get(name, 0.0)) + (now - last);
        last = now;
    }
};

/// Reads one op's options. A missing key gives the fallback; a value of the wrong kind, or
/// outside its range, is a problem: the first one is kept as one sentence, and the op refuses
/// with it (never a silent clamp).
class Options
{
public:
    explicit Options(const godot::Dictionary& options) : dict(options)
    {
    }
    bool ok() const
    {
        return error.empty();
    }
    const std::string& problem() const
    {
        return error;
    }
    void fail(const std::string& sentence)
    {
        if (error.empty()) {
            error = sentence;
        }
    }
    bool has(const char* key) const;
    double number(const char* key, const char* label, double fallback);
    bool flag(const char* key, const char* label, bool fallback);
    /// The index of the chosen word.
    int choice(const char* key, const char* label, std::initializer_list<const char*> words, int fallback);
    /// False when the key is missing (out untouched) or not a Vector3 (a problem).
    bool vector(const char* key, const char* label, double out[3]);
    /// options.name, the body's name for messages; when missing "the body", or "The body" for
    /// the start of a sentence.
    std::string name(bool sentence_start = false) const;
    /// options.time_limit: 20 s when missing, kept within 0.05 .. 120 s.
    double time_limit();
    /// options.skip_estimate (tests only): the op starts even when its own estimate says it
    /// will not fit the time limit, so that the deadline and the watchdog are what stops it.
    bool skip_estimate();
    /// "<Label> must be between <a> and <b>." when value is outside lo..hi (lengths in mm).
    /// A value within one millionth of a bound counts as on it (the panel's numbers are float32).
    bool range(const char* label, double value, double lo, double hi, bool length);

private:
    const godot::Dictionary& dict;
    std::string error;
};

}  // namespace holo_forge::mesh::ops

namespace holo_forge::mesh::mf
{

using Status = manifold::Manifold::Error;

/// One sentence for a Manifold status that is not NoError and not Cancelled (the library has
/// text of its own only in debug builds).
std::string status_text(Status status, const char* title);

/// Calls ctx.Cancel() when the deadline passes: the one extra thread of an op (contract C4.4).
/// It sleeps on a condition variable and touches nothing else. Stops when it goes out of scope.
///
/// Measured in Stage N3 (how long after its limit a whole op was back, its own clean-up
/// included): LevelSet 2 to 50 ms; a boolean of 2 x 1M triangles 0.21 to 0.30 s; a plane trim
/// of 2M triangles 0.48 to 0.76 s; and during ctx.FromMeshGL, which looks for the cancel only
/// between its steps, up to 0.52 s on a 1M-triangle body and 0.86 s on a 2M one. So the
/// ingest is the slowest to stop, and every op's own estimate holds it: an op whose limit is
/// below its ingest is refused before it starts. Manifold calls that take no context
/// (SplitByPlane, Decompose, GetMeshGL64) cannot be stopped at all: SplitByPlane is not used
/// for that reason, and the other two are short (under 0.8 s at 2M triangles).
class Watchdog
{
public:
    Watchdog(const manifold::ExecutionContext& ctx, const Deadline& deadline);
    ~Watchdog();
    Watchdog(const Watchdog&) = delete;
    Watchdog& operator=(const Watchdog&) = delete;

private:
    manifold::ExecutionContext ctx;
    std::mutex lock;
    std::condition_variable changed;
    bool done = false;
    std::thread thread;
};

/// "" when Manifold can take the mesh as a solid: closed, two triangles on every edge running
/// it opposite ways, no part inside-out by the nesting rule. Else the sentence to refuse with
/// (it starts with the body's name and says what to run first).
std::string unfit(State& state, const std::string& name);

/// The mesh as Manifold input: one run with run_id; faceID is group id + group_offset, or the
/// triangle's own index with by_triangle. Triangles that name a vertex twice are left out
/// (they have no area and no edges).
manifold::MeshGL64 to_gl(const MeshData& mesh, uint32_t run_id, uint32_t group_offset, bool by_triangle = false);

struct Import
{
    MeshData mesh;                 // groups: the faceID of triangles in our runs; names.size() for the rest
    std::vector<uint8_t> foreign;  // per triangle: 1 when its run is none of ours (a cap, a level set)
    std::vector<uint32_t> run;     // per triangle: the index into own_runs, NONE when foreign
    size_t foreign_triangles = 0;
};
/// Manifold output back as MeshData. Triangles in a run whose runOriginalID is in own_runs keep
/// their faceID as group (it must be below names.size(), else that is an error: Manifold lost
/// our ids); every other triangle goes to one more group named foreign_name (which must not be
/// in names). Positions become float32.
bool from_gl(const manifold::MeshGL64& gl, const std::vector<uint32_t>& own_runs, const std::vector<std::string>& names, const std::string& foreign_name,
             Import& out, std::string& error);

/// The solid where the function sampled on the grid is positive (Manifold's LevelSet at level
/// 0 with the grid's cell size, read between the samples). The watchdog's ctx stops it; the
/// caller reads Status(). (mesh_wrap.cpp)
///
/// The solid also holds one tiny extra piece, the guard, below the grid in x: everything of it
/// lies at x < guard_below, everything else at x > guard_below. It is there because Manifold
/// 3.5.4's LevelSet reads before the start of an array, and then crashes, when its table of
/// grid points fills up before the first surface point has been made (a flat face of a box
/// that lies midway between two grid layers does that; found on bodies away from the origin,
/// where the faces fall differently on the grid). The guard is the first thing LevelSet meets
/// and makes those first points. Callers drop it with drop_guard() after from_gl(), and ask
/// only_guard() where they asked IsEmpty() before.
manifold::Manifold level_set(manifold::ExecutionContext& ctx, const voxel::Grid& grid, const std::vector<float>& values, double& guard_below);
/// True when the level set found nothing but the guard.
bool only_guard(const manifold::Manifold& solid, double guard_below);
/// Takes the guard's triangles out of what from_gl() gave.
void drop_guard(Import& imported, double guard_below);
/// What LevelSet, the way back and the checks on its result cost: by grid samples, and by the
/// triangles a surface of that area comes out with at cell size h.
double level_set_seconds(double cells, double surface_area, double h);
/// What our own voxel work costs on a grid of that many samples, when the distance field is
/// right up to `band` (meters) at cell size h.
double voxel_seconds(double cells, double band, double h);

}  // namespace holo_forge::mesh::mf

namespace holo_forge::mesh::cut
{

/// A plane with an in-plane frame: u x v = n (all unit).
struct Frame
{
    double origin[3] = {0, 0, 0};
    double n[3] = {0, 0, 1};
    double u[3] = {1, 0, 0};
    double v[3] = {0, 1, 0};
};
Frame make_frame(const double origin[3], const double normal[3]);

/// Refines a planar cap in place: `cap` lists triangles of `mesh` that lie in the frame's plane
/// and face `facing` (+1: along n, -1: against it). Points on a square grid of `spacing` that
/// are at least half a spacing away from the cap's outline are added, and the cap's inner edges
/// are flipped until they are Delaunay; the outline (and with it every triangle outside the
/// cap) stays as it is. False when the deadline passed or the cap is not a clean patch (the
/// mesh is then untouched). `added` gets the number of new vertices.
bool refine_cap(MeshData& mesh, const std::vector<uint32_t>& cap, const Frame& frame, int facing, double spacing, size_t max_new_triangles,
                const Deadline& deadline, size_t& added);

}  // namespace holo_forge::mesh::cut

namespace holo_forge::mesh
{
// What each op's panel needs before the op runs: defaults (raised to fit the grid cap where
// that applies), the range of every field, and the op's own time estimate. Each is in the
// file of its op and shares that op's own checks.
godot::Dictionary wrap_defaults(State& state, const godot::Dictionary& options, bool rebuild);
godot::Dictionary shell_defaults(State& state, const godot::Dictionary& options);
godot::Dictionary plane_cut_defaults(State& state, const godot::Dictionary& options);
godot::Dictionary displace_defaults(State& state, const godot::Dictionary& options);
godot::Dictionary boolean_defaults(State& state, const godot::Dictionary& options);
}  // namespace holo_forge::mesh
