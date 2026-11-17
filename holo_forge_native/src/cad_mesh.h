#pragma once

#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <memory>
#include <string>

#include "mesh_data.h"

namespace holo_forge
{

// (Only named here: cad_shape.h brings in OpenCASCADE, whose macro Handle(Class) breaks pmp's
// headers, which have a class Handle. Files that need CadShape include cad_shape.h themselves;
// a file that includes both OpenCASCADE and pmp puts
//     #pragma push_macro("Handle")
//     #undef Handle
//     #include <pmp/...>
//     #pragma pop_macro("Handle")
// around the pmp headers, as cad_mesh.cpp does.)
class CadShape;

namespace mesh::contact
{
struct Cache;  // Phase 8 contact: the mesh's Manifold, built by overlap() (mesh_contact.h)
}

/// One triangle-mesh body of the Mesh workspace: indexed triangles with face groups (the work
/// order's contracts C1, C2 and C4). A mesh never changes once it is made: every operation gives
/// a new CadMesh, so results can be cached, previewed and undone freely.
///
/// Positions are meters in the part's space, float32 on purpose. Stored triangles wind
/// counter-clockwise seen from outside; set_arrays(), get_arrays() and tessellate() are the
/// only places that speak Godot's clockwise order.
///
/// Errors: a method that can fail clears get_last_error(), get_last_warning() and
/// get_last_report() when it starts, and on failure returns false, null or an empty value with
/// one sentence for the user in get_last_error(). The plain getters never touch them.
class CadMesh: public godot::RefCounted
{
    GDCLASS(CadMesh, godot::RefCounted)

public:
    CadMesh();
    ~CadMesh() override;

    // --- Native side (the op files) ---
    /// A mesh body from op output: compacted (no unused vertices, no empty groups) and checked.
    /// Null with `error` when the data breaks a C1 rule.
    static godot::Ref<CadMesh> wrap(mesh::MeshData&& data, std::string* error = nullptr);
    mesh::State& get_state()
    {
        return *state;
    }
    const mesh::MeshData& data() const
    {
        return state->data;
    }
    /// The shared end of an op on this mesh (work order 2.6.3): wraps `result`, runs the checks
    /// every result gets and fills get_last_report() and get_last_warning() of this mesh (the
    /// one the op was called on). Null with get_last_error() when the result is broken.
    /// `title` is the op's name in messages ("Remesh"), `op` its report key ("remesh").
    /// With test_self_intersections the result is tested for at most SELF_INTERSECTION_SECONDS
    /// (and the input too, to tell new crossings from old ones).
    /// Op-specific promises (boundary, volume, deviation) are added to the report by the op.
    godot::Ref<CadMesh> finish_op(const char* title, const char* op, mesh::MeshData&& result, double started_ms, bool test_self_intersections);

    // --- Construction and IO (each only on a fresh instance) ---
    bool set_arrays(const godot::PackedVector3Array& positions, const godot::PackedInt32Array& indices, const godot::PackedInt32Array& groups,
                    const godot::PackedStringArray& group_names, const godot::String& winding);
    bool from_blob(const godot::PackedByteArray& bytes);
    godot::PackedByteArray to_blob() const;
    bool read_stl(const godot::String& path, double scale);
    bool read_obj(const godot::String& path, double scale);
    /// Tessellate: linear in meters (a fraction of each edge's size when relative), angular in
    /// radians, like CadShape.tessellate.
    bool from_shape(const godot::Ref<CadShape>& shape, double linear, double angular, bool relative, double time_limit);
    godot::Dictionary get_arrays() const;
    /// {"pmp", "manifold", "meshoptimizer", "clipper2"}: the versions of the mesh libraries this
    /// build is linked against. Each library is also called once, so a missing or mismatched DLL
    /// shows here (get_last_error()) and not in the first tool that needs it.
    godot::Dictionary library_versions();
    /// The group name Tessellate gives a B-rep face name: the name itself when it is 1..64
    /// bytes, else a shortened form that is the same on every run.
    godot::String group_name_for(const godot::String& face_name) const;

    // --- The CadShape subset (contract C2.2) ---
    bool is_null() const;
    godot::String shape_type() const;
    godot::AABB bbox();
    godot::Dictionary tessellate(double linear_deflection, double angular_deflection);
    double volume();
    double area();
    godot::Vector3 center_of_mass();
    godot::Dictionary mass_properties(double density);
    int face_count() const;
    godot::PackedStringArray get_face_names() const;
    int find_face(const godot::String& name) const;
    godot::Dictionary face_info(int group);
    godot::Vector3 face_normal_at(int group, const godot::Vector3& point);
    int edge_count() const;
    godot::PackedStringArray get_edge_names() const;
    godot::Dictionary edge_info(int edge_id) const;
    int vertex_count() const;
    bool is_surface();
    int solid_count();
    godot::Ref<CadMesh> copy();

    // --- Queries (contract C4.2) ---
    bool is_mesh() const;
    int triangle_count() const;
    int group_count() const;
    godot::String digest();
    int64_t memory_bytes() const;
    godot::Dictionary check(double time_limit);
    godot::Array boundary_loops();
    godot::PackedInt32Array group_triangles(int group);
    godot::Dictionary ray_hit(const godot::Vector3& origin, const godot::Vector3& direction, double max_distance);
    /// planes: Plane values whose normals point out of the region, as Camera3D.get_frustum() gives.
    godot::PackedInt32Array triangles_in_frustum(const godot::Array& planes, const godot::String& mode);
    godot::PackedInt32Array triangles_near(const godot::Vector3& point, double radius, bool connected);
    godot::PackedInt32Array grow(const godot::PackedInt32Array& tris, int steps);
    godot::PackedInt32Array shrink(const godot::PackedInt32Array& tris, int steps);
    godot::PackedInt32Array connected(const godot::PackedInt32Array& tris, double max_angle_deg);
    godot::Array section(const godot::Vector3& origin, const godot::Vector3& normal);
    godot::Dictionary distance_to(const godot::Ref<CadMesh>& other, int64_t samples, double time_limit);
    godot::PackedByteArray winding_inside(const godot::PackedVector3Array& points);

    // --- Ops (contract C4.3). Stage N1 has the one the gate needs; N2 and N3 add theirs. ---
    godot::Ref<CadMesh> transformed(const godot::Transform3D& xform);
    /// Phase 8 fix round 1: the mesh moved by a rigid move given in doubles. m is an xform64
    /// (core/assembly/xform64.gd): 12 doubles, elements 0-2 the basis column X, 3-5 the column Y,
    /// 6-8 the column Z, 9-11 the origin, in meters. Each vertex is moved in doubles and rounded to
    /// float32 once. Only a rigid move is taken (finite, orthonormal within 1e-9, no mirror);
    /// anything else, or a result past 1,000 km, gives null and a sentence in get_last_error().
    godot::Ref<CadMesh> transformed64(const godot::PackedFloat64Array& m);

    // --- Stage N2 ops (mesh_clean.cpp, mesh_groups.cpp, mesh_smooth.cpp, mesh_reduce.cpp,
    // mesh_fill.cpp, mesh_remesh.cpp). Each returns a new mesh, or null with get_last_error(). ---
    godot::Ref<CadMesh> welded();
    godot::Ref<CadMesh> delete_triangles(const godot::PackedInt32Array& tris);
    godot::Ref<CadMesh> reverse(const godot::Dictionary& options);
    godot::Ref<CadMesh> stitch_and_remove(const godot::Dictionary& options);
    godot::Ref<CadMesh> regroup(const godot::Dictionary& tris_or_groups);
    godot::Ref<CadMesh> generate_groups(const godot::Dictionary& options);
    godot::Dictionary fit_primitive(const godot::PackedInt32Array& tris);
    godot::Ref<CadMesh> smooth(const godot::Dictionary& options);
    godot::Ref<CadMesh> reduce(const godot::Dictionary& options);
    godot::Ref<CadMesh> close_holes(const godot::Dictionary& options);
    godot::Ref<CadMesh> remesh(const godot::Dictionary& options);

    // --- Stage N3 ops (mesh_boolean.cpp, mesh_cut.cpp, mesh_wrap.cpp, mesh_shell.cpp,
    // mesh_separate.cpp, mesh_displace.cpp, mesh_manifold.cpp). plane_cut gives [above, below]
    // (either may be null) and separate the pieces; both give an empty Array with
    // get_last_error() on failure. wrap_op is bound as "wrap" (wrap() is the native helper). ---
    godot::Ref<CadMesh> boolean(const godot::Array& tools, const godot::Dictionary& options);
    godot::Ref<CadMesh> merge_with(const godot::Array& others);
    godot::Array plane_cut(const godot::Dictionary& options);
    godot::Ref<CadMesh> wrap_op(const godot::Dictionary& options);
    godot::Ref<CadMesh> rebuild(const godot::Dictionary& options);
    godot::Ref<CadMesh> shell(const godot::Dictionary& options);
    godot::Array separate(const godot::Dictionary& options);
    godot::Ref<CadMesh> displace(const godot::Dictionary& options);
    /// What a panel needs before an op runs ("wrap", "rebuild", "shell", "plane_cut",
    /// "displace", "boolean"): defaults, ranges and the op's time estimate in seconds.
    godot::Dictionary op_defaults(const godot::String& method, const godot::Dictionary& options);

    // --- Stage C: Convert Mesh (mesh_convert.cpp). Each gives a CadShape (a B-rep body), or
    // null with get_last_error(); convert_defaults ("faceted", "prismatic") is what their
    // panels ask before the op: defaults, ranges, the time estimate, and "problem". ---
    godot::Ref<CadShape> to_faceted(const godot::Dictionary& options);
    godot::Ref<CadShape> to_prismatic(const godot::Dictionary& options);
    godot::Dictionary convert_defaults(const godot::String& method, const godot::Dictionary& options);

    // --- Phase 8 contact (mesh_contact.cpp, work order C5.1). The solid this mesh shares with
    // other placed by other_to_this (12 doubles: basis columns X, Y, Z, then the origin), in this
    // mesh's space. Answers in the Dictionary (its "error"); get_last_* are not touched. ---
    godot::Dictionary overlap(const godot::Ref<CadMesh>& other, const godot::PackedFloat64Array& other_to_this, const godot::Dictionary& options);

    godot::String get_last_error() const;
    godot::String get_last_warning() const;
    godot::Dictionary get_last_report() const;

protected:
    static void _bind_methods();
    /// Stage N2 (pmp and meshoptimizer ops) binds its methods here, Stage N3 (Manifold and voxel
    /// ops) there. Both are called from _bind_methods(); each stage owns its function.
    static void bind_pmp_methods();
    static void bind_manifold_methods();
    /// Stage C (Convert Mesh) binds its methods here (mesh_convert.cpp).
    static void bind_convert_methods();
    /// Phase 8 contact binds overlap here (mesh_contact.cpp).
    static void bind_contact_methods();

private:
    void clear_messages() const;
    bool fresh(const char* what);
    bool adopt(mesh::MeshData&& data);
    bool fail(const std::string& message) const;
    /// transformed() and transformed64(): the mesh moved by basis (rows) and origin, in doubles.
    godot::Ref<CadMesh> move_by(const double basis[9], const double origin[3], double started);

    std::unique_ptr<mesh::State> state;
    /// overlap()'s Manifold of this mesh, kept for the next call; it names the State it was built
    /// from, adopt() drops it, and memory_bytes() counts it.
    std::shared_ptr<mesh::contact::Cache> contact_cache;
    bool made = false;
    mutable godot::String last_error;
    mutable godot::String last_warning;
    mutable godot::Dictionary last_report;
};

namespace mesh
{
/// Tessellate (mesh_tessellate.cpp): one group per B-rep face, named after the face; nodes on
/// shared edges welded. False with one sentence in error.
bool from_shape(const CadShape& shape, double linear, double angular, bool relative, double time_limit, MeshData& out, std::string& error);
/// The same, with `warning`: set when the mesh was made with another value than asked (a Surface
/// Deviation below the finest the mesher takes is raised to it).
bool from_shape(const CadShape& shape, double linear, double angular, bool relative, double time_limit, MeshData& out, std::string& error, std::string& warning);
/// The same, with `dropped`: the triangles left out because two of their corners are one vertex
/// (the mesher makes them where a face runs into a point: a ball's poles, a cone's tip). They
/// have no area and no edges of their own; the mesh is as closed without them.
bool from_shape(const CadShape& shape, double linear, double angular, bool relative, double time_limit, MeshData& out, std::string& error, std::string& warning,
                size_t& dropped);
/// "the body is <d> from the origin, where positions are stored only to about <step>" when the
/// float32 step at the mesh's place is more than a ten-thousandth of its size; else empty.
std::string far_note(const MeshData& mesh);
}  // namespace mesh

}  // namespace holo_forge
