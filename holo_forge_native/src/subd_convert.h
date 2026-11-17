#pragma once

// Shared cage data for CadSubD and the subdivision-surface to B-rep conversion (to_shapes),
// plus the B-rep helpers the Form tools use (closest points on a shape, face sample grids).

#include <memory>
#include <string>
#include <vector>

#include <opensubdiv/far/topologyRefiner.h>

#include <TopoDS_Shape.hxx>

namespace holo_forge::subd
{

namespace osd = OpenSubdiv::Far;

/// One cage (C1) in flat arrays, plus derived topology. Positions are meters, doubles.
struct CageData
{
    int nV = 0;
    std::vector<double> pos;           // 3 per vertex
    std::vector<int> counts;           // per face
    std::vector<int> offsets;          // per face + 1
    std::vector<int> indices;          // face corners
    std::vector<int> crease_pairs;     // 2 per crease
    std::vector<float> crease_weights;
    std::vector<int> corners;
    std::vector<float> corner_weights;

    // Derived (build_topology).
    std::vector<int> edges;            // 2 per canonical edge (a < b), C1 canonical order
    std::vector<int> corner_edge;      // per face corner k of face f (offsets[f] + k): edge (f[k], f[k+1])
    std::vector<int> edge_face_count;  // faces per edge
    std::vector<int> edge_first_face;  // first face (in face order) using the edge
    std::vector<int> edge_first_side;  // its corner k
    std::vector<int> ptex_base;        // first ptex face of each face (n-gons own n)
    int nPtex = 0;
    int dropped_creases = 0;   // crease pairs that are not edges (dropped)
    int dropped_corners = 0;   // corner indices out of range (dropped)
    bool unpaired_data = false;  // crease or corner lists and their weights differ in length

    int face_count() const { return int(counts.size()); }
    int edge_count() const { return int(edges.size() / 2); }
};

/// Validates the arrays and fills the derived topology. False with error on out-of-range
/// indices, faces with fewer than 3 distinct vertices, edges with more than two faces or faces
/// that disagree on orientation.
bool build_topology(CageData& c, std::string& error);

/// Topology key: faces, creases and corners.
uint64_t topology_key(const CageData& c);

/// A Catmull-Clark TopologyRefiner for the cage (base level only), with the options of C3.
/// Null with error (OpenSubdiv's message when it gave one) on failure.
std::unique_ptr<osd::TopologyRefiner> make_refiner(const CageData& c, std::string& error);

/// Messages OpenSubdiv reported through its error and warning callbacks since the last call
/// (installed once, so nothing goes to stdout).
void install_osd_callbacks();
std::string take_osd_errors();
std::string take_osd_warnings();

struct ConvertParams
{
    int isolation = 6;
    std::string prefix;
    double tolerance = 1e-7;
    bool check = true;
    double regularity = 1.75e-2;  // rad (1 deg): above the largest end-cap seam jump measured
    bool force_sewing = false;  // tests: skip the direct shell build and sew
};

struct ConvertComponent
{
    TopoDS_Shape shape;
    std::vector<std::string> face_names;  // in the order of TopExp::MapShapes(shape, FACE)
    int faces = 0;
    bool closed = false;
    bool solid = false;
    bool valid = false;
    bool sewn = false;
    int free_edges = 0;
    double volume = 0.0;
    double area = 0.0;
};

struct ConvertResult
{
    std::vector<ConvertComponent> components;
    std::vector<std::string> warnings;
    double ms = 0.0;
    // Timings of the stages (ms), for reports and tests.
    double c1_adjust = 0.0;  // largest pole move of the C1 correction, relative to the face size
    int c0_knots = 0;        // interior knots left C0
    double ms_patches = 0.0, ms_merge = 0.0, ms_shell = 0.0, ms_check = 0.0, ms_regularity = 0.0, ms_props = 0.0;
};

/// The limit surface of the cage as B-rep: one shape per edge-connected component, ordered by
/// lowest face. Closed components become solids, open ones shells. False with error when the
/// patch table can't be built or a component can't be made at all.
bool convert(const CageData& c, const ConvertParams& params, ConvertResult& result, std::string& error);

// ---------------------------------------------------------------- B-rep helpers

struct ProjectResult
{
    std::vector<double> positions;  // 3 per point
    std::vector<double> normals;    // 3 per point (unit, outward for the face orientation)
    std::vector<int> faces;         // face index (face map order), -1 when beyond max_distance
    std::vector<double> distances;
};

/// Closest points on the faces of a shape (respecting their trims), for each point.
bool project_to_shape(const TopoDS_Shape& shape, const std::vector<double>& points, double max_distance,
                      ProjectResult& result, std::string& error);

struct FaceGridResult
{
    bool ok = false;
    bool four_sided = false;
    bool reversed = false;          // the face is reversed in the shape (its outside is -Du x Dv)
    std::vector<double> positions;  // (nu+1)*(nv+1)*3, row-major v then u
    std::string error;
};

/// Samples a face's surface on an (nu+1) x (nv+1) grid over its UV bounds.
FaceGridResult face_grid(const TopoDS_Shape& shape, int face_index, int nu, int nv);

}  // namespace holo_forge::subd
