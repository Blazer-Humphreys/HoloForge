// Holo Forge shim for FreeCAD's Base/Console.h: planegcs only logs debug text, which we drop.
#pragma once

namespace Base
{
struct ConsoleShim
{
    template<typename... Args>
    void log(Args&&...)
    {}
    template<typename... Args>
    void warning(Args&&...)
    {}
    template<typename... Args>
    void error(Args&&...)
    {}
    template<typename... Args>
    void message(Args&&...)
    {}
};

inline ConsoleShim& Console()
{
    static ConsoleShim console;
    return console;
}
}  // namespace Base
