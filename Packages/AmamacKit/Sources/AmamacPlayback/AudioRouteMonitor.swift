import CoreAudio
import Foundation

/// Follows the audio route: devices coming and going, the default output and input, the playing
/// device's rate, channels and presence, and other apps starting or stopping recording. A burst of
/// Core Audio notifications (a headset switching to call mode sends a dozen) is collapsed into one
/// `AudioRoute`, delivered on the main queue only when it differs from the last one.
///
/// This replaces reacting to each device notification directly, which raced SFBAudioEngine's own
/// handling of the same change and restarted the engines several times in a row.
public final class AudioRouteMonitor: @unchecked Sendable {
    public typealias Reader = @Sendable (_ output: AudioObjectID?) -> AudioRoute

    private struct Subscription: Hashable {
        let object: AudioObjectID
        let selector: AudioObjectPropertySelector
        let scope: AudioObjectPropertyScope
    }

    private let queue = DispatchQueue(label: "amamac.route", qos: .userInitiated)
    private let debounce: TimeInterval
    private let read: Reader
    private let listens: Bool
    private let handler: @Sendable (AudioRoute) -> Void
    private let deliveryQueue: DispatchQueue
    // Only touched on `queue`.
    private var watched: AudioObjectID?
    private var last: AudioRoute
    private var pending: DispatchWorkItem?
    private var subscriptions: Set<Subscription> = []
    private var listener: AudioObjectPropertyListenerBlock?

    /// Listens to Core Audio and calls `handler` on the main queue.
    public convenience init(debounce: TimeInterval = 0.4, handler: @escaping @Sendable (AudioRoute) -> Void) {
        self.init(debounce: debounce, read: { AudioRoute.read(output: $0) }, listens: true, deliveryQueue: .main, handler: handler)
    }

    /// `listens: false` (tests) leaves Core Audio alone; changes are then signalled with `noteChange`.
    init(debounce: TimeInterval, read: @escaping Reader, listens: Bool, deliveryQueue: DispatchQueue,
         handler: @escaping @Sendable (AudioRoute) -> Void) {
        self.debounce = debounce
        self.read = read
        self.listens = listens
        self.handler = handler
        self.deliveryQueue = deliveryQueue
        last = read(nil)
        guard listens else { return }
        listener = Self.listenerBlock(self)
        queue.sync { resubscribe() }
    }

    deinit {
        guard let listener else { return }
        for s in subscriptions {
            var address = CoreAudioProperty.address(s.selector, s.scope)
            AudioObjectRemovePropertyListenerBlock(s.object, &address, queue, listener)
        }
    }

    private static func listenerBlock(_ monitor: AudioRouteMonitor) -> AudioObjectPropertyListenerBlock {
        { [weak monitor] _, _ in monitor?.changed() }
    }

    /// The route as last delivered (or read at creation).
    public var current: AudioRoute { queue.sync { last } }

    /// The device playback is on; its rate, channels and presence are followed from now on.
    public func watchOutput(_ id: AudioObjectID?) {
        queue.async {
            guard self.watched != id else { return }
            self.watched = id
            self.changed()
        }
    }

    /// Something may have changed (tests; Core Audio listeners call this on `queue` themselves).
    func noteChange() { queue.async { self.changed() } }

    /// On `queue`.
    private func changed() {
        if listens { resubscribe() }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.deliver() }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    /// On `queue`.
    private func deliver() {
        pending = nil
        let route = read(watched)
        guard route != last else { return }
        last = route
        let handler = self.handler
        deliveryQueue.async { handler(route) }
    }

    /// Listens to the system object, the watched output device and every other process's input
    /// state; drops listeners for devices and processes that are gone. On `queue`.
    private func resubscribe() {
        guard let listener else { return }
        var wanted: Set<Subscription> = []
        let system = CoreAudioProperty.system
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyProcessObjectList] {
            wanted.insert(Subscription(object: system, selector: selector, scope: kAudioObjectPropertyScopeGlobal))
        }
        if let output = watched ?? AudioDevices.defaultOutputDevice() {
            wanted.insert(Subscription(object: output, selector: kAudioDevicePropertyNominalSampleRate, scope: kAudioObjectPropertyScopeGlobal))
            wanted.insert(Subscription(object: output, selector: kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput))
            wanted.insert(Subscription(object: output, selector: kAudioDevicePropertyDeviceIsAlive, scope: kAudioObjectPropertyScopeGlobal))
        }
        for process in CoreAudioProperty.objects(system, kAudioHardwarePropertyProcessObjectList) {
            wanted.insert(Subscription(object: process, selector: kAudioProcessPropertyIsRunningInput, scope: kAudioObjectPropertyScopeGlobal))
        }
        for s in subscriptions.subtracting(wanted) {
            var address = CoreAudioProperty.address(s.selector, s.scope)
            AudioObjectRemovePropertyListenerBlock(s.object, &address, queue, listener)
        }
        for s in wanted.subtracting(subscriptions) {
            var address = CoreAudioProperty.address(s.selector, s.scope)
            // A process or device can vanish between listing and listening; it is then simply not followed.
            if AudioObjectAddPropertyListenerBlock(s.object, &address, queue, listener) != noErr { wanted.remove(s) }
        }
        subscriptions = wanted
    }
}
