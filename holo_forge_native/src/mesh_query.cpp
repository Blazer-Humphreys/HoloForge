// Read-only structures and queries of a mesh body (contract C4.2): edge topology, components
// and the nesting rule, check, boundary loops, section, ray and region selection, distances,
// group and mass properties. Everything works in doubles from the float positions.

#include "mesh_budget.h"
#include "mesh_bvh.h"
#include "mesh_data.h"

#include <Eigen/Dense>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <unordered_map>

namespace holo_forge::mesh
{

namespace
{
constexpr double kInf = std::numeric_limits<double>::infinity();

inline void sub3(const double* a, const double* b, double* r)
{
    r[0] = a[0] - b[0];
    r[1] = a[1] - b[1];
    r[2] = a[2] - b[2];
}
inline void cross3(const double* a, const double* b, double* r)
{
    r[0] = a[1] * b[2] - a[2] * b[1];
    r[1] = a[2] * b[0] - a[0] * b[2];
    r[2] = a[0] * b[1] - a[1] * b[0];
}
inline double dot3(const double* a, const double* b)
{
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}
inline double length3(const double* a)
{
    return std::sqrt(dot3(a, a));
}
inline bool has_edges(const uint32_t* t)
{
    return t[0] != t[1] && t[1] != t[2] && t[0] != t[2];
}
inline uint32_t next_he(uint32_t he)
{
    return he - he % 3 + (he + 1) % 3;
}

/// (b - a) x (c - a): twice the area, along the outward normal.
inline void triangle_normal(const MeshData& m, uint32_t t, double n[3])
{
    double a[3], b[3], c[3], e1[3], e2[3];
    m.point(m.triangles[size_t(t) * 3], a);
    m.point(m.triangles[size_t(t) * 3 + 1], b);
    m.point(m.triangles[size_t(t) * 3 + 2], c);
    sub3(b, a, e1);
    sub3(c, a, e2);
    cross3(e1, e2, n);
}

/// Adds w (s s^T + a a^T + b b^T + c c^T) to a 3x3 sum, s = a + b + c.
inline void add_second(double* sum, double w, const double* a, const double* b, const double* c)
{
    const double s[3] = {a[0] + b[0] + c[0], a[1] + b[1] + c[1], a[2] + b[2] + c[2]};
    for (int i = 0; i < 3; ++i) {
        for (int j = 0; j < 3; ++j) {
            sum[i * 3 + j] += w * (s[i] * s[j] + a[i] * a[j] + b[i] * b[j] + c[i] * c[j]);
        }
    }
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
    void join(uint32_t a, uint32_t b)
    {
        a = find(a);
        b = find(b);
        if (a != b) {
            // The smaller index stays the root, so roots do not depend on the order of joins.
            if (a < b) {
                parent[b] = a;
            }
            else {
                parent[a] = b;
            }
        }
    }
};

std::vector<uint32_t> sorted_valid(const std::vector<uint32_t>& tris, size_t count)
{
    std::vector<uint32_t> out;
    out.reserve(tris.size());
    for (const uint32_t t : tris) {
        if (size_t(t) < count) {
            out.push_back(t);
        }
    }
    std::sort(out.begin(), out.end());
    out.erase(std::unique(out.begin(), out.end()), out.end());
    return out;
}

std::vector<uint32_t> from_flags(const std::vector<uint8_t>& flags)
{
    std::vector<uint32_t> out;
    for (size_t t = 0; t < flags.size(); ++t) {
        if (flags[t]) {
            out.push_back(uint32_t(t));
        }
    }
    return out;
}
}  // namespace

// ---------------------------------------------------------------- derived structures

const Topology* topology_of(State& state, const Deadline* deadline)
{
    if (state.topology) {
        return state.topology.get();
    }
    auto late = [&]() { return deadline != nullptr && deadline->tick(); };
    const MeshData& m = state.data;
    const size_t T = m.triangle_count(), V = m.vertex_count();
    auto topo = std::make_unique<Topology>();
    topo->he_edge.assign(T * 3, NONE);

    // Half-edges bucketed by their smaller vertex, then sorted by the larger one.
    std::vector<uint32_t> start(V + 1, 0);
    for (size_t t = 0; t < T; ++t) {
        const uint32_t* tri = &m.triangles[t * 3];
        if (!has_edges(tri)) {
            continue;
        }
        for (int k = 0; k < 3; ++k) {
            ++start[size_t(std::min(tri[k], tri[(k + 1) % 3])) + 1];
        }
        if (late()) {
            return nullptr;
        }
    }
    for (size_t v = 0; v < V; ++v) {
        start[v + 1] += start[v];
    }
    struct Entry
    {
        uint32_t hi, he;
    };
    std::vector<Entry> entries(start[V]);
    {
        std::vector<uint32_t> cursor(start.begin(), start.end() - 1);
        for (size_t t = 0; t < T; ++t) {
            const uint32_t* tri = &m.triangles[t * 3];
            if (!has_edges(tri)) {
                continue;
            }
            for (int k = 0; k < 3; ++k) {
                const uint32_t u = tri[k], w = tri[(k + 1) % 3];
                entries[cursor[std::min(u, w)]++] = {std::max(u, w), uint32_t(t * 3 + size_t(k))};
            }
            if (late()) {
                return nullptr;
            }
        }
    }
    topo->edge_first.reserve(entries.size() / 2 + 16);
    topo->edge_hes.reserve(entries.size());
    for (size_t v = 0; v < V; ++v) {
        Entry* first = entries.data() + start[v];
        Entry* last = entries.data() + start[v + 1];
        if (first == last) {
            continue;
        }
        std::sort(first, last, [](const Entry& a, const Entry& b) { return a.hi != b.hi ? a.hi < b.hi : a.he < b.he; });
        for (Entry* e = first; e < last;) {
            Entry* run = e;
            while (run < last && run->hi == e->hi) {
                ++run;
            }
            const uint32_t edge = uint32_t(topo->edge_first.size());
            topo->edge_first.push_back(uint32_t(topo->edge_hes.size()));
            for (Entry* h = e; h < run; ++h) {
                topo->edge_hes.push_back(h->he);
                topo->he_edge[h->he] = edge;
            }
            const size_t uses = size_t(run - e);
            if (uses == 1) {
                ++topo->boundary_edges;
            }
            else if (uses > 2) {
                ++topo->non_manifold_edges;
            }
            else if (m.triangles[e->he] == m.triangles[(e + 1)->he]) {
                ++topo->inconsistent_edges;
            }
            e = run;
        }
        if (late()) {
            return nullptr;
        }
    }
    topo->edge_first.push_back(uint32_t(topo->edge_hes.size()));
    state.topology = std::move(topo);
    return state.topology.get();
}

const Measures& measures_of(State& state)
{
    if (state.measures) {
        return *state.measures;
    }
    auto ms = std::make_unique<Measures>();
    const MeshData& m = state.data;
    const size_t T = m.triangle_count();
    double lo[3] = {kInf, kInf, kInf}, hi[3] = {-kInf, -kInf, -kInf};
    for (const uint32_t v : m.triangles) {
        const float* p = &m.positions[size_t(v) * 3];
        for (int k = 0; k < 3; ++k) {
            lo[k] = std::min(lo[k], double(p[k]));
            hi[k] = std::max(hi[k], double(p[k]));
        }
    }
    if (T > 0) {
        ms->any = true;
        double size[3];
        for (int k = 0; k < 3; ++k) {
            ms->lo[k] = lo[k];
            ms->hi[k] = hi[k];
            ms->origin[k] = 0.5 * (lo[k] + hi[k]);
            size[k] = hi[k] - lo[k];
        }
        ms->diagonal = length3(size);
    }
    double area_sum[3] = {0, 0, 0}, volume_sum[3] = {0, 0, 0};
    for (size_t t = 0; t < T; ++t) {
        double a[3], b[3], c[3], e1[3], e2[3], n[3];
        m.point(m.triangles[t * 3], a);
        m.point(m.triangles[t * 3 + 1], b);
        m.point(m.triangles[t * 3 + 2], c);
        sub3(a, ms->origin, a);
        sub3(b, ms->origin, b);
        sub3(c, ms->origin, c);
        sub3(b, a, e1);
        sub3(c, a, e2);
        cross3(e1, e2, n);
        const double area = 0.5 * length3(n);
        double bc[3];
        cross3(b, c, bc);
        const double det = dot3(a, bc);
        ms->area += area;
        ms->volume += det / 6.0;
        for (int k = 0; k < 3; ++k) {
            const double s = a[k] + b[k] + c[k];
            area_sum[k] += area * s / 3.0;
            volume_sum[k] += det * s / 24.0;
        }
        add_second(ms->area_second, area / 12.0, a, b, c);
        add_second(ms->volume_second, det / 120.0, a, b, c);
    }
    for (int k = 0; k < 3; ++k) {
        ms->area_centre[k] = ms->origin[k] + (ms->area > 0.0 ? area_sum[k] / ms->area : 0.0);
        ms->volume_centre[k] = ms->origin[k] + (ms->volume != 0.0 ? volume_sum[k] / ms->volume : 0.0);
    }
    state.measures = std::move(ms);
    return *state.measures;
}

const Components* components_of(State& state, const Deadline* deadline)
{
    if (state.components) {
        return state.components.get();
    }
    const Topology* topo = topology_of(state, deadline);
    if (topo == nullptr) {
        return nullptr;
    }
    auto late = [&]() { return deadline != nullptr && deadline->tick(); };
    const MeshData& m = state.data;
    const Measures& ms = measures_of(state);
    const size_t T = m.triangle_count();
    auto comps = std::make_unique<Components>();
    comps->of_triangle.assign(T, -1);
    std::vector<uint32_t> stack;
    for (size_t seed = 0; seed < T; ++seed) {
        if (comps->of_triangle[seed] >= 0 || !has_edges(&m.triangles[seed * 3])) {
            continue;
        }
        const int32_t id = int32_t(comps->list.size());
        Component comp;
        comp.first_triangle = uint32_t(seed);
        comp.closed = true;
        bool consistent = true;
        for (int k = 0; k < 3; ++k) {
            comp.lo[k] = kInf;
            comp.hi[k] = -kInf;
        }
        comps->of_triangle[seed] = id;
        stack.push_back(uint32_t(seed));
        while (!stack.empty()) {
            const uint32_t t = stack.back();
            stack.pop_back();
            ++comp.triangles;
            double p[3][3];
            for (int k = 0; k < 3; ++k) {
                m.point(m.triangles[size_t(t) * 3 + size_t(k)], p[k]);
                for (int a = 0; a < 3; ++a) {
                    comp.lo[a] = std::min(comp.lo[a], p[k][a]);
                    comp.hi[a] = std::max(comp.hi[a], p[k][a]);
                }
                sub3(p[k], ms.origin, p[k]);
            }
            double bc[3];
            cross3(p[1], p[2], bc);
            comp.volume += dot3(p[0], bc) / 6.0;
            for (int k = 0; k < 3; ++k) {
                const uint32_t he = t * 3 + uint32_t(k);
                const uint32_t e = topo->he_edge[he];
                const uint32_t uses = topo->uses(e);
                if (uses != 2) {
                    comp.closed = false;
                }
                for (uint32_t i = topo->edge_first[e]; i < topo->edge_first[size_t(e) + 1]; ++i) {
                    const uint32_t other = topo->edge_hes[i];
                    if (other == he) {
                        continue;
                    }
                    if (uses == 2 && m.triangles[other] == m.triangles[he]) {
                        consistent = false;
                    }
                    const uint32_t t2 = other / 3;
                    if (comps->of_triangle[t2] < 0) {
                        comps->of_triangle[t2] = id;
                        stack.push_back(t2);
                    }
                }
            }
            if (late()) {
                return nullptr;
            }
        }
        comp.consistent = comp.closed && consistent;
        comps->list.push_back(comp);
    }
    state.components = std::move(comps);
    return state.components.get();
}

const TriBvh* bvh_of(State& state, const Deadline* deadline)
{
    if (state.bvh) {
        return state.bvh.get();
    }
    auto bvh = std::make_unique<TriBvh>();
    if (!bvh->build(state.data, deadline)) {
        return nullptr;
    }
    state.bvh = std::move(bvh);
    return state.bvh.get();
}

const Components* nested_components_of(State& state, const Deadline* deadline)
{
    const Components* base = components_of(state, deadline);
    if (base == nullptr) {
        return nullptr;
    }
    if (base->nested) {
        return base;
    }
    Components& comps = *state.components;
    const MeshData& m = state.data;
    const size_t count = comps.list.size();
    std::vector<int> depth(count, -1), parent(count, -1);
    std::vector<int32_t> shells;  // closed and consistent components
    for (size_t c = 0; c < count; ++c) {
        if (comps.list[c].consistent) {
            shells.push_back(int32_t(c));
            depth[c] = 0;
        }
    }
    if (shells.size() >= 2) {
        const TriBvh* bvh = bvh_of(state, deadline);
        if (bvh == nullptr) {
            return nullptr;
        }
        // Up to 64 vertices of each shell, evenly spaced by index.
        const size_t V = m.vertex_count();
        std::vector<int32_t> owner(V, -1);
        std::vector<uint32_t> owned(count, 0);
        for (size_t t = 0; t < m.triangle_count(); ++t) {
            const int32_t c = comps.of_triangle[t];
            if (c < 0 || !comps.list[size_t(c)].consistent) {
                continue;
            }
            for (int k = 0; k < 3; ++k) {
                const uint32_t v = m.triangles[t * 3 + size_t(k)];
                if (owner[v] < 0) {
                    owner[v] = c;
                    ++owned[size_t(c)];
                }
            }
        }
        std::vector<std::vector<uint32_t>> samples(count);
        std::vector<uint32_t> seen(count, 0), taken(count, 0);
        for (size_t v = 0; v < V; ++v) {
            const int32_t c = owner[v];
            if (c < 0) {
                continue;
            }
            const uint32_t n = owned[size_t(c)];
            const uint32_t want = std::min<uint32_t>(n, 64);
            const uint32_t j = taken[size_t(c)];
            if (j < want) {
                const uint32_t ordinal = n <= 64 ? j : uint32_t(uint64_t(j) * uint64_t(n - 1) / 63u);
                if (seen[size_t(c)] == ordinal) {
                    samples[size_t(c)].push_back(uint32_t(v));
                    ++taken[size_t(c)];
                }
            }
            ++seen[size_t(c)];
        }
        std::vector<std::pair<int32_t, int32_t>> column;  // (shell, winding) along one ray
        std::unordered_map<int32_t, uint32_t> inside;     // shell -> samples of A inside it
        for (const int32_t a : shells) {
            const Component& A = comps.list[size_t(a)];
            inside.clear();
            for (const uint32_t v : samples[size_t(a)]) {
                double p[3];
                m.point(v, p);
                column.clear();
                bvh->column(p, [&](uint32_t tri, int sign) {
                    const int32_t b = comps.of_triangle[tri];
                    if (b < 0 || b == a || !comps.list[size_t(b)].consistent) {
                        return;
                    }
                    for (auto& entry : column) {
                        if (entry.first == b) {
                            entry.second += sign;
                            return;
                        }
                    }
                    column.push_back({b, sign});
                });
                for (const auto& entry : column) {
                    if (entry.second != 0) {
                        ++inside[entry.first];
                    }
                }
                if (deadline != nullptr && deadline->expired()) {
                    return nullptr;
                }
            }
            double smallest = kInf;
            int holders = 0;
            for (const auto& entry : inside) {
                // Every sample inside (a mix means the two shells cross: not contained), and
                // B's box holds A's box.
                if (entry.second != samples[size_t(a)].size()) {
                    continue;
                }
                const Component& B = comps.list[size_t(entry.first)];
                bool holds = true;
                for (int k = 0; k < 3; ++k) {
                    holds = holds && B.lo[k] <= A.lo[k] && B.hi[k] >= A.hi[k];
                }
                if (!holds) {
                    continue;
                }
                ++holders;
                const double size = std::fabs(B.volume);
                if (size < smallest || (size == smallest && entry.first < parent[size_t(a)])) {
                    smallest = size;
                    parent[size_t(a)] = entry.first;
                }
            }
            depth[size_t(a)] = holders;
        }
    }
    for (size_t c = 0; c < count; ++c) {
        Component& comp = comps.list[c];
        comp.depth = depth[c];
        comp.parent = parent[c];
        comp.inverted = comp.depth >= 0 && ((comp.depth % 2 == 0 && comp.volume < 0.0) || (comp.depth % 2 == 1 && comp.volume > 0.0));
    }
    comps.nested = true;
    return &comps;
}

const GroupIndex& group_index_of(State& state)
{
    if (state.group_index) {
        return *state.group_index;
    }
    auto index = std::make_unique<GroupIndex>();
    const MeshData& m = state.data;
    const size_t T = m.triangle_count(), G = m.group_count();
    index->first.assign(G + 1, 0);
    for (size_t t = 0; t < T; ++t) {
        ++index->first[size_t(m.groups[t]) + 1];
    }
    for (size_t g = 0; g < G; ++g) {
        index->first[g + 1] += index->first[g];
    }
    index->tris.resize(T);
    std::vector<uint32_t> cursor(index->first.begin(), index->first.end() - 1);
    for (size_t t = 0; t < T; ++t) {
        index->tris[cursor[m.groups[t]]++] = uint32_t(t);
    }
    state.group_index = std::move(index);
    return *state.group_index;
}

uint64_t digest_of(State& state)
{
    if (!state.has_digest) {
        state.digest_value = digest(state.data);
        state.has_digest = true;
    }
    return state.digest_value;
}

size_t memory_bytes(const State& state)
{
    size_t bytes = memory_bytes(state.data);
    if (state.topology) {
        bytes += (state.topology->he_edge.capacity() + state.topology->edge_first.capacity() + state.topology->edge_hes.capacity()) * sizeof(uint32_t);
    }
    if (state.components) {
        bytes += state.components->of_triangle.capacity() * sizeof(int32_t) + state.components->list.capacity() * sizeof(Component);
    }
    if (state.bvh) {
        bytes += state.bvh->memory_bytes();
    }
    if (state.group_index) {
        bytes += (state.group_index->first.capacity() + state.group_index->tris.capacity()) * sizeof(uint32_t);
    }
    return bytes;
}

// ---------------------------------------------------------------- check

bool is_closed(State& state)
{
    if (state.data.triangle_count() == 0) {
        return false;
    }
    const Topology* topo = topology_of(state);
    return topo->edge_count() > 0 && topo->boundary_edges == 0 && topo->non_manifold_edges == 0;
}

int64_t count_degenerate(State& state)
{
    // (Each triangle by its own shape: on a body 100 m across a 0.1 mm triangle has area.)
    const MeshData& m = state.data;
    int64_t count = 0;
    for (size_t t = 0; t < m.triangle_count(); ++t) {
        count += without_area(m, t) ? 1 : 0;
    }
    return count;
}

int64_t self_intersections(State& state, const Deadline& deadline, std::vector<int32_t>* pairs)
{
    const TriBvh* bvh = bvh_of(state, &deadline);
    if (bvh == nullptr) {
        return -1;
    }
    const MeshData& m = state.data;
    const std::vector<subd::Bvh::Node>& nodes = bvh->bvh.nodes;
    const std::vector<int>& prims = bvh->bvh.prims;
    if (nodes.empty()) {
        return 0;
    }
    int64_t count = 0;
    std::vector<std::pair<int32_t, int32_t>> found;  // up to 4,096, then sorted
    // Each triangle's box and corners, in the order of the leaves: a pair of leaves is tested on
    // memory that lies together, and most pairs are told apart by their boxes alone.
    struct Record
    {
        float lo[3], hi[3];
        uint32_t v[3];
    };
    std::vector<Record> records(prims.size());
    for (size_t i = 0; i < prims.size(); ++i) {
        Record& r = records[i];
        const uint32_t* t = &m.triangles[size_t(prims[i]) * 3];
        for (int k = 0; k < 3; ++k) {
            const float x = m.positions[size_t(t[0]) * 3 + size_t(k)], y = m.positions[size_t(t[1]) * 3 + size_t(k)], z = m.positions[size_t(t[2]) * 3 + size_t(k)];
            r.lo[k] = std::min(x, std::min(y, z));
            r.hi[k] = std::max(x, std::max(y, z));
            r.v[k] = t[k];
        }
        if (deadline.tick()) {
            return -1;
        }
    }
    // A quick, strict way to tell two triangles apart before the full test: q wholly on one side
    // of p's plane, or, when q lies in that plane, wholly outside one edge of p. (Flat grids are
    // full of triangles whose boxes touch at a corner; the full test in the plane is slow.)
    auto apart = [](const double p[3][3], const double q[3][3]) {
        double e1[3], e2[3], n[3], d[3];
        sub3(p[1], p[0], e1);
        sub3(p[2], p[0], e2);
        cross3(e1, e2, n);
        for (int i = 0; i < 3; ++i) {
            double r[3];
            sub3(q[i], p[0], r);
            d[i] = dot3(n, r);
        }
        if ((d[0] > 0.0 && d[1] > 0.0 && d[2] > 0.0) || (d[0] < 0.0 && d[1] < 0.0 && d[2] < 0.0)) {
            return true;
        }
        if (d[0] != 0.0 || d[1] != 0.0 || d[2] != 0.0) {
            return false;
        }
        for (int k = 0; k < 3; ++k) {
            double edge[3], out[3];
            sub3(p[(k + 1) % 3], p[k], edge);
            cross3(edge, n, out);  // in the plane, pointing away from the triangle
            bool outside = true;
            for (int i = 0; i < 3 && outside; ++i) {
                double r[3];
                sub3(q[i], p[k], r);
                outside = dot3(out, r) > 0.0;
            }
            if (outside) {
                return true;
            }
        }
        return false;
    };
    auto test = [&](int pa, int pb) {
        const Record& A = records[size_t(pa)];
        const Record& B = records[size_t(pb)];
        if (A.lo[0] > B.hi[0] || B.lo[0] > A.hi[0] || A.lo[1] > B.hi[1] || B.lo[1] > A.hi[1] || A.lo[2] > B.hi[2] || B.lo[2] > A.hi[2]) {
            return;
        }
        // Neighbours (a shared vertex, by index or by position) touch by design.
        for (int i = 0; i < 3; ++i) {
            if (A.v[i] == B.v[0] || A.v[i] == B.v[1] || A.v[i] == B.v[2]) {
                return;
            }
        }
        if (A.v[0] == A.v[1] || A.v[1] == A.v[2] || A.v[0] == A.v[2] || B.v[0] == B.v[1] || B.v[1] == B.v[2] || B.v[0] == B.v[2]) {
            return;
        }
        double a[3][3], b[3][3];
        for (int k = 0; k < 3; ++k) {
            m.point(A.v[k], a[k]);
            m.point(B.v[k], b[k]);
        }
        for (int i = 0; i < 3; ++i) {
            for (int j = 0; j < 3; ++j) {
                if (a[i][0] == b[j][0] && a[i][1] == b[j][1] && a[i][2] == b[j][2]) {
                    return;
                }
            }
        }
        if (apart(a, b) || apart(b, a)) {
            return;
        }
        if (subd::triangles_cross(a[0], a[1], a[2], b[0], b[1], b[2], 0.0)) {
            ++count;
            if (pairs != nullptr && found.size() < 4096) {
                const int ia = prims[size_t(pa)], ib = prims[size_t(pb)];
                found.push_back({int32_t(std::min(ia, ib)), int32_t(std::max(ia, ib))});
            }
        }
    };
    // The tree against itself: every pair of leaves whose boxes meet is visited once. A compact
    // copy of the tree (float boxes: the positions are floats, so nothing is rounded) in which a
    // node of up to GROUP triangles counts as a leaf: fewer node pairs, and its triangles lie
    // together in `records`.
    constexpr int GROUP = 8;
    struct Compact
    {
        float lo[3], hi[3];
        int32_t left, right, first, count;
    };
    std::vector<Compact> tree(nodes.size());
    for (size_t i = nodes.size(); i-- > 0;) {
        const subd::Bvh::Node& n = nodes[i];
        Compact& c = tree[i];
        for (int k = 0; k < 3; ++k) {
            c.lo[k] = float(n.box.lo[k]);
            c.hi[k] = float(n.box.hi[k]);
        }
        c.left = n.left;
        c.right = n.right;
        if (n.left < 0) {
            c.first = n.first;
            c.count = n.count;
        }
        else {
            // (Children come after their parent, and the left child holds the first triangles.)
            c.first = tree[size_t(n.left)].first;
            c.count = tree[size_t(n.left)].count + tree[size_t(n.right)].count;
            if (c.count <= GROUP) {
                c.left = -1;
            }
        }
    }
    std::vector<std::pair<int, int>> stack;
    stack.push_back({0, 0});
    while (!stack.empty()) {
        if (deadline.tick()) {
            return -1;
        }
        const std::pair<int, int> item = stack.back();
        stack.pop_back();
        const Compact& na = tree[size_t(item.first)];
        if (item.first == item.second) {
            if (na.left < 0) {
                for (int i = 0; i < na.count; ++i) {
                    for (int j = i + 1; j < na.count; ++j) {
                        test(na.first + i, na.first + j);
                    }
                }
            }
            else {
                stack.push_back({na.left, na.left});
                stack.push_back({na.right, na.right});
                stack.push_back({na.left, na.right});
            }
            continue;
        }
        const Compact& nb = tree[size_t(item.second)];
        if (na.lo[0] > nb.hi[0] || nb.lo[0] > na.hi[0] || na.lo[1] > nb.hi[1] || nb.lo[1] > na.hi[1] || na.lo[2] > nb.hi[2] || nb.lo[2] > na.hi[2]) {
            continue;
        }
        if (na.left < 0 && nb.left < 0) {
            for (int i = 0; i < na.count; ++i) {
                for (int j = 0; j < nb.count; ++j) {
                    test(na.first + i, nb.first + j);
                }
            }
            continue;
        }
        // Split the larger of the two (a leaf is never split).
        bool split_a = nb.left < 0;
        if (na.left >= 0 && nb.left >= 0) {
            split_a = na.count >= nb.count;
        }
        if (split_a) {
            stack.push_back({na.left, item.second});
            stack.push_back({na.right, item.second});
        }
        else {
            stack.push_back({item.first, nb.left});
            stack.push_back({item.first, nb.right});
        }
    }
    if (pairs != nullptr) {
        std::sort(found.begin(), found.end());
        for (size_t i = 0; i < found.size() && i < 64; ++i) {
            pairs->push_back(found[i].first);
            pairs->push_back(found[i].second);
        }
    }
    return count;
}

CheckResult check(State& state, const Deadline& deadline, double self_seconds)
{
    CheckResult r;
    const MeshData& m = state.data;
    const size_t T = m.triangle_count(), V = m.vertex_count();
    const Topology* topo = topology_of(state, &deadline);
    if (topo == nullptr) {
        return r;
    }
    r.boundary_edges = topo->boundary_edges;
    r.non_manifold_edges = topo->non_manifold_edges;
    r.degenerate_triangles = count_degenerate(state);

    // Duplicates: a triangle with the corners of an earlier one (in any order).
    size_t with_edges = 0;
    for (size_t t = 0; t < T; ++t) {
        const uint32_t* tri = &m.triangles[t * 3];
        if (!has_edges(tri)) {
            continue;
        }
        ++with_edges;
        const uint32_t e = topo->he_edge[t * 3];
        for (uint32_t i = topo->edge_first[e]; i < topo->edge_first[size_t(e) + 1]; ++i) {
            const size_t t2 = topo->edge_hes[i] / 3;
            if (t2 >= t) {
                break;  // ascending
            }
            const uint32_t* other = &m.triangles[t2 * 3];
            const bool same = (tri[0] == other[0] || tri[0] == other[1] || tri[0] == other[2]) && (tri[1] == other[0] || tri[1] == other[1] || tri[1] == other[2]) &&
                              (tri[2] == other[0] || tri[2] == other[1] || tri[2] == other[2]);
            if (same) {
                ++r.duplicate_triangles;
                break;
            }
        }
        if (deadline.tick()) {
            return r;
        }
    }

    // Unused vertices, and vertices whose triangles form more than one fan.
    std::vector<uint8_t> used(V, 0);
    for (const uint32_t v : m.triangles) {
        used[v] = 1;
    }
    size_t used_count = 0;
    for (size_t v = 0; v < V; ++v) {
        used_count += used[v];
    }
    r.unused_vertices = int64_t(V - used_count);
    {
        UnionFind fans(T * 3);
        for (size_t e = 0; e < topo->edge_count(); ++e) {
            const uint32_t first = topo->edge_first[e], last = topo->edge_first[e + 1];
            for (uint32_t i = first; i + 1 < last; ++i) {
                const uint32_t h1 = topo->edge_hes[i], h2 = topo->edge_hes[size_t(i) + 1];
                if (m.triangles[h1] == m.triangles[h2]) {
                    fans.join(h1, h2);
                    fans.join(next_he(h1), next_he(h2));
                }
                else {
                    fans.join(h1, next_he(h2));
                    fans.join(next_he(h1), h2);
                }
            }
            if (deadline.tick()) {
                return r;
            }
        }
        std::vector<uint8_t> fan_count(V, 0);
        for (size_t t = 0; t < T; ++t) {
            if (!has_edges(&m.triangles[t * 3])) {
                continue;
            }
            for (uint32_t c = uint32_t(t * 3); c < uint32_t(t * 3 + 3); ++c) {
                if (fans.find(c) == c && fan_count[m.triangles[c]] < 2) {
                    ++fan_count[m.triangles[c]];
                }
            }
        }
        for (size_t v = 0; v < V; ++v) {
            if (fan_count[v] > 1) {
                ++r.non_manifold_vertices;
            }
        }
    }
    if (deadline.expired()) {
        return r;
    }

    r.closed = with_edges > 0 && r.boundary_edges == 0 && r.non_manifold_edges == 0;
    r.manifold = r.non_manifold_edges == 0 && r.non_manifold_vertices == 0;
    if (r.boundary_edges > 0) {
        r.boundary_loops = int64_t(boundary_loops(state).size());
    }
    const Components* comps = nested_components_of(state, &deadline);
    if (comps == nullptr) {
        return r;
    }
    r.components = int64_t(comps->list.size());
    for (const Component& c : comps->list) {
        r.closed_components += c.closed ? 1 : 0;
        r.inverted_components += c.inverted ? 1 : 0;
        r.solid_components += (c.depth >= 0 && c.depth % 2 == 0) ? 1 : 0;
    }
    r.oriented = topo->inconsistent_edges == 0 && r.inverted_components == 0;
    if (r.closed && r.manifold) {
        // V - E + F = 2 (C - g), summed over the components.
        const int64_t euler = int64_t(used_count) - int64_t(topo->edge_count()) + int64_t(with_edges);
        r.genus = r.components - euler / 2;
    }
    r.finished = true;

    // Self-intersections, in what is left of the time (never started when it cannot fit).
    r.self_intersections = self_intersections_within(state, std::min(self_seconds, deadline.remaining()), &r.pairs, &r.self_ms);
    return r;
}

int64_t self_intersections_within(State& state, double seconds, std::vector<int32_t>* pairs, double* elapsed_ms)
{
    if (elapsed_ms != nullptr) {
        *elapsed_ms = 0.0;
    }
    // (A count from an earlier test of this mesh is kept: a mesh never changes.)
    if (state.has_self_intersections && pairs == nullptr) {
        return state.self_intersection_count;
    }
    if (!(seconds > 0.0)) {
        return -1;
    }
    const double triangles = double(state.data.triangle_count());
    const double cost = (state.bvh ? 0.0 : budget::estimate(budget::BVH_BUILD, triangles)) + budget::estimate(budget::SELF_INTERSECTIONS, triangles);
    if (cost > seconds) {
        return -1;
    }
    const Deadline own(seconds);
    const int64_t count = self_intersections(state, own, pairs);
    if (count < 0 && pairs != nullptr) {
        pairs->clear();
    }
    if (count >= 0) {
        state.has_self_intersections = true;
        state.self_intersection_count = count;
    }
    if (elapsed_ms != nullptr) {
        *elapsed_ms = own.elapsed() * 1000.0;
    }
    return count;
}

Summary summarize(State& state)
{
    Summary s;
    const MeshData& m = state.data;
    s.triangles = int64_t(m.triangle_count());
    s.vertices = int64_t(m.vertex_count());
    s.groups = int64_t(m.group_count());
    if (m.triangle_count() == 0) {
        return s;
    }
    const Topology* topo = topology_of(state);
    const Measures& ms = measures_of(state);
    s.closed = is_closed(state);
    s.boundary_edges = topo->boundary_edges;
    s.non_manifold_edges = topo->non_manifold_edges;
    s.degenerate_triangles = count_degenerate(state);
    s.area = ms.area;
    s.volume = s.closed ? ms.volume : 0.0;
    const Components* comps = nested_components_of(state);
    s.components = int64_t(comps->list.size());
    for (const Component& c : comps->list) {
        s.inverted_components += c.inverted ? 1 : 0;
    }
    return s;
}

// ---------------------------------------------------------------- boundary loops

std::vector<BoundaryLoop> boundary_loops(State& state)
{
    std::vector<BoundaryLoop> loops;
    const MeshData& m = state.data;
    const Topology* topo = topology_of(state);
    if (topo->boundary_edges == 0) {
        return loops;
    }
    const size_t H = m.triangles.size();
    auto is_boundary = [&](uint32_t he) { return topo->he_edge[he] != NONE && topo->uses(topo->he_edge[he]) == 1; };
    // Boundary half-edges by the vertex they start at (for corners the walk around a vertex
    // cannot pass: non-manifold edges, flipped neighbours).
    std::vector<std::pair<uint32_t, uint32_t>> leaving;
    for (uint32_t he = 0; he < H; ++he) {
        if (is_boundary(he)) {
            leaving.push_back({m.triangles[he], he});
        }
    }
    std::sort(leaving.begin(), leaving.end());
    std::vector<uint8_t> visited(H, 0);
    auto next_boundary = [&](uint32_t he) -> uint32_t {
        const uint32_t v = m.triangles[next_he(he)];
        // Turn around v inside its fan until the next open edge.
        uint32_t g = next_he(he);
        for (size_t guard = 0; guard < H; ++guard) {
            if (is_boundary(g)) {
                return g;
            }
            const uint32_t tw = topo->twin(g);
            if (tw == NONE) {
                break;
            }
            g = next_he(tw);
            if (m.triangles[g] != v) {
                break;
            }
        }
        auto it = std::lower_bound(leaving.begin(), leaving.end(), std::make_pair(v, uint32_t(0)));
        for (; it != leaving.end() && it->first == v; ++it) {
            if (!visited[it->second]) {
                return it->second;
            }
        }
        return NONE;
    };
    for (uint32_t start = 0; start < H; ++start) {
        if (!is_boundary(start) || visited[start]) {
            continue;
        }
        BoundaryLoop loop;
        loop.closed = false;
        uint32_t he = start;
        for (;;) {
            visited[he] = 1;
            loop.vertices.push_back(m.triangles[he]);
            const uint32_t next = next_boundary(he);
            if (next == start) {
                loop.closed = true;
                break;
            }
            if (next == NONE || visited[next]) {
                loop.vertices.push_back(m.triangles[next_he(he)]);
                break;
            }
            he = next;
        }
        loops.push_back(std::move(loop));
    }
    for (BoundaryLoop& loop : loops) {
        std::vector<uint32_t>& v = loop.vertices;
        if (loop.closed) {
            std::rotate(v.begin(), std::min_element(v.begin(), v.end()), v.end());
        }
        const size_t n = v.size();
        double centre[3] = {0, 0, 0}, normal[3] = {0, 0, 0};
        std::vector<double> pts(n * 3);
        for (size_t i = 0; i < n; ++i) {
            m.point(v[i], &pts[i * 3]);
            for (int k = 0; k < 3; ++k) {
                centre[k] += pts[i * 3 + size_t(k)] / double(n);
            }
        }
        const size_t segments = loop.closed ? n : n - 1;
        for (size_t i = 0; i < segments; ++i) {
            const double* a = &pts[i * 3];
            const double* b = &pts[((i + 1) % n) * 3];
            double d[3];
            sub3(b, a, d);
            loop.length += length3(d);
        }
        for (size_t i = 0; i < n; ++i) {
            double a[3], b[3], c[3];
            sub3(&pts[i * 3], centre, a);
            sub3(&pts[((i + 1) % n) * 3], centre, b);
            cross3(a, b, c);
            for (int k = 0; k < 3; ++k) {
                normal[k] += c[k];
            }
        }
        const double len = length3(normal);
        if (len > 0.0) {
            for (size_t i = 0; i < n; ++i) {
                double d[3];
                sub3(&pts[i * 3], centre, d);
                loop.planar_error = std::max(loop.planar_error, std::fabs(dot3(d, normal) / len));
            }
        }
    }
    std::sort(loops.begin(), loops.end(), [](const BoundaryLoop& a, const BoundaryLoop& b) {
        const uint32_t ma = *std::min_element(a.vertices.begin(), a.vertices.end());
        const uint32_t mb = *std::min_element(b.vertices.begin(), b.vertices.end());
        return ma != mb ? ma < mb : a.vertices.size() < b.vertices.size();
    });
    return loops;
}

// ---------------------------------------------------------------- section

std::vector<Polyline> section(State& state, const double origin[3], const double normal_in[3])
{
    std::vector<Polyline> lines;
    const MeshData& m = state.data;
    const size_t T = m.triangle_count(), V = m.vertex_count();
    double normal[3] = {normal_in[0], normal_in[1], normal_in[2]};
    const double len = length3(normal);
    if (!(len > 0.0) || !std::isfinite(len) || T == 0) {
        return lines;
    }
    for (int k = 0; k < 3; ++k) {
        normal[k] /= len;
    }
    const Topology* topo = topology_of(state);
    std::vector<double> dist(V);
    for (size_t v = 0; v < V; ++v) {
        double p[3];
        m.point(uint32_t(v), p);
        sub3(p, origin, p);
        dist[v] = dot3(p, normal);
    }
    // A vertex on the plane counts as above it, so every crossing lies on an edge with one end
    // on each side and every cut triangle gives one segment between two of its edges.
    auto above = [&](uint32_t v) { return dist[v] >= 0.0; };
    struct Segment
    {
        uint32_t in, out;  // the edges it starts and ends on
    };
    std::vector<Segment> segments;
    struct Uses
    {
        uint32_t a = NONE, b = NONE;
        uint32_t count = 0;
    };
    std::unordered_map<uint32_t, Uses> on_edge;
    for (size_t t = 0; t < T; ++t) {
        const uint32_t* tri = &m.triangles[t * 3];
        if (!has_edges(tri)) {
            continue;
        }
        const bool s0 = above(tri[0]), s1 = above(tri[1]), s2 = above(tri[2]);
        if (s0 == s1 && s1 == s2) {
            continue;
        }
        Segment seg{NONE, NONE};
        const bool side[3] = {s0, s1, s2};
        for (int k = 0; k < 3; ++k) {
            const uint32_t e = topo->he_edge[t * 3 + size_t(k)];
            if (side[k] && !side[(k + 1) % 3]) {
                seg.in = e;   // leaves the upper side
            }
            else if (!side[k] && side[(k + 1) % 3]) {
                seg.out = e;  // comes back up
            }
        }
        const uint32_t id = uint32_t(segments.size());
        segments.push_back(seg);
        for (const uint32_t e : {seg.in, seg.out}) {
            Uses& u = on_edge[e];
            if (u.count == 0) {
                u.a = id;
            }
            else if (u.count == 1) {
                u.b = id;
            }
            ++u.count;
        }
    }
    // The point where an edge crosses: from its upper end, so both triangles get the same point.
    auto edge_point = [&](uint32_t e, double out[3]) {
        const uint32_t he = topo->edge_hes[topo->edge_first[e]];
        uint32_t u = m.triangles[he], w = m.triangles[next_he(he)];
        if (!above(u)) {
            std::swap(u, w);
        }
        double pu[3], pw[3];
        m.point(u, pu);
        m.point(w, pw);
        const double s = dist[u] / (dist[u] - dist[w]);
        for (int k = 0; k < 3; ++k) {
            out[k] = pu[k] + s * (pw[k] - pu[k]);
        }
    };
    // The segment across edge e from segment s, when the edge joins exactly two.
    auto across = [&](uint32_t e, uint32_t s) -> uint32_t {
        const Uses& u = on_edge[e];
        if (u.count != 2) {
            return NONE;
        }
        return u.a == s ? u.b : u.a;
    };
    std::vector<uint8_t> visited(segments.size(), 0);
    for (uint32_t first = 0; first < segments.size(); ++first) {
        if (visited[first]) {
            continue;
        }
        // Forward from `first` over its out edge, then (when the chain is open) back over its in edge.
        std::vector<uint32_t> edges;  // the crossed edges, in order
        bool closed = false;
        visited[first] = 1;
        edges.push_back(segments[first].in);
        edges.push_back(segments[first].out);
        uint32_t s = first, e = segments[first].out;
        for (;;) {
            const uint32_t next = across(e, s);
            if (next == first) {
                closed = true;
                break;
            }
            if (next == NONE || visited[next]) {
                break;
            }
            visited[next] = 1;
            e = segments[next].in == e ? segments[next].out : segments[next].in;
            edges.push_back(e);
            s = next;
        }
        if (!closed) {
            std::vector<uint32_t> before;
            s = first;
            e = segments[first].in;
            for (;;) {
                const uint32_t next = across(e, s);
                if (next == NONE || visited[next]) {
                    break;
                }
                visited[next] = 1;
                e = segments[next].out == e ? segments[next].in : segments[next].out;
                before.push_back(e);
                s = next;
            }
            edges.insert(edges.begin(), before.rbegin(), before.rend());
        }
        else {
            edges.pop_back();  // the last edge is the first again
        }
        Polyline line;
        line.closed = closed;
        for (const uint32_t edge : edges) {
            double p[3];
            edge_point(edge, p);
            const size_t n = line.points.size();
            if (n >= 3 && line.points[n - 3] == p[0] && line.points[n - 2] == p[1] && line.points[n - 1] == p[2]) {
                continue;  // a segment of no length (through a vertex on the plane)
            }
            line.points.insert(line.points.end(), p, p + 3);
        }
        if (closed && line.points.size() >= 6) {
            const size_t n = line.points.size();
            if (line.points[n - 3] == line.points[0] && line.points[n - 2] == line.points[1] && line.points[n - 1] == line.points[2]) {
                line.points.resize(n - 3);
            }
        }
        if (line.points.size() >= (closed ? 9u : 6u)) {
            lines.push_back(std::move(line));
        }
    }
    return lines;
}

// ---------------------------------------------------------------- rays and regions

RayHit ray_hit(State& state, const double origin[3], const double direction[3], double max_distance)
{
    RayHit hit;
    const double len = length3(direction);
    if (!(len > 0.0) || !std::isfinite(len) || state.data.triangle_count() == 0) {
        return hit;
    }
    const double d[3] = {direction[0] / len, direction[1] / len, direction[2] / len};
    const TriBvh* bvh = bvh_of(state);
    uint32_t tri = NONE;
    double t = 0.0;
    if (!bvh->closest_hit(origin, d, max_distance, tri, t)) {
        return hit;
    }
    hit.hit = true;
    hit.distance = t;
    hit.triangle = tri;
    for (int k = 0; k < 3; ++k) {
        hit.point[k] = origin[k] + t * d[k];
    }
    double n[3];
    triangle_normal(state.data, tri, n);
    const double nl = length3(n);
    for (int k = 0; k < 3; ++k) {
        hit.normal[k] = nl > 0.0 ? n[k] / nl : 0.0;
    }
    return hit;
}

void winding_numbers(State& state, const double* points, size_t count, std::vector<int32_t>& out)
{
    out.assign(count, 0);
    if (state.data.triangle_count() == 0) {
        return;
    }
    const TriBvh* bvh = bvh_of(state);
    for (size_t i = 0; i < count; ++i) {
        int32_t w = 0;
        bvh->column(points + i * 3, [&](uint32_t, int sign) { w += sign; });
        out[i] = w;
    }
}

namespace
{
/// Does any part of triangle (a, b, c) lie inside every plane (n . p <= d)?
bool triangle_meets_planes(const double* a, const double* b, const double* c, const double* planes, size_t plane_count)
{
    double poly[2][64][3];
    int n = 3, cur = 0;
    std::memcpy(poly[0][0], a, sizeof(double) * 3);
    std::memcpy(poly[0][1], b, sizeof(double) * 3);
    std::memcpy(poly[0][2], c, sizeof(double) * 3);
    for (size_t p = 0; p < plane_count && n > 0; ++p) {
        const double* pl = planes + p * 4;
        int out = 0;
        for (int i = 0; i < n; ++i) {
            const double* u = poly[cur][i];
            const double* w = poly[cur][(i + 1) % n];
            const double du = dot3(pl, u) - pl[3], dw = dot3(pl, w) - pl[3];
            if (du <= 0.0 && out < 62) {
                std::memcpy(poly[1 - cur][out++], u, sizeof(double) * 3);
            }
            if ((du < 0.0 && dw > 0.0) || (du > 0.0 && dw < 0.0)) {
                const double s = du / (du - dw);
                if (out < 62) {
                    for (int k = 0; k < 3; ++k) {
                        poly[1 - cur][out][k] = u[k] + s * (w[k] - u[k]);
                    }
                    ++out;
                }
            }
        }
        n = out;
        cur = 1 - cur;
    }
    return n > 0;
}
}  // namespace

std::vector<uint32_t> triangles_in_planes(State& state, const double* planes, size_t plane_count, bool all_inside)
{
    std::vector<uint32_t> out;
    if (state.data.triangle_count() == 0 || plane_count == 0 || plane_count > 32) {
        return out;
    }
    const TriBvh* bvh = bvh_of(state);
    const std::vector<subd::Bvh::Node>& nodes = bvh->bvh.nodes;
    std::vector<std::pair<int, bool>> stack;  // (node, wholly inside)
    stack.push_back({0, false});
    while (!stack.empty()) {
        const std::pair<int, bool> item = stack.back();
        stack.pop_back();
        const subd::Bvh::Node& node = nodes[size_t(item.first)];
        bool whole = item.second;
        if (!whole) {
            bool outside = false;
            whole = true;
            for (size_t p = 0; p < plane_count && !outside; ++p) {
                const double* pl = planes + p * 4;
                double least = -pl[3], most = -pl[3];
                for (int k = 0; k < 3; ++k) {
                    least += pl[k] * (pl[k] > 0.0 ? node.box.lo[k] : node.box.hi[k]);
                    most += pl[k] * (pl[k] > 0.0 ? node.box.hi[k] : node.box.lo[k]);
                }
                outside = least > 0.0;
                whole = whole && most <= 0.0;
            }
            if (outside) {
                continue;
            }
        }
        if (node.left >= 0) {
            stack.push_back({node.left, whole});
            stack.push_back({node.right, whole});
            continue;
        }
        for (int i = 0; i < node.count; ++i) {
            const uint32_t tri = uint32_t(bvh->bvh.prims[size_t(node.first + i)]);
            if (whole) {
                out.push_back(tri);
                continue;
            }
            double a[3], b[3], c[3];
            bvh->corners(tri, a, b, c);
            bool keep;
            if (all_inside) {
                keep = true;
                for (size_t p = 0; p < plane_count && keep; ++p) {
                    const double* pl = planes + p * 4;
                    keep = dot3(pl, a) <= pl[3] && dot3(pl, b) <= pl[3] && dot3(pl, c) <= pl[3];
                }
            }
            else {
                keep = triangle_meets_planes(a, b, c, planes, plane_count);
            }
            if (keep) {
                out.push_back(tri);
            }
        }
    }
    std::sort(out.begin(), out.end());
    return out;
}

std::vector<uint32_t> triangles_near(State& state, const double point[3], double radius, bool only_connected)
{
    std::vector<uint32_t> out;
    const size_t T = state.data.triangle_count();
    if (T == 0 || !(radius >= 0.0) || !std::isfinite(radius)) {
        return out;
    }
    const TriBvh* bvh = bvh_of(state);
    subd::Box box;
    box.add(point);
    box.expand(radius);
    const double r2 = radius * radius;
    uint32_t nearest = NONE;
    double nearest2 = kInf;
    bvh->bvh.overlap(box, [&](int prim) {
        double a[3], b[3], c[3], q[3], b1 = 0.0, b2 = 0.0;
        bvh->corners(uint32_t(prim), a, b, c);
        const double d2 = subd::closest_on_triangle(point, a, b, c, q, b1, b2);
        if (d2 <= r2) {
            out.push_back(uint32_t(prim));
            if (d2 < nearest2 || (d2 == nearest2 && uint32_t(prim) < nearest)) {
                nearest2 = d2;
                nearest = uint32_t(prim);
            }
        }
    });
    std::sort(out.begin(), out.end());
    if (!only_connected || out.empty()) {
        return out;
    }
    const Topology* topo = topology_of(state);
    std::vector<uint8_t> in_set(T, 0), reached(T, 0);
    for (const uint32_t t : out) {
        in_set[t] = 1;
    }
    std::vector<uint32_t> stack{nearest};
    reached[nearest] = 1;
    while (!stack.empty()) {
        const uint32_t t = stack.back();
        stack.pop_back();
        for (uint32_t he = t * 3; he < t * 3 + 3; ++he) {
            const uint32_t e = topo->he_edge[he];
            if (e == NONE) {
                continue;
            }
            for (uint32_t i = topo->edge_first[e]; i < topo->edge_first[size_t(e) + 1]; ++i) {
                const uint32_t t2 = topo->edge_hes[i] / 3;
                if (in_set[t2] && !reached[t2]) {
                    reached[t2] = 1;
                    stack.push_back(t2);
                }
            }
        }
    }
    return from_flags(reached);
}

std::vector<uint32_t> grow(State& state, const std::vector<uint32_t>& tris, int steps, bool shrink)
{
    const size_t T = state.data.triangle_count();
    std::vector<uint32_t> current = sorted_valid(tris, T);
    if (current.empty() || steps <= 0) {
        return current;
    }
    const Topology* topo = topology_of(state);
    std::vector<uint8_t> in_set(T, 0);
    for (const uint32_t t : current) {
        in_set[t] = 1;
    }
    for (int step = 0; step < steps; ++step) {
        std::vector<uint32_t> changed;
        for (const uint32_t t : current) {
            bool has_outside = false;
            for (uint32_t he = t * 3; he < t * 3 + 3; ++he) {
                const uint32_t e = topo->he_edge[he];
                if (e == NONE) {
                    continue;
                }
                for (uint32_t i = topo->edge_first[e]; i < topo->edge_first[size_t(e) + 1]; ++i) {
                    const uint32_t t2 = topo->edge_hes[i] / 3;
                    if (!in_set[t2]) {
                        has_outside = true;
                        if (!shrink) {
                            changed.push_back(t2);
                        }
                    }
                }
            }
            if (shrink && has_outside) {
                changed.push_back(t);
            }
        }
        if (changed.empty()) {
            break;
        }
        for (const uint32_t t : changed) {
            in_set[t] = shrink ? 0 : 1;
        }
        if (shrink) {
            std::vector<uint32_t> kept;
            for (const uint32_t t : current) {
                if (in_set[t]) {
                    kept.push_back(t);
                }
            }
            current.swap(kept);
        }
        else {
            std::sort(changed.begin(), changed.end());
            changed.erase(std::unique(changed.begin(), changed.end()), changed.end());
            current.insert(current.end(), changed.begin(), changed.end());
        }
        if (current.empty()) {
            break;
        }
    }
    std::sort(current.begin(), current.end());
    return current;
}

std::vector<uint32_t> connected(State& state, const std::vector<uint32_t>& tris, double max_angle_deg)
{
    const MeshData& m = state.data;
    const size_t T = m.triangle_count();
    std::vector<uint32_t> seeds = sorted_valid(tris, T);
    if (seeds.empty()) {
        return seeds;
    }
    const Topology* topo = topology_of(state);
    const bool any = !(max_angle_deg < 180.0);
    const double limit = std::cos(std::max(0.0, std::min(max_angle_deg, 180.0)) * M_PI / 180.0) - 1e-12;
    std::vector<uint8_t> reached(T, 0);
    std::vector<uint32_t> stack;
    for (const uint32_t t : seeds) {
        reached[t] = 1;
        stack.push_back(t);
    }
    while (!stack.empty()) {
        const uint32_t t = stack.back();
        stack.pop_back();
        double n1[3];
        triangle_normal(m, t, n1);
        const double l1 = length3(n1);
        for (uint32_t he = t * 3; he < t * 3 + 3; ++he) {
            const uint32_t e = topo->he_edge[he];
            if (e == NONE) {
                continue;
            }
            for (uint32_t i = topo->edge_first[e]; i < topo->edge_first[size_t(e) + 1]; ++i) {
                const uint32_t t2 = topo->edge_hes[i] / 3;
                if (reached[t2]) {
                    continue;
                }
                bool pass = any;
                if (!pass) {
                    double n2[3];
                    triangle_normal(m, t2, n2);
                    const double l2 = length3(n2);
                    // A triangle of no area has no normal: it never stops the fill.
                    pass = !(l1 > 0.0) || !(l2 > 0.0) || dot3(n1, n2) / (l1 * l2) >= limit;
                }
                if (pass) {
                    reached[t2] = 1;
                    stack.push_back(t2);
                }
            }
        }
    }
    return from_flags(reached);
}

// ---------------------------------------------------------------- distance

Distance distance_between(State& from, State& to, int64_t samples, const Deadline& deadline)
{
    Distance out;
    const MeshData& m = from.data;
    const size_t T = m.triangle_count(), V = m.vertex_count();
    if (T == 0 || to.data.triangle_count() == 0 || samples <= 0) {
        return out;
    }
    const TriBvh* bvh = bvh_of(to, &deadline);
    if (bvh == nullptr) {
        out.timed_out = true;
        return out;
    }
    double sum = 0.0, sum2 = 0.0;
    auto measure = [&](const double p[3]) {
        uint32_t tri = NONE;
        double q[3];
        const double d = std::sqrt(bvh->nearest(p, kInf, tri, q));
        sum += d;
        sum2 += d * d;
        if (d > out.max || out.samples == 0) {
            out.max = d;
            out.max_point[0] = p[0];
            out.max_point[1] = p[1];
            out.max_point[2] = p[2];
        }
        ++out.samples;
    };
    // The used vertices (every `stride`-th when there are more than `samples`).
    std::vector<uint8_t> used(V, 0);
    for (const uint32_t v : m.triangles) {
        used[v] = 1;
    }
    std::vector<uint32_t> vertices;
    vertices.reserve(V);
    for (size_t v = 0; v < V; ++v) {
        if (used[v]) {
            vertices.push_back(uint32_t(v));
        }
    }
    const size_t take = std::min<size_t>(vertices.size(), size_t(samples));
    for (size_t i = 0; i < take && !out.timed_out; ++i) {
        const size_t pick = take == vertices.size() ? i : size_t(uint64_t(i) * uint64_t(vertices.size()) / uint64_t(take));
        double p[3];
        m.point(vertices[pick], p);
        measure(p);
        out.timed_out = deadline.tick();
    }
    // Then points spread over the area, from a fixed seed.
    const size_t extra = size_t(samples) - take;
    if (extra > 0 && !out.timed_out) {
        std::vector<double> cumulative(T);
        double total = 0.0;
        for (size_t t = 0; t < T; ++t) {
            double n[3];
            triangle_normal(m, uint32_t(t), n);
            total += 0.5 * length3(n);
            cumulative[t] = total;
        }
        uint64_t seed = 0x9E3779B97F4A7C15ull;
        auto random = [&]() {
            // splitmix64
            seed += 0x9E3779B97F4A7C15ull;
            uint64_t z = seed;
            z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
            z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
            z ^= z >> 31;
            return double(z >> 11) * (1.0 / 9007199254740992.0);
        };
        for (size_t i = 0; i < extra && total > 0.0 && !out.timed_out; ++i) {
            const double r = random() * total;
            const size_t t = std::min<size_t>(size_t(std::lower_bound(cumulative.begin(), cumulative.end(), r) - cumulative.begin()), T - 1);
            const double s = std::sqrt(random()), u = random();
            const double wa = 1.0 - s, wb = s * (1.0 - u), wc = s * u;
            double a[3], b[3], c[3], p[3];
            m.point(m.triangles[t * 3], a);
            m.point(m.triangles[t * 3 + 1], b);
            m.point(m.triangles[t * 3 + 2], c);
            for (int k = 0; k < 3; ++k) {
                p[k] = wa * a[k] + wb * b[k] + wc * c[k];
            }
            measure(p);
            out.timed_out = deadline.tick();
        }
    }
    if (out.samples > 0) {
        out.mean = sum / double(out.samples);
        out.rms = std::sqrt(sum2 / double(out.samples));
    }
    return out;
}

// ---------------------------------------------------------------- groups and mass

GroupInfo group_info(State& state, uint32_t group)
{
    GroupInfo info;
    const MeshData& m = state.data;
    if (size_t(group) >= m.group_count()) {
        return info;
    }
    info.valid = true;
    const GroupIndex& index = group_index_of(state);
    const Measures& ms = measures_of(state);
    const uint32_t first = index.first[group], last = index.first[size_t(group) + 1];
    info.triangles = int64_t(last - first);
    double centre[3] = {0, 0, 0}, normal[3] = {0, 0, 0};
    for (uint32_t i = first; i < last; ++i) {
        const uint32_t t = index.tris[i];
        double a[3], b[3], c[3], n[3];
        m.point(m.triangles[size_t(t) * 3], a);
        m.point(m.triangles[size_t(t) * 3 + 1], b);
        m.point(m.triangles[size_t(t) * 3 + 2], c);
        triangle_normal(m, t, n);
        const double area = 0.5 * length3(n);
        info.area += area;
        for (int k = 0; k < 3; ++k) {
            centre[k] += area * (a[k] + b[k] + c[k] - 3.0 * ms.origin[k]) / 3.0;
            normal[k] += 0.5 * n[k];
        }
    }
    if (info.area > 0.0) {
        for (int k = 0; k < 3; ++k) {
            info.point[k] = ms.origin[k] + centre[k] / info.area;
        }
    }
    const double nl = length3(normal);
    if (nl > 0.0) {
        for (int k = 0; k < 3; ++k) {
            info.normal[k] = normal[k] / nl;
        }
        // Flat: every corner within 1e-6 x the body's diagonal of the plane through the centroid.
        const double tolerance = 1e-6 * ms.diagonal;
        bool flat = true;
        for (uint32_t i = first; i < last && flat; ++i) {
            const uint32_t t = index.tris[i];
            for (int k = 0; k < 3 && flat; ++k) {
                double p[3];
                m.point(m.triangles[size_t(t) * 3 + size_t(k)], p);
                sub3(p, info.point, p);
                flat = std::fabs(dot3(p, info.normal)) <= tolerance;
            }
        }
        info.planar = flat;
    }
    return info;
}

void group_normal_at(State& state, uint32_t group, const double point[3], double out[3])
{
    out[0] = out[1] = out[2] = 0.0;
    const MeshData& m = state.data;
    if (size_t(group) >= m.group_count() || m.triangle_count() == 0) {
        return;
    }
    const TriBvh* bvh = bvh_of(state);
    uint32_t tri = NONE;
    double q[3];
    bvh->nearest(point, kInf, tri, q, [&](uint32_t t) { return m.groups[t] == group; });
    if (tri == NONE) {
        return;
    }
    double n[3];
    triangle_normal(m, tri, n);
    const double nl = length3(n);
    if (nl > 0.0) {
        for (int k = 0; k < 3; ++k) {
            out[k] = n[k] / nl;
        }
    }
}

MassProperties mass_properties(State& state)
{
    return mass_properties(state, false);
}

MassProperties mass_properties(State& state, bool test_crossings)
{
    MassProperties mp;
    if (state.data.triangle_count() == 0) {
        return mp;
    }
    const Measures& ms = measures_of(state);
    mp.area = ms.area;
    const Topology* topo = topology_of(state);
    mp.open = topo->boundary_edges > 0 || topo->edge_count() == 0;
    mp.non_manifold_edges = topo->non_manifold_edges;
    mp.wrong_way_edges = topo->inconsistent_edges;
    // A volume can be told only when the mesh is closed and its triangles agree on a side:
    // with some of them flipped the signed sum is noise (and a centre taken from it lies
    // anywhere).
    mp.closed = !mp.open && mp.non_manifold_edges == 0 && mp.wrong_way_edges == 0 && ms.volume != 0.0;
    if (mp.closed) {
        for (const Component& c : nested_components_of(state)->list) {
            mp.inside_out_parts += c.inverted ? 1 : 0;
        }
        if (state.has_self_intersections) {
            mp.self_intersections = state.self_intersection_count;
        }
        else if (test_crossings) {
            mp.self_intersections = self_intersections_within(state, budget::SELF_INTERSECTION_SECONDS, nullptr);
        }
    }
    const double amount = mp.closed ? ms.volume : ms.area;
    const double* second = mp.closed ? ms.volume_second : ms.area_second;
    const double* centre = mp.closed ? ms.volume_centre : ms.area_centre;
    // (Never negative: a mesh that is inside-out as a whole has the size of its volume.)
    mp.volume = mp.closed ? std::fabs(ms.volume) : 0.0;
    Eigen::Matrix3d inertia = Eigen::Matrix3d::Zero();
    double c[3];
    for (int k = 0; k < 3; ++k) {
        mp.centre[k] = centre[k];
        c[k] = centre[k] - ms.origin[k];
    }
    // Second moments about the centre, then I = trace(C) 1 - C. (An inside-out closed mesh has
    // a negative volume and negative sums: the sign is taken out.)
    const double sign = amount < 0.0 ? -1.0 : 1.0;
    Eigen::Matrix3d cov;
    for (int i = 0; i < 3; ++i) {
        for (int j = 0; j < 3; ++j) {
            cov(i, j) = sign * (second[i * 3 + j] - amount * c[i] * c[j]);
        }
    }
    inertia = cov.trace() * Eigen::Matrix3d::Identity() - cov;
    for (int i = 0; i < 3; ++i) {
        for (int j = 0; j < 3; ++j) {
            mp.inertia[i * 3 + j] = inertia(i, j);
        }
    }
    const Eigen::SelfAdjointEigenSolver<Eigen::Matrix3d> solver(0.5 * (inertia + inertia.transpose()), Eigen::EigenvaluesOnly);
    if (solver.info() == Eigen::Success) {
        for (int k = 0; k < 3; ++k) {
            mp.principal[k] = solver.eigenvalues()(k);
        }
    }
    return mp;
}

}  // namespace holo_forge::mesh
