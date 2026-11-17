#include "mesh_bvh.h"

#include <algorithm>
#include <utility>

namespace holo_forge::mesh
{

namespace
{
constexpr int LEAF_SIZE = 4;

/// Spreads the low 21 bits of v so that two zero bits follow each.
inline uint64_t spread(uint64_t v)
{
    v &= 0x1FFFFFull;
    v = (v | (v << 32)) & 0x1F00000000FFFFull;
    v = (v | (v << 16)) & 0x1F0000FF0000FFull;
    v = (v | (v << 8)) & 0x100F00F00F00F00Full;
    v = (v | (v << 4)) & 0x10C30C30C30C30C3ull;
    v = (v | (v << 2)) & 0x1249249249249249ull;
    return v;
}
}  // namespace

bool TriBvh::build(const MeshData& data, const Deadline* deadline)
{
    mesh = &data;
    bvh.clear();
    const size_t count = data.triangle_count();
    if (count == 0) {
        return true;
    }
    auto late = [&]() { return deadline != nullptr && deadline->tick(); };

    // Centroids (times 3) and their bounds.
    double lo[3] = {INFINITY, INFINITY, INFINITY}, hi[3] = {-INFINITY, -INFINITY, -INFINITY};
    for (size_t t = 0; t < count; ++t) {
        const uint32_t* tri = &data.triangles[t * 3];
        for (int k = 0; k < 3; ++k) {
            const double c = double(data.positions[size_t(tri[0]) * 3 + k]) + double(data.positions[size_t(tri[1]) * 3 + k]) +
                             double(data.positions[size_t(tri[2]) * 3 + k]);
            lo[k] = std::min(lo[k], c);
            hi[k] = std::max(hi[k], c);
        }
        if (late()) {
            return false;
        }
    }
    double scale[3];
    for (int k = 0; k < 3; ++k) {
        scale[k] = hi[k] > lo[k] ? 2097151.0 / (hi[k] - lo[k]) : 0.0;
    }
    std::vector<std::pair<uint64_t, uint32_t>> keyed(count);
    for (size_t t = 0; t < count; ++t) {
        const uint32_t* tri = &data.triangles[t * 3];
        uint64_t code = 0;
        for (int k = 0; k < 3; ++k) {
            const double c = double(data.positions[size_t(tri[0]) * 3 + k]) + double(data.positions[size_t(tri[1]) * 3 + k]) +
                             double(data.positions[size_t(tri[2]) * 3 + k]);
            code |= spread(uint64_t((c - lo[k]) * scale[k])) << k;
        }
        keyed[t] = {code, uint32_t(t)};
        if (late()) {
            return false;
        }
    }
    std::sort(keyed.begin(), keyed.end());
    if (deadline != nullptr && deadline->expired()) {
        return false;
    }
    std::vector<uint64_t> codes(count);
    bvh.prims.resize(count);
    for (size_t i = 0; i < count; ++i) {
        codes[i] = keyed[i].first;
        bvh.prims[i] = int(keyed[i].second);
    }
    std::vector<std::pair<uint64_t, uint32_t>>().swap(keyed);

    // The tree: a range of sorted codes splits where their highest differing bit changes.
    struct Task
    {
        int node, first, count;
    };
    std::vector<Task> tasks;
    bvh.nodes.reserve(count / 2 + 16);
    bvh.nodes.push_back(subd::Bvh::Node());
    tasks.push_back({0, 0, int(count)});
    while (!tasks.empty()) {
        const Task task = tasks.back();
        tasks.pop_back();
        if (task.count <= LEAF_SIZE) {
            bvh.nodes[size_t(task.node)].first = task.first;
            bvh.nodes[size_t(task.node)].count = task.count;
            continue;
        }
        const uint64_t c0 = codes[size_t(task.first)], c1 = codes[size_t(task.first + task.count - 1)];
        int mid = task.first + task.count / 2;
        if (c0 != c1) {
            uint64_t diff = c0 ^ c1;
            int bit = 0;
            while (diff >>= 1) {
                ++bit;
            }
            const uint64_t split = (c1 >> bit) << bit;
            mid = int(std::lower_bound(codes.begin() + task.first, codes.begin() + task.first + task.count, split) - codes.begin());
        }
        const int left = int(bvh.nodes.size());
        bvh.nodes.push_back(subd::Bvh::Node());
        bvh.nodes.push_back(subd::Bvh::Node());
        bvh.nodes[size_t(task.node)].left = left;
        bvh.nodes[size_t(task.node)].right = left + 1;
        tasks.push_back({left, task.first, mid - task.first});
        tasks.push_back({left + 1, mid, task.first + task.count - mid});
        if (late()) {
            bvh.clear();
            return false;
        }
    }
    // Boxes, children before parents (a child always comes after its parent in nodes).
    for (size_t i = bvh.nodes.size(); i-- > 0;) {
        subd::Bvh::Node& n = bvh.nodes[i];
        if (n.left < 0) {
            for (int j = 0; j < n.count; ++j) {
                double a[3], b[3], c[3];
                corners(uint32_t(bvh.prims[size_t(n.first + j)]), a, b, c);
                n.box.add(a);
                n.box.add(b);
                n.box.add(c);
            }
        }
        else {
            n.box.add(bvh.nodes[size_t(n.left)].box);
            n.box.add(bvh.nodes[size_t(n.right)].box);
        }
        if (late()) {
            bvh.clear();
            return false;
        }
    }
    return true;
}

size_t TriBvh::memory_bytes() const
{
    return bvh.nodes.capacity() * sizeof(subd::Bvh::Node) + bvh.prims.capacity() * sizeof(int);
}

bool TriBvh::closest_hit(const double o[3], const double d[3], double tmax, uint32_t& triangle, double& t) const
{
    triangle = NONE;
    bvh.ray(o, d, tmax, [&](int prim, double& limit) {
        double a[3], b[3], c[3], tt = 0.0, b1 = 0.0, b2 = 0.0;
        corners(uint32_t(prim), a, b, c);
        if (subd::ray_triangle(o, d, a, b, c, 0.0, limit, tt, b1, b2)) {
            limit = tt;
            t = tt;
            triangle = uint32_t(prim);
        }
        return true;
    });
    return triangle != NONE;
}

}  // namespace holo_forge::mesh
