// A small, dependency-free gzip decoder (RFC 1952 wrapper around RFC 1951 inflate),
// so io works identically on Apple platforms and Linux without linking zlib.
// Output is capped (`maxOutput`), so a tiny compressed input can't expand without bound.

import PMTiles

package enum InflateError: Error {
    case corrupt
    case tooLarge
}

/// Decodes a gzip member. Throws `.tooLarge` once output would exceed `maxOutput`.
package func gunzip(_ data: [UInt8], maxOutput: Int) throws(InflateError) -> [UInt8] {
    // Header: ID1 ID2 CM FLG MTIME(4) XFL OS, then optional fields by FLG.
    guard data.count >= 18, data[0] == 0x1F, data[1] == 0x8B, data[2] == 8 else { throw .corrupt }
    let flags = data[3]
    guard flags & 0xE0 == 0 else { throw .corrupt }
    var p = 10
    if flags & 0x04 != 0 {  // FEXTRA
        guard p + 2 <= data.count else { throw .corrupt }
        p += 2 + Int(data[p]) | Int(data[p + 1]) << 8
    }
    if flags & 0x08 != 0 {  // FNAME, zero-terminated
        while p < data.count && data[p] != 0 { p += 1 }
        p += 1
    }
    if flags & 0x10 != 0 {  // FCOMMENT, zero-terminated
        while p < data.count && data[p] != 0 { p += 1 }
        p += 1
    }
    if flags & 0x02 != 0 { p += 2 }  // FHCRC
    guard p <= data.count - 8 else { throw .corrupt }

    var inflater = Inflater(data, start: p, end: data.count - 8, maxOutput: maxOutput)
    try inflater.run()
    let out = inflater.out

    let t = data.count - 8
    let crc = UInt32(data[t]) | UInt32(data[t + 1]) << 8 | UInt32(data[t + 2]) << 16 | UInt32(data[t + 3]) << 24
    let size = UInt32(data[t + 4]) | UInt32(data[t + 5]) << 8 | UInt32(data[t + 6]) << 16 | UInt32(data[t + 7]) << 24
    guard crc32(out) == crc, UInt32(truncatingIfNeeded: out.count) == size else { throw .corrupt }
    return out
}

// MARK: - CRC-32 (IEEE)

private let crcTable: [UInt32] = (0..<256).map { n in
    var c = UInt32(n)
    for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    return c
}

package func crc32(_ bytes: [UInt8]) -> UInt32 {
    var c: UInt32 = 0xFFFF_FFFF
    for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
    return c ^ 0xFFFF_FFFF
}

// MARK: - Inflate (RFC 1951)

private let lengthBase: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
private let lengthExtra: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
private let distBase: [Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
private let distExtra: [Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
private let codeLengthOrder: [Int] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

/// Canonical Huffman decoding table (counts per length + symbols in code order).
private struct Huffman {
    var counts = [Int](repeating: 0, count: 16)
    var symbols: [Int]

    init(lengths: [Int]) throws(InflateError) {
        symbols = [Int](repeating: 0, count: lengths.count)
        for l in lengths { counts[l] += 1 }
        counts[0] = 0
        // Reject over-subscribed codes (incomplete codes are allowed, as in zlib's puff).
        var left = 1
        for len in 1...15 {
            left <<= 1
            left -= counts[len]
            if left < 0 { throw .corrupt }
        }
        var offsets = [Int](repeating: 0, count: 16)
        for len in 1..<15 { offsets[len + 1] = offsets[len] + counts[len] }
        for (sym, l) in lengths.enumerated() where l != 0 {
            symbols[offsets[l]] = sym
            offsets[l] += 1
        }
    }
}

private struct Inflater {
    let data: [UInt8]
    var pos: Int
    let end: Int
    let maxOutput: Int
    var bitBuf: UInt32 = 0
    var bitCount = 0
    var out: [UInt8] = []

    init(_ data: [UInt8], start: Int, end: Int, maxOutput: Int) {
        self.data = data
        self.pos = start
        self.end = end
        self.maxOutput = maxOutput
    }

    mutating func bits(_ need: Int) throws(InflateError) -> Int {
        while bitCount < need {
            guard pos < end else { throw .corrupt }
            bitBuf |= UInt32(data[pos]) << UInt32(bitCount)
            pos += 1
            bitCount += 8
        }
        let v = Int(bitBuf & ((UInt32(1) << UInt32(need)) &- 1))
        bitBuf >>= UInt32(need)
        bitCount -= need
        return v
    }

    mutating func decode(_ h: Huffman) throws(InflateError) -> Int {
        var code = 0, first = 0, index = 0
        for len in 1...15 {
            code |= try bits(1)
            let count = h.counts[len]
            if code - count < first { return h.symbols[index + (code - first)] }
            index += count
            first += count
            first <<= 1
            code <<= 1
        }
        throw .corrupt
    }

    mutating func emit(_ byte: UInt8) throws(InflateError) {
        guard out.count < maxOutput else { throw .tooLarge }
        out.append(byte)
    }

    mutating func run() throws(InflateError) {
        var last = 0
        repeat {
            last = try bits(1)
            switch try bits(2) {
            case 0: try stored()
            case 1: try codes(Inflater.fixedLength, Inflater.fixedDistance)
            case 2: try dynamic()
            default: throw .corrupt
            }
        } while last == 0
    }

    mutating func stored() throws(InflateError) {
        bitBuf = 0
        bitCount = 0
        guard pos + 4 <= end else { throw .corrupt }
        let len = Int(data[pos]) | Int(data[pos + 1]) << 8
        let nlen = Int(data[pos + 2]) | Int(data[pos + 3]) << 8
        guard len == (~nlen & 0xFFFF) else { throw .corrupt }
        pos += 4
        guard pos + len <= end else { throw .corrupt }
        guard out.count + len <= maxOutput else { throw .tooLarge }
        out.append(contentsOf: data[pos..<pos + len])
        pos += len
    }

    static let fixedLength: Huffman = {
        var l = [Int](repeating: 8, count: 288)
        for i in 144..<256 { l[i] = 9 }
        for i in 256..<280 { l[i] = 7 }
        return try! Huffman(lengths: l)
    }()

    static let fixedDistance: Huffman = try! Huffman(lengths: [Int](repeating: 5, count: 30))

    mutating func dynamic() throws(InflateError) {
        let nlen = try bits(5) + 257
        let ndist = try bits(5) + 1
        let ncode = try bits(4) + 4
        guard nlen <= 286, ndist <= 30 else { throw .corrupt }
        var lengths = [Int](repeating: 0, count: 19)
        for i in 0..<ncode { lengths[codeLengthOrder[i]] = try bits(3) }
        let lencode = try Huffman(lengths: lengths)

        var all = [Int]()
        all.reserveCapacity(nlen + ndist)
        while all.count < nlen + ndist {
            let sym = try decode(lencode)
            if sym < 16 {
                all.append(sym)
            } else {
                var value = 0, repeatCount: Int
                switch sym {
                case 16:
                    guard let prev = all.last else { throw .corrupt }
                    value = prev
                    repeatCount = 3 + (try bits(2))
                case 17: repeatCount = 3 + (try bits(3))
                default: repeatCount = 11 + (try bits(7))
                }
                guard all.count + repeatCount <= nlen + ndist else { throw .corrupt }
                all.append(contentsOf: repeatElement(value, count: repeatCount))
            }
        }
        guard all[256] != 0 else { throw .corrupt }  // end-of-block code must exist
        try codes(Huffman(lengths: Array(all[0..<nlen])), Huffman(lengths: Array(all[nlen...])))
    }

    mutating func codes(_ lencode: Huffman, _ distcode: Huffman) throws(InflateError) {
        while true {
            var sym = try decode(lencode)
            if sym < 256 {
                try emit(UInt8(sym))
            } else if sym == 256 {
                return
            } else {
                sym -= 257
                guard sym < 29 else { throw .corrupt }
                let len = lengthBase[sym] + (try bits(lengthExtra[sym]))
                let dsym = try decode(distcode)
                guard dsym < 30 else { throw .corrupt }
                let dist = distBase[dsym] + (try bits(distExtra[dsym]))
                guard dist <= out.count else { throw .corrupt }
                guard out.count + len <= maxOutput else { throw .tooLarge }
                let start = out.count - dist
                for i in 0..<len { out.append(out[start + i]) }
            }
        }
    }
}
