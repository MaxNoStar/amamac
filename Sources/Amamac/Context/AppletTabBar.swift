import AmamacModels
import AppKit
import SwiftUI

/// Tabs for the enabled applets (click scrolls to the applet; drag to reorder) and the checkable
/// "Configure Applets" button.
final class AppletTabBar: NSView {
    var kinds: [AppletKind] = [] { didSet { needsDisplay = true; invalidateIntrinsicContentSize() } }
    var onSelect: ((AppletKind) -> Void)?
    var onReorder: (([AppletKind]) -> Void)?
    let configureButton = NSButton(title: "Configure Applets", target: nil, action: nil)
    private var dragIndex: Int?
    private var dragX: CGFloat = 0
    private var dragStartX: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("appletTabBar")
        configureButton.setButtonType(.pushOnPushOff)
        configureButton.bezelStyle = .recessed
        configureButton.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
        configureButton.imagePosition = .imageLeading
        configureButton.controlSize = .small
        configureButton.font = .systemFont(ofSize: 11)
        configureButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(configureButton)
        NSLayoutConstraint.activate([
            configureButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            configureButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 30),
        ])
        setAccessibilityRole(.tabGroup)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private let tabWidth: CGFloat = 112

    private func tabRect(_ i: Int) -> NSRect {
        NSRect(x: 8 + CGFloat(i) * (tabWidth + 4), y: 4, width: tabWidth, height: bounds.height - 8)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        for (i, kind) in kinds.enumerated() {
            var rect = tabRect(i)
            if i == dragIndex { rect.origin.x += dragX - dragStartX }
            let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            (i == dragIndex ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25) : NSColor.controlBackgroundColor).setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.stroke()
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular).applying(.init(paletteColors: [.secondaryLabelColor]))
            if let image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                image.draw(in: NSRect(x: rect.minX + 7, y: rect.midY - image.size.height / 2, width: image.size.width, height: image.size.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            NSAttributedString(string: kind.title, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor,
                                                                .paragraphStyle: style])
                .draw(with: NSRect(x: rect.minX + 26, y: rect.midY - 7, width: rect.width - 32, height: 14),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    private func index(at point: NSPoint) -> Int? {
        kinds.indices.first { tabRect($0).contains(point) }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        dragIndex = index(at: p)
        dragStartX = p.x
        dragX = p.x
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragIndex != nil else { return }
        dragX = convert(event.locationInWindow, from: nil).x
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragIndex = nil; needsDisplay = true }
        guard let from = dragIndex else { return }
        if abs(dragX - dragStartX) < 4 {
            onSelect?(kinds[from])
            return
        }
        let target = max(0, min(kinds.count - 1, Int(((tabRect(from).midX + dragX - dragStartX) - 8) / (tabWidth + 4))))
        guard target != from else { return }
        var new = kinds
        new.insert(new.remove(at: from), at: target)
        kinds = new
        onReorder?(new)
    }

    override func accessibilityChildren() -> [Any]? {
        kinds.enumerated().map { i, kind in
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.radioButton)
            element.setAccessibilityLabel(kind.title)
            element.setAccessibilityFrameInParentSpace(tabRect(i))
            element.setAccessibilityParent(self)
            return element
        }
    }
}

/// The strip of all applets shown while "Configure Applets" is on: toggles to add or remove.
struct AppletStrip: View {
    let enabled: [AppletKind]
    let onToggle: (AppletKind) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(AppletKind.allCases, id: \.self) { kind in
                    let on = enabled.contains(kind)
                    Button { onToggle(kind) } label: {
                        VStack(spacing: 4) {
                            Image(systemName: kind.symbol).font(.system(size: 20))
                            Text(kind.title).font(.caption.weight(.semibold))
                            Text(kind.summary).font(.caption2).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center).lineLimit(2)
                        }
                        .frame(width: 130, height: 76)
                        .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.amamacAccent.opacity(0.18) : Color.secondary.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Color.amamacAccent : Color.secondary.opacity(0.3)))
                    }
                    .buttonStyle(.plain)
                    .help(on ? "Remove \(kind.title)" : "Add \(kind.title)")
                }
            }
            .padding(10)
        }
    }
}
