#pragma once

// The triangle hierarchy of a mesh body: holo_forge::subd::Bvh (subd_bvh.h, shared with the Form
// workspace, not copied) over the mesh's triangles, with the queries the Mesh workspace needs.
// Only the way the tree is filled is new: by sorted Morton codes, which is several times faster
// on a million triangles than the median split subd::Bvh::build() does, and can be stopped.

#include "mesh_data.h"
#include "subd_bvh.h"

namespace holo_forge::mesh
{

struct TriBvh
{
    subd::Bvh bvh;
    const MeshData* mesh = nullptr;

    /// False when the deadline (may be null) passed; the tree is then empty.
    bool build(const MeshData& data, const Deadline* deadline);
    size_t memory_bytes() const;

    void corners(uint32_t triangle, double a[3], double b[3], double c[3]) const
    {
        const uint32_t* t = &mesh->triangles[size_t(triangle) * 3];
        mesh->point(t[0], a);
        mesh->point(t[1], b);
        mesh->point(t[2], c);
    }

    /// The first triangle the ray o + t d meets for t in (0, tmax). Back faces count.
    bool closest_hit(const double o[3], const double d[3], double tmax, uint32_t& triangle, double& t) const;

    /// The nearest point on the triangles accept(triangle) lets through. Returns the squared
    /// distance (best2 when nothing is nearer than that) and fills triangle (NONE when none) and out.
    template <class F>
    double nearest(const double p[3], double best2, uint32_t& triangle, double out[3], F&& accept) const
    {
        triangle = NONE;
        bvh.nearest(p, best2, [&](int prim, double& best) {
            if (!accept(uint32_t(prim))) {
                return;
            }
            double a[3], b[3], c[3], q[3], b1 = 0.0, b2 = 0.0;
            corners(uint32_t(prim), a, b, c);
            const double d2 = subd::closest_on_triangle(p, a, b, c, q, b1, b2);
            if (d2 < best) {
                best = d2;
                triangle = uint32_t(prim);
                out[0] = q[0];
                out[1] = q[1];
                out[2] = q[2];
            }
        });
        return best2;
    }
    double nearest(const double p[3], double best2, uint32_t& triangle, double out[3]) const
    {
        return nearest(p, best2, triangle, out, [](uint32_t) { return true; });
    }

    /// Calls visit(triangle, sign) for every triangle a +Z ray from p passes through: sign is +1
    /// where the ray leaves through the triangle's front (its normal points up), -1 where it
    /// enters. A ray through an edge or a corner two triangles share counts once (each edge is
    /// judged by one rule, whichever triangle asks), so the signs of a closed surface add up to
    /// its winding number around p.
    template <class F>
    void column(const double p[3], F&& visit) const
    {
        const double d[3] = {0.0, 0.0, 1.0};
        bvh.ray(p, d, std::numeric_limits<double>::infinity(), [&](int prim, double&) {
            double a[3], b[3], c[3];
            corners(uint32_t(prim), a, b, c);
            const int w = winding_2d(a, b, p) + winding_2d(b, c, p) + winding_2d(c, a, p);
            if (w == 0) {
                return true;
            }
            const double nx = (b[1] - a[1]) * (c[2] - a[2]) - (b[2] - a[2]) * (c[1] - a[1]);
            const double ny = (b[2] - a[2]) * (c[0] - a[0]) - (b[0] - a[0]) * (c[2] - a[2]);
            const double nz = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
            if (nz == 0.0) {
                return true;
            }
            const double z = a[2] - (nx * (p[0] - a[0]) + ny * (p[1] - a[1])) / nz;
            if (z > p[2]) {
                visit(uint32_t(prim), w);
            }
            return true;
        });
    }

    /// What the edge a -> b adds to the winding number of a polygon around p in the XY plane
    /// (a ray along +X; an edge owns its lower end and not its upper one).
    static int winding_2d(const double* a, const double* b, const double* p)
    {
        const bool up = a[1] <= p[1] && p[1] < b[1];
        const bool down = b[1] <= p[1] && p[1] < a[1];
        if (!up && !down) {
            return 0;
        }
        // Always measured from the lower end, so both triangles of an edge get the same number.
        const double* lo = up ? a : b;
        const double* hi = up ? b : a;
        const double left = (hi[0] - lo[0]) * (p[1] - lo[1]) - (p[0] - lo[0]) * (hi[1] - lo[1]);
        if (!(left > 0.0)) {
            return 0;
        }
        return up ? 1 : -1;
    }
};

}  // namespace holo_forge::mesh
