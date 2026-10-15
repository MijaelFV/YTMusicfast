import SwiftUI

/// One design system for the whole app: a layout of rounded panels — on black in
/// the dark appearance (the default), on light grey in the light one. Every colour here follows
/// the appearance chosen in Settings (or the system's).
enum Theme {
    static let window = dynamic(dark: NSColor.black, light: NSColor(white: 0.91, alpha: 1))
    static let panel = dynamic(dark: NSColor(white: 0.071, alpha: 1), light: .white)              // #121212
    static let elevated = dynamic(dark: NSColor(white: 0.12, alpha: 1), light: NSColor(white: 0.945, alpha: 1))  // cards, menus
    /// A step above `elevated`: hovered buttons, popovers, the search field while focused.
    static let raised = dynamic(dark: NSColor(white: 0.16, alpha: 1), light: NSColor(white: 0.9, alpha: 1))
    /// Menus (#282828).
    static let menu = dynamic(dark: NSColor(white: 0.157, alpha: 1), light: .white)
    static let hover = dynamic(dark: NSColor(white: 1, alpha: 0.07), light: NSColor(white: 0, alpha: 0.05))
    static let selected = dynamic(dark: NSColor(white: 1, alpha: 0.12), light: NSColor(white: 0, alpha: 0.08))
    static let chip = dynamic(dark: NSColor(white: 1, alpha: 0.08), light: NSColor(white: 0, alpha: 0.06))

    static let text = dynamic(dark: .white, light: NSColor(white: 0.07, alpha: 1))
    static let secondary = dynamic(dark: NSColor(white: 0.70, alpha: 1), light: NSColor(white: 0.38, alpha: 1))  // #B3B3B3
    static let tertiary = dynamic(dark: NSColor(white: 0.45, alpha: 1), light: NSColor(white: 0.62, alpha: 1))
    /// The strongest fill (the play button, primary pills): white on dark, near-black on light.
    static let contrast = dynamic(dark: .white, light: NSColor(white: 0.07, alpha: 1))
    /// Text and glyphs on `contrast`.
    static let onContrast = dynamic(dark: .black, light: .white)
    /// What tinted headers fade into: black on dark, white on light.
    static let shade = dynamic(dark: .black, light: .white)

    static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static let accent = Color.brand
    static let radius: CGFloat = 8
    static let gap: CGFloat = 8
    static let pagePadding: CGFloat = 24
}

private struct PlayContextKey: EnvironmentKey {
    static let defaultValue: BrowseTarget? = nil
}

private struct SearchOriginKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The page a track list belongs to, so playback knows what it's "playing from".
    var playContext: BrowseTarget? {
        get { self[PlayContextKey.self] }
        set { self[PlayContextKey.self] = newValue }
    }

    /// Inside Search's results: what's opened or played is kept in Recent searches.
    var searchOrigin: Bool {
        get { self[SearchOriginKey.self] }
        set { self[SearchOriginKey.self] = newValue }
    }
}

extension Color {
    static let brand = Color(red: 1.0, green: 0.17, blue: 0.33)

    /// Artwork colour tuned for page header gradients: averaged artwork colours are muddy,
    /// so push saturation up and keep brightness in a range where the text reads well — white
    /// text on a deep tint in the dark appearance, dark text on a pastel one in the light.
    func headerTint() -> Color {
        guard let color = NSColor(self).usingColorSpace(.deviceRGB) else { return self }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let saturation = s < 0.08 ? s : min(0.85, max(0.45, s * 1.7))
        let brightness = min(0.62, max(0.32, b))
        let dark = NSColor(hue: h, saturation: saturation, brightness: brightness, alpha: 1)
        let light = NSColor(hue: h, saturation: s < 0.08 ? s : min(0.45, max(0.22, s)), brightness: 0.93, alpha: 1)
        return Theme.dynamic(dark: dark, light: light)
    }
}

// MARK: - Panels & rows

extension View {
    /// A rounded content panel floating on the black window.
    func panel() -> some View {
        background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }

    /// Standard hover/selection background for list rows.
    func rowBackground(hovering: Bool, selected: Bool = false) -> some View {
        background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Theme.selected : hovering ? Theme.hover : .clear)
        )
    }
}

// MARK: - Tooltips (a dark bubble instead of the system tooltip)

/// A tooltip waiting to be drawn by the window's tooltip layer.
struct TooltipRequest: Equatable {
    var text: String
    var anchor: CGRect
    var edge: VerticalEdge
}

private struct TooltipHostKey: EnvironmentKey {
    static let defaultValue = false
}

private struct InTitleBarKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside a window that draws `TooltipLayer`; elsewhere tooltips fall back to the system's.
    var hasTooltipLayer: Bool {
        get { self[TooltipHostKey.self] }
        set { self[TooltipHostKey.self] = newValue }
    }

    /// Inside the top bar, under the transparent title bar, where SwiftUI gets no hover events.
    var inTitleBar: Bool {
        get { self[InTitleBarKey.self] }
        set { self[InTitleBarKey.self] = newValue }
    }
}

struct Tooltip: ViewModifier {
    var text: String
    var edge: VerticalEdge
    @State private var hovering = false
    @State private var frame: CGRect = .zero
    @Environment(\.hasTooltipLayer) private var hasLayer
    @Environment(\.inTitleBar) private var inTitleBar
    @Environment(Router.self) private var router

    func body(content: Content) -> some View {
        if hasLayer {
            content
                // Position only while hovered: inside a scrolling page it changes every frame,
                // and tracking it all the time cost each such button an update per frame.
                .background {
                    if hovering {
                        Color.clear
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("window")) } action: { frame = $0 }
                    }
                }
                // The title bar needs an AppKit tracking area; everywhere else SwiftUI's own hover
                // is cheaper (tracking areas inside scrolling content are recomputed every frame).
                .onHover(tracking: inTitleBar) { h in
                    hovering = h
                    if h {
                        Task {
                            try? await Task.sleep(for: .milliseconds(550))
                            if hovering { router.tooltip = TooltipRequest(text: text, anchor: frame, edge: edge) }
                        }
                    } else if router.tooltip?.anchor == frame {
                        router.tooltip = nil
                    }
                }
                .onDisappear { if router.tooltip?.anchor == frame { router.tooltip = nil } }
                .simultaneousGesture(TapGesture().onEnded { router.tooltip = nil })
        } else {
            content.help(text)
        }
    }
}

/// Top-bar buttons: grow a little on hover, shrink while pressed.
struct HoverScaleButtonStyle: ButtonStyle {
    var hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : hovering ? 1.04 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Reports the pointer entering and leaving its frame. Never takes clicks.
private struct HoverTracker: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onChange = onChange
    }

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        }

        override func mouseEntered(with event: NSEvent) { onChange?(true) }
        override func mouseExited(with event: NSEvent) { onChange?(false) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Draws the current tooltip above everything, kept inside the window.
struct TooltipLayer: View {
    @Environment(Router.self) private var router

    var body: some View {
        GeometryReader { geo in
            if let tip = router.tooltip {
                let halfWidth = min(CGFloat(tip.text.count) * 3.6 + 10, 160)
                let x = min(max(tip.anchor.midX, halfWidth + 6), geo.size.width - halfWidth - 6)
                let y = tip.edge == .top ? tip.anchor.minY - 20 : tip.anchor.maxY + 20
                Text(tip.text)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.raised))
                    .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
                    .fixedSize()
                    .position(x: x, y: max(14, y))
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.1), value: router.tooltip)
    }
}

extension View {
    /// `onHover` that also works in the top bar: the transparent title bar above it swallows
    /// SwiftUI's hover events there, but an AppKit tracking area still fires.
    func onTrackingHover(_ action: @escaping (Bool) -> Void) -> some View {
        // Out of hit-testing, or AppKit treats a click there as the start of a window drag.
        background(HoverTracker(onChange: action).allowsHitTesting(false))
    }

    /// Two-stage hover for rows and cards. `hovering` follows the pointer at once (the cheap
    /// highlight); `engaged` turns on only after it rests ~90 ms. Links, buttons and menus use
    /// `engaged`, so rows sliding under a still pointer while scrolling never build them.
    func onHover(_ hovering: Binding<Bool>, engaged: Binding<Bool>) -> some View {
        onHover { inside in
            hovering.wrappedValue = inside
            if inside {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(90))
                    if hovering.wrappedValue { engaged.wrappedValue = true }
                }
            } else {
                engaged.wrappedValue = false
            }
        }
    }

    @ViewBuilder
    func onHover(tracking: Bool, perform action: @escaping (Bool) -> Void) -> some View {
        if tracking { onTrackingHover(action) } else { onHover(perform: action) }
    }

    /// Small dark label shown after hovering for a moment.
    func tooltip(_ text: String, edge: VerticalEdge = .top) -> some View {
        modifier(Tooltip(text: text, edge: edge))
    }
}

// MARK: - Controls

/// The big round accent play button.
struct PlayCircleButton: View {
    var size: CGFloat = 52
    var isPlaying = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            PlayPauseGlyph(isPlaying: isPlaying, diameter: size)
                .foregroundStyle(.black)
                .frame(width: size, height: size)
                .background(Circle().fill(Theme.accent))
                .scaleEffect(hovering ? 1.05 : 1)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(duration: 0.2), value: hovering)
        .accessibilityLabel(isPlaying ? String(localized: "Pause") : String(localized: "Play"))
    }
}

/// Play/pause for round buttons. Sized from the glyph's own shape (as text it sat a pixel low),
/// and the triangle nudged right a little so its visual weight, not its box, is centred.
struct PlayPauseGlyph: View {
    var isPlaying: Bool
    var diameter: CGFloat

    var body: some View {
        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            .resizable()
            .scaledToFit()
            .frame(width: diameter * 0.34, height: diameter * 0.34)
            .offset(x: isPlaying ? 0 : diameter * 0.025)
            .contentTransition(.symbolEffect(.replace))
    }
}

/// Secondary icon button used in action bars and the player (dims until hovered).
struct IconButton: View {
    var systemImage: String
    var size: CGFloat = 16
    var active = false
    var label: String
    var tooltipEdge: VerticalEdge = .top
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(active ? Theme.accent : hovering ? Theme.text : Theme.secondary)
                .frame(width: size + 16, height: size + 16)
                .contentShape(Rectangle())
                .overlay(alignment: .bottom) {
                    // A little dot under an active toggle.
                    if active {
                        Circle().fill(Theme.accent).frame(width: 4, height: 4).offset(y: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .tooltip(label, edge: tooltipEdge)
        .accessibilityLabel(label)
    }
}

/// Filter chip ("Playlists", "Songs", "For you"…).
struct Chip: View {
    var title: String
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? Theme.onContrast : Theme.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(selected ? Theme.text : hovering ? Theme.text.opacity(0.14) : Theme.chip))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct SectionHeader: View {
    var title: String
    var label: String?
    var showAll: (() -> Void)?
    /// YouTube Music's ‹ › for shelves that scroll sideways (nil: no buttons).
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var canGoPrevious = false
    var canGoNext = false

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                if let label {
                    Text(label).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.text)
            }
            Spacer()
            if let showAll {
                Button("Show all", action: showAll)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.secondary)
                    .hoverUnderline()
            }
            if let onPrevious, let onNext {
                HStack(spacing: 8) {
                    ShelfArrow(systemImage: "chevron.left", enabled: canGoPrevious, label: String(localized: "Scroll back"), action: onPrevious)
                    ShelfArrow(systemImage: "chevron.right", enabled: canGoNext, label: String(localized: "Scroll forward"), action: onNext)
                }
                .padding(.leading, 12)
                .alignmentGuide(.lastTextBaseline) { $0[VerticalAlignment.center] + 5 }
            }
        }
    }
}

private struct ShelfArrow: View {
    var systemImage: String
    var enabled: Bool
    var label: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(enabled ? Theme.text : Theme.tertiary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(enabled && hovering ? Theme.text.opacity(0.18) : Theme.text.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
    }
}

// MARK: - Hover pauses while scrolling

/// Whether a page is scrolling right now (including the momentum glide).
@MainActor
@Observable
final class ScrollActivity {
    static let shared = ScrollActivity()
    var isScrolling = false
    @ObservationIgnored private var lastMove = Date.distantPast
    @ObservationIgnored private var watching = false

    /// The page actually moved. Hover pauses until it's been still for a moment.
    func moved() {
        lastMove = Date()
        if !isScrolling { isScrolling = true }
        guard !watching else { return }
        watching = true
        Task {
            while Date().timeIntervalSince(lastMove) < 0.15 {
                try? await Task.sleep(for: .milliseconds(60))
            }
            watching = false
            isScrolling = false
        }
    }

}

/// Page content that ignores the pointer while the page scrolls, as browsers do: no hover regions
/// to re-test on every frame, no rows switching hover state as they slide past a still pointer.
/// Hover returns as soon as scrolling stops. Only this wrapper redraws when that flips.
struct PausesHoverWhileScrolling<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content.allowsHitTesting(!ScrollActivity.shared.isScrolling)
    }
}

extension View {
    /// On a ScrollView: keeps `ScrollActivity` up to date.
    /// Reports the page moving vertically — not just a touch on the trackpad. A scroll *phase*
    /// starts as soon as fingers touch, even when the swipe is for a sideways shelf; pausing
    /// hit-testing then cut the shelf's swipe off after a few pixels.
    func reportsScrolling() -> some View {
        onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { old, new in
            // The benchmark scrolls programmatically and sets the flag itself.
            guard !Bench.enabled, abs(new - old) > 0.5 else { return }
            ScrollActivity.shared.moved()
        }
    }
}

// MARK: - Appearance

/// Dark (the default), light, or whatever the system uses. Settings → General.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, dark, light
    var id: String { rawValue }
    static let key = "appearance"

    static var current: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .dark
    }

    var title: String {
        switch self {
        case .system: String(localized: "Follow System")
        case .dark: String(localized: "Dark")
        case .light: String(localized: "Light")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }

    /// AppKit's menus, alerts and panels follow too.
    @MainActor
    static func applyToApp() {
        NSApp.appearance = switch current {
        case .system: nil
        case .dark: NSAppearance(named: .darkAqua)
        case .light: NSAppearance(named: .aqua)
        }
    }
}

private struct AppAppearanceModifier: ViewModifier {
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.dark

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(appearance.colorScheme)
            .onChange(of: appearance, initial: true) { AppAppearance.applyToApp() }
    }
}

extension View {
    /// The appearance chosen in Settings, for a window's root view.
    func appAppearance() -> some View { modifier(AppAppearanceModifier()) }
}
