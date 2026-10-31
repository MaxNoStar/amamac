import SwiftUI

/// The analyzer's configuration popover. Bar width and fade bars appear only for the styles they
/// change.
struct AnalyzerSettingsView: View {
    @AppStorage private var style: String
    @AppStorage private var palette: String
    @AppStorage private var barWidth: Double
    @AppStorage private var fallSpeed: Int
    @AppStorage private var fadebars: Bool
    @AppStorage private var sampleSize: Int
    @AppStorage private var minFrequency: Double
    @AppStorage private var maxFrequency: Double

    init(defaults: UserDefaults) {
        _style = AppStorage(wrappedValue: AnalyzerStyle.neonBars.rawValue, AppSettings.Key.analyzerStyle, store: defaults)
        _palette = AppStorage(wrappedValue: AnalyzerPalette.neon.rawValue, AppSettings.Key.analyzerPalette, store: defaults)
        _barWidth = AppStorage(wrappedValue: 8, AppSettings.Key.analyzerBarWidth, store: defaults)
        _fallSpeed = AppStorage(wrappedValue: 3, AppSettings.Key.analyzerFallSpeed, store: defaults)
        _fadebars = AppStorage(wrappedValue: true, AppSettings.Key.analyzerShowFadebars, store: defaults)
        _sampleSize = AppStorage(wrappedValue: 4096, AppSettings.Key.analyzerSampleSize, store: defaults)
        _minFrequency = AppStorage(wrappedValue: 40, AppSettings.Key.analyzerMinFrequency, store: defaults)
        _maxFrequency = AppStorage(wrappedValue: 16_000, AppSettings.Key.analyzerMaxFrequency, store: defaults)
    }

    private var current: AnalyzerStyle { AnalyzerStyle(rawValue: style) ?? .neonBars }

    var body: some View {
        Form {
            Picker("Style", selection: $style) {
                ForEach(AnalyzerStyle.allCases) { Label($0.title, systemImage: $0.symbol).tag($0.rawValue) }
            }
            LabeledContent("Colours") { PaletteSwatches(selection: $palette) }
            if current.usesBarWidth {
                Slider(value: $barWidth, in: 3...20, step: 1) { Text("Bar width") }
            }
            Picker("Fall speed", selection: $fallSpeed) {
                Text("Very slow").tag(1); Text("Slow").tag(2); Text("Medium").tag(3); Text("Fast").tag(4); Text("Very fast").tag(5)
            }
            if current.usesFadeBars {
                Toggle("Show fade bars", isOn: $fadebars)
            }
            Picker("Lowest frequency", selection: $minFrequency) {
                ForEach([20.0, 40, 80, 160], id: \.self) { Text("\(Int($0)) Hz").tag($0) }
            }
            Picker("Highest frequency", selection: $maxFrequency) {
                ForEach([5_000.0, 10_000, 16_000, 20_000], id: \.self) { Text("\(Int($0 / 1000)) kHz").tag($0) }
            }
            Picker("Sample size", selection: $sampleSize) {
                ForEach([1024, 2048, 4096, 8192], id: \.self) { Text("\($0)").tag($0) }
            }
        }
        .frame(width: 300)
    }
}

/// One gradient swatch per palette; the chosen one is ringed.
private struct PaletteSwatches: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AnalyzerPalette.allCases) { palette in
                let selected = palette.rawValue == selection
                Button { selection = palette.rawValue } label: {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(LinearGradient(gradient: palette.gradient(), startPoint: .leading, endPoint: .trailing))
                        .frame(width: 32, height: 16)
                        .padding(2)
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: selected ? 2 : 1))
                }
                .buttonStyle(.plain)
                .help(palette.title)
                .accessibilityLabel(palette.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        // Line the row's middle up with the label's text.
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
    }
}
