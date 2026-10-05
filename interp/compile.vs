package interp

import (
    "shader"
)

/// CompileError is a module this interpreter can't run.
public struct CompileError: Error {
    public let Message: string

    public init(_ message: string) {
        Message = message
    }
}

/// Where an assignment writes: slots directly, or an element chosen at
/// run time by an index.
enum Place {
    case direct([int])
    /// base[index]: `inner` are slot offsets within one element.
    case indexed(base: int, width: int, count: int, index: int, inner: [int])
}

/// Compiles `m` for the interpreter.
public func Compile(_ m: shader.Module) throws -> Executable {
    let c = Compiler(m)
    try c.run()
    return c.exe
}

final class Compiler {
    let m: shader.Module
    let exe: Executable
    var offsets: [int] = []
    var returnSlot: [int] = []
    var top = 0
    var maxTop = 0
    var constantSlots: [string: int] = [:]
    var constants: [ConstantSlot] = []
    var constEnd = 0
    var code: [Instr] = []
    /// The function being inlined, innermost last: Module.Functions indices.
    var inlining: [int] = []

    init(_ m: shader.Module) {
        self.m = m
        exe = Executable(m)
    }

    func run() throws {
        // Every variable, then each function's result, then constants and temporaries.
        var at = 0
        for v in m.Variables {
            offsets.append(at)
            at += max(1, m.Slots(v.Type))
        }
        for f in m.Functions {
            returnSlot.append(at)
            at += max(1, m.Slots(f.Result))
        }
        constEnd = at
        top = at
        maxTop = at
        exe.Offsets = offsets
        reflect()
        // Global initializers, then main.
        for s in m.Init { try stmt(s) }
        if m.EntryPoint < 0 { throw CompileError("no main") }
        try inline(m.EntryPoint, args: [])
        // Constants were numbered from constBase; they live after every temporary.
        let first = maxTop
        func reloc(_ s: int) -> int { s >= constBase ? s - constBase + first : s }
        for k in 0..<code.count {
            code[k].Dst = reloc(code[k].Dst)
            code[k].A = reloc(code[k].A)
            code[k].B = reloc(code[k].B)
            code[k].C = reloc(code[k].C)
        }
        exe.Code = code
        exe.Constants = constants.map { ConstantSlot(slot: reloc($0.Slot), bits: $0.Bits) }
        exe.SlotCount = first + constCount + 1
    }

    // MARK: reflection

    func reflect() {
        for v in m.Variables {
            let o = offsets[v.Index]
            switch v.Storage {
            case .uniform:
                flattenUniform(v.Name, v.Type, o)
            case .input:
                exe.Inputs.append(Interface(name: v.Name, type: v.Type, offset: o, slots: m.Slots(v.Type), location: v.Location, flat: v.Flat))
            case .output:
                exe.Outputs.append(Interface(name: v.Name, type: v.Type, offset: o, slots: m.Slots(v.Type), location: v.Location, flat: v.Flat))
            case .builtin(let b):
                switch b {
                case .position: exe.Position = o
                case .pointSize: exe.PointSize = o
                case .fragCoord: exe.FragCoord = o
                case .frontFacing: exe.FrontFacing = o
                case .pointCoord: exe.PointCoord = o
                case .fragColor: exe.FragColor = o
                case .fragData: exe.FragData = o
                case .fragDepth: exe.FragDepth = o
                case .vertexId: exe.VertexId = o
                case .instanceId: exe.InstanceId = o
                default: break
                }
            default:
                break
            }
        }
    }

    /// GL's names for a uniform's parts: an array's elements, a struct's fields.
    func flattenUniform(_ name: string, _ t: shader.DataType, _ offset: int) {
        if t.IsArray {
            let elem = t.Element
            let w = m.Slots(elem)
            if elem.IsStruct {
                for i in 0..<t.ArrayCount { flattenUniform("\(name)[\(i)]", elem, offset + i * w) }
            } else {
                // One entry per element; the first carries the array size, named name[0] (GL also accepts name).
                for i in 0..<t.ArrayCount {
                    exe.Uniforms.append(Uniform(name: "\(name)[\(i)]", type: elem, offset: offset + i * w, arraySize: i == 0 ? t.ArrayCount : 1))
                }
            }
            return
        }
        if case .structure(let s) = t.Kind {
            var at = offset
            for f in m.Structs[s].Fields {
                flattenUniform("\(name).\(f.Name)", f.Type, at)
                at += m.Slots(f.Type)
            }
            return
        }
        exe.Uniforms.append(Uniform(name: name, type: t, offset: offset, arraySize: 1))
    }

    // MARK: slots

    func temp(_ n: int) -> int {
        let o = top
        top += max(1, n)
        if top > maxTop { maxTop = top }
        return o
    }

    /// Constants get slots numbered from here while compiling; run moves
    /// them past the temporaries, so no temporary ever reuses one.
    let constBase = 1 << 24
    var constCount = 0

    func constant(_ bits: [uint32]) -> int {
        let key = bits.map { string($0) }.joined(separator: ",")
        if let o = constantSlots[key] { return o }
        let o = constBase + constCount
        constCount += max(1, bits.count)
        for (k, b) in bits.enumerated() { constants.append(ConstantSlot(slot: o + k, bits: b)) }
        constantSlots[key] = o
        return o
    }

    func emit(_ i: Instr) -> int {
        code.append(i)
        return code.count - 1
    }

    func op(_ o: Op, n: int, dst: int, a: int = 0, b: int = 0, c: int = 0, sa: int = 1, sb: int = 1, sc: int = 1) {
        var i = Instr(o)
        i.N = n
        i.Dst = dst
        i.A = a
        i.B = b
        i.C = c
        i.StrideA = sa
        i.StrideB = sb
        i.StrideC = sc
        _ = emit(i)
    }

    func mov(_ dst: int, _ src: int, _ n: int, stride: int = 1) {
        if dst == src && stride == 1 { return }
        op(.mov, n: n, dst: dst, a: src, sa: stride)
    }

    /// Runs `body` and frees the temporaries it took, keeping constants.
    func scoped(_ body: () throws -> Void) rethrows {
        let save = top
        try body()
        top = save
    }

    // MARK: statements

    func stmts(_ list: [shader.Stmt]) throws {
        for s in list { try stmt(s) }
    }

    func stmt(_ s: shader.Stmt) throws {
        switch s.Op {
        case .expr:
            try scoped { _ = try expr(s.Expr!) }
        case .declare:
            let v = m.Variables[s.Index]
            let n = m.Slots(v.Type)
            if let e = s.Expr {
                try scoped {
                    let r = try expr(e)
                    mov(offsets[v.Index], r, n)
                }
            } else {
                mov(offsets[v.Index], constant([0]), n, stride: 0)
            }
        case .ifElse:
            var cond = 0
            try scoped { cond = try expr(s.Expr!) }
            // The condition must survive the body: copy it out of the temporaries.
            let keep = temp(1)
            mov(keep, cond, 1)
            var i = Instr(.ifBegin)
            i.A = keep
            let begin = emit(i)
            try stmts(s.Body)
            var elseAt = -1
            if !s.Else.isEmpty {
                elseAt = emit(Instr(.elseBegin))
                try stmts(s.Else)
            }
            let end = emit(Instr(.ifEnd))
            code[begin].Target = elseAt >= 0 ? elseAt : end
            if elseAt >= 0 { code[elseAt].Target = end }
        case .loop, .doWhile:
            _ = emit(Instr(.loopBegin))
            let topAt = code.count
            var condAt = -1
            if s.Op == .loop, let c = s.Expr {
                try scoped {
                    let r = try expr(c)
                    var i = Instr(.loopCondition)
                    i.A = r
                    condAt = emit(i)
                }
            }
            try stmts(s.Body)
            _ = emit(Instr(.loopContinue))
            if let step = s.Step { try scoped { _ = try expr(step) } }
            if s.Op == .doWhile {
                try scoped {
                    let r = try expr(s.Expr!)
                    var i = Instr(.loopCondition)
                    i.A = r
                    condAt = emit(i)
                }
            }
            var back = Instr(.loopBack)
            back.Target = topAt
            _ = emit(back)
            let end = emit(Instr(.loopEnd))
            if condAt >= 0 { code[condAt].Target = end }
        case .breakLoop:
            _ = emit(Instr(.breakLoop))
        case .continueLoop:
            _ = emit(Instr(.continueLoop))
        case .returnValue:
            guard let f = inlining.last else { throw CompileError("return outside a function") }
            if let e = s.Expr {
                try scoped {
                    let r = try expr(e)
                    mov(returnSlot[f], r, m.Slots(e.Type))
                }
            }
            _ = emit(Instr(.functionReturn))
        case .discard:
            _ = emit(Instr(.discard))
        case .block:
            try stmts(s.Body)
        case .switchCase:
            var value = 0
            try scoped { value = try expr(s.Expr!) }
            let keep = temp(1)
            mov(keep, value, 1)
            var b = Instr(.switchBegin)
            b.A = keep
            b.Aux = exe.SwitchCases.count
            exe.SwitchCases.append(s.Labels.compactMap { $0.Value })
            _ = emit(b)
            var next = 0
            for (k, body) in s.Body.enumerated() {
                while next < s.Labels.count && s.Labels[next].Start == k {
                    var c = Instr(.switchCase)
                    c.A = keep
                    if let v = s.Labels[next].Value { c.Aux = int(v) } else { c.Aux2 = 1 }
                    _ = emit(c)
                    next += 1
                }
                try stmt(body)
            }
            while next < s.Labels.count {
                var c = Instr(.switchCase)
                c.A = keep
                if let v = s.Labels[next].Value { c.Aux = int(v) } else { c.Aux2 = 1 }
                _ = emit(c)
                next += 1
            }
            _ = emit(Instr(.switchEnd))
        }
    }

    // MARK: functions

    /// Inlines a call of Functions[f]: copies arguments in, runs the body,
    /// copies out parameters back. The result is in returnSlot[f].
    func inline(_ f: int, args: [shader.Expr]) throws {
        let fn = m.Functions[f]
        if inlining.contains(f) { throw CompileError("\(fn.Name) is recursive") }
        // Out arguments' places are found before the call.
        var places: [Place?] = []
        for (k, a) in args.enumerated() {
            let p = fn.Params[k]
            let n = m.Slots(m.Variables[p].Type)
            if fn.In[k] {
                let r = try expr(a)
                mov(offsets[p], r, n)
            } else {
                mov(offsets[p], constant([0]), n, stride: 0)
            }
            places.append(fn.Out[k] ? try place(a) : nil)
        }
        inlining.append(f)
        _ = emit(Instr(.functionBegin))
        try stmts(fn.Body)
        _ = emit(Instr(.functionEnd))
        inlining.removeLast()
        for (k, p) in places.enumerated() {
            if let pl = p { store(pl, offsets[fn.Params[k]], m.Slots(m.Variables[fn.Params[k]].Type)) }
        }
    }

    // MARK: places (lvalues)

    func place(_ e: shader.Expr) throws -> Place {
        switch e.Op {
        case .variable:
            let o = offsets[e.Index]
            return .direct(Array(o..<(o + m.Slots(e.Type))))
        case .field:
            let base = try place(e.Args[0])
            guard case .structure(let s) = e.Args[0].Type.Kind else { throw CompileError("field of a non-struct") }
            var off = 0
            for k in 0..<e.Index { off += m.Slots(m.Structs[s].Fields[k].Type) }
            let w = m.Slots(e.Type)
            switch base {
            case .direct(let slots): return .direct(Array(slots[off..<(off + w)]))
            case .indexed(let b, let width, let count, let index, let inner):
                return .indexed(base: b, width: width, count: count, index: index, inner: Array(inner[off..<(off + w)]))
            }
        case .swizzle:
            let base = try place(e.Args[0])
            switch base {
            case .direct(let slots): return .direct(e.Components.map { slots[$0] })
            case .indexed(let b, let width, let count, let index, let inner):
                return .indexed(base: b, width: width, count: count, index: index, inner: e.Components.map { inner[$0] })
            }
        case .index:
            let base = try place(e.Args[0])
            let w = m.Slots(e.Type)
            let count = e.Args[0].Type.IsArray ? e.Args[0].Type.ArrayCount : (e.Args[0].Type.IsMatrix ? e.Args[0].Type.Columns : e.Args[0].Type.Rows)
            let idx = e.Args[1]
            if idx.IsConstant {
                let k = int(int32(bitPattern: idx.Value[0]))
                switch base {
                case .direct(let slots): return .direct(Array(slots[(k * w)..<((k + 1) * w)]))
                case .indexed(let b, let width, let cnt, let index, let inner):
                    return .indexed(base: b, width: width, count: cnt, index: index, inner: Array(inner[(k * w)..<((k + 1) * w)]))
                }
            }
            guard case .direct(let slots) = base else { throw CompileError("two run-time indices in one assignment") }
            // A run-time index: the base must be contiguous.
            for k in 1..<max(1, slots.count) where slots[k] != slots[0] + k { throw CompileError("a run-time index into a swizzle") }
            let r = try expr(idx)
            let keep = temp(1)
            mov(keep, r, 1)
            return .indexed(base: slots[0], width: w, count: count, index: keep, inner: Array(0..<w))
        default:
            throw CompileError("not an assignable expression")
        }
    }

    func store(_ p: Place, _ value: int, _ n: int) {
        switch p {
        case .direct(let slots):
            var contiguous = true
            for k in 1..<max(1, slots.count) where slots[k] != slots[0] + k { contiguous = false }
            if contiguous {
                mov(slots[0], value, slots.count)
            } else {
                var i = Instr(.scatter)
                i.N = slots.count
                i.Dst = slots[0]
                i.A = value
                // Each target slot's offset from the first, as gather/scatter's list.
                i.Aux = packList(slots.map { $0 - slots[0] })
                if slots.allSatisfy({ $0 - slots[0] >= 0 && $0 - slots[0] < 4 }) {
                    _ = emit(i)
                } else {
                    for (k, s) in slots.enumerated() { mov(s, value + k, 1) }
                }
            }
        case .indexed(let base, let width, let count, let index, let inner):
            for (k, off) in inner.enumerated() {
                var i = Instr(.storeIndexed)
                i.N = 1
                i.Dst = base + off
                i.B = value + k
                i.C = index
                i.Aux = count
                i.Aux2 = width
                _ = emit(i)
            }
        }
    }

    /// Up to four small offsets, two bits each.
    func packList(_ list: [int]) -> int {
        var v = 0
        for (k, x) in list.enumerated() { v |= (x & 3) << (2 * k) }
        return v
    }
}
