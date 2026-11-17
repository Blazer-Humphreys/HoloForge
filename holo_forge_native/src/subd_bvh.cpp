#include "subd_bvh.h"

#include <algorithm>
#include <cmath>
#include <numeric>

namespace holo_forge::subd
{

namespace
{
constexpr int LEAF_SIZE = 4;

inline void sub(const double* a, const double* b, double* r)
{
    r[0] = a[0] - b[0];
    r[1] = a[1] - b[1];
    r[2] = a[2] - b[2];
}
inline void cross(const double* a, const double* b, double* r)
{
    r[0] = a[1] * b[2] - a[2] * b[1];
    r[1] = a[2] * b[0] - a[0] * b[2];
    r[2] = a[0] * b[1] - a[1] * b[0];
}
inline double dot(const double* a, const double* b)
{
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}
}  // namespace

void Bvh::build(const std::vector<Box>& boxes)
{
    nodes.clear();
    prims.resize(boxes.size());
    std::iota(prims.begin(), prims.end(), 0);
    if (boxes.empty()) {
        return;
    }
    std::vector<double> centre(boxes.size() * 3);
    for (size_t i = 0; i < boxes.size(); ++i) {
        for (int k = 0; k < 3; ++k) {
            centre[i * 3 + size_t(k)] = 0.5 * (boxes[i].lo[k] + boxes[i].hi[k]);
        }
    }
    nodes.reserve(boxes.size() * 2 / LEAF_SIZE + 2);
    struct Task
    {
        int node, first, count;
    };
    std::vector<Task> tasks;
    nodes.push_back(Node());
    tasks.push_back({0, 0, int(boxes.size())});
    while (!tasks.empty()) {
        const Task task = tasks.back();
        tasks.pop_back();
        Box box, cbox;
        for (int i = task.first; i < task.first + task.count; ++i) {
            const int p = prims[size_t(i)];
            box.add(boxes[size_t(p)]);
            cbox.add(&centre[size_t(p) * 3]);
        }
        nodes[size_t(task.node)].box = box;
        if (task.count <= LEAF_SIZE) {
            nodes[size_t(task.node)].first = task.first;
            nodes[size_t(task.node)].count = task.count;
            continue;
        }
        int axis = 0;
        double extent = cbox.hi[0] - cbox.lo[0];
        for (int k = 1; k < 3; ++k) {
            if (cbox.hi[k] - cbox.lo[k] > extent) {
                extent = cbox.hi[k] - cbox.lo[k];
                axis = k;
            }
        }
        if (!(extent > 0.0)) {
            // All centres coincide: one leaf holds them all.
            nodes[size_t(task.node)].first = task.first;
            nodes[size_t(task.node)].count = task.count;
            continue;
        }
        const int mid = task.first + task.count / 2;
        std::nth_element(prims.begin() + task.first, prims.begin() + mid, prims.begin() + task.first + task.count,
                         [&](int a, int b) { return centre[size_t(a) * 3 + size_t(axis)] < centre[size_t(b) * 3 + size_t(axis)]; });
        const int left = int(nodes.size());
        nodes.push_back(Node());
        nodes.push_back(Node());
        nodes[size_t(task.node)].left = left;
        nodes[size_t(task.node)].right = left + 1;
        tasks.push_back({left, task.first, mid - task.first});
        tasks.push_back({left + 1, mid, task.first + task.count - mid});
    }
}

bool ray_triangle(const double* o, const double* d, const double* a, const double* b, const double* c, double tmin,
                  double tmax, double& t, double& b1, double& b2)
{
    double e1[3], e2[3], pv[3], tv[3], qv[3];
    sub(b, a, e1);
    sub(c, a, e2);
    cross(d, e2, pv);
    const double det = dot(e1, pv);
    const double scale = std::sqrt(dot(e1, e1) * dot(e2, e2) * dot(d, d));
    if (std::fabs(det) <= 1e-300 || std::fabs(det) <= 1e-15 * scale) {
        return false;
    }
    const double inv = 1.0 / det;
    sub(o, a, tv);
    const double u = dot(tv, pv) * inv;
    const double eps = 1e-12;
    if (u < -eps || u > 1.0 + eps) {
        return false;
    }
    cross(tv, e1, qv);
    const double v = dot(d, qv) * inv;
    if (v < -eps || u + v > 1.0 + eps) {
        return false;
    }
    const double tt = dot(e2, qv) * inv;
    if (!(tt > tmin) || !(tt < tmax)) {
        return false;
    }
    t = tt;
    b1 = u;
    b2 = v;
    return true;
}

double closest_on_triangle(const double* p, const double* a, const double* b, const double* c, double* out,
                           double& b1, double& b2)
{
    double ab[3], ac[3], ap[3];
    sub(b, a, ab);
    sub(c, a, ac);
    sub(p, a, ap);
    const double d1 = dot(ab, ap), d2 = dot(ac, ap);
    auto finish = [&](double v, double w) {
        b1 = v;
        b2 = w;
        for (int k = 0; k < 3; ++k) {
            out[k] = a[k] + v * ab[k] + w * ac[k];
        }
        double r[3];
        sub(p, out, r);
        return dot(r, r);
    };
    if (d1 <= 0.0 && d2 <= 0.0) {
        return finish(0.0, 0.0);
    }
    double bp[3];
    sub(p, b, bp);
    const double d3 = dot(ab, bp), d4 = dot(ac, bp);
    if (d3 >= 0.0 && d4 <= d3) {
        return finish(1.0, 0.0);
    }
    const double vc = d1 * d4 - d3 * d2;
    if (vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0) {
        const double v = d1 / (d1 - d3);
        return finish(v, 0.0);
    }
    double cp[3];
    sub(p, c, cp);
    const double d5 = dot(ab, cp), d6 = dot(ac, cp);
    if (d6 >= 0.0 && d5 <= d6) {
        return finish(0.0, 1.0);
    }
    const double vb = d5 * d2 - d1 * d6;
    if (vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0) {
        const double w = d2 / (d2 - d6);
        return finish(0.0, w);
    }
    const double va = d3 * d6 - d5 * d4;
    if (va <= 0.0 && (d4 - d3) >= 0.0 && (d5 - d6) >= 0.0) {
        const double w = (d4 - d3) / ((d4 - d3) + (d5 - d6));
        return finish(1.0 - w, w);
    }
    const double denom = 1.0 / (va + vb + vc);
    return finish(vb * denom, vc * denom);
}

namespace
{
/// The points where triangle T meets a plane, given its corners' distances d to it: the corners
/// on the plane (d == 0) and the crossings of edges whose ends lie on opposite sides.
int plane_points(const double* const T[3], const double d[3], double out[6][3])
{
    int count = 0;
    for (int i = 0; i < 3; ++i) {
        if (d[i] == 0.0) {
            for (int k = 0; k < 3; ++k) {
                out[count][k] = T[i][k];
            }
            ++count;
        }
    }
    for (int i = 0; i < 3; ++i) {
        const int j = (i + 1) % 3;
        if ((d[i] < 0.0 && d[j] > 0.0) || (d[i] > 0.0 && d[j] < 0.0)) {
            const double s = d[i] / (d[i] - d[j]);
            for (int k = 0; k < 3; ++k) {
                out[count][k] = T[i][k] + s * (T[j][k] - T[i][k]);
            }
            ++count;
        }
    }
    return count;
}

/// Closed 2D segment test (touching counts), eps a distance.
bool segments_touch_2d(const double* p, const double* q, const double* a, const double* b, double eps)
{
    auto orient = [](const double* x, const double* y, const double* z) {
        return (y[0] - x[0]) * (z[1] - x[1]) - (y[1] - x[1]) * (z[0] - x[0]);
    };
    auto on_seg = [&](const double* x, const double* y, const double* z) {
        const double dx = y[0] - x[0], dy = y[1] - x[1];
        const double l2 = dx * dx + dy * dy;
        if (l2 <= 0.0) {
            return std::hypot(z[0] - x[0], z[1] - x[1]) <= eps;
        }
        const double t = std::clamp(((z[0] - x[0]) * dx + (z[1] - x[1]) * dy) / l2, 0.0, 1.0);
        return std::hypot(x[0] + t * dx - z[0], x[1] + t * dy - z[1]) <= eps;
    };
    const double lpq = std::hypot(q[0] - p[0], q[1] - p[1]);
    const double lab = std::hypot(b[0] - a[0], b[1] - a[1]);
    const double o1 = orient(p, q, a), o2 = orient(p, q, b);
    const double o3 = orient(a, b, p), o4 = orient(a, b, q);
    const double t1 = eps * lpq, t2 = eps * lab;
    const int s1 = o1 > t1 ? 1 : (o1 < -t1 ? -1 : 0);
    const int s2 = o2 > t1 ? 1 : (o2 < -t1 ? -1 : 0);
    const int s3 = o3 > t2 ? 1 : (o3 < -t2 ? -1 : 0);
    const int s4 = o4 > t2 ? 1 : (o4 < -t2 ? -1 : 0);
    if (s1 * s2 < 0 && s3 * s4 < 0) {
        return true;
    }
    return (s1 == 0 && on_seg(p, q, a)) || (s2 == 0 && on_seg(p, q, b)) || (s3 == 0 && on_seg(a, b, p)) ||
           (s4 == 0 && on_seg(a, b, q));
}

bool point_in_tri_2d(const double* p, const double* a, const double* b, const double* c)
{
    const double d1 = (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0]);
    const double d2 = (c[0] - b[0]) * (p[1] - b[1]) - (c[1] - b[1]) * (p[0] - b[0]);
    const double d3 = (a[0] - c[0]) * (p[1] - c[1]) - (a[1] - c[1]) * (p[0] - c[0]);
    const bool neg = d1 < 0.0 || d2 < 0.0 || d3 < 0.0;
    const bool pos = d1 > 0.0 || d2 > 0.0 || d3 > 0.0;
    return !(neg && pos);
}
}  // namespace

bool triangles_cross(const double* a0, const double* a1, const double* a2, const double* b0, const double* b1,
                     const double* b2, double eps)
{
    const double* A[3] = {a0, a1, a2};
    const double* B[3] = {b0, b1, b2};
    double na[3], nb[3], e1[3], e2[3];
    sub(a1, a0, e1);
    sub(a2, a0, e2);
    cross(e1, e2, na);
    sub(b1, b0, e1);
    sub(b2, b0, e2);
    cross(e1, e2, nb);
    const double la = std::sqrt(dot(na, na)), lb = std::sqrt(dot(nb, nb));
    if (!(la > 0.0) || !(lb > 0.0)) {
        return false;  // degenerate triangles are reported as degenerate faces instead
    }
    for (int k = 0; k < 3; ++k) {
        na[k] /= la;
        nb[k] /= lb;
    }
    double da[3], db[3], t[3];
    for (int i = 0; i < 3; ++i) {
        sub(A[i], b0, t);
        da[i] = dot(nb, t);
        if (std::fabs(da[i]) <= eps) {
            da[i] = 0.0;
        }
        sub(B[i], a0, t);
        db[i] = dot(na, t);
        if (std::fabs(db[i]) <= eps) {
            db[i] = 0.0;
        }
    }
    auto one_side = [](const double d[3]) {
        return (d[0] > 0.0 && d[1] > 0.0 && d[2] > 0.0) || (d[0] < 0.0 && d[1] < 0.0 && d[2] < 0.0);
    };
    if (one_side(da) || one_side(db)) {
        return false;
    }
    if (da[0] == 0.0 && da[1] == 0.0 && da[2] == 0.0) {
        // Coplanar: drop the dominant normal axis and test in 2D.
        int drop = 0;
        for (int k = 1; k < 3; ++k) {
            if (std::fabs(nb[k]) > std::fabs(nb[drop])) {
                drop = k;
            }
        }
        const int x = (drop + 1) % 3, y = (drop + 2) % 3;
        double P[3][2], R[3][2];
        for (int i = 0; i < 3; ++i) {
            P[i][0] = A[i][x];
            P[i][1] = A[i][y];
            R[i][0] = B[i][x];
            R[i][1] = B[i][y];
        }
        for (int i = 0; i < 3; ++i) {
            for (int j = 0; j < 3; ++j) {
                if (segments_touch_2d(P[i], P[(i + 1) % 3], R[j], R[(j + 1) % 3], eps)) {
                    return true;
                }
            }
        }
        return point_in_tri_2d(P[0], R[0], R[1], R[2]) || point_in_tri_2d(R[0], P[0], P[1], P[2]);
    }
    // Each triangle meets the plane of the other: compare their spans along the common line.
    double D[3];
    cross(na, nb, D);
    const double ld = std::sqrt(dot(D, D));
    if (!(ld > 0.0)) {
        return false;
    }
    double pa[6][3], pb[6][3];
    const int ca = plane_points(A, da, pa);
    const int cb = plane_points(B, db, pb);
    if (ca == 0 || cb == 0) {
        return false;
    }
    double amin = INFINITY, amax = -INFINITY, bmin = INFINITY, bmax = -INFINITY;
    for (int i = 0; i < ca; ++i) {
        const double s = dot(pa[i], D) / ld;
        amin = std::min(amin, s);
        amax = std::max(amax, s);
    }
    for (int i = 0; i < cb; ++i) {
        const double s = dot(pb[i], D) / ld;
        bmin = std::min(bmin, s);
        bmax = std::max(bmax, s);
    }
    return std::max(amin, bmin) <= std::min(amax, bmax) + eps;
}

}  // namespace holo_forge::subd
