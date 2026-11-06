import CoreAudio
import Foundation

/// An output-capable Core Audio device. `uid` is stable across reboots; `id` is not.
public struct AudioOutputDevice: Sendable, Hashable, Identifiable {
    public var id: AudioObjectID
    public var uid: String
    public var name: String
}

/// Output device lookup. (Route changes that playback follows come from `AudioRouteMonitor`; the
/// change notifications here only refresh device lists in Settings.)
public enum AudioDevices {
    public static func outputDevices() -> [AudioOutputDevice] {
        CoreAudioProperty.objects(CoreAudioProperty.system, kAudioHardwarePropertyDevices).compactMap { id in
            guard hasOutput(id), let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return AudioOutputDevice(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func defaultOutputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    /// The device's current sample rate, if it reports one.
    public static func nominalSampleRate(_ id: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard id != 0, AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr,
              rate.isFinite, rate > 0 else { return nil }
        return rate
    }

    public static func device(uid: String) -> AudioObjectID? {
        outputDevices().first { $0.uid == uid }?.id
    }

    private static func hasOutput(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        CoreAudioProperty.string(id, selector)
    }

    /// Calls `handler` on the main queue when devices come or go or the default output changes.
    /// Listening stops when the returned object is released.
    public static func observeChanges(_ handler: @escaping @Sendable () -> Void) -> AudioDeviceObservation {
        AudioDeviceObservation(handler)
    }
}

public final class AudioDeviceObservation: @unchecked Sendable {
    private let block: AudioObjectPropertyListenerBlock
    private static let selectors = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice]

    init(_ handler: @escaping @Sendable () -> Void) {
        block = { _, _ in handler() }
        for selector in Self.selectors {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
    }

    deinit {
        for selector in Self.selectors {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
    }
}
