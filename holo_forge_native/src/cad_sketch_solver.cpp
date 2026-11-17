#include "cad_sketch_solver.h"

#include <cmath>
#include <optional>
#include <set>
#include <string>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

namespace holo_forge
{

namespace
{
/// Same signed point-to-line value planegcs uses: positive when the point is left of the line.
double side_of_line(const GCS::Point& p, const GCS::Line& l)
{
    const double x0 = *p.x, y0 = *p.y;
    const double x1 = *l.p1.x, y1 = *l.p1.y;
    const double x2 = *l.p2.x, y2 = *l.p2.y;
    return -x0 * (y2 - y1) + y0 * (x2 - x1) + x1 * y2 - x2 * y1;
}
}  // namespace

CadSketchSolver::CadSketchSolver()
    : system(std::make_unique<GCS::System>())
{}

CadSketchSolver::~CadSketchSolver() = default;

void CadSketchSolver::clear()
{
    system = std::make_unique<GCS::System>();
    params.clear();
    param_fixed.clear();
    point_params.clear();
    values.clear();
    drag_params.clear();
    value_by_tag.clear();
    driven_values.clear();
    points.clear();
    lines.clear();
    circles.clear();
    arcs.clear();
    ellipses.clear();
    arc_points.clear();
    circle_params.clear();
    arc_params.clear();
    ellipse_params.clear();
    next_tag = 1;
    dof = -1;
    conflicting.clear();
    redundant.clear();
    dependent.clear();
}

size_t CadSketchSolver::new_param(double value)
{
    params.push_back(value);
    param_fixed.push_back(false);
    return params.size() - 1;
}

double* CadSketchSolver::new_value(int tag, double value, bool driving)
{
    values.push_back(value);
    double* slot = &values.back();
    value_by_tag[tag] = slot;
    if (!driving) {
        driven_values.push_back(slot);
    }
    return slot;
}

bool CadSketchSolver::check_ref(const Vector2i& ref) const
{
    size_t count = 0;
    switch (ref.x) {
        case KIND_POINT:
            count = points.size();
            break;
        case KIND_LINE:
            count = lines.size();
            break;
        case KIND_CIRCLE:
            count = circles.size();
            break;
        case KIND_ARC:
            count = arcs.size();
            break;
        case KIND_ELLIPSE:
            count = ellipses.size();
            break;
        default:
            UtilityFunctions::push_error("CadSketchSolver: unknown geometry kind ", ref.x);
            return false;
    }
    if (ref.y < 0 || size_t(ref.y) >= count) {
        UtilityFunctions::push_error("CadSketchSolver: geometry index out of range: ", ref);
        return false;
    }
    return true;
}

GCS::Point& CadSketchSolver::point_ref(const Vector2i& ref)
{
    return points[ref.y];
}

GCS::Line& CadSketchSolver::line_ref(const Vector2i& ref)
{
    return lines[ref.y];
}

GCS::Circle& CadSketchSolver::circle_ref(const Vector2i& ref)
{
    if (ref.x == KIND_ARC) {
        return arcs[ref.y];
    }
    return circles[ref.y];
}

std::vector<size_t> CadSketchSolver::params_of(const Vector2i& ref) const
{
    std::vector<size_t> result;
    switch (ref.x) {
        case KIND_POINT:
            result = {point_params[ref.y].first, point_params[ref.y].second};
            break;
        case KIND_LINE: {
            // A line shares its end points' parameters.
            for (size_t p = 0; p < points.size(); ++p) {
                if (points[p].x == lines[ref.y].p1.x || points[p].x == lines[ref.y].p2.x) {
                    result.push_back(point_params[p].first);
                    result.push_back(point_params[p].second);
                }
            }
            break;
        }
        case KIND_CIRCLE:
            result = circle_params[ref.y];
            break;
        case KIND_ARC:
            result = arc_params[ref.y];
            break;
        case KIND_ELLIPSE:
            result = ellipse_params[ref.y];
            break;
        default:
            break;
    }
    return result;
}

int CadSketchSolver::add_point(const Vector2& position)
{
    return add_point_xy(position.x, position.y);
}

int CadSketchSolver::add_point_xy(double x, double y)
{
    const size_t ix = new_param(x);
    const size_t iy = new_param(y);
    points.emplace_back(&params[ix], &params[iy]);
    point_params.emplace_back(ix, iy);
    return int(points.size()) - 1;
}

void CadSketchSolver::set_point_xy(int point, double x, double y)
{
    if (point < 0 || size_t(point) >= points.size()) {
        return;
    }
    *points[point].x = x;
    *points[point].y = y;
}

PackedFloat64Array CadSketchSolver::get_point_coords() const
{
    PackedFloat64Array coords;
    coords.resize(int64_t(points.size()) * 2);
    for (size_t i = 0; i < points.size(); ++i) {
        coords.set(int64_t(i) * 2, *points[i].x);
        coords.set(int64_t(i) * 2 + 1, *points[i].y);
    }
    return coords;
}

int CadSketchSolver::add_line(int point_a, int point_b)
{
    if (!check_ref(Vector2i(KIND_POINT, point_a)) || !check_ref(Vector2i(KIND_POINT, point_b))) {
        return -1;
    }
    GCS::Line line;
    line.p1 = points[point_a];
    line.p2 = points[point_b];
    lines.push_back(line);
    return int(lines.size()) - 1;
}

int CadSketchSolver::add_circle(int center_point, double radius)
{
    if (!check_ref(Vector2i(KIND_POINT, center_point))) {
        return -1;
    }
    GCS::Circle circle;
    circle.center = points[center_point];
    const size_t r = new_param(radius);
    circle.rad = &params[r];
    circles.push_back(circle);
    circle_params.push_back({point_params[center_point].first, point_params[center_point].second, r});
    return int(circles.size()) - 1;
}

int CadSketchSolver::add_arc(int center_point, double radius, double start_angle, double end_angle, int start_point, int end_point)
{
    if (!check_ref(Vector2i(KIND_POINT, center_point))) {
        return -1;
    }
    const Vector2 center(real_t(*points[center_point].x), real_t(*points[center_point].y));
    const int start = start_point >= 0 && check_ref(Vector2i(KIND_POINT, start_point)) ? start_point
        : add_point(center + Vector2(real_t(std::cos(start_angle) * radius), real_t(std::sin(start_angle) * radius)));
    const int end = end_point >= 0 && check_ref(Vector2i(KIND_POINT, end_point)) ? end_point
        : add_point(center + Vector2(real_t(std::cos(end_angle) * radius), real_t(std::sin(end_angle) * radius)));

    GCS::Arc arc;
    arc.center = points[center_point];
    const size_t r = new_param(radius);
    const size_t a0 = new_param(start_angle);
    const size_t a1 = new_param(end_angle);
    arc.rad = &params[r];
    arc.startAngle = &params[a0];
    arc.endAngle = &params[a1];
    arc.start = points[start];
    arc.end = points[end];
    arcs.push_back(arc);
    arc_points.emplace_back(start, end);
    arc_params.push_back({
        point_params[center_point].first, point_params[center_point].second, r, a0, a1,
        point_params[start].first, point_params[start].second, point_params[end].first, point_params[end].second,
    });
    // Arc rules keep the end points on the circle at the end angles (internal, tag 0).
    system->addConstraintArcRules(arcs.back(), 0, true);
    dof = -1;
    return int(arcs.size()) - 1;
}

int CadSketchSolver::add_ellipse(int center_point, int focus_point, double minor_radius)
{
    if (!check_ref(Vector2i(KIND_POINT, center_point)) || !check_ref(Vector2i(KIND_POINT, focus_point))) {
        return -1;
    }
    GCS::Ellipse ellipse;
    ellipse.center = points[center_point];
    ellipse.focus1 = points[focus_point];
    const size_t r = new_param(minor_radius);
    ellipse.radmin = &params[r];
    ellipses.push_back(ellipse);
    ellipse_params.push_back({
        point_params[center_point].first, point_params[center_point].second,
        point_params[focus_point].first, point_params[focus_point].second, r,
    });
    return int(ellipses.size()) - 1;
}

PackedInt32Array CadSketchSolver::get_arc_end_points(int arc) const
{
    PackedInt32Array result;
    if (arc >= 0 && size_t(arc) < arc_points.size()) {
        result.push_back(arc_points[arc].first);
        result.push_back(arc_points[arc].second);
    }
    return result;
}

void CadSketchSolver::set_fixed(const Vector2i& ref, bool fixed)
{
    if (!check_ref(ref)) {
        return;
    }
    for (size_t i : params_of(ref)) {
        param_fixed[i] = fixed;
    }
    dof = -1;
}

void CadSketchSolver::set_point_fixed(int point, bool fixed)
{
    set_fixed(Vector2i(KIND_POINT, point), fixed);
}

Vector2 CadSketchSolver::get_point(int point) const
{
    if (point < 0 || size_t(point) >= points.size()) {
        return Vector2();
    }
    return Vector2(real_t(*points[point].x), real_t(*points[point].y));
}

void CadSketchSolver::set_point(int point, const Vector2& position)
{
    if (point < 0 || size_t(point) >= points.size()) {
        return;
    }
    *points[point].x = position.x;
    *points[point].y = position.y;
}

double CadSketchSolver::get_circle_radius(int circle) const
{
    return circle >= 0 && size_t(circle) < circles.size() ? *circles[circle].rad : 0.0;
}

double CadSketchSolver::get_arc_radius(int arc) const
{
    return arc >= 0 && size_t(arc) < arcs.size() ? *arcs[arc].rad : 0.0;
}

Vector2 CadSketchSolver::get_arc_angles(int arc) const
{
    if (arc < 0 || size_t(arc) >= arcs.size()) {
        return Vector2();
    }
    return Vector2(real_t(*arcs[arc].startAngle), real_t(*arcs[arc].endAngle));
}

double CadSketchSolver::get_ellipse_minor_radius(int ellipse) const
{
    return ellipse >= 0 && size_t(ellipse) < ellipses.size() ? *ellipses[ellipse].radmin : 0.0;
}

int CadSketchSolver::add_constraint(const String& type, const Array& refs, double value, bool driving)
{
    std::vector<Vector2i> r;
    for (int64_t i = 0; i < refs.size(); ++i) {
        const Variant v = refs[i];
        if (v.get_type() != Variant::VECTOR2I) {
            UtilityFunctions::push_error("CadSketchSolver.add_constraint: references must be Vector2i(kind, index)");
            return -1;
        }
        const Vector2i ref = v;
        if (!check_ref(ref)) {
            return -1;
        }
        r.push_back(ref);
    }
    auto kinds = [&](std::initializer_list<int> wanted) -> bool {
        if (r.size() != wanted.size()) {
            return false;
        }
        size_t i = 0;
        for (int k : wanted) {
            if (r[i++].x != k) {
                return false;
            }
        }
        return true;
    };
    auto round = [&](size_t i) -> bool { return i < r.size() && (r[i].x == KIND_CIRCLE || r[i].x == KIND_ARC); };
    auto has_center = [&](size_t i) -> bool { return round(i) || (i < r.size() && r[i].x == KIND_ELLIPSE); };
    auto center = [&](size_t i) -> GCS::Point& { return r[i].x == KIND_ELLIPSE ? ellipses[r[i].y].center : circle_ref(r[i]).center; };

    GCS::System& s = *system;
    const int tag = next_tag;
    const std::string t = type.utf8().get_data();
    bool done = true;

    if (t == "coincident" && kinds({KIND_POINT, KIND_POINT})) {
        s.addConstraintP2PCoincident(point_ref(r[0]), point_ref(r[1]), tag);
    }
    else if ((t == "horizontal" || t == "vertical") && kinds({KIND_LINE})) {
        t == "horizontal" ? s.addConstraintHorizontal(line_ref(r[0]), tag) : s.addConstraintVertical(line_ref(r[0]), tag);
    }
    else if ((t == "horizontal" || t == "vertical") && kinds({KIND_POINT, KIND_POINT})) {
        t == "horizontal" ? s.addConstraintHorizontal(point_ref(r[0]), point_ref(r[1]), tag)
                          : s.addConstraintVertical(point_ref(r[0]), point_ref(r[1]), tag);
    }
    else if (t == "parallel" && kinds({KIND_LINE, KIND_LINE})) {
        s.addConstraintParallel(line_ref(r[0]), line_ref(r[1]), tag);
    }
    else if (t == "perpendicular" && kinds({KIND_LINE, KIND_LINE})) {
        s.addConstraintPerpendicular(line_ref(r[0]), line_ref(r[1]), tag);
    }
    else if (t == "point_on" && r.size() == 2 && r[0].x == KIND_POINT) {
        GCS::Point& p = point_ref(r[0]);
        switch (r[1].x) {
            case KIND_POINT:
                s.addConstraintP2PCoincident(p, point_ref(r[1]), tag);
                break;
            case KIND_LINE:
                s.addConstraintPointOnLine(p, line_ref(r[1]), tag);
                break;
            case KIND_CIRCLE:
                s.addConstraintPointOnCircle(p, circles[r[1].y], tag);
                break;
            case KIND_ARC:
                s.addConstraintPointOnArc(p, arcs[r[1].y], tag);
                break;
            case KIND_ELLIPSE:
                s.addConstraintPointOnEllipse(p, ellipses[r[1].y], tag);
                break;
            default:
                done = false;
        }
    }
    else if (t == "midpoint" && kinds({KIND_POINT, KIND_LINE})) {
        s.addConstraintP2PSymmetric(line_ref(r[1]).p1, line_ref(r[1]).p2, point_ref(r[0]), tag);
    }
    else if (t == "symmetric" && kinds({KIND_POINT, KIND_POINT, KIND_LINE})) {
        s.addConstraintP2PSymmetric(point_ref(r[0]), point_ref(r[1]), line_ref(r[2]), tag);
    }
    else if (t == "symmetric" && kinds({KIND_POINT, KIND_POINT, KIND_POINT})) {
        s.addConstraintP2PSymmetric(point_ref(r[0]), point_ref(r[1]), point_ref(r[2]), tag);
    }
    else if (t == "equal" && kinds({KIND_LINE, KIND_LINE})) {
        s.addConstraintEqualLength(line_ref(r[0]), line_ref(r[1]), tag);
    }
    else if (t == "equal" && round(0) && round(1) && r.size() == 2) {
        if (r[0].x == KIND_CIRCLE && r[1].x == KIND_CIRCLE) {
            s.addConstraintEqualRadius(circles[r[0].y], circles[r[1].y], tag);
        }
        else if (r[0].x == KIND_ARC && r[1].x == KIND_ARC) {
            s.addConstraintEqualRadius(arcs[r[0].y], arcs[r[1].y], tag);
        }
        else {
            const size_t c = r[0].x == KIND_CIRCLE ? 0 : 1;
            s.addConstraintEqualRadius(circles[r[c].y], arcs[r[1 - c].y], tag);
        }
    }
    else if (t == "equal" && kinds({KIND_ELLIPSE, KIND_ELLIPSE})) {
        s.addConstraintEqualRadii(ellipses[r[0].y], ellipses[r[1].y], tag);
    }
    else if (t == "concentric" && r.size() == 2 && has_center(0) && has_center(1)) {
        s.addConstraintP2PCoincident(center(0), center(1), tag);
    }
    else if (t == "collinear" && kinds({KIND_LINE, KIND_LINE})) {
        s.addConstraintPointOnLine(line_ref(r[1]).p1, line_ref(r[0]), tag);
        s.addConstraintPointOnLine(line_ref(r[1]).p2, line_ref(r[0]), tag);
    }
    else if (t == "tangent" && r.size() == 2) {
        const bool line_first = r[0].x == KIND_LINE;
        const bool line_second = r[1].x == KIND_LINE;
        if (line_first != line_second) {
            GCS::Line& l = line_ref(line_first ? r[0] : r[1]);
            const Vector2i other = line_first ? r[1] : r[0];
            if (other.x == KIND_CIRCLE) {
                s.addConstraintTangent(l, circles[other.y], side_of_line(circles[other.y].center, l) >= 0.0, tag);
            }
            else if (other.x == KIND_ARC) {
                s.addConstraintTangent(l, arcs[other.y], side_of_line(arcs[other.y].center, l) >= 0.0, tag);
            }
            else if (other.x == KIND_ELLIPSE) {
                s.addConstraintTangent(l, ellipses[other.y], tag);
            }
            else {
                done = false;
            }
        }
        else if (round(0) && round(1)) {
            if (r[0].x == KIND_CIRCLE && r[1].x == KIND_CIRCLE) {
                s.addConstraintTangent(circles[r[0].y], circles[r[1].y], tag);
            }
            else if (r[0].x == KIND_ARC && r[1].x == KIND_ARC) {
                s.addConstraintTangent(arcs[r[0].y], arcs[r[1].y], tag);
            }
            else {
                const size_t c = r[0].x == KIND_CIRCLE ? 0 : 1;
                s.addConstraintTangent(circles[r[c].y], arcs[r[1 - c].y], tag);
            }
        }
        else {
            done = false;
        }
    }
    else if (t == "distance" && kinds({KIND_POINT, KIND_POINT})) {
        s.addConstraintP2PDistance(point_ref(r[0]), point_ref(r[1]), new_value(tag, value, driving), tag, driving);
    }
    else if (t == "distance" && r.size() == 2 && ((r[0].x == KIND_POINT && r[1].x == KIND_LINE) || (r[0].x == KIND_LINE && r[1].x == KIND_POINT))) {
        GCS::Point& p = point_ref(r[0].x == KIND_POINT ? r[0] : r[1]);
        GCS::Line& l = line_ref(r[0].x == KIND_LINE ? r[0] : r[1]);
        s.addConstraintP2LDistance(p, l, new_value(tag, value, driving), side_of_line(p, l) >= 0.0, tag, driving);
    }
    else if (t == "distance" && kinds({KIND_LINE, KIND_LINE})) {
        GCS::Line& l = line_ref(r[0]);
        GCS::Point& p = line_ref(r[1]).p1;
        s.addConstraintP2LDistance(p, l, new_value(tag, value, driving), side_of_line(p, l) >= 0.0, tag, driving);
    }
    else if (t == "distance" && r.size() == 2 && ((r[0].x == KIND_POINT && round(1)) || (round(0) && r[1].x == KIND_POINT))) {
        GCS::Point& p = point_ref(r[0].x == KIND_POINT ? r[0] : r[1]);
        GCS::Circle& c = circle_ref(r[0].x == KIND_POINT ? r[1] : r[0]);
        s.addConstraintP2CDistance(p, c, new_value(tag, value, driving), tag, driving);
    }
    else if (t == "distance" && round(0) && round(1) && r.size() == 2) {
        s.addConstraintC2CDistance(circle_ref(r[0]), circle_ref(r[1]), new_value(tag, value, driving), std::nullopt, tag, driving);
    }
    else if (t == "distance" && r.size() == 2 && ((round(0) && r[1].x == KIND_LINE) || (r[0].x == KIND_LINE && round(1)))) {
        GCS::Circle& c = circle_ref(round(0) ? r[0] : r[1]);
        GCS::Line& l = line_ref(round(0) ? r[1] : r[0]);
        s.addConstraintC2LDistance(c, l, new_value(tag, value, driving), side_of_line(c.center, l) >= 0.0, false, tag, driving);
    }
    else if ((t == "distance_x" || t == "distance_y") && kinds({KIND_POINT, KIND_POINT})) {
        GCS::Point& a = point_ref(r[0]);
        GCS::Point& b = point_ref(r[1]);
        double* v = new_value(tag, value, driving);
        t == "distance_x" ? s.addConstraintDifference(a.x, b.x, v, tag, driving) : s.addConstraintDifference(a.y, b.y, v, tag, driving);
    }
    else if ((t == "coordinate_x" || t == "coordinate_y") && kinds({KIND_POINT})) {
        double* v = new_value(tag, value, driving);
        t == "coordinate_x" ? s.addConstraintCoordinateX(point_ref(r[0]), v, tag, driving)
                            : s.addConstraintCoordinateY(point_ref(r[0]), v, tag, driving);
    }
    else if ((t == "radius" || t == "diameter") && r.size() == 1 && round(0)) {
        double* v = new_value(tag, value, driving);
        if (r[0].x == KIND_CIRCLE) {
            t == "radius" ? s.addConstraintCircleRadius(circles[r[0].y], v, tag, driving)
                          : s.addConstraintCircleDiameter(circles[r[0].y], v, tag, driving);
        }
        else {
            t == "radius" ? s.addConstraintArcRadius(arcs[r[0].y], v, tag, driving)
                          : s.addConstraintArcDiameter(arcs[r[0].y], v, tag, driving);
        }
    }
    else if (t == "angle" && kinds({KIND_LINE, KIND_LINE})) {
        s.addConstraintL2LAngle(line_ref(r[0]), line_ref(r[1]), new_value(tag, value, driving), tag, driving);
    }
    else if (t == "arc_length" && kinds({KIND_ARC})) {
        s.addConstraintArcLength(arcs[r[0].y], new_value(tag, value, driving), tag, driving);
    }
    else if (t == "length" && kinds({KIND_LINE})) {
        s.addConstraintP2PDistance(line_ref(r[0]).p1, line_ref(r[0]).p2, new_value(tag, value, driving), tag, driving);
    }
    else {
        done = false;
    }

    if (!done) {
        UtilityFunctions::push_error("CadSketchSolver.add_constraint: '", type, "' does not apply to these references");
        return -1;
    }
    next_tag++;
    dof = -1;
    return tag;
}

bool CadSketchSolver::set_constraint_value(int tag, double value)
{
    auto found = value_by_tag.find(tag);
    if (found == value_by_tag.end()) {
        UtilityFunctions::push_error("CadSketchSolver.set_constraint_value: no dimension with tag ", tag);
        return false;
    }
    *found->second = value;
    return true;
}

double CadSketchSolver::get_constraint_value(int tag) const
{
    auto found = value_by_tag.find(tag);
    return found == value_by_tag.end() ? std::nan("") : *found->second;
}

void CadSketchSolver::prepare()
{
    GCS::VEC_pD unknowns;
    for (size_t i = 0; i < params.size(); ++i) {
        if (!param_fixed[i]) {
            unknowns.push_back(&params[i]);
        }
    }
    system->invalidatedDiagnosis();
    system->declareUnknowns(unknowns);
    system->declareDrivenParams(driven_values);
    system->initSolution(GCS::DogLeg);
    dof = system->dofsNumber();
    conflicting.clear();
    redundant.clear();
    dependent.clear();
    system->getConflicting(conflicting);
    system->getRedundant(redundant);
    system->getDependentParams(dependent);
}

GCS::SolveStatus CadSketchSolver::run_solver()
{
    GCS::SolveStatus status = system->solve(GCS::DogLeg);
    if (status != GCS::SolveStatus::Success && status != GCS::SolveStatus::Converged) {
        // DogLeg occasionally stalls on large moves; Levenberg-Marquardt is the fallback.
        system->undoSolution();
        system->initSolution(GCS::LevenbergMarquardt);
        status = system->solve(GCS::LevenbergMarquardt);
    }
    if (status == GCS::SolveStatus::Success || status == GCS::SolveStatus::Converged) {
        system->applySolution();
        system->evaluateDrivenConstraints();
    }
    else {
        system->undoSolution();
    }
    return status;
}

int CadSketchSolver::to_result(GCS::SolveStatus status) const
{
    switch (status) {
        case GCS::SolveStatus::Success:
            return SOLVE_SUCCESS;
        case GCS::SolveStatus::Converged:
            return SOLVE_CONVERGED;
        case GCS::SolveStatus::SuccessfulSolutionInvalid:
            return SOLVE_INVALID;
        default:
            return SOLVE_FAILED;
    }
}

int CadSketchSolver::solve()
{
    prepare();
    return to_result(run_solver());
}

int CadSketchSolver::drag_point(int point, const Vector2& target)
{
    if (point < 0 || size_t(point) >= points.size()) {
        return SOLVE_FAILED;
    }
    // A temporary, soft constraint (negative tag) pulls the point toward the mouse while every
    // real constraint stays satisfied.
    drag_params.clear();
    drag_params.push_back(target.x);
    drag_params.push_back(target.y);
    GCS::Point goal(&drag_params[0], &drag_params[1]);
    system->clearByTag(-1);
    system->addConstraintP2PCoincident(points[point], goal, -1);
    const int saved_dof = dof;
    prepare();
    const GCS::SolveStatus status = run_solver();
    system->clearByTag(-1);
    dof = saved_dof;
    return to_result(status);
}

int CadSketchSolver::get_dof() const
{
    return dof;
}

PackedInt32Array CadSketchSolver::get_conflicting() const
{
    PackedInt32Array result;
    for (int tag : conflicting) {
        result.push_back(tag);
    }
    return result;
}

PackedInt32Array CadSketchSolver::get_redundant() const
{
    PackedInt32Array result;
    for (int tag : redundant) {
        result.push_back(tag);
    }
    return result;
}

Array CadSketchSolver::get_free_geometry() const
{
    std::set<const double*> free(dependent.begin(), dependent.end());
    Array result;
    auto check = [&](int kind, size_t count) {
        for (size_t i = 0; i < count; ++i) {
            const Vector2i ref(kind, int(i));
            for (size_t p : params_of(ref)) {
                if (!param_fixed[p] && free.count(&params[p])) {
                    result.push_back(ref);
                    break;
                }
            }
        }
    };
    check(KIND_POINT, points.size());
    check(KIND_LINE, lines.size());
    check(KIND_CIRCLE, circles.size());
    check(KIND_ARC, arcs.size());
    check(KIND_ELLIPSE, ellipses.size());
    return result;
}

void CadSketchSolver::_bind_methods()
{
    ClassDB::bind_method(D_METHOD("clear"), &CadSketchSolver::clear);
    ClassDB::bind_method(D_METHOD("add_point", "position"), &CadSketchSolver::add_point);
    ClassDB::bind_method(D_METHOD("add_line", "point_a", "point_b"), &CadSketchSolver::add_line);
    ClassDB::bind_method(D_METHOD("add_circle", "center_point", "radius"), &CadSketchSolver::add_circle);
    ClassDB::bind_method(
        D_METHOD("add_arc", "center_point", "radius", "start_angle", "end_angle", "start_point", "end_point"),
        &CadSketchSolver::add_arc,
        DEFVAL(-1),
        DEFVAL(-1)
    );
    ClassDB::bind_method(D_METHOD("add_ellipse", "center_point", "focus_point", "minor_radius"), &CadSketchSolver::add_ellipse);
    ClassDB::bind_method(D_METHOD("get_arc_end_points", "arc"), &CadSketchSolver::get_arc_end_points);
    ClassDB::bind_method(D_METHOD("set_fixed", "ref", "fixed"), &CadSketchSolver::set_fixed);
    ClassDB::bind_method(D_METHOD("set_point_fixed", "point", "fixed"), &CadSketchSolver::set_point_fixed);
    ClassDB::bind_method(D_METHOD("get_point", "point"), &CadSketchSolver::get_point);
    ClassDB::bind_method(D_METHOD("set_point", "point", "position"), &CadSketchSolver::set_point);
    ClassDB::bind_method(D_METHOD("add_point_xy", "x", "y"), &CadSketchSolver::add_point_xy);
    ClassDB::bind_method(D_METHOD("set_point_xy", "point", "x", "y"), &CadSketchSolver::set_point_xy);
    ClassDB::bind_method(D_METHOD("get_point_coords"), &CadSketchSolver::get_point_coords);
    ClassDB::bind_method(D_METHOD("get_circle_radius", "circle"), &CadSketchSolver::get_circle_radius);
    ClassDB::bind_method(D_METHOD("get_arc_radius", "arc"), &CadSketchSolver::get_arc_radius);
    ClassDB::bind_method(D_METHOD("get_arc_angles", "arc"), &CadSketchSolver::get_arc_angles);
    ClassDB::bind_method(D_METHOD("get_ellipse_minor_radius", "ellipse"), &CadSketchSolver::get_ellipse_minor_radius);
    ClassDB::bind_method(
        D_METHOD("add_constraint", "type", "refs", "value", "driving"),
        &CadSketchSolver::add_constraint,
        DEFVAL(0.0),
        DEFVAL(true)
    );
    ClassDB::bind_method(D_METHOD("set_constraint_value", "tag", "value"), &CadSketchSolver::set_constraint_value);
    ClassDB::bind_method(D_METHOD("get_constraint_value", "tag"), &CadSketchSolver::get_constraint_value);
    ClassDB::bind_method(D_METHOD("solve"), &CadSketchSolver::solve);
    ClassDB::bind_method(D_METHOD("drag_point", "point", "target"), &CadSketchSolver::drag_point);
    ClassDB::bind_method(D_METHOD("get_dof"), &CadSketchSolver::get_dof);
    ClassDB::bind_method(D_METHOD("get_conflicting"), &CadSketchSolver::get_conflicting);
    ClassDB::bind_method(D_METHOD("get_redundant"), &CadSketchSolver::get_redundant);
    ClassDB::bind_method(D_METHOD("get_free_geometry"), &CadSketchSolver::get_free_geometry);

    BIND_ENUM_CONSTANT(KIND_POINT);
    BIND_ENUM_CONSTANT(KIND_LINE);
    BIND_ENUM_CONSTANT(KIND_CIRCLE);
    BIND_ENUM_CONSTANT(KIND_ARC);
    BIND_ENUM_CONSTANT(KIND_ELLIPSE);
    BIND_ENUM_CONSTANT(SOLVE_SUCCESS);
    BIND_ENUM_CONSTANT(SOLVE_CONVERGED);
    BIND_ENUM_CONSTANT(SOLVE_FAILED);
    BIND_ENUM_CONSTANT(SOLVE_INVALID);
}

}  // namespace holo_forge
