#pragma once

// Our own voxel code for Wrap, Rebuild and Shell (work order 3.2.3, 3.2.4, 3.3.5): a regular grid
// of samples over a mesh, the unsigned distance to the triangles at each sample, inside/outside
// by winding along +Z columns, a flood fill from the grid's border, an exact nearest-sample
// transform (Felzenszwalb and Huttenlocher's lower envelopes, linear time), and the trilinear
// reader Manifold's LevelSet samples. Every loop here checks the op's deadline.

#include "mesh_bvh.h"
#include "mesh_data.h"
#include "mesh_deadline.h"

#include <cstdint>
#include <vector>

namespace holo_forge::mesh::voxel
{

/// Samples at origin + (i, j, k) h. Sample (i, j, k) has index (k n[1] + j) n[0] + i.
struct Grid
{
    int n[3] = {0, 0, 0};
    double origin[3] = {0, 0, 0};
    double h = 0.0;

    size_t count() const
    {
        return size_t(n[0]) * size_t(n[1]) * size_t(n[2]);
    }
    size_t index(int i, int j, int k) const
    {
        return (size_t(k) * size_t(n[1]) + size_t(j)) * size_t(n[0]) + size_t(i);
    }
    void point(int i, int j, int k, double p[3]) const
    {
        p[0] = origin[0] + i * h;
        p[1] = origin[1] + j * h;
        p[2] = origin[2] + k * h;
    }
    double top(int axis) const
    {
        return origin[axis] + (n[axis] - 1) * h;
    }
};

/// How many samples a grid of cell size h has over lo..hi grown by margin on every side (a
/// double, so a far too fine grid cannot overflow).
double sample_count(const double lo[3], const double hi[3], double margin, double h);
/// That grid, centred on the bounds.
Grid make_grid(const double lo[3], const double hi[3], double margin, double h);
/// The smallest cell size h whose grid over lo..hi, grown by fixed_margin + margin_cells x h,
/// has at most max_samples samples (rounded up to 3 significant digits).
double fitting_cell(const double lo[3], const double hi[3], double fixed_margin, double margin_cells, double max_samples);

/// The unsigned distance from every sample to the triangles; values above band are band.
/// False when the deadline passed.
bool distance_field(const TriBvh& bvh, const Grid& grid, double band, std::vector<float>& out, const Deadline& deadline);
/// 1 at samples whose winding number is not 0: one +Z ray per grid column, its crossings
/// sorted and added up (handles overlapping and self-crossing shells). With by_parity the
/// crossings are only counted, and a sample with an odd number above it is inside: that needs
/// no agreement between the triangles about their sides (a mesh with flipped triangles), but
/// where two shells overlap it sees a hole. False when the deadline passed.
bool winding_field(const TriBvh& bvh, const Grid& grid, bool by_parity, std::vector<uint8_t>& inside, const Deadline& deadline);
/// 1 at samples reached from the grid's border through samples whose value is above `above`
/// (6 neighbours). False when the deadline passed.
bool flood_from_border(const Grid& grid, const std::vector<float>& values, float above, std::vector<uint8_t>& reached, const Deadline& deadline);
/// For every sample the index of the nearest sample of the set (exact Euclidean), -1 when the
/// set is empty. False when the deadline passed.
bool nearest_in_set(const Grid& grid, const std::vector<uint8_t>& set, std::vector<int32_t>& source, const Deadline& deadline);

/// A sampled function read between the samples (trilinear; outside the grid the nearest
/// sample's value).
struct Field
{
    const Grid* grid = nullptr;
    const float* values = nullptr;
    double at(double x, double y, double z) const;
};

}  // namespace holo_forge::mesh::voxel
