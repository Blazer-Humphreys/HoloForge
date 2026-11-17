#pragma once

#include <string>
#include <vector>

#include <BRepBuilderAPI_MakeShape.hxx>
#include <BRepTools_History.hxx>
#include <TopoDS_Shape.hxx>
#include <gp_Dir.hxx>

#include "cad_shape.h"

namespace holo_forge::naming
{

/// Every face of shape is given name (when it has none yet): start/end caps, primitive sides, ...
struct Role
{
    TopoDS_Shape shape;
    std::string name;
};

/// Names the faces of result: roles first, then names inherited through op's history from the
/// inputs' faces (modified faces keep their name, split faces get "#k"), then faces generated
/// from named input edges ("tag:g(edge)"), then anything left by position ("tag:f#k").
/// Edge names follow from the faces they join. op may be null (no history: same shapes kept).
void name_result(CadShape& result, BRepBuilderAPI_MakeShape* op, const std::vector<const CadShape*>& inputs,
    const std::string& tag, const std::vector<Role>& roles = {});

/// Same as name_result for algorithms that report a BRepTools_History (e.g. merging coplanar faces).
void name_from_history(CadShape& result, const Handle(BRepTools_History)& history, const CadShape& input, const std::string& tag);

/// Edge names: the sorted names of the faces an edge joins ("a|b"), "#k" when repeated.
void name_edges(CadShape& shape);

/// "x+", "y-", ... for a direction mostly along an axis, otherwise "n(x,y,z)" rounded.
std::string direction_name(const gp_Dir& normal);

/// Copies the names of a sub-shape's faces and edges from its parent.
void copy_names(const CadShape& parent, CadShape& part);

}  // namespace holo_forge::naming
