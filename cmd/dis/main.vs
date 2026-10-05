// dis prints the interpreter's instructions for a shader file:
//     vsc run dis -- vertex|fragment path.glsl
package main

import (
    "fs"
    "os/process"
    "shader"
    "shader/glsl"
    "shader/interp"
)

func main() -> int32 {
    let args = process.Args
    if args.count < 3 {
        print("usage: dis vertex|fragment file")
        return 2
    }
    let stage: shader.Stage = args[1] == "vertex" ? .vertex : .fragment
    guard let bytes = try? fs.ReadFile(fs.Path(args[2])) else {
        print("can't read \(args[2])")
        return 1
    }
    let r = glsl.Compile(string(decoding: bytes, as: UTF8.self), stage: stage)
    guard let m = r.Module else {
        print(r.Log)
        return 1
    }
    do {
        let e = try interp.Compile(m)
        print(e.Listing)
        print("slots: \(e.SlotCount), constants: \(e.Constants.count)")
    } catch {
        print("\(error)")
        return 1
    }
    return 0
}
