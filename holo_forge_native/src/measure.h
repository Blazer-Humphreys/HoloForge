#pragma once

#include <Bnd_Box.hxx>
#include <GProp_GProps.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Shape.hxx>
#include <gp_Pnt.hxx>
#include <gp_Trsf.hxx>

#include <vector>

namespace holo_forge::measure
{

/// Volume, centre and inertia of a shape's closed shells (as BRepGProp::VolumeProperties with
/// OnlyClosed). Each face is integrated over its own boundary, split wherever its surface or an edge's
/// curve changes piece, so spline faces come out as exact as analytic ones (OCCT's fixed-order rule
/// misread spline-bounded solids by up to a fifth).
GProp_GProps volume(const TopoDS_Shape& shape);

/// Area, centre and inertia of a shape's faces (as BRepGProp::SurfaceProperties), integrated the same
/// way.
GProp_GProps surface(const TopoDS_Shape& shape);

/// The UV box of a face's edges' own curves within its surface's bounds (BRepTools::UVBounds boxes
/// their control points, which can reach well past them). False for a face with no edge curves.
bool uv_bounds(const TopoDS_Face& face, double& u1, double& u2, double& v1, double& v2);

/// A box around the whole shape: every face's edges, and where a face bulges past them (a dome, a
/// bowl) the face's own highest and lowest points, found from points sampled inside it. OCCT's
/// precise box trims a face to its edges wherever a numeric search says nothing lies beyond them,
/// and the search can be wrong (a plate bowl came out flat).
Bnd_Box box(const TopoDS_Shape& shape);

/// An edge's length, integrated a piece of its curve at a time (an ellipse's quarters too), each
/// piece halved until two rules agree to rounding (OCCT's fixed-order rule read a 10 x 1 mm
/// ellipse 1.5 % long). 0 for a degenerate edge.
double length(const TopoDS_Edge& edge);

/// The curve parameter of an edge at distance along it from its curve's first parameter (exact to
/// rounding, by length as above).
double parameter_at_length(const TopoDS_Edge& edge, double distance);

/// A copy of shape scaled by trsf, for measuring at another size, whose faces keep their own
/// tolerances: OCCT's face classifier reads a face's tolerance in its surface's parameters, which
/// scaling leaves as they were on a spline, so a thousandfold scaled tolerance put every point within
/// 1 % of a plate's size of its rim on the rim.
TopoDS_Shape scaled_copy(const TopoDS_Shape& shape, const gp_Trsf& trsf);

/// The area a meshed face's triangles cover, -1 when it has no mesh.
double mesh_area(const TopoDS_Face& face);

/// Whether a meshed shape's faces' meshes fit together: along every edge two of its faces share,
/// both faces' meshes run through the same points of the edge. The mesher makes them so when it
/// meshes the faces together, and leaves them be when it finds them meshed already: a face the
/// shape shares with another shape (a cut's or a fillet's result keeps the faces the tool left
/// alone) that was meshed again there, finer, then meets the shape's other faces along its own
/// finer points, and the shape is drawn with open edges all along them (a plate with a hole,
/// filleted, the fillet exported: the plate drawn again with 168 open edges; a cross-drilled
/// block: 504), with no warning.
bool mesh_fits_together(const TopoDS_Shape& shape);

/// How far a face's edges stray from it: the most, over its edges, of the gap between an edge's
/// ends and the corners (vertices) it joins, and of the gap between an edge's own curve and the
/// face's surface at the edge's curve on it (at the same parameter, as the mesher pairs them;
/// sampled). OCCT's blends at loose tolerances can leave a corner millimetres from the edges that
/// meet there, held together by the corner's tolerance alone: a body its own checks pass, whose
/// mesh (a node at the corner, the rest on the faces) is pulled off its faces around it. at, when
/// given, takes where; corner whether that is a corner off its edge's end (else an edge off the
/// surface).
double edge_stray(const TopoDS_Face& face, gp_Pnt* at = nullptr, bool* corner = nullptr);

/// How much of a face its surface holds folded over itself: the area of the cells, of a grid over
/// the face's parameters, whose normal points against a neighbouring cell's and whose middle lies
/// in the face (0 for a sound surface, whose normal turns a little from cell to cell). OCCT's
/// blends can fit a fillet's surface with a wrinkle in it (3.8 mm on a 20 mm spline body, fitted
/// to 0.01 mm: 1.3 mm2 of a 48 mm2 fillet face back to front), which the face's own area, OCCT's
/// measure of it and its mesh then all read differently (48.6, 46.1 and 53.9 mm2). at, when
/// given, takes a place where it folds.
double fold_area(const TopoDS_Face& face, gp_Pnt* at = nullptr);

/// Whether a meshed face's triangles cover the face's own area (as surface() measures it), within
/// what a mesh at deflection and angle (rad) can be off by: a face whose wires the mesher misreads
/// (a hole that touches its outer wire) is meshed with a lid over the hole or with a piece left
/// out, while the face itself is right. On a face that isn't flat or elementary (a spline) the
/// mesh's nodes must also lie on the face, to within stray_limit (four deflections when negative;
/// stray, when given, takes how far off they are: a corner off its edges pulls the mesh around it
/// off the face), and its area is measured only where its wires could be misread (more than one
/// wire, or one that isn't a plain loop), or always when every_area is set: a spline face's area
/// takes milliseconds to measure, a body of them as long as meshing it. False for a face with no
/// mesh at all (it is left out of what is drawn), unless the face has next to no area (four
/// deflections squared); meshed is then -1. What the mesh may miss comes from the face's own
/// edges and the deflection and angle asked for, never from the mesh being judged, and is at most
/// three tenths of the face. face_area and meshed, when given, take the two areas (face_area only
/// when measured).
bool mesh_covers_face(const TopoDS_Face& face, double deflection, double angle, double* face_area = nullptr, double* meshed = nullptr, double* stray = nullptr,
                      double stray_limit = -1.0, bool every_area = false);

/// A flat face whose mesh doesn't cover it (mesh_covers_face) remade as faces the mesher reads
/// right, each meshed at deflection and angle and covering itself: the face of its outer wire less
/// a slab through it the shape of each other wire (a hole touching the outer wire, as a rim's does
/// where an opening runs up to a wall, is misread: a lid over it or part of the rim left out), with
/// the face's orientation. Empty when it isn't flat or they don't hold its own area (own_area).
std::vector<TopoDS_Face> flat_face_pieces(const TopoDS_Face& face, double own_area, double deflection, double angle);

/// Whether a meshed face is drawn as it is: its mesh covers it (mesh_covers_face), or it is a flat
/// face whose pieces do (flat_face_pieces), which CadShape.tessellate and the STL export draw
/// instead. face_area, meshed, stray, stray_limit and every_area as mesh_covers_face's.
bool face_drawable(const TopoDS_Face& face, double deflection, double angle, double* face_area = nullptr, double* meshed = nullptr, double* stray = nullptr,
                   double stray_limit = -1.0, bool every_area = false);

}  // namespace holo_forge::measure
