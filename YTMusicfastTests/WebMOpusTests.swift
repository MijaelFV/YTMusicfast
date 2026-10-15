import AVFoundation
import Foundation
import Testing

private final class BundleToken {}

/// Three seconds of a 440 Hz tone, Opus in WebM (made with ffmpeg; laid out like YouTube's).
private func tone() throws -> Data {
    let url = try #require(Bundle(for: BundleToken.self).url(forResource: "opus-3s", withExtension: "webm", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite("Opus from WebM to MP4")
struct WebMOpusTests {
    @Test func laysOutAnMP4() throws {
        let webm = try tone()
        let layout = try #require(WebMOpus.layout(webm))
        #expect(layout.packets.count == 151)
        #expect(layout.header.prefix(8).suffix(4) == Data("ftyp".utf8))
        #expect(layout.header.range(of: Data("dOps".utf8)) != nil)
        // The header ends with the audio's box: exactly the packets follow.
        #expect(layout.header.suffix(4) == Data("mdat".utf8))
        #expect(layout.length == layout.header.count + layout.packets.reduce(0) { $0 + $1.count })
    }

    @Test func playsForExactlyItsLength() async throws {
        let webm = try tone()
        let layout = try #require(WebMOpus.layout(webm))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: file) }
        try WebMOpus.write(layout, from: webm, to: file)
        #expect(WebMOpus.isOpus(file))
        let asset = AVURLAsset(url: file)
        #expect(try await asset.load(.isPlayable))
        // Encoder warm-up and end padding trimmed: 3 seconds, not 3.02.
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 3) < 0.001)
        // Written and in memory are the same bytes.
        #expect(try Data(contentsOf: file) == WebMOpus.data(layout, from: webm))
    }

    @Test func packetLengths() {
        #expect(WebMOpus.samples(in: Data([0xFC])[...]) == 960)  // CELT 20 ms, one frame
        #expect(WebMOpus.samples(in: Data([0xFD])[...]) == 1920)  // two frames
        #expect(WebMOpus.samples(in: Data([0xFF, 0x03])[...]) == 2880)  // three frames
        #expect(WebMOpus.samples(in: Data([0x08])[...]) == 960)  // SILK 20 ms
        #expect(WebMOpus.samples(in: Data([0xFF, 0x00])[...]) == nil)  // no frames
        #expect(WebMOpus.samples(in: Data([0xFF, 0x3F])[...]) == nil)  // over 120 ms
        #expect(WebMOpus.samples(in: Data()[...]) == nil)
    }

    @Test func rejectsWhatItDoesntKnow() throws {
        #expect(WebMOpus.layout(Data("not a webm file".utf8)) == nil)
        #expect(WebMOpus.layout(Data()) == nil)
        // Cut short mid-file: either a shorter valid MP4 or nothing — never a crash.
        let webm = try tone()
        for cut in stride(from: 0, to: webm.count, by: 997) {
            if let layout = WebMOpus.layout(webm.prefix(cut)) {
                #expect(layout.packets.allSatisfy { $0.upperBound <= cut })
            }
        }
    }
}

@Suite("Network speed")
struct NetworkSpeedTests {
    @Test func decidesBetweenWholeAndStreamed() {
        let speed = NetworkSpeed()
        // Unmeasured: assume a normal connection.
        #expect(!speed.isSlow(for: 5 << 20))
        // 1 MB in half a second per connection: a 5 MB song whole in under a second.
        speed.record(bytes: 1 << 20, seconds: 0.5)
        #expect(!speed.isSlow(for: 5 << 20))
        // About 1 Mbit/s: whole would take half a minute — stream it.
        speed.networkChanged(lowDataMode: true)
        speed.record(bytes: 1 << 20, seconds: 25)
        #expect(speed.isSlow(for: 5 << 20))
        #expect(speed.isLowDataMode)
        // Tiny pieces say nothing about speed.
        speed.networkChanged(lowDataMode: false)
        speed.record(bytes: 1000, seconds: 10)
        #expect(!speed.isSlow(for: 5 << 20))
    }
}
