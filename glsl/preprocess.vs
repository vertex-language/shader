package glsl

/// A macro: its parameters (nil for an object-like macro) and body.
final class Macro {
    let Name: string
    let Params: [string]?
    let Body: [Token]

    init(name: string, params: [string]?, body: [Token]) {
        Name = name
        Params = params
        Body = body
    }
}

/// What preprocessing found, beside the tokens.
struct Preprocessed {
    var Tokens: [Token] = []
    /// The #version, or 100 when there is none.
    var Version = 100
    /// Extensions enabled with #extension.
    var Extensions: [string] = []
}

/// One level of #if nesting.
struct Conditional {
    /// Whether this group's lines are kept.
    var active: bool
    /// Whether some branch of this #if has already been taken.
    var taken: bool
    /// Whether the enclosing group is kept at all.
    var parentActive: bool
    var sawElse: bool
}

/// The preprocessor: directives, conditionals, macros.
final class Preprocessor {
    var macros: [string: Macro] = [:]
    var out = Preprocessed()
    let fragment: bool
    /// Extensions this compiler supports, each also a macro defined to 1.
    let supported: [string]

    init(fragment: bool, supported: [string]) {
        self.fragment = fragment
        self.supported = supported
    }

    func define(_ name: string, _ value: string, line: int = 0) {
        macros[name] = Macro(name: name, params: nil, body: [Token(.intLiteral, value, line: line)])
    }

    func run(_ source: string) throws -> Preprocessed {
        let tokens = try lex(source)
        define("GL_ES", "1")
        define("__FILE__", "0")
        if fragment { define("GL_FRAGMENT_PRECISION_HIGH", "1") }
        for e in supported { define(e, "1") }

        // Split into lines.
        var lines: [[Token]] = []
        var cur: [Token] = []
        for t in tokens {
            if t.Kind == .newline {
                lines.append(cur)
                cur = []
            } else if t.Kind != .end {
                cur.append(t)
            }
        }
        if !cur.isEmpty { lines.append(cur) }

        // #version, if present, must come first; it sets __VERSION__.
        var sawCode = false
        for l in lines where !l.isEmpty {
            if l[0].Text == "#" && l.count > 1 && l[1].Text == "version" {
                if l.count < 3 { throw CompileError(line: l[0].Line, "#version needs a number") }
                guard let v = int(l[2].Text) else { throw CompileError(line: l[0].Line, "bad #version") }
                if v == 300 {
                    if l.count < 4 || l[3].Text != "es" { throw CompileError(line: l[0].Line, "#version 300 needs the es profile") }
                } else if v != 100 {
                    throw CompileError(line: l[0].Line, "#version \(v) is not supported")
                }
                if sawCode { throw CompileError(line: l[0].Line, "#version must come first") }
                out.Version = v
            }
            sawCode = true
            break
        }
        define("__VERSION__", "\(out.Version)")

        var stack: [Conditional] = []
        func active() -> bool { stack.isEmpty || stack[stack.count - 1].active }
        var pending: [Token] = []   // code lines waiting for expansion (a macro call may span lines)
        for l in lines {
            if l.isEmpty { continue }
            if l[0].Text == "#" && l[0].Kind == .punct {
                if active() && !pending.isEmpty {
                    out.Tokens += try expand(pending, [])
                    pending = []
                }
                try directive(l, &stack)
                continue
            }
            if active() { pending += l }
        }
        if !stack.isEmpty { throw CompileError(line: lines.last?.first?.Line ?? 0, "unterminated #if") }
        out.Tokens += try expand(pending, [])
        let last = out.Tokens.last?.Line ?? 0
        out.Tokens.append(Token(.end, "", line: last))
        return out
    }

    func directive(_ l: [Token], _ stack: inout [Conditional]) throws {
        let line = l[0].Line
        if l.count == 1 { return }   // a null directive
        let name = l[1].Text
        let rest = Array(l.dropFirst(2))
        let isActive = stack.isEmpty || stack[stack.count - 1].active
        switch name {
        case "if", "ifdef", "ifndef":
            var on = false
            if isActive {
                if name == "if" {
                    on = try evaluate(rest, line: line) != 0
                } else {
                    guard let n = rest.first, n.Kind == .identifier else { throw CompileError(line: line, "#\(name) needs a name") }
                    on = (macros[n.Text] != nil) == (name == "ifdef")
                }
            }
            stack.append(Conditional(active: isActive && on, taken: on, parentActive: isActive, sawElse: false))
        case "elif":
            if stack.isEmpty { throw CompileError(line: line, "#elif without #if") }
            var c = stack[stack.count - 1]
            if c.sawElse { throw CompileError(line: line, "#elif after #else") }
            if c.parentActive && !c.taken {
                let on = try evaluate(rest, line: line) != 0
                c.active = on
                c.taken = on
            } else {
                c.active = false
            }
            stack[stack.count - 1] = c
        case "else":
            if stack.isEmpty { throw CompileError(line: line, "#else without #if") }
            var c = stack[stack.count - 1]
            if c.sawElse { throw CompileError(line: line, "#else after #else") }
            c.sawElse = true
            c.active = c.parentActive && !c.taken
            c.taken = true
            stack[stack.count - 1] = c
        case "endif":
            if stack.isEmpty { throw CompileError(line: line, "#endif without #if") }
            stack.removeLast()
        default:
            if !isActive { return }
            switch name {
            case "define": try defineDirective(rest, line: line)
            case "undef":
                if let n = rest.first { macros[n.Text] = nil }
            case "error":
                throw CompileError(line: line, "#error " + rest.map { $0.Text }.joined(separator: " "))
            case "extension":
                // #extension name : behavior
                if rest.count >= 3 && rest[1].Text == ":" {
                    let ext = rest[0].Text
                    let behavior = rest[2].Text
                    if ext != "all" && !supported.contains(ext) && behavior == "require" {
                        throw CompileError(line: line, "extension \(ext) is not supported")
                    }
                    if behavior != "disable" && !out.Extensions.contains(ext) { out.Extensions.append(ext) }
                } else {
                    throw CompileError(line: line, "malformed #extension")
                }
            case "version", "pragma", "line":
                break
            default:
                throw CompileError(line: line, "unknown directive #\(name)")
            }
        }
    }

    func defineDirective(_ rest: [Token], line: int) throws {
        guard let n = rest.first, n.Kind == .identifier else { throw CompileError(line: line, "#define needs a name") }
        if n.Text.hasPrefix("GL_") { throw CompileError(line: line, "macro names beginning GL_ are reserved") }
        var params: [string]? = nil
        var body = Array(rest.dropFirst())
        if let open = body.first, open.Text == "(", !open.Spaced {
            var ps: [string] = []
            var k = 1
            while k < body.count && body[k].Text != ")" {
                if body[k].Kind == .identifier { ps.append(body[k].Text) }
                else if body[k].Text != "," { throw CompileError(line: line, "bad macro parameter list") }
                k += 1
            }
            if k >= body.count { throw CompileError(line: line, "unterminated macro parameter list") }
            params = ps
            body = Array(body[(k + 1)...])
        }
        macros[n.Text] = Macro(name: n.Text, params: params, body: body)
    }

    /// Macro expansion of `tokens`, with `hidden` (the macros being
    /// expanded) left alone, so a macro can't expand itself.
    func expand(_ tokens: [Token], _ hidden: [string]) throws -> [Token] {
        var out: [Token] = []
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            if t.Kind == .identifier && t.Text == "__LINE__" {
                out.append(Token(.intLiteral, "\(t.Line)", line: t.Line))
                i += 1
                continue
            }
            guard t.Kind == .identifier, !hidden.contains(t.Text), let m = macros[t.Text] else {
                out.append(t)
                i += 1
                continue
            }
            var h = hidden
            h.append(m.Name)
            guard let params = m.Params else {
                out += try expand(relined(m.Body, t.Line), h)
                i += 1
                continue
            }
            // A function-like macro's name not followed by ( is just a name.
            if i + 1 >= tokens.count || tokens[i + 1].Text != "(" {
                out.append(t)
                i += 1
                continue
            }
            var args: [[Token]] = [[]]
            var depth = 0
            var k = i + 2
            while k < tokens.count {
                let a = tokens[k]
                if a.Text == "(" { depth += 1 }
                if a.Text == ")" {
                    if depth == 0 { break }
                    depth -= 1
                }
                if a.Text == "," && depth == 0 {
                    args.append([])
                } else {
                    args[args.count - 1].append(a)
                }
                k += 1
            }
            if k >= tokens.count { throw CompileError(line: t.Line, "unterminated call of macro \(m.Name)") }
            if params.isEmpty && args.count == 1 && args[0].isEmpty { args = [] }
            if args.count != params.count {
                throw CompileError(line: t.Line, "macro \(m.Name) takes \(params.count) arguments, given \(args.count)")
            }
            var expanded: [[Token]] = []
            for a in args { expanded.append(try expand(a, hidden)) }
            var body: [Token] = []
            for b in relined(m.Body, t.Line) {
                if b.Kind == .identifier, let p = params.firstIndex(of: b.Text) {
                    body += expanded[p]
                } else {
                    body.append(b)
                }
            }
            out += try expand(body, h)
            i = k + 1
        }
        return out
    }

    /// A macro body's tokens, placed on the line it's used on.
    func relined(_ body: [Token], _ line: int) -> [Token] {
        body.map { Token($0.Kind, $0.Text, line: line, spaced: $0.Spaced) }
    }

    // MARK: #if expressions

    func evaluate(_ tokens: [Token], line: int) throws -> int {
        // `defined X` and `defined(X)` before expansion.
        var resolved: [Token] = []
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            if t.Text == "defined" {
                var name = ""
                if i + 1 < tokens.count && tokens[i + 1].Text == "(" && i + 3 < tokens.count {
                    name = tokens[i + 2].Text
                    i += 4
                } else if i + 1 < tokens.count {
                    name = tokens[i + 1].Text
                    i += 2
                } else {
                    throw CompileError(line: line, "defined needs a name")
                }
                resolved.append(Token(.intLiteral, macros[name] != nil ? "1" : "0", line: line))
                continue
            }
            resolved.append(t)
            i += 1
        }
        let expanded = try expand(resolved, [])
        var p = ConstExprParser(tokens: expanded, line: line)
        let v = try p.ternary()
        if p.at < expanded.count { throw CompileError(line: line, "junk after #if expression") }
        return v
    }
}

/// The integer expressions of #if.
struct ConstExprParser {
    let tokens: [Token]
    let line: int
    var at = 0

    init(tokens: [Token], line: int) {
        self.tokens = tokens
        self.line = line
    }

    func peek() -> string { at < tokens.count ? tokens[at].Text : "" }

    mutating func ternary() throws -> int {
        let c = try binary(0)
        if peek() == "?" {
            at += 1
            let a = try ternary()
            if peek() != ":" { throw CompileError(line: line, "expected : in #if expression") }
            at += 1
            let b = try ternary()
            return c != 0 ? a : b
        }
        return c
    }

    static func precedence(_ op: string) -> int {
        switch op {
        case "||": return 1
        case "&&": return 2
        case "|": return 3
        case "^": return 4
        case "&": return 5
        case "==", "!=": return 6
        case "<", ">", "<=", ">=": return 7
        case "<<", ">>": return 8
        case "+", "-": return 9
        case "*", "/", "%": return 10
        default: return 0
        }
    }

    mutating func binary(_ minPrec: int) throws -> int {
        var left = try unary()
        while true {
            let op = peek()
            let p = ConstExprParser.precedence(op)
            if p == 0 || p <= minPrec { break }
            at += 1
            let right = try binary(p)
            switch op {
            case "||": left = (left != 0 || right != 0) ? 1 : 0
            case "&&": left = (left != 0 && right != 0) ? 1 : 0
            case "|": left = left | right
            case "^": left = left ^ right
            case "&": left = left & right
            case "==": left = left == right ? 1 : 0
            case "!=": left = left != right ? 1 : 0
            case "<": left = left < right ? 1 : 0
            case ">": left = left > right ? 1 : 0
            case "<=": left = left <= right ? 1 : 0
            case ">=": left = left >= right ? 1 : 0
            case "<<": left = left << right
            case ">>": left = left >> right
            case "+": left = left + right
            case "-": left = left - right
            case "*": left = left * right
            case "/":
                if right == 0 { throw CompileError(line: line, "division by zero in #if") }
                left = left / right
            default:
                if right == 0 { throw CompileError(line: line, "division by zero in #if") }
                left = left % right
            }
        }
        return left
    }

    mutating func unary() throws -> int {
        let t = peek()
        switch t {
        case "-":
            at += 1
            return -(try unary())
        case "+":
            at += 1
            return try unary()
        case "!":
            at += 1
            return try unary() == 0 ? 1 : 0
        case "~":
            at += 1
            return ~(try unary())
        case "(":
            at += 1
            let v = try ternary()
            if peek() != ")" { throw CompileError(line: line, "expected ) in #if expression") }
            at += 1
            return v
        default:
            if at >= tokens.count { throw CompileError(line: line, "#if expression ends early") }
            let tok = tokens[at]
            at += 1
            if tok.Kind == .intLiteral || tok.Kind == .uintLiteral {
                return parseIntLiteral(tok.Text) ?? 0
            }
            if tok.Kind == .identifier { return 0 }   // an undefined name is 0, as in C
            throw CompileError(line: line, "unexpected '\(tok.Text)' in #if expression")
        }
    }
}

/// A decimal, octal (leading 0) or hexadecimal integer literal, without its u suffix.
func parseIntLiteral(_ text: string) -> int? {
    var t = text
    if t.hasSuffix("u") || t.hasSuffix("U") { t = string(t.dropLast()) }
    if t.hasPrefix("0x") || t.hasPrefix("0X") { return int(string(t.dropFirst(2)), radix: 16) }
    if t.count > 1 && t.hasPrefix("0") { return int(string(t.dropFirst()), radix: 8) }
    return int(t)
}
