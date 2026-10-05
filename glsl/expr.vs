package glsl

import (
    "shader"
)

extension Parser {
    // MARK: expressions, by precedence

    /// expression: assignments separated by commas.
    func expression() throws -> shader.Expr {
        var e = try assignment()
        if !isNext(",") { return e }
        var parts = [e]
        while accept(",") { parts.append(try assignment()) }
        e = shader.Expr(.sequence, parts[parts.count - 1].Type, parts)
        return e
    }

    func assignment() throws -> shader.Expr {
        let start = at
        let lhs = try conditional()
        let op = peek().Text
        let compound: shader.BinaryOp?
        switch op {
        case "=": compound = nil
        case "+=": compound = .add
        case "-=": compound = .subtract
        case "*=": compound = .multiply
        case "/=": compound = .divide
        case "%=": compound = .remainder
        case "&=": compound = .bitAnd
        case "|=": compound = .bitOr
        case "^=": compound = .bitXor
        case "<<=": compound = .shiftLeft
        case ">>=": compound = .shiftRight
        default: return lhs
        }
        _ = start
        at += 1
        try checkLvalue(lhs)
        let rhs = try assignment()
        if let c = compound {
            guard let t = binaryType(c, lhs.Type, rhs.Type), t == lhs.Type else {
                throw fail("can't \(op) a \(describe(rhs.Type)) to a \(describe(lhs.Type))")
            }
            return shader.Expr(.compoundAssign(c), lhs.Type, [lhs, rhs])
        }
        if lhs.Type != rhs.Type { throw fail("can't assign a \(describe(rhs.Type)) to a \(describe(lhs.Type))") }
        if lhs.Type.IsArray && !es3 { throw fail("arrays can't be assigned in GLSL ES 1.00") }
        return shader.Expr(.assign, lhs.Type, [lhs, rhs])
    }

    func conditional() throws -> shader.Expr {
        let c = try binary(0)
        if !accept("?") { return c }
        if c.Type != .Bool { throw fail("a ?: condition must be a bool") }
        let a = try expression()
        try expect(":")
        let b = try assignment()
        if a.Type != b.Type { throw fail("?: arms have different types: \(describe(a.Type)) and \(describe(b.Type))") }
        return fold(shader.Expr(.select, a.Type, [c, a, b]))
    }

    /// The operator `text` names and its precedence (vsc_TODO #46: a struct, not a tuple).
    static func binaryOp(_ text: string) -> OperatorInfo? {
        switch text {
        case "||": return OperatorInfo(.logicalOr, 1)
        case "^^": return OperatorInfo(.logicalXor, 2)
        case "&&": return OperatorInfo(.logicalAnd, 3)
        case "|": return OperatorInfo(.bitOr, 4)
        case "^": return OperatorInfo(.bitXor, 5)
        case "&": return OperatorInfo(.bitAnd, 6)
        case "==": return OperatorInfo(.equal, 7)
        case "!=": return OperatorInfo(.notEqual, 7)
        case "<": return OperatorInfo(.less, 8)
        case ">": return OperatorInfo(.greater, 8)
        case "<=": return OperatorInfo(.lessEqual, 8)
        case ">=": return OperatorInfo(.greaterEqual, 8)
        case "<<": return OperatorInfo(.shiftLeft, 9)
        case ">>": return OperatorInfo(.shiftRight, 9)
        case "+": return OperatorInfo(.add, 10)
        case "-": return OperatorInfo(.subtract, 10)
        case "*": return OperatorInfo(.multiply, 11)
        case "/": return OperatorInfo(.divide, 11)
        case "%": return OperatorInfo(.remainder, 11)
        default: return nil
        }
    }

    func binary(_ minPrec: int) throws -> shader.Expr {
        var left = try unary()
        while true {
            let t = peek()
            guard t.Kind == .punct, let info = Parser.binaryOp(t.Text), info.Precedence > minPrec else { break }
            let op = info.Op
            let prec = info.Precedence
            at += 1
            let right = try binary(prec)
            guard let type = binaryType(op, left.Type, right.Type) else {
                throw CompileError(line: t.Line, "'\(t.Text)' doesn't apply to \(describe(left.Type)) and \(describe(right.Type))")
            }
            if !es3 {
                switch op {
                case .remainder, .bitAnd, .bitOr, .bitXor, .shiftLeft, .shiftRight:
                    throw CompileError(line: t.Line, "'\(t.Text)' needs GLSL ES 3.00")
                default: break
                }
            }
            left = fold(shader.Expr(.binary(op), type, [left, right]))
        }
        return left
    }

    func unary() throws -> shader.Expr {
        let t = peek()
        if t.Kind == .punct {
            switch t.Text {
            case "+":
                at += 1
                let e = try unary()
                if !e.Type.IsNumeric || e.Type.Kind == .bool || e.Type.IsArray { throw fail("unary + needs a number") }
                return e
            case "-":
                at += 1
                let e = try unary()
                if !e.Type.IsNumeric || e.Type.Kind == .bool || e.Type.IsArray { throw fail("unary - needs a number") }
                return fold(shader.Expr(.unary(.negate), e.Type, [e]))
            case "!":
                at += 1
                let e = try unary()
                if e.Type != .Bool { throw fail("! needs a bool") }
                return fold(shader.Expr(.unary(.not), e.Type, [e]))
            case "~":
                at += 1
                let e = try unary()
                if !es3 || !e.Type.IsIntegral || e.Type.IsArray { throw fail("~ needs an integer (GLSL ES 3.00)") }
                return fold(shader.Expr(.unary(.complement), e.Type, [e]))
            case "++", "--":
                at += 1
                let e = try unary()
                try checkLvalue(e)
                try checkIncrementable(e)
                return shader.Expr(t.Text == "++" ? .preIncrement : .preDecrement, e.Type, [e])
            default:
                break
            }
        }
        return try postfix()
    }

    func checkIncrementable(_ e: shader.Expr) throws {
        if !e.Type.IsNumeric || e.Type.Kind == .bool || e.Type.IsArray { throw fail("++ and -- need a number") }
    }

    func postfix() throws -> shader.Expr {
        var e = try primary()
        while true {
            if accept("[") {
                let i = try expression()
                try expect("]")
                e = try index(e, i)
            } else if accept(".") {
                let name = try fieldName()
                if name == "length" && isNext("(") && e.Type.IsArray {
                    at += 1
                    try expect(")")
                    if !es3 { throw fail(".length() needs GLSL ES 3.00") }
                    e = shader.Expr.IntConstant(int32(e.Type.ArrayCount))
                    continue
                }
                e = try member(e, name)
            } else if isNext("++") || isNext("--") {
                let inc = next().Text == "++"
                try checkLvalue(e)
                try checkIncrementable(e)
                e = shader.Expr(inc ? .postIncrement : .postDecrement, e.Type, [e])
            } else {
                return e
            }
        }
    }

    func fieldName() throws -> string {
        let t = next()
        if t.Kind != .identifier { throw CompileError(line: t.Line, "expected a field name") }
        return t.Text
    }

    func primary() throws -> shader.Expr {
        let t = peek()
        switch t.Kind {
        case .intLiteral:
            at += 1
            guard let v = parseIntLiteral(t.Text), v <= 0xFFFF_FFFF else { throw CompileError(line: t.Line, "bad integer \(t.Text)") }
            return shader.Expr.Constant(.Int, [uint32(truncatingIfNeeded: v)])
        case .uintLiteral:
            at += 1
            guard let v = parseIntLiteral(t.Text), v <= 0xFFFF_FFFF else { throw CompileError(line: t.Line, "bad integer \(t.Text)") }
            return shader.Expr.Constant(.Uint, [uint32(truncatingIfNeeded: v)])
        case .floatLiteral:
            at += 1
            guard let v = parseFloatLiteral(t.Text) else { throw CompileError(line: t.Line, "bad number \(t.Text)") }
            return shader.Expr.FloatConstant(v)
        case .identifier:
            break
        default:
            if accept("(") {
                let e = try expression()
                try expect(")")
                return e
            }
            throw CompileError(line: t.Line, "expected an expression, found '\(t.Kind == .end ? "end of file" : t.Text)'")
        }
        if t.Text == "true" || t.Text == "false" {
            at += 1
            return shader.Expr.BoolConstant(t.Text == "true")
        }
        // A constructor: a type, then (.
        if startsType() && t.Text != "struct" {
            var type = try typeSpecifierForConstructor()
            try expect("(")
            let args = try callArguments()
            if type.ArrayCount == -1 { type = type.Element.ArrayOf(args.count) }
            return try construct(type, args)
        }
        at += 1
        if isNext("(") {
            at += 1
            let args = try callArguments()
            return try call(t.Text, args, line: t.Line)
        }
        guard let s = lookup(t.Text) else { throw CompileError(line: t.Line, "'\(t.Text)' is not declared") }
        switch s {
        case .variable(let v):
            if v.Storage == .constant && !v.Value.isEmpty {
                return shader.Expr.Constant(v.Type, v.Value)
            }
            if v.Name == "gl_FragDepth" || v.Name == "gl_FragDepthEXT" { module.WritesDepth = true }
            return shader.Expr.Ref(v)
        default:
            throw CompileError(line: t.Line, "'\(t.Text)' is not a variable")
        }
    }

    /// A constructor's type: like a type specifier, but `float[](…)` may leave out its size.
    func typeSpecifierForConstructor() throws -> shader.DataType {
        let save = at
        let t = next()
        var type: shader.DataType
        if let k = typeKeyword(t.Text) {
            type = k
        } else if case .structType(let s)? = lookup(t.Text) {
            type = shader.DataType(.structure(s))
        } else {
            at = save
            throw fail("unknown type '\(t.Text)'")
        }
        if accept("[") {
            if !es3 { throw fail("array constructors need GLSL ES 3.00") }
            if accept("]") {
                type = type.ArrayOf(-1)
            } else {
                type = type.ArrayOf(try arraySize())
            }
        }
        return type
    }

    /// Arguments up to and including ).
    func callArguments() throws -> [shader.Expr] {
        var args: [shader.Expr] = []
        if accept(")") { return args }
        // f(void)
        if isNext("void") && peek(1).Text == ")" {
            at += 2
            return args
        }
        repeat {
            args.append(try assignment())
        } while accept(",")
        try expect(")")
        return args
    }

    // MARK: calls

    func call(_ name: string, _ args: [shader.Expr], line: int) throws -> shader.Expr {
        // A user function first: in 1.00 one may hide a built-in.
        if case .functions(let fs)? = lookup(name) {
            for i in fs {
                let f = module.Functions[i]
                if f.Params.count != args.count { continue }
                var match = true
                for k in 0..<args.count where module.Variables[f.Params[k]].Type != args[k].Type { match = false }
                if !match { continue }
                for k in 0..<args.count where f.Out[k] {
                    try checkLvalue(args[k])
                }
                if !calls.contains(i) { calls.append(i) }
                let e = shader.Expr(.call, f.Result, args)
                e.Index = i
                return e
            }
            if lookupBuiltin(name, args) == nil {
                throw CompileError(line: line, "no overload of \(name) takes (\(args.map { describe($0.Type) }.joined(separator: ", ")))")
            }
        }
        guard let r = lookupBuiltin(name, args) else {
            if lookup(name) == nil && !isBuiltinName(name) {
                throw CompileError(line: line, "'\(name)' is not a function")
            }
            throw CompileError(line: line, "no overload of \(name) takes (\(args.map { describe($0.Type) }.joined(separator: ", ")))")
        }
        if r.Fn == .modf { try checkLvalue(args[1]) }
        return shader.Expr(.builtin(r.Fn), r.Result, args)
    }

    func lookupBuiltin(_ name: string, _ args: [shader.Expr]) -> Resolved? {
        resolveBuiltin(name, args.map { $0.Type }, fragment: fragment, version: version, extensions: extensions)
    }

    func isBuiltinName(_ name: string) -> bool {
        builtinNames.contains(name)
    }

    // MARK: constructors

    func construct(_ t: shader.DataType, _ args: [shader.Expr]) throws -> shader.Expr {
        if args.isEmpty { throw fail("a constructor needs arguments") }
        if t.IsArray {
            if args.count != t.ArrayCount { throw fail("array constructor of \(t.ArrayCount) given \(args.count) values") }
            for a in args where a.Type != t.Element { throw fail("array constructor given a \(describe(a.Type))") }
            return shader.Expr(.construct, t, args)
        }
        if case .structure(let s) = t.Kind {
            let fields = module.Structs[s].Fields
            if args.count != fields.count { throw fail("struct constructor needs \(fields.count) values") }
            for k in 0..<fields.count where args[k].Type != fields[k].Type {
                throw fail("struct field \(fields[k].Name) is a \(describe(fields[k].Type)), not a \(describe(args[k].Type))")
            }
            return shader.Expr(.construct, t, args)
        }
        if !t.IsNumeric { throw fail("can't construct a \(describe(t))") }
        for a in args where !a.Type.IsNumeric || a.Type.IsArray {
            throw fail("can't make a \(describe(t)) from a \(describe(a.Type))")
        }
        let need = t.Components
        if args.count == 1 {
            let a = args[0]
            // A scalar spreads; a matrix from a matrix; a scalar from anything takes its first component.
            if a.Type.IsScalar || (t.IsMatrix && a.Type.IsMatrix) || (t.IsScalar) {
                return fold(shader.Expr(.construct, t, args))
            }
            if t.IsMatrix && !a.Type.IsMatrix && a.Type.Components < need {
                throw fail("not enough values for \(describe(t))")
            }
            if a.Type.Components < need { throw fail("not enough values for \(describe(t))") }
            if a.Type.IsMatrix && !t.IsMatrix && !es3 { throw fail("can't make a \(describe(t)) from a matrix") }
            return fold(shader.Expr(.construct, t, args))
        }
        var have = 0
        for (k, a) in args.enumerated() {
            if have >= need { throw fail("too many values for \(describe(t)) (argument \(k + 1))") }
            if t.IsMatrix && a.Type.IsMatrix { throw fail("a matrix argument must be alone") }
            have += a.Type.Components
        }
        if have < need { throw fail("not enough values for \(describe(t))") }
        return fold(shader.Expr(.construct, t, args))
    }

    // MARK: members and indexing

    func member(_ e: shader.Expr, _ name: string) throws -> shader.Expr {
        if case .structure(let s) = e.Type.Kind, !e.Type.IsArray {
            let fields = module.Structs[s].Fields
            guard let k = fields.firstIndex(where: { $0.Name == name }) else { throw fail("struct has no field \(name)") }
            let f = shader.Expr(.field, fields[k].Type, [e])
            f.Index = k
            return foldField(f)
        }
        // A swizzle of a vector (or, in 3.00, a scalar).
        if !(e.Type.IsVector || (es3 && e.Type.IsScalar)) { throw fail("\(describe(e.Type)) has no member \(name)") }
        let sets = ["xyzw", "rgba", "stpq"]
        var comps: [int] = []
        var whichSet = -1
        for c in name.utf8 {
            var found = false
            for (si, set) in sets.enumerated() {
                if let k = Array(set.utf8).firstIndex(of: c) {
                    if whichSet >= 0 && whichSet != si { throw fail("swizzle \(name) mixes component sets") }
                    whichSet = si
                    comps.append(k)
                    found = true
                }
            }
            if !found { throw fail("bad swizzle .\(name)") }
        }
        if comps.isEmpty || comps.count > 4 { throw fail("bad swizzle .\(name)") }
        for k in comps where k >= e.Type.Rows { throw fail("swizzle .\(name) is past the end of a \(describe(e.Type))") }
        let s = shader.Expr(.swizzle, shader.DataType(e.Type.Kind, rows: comps.count), [e])
        s.Components = comps
        return fold(s)
    }

    func foldField(_ f: shader.Expr) -> shader.Expr {
        let base = f.Args[0]
        if !base.IsConstant { return f }
        guard case .structure(let s) = base.Type.Kind else { return f }
        var offset = 0
        for k in 0..<f.Index { offset += module.Slots(module.Structs[s].Fields[k].Type) }
        let width = module.Slots(f.Type)
        if offset + width > base.Value.count { return f }
        return shader.Expr.Constant(f.Type, Array(base.Value[offset..<offset + width]))
    }

    func index(_ e: shader.Expr, _ i: shader.Expr) throws -> shader.Expr {
        if i.Type != .Int && i.Type != .Uint { throw fail("an index must be an integer") }
        var result: shader.DataType
        var size: int
        if e.Type.IsArray {
            result = e.Type.Element
            size = e.Type.ArrayCount
        } else if e.Type.IsMatrix {
            result = e.Type.ColumnType
            size = e.Type.Columns
        } else if e.Type.IsVector {
            result = e.Type.ComponentType
            size = e.Type.Rows
        } else {
            throw fail("a \(describe(e.Type)) can't be indexed")
        }
        if i.IsConstant {
            let k = int(int32(bitPattern: i.Value[0]))
            if k < 0 || k >= size { throw fail("index \(k) is out of range (0..<\(size))") }
        }
        let x = shader.Expr(.index, result, [e, i])
        if e.IsConstant && i.IsConstant && !e.Type.IsStruct && !result.IsStruct {
            let width = module.Slots(result)
            let k = int(int32(bitPattern: i.Value[0]))
            if (k + 1) * width <= e.Value.count {
                return shader.Expr.Constant(result, Array(e.Value[(k * width)..<((k + 1) * width)]))
            }
        }
        return x
    }

    // MARK: lvalues

    func checkLvalue(_ e: shader.Expr) throws {
        switch e.Op {
        case .variable:
            let v = module.Variables[e.Index]
            switch v.Storage {
            case .uniform: throw fail("uniform \(v.Name) can't be written")
            case .input: throw fail("input \(v.Name) can't be written")
            case .constant: throw fail("const \(v.Name) can't be written")
            case .builtin(let b):
                switch b {
                case .fragCoord, .frontFacing, .pointCoord, .vertexId, .instanceId, .depthRangeNear, .depthRangeFar:
                    throw fail("\(v.Name) can't be written")
                default:
                    break
                }
            default:
                break
            }
        case .swizzle:
            var seen: [int] = []
            for c in e.Components {
                if seen.contains(c) { throw fail("a swizzle written to can't repeat a component") }
                seen.append(c)
            }
            try checkLvalue(e.Args[0])
        case .index, .field:
            try checkLvalue(e.Args[0])
        default:
            throw fail("can't write to this expression")
        }
    }
}

/// A binary operator and how tightly it binds.
struct OperatorInfo {
    let Op: shader.BinaryOp
    let Precedence: int

    init(_ op: shader.BinaryOp, _ precedence: int) {
        Op = op
        Precedence = precedence
    }
}

/// The result type of `a op b`, or nil when GLSL doesn't allow it.
func binaryType(_ op: shader.BinaryOp, _ a: shader.DataType, _ b: shader.DataType) -> shader.DataType? {
    if a.IsArray || b.IsArray || a.IsSampler || b.IsSampler {
        if (op == .equal || op == .notEqual) && a == b && !a.IsSampler { return .Bool }
        return nil
    }
    switch op {
    case .logicalAnd, .logicalOr, .logicalXor:
        return a == .Bool && b == .Bool ? .Bool : nil
    case .equal, .notEqual:
        return a == b ? .Bool : nil
    case .less, .lessEqual, .greater, .greaterEqual:
        return a == b && a.IsScalar && a.Kind != .bool ? .Bool : nil
    case .shiftLeft, .shiftRight:
        if !a.IsIntegral || !b.IsIntegral || a.IsMatrix || b.IsMatrix { return nil }
        if b.IsScalar || b.Rows == a.Rows { return a }
        return nil
    case .bitAnd, .bitOr, .bitXor, .remainder:
        if !a.IsIntegral || a.Kind != b.Kind { return nil }
        if a == b { return a }
        if a.IsScalar { return b }
        if b.IsScalar { return a }
        return nil
    default:
        break
    }
    // + - * /
    if a.Kind != b.Kind || a.Kind == .bool || a.IsStruct || b.IsStruct { return nil }
    if op == .multiply && a.IsMatrix && b.IsMatrix {
        return a.Columns == b.Rows ? shader.DataType.Matrix(columns: b.Columns, rows: a.Rows) : nil
    }
    if op == .multiply && a.IsVector && b.IsMatrix {
        return a.Rows == b.Rows ? shader.DataType.Vector(.float, b.Columns) : nil
    }
    if op == .multiply && a.IsMatrix && b.IsVector {
        return a.Columns == b.Rows ? shader.DataType.Vector(.float, a.Rows) : nil
    }
    if a == b { return a }
    if a.IsScalar { return b }
    if b.IsScalar { return a }
    return nil
}

/// The built-in function names, for telling "no such function" from "no such overload".
let builtinNames: [string] = [
    "radians", "degrees", "sin", "cos", "tan", "asin", "acos", "atan", "sinh", "cosh", "tanh", "asinh", "acosh", "atanh",
    "pow", "exp", "log", "exp2", "log2", "sqrt", "inversesqrt", "abs", "sign", "floor", "trunc", "round", "roundEven",
    "ceil", "fract", "mod", "modf", "min", "max", "clamp", "mix", "step", "smoothstep", "isnan", "isinf",
    "floatBitsToInt", "floatBitsToUint", "intBitsToFloat", "uintBitsToFloat", "packSnorm2x16", "unpackSnorm2x16",
    "packUnorm2x16", "unpackUnorm2x16", "packHalf2x16", "unpackHalf2x16", "length", "distance", "dot", "cross",
    "normalize", "faceforward", "reflect", "refract", "matrixCompMult", "outerProduct", "transpose", "determinant",
    "inverse", "lessThan", "lessThanEqual", "greaterThan", "greaterThanEqual", "equal", "notEqual", "any", "all", "not",
    "texture2D", "texture2DProj", "texture2DLod", "texture2DProjLod", "textureCube", "textureCubeLod", "texture2DLodEXT",
    "texture2DProjLodEXT", "textureCubeLodEXT", "texture", "textureProj", "textureLod", "textureProjLod", "textureGrad",
    "textureOffset", "texelFetch", "textureSize", "dFdx", "dFdy", "fwidth",
]
