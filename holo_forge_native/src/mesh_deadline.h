#pragma once

// The time bound of the Mesh workspace's own loops (contract C5, layer 2): every loop the mesh
// code writes calls tick() once a round and stops when it answers true.

#include <algorithm>
#include <chrono>
#include <cstdint>

namespace holo_forge::mesh
{

class Deadline
{
public:
    explicit Deadline(double seconds) : start(std::chrono::steady_clock::now()), seconds(seconds)
    {
    }

    /// Seconds since the deadline was made.
    double elapsed() const
    {
        return std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    }
    double limit() const
    {
        return seconds;
    }
    double remaining() const
    {
        return seconds - elapsed();
    }
    /// Reads the clock. Once true it stays true.
    bool expired() const
    {
        if (!passed && elapsed() >= seconds) {
            passed = true;
        }
        return passed;
    }
    /// For loops: reads the clock every 4,096th call only.
    bool tick() const
    {
        if ((++calls & 4095u) == 0u) {
            return expired();
        }
        return passed;
    }

private:
    std::chrono::steady_clock::time_point start;
    double seconds;
    mutable uint32_t calls = 0;
    mutable bool passed = false;
};

/// options.time_limit as the ops read it: 20 s when missing or not a number, kept within
/// 0.05 .. 120 s (contract C4, ops).
inline double clamp_time_limit(double seconds, double fallback = 20.0)
{
    if (!(seconds == seconds)) {
        seconds = fallback;
    }
    return std::min(std::max(seconds, 0.05), 120.0);
}

}  // namespace holo_forge::mesh
