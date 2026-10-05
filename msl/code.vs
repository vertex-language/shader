package msl

import (
    "shader"
)

extension Printer {
    // MARK: statements

    func stmts(_ list: [shader.Stmt]) throws {
        for s in list { try stmt(s) }
    }

    func stmt(_ s: shader.Stmt) throws {
        switch s.Op {
        case .expr:
            line(try expr(s.Expr!) + ";")
        case .declare:
            let v = m.Variables[s.Index]
            if let e = s.Expr {
                if v.Storage == .local {
                    line("\(try type(v.Type)) \(name(v)) = \(try expr(e));")
                } else {
                    line("\(name(v)) = \(try expr(e));")
                }
            } else if v.Storage == .local {
                line("\(try type(v.Type)) \(name(v)) = {};")
            }
        case .ifElse:
            line("if (\(try expr(s.Expr!))) {")
            indent += 1
            try stmts(s.Body)
            indent -= 1
            if s.Else.isEmpty {
                line("}")
            } else {
                line("} else {")
                indent += 1
                try stmts(s.Else)
                indent -= 1
                line("}")
            }
        case .loop:
            let cond = s.Expr != nil ? try expr(s.Expr!) : "true"
            let step = s.Step != nil ? try expr(s.Step!) : ""
            line("for (; \(cond); \(step)) {")
            indent += 1
            try stmts(s.Body)
            indent -= 1
            line("}")
        case .doWhile:
            line("do {")
            indent += 1
            try stmts(s.Body)
            indent -= 1
            line("} while (\(try expr(s.Expr!)));")
        case .breakLoop:
            line("break;")
        case .continueLoop:
            line("continue;")
        case .returnValue:
            if let e = s.Expr { line("return \(try expr(e));") } else { line("return;") }
        case .discard:
            line("discard_fragment();")
        case .block:
            line("{")
            indent += 1
            try stmts(s.Body)
            indent -= 1
            line("}")
        case .switchCase:
            line("switch (\(try expr(s.Expr!))) {")
            var next = 0
            for (k, body) in s.Body.enumerated() {
                while next < s.Labels.count && s.Labels[next].Start == k {
                    if let v = s.Labels[next].Value { line("case \(v):") } else { line("default:") }
                    next += 1
                }
                indent += 1
                try stmt(body)
                indent -= 1
            }
            while next < s.Labels.count {
                if let v = s.Labels[next].Value { line("case \(v):") } else { line("default:") }
                next += 1
            }
            line("}")
        }
    }

    // MARK: constants

    func floatLiteral(_ bits: uint32) -> string {
        let f = float32(bitPattern: bits)
        if f.isNaN { return "NAN" }
        if f.isInfinite { return f > 0 ? "INFINITY" : "(-INFINITY)" }
        // Exact: the bits themselves.
        return "as_type<float>(0x\(string(bits, radix: 16))u)"
    }

    func scalarLiteral(_ k: shader.Kind, _ bits: uint32) -> string {
        switch k {
        case .float: return floatLiteral(bits)
        case .int: return "int(\(int32(bitPattern: bits)))"
        case .uint: return "\(bits)u"
        default: return bits != 0 ? "true" : "false"
        }
    }

    func constant(_ t: shader.DataType, _ v: [uint32]) throws -> string {
        if t.IsArray {
            let w = m.Slots(t.Element)
            var parts: [string] = []
            for i in 0..<t.ArrayCount { parts.append(try constant(t.Element, Array(v[(i * w)..<((i + 1) * w)]))) }
            return "\(try type(t)){\(parts.joined(separator: ", "))}"
        }
        if case .structure(let s) = t.Kind {
            var parts: [string] = []
            var at = 0
            for f in m.Structs[s].Fields {
                let w = m.Slots(f.Type)
                parts.append(try constant(f.Type, Array(v[at..<(at + w)])))
                at += w
            }
            return "S\(s){\(parts.joined(separator: ", "))}"
        }
        if t.IsScalar { return scalarLiteral(t.Kind, v[0]) }
        if t.IsMatrix {
            var cols: [string] = []
            for c in 0..<t.Columns {
                var comps: [string] = []
                for r in 0..<t.Rows { comps.append(floatLiteral(v[c * t.Rows + r])) }
                cols.append("float\(t.Rows)(\(comps.joined(separator: ", ")))")
            }
            return "\(try type(t))(\(cols.joined(separator: ", ")))"
        }
        var comps: [string] = []
        for x in v { comps.append(scalarLiteral(t.Kind, x)) }
        return "\(try type(t))(\(comps.joined(separator: ", ")))"
    }

    // MARK: expressions

    func expr(_ e: shader.Expr) throws -> string {
        switch e.Op {
        case .constant, .arrayLength:
            return try constant(e.Type, e.Value)
        case .variable:
            let v = m.Variables[e.Index]
            if v.Storage == .constant { return "c\(v.Index)_\(clean(v.Name))" }
            if v.Type.IsSampler { throw TranslateError("a sampler used as a value") }
            return name(v)
        case .swizzle:
            let letters: [string] = ["x", "y", "z", "w"]
            var s = ""
            for c in e.Components { s += letters[c] }
            let base = try expr(e.Args[0])
            // A scalar's swizzle (3.00): build the vector.
            if e.Args[0].Type.IsScalar { return e.Components.count == 1 ? base : "\(try type(e.Type))(\(base))" }
            return "(\(base)).\(s)"
        case .index:
            return "(\(try expr(e.Args[0])))[\(try expr(e.Args[1]))]"
        case .field:
            return "(\(try expr(e.Args[0]))).f\(e.Index)"
        case .unary(let u):
            let a = try expr(e.Args[0])
            switch u {
            case .negate: return "(-\(a))"
            case .not: return e.Type.IsVector ? "(!\(a))" : "(!\(a))"
            case .complement: return "(~\(a))"
            }
        case .binary(let b):
            return try binary(b, e)
        case .select:
            return "(\(try expr(e.Args[0])) ? \(try expr(e.Args[1])) : \(try expr(e.Args[2])))"
        case .call:
            var args = ["G", "T"]
            for a in e.Args { args.append(try expr(a)) }
            return "f\(e.Index)_\(clean(m.Functions[e.Index].Name))(\(args.joined(separator: ", ")))"
        case .builtin(let f):
            return try builtin(f, e)
        case .construct:
            return try construct(e)
        case .assign:
            return "(\(try expr(e.Args[0])) = \(try expr(e.Args[1])))"
        case .compoundAssign(let b):
            let lhs = try expr(e.Args[0])
            let combined = shader.Expr(.binary(b), e.Type, [e.Args[0], e.Args[1]])
            return "(\(lhs) = \(try binary(b, combined)))"
        case .preIncrement: return "(++\(try expr(e.Args[0])))"
        case .preDecrement: return "(--\(try expr(e.Args[0])))"
        case .postIncrement: return "(\(try expr(e.Args[0]))++)"
        case .postDecrement: return "(\(try expr(e.Args[0]))--)"
        case .sequence:
            var parts: [string] = []
            for a in e.Args { parts.append(try expr(a)) }
            return "(\(parts.joined(separator: ", ")))"
        }
    }

    func binary(_ b: shader.BinaryOp, _ e: shader.Expr) throws -> string {
        let l = e.Args[0]
        let r = e.Args[1]
        let a = try expr(l)
        let c = try expr(r)
        switch b {
        case .equal, .notEqual:
            if l.Type.IsArray || l.Type.IsStruct { throw TranslateError("== of arrays or structs") }
            var same = "(\(a) == \(c))"
            if l.Type.IsVector { same = "all(\(a) == \(c))" }
            if l.Type.IsMatrix {
                var cols: [string] = []
                for k in 0..<l.Type.Columns { cols.append("all((\(a))[\(k)] == (\(c))[\(k)])") }
                same = "(\(cols.joined(separator: " && ")))"
            }
            return b == .equal ? same : "(!\(same))"
        case .logicalXor:
            return "(\(a) != \(c))"
        default:
            break
        }
        let op: string
        switch b {
        case .add: op = "+"
        case .subtract: op = "-"
        case .multiply: op = "*"
        case .divide: op = "/"
        case .remainder: op = "%"
        case .less: op = "<"
        case .lessEqual: op = "<="
        case .greater: op = ">"
        case .greaterEqual: op = ">="
        case .logicalAnd: op = "&&"
        case .logicalOr: op = "||"
        case .bitAnd: op = "&"
        case .bitOr: op = "|"
        case .bitXor: op = "^"
        case .shiftLeft: op = "<<"
        default: op = ">>"
        }
        // A matrix with a scalar, componentwise: Metal has * and / but not + or -.
        if (op == "+" || op == "-") && (l.Type.IsMatrix != r.Type.IsMatrix) {
            let mt = l.Type.IsMatrix ? l.Type : r.Type
            var cols: [string] = []
            for k in 0..<mt.Columns {
                let x = l.Type.IsMatrix ? "(\(a))[\(k)]" : a
                let y = r.Type.IsMatrix ? "(\(c))[\(k)]" : c
                cols.append("(\(x) \(op) \(y))")
            }
            return "\(try type(mt))(\(cols.joined(separator: ", ")))"
        }
        return "(\(a) \(op) \(c))"
    }

    /// `s` as a value of `t`'s shape, when it is a scalar used with a vector.
    func widen(_ s: string, _ from: shader.DataType, _ to: shader.DataType) throws -> string {
        if from.IsScalar && !to.IsScalar && to.IsVector { return "\(try type(to))(\(s))" }
        return s
    }

    func helper(_ name: string, _ code: string) -> string {
        if !helperNames.contains(name) {
            helperNames.append(name)
            helpers.append(code)
        }
        return name
    }

    func builtin(_ f: shader.Function, _ e: shader.Expr) throws -> string {
        let t = e.Type
        var a: [string] = []
        for x in e.Args where !x.Type.IsSampler { a.append(try expr(x)) }
        func w(_ i: int) throws -> string {
            // Argument i, widened to the result's shape.
            let off = e.Args[0].Type.IsSampler ? 1 : 0
            return try widen(a[i], e.Args[i + off].Type, t)
        }
        switch f {
        case .radians: return "(\(a[0]) * 0.017453292519943295f)"
        case .degrees: return "(\(a[0]) * 57.29577951308232f)"
        case .sin: return "sin(\(a[0]))"
        case .cos: return "cos(\(a[0]))"
        case .tan: return "tan(\(a[0]))"
        case .asin: return "asin(\(a[0]))"
        case .acos: return "acos(\(a[0]))"
        case .atan: return "atan(\(a[0]))"
        case .atan2: return "atan2(\(a[0]), \(a[1]))"
        case .sinh: return "sinh(\(a[0]))"
        case .cosh: return "cosh(\(a[0]))"
        case .tanh: return "tanh(\(a[0]))"
        case .asinh: return "asinh(\(a[0]))"
        case .acosh: return "acosh(\(a[0]))"
        case .atanh: return "atanh(\(a[0]))"
        case .pow: return "pow(\(a[0]), \(a[1]))"
        case .exp: return "exp(\(a[0]))"
        case .log: return "log(\(a[0]))"
        case .exp2: return "exp2(\(a[0]))"
        case .log2: return "log2(\(a[0]))"
        case .sqrt: return "sqrt(\(a[0]))"
        case .inversesqrt: return "rsqrt(\(a[0]))"
        case .abs: return "abs(\(a[0]))"
        case .sign:
            if t.IsFloat { return "sign(\(a[0]))" }
            return "\(try type(t))((\(a[0]) > 0) ? 1 : 0) - \(try type(t))((\(a[0]) < 0) ? 1 : 0)"
        case .floor: return "floor(\(a[0]))"
        case .trunc: return "trunc(\(a[0]))"
        case .round: return "round(\(a[0]))"
        case .roundEven: return "rint(\(a[0]))"
        case .ceil: return "ceil(\(a[0]))"
        case .fract: return "fract(\(a[0]))"
        case .mod:
            let y = try w(1)
            return "((\(a[0])) - (\(y)) * floor((\(a[0])) / (\(y))))"
        case .modf:
            let n = try expr(e.Args[1])
            return "((\(n) = trunc(\(a[0]))), (\(a[0]) - \(n)))"
        case .min: return "min(\(a[0]), \(try w(1)))"
        case .max: return "max(\(a[0]), \(try w(1)))"
        case .clamp: return "clamp(\(a[0]), \(try w(1)), \(try w(2)))"
        case .mix:
            if e.Args[2].Type.Kind == .bool { return "select(\(a[0]), \(a[1]), \(a[2]))" }
            return "mix(\(a[0]), \(a[1]), \(try w(2)))"
        case .step: return "step(\(try w(0)), \(a[1]))"
        case .smoothstep: return "smoothstep(\(try w(0)), \(try w(1)), \(a[2]))"
        case .isnan: return "isnan(\(a[0]))"
        case .isinf: return "isinf(\(a[0]))"
        case .floatBitsToInt, .floatBitsToUint, .intBitsToFloat, .uintBitsToFloat:
            return "as_type<\(try type(t))>(\(a[0]))"
        case .packSnorm2x16: return "pack_float_to_snorm2x16(\(a[0]))"
        case .unpackSnorm2x16: return "unpack_snorm2x16_to_float(\(a[0]))"
        case .packUnorm2x16: return "pack_float_to_unorm2x16(\(a[0]))"
        case .unpackUnorm2x16: return "unpack_unorm2x16_to_float(\(a[0]))"
        case .packHalf2x16: return "as_type<uint>(half2(\(a[0])))"
        case .unpackHalf2x16: return "float2(as_type<half2>(\(a[0])))"
        case .length: return "length(\(a[0]))"
        case .distance: return "distance(\(a[0]), \(a[1]))"
        case .dot:
            return e.Args[0].Type.IsScalar ? "(\(a[0]) * \(a[1]))" : "dot(\(a[0]), \(a[1]))"
        case .cross: return "cross(\(a[0]), \(a[1]))"
        case .normalize: return e.Args[0].Type.IsScalar ? "sign(\(a[0]))" : "normalize(\(a[0]))"
        case .faceforward: return "faceforward(\(a[0]), \(a[1]), \(a[2]))"
        case .reflect: return "reflect(\(a[0]), \(a[1]))"
        case .refract: return "refract(\(a[0]), \(a[1]), \(a[2]))"
        case .matrixCompMult:
            var cols: [string] = []
            for k in 0..<t.Columns { cols.append("(\(a[0]))[\(k)] * (\(a[1]))[\(k)]") }
            return "\(try type(t))(\(cols.joined(separator: ", ")))"
        case .outerProduct:
            var cols: [string] = []
            for k in 0..<t.Columns { cols.append("(\(a[0])) * (\(a[1]))[\(k)]") }
            return "\(try type(t))(\(cols.joined(separator: ", ")))"
        case .transpose: return "transpose(\(a[0]))"
        case .determinant: return "determinant(\(a[0]))"
        case .inverse:
            let n = t.Columns
            let h = helper("gl_inverse\(n)", inverseHelper(n))
            return "\(h)(\(a[0]))"
        case .lessThan: return "(\(a[0]) < \(a[1]))"
        case .lessThanEqual: return "(\(a[0]) <= \(a[1]))"
        case .greaterThan: return "(\(a[0]) > \(a[1]))"
        case .greaterThanEqual: return "(\(a[0]) >= \(a[1]))"
        case .equal: return "(\(a[0]) == \(a[1]))"
        case .notEqual: return "(\(a[0]) != \(a[1]))"
        case .any: return "any(\(a[0]))"
        case .all: return "all(\(a[0]))"
        case .not: return "(!\(a[0]))"
        case .dFdx: return "dfdx(\(a[0]))"
        case .dFdy: return "(G.dfdySign * dfdy(\(a[0])))"
        case .fwidth: return "fwidth(\(a[0]))"
        default:
            return try texture(f, e, a)
        }
    }

    func samplerSlot(_ e: shader.Expr) throws -> SamplerSlot {
        guard e.Op == .variable, let s = samplers.first(where: { $0.Variable == e.Index }) else {
            throw TranslateError("a sampler that isn't a plain uniform")
        }
        return s
    }

    /// Texture lookups. `a` holds the arguments after the sampler.
    func texture(_ f: shader.Function, _ e: shader.Expr, _ a: [string]) throws -> string {
        let slot = try samplerSlot(e.Args[0])
        let k = slot.Kind
        let tex = "T.t\(slot.Slot)"
        let smp = "T.s\(slot.Slot)"
        let coordType = e.Args[1].Type
        var coord = a[0]
        let n = coordType.Rows
        let proj = f == .textureProj || f == .textureProjLod
        if proj {
            let last = n == 4 ? "w" : (n == 3 ? "z" : "y")
            let lead = k == .texture3D ? "xyz" : "xy"
            coord = "((\(coord)).\(lead) / (\(coord)).\(last))"
        }
        // Coordinates and the extra arguments of each kind of sampler.
        var c = coord
        var ref = ""
        switch k {
        case .array2D:
            c = "(\(coord)).xy, uint(rint((\(coord)).z))"
        case .shadow2D:
            c = proj ? coord : "(\(coord)).xy"
            ref = proj ? "(\(a[0])).z / (\(a[0])).w" : "(\(coord)).z"
        case .shadowCube:
            c = "(\(coord)).xyz"
            ref = "(\(coord)).w"
        case .shadowArray2D:
            c = "(\(coord)).xy, uint(rint((\(coord)).z))"
            ref = "(\(coord)).w"
        default:
            break
        }
        switch f {
        case .texelFetch:
            return "\(tex).read(uint2(\(a[0])), uint(\(a[1])))"
        case .textureSize:
            return "int2(int(\(tex).get_width(uint(\(a[0])))), int(\(tex).get_height(uint(\(a[0])))))"
        default:
            break
        }
        var options = ""
        switch f {
        case .textureLod, .textureProjLod: options = ", level(\(a[1]))"
        case .textureGrad:
            let g = k == .cube ? "gradientcube" : (k == .texture3D ? "gradient3d" : "gradient2d")
            options = ", \(g)(\(a[1]), \(a[2]))"
        case .texture, .textureProj:
            if a.count > 1 { options = ", bias(\(a[1]))" }
        default:
            throw TranslateError("textureOffset")
        }
        if !ref.isEmpty {
            return "\(tex).sample_compare(\(smp), \(c), \(ref)\(options))"
        }
        return "\(tex).sample(\(smp), \(c)\(options))"
    }

    // MARK: constructors

    func construct(_ e: shader.Expr) throws -> string {
        let t = e.Type
        var args: [string] = []
        for x in e.Args { args.append(try expr(x)) }
        if t.IsArray || t.IsStruct { return "\(try type(t)){\(args.joined(separator: ", "))}" }
        let tn = try type(t)
        let comp = scalarName(t.Kind)
        if e.Args.count == 1 {
            let at = e.Args[0].Type
            if t.IsScalar {
                // The first component of whatever it's given.
                if at.IsMatrix { return "\(comp)((\(args[0]))[0][0])" }
                if at.IsVector { return "\(comp)((\(args[0])).x)" }
                return "\(comp)(\(args[0]))"
            }
            if t.IsVector {
                if at.IsScalar { return "\(tn)(\(comp)(\(args[0])))" }
                if at.IsVector {
                    let letters = "xyzw"
                    let sub = string(letters.prefix(t.Rows))
                    let v = at.Rows == t.Rows ? args[0] : "(\(args[0])).\(sub)"
                    return at.Kind == t.Kind ? "\(tn)(\(v))" : "\(tn)(\(v))"
                }
            }
            if t.IsMatrix {
                if at.IsScalar { return "\(tn)(float(\(args[0])))" }
                if at.IsMatrix {
                    // Resized: the overlap, the rest from the identity.
                    var cols: [string] = []
                    for c in 0..<t.Columns {
                        var comps: [string] = []
                        for r in 0..<t.Rows {
                            if c < at.Columns && r < at.Rows { comps.append("(\(args[0]))[\(c)][\(r)]") } else { comps.append(c == r ? "1.0" : "0.0") }
                        }
                        cols.append("float\(t.Rows)(\(comps.joined(separator: ", ")))")
                    }
                    return "\(tn)(\(cols.joined(separator: ", ")))"
                }
            }
        }
        // Components in order, from scalars, vectors and matrices: a helper
        // takes the arguments once and spreads their components.
        var params: [string] = []
        var comps: [string] = []
        for (i, x) in e.Args.enumerated() {
            let at = x.Type
            params.append("\(try type(at)) p\(i)")
            if at.IsMatrix {
                for c in 0..<at.Columns { for r in 0..<at.Rows { comps.append("p\(i)[\(c)][\(r)]") } }
            } else if at.IsVector {
                let letters: [string] = ["x", "y", "z", "w"]
                for r in 0..<at.Rows { comps.append("p\(i).\(letters[r])") }
            } else {
                comps.append("p\(i)")
            }
        }
        let need = t.Components
        if comps.count < need { throw TranslateError("too few components for \(tn)") }
        var body: string
        if t.IsMatrix {
            var cols: [string] = []
            for c in 0..<t.Columns {
                var cs: [string] = []
                for r in 0..<t.Rows { cs.append("float(\(comps[c * t.Rows + r]))") }
                cols.append("float\(t.Rows)(\(cs.joined(separator: ", ")))")
            }
            body = "\(tn)(\(cols.joined(separator: ", ")))"
        } else {
            var cs: [string] = []
            for k in 0..<need { cs.append("\(comp)(\(comps[k]))") }
            body = "\(tn)(\(cs.joined(separator: ", ")))"
        }
        let hname = "mk\(helperNames.count)"
        let h = helper(hname, "static \(tn) \(hname)(\(params.joined(separator: ", "))) { return \(body); }\n")
        return "\(h)(\(args.joined(separator: ", ")))"
    }

    func inverseHelper(_ n: int) -> string {
        switch n {
        case 2:
            return "static float2x2 gl_inverse2(float2x2 m) { float d = determinant(m); return float2x2(float2(m[1][1], -m[0][1]), float2(-m[1][0], m[0][0])) * (1.0 / d); }\n"
        case 3:
            return """
            static float3x3 gl_inverse3(float3x3 m) {
                float3 a = m[0], b = m[1], c = m[2];
                float3 r0 = cross(b, c), r1 = cross(c, a), r2 = cross(a, b);
                float d = dot(a, r0);
                return transpose(float3x3(r0, r1, r2)) * (1.0 / d);
            }

            """
        default:
            return """
            static float4x4 gl_inverse4(float4x4 m) {
                float4x4 inv;
                float a00 = m[0][0], a01 = m[0][1], a02 = m[0][2], a03 = m[0][3];
                float a10 = m[1][0], a11 = m[1][1], a12 = m[1][2], a13 = m[1][3];
                float a20 = m[2][0], a21 = m[2][1], a22 = m[2][2], a23 = m[2][3];
                float a30 = m[3][0], a31 = m[3][1], a32 = m[3][2], a33 = m[3][3];
                float b00 = a00 * a11 - a01 * a10, b01 = a00 * a12 - a02 * a10, b02 = a00 * a13 - a03 * a10;
                float b03 = a01 * a12 - a02 * a11, b04 = a01 * a13 - a03 * a11, b05 = a02 * a13 - a03 * a12;
                float b06 = a20 * a31 - a21 * a30, b07 = a20 * a32 - a22 * a30, b08 = a20 * a33 - a23 * a30;
                float b09 = a21 * a32 - a22 * a31, b10 = a21 * a33 - a23 * a31, b11 = a22 * a33 - a23 * a32;
                float det = b00 * b11 - b01 * b10 + b02 * b09 + b03 * b08 - b04 * b07 + b05 * b06;
                inv[0] = float4(a11 * b11 - a12 * b10 + a13 * b09, a02 * b10 - a01 * b11 - a03 * b09, a31 * b05 - a32 * b04 + a33 * b03, a22 * b04 - a21 * b05 - a23 * b03);
                inv[1] = float4(a12 * b08 - a10 * b11 - a13 * b07, a00 * b11 - a02 * b08 + a03 * b07, a32 * b02 - a30 * b05 - a33 * b01, a20 * b05 - a22 * b02 + a23 * b01);
                inv[2] = float4(a10 * b10 - a11 * b08 + a13 * b06, a01 * b08 - a00 * b10 - a03 * b06, a30 * b04 - a31 * b02 + a33 * b00, a21 * b02 - a20 * b04 - a23 * b00);
                inv[3] = float4(a11 * b07 - a10 * b09 - a12 * b06, a00 * b09 - a01 * b07 + a02 * b06, a31 * b01 - a30 * b03 - a32 * b00, a20 * b03 - a21 * b01 + a22 * b00);
                return inv * (1.0 / det);
            }

            """
        }
    }
}
