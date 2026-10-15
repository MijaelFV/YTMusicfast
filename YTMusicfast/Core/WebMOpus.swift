import Foundation

/// YouTube's best audio for everyone is Opus (about 130–160 kbps, what YouTube Music's own web
/// player streams) — clearly better than its 128 kbps AAC. It comes in WebM, which AVFoundation
/// can't open, but AVFoundation does decode Opus inside MP4. So this repackages it: the same
/// audio packets, untouched, in an MP4 container (no decoding, no quality loss, milliseconds).
///
/// Only the simple layout YouTube uses is accepted (one Opus track, unlaced blocks); anything else
/// returns nil and the caller plays the AAC stream instead.
enum WebMOpus {
    /// The MP4 to write: its header (everything before the audio) and, in order, where each audio
    /// packet is in the WebM file.
    struct Layout {
        var header: Data
        var packets: [Range<Int>]
        var length: Int { header.count + packets.reduce(0) { $0 + $1.count } }
    }

    // MARK: Reading WebM

    private struct Track {
        var number = 0
        var codec = ""
        var codecPrivate = Data()
        var codecDelay = 0  // ns
        var channels = 2
    }

    /// Lays out the MP4 for a whole WebM file.
    static func layout(_ webm: Data) -> Layout? {
        var reader = Reader(data: webm)
        guard let segment = reader.find(0x1853_8067, from: webm.startIndex, to: webm.endIndex) else { return nil }
        var track: Track?
        var packets: [Range<Int>] = []
        var discardPadding = 0  // ns, trimmed from the end
        var at = segment.body
        while at < segment.end, let element = reader.element(at: at, limit: segment.end) {
            switch element.id {
            case 0x1654_AE6B:  // Tracks
                var entryAt = element.body
                while entryAt < element.end, let entry = reader.element(at: entryAt, limit: element.end) {
                    if entry.id == 0xAE, let found = reader.track(entry), found.codec == "A_OPUS" {
                        guard track == nil else { return nil }  // more than one: not YouTube's layout
                        track = found
                    } else if entry.id == 0xAE {
                        return nil
                    }
                    entryAt = entry.end
                }
            case 0x1F43_B675:  // Cluster
                guard let track else { return nil }
                var blockAt = element.body
                while blockAt < element.end, let child = reader.element(at: blockAt, limit: element.end) {
                    // A cluster of unknown size ends where the next top-level element starts.
                    if element.unknownSize, [0x1F43_B675, 0x1C53_BB6B, 0x1254_C367].contains(child.id) { break }
                    switch child.id {
                    case 0xA3:  // SimpleBlock
                        guard let frame = reader.frame(child, track: track.number) else { return nil }
                        if !frame.isEmpty { packets.append(frame) }
                    case 0xA0:  // BlockGroup
                        var groupAt = child.body
                        while groupAt < child.end, let part = reader.element(at: groupAt, limit: child.end) {
                            if part.id == 0xA1 {
                                guard let frame = reader.frame(part, track: track.number) else { return nil }
                                if !frame.isEmpty { packets.append(frame) }
                            } else if part.id == 0x75A2 {
                                discardPadding = max(0, reader.int(part))
                            }
                            groupAt = part.end
                        }
                    default: break
                    }
                    blockAt = child.end
                }
                if element.unknownSize {
                    at = blockAt
                    continue
                }
            default: break
            }
            at = element.end
        }
        guard let track, !packets.isEmpty else { return nil }
        return mp4Header(track: track, packets: packets, in: webm, discardPadding: discardPadding)
    }

    /// Writes the MP4 for `webm` to `url`.
    static func write(_ layout: Layout, from webm: Data, to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var buffer = layout.header
        buffer.reserveCapacity(1 << 18)
        for packet in layout.packets {
            buffer += webm[packet]
            if buffer.count >= 1 << 18 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        try handle.write(contentsOf: buffer)
    }

    /// The MP4 in memory (when the disk refuses a file).
    static func data(_ layout: Layout, from webm: Data) -> Data {
        var data = Data(capacity: layout.length)
        data += layout.header
        for packet in layout.packets { data += webm[packet] }
        return data
    }

    /// Whether an MP4 file holds Opus (only some players, e.g. Cast receivers, care).
    static func isOpus(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 1 << 16) else { return false }
        return head.range(of: Data("dOps".utf8)) != nil
    }

    /// How many 48 kHz samples an Opus packet holds (from its first byte; RFC 6716 §3.1).
    static func samples(in packet: Data.SubSequence) -> Int? {
        guard let toc = packet.first else { return nil }
        let config = Int(toc >> 3)
        let frame: Int
        switch config {
        case 0...11: frame = [480, 960, 1920, 2880][config % 4]
        case 12...15: frame = [480, 960][config % 2]
        default: frame = [120, 240, 480, 960][config % 4]
        }
        let count: Int
        switch toc & 3 {
        case 0: count = 1
        case 1, 2: count = 2
        default:
            guard packet.count >= 2 else { return nil }
            count = Int(packet[packet.startIndex + 1] & 0x3F)
        }
        guard count > 0, frame * count <= 5760 else { return nil }  // at most 120 ms
        return frame * count
    }

    private struct Reader {
        let data: Data

        struct Element {
            var id: UInt32
            var body: Int
            var end: Int
            var unknownSize: Bool
        }

        func element(at offset: Int, limit: Int) -> Element? {
            guard offset < limit, let (id, idLength) = vint(at: offset, keepMarker: true), idLength <= 4,
                  let (size, sizeLength) = vint(at: offset + idLength, keepMarker: false) else { return nil }
            let body = offset + idLength + sizeLength
            // All ones: size unknown (runs to the end of its parent).
            let unknown = size == (1 << (7 * sizeLength)) - 1
            let end = unknown ? limit : body + size
            guard body <= limit, end <= limit || unknown, end >= body else { return nil }
            return Element(id: UInt32(id), body: body, end: min(end, limit), unknownSize: unknown)
        }

        func find(_ id: UInt32, from: Int, to: Int) -> Element? {
            var at = from
            while at < to, let element = element(at: at, limit: to) {
                if element.id == id { return element }
                at = element.end
            }
            return nil
        }

        /// An EBML variable-length number and its length in bytes.
        func vint(at offset: Int, keepMarker: Bool) -> (Int, Int)? {
            guard offset < data.endIndex else { return nil }
            let first = data[offset]
            guard first != 0 else { return nil }
            let length = first.leadingZeroBitCount + 1
            guard offset + length <= data.endIndex else { return nil }
            var value = keepMarker ? Int(first) : Int(first & (0xFF >> length))
            for index in 1..<length { value = value << 8 | Int(data[offset + index]) }
            return (value, length)
        }

        func uint(_ element: Element) -> Int {
            data[element.body..<element.end].prefix(8).reduce(0) { $0 << 8 | Int($1) }
        }

        func int(_ element: Element) -> Int {
            let bytes = data[element.body..<element.end].prefix(8)
            guard let first = bytes.first else { return 0 }
            var value = first & 0x80 != 0 ? -1 : 0
            for byte in bytes { value = value << 8 | Int(byte) }
            return value
        }

        func track(_ entry: Element) -> Track? {
            var track = Track()
            var at = entry.body
            while at < entry.end, let field = element(at: at, limit: entry.end) {
                switch field.id {
                case 0xD7: track.number = uint(field)
                case 0x86: track.codec = String(decoding: data[field.body..<field.end], as: UTF8.self).trimmingCharacters(in: .controlCharacters)
                case 0x63A2: track.codecPrivate = Data(data[field.body..<field.end])
                case 0x56AA: track.codecDelay = uint(field)
                case 0xE1:
                    if let channels = find(0x9F, from: field.body, to: field.end) { track.channels = uint(channels) }
                default: break
                }
                at = field.end
            }
            return track.number > 0 ? track : nil
        }

        /// The audio of a block: nil if it's laced or not for `track` (not YouTube's layout).
        func frame(_ block: Element, track: Int) -> Range<Int>? {
            guard let (number, length) = vint(at: block.body, keepMarker: false), number == track else { return nil }
            let flags = block.body + length + 2
            guard flags < block.end, (data[flags] >> 1) & 3 == 0 else { return nil }
            return (flags + 1)..<block.end
        }
    }

    // MARK: Writing MP4

    private static func mp4Header(track: Track, packets: [Range<Int>], in webm: Data, discardPadding: Int) -> Layout? {
        // Opus's own header (CodecPrivate, little-endian) → MP4's 'dOps' (big-endian).
        var channels = track.channels
        var preSkip = track.codecDelay * 48000 / 1_000_000_000
        var inputRate = 48000
        var gain = 0
        var mapping = Data([0])
        let head = track.codecPrivate
        if head.count >= 19, head.prefix(8) == Data("OpusHead".utf8) {
            let base = head.startIndex
            channels = Int(head[base + 9])
            preSkip = Int(head[base + 10]) | Int(head[base + 11]) << 8
            inputRate = Int(head[base + 12]) | Int(head[base + 13]) << 8 | Int(head[base + 14]) << 16 | Int(head[base + 15]) << 24
            gain = Int(Int16(bitPattern: UInt16(head[base + 16]) | UInt16(head[base + 17]) << 8))
            let family = head[base + 18]
            if family == 0 {
                guard channels <= 2 else { return nil }
            } else {
                // Family, stream count, coupled count, then one byte per channel.
                guard head.count >= 21 + channels else { return nil }
                mapping = Data(head[(base + 18)..<(base + 21 + channels)])
            }
        }
        guard (1...8).contains(channels) else { return nil }

        var sizes: [UInt32] = []
        sizes.reserveCapacity(packets.count)
        var durations: [(count: UInt32, delta: UInt32)] = []
        var total = 0
        for packet in packets {
            guard let samples = samples(in: webm[packet]) else { return nil }
            total += samples
            sizes.append(UInt32(packet.count))
            if let last = durations.last, last.delta == UInt32(samples) {
                durations[durations.count - 1].count += 1
            } else {
                durations.append((1, UInt32(samples)))
            }
        }
        let trailing = discardPadding * 48000 / 1_000_000_000
        let shown = total - preSkip - trailing
        guard shown > 0, total < Int(UInt32.max) else { return nil }

        var dOps = Data([0, UInt8(channels)])
        dOps.u16(preSkip)
        dOps.u32(inputRate)
        dOps.u16(gain & 0xFFFF)
        dOps += mapping

        var entry = Data(count: 6)
        entry.u16(1)  // data reference
        entry += Data(count: 8)
        entry.u16(channels)
        entry.u16(16)
        entry += Data(count: 4)
        entry.u32(48000 << 16)
        entry += box("dOps", dOps)

        // Decoders need 80 ms of audio before a seek point to settle ('roll' recovery).
        let firstSamples = Int(durations.first?.delta ?? 960)
        let roll = min(packets.count, (3840 + firstSamples - 1) / firstSamples)

        func stbl(chunkOffset: Int) -> Data {
            var stsd = Data(count: 4)
            stsd.u32(1)
            stsd += box("Opus", entry)
            var stts = Data(count: 4)
            stts.u32(durations.count)
            for run in durations {
                stts.u32(Int(run.count))
                stts.u32(Int(run.delta))
            }
            var stsc = Data(count: 4)
            stsc.u32(1)
            stsc.u32(1)
            stsc.u32(packets.count)
            stsc.u32(1)
            var stsz = Data(count: 8)
            stsz.u32(packets.count)
            for size in sizes { stsz.u32(Int(size)) }
            var stco = Data(count: 4)
            stco.u32(1)
            stco.u32(chunkOffset)
            var sgpd = Data([1, 0, 0, 0])
            sgpd += Data("roll".utf8)
            sgpd.u32(2)
            sgpd.u32(1)
            sgpd.u16(-roll & 0xFFFF)
            var sbgp = Data(count: 4)
            sbgp += Data("roll".utf8)
            sbgp.u32(packets.count > roll ? 2 : 1)
            sbgp.u32(roll)
            sbgp.u32(0)
            if packets.count > roll {
                sbgp.u32(packets.count - roll)
                sbgp.u32(1)
            }
            return box("stbl", box("stsd", stsd) + box("stts", stts) + box("stsc", stsc) + box("stsz", stsz)
                       + box("stco", stco) + box("sgpd", sgpd) + box("sbgp", sbgp))
        }

        func moov(chunkOffset: Int) -> Data {
            var mvhd = Data(count: 12)
            mvhd.u32(48000)
            mvhd.u32(shown)
            mvhd.u32(0x0001_0000)
            mvhd.u16(0x0100)
            mvhd += Data(count: 10)
            mvhd += matrix
            mvhd += Data(count: 24)
            mvhd.u32(2)

            var tkhd = Data([0, 0, 0, 3]) + Data(count: 8)
            tkhd.u32(1)
            tkhd += Data(count: 4)
            tkhd.u32(shown)
            tkhd += Data(count: 8)
            tkhd.u16(0)
            tkhd.u16(1)
            tkhd.u16(0x0100)
            tkhd += Data(count: 2)
            tkhd += matrix
            tkhd += Data(count: 8)

            // Skips the encoder's warm-up at the start and its padding at the end (gapless).
            var elst = Data(count: 4)
            elst.u32(1)
            elst.u32(shown)
            elst.u32(preSkip)
            elst.u32(0x0001_0000)

            var mdhd = Data(count: 12)
            mdhd.u32(48000)
            mdhd.u32(total)
            mdhd.u16(0x55C4)  // "und"
            mdhd.u16(0)

            var hdlr = Data(count: 8)
            hdlr += Data("soun".utf8)
            hdlr += Data(count: 12)
            hdlr += Data("SoundHandler".utf8) + Data([0])

            let dref = box("dref", Data(count: 4) + Data([0, 0, 0, 1]) + box("url ", Data([0, 0, 0, 1])))
            let minf = box("minf", box("smhd", Data(count: 8)) + box("dinf", dref) + stbl(chunkOffset: chunkOffset))
            let mdia = box("mdia", box("mdhd", mdhd) + box("hdlr", hdlr) + minf)
            let trak = box("trak", box("tkhd", tkhd) + box("edts", box("elst", elst)) + mdia)
            return box("moov", box("mvhd", mvhd) + trak)
        }

        var ftyp = Data("isom".utf8)
        ftyp.u32(0x200)
        ftyp += Data("isomiso2mp41".utf8)
        let ftypBox = box("ftyp", ftyp)
        let payload = packets.reduce(0) { $0 + $1.count }
        guard payload + 8 < Int(UInt32.max) else { return nil }
        // The packets' offset depends on the header's size, which doesn't depend on the offset.
        let start = ftypBox.count + moov(chunkOffset: 0).count + 8
        var header = ftypBox + moov(chunkOffset: start)
        header.u32(payload + 8)
        header += Data("mdat".utf8)
        return Layout(header: header, packets: packets)
    }

    private static let matrix: Data = {
        var data = Data()
        for value in [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000] { data.u32(value) }
        return data
    }()

    private static func box(_ type: String, _ body: Data) -> Data {
        var data = Data(capacity: body.count + 8)
        data.u32(body.count + 8)
        data += Data(type.utf8)
        data += body
        return data
    }
}

private extension Data {
    mutating func u16(_ value: Int) {
        append(UInt8(value >> 8 & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func u32(_ value: Int) {
        append(contentsOf: [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }
}
