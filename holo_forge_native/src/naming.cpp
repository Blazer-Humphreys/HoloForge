#include "naming.h"

#include <algorithm>
#include <cmath>
#include <map>
#include <tuple>

#include <BRepAdaptor_Curve.hxx>
#include <BRepGProp.hxx>
#include <BRep_Tool.hxx>
#include <Standard_Failure.hxx>
#include <GProp_GProps.hxx>
#include <TopExp.hxx>
#include <TopTools_IndexedDataMapOfShapeListOfShape.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <TopTools_ListOfShape.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Face.hxx>

namespace holo_forge::naming
{

namespace
{
using Key = std::tuple<double, double, double>;

Key rounded(const gp_Pnt& p)
{
    auto r = [](double v) { return std::round(v * 1e6) / 1e6; };
    return {r(p.X()), r(p.Y()), r(p.Z())};
}

gp_Pnt face_center(const TopoDS_Shape& face)
{
    GProp_GProps props;
    BRepGProp::SurfaceProperties(face, props);
    return props.CentreOfMass();
}

gp_Pnt edge_middle(const TopoDS_Edge& edge)
{
    BRepAdaptor_Curve curve(edge);
    return curve.Value(0.5 * (curve.FirstParameter() + curve.LastParameter()));
}

/// Gives each name used more than once a "#k" suffix, ordered by position.
void disambiguate(std::vector<std::string>& names, const std::vector<gp_Pnt>& positions)
{
    std::map<std::string, std::vector<size_t>> groups;
    for (size_t i = 0; i < names.size(); ++i) {
        groups[names[i]].push_back(i);
    }
    for (auto& [name, indices] : groups) {
        if (indices.size() < 2) {
            continue;
        }
        std::sort(indices.begin(), indices.end(), [&](size_t a, size_t b) { return rounded(positions[a]) < rounded(positions[b]); });
        for (size_t k = 0; k < indices.size(); ++k) {
            names[indices[k]] = name + "#" + std::to_string(k);
        }
    }
}
}  // namespace

std::string direction_name(const gp_Dir& n)
{
    const char* axes[3] = {"x", "y", "z"};
    const double c[3] = {n.X(), n.Y(), n.Z()};
    for (int i = 0; i < 3; ++i) {
        if (std::abs(c[i]) > 0.999) {
            return std::string(axes[i]) + (c[i] > 0.0 ? "+" : "-");
        }
    }
    char buffer[64];
    std::snprintf(buffer, sizeof(buffer), "n(%.2f,%.2f,%.2f)", c[0], c[1], c[2]);
    return buffer;
}

void name_edges(CadShape& shape)
{
    const TopoDS_Shape& s = shape.get_occ_shape();
    TopTools_IndexedMapOfShape faces;
    TopTools_IndexedMapOfShape edges;
    TopExp::MapShapes(s, TopAbs_FACE, faces);
    TopExp::MapShapes(s, TopAbs_EDGE, edges);
    TopTools_IndexedDataMapOfShapeListOfShape edge_faces;
    TopExp::MapShapesAndAncestors(s, TopAbs_EDGE, TopAbs_FACE, edge_faces);
    std::vector<std::string> names(edges.Extent());
    std::vector<gp_Pnt> middles(edges.Extent());
    for (int i = 1; i <= edges.Extent(); ++i) {
        const TopoDS_Edge& edge = TopoDS::Edge(edges(i));
        std::vector<std::string> parts;
        const int key = edge_faces.FindIndex(edge);
        if (key > 0) {
            for (TopTools_ListOfShape::Iterator it(edge_faces(key)); it.More(); it.Next()) {
                const int f = faces.FindIndex(it.Value());
                std::string face_name = f > 0 && size_t(f - 1) < shape.face_name_list.size() ? shape.face_name_list[f - 1] : "";
                if (face_name.empty()) {
                    face_name = "?";
                }
                if (std::find(parts.begin(), parts.end(), face_name) == parts.end() || parts.size() == 1) {
                    parts.push_back(face_name);
                }
            }
        }
        std::sort(parts.begin(), parts.end());
        std::string joined;
        for (const std::string& p : parts) {
            joined += (joined.empty() ? "" : "|") + p;
        }
        names[i - 1] = joined.empty() ? "free" : joined;
        middles[i - 1] = BRep_Tool::Degenerated(edge) ? gp_Pnt() : edge_middle(edge);
    }
    disambiguate(names, middles);
    shape.edge_name_list = names;
}

void name_result(CadShape& result, BRepBuilderAPI_MakeShape* op, const std::vector<const CadShape*>& inputs,
    const std::string& tag, const std::vector<Role>& roles)
{
    const TopoDS_Shape& s = result.get_occ_shape();
    TopTools_IndexedMapOfShape faces;
    TopExp::MapShapes(s, TopAbs_FACE, faces);
    std::vector<std::string> names(faces.Extent());
    auto assign = [&](const TopoDS_Shape& face, const std::string& name) {
        const int i = faces.FindIndex(face);
        if (i > 0 && names[i - 1].empty()) {
            names[i - 1] = name;
        }
    };
    for (const Role& role : roles) {
        if (role.shape.IsNull()) {
            continue;
        }
        TopTools_IndexedMapOfShape role_faces;
        TopExp::MapShapes(role.shape, TopAbs_FACE, role_faces);
        for (int i = 1; i <= role_faces.Extent(); ++i) {
            assign(role_faces(i), role.name);
        }
    }
    for (const CadShape* input : inputs) {
        if (input == nullptr || input->get_occ_shape().IsNull()) {
            continue;
        }
        TopTools_IndexedMapOfShape in_faces;
        TopExp::MapShapes(input->get_occ_shape(), TopAbs_FACE, in_faces);
        for (int j = 1; j <= in_faces.Extent(); ++j) {
            const std::string name = size_t(j - 1) < input->face_name_list.size() ? input->face_name_list[j - 1] : "";
            if (name.empty()) {
                continue;
            }
            const TopoDS_Shape& face = in_faces(j);
            if (op != nullptr) {
                try {
                    const TopTools_ListOfShape& modified = op->Modified(face);
                    if (!modified.IsEmpty()) {
                        const int count = modified.Extent();
                        int k = 0;
                        for (TopTools_ListOfShape::Iterator it(modified); it.More(); it.Next(), ++k) {
                            TopTools_IndexedMapOfShape pieces;
                            TopExp::MapShapes(it.Value(), TopAbs_FACE, pieces);
                            for (int p = 1; p <= pieces.Extent(); ++p) {
                                assign(pieces(p), count > 1 || pieces.Extent() > 1 ? name + "#" + std::to_string(k + p - 1) : name);
                            }
                        }
                        continue;
                    }
                    if (op->IsDeleted(face)) {
                        continue;
                    }
                }
                catch (const Standard_Failure&) {
                }
            }
            assign(face, name);
        }
    }
    if (op != nullptr) {
        for (const CadShape* input : inputs) {
            if (input == nullptr || input->get_occ_shape().IsNull()) {
                continue;
            }
            TopTools_IndexedMapOfShape in_edges;
            TopExp::MapShapes(input->get_occ_shape(), TopAbs_EDGE, in_edges);
            for (int j = 1; j <= in_edges.Extent(); ++j) {
                const std::string edge_name = size_t(j - 1) < input->edge_name_list.size() ? input->edge_name_list[j - 1] : "e" + std::to_string(j - 1);
                try {
                    const TopTools_ListOfShape& generated = op->Generated(in_edges(j));
                    int k = 0;
                    for (TopTools_ListOfShape::Iterator it(generated); it.More(); it.Next()) {
                        TopTools_IndexedMapOfShape pieces;
                        TopExp::MapShapes(it.Value(), TopAbs_FACE, pieces);
                        for (int p = 1; p <= pieces.Extent(); ++p, ++k) {
                            assign(pieces(p), tag + ":g(" + edge_name + ")" + (k > 0 ? "#" + std::to_string(k) : ""));
                        }
                    }
                }
                catch (const Standard_Failure&) {
                }
            }
        }
    }
    // Anything still unnamed is named by where it is.
    std::vector<std::string> fallback;
    std::vector<gp_Pnt> centers;
    std::vector<size_t> unnamed;
    for (size_t i = 0; i < names.size(); ++i) {
        if (names[i].empty()) {
            unnamed.push_back(i);
            fallback.push_back(tag + ":f");
            centers.push_back(face_center(faces(int(i) + 1)));
        }
    }
    disambiguate(fallback, centers);
    for (size_t k = 0; k < unnamed.size(); ++k) {
        names[unnamed[k]] = fallback[k];
    }
    // Two faces can still share an inherited name (e.g. a face split by a later cut).
    std::vector<gp_Pnt> all_centers(names.size());
    std::map<std::string, int> uses;
    for (const std::string& n : names) {
        uses[n]++;
    }
    bool repeated = false;
    for (auto& [n, count] : uses) {
        repeated = repeated || count > 1;
    }
    if (repeated) {
        for (size_t i = 0; i < names.size(); ++i) {
            all_centers[i] = uses[names[i]] > 1 ? face_center(faces(int(i) + 1)) : gp_Pnt();
        }
        disambiguate(names, all_centers);
    }
    result.face_name_list = names;
    name_edges(result);
}

void name_from_history(CadShape& result, const Handle(BRepTools_History)& history, const CadShape& input, const std::string& tag)
{
    const TopoDS_Shape& s = result.get_occ_shape();
    TopTools_IndexedMapOfShape faces;
    TopExp::MapShapes(s, TopAbs_FACE, faces);
    std::vector<std::string> names(faces.Extent());
    auto assign = [&](const TopoDS_Shape& face, const std::string& name) {
        const int i = faces.FindIndex(face);
        if (i > 0 && names[i - 1].empty()) {
            names[i - 1] = name;
        }
    };
    TopTools_IndexedMapOfShape in_faces;
    TopExp::MapShapes(input.get_occ_shape(), TopAbs_FACE, in_faces);
    for (int j = 1; j <= in_faces.Extent(); ++j) {
        const std::string name = size_t(j - 1) < input.face_name_list.size() ? input.face_name_list[j - 1] : "";
        if (name.empty()) {
            continue;
        }
        const TopoDS_Shape& face = in_faces(j);
        if (!history.IsNull()) {
            const TopTools_ListOfShape& modified = history->Modified(face);
            if (!modified.IsEmpty()) {
                for (TopTools_ListOfShape::Iterator it(modified); it.More(); it.Next()) {
                    assign(it.Value(), name);
                }
                continue;
            }
            if (history->IsRemoved(face)) {
                continue;
            }
        }
        assign(face, name);
    }
    std::vector<std::string> fallback;
    std::vector<gp_Pnt> centers;
    std::vector<size_t> unnamed;
    for (size_t i = 0; i < names.size(); ++i) {
        if (names[i].empty()) {
            unnamed.push_back(i);
            fallback.push_back(tag + ":f");
            centers.push_back(face_center(faces(int(i) + 1)));
        }
    }
    disambiguate(fallback, centers);
    for (size_t k = 0; k < unnamed.size(); ++k) {
        names[unnamed[k]] = fallback[k];
    }
    result.face_name_list = names;
    name_edges(result);
}

void copy_names(const CadShape& parent, CadShape& part)
{
    TopTools_IndexedMapOfShape parent_faces;
    TopTools_IndexedMapOfShape part_faces;
    TopExp::MapShapes(parent.get_occ_shape(), TopAbs_FACE, parent_faces);
    TopExp::MapShapes(part.get_occ_shape(), TopAbs_FACE, part_faces);
    part.face_name_list.assign(part_faces.Extent(), "");
    for (int i = 1; i <= part_faces.Extent(); ++i) {
        const int j = parent_faces.FindIndex(part_faces(i));
        if (j > 0 && size_t(j - 1) < parent.face_name_list.size()) {
            part.face_name_list[i - 1] = parent.face_name_list[j - 1];
        }
    }
    TopTools_IndexedMapOfShape parent_edges;
    TopTools_IndexedMapOfShape part_edges;
    TopExp::MapShapes(parent.get_occ_shape(), TopAbs_EDGE, parent_edges);
    TopExp::MapShapes(part.get_occ_shape(), TopAbs_EDGE, part_edges);
    part.edge_name_list.assign(part_edges.Extent(), "");
    for (int i = 1; i <= part_edges.Extent(); ++i) {
        const int j = parent_edges.FindIndex(part_edges(i));
        if (j > 0 && size_t(j - 1) < parent.edge_name_list.size()) {
            part.edge_name_list[i - 1] = parent.edge_name_list[j - 1];
        }
    }
}

}  // namespace holo_forge::naming
