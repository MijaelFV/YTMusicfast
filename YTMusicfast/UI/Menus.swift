import AppKit
import SwiftUI

// MARK: - Menu content

/// One entry of the app's menus: right-click menus, ⋯ buttons, sort pickers, Create, account.
enum MenuEntry {
    case action(String, systemImage: String, () -> Void)
    case item(MenuItemSpec)
    /// Opens to the side on hover (or →).
    case submenu(String, systemImage: String?, [MenuEntry])
    case divider
    /// A small grey section title ("Sort by").
    case header(String)
    /// Something to read, not click (the account menu's updates note).
    case footer(AnyView)
}

/// An item with everything the menus can show: an icon (small or in a big circle), a second
/// line, a checkmark or a trailing icon, a dot, or a disabled or destructive look.
struct MenuItemSpec {
    var title: String
    var subtitle: String?
    var systemImage: String?
    /// A drawn icon instead of a symbol (the Liked Music square).
    var icon: MenuIcon?
    var largeIcon = false
    var checked = false
    var trailingImage: String?
    var dot = false
    var enabled = true
    var destructive = false
    var action: () -> Void
}

extension MenuEntry {
    static func item(_ title: String, subtitle: String? = nil, systemImage: String? = nil, largeIcon: Bool = false, checked: Bool = false,
                     trailingImage: String? = nil, dot: Bool = false, enabled: Bool = true, destructive: Bool = false,
                     action: @escaping () -> Void) -> MenuEntry {
        .item(MenuItemSpec(title: title, subtitle: subtitle, systemImage: systemImage, largeIcon: largeIcon, checked: checked,
                           trailingImage: trailingImage, dot: dot, enabled: enabled, destructive: destructive, action: action))
    }

    /// A choice in a list of options (sort order, speed…): checked when it's the current one.
    static func choice(_ title: String, systemImage: String? = nil, selected: Bool, action: @escaping () -> Void) -> MenuEntry {
        .item(title, systemImage: systemImage, checked: selected, action: action)
    }

    fileprivate var spec: MenuItemSpec? {
        switch self {
        case .action(let title, let image, let action): MenuItemSpec(title: title, systemImage: image.isEmpty ? nil : image, action: action)
        case .item(let spec): spec
        default: nil
        }
    }

    fileprivate var isSelectable: Bool {
        switch self {
        case .action: true
        case .item(let spec): spec.enabled
        case .submenu: true
        default: false
        }
    }
}

/// Icons drawn here rather than taken from a symbol set.
enum MenuIcon {
    /// The purple-to-blue square with a heart.
    case likedSongs
    /// The same square, for "Remove from Liked Music".
    case likedSongsRemove

    @ViewBuilder var view: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.27, green: 0.13, blue: 0.85), Color(red: 0.55, green: 0.85, blue: 0.85)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Image(systemName: self == .likedSongs ? "heart.fill" : "heart.slash.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(.white))
    }
}

// MARK: - Presenting

/// Shows the app's menus in floating panels above the window — at the pointer for right-clicks,
/// under the button for ⋯ and pickers. One menu (plus its open submenus) at a time.
///
/// Nothing exists while no menu is open: the panels, their event monitors and observers are made
/// when a menu opens and released when it closes.
@MainActor
@Observable
final class MenuPresenter {
    static let shared = MenuPresenter()

    /// Which button's menu is open, for buttons that look pressed while theirs is.
    private(set) var openToken: String?
    var isOpen: Bool { !levels.isEmpty }

    @ObservationIgnored private var levels: [MenuLevel] = []
    @ObservationIgnored private var anchor: NSRect?
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var submenuTimer: Timer?

    enum Alignment { case leading, trailing }

    /// A right-click menu: its top-left corner at the pointer.
    func showContextMenu(_ entries: [MenuEntry]) {
        let point = NSEvent.mouseLocation
        show(entries, place: { size, screen in
            Self.fit(NSRect(x: point.x, y: point.y - size.height, width: size.width, height: size.height),
                     in: screen, flipFrom: NSRect(origin: point, size: .zero))
        }, anchor: nil, token: nil)
    }

    /// A button's menu, under the button (or above it when there's no room).
    func toggle(_ entries: [MenuEntry], below rect: NSRect, alignment: Alignment = .leading, token: String) {
        if openToken == token { close(); return }
        show(entries, place: { size, screen in
            let x = alignment == .leading ? rect.minX : rect.maxX - size.width
            var frame = NSRect(x: x, y: rect.minY - 6 - size.height, width: size.width, height: size.height)
            if frame.minY < screen.minY { frame.origin.y = rect.maxY + 6 }
            return Self.fit(frame, in: screen, flipFrom: nil)
        }, anchor: rect, token: token)
    }

    func close() {
        submenuTimer?.invalidate()
        submenuTimer = nil
        for level in levels { level.window.orderOut(nil) }
        levels = []
        anchor = nil
        openToken = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    private func show(_ entries: [MenuEntry], place: (NSSize, NSRect) -> NSRect, anchor: NSRect?, token: String?) {
        close()
        guard !entries.isEmpty else { return }
        let level = MenuLevel(entries: entries, depth: 0, presenter: self)
        let screen = Self.screen(containing: anchor.map { NSPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation)
        level.window.setFrame(place(level.fittingSize(maxHeight: screen.height - 16), screen), display: true)
        level.window.orderFront(nil)
        levels = [level]
        self.anchor = anchor
        openToken = token
        startWatching()
        NSAccessibility.post(element: level.window, notification: .created)
    }

    // MARK: Submenus

    fileprivate func hovered(_ index: Int?, in level: MenuLevel) {
        level.highlighted = index
        submenuTimer?.invalidate()
        // Back on the row whose submenu is already open: keep it open.
        if let index, index == level.submenuIndex { return }
        // Moving onto another row of a menu closes the submenus opened from it, after a moment
        // (like macOS), so a diagonal move toward a submenu doesn't close it.
        submenuTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) { [weak self, weak level] _ in
            MainActor.assumeIsolated {
                guard let self, let level else { return }
                self.closeSubmenus(after: level)
                if let index, case .submenu = level.entries[index] { self.openSubmenu(at: index, of: level) }
            }
        }
    }

    fileprivate func openSubmenu(at index: Int, of level: MenuLevel) {
        // Only from a menu that's still open.
        guard levels.contains(where: { $0 === level }),
              case .submenu(_, _, let children) = level.entries[index], !children.isEmpty,
              let rowFrame = level.rowFrames[index] else { return }
        closeSubmenus(after: level)
        let child = MenuLevel(entries: children, depth: level.depth + 1, presenter: self)
        let screen = Self.screen(containing: NSPoint(x: level.window.frame.midX, y: level.window.frame.midY))
        let size = child.fittingSize(maxHeight: screen.height - 16)
        // Row frame is in the parent's SwiftUI space (top-left origin): to screen coordinates.
        let rowTop = level.window.frame.maxY - rowFrame.minY
        var frame = NSRect(x: level.window.frame.maxX - 4, y: rowTop - size.height + 4, width: size.width, height: size.height)
        if frame.maxX > screen.maxX { frame.origin.x = level.window.frame.minX - size.width + 4 }
        // Part of the menu before it's placed: placing it posts move/resize notices, which close
        // the menu when they come from a window that isn't one of its own.
        levels.append(child)
        level.submenuIndex = index
        child.window.setFrame(Self.fit(frame, in: screen, flipFrom: nil), display: true)
        child.window.orderFront(nil)
    }

    private func closeSubmenus(after level: MenuLevel) {
        while let last = levels.last, last.depth > level.depth {
            last.window.orderOut(nil)
            levels.removeLast()
        }
        level.submenuIndex = nil
    }

    /// The pointer left a menu: its highlight goes, unless it points at its open submenu.
    fileprivate func pointerLeft(_ level: MenuLevel) {
        level.highlighted = level.submenuIndex
    }

    fileprivate func activate(_ index: Int, in level: MenuLevel) {
        let entry = level.entries[index]
        if case .submenu = entry {
            submenuTimer?.invalidate()
            openSubmenu(at: index, of: level)
            levels.last?.highlightFirst()
            return
        }
        guard levels.contains(where: { $0 === level }), let spec = entry.spec, spec.enabled else { return }
        close()
        // After the menu is gone, so a sheet or panel the action opens isn't fighting it.
        DispatchQueue.main.async { spec.action() }
    }

    // MARK: Closing and keys

    private func startWatching() {
        let isMenuWindow: (NSWindow?) -> Bool = { $0 is MenuWindow }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, !isMenuWindow(event.window) else { return event }
                // A click on the button that opened it just closes it (instead of reopening).
                let onAnchor = self.anchor?.contains(NSEvent.mouseLocation) ?? false
                self.close()
                return onAnchor ? nil : event
            }
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { event in
            MainActor.assumeIsolated {
                // Like the system's menus: scrolling outside does nothing while a menu is open (a
                // trackpad's leftover momentum used to close it right after it opened). A long
                // menu still scrolls.
                isMenuWindow(event.window) ? event : nil
            }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handleKey(event) ?? event }
        } as Any)
        let center = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResizeNotification, NSWindow.didMoveNotification,
                     NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    // Menu windows never count, registered yet or not: a submenu's window posts a
                    // resize while it's being created, which used to close the menu it opens from.
                    guard let self, !(note.object is MenuWindow) else { return }
                    self.close()
                }
            })
        }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard let level = levels.last else { return event }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // ⌘-shortcuts still work (and close the menu), like the system's menus.
        if flags.contains(.command) { close(); return event }
        switch event.keyCode {
        case 125: level.moveHighlight(by: 1)
        case 126: level.moveHighlight(by: -1)
        case 124:
            if let index = level.highlighted, case .submenu = level.entries[index] { activate(index, in: level) }
        case 123, 53:
            if levels.count > 1 {
                level.window.orderOut(nil)
                levels.removeLast()
                levels.last?.submenuIndex = nil
            } else {
                close()
            }
        case 36, 76, 49:
            if let index = level.highlighted { activate(index, in: level) }
        default:
            // Type to jump to an item starting with that letter.
            if let typed = event.charactersIgnoringModifiers?.lowercased(), typed.count == 1 { level.jump(to: typed) }
        }
        return nil
    }

    // MARK: Geometry

    private static func screen(containing point: NSPoint) -> NSRect {
        (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// Keeps a menu on screen: flips it to the other side of the pointer when it would run off.
    private static func fit(_ frame: NSRect, in screen: NSRect, flipFrom point: NSRect?) -> NSRect {
        var frame = frame
        if frame.maxX > screen.maxX - 4 {
            frame.origin.x = point.map { $0.minX - frame.width } ?? (screen.maxX - 4 - frame.width)
        }
        if frame.minY < screen.minY + 4 {
            frame.origin.y = point.map { $0.minY } ?? (screen.minY + 4)
        }
        frame.origin.x = max(screen.minX + 4, frame.origin.x)
        frame.origin.y = min(max(screen.minY + 4, frame.origin.y), screen.maxY - 4 - frame.height)
        return frame.integral
    }
}

/// One open menu (the menu itself, or a submenu): its entries, highlight and panel.
@MainActor
@Observable
final class MenuLevel {
    let entries: [MenuEntry]
    let depth: Int
    var highlighted: Int?
    /// The row whose submenu is open (it stays highlighted while you're in the submenu).
    var submenuIndex: Int?
    /// Each row's frame in the menu, for placing its submenu.
    @ObservationIgnored var rowFrames: [Int: CGRect] = [:]
    @ObservationIgnored private(set) var window: MenuWindow!
    @ObservationIgnored private weak var presenter: MenuPresenter?
    @ObservationIgnored private var hosting: MenuHostingView<MenuListView>!

    init(entries: [MenuEntry], depth: Int, presenter: MenuPresenter) {
        self.entries = entries
        self.depth = depth
        self.presenter = presenter
        hosting = MenuHostingView(rootView: MenuListView(level: self))
        window = MenuWindow(content: hosting)
    }

    func fittingSize(maxHeight: CGFloat) -> NSSize {
        let size = hosting.fittingSize
        return NSSize(width: min(max(size.width, 200), 420), height: min(size.height, maxHeight))
    }

    func hover(_ index: Int?) { presenter?.hovered(index, in: self) }
    func pointerLeft() { presenter?.pointerLeft(self) }
    func activate(_ index: Int) { presenter?.activate(index, in: self) }

    func highlightFirst() { highlighted = entries.indices.first { entries[$0].isSelectable } }

    func moveHighlight(by step: Int) {
        let selectable = entries.indices.filter { entries[$0].isSelectable }
        guard !selectable.isEmpty else { return }
        guard let current = highlighted, let position = selectable.firstIndex(of: current) else {
            highlighted = step > 0 ? selectable.first : selectable.last
            return
        }
        highlighted = selectable[(position + step + selectable.count) % selectable.count]
    }

    func jump(to letter: String) {
        let start = (highlighted ?? -1) + 1
        let order = Array(entries.indices.dropFirst(start)) + Array(entries.indices.prefix(start))
        highlighted = order.first { index in
            guard entries[index].isSelectable else { return false }
            switch entries[index] {
            case .submenu(let title, _, _): return title.lowercased().hasPrefix(letter)
            default: return entries[index].spec?.title.lowercased().hasPrefix(letter) ?? false
            }
        } ?? highlighted
    }
}

/// A borderless panel that floats above the window without taking focus from it (the window keeps
/// looking active, like with the system's menus).
final class MenuWindow: NSPanel {
    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        contentView = content
        setAccessibilityRole(.menu)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Takes the first click even though its window isn't key.
final class MenuHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Drawing

struct MenuListView: View {
    let level: MenuLevel

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(level.entries.enumerated()), id: \.offset) { index, entry in
                    row(index, entry)
                }
            }
            // At least the menu's minimum width, so short menus' rows still reach across.
            .frame(minWidth: 192, alignment: .leading)
            .padding(4)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.automatic)
        .fixedSize(horizontal: true, vertical: false)
        .frame(minWidth: 200, maxWidth: 420, alignment: .leading)
        .background(Theme.menu, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .coordinateSpace(.named("menu"))
        .background(MenuHoverTracker { inside in if !inside { level.pointerLeft() } })
    }

    @ViewBuilder
    private func row(_ index: Int, _ entry: MenuEntry) -> some View {
        switch entry {
        case .divider:
            Rectangle().fill(Theme.text.opacity(0.1)).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 8)
        case .header(let title):
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 12)
                .padding(.top, index == 0 ? 8 : 10)
                .padding(.bottom, 4)
        case .footer(let view):
            view
        case .submenu(let title, let image, _):
            MenuRowView(spec: MenuItemSpec(title: title, systemImage: image?.isEmpty == false ? image : nil, action: {}), isSubmenu: true,
                        highlighted: level.highlighted == index)
                .modifier(MenuRowBehavior(level: level, index: index))
        case .action, .item:
            if let spec = entry.spec {
                MenuRowView(spec: spec, isSubmenu: false, highlighted: level.highlighted == index && spec.enabled)
                    .modifier(MenuRowBehavior(level: level, index: index))
                    .disabled(!spec.enabled)
            }
        }
    }
}

private struct MenuRowBehavior: ViewModifier {
    let level: MenuLevel
    let index: Int

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            // An AppKit tracking area: the menu's panel is never the key window, and this works
            // regardless.
            .background(MenuHoverTracker { inside in if inside { level.hover(index) } })
            .onTapGesture { level.activate(index) }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("menu")) } action: { level.rowFrames[index] = $0 }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { level.activate(index) }
    }
}

private struct MenuRowView: View {
    let spec: MenuItemSpec
    let isSubmenu: Bool
    let highlighted: Bool

    var body: some View {
        HStack(spacing: spec.largeIcon ? 14 : 12) {
            if let icon = spec.icon {
                icon.view.frame(width: 18, height: 18)
            } else if let image = spec.systemImage {
                Image(systemName: image)
                    .font(.system(size: spec.largeIcon ? 18 : 14, weight: .medium))
                    .frame(width: spec.largeIcon ? 46 : 18, height: spec.largeIcon ? 46 : 18)
                    .background { if spec.largeIcon { Circle().fill(Theme.text.opacity(0.1)) } }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(spec.title)
                    .font(.system(size: 14, weight: spec.largeIcon ? .bold : .regular))
                    .foregroundStyle(spec.destructive ? Color.red : spec.checked ? Theme.accent : Theme.text)
                if let subtitle = spec.subtitle {
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 24)
            if spec.dot { Circle().fill(Color.blue).frame(width: 7, height: 7) }
            if spec.checked {
                Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.accent)
            } else if let trailing = spec.trailingImage {
                Image(systemName: trailing).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
            }
            if isSubmenu {
                Image(systemName: "arrowtriangle.right.fill").font(.system(size: 9)).foregroundStyle(Theme.text)
            }
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 12)
        .padding(.vertical, spec.largeIcon ? 8 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 3).fill(highlighted ? Theme.text.opacity(0.1) : .clear))
        .opacity(spec.enabled ? 1 : 0.4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spec.subtitle.map { "\(spec.title), \($0)" } ?? spec.title)
        .accessibilityAddTraits(spec.checked ? .isSelected : [])
    }
}

/// Enter/exit for a menu row, from an AppKit tracking area that works in any window.
private struct MenuHoverTracker: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) { view.onChange = onChange }

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }

        override func mouseEntered(with event: NSEvent) { onChange?(true) }
        override func mouseExited(with event: NSEvent) { onChange?(false) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// MARK: - Buttons and right-clicks

/// A button that opens a menu under itself. Looks pressed while its menu is open.
struct MenuButton<Label: View>: View {
    var alignment: MenuPresenter.Alignment = .leading
    var entries: () -> [MenuEntry]
    /// `open`: its menu is showing; `hovering`: the pointer is over it (brighten, like IconButton).
    @ViewBuilder var label: (_ open: Bool, _ hovering: Bool) -> Label
    @State private var token = UUID().uuidString
    @State private var anchor = ViewAnchor()
    @State private var hovering = false
    /// Bumped to open (or close) the menu without a click: the full screen player's remote keys.
    var openSignal = 0

    init(alignment: MenuPresenter.Alignment = .leading, entries: @escaping () -> [MenuEntry],
         @ViewBuilder label: @escaping (_ open: Bool, _ hovering: Bool) -> Label) {
        self.alignment = alignment
        self.entries = entries
        self.label = label
    }

    /// A label that only cares whether the menu is open (it brightens on hover too: `highlighted`).
    init(alignment: MenuPresenter.Alignment = .leading, entries: @escaping () -> [MenuEntry],
         @ViewBuilder label: @escaping (_ highlighted: Bool) -> Label) {
        self.init(alignment: alignment, entries: entries) { open, hovering in label(open || hovering) }
    }

    /// Opens on `signal` changing (see `openSignal`).
    func opening(on signal: Int) -> Self {
        var copy = self
        copy.openSignal = signal
        return copy
    }

    var body: some View {
        Button(action: toggle) {
            label(MenuPresenter.shared.openToken == token, hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .background(ViewAnchorView(anchor: anchor))
        .onChange(of: openSignal) { toggle() }
    }

    private func toggle() {
        guard let rect = anchor.screenRect else { return }
        MenuPresenter.shared.toggle(entries(), below: rect, alignment: alignment, token: token)
    }
}

extension MenuButton where Label == AnyView {
    /// The ⋯ "More options" button.
    static func more(size: CGFloat = 16, color: Color = Theme.secondary, alignment: MenuPresenter.Alignment = .leading,
                     entries: @escaping () -> [MenuEntry]) -> MenuButton<AnyView> {
        MenuButton(alignment: alignment, entries: entries) { open, hovering in
            AnyView(Image(systemName: "ellipsis")
                .font(.system(size: size, weight: .bold))
                // Brightens on hover and while open, like the other icon buttons.
                .foregroundStyle(open || hovering ? (color == Theme.secondary ? Theme.text : color) : color.opacity(color == Theme.secondary ? 1 : 0.75))
                .frame(width: size + 14, height: size + 14)
                .contentShape(Rectangle())
                .accessibilityLabel("More options"))
        }
    }
}

/// Where a SwiftUI view is on screen, read when needed (a menu opening under it).
@MainActor
final class ViewAnchor {
    weak var view: NSView?

    var screenRect: NSRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

private struct ViewAnchorView: NSViewRepresentable {
    let anchor: ViewAnchor

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }

    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Right-click menus. Rows and cards register what their menu would be while the pointer is over
/// them (they already track hovering); a right-click (or ⌃-click) then shows the innermost one.
/// Text fields keep the system's Cut/Copy/Paste menu.
@MainActor
enum ContextMenus {
    private static var stack: [(id: UUID, entries: () -> [MenuEntry])] = []
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            MainActor.assumeIsolated { handle(event) }
        }
    }

    static func register(_ id: UUID, _ entries: @escaping () -> [MenuEntry]) {
        stack.removeAll { $0.id == id }
        stack.append((id, entries))
    }

    static func unregister(_ id: UUID) { stack.removeAll { $0.id == id } }

    private static func handle(_ event: NSEvent) -> NSEvent? {
        let isRightClick = event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control)
        guard isRightClick, let window = event.window, ["YT Musicfast", "Miniplayer"].contains(window.title),
              let provider = stack.last, !isOverText(event, in: window) else { return event }
        let entries = provider.entries()
        guard !entries.isEmpty else { return event }
        MenuPresenter.shared.showContextMenu(entries)
        return nil
    }

    /// Text fields and text views keep their own menu.
    private static func isOverText(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard let content = window.contentView else { return false }
        var view = content.hitTest(content.convert(event.locationInWindow, from: nil))
        while let current = view {
            if current is NSText || current is NSTextField { return true }
            view = current.superview
        }
        return false
    }
}

private struct ContextMenuRegion: ViewModifier {
    var active: Bool?
    var entries: () -> [MenuEntry]
    @State private var id = UUID()
    @State private var hovering = false

    func body(content: Content) -> some View {
        Group {
            if active == nil {
                // Tracks hovering itself (views that don't already).
                content.onHover { inside in
                    hovering = inside
                    update(inside)
                }
            } else {
                content.onChange(of: active) { _, inside in update(inside == true) }
            }
        }
        .onDisappear { ContextMenus.unregister(id) }
        .accessibilityAction(named: Text("Show Menu")) { MenuPresenter.shared.showContextMenu(entries()) }
    }

    private func update(_ inside: Bool) {
        if inside { ContextMenus.register(id, entries) } else { ContextMenus.unregister(id) }
    }
}

extension View {
    /// A right-click menu for a row or card that already tracks `hovering`.
    func menuOnRightClick(hovering: Bool, _ entries: @escaping () -> [MenuEntry]) -> some View {
        modifier(ContextMenuRegion(active: hovering, entries: entries))
    }

    /// A right-click menu (tracks hovering itself).
    func menuOnRightClick(_ entries: @escaping () -> [MenuEntry]) -> some View {
        modifier(ContextMenuRegion(active: nil, entries: entries))
    }
}
