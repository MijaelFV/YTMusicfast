import MultipeerConnectivity
import SwiftUI

// MARK: - Watch page extras (chapters, comments token)

/// Loads each song's watch-page extras once and shares them between the views that need them.
@MainActor
@Observable
final class WatchExtrasStore {
    static let shared = WatchExtrasStore()
    private(set) var extras: [String: WatchExtras] = [:]
    /// Requests in flight: a second caller (chapters, comments) waits for the same one.
    private var loading: [String: Task<Void, Never>] = [:]

    func load(_ videoId: String) async {
        guard extras[videoId] == nil else { return }
        if let running = loading[videoId] { return await running.value }
        let task = Task { @MainActor in
            if let result = try? await MusicAPI.watchExtras(videoId: videoId) {
                if extras.count > 40 { extras.removeAll() }
                extras[videoId] = result
            }
            loading[videoId] = nil
        }
        loading[videoId] = task
        await task.value
    }
}

// MARK: - Chapters

/// Chapters of a long video or episode, in the Now Playing view; click one to jump there.
struct ChaptersCard: View {
    var track: Track
    private var player: PlayerController { .shared }
    private var store: WatchExtrasStore { .shared }

    var body: some View {
        Group {
            if let chapters = store.extras[track.videoId]?.chapters, chapters.count > 1 {
                let current = chapters.lastIndex { $0.start <= player.currentTime + 0.5 }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Chapters").font(.system(size: 15, weight: .bold)).padding(.bottom, 4)
                    ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                        Button { player.seek(to: chapter.start) } label: {
                            HStack(spacing: 10) {
                                Text(Format.time(chapter.start))
                                    .font(.system(size: 12).monospacedDigit())
                                    .foregroundStyle(Theme.secondary)
                                    .frame(width: 48, alignment: .leading)
                                Text(chapter.title)
                                    .font(.system(size: 13, weight: index == current ? .bold : .regular))
                                    .foregroundStyle(index == current ? Theme.accent : Theme.text)
                                    .lineLimit(2)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(14)
                .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            }
        }
        .task(id: track.videoId) {
            guard !track.isLocal, (track.duration ?? player.duration) >= 300 || track.isVideo else { return }
            await store.load(track.videoId)
        }
    }
}

// MARK: - Comments

/// YouTube comments on the playing song or video (YouTube Music's "Comments" tab).
struct CommentsList: View {
    @State private var page = CommentPage()
    @State private var loadedFor: String?
    @State private var loading = false
    @State private var commentsOff = false
    @State private var sort: SearchFilter?
    /// The song the sort was picked for: sort tokens belong to one video's comments.
    @State private var sortFor: String?
    @State private var failed = false
    @State private var draft = ""
    @FocusState private var draftFocused: Bool
    @State private var posting = false
    @State private var replies: [String: [Comment]] = [:]
    @Environment(AuthManager.self) private var auth
    private var player: PlayerController { .shared }

    var body: some View {
        Group {
            if player.current == nil || player.current?.isLocal == true {
                ContentUnavailableView("No comments", systemImage: "text.bubble",
                                       description: Text("Play a song from YouTube Music to see what people say about it."))
            } else if commentsOff {
                ContentUnavailableView("Comments are off", systemImage: "text.bubble",
                                       description: Text("There are no comments for this song."))
            } else if failed, page.comments.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't load comments", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("Check your connection and try again.")
                } actions: {
                    Button("Try Again") {
                        loadedFor = nil
                        Task { await load() }
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        header
                        if let params = page.createParams, auth.isSignedIn { composer(params) }
                        ForEach(page.comments) { comment in
                            CommentRow(comment: comment, replies: replies[comment.id]) { await loadReplies(comment) }
                        }
                        if let next = page.next {
                            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                                .task(id: next) { await loadMore(next) }
                        } else if loading, page.comments.isEmpty {
                            VStack(alignment: .leading, spacing: 18) {
                                ForEach(0..<6, id: \.self) { _ in SkeletonComment() }
                            }
                        }
                    }
                    .padding(16)
                }
                .scrollIndicators(.never)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: "\(player.current?.videoId ?? "")|\(sort?.title ?? "")") { await load() }
    }

    private var header: some View {
        HStack {
            Text(page.total ?? String(localized: "Comments")).font(.system(size: 15, weight: .bold))
            Spacer()
            if page.sorts.count > 1 {
                MenuButton(alignment: .trailing) {
                    page.sorts.map { option in
                        .choice(option.title, selected: (sort ?? page.sorts.first) == option) {
                            sortFor = player.current?.videoId
                            sort = option
                        }
                    }
                } label: { open in
                    Label(sort?.title ?? page.sorts.first?.title ?? String(localized: "Sort"), systemImage: "arrow.up.arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(open ? Theme.text : Theme.secondary)
                }
                .fixedSize()
            }
        }
    }

    private func composer(_ params: String) -> some View {
        HStack(spacing: 8) {
            TextField("Add a comment…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...4)
                .focused($draftFocused)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.text.opacity(0.08)))
            Button(posting ? "…" : String(localized: "Post")) {
                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                posting = true
                Task {
                    do {
                        try await MusicAPI.postComment(text, params: params)
                        draft = ""
                        Router.shared.showToast(String(localized: "Comment posted"))
                        loadedFor = nil
                        await load()
                    } catch {
                        Router.shared.showToast(String(localized: "Couldn't post your comment"), icon: "exclamationmark.triangle.fill")
                    }
                    posting = false
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || posting)
        }
        // Clicking elsewhere leaves the box (the draft stays); Post counts as part of it.
        .endEditingOnOutsideClick(isActive: draftFocused) { draftFocused = false }
    }

    private func load() async {
        guard let track = player.current, !track.isLocal else { return }
        // A new song starts with its default order (this restarts the load).
        if sort != nil, sortFor != track.videoId {
            sort = nil
            return
        }
        let key = "\(track.videoId)|\(sort?.title ?? "")"
        guard loadedFor != key else { return }
        loading = true
        defer { loading = false }
        commentsOff = false
        failed = false
        replies = [:]
        if sort == nil || loadedFor?.hasPrefix(track.videoId) != true { page = CommentPage() }
        let token: String?
        if let sortToken = sort?.params {
            token = sortToken
        } else {
            await WatchExtrasStore.shared.load(track.videoId)
            token = WatchExtrasStore.shared.extras[track.videoId]?.commentsToken
        }
        guard let token else {
            commentsOff = WatchExtrasStore.shared.extras[track.videoId] != nil
            return
        }
        let first: CommentPage
        do {
            first = try await MusicAPI.comments(token: token)
        } catch {
            if !Task.isCancelled, player.current?.videoId == track.videoId { failed = true }
            return
        }
        guard player.current?.videoId == track.videoId else { return }
        let sorts = page.sorts.isEmpty ? first.sorts : page.sorts
        page = first
        page.sorts = sorts
        if page.createParams == nil, let params = first.createParams { page.createParams = params }
        commentsOff = first.comments.isEmpty && first.next == nil
        loadedFor = key
    }

    private func loadMore(_ token: String) async {
        guard let more = try? await MusicAPI.comments(token: token), page.next == token else { return }
        let known = Set(page.comments.map(\.id))
        page.comments += more.comments.filter { !known.contains($0.id) }
        page.next = more.next == token ? nil : more.next
    }

    private func loadReplies(_ comment: Comment) async {
        guard let token = comment.repliesToken, replies[comment.id] == nil,
              let result = try? await MusicAPI.comments(token: token) else { return }
        replies[comment.id] = result.comments
    }
}

private struct CommentRow: View {
    var comment: Comment
    var replies: [Comment]?
    var loadReplies: () async -> Void
    @State private var expanded = false
    @State private var showReplies = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ArtworkView(url: comment.authorAvatar, size: 30, circle: true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(comment.author).font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, comment.isCreator ? 6 : 0)
                        .background(Capsule().fill(comment.isCreator ? Theme.text.opacity(0.18) : .clear))
                    Text(comment.published).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                Text(comment.text)
                    .font(.system(size: 13))
                    .lineLimit(expanded ? nil : 5)
                    .textSelection(.enabled)
                    .onTapGesture { expanded.toggle() }
                HStack(spacing: 14) {
                    if let likes = comment.likes {
                        Label(likes, systemImage: "hand.thumbsup").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                    if comment.replyCount > 0 {
                        Button(showReplies ? String(localized: "Hide replies") : "\(comment.replyCount) repl\(comment.replyCount == 1 ? "y" : "ies")") {
                            showReplies.toggle()
                            if showReplies { Task { await loadReplies() } }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.accent)
                    }
                }
                if showReplies {
                    if let replies {
                        ForEach(replies) { reply in
                            HStack(alignment: .top, spacing: 8) {
                                ArtworkView(url: reply.authorAvatar, size: 22, circle: true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(reply.author).font(.system(size: 11, weight: .semibold))
                                    Text(reply.text).font(.system(size: 12)).textSelection(.enabled)
                                }
                            }
                            .padding(.top, 4)
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
    }
}

// MARK: - Listen together

/// Listening together, as a section of the Connect panel: start a session or join
/// one nearby; while in one, who's listening and a way out. Looks for sessions only while shown.
struct ListenTogetherSection: View {
    private var together: ListenTogether { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Listen together").font(.system(size: 15, weight: .bold))
            switch together.role {
            case .off:
                VStack(alignment: .leading, spacing: 12) {
                    Text("Play in sync with people on the same Wi‑Fi. Everyone can play, pause, skip and add songs.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    PillButton(title: String(localized: "Start a session"), filled: true) { ListenTogetherActions.start() }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                HStack(spacing: 8) {
                    Text("Sessions nearby").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
                    ProgressView().controlSize(.mini)
                }
                if together.nearby.isEmpty {
                    Text("Ask a friend to start a session in YT Musicfast.").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                ForEach(together.nearby, id: \.self) { peer in
                    HStack(spacing: 14) {
                        Image(systemName: "person.wave.2.fill").font(.system(size: 18)).frame(width: 32)
                        Text(peer.displayName).font(.system(size: 15)).lineLimit(1)
                        Spacer()
                        PillButton(title: String(localized: "Join"), filled: false) { together.join(peer) }
                    }
                }
            case .hosting, .joined:
                SessionCard()
            }
            if let error = together.lastError {
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
            }
        }
        .foregroundStyle(Theme.text)
        .onAppear { if together.role == .off { together.lookForSessions() } }
        .onDisappear { together.stopLooking() }
    }
}

/// The session you're in: who's there and a way out (Connect panel, top of the queue).
struct SessionCard: View {
    private var together: ListenTogether { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "person.2.wave.2.fill").font(.system(size: 20))
                Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.accent)
            Text(detail).font(.system(size: 13)).foregroundStyle(Theme.secondary).lineLimit(2)
            PillButton(title: together.role == .hosting ? String(localized: "End session") : String(localized: "Leave"), filled: false) {
                together.leave()
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }

    private var title: String {
        switch together.role {
        case .joined(let host): String(localized: "Listening with \(host)")
        default: String(localized: "You're hosting a session")
        }
    }

    private var detail: String {
        switch together.role {
        case .joined:
            together.hostState?.track.map { "\($0.title) · \($0.artistLine)" } ?? String(localized: "Connecting…")
        default:
            together.people.isEmpty ? String(localized: "Waiting for people nearby to join…")
                : String(localized: "Listening with \(together.people.formatted(.list(type: .and)))")
        }
    }
}

/// Starting a session: optionally with something to play, then the
/// queue opens to show it.
@MainActor
enum ListenTogetherActions {
    static func start(playing play: (() -> Void)? = nil) {
        if ListenTogether.shared.role == .off { ListenTogether.shared.startHosting() }
        play?()
        withAnimation(.spring(duration: 0.3)) { Router.shared.rightPanel = .queue }
    }
}

/// Pill buttons: filled (the main action) or outlined.
struct PillButton: View {
    var title: String
    var filled: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(filled ? Color.black : Theme.text)
                .padding(.horizontal, 20)
                .padding(.vertical, 9)
                .background {
                    if filled {
                        Capsule().fill(Theme.accent)
                    } else {
                        Capsule().strokeBorder(hovering ? Theme.text : Theme.tertiary, lineWidth: 1)
                    }
                }
                .scaleEffect(hovering ? 1.04 : 1)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
