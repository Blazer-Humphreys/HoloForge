#include "mesh_data.h"

#include "mesh_budget.h"
#include "mesh_bvh.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <unordered_set>

namespace holo_forge::mesh
{

State::State() = default;
State::~State() = default;

std::string with_commas(uint64_t value)
{
    std::string digits = std::to_string(value);
    std::string out;
    const size_t n = digits.size();
    for (size_t i = 0; i < n; ++i) {
        out.push_back(digits[i]);
        if (i + 1 < n && (n - 1 - i) % 3 == 0) {
            out.push_back(',');
        }
    }
    return out;
}

std::string number_text(double value, const char* format)
{
    char text[64];
    std::snprintf(text, sizeof(text), format, value);
    return std::string(text);
}

namespace
{
/// value with `decimals` digits after the point, trailing zeros cut, commas in the whole part.
std::string plain_number(double value, int decimals)
{
    char text[64];
    std::snprintf(text, sizeof(text), "%.*f", decimals, value);
    std::string digits(text);
    const size_t point = digits.find('.');
    std::string whole = digits.substr(0, point), rest = point == std::string::npos ? std::string() : digits.substr(point + 1);
    while (!rest.empty() && rest.back() == '0') {
        rest.pop_back();
    }
    std::string out;
    for (size_t i = 0; i < whole.size(); ++i) {
        out.push_back(whole[i]);
        if (i + 1 < whole.size() && (whole.size() - 1 - i) % 3 == 0) {
            out.push_back(',');
        }
    }
    return rest.empty() ? out : out + "." + rest;
}

/// About four digits of a positive number, as a plain number.
std::string four_digits(double value)
{
    if (!(value < 1e15)) {
        return "more than 1,000,000,000,000,000";
    }
    if (value >= 1000.0) {
        return plain_number(value, 3);
    }
    if (!(value > 0.0)) {
        return "0";
    }
    const int decimals = std::min(12, std::max(0, 3 - int(std::floor(std::log10(value)))));
    return plain_number(value, decimals);
}
}  // namespace

std::string length_text(double meters)
{
    const double size = std::fabs(meters);
    const char* sign = meters < 0.0 ? "-" : "";
    if (!std::isfinite(size) || size >= 1000.0) {
        return std::string(sign) + four_digits(size / 1000.0) + " km";
    }
    if (size >= 1.0) {
        return std::string(sign) + four_digits(size) + " m";
    }
    if (size >= 1e-6 * (1.0 - 1e-9) || size == 0.0) {
        return std::string(sign) + four_digits(size * 1e3) + " mm";
    }
    if (size >= 1e-7 * (1.0 - 1e-9)) {
        return std::string(sign) + four_digits(size * 1e6) + " µm";
    }
    return std::string(sign) + four_digits(size * 1e9) + " nm";
}

std::string seconds_text(double seconds)
{
    const double size = std::fabs(seconds);
    if (!(size < 1e15)) {
        return "more than 1,000,000,000,000,000";
    }
    if (size >= 100.0) {
        // Two digits tell enough of an estimate.
        const double step = std::pow(10.0, std::floor(std::log10(size)) - 1.0);
        return plain_number(std::round(size / step) * step, 0);
    }
    return plain_number(size, size >= 10.0 ? 0 : (size >= 1.0 ? 1 : 2));
}

bool without_area(const MeshData& mesh, size_t triangle)
{
    const uint32_t* t = &mesh.triangles[triangle * 3];
    if (t[0] == t[1] || t[1] == t[2] || t[0] == t[2]) {
        return true;
    }
    double p[3][3];
    for (int k = 0; k < 3; ++k) {
        mesh.point(t[k], p[k]);
    }
    double longest = 0.0;
    for (int k = 0; k < 3; ++k) {
        const double* a = p[k];
        const double* b = p[(k + 1) % 3];
        longest = std::max(longest, (b[0] - a[0]) * (b[0] - a[0]) + (b[1] - a[1]) * (b[1] - a[1]) + (b[2] - a[2]) * (b[2] - a[2]));
    }
    longest = std::sqrt(longest);
    const double u[3] = {p[1][0] - p[0][0], p[1][1] - p[0][1], p[1][2] - p[0][2]}, v[3] = {p[2][0] - p[0][0], p[2][1] - p[0][1], p[2][2] - p[0][2]};
    const double n[3] = {u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]};
    const double twice = std::sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
    // twice the area = longest edge x height. (Differences of float32 coordinates and their
    // products are exact or nearly so in doubles, so `twice` is the area of the stored corners.
    // The place does not count: far from the origin the corners sit on a coarser grid, but three
    // corners that are not on one line there still make a triangle; Faceted and Stitch treat it
    // as one.)
    return !(twice > longest * longest * 0x1p-24);
}

// ---------------------------------------------------------------- validation

std::string validate_sizes(uint64_t vertices, uint64_t triangles, uint64_t groups)
{
    if (triangles > budget::MAX_TRIANGLES_MESH) {
        return "The mesh has " + with_commas(triangles) + " triangles; mesh bodies take up to " + with_commas(budget::MAX_TRIANGLES_MESH) + ".";
    }
    if (vertices > budget::MAX_VERTICES_MESH) {
        return "The mesh has " + with_commas(vertices) + " vertices; mesh bodies take up to " + with_commas(budget::MAX_VERTICES_MESH) + ".";
    }
    if (groups > budget::MAX_GROUPS_MESH) {
        return "The mesh has " + with_commas(groups) + " face groups; mesh bodies take up to " + with_commas(budget::MAX_GROUPS_MESH) + ".";
    }
    return std::string();
}

namespace
{
bool valid_utf8(const std::string& s)
{
    size_t i = 0;
    const size_t n = s.size();
    while (i < n) {
        const unsigned char c = static_cast<unsigned char>(s[i]);
        size_t extra = 0;
        if (c < 0x80) {
            extra = 0;
        }
        else if ((c & 0xE0) == 0xC0) {
            extra = 1;
        }
        else if ((c & 0xF0) == 0xE0) {
            extra = 2;
        }
        else if ((c & 0xF8) == 0xF0) {
            extra = 3;
        }
        else {
            return false;
        }
        for (size_t k = 1; k <= extra; ++k) {
            if (i + k >= n || (static_cast<unsigned char>(s[i + k]) & 0xC0) != 0x80) {
                return false;
            }
        }
        i += extra + 1;
    }
    return true;
}

inline uint64_t mix(uint64_t h, uint64_t v)
{
    h ^= v;
    h *= 0x9E3779B97F4A7C15ull;
    h ^= h >> 29;
    return h;
}

uint64_t hash_bytes(uint64_t h, const void* data, size_t size)
{
    const uint8_t* p = static_cast<const uint8_t*>(data);
    h = mix(h, uint64_t(size));
    size_t i = 0;
    for (; i + 8 <= size; i += 8) {
        uint64_t w;
        std::memcpy(&w, p + i, 8);
        h = mix(h, w);
    }
    if (i < size) {
        uint64_t w = 0;
        std::memcpy(&w, p + i, size - i);
        h = mix(h, w);
    }
    return h;
}
}  // namespace

std::string validate(const MeshData& mesh)
{
    if (mesh.positions.size() % 3 != 0 || mesh.triangles.size() % 3 != 0) {
        return "The mesh arrays are broken: the index count is not a multiple of 3.";
    }
    const size_t V = mesh.vertex_count(), T = mesh.triangle_count(), G = mesh.group_count();
    const std::string sizes = validate_sizes(V, T, G);
    if (!sizes.empty()) {
        return sizes;
    }
    if (mesh.groups.size() != T) {
        return "The mesh arrays are broken: there are " + with_commas(T) + " triangles but " + with_commas(mesh.groups.size()) + " group ids.";
    }
    for (size_t i = 0; i < mesh.positions.size(); ++i) {
        if (!std::isfinite(mesh.positions[i])) {
            return "The mesh arrays are broken: vertex " + with_commas(i / 3) + " is not a finite number (NaN or infinite).";
        }
        if (std::fabs(double(mesh.positions[i])) > budget::MAX_COORDINATE) {
            return "The mesh arrays are broken: vertex " + with_commas(i / 3) + " has a coordinate of " + length_text(double(mesh.positions[i])) +
                   "; mesh bodies take coordinates up to " + length_text(budget::MAX_COORDINATE) + " along each axis.";
        }
    }
    for (size_t i = 0; i < mesh.triangles.size(); ++i) {
        if (mesh.triangles[i] >= V) {
            return "The mesh arrays are broken: triangle " + with_commas(i / 3) + " points at vertex " + with_commas(mesh.triangles[i]) + ", but there are only " +
                   with_commas(V) + " vertices.";
        }
    }
    for (size_t t = 0; t < T; ++t) {
        if (mesh.groups[t] >= G) {
            return "The mesh arrays are broken: triangle " + with_commas(t) + " is in face group " + with_commas(mesh.groups[t]) + ", but there are only " +
                   with_commas(G) + " face groups.";
        }
    }
    std::unordered_set<std::string> seen;
    seen.reserve(G * 2);
    for (size_t g = 0; g < G; ++g) {
        const std::string& name = mesh.group_names[g];
        if (name.empty() || name.size() > budget::MAX_GROUP_NAME_BYTES) {
            return "The mesh arrays are broken: the name of face group " + with_commas(g) + " must be 1 to 64 bytes long (it is " + with_commas(name.size()) + ").";
        }
        if (!valid_utf8(name)) {
            return "The mesh arrays are broken: the name of face group " + with_commas(g) + " is not valid UTF-8 text.";
        }
        if (name.find('\0') != std::string::npos) {
            return "The mesh arrays are broken: the name of face group " + with_commas(g) + " holds a NUL character.";
        }
        if (!seen.insert(name).second) {
            return "The mesh arrays are broken: two face groups are both named '" + name + "'.";
        }
    }
    return std::string();
}

std::string short_group_name(const std::string& name)
{
    if (name.size() <= budget::MAX_GROUP_NAME_BYTES) {
        return name;
    }
    // FNV-1a over the whole name.
    uint64_t h = 0xCBF29CE484222325ull;
    for (const char ch : name) {
        h ^= static_cast<unsigned char>(ch);
        h *= 0x100000001B3ull;
    }
    size_t keep = budget::MAX_GROUP_NAME_BYTES - 17;
    // Never cut inside a UTF-8 character.
    while (keep > 0 && (static_cast<unsigned char>(name[keep]) & 0xC0) == 0x80) {
        --keep;
    }
    char tail[24];
    std::snprintf(tail, sizeof(tail), "~%016llx", static_cast<unsigned long long>(h));
    return name.substr(0, keep) + tail;
}

void repair_group_names(std::vector<std::string>& names)
{
    std::unordered_set<std::string> seen;
    seen.reserve(names.size() * 2);
    for (size_t g = 0; g < names.size(); ++g) {
        std::string name = names[g];
        if (name.empty() || !valid_utf8(name)) {
            name = "g" + std::to_string(g);
        }
        name = short_group_name(name);
        if (seen.count(name) != 0) {
            const std::string tail = "~" + std::to_string(g);
            std::string base = name;
            if (base.size() + tail.size() > budget::MAX_GROUP_NAME_BYTES) {
                size_t keep = budget::MAX_GROUP_NAME_BYTES - tail.size();
                while (keep > 0 && (static_cast<unsigned char>(base[keep]) & 0xC0) == 0x80) {
                    --keep;
                }
                base = base.substr(0, keep);
            }
            name = base + tail;
            // (Still taken only when another group is literally named like that: number on.)
            for (size_t k = 0; seen.count(name) != 0; ++k) {
                name = "g" + std::to_string(g) + "~" + std::to_string(k);
            }
        }
        seen.insert(name);
        names[g] = name;
    }
}

void compact(MeshData& mesh)
{
    const size_t V = mesh.vertex_count(), T = mesh.triangle_count(), G = mesh.group_count();
    // Vertices: keep the used ones, in order.
    std::vector<uint32_t> remap(V, NONE);
    for (const uint32_t v : mesh.triangles) {
        remap[v] = 0;
    }
    uint32_t next = 0;
    bool all_used = true;
    for (size_t v = 0; v < V; ++v) {
        if (remap[v] == 0) {
            remap[v] = next++;
        }
        else {
            all_used = false;
        }
    }
    if (!all_used) {
        std::vector<float> kept(size_t(next) * 3);
        for (size_t v = 0; v < V; ++v) {
            if (remap[v] != NONE) {
                std::memcpy(&kept[size_t(remap[v]) * 3], &mesh.positions[v * 3], sizeof(float) * 3);
            }
        }
        mesh.positions.swap(kept);
        for (uint32_t& v : mesh.triangles) {
            v = remap[v];
        }
    }
    // Groups: drop the empty ones.
    std::vector<uint32_t> group_map(G, NONE);
    for (size_t t = 0; t < T; ++t) {
        group_map[mesh.groups[t]] = 0;
    }
    uint32_t next_group = 0;
    bool all_groups = true;
    for (size_t g = 0; g < G; ++g) {
        if (group_map[g] == 0) {
            group_map[g] = next_group++;
        }
        else {
            all_groups = false;
        }
    }
    if (!all_groups) {
        std::vector<std::string> names(next_group);
        for (size_t g = 0; g < G; ++g) {
            if (group_map[g] != NONE) {
                names[group_map[g]] = mesh.group_names[g];
            }
        }
        mesh.group_names.swap(names);
        for (uint32_t& g : mesh.groups) {
            g = group_map[g];
        }
    }
}

uint64_t digest(const MeshData& mesh)
{
    uint64_t h = 0x48464D3100000001ull;  // "HFM1", digest version 1
    h = hash_bytes(h, mesh.positions.data(), mesh.positions.size() * sizeof(float));
    h = hash_bytes(h, mesh.triangles.data(), mesh.triangles.size() * sizeof(uint32_t));
    h = hash_bytes(h, mesh.groups.data(), mesh.groups.size() * sizeof(uint32_t));
    h = mix(h, uint64_t(mesh.group_names.size()));
    for (const std::string& name : mesh.group_names) {
        h = hash_bytes(h, name.data(), name.size());
    }
    // Finish: spread the last words over all bits.
    h ^= h >> 32;
    h *= 0xD6E8FEB86659FD93ull;
    h ^= h >> 32;
    return h;
}

size_t memory_bytes(const MeshData& mesh)
{
    size_t bytes = mesh.positions.capacity() * sizeof(float) + mesh.triangles.capacity() * sizeof(uint32_t) + mesh.groups.capacity() * sizeof(uint32_t);
    for (const std::string& name : mesh.group_names) {
        bytes += sizeof(std::string) + name.capacity();
    }
    return bytes;
}

// ---------------------------------------------------------------- CRC-32 (slicing by 8)

namespace
{
struct CrcTables
{
    uint32_t t[8][256];
    CrcTables()
    {
        for (uint32_t i = 0; i < 256; ++i) {
            uint32_t c = i;
            for (int k = 0; k < 8; ++k) {
                c = (c & 1u) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
            }
            t[0][i] = c;
        }
        for (uint32_t i = 0; i < 256; ++i) {
            for (int k = 1; k < 8; ++k) {
                t[k][i] = (t[k - 1][i] >> 8) ^ t[0][t[k - 1][i] & 0xFFu];
            }
        }
    }
};
}  // namespace

uint32_t crc32(const uint8_t* bytes, size_t size)
{
    static const CrcTables tables;
    uint32_t crc = 0xFFFFFFFFu;
    size_t i = 0;
    for (; i + 8 <= size; i += 8) {
        uint32_t a, b;
        std::memcpy(&a, bytes + i, 4);
        std::memcpy(&b, bytes + i + 4, 4);
        a ^= crc;
        crc = tables.t[7][a & 0xFFu] ^ tables.t[6][(a >> 8) & 0xFFu] ^ tables.t[5][(a >> 16) & 0xFFu] ^ tables.t[4][a >> 24] ^ tables.t[3][b & 0xFFu] ^
              tables.t[2][(b >> 8) & 0xFFu] ^ tables.t[1][(b >> 16) & 0xFFu] ^ tables.t[0][b >> 24];
    }
    for (; i < size; ++i) {
        crc = tables.t[0][(crc ^ bytes[i]) & 0xFFu] ^ (crc >> 8);
    }
    return crc ^ 0xFFFFFFFFu;
}

// ---------------------------------------------------------------- the HFM1 blob
// (Little endian, as the machine is: the arrays are copied as they lie in memory.)

namespace
{
constexpr size_t HEADER = 24;

inline void put_u32(uint8_t* out, uint32_t v)
{
    std::memcpy(out, &v, 4);
}
inline uint32_t get_u32(const uint8_t* in)
{
    uint32_t v;
    std::memcpy(&v, in, 4);
    return v;
}
}  // namespace

size_t blob_size(const MeshData& mesh)
{
    size_t bytes = HEADER + mesh.positions.size() * 4 + mesh.triangles.size() * 4 + mesh.groups.size() * 4 + 4;
    for (const std::string& name : mesh.group_names) {
        bytes += 2 + name.size();
    }
    return bytes;
}

void write_blob(const MeshData& mesh, uint8_t* out)
{
    uint8_t* p = out;
    std::memcpy(p, "HFM1", 4);
    put_u32(p + 4, 1);
    put_u32(p + 8, 0);
    put_u32(p + 12, uint32_t(mesh.vertex_count()));
    put_u32(p + 16, uint32_t(mesh.triangle_count()));
    put_u32(p + 20, uint32_t(mesh.group_count()));
    p += HEADER;
    auto copy = [&](const void* data, size_t bytes) {
        if (bytes > 0) {
            std::memcpy(p, data, bytes);
            p += bytes;
        }
    };
    copy(mesh.positions.data(), mesh.positions.size() * 4);
    copy(mesh.triangles.data(), mesh.triangles.size() * 4);
    copy(mesh.groups.data(), mesh.groups.size() * 4);
    for (const std::string& name : mesh.group_names) {
        const uint16_t length = uint16_t(name.size());
        std::memcpy(p, &length, 2);
        p += 2;
        copy(name.data(), name.size());
    }
    put_u32(p, crc32(out, size_t(p - out)));
}

bool read_blob(const uint8_t* bytes, size_t size, MeshData& mesh, std::string& error)
{
    if (size < HEADER + 4 || std::memcmp(bytes, "HFM1", 4) != 0) {
        error = "The stored mesh is not readable: it does not start with the HFM1 magic.";
        return false;
    }
    const uint32_t version = get_u32(bytes + 4), flags = get_u32(bytes + 8);
    if (version != 1) {
        error = "The stored mesh is not readable: its version is " + std::to_string(version) + ", this build reads version 1.";
        return false;
    }
    if (flags != 0) {
        error = "The stored mesh is not readable: it has unknown flags (" + std::to_string(flags) + ").";
        return false;
    }
    const uint64_t V = get_u32(bytes + 12), T = get_u32(bytes + 16), G = get_u32(bytes + 20);
    const std::string sizes = validate_sizes(V, T, G);
    if (!sizes.empty()) {
        error = sizes;
        return false;
    }
    const uint64_t fixed = HEADER + V * 12 + T * 12 + T * 4;
    if (uint64_t(size) < fixed + G * 2 + 4) {
        error = "The stored mesh is not readable: its size is wrong (" + with_commas(size) + " bytes, too few for its " + with_commas(V) + " vertices and " +
                with_commas(T) + " triangles).";
        return false;
    }
    // Names: the byte count must come out exactly.
    uint64_t at = fixed;
    for (uint64_t g = 0; g < G; ++g) {
        if (at + 2 > uint64_t(size) - 4) {
            error = "The stored mesh is not readable: its size is wrong (the face group names run past the end).";
            return false;
        }
        uint16_t length;
        std::memcpy(&length, bytes + at, 2);
        at += 2 + uint64_t(length);
    }
    if (at + 4 != uint64_t(size)) {
        error = "The stored mesh is not readable: its size is wrong (" + with_commas(size) + " bytes, " + with_commas(at + 4) + " expected).";
        return false;
    }
    if (crc32(bytes, size - 4) != get_u32(bytes + size - 4)) {
        error = "The stored mesh is damaged: its CRC checksum does not match.";
        return false;
    }
    MeshData read;
    read.positions.resize(size_t(V) * 3);
    read.triangles.resize(size_t(T) * 3);
    read.groups.resize(size_t(T));
    const uint8_t* p = bytes + HEADER;
    if (V > 0) {
        std::memcpy(read.positions.data(), p, size_t(V) * 12);
    }
    p += V * 12;
    if (T > 0) {
        std::memcpy(read.triangles.data(), p, size_t(T) * 12);
        std::memcpy(read.groups.data(), p + T * 12, size_t(T) * 4);
    }
    p += T * 16;
    read.group_names.resize(size_t(G));
    for (uint64_t g = 0; g < G; ++g) {
        uint16_t length;
        std::memcpy(&length, p, 2);
        read.group_names[size_t(g)].assign(reinterpret_cast<const char*>(p + 2), length);
        p += 2 + size_t(length);
    }
    const std::string problem = validate(read);
    if (!problem.empty()) {
        error = problem;
        return false;
    }
    mesh = std::move(read);
    return true;
}

// ---------------------------------------------------------------- simple ops on the data

MeshData transformed(const MeshData& mesh, const double basis[9], const double origin[3])
{
    MeshData out;
    out.triangles = mesh.triangles;
    out.groups = mesh.groups;
    out.group_names = mesh.group_names;
    out.positions.resize(mesh.positions.size());
    const size_t V = mesh.vertex_count();
    for (size_t v = 0; v < V; ++v) {
        const double x = mesh.positions[v * 3], y = mesh.positions[v * 3 + 1], z = mesh.positions[v * 3 + 2];
        for (int r = 0; r < 3; ++r) {
            out.positions[v * 3 + size_t(r)] = float(basis[r * 3] * x + basis[r * 3 + 1] * y + basis[r * 3 + 2] * z + origin[r]);
        }
    }
    const double det = basis[0] * (basis[4] * basis[8] - basis[5] * basis[7]) - basis[1] * (basis[3] * basis[8] - basis[5] * basis[6]) +
                       basis[2] * (basis[3] * basis[7] - basis[4] * basis[6]);
    if (det < 0.0) {
        for (size_t t = 0; t < out.triangle_count(); ++t) {
            std::swap(out.triangles[t * 3 + 1], out.triangles[t * 3 + 2]);
        }
    }
    return out;
}

size_t weld_exact(MeshData& mesh)
{
    const size_t V = mesh.vertex_count();
    if (V == 0) {
        return 0;
    }
    // Open addressing over vertex ids; a slot holds id + 1.
    size_t capacity = 16;
    while (capacity < V * 2) {
        capacity <<= 1;
    }
    std::vector<uint32_t> table(capacity, 0);
    std::vector<uint32_t> remap(V);
    std::vector<float> kept;
    kept.reserve(mesh.positions.size());
    uint32_t next = 0;
    for (size_t v = 0; v < V; ++v) {
        float p[3];
        for (int k = 0; k < 3; ++k) {
            p[k] = mesh.positions[v * 3 + size_t(k)] + 0.0f;  // -0 becomes +0
        }
        uint32_t bits[3];
        std::memcpy(bits, p, 12);
        uint64_t h = mix(mix(mix(0x51ED270B7F4A7C15ull, bits[0]), bits[1]), bits[2]);
        size_t slot = size_t(h ^ (h >> 31)) & (capacity - 1);
        for (;;) {
            const uint32_t held = table[slot];
            if (held == 0) {
                table[slot] = next + 1;
                remap[v] = next++;
                kept.insert(kept.end(), p, p + 3);
                break;
            }
            if (std::memcmp(&kept[size_t(held - 1) * 3], p, 12) == 0) {
                remap[v] = held - 1;
                break;
            }
            slot = (slot + 1) & (capacity - 1);
        }
    }
    const size_t removed = V - size_t(next);
    mesh.positions.swap(kept);
    for (uint32_t& v : mesh.triangles) {
        v = remap[v];
    }
    return removed;
}

}  // namespace holo_forge::mesh
