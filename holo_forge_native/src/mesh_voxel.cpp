#include "mesh_voxel.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <utility>

namespace holo_forge::mesh::voxel
{

namespace
{
constexpr float kFar = 1e30f;

inline int cells_along(double size, double margin, double h)
{
    return int(std::ceil((size + 2.0 * margin) / h - 1e-9)) + 1;
}

/// The squared distance from p to the nearest triangle, when below best2 (else best2). A plain
/// stack walk, nearer child first: no allocation per call (subd::Bvh::nearest keeps a heap).
double nearest2(const TriBvh& tree, const double p[3], double best2, std::vector<int>& stack)
{
    const std::vector<subd::Bvh::Node>& nodes = tree.bvh.nodes;
    const std::vector<int>& prims = tree.bvh.prims;
    if (nodes.empty()) {
        return best2;
    }
    stack.clear();
    stack.push_back(0);
    while (!stack.empty()) {
        const subd::Bvh::Node& n = nodes[size_t(stack.back())];
        stack.pop_back();
        if (n.box.dist2(p) >= best2) {
            continue;
        }
        if (n.left < 0) {
            for (int i = 0; i < n.count; ++i) {
                double a[3], b[3], c[3], q[3], b1 = 0.0, b2 = 0.0;
                tree.corners(uint32_t(prims[size_t(n.first + i)]), a, b, c);
                const double d2 = subd::closest_on_triangle(p, a, b, c, q, b1, b2);
                if (d2 < best2) {
                    best2 = d2;
                }
            }
            continue;
        }
        const double da = nodes[size_t(n.left)].box.dist2(p), db = nodes[size_t(n.right)].box.dist2(p);
        // The nearer child is pushed last, so it is looked at first.
        if (da <= db) {
            if (db < best2) {
                stack.push_back(n.right);
            }
            if (da < best2) {
                stack.push_back(n.left);
            }
        }
        else {
            if (da < best2) {
                stack.push_back(n.left);
            }
            if (db < best2) {
                stack.push_back(n.right);
            }
        }
    }
    return best2;
}
}  // namespace

double sample_count(const double lo[3], const double hi[3], double margin, double h)
{
    if (!(h > 0.0)) {
        return std::numeric_limits<double>::infinity();
    }
    double count = 1.0;
    for (int k = 0; k < 3; ++k) {
        count *= std::ceil((hi[k] - lo[k] + 2.0 * margin) / h - 1e-9) + 1.0;
    }
    return count;
}

Grid make_grid(const double lo[3], const double hi[3], double margin, double h)
{
    Grid grid;
    grid.h = h;
    for (int k = 0; k < 3; ++k) {
        grid.n[k] = std::max(2, cells_along(hi[k] - lo[k], margin, h));
        const double extent = (grid.n[k] - 1) * h;
        grid.origin[k] = 0.5 * (lo[k] + hi[k]) - 0.5 * extent;
    }
    return grid;
}

double fitting_cell(const double lo[3], const double hi[3], double fixed_margin, double margin_cells, double max_samples)
{
    auto count = [&](double h) { return sample_count(lo, hi, fixed_margin + margin_cells * h, h); };
    double size = 0.0;
    for (int k = 0; k < 3; ++k) {
        size = std::max(size, hi[k] - lo[k] + 2.0 * fixed_margin);
    }
    if (!(size > 0.0)) {
        return 0.0;
    }
    double high = size;
    while (count(high) > max_samples) {
        high *= 2.0;
    }
    double low = high;
    for (int i = 0; i < 80 && count(low) <= max_samples; ++i) {
        low *= 0.5;
    }
    for (int i = 0; i < 60; ++i) {
        const double mid = 0.5 * (low + high);
        if (count(mid) <= max_samples) {
            high = mid;
        }
        else {
            low = mid;
        }
    }
    // Up to 3 significant digits (a larger cell never has more samples).
    const double unit = std::pow(10.0, std::floor(std::log10(high)) - 2.0);
    double rounded = std::ceil(high / unit - 1e-9) * unit;
    if (count(rounded) > max_samples) {
        rounded += unit;
    }
    return rounded;
}

bool distance_field(const TriBvh& bvh, const Grid& grid, double band, std::vector<float>& out, const Deadline& deadline)
{
    out.assign(grid.count(), float(band));
    const double band2 = band * band;
    std::vector<int> stack;
    stack.reserve(256);
    size_t at = 0;
    for (int k = 0; k < grid.n[2]; ++k) {
        for (int j = 0; j < grid.n[1]; ++j) {
            for (int i = 0; i < grid.n[0]; ++i, ++at) {
                double p[3];
                grid.point(i, j, k, p);
                const double d2 = nearest2(bvh, p, band2, stack);
                if (d2 < band2) {
                    out[at] = float(std::sqrt(d2));
                }
                if (deadline.tick()) {
                    return false;
                }
            }
        }
    }
    return true;
}

bool winding_field(const TriBvh& bvh, const Grid& grid, bool by_parity, std::vector<uint8_t>& inside, const Deadline& deadline)
{
    inside.assign(grid.count(), 0);
    std::vector<std::pair<double, int>> hits;  // (height, sign), per column
    const double direction[3] = {0.0, 0.0, 1.0};
    for (int j = 0; j < grid.n[1]; ++j) {
        for (int i = 0; i < grid.n[0]; ++i) {
            double p[3];
            grid.point(i, j, 0, p);
            p[2] -= grid.h;
            hits.clear();
            // The same rule as TriBvh::column (each edge is judged once, whichever triangle
            // asks), with the height of every crossing kept.
            bvh.bvh.ray(p, direction, std::numeric_limits<double>::infinity(), [&](int prim, double&) {
                double a[3], b[3], c[3];
                bvh.corners(uint32_t(prim), a, b, c);
                const int w = TriBvh::winding_2d(a, b, p) + TriBvh::winding_2d(b, c, p) + TriBvh::winding_2d(c, a, p);
                if (w == 0) {
                    return true;
                }
                const double nx = (b[1] - a[1]) * (c[2] - a[2]) - (b[2] - a[2]) * (c[1] - a[1]);
                const double ny = (b[2] - a[2]) * (c[0] - a[0]) - (b[0] - a[0]) * (c[2] - a[2]);
                const double nz = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
                if (nz == 0.0) {
                    return true;
                }
                hits.push_back({a[2] - (nx * (p[0] - a[0]) + ny * (p[1] - a[1])) / nz, w});
                return true;
            });
            if (deadline.tick()) {
                return false;
            }
            if (hits.empty()) {
                continue;
            }
            std::sort(hits.begin(), hits.end(), [](const std::pair<double, int>& x, const std::pair<double, int>& y) { return x.first > y.first; });
            // From the top down: a sample's winding number is the sum of the crossings above it.
            size_t next = 0;
            int winding = 0;
            for (int k = grid.n[2] - 1; k >= 0; --k) {
                const double z = grid.origin[2] + k * grid.h;
                while (next < hits.size() && hits[next].first > z) {
                    winding += by_parity ? 1 : hits[next].second;
                    ++next;
                }
                if (by_parity ? (winding & 1) != 0 : winding != 0) {
                    inside[grid.index(i, j, k)] = 1;
                }
            }
        }
    }
    return true;
}

bool flood_from_border(const Grid& grid, const std::vector<float>& values, float above, std::vector<uint8_t>& reached, const Deadline& deadline)
{
    reached.assign(grid.count(), 0);
    std::vector<uint32_t> stack;
    const int nx = grid.n[0], ny = grid.n[1], nz = grid.n[2];
    auto visit = [&](int i, int j, int k) {
        const size_t at = grid.index(i, j, k);
        if (reached[at] == 0 && values[at] > above) {
            reached[at] = 1;
            stack.push_back(uint32_t(at));
        }
    };
    for (int k = 0; k < nz; ++k) {
        for (int j = 0; j < ny; ++j) {
            const bool edge_row = k == 0 || k == nz - 1 || j == 0 || j == ny - 1;
            if (edge_row) {
                for (int i = 0; i < nx; ++i) {
                    visit(i, j, k);
                }
            }
            else {
                visit(0, j, k);
                visit(nx - 1, j, k);
            }
        }
        if (deadline.expired()) {
            return false;
        }
    }
    const size_t row = size_t(nx), slab = size_t(nx) * size_t(ny);
    while (!stack.empty()) {
        const size_t at = stack.back();
        stack.pop_back();
        const int i = int(at % row), j = int((at / row) % size_t(ny)), k = int(at / slab);
        if (i > 0) {
            visit(i - 1, j, k);
        }
        if (i < nx - 1) {
            visit(i + 1, j, k);
        }
        if (j > 0) {
            visit(i, j - 1, k);
        }
        if (j < ny - 1) {
            visit(i, j + 1, k);
        }
        if (k > 0) {
            visit(i, j, k - 1);
        }
        if (k < nz - 1) {
            visit(i, j, k + 1);
        }
        if (deadline.tick()) {
            return false;
        }
    }
    return true;
}

namespace
{
/// One line of the transform: f (squared distance so far, in cells, kFar when none) and src (the
/// sample that distance leads to) of n samples become those of the lower envelope of the
/// parabolas f[p] + (q - p)^2. v and z are work arrays of n and n + 1 entries.
void envelope(const float* f, const int32_t* src, int n, float* out_f, int32_t* out_src, int* v, double* z)
{
    const double inf = std::numeric_limits<double>::infinity();
    int k = -1;
    for (int q = 0; q < n; ++q) {
        if (f[q] >= kFar) {
            continue;
        }
        const double fq = double(f[q]) + double(q) * double(q);
        while (k >= 0) {
            const int p = v[k];
            const double s = (fq - (double(f[p]) + double(p) * double(p))) / (2.0 * double(q - p));
            if (s <= z[k]) {
                --k;
                continue;
            }
            ++k;
            v[k] = q;
            z[k] = s;
            z[k + 1] = inf;
            break;
        }
        if (k < 0) {
            k = 0;
            v[0] = q;
            z[0] = -inf;
            z[1] = inf;
        }
    }
    if (k < 0) {
        for (int q = 0; q < n; ++q) {
            out_f[q] = kFar;
            out_src[q] = -1;
        }
        return;
    }
    int at = 0;
    for (int q = 0; q < n; ++q) {
        while (z[at + 1] < double(q)) {
            ++at;
        }
        const int p = v[at];
        const double d = double(q - p);
        out_f[q] = float(d * d + double(f[p]));
        out_src[q] = src[p];
    }
}
}  // namespace

bool nearest_in_set(const Grid& grid, const std::vector<uint8_t>& set, std::vector<int32_t>& source, const Deadline& deadline)
{
    const size_t total = grid.count();
    source.assign(total, -1);
    std::vector<float> dist(total, kFar);
    for (size_t i = 0; i < total; ++i) {
        if (set[i] != 0) {
            dist[i] = 0.0f;
            source[i] = int32_t(i);
        }
    }
    const size_t longest = size_t(std::max(grid.n[0], std::max(grid.n[1], grid.n[2])));
    std::vector<float> f(longest), out_f(longest);
    std::vector<int32_t> src(longest), out_src(longest);
    std::vector<int> v(longest);
    std::vector<double> z(longest + 1);
    const size_t strides[3] = {1, size_t(grid.n[0]), size_t(grid.n[0]) * size_t(grid.n[1])};
    for (int axis = 0; axis < 3; ++axis) {
        const int a1 = (axis + 1) % 3, a2 = (axis + 2) % 3;
        const int n = grid.n[axis];
        const size_t stride = strides[axis];
        for (int u = 0; u < grid.n[a1]; ++u) {
            for (int w = 0; w < grid.n[a2]; ++w) {
                const size_t start = size_t(u) * strides[a1] + size_t(w) * strides[a2];
                for (int q = 0; q < n; ++q) {
                    f[size_t(q)] = dist[start + size_t(q) * stride];
                    src[size_t(q)] = source[start + size_t(q) * stride];
                }
                envelope(f.data(), src.data(), n, out_f.data(), out_src.data(), v.data(), z.data());
                for (int q = 0; q < n; ++q) {
                    dist[start + size_t(q) * stride] = out_f[size_t(q)];
                    source[start + size_t(q) * stride] = out_src[size_t(q)];
                }
            }
            if (deadline.expired()) {
                return false;
            }
        }
    }
    return true;
}

double Field::at(double x, double y, double z) const
{
    const Grid& g = *grid;
    const double p[3] = {x, y, z};
    int cell[3];
    double t[3];
    for (int k = 0; k < 3; ++k) {
        double s = (p[k] - g.origin[k]) / g.h;
        s = std::min(std::max(s, 0.0), double(g.n[k] - 1));
        cell[k] = std::min(int(s), g.n[k] - 2);
        t[k] = s - cell[k];
    }
    const size_t row = size_t(g.n[0]), slab = row * size_t(g.n[1]);
    const float* c = values + g.index(cell[0], cell[1], cell[2]);
    const double c00 = c[0] + (c[1] - c[0]) * t[0];
    const double c10 = c[row] + (c[row + 1] - c[row]) * t[0];
    const double c01 = c[slab] + (c[slab + 1] - c[slab]) * t[0];
    const double c11 = c[slab + row] + (c[slab + row + 1] - c[slab + row]) * t[0];
    const double c0 = c00 + (c10 - c00) * t[1];
    const double c1 = c01 + (c11 - c01) * t[1];
    return c0 + (c1 - c0) * t[2];
}

}  // namespace holo_forge::mesh::voxel
