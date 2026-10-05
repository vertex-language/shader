package glsl

import (
    "math"
    "shader"
)

// Constant folding: the values of constant expressions, which GLSL needs
// for array sizes, `const` variables and (in 1.00) global initializers.
// Values are component bit patterns, as shader.Expr.Value holds them.

func f32(_ bits: uint32) -> float32 { float32(bitPattern: bits) }
func bitsOf(_ f: float32) -> uint32 { f.bitPattern }
func i32(_ bits: uint32) -> int32 { int32(bitPattern: bits) }
func bitsOfInt(_ i: int32) -> uint32 { uint32(bitPattern: i) }

/// The value of a constant operand, `n` components wide: a scalar spreads.
func spread(_ e: shader.Expr, _ n: int) -> [uint32] {
    if e.Value.count == n { return e.Value }
    if e.Value.count == 1 { return [uint32](repeating: e.Value[0], count: n) }
    return e.Value
}

/// Folds `e` if its operands are constants; returns it unchanged otherwise.
func fold(_ e: shader.Expr) -> shader.Expr {
    for a in e.Args where !a.IsConstant { return e }
    let t = e.Type
    switch e.Op {
    case .swizzle:
        let v = e.Args[0].Value
        return shader.Expr.Constant(t, e.Components.map { v[$0] })
    case .index:
        let base = e.Args[0]
        let i = int(i32(e.Args[1].Value[0]))
        let width = base.Type.IsArray ? (base.Value.count / max(1, base.Type.ArrayCount)) : (base.Type.IsMatrix ? base.Type.Rows : 1)
        if i < 0 || (i + 1) * width > base.Value.count { return e }
        return shader.Expr.Constant(t, Array(base.Value[(i * width)..<((i + 1) * width)]))
    case .construct:
        if let v = constructValue(t, e.Args) { return shader.Expr.Constant(t, v) }
        return e
    case .unary(let op):
        let v = e.Args[0].Value
        var out: [uint32] = []
        for x in v {
            switch op {
            case .negate:
                out.append(t.Kind == .float ? bitsOf(-f32(x)) : bitsOfInt(0 &- i32(x)))
            case .not:
                out.append(x == 0 ? 1 : 0)
            case .complement:
                out.append(~x)
            }
        }
        return shader.Expr.Constant(t, out)
    case .binary(let op):
        let a = e.Args[0]
        let b = e.Args[1]
        // Linear-algebra products aren't folded; nothing needs them constant.
        if op == .multiply && (a.Type.IsMatrix || b.Type.IsMatrix) { return e }
        if op == .equal || op == .notEqual {
            let same = a.Value == b.Value
            return shader.Expr.BoolConstant(op == .equal ? same : !same)
        }
        let kind = a.Type.Kind
        let n = max(a.Value.count, b.Value.count)
        let x = spread(a, n)
        let y = spread(b, n)
        var out: [uint32] = []
        for k in 0..<n {
            guard let r = foldScalar(op, kind, x[k], y[k]) else { return e }
            out.append(r)
        }
        return shader.Expr.Constant(t, out)
    case .select:
        return e.Args[0].Value.first == 1 ? e.Args[1] : e.Args[2]
    default:
        return e
    }
}

func foldScalar(_ op: shader.BinaryOp, _ kind: shader.Kind, _ x: uint32, _ y: uint32) -> uint32? {
    switch kind {
    case .float:
        let a = f32(x)
        let b = f32(y)
        switch op {
        case .add: return bitsOf(a + b)
        case .subtract: return bitsOf(a - b)
        case .multiply: return bitsOf(a * b)
        case .divide: return bitsOf(a / b)
        case .less: return a < b ? 1 : 0
        case .lessEqual: return a <= b ? 1 : 0
        case .greater: return a > b ? 1 : 0
        case .greaterEqual: return a >= b ? 1 : 0
        default: return nil
        }
    case .int:
        let a = i32(x)
        let b = i32(y)
        switch op {
        case .add: return bitsOfInt(a &+ b)
        case .subtract: return bitsOfInt(a &- b)
        case .multiply: return bitsOfInt(a &* b)
        case .divide: return b == 0 ? nil : bitsOfInt(a / b)
        case .remainder: return b == 0 ? nil : bitsOfInt(a % b)
        case .less: return a < b ? 1 : 0
        case .lessEqual: return a <= b ? 1 : 0
        case .greater: return a > b ? 1 : 0
        case .greaterEqual: return a >= b ? 1 : 0
        case .bitAnd: return x & y
        case .bitOr: return x | y
        case .bitXor: return x ^ y
        case .shiftLeft: return x << (y & 31)
        case .shiftRight: return bitsOfInt(a >> int32(y & 31))
        default: return nil
        }
    case .uint:
        switch op {
        case .add: return x &+ y
        case .subtract: return x &- y
        case .multiply: return x &* y
        case .divide: return y == 0 ? nil : x / y
        case .remainder: return y == 0 ? nil : x % y
        case .less: return x < y ? 1 : 0
        case .lessEqual: return x <= y ? 1 : 0
        case .greater: return x > y ? 1 : 0
        case .greaterEqual: return x >= y ? 1 : 0
        case .bitAnd: return x & y
        case .bitOr: return x | y
        case .bitXor: return x ^ y
        case .shiftLeft: return x << (y & 31)
        case .shiftRight: return x >> (y & 31)
        default: return nil
        }
    case .bool:
        switch op {
        case .logicalAnd: return (x != 0 && y != 0) ? 1 : 0
        case .logicalOr: return (x != 0 || y != 0) ? 1 : 0
        case .logicalXor: return (x != 0) != (y != 0) ? 1 : 0
        default: return nil
        }
    default:
        return nil
    }
}

/// One component converted from `from` to `to`.
func convertScalar(_ bits: uint32, from: shader.Kind, to: shader.Kind) -> uint32 {
    if from == to { return bits }
    switch to {
    case .float:
        switch from {
        case .int: return bitsOf(float32(i32(bits)))
        case .uint: return bitsOf(float32(bits))
        default: return bitsOf(bits != 0 ? 1 : 0)
        }
    case .int:
        switch from {
        case .float:
            let f = f32(bits)
            if f.isNaN { return 0 }
            return bitsOfInt(int32(max(-2147483648, min(2147483647, f.rounded(.towardZero)))))
        case .uint: return bits
        default: return bits != 0 ? 1 : 0
        }
    case .uint:
        switch from {
        case .float:
            let f = f32(bits)
            if f.isNaN || f <= 0 { return 0 }
            return uint32(min(4294967295, f.rounded(.towardZero)))
        case .int: return bits
        default: return bits != 0 ? 1 : 0
        }
    default:
        switch from {
        case .float: return f32(bits) != 0 ? 1 : 0
        default: return bits != 0 ? 1 : 0
        }
    }
}

/// The components a constructor of `t` makes from constant arguments, or
/// nil when it can't tell (structs, arrays).
func constructValue(_ t: shader.DataType, _ args: [shader.Expr]) -> [uint32]? {
    if !t.IsNumeric || t.IsArray { return nil }
    let n = t.Components
    // One scalar: a vector spreads it; a matrix puts it on the diagonal.
    if args.count == 1 && args[0].Type.IsScalar {
        let v = convertScalar(args[0].Value[0], from: args[0].Type.Kind, to: t.Kind)
        if t.IsMatrix {
            var out = [uint32](repeating: bitsOf(0), count: n)
            for c in 0..<min(t.Columns, t.Rows) { out[c * t.Rows + c] = v }
            return out
        }
        return [uint32](repeating: v, count: n)
    }
    // A matrix from a matrix: the overlap, the rest from the identity.
    if args.count == 1 && args[0].Type.IsMatrix && t.IsMatrix {
        let src = args[0]
        var out: [uint32] = []
        for c in 0..<t.Columns {
            for r in 0..<t.Rows {
                if c < src.Type.Columns && r < src.Type.Rows {
                    out.append(src.Value[c * src.Type.Rows + r])
                } else {
                    out.append(bitsOf(c == r ? 1 : 0))
                }
            }
        }
        return out
    }
    var comps: [uint32] = []
    for a in args {
        for v in a.Value { comps.append(convertScalar(v, from: a.Type.Kind, to: t.Kind)) }
    }
    if comps.count < n { return nil }
    return Array(comps[0..<n])
}

/// A float literal's value: decimal digits, optional exponent, optional f.
func parseFloatLiteral(_ text: string) -> float32? {
    var t = text
    if t.hasSuffix("f") || t.hasSuffix("F") { t = string(t.dropLast()) }
    if let d = float64(t) { return float32(d) }
    return nil
}

let mathPi = math.Pi
