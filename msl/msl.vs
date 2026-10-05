// Package msl prints a shader module as Metal Shading Language source,
// which the Metal driver compiles while the program runs (through the
// built-in gpu's Library). It is how a GPU runs shaders that arrive as
// GLSL at run time.
//
// The printed program follows the interpreter's layout, so callers keep
// one copy of their state for both: uniforms are read from a buffer of
// 32-bit slots at the interpreter's offsets (buffer 30), and a sampler
// variable's texture and sampler sit at its sampler index. Per-draw
// constants in buffer 29 say how the target is oriented: GL's window
// coordinates have y up, Metal's y down.
package msl

import (
    "shader"
)

/// TranslateError is a module this printer can't express in Metal yet.
public struct TranslateError: Error {
    public let Message: string

    public init(_ message: string) {
        Message = message
    }
}

/// One sampler variable: the texture and sampler slot it is bound at.
public struct SamplerSlot {
    /// Module.Variables index.
    public let Variable: int
    /// texture(Slot) and sampler(Slot).
    public let Slot: int
    public let Kind: shader.SamplerKind

    public init(variable: int, slot: int, kind: shader.SamplerKind) {
        Variable = variable
        Slot = slot
        Kind = kind
    }
}

/// A printed stage.
public struct Source {
    public let Text: string
    /// The entry point's name.
    public let Entry: string
    public let Samplers: [SamplerSlot]
}

/// Where the per-draw constants and uniform slots are bound.
public let ConstantsBuffer = 29
public let UniformBuffer = 30

/// The per-draw constants buffer 29 holds, as floats: flip (1 for a target
/// stored top row first, as a window; -1 for one stored bottom row first,
/// as GL textures), the target's height, and dFdy's sign.
public let ConstantsCount = 4

/// Prints `m`. `offsets` are each variable's first uniform slot (the
/// interpreter's Executable.Offsets); `attributes` each vertex input's
/// attribute location, by Module.Variables index (vertex stage only).
public func Translate(_ m: shader.Module, offsets: [int], attributes: [int: int]) throws -> Source {
    let p = Printer(m, offsets: offsets, attributes: attributes)
    return try p.run()
}

final class Printer {
    let m: shader.Module
    let offsets: [int]
    let attributes: [int: int]
    var out = ""
    var helpers: [string] = []
    var helperNames: [string] = []
    var samplers: [SamplerSlot] = []
    var indent = 1
    let vertex: bool

    init(_ m: shader.Module, offsets: [int], attributes: [int: int]) {
        self.m = m
        self.offsets = offsets
        self.attributes = attributes
        vertex = m.Stage == .vertex
    }

    // MARK: names and types

    func name(_ v: shader.Variable) -> string {
        if case .builtin = v.Storage { return "G.\(builtinName(v))" }
        let n = "v\(v.Index)_\(clean(v.Name))"
        switch v.Storage {
        case .local: return n
        case .constant: return "c\(v.Index)_\(clean(v.Name))"
        default: return "G.\(n)"
        }
    }

    func fieldName(_ v: shader.Variable) -> string {
        if case .builtin = v.Storage { return builtinName(v) }
        return "v\(v.Index)_\(clean(v.Name))"
    }

    func builtinName(_ v: shader.Variable) -> string {
        guard case .builtin(let b) = v.Storage else { return v.Name }
        switch b {
        case .position: return "b_position"
        case .pointSize: return "b_pointSize"
        case .vertexId: return "b_vertexId"
        case .instanceId: return "b_instanceId"
        case .fragCoord: return "b_fragCoord"
        case .frontFacing: return "b_frontFacing"
        case .pointCoord: return "b_pointCoord"
        case .fragColor: return "b_fragColor"
        case .fragData: return "b_fragData"
        case .fragDepth: return "b_fragDepth"
        case .depthRangeNear: return "b_depthNear"
        case .depthRangeFar: return "b_depthFar"
        }
    }

    /// Letters, digits and underscores only.
    func clean(_ s: string) -> string {
        var b: [uint8] = []
        for c in s.utf8 {
            if (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c == 0x5f { b.append(c) } else { b.append(0x5f) }
        }
        return string(decoding: b, as: UTF8.self)
    }

    func scalarName(_ k: shader.Kind) -> string {
        switch k {
        case .bool: return "bool"
        case .int: return "int"
        case .uint: return "uint"
        case .float: return "float"
        default: return "void"
        }
    }

    /// One element's Metal type (no array).
    func elemType(_ t: shader.DataType) throws -> string {
        switch t.Kind {
        case .void: return "void"
        case .structure(let s): return "S\(s)"
        case .sampler: throw TranslateError("a sampler as a value")
        default:
            let s = scalarName(t.Kind)
            if t.Columns > 1 { return "float\(t.Columns)x\(t.Rows)" }
            if t.Rows > 1 { return "\(s)\(t.Rows)" }
            return s
        }
    }

    func type(_ t: shader.DataType) throws -> string {
        let e = try elemType(t)
        return t.IsArray ? "garray<\(e), \(t.ArrayCount)>" : e
    }

    // MARK: the program

    func line(_ s: string) {
        out += string(repeating: "    ", count: indent) + s + "\n"
    }

    func run() throws -> Source {
        // Samplers first: their slots.
        for v in m.Variables where v.Type.IsSampler && v.Storage == .uniform {
            if v.Type.IsArray { throw TranslateError("arrays of samplers") }
            guard case .sampler(let k) = v.Type.Kind else { continue }
            samplers.append(SamplerSlot(variable: v.Index, slot: samplers.count, kind: k))
        }
        var head = "#include <metal_stdlib>\nusing namespace metal;\n\n"
        // GLSL's arrays are values: copied, assigned, compared.
        head += "template <typename T, int N> struct garray {\n    T v[N];\n"
        head += "    thread T& operator[](int i) thread { return v[i]; }\n"
        head += "    const thread T& operator[](int i) const thread { return v[i]; }\n"
        head += "    const constant T& operator[](int i) const constant { return v[i]; }\n};\n\n"
        // Structs.
        for (i, st) in m.Structs.enumerated() {
            head += "struct S\(i) {\n"
            for (k, f) in st.Fields.enumerated() { head += "    \(try type(f.Type)) f\(k);\n" }
            head += "};\n"
        }
        head += "struct K { float flip; float height; float dfdySign; float pad; };\n\n"
        // Every global, in one struct.
        head += "struct Globals {\n"
        for v in m.Variables {
            if v.Storage == .local || v.Storage == .constant { continue }
            if v.Type.IsSampler { continue }
            head += "    \(try type(v.Type)) \(fieldName(v));\n"
        }
        head += "    float dfdySign;\n};\n\n"
        // Textures and samplers can't be assigned, so they travel in a
        // struct of their own, made once in the entry point.
        head += "struct Tex {\n"
        for slot in samplers { head += "    \(textureType(slot.Kind)) t\(slot.Slot);\n    sampler s\(slot.Slot);\n" }
        if samplers.isEmpty { head += "    int none;\n" }
        head += "};\n\n"
        // Constants are globals too, with their values.
        var consts = ""
        for v in m.Variables where v.Storage == .constant && !v.Value.isEmpty {
            consts += "constant \(try type(v.Type)) c\(v.Index)_\(clean(v.Name)) = \(try constant(v.Type, v.Value));\n"
        }
        // Functions: prototypes, then bodies.
        var protos = ""
        var bodies = ""
        for (k, f) in m.Functions.enumerated() where f.Defined {
            let sig = try signature(k, f)
            protos += sig + ";\n"
            out = ""
            indent = 1
            try stmts(f.Body)
            bodies += sig + " {\n" + out + "}\n\n"
        }
        out = ""
        indent = 1
        let entry = try entryPoint()
        let text = head + consts + "\n" + helpers.joined(separator: "\n") + "\n" + protos + "\n" + bodies + entry
        return Source(Text: text, Entry: vertex ? "vmain" : "fmain", Samplers: samplers)
    }

    func textureType(_ k: shader.SamplerKind) -> string {
        switch k {
        case .cube: return "texturecube<float>"
        case .texture3D: return "texture3d<float>"
        case .array2D: return "texture2d_array<float>"
        case .shadow2D: return "depth2d<float>"
        case .shadowCube: return "depthcube<float>"
        case .shadowArray2D: return "depth2d_array<float>"
        case .itexture2D: return "texture2d<int>"
        case .utexture2D: return "texture2d<uint>"
        default: return "texture2d<float>"
        }
    }

    func signature(_ k: int, _ f: shader.FunctionDef) throws -> string {
        var params = ["thread Globals& G", "thread Tex& T"]
        for (i, p) in f.Params.enumerated() {
            let v = m.Variables[p]
            if v.Type.IsSampler { throw TranslateError("a sampler as a function parameter") }
            let t = try type(v.Type)
            params.append(f.Out[i] ? "thread \(t)& \(name(v))" : "\(t) \(name(v))")
        }
        return "static \(try type(f.Result)) f\(k)_\(clean(f.Name))(\(params.joined(separator: ", ")))"
    }

    // MARK: the entry point

    func entryPoint() throws -> string {
        var s = ""
        let outputs = m.Variables.filter { $0.Storage == .output }
        let inputs = m.Variables.filter { $0.Storage == .input }
        if vertex {
            s += "struct VIn {\n"
            for v in inputs {
                guard let loc = attributes[v.Index] else { throw TranslateError("no attribute location for \(v.Name)") }
                if v.Type.IsMatrix {
                    for c in 0..<v.Type.Columns { s += "    float\(v.Type.Rows) a\(v.Index)_\(c) [[attribute(\(loc + c))]];\n" }
                } else if v.Type.IsArray {
                    throw TranslateError("an array attribute")
                } else {
                    s += "    \(try type(v.Type)) a\(v.Index) [[attribute(\(loc))]];\n"
                }
            }
            s += "};\nstruct VOut {\n    float4 position [[position]];\n"
            if m.Variables.contains(where: { isBuiltin($0, .pointSize) }) { s += "    float pointSize [[point_size]];\n" }
            for v in outputs { s += try varying(v) }
            s += "};\n\n"
            s += "vertex VOut vmain(VIn in [[stage_in]], constant uint* U [[buffer(30)]], constant K& k [[buffer(29)]],\n"
            s += "                  uint vid [[vertex_id]], uint iid [[instance_id]]\(textureParams())) {\n"
            s += "    Globals G;\n    G.dfdySign = k.dfdySign;\n"
            for v in inputs {
                if v.Type.IsMatrix {
                    var cols: [string] = []
                    for c in 0..<v.Type.Columns { cols.append("in.a\(v.Index)_\(c)") }
                    s += "    \(name(v)) = \(try type(v.Type))(\(cols.joined(separator: ", ")));\n"
                } else {
                    s += "    \(name(v)) = in.a\(v.Index);\n"
                }
            }
            for v in m.Variables where isBuiltin(v, .vertexId) { s += "    \(name(v)) = int(vid);\n" }
            for v in m.Variables where isBuiltin(v, .instanceId) { s += "    \(name(v)) = int(iid);\n" }
            for v in m.Variables where isBuiltin(v, .pointSize) { s += "    \(name(v)) = 1.0;\n" }
            for v in m.Variables where isBuiltin(v, .position) { s += "    \(name(v)) = float4(0.0);\n" }
        } else {
            s += "struct FIn {\n    float4 position [[position]];\n"
            for v in inputs { s += try varying(v) }
            s += "};\nstruct FOut {\n    float4 color [[color(0)]];\n"
            if m.WritesDepth { s += "    float depth [[depth(any)]];\n" }
            s += "};\n\n"
            s += "fragment FOut fmain(FIn in [[stage_in]], constant uint* U [[buffer(30)]], constant K& k [[buffer(29)]],\n"
            s += "                    bool front [[front_facing]], float2 pointCoord [[point_coord]]\(textureParams())) {\n"
            s += "    Globals G;\n    G.dfdySign = k.dfdySign;\n"
            for v in inputs { s += "    \(name(v)) = in.\(fieldName(v));\n" }
            for v in m.Variables {
                if isBuiltin(v, .fragCoord) {
                    // GL's window y is up: a target stored top row first counts from its bottom.
                    s += "    \(name(v)) = float4(in.position.x, k.flip > 0.0 ? k.height - in.position.y : in.position.y, in.position.z, in.position.w);\n"
                }
                if isBuiltin(v, .frontFacing) { s += "    \(name(v)) = front;\n" }
                if isBuiltin(v, .pointCoord) { s += "    \(name(v)) = pointCoord;\n" }
                if isBuiltin(v, .fragDepth) { s += "    \(name(v)) = in.position.z;\n" }
                if isBuiltin(v, .fragColor) { s += "    \(name(v)) = float4(0.0);\n" }
            }
        }
        // Samplers and uniforms.
        var texArgs: [string] = []
        for slot in samplers { texArgs += ["t\(slot.Slot)", "s\(slot.Slot)"] }
        if texArgs.isEmpty { texArgs = ["0"] }
        s += "    Tex T{\(texArgs.joined(separator: ", "))};\n"
        for v in m.Variables where v.Storage == .uniform && !v.Type.IsSampler {
            guard v.Index < offsets.count else { throw TranslateError("no uniform offset for \(v.Name)") }
            s += try loadUniform(name(v), v.Type, offsets[v.Index], indent: "    ")
        }
        // Global initializers, then main.
        out = ""
        indent = 1
        try stmts(m.Init)
        s += out
        guard m.EntryPoint >= 0 else { throw TranslateError("no main") }
        s += "    f\(m.EntryPoint)_\(clean(m.Functions[m.EntryPoint].Name))(G, T);\n"
        if vertex {
            s += "    VOut o;\n"
            if let pos = m.Variables.first(where: { isBuiltin($0, .position) }) {
                // GL's clip z is -w…w, Metal's 0…w; a target stored bottom row first is drawn upside down.
                s += "    float4 p = \(name(pos));\n    o.position = float4(p.x, p.y * k.flip, (p.z + p.w) * 0.5, p.w);\n"
            } else {
                s += "    o.position = float4(0.0, 0.0, 0.0, 1.0);\n"
            }
            for v in m.Variables where isBuiltin(v, .pointSize) { s += "    o.pointSize = \(name(v));\n" }
            for v in outputs { s += "    o.\(fieldName(v)) = \(name(v));\n" }
            s += "    return o;\n}\n"
        } else {
            s += "    FOut o;\n"
            var color = "float4(0.0)"
            if let c = m.Variables.first(where: { isBuiltin($0, .fragColor) }), isWritten(c) {
                color = name(c)
            } else if let c = m.Variables.first(where: { isBuiltin($0, .fragData) }) {
                color = "\(name(c))[0]"
            } else if let c = outputs.first(where: { $0.Location <= 0 }) {
                color = try convertColor(name(c), c.Type)
            } else if let c = m.Variables.first(where: { isBuiltin($0, .fragColor) }) {
                color = name(c)
            }
            s += "    o.color = \(color);\n"
            if m.WritesDepth, let d = m.Variables.first(where: { isBuiltin($0, .fragDepth) }) { s += "    o.depth = \(name(d));\n" }
            s += "    return o;\n}\n"
        }
        return s
    }

    func isWritten(_ v: shader.Variable) -> bool { true }

    func convertColor(_ e: string, _ t: shader.DataType) throws -> string {
        if t.IsFloat && t.Rows == 4 { return e }
        if t.IsFloat && t.Rows == 3 { return "float4(\(e), 1.0)" }
        if t.IsFloat && t.Rows == 2 { return "float4(\(e), 0.0, 1.0)" }
        if t.IsFloat { return "float4(\(e), 0.0, 0.0, 1.0)" }
        throw TranslateError("an integer color output")
    }

    func isBuiltin(_ v: shader.Variable, _ b: shader.Builtin) -> bool {
        if case .builtin(let x) = v.Storage { return x == b }
        return false
    }

    func varying(_ v: shader.Variable) throws -> string {
        if v.Type.IsArray || v.Type.IsStruct || v.Type.IsMatrix { throw TranslateError("varying \(v.Name) of an array, struct or matrix type") }
        let flat = v.Flat || v.Type.IsIntegral ? " [[flat]]" : ""
        return "    \(try type(v.Type)) \(fieldName(v)) [[user(\(clean(v.Name)))]]\(flat);\n"
    }

    func textureParams() -> string {
        var s = ""
        for slot in samplers {
            s += ",\n    \(textureType(slot.Kind)) t\(slot.Slot) [[texture(\(slot.Slot))]], sampler s\(slot.Slot) [[sampler(\(slot.Slot))]]"
        }
        return s
    }

    /// Code that loads a uniform of `t` at slot `o` into `dst`.
    func loadUniform(_ dst: string, _ t: shader.DataType, _ o: int, indent ind: string) throws -> string {
        if t.IsArray {
            var s = ""
            let w = m.Slots(t.Element)
            for i in 0..<t.ArrayCount { s += try loadUniform("\(dst)[\(i)]", t.Element, o + i * w, indent: ind) }
            return s
        }
        if case .structure(let st) = t.Kind {
            var s = ""
            var at = o
            for (k, f) in m.Structs[st].Fields.enumerated() {
                s += try loadUniform("\(dst).f\(k)", f.Type, at, indent: ind)
                at += m.Slots(f.Type)
            }
            return s
        }
        func comp(_ i: int) -> string {
            switch t.Kind {
            case .float: return "as_type<float>(U[\(o + i)])"
            case .int: return "as_type<int>(U[\(o + i)])"
            case .bool: return "(U[\(o + i)] != 0u)"
            default: return "U[\(o + i)]"
            }
        }
        if t.IsMatrix {
            var cols: [string] = []
            for c in 0..<t.Columns {
                var comps: [string] = []
                for r in 0..<t.Rows { comps.append(comp(c * t.Rows + r)) }
                cols.append("float\(t.Rows)(\(comps.joined(separator: ", ")))")
            }
            return "\(ind)\(dst) = \(try type(t))(\(cols.joined(separator: ", ")));\n"
        }
        var comps: [string] = []
        for i in 0..<t.Rows { comps.append(comp(i)) }
        if t.Rows == 1 { return "\(ind)\(dst) = \(comps[0]);\n" }
        return "\(ind)\(dst) = \(try type(t))(\(comps.joined(separator: ", ")));\n"
    }
}
