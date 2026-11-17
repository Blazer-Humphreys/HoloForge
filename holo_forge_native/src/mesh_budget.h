#pragma once

// Size caps and cost rates of the Mesh workspace (contract C5.2). The caps are mirrored in
// addons/holo_forge/core/features/mesh.gd. Rates are seconds on the dev machine (Ryzen 9 5900HX,
// one thread); "measured" ones carry a 1.5x safety factor, "spike" ones are the library spike's
// numbers (work order 2.6.2), to be measured again inside the real ops by the stages that own them.

#include <algorithm>
#include <cmath>
#include <cstddef>

namespace holo_forge::mesh::budget
{

// ---------------------------------------------------------------- caps
constexpr size_t MAX_TRIANGLES_MESH = 2000000;
constexpr size_t MAX_VERTICES_MESH = 2000000;
constexpr size_t MAX_GROUPS_MESH = 100000;
constexpr size_t MAX_GROUP_NAME_BYTES = 64;
/// The farthest a vertex may lie from the origin along an axis, in meters (1,000 km). Anything
/// beyond is a wrong unit or a damaged file, and volumes of such sizes overflow.
constexpr double MAX_COORDINATE = 1.0e6;
constexpr size_t MAX_TRIANGLES_FACETED = 60000;
constexpr size_t MAX_VOXEL_SAMPLES = 2000000;
constexpr size_t MAX_PRISMATIC_SURFACES = 150;
constexpr size_t MAX_PRISMATIC_TRIANGLES = 200000;
constexpr size_t MAX_ORGANIC_FACES = 5000;
constexpr size_t MAX_SECTION_SEGMENTS = 5000;
constexpr int DECIMATE_STEPS = 3;
constexpr double PREVIEW_SECONDS = 0.5;
constexpr double OK_SECONDS = 20.0;
constexpr double SELF_INTERSECTION_SECONDS = 1.0;
/// check(): the default time limit of the whole call.
constexpr double CHECK_SECONDS = 2.0;
/// Readers (STL, OBJ) have no time argument: they stop after this long.
constexpr double READ_SECONDS = 20.0;
/// An ASCII file larger than this is refused before it is read (2,000,000 facets fit in it).
constexpr double MAX_TEXT_FILE_BYTES = 1024.0 * 1024.0 * 1024.0;

// ---------------------------------------------------------------- a cost by triangle count

/// A cost measured at 100k, 500k and 2M triangles.
struct Curve
{
    double at_100k;
    double at_500k;
    double at_2m;
};

/// Seconds for `triangles` triangles: between the three measured sizes the curve is a straight
/// line on log-log axes; below 100k it scales down linearly from the 100k point; above 2M (which
/// the cap rules out) the 500k..2M slope goes on.
inline double estimate(const Curve& c, double triangles)
{
    if (!(triangles > 0.0)) {
        return 0.0;
    }
    if (triangles <= 1e5) {
        return c.at_100k * triangles / 1e5;
    }
    const bool low = triangles <= 5e5;
    const double x0 = low ? 1e5 : 5e5, x1 = low ? 5e5 : 2e6;
    const double y0 = low ? c.at_100k : c.at_500k, y1 = low ? c.at_500k : c.at_2m;
    if (!(y0 > 0.0) || !(y1 > 0.0)) {
        return y0 + (y1 - y0) * (triangles - x0) / (x1 - x0);
    }
    const double slope = std::log(y1 / y0) / std::log(x1 / x0);
    return y0 * std::pow(triangles / x0, slope);
}

// ---------------------------------------------------------------- measured in Stage N1 (x 1.5)
// Measured 2026-11-11 inside CadMesh, through GDScript, on welded grid cubes (the test fixture
// large_grid) of 99,372 / 499,392 / 1,997,568 triangles; the fastest of 3 runs, in seconds:
//   edge topology                       0.0045 / 0.027 / 0.098
//   triangle hierarchy                  0.011  / 0.068 / 0.280
//   nearest point, one per vertex       0.053  / 0.306 / 1.30   (T / 2 vertices; 1.1 to 1.3 us each)
//   self-intersections, hierarchy built 0.039  / 0.217 / 0.781  (a flat grid: every pair coplanar)
// For the record, the same run: tessellate() 0.023 / 0.141 / 0.433, read_stl (binary)
// 0.017 / 0.089 / 0.397, check() cold 0.070 / 0.349 / 1.61, one ray_hit 2 us at every size.

/// Edge topology (the first check(), volume(), tessellate(), section() of a mesh builds it once).
constexpr Curve TOPOLOGY = {0.0068, 0.040, 0.147};
/// The triangle hierarchy (the first ray_hit(), distance_to(), self-intersection test builds it).
constexpr Curve BVH_BUILD = {0.017, 0.102, 0.42};
/// One nearest-point query per vertex of a mesh of that size (T / 2 vertices), hierarchy built.
constexpr Curve NEAREST_PER_VERTEX = {0.080, 0.46, 1.95};
/// The self-intersection test of a clean closed mesh (no crossings), hierarchy already built.
constexpr Curve SELF_INTERSECTIONS = {0.059, 0.325, 1.17};

/// Tessellate. OpenCASCADE's mesher works face by face and slows down faster than a face grows.
/// Measured on one sphere face (triangles: seconds): 125,706: 2.89; 201,198: 5.82; 251,050:
/// 8.87; 502,752: 26.9 (36.0 in another run). So a face costs about
/// AT_100K x (its triangles / 100,000) ^ POWER seconds (2.0 measured, x 1.5 here), summed over
/// the faces: about 300,000 triangles on one curved face fit in 20 s.
/// A doubly curved face gets about 3.2 x the triangles a plain chord estimate gives (measured:
/// 125,706 against 39,270; 201,198 against 62,832; 502,752 against 157,080).
constexpr double TESSELLATE_FACE_SECONDS_AT_100K = 3.0;
constexpr double TESSELLATE_FACE_POWER = 1.7;
constexpr double TESSELLATE_CURVED_FACTOR = 3.2;

// ---------------------------------------------------------------- spike numbers (library calls)

// (The pmp and meshoptimizer rows were measured again by Stage N2 inside the real ops, 2026-11-11,
// on noisy icospheres of 81,920 / 327,680 / 1,310,720 triangles, one run each, other teams'
// tests running at times; brought to 100k / 500k / 2M along the measured slope and stored x 1.5.
// The spike's own numbers are kept beside them where they differ.)
/// One pmp decimate call that takes out half the triangles (no Hausdorff limit). Measured per
/// call: about (4 + 11 x the share taken out) microseconds per triangle the call starts from,
/// at every size (3.0..4.3 at a sixth to a quarter, 6.9..7.6 at 30 %, 8.4..9.6 at 43 %,
/// 9.7..11.4 at 75 %): 0.95 / 4.75 / 19 s for a half. The spike had 3.08 / 9.54 / 50.3 s.
constexpr Curve PMP_DECIMATE_HALF = {1.43, 7.1, 28.5};
/// meshopt_simplifyWithAttributes to 50 %. Measured 0.026 / 0.16 / 0.65 s (0.020 s at 82k, 0.105 s
/// at 328k, 0.43 s at 1.31M; a flat grid: 0.019 / 0.14 / 0.28 s at 99k / 499k / 1M). The spike's
/// higher numbers are kept: the fast method is nowhere near its limit either way.
constexpr Curve MESHOPT_SIMPLIFY_HALF = {0.047, 0.60, 1.75};
/// One Remesh pass: pmp's pass with its projection off, then ours, by the larger of the
/// triangles before and after. Measured 2.7 microseconds a triangle at 82k and 328k (0.22 and
/// 0.90 s; two thirds pmp, one third projection), up to 3.7 when a pass makes four times the
/// triangles, 4.8..5.2 at 1.31M (6.3..6.8 s): 0.36 / 2.0 / 10.5 s. The spike had 1.39 / 3.46 / 8.32 s.
constexpr Curve PMP_REMESH_PASS_WITH_PROJECTION = {0.54, 3.0, 15.8};
/// (The spike's number for pmp's own 10-pass call, which is not used: for the record.)
constexpr Curve PMP_REMESH_10_PASSES = {9.05, 37.7, 37.7 * 4.0};  // not run at 2M: 100k..500k slope
/// One pmp implicit_smoothing pass: a sparse solve that grows faster than the mesh. Measured
/// 0.32 s at 82k, 4.0 s at 328k, 38..42 s at 1.31M (a flat grid: 0.35 / 4.4 / 15.2 s at 99k /
/// 499k / 1M): 0.45 / 8.4 / 82 s. The spike had 0.79 / 6.79 / 73.6 s.
constexpr Curve PMP_IMPLICIT_SMOOTHING_PASS = {0.68, 12.6, 123.0};
/// pmp::SurfaceMesh from a mesh body. Measured 0.020 / 0.085 / 0.31 s at 82k / 328k / 1.31M
/// (0.027 / 0.14 / 0.5 s); the spike's 0.052 / 0.278 / 0.834 s are a little higher and kept.
constexpr Curve PMP_SURFACE_MESH_BUILD = {0.052, 0.278, 0.834};
constexpr Curve MANIFOLD_INGEST = {0.30, 0.87, 2.77};
constexpr Curve MANIFOLD_UNION = {0.31, 0.87, 3.50};
constexpr Curve MANIFOLD_SUBTRACT = {0.41, 0.47, 2.50};
constexpr Curve MANIFOLD_SPLIT_BY_PLANE = {0.94, 1.80, 5.61};
/// The 3-call decimate staircase to 50 % against one call to 50 %, by the per-call rule above
/// (0.61 + 0.54 + 0.47 of a half-call): for the record, the ops add the calls up themselves.
/// Measured: the three calls took 0.72 s at 82k, 3.2 s at 328k and 11.5 s at 1.31M (the first
/// call 43 to 45 % of that). One call to 50 % was not timed on its own.
constexpr double DECIMATE_STAIRCASE_FACTOR = 1.63;
/// Manifold LevelSet, seconds per million grid cells (the worst rate seen; no extra factor).
constexpr double LEVEL_SET_SECONDS_PER_MILLION_CELLS = 4.6;
/// Convert Prismatic: BOPAlgo_MakerVolume by surfaces and crossing cylinder pairs. (Measured
/// again by Stage C inside the real op, see the Stage C block: the pair rate was 0.25, the
/// spike's.)
constexpr double PRISMATIC_SECONDS_PER_SURFACE = 0.01;
constexpr double PRISMATIC_SECONDS_PER_CROSSING_PAIR = 0.11;

// ---------------------------------------------------------------- Stage N2 (our own clean-up, group, fill and smoothing code)
// N2-BEGIN (stage N2 owns the lines down to N2-END)
// Measured 2026-11-11 inside the real ops, through GDScript, each op on a fresh mesh, on noisy
// icospheres of 81,920 / 327,680 / 1,310,720 triangles and on welded grid cubes of 99,372 /
// 499,392 / 1,009,200; one run each, other teams' tests running at times. Brought to 100k /
// 500k / 2M and stored x 1.5. Whole ops, with the checks at their end (ms at the three sphere
// sizes): Stitch and Remove 164 / 761 / 3,433; Reverse Normal (auto) 44 / 256 / 1,045; Generate
// Face Groups fast 33 / 200 / 863, accurate 165 / 884 / 3,116; Reduce fast 156 / 657 / 1,666;
// Reduce adaptive to 50 % 869 / 3,677 / 13,006, to 10 % 1,495 / 6,517 / 23,487; Remesh, 3
// passes at the same size, 877 / 3,282 / 19,871; Smooth (pmp), 2 passes, 724 / 8,479 / 81,709;
// Smooth (our Laplacian), 2 passes, 109 / 461 / 854.

/// Stitch and Remove, the whole op without the checks at its end (0.13 / 0.95 / 4.4 s).
constexpr Curve STITCH = {0.20, 1.45, 6.6};
/// Reverse Normal (auto): one-way pieces and the nesting rule (0.045 / 0.36 / 1.45 s).
constexpr Curve ORIENT = {0.07, 0.54, 2.2};
/// Generate Face Groups, fast (0.04 / 0.31 / 1.3 s) and accurate (0.2 / 1.3 / 4.7 s on a noisy
/// ball that breaks into thousands of groups; a clean body costs what fast costs).
constexpr Curve GROUPS_FAST = {0.06, 0.47, 2.0};
constexpr Curve GROUPS_ACCURATE = {0.30, 2.0, 7.1};
/// Smooth, our own Laplacian: one pass over that many triangles (0.010 / 0.056 / 0.18 s).
constexpr Curve LAPLACIAN_PASS = {0.015, 0.085, 0.27};
/// Reduce (adaptive). One pmp decimate call costs a base part (its queue, by the triangles it
/// starts from) plus a part by what it takes out: of a call to 50 %, this share is the base
/// (4 of 9.5 microseconds a triangle; see PMP_DECIMATE_HALF).
constexpr double DECIMATE_BASE_SHARE = 0.42;
/// A call with the Hausdorff limit on (Reduce by tolerance) against one without: measured 1.9 x
/// at 82k (2.0 s) and 2.4 x at 328k (11.8 s).
constexpr double DECIMATE_HAUSDORFF_FACTOR = 2.5;
/// The share of the Maximum Deviation pmp's own limit gets. pmp checks the corners it took out
/// against the new triangles only: with the whole tolerance the measured two-sided deviation
/// was 0.060 mm at a 0.05 mm limit and 0.1994 mm at 0.2 mm. The result is measured both ways
/// and the call made again with less when it is over.
constexpr double DECIMATE_TOLERANCE_SHARE = 0.8;
/// The same for meshoptimizer's error limit (its error read about half the measured deviation;
/// below about a thousandth of the body's size its float sums cannot tell collapses apart, so
/// Reduce (fast) by a small tolerance is refused after measuring).
constexpr double MESHOPT_TOLERANCE_SHARE = 0.5;
/// The longest edge the staircase may make, as a multiple of the mean edge the target count
/// gives (1.3 and below kept the count up on a sphere at 50 %; 2.0 gave 0.061 mm, 1.6 0.043 mm,
/// no limit 0.065 mm of deviation).
constexpr double DECIMATE_EDGE_FACTOR = 1.6;
/// ... and never below this multiple of the input's mean edge: taking one vertex out about
/// doubles an edge, so a lower limit lets nothing go (seen at "keep 90 %": 1.69 x let nothing
/// go; at 50 % a limit of 2.3 x gave 0.051 mm on the sphere where 2.0 to 2.26 x gave 0.043 mm).
constexpr double DECIMATE_EDGE_FLOOR = 2.0;
/// Reduce (fast) by Maximum Deviation calls the library several times, each time to a count
/// (see reduce_fast): the cost of one such call as a multiple of MESHOPT_SIMPLIFY_HALF, the
/// number of calls the estimate at the start counts with, and the most it makes.
constexpr double MESHOPT_PROBE_FACTOR = 2.0;
constexpr double MESHOPT_TOLERANCE_PROBES = 8.0;
constexpr int MESHOPT_MAX_PROBES = 16;
/// Reduce by Maximum Deviation checks the result on a lattice of points across every triangle
/// that changed, both ways (mesh::distance_at_points): seconds a million points (measured 1.2
/// to 1.3), and the share of the tolerance a result may use at those points (the surface
/// between them can be a little further off).
constexpr double POINT_DISTANCE_SECONDS_PER_MILLION = 1.5;
constexpr double TOLERANCE_MARGIN = 0.98;
/// Reduce (fast): welding, locks and groups around the library call.
constexpr Curve REDUCE_FAST_SETUP = {0.06, 0.30, 1.2};
/// Remesh (adaptive): pmp analyses the curvature of the whole mesh at the start of every call,
/// so once a pass. Its cost grows far faster than the mesh, with a cliff that is not explained
/// (measured, one analysis, on welded grid cubes and on balls alike; triangles: seconds):
/// 58,800: 0.21; 81,920: 0.38..0.43; 120,000: 0.71; 172,800: 1.53; 235,200: 5.4; 326,700: 52
/// (327,680: 42..45). Small patches of a slow mesh are fast, so it cannot be sampled. Stored
/// x 1.5; above the last point the last slope goes on. Because the cliff may sit elsewhere on
/// another machine, the adaptive type also has a plain size limit below it.
constexpr int ADAPTIVE_CURVATURE_POINTS = 5;
constexpr double ADAPTIVE_CURVATURE_TRIANGLES[ADAPTIVE_CURVATURE_POINTS] = {58800.0, 120000.0, 172800.0, 235200.0, 326700.0};
constexpr double ADAPTIVE_CURVATURE_SECONDS[ADAPTIVE_CURVATURE_POINTS] = {0.32, 1.07, 2.3, 8.2, 78.0};
constexpr size_t MAX_ADAPTIVE_REMESH_TRIANGLES = 150000;
/// Close Holes. Loops of up to this many edges get the minimal-area-and-dihedral triangulation
/// (a dynamic program, cubic in the edge count: measured 1 ms at 59 edges, 7 at 114, 35..48 at
/// 214..221, 214..295 at 375..390, so 0.26..0.32 s at 400); longer ones ear clipping (measured
/// 1 to 4 ms at 747 to 1,193 edges of a round hole; quadratic at worst for a loop of many
/// inward corners, which was not measured: the number below is a guess on the safe side, and
/// the loop itself is stopped by the deadline).
constexpr size_t FILL_DP_MAX_EDGES = 400;
constexpr double FILL_DP_SECONDS_AT_400 = 0.48;
constexpr double FILL_EAR_SECONDS_AT_10K = 1.0;
/// Refining a patch to the loop's edge size, per thousand new vertices (measured 3.4 to 11.4 ms).
constexpr double FILL_REFINE_SECONDS_PER_1K_VERTICES = 0.017;
/// pmp fair on a hole's sub-mesh (the patch and three rings around the hole), with building
/// that sub-mesh: seconds at 10,000 free vertices, and how it grows. Measured (free vertices:
/// ms): 395: 2.4; 1,367: 6.8; 4,727: 39; 13,041: 128; 17,653: 231; 58,603: 1,367; 71,223:
/// 2,134; 74,152: 2,686; 148,941: 7,096. About 0.1 s at 10,000 and a power of 1.6.
constexpr double FAIR_SECONDS_AT_10K = 0.18;
constexpr double FAIR_POWER = 1.6;
/// The most new vertices one hole's fill may need (smooth and flat fills with Match Edge
/// Size). The work order's provisional 200,000 is lowered to what was measured (7.1 s at
/// 148,941); at 20 s the time estimate refuses a little above it anyway.
constexpr size_t MAX_FILL_FREE_VERTICES = 150000;
// N2-END

// ---------------------------------------------------------------- Stage N3 (Manifold and voxel ops)
// N3-BEGIN (stage N3 owns the lines down to N3-END)
// Measured 2026-11-11 inside the real ops (each op's report has "phases": what its steps took),
// through GDScript, on welded grid cubes (the fixture large_grid) of about 100k / 500k / 2M
// triangles and on a 100 mm ball; seconds, one run, other teams' tests running at times.
// Stored with the 1.5x factor unless said otherwise.
//   ingest (our MeshGL64 copy + ctx.FromMeshGL), one body     0.090 / 0.49 / 2.28
//   union of two boxes, after the ingests, by all triangles   0.089 / 0.48 / 1.56
//   subtract, the same                                        0.054 / 0.28 / 0.86
//   one plane trim, after the ingest                          0.081 / 0.44 / 2.14
//   Manifold's result back as a mesh body, by its triangles   0.0075 / 0.057 / 0.16
//   the shared checks at an op's end, by result triangles     0.036 / 0.21 / 0.85
//   Decompose and its parts read back                         0.043 / 0.23 / 0.78
//   our own plane clipper                                     0.019 / 0.10 / 0.42
//   Shell (fast): normals, the two surfaces, the rim          0.031 / 0.16 / (0.64)
/// Manifold ingest of one body, by its triangles.
constexpr Curve MF_INGEST = {0.14, 0.74, 3.4};
/// A Manifold boolean after the ingests, by the triangles of all inputs together. Two boxes
/// that cross along a few lines measured well below the library spike's numbers (two halves of
/// a bumpy torus, which cross along a long seam): the spike's larger numbers stay.
constexpr Curve MF_UNION = {0.31, 0.87, 3.50};
constexpr Curve MF_SUBTRACT = {0.41, 0.47, 2.50};
/// One plane trim (a deferred boolean with a half space) after the ingest. Split Body is two.
constexpr Curve MF_TRIM_BY_PLANE = {0.13, 0.66, 3.3};
/// Manifold's result back as a mesh body (GetMeshGL64 and our copy), by its triangles.
constexpr Curve MF_EXPORT = {0.012, 0.086, 0.24};
/// The shared end of an op (CadMesh::finish_op without the self-intersection test): the
/// numbers of the input and of the result, by the result's triangles.
constexpr Curve OP_FINISH = {0.054, 0.32, 1.3};
/// Manifold Decompose and reading its parts back (Separate), after the ingest.
constexpr Curve MANIFOLD_DECOMPOSE = {0.065, 0.34, 1.2};
/// Our own plane clipper (Plane Cut on open bodies, Split Faces).
constexpr Curve PLANE_CLIP = {0.03, 0.15, 0.65};
/// The even fill of a cut face, per million triangles it makes (measured 0.47 to 0.76 s).
constexpr double CAP_FILL_SECONDS_PER_MILLION_TRIANGLES = 1.2;
/// Our own voxel work per million grid samples: the distance field, and with it the winding
/// columns (Rebuild, Shell) or the flood, the nearest-sample transform and the function (Wrap).
/// The distance field is most of it, and it costs by the samples within its band of the
/// surface, so the rate grows with the band's width in cells. Measured, seconds per million
/// samples: band 2.5 cells 0.29 to 0.59; 4.5 cells 0.40 to 1.0; 6.5 cells 0.72 to 0.95;
/// 12.5 cells 1.7 to 2.1 (the higher numbers on small grids, where more samples are near the
/// surface). Stored: base + per band cell x band, 1.5 x the fit 0.25 + 0.15 x band.
/// The steps apart, on a quiet machine, seconds per million samples: distance field 0.21 to
/// 0.91 (band 2.5 to 4.5 cells) and 1.67 (12.5 cells); the exact distance transform (nearest
/// outside sample) 0.022 to 0.028; the flood 0.002 to 0.009; winding columns 0.013 to 0.027;
/// Wrap's function 0.016 to 0.033.
constexpr double VOXEL_SECONDS_PER_MILLION_CELLS = 0.4;
constexpr double VOXEL_SECONDS_PER_MILLION_CELLS_PER_BAND_CELL = 0.22;
/// (LevelSet itself: 0.69 to 2.0 s per million samples measured here in 14 runs; the stored
/// LEVEL_SET_SECONDS_PER_MILLION_CELLS stays at the spike's worst rate, 4.6, as the work order says.)
/// Triangles LevelSet makes per cell-sized square (h x h) of the surface it finds (measured 5.4 to 5.7).
constexpr double LEVEL_SET_TRIANGLES_PER_CELL_AREA = 6.0;
/// Shell (fast) without the checks at its end.
constexpr Curve SHELL_FAST = {0.047, 0.24, 0.96};
/// Texture Extrude (refine and move), per million triangles of its result (measured 0.31 to 0.39 s).
constexpr double DISPLACE_SECONDS_PER_MILLION_TRIANGLES = 0.6;
/// Separate: Manifold's Decompose costs about its parts x its triangles (measured 1.0 s at
/// 2,000 x 8,000, 7 s at 5,000 x 20,000, 26 s at 10,000 x 40,000: 6.5e-8 s each) and cannot be
/// stopped, so it is used only up to this product (about 2 s), whatever the time limit is.
constexpr double DECOMPOSE_MAX_PARTS_X_TRIANGLES = 2e7;
constexpr double DECOMPOSE_SECONDS_PER_PART_TRIANGLE = 1e-7;
/// Wrap and Rebuild: measuring how much of the input the result left out (up to about 100,000
/// points against the result's hierarchy; measured 0.03 to 0.3 s).
constexpr double COVERAGE_SECONDS = 0.5;
// N3-END

// ---------------------------------------------------------------- Stage C (Convert Mesh)
// C-BEGIN (stage C owns the lines down to C-END)
// Measured 2026-11-12 inside the real ops (CadMesh::to_faceted, to_prismatic), through GDScript,
// one run each, other teams' tests running at times; stored x 1.5.
/// Convert Mesh: Faceted, the whole op per 1,000 faces of the result (a merged flat patch is
/// one face, every other triangle one). Measured 0.13 to 0.22 s (grid cubes of 4,800 / 19,200 /
/// 58,800 triangles as faces: 0.62 / 2.8 / 11.5 s; a 20,480-triangle ball 3.8 to 4.0 s; plates of
/// 20,000 / 39,762 triangles as faces 3.9 / 8.7 s, re-measured 2026-11-13 with three other Godot
/// runs going). Three quarters of it is the kernel's validity check of each face, which can be
/// stopped (stopped 0.13 to 0.15 s past limits of 1 to 5 s): the estimate is the expected time,
/// not padded, and refuses only what would not fit. (Per triangle it refused a flat plate that
/// merges to one face in 0.02 s, and a 39,762-triangle one at 9 s that takes 4 to 8 s.)
constexpr double FACETED_SECONDS_PER_1K_FACES = 0.22;
/// ... and per 1,000 edges of the merged faces' outlines (checked piece by piece): comb plates
/// of 20,000 / 57,800 triangles merged into 51 / 86 faces with about 10,000 / 29,000 outline
/// edges took 0.78 / 3.0 s.
constexpr double FACETED_SECONDS_PER_1K_OUTLINE_EDGES = 0.10;
/// Its two steps that cannot be stopped once started, per 1,000 faces of the result: the
/// kernel's check of the shells and solids (measured 0.008 to 0.012 s) and measuring the body
/// (0.014 to 0.024 s). Each is not started when it would not fit in what is left.
constexpr double FACETED_CHECK_SECONDS_PER_1K_FACES = 0.02;
constexpr double FACETED_MEASURE_SECONDS_PER_1K_FACES = 0.035;
/// Convert Mesh: Prismatic. The fits and the checks at the end by triangles (the fits alone:
/// 0.16 s per 100,000). The cells, their pick, the solid and its checks:
///   by surfaces: 0.005 s each (21 surfaces that do not cross: 0.11 s; the spike had 0.006 s
///     for the cell building alone), kept at PRISMATIC_SECONDS_PER_SURFACE 0.01;
///   by crossing pairs of round surfaces: 0.045 to 0.076 s each, whole op (4 pairs 0.25 s;
///     15 pairs 1.2 s; 50 pairs 3.2 s; 120 pairs 9.2 to 10.1 s; 200 pairs 15.3 to 16.0 s). The
///     spike's 0.22 s per pair (28 s at 120 pairs in the cell building alone) was not seen
///     again: the faces here reach less far past the body;
///   by corners where three flat surfaces meet (a waffle of k slots each way: 256 corners
///     0.33 s, 784 corners 1.25 s, 1,936 corners 3.3 s): 0.9 to 1.6 ms each.
constexpr double PRISMATIC_SECONDS_PER_100K_TRIANGLES = 0.5;
constexpr double PRISMATIC_SECONDS_PER_CORNER = 0.0024;
/// Merging the kept cells' faces cannot be stopped: 0.02 s per 100 kept cells measured.
constexpr double PRISMATIC_UNIFY_SECONDS_PER_100_CELLS = 0.03;
// C-END

// ---------------------------------------------------------------- Phase 8 team N (contact)
// N8-BEGIN (Phase 8 team N owns the lines down to N8-END)
// CadMesh.overlap (work order C5.1), the rate the contact sweep estimates with (C5.5). Measured
// 2026-11-13 through GDScript on two large_grid boxes overlapping by about half (the whole
// call: the Dictionary, the checks, the boolean and its read-back), other teams' tests running
// at times; stored x 1.5. Mirror these in core/assembly/contact.gd, or ask a mesh with
// overlap(other, xform, {"estimate_only": true}).estimate (no work done).
/// One call with both Manifolds cached: a fixed part, and per triangle of the two meshes
/// together ("per triangle of the pair"), in microseconds. Measured: 2 x 12 triangles 0.23 ms;
/// 2 x 4,800 2.8-3.0 ms; 2 x 20,172 9.5-9.6 ms; 2 x 199,692 73-82 ms; 2 x 1,002,252 375-394 ms
/// (0.18-0.30 us a triangle); turned 0.6 rad about Z instead of moved: 3-15 % more.
constexpr double OVERLAP_MICROSECONDS_PER_CALL = 300.0;
constexpr double OVERLAP_MICROSECONDS_PER_TRIANGLE = 0.5;
/// The first call on a mesh also builds its Manifold (and its edge topology, kept by the mesh),
/// per triangle of that mesh, in microseconds. Measured: 0.81-0.96 us (first call less cached
/// call: 2 x 4,800 10.6-10.9 ms; 2 x 20,172 42-43 ms; 2 x 199,692 398-465 ms; 2 x 1,002,252
/// 2.30-2.40 s).
constexpr double OVERLAP_BUILD_MICROSECONDS_PER_TRIANGLE = 1.4;
/// Seconds one overlap() call is expected to take; built_*: that mesh's Manifold is cached.
inline double overlap_seconds(double triangles_this, double triangles_other, bool built_this, bool built_other)
{
    double us = OVERLAP_MICROSECONDS_PER_CALL + OVERLAP_MICROSECONDS_PER_TRIANGLE * (triangles_this + triangles_other);
    us += built_this ? 0.0 : OVERLAP_BUILD_MICROSECONDS_PER_TRIANGLE * triangles_this;
    us += built_other ? 0.0 : OVERLAP_BUILD_MICROSECONDS_PER_TRIANGLE * triangles_other;
    return us * 1e-6;
}
// N8-END

}  // namespace holo_forge::mesh::budget
