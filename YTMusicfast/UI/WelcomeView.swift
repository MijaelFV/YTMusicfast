import SwiftUI

/// First-launch sheet: what the app is, what it isn't, and an optional sign-in.
struct WelcomeView: View {
    var onFinish: () -> Void
    @Environment(Router.self) private var router

    var body: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Welcome to YT Musicfast").font(.largeTitle.bold())
                Text("A fast, native Mac app for YouTube Music.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 16) {
                feature("bolt.fill", String(localized: "Native and light"),
                        String(localized: "Plays audio directly — no browser inside. Songs load in about a second and skips are instant."))
                feature("person.crop.circle", String(localized: "Your music, if you want it"),
                        String(localized: "Sign in with Google for your mixes, liked songs and playlists. Everything else works without an account."))
                feature("keyboard", String(localized: "Built for the keyboard"),
                        String(localized: "Space to play/pause, ⌘F to search, ⌘← ⌘→ to skip, ⌘L to like."))
                feature("quote.bubble", String(localized: "Lyrics and more"),
                        String(localized: "Time-synced lyrics, crossfade, volume normalization and a menu-bar mini player."))
            }
            .frame(maxWidth: 440)

            Text("YT Musicfast is an independent open-source project. It isn't affiliated with or endorsed by Google or YouTube.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            HStack(spacing: 12) {
                Button("Sign in with Google") {
                    onFinish()
                    // After the welcome sheet is gone: two sheets in one update can drop the second.
                    Task {
                        try? await Task.sleep(for: .milliseconds(450))
                        router.showSignIn = true
                    }
                }
                .controlSize(.large)
                Button("Start Listening") { onFinish() }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(36)
        .frame(width: 560)
    }

    private func feature(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color.brand)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
