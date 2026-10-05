package shader

/// The implementation's limits: what shaders see as gl_Max… constants and
/// what the API reports, so the two agree.
public struct Limits {
    public var VertexAttribs = 16
    public var VertexUniformVectors = 256
    public var FragmentUniformVectors = 256
    public var VaryingVectors = 15
    public var VertexTextureUnits = 16
    public var FragmentTextureUnits = 16
    public var CombinedTextureUnits = 32
    public var DrawBuffers = 4

    public init() {}
}
