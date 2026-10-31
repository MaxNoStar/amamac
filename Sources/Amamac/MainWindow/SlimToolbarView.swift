import AppKit

/// Amarok's "Slim Toolbar": Prev / Play-Pause / Stop / Next, title, progress and a volume popup.
final class SlimToolbarView: NSView {
    private let prev = NSButton()
    private let play = NSButton()
    private let stop = NSButton()
    private let next = NSButton()
    private let title = NSTextField(labelWithString: "")
    private let slider = SeekSlider()
    private let elapsed = ClickableTimeLabel(alignment: .right)
    private let remaining = ClickableTimeLabel(alignment: .left)
    private let volume = NSButton()
    private weak var player: PlayerController?

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("slimToolbar")
        for (button, symbol, label) in [(prev, "backward.fill", "Previous"), (play, "play.fill", "Play/Pause"),
                                        (stop, "stop.fill", "Stop"), (next, "forward.fill", "Next"),
                                        (volume, "speaker.wave.2.fill", "Volume")] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.bezelStyle = .toolbar
            button.isBordered = false
            button.toolTip = label
            button.target = self
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        prev.action = #selector(doPrev)
        play.action = #selector(doPlay)
        stop.action = #selector(doStop)
        next.action = #selector(doNext)
        volume.action = #selector(showVolume(_:))
        title.font = .boldSystemFont(ofSize: 12)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true
        let stack = NSStackView(views: [prev, play, stop, next, title, elapsed, slider, remaining, volume])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 34),
            elapsed.widthAnchor.constraint(equalToConstant: 44),
            remaining.widthAnchor.constraint(equalToConstant: 48),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func bind(player: PlayerController) {
        self.player = player
        slider.onSeek = { player.seek(to: $0) }
    }

    func refresh() {
        guard let player else { return }
        let playing = player.state == .playing || player.state == .buffering
        play.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: "Play/Pause")
        title.stringValue = player.currentItem.map { [$0.streamTitle ?? $0.track.displayTitle, $0.track.artist].filter { !$0.isEmpty }.joined(separator: " – ") } ?? ""
        volume.image = NSImage(systemSymbolName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", accessibilityDescription: "Volume")
        refreshTime()
    }

    func refreshTime() {
        guard let player, !isHidden else { return }
        slider.duration = player.duration
        slider.position = player.currentTime
        slider.isEnabled = player.isActive
        elapsed.stringValue = player.isActive ? TimeFormattingBridge.format(player.currentTime) : ""
        remaining.stringValue = player.isActive && player.duration > 0 ? "-" + TimeFormattingBridge.format(player.duration - player.currentTime) : ""
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    @objc private func doPrev() { player?.previous() }
    @objc private func doPlay() { player?.playPause() }
    @objc private func doStop() { player?.stop() }
    @objc private func doNext() { player?.next() }

    @objc private func showVolume(_ sender: NSButton) {
        guard let player else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        let vc = NSViewController()
        let slider = NSSlider(value: Double(player.volume), minValue: 0, maxValue: 100, target: nil, action: nil)
        slider.isVertical = true
        let mute = NSButton(checkboxWithTitle: "Mute", target: nil, action: nil)
        mute.state = player.isMuted ? .on : .off
        let handler = SliderHandler(player: player)
        slider.target = handler
        slider.action = #selector(SliderHandler.changed(_:))
        mute.target = handler
        mute.action = #selector(SliderHandler.mute(_:))
        let stack = NSStackView(views: [slider, mute])
        stack.orientation = .vertical
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        slider.heightAnchor.constraint(equalToConstant: 120).isActive = true
        vc.view = stack
        objc_setAssociatedObject(vc, "handler", handler, .OBJC_ASSOCIATION_RETAIN)
        popover.contentViewController = vc
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let player else { return }
        player.setVolume(player.volume + Int((event.scrollingDeltaY / (event.hasPreciseScrollingDeltas ? 4 : 0.5)).rounded()))
    }

    private final class SliderHandler: NSObject {
        let player: PlayerController
        init(player: PlayerController) { self.player = player }
        @objc func changed(_ sender: NSSlider) { player.setVolume(Int(sender.doubleValue)) }
        @objc func mute(_ sender: NSButton) { player.toggleMute() }
    }
}
