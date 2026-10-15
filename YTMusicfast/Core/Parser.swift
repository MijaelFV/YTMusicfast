import Foundation

/// Turns raw InnerTube JSON into app models. Everything here is defensive:
/// unknown renderers are skipped instead of failing the whole page.
enum Parser {
    // MARK: Primitives

    static func thumbnail(in json: JSON) -> URL? {
        guard let list = json.first("thumbnails")?.array, let last = list.last?["url"].string else { return nil }
        return URL(string: last.hasPrefix("//") ? "https:" + last : last)
    }

    static func pageType(_ endpoint: JSON) -> String? {
        endpoint.at("browseEndpoint", "browseEndpointContextSupportedConfigs", "browseEndpointContextMusicConfig", "pageType").string
    }

    static func browseTarget(_ endpoint: JSON, title: String) -> BrowseTarget? {
        guard let id = endpoint.at("browseEndpoint", "browseId").string else { return nil }
        return BrowseTarget(
            browseId: id,
            kind: PageKind(pageType: pageType(endpoint)),
            title: title,
            params: endpoint.at("browseEndpoint", "params").string
        )
    }

    static func duration(_ text: String) -> TimeInterval? {
        let parts = text.split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    private static let typeLabels: Set<String> = ["Song", "Video", "Episode", "Podcast", "Single", "EP", "Album", "Playlist", "Artist", "Profile"]
    private static let separators: Set<String> = [" • ", " & ", ", ", " · ", " and "]

    struct Byline {
        var artists: [ArtistRef] = []
        var album: AlbumRef?
        var duration: TimeInterval?
        var plain: [String] = []
    }

    /// Splits byline runs into artists / album / duration / leftover text.
    static func byline(_ runs: [JSON]) -> Byline {
        var result = Byline()
        for run in runs {
            guard let text = run["text"].string else { continue }
            let endpoint = run["navigationEndpoint"]
            switch PageKind(pageType: pageType(endpoint)) {
            case .artist:
                result.artists.append(ArtistRef(name: text, browseId: endpoint.at("browseEndpoint", "browseId").string))
            case .album:
                result.album = AlbumRef(name: text, browseId: endpoint.at("browseEndpoint", "browseId").string)
            default:
                if separators.contains(text) { continue }
                if let d = duration(text) {
                    result.duration = d
                } else {
                    result.plain.append(text)
                }
            }
        }
        return result
    }

    /// Plain text that plausibly names an artist (not a type label, play count or year).
    static func plainArtist(_ texts: [String]) -> ArtistRef? {
        let candidate = texts.first { text in
            !typeLabels.contains(text)
                && !text.contains(" plays") && !text.contains(" views") && !text.contains(" likes")
                && !text.contains("monthly audience") && !text.contains("subscribers")
                && Int(text) == nil
        }
        return candidate.map { ArtistRef(name: $0, browseId: nil) }
    }

    static func isVideo(_ endpoint: JSON) -> Bool {
        guard let type = endpoint.first("musicVideoType")?.string else { return false }
        return type != "MUSIC_VIDEO_TYPE_ATV"
    }

    // MARK: Items

    static func item(_ wrapper: JSON) -> ShelfItem? {
        if case let r = wrapper["musicResponsiveListItemRenderer"], r.exists { return responsiveItem(r) }
        if case let r = wrapper["musicTwoRowItemRenderer"], r.exists { return twoRowItem(r) }
        if case let r = wrapper["playlistPanelVideoRenderer"], r.exists { return panelTrack(r).map(ShelfItem.track) }
        if case let r = wrapper["musicNavigationButtonRenderer"], r.exists { return categoryButton(r) }
        return nil
    }

    static func responsiveItem(_ r: JSON) -> ShelfItem? {
        let columns = r["flexColumns"].array.map { $0.at("musicResponsiveListItemFlexColumnRenderer", "text") }
        let fixed = r["fixedColumns"].array.map { $0.at("musicResponsiveListItemFixedColumnRenderer", "text") }
        guard let titleColumn = columns.first, let title = titleColumn.text else { return nil }
        let thumb = thumbnail(in: r["thumbnail"])

        let titleEndpoint = titleColumn.runs.first?["navigationEndpoint"] ?? .null
        let videoId = r.at("playlistItemData", "videoId").string
            ?? titleEndpoint.at("watchEndpoint", "videoId").string

        if let videoId {
            let rest = columns.dropFirst().flatMap(\.runs) + fixed.flatMap(\.runs)
            let info = byline(rest)
            var artists = info.artists
            if artists.isEmpty, let column = columns.dropFirst().first {
                if let fallback = plainArtist(byline(column.runs).plain) { artists = [fallback] }
            }
            return .track(Track(
                videoId: videoId,
                title: title,
                artists: artists,
                album: info.album,
                duration: info.duration,
                thumbnail: thumb,
                isVideo: isVideo(titleEndpoint.exists ? titleEndpoint : r["overlay"]),
                // Songs count plays, videos count views.
                plays: info.plain.first { $0.hasSuffix(" plays") || $0.hasSuffix(" views") },
                isExplicit: isExplicit(r),
                likeStatus: likeStatus(r),
                setVideoId: r.at("playlistItemData", "playlistSetVideoId").string,
                historyToken: historyToken(r)
            ))
        }

        guard let target = browseTarget(r["navigationEndpoint"], title: title) else { return nil }
        let subtitle = columns.dropFirst().compactMap(\.text).joined(separator: " • ")
        let named = byline(columns.dropFirst().flatMap(\.runs)).artists.filter { $0.browseId != nil }
        return .media(MediaItem(
            target: target,
            subtitle: subtitle,
            thumbnail: thumb,
            playlistId: r["overlay"].first("watchPlaylistEndpoint")?["playlistId"].string,
            artists: named.isEmpty ? nil : named
        ))
    }

    static func twoRowItem(_ r: JSON) -> ShelfItem? {
        guard let title = r["title"].text else { return nil }
        let thumb = thumbnail(in: r["thumbnailRenderer"])
        let subtitleRuns = r["subtitle"].runs
        let endpoint = r["navigationEndpoint"]

        if let videoId = endpoint.at("watchEndpoint", "videoId").string {
            let info = byline(subtitleRuns)
            var artists = info.artists
            if artists.isEmpty, let fallback = plainArtist(info.plain) { artists = [fallback] }
            return .track(Track(videoId: videoId, title: title, artists: artists, album: info.album,
                                duration: info.duration, thumbnail: thumb, isVideo: isVideo(endpoint),
                                plays: info.plain.first { $0.hasSuffix(" plays") || $0.hasSuffix(" views") },
                                isExplicit: isExplicit(r)))
        }

        guard let target = browseTarget(endpoint, title: title) else { return nil }
        let named = byline(subtitleRuns).artists.filter { $0.browseId != nil }
        return .media(MediaItem(
            target: target,
            subtitle: r["subtitle"].text ?? "",
            thumbnail: thumb,
            playlistId: r["thumbnailOverlay"].first("watchPlaylistEndpoint")?["playlistId"].string,
            artists: named.isEmpty ? nil : named
        ))
    }

    /// Mood/genre buttons: a coloured tile that opens a category page.
    static func categoryButton(_ r: JSON) -> ShelfItem? {
        guard let title = r["buttonText"].text,
              let target = browseTarget(r["clickCommand"], title: title) else { return nil }
        let color = r.at("solid", "leftStripeColor").double.map { UInt32(truncatingIfNeeded: Int64($0)) }
        return .media(MediaItem(target: target, subtitle: "", thumbnail: nil, color: color))
    }

    static func panelTrack(_ r: JSON) -> Track? {
        guard let videoId = r["videoId"].string, let title = r["title"].text else { return nil }
        let info = byline(r["longBylineText"].runs)
        var artists = info.artists
        if artists.isEmpty, let fallback = plainArtist(info.plain) { artists = [fallback] }
        return Track(
            videoId: videoId,
            title: title,
            artists: artists,
            album: info.album,
            duration: r["lengthText"].text.flatMap(duration),
            thumbnail: thumbnail(in: r["thumbnail"]),
            isVideo: isVideo(r["navigationEndpoint"]),
            isExplicit: isExplicit(r),
            likeStatus: likeStatus(r)
        )
    }

    /// The little "E" badge YouTube puts next to explicit songs.
    static func isExplicit(_ r: JSON) -> Bool {
        (r["badges"].array + r["subtitleBadges"].array).contains {
            $0.at("musicInlineBadgeRenderer", "icon", "iconType").string == "MUSIC_EXPLICIT_BADGE"
        }
    }

    /// History rows offer "Remove from history": a feedback token in the row's menu.
    static func historyToken(_ r: JSON) -> String? {
        r["menu"].findAll("menuServiceItemRenderer").first { item in
            item["text"].text?.localizedCaseInsensitiveContains("history") == true
        }?.at("serviceEndpoint", "feedbackEndpoint", "feedbackToken").string
    }

    /// "Song credits": each section is a role with one name per line.
    static func credits(_ json: JSON) -> [CreditRole] {
        json.findAll("dismissableDialogContentSectionRenderer").compactMap { section in
            guard let role = section["title"].text else { return nil }
            let names = section["subtitle"].runs.compactMap { $0["text"].string }
                .flatMap { $0.components(separatedBy: "\n") }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return names.isEmpty ? nil : CreditRole(role: role, names: names)
        }
    }

    /// Countries in Charts' country menu: names from the menu, codes from its form entities.
    static func chartCountries(_ json: JSON) -> (countries: [ChartCountry], selected: String?) {
        var codes: [String: (code: String, selected: Bool)] = [:]
        for choice in json.findAll("musicFormBooleanChoice") {
            if let id = choice["id"].string, let code = choice["opaqueToken"].string {
                codes[id] = (code, choice["selected"].bool ?? false)
            }
        }
        var selected: String?
        let countries: [ChartCountry] = json.findAll("musicMultiSelectMenuItemRenderer").compactMap { item in
            guard let name = item["title"].text, let key = item["formItemEntityKey"].string, let entry = codes[key],
                  entry.code != "ZZ" || name.localizedCaseInsensitiveContains("global") else { return nil }
            if entry.selected { selected = entry.code }
            return ChartCountry(code: entry.code, name: name)
        }
        return (countries, selected)
    }

    // MARK: Watch page (regular YouTube)

    static func watchExtras(_ json: JSON) -> WatchExtras {
        var seen = Set<Double>()
        let chapters: [Chapter] = json.findAll("chapterRenderer").compactMap { chapter in
            guard let title = chapter["title"].text, let millis = chapter["timeRangeStartMillis"].double,
                  seen.insert(millis).inserted else { return nil }
            return Chapter(title: title, start: millis / 1000)
        }
        let section = json.findAll("itemSectionRenderer").first { $0["sectionIdentifier"].string == "comment-item-section" }
        return WatchExtras(chapters: chapters.sorted { $0.start < $1.start },
                           commentsToken: section?.first("continuationCommand")?["token"].string)
    }

    /// A page of comments (or of one comment's replies). Comment text lives in entity payloads,
    /// keyed by the comment views, which give the order.
    static func comments(_ json: JSON) -> CommentPage {
        var page = CommentPage()
        var entities: [String: JSON] = [:]
        for payload in json.findAll("commentEntityPayload") {
            if let key = payload["key"].string { entities[key] = payload }
        }
        var order: [(key: String, repliesToken: String?)] = []
        let items = json["onResponseReceivedEndpoints"].array.flatMap { endpoint in
            endpoint.at("reloadContinuationItemsCommand", "continuationItems").array
                + endpoint.at("appendContinuationItemsAction", "continuationItems").array
        }
        for item in items {
            if case let thread = item["commentThreadRenderer"], thread.exists {
                guard let key = thread.at("commentViewModel", "commentViewModel", "commentKey").string else { continue }
                order.append((key, thread["replies"].first("continuationCommand")?["token"].string))
            } else if case let view = item["commentViewModel"], view.exists, let key = view["commentKey"].string {
                order.append((key, nil))
            } else if case let more = item["continuationItemRenderer"], more.exists {
                page.next = more.first("continuationCommand")?["token"].string
            } else if case let header = item["commentsHeaderRenderer"], header.exists {
                page.total = header["countText"].text
                page.sorts = header.findAll("subMenuItems").flatMap(\.array).compactMap { option in
                    guard let title = option["title"].string,
                          let token = option.at("serviceEndpoint", "continuationCommand", "token").string else { return nil }
                    return SearchFilter(title: title, params: token)
                }
                page.createParams = header.first("createCommentParams")?.string
            }
        }
        page.comments = order.compactMap { entry in
            guard let payload = entities[entry.key], let text = payload.at("properties", "content", "content").string else { return nil }
            let author = payload["author"]
            let replies = payload.at("toolbar", "replyCount").string.flatMap { Int($0.filter(\.isNumber)) } ?? 0
            return Comment(
                id: payload.at("properties", "commentId").string ?? entry.key,
                author: author["displayName"].string ?? "",
                authorAvatar: author["avatarThumbnailUrl"].string.flatMap(URL.init(string:)),
                text: text,
                published: payload.at("properties", "publishedTime").string ?? "",
                likes: payload.at("toolbar", "likeCountNotliked").string.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 },
                replyCount: replies,
                repliesToken: replies > 0 ? entry.repliesToken : nil,
                isCreator: author["isCreator"].bool == true || author["isArtist"].bool == true
            )
        }
        return page
    }

    /// YouTube's "How this was made" disclosure says the content is altered or synthetic (AI).
    /// Other disclosures in the same section (auto-dubbed audio) don't count.
    static func isSyntheticDisclosure(_ json: JSON) -> Bool {
        json.findAll("howThisWasMadeSectionViewModel").contains { section in
            let text = [section.at("bodyHeader", "content").string, section.at("bodyText", "content").string]
                .compactMap { $0?.lowercased() }.joined(separator: " ")
            return text.contains("synthetic") || text.contains("altered") || text.contains("ai-generated")
                || text.contains("generated with ai") || text.contains("made with ai")
        }
    }

    /// Song rows carry a like button in their menu; its state says whether the song is in Liked Music.
    static func likeStatus(_ r: JSON) -> LikeStatus? {
        r["menu"].first("likeButtonRenderer")?["likeStatus"].string.flatMap(LikeStatus.init(rawValue:))
    }

    // MARK: Pages

    static func page(_ json: JSON) -> BrowsePage {
        var page = BrowsePage()
        walk(json.raw, into: &page)
        return page
    }

    private static func listContinuation(_ shelf: JSON) -> String? {
        shelf.at("continuations", 0, "nextContinuationData", "continuation").string
            ?? shelf["contents"].array.last?.first("continuationCommand")?["token"].string
    }

    private static func walk(_ node: Any?, into page: inout BrowsePage) {
        if let array = node as? [Any] {
            for value in array { walk(value, into: &page) }
            return
        }
        guard let dict = node as? [String: Any] else { return }

        for key in JSON.orderedKeys(dict) {
            let value = JSON(dict[key])
            switch key {
            case "musicCarouselShelfRenderer":
                let header = value.at("header", "musicCarouselShelfBasicHeaderRenderer")
                let titleText = header["title"].text
                let more = header.at("moreContentButton", "buttonRenderer", "navigationEndpoint").exists
                    ? header.at("moreContentButton", "buttonRenderer", "navigationEndpoint")
                    : header.at("title", "runs", 0, "navigationEndpoint")
                let items = value["contents"].array.compactMap(item)
                if !items.isEmpty {
                    let isRows = value.at("contents", 0, "musicResponsiveListItemRenderer").exists
                    page.shelves.append(Shelf(title: titleText, label: header["strapline"].text, style: isRows ? .rows : .carousel, items: items,
                                              moreTarget: browseTarget(more, title: titleText ?? "")))
                }

            case "musicShelfRenderer", "musicPlaylistShelfRenderer", "musicShelfContinuation", "musicPlaylistShelfContinuation":
                let items = value["contents"].array.compactMap(item)
                if !items.isEmpty {
                    page.shelves.append(Shelf(title: value["title"].text, style: .list, items: items,
                                              continuation: listContinuation(value),
                                              isPlaylistContents: key.hasPrefix("musicPlaylistShelf")))
                }

            case "appendContinuationItemsAction":
                // Later batches of a long playlist: bare rows, with the next token on the last item.
                let rows = value["continuationItems"].array
                let items = rows.compactMap(item)
                if !items.isEmpty {
                    page.shelves.append(Shelf(style: .list, items: items,
                                              continuation: rows.last?.first("continuationCommand")?["token"].string,
                                              isPlaylistContents: true))
                }

            case "gridRenderer", "gridContinuation":
                let items = value["items"].array.compactMap(item)
                if !items.isEmpty {
                    let title = value.at("header", "gridHeaderRenderer", "title").text
                    let isCategories = value.at("items", 0, "musicNavigationButtonRenderer").exists
                    page.shelves.append(Shelf(title: title, style: isCategories ? .categories : .grid, items: items,
                                              continuation: value.at("continuations", 0, "nextContinuationData", "continuation").string))
                }

            case "musicResponsiveHeaderRenderer", "musicImmersiveHeaderRenderer", "musicVisualHeaderRenderer", "musicDetailHeaderRenderer", "musicHeaderRenderer":
                if page.header == nil { page.header = header(value) }

            case "chipCloudRenderer":
                if page.chips.isEmpty { page.chips = chips(value) }

            case "musicDescriptionShelfRenderer":
                if page.header?.description == nil { page.header?.description = value["description"].text }

            case "sectionListRenderer", "sectionListContinuation":
                if page.continuation == nil {
                    page.continuation = value.at("continuations", 0, "nextContinuationData", "continuation").string
                }
                walk(value.raw, into: &page)

            case "menu", "responseContext", "frameworkUpdates", "microformat", "trackingParams", "musicCardShelfRenderer":
                continue

            default:
                walk(value.raw, into: &page)
            }
        }
    }

    /// Home's mood chips: each reloads the page with its own params.
    static func chips(_ cloud: JSON) -> [SearchFilter] {
        cloud["chips"].array.compactMap { wrapper in
            let chip = wrapper["chipCloudChipRenderer"]
            guard let title = chip["text"].text,
                  let params = chip.at("navigationEndpoint", "browseEndpoint", "params").string else { return nil }
            return SearchFilter(title: title, params: params)
        }
    }

    /// The playlist a watch endpoint (play/shuffle/radio button) starts.
    private static func watchPlaylistId(_ endpoint: JSON) -> String? {
        endpoint.at("watchPlaylistEndpoint", "playlistId").string ?? endpoint.at("watchEndpoint", "playlistId").string
    }

    static func header(_ h: JSON) -> PageHeader? {
        guard let title = h["title"].text else { return nil }
        let strapline = byline(h["straplineTextOne"].runs)
        var artists = strapline.artists
        if artists.isEmpty, let fallback = plainArtist(strapline.plain) { artists = [fallback] }
        let facepile = h.at("facepile", "avatarStackViewModel")
        let ownerName = facepile.at("text", "content").string
        let ownerId = facepile.first("browseEndpoint")?["browseId"].string
        let buttons = h["buttons"].array
        let libraryToggle = buttons.first { $0["toggleButtonRenderer"].exists }?["toggleButtonRenderer"]
        let playEndpoint = buttons.first { $0["musicPlayButtonRenderer"].exists }?.at("musicPlayButtonRenderer", "playNavigationEndpoint")
        let subscribe = h.at("subscriptionButton", "subscribeButtonRenderer")
        return PageHeader(
            title: title,
            subtitle: h["subtitle"].text ?? h["monthlyListenerCount"].text,
            secondSubtitle: h["secondSubtitle"].text,
            description: h.first("description")?.text ?? h["description"].text,
            thumbnail: thumbnail(in: h["thumbnail"]) ?? thumbnail(in: h),
            artists: artists,
            owner: ownerName.map { ArtistRef(name: $0, browseId: ownerId) },
            ownerAvatar: facepile.first("sources")?[0]["url"].string.flatMap(URL.init(string:)),
            playlistId: playEndpoint.flatMap(watchPlaylistId),
            inLibrary: libraryToggle?["isToggled"].bool,
            channelId: subscribe["channelId"].string,
            subscribed: subscribe["subscribed"].bool,
            radioPlaylistId: watchPlaylistId(h.at("startRadioButton", "buttonRenderer", "navigationEndpoint")),
            shufflePlaylistId: watchPlaylistId(h.at("playButton", "buttonRenderer", "navigationEndpoint"))
        )
    }

    // MARK: Search

    static func search(_ json: JSON) -> SearchResults {
        var results = SearchResults()

        if let card = json.first("musicCardShelfRenderer") {
            let titleRun = card.at("title", "runs", 0)
            let title = card["title"].text ?? ""
            let endpoint = titleRun["navigationEndpoint"]
            let thumb = thumbnail(in: card["thumbnail"])
            results.topSubtitle = card["subtitle"].text
            if let videoId = endpoint.at("watchEndpoint", "videoId").string {
                let info = byline(card["subtitle"].runs)
                results.top = .track(Track(videoId: videoId, title: title, artists: info.artists, album: info.album,
                                           duration: info.duration, thumbnail: thumb, isVideo: isVideo(endpoint)))
            } else if let target = browseTarget(endpoint, title: title) {
                let named = byline(card["subtitle"].runs).artists.filter { $0.browseId != nil }
                results.top = .media(MediaItem(target: target, subtitle: card["subtitle"].text ?? "", thumbnail: thumb,
                                               artists: named.isEmpty ? nil : named))
            }
        }

        let sections = json.first("sectionListRenderer")?["contents"].array
            ?? json.at("continuationContents").array
        for section in sections where section.firstKey != "musicCardShelfRenderer" {
            results.items += section.findAll("musicResponsiveListItemRenderer").compactMap(responsiveItem)
        }
        if results.items.isEmpty, let shelf = json.first("musicShelfContinuation") {
            results.items = shelf["contents"].array.compactMap(item)
        }

        // When the top result is an artist, YouTube omits that artist from the song rows below it.
        if case .media(let top) = results.top, top.target.kind == .artist {
            let artist = ArtistRef(name: top.title, browseId: top.target.browseId)
            results.items = results.items.map { item in
                guard case .track(var track) = item, track.artists.isEmpty else { return item }
                track.artists = [artist]
                return .track(track)
            }
        }

        results.continuation = json.first("musicShelfRenderer").flatMap(listContinuation)
            ?? json.first("musicShelfContinuation").flatMap(listContinuation)

        let chips = json.findAll("chipCloudChipRenderer").compactMap { chip -> SearchFilter? in
            guard let title = chip["text"].text else { return nil }
            return SearchFilter(title: title, params: chip.at("navigationEndpoint", "searchEndpoint", "params").string)
        }
        if !chips.isEmpty { results.filters = [SearchFilter(title: "All", params: nil)] + chips.filter { $0.params != nil } }
        return results
    }

    // MARK: Radio / queue

    static func suggestions(_ json: JSON) -> SearchSuggestions {
        SearchSuggestions(
            queries: json.findAll("searchSuggestionRenderer").compactMap {
                $0.at("navigationEndpoint", "searchEndpoint", "query").string ?? $0["suggestion"].text
            },
            items: json.findAll("musicResponsiveListItemRenderer").compactMap(responsiveItem)
        )
    }

    static func radio(_ json: JSON) -> RadioResult {
        let panel = json.first("playlistPanelRenderer") ?? json.first("playlistPanelContinuation") ?? .null
        let tracks = panel["contents"].array.compactMap { entry -> Track? in
            let renderer = entry["playlistPanelVideoRenderer"].exists
                ? entry["playlistPanelVideoRenderer"]
                : entry.at("playlistPanelVideoWrapperRenderer", "primaryRenderer", "playlistPanelVideoRenderer")
            return panelTrack(renderer)
        }
        let continuation = panel.at("continuations", 0, "nextRadioContinuationData", "continuation").string
            ?? panel.at("continuations", 0, "nextContinuationData", "continuation").string
        // Tuning chips refill the queue (`queueUpdateCommand`); the "Save" chip is something else.
        var selected: String?
        let tuners = json.findAll("chipCloudChipRenderer").compactMap { chip -> RadioTuner? in
            let endpoint = chip.at("navigationEndpoint", "queueUpdateCommand", "fetchContentsCommand", "watchEndpoint")
            guard let title = chip["text"].text, let playlistId = endpoint["playlistId"].string else { return nil }
            if chip["isSelected"].bool == true { selected = title }
            return RadioTuner(title: title, playlistId: playlistId, params: endpoint["params"].string)
        }
        return RadioResult(tracks: tracks, continuation: continuation, tuners: tuners.count > 1 ? tuners : [],
                           selectedTuner: tuners.count > 1 ? selected ?? tuners.first?.title : nil)
    }
}
