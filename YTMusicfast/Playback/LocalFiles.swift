import AVFoundation
import CryptoKit
import Foundation
import Observation

/// Local Files: music folders on this Mac, played alongside YouTube Music.
///
/// Songs get a stable id from their path (`local:…`) so they work in the queue, recents and the
/// restored session like any other song. Title, artist, album, length and cover come from the
/// files' own tags; covers are written to the cache so the normal artwork loader shows them.
@MainActor
@Observable
final class LocalFiles {
    static let shared = LocalFiles()

    nonisolated static let extensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "alac", "caf", "mp4"]

    private(set) var folders: [String] = UserDefaults.standard.stringArray(forKey: "localFolders") ?? []
    private(set) var tracks: [Track] = []
    private(set) var scanning = false

    static let target = BrowseTarget(browseId: "local-files", kind: .other, title: String(localized: "Local Files"))

    private nonisolated static let artDirectory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YTMusicfast/local-art", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static var indexURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YTMusicfast/local-files.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.indexURL), let saved = try? JSONDecoder().decode([Track].self, from: data) {
            tracks = saved
        }
    }

    nonisolated static func id(for path: String) -> String {
        "local:" + SHA256.hash(data: Data(path.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    func add(folder url: URL) {
        let path = url.standardizedFileURL.path
        guard !folders.contains(path) else { return }
        folders.append(path)
        UserDefaults.standard.set(folders, forKey: "localFolders")
        Task { await rescan() }
    }

    func remove(folder path: String) {
        folders.removeAll { $0 == path }
        UserDefaults.standard.set(folders, forKey: "localFolders")
        tracks.removeAll { $0.localPath?.hasPrefix(path) == true }
        save()
    }

    /// Reads every audio file in the folders (tags are read off the main thread).
    func rescan() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        let folders = self.folders
        let known = Dictionary(tracks.compactMap { track in track.localPath.map { ($0, track) } }, uniquingKeysWith: { a, _ in a })
        let found = await Task.detached(priority: .utility) { () -> [Track] in
            var result: [Track] = []
            for folder in folders {
                guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: folder),
                                                                  includingPropertiesForKeys: [.isRegularFileKey],
                                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                while let url = walker.nextObject() as? URL {
                    guard Self.extensions.contains(url.pathExtension.lowercased()) else { continue }
                    if let existing = known[url.path] {
                        result.append(existing)
                    } else if let track = await Self.read(url) {
                        result.append(track)
                    }
                }
            }
            return result.sorted {
                ($0.artistLine, $0.album?.name ?? "", $0.title) < ($1.artistLine, $1.album?.name ?? "", $1.title)
            }
        }.value
        tracks = found
        save()
    }

    private nonisolated static func read(_ url: URL) async -> Track? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds > 0 else { return nil }
        let metadata = (try? await asset.load(.commonMetadata)) ?? []
        func value(_ key: AVMetadataKey) async -> String? {
            guard let item = AVMetadataItem.metadataItems(from: metadata, withKey: key, keySpace: .common).first else { return nil }
            return try? await item.load(.stringValue)
        }
        let title = await value(.commonKeyTitle) ?? url.deletingPathExtension().lastPathComponent
        let artist = await value(.commonKeyArtist)
        let album = await value(.commonKeyAlbumName)
        var artURL: URL?
        if let item = AVMetadataItem.metadataItems(from: metadata, withKey: AVMetadataKey.commonKeyArtwork, keySpace: .common).first,
           let data = try? await item.load(.dataValue) {
            let file = artDirectory.appendingPathComponent(id(for: url.path).replacingOccurrences(of: "local:", with: "") + ".img")
            try? data.write(to: file, options: .atomic)
            artURL = file
        }
        return Track(
            videoId: id(for: url.path),
            title: title,
            artists: artist.map { [ArtistRef(name: $0, browseId: nil)] } ?? [],
            album: album.map { AlbumRef(name: $0, browseId: nil) },
            duration: duration.seconds,
            thumbnail: artURL,
            localPath: url.path
        )
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(tracks) { try? data.write(to: Self.indexURL, options: .atomic) }
    }
}
