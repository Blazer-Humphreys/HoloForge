// Mesh clean-up ops of the Mesh workspace (work order 3.2.2, 3.3.8, 3.3.9 and addendum 10.1):
// Stitch and Remove, Reverse Normal, delete_triangles and welded. All our own code.

#include "cad_mesh.h"
#include "mesh_bvh.h"
#include "mesh_pmp.h"

#include <godot_cpp/variant/packed_string_array.hpp>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <exception>
#include <unordered_map>

using namespace godot;

namespace holo_forge
{

namespace mesh
{
namespace
{
inline uint32_t next_he(uint32_t he)
{
    return he - he % 3 + (he + 1) % 3;
}

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
    /// The smaller index stays the root.
    void join(uint32_t a, uint32_t b)
    {
        a = find(a);
        b = find(b);
        if (a < b) {
            parent[b] = a;
        }
        else if (b < a) {
            parent[a] = b;
        }
    }
};

inline void flip_triangle(MeshData& m, size_t t)
{
    std::swap(m.triangles[t * 3 + 1], m.triangles[t * 3 + 2]);
}

struct OrientStats
{
    size_t flipped_triangles = 0;
    size_t flipped_pieces = 0;   // closed pieces turned by the nesting rule
    size_t one_sided_edges = 0;  // edges that cannot be made consistent (a one-sided surface)
};

/// Makes every edge-connected piece face one way (the way most of its area already faces), then
/// turns the closed pieces the nesting rule calls inside-out (work order 2.6.3: solid shells
/// face out, voids face in). False when the deadline passed; the mesh is then as it was.
bool orient_pieces(MeshData& data, OrientStats& stats, const Deadline& deadline)
{
    const size_t T = data.triangle_count();
    std::vector<uint8_t> flip(T, 0);
    {
        State state;
        state.data = std::move(data);
        const MeshData& m = state.data;
        const Topology* topo = topology_of(state, &deadline);
        if (topo == nullptr) {
            data = std::move(state.data);
            return false;
        }
        std::vector<uint8_t> seen(T, 0);
        std::vector<uint32_t> stack, piece;
        size_t conflicts = 0;
        for (size_t seed = 0; seed < T; ++seed) {
            if (seen[seed] || topo->he_edge[seed * 3] == NONE) {
                continue;
            }
            piece.clear();
            seen[seed] = 1;
            stack.push_back(uint32_t(seed));
            double area = 0.0, flipped_area = 0.0;
            while (!stack.empty()) {
                const uint32_t t = stack.back();
                stack.pop_back();
                piece.push_back(t);
                const double a = 0.5 * length(triangle_cross(m, t));
                area += a;
                flipped_area += flip[t] ? a : 0.0;
                for (uint32_t k = 0; k < 3; ++k) {
                    const uint32_t he = t * 3 + k;
                    const uint32_t other = topo->twin(he);
                    if (other == NONE) {
                        continue;
                    }
                    const uint32_t t2 = other / 3;
                    // Two triangles that run their shared edge the same way face opposite ways.
                    const uint8_t want = flip[t] ^ uint8_t(m.triangles[other] == m.triangles[he] ? 1 : 0);
                    if (!seen[t2]) {
                        seen[t2] = 1;
                        flip[t2] = want;
                        stack.push_back(t2);
                    }
                    else if (flip[t2] != want) {
                        ++conflicts;
                    }
                }
                if (deadline.tick()) {
                    data = std::move(state.data);
                    return false;
                }
            }
            if (flipped_area > 0.5 * area) {
                for (const uint32_t t : piece) {
                    flip[t] ^= 1;
                }
            }
        }
        stats.one_sided_edges = conflicts / 2;
        data = std::move(state.data);
    }
    for (size_t t = 0; t < T; ++t) {
        if (flip[t]) {
            flip_triangle(data, t);
            ++stats.flipped_triangles;
        }
    }
    State state;
    state.data = std::move(data);
    const Components* comps = nested_components_of(state, &deadline);
    if (comps == nullptr) {
        data = std::move(state.data);
        // (Put back as it was.)
        for (size_t t = 0; t < T; ++t) {
            if (flip[t]) {
                flip_triangle(data, t);
            }
        }
        stats = OrientStats();
        return false;
    }
    std::vector<uint8_t> turn(comps->list.size(), 0);
    for (size_t c = 0; c < comps->list.size(); ++c) {
        if (comps->list[c].inverted) {
            turn[c] = 1;
            ++stats.flipped_pieces;
        }
    }
    const std::vector<int32_t> of_triangle = comps->of_triangle;
    data = std::move(state.data);
    if (stats.flipped_pieces > 0) {
        for (size_t t = 0; t < T; ++t) {
            if (of_triangle[t] >= 0 && turn[size_t(of_triangle[t])]) {
                flip_triangle(data, t);
                // A triangle turned twice is back where it was.
                stats.flipped_triangles += flip[t] ? size_t(-1) : size_t(1);
            }
        }
    }
    return true;
}

}  // namespace

bool split_into_sheets(MeshData& m, SheetStats& stats, const Deadline& deadline)
{
    State state;
    state.data = std::move(m);
    const Topology* topo = topology_of(state, &deadline);
    if (topo == nullptr) {
        m = std::move(state.data);
        return false;
    }
    const MeshData& d = state.data;
    const size_t T = d.triangle_count();
    stats.non_manifold_before = topo->non_manifold_edges;
    // Around each edge more than two triangles share, the triangles are paired into sheets: a
    // triangle with the next one around the edge that closes material between them.
    std::vector<uint32_t> mate(T * 3, NONE);
    for (size_t e = 0; e < topo->edge_count(); ++e) {
        const uint32_t first = topo->edge_first[e], last = topo->edge_first[e + 1];
        const uint32_t uses = last - first;
        if (uses == 2) {
            mate[topo->edge_hes[first]] = topo->edge_hes[first + 1];
            mate[topo->edge_hes[first + 1]] = topo->edge_hes[first];
        }
        else if (uses > 2) {
            const uint32_t h0 = topo->edge_hes[first];
            const uint32_t va = std::min(d.triangles[h0], d.triangles[next_he(h0)]);
            const uint32_t vb = std::max(d.triangles[h0], d.triangles[next_he(h0)]);
            const V3 a = point_of(d, va), axis = normalized(point_of(d, vb) - a);
            // A frame across the edge.
            V3 x = cross(axis, std::fabs(axis.x) < 0.9 ? V3(1, 0, 0) : V3(0, 1, 0));
            x = normalized(x);
            const V3 y = cross(axis, x);
            struct Wing
            {
                double angle;
                uint32_t he;
                bool forward;  // runs the edge from va to vb
            };
            std::vector<Wing> wings;
            for (uint32_t i = first; i < last; ++i) {
                const uint32_t he = topo->edge_hes[i];
                const uint32_t apex = d.triangles[next_he(next_he(he))];
                const V3 w = point_of(d, apex) - a;
                wings.push_back({std::atan2(dot(w, y), dot(w, x)), he, d.triangles[he] == va});
            }
            std::sort(wings.begin(), wings.end(), [](const Wing& p, const Wing& q) { return p.angle != q.angle ? p.angle < q.angle : p.he < q.he; });
            const size_t n = wings.size();
            // Triangles at one angle are walls that lie on each other (two bodies that touch
            // face to face). There the one that ends a body's material comes before the one
            // that starts the next body's: the bodies touch, they are not one.
            for (size_t i = 0; i < n;) {
                size_t j = i + 1;
                while (j < n && wings[j].angle - wings[j - 1].angle <= 1e-9) {
                    ++j;
                }
                std::stable_partition(wings.begin() + i, wings.begin() + j, [](const Wing& w) { return w.forward; });
                i = j;
            }
            std::vector<uint8_t> taken(n, 0);
            // Material lies counter-clockwise (about va -> vb) of a triangle that runs the edge
            // backward, up to the next triangle, which must run it forward.
            for (size_t i = 0; i < n; ++i) {
                const size_t j = (i + 1) % n;
                if (!wings[i].forward && wings[j].forward && !taken[i] && !taken[j] && i != j) {
                    taken[i] = taken[j] = 1;
                    mate[wings[i].he] = wings[j].he;
                    mate[wings[j].he] = wings[i].he;
                }
            }
            // What is left (sheets that do not bound material): neighbours around the edge.
            for (size_t i = 0; i < n; ++i) {
                if (taken[i]) {
                    continue;
                }
                for (size_t step = 1; step < n; ++step) {
                    const size_t j = (i + step) % n;
                    if (!taken[j]) {
                        taken[i] = taken[j] = 1;
                        mate[wings[i].he] = wings[j].he;
                        mate[wings[j].he] = wings[i].he;
                        break;
                    }
                }
            }
        }
        if (deadline.tick()) {
            m = std::move(state.data);
            return false;
        }
    }
    // Corners of one vertex meet in more than one fan only at such edges, or where surfaces
    // touch at a point: found by joining corners across paired edges.
    UnionFind fans(T * 3);
    for (uint32_t h = 0; h < T * 3; ++h) {
        const uint32_t g = mate[h];
        if (g == NONE || g < h) {
            continue;
        }
        if (d.triangles[h] == d.triangles[g]) {
            fans.join(h, g);
            fans.join(next_he(h), next_he(g));
        }
        else {
            fans.join(h, next_he(g));
            fans.join(next_he(h), g);
        }
    }
    // The fan with a vertex's first corner keeps the vertex; every other fan gets a copy.
    MeshData fixed = d;
    std::vector<uint32_t> owner(d.vertex_count(), NONE);  // the fan root that keeps the vertex
    std::unordered_map<uint32_t, uint32_t> copies;        // fan root -> the copy
    for (uint32_t c = 0; c < T * 3; ++c) {
        if (topo->he_edge[c - c % 3] == NONE) {
            continue;  // a triangle that names a corner twice: as it is
        }
        const uint32_t v = d.triangles[c];
        const uint32_t root = fans.find(c);
        if (owner[v] == NONE) {
            owner[v] = root;
        }
        if (owner[v] == root) {
            continue;
        }
        auto it = copies.find(root);
        if (it == copies.end()) {
            const uint32_t copy = uint32_t(fixed.vertex_count());
            fixed.positions.insert(fixed.positions.end(), d.positions.begin() + size_t(v) * 3, d.positions.begin() + size_t(v) * 3 + 3);
            it = copies.emplace(root, copy).first;
            ++stats.split_vertices;
            stats.copied.push_back(v);
        }
        fixed.triangles[c] = it->second;
    }
    State after;
    after.data = std::move(fixed);
    const Topology* topo2 = topology_of(after, &deadline);
    if (topo2 == nullptr) {
        m = std::move(state.data);
        return false;
    }
    stats.non_manifold_after = topo2->non_manifold_edges;
    m = std::move(after.data);
    return true;
}

namespace
{

struct StitchOptions
{
    double tolerance = 0.0;
    bool remove_small = true;
    double min_size_percent = 1.0;
    bool remove_inner = false;
    bool fix_non_manifold = true;
};

struct StitchStats
{
    size_t welded = 0, duplicates = 0, degenerate = 0, kept_degenerate = 0, fins = 0;
    size_t pieces = 0, piece_triangles = 0, inner_pieces = 0;
    size_t non_manifold_before = 0, non_manifold_after = 0, split_vertices = 0;
    double removed_area = 0.0;  // of every removed triangle, at its position in the input
    double weld_area = 0.0;     // area the kept triangles lost by welding (input minus welded)
    OrientStats orient;
};

/// Removes the triangles flagged in drop (and their groups' entries); adds their input area.
void drop_triangles(MeshData& m, std::vector<uint32_t>& source, const std::vector<uint8_t>& drop)
{
    size_t w = 0;
    for (size_t t = 0; t < m.triangle_count(); ++t) {
        if (drop[t]) {
            continue;
        }
        if (w != t) {
            std::memcpy(&m.triangles[w * 3], &m.triangles[t * 3], sizeof(uint32_t) * 3);
            m.groups[w] = m.groups[t];
            source[w] = source[t];
        }
        ++w;
    }
    m.triangles.resize(w * 3);
    m.groups.resize(w);
    source.resize(w);
}

bool stitch(const MeshData& in, const StitchOptions& opt, const Deadline& deadline, MeshData& out, StitchStats& stats, std::string& error)
{
    const char* hint = "Lower the Stitch Tolerance, or Reduce the body first.";
    const std::string late = timed_out_text("Stitch and Remove", deadline.limit(), hint);
    const size_t V = in.vertex_count(), T0 = in.triangle_count();
    MeshData m = in;
    std::vector<uint32_t> source(T0);  // the input triangle of each triangle still here
    std::vector<double> input_area(T0);
    for (size_t t = 0; t < T0; ++t) {
        source[t] = uint32_t(t);
        input_area[t] = 0.5 * length(triangle_cross(in, t));
    }
    auto removed = [&](const std::vector<uint8_t>& drop) {
        size_t count = 0;
        for (size_t t = 0; t < drop.size(); ++t) {
            if (drop[t]) {
                stats.removed_area += input_area[source[t]];
                ++count;
            }
        }
        return count;
    };

    // 1. Weld: vertices closer than the tolerance become the one with the lowest index.
    {
        std::vector<uint8_t> used(V, 0);
        for (const uint32_t v : m.triangles) {
            used[v] = 1;
        }
        UnionFind sets(V);
        double lo[3] = {0, 0, 0};
        bool any = false;
        for (size_t v = 0; v < V; ++v) {
            if (!used[v]) {
                continue;
            }
            for (int k = 0; k < 3; ++k) {
                const double c = m.positions[v * 3 + size_t(k)];
                lo[k] = any ? std::min(lo[k], c) : c;
            }
            any = true;
        }
        // A cell as wide as the tolerance; with no tolerance only equal positions meet.
        const double cell = opt.tolerance > 0.0 ? opt.tolerance : 0.0;
        const double reach2 = opt.tolerance * opt.tolerance;
        std::unordered_map<uint64_t, uint32_t> head;
        head.reserve(V);
        std::vector<uint32_t> next(V, NONE);
        auto key_of = [](int64_t x, int64_t y, int64_t z) {
            uint64_t h = uint64_t(x) * 0x9E3779B97F4A7C15ull;
            h ^= uint64_t(y) * 0xC2B2AE3D27D4EB4Full + (h << 6) + (h >> 2);
            h ^= uint64_t(z) * 0x165667B19E3779F9ull + (h << 6) + (h >> 2);
            return h;
        };
        for (size_t v = 0; v < V; ++v) {
            if (!used[v]) {
                continue;
            }
            const V3 p = point_of(m, uint32_t(v));
            int64_t c[3];
            if (cell > 0.0) {
                for (int k = 0; k < 3; ++k) {
                    c[k] = int64_t(std::floor((p[k] - lo[k]) / cell));
                }
            }
            else {
                // Equal positions: the cell is the bit pattern (-0 counts as 0).
                for (int k = 0; k < 3; ++k) {
                    const float f = m.positions[v * 3 + size_t(k)] + 0.0f;
                    uint32_t bits = 0;
                    std::memcpy(&bits, &f, 4);
                    c[k] = int64_t(bits);
                }
            }
            const int reach = cell > 0.0 ? 1 : 0;
            for (int dz = -reach; dz <= reach; ++dz) {
                for (int dy = -reach; dy <= reach; ++dy) {
                    for (int dx = -reach; dx <= reach; ++dx) {
                        const auto it = head.find(key_of(c[0] + dx, c[1] + dy, c[2] + dz));
                        if (it == head.end()) {
                            continue;
                        }
                        for (uint32_t u = it->second - 1; u != NONE; u = next[u]) {
                            const V3 d = point_of(m, u) - p;
                            if (dot(d, d) <= reach2) {
                                sets.join(u, uint32_t(v));
                            }
                            if (deadline.tick()) {
                                error = late;
                                return false;
                            }
                        }
                    }
                }
            }
            uint32_t& first = head[key_of(c[0], c[1], c[2])];  // (a slot holds id + 1; 0 is a new one)
            next[v] = first != 0 ? first - 1 : NONE;
            first = uint32_t(v) + 1;
            if (deadline.tick()) {
                error = late;
                return false;
            }
        }
        for (size_t v = 0; v < V; ++v) {
            if (used[v] && sets.find(uint32_t(v)) != v) {
                ++stats.welded;
            }
        }
        if (stats.welded > 0) {
            for (uint32_t& v : m.triangles) {
                v = sets.find(v);
            }
        }
    }

    // 2. Triangles that name a corner twice, and copies of an earlier triangle: the same three
    // corners, the same way round. (Two triangles on the same corners that face opposite ways
    // are the two walls of bodies that touch there, or the two sides of a sheet without
    // thickness: taking one out would open a closed body. Both stay.)
    {
        const size_t T = m.triangle_count();
        std::vector<uint8_t> drop(T, 0);
        struct Key
        {
            uint32_t a, b, c, t;
            uint32_t turned;  // 1 when the corners run the other way than a < b < c does
        };
        std::vector<Key> keys;
        keys.reserve(T);
        for (size_t t = 0; t < T; ++t) {
            uint32_t v[3] = {m.triangles[t * 3], m.triangles[t * 3 + 1], m.triangles[t * 3 + 2]};
            if (v[0] == v[1] || v[1] == v[2] || v[0] == v[2]) {
                drop[t] = 1;
                ++stats.degenerate;
                continue;
            }
            // (Starting at the smallest corner, the triangle runs towards the middle one or towards the largest.)
            const int low = v[0] < v[1] ? (v[0] < v[2] ? 0 : 2) : (v[1] < v[2] ? 1 : 2);
            const uint32_t turned = v[(low + 1) % 3] < v[(low + 2) % 3] ? 0u : 1u;
            std::sort(v, v + 3);
            keys.push_back({v[0], v[1], v[2], uint32_t(t), turned});
        }
        std::sort(keys.begin(), keys.end(), [](const Key& x, const Key& y) {
            if (x.a != y.a) {
                return x.a < y.a;
            }
            if (x.b != y.b) {
                return x.b < y.b;
            }
            if (x.c != y.c) {
                return x.c < y.c;
            }
            if (x.turned != y.turned) {
                return x.turned < y.turned;
            }
            return x.t < y.t;
        });
        for (size_t i = 1; i < keys.size(); ++i) {
            if (keys[i].a == keys[i - 1].a && keys[i].b == keys[i - 1].b && keys[i].c == keys[i - 1].c && keys[i].turned == keys[i - 1].turned) {
                drop[keys[i].t] = 1;
                ++stats.duplicates;
            }
        }
        if (deadline.expired()) {
            error = late;
            return false;
        }
        removed(drop);
        drop_triangles(m, source, drop);
    }

    // Triangles without area whose three corners differ: taken out only where that opens no
    // closed edge (each of its edges is open already, or shared by more than two triangles).
    {
        State state;
        state.data = std::move(m);
        const Topology* topo = topology_of(state, &deadline);
        if (topo == nullptr) {
            error = late;
            return false;
        }
        // (By the shared rule, mesh::without_area, which check() counts by too: by the triangle's
        // own shape and place, not by the body's size. A 0.1 mm triangle of a 100 m body has area.)
        const size_t T = state.data.triangle_count();
        std::vector<uint8_t> drop(T, 0);
        size_t dropped = 0;
        for (size_t t = 0; t < T; ++t) {
            if (!without_area(state.data, t)) {
                continue;
            }
            bool free = true;
            for (uint32_t k = 0; k < 3; ++k) {
                free = free && topo->uses(topo->he_edge[t * 3 + k]) != 2;
            }
            if (free) {
                drop[t] = 1;
                ++dropped;
            }
            else {
                ++stats.kept_degenerate;
            }
        }
        m = std::move(state.data);
        if (dropped > 0) {
            stats.degenerate += removed(drop);
            drop_triangles(m, source, drop);
        }
    }

    // 3. Edges more than two triangles share.
    if (opt.fix_non_manifold) {
        // Fins first: a triangle on such an edge whose two other edges are open. (Taking one
        // out can free the next, so again until none is left; a strip of n fins takes n rounds.)
        bool first_round = true;
        for (int round = 0; round < 64; ++round) {
            State state;
            state.data = std::move(m);
            const Topology* topo = topology_of(state, &deadline);
            if (topo == nullptr) {
                error = late;
                return false;
            }
            if (first_round) {
                stats.non_manifold_before = topo->non_manifold_edges;
                first_round = false;
            }
            const size_t T = state.data.triangle_count();
            std::vector<uint8_t> drop(T, 0);
            size_t dropped = 0;
            if (topo->non_manifold_edges > 0) {
                for (size_t t = 0; t < T; ++t) {
                    int shared = 0, open = 0;
                    for (uint32_t k = 0; k < 3; ++k) {
                        const uint32_t uses = topo->uses(topo->he_edge[t * 3 + k]);
                        shared += uses > 2 ? 1 : 0;
                        open += uses == 1 ? 1 : 0;
                    }
                    if (shared == 1 && open == 2) {
                        drop[t] = 1;
                        ++dropped;
                    }
                }
            }
            m = std::move(state.data);
            if (dropped == 0) {
                break;
            }
            stats.fins += removed(drop);
            drop_triangles(m, source, drop);
        }

        // Then the rest: sheets and fans (split_into_sheets below).
        SheetStats sheets;
        if (!split_into_sheets(m, sheets, deadline)) {
            error = late;
            return false;
        }
        stats.split_vertices = sheets.split_vertices;
        stats.non_manifold_after = sheets.non_manifold_after;
        if (m.vertex_count() > budget::MAX_VERTICES_MESH) {
            error = "Stitch and Remove would need more than " + with_commas(budget::MAX_VERTICES_MESH) + " vertices to split the edges that more than two triangles share. Reduce the body first.";
            return false;
        }
    }
    else {
        State state;
        state.data = std::move(m);
        const Topology* topo = topology_of(state, &deadline);
        if (topo == nullptr) {
            error = late;
            return false;
        }
        stats.non_manifold_before = stats.non_manifold_after = topo->non_manifold_edges;
        m = std::move(state.data);
    }

    // 4. Every piece faces one way; closed pieces follow the nesting rule.
    if (!orient_pieces(m, stats.orient, deadline)) {
        error = late;
        return false;
    }

    // 5. Small pieces, and pieces inside others.
    if (opt.remove_small || opt.remove_inner) {
        State state;
        state.data = std::move(m);
        const Components* comps = opt.remove_inner ? nested_components_of(state, &deadline) : components_of(state, &deadline);
        if (comps == nullptr) {
            error = late;
            return false;
        }
        const MeshData& d = state.data;
        const size_t T = d.triangle_count(), C = comps->list.size();
        std::vector<double> area(C, 0.0);
        for (size_t t = 0; t < T; ++t) {
            if (comps->of_triangle[t] >= 0) {
                area[size_t(comps->of_triangle[t])] += 0.5 * length(triangle_cross(d, t));
            }
        }
        double largest = 0.0;
        for (const double a : area) {
            largest = std::max(largest, a);
        }
        std::vector<uint8_t> gone(C, 0);
        if (opt.remove_small) {
            const double least = largest * opt.min_size_percent / 100.0;
            for (size_t c = 0; c < C; ++c) {
                gone[c] = area[c] < least ? 1 : 0;
            }
        }
        std::vector<uint8_t> inner(C, 0);
        if (opt.remove_inner) {
            // Closed pieces inside another closed piece by the nesting rule; open pieces whose
            // sample corners all lie inside the outermost closed pieces that stay.
            bool any_shell = false, any_open = false;
            for (size_t c = 0; c < C; ++c) {
                const Component& comp = comps->list[c];
                if (comp.depth > 0) {
                    inner[c] = 1;
                }
                any_shell = any_shell || (comp.depth == 0 && !gone[c]);
                any_open = any_open || (comp.depth < 0 && !gone[c]);
            }
            if (any_shell && any_open) {
                State shells;
                for (size_t t = 0; t < T; ++t) {
                    const int32_t c = comps->of_triangle[t];
                    if (c < 0) {
                        continue;
                    }
                    if (comps->list[size_t(c)].depth == 0 && !gone[size_t(c)]) {
                        shells.data.triangles.insert(shells.data.triangles.end(), d.triangles.begin() + t * 3, d.triangles.begin() + t * 3 + 3);
                    }
                }
                shells.data.positions = d.positions;
                shells.data.groups.assign(shells.data.triangle_count(), 0);
                shells.data.group_names = {"g0"};
                // Up to 64 corners of each open piece, evenly spaced over its triangles.
                std::vector<std::vector<uint32_t>> tris_of(C);
                for (size_t t = 0; t < T; ++t) {
                    const int32_t c = comps->of_triangle[t];
                    if (c >= 0 && comps->list[size_t(c)].depth < 0 && !gone[size_t(c)]) {
                        tris_of[size_t(c)].push_back(uint32_t(t));
                    }
                }
                for (size_t c = 0; c < C; ++c) {
                    const std::vector<uint32_t>& list = tris_of[c];
                    if (list.empty()) {
                        continue;
                    }
                    const size_t take = std::min<size_t>(list.size(), 64);
                    std::vector<double> points;
                    for (size_t i = 0; i < take; ++i) {
                        const uint32_t t = list[i * list.size() / take];
                        const V3 p = point_of(d, d.triangles[size_t(t) * 3 + i % 3]);
                        points.insert(points.end(), {p.x, p.y, p.z});
                    }
                    std::vector<int32_t> winding;
                    winding_numbers(shells, points.data(), take, winding);
                    bool all_inside = true;
                    for (const int32_t w : winding) {
                        all_inside = all_inside && w != 0;
                    }
                    inner[c] = all_inside ? 1 : 0;
                    if (deadline.expired()) {
                        error = late;
                        return false;
                    }
                }
            }
        }
        std::vector<uint8_t> drop(T, 0);
        std::vector<uint8_t> counted(C, 0);
        bool any = false;
        for (size_t t = 0; t < T; ++t) {
            const int32_t c = comps->of_triangle[t];
            if (c < 0 || (!gone[size_t(c)] && !inner[size_t(c)])) {
                continue;
            }
            drop[t] = 1;
            any = true;
            ++stats.piece_triangles;
            if (!counted[size_t(c)]) {
                counted[size_t(c)] = 1;
                ++stats.pieces;
                stats.inner_pieces += (inner[size_t(c)] && !gone[size_t(c)]) ? 1 : 0;
            }
        }
        m = std::move(state.data);
        if (any) {
            removed(drop);
            drop_triangles(m, source, drop);
        }
    }

    // What welding did to the area of the triangles that stay.
    for (size_t t = 0; t < m.triangle_count(); ++t) {
        stats.weld_area += input_area[source[t]] - 0.5 * length(triangle_cross(m, t));
    }
    if (m.triangle_count() == 0) {
        error = "Stitch and Remove would leave nothing of the mesh. Lower the Stitch Tolerance or the Smallest Piece to Keep.";
        return false;
    }
    out = std::move(m);
    return true;
}

}  // namespace
}  // namespace mesh

// ---------------------------------------------------------------- welded

Ref<CadMesh> CadMesh::welded()
{
    clear_messages();
    const double started = mesh::op_now_ms();
    if (is_null()) {
        fail("There is no mesh to weld.");
        return Ref<CadMesh>();
    }
    mesh::MeshData data = state->data;
    const size_t before = data.vertex_count();
    const size_t removed = mesh::weld_exact(data);
    Ref<CadMesh> out = finish_op("Weld", "welded", std::move(data), started, false);
    if (out.is_valid()) {
        last_report["welded_vertices"] = int64_t(removed);
        last_report["vertices_before"] = int64_t(before);
    }
    return out;
}

// ---------------------------------------------------------------- delete_triangles

Ref<CadMesh> CadMesh::delete_triangles(const PackedInt32Array& tris)
{
    clear_messages();
    const double started = mesh::op_now_ms();
    if (is_null()) {
        fail("There is no mesh to delete triangles from.");
        return Ref<CadMesh>();
    }
    const mesh::MeshData& m = state->data;
    const size_t T = m.triangle_count();
    std::vector<uint32_t> list;
    std::string error;
    if (!mesh::triangle_list(tris, T, list, error)) {
        fail(error);
        return Ref<CadMesh>();
    }
    if (list.empty()) {
        fail("Select the triangles to delete.");
        return Ref<CadMesh>();
    }
    if (list.size() == T) {
        fail("Deleting every triangle would leave nothing of the mesh. Delete the body instead.");
        return Ref<CadMesh>();
    }
    std::vector<uint8_t> gone(T, 0);
    for (const uint32_t t : list) {
        gone[t] = 1;
    }
    // The triangles that stay, in order; vertices compacted here so the map back is known.
    std::vector<uint32_t> kept;
    kept.reserve(T - list.size());
    for (size_t t = 0; t < T; ++t) {
        if (!gone[t]) {
            kept.push_back(uint32_t(t));
        }
    }
    mesh::MeshData data;
    data.group_names = m.group_names;
    data.triangles.resize(kept.size() * 3);
    data.groups.resize(kept.size());
    std::vector<uint32_t> remap(m.vertex_count(), mesh::NONE);
    for (const uint32_t t : kept) {
        for (int k = 0; k < 3; ++k) {
            remap[m.triangles[size_t(t) * 3 + size_t(k)]] = 0;
        }
    }
    uint32_t next = 0;
    for (size_t v = 0; v < m.vertex_count(); ++v) {
        if (remap[v] == 0) {
            remap[v] = next++;
            data.positions.insert(data.positions.end(), m.positions.begin() + v * 3, m.positions.begin() + v * 3 + 3);
        }
    }
    for (size_t i = 0; i < kept.size(); ++i) {
        for (int k = 0; k < 3; ++k) {
            data.triangles[i * 3 + size_t(k)] = remap[m.triangles[size_t(kept[i]) * 3 + size_t(k)]];
        }
        data.groups[i] = m.groups[kept[i]];
    }
    Ref<CadMesh> out = finish_op("Delete", "delete_triangles", std::move(data), started, false);
    if (out.is_null()) {
        return out;
    }
    // Which open loops of the result the deletion made (they hold an edge that had two
    // triangles before), and which of those also run along an edge that was open already.
    const mesh::Topology* before = mesh::topology_of(*state);
    mesh::State& result = out->get_state();
    const mesh::MeshData& r = result.data;
    const mesh::Topology* after = mesh::topology_of(result);
    std::unordered_map<uint64_t, uint32_t> open_he;  // (from, to) of the result -> its half-edge
    for (uint32_t he = 0; he < r.triangles.size(); ++he) {
        const uint32_t e = after->he_edge[he];
        if (e != mesh::NONE && after->uses(e) == 1) {
            const uint32_t to = r.triangles[he - he % 3 + (he + 1) % 3];
            open_he[(uint64_t(r.triangles[he]) << 32) | to] = he;
        }
    }
    PackedInt32Array new_loops, merged_loops;
    const std::vector<mesh::BoundaryLoop> loops = mesh::boundary_loops(result);
    for (size_t i = 0; i < loops.size(); ++i) {
        const std::vector<uint32_t>& v = loops[i].vertices;
        const size_t n = v.size();
        const size_t segments = loops[i].closed ? n : n - 1;
        bool fresh = false, old = false;
        for (size_t k = 0; k < segments; ++k) {
            const auto it = open_he.find((uint64_t(v[k]) << 32) | v[(k + 1) % n]);
            if (it == open_he.end()) {
                continue;
            }
            // The same corner of the same triangle in the input.
            const uint32_t he = kept[it->second / 3] * 3 + it->second % 3;
            const uint32_t e = before->he_edge[he];
            if (e != mesh::NONE && before->uses(e) == 1) {
                old = true;
            }
            else {
                fresh = true;
            }
        }
        if (fresh) {
            new_loops.push_back(int32_t(i));
            if (old) {
                merged_loops.push_back(int32_t(i));
            }
        }
    }
    last_report["deleted_triangles"] = int64_t(list.size());
    last_report["new_loops"] = new_loops;
    last_report["merged_loops"] = merged_loops;
    return out;
}

// ---------------------------------------------------------------- reverse

Ref<CadMesh> CadMesh::reverse(const Dictionary& options)
{
    clear_messages();
    const double started = mesh::op_now_ms();
    if (is_null()) {
        fail("There is no mesh to reverse.");
        return Ref<CadMesh>();
    }
    const mesh::MeshData& m = state->data;
    const size_t T = m.triangle_count();
    mesh::OptionReader reader(options);
    const int mode = reader.choice("mode", "Mode", {"whole", "selection", "auto"}, 2);
    bool given = false;
    std::vector<uint32_t> picked = reader.triangles("triangles", T, &given);
    // Groups may be picked by name too.
    if (reader.ok() && options.has("groups")) {
        const Variant v = options["groups"];
        if (v.get_type() != Variant::PACKED_STRING_ARRAY && v.get_type() != Variant::ARRAY) {
            reader.refuse("The face groups to reverse must be given by name.");
        }
        else {
            const Array names = v;
            const mesh::GroupIndex& index = mesh::group_index_of(*state);
            for (int64_t i = 0; i < names.size() && reader.ok(); ++i) {
                const int g = find_face(String(names[i]));
                if (g < 0) {
                    reader.refuse("Face group '" + std::string(String(names[i]).utf8().get_data()) + "' is not in the mesh.");
                    break;
                }
                picked.insert(picked.end(), index.tris.begin() + index.first[size_t(g)], index.tris.begin() + index.first[size_t(g) + 1]);
            }
            std::sort(picked.begin(), picked.end());
            picked.erase(std::unique(picked.begin(), picked.end()), picked.end());
            given = true;
        }
    }
    const double limit = reader.time_limit();
    if (!reader.ok()) {
        fail(reader.error());
        return Ref<CadMesh>();
    }
    if (mode == 1 && picked.empty()) {
        fail("Select the triangles or face groups to reverse.");
        return Ref<CadMesh>();
    }
    const char* hint = "Reverse the whole body, or a selection.";
    mesh::MeshData data = m;
    mesh::OrientStats stats;
    if (mode == 0) {
        for (size_t t = 0; t < T; ++t) {
            mesh::flip_triangle(data, t);
        }
        stats.flipped_triangles = T;
    }
    else if (mode == 1) {
        for (const uint32_t t : picked) {
            mesh::flip_triangle(data, t);
        }
        stats.flipped_triangles = picked.size();
    }
    else {
        const double estimate = mesh::budget::estimate(mesh::budget::ORIENT, double(T)) + mesh::post_check_estimate(double(T), false);
        if (estimate > limit) {
            fail(mesh::too_slow_text("Reverse Normal", estimate, limit, hint));
            return Ref<CadMesh>();
        }
        const mesh::Deadline deadline(limit);
        bool ok = false;
        try {
            ok = mesh::orient_pieces(data, stats, deadline);
        }
        catch (const std::exception& e) {
            fail(mesh::library_error("Reverse Normal", e.what()));
            return Ref<CadMesh>();
        }
        if (!ok) {
            fail(mesh::timed_out_text("Reverse Normal", limit, hint));
            return Ref<CadMesh>();
        }
    }
    Ref<CadMesh> out = finish_op("Reverse Normal", "reverse", std::move(data), started, false);
    if (out.is_null()) {
        return out;
    }
    Dictionary checks = last_report.get("checks", Dictionary());
    last_report["flipped_triangles"] = int64_t(stats.flipped_triangles);
    last_report["flipped_pieces"] = int64_t(stats.flipped_pieces);
    if (mode == 1) {
        // A reversed selection faces the other way than what surrounds it: said, with the count.
        const int64_t now = mesh::topology_of(out->get_state())->inconsistent_edges, were = mesh::topology_of(*state)->inconsistent_edges;
        last_report["disagreeing_edges"] = now;
        if (now > were) {
            const std::string text = "The reversed triangles now face the other way than their neighbours along " + mesh::counted(uint64_t(now - were), "edge", "edges") + ".";
            checks["orientation"] = String("warn: ") + mesh::op_text(text);
            last_report["checks"] = checks;
            last_warning = last_warning.is_empty() ? mesh::op_text(text) : last_warning + String("\n") + mesh::op_text(text);
        }
    }
    if (mode == 2) {
        // Must hold: no closed piece is inside-out by the nesting rule.
        const mesh::Components* comps = mesh::nested_components_of(out->get_state());
        int64_t inverted = 0;
        for (const mesh::Component& c : comps->list) {
            inverted += c.inverted ? 1 : 0;
        }
        if (inverted > 0) {
            const std::string text = "Reverse Normal left " + mesh::with_commas(uint64_t(inverted)) + " closed parts inside-out (internal error). Please report it.";
            checks["orientation"] = String("fail: ") + mesh::op_text(text);
            last_report["checks"] = checks;
            fail(text);
            return Ref<CadMesh>();
        }
        checks["orientation"] = "ok";
        if (stats.one_sided_edges > 0) {
            const std::string text = mesh::counted(uint64_t(stats.one_sided_edges), "edge", "edges") + " could not be made to agree: the surface is one-sided there.";
            checks["one_sided"] = String("warn: ") + mesh::op_text(text);
            last_warning = last_warning.is_empty() ? mesh::op_text(text) : last_warning + String("\n") + mesh::op_text(text);
        }
        last_report["checks"] = checks;
    }
    return out;
}

// ---------------------------------------------------------------- stitch_and_remove

Ref<CadMesh> CadMesh::stitch_and_remove(const Dictionary& options)
{
    clear_messages();
    const double started = mesh::op_now_ms();
    if (is_null()) {
        fail("There is no mesh to stitch.");
        return Ref<CadMesh>();
    }
    const size_t T = state->data.triangle_count();
    const double D = mesh::measures_of(*state).diagonal;
    mesh::OptionReader reader(options);
    mesh::StitchOptions opt;
    opt.tolerance = reader.number("tolerance", "Stitch Tolerance", D * 1e-5, 0.0, D / 100.0, "m");
    opt.remove_small = reader.flag("remove_small", "Remove Small Pieces", true);
    opt.min_size_percent = reader.number("min_size", "Smallest Piece to Keep", 1.0, 0.0, 50.0, "%");
    opt.remove_inner = reader.flag("remove_inner", "Remove Pieces Inside Others", false);
    opt.fix_non_manifold = reader.flag("fix_non_manifold", "Fix Non-Manifold Edges", true);
    const double limit = reader.time_limit();
    if (!reader.ok()) {
        fail(reader.error());
        return Ref<CadMesh>();
    }
    const char* hint = "Lower the Stitch Tolerance, or Reduce the body first.";
    const double estimate = mesh::budget::estimate(mesh::budget::STITCH, double(T)) + mesh::post_check_estimate(double(T), true);
    if (estimate > limit) {
        fail(mesh::too_slow_text("Stitch and Remove", estimate, limit, hint));
        return Ref<CadMesh>();
    }
    const mesh::Deadline deadline(limit);
    mesh::MeshData data;
    mesh::StitchStats stats;
    std::string error;
    bool ok = false;
    try {
        ok = mesh::stitch(state->data, opt, deadline, data, stats, error);
    }
    catch (const std::exception& e) {
        error = mesh::library_error("Stitch and Remove", e.what());
    }
    catch (...) {
        error = mesh::library_error("Stitch and Remove", nullptr);
    }
    if (!ok) {
        fail(error);
        return Ref<CadMesh>();
    }
    const double area_before = mesh::measures_of(*state).area;
    Ref<CadMesh> out = finish_op("Stitch and Remove", "stitch_and_remove", std::move(data), started, true);
    if (out.is_null()) {
        return out;
    }
    Dictionary checks = last_report.get("checks", Dictionary());
    PackedStringArray warnings;
    if (!last_warning.is_empty()) {
        warnings = last_warning.split("\n");
    }
    const size_t removed_triangles = stats.duplicates + stats.degenerate + stats.fins + stats.piece_triangles;
    const size_t fixed_edges = stats.non_manifold_before > stats.non_manifold_after ? stats.non_manifold_before - stats.non_manifold_after : 0;
    last_report["welded_vertices"] = int64_t(stats.welded);
    last_report["removed_triangles"] = int64_t(removed_triangles);
    last_report["removed_duplicates"] = int64_t(stats.duplicates);
    last_report["removed_degenerate"] = int64_t(stats.degenerate);
    last_report["kept_degenerate"] = int64_t(stats.kept_degenerate);
    last_report["removed_fins"] = int64_t(stats.fins);
    last_report["removed_pieces"] = int64_t(stats.pieces);
    last_report["removed_inner_pieces"] = int64_t(stats.inner_pieces);
    last_report["fixed_non_manifold_edges"] = int64_t(fixed_edges);
    last_report["split_vertices"] = int64_t(stats.split_vertices);
    last_report["flipped_triangles"] = int64_t(stats.orient.flipped_triangles);
    last_report["flipped_pieces"] = int64_t(stats.orient.flipped_pieces);
    last_report["summary"] = mesh::op_text("Welded " + mesh::counted(uint64_t(stats.welded), "vertex", "vertices") + ", removed " + mesh::counted(uint64_t(removed_triangles), "triangle", "triangles") + " and " +
                                           mesh::counted(uint64_t(stats.pieces), "piece", "pieces") + ", fixed " + mesh::counted(uint64_t(fixed_edges), "non-manifold edge", "non-manifold edges") + ".");

    // Must hold: no new edges that more than two triangles share.
    const mesh::Topology* after = mesh::topology_of(out->get_state());
    const mesh::Topology* before = mesh::topology_of(*state);
    if (after->non_manifold_edges > before->non_manifold_edges) {
        const std::string text = "Stitch and Remove made " + mesh::counted(uint64_t(after->non_manifold_edges - before->non_manifold_edges), "edge that more than two triangles share", "edges that more than two triangles share") + ". " +
                                 // (With the fix on and no tolerance, only a body that touches itself gets here: no setting helps it.)
                                 (opt.fix_non_manifold ? (opt.tolerance > 0.0 ? "Lower the Stitch Tolerance; if the body touches itself there, Rebuild makes a clean body of it."
                                                                             : "The body touches itself there (parts of its surface lie on each other); Rebuild makes a clean body of it.")
                                                       : "Turn Fix Non-Manifold Edges on (it keeps bodies that touch apart), or lower the Stitch Tolerance.");
        checks["non_manifold"] = String("fail: ") + mesh::op_text(text);
        last_report["checks"] = checks;
        fail(text);
        return Ref<CadMesh>();
    }
    // Must hold: a closed body stays closed. (More open edges on a body that was open already
    // are said: taking out doubles and fins can open them.)
    last_report["open_edges_before"] = int64_t(before->boundary_edges);
    last_report["open_edges_after"] = int64_t(after->boundary_edges);
    if (after->boundary_edges > before->boundary_edges) {
        if (before->boundary_edges == 0 && before->non_manifold_edges == 0) {
            const std::string text = "Stitch and Remove would open a closed body (" + mesh::counted(uint64_t(after->boundary_edges), "open edge", "open edges") + "). Lower the Stitch Tolerance.";
            checks["closed"] = String("fail: ") + mesh::op_text(text);
            last_report["checks"] = checks;
            fail(text);
            return Ref<CadMesh>();
        }
        const std::string text = "The mesh has " + mesh::counted(uint64_t(after->boundary_edges - before->boundary_edges), "more open edge", "more open edges") + " than before (" + mesh::with_commas(before->boundary_edges) + " -> " +
                                 mesh::with_commas(after->boundary_edges) + "): taking out double and fin triangles, or splitting edges that more than two triangles share, opened them.";
        checks["closed"] = String("warn: ") + mesh::op_text(text);
        warnings.push_back(mesh::op_text(text));
    }
    else {
        checks["closed"] = "ok";
    }
    // Must hold: the area changes only by what was removed (and by what welding moved).
    const double area_after = mesh::measures_of(out->get_state()).area;
    const double unexplained = std::fabs((area_before - area_after) - (stats.removed_area + stats.weld_area));
    last_report["removed_area"] = stats.removed_area;
    last_report["weld_area_change"] = stats.weld_area;
    if (unexplained > 1e-9 * std::max(area_before, 1e-30) + 1e-18) {
        const std::string text = "Stitch and Remove changed the area by " + mesh::number_text(unexplained * 1e6) + " mm2 more than the removed triangles explain (internal error). Please report it.";
        checks["area"] = String("fail: ") + mesh::op_text(text);
        last_report["checks"] = checks;
        fail(text);
        return Ref<CadMesh>();
    }
    if (std::fabs(stats.weld_area) > 1e-3 * area_before) {
        const std::string text = "Stitching moved the surface: the area of the kept triangles changed by " + mesh::number_text(100.0 * std::fabs(stats.weld_area) / area_before, "%.3g") +
                                 " %. Lower the Stitch Tolerance if that is too much.";
        checks["area"] = String("warn: ") + mesh::op_text(text);
        warnings.push_back(mesh::op_text(text));
    }
    else {
        checks["area"] = "ok";
    }
    {
        // Triangles that lie exactly on another one and face the same way: two pieces on each
        // other (a body and its inside-out copy, once the copy is turned), counted twice in the
        // volume. (Walls of bodies that touch face opposite ways and are not meant.)
        const mesh::MeshData& r = out->data();
        std::vector<uint64_t> keys(r.triangle_count());
        for (size_t t = 0; t < r.triangle_count(); ++t) {
            uint32_t bits[3][3];
            for (int k = 0; k < 3; ++k) {
                for (int c = 0; c < 3; ++c) {
                    const float value = r.positions[size_t(r.triangles[t * 3 + size_t(k)]) * 3 + size_t(c)] + 0.0f;
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
            keys[t] = h;
        }
        std::sort(keys.begin(), keys.end());
        uint64_t coincident = 0;
        for (size_t i = 1; i < keys.size(); ++i) {
            coincident += keys[i] == keys[i - 1] ? 1 : 0;
        }
        last_report["coincident_triangles"] = int64_t(coincident);
        if (coincident > 0) {
            const std::string text = mesh::counted(coincident, "triangle lies exactly on another one that faces", "triangles lie exactly on other ones that face") +
                                     " the same way (pieces of the body lie on each other): the volume counts them twice. Delete one of the pieces.";
            checks["coincident"] = String("warn: ") + mesh::op_text(text);
            warnings.push_back(mesh::op_text(text));
        }
    }
    if (stats.non_manifold_after > 0 && opt.fix_non_manifold) {
        const std::string text = mesh::counted(uint64_t(stats.non_manifold_after), "edge is still shared by more than two triangles (it could not be split into sheets).",
                                               "edges are still shared by more than two triangles (they could not be split into sheets).");
        checks["non_manifold_left"] = String("warn: ") + mesh::op_text(text);
        warnings.push_back(mesh::op_text(text));
    }
    if (stats.kept_degenerate > 0) {
        const std::string text = mesh::counted(uint64_t(stats.kept_degenerate), "triangle without area was kept: taking it out would open the mesh.",
                                               "triangles without area were kept: taking them out would open the mesh.");
        checks["kept_degenerate"] = String("warn: ") + mesh::op_text(text);
        warnings.push_back(mesh::op_text(text));
    }
    if (stats.orient.one_sided_edges > 0) {
        const std::string text = mesh::counted(uint64_t(stats.orient.one_sided_edges), "edge", "edges") + " could not be made to agree: the surface is one-sided there.";
        checks["one_sided"] = String("warn: ") + mesh::op_text(text);
        warnings.push_back(mesh::op_text(text));
    }
    mesh::note_untested_crossings("Stitch and Remove", last_report, checks, warnings);
    last_report["ms"] = mesh::op_now_ms() - started;  // with the checks above
    last_report["checks"] = checks;
    last_warning = String("\n").join(warnings);
    return out;
}

}  // namespace holo_forge
