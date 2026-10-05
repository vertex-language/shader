# shader/glsl

Compiles GLSL ES source to a `shader.Module`: version 1.00 (OpenGL ES 2.0, WebGL 1) and 3.00 (OpenGL ES 3.0, WebGL 2).

```vertex
import "shader/glsl"

let r = glsl.Compile(source, stage: .fragment)
if let m = r.Module { … } else { print(r.Log) }   // "ERROR: 0:3: …"
```

## Functions

- `func Compile(_ source: string, stage: shader.Stage) -> Result`: Compile is the source's module, or why not. The version is the source's `#version` line (1.00 without one).

## Types

- **`Result`** (struct): `Module` or `Log`, as `glGetShaderInfoLog` shows it.
- **`CompileError`** (struct): A problem at a line.

## Values

- `SupportedExtensions`: `GL_OES_standard_derivatives`, `GL_OES_EGL_image_external` (and its ESSL 3 form), `GL_EXT_shader_texture_lod`, `GL_EXT_frag_depth`; each is also a macro defined to 1.

Not yet: uniform blocks and interface blocks (3.00), `invariant` beyond accepting it, the `#line` directive's numbering.

Part of the [`shader`](../README.md) repository.
