#include "occt_guard.h"

// Built with /EHa (CMakeLists.txt): the stop arrives as a structured exception that a C++
// exception is made from, and so does a fault inside the work (run_guarded).

#ifdef _WIN32

#include <windows.h>
#include <eh.h>
#include <malloc.h>

#include <chrono>
#include <condition_variable>
#include <exception>
#include <mutex>
#include <thread>

namespace holo_forge::guard
{
namespace
{

/// What a stopped run throws: not an OCCT exception, so OCCT's own catch blocks (which catch
/// Standard_Failure and carry on) let it through.
struct Stopped
{
};

/// The functions a run is stopped at: OCCT's blend marching and approximation call them all the
/// time, and each can fail at its start like any OCCT function (it throws), so stopping there
/// leaves OCCT's state as one of its own failures does.
struct Targets
{
    void* at[4] = {nullptr, nullptr, nullptr, nullptr};
    int count = 0;
};

const Targets& targets()
{
    static const Targets found = [] {
        Targets t;
        const struct
        {
            const wchar_t* module;
            const char* name;
        } wanted[] = {
            // math_FunctionSetRoot::Perform (with bounds): every marching step and approximation point.
            {L"TKMath.dll", "?Perform@math_FunctionSetRoot@@QEAAXAEAVmath_FunctionSetWithDerivatives@@AEBV?$math_VectorBase@N@@11_N@Z"},
            // math_FunctionSetRoot::Perform (without bounds).
            {L"TKMath.dll", "?Perform@math_FunctionSetRoot@@QEAAXAEAVmath_FunctionSetWithDerivatives@@AEBV?$math_VectorBase@N@@_N@Z"},
            // BRepBlend_AppFuncRoot::D0: the blend surface's approximation.
            {L"TKFillet.dll", "?D0@BRepBlend_AppFuncRoot@@UEAA_NNNNAEAV?$NCollection_Array1@Vgp_Pnt@@@@AEAV?$NCollection_Array1@Vgp_Pnt2d@@@@AEAV?$NCollection_Array1@N@@@Z"},
            // BRepTopAdaptor_TopolTool::Classify: whether a marching point is still on its face.
            {L"TKTopAlgo.dll", "?Classify@BRepTopAdaptor_TopolTool@@UEAA?AW4TopAbs_State@@AEBVgp_Pnt2d@@N_N@Z"},
        };
        for (const auto& w : wanted) {
            const HMODULE module = GetModuleHandleW(w.module);
            void* at = module ? reinterpret_cast<void*>(GetProcAddress(module, w.name)) : nullptr;
            if (at) {
                t.at[t.count++] = at;
            }
        }
        return t;
    }();
    return found;
}

/// Sets (or clears) hardware execution breakpoints on the targets in thread, which is suspended
/// meanwhile. Allocates nothing while it is (thread may hold the heap's lock).
bool set_breakpoints(HANDLE thread, const Targets& t, bool on)
{
    if (SuspendThread(thread) == DWORD(-1)) {
        return false;
    }
    alignas(16) CONTEXT context = {};
    context.ContextFlags = CONTEXT_DEBUG_REGISTERS;
    bool ok = GetThreadContext(thread, &context) != 0;
    if (ok) {
        DWORD64* slots[4] = {&context.Dr0, &context.Dr1, &context.Dr2, &context.Dr3};
        DWORD64 enable = 0;
        for (int i = 0; i < 4; ++i) {
            *slots[i] = on && i < t.count ? DWORD64(reinterpret_cast<uintptr_t>(t.at[i])) : 0;
            if (on && i < t.count) {
                // Local enable; condition 00 (execution) and length 00 (bits 16 + 4i up) stay clear.
                enable |= DWORD64(1) << (2 * i);
            }
        }
        context.Dr6 = 0;
        context.Dr7 = enable;
        ok = SetThreadContext(thread, &context) != 0;
    }
    ResumeThread(thread);
    return ok;
}

/// What a run that faulted throws (run_guarded): not an OCCT exception either.
struct Crashed
{
    unsigned int code;
};

thread_local bool t_watched = false;
thread_local bool t_faults_caught = false;
thread_local _se_translator_function t_previous = nullptr;

/// The structured exceptions that are a fault in the code that ran (not a debugger's, not a
/// C++ exception's, which never comes here).
bool is_fault(unsigned int code)
{
    switch (code) {
        case EXCEPTION_ACCESS_VIOLATION:
        case EXCEPTION_IN_PAGE_ERROR:
        case EXCEPTION_ARRAY_BOUNDS_EXCEEDED:
        case EXCEPTION_ILLEGAL_INSTRUCTION:
        case EXCEPTION_PRIV_INSTRUCTION:
        case EXCEPTION_INT_DIVIDE_BY_ZERO:
        case EXCEPTION_INT_OVERFLOW:
        case EXCEPTION_FLT_DIVIDE_BY_ZERO:
        case EXCEPTION_FLT_INVALID_OPERATION:
        case EXCEPTION_FLT_OVERFLOW:
        case EXCEPTION_FLT_STACK_CHECK:
        case EXCEPTION_STACK_OVERFLOW:
            return true;
        default:
            return false;
    }
}

/// One of the breakpoints was reached on a watched thread: stop there. A fault on a thread whose
/// faults are caught: unwind from there. Anything else goes on to whoever translated structured
/// exceptions before.
void translate(unsigned int code, EXCEPTION_POINTERS* info)
{
    if (code == EXCEPTION_SINGLE_STEP && t_watched && info != nullptr && info->ContextRecord != nullptr && (info->ContextRecord->Dr6 & 0xF) != 0) {
        throw Stopped();
    }
    if (t_faults_caught && is_fault(code)) {
        throw Crashed{code};
    }
    if (t_previous != nullptr) {
        t_previous(code, info);
    }
}

/// work run with a time bound (seconds above 0, where the targets were found) and, when asked,
/// its faults caught.
Outcome run(double seconds, const std::function<void()>& work, bool catch_faults)
{
    const Targets& t = targets();
    HANDLE self = nullptr;
    const bool watched = seconds > 0.0 && t.count > 0 &&
                         DuplicateHandle(GetCurrentProcess(), GetCurrentThread(), GetCurrentProcess(), &self,
                                         THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_SET_CONTEXT | THREAD_QUERY_INFORMATION, FALSE, 0);
    if (!watched && !catch_faults) {
        // (Can't be watched: runs unbounded, as before.)
        work();
        return Outcome::done;
    }
    std::mutex lock;
    std::condition_variable changed;
    bool done = false;
    std::thread watch;
    if (watched) {
        watch = std::thread([&] {
            std::unique_lock<std::mutex> held(lock);
            bool armed = false;
            if (!changed.wait_for(held, std::chrono::duration<double>(seconds), [&] { return done; })) {
                armed = set_breakpoints(self, t, true);
                changed.wait(held, [&] { return done; });
            }
            if (armed) {
                set_breakpoints(self, t, false);
            }
        });
    }
    const bool was_watched = t_watched;
    const bool was_caught = t_faults_caught;
    const _se_translator_function was_previous = t_previous;
    const _se_translator_function before = _set_se_translator(translate);
    if (before != translate) {
        t_previous = before;
    }
    t_watched = watched || was_watched;
    t_faults_caught = catch_faults || was_caught;
    Outcome outcome = Outcome::done;
    std::exception_ptr failure;
    try {
        work();
    }
    catch (const Stopped&) {
        outcome = Outcome::stopped;
    }
    catch (const Crashed& crash) {
        if (catch_faults) {
            outcome = Outcome::crashed;
            if (crash.code == EXCEPTION_STACK_OVERFLOW) {
                // (The guard page is put back, or the next overflow can't be caught.)
                _resetstkoflw();
            }
        }
        else {
            failure = std::current_exception();
        }
    }
    catch (...) {
        failure = std::current_exception();
    }
    // (No OCCT is called from here until the breakpoints are cleared, so none can be reached.)
    _set_se_translator(before);
    t_watched = was_watched;
    t_faults_caught = was_caught;
    t_previous = was_previous;
    if (watched) {
        {
            std::lock_guard<std::mutex> held(lock);
            done = true;
        }
        changed.notify_all();
        watch.join();
        CloseHandle(self);
    }
    if (failure) {
        std::rethrow_exception(failure);
    }
    return outcome;
}

}  // namespace

bool run_bounded(double seconds, const std::function<void()>& work)
{
    return run(seconds, work, false) != Outcome::stopped;
}

Outcome run_guarded(double seconds, const std::function<void()>& work)
{
    return run(seconds, work, true);
}

}  // namespace holo_forge::guard

#else

namespace holo_forge::guard
{

bool run_bounded(double, const std::function<void()>& work)
{
    work();
    return true;
}

Outcome run_guarded(double, const std::function<void()>& work)
{
    work();
    return Outcome::done;
}

}  // namespace holo_forge::guard

#endif
