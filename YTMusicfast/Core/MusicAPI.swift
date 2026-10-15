import Foundation

/// High-level YouTube Music operations used by the UI.
enum MusicAPI {
    private static var api: InnerTube { .shared }

    /// Home, optionally narrowed by one of its mood chips.
    static func home(params: String? = nil) async throws -> BrowsePage {
        var body: [String: Any] = ["browseId": "FEmusic_home"]
        if let params { body["params"] = params }
        return Parser.page(try await api.post("browse", body: body))
    }

    /// Autocomplete for the search field.
    static func searchSuggestions(_ input: String) async throws -> SearchSuggestions {
        Parser.suggestions(try await api.post("music/get_search_suggestions", body: ["input": input]))
    }

    /// YouTube Music's "Related" tab for a song: similar songs, artists and playlists.
    static func related(videoId: String) async throws -> BrowsePage {
        let next = try await api.post("next", body: ["videoId": videoId, "isAudioOnly": true])
        let tab = next.findAll("tabRenderer").first {
            $0.at("endpoint", "browseEndpoint", "browseId").string?.hasPrefix("MPTR") == true
        }
        guard let browseId = tab?.at("endpoint", "browseEndpoint", "browseId").string else { return BrowsePage() }
        return Parser.page(try await api.post("browse", body: ["browseId": browseId]))
    }

    static func browse(_ target: BrowseTarget) async throws -> BrowsePage {
        var body: [String: Any] = ["browseId": target.browseId]
        if let params = target.params { body["params"] = params }
        var page = Parser.page(try await api.post("browse", body: body))
        // Podcast show pages are empty in regions without YouTube Music podcasts; every show is
        // backed by a playlist of its episodes, which loads everywhere.
        if target.kind == .podcast, target.browseId.hasPrefix("MPSP"), page.mainShelf == nil || page.header == nil {
            var fallback = Parser.page(try await api.post("browse", body: ["browseId": "VL" + target.browseId.dropFirst(4)]))
            fallback.chips = []
            page = fallback
        }
        page.kind = target.kind
        page.fillTrackContext(target: target)
        return page
    }

    /// Charts for a country (nil: YouTube's pick for your region).
    static func charts(country: String?) async throws -> BrowsePage {
        var body: [String: Any] = ["browseId": "FEmusic_charts"]
        if let country { body["formData"] = ["selectedValues": [country]] }
        let json = try await api.post("browse", body: body)
        var page = Parser.page(json)
        let menu = Parser.chartCountries(json)
        page.countries = menu.countries
        page.selectedCountry = menu.selected ?? country
        return page
    }

    /// Chapters and the comments token, from the regular YouTube watch page.
    static func watchExtras(videoId: String) async throws -> WatchExtras {
        Parser.watchExtras(try await api.postWeb("next", body: ["videoId": videoId], signedIn: true))
    }

    /// A page of comments, a different sort, or a comment's replies (all continuation tokens).
    static func comments(token: String) async throws -> CommentPage {
        Parser.comments(try await api.postWeb("next", body: ["continuation": token], signedIn: true))
    }

    /// Posts a comment (signed in; `params` comes with the first page of comments).
    static func postComment(_ text: String, params: String) async throws {
        let json = try await api.postWeb("comment/create_comment", body: ["commentText": text, "createCommentParams": params], signedIn: true)
        guard json["actionResult"]["status"].string != "STATUS_FAILED", json["errorMessage"].exists == false else {
            throw InnerTubeError.unplayable(String(localized: "Couldn't post your comment"))
        }
    }

    /// YouTube Music's "Song credits": performers, writers, producers.
    static func credits(videoId: String) async throws -> [CreditRole] {
        Parser.credits(try await api.post("browse", body: ["browseId": "MPTC\(videoId)"]))
    }

    /// Whether YouTube labels the video "Altered or synthetic content" (AI). Read from the regular
    /// YouTube watch page, the only place the disclosure appears.
    static func hasSyntheticLabel(videoId: String) async throws -> Bool {
        Parser.isSyntheticDisclosure(try await api.postWeb("next", body: ["videoId": videoId]))
    }

    /// The music video for a song ("Switch to video"): the best matching video in a video search.
    static func musicVideo(for track: Track) async -> Track? {
        let query = "\(track.title) \(track.artists.first?.name ?? "")"
        guard let results = try? await search(query, params: "EgWKAQIQAWoMEA4QChADEAQQCRAF") else { return nil }
        let videos = results.items.compactMap(\.track).filter(\.isVideo)
        let normalizedTitle = Self.normalize(track.title)
        let artistNames = Set(track.artists.map { Self.normalize($0.name) })
        return videos.first { video in
            let sameArtist = video.artists.contains { artistNames.contains(Self.normalize($0.name)) } || artistNames.isEmpty
            let title = Self.normalize(video.title)
            return sameArtist && (title.contains(normalizedTitle) || normalizedTitle.contains(title))
        }
    }

    /// The song for a music video (Song mode): a song with the very same title and artist — a
    /// live take or a cover is a different recording, so near matches don't count.
    static func songVersion(for video: Track) async -> Track? {
        let title = plainTitle(video)
        guard !title.isEmpty else { return nil }
        guard let results = try? await search("\(title) \(video.artists.first?.name ?? "")", params: "EgWKAQIIAWoMEA4QChADEAQQCRAF") else { return nil }
        let wanted = normalize(title)
        let artists = Set(video.artists.map { normalize($0.name) })
        return results.items.compactMap(\.track).filter { !$0.isVideo }.first { song in
            normalize(song.title) == wanted && song.artists.contains { artists.contains(normalize($0.name)) }
        }
    }

    /// A video's title without what makes it a video: "(Official Music Video)", "[Lyric Video]",
    /// "(Visualizer)", or the artist's name in front ("Artist - Title").
    private static func plainTitle(_ video: Track) -> String {
        var title = video.title.replacingOccurrences(
            of: #"\s*[\(\[][^\)\]]*\b(official|video|audio|lyrics?|visuali[sz]er|m/?v|hd|4k)\b[^\)\]]*[\)\]]"#,
            with: "", options: [.regularExpression, .caseInsensitive])
        for artist in video.artists where title.lowercased().hasPrefix(artist.name.lowercased() + " - ") {
            title = String(title.dropFirst(artist.name.count + 3))
        }
        return title.trimmingCharacters(in: .whitespaces)
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "(official video)", with: "")
            .replacingOccurrences(of: "(official music video)", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Every song of an album or playlist (following continuations), or an artist's top songs.
    static func collectionTracks(_ target: BrowseTarget, limit: Int = 2000) async throws -> (header: PageHeader?, tracks: [Track]) {
        let page = try await browse(target)
        if target.kind == .artist {
            return (page.header, page.shelves.first { $0.style == .list }?.tracks ?? [])
        }
        var tracks = page.mainTracks
        var token = page.mainShelf?.continuation
        while let current = token, tracks.count < limit {
            var more = try await continuation(current)
            more.fillTrackContext(target: target)
            let rows = more.shelves.filter { $0.style == .list }
            let fresh = rows.flatMap(\.tracks)
            guard !fresh.isEmpty else { break }
            tracks += fresh
            token = rows.last?.continuation
        }
        return (page.header, tracks)
    }

    /// Loads the next batch for a feed or list (`continuation` token from a page or shelf).
    static func continuation(_ token: String) async throws -> BrowsePage {
        Parser.page(try await api.post("browse", body: ["continuation": token]))
    }

    static func search(_ query: String, params: String? = nil) async throws -> SearchResults {
        var body: [String: Any] = ["query": query]
        if let params { body["params"] = params }
        return Parser.search(try await api.post("search", body: body))
    }

    static func searchContinuation(_ token: String) async throws -> SearchResults {
        Parser.search(try await api.post("search", body: ["continuation": token]))
    }

    /// The "radio" / up-next queue for a song, or the contents of a playlist when `playlistId` is given.
    /// `params` picks a variant of a playlist ("wAEB": a mix built from it).
    static func radio(videoId: String? = nil, playlistId: String? = nil, params: String? = nil) async throws -> RadioResult {
        var body: [String: Any] = ["isAudioOnly": true, "enablePersistentPlaylistPanel": true, "tunerSettingValue": "AUTOMIX_SETTING_NORMAL"]
        if let videoId {
            body["videoId"] = videoId
            body["playlistId"] = playlistId ?? "RDAMVM\(videoId)"
            body["params"] = params ?? "wAEB"
        } else if let playlistId {
            body["playlistId"] = playlistId
            if let params { body["params"] = params }
        }
        return Parser.radio(try await api.post("next", body: body))
    }

    static func radioContinuation(_ token: String) async throws -> RadioResult {
        Parser.radio(try await api.post("next", body: ["continuation": token, "isAudioOnly": true, "enablePersistentPlaylistPanel": true]))
    }

    static func accountName() async -> String? {
        guard let json = try? await api.post("account/account_menu", body: [:]) else { return nil }
        return json.first("activeAccountHeaderRenderer")?["accountName"].text
    }
}

extension BrowsePage {
    /// Album tracks come without artwork/artist/album info; inherit it from the page header.
    mutating func fillTrackContext(target: BrowseTarget) {
        guard let header else { return }
        for s in shelves.indices where shelves[s].style == .list {
            shelves[s].items = shelves[s].items.map { item in
                guard case .track(var track) = item else { return item }
                if track.thumbnail == nil { track.thumbnail = header.thumbnail }
                if track.artists.isEmpty || track.artists.allSatisfy({ $0.browseId == nil }), !header.artists.isEmpty,
                   target.kind == .album {
                    track.artists = header.artists
                }
                if track.album == nil, target.kind == .album {
                    track.album = AlbumRef(name: header.title, browseId: target.browseId)
                }
                return .track(track)
            }
        }
    }
}

// MARK: - Account actions (require sign-in)

extension MusicAPI {
    static func setLike(_ status: LikeStatus, videoId: String) async throws {
        let endpoint = switch status {
        case .like: "like/like"
        case .dislike: "like/dislike"
        case .indifferent: "like/removelike"
        }
        _ = try await api.post(endpoint, body: ["target": ["videoId": videoId]])
    }

    static func likeStatus(videoId: String) async -> LikeStatus {
        guard let json = try? await api.post("next", body: ["videoId": videoId, "isAudioOnly": true]),
              let raw = json.first("likeButtonRenderer")?["likeStatus"].string else { return .indifferent }
        return LikeStatus(rawValue: raw) ?? .indifferent
    }

    /// Playlists the signed-in user can add songs to.
    static func editablePlaylists(for videoId: String) async throws -> [PlaylistOption] {
        let json = try await api.post("playlist/get_add_to_playlist", body: ["videoIds": [videoId], "excludeWatchLater": true])
        return json.findAll("playlistAddToOptionRenderer").compactMap { option in
            guard let id = option["playlistId"].string, let title = option["title"].text else { return nil }
            return PlaylistOption(playlistId: id, title: title, thumbnail: Parser.thumbnail(in: option))
        }
    }

    static func add(videoId: String, toPlaylist playlistId: String) async throws {
        try await add(videoIds: [videoId], toPlaylist: playlistId)
    }

    enum AddResult: Equatable {
        case added
        /// Some songs are already in the playlist; nothing was added.
        case duplicates
    }

    /// Adds songs to a playlist. Unless `allowDuplicates`, YouTube refuses when any is already
    /// there, and `.duplicates` comes back so the user can decide ("Already added").
    @discardableResult
    static func add(videoIds: [String], toPlaylist playlistId: String, allowDuplicates: Bool = false) async throws -> AddResult {
        guard !videoIds.isEmpty else { return .added }
        let id = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
        let json = try await api.post("browse/edit_playlist", body: [
            "playlistId": id,
            "actions": videoIds.map { videoId -> [String: Any] in
                var action: [String: Any] = ["action": "ACTION_ADD_VIDEO", "addedVideoId": videoId]
                if allowDuplicates { action["dedupeOption"] = "DEDUPE_OPTION_SKIP" }
                return action
            },
        ])
        if json["status"].string?.contains("SUCCEEDED") == true { return .added }
        if !allowDuplicates {
            let raw = (json.raw.flatMap { try? JSONSerialization.data(withJSONObject: $0) }).map { String(decoding: $0, as: UTF8.self) } ?? ""
            if json.first("confirmDialogRenderer") != nil || raw.localizedCaseInsensitiveContains("duplicate")
                || raw.localizedCaseInsensitiveContains("already") {
                return .duplicates
            }
        }
        throw InnerTubeError.unplayable(String(localized: "Couldn't add to playlist"))
    }

    /// The new slots (`setVideoId`) of songs just added, in order: lets an undo put a song back in place.
    static func addReturningSlots(videoId: String, toPlaylist playlistId: String) async throws -> String? {
        let id = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
        let json = try await api.post("browse/edit_playlist", body: [
            "playlistId": id,
            "actions": [["action": "ACTION_ADD_VIDEO", "addedVideoId": videoId, "dedupeOption": "DEDUPE_OPTION_SKIP"]],
        ])
        guard json["status"].string?.contains("SUCCEEDED") == true else { throw InnerTubeError.unplayable(String(localized: "Couldn't add to playlist")) }
        return json.findAll("playlistEditVideoAddedResultData").first?["setVideoId"].string
    }

    /// Removes plays from your listening history (each history row carries its own token).
    static func removeFromHistory(tokens: [String]) async throws {
        guard !tokens.isEmpty else { return }
        let json = try await api.post("feedback", body: ["feedbackTokens": tokens])
        let ok = json.findAll("feedbackResponses").flatMap(\.array).allSatisfy { $0["isProcessed"].bool != false }
        if !ok { throw InnerTubeError.unplayable(String(localized: "Couldn't remove from history")) }
    }

    /// Uploads a song file to your YouTube Music library ("Uploads"). Formats: MP3, M4A, FLAC, OGG, WMA.
    static func upload(_ file: URL) async throws {
        try await api.uploadMusic(file)
    }

    /// Saves an album or someone else's playlist to (or removes it from) the account's library.
    static func setInLibrary(_ saved: Bool, playlistId: String) async throws {
        let id = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
        _ = try await api.post(saved ? "like/like" : "like/removelike", body: ["target": ["playlistId": id]])
    }

    /// Subscribes to (follows) or unsubscribes from an artist.
    static func setSubscribed(_ subscribed: Bool, channelId: String) async throws {
        _ = try await api.post(subscribed ? "subscription/subscribe" : "subscription/unsubscribe", body: ["channelIds": [channelId]])
    }

    /// A song's playback-stats addresses, from an authenticated player request as the website gets
    /// them: `playback` (pinged once, it adds the song to History) and `watchtime` (how long it was
    /// listened to). See `WatchTime`.
    static func statsURLs(videoId: String) async -> (playback: URL?, watchtime: URL?) {
        let player = try? await api.post("player", body: ["videoId": videoId])
        func url(_ key: String) -> URL? { player?.at("playbackTracking", key, "baseUrl").string.flatMap(URL.init(string:)) }
        return (url("videostatsPlaybackUrl"), url("videostatsWatchtimeUrl"))
    }

    /// Sends one stats ping: the base address with `parameters` (and the web client's) in place of
    /// any already there. Best effort.
    static func ping(_ base: URL, _ parameters: [(String, String)]) async {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return }
        let all = [("ver", "2"), ("c", "WEB_REMIX")] + parameters
        let names = Set(all.map(\.0))
        components.queryItems = (components.queryItems ?? []).filter { !names.contains($0.name) }
            + all.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = components.url else { return }
        try? await api.get(url)
    }

    @discardableResult
    static func createPlaylist(title: String, videoIds: [String]) async throws -> String? {
        let json = try await api.post("playlist/create", body: [
            "title": title, "description": "", "privacyStatus": "PRIVATE", "videoIds": videoIds,
        ])
        return json["playlistId"].string
    }

    /// YouTube's own (unsynced) lyrics text, used when LRCLIB has nothing.
    static func youtubeLyrics(videoId: String) async -> (text: String, source: String?)? {
        guard let next = try? await api.post("next", body: ["videoId": videoId, "isAudioOnly": true]) else { return nil }
        let lyricsTab = next.findAll("tabRenderer").first {
            $0.at("endpoint", "browseEndpoint", "browseId").string?.hasPrefix("MPLY") == true
        }
        guard let browseId = lyricsTab?.at("endpoint", "browseEndpoint", "browseId").string,
              let page = try? await api.post("browse", body: ["browseId": browseId]),
              let shelf = page.first("musicDescriptionShelfRenderer"),
              let text = shelf["description"].text
        else { return nil }
        return (text, shelf["footer"].text)
    }
}

// MARK: - Editing your own playlists

extension MusicAPI {
    private static func plainPlaylistId(_ id: String) -> String {
        id.hasPrefix("VL") ? String(id.dropFirst(2)) : id
    }

    static func renamePlaylist(_ playlistId: String, title: String, description: String?) async throws {
        var actions: [[String: Any]] = [["action": "ACTION_SET_PLAYLIST_NAME", "playlistName": title]]
        if let description {
            actions.append(["action": "ACTION_SET_PLAYLIST_DESCRIPTION", "playlistDescription": description])
        }
        let json = try await api.post("browse/edit_playlist", body: ["playlistId": plainPlaylistId(playlistId), "actions": actions])
        if json["status"].string == "STATUS_FAILED" { throw InnerTubeError.unplayable(String(localized: "Couldn't update playlist")) }
    }

    static func deletePlaylist(_ playlistId: String) async throws {
        _ = try await api.post("playlist/delete", body: ["playlistId": plainPlaylistId(playlistId)])
    }

    enum Privacy: String, CaseIterable, Identifiable {
        case `public` = "PUBLIC", unlisted = "UNLISTED", `private` = "PRIVATE"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .public: String(localized: "Public")
            case .unlisted: String(localized: "Unlisted")
            case .private: String(localized: "Private")
            }
        }
    }

    static func setPrivacy(_ privacy: Privacy, playlistId: String) async throws {
        let json = try await api.post("browse/edit_playlist", body: [
            "playlistId": plainPlaylistId(playlistId),
            "actions": [["action": "ACTION_SET_PLAYLIST_PRIVACY", "playlistPrivacy": privacy.rawValue]],
        ])
        if json["status"].string == "STATUS_FAILED" { throw InnerTubeError.unplayable(String(localized: "Couldn't change privacy")) }
    }

    /// Removes songs from your playlist. Each needs its playlist slot (`setVideoId`).
    static func remove(_ tracks: [Track], fromPlaylist playlistId: String) async throws {
        let actions: [[String: Any]] = tracks.compactMap { track in
            guard let slot = track.setVideoId else { return nil }
            return ["action": "ACTION_REMOVE_VIDEO", "setVideoId": slot, "removedVideoId": track.videoId]
        }
        guard !actions.isEmpty else { throw InnerTubeError.unplayable(String(localized: "Couldn't remove from playlist")) }
        let json = try await api.post("browse/edit_playlist", body: ["playlistId": plainPlaylistId(playlistId), "actions": actions])
        if json["status"].string == "STATUS_FAILED" { throw InnerTubeError.unplayable(String(localized: "Couldn't remove from playlist")) }
    }

    /// Moves a song in your playlist to just before another one (nil: to the end).
    static func move(_ track: Track, before successor: Track?, inPlaylist playlistId: String) async throws {
        guard let slot = track.setVideoId else { throw InnerTubeError.unplayable(String(localized: "Couldn't reorder playlist")) }
        var action: [String: Any] = ["action": "ACTION_MOVE_VIDEO_BEFORE", "setVideoId": slot]
        if let next = successor?.setVideoId { action["movedSetVideoIdSuccessor"] = next }
        let json = try await api.post("browse/edit_playlist", body: ["playlistId": plainPlaylistId(playlistId), "actions": [action]])
        if json["status"].string == "STATUS_FAILED" { throw InnerTubeError.unplayable(String(localized: "Couldn't reorder playlist")) }
    }
}
