package shader

/// Storage is where a variable lives and who sets it.
public enum Storage: Equatable {
    /// A vertex attribute, or a fragment shader's varying.
    case input
    /// A vertex shader's varying, or a fragment shader's color output.
    case output
    /// Set by the API for a whole draw.
    case uniform
    /// A global the shader itself writes.
    case global
    /// A function's local or parameter.
    case local
    /// A constant global (`const` at file scope).
    case constant
    /// A built-in the pipeline sets or reads (gl_Position, gl_FragCoord …).
    case builtin(Builtin)
}

/// The built-in variables.
public enum Builtin: Equatable {
    case position        // gl_Position
    case pointSize       // gl_PointSize
    case vertexId        // gl_VertexID
    case instanceId      // gl_InstanceID
    case fragCoord       // gl_FragCoord
    case frontFacing     // gl_FrontFacing
    case pointCoord      // gl_PointCoord
    case fragColor       // gl_FragColor (GLSL ES 1.00)
    case fragData        // gl_FragData[] (GLSL ES 1.00)
    case fragDepth       // gl_FragDepth (3.00), gl_FragDepthEXT
    case depthRangeNear  // gl_DepthRange.near
    case depthRangeFar   // gl_DepthRange.far
}

/// A variable: a global, a uniform, an input or output, or a function's
/// local or parameter. Every one has a fixed place for the whole program.
public final class Variable {
    public let Name: string
    public let Type: DataType
    public let Storage: Storage
    public var Precision: Precision = .none
    /// layout(location = n) on an input or output; -1 when not given.
    public var Location: int = -1
    /// For a varying: interpolated flat (no interpolation).
    public var Flat: bool = false
    /// A constant's value, as component bit patterns.
    public var Value: [uint32] = []
    /// Its index in Module.Variables.
    public var Index: int = -1

    public init(name: string, type: DataType, storage: Storage) {
        Name = name
        Type = type
        Storage = storage
    }
}

/// An operator of one operand.
public enum UnaryOp: Equatable {
    case negate
    case not          // !b
    case complement   // ~i (3.00)
}

/// An operator of two operands. Arithmetic works componentwise, a scalar
/// with a vector or matrix applies to each component, and `multiply`
/// with a matrix operand is the linear-algebra product.
public enum BinaryOp: Equatable {
    case add
    case subtract
    case multiply
    case divide
    case remainder    // % (3.00)
    case less
    case lessEqual
    case greater
    case greaterEqual
    case equal        // of whole values: a bool
    case notEqual
    case logicalAnd   // && (short-circuit)
    case logicalOr    // ||
    case logicalXor   // ^^
    case bitAnd
    case bitOr
    case bitXor
    case shiftLeft
    case shiftRight
}

/// The built-in functions.
public enum Function: Equatable {
    case radians, degrees, sin, cos, tan, asin, acos, atan, atan2
    case sinh, cosh, tanh, asinh, acosh, atanh
    case pow, exp, log, exp2, log2, sqrt, inversesqrt
    case abs, sign, floor, trunc, round, roundEven, ceil, fract, mod, modf
    case min, max, clamp, mix, step, smoothstep
    case isnan, isinf
    case floatBitsToInt, floatBitsToUint, intBitsToFloat, uintBitsToFloat
    case packSnorm2x16, unpackSnorm2x16, packUnorm2x16, unpackUnorm2x16, packHalf2x16, unpackHalf2x16
    case length, distance, dot, cross, normalize, faceforward, reflect, refract
    case matrixCompMult, outerProduct, transpose, determinant, inverse
    case lessThan, lessThanEqual, greaterThan, greaterThanEqual, equal, notEqual, any, all, not
    /// texture2D, texture, textureCube …: with an implicit level of detail in a fragment shader.
    case texture
    /// texture2DProj, textureProj: coordinates divided by their last component.
    case textureProj
    /// texture2DLod, textureLod: an explicit level.
    case textureLod
    case textureProjLod
    /// textureGrad: explicit derivatives.
    case textureGrad
    case textureOffset
    case texelFetch
    case textureSize
    case dFdx, dFdy, fwidth
}

/// Which expression an Expr is.
public enum ExprOp: Equatable {
    /// Expr.Value: the constant's component bit patterns.
    case constant
    /// Module.Variables[Expr.Index].
    case variable
    /// Args[0]'s components Expr.Components, in order (.xzy, .rgb …).
    case swizzle
    /// Args[0][Args[1]]: an array element, a matrix column or a vector component.
    case index
    /// Args[0]'s field Expr.Index.
    case field
    case unary(UnaryOp)
    case binary(BinaryOp)
    /// Args[0] ? Args[1] : Args[2], evaluating only the operand chosen.
    case select
    /// A user function, Module.Functions[Expr.Index], with Args.
    case call
    /// A built-in function with Args.
    case builtin(Function)
    /// A value of Expr.Type from Args: GLSL's constructors (vec4(v, 1.0),
    /// mat3(m4), float(i) …).
    case construct
    /// Args[0] = Args[1]; its value is what was stored.
    case assign
    /// Args[0] op= Args[1].
    case compoundAssign(BinaryOp)
    /// ++x, --x, x++, x--: its value is the new or old value.
    case preIncrement
    case preDecrement
    case postIncrement
    case postDecrement
    /// Args evaluated in order; the value is the last one's (the comma operator).
    case sequence
    /// The array's length (3.00's .length()): Expr.Value holds it.
    case arrayLength
}

/// An expression, with its type.
public final class Expr {
    public let Op: ExprOp
    public let Type: DataType
    public var Args: [Expr]
    /// A variable, function or field index.
    public var Index: int = 0
    /// A swizzle's components, 0–3.
    public var Components: [int] = []
    /// A constant's component bit patterns: floats as their IEEE bits,
    /// bools as 0 or 1.
    public var Value: [uint32] = []

    public init(_ op: ExprOp, _ type: DataType, _ args: [Expr] = []) {
        Op = op
        Type = type
        Args = args
    }

    /// A constant of `type` from component bit patterns.
    public static func Constant(_ type: DataType, _ bits: [uint32]) -> Expr {
        let e = Expr(.constant, type)
        e.Value = bits
        return e
    }

    public static func FloatConstant(_ v: float32) -> Expr { Constant(.Float, [v.bitPattern]) }
    public static func IntConstant(_ v: int32) -> Expr { Constant(.Int, [uint32(bitPattern: v)]) }
    public static func BoolConstant(_ v: bool) -> Expr { Constant(.Bool, [v ? 1 : 0]) }

    /// A reference to `v`.
    public static func Ref(_ v: Variable) -> Expr {
        let e = Expr(.variable, v.Type)
        e.Index = v.Index
        return e
    }

    public var IsConstant: bool { Op == .constant }
}

/// What a statement is.
public enum StmtOp: Equatable {
    /// Evaluate Expr for its effects.
    case expr
    /// Declare Module.Variables[Index], initialized to Expr when there is one.
    case declare
    /// if Expr { Body } else { Else }
    case ifElse
    /// A loop: while Expr (none: forever) { Body; Step }. `for` puts its
    /// initializer in a block around it; `continue` runs Step.
    case loop
    /// do { Body } while Expr.
    case doWhile
    case breakLoop
    case continueLoop
    /// Return Expr (none for void).
    case returnValue
    /// End the fragment without writing it.
    case discard
    /// Body, in its own scope.
    case block
    /// switch Expr: Cases' values select where in Body to start (3.00).
    case switchCase
}

/// A statement.
public final class Stmt {
    public let Op: StmtOp
    public var Expr: Expr? = nil
    public var Body: [Stmt] = []
    public var Else: [Stmt] = []
    /// A loop's step (a for loop's third clause).
    public var Step: Expr? = nil
    /// The variable a declare statement declares.
    public var Index: int = 0
    /// A switch's labels.
    public var Labels: [CaseLabel] = []

    public init(_ op: StmtOp) {
        Op = op
    }
}

/// One `case` (or `default`) of a switch: where in Body it starts.
public struct CaseLabel {
    /// The case's value; nil for default.
    public let Value: int32?
    public let Start: int

    public init(value: int32?, start: int) {
        Value = value
        Start = start
    }
}

/// A function the shader defines.
public final class FunctionDef {
    public let Name: string
    public let Result: DataType
    /// Module.Variables indices of the parameters, in order.
    public var Params: [int] = []
    /// Whether each parameter is copied back out (out, inout).
    public var Out: [bool] = []
    /// Whether each parameter is copied in (in, inout).
    public var In: [bool] = []
    public var Body: [Stmt] = []
    /// Defined, not only declared.
    public var Defined = false

    public init(name: string, result: DataType) {
        Name = name
        Result = result
    }
}

/// A compiled shader stage.
public final class Module {
    public let Stage: Stage
    /// The source language version (100, 300).
    public var Version: int = 100
    public var Variables: [Variable] = []
    public var Structs: [StructType] = []
    public var Functions: [FunctionDef] = []
    /// Global initializers, in order, run before main.
    public var Init: [Stmt] = []
    /// Functions[EntryPoint] is main.
    public var EntryPoint: int = -1
    /// Whether the fragment shader writes gl_FragDepth / discards / reads derivatives.
    public var WritesDepth = false
    public var Discards = false
    /// Extensions the source enabled (#extension … : enable).
    public var Extensions: [string] = []

    public init(stage: Stage) {
        Stage = stage
    }

    /// Adds `v` and gives it its index.
    public func Add(_ v: Variable) -> Variable {
        v.Index = Variables.count
        Variables.append(v)
        return v
    }

    /// The scalars one value of `t` holds, structs and arrays included.
    public func Slots(_ t: DataType) -> int {
        var one = t.Components
        if case .structure(let s) = t.Kind {
            one = 0
            for f in Structs[s].Fields { one += Slots(f.Type) }
        }
        if case .sampler = t.Kind { one = 1 }
        return t.IsArray ? one * t.ArrayCount : one
    }

    /// Variables of a storage class, in declaration order.
    public func VariablesIn(_ storage: Storage) -> [Variable] {
        Variables.filter { $0.Storage == storage }
    }
}
