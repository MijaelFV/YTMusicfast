import AppKit
import SwiftUI

/// The menu-bar item: click for the mini player, right-click (or ⌃-click) for quick actions.
/// Optionally shows what's playing next to the icon. Off and on in Settings → General.
@MainActor
final class StatusBarController: NSObject {
    static let shared = StatusBarController()

    static let showIconKey = "menuBar.showIcon"
    static let showTitleKey = "menuBar.showTitle"

    private var item: NSStatusItem?
    private var symbol: String?
    private lazy var popover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = NSHostingController(rootView: MiniPlayerView()
            .environment(Router.shared)
            .environment(AuthManager.shared)
            .preferredColorScheme(.dark))
        return popover
    }()

    /// Opens (or re-opens) the main window; set by the main scene, which owns `openWindow`.
    static var openMainWindow: (() -> Void)?

    private var showIcon: Bool { UserDefaults.standard.object(forKey: Self.showIconKey) as? Bool ?? true }
    private var showTitle: Bool { UserDefaults.standard.bool(forKey: Self.showTitleKey) }

    func start() {
        update()
        observePlayer()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { StatusBarController.shared.update() }
        }
    }

    /// Redraws whenever the song or play state changes.
    private func observePlayer() {
        withObservationTracking {
            _ = PlayerController.shared.current
            _ = PlayerController.shared.isPlaying
        } onChange: {
            Task { @MainActor in
                StatusBarController.shared.update()
                StatusBarController.shared.observePlayer()
            }
        }
    }

    private func update() {
        guard showIcon else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            symbol = nil
            return
        }
        let item = self.item ?? makeItem()
        guard let button = item.button else { return }
        let player = PlayerController.shared
        // A waveform while music plays, a note when paused or idle.
        let symbol = player.isPlaying ? "waveform" : "music.note"
        if symbol != self.symbol {
            self.symbol = symbol
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "YT Musicfast")
            image?.isTemplate = true
            button.image = image
        }
        let title: String
        if showTitle, let track = player.current {
            title = " " + Self.truncate("\(track.title) — \(track.artistLine)", to: 38)
        } else {
            title = ""
        }
        if button.title != title { button.title = title }
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        button.toolTip = player.current.map { "\($0.title) — \($0.artistLine)" } ?? "YT Musicfast"
    }

    private func makeItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(clicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.setAccessibilityLabel("YT Musicfast")
        self.item = item
        return item
    }

    static func truncate(_ text: String, to length: Int) -> String {
        text.count > length ? String(text.prefix(length - 1)).trimmingCharacters(in: .whitespaces) + "…" : text
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            popover.performClose(nil)
            showMenu(from: sender)
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showMenu(from button: NSStatusBarButton) {
        let player = PlayerController.shared
        let menu = NSMenu()
        if let track = player.current {
            let info = NSMenuItem(title: "\(track.title) — \(track.artistLine)", action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
            menu.addItem(.separator())
            menu.addItem(StatusMenuItem(player.isPlaying ? String(localized: "Pause") : String(localized: "Play"),
                                         symbol: player.isPlaying ? "pause.fill" : "play.fill") { player.togglePlayPause() })
            menu.addItem(StatusMenuItem(String(localized: "Next"), symbol: "forward.fill") { player.next() })
            menu.addItem(StatusMenuItem(String(localized: "Previous"), symbol: "backward.fill") { player.previous() })
            if !track.isLocal {
                let liked = player.isLiked(track)
                menu.addItem(StatusMenuItem(liked ? String(localized: "Remove like") : String(localized: "Like"),
                                             symbol: liked ? "heart.fill" : "heart") { player.toggleLike() })
            }
            menu.addItem(.separator())
        }
        menu.addItem(StatusMenuItem(String(localized: "Open YT Musicfast"), symbol: "macwindow") { Self.showMainWindow() })
        menu.addItem(StatusMenuItem(String(localized: "Hide Menu Bar Icon"), symbol: "eye.slash") {
            UserDefaults.standard.set(false, forKey: Self.showIconKey)
        })
        menu.addItem(.separator())
        menu.addItem(StatusMenuItem(String(localized: "Quit YT Musicfast"), symbol: nil) { NSApp.terminate(nil) })
        // Attach the menu just for this click so it opens like any menu-bar menu, then detach it
        // so a normal click shows the mini player again.
        item?.menu = menu
        button.performClick(nil)
        item?.menu = nil
    }

    static func showMainWindow() {
        shared.popover.performClose(nil)
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.title == "YT Musicfast" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }
}

/// An NSMenuItem that runs a closure.
final class StatusMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String?, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { MainActor.assumeIsolated { handler() } }
}
