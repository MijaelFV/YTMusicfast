import AppIntents

// Actions for the Shortcuts app, Siri and Spotlight. They run inside the app (launching it in the
// background if needed), so playback keeps going where it is.

struct PlayPauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    static let description = IntentDescription("Plays or pauses the current song in YT Musicfast.")

    @MainActor
    func perform() async throws -> some IntentResult {
        PlayerController.shared.togglePlayPause()
        return .result()
    }
}

struct NextSongIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Song"
    static let description = IntentDescription("Skips to the next song.")

    @MainActor
    func perform() async throws -> some IntentResult {
        PlayerController.shared.next()
        return .result()
    }
}

struct PreviousSongIntent: AppIntent {
    static let title: LocalizedStringResource = "Previous Song"
    static let description = IntentDescription("Goes back to the previous song.")

    @MainActor
    func perform() async throws -> some IntentResult {
        PlayerController.shared.previous()
        return .result()
    }
}

struct LikeSongIntent: AppIntent {
    static let title: LocalizedStringResource = "Like the Current Song"
    static let description = IntentDescription("Likes the playing song, adding it to Liked Music (signed in).")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let player = PlayerController.shared
        guard let track = player.current, !track.isLocal else { return .result(dialog: "Nothing is playing.") }
        if !player.isLiked(track) { player.setLiked(true, track) }
        return .result(dialog: "Liked \(track.title).")
    }
}

struct WhatsPlayingIntent: AppIntent {
    static let title: LocalizedStringResource = "What's Playing"
    static let description = IntentDescription("Tells you the song and artist that's playing.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let track = PlayerController.shared.current else {
            return .result(value: "", dialog: "Nothing is playing.")
        }
        let line = "\(track.title) — \(track.artistLine)"
        return .result(value: line, dialog: "\(line)")
    }
}

struct StartRadioIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Radio from the Current Song"
    static let description = IntentDescription("Replaces what's up next with a radio based on the playing song.")

    @MainActor
    func perform() async throws -> some IntentResult {
        if let track = PlayerController.shared.current { PlayerController.shared.playRadio(from: track) }
        return .result()
    }
}

struct PlayMusicIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Music"
    static let description = IntentDescription("Searches YouTube Music and plays the top result: a song (with its radio), artist, album or playlist.")

    @Parameter(title: "Search for", requestValueDialog: "What do you want to play?")
    var query: String

    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$query)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let results = try await MusicAPI.search(query)
        let candidates = ([results.top].compactMap { $0 } + results.items).filter { item in
            if case .track(let track) = item { return !ContentFilter.shared.isHidden(track) }
            return true
        }
        guard let first = candidates.first else { return .result(dialog: "Couldn't find \(query).") }
        let player = PlayerController.shared
        switch first {
        case .track(let track):
            player.playRadio(from: track)
            return .result(dialog: "Playing \(track.title).")
        case .media(let item):
            if item.target.kind == .artist {
                player.startRadio(for: item)
            } else {
                player.playCollection(item.target, playlistId: item.playlistId)
            }
            return .result(dialog: "Playing \(item.title).")
        }
    }
}

struct YTMusicfastShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayMusicIntent(), phrases: ["Play music in \(.applicationName)", "Play something in \(.applicationName)"],
                    shortTitle: "Play Music", systemImageName: "play.circle")
        AppShortcut(intent: PlayPauseIntent(), phrases: ["Pause \(.applicationName)", "Resume \(.applicationName)"],
                    shortTitle: "Play or Pause", systemImageName: "playpause")
        AppShortcut(intent: NextSongIntent(), phrases: ["Next song in \(.applicationName)", "Skip this song in \(.applicationName)"],
                    shortTitle: "Next Song", systemImageName: "forward.end")
        AppShortcut(intent: LikeSongIntent(), phrases: ["Like this song in \(.applicationName)"],
                    shortTitle: "Like Song", systemImageName: "heart")
        AppShortcut(intent: WhatsPlayingIntent(), phrases: ["What's playing in \(.applicationName)"],
                    shortTitle: "What's Playing", systemImageName: "music.note")
        AppShortcut(intent: StartRadioIntent(), phrases: ["Start a radio in \(.applicationName)"],
                    shortTitle: "Start Radio", systemImageName: "dot.radiowaves.left.and.right")
    }
}
