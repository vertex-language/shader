package main

import (
    "gpu"
    "shader"
    "shader/glsl"
    "shader/interp"
    "shader/msl"
)

var failures = 0

func check(_ ok: bool, _ what: string) {
    print(ok ? "ok    \(what)" : "FAIL  \(what)")
    if !ok { failures += 1 }
}

func compiles(_ src: string, _ stage: shader.Stage) -> shader.Module? {
    let r = glsl.Compile(src, stage: stage)
    if !r.Ok { print("      log: \(r.Log)") }
    return r.Module
}

func refuses(_ src: string, _ stage: shader.Stage, _ needle: string) -> bool {
    let r = glsl.Compile(src, stage: stage)
    if r.Ok { return false }
    if !r.Log.contains(needle) { print("      log: \(r.Log)") }
    return r.Log.contains(needle)
}

func main() -> int32 {
    let m = shader.Module(stage: .vertex)
    check(m.Slots(shader.DataType.Matrix(columns: 4, rows: 4)) == 16, "a mat4 is 16 slots")
    check(m.Slots(shader.DataType.Vector(.float, 3).ArrayOf(5)) == 15, "vec3[5] is 15 slots")

    let vs = """
    attribute vec4 position;
    attribute vec2 texCoords;
    uniform mat4 projection;
    uniform mat4 texture;
    varying vec2 outTexCoords;
    void main(void) {
        outTexCoords = (texture * vec4(texCoords, 0.0, 1.0)).st;
        gl_Position = projection * position;
    }
    """
    if let v = compiles(vs, .vertex) {
        check(v.VariablesIn(.input).map { $0.Name } == ["position", "texCoords"], "vertex: attributes are inputs")
        check(v.VariablesIn(.uniform).count == 2 && v.VariablesIn(.output).map { $0.Name } == ["outTexCoords"], "vertex: uniforms and a varying")
    } else {
        check(false, "a SurfaceFlinger-style vertex shader compiles")
    }
    let fs = """
    #extension GL_OES_EGL_image_external : require
    precision mediump float;
    uniform samplerExternalOES sampler;
    uniform vec4 color;
    uniform float alphaPlane;
    varying vec2 outTexCoords;
    #define SATURATE(x) clamp((x), 0.0, 1.0)
    void main(void) {
        vec4 texel = texture2D(sampler, outTexCoords);
        gl_FragColor.rgb = SATURATE(texel.rgb * color.a);
        gl_FragColor.a = alphaPlane < 0.5 ? texel.a * color.a : 1.0;
    #if defined(GL_ES) && __VERSION__ >= 100
        if (gl_FragColor.a < 0.01) discard;
    #else
        bogus;
    #endif
    }
    """
    if let f = compiles(fs, .fragment) {
        check(f.VariablesIn(.input).map { $0.Name } == ["outTexCoords"] && f.Discards, "fragment: an external sampler, macros, #if, discard")
    } else {
        check(false, "a SurfaceFlinger-style fragment shader compiles")
    }
    let es3 = """
    #version 300 es
    precision highp float;
    in vec2 uv;
    uniform sampler2D tex;
    uniform float weights[3];
    out vec4 color;
    float sum(in vec4 v) { return v.x + v.y + v.z + v.w; }
    void main() {
        vec4 acc = vec4(0.0);
        for (int i = 0; i < weights.length(); ++i) {
            acc += texture(tex, uv + vec2(float(i) * 0.01, 0.0)) * weights[i];
        }
        switch (int(sum(acc))) {
        case 0: acc.a = 1.0; break;
        default: break;
        }
        color = acc;
    }
    """
    if let m3 = compiles(es3, .fragment) {
        check(m3.Version == 300 && m3.VariablesIn(.output)[0].Location == 0, "3.00: in/out, loops, switch, .length(); the output at location 0")
    } else {
        check(false, "a GLSL ES 3.00 fragment shader compiles")
    }
    check(refuses("void main() { float x = 1; }", .vertex, "can't initialize a float with a int"), "no implicit int to float")
    check(refuses("uniform float u; void main() { u = 1.0; }", .vertex, "uniform u can't be written"), "uniforms are read-only")
    check(refuses("void main() { vec2 v; v.xx = vec2(1.0); }", .vertex, "repeat a component"), "a swizzle written can't repeat")
    check(refuses("void main() { gl_Position = vec4(1.0, 2.0); }", .vertex, "not enough values"), "constructors count components")
    check(refuses("void main() { foo(); }", .vertex, "'foo' is not a function"), "undeclared functions")
    check(refuses("void main() {", .vertex, "missing '}'"), "unterminated bodies")
    check(refuses("void f() {}", .vertex, "no main"), "main is required")
    let c = compiles("const int N = 2 * 3 + 1; uniform vec4 v[N]; void main() { gl_Position = v[N - 1]; }", .vertex)
    check(c?.VariablesIn(.uniform).first?.Type.ArrayCount == 7, "constant expressions size arrays")

    checkInterp()
    checkMetal()
    print(failures == 0 ? "all passed" : "\(failures) failed")
    return failures == 0 ? 0 : 1
}

func exe(_ src: string, _ stage: shader.Stage) -> interp.Executable? {
    guard let m = compiles(src, stage) else { return nil }
    do { return try interp.Compile(m) } catch { print("      interp: \(error)"); return nil }
}

func near(_ a: float32, _ b: float32) -> bool { abs(a - b) <= 1e-5 * max(1, abs(b)) }

func checkInterp() {
    // A vertex shader: a matrix times a vector, per lane.
    let vs = """
    attribute vec4 position;
    uniform mat4 mvp;
    varying vec2 uv;
    void main() {
        uv = position.xy * 0.5 + 0.5;
        gl_Position = mvp * position;
    }
    """
    if let e = exe(vs, .vertex) {
        let mach = interp.Machine(e, lanes: 4)
        let mvp = e.FindUniform("mvp")!
        // Scale by 2, translate x by 1 (column-major).
        let mat: [float32] = [2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 2, 0, 1, 0, 0, 1]
        for (k, v) in mat.enumerated() { mach.Set(mvp.Offset + k, all: v.bitPattern) }
        let pos = e.Inputs[0].Offset
        for l in 0..<4 {
            let x = float32(l)
            mach.SetFloat(pos, lane: l, x); mach.SetFloat(pos + 1, lane: l, -x); mach.SetFloat(pos + 2, lane: l, 0); mach.SetFloat(pos + 3, lane: l, 1)
        }
        _ = mach.Run(0b1111)
        var ok = true
        for l in 0..<4 {
            let x = float32(l)
            ok = ok && near(mach.GetFloat(e.Position, lane: l), 2 * x + 1) && near(mach.GetFloat(e.Position + 1, lane: l), -2 * x)
            ok = ok && near(mach.GetFloat(e.Outputs[0].Offset, lane: l), x * 0.5 + 0.5)
        }
        check(ok, "interp: mat4 * vec4 and a varying, four lanes")
    } else {
        check(false, "interp: the vertex shader compiles")
    }
    // Control flow that differs between lanes: loops, break, functions, out parameters, discard.
    let fs = """
    precision highp float;
    varying float v;
    float twice(float x, out float half) { half = x * 0.5; if (x > 2.0) { return x * 2.0; } return x; }
    void main() {
        float acc = 0.0;
        for (int i = 0; i < 10; i++) {
            if (float(i) >= v) break;
            if (i == 1) continue;
            acc += float(i);
        }
        float h;
        float t = twice(v, h);
        if (v > 5.5) discard;
        gl_FragColor = vec4(acc, t, h, v < 1.0 ? 1.0 : 0.0);
    }
    """
    if let e = exe(fs, .fragment) {
        let mach = interp.Machine(e, lanes: 8)
        let vin = e.Inputs[0].Offset
        for l in 0..<8 { mach.SetFloat(vin, lane: l, float32(l)) }
        let alive = mach.Run(0xff)
        var ok = alive == 0b0011_1111
        for l in 0..<6 {
            let v = float32(l)
            var acc: float32 = 0
            for i in 0..<10 { if float32(i) >= v { break }; if i == 1 { continue }; acc += float32(i) }
            let t = v > 2 ? v * 2 : v
            let c = e.FragColor
            ok = ok && near(mach.GetFloat(c, lane: l), acc) && near(mach.GetFloat(c + 1, lane: l), t)
            ok = ok && near(mach.GetFloat(c + 2, lane: l), v * 0.5) && near(mach.GetFloat(c + 3, lane: l), v < 1 ? 1 : 0)
        }
        check(ok, "interp: per-lane loops, break, continue, inlined calls with out, discard (alive \(alive))")
    } else {
        check(false, "interp: the fragment shader compiles")
    }
    // Derivatives across a quad.
    let ds = """
    #extension GL_OES_standard_derivatives : enable
    precision highp float;
    varying vec2 p;
    void main() { gl_FragColor = vec4(dFdx(p.x * p.x), dFdy(p.y * 3.0), fwidth(p.x), 0.0); }
    """
    if let e = exe(ds, .fragment) {
        let mach = interp.Machine(e, lanes: 4)
        let pin = e.Inputs[0].Offset
        let xs: [float32] = [1, 2, 1, 2]
        let ys: [float32] = [5, 5, 6, 6]
        for l in 0..<4 { mach.SetFloat(pin, lane: l, xs[l]); mach.SetFloat(pin + 1, lane: l, ys[l]) }
        _ = mach.Run(0xf)
        let c = e.FragColor
        check(near(mach.GetFloat(c, lane: 0), 3) && near(mach.GetFloat(c + 1, lane: 3), 3) && near(mach.GetFloat(c + 2, lane: 2), 1),
              "interp: dFdx, dFdy and fwidth across a quad")
    } else {
        check(false, "interp: the derivative shader compiles")
    }
    // GLSL ES 3.00: integers, switch, arrays indexed at run time, matrices.
    let es3 = """
    #version 300 es
    precision highp float;
    in float v;
    out vec4 color;
    uniform float table[4];
    void main() {
        int k = int(v);
        float r = 0.0;
        switch (k) {
        case 0: r = 10.0;
        case 1: r += 1.0; break;
        case 2: r = 20.0; break;
        default: r = -1.0;
        }
        mat2 m = mat2(1.0, 2.0, 3.0, 4.0);
        mat2 mi = inverse(m);
        vec2 q = mi * (m * vec2(1.0, 1.0));
        color = vec4(r, table[k & 3], q.x + q.y, float(k << 2 | 1));
    }
    """
    if let e = exe(es3, .fragment) {
        let mach = interp.Machine(e, lanes: 4)
        let t = e.FindUniform("table[0]")!
        for k in 0..<4 { mach.Set(t.Offset + k, all: float32(100 + k).bitPattern) }
        for l in 0..<4 { mach.SetFloat(e.Inputs[0].Offset, lane: l, float32(l)) }
        _ = mach.Run(0xf)
        let o = e.Outputs[0].Offset
        let rs: [float32] = [11, 1, 20, -1]
        var ok = t.ArraySize == 4
        for l in 0..<4 {
            ok = ok && near(mach.GetFloat(o, lane: l), rs[l]) && near(mach.GetFloat(o + 1, lane: l), float32(100 + l))
            ok = ok && near(mach.GetFloat(o + 2, lane: l), 2) && near(mach.GetFloat(o + 3, lane: l), float32(l << 2 | 1))
        }
        check(ok, "interp: 3.00 switch with fallthrough, run-time array index, inverse, shifts")
    } else {
        check(false, "interp: the 3.00 shader compiles")
    }
}

/// shader/msl: shaders printed as Metal source, compiled by the Metal driver.
func checkMetal() {
    let d = gpu.Default()
    if d.IsCPU {
        print("ok    msl: no Metal device here; skipped")
        return
    }
    let shaders: [(string, shader.Stage)] = [
        ("attribute vec4 position; attribute vec2 tc; uniform mat4 mvp; uniform mat4 tm; varying vec2 v; void main() { v = (tm * vec4(tc, 0.0, 1.0)).st; gl_Position = mvp * position; gl_PointSize = 2.0; }", .vertex),
        ("#extension GL_OES_EGL_image_external : require\nprecision mediump float; uniform samplerExternalOES s; uniform vec4 color; varying vec2 v; void main() { vec4 t = texture2D(s, v); if (t.a < 0.01) discard; gl_FragColor = t * color.a; }", .fragment),
        ("#extension GL_OES_standard_derivatives : enable\nprecision highp float; varying vec2 v; uniform float k[3]; struct L { vec3 dir; float w; }; uniform L lights[2]; float f(inout float x, out vec2 y) { x += 1.0; y = vec2(x); return mod(x, 2.0); } void main() { float a = 0.0; vec2 b; for (int i = 0; i < 3; i++) { if (k[i] > 1.0) continue; a += f(a, b); } mat3 m = mat3(vec3(1.0), vec2(0.5), 0.0, 1.0, 1.0, 0.0); gl_FragColor = vec4(m * lights[1].dir, fwidth(v.x) + dFdy(v.y) + a + b.x + lights[0].w); }", .fragment),
        ("#version 300 es\nprecision highp float; in vec2 uv; uniform sampler2D tex; uniform highp int n; out vec4 color; void main() { ivec2 s = textureSize(tex, 0); vec4 acc = vec4(0.0); switch (n) { case 0: acc = texelFetch(tex, ivec2(uv * vec2(s)), 0); break; default: acc = textureLod(tex, uv, 1.0); } color = acc + vec4(inverse(mat2(1.0, 2.0, 3.0, 4.0))[0], 0.0, float(n >> 1)); }", .fragment),
    ]
    for (i, pair) in shaders.enumerated() {
        guard let m = compiles(pair.0, pair.1) else { check(false, "msl: shader \(i) compiles as GLSL"); continue }
        do {
            let exe = try interp.Compile(m)
            var attrs: [int: int] = [:]
            for (k, v) in m.Variables.enumerated() where v.Storage == .input && pair.1 == .vertex { attrs[k] = k }
            let src = try msl.Translate(m, offsets: exe.Offsets, attributes: attrs)
            do {
                let lib = try gpu.Library(device: d, source: src.Text)
                _ = try lib.Function(src.Entry)
                check(true, "msl: shader \(i) compiles for Metal (\(src.Samplers.count) samplers)")
            } catch let e as gpu.RenderError {
                print(src.Text)
                check(false, "msl: shader \(i) compiles for Metal: \(e)")
            }
        } catch {
            check(false, "msl: shader \(i): \(error)")
        }
    }
}
