import Foundation
import Observation

/// On-device library: pins, recently played songs and recently opened collections.
/// Works without signing in, and feeds "Jump back in" on Home and the Library sidebar.
@MainActor
@Observable
final class LocalLibrary {
    static let shared = LocalLibrary()

    private(set) var pinned: [MediaItem] = []
    private(set) var recentCollections: [MediaItem] = []
    private(set) var recentTracks: [Track] = []

    /// Playlist folders. YouTube has none, so they live on this Mac.
    struct Folder: Codable, Identifiable, Hashable {
        var id = UUID()
        var name: String
        /// `MediaItem.id`s of the playlists, albums and artists inside.
        var itemIds: [String] = []
        var expanded = true

        /// Holds this item, however it was opened (see `MediaItem.collectionId`).
        func contains(_ item: MediaItem) -> Bool {
            itemIds.contains { $0 == item.id || $0.split(separator: "|").first.map(String.init) == item.collectionId }
        }
    }

    private(set) var folders: [Folder] = []

    private init() {
        // Older versions could keep one playlist twice (opened with and without YouTube's page
        // parameters): one entry each, the most recent.
        let savedPins: [MediaItem] = Self.load("library.pinned") ?? []
        let savedRecents: [MediaItem] = Self.load("library.recentCollections") ?? []
        pinned = Self.unique(savedPins)
        recentCollections = Self.unique(savedRecents)
        if pinned.count != savedPins.count { Self.save(pinned, "library.pinned") }
        if recentCollections.count != savedRecents.count { Self.save(recentCollections, "library.recentCollections") }
        recentTracks = Self.load("library.recentTracks") ?? []
        folders = Self.load("library.folders") ?? []
    }

    // MARK: Folders

    @discardableResult
    func createFolder(named name: String = String(localized: "New Folder")) -> Folder {
        let existing = Set(folders.map(\.name))
        var title = name
        var counter = 2
        while existing.contains(title) { title = "\(name) \(counter)"; counter += 1 }
        let folder = Folder(name: title)
        folders.insert(folder, at: 0)
        saveFolders()
        return folder
    }

    func rename(_ folder: Folder, to name: String) {
        guard let index = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        folders[index].name = trimmed
        saveFolders()
    }

    func delete(_ folder: Folder) {
        folders.removeAll { $0.id == folder.id }
        saveFolders()
    }

    func toggleExpanded(_ folder: Folder) {
        guard let index = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        folders[index].expanded.toggle()
        saveFolders()
    }

    /// Moves an item into a folder (out of any other), or out of all folders with nil.
    func move(_ item: MediaItem, to folder: Folder?) {
        for index in folders.indices {
            folders[index].itemIds.removeAll { $0 == item.id || $0.split(separator: "|").first.map(String.init) == item.collectionId }
        }
        if let folder, let index = folders.firstIndex(where: { $0.id == folder.id }) {
            folders[index].itemIds.append(item.collectionId)
        }
        saveFolders()
    }

    func folder(containing item: MediaItem) -> Folder? {
        folders.first { $0.contains(item) }
    }

    private func saveFolders() { Self.save(folders, "library.folders") }

    private static func unique(_ items: [MediaItem]) -> [MediaItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.collectionId).inserted }
    }

    func isPinned(_ item: MediaItem) -> Bool {
        pinned.contains { $0.collectionId == item.collectionId }
    }

    func togglePin(_ item: MediaItem) {
        if isPinned(item) {
            pinned.removeAll { $0.collectionId == item.collectionId }
        } else {
            pinned.insert(item, at: 0)
        }
        Self.save(pinned, "library.pinned")
    }

    func recordVisit(_ item: MediaItem) {
        guard item.target.kind != .other else { return }
        recentCollections.removeAll { $0.collectionId == item.collectionId }
        recentCollections.insert(item, at: 0)
        recentCollections = Array(recentCollections.prefix(40))
        Self.save(recentCollections, "library.recentCollections")
    }

    func removeRecent(_ item: MediaItem) {
        recentCollections.removeAll { $0.collectionId == item.collectionId }
        Self.save(recentCollections, "library.recentCollections")
    }

    func recordPlay(_ track: Track) {
        recentTracks.removeAll { $0.videoId == track.videoId }
        recentTracks.insert(track, at: 0)
        recentTracks = Array(recentTracks.prefix(60))
        Self.save(recentTracks, "library.recentTracks")
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
}
