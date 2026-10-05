// Package shader is a shader program compiled while a program runs: the
// IR every front end lowers to (GLSL ES today, WGSL later) and every
// backend reads (the CPU interpreter today, Metal source later). A module
// is plain data, so a front end builds one with no device in sight.
//
// Shader languages have no recursion and no heap, so every variable a
// module declares, function locals and parameters included, has one fixed
// place. The IR keeps that: a Module lists all its variables, and code
// refers to them by index.
package shader

/// Stage is the point in a pipeline a shader runs at.
public enum Stage: Equatable {
    case vertex
    case fragment
}

/// Kind is what a type's components are.
public enum Kind: Equatable {
    case void
    case bool
    case int
    case uint
    case float
    case sampler(SamplerKind)
    /// Module.Structs[i].
    case structure(int)
}

/// SamplerKind is the texture shape and component type a sampler reads.
public enum SamplerKind: Equatable {
    case texture2D
    case texture3D
    case cube
    case array2D
    case shadow2D
    case shadowCube
    case shadowArray2D
    /// GL_OES_EGL_image_external: Android's camera and video frames.
    case external
    case itexture2D
    case utexture2D
}

/// Precision is a GLSL ES precision qualifier. It is a hint: a backend may
/// compute at a higher precision, never at a lower one.
public enum Precision: Equatable {
    case none
    case low
    case medium
    case high
}

/// DataType is a value's type: a scalar, vector or matrix of one Kind, a
/// sampler or a struct, optionally an array of them.
public struct DataType: Equatable {
    public var Kind: Kind
    /// Matrix columns; 1 for a scalar or vector.
    public var Columns: int
    /// Vector size, or a matrix column's size; 1 for a scalar.
    public var Rows: int
    /// The element count of an array; 0 for a single value.
    public var ArrayCount: int

    public init(_ kind: Kind, columns: int = 1, rows: int = 1, arrayCount: int = 0) {
        Kind = kind
        Columns = columns
        Rows = rows
        ArrayCount = arrayCount
    }

    public static let Void = DataType(.void)
    public static let Bool = DataType(.bool)
    public static let Int = DataType(.int)
    public static let Uint = DataType(.uint)
    public static let Float = DataType(.float)

    public static func Vector(_ k: Kind, _ n: int) -> DataType { DataType(k, rows: n) }
    public static func Matrix(columns: int, rows: int) -> DataType { DataType(.float, columns: columns, rows: rows) }

    public var IsArray: bool { ArrayCount > 0 }
    /// The type of one element of an array; the type itself otherwise.
    public var Element: DataType { DataType(Kind, columns: Columns, rows: Rows) }
    public func ArrayOf(_ n: int) -> DataType { DataType(Kind, columns: Columns, rows: Rows, arrayCount: n) }

    public var IsScalar: bool { !IsArray && Columns == 1 && Rows == 1 && IsNumeric }
    public var IsVector: bool { !IsArray && Columns == 1 && Rows > 1 }
    public var IsMatrix: bool { !IsArray && Columns > 1 }
    public var IsSampler: bool {
        if case .sampler = Kind { return true }
        return false
    }
    public var IsStruct: bool {
        if case .structure = Kind { return true }
        return false
    }
    /// bool, int, uint or float, of any shape.
    public var IsNumeric: bool {
        switch Kind {
        case .bool, .int, .uint, .float: return true
        default: return false
        }
    }
    public var IsFloat: bool { Kind == .float }
    public var IsIntegral: bool { Kind == .int || Kind == .uint }

    /// The scalar type of one component.
    public var ComponentType: DataType { DataType(Kind) }

    /// A matrix's column type.
    public var ColumnType: DataType { DataType(Kind, rows: Rows) }

    /// How many scalars one element holds: 0 for a sampler or struct (see Module.Slots).
    public var Components: int {
        if !IsNumeric { return 0 }
        return Columns * Rows
    }
}

/// A struct's fields, in order.
public final class StructType {
    public let Name: string
    public var Fields: [Field] = []

    public init(name: string) {
        Name = name
    }
}

/// One field of a struct.
public struct Field {
    public let Name: string
    public let Type: DataType

    public init(name: string, type: DataType) {
        Name = name
        Type = type
    }
}
