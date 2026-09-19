import Foundation

public struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private var state: UInt32 = 0xFFFFFFFF

    public init() {}

    public mutating func update(_ data: Data) {
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for b in buf { state = CRC32.table[Int((state ^ UInt32(b)) & 0xFF)] ^ (state >> 8) }
        }
    }

    public var value: UInt32 { state ^ 0xFFFFFFFF }

    public static func checksum(_ data: Data) -> UInt32 {
        var c = CRC32()
        c.update(data)
        return c.value
    }
}
