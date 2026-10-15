import Foundation
import Testing

private final class BundleToken {}

/// The first 4 KB of a real YouTube audio file (header and index only, no music).
private func header() throws -> Data {
    let url = try #require(Bundle(for: BundleToken.self).url(forResource: "fmp4-head", withExtension: "bin", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite("YouTube's MP4 header (twice-the-length fix)")
struct FragmentedMP4Tests {
    @Test func zeroesTheStatedDurations() throws {
        var data = try header()
        let before = data
        #expect(FragmentedMP4.fixHeaderDurations(&data))
        #expect(data.count == before.count)
        // Only the three duration fields change (mvhd, tkhd, mdhd: 4 bytes each).
        let changed = zip(before, data).filter { $0 != $1 }.count
        #expect(changed > 0 && changed <= 12)
        // Running it again changes nothing.
        #expect(!FragmentedMP4.fixHeaderDurations(&data))
    }

    @Test func leavesOtherFilesAlone() {
        var text = Data("not an mp4 at all, just some bytes".utf8)
        #expect(!FragmentedMP4.fixHeaderDurations(&text))
        // A plain (unfragmented) MP4 header: ftyp + moov without mvex.
        var plain = Data([0, 0, 0, 16]) + Data("ftypM4A ".utf8) + Data([0, 0, 0, 0])
        plain += Data([0, 0, 0, 8]) + Data("moov".utf8)
        let copy = plain
        #expect(!FragmentedMP4.fixHeaderDurations(&plain))
        #expect(plain == copy)
    }

    @Test func survivesTruncatedHeaders() throws {
        var cut = try header().prefix(200)
        _ = FragmentedMP4.fixHeaderDurations(&cut)
        var empty = Data()
        #expect(!FragmentedMP4.fixHeaderDurations(&empty))
    }
}

@Suite("Streaming long recordings (HLS from the MP4 index)")
struct FragmentedMP4IndexTests {
    @Test func readsTheSegmentIndex() throws {
        let index = try #require(FragmentedMP4.index(in: try header()))
        #expect(index.header.lowerBound == 0)
        #expect(index.segments.count == 15)
        // The fixture's song is 143 s; the fragments add up to it.
        #expect(abs(index.duration - 143.0) < 0.1)
        // Fragments follow each other with no gaps.
        for (a, b) in zip(index.segments, index.segments.dropFirst()) { #expect(a.offset + a.size == b.offset) }
        // The first fragment starts right where the index said (the 'moof' after it).
        #expect(index.segments[0].offset == 971)
    }

    @Test func buildsAPlaylist() throws {
        let index = try #require(FragmentedMP4.index(in: try header()))
        let playlist = FragmentedMP4.playlist(for: index, mediaName: "media.mp4")
        #expect(playlist.hasPrefix("#EXTM3U\n"))
        #expect(playlist.contains("#EXT-X-MAP:URI=\"media.mp4\",BYTERANGE=\"759@0\""))
        #expect(playlist.components(separatedBy: "#EXTINF:").count - 1 == 15)
        #expect(playlist.hasSuffix("#EXT-X-ENDLIST\n"))
    }

    @Test func playlistWithFragmentAddresses() throws {
        let index = try #require(FragmentedMP4.index(in: try header()))
        let playlist = FragmentedMP4.playlist(for: index, mediaName: "media.mp4") { "https://cdn/v?range=\($0.offset)-\($0.offset + $0.size - 1)" }
        // The header still comes from the media file; each fragment from its own address.
        #expect(playlist.contains("#EXT-X-MAP:URI=\"media.mp4\",BYTERANGE=\"759@0\""))
        #expect(!playlist.contains("#EXT-X-BYTERANGE"))
        #expect(playlist.contains("\nhttps://cdn/v?range=971-"))
        #expect(playlist.components(separatedBy: "\nhttps://cdn/").count - 1 == 15)
    }

    @Test func noIndexNoPlaylist() {
        #expect(FragmentedMP4.index(in: Data("nothing here".utf8)) == nil)
    }
}
