#pragma once

#include <vector>

#include <TopTools_MapOfShape.hxx>
#include <TopoDS_Face.hxx>
#include <gp_Pnt.hxx>

#include "solid_ops.h"

namespace holo_forge::ops
{

/// Surface operations behind the Surface workspace: they make and edit open shells (surface
/// bodies). Same conventions as solid_ops.h: options in a Dictionary (with "tag"), a named result,
/// error set and a null result when the kernel can't do it.

/// A face filling a closed boundary. boundary: [{"shape": CadShape, "edges": PackedInt32Array
/// (empty: every edge of the shape), "continuity": 0 | 1, "edge_continuity": optional, one per
/// edge id, "outline": true for a profile's outline (its own face isn't one to carry on)}]: G1
/// keeps the patch tangent to the edge's face in that shape (the one away from the loop's
/// inside); an edge with no such face is built G0 and note says how many were; 2 (curvature) is
/// refused along a face (an edge with none builds G0 as for G1). points: extra points the patch
/// passes through; "rails": [{"shape", "edges"}], curves inside it that it runs along. A flat
/// boundary (G0, or G1 to faces in its plane) with no points or rails gives an exact plane; one
/// of three or four sides (split at its corners) a Coons surface the face fills, named
/// "<tag>:patch", and one with fewer corners a lens (two sides between collapsed ends) named so
/// too; anything else a plate trimmed from a bigger surface, named "<tag>:plate" (a mean plane
/// bent to the constraints, so it can't rise steeply off G1 faces). A plate may miss a sharply
/// bent rail or point by up to a hundredth of the patch's size (note gives the largest miss);
/// farther is refused. Refused too: a patch that would crease, pass out beyond the faces round
/// it (fold over, bulge out), run back down along a G1 face instead of carrying it on, or dip
/// below its edges where the faces rise up to them. A G1 patch that turns off its faces somewhere
/// (near a corner where two G1 faces meet no smooth patch carries both on) says in note along what
/// share of its G1 edges it is tangent and how far it turns off, and how far it faces back down
/// past their lean if it does; one passing out past the plane of one of its G1 faces says how far.
/// The shapes given are left as they were (it works on copies).
Shape patch(const godot::Array& boundary, const godot::PackedVector3Array& points, const godot::Dictionary& p, godot::String& error, godot::String& note);

/// Ruled faces growing from edges of shape, "distance" long, along "type": tangent (along the
/// edge's face, away from it) | normal (the face's normal) | direction ("direction"), turned by
/// "angle" about the edge (tangent strips up toward the face's normal, normal ones out away from
/// the face, alike all along a chain); "flip" turns them the other way, "alternate" uses the
/// edge's other face. Where picked edges meet, "corner_type" mitered (the default: at a convex
/// corner both strips carried on until they meet) | rounded (the gap filled with a circular sector
/// about the corner); at a concave corner both strips are cut back to where they cross.
Shape ruled(const Shape& shape, const godot::PackedInt32Array& edges, const godot::Dictionary& p, godot::String& error);

/// A copy of the faces (every face when empty) moved distance along their normals, as a surface,
/// each named as the face it came from. Refused where a face curves too tightly for the distance,
/// and where OCCT's offset comes out broken or the wrong way.
Shape offset_surface(const Shape& shape, const godot::PackedInt32Array& faces, double distance, const std::string& tag, godot::String& error, godot::String& note);

/// The shapes sewn together where their edges meet within "tolerance"; closed shells (a lone face
/// closed on itself too) become solids when "solid" is true. Refused when nothing meets. The
/// shapes given are left as they were (it sews copies, made together so a face they share stays
/// one), and the faces sewn keep their names.
Shape stitch(const godot::Array& shapes, const godot::Dictionary& p, godot::String& error);

/// Only the given faces of shape (faces that share edges stay joined), with their names.
Shape keep_faces(const Shape& shape, const godot::PackedInt32Array& faces, godot::String& error);

/// shape's separate pieces: each solid, and each group of other faces joined by edges.
godot::Array pieces(const Shape& shape);

/// shape cut by tool, without the regions (faces between the cuts) nearest remove_points. With no
/// points every region is kept, so the cuts show where pieces can be clicked. Edges the tool runs
/// along part regions as its cuts do. A surface under 10 mm across is cut scaled up to that and
/// back (the cut's tolerances suit bigger shapes).
Shape trim(const Shape& shape, const Shape& tool, const godot::PackedVector3Array& remove_points, const godot::Dictionary& p, godot::String& error);

/// Faces given back their surface's natural bounds: "mode" all | inner (holes removed) | outer
/// (outer boundary removed, holes kept) | loops (the loops holding edges). Directions the surface
/// doesn't bound (planes, a cylinder's length) keep the face's extent grown by "extend". A face
/// stays joined to the faces it meets: sides along them don't move (nor wrap round a periodic
/// direction), and it is sewn back to them. A plate patch's outer boundary is refused. The shape
/// given is left as it was (it works on a copy).
Shape untrim(const Shape& shape, const godot::PackedInt32Array& faces, const godot::PackedInt32Array& edges, const godot::Dictionary& p, godot::String& error);

/// Open boundary edges pushed out by "distance": "mode" natural (the surface carries on, curving as
/// it does, along a surface of revolution's profile; on an edge where the face's surface ends,
/// a trimmed face's too, a band of it sewn on; an edge where the surface comes to a point at its
/// ends, a lens patch's rim, gets a band of its own bending as the face does, as wide all along;
/// other edges extend tangent and note gets how many did) | tangent (a strip along the surface's
/// tangent) | perpendicular (a strip along its normal), both taking the limit of the face's
/// normal where it comes to a point. Strips meeting at a corner, on one face or two, fill it or
/// are cut back to meet.
/// "chain" adds the open edges running on smoothly from the picked ones. Refused past a point the
/// surface or its strips come to (a cone's apex, a profile reaching its axis). The shape given is
/// left as it was (it works on a copy).
Shape extend(const Shape& shape, const godot::PackedInt32Array& edges, const godot::Dictionary& p, godot::String& error, godot::String& note);

/// Faces lying on one surface merged into one face across the given edges (and between the given
/// faces).
Shape merge_faces(const Shape& shape, const godot::PackedInt32Array& edges, const godot::PackedInt32Array& faces, const std::string& tag, godot::String& error);

/// The faces (every face when empty) turned to face the other way, each with every face joined to
/// it by edges, so a sheet keeps facing one way.
Shape reverse_faces(const Shape& shape, const godot::PackedInt32Array& faces, godot::String& error);

/// Faces of owner in groups joined by shared edges (only edges in joining, when given): each group
/// as indices into faces.
std::vector<std::vector<int>> face_regions(const TopoDS_Shape& owner, const std::vector<TopoDS_Face>& faces, const TopTools_MapOfShape* joining = nullptr);

/// The faces as one shell per group (a compound when several).
TopoDS_Shape assemble_faces(const std::vector<TopoDS_Face>& faces, const std::vector<std::vector<int>>& groups);

/// True when every edge of shell joins two faces (a seam joins its face to itself).
bool closed_shell(const TopoDS_Shape& shell);

/// True when an algorithm's result can be used: valid topology with a finite, positive area
/// (some offsets report success with a face whose edges are garbage).
bool sound(const TopoDS_Shape& s);

/// False (with error) when a face curves too tightly to be offset distance along its normal:
/// moving to a center of curvature or past it turns the surface inside out.
bool offset_fits(const std::vector<TopoDS_Face>& faces, double distance, godot::String& error);

/// True when result lies distance from source along the source faces' normals, checked at a point
/// inside each face (an offset can also come out the wrong way).
bool offset_along(const TopoDS_Shape& source, const TopoDS_Shape& result, double distance);

/// The volume swept by a face moved from from to to along its normal (the integrals of its
/// curvatures over it give it exactly: t A - t^2 int H + t^3 / 3 int K, between the ends).
double swept_volume(const TopoDS_Face& face, double from, double to);

/// The area of a face moved distance along its normal (A - 2 d int H + d^2 int K).
double offset_area(const TopoDS_Face& face, double distance);

/// What a sheet's seams (edges two of its faces share) add to it moved distance along its normals,
/// a unit of offset squared (for a volume) or of offset (for an area, twice it): where the faces
/// part, on the side the sheet moves to, their mitre adds tan(a/2) a unit of seam length (a
/// rounded join a/2), and where they close in, their overlap takes tan(a/2) away, a the angle
/// between their normals. seams is the seams' whole length.
double seam_change(const TopoDS_Shape& sheet, double distance, bool rounded, double& seams);

/// How much to scale faces up by before offsetting or thickening them (1 for not at all), and the
/// middle of their box to scale about: to at least floor across, and so that their shortest edge
/// is at least half that, though not past a metre across. (OCCT's offsets have absolute
/// tolerances: an L sheet with 0.6 mm legs 30 mm long, sized by its 30 mm box, came out 74 %
/// short thickened.)
double work_scale(const std::vector<TopoDS_Face>& faces, double floor, gp_Pnt& middle);

}  // namespace holo_forge::ops
