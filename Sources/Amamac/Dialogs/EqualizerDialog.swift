import AppKit
import SwiftUI
import AmamacCore

/// The equalizer state: on/off, the selected preset, preamp and band gains. Every change is saved
/// and applied to the engine at once.
@MainActor
@Observable
final class EqualizerController {
    private(set) var enabled: Bool
    private(set) var presetName: String
    private(set) var preamp: Double
    private(set) var bands: [Double]
    private(set) var userPresets: [EqualizerPreset]

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let engine: LocalAudioEngine

    init(settings: AppSettings, engine: LocalAudioEngine) {
        self.settings = settings
        self.engine = engine
        let stored = (settings.defaults.dictionary(forKey: AppSettings.Key.equalizerUserPresets) as? [String: [Double]]) ?? [:]
        let user = stored.map { EqualizerPreset(name: $0.key, values: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let name = settings.string(AppSettings.Key.equalizerPreset) ?? EqualizerPreset.zeroName
        let current = EqualizerPreset(name: name, preamp: settings.double(AppSettings.Key.equalizerPreamp),
                                      bands: (settings.defaults.array(forKey: AppSettings.Key.equalizerBands) as? [Double]) ?? [])
        enabled = settings.bool(AppSettings.Key.equalizerEnabled)
        presetName = name
        preamp = current.preamp
        bands = current.bands
        userPresets = user
        apply()
    }

    var presets: [EqualizerPreset] { EqualizerPreset.builtIn + userPresets }

    func isUserPreset(_ name: String) -> Bool { userPresets.contains { $0.name == name } }

    func setEnabled(_ on: Bool) {
        enabled = on
        persist()
    }

    func select(_ name: String) {
        let preset: EqualizerPreset?
        if name == EqualizerPreset.manualName {
            preset = (settings.defaults.array(forKey: AppSettings.Key.equalizerManual) as? [Double])
                .map { EqualizerPreset(name: name, values: $0) } ?? EqualizerPreset.builtIn(named: name)
        } else {
            preset = presets.first { $0.name == name }
        }
        guard let preset else { return }
        presetName = preset.name
        preamp = preset.preamp
        bands = preset.bands
        if !enabled { enabled = true }
        persist()
    }

    /// Moving a slider switches to Manual, which remembers the hand-made curve.
    func setBand(_ index: Int, _ value: Double) {
        guard bands.indices.contains(index) else { return }
        bands[index] = min(12, max(-12, value))
        becomeManual()
    }

    func setPreamp(_ value: Double) {
        preamp = min(12, max(-12, value))
        becomeManual()
    }

    func flatten() {
        bands = Array(repeating: 0, count: EqualizerPreset.bandCount)
        preamp = 0
        becomeManual()
    }

    private func becomeManual() {
        presetName = EqualizerPreset.manualName
        settings.set([preamp] + bands, AppSettings.Key.equalizerManual)
        persist()
    }

    /// Saves the current curve under `name`. Built-in names cannot be replaced.
    @discardableResult
    func saveUserPreset(named name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, EqualizerPreset.builtIn(named: name) == nil else { return false }
        userPresets.removeAll { $0.name == name }
        userPresets.append(EqualizerPreset(name: name, preamp: preamp, bands: bands))
        userPresets.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        presetName = name
        persist()
        return true
    }

    func deleteUserPreset(named name: String) {
        userPresets.removeAll { $0.name == name }
        if presetName == name { presetName = EqualizerPreset.manualName }
        persist()
    }

    private func persist() {
        settings.set(enabled, AppSettings.Key.equalizerEnabled)
        settings.set(presetName, AppSettings.Key.equalizerPreset)
        settings.set(preamp, AppSettings.Key.equalizerPreamp)
        settings.set(bands, AppSettings.Key.equalizerBands)
        settings.set(Dictionary(uniqueKeysWithValues: userPresets.map { ($0.name, $0.values) }), AppSettings.Key.equalizerUserPresets)
        apply()
    }

    private func apply() {
        engine.setEqualizer(enabled: enabled, preamp: Float(preamp), bands: bands.map(Float.init))
    }

    static func frequencyLabel(_ hz: Float) -> String {
        hz >= 1000 ? (hz.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int(hz / 1000))k" : String(format: "%.1fk", hz / 1000)) : "\(Int(hz))"
    }
}

struct EqualizerView: View {
    let eq: EqualizerController
    @State private var saving = false
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle("Enable equalizer", isOn: Binding(get: { eq.enabled }, set: { eq.setEnabled($0) }))
                Spacer()
                Picker("Preset", selection: Binding(get: { eq.presetName }, set: { eq.select($0) })) {
                    ForEach(EqualizerPreset.builtIn) { Text($0.name).tag($0.name) }
                    if !eq.userPresets.isEmpty {
                        Divider()
                        ForEach(eq.userPresets) { Text($0.name).tag($0.name) }
                    }
                }
                .fixedSize()
                Button("Save…") {
                    newName = eq.isUserPreset(eq.presetName) ? eq.presetName : ""
                    saving = true
                }
                Button("Delete") { eq.deleteUserPreset(named: eq.presetName) }
                    .disabled(!eq.isUserPreset(eq.presetName))
            }
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .trailing) {
                    Text("+12 dB")
                    Spacer()
                    Text("0 dB")
                    Spacer()
                    Text("-12 dB")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(height: 180)
                .padding(.top, 18)
                band("Preamp", value: eq.preamp) { eq.setPreamp($0) }
                Divider().frame(height: 220)
                ForEach(eq.bands.indices, id: \.self) { i in
                    band(EqualizerController.frequencyLabel(LocalAudioEngine.equalizerFrequencies[i]), value: eq.bands[i]) { eq.setBand(i, $0) }
                }
            }
            .disabled(!eq.enabled)
            .opacity(eq.enabled ? 1 : 0.5)
            HStack {
                Text("Bands are in Hz. Moving a slider switches to the Manual preset.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Flat") { eq.flatten() }.disabled(!eq.enabled)
            }
        }
        .padding(16)
        .fixedSize()
        .sheet(isPresented: $saving) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Save Equalizer Preset").font(.headline)
                TextField("Preset name", text: $newName)
                if EqualizerPreset.builtIn(named: newName.trimmingCharacters(in: .whitespaces)) != nil {
                    Text("Built-in presets cannot be replaced.").font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { saving = false }.keyboardShortcut(.cancelAction)
                    Button("Save") {
                        if eq.saveUserPreset(named: newName) { saving = false }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty
                              || EqualizerPreset.builtIn(named: newName.trimmingCharacters(in: .whitespaces)) != nil)
                }
            }
            .padding(16)
            .frame(width: 320)
        }
    }

    private func band(_ label: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        VStack(spacing: 4) {
            Text(String(format: "%+.1f", value)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            VerticalSlider(value: value, range: EqualizerPreset.range, onChange: set)
                .frame(width: 26, height: 180)
            Text(label).font(.caption2)
        }
        .frame(width: label == "Preamp" ? 44 : 34)
    }
}

/// AppKit's vertical slider (SwiftUI has none). Values snap to 0.5 dB.
struct VerticalSlider: NSViewRepresentable {
    var value: Double
    var range: ClosedRange<Double>
    var onChange: (Double) -> Void

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound,
                              target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.isVertical = true
        slider.numberOfTickMarks = 5
        slider.isContinuous = true
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.onChange = onChange
        if abs(slider.doubleValue - value) > 0.01 { slider.doubleValue = value }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onChange) }

    final class Coordinator: NSObject {
        var onChange: (Double) -> Void
        init(_ onChange: @escaping (Double) -> Void) { self.onChange = onChange }
        @objc func changed(_ sender: NSSlider) { onChange((sender.doubleValue * 2).rounded() / 2) }
    }
}

enum EqualizerWindow {
    private static var window: NSWindow?

    static func show(env: AppEnvironment) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: EqualizerView(eq: env.equalizer))
        host.sizingOptions = [.preferredContentSize]
        let w = NSWindow(contentViewController: host)
        w.title = "Equalizer"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { window = nil }
        }
        w.makeKeyAndOrderFront(nil)
    }
}
