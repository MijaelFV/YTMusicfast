import Foundation
import Testing

@Suite("Listening stats")
struct ListeningSummaryTests {
    private let daft = ArtistRef(name: "Daft Punk", browseId: "UCdaft")
    private let pharrell = ArtistRef(name: "Pharrell Williams", browseId: "UCpharrell")

    private func listen(_ id: String, _ artists: [ArtistRef], daysAgo: Double, seconds: TimeInterval = 180) -> Listen {
        Listen(track: Track(videoId: id, title: id, artists: artists, thumbnail: URL(string: "https://example.com/\(id).jpg")),
               date: Date().addingTimeInterval(-daysAgo * 86_400), seconds: seconds)
    }

    @Test func ranksSongsAndArtistsByPlays() {
        let plays = [
            listen("lucky", [daft, pharrell], daysAgo: 1),
            listen("lucky", [daft, pharrell], daysAgo: 2),
            listen("lucky", [daft, pharrell], daysAgo: 2),
            listen("one-more-time", [daft], daysAgo: 3),
            listen("happy", [pharrell], daysAgo: 4, seconds: 60),
        ]
        let summary = ListeningSummary(plays, since: .distantPast)
        #expect(summary.playCount == 5)
        #expect(summary.topTracks.map(\.track.videoId) == ["lucky", "one-more-time", "happy"])
        #expect(summary.topTracks.first?.count == 3)
        #expect(summary.topArtists.map(\.artist.name) == ["Daft Punk", "Pharrell Williams"])
        #expect(summary.topArtists.first?.count == 4)
        // An artist's picture falls back to the cover of their most-played song.
        #expect(summary.topArtists.last?.artwork?.lastPathComponent == "lucky.jpg")
        #expect(summary.seconds == 4 * 180 + 60)
        #expect(abs(summary.minutesByHour.reduce(0, +) - 13) < 0.001)
        #expect(summary.activeDays == 4)
    }

    @Test func onlyCountsThePeriod() {
        let plays = [listen("old", [daft], daysAgo: 60), listen("new", [daft], daysAgo: 1)]
        let summary = ListeningSummary(plays, since: Date().addingTimeInterval(-28 * 86_400))
        #expect(summary.topTracks.map(\.track.videoId) == ["new"])
        #expect(summary.artistCount == 1)
        #expect(ListeningSummary([], since: .distantPast).playCount == 0)
    }

    @Test func groupsArtistsWithoutIdsByName() {
        let local = ArtistRef(name: "Burial", browseId: nil)
        let summary = ListeningSummary([listen("a", [local], daysAgo: 1), listen("b", [ArtistRef(name: "burial")], daysAgo: 1)],
                                       since: .distantPast)
        #expect(summary.topArtists.count == 1)
        #expect(summary.topArtists.first?.count == 2)
    }
}
