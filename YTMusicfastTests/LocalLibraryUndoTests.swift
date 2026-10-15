import Foundation
import Testing

/// Undo in Your Library puts things back exactly where they were.
@Suite("Your Library undo", .serialized)
@MainActor
struct LocalLibraryUndoTests {
    private let library = LocalLibrary.shared

    private func item(_ id: String) -> MediaItem {
        MediaItem(target: BrowseTarget(browseId: id, kind: .playlist, title: id), subtitle: "")
    }

    @Test func deletedFolderComesBackInPlaceWithItsPlaylists() {
        let first = library.createFolder(named: "Undo test A")
        let second = library.createFolder(named: "Undo test B")
        defer { library.delete(first); library.delete(second) }
        let playlist = item("VLundo-test-folder")
        library.move(playlist, to: second)
        let before = library.folders.map(\.id)
        let saved = library.folders.first { $0.id == second.id }!

        let index = library.delete(saved)
        #expect(!library.folders.contains { $0.id == second.id })

        library.restore(saved, at: index)
        #expect(library.folders.map(\.id) == before)
        #expect(library.folder(containing: playlist)?.id == second.id)

        // Undoing twice doesn't make a second copy.
        library.restore(saved, at: index)
        #expect(library.folders.filter { $0.id == second.id }.count == 1)
    }

    @Test func removedRecentComesBackInPlace() {
        let a = item("VLundo-test-a"), b = item("VLundo-test-b")
        library.recordVisit(a)
        library.recordVisit(b)
        defer { library.removeRecent(a); library.removeRecent(b) }
        let before = library.recentCollections.map(\.collectionId)

        let index = library.removeRecent(a)
        #expect(!library.recentCollections.contains { $0.collectionId == a.collectionId })
        library.restoreRecent(a, at: index)
        #expect(library.recentCollections.map(\.collectionId) == before)
    }
}
