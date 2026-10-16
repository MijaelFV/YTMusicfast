import AppKit
import SwiftUI

/// Every setting by name (and a few words people might search for), for Settings' search field.
struct SettingsEntry: Identifiable {
    var title: String
    var keywords: String = ""
    /// Settings tab, and the section of General to scroll to.
    var tab: String
    var section: String = ""
    var id: String { tab + section + title }

    var place: String {
        switch tab {
        case "equalizer": String(localized: "Equalizer")
        case "filter": String(localized: "Content Filter")
        case "library": String(localized: "Library")
        default: String(localized: "General")
        }
    }

    static var all: [SettingsEntry] {
        [
            SettingsEntry(title: String(localized: "Theme"), keywords: "appearance dark light system mode", tab: "general", section: "appearance"),
            SettingsEntry(title: String(localized: "Player bar visualizer"), keywords: "spectrum waveform animation fps", tab: "general", section: "appearance"),
            SettingsEntry(title: String(localized: "Show what's playing around the notch"), keywords: "notch island widget", tab: "general", section: "appearance"),
            SettingsEntry(title: String(localized: "Normalize volume"), keywords: "loudness level", tab: "general", section: "playback"),
            SettingsEntry(title: String(localized: "Autoplay similar songs when the queue ends"), keywords: "radio endless", tab: "general", section: "playback"),
            SettingsEntry(title: String(localized: "Crossfade"), keywords: "gapless fade transition", tab: "general", section: "playback"),
            SettingsEntry(title: String(localized: "Speed"), keywords: "playback rate tempo", tab: "general", section: "playback"),
            SettingsEntry(title: String(localized: "Streaming quality"), keywords: "bitrate data saver audio", tab: "general", section: "playback"),
            SettingsEntry(title: String(localized: "Show music videos (video mode)"), keywords: "video", tab: "general", section: "playback"),
            SettingsEntry(title: String(localized: "Skip non-music parts of music videos"), keywords: "sponsorblock intro outro", tab: "general", section: "playback"),
            SettingsEntry(title: String(localized: "Show a notification when the song changes"), keywords: "banner alert", tab: "general", section: "playback"),
            SettingsEntry(title: String(localized: "Balance"), keywords: "left right pan channel", tab: "general", section: "playback"),
            SettingsEntry(title: String(localized: "Mono audio"), keywords: "stereo channel", tab: "general", section: "playback"),
            SettingsEntry(title: String(localized: "Play through the TV's YouTube app"), keywords: "cast chromecast google tv sleep stream ads", tab: "general", section: "casting"),
            SettingsEntry(title: String(localized: "Show lyrics on the TV"), keywords: "cast chromecast google tv captions subtitles", tab: "general", section: "casting"),
            SettingsEntry(title: String(localized: "Show YT Musicfast in the menu bar"), keywords: "status icon tray", tab: "general", section: "menubar"),
            SettingsEntry(title: String(localized: "Global shortcuts"), keywords: "hotkeys keyboard", tab: "general", section: "shortcuts"),
            SettingsEntry(title: String(localized: "Phone remote"), keywords: "control qr wifi", tab: "general", section: "remote"),
            SettingsEntry(title: String(localized: "Command-line tool"), keywords: "terminal cli raycast alfred script", tab: "general", section: "cli"),
            SettingsEntry(title: String(localized: "Add songs I play to my YouTube Music history"), keywords: "privacy history", tab: "general", section: "privacy"),
            SettingsEntry(title: String(localized: "Private session"), keywords: "privacy", tab: "general", section: "privacy"),
            SettingsEntry(title: String(localized: "Offline Mode"), keywords: "downloads internet", tab: "general", section: "privacy"),
            SettingsEntry(title: String(localized: "Listening stats"), keywords: "clear plays", tab: "general", section: "privacy"),
            SettingsEntry(title: String(localized: "Open YT Musicfast when I log in"), keywords: "startup launch login", tab: "general", section: "startup"),
            SettingsEntry(title: String(localized: "Replay cache"), keywords: "storage disk space clear", tab: "general", section: "storage"),
            SettingsEntry(title: String(localized: "Saved pages"), keywords: "storage cache clear", tab: "general", section: "storage"),
            SettingsEntry(title: String(localized: "Downloads"), keywords: "storage offline remove", tab: "general", section: "storage"),
            SettingsEntry(title: String(localized: "Updates"), keywords: "version check automatic", tab: "general", section: "updates"),
            SettingsEntry(title: String(localized: "Equalizer"), keywords: "eq bass treble preset", tab: "equalizer"),
            SettingsEntry(title: String(localized: "Hide AI-generated music"), keywords: "ai filter synthetic", tab: "filter"),
            SettingsEntry(title: String(localized: "Hide explicit songs"), keywords: "explicit clean filter", tab: "filter"),
            SettingsEntry(title: String(localized: "Hide songs that can't be played"), keywords: "unavailable filter", tab: "filter"),
            SettingsEntry(title: String(localized: "Shared AI artist list"), keywords: "community list url", tab: "filter"),
            SettingsEntry(title: String(localized: "Hidden songs and artists"), keywords: "hide unhide", tab: "filter"),
            SettingsEntry(title: String(localized: "Local Files"), keywords: "folders music mac", tab: "library"),
        ]
    }

    static func matching(_ query: String) -> [SettingsEntry] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        return all.filter { entry in
            let haystack = "\(entry.title) \(entry.keywords) \(entry.place)".lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }
}

/// Settings that match the search, in place of the General tab's sections.
struct SettingsSearchResults: View {
    var query: String
    var open: (SettingsEntry) -> Void

    var body: some View {
        let results = SettingsEntry.matching(query)
        Section {
            if results.isEmpty {
                Text("No settings match “\(query)”.").foregroundStyle(.secondary)
            }
            ForEach(results) { entry in
                Button { open(entry) } label: {
                    HStack {
                        Text(entry.title)
                        Spacer()
                        Text(entry.place).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Installs `ytmusicfast` (bundled in the app) on the PATH as a symbolic link.
struct CommandLineSection: View {
    @State private var installedAt: String? = CommandLineTool.installedPath
    @State private var error: String?

    var body: some View {
        Section {
            LabeledContent {
                Button(installedAt == nil ? String(localized: "Install") : String(localized: "Reinstall")) {
                    switch CommandLineTool.install() {
                    case .success(let path):
                        installedAt = path
                        error = nil
                    case .failure(let message):
                        error = message
                    }
                }
            } label: {
                if let installedAt {
                    Text("Installed at \(installedAt)")
                } else {
                    Text("Not installed")
                }
            }
            if let error {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(CommandLineTool.manualCommand)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(CommandLineTool.manualCommand, forType: .string)
                        }
                        .controlSize(.small)
                    }
                }
            }
        } header: {
            Text("Command-line tool")
        } footer: {
            Text("Control playback from Terminal, scripts, Raycast or Alfred: ytmusicfast play-pause, next, now-playing, play-search… Run ytmusicfast help for everything.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

enum CommandLineTool {
    static var bundled: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ytmusicfast") }

    /// Folders on the PATH, Homebrew's first (writable without a password when Homebrew is installed).
    private static let candidates = ["/opt/homebrew/bin", "/usr/local/bin"]

    static var installedPath: String? {
        candidates.map { "\($0)/ytmusicfast" }.first { path in
            (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) == bundled.path
        }
    }

    static var manualCommand: String {
        "sudo ln -sf '\(bundled.path)' /usr/local/bin/ytmusicfast"
    }

    enum Result { case success(String), failure(String) }

    static func install() -> Result {
        let manager = FileManager.default
        for folder in candidates where manager.isWritableFile(atPath: folder) {
            let path = "\(folder)/ytmusicfast"
            // Only replace our own link (or nothing): never someone else's file.
            if manager.fileExists(atPath: path) || (try? manager.destinationOfSymbolicLink(atPath: path)) != nil {
                guard let target = try? manager.destinationOfSymbolicLink(atPath: path), target.hasSuffix("/Contents/Helpers/ytmusicfast") else {
                    return .failure(String(localized: "\(path) already exists and isn't YT Musicfast's. Remove it first, or install by hand:"))
                }
                try? manager.removeItem(atPath: path)
            }
            do {
                try manager.createSymbolicLink(atPath: path, withDestinationPath: bundled.path)
                return .success(path)
            } catch {
                continue
            }
        }
        return .failure(String(localized: "Installing needs an administrator. Run this in Terminal:"))
    }
}
