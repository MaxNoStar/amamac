import AmamacBase
import AppKit

/// Amarok's large round Play/Pause button.
final class PlayPauseButton: NSControl {
    var isPlaying = false { didSet { needsDisplay = true; setAccessibilityLabel(isPlaying ? "Pause" : "Play") } }
    private var pressed = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Play")
        toolTip = "Play/Pause"
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 48, height: 48) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 2, dy: 2)
        let circle = NSBezierPath(ovalIn: rect)
        let accent = NSColor.amamacAccent
        let top = accent.blended(withFraction: pressed ? 0.25 : 0.0, of: .black) ?? accent
        let bottom = accent.blended(withFraction: pressed ? 0.45 : 0.25, of: .black) ?? accent
        NSGradient(starting: top, ending: bottom)?.draw(in: circle, angle: -90)
        NSColor.black.withAlphaComponent(0.15).setStroke()
        circle.lineWidth = 1
        circle.stroke()
        let symbol = isPlaying ? "pause.fill" : "play.fill"
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .bold).applying(.init(paletteColors: [.white]))
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            var r = NSRect(origin: .zero, size: image.size)
            r.origin.x = bounds.midX - r.width / 2 + (isPlaying ? 0 : 2)
            r.origin.y = bounds.midY - r.height / 2
            image.draw(in: r)
        }
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            let inside = bounds.contains(convert(next.locationInWindow, from: nil))
            pressed = inside
            if next.type == .leftMouseUp {
                pressed = false
                if inside { sendAction(action, to: target) }
                break
            }
        }
    }
}

/// Amarok's circular volume dial: the arc fills clockwise from the bottom left; click the speaker
/// to mute, drag or scroll to change.
final class VolumeDial: NSControl {
    var volume = 80 { didSet { needsDisplay = true; updateAccessibility() } }
    var isMuted = false { didSet { needsDisplay = true; updateAccessibility() } }
    var onChange: ((Int) -> Void)?
    var onToggleMute: (() -> Void)?
    private var dragStart: (y: CGFloat, value: Int)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.slider)
        updateAccessibility()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateAccessibility() {
        setAccessibilityLabel("Volume")
        setAccessibilityValue(isMuted ? "Muted" : "\(volume)%")
        toolTip = isMuted ? "Volume: muted" : "Volume: \(volume)%"
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 48, height: 48) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static let startAngle: CGFloat = 225   // bottom-left
    static let sweep: CGFloat = 270

    override func draw(_ dirtyRect: NSRect) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) / 2 - 4
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: Self.startAngle, endAngle: Self.startAngle - Self.sweep, clockwise: true)
        track.lineWidth = 4
        track.lineCapStyle = .round
        NSColor.tertiaryLabelColor.setStroke()
        track.stroke()
        if volume > 0 {
            let fill = NSBezierPath()
            let end = Self.startAngle - Self.sweep * CGFloat(volume) / 100
            fill.appendArc(withCenter: center, radius: radius, startAngle: Self.startAngle, endAngle: end, clockwise: true)
            fill.lineWidth = 4
            fill.lineCapStyle = .round
            (isMuted ? NSColor.secondaryLabelColor : NSColor.amamacAccent).setStroke()
            fill.stroke()
        }
        let symbol = isMuted || volume == 0 ? "speaker.slash.fill" : (volume < 34 ? "speaker.wave.1.fill" : (volume < 67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"))
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular).applying(.init(paletteColors: [.labelColor]))
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            image.draw(in: NSRect(x: center.x - image.size.width / 2, y: center.y - image.size.height / 2,
                                  width: image.size.width, height: image.size.height))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        if hypot(p.x - center.x, p.y - center.y) < 10 && event.clickCount == 1 {
            // Mute on click in the centre (if the mouse doesn't move).
            if let up = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]), up.type == .leftMouseUp {
                onToggleMute?()
                return
            }
        }
        dragStart = (event.locationInWindow.y, volume)
        setFromPoint(p)
    }

    override func mouseDragged(with event: NSEvent) {
        setFromPoint(convert(event.locationInWindow, from: nil))
    }

    private func setFromPoint(_ p: NSPoint) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        var angle = atan2(p.y - center.y, p.x - center.x) * 180 / .pi   // -180...180, 0 = right
        if angle < -45 - 1 && angle > -135 + 1 {
            // Bottom gap: snap to nearest end.
            angle = p.x < center.x ? Self.startAngle : Self.startAngle - Self.sweep
        }
        var delta = Self.startAngle - angle
        while delta < 0 { delta += 360 }
        while delta > 360 { delta -= 360 }
        let value = Int((min(Self.sweep, delta) / Self.sweep * 100).rounded())
        onChange?(value)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 4 : event.scrollingDeltaY * 2
        onChange?(max(0, min(100, volume + Int(delta.rounded()))))
    }
}

/// The seek slider with position-marker triangles (seeks on release, like Amarok).
final class SeekSlider: NSView {
    var duration: TimeInterval = 0 { didSet { needsDisplay = true } }
    var position: TimeInterval = 0 { didSet { if dragPosition == nil { needsDisplay = true } } }
    var markers: [TimeInterval] = [] { didSet { needsDisplay = true } }
    var isEnabled = true { didSet { needsDisplay = true } }
    var onSeek: ((TimeInterval) -> Void)?
    var onMarkerClick: ((TimeInterval) -> Void)?
    private var dragPosition: TimeInterval?
    private var hoverX: CGFloat?
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Track position")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 18) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    private var trackRect: NSRect { bounds.insetBy(dx: 6, dy: 0).insetBy(dx: 0, dy: (bounds.height - 6) / 2) }

    private func x(for time: TimeInterval) -> CGFloat {
        guard duration > 0 else { return trackRect.minX }
        return trackRect.minX + trackRect.width * CGFloat(min(1, max(0, time / duration)))
    }

    private func time(for x: CGFloat) -> TimeInterval {
        guard duration > 0 else { return 0 }
        return duration * TimeInterval(max(0, min(1, (x - trackRect.minX) / trackRect.width)))
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = trackRect
        let path = NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setFill()
        path.fill()
        let active = isEnabled && duration > 0
        let pos = dragPosition ?? position
        if active {
            var filled = track
            filled.size.width = x(for: pos) - track.minX
            NSColor.amamacAccent.setFill()
            NSBezierPath(roundedRect: filled, xRadius: 3, yRadius: 3).fill()
        }
        // Position markers (bookmarks) as small triangles above the track.
        NSColor.systemOrange.setFill()
        for marker in markers where duration > 0 {
            let mx = x(for: marker)
            let tri = NSBezierPath()
            tri.move(to: NSPoint(x: mx - 4, y: bounds.maxY))
            tri.line(to: NSPoint(x: mx + 4, y: bounds.maxY))
            tri.line(to: NSPoint(x: mx, y: track.maxY))
            tri.close()
            tri.fill()
        }
        if active {
            let knob = NSRect(x: x(for: pos) - 6, y: bounds.midY - 6, width: 12, height: 12)
            let knobPath = NSBezierPath(ovalIn: knob)
            NSColor.white.setFill()
            knobPath.fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            knobPath.lineWidth = 0.5
            knobPath.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, duration > 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let marker = markers.first(where: { abs(x(for: $0) - p.x) < 5 && p.y > trackRect.maxY }) {
            onMarkerClick?(marker)
            return
        }
        dragPosition = time(for: p.x)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragPosition != nil else { return }
        dragPosition = time(for: convert(event.locationInWindow, from: nil).x)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let target = dragPosition else { return }
        dragPosition = nil
        position = target
        onSeek?(target)
    }

    override func mouseMoved(with event: NSEvent) {
        guard duration > 0 else { toolTip = nil; return }
        toolTip = TimeFormatting.duration(time(for: convert(event.locationInWindow, from: nil).x))
    }

    override func scrollWheel(with event: NSEvent) {
        guard isEnabled, duration > 0, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else {
            nextResponder?.scrollWheel(with: event)
            return
        }
        onSeek?(max(0, position - TimeInterval(event.scrollingDeltaX) / 4))
    }
}

/// Time label that swaps elapsed / remaining when clicked.
final class ClickableTimeLabel: NSTextField {
    var onClick: (() -> Void)?

    convenience init(alignment: NSTextAlignment) {
        self.init(labelWithString: "")
        self.alignment = alignment
        font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        textColor = .secondaryLabelColor
        setContentHuggingPriority(.required, for: .horizontal)
        toolTip = "Click to switch between elapsed and remaining time"
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}
