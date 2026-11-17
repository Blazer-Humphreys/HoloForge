// Face group tools of the Mesh workspace (work order 3.2.5 to 3.2.7): Generate Face Groups
// (fast: by angle; accurate: by plane, cylinder and sphere fits), Combine Face Groups and Create
// Face Group (regroup), and the primitive fits themselves (fit_primitive). All our own code.

#include "cad_mesh.h"
#include "mesh_pmp.h"

#include <godot_cpp/variant/packed_string_array.hpp>

#include <Eigen/Dense>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <exception>
#include <limits>
#include <queue>
#include <unordered_set>

using namespace godot;

namespace holo_forge
{

namespace mesh
{
namespace
{
constexpr double kInf = std::numeric_limits<double>::infinity();

// (rms and max: distances of the triangles' corners from the primitive. max_middle: the largest
// distance of a triangle's middle from it. Corners alone can lie on a primitive the surface is
// not: the 8 corners of a cube lie on a sphere and on a cylinder.)
struct PlaneFit
{
    bool valid = false;
    V3 point, normal;
    double rms = kInf, max = kInf, max_middle = kInf;
};
struct CylinderFit
{
    bool valid = false;
    V3 point, axis;
    double radius = 0.0, rms = kInf, max = kInf, max_middle = kInf;
};
struct SphereFit
{
    bool valid = false;
    V3 center;
    double radius = 0.0, rms = kInf, max = kInf, max_middle = kInf;
};
struct PrimitiveFit
{
    PlaneFit plane;
    CylinderFit cylinder;
    SphereFit sphere;
    size_t points = 0;
    double area = 0.0;
    double size = 0.0;  // the largest distance of a corner from the corners' mean
};

/// Marks vertices without clearing an array of V entries for every fit.
struct FitScratch
{
    std::vector<uint32_t> stamp;
    uint32_t epoch = 0;
    std::vector<V3> points;
    explicit FitScratch(size_t vertices) : stamp(vertices, 0)
    {
    }
};

Eigen::Matrix3d outer(const V3& a, const V3& b)
{
    Eigen::Matrix3d m;
    m << a.x * b.x, a.x * b.y, a.x * b.z, a.y * b.x, a.y * b.y, a.y * b.z, a.z * b.x, a.z * b.y, a.z * b.z;
    return m;
}

inline V3 from_eigen(const Eigen::Vector3d& v)
{
    return {v[0], v[1], v[2]};
}

void frame_across(const V3& axis, V3& x, V3& y)
{
    x = normalized(cross(axis, std::fabs(axis.x) < 0.9 ? V3(1, 0, 0) : V3(0, 1, 0)));
    y = cross(axis, x);
}

/// Best plane, cylinder and sphere of the corners of some triangles (work order 3.4.2 step 1).
/// The errors are distances of those corners from the primitive.
PrimitiveFit fit_primitives(const MeshData& m, const uint32_t* tris, size_t count, FitScratch& scratch)
{
    PrimitiveFit fit;
    if (count == 0) {
        return fit;
    }
    // The corners, each once; and the area sums.
    ++scratch.epoch;
    std::vector<V3>& pts = scratch.points;
    pts.clear();
    V3 mean, normal_sum, area_centre;
    Eigen::Matrix3d normal_cov = Eigen::Matrix3d::Zero();
    for (size_t i = 0; i < count; ++i) {
        const size_t t = tris[i];
        V3 corner[3];
        for (int k = 0; k < 3; ++k) {
            const uint32_t v = m.triangles[t * 3 + size_t(k)];
            corner[k] = point_of(m, v);
            if (scratch.stamp[v] != scratch.epoch) {
                scratch.stamp[v] = scratch.epoch;
                pts.push_back(corner[k]);
                mean += corner[k];
            }
        }
        const V3 n = cross(corner[1] - corner[0], corner[2] - corner[0]);
        const double twice = length(n);
        if (twice > 0.0) {
            const double area = 0.5 * twice;
            fit.area += area;
            normal_sum += n * 0.5;
            area_centre += (corner[0] + corner[1] + corner[2]) * (area / 3.0);
            normal_cov += outer(n, n) * (area / (twice * twice));
        }
    }
    const size_t N = pts.size();
    fit.points = N;
    mean = mean * (1.0 / double(N));
    const V3 centre = fit.area > 0.0 ? area_centre * (1.0 / fit.area) : mean;
    double scale = 0.0;
    for (const V3& p : pts) {
        scale = std::max(scale, length(p - mean));
    }
    fit.size = scale;
    if (N < 3 || !(scale > 0.0)) {
        return fit;
    }
    auto finish = [&](double sum2, double worst, double& rms, double& max) {
        rms = std::sqrt(sum2 / double(N));
        max = worst;
    };

    // --- Plane: the surface's second moments about its centre (area weighted), else the points'.
    {
        Eigen::Matrix3d cov = Eigen::Matrix3d::Zero();
        if (fit.area > 0.0) {
            for (size_t i = 0; i < count; ++i) {
                const size_t t = tris[i];
                const V3 a = point_of(m, m.triangles[t * 3]) - centre, b = point_of(m, m.triangles[t * 3 + 1]) - centre, c = point_of(m, m.triangles[t * 3 + 2]) - centre;
                const double w = 0.5 * length(cross(b - a, c - a)) / 12.0;
                const V3 s = a + b + c;
                cov += (outer(s, s) + outer(a, a) + outer(b, b) + outer(c, c)) * w;
            }
        }
        else {
            for (const V3& p : pts) {
                cov += outer(p - centre, p - centre);
            }
        }
        Eigen::SelfAdjointEigenSolver<Eigen::Matrix3d> solver(cov);
        // (Corners on one line span no plane.)
        if (solver.info() == Eigen::Success && solver.eigenvalues()[1] > 1e-12 * solver.eigenvalues()[2]) {
            V3 n = normalized(from_eigen(solver.eigenvectors().col(0)));
            if (dot(n, normal_sum) < 0.0) {
                n = n * -1.0;
            }
            double sum2 = 0.0, worst = 0.0;
            for (const V3& p : pts) {
                const double d = std::fabs(dot(p - centre, n));
                sum2 += d * d;
                worst = std::max(worst, d);
            }
            fit.plane.valid = true;
            fit.plane.point = centre;
            fit.plane.normal = n;
            finish(sum2, worst, fit.plane.rms, fit.plane.max);
        }
    }

    // The fits below run on at most this many corners (evenly spaced); the errors on all.
    const size_t sample = std::min<size_t>(N, 4000);
    auto sample_point = [&](size_t i) -> const V3& { return pts[sample == N ? i : i * N / sample]; };

    // --- Cylinder: the axis is the direction the normals have least of; then a circle in the
    // plane across it; then 5 Gauss-Newton steps on axis, centre and radius together.
    if (fit.area > 0.0) {
        Eigen::SelfAdjointEigenSolver<Eigen::Matrix3d> solver(normal_cov);
        const bool round = solver.info() == Eigen::Success && solver.eigenvalues()[1] > 1e-9 * solver.eigenvalues()[2];
        if (round) {
            V3 d = normalized(from_eigen(solver.eigenvectors().col(0)));
            V3 x, y;
            frame_across(d, x, y);
            // Circle (algebraic): u2 + v2 + D u + E v + F = 0.
            Eigen::Matrix3d A = Eigen::Matrix3d::Zero();
            Eigen::Vector3d b = Eigen::Vector3d::Zero();
            for (size_t i = 0; i < sample; ++i) {
                const V3 q = sample_point(i) - mean;
                const double u = dot(q, x) / scale, v = dot(q, y) / scale;
                const Eigen::Vector3d row(u, v, 1.0);
                A += row * row.transpose();
                b -= row * (u * u + v * v);
            }
            Eigen::SelfAdjointEigenSolver<Eigen::Matrix3d> circle(A);
            if (circle.info() == Eigen::Success && circle.eigenvalues()[0] > 1e-13 * circle.eigenvalues()[2]) {
                const Eigen::Vector3d s = A.ldlt().solve(b);
                const double cu = -0.5 * s[0], cv = -0.5 * s[1];
                const double r2 = cu * cu + cv * cv - s[2];
                if (r2 > 0.0 && std::isfinite(r2)) {
                    V3 c = mean + x * (cu * scale) + y * (cv * scale);
                    double r = std::sqrt(r2) * scale;
                    auto cost = [&](const V3& cc, const V3& dd, double rr, std::vector<double>* res) {
                        double sum = 0.0;
                        for (size_t i = 0; i < sample; ++i) {
                            const V3 q = sample_point(i) - cc;
                            const double e = length(q - dd * dot(q, dd)) - rr;
                            if (res != nullptr) {
                                (*res)[i] = e;
                            }
                            sum += e * e;
                        }
                        return sum;
                    };
                    std::vector<double> r0(sample), r1(sample);
                    for (int iter = 0; iter < 5; ++iter) {
                        // The axis point nearest the corners' mean (so turning the axis turns it there).
                        c = c + d * dot(mean - c, d);
                        frame_across(d, x, y);
                        const double cost0 = cost(c, d, r, &r0);
                        const double h = 1e-6 * scale, ha = 1e-6;
                        Eigen::Matrix<double, Eigen::Dynamic, 5> J(Eigen::Index(sample), 5);
                        const V3 moved[4] = {c + x * h, c + y * h, c, c};
                        const V3 turned[4] = {d, d, normalized(d + x * ha), normalized(d + y * ha)};
                        for (int p = 0; p < 4; ++p) {
                            cost(moved[p], turned[p], r, &r1);
                            const double step = p < 2 ? h : ha;
                            for (size_t i = 0; i < sample; ++i) {
                                J(Eigen::Index(i), p) = (r1[i] - r0[i]) / step;
                            }
                        }
                        for (size_t i = 0; i < sample; ++i) {
                            J(Eigen::Index(i), 4) = -1.0;
                        }
                        Eigen::Map<Eigen::VectorXd> res(r0.data(), Eigen::Index(sample));
                        Eigen::Matrix<double, 5, 5> JtJ = J.transpose() * J;
                        const Eigen::Matrix<double, 5, 1> g = J.transpose() * res;
                        for (int p = 0; p < 5; ++p) {
                            JtJ(p, p) *= 1.0 + 1e-9;
                        }
                        const Eigen::Matrix<double, 5, 1> delta = JtJ.ldlt().solve(-g);
                        if (!delta.allFinite()) {
                            break;
                        }
                        const V3 c2 = c + x * delta[0] + y * delta[1];
                        const V3 d2 = normalized(d + x * delta[2] + y * delta[3]);
                        const double r2n = r + delta[4];
                        if (!(r2n > 0.0) || !(cost(c2, d2, r2n, nullptr) < cost0)) {
                            break;
                        }
                        c = c2;
                        d = d2;
                        r = r2n;
                    }
                    c = c + d * dot(mean - c, d);
                    double sum2 = 0.0, worst = 0.0;
                    for (const V3& p : pts) {
                        const V3 q = p - c;
                        const double e = std::fabs(length(q - d * dot(q, d)) - r);
                        sum2 += e * e;
                        worst = std::max(worst, e);
                    }
                    if (std::isfinite(worst) && std::isfinite(r) && r < 1e6 * scale) {
                        fit.cylinder.valid = true;
                        fit.cylinder.point = c;
                        fit.cylinder.axis = d;
                        fit.cylinder.radius = r;
                        finish(sum2, worst, fit.cylinder.rms, fit.cylinder.max);
                    }
                }
            }
        }
    }

    // --- Sphere: algebraic (|q|2 = 2 c.q + k), then Gauss-Newton on centre and radius.
    {
        Eigen::Matrix4d A = Eigen::Matrix4d::Zero();
        Eigen::Vector4d b = Eigen::Vector4d::Zero();
        for (size_t i = 0; i < sample; ++i) {
            const V3 q = (sample_point(i) - mean) * (1.0 / scale);
            const Eigen::Vector4d row(2.0 * q.x, 2.0 * q.y, 2.0 * q.z, 1.0);
            A += row * row.transpose();
            b += row * dot(q, q);
        }
        Eigen::SelfAdjointEigenSolver<Eigen::Matrix4d> solver(A);
        if (solver.info() == Eigen::Success && solver.eigenvalues()[0] > 1e-13 * solver.eigenvalues()[3]) {
            const Eigen::Vector4d s = A.ldlt().solve(b);
            const double r2 = s[3] + s[0] * s[0] + s[1] * s[1] + s[2] * s[2];
            if (r2 > 0.0 && std::isfinite(r2)) {
                V3 c = mean + V3(s[0], s[1], s[2]) * scale;
                double r = std::sqrt(r2) * scale;
                for (int iter = 0; iter < 5; ++iter) {
                    Eigen::Matrix4d JtJ = Eigen::Matrix4d::Zero();
                    Eigen::Vector4d g = Eigen::Vector4d::Zero();
                    double cost0 = 0.0;
                    for (size_t i = 0; i < sample; ++i) {
                        const V3 q = sample_point(i) - c;
                        const double l = length(q);
                        if (!(l > 0.0)) {
                            continue;
                        }
                        const double e = l - r;
                        const Eigen::Vector4d row(-q.x / l, -q.y / l, -q.z / l, -1.0);
                        JtJ += row * row.transpose();
                        g += row * e;
                        cost0 += e * e;
                    }
                    for (int p = 0; p < 4; ++p) {
                        JtJ(p, p) *= 1.0 + 1e-9;
                    }
                    const Eigen::Vector4d delta = JtJ.ldlt().solve(-g);
                    if (!delta.allFinite()) {
                        break;
                    }
                    const V3 c2 = c + V3(delta[0], delta[1], delta[2]);
                    const double r2n = r + delta[3];
                    double cost1 = 0.0;
                    for (size_t i = 0; i < sample; ++i) {
                        const double e = length(sample_point(i) - c2) - r2n;
                        cost1 += e * e;
                    }
                    if (!(r2n > 0.0) || !(cost1 < cost0)) {
                        break;
                    }
                    c = c2;
                    r = r2n;
                }
                double sum2 = 0.0, worst = 0.0;
                for (const V3& p : pts) {
                    const double e = std::fabs(length(p - c) - r);
                    sum2 += e * e;
                    worst = std::max(worst, e);
                }
                if (std::isfinite(worst) && std::isfinite(r) && r < 1e6 * scale) {
                    fit.sphere.valid = true;
                    fit.sphere.center = c;
                    fit.sphere.radius = r;
                    finish(sum2, worst, fit.sphere.rms, fit.sphere.max);
                }
            }
        }
    }
    // The triangles' middles against each primitive.
    fit.plane.max_middle = fit.plane.valid ? 0.0 : kInf;
    fit.cylinder.max_middle = fit.cylinder.valid ? 0.0 : kInf;
    fit.sphere.max_middle = fit.sphere.valid ? 0.0 : kInf;
    for (size_t i = 0; i < count; ++i) {
        const size_t t = tris[i];
        const V3 middle = (point_of(m, m.triangles[t * 3]) + point_of(m, m.triangles[t * 3 + 1]) + point_of(m, m.triangles[t * 3 + 2])) * (1.0 / 3.0);
        if (fit.plane.valid) {
            fit.plane.max_middle = std::max(fit.plane.max_middle, std::fabs(dot(middle - fit.plane.point, fit.plane.normal)));
        }
        if (fit.cylinder.valid) {
            const V3 q = middle - fit.cylinder.point;
            fit.cylinder.max_middle = std::max(fit.cylinder.max_middle, std::fabs(length(q - fit.cylinder.axis * dot(q, fit.cylinder.axis)) - fit.cylinder.radius));
        }
        if (fit.sphere.valid) {
            fit.sphere.max_middle = std::max(fit.sphere.max_middle, std::fabs(length(middle - fit.sphere.center) - fit.sphere.radius));
        }
    }
    return fit;
}

/// One fitted primitive, as the group growing uses it.
struct Primitive
{
    int kind = -1;  // 0 plane, 1 cylinder, 2 sphere
    V3 point, axis;
    double radius = 0.0;

    double distance(const V3& p) const
    {
        const V3 q = p - point;
        if (kind == 0) {
            return std::fabs(dot(q, axis));
        }
        if (kind == 1) {
            return std::fabs(length(q - axis * dot(q, axis)) - radius);
        }
        return std::fabs(length(q) - radius);
    }
    /// Along the primitive's normal at p (either sense).
    V3 normal(const V3& p) const
    {
        const V3 q = p - point;
        if (kind == 0) {
            return axis;
        }
        if (kind == 1) {
            return normalized(q - axis * dot(q, axis));
        }
        return normalized(q);
    }
};

/// The simplest primitive within the tolerance: plane, then cylinder, then sphere. kind -1: none.
Primitive pick_primitive(const PrimitiveFit& fit, double tolerance)
{
    Primitive p;
    if (fit.plane.valid && fit.plane.max <= tolerance) {
        p.kind = 0;
        p.point = fit.plane.point;
        p.axis = fit.plane.normal;
    }
    else if (fit.cylinder.valid && fit.cylinder.max <= tolerance) {
        p.kind = 1;
        p.point = fit.cylinder.point;
        p.axis = fit.cylinder.axis;
        p.radius = fit.cylinder.radius;
    }
    else if (fit.sphere.valid && fit.sphere.max <= tolerance) {
        p.kind = 2;
        p.point = fit.sphere.center;
        p.radius = fit.sphere.radius;
    }
    return p;
}

struct GroupOptions
{
    bool accurate = true;
    double angle_deg = 20.0;
    double tolerance = 0.0;
    int64_t min_size = 10;
};

struct GroupStats
{
    size_t groups = 0, planes = 0, cylinders = 0, spheres = 0, freeform = 0, merged_small = 0;
};

/// Flood fill over the triangles `allowed` lets through (null: all), across edges of two
/// triangles whose normals differ by less than the angle. label[t] gets ids from `next` on,
/// in order of each region's smallest triangle. False when the deadline passed.
bool flood_by_angle(State& state, double angle_deg, const std::vector<uint8_t>* allowed, std::vector<uint32_t>& label, uint32_t& next, const std::vector<V3>& normals,
                    const Deadline& deadline)
{
    const MeshData& m = state.data;
    const Topology* topo = topology_of(state, &deadline);
    if (topo == nullptr) {
        return false;
    }
    const double least = std::cos(std::min(std::max(angle_deg, 0.0), 180.0) * M_PI / 180.0);
    const size_t T = m.triangle_count();
    std::vector<uint32_t> stack;
    for (size_t seed = 0; seed < T; ++seed) {
        if (label[seed] != NONE || (allowed != nullptr && !(*allowed)[seed])) {
            continue;
        }
        const uint32_t id = next++;
        label[seed] = id;
        stack.push_back(uint32_t(seed));
        while (!stack.empty()) {
            const uint32_t t = stack.back();
            stack.pop_back();
            for (uint32_t k = 0; k < 3; ++k) {
                const uint32_t he = t * 3 + k;
                if (topo->he_edge[he] == NONE) {
                    continue;
                }
                const uint32_t other = topo->twin(he);
                if (other == NONE) {
                    continue;
                }
                const uint32_t t2 = other / 3;
                if (label[t2] != NONE || (allowed != nullptr && !(*allowed)[t2])) {
                    continue;
                }
                // Neighbours that run the edge the same way face opposite ways.
                const double sign = m.triangles[other] == m.triangles[he] ? -1.0 : 1.0;
                const double c = sign * dot(normals[t], normals[t2]);
                const bool flat = dot(normals[t], normals[t]) == 0.0 || dot(normals[t2], normals[t2]) == 0.0;
                if (flat || c > least) {
                    label[t2] = id;
                    stack.push_back(t2);
                }
            }
            if (deadline.tick()) {
                return false;
            }
        }
    }
    return true;
}

/// Groups of fewer than min_size triangles join the neighbour (across an edge) whose mean
/// normal is closest, when it is within limit_deg of their own: a small flat face that meets its
/// neighbours at a real corner (a 2-triangle side of a machined part) stays a group; small
/// patches of noise join what surrounds them. False when the deadline passed.
bool merge_small(State& state, std::vector<uint32_t>& label, uint32_t groups, int64_t min_size, double limit_deg, const std::vector<V3>& normals, size_t& merged,
                 const Deadline& deadline)
{
    const double least = std::cos(std::min(std::max(limit_deg, 0.0), 180.0) * M_PI / 180.0);
    const MeshData& m = state.data;
    const Topology* topo = topology_of(state, &deadline);
    if (topo == nullptr) {
        return false;
    }
    const size_t T = m.triangle_count();
    if (min_size <= 1 || groups < 2) {
        return true;
    }
    std::vector<uint32_t> parent(groups);
    for (uint32_t g = 0; g < groups; ++g) {
        parent[g] = g;
    }
    auto find = [&](uint32_t g) {
        while (parent[g] != g) {
            parent[g] = parent[parent[g]];
            g = parent[g];
        }
        return g;
    };
    std::vector<int64_t> size(groups, 0);
    std::vector<V3> sum(groups);
    for (size_t t = 0; t < T; ++t) {
        ++size[label[t]];
        sum[label[t]] += normals[t] * (0.5 * length(triangle_cross(m, t)));
    }
    for (int round = 0; round < 64; ++round) {
        std::vector<uint32_t> best(groups, NONE);
        std::vector<double> score(groups, -kInf);
        bool any_small = false;
        for (size_t e = 0; e < topo->edge_count(); ++e) {
            const uint32_t first = topo->edge_first[e], last = topo->edge_first[e + 1];
            for (uint32_t i = first; i + 1 < last; ++i) {
                const uint32_t a = find(label[topo->edge_hes[i] / 3]), b = find(label[topo->edge_hes[size_t(i) + 1] / 3]);
                if (a == b) {
                    continue;
                }
                const double s = dot(normalized(sum[a]), normalized(sum[b]));
                if (s < least) {
                    continue;
                }
                for (int side = 0; side < 2; ++side) {
                    const uint32_t g = side == 0 ? a : b, other = side == 0 ? b : a;
                    if (size[g] < min_size && (s > score[g] || (s == score[g] && other < best[g]))) {
                        score[g] = s;
                        best[g] = other;
                        any_small = true;
                    }
                }
            }
            if (deadline.tick()) {
                return false;
            }
        }
        if (!any_small) {
            break;
        }
        bool joined = false;
        for (uint32_t g = 0; g < groups; ++g) {
            if (parent[g] != g || best[g] == NONE || size[g] >= min_size) {
                continue;
            }
            const uint32_t into = find(best[g]);
            if (into == g) {
                continue;
            }
            // The lower id stays (names follow the smallest triangle).
            const uint32_t keep = std::min(g, into), gone = std::max(g, into);
            parent[gone] = keep;
            size[keep] += size[gone];
            sum[keep] += sum[gone];
            ++merged;
            joined = true;
        }
        if (!joined) {
            break;
        }
    }
    for (size_t t = 0; t < T; ++t) {
        label[t] = find(label[t]);
    }
    return true;
}

bool generate(State& state, const GroupOptions& opt, const Deadline& deadline, MeshData& out, GroupStats& stats, std::string& error)
{
    const char* hint = "Use the Fast method, or Reduce the body first.";
    const std::string late = timed_out_text("Generate Face Groups", deadline.limit(), hint);
    const MeshData& m = state.data;
    const size_t T = m.triangle_count();
    const Topology* topo = topology_of(state, &deadline);
    if (topo == nullptr) {
        error = late;
        return false;
    }
    std::vector<V3> normals(T);
    for (size_t t = 0; t < T; ++t) {
        normals[t] = normalized(triangle_cross(m, t));
    }
    std::vector<uint32_t> label(T, NONE);
    std::vector<int> kinds;  // accurate: what each region fits (0 plane, 1 cylinder, 2 sphere, -1 nothing)
    uint32_t count = 0;
    if (!opt.accurate) {
        if (!flood_by_angle(state, opt.angle_deg, nullptr, label, count, normals, deadline)) {
            error = late;
            return false;
        }
    }
    else {
        // Start from the angle regions at 40 degrees; fit each; split what fits nothing at 10
        // degrees and fit again.
        if (!flood_by_angle(state, 40.0, nullptr, label, count, normals, deadline)) {
            error = late;
            return false;
        }
        FitScratch scratch(m.vertex_count());
        std::vector<Primitive> primitive;  // per region; kind -1: fits nothing
        auto fit_regions = [&](uint32_t first_region, uint32_t last_region) {
            // Triangles of the regions first_region .. last_region - 1, bucketed.
            const uint32_t n = last_region - first_region;
            std::vector<uint32_t> start(size_t(n) + 1, 0);
            for (size_t t = 0; t < T; ++t) {
                if (label[t] >= first_region && label[t] < last_region) {
                    ++start[label[t] - first_region + 1];
                }
            }
            for (uint32_t r = 0; r < n; ++r) {
                start[r + 1] += start[r];
            }
            std::vector<uint32_t> tris(start[n]);
            std::vector<uint32_t> cursor(start.begin(), start.end() - 1);
            for (size_t t = 0; t < T; ++t) {
                if (label[t] >= first_region && label[t] < last_region) {
                    tris[cursor[label[t] - first_region]++] = uint32_t(t);
                }
            }
            primitive.resize(last_region);
            for (uint32_t r = 0; r < n; ++r) {
                const PrimitiveFit fit = fit_primitives(m, tris.data() + start[r], start[r + 1] - start[r], scratch);
                primitive[first_region + r] = pick_primitive(fit, opt.tolerance);
                if (deadline.expired()) {
                    return false;
                }
            }
            return true;
        };
        if (!fit_regions(0, count)) {
            error = late;
            return false;
        }
        const uint32_t coarse = count;
        std::vector<uint8_t> loose(T, 0);
        bool any_loose = false;
        for (size_t t = 0; t < T; ++t) {
            if (primitive[label[t]].kind < 0) {
                loose[t] = 1;
                label[t] = NONE;
                any_loose = true;
            }
        }
        if (any_loose) {
            if (!flood_by_angle(state, 10.0, &loose, label, count, normals, deadline) || !fit_regions(coarse, count)) {
                error = late;
                return false;
            }
            // Regions that fit a primitive grow, triangle by triangle and best fit first, into
            // neighbours that still fit nothing and lie on the primitive within the tolerance.
            struct Item
            {
                double error;
                uint32_t triangle, region;
                bool operator<(const Item& o) const
                {
                    return error != o.error ? error > o.error : (triangle != o.triangle ? triangle > o.triangle : region > o.region);
                }
            };
            std::priority_queue<Item> queue;
            const double least = std::cos(60.0 * M_PI / 180.0);
            auto offer = [&](uint32_t t, uint32_t region) {
                const Primitive& p = primitive[region];
                double worst = 0.0;
                V3 centre;
                for (int k = 0; k < 3; ++k) {
                    const V3 q = point_of(m, m.triangles[size_t(t) * 3 + size_t(k)]);
                    worst = std::max(worst, p.distance(q));
                    centre += q * (1.0 / 3.0);
                }
                if (worst <= opt.tolerance && std::fabs(dot(p.normal(centre), normals[t])) >= least) {
                    queue.push({worst, t, region});
                }
            };
            auto offer_neighbours = [&](uint32_t t, uint32_t region) {
                for (uint32_t k = 0; k < 3; ++k) {
                    const uint32_t other = topo->he_edge[t * 3 + k] == NONE ? NONE : topo->twin(t * 3 + k);
                    if (other != NONE && primitive[label[other / 3]].kind < 0) {
                        offer(other / 3, region);
                    }
                }
            };
            for (size_t t = 0; t < T; ++t) {
                if (primitive[label[t]].kind >= 0) {
                    offer_neighbours(uint32_t(t), label[t]);
                }
            }
            bool grew = false;
            while (!queue.empty()) {
                const Item item = queue.top();
                queue.pop();
                if (primitive[label[item.triangle]].kind >= 0) {
                    continue;
                }
                label[item.triangle] = item.region;
                grew = true;
                offer_neighbours(item.triangle, item.region);
                if (deadline.tick()) {
                    error = late;
                    return false;
                }
            }
            if (grew) {
                // What is left of the regions that fit nothing: its connected pieces.
                std::vector<uint8_t> left(T, 0);
                for (size_t t = 0; t < T; ++t) {
                    if (primitive[label[t]].kind < 0) {
                        left[t] = 1;
                        label[t] = NONE;
                    }
                }
                if (!flood_by_angle(state, 180.0, &left, label, count, normals, deadline)) {
                    error = late;
                    return false;
                }
                primitive.resize(count);
            }
        }
        kinds.resize(count, -1);
        for (uint32_t r = 0; r < count && r < primitive.size(); ++r) {
            kinds[r] = primitive[r].kind;
        }
    }
    const std::vector<uint32_t> regions = label;  // before the small ones join their neighbours
    if (!merge_small(state, label, count, opt.min_size, opt.accurate ? 40.0 : 2.0 * opt.angle_deg, normals, stats.merged_small, deadline)) {
        error = late;
        return false;
    }
    if (opt.accurate) {
        // What the groups are, as they come out: a group is what its largest region was (small
        // regions that joined a neighbour count as that neighbour).
        std::vector<uint32_t> region_size(count, 0), largest(count, NONE);
        for (size_t t = 0; t < T; ++t) {
            ++region_size[regions[t]];
        }
        for (size_t t = 0; t < T; ++t) {
            uint32_t& top = largest[label[t]];
            const uint32_t r = regions[t];
            if (top == NONE || region_size[r] > region_size[top] || (region_size[r] == region_size[top] && r < top)) {
                top = r;
            }
        }
        for (uint32_t g = 0; g < count; ++g) {
            if (largest[g] == NONE) {
                continue;
            }
            const int kind = kinds[largest[g]];
            stats.planes += kind == 0 ? 1 : 0;
            stats.cylinders += kind == 1 ? 1 : 0;
            stats.spheres += kind == 2 ? 1 : 0;
            stats.freeform += kind < 0 ? 1 : 0;
        }
    }
    // Names g0..gN by each group's smallest triangle.
    std::vector<uint32_t> renumber(count, NONE);
    uint32_t groups = 0;
    out.positions = m.positions;
    out.triangles = m.triangles;
    out.groups.resize(T);
    for (size_t t = 0; t < T; ++t) {
        uint32_t& id = renumber[label[t]];
        if (id == NONE) {
            id = groups++;
        }
        out.groups[t] = id;
    }
    if (groups > budget::MAX_GROUPS_MESH) {
        error = "Too many groups (" + with_commas(groups) + "); raise the " + (opt.accurate ? "Fit Tolerance" : "Angle Threshold") + " or Smallest Group.";
        return false;
    }
    out.group_names.clear();
    for (uint32_t g = 0; g < groups; ++g) {
        out.group_names.push_back("g" + std::to_string(g));
    }
    stats.groups = groups;
    return true;
}

Dictionary plane_dict(const PlaneFit& f)
{
    Dictionary d;
    d["valid"] = f.valid;
    if (f.valid) {
        d["point"] = Vector3(real_t(f.point.x), real_t(f.point.y), real_t(f.point.z));
        d["normal"] = Vector3(real_t(f.normal.x), real_t(f.normal.y), real_t(f.normal.z));
        d["rms"] = f.rms;
        d["max"] = f.max;
        d["max_at_middles"] = f.max_middle;
    }
    return d;
}

}  // namespace
}  // namespace mesh

// ---------------------------------------------------------------- fit_primitive

Dictionary CadMesh::fit_primitive(const PackedInt32Array& tris)
{
    clear_messages();
    Dictionary out;
    if (is_null()) {
        fail("There is no mesh to fit.");
        return out;
    }
    const mesh::MeshData& m = state->data;
    std::vector<uint32_t> list;
    std::string error;
    if (!mesh::triangle_list(tris, m.triangle_count(), list, error)) {
        fail(error);
        return out;
    }
    if (list.empty()) {
        fail("Select the triangles to fit.");
        return out;
    }
    mesh::FitScratch scratch(m.vertex_count());
    mesh::PrimitiveFit fit;
    try {
        fit = mesh::fit_primitives(m, list.data(), list.size(), scratch);
    }
    catch (const std::exception& e) {
        fail(mesh::library_error("The fit", e.what()));
        return out;
    }
    out["triangles"] = int64_t(list.size());
    out["points"] = int64_t(fit.points);
    out["area"] = fit.area;
    out["plane"] = mesh::plane_dict(fit.plane);
    Dictionary cylinder;
    cylinder["valid"] = fit.cylinder.valid;
    if (fit.cylinder.valid) {
        cylinder["point"] = Vector3(real_t(fit.cylinder.point.x), real_t(fit.cylinder.point.y), real_t(fit.cylinder.point.z));
        cylinder["axis"] = Vector3(real_t(fit.cylinder.axis.x), real_t(fit.cylinder.axis.y), real_t(fit.cylinder.axis.z));
        cylinder["radius"] = fit.cylinder.radius;
        cylinder["rms"] = fit.cylinder.rms;
        cylinder["max"] = fit.cylinder.max;
        cylinder["max_at_middles"] = fit.cylinder.max_middle;
    }
    out["cylinder"] = cylinder;
    Dictionary sphere;
    sphere["valid"] = fit.sphere.valid;
    if (fit.sphere.valid) {
        sphere["center"] = Vector3(real_t(fit.sphere.center.x), real_t(fit.sphere.center.y), real_t(fit.sphere.center.z));
        sphere["radius"] = fit.sphere.radius;
        sphere["rms"] = fit.sphere.rms;
        sphere["max"] = fit.sphere.max;
        sphere["max_at_middles"] = fit.sphere.max_middle;
    }
    out["sphere"] = sphere;
    out["size"] = fit.size;
    // The winner: the simplest primitive that is as good as the best one, by the larger of its
    // two errors (at the corners and at the triangles' middles): within 1.5 x the best one's, or
    // within 1e-6 x the body's diagonal (what float positions can hold). And no winner at all
    // when even that one is poor for the patch: over 5 % of the patch's half-size (a cube, a
    // cone and a torus patch are none of the three).
    const double floor = 1e-6 * mesh::measures_of(*state).diagonal;
    const double plane_error = fit.plane.valid ? std::max(fit.plane.max, fit.plane.max_middle) : mesh::kInf;
    const double cylinder_error = fit.cylinder.valid ? std::max(fit.cylinder.max, fit.cylinder.max_middle) : mesh::kInf;
    const double sphere_error = fit.sphere.valid ? std::max(fit.sphere.max, fit.sphere.max_middle) : mesh::kInf;
    const double best = std::min(plane_error, std::min(cylinder_error, sphere_error));
    const double enough = std::min(std::max(floor, 1.5 * best), std::max(floor, 0.05 * fit.size));
    String winner = "";
    if (plane_error <= enough) {
        winner = "plane";
    }
    else if (cylinder_error <= enough) {
        winner = "cylinder";
    }
    else if (sphere_error <= enough) {
        winner = "sphere";
    }
    out["winner"] = winner;
    return out;
}

// ---------------------------------------------------------------- generate_groups

Ref<CadMesh> CadMesh::generate_groups(const Dictionary& options)
{
    clear_messages();
    const double started = mesh::op_now_ms();
    if (is_null()) {
        fail("There is no mesh to group.");
        return Ref<CadMesh>();
    }
    const size_t T = state->data.triangle_count();
    const double D = mesh::measures_of(*state).diagonal;
    mesh::OptionReader reader(options);
    mesh::GroupOptions opt;
    opt.accurate = reader.choice("method", "Method", {"fast", "accurate"}, 1) == 1;
    opt.angle_deg = reader.number("angle", "Angle Threshold", 20.0, 1.0, 90.0, "deg");
    opt.tolerance = reader.number("tolerance", "Fit Tolerance", D / 2000.0, D * 1e-6, D / 20.0, "m");
    opt.min_size = reader.integer("min_size", "Smallest Group", 10, 1, 100000);
    const double limit = reader.time_limit();
    if (!reader.ok()) {
        fail(reader.error());
        return Ref<CadMesh>();
    }
    const char* hint = "Use the Fast method, or Reduce the body first.";
    const double estimate = mesh::budget::estimate(opt.accurate ? mesh::budget::GROUPS_ACCURATE : mesh::budget::GROUPS_FAST, double(T)) + mesh::post_check_estimate(double(T), false);
    if (estimate > limit) {
        fail(mesh::too_slow_text("Generate Face Groups", estimate, limit, hint));
        return Ref<CadMesh>();
    }
    const mesh::Deadline deadline(limit);
    mesh::MeshData data;
    mesh::GroupStats stats;
    std::string error;
    bool ok = false;
    try {
        ok = mesh::generate(*state, opt, deadline, data, stats, error);
    }
    catch (const std::exception& e) {
        error = mesh::library_error("Generate Face Groups", e.what());
    }
    catch (...) {
        error = mesh::library_error("Generate Face Groups", nullptr);
    }
    if (!ok) {
        fail(error);
        return Ref<CadMesh>();
    }
    Ref<CadMesh> out = finish_op("Generate Face Groups", "generate_groups", std::move(data), started, false);
    if (out.is_null()) {
        return out;
    }
    last_report["groups"] = int64_t(stats.groups);
    last_report["planes"] = int64_t(stats.planes);
    last_report["cylinders"] = int64_t(stats.cylinders);
    last_report["spheres"] = int64_t(stats.spheres);
    last_report["freeform"] = int64_t(stats.freeform);
    last_report["merged_small"] = int64_t(stats.merged_small);
    // Must hold: only the groups changed.
    Dictionary checks = last_report.get("checks", Dictionary());
    const mesh::MeshData& r = out->data();
    if (r.triangles != state->data.triangles || r.triangle_count() != T) {
        // (An input with unused vertices is compacted; then the corners' positions are compared.)
        bool same = r.triangle_count() == T;
        for (size_t i = 0; same && i < T * 3; ++i) {
            same = std::memcmp(&r.positions[size_t(r.triangles[i]) * 3], &state->data.positions[size_t(state->data.triangles[i]) * 3], sizeof(float) * 3) == 0;
        }
        if (!same) {
            checks["unchanged"] = "fail: Generate Face Groups changed the triangles (internal error).";
            last_report["checks"] = checks;
            fail("Generate Face Groups changed the triangles (internal error). Please report it.");
            return Ref<CadMesh>();
        }
    }
    checks["unchanged"] = "ok";
    last_report["checks"] = checks;
    return out;
}

// ---------------------------------------------------------------- regroup

Ref<CadMesh> CadMesh::regroup(const Dictionary& tris_or_groups)
{
    clear_messages();
    const double started = mesh::op_now_ms();
    if (is_null()) {
        fail("There is no mesh to regroup.");
        return Ref<CadMesh>();
    }
    const mesh::MeshData& m = state->data;
    const size_t T = m.triangle_count();
    const bool by_groups = tris_or_groups.has("groups");
    const bool by_triangles = tris_or_groups.has("triangles");
    if (by_groups == by_triangles) {
        fail("Pick either face groups to combine or triangles for a new face group.");
        return Ref<CadMesh>();
    }
    mesh::MeshData data = m;
    if (by_groups) {
        // Combine Face Groups: every picked group takes the name of the first picked one.
        const Variant v = tris_or_groups["groups"];
        std::vector<uint32_t> ids;
        if (v.get_type() == Variant::PACKED_INT32_ARRAY) {
            const PackedInt32Array list = v;
            for (int64_t i = 0; i < list.size(); ++i) {
                if (list[i] < 0 || size_t(list[i]) >= m.group_count()) {
                    fail("Face group " + std::to_string(list[i]) + " is not in the mesh (it has " + mesh::with_commas(m.group_count()) + " face groups).");
                    return Ref<CadMesh>();
                }
                ids.push_back(uint32_t(list[i]));
            }
        }
        else if (v.get_type() == Variant::PACKED_STRING_ARRAY || v.get_type() == Variant::ARRAY) {
            const Array names = v;
            for (int64_t i = 0; i < names.size(); ++i) {
                int g = -1;
                if (names[i].get_type() == Variant::INT) {
                    g = int(int64_t(names[i]));
                    g = (g >= 0 && size_t(g) < m.group_count()) ? g : -1;
                }
                else if (names[i].get_type() == Variant::STRING || names[i].get_type() == Variant::STRING_NAME) {
                    g = find_face(String(names[i]));
                }
                if (g < 0) {
                    fail("Face group '" + std::string(String(names[i]).utf8().get_data()) + "' is not in the mesh.");
                    return Ref<CadMesh>();
                }
                ids.push_back(uint32_t(g));
            }
        }
        else {
            fail("The face groups to combine must be given by name.");
            return Ref<CadMesh>();
        }
        std::vector<uint32_t> unique_ids;
        for (const uint32_t g : ids) {
            if (std::find(unique_ids.begin(), unique_ids.end(), g) == unique_ids.end()) {
                unique_ids.push_back(g);
            }
        }
        if (unique_ids.size() < 2) {
            fail("Pick two or more face groups to combine.");
            return Ref<CadMesh>();
        }
        std::vector<uint32_t> into(m.group_count());
        for (size_t g = 0; g < into.size(); ++g) {
            into[g] = uint32_t(g);
        }
        for (const uint32_t g : unique_ids) {
            into[g] = unique_ids[0];
        }
        for (uint32_t& g : data.groups) {
            g = into[g];
        }
        Ref<CadMesh> out = finish_op("Combine Face Groups", "regroup", std::move(data), started, false);
        if (out.is_valid()) {
            last_report["combined_groups"] = int64_t(unique_ids.size());
            last_report["group"] = mesh::op_text(m.group_names[unique_ids[0]]);
        }
        return out;
    }
    // Create Face Group: the picked triangles leave their groups for a new one, user<k>.
    const Variant v = tris_or_groups["triangles"];
    if (v.get_type() != Variant::PACKED_INT32_ARRAY) {
        fail("The triangles of the new face group must be given as triangle numbers.");
        return Ref<CadMesh>();
    }
    std::vector<uint32_t> list;
    std::string error;
    if (!mesh::triangle_list(PackedInt32Array(v), T, list, error)) {
        fail(error);
        return Ref<CadMesh>();
    }
    if (list.empty()) {
        fail("Pick the triangles of the new face group.");
        return Ref<CadMesh>();
    }
    std::string name;
    if (tris_or_groups.has("name")) {
        name = std::string(String(tris_or_groups["name"]).utf8().get_data());
        if (name.empty() || name.size() > mesh::budget::MAX_GROUP_NAME_BYTES || find_face(String(tris_or_groups["name"])) >= 0) {
            fail("The new face group needs a name of 1 to 64 bytes that no other face group has.");
            return Ref<CadMesh>();
        }
    }
    else {
        std::unordered_set<std::string> taken(m.group_names.begin(), m.group_names.end());
        for (size_t k = 0;; ++k) {
            name = "user" + std::to_string(k);
            if (taken.count(name) == 0) {
                break;
            }
        }
    }
    if (m.group_count() + 1 > mesh::budget::MAX_GROUPS_MESH) {
        fail("The mesh already has " + mesh::with_commas(m.group_count()) + " face groups, the most a mesh body takes. Combine some first.");
        return Ref<CadMesh>();
    }
    const uint32_t id = uint32_t(data.group_names.size());
    data.group_names.push_back(name);
    for (const uint32_t t : list) {
        data.groups[t] = id;
    }
    Ref<CadMesh> out = finish_op("Create Face Group", "regroup", std::move(data), started, false);
    if (out.is_valid()) {
        last_report["group"] = mesh::op_text(name);
        last_report["group_triangles"] = int64_t(list.size());
    }
    return out;
}

}  // namespace holo_forge
