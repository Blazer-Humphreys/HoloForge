#pragma once

// Convert Mesh (work order 3.4): a mesh body turned into a B-rep body.
//   Faceted    one flat face per triangle, or one per flat patch of a face group
//              (CadMesh::to_faceted)
//   Prismatic  a plane, a cylinder or a sphere fitted to each face group, and the solid those
//              surfaces close (CadMesh::to_prismatic)
// Both are CadMesh methods in mesh_convert.cpp and give a CadShape, or null with
// get_last_error(). Each result is checked before it is handed over (closed, valid, its volume
// and its surface against the mesh's, every face drawable); a result that fails a check is
// refused with what is off and by how much. Organic convert is GDScript (core/mesh/organic.gd).
//
// CadMesh::convert_defaults(method, options) gives what a panel needs before the op runs:
// defaults, ranges, the op's own time estimate in seconds and, when the options would be
// refused before any work, the sentence ("problem").

#include <cstddef>

namespace holo_forge::mesh::convert
{

/// What Convert Mesh: Faceted costs, in seconds, for a result of that many faces (a merged flat
/// patch is one face, every other triangle one) whose merged faces have that many outline edges:
/// building the faces, the solid check, meshing the result for the per-face check and measuring.
double faceted_seconds(double faces, double outline_edges);

/// What Convert Mesh: Prismatic costs, in seconds: the fits and the checks by triangles, the
/// cell building by surfaces, by pairs of round surfaces that cross (the intersection curves
/// OpenCASCADE has to walk) and by the corners where three flat surfaces meet (the cells).
double prismatic_seconds(double triangles, double surfaces, double crossing_pairs, double corners);

}  // namespace holo_forge::mesh::convert
