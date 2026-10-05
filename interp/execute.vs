package interp

import (
    "math"
    "shader"
)

extension Machine {
    /// Carries out one non-control instruction for the lanes in `mask`.
    func execute(_ i: Instr, _ mask: uint64, _ f: UnsafeMutablePointer<float32>) {
        let L = Lanes
        let all = mask == full
        func on(_ l: int) -> bool { all || (mask >> uint64(l)) & 1 != 0 }
        switch i.Op {
        case .mov:
            for k in 0..<i.N {
                let d = (i.Dst + k) * L
                let a = (i.A + k * i.StrideA) * L
                for l in 0..<L where on(l) { p[d + l] = p[a + l] }
            }
        case .fadd, .fsub, .fmul, .fdiv:
            for k in 0..<i.N {
                let d = (i.Dst + k) * L
                let a = (i.A + k * i.StrideA) * L
                let b = (i.B + k * i.StrideB) * L
                switch i.Op {
                case .fadd: for l in 0..<L where on(l) { f[d + l] = f[a + l] + f[b + l] }
                case .fsub: for l in 0..<L where on(l) { f[d + l] = f[a + l] - f[b + l] }
                case .fmul: for l in 0..<L where on(l) { f[d + l] = f[a + l] * f[b + l] }
                default: for l in 0..<L where on(l) { f[d + l] = f[a + l] / f[b + l] }
                }
            }
        case .fneg:
            unary(i, mask) { x in (float32(bitPattern: x) * -1).bitPattern }
        case .iadd: binaryBits(i, mask) { a, b in a &+ b }
        case .isub: binaryBits(i, mask) { a, b in a &- b }
        case .imul: binaryBits(i, mask) { a, b in a &* b }
        case .idiv:
            binaryBits(i, mask) { a, b in
                let x = int32(bitPattern: a)
                let y = int32(bitPattern: b)
                if y == 0 || (x == int32.min && y == -1) { return 0 }
                return uint32(bitPattern: x / y)
            }
        case .irem:
            binaryBits(i, mask) { a, b in
                let x = int32(bitPattern: a)
                let y = int32(bitPattern: b)
                if y == 0 || (x == int32.min && y == -1) { return 0 }
                return uint32(bitPattern: x % y)
            }
        case .udiv: binaryBits(i, mask) { a, b in b == 0 ? 0 : a / b }
        case .urem: binaryBits(i, mask) { a, b in b == 0 ? 0 : a % b }
        case .ineg: unary(i, mask) { x in 0 &- x }
        case .and: binaryBits(i, mask) { a, b in a & b }
        case .or: binaryBits(i, mask) { a, b in a | b }
        case .xor: binaryBits(i, mask) { a, b in a ^ b }
        case .not: unary(i, mask) { x in x == 0 ? 1 : 0 }
        case .complement: unary(i, mask) { x in ~x }
        case .shl: binaryBits(i, mask) { a, b in a << (b & 31) }
        case .shrI: binaryBits(i, mask) { a, b in uint32(bitPattern: int32(bitPattern: a) >> int32(b & 31)) }
        case .shrU: binaryBits(i, mask) { a, b in a >> (b & 31) }
        case .flt: binaryBits(i, mask) { a, b in float32(bitPattern: a) < float32(bitPattern: b) ? 1 : 0 }
        case .fle: binaryBits(i, mask) { a, b in float32(bitPattern: a) <= float32(bitPattern: b) ? 1 : 0 }
        case .fgt: binaryBits(i, mask) { a, b in float32(bitPattern: a) > float32(bitPattern: b) ? 1 : 0 }
        case .fge: binaryBits(i, mask) { a, b in float32(bitPattern: a) >= float32(bitPattern: b) ? 1 : 0 }
        case .feq: binaryBits(i, mask) { a, b in float32(bitPattern: a) == float32(bitPattern: b) ? 1 : 0 }
        case .fne: binaryBits(i, mask) { a, b in float32(bitPattern: a) != float32(bitPattern: b) ? 1 : 0 }
        case .ilt: binaryBits(i, mask) { a, b in int32(bitPattern: a) < int32(bitPattern: b) ? 1 : 0 }
        case .ile: binaryBits(i, mask) { a, b in int32(bitPattern: a) <= int32(bitPattern: b) ? 1 : 0 }
        case .igt: binaryBits(i, mask) { a, b in int32(bitPattern: a) > int32(bitPattern: b) ? 1 : 0 }
        case .ige: binaryBits(i, mask) { a, b in int32(bitPattern: a) >= int32(bitPattern: b) ? 1 : 0 }
        case .ult: binaryBits(i, mask) { a, b in a < b ? 1 : 0 }
        case .ule: binaryBits(i, mask) { a, b in a <= b ? 1 : 0 }
        case .ugt: binaryBits(i, mask) { a, b in a > b ? 1 : 0 }
        case .uge: binaryBits(i, mask) { a, b in a >= b ? 1 : 0 }
        case .ieq: binaryBits(i, mask) { a, b in a == b ? 1 : 0 }
        case .ine: binaryBits(i, mask) { a, b in a != b ? 1 : 0 }
        case .eqAll:
            let d = i.Dst * L
            for l in 0..<L where on(l) {
                var same = true
                for k in 0..<i.N {
                    let a = p[(i.A + k) * L + l]
                    let b = p[(i.B + k) * L + l]
                    if i.Aux == 1 {
                        if float32(bitPattern: a) != float32(bitPattern: b) { same = false }
                    } else if a != b {
                        same = false
                    }
                }
                p[d + l] = same ? 1 : 0
            }
        case .f2i:
            unary(i, mask) { x in
                let v = float32(bitPattern: x)
                if v.isNaN { return 0 }
                return uint32(bitPattern: int32(max(-2147483648, min(2147483520, v.rounded(.towardZero)))))
            }
        case .f2u:
            unary(i, mask) { x in
                let v = float32(bitPattern: x)
                if v.isNaN || v <= 0 { return 0 }
                return uint32(min(4294967040, v.rounded(.towardZero)))
            }
        case .i2f: unary(i, mask) { x in float32(int32(bitPattern: x)).bitPattern }
        case .u2f: unary(i, mask) { x in float32(x).bitPattern }
        case .b2f: unary(i, mask) { x in x != 0 ? float32(1).bitPattern : 0 }
        case .f2b: unary(i, mask) { x in float32(bitPattern: x) != 0 ? 1 : 0 }
        case .i2b: unary(i, mask) { x in x != 0 ? 1 : 0 }
        case .select:
            for k in 0..<i.N {
                let d = (i.Dst + k) * L
                let a = (i.A + k * i.StrideA) * L
                let b = (i.B + k * i.StrideB) * L
                let c = (i.C + k * i.StrideC) * L
                for l in 0..<L where on(l) { p[d + l] = p[c + l] != 0 ? p[a + l] : p[b + l] }
            }
        case .math1:
            let fn = i.Fn
            for k in 0..<i.N {
                let d = (i.Dst + k) * L
                let a = (i.A + k * i.StrideA) * L
                for l in 0..<L where on(l) { f[d + l] = math1(fn, f[a + l]) }
            }
        case .math2:
            let fn = i.Fn
            for k in 0..<i.N {
                let d = (i.Dst + k) * L
                let a = (i.A + k * i.StrideA) * L
                let b = (i.B + k * i.StrideB) * L
                for l in 0..<L where on(l) { f[d + l] = math2(fn, f[a + l], f[b + l]) }
            }
        case .math3:
            let fn = i.Fn
            for k in 0..<i.N {
                let d = (i.Dst + k) * L
                let a = (i.A + k * i.StrideA) * L
                let b = (i.B + k * i.StrideB) * L
                let c = (i.C + k * i.StrideC) * L
                for l in 0..<L where on(l) { f[d + l] = math3(fn, f[a + l], f[b + l], f[c + l]) }
            }
        case .imin: binaryBits(i, mask) { a, b in int32(bitPattern: a) < int32(bitPattern: b) ? a : b }
        case .imax: binaryBits(i, mask) { a, b in int32(bitPattern: a) > int32(bitPattern: b) ? a : b }
        case .umin: binaryBits(i, mask) { a, b in a < b ? a : b }
        case .umax: binaryBits(i, mask) { a, b in a > b ? a : b }
        case .iabs: unary(i, mask) { x in int32(bitPattern: x) < 0 ? 0 &- x : x }
        case .isign: unary(i, mask) { x in let v = int32(bitPattern: x); return uint32(bitPattern: v > 0 ? 1 : (v < 0 ? -1 : 0)) }
        case .iclamp, .uclamp:
            for k in 0..<i.N {
                let d = (i.Dst + k) * L
                let a = (i.A + k * i.StrideA) * L
                let b = (i.B + k * i.StrideB) * L
                let c = (i.C + k * i.StrideC) * L
                for l in 0..<L where on(l) {
                    if i.Op == .iclamp {
                        let v = int32(bitPattern: p[a + l])
                        p[d + l] = uint32(bitPattern: max(int32(bitPattern: p[b + l]), min(int32(bitPattern: p[c + l]), v)))
                    } else {
                        p[d + l] = max(p[b + l], min(p[c + l], p[a + l]))
                    }
                }
            }
        case .isnan: unary(i, mask) { x in float32(bitPattern: x).isNaN ? 1 : 0 }
        case .isinf: unary(i, mask) { x in float32(bitPattern: x).isInfinite ? 1 : 0 }
        case .dot, .length, .distance, .normalize, .cross, .reflect, .refract, .faceforward:
            geometry(i, mask, f)
        case .matmul:
            let rows = i.Aux
            let inner = i.Aux2
            let cols = i.Aux3
            for l in 0..<L where on(l) {
                for c in 0..<cols {
                    for r in 0..<rows {
                        var s: float32 = 0
                        for t in 0..<inner {
                            s += f[(i.A + t * rows + r) * L + l] * f[(i.B + c * inner + t) * L + l]
                        }
                        f[(i.Dst + c * rows + r) * L + l] = s
                    }
                }
            }
        case .outer:
            for l in 0..<L where on(l) {
                for c in 0..<i.Aux2 {
                    for r in 0..<i.Aux {
                        f[(i.Dst + c * i.Aux + r) * L + l] = f[(i.A + r) * L + l] * f[(i.B + c) * L + l]
                    }
                }
            }
        case .transpose:
            let rows = i.Aux
            let cols = i.Aux2
            for l in 0..<L where on(l) {
                for c in 0..<cols {
                    for r in 0..<rows {
                        p[(i.Dst + r * cols + c) * L + l] = p[(i.A + c * rows + r) * L + l]
                    }
                }
            }
        case .determinant, .inverse:
            matrixInverse(i, mask, f)
        case .any, .all:
            let d = i.Dst * L
            for l in 0..<L where on(l) {
                var anyTrue = false
                var allTrue = true
                for k in 0..<i.N {
                    if p[(i.A + k) * L + l] != 0 { anyTrue = true } else { allTrue = false }
                }
                p[d + l] = (i.Op == .any ? anyTrue : allTrue) ? 1 : 0
            }
        case .gather:
            for k in 0..<i.N {
                let c = (i.Aux >> (2 * k)) & 3
                let d = (i.Dst + k) * L
                let a = (i.A + c) * L
                for l in 0..<L where on(l) { p[d + l] = p[a + l] }
            }
        case .scatter:
            for k in 0..<i.N {
                let c = (i.Aux >> (2 * k)) & 3
                let d = (i.Dst + c) * L
                let a = (i.A + k) * L
                for l in 0..<L where on(l) { p[d + l] = p[a + l] }
            }
        case .loadIndexed:
            for l in 0..<L where on(l) {
                let idx = max(0, min(int(int32(bitPattern: p[i.C * L + l])), i.Aux - 1))
                for k in 0..<i.N { p[(i.Dst + k) * L + l] = p[(i.A + idx * i.N + k) * L + l] }
            }
        case .storeIndexed:
            for l in 0..<L where on(l) {
                let idx = max(0, min(int(int32(bitPattern: p[i.C * L + l])), i.Aux - 1))
                p[(i.Dst + idx * i.Aux2) * L + l] = p[i.B * L + l]
            }
        case .dfdx, .dfdy, .fwidth:
            derivative(i, f)
        case .sample:
            sample(i, mask, f)
        case .texelFetch:
            fetch(i, mask)
        case .textureSize:
            for l in 0..<L where on(l) {
                let size = Textures.Size(unit: int(int32(bitPattern: p[i.A * L + l])), sampler: i.Sampler,
                                         level: int(int32(bitPattern: p[i.C * L + l])))
                for k in 0..<i.N { p[(i.Dst + k) * L + l] = uint32(bitPattern: k < size.count ? size[k] : 0) }
            }
        case .packSnorm2x16, .packUnorm2x16, .packHalf2x16:
            for l in 0..<L where on(l) {
                let x = f[i.A * L + l]
                let y = f[(i.A + 1) * L + l]
                p[i.Dst * L + l] = pack2x16(i.Op, x) | pack2x16(i.Op, y) << 16
            }
        case .unpackSnorm2x16, .unpackUnorm2x16, .unpackHalf2x16:
            for l in 0..<L where on(l) {
                let v = p[i.A * L + l]
                f[i.Dst * L + l] = unpack2x16(i.Op, v & 0xffff)
                f[(i.Dst + 1) * L + l] = unpack2x16(i.Op, v >> 16)
            }
        default:
            break
        }
    }

    func unary(_ i: Instr, _ mask: uint64, _ op: (uint32) -> uint32) {
        let L = Lanes
        for k in 0..<i.N {
            let d = (i.Dst + k) * L
            let a = (i.A + k * i.StrideA) * L
            for l in 0..<L where mask & (uint64(1) << uint64(l)) != 0 { p[d + l] = op(p[a + l]) }
        }
    }

    func binaryBits(_ i: Instr, _ mask: uint64, _ op: (uint32, uint32) -> uint32) {
        let L = Lanes
        for k in 0..<i.N {
            let d = (i.Dst + k) * L
            let a = (i.A + k * i.StrideA) * L
            let b = (i.B + k * i.StrideB) * L
            for l in 0..<L where mask & (uint64(1) << uint64(l)) != 0 { p[d + l] = op(p[a + l], p[b + l]) }
        }
    }

    // MARK: geometry and matrices

    func geometry(_ i: Instr, _ mask: uint64, _ f: UnsafeMutablePointer<float32>) {
        let L = Lanes
        let n = i.Aux
        for l in 0..<L where mask & (uint64(1) << uint64(l)) != 0 {
            func a(_ k: int) -> float32 { f[(i.A + k) * L + l] }
            func b(_ k: int) -> float32 { f[(i.B + k) * L + l] }
            func c(_ k: int) -> float32 { f[(i.C + k) * L + l] }
            func set(_ k: int, _ v: float32) { f[(i.Dst + k) * L + l] = v }
            switch i.Op {
            case .dot:
                var s: float32 = 0
                for k in 0..<n { s += a(k) * b(k) }
                set(0, s)
            case .length:
                var s: float32 = 0
                for k in 0..<n { s += a(k) * a(k) }
                set(0, s.squareRoot())
            case .distance:
                var s: float32 = 0
                for k in 0..<n { let d = a(k) - b(k); s += d * d }
                set(0, s.squareRoot())
            case .normalize:
                var s: float32 = 0
                for k in 0..<n { s += a(k) * a(k) }
                let inv = 1 / s.squareRoot()
                var out: [float32] = []
                for k in 0..<n { out.append(a(k) * inv) }
                for k in 0..<n { set(k, out[k]) }
            case .cross:
                let x = a(1) * b(2) - a(2) * b(1)
                let y = a(2) * b(0) - a(0) * b(2)
                let z = a(0) * b(1) - a(1) * b(0)
                set(0, x)
                set(1, y)
                set(2, z)
            case .reflect:
                var d: float32 = 0
                for k in 0..<n { d += b(k) * a(k) }
                var out: [float32] = []
                for k in 0..<n { out.append(a(k) - 2 * d * b(k)) }
                for k in 0..<n { set(k, out[k]) }
            case .refract:
                let eta = f[i.C * L + l]
                var d: float32 = 0
                for k in 0..<n { d += b(k) * a(k) }
                let kk = 1 - eta * eta * (1 - d * d)
                var out: [float32] = []
                for k in 0..<n { out.append(kk < 0 ? 0 : eta * a(k) - (eta * d + kk.squareRoot()) * b(k)) }
                for k in 0..<n { set(k, out[k]) }
            default:   // faceforward(N, I, Nref)
                var d: float32 = 0
                for k in 0..<n { d += c(k) * b(k) }
                var out: [float32] = []
                for k in 0..<n { out.append(d < 0 ? a(k) : -a(k)) }
                for k in 0..<n { set(k, out[k]) }
            }
        }
    }

    func matrixInverse(_ i: Instr, _ mask: uint64, _ f: UnsafeMutablePointer<float32>) {
        let L = Lanes
        let n = i.Aux
        for l in 0..<L where mask & (uint64(1) << uint64(l)) != 0 {
            // Column-major n×n; Gauss–Jordan in float64 for the inverse.
            var m = [float64](repeating: 0, count: n * n)
            for c in 0..<n { for r in 0..<n { m[r * n + c] = float64(f[(i.A + c * n + r) * L + l]) } }
            var inv = [float64](repeating: 0, count: n * n)
            for k in 0..<n { inv[k * n + k] = 1 }
            var det: float64 = 1
            for col in 0..<n {
                var pivot = col
                for r in col..<n where abs(m[r * n + col]) > abs(m[pivot * n + col]) { pivot = r }
                if m[pivot * n + col] == 0 { det = 0; break }
                if pivot != col {
                    for k in 0..<n {
                        let t = m[col * n + k]; m[col * n + k] = m[pivot * n + k]; m[pivot * n + k] = t
                        let u = inv[col * n + k]; inv[col * n + k] = inv[pivot * n + k]; inv[pivot * n + k] = u
                    }
                    det = -det
                }
                let pv = m[col * n + col]
                det *= pv
                for k in 0..<n { m[col * n + k] /= pv; inv[col * n + k] /= pv }
                for r in 0..<n where r != col {
                    let factor = m[r * n + col]
                    if factor == 0 { continue }
                    for k in 0..<n { m[r * n + k] -= factor * m[col * n + k]; inv[r * n + k] -= factor * inv[col * n + k] }
                }
            }
            if i.Op == .determinant {
                f[i.Dst * L + l] = float32(det)
            } else {
                for c in 0..<n { for r in 0..<n { f[(i.Dst + c * n + r) * L + l] = float32(inv[r * n + c]) } }
            }
        }
    }

    // MARK: derivatives

    /// Lanes come in quads: 0 (x, y), 1 (x+1, y), 2 (x, y+1), 3 (x+1, y+1).
    func derivative(_ i: Instr, _ f: UnsafeMutablePointer<float32>) {
        let L = Lanes
        for k in 0..<i.N {
            let a = (i.A + k) * L
            let d = (i.Dst + k) * L
            var q = 0
            while q + 3 < L {
                let v0 = f[a + q]
                let v1 = f[a + q + 1]
                let v2 = f[a + q + 2]
                let v3 = f[a + q + 3]
                let dxTop = v1 - v0
                let dxBottom = v3 - v2
                let dyLeft = v2 - v0
                let dyRight = v3 - v1
                switch i.Op {
                case .dfdx:
                    f[d + q] = dxTop; f[d + q + 1] = dxTop; f[d + q + 2] = dxBottom; f[d + q + 3] = dxBottom
                case .dfdy:
                    f[d + q] = dyLeft; f[d + q + 1] = dyRight; f[d + q + 2] = dyLeft; f[d + q + 3] = dyRight
                default:
                    f[d + q] = abs(dxTop) + abs(dyLeft)
                    f[d + q + 1] = abs(dxTop) + abs(dyRight)
                    f[d + q + 2] = abs(dxBottom) + abs(dyLeft)
                    f[d + q + 3] = abs(dxBottom) + abs(dyRight)
                }
                q += 4
            }
        }
    }

    // MARK: textures

    func sample(_ i: Instr, _ mask: uint64, _ f: UnsafeMutablePointer<float32>) {
        let L = Lanes
        // Locals, so the loops below touch no reference counts.
        let req = request
        let unit = req.Unit
        let coords = req.Coords
        let ddx = req.Ddx
        let ddy = req.Ddy
        let lod = req.LodOrBias
        let result = req.Result
        let fragment = Exe.Module.Stage == .fragment
        request.Lanes = L
        request.Mask = mask
        request.Sampler = i.Sampler
        request.Lookup = i.Lookup
        let n = i.Aux2
        let need = coordWidth(i.Sampler)
        for l in 0..<L {
            unit[l] = int32(bitPattern: p[i.A * L + l])
            // Projective lookups divide by the last coordinate.
            let q: float32 = i.Projective ? f[(i.B + n - 1) * L + l] : 1
            for k in 0..<4 {
                var v: float32 = 0
                if k < need && k < n { v = f[(i.B + k) * L + l] / q }
                if i.Projective && n == 4 && need == 2 && k >= 2 { v = 0 }
                coords[l * 4 + k] = v
            }
            if i.Lookup == .bias || i.Lookup == .level { lod[l] = f[i.C * L + l] }
        }
        request.HasDerivatives = false
        if i.Lookup == .gradient {
            for l in 0..<L {
                for k in 0..<need {
                    ddx[l * 4 + k] = f[(i.C + k) * L + l]
                    ddy[l * 4 + k] = f[(i.C + need + k) * L + l]
                }
            }
            request.HasDerivatives = true
        } else if fragment && (i.Lookup == .implicit || i.Lookup == .bias) {
            var q = 0
            while q + 3 < L {
                for k in 0..<need {
                    let v0 = coords[q * 4 + k]
                    let v1 = coords[(q + 1) * 4 + k]
                    let v2 = coords[(q + 2) * 4 + k]
                    let v3 = coords[(q + 3) * 4 + k]
                    ddx[q * 4 + k] = v1 - v0
                    ddx[(q + 1) * 4 + k] = v1 - v0
                    ddx[(q + 2) * 4 + k] = v3 - v2
                    ddx[(q + 3) * 4 + k] = v3 - v2
                    ddy[q * 4 + k] = v2 - v0
                    ddy[(q + 2) * 4 + k] = v2 - v0
                    ddy[(q + 1) * 4 + k] = v3 - v1
                    ddy[(q + 3) * 4 + k] = v3 - v1
                }
                q += 4
            }
            request.HasDerivatives = true
        }
        Textures.Sample(request)
        for l in 0..<L where mask & (uint64(1) << uint64(l)) != 0 {
            for k in 0..<i.N { p[(i.Dst + k) * L + l] = result[l * 4 + k] }
        }
    }

    func fetch(_ i: Instr, _ mask: uint64) {
        let L = Lanes
        request.Lanes = L
        request.Mask = mask
        request.Sampler = i.Sampler
        for l in 0..<L {
            request.Unit[l] = int32(bitPattern: p[i.A * L + l])
            for k in 0..<4 {
                // Integer coordinates travel as their bits.
                request.Coords[l * 4 + k] = k < i.Aux2 ? float32(bitPattern: p[(i.B + k) * L + l]) : 0
            }
            request.LodOrBias[l] = float32(int32(bitPattern: p[i.C * L + l]))
        }
        Textures.Fetch(request)
        for l in 0..<L where mask & (uint64(1) << uint64(l)) != 0 {
            for k in 0..<i.N { p[(i.Dst + k) * L + l] = request.Result[l * 4 + k] }
        }
    }
}

/// The coordinates a sampler kind reads (before projection).
func coordWidth(_ k: shader.SamplerKind) -> int {
    switch k {
    case .texture2D, .external, .itexture2D, .utexture2D: return 2
    case .texture3D, .cube, .array2D, .shadow2D: return 3
    case .shadowCube, .shadowArray2D: return 4
    }
}

// MARK: math

func math1(_ fn: shader.Function, _ x: float32) -> float32 {
    switch fn {
    case .radians: return x * float32(math.Pi / 180)
    case .degrees: return x * float32(180 / math.Pi)
    case .sin: return math.Sin(x)
    case .cos: return math.Cos(x)
    case .tan: return math.Tan(x)
    case .asin: return math.Asin(x)
    case .acos: return math.Acos(x)
    case .atan: return math.Atan(x)
    case .sinh: return math.Sinh(x)
    case .cosh: return math.Cosh(x)
    case .tanh: return math.Tanh(x)
    case .asinh: return math.Asinh(x)
    case .acosh: return math.Acosh(x)
    case .atanh: return math.Atanh(x)
    case .exp: return math.Exp(x)
    case .log: return math.Log(x)
    case .exp2: return math.Exp2(x)
    case .log2: return math.Log2(x)
    case .sqrt: return x.squareRoot()
    case .inversesqrt: return 1 / x.squareRoot()
    case .abs: return abs(x)
    case .sign: return x > 0 ? 1 : (x < 0 ? -1 : 0)
    case .floor: return x.rounded(.down)
    case .trunc: return x.rounded(.towardZero)
    case .round: return x.rounded(.toNearestOrAwayFromZero)
    case .roundEven: return x.rounded(.toNearestOrEven)
    case .ceil: return x.rounded(.up)
    case .fract: return x - x.rounded(.down)
    default: return x
    }
}

func math2(_ fn: shader.Function, _ a: float32, _ b: float32) -> float32 {
    switch fn {
    case .pow: return math.Pow(a, b)
    case .atan2: return math.Atan2(a, b)
    case .mod: return a - b * (a / b).rounded(.down)
    case .min: return b < a ? b : a
    case .max: return a < b ? b : a
    case .step: return b < a ? 0 : 1
    default: return a
    }
}

func math3(_ fn: shader.Function, _ a: float32, _ b: float32, _ c: float32) -> float32 {
    switch fn {
    case .clamp: return min(max(a, b), c)
    case .mix: return a * (1 - c) + b * c
    case .smoothstep:
        let t = min(max((c - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    default: return a
    }
}

func pack2x16(_ op: Op, _ v: float32) -> uint32 {
    switch op {
    case .packSnorm2x16:
        let c = (min(max(v, -1), 1) * 32767).rounded(.toNearestOrEven)
        return uint32(bitPattern: int32(c)) & 0xffff
    case .packUnorm2x16:
        return uint32((min(max(v, 0), 1) * 65535).rounded(.toNearestOrEven))
    default:
        return uint32(float16(v).bitPattern)
    }
}

func unpack2x16(_ op: Op, _ v: uint32) -> float32 {
    switch op {
    case .unpackSnorm2x16:
        let s = int16(bitPattern: uint16(v))
        return min(max(float32(s) / 32767, -1), 1)
    case .unpackUnorm2x16:
        return float32(v) / 65535
    default:
        return float32(float16(bitPattern: uint16(v)))
    }
}
