// Combine (work order 3.3.6): join, cut and intersect of closed mesh bodies through Manifold,
// and Merge (triangles put together with no boolean).

#include "cad_mesh.h"
#include "mesh_manifold.h"

#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

#include <algorithm>
#include <cmath>
#include <exception>

using namespace godot;

namespace holo_forge
{

namespace
{
const char* const kHint = "Reduce the bodies first.";

/// What Combine will cost on these inputs: every ingest, the boolean, the way back and the
/// checks on the result (the self-intersection test has its own 1 s bound).
double boolean_seconds(const std::vector<double>& triangles, int operation)
{
    using namespace mesh::budget;
    double total = 0.0, seconds = 0.0;
    for (const double t : triangles) {
        total += t;
        seconds += estimate(MF_INGEST, t);
    }
    seconds += estimate(operation == 0 ? MF_UNION : MF_SUBTRACT, total);
    seconds += estimate(MF_EXPORT, total) + estimate(OP_FINISH, total);
    // Every input and the result are tested for places where they cross themselves (1 s each at most).
    seconds += std::min(SELF_INTERSECTION_SECONDS, estimate(BVH_BUILD, total) + estimate(SELF_INTERSECTIONS, total));
    for (const double t : triangles) {
        seconds += std::min(SELF_INTERSECTION_SECONDS, estimate(BVH_BUILD, t) + estimate(SELF_INTERSECTIONS, t));
    }
    return seconds;
}

/// The mesh bodies of an Array (false with a sentence when one is not a mesh or has no triangles).
bool mesh_list(const Array& list, const char* title, std::vector<Ref<CadMesh>>& out, std::string& error)
{
    for (int64_t i = 0; i < list.size(); ++i) {
        const Ref<CadMesh> one = list[i];
        if (one.is_null()) {
            error = std::string(title) + " needs mesh bodies: item " + std::to_string(i + 1) + " is not one.";
            return false;
        }
        out.push_back(one);
    }
    return true;
}

std::vector<std::string> tool_names(const Dictionary& options, size_t count)
{
    std::vector<std::string> names;
    const Variant given = options.get(String("tool_names"), Variant());
    PackedStringArray list;
    if (given.get_type() == Variant::PACKED_STRING_ARRAY || given.get_type() == Variant::ARRAY) {
        list = given;
    }
    for (size_t i = 0; i < count; ++i) {
        std::string name = int64_t(i) < list.size() ? mesh::ops::plain(list[int64_t(i)]) : std::string();
        if (name.empty()) {
            name = "Tool body " + std::to_string(i + 1);
        }
        names.push_back(name);
    }
    return names;
}
}  // namespace

namespace mesh
{
Dictionary boolean_defaults(State& state, const Dictionary& options)
{
    ops::Options o(options);
    const int operation = o.choice("operation", "Operation", {"join", "cut", "intersect"}, 0);
    std::vector<double> triangles = {double(state.data.triangle_count())};
    const Variant tools = options.get(String("tools"), Variant());
    if (tools.get_type() == Variant::ARRAY) {
        const Array list = tools;
        for (int64_t i = 0; i < list.size(); ++i) {
            const Ref<CadMesh> one = list[i];
            if (one.is_valid()) {
                triangles.push_back(double(one->data().triangle_count()));
            }
        }
    }
    Dictionary out;
    out["operation"] = "join";
    out["seconds"] = boolean_seconds(triangles, operation);
    return out;
}
}  // namespace mesh

Ref<CadMesh> CadMesh::boolean(const Array& tools, const Dictionary& options)
{
    clear_messages();
    const double started = mesh::ops::now_ms();
    mesh::ops::Options o(options);
    const int operation = o.choice("operation", "Operation", {"join", "cut", "intersect"}, 0);
    const double limit = o.time_limit();
    const bool skip_estimate = o.skip_estimate();
    const std::string name = o.name(true), name_inside = o.name(false);
    mesh::ops::Phases phases;
    if (!o.ok()) {
        fail(o.problem());
        return Ref<CadMesh>();
    }
    std::vector<Ref<CadMesh>> bodies;
    std::string error;
    if (!mesh_list(tools, "Combine", bodies, error)) {
        fail(error);
        return Ref<CadMesh>();
    }
    if (bodies.empty()) {
        fail("Combine needs at least one tool body.");
        return Ref<CadMesh>();
    }
    const std::vector<std::string> names_of_tools = tool_names(options, bodies.size());

    // Refusals, before any heavy work: sizes, then closed solids, then the time.
    std::vector<mesh::State*> states = {state.get()};
    std::vector<std::string> body_names = {name};
    for (size_t i = 0; i < bodies.size(); ++i) {
        states.push_back(&bodies[i]->get_state());
        body_names.push_back(names_of_tools[i]);
    }
    uint64_t total = 0;
    std::vector<double> triangles;
    for (mesh::State* s : states) {
        total += s->data.triangle_count();
        triangles.push_back(double(s->data.triangle_count()));
    }
    if (total > mesh::budget::MAX_TRIANGLES_MESH) {
        fail("Combine needs " + mesh::with_commas(total) + " triangles in all; mesh bodies take up to " + mesh::with_commas(mesh::budget::MAX_TRIANGLES_MESH) + ". " + kHint);
        return Ref<CadMesh>();
    }
    for (size_t i = 0; i < states.size(); ++i) {
        const std::string problem = mesh::mf::unfit(*states[i], body_names[i]);
        if (!problem.empty()) {
            fail(problem);
            return Ref<CadMesh>();
        }
    }
    const double seconds = boolean_seconds(triangles, operation);
    phases.mark("checks");
    if (seconds > limit && !skip_estimate) {
        fail(mesh::ops::too_slow("Combine", seconds, limit, kHint));
        return Ref<CadMesh>();
    }

    // Group names: the target's, then each tool's (a name already taken gets " (2)", ...).
    std::vector<std::string> names = state->data.group_names;
    std::unordered_set<std::string> taken(names.begin(), names.end());
    std::vector<uint32_t> offsets = {0u};
    for (size_t i = 0; i < bodies.size(); ++i) {
        offsets.push_back(uint32_t(names.size()));
        for (const std::string& group : bodies[i]->data().group_names) {
            names.push_back(mesh::ops::unique_name(group, taken));
        }
    }
    const std::string foreign_name = mesh::ops::unique_name("combine0", taken);

    const mesh::Deadline deadline(limit);
    // Does an input cross itself? Manifold's answer is not reliable where one does, so each is
    // tested (-1: not in the time there is), and what is found is said by name below.
    std::vector<int64_t> input_crossings;
    for (mesh::State* s : states) {
        input_crossings.push_back(mesh::ops::crossings(*s, deadline));
    }
    phases.mark("crossings");
    mesh::mf::Import imported;
    double library_volume = 0.0;
    bool empty = false;
    try {
        manifold::ExecutionContext ctx;
        const mesh::mf::Watchdog watchdog(ctx, deadline);
        // One run id per input, from Manifold's own counter (it hands out the ids of its own
        // runs from the same one).
        const uint32_t first_id = manifold::Manifold::ReserveIDs(uint32_t(states.size()));
        std::vector<uint32_t> run_ids;
        std::vector<manifold::Manifold> solids;
        for (size_t i = 0; i < states.size(); ++i) {
            run_ids.push_back(first_id + uint32_t(i));
            manifold::Manifold solid = ctx.FromMeshGL(mesh::mf::to_gl(states[i]->data, run_ids[i], offsets[i]));
            const mesh::mf::Status status = solid.Status();
            if (status == mesh::mf::Status::Cancelled || deadline.expired()) {
                fail(mesh::ops::timed_out("Combine", limit, kHint));
                return Ref<CadMesh>();
            }
            if (status != mesh::mf::Status::NoError) {
                fail(body_names[i] + " could not be used. " + mesh::mf::status_text(status, "Combine"));
                return Ref<CadMesh>();
            }
            solids.push_back(std::move(solid));
        }
        phases.mark("ingest");
        const manifold::OpType type = operation == 0 ? manifold::OpType::Add : (operation == 1 ? manifold::OpType::Subtract : manifold::OpType::Intersect);
        manifold::Manifold result =
            (solids.size() == 2 ? solids[0].Boolean(solids[1], type) : manifold::Manifold::BatchBoolean(solids, type)).WithContext(ctx);
        const mesh::mf::Status status = result.Status();
        if (status == mesh::mf::Status::Cancelled || deadline.expired()) {
            fail(mesh::ops::timed_out("Combine", limit, kHint));
            return Ref<CadMesh>();
        }
        if (status != mesh::mf::Status::NoError) {
            fail(mesh::mf::status_text(status, "Combine"));
            return Ref<CadMesh>();
        }
        phases.mark("boolean");
        empty = result.IsEmpty();
        library_volume = empty ? 0.0 : result.Volume();
        if (!mesh::mf::from_gl(result.GetMeshGL64(), run_ids, names, foreign_name, imported, error)) {
            fail("Combine failed: " + error + ".");
            return Ref<CadMesh>();
        }
    }
    catch (const std::exception& e) {
        fail(std::string("Combine failed inside the mesh library: ") + e.what());
        return Ref<CadMesh>();
    }
    catch (...) {
        fail("Combine failed inside the mesh library.");
        return Ref<CadMesh>();
    }
    if (empty && operation == 2) {
        // An error for Intersect, and a flag in the report: callers that ask "do these bodies
        // overlap at all?" read "empty", never the sentence.
        Dictionary checks;
        checks["empty"] = "fail: the result is empty";
        last_report["op"] = "boolean";
        last_report["empty"] = true;
        last_report["checks"] = checks;
        last_report["ms"] = mesh::ops::now_ms() - started;
        fail("The result is empty (the bodies do not overlap).");
        return Ref<CadMesh>();
    }
    phases.mark("export");
    const size_t foreign = imported.foreign_triangles;
    Ref<CadMesh> out = finish_op("Combine", "boolean", std::move(imported.mesh), started, false);
    if (out.is_null()) {
        return out;
    }
    Dictionary checks = last_report["checks"];
    PackedStringArray warnings;
    if (!last_warning.is_empty()) {
        warnings.push_back(last_warning);
    }
    auto broken = [&](const char* key, const std::string& sentence) {
        checks[key] = String("fail: ") + mesh::ops::text(sentence);
        last_report["checks"] = checks;
        last_warning = String();
        fail(sentence);
        return Ref<CadMesh>();
    };
    // Must hold: closed and manifold, every triangle from an input, and the volume on the right
    // side of the inputs' volumes.
    const mesh::Summary after = mesh::summarize(out->get_state());
    if (after.triangles > 0 && (after.boundary_edges > 0 || after.non_manifold_edges > 0)) {
        return broken("closed", "Combine made a mesh that is not closed (" + mesh::ops::count_text(after.boundary_edges, "open edge", "open edges") + ", " +
                                    mesh::ops::count_text(after.non_manifold_edges, "edge", "edges") + " shared by more than two triangles). Please report it.");
    }
    checks["closed"] = "ok";
    if (foreign > 0) {
        return broken("groups", "Combine made " + mesh::ops::count_text(int64_t(foreign), "triangle that belongs", "triangles that belong") + " to no input (internal error). Please report it.");
    }
    checks["groups"] = "ok";
    std::vector<double> volumes;
    double largest = 0.0, smallest = INFINITY, sum = 0.0, reach = 0.0;
    for (mesh::State* s : states) {
        const mesh::Measures& ms = mesh::measures_of(*s);
        const double v = ms.volume;
        volumes.push_back(v);
        largest = std::max(largest, v);
        smallest = std::min(smallest, v);
        sum += v;
        for (int k = 0; k < 3; ++k) {
            reach = std::max(reach, std::max(std::fabs(ms.lo[k]), std::fabs(ms.hi[k])));
        }
    }
    // What rounding the result's points to float32 can move its volume by: at most one float32
    // step of the largest coordinate, over the result's area.
    const double rounding = 1.2e-7 * reach * after.area;
    const double tol = 1e-6 * largest + rounding;
    const double v = after.volume;
    bool volume_ok = true;
    std::string promise;
    if (operation == 0) {
        volume_ok = v >= largest - tol && v <= sum + tol;
        promise = "between the largest input (" + mesh::number_text(largest, "%.6g") + " m3) and all inputs together (" + mesh::number_text(sum, "%.6g") + " m3)";
    }
    else if (operation == 1) {
        volume_ok = v <= volumes[0] + tol && v >= volumes[0] - (sum - volumes[0]) - tol;
        promise = "at most the target's (" + mesh::number_text(volumes[0], "%.6g") + " m3)";
    }
    else {
        volume_ok = v <= smallest + tol && v >= -tol;
        promise = "at most the smallest input's (" + mesh::number_text(smallest, "%.6g") + " m3)";
    }
    if (!volume_ok) {
        return broken("volume", "Combine gave a volume of " + mesh::number_text(v, "%.6g") + " m3, but it must be " + promise + ". Check the bodies for parts that cross themselves.");
    }
    checks["volume"] = "ok";
    // (Against the inputs' size, not the result's own: a thin leftover's volume is small next
    // to what the rounding moves.)
    if (std::fabs(v - library_volume) > 1e-5 * largest + rounding + 1e-18) {
        return broken("export", "Combine's result changed on the way back from the mesh library (volume " + mesh::number_text(library_volume, "%.9g") + " m3 became " +
                                    mesh::number_text(v, "%.9g") + " m3). Please report it.");
    }
    checks["export"] = "ok";
    last_report["empty"] = empty;
    if (empty) {
        warnings.push_back(mesh::ops::text("The result is empty (the tool bodies cut all of " + name_inside + " away)."));
        checks["empty"] = "warn: the result is empty";
    }
    // A join of bodies that only touch (or do not meet) is not fused. The result's solid pieces
    // are counted (closed shells with a volume above zero: a void's is below), and so are the
    // inputs': every tool that fused with something takes at least one piece off the sum, so
    // more pieces than that means a tool that fused with nothing, and that is said.
    // (Not by the nesting rule: a piece that lies against another's face is not inside it.)
    auto solid_pieces_of = [&](mesh::State& s) {
        int64_t count = 0;
        if (const mesh::Components* comps = mesh::components_of(s, &deadline)) {
            for (const mesh::Component& c : comps->list) {
                count += (c.closed && c.volume > 0.0) ? 1 : 0;
            }
        }
        return count;
    };
    const int64_t solid_pieces = solid_pieces_of(out->get_state());
    int64_t fused_at_most = 1 - int64_t(states.size());
    for (mesh::State* s : states) {
        fused_at_most += std::max<int64_t>(solid_pieces_of(*s), 1);
    }
    last_report["pieces"] = solid_pieces;
    if (operation == 0 && solid_pieces > 1 && solid_pieces > fused_at_most) {
        warnings.push_back(mesh::ops::text("The joined body is still " + mesh::with_commas(uint64_t(solid_pieces)) +
                                           " separate pieces: bodies that only touch, or do not meet, are not fused."));
        checks["pieces"] = "warn: the join is more than one piece";
    }
    // Far from the origin the result's points are rounded by more than a small share of the
    // bodies' size: the input that loses most is named, with the numbers.
    {
        size_t worst = 0;
        double worst_share = 0.0;
        for (size_t i = 0; i < states.size(); ++i) {
            const mesh::ops::Place place = mesh::ops::place_of(*states[i]);
            const double share = place.diagonal > 0.0 ? place.step / place.diagonal : 0.0;
            if (share > worst_share) {
                worst_share = share;
                worst = i;
            }
        }
        const std::string note = mesh::ops::rounding_note(*states[worst], body_names[worst]);
        if (!note.empty()) {
            warnings.push_back(mesh::ops::text(note));
            checks["precision"] = "warn: far from the origin for its size";
        }
    }
    // Crossings. Inputs that cross themselves are named: the result may be wrong there. Only
    // when every input was tested clean are crossings in the result the result's own.
    const int64_t crossings = mesh::ops::crossings(out->get_state(), deadline);
    last_report["self_intersections"] = crossings;
    PackedInt64Array per_input;
    bool any_crossing = false, any_untested = false;
    for (size_t i = 0; i < states.size(); ++i) {
        per_input.push_back(input_crossings[i]);
        if (input_crossings[i] > 0) {
            warnings.push_back(mesh::ops::text(body_names[i] + " crosses itself, so the result may be wrong there. Rebuild it first."));
            any_crossing = true;
        }
        else if (input_crossings[i] < 0) {
            warnings.push_back(mesh::ops::text(body_names[i] + " could not be tested for places where it crosses itself in the time left (it is too large to test in 1 s); if it does, " +
                                               "the result may be wrong there."));
            any_untested = true;
        }
    }
    last_report["input_self_intersections"] = per_input;
    if (any_crossing) {
        checks["self_intersections"] = "warn: an input crosses itself";
    }
    else if (any_untested) {
        checks["self_intersections"] = "warn: an input could not be tested in time";
    }
    else if (crossings > 0) {
        const std::string sentence = "Combine made " + mesh::ops::count_text(crossings, "place", "places") + " where the mesh crosses itself.";
        warnings.push_back(mesh::ops::text(sentence));
        checks["self_intersections"] = String("warn: ") + mesh::ops::text(sentence);
    }
    else if (crossings == 0) {
        checks["self_intersections"] = "ok";
    }
    // (For the record: groups that are wholly inside another body are gone, by design.)
    last_report["groups_lost"] = int64_t(names.size()) - int64_t(after.groups);
    phases.mark("finish");
    last_report["phases"] = phases.ms;
    last_report["estimate"] = seconds;
    last_report["checks"] = checks;
    last_report["ms"] = mesh::ops::now_ms() - started;
    last_warning = String("\n").join(warnings);
    return out;
}

Ref<CadMesh> CadMesh::merge_with(const Array& others)
{
    clear_messages();
    const double started = mesh::ops::now_ms();
    std::vector<Ref<CadMesh>> bodies;
    std::string error;
    if (!mesh_list(others, "Merge", bodies, error)) {
        fail(error);
        return Ref<CadMesh>();
    }
    if (bodies.empty()) {
        fail("Merge needs at least one other mesh body.");
        return Ref<CadMesh>();
    }
    if (is_null()) {
        fail("There is no mesh to merge into.");
        return Ref<CadMesh>();
    }
    uint64_t triangles = state->data.triangle_count(), vertices = state->data.vertex_count(), groups = state->data.group_count();
    for (size_t i = 0; i < bodies.size(); ++i) {
        if (bodies[i]->is_null()) {
            fail("Merge needs mesh bodies with triangles: item " + std::to_string(i + 1) + " has none.");
            return Ref<CadMesh>();
        }
        triangles += bodies[i]->data().triangle_count();
        vertices += bodies[i]->data().vertex_count();
        groups += bodies[i]->data().group_count();
    }
    if (triangles > mesh::budget::MAX_TRIANGLES_MESH || vertices > mesh::budget::MAX_VERTICES_MESH || groups > mesh::budget::MAX_GROUPS_MESH) {
        fail("Merge would make " + mesh::with_commas(triangles) + " triangles, " + mesh::with_commas(vertices) + " vertices and " + mesh::with_commas(groups) +
             " face groups; mesh bodies take up to " + mesh::with_commas(mesh::budget::MAX_TRIANGLES_MESH) + ", " + mesh::with_commas(mesh::budget::MAX_VERTICES_MESH) +
             " and " + mesh::with_commas(mesh::budget::MAX_GROUPS_MESH) + ". Reduce the bodies first.");
        return Ref<CadMesh>();
    }
    mesh::MeshData merged = state->data;
    merged.positions.reserve(size_t(vertices) * 3);
    merged.triangles.reserve(size_t(triangles) * 3);
    merged.groups.reserve(size_t(triangles));
    std::unordered_set<std::string> taken(merged.group_names.begin(), merged.group_names.end());
    for (const Ref<CadMesh>& body : bodies) {
        const mesh::MeshData& other = body->data();
        const uint32_t vertex_base = uint32_t(merged.vertex_count()), group_base = uint32_t(merged.group_count());
        merged.positions.insert(merged.positions.end(), other.positions.begin(), other.positions.end());
        for (const uint32_t v : other.triangles) {
            merged.triangles.push_back(v + vertex_base);
        }
        for (const uint32_t g : other.groups) {
            merged.groups.push_back(g + group_base);
        }
        for (const std::string& group : other.group_names) {
            merged.group_names.push_back(mesh::ops::unique_name(group, taken));
        }
    }
    Ref<CadMesh> out = finish_op("Merge", "merge_with", std::move(merged), started, false);
    if (out.is_null()) {
        return out;
    }
    // Must hold: every triangle is still there.
    Dictionary checks = last_report["checks"];
    if (uint64_t(out->data().triangle_count()) != triangles) {
        checks["triangles"] = "fail: the triangle count changed";
        last_report["checks"] = checks;
        last_warning = String();
        fail("Merge lost triangles (internal error). Please report it.");
        return Ref<CadMesh>();
    }
    checks["triangles"] = "ok";
    last_report["checks"] = checks;
    return out;
}

}  // namespace holo_forge
