#pragma once

#include <deque>
#include <map>
#include <memory>
#include <vector>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <App/planegcs/GCS.h>

namespace holo_forge
{

/// 2D geometric constraint solver for sketches (FreeCAD planegcs).
///
/// Geometry is added first (points, lines, circles, arcs, ellipses); constraints and dimensions
/// refer to it with Vector2i(kind, index) references and return a tag (>= 1) that conflict and
/// redundancy reports use. Dimensions can be driving (they move geometry) or driven (they only
/// measure it).
class CadSketchSolver: public godot::RefCounted
{
    GDCLASS(CadSketchSolver, godot::RefCounted)

public:
    enum Kind
    {
        KIND_POINT = 0,
        KIND_LINE = 1,
        KIND_CIRCLE = 2,
        KIND_ARC = 3,
        KIND_ELLIPSE = 4,
    };

    enum SolveResult
    {
        SOLVE_SUCCESS = 0,
        SOLVE_CONVERGED = 1,
        SOLVE_FAILED = 2,
        SOLVE_INVALID = 3,
    };

    CadSketchSolver();
    ~CadSketchSolver() override;

    void clear();

    int add_point(const godot::Vector2& position);
    int add_line(int point_a, int point_b);
    int add_circle(int center_point, double radius);
    /// An arc from start_angle to end_angle (counter-clockwise). start_point/end_point are
    /// existing points to use as the arc's ends, or -1 to create them.
    int add_arc(int center_point, double radius, double start_angle, double end_angle, int start_point, int end_point);
    /// An ellipse by center, one focus and minor radius (planegcs' parameterization).
    int add_ellipse(int center_point, int focus_point, double minor_radius);
    godot::PackedInt32Array get_arc_end_points(int arc) const;

    /// Locks or frees every parameter of a piece of geometry.
    void set_fixed(const godot::Vector2i& ref, bool fixed);
    void set_point_fixed(int point, bool fixed);

    godot::Vector2 get_point(int point) const;
    void set_point(int point, const godot::Vector2& position);
    /// Double-precision versions (Vector2 is single precision): sketches store these.
    int add_point_xy(double x, double y);
    void set_point_xy(int point, double x, double y);
    /// Every point as x0, y0, x1, y1, ... in double precision.
    godot::PackedFloat64Array get_point_coords() const;
    double get_circle_radius(int circle) const;
    double get_arc_radius(int arc) const;
    godot::Vector2 get_arc_angles(int arc) const;
    double get_ellipse_minor_radius(int ellipse) const;

    /// Adds a constraint or dimension; returns its tag, or -1 when the references don't fit.
    /// Types: coincident, horizontal, vertical, parallel, perpendicular, point_on, midpoint,
    /// symmetric, equal, concentric, collinear, tangent, distance, distance_x, distance_y,
    /// radius, diameter, angle, arc_length, length, coordinate_x, coordinate_y.
    int add_constraint(const godot::String& type, const godot::Array& refs, double value, bool driving);
    bool set_constraint_value(int tag, double value);
    /// The dimension's value: the target for driving dimensions, the measurement for driven ones.
    double get_constraint_value(int tag) const;

    int solve();
    /// Moves a point toward target as far as the constraints allow (for mouse drags).
    int drag_point(int point, const godot::Vector2& target);
    int get_dof() const;
    godot::PackedInt32Array get_conflicting() const;
    godot::PackedInt32Array get_redundant() const;
    /// Geometry that can still move (has a free parameter): Array of Vector2i(kind, index).
    godot::Array get_free_geometry() const;

protected:
    static void _bind_methods();

private:
    size_t new_param(double value);
    double* new_value(int tag, double value, bool driving);
    bool check_ref(const godot::Vector2i& ref) const;
    std::vector<size_t> params_of(const godot::Vector2i& ref) const;
    void prepare();
    GCS::SolveStatus run_solver();
    int to_result(GCS::SolveStatus status) const;

    GCS::Point& point_ref(const godot::Vector2i& ref);
    GCS::Line& line_ref(const godot::Vector2i& ref);
    GCS::Circle& circle_ref(const godot::Vector2i& ref);

    std::unique_ptr<GCS::System> system;
    std::deque<double> params;
    std::vector<bool> param_fixed;
    std::vector<std::pair<size_t, size_t>> point_params;
    std::deque<double> values;
    std::deque<double> drag_params;
    std::map<int, double*> value_by_tag;
    GCS::VEC_pD driven_values;
    std::deque<GCS::Point> points;
    std::deque<GCS::Line> lines;
    std::deque<GCS::Circle> circles;
    std::deque<GCS::Arc> arcs;
    std::deque<GCS::Ellipse> ellipses;
    std::vector<std::pair<int, int>> arc_points;
    std::vector<std::vector<size_t>> circle_params;
    std::vector<std::vector<size_t>> arc_params;
    std::vector<std::vector<size_t>> ellipse_params;
    int next_tag = 1;
    int dof = -1;
    std::vector<int> conflicting;
    std::vector<int> redundant;
    GCS::VEC_pD dependent;
};

}  // namespace holo_forge

VARIANT_ENUM_CAST(holo_forge::CadSketchSolver::Kind);
VARIANT_ENUM_CAST(holo_forge::CadSketchSolver::SolveResult);
