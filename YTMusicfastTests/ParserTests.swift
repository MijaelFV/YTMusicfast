import Foundation
import Testing

/// Parsers run against real InnerTube responses captured on 2026-10-13. When YouTube changes
/// its layout, refresh a fixture and these tests show exactly what broke.
private final class BundleToken {}

private func fixture(_ name: String) throws -> JSON {
    let url = try #require(Bundle(for: BundleToken.self).url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try JSON(data: Data(contentsOf: url))
}

@Suite("Parsing InnerTube responses")
struct ParserTests {
    @Test func searchTopResultAndFilters() throws {
        let results = Parser.search(try fixture("search"))
        guard case .media(let top) = results.top else {
            Issue.record("Expected an artist as the top result")
            return
        }
        #expect(top.title == "Daft Punk")
        #expect(top.target.kind == .artist)
        #expect(results.items.count > 10)
        let filters = Set(results.filters.map(\.title))
        #expect(filters.isSuperset(of: ["All", "Songs", "Albums", "Artists"]))
        #expect(results.filters.dropFirst().allSatisfy { $0.params != nil })
    }

    @Test func songSearchParsesArtistsAlbumsAndDurations() throws {
        let tracks = Parser.search(try fixture("songs")).items.compactMap(\.track)
        #expect(tracks.count >= 10)
        let first = try #require(tracks.first)
        #expect(first.artists.first?.name == "Daft Punk")
        #expect(first.artists.first?.browseId != nil)
        #expect(first.album?.browseId?.hasPrefix("MPRE") == true)
        #expect((first.duration ?? 0) > 60)
        #expect(tracks.allSatisfy { !$0.isVideo })
    }

    @Test func albumPage() throws {
        var page = Parser.page(try fixture("album"))
        page.fillTrackContext(target: BrowseTarget(browseId: "MPREb_K8qWMWVqXGi", kind: .album, title: ""))
        let header = try #require(page.header)
        #expect(header.title == "Random Access Memories")
        #expect(header.artists.first?.name == "Daft Punk")
        #expect(header.thumbnail != nil)
        #expect(page.mainTracks.count == 13)
        // Album rows lack art/album info; it must be inherited from the header.
        #expect(page.mainTracks.allSatisfy { $0.thumbnail != nil && $0.album?.name == "Random Access Memories" })
        #expect(page.mainTracks.allSatisfy { ($0.duration ?? 0) > 0 })
    }

    @Test func artistPage() throws {
        let page = Parser.page(try fixture("artist"))
        #expect(page.header?.title == "Daft Punk")
        let topSongs = try #require(page.shelves.first { $0.style == .list })
        #expect(topSongs.tracks.count == 5)
        let carousels = page.shelves.filter { $0.style == .carousel }
        #expect(carousels.count >= 3)
        #expect(carousels.contains { shelf in shelf.items.contains { if case .media(let m) = $0 { m.target.kind == .album } else { false } } })
    }

    @Test func playlistPage() throws {
        let page = Parser.page(try fixture("playlist"))
        #expect(page.header?.title.isEmpty == false)
        #expect(page.header?.secondSubtitle?.contains("40 tracks") == true)
        #expect(page.mainTracks.count == 40)
        // All 40 tracks are inline; the page continuation loads "Related playlists".
        #expect(page.shelves.first { $0.style == .list }?.continuation == nil)
        #expect(page.continuation != nil)
    }

    @Test func playlistRowsCarryLikeStatus() throws {
        let tracks = Parser.page(try fixture("playlist")).mainTracks
        #expect(!tracks.isEmpty)
        #expect(tracks.allSatisfy { $0.likeStatus != nil })
    }

    @Test func explicitBadge() throws {
        // The song search fixture has exactly one explicit song.
        let songs = Parser.search(try fixture("songs")).items.compactMap(\.track)
        #expect(songs.filter { $0.isExplicit == true }.count == 1)
    }

    @Test func longPlaylistLoadsMoreTracks() throws {
        // Captured from a public 500-song playlist: later batches arrive as bare rows.
        let page = Parser.page(try fixture("playlist-continuation"))
        let shelf = try #require(page.shelves.first { $0.style == .list })
        #expect(shelf.tracks.count == 5)
        #expect(shelf.continuation != nil)
    }

    @Test func playlistContentsComeFromThePlaylistShelfOnly() throws {
        var page = Parser.page(try fixture("playlist"))
        page.kind = .playlist
        #expect(page.mainShelf?.isPlaylistContents == true)
        #expect(page.mainTracks.count == 40)
        // A playlist page with only a suggestions list has no contents of its own.
        page.shelves = page.shelves.map { var shelf = $0; shelf.isPlaylistContents = false; return shelf }
        #expect(page.mainTracks.isEmpty)
    }

    @Test func homeFeed() throws {
        let page = Parser.page(try fixture("home"))
        #expect(page.shelves.count >= 2)
        #expect(page.shelves.contains { $0.style == .rows && $0.tracks.count >= 10 })
        #expect(page.shelves.contains { $0.style == .carousel })
        #expect(page.shelves.allSatisfy { $0.title != nil })
    }

    @Test func moodsAndGenresTiles() throws {
        let page = Parser.page(try fixture("moods"))
        #expect(page.header?.title.isEmpty == false)
        let grids = page.shelves.filter { $0.style == .categories }
        #expect(grids.count == 2)
        let tiles = grids.flatMap(\.items).compactMap { item -> MediaItem? in
            if case .media(let m) = item { return m }
            return nil
        }
        #expect(tiles.count == 45)
        #expect(tiles.allSatisfy { $0.color != nil && $0.target.params != nil })
    }

    @Test func searchSongsInheritTopArtist() throws {
        let results = Parser.search(try fixture("search"))
        let tracks = results.items.compactMap(\.track)
        #expect(!tracks.isEmpty)
        #expect(tracks.allSatisfy { !$0.artists.isEmpty })
    }

    @Test func radioQueue() throws {
        let radio = Parser.radio(try fixture("next"))
        #expect(radio.tracks.count == 50)
        #expect(radio.continuation != nil)
        #expect(radio.tracks.first?.videoId == "5NV6Rdv1a3I")
        #expect(radio.tracks.allSatisfy { !$0.artists.isEmpty && $0.duration != nil })
    }
}

@Suite("Small helpers")
struct HelperTests {
    @Test(arguments: [("4:09", 249.0), ("1:02:03", 3723.0), ("0:05", 5.0)])
    func durations(text: String, seconds: Double) {
        #expect(Parser.duration(text) == seconds)
    }

    @Test func notDurations() {
        #expect(Parser.duration("2013") == nil)
        #expect(Parser.duration("20M plays") == nil)
    }

    @Test func sapisidFromCookies() {
        #expect(Credentials(cookieHeader: "A=1; SAPISID=abc/def; B=2").sapisid == "abc/def")
        #expect(Credentials(cookieHeader: "__Secure-3PAPISID=xyz").sapisid == "xyz")
        #expect(Credentials(cookieHeader: "HSID=1").sapisid == nil)
    }

    @Test func lrcParsing() {
        let lines = LyricsService.parseLRC("""
        [00:30.64] Like the legend of the phoenix
        [00:35.11]Our ends were beginnings
        [01:02.00][01:30.50] Repeated line
        not a lyric line
        """)
        #expect(lines.map(\.time) == [30.64, 35.11, 62, 90.5])
        #expect(lines.first?.text == "Like the legend of the phoenix")
        #expect(lines.map(\.id) == [0, 1, 2, 3])

        let lyrics = Lyrics(lines: lines, source: "test")
        #expect(lyrics.lineIndex(at: 10) == nil)
        #expect(lyrics.lineIndex(at: 33) == 0)
        #expect(lyrics.lineIndex(at: 70) == 2)
        #expect(lyrics.lineIndex(at: 500) == 3)
    }

    @Test(arguments: [
        ("Get Lucky (Official Audio) (feat. Pharrell Williams & Nile Rodgers)", "Get Lucky"),
        ("Persiana Americana (Remasterizado 2007)", "Persiana Americana"),
        ("¿Quién te dijo? (En Vivo)", "¿Quién te dijo?"),
        ("Song Title - Remastered 2011", "Song Title"),
    ])
    func titleCleaning(raw: String, clean: String) {
        #expect(LyricsService.clean(raw) == clean)
    }
}

/// Hits the network. Run with `YTF_LIVE=1` (e.g. before a release) to check playback still resolves.
@Suite("Live stream resolution", .enabled(if: ProcessInfo.processInfo.environment["YTF_LIVE"] == "1"))
struct LiveResolverTests {
    @Test func visionOSResolves() async throws {
        let info = try await VisionOSStreamResolver().resolve(videoId: "dQw4w9WgXcQ")
        #expect(info.contentLength > 1_000_000)
        #expect(info.mimeType.hasPrefix("audio/mp4"))
        #expect(abs((info.duration ?? 0) - 213) < 2)
        try await expectRangeFetch(info)
    }

    @Test(.enabled(if: YtDlpStreamResolver.locate() != nil))
    func ytDlpResolves() async throws {
        let info = try await #require(YtDlpStreamResolver.locate()).resolve(videoId: "dQw4w9WgXcQ")
        #expect(info.contentLength > 1_000_000)
        try await expectRangeFetch(info)
    }

    private func expectRangeFetch(_ info: StreamInfo) async throws {
        var components = try #require(URLComponents(url: info.url, resolvingAgainstBaseURL: false))
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "range", value: "0-65535")]
        let (data, response) = try await URLSession.shared.data(from: try #require(components.url))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(data.count == 65536)
    }
}

@Suite("Parsing account and discovery details")
struct AccountParsingTests {
    @Test func albumHeaderCarriesLibraryStateAndPlaylist() throws {
        let page = Parser.page(try fixture("album"))
        let header = try #require(page.header)
        #expect(header.playlistId?.hasPrefix("OLAK5uy_") == true)
        #expect(header.inLibrary == false)
    }

    @Test func artistHeaderCarriesSubscriptionAndMixes() throws {
        let header = try #require(Parser.page(try fixture("artist")).header)
        #expect(header.channelId?.hasPrefix("UC") == true)
        #expect(header.subscribed == false)
        #expect(header.radioPlaylistId?.hasPrefix("RD") == true)
        #expect(header.shufflePlaylistId?.hasPrefix("RD") == true)
    }

    @Test func playlistSongsKnowTheirSlot() throws {
        var page = Parser.page(try fixture("playlist"))
        page.kind = .playlist
        let tracks = page.mainTracks
        #expect(!tracks.isEmpty)
        #expect(tracks.allSatisfy { $0.setVideoId != nil })
    }

    @Test func homeHasMoodChips() throws {
        let chips = Parser.page(try fixture("home")).chips
        #expect(chips.count >= 4)
        #expect(chips.allSatisfy { $0.params != nil && !$0.title.isEmpty })
    }

    @Test func relatedTabParsesShelves() throws {
        let page = Parser.page(try fixture("related"))
        #expect(page.shelves.count >= 3)
        #expect(page.shelves.contains { !$0.tracks.isEmpty })
        #expect(page.shelves.contains { $0.items.contains { if case .media = $0 { true } else { false } } })
    }
}

@Suite("Parsing credits, disclosures and podcasts")
struct DiscoveryParsingTests {
    @Test func songCredits() throws {
        let credits = Parser.credits(try fixture("credits"))
        #expect(credits.first?.role == "Performed by")
        let producers = try #require(credits.first { $0.role == "Produced by" })
        #expect(producers.names.count == 2)
        #expect(producers.names.contains("Thomas Bangalter"))
    }

    @Test func autoDubbedIsNotAI() throws {
        // "How this was made" also covers auto-dubbed audio; only synthetic-content labels count.
        #expect(!Parser.isSyntheticDisclosure(try fixture("autodubbed-next")))
    }

    @Test func syntheticDisclosureIsAI() throws {
        let labeled = JSON(["howThisWasMadeSectionViewModel": [
            "sectionTitle": ["content": "How this was made"],
            "bodyHeader": ["content": "Altered or synthetic content"],
            "bodyText": ["content": "Sound or visuals were significantly edited or digitally generated."],
        ]])
        #expect(Parser.isSyntheticDisclosure(labeled))
    }

    @Test func podcastPageTypes() {
        #expect(PageKind(pageType: "MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE") == .podcast)
        #expect(PageKind(pageType: "MUSIC_PAGE_TYPE_NON_MUSIC_AUDIO_TRACK_PAGE") == .episode)
    }

    @Test func episodePageHasHeaderAndNotes() throws {
        let page = Parser.page(try fixture("episode"))
        let header = try #require(page.header)
        #expect(!header.title.isEmpty)
        #expect(header.description?.isEmpty == false)
    }
}

@Suite("Parsing comments, chapters and charts")
struct CommunityParsingTests {
    @Test func commentsPage() throws {
        let page = Parser.comments(try fixture("comments"))
        #expect(page.comments.count >= 10)
        let first = try #require(page.comments.first)
        #expect(!first.text.isEmpty)
        #expect(!first.author.isEmpty)
        #expect(page.next != nil)
        #expect(page.total?.contains("Comments") == true)
        #expect(page.sorts.map(\.title) == ["Top", "Newest"])
        #expect(page.comments.contains { $0.replyCount > 0 && $0.repliesToken != nil })
    }

    @Test func chaptersAndCommentsToken() throws {
        let extras = Parser.watchExtras(try fixture("chapters-next"))
        #expect(extras.chapters.count >= 2)
        #expect(extras.chapters.first?.start == 0)
        #expect(extras.chapters.map(\.start) == extras.chapters.map(\.start).sorted())
    }

    @Test func chartCountries() throws {
        let menu = Parser.chartCountries(try fixture("charts"))
        #expect(menu.countries.count > 30)
        #expect(menu.countries.contains { $0.code == "US" })
        #expect(menu.selected != nil)
    }
}

@Suite("Parsing radio tuning and suggestions")
struct RadioAndSuggestionTests {
    @Test func radioHasTuningChips() throws {
        let radio = Parser.radio(try fixture("radio-tuners"))
        #expect(radio.tracks.count > 10)
        #expect(radio.continuation != nil)
        let titles = radio.tuners.map(\.title)
        #expect(titles.starts(with: ["All", "Popular", "Discover", "Deep cuts"]))
        #expect(!titles.contains("Save"))
        #expect(radio.selectedTuner == "All")
        #expect(radio.tuners.allSatisfy { $0.playlistId.hasPrefix("RD") && $0.params != nil })
    }

    @Test func suggestionsIncludeArtistAndSongs() throws {
        let suggestions = Parser.suggestions(try fixture("suggestions"))
        #expect(suggestions.queries.first == "daft punk")
        guard case .media(let artist) = suggestions.items.first else {
            Issue.record("Expected the artist first")
            return
        }
        #expect(artist.title == "Daft Punk")
        #expect(artist.target.kind == .artist)
        let songs = suggestions.items.compactMap(\.track)
        #expect(songs.count >= 3)
        #expect(songs.first?.title.hasPrefix("Get Lucky") == true)
        #expect(songs.first?.artists.first?.name == "Daft Punk")
        #expect(songs.allSatisfy { $0.thumbnail != nil })
    }

    @Test func cardsKeepTheirArtistLinks() throws {
        // Albums and singles on an artist's page, and home's cards: the subtitle's artists are
        // links of their own.
        let media = (Parser.page(try fixture("artist")).shelves + Parser.page(try fixture("home")).shelves)
            .flatMap(\.items).compactMap { item -> MediaItem? in
                if case .media(let m) = item { return m }
                return nil
            }
        let linked = media.filter { !($0.artists ?? []).isEmpty }
        #expect(!linked.isEmpty)
        for item in linked {
            for artist in item.artists ?? [] {
                #expect(artist.browseId != nil)
                #expect(item.subtitle.contains(artist.name))
            }
        }
    }
}
