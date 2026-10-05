package glsl

import (
    "shader"
)

/// What compiling a shader gave: the module, or the log of why not.
public struct Result {
    public let Module: shader.Module?
    /// What glGetShaderInfoLog shows: empty on success.
    public let Log: string

    public var Ok: bool { Module != nil }
}

/// The extensions this compiler takes, each also defined as a macro.
public let SupportedExtensions: [string] = [
    "GL_OES_standard_derivatives",
    "GL_OES_EGL_image_external",
    "GL_OES_EGL_image_external_essl3",
    "GL_EXT_shader_texture_lod",
    "GL_EXT_frag_depth",
]

/// Compiles GLSL ES source for `stage`. The version is the source's
/// `#version` line: 1.00 without one.
public func Compile(_ source: string, stage: shader.Stage) -> Result {
    do {
        let pp = try Preprocessor(fragment: stage == .fragment, supported: SupportedExtensions).run(source)
        let p = Parser(tokens: pp.Tokens, stage: stage, version: pp.Version, extensions: pp.Extensions)
        let m = try p.parse()
        return Result(Module: m, Log: "")
    } catch let e as CompileError {
        return Result(Module: nil, Log: e.Log)
    } catch {
        return Result(Module: nil, Log: "ERROR: \(error)\n")
    }
}
