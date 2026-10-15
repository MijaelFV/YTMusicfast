import CoreAudio
import Foundation

/// This Mac's audio outputs (speakers, headphones, AirPlay and Bluetooth devices macOS knows about),
/// for the Connect panel's device list. Playback is routed per player via `audioOutputDeviceUniqueID`.
enum OutputDevices {
    struct Device: Identifiable, Hashable {
        var uid: String
        var name: String
        var transport: UInt32
        var id: String { uid }

        var symbol: String {
            switch transport {
            case kAudioDeviceTransportTypeAirPlay: "airplayaudio"
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "headphones"
            case kAudioDeviceTransportTypeBuiltIn: "laptopcomputer"
            case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: "tv"
            case kAudioDeviceTransportTypeUSB: "hifispeaker"
            default: "speaker.wave.2"
            }
        }
    }

    static func all() -> [Device] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasOutput(id), let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Device(uid: uid, name: name, transport: transport(id))
        }
    }

    /// What kind of output it is, for the Connect panel ("Bluetooth", "AirPlay"…).
    static func kind(_ device: Device) -> String {
        switch device.transport {
        case kAudioDeviceTransportTypeAirPlay: String(localized: "AirPlay")
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: String(localized: "Bluetooth")
        case kAudioDeviceTransportTypeBuiltIn: String(localized: "This computer")
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: String(localized: "Display")
        case kAudioDeviceTransportTypeUSB: String(localized: "USB")
        default: String(localized: "Audio output")
        }
    }

    /// Calls `changed` whenever outputs come or go or the system's default changes — events from
    /// Core Audio, not polling. Listening stops when the returned token is released.
    static func observe(_ changed: @escaping @MainActor () -> Void) -> AnyObject {
        Listener(changed)
    }

    private final class Listener {
        private var addresses = [
            AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain),
            AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain),
        ]
        private let block: AudioObjectPropertyListenerBlock

        init(_ changed: @escaping @MainActor () -> Void) {
            block = { _, _ in MainActor.assumeIsolated { changed() } }
            for index in addresses.indices {
                AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addresses[index], .main, block)
            }
        }

        deinit {
            for index in addresses.indices {
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addresses[index], .main, block)
            }
        }
    }

    /// The system's current default output.
    static func defaultDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return nil }
        return string(id, kAudioDevicePropertyDeviceUID)
    }

    private static func hasOutput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func transport(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
    }
}
