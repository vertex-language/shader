package interp

import (
    "shader"
)

extension Compiler {
    /// Compiles `e`; returns the first slot of its value (a variable's own
    /// slots when it is one, else temporaries).
    func expr(_ e: shader.Expr) throws -> int {
        let t = e.Type
        let n = m.Slots(t)
        switch e.Op {
        case .constant:
            return constant(e.Value)
        case .variable:
            return offsets[e.Index]
        case .arrayLength:
            return constant(e.Value)
        case .swizzle:
            let base = try expr(e.Args[0])
            // A run of consecutive components is a view, not a copy.
            var consecutive = true
            for k in 1..<max(1, e.Components.count) where e.Components[k] != e.Components[0] + k { consecutive = false }
            if consecutive { return base + e.Components[0] }
            let d = temp(n)
            var i = Instr(.gather)
            i.N = e.Components.count
            i.Dst = d
            i.A = base
            i.Aux = packList(e.Components)
            _ = emit(i)
            return d
        case .field:
            let base = try expr(e.Args[0])
            guard case .structure(let s) = e.Args[0].Type.Kind else { throw CompileError("field of a non-struct") }
            var off = 0
            for k in 0..<e.Index { off += m.Slots(m.Structs[s].Fields[k].Type) }
            return base + off
        case .index:
            let base = try expr(e.Args[0])
            let at = e.Args[0].Type
            let count = at.IsArray ? at.ArrayCount : (at.IsMatrix ? at.Columns : at.Rows)
            if e.Args[1].IsConstant {
                let k = int(int32(bitPattern: e.Args[1].Value[0]))
                return base + max(0, min(k, count - 1)) * n
            }
            let idx = try expr(e.Args[1])
            let d = temp(n)
            var i = Instr(.loadIndexed)
            i.N = n
            i.Dst = d
            i.A = base
            i.C = idx
            i.Aux = count
            _ = emit(i)
            return d
        case .unary(let u):
            let a = try expr(e.Args[0])
            let d = temp(n)
            switch u {
            case .negate: op(t.IsFloat ? .fneg : .ineg, n: n, dst: d, a: a)
            case .not: op(.not, n: n, dst: d, a: a)
            case .complement: op(.complement, n: n, dst: d, a: a)
            }
            return d
        case .binary(let b):
            return try binary(b, e)
        case .select:
            let c = try expr(e.Args[0])
            let keep = temp(1)
            mov(keep, c, 1)
            let d = temp(n)
            var i = Instr(.ifBegin)
            i.A = keep
            let begin = emit(i)
            let a = try expr(e.Args[1])
            mov(d, a, n)
            let elseAt = emit(Instr(.elseBegin))
            let b = try expr(e.Args[2])
            mov(d, b, n)
            let end = emit(Instr(.ifEnd))
            code[begin].Target = elseAt
            code[elseAt].Target = end
            return d
        case .call:
            try inline(e.Index, args: e.Args)
            if t.Kind == .void { return constant([0]) }
            // Copy the result out: another call of the same function would overwrite it.
            let d = temp(n)
            mov(d, returnSlot[e.Index], n)
            return d
        case .builtin(let f):
            return try builtin(f, e)
        case .construct:
            return try construct(e)
        case .assign:
            let p = try place(e.Args[0])
            let v = try expr(e.Args[1])
            // The value may alias the target (a = a.yx): copy through a temporary when it might.
            let src = aliases(e.Args[1]) ? copy(v, n) : v
            store(p, src, n)
            return src
        case .compoundAssign(let b):
            let p = try place(e.Args[0])
            let combined = shader.Expr(.binary(b), t, [e.Args[0], e.Args[1]])
            let v = try binary(b, combined)
            store(p, v, n)
            return v
        case .preIncrement, .preDecrement, .postIncrement, .postDecrement:
            let p = try place(e.Args[0])
            let old = copy(try expr(e.Args[0]), n)
            let one = constant([t.IsFloat ? float32(1).bitPattern : 1])
            let d = temp(n)
            let up = e.Op == .preIncrement || e.Op == .postIncrement
            op(t.IsFloat ? (up ? .fadd : .fsub) : (up ? .iadd : .isub), n: n, dst: d, a: old, b: one, sb: 0)
            store(p, d, n)
            return e.Op == .preIncrement || e.Op == .preDecrement ? d : old
        case .sequence:
            var last = 0
            for a in e.Args { last = try expr(a) }
            return last
        }
    }

    func copy(_ src: int, _ n: int) -> int {
        let d = temp(n)
        mov(d, src, n)
        return d
    }

    /// Whether an expression's value might be read from a variable's own
    /// slots (so writing that variable first would change it).
    func aliases(_ e: shader.Expr) -> bool {
        switch e.Op {
        case .variable, .swizzle, .field, .index: return true
        default: return false
        }
    }

    // MARK: operators

    func binary(_ b: shader.BinaryOp, _ e: shader.Expr) throws -> int {
        let l = e.Args[0]
        let r = e.Args[1]
        let t = e.Type
        // && and || evaluate their right side only when needed.
        if b == .logicalAnd || b == .logicalOr {
            let a = try expr(l)
            let d = temp(1)
            mov(d, a, 1)
            var i = Instr(.ifBegin)
            if b == .logicalAnd {
                i.A = d
            } else {
                let notA = temp(1)
                op(.not, n: 1, dst: notA, a: d)
                i.A = notA
            }
            let begin = emit(i)
            let v = try expr(r)
            mov(d, v, 1)
            let end = emit(Instr(.ifEnd))
            code[begin].Target = end
            return d
        }
        let a = try expr(l)
        let c = try expr(r)
        if b == .multiply && (l.Type.IsMatrix || r.Type.IsMatrix) && !(l.Type.IsScalar || r.Type.IsScalar) {
            // A linear-algebra product: rows of A × inner × columns of B.
            let rows = l.Type.IsMatrix ? l.Type.Rows : 1
            let inner = l.Type.IsMatrix ? l.Type.Columns : l.Type.Rows
            let cols = r.Type.IsMatrix ? r.Type.Columns : 1
            let d = temp(m.Slots(t))
            var i = Instr(.matmul)
            i.Dst = d
            i.A = a
            i.B = c
            i.Aux = rows
            i.Aux2 = inner
            i.Aux3 = cols
            _ = emit(i)
            return d
        }
        if b == .equal || b == .notEqual {
            let d = temp(1)
            var i = Instr(.eqAll)
            i.N = m.Slots(l.Type)
            i.Dst = d
            i.A = a
            i.B = c
            i.Aux = l.Type.IsFloat ? 1 : 0
            _ = emit(i)
            if b == .notEqual { op(.not, n: 1, dst: d, a: d) }
            return d
        }
        let n = max(m.Slots(l.Type), m.Slots(r.Type))
        let sa = l.Type.IsScalar && n > 1 ? 0 : 1
        let sb = r.Type.IsScalar && n > 1 ? 0 : 1
        let d = temp(m.Slots(t))
        let k = l.Type.Kind
        var o: Op
        switch b {
        case .add: o = k == .float ? .fadd : .iadd
        case .subtract: o = k == .float ? .fsub : .isub
        case .multiply: o = k == .float ? .fmul : .imul
        case .divide: o = k == .float ? .fdiv : (k == .uint ? .udiv : .idiv)
        case .remainder: o = k == .uint ? .urem : .irem
        case .less: o = k == .float ? .flt : (k == .uint ? .ult : .ilt)
        case .lessEqual: o = k == .float ? .fle : (k == .uint ? .ule : .ile)
        case .greater: o = k == .float ? .fgt : (k == .uint ? .ugt : .igt)
        case .greaterEqual: o = k == .float ? .fge : (k == .uint ? .uge : .ige)
        case .logicalXor: o = .ine
        case .bitAnd: o = .and
        case .bitOr: o = .or
        case .bitXor: o = .xor
        case .shiftLeft: o = .shl
        case .shiftRight: o = k == .uint ? .shrU : .shrI
        default: throw CompileError("operator \(b) isn't compiled")
        }
        op(o, n: n, dst: d, a: a, b: c, sa: sa, sb: sb)
        return d
    }

    // MARK: constructors

    func conversion(_ from: shader.Kind, _ to: shader.Kind) -> Op {
        switch to {
        case .float:
            switch from {
            case .int: return .i2f
            case .uint: return .u2f
            case .bool: return .b2f
            default: return .mov
            }
        case .int, .uint:
            switch from {
            case .float: return to == .int ? .f2i : .f2u
            default: return .mov   // int ↔ uint keep their bits; a bool is already 0 or 1
            }
        case .bool:
            switch from {
            case .float: return .f2b
            case .int, .uint: return .i2b
            default: return .mov
            }
        default:
            return .mov
        }
    }

    func construct(_ e: shader.Expr) throws -> int {
        let t = e.Type
        let n = m.Slots(t)
        let d = temp(n)
        if t.IsArray || t.IsStruct {
            var at = d
            for a in e.Args {
                let w = m.Slots(a.Type)
                mov(at, try expr(a), w)
                at += w
            }
            return d
        }
        let args = e.Args
        if args.count == 1 && args[0].Type.IsScalar {
            let v = try expr(args[0])
            let one = temp(1)
            op(conversion(args[0].Type.Kind, t.Kind), n: 1, dst: one, a: v)
            if t.IsMatrix {
                mov(d, constant([0]), n, stride: 0)
                for c in 0..<min(t.Columns, t.Rows) { mov(d + c * t.Rows + c, one, 1) }
            } else {
                mov(d, one, n, stride: 0)
            }
            return d
        }
        if args.count == 1 && args[0].Type.IsMatrix && t.IsMatrix {
            let src = try expr(args[0])
            let st = args[0].Type
            let zero = constant([0])
            let oneBits = constant([float32(1).bitPattern])
            for c in 0..<t.Columns {
                for r in 0..<t.Rows {
                    if c < st.Columns && r < st.Rows {
                        mov(d + c * t.Rows + r, src + c * st.Rows + r, 1)
                    } else {
                        mov(d + c * t.Rows + r, c == r ? oneBits : zero, 1)
                    }
                }
            }
            return d
        }
        var at = 0
        for a in args {
            if at >= n { break }
            let v = try expr(a)
            let take = min(m.Slots(a.Type), n - at)
            op(conversion(a.Type.Kind, t.Kind), n: take, dst: d + at, a: v)
            at += take
        }
        return d
    }
}
