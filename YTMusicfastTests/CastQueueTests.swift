import Foundation
import Testing

@Suite("Casting: lyrics on the TV and the device's queue")
struct CastQueueTests {
    private func lyrics(_ lines: [(TimeInterval, String)]) -> Lyrics {
        Lyrics(lines: lines.enumerated().map { LyricLine(id: $0, time: $1.0, text: $1.1) }, source: "test")
    }

    @Test func webVTTHasACuePerLine() throws {
        let vtt = try #require(CastLyrics.webVTT(lyrics([(1.5, "First"), (4, "Second & <third>")]), duration: 6))
        #expect(vtt == """
        WEBVTT

        1
        00:00:01.500 --> 00:00:04.000
        First

        2
        00:00:04.000 --> 00:00:06.000
        Second &amp; &lt;third&gt;

        """)
    }

    @Test func webVTTSkipsBlankLinesAndCapsLongOnes() throws {
        let vtt = try #require(CastLyrics.webVTT(lyrics([(0, "Hello"), (3, ""), (40, "Back"), (3700, "Late")]), duration: nil))
        // The blank line ends "Hello"; "Back" stays up 10 s at most, through the break.
        #expect(vtt.contains("00:00:00.000 --> 00:00:03.000\nHello"))
        #expect(vtt.contains("00:00:40.000 --> 00:00:50.000\nBack"))
        #expect(vtt.contains("01:01:40.000 --> 01:01:50.000\nLate"))
        #expect(!vtt.contains("\n\n\n"))
        #expect(vtt.components(separatedBy: " --> ").count == 4)
    }

    @Test func noTrackWithoutSyncedLyrics() {
        #expect(CastLyrics.webVTT(nil, duration: 200) == nil)
        #expect(CastLyrics.webVTT(Lyrics(plain: "Words", source: "test"), duration: 200) == nil)
        #expect(CastLyrics.webVTT(lyrics([(2, "  ")]), duration: 200) == nil)
    }

    @Test func timestamps() {
        #expect(CastLyrics.timestamp(0) == "00:00:00.000")
        #expect(CastLyrics.timestamp(61.2345) == "00:01:01.235")
        #expect(CastLyrics.timestamp(3600 * 2 + 5) == "02:00:05.000")
    }

    // MARK: Queue

    private let a = "http://10.0.0.2:5000/cast/s/aaa", b = "http://10.0.0.2:5000/cast/s/bbb", c = "http://10.0.0.2:5000/cast/s/v/ccc/index.m3u8"

    @Test func addsTheNextSong() {
        let plan = CastQueueSync.plan(items: [.init(id: 1, contentId: a)], currentItemId: 1, next: b, inserting: false)
        #expect(plan == .init(remove: [], insert: true))
    }

    @Test func leavesAQueueThatMatches() {
        let items: [CastQueueSync.Item] = [.init(id: 1, contentId: a), .init(id: 2, contentId: b)]
        #expect(CastQueueSync.plan(items: items, currentItemId: 1, next: b, inserting: false).isEmpty)
        // Sent and not listed yet: not sent twice.
        #expect(CastQueueSync.plan(items: [.init(id: 1, contentId: a)], currentItemId: 1, next: b, inserting: true).isEmpty)
    }

    @Test func replacesANextSongThatChanged() {
        // Shuffle, a reorder, or Song/Video mode: another song (or version) is next now.
        let items: [CastQueueSync.Item] = [.init(id: 1, contentId: a), .init(id: 2, contentId: b)]
        #expect(CastQueueSync.plan(items: items, currentItemId: 1, next: c, inserting: false) == .init(remove: [2], insert: true))
        // Nothing next any more (end of the queue, Repeat One).
        #expect(CastQueueSync.plan(items: items, currentItemId: 1, next: nil, inserting: false) == .init(remove: [2], insert: false))
    }

    @Test func dropsSongsAlreadyPlayed() {
        // The device moved on to b by itself: a stays on its queue until taken off.
        let items: [CastQueueSync.Item] = [.init(id: 1, contentId: a), .init(id: 2, contentId: b), .init(id: 3, contentId: b)]
        #expect(CastQueueSync.plan(items: items, currentItemId: 2, next: c, inserting: false) == .init(remove: [1, 3], insert: true))
        #expect(CastQueueSync.plan(items: items, currentItemId: 2, next: b, inserting: false) == .init(remove: [1], insert: false))
    }

    @Test func followsTheDeviceMovingOn() {
        let queue = ["a", "b", "c"]
        #expect(CastQueueSync.indexAfterAdvance(queue: queue, current: 0, to: "b", repeatAll: false) == 1)
        // A song removed meanwhile: the one the device has, further on.
        #expect(CastQueueSync.indexAfterAdvance(queue: queue, current: 0, to: "c", repeatAll: false) == 2)
        #expect(CastQueueSync.indexAfterAdvance(queue: queue, current: 2, to: "a", repeatAll: true) == 0)
        #expect(CastQueueSync.indexAfterAdvance(queue: queue, current: 2, to: "a", repeatAll: false) == nil)
        #expect(CastQueueSync.indexAfterAdvance(queue: queue, current: 0, to: "zzz", repeatAll: false) == nil)
        // Not back to a song before the one playing.
        #expect(CastQueueSync.indexAfterAdvance(queue: queue, current: 1, to: "a", repeatAll: false) == nil)
    }

    @Test func videoIdsFromAddresses() {
        #expect(CastQueueSync.videoId(fromContentId: a) == "aaa")
        #expect(CastQueueSync.videoId(fromContentId: c) == "ccc")
        #expect(CastQueueSync.videoId(fromContentId: "http://10.0.0.2:5000/cast/s/v/ccc/720.m3u8") == "ccc")
        #expect(CastQueueSync.videoId(fromContentId: "http://10.0.0.2:5000/other/x") == nil)
        #expect(CastQueueSync.videoId(fromContentId: "") == nil)
    }
}
