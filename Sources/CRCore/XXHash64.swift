import Foundation

/// Streaming xxHash64 (seed 0), the checksum ShotPut Pro uses by default.
/// Output is the canonical big-endian hex that `xxhsum` prints.
public struct XXHash64 {
    private static let p1: UInt64 = 0x9E37_79B1_85EB_CA87
    private static let p2: UInt64 = 0xC2B2_AE3D_27D4_EB4F
    private static let p3: UInt64 = 0x1656_67B1_9E37_79F9
    private static let p4: UInt64 = 0x85EB_CA77_C2B2_AE63
    private static let p5: UInt64 = 0x27D4_EB2F_1656_67C5

    private var v1: UInt64, v2: UInt64, v3: UInt64, v4: UInt64
    private var total: UInt64 = 0
    private var buffer = [UInt8](repeating: 0, count: 32)
    private var bufferCount = 0
    private let seed: UInt64

    public init(seed: UInt64 = 0) {
        self.seed = seed
        v1 = seed &+ Self.p1 &+ Self.p2
        v2 = seed &+ Self.p2
        v3 = seed
        v4 = seed &- Self.p1
    }

    @inline(__always) private static func rotl(_ x: UInt64, _ r: UInt64) -> UInt64 { (x << r) | (x >> (64 - r)) }

    @inline(__always) private static func round(_ acc: UInt64, _ input: UInt64) -> UInt64 {
        rotl(acc &+ input &* p2, 31) &* p1
    }

    @inline(__always) private static func merge(_ acc: UInt64, _ val: UInt64) -> UInt64 {
        (acc ^ round(0, val)) &* p1 &+ p4
    }

    @inline(__always) private static func read64(_ p: UnsafeRawPointer, _ o: Int) -> UInt64 {
        UInt64(littleEndian: p.loadUnaligned(fromByteOffset: o, as: UInt64.self))
    }

    @inline(__always) private static func read32(_ p: UnsafeRawPointer, _ o: Int) -> UInt64 {
        UInt64(UInt32(littleEndian: p.loadUnaligned(fromByteOffset: o, as: UInt32.self)))
    }

    public mutating func update(_ data: UnsafeRawBufferPointer) {
        guard var p = data.baseAddress, data.count > 0 else { return }
        var len = data.count
        total &+= UInt64(len)

        if bufferCount > 0 {
            let take = min(32 - bufferCount, len)
            buffer.withUnsafeMutableBytes { b in
                (b.baseAddress! + bufferCount).copyMemory(from: p, byteCount: take)
            }
            bufferCount += take
            p += take
            len -= take
            if bufferCount < 32 { return }
            buffer.withUnsafeBytes { b in stripe(b.baseAddress!) }
            bufferCount = 0
        }

        var a = v1, b = v2, c = v3, d = v4
        while len >= 32 {
            a = Self.round(a, Self.read64(p, 0))
            b = Self.round(b, Self.read64(p, 8))
            c = Self.round(c, Self.read64(p, 16))
            d = Self.round(d, Self.read64(p, 24))
            p += 32
            len -= 32
        }
        v1 = a; v2 = b; v3 = c; v4 = d

        if len > 0 {
            buffer.withUnsafeMutableBytes { b in b.baseAddress!.copyMemory(from: p, byteCount: len) }
            bufferCount = len
        }
    }

    public mutating func update(_ data: Data) {
        data.withUnsafeBytes { update($0) }
    }

    private mutating func stripe(_ p: UnsafeRawPointer) {
        v1 = Self.round(v1, Self.read64(p, 0))
        v2 = Self.round(v2, Self.read64(p, 8))
        v3 = Self.round(v3, Self.read64(p, 16))
        v4 = Self.round(v4, Self.read64(p, 24))
    }

    public func finalize() -> UInt64 {
        var h: UInt64
        if total >= 32 {
            h = Self.rotl(v1, 1) &+ Self.rotl(v2, 7) &+ Self.rotl(v3, 12) &+ Self.rotl(v4, 18)
            h = Self.merge(h, v1)
            h = Self.merge(h, v2)
            h = Self.merge(h, v3)
            h = Self.merge(h, v4)
        } else {
            h = seed &+ Self.p5
        }
        h &+= total

        buffer.withUnsafeBytes { raw in
            let p = raw.baseAddress!
            var i = 0
            while i + 8 <= bufferCount {
                h ^= Self.round(0, Self.read64(p, i))
                h = Self.rotl(h, 27) &* Self.p1 &+ Self.p4
                i += 8
            }
            if i + 4 <= bufferCount {
                h ^= Self.read32(p, i) &* Self.p1
                h = Self.rotl(h, 23) &* Self.p2 &+ Self.p3
                i += 4
            }
            while i < bufferCount {
                h ^= UInt64(p.load(fromByteOffset: i, as: UInt8.self)) &* Self.p5
                h = Self.rotl(h, 11) &* Self.p1
                i += 1
            }
        }

        h ^= h >> 33
        h &*= Self.p2
        h ^= h >> 29
        h &*= Self.p3
        h ^= h >> 32
        return h
    }

    public static func hex(_ value: UInt64) -> String { String(format: "%016llx", value) }

    public static func hash(_ data: Data) -> UInt64 {
        var h = XXHash64()
        h.update(data)
        return h.finalize()
    }
}
