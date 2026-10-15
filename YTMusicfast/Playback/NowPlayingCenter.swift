import AppKit
import MediaPlayer

/// Bridges playback to Control Center's Now Playing widget and the keyboard media keys.
@MainActor
final class NowPlayingCenter {
    private unowned let player: PlayerController
    private var artwork: MPMediaItemArtwork?
    private var artworkVideoId: String?

    init(player: PlayerController) {
        self.player = player
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            guard let self, !self.player.isPlaying else { return .success }
            self.player.togglePlayPause()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.player.isPlaying else { return .success }
            self.player.togglePlayPause()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.player.togglePlayPause()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.player.next()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.player.previous()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.player.seek(to: event.positionTime)
            return .success
        }
    }

    func updateTrack() {
        guard let track = player.current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        if artworkVideoId != track.videoId {
            artwork = nil
            artworkVideoId = track.videoId
            loadArtwork(for: track)
        }
        publish()
    }

    func updatePlayback() {
        publish()
    }

    private func publish() {
        guard let track = player.current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artistLine,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? player.playbackRate : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: player.playbackRate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let album = track.album?.name { info[MPMediaItemPropertyAlbumTitle] = album }
        let duration = player.duration > 0 ? player.duration : (track.duration ?? 0)
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }

        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = player.isPlaying ? .playing : .paused
    }

    private func loadArtwork(for track: Track) {
        guard let url = Artwork.url(track.thumbnail, size: 600) else { return }
        Task {
            guard let image = await ImageLoader.shared.image(for: url), artworkVideoId == track.videoId else { return }
            artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            publish()
        }
    }
}
