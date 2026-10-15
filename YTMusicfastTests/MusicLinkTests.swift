import Foundation
import Testing

@Suite("Opening YouTube Music links")
struct MusicLinkTests {
    @Test func songLinks() {
        #expect(MusicLink("https://music.youtube.com/watch?v=dQw4w9WgXcQ") == .song(videoId: "dQw4w9WgXcQ"))
        #expect(MusicLink("https://music.youtube.com/watch?v=dQw4w9WgXcQ&list=RDAMVM") == .song(videoId: "dQw4w9WgXcQ"))
        #expect(MusicLink("https://www.youtube.com/watch?v=abc123") == .song(videoId: "abc123"))
        #expect(MusicLink("https://youtu.be/abc123?si=xyz") == .song(videoId: "abc123"))
        #expect(MusicLink("  ytmusicfast://watch?v=abc123\n") == .song(videoId: "abc123"))
    }

    @Test func pageLinks() {
        #expect(MusicLink("https://music.youtube.com/playlist?list=PLabc") == .page(BrowseTarget(browseId: "VLPLabc", kind: .playlist, title: "")))
        #expect(MusicLink("https://music.youtube.com/browse/MPREb_xyz") == .page(BrowseTarget(browseId: "MPREb_xyz", kind: .album, title: "")))
        #expect(MusicLink("https://music.youtube.com/channel/UCabc") == .page(BrowseTarget(browseId: "UCabc", kind: .artist, title: "")))
        #expect(MusicLink("ytmusicfast://playlist?list=PLabc") == .page(BrowseTarget(browseId: "VLPLabc", kind: .playlist, title: "")))
        #expect(MusicLink("ytmusicfast://search?q=daft%20punk") == .search("daft punk"))
    }

    @Test func rejectsOtherText() {
        #expect(MusicLink("hello world") == nil)
        #expect(MusicLink("https://example.com/watch?v=abc") == nil)
        #expect(MusicLink("https://music.youtube.com/watch?v=a\nhttps://music.youtube.com/watch?v=b") == nil)
        #expect(MusicLink("file:///etc/passwd") == nil)
    }
}

@Suite("Disk cache")
struct DiskCacheTests {
    @Test func pagesRoundTrip() async throws {
        var page = BrowsePage()
        page.header = PageHeader(title: "Mix", playlistId: "PL1")
        page.shelves = [Shelf(title: "Songs", style: .list, items: [.track(Track(videoId: "v1", title: "One")),
                                                                    .media(MediaItem(target: BrowseTarget(browseId: "MPREb_1", kind: .album, title: "A"), subtitle: "Album"))],
                              isPlaylistContents: true)]
        page.kind = .playlist
        let key = "test|\(UUID().uuidString)"
        DiskCache.store(page, key: key)
        // Writes are coalesced for two seconds.
        try await Task.sleep(for: .seconds(2.5))
        let loaded = try #require(await DiskCache.load(BrowsePage.self, key: key))
        #expect(loaded.value.header?.title == "Mix")
        #expect(loaded.value.mainTracks.map(\.videoId) == ["v1"])
        #expect(loaded.value.shelves.first?.id == page.shelves.first?.id)
        DiskCache.remove(key: key)
    }
}
