// STL and OBJ readers of the Mesh workspace (contract C4.1). Our own code: pmp::read decides an
// STL's kind by a leading "solid" alone and lets topology exceptions through.
//
// A damaged file is never read as if it were whole: it is refused with the reason, or what is
// there is loaded and `warning` says what is missing and how much.

#include "mesh_budget.h"
#include "mesh_data.h"

#include <algorithm>
#include <charconv>
#include <climits>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <tuple>
#include <utility>
#include <unordered_map>
#include <vector>

namespace holo_forge::mesh
{

namespace
{
inline bool is_space(uint8_t c)
{
    return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\f' || c == '\v';
}

inline char lower(char c)
{
    return (c >= 'A' && c <= 'Z') ? char(c - 'A' + 'a') : c;
}

/// Is [word, word + size) the keyword (given in lower case), in any case?
bool is_word(const char* word, size_t size, const char* keyword)
{
    const size_t length = std::strlen(keyword);
    if (size != length) {
        return false;
    }
    for (size_t i = 0; i < length; ++i) {
        if (lower(word[i]) != keyword[i]) {
            return false;
        }
    }
    return true;
}

/// Does [begin, end) hold the keyword (lower case), in any case?
bool holds_word(const uint8_t* begin, const uint8_t* end, const char* keyword)
{
    const size_t length = std::strlen(keyword);
    if (size_t(end - begin) < length) {
        return false;
    }
    for (const uint8_t* p = begin; p + length <= end; ++p) {
        size_t i = 0;
        while (i < length && lower(char(p[i])) == keyword[i]) {
            ++i;
        }
        if (i == length) {
            return true;
        }
    }
    return false;
}

/// Reads a number at p (a leading '+' is allowed). False when there is none.
bool read_number(const char*& p, const char* end, double& value)
{
    while (p < end && (*p == ' ' || *p == '\t')) {
        ++p;
    }
    if (p < end && *p == '+') {
        ++p;
    }
    const std::from_chars_result r = std::from_chars(p, end, value);
    if (r.ec != std::errc()) {
        return false;
    }
    p = r.ptr;
    return true;
}

std::string too_many(const std::string& label, uint64_t triangles)
{
    return label + " has " + with_commas(triangles) + " triangles; mesh bodies take up to " + with_commas(budget::MAX_TRIANGLES_MESH) + ".";
}

std::string too_slow(const std::string& label)
{
    return "Reading " + label + " took longer than " + seconds_text(budget::READ_SECONDS) + " s and was stopped. Use a smaller file.";
}

std::string plural(uint64_t count, const char* one, const char* many)
{
    return with_commas(count) + " " + (count == 1 ? one : many);
}

/// "" when every coordinate is a finite number within the size a mesh body can have, else the
/// sentence for a file.
std::string coordinate_problem(const std::string& label, const std::vector<float>& positions, const char* kind)
{
    for (size_t i = 0; i < positions.size(); ++i) {
        const float value = positions[i];
        if (!std::isfinite(value)) {
            return label + " is not a readable " + kind + " file: it has a coordinate that is not a finite number.";
        }
        if (std::fabs(double(value)) > budget::MAX_COORDINATE) {
            return label + " is too large for a mesh body: it has a coordinate of " + length_text(double(value)) + ", and mesh bodies take coordinates up to " +
                   length_text(budget::MAX_COORDINATE) + " along each axis. Check the units.";
        }
    }
    return std::string();
}

// ---------------------------------------------------------------- polygons

enum class Split
{
    Whole,    // triangles that tile the polygon
    Folded,   // the polygon crosses itself or is folded flat: its triangles may overlap
    TooLong,  // not finished within the work allowed: no triangles
};

/// A polygon of n >= 3 points (3 doubles each) as n - 2 triangles (index triples into the
/// polygon), keeping its direction.
///
/// Corners along a straight side are the hard part. Such a corner must stay a vertex (the
/// neighbouring face has it too), and it must never be cut off as a triangle of its own: that
/// triangle has no area, and its third side runs along the polygon's side, where the
/// neighbouring face would put the same edge again (an edge of four triangles). So a corner that
/// is straight between its two sides of the polygon (within what float32 can tell) is never the
/// tip of a cut; it becomes a corner of triangles that reach across the polygon.
///
/// - Convex with no straight corner: a fan.
/// - Convex with straight corners: a strip, walked from a real corner along both sides at once,
///   each step taking the side that leaves a triangle with area and a rest that is not a line.
/// - Otherwise ear clipping. Corners are tested against the reflex and straight corners only,
///   found through a grid that a corner leaves when it is cut off or stops being either, so
///   real faces take near linear time. The work is counted; a polygon that would take seconds
///   gives TooLong.
Split triangulate_polygon(const std::vector<double>& pts, std::vector<int>& out, const Deadline& deadline)
{
    const int n = int(pts.size() / 3);
    out.clear();
    auto fan = [&]() {
        out.clear();
        for (int i = 1; i + 1 < n; ++i) {
            out.push_back(0);
            out.push_back(i);
            out.push_back(i + 1);
        }
    };
    if (n == 3) {
        fan();
        return Split::Whole;
    }
    // Newell normal, then the plane of the two other axes.
    double normal[3] = {0, 0, 0}, reach = 0.0;
    for (int i = 0; i < n; ++i) {
        const double* a = &pts[size_t(i) * 3];
        const double* b = &pts[size_t((i + 1) % n) * 3];
        normal[0] += (a[1] - b[1]) * (a[2] + b[2]);
        normal[1] += (a[2] - b[2]) * (a[0] + b[0]);
        normal[2] += (a[0] - b[0]) * (a[1] + b[1]);
        reach = std::max(reach, std::max(std::fabs(a[0]), std::max(std::fabs(a[1]), std::fabs(a[2]))));
    }
    int drop = 0;
    for (int k = 1; k < 3; ++k) {
        if (std::fabs(normal[k]) > std::fabs(normal[drop])) {
            drop = k;
        }
    }
    if (normal[drop] == 0.0) {
        fan();
        return Split::Folded;
    }
    const int ax = (drop + 1) % 3, ay = (drop + 2) % 3;
    const double sign = normal[drop] > 0.0 ? 1.0 : -1.0;
    std::vector<double> x(static_cast<size_t>(n)), y(static_cast<size_t>(n));
    double lo[2] = {INFINITY, INFINITY}, hi[2] = {-INFINITY, -INFINITY};
    for (int i = 0; i < n; ++i) {
        x[size_t(i)] = pts[size_t(i) * 3 + size_t(ax)];
        y[size_t(i)] = pts[size_t(i) * 3 + size_t(ay)] * sign;  // now counter-clockwise
        lo[0] = std::min(lo[0], x[size_t(i)]);
        hi[0] = std::max(hi[0], x[size_t(i)]);
        lo[1] = std::min(lo[1], y[size_t(i)]);
        hi[1] = std::max(hi[1], y[size_t(i)]);
    }
    // Twice the area of (a, b, c): positive when b is a left turn. Exact in sign for float input.
    auto turn = [&](int a, int b, int c) {
        return (x[size_t(b)] - x[size_t(a)]) * (y[size_t(c)] - y[size_t(a)]) - (y[size_t(b)] - y[size_t(a)]) * (x[size_t(c)] - x[size_t(a)]);
    };
    auto span = [&](int a, int b) { return std::hypot(x[size_t(b)] - x[size_t(a)], y[size_t(b)] - y[size_t(a)]); };
    // How far a float32 point can sit off a line it was meant to be on (4 steps of the largest
    // coordinate): a corner nearer than this to the line through its neighbours is straight.
    const double noise = 4.0 * 1.1920929e-7 * reach;
    auto straight = [&](int a, int b, int c) {
        const double base = span(a, c);
        return std::fabs(turn(a, b, c)) <= noise * base;
    };
    // Twice the polygon's area (positive now), to compare the triangles with at the end.
    double polygon_area = 0.0;
    for (int i = 0; i < n; ++i) {
        const int j = (i + 1) % n;
        polygon_area += (x[size_t(i)] - lo[0]) * (y[size_t(j)] - lo[1]) - (x[size_t(j)] - lo[0]) * (y[size_t(i)] - lo[1]);
    }
    auto tiles = [&]() {
        double sum = 0.0;
        for (size_t i = 0; i + 2 < out.size(); i += 3) {
            sum += std::fabs(turn(out[i], out[i + 1], out[i + 2]));
        }
        return sum <= polygon_area * (1.0 + 1e-9) + 1e-300;
    };
    // Convex: no right turn, and one turn around in all. Which corners are straight.
    bool convex = true;
    int blocking = 0, straight_corners = 0;
    double angle = 0.0;
    std::vector<uint8_t> is_straight(static_cast<size_t>(n), 0);
    for (int i = 0; i < n; ++i) {
        const int a = i, b = (i + 1) % n, c = (i + 2) % n;
        const double t = turn(a, b, c);
        if (t < 0.0) {
            convex = false;
        }
        if (straight(a, b, c)) {
            is_straight[size_t(b)] = 1;
            ++straight_corners;
        }
        if (t <= 0.0 || is_straight[size_t(b)]) {
            ++blocking;
        }
        const double ux = x[size_t(b)] - x[size_t(a)], uy = y[size_t(b)] - y[size_t(a)];
        const double vx = x[size_t(c)] - x[size_t(b)], vy = y[size_t(c)] - y[size_t(b)];
        angle += std::atan2(ux * vy - uy * vx, ux * vx + uy * vy);
    }
    convex = convex && std::fabs(angle - 2.0 * M_PI) < 0.5;
    if (convex && straight_corners == 0) {
        fan();
        return Split::Whole;
    }
    if (convex && n - straight_corners >= 3) {
        // A strip from a real corner v0: `low` walks forward from it, `high` backward. The rest
        // is always the polygon low .. high. Taking (low, low + 1, high) leaves low + 1 .. high,
        // taking (low, high - 1, high) leaves low .. high - 1; a step is good when its triangle
        // has area and what it leaves is not all on one side (a run of corners is on one side
        // exactly when no real corner lies strictly inside it).
        int start = 0;
        while (is_straight[size_t(start)]) {
            ++start;
        }
        std::vector<int> real(static_cast<size_t>(n) + 1, 0);  // real corners before position i
        for (int i = 0; i < n; ++i) {
            real[size_t(i) + 1] = real[size_t(i)] + (is_straight[size_t((start + i) % n)] ? 0 : 1);
        }
        auto reals = [&](int from, int to) { return from > to ? 0 : real[size_t(to) + 1] - real[size_t(from)]; };
        auto at = [&](int i) { return (start + i) % n; };
        int low = 0, high = n - 1;
        bool forward = true, stuck = false;
        while (high - low >= 2) {
            if (high - low == 2) {
                out.push_back(at(low));
                out.push_back(at(low + 1));
                out.push_back(at(high));
                break;
            }
            // (low is a real corner or was reached over one, so (high, low, low + 1) is never a line.)
            const bool can_forward = reals(low + 2, high - 1) > 0;
            const bool can_backward = reals(high, n - 1) + reals(0, low - 1) > 0 && reals(low + 1, high - 2) > 0;
            if (!can_forward && !can_backward) {
                stuck = true;
                break;
            }
            const bool go_forward = can_forward && (forward || !can_backward);
            out.push_back(at(low));
            out.push_back(at(go_forward ? low + 1 : high - 1));
            out.push_back(at(high));
            if (go_forward) {
                ++low;
            }
            else {
                --high;
            }
            forward = !go_forward;
        }
        if (!stuck && tiles()) {
            return Split::Whole;
        }
        out.clear();  // (not as convex as it looked: the general way)
    }

    // Ear clipping over a ring of corners.
    std::vector<int> prev(static_cast<size_t>(n)), next(static_cast<size_t>(n));
    for (int i = 0; i < n; ++i) {
        prev[size_t(i)] = (i + n - 1) % n;
        next[size_t(i)] = (i + 1) % n;
    }
    // A corner that may not be the tip of a cut while anything else can be cut: straight between
    // two sides of the polygon. (It only ever ends: when one of the corner's two sides is cut away.)
    std::vector<uint8_t> lock(is_straight);
    // A corner that is straight between the two corners next to it now (sides of the polygon or
    // cuts): worked out again for the two neighbours of every cut.
    std::vector<uint8_t> flat(is_straight);
    // A corner that can lie in the way of a cut: reflex, or straight. A straight one is in the
    // way from as near as float32 can put it: the line it is on must not become the side of a
    // cut, or a triangle without area is what is left of it.
    auto blocks = [&](int b) { return flat[size_t(b)] != 0 || turn(prev[size_t(b)], b, next[size_t(b)]) <= 0.0; };
    // The grid of blocking corners, about one a cell, and the same corners as one list `all`.
    // Every corner has a cell and a place kept in it, since a corner can come to be in the way
    // later (when a cut leaves it straight). The grid is laid out again for the corners still
    // in it whenever seven in eight have left: late cuts are large, and would walk through
    // cells that are mostly empty by then.
    int cells = 1, alive = 0;
    double step[2] = {0.0, 0.0};
    auto cell_x = [&](double v) { return step[0] > 0.0 ? std::clamp(int((v - lo[0]) / step[0]), 0, cells - 1) : 0; };
    auto cell_y = [&](double v) { return step[1] > 0.0 ? std::clamp(int((v - lo[1]) / step[1]), 0, cells - 1) : 0; };
    std::vector<int> cell_first, cell_live, items;
    std::vector<int> home(static_cast<size_t>(n), 0), slot_of(static_cast<size_t>(n), -1);
    std::vector<int> all, all_slot(static_cast<size_t>(n), -1);
    all.reserve(size_t(blocking));
    for (int i = 0; i < n; ++i) {
        if (blocks(i)) {
            all_slot[size_t(i)] = int(all.size());
            all.push_back(i);
        }
    }
    size_t laid_out_for = 0;
    auto lay_out = [&]() {
        laid_out_for = all.size();
        cells = std::clamp(int(std::sqrt(double(all.size()))) + 1, 1, 2048);
        step[0] = (hi[0] - lo[0]) / cells;
        step[1] = (hi[1] - lo[1]) / cells;
        cell_first.assign(size_t(cells) * size_t(cells) + 1, 0);
        cell_live.assign(size_t(cells) * size_t(cells), 0);
        // Room in each cell for every corner of the ring that lies in it.
        int v = alive;
        do {
            home[size_t(v)] = cell_y(y[size_t(v)]) * cells + cell_x(x[size_t(v)]);
            ++cell_first[size_t(home[size_t(v)]) + 1];
            v = next[size_t(v)];
        } while (v != alive);
        for (size_t c = 0; c + 1 < cell_first.size(); ++c) {
            cell_first[c + 1] += cell_first[c];
        }
        items.assign(size_t(cell_first.back()), 0);
        for (const int b : all) {
            const int c = home[size_t(b)];
            slot_of[size_t(b)] = cell_live[size_t(c)]++;
            items[size_t(cell_first[size_t(c)] + slot_of[size_t(b)])] = b;
        }
    };
    lay_out();
    auto enter_grid = [&](int v) {
        if (slot_of[size_t(v)] >= 0) {
            return;
        }
        const int c = home[size_t(v)];
        slot_of[size_t(v)] = cell_live[size_t(c)]++;
        items[size_t(cell_first[size_t(c)] + slot_of[size_t(v)])] = v;
        all_slot[size_t(v)] = int(all.size());
        all.push_back(v);
    };
    auto leave_grid = [&](int v) {
        if (slot_of[size_t(v)] < 0) {
            return;
        }
        const int c = home[size_t(v)];
        const int last = items[size_t(cell_first[size_t(c)] + cell_live[size_t(c)] - 1)];
        items[size_t(cell_first[size_t(c)] + slot_of[size_t(v)])] = last;
        slot_of[size_t(last)] = slot_of[size_t(v)];
        --cell_live[size_t(c)];
        slot_of[size_t(v)] = -1;
        const int moved = all.back();
        all[size_t(all_slot[size_t(v)])] = moved;
        all_slot[size_t(moved)] = all_slot[size_t(v)];
        all.pop_back();
        all_slot[size_t(v)] = -1;
    };
    uint64_t work = 0;
    const uint64_t allowed = 200000000ull;  // about a second of corner tests
    // Can corner b be cut off? Three levels, each used only when the one before finds no corner
    // to cut anywhere: 0, the cut must have area that float32 can hold (a sliver is left for a
    // triangle that reaches across); 1, a sliver may be cut where it is not along a side of the
    // polygon; 2, anything that turns left, and corners on the cut's outline do not block it.
    auto is_ear = [&](int b, int level) {
        const int a = prev[size_t(b)], c = next[size_t(b)];
        if (!(turn(a, b, c) > 0.0)) {
            return false;  // reflex, or on a line: a cut there would have no area
        }
        if ((level == 0 && flat[size_t(b)]) || (level == 1 && lock[size_t(b)])) {
            return false;
        }
        const bool loose = level >= 2;
        // The cut's box, widened by what float32 can be off.
        const double bx0 = std::min(x[size_t(a)], std::min(x[size_t(b)], x[size_t(c)])) - noise, bx1 = std::max(x[size_t(a)], std::max(x[size_t(b)], x[size_t(c)])) + noise;
        const double by0 = std::min(y[size_t(a)], std::min(y[size_t(b)], y[size_t(c)])) - noise, by1 = std::max(y[size_t(a)], std::max(y[size_t(b)], y[size_t(c)])) + noise;
        const int x0 = cell_x(bx0), x1 = cell_x(bx1), y0 = cell_y(by0), y1 = cell_y(by1);
        const double side[3] = {span(a, b), span(b, c), span(c, a)};
        // Is corner p in the way of the cut?
        auto in_the_way = [&](int p) {
            ++work;
            if (p == a || p == b || p == c) {
                return false;
            }
            const double px = x[size_t(p)], py = y[size_t(p)];
            // A corner at the place of one of the cut's own (a repeated position) does not block it.
            if ((px == x[size_t(a)] && py == y[size_t(a)]) || (px == x[size_t(b)] && py == y[size_t(b)]) || (px == x[size_t(c)] && py == y[size_t(c)])) {
                return false;
            }
            const double d1 = turn(a, b, p), d2 = turn(b, c, p), d3 = turn(c, a, p);
            if (loose) {
                return d1 > 0.0 && d2 > 0.0 && d3 > 0.0;
            }
            if (d1 >= 0.0 && d2 >= 0.0 && d3 >= 0.0) {
                return true;
            }
            // Outside, but is it within float32's reach of one of the cut's sides (between its
            // ends)? Then it is in the way too: a reflex or straight corner on the cut's side
            // would be left straight between corners of the rest, with no triangle with area to
            // take it (a staircase whose inner corners lie on one line, tilted: 2 nm needles).
            // (First the cheap part: farther than that outside one side's line is farther from
            // the whole cut.)
            if (d1 < -noise * side[0] || d2 < -noise * side[1] || d3 < -noise * side[2]) {
                return false;
            }
            const int ends[3][2] = {{a, b}, {b, c}, {c, a}};
            for (const auto& e : ends) {
                const double ux = x[size_t(e[0])], uy = y[size_t(e[0])];
                const double ex = x[size_t(e[1])] - ux, ey = y[size_t(e[1])] - uy;
                const double length2 = ex * ex + ey * ey;
                const double t = length2 > 0.0 ? std::clamp(((px - ux) * ex + (py - uy) * ey) / length2, 0.0, 1.0) : 0.0;
                const double rx = px - (ux + t * ex), ry = py - (uy + t * ey);
                if (rx * rx + ry * ry <= noise * noise) {
                    return true;
                }
            }
            return false;
        };
        // Through the grid's cells, or (when the box holds more than two cells for every corner
        // left in the grid) through those corners, most of them told apart by the box.
        if (uint64_t(x1 - x0 + 1) * uint64_t(y1 - y0 + 1) > 2 * uint64_t(all.size())) {
            uint32_t passed = 0;
            for (const int p : all) {
                const double px = x[size_t(p)], py = y[size_t(p)];
                if (px < bx0 || px > bx1 || py < by0 || py > by1) {
                    work += (++passed & 1u) == 0u ? 1 : 0;  // (half a full test)
                    continue;
                }
                if (in_the_way(p)) {
                    return false;
                }
            }
            return true;
        }
        for (int cy = y0; cy <= y1; ++cy) {
            for (int cx = x0; cx <= x1; ++cx) {
                const size_t cell = size_t(cy) * size_t(cells) + size_t(cx);
                ++work;
                for (int i = 0; i < cell_live[cell]; ++i) {
                    if (in_the_way(items[size_t(cell_first[cell] + i)])) {
                        return false;
                    }
                }
            }
        }
        return true;
    };
    out.reserve(size_t(n - 2) * 3);
    // Corners are looked at in rounds. A round looks at the corners whose surroundings changed in
    // the round before (the two neighbours of every cut), so the work follows the cuts, not the
    // size of the polygon times the number of rounds. A neighbour of a cut waits for the next
    // round: cutting every other corner keeps the triangles even. When a round cuts nothing, all
    // corners are looked at once more; when that cuts nothing either, the next level is tried.
    std::vector<int> round(static_cast<size_t>(n)), following;
    for (int i = 0; i < n; ++i) {
        round[size_t(i)] = i;
    }
    std::vector<uint8_t> gone(static_cast<size_t>(n), 0), waiting(static_cast<size_t>(n), 0);
    int left = n, level = 0;
    bool folded = false, all_looked_at = true;
    while (left > 3) {
        size_t cuts = 0;
        for (size_t i = 0; i < round.size() && left > 3; ++i) {
            const int b = round[i];
            if (gone[size_t(b)] || waiting[size_t(b)]) {
                continue;
            }
            if (work > allowed || deadline.tick()) {
                out.clear();
                return Split::TooLong;
            }
            ++work;
            if (!is_ear(b, level)) {
                continue;
            }
            const int a = prev[size_t(b)], c = next[size_t(b)];
            out.push_back(a);
            out.push_back(b);
            out.push_back(c);
            next[size_t(a)] = c;
            prev[size_t(c)] = a;
            lock[size_t(a)] = 0;  // a .. c is a cut now, not a side of the polygon
            lock[size_t(c)] = 0;
            leave_grid(b);
            gone[size_t(b)] = 1;
            alive = a;
            --left;
            ++cuts;
            for (const int v : {a, c}) {
                // Its neighbours may have stopped being in the way, or have come to be (left
                // straight by the cut); they are looked at next round.
                flat[size_t(v)] = straight(prev[size_t(v)], v, next[size_t(v)]) ? 1 : 0;
                if (blocks(v)) {
                    enter_grid(v);
                }
                else {
                    leave_grid(v);
                }
                if (!waiting[size_t(v)]) {
                    waiting[size_t(v)] = 1;
                    following.push_back(v);
                }
            }
        }
        if (left <= 3) {
            break;
        }
        for (const int v : following) {
            waiting[size_t(v)] = 0;
        }
        if (laid_out_for > 64 && all.size() * 8 < laid_out_for) {
            lay_out();
        }
        if (cuts > 0) {
            round.swap(following);
            following.clear();
            all_looked_at = false;
            continue;
        }
        following.clear();
        if (all_looked_at) {
            if (level == 2) {
                // No corner can be cut off: the polygon crosses itself. The rest goes out as a fan.
                folded = true;
                int v = next[size_t(alive)];
                while (next[size_t(v)] != alive) {
                    out.push_back(alive);
                    out.push_back(v);
                    out.push_back(next[size_t(v)]);
                    v = next[size_t(v)];
                }
                left = 0;
                break;
            }
            ++level;
        }
        // Every corner that is left, once around.
        round.clear();
        int v = alive;
        do {
            round.push_back(v);
            v = next[size_t(v)];
        } while (v != alive);
        all_looked_at = true;
    }
    if (left == 3) {
        out.push_back(prev[size_t(alive)]);
        out.push_back(alive);
        out.push_back(next[size_t(alive)]);
    }
    return (folded || !tiles()) ? Split::Folded : Split::Whole;
}

// ---------------------------------------------------------------- STL: which kind

/// Does the start of the file read as a text STL? "solid" first (after blanks) with a "facet"
/// or an "endsolid" within the first kilobyte, in any case.
bool reads_as_text(const uint8_t* data, size_t size)
{
    const size_t span = std::min<size_t>(size, 1024);
    size_t i = 0;
    while (i < span && is_space(data[i])) {
        ++i;
    }
    if (i + 5 > span || !is_word(reinterpret_cast<const char*>(data + i), 5, "solid")) {
        return false;
    }
    return holds_word(data + i, data + span, "facet") || holds_word(data + i, data + span, "endsolid");
}
}  // namespace

uint32_t stl_binary_count(FileBytes file)
{
    uint32_t n = 0;
    if (file.size >= 84) {
        std::memcpy(&n, file.data + 80, 4);
    }
    return n;
}

bool stl_is_binary(FileBytes head, uint64_t file_size)
{
    if (head.size < 84 || file_size < 84) {
        return false;
    }
    const uint64_t n = stl_binary_count(head);
    if (84ull + 50ull * n > file_size) {
        return false;
    }
    // The size fits a binary file. It is still text when it reads like text.
    return !reads_as_text(head.data, head.size);
}

bool stl_is_binary(FileBytes file)
{
    return stl_is_binary(file, file.size);
}

// ---------------------------------------------------------------- STL

bool parse_stl(FileBytes file, const std::string& label, double scale, MeshData& mesh, std::string& error, std::string& warning)
{
    warning.clear();
    if (!(scale > 0.0) || !std::isfinite(scale)) {
        error = "The scale of " + label + " must be a positive number.";
        return false;
    }
    const Deadline deadline(budget::READ_SECONDS);
    MeshData read;
    if (!reads_as_text(file.data, file.size)) {
        // Binary: an 80-byte header, a count, 50 bytes a facet.
        if (file.size < 84) {
            error = label + " is not an STL file: it has " + plural(file.size, "byte", "bytes") + ", too few for a binary STL file, and it does not read as a text one.";
            return false;
        }
        const uint64_t n = stl_binary_count(file);
        const uint64_t needed = 84ull + 50ull * n;
        if (needed > file.size) {
            error = label + " says it has " + plural(n, "triangle", "triangles") + ", which takes " + with_commas(needed) + " bytes, but the file has " + with_commas(file.size) +
                    "; it looks cut off.";
            return false;
        }
        if (n > budget::MAX_TRIANGLES_MESH) {
            error = too_many(label, n);
            return false;
        }
        // Bytes after the last facet: zeros are padding; anything else of a facet's size or more
        // is data the count does not name.
        const uint64_t extra = file.size - needed;
        if (extra >= 50) {
            bool blank = true;
            for (uint64_t i = needed; i < file.size && blank; ++i) {
                blank = file.data[i] == 0;
            }
            if (!blank) {
                warning = label + " says it has " + plural(n, "triangle", "triangles") + " but holds room for " + with_commas((file.size - 84) / 50) + " (" + with_commas(extra) +
                          " bytes follow the last one); only the " + with_commas(n) + " it names were read.";
            }
        }
        read.positions.resize(size_t(n) * 9);
        const uint8_t* p = file.data + 84;
        for (uint64_t t = 0; t < n; ++t, p += 50) {
            float v[9];
            std::memcpy(v, p + 12, 36);
            for (int k = 0; k < 9; ++k) {
                read.positions[size_t(t) * 9 + size_t(k)] = float(double(v[k]) * scale);
            }
            if (deadline.tick()) {
                error = too_slow(label);
                return false;
            }
        }
    }
    else {
        if (double(file.size) > budget::MAX_TEXT_FILE_BYTES) {
            error = label + " is a text file of " + with_commas(file.size) + " bytes; text files up to " + with_commas(uint64_t(budget::MAX_TEXT_FILE_BYTES)) +
                    " bytes can be read.";
            return false;
        }
        const char* begin = reinterpret_cast<const char*>(file.data);
        const char* p = begin;
        const char* end = p + file.size;
        uint64_t facets = 0;      // whole facets read
        bool in_facet = false;    // after "facet", before its "endfacet"
        bool in_solid = false;    // after "solid", before its "endsolid"
        int vertices = 0;         // of the open facet
        auto broken = [&](const std::string& what) {
            error = label + " is not a readable STL file: " + what;
            return false;
        };
        auto cut_off = [&]() {
            error = label + " ends inside facet " + with_commas(facets + 1) + "; it looks cut off.";
            return false;
        };
        auto skip_line = [&]() {
            while (p < end && *p != '\n') {
                ++p;
            }
        };
        while (p < end) {
            while (p < end && is_space(uint8_t(*p))) {
                ++p;
            }
            const char* word = p;
            while (p < end && !is_space(uint8_t(*p))) {
                ++p;
            }
            const size_t size = size_t(p - word);
            if (size == 0) {
                break;
            }
            if (is_word(word, size, "vertex")) {
                if (!in_facet) {
                    return broken("a vertex stands outside a facet (near byte " + with_commas(uint64_t(word - begin)) + ").");
                }
                double v[3];
                for (int k = 0; k < 3; ++k) {
                    if (!read_number(p, end, v[k])) {
                        const char* rest = p;
                        while (rest < end && is_space(uint8_t(*rest))) {
                            ++rest;
                        }
                        if (rest >= end) {
                            return cut_off();
                        }
                        return broken("a vertex of facet " + with_commas(facets + 1) + " has no three numbers (near byte " + with_commas(uint64_t(p - begin)) + ").");
                    }
                }
                ++vertices;
                if (vertices <= 3) {
                    for (int k = 0; k < 3; ++k) {
                        read.positions.push_back(float(v[k] * scale));
                    }
                }
            }
            else if (is_word(word, size, "facet")) {
                if (in_facet) {
                    return broken("facet " + with_commas(facets + 1) + " has no endfacet.");
                }
                in_facet = true;
                vertices = 0;
                if (facets >= budget::MAX_TRIANGLES_MESH) {
                    error = label + " has more than " + with_commas(budget::MAX_TRIANGLES_MESH) + " triangles; mesh bodies take up to " + with_commas(budget::MAX_TRIANGLES_MESH) + ".";
                    return false;
                }
            }
            else if (is_word(word, size, "endfacet")) {
                if (!in_facet) {
                    return broken("an endfacet stands without a facet (near byte " + with_commas(uint64_t(word - begin)) + ").");
                }
                if (vertices != 3) {
                    return broken("facet " + with_commas(facets + 1) + " has " + plural(uint64_t(vertices), "vertex", "vertices") + ", not 3.");
                }
                in_facet = false;
                ++facets;
            }
            else if (is_word(word, size, "solid")) {
                in_solid = true;
                skip_line();  // the rest of the line is its name
            }
            else if (is_word(word, size, "endsolid")) {
                if (in_facet) {
                    return broken("facet " + with_commas(facets + 1) + " has no endfacet.");
                }
                in_solid = false;
                skip_line();
            }
            // ("normal" and its numbers, "outer", "loop", "endloop": nothing to do.)
            if (deadline.tick()) {
                error = too_slow(label);
                return false;
            }
        }
        if (in_facet) {
            return cut_off();
        }
        if (facets > 0 && in_solid) {
            warning = label + " has no endsolid line after its last facet; it looks cut off (" + plural(facets, "triangle was", "triangles were") + " read).";
        }
    }
    const size_t T = read.positions.size() / 9;
    if (T == 0) {
        error = label + " has no triangles.";
        return false;
    }
    const std::string problem = coordinate_problem(label, read.positions, "STL");
    if (!problem.empty()) {
        error = problem;
        return false;
    }
    read.triangles.resize(T * 3);
    for (size_t i = 0; i < T * 3; ++i) {
        read.triangles[i] = uint32_t(i);
    }
    weld_exact(read);
    read.groups.assign(T, 0);
    read.group_names = {"g0"};
    const std::string invalid = validate(read);
    if (!invalid.empty()) {
        error = label + ": " + invalid;
        return false;
    }
    mesh = std::move(read);
    return true;
}

bool parse_stl(FileBytes file, const std::string& label, double scale, MeshData& mesh, std::string& error)
{
    std::string warning;
    return parse_stl(file, label, scale, mesh, error, warning);
}

// ---------------------------------------------------------------- OBJ

namespace
{
/// The faces of an OBJ file as read: their corners (vertex numbers), one face after another.
struct ObjFaces
{
    std::vector<uint32_t> first{0};  // F + 1 offsets into corners
    std::vector<uint32_t> corners;
    std::vector<uint32_t> group;     // F
    std::vector<uint32_t> line;      // F: the line of the file each face is on
    size_t count() const
    {
        return group.size();
    }
};

struct ObjTriangles
{
    std::vector<uint32_t> triangles, groups, face;  // 3T, T, T
    uint64_t folded_faces = 0;                      // faces that cross themselves or are folded flat
    uint32_t folded_line = 0;                       // the first one's line
};

enum class Built
{
    Done,
    Late,     // the reader's time ran out
    Tangled,  // one face could not be split in the work allowed (failed_face)
    TooMany,  // more triangles than a mesh body takes
};

/// Splits every face into triangles.
Built build_triangles(const ObjFaces& faces, const std::vector<float>& positions, ObjTriangles& out, size_t& failed_face, const Deadline& deadline)
{
    out = ObjTriangles();
    std::vector<double> polygon;
    std::vector<int> pieces;
    for (size_t f = 0; f < faces.count(); ++f) {
        const uint32_t* corners = &faces.corners[faces.first[f]];
        const size_t n = faces.first[f + 1] - faces.first[f];
        if (n == 3) {
            pieces.assign({0, 1, 2});
        }
        else {
            polygon.resize(n * 3);
            for (size_t i = 0; i < n; ++i) {
                for (int k = 0; k < 3; ++k) {
                    polygon[i * 3 + size_t(k)] = positions[size_t(corners[i]) * 3 + size_t(k)];
                }
            }
            const Split split = triangulate_polygon(polygon, pieces, deadline);
            if (split == Split::TooLong) {
                failed_face = f;
                return deadline.expired() ? Built::Late : Built::Tangled;
            }
            if (split == Split::Folded && out.folded_faces++ == 0) {
                out.folded_line = faces.line[f];
            }
        }
        for (size_t i = 0; i + 2 < pieces.size(); i += 3) {
            out.triangles.push_back(corners[size_t(pieces[i])]);
            out.triangles.push_back(corners[size_t(pieces[i + 1])]);
            out.triangles.push_back(corners[size_t(pieces[i + 2])]);
            out.groups.push_back(faces.group[f]);
            out.face.push_back(uint32_t(f));
        }
        if (out.groups.size() > budget::MAX_TRIANGLES_MESH) {
            return Built::TooMany;
        }
        if (deadline.tick()) {
            return Built::Late;
        }
    }
    return Built::Done;
}

/// An edge of one triangle only, as that triangle runs it, with the face the triangle is of.
/// (Cuts inside a face always have two triangles, so these are sides of faces.)
struct OpenEdge
{
    uint32_t from, to, face;
};

/// The open edges of the triangles. False when the time ran out.
bool open_edges(std::vector<float>& positions, ObjTriangles& mesh, std::vector<OpenEdge>& out, const Deadline& deadline)
{
    out.clear();
    State state;
    // (Lent to the state for the count, and taken back.)
    state.data.positions.swap(positions);
    state.data.triangles.swap(mesh.triangles);
    const Topology* topo = topology_of(state, &deadline);
    if (topo != nullptr && topo->boundary_edges > 0) {
        const std::vector<uint32_t>& triangles = state.data.triangles;
        for (size_t e = 0; e < topo->edge_count(); ++e) {
            if (topo->uses(uint32_t(e)) != 1) {
                continue;
            }
            const uint32_t he = topo->edge_hes[topo->edge_first[e]];
            out.push_back({triangles[he], triangles[he - he % 3 + (he + 1) % 3], mesh.face[he / 3]});
        }
    }
    state.data.positions.swap(positions);
    state.data.triangles.swap(mesh.triangles);
    return topo != nullptr;
}

/// Open edges that lie on another open edge the other way round with their corners at the
/// same places but other vertex numbers (a file that writes a vertex twice): `paired` marks
/// them, and the count of such pairs is returned.
uint64_t pair_repeated(const std::vector<float>& positions, const std::vector<OpenEdge>& edges, std::vector<uint8_t>& paired)
{
    paired.assign(edges.size(), 0);
    // One number per place: the smallest vertex number among the ends of open edges there.
    std::vector<uint32_t> ends;
    ends.reserve(edges.size() * 2);
    for (const OpenEdge& e : edges) {
        ends.push_back(e.from);
        ends.push_back(e.to);
    }
    auto bits = [&](uint32_t v) {
        uint32_t b[3];
        std::memcpy(b, &positions[size_t(v) * 3], 12);
        return std::make_tuple(b[0], b[1], b[2], v);
    };
    std::sort(ends.begin(), ends.end(), [&](uint32_t u, uint32_t v) { return bits(u) < bits(v); });
    ends.erase(std::unique(ends.begin(), ends.end()), ends.end());
    std::vector<std::pair<uint32_t, uint32_t>> place;  // (vertex, its place), sorted by vertex
    place.reserve(ends.size());
    for (size_t i = 0; i < ends.size();) {
        size_t j = i;
        uint32_t first = ends[i];
        while (j < ends.size() && std::memcmp(&positions[size_t(ends[j]) * 3], &positions[size_t(ends[i]) * 3], 12) == 0) {
            first = std::min(first, ends[j]);
            ++j;
        }
        for (size_t k = i; k < j; ++k) {
            place.push_back({ends[k], first});
        }
        i = j;
    }
    std::sort(place.begin(), place.end());
    auto place_of = [&](uint32_t v) { return std::lower_bound(place.begin(), place.end(), std::make_pair(v, uint32_t(0)))->second; };
    // Edges by (from place, to place); each looks for one the other way round.
    std::vector<std::pair<uint64_t, uint32_t>> keyed(edges.size());
    for (size_t i = 0; i < edges.size(); ++i) {
        keyed[i] = {uint64_t(place_of(edges[i].from)) << 32 | place_of(edges[i].to), uint32_t(i)};
    }
    std::sort(keyed.begin(), keyed.end());
    uint64_t pairs = 0;
    for (const auto& [key, i] : keyed) {
        const uint64_t back = key << 32 | key >> 32;
        if (paired[i] || back == key) {
            continue;
        }
        for (auto it = std::lower_bound(keyed.begin(), keyed.end(), std::make_pair(back, uint32_t(0))); it != keyed.end() && it->first == back; ++it) {
            const uint32_t j = it->second;
            // The other way round at the same places, but not the same vertices (those would share the edge).
            if (!paired[j] && (edges[j].from != edges[i].to || edges[j].to != edges[i].from)) {
                paired[i] = paired[j] = 1;
                ++pairs;
                break;
            }
        }
    }
    return pairs;
}

/// An end of an open edge that lies on or near another open edge, between its ends.
struct OnEdge
{
    uint32_t edge, vertex;
    double t, off;  // where along the edge (0 .. 1), and how far off its line
    bool on;        // on it: within the `on` tolerance
};

/// For every open edge that `use` marks, the ends of such edges that lie within `near` times its
/// length of it (`on`: within `on_rel` times its length, or float32's noise at its place when
/// that is more; both a quarter of an average open edge at most), farther than the `on`
/// tolerance from both its ends, and are not corners of its own face. Through a grid of cells
/// about one open edge long: each edge is walked through the cells it crosses, each end is put
/// in the cells within that distance of it, and the two lists, sorted by cell, are merged.
/// False when the time ran out (then `out` is partial).
bool ends_on_edges(const ObjFaces& faces, const std::vector<float>& positions, const std::vector<OpenEdge>& edges, const std::vector<uint8_t>& use, double rel,
                   double on_rel, std::vector<OnEdge>& out, const Deadline& deadline)
{
    out.clear();
    auto point = [&](uint32_t v, double p[3]) {
        for (int k = 0; k < 3; ++k) {
            p[k] = positions[size_t(v) * 3 + size_t(k)];
        }
    };
    std::vector<uint32_t> ends;
    double total = 0.0, lo[3] = {INFINITY, INFINITY, INFINITY};
    size_t used = 0;
    for (size_t i = 0; i < edges.size(); ++i) {
        if (!use[i]) {
            continue;
        }
        double a[3], b[3];
        point(edges[i].from, a);
        point(edges[i].to, b);
        total += std::sqrt((b[0] - a[0]) * (b[0] - a[0]) + (b[1] - a[1]) * (b[1] - a[1]) + (b[2] - a[2]) * (b[2] - a[2]));
        for (int k = 0; k < 3; ++k) {
            lo[k] = std::min(lo[k], std::min(a[k], b[k]));
        }
        ends.push_back(edges[i].from);
        ends.push_back(edges[i].to);
        ++used;
    }
    if (used == 0) {
        return true;
    }
    std::sort(ends.begin(), ends.end());
    ends.erase(std::unique(ends.begin(), ends.end()), ends.end());
    const double cell = total / double(used);
    if (!(cell > 0.0) || !std::isfinite(cell)) {
        return true;
    }
    auto cell_index = [&](double v, int k) { return int64_t(std::clamp(std::floor((v - lo[k]) / cell), -1e15, 1e15)); };
    auto key_of = [](int64_t cx, int64_t cy, int64_t cz) {
        // (Cells far apart may share a key: they only add pairs to test.)
        return (uint64_t(cx) & 0x1FFFFF) << 42 | (uint64_t(cy) & 0x1FFFFF) << 21 | (uint64_t(cz) & 0x1FFFFF);
    };
    // Each edge's tolerances, and the largest.
    std::vector<double> tol(edges.size(), 0.0), on_tol(edges.size(), 0.0);
    double widest = 0.0;
    for (size_t i = 0; i < edges.size(); ++i) {
        if (!use[i]) {
            continue;
        }
        double a[3], b[3], length2 = 0.0, reach = 0.0;
        point(edges[i].from, a);
        point(edges[i].to, b);
        for (int k = 0; k < 3; ++k) {
            length2 += (b[k] - a[k]) * (b[k] - a[k]);
            reach = std::max(reach, std::max(std::fabs(a[k]), std::fabs(b[k])));
        }
        const double noise = 4.0 * 1.1920929e-7 * reach;
        on_tol[i] = std::min(std::max(noise, on_rel * std::sqrt(length2)), 0.25 * cell);
        tol[i] = std::max(on_tol[i], std::min(rel * std::sqrt(length2), 0.25 * cell));
        widest = std::max(widest, tol[i]);
    }
    // The edges, cell by cell along each (a 3D grid walk).
    std::vector<std::pair<uint64_t, uint32_t>> edge_cells, end_cells;
    edge_cells.reserve(used * 3);
    for (size_t i = 0; i < edges.size(); ++i) {
        if (!use[i]) {
            continue;
        }
        if (deadline.tick()) {
            return false;
        }
        double a[3], b[3];
        point(edges[i].from, a);
        point(edges[i].to, b);
        int64_t c[3], last[3], step[3];
        double t_max[3], t_delta[3];
        for (int k = 0; k < 3; ++k) {
            c[k] = cell_index(a[k], k);
            last[k] = cell_index(b[k], k);
            const double d = b[k] - a[k];
            step[k] = d > 0.0 ? 1 : (d < 0.0 ? -1 : 0);
            if (step[k] == 0) {
                t_max[k] = t_delta[k] = INFINITY;
                continue;
            }
            const double border = lo[k] + double(c[k] + (step[k] > 0 ? 1 : 0)) * cell;
            t_max[k] = (border - a[k]) / d;
            t_delta[k] = cell / std::fabs(d);
        }
        const int64_t most = std::llabs(last[0] - c[0]) + std::llabs(last[1] - c[1]) + std::llabs(last[2] - c[2]) + 1;
        for (int64_t s = 0; s < most; ++s) {
            edge_cells.push_back({key_of(c[0], c[1], c[2]), uint32_t(i)});
            if (c[0] == last[0] && c[1] == last[1] && c[2] == last[2]) {
                break;
            }
            const int k = t_max[0] <= t_max[1] ? (t_max[0] <= t_max[2] ? 0 : 2) : (t_max[1] <= t_max[2] ? 1 : 2);
            c[k] += step[k];
            t_max[k] += t_delta[k];
        }
    }
    // The ends, in every cell within `widest` of them.
    for (const uint32_t v : ends) {
        double p[3];
        point(v, p);
        int64_t from[3], to[3];
        for (int k = 0; k < 3; ++k) {
            from[k] = cell_index(p[k] - widest, k);
            to[k] = cell_index(p[k] + widest, k);
        }
        for (int64_t x = from[0]; x <= to[0]; ++x) {
            for (int64_t y = from[1]; y <= to[1]; ++y) {
                for (int64_t z = from[2]; z <= to[2]; ++z) {
                    end_cells.push_back({key_of(x, y, z), v});
                }
            }
        }
    }
    std::sort(edge_cells.begin(), edge_cells.end());
    std::sort(end_cells.begin(), end_cells.end());
    // Merged: every end against every edge of its cell.
    uint64_t work = 0;
    const uint64_t allowed = 50000000ull;
    size_t i = 0, j = 0;
    while (i < edge_cells.size() && j < end_cells.size()) {
        if (edge_cells[i].first < end_cells[j].first) {
            ++i;
            continue;
        }
        if (end_cells[j].first < edge_cells[i].first) {
            ++j;
            continue;
        }
        const uint64_t key = edge_cells[i].first;
        size_t i_end = i, j_end = j;
        while (i_end < edge_cells.size() && edge_cells[i_end].first == key) {
            ++i_end;
        }
        while (j_end < end_cells.size() && end_cells[j_end].first == key) {
            ++j_end;
        }
        work += uint64_t(i_end - i) * uint64_t(j_end - j);
        if (work > allowed || deadline.tick()) {
            return false;
        }
        for (size_t ei = i; ei < i_end; ++ei) {
            const uint32_t e = edge_cells[ei].second;
            double a[3], b[3], d[3], length2 = 0.0;
            point(edges[e].from, a);
            point(edges[e].to, b);
            for (int k = 0; k < 3; ++k) {
                d[k] = b[k] - a[k];
                length2 += d[k] * d[k];
            }
            if (!(length2 > 0.0)) {
                continue;
            }
            const double length = std::sqrt(length2);
            for (size_t vj = j; vj < j_end; ++vj) {
                const uint32_t v = end_cells[vj].second;
                if (v == edges[e].from || v == edges[e].to) {
                    continue;
                }
                double p[3], dot = 0.0, r2 = 0.0;
                point(v, p);
                for (int k = 0; k < 3; ++k) {
                    const double r = p[k] - a[k];
                    dot += r * d[k];
                    r2 += r * r;
                }
                const double t = dot / length2;
                const double off2 = std::max(0.0, r2 - dot * dot / length2);
                if (off2 > tol[e] * tol[e] || t * length <= on_tol[e] || (1.0 - t) * length <= on_tol[e]) {
                    continue;
                }
                out.push_back({e, v, t, std::sqrt(off2), off2 <= on_tol[e] * on_tol[e]});
            }
        }
        i = i_end;
        j = j_end;
    }
    // Once each (an end can meet an edge in more than one cell), and not the edge's own face's corners.
    std::sort(out.begin(), out.end(), [](const OnEdge& p, const OnEdge& q) { return p.edge != q.edge ? p.edge < q.edge : p.vertex < q.vertex; });
    out.erase(std::unique(out.begin(), out.end(), [](const OnEdge& p, const OnEdge& q) { return p.edge == q.edge && p.vertex == q.vertex; }), out.end());
    std::vector<std::pair<uint32_t, uint32_t>> has;
    {
        std::vector<uint32_t> concerned;
        for (const OnEdge& o : out) {
            concerned.push_back(edges[o.edge].face);
        }
        std::sort(concerned.begin(), concerned.end());
        concerned.erase(std::unique(concerned.begin(), concerned.end()), concerned.end());
        for (const uint32_t f : concerned) {
            for (uint32_t c = faces.first[f]; c < faces.first[f + 1]; ++c) {
                has.push_back({f, faces.corners[c]});
            }
        }
        std::sort(has.begin(), has.end());
    }
    out.erase(std::remove_if(out.begin(), out.end(), [&](const OnEdge& o) { return std::binary_search(has.begin(), has.end(), std::make_pair(edges[o.edge].face, o.vertex)); }),
              out.end());
    return true;
}

/// One face that takes corners of others into one of its sides.
struct Splice
{
    uint32_t face, from, to;
    std::vector<uint32_t> between;  // from `from` to `to`
};

/// The splices for corners found on open sides: each side takes the corners on it in order
/// along it; of corners at one place only the first.
std::vector<Splice> splices_of(const std::vector<float>& positions, const std::vector<OpenEdge>& edges, std::vector<OnEdge> on)
{
    std::vector<Splice> splices;
    on.erase(std::remove_if(on.begin(), on.end(), [](const OnEdge& o) { return !o.on; }), on.end());
    std::sort(on.begin(), on.end(), [](const OnEdge& p, const OnEdge& q) { return p.edge != q.edge ? p.edge < q.edge : p.t < q.t; });
    for (size_t i = 0; i < on.size();) {
        size_t j = i;
        while (j < on.size() && on[j].edge == on[i].edge) {
            ++j;
        }
        const OpenEdge& e = edges[on[i].edge];
        Splice splice{e.face, e.from, e.to, {}};
        double last[3] = {NAN, NAN, NAN};
        for (size_t k = i; k < j; ++k) {
            const float* p = &positions[size_t(on[k].vertex) * 3];
            if (p[0] == last[0] && p[1] == last[1] && p[2] == last[2]) {
                continue;  // (another vertex at the same place: one corner is enough)
            }
            splice.between.push_back(on[k].vertex);
            last[0] = p[0];
            last[1] = p[1];
            last[2] = p[2];
        }
        splices.push_back(std::move(splice));
        i = j;
    }
    return splices;
}

/// The faces with the splices put in.
ObjFaces spliced(const ObjFaces& faces, std::vector<Splice>& splices)
{
    std::sort(splices.begin(), splices.end(), [](const Splice& a, const Splice& b) { return a.face < b.face; });
    ObjFaces out;
    out.group = faces.group;
    out.line = faces.line;
    out.corners.reserve(faces.corners.size() + splices.size() * 2);
    size_t s = 0;
    for (size_t f = 0; f < faces.count(); ++f) {
        while (s < splices.size() && splices[s].face < f) {
            ++s;
        }
        size_t last = s;
        while (last < splices.size() && splices[last].face == f) {
            ++last;
        }
        const uint32_t* corners = &faces.corners[faces.first[f]];
        const size_t n = faces.first[f + 1] - faces.first[f];
        for (size_t i = 0; i < n; ++i) {
            out.corners.push_back(corners[i]);
            const uint32_t following = corners[(i + 1) % n];
            for (size_t k = s; k < last; ++k) {
                if (splices[k].from == corners[i] && splices[k].to == following) {
                    out.corners.insert(out.corners.end(), splices[k].between.begin(), splices[k].between.end());
                    splices[k].from = NONE;  // (once)
                    break;
                }
            }
        }
        out.first.push_back(uint32_t(out.corners.size()));
    }
    return out;
}

/// The faces without those `drop` marks.
ObjFaces without_faces(const ObjFaces& faces, const std::vector<uint8_t>& drop)
{
    ObjFaces out;
    for (size_t f = 0; f < faces.count(); ++f) {
        if (drop[f]) {
            continue;
        }
        out.corners.insert(out.corners.end(), faces.corners.begin() + faces.first[f], faces.corners.begin() + faces.first[f + 1]);
        out.first.push_back(uint32_t(out.corners.size()));
        out.group.push_back(faces.group[f]);
        out.line.push_back(faces.line[f]);
    }
    return out;
}
}  // namespace

bool parse_obj(FileBytes file, const std::string& label, double scale, MeshData& mesh, std::string& error, std::string& warning)
{
    warning.clear();
    if (!(scale > 0.0) || !std::isfinite(scale)) {
        error = "The scale of " + label + " must be a positive number.";
        return false;
    }
    if (double(file.size) > budget::MAX_TEXT_FILE_BYTES) {
        error = label + " is a text file of " + with_commas(file.size) + " bytes; text files up to " + with_commas(uint64_t(budget::MAX_TEXT_FILE_BYTES)) + " bytes can be read.";
        return false;
    }
    const Deadline deadline(budget::READ_SECONDS);
    MeshData read;
    ObjFaces faces;
    bool new_group = true;  // the next face starts a group
    uint64_t line_number = 0;
    uint64_t short_faces = 0, short_line = 0;    // faces of one or two corners, and the first one's line
    uint64_t repeat_faces = 0, repeat_line = 0;  // faces that name a corner twice in a row
    const char* p = reinterpret_cast<const char*>(file.data);
    const char* end = p + file.size;
    auto broken = [&](const std::string& what) {
        error = label + " is not a readable OBJ file: " + what;
        return false;
    };
    // The same corner as the one before: the same vertex, or a vertex at the same place.
    auto same_corner = [&](uint32_t u, uint32_t v) {
        return u == v || std::memcmp(&read.positions[size_t(u) * 3], &read.positions[size_t(v) * 3], 12) == 0;
    };
    while (p < end) {
        const char* line = p;
        while (p < end && *p != '\n') {
            ++p;
        }
        const char* line_end = p;
        const bool unfinished = p >= end;  // the file stops without ending this line
        if (p < end) {
            ++p;
        }
        ++line_number;
        if (deadline.tick()) {
            error = too_slow(label);
            return false;
        }
        while (line_end > line && (line_end[-1] == '\r' || line_end[-1] == ' ' || line_end[-1] == '\t')) {
            --line_end;
        }
        while (line < line_end && (*line == ' ' || *line == '\t')) {
            ++line;
        }
        if (line_end == line) {
            continue;
        }
        const bool spaced = line_end - line == 1 || line[1] == ' ' || line[1] == '\t';
        if (line[0] == 'v' && spaced) {
            const char* q = line + 1;
            double v[3];
            for (int k = 0; k < 3; ++k) {
                if (!read_number(q, line_end, v[k])) {
                    if (unfinished) {
                        error = label + " ends inside a vertex on line " + with_commas(line_number) + "; it looks cut off.";
                        return false;
                    }
                    return broken("the vertex on line " + with_commas(line_number) + " has no three numbers.");
                }
                read.positions.push_back(float(v[k] * scale));
            }
        }
        else if ((line[0] == 'o' || line[0] == 'g') && spaced) {
            new_group = true;
        }
        else if (line[0] == 'f' && spaced) {
            const int64_t V = int64_t(read.positions.size() / 3);
            const size_t before = faces.corners.size();
            bool repeated = false;
            const char* q = line + 1;
            while (q < line_end) {
                while (q < line_end && (*q == ' ' || *q == '\t' || *q == '\r')) {
                    ++q;
                }
                if (q >= line_end) {
                    break;
                }
                int64_t index = 0;
                const std::from_chars_result r = std::from_chars(q, line_end, index);
                // A whole number, then the end of the corner or its "/vt/vn" part.
                if (r.ec != std::errc() || (r.ptr < line_end && *r.ptr != '/' && *r.ptr != ' ' && *r.ptr != '\t' && *r.ptr != '\r')) {
                    return broken("the face on line " + with_commas(line_number) + " has a corner that is not a whole number.");
                }
                const int64_t vertex = index < 0 ? V + index : index - 1;
                if (index == 0 || vertex < 0 || vertex >= V) {
                    return broken("the face on line " + with_commas(line_number) + " points at vertex " + std::to_string(index) + ", but " + with_commas(uint64_t(V)) +
                                  " vertices came before it.");
                }
                // A corner twice in a row (or two at one place) is one corner: the repeat would
                // make an edge of no length and a triangle without area.
                if (faces.corners.size() > before && same_corner(faces.corners.back(), uint32_t(vertex))) {
                    repeated = true;
                }
                else {
                    faces.corners.push_back(uint32_t(vertex));
                }
                q = r.ptr;
                while (q < line_end && !(*q == ' ' || *q == '\t' || *q == '\r')) {
                    ++q;  // the "/vt/vn" part
                }
            }
            // (Also the last corner again at the end: "f 1 2 3 4 1".)
            while (faces.corners.size() - before >= 2 && same_corner(faces.corners.back(), faces.corners[before])) {
                faces.corners.pop_back();
                repeated = true;
            }
            if (faces.corners.size() - before < 3) {
                // A face needs three corners. At the very end of a file without a line end it is
                // the mark of a file cut off; anywhere else the face is left out and counted.
                faces.corners.resize(before);
                if (unfinished) {
                    error = label + " ends inside a face on line " + with_commas(line_number) + "; it looks cut off.";
                    return false;
                }
                if (short_faces++ == 0) {
                    short_line = line_number;
                }
                continue;
            }
            if (repeated && repeat_faces++ == 0) {
                repeat_line = line_number;
            }
            if (new_group) {
                read.group_names.push_back("g" + std::to_string(read.group_names.size()));
                new_group = false;
            }
            faces.first.push_back(uint32_t(faces.corners.size()));
            faces.group.push_back(uint32_t(read.group_names.size() - 1));
            faces.line.push_back(uint32_t(line_number));
            // (Every face has a triangle or more: stop a file that cannot fit before splitting it.)
            if (faces.corners.size() - 2 * faces.count() > budget::MAX_TRIANGLES_MESH) {
                error = label + " has more than " + with_commas(budget::MAX_TRIANGLES_MESH) + " triangles; mesh bodies take up to " + with_commas(budget::MAX_TRIANGLES_MESH) + ".";
                return false;
            }
        }
    }
    if (faces.count() == 0) {
        error = label + " has no faces.";
        return false;
    }
    const std::string problem = coordinate_problem(label, read.positions, "OBJ");
    if (!problem.empty()) {
        error = problem;
        return false;
    }

    // Triangles.
    ObjTriangles built;
    size_t failed = 0;
    auto build = [&]() {
        const Built result = build_triangles(faces, read.positions, built, failed, deadline);
        if (result == Built::Late) {
            error = too_slow(label);
        }
        else if (result == Built::TooMany) {
            error = label + " has more than " + with_commas(budget::MAX_TRIANGLES_MESH) + " triangles; mesh bodies take up to " + with_commas(budget::MAX_TRIANGLES_MESH) + ".";
        }
        else if (result == Built::Tangled) {
            broken("the face on line " + with_commas(faces.line[failed]) + " has " + with_commas(faces.first[failed + 1] - faces.first[failed]) +
                   " corners and could not be split into triangles in time. Split it into smaller faces in the program that wrote the file.");
        }
        return result == Built::Done;
    };
    if (!build()) {
        return false;
    }
    // Faces without area (every corner on one line): left out, and counted. Kept, they would be
    // triangles without area, and their sides would close edges of the faces beside them that are
    // open in fact.
    uint64_t flat_faces = 0, flat_line = 0;
    {
        std::vector<uint8_t> drop(faces.count(), 1);
        MeshData probe;
        probe.positions.swap(read.positions);
        probe.triangles.swap(built.triangles);
        for (size_t t = 0; t < probe.triangle_count(); ++t) {
            if (drop[built.face[t]] && !without_area(probe, t)) {
                drop[built.face[t]] = 0;
            }
        }
        probe.positions.swap(read.positions);
        probe.triangles.swap(built.triangles);
        for (size_t f = 0; f < faces.count(); ++f) {
            if (drop[f] && flat_faces++ == 0) {
                flat_line = faces.line[f];
            }
        }
        if (flat_faces == faces.count()) {
            error = label + " has no faces with area: the corners of every face lie on one line.";
            return false;
        }
        if (flat_faces > 0) {
            faces = without_faces(faces, drop);
            if (!build()) {
                return false;
            }
        }
    }
    // Faces that meet others part-way along an edge (a T-junction): a side that is open while
    // the corners of other faces lie on it takes those corners, and its face is split again. On
    // it means within 1e-5 of the side's length (or float32's noise there, when more): the
    // numbers of a file written to six digits. Again for what the new sides find, three times at
    // most. What is left after that, or near a side (within 1 % of its length) but off it, is
    // counted for the warning.
    std::vector<OpenEdge> open;
    std::vector<uint8_t> paired, use;
    std::vector<OnEdge> on;
    uint64_t pairs = 0;
    bool checked = true;
    for (int pass = 0;; ++pass) {
        if (!open_edges(read.positions, built, open, deadline)) {
            error = too_slow(label);
            return false;
        }
        // (Edges written twice at the same places are not T-junctions: they are left to Stitch.)
        pairs = pair_repeated(read.positions, open, paired);
        use.assign(open.size(), 0);
        for (size_t i = 0; i < open.size(); ++i) {
            use[i] = paired[i] ? 0 : 1;
        }
        on.clear();
        if (open.empty()) {
            break;
        }
        checked = ends_on_edges(faces, read.positions, open, use, 1e-2, 1e-5, on, deadline);
        if (pass == 3 || !checked) {
            break;
        }
        std::vector<Splice> splices = splices_of(read.positions, open, on);
        if (splices.empty()) {
            break;
        }
        faces = spliced(faces, splices);
        if (!build()) {
            return false;
        }
    }
    uint64_t near_faces = 0;
    double near_off = 0.0;
    {
        std::vector<uint8_t> marked(faces.count(), 0);
        for (const OnEdge& o : on) {
            near_faces += marked[open[o.edge].face] ? 0 : 1;
            marked[open[o.edge].face] = 1;
            near_off = std::max(near_off, o.off);
        }
    }
    if (deadline.expired()) {
        error = too_slow(label);
        return false;
    }
    const size_t open_count = open.size();
    read.triangles.swap(built.triangles);
    read.groups.swap(built.groups);
    compact(read);
    const std::string invalid = validate(read);
    if (!invalid.empty()) {
        error = label + ": " + invalid;
        return false;
    }
    auto also = [&](const std::string& sentence) {
        if (!warning.empty()) {
            warning += "\n";
        }
        warning += sentence;
    };
    if (short_faces > 0) {
        also(label + ": " + plural(short_faces, "face with fewer than 3 corners was", "faces with fewer than 3 corners were") + " left out (the first is on line " +
             with_commas(short_line) + ").");
    }
    if (repeat_faces > 0) {
        also(label + ": " + plural(repeat_faces, "face names", "faces name") + " a corner twice in a row (or two corners at one place); the repeat was left out (the first is on line " +
             with_commas(repeat_line) + ").");
    }
    if (flat_faces > 0) {
        also(label + ": " + (flat_faces == 1 ? std::string("1 face has no area (its corners lie on one line) and was left out (line ") + with_commas(flat_line) + ")."
                                              : with_commas(flat_faces) + " faces have no area (their corners lie on one line) and were left out (the first is on line " +
                                                    with_commas(flat_line) + ")."));
    }
    if (built.folded_faces > 0) {
        also(label + ": " + plural(built.folded_faces, "face crosses itself or is folded flat", "faces cross themselves or are folded flat") +
             ", so their triangles may overlap (the first is on line " + with_commas(built.folded_line) + ").");
    }
    if (near_faces > 0) {
        also(label + ": " + (near_faces == 1 ? std::string("1 face has a corner of another face near one of its sides") : with_commas(near_faces) + " faces have corners of other faces near their sides") +
             " (up to " + length_text(near_off) + " off) without sharing it, so the mesh is open there. Join them in the program that wrote the file.");
    }
    if (pairs > 0) {
        also(label + ": " + plural(pairs, "edge lies", "edges lie") +
             " on another whose corners are written twice (the same places under other vertex numbers), so the mesh is open there; Stitch and Remove can join them.");
    }
    if (!checked) {
        also(label + ": the mesh has " + with_commas(open_count) + " open edges, too many to check them all for faces that meet others part-way along an edge.");
    }
    mesh = std::move(read);
    return true;
}

bool parse_obj(FileBytes file, const std::string& label, double scale, MeshData& mesh, std::string& error)
{
    std::string warning;
    return parse_obj(file, label, scale, mesh, error, warning);
}

}  // namespace holo_forge::mesh
