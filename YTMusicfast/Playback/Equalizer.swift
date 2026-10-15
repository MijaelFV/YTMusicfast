import Accelerate
import AVFoundation
import MediaToolbox
import Observation
import os

/// The equalizer: ten bands with presets, applied to the audio as AVPlayer decodes it —
/// plus left/right balance, mono, and the samples the player-bar visualizer draws.
///
/// Every player item gets one audio processing tap when it's created, and keeps it: turning these
/// on or off only flips flags the tap reads. Swapping a tap on an item that's already playing or
/// queued rebuilds its audio chain mid-song, and AVQueuePlayer could then play the *next* song's
/// pre-loaded audio under the current one. With everything off the tap returns at once (it costs
/// nothing measurable); when on: vDSP biquads for the EQ, a few multiplies for balance/mono, a
/// copy of recent samples while a visualizer is showing.
@MainActor
@Observable
final class Equalizer {
    static let shared = Equalizer()

    static let frequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let range: ClosedRange<Double> = -12...12

    static let presets: [(name: String, gains: [Double])] = [
        (String(localized: "Flat"), [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        (String(localized: "Bass Booster"), [6, 5, 4, 2.5, 1, 0, 0, 0, 0, 0]),
        (String(localized: "Bass Reducer"), [-6, -5, -4, -2.5, -1, 0, 0, 0, 0, 0]),
        (String(localized: "Treble Booster"), [0, 0, 0, 0, 0, 1, 2.5, 4, 5, 6]),
        (String(localized: "Vocal Booster"), [-2, -3, -3, 1, 4, 4, 3, 1.5, 0, -1.5]),
        (String(localized: "Acoustic"), [4.5, 4.5, 3.5, 1, 1.5, 1.5, 3, 3.5, 3, 1.5]),
        (String(localized: "Classical"), [4.5, 3.5, 3, 2.5, -1.5, -1.5, 0, 2, 3, 3.5]),
        (String(localized: "Dance"), [3.5, 6.5, 5, 0, 2, 3.5, 5, 4, 3.5, 0]),
        (String(localized: "Electronic"), [4, 3.5, 1, 0, -2, 2, 1, 1.5, 4, 4.5]),
        (String(localized: "Hip-Hop"), [5, 4.5, 1.5, 3, -1, -1, 1.5, -0.5, 2, 3]),
        (String(localized: "Jazz"), [4, 3, 1.5, 2, -1.5, -1.5, 0, 1.5, 3, 3.5]),
        (String(localized: "Loudness"), [6, 4, 0, 0, -2, 0, -1, -5, 5, 1]),
        (String(localized: "Pop"), [-1.5, -1, 0, 2, 4, 4, 2, 0, -1, -1.5]),
        (String(localized: "Rock"), [5, 4, 3, 1.5, -0.5, -1, 0.5, 2.5, 3.5, 4.5]),
        (String(localized: "Lounge"), [-3, -1.5, -0.5, 1.5, 4, 2.5, 0, -1.5, 2, 1]),
    ]

    var enabled = UserDefaults.standard.bool(forKey: "eq.enabled") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "eq.enabled")
            state.setEqualizer(enabled)
        }
    }

    /// Left/right balance, −1 (left only) … 1 (right only).
    var balance = UserDefaults.standard.double(forKey: "audio.balance") {
        didSet {
            UserDefaults.standard.set(balance, forKey: "audio.balance")
            state.setChannels(balance: balance, mono: mono)
        }
    }

    /// Both speakers play the same (one earbud, or hard-panned old recordings).
    var mono = UserDefaults.standard.bool(forKey: "audio.mono") {
        didSet {
            UserDefaults.standard.set(mono, forKey: "audio.mono")
            state.setChannels(balance: balance, mono: mono)
        }
    }

    /// A visualizer is on screen and wants the samples being played.
    var capturing = false {
        didSet {
            guard capturing != oldValue else { return }
            state.setCapturing(capturing)
        }
    }

    /// The recent samples the tap copied (mono), for the visualizers.
    let samples = SampleBuffer()


    var gains: [Double] = (UserDefaults.standard.array(forKey: "eq.gains") as? [Double]).flatMap { $0.count == 10 ? $0 : nil }
        ?? Array(repeating: 0, count: 10) {
        didSet {
            UserDefaults.standard.set(gains, forKey: "eq.gains")
            state.update(gains)
        }
    }

    /// The preset the gains match, if any ("Custom" otherwise).
    var presetName: String {
        Self.presets.first { $0.gains == gains }?.name ?? String(localized: "Custom")
    }

    func apply(preset name: String) {
        guard let preset = Self.presets.first(where: { $0.name == name }) else { return }
        gains = preset.gains
    }

    /// Shared with the audio thread.
    private let state = TapState()

    private init() {
        state.update(gains)
        state.setEqualizer(enabled)
        state.setChannels(balance: balance, mono: mono)
    }

    /// Gives a new player item its tap, before it plays. Waits for the item's audio track.
    func attach(to item: AVPlayerItem) async {
        guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first,
              let tap = EqualizerTap.make(state: state, samples: samples) else { return }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        item.audioMix = mix
    }
}

/// Settings read by the audio thread, behind a lock it only holds for a moment.
final class TapState: @unchecked Sendable {
    struct Snapshot {
        var gains: [Double]
        var version: Int
        var equalizer: Bool
        var balance: Float
        var mono: Bool
        var capturing: Bool
    }

    private var lock = os_unfair_lock()
    private var current = Snapshot(gains: Array(repeating: 0, count: 10), version: 0, equalizer: false, balance: 0, mono: false, capturing: false)

    private func edit(_ change: (inout Snapshot) -> Void) {
        os_unfair_lock_lock(&lock)
        change(&current)
        os_unfair_lock_unlock(&lock)
    }

    func update(_ new: [Double]) { edit { $0.gains = new; $0.version += 1 } }
    func setEqualizer(_ on: Bool) { edit { $0.equalizer = on } }
    func setChannels(balance: Double, mono: Bool) { edit { $0.balance = Float(balance); $0.mono = mono } }
    func setCapturing(_ on: Bool) { edit { $0.capturing = on } }

    func snapshot() -> Snapshot {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return current
    }
}

/// The last couple of thousand samples played (both channels mixed), for visualizers. The audio
/// thread never waits for it: if the reader holds the lock, that block simply isn't copied.
final class SampleBuffer: @unchecked Sendable {
    static let capacity = 4096
    private var lock = os_unfair_lock()
    private let storage = UnsafeMutablePointer<Float>.allocate(capacity: SampleBuffer.capacity)
    private var writeIndex = 0
    private(set) var sampleRate: Double = 44_100

    init() { storage.initialize(repeating: 0, count: Self.capacity) }
    deinit { storage.deallocate() }

    /// Audio thread: appends one buffer's frames, mixing interleaved or separate channels to mono.
    func append(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int, sampleRate rate: Double) {
        guard frames > 0, os_unfair_lock_trylock(&lock) else { return }
        defer { os_unfair_lock_unlock(&lock) }
        sampleRate = rate
        let channels = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        guard channels > 0 else { return }
        let scale = 1 / Float(channels)
        for frame in 0..<frames {
            var sum: Float = 0
            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let stride = Int(buffer.mNumberChannels)
                for channel in 0..<stride { sum += data[frame * stride + channel] }
            }
            storage[writeIndex] = sum * scale
            writeIndex = (writeIndex + 1) % Self.capacity
        }
    }

    /// The newest `count` samples, oldest first, written into `out`.
    func copyLatest(_ count: Int, into out: inout [Float]) {
        let count = min(count, Self.capacity)
        if out.count != count { out = Array(repeating: 0, count: count) }
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        var index = (writeIndex - count + Self.capacity) % Self.capacity
        for i in 0..<count {
            out[i] = storage[index]
            index = (index + 1) % Self.capacity
        }
    }

    /// Silence, so a paused or finished song doesn't leave its last shape frozen on screen.
    func clear() {
        os_unfair_lock_lock(&lock)
        storage.update(repeating: 0, count: Self.capacity)
        os_unfair_lock_unlock(&lock)
    }
}

/// The audio processing tap: one biquad cascade per channel (rebuilt when the gains change),
/// then balance / mono, then a copy of the samples for the visualizer.
private final class EqualizerTap {
    let state: TapState
    let samples: SampleBuffer
    var sampleRate: Double = 44_100
    var interleaved = false
    var isFloat = true
    var version = -1
    var setup: vDSP_biquad_Setup?
    var sections = 0
    var delays: [[Float]] = []
    var preamp: Float = 1
    var equalizing = false

    init(state: TapState, samples: SampleBuffer) {
        self.state = state
        self.samples = samples
    }

    deinit { if let setup { vDSP_biquad_DestroySetup(setup) } }

    static func make(state: TapState, samples: SampleBuffer) -> MTAudioProcessingTap? {
        let context = EqualizerTap(state: state, samples: samples)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(context).toOpaque(),
            init: { _, clientInfo, storageOut in
                storageOut.pointee = clientInfo
            },
            finalize: { tap in
                Unmanaged<EqualizerTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let context = Unmanaged<EqualizerTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let description = format.pointee
                context.sampleRate = description.mSampleRate
                context.interleaved = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
                context.isFloat = description.mFormatFlags & kAudioFormatFlagIsFloat != 0 && description.mBitsPerChannel == 32
                context.version = -1
            },
            unprepare: { _ in },
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut) == noErr else { return }
                let context = Unmanaged<EqualizerTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                context.process(UnsafeMutableAudioBufferListPointer(bufferList), frames: Int(framesOut.pointee))
            }
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr else {
            Unmanaged<EqualizerTap>.fromOpaque(callbacks.clientInfo!).release()
            return nil
        }
        return tap
    }

    /// RBJ peaking-filter coefficients for each band below Nyquist, as vDSP wants them.
    private func rebuild(gains: [Double], channels: Int) {
        if let setup { vDSP_biquad_DestroySetup(setup) }
        var coefficients: [Double] = []
        let q = 1.0
        for (frequency, gain) in zip(Equalizer.frequencies, gains) where frequency < sampleRate * 0.45 && abs(gain) > 0.01 {
            let a = pow(10, gain / 40)
            let w0 = 2 * Double.pi * frequency / sampleRate
            let alpha = sin(w0) / (2 * q)
            let a0 = 1 + alpha / a
            coefficients += [(1 + alpha * a) / a0, (-2 * cos(w0)) / a0, (1 - alpha * a) / a0, (-2 * cos(w0)) / a0, (1 - alpha / a) / a0]
        }
        sections = coefficients.count / 5
        setup = sections > 0 ? vDSP_biquad_CreateSetup(coefficients, vDSP_Length(sections)) : nil
        delays = Array(repeating: Array(repeating: 0, count: 2 * sections + 2), count: max(channels, 1))
        // Headroom so boosted bands don't clip.
        let boost = max(0, gains.max() ?? 0)
        preamp = Float(pow(10, -boost * 0.6 / 20))
    }

    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
        guard isFloat, frames > 0 else { return }
        let snapshot = state.snapshot()
        // Switched on mid-song: start the filters from silence, not from whatever they last held.
        if snapshot.equalizer, !equalizing { delays = delays.map { Array(repeating: 0, count: $0.count) } }
        equalizing = snapshot.equalizer
        if snapshot.equalizer { equalize(buffers, frames: frames, snapshot: snapshot) }
        if snapshot.mono || snapshot.balance != 0 { mixChannels(buffers, frames: frames, balance: snapshot.balance, mono: snapshot.mono) }
        if snapshot.capturing { samples.append(buffers, frames: frames, sampleRate: sampleRate) }
    }

    /// Mono, then balance: the far side is turned down (the near side stays at full level).
    private func mixChannels(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int, balance: Float, mono: Bool) {
        // The two channels: one interleaved buffer, or two separate ones.
        let left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, stride: Int
        if buffers.count == 1, buffers[0].mNumberChannels == 2, let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
            (left, right, stride) = (data, data + 1, 2)
        } else if buffers.count == 2, let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) {
            (left, right, stride) = (l, r, 1)
        } else {
            return
        }
        let n = vDSP_Length(frames)
        let s = vDSP_Stride(stride)
        if mono {
            var half: Float = 0.5
            vDSP_vasm(left, s, right, s, &half, left, s, n)
            cblas_scopy(Int32(frames), left, Int32(stride), right, Int32(stride))
        }
        if balance > 0 {
            var gain = 1 - balance
            vDSP_vsmul(left, s, &gain, left, s, n)
        } else if balance < 0 {
            var gain = 1 + balance
            vDSP_vsmul(right, s, &gain, right, s, n)
        }
    }

    private func equalize(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int, snapshot: TapState.Snapshot) {
        let channels = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        if snapshot.version != version || delays.count != max(channels, 1) {
            rebuild(gains: snapshot.gains, channels: channels)
            version = snapshot.version
        }
        guard let setup else { return }
        var channel = 0
        for buffer in buffers {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let stride = Int(buffer.mNumberChannels)
            for offset in 0..<stride where channel < delays.count {
                let start = data + offset
                delays[channel].withUnsafeMutableBufferPointer { delay in
                    vDSP_biquad(setup, delay.baseAddress!, start, vDSP_Stride(stride), start, vDSP_Stride(stride), vDSP_Length(frames))
                }
                var gain = preamp
                vDSP_vsmul(start, vDSP_Stride(stride), &gain, start, vDSP_Stride(stride), vDSP_Length(frames))
                channel += 1
            }
        }
    }
}
