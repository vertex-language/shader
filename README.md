# shader

[![package: vs-package](https://img.shields.io/badge/package-vs--package-f4f4f5?style=flat-square&labelColor=e4e4e7&color=18181b)](https://github.com/vertex-language)

Shaders compiled while a program runs. A guest's `glShaderSource`, a web page's WebGL, a material editor: each hands over source text at run time, which `vsc`'s ahead-of-time `.vs` kernels can't help with. This is the runtime compiler, in Vertex: front ends lower source to one small IR, and backends run it.

---

## Quick Start

```bash
vsc run check                                   # the front end, then the interpreter running real shaders
vsc run dis -- fragment path/to/shader.frag    # the interpreter's instructions for a shader
```

---

## Packages

| Package | What it is |
| --- | --- |
| **`shader`** | The IR. A `Module` lists every `Variable` (inputs, outputs, uniforms, globals, function locals and parameters: shader languages have no recursion, so each has one fixed place), its `StructType`s and `FunctionDef`s; code is `Stmt` and typed `Expr` trees with structured control flow. `DataType` (scalars, vectors, matrices, samplers, structs, arrays), `Function` (the built-ins), `Limits` (what `gl_Max…` and the API report) |
| **`shader/glsl`** | GLSL ES **1.00** (OpenGL ES 2.0, WebGL 1) and **3.00** (OpenGL ES 3.0, WebGL 2) → `shader`. A preprocessor (macros with arguments, `#if` with `defined`, `#extension`, `#version`), then one pass that parses and type-checks (GLSL declares before use): overloads, constructors, swizzles, constant folding for array sizes and `const`, every built-in function and texture lookup, lvalue rules. Errors read as `glGetShaderInfoLog` shows them: `ERROR: 0:<line>: <message>` |
| **`shader/interp`** | Runs a module on the CPU: the reference every other backend must match. It compiles to instructions over slots and runs up to 64 invocations in lockstep with lane masks for `if`, loops, `break`, `continue`, `return` and `discard`; functions are inlined. Fragments run as 2×2 quads, so `dFdx`, `dFdy` and texture levels of detail are exact. Lookups go through `Textures` (implemented by `gpu/raster`) |

| **`shader/msl`** | Prints a module as Metal source, which the driver compiles through the built-in `gpu` (`gpu.Library`). Uniforms are read from the interpreter's slots (buffer 30), so one set of uniform values serves both; per-draw constants (the flip, the target's height) are in buffer 29. Varyings are matched by name. `gl_FragCoord`, `dFdy` and clip z are adjusted to Metal's conventions. What it can't print yet (3D textures, sampler arrays, shadow samplers on the GPU) is refused with a `TranslateError`, and `gpu/raster` draws those on the CPU |

Planned: `shader/wgsl` (WebGPU), `shader/ptx`.

---

## Why not VIR

`ir` and its lowerings are the toolchain: Go, run by `vsc` at build time. A runtime shader needs a compiler linked into the program. The `shader` IR stays the shape of shader languages (no generics, protocols or heap), so its backends stay short.

---

## Testing

`cmd/check` compiles shaders shaped like Android's compositor and UI and a GLSL ES 3.00 one, refuses invalid ones with GL-style logs, and runs the interpreter on lanes whose control flow differs: loops with `break` and `continue`, inlined functions with `out` parameters, `discard`, quad derivatives, `switch` fall-through, run-time array indices and matrix inverses, against values computed on the host. Android 8's SurfaceFlinger and UI shaders run through it in `vm`.
