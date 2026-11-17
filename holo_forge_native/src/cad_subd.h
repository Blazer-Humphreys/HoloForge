#pragma once

#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

#include <memory>

#include "cad_shape.h"

namespace holo_forge
{

namespace subd
{
struct State;
}

/// One Catmull-Clark subdivision cage (a Form body) and its limit surface, through OpenSubdiv:
/// display tessellation, exact limit evaluation, picking, closest points, least-squares fits
/// and conversion to exact B-rep (contract C3 of the Form work order). Positions are meters in
/// doubles. Every method returns an empty value on failure and sets get_last_error().
class CadSubD: public godot::RefCounted
{
    GDCLASS(CadSubD, godot::RefCounted)

public:
    CadSubD();
    ~CadSubD() override;

    bool set_cage(const godot::Dictionary& cage);
    bool set_positions(const godot::PackedFloat64Array& positions);
    int get_vertex_count() const;
    int get_face_count() const;
    int get_edge_count() const;
    int get_ptex_count() const;
    godot::String osd_version() const;

    godot::Dictionary tessellate(const godot::Dictionary& options);
    godot::Dictionary limit_points();
    godot::Dictionary evaluate(const godot::PackedInt32Array& faces, const godot::PackedVector2Array& uvs);
    /// The face coordinate of normalized point (s, t) of sub-face k of an n-gon (quads: (s, t)).
    /// Verified against Bfr::Parameterization and by evaluation: sub-face k has (0,0) at corner k,
    /// (1,0) at the midpoint of edge (k, k+1), (1,1) at the face centre and (0,1) at the midpoint
    /// of edge (k-1, k) (the same layout as the patch table's ptex sub-faces). Sub-faces are laid
    /// out as half-size tiles: sub-face k sits at tile (k % w, k / w), w = 2 for triangles and
    /// 3 for 5- to 9-gons, and (s, t) maps to (k % w + s / 2, k / w + t / 2).
    godot::Vector2 subface_uv(int face, int subface, double s, double t) const;

    godot::Dictionary ray_hit(const godot::Vector3& from, const godot::Vector3& dir, int mode, bool refine);
    godot::PackedByteArray visible(const godot::PackedVector3Array& points, const godot::Vector3& eye,
                                   const godot::Vector3& view_dir, double tolerance, int mode);
    godot::Dictionary closest_points(const godot::PackedVector3Array& points, double max_distance);

    godot::PackedFloat64Array interpolate(const godot::PackedFloat64Array& targets, const godot::PackedInt32Array& free,
                                          double regularize);
    godot::PackedFloat64Array fit(const godot::PackedInt32Array& faces, const godot::PackedVector2Array& uvs,
                                  const godot::PackedFloat64Array& targets, const godot::PackedInt32Array& free,
                                  double regularize);

    godot::Array to_shapes(const godot::Dictionary& params);
    godot::Dictionary get_last_report() const;
    godot::Dictionary check_cage(const godot::Dictionary& cage, bool self_intersections) const;

    godot::Dictionary project_to_shape(const godot::Ref<CadShape>& shape, const godot::PackedVector3Array& points,
                                       double max_distance);
    godot::Dictionary face_grid(const godot::Ref<CadShape>& shape, int face_index, int nu, int nv);

    godot::String get_last_error() const;
    godot::String get_last_warning() const;

protected:
    static void _bind_methods();

private:
    void report(const godot::String& error) const;

    std::unique_ptr<subd::State> state;
    mutable godot::String last_error;
    mutable godot::String last_warning;
    godot::Dictionary last_report;
};

}  // namespace holo_forge
