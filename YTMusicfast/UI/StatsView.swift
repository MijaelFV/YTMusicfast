import Charts
import SwiftUI

/// "Your stats": top songs and artists, minutes listened and when you listen — from what you've
/// played on this Mac (a year-in-review you can look at any time).
struct StatsView: View {
    @AppStorage("statsRange") private var rangeRaw = ListeningStats.Range.month.rawValue
    @Environment(Router.self) private var router
    @Environment(AuthManager.self) private var auth
    @State private var savingPlaylist = false
    private var stats: ListeningStats { .shared }

    private var range: ListeningStats.Range { ListeningStats.Range(rawValue: rangeRaw) ?? .month }
    /// Cached by the store, so reading it per render is cheap.
    private var summary: ListeningStats.Summary { stats.summary(for: range) }
    private var topTracks: [Track] { summary.topTracks.prefix(50).map(\.track) }
    static let target = BrowseTarget(browseId: "ytmusicfast:stats", kind: .other, title: String(localized: "Your top songs"))

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header
                if summary.playCount == 0 {
                    emptyState
                } else {
                    tiles
                    topArtists
                    topSongs
                    hours
                }
            }
            .padding(.bottom, 40)
            .restoresScrollPosition()
        }
        .environment(\.playContext, Self.target)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your listening").font(.system(size: 14, weight: .medium))
                Text("Stats").font(.system(size: 72, weight: .black)).tracking(-2)
                Text(subtitle).font(.system(size: 14)).foregroundStyle(Theme.secondary)
            }
            HStack(spacing: 8) {
                ForEach(ListeningStats.Range.allCases) { option in
                    Chip(title: option.title, selected: option == range) { rangeRaw = option.rawValue }
                }
            }
        }
        .padding(.top, 48)
        .padding(.horizontal, Theme.pagePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.42, green: 0.16, blue: 0.55), Theme.panel], startPoint: .top, endPoint: .bottom)
                .frame(height: 320)
                .allowsHitTesting(false)
        }
    }

    private var subtitle: String {
        guard let first = stats.plays.first?.date else { return String(localized: "Kept on this Mac") }
        return String(localized: "Kept on this Mac since \(first.formatted(date: .abbreviated, time: .omitted))")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(stats.plays.isEmpty ? String(localized: "Your stats start here") : String(localized: "Nothing in this period"), systemImage: "chart.bar.xaxis")
        } description: {
            Text(stats.plays.isEmpty
                 ? String(localized: "Songs you listen to for 30 seconds or more show up here — your top songs, artists and how much you listen.")
                 : String(localized: "Pick a longer period to see more."))
        }
        .padding(.top, 20)
    }

    // MARK: Summary

    private var tiles: some View {
        HStack(spacing: 12) {
            StatTile(value: Self.minutes(summary.seconds), label: Self.minutes(summary.seconds) == "1" ? "minute listened" : "minutes listened")
            StatTile(value: summary.songCount.formatted(), label: summary.songCount == 1 ? "song" : "songs")
            StatTile(value: summary.artistCount.formatted(), label: summary.artistCount == 1 ? "artist" : "artists")
            StatTile(value: summary.activeDays.formatted(), label: summary.activeDays == 1 ? "day you listened" : "days you listened")
        }
        .padding(.horizontal, Theme.pagePadding)
    }

    static func minutes(_ seconds: TimeInterval) -> String {
        Int((seconds / 60).rounded()).formatted()
    }

    // MARK: Top artists

    @ViewBuilder
    private var topArtists: some View {
        let artists = Array(summary.topArtists.prefix(8))
        if !artists.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: String(localized: "Top artists"), label: range.title)
                    .padding(.horizontal, Theme.pagePadding)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(Array(artists.enumerated()), id: \.element.id) { rank, artist in
                            TopArtistCard(rank: rank + 1, artist: artist)
                        }
                    }
                    .padding(.horizontal, Theme.pagePadding - 12)
                }
            }
        }
    }

    // MARK: Top songs

    private var topSongs: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                SectionHeader(title: String(localized: "Top songs"), label: range.title)
                let state = PlayerController.shared.playState(of: Self.target)
                PlayCircleButton(size: 44, isPlaying: state == .playing, loading: state == .loading) {
                    PlayerController.shared.playOrToggle(topTracks, from: Self.target)
                }
                IconButton(systemImage: "shuffle", size: 20, label: String(localized: "Shuffle play")) {
                    PlayerController.shared.play(topTracks, shuffled: true, from: Self.target)
                }
                Button {
                    saveAsPlaylist()
                } label: {
                    Label("Save as Playlist", systemImage: "plus.circle")
                }
                .buttonStyle(.bordered)
                .disabled(savingPlaylist || topTracks.allSatisfy(\.isLocal))
            }
            .padding(.horizontal, Theme.pagePadding)
            TopSongsList(tracks: summary.topTracks.prefix(50).map { $0 })
                .padding(.horizontal, Theme.pagePadding - 12)
        }
    }

    private func saveAsPlaylist() {
        guard auth.isSignedIn else { router.showSignIn = true; return }
        let ids = topTracks.filter { !$0.isLocal }.map(\.videoId)
        let title = String(localized: "My top songs — \(range.title.lowercased())")
        savingPlaylist = true
        Task {
            defer { savingPlaylist = false }
            do {
                let id = try await MusicAPI.createPlaylist(title: title, videoIds: ids)
                router.showToast(String(localized: "Saved \(Format.count(ids.count, .song)) to “\(title)”"))
                RemoteLibraryCache.needsReload += 1
                if let id { router.open(BrowseTarget(browseId: "VL\(id)", kind: .playlist, title: title)) }
            } catch {
                router.showToast(String(localized: "Couldn't create playlist"), icon: "exclamationmark.triangle.fill")
            }
        }
    }

    // MARK: Listening clock

    private var hours: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: String(localized: "When you listen"), label: peakHourLabel)
            Chart {
                ForEach(0..<24, id: \.self) { hour in
                    BarMark(x: .value("Hour", hour), y: .value("Minutes", summary.minutesByHour[hour]))
                        .foregroundStyle(hour == peakHour ? Theme.accent : Theme.text.opacity(0.28))
                        .cornerRadius(3)
                }
            }
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18]) { value in
                    AxisValueLabel {
                        if let hour = value.as(Int.self) { Text(Self.hourName(hour)) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Theme.text.opacity(0.08))
                    AxisValueLabel {
                        if let minutes = value.as(Double.self) { Text("\(Int(minutes)) min") }
                    }
                }
            }
            .frame(height: 180)
            .accessibilityLabel("Minutes listened by hour of the day")
        }
        .padding(.horizontal, Theme.pagePadding)
    }

    private var peakHour: Int? {
        let peak = summary.minutesByHour.enumerated().max { $0.element < $1.element }
        return peak.flatMap { $0.element > 0 ? $0.offset : nil }
    }

    private var peakHourLabel: String? {
        guard let peakHour else { return nil }
        return String(localized: "You listen most around \(Self.hourName(peakHour))")
    }

    static func hourName(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        let date = Calendar.current.date(from: components) ?? Date()
        return date.formatted(.dateTime.hour())
    }
}

private struct StatTile: View {
    var value: String
    var label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 30, weight: .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label).font(.system(size: 13)).foregroundStyle(Theme.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.text.opacity(0.06)))
        .accessibilityElement(children: .combine)
    }
}

/// An artist circle with their rank; shows their YouTube photo once it's loaded.
private struct TopArtistCard: View {
    var rank: Int
    var artist: ListeningStats.TopArtist
    @State private var photo: URL?
    @State private var hovering = false
    @Environment(Router.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkView(url: photo ?? artist.artwork, size: 148, circle: true)
                .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                .overlay(alignment: .bottomLeading) {
                    Text("\(rank)")
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(Theme.onContrast)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Theme.contrast))
                }
                // The round play button: plays the artist (their top songs).
                .overlay(alignment: .bottomTrailing) {
                    if let id = artist.artist.browseId {
                        let target = BrowseTarget(browseId: id, kind: .artist, title: artist.artist.name)
                        let state = PlayerController.shared.playState(of: target)
                        if hovering || state == .loading || state == .playing {
                            PlayCircleButton(size: 44, isPlaying: state == .playing, loading: state == .loading) {
                                if state == .playing || state == .paused { PlayerController.shared.togglePlayPause() }
                                else { PlayerController.shared.playCollection(target) }
                            }
                            .transition(.opacity.combined(with: .offset(y: 6)))
                        }
                    }
                }
                .animation(.easeOut(duration: 0.15), value: hovering)
            Text(artist.artist.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            Text("\(Format.count(artist.count, .play)) · \(StatsView.minutes(artist.seconds)) min")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
        }
        .frame(width: 148, alignment: .leading)
        .padding(12)
        .rowBackground(hovering: hovering)
        .contentShape(Rectangle())
        // Artists from local files have no YouTube page.
        .onTapGesture { router.open(artist: artist.artist) }
        .onHover { hovering = $0 && artist.artist.browseId != nil }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { router.open(artist: artist.artist) }
        .accessibilityAction(named: "Play") {
            if let id = artist.artist.browseId {
                PlayerController.shared.playCollection(BrowseTarget(browseId: id, kind: .artist, title: artist.artist.name))
            }
        }
        .task(id: artist.id) { photo = await ArtistPhotos.photo(for: artist.artist) }
        .accessibilityLabel("Number \(rank), \(artist.artist.name), \(Format.count(artist.count, .play))")
    }
}

/// Top songs with how many times you played each.
private struct TopSongsList: View {
    var tracks: [ListeningStats.TopTrack]

    var body: some View {
        VStack(spacing: 0) {
            // The plays column shows your own play count here.
            // History saved from some pages has no length; the song's own (known once played) fills in.
            let known = tracks.contains { $0.track.duration == nil } ? AudioCache.durations() : [:]
            TrackList(tracks: tracks.map { top in
                var track = top.track
                track.plays = Format.count(top.count, .play)
                if track.duration == nil { track.duration = known[track.videoId] }
                return track
            }, showHeader: true, showPlays: true)
            if tracks.count >= 50 {
                Text("Your top 50").font(.system(size: 12)).foregroundStyle(Theme.tertiary).padding(.top, 10)
            }
        }
    }
}

/// Artist photos from their YouTube Music page, remembered between launches.
@MainActor
enum ArtistPhotos {
    private static var cache: [String: String] = UserDefaults.standard.dictionary(forKey: "stats.artistPhotos") as? [String: String] ?? [:]

    static func photo(for artist: ArtistRef) async -> URL? {
        guard let id = artist.browseId, !PlayerController.shared.offlineMode else { return nil }
        if let cached = cache[id] { return URL(string: cached) }
        guard let page = try? await MusicAPI.browse(BrowseTarget(browseId: id, kind: .artist, title: artist.name)),
              let url = page.header?.thumbnail else { return nil }
        cache[id] = url.absoluteString
        UserDefaults.standard.set(cache, forKey: "stats.artistPhotos")
        return url
    }
}
