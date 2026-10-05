package glsl

import (
    "shader"
)

/// A built-in call, resolved: what it computes, and its result's type.
struct Resolved {
    let Fn: shader.Function
    let Result: shader.DataType
}

/// float, vec2, vec3 or vec4 (GLSL's genType).
func isGenFloat(_ t: shader.DataType) -> bool { t.IsFloat && !t.IsArray && t.Columns == 1 }
/// int or ivecN (genIType).
func isGenInt(_ t: shader.DataType) -> bool { t.Kind == .int && !t.IsArray && t.Columns == 1 }
/// uint or uvecN (genUType).
func isGenUint(_ t: shader.DataType) -> bool { t.Kind == .uint && !t.IsArray && t.Columns == 1 }
/// bool or bvecN (genBType).
func isGenBool(_ t: shader.DataType) -> bool { t.Kind == .bool && !t.IsArray && t.Columns == 1 }
func isFloatScalar(_ t: shader.DataType) -> bool { t == shader.DataType.Float }
func isVectorOf(_ t: shader.DataType, _ k: shader.Kind) -> bool { t.Kind == k && t.IsVector }

/// The sampler kind of a sampler type, and whether it's a sampler at all.
func samplerOf(_ t: shader.DataType) -> shader.SamplerKind? {
    if t.IsArray { return nil }
    if case .sampler(let k) = t.Kind { return k }
    return nil
}

/// The coordinate width a sampler's lookups take (before projection).
func coordWidth(_ k: shader.SamplerKind) -> int {
    switch k {
    case .texture2D, .external, .itexture2D, .utexture2D: return 2
    case .texture3D, .cube, .array2D, .shadow2D: return 3
    case .shadowCube, .shadowArray2D: return 4
    }
}

/// What a lookup through a sampler returns.
func lookupResult(_ k: shader.SamplerKind) -> shader.DataType {
    switch k {
    case .shadow2D, .shadowCube, .shadowArray2D: return .Float
    case .itexture2D: return shader.DataType.Vector(.int, 4)
    case .utexture2D: return shader.DataType.Vector(.uint, 4)
    default: return shader.DataType.Vector(.float, 4)
    }
}

/// Resolves a call of a built-in function, or nil when `name` isn't one
/// or no overload takes these arguments.
func resolveBuiltin(_ name: string, _ a: [shader.DataType], fragment: bool, version: int, extensions: [string]) -> Resolved? {
    let es3 = version >= 300
    let n = a.count
    func same(_ k: int) -> bool { for i in 1..<k { if a[i] != a[0] { return false } }; return true }
    func gen(_ fn: shader.Function) -> Resolved? {
        // One genType argument; the result has its type.
        if n == 1 && isGenFloat(a[0]) { return Resolved(Fn: fn, Result: a[0]) }
        return nil
    }
    func gen2(_ fn: shader.Function) -> Resolved? {
        if n == 2 && isGenFloat(a[0]) && a[1] == a[0] { return Resolved(Fn: fn, Result: a[0]) }
        return nil
    }
    switch name {
    case "radians": return gen(.radians)
    case "degrees": return gen(.degrees)
    case "sin": return gen(.sin)
    case "cos": return gen(.cos)
    case "tan": return gen(.tan)
    case "asin": return gen(.asin)
    case "acos": return gen(.acos)
    case "atan": return n == 1 ? gen(.atan) : gen2(.atan2)
    case "sinh": return es3 ? gen(.sinh) : nil
    case "cosh": return es3 ? gen(.cosh) : nil
    case "tanh": return es3 ? gen(.tanh) : nil
    case "asinh": return es3 ? gen(.asinh) : nil
    case "acosh": return es3 ? gen(.acosh) : nil
    case "atanh": return es3 ? gen(.atanh) : nil
    case "pow": return gen2(.pow)
    case "exp": return gen(.exp)
    case "log": return gen(.log)
    case "exp2": return gen(.exp2)
    case "log2": return gen(.log2)
    case "sqrt": return gen(.sqrt)
    case "inversesqrt": return gen(.inversesqrt)
    case "abs", "sign":
        let fn: shader.Function = name == "abs" ? .abs : .sign
        if n == 1 && (isGenFloat(a[0]) || (es3 && isGenInt(a[0]))) { return Resolved(Fn: fn, Result: a[0]) }
        return nil
    case "floor": return gen(.floor)
    case "ceil": return gen(.ceil)
    case "fract": return gen(.fract)
    case "trunc": return es3 ? gen(.trunc) : nil
    case "round": return es3 ? gen(.round) : nil
    case "roundEven": return es3 ? gen(.roundEven) : nil
    case "mod":
        if n == 2 && isGenFloat(a[0]) && (a[1] == a[0] || isFloatScalar(a[1])) { return Resolved(Fn: .mod, Result: a[0]) }
        return nil
    case "modf":
        if es3 && n == 2 && isGenFloat(a[0]) && a[1] == a[0] { return Resolved(Fn: .modf, Result: a[0]) }
        return nil
    case "min", "max":
        let fn: shader.Function = name == "min" ? .min : .max
        if n == 2 && (isGenFloat(a[0]) || (es3 && (isGenInt(a[0]) || isGenUint(a[0])))) &&
            (a[1] == a[0] || a[1] == a[0].ComponentType) {
            return Resolved(Fn: fn, Result: a[0])
        }
        return nil
    case "clamp":
        if n == 3 && (isGenFloat(a[0]) || (es3 && (isGenInt(a[0]) || isGenUint(a[0])))) &&
            ((a[1] == a[0] && a[2] == a[0]) || (a[1] == a[0].ComponentType && a[2] == a[0].ComponentType)) {
            return Resolved(Fn: .clamp, Result: a[0])
        }
        return nil
    case "mix":
        if n == 3 && isGenFloat(a[0]) && a[1] == a[0] && (a[2] == a[0] || isFloatScalar(a[2])) {
            return Resolved(Fn: .mix, Result: a[0])
        }
        if es3 && n == 3 && isGenFloat(a[0]) && a[1] == a[0] && isGenBool(a[2]) && a[2].Rows == a[0].Rows {
            return Resolved(Fn: .mix, Result: a[0])
        }
        return nil
    case "step":
        if n == 2 && isGenFloat(a[1]) && (a[0] == a[1] || isFloatScalar(a[0])) { return Resolved(Fn: .step, Result: a[1]) }
        return nil
    case "smoothstep":
        if n == 3 && isGenFloat(a[2]) && ((a[0] == a[2] && a[1] == a[2]) || (isFloatScalar(a[0]) && isFloatScalar(a[1]))) {
            return Resolved(Fn: .smoothstep, Result: a[2])
        }
        return nil
    case "isnan", "isinf":
        if es3 && n == 1 && isGenFloat(a[0]) {
            return Resolved(Fn: name == "isnan" ? .isnan : .isinf, Result: shader.DataType(.bool, rows: a[0].Rows))
        }
        return nil
    case "floatBitsToInt", "floatBitsToUint":
        if es3 && n == 1 && isGenFloat(a[0]) {
            let k: shader.Kind = name == "floatBitsToInt" ? .int : .uint
            return Resolved(Fn: name == "floatBitsToInt" ? .floatBitsToInt : .floatBitsToUint, Result: shader.DataType(k, rows: a[0].Rows))
        }
        return nil
    case "intBitsToFloat":
        if es3 && n == 1 && isGenInt(a[0]) { return Resolved(Fn: .intBitsToFloat, Result: shader.DataType(.float, rows: a[0].Rows)) }
        return nil
    case "uintBitsToFloat":
        if es3 && n == 1 && isGenUint(a[0]) { return Resolved(Fn: .uintBitsToFloat, Result: shader.DataType(.float, rows: a[0].Rows)) }
        return nil
    case "packSnorm2x16", "packUnorm2x16", "packHalf2x16":
        if es3 && n == 1 && a[0] == shader.DataType.Vector(.float, 2) {
            let fn: shader.Function = name == "packSnorm2x16" ? .packSnorm2x16 : name == "packUnorm2x16" ? .packUnorm2x16 : .packHalf2x16
            return Resolved(Fn: fn, Result: .Uint)
        }
        return nil
    case "unpackSnorm2x16", "unpackUnorm2x16", "unpackHalf2x16":
        if es3 && n == 1 && a[0] == shader.DataType.Uint {
            let fn: shader.Function = name == "unpackSnorm2x16" ? .unpackSnorm2x16 : name == "unpackUnorm2x16" ? .unpackUnorm2x16 : .unpackHalf2x16
            return Resolved(Fn: fn, Result: shader.DataType.Vector(.float, 2))
        }
        return nil
    case "length":
        if n == 1 && isGenFloat(a[0]) { return Resolved(Fn: .length, Result: .Float) }
        return nil
    case "distance":
        if n == 2 && isGenFloat(a[0]) && a[1] == a[0] { return Resolved(Fn: .distance, Result: .Float) }
        return nil
    case "dot":
        if n == 2 && isGenFloat(a[0]) && a[1] == a[0] { return Resolved(Fn: .dot, Result: .Float) }
        return nil
    case "cross":
        let v3 = shader.DataType.Vector(.float, 3)
        if n == 2 && a[0] == v3 && a[1] == v3 { return Resolved(Fn: .cross, Result: v3) }
        return nil
    case "normalize": return gen(.normalize)
    case "faceforward":
        if n == 3 && isGenFloat(a[0]) && same(3) { return Resolved(Fn: .faceforward, Result: a[0]) }
        return nil
    case "reflect": return gen2(.reflect)
    case "refract":
        if n == 3 && isGenFloat(a[0]) && a[1] == a[0] && isFloatScalar(a[2]) { return Resolved(Fn: .refract, Result: a[0]) }
        return nil
    case "matrixCompMult":
        if n == 2 && a[0].IsMatrix && a[1] == a[0] { return Resolved(Fn: .matrixCompMult, Result: a[0]) }
        return nil
    case "outerProduct":
        if es3 && n == 2 && isVectorOf(a[0], .float) && isVectorOf(a[1], .float) {
            return Resolved(Fn: .outerProduct, Result: shader.DataType.Matrix(columns: a[1].Rows, rows: a[0].Rows))
        }
        return nil
    case "transpose":
        if es3 && n == 1 && a[0].IsMatrix { return Resolved(Fn: .transpose, Result: shader.DataType.Matrix(columns: a[0].Rows, rows: a[0].Columns)) }
        return nil
    case "determinant":
        if es3 && n == 1 && a[0].IsMatrix && a[0].Columns == a[0].Rows { return Resolved(Fn: .determinant, Result: .Float) }
        return nil
    case "inverse":
        if es3 && n == 1 && a[0].IsMatrix && a[0].Columns == a[0].Rows { return Resolved(Fn: .inverse, Result: a[0]) }
        return nil
    case "lessThan", "lessThanEqual", "greaterThan", "greaterThanEqual":
        if n == 2 && a[0].IsVector && a[1] == a[0] && (a[0].IsFloat || a[0].Kind == .int || (es3 && a[0].Kind == .uint)) {
            let fn: shader.Function = name == "lessThan" ? .lessThan : name == "lessThanEqual" ? .lessThanEqual :
                name == "greaterThan" ? .greaterThan : .greaterThanEqual
            return Resolved(Fn: fn, Result: shader.DataType(.bool, rows: a[0].Rows))
        }
        return nil
    case "equal", "notEqual":
        if n == 2 && a[0].IsVector && a[1] == a[0] {
            return Resolved(Fn: name == "equal" ? .equal : .notEqual, Result: shader.DataType(.bool, rows: a[0].Rows))
        }
        return nil
    case "any", "all":
        if n == 1 && isVectorOf(a[0], .bool) { return Resolved(Fn: name == "any" ? .any : .all, Result: .Bool) }
        return nil
    case "not":
        if n == 1 && isVectorOf(a[0], .bool) { return Resolved(Fn: .not, Result: a[0]) }
        return nil
    case "dFdx", "dFdy", "fwidth":
        if !fragment { return nil }
        if !es3 && !extensions.contains("GL_OES_standard_derivatives") { return nil }
        let fn: shader.Function = name == "dFdx" ? .dFdx : name == "dFdy" ? .dFdy : .fwidth
        return gen(fn)
    default:
        return resolveTexture(name, a, fragment: fragment, version: version, extensions: extensions)
    }
}

/// The texture lookups: GLSL ES 1.00's texture2D, textureCube … and
/// 3.00's overloaded texture, textureLod ….
func resolveTexture(_ name: string, _ a: [shader.DataType], fragment: bool, version: int, extensions: [string]) -> Resolved? {
    if a.isEmpty { return nil }
    guard let k = samplerOf(a[0]) else { return nil }
    let n = a.count
    let w = coordWidth(k)
    let result = lookupResult(k)
    func coord(_ t: shader.DataType, _ width: int) -> bool {
        t.IsFloat && !t.IsArray && t.Columns == 1 && t.Rows == width
    }
    let es3 = version >= 300
    if !es3 {
        let is2D = k == .texture2D || k == .external
        let lodExt = extensions.contains("GL_EXT_shader_texture_lod")
        switch name {
        case "texture2D":
            if is2D && (n == 2 || (n == 3 && fragment && isFloatScalar(a[2]))) && coord(a[1], 2) { return Resolved(Fn: .texture, Result: result) }
        case "texture2DProj":
            if is2D && (n == 2 || (n == 3 && fragment && isFloatScalar(a[2]))) && (coord(a[1], 3) || coord(a[1], 4)) {
                return Resolved(Fn: .textureProj, Result: result)
            }
        case "texture2DLod", "texture2DLodEXT":
            if (name == "texture2DLod" ? !fragment : lodExt) && is2D && n == 3 && coord(a[1], 2) && isFloatScalar(a[2]) {
                return Resolved(Fn: .textureLod, Result: result)
            }
        case "texture2DProjLod", "texture2DProjLodEXT":
            if (name == "texture2DProjLod" ? !fragment : lodExt) && is2D && n == 3 && (coord(a[1], 3) || coord(a[1], 4)) && isFloatScalar(a[2]) {
                return Resolved(Fn: .textureProjLod, Result: result)
            }
        case "textureCube":
            if k == .cube && (n == 2 || (n == 3 && fragment && isFloatScalar(a[2]))) && coord(a[1], 3) { return Resolved(Fn: .texture, Result: result) }
        case "textureCubeLod", "textureCubeLodEXT":
            if (name == "textureCubeLod" ? !fragment : lodExt) && k == .cube && n == 3 && coord(a[1], 3) && isFloatScalar(a[2]) {
                return Resolved(Fn: .textureLod, Result: result)
            }
        default:
            break
        }
        return nil
    }
    let shadow = k == .shadow2D || k == .shadowCube || k == .shadowArray2D
    switch name {
    case "texture":
        if (n == 2 || (n == 3 && fragment && isFloatScalar(a[2]) && k != .shadowCube && k != .shadowArray2D)) && coord(a[1], w) {
            return Resolved(Fn: .texture, Result: result)
        }
    case "textureProj":
        if (k == .texture2D || k == .shadow2D || k == .itexture2D || k == .utexture2D || k == .texture3D) &&
            (n == 2 || (n == 3 && fragment && isFloatScalar(a[2]))) && (coord(a[1], w + 1) || (k != .shadow2D && k != .texture3D && coord(a[1], 4))) {
            return Resolved(Fn: .textureProj, Result: result)
        }
    case "textureLod":
        if !shadow || k == .shadow2D {
            if n == 3 && coord(a[1], w) && isFloatScalar(a[2]) { return Resolved(Fn: .textureLod, Result: result) }
        }
    case "textureProjLod":
        if n == 3 && (coord(a[1], w + 1) || coord(a[1], 4)) && isFloatScalar(a[2]) { return Resolved(Fn: .textureProjLod, Result: result) }
    case "textureGrad":
        if n == 4 && coord(a[1], w) { return Resolved(Fn: .textureGrad, Result: result) }
    case "textureOffset":
        if n >= 3 && coord(a[1], w) { return Resolved(Fn: .textureOffset, Result: result) }
    case "texelFetch":
        if n == 3 && !shadow && k != .cube && a[1].Kind == .int && a[1].IsVector && a[2] == .Int {
            return Resolved(Fn: .texelFetch, Result: result)
        }
    case "textureSize":
        if n == 2 && a[1] == .Int {
            let dims = (k == .texture3D || k == .array2D || k == .shadowArray2D) ? 3 : 2
            return Resolved(Fn: .textureSize, Result: shader.DataType(.int, rows: dims))
        }
    default:
        break
    }
    return nil
}
