#pragma once

// A time bound for OCCT algorithms that take no progress range (its fillet and chamfer builder,
// ChFi3d), which can march for many minutes on spline bodies.

#include <functional>

namespace holo_forge::guard
{

/// Runs work on this thread, and stops it when it runs longer than seconds: from then on the next
/// call into OCCT's blend marching, root finding, blend approximation or face classification
/// throws (as if that function had failed at its start), which unwinds work like any other OCCT
/// failure. Nothing runs on another thread, so OCCT is never used from two threads at once.
/// Returns false when work was stopped; other exceptions from work pass through.
bool run_bounded(double seconds, const std::function<void()>& work);

/// How a guarded run ended.
enum class Outcome
{
    done,
    stopped,  // it ran longer than its seconds and was stopped, as run_bounded stops one
    crashed,  // a fault inside it (an access violation and the like) was caught
};

/// As run_bounded (no time bound when seconds is 0 or less), and a fault inside work is caught
/// instead of taking the process down: OCCT's offset reads through a null pointer on some bodies
/// (a block of flat facets with crossing holes, shelled: an access violation in its topology
/// library, in about half the runs), which no C++ catch sees. The fault is turned into a C++
/// exception where it happens and work is unwound like any other failure; what work had built
/// until then may be half made, so the caller must not use it (nor run its destructor: leak it).
/// Faults on other threads (OCCT's parallel meshing and booleans) are not caught.
Outcome run_guarded(double seconds, const std::function<void()>& work);

}  // namespace holo_forge::guard
