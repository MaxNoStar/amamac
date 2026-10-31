import AmamacBase
import AmamacModels
import AppKit

/// Previous / current / next track labels. The side labels are dimmed and skip when clicked;
/// dragging past a fifth of the width skips; track changes slide in.
final class TrackLabelCarousel: NSView {
    struct Labels: Equatable {
        var previous: String?
        var currentTitle: String
        var currentDetail: String?
        var next: String?
        var previousID: PlaylistItemID?
        var nextID: PlaylistItemID?
        var currentID: PlaylistItemID?
    }

    var labels = Labels(currentTitle: "Rediscover Your Music") { didSet { labelsChanged(from: oldValue) } }
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onCurrentClicked: (() -> Void)?

    private var offset: CGFloat = 0 { didSet { needsDisplay = true } }
    private var dragStartX: CGFloat?
    private var hoverZone: Int? { didSet { if hoverZone != oldValue { needsDisplay = true } } }
    private var animationTimer: Timer?
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 26) }
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    private var sideWidth: CGFloat { bounds.width * 0.22 }
    private var currentRect: NSRect { NSRect(x: sideWidth, y: 0, width: bounds.width - 2 * sideWidth, height: bounds.height) }

    private func labelsChanged(from old: Labels) {
        setAccessibilityValue(labels.currentTitle + (labels.currentDetail.map { " " + $0 } ?? ""))
        toolTip = labels.currentDetail.map { labels.currentTitle + " " + $0 } ?? labels.currentTitle
        // Slide in the direction of travel.
        if let id = labels.currentID, id != old.currentID {
            if id == old.nextID { animate(from: bounds.width * 0.5) } else if id == old.previousID { animate(from: -bounds.width * 0.5) }
        }
        needsDisplay = true
    }

    private func animate(from start: CGFloat) {
        animationTimer?.invalidate()
        offset = start
        let begin = Date()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] timer in
            let finished = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return true }
                let t = min(1, Date().timeIntervalSince(begin) / 0.25)
                let eased = 1 - pow(1 - t, 3)
                self.offset = start * (1 - eased)
                return t >= 1
            }
            if finished { timer.invalidate() }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = .center

        // Current label: bold title + detail.
        var currentFrame = currentRect.offsetBy(dx: offset, dy: 0)
        currentFrame.origin.y = 3
        let current = NSMutableAttributedString(string: labels.currentTitle, attributes: [
            .font: NSFont.boldSystemFont(ofSize: 15), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ])
        if let detail = labels.currentDetail, !detail.isEmpty {
            current.append(NSAttributedString(string: "  " + detail, attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph,
            ]))
        }
        current.draw(with: currentFrame.insetBy(dx: 8, dy: 0), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

        // Side labels.
        func side(_ text: String?, leading: Bool, zone: Int) {
            guard let text, !text.isEmpty else { return }
            let p = NSMutableParagraphStyle()
            p.lineBreakMode = .byTruncatingTail
            p.alignment = leading ? .left : .right
            let alpha: CGFloat = hoverZone == zone ? 1 : (leading ? 0.5 : 0.62)
            let arrow = leading ? "◂ " : ""
            let tail = leading ? "" : " ▸"
            let s = NSAttributedString(string: arrow + text + tail, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor.withAlphaComponent(alpha), .paragraphStyle: p,
            ])
            var rect = leading ? NSRect(x: 4, y: 6, width: sideWidth - 8, height: bounds.height - 6)
                               : NSRect(x: bounds.width - sideWidth + 4, y: 6, width: sideWidth - 8, height: bounds.height - 6)
            rect = rect.offsetBy(dx: offset, dy: 0)
            s.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        side(labels.previous, leading: true, zone: 0)
        side(labels.next, leading: false, zone: 2)
    }

    private func zone(at p: NSPoint) -> Int {
        if p.x < sideWidth { return 0 }
        if p.x > bounds.width - sideWidth { return 2 }
        return 1
    }

    override func mouseMoved(with event: NSEvent) {
        let z = zone(at: convert(event.locationInWindow, from: nil))
        hoverZone = (z == 0 && labels.previous != nil) || (z == 2 && labels.next != nil) ? z : nil
    }

    override func mouseExited(with event: NSEvent) { hoverZone = nil }

    override func mouseDown(with event: NSEvent) {
        dragStartX = convert(event.locationInWindow, from: nil).x
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartX else { return }
        offset = convert(event.locationInWindow, from: nil).x - start
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        defer { dragStartX = nil }
        let moved = offset
        if abs(moved) > 4 {
            if moved < -bounds.width / 5, labels.next != nil {
                onNext?()
            } else if moved > bounds.width / 5, labels.previous != nil {
                onPrevious?()
            }
            animate(from: offset)
            return
        }
        offset = 0
        switch zone(at: p) {
        case 0: if labels.previous != nil { onPrevious?() }
        case 2: if labels.next != nil { onNext?() }
        default: onCurrentClicked?()
        }
    }
}

/// Amarok 2/3 "Main Toolbar": big Play/Pause, track label carousel with position-marker action,
/// elapsed / seek slider / remaining, and the volume dial.
final class MainToolbarView: NSView {
    let playButton = PlayPauseButton()
    let carousel = TrackLabelCarousel()
    let markerButton = NSButton()
    let slider = SeekSlider()
    let elapsedLabel = ClickableTimeLabel(alignment: .right)
    let remainingLabel = ClickableTimeLabel(alignment: .left)
    let volumeDial = VolumeDial()
    private var showRemainingOnLeft = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("mainToolbar")
        markerButton.image = NSImage(systemSymbolName: "flag", accessibilityDescription: "Add Position Marker")
        markerButton.isBordered = false
        markerButton.toolTip = "Add Position Marker"
        markerButton.contentTintColor = .secondaryLabelColor
        markerButton.setContentHuggingPriority(.required, for: .horizontal)
        elapsedLabel.stringValue = ""
        remainingLabel.stringValue = ""

        let timeRow = NSStackView(views: [elapsedLabel, slider, remainingLabel])
        timeRow.spacing = 6
        timeRow.orientation = .horizontal
        elapsedLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true
        remainingLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true

        let labelRow = NSStackView(views: [carousel, markerButton])
        labelRow.orientation = .horizontal
        labelRow.spacing = 2

        let info = NSStackView(views: [labelRow, timeRow])
        info.orientation = .vertical
        info.spacing = 2
        info.alignment = .leading
        labelRow.leadingAnchor.constraint(equalTo: info.leadingAnchor).isActive = true
        labelRow.trailingAnchor.constraint(equalTo: info.trailingAnchor).isActive = true
        timeRow.leadingAnchor.constraint(equalTo: info.leadingAnchor).isActive = true
        timeRow.trailingAnchor.constraint(equalTo: info.trailingAnchor).isActive = true

        for v in [playButton, info, volumeDial] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            playButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            playButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 48),
            playButton.heightAnchor.constraint(equalToConstant: 48),
            info.leadingAnchor.constraint(equalTo: playButton.trailingAnchor, constant: 12),
            info.trailingAnchor.constraint(equalTo: volumeDial.leadingAnchor, constant: -12),
            info.centerYAnchor.constraint(equalTo: centerYAnchor),
            volumeDial.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -15),
            volumeDial.centerYAnchor.constraint(equalTo: centerYAnchor),
            volumeDial.widthAnchor.constraint(equalToConstant: 48),
            volumeDial.heightAnchor.constraint(equalToConstant: 48),
            heightAnchor.constraint(equalToConstant: 68),
        ])
        elapsedLabel.onClick = { [weak self] in self?.toggleTimeDisplay() }
        remainingLabel.onClick = { [weak self] in self?.toggleTimeDisplay() }
    }

    required init?(coder: NSCoder) { fatalError() }

    var onTimeDisplayToggled: ((Bool) -> Void)?

    func setTimeDisplayRemainingLeft(_ value: Bool) { showRemainingOnLeft = value }

    private func toggleTimeDisplay() {
        showRemainingOnLeft.toggle()
        onTimeDisplayToggled?(showRemainingOnLeft)
        updateTime(position: slider.position, duration: slider.duration, active: slider.isEnabled)
    }

    func updateTime(position: TimeInterval, duration: TimeInterval, active: Bool) {
        slider.duration = duration
        slider.position = position
        slider.isEnabled = active && duration > 0
        guard active else {
            elapsedLabel.stringValue = ""
            remainingLabel.stringValue = ""
            return
        }
        let elapsed = TimeFormatting.duration(position)
        let remaining = duration > 0 ? "-" + TimeFormatting.duration(max(0, duration - position)) : ""
        elapsedLabel.stringValue = showRemainingOnLeft ? remaining : elapsed
        remainingLabel.stringValue = showRemainingOnLeft ? elapsed : remaining
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    override func scrollWheel(with event: NSEvent) {
        // Scrolling anywhere on the toolbar changes the volume (as in Amarok).
        volumeDial.scrollWheel(with: event)
    }
}
