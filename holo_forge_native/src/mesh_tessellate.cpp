// Both directions between a mesh body and what is drawn or meshed: the display arrays of a mesh
// body (contract C6.1) and Tessellate, a B-rep body turned into a mesh body (CadMesh::from_shape).

#include "cad_mesh.h"
#include "cad_shape.h"
#include "mesh_budget.h"
#include "mesh_data.h"
#include "occt_guard.h"

#include <BRepAdaptor_Surface.hxx>
#include <BRepBuilderAPI_Copy.hxx>
#include <BRepLProp_SLProps.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRep_Tool.hxx>
#include <GeomAbs_SurfaceType.hxx>
#include <IMeshTools_Parameters.hxx>
#include <Message_ProgressIndicator.hxx>
#include <Message_ProgressScope.hxx>
#include <Poly_PolygonOnTriangulation.hxx>
#include <Poly_Triangulation.hxx>
#include <Precision.hxx>
#include <Standard_Failure.hxx>
#include <TopExp.hxx>
#include <TopLoc_Location.hxx>
#include <TopTools_IndexedDataMapOfShapeListOfShape.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Face.hxx>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>

namespace holo_forge::mesh
{

namespace
{
inline uint32_t next_corner(uint32_t c)
{
    return c - c % 3 + (c + 1) % 3;
}

/// Sets of corners; the smallest corner of a set is its root.
struct Sets
{
    std::vector<uint32_t> parent;
    explicit Sets(size_t n) : parent(n)
    {
        for (size_t i = 0; i < n; ++i) {
            parent[i] = uint32_t(i);
        }
    }
    uint32_t find(uint32_t x)
    {
        while (parent[x] != x) {
            parent[x] = parent[parent[x]];
            x = parent[x];
        }
        return x;
    }
    void join(uint32_t a, uint32_t b)
    {
        a = find(a);
        b = find(b);
        if (a < b) {
            parent[b] = a;
        }
        else if (b < a) {
            parent[a] = b;
        }
    }
    /// Every entry becomes its root.
    void flatten()
    {
        for (size_t c = 0; c < parent.size(); ++c) {
            parent[c] = find(uint32_t(c));
        }
    }
    /// Replaces every entry by a running number of its set (sets numbered by their smallest
    /// corner). Returns the number of sets.
    uint32_t number()
    {
        flatten();
        uint32_t next = 0;
        for (size_t c = 0; c < parent.size(); ++c) {
            const uint32_t root = parent[c];
            // A root comes before its members, so its slot already holds its number.
            parent[c] = root == c ? next++ : parent[root];
        }
        return next;
    }
};
}  // namespace

void tessellate(State& state, Tessellation& out)
{
    const MeshData& m = state.data;
    const size_t T = m.triangle_count();
    out = Tessellation();
    if (T == 0) {
        return;
    }
    const Topology* topo = topology_of(state);

    // Each triangle's unit normal and the axis its box projection looks along (0..5: +x -x +y -y +z -z).
    std::vector<float> normals(T * 3, 0.0f);
    std::vector<uint8_t> axis(T, 0), flat(T, 0);
    for (size_t t = 0; t < T; ++t) {
        double a[3], b[3], c[3];
        m.point(m.triangles[t * 3], a);
        m.point(m.triangles[t * 3 + 1], b);
        m.point(m.triangles[t * 3 + 2], c);
        const double e1[3] = {b[0] - a[0], b[1] - a[1], b[2] - a[2]}, e2[3] = {c[0] - a[0], c[1] - a[1], c[2] - a[2]};
        const double n[3] = {e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0]};
        const double len = std::sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
        if (!(len > 0.0)) {
            flat[t] = 1;
            continue;
        }
        int major = 0;
        for (int k = 1; k < 3; ++k) {
            if (std::fabs(n[k]) > std::fabs(n[major])) {
                major = k;
            }
        }
        axis[t] = uint8_t(major * 2 + (n[major] < 0.0 ? 1 : 0));
        for (int k = 0; k < 3; ++k) {
            normals[t * 3 + size_t(k)] = float(n[k] / len);
        }
    }

    // Corners that share a normal (across edges inside one group that bend 30 degrees or less),
    // and corners that share an output vertex (the same, and the same projection axis).
    const double sharp = std::cos(30.0 * M_PI / 180.0);
    Sets fans(T * 3), verts(T * 3);
    for (size_t e = 0; e < topo->edge_count(); ++e) {
        if (topo->uses(uint32_t(e)) != 2) {
            continue;
        }
        const uint32_t h1 = topo->edge_hes[topo->edge_first[e]], h2 = topo->edge_hes[size_t(topo->edge_first[e]) + 1];
        const uint32_t t1 = h1 / 3, t2 = h2 / 3;
        if (m.triangles[h1] == m.triangles[h2] || m.groups[t1] != m.groups[t2]) {
            continue;  // flipped neighbours, or a group border
        }
        if (!flat[t1] && !flat[t2]) {
            const float* n1 = &normals[size_t(t1) * 3];
            const float* n2 = &normals[size_t(t2) * 3];
            if (double(n1[0]) * n2[0] + double(n1[1]) * n2[1] + double(n1[2]) * n2[2] < sharp) {
                continue;
            }
        }
        fans.join(h1, next_corner(h2));
        fans.join(next_corner(h1), h2);
        if (axis[t1] == axis[t2]) {
            verts.join(h1, next_corner(h2));
            verts.join(next_corner(h1), h2);
        }
    }
    const uint32_t fan_count = fans.number();
    // Angle-weighted normals per fan.
    std::vector<float> fan_normals(size_t(fan_count) * 3, 0.0f);
    for (size_t t = 0; t < T; ++t) {
        if (flat[t]) {
            continue;
        }
        double p[3][3];
        for (int k = 0; k < 3; ++k) {
            m.point(m.triangles[t * 3 + size_t(k)], p[k]);
        }
        for (int k = 0; k < 3; ++k) {
            const double* at = p[k];
            const double* to = p[(k + 1) % 3];
            const double* from = p[(k + 2) % 3];
            const double u[3] = {to[0] - at[0], to[1] - at[1], to[2] - at[2]}, w[3] = {from[0] - at[0], from[1] - at[1], from[2] - at[2]};
            const double cx = u[1] * w[2] - u[2] * w[1], cy = u[2] * w[0] - u[0] * w[2], cz = u[0] * w[1] - u[1] * w[0];
            const double angle = std::atan2(std::sqrt(cx * cx + cy * cy + cz * cz), u[0] * w[0] + u[1] * w[1] + u[2] * w[2]);
            float* sum = &fan_normals[size_t(fans.parent[t * 3 + size_t(k)]) * 3];
            for (int a = 0; a < 3; ++a) {
                sum[a] += float(angle * normals[t * 3 + size_t(a)]);
            }
        }
    }

    // Output vertices, numbered by their first corner.
    out.indices.resize(T * 3);
    out.face_ids.resize(T);
    {
        // (number() in place, done here so that a set's first corner fills its vertex.)
        verts.flatten();
        uint32_t next = 0;
        for (size_t c = 0; c < T * 3; ++c) {
            const uint32_t root = verts.parent[c];
            if (root != c) {
                verts.parent[c] = verts.parent[root];
                continue;
            }
            verts.parent[c] = next++;
            const size_t t = c / 3;
            const float* p = &m.positions[size_t(m.triangles[c]) * 3];
            out.positions.insert(out.positions.end(), p, p + 3);
            const float* n = &fan_normals[size_t(fans.parent[c]) * 3];
            const double len = std::sqrt(double(n[0]) * n[0] + double(n[1]) * n[1] + double(n[2]) * n[2]);
            if (len > 0.0) {
                out.normals.push_back(float(n[0] / len));
                out.normals.push_back(float(n[1] / len));
                out.normals.push_back(float(n[2] / len));
            }
            else {
                // A corner of triangles without area only: any unit normal will do.
                out.normals.push_back(0.0f);
                out.normals.push_back(1.0f);
                out.normals.push_back(0.0f);
            }
            // Box projection in meters, not mirrored seen from outside.
            float u = 0.0f, v = 0.0f;
            switch (axis[t]) {
                case 0: u = -p[2]; v = -p[1]; break;
                case 1: u = p[2]; v = -p[1]; break;
                case 2: u = p[0]; v = p[2]; break;
                case 3: u = p[0]; v = -p[2]; break;
                case 4: u = p[0]; v = -p[1]; break;
                default: u = -p[0]; v = -p[1]; break;
            }
            out.uvs.push_back(u);
            out.uvs.push_back(v);
        }
    }
    for (size_t t = 0; t < T; ++t) {
        // Stored counter-clockwise; Godot's front faces are clockwise.
        out.indices[t * 3] = int32_t(verts.parent[t * 3]);
        out.indices[t * 3 + 1] = int32_t(verts.parent[t * 3 + 2]);
        out.indices[t * 3 + 2] = int32_t(verts.parent[t * 3 + 1]);
        out.face_ids[t] = int32_t(m.groups[t]);
    }

    // Lines: open boundaries (-2) and group borders (-1).
    for (size_t e = 0; e < topo->edge_count(); ++e) {
        const uint32_t first = topo->edge_first[e], last = topo->edge_first[e + 1];
        int id = 0;
        if (last - first == 1) {
            id = -2;
        }
        else {
            const uint32_t group = m.groups[topo->edge_hes[first] / 3];
            for (uint32_t i = first + 1; i < last && id == 0; ++i) {
                if (m.groups[topo->edge_hes[i] / 3] != group) {
                    id = -1;
                }
            }
        }
        if (id == 0) {
            continue;
        }
        const uint32_t he = topo->edge_hes[first];
        const float* a = &m.positions[size_t(m.triangles[he]) * 3];
        const float* b = &m.positions[size_t(m.triangles[next_corner(he)]) * 3];
        out.edge_points.insert(out.edge_points.end(), a, a + 3);
        out.edge_points.insert(out.edge_points.end(), b, b + 3);
        out.edge_ids.push_back(id);
    }
}

// ---------------------------------------------------------------- Tessellate (B-rep to mesh)

namespace
{
/// OCCT's progress hook as a deadline: the mesher asks between faces.
class MeshClock: public Message_ProgressIndicator
{
public:
    explicit MeshClock(double seconds)
        : end(std::chrono::steady_clock::now() + std::chrono::duration_cast<std::chrono::steady_clock::duration>(std::chrono::duration<double>(seconds)))
    {
    }
    bool UserBreak() override
    {
        if (!passed.load() && std::chrono::steady_clock::now() > end) {
            passed.store(true);
        }
        return passed.load();
    }
    void Show(const Message_ProgressScope&, const bool) override
    {
    }
    bool expired() const
    {
        return passed.load();
    }

private:
    std::chrono::steady_clock::time_point end;
    std::atomic<bool> passed{false};
};

struct Guess
{
    double triangles = 0.0;
    double seconds = 0.0;
};

/// A guess of the triangle count and the meshing time before meshing, from each face's size and
/// curvature at a 4 x 4 grid of its parameters. Rough (within a factor of about two on the
/// shapes measured): good enough to refuse a setting that would make tens of millions of
/// triangles, or run for minutes inside one face, before the mesher starts.
Guess estimate_triangles(const TopTools_IndexedMapOfShape& faces, double linear, double angular, bool relative)
{
    Guess total;
    auto add = [&](double triangles) {
        total.triangles += triangles;
        total.seconds += budget::TESSELLATE_FACE_SECONDS_AT_100K * std::pow(triangles / 1e5, budget::TESSELLATE_FACE_POWER);
    };
    for (int fi = 1; fi <= faces.Extent(); ++fi) {
        try {
            const TopoDS_Face& face = TopoDS::Face(faces(fi));
            BRepAdaptor_Surface surface(face);
            if (surface.GetType() == GeomAbs_Plane) {
                add(16.0);
                continue;
            }
            const double u0 = surface.FirstUParameter(), u1 = surface.LastUParameter();
            const double v0 = surface.FirstVParameter(), v1 = surface.LastVParameter();
            if (Precision::IsInfinite(u0) || Precision::IsInfinite(u1) || Precision::IsInfinite(v0) || Precision::IsInfinite(v1)) {
                continue;
            }
            BRepLProp_SLProps props(surface, 2, 1e-9);
            const double du = (u1 - u0) / 4.0, dv = (v1 - v0) / 4.0;
            double areas[16], k1[16], k2[16], area = 0.0;
            for (int i = 0; i < 16; ++i) {
                props.SetParameters(u0 + (i % 4 + 0.5) * du, v0 + (i / 4 + 0.5) * dv);
                areas[i] = props.D1U().Crossed(props.D1V()).Magnitude() * du * dv;
                area += areas[i];
                k1[i] = k2[i] = 0.0;
                if (props.IsCurvatureDefined()) {
                    k1[i] = std::max(std::fabs(props.MaxCurvature()), std::fabs(props.MinCurvature()));
                    k2[i] = std::min(std::fabs(props.MaxCurvature()), std::fabs(props.MinCurvature()));
                }
            }
            const double extent = std::sqrt(area);
            const double deflection = relative ? linear * extent : linear;
            if (!(extent > 0.0) || !(deflection > 0.0)) {
                continue;
            }
            auto edge = [&](double k) {
                if (!(k * extent > 1e-6)) {
                    return extent;  // straight that way: one edge spans the face
                }
                return std::min(extent, std::min(2.0 * std::sqrt(2.0 * deflection / k), angular / k));
            };
            double triangles = 16.0;
            for (int i = 0; i < 16; ++i) {
                const bool both = k2[i] * extent > 1e-6;
                triangles += (both ? budget::TESSELLATE_CURVED_FACTOR : 1.0) * 2.0 * areas[i] / (edge(k1[i]) * edge(k2[i]));
            }
            add(triangles);
        }
        catch (const Standard_Failure&) {
        }
    }
    return total;
}
}  // namespace

bool from_shape(const CadShape& shape, double linear, double angular, bool relative, double time_limit, MeshData& out, std::string& error)
{
    std::string warning;
    return from_shape(shape, linear, angular, relative, time_limit, out, error, warning);
}

bool from_shape(const CadShape& shape, double linear, double angular, bool relative, double time_limit, MeshData& out, std::string& error, std::string& warning)
{
    size_t dropped = 0;
    return from_shape(shape, linear, angular, relative, time_limit, out, error, warning, dropped);
}

bool from_shape(const CadShape& shape, double linear_asked, double angular, bool relative, double time_limit, MeshData& out, std::string& error, std::string& warning,
                size_t& dropped)
{
    warning.clear();
    dropped = 0;
    double linear = linear_asked;
    const TopoDS_Shape& source = shape.get_occ_shape();
    if (source.IsNull()) {
        error = "There is no body to tessellate.";
        return false;
    }
    const TopTools_IndexedMapOfShape& faces = shape.face_map();
    const int face_count = faces.Extent();
    if (face_count == 0) {
        error = "The body has no faces to tessellate.";
        return false;
    }
    // Ranges (the panel checks them too; never clamped in silence).
    const double degree = M_PI / 180.0;
    if (!(angular >= 1.0 * degree - 1e-9 && angular <= 45.0 * degree + 1e-9)) {
        error = "Normal Deviation must be between 1 and 45 degrees.";
        return false;
    }
    const godot::AABB box = shape.bbox();
    const double diagonal = double(box.size.length());
    if (relative) {
        if (!(linear >= 1e-5 && linear <= 0.1)) {
            error = "Surface Deviation (relative to size) must be between 0.00001 and 0.1.";
            return false;
        }
    }
    else {
        // From a tenth of the body's size down to 0.001 mm, or to 1 / 20,000 of the size on a
        // body so small that this is less (the finest preset is 1 / 20,000, so every preset
        // works on every body). How much work a fine value is, is judged below by the
        // triangles and the time it would take, not here.
        const double most = diagonal / 10.0, least = std::min(1e-6, diagonal / 20000.0);
        if (!(linear >= least * (1.0 - 1e-6) && linear <= most * (1.0 + 1e-6))) {
            error = "Surface Deviation must be between " + length_text(least) + " and " + length_text(most) + ".";
            return false;
        }
    }
    // The mesher takes no deviation below its own tolerance (0.0001 mm): on a body of under
    // 2 mm the fine presets ask for less. It is raised to that, and said; the Normal Deviation
    // still bounds the mesh (and is the finer of the two on a body that small).
    if (!relative && linear < Precision::Confusion()) {
        warning = "Surface Deviation was raised from " + length_text(linear) + " to " + length_text(Precision::Confusion()) +
                  ", the finest the mesher works to; Normal Deviation still applies.";
        linear = Precision::Confusion();
    }
    const auto refuse_count = [&](double triangles) {
        error = "Tessellate would make about " + with_commas(uint64_t(triangles)) + " triangles; lower the Refinement.";
        return false;
    };
    const Guess guess = estimate_triangles(faces, linear, angular, relative);
    if (guess.triangles > 4.0 * double(budget::MAX_TRIANGLES_MESH)) {
        return refuse_count(guess.triangles);
    }
    if (guess.seconds > time_limit) {
        error = "Tessellate would take about " + seconds_text(guess.seconds) + " s on this body (limit " + seconds_text(time_limit) + " s). Lower the Refinement.";
        return false;
    }

    struct Piece
    {
        Handle(Poly_Triangulation) tri;
        TopoDS_Face face;
        gp_Trsf trsf;
        bool reversed = false;
        uint32_t base = 0;
    };
    std::vector<Piece> pieces(static_cast<size_t>(face_count));
    std::vector<double> nodes;  // 3 per node, before welding
    TopoDS_Shape copy;
    TopTools_IndexedMapOfShape copied;
    try {
        // A copy without the body's own triangulation: the body's display mesh stays as it is.
        BRepBuilderAPI_Copy copier(source, false, false);
        copy = copier.Shape();
        IMeshTools_Parameters params;
        params.Deflection = linear;
        params.Angle = angular;
        params.Relative = relative;
        params.InParallel = false;
        const Handle(MeshClock) clock = new MeshClock(time_limit);
        const bool finished = guard::run_bounded(time_limit, [&] { BRepMesh_IncrementalMesh mesher(copy, params, clock->Start()); });
        if (!finished || clock->expired()) {
            error = "Tessellate took longer than " + seconds_text(time_limit) + " s and was stopped. Lower the Refinement.";
            return false;
        }
        TopExp::MapShapes(copy, TopAbs_FACE, copied);
        uint64_t triangles = 0, node_count = 0;
        for (int fi = 1; fi <= face_count; ++fi) {
            Piece& piece = pieces[size_t(fi - 1)];
            // The copy of face fi (the copy keeps the order of the faces; asked by face when it can be).
            TopoDS_Shape mapped = copier.ModifiedShape(faces(fi));
            if (mapped.IsNull() || mapped.ShapeType() != TopAbs_FACE || !copied.Contains(mapped)) {
                if (copied.Extent() != face_count) {
                    error = "Tessellate failed inside the CAD kernel: the copy of the body has other faces.";
                    return false;
                }
                mapped = copied(fi);
            }
            piece.face = TopoDS::Face(mapped);
            TopLoc_Location location;
            piece.tri = BRep_Tool::Triangulation(piece.face, location);
            const std::string name = size_t(fi - 1) < shape.face_name_list.size() ? shape.face_name_list[size_t(fi - 1)] : std::string();
            if (piece.tri.IsNull() || piece.tri->NbTriangles() == 0) {
                error = "Face " + (name.empty() ? std::to_string(fi) : name) + " could not be tessellated.";
                return false;
            }
            piece.trsf = location.Transformation();
            // (The orientation the face has in the body: the copy comes back without it.)
            piece.reversed = faces(fi).Orientation() == TopAbs_REVERSED;
            piece.base = uint32_t(node_count);
            triangles += uint64_t(piece.tri->NbTriangles());
            node_count += uint64_t(piece.tri->NbNodes());
        }
        if (triangles > budget::MAX_TRIANGLES_MESH) {
            return refuse_count(double(triangles));
        }
        nodes.resize(size_t(node_count) * 3);
        out = MeshData();
        out.triangles.reserve(size_t(triangles) * 3);
        out.groups.reserve(size_t(triangles));
        for (int fi = 1; fi <= face_count; ++fi) {
            const Piece& piece = pieces[size_t(fi - 1)];
            for (int n = 1; n <= piece.tri->NbNodes(); ++n) {
                const gp_Pnt p = piece.tri->Node(n).Transformed(piece.trsf);
                double* at = &nodes[(size_t(piece.base) + size_t(n - 1)) * 3];
                at[0] = p.X() + 0.0;  // -0 becomes +0
                at[1] = p.Y() + 0.0;
                at[2] = p.Z() + 0.0;
            }
            for (int t = 1; t <= piece.tri->NbTriangles(); ++t) {
                int a = 0, b = 0, c = 0;
                piece.tri->Triangle(t).Get(a, b, c);
                if (piece.reversed) {
                    std::swap(b, c);
                }
                // OCCT winds counter-clockwise around the outward normal, as the mesh is stored.
                out.triangles.push_back(piece.base + uint32_t(a - 1));
                out.triangles.push_back(piece.base + uint32_t(b - 1));
                out.triangles.push_back(piece.base + uint32_t(c - 1));
                out.groups.push_back(uint32_t(fi - 1));
            }
        }
        // Weld: nodes at bit-equal positions, and the nodes two faces hold for one point of a
        // shared edge (equal already unless the faces sit in different placements).
        const size_t N = nodes.size() / 3;
        Sets same(N);
        // Nodes that float32 stores at one place (far from the origin, where its step is coarse,
        // two nodes a few micrometres apart): one vertex too, when that keeps the mesh as closed
        // as it is (below). Otherwise they are two vertices at one place, and every triangle
        // between them is a needle without area.
        std::vector<uint32_t> stored_at;  // per node: the first node stored at its place
        {
            stored_at.resize(N);
            std::vector<std::pair<std::array<float, 3>, uint32_t>> rounded(N);
            for (size_t n = 0; n < N; ++n) {
                rounded[n] = {{float(nodes[n * 3]), float(nodes[n * 3 + 1]), float(nodes[n * 3 + 2])}, uint32_t(n)};
            }
            std::sort(rounded.begin(), rounded.end());
            for (size_t i = 0; i < N;) {
                size_t j = i;
                while (j < N && rounded[j].first == rounded[i].first) {
                    stored_at[rounded[j].second] = rounded[i].second;
                    ++j;
                }
                i = j;
            }
        }
        {
            size_t capacity = 16;
            while (capacity < N * 2) {
                capacity <<= 1;
            }
            std::vector<uint32_t> table(capacity, 0);
            for (size_t n = 0; n < N; ++n) {
                uint64_t bits[3];
                std::memcpy(bits, &nodes[n * 3], 24);
                uint64_t h = 0x51ED270B7F4A7C15ull;
                for (int k = 0; k < 3; ++k) {
                    h = (h ^ bits[k]) * 0x9E3779B97F4A7C15ull;
                    h ^= h >> 29;
                }
                size_t slot = size_t(h ^ (h >> 31)) & (capacity - 1);
                for (;;) {
                    const uint32_t held = table[slot];
                    if (held == 0) {
                        table[slot] = uint32_t(n) + 1;
                        break;
                    }
                    if (std::memcmp(&nodes[size_t(held - 1) * 3], &nodes[n * 3], 24) == 0) {
                        same.join(held - 1, uint32_t(n));
                        break;
                    }
                    slot = (slot + 1) & (capacity - 1);
                }
            }
        }
        TopTools_IndexedDataMapOfShapeListOfShape edge_faces;
        TopExp::MapShapesAndAncestors(copy, TopAbs_EDGE, TopAbs_FACE, edge_faces);
        for (int ei = 1; ei <= edge_faces.Extent(); ++ei) {
            const TopoDS_Edge& edge = TopoDS::Edge(edge_faces.FindKey(ei));
            Handle(Poly_PolygonOnTriangulation) first;
            uint32_t first_base = 0;
            for (TopTools_ListOfShape::Iterator it(edge_faces(ei)); it.More(); it.Next()) {
                const int index = copied.FindIndex(it.Value());
                if (index < 1 || index > face_count) {
                    continue;
                }
                const Piece& piece = pieces[size_t(index - 1)];
                TopLoc_Location location;
                const Handle(Poly_PolygonOnTriangulation) polygon = BRep_Tool::PolygonOnTriangulation(edge, piece.tri, location);
                if (polygon.IsNull()) {
                    continue;
                }
                if (first.IsNull()) {
                    first = polygon;
                    first_base = piece.base;
                    continue;
                }
                if (polygon->NbNodes() != first->NbNodes()) {
                    continue;
                }
                for (int i = 1; i <= polygon->NbNodes(); ++i) {
                    same.join(first_base + uint32_t(first->Node(i) - 1), piece.base + uint32_t(polygon->Node(i) - 1));
                }
            }
        }
        // Vertices in order of first use; a set's position is its first node's. A triangle with
        // two corners in one set is left out: where a face runs into a point (a ball's pole, a
        // cone's tip, the corner of a rounded box) the mesher has several nodes at that point and
        // a triangle between two of them. It has no area and no edge that another triangle needs
        // (its two sides are one edge, which its two neighbours then share).
        auto assemble = [&](Sets& sets, MeshData& mesh, size_t& left_out) {
            mesh.positions.clear();
            mesh.triangles.assign(out.triangles.size(), 0);
            mesh.groups.assign(out.groups.size(), 0);
            left_out = 0;
            std::vector<uint32_t> vertex_of(N, NONE);
            size_t kept = 0;
            const size_t made = out.triangles.size() / 3;
            for (size_t t = 0; t < made; ++t) {
                uint32_t roots[3];
                for (int k = 0; k < 3; ++k) {
                    roots[k] = sets.find(out.triangles[t * 3 + size_t(k)]);
                }
                if (roots[0] == roots[1] || roots[1] == roots[2] || roots[0] == roots[2]) {
                    ++left_out;
                    continue;
                }
                for (int k = 0; k < 3; ++k) {
                    const uint32_t root = roots[k];
                    if (vertex_of[root] == NONE) {
                        vertex_of[root] = uint32_t(mesh.positions.size() / 3);
                        for (int a = 0; a < 3; ++a) {
                            mesh.positions.push_back(float(nodes[size_t(root) * 3 + size_t(a)]));
                        }
                    }
                    mesh.triangles[kept * 3 + size_t(k)] = vertex_of[root];
                }
                mesh.groups[kept] = out.groups[t];
                ++kept;
            }
            mesh.triangles.resize(kept * 3);
            mesh.groups.resize(kept);
        };
        // Nodes at one float32 place joined too, when that adds no open or shared-by-three edge.
        Sets stored = same;
        bool more = false;
        for (size_t n = 0; n < N; ++n) {
            if (stored.find(uint32_t(n)) != stored.find(stored_at[n])) {
                stored.join(uint32_t(n), stored_at[n]);
                more = true;
            }
        }
        MeshData plain;
        assemble(same, plain, dropped);
        if (more) {
            MeshData joined;
            size_t joined_dropped = 0;
            assemble(stored, joined, joined_dropped);
            State a, b;
            a.data.positions = plain.positions;
            a.data.triangles = plain.triangles;
            b.data.positions = joined.positions;
            b.data.triangles = joined.triangles;
            const Topology* ta = topology_of(a);
            const Topology* tb = topology_of(b);
            if (ta != nullptr && tb != nullptr && tb->boundary_edges <= ta->boundary_edges && tb->non_manifold_edges <= ta->non_manifold_edges) {
                plain = std::move(joined);
                dropped = joined_dropped;
            }
        }
        out.positions = std::move(plain.positions);
        out.triangles = std::move(plain.triangles);
        out.groups = std::move(plain.groups);
    }
    catch (const Standard_Failure& failure) {
        const char* what = failure.what();
        error = std::string("Tessellate failed inside the CAD kernel: ") + (what != nullptr && what[0] != '\0' ? what : "unknown error") + ".";
        return false;
    }
    // One group per face, named after the face (work order 2.2.2).
    out.group_names.resize(size_t(face_count));
    for (int fi = 0; fi < face_count; ++fi) {
        out.group_names[size_t(fi)] = size_t(fi) < shape.face_name_list.size() ? shape.face_name_list[size_t(fi)] : std::string();
    }
    repair_group_names(out.group_names);
    if (out.positions.size() / 3 > budget::MAX_VERTICES_MESH) {
        return refuse_count(double(out.triangle_count()));
    }
    const std::string problem = validate(out);
    if (!problem.empty()) {
        error = problem;
        return false;
    }
    // Triangles without area are made only where float32 cannot hold the mesher's nodes apart
    // (far from the origin): counted, and the place named.
    size_t flat = 0;
    for (size_t t = 0; t < out.triangle_count(); ++t) {
        flat += without_area(out, t) ? 1 : 0;
    }
    if (flat > 0) {
        const std::string far = far_note(out);
        const std::string sentence = "Tessellate made " + (flat == 1 ? std::string("1 triangle") : with_commas(flat) + " triangles") + " without area" +
                                     (far.empty() ? std::string(".") : ": " + far + ". Move the body nearer the origin first.");
        warning = warning.empty() ? sentence : warning + "\n" + sentence;
    }
    return true;
}

std::string far_note(const MeshData& mesh)
{
    if (mesh.positions.empty()) {
        return std::string();
    }
    double lo[3] = {INFINITY, INFINITY, INFINITY}, hi[3] = {-INFINITY, -INFINITY, -INFINITY}, reach = 0.0;
    for (size_t i = 0; i < mesh.positions.size(); ++i) {
        const double v = mesh.positions[i];
        lo[i % 3] = std::min(lo[i % 3], v);
        hi[i % 3] = std::max(hi[i % 3], v);
        reach = std::max(reach, std::fabs(v));
    }
    double size2 = 0.0, centre2 = 0.0;
    for (int k = 0; k < 3; ++k) {
        size2 += (hi[k] - lo[k]) * (hi[k] - lo[k]);
        centre2 += 0.25 * (hi[k] + lo[k]) * (hi[k] + lo[k]);
    }
    // float32's step at the largest coordinate: 2^(exponent - 23).
    const double step = reach > 0.0 ? std::ldexp(1.0, std::ilogb(reach) - 23) : 0.0;
    if (!(step > 1e-4 * std::sqrt(size2))) {
        return std::string();
    }
    return "the body is " + length_text(std::sqrt(centre2)) + " from the origin, where positions are stored only to about " + length_text(step);
}

}  // namespace holo_forge::mesh
