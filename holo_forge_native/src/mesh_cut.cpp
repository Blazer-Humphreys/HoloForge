// Plane Cut (work order 3.3.4). A closed solid goes through Manifold's plane trims, and the cut
// faces (caps) are found by run id, never by position. Any other body, and Split Faces on every
// body, goes through the clipper in this file; closed loops of its cut are filled. Each side
// Manifold gives is checked against the plain cut of the triangles (its volume, and no face left
// on the plane facing the wrong way); a side that fails is cut again with the clipper.

#include "cad_mesh.h"
#include "mesh_manifold.h"

#include <manifold/polygon.h>

#include <algorithm>
#include <cmath>
#include <cctype>
#include <exception>
#include <string>
#include <unordered_map>
#include <unordered_set>

using namespace godot;

namespace holo_forge::mesh::cut
{

namespace
{
inline double dot3(const double* a, const double* b)
{
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}
inline void cross3(const double* a, const double* b, double* r)
{
    r[0] = a[1] * b[2] - a[2] * b[1];
    r[1] = a[2] * b[0] - a[0] * b[2];
    r[2] = a[0] * b[1] - a[1] * b[0];
}
inline uint64_t edge_key(uint32_t a, uint32_t b)
{
    return (uint64_t(std::min(a, b)) << 32) | uint64_t(std::max(a, b));
}

// ---------------------------------------------------------------- the cap as a 2D triangulation

/// A planar patch of triangles, counter-clockwise in its own 2D frame, with neighbours.
/// Edge k of triangle t runs from corner k to corner (k + 1) % 3.
struct Patch
{
    std::vector<double> xy;      // 2 per vertex, scaled so the patch is about 1 across
    std::vector<int> tri;        // 3 per triangle
    std::vector<int> adj;        // 3 per triangle: the triangle across edge k, -1 when none
    std::vector<uint8_t> fixed;  // 3 per triangle: the edge must stay

    const double* at(int vertex) const
    {
        return &xy[size_t(vertex) * 2];
    }
    size_t triangles() const
    {
        return tri.size() / 3;
    }
};

inline double orient(const double* a, const double* b, const double* c)
{
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
}

/// Positive when d lies inside the circle through a, b, c (counter-clockwise).
inline double in_circle(const double* a, const double* b, const double* c, const double* d)
{
    const double ax = a[0] - d[0], ay = a[1] - d[1];
    const double bx = b[0] - d[0], by = b[1] - d[1];
    const double cx = c[0] - d[0], cy = c[1] - d[1];
    return (ax * ax + ay * ay) * (bx * cy - cx * by) - (bx * bx + by * by) * (ax * cy - cx * ay) + (cx * cx + cy * cy) * (ax * by - bx * ay);
}

constexpr double kAreaEps = 1e-14;    // of a patch about 1 across
constexpr double kCircleEps = 1e-13;

/// Makes the neighbour of `of` across the edge from -> to point at `now`.
inline void repoint(Patch& p, int of, int from, int to, int now)
{
    if (of < 0) {
        return;
    }
    for (int s = 0; s < 3; ++s) {
        if (p.tri[size_t(of) * 3 + size_t(s)] == from && p.tri[size_t(of) * 3 + size_t((s + 1) % 3)] == to) {
            p.adj[size_t(of) * 3 + size_t(s)] = now;
            return;
        }
    }
}

/// Flips edge k of triangle t when that makes the pair better (Delaunay, or rid of a triangle
/// without area) and the edge may move. The four outer edges are pushed on todo.
bool flip(Patch& p, int t, int k, std::vector<std::pair<int, int>>& todo)
{
    const size_t e = size_t(t) * 3 + size_t(k);
    const int n = p.adj[e];
    if (n < 0 || p.fixed[e] != 0) {
        return false;
    }
    const int u = p.tri[e], v = p.tri[size_t(t) * 3 + size_t((k + 1) % 3)], w = p.tri[size_t(t) * 3 + size_t((k + 2) % 3)];
    int m = -1;
    for (int s = 0; s < 3; ++s) {
        if (p.tri[size_t(n) * 3 + size_t(s)] == v && p.tri[size_t(n) * 3 + size_t((s + 1) % 3)] == u) {
            m = s;
        }
    }
    if (m < 0) {
        return false;
    }
    const int d = p.tri[size_t(n) * 3 + size_t((m + 2) % 3)];
    const double *pu = p.at(u), *pv = p.at(v), *pw = p.at(w), *pd = p.at(d);
    // The two triangles after the flip must both have area (the four points make a convex quad).
    const double after1 = orient(pw, pu, pd), after2 = orient(pd, pv, pw);
    if (!(after1 > kAreaEps) || !(after2 > kAreaEps)) {
        return false;
    }
    const double before1 = orient(pu, pv, pw), before2 = orient(pv, pu, pd);
    const bool flat = std::min(before1, before2) <= kAreaEps;
    if (!flat && !(in_circle(pu, pv, pw, pd) > kCircleEps)) {
        return false;
    }
    const int a_vw = p.adj[size_t(t) * 3 + size_t((k + 1) % 3)], a_wu = p.adj[size_t(t) * 3 + size_t((k + 2) % 3)];
    const uint8_t f_vw = p.fixed[size_t(t) * 3 + size_t((k + 1) % 3)], f_wu = p.fixed[size_t(t) * 3 + size_t((k + 2) % 3)];
    const int a_ud = p.adj[size_t(n) * 3 + size_t((m + 1) % 3)], a_dv = p.adj[size_t(n) * 3 + size_t((m + 2) % 3)];
    const uint8_t f_ud = p.fixed[size_t(n) * 3 + size_t((m + 1) % 3)], f_dv = p.fixed[size_t(n) * 3 + size_t((m + 2) % 3)];
    // t becomes (w, u, d), n becomes (d, v, w).
    const size_t T = size_t(t) * 3, N = size_t(n) * 3;
    p.tri[T] = w;
    p.tri[T + 1] = u;
    p.tri[T + 2] = d;
    p.adj[T] = a_wu;
    p.adj[T + 1] = a_ud;
    p.adj[T + 2] = n;
    p.fixed[T] = f_wu;
    p.fixed[T + 1] = f_ud;
    p.fixed[T + 2] = 0;
    p.tri[N] = d;
    p.tri[N + 1] = v;
    p.tri[N + 2] = w;
    p.adj[N] = a_dv;
    p.adj[N + 1] = a_vw;
    p.adj[N + 2] = t;
    p.fixed[N] = f_dv;
    p.fixed[N + 1] = f_vw;
    p.fixed[N + 2] = 0;
    repoint(p, a_ud, d, u, t);
    repoint(p, a_vw, w, v, n);
    todo.push_back({t, 0});
    todo.push_back({t, 1});
    todo.push_back({n, 0});
    todo.push_back({n, 1});
    return true;
}

bool settle(Patch& p, std::vector<std::pair<int, int>>& todo, size_t& flips_left, const Deadline& deadline)
{
    while (!todo.empty()) {
        const std::pair<int, int> edge = todo.back();
        todo.pop_back();
        if (flips_left == 0) {
            todo.clear();
            return true;  // (good enough: the triangulation is valid after every flip)
        }
        if (flip(p, edge.first, edge.second, todo)) {
            --flips_left;
        }
        if (deadline.tick()) {
            return false;
        }
    }
    return true;
}

/// Puts vertex `point` inside triangle t (which it lies strictly inside): three triangles.
void insert(Patch& p, int t, int point, std::vector<int>& made, std::vector<std::pair<int, int>>& todo)
{
    const size_t T = size_t(t) * 3;
    const int a = p.tri[T], b = p.tri[T + 1], c = p.tri[T + 2];
    const int n0 = p.adj[T], n1 = p.adj[T + 1], n2 = p.adj[T + 2];
    const uint8_t f0 = p.fixed[T], f1 = p.fixed[T + 1], f2 = p.fixed[T + 2];
    const int t1 = int(p.triangles()), t2 = t1 + 1;
    p.tri.insert(p.tri.end(), {b, c, point, c, a, point});
    p.adj.insert(p.adj.end(), {n1, t2, t, n2, t, t1});
    p.fixed.insert(p.fixed.end(), {f1, uint8_t(0), uint8_t(0), f2, uint8_t(0), uint8_t(0)});
    p.tri[T + 2] = point;
    p.adj[T] = n0;
    p.adj[T + 1] = t1;
    p.adj[T + 2] = t2;
    p.fixed[T] = f0;
    p.fixed[T + 1] = 0;
    p.fixed[T + 2] = 0;
    repoint(p, n1, c, b, t1);
    repoint(p, n2, a, c, t2);
    made.push_back(t1);
    made.push_back(t2);
    todo.push_back({t, 0});
    todo.push_back({t1, 0});
    todo.push_back({t2, 0});
}
}  // namespace

Frame make_frame(const double origin[3], const double normal[3])
{
    Frame f;
    const double len = std::sqrt(dot3(normal, normal));
    for (int k = 0; k < 3; ++k) {
        f.origin[k] = origin[k];
        f.n[k] = normal[k] / len;
    }
    // u: at right angles to n, starting from the world axis n leans on least.
    int axis = 0;
    for (int k = 1; k < 3; ++k) {
        if (std::fabs(f.n[k]) < std::fabs(f.n[axis])) {
            axis = k;
        }
    }
    double e[3] = {0, 0, 0};
    e[axis] = 1.0;
    cross3(e, f.n, f.u);
    const double ul = std::sqrt(dot3(f.u, f.u));
    for (int k = 0; k < 3; ++k) {
        f.u[k] /= ul;
    }
    cross3(f.n, f.u, f.v);
    return f;
}

bool refine_cap(MeshData& mesh, const std::vector<uint32_t>& cap, const Frame& frame, int facing, double spacing, size_t max_new_triangles, const Deadline& deadline,
                size_t& added)
{
    added = 0;
    if (cap.empty() || !(spacing > 0.0) || max_new_triangles < 2) {
        return true;
    }
    // The cap in 2D (y mirrored for a cap that faces against n, so it is counter-clockwise).
    Patch p;
    std::unordered_map<uint32_t, int> local;
    std::vector<uint32_t> global;
    std::vector<double> raw;
    double lo[2] = {INFINITY, INFINITY}, hi[2] = {-INFINITY, -INFINITY};
    for (const uint32_t t : cap) {
        for (int k = 0; k < 3; ++k) {
            const uint32_t g = mesh.triangles[size_t(t) * 3 + size_t(k)];
            auto found = local.find(g);
            if (found == local.end()) {
                double q[3];
                mesh.point(g, q);
                for (int a = 0; a < 3; ++a) {
                    q[a] -= frame.origin[a];
                }
                const double x = dot3(q, frame.u), y = facing * dot3(q, frame.v);
                found = local.insert({g, int(global.size())}).first;
                global.push_back(g);
                raw.push_back(x);
                raw.push_back(y);
                lo[0] = std::min(lo[0], x);
                hi[0] = std::max(hi[0], x);
                lo[1] = std::min(lo[1], y);
                hi[1] = std::max(hi[1], y);
            }
            p.tri.push_back(found->second);
        }
    }
    const double extent = std::max(hi[0] - lo[0], hi[1] - lo[1]);
    if (!(extent > 0.0)) {
        return true;
    }
    const double centre[2] = {0.5 * (lo[0] + hi[0]), 0.5 * (lo[1] + hi[1])};
    p.xy.resize(raw.size());
    for (size_t i = 0; i < raw.size(); ++i) {
        p.xy[i] = (raw[i] - centre[i % 2]) / extent;
    }
    const size_t first_count = p.triangles();
    double area = 0.0;
    for (size_t t = 0; t < first_count; ++t) {
        const double a = orient(p.at(p.tri[t * 3]), p.at(p.tri[t * 3 + 1]), p.at(p.tri[t * 3 + 2]));
        if (a < -1e-9) {
            return false;  // a triangle faces the other way: not a clean cap
        }
        area += 0.5 * a;
    }
    if (!(area > 0.0)) {
        return true;
    }
    // Neighbours: every edge has one triangle (the outline) or two that run it opposite ways.
    {
        struct Use
        {
            uint64_t key;
            int slot;
        };
        std::vector<Use> uses(first_count * 3);
        for (size_t s = 0; s < first_count * 3; ++s) {
            const int a = p.tri[s], b = p.tri[(s / 3) * 3 + (s + 1) % 3];
            if (a == b) {
                return false;
            }
            uses[s] = {edge_key(uint32_t(a), uint32_t(b)), int(s)};
        }
        std::sort(uses.begin(), uses.end(), [](const Use& x, const Use& y) { return x.key != y.key ? x.key < y.key : x.slot < y.slot; });
        p.adj.assign(first_count * 3, -1);
        p.fixed.assign(first_count * 3, 1);
        for (size_t i = 0; i < uses.size();) {
            size_t j = i;
            while (j < uses.size() && uses[j].key == uses[i].key) {
                ++j;
            }
            if (j - i == 2) {
                const int s1 = uses[i].slot, s2 = uses[i + 1].slot;
                if (p.tri[size_t(s1)] == p.tri[size_t(s2)]) {
                    return false;  // the same direction twice
                }
                p.adj[size_t(s1)] = s2 / 3;
                p.adj[size_t(s2)] = s1 / 3;
            }
            else if (j - i != 1) {
                return false;
            }
            i = j;
        }
    }
    // The grid: coarser when it would make more triangles than there is room for.
    double h = spacing / extent;
    if (2.0 * area / (h * h) > double(max_new_triangles)) {
        h = std::sqrt(2.0 * area / double(max_new_triangles)) * 1.05;
    }
    const double x0 = (lo[0] - centre[0]) / extent + 0.37 * h, y0 = (lo[1] - centre[1]) / extent + 0.61 * h;
    const double x1 = (hi[0] - centre[0]) / extent, y1 = (hi[1] - centre[1]) / extent;
    const int64_t nx = x1 >= x0 ? int64_t((x1 - x0) / h) + 1 : 0, ny = y1 >= y0 ? int64_t((y1 - y0) / h) + 1 : 0;
    if (nx <= 0 || ny <= 0 || nx * ny > int64_t(64) * 1000 * 1000) {
        return nx <= 0 || ny <= 0;
    }
    // Grid points nearer than half a cell to the outline are left out.
    std::vector<uint8_t> blocked(size_t(nx * ny), 0);
    for (size_t s = 0; s < first_count * 3; ++s) {
        if (p.adj[s] >= 0) {
            continue;
        }
        const double* a = p.at(p.tri[s]);
        const double* b = p.at(p.tri[(s / 3) * 3 + (s + 1) % 3]);
        const double ex = b[0] - a[0], ey = b[1] - a[1];
        const double len = std::sqrt(ex * ex + ey * ey);
        const int pieces = std::max(1, int(std::ceil(len / (2.0 * h))));
        for (int piece = 0; piece < pieces; ++piece) {
            const double t0 = double(piece) / pieces, t1 = double(piece + 1) / pieces;
            const double ax = a[0] + ex * t0, ay = a[1] + ey * t0, bx = a[0] + ex * t1, by = a[1] + ey * t1;
            const int64_t i0 = std::max<int64_t>(0, int64_t(std::floor((std::min(ax, bx) - 0.5 * h - x0) / h))),
                          i1 = std::min<int64_t>(nx - 1, int64_t(std::ceil((std::max(ax, bx) + 0.5 * h - x0) / h)));
            const int64_t j0 = std::max<int64_t>(0, int64_t(std::floor((std::min(ay, by) - 0.5 * h - y0) / h))),
                          j1 = std::min<int64_t>(ny - 1, int64_t(std::ceil((std::max(ay, by) + 0.5 * h - y0) / h)));
            const double sx = bx - ax, sy = by - ay, s2 = sx * sx + sy * sy;
            for (int64_t j = j0; j <= j1; ++j) {
                for (int64_t i = i0; i <= i1; ++i) {
                    const double px = x0 + i * h - ax, py = y0 + j * h - ay;
                    const double along = s2 > 0.0 ? std::min(1.0, std::max(0.0, (px * sx + py * sy) / s2)) : 0.0;
                    const double dx = px - along * sx, dy = py - along * sy;
                    if (dx * dx + dy * dy < 0.25 * h * h) {
                        blocked[size_t(j * nx + i)] = 1;
                    }
                }
            }
            if (deadline.tick()) {
                return false;
            }
        }
    }
    // Step 1: every first triangle takes the grid points inside it (its own three edges stay,
    // so the search for the small triangle a point falls in never leaves it).
    std::vector<std::pair<int, int>> todo;
    std::vector<int> mine;
    size_t flips_left = 40 * size_t(2.0 * area / (h * h) + double(first_count)) + 1000;
    const double edge_margin = 1e-7;
    for (size_t t0 = 0; t0 < first_count; ++t0) {
        const int corners[3] = {p.tri[t0 * 3], p.tri[t0 * 3 + 1], p.tri[t0 * 3 + 2]};
        const double c[3][2] = {{p.at(corners[0])[0], p.at(corners[0])[1]}, {p.at(corners[1])[0], p.at(corners[1])[1]}, {p.at(corners[2])[0], p.at(corners[2])[1]}};
        if (!(orient(c[0], c[1], c[2]) > kAreaEps)) {
            continue;
        }
        double edge_length[3];
        for (int k = 0; k < 3; ++k) {
            const double ex = c[(k + 1) % 3][0] - c[k][0], ey = c[(k + 1) % 3][1] - c[k][1];
            edge_length[k] = std::sqrt(ex * ex + ey * ey);
        }
        const double ymin = std::min(c[0][1], std::min(c[1][1], c[2][1])), ymax = std::max(c[0][1], std::max(c[1][1], c[2][1]));
        const int64_t j0 = std::max<int64_t>(0, int64_t(std::ceil((ymin - y0) / h))), j1 = std::min<int64_t>(ny - 1, int64_t(std::floor((ymax - y0) / h)));
        mine.clear();
        mine.push_back(int(t0));
        int hint = int(t0);
        for (int64_t j = j0; j <= j1; ++j) {
            const double y = y0 + j * h;
            double xl = INFINITY, xr = -INFINITY;
            for (int k = 0; k < 3; ++k) {
                const double* a = c[k];
                const double* b = c[(k + 1) % 3];
                if ((a[1] - y) * (b[1] - y) <= 0.0 && a[1] != b[1]) {
                    const double x = a[0] + (y - a[1]) / (b[1] - a[1]) * (b[0] - a[0]);
                    xl = std::min(xl, x);
                    xr = std::max(xr, x);
                }
            }
            if (!(xl <= xr)) {
                continue;
            }
            const int64_t i0 = std::max<int64_t>(0, int64_t(std::ceil((xl - x0) / h))), i1 = std::min<int64_t>(nx - 1, int64_t(std::floor((xr - x0) / h)));
            for (int64_t i = i0; i <= i1; ++i) {
                if (blocked[size_t(j * nx + i)] != 0) {
                    continue;
                }
                const double q[2] = {x0 + i * h, y};
                // Strictly inside the first triangle (clear of its edges).
                bool inside = true;
                for (int k = 0; k < 3 && inside; ++k) {
                    inside = orient(c[k], c[(k + 1) % 3], q) > edge_margin * edge_length[k];
                }
                if (!inside) {
                    continue;
                }
                // The small triangle that holds it: a walk from the last one, else all of them.
                int at = hint;
                bool found = false;
                for (size_t step = 0; step < mine.size() + 8 && !found; ++step) {
                    found = true;
                    for (int k = 0; k < 3; ++k) {
                        const size_t e = size_t(at) * 3 + size_t(k);
                        if (orient(p.at(p.tri[e]), p.at(p.tri[size_t(at) * 3 + size_t((k + 1) % 3)]), q) < 0.0) {
                            found = false;
                            if (p.fixed[e] != 0 || p.adj[e] < 0) {
                                step = mine.size() + 8;  // would leave the first triangle: search them all
                            }
                            else {
                                at = p.adj[e];
                            }
                            break;
                        }
                    }
                }
                if (!found) {
                    for (const int candidate : mine) {
                        const size_t e = size_t(candidate) * 3;
                        if (orient(p.at(p.tri[e]), p.at(p.tri[e + 1]), q) >= 0.0 && orient(p.at(p.tri[e + 1]), p.at(p.tri[e + 2]), q) >= 0.0 &&
                            orient(p.at(p.tri[e + 2]), p.at(p.tri[e]), q) >= 0.0) {
                            at = candidate;
                            found = true;
                            break;
                        }
                    }
                }
                if (!found) {
                    continue;
                }
                // On an edge of that triangle (within rounding): left out, its neighbours fill in.
                const size_t e = size_t(at) * 3;
                bool clear = true;
                for (int k = 0; k < 3 && clear; ++k) {
                    const double* a = p.at(p.tri[e + size_t(k)]);
                    const double* b = p.at(p.tri[e + size_t((k + 1) % 3)]);
                    const double len = std::sqrt((b[0] - a[0]) * (b[0] - a[0]) + (b[1] - a[1]) * (b[1] - a[1]));
                    clear = orient(a, b, q) > edge_margin * len;
                }
                if (!clear) {
                    continue;
                }
                const int vertex = int(p.xy.size() / 2);
                p.xy.push_back(q[0]);
                p.xy.push_back(q[1]);
                insert(p, at, vertex, mine, todo);
                hint = at;
                ++added;
                if (!settle(p, todo, flips_left, deadline)) {
                    added = 0;
                    return false;
                }
            }
        }
        if (deadline.tick()) {
            added = 0;
            return false;
        }
    }
    if (added == 0) {
        return true;
    }
    // Step 2: the first triangles' inner edges are free now; flip until nothing improves.
    for (size_t s = 0; s < p.adj.size(); ++s) {
        p.fixed[s] = p.adj[s] < 0 ? 1 : 0;
        if (p.adj[s] >= 0) {
            todo.push_back({int(s / 3), int(s % 3)});
        }
    }
    if (!settle(p, todo, flips_left, deadline)) {
        added = 0;
        return false;
    }
    // Back into the mesh: the cap's slots first, the rest appended in the cap's group.
    const uint32_t group = mesh.groups[cap[0]];
    const uint32_t base = uint32_t(mesh.vertex_count());
    const size_t old_vertices = global.size();
    for (size_t v = old_vertices; v < p.xy.size() / 2; ++v) {
        const double x = p.xy[v * 2] * extent + centre[0], y = (p.xy[v * 2 + 1] * extent + centre[1]) * facing;
        for (int k = 0; k < 3; ++k) {
            mesh.positions.push_back(float(frame.origin[k] + x * frame.u[k] + y * frame.v[k]));
        }
    }
    auto vertex_of = [&](int l) { return size_t(l) < old_vertices ? global[size_t(l)] : base + uint32_t(size_t(l) - old_vertices); };
    for (size_t t = 0; t < p.triangles(); ++t) {
        uint32_t ids[3];
        for (int k = 0; k < 3; ++k) {
            ids[k] = vertex_of(p.tri[t * 3 + size_t(k)]);
        }
        if (t < cap.size()) {
            for (int k = 0; k < 3; ++k) {
                mesh.triangles[size_t(cap[t]) * 3 + size_t(k)] = ids[k];
            }
        }
        else {
            mesh.triangles.insert(mesh.triangles.end(), ids, ids + 3);
            mesh.groups.push_back(group);
        }
    }
    return true;
}

}  // namespace holo_forge::mesh::cut

namespace holo_forge
{

namespace
{
using mesh::MeshData;
using mesh::NONE;
const char* const kHint = "Reduce the body first.";

inline double dot3(const double* a, const double* b)
{
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}
inline uint64_t edge_key(uint32_t a, uint32_t b)
{
    return (uint64_t(std::min(a, b)) << 32) | uint64_t(std::max(a, b));
}

/// What the op was asked, checked.
struct Plan
{
    double origin[3] = {0, 0, 0};   // a point of the plane (the offset already applied)
    double normal[3] = {0, 0, 1};   // unit
    int type = 0;                   // 0 trim, 1 split_body, 2 split_faces
    bool flip = false;
    int fill = 1;                   // 0 none, 1 uniform, 2 minimal
    double diagonal = 0.0;
    double eps = 0.0;               // a vertex this near the plane is on it
    double mean_edge = 0.0;
    bool solid = false;             // Manifold can take it
    bool cuts = false;              // the plane has triangles on both sides
    double seconds = 0.0;
    std::string name;
    double limit = 20.0;
};

double mean_edge_length(const MeshData& m)
{
    double sum = 0.0;
    const size_t T = m.triangle_count();
    for (size_t t = 0; t < T; ++t) {
        double p[3][3];
        for (int k = 0; k < 3; ++k) {
            m.point(m.triangles[t * 3 + size_t(k)], p[k]);
        }
        for (int k = 0; k < 3; ++k) {
            const double* a = p[k];
            const double* b = p[(k + 1) % 3];
            sum += std::sqrt((a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1]) + (a[2] - b[2]) * (a[2] - b[2]));
        }
    }
    return T > 0 ? sum / double(T * 3) : 0.0;
}

bool make_plan(mesh::State& state, mesh::ops::Options& o, Plan& plan, bool for_defaults)
{
    const mesh::Measures& ms = mesh::measures_of(state);
    plan.diagonal = ms.diagonal;
    plan.eps = 1e-7 * ms.diagonal;
    plan.name = o.name();
    plan.limit = o.time_limit();
    plan.type = o.choice("type", "Cut Type", {"trim", "split_body", "split_faces"}, 0);
    plan.flip = o.flag("flip", "Keep Other Side", false);
    plan.fill = o.choice("fill", "Fill", {"none", "uniform", "minimal"}, 1);
    const double offset = o.number("offset", "Offset", 0.0);
    double origin[3] = {0, 0, 0}, normal[3] = {0, 0, 1};
    o.vector("origin", "The plane's origin", origin);
    const bool has_normal = o.vector("normal", "The plane's normal", normal);
    if (!o.ok()) {
        return false;
    }
    if (!has_normal && !for_defaults) {
        o.fail("Plane Cut needs a plane (its normal is missing).");
        return false;
    }
    const double len = std::sqrt(dot3(normal, normal));
    if (!(len > 1e-12)) {
        o.fail("The plane's normal must have a length.");
        return false;
    }
    if (!o.range("Offset", offset, -ms.diagonal, ms.diagonal, true)) {
        return false;
    }
    for (int k = 0; k < 3; ++k) {
        plan.normal[k] = normal[k] / len;
        plan.origin[k] = origin[k] + plan.normal[k] * offset;
    }
    // Does the plane cut it at all? (Vertices in use only.)
    const MeshData& m = state.data;
    double least = INFINITY, most = -INFINITY;
    const double d0 = dot3(plan.origin, plan.normal);
    for (const uint32_t v : m.triangles) {
        double p[3];
        m.point(v, p);
        const double d = dot3(p, plan.normal) - d0;
        least = std::min(least, d);
        most = std::max(most, d);
    }
    plan.cuts = least < -plan.eps && most > plan.eps;
    plan.solid = plan.type != 2 && mesh::mf::unfit(state, plan.name).empty();
    plan.mean_edge = mean_edge_length(m);
    using namespace mesh::budget;
    const double T = double(m.triangle_count());
    if (plan.solid) {
        // Trim evaluates one half, Split Body both.
        // One trim for Trim, two for Split Body.
        plan.seconds = estimate(MF_INGEST, T) + estimate(MF_TRIM_BY_PLANE, T) * (plan.type == 0 ? 1.0 : 2.0) + estimate(MF_EXPORT, T) + estimate(OP_FINISH, T);
        // The plain cut each side is checked against (about a third of a clip).
        plan.seconds += estimate(PLANE_CLIP, T) / 3.0;
    }
    else {
        plan.seconds = estimate(PLANE_CLIP, T) + estimate(OP_FINISH, T);
    }
    if (plan.fill == 1 && plan.type != 2) {
        // The cut face is at most half the body's area, so at most about T / 2 grid triangles.
        plan.seconds += CAP_FILL_SECONDS_PER_MILLION_TRIANGLES * std::min(0.5 * T, 2e6) / 1e6 * (plan.type == 1 ? 2.0 : 1.0);
    }
    return true;
}

// ---------------------------------------------------------------- our own clipper

/// The mesh cut along the plane: every triangle that crosses it is split, so each piece lies on
/// one side. Vertices are the mesh's own plus one per crossed edge.
struct Clipped
{
    std::vector<float> positions;
    std::vector<int8_t> side;            // per vertex: +1 above, 0 on the plane, -1 below
    std::vector<uint32_t> triangles;     // 3 per piece
    std::vector<uint32_t> groups;        // per piece
    std::vector<int8_t> piece_side;      // per piece: +1 above, -1 below
    std::vector<uint8_t> flat;           // per piece: 1 when it lies in the plane
    size_t first_new = 0;                // vertices from here on are cut points
};

bool clip(const MeshData& m, const Plan& plan, Clipped& out, const mesh::Deadline& deadline)
{
    const size_t V = m.vertex_count(), T = m.triangle_count();
    out.positions = m.positions;
    out.first_new = V;
    out.side.assign(V, 0);
    std::vector<double> dist(V);
    const double d0 = dot3(plan.origin, plan.normal);
    for (size_t v = 0; v < V; ++v) {
        double p[3];
        m.point(uint32_t(v), p);
        dist[v] = dot3(p, plan.normal) - d0;
        out.side[v] = dist[v] > plan.eps ? 1 : (dist[v] < -plan.eps ? -1 : 0);
    }
    std::unordered_map<uint64_t, uint32_t> cut_vertex;
    auto cut_point = [&](uint32_t a, uint32_t b) {
        const uint64_t key = edge_key(a, b);
        const auto found = cut_vertex.find(key);
        if (found != cut_vertex.end()) {
            return found->second;
        }
        // Always from the lower index to the higher, so both triangles of the edge get the
        // same point to the bit.
        const uint32_t lo = std::min(a, b), hi = std::max(a, b);
        const double t = dist[lo] / (dist[lo] - dist[hi]);
        double p[3], q[3];
        m.point(lo, p);
        m.point(hi, q);
        const uint32_t id = uint32_t(out.positions.size() / 3);
        for (int k = 0; k < 3; ++k) {
            out.positions.push_back(float(p[k] + t * (q[k] - p[k])));
        }
        out.side.push_back(0);
        cut_vertex.insert({key, id});
        return id;
    };
    auto piece = [&](uint32_t a, uint32_t b, uint32_t c, uint32_t group, int8_t side, bool flat) {
        out.triangles.push_back(a);
        out.triangles.push_back(b);
        out.triangles.push_back(c);
        out.groups.push_back(group);
        out.piece_side.push_back(side);
        out.flat.push_back(flat ? 1 : 0);
    };
    auto length2 = [&](uint32_t a, uint32_t b) {
        double s = 0.0;
        for (int k = 0; k < 3; ++k) {
            const double d = double(out.positions[size_t(a) * 3 + size_t(k)]) - double(out.positions[size_t(b) * 3 + size_t(k)]);
            s += d * d;
        }
        return s;
    };
    for (size_t t = 0; t < T; ++t) {
        const uint32_t* tri = &m.triangles[t * 3];
        const int8_t s[3] = {out.side[tri[0]], out.side[tri[1]], out.side[tri[2]]};
        const int above = (s[0] > 0) + (s[1] > 0) + (s[2] > 0), below = (s[0] < 0) + (s[1] < 0) + (s[2] < 0);
        const uint32_t group = m.groups[t];
        if (above == 0 || below == 0) {
            int8_t side = above > 0 ? 1 : -1;
            const bool flat = above == 0 && below == 0;
            if (flat) {
                // In the plane: it bounds the side its normal points away from.
                double p[3][3], e1[3], e2[3], n[3];
                for (int k = 0; k < 3; ++k) {
                    m.point(tri[k], p[k]);
                }
                for (int k = 0; k < 3; ++k) {
                    e1[k] = p[1][k] - p[0][k];
                    e2[k] = p[2][k] - p[0][k];
                }
                n[0] = e1[1] * e2[2] - e1[2] * e2[1];
                n[1] = e1[2] * e2[0] - e1[0] * e2[2];
                n[2] = e1[0] * e2[1] - e1[1] * e2[0];
                side = dot3(n, plan.normal) > 0.0 ? -1 : 1;
            }
            piece(tri[0], tri[1], tri[2], group, side, flat);
        }
        else {
            // One walk around the triangle builds the polygon of each side; a cut point goes to both.
            uint32_t up[4], down[4];
            int nu = 0, nd = 0;
            for (int k = 0; k < 3; ++k) {
                const uint32_t a = tri[k], b = tri[(k + 1) % 3];
                if (s[k] >= 0) {
                    up[nu++] = a;
                }
                if (s[k] <= 0) {
                    down[nd++] = a;
                }
                if (s[k] * s[(k + 1) % 3] < 0) {
                    const uint32_t x = cut_point(a, b);
                    up[nu++] = x;
                    down[nd++] = x;
                }
            }
            for (int half = 0; half < 2; ++half) {
                const uint32_t* poly = half == 0 ? up : down;
                const int count = half == 0 ? nu : nd;
                const int8_t side = half == 0 ? 1 : -1;
                if (count == 3) {
                    piece(poly[0], poly[1], poly[2], group, side, false);
                }
                else if (count == 4) {
                    // The shorter diagonal.
                    if (length2(poly[0], poly[2]) <= length2(poly[1], poly[3])) {
                        piece(poly[0], poly[1], poly[2], group, side, false);
                        piece(poly[0], poly[2], poly[3], group, side, false);
                    }
                    else {
                        piece(poly[0], poly[1], poly[3], group, side, false);
                        piece(poly[1], poly[2], poly[3], group, side, false);
                    }
                }
            }
        }
        if (deadline.tick()) {
            return false;
        }
    }
    return true;
}

/// One side of a clipped mesh, with its cut filled where the cut runs in closed loops.
struct Part
{
    MeshData mesh;
    std::vector<uint32_t> cap;   // the triangles that fill the cut
    int64_t open_cut_edges = 0;  // cut edges left open (the cut ran into an open edge, or the fill failed)
    bool fill_failed = false;
    bool rim = false;            // the plane cut through this part (it has cut edges)
};

void fill_rim(Part& part, std::vector<std::pair<uint32_t, uint32_t>>& rim, int8_t side, const Plan& plan, const std::string& cut_name);

void build_part(mesh::State& state, const Clipped& c, int8_t side, const Plan& plan, const std::string& cut_name, bool fill, Part& part)
{
    const MeshData& m = state.data;
    part.mesh.positions = c.positions;
    part.mesh.group_names = m.group_names;
    for (size_t t = 0; t < c.groups.size(); ++t) {
        if (c.piece_side[t] == side) {
            part.mesh.triangles.insert(part.mesh.triangles.end(), &c.triangles[t * 3], &c.triangles[t * 3] + 3);
            part.mesh.groups.push_back(c.groups[t]);
        }
    }
    // The cut's edges on this part: an edge in the plane with one triangle here, that was not
    // an open edge of the body before.
    struct Use
    {
        uint64_t key;
        uint32_t a, b;
    };
    std::vector<Use> uses;
    const size_t T = part.mesh.triangle_count();
    for (size_t t = 0; t < T; ++t) {
        for (int k = 0; k < 3; ++k) {
            const uint32_t a = part.mesh.triangles[t * 3 + size_t(k)], b = part.mesh.triangles[t * 3 + size_t((k + 1) % 3)];
            if (a != b && c.side[a] == 0 && c.side[b] == 0) {
                uses.push_back({edge_key(a, b), a, b});
            }
        }
    }
    std::sort(uses.begin(), uses.end(), [](const Use& x, const Use& y) { return x.key < y.key; });
    std::unordered_set<uint64_t> was_open;
    {
        const mesh::Topology* topo = mesh::topology_of(state);
        for (size_t he = 0; he < topo->he_edge.size(); ++he) {
            const uint32_t e = topo->he_edge[he];
            if (e == NONE || topo->uses(e) != 1) {
                continue;
            }
            const uint32_t a = m.triangles[he], b = m.triangles[(he / 3) * 3 + (he + 1) % 3];
            if (c.side[a] == 0 && c.side[b] == 0) {
                was_open.insert(edge_key(a, b));
            }
        }
    }
    // The fill runs each cut edge the other way.
    std::vector<std::pair<uint32_t, uint32_t>> rim;
    for (size_t i = 0; i < uses.size();) {
        size_t j = i;
        while (j < uses.size() && uses[j].key == uses[i].key) {
            ++j;
        }
        if (j - i == 1 && was_open.count(uses[i].key) == 0) {
            rim.push_back({uses[i].b, uses[i].a});
        }
        i = j;
    }
    if (rim.empty()) {
        return;
    }
    part.rim = true;
    if (!fill) {
        return;
    }
    fill_rim(part, rim, side, plan, cut_name);
}

/// Fills the closed loops of a part's cut. `rim` holds the cut's edges, each the way the fill
/// runs it (against the triangle that is there). Loops are triangulated in the plane, outer
/// loops and holes together; what cannot be closed or filled is counted in the part.
void fill_rim(Part& part, std::vector<std::pair<uint32_t, uint32_t>>& rim, int8_t side, const Plan& plan, const std::string& cut_name)
{
    const std::vector<float>& positions = part.mesh.positions;
    std::sort(rim.begin(), rim.end());
    std::vector<uint8_t> used(rim.size(), 0);
    std::vector<std::vector<uint32_t>> loops;
    for (size_t first = 0; first < rim.size(); ++first) {
        if (used[first] != 0) {
            continue;
        }
        std::vector<uint32_t> chain;
        const uint32_t start = rim[first].first;
        size_t at = first;
        bool closed = false;
        for (;;) {
            used[at] = 1;
            chain.push_back(rim[at].first);
            const uint32_t next = rim[at].second;
            if (next == start) {
                closed = true;
                break;
            }
            auto found = std::lower_bound(rim.begin(), rim.end(), std::make_pair(next, uint32_t(0)));
            size_t candidate = size_t(found - rim.begin());
            while (candidate < rim.size() && rim[candidate].first == next && used[candidate] != 0) {
                ++candidate;
            }
            if (candidate >= rim.size() || rim[candidate].first != next) {
                break;
            }
            at = candidate;
        }
        if (closed && chain.size() >= 3) {
            loops.push_back(std::move(chain));
        }
        else {
            part.open_cut_edges += int64_t(chain.size());
        }
    }
    if (loops.empty()) {
        return;
    }
    // Closed loops, triangulated in the plane (outer loops and holes together).
    const mesh::cut::Frame frame = mesh::cut::make_frame(plan.origin, plan.normal);
    const int facing = side < 0 ? 1 : -1;  // the cap of the lower part faces along the normal
    manifold::PolygonsIdx polygons;
    double outline_area = 0.0, scale = 0.0;
    int64_t loop_edges = 0;
    for (const std::vector<uint32_t>& loop : loops) {
        manifold::SimplePolygonIdx polygon;
        for (const uint32_t v : loop) {
            double q[3];
            for (int k = 0; k < 3; ++k) {
                q[k] = double(positions[size_t(v) * 3 + size_t(k)]) - frame.origin[k];
            }
            polygon.push_back({manifold::vec2(dot3(q, frame.u), facing * dot3(q, frame.v)), int(v)});
        }
        for (size_t i = 0; i < polygon.size(); ++i) {
            const manifold::vec2 a = polygon[i].pos, b = polygon[(i + 1) % polygon.size()].pos;
            outline_area += 0.5 * (a.x * b.y - b.x * a.y);
            scale = std::max(scale, std::max(std::fabs(a.x), std::fabs(a.y)));
        }
        loop_edges += int64_t(polygon.size());
        polygons.push_back(std::move(polygon));
    }
    std::vector<manifold::ivec3> filled;
    bool ok = outline_area > 0.0;
    if (ok) {
        try {
            filled = manifold::TriangulateIdx(polygons);
        }
        catch (...) {
            ok = false;
        }
    }
    // Checked before it is used: every triangle the right way round, and together exactly the
    // outline's area (overlaps or gaps would show there).
    double fill_area = 0.0;
    if (ok) {
        std::unordered_map<int, manifold::vec2> at;
        for (const manifold::SimplePolygonIdx& polygon : polygons) {
            for (const manifold::PolyVert& v : polygon) {
                at[v.idx] = v.pos;
            }
        }
        for (const manifold::ivec3& tri : filled) {
            const auto a = at.find(tri[0]), b = at.find(tri[1]), d = at.find(tri[2]);
            if (a == at.end() || b == at.end() || d == at.end()) {
                ok = false;
                break;
            }
            const double area = 0.5 * ((b->second.x - a->second.x) * (d->second.y - a->second.y) - (b->second.y - a->second.y) * (d->second.x - a->second.x));
            if (area < -1e-9 * scale * scale) {
                ok = false;
                break;
            }
            fill_area += area;
        }
        ok = ok && !filled.empty() && std::fabs(fill_area - outline_area) <= 1e-6 * outline_area + 1e-12 * scale * scale;
    }
    if (!ok) {
        part.fill_failed = true;
        part.open_cut_edges += loop_edges;
        return;
    }
    uint32_t group = 0;
    while (group < part.mesh.group_names.size() && part.mesh.group_names[group] != cut_name) {
        ++group;
    }
    if (group == part.mesh.group_names.size()) {
        part.mesh.group_names.push_back(cut_name);
    }
    for (const manifold::ivec3& tri : filled) {
        part.cap.push_back(uint32_t(part.mesh.triangle_count()));
        // (Counter-clockwise in the mirrored frame is the right way round in space: see refine_cap.)
        part.mesh.triangles.push_back(uint32_t(tri[0]));
        part.mesh.triangles.push_back(uint32_t(tri[1]));
        part.mesh.triangles.push_back(uint32_t(tri[2]));
        part.mesh.groups.push_back(group);
    }
}

/// A plane that lies on a wall of the body (a void's wall, say) can come back from Manifold with
/// that wall still there, back to back with the cut's own face: a skin without thickness, and
/// which of the two it gives depends on the axis. Such a wall bounds nothing on this side (the
/// material it faced was cut away), so it is taken out together with the cut's face, and the
/// cut is filled again from the edges that are left: the same part on every axis.
/// `foreign` marks the cut's triangles (found by run id). False when there is no such wall, or
/// the new fill did not close (the part is then left as Manifold gave it).
bool mend_skin(MeshData& mesh_in, const std::vector<uint8_t>& foreign, int side, const Plan& plan, double d0, double tolerance, const std::string& cut_name, bool fill,
               std::vector<uint32_t>& cap)
{
    const size_t V = mesh_in.vertex_count(), T = mesh_in.triangle_count();
    std::vector<uint8_t> on(V, 0);
    for (size_t v = 0; v < V; ++v) {
        double p[3];
        mesh_in.point(uint32_t(v), p);
        on[v] = std::fabs(dot3(p, plan.normal) - d0) <= tolerance ? 1 : 0;
    }
    // The cut's face of the upper part looks down the normal, the lower part's up it.
    const double facing = side == 0 ? -1.0 : 1.0;
    std::vector<uint8_t> drop(T, 0);
    size_t skins = 0;
    for (size_t t = 0; t < T; ++t) {
        const uint32_t* tri = &mesh_in.triangles[t * 3];
        if (foreign[t] != 0) {
            drop[t] = 1;
            continue;
        }
        if (on[tri[0]] == 0 || on[tri[1]] == 0 || on[tri[2]] == 0) {
            continue;
        }
        double p[3][3], e1[3], e2[3], n[3];
        for (int k = 0; k < 3; ++k) {
            mesh_in.point(tri[k], p[k]);
        }
        for (int k = 0; k < 3; ++k) {
            e1[k] = p[1][k] - p[0][k];
            e2[k] = p[2][k] - p[0][k];
        }
        n[0] = e1[1] * e2[2] - e1[2] * e2[1];
        n[1] = e1[2] * e2[0] - e1[0] * e2[2];
        n[2] = e1[0] * e2[1] - e1[1] * e2[0];
        // A wall, not what the plane left of a triangle it clipped. Where the plane passes
        // through a vertex or along an edge (or a hair beside them), the clipped triangles
        // come back as tips and as long slivers along the plane: all three corners within the
        // tolerance, yet no wall. A wall is far larger than the tolerance in every direction:
        // its longest edge, and its height over that edge too, so that lying within the
        // tolerance means lying along the plane, which is then asked of its normal as well.
        const double e3[3] = {p[2][0] - p[1][0], p[2][1] - p[1][1], p[2][2] - p[1][2]};
        const double longest2 = std::max(dot3(e1, e1), std::max(dot3(e2, e2), dot3(e3, e3)));
        const double twice_area = std::sqrt(dot3(n, n));
        if (longest2 < 1e6 * tolerance * tolerance || twice_area < 100.0 * tolerance * std::sqrt(longest2)) {
            continue;
        }
        const double along = dot3(n, plan.normal) / twice_area;
        if (along * facing < -0.999) {
            drop[t] = 1;
            ++skins;
        }
    }
    if (skins == 0) {
        return false;
    }
    Part part;
    part.mesh.positions = mesh_in.positions;
    part.mesh.group_names = mesh_in.group_names;
    for (size_t t = 0; t < T; ++t) {
        if (drop[t] == 0) {
            part.mesh.triangles.insert(part.mesh.triangles.end(), &mesh_in.triangles[t * 3], &mesh_in.triangles[t * 3] + 3);
            part.mesh.groups.push_back(mesh_in.groups[t]);
        }
    }
    if (fill) {
        // The open edges that are left all lie on the plane: the cut's rim.
        struct Use
        {
            uint64_t key;
            uint32_t a, b;
        };
        std::vector<Use> uses;
        for (size_t t = 0; t < part.mesh.triangle_count(); ++t) {
            for (int k = 0; k < 3; ++k) {
                const uint32_t a = part.mesh.triangles[t * 3 + size_t(k)], b = part.mesh.triangles[t * 3 + size_t((k + 1) % 3)];
                uses.push_back({edge_key(a, b), a, b});
            }
        }
        std::sort(uses.begin(), uses.end(), [](const Use& x, const Use& y) { return x.key < y.key; });
        std::vector<std::pair<uint32_t, uint32_t>> rim;
        for (size_t i = 0; i < uses.size();) {
            size_t j = i;
            while (j < uses.size() && uses[j].key == uses[i].key) {
                ++j;
            }
            if (j - i == 1) {
                if (on[uses[i].a] == 0 || on[uses[i].b] == 0) {
                    return false;  // an open edge off the plane: not what this mends
                }
                rim.push_back({uses[i].b, uses[i].a});
            }
            i = j;
        }
        if (!rim.empty()) {
            fill_rim(part, rim, side == 0 ? int8_t(1) : int8_t(-1), plan, cut_name);
            if (part.fill_failed || part.open_cut_edges > 0) {
                return false;
            }
        }
        // What comes out must be closed, every edge with its two triangles: if the new fill
        // did not give that, the part stays as Manifold made it.
        uses.clear();
        for (size_t t = 0; t < part.mesh.triangle_count(); ++t) {
            for (int k = 0; k < 3; ++k) {
                const uint32_t a = part.mesh.triangles[t * 3 + size_t(k)], b = part.mesh.triangles[t * 3 + size_t((k + 1) % 3)];
                uses.push_back({edge_key(a, b), a, b});
            }
        }
        std::sort(uses.begin(), uses.end(), [](const Use& x, const Use& y) { return x.key < y.key; });
        for (size_t i = 0; i < uses.size();) {
            size_t j = i;
            while (j < uses.size() && uses[j].key == uses[i].key) {
                ++j;
            }
            if (j - i != 2 || uses[i].a == uses[i + 1].a) {
                return false;  // (open, shared by more than two, or run the same way twice)
            }
            i = j;
        }
    }
    mesh_in = std::move(part.mesh);
    cap = std::move(part.cap);
    return true;
}

/// The room left for new triangles in a mesh body.
size_t room(const MeshData& m)
{
    const size_t tris = mesh::budget::MAX_TRIANGLES_MESH - std::min(mesh::budget::MAX_TRIANGLES_MESH, m.triangle_count());
    const size_t verts = mesh::budget::MAX_VERTICES_MESH - std::min(mesh::budget::MAX_VERTICES_MESH, m.vertex_count());
    return std::min(tris, verts * 2);
}

/// Every edge with exactly two triangles, run opposite ways.
bool closed_pairs(const MeshData& m)
{
    std::vector<std::pair<uint64_t, uint32_t>> uses;  // key, first vertex
    uses.reserve(m.triangles.size());
    for (size_t t = 0; t < m.triangle_count(); ++t) {
        for (int k = 0; k < 3; ++k) {
            const uint32_t a = m.triangles[t * 3 + size_t(k)], b = m.triangles[t * 3 + size_t((k + 1) % 3)];
            uses.push_back({edge_key(a, b), a});
        }
    }
    std::sort(uses.begin(), uses.end());
    for (size_t i = 0; i < uses.size();) {
        size_t j = i;
        while (j < uses.size() && uses[j].first == uses[i].first) {
            ++j;
        }
        if (j - i != 2 || uses[i].second == uses[i + 1].second) {
            return false;
        }
        i = j;
    }
    return true;
}

/// The plain cut, worked out from the body's triangles alone (no fill needed): the volume on
/// each side about a point of the plane, where a cut face adds nothing, so it is the volume of
/// the closed part whatever its fill; the cut's length; and the area of the triangles that come
/// within `eps` of the plane (where snapping a corner to it moves the volume).
struct Plain
{
    double point[3] = {0, 0, 0};    // the point of the plane volumes are taken about
    double volume[2] = {0.0, 0.0};  // [above, below]
    double rim = 0.0;
    double near_area = 0.0;
    double flux[2] = {0.0, 0.0};    // each side's faces' area along the normal (its cut face's, negated)
};

Plain plain_cut(const MeshData& m, const Plan& plan, const double centre[3], double eps)
{
    Plain out;
    // The point of the plane nearest the body's centre (a far point would cost precision).
    const double lift = dot3(centre, plan.normal) - dot3(plan.origin, plan.normal);
    for (int k = 0; k < 3; ++k) {
        out.point[k] = centre[k] - lift * plan.normal[k];
    }
    const size_t T = m.triangle_count();
    for (size_t t = 0; t < T; ++t) {
        double p[3][3], d[3];
        for (int k = 0; k < 3; ++k) {
            m.point(m.triangles[t * 3 + size_t(k)], p[k]);
            for (int c = 0; c < 3; ++c) {
                p[k][c] -= out.point[c];
            }
            d[k] = dot3(p[k], plan.normal);
        }
        int near = 0;
        for (int k = 0; k < 3; ++k) {
            near += std::fabs(d[k]) <= eps ? 1 : 0;
        }
        if (near > 0) {
            double e1[3], e2[3], n[3];
            for (int c = 0; c < 3; ++c) {
                e1[c] = p[1][c] - p[0][c];
                e2[c] = p[2][c] - p[0][c];
            }
            n[0] = e1[1] * e2[2] - e1[2] * e2[1];
            n[1] = e1[2] * e2[0] - e1[0] * e2[2];
            n[2] = e1[0] * e2[1] - e1[1] * e2[0];
            out.near_area += 0.5 * std::sqrt(dot3(n, n));
            if (near == 3) {
                // A face on the plane goes whole with the side it bounds (as in the clipper).
                const int half = dot3(n, plan.normal) > 0.0 ? 1 : 0;
                const double bc[3] = {p[1][1] * p[2][2] - p[1][2] * p[2][1], p[1][2] * p[2][0] - p[1][0] * p[2][2], p[1][0] * p[2][1] - p[1][1] * p[2][0]};
                out.volume[half] += dot3(p[0], bc) / 6.0;
                out.flux[half] += 0.5 * dot3(n, plan.normal);
                continue;
            }
            if (near == 2) {
                // An edge on the plane: half of it here, half in its other triangle.
                for (int k = 0; k < 3; ++k) {
                    if (std::fabs(d[k]) <= eps && std::fabs(d[(k + 1) % 3]) <= eps) {
                        double e[3];
                        for (int c = 0; c < 3; ++c) {
                            e[c] = p[(k + 1) % 3][c] - p[k][c];
                        }
                        out.rim += 0.5 * std::sqrt(dot3(e, e));
                    }
                }
            }
        }
        // Each side's polygon, exactly (a corner on the plane goes to both), as a fan.
        double on_plane[2][3];
        int crossings = 0;
        for (int half = 0; half < 2; ++half) {
            const double sign = half == 0 ? 1.0 : -1.0;
            double poly[4][3];
            int count = 0;
            for (int k = 0; k < 3 && count < 4; ++k) {
                const int j = (k + 1) % 3;
                if (sign * d[k] >= 0.0) {
                    std::copy(p[k], p[k] + 3, poly[count++]);
                }
                if (d[k] * d[j] < 0.0 && count < 4) {
                    const double s = d[k] / (d[k] - d[j]);
                    for (int c = 0; c < 3; ++c) {
                        poly[count][c] = p[k][c] + s * (p[j][c] - p[k][c]);
                    }
                    if (half == 0 && crossings < 2) {
                        std::copy(poly[count], poly[count] + 3, on_plane[crossings]);
                        ++crossings;
                    }
                    ++count;
                }
            }
            for (int i = 1; i + 1 < count; ++i) {
                const double* a = poly[0];
                const double* b = poly[i];
                const double* c = poly[i + 1];
                const double bc[3] = {b[1] * c[2] - b[2] * c[1], b[2] * c[0] - b[0] * c[2], b[0] * c[1] - b[1] * c[0]};
                out.volume[half] += dot3(a, bc) / 6.0;
                const double u[3] = {b[0] - a[0], b[1] - a[1], b[2] - a[2]}, w[3] = {c[0] - a[0], c[1] - a[1], c[2] - a[2]};
                const double uw[3] = {u[1] * w[2] - u[2] * w[1], u[2] * w[0] - u[0] * w[2], u[0] * w[1] - u[1] * w[0]};
                out.flux[half] += 0.5 * dot3(uw, plan.normal);
            }
        }
        if (crossings == 1) {
            // The other end of the segment is a corner on the plane.
            for (int k = 0; k < 3; ++k) {
                if (d[k] == 0.0) {
                    std::copy(p[k], p[k] + 3, on_plane[1]);
                    crossings = 2;
                    break;
                }
            }
        }
        if (crossings == 2) {
            double e[3];
            for (int c = 0; c < 3; ++c) {
                e[c] = on_plane[1][c] - on_plane[0][c];
            }
            out.rim += std::sqrt(dot3(e, e));
        }
    }
    return out;
}

/// The total length of a mesh's open edges (edges with one triangle).
double open_length(const MeshData& m)
{
    std::vector<std::pair<uint64_t, uint32_t>> uses;
    uses.reserve(m.triangles.size());
    for (size_t t = 0; t < m.triangle_count(); ++t) {
        for (int k = 0; k < 3; ++k) {
            const uint32_t a = m.triangles[t * 3 + size_t(k)], b = m.triangles[t * 3 + size_t((k + 1) % 3)];
            uses.push_back({edge_key(a, b), a});
        }
    }
    std::sort(uses.begin(), uses.end());
    double length = 0.0;
    for (size_t i = 0; i < uses.size();) {
        size_t j = i;
        while (j < uses.size() && uses[j].first == uses[i].first) {
            ++j;
        }
        if (j - i == 1) {
            const uint32_t a = uint32_t(uses[i].first >> 32), b = uint32_t(uses[i].first & 0xffffffffu);
            double p[3], q[3];
            m.point(a, p);
            m.point(b, q);
            length += std::sqrt((p[0] - q[0]) * (p[0] - q[0]) + (p[1] - q[1]) * (p[1] - q[1]) + (p[2] - q[2]) * (p[2] - q[2]));
        }
        i = j;
    }
    return length;
}

/// A part's faces' area along the normal (0 for a closed part; minus its open cut face's).
double flux_of(const MeshData& m, const double normal[3])
{
    double f = 0.0;
    for (size_t t = 0; t < m.triangle_count(); ++t) {
        double p[3][3];
        for (int k = 0; k < 3; ++k) {
            m.point(m.triangles[t * 3 + size_t(k)], p[k]);
        }
        const double u[3] = {p[1][0] - p[0][0], p[1][1] - p[0][1], p[1][2] - p[0][2]}, w[3] = {p[2][0] - p[0][0], p[2][1] - p[0][1], p[2][2] - p[0][2]};
        const double uw[3] = {u[1] * w[2] - u[2] * w[1], u[2] * w[0] - u[0] * w[2], u[0] * w[1] - u[1] * w[0]};
        f += 0.5 * dot3(uw, normal);
    }
    return f;
}

/// A part's volume about `point` (for an open part: as if closed by a face through it).
double volume_about(const MeshData& m, const double point[3])
{
    double v = 0.0;
    for (size_t t = 0; t < m.triangle_count(); ++t) {
        double p[3][3];
        for (int k = 0; k < 3; ++k) {
            m.point(m.triangles[t * 3 + size_t(k)], p[k]);
            for (int c = 0; c < 3; ++c) {
                p[k][c] -= point[c];
            }
        }
        const double bc[3] = {p[1][1] * p[2][2] - p[1][2] * p[2][1], p[1][2] * p[2][0] - p[1][0] * p[2][2], p[1][0] * p[2][1] - p[1][1] * p[2][0]};
        v += dot3(p[0], bc) / 6.0;
    }
    return v;
}

/// The area of a part's triangles that lie on the plane (all three corners within `tolerance`)
/// facing the way no face of that side can: along the normal on the upper part, against it on
/// the lower. On a right part that is rounding slivers only; more is a wall without thickness (a
/// fin: a face on the plane kept back to back with the cut face) or a flake.
double wrong_way_area(const MeshData& m, int side, const Plan& plan, double d0, double tolerance)
{
    const double facing = side == 0 ? -1.0 : 1.0;
    double area = 0.0;
    for (size_t t = 0; t < m.triangle_count(); ++t) {
        double p[3][3];
        bool on = true;
        for (int k = 0; k < 3 && on; ++k) {
            m.point(m.triangles[t * 3 + size_t(k)], p[k]);
            on = std::fabs(dot3(p[k], plan.normal) - d0) <= tolerance;
        }
        if (!on) {
            continue;
        }
        double e1[3], e2[3], n[3];
        for (int c = 0; c < 3; ++c) {
            e1[c] = p[1][c] - p[0][c];
            e2[c] = p[2][c] - p[0][c];
        }
        n[0] = e1[1] * e2[2] - e1[2] * e2[1];
        n[1] = e1[2] * e2[0] - e1[0] * e2[2];
        n[2] = e1[0] * e2[1] - e1[1] * e2[0];
        if (dot3(n, plan.normal) * facing < 0.0) {
            area += 0.5 * std::sqrt(dot3(n, n));
        }
    }
    return area;
}

/// Two volumes in mm3, with as many digits as it takes to tell them apart.
std::pair<std::string, std::string> two_volumes(double a, double b)
{
    for (int digits = 6;; ++digits) {
        std::string x = mesh::ops::plain_number(a * 1e9, digits), y = mesh::ops::plain_number(b * 1e9, digits);
        if (x != y || digits >= 12) {
            return {x + " mm3", y + " mm3"};
        }
    }
}

/// The sentences of the parts' checks, each said once: "Plane Cut made 3 triangles without
/// area." from one part and "... 2 ..." from the other become one sentence with both counts.
class Sentences
{
public:
    void add(const String& warning, int side)
    {
        const PackedStringArray lines = warning.split("\n", false);
        for (int i = 0; i < lines.size(); ++i) {
            const std::string line = lines[i].utf8().get_data();
            std::string key;
            int64_t count = 0;
            if (!counted(line, key, count)) {
                if (std::find(plain_.begin(), plain_.end(), line) == plain_.end()) {
                    plain_.push_back(line);
                    order_.push_back({false, plain_.size() - 1});
                }
                continue;
            }
            size_t at = 0;
            while (at < keys_.size() && keys_[at].key != key) {
                ++at;
            }
            if (at == keys_.size()) {
                keys_.push_back({key, {0, 0}});
                order_.push_back({true, at});
            }
            keys_[at].count[side == 0 ? 0 : 1] += count;
        }
    }
    void into(PackedStringArray& out) const
    {
        for (const auto& [is_key, index] : order_) {
            if (!is_key) {
                out.push_back(String::utf8(plain_[index].c_str()));
                continue;
            }
            const Key& k = keys_[index];
            const int64_t total = k.count[0] + k.count[1];
            std::string line = k.key;
            if (total != 1) {
                for (const auto& [one, many] : forms()) {
                    const size_t found = line.find(one);
                    if (found != std::string::npos) {
                        line.replace(found, one.size(), many);
                        break;
                    }
                }
            }
            line.replace(line.find('#'), 1, mesh::with_commas(uint64_t(total)));
            if (k.count[0] > 0 && k.count[1] > 0 && !line.empty() && line.back() == '.') {
                line.pop_back();
                line += " (" + mesh::with_commas(uint64_t(k.count[0])) + " in the upper part, " + mesh::with_commas(uint64_t(k.count[1])) + " in the lower).";
            }
            out.push_back(String::utf8(line.c_str()));
        }
    }

private:
    struct Key
    {
        std::string key;  // the sentence in the singular with # for the count
        int64_t count[2];
    };
    static const std::vector<std::pair<std::string, std::string>>& forms()
    {
        static const std::vector<std::pair<std::string, std::string>> list = {
            {" triangle without area", " triangles without area"},
            {" edge that more than two triangles share", " edges that more than two triangles share"},
            {" part is inside-out", " parts are inside-out"},
            {" place where the mesh crosses itself", " places where the mesh crosses itself"},
        };
        return list;
    }
    /// A sentence of one of the forms above: its singular with # for the count, and the count.
    static bool counted(const std::string& line, std::string& key, int64_t& count)
    {
        const size_t first = line.find_first_of("0123456789");
        if (first == std::string::npos || (first > 0 && line[first - 1] != ' ')) {
            return false;
        }
        size_t end = first;
        std::string digits;
        while (end < line.size() && (std::isdigit(static_cast<unsigned char>(line[end])) || line[end] == ',')) {
            if (line[end] != ',') {
                digits += line[end];
            }
            ++end;
        }
        if (digits.empty() || digits.size() > 15 || (end < line.size() && line[end] != ' ')) {
            return false;
        }
        count = std::stoll(digits);
        std::string rest = line.substr(end);
        bool known = false;
        for (const auto& [one, many] : forms()) {
            const std::string& form = count == 1 ? one : many;
            const size_t found = rest.find(form);
            if (found == 0) {
                rest.replace(found, form.size(), one);
                known = true;
                break;
            }
        }
        if (!known) {
            return false;
        }
        key = line.substr(0, first) + "#" + rest;
        return true;
    }
    std::vector<std::string> plain_;
    std::vector<Key> keys_;
    std::vector<std::pair<bool, size_t>> order_;
};
}  // namespace

namespace mesh
{
Dictionary plane_cut_defaults(State& state, const Dictionary& options)
{
    ops::Options o(options);
    Plan plan;
    Dictionary out;
    const Measures& ms = measures_of(state);
    out["type"] = "trim";
    out["fill"] = "uniform";
    out["flip"] = false;
    out["offset"] = 0.0;
    out["offset_min"] = -ms.diagonal;
    out["offset_max"] = ms.diagonal;
    if (make_plan(state, o, plan, true)) {
        out["seconds"] = plan.seconds;
        out["through_manifold"] = plan.solid;
        out["cuts"] = plan.cuts;
    }
    return out;
}
}  // namespace mesh

Array CadMesh::plane_cut(const Dictionary& options)
{
    clear_messages();
    const double started = mesh::ops::now_ms();
    Array none;
    if (is_null()) {
        fail("There is no mesh to cut.");
        return none;
    }
    mesh::ops::Options o(options);
    Plan plan;
    mesh::ops::Phases phases;
    const bool skip_estimate = o.skip_estimate();
    if (!make_plan(*state, o, plan, false) || !o.ok()) {
        fail(o.problem());
        return none;
    }
    // Far from the origin positions step by more than a cut can be told to: the true reason,
    // before the work (it used to end as "a cut triangle that is not on the plane").
    const mesh::ops::Place place = mesh::ops::place_of(*state);
    {
        const std::string far = mesh::ops::too_far(*state, o.name(true), place.diagonal / 1000.0, "too coarse to cut a body " + mesh::ops::length_text(place.diagonal) + " across");
        if (!far.empty()) {
            fail(far);
            return none;
        }
    }
    if (!plan.cuts) {
        fail("The plane does not cut " + plan.name + ".");
        return none;
    }
    phases.mark("checks");
    if (plan.seconds > plan.limit && !skip_estimate) {
        fail(mesh::ops::too_slow("Plane Cut", plan.seconds, plan.limit, kHint));
        return none;
    }
    const mesh::Deadline deadline(plan.limit);
    const MeshData& input = state->data;
    const mesh::Summary before = mesh::summarize(*state);
    const std::string cut_name = mesh::ops::numbered_name("cut", input.group_names);
    const mesh::cut::Frame frame = mesh::cut::make_frame(plan.origin, plan.normal);
    const double d0 = dot3(plan.origin, plan.normal);
    PackedStringArray warnings;
    auto late = [&]() {
        fail(mesh::ops::timed_out("Plane Cut", plan.limit, kHint));
        return none;
    };

    // Which sides are wanted: [above, below].
    bool want[2] = {true, true};
    if (plan.type == 0) {
        want[plan.flip ? 0 : 1] = false;
    }
    MeshData parts[2];
    std::vector<uint32_t> caps[2];
    bool have[2] = {false, false};
    double library_volume[2] = {0.0, 0.0};
    int64_t open_cut_edges = 0;
    bool fill_failed = false;
    bool any_cut_face = false;  // (a solid: some side came back with a cut face)
    bool own_side[2] = {false, false};  // (a solid: this side was cut again with our own clipper)
    bool cut_face[2] = {false, false};  // (a solid: this side came back with a cut face)
    bool lost_volume = false;           // (a solid: the library's side had the wrong volume)
    double fin_left[2] = {0.0, 0.0};    // (a solid: wall without thickness that had to stay)

    if (plan.type == 2) {
        // Split Faces: everything stays; the upper side of each crossed group becomes a new group.
        Clipped c;
        if (!clip(input, plan, c, deadline)) {
            return late();
        }
        MeshData whole;
        whole.positions = std::move(c.positions);
        whole.triangles = std::move(c.triangles);
        whole.groups = std::move(c.groups);
        whole.group_names = input.group_names;
        const size_t G = input.group_count();
        std::vector<uint8_t> sides(G, 0);
        for (size_t t = 0; t < whole.groups.size(); ++t) {
            if (c.flat[t] == 0) {
                sides[whole.groups[t]] |= c.piece_side[t] > 0 ? 1 : 2;
            }
        }
        std::unordered_set<std::string> taken(input.group_names.begin(), input.group_names.end());
        std::vector<uint32_t> upper(G, NONE);
        for (size_t g = 0; g < G; ++g) {
            if (sides[g] == 3) {
                upper[g] = uint32_t(whole.group_names.size());
                whole.group_names.push_back(mesh::ops::unique_name(mesh::short_group_name(input.group_names[g] + "_cut"), taken));
            }
        }
        for (size_t t = 0; t < whole.groups.size(); ++t) {
            const uint32_t g = whole.groups[t];
            if (upper[g] != NONE && c.flat[t] == 0 && c.piece_side[t] > 0) {
                whole.groups[t] = upper[g];
            }
        }
        if (whole.triangle_count() > mesh::budget::MAX_TRIANGLES_MESH || whole.vertex_count() > mesh::budget::MAX_VERTICES_MESH) {
            fail("Plane Cut would make " + mesh::with_commas(whole.triangle_count()) + " triangles; mesh bodies take up to " +
                 mesh::with_commas(mesh::budget::MAX_TRIANGLES_MESH) + ". " + kHint);
            return none;
        }
        parts[0] = std::move(whole);
        have[0] = true;
        want[1] = false;
    }
    else if (plan.solid) {
        // A closed solid: Manifold. The body is one run with an id of ours, its groups travel as
        // face ids; the triangles of the cut come back in a run with an id that is not ours.
        std::string error;
        try {
            manifold::ExecutionContext ctx;
            const mesh::mf::Watchdog watchdog(ctx, deadline);
            const uint32_t run_id = manifold::Manifold::ReserveIDs(1);
            const manifold::Manifold body = ctx.FromMeshGL(mesh::mf::to_gl(input, run_id, 0));
            mesh::mf::Status status = body.Status();
            if (status == mesh::mf::Status::Cancelled || deadline.expired()) {
                return late();
            }
            if (status != mesh::mf::Status::NoError) {
                fail(mesh::mf::status_text(status, "Plane Cut"));
                return none;
            }
            phases.mark("ingest");
            // One trim per wanted side. (Not SplitByPlane: measured, it does all its work inside
            // the call itself, where no context reaches, so the watchdog could not stop it: a
            // 2M-triangle split came back 2.2 s after its limit. A trim is a deferred boolean,
            // worked out in Status() under the context, and stops like any other.)
            const manifold::vec3 normal(plan.normal[0], plan.normal[1], plan.normal[2]);
            double reach = 0.0;
            {
                const mesh::Measures& mb = mesh::measures_of(*state);
                for (int k = 0; k < 3; ++k) {
                    reach = std::max(reach, std::max(std::fabs(mb.lo[k]), std::fabs(mb.hi[k])));
                }
            }
            const double skin_tolerance = 4.0 * 1.2e-7 * reach + 1e-12;
            // The plain cut each side is checked against, and our own clipper's cut for a side
            // that fails (made when first needed). The clipper takes a corner within a few
            // float32 steps for one on the plane, so that a face on the plane is one.
            Plan wide = plan;
            wide.eps = std::max(plan.eps, skin_tolerance);
            double centre[3];
            {
                const mesh::Measures& mb = mesh::measures_of(*state);
                for (int k = 0; k < 3; ++k) {
                    centre[k] = 0.5 * (mb.lo[k] + mb.hi[k]);
                }
            }
            const Plain plain = plain_cut(input, plan, centre, wide.eps);
            Clipped own;
            bool own_ready = false;
            // Rounding (float32 positions, and corners snapped to the plane) moves a side's
            // volume by at most this much; a face on the plane facing the wrong way by at most
            // this much area (slivers a few steps high along the cut).
            const double volume_slack = 1e-6 * std::fabs(before.volume) + std::max(3e-8 * plan.diagonal, 1.2e-7 * reach) * before.area + wide.eps * plain.near_area + 1e-18;
            const double fin_slack = 16.0 * skin_tolerance * plain.rim + 1e-18;
            // (Fill None: what is left open must be the cut, no more; the library can take a
            // face of the body that lies on the plane for cut face and leave it out.)
            const double flux_slack = 1e-6 * before.area + 16.0 * skin_tolerance * plain.rim + 1e-18;
            enum Fault { NONE_FAULT = 0, VOLUME_FAULT = 1, FIN_FAULT = 2, OPEN_FAULT = 3, FACE_FAULT = 4 };
            auto judge = [&](const MeshData& part, int side, bool closed_wanted, double& volume, double& fin) {
                volume = volume_about(part, plain.point);
                fin = wrong_way_area(part, side, plan, d0, skin_tolerance);
                if (closed_wanted && !closed_pairs(part)) {
                    return OPEN_FAULT;
                }
                if (std::fabs(volume - plain.volume[side]) > volume_slack) {
                    return VOLUME_FAULT;
                }
                if (fin > fin_slack) {
                    return FIN_FAULT;
                }
                if (!closed_wanted && std::fabs(flux_of(part, plan.normal) - plain.flux[side]) > flux_slack) {
                    return FACE_FAULT;
                }
                return NONE_FAULT;
            };
            for (int side = 0; side < 2; ++side) {
                if (!want[side]) {
                    continue;
                }
                const manifold::Manifold half = (side == 0 ? body.TrimByPlane(normal, d0) : body.TrimByPlane(-normal, -d0)).WithContext(ctx);
                status = half.Status();
                if (status == mesh::mf::Status::Cancelled || deadline.expired()) {
                    return late();
                }
                if (status != mesh::mf::Status::NoError) {
                    fail(mesh::mf::status_text(status, "Plane Cut"));
                    return none;
                }
                if (half.IsEmpty()) {
                    // (The plane lies on an outer face: Manifold gives nothing on one side, with no error.)
                    fail("The plane does not cut " + plan.name + ".");
                    return none;
                }
                library_volume[side] = half.Volume();
                phases.mark("split");
                mesh::mf::Import imported;
                if (!mesh::mf::from_gl(half.GetMeshGL64(), {run_id}, input.group_names, cut_name, imported, error)) {
                    fail("Plane Cut failed: " + error + ".");
                    return none;
                }
                // The triangles found by id must lie on the plane; if one does not, the ids lied.
                MeshData& part = imported.mesh;
                const double tolerance = 1e-5 * plan.diagonal + 1e-9 + 2.0 * place.step;
                for (size_t t = 0; t < part.triangle_count(); ++t) {
                    if (imported.foreign[t] == 0) {
                        continue;
                    }
                    for (int k = 0; k < 3; ++k) {
                        double p[3];
                        part.point(part.triangles[t * 3 + size_t(k)], p);
                        if (std::fabs(dot3(p, plan.normal) - d0) > tolerance) {
                            fail("Plane Cut found a cut triangle that is not on the plane (internal error). Please report it.");
                            return none;
                        }
                    }
                }
                // (No cut face at all is no error: the plane passes between pieces of the body,
                // or along a face two pieces share, and this side's pieces came back whole.)
                cut_face[side] = imported.foreign_triangles > 0;
                // (A wall counts as lying on the plane only within what float32 positions can
                // tell apart, a few steps of the largest coordinate: with the wider tolerance
                // above, the whole of a thin sliver would be taken for such a wall.)
                if (mend_skin(part, imported.foreign, side, plan, d0, skin_tolerance, cut_name, plan.fill != 0, caps[side])) {
                    parts[side] = std::move(part);
                }
                else if (plan.fill == 0) {
                    MeshData kept;
                    kept.positions = part.positions;
                    kept.group_names = part.group_names;
                    for (size_t t = 0; t < part.triangle_count(); ++t) {
                        if (imported.foreign[t] == 0) {
                            kept.triangles.insert(kept.triangles.end(), &part.triangles[t * 3], &part.triangles[t * 3] + 3);
                            kept.groups.push_back(part.groups[t]);
                        }
                    }
                    parts[side] = std::move(kept);
                }
                else {
                    for (size_t t = 0; t < part.triangle_count(); ++t) {
                        if (imported.foreign[t] != 0) {
                            caps[side].push_back(uint32_t(t));
                        }
                    }
                    parts[side] = std::move(part);
                }
                // Checked against the plain cut. The library takes pieces that touch for one solid
                // and can lose volume where they do (a small cube standing on a big one, cut on
                // the face between them), and a face on the plane can come back as a wall without
                // thickness, back to back with the cut face (the inner wall of a U channel), or
                // as a flake. Such a side is cut again with our own clipper, which goes by the
                // triangles alone: a face on the plane goes with the side it bounds.
                double volume = 0.0, fin = 0.0;
                Fault fault = parts[side].triangle_count() == 0 ? NONE_FAULT : judge(parts[side], side, plan.fill != 0, volume, fin);
                Part mine;
                bool mine_built = false;
                auto build_mine = [&]() {
                    if (!own_ready) {
                        if (!clip(input, wide, own, deadline)) {
                            return false;
                        }
                        own_ready = true;
                    }
                    if (!mine_built) {
                        build_part(*state, own, side == 0 ? int8_t(1) : int8_t(-1), wide, cut_name, plan.fill != 0, mine);
                        mine_built = true;
                    }
                    return true;
                };
                if (fault == NONE_FAULT && plan.fill == 0 && parts[side].triangle_count() > 0) {
                    // Fill None: the open edges must be the cut's and no more. The library can
                    // leave a piece that stands on the plane as a ring of walls without height
                    // there (no volume, no area to speak of, but open edges as long as its outline).
                    if (!build_mine()) {
                        return late();
                    }
                    const double theirs = open_length(parts[side]), ours = open_length(mine.mesh);
                    if (std::fabs(theirs - ours) > 1e-5 * (ours + std::sqrt(before.area)) + 16.0 * skin_tolerance) {
                        fault = FACE_FAULT;
                    }
                }
                if (fault != NONE_FAULT) {
                    if (!build_mine()) {
                        return late();
                    }
                    double own_volume = 0.0, own_fin = 0.0;
                    const bool filled = plan.fill == 0 || (!mine.fill_failed && mine.open_cut_edges == 0);
                    const Fault own_fault = mine.mesh.triangle_count() == 0 ? VOLUME_FAULT : judge(mine.mesh, side, plan.fill != 0, own_volume, own_fin);
                    if (filled && own_fault == NONE_FAULT) {
                        parts[side] = std::move(mine.mesh);
                        caps[side] = std::move(mine.cap);
                        own_side[side] = true;
                        cut_face[side] = mine.rim;
                        lost_volume = lost_volume || fault == VOLUME_FAULT;
                    }
                    else if (fault == FIN_FAULT) {
                        // (Manifold's part is closed and has the right volume: it is kept, and
                        // the wall is said.)
                        fin_left[side] = fin;
                    }
                    else if (fault == OPEN_FAULT || fault == FACE_FAULT) {
                        // (Kept: the closed check below refuses an open part with what it
                        // found; with Fill None the part is the library's.)
                    }
                    else {
                        // The pieces cross or overlap each other: neither cut is right.
                        const auto [has, made_volume] = two_volumes(plain.volume[side], volume);
                        const std::string sentence = "Plane Cut could not cut " + plan.name + " cleanly: " + std::string(plan.type == 1 ? "on one side of the plane" : "on the side it keeps") +
                                                     " the body has " + has + ", but the cut came out with " + made_volume + ". Check " + plan.name +
                                                     " for pieces that cross or overlap each other.";
                        Dictionary refused;
                        refused["volume"] = String("fail: ") + mesh::ops::text(sentence);
                        last_report["op"] = "plane_cut";
                        last_report["checks"] = refused;
                        fail(sentence);
                        return none;
                    }
                }
                if (parts[side].triangle_count() == 0) {
                    // (Nothing with a thickness is left on this side.)
                    fail("The plane does not cut " + plan.name + ".");
                    return none;
                }
                have[side] = true;
                phases.mark("export");
            }
        }
        catch (const std::exception& e) {
            fail(std::string("Plane Cut failed inside the mesh library: ") + e.what());
            return none;
        }
        catch (...) {
            fail("Plane Cut failed inside the mesh library.");
            return none;
        }
        any_cut_face = cut_face[0] || cut_face[1];
    }
    else {
        // An open body (or one Manifold cannot take): our own clipper, then the closed loops filled.
        Clipped c;
        if (!clip(input, plan, c, deadline)) {
            return late();
        }
        for (int side = 0; side < 2; ++side) {
            if (!want[side]) {
                continue;
            }
            Part part;
            build_part(*state, c, side == 0 ? int8_t(1) : int8_t(-1), plan, cut_name, plan.fill != 0, part);
            if (part.mesh.triangle_count() == 0) {
                fail("The plane does not cut " + plan.name + ".");
                return none;
            }
            open_cut_edges = std::max(open_cut_edges, part.open_cut_edges);
            fill_failed = fill_failed || part.fill_failed;
            parts[side] = std::move(part.mesh);
            caps[side] = std::move(part.cap);
            have[side] = true;
            if (deadline.expired()) {
                return late();
            }
        }
    }

    phases.mark("clip");
    // Uniform fill: grid points of the body's mean edge length inside each cut face.
    bool coarser = false, plain_fill = false;
    if (plan.fill == 1 && plan.type != 2) {
        for (int side = 0; side < 2; ++side) {
            if (!have[side] || caps[side].empty()) {
                continue;
            }
            size_t added = 0;
            const size_t space = room(parts[side]);
            // (The same test refine_cap makes, to say so when the grid had to be coarser.)
            double cap_area = 0.0;
            for (const uint32_t t : caps[side]) {
                double p[3][3], e1[3], e2[3], n[3];
                for (int k = 0; k < 3; ++k) {
                    parts[side].point(parts[side].triangles[size_t(t) * 3 + size_t(k)], p[k]);
                }
                for (int k = 0; k < 3; ++k) {
                    e1[k] = p[1][k] - p[0][k];
                    e2[k] = p[2][k] - p[0][k];
                }
                n[0] = e1[1] * e2[2] - e1[2] * e2[1];
                n[1] = e1[2] * e2[0] - e1[0] * e2[2];
                n[2] = e1[0] * e2[1] - e1[1] * e2[0];
                cap_area += 0.5 * std::sqrt(dot3(n, n));
            }
            coarser = coarser || 2.0 * cap_area / (plan.mean_edge * plan.mean_edge) > double(space);
            const int facing = side == 0 ? -1 : 1;
            if (!mesh::cut::refine_cap(parts[side], caps[side], frame, facing, plan.mean_edge, space, deadline, added)) {
                if (deadline.expired()) {
                    return late();
                }
                plain_fill = true;
            }
        }
    }
    phases.mark("fill");
    if (deadline.expired()) {
        return late();
    }

    // The results, each through the shared checks; then what this op promises.
    Array out;
    Array part_reports;
    Dictionary first_report;
    Ref<CadMesh> made[2];
    double volumes[2] = {0.0, 0.0};
    Sentences said;
    // (Closed parts are promised for a solid. A body with no open edge that is still no solid
    // -- triangles facing the wrong way, parts inside-out -- went through our own clipper, and
    // where its cut cannot be filled the warning below says why.)
    const bool promise_closed = plan.solid && plan.type != 2 && plan.fill != 0;
    for (int side = 0; side < 2; ++side) {
        if (!have[side]) {
            part_reports.push_back(Dictionary());
            continue;
        }
        const size_t cap_count = caps[side].size();
        made[side] = finish_op("Plane Cut", "plane_cut", std::move(parts[side]), started, false);
        if (made[side].is_null()) {
            return none;
        }
        said.add(last_warning, side);
        last_warning = String();
        Dictionary checks = last_report["checks"];
        const mesh::Summary after = mesh::summarize(made[side]->get_state());
        volumes[side] = after.volume;
        if (promise_closed) {
            if (after.boundary_edges > 0 || after.non_manifold_edges > 0) {
                const std::string sentence = "Plane Cut made a part that is not closed (" + mesh::ops::count_text(after.boundary_edges, "open edge", "open edges") + ", " +
                                             mesh::ops::count_text(after.non_manifold_edges, "edge", "edges") + " shared by more than two triangles). Please report it.";
                checks["closed"] = String("fail: ") + mesh::ops::text(sentence);
                last_report["checks"] = checks;
                fail(sentence);
                return none;
            }
            checks["closed"] = "ok";
            if (plan.solid && !own_side[side]) {
                const double lib = library_volume[side];
                // (Against the body's size, not the part's own: a thin sliver's volume is small
                // next to what rounding its points to float32 moves. That rounding is at most
                // one float32 step of the largest coordinate, over the part's area.)
                const mesh::Measures& mb = mesh::measures_of(*state);
                double reach = 0.0;
                for (int k = 0; k < 3; ++k) {
                    reach = std::max(reach, std::max(std::fabs(mb.lo[k]), std::fabs(mb.hi[k])));
                }
                if (std::fabs(after.volume - lib) > 1e-5 * std::fabs(before.volume) + 1.2e-7 * reach * after.area + 1e-18) {
                    const auto [was, became] = two_volumes(lib, after.volume);
                    const std::string sentence = "Plane Cut's result changed on the way back from the mesh library (volume " + was + " became " + became + "). Please report it.";
                    checks["export"] = String("fail: ") + mesh::ops::text(sentence);
                    last_report["checks"] = checks;
                    fail(sentence);
                    return none;
                }
                checks["export"] = "ok";
            }
        }
        if (plan.type == 2) {
            // Split Faces splits both triangles of every crossed edge at one point: no new open edge.
            if (after.boundary_edges != before.boundary_edges || after.non_manifold_edges != before.non_manifold_edges) {
                checks["boundary"] = "fail: the open edges changed";
                last_report["checks"] = checks;
                fail("Plane Cut opened the mesh while splitting its faces (internal error). Please report it.");
                return none;
            }
            checks["boundary"] = "ok";
        }
        last_report["checks"] = checks;
        // (The cut face's triangles as they are now: the even fill has added to them.)
        const int cut_group = made[side]->find_face(mesh::ops::text(cut_name));
        last_report["cap_triangles"] = cut_group >= 0 ? int64_t(made[side]->group_triangles(cut_group).size()) : int64_t(0);
        (void)cap_count;
        part_reports.push_back(last_report);
        if (first_report.is_empty()) {
            first_report = last_report;
        }
        last_report = Dictionary();
    }
    last_report = first_report.duplicate(true);
    Dictionary checks = last_report["checks"];
    said.into(warnings);
    if (promise_closed) {
        const double v_in = before.volume;
        // (One millionth, plus what rounding the cut's vertices to float32 can move.)
        const double slack = 1e-6 * std::fabs(v_in) + std::max(3e-8 * plan.diagonal, 1.2e-7 * place.reach) * before.area;
        if (plan.type == 1) {
            // Split Body: the two volumes add up to the input's.
            if (std::fabs(volumes[0] + volumes[1] - v_in) > slack) {
                const auto [together, had] = two_volumes(volumes[0] + volumes[1], v_in);
                const std::string sentence = "Plane Cut's two parts have " + together + " together, but the body had " + had + ". Check " + plan.name +
                                             " for pieces that cross or overlap each other.";
                checks["volume"] = String("fail: ") + mesh::ops::text(sentence);
                last_report["checks"] = checks;
                fail(sentence);
                return none;
            }
        }
        else {
            const double v = volumes[plan.flip ? 1 : 0];
            if (!(v > -slack) || v > v_in + slack) {
                const auto [kept, had] = two_volumes(v, v_in);
                const std::string sentence = "Plane Cut kept " + kept + " of a body of " + had + ". Check " + plan.name + " for pieces that cross or overlap each other.";
                checks["volume"] = String("fail: ") + mesh::ops::text(sentence);
                last_report["checks"] = checks;
                fail(sentence);
                return none;
            }
        }
        checks["volume"] = "ok";
    }
    if ((fill_failed || open_cut_edges > 0) && plan.fill != 0 && plan.type != 2 && before.boundary_edges == 0) {
        // No open edge before, and still the cut does not close: the body is no proper solid.
        std::string why = mesh::mf::unfit(*state, o.name(true));
        if (why.empty()) {
            why = "Run Stitch and Remove on " + plan.name + " first.";
        }
        warnings.push_back(mesh::ops::text("The cut could not be filled (" + mesh::ops::count_text(open_cut_edges, "cut edge stays", "cut edges stay") + " open). " + why));
        checks["fill"] = "warn: the cut could not be filled";
    }
    else if (fill_failed) {
        warnings.push_back(mesh::ops::text("The cut could not be filled (" + mesh::ops::count_text(open_cut_edges, "cut edge stays", "cut edges stay") +
                                           " open). Run Stitch and Remove on " + plan.name + " first."));
        checks["fill"] = "warn: the cut could not be filled";
    }
    else if (open_cut_edges > 0 && plan.fill != 0 && plan.type != 2) {
        warnings.push_back(mesh::ops::text(mesh::ops::count_text(open_cut_edges, "cut edge stays", "cut edges stay") + " open (the body was open there)."));
        checks["fill"] = "warn: cut edges stay open";
    }
    if (plan.solid && plan.type != 2 && !any_cut_face) {
        warnings.push_back(mesh::ops::text("The plane passes between the pieces of " + plan.name + ": nothing was cut, each piece went to its side."));
        checks["cut"] = "warn: the plane passes between pieces";
    }
    if (fin_left[0] + fin_left[1] > 0.0) {
        warnings.push_back(mesh::ops::text("Plane Cut left " + mesh::ops::plain_number((fin_left[0] + fin_left[1]) * 1e6, 4) + " mm2 of a face of " + plan.name +
                                           " that lies on the plane as a wall without thickness. Move the plane off that face a little first."));
        checks["fin"] = "warn: a wall without thickness stays on the plane";
    }
    else if (plan.solid && plan.type != 2) {
        checks["fin"] = "ok";
    }
    if (own_side[0] || own_side[1]) {
        checks["own_cut"] = "ok: cut again by the triangles (the mesh library's side was not right)";
        if (any_cut_face && lost_volume && before.components > 1) {
            // (The library had taken pieces that touch or overlap for one solid.)
            warnings.push_back(mesh::ops::text("Each piece of " + plan.name + " was cut on its own: pieces that touch or overlap each other stay so (Rebuild makes one solid of them)."));
        }
    }
    {
        const std::string note = mesh::ops::rounding_note(*state, o.name(true));
        if (!note.empty()) {
            warnings.push_back(mesh::ops::text(note));
            checks["precision"] = "warn: far from the origin for its size";
        }
    }
    if (plain_fill) {
        warnings.push_back("The cut face kept its plain fill (it could not be filled evenly).");
        checks["uniform"] = "warn: plain fill kept";
    }
    else if (coarser) {
        warnings.push_back(mesh::ops::text("The cut face was filled with triangles larger than the body's (" + mesh::ops::length_text(plan.mean_edge) +
                                           ") to stay under " + mesh::with_commas(mesh::budget::MAX_TRIANGLES_MESH) + " triangles."));
        checks["uniform"] = "warn: coarser fill";
    }
    phases.mark("finish");
    last_report["phases"] = phases.ms;
    last_report["estimate"] = plan.seconds;
    last_report["checks"] = checks;
    last_report["parts"] = part_reports;
    last_report["cut_group"] = mesh::ops::text(cut_name);
    last_report["through_manifold"] = plan.solid && !own_side[0] && !own_side[1];
    last_report["ms"] = mesh::ops::now_ms() - started;
    last_warning = String("\n").join(warnings);
    for (int side = 0; side < 2; ++side) {
        out.push_back(made[side].is_valid() ? Variant(made[side]) : Variant());
    }
    return out;
}

}  // namespace holo_forge
