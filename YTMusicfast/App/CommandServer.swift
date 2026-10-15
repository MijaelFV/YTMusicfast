import AppKit
import Foundation

/// Lets the `ytmusicfast` command-line tool (and launchers like Raycast or Alfred that call it)
/// control the running app.
///
/// Requests arrive on a Mach message port registered for this user only: no network socket, no
/// polling — the port costs nothing until a command comes in. Each request names a reply port of
/// the tool's own; the answer is sent there once the command has run (searches take a moment).
@MainActor
enum CommandServer {
    static let portName = "dev.ytmusicfast.app.control" as CFString
    private static var port: CFMessagePort?

    struct Request: Codable {
        var args: [String]
        var replyPort: String
    }

    struct Reply: Codable {
        var output: String
        var status: Int32
    }

    static func start() {
        guard port == nil else { return }
        var shouldFree: DarwinBoolean = false
        guard let local = CFMessagePortCreateLocal(nil, portName, { _, _, data, _ in
            guard let data = data as Data?, let request = try? JSONDecoder().decode(Request.self, from: data) else { return nil }
            MainActor.assumeIsolated {
                Task { @MainActor in
                    let reply = await CommandServer.run(request.args)
                    CommandServer.send(reply, to: request.replyPort)
                }
            }
            return nil
        }, nil, &shouldFree) else { return }
        port = local
        let source = CFMessagePortCreateRunLoopSource(nil, local, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private static func send(_ reply: Reply, to name: String) {
        guard let remote = CFMessagePortCreateRemote(nil, name as CFString),
              let data = try? JSONEncoder().encode(reply) else { return }
        CFMessagePortSendRequest(remote, 0, data as CFData, 2, 0, nil, nil)
        CFMessagePortInvalidate(remote)
    }

    // MARK: Commands

    private static func ok(_ output: String = "") -> Reply { Reply(output: output, status: 0) }
    private static func fail(_ output: String) -> Reply { Reply(output: output, status: 1) }

    static func run(_ args: [String]) async -> Reply {
        let player = PlayerController.shared
        guard let command = args.first else { return fail("No command. Try: ytmusicfast help") }
        let rest = Array(args.dropFirst())
        let number = rest.first.flatMap(Double.init)

        switch command {
        case "play-pause":
            player.togglePlayPause()
        case "play":
            if !player.isPlaying { player.togglePlayPause() }
        case "pause":
            if player.isPlaying { player.togglePlayPause() }
        case "next":
            player.next()
        case "previous":
            player.previous()
        case "volume":
            guard let number else { return ok("\(Int((player.volume * 100).rounded()))") }
            player.isMuted = false
            player.volume = min(1, max(0, number / 100))
        case "volume-up":
            player.volume = min(1, player.volume + (number ?? 10) / 100)
        case "volume-down":
            player.volume = max(0, player.volume - (number ?? 10) / 100)
        case "mute":
            player.toggleMute()
        case "shuffle":
            let want = rest.first.map { $0 == "on" } ?? !player.shuffle
            if want != player.shuffle { player.toggleShuffle() }
        case "repeat":
            if let mode = rest.first {
                guard let target = RepeatMode(rawValue: mode == "track" ? "one" : mode == "context" ? "all" : mode) else {
                    return fail("repeat takes off, all or one")
                }
                player.repeatMode = target
            } else {
                player.cycleRepeat()
            }
        case "seek":
            guard let number else { return fail("seek takes a number of seconds (negative goes back)") }
            player.skip(by: number)
        case "seek-to":
            guard let number else { return fail("seek-to takes a position in seconds") }
            player.seek(to: max(0, number))
        case "like":
            guard let track = player.current, !track.isLocal else { return fail("Nothing to like") }
            guard AuthManager.shared.isSignedIn else { return fail("Sign in to like songs") }
            player.toggleLike()
            return ok(player.likeStatus == .like ? "Liked" : "Removed like")
        case "play-search":
            return await playSearch(rest)
        case "now-playing":
            return nowPlaying(raw: rest.contains("--raw"))
        case "devices":
            return devices(raw: rest.contains("--raw"))
        case "transfer":
            guard let uid = rest.first else { return fail("transfer takes a device id (see: ytmusicfast devices)") }
            if uid == "default" {
                player.outputDeviceUID = nil
            } else {
                guard OutputDevices.all().contains(where: { $0.uid == uid }) else { return fail("No such device: \(uid)") }
                player.outputDeviceUID = uid
            }
        case "diagnose":
            // A song link or id; the playing song when there's none.
            let id = rest.first { !$0.hasPrefix("--") && Int($0) == nil }.flatMap { text -> String? in
                if case .song(let id) = MusicLink(text) { return id }
                return text.count == 11 ? text : nil
            } ?? player.current?.videoId
            guard let id else { return fail("diagnose takes a song link or id") }
            if rest.contains("--video") {
                let height = rest.firstIndex(of: "--quality").flatMap { rest.indices.contains($0 + 1) ? Int(rest[$0 + 1]) : nil }
                let jump = rest.firstIndex(of: "--at").flatMap { rest.indices.contains($0 + 1) ? TimeInterval(rest[$0 + 1]) : nil }
                return ok(await VideoController.diagnose(videoId: id, height: height, jumpTo: jump, noOutput: rest.contains("--no-output")))
            }
            return ok(await ChainedStreamResolver.shared.diagnose(videoId: id))
        #if DEBUG
        case "debug-cast":
            // Casting from scripts: `debug-cast <device name>`, `debug-cast off`, `debug-cast status`.
            let cast = CastController.shared
            switch rest.joined(separator: " ") {
            case "", "status": break
            case "off": cast.disconnect()
            case let name:
                cast.startDiscovery()
                defer { cast.stopDiscovery() }
                for _ in 0..<30 where !cast.devices.contains(where: { $0.name == name }) { try? await Task.sleep(for: .milliseconds(250)) }
                guard let device = cast.devices.first(where: { $0.name == name }) else {
                    return fail("No Cast device named \(name) (found: \(cast.devices.map(\.name).joined(separator: ", ")))")
                }
                cast.cast(to: device)
                for _ in 0..<30 where !cast.isActive { try? await Task.sleep(for: .milliseconds(250)) }
            }
            let data = (try? JSONSerialization.data(withJSONObject: cast.debugState, options: [.sortedKeys])) ?? Data()
            return ok(String(decoding: data, as: UTF8.self))
        #endif
        case "show":
            StatusBarController.showMainWindow()
        case "open":
            guard let text = rest.first, let link = MusicLink(text) else { return fail("Not a YouTube Music link") }
            if case .song = link {} else { StatusBarController.showMainWindow() }
            link.open()
        default:
            // `ytmusicfast <link>` opens it.
            if let link = MusicLink(command) {
                if case .song = link {} else { StatusBarController.showMainWindow() }
                link.open()
                return ok()
            }
            return fail("Unknown command: \(command). Try: ytmusicfast help")
        }
        return ok()
    }

    private static func playSearch(_ args: [String]) async -> Reply {
        var words = args
        var kind = "song"
        if let index = words.firstIndex(of: "--kind"), words.indices.contains(index + 1) {
            kind = words[index + 1]
            words.removeSubrange(index...(index + 1))
        }
        let query = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return fail("play-search takes words to search for") }
        guard var results = try? await MusicAPI.search(query) else { return fail("Search failed (offline?)") }
        // Narrow to the kind asked for, with YouTube Music's own filter when there is one.
        let filterTitle = ["song": "Songs", "album": "Albums", "artist": "Artists", "playlist": "Community playlists"][kind]
        if let title = filterTitle, let params = results.filters.first(where: { $0.title == title })?.params,
           let narrowed = try? await MusicAPI.search(query, params: params) {
            results = narrowed
        }
        let items = ContentFilter.shared.filter(([results.top].compactMap { $0 }) + results.items)
        let player = PlayerController.shared
        if kind == "song" {
            guard let track = items.compactMap(\.track).first else { return fail("No songs match “\(query)”") }
            player.playRadio(from: track)
            return ok("Playing \(track.title) — \(track.artistLine)")
        }
        let wanted: PageKind = kind == "album" ? .album : kind == "artist" ? .artist : .playlist
        let media = items.compactMap { item -> MediaItem? in
            if case .media(let m) = item, m.target.kind == wanted { return m }
            return nil
        }.first
        guard let media else { return fail("No \(kind)s match “\(query)”") }
        player.playCollection(media.target, playlistId: media.playlistId)
        return ok("Playing \(media.title)")
    }

    private static func nowPlaying(raw: Bool) -> Reply {
        let player = PlayerController.shared
        guard let track = player.current else { return raw ? ok("stopped") : ok("Nothing playing") }
        let state = player.isPlaying ? "playing" : "paused"
        let device = player.outputDeviceUID.flatMap { uid in OutputDevices.all().first { $0.uid == uid }?.name } ?? "System default"
        if raw {
            let fields: [String] = [
                state, track.title, track.artists.map(\.name).joined(separator: ", "), track.album?.name ?? "",
                String(Int(player.currentTime)), String(Int(player.duration)), String(Int((player.volume * 100).rounded())),
                player.shuffle ? "on" : "off", player.repeatMode.rawValue, track.thumbnail?.absoluteString ?? "",
                player.likeStatus == .like ? "saved" : "", device,
            ]
            return ok(fields.map { $0.replacingOccurrences(of: "\t", with: " ") }.joined(separator: "\t"))
        }
        var lines = ["\(track.title) — \(track.artistLine)"]
        if let album = track.album?.name { lines.append(album) }
        lines.append("\(state.capitalized) · \(Format.time(player.currentTime)) / \(Format.time(player.duration))")
        return ok(lines.joined(separator: "\n"))
    }

    private static func devices(raw: Bool) -> Reply {
        let current = PlayerController.shared.outputDeviceUID ?? OutputDevices.defaultDeviceUID()
        let list = OutputDevices.all()
        if raw {
            let rows = list.map { ["uid": $0.uid, "name": $0.name, "active": $0.uid == current ? "true" : "false"] }
            let data = (try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])) ?? Data()
            return ok(String(decoding: data, as: UTF8.self))
        }
        return ok(list.map { "\($0.uid == current ? "*" : " ") \($0.name)\t\($0.uid)" }.joined(separator: "\n"))
    }
}
