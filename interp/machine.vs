package interp

import (
    "math"
    "shader"
)

/// What a texture lookup asks of the textures, for the lanes in Mask.
/// Buffers are lane-major: lane l's coordinate k is Coords[l * 4 + k].
/// The machine owns one, its buffers made once, so a lookup moves no
/// arrays: textures read and write them in place.
public final class SampleRequest {
    public let Capacity: int
    public let Unit: UnsafeMutablePointer<int32>
    public let Coords: UnsafeMutablePointer<float32>
    /// Derivatives of the coordinates (implicit and gradient lookups).
    public let Ddx: UnsafeMutablePointer<float32>
    public let Ddy: UnsafeMutablePointer<float32>
    /// A bias or an explicit level, per lane.
    public let LodOrBias: UnsafeMutablePointer<float32>
    /// The results: four 32-bit words per lane (floats' bits, or integers for integer samplers).
    public let Result: UnsafeMutablePointer<uint32>
    public var Sampler: shader.SamplerKind = .texture2D
    public var Lookup: Lookup = .implicit
    /// Whether Ddx and Ddy hold anything (a vertex shader's implicit lookups take the base level).
    public var HasDerivatives = false
    public var Mask: uint64 = 0
    public var Lanes: int = 0

    public init(lanes: int) {
        Capacity = lanes
        Unit = UnsafeMutablePointer<int32>.allocate(capacity: lanes)
        Unit.initialize(repeating: 0, count: lanes)
        Coords = UnsafeMutablePointer<float32>.allocate(capacity: lanes * 4)
        Coords.initialize(repeating: 0, count: lanes * 4)
        Ddx = UnsafeMutablePointer<float32>.allocate(capacity: lanes * 4)
        Ddx.initialize(repeating: 0, count: lanes * 4)
        Ddy = UnsafeMutablePointer<float32>.allocate(capacity: lanes * 4)
        Ddy.initialize(repeating: 0, count: lanes * 4)
        LodOrBias = UnsafeMutablePointer<float32>.allocate(capacity: lanes)
        LodOrBias.initialize(repeating: 0, count: lanes)
        Result = UnsafeMutablePointer<uint32>.allocate(capacity: lanes * 4)
        Result.initialize(repeating: 0, count: lanes * 4)
    }

    deinit {
        Unit.deallocate()
        Coords.deallocate()
        Ddx.deallocate()
        Ddy.deallocate()
        LodOrBias.deallocate()
        Result.deallocate()
    }
}

/// Where a machine's texture lookups go: the pipeline's bound textures.
public protocol Textures: AnyObject {
    func Sample(_ r: SampleRequest)
    /// texelFetch: integer coordinates and a level, per lane.
    func Fetch(_ r: SampleRequest)
    /// textureSize: a texture's size at a level.
    func Size(unit: int, sampler: shader.SamplerKind, level: int) -> [int32]
}

/// Textures that aren't there: every lookup is transparent black.
public final class NoTextures: Textures {
    public init() {}
    public func Sample(_ r: SampleRequest) {}
    public func Fetch(_ r: SampleRequest) {}
    public func Size(unit: int, sampler: shader.SamplerKind, level: int) -> [int32] { [0, 0, 0] }
}

enum FrameKind {
    case ifFrame
    case loop
    case function
    case switchFrame
}

struct Frame {
    var kind: FrameKind
    var entry: uint64
    /// if: the lanes whose condition held; switch: lanes matched so far.
    var cond: uint64 = 0
    /// loop and switch: lanes that broke; function: lanes that returned.
    var brk: uint64 = 0
    /// loop: lanes that continued.
    var cont: uint64 = 0
    /// switch: lanes no case value matches.
    var dflt: uint64 = 0

    init(_ kind: FrameKind, entry: uint64) {
        self.kind = kind
        self.entry = entry
    }
}

/// Runs an executable on up to 64 lanes at once. Slots are slot-major:
/// slot s of lane l is at s * Lanes + l.
public final class Machine {
    public let Exe: Executable
    public let Lanes: int
    public var Textures: any Textures
    let full: uint64
    let p: UnsafeMutablePointer<uint32>
    let count: int
    var frames: [Frame] = []
    let request: SampleRequest

    public init(_ exe: Executable, lanes: int, textures: any Textures = NoTextures()) {
        Exe = exe
        Lanes = max(1, min(64, lanes))
        Textures = textures
        full = Lanes == 64 ? ~uint64(0) : (uint64(1) << uint64(Lanes)) - 1
        count = exe.SlotCount * Lanes
        request = SampleRequest(lanes: Lanes)
        p = UnsafeMutablePointer<uint32>.allocate(capacity: count)
        p.initialize(repeating: 0, count: count)
        for c in exe.Constants { Set(c.Slot, all: c.Bits) }
    }

    deinit {
        p.deallocate()
    }

    // MARK: slots

    /// Slot `s` of `lane`, as bits.
    public func Get(_ s: int, lane: int) -> uint32 { p[s * Lanes + lane] }
    public func Set(_ s: int, lane: int, _ v: uint32) { p[s * Lanes + lane] = v }
    public func GetFloat(_ s: int, lane: int) -> float32 { float32(bitPattern: p[s * Lanes + lane]) }
    public func SetFloat(_ s: int, lane: int, _ v: float32) { p[s * Lanes + lane] = v.bitPattern }

    /// Sets slot `s` in every lane (uniforms, constants).
    public func Set(_ s: int, all v: uint32) {
        let base = s * Lanes
        for l in 0..<Lanes { p[base + l] = v }
    }

    /// The raw slots, for callers that move many values at once.
    public var Slots: UnsafeMutablePointer<uint32> { p }

    // MARK: running

    /// Runs the shader for the lanes in `active`; returns the lanes still
    /// alive at the end (the rest discarded).
    public func Run(_ active: uint64) -> uint64 {
        frames.removeAll(keepingCapacity: true)
        var mask = active & full
        var disabled: uint64 = 0
        var killed: uint64 = 0
        let code = Exe.Code
        var pc = 0
        let L = Lanes
        let f = UnsafeMutableRawPointer(p).assumingMemoryBound(to: float32.self)
        while pc < code.count {
            let i = code[pc]
            pc += 1
            switch i.Op {
            // MARK: control
            case .ifBegin:
                var fr = Frame(.ifFrame, entry: mask)
                fr.cond = laneMask(i.A, mask)
                frames.append(fr)
                mask &= fr.cond
                if mask == 0 { pc = i.Target }
                continue
            case .elseBegin:
                let fr = frames[frames.count - 1]
                mask = fr.entry & ~fr.cond & ~disabled
                if mask == 0 { pc = i.Target }
                continue
            case .ifEnd:
                let fr = frames.removeLast()
                mask = fr.entry & ~disabled
                continue
            case .loopBegin:
                frames.append(Frame(.loop, entry: mask))
                continue
            case .loopCondition:
                let c = laneMask(i.A, mask)
                let failing = mask & ~c
                let k = innermost(.loop)
                frames[k].brk |= failing
                disabled |= failing
                mask &= c
                if mask == 0 { pc = i.Target }
                continue
            case .breakLoop:
                let k = innermostBreakable()
                frames[k].brk |= mask
                disabled |= mask
                mask = 0
                continue
            case .continueLoop:
                let k = innermost(.loop)
                frames[k].cont |= mask
                disabled |= mask
                mask = 0
                continue
            case .loopContinue:
                let k = innermost(.loop)
                disabled &= ~frames[k].cont
                frames[k].cont = 0
                mask = frames[k].entry & ~disabled
                continue
            case .loopBack:
                if mask != 0 { pc = i.Target }
                continue
            case .loopEnd:
                let fr = frames.removeLast()
                disabled &= ~(fr.brk | fr.cont)
                mask = fr.entry & ~disabled
                continue
            case .functionBegin:
                frames.append(Frame(.function, entry: mask))
                continue
            case .functionReturn:
                let k = innermost(.function)
                frames[k].brk |= mask
                disabled |= mask
                mask = 0
                continue
            case .functionEnd:
                let fr = frames.removeLast()
                disabled &= ~fr.brk
                mask = fr.entry & ~disabled
                continue
            case .discard:
                killed |= mask
                disabled |= mask
                mask = 0
                continue
            case .switchBegin:
                var fr = Frame(.switchFrame, entry: mask)
                let cases = Exe.SwitchCases[i.Aux]
                var none: uint64 = 0
                for l in 0..<L where mask & (uint64(1) << uint64(l)) != 0 {
                    let v = int32(bitPattern: p[i.A * L + l])
                    if !cases.contains(v) { none |= uint64(1) << uint64(l) }
                }
                fr.dflt = none
                frames.append(fr)
                mask = 0
                continue
            case .switchCase:
                let k = frames.count - 1
                var join: uint64 = 0
                if i.Aux2 == 1 {
                    join = frames[k].dflt
                } else {
                    for l in 0..<L where frames[k].entry & (uint64(1) << uint64(l)) != 0 {
                        if int32(bitPattern: p[i.A * L + l]) == int32(i.Aux) { join |= uint64(1) << uint64(l) }
                    }
                }
                frames[k].cond |= join & frames[k].entry
                mask = frames[k].cond & ~disabled
                continue
            case .switchEnd:
                let fr = frames.removeLast()
                disabled &= ~fr.brk
                mask = fr.entry & ~disabled
                continue
            default:
                break
            }
            if mask == 0 { continue }
            execute(i, mask, f)
        }
        return (active & full) & ~killed
    }

    func innermost(_ kind: FrameKind) -> int {
        var k = frames.count - 1
        while k >= 0 {
            if frames[k].kind == kind { return k }
            k -= 1
        }
        return 0
    }

    func innermostBreakable() -> int {
        var k = frames.count - 1
        while k >= 0 {
            if frames[k].kind == .loop || frames[k].kind == .switchFrame { return k }
            k -= 1
        }
        return 0
    }

    /// The lanes of `mask` where slot `s` is true (nonzero).
    func laneMask(_ s: int, _ mask: uint64) -> uint64 {
        var out: uint64 = 0
        let base = s * Lanes
        for l in 0..<Lanes where mask & (uint64(1) << uint64(l)) != 0 {
            if p[base + l] != 0 { out |= uint64(1) << uint64(l) }
        }
        return out
    }
}
