// Phase 8 fix round 1 (verifier B4): CadKernel.transform_shape64 and the rigid check that
// CadMesh.transformed64 shares. See transform64.h for the xform64 layout.

#include "transform64.h"

#include "cad_shape.h"

#include <BRepBuilderAPI_Transform.hxx>
#include <Standard_Failure.hxx>
#include <gp_Trsf.hxx>

#include <algorithm>
#include <cmath>

using namespace godot;

namespace holo_forge::xform64
{

bool rigid(const PackedFloat64Array& m, double out[12], std::string& error)
{
    if (m.size() != 12) {
        error = "The move must be 12 numbers (the basis columns X, Y and Z, then the origin); it has " + std::to_string(m.size()) + ".";
        return false;
    }
    for (int i = 0; i < 12; ++i) {
        out[i] = m[i];
        if (!std::isfinite(out[i])) {
            error = "The move must hold finite numbers.";
            return false;
        }
    }
    double worst = 0.0;
    for (int a = 0; a < 3; ++a) {
        for (int b = 0; b < 3; ++b) {
            const double dot = out[a * 3] * out[b * 3] + out[a * 3 + 1] * out[b * 3 + 1] + out[a * 3 + 2] * out[b * 3 + 2];
            worst = std::max(worst, std::fabs(dot - (a == b ? 1.0 : 0.0)));
        }
    }
    const double det = out[0] * (out[4] * out[8] - out[5] * out[7]) - out[3] * (out[1] * out[8] - out[2] * out[7]) + out[6] * (out[1] * out[5] - out[2] * out[4]);
    if (worst > RIGID_TOLERANCE || det < 0.0) {
        error = "The move must be rigid: a turn without scaling or mirroring, and a shift.";
        return false;
    }
    return true;
}

Ref<CadShape> transform_shape(const Ref<CadShape>& shape, const PackedFloat64Array& m, const std::string& tag, String& error)
{
    (void)tag;  // a rigid move keeps every face and edge: the names are copied, not made
    if (shape.is_null() || shape->is_null()) {
        error = "Nothing to move";
        return Ref<CadShape>();
    }
    double x[12];
    std::string problem;
    if (!rigid(m, x, problem)) {
        error = String(problem.c_str());
        return Ref<CadShape>();
    }
    try {
        // The columns made exactly orthonormal in doubles (Gram-Schmidt; they are within 1e-9),
        // so gp_Trsf takes a pure turn with a scale of 1.
        double c[3][3] = {{x[0], x[1], x[2]}, {x[3], x[4], x[5]}, {x[6], x[7], x[8]}};
        auto dot = [](const double* p, const double* q) { return p[0] * q[0] + p[1] * q[1] + p[2] * q[2]; };
        auto unit = [&](double* p) {
            const double len = std::sqrt(dot(p, p));
            for (int k = 0; k < 3; ++k) {
                p[k] /= len;
            }
        };
        unit(c[0]);
        const double d01 = dot(c[1], c[0]);
        for (int k = 0; k < 3; ++k) {
            c[1][k] -= d01 * c[0][k];
        }
        unit(c[1]);
        c[2][0] = c[0][1] * c[1][2] - c[0][2] * c[1][1];
        c[2][1] = c[0][2] * c[1][0] - c[0][0] * c[1][2];
        c[2][2] = c[0][0] * c[1][1] - c[0][1] * c[1][0];
        gp_Trsf trsf;
        // SetValues takes rows: a_ij is row i, column j; the 4th of each row is the shift.
        trsf.SetValues(c[0][0], c[1][0], c[2][0], x[9],
                       c[0][1], c[1][1], c[2][1], x[10],
                       c[0][2], c[1][2], c[2][2], x[11]);
        trsf.SetScaleFactor(1.0);
        BRepBuilderAPI_Transform maker(shape->get_occ_shape(), trsf, true);
        if (!maker.IsDone()) {
            error = "The move could not be applied to the shape";
            return Ref<CadShape>();
        }
        Ref<CadShape> out = CadShape::wrap(maker.Shape());
        out->face_name_list = shape->face_name_list;
        out->edge_name_list = shape->edge_name_list;
        return out;
    }
    catch (const Standard_Failure& failure) {
        error = String("Transform failed: ") + failure.GetMessageString();
        return Ref<CadShape>();
    }
}

}  // namespace holo_forge::xform64
