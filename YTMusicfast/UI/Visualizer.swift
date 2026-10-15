import Accelerate
import AppKit
import SwiftUI

/// The player-bar visualizer: a spectrum or a waveform of what's playing, in the cover's
/// colour, drawn behind the player bar.
///
/// Off by default, and free when off: nothing is drawn and the audio tap doesn't copy samples. When on,
/// it redraws only while music plays in a visible window, at the frame rate chosen in Settings
/// (lower when the app isn't in front).
enum VisualizerMode: String, CaseIterable, Identifiable {
    case off, spectrum, waveform
    var id: String { rawValue }

    static let key = "visualizer"
    static let fpsKey = "visualizerFPS"

    var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .spectrum: String(localized: "Spectrum")
        case .waveform: String(localized: "Waveform")
        }
    }

    var next: VisualizerMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

struct PlayerBarVisualizer: View {
    @AppStorage(VisualizerMode.key) private var mode = VisualizerMode.off

    var body: some View {
        if mode != .off {
            VisualizerCanvas(mode: mode)
        }
    }
}

/// Draws the visualizer. Only exists while a mode is on.
///
/// Core Animation does the drawing: one layer per bar (or one shape for the waveform) whose
/// frames change each tick, so frames are composited by the GPU instead of being rasterized on
/// the main thread. A display link drives it, paused while music is paused or the window hidden.
struct VisualizerCanvas: View {
    var mode: VisualizerMode
    @AppStorage(VisualizerMode.fpsKey) private var fps = 30
    @State private var tint = Theme.accent
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.colorScheme) private var colorScheme
    private var player: PlayerController { .shared }

    var body: some View {
        // Half the rate while another app is in front.
        let rate = activeState == .inactive ? max(15, fps / 2) : fps
        VisualizerLayerView(mode: mode, fps: rate, running: player.isPlaying,
                            color: NSColor(tint.headerTint()).resolved(dark: colorScheme == .dark))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .artworkTint(player.current?.thumbnail, into: $tint)
            .onAppear { Equalizer.shared.capturing = true }
            .onDisappear {
                Equalizer.shared.capturing = false
                Equalizer.shared.samples.clear()
            }
            .onChange(of: player.isPlaying) { _, playing in
                if !playing { Equalizer.shared.samples.clear() }
            }
    }
}

private extension NSColor {
    /// A dynamic colour as it looks in one appearance (layers take fixed colours).
    func resolved(dark: Bool) -> NSColor {
        var result = self
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            result = NSColor(cgColor: self.cgColor) ?? self
        }
        return result
    }
}

private struct VisualizerLayerView: NSViewRepresentable {
    var mode: VisualizerMode
    var fps: Int
    var running: Bool
    var color: NSColor

    func makeNSView(context: Context) -> VisualizerLayerHost { VisualizerLayerHost() }

    func updateNSView(_ view: VisualizerLayerHost, context: Context) {
        view.configure(mode: mode, fps: fps, running: running, color: color)
    }

    static func dismantleNSView(_ view: VisualizerLayerHost, coordinator: ()) { view.stop() }
}

final class VisualizerLayerHost: NSView {
    private let barCount = 48
    private var bars: [CALayer] = []
    private let wave = CAShapeLayer()
    private let analyzer = SpectrumAnalyzer()
    private var link: CADisplayLink?
    private var mode = VisualizerMode.off
    private var running = false
    private var fps = 30

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        for _ in 0..<barCount {
            let bar = CALayer()
            bar.cornerRadius = 1.5
            bar.anchorPoint = CGPoint(x: 0, y: 0)
            layer?.addSublayer(bar)
            bars.append(bar)
        }
        wave.fillColor = nil
        wave.lineWidth = 1.5
        wave.lineJoin = .round
        layer?.addSublayer(wave)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // Layer coordinates with y going up, like the bars grow.
    override var isFlipped: Bool { false }

    func configure(mode: VisualizerMode, fps: Int, running: Bool, color: NSColor) {
        self.mode = mode
        self.running = running
        self.fps = fps
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in bars {
            bar.backgroundColor = color.withAlphaComponent(0.4).cgColor
            bar.isHidden = mode != .spectrum
        }
        wave.strokeColor = color.withAlphaComponent(0.6).cgColor
        wave.isHidden = mode != .waveform
        CATransaction.commit()
        updateLink()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged), name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        updateLink()
    }

    @objc private func occlusionChanged() { updateLink() }

    /// Ticks only while there's something to show: playing, in a visible window.
    private func updateLink() {
        let visible = window?.occlusionState.contains(.visible) ?? false
        let active = running && visible && mode != .off
        if active, link == nil {
            let link = displayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: Float(fps) / 2, maximum: Float(fps), preferred: Float(fps))
        link?.isPaused = !active
        if !active { clearShapes() }
    }

    func stop() {
        link?.invalidate()
        link = nil
        NotificationCenter.default.removeObserver(self)
    }

    private func clearShapes() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in bars { bar.bounds.size.height = 0 }
        wave.path = nil
        CATransaction.commit()
    }

    @objc private func tick() {
        let size = bounds.size
        guard size.width > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch mode {
        case .spectrum:
            let levels = analyzer.spectrum(bars: barCount)
            let gap: CGFloat = 2
            let width = (size.width - gap * CGFloat(barCount - 1)) / CGFloat(barCount)
            for (index, level) in levels.enumerated() {
                bars[index].frame = CGRect(x: CGFloat(index) * (width + gap), y: 0, width: width, height: max(1, CGFloat(level) * size.height))
            }
        case .waveform:
            let points = analyzer.waveform(points: 160)
            let mid = size.height / 2
            let step = size.width / CGFloat(max(1, points.count - 1))
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: mid))
            for (index, value) in points.enumerated() {
                path.addLine(to: CGPoint(x: CGFloat(index) * step, y: mid + CGFloat(value) * mid * 0.9))
            }
            wave.path = path
        case .off:
            break
        }
        CATransaction.commit()
    }

    deinit { link?.invalidate() }
}

/// Turns the tap's recent samples into bar levels (FFT, log-spaced bands, smoothed) or a
/// waveform. Buffers are allocated once and reused every frame.
@MainActor
final class SpectrumAnalyzer {
    private static let log2n: vDSP_Length = 11
    private static let size = 1 << Int(log2n)
    private let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)
    private var samples = [Float](repeating: 0, count: size)
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
    private var real = [Float](repeating: 0, count: size / 2)
    private var imaginary = [Float](repeating: 0, count: size / 2)
    private var magnitudes = [Float](repeating: 0, count: size / 2)
    private var levels: [Float] = []
    private var wave: [Float] = []

    func spectrum(bars: Int) -> [Float] {
        if levels.count != bars { levels = Array(repeating: 0, count: bars) }
        let buffer = Equalizer.shared.samples
        buffer.copyLatest(Self.size, into: &samples)
        vDSP.multiply(samples, window, result: &samples)
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                samples.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(Self.size / 2))
                }
                fft?.forward(input: split, output: &split)
                vDSP.absolute(split, result: &magnitudes)
            }
        }
        // Log-spaced bands from 40 Hz to 16 kHz, in dB, mapped to 0…1.
        let nyquist = Float(buffer.sampleRate / 2)
        let binWidth = nyquist / Float(Self.size / 2)
        let low: Float = 40, high = min(16_000, nyquist)
        for bar in 0..<bars {
            let from = low * pow(high / low, Float(bar) / Float(bars))
            let to = low * pow(high / low, Float(bar + 1) / Float(bars))
            let first = min(magnitudes.count - 1, max(1, Int(from / binWidth)))
            let last = min(magnitudes.count - 1, max(first, Int(to / binWidth)))
            var peak: Float = 0
            for bin in first...last { peak = max(peak, magnitudes[bin]) }
            let db = 20 * log10(max(peak / Float(Self.size), 1e-7))
            let target = min(1, max(0, (db + 70) / 60))
            // Rise at once, fall gently.
            levels[bar] = target > levels[bar] ? target : levels[bar] * 0.82 + target * 0.18
        }
        return levels
    }

    func waveform(points: Int) -> [Float] {
        Equalizer.shared.samples.copyLatest(1024, into: &samples)
        if wave.count != points { wave = Array(repeating: 0, count: points) }
        let chunk = max(1, 1024 / points)
        var peak: Float = 0.05
        for index in 0..<points {
            var sum: Float = 0
            for offset in 0..<chunk where index * chunk + offset < 1024 { sum += samples[index * chunk + offset] }
            wave[index] = sum / Float(chunk)
            peak = max(peak, abs(wave[index]))
        }
        // Scaled to fill the height whatever the volume.
        vDSP.multiply(1 / peak, wave, result: &wave)
        return wave
    }
}
