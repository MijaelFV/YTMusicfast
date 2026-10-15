import Observation
import SwiftUI

/// Background work worth knowing about — refreshing Your Library or a page you're looking at,
/// checking for updates — for the small spinner in the top bar. Just counters: nothing
/// runs or polls because of it.
@MainActor
@Observable
final class Activity {
    static let shared = Activity()

    enum Kind: CaseIterable {
        case library, page, updates
        /// A collection's songs loading before it plays, queues or downloads.
        case starting, queueing, preparingDownload

        var label: String {
            switch self {
            case .library: String(localized: "Updating Your Library")
            case .page: String(localized: "Refreshing this page")
            case .updates: String(localized: "Checking for updates")
            case .starting: String(localized: "Starting playback")
            case .queueing: String(localized: "Adding to the queue")
            case .preparingDownload: String(localized: "Getting the songs to download")
            }
        }
    }

    private(set) var running: [Kind: Int] = [:]

    var isBusy: Bool { running.values.contains { $0 > 0 } }

    var summary: String {
        Kind.allCases.filter { (running[$0] ?? 0) > 0 }.map(\.label).joined(separator: "\n")
    }

    func begin(_ kind: Kind) { running[kind, default: 0] += 1 }
    func end(_ kind: Kind) { running[kind] = max(0, (running[kind] ?? 0) - 1) }
}

/// The top bar's spinner. Shows only when work takes more than a moment, so quick loads don't
/// flash it.
struct ActivityIndicator: View {
    @State private var visible = false
    private var activity: Activity { .shared }

    var body: some View {
        // Built only while shown: a hidden spinner would still animate.
        ZStack {
            if visible {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 22)
                    .padding(.trailing, 8)
                    .tooltip(activity.summary, edge: .bottom)
                    .accessibilityLabel(activity.summary)
                    .transition(.opacity)
            }
        }
        .task(id: activity.isBusy) {
            guard activity.isBusy else { visible = false; return }
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled, activity.isBusy { withAnimation(.easeOut(duration: 0.2)) { visible = true } }
        }
    }
}
