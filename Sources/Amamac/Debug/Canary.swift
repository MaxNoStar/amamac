import AppKit
import SwiftUI
import WebKit

/// `--canary <dir>`: renders a window with each kind of content the real UI uses and snapshots it,
/// to prove `Snapshotter` captures AppKit tables, SwiftUI (Text/Image/Canvas/List) and WKWebView.
final class CanaryController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow!

    func run(output: URL) {
        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        split.isVertical = true
        split.dividerStyle = .thin

        let table = NSTableView()
        let column = NSTableColumn(identifier: .init("c"))
        column.title = "Tracks"
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true

        let hosting = NSHostingView(rootView: CanarySwiftUIView())
        hosting.sizingOptions = []

        let web = WKWebView()
        web.loadHTMLString("<html><body style='background:#2a6;color:white;font:24px -apple-system'><h1>WebKit OK</h1></body></html>", baseURL: nil)

        split.addArrangedSubview(scroll)
        split.addArrangedSubview(hosting)
        split.addArrangedSubview(web)

        window = NSWindow(contentRect: split.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = split
        window.appearance = NSAppearance(named: .aqua)
        window.orderFront(nil)
        split.adjustSubviews()
        split.setPosition(300, ofDividerAt: 0)
        split.setPosition(600, ofDividerAt: 1)

        Task { @MainActor in
            await Snapshotter.waitUntil(timeout: 5) { !web.isLoading }
            try? await Task.sleep(for: .milliseconds(500))
            try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            await Snapshotter.capture(split, to: output.appendingPathComponent("canary.png"))
            Snapshotter.dumpLayout(of: window, to: output.appendingPathComponent("canary-layout.json"))
            print("Canary written to \(output.path)")
            exit(0)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { 3 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let field = NSTextField(labelWithString: "AppKit row \(row + 1)")
        return field
    }
}

private struct CanarySwiftUIView: View {
    var body: some View {
        VStack(alignment: .leading) {
            Text("SwiftUI Text").font(.title)
            Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.blue)
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)), with: .color(.orange))
            }
            .frame(height: 40)
            List(["List row A", "List row B"], id: \.self) { Text($0) }
        }
        .padding()
    }
}
