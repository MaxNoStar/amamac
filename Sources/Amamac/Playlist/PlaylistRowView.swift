import AppKit
import AmamacCore

/// What kind of row a playlist entry renders as.
enum PlaylistRowKind: Equatable {
    /// A group of one track, or grouping disabled.
    case single
    /// First track of a group: header + body line(s).
    case head
    case body
}

/// Everything a row needs to draw itself.
struct PlaylistRowModel {
    var item: PlaylistItem
    var kind: PlaylistRowKind
    var layout: PlaylistLayout
    var isActive: Bool
    var playerState: PlayerController.State
    var queuePosition: Int?
    var isStopAfter: Bool
    var isSearchMatch: Bool
    var indexInGroup: Int
    var groupTrackCount: Int
    var groupLength: TimeInterval
    var cover: NSImage?
}

enum PlaylistMetrics {
    static let lineHeight: CGFloat = 17
    static let margin: CGFloat = 22
    static let headPadding: CGFloat = 6
    static let coverSize: CGFloat = 44

    static func headHeight(_ layout: PlaylistLayout) -> CGFloat {
        let textHeight = CGFloat(layout.head.count) * lineHeight
        let cover = layout.showCover ? coverSize : 0
        return max(textHeight, cover) + headPadding * 2
    }

    static func bodyHeight(_ lines: [LayoutLine]) -> CGFloat {
        CGFloat(max(1, lines.count)) * lineHeight + 4
    }

    static func height(kind: PlaylistRowKind, layout: PlaylistLayout) -> CGFloat {
        switch kind {
        case .single:
            let base = bodyHeight(layout.single)
            return layout.showCover && layout.single.count > 1 ? max(base, 38) : base
        case .head: return headHeight(layout) + bodyHeight(layout.body)
        case .body: return bodyHeight(layout.body)
        }
    }
}

/// Draws one playlist entry (group header, track line(s), state indicators) without subviews.
final class PlaylistRowView: NSTableRowView {
    var model: PlaylistRowModel? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    /// The part of the row that represents the track itself (selection is drawn only here).
    var trackRect: NSRect {
        guard let model, model.kind == .head else { return bounds }
        let head = PlaylistMetrics.headHeight(model.layout)
        return NSRect(x: 0, y: head, width: bounds.width, height: bounds.height - head)
    }

    var headRect: NSRect? {
        guard let model, model.kind == .head else { return nil }
        return NSRect(x: 0, y: 0, width: bounds.width, height: PlaylistMetrics.headHeight(model.layout))
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard let model else { return }
        let track = trackRect
        if model.kind != .head && model.indexInGroup % 2 == 1 || (model.kind == .single && model.indexInGroup % 2 == 1) {
            NSColor.alternatingContentBackgroundColors.last?.setFill()
            track.fill()
        }
        if let head = headRect {
            let gradient = NSGradient(starting: NSColor.controlBackgroundColor,
                                      ending: NSColor.underPageBackgroundColor.withAlphaComponent(0.6))
            gradient?.draw(in: head, angle: 90)
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        }
        if model.isActive {
            let rect = track.insetBy(dx: 2, dy: 1)
            NSColor.amamacAccent.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        }
        if model.isSearchMatch {
            NSColor.systemYellow.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: track.insetBy(dx: 2, dy: 1), xRadius: 4, yRadius: 4).fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let rect = trackRect.insetBy(dx: 2, dy: 1)
        (isEmphasized ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { isSelected && isEmphasized ? .emphasized : .normal }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let model else { return }
        let selected = isSelected && isEmphasized
        if let head = headRect { drawHead(model, in: head, selected: false) }
        let track = trackRect
        let lines = model.kind == .single ? model.layout.single : model.layout.body
        var contentRect = track.insetBy(dx: 0, dy: 2)
        contentRect.origin.x = PlaylistMetrics.margin
        contentRect.size.width = bounds.width - PlaylistMetrics.margin - 6
        if model.kind == .single && model.layout.showCover && lines.count > 1 {
            let size = min(contentRect.height - 2, 34)
            let coverRect = NSRect(x: contentRect.minX, y: track.minY + (track.height - size) / 2, width: size, height: size)
            drawCover(model.cover, in: coverRect)
            contentRect.origin.x += size + 6
            contentRect.size.width -= size + 6
        }
        for (i, line) in lines.enumerated() {
            let lineRect = NSRect(x: contentRect.minX, y: contentRect.minY + CGFloat(i) * PlaylistMetrics.lineHeight,
                                  width: contentRect.width, height: PlaylistMetrics.lineHeight)
            drawLine(line, model: model, in: lineRect, selected: selected, dimmed: i > 0)
        }
        drawIndicators(model, in: NSRect(x: 2, y: track.minY, width: PlaylistMetrics.margin - 4, height: min(track.height, PlaylistMetrics.lineHeight + 4)), selected: selected)
    }

    private func drawHead(_ model: PlaylistRowModel, in rect: NSRect, selected: Bool) {
        var textRect = rect.insetBy(dx: 8, dy: PlaylistMetrics.headPadding)
        if model.layout.showCover {
            let size = PlaylistMetrics.coverSize
            let coverRect = NSRect(x: rect.minX + 8, y: rect.minY + (rect.height - size) / 2, width: size, height: size)
            drawCover(model.cover, in: coverRect)
            textRect.origin.x = coverRect.maxX + 8
            textRect.size.width = rect.maxX - textRect.minX - 8
        }
        let total = CGFloat(model.layout.head.count) * PlaylistMetrics.lineHeight
        var y = rect.minY + (rect.height - total) / 2
        for line in model.layout.head {
            drawLine(line, model: model, in: NSRect(x: textRect.minX, y: y, width: textRect.width, height: PlaylistMetrics.lineHeight),
                     selected: selected, dimmed: false)
            y += PlaylistMetrics.lineHeight
        }
    }

    private func drawCover(_ image: NSImage?, in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        clip.addClip()
        if let image {
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            NSColor.quaternaryLabelColor.setFill()
            rect.fill()
            if let disc = NSImage(systemSymbolName: "opticaldisc", accessibilityDescription: nil) {
                let s = rect.width * 0.5
                disc.draw(in: NSRect(x: rect.midX - s / 2, y: rect.midY - s / 2, width: s, height: s), from: .zero,
                          operation: .sourceOver, fraction: 0.4, respectFlipped: true, hints: nil)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.15).setStroke()
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: 3, yRadius: 3)
        border.lineWidth = 0.5
        border.stroke()
    }

    private func drawLine(_ line: LayoutLine, model: PlaylistRowModel, in rect: NSRect, selected: Bool, dimmed: Bool) {
        let fixed = line.reduce(0) { $0 + $1.width }
        let flexible = line.filter { $0.width == 0 }.count
        let remaining = max(0, 1 - fixed)
        var x = rect.minX
        for token in line {
            let fraction = token.width > 0 ? token.width : (flexible > 0 ? remaining / Double(flexible) : 0)
            let width = rect.width * CGFloat(fraction)
            let tokenRect = NSRect(x: x, y: rect.minY, width: width - 4, height: rect.height)
            x += width
            let text = tokenText(token, model: model)
            guard !text.isEmpty else { continue }
            var font = NSFont.systemFont(ofSize: 12, weight: token.bold ? .semibold : .regular)
            if token.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            if token.column == .length || token.column == .groupLength { font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular) }
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            style.alignment = token.alignment == .center ? .center : (token.alignment == .right ? .right : .left)
            let color: NSColor = selected ? .alternateSelectedControlTextColor
                : (dimmed || token.column == .length ? .secondaryLabelColor : .labelColor)
            let attributed = NSAttributedString(string: token.prefix + text + token.suffix, attributes: [
                .font: font, .foregroundColor: token.column == .rating && !selected ? NSColor.systemOrange : color,
                .paragraphStyle: style,
            ])
            attributed.draw(with: tokenRect.offsetBy(dx: 0, dy: 1), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    private func tokenText(_ token: LayoutToken, model: PlaylistRowModel) -> String {
        switch token.column {
        case .groupTracks: return "\(model.groupTrackCount)"
        case .groupLength: return TimeFormattingBridge.format(model.groupLength)
        case .rating: return Self.stars(model.item.statistics?.rating ?? 0)
        case .album where model.item.isStream: return model.kind == .head ? model.item.track.displayTitle : ""
        case .albumArtist where model.item.isStream: return model.kind == .head ? "Stream" : ""
        default:
            let text = token.column.text(for: model.item)
            if text.isEmpty {
                switch token.column {
                case .album: return model.item.isStream ? "" : TrackText.unknownAlbum
                case .albumArtist, .artist: return model.item.isStream ? "" : TrackText.unknownArtist
                default: return ""
                }
            }
            return text
        }
    }

    static func stars(_ rating: Int) -> String {
        guard rating > 0 else { return "" }
        return String(repeating: "★", count: rating / 2) + (rating % 2 == 1 ? "½" : "")
    }

    private func drawIndicators(_ model: PlaylistRowModel, in rect: NSRect, selected: Bool) {
        if let pos = model.queuePosition {
            let d: CGFloat = 15
            let circle = NSRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d)
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: circle).fill()
            let s = NSAttributedString(string: "\(pos)", attributes: [.font: NSFont.boldSystemFont(ofSize: pos > 9 ? 8 : 9),
                                                                    .foregroundColor: NSColor.white])
            let size = s.size()
            s.draw(at: NSPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2))
            return
        }
        var symbol: String?
        var tint = NSColor.amamacAccent
        if model.isStopAfter {
            symbol = "stop.circle.fill"
            tint = .systemRed
        } else if model.isActive {
            switch model.playerState {
            case .playing, .buffering: symbol = "speaker.wave.2.fill"
            case .paused: symbol = "pause.fill"
            case .stopped: symbol = "play.fill"
            }
        }
        guard let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return }
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold).applying(.init(paletteColors: [selected ? .white : tint]))
        let img = image.withSymbolConfiguration(config) ?? image
        let size = img.size
        img.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
                 from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
