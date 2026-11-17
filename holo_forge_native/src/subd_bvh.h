#pragma once

// A small axis-aligned bounding-box hierarchy in doubles, used by CadSubD for ray picking,
// visibility, nearest-triangle and closest-point queries and the cage self-intersection test.
// Primitives are referred to by index; the caller keeps their geometry.

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <vector>

namespace holo_forge::subd
{

struct Box
{
    double lo[3] = {std::numeric_limits<double>::infinity(), std::numeric_limits<double>::infinity(),
                    std::numeric_limits<double>::infinity()};
    double hi[3] = {-std::numeric_limits<double>::infinity(), -std::numeric_limits<double>::infinity(),
                    -std::numeric_limits<double>::infinity()};

    void add(const double* p)
    {
        for (int k = 0; k < 3; ++k) {
            lo[k] = std::min(lo[k], p[k]);
            hi[k] = std::max(hi[k], p[k]);
        }
    }
    void add(const Box& b)
    {
        for (int k = 0; k < 3; ++k) {
            lo[k] = std::min(lo[k], b.lo[k]);
            hi[k] = std::max(hi[k], b.hi[k]);
        }
    }
    void expand(double r)
    {
        for (int k = 0; k < 3; ++k) {
            lo[k] -= r;
            hi[k] += r;
        }
    }
    bool empty() const { return lo[0] > hi[0]; }
    /// Squared distance from p to the box (0 inside).
    double dist2(const double* p) const
    {
        double d = 0.0;
        for (int k = 0; k < 3; ++k) {
            const double e = p[k] < lo[k] ? lo[k] - p[k] : (p[k] > hi[k] ? p[k] - hi[k] : 0.0);
            d += e * e;
        }
        return d;
    }
    bool overlaps(const Box& b) const
    {
        for (int k = 0; k < 3; ++k) {
            if (b.lo[k] > hi[k] || b.hi[k] < lo[k]) {
                return false;
            }
        }
        return true;
    }
    /// Slab test: does the ray o + t d (inv = 1/d) meet the box for some t in [0, tmax]?
    bool ray(const double* o, const double* inv, double tmax, double& tnear) const
    {
        double t0 = 0.0, t1 = tmax;
        for (int k = 0; k < 3; ++k) {
            double a = (lo[k] - o[k]) * inv[k];
            double b = (hi[k] - o[k]) * inv[k];
            if (a > b) {
                std::swap(a, b);
            }
            // NaN (0 * inf) means the ray runs inside the slab plane: keep the interval.
            if (a == a) {
                t0 = std::max(t0, a);
            }
            if (b == b) {
                t1 = std::min(t1, b);
            }
            if (t0 > t1) {
                return false;
            }
        }
        tnear = t0;
        return true;
    }
};

class Bvh
{
public:
    struct Node
    {
        Box box;
        int left = -1;   // child index, or -1 for a leaf
        int right = -1;
        int first = 0;   // leaf: range in prims
        int count = 0;
    };

    void build(const std::vector<Box>& boxes);
    bool empty() const { return nodes.empty(); }
    void clear()
    {
        nodes.clear();
        prims.clear();
    }

    /// Calls visit(prim, tmax&) for every primitive whose box meets the ray within [0, tmax];
    /// visit may shrink tmax (closest-hit) or return false to stop the walk (any-hit).
    template <class F>
    void ray(const double o[3], const double d[3], double tmax, F&& visit) const
    {
        if (nodes.empty()) {
            return;
        }
        double inv[3];
        for (int k = 0; k < 3; ++k) {
            inv[k] = 1.0 / d[k];
        }
        int stack[128];
        int top = 0;
        stack[top++] = 0;
        while (top > 0) {
            const Node& n = nodes[size_t(stack[--top])];
            double tn = 0.0;
            if (!n.box.ray(o, inv, tmax, tn)) {
                continue;
            }
            if (n.left < 0) {
                for (int i = 0; i < n.count; ++i) {
                    if (!visit(prims[size_t(n.first + i)], tmax)) {
                        return;
                    }
                }
            }
            else if (top < 126) {
                stack[top++] = n.left;
                stack[top++] = n.right;
            }
        }
    }

    /// Visits primitives in order of increasing box distance while that distance is below
    /// best2 (squared); visit(prim, best2&) may lower best2.
    template <class F>
    void nearest(const double p[3], double& best2, F&& visit) const
    {
        if (nodes.empty()) {
            return;
        }
        struct Item
        {
            double d2;
            int node;
        };
        std::vector<Item> heap;
        heap.reserve(64);
        auto cmp = [](const Item& a, const Item& b) { return a.d2 > b.d2; };
        heap.push_back({nodes[0].box.dist2(p), 0});
        while (!heap.empty()) {
            std::pop_heap(heap.begin(), heap.end(), cmp);
            const Item it = heap.back();
            heap.pop_back();
            if (it.d2 >= best2) {
                break;
            }
            const Node& n = nodes[size_t(it.node)];
            if (n.left < 0) {
                for (int i = 0; i < n.count; ++i) {
                    visit(prims[size_t(n.first + i)], best2);
                }
            }
            else {
                const double a = nodes[size_t(n.left)].box.dist2(p);
                const double b = nodes[size_t(n.right)].box.dist2(p);
                if (a < best2) {
                    heap.push_back({a, n.left});
                    std::push_heap(heap.begin(), heap.end(), cmp);
                }
                if (b < best2) {
                    heap.push_back({b, n.right});
                    std::push_heap(heap.begin(), heap.end(), cmp);
                }
            }
        }
    }

    /// Calls visit(prim) for every primitive whose box overlaps b.
    template <class F>
    void overlap(const Box& b, F&& visit) const
    {
        if (nodes.empty()) {
            return;
        }
        int stack[128];
        int top = 0;
        stack[top++] = 0;
        while (top > 0) {
            const Node& n = nodes[size_t(stack[--top])];
            if (!n.box.overlaps(b)) {
                continue;
            }
            if (n.left < 0) {
                for (int i = 0; i < n.count; ++i) {
                    visit(prims[size_t(n.first + i)]);
                }
            }
            else if (top < 126) {
                stack[top++] = n.left;
                stack[top++] = n.right;
            }
        }
    }

    std::vector<Node> nodes;
    std::vector<int> prims;
};

// ---------------------------------------------------------------- triangle helpers (doubles)

/// Moller-Trumbore. Returns true with t, b1, b2 (barycentrics of b and c) when the ray
/// o + t d meets triangle (a, b, c) for t in (tmin, tmax). Edges count as inside (eps).
bool ray_triangle(const double* o, const double* d, const double* a, const double* b, const double* c, double tmin,
                  double tmax, double& t, double& b1, double& b2);

/// Closest point on triangle (a, b, c) to p (Ericson); returns the squared distance and the
/// point, with the barycentrics of b and c.
double closest_on_triangle(const double* p, const double* a, const double* b, const double* c, double* out,
                           double& b1, double& b2);

/// True when the two closed triangles meet: crossing, touching at an edge or a corner, or
/// overlapping when coplanar. eps is the distance tolerance (meters). Callers test only faces
/// that share no vertex, so any contact there is a self-intersection of the cage.
bool triangles_cross(const double* a0, const double* a1, const double* a2, const double* b0, const double* b1,
                     const double* b2, double eps);

}  // namespace holo_forge::subd
