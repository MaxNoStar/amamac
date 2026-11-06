import CoreAudio
import Foundation

/// What the audio hardware looks like, as far as playback cares: where the sound goes, in what
/// format, and whether another app is recording (a call).
public struct AudioRoute: Sendable, Equatable {
    /// The system's default output device.
    public var defaultOutput: AudioObjectID?
    /// Every audio device, so devices coming and going are noticed.
    public var devices: [AudioObjectID] = []
    /// The device playback is on (see `AudioRouteMonitor.watchOutput`), else the default output.
    public var output: AudioObjectID?
    public var outputName: String?
    public var outputRate: Double?
    public var outputChannels: Int?
    public var outputAlive = true
    /// Other apps recording from a microphone now (bundle IDs, or "pid N"): a call, dictation, a
    /// voice memo. Amamac never records, so it is never one of them.
    public var recordingApps: [String] = []

    public var microphoneInUse: Bool { !recordingApps.isEmpty }

    public init() {}

    /// The route right now. `output` is the device to describe; nil means the default output.
    public static func read(output watched: AudioObjectID?) -> AudioRoute {
        var route = AudioRoute()
        route.defaultOutput = AudioDevices.defaultOutputDevice()
        route.devices = CoreAudioProperty.objects(CoreAudioProperty.system, kAudioHardwarePropertyDevices).sorted()
        let output = watched ?? route.defaultOutput
        route.output = output
        if let output {
            route.outputName = CoreAudioProperty.string(output, kAudioObjectPropertyName)
            route.outputRate = AudioDevices.nominalSampleRate(output)
            route.outputChannels = CoreAudioProperty.channelCount(output, scope: kAudioObjectPropertyScopeOutput)
            route.outputAlive = (CoreAudioProperty.uint32(output, kAudioDevicePropertyDeviceIsAlive) ?? 1) != 0
        }
        route.recordingApps = recordingApps()
        return route
    }

    /// Core Audio's per-process view: which client processes run input IO right now.
    static func recordingApps() -> [String] {
        let me = getpid()
        return CoreAudioProperty.objects(CoreAudioProperty.system, kAudioHardwarePropertyProcessObjectList).compactMap { process in
            let pid = CoreAudioProperty.int32(process, kAudioProcessPropertyPID)
            guard pid != me, CoreAudioProperty.uint32(process, kAudioProcessPropertyIsRunningInput) == 1 else { return nil }
            return CoreAudioProperty.string(process, kAudioProcessPropertyBundleID).flatMap { $0.isEmpty ? nil : $0 }
                ?? "pid \(pid.map(String.init) ?? "?")"
        }
        .sorted()
    }

    /// One line for the playback event log.
    public var summary: String {
        var parts: [String] = []
        parts.append("output \(outputName ?? output.map { "#\($0)" } ?? "none")")
        if let outputRate { parts.append("\(Int(outputRate.rounded())) Hz") }
        if let outputChannels { parts.append("\(outputChannels) ch") }
        if !outputAlive { parts.append("gone") }
        parts.append(microphoneInUse ? "microphone in use by \(recordingApps.joined(separator: ", "))" : "microphone free")
        return parts.joined(separator: ", ")
    }
}
