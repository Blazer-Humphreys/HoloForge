#pragma once

#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

#include <memory>
#include <string>
#include <vector>

#include <GProp_GProps.hxx>
#include <TopTools_IndexedDataMapOfShapeListOfShape.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <TopoDS_Shape.hxx>

namespace holo_forge
{

/// A B-rep shape (solid, shell, face, wire, ...) owned by the OpenCASCADE kernel.
class CadShape: public godot::RefCounted
{
    GDCLASS(CadShape, godot::RefCounted)

public:
    static godot::Ref<CadShape> wrap(const TopoDS_Shape& shape);

    const TopoDS_Shape& get_occ_shape() const
    {
        return shape;
    }
    void set_occ_shape(const TopoDS_Shape& value)
    {
        shape = value;
        reset_maps();
    }

    /// The shape's faces / edges / vertices in id order (id + 1 is the map index), and each
    /// edge's faces. Built on first use and kept until the shape changes, so per-face and per-edge
    /// calls don't map the whole shape again (that made face-by-face loops quadratic).
    const TopTools_IndexedMapOfShape& face_map() const;
    const TopTools_IndexedMapOfShape& edge_map() const;
    const TopTools_IndexedMapOfShape& vertex_map() const;
    const TopTools_IndexedDataMapOfShapeListOfShape& edge_face_map() const;
    void reset_maps();

    bool is_null() const;
    godot::String shape_type() const;
    /// Volume and center of mass count closed shells only: an open shell (a surface body) has no
    /// volume (its center is then the origin; callers use the area's center instead).
    double volume() const;
    double area() const;
    godot::Vector3 center_of_mass() const;
    /// The centre of the faces' area, integrated exactly as area() (the origin for a shape with no
    /// faces): a surface body's centre.
    godot::Vector3 area_center() const;
    godot::AABB bbox() const;
    int face_count() const;
    int edge_count() const;
    int vertex_count() const;

    /// Triangulates the shape. Returns arrays ready for ArrayMesh plus per-triangle face ids and
    /// sampled edge segments with edge ids, used for picking and edge overlays.
    godot::Dictionary tessellate(double linear_deflection, double angular_deflection) const;

    /// A face's surface: {"type": "plane"|"cylinder"|"cone"|"sphere"|"torus"|"other", "planar",
    /// "point" (a point on the face), "normal" (outward, planes only), "area", "edges" (edge ids),
    /// and for round faces "axis_origin", "axis", "radius" (sphere/torus: "center")}.
    godot::Dictionary face_info(int face_id) const;
    /// An edge's curve: {"type": "line"|"circle"|"ellipse"|"bspline"|"other", "start", "end",
    /// "midpoint", "tangent" (at the middle), "length", "closed", "convex" (between its faces),
    /// "faces" (face ids); circles add "center", "radius", "axis"}.
    godot::Dictionary edge_info(int edge_id) const;
    /// The outward normal of a face at the point on it nearest to point.
    godot::Vector3 face_normal_at(int face_id, const godot::Vector3& point) const;
    /// A point and tangent at fraction t (0..1) of an edge's curve parameter range.
    godot::Dictionary edge_point_at(int edge_id, double t) const;
    /// A point and tangent at a fraction (0..1) of an edge's length from its start.
    godot::Dictionary edge_point_at_length(int edge_id, double fraction) const;

    // --- Inspection ---
    /// {"volume", "area", "mass", "center", "inertia" (9 values about the center, row-major),
    ///  "principal_moments": Vector3} for a uniform density (kg/m^3). Volume, mass and inertia
    /// come from closed shells only, as volume().
    godot::Dictionary mass_properties(double density) const;
    /// Curvatures of a face at surface parameters (e.g. a tessellation's uvs):
    /// {"k1", "k2" (largest, smallest principal), "gaussian", "mean": PackedFloat64Array,
    ///  "dir1": PackedVector3Array (direction of k1), "normals": PackedVector3Array}. Signs follow
    /// the face's outward side: positive bends away from it (convex).
    godot::Dictionary surface_curvatures(int face_id, const godot::PackedVector2Array& uvs) const;
    /// How many meters one unit of the face's u and v parameters spans (at its middle).
    godot::Vector2 face_uv_metric(int face_id) const;
    /// {"points": PackedVector3Array, "curvature": PackedFloat64Array, "normals": PackedVector3Array}
    /// at count evenly spaced parameters along an edge (normals point to the center of curvature).
    godot::Dictionary edge_curvature(int edge_id, int count) const;
    /// Iso lines of a face's surface, trimmed to the face: u_count lines of constant u and v_count
    /// of constant v, evenly spaced inside the face's UV bounds (BRepTools::UVBounds) and never on
    /// them. Each line is sampled at `samples` parameters across the bounds; samples outside the
    /// face (BRepClass) split it into runs, and run ends are bisected onto the face's boundary.
    /// A flat face's lines are cut exactly where they cross its boundary (OCCT's hatcher, with
    /// the samples between), which is much faster on meshes with thousands of flat faces.
    /// Returns one entry per run: {"points": PackedVector3Array, "curvature": PackedFloat64Array
    /// (of the iso curve in space, 1/m), "normals": PackedVector3Array (unit, toward the center of
    /// curvature; zero where straight), "direction": "u" (constant u) | "v"}. Points follow the
    /// face's location; curvature and normals don't depend on its orientation.
    godot::Array face_isocurves(int face_id, int u_count, int v_count, int samples) const;
    godot::Vector3 vertex_position(int vertex_id) const;

    // --- Persistent names (topological naming) ---
    /// Names for every face / edge, in face and edge id order. Features refer to faces and edges by
    /// these names, which survive rebuilds because operations pass them on through their history.
    godot::PackedStringArray get_face_names() const;
    godot::PackedStringArray get_edge_names() const;
    void set_face_names(const godot::PackedStringArray& names);
    void set_edge_names(const godot::PackedStringArray& names);
    int find_face(const godot::String& name) const;
    int find_edge(const godot::String& name) const;
    /// Recomputes edge names from the names of the faces they join.
    void name_edges_from_faces();

    /// Each solid of a compound as its own shape (with its names).
    godot::Array solids() const;
    /// One face or edge as its own shape, keeping its names.
    godot::Ref<CadShape> face_shape(int face_id) const;
    godot::Ref<CadShape> edge_shape(int edge_id) const;
    int solid_count() const;
    /// True for a surface body: faces but no solid (open shells, lone faces).
    bool is_surface() const;
    godot::Ref<CadShape> copy() const;

    godot::PackedByteArray to_brep_bytes() const;
    bool load_brep_bytes(const godot::PackedByteArray& bytes);

    /// For tests of tessellate's guard only: damages the mesh of one face as a failed or misread
    /// meshing would leave it, and from then on tessellate draws this shape's mesh as it finds it
    /// (it doesn't mesh the shape again). With coarse_deflection above 0 the whole shape is first
    /// meshed afresh that coarsely (its edges' mesh points few and far off them). keep below 0
    /// takes the face's mesh away; from 0 to 1 it leaves triangles covering about that part of
    /// the mesh's area (the rest are made empty). block_remesh also keeps tessellate from meshing
    /// the shape again when a face's mesh fails its check, so that what it says of a face it
    /// can't draw can be tested.
    /// False when there is no such face or it has no mesh to damage.
    bool test_damage_mesh(int face_id, double keep, double coarse_deflection, bool block_remesh);

    // Native-side naming access.
    std::vector<std::string> face_name_list;
    std::vector<std::string> edge_name_list;

protected:
    static void _bind_methods();

private:
    const GProp_GProps& volume_props() const;
    const GProp_GProps& surface_props() const;

    TopoDS_Shape shape;
    mutable std::unique_ptr<godot::AABB> bbox_cache;
    // Volume and surface properties, and each face's area and centre (-1 until measured): a spline
    // face's integral takes a while, so each is measured once.
    mutable std::unique_ptr<GProp_GProps> volume_cache;
    mutable std::unique_ptr<GProp_GProps> surface_cache;
    mutable std::vector<std::pair<double, godot::Vector3>> face_area_cache;
    mutable std::unique_ptr<TopTools_IndexedMapOfShape> face_map_cache;
    mutable std::unique_ptr<TopTools_IndexedMapOfShape> edge_map_cache;
    mutable std::unique_ptr<TopTools_IndexedMapOfShape> vertex_map_cache;
    mutable std::unique_ptr<TopTools_IndexedDataMapOfShapeListOfShape> edge_faces_cache;
    // Set by test_damage_mesh only.
    bool test_mesh_frozen = false;
    bool test_remesh_blocked = false;
};

}  // namespace holo_forge
