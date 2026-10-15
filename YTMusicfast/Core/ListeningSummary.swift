import Foundation

/// One song you listened to for 30 seconds or more.
struct Listen: Codable, Hashable, Sendable {
    var track: Track
    var date: Date
    /// How long you actually listened.
    var seconds: TimeInterval
}

/// Top songs and artists, minutes and listening hours for a period (the Stats page).
struct ListeningSummary: Sendable {
    struct TopTrack: Identifiable, Hashable, Sendable {
        var track: Track
        var count: Int
        var seconds: TimeInterval
        var id: String { track.videoId }
    }

    struct TopArtist: Identifiable, Hashable, Sendable {
        var artist: ArtistRef
        var count: Int
        var seconds: TimeInterval
        /// Artwork of their song you played most (artist photos come from YouTube, on demand).
        var artwork: URL?
        var id: String { artist.browseId ?? artist.name.lowercased() }
    }

    var seconds: TimeInterval = 0
    var playCount = 0
    var topTracks: [TopTrack] = []
    var topArtists: [TopArtist] = []
    /// Minutes listened in each hour of the day (0–23).
    var minutesByHour = [Double](repeating: 0, count: 24)
    /// Distinct days you listened on.
    var activeDays = 0
    var songCount: Int { topTracks.count }
    var artistCount: Int { topArtists.count }

    init() {}

    init(_ plays: [Listen], since start: Date) {
        var tracks: [String: TopTrack] = [:]
        var artists: [String: TopArtist] = [:]
        var artistTrackCounts: [String: [String: Int]] = [:]
        var days = Set<DateComponents>()
        let calendar = Calendar.current
        for play in plays where play.date >= start {
            seconds += play.seconds
            playCount += 1
            let hour = calendar.component(.hour, from: play.date)
            minutesByHour[hour] += play.seconds / 60
            days.insert(calendar.dateComponents([.year, .month, .day], from: play.date))

            var top = tracks[play.track.videoId] ?? TopTrack(track: play.track, count: 0, seconds: 0)
            top.count += 1
            top.seconds += play.seconds
            top.track = play.track  // the newest metadata wins
            tracks[play.track.videoId] = top

            for ref in play.track.artists where !ref.name.isEmpty {
                let key = ref.browseId ?? ref.name.lowercased()
                var artist = artists[key] ?? TopArtist(artist: ref, count: 0, seconds: 0)
                artist.count += 1
                artist.seconds += play.seconds
                if artist.artist.browseId == nil, ref.browseId != nil { artist.artist = ref }
                artists[key] = artist
                artistTrackCounts[key, default: [:]][play.track.videoId, default: 0] += 1
            }
        }
        let byPlays: (TopTrack, TopTrack) -> Bool = { $0.count != $1.count ? $0.count > $1.count : $0.seconds > $1.seconds }
        topTracks = tracks.values.sorted(by: byPlays)
        topArtists = artists.map { key, value in
            var artist = value
            if let favourite = artistTrackCounts[key]?.max(by: { $0.value < $1.value })?.key {
                artist.artwork = tracks[favourite]?.track.thumbnail
            }
            return artist
        }
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0.seconds > $1.seconds }
        activeDays = days.count
    }
}
