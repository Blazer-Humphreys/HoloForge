// Separate (work order 3.3.12): a body's pieces as bodies of their own.
// The pieces are the body's edge-connected parts; every void is put back with the solid shell
// around it (the nesting rule, work order 2.6.3). Every piece is built from the input's own
// arrays, so positions, triangle order and face groups are the input's to the bit.
// A closed solid is also taken apart by Manifold's Decompose, which can only join our parts
// (two shells that Manifold holds to be one), never split one. Decompose costs its parts times
// its triangles and cannot be stopped, so the pieces are counted first, and it is left out
// when that product is large (the pieces are then our own parts alone).

#include "cad_mesh.h"
#include "mesh_manifold.h"

#include <godot_cpp/variant/packed_int32_array.hpp>

#include <algorithm>
#include <cmath>
#include <exception>

using namespace godot;

namespace holo_forge
{

namespace
{
using mesh::MeshData;
using mesh::NONE;
constexpr size_t kMaxPieces = 1000;
const char* const kHint = "Reduce the body first.";

struct UnionFind
{
    std::vector<uint32_t> parent;
    explicit UnionFind(size_t n) : parent(n)
    {
        for (size_t i = 0; i < n; ++i) {
            parent[i] = uint32_t(i);
        }
    }
    uint32_t find(uint32_t x)
    {
        while (parent[x] != x) {
            parent[x] = parent[parent[x]];
            x = parent[x];
        }
        return x;
    }
    void join(uint32_t a, uint32_t b)
    {
        a = find(a);
        b = find(b);
        if (a != b) {
            parent[std::max(a, b)] = std::min(a, b);
        }
    }
    size_t roots()
    {
        size_t count = 0;
        for (size_t i = 0; i < parent.size(); ++i) {
            count += parent[i] == i ? 1 : 0;
        }
        return count;
    }
};
}  // namespace

Array CadMesh::separate(const Dictionary& options)
{
    clear_messages();
    const double started = mesh::ops::now_ms();
    Array none;
    if (is_null()) {
        fail("There is no mesh to separate.");
        return none;
    }
    mesh::ops::Options o(options);
    const int by = o.choice("by", "Separate By", {"components", "groups"}, 0);
    const double limit = o.time_limit();
    const bool skip_estimate = o.skip_estimate();
    const std::string name = o.name(false), name_start = o.name(true);
    mesh::ops::Phases phases;
    if (!o.ok()) {
        fail(o.problem());
        return none;
    }
    using namespace mesh::budget;
    const MeshData& m = state->data;
    const size_t T = m.triangle_count(), V = m.vertex_count(), G = m.group_count();
    // Our own part: the edges, the parts with their nesting, the pieces. All of it by the triangles.
    const double own_seconds = estimate(TOPOLOGY, double(T)) * 3.0 + estimate(BVH_BUILD, double(T)) + estimate(OP_FINISH, double(T));
    if (own_seconds > limit && !skip_estimate) {
        fail(mesh::ops::too_slow("Separate", own_seconds, limit, kHint));
        return none;
    }
    const mesh::Deadline deadline(limit);
    auto late = [&]() {
        fail(mesh::ops::timed_out("Separate", limit, kHint));
        return none;
    };
    auto too_many = [&](size_t count) {
        fail(name_start + " has " + mesh::with_commas(count) + " separate pieces; Separate makes up to " + mesh::with_commas(kMaxPieces) +
             " bodies. Run Stitch and Remove first to drop the small ones.");
        return none;
    };
    const mesh::Topology* topo = mesh::topology_of(*state, &deadline);
    if (topo == nullptr) {
        return late();
    }
    Dictionary checks;
    checks["valid"] = "ok";
    PackedStringArray warnings;
    double seconds = own_seconds;

    // label[t]: which piece a triangle goes to (numbered later, by smallest triangle).
    std::vector<uint32_t> label(T, 0);
    int64_t inside_out = 0, voids_attached = 0;
    bool through_manifold = false;
    if (by == 1) {
        if (G > kMaxPieces) {
            // (Groups without triangles do not exist in a mesh body: every group is a piece.)
            return too_many(G);
        }
        for (size_t t = 0; t < T; ++t) {
            label[t] = m.groups[t];
        }
    }
    else {
        const mesh::Components* comps = mesh::nested_components_of(*state, &deadline);
        if (comps == nullptr) {
            return late();
        }
        const size_t C = comps->list.size();
        phases.mark("components");
        UnionFind pieces(C + 1);  // (C: the triangles that are in no part; they go with triangle 0's piece)
        // Each void goes to the smallest solid shell that holds it: the first shell with
        // positive volume up its chain of parents (the nesting rule's containment).
        for (size_t c = 0; c < C; ++c) {
            const mesh::Component& comp = comps->list[c];
            if (!comp.consistent || !(comp.volume < 0.0)) {
                continue;
            }
            int holder = comp.parent;
            int guard = 0;
            while (holder >= 0 && !(comps->list[size_t(holder)].volume > 0.0) && guard++ < int(C)) {
                holder = comps->list[size_t(holder)].parent;
            }
            if (holder >= 0 && comps->list[size_t(holder)].volume > 0.0) {
                pieces.join(uint32_t(c), uint32_t(holder));
                ++voids_attached;
            }
        }
        // The pieces are counted before anything costly: Manifold below can only join some.
        const size_t counted = pieces.roots() - 1;
        const bool solid = topo->edge_count() > 0 && topo->boundary_edges == 0 && topo->non_manifold_edges == 0 && topo->inconsistent_edges == 0;
        // Decompose costs about its parts x its triangles (measured: 1.0 s at 2,000 x 8,000,
        // 7 s at 5,000 x 20,000, 26 s at 10,000 x 40,000) and takes no context: it is used
        // only where that product is small, whatever the time limit is.
        bool decompose = solid && C >= 2 && double(C) * double(T) <= DECOMPOSE_MAX_PARTS_X_TRIANGLES;
        const char* left_out = "too many parts for it";
        if (counted > kMaxPieces) {
            return too_many(counted);
        }
        const double manifold_seconds =
            estimate(MF_INGEST, double(T)) + estimate(MANIFOLD_DECOMPOSE, double(T)) + double(C) * double(T) * DECOMPOSE_SECONDS_PER_PART_TRIANGLE;
        // The library's split can only join parts we found, and it cannot be stopped: where it
        // would not fit the time it is left out and the pieces are our own, not a refusal.
        if (decompose && !skip_estimate && (seconds + manifold_seconds > limit || manifold_seconds > deadline.remaining())) {
            decompose = false;
            left_out = "it would not fit the time limit";
        }
        if (decompose) {
            seconds += manifold_seconds;
            if (manifold_seconds > deadline.remaining()) {
                return late();  // (it cannot be stopped once started)
            }
            try {
                manifold::ExecutionContext ctx;
                const mesh::mf::Watchdog watchdog(ctx, deadline);
                const uint32_t run_id = manifold::Manifold::ReserveIDs(1);
                // Each triangle's own index travels as its face id, so every part can be read
                // back as a set of input triangles.
                const manifold::Manifold body = ctx.FromMeshGL(mesh::mf::to_gl(m, run_id, 0, true));
                const mesh::mf::Status status = body.Status();
                phases.mark("ingest");
                if (status == mesh::mf::Status::Cancelled || deadline.expired()) {
                    return late();
                }
                if (status != mesh::mf::Status::NoError) {
                    // (Our own parts give the same pieces; the report says Manifold was not used.)
                    checks["decompose"] = String("warn: ") + mesh::ops::text(mesh::mf::status_text(status, "Separate"));
                }
                else {
                    const std::vector<manifold::Manifold> parts = body.Decompose();
                    for (const manifold::Manifold& part : parts) {
                        const manifold::MeshGL64 gl = part.GetMeshGL64();
                        uint32_t first = NONE;
                        for (const uint64_t id : gl.faceID) {
                            if (id >= T || comps->of_triangle[size_t(id)] < 0) {
                                continue;
                            }
                            const uint32_t c = uint32_t(comps->of_triangle[size_t(id)]);
                            if (first == NONE) {
                                first = c;
                            }
                            else {
                                pieces.join(first, c);
                            }
                        }
                        if (deadline.expired()) {
                            return late();
                        }
                    }
                    checks["decompose"] = "ok";
                    through_manifold = true;
                    last_report["manifold_parts"] = int64_t(parts.size());
                    phases.mark("decompose");
                }
            }
            catch (const std::exception& e) {
                fail(std::string("Separate failed inside the mesh library: ") + e.what());
                return none;
            }
            catch (...) {
                fail("Separate failed inside the mesh library.");
                return none;
            }
            if (pieces.roots() - 1 > kMaxPieces) {
                return too_many(pieces.roots() - 1);
            }
        }
        else if (solid && C >= 2) {
            checks["decompose"] = String("ok: left out (") + left_out + "); the pieces are the body's connected parts";
        }
        const uint32_t loose = uint32_t(C);
        for (size_t t = 0; t < T; ++t) {
            label[t] = comps->of_triangle[t] >= 0 ? pieces.find(uint32_t(comps->of_triangle[t])) : loose;
        }
        if (T > 0 && label[0] != loose) {
            for (size_t t = 0; t < T; ++t) {
                if (label[t] == loose) {
                    label[t] = label[0];
                }
            }
        }
        // A piece that is one or more voids with no solid shell around them is inside-out.
        std::vector<double> volume(C + 1, 0.0);
        std::vector<uint8_t> has_solid(C + 1, 0), closed(C + 1, 1), has_void(C + 1, 0);
        for (size_t c = 0; c < C; ++c) {
            const uint32_t root = pieces.find(uint32_t(c));
            const mesh::Component& comp = comps->list[c];
            volume[root] += comp.volume;
            if (!comp.consistent) {
                closed[root] = 0;
            }
            else if (comp.volume > 0.0) {
                has_solid[root] = 1;
            }
            else {
                has_void[root] = 1;
            }
        }
        for (size_t c = 0; c < C; ++c) {
            if (pieces.find(uint32_t(c)) != c || closed[c] == 0) {
                continue;
            }
            if (has_solid[c] == 0) {
                ++inside_out;
            }
            else if (has_void[c] != 0 && !(volume[c] > 0.0)) {
                checks["voids"] = "fail: a piece with a void has no positive volume";
                last_report["op"] = "separate";
                last_report["checks"] = checks;
                fail("Separate made a hollow piece whose volume is not positive (internal error). Please report it.");
                return none;
            }
        }
        checks["voids"] = "ok";
    }

    // Pieces in the order of their smallest triangle.
    std::vector<uint32_t> piece_of_label;
    {
        uint32_t highest = 0;
        for (const uint32_t l : label) {
            highest = std::max(highest, l);
        }
        piece_of_label.assign(size_t(highest) + 1, NONE);
    }
    std::vector<uint32_t> counts;
    for (size_t t = 0; t < T; ++t) {
        uint32_t& piece = piece_of_label[label[t]];
        if (piece == NONE) {
            piece = uint32_t(counts.size());
            counts.push_back(0);
        }
        ++counts[piece];
    }
    const size_t P = counts.size();
    last_report["op"] = "separate";
    last_report["input"] = mesh::ops::summary_dict(mesh::summarize(*state), false);
    last_report["through_manifold"] = through_manifold;
    last_report["voids_attached"] = voids_attached;
    Array out;
    if (P <= 1) {
        // One piece: the body itself (a mesh never changes, so it can be handed on as it is).
        out.push_back(Ref<CadMesh>(this));
        warnings.push_back(mesh::ops::text(name_start + " is one piece; nothing to separate."));
        checks["pieces"] = "warn: one piece";
    }
    else {
        if (P > kMaxPieces) {
            return too_many(P);
        }
        // The triangles of each piece, in input order.
        std::vector<uint32_t> first(P + 1, 0);
        for (size_t p = 0; p < P; ++p) {
            first[p + 1] = first[p] + counts[p];
        }
        std::vector<uint32_t> order(T), cursor(first.begin(), first.end() - 1);
        for (size_t t = 0; t < T; ++t) {
            order[cursor[piece_of_label[label[t]]]++] = uint32_t(t);
        }
        // Each piece keeps the input's order of vertices and of groups, too.
        std::vector<uint32_t> vertex_stamp(V, NONE), vertex_local(V, 0), group_stamp(G, NONE), group_local(G, 0);
        std::vector<uint32_t> piece_vertices, piece_groups;
        size_t total = 0;
        for (size_t p = 0; p < P; ++p) {
            MeshData piece;
            piece.triangles.reserve(size_t(counts[p]) * 3);
            piece.groups.reserve(counts[p]);
            piece_vertices.clear();
            piece_groups.clear();
            for (uint32_t i = first[p]; i < first[p + 1]; ++i) {
                const uint32_t t = order[i];
                for (int k = 0; k < 3; ++k) {
                    const uint32_t v = m.triangles[size_t(t) * 3 + size_t(k)];
                    if (vertex_stamp[v] != p) {
                        vertex_stamp[v] = uint32_t(p);
                        piece_vertices.push_back(v);
                    }
                }
                const uint32_t g = m.groups[t];
                if (group_stamp[g] != p) {
                    group_stamp[g] = uint32_t(p);
                    piece_groups.push_back(g);
                }
                if (deadline.tick()) {
                    return late();
                }
            }
            std::sort(piece_vertices.begin(), piece_vertices.end());
            std::sort(piece_groups.begin(), piece_groups.end());
            piece.positions.reserve(piece_vertices.size() * 3);
            for (const uint32_t v : piece_vertices) {
                vertex_local[v] = uint32_t(piece.positions.size() / 3);
                piece.positions.insert(piece.positions.end(), &m.positions[size_t(v) * 3], &m.positions[size_t(v) * 3] + 3);
            }
            for (const uint32_t g : piece_groups) {
                group_local[g] = uint32_t(piece.group_names.size());
                piece.group_names.push_back(m.group_names[g]);
            }
            for (uint32_t i = first[p]; i < first[p + 1]; ++i) {
                const uint32_t t = order[i];
                for (int k = 0; k < 3; ++k) {
                    piece.triangles.push_back(vertex_local[m.triangles[size_t(t) * 3 + size_t(k)]]);
                }
                piece.groups.push_back(group_local[m.groups[t]]);
            }
            total += piece.triangle_count();
            std::string problem;
            const Ref<CadMesh> made = wrap(std::move(piece), &problem);
            if (made.is_null()) {
                checks["valid"] = String("fail: ") + mesh::ops::text(problem);
                last_report["checks"] = checks;
                fail("Separate made a broken mesh (internal error). Please report it.");
                return none;
            }
            out.push_back(made);
            if (deadline.expired()) {
                return late();
            }
        }
        // Must hold: every triangle is in exactly one piece.
        if (total != T) {
            checks["triangles"] = "fail: the pieces do not add up to the input";
            last_report["checks"] = checks;
            fail("Separate lost triangles (internal error). Please report it.");
            return none;
        }
        checks["triangles"] = "ok";
        checks["pieces"] = "ok";
    }
    if (inside_out > 0) {
        warnings.push_back(mesh::ops::text(mesh::ops::count_text(inside_out, "piece is", "pieces are") + " inside-out. Reverse Normal can fix " + (inside_out == 1 ? "it." : "them.")));
        checks["orientation"] = "warn: pieces are inside-out";
    }
    PackedInt32Array sizes;
    for (const uint32_t count : counts) {
        sizes.push_back(int32_t(count));
    }
    Dictionary output;
    output["pieces"] = int64_t(out.size());
    output["triangles"] = sizes;
    last_report["output"] = output;
    last_report["deviation"] = Dictionary();
    last_report["self_intersections"] = -1;
    last_report["checks"] = checks;
    phases.mark("pieces");
    last_report["phases"] = phases.ms;
    last_report["estimate"] = seconds;
    last_report["ms"] = mesh::ops::now_ms() - started;
    last_warning = String("\n").join(warnings);
    return out;
}

}  // namespace holo_forge
