# shader/interp

Runs `shader.Module`s on the CPU: the reference every other backend must match, and how the CPU device shades.

```vertex
import "shader/interp"

let exe = try interp.Compile(module)
let m = interp.Machine(exe, lanes: 16, textures: myTextures)
m.Set(exe.FindUniform("mvp")!.Offset, all: bits)    // uniforms: every lane
let alive = m.Run(0xffff)                            // lanes not discarded
```

## Types

- **`Executable`** (class): A compiled stage: `Code`, `SlotCount`, each variable's `Offsets`, `Uniforms` (GL names: `a[2]`, `s.f`), `Inputs`, `Outputs`, and where the built-ins live (`Position`, `FragColor`, `FragCoord` …). `Listing` prints the instructions.
- **`Machine`** (class): Runs an executable on up to 64 lanes in lockstep. Slots are slot-major (`s * Lanes + lane`); `Get`/`Set`/`GetFloat`/`SetFloat` and `Slots` reach them.
- **`Textures`** (protocol), **`SampleRequest`** (class): Where lookups go: all lanes of one lookup at once, with coordinates, derivatives and bias or level, in buffers the machine owns.
- **`Instr`**, **`Op`**, **`Lookup`**: The instructions.
- **`Uniform`**, **`Interface`**, **`ConstantSlot`**: What an executable exposes.

Fragment lanes come in 2×2 quads: lanes 4q…4q+3 are (x, y), (x+1, y), (x, y+1), (x+1, y+1).

Part of the [`shader`](../README.md) repository.
