import AppKit
import AVKit
import SwiftUI

/// The Connect panel (the right panel): the device playing now in a highlighted card, the
/// others below, AirPlay, and help at the bottom. Updates as devices come and go.
struct ConnectPanel: View {
    @Environment(Router.self) private var router
    @State private var devices: [OutputDevices.Device] = []
    @State private var defaultUID: String?
    @State private var listener: AnyObject?
    private var player: PlayerController { .shared }
    private var cast: CastController { .shared }

    /// What's playing the music right now.
    private var current: (name: String, kind: String, symbol: String) {
        if let device = cast.device {
            let kind = cast.state == .connecting ? String(localized: "Connecting…")
                : cast.viaYouTubeApp ? String(localized: "Google Cast · YouTube app") : String(localized: "Google Cast")
            return (device.name, kind, device.symbol)
        }
        if player.isAirPlaying { return (String(localized: "AirPlay"), String(localized: "AirPlay"), "airplayaudio") }
        let uid = player.outputDeviceUID ?? defaultUID
        guard let device = devices.first(where: { $0.uid == uid }) else {
            return (String(localized: "This computer"), String(localized: "System output"), "laptopcomputer")
        }
        let kind = player.outputDeviceUID == nil ? String(localized: "This computer") : OutputDevices.kind(device)
        return (device.name, kind, device.symbol)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Connect").font(.system(size: 17, weight: .bold))
                Spacer()
                IconButton(systemImage: "xmark", size: 14, label: String(localized: "Close")) {
                    withAnimation(.spring(duration: 0.3)) { router.rightPanel = nil }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    currentCard
                        .padding(.bottom, cast.device?.isSpeaker == false ? 4 : 18)
                    if let device = cast.device, !device.isSpeaker {
                        let youTubeApp = TVYouTubeApp.shared.isOn(for: device)
                        CastSwitch(title: String(localized: "Use the TV's YouTube app"),
                                   help: String(localized: "On: the TV's YouTube app plays the music, with the TV's YouTube account, and this Mac can sleep. Off: this Mac streams to the TV."),
                                   isOn: Binding(get: { youTubeApp }, set: { TVYouTubeApp.shared.set($0, for: device) }))
                        Spacer().frame(height: 12)
                    }
                    let casting = cast.device != nil
                    if player.outputDeviceUID != nil || player.isAirPlaying || casting {
                        // Back to whatever macOS is set to.
                        let system = devices.first { $0.uid == defaultUID }
                        DeviceRow(name: String(localized: "System output"), subtitle: system?.name, symbol: "laptopcomputer") {
                            cast.disconnect()
                            player.outputDeviceUID = nil
                        }
                    }
                    ForEach(devices.filter { casting || $0.uid != (player.outputDeviceUID ?? (player.isAirPlaying ? nil : defaultUID)) }) { device in
                        DeviceRow(name: device.name, subtitle: OutputDevices.kind(device), symbol: device.symbol) {
                            cast.disconnect()
                            player.outputDeviceUID = device.uid
                        }
                    }
                    // Chromecasts, Google TVs and Cast speakers on the network.
                    if cast.needsLocalNetworkPermission {
                        LocalNetworkNotice()
                    } else if cast.searching, cast.devices.isEmpty, !cast.searchedOnce {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Looking for Chromecasts and Google TVs…").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    } else if cast.searchedOnce, cast.devices.isEmpty {
                        // Still looking (one turned on now shows up), but say none answered so far.
                        VStack(alignment: .leading, spacing: 3) {
                            Text("No Cast devices found").font(.system(size: 13, weight: .semibold))
                            Text("Check that your Chromecast or Google TV is on and on the same Wi-Fi as this Mac.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .accessibilityElement(children: .combine)
                    }
                    ForEach(cast.devices.filter { $0.id != cast.device?.id }) { device in
                        let youTubeApp = TVYouTubeApp.shared.isOn(for: device)
                        DeviceRow(name: device.name, subtitle: youTubeApp ? String(localized: "Google Cast · YouTube app") : String(localized: "Google Cast"),
                                  symbol: device.symbol) {
                            cast.cast(to: device)
                        }
                        .contextMenu {
                            if !device.isSpeaker {
                                Toggle("Use the TV's YouTube app", isOn: Binding(get: { youTubeApp }, set: { TVYouTubeApp.shared.set($0, for: device) }))
                            }
                        }
                    }
                    AirPlayRow()
                    // Starting a listening session lives here too.
                    ListenTogetherSection()
                        .padding(.horizontal, 8)
                        .padding(.top, 22)
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.never)

            VStack(spacing: 0) {
                HelpLink(title: String(localized: "Don't see your device?")) {
                    // Pair Bluetooth speakers and headphones there; AirPlay devices show up above.
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
                }
                HelpLink(title: String(localized: "Sound settings")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
        .foregroundStyle(Theme.text)
        .onAppear {
            reload()
            listener = OutputDevices.observe { reload() }
            cast.startDiscovery()
        }
        .onDisappear {
            listener = nil
            cast.stopDiscovery()
        }
    }

    private var currentCard: some View {
        let current = current
        return HStack(spacing: 16) {
            Image(systemName: current.symbol)
                .font(.system(size: 24, weight: .medium))
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(current.name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                Text(current.kind).font(.system(size: 14)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Playing on \(current.name)")
    }

    private func reload() {
        devices = OutputDevices.all()
        defaultUID = OutputDevices.defaultDeviceUID()
    }
}

/// A setting for the TV playing now, under its card: whether it plays through its own YouTube app
/// (see `TVYouTubeApp`).
private struct CastSwitch: View {
    var title: String
    var help: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(Theme.accent)
        .help(help)
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
    }
}

/// macOS hasn't let the app look for devices on the network: say so, with the way to allow it.
private struct LocalNetworkNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Allow local network access to see Chromecasts and Google TVs")
                .font(.system(size: 14, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("System Settings → Privacy & Security → Local Network → turn on YT Musicfast.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            PillButton(title: String(localized: "Open Settings"), filled: true) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .padding(.vertical, 6)
    }
}

/// One device in the Connect panel.
private struct DeviceRow: View {
    var name: String
    var subtitle: String?
    var symbol: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: symbol).font(.system(size: 20)).frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 15)).lineLimit(1)
                    if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// "AirPlay speakers and TVs": Apple's AirPlay picker for the music player, which finds every
/// AirPlay device on the network by itself. Shown only while macOS detects AirPlay devices nearby
/// (a network without any shouldn't offer a row that opens an empty list). Picking one clears a
/// Mac output chosen above.
private struct AirPlayRow: View {
    @State private var hovering = false
    @State private var available = false
    @State private var picker = RoutePickerBox()

    var body: some View {
        Group {
            if available {
                Button { picker.open() } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "airplayaudio").font(.system(size: 20)).frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("AirPlay speakers and TVs").font(.system(size: 15)).lineLimit(1)
                            Text("HomePod, Apple TV, Sonos, smart TVs…").font(.system(size: 13)).foregroundStyle(Theme.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.hover : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
            }
        }
        // Apple's picker itself, out of sight: the row opens its menu.
        .background(RoutePicker(box: picker).frame(width: 1, height: 1).opacity(0))
        .background(RouteDetection(available: $available))
    }
}

/// Holds Apple's route picker so the row can open it.
@MainActor
final class RoutePickerBox {
    weak var view: AVRoutePickerView?

    /// Clicks the picker's own button, which shows the system's AirPlay menu.
    func open() {
        guard let view else { return }
        func button(in view: NSView) -> NSButton? {
            if let button = view as? NSButton { return button }
            for subview in view.subviews { if let found = button(in: subview) { return found } }
            return nil
        }
        button(in: view)?.performClick(nil)
    }
}

private struct RoutePicker: NSViewRepresentable {
    let box: RoutePickerBox

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.player = PlayerController.shared.routingPlayer
        picker.isRoutePickerButtonBordered = false
        picker.delegate = context.coordinator
        box.view = picker
        return picker
    }

    func updateNSView(_ picker: AVRoutePickerView, context: Context) {
        picker.player = PlayerController.shared.routingPlayer
        box.view = picker
    }

    final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            MainActor.assumeIsolated {
                let player = PlayerController.shared
                // An AirPlay device was picked: let it have the sound.
                if player.isAirPlaying { player.outputDeviceUID = nil }
            }
        }
    }
}

/// Whether macOS sees AirPlay devices to play to, while the panel is open (detection costs a
/// little network scanning, so only then).
private struct RouteDetection: NSViewRepresentable {
    @Binding var available: Bool

    func makeCoordinator() -> Coordinator { Coordinator(available: $available) }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.start()
        return NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {}

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }

    final class Coordinator {
        private let detector = AVRouteDetector()
        private var observation: NSKeyValueObservation?
        private let available: Binding<Bool>

        init(available: Binding<Bool>) { self.available = available }

        @MainActor func start() {
            detector.isRouteDetectionEnabled = true
            observation = detector.observe(\.multipleRoutesDetected, options: [.initial, .new]) { [available] detector, _ in
                let found = detector.multipleRoutesDetected
                Task { @MainActor in available.wrappedValue = found }
            }
        }

        @MainActor func stop() {
            observation = nil
            detector.isRouteDetectionEnabled = false
        }
    }
}

private struct HelpLink: View {
    var title: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 15, weight: .medium))
                Spacer()
                Image(systemName: "arrow.up.forward.square").font(.system(size: 15))
            }
            .foregroundStyle(hovering ? Theme.text : Theme.text.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The devices as a menu, for places with no room for the panel (the notch island).
@MainActor
enum ConnectMenu {
    static func entries() -> [MenuEntry] {
        let player = PlayerController.shared
        let defaultUID = OutputDevices.defaultDeviceUID()
        var entries: [MenuEntry] = [
            .header(String(localized: "Connect")),
            .choice(String(localized: "System output"), systemImage: "laptopcomputer", selected: player.outputDeviceUID == nil && !player.isAirPlaying) {
                player.outputDeviceUID = nil
            },
        ]
        entries += OutputDevices.all().filter { $0.uid != defaultUID || player.outputDeviceUID != nil }.map { device in
            .choice(device.name, systemImage: device.symbol, selected: player.outputDeviceUID == device.uid) { player.outputDeviceUID = device.uid }
        }
        return entries
    }
}
