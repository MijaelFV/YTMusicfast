import AppKit
import SwiftUI

/// The notch widget: on Macs with a notch, while YT Musicfast is in the background (or its
/// window is closed or minimized), a small Now Playing island sits around the notch — the cover on
/// the left, a playing indicator on the right. Hover it for the song, a seek bar and controls.
///
/// Off by default (Settings → General). The panel exists only while it's showing: it's built when
/// the app goes to the background and released when it comes back.
@MainActor
final class NotchPlayer {
    static let shared = NotchPlayer()
    static let key = "notchPlayer"

    private var panel: NSPanel?
    private var observers: [NSObjectProtocol] = []
    private var watchingPlayer = false

    private var enabled: Bool { UserDefaults.standard.bool(forKey: Self.key) }

    /// A Mac with a notch: the screen the main window is on, else the built-in display.
    static var notchScreen: NSScreen? {
        let main = NSApp.windows.first { $0.title == "YT Musicfast" }?.screen
        if let main, main.safeAreaInsets.top > 0 { return main }
        return NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }

    static var hasNotch: Bool { NSScreen.screens.contains { $0.safeAreaInsets.top > 0 } }

    func start() {
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NotchPlayer.shared.enabledChanged() }
        }
        enabledChanged()
    }

    private func enabledChanged() {
        if enabled, observers.isEmpty {
            let center = NotificationCenter.default
            let names: [Notification.Name] = [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                                              NSApplication.didChangeScreenParametersNotification, NSWindow.didMiniaturizeNotification,
                                              NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification]
            observers = names.map { name in
                center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    // After the window has actually closed or moved.
                    Task { @MainActor in NotchPlayer.shared.update() }
                }
            }
            watchPlayer()
            update()
        } else if !enabled, !observers.isEmpty {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            hide()
        }
    }

    /// Shows or hides the island when the song starts or stops.
    private func watchPlayer() {
        guard !watchingPlayer else { return }
        watchingPlayer = true
        withObservationTracking {
            _ = PlayerController.shared.current == nil
        } onChange: {
            Task { @MainActor in
                NotchPlayer.shared.watchingPlayer = false
                guard NotchPlayer.shared.enabled else { return }
                NotchPlayer.shared.update()
                NotchPlayer.shared.watchPlayer()
            }
        }
    }

    private var shouldShow: Bool {
        guard enabled, PlayerController.shared.current != nil, Self.notchScreen != nil else { return false }
        let main = NSApp.windows.first { $0.title == "YT Musicfast" }
        let windowShowing = main.map { $0.isVisible && !$0.isMiniaturized } ?? false
        return !NSApp.isActive || !windowShowing
    }

    private func update() {
        if shouldShow { show() } else { hide() }
    }

    private func show() {
        guard let screen = Self.notchScreen else { return }
        let geometry = NotchGeometry(screen: screen)
        if panel == nil {
            let panel = NSPanel(contentRect: geometry.panelFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            // Black like the notch, whatever the appearance.
            panel.appearance = NSAppearance(named: .darkAqua)
            // Takes the first click: the panel never becomes key, so a plain hosting view would
            // spend a click on the controls just "activating" it.
            panel.contentView = MenuHostingView(rootView: NotchIsland(geometry: geometry)
                .environment(Router.shared)
                .environment(AuthManager.shared)
                .preferredColorScheme(.dark))
            self.panel = panel
        }
        panel?.setFrame(geometry.panelFrame, display: false)
        panel?.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }
}

/// Where the notch is on a screen, and the panel around it.
struct NotchGeometry: Equatable {
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var panelFrame: CGRect

    static let expandedSize = CGSize(width: 400, height: 150)

    init(screen: NSScreen) {
        let frame = screen.frame
        notchHeight = screen.safeAreaInsets.top
        let left = screen.auxiliaryTopLeftArea?.width ?? frame.width / 2 - 100
        let right = screen.auxiliaryTopRightArea?.width ?? frame.width / 2 - 100
        notchWidth = max(120, frame.width - left - right)
        let width = max(Self.expandedSize.width, notchWidth + 120)
        let height = notchHeight + Self.expandedSize.height
        let centerX = frame.minX + left + notchWidth / 2
        panelFrame = CGRect(x: (centerX - width / 2).rounded(), y: frame.maxY - height, width: width, height: height)
    }
}

/// The black island: notch-sized with "ears" when collapsed, a small player when hovered.
private struct NotchIsland: View {
    let geometry: NotchGeometry
    @State private var expanded = false
    private var player: PlayerController { .shared }

    private var ear: CGFloat { geometry.notchHeight + 8 }

    private var collapsedSize: CGSize { CGSize(width: geometry.notchWidth + ear * 2, height: geometry.notchHeight) }
    private var expandedSize: CGSize {
        CGSize(width: NotchGeometry.expandedSize.width, height: geometry.notchHeight + NotchGeometry.expandedSize.height - 12)
    }

    var body: some View {
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: expanded ? 22 : 12, bottomTrailingRadius: expanded ? 22 : 12, style: .continuous)
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if expanded {
                    expandedContent
                        .transition(.opacity.animation(.easeOut(duration: 0.2).delay(0.08)))
                } else {
                    collapsedContent
                        .transition(.opacity.animation(.easeOut(duration: 0.12)))
                }
            }
            .frame(width: expanded ? expandedSize.width : collapsedSize.width,
                   height: expanded ? expandedSize.height : collapsedSize.height,
                   alignment: .top)
            .background(shape.fill(.black))
            // Nothing draws outside the black while it grows or shrinks.
            .clipShape(shape)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Fixed hover zones (not the animating shape, whose moving edge used to fire enter/leave
        // over and over while it grew — the flicker).
        .background(IslandHover(collapsed: collapsedSize, expanded: expandedSize,
                                onEnter: { setExpanded(true) }, onLeave: { setExpanded(false) }))
    }

    private func setExpanded(_ value: Bool) {
        guard value != expanded else { return }
        withAnimation(value ? .spring(duration: 0.38, bounce: 0.12) : .spring(duration: 0.3, bounce: 0)) { expanded = value }
    }

    private var collapsedContent: some View {
        HStack(spacing: 0) {
            ArtworkView(url: player.current?.thumbnail, size: geometry.notchHeight - 10, cornerRadius: 4)
                .frame(width: ear)
            Spacer(minLength: geometry.notchWidth)
            EqualizerBars(animating: player.isPlaying)
                .frame(width: ear)
        }
        .frame(height: geometry.notchHeight)
    }

    private var expandedContent: some View {
        VStack(spacing: 10) {
            Color.clear.frame(height: geometry.notchHeight - 6)
            if let track = player.current {
                HStack(spacing: 12) {
                    ArtworkView(url: track.thumbnail, size: 48, cornerRadius: 6)
                        .onTapGesture { StatusBarController.showMainWindow() }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Text(track.artistLine).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    LikeButton(size: 16)
                    MenuButton(alignment: .trailing, entries: ConnectMenu.entries) { highlighted in
                        Image(systemName: "hifispeaker.2")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(highlighted ? Theme.text : Theme.secondary)
                            .frame(width: 31, height: 31)
                            .contentShape(Rectangle())
                    }
                }
                ProgressScrubber()
                TransportControls(size: .regular)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .foregroundStyle(Theme.text)
    }
}

/// The island's hover, from two fixed areas centred at the top of the panel: entering the small
/// island opens it; leaving the open island's area closes it — after a moment, and only once the
/// pointer really is outside, no menu from it is open and no button is held (dragging the seek
/// bar past the edge mustn't close it).
private struct IslandHover: NSViewRepresentable {
    var collapsed: CGSize
    var expanded: CGSize
    var onEnter: () -> Void
    var onLeave: () -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        update(view)
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) { update(view) }

    private func update(_ view: TrackingView) {
        view.collapsed = collapsed
        view.expanded = expanded
        view.onEnter = onEnter
        view.onLeave = onLeave
    }

    final class TrackingView: NSView {
        var collapsed: CGSize = .zero { didSet { if collapsed != oldValue { needsUpdateTracking() } } }
        var expanded: CGSize = .zero { didSet { if expanded != oldValue { needsUpdateTracking() } } }
        var onEnter: (() -> Void)?
        var onLeave: (() -> Void)?
        private var leaveCheck: Timer?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func rect(_ size: CGSize) -> NSRect {
            NSRect(x: (bounds.width - size.width) / 2, y: 0, width: size.width, height: size.height)
        }

        private func needsUpdateTracking() { updateTrackingAreas() }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            guard collapsed.width > 0 else { return }
            addTrackingArea(NSTrackingArea(rect: rect(collapsed), options: [.mouseEnteredAndExited, .activeAlways],
                                           owner: self, userInfo: ["area": "collapsed"]))
            addTrackingArea(NSTrackingArea(rect: rect(expanded), options: [.mouseEnteredAndExited, .activeAlways],
                                           owner: self, userInfo: ["area": "expanded"]))
        }

        override func mouseEntered(with event: NSEvent) {
            guard event.trackingArea?.userInfo?["area"] as? String == "collapsed" else { return }
            leaveCheck?.invalidate()
            onEnter?()
        }

        override func mouseExited(with event: NSEvent) {
            guard event.trackingArea?.userInfo?["area"] as? String == "expanded" else { return }
            scheduleLeaveCheck(after: 0.15)
        }

        private func scheduleLeaveCheck(after delay: TimeInterval) {
            leaveCheck?.invalidate()
            let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkLeave() }
            }
            RunLoop.main.add(timer, forMode: .common)
            leaveCheck = timer
        }

        private func checkLeave() {
            guard let window else { return }
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            // Back inside: stay open.
            if rect(expanded).insetBy(dx: -4, dy: -4).contains(point) { return }
            // Outside, but busy with it (its menu, a drag): look again shortly.
            if NSEvent.pressedMouseButtons != 0 || MenuPresenter.shared.isOpen {
                scheduleLeaveCheck(after: 0.3)
                return
            }
            onLeave?()
        }
    }
}
