#pragma once

#include <vector>

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/transform3d.hpp>

#include <Geom2d_Curve.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Shape.hxx>
#include <gp_Pln.hxx>

namespace holo_forge::sketch
{

/// Sketch curves are dictionaries in plane coordinates (u along the plane's X, v along its Y):
///   {"type": "line", "a": Vector2, "b": Vector2}
///   {"type": "circle", "c": Vector2, "r": float}
///   {"type": "arc", "c": Vector2, "r": float, "a0": float, "a1": float}   counter-clockwise
///   {"type": "ellipse", "c": Vector2, "major": Vector2 (direction * major radius), "minor": float}
///   {"type": "ellipse_arc", ... ellipse keys, "a0", "a1"}                eccentric angles, ccw
///   {"type": "bspline", "poles": PackedVector2Array, "degree": int, "weights"?, "knots"?, "mults"?, "periodic"?}
///   {"type": "interp", "points": PackedVector2Array, "periodic": bool}  fit-point spline
///   {"type": "conic", "a": Vector2, "b": Vector2, "shoulder": Vector2, "weight": float}
///   {"type": "polyline", "points": PackedVector2Array, "closed": bool}
/// A plane is a Transform3D: origin, X and Y in the plane, Z its normal.

gp_Pln to_plane(const godot::Transform3D& plane);

/// The 2D curves a dictionary describes (a polyline gives one curve per segment).
std::vector<Handle(Geom2d_Curve)> curves_from_dict(const godot::Dictionary& curve, godot::String& error);

/// Exact edges of the curves on the plane.
/// entities, when given, receives each edge's sketch entity id (the curve's "entity", or -1).
std::vector<TopoDS_Edge> edges_on_plane(const godot::Array& curves, const gp_Pln& plane, godot::String& error, std::vector<int>* entities = nullptr);

/// A 3D edge as a sketch curve dictionary in plane coordinates.
godot::Dictionary edge_to_curve(const TopoDS_Edge& edge, const gp_Pln& plane);

/// Closed regions bounded by the curves: [{"face", "area", "loops": [outer, holes...]}].
godot::Array regions(const godot::Array& curves, const gp_Pln& plane, double deflection, godot::String& error);

/// Where two curves cross: {"points", "params_a", "params_b"} (line params run 0..1).
godot::Dictionary intersections(const godot::Dictionary& a, const godot::Dictionary& b, godot::String& error);

/// The nearest point on a curve: {"point", "param", "distance"} (line params run 0..1).
godot::Dictionary closest_point(const godot::Dictionary& curve, const godot::Vector2& point, godot::String& error);

/// Points along a curve, close to it within deflection.
godot::PackedVector2Array sample(const godot::Dictionary& curve, double deflection, godot::String& error);

/// Offsets a connected chain of curves by distance (signed); returns curve dictionaries.
godot::Array offset(const godot::Array& chain, double distance, godot::String& error);

/// Body edges projected straight onto the plane, as curve dictionaries (or points).
godot::Array project_edges(const TopoDS_Shape& shape, const std::vector<int>& edge_ids, const gp_Pln& plane, godot::String& error);

/// Where the plane cuts the shape, as curve dictionaries.
godot::Array section(const TopoDS_Shape& shape, const gp_Pln& plane, godot::String& error);

/// 3D polylines: sketch curves wrapped onto faces along a direction (or the plane normal).
godot::Array project_to_faces(const godot::Array& curves, const gp_Pln& plane, const TopoDS_Shape& shape,
    const std::vector<int>& face_ids, const godot::Vector3& direction, double deflection, godot::String& error);

/// 3D polylines where the sketch curves, swept along the plane normal, meet the faces.
godot::Array intersection_curves(const godot::Array& curves, const gp_Pln& plane, const TopoDS_Shape& shape,
    const std::vector<int>& face_ids, double deflection, godot::String& error);

/// 3D polylines along a face's U (direction 0) or V (direction 1) at normalized parameters.
godot::Array isocurves(const TopoDS_Shape& shape, int face_id, int direction, const std::vector<double>& params,
    double deflection, godot::String& error);

}  // namespace holo_forge::sketch
