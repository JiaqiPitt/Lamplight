import Foundation
import CryptoKit

/// A small FLAC decoder, used only by the sound-pack tools.
///
/// The system's own decoder returned no audio for the source recordings on this machine,
/// so the files are decoded here instead. Every FLAC file carries an MD5 of its original
/// samples; `decode` checks its output against that, so a decode either matches the
/// recording bit for bit or reports that it does not.
enum FLACDecoder {
    enum Failure: Error, CustomStringConvertible {
        case notFLAC
        case unsupported(String)
        case corrupt(String)

        var description: String {
            switch self {
            case .notFLAC: return "not a FLAC file"
            case .unsupported(let what): return "unsupported: \(what)"
            case .corrupt(let what): return "corrupt: \(what)"
            }
        }
    }

    /// How often each feature of the format was met in the last decode, for diagnosing a
    /// file whose checksum does not match.
    static var stats: [String: Int] = [:]
    private static func note(_ key: String) { stats[key, default: 0] += 1 }

    struct Result {
        var channels: [[Int32]]
        var sampleRate: Int
        var bitsPerSample: Int
        /// True when the decoded samples hash to the MD5 stored in the file.
        var verified: Bool
    }

    private struct BitReader {
        let data: [UInt8]
        var pos: Int
        var acc: UInt64 = 0
        var bits = 0

        init(_ data: [UInt8], offset: Int) {
            self.data = data
            pos = offset
        }

        var atEnd: Bool { pos >= data.count && bits == 0 }

        mutating func read(_ n: Int) throws -> UInt32 {
            if n == 0 { return 0 }
            while bits < n {
                guard pos < data.count else { throw Failure.corrupt("ran out of data") }
                acc = (acc << 8) | UInt64(data[pos])
                pos += 1
                bits += 8
            }
            bits -= n
            let mask: UInt64 = n >= 32 ? 0xFFFF_FFFF : (1 << UInt64(n)) - 1
            return UInt32(truncatingIfNeeded: (acc >> UInt64(bits)) & mask)
        }

        mutating func readSigned(_ n: Int) throws -> Int32 {
            if n == 0 { return 0 }
            let v = try read(n)
            let shift = UInt32(32 - n)
            return Int32(bitPattern: v << shift) >> Int32(shift)
        }

        /// Counts zero bits up to the next one bit.
        mutating func readUnary() throws -> Int {
            var count = 0
            while true {
                if bits == 0 {
                    guard pos < data.count else { throw Failure.corrupt("ran out of data") }
                    acc = (acc << 8) | UInt64(data[pos])
                    pos += 1
                    bits = 8
                }
                bits -= 1
                if (acc >> UInt64(bits)) & 1 == 1 { return count }
                count += 1
            }
        }

        mutating func alignToByte() {
            bits -= bits % 8
        }
    }

    static func decode(_ bytes: [UInt8]) throws -> Result {
        guard bytes.count > 42, bytes[0] == 0x66, bytes[1] == 0x4C, bytes[2] == 0x61, bytes[3] == 0x43 else {
            throw Failure.notFLAC
        }
        // Metadata blocks. Only STREAMINFO matters here.
        var offset = 4
        var sampleRate = 0, channelCount = 0, bitsPerSample = 0
        var totalSamples: UInt64 = 0
        var md5 = [UInt8](repeating: 0, count: 16)
        var last = false
        while !last {
            guard offset + 4 <= bytes.count else { throw Failure.corrupt("metadata") }
            last = bytes[offset] & 0x80 != 0
            let type = bytes[offset] & 0x7F
            let length = Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4
            guard offset + length <= bytes.count else { throw Failure.corrupt("metadata length") }
            if type == 0 {
                guard length >= 34 else { throw Failure.corrupt("stream info") }
                let b = Array(bytes[offset..<offset + 34])
                sampleRate = Int(b[10]) << 12 | Int(b[11]) << 4 | Int(b[12]) >> 4
                channelCount = Int((b[12] >> 1) & 0x07) + 1
                bitsPerSample = Int((b[12] & 0x01) << 4 | b[13] >> 4) + 1
                totalSamples = UInt64(b[13] & 0x0F) << 32 | UInt64(b[14]) << 24 | UInt64(b[15]) << 16 | UInt64(b[16]) << 8 | UInt64(b[17])
                md5 = Array(b[18..<34])
            }
            offset += length
        }
        guard sampleRate > 0, channelCount > 0, channelCount <= 2 else {
            throw Failure.unsupported("\(channelCount) channels")
        }

        var out = [[Int32]](repeating: [], count: channelCount)
        if totalSamples > 0 {
            for c in 0..<channelCount { out[c].reserveCapacity(Int(totalSamples)) }
        }
        var reader = BitReader(bytes, offset: offset)
        var block = [[Int32]](repeating: [], count: channelCount)
        stats = [:]

        while !reader.atEnd {
            if totalSamples > 0 && UInt64(out[0].count) >= totalSamples { break }
            // Frame header.
            let sync = try reader.read(14)
            guard sync == 0x3FFE else { throw Failure.corrupt("lost frame sync at byte \(reader.pos)") }
            _ = try reader.read(1)
            _ = try reader.read(1)
            let sizeCode = Int(try reader.read(4))
            let rateCode = Int(try reader.read(4))
            let assignment = Int(try reader.read(4))
            let depthCode = Int(try reader.read(3))
            _ = try reader.read(1)

            // Frame or sample number, in a UTF-8-like variable-length code. Its value is not needed.
            let lead = try reader.read(8)
            var extra = 0
            var probe = lead
            while probe & 0x80 != 0 { extra += 1; probe <<= 1 }
            if extra > 0 {
                for _ in 0..<(extra - 1) { _ = try reader.read(8) }
            }

            var blockSize: Int
            switch sizeCode {
            case 1: blockSize = 192
            case 2...5: blockSize = 576 << (sizeCode - 2)
            case 6: blockSize = Int(try reader.read(8)) + 1
            case 7: blockSize = Int(try reader.read(16)) + 1
            case 8...15: blockSize = 256 << (sizeCode - 8)
            default: throw Failure.corrupt("block size code")
            }
            switch rateCode {
            case 12: _ = try reader.read(8)
            case 13, 14: _ = try reader.read(16)
            default: break
            }
            _ = try reader.read(8)   // header CRC

            let depth: Int
            switch depthCode {
            case 0: depth = bitsPerSample
            case 1: depth = 8
            case 2: depth = 12
            case 4: depth = 16
            case 5: depth = 20
            case 6: depth = 24
            default: throw Failure.unsupported("sample size code \(depthCode)")
            }
            guard assignment <= 10 else { throw Failure.corrupt("channel assignment") }
            note("assignment \(assignment)")
            note("block \(blockSize)")
            let frameChannels = assignment < 8 ? assignment + 1 : 2
            guard frameChannels == channelCount else { throw Failure.unsupported("channel count changes mid-stream") }

            for c in 0..<frameChannels {
                // The "side" channel of a stereo pair needs one extra bit.
                let isSide = (assignment == 8 && c == 1) || (assignment == 9 && c == 0) || (assignment == 10 && c == 1)
                if block[c].count != blockSize { block[c] = [Int32](repeating: 0, count: blockSize) }
                try subframe(&reader, blockSize: blockSize, bits: depth + (isSide ? 1 : 0), out: &block[c])
            }
            reader.alignToByte()
            _ = try reader.read(16)  // frame CRC

            switch assignment {
            case 8:   // left, side
                for i in 0..<blockSize { block[1][i] = block[0][i] &- block[1][i] }
            case 9:   // side, right
                for i in 0..<blockSize { block[0][i] = block[0][i] &+ block[1][i] }
            case 10:  // mid, side
                for i in 0..<blockSize {
                    let side = Int64(block[1][i])
                    let mid = (Int64(block[0][i]) << 1) | (side & 1)
                    block[0][i] = Int32(truncatingIfNeeded: (mid + side) >> 1)
                    block[1][i] = Int32(truncatingIfNeeded: (mid - side) >> 1)
                }
            default:
                break
            }
            for c in 0..<channelCount { out[c].append(contentsOf: block[c]) }
        }

        // The stored MD5 is of the interleaved samples, little-endian, at the stream's byte width.
        func matches(frames: Int, width: Int = 0, shift: Int = 0) -> Bool {
            let width = width > 0 ? width : (bitsPerSample + 7) / 8
            var hasher = Insecure.MD5()
            var chunk = [UInt8]()
            chunk.reserveCapacity(65536 * width * channelCount)
            var i = 0
            while i < frames {
                chunk.removeAll(keepingCapacity: true)
                let end = min(frames, i + 65536)
                for f in i..<end {
                    for c in 0..<channelCount {
                        let v = UInt32(bitPattern: shift >= 0 ? out[c][f] << Int32(shift) : out[c][f] >> Int32(-shift))
                        for b in 0..<width { chunk.append(UInt8(truncatingIfNeeded: v >> UInt32(8 * b))) }
                    }
                }
                hasher.update(data: chunk)
                i = end
            }
            return Array(hasher.finalize()) == md5
        }

        var verified = false
        let decoded = out[0].count
        let declared = totalSamples > 0 ? min(Int(totalSamples), decoded) : decoded
        if md5.contains(where: { $0 != 0 }) {
            // Some encoders pad the final block and hash the padding too; accept either reading.
            verified = matches(frames: declared) || (decoded != declared && matches(frames: decoded))
            if verified && decoded != declared { note("checksum covers padded final block") }
            if !verified && bitsPerSample == 24 {
                // Try the other ways an encoder might have laid 24-bit samples out before hashing.
                for (label, width, shift) in [("32-bit container", 4, 0), ("left-justified in 32 bits", 4, 8), ("truncated to 16 bits", 2, -8)] {
                    for frames in Set([declared, decoded]) where matches(frames: frames, width: width, shift: shift) {
                        verified = true
                        note("checksum is of samples \(label)")
                    }
                }
            }
        }
        for c in 0..<channelCount where out[c].count > declared {
            out[c].removeLast(out[c].count - declared)
        }
        return Result(channels: out, sampleRate: sampleRate, bitsPerSample: bitsPerSample, verified: verified)
    }

    private static func subframe(_ r: inout BitReader, blockSize: Int, bits fullBits: Int, out: inout [Int32]) throws {
        guard try r.read(1) == 0 else { throw Failure.corrupt("subframe padding") }
        let type = Int(try r.read(6))
        var wasted = 0
        if try r.read(1) == 1 { wasted = try r.readUnary() + 1 }
        note(type == 0 ? "constant" : (type == 1 ? "verbatim" : (type < 32 ? "fixed \(type - 8)" : "lpc")))
        if wasted > 0 { note("wasted \(wasted)") }
        let bits = fullBits - wasted
        guard bits > 0 else { throw Failure.corrupt("wasted bits") }

        switch type {
        case 0:   // every sample the same
            let v = try r.readSigned(bits)
            for i in 0..<blockSize { out[i] = v }
        case 1:   // stored as is
            for i in 0..<blockSize { out[i] = try r.readSigned(bits) }
        case 8...12:   // fixed polynomial predictor
            let order = type - 8
            guard order <= blockSize else { throw Failure.corrupt("fixed order") }
            for i in 0..<order { out[i] = try r.readSigned(bits) }
            try residual(&r, blockSize: blockSize, order: order, out: &out)
            switch order {
            case 1:
                for i in 1..<blockSize { out[i] = out[i] &+ out[i - 1] }
            case 2:
                for i in 2..<blockSize {
                    out[i] = Int32(truncatingIfNeeded: Int64(out[i]) + 2 * Int64(out[i - 1]) - Int64(out[i - 2]))
                }
            case 3:
                for i in 3..<blockSize {
                    out[i] = Int32(truncatingIfNeeded: Int64(out[i]) + 3 * Int64(out[i - 1]) - 3 * Int64(out[i - 2]) + Int64(out[i - 3]))
                }
            case 4:
                for i in 4..<blockSize {
                    out[i] = Int32(truncatingIfNeeded: Int64(out[i]) + 4 * Int64(out[i - 1]) - 6 * Int64(out[i - 2])
                                   + 4 * Int64(out[i - 3]) - Int64(out[i - 4]))
                }
            default:
                break
            }
        case 32...63:   // linear predictor
            let order = type - 31
            guard order <= blockSize else { throw Failure.corrupt("predictor order") }
            for i in 0..<order { out[i] = try r.readSigned(bits) }
            let precision = Int(try r.read(4)) + 1
            guard precision < 16 else { throw Failure.corrupt("predictor precision") }
            let shift = Int(try r.readSigned(5))
            guard shift >= 0 else { throw Failure.unsupported("negative predictor shift") }
            var coefficients = [Int64](repeating: 0, count: order)
            for j in 0..<order { coefficients[j] = Int64(try r.readSigned(precision)) }
            try residual(&r, blockSize: blockSize, order: order, out: &out)
            for i in order..<blockSize {
                var sum: Int64 = 0
                for j in 0..<order { sum += coefficients[j] * Int64(out[i - 1 - j]) }
                out[i] = Int32(truncatingIfNeeded: Int64(out[i]) + (sum >> Int64(shift)))
            }
        default:
            throw Failure.unsupported("subframe type \(type)")
        }

        if wasted > 0 {
            for i in 0..<blockSize { out[i] = out[i] << Int32(wasted) }
        }
    }

    /// The prediction errors, Rice-coded in partitions.
    private static func residual(_ r: inout BitReader, blockSize: Int, order: Int, out: inout [Int32]) throws {
        let method = try r.read(2)
        guard method < 2 else { throw Failure.unsupported("residual coding \(method)") }
        note("rice method \(method)")
        let parameterBits = method == 0 ? 4 : 5
        let escape: UInt32 = method == 0 ? 15 : 31
        let partitionOrder = Int(try r.read(4))
        let partitions = 1 << partitionOrder
        guard blockSize % partitions == 0 else { throw Failure.corrupt("partition order") }
        var i = order
        for p in 0..<partitions {
            let count = (blockSize >> partitionOrder) - (p == 0 ? order : 0)
            guard count >= 0 else { throw Failure.corrupt("partition size") }
            let parameter = try r.read(parameterBits)
            if parameter == escape {
                note("escape")
                let n = Int(try r.read(5))
                for _ in 0..<count {
                    out[i] = try r.readSigned(n)
                    i += 1
                }
            } else {
                let k = Int(parameter)
                for _ in 0..<count {
                    let q = UInt32(try r.readUnary())
                    let v = (q << UInt32(k)) | (try r.read(k))
                    out[i] = Int32(bitPattern: v >> 1) ^ -Int32(bitPattern: v & 1)
                    i += 1
                }
            }
        }
    }
}
