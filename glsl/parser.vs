package glsl

import (
    "shader"
)

/// What a name means in a scope.
enum Symbol {
    case variable(shader.Variable)
    /// User functions of this name: Module.Functions indices.
    case functions([int])
    /// Module.Structs index.
    case structType(int)
}

/// A declaration's qualifiers.
struct Qualifiers {
    var storage = ""        // "", const, attribute, varying, uniform, in, out, inout
    var precision = shader.Precision.none
    var invariant = false
    var flat = false
    var centroid = false
    var location = -1
    var any = false

    init() {}
}

/// The parser, which is also the type checker: GLSL declares everything
/// before use, so each expression's type is known as it is read.
final class Parser {
    let tokens: [Token]
    var at = 0
    let module: shader.Module
    let version: int
    let fragment: bool
    let extensions: [string]
    var scopes: [[string: Symbol]] = [[:]]
    /// The function being read, and its result type.
    var function: shader.FunctionDef? = nil
    var loopDepth = 0
    var switchDepth = 0
    var counter = 0

    init(tokens: [Token], stage: shader.Stage, version: int, extensions: [string]) {
        self.tokens = tokens
        module = shader.Module(stage: stage)
        module.Version = version
        module.Extensions = extensions
        self.version = version
        fragment = stage == .fragment
        self.extensions = extensions
    }

    var es3: bool { version >= 300 }

    // MARK: tokens

    func peek(_ k: int = 0) -> Token {
        let i = at + k
        return i < tokens.count ? tokens[i] : tokens[tokens.count - 1]
    }

    func next() -> Token {
        let t = peek()
        if at < tokens.count - 1 { at += 1 }
        return t
    }

    func isNext(_ text: string) -> bool {
        let t = peek()
        return t.Text == text && (t.Kind == .punct || t.Kind == .identifier)
    }

    func accept(_ text: string) -> bool {
        if isNext(text) {
            at += 1
            return true
        }
        return false
    }

    func expect(_ text: string) throws {
        if !accept(text) {
            let t = peek()
            throw CompileError(line: t.Line, "expected '\(text)', found '\(t.Kind == .end ? "end of file" : t.Text)'")
        }
    }

    func fail(_ message: string) -> CompileError {
        CompileError(line: peek().Line, message)
    }

    func identifier() throws -> string {
        let t = peek()
        if t.Kind != .identifier || keywords.contains(t.Text) || typeKeyword(t.Text) != nil {
            throw fail("expected a name, found '\(t.Text)'")
        }
        if t.Text.hasPrefix("gl_") { throw fail("names beginning gl_ are reserved") }
        at += 1
        return t.Text
    }

    // MARK: scopes

    func lookup(_ name: string) -> Symbol? {
        var i = scopes.count - 1
        while i >= 0 {
            if let s = scopes[i][name] { return s }
            i -= 1
        }
        return nil
    }

    func declare(_ name: string, _ s: Symbol) throws {
        if scopes[scopes.count - 1][name] != nil {
            if case .functions = s {} else { throw fail("'\(name)' is already declared in this scope") }
        }
        scopes[scopes.count - 1][name] = s
    }

    func push() { scopes.append([:]) }
    func pop() { scopes.removeLast() }

    func variable(_ name: string, _ type: shader.DataType, _ storage: shader.Storage) -> shader.Variable {
        module.Add(shader.Variable(name: name, type: type, storage: storage))
    }

    // MARK: the translation unit

    func parse() throws -> shader.Module {
        declareBuiltins()
        while peek().Kind != .end {
            try external()
        }
        guard case .functions(let fs)? = scopes[0]["main"],
              let m = fs.first(where: { module.Functions[$0].Defined && module.Functions[$0].Params.isEmpty }) else {
            throw CompileError(line: peek().Line, "no main function")
        }
        if module.Functions[m].Result != .Void { throw CompileError(line: 0, "main must return void") }
        module.EntryPoint = m
        for f in module.Functions where !f.Defined {
            if isCalled(f) { throw CompileError(line: 0, "function \(f.Name) is called but never defined") }
        }
        // A 3.00 fragment shader's only output goes to location 0.
        let outs = module.VariablesIn(.output)
        if fragment && outs.count == 1 && outs[0].Location < 0 { outs[0].Location = 0 }
        return module
    }

    func isCalled(_ f: shader.FunctionDef) -> bool {
        guard let idx = module.Functions.firstIndex(where: { $0 === f }) else { return false }
        return calls.contains(idx)
    }

    var calls: [int] = []

    func declareBuiltins() {
        func add(_ name: string, _ t: shader.DataType, _ b: shader.Builtin) {
            let v = variable(name, t, .builtin(b))
            scopes[0][name] = .variable(v)
        }
        let v4 = shader.DataType.Vector(.float, 4)
        if fragment {
            add("gl_FragCoord", v4, .fragCoord)
            add("gl_FrontFacing", .Bool, .frontFacing)
            add("gl_PointCoord", shader.DataType.Vector(.float, 2), .pointCoord)
            if es3 {
                add("gl_FragDepth", .Float, .fragDepth)
            } else {
                add("gl_FragColor", v4, .fragColor)
                add("gl_FragData", v4.ArrayOf(1), .fragData)
                if extensions.contains("GL_EXT_frag_depth") { add("gl_FragDepthEXT", .Float, .fragDepth) }
            }
        } else {
            add("gl_Position", v4, .position)
            add("gl_PointSize", .Float, .pointSize)
            if es3 {
                add("gl_VertexID", .Int, .vertexId)
                add("gl_InstanceID", .Int, .instanceId)
            }
        }
        func constant(_ name: string, _ v: int) {
            let c = variable(name, .Int, .constant)
            c.Value = [uint32(bitPattern: int32(v))]
            scopes[0][name] = .variable(c)
        }
        let l = shader.Limits()
        constant("gl_MaxVertexAttribs", l.VertexAttribs)
        constant("gl_MaxVertexUniformVectors", l.VertexUniformVectors)
        constant("gl_MaxFragmentUniformVectors", l.FragmentUniformVectors)
        constant("gl_MaxVertexTextureImageUnits", l.VertexTextureUnits)
        constant("gl_MaxCombinedTextureImageUnits", l.CombinedTextureUnits)
        constant("gl_MaxTextureImageUnits", l.FragmentTextureUnits)
        constant("gl_MaxDrawBuffers", es3 ? l.DrawBuffers : 1)
        if es3 {
            constant("gl_MaxVertexOutputVectors", l.VaryingVectors + 1)
            constant("gl_MaxFragmentInputVectors", l.VaryingVectors)
            constant("gl_MinProgramTexelOffset", -8)
            constant("gl_MaxProgramTexelOffset", 7)
        } else {
            constant("gl_MaxVaryingVectors", l.VaryingVectors)
        }
    }

    func external() throws {
        if accept(";") { return }
        if accept("precision") {
            _ = try precisionQualifier()
            _ = try typeSpecifier()
            try expect(";")
            return
        }
        let q = try qualifiers()
        // `invariant gl_Position;`, `layout(...) in;`
        if q.any && accept(";") { return }
        if q.invariant && peek().Kind == .identifier && peek(1).Text == ";" {
            at += 2
            return
        }
        let type = try typeSpecifier(qualifiers: q)
        if accept(";") { return }   // a struct declared without a variable
        let name = try identifier()
        if isNext("(") {
            try functionDeclaration(q, type, name)
            return
        }
        try declarators(q, type, name, global: true)
    }

    func precisionQualifier() throws -> shader.Precision {
        let t = next()
        switch t.Text {
        case "highp": return .high
        case "mediump": return .medium
        case "lowp": return .low
        default: throw CompileError(line: t.Line, "expected a precision")
        }
    }

    func qualifiers() throws -> Qualifiers {
        var q = Qualifiers()
        while true {
            let t = peek().Text
            switch t {
            case "const", "attribute", "varying", "uniform":
                if t == "attribute" && (fragment || es3) { throw fail("attribute is not allowed here") }
                if t == "varying" && es3 { throw fail("varying is not allowed in GLSL ES 3.00") }
                q.storage = t
            case "in", "out":
                if !es3 { throw fail("'\(t)' as a storage qualifier needs GLSL ES 3.00") }
                q.storage = t
            case "highp", "mediump", "lowp":
                q.precision = try precisionQualifier()
                q.any = true
                continue
            case "invariant": q.invariant = true
            case "flat":
                if !es3 { throw fail("flat needs GLSL ES 3.00") }
                q.flat = true
            case "smooth": break
            case "centroid": q.centroid = true
            case "layout":
                at += 1
                try expect("(")
                while !accept(")") {
                    let key = next().Text
                    if accept("=") {
                        let v = next()
                        if key == "location", let n = parseIntLiteral(v.Text) { q.location = n }
                    }
                    _ = accept(",")
                }
                q.any = true
                continue
            default:
                return q
            }
            at += 1
            q.any = true
        }
    }

    // MARK: types

    /// The type a type keyword names, or nil.
    func typeKeyword(_ name: string) -> shader.DataType? {
        switch name {
        case "void": return .Void
        case "float": return .Float
        case "int": return .Int
        case "bool": return .Bool
        case "vec2", "vec3", "vec4": return shader.DataType.Vector(.float, int(name.utf8.last! - 0x30))
        case "bvec2", "bvec3", "bvec4": return shader.DataType.Vector(.bool, int(name.utf8.last! - 0x30))
        case "ivec2", "ivec3", "ivec4": return shader.DataType.Vector(.int, int(name.utf8.last! - 0x30))
        case "mat2", "mat3", "mat4":
            let n = int(name.utf8.last! - 0x30)
            return shader.DataType.Matrix(columns: n, rows: n)
        case "sampler2D": return shader.DataType(.sampler(.texture2D))
        case "samplerCube": return shader.DataType(.sampler(.cube))
        case "samplerExternalOES":
            return extensions.contains("GL_OES_EGL_image_external") || extensions.contains("GL_OES_EGL_image_external_essl3")
                ? shader.DataType(.sampler(.external)) : nil
        default:
            break
        }
        if !es3 { return nil }
        switch name {
        case "uint": return .Uint
        case "uvec2", "uvec3", "uvec4": return shader.DataType.Vector(.uint, int(name.utf8.last! - 0x30))
        case "mat2x2", "mat2x3", "mat2x4", "mat3x2", "mat3x3", "mat3x4", "mat4x2", "mat4x3", "mat4x4":
            let b = Array(name.utf8)
            return shader.DataType.Matrix(columns: int(b[3] - 0x30), rows: int(b[5] - 0x30))
        case "sampler3D": return shader.DataType(.sampler(.texture3D))
        case "sampler2DArray": return shader.DataType(.sampler(.array2D))
        case "sampler2DShadow": return shader.DataType(.sampler(.shadow2D))
        case "samplerCubeShadow": return shader.DataType(.sampler(.shadowCube))
        case "sampler2DArrayShadow": return shader.DataType(.sampler(.shadowArray2D))
        case "isampler2D": return shader.DataType(.sampler(.itexture2D))
        case "usampler2D": return shader.DataType(.sampler(.utexture2D))
        default: return nil
        }
    }

    /// Whether the next tokens start a type (a keyword or a struct's name).
    func startsType() -> bool {
        let t = peek()
        if t.Kind != .identifier { return false }
        if t.Text == "struct" || typeKeyword(t.Text) != nil { return true }
        if case .structType? = lookup(t.Text) { return true }
        return false
    }

    func typeSpecifier() throws -> shader.DataType {
        try typeSpecifier(qualifiers: Qualifiers())   // vsc_TODO #45: not a default argument
    }

    func typeSpecifier(qualifiers q: Qualifiers) throws -> shader.DataType {
        let t = peek()
        var type: shader.DataType
        if t.Text == "struct" {
            at += 1
            type = try structSpecifier()
        } else if let k = typeKeyword(t.Text) {
            at += 1
            type = k
        } else if case .structType(let s)? = lookup(t.Text) {
            at += 1
            type = shader.DataType(.structure(s))
        } else {
            throw fail("unknown type '\(t.Text)'")
        }
        // 3.00's `float[3] a;`
        if isNext("[") && es3 {
            at += 1
            let n = try arraySize()
            type = type.ArrayOf(n)
        }
        return type
    }

    func structSpecifier() throws -> shader.DataType {
        var name = ""
        if peek().Kind == .identifier && !isNext("{") { name = try identifier() }
        let st = shader.StructType(name: name.isEmpty ? "__anon\(module.Structs.count)" : name)
        let index = module.Structs.count
        module.Structs.append(st)
        try expect("{")
        while !accept("}") {
            _ = try qualifiers()
            let ft = try typeSpecifier()
            repeat {
                let fname = try identifier()
                var t = ft
                if accept("[") { t = ft.ArrayOf(try arraySize()) }
                if st.Fields.contains(where: { $0.Name == fname }) { throw fail("field \(fname) is declared twice") }
                st.Fields.append(shader.Field(name: fname, type: t))
            } while accept(",")
            try expect(";")
        }
        if !name.isEmpty { try declare(name, .structType(index)) }
        return shader.DataType(.structure(index))
    }

    /// A constant integral expression inside [ ], and the ].
    func arraySize() throws -> int {
        let e = try conditional()
        try expect("]")
        guard e.IsConstant, e.Type == .Int || e.Type == .Uint else { throw fail("array size must be a constant integer") }
        let n = int(int32(bitPattern: e.Value[0]))
        if n <= 0 { throw fail("array size must be positive") }
        return n
    }

    // MARK: declarations

    func storage(_ q: Qualifiers, global: bool) throws -> shader.Storage {
        switch q.storage {
        case "const": return .constant
        case "uniform":
            if !global { throw fail("uniforms must be global") }
            return .uniform
        case "attribute": return .input
        case "varying": return fragment ? .input : .output
        case "in": return .input
        case "out": return .output
        default: return global ? .global : .local
        }
    }

    func declarators(_ q: Qualifiers, _ base: shader.DataType, _ firstName: string, global: bool) throws {
        var name = firstName
        while true {
            var t = base
            if accept("[") {
                if es3 && isNext("]") && base.IsArray == false {
                    at += 1
                    t = base.ArrayOf(-1)   // sized by its initializer
                } else {
                    t = base.ArrayOf(try arraySize())
                }
            }
            if t.Kind == .void { throw fail("a variable can't be void") }
            let st = try storage(q, global: global)
            var initExpr: shader.Expr? = nil
            if accept("=") {
                if st == .uniform || st == .input || st == .output { throw fail("\(q.storage) variables can't be initialized") }
                var e = try assignment()
                if t.ArrayCount == -1 && e.Type.IsArray { t = t.Element.ArrayOf(e.Type.ArrayCount) }
                e = try coerceForInit(e, t)
                initExpr = e
            } else if st == .constant {
                throw fail("const variable \(name) needs an initializer")
            }
            if t.ArrayCount == -1 { throw fail("array \(name) needs a size") }
            let v = variable(name, t, st)
            v.Precision = q.precision
            v.Location = q.location
            v.Flat = q.flat
            if st == .constant {
                if let e = initExpr, e.IsConstant {
                    v.Value = e.Value
                } else if !es3 || global {
                    throw fail("const variable \(name) needs a constant initializer")
                }
            }
            try declare(name, .variable(v))
            if let e = initExpr {
                let s = shader.Stmt(.declare)
                s.Index = v.Index
                s.Expr = e
                if global {
                    module.Init.append(s)
                } else {
                    pendingDeclarations.append(s)
                }
            } else if !global && st == .local {
                let s = shader.Stmt(.declare)
                s.Index = v.Index
                pendingDeclarations.append(s)
            }
            if !accept(",") { break }
            name = try identifier()
        }
        try expect(";")
    }

    /// Declarations a statement made, for the statement list.
    var pendingDeclarations: [shader.Stmt] = []

    func coerceForInit(_ e: shader.Expr, _ t: shader.DataType) throws -> shader.Expr {
        if e.Type != t { throw fail("can't initialize a \(describe(t)) with a \(describe(e.Type))") }
        return e
    }

    // MARK: functions

    func functionDeclaration(_ q: Qualifiers, _ result: shader.DataType, _ name: string) throws {
        if q.storage != "" && q.storage != "const" { throw fail("a function can't be \(q.storage)") }
        try expect("(")
        var paramTypes: [shader.DataType] = []
        var paramNames: [string] = []
        var ins: [bool] = []
        var outs: [bool] = []
        if !accept(")") {
            // `void` alone is an empty list.
            if isNext("void") && peek(1).Text == ")" {
                at += 2
            } else {
                repeat {
                    var dir = "in"
                    while true {
                        let t = peek().Text
                        if t == "in" || t == "out" || t == "inout" { dir = t; at += 1; continue }
                        if t == "const" || t == "highp" || t == "mediump" || t == "lowp" { at += 1; continue }
                        break
                    }
                    var pt = try typeSpecifier()
                    var pname = ""
                    if peek().Kind == .identifier && !isNext(",") && !isNext(")") {
                        pname = try identifier()
                    }
                    if accept("[") { pt = pt.ArrayOf(try arraySize()) }
                    if pt.Kind == .void { throw fail("a parameter can't be void") }
                    paramTypes.append(pt)
                    paramNames.append(pname)
                    ins.append(dir != "out")
                    outs.append(dir != "in")
                } while accept(",")
                try expect(")")
            }
        }
        // The same signature declared before is the same function.
        var index = -1
        if case .functions(let fs)? = lookup(name) {
            for i in fs {
                let f = module.Functions[i]
                if f.Params.map({ module.Variables[$0].Type }) == paramTypes {
                    if f.Result != result { throw fail("\(name) is redeclared with another result type") }
                    index = i
                }
            }
        }
        if index < 0 {
            let f = shader.FunctionDef(name: name, result: result)
            index = module.Functions.count
            module.Functions.append(f)
            var list: [int] = []
            if case .functions(let fs)? = scopes[0][name] { list = fs }
            list.append(index)
            scopes[0][name] = .functions(list)
        }
        let f = module.Functions[index]
        // Fresh parameter variables, named for this declaration.
        var params: [int] = []
        for i in 0..<paramTypes.count {
            params.append(variable(paramNames[i], paramTypes[i], .local).Index)
        }
        f.Params = params
        f.In = ins
        f.Out = outs
        if accept(";") { return }
        if f.Defined { throw fail("function \(name) is defined twice") }
        f.Defined = true
        push()
        for i in 0..<params.count where !paramNames[i].isEmpty {
            try declare(paramNames[i], .variable(module.Variables[params[i]]))
        }
        function = f
        try expect("{")
        f.Body = try statementsUntilClose()
        function = nil
        pop()
    }

    // MARK: statements

    /// Statements up to a closing brace (consumed).
    func statementsUntilClose() throws -> [shader.Stmt] {
        var out: [shader.Stmt] = []
        while !accept("}") {
            if peek().Kind == .end { throw fail("missing '}'") }
            out += try statement()
        }
        return out
    }

    /// One statement; a declaration may make several.
    func statement() throws -> [shader.Stmt] {
        let t = peek()
        switch t.Text {
        case "{":
            at += 1
            push()
            let b = shader.Stmt(.block)
            b.Body = try statementsUntilClose()
            pop()
            return [b]
        case ";":
            at += 1
            return []
        case "if":
            at += 1
            try expect("(")
            let c = try expression()
            if c.Type != .Bool { throw fail("an if condition must be a bool") }
            try expect(")")
            let s = shader.Stmt(.ifElse)
            s.Expr = c
            s.Body = try scoped()
            if accept("else") { s.Else = try scoped() }
            return [s]
        case "while":
            at += 1
            try expect("(")
            let c = try expression()
            if c.Type != .Bool { throw fail("a while condition must be a bool") }
            try expect(")")
            let s = shader.Stmt(.loop)
            s.Expr = c
            loopDepth += 1
            s.Body = try scoped()
            loopDepth -= 1
            return [s]
        case "do":
            at += 1
            let s = shader.Stmt(.doWhile)
            loopDepth += 1
            s.Body = try scoped()
            loopDepth -= 1
            try expect("while")
            try expect("(")
            let c = try expression()
            if c.Type != .Bool { throw fail("a do-while condition must be a bool") }
            try expect(")")
            try expect(";")
            s.Expr = c
            return [s]
        case "for":
            at += 1
            try expect("(")
            push()
            let block = shader.Stmt(.block)
            if !accept(";") {
                block.Body += try simpleStatement()
            }
            let s = shader.Stmt(.loop)
            if !isNext(";") {
                let c = try expression()
                if c.Type != .Bool { throw fail("a for condition must be a bool") }
                s.Expr = c
            }
            try expect(";")
            if !isNext(")") { s.Step = try expression() }
            try expect(")")
            loopDepth += 1
            s.Body = try scoped()
            loopDepth -= 1
            pop()
            block.Body.append(s)
            return [block]
        case "switch":
            if !es3 { break }
            at += 1
            try expect("(")
            let v = try expression()
            if v.Type != .Int && v.Type != .Uint { throw fail("a switch needs an integer") }
            try expect(")")
            try expect("{")
            let s = shader.Stmt(.switchCase)
            s.Expr = v
            switchDepth += 1
            push()
            while !accept("}") {
                if accept("case") {
                    let c = try conditional()
                    guard c.IsConstant, c.Type == v.Type else { throw fail("a case needs a constant of the switch's type") }
                    try expect(":")
                    s.Labels.append(shader.CaseLabel(value: int32(bitPattern: c.Value[0]), start: s.Body.count))
                } else if accept("default") {
                    try expect(":")
                    s.Labels.append(shader.CaseLabel(value: nil, start: s.Body.count))
                } else {
                    s.Body += try statement()
                }
            }
            pop()
            switchDepth -= 1
            return [s]
        case "break":
            at += 1
            try expect(";")
            if loopDepth == 0 && switchDepth == 0 { throw fail("break outside a loop or switch") }
            return [shader.Stmt(.breakLoop)]
        case "continue":
            at += 1
            try expect(";")
            if loopDepth == 0 { throw fail("continue outside a loop") }
            return [shader.Stmt(.continueLoop)]
        case "discard":
            at += 1
            try expect(";")
            if !fragment { throw fail("discard is only for fragment shaders") }
            module.Discards = true
            return [shader.Stmt(.discard)]
        case "return":
            at += 1
            let s = shader.Stmt(.returnValue)
            guard let f = function else { throw fail("return outside a function") }
            if !accept(";") {
                let e = try expression()
                if e.Type != f.Result { throw fail("\(f.Name) returns \(describe(f.Result)), not \(describe(e.Type))") }
                s.Expr = e
                try expect(";")
            } else if f.Result != .Void {
                throw fail("\(f.Name) must return a value")
            }
            return [s]
        default:
            break
        }
        return try simpleStatement()
    }

    /// A body: a statement in its own scope.
    func scoped() throws -> [shader.Stmt] {
        push()
        let s = try statement()
        pop()
        return s
    }

    /// A declaration or an expression, then ;.
    func simpleStatement() throws -> [shader.Stmt] {
        if isDeclaration() {
            let q = try qualifiers()
            let type = try typeSpecifier(qualifiers: q)
            if accept(";") { return [] }   // a struct type alone
            let name = try identifier()
            pendingDeclarations = []
            try declarators(q, type, name, global: false)
            let d = pendingDeclarations
            pendingDeclarations = []
            return d
        }
        let e = try expression()
        try expect(";")
        let s = shader.Stmt(.expr)
        s.Expr = e
        return [s]
    }

    func isDeclaration() -> bool {
        let t = peek().Text
        if ["const", "highp", "mediump", "lowp", "precision", "invariant", "struct"].contains(t) { return true }
        if !startsType() { return false }
        // A type followed by ( is a constructor call; float[3](…) too.
        if peek(1).Text == "(" { return false }
        if peek(1).Text == "[" {
            var k = 2
            var depth = 1
            while depth > 0 && peek(k).Kind != .end {
                if peek(k).Text == "[" { depth += 1 }
                if peek(k).Text == "]" { depth -= 1 }
                k += 1
            }
            return peek(k).Text != "("
        }
        return true
    }
}

/// Words GLSL ES reserves, which can't name anything.
let keywords: [string] = [
    "attribute", "const", "uniform", "varying", "break", "continue", "do", "for", "while", "if", "else",
    "in", "out", "inout", "true", "false", "lowp", "mediump", "highp", "precision", "invariant",
    "discard", "return", "struct", "layout", "centroid", "flat", "smooth", "switch", "case", "default",
]

/// A type as GLSL spells it, for messages.
func describe(_ t: shader.DataType) -> string {
    var s = ""
    switch t.Kind {
    case .void: s = "void"
    case .bool: s = t.Rows > 1 ? "bvec\(t.Rows)" : "bool"
    case .int: s = t.Rows > 1 ? "ivec\(t.Rows)" : "int"
    case .uint: s = t.Rows > 1 ? "uvec\(t.Rows)" : "uint"
    case .float:
        if t.Columns > 1 {
            s = t.Columns == t.Rows ? "mat\(t.Columns)" : "mat\(t.Columns)x\(t.Rows)"
        } else {
            s = t.Rows > 1 ? "vec\(t.Rows)" : "float"
        }
    case .sampler: s = "sampler"
    case .structure: s = "struct"
    }
    return t.IsArray ? "\(s)[\(t.ArrayCount)]" : s
}
