# Holo Forge license

MIT License

Copyright (c) 2026 Holo

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## What this covers

This covers Holo Forge's own files: the GDScript, shaders, icons, the C++ source of the native library and `bin/holo_forge_native.dll`. A game you export may include Holo Forge's scripts (baked parts use `nodes/cad_part.gd`); the MIT license only asks that you keep this notice with them, for example in your game's credits or license file.

It does not cover the third-party libraries in `bin/`, which keep their own licenses (see `THIRD_PARTY_NOTICES.md` and `licenses/`). In particular, OpenCASCADE (`TK*.dll`) and planegcs (`planegcs.dll`) are under the GNU Lesser General Public License 2.1. They are used by the editor only and are left out of game exports. You may replace those DLLs with versions you build or change yourself. Nothing in this license limits the rights the LGPL gives you.
