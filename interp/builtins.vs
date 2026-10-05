package interp

import (
    "shader"
)

extension Compiler {
    func builtin(_ f: shader.Function, _ e: shader.Expr) throws -> int {
        let t = e.Type
        let n = m.Slots(t)
        let args = e.Args
        var a: [int] = []
        // modf's second argument is written, not read; texture lookups read all.
        for (k, x) in args.enumerated() {
            if f == .modf && k == 1 { a.append(0); continue }
            a.append(try expr(x))
        }
        func stride(_ k: int) -> int { m.Slots(args[k].Type) == 1 && n > 1 ? 0 : 1 }
        let d = temp(max(1, n))
        func math(_ o: Op) {
            var i = Instr(o)
            i.N = n
            i.Dst = d
            i.A = a[0]
            if a.count > 1 { i.B = a[1]; i.StrideB = stride(1) }
            if a.count > 2 { i.C = a[2]; i.StrideC = stride(2) }
            i.StrideA = stride(0)
            i.Fn = f
            _ = emit(i)
        }
        let k = args[0].Type.Kind
        switch f {
        case .radians, .degrees, .sin, .cos, .tan, .asin, .acos, .atan, .sinh, .cosh, .tanh, .asinh, .acosh, .atanh,
             .exp, .log, .exp2, .log2, .sqrt, .inversesqrt, .floor, .trunc, .round, .roundEven, .ceil, .fract:
            math(.math1)
        case .abs:
            if k == .float { math(.math1) } else { op(.iabs, n: n, dst: d, a: a[0]) }
        case .sign:
            if k == .float { math(.math1) } else { op(.isign, n: n, dst: d, a: a[0]) }
        case .pow, .atan2, .mod, .step:
            math(.math2)
        case .min, .max:
            switch k {
            case .float: math(.math2)
            case .int: op(f == .min ? .imin : .imax, n: n, dst: d, a: a[0], b: a[1], sb: stride(1))
            default: op(f == .min ? .umin : .umax, n: n, dst: d, a: a[0], b: a[1], sb: stride(1))
            }
        case .clamp:
            switch k {
            case .float: math(.math3)
            case .int: op(.iclamp, n: n, dst: d, a: a[0], b: a[1], c: a[2], sb: stride(1), sc: stride(2))
            default: op(.uclamp, n: n, dst: d, a: a[0], b: a[1], c: a[2], sb: stride(1), sc: stride(2))
            }
        case .mix:
            if args[2].Type.Kind == .bool {
                op(.select, n: n, dst: d, a: a[1], b: a[0], c: a[2])
            } else {
                math(.math3)
            }
        case .smoothstep:
            math(.math3)
        case .modf:
            let whole = temp(n)
            var i = Instr(.math1)
            i.N = n
            i.Dst = whole
            i.A = a[0]
            i.Fn = .trunc
            _ = emit(i)
            store(try place(args[1]), whole, n)
            op(.fsub, n: n, dst: d, a: a[0], b: whole)
        case .isnan: op(.isnan, n: n, dst: d, a: a[0])
        case .isinf: op(.isinf, n: n, dst: d, a: a[0])
        case .floatBitsToInt, .floatBitsToUint, .intBitsToFloat, .uintBitsToFloat:
            mov(d, a[0], n)
        case .packSnorm2x16: op(.packSnorm2x16, n: 1, dst: d, a: a[0])
        case .unpackSnorm2x16: op(.unpackSnorm2x16, n: 2, dst: d, a: a[0])
        case .packUnorm2x16: op(.packUnorm2x16, n: 1, dst: d, a: a[0])
        case .unpackUnorm2x16: op(.unpackUnorm2x16, n: 2, dst: d, a: a[0])
        case .packHalf2x16: op(.packHalf2x16, n: 1, dst: d, a: a[0])
        case .unpackHalf2x16: op(.unpackHalf2x16, n: 2, dst: d, a: a[0])
        case .length, .distance, .dot, .normalize, .cross, .reflect, .refract, .faceforward:
            var i = Instr(.dot)
            switch f {
            case .length: i = Instr(.length)
            case .distance: i = Instr(.distance)
            case .normalize: i = Instr(.normalize)
            case .cross: i = Instr(.cross)
            case .reflect: i = Instr(.reflect)
            case .refract: i = Instr(.refract)
            case .faceforward: i = Instr(.faceforward)
            default: break
            }
            i.N = n
            i.Dst = d
            i.A = a[0]
            if a.count > 1 { i.B = a[1] }
            if a.count > 2 { i.C = a[2] }
            i.Aux = m.Slots(args[0].Type)
            _ = emit(i)
        case .matrixCompMult:
            op(.fmul, n: n, dst: d, a: a[0], b: a[1])
        case .outerProduct:
            var i = Instr(.outer)
            i.Dst = d
            i.A = a[0]
            i.B = a[1]
            i.Aux = args[0].Type.Rows
            i.Aux2 = args[1].Type.Rows
            _ = emit(i)
        case .transpose, .determinant, .inverse:
            var i = Instr(f == .transpose ? .transpose : f == .determinant ? .determinant : .inverse)
            i.Dst = d
            i.A = a[0]
            i.Aux = args[0].Type.Rows
            i.Aux2 = args[0].Type.Columns
            _ = emit(i)
        case .lessThan, .lessThanEqual, .greaterThan, .greaterThanEqual:
            var o: Op
            switch (f, k) {
            case (.lessThan, .float): o = .flt
            case (.lessThan, .uint): o = .ult
            case (.lessThan, _): o = .ilt
            case (.lessThanEqual, .float): o = .fle
            case (.lessThanEqual, .uint): o = .ule
            case (.lessThanEqual, _): o = .ile
            case (.greaterThan, .float): o = .fgt
            case (.greaterThan, .uint): o = .ugt
            case (.greaterThan, _): o = .igt
            case (_, .float): o = .fge
            case (_, .uint): o = .uge
            default: o = .ige
            }
            op(o, n: n, dst: d, a: a[0], b: a[1])
        case .equal, .notEqual:
            let o: Op = k == .float ? (f == .equal ? .feq : .fne) : (f == .equal ? .ieq : .ine)
            op(o, n: n, dst: d, a: a[0], b: a[1])
        case .any, .all:
            var i = Instr(f == .any ? .any : .all)
            i.N = m.Slots(args[0].Type)
            i.Dst = d
            i.A = a[0]
            _ = emit(i)
        case .not:
            op(.not, n: n, dst: d, a: a[0])
        case .dFdx, .dFdy, .fwidth:
            exe.UsesDerivatives = true
            op(f == .dFdx ? .dfdx : f == .dFdy ? .dfdy : .fwidth, n: n, dst: d, a: a[0])
        case .texture, .textureProj, .textureLod, .textureProjLod, .textureGrad, .textureOffset:
            guard case .sampler(let sk) = args[0].Type.Kind else { throw CompileError("a lookup without a sampler") }
            var i = Instr(.sample)
            i.Dst = d
            i.A = a[0]
            i.B = a[1]
            i.Aux2 = m.Slots(args[1].Type)
            i.Sampler = sk
            i.Projective = f == .textureProj || f == .textureProjLod
            i.N = n
            switch f {
            case .textureLod, .textureProjLod:
                i.Lookup = .level
                i.C = a[2]
            case .textureGrad:
                // dPdx and dPdy, side by side.
                let w = m.Slots(args[2].Type)
                let g = temp(2 * w)
                mov(g, a[2], w)
                mov(g + w, a[3], w)
                i.Lookup = .gradient
                i.C = g
            default:
                if a.count > 2 && f != .textureOffset {
                    i.Lookup = .bias
                    i.C = a[2]
                }
                if m.Stage == .fragment { exe.UsesDerivatives = true }
            }
            _ = emit(i)
        case .texelFetch:
            guard case .sampler(let sk) = args[0].Type.Kind else { throw CompileError("a fetch without a sampler") }
            var i = Instr(.texelFetch)
            i.Dst = d
            i.A = a[0]
            i.B = a[1]
            i.C = a[2]
            i.Aux2 = m.Slots(args[1].Type)
            i.Sampler = sk
            i.N = n
            _ = emit(i)
        case .textureSize:
            guard case .sampler(let sk) = args[0].Type.Kind else { throw CompileError("a size without a sampler") }
            var i = Instr(.textureSize)
            i.Dst = d
            i.A = a[0]
            i.C = a[1]
            i.N = n
            i.Sampler = sk
            _ = emit(i)
        }
        return d
    }
}
