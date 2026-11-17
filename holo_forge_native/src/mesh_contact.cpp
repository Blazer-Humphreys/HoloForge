// Contact (Phase 8 work order, contract C5.1): CadMesh.overlap, the solid two closed mesh bodies
// share at a relative placement, through Manifold's intersection.
//
// The order of one call:
//   1. options and the placement (12 finite numbers, a rigid move): refused at once;
//   2. both meshes closed, manifold, facing one way and not inside out: refused at once (the
//      topology this needs is built once per mesh and kept by its State);
//   3. the boxes: the other mesh's box moved by the placement against this one's; apart means
//      no overlap, with no Manifold work (early_out);
//   4. each mesh's Manifold, from its contact cache or built now and kept;
//   5. this ∩ other moved by the placement, under one deadline (the watchdog of Stage N3 cancels
//      Manifold's work when it passes); the moved side is the one with fewer triangles;
//   6. checks on the result (volume no more than the smaller body's, the overlap inside both
//      boxes): a result that fails them is an error, never a number.
// A mesh that crosses itself (fix round 1, verifier P6): Manifold counts the part it covers twice
// twice, so an overlap there means nothing. When the intersection is not empty, each mesh is
// tested for crossings once (ops::crossings: at most 1 s, never past the deadline; the count is
// kept by its State, a test that ran out is not tried again). A crossing gives the error "The mesh
// crosses itself ..." with self_crossing true and refused naming the side, never a number; a mesh
// that could not be tested in time is said as a warning. An empty intersection needs no test.

#include "mesh_contact.h"

#include "cad_mesh.h"
#include "mesh_budget.h"
#include "mesh_manifold.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

#include <algorithm>
#include <cmath>
#include <exception>
#include <memory>
#include <string>

using namespace godot;

namespace holo_forge
{

namespace mesh::contact
{

struct Cache
{
    manifold::Manifold solid;
    const State* owner = nullptr;  // the mesh data it was built from
    size_t bytes = 0;
    bool crossings_ran_out = false;  // a crossing test of this mesh ran out of time: not tried again
};

size_t cache_bytes(const Cache* cache)
{
    return cache != nullptr ? cache->bytes : 0;
}

}  // namespace mesh::contact

namespace
{
using mesh::contact::Cache;

const char* const kClosed = "Contact needs closed bodies: the mesh ";
const char* const kTitle = "Contact";

/// "" when the mesh can take part in contact, else the sentence (C5.1). late is set when the
/// deadline passed while the mesh's topology was being built (nothing is said then).
std::string refusal(mesh::State& state, const mesh::Deadline& deadline, bool& late)
{
    if (state.data.triangle_count() == 0) {
        return std::string(kClosed) + "is empty.";
    }
    const mesh::Topology* topo = mesh::topology_of(state, &deadline);
    if (topo == nullptr) {
        late = true;
        return std::string();
    }
    if (topo->edge_count() == 0) {
        return std::string(kClosed) + "has no triangles with area.";
    }
    if (topo->boundary_edges > 0) {
        return std::string(kClosed) + "is open.";
    }
    if (topo->non_manifold_edges > 0) {
        return std::string(kClosed) + "has edges that more than two triangles share.";
    }
    if (topo->inconsistent_edges > 0) {
        return std::string(kClosed) + "has triangles that face the wrong way.";
    }
    const mesh::Components* comps = mesh::nested_components_of(state, &deadline);
    if (comps == nullptr) {
        late = true;
        return std::string();
    }
    for (const mesh::Component& c : comps->list) {
        if (c.inverted) {
            return std::string(kClosed) + "is inside out.";
        }
    }
    return std::string();
}

/// The mesh's Manifold: the cached one, or built now under ctx and kept in slot. False when it
/// could not be built: error holds the sentence, or late is set when the deadline stopped it.
bool solid_of(std::shared_ptr<Cache>& slot, mesh::State& state, manifold::ExecutionContext& ctx, const mesh::Deadline& deadline, manifold::Manifold& out,
              int64_t& built, std::string& error, bool& late)
{
    if (slot && slot->owner == &state) {
        out = slot->solid;
        return true;
    }
    slot.reset();
    manifold::Manifold solid = ctx.FromMeshGL(mesh::mf::to_gl(state.data, manifold::Manifold::ReserveIDs(1), 0u));
    const mesh::mf::Status status = solid.Status();
    if (status == mesh::mf::Status::Cancelled) {
        late = true;
        return false;
    }
    if (status != mesh::mf::Status::NoError) {
        error = std::string(kClosed) + "could not be used. " + mesh::mf::status_text(status, kTitle);
        return false;
    }
    auto cache = std::make_shared<Cache>();
    // (Kept with a context of its own: this call's may be cancelled by its watchdog later.)
    cache->solid = solid.WithContext(manifold::ExecutionContext());
    cache->owner = &state;
    // Manifold keeps per vertex a position and a normal (2 x 24 bytes), per triangle three
    // half-edges (3 x 16), a normal (24), a reference to its input (16) and its share of the
    // collision hierarchy (two boxes of 48 and a code, about 110).
    cache->bytes = sizeof(Cache) + solid.NumVert() * 48 + solid.NumTri() * 200;
    slot = cache;
    out = cache->solid;
    ++built;
    if (deadline.expired()) {
        late = true;
        return false;
    }
    return true;
}

/// p' = B p + t for the C1.3 layout (columns X, Y, Z, then the origin).
void apply(const double m[12], const double p[3], double out[3])
{
    for (int k = 0; k < 3; ++k) {
        out[k] = m[k] * p[0] + m[3 + k] * p[1] + m[6 + k] * p[2] + m[9 + k];
    }
}

manifold::mat3x4 to_mat(const double m[12])
{
    return manifold::mat3x4(manifold::vec3(m[0], m[1], m[2]), manifold::vec3(m[3], m[4], m[5]), manifold::vec3(m[6], m[7], m[8]),
                            manifold::vec3(m[9], m[10], m[11]));
}

/// The inverse of a rigid move: the transposed turn, and the move turned back.
void inverse(const double m[12], double out[12])
{
    for (int c = 0; c < 3; ++c) {
        for (int r = 0; r < 3; ++r) {
            out[c * 3 + r] = m[r * 3 + c];
        }
    }
    for (int r = 0; r < 3; ++r) {
        out[9 + r] = -(out[r] * m[9] + out[3 + r] * m[10] + out[6 + r] * m[11]);
    }
}

PackedFloat64Array point3(double x, double y, double z)
{
    PackedFloat64Array p;
    p.resize(3);
    p.set(0, x);
    p.set(1, y);
    p.set(2, z);
    return p;
}

/// How many places the mesh crosses itself: the kept count, or tested now (ops::crossings), -1
/// when it could not be tested in time. A test that ran out is remembered in the cache so a
/// sweep does not pay for it on every step.
int64_t crossings_of(Cache* cache, mesh::State& state, const mesh::Deadline& deadline)
{
    if (state.has_self_intersections) {
        return state.self_intersection_count;
    }
    if (cache != nullptr && cache->crossings_ran_out) {
        return -1;
    }
    const int64_t count = mesh::ops::crossings(state, deadline);
    if (count < 0 && cache != nullptr) {
        cache->crossings_ran_out = true;
    }
    return count;
}

const char* const kRepair = "Repair it with Mesh > Repair > Rebuild.";

std::string crossing_error(int64_t count)
{
    return "The mesh crosses itself in " + mesh::ops::count_text(count, "place", "places") +
           ", so contact cannot measure its overlap there. " + kRepair;
}

std::string untested_note(const char* name_start)
{
    return std::string(name_start) +
           " could not be tested for places where it crosses itself in the time left; if it does, the overlap may be wrong there.";
}

}  // namespace

Dictionary CadMesh::overlap(const Ref<CadMesh>& other, const PackedFloat64Array& other_to_this, const Dictionary& options)
{
    const double started = mesh::ops::now_ms();
    Dictionary out;
    out["overlap"] = false;
    out["volume"] = 0.0;
    out["area"] = 0.0;
    out["thickness"] = 0.0;
    out["point"] = point3(0.0, 0.0, 0.0);
    out["timed_out"] = false;
    out["early_out"] = false;
    out["built"] = int64_t(0);
    out["warning"] = String();
    out["error"] = String();
    out["self_crossing"] = false;
    auto finish = [&]() {
        out["ms"] = mesh::ops::now_ms() - started;
        return out;
    };
    auto refuse = [&](const std::string& sentence, const char* side) {
        out["error"] = mesh::ops::text(sentence);
        if (side != nullptr) {
            out["refused"] = side;
        }
        return finish();
    };

    // 1. Options and the placement.
    mesh::ops::Options o(options);
    const double limit = mesh::clamp_time_limit(o.number("time_limit", "Time Limit", 1.0), 1.0);
    const bool estimate_only = o.flag("estimate_only", "Estimate Only", false);
    if (!o.ok()) {
        return refuse(o.problem(), nullptr);
    }
    if (other.is_null()) {
        return refuse("Contact needs a second mesh body.", "other");
    }
    if (other_to_this.size() != 12) {
        return refuse("The placement must be 12 numbers (a turn and a move); it has " + std::to_string(other_to_this.size()) + ".", nullptr);
    }
    double m[12];
    for (int i = 0; i < 12; ++i) {
        m[i] = other_to_this[i];
        if (!std::isfinite(m[i])) {
            return refuse("The placement must hold finite numbers.", nullptr);
        }
    }
    {
        // Rigid: the three columns unit and square to each other, and no mirror.
        double worst = 0.0;
        for (int a = 0; a < 3; ++a) {
            for (int b = 0; b < 3; ++b) {
                const double dot = m[a * 3] * m[b * 3] + m[a * 3 + 1] * m[b * 3 + 1] + m[a * 3 + 2] * m[b * 3 + 2];
                worst = std::max(worst, std::fabs(dot - (a == b ? 1.0 : 0.0)));
            }
        }
        const double det = m[0] * (m[4] * m[8] - m[5] * m[7]) - m[3] * (m[1] * m[8] - m[2] * m[7]) + m[6] * (m[1] * m[5] - m[2] * m[4]);
        if (worst > 1e-9 || det < 0.0) {
            return refuse("The placement must be a rigid move: a turn without scaling or mirroring, and a move.", nullptr);
        }
    }

    // 2. Closed bodies.
    const mesh::Deadline deadline(limit);
    mesh::State& a = *state;
    mesh::State& b = other->get_state();
    bool late = false;
    std::string problem = refusal(a, deadline, late);
    if (!problem.empty()) {
        return refuse(problem, "this");
    }
    if (!late) {
        problem = refusal(b, deadline, late);
        if (!problem.empty()) {
            return refuse(problem, "other");
        }
    }
    if (late) {
        out["timed_out"] = true;
        return finish();
    }

    // Where the bodies lie: float32 positions step by about an eight-millionth of the largest
    // coordinate, and the overlap is measured no finer than that.
    const mesh::ops::Place place_a = mesh::ops::place_of(a), place_b = mesh::ops::place_of(b);
    out["step"] = std::max(place_a.step, place_b.step);
    PackedStringArray warnings;
    for (const std::string& note : {mesh::ops::rounding_note(a, "The mesh"), mesh::ops::rounding_note(b, "The other mesh")}) {
        if (!note.empty()) {
            warnings.push_back(mesh::ops::text(note));
        }
    }
    out["warning"] = String("\n").join(warnings);

    const double tri_a = double(a.data.triangle_count()), tri_b = double(b.data.triangle_count());
    const bool cached_a = contact_cache && contact_cache->owner == &a;
    const bool cached_b = other->contact_cache && other->contact_cache->owner == &b;
    const double estimate = mesh::budget::overlap_seconds(tri_a, tri_b, cached_a, cached_b || (&a == &b && cached_a));
    out["estimate"] = estimate;
    if (estimate_only) {
        return finish();
    }

    // 3. The boxes.
    const mesh::Measures& ma = mesh::measures_of(a);
    const mesh::Measures& mb = mesh::measures_of(b);
    double lo[3] = {INFINITY, INFINITY, INFINITY}, hi[3] = {-INFINITY, -INFINITY, -INFINITY};
    for (int corner = 0; corner < 8; ++corner) {
        // (The box of the used vertices, in doubles from the float32 positions.)
        const double p[3] ={(corner & 1) ? mb.hi[0] : mb.lo[0], (corner & 2) ? mb.hi[1] : mb.lo[1], (corner & 4) ? mb.hi[2] : mb.lo[2]};
        double q[3];
        apply(m, p, q);
        for (int k = 0; k < 3; ++k) {
            lo[k] = std::min(lo[k], q[k]);
            hi[k] = std::max(hi[k], q[k]);
        }
    }
    for (int k = 0; k < 3; ++k) {
        if (lo[k] > ma.hi[k] || hi[k] < ma.lo[k]) {
            out["early_out"] = true;
            return finish();
        }
    }

    // 4. and 5. The Manifolds and their intersection, under one deadline.
    int64_t built = 0;
    double volume = 0.0, area = 0.0;
    manifold::Box box;
    bool empty = true;
    try {
        manifold::ExecutionContext ctx;
        const mesh::mf::Watchdog watchdog(ctx, deadline);
        manifold::Manifold solid_a, solid_b;
        std::string error;
        const bool ok = solid_of(contact_cache, a, ctx, deadline, solid_a, built, error, late) &&
                        solid_of(other->contact_cache, b, ctx, deadline, solid_b, built, error, late);
        out["built"] = built;
        if (!ok) {
            if (late) {
                out["timed_out"] = true;
                return finish();
            }
            return refuse(error, nullptr);
        }
        // The side with fewer triangles is moved (moving one costs a pass over its vertices and
        // a new collision hierarchy); the result is brought into this mesh's space either way.
        manifold::Manifold result;
        if (tri_b <= tri_a) {
            result = solid_a ^ solid_b.Transform(to_mat(m));
        }
        else {
            double back[12];
            inverse(m, back);
            result = (solid_a.Transform(to_mat(back)) ^ solid_b).Transform(to_mat(m));
        }
        const mesh::mf::Status status = result.WithContext(ctx).Status();
        if (status == mesh::mf::Status::Cancelled || deadline.expired()) {
            out["timed_out"] = true;
            return finish();
        }
        if (status != mesh::mf::Status::NoError) {
            return refuse(mesh::mf::status_text(status, kTitle), nullptr);
        }
        empty = result.IsEmpty();
        if (!empty) {
            volume = result.Volume();
            area = result.SurfaceArea();
            box = result.BoundingBox();
        }
    }
    catch (const std::exception& e) {
        return refuse(std::string("Contact failed inside the mesh library: ") + e.what(), nullptr);
    }
    catch (...) {
        return refuse("Contact failed inside the mesh library.", nullptr);
    }

    // 6. Checks: neither mesh crosses itself, the overlap is no larger than the smaller body, and
    // it lies inside both boxes.
    if (!empty) {
        const int64_t crossed_a = crossings_of(contact_cache.get(), a, deadline);
        const int64_t crossed_b = &b == &a ? crossed_a : crossings_of(other->contact_cache.get(), b, deadline);
        if (crossed_a > 0 || crossed_b > 0) {
            out["self_crossing"] = true;
            return refuse(crossing_error(crossed_a > 0 ? crossed_a : crossed_b), crossed_a > 0 ? "this" : "other");
        }
        const double smaller = std::min(std::fabs(ma.volume), std::fabs(mb.volume));
        const double room = std::max(place_a.step, place_b.step) + 1e-12 * std::max(place_a.reach, place_b.reach) + 1e-15;
        bool inside = true;
        for (int k = 0; k < 3; ++k) {
            inside = inside && box.min[k] >= std::max(lo[k], ma.lo[k]) - room && box.max[k] <= std::min(hi[k], ma.hi[k]) + room;
        }
        if (!std::isfinite(volume) || !std::isfinite(area) || volume > smaller * (1.0 + 1e-9) + 1e-21 || volume < -1e-9 * smaller - 1e-21 || area < 0.0 ||
            !inside) {
            const std::string measured = "Contact could not measure the overlap cleanly (volume " + mesh::number_text(volume, "%.9g") + " m3, area " +
                                         mesh::number_text(area, "%.9g") + " m2" + (inside ? "" : ", outside the bodies' boxes") + ").";
            if (crossed_a < 0 || crossed_b < 0) {
                // (Nearly always a mesh that crosses itself, too large to test in the time left.)
                const char* side = crossed_a < 0 ? "this" : "other";
                out["self_crossing"] = true;
                return refuse(measured + " The mesh may cross itself: it could not be tested for that in the time left. " + kRepair, side);
            }
            return refuse(measured + " This is a Holo Forge fault; please report it.", nullptr);
        }
        if (crossed_a < 0) {
            warnings.push_back(mesh::ops::text(untested_note("The mesh")));
        }
        if (crossed_b < 0 && &b != &a) {
            warnings.push_back(mesh::ops::text(untested_note("The other mesh")));
        }
        out["warning"] = String("\n").join(warnings);
        volume = std::max(volume, 0.0);
        out["volume"] = volume;
        out["area"] = area;
        out["thickness"] = area > 0.0 ? 2.0 * volume / area : 0.0;
        out["overlap"] = volume > 0.0;
        const manifold::vec3 centre = box.Center();
        out["point"] = point3(centre.x, centre.y, centre.z);
    }
    return finish();
}

void CadMesh::bind_contact_methods()
{
    // Phase 8 team N: contact (work order C5.1).
    ClassDB::bind_method(D_METHOD("overlap", "other", "other_to_this", "options"), &CadMesh::overlap, DEFVAL(Dictionary()));
}

}  // namespace holo_forge
