// Package interp runs shader modules on the CPU. It is the reference
// every other backend must match, and how the CPU device shades.
//
// A module compiles to instructions over slots: each variable has a fixed
// range of 32-bit slots (shader languages have no recursion), expressions
// write temporaries after them, and functions are inlined where they are
// called. A Machine runs many invocations in lockstep, one per lane, with
// a mask of the lanes each instruction applies to, as a GPU does: a
// fragment shader runs 2×2 quads of pixels, so derivatives (dFdx, dFdy)
// and texture levels of detail are differences between lanes of a quad.
package interp

import (
    "shader"
)

/// What an instruction does. Componentwise operations apply to N
/// components; an operand with stride 0 is one scalar used for each.
public enum Op: Equatable {
    case mov
    // float
    case fadd, fsub, fmul, fdiv, fneg
    // int and uint (wrapping)
    case iadd, isub, imul, idiv, irem, ineg, udiv, urem
    // bits and bools
    case and, or, xor, not, complement, shl, shrI, shrU
    // comparisons, giving 0 or 1
    case flt, fle, fgt, fge, feq, fne, ilt, ile, igt, ige, ult, ule, ugt, uge, ieq, ine
    /// dst = whether all N components are equal (floats compared as floats when Aux is 1).
    case eqAll
    // conversions
    case f2i, f2u, i2f, u2f, b2f, f2b, i2b
    /// dst = c ? a : b, per component.
    case select
    /// One-operand math on floats: Aux is the shader.Function.
    case math1
    /// Two-operand math on floats (pow, atan2, mod, min, max, step).
    case math2
    /// Three-operand math (clamp, mix, smoothstep, fma).
    case math3
    case imin, imax, umin, umax, iabs, isign, iclamp, uclamp
    // geometry: Aux is the vector size
    case dot, length, distance, normalize, cross, reflect, refract, faceforward
    // matrices: Aux = rows of A, Aux2 = columns of A (inner), Aux3 = columns of B
    case matmul
    case transpose, determinant, inverse, outer
    case any, all
    /// dst[0..<N] = a's components listed in Aux (2 bits each).
    case gather
    /// dst's components listed in Aux = a[0..<N] (a swizzle written to).
    case scatter
    /// dst = a[clamp(index c)]: N slots per element, Aux elements.
    case loadIndexed
    /// a[clamp(index c)] = b: N slots per element, Aux elements; dst is a's base.
    case storeIndexed
    /// A texture lookup: dst (4) = sample unit a at coordinates b (Aux2 components); c: bias, level or derivatives.
    case sample
    case texelFetch
    case textureSize
    case dfdx, dfdy, fwidth
    case packSnorm2x16, unpackSnorm2x16, packUnorm2x16, unpackUnorm2x16, packHalf2x16, unpackHalf2x16
    case isnan, isinf
    // control
    case ifBegin       // a: condition; Target: the matching else or end
    case elseBegin     // Target: the end
    case ifEnd
    case loopBegin
    case loopCondition // a: condition; Target: the loop's end
    case loopContinue  // the continue point: lanes that continued resume
    case loopBack      // Target: the loop's first instruction
    case loopEnd
    case breakLoop
    case continueLoop
    case functionBegin
    case functionReturn
    case functionEnd
    case discard
    /// Starts a switch: a is the value; lanes match cases as they come.
    case switchBegin
    /// A case label: lanes whose value is Aux (or, for default, any lane no case takes: Aux2 = 1) join.
    case switchCase
    case switchEnd
}

/// Which texture lookup a sample instruction is.
public enum Lookup: Equatable {
    /// An implicit level of detail, from the quad's derivatives (vertex shaders: the base level).
    case implicit
    /// Implicit, plus a bias in c.
    case bias
    /// An explicit level in c.
    case level
    /// Explicit derivatives: dPdx at c, dPdy after it.
    case gradient
}

/// One instruction.
public struct Instr {
    public var Op: Op
    public var N: int = 1
    public var Dst: int = 0
    public var A: int = 0
    public var B: int = 0
    public var C: int = 0
    public var StrideA: int = 1
    public var StrideB: int = 1
    public var StrideC: int = 1
    public var Aux: int = 0
    public var Aux2: int = 0
    public var Aux3: int = 0
    /// A jump target (an instruction index).
    public var Target: int = 0
    /// For sample instructions.
    public var Lookup: Lookup = .implicit
    public var Projective: bool = false
    public var Sampler: shader.SamplerKind = .texture2D
    /// For math1, math2 and math3: which function.
    public var Fn: shader.Function = .sin

    public init(_ op: Op) {
        Op = op
    }
}

/// A uniform the API can set: one scalar, vector, matrix or sampler, an
/// element of an array or a field of a struct named as GL names them
/// ("lights[2].color").
public struct Uniform {
    public let Name: string
    public let Type: shader.DataType
    /// The first slot.
    public let Offset: int
    /// For an array's first element: how many elements (each its own Uniform after it); 1 otherwise.
    public let ArraySize: int

    public init(name: string, type: shader.DataType, offset: int, arraySize: int) {
        Name = name
        Type = type
        Offset = offset
        ArraySize = arraySize
    }
}

/// An input or output of a stage.
public struct Interface {
    public let Name: string
    public let Type: shader.DataType
    public let Offset: int
    public let Slots: int
    public let Location: int
    public let Flat: bool

    public init(name: string, type: shader.DataType, offset: int, slots: int, location: int, flat: bool) {
        Name = name
        Type = type
        Offset = offset
        Slots = slots
        Location = location
        Flat = flat
    }
}

/// A slot holding a constant.
public struct ConstantSlot {
    public let Slot: int
    public let Bits: uint32

    public init(slot: int, bits: uint32) {
        Slot = slot
        Bits = bits
    }
}

/// A compiled stage: instructions, and where everything is.
public final class Executable {
    public let Module: shader.Module
    public var Code: [Instr] = []
    public var SlotCount: int = 0
    /// Each variable's first slot, by Module.Variables index.
    public var Offsets: [int] = []
    public var Uniforms: [Uniform] = []
    public var Inputs: [Interface] = []
    public var Outputs: [Interface] = []
    /// Constants to load into every lane before running.
    public var Constants: [ConstantSlot] = []
    /// Each switch's case values, by switchBegin's Aux.
    public var SwitchCases: [[int32]] = []
    /// Where built-ins live: -1 when the shader doesn't use one.
    public var Position = -1
    public var PointSize = -1
    public var FragCoord = -1
    public var FrontFacing = -1
    public var PointCoord = -1
    public var FragColor = -1
    public var FragData = -1
    public var FragDepth = -1
    public var VertexId = -1
    public var InstanceId = -1
    /// Whether any instruction needs neighbouring lanes (derivatives, implicit-LOD lookups).
    public var UsesDerivatives = false

    init(_ m: shader.Module) {
        Module = m
    }

    /// The uniform with a GL name, or nil.
    public func FindUniform(_ name: string) -> Uniform? {
        for u in Uniforms where u.Name == name { return u }
        return nil
    }
}

extension Executable {
    /// The instructions, one per line, for reading and debugging.
    public var Listing: string {
        var s = ""
        for (k, i) in Code.enumerated() {
            s += "\(k)\t\(i.Op) n=\(i.N) d=\(i.Dst) a=\(i.A)/\(i.StrideA) b=\(i.B)/\(i.StrideB) c=\(i.C)/\(i.StrideC)"
            if i.Aux != 0 || i.Aux2 != 0 || i.Aux3 != 0 { s += " aux=\(i.Aux),\(i.Aux2),\(i.Aux3)" }
            if i.Target != 0 { s += " -> \(i.Target)" }
            s += "\n"
        }
        return s
    }
}
