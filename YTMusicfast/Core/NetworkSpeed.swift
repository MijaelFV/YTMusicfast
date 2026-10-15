import Foundation

/// How fast YouTube's audio has been arriving lately — to choose between downloading a song whole
/// before it plays (needed for the equalizer and crossfade; about a second on a normal
/// connection) and streaming it piece by piece (starts sooner on a slow one). Also whether macOS
/// is in Low Data Mode, which switches to the smaller data-saver stream.
final class NetworkSpeed: @unchecked Sendable {
    static let shared = NetworkSpeed()

    init() {}
    private let lock = NSLock()
    private var bytesPerSecond: Double?
    private var constrained = false

    /// One finished download: bytes over seconds, on one of the (up to three) connections.
    func record(bytes: Int, seconds: TimeInterval) {
        guard bytes >= 64 * 1024, seconds > 0.01 else { return }
        let rate = Double(bytes) / seconds
        lock.withLock { bytesPerSecond = bytesPerSecond.map { $0 * 0.6 + rate * 0.4 } ?? rate }
    }

    /// The network changed (another Wi-Fi, a hotspot): measure afresh.
    func networkChanged(lowDataMode: Bool) {
        lock.withLock {
            bytesPerSecond = nil
            constrained = lowDataMode
        }
    }

    var isLowDataMode: Bool { lock.withLock { constrained } }

    /// Whether downloading `length` bytes whole would keep you waiting more than a few seconds.
    func isSlow(for length: Int) -> Bool {
        lock.withLock {
            guard let bytesPerSecond else { return false }
            return Double(length) / (bytesPerSecond * 3) > 6
        }
    }
}

