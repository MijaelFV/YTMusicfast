import Foundation

/// YouTube's audio comes as fragmented MP4: a header, then the music in many small fragments. Its
/// header also states the song's full length (fragmented files normally say 0 there), and
/// AVFoundation adds that to the fragments' own length — so it believes every song is twice as
/// long as it is.
///
/// That was more than a wrong number. While streaming, AVFoundation maps bytes to time with it:
/// once it had about half the file it thought it had the whole song, stopped asking for more,
/// and then played on in silence from around the middle (seeking back had sound again).
/// Zeroing those header durations — a few bytes, sizes and offsets unchanged — makes it read
/// the true length.
enum FragmentedMP4 {
    /// Fixes the header in `data` (the first bytes of a file) in place. Only fragmented MP4s with
    /// a stated length are touched; anything else (your own music files) is left as it is.
    /// Returns whether anything changed.
    @discardableResult
    static func fixHeaderDurations(_ data: inout Data) -> Bool {
        guard let moov = box("moov", in: data, from: data.startIndex, to: data.endIndex),
              box("mvex", in: data, from: moov.body, to: moov.end) != nil else { return false }
        var changed = false
        func zero(_ type: String, in range: (body: Int, end: Int)) {
            guard let found = box(type, in: data, from: range.body, to: range.end) else { return }
            let version = data[found.body]
            // Where the duration is: after version+flags and the fields before it.
            let offset: Int
            switch (type, version) {
            case ("tkhd", 0): offset = 20
            case ("tkhd", 1): offset = 28
            case (_, 0): offset = 16  // mvhd, mdhd
            default: offset = 24
            }
            let width = version == 0 ? 4 : 8
            let start = found.body + offset
            guard start + width <= found.end else { return }
            if data[start..<(start + width)].contains(where: { $0 != 0 }) {
                data.replaceSubrange(start..<(start + width), with: Data(count: width))
                changed = true
            }
        }
        zero("mvhd", in: (moov.body, moov.end))
        var search = moov.body
        while let trak = box("trak", in: data, from: search, to: moov.end) {
            zero("tkhd", in: (trak.body, trak.end))
            if let mdia = box("mdia", in: data, from: trak.body, to: trak.end) { zero("mdhd", in: (mdia.body, mdia.end)) }
            search = trak.end
        }
        return changed
    }

    /// Fixes a file on disk (a replay or a download saved before this fix), reading and writing
    /// only its first bytes. Cheap enough to call before every play.
    static func fixFile(_ url: URL) {
        guard let handle = try? FileHandle(forUpdating: url) else { return }
        defer { try? handle.close() }
        guard var head = try? handle.read(upToCount: 64 * 1024), fixHeaderDurations(&head) else { return }
        try? handle.seek(toOffset: 0)
        try? handle.write(contentsOf: head)
    }

    /// The first box of `type` between `from` and `to`: where its contents start and where it ends.
    private static func box(_ type: String, in data: Data, from: Int, to: Int) -> (body: Int, end: Int)? {
        var index = from
        while index + 8 <= to {
            var size = Int(data[index]) << 24 | Int(data[index + 1]) << 16 | Int(data[index + 2]) << 8 | Int(data[index + 3])
            var header = 8
            if size == 1, index + 16 <= to {
                size = data[(index + 8)..<(index + 16)].reduce(0) { $0 << 8 | Int($1) }
                header = 16
            } else if size == 0 {
                size = to - index
            }
            guard size >= header, index + size <= to else { return nil }
            let name = String(decoding: data[(index + 4)..<(index + 8)], as: UTF8.self)
            if name == type { return (index + header, index + size) }
            index += size
        }
        return nil
    }
}

extension FragmentedMP4 {
    /// Where a fragmented MP4's parts are, from its segment index (`sidx`), which YouTube puts at
    /// the start of the file: the header (`ftyp` + `moov`) and every fragment's bytes and length.
    struct Index: Equatable {
        struct Segment: Equatable {
            var offset: Int
            var size: Int
            var duration: Double
        }
        /// Bytes of the header the player needs first.
        var header: Range<Int>
        var segments: [Segment]
        var duration: Double { segments.reduce(0) { $0 + $1.duration } }
    }

    /// Reads the index from the first bytes of a file (the first megabyte is plenty).
    static func index(in data: Data) -> Index? {
        guard let moov = box("moov", in: data, from: data.startIndex, to: data.endIndex),
              let sidx = box("sidx", in: data, from: moov.end, to: data.endIndex) else { return nil }
        func u32(_ at: Int) -> Int? {
            guard at + 4 <= data.endIndex else { return nil }
            return data[at..<(at + 4)].reduce(0) { $0 << 8 | Int($1) }
        }
        func u64(_ at: Int) -> Int? {
            guard at + 8 <= data.endIndex else { return nil }
            return data[at..<(at + 8)].reduce(0) { $0 << 8 | Int($1) }
        }
        var at = sidx.body
        let version = data[at]
        at += 4 + 4  // version+flags, reference_ID
        guard let timescale = u32(at), timescale > 0 else { return nil }
        at += 4
        let firstOffset: Int
        if version == 0 {
            guard let offset = u32(at + 4) else { return nil }
            firstOffset = offset
            at += 8
        } else {
            guard let offset = u64(at + 8) else { return nil }
            firstOffset = offset
            at += 16
        }
        guard let countField = u32(at) else { return nil }
        let count = countField & 0xFFFF
        at += 4
        var offset = sidx.end + firstOffset
        var segments: [Index.Segment] = []
        segments.reserveCapacity(count)
        for _ in 0..<count {
            guard let typeAndSize = u32(at), let duration = u32(at + 4) else { return nil }
            // A reference to another index (type 1) isn't used by YouTube; bail out if seen.
            guard typeAndSize >> 31 == 0 else { return nil }
            let size = typeAndSize & 0x7FFF_FFFF
            segments.append(Index.Segment(offset: offset, size: size, duration: Double(duration) / Double(timescale)))
            offset += size
            at += 12
        }
        guard !segments.isEmpty else { return nil }
        // The header: everything before the index (ftyp + moov).
        return Index(header: data.startIndex..<(moov.end), segments: segments)
    }

    /// An HLS playlist for the file at `mediaName`, made from its index: Apple's own streaming
    /// format, which AVFoundation loads a piece at a time. With `segmentURL`, each fragment is
    /// fetched from its own address instead of a byte range of `mediaName` (the header still is).
    static func playlist(for index: Index, mediaName: String, segmentURL: ((Index.Segment) -> String)? = nil) -> String {
        let target = Int((index.segments.map(\.duration).max() ?? 10).rounded(.up))
        var lines = [
            "#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(target)", "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MAP:URI=\"\(mediaName)\",BYTERANGE=\"\(index.header.count)@\(index.header.lowerBound)\"",
        ]
        lines.reserveCapacity(lines.count + index.segments.count * 3 + 1)
        for segment in index.segments {
            lines.append(String(format: "#EXTINF:%.5f,", segment.duration))
            if let segmentURL {
                lines.append(segmentURL(segment))
            } else {
                lines.append("#EXT-X-BYTERANGE:\(segment.size)@\(segment.offset)")
                lines.append(mediaName)
            }
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }
}
