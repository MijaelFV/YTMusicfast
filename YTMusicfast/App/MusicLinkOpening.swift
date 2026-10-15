import Foundation

extension MusicLink {
    /// Plays a song (followed by its radio), opens a page, or searches.
    @MainActor
    func open() {
        let router = Router.shared
        switch self {
        case .song(let videoId): PlayerController.shared.playSong(videoId: videoId)
        case .page(let target): router.open(target)
        case .search(let query):
            router.search(query)
            router.focusSearch()
        }
    }
}
