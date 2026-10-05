// Package glsl compiles GLSL ES source to a shader.Module: version 1.00
// (OpenGL ES 2.0, WebGL 1) and 3.00 (OpenGL ES 3.0, WebGL 2). A shader's
// source arrives at run time, from a guest's glShaderSource or a web
// page, so this is a library, not a build step.
//
// Compiling is three passes over the text: the lexer splits it into
// tokens, the preprocessor runs its directives and expands macros, and the
// parser checks the program as it reads it (GLSL declares everything
// before use, so one pass suffices) and builds the module.
package glsl

/// What a token is.
public enum TokenKind: Equatable {
    case identifier
    case intLiteral
    case uintLiteral
    case floatLiteral
    case punct
    /// The end of a source line; only the preprocessor sees these.
    case newline
    case end
}

/// A token: its kind, its text and the line it is on.
public struct Token {
    public let Kind: TokenKind
    public let Text: string
    public let Line: int
    /// Whitespace came before it (for telling `#define F(x)` from `#define F (x)`).
    public let Spaced: bool

    public init(_ kind: TokenKind, _ text: string, line: int, spaced: bool = false) {
        Kind = kind
        Text = text
        Line = line
        Spaced = spaced
    }
}

/// CompileError is a problem in the source, at a line.
public struct CompileError: Error {
    public let Line: int
    public let Message: string

    public init(line: int, _ message: string) {
        Line = line
        Message = message
    }

    /// As glGetShaderInfoLog shows it: "ERROR: 0:<line>: <message>".
    public var Log: string { "ERROR: 0:\(Line): \(Message)\n" }
}

/// The punctuators, longest first so the lexer takes the longest match.
let puncts3 = ["<<=", ">>="]
let puncts2 = ["++", "--", "<=", ">=", "==", "!=", "&&", "||", "^^", "+=", "-=", "*=", "/=", "%=",
               "&=", "|=", "^=", "<<", ">>", "##"]
let puncts1: [uint8] = Array("+-*/%<>=!&|^~?:;,.()[]{}#".utf8)

func isDigit(_ c: uint8) -> bool { c >= 0x30 && c <= 0x39 }
func isAlpha(_ c: uint8) -> bool { (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c == 0x5f }
func isHex(_ c: uint8) -> bool { isDigit(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66) }

/// Splits source into tokens, newlines kept. Comments become a space
/// (a block comment's newlines still end lines), and a backslash before a
/// newline joins two lines.
func lex(_ source: string) throws -> [Token] {
    let b = Array(source.utf8)
    var out: [Token] = []
    var i = 0
    var line = 1
    var spaced = true
    func text(_ from: int, _ to: int) -> string { string(decoding: b[from..<to], as: UTF8.self) }
    while i < b.count {
        let c = b[i]
        if c == 0x0A {
            out.append(Token(.newline, "\n", line: line))
            line += 1
            i += 1
            spaced = true
            continue
        }
        if c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0B || c == 0x0C {
            i += 1
            spaced = true
            continue
        }
        if c == 0x5C && i + 1 < b.count && (b[i + 1] == 0x0A || (b[i + 1] == 0x0D && i + 2 < b.count && b[i + 2] == 0x0A)) {
            // A line continuation.
            i += b[i + 1] == 0x0A ? 2 : 3
            line += 1
            continue
        }
        if c == 0x2F && i + 1 < b.count && b[i + 1] == 0x2F {
            while i < b.count && b[i] != 0x0A { i += 1 }
            spaced = true
            continue
        }
        if c == 0x2F && i + 1 < b.count && b[i + 1] == 0x2A {
            i += 2
            while i + 1 < b.count && !(b[i] == 0x2A && b[i + 1] == 0x2F) {
                if b[i] == 0x0A {
                    out.append(Token(.newline, "\n", line: line))
                    line += 1
                }
                i += 1
            }
            if i + 1 >= b.count { throw CompileError(line: line, "unterminated comment") }
            i += 2
            spaced = true
            continue
        }
        let start = i
        if isAlpha(c) {
            while i < b.count && (isAlpha(b[i]) || isDigit(b[i])) { i += 1 }
            out.append(Token(.identifier, text(start, i), line: line, spaced: spaced))
            spaced = false
            continue
        }
        if isDigit(c) || (c == 0x2E && i + 1 < b.count && isDigit(b[i + 1])) {
            var kind = TokenKind.intLiteral
            if c == 0x30 && i + 1 < b.count && (b[i + 1] == 0x78 || b[i + 1] == 0x58) {
                i += 2
                while i < b.count && isHex(b[i]) { i += 1 }
            } else {
                while i < b.count && isDigit(b[i]) { i += 1 }
                if i < b.count && b[i] == 0x2E {
                    kind = .floatLiteral
                    i += 1
                    while i < b.count && isDigit(b[i]) { i += 1 }
                }
                if i < b.count && (b[i] == 0x65 || b[i] == 0x45) {
                    kind = .floatLiteral
                    i += 1
                    if i < b.count && (b[i] == 0x2B || b[i] == 0x2D) { i += 1 }
                    while i < b.count && isDigit(b[i]) { i += 1 }
                }
            }
            if kind == .floatLiteral && i < b.count && (b[i] == 0x66 || b[i] == 0x46) {
                i += 1   // 3.00's f suffix
            } else if kind == .intLiteral && i < b.count && (b[i] == 0x75 || b[i] == 0x55) {
                kind = .uintLiteral
                i += 1
            }
            out.append(Token(kind, text(start, i), line: line, spaced: spaced))
            spaced = false
            continue
        }
        if i + 2 < b.count {
            let t = text(i, i + 3)
            if puncts3.contains(t) {
                out.append(Token(.punct, t, line: line, spaced: spaced))
                i += 3
                spaced = false
                continue
            }
        }
        if i + 1 < b.count {
            let t = text(i, i + 2)
            if puncts2.contains(t) {
                out.append(Token(.punct, t, line: line, spaced: spaced))
                i += 2
                spaced = false
                continue
            }
        }
        if puncts1.contains(c) {
            out.append(Token(.punct, text(i, i + 1), line: line, spaced: spaced))
            i += 1
            spaced = false
            continue
        }
        throw CompileError(line: line, "unexpected character '\(text(i, i + 1))'")
    }
    out.append(Token(.newline, "\n", line: line))
    out.append(Token(.end, "", line: line))
    return out
}
