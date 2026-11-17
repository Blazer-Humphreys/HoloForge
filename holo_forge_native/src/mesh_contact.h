#pragma once

// Contact between two mesh bodies (Phase 8 work order, contract C5.1): CadMesh.overlap gives the
// solid two closed meshes share at a relative placement (its volume, area, thickness and where it
// is), from Manifold's intersection. The method itself is in mesh_contact.cpp; this header holds
// what cad_mesh.cpp needs of it.
//
// Each CadMesh keeps the Manifold that overlap() builds from it (the contact cache), so a sweep
// that calls overlap() thousands of times on the same two bodies builds each one only once. The
// cache belongs to the mesh's data (CadMesh::adopt() drops it), and CadMesh.memory_bytes() counts
// it, so it counts toward the mesh cache cap of the Mesh workspace.

#include <cstddef>

namespace holo_forge::mesh::contact
{

/// A mesh's Manifold for contact, built on first use (defined in mesh_contact.cpp).
struct Cache;

/// The bytes a contact cache holds (an estimate from the Manifold's vertex and triangle counts);
/// 0 for none.
size_t cache_bytes(const Cache* cache);

}  // namespace holo_forge::mesh::contact
