import SwiftUI

/// "Let's find something for your playlist": search right on the playlist page and add songs.
struct PlaylistFinder: View {
    @FocusState private var queryFocused: Bool
    let playlistId: String
    var onAdded: () -> Void
    var onClose: (() -> Void)?

    @State private var query = ""
    @State private var results: [Track] = []
    @State private var added: Set<String> = []
    @State private var searching = false
    @Environment(Router.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Rectangle().fill(Theme.text.opacity(0.1)).frame(height: 1)
            HStack {
                Text("Let's find something for your playlist").font(.sectionTitle)
                Spacer()
                if let onClose {
                    IconButton(systemImage: "xmark", size: 16, label: String(localized: "Close")) { onClose() }
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
                TextField("Search for songs", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($queryFocused)
                if searching { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 12)
            .frame(width: 400, height: 38)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.text.opacity(0.1)))
            .endEditingOnOutsideClick(isActive: queryFocused) { queryFocused = false }

            LazyVStack(spacing: 0) {
                ForEach(results) { track in
                    FinderRow(track: track, added: added.contains(track.videoId)) { add(track) }
                }
            }
        }
        .padding(.horizontal, 12)
        .task(id: query) {
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            guard trimmed.count > 1 else { results = []; return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            searching = true
            defer { searching = false }
            // Songs only: an all-results search ranks covers and videos above the actual song.
            let found = try? await MusicAPI.search(trimmed, params: "EgWKAQIIAWoMEA4QChADEAQQCRAF")
            guard !Task.isCancelled else { return }
            results = Array((found?.items.compactMap(\.track) ?? []).prefix(12))
        }
    }

    private func add(_ track: Track) {
        // Marked "Added" only once it is (an "Already added" → "Don't add" leaves it as it was).
        router.add(videoIds: [track.videoId], toPlaylist: playlistId, title: "playlist") {
            added.insert(track.videoId)
            onAdded()
        }
    }
}

/// Suggested songs under your playlist, each with an Add button.
struct RecommendedSongs: View {
    let playlistId: String
    let tracks: [Track]
    var onAdded: () -> Void
    @State private var added: Set<String> = []
    @Environment(Router.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recommended").font(.sectionTitle).padding(.horizontal, 12)
            Text("Based on what's in this playlist")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            ForEach(tracks) { track in
                FinderRow(track: track, added: added.contains(track.videoId)) {
                    router.add(videoIds: [track.videoId], toPlaylist: playlistId, title: "playlist") {
                        added.insert(track.videoId)
                        onAdded()
                    }
                }
            }
        }
    }
}

struct FinderRow: View {
    var track: Track
    var added: Bool
    var add: () -> Void
    @State private var hovering = false
    private var player: PlayerController { .shared }

    private var isCurrent: Bool { player.current?.videoId == track.videoId }

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: track.thumbnail, size: 40, cornerRadius: 4)
                .overlay {
                    // A play button on the cover while hovering, bars while it plays.
                    if hovering || (isCurrent && player.isPlaying) {
                        RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.5))
                        if hovering {
                            Button(action: play) {
                                Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.text)
                                    .frame(width: 40, height: 40)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(isCurrent && player.isPlaying ? String(localized: "Pause") : String(localized: "Play \(track.title)"))
                        } else {
                            EqualizerBars(animating: true)
                        }
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.system(size: 15))
                    .foregroundStyle(isCurrent ? Theme.accent : Theme.text)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if track.isExplicit == true { ExplicitBadge() }
                    Text(track.artistLine).lineLimit(1)
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(track.album?.name ?? "").font(.system(size: 13)).foregroundStyle(Theme.secondary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: add) {
                Text(added ? String(localized: "Added") : String(localized: "Add"))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .overlay(Capsule().strokeBorder(added ? Theme.tertiary : Theme.secondary, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(added)
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
        .background(RoundedRectangle(cornerRadius: 4).fill(hovering ? Theme.text.opacity(0.1) : .clear))
        // The whole row, not just its text, takes hover and double-click.
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: play)
    }

    private func play() {
        if isCurrent { player.togglePlayPause() } else { player.playRadio(from: track) }
    }
}

/// "Edit details": rename and describe your playlist.
struct PlaylistDetailsSheet: View {
    let playlistId: String
    @State var title: String
    @State var details: String
    @State var privacy: MusicAPI.Privacy
    var onSaved: () -> Void
    var onDelete: (() -> Void)? = nil
    @State private var originalPrivacy: MusicAPI.Privacy?

    /// Your playlist's header says "Private" / "Public" / "Unlisted" among its subtitle parts.
    static func privacy(from header: PageHeader?) -> MusicAPI.Privacy {
        let parts = ((header?.subtitle ?? "") + " • " + (header?.secondSubtitle ?? "")).components(separatedBy: " • ")
        return MusicAPI.Privacy.allCases.first { parts.contains($0.title) } ?? .private
    }
    @Environment(\.dismiss) private var dismiss
    @Environment(Router.self) private var router
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Edit details").font(.sectionTitle)
                Spacer()
                IconButton(systemImage: "xmark", size: 14, label: String(localized: "Close")) { dismiss() }
            }
            TextField("Add a name", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.text.opacity(0.1)))
            TextField("Add an optional description", text: $details, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(4...6)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.text.opacity(0.1)))
            Picker("Visibility", selection: $privacy) {
                ForEach(MusicAPI.Privacy.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                if let onDelete {
                    Button("Delete playlist", role: .destructive) {
                        dismiss()
                        onDelete()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.red)
                }
                Spacer()
                Button(action: save) {
                    Text(saving ? String(localized: "Saving…") : String(localized: "Save"))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.onContrast)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Theme.contrast))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(Theme.raised)
        .onAppear { if originalPrivacy == nil { originalPrivacy = privacy } }
    }

    private func save() {
        saving = true
        Task {
            do {
                try await MusicAPI.renamePlaylist(playlistId, title: title.trimmingCharacters(in: .whitespaces), description: details)
                if privacy != originalPrivacy { try await MusicAPI.setPrivacy(privacy, playlistId: playlistId) }
                RemoteLibraryCache.needsReload += 1
                onSaved()
                dismiss()
            } catch {
                router.showToast(String(localized: "Couldn't save changes"), icon: "exclamationmark.triangle.fill")
                saving = false
            }
        }
    }
}
