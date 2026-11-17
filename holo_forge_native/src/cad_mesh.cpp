#include "cad_mesh.h"

#include "cad_shape.h"
#include "mesh_budget.h"
#include "mesh_bvh.h"
#include "mesh_contact.h"
#include "mesh_deadline.h"
#include "transform64.h"

#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/plane.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <clipper2/clipper.version.h>
#include <manifold/manifold.h>
#include <manifold/version.h>
#include <meshoptimizer.h>
// pmp has a class named Handle; OpenCASCADE (through cad_shape.h) defines a macro Handle(Class).
// Every file that includes a pmp header after an OCCT one needs this push/undef/pop around it.
#pragma push_macro("Handle")
#undef Handle
#include <pmp/surface_mesh.h>
#pragma pop_macro("Handle")

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <exception>
#include <limits>

using namespace godot;

namespace holo_forge
{

namespace
{
constexpr double kInf = std::numeric_limits<double>::infinity();

inline String text(const std::string& s)
{
    return String::utf8(s.c_str(), int64_t(s.size()));
}
inline std::string plain(const String& s)
{
    const CharString utf8 = s.utf8();
    return std::string(utf8.get_data(), size_t(utf8.length()));
}
inline Vector3 vec3(const double* p)
{
    return Vector3(real_t(p[0]), real_t(p[1]), real_t(p[2]));
}
inline void doubles(const Vector3& v, double out[3])
{
    out[0] = v.x;
    out[1] = v.y;
    out[2] = v.z;
}
double now_ms()
{
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

PackedVector3Array vec3_array(const float* data, size_t count)
{
    PackedVector3Array out;
    out.resize(int64_t(count));
    if (count == 0) {
        return out;
    }
    Vector3* w = out.ptrw();
    if (sizeof(Vector3) == sizeof(float) * 3) {
        std::memcpy(static_cast<void*>(w), data, count * sizeof(float) * 3);
    }
    else {
        for (size_t i = 0; i < count; ++i) {
            w[i] = Vector3(data[i * 3], data[i * 3 + 1], data[i * 3 + 2]);
        }
    }
    return out;
}

PackedVector3Array vec3_array(const std::vector<double>& data)
{
    PackedVector3Array out;
    out.resize(int64_t(data.size() / 3));
    Vector3* w = out.ptrw();
    for (size_t i = 0; i < data.size() / 3; ++i) {
        w[i] = vec3(&data[i * 3]);
    }
    return out;
}

PackedInt32Array int_array(const int32_t* data, size_t count)
{
    PackedInt32Array out;
    out.resize(int64_t(count));
    if (count > 0) {
        std::memcpy(out.ptrw(), data, count * sizeof(int32_t));
    }
    return out;
}

PackedInt32Array int_array(const std::vector<uint32_t>& data)
{
    return int_array(reinterpret_cast<const int32_t*>(data.data()), data.size());
}

std::vector<uint32_t> index_list(const PackedInt32Array& tris)
{
    std::vector<uint32_t> out;
    out.reserve(size_t(tris.size()));
    const int32_t* r = tris.ptr();
    for (int64_t i = 0; i < tris.size(); ++i) {
        if (r[i] >= 0) {
            out.push_back(uint32_t(r[i]));
        }
    }
    return out;
}

Dictionary summary_dict(const mesh::Summary& s, bool output)
{
    Dictionary d;
    d["triangles"] = s.triangles;
    d["vertices"] = s.vertices;
    d["groups"] = s.groups;
    d["closed"] = s.closed;
    d["boundary_edges"] = s.boundary_edges;
    d["volume"] = s.volume;
    d["area"] = s.area;
    if (output) {
        d["non_manifold_edges"] = s.non_manifold_edges;
        d["degenerate_triangles"] = s.degenerate_triangles;
        d["components"] = s.components;
    }
    return d;
}
}  // namespace

CadMesh::CadMesh() : state(std::make_unique<mesh::State>())
{
}

CadMesh::~CadMesh() = default;

void CadMesh::clear_messages() const
{
    last_error = String();
    last_warning = String();
    last_report = Dictionary();
}

bool CadMesh::fail(const std::string& message) const
{
    last_error = text(message);
    return false;
}

bool CadMesh::fresh(const char*)
{
    if (made) {
        last_error = "A mesh cannot change once made.";
        return false;
    }
    return true;
}

bool CadMesh::adopt(mesh::MeshData&& data)
{
    state = std::make_unique<mesh::State>();
    state->data = std::move(data);
    contact_cache.reset();  // (Phase 8 contact: a Manifold of the old data must not answer for the new)
    made = true;
    return true;
}

Ref<CadMesh> CadMesh::wrap(mesh::MeshData&& data, std::string* error)
{
    mesh::MeshData result = std::move(data);
    // Ranges first: compact() indexes by them.
    std::string problem = mesh::validate(result);
    if (problem.empty()) {
        mesh::compact(result);
        problem = mesh::validate(result);
    }
    if (!problem.empty()) {
        if (error != nullptr) {
            *error = problem;
        }
        return Ref<CadMesh>();
    }
    Ref<CadMesh> out;
    out.instantiate();
    out->adopt(std::move(result));
    return out;
}

Ref<CadMesh> CadMesh::finish_op(const char* title, const char* op, mesh::MeshData&& result, double started_ms, bool test_self_intersections)
{
    std::string problem;
    Ref<CadMesh> out = wrap(std::move(result), &problem);
    if (out.is_null()) {
        last_error = String(title) + String(" made a broken mesh (internal error). Please report it.");
        Dictionary checks;
        checks["valid"] = String("fail: ") + text(problem);
        last_report["op"] = String(op);
        last_report["checks"] = checks;
        return out;
    }
    const mesh::Summary before = mesh::summarize(*state);
    const mesh::Summary after = mesh::summarize(out->get_state());
    Dictionary checks;
    checks["valid"] = "ok";
    PackedStringArray warnings;
    char line[256];
    auto warn = [&](const char* key, const char* sentence) {
        checks[key] = String("warn: ") + String::utf8(sentence);
        warnings.push_back(String::utf8(sentence));
    };
    if (after.degenerate_triangles > before.degenerate_triangles) {
        const long long made = static_cast<long long>(after.degenerate_triangles - before.degenerate_triangles);
        std::snprintf(line, sizeof(line), made == 1 ? "%s made %lld triangle without area." : "%s made %lld triangles without area.", title, made);
        warn("degenerate", line);
    }
    else {
        checks["degenerate"] = "ok";
    }
    if (after.non_manifold_edges > before.non_manifold_edges) {
        const long long made = static_cast<long long>(after.non_manifold_edges - before.non_manifold_edges);
        std::snprintf(line, sizeof(line), made == 1 ? "%s made %lld edge that more than two triangles share." : "%s made %lld edges that more than two triangles share.", title, made);
        warn("non_manifold", line);
    }
    else {
        checks["non_manifold"] = "ok";
    }
    if (after.inverted_components > before.inverted_components) {
        const long long made = static_cast<long long>(after.inverted_components - before.inverted_components);
        std::snprintf(line, sizeof(line), made == 1 ? "%lld part is inside-out." : "%lld parts are inside-out.", made);
        warn("orientation", line);
    }
    else {
        checks["orientation"] = "ok";
    }
    int64_t crossings = -1;
    if (test_self_intersections) {
        double took_ms = 0.0;
        crossings = mesh::self_intersections_within(out->get_state(), mesh::budget::SELF_INTERSECTION_SECONDS, nullptr, &took_ms);
        if (crossings > 0) {
            const int64_t were = mesh::self_intersections_within(*state, mesh::budget::SELF_INTERSECTION_SECONDS - took_ms / 1000.0, nullptr);
            if (were >= 0 && crossings > were) {
                const long long made = static_cast<long long>(crossings - were);
                std::snprintf(line, sizeof(line), made == 1 ? "%s made %lld place where the mesh crosses itself." : "%s made %lld places where the mesh crosses itself.", title, made);
                warn("self_intersections", line);
            }
            else if (were >= 0) {
                checks["self_intersections"] = "ok";
            }
            // (Not compared with the input in time: no claim, the key stays out.)
        }
        else if (crossings == 0) {
            checks["self_intersections"] = "ok";
        }
        // (Not checked in time: -1 in the report and no entry in the checks.)
    }
    last_report["op"] = String(op);
    last_report["input"] = summary_dict(before, false);
    last_report["output"] = summary_dict(after, true);
    last_report["deviation"] = Dictionary();
    last_report["self_intersections"] = crossings;
    last_report["checks"] = checks;
    last_report["ms"] = now_ms() - started_ms;
    if (!warnings.is_empty()) {
        last_warning = String("\n").join(warnings);
    }
    return out;
}

// ---------------------------------------------------------------- construction and IO

bool CadMesh::set_arrays(const PackedVector3Array& positions, const PackedInt32Array& indices, const PackedInt32Array& groups, const PackedStringArray& group_names,
                         const String& winding)
{
    clear_messages();
    if (!fresh("set_arrays")) {
        return false;
    }
    const bool flip = winding == "godot";
    if (!flip && winding != "ccw") {
        UtilityFunctions::push_error("CadMesh.set_arrays: winding must be \"godot\" or \"ccw\".");
        return fail("The mesh arrays are broken: the winding must be \"godot\" or \"ccw\".");
    }
    if (indices.size() % 3 != 0) {
        return fail("The mesh arrays are broken: the index count is not a multiple of 3.");
    }
    const size_t V = size_t(positions.size()), T = size_t(indices.size() / 3);
    // Sizes before anything is allocated.
    const std::string sizes = mesh::validate_sizes(V, T, uint64_t(group_names.size()));
    if (!sizes.empty()) {
        return fail(sizes);
    }
    if (groups.size() != 0 && size_t(groups.size()) != T) {
        return fail("The mesh arrays are broken: there are " + mesh::with_commas(T) + " triangles but " + mesh::with_commas(uint64_t(groups.size())) + " group ids.");
    }
    mesh::MeshData data;
    data.positions.resize(V * 3);
    const Vector3* p = positions.ptr();
    for (size_t v = 0; v < V; ++v) {
        data.positions[v * 3] = float(p[v].x);
        data.positions[v * 3 + 1] = float(p[v].y);
        data.positions[v * 3 + 2] = float(p[v].z);
    }
    data.triangles.resize(T * 3);
    const int32_t* idx = indices.ptr();
    for (size_t i = 0; i < T * 3; ++i) {
        if (idx[i] < 0) {
            return fail("The mesh arrays are broken: triangle " + mesh::with_commas(i / 3) + " points at vertex " + std::to_string(idx[i]) + ".");
        }
        data.triangles[i] = uint32_t(idx[i]);
    }
    if (flip) {
        for (size_t t = 0; t < T; ++t) {
            std::swap(data.triangles[t * 3 + 1], data.triangles[t * 3 + 2]);
        }
    }
    uint32_t highest = 0;
    if (groups.size() == 0) {
        data.groups.assign(T, 0);
    }
    else {
        data.groups.resize(T);
        const int32_t* g = groups.ptr();
        for (size_t t = 0; t < T; ++t) {
            if (g[t] < 0) {
                return fail("The mesh arrays are broken: triangle " + mesh::with_commas(t) + " is in face group " + std::to_string(g[t]) + ".");
            }
            data.groups[t] = uint32_t(g[t]);
            highest = std::max(highest, data.groups[t]);
        }
    }
    if (group_names.size() == 0) {
        // No names given: g0, g1, ...
        if (size_t(highest) + 1 > mesh::budget::MAX_GROUPS_MESH) {
            return fail(mesh::validate_sizes(V, T, uint64_t(highest) + 1));
        }
        for (uint32_t g = 0; g <= highest; ++g) {
            data.group_names.push_back("g" + std::to_string(g));
        }
    }
    else {
        for (int64_t g = 0; g < group_names.size(); ++g) {
            data.group_names.push_back(plain(group_names[g]));
        }
    }
    const std::string problem = mesh::validate(data);
    if (!problem.empty()) {
        return fail(problem);
    }
    return adopt(std::move(data));
}

bool CadMesh::from_blob(const PackedByteArray& bytes)
{
    clear_messages();
    if (!fresh("from_blob")) {
        return false;
    }
    mesh::MeshData data;
    std::string error;
    if (!mesh::read_blob(bytes.ptr(), size_t(bytes.size()), data, error)) {
        return fail(error);
    }
    return adopt(std::move(data));
}

PackedByteArray CadMesh::to_blob() const
{
    PackedByteArray out;
    out.resize(int64_t(mesh::blob_size(state->data)));
    mesh::write_blob(state->data, out.ptrw());
    return out;
}

namespace
{
/// Opens a file and reads it whole, after `early` (given the first bytes and the size) agreed.
template <class F>
bool read_file(const String& path, PackedByteArray& bytes, std::string& label, std::string& error, F&& early)
{
    label = plain(path.get_file());
    Ref<FileAccess> file = FileAccess::open(path, FileAccess::READ);
    if (file.is_null()) {
        error = label + " could not be opened.";
        return false;
    }
    const uint64_t size = file->get_length();
    const PackedByteArray head = file->get_buffer(int64_t(std::min<uint64_t>(size, 1024)));
    if (!early(head, size)) {
        return false;
    }
    file->seek(0);
    bytes = file->get_buffer(int64_t(size));
    if (uint64_t(bytes.size()) != size) {
        error = label + " could not be read to its end.";
        return false;
    }
    return true;
}
}  // namespace

bool CadMesh::read_stl(const String& path, double scale)
{
    clear_messages();
    if (!fresh("read_stl")) {
        return false;
    }
    PackedByteArray bytes;
    std::string label, error;
    const bool opened = read_file(path, bytes, label, error, [&](const PackedByteArray& head, uint64_t size) {
        // Refused before the file is read: a binary header that claims too many triangles, a
        // text file too large to hold fewer.
        const mesh::FileBytes first{head.ptr(), size_t(head.size())};
        if (mesh::stl_is_binary(first, size)) {
            const uint64_t count = mesh::stl_binary_count(first);
            if (count > mesh::budget::MAX_TRIANGLES_MESH) {
                error = label + " has " + mesh::with_commas(count) + " triangles; mesh bodies take up to " + mesh::with_commas(mesh::budget::MAX_TRIANGLES_MESH) + ".";
                return false;
            }
        }
        else if (double(size) > mesh::budget::MAX_TEXT_FILE_BYTES) {
            error = label + " is a text file of " + mesh::with_commas(size) + " bytes; text files up to " + mesh::with_commas(uint64_t(mesh::budget::MAX_TEXT_FILE_BYTES)) +
                    " bytes can be read.";
            return false;
        }
        return true;
    });
    if (!opened) {
        return fail(error);
    }
    mesh::MeshData data;
    std::string warning;
    if (!mesh::parse_stl({bytes.ptr(), size_t(bytes.size())}, label, scale, data, error, warning)) {
        return fail(error);
    }
    // (A damaged file that was still loaded: what is missing.)
    last_warning = text(warning);
    return adopt(std::move(data));
}

bool CadMesh::read_obj(const String& path, double scale)
{
    clear_messages();
    if (!fresh("read_obj")) {
        return false;
    }
    PackedByteArray bytes;
    std::string label, error;
    const bool opened = read_file(path, bytes, label, error, [&](const PackedByteArray&, uint64_t size) {
        if (double(size) > mesh::budget::MAX_TEXT_FILE_BYTES) {
            error = label + " is a text file of " + mesh::with_commas(size) + " bytes; text files up to " + mesh::with_commas(uint64_t(mesh::budget::MAX_TEXT_FILE_BYTES)) +
                    " bytes can be read.";
            return false;
        }
        return true;
    });
    if (!opened) {
        return fail(error);
    }
    mesh::MeshData data;
    std::string warning;
    if (!mesh::parse_obj({bytes.ptr(), size_t(bytes.size())}, label, scale, data, error, warning)) {
        return fail(error);
    }
    last_warning = text(warning);
    return adopt(std::move(data));
}

bool CadMesh::from_shape(const Ref<CadShape>& shape, double linear, double angular, bool relative, double time_limit)
{
    clear_messages();
    if (!fresh("from_shape")) {
        return false;
    }
    if (shape.is_null() || shape->is_null()) {
        return fail("There is no body to tessellate.");
    }
    const double started = now_ms();
    const double limit = mesh::clamp_time_limit(time_limit);
    mesh::MeshData data;
    std::string error, mesher_warning;
    size_t dropped = 0;  // triangles left out at points where a face runs together
    bool ok = false;
    try {
        ok = mesh::from_shape(*shape.ptr(), linear, angular, relative, limit, data, error, mesher_warning, dropped);
    }
    catch (const std::exception& e) {
        error = std::string("Tessellate failed: ") + e.what();
    }
    catch (...) {
        error = "Tessellate failed.";
    }
    if (!ok) {
        return fail(error);
    }
    auto fresh_state = std::make_unique<mesh::State>();
    fresh_state->data = std::move(data);
    // Must hold: a closed B-rep solid gives a closed mesh with its volume: within 1 % without a
    // word, up to 5 % off with a warning that gives the percent, refused beyond.
    String volume_warning;
    Dictionary checks;
    checks["valid"] = "ok";
    const mesh::Summary after = mesh::summarize(*fresh_state);
    if (shape->solid_count() > 0 && !shape->is_surface()) {
        char line[400];
        if (after.boundary_edges > 0 || after.non_manifold_edges > 0) {
            // (Far from the origin, float32 is the cause, not the Refinement.)
            const std::string far = mesh::far_note(fresh_state->data);
            std::snprintf(line, sizeof(line), "Tessellate left %lld open edges and %lld edges shared by more than two triangles on a closed body%s",
                          static_cast<long long>(after.boundary_edges), static_cast<long long>(after.non_manifold_edges),
                          far.empty() ? ". Raise the Refinement." : (": " + far + ". Move the body nearer the origin first.").c_str());
            checks["boundary"] = String("fail: ") + text(line);
            last_report["checks"] = checks;
            return fail(line);
        }
        checks["boundary"] = "ok";
        const double exact = shape->volume();
        const double percent = 100.0 * std::fabs(after.volume - exact) / std::max(std::fabs(exact), 1e-300);
        if (percent > 5.0) {
            std::snprintf(line, sizeof(line), "The mesh's volume is %.1f %% off the body's (more than 5 %%). Raise the Refinement.", percent);
            checks["volume"] = String("fail: ") + String(line);
            last_report["checks"] = checks;
            return fail(line);
        }
        if (percent > 1.0) {
            std::snprintf(line, sizeof(line), "The mesh's volume is %.1f %% off the body's. Raise the Refinement for a closer mesh.", percent);
            checks["volume"] = String("warn: ") + String(line);
            volume_warning = String(line);
        }
        else {
            checks["volume"] = "ok";
        }
    }
    last_warning = text(mesher_warning);
    if (!volume_warning.is_empty()) {
        last_warning = last_warning.is_empty() ? volume_warning : last_warning + String("\n") + volume_warning;
    }
    state = std::move(fresh_state);
    made = true;
    last_report["op"] = "tessellate";
    last_report["ms"] = now_ms() - started;
    last_report["input"] = Dictionary();
    last_report["output"] = summary_dict(after, true);
    last_report["deviation"] = Dictionary();
    last_report["self_intersections"] = -1;
    last_report["checks"] = checks;
    last_report["dropped_triangles"] = int64_t(dropped);
    return true;
}

Dictionary CadMesh::get_arrays() const
{
    const mesh::MeshData& m = state->data;
    Dictionary out;
    out["positions"] = vec3_array(m.positions.data(), m.vertex_count());
    PackedInt32Array indices;
    indices.resize(int64_t(m.triangles.size()));
    int32_t* w = indices.ptrw();
    for (size_t t = 0; t < m.triangle_count(); ++t) {
        w[t * 3] = int32_t(m.triangles[t * 3]);
        w[t * 3 + 1] = int32_t(m.triangles[t * 3 + 2]);
        w[t * 3 + 2] = int32_t(m.triangles[t * 3 + 1]);
    }
    out["indices"] = indices;
    out["groups"] = int_array(m.groups);
    out["group_names"] = get_face_names();
    return out;
}

Dictionary CadMesh::library_versions()
{
    clear_messages();
    char line[64];
    Dictionary out;
    // pmp has no version macro: the vcpkg port version, set by CMake.
    out["pmp"] = String(HOLO_FORGE_PMP_PORT_VERSION);
    std::snprintf(line, sizeof(line), "%d.%d.%d", MANIFOLD_VERSION_MAJOR, MANIFOLD_VERSION_MINOR, MANIFOLD_VERSION_PATCH);
    out["manifold"] = String(line);
    std::snprintf(line, sizeof(line), "%d.%d", MESHOPTIMIZER_VERSION / 1000, (MESHOPTIMIZER_VERSION % 1000) / 10);
    out["meshoptimizer"] = String(line);
    out["clipper2"] = String(CLIPPER2_VERSION);

    // One real call into each DLL: a tetrahedron through all three.
    try {
        pmp::SurfaceMesh tetra;
        const pmp::Vertex a = tetra.add_vertex(pmp::Point(0, 0, 0));
        const pmp::Vertex b = tetra.add_vertex(pmp::Point(1, 0, 0));
        const pmp::Vertex c = tetra.add_vertex(pmp::Point(0, 1, 0));
        const pmp::Vertex d = tetra.add_vertex(pmp::Point(0, 0, 1));
        tetra.add_triangle(a, c, b);
        tetra.add_triangle(a, b, d);
        tetra.add_triangle(b, c, d);
        tetra.add_triangle(c, a, d);
        if (tetra.n_faces() != 4 || tetra.n_edges() != 6) {
            last_error = "The pmp mesh library gave a wrong answer (a tetrahedron should have 4 faces and 6 edges).";
        }
    }
    catch (const std::exception& e) {
        last_error = String("The pmp mesh library failed: ") + String::utf8(e.what());
    }
    catch (...) {
        last_error = "The pmp mesh library failed.";
    }
    try {
        const manifold::Manifold tetrahedron = manifold::Manifold::Tetrahedron();
        if (tetrahedron.Status() != manifold::Manifold::Error::NoError || tetrahedron.NumTri() != 4) {
            last_error = "The Manifold mesh library gave a wrong answer (its tetrahedron should have 4 triangles).";
        }
    }
    catch (const std::exception& e) {
        last_error = String("The Manifold mesh library failed: ") + String::utf8(e.what());
    }
    catch (...) {
        last_error = "The Manifold mesh library failed.";
    }
    {
        const float positions[12] = {0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1};
        const unsigned int indices[12] = {0, 2, 1, 0, 1, 3, 1, 2, 3, 2, 0, 3};
        unsigned int kept[12] = {};
        const size_t count = meshopt_simplify(kept, indices, 12, positions, 4, sizeof(float) * 3, 12, 0.0f, 0, nullptr);
        if (count != 12) {
            last_error = "The meshoptimizer library gave a wrong answer (a tetrahedron kept whole should keep 12 indices).";
        }
    }
    return out;
}

String CadMesh::group_name_for(const String& face_name) const
{
    return text(mesh::short_group_name(plain(face_name)));
}

// ---------------------------------------------------------------- the CadShape subset

bool CadMesh::is_null() const
{
    return state->data.triangle_count() == 0;
}

String CadMesh::shape_type() const
{
    return "MESH";
}

AABB CadMesh::bbox()
{
    const mesh::Measures& ms = mesh::measures_of(*state);
    if (!ms.any) {
        return AABB();
    }
    return AABB(vec3(ms.lo), Vector3(real_t(ms.hi[0] - ms.lo[0]), real_t(ms.hi[1] - ms.lo[1]), real_t(ms.hi[2] - ms.lo[2])));
}

Dictionary CadMesh::tessellate(double, double)
{
    Dictionary out;
    if (is_null()) {
        return out;
    }
    mesh::Tessellation t;
    mesh::tessellate(*state, t);
    out["positions"] = vec3_array(t.positions.data(), t.positions.size() / 3);
    out["normals"] = vec3_array(t.normals.data(), t.normals.size() / 3);
    PackedVector2Array uvs;
    uvs.resize(int64_t(t.uvs.size() / 2));
    Vector2* w = uvs.ptrw();
    for (size_t i = 0; i < t.uvs.size() / 2; ++i) {
        w[i] = Vector2(t.uvs[i * 2], t.uvs[i * 2 + 1]);
    }
    out["uvs"] = uvs;
    out["indices"] = int_array(t.indices.data(), t.indices.size());
    out["face_ids"] = int_array(t.face_ids.data(), t.face_ids.size());
    out["edge_points"] = vec3_array(t.edge_points.data(), t.edge_points.size() / 3);
    out["edge_ids"] = int_array(t.edge_ids.data(), t.edge_ids.size());
    out["vertices"] = PackedVector3Array();
    return out;
}

double CadMesh::volume()
{
    if (is_null() || !mesh::is_closed(*state)) {
        return 0.0;
    }
    return mesh::measures_of(*state).volume;
}

double CadMesh::area()
{
    return mesh::measures_of(*state).area;
}

Vector3 CadMesh::center_of_mass()
{
    if (is_null()) {
        return Vector3();
    }
    return vec3(mesh::mass_properties(*state).centre);
}

Dictionary CadMesh::mass_properties(double density)
{
    Dictionary out;
    if (is_null()) {
        return out;
    }
    const mesh::MassProperties mp = mesh::mass_properties(*state, true);
    // A closed mesh: the solid's values for the density. An open one has no volume to weigh: its
    // surface's second moments of area (m4, as for 1 kg per square meter) are given as they are.
    const double scale = mp.closed ? density : 1.0;
    PackedFloat64Array inertia;
    for (int i = 0; i < 9; ++i) {
        inertia.push_back(mp.inertia[i] * scale);
    }
    out["volume"] = mp.volume;
    out["area"] = mp.area;
    out["mass"] = mp.volume * density;
    out["center"] = vec3(mp.centre);
    out["inertia"] = inertia;
    out["principal_moments"] = Vector3(real_t(mp.principal[0] * scale), real_t(mp.principal[1] * scale), real_t(mp.principal[2] * scale));
    // What is wrong with the mesh, when the numbers are less than the truth because of it.
    PackedStringArray flaws, sentences;
    char line[400];
    const char* surface = "the center and the inertia are those of its surface (as a shell of 1 kg per square meter)";
    // (Said once: by the first flaw that leaves the mesh without a volume.)
    bool surface_said = false;
    if (mp.open) {
        flaws.push_back("open");
        std::snprintf(line, sizeof(line), "The mesh is open, so it has no volume and no mass; %s.", surface);
        sentences.push_back(String(line));
        surface_said = true;
    }
    if (mp.non_manifold_edges > 0) {
        flaws.push_back("non_manifold");
        out["non_manifold_edges"] = mp.non_manifold_edges;
        const std::string edges = mp.non_manifold_edges == 1 ? std::string("1 edge of the mesh is") : mesh::with_commas(uint64_t(mp.non_manifold_edges)) + " edges of the mesh are";
        if (surface_said) {
            std::snprintf(line, sizeof(line), "%s shared by more than two triangles. Stitch and Remove can fix it.", edges.c_str());
        }
        else {
            std::snprintf(line, sizeof(line), "%s shared by more than two triangles, so the volume and the mass cannot be measured; %s. Stitch and Remove can fix it.", edges.c_str(),
                          surface);
        }
        sentences.push_back(String(line));
        surface_said = true;
    }
    if (mp.wrong_way_edges > 0) {
        flaws.push_back("wrong_way");
        out["wrong_way_edges"] = mp.wrong_way_edges;
        const std::string edges = mp.wrong_way_edges == 1 ? std::string("1 edge") : mesh::with_commas(uint64_t(mp.wrong_way_edges)) + " edges";
        if (surface_said) {
            std::snprintf(line, sizeof(line), "Triangles face the wrong way at %s. Stitch and Remove or Reverse Normal can fix it.", edges.c_str());
        }
        else {
            std::snprintf(line, sizeof(line), "Triangles face the wrong way at %s, so the volume and the mass cannot be measured; %s. Stitch and Remove or Reverse Normal can fix it.",
                          edges.c_str(), surface);
        }
        sentences.push_back(String(line));
        surface_said = true;
    }
    if (!mp.closed && !surface_said) {
        flaws.push_back("no_volume");
        std::snprintf(line, sizeof(line), "The mesh encloses no volume, so it has no mass; %s.", surface);
        sentences.push_back(String(line));
    }
    if (mp.inside_out_parts > 0) {
        flaws.push_back("inside_out");
        out["inside_out_parts"] = mp.inside_out_parts;
        if (mp.inside_out_parts == 1) {
            std::snprintf(line, sizeof(line), "1 part of the mesh is inside-out, so the volume, the mass and the center may be wrong. Reverse Normal fixes it.");
        }
        else {
            std::snprintf(line, sizeof(line), "%s parts of the mesh are inside-out, so the volume, the mass and the center may be wrong. Reverse Normal fixes it.",
                          mesh::with_commas(uint64_t(mp.inside_out_parts)).c_str());
        }
        sentences.push_back(String(line));
    }
    if (mp.self_intersections > 0) {
        flaws.push_back("self_crossing");
        out["self_intersections"] = mp.self_intersections;
        std::snprintf(line, sizeof(line), "The mesh crosses itself at %s, so the volume, the mass and the center count the overlap more than once. Rebuild fixes it.",
                      mp.self_intersections == 1 ? "1 place" : (mesh::with_commas(uint64_t(mp.self_intersections)) + " places").c_str());
        sentences.push_back(String(line));
    }
    if (!flaws.is_empty()) {
        out["flaws"] = flaws;
        out["warning"] = String("\n").join(sentences);
    }
    return out;
}

int CadMesh::face_count() const
{
    return int(state->data.group_count());
}

PackedStringArray CadMesh::get_face_names() const
{
    PackedStringArray names;
    for (const std::string& name : state->data.group_names) {
        names.push_back(text(name));
    }
    return names;
}

int CadMesh::find_face(const String& name) const
{
    const std::string wanted = plain(name);
    const std::vector<std::string>& names = state->data.group_names;
    for (size_t g = 0; g < names.size(); ++g) {
        if (names[g] == wanted) {
            return int(g);
        }
    }
    return -1;
}

Dictionary CadMesh::face_info(int group)
{
    Dictionary out;
    if (group < 0) {
        return out;
    }
    const mesh::GroupInfo info = mesh::group_info(*state, uint32_t(group));
    if (!info.valid) {
        return out;
    }
    out["type"] = info.planar ? "plane" : "mesh_group";
    out["planar"] = info.planar;
    out["point"] = vec3(info.point);
    out["area"] = info.area;
    out["normal"] = vec3(info.normal);
    out["edges"] = PackedInt32Array();
    out["triangles"] = info.triangles;
    return out;
}

Vector3 CadMesh::face_normal_at(int group, const Vector3& point)
{
    if (group < 0) {
        return Vector3();
    }
    double p[3], n[3];
    doubles(point, p);
    mesh::group_normal_at(*state, uint32_t(group), p, n);
    return vec3(n);
}

int CadMesh::edge_count() const
{
    return 0;
}

PackedStringArray CadMesh::get_edge_names() const
{
    return PackedStringArray();
}

Dictionary CadMesh::edge_info(int) const
{
    return Dictionary();
}

int CadMesh::vertex_count() const
{
    return int(state->data.vertex_count());
}

bool CadMesh::is_surface()
{
    return !is_null() && !mesh::is_closed(*state);
}

int CadMesh::solid_count()
{
    if (is_null()) {
        return 0;
    }
    int count = 0;
    for (const mesh::Component& c : mesh::nested_components_of(*state)->list) {
        count += (c.depth >= 0 && c.depth % 2 == 0) ? 1 : 0;
    }
    return count;
}

Ref<CadMesh> CadMesh::copy()
{
    return Ref<CadMesh>(this);
}

// ---------------------------------------------------------------- queries

bool CadMesh::is_mesh() const
{
    return true;
}

int CadMesh::triangle_count() const
{
    return int(state->data.triangle_count());
}

int CadMesh::group_count() const
{
    return int(state->data.group_count());
}

String CadMesh::digest()
{
    char line[32];
    std::snprintf(line, sizeof(line), "%016llx", static_cast<unsigned long long>(mesh::digest_of(*state)));
    return String(line);
}

int64_t CadMesh::memory_bytes() const
{
    // (With overlap()'s Manifold, Phase 8: it counts toward the mesh cache cap too.)
    return int64_t(mesh::memory_bytes(*state) + mesh::contact::cache_bytes(contact_cache.get()));
}

Dictionary CadMesh::check(double time_limit)
{
    clear_messages();
    Dictionary out;
    const double limit = mesh::clamp_time_limit(time_limit, mesh::budget::CHECK_SECONDS);
    const mesh::Deadline deadline(limit);
    // (The self-intersection test gets what is left of the call's own time.)
    const mesh::CheckResult r = mesh::check(*state, deadline, limit);
    last_report["op"] = "check";
    last_report["ms"] = deadline.elapsed() * 1000.0;
    last_report["self_intersection_ms"] = r.self_ms;
    if (!r.finished) {
        fail("Check took longer than " + mesh::number_text(limit) + " s and was stopped. Give it more time.");
        return out;
    }
    out["closed"] = r.closed;
    out["manifold"] = r.manifold;
    out["oriented"] = r.oriented;
    out["boundary_edges"] = r.boundary_edges;
    out["boundary_loops"] = r.boundary_loops;
    out["non_manifold_edges"] = r.non_manifold_edges;
    out["non_manifold_vertices"] = r.non_manifold_vertices;
    out["degenerate_triangles"] = r.degenerate_triangles;
    out["duplicate_triangles"] = r.duplicate_triangles;
    out["unused_vertices"] = r.unused_vertices;
    out["components"] = r.components;
    out["closed_components"] = r.closed_components;
    out["inverted_components"] = r.inverted_components;
    out["genus"] = r.genus;
    out["self_intersections"] = r.self_intersections;
    out["self_intersection_pairs"] = int_array(r.pairs.data(), r.pairs.size());
    return out;
}

Array CadMesh::boundary_loops()
{
    Array out;
    if (is_null()) {
        return out;
    }
    const std::vector<mesh::BoundaryLoop> loops = mesh::boundary_loops(*state);
    for (size_t i = 0; i < loops.size(); ++i) {
        const mesh::BoundaryLoop& loop = loops[i];
        PackedVector3Array points;
        points.resize(int64_t(loop.vertices.size()));
        Vector3* w = points.ptrw();
        for (size_t k = 0; k < loop.vertices.size(); ++k) {
            const float* p = &state->data.positions[size_t(loop.vertices[k]) * 3];
            w[k] = Vector3(p[0], p[1], p[2]);
        }
        Dictionary d;
        d["id"] = int64_t(i);
        d["vertices"] = int_array(loop.vertices);
        d["points"] = points;
        d["length"] = loop.length;
        d["edges"] = int64_t(loop.closed ? loop.vertices.size() : loop.vertices.size() - 1);
        d["planar_error"] = loop.planar_error;
        out.push_back(d);
    }
    return out;
}

PackedInt32Array CadMesh::group_triangles(int group)
{
    if (group < 0 || size_t(group) >= state->data.group_count()) {
        return PackedInt32Array();
    }
    const mesh::GroupIndex& index = mesh::group_index_of(*state);
    const uint32_t first = index.first[size_t(group)], last = index.first[size_t(group) + 1];
    return int_array(reinterpret_cast<const int32_t*>(index.tris.data() + first), size_t(last - first));
}

Dictionary CadMesh::ray_hit(const Vector3& origin, const Vector3& direction, double max_distance)
{
    Dictionary out;
    double o[3], d[3];
    doubles(origin, o);
    doubles(direction, d);
    const mesh::RayHit hit = mesh::ray_hit(*state, o, d, max_distance > 0.0 ? max_distance : 0.0);
    out["hit"] = hit.hit;
    if (!hit.hit) {
        return out;
    }
    out["distance"] = hit.distance;
    out["point"] = vec3(hit.point);
    out["normal"] = vec3(hit.normal);
    out["triangle"] = int64_t(hit.triangle);
    out["group"] = int64_t(state->data.groups[hit.triangle]);
    return out;
}

PackedInt32Array CadMesh::triangles_in_frustum(const Array& planes, const String& mode)
{
    const bool inside = mode == "inside";
    if (!inside && mode != "crossing") {
        UtilityFunctions::push_error("CadMesh.triangles_in_frustum: mode must be \"inside\" or \"crossing\".");
        return PackedInt32Array();
    }
    std::vector<double> values;
    for (int64_t i = 0; i < planes.size(); ++i) {
        if (planes[i].get_type() != Variant::PLANE) {
            UtilityFunctions::push_error("CadMesh.triangles_in_frustum: planes must hold Plane values.");
            return PackedInt32Array();
        }
        const Plane plane = planes[i];
        values.push_back(plane.normal.x);
        values.push_back(plane.normal.y);
        values.push_back(plane.normal.z);
        values.push_back(plane.d);
    }
    if (values.empty() || values.size() / 4 > 32) {
        if (!values.empty()) {
            UtilityFunctions::push_error("CadMesh.triangles_in_frustum: at most 32 planes.");
        }
        return PackedInt32Array();
    }
    return int_array(mesh::triangles_in_planes(*state, values.data(), values.size() / 4, inside));
}

PackedInt32Array CadMesh::triangles_near(const Vector3& point, double radius, bool only_connected)
{
    double p[3];
    doubles(point, p);
    return int_array(mesh::triangles_near(*state, p, radius, only_connected));
}

PackedInt32Array CadMesh::grow(const PackedInt32Array& tris, int steps)
{
    return int_array(mesh::grow(*state, index_list(tris), steps, false));
}

PackedInt32Array CadMesh::shrink(const PackedInt32Array& tris, int steps)
{
    return int_array(mesh::grow(*state, index_list(tris), steps, true));
}

PackedInt32Array CadMesh::connected(const PackedInt32Array& tris, double max_angle_deg)
{
    return int_array(mesh::connected(*state, index_list(tris), max_angle_deg));
}

Array CadMesh::section(const Vector3& origin, const Vector3& normal)
{
    Array out;
    double o[3], n[3];
    doubles(origin, o);
    doubles(normal, n);
    for (const mesh::Polyline& line : mesh::section(*state, o, n)) {
        Dictionary d;
        d["points"] = vec3_array(line.points);
        d["closed"] = line.closed;
        out.push_back(d);
    }
    return out;
}

Dictionary CadMesh::distance_to(const Ref<CadMesh>& other, int64_t samples, double time_limit)
{
    clear_messages();
    Dictionary out;
    if (other.is_null() || other->is_null() || is_null()) {
        fail("The distance needs two mesh bodies that have triangles.");
        return out;
    }
    if (samples < 1 || samples > 10000000) {
        fail("Samples must be between 1 and 10,000,000.");
        return out;
    }
    const mesh::Deadline deadline(mesh::clamp_time_limit(time_limit));
    const mesh::Distance d = mesh::distance_between(*state, other->get_state(), samples, deadline);
    out["max"] = d.max;
    out["mean"] = d.mean;
    out["rms"] = d.rms;
    out["max_point"] = vec3(d.max_point);
    out["samples"] = d.samples;
    out["timed_out"] = d.timed_out;
    if (d.timed_out) {
        last_warning = text("The distance was measured at " + mesh::with_commas(uint64_t(d.samples)) + " of " + mesh::with_commas(uint64_t(samples)) +
                            " samples before the time limit of " + mesh::number_text(deadline.limit()) + " s.");
    }
    return out;
}

PackedByteArray CadMesh::winding_inside(const PackedVector3Array& points)
{
    PackedByteArray out;
    out.resize(points.size());
    if (points.size() == 0) {
        return out;
    }
    std::vector<double> flat(size_t(points.size()) * 3);
    const Vector3* p = points.ptr();
    for (int64_t i = 0; i < points.size(); ++i) {
        doubles(p[i], &flat[size_t(i) * 3]);
    }
    std::vector<int32_t> winding;
    mesh::winding_numbers(*state, flat.data(), size_t(points.size()), winding);
    uint8_t* w = out.ptrw();
    for (int64_t i = 0; i < points.size(); ++i) {
        w[i] = winding[size_t(i)] != 0 ? 1 : 0;
    }
    return out;
}

// ---------------------------------------------------------------- ops

Ref<CadMesh> CadMesh::transformed(const Transform3D& xform)
{
    clear_messages();
    const double started = now_ms();
    if (is_null()) {
        fail("There is no mesh to move.");
        return Ref<CadMesh>();
    }
    double basis[9], origin[3];
    bool finite = true;
    for (int r = 0; r < 3; ++r) {
        for (int c = 0; c < 3; ++c) {
            basis[r * 3 + c] = xform.basis[r][c];
            finite = finite && std::isfinite(basis[r * 3 + c]);
        }
        origin[r] = xform.origin[r];
        finite = finite && std::isfinite(origin[r]);
    }
    const double det = basis[0] * (basis[4] * basis[8] - basis[5] * basis[7]) - basis[1] * (basis[3] * basis[8] - basis[5] * basis[6]) +
                       basis[2] * (basis[3] * basis[7] - basis[4] * basis[6]);
    if (!finite || det == 0.0) {
        fail("The move is not valid: it would flatten the mesh or is not a number.");
        return Ref<CadMesh>();
    }
    return move_by(basis, origin, started);
}

Ref<CadMesh> CadMesh::transformed64(const PackedFloat64Array& m)
{
    clear_messages();
    const double started = now_ms();
    if (is_null()) {
        fail("There is no mesh to move.");
        return Ref<CadMesh>();
    }
    double x[12];
    std::string error;
    if (!xform64::rigid(m, x, error)) {
        fail(error);
        return Ref<CadMesh>();
    }
    // (mesh::transformed takes the basis as rows; x holds columns.)
    double basis[9], origin[3];
    for (int r = 0; r < 3; ++r) {
        for (int c = 0; c < 3; ++c) {
            basis[r * 3 + c] = x[c * 3 + r];
        }
        origin[r] = x[9 + r];
    }
    return move_by(basis, origin, started);
}

Ref<CadMesh> CadMesh::move_by(const double basis[9], const double origin[3], double started)
{
    mesh::MeshData moved = mesh::transformed(state->data, basis, origin);
    for (const float value : moved.positions) {
        if (!std::isfinite(value) || std::fabs(double(value)) > mesh::budget::MAX_COORDINATE) {
            fail("The move is not valid: it would give the mesh a coordinate beyond " + mesh::length_text(mesh::budget::MAX_COORDINATE) +
                 ", the farthest a mesh body reaches along each axis.");
            return Ref<CadMesh>();
        }
    }
    // Far from the origin, or very small, float32 positions run out of digits (about 7): points
    // that were apart land on one value. When that happens to more than half of the triangles
    // that had three different corners, the body is gone: refused, not stored.
    {
        const mesh::MeshData& was = state->data;
        const size_t T = was.triangle_count();
        size_t proper = 0, fallen = 0;
        auto same = [](const std::vector<float>& p, uint32_t a, uint32_t b) { return std::memcmp(&p[size_t(a) * 3], &p[size_t(b) * 3], sizeof(float) * 3) == 0; };
        for (size_t t = 0; t < T; ++t) {
            const uint32_t* tri = &was.triangles[t * 3];
            if (same(was.positions, tri[0], tri[1]) || same(was.positions, tri[1], tri[2]) || same(was.positions, tri[0], tri[2])) {
                continue;
            }
            ++proper;
            // (A mirroring move swaps two corners of every triangle: the same three vertices.)
            if (same(moved.positions, tri[0], tri[1]) || same(moved.positions, tri[1], tri[2]) || same(moved.positions, tri[0], tri[2])) {
                ++fallen;
            }
        }
        if (fallen * 2 > proper) {
            fail("The move is not valid: at that distance or size " + mesh::with_commas(fallen) + " of the mesh's " + mesh::with_commas(proper) +
                 " triangles would fall together into a line or a point (positions keep about 7 digits).");
            return Ref<CadMesh>();
        }
        // A scale that leaves the points apart but the body smaller than any length the mesh
        // tools work at (their tolerances are absolute below about a nanometre): refused too.
        auto across = [](const std::vector<float>& p) {
            double lo[3] = {INFINITY, INFINITY, INFINITY}, hi[3] = {-INFINITY, -INFINITY, -INFINITY};
            for (size_t i = 0; i + 2 < p.size(); i += 3) {
                for (int k = 0; k < 3; ++k) {
                    lo[k] = std::min(lo[k], double(p[i + size_t(k)]));
                    hi[k] = std::max(hi[k], double(p[i + size_t(k)]));
                }
            }
            return p.empty() ? 0.0 : std::sqrt((hi[0] - lo[0]) * (hi[0] - lo[0]) + (hi[1] - lo[1]) * (hi[1] - lo[1]) + (hi[2] - lo[2]) * (hi[2] - lo[2]));
        };
        const double kSmallest = 1e-9;
        if (across(moved.positions) < kSmallest && across(was.positions) >= kSmallest) {
            fail("The move is not valid: it would shrink the mesh to less than 0.000001 mm across, smaller than a mesh body can be.");
            return Ref<CadMesh>();
        }
    }
    return finish_op("Move", "transformed", std::move(moved), started, false);
}

String CadMesh::get_last_error() const
{
    return last_error;
}

String CadMesh::get_last_warning() const
{
    return last_warning;
}

Dictionary CadMesh::get_last_report() const
{
    return last_report;
}

void CadMesh::bind_pmp_methods()
{
    // Stage N2: remesh, reduce, close_holes, smooth, generate_groups, regroup, fit_primitive,
    // stitch_and_remove, reverse, delete_triangles, welded.
    ClassDB::bind_method(D_METHOD("welded"), &CadMesh::welded);
    ClassDB::bind_method(D_METHOD("delete_triangles", "tris"), &CadMesh::delete_triangles);
    ClassDB::bind_method(D_METHOD("reverse", "options"), &CadMesh::reverse, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("stitch_and_remove", "options"), &CadMesh::stitch_and_remove, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("regroup", "tris_or_groups"), &CadMesh::regroup);
    ClassDB::bind_method(D_METHOD("generate_groups", "options"), &CadMesh::generate_groups, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("fit_primitive", "tris"), &CadMesh::fit_primitive);
    ClassDB::bind_method(D_METHOD("smooth", "options"), &CadMesh::smooth, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("reduce", "options"), &CadMesh::reduce, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("close_holes", "options"), &CadMesh::close_holes, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("remesh", "options"), &CadMesh::remesh, DEFVAL(Dictionary()));
}

void CadMesh::bind_manifold_methods()
{
    // Stage N3: wrap, rebuild, plane_cut, shell, boolean, merge_with, separate, displace, and
    // op_defaults (defaults, ranges and time estimates for their panels).
    ClassDB::bind_method(D_METHOD("boolean", "tools", "options"), &CadMesh::boolean, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("merge_with", "others"), &CadMesh::merge_with);
    ClassDB::bind_method(D_METHOD("plane_cut", "options"), &CadMesh::plane_cut);
    ClassDB::bind_method(D_METHOD("wrap", "options"), &CadMesh::wrap_op, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("rebuild", "options"), &CadMesh::rebuild, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("shell", "options"), &CadMesh::shell, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("separate", "options"), &CadMesh::separate, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("displace", "options"), &CadMesh::displace);
    ClassDB::bind_method(D_METHOD("op_defaults", "method", "options"), &CadMesh::op_defaults, DEFVAL(Dictionary()));
}

void CadMesh::_bind_methods()
{
    ClassDB::bind_method(D_METHOD("set_arrays", "positions", "indices", "groups", "group_names", "winding"), &CadMesh::set_arrays, DEFVAL(PackedInt32Array()),
                         DEFVAL(PackedStringArray()), DEFVAL(String("godot")));
    ClassDB::bind_method(D_METHOD("from_blob", "bytes"), &CadMesh::from_blob);
    ClassDB::bind_method(D_METHOD("to_blob"), &CadMesh::to_blob);
    ClassDB::bind_method(D_METHOD("read_stl", "path", "scale"), &CadMesh::read_stl);
    ClassDB::bind_method(D_METHOD("read_obj", "path", "scale"), &CadMesh::read_obj);
    ClassDB::bind_method(D_METHOD("from_shape", "shape", "linear", "angular", "relative", "time_limit"), &CadMesh::from_shape);
    ClassDB::bind_method(D_METHOD("get_arrays"), &CadMesh::get_arrays);
    ClassDB::bind_method(D_METHOD("library_versions"), &CadMesh::library_versions);
    ClassDB::bind_method(D_METHOD("group_name_for", "face_name"), &CadMesh::group_name_for);

    ClassDB::bind_method(D_METHOD("is_null"), &CadMesh::is_null);
    ClassDB::bind_method(D_METHOD("shape_type"), &CadMesh::shape_type);
    ClassDB::bind_method(D_METHOD("bbox"), &CadMesh::bbox);
    ClassDB::bind_method(D_METHOD("tessellate", "linear_deflection", "angular_deflection"), &CadMesh::tessellate, DEFVAL(0.1), DEFVAL(0.5));
    ClassDB::bind_method(D_METHOD("volume"), &CadMesh::volume);
    ClassDB::bind_method(D_METHOD("area"), &CadMesh::area);
    ClassDB::bind_method(D_METHOD("center_of_mass"), &CadMesh::center_of_mass);
    ClassDB::bind_method(D_METHOD("mass_properties", "density"), &CadMesh::mass_properties, DEFVAL(1000.0));
    ClassDB::bind_method(D_METHOD("face_count"), &CadMesh::face_count);
    ClassDB::bind_method(D_METHOD("get_face_names"), &CadMesh::get_face_names);
    ClassDB::bind_method(D_METHOD("find_face", "name"), &CadMesh::find_face);
    ClassDB::bind_method(D_METHOD("face_info", "face_id"), &CadMesh::face_info);
    ClassDB::bind_method(D_METHOD("face_normal_at", "face_id", "point"), &CadMesh::face_normal_at);
    ClassDB::bind_method(D_METHOD("edge_count"), &CadMesh::edge_count);
    ClassDB::bind_method(D_METHOD("get_edge_names"), &CadMesh::get_edge_names);
    ClassDB::bind_method(D_METHOD("edge_info", "edge_id"), &CadMesh::edge_info);
    ClassDB::bind_method(D_METHOD("vertex_count"), &CadMesh::vertex_count);
    ClassDB::bind_method(D_METHOD("is_surface"), &CadMesh::is_surface);
    ClassDB::bind_method(D_METHOD("solid_count"), &CadMesh::solid_count);
    ClassDB::bind_method(D_METHOD("copy"), &CadMesh::copy);

    ClassDB::bind_method(D_METHOD("is_mesh"), &CadMesh::is_mesh);
    ClassDB::bind_method(D_METHOD("triangle_count"), &CadMesh::triangle_count);
    ClassDB::bind_method(D_METHOD("group_count"), &CadMesh::group_count);
    ClassDB::bind_method(D_METHOD("digest"), &CadMesh::digest);
    ClassDB::bind_method(D_METHOD("memory_bytes"), &CadMesh::memory_bytes);
    ClassDB::bind_method(D_METHOD("check", "time_limit"), &CadMesh::check, DEFVAL(2.0));
    ClassDB::bind_method(D_METHOD("boundary_loops"), &CadMesh::boundary_loops);
    ClassDB::bind_method(D_METHOD("group_triangles", "group"), &CadMesh::group_triangles);
    ClassDB::bind_method(D_METHOD("ray_hit", "origin", "direction", "max_distance"), &CadMesh::ray_hit, DEFVAL(kInf));
    ClassDB::bind_method(D_METHOD("triangles_in_frustum", "planes", "mode"), &CadMesh::triangles_in_frustum);
    ClassDB::bind_method(D_METHOD("triangles_near", "point", "radius", "connected"), &CadMesh::triangles_near);
    ClassDB::bind_method(D_METHOD("grow", "tris", "steps"), &CadMesh::grow);
    ClassDB::bind_method(D_METHOD("shrink", "tris", "steps"), &CadMesh::shrink);
    ClassDB::bind_method(D_METHOD("connected", "tris", "max_angle_deg"), &CadMesh::connected);
    ClassDB::bind_method(D_METHOD("section", "origin", "normal"), &CadMesh::section);
    ClassDB::bind_method(D_METHOD("distance_to", "other", "samples", "time_limit"), &CadMesh::distance_to);
    ClassDB::bind_method(D_METHOD("winding_inside", "points"), &CadMesh::winding_inside);

    ClassDB::bind_method(D_METHOD("transformed", "xform"), &CadMesh::transformed);
    // Phase 8 fix round 1: m is an xform64, 12 doubles (basis columns X, Y, Z, then the origin).
    ClassDB::bind_method(D_METHOD("transformed64", "m"), &CadMesh::transformed64);

    ClassDB::bind_method(D_METHOD("get_last_error"), &CadMesh::get_last_error);
    ClassDB::bind_method(D_METHOD("get_last_warning"), &CadMesh::get_last_warning);
    ClassDB::bind_method(D_METHOD("get_last_report"), &CadMesh::get_last_report);

    bind_pmp_methods();
    bind_manifold_methods();
    bind_convert_methods();
    bind_contact_methods();
}

}  // namespace holo_forge
