import AmamacBase
import AmamacModels
import AmamacWeb
import AppKit
import SwiftUI
import WebKit

/// Wikipedia articles for the current artist, composer, album or track. Article links open inside
/// the applet (with Back / Forward); other links open in the browser.
final class WikipediaAppletController: NSObject, Applet, WKNavigationDelegate {
    let kind = AppletKind.wikipedia
    let contentView: NSView
    let env: AppEnvironment
    private let web: WKWebView
    private let subjects = NSSegmentedControl(labels: ["Artist", "Composer", "Album", "Track"], trackingMode: .selectOne, target: nil, action: nil)
    private let back = NSButton()
    private let forward = NSButton()
    private let reload = NSButton()
    private let browser = NSButton()
    private let titleLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    private var history: [WikipediaClient.Page] = []
    private var position = -1
    private var subject = WikipediaClient.Subject.artist
    private var loadedQuery: String?
    private var task: Task<Void, Never>?
    private var isActive = false

    init(env: AppEnvironment) {
        self.env = env
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        // Articles are static HTML; scripts from a page would only be risk.
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        web = WKWebView(frame: .zero, configuration: config)
        let root = NSView()
        contentView = root
        super.init()
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        web.identifier = NSUserInterfaceItemIdentifier("wikipediaWebView")
        subjects.selectedSegment = 0
        subjects.segmentStyle = .rounded
        subjects.controlSize = .small
        subjects.target = self
        subjects.action = #selector(subjectChanged(_:))
        for (button, symbol, tip, action) in [(back, "chevron.left", "Back", #selector(goBack)),
                                              (forward, "chevron.right", "Forward", #selector(goForward)),
                                              (reload, "arrow.clockwise", "Reload", #selector(reloadPage)),
                                              (browser, "safari", "Open in Browser", #selector(openInBrowser))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.isBordered = false
            button.toolTip = tip
            button.target = self
            button.action = action
        }
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let bar = NSStackView(views: [back, forward, reload, subjects, titleLabel, NSView(), spinner, browser])
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        for v in [bar, web] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            web.topAnchor.constraint(equalTo: bar.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        env.player.addListener { [weak self] event in
            if event == .trackChanged { self?.trackChanged() }
        }
        NotificationCenter.default.addObserver(forName: .amamacSettingChanged, object: AppSettings.Key.wikipediaLanguage, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackChanged(force: true) }
        }
        updateButtons()
        showMessage("Wikipedia articles appear here while a track plays.")
    }

    func setActive(_ active: Bool) {
        isActive = active
        if active { trackChanged() }
    }

    func makeConfigurationView() -> AnyView? {
        AnyView(WikipediaSettingsView(settings: env.settings))
    }

    // MARK: Loading

    private var track: Track? {
        guard env.player.isActive, let item = env.player.currentItem, !item.isStream else { return nil }
        return item.track
    }

    private func trackChanged(force: Bool = false) {
        guard isActive else { return }
        guard let track else {
            loadedQuery = nil
            return
        }
        let query = WikipediaClient.query(for: subject, track: track).map { subject.rawValue + ":" + $0 } ?? subject.rawValue + ":"
        guard force || query != loadedQuery else { return }
        loadedQuery = query
        load { client in try await client.page(for: self.subject, track: track) }
    }

    enum HistoryMode { case reset, push, replace }

    private func load(_ mode: HistoryMode = .reset, _ fetch: @escaping (WikipediaClient) async throws -> WikipediaClient.Page) {
        task?.cancel()
        spinner.startAnimation(nil)
        let client = env.wikipedia()
        task = Task {
            defer { spinner.stopAnimation(nil) }
            do {
                let page = try await fetch(client)
                guard !Task.isCancelled else { return }
                switch mode {
                case .reset:
                    history = [page]
                    position = 0
                case .push:
                    history = Array(history.prefix(position + 1)) + [page]
                    position = history.count - 1
                case .replace:
                    if position >= 0 { history[position] = page } else { history = [page]; position = 0 }
                }
                show(page)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                if mode == .reset {
                    history = []
                    position = -1
                }
                showMessage(error.localizedDescription)
            }
            updateButtons()
        }
    }

    private func show(_ page: WikipediaClient.Page) {
        titleLabel.stringValue = page.title
        web.loadHTMLString(Self.document(for: page), baseURL: URL(string: "https://\(page.language).wikipedia.org/wiki/"))
        updateButtons()
    }

    private func showMessage(_ text: String) {
        titleLabel.stringValue = ""
        let escaped = XMLText.escape(text)
        web.loadHTMLString(Self.wrap("<p class=\"amamac-message\">\(escaped)</p>", lang: "en"), baseURL: nil)
        updateButtons()
    }

    private func updateButtons() {
        back.isEnabled = position > 0
        forward.isEnabled = position >= 0 && position < history.count - 1
        reload.isEnabled = track != nil || position >= 0
        browser.isEnabled = position >= 0
    }

    @objc private func subjectChanged(_ sender: NSSegmentedControl) {
        subject = WikipediaClient.Subject.allCases[max(0, sender.selectedSegment)]
        trackChanged(force: true)
    }

    @objc private func goBack() {
        guard position > 0 else { return }
        position -= 1
        show(history[position])
    }

    @objc private func goForward() {
        guard position < history.count - 1 else { return }
        position += 1
        show(history[position])
    }

    @objc private func reloadPage() {
        if position >= 0 {
            let title = history[position].title
            load(.replace) { try await $0.page(title: title) }
        } else {
            trackChanged(force: true)
        }
    }

    @objc private func openInBrowser() {
        guard position >= 0 else { return }
        NSWorkspace.shared.open(history[position].url)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else {
            // Only the applet's own loads (`loadHTMLString` with a Wikipedia base URL) go through;
            // anything a page starts by itself, such as a refresh or a form, is cancelled.
            decisionHandler(Self.isOwnLoad(navigationAction) ? .allow : .cancel)
            return
        }
        decisionHandler(.cancel)
        if let title = Self.articleTitle(from: url, language: env.wikipedia().language) {
            load(.push) { try await $0.page(title: title) }
        } else if url.fragment != nil && (url.host() == nil || url.path() == "/wiki/") {
            return
        } else if url.isWebURL {
            NSWorkspace.shared.open(url)
        }
    }

    static func isOwnLoad(_ action: WKNavigationAction) -> Bool {
        guard action.navigationType == .other, action.targetFrame?.isMainFrame != false, let url = action.request.url else { return false }
        return url.absoluteString == "about:blank" || (url.host()?.hasSuffix(".wikipedia.org") == true && url.path() == "/wiki/")
    }

    /// Article title for links to ordinary articles in the same language edition.
    static func articleTitle(from url: URL, language: String) -> String? {
        guard url.host() == "\(language).wikipedia.org", url.path().hasPrefix("/wiki/") else { return nil }
        let title = String(url.path(percentEncoded: false).dropFirst("/wiki/".count)).replacingOccurrences(of: "_", with: " ")
        // Namespaced pages (File:, Help:, Special:, …) open in the browser.
        if title.contains(":") { return nil }
        return title.isEmpty ? nil : title
    }

    // MARK: HTML

    static func document(for page: WikipediaClient.Page) -> String {
        wrap("<h1>\(page.title.replacingOccurrences(of: "<", with: "&lt;"))</h1>" + page.html, lang: page.language)
    }

    static func wrap(_ body: String, lang: String) -> String {
        """
        <!doctype html><html lang="\(lang)"><head><meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <style>
        :root { color-scheme: light dark; }
        body { font: 13px -apple-system, system-ui, sans-serif; line-height: 1.5; margin: 12px 16px; color: CanvasText; background: transparent; }
        h1 { font-size: 20px; margin: 0 0 8px; } h2 { font-size: 16px; border-bottom: 1px solid #8884; padding-bottom: 2px; } h3 { font-size: 14px; }
        a { color: LinkText; text-decoration: none; } a:hover { text-decoration: underline; }
        img { max-width: 100%; height: auto; }
        table { border-collapse: collapse; font-size: 12px; }
        .infobox { float: right; clear: right; max-width: 40%; margin: 0 0 10px 14px; border: 1px solid #8884; background: #8881; }
        .infobox td, .infobox th { padding: 2px 6px; vertical-align: top; text-align: left; }
        .navbox, .navbox-styles, .mw-references-wrap, .reflist, .references, .metadata, .ambox, .mw-editsection, .noprint,
        .sistersitebox, .side-box, .hatnote, .mw-empty-elt, .reference, .mw-cite-backlink, .portalbox, .catlinks { display: none !important; }
        .thumb, figure { margin: 6px 0; } figcaption, .thumbcaption { font-size: 11px; opacity: .75; }
        .amamac-message { opacity: .6; text-align: center; margin-top: 40px; }
        </style></head><body>\(body)</body></html>
        """
    }
}

struct WikipediaSettingsView: View {
    let settings: AppSettings
    @State private var language: String

    static let languages: [(String, String)] = [
        ("en", "English"), ("de", "Deutsch"), ("fr", "Français"), ("es", "Español"), ("it", "Italiano"),
        ("nl", "Nederlands"), ("pt", "Português"), ("sv", "Svenska"), ("pl", "Polski"), ("ru", "Русский"),
        ("ja", "日本語"), ("zh", "中文"), ("ko", "한국어"), ("is", "Íslenska"),
    ]

    init(settings: AppSettings) {
        self.settings = settings
        _language = State(initialValue: settings.string(AppSettings.Key.wikipediaLanguage) ?? "en")
    }

    var body: some View {
        Form {
            Picker("Language", selection: $language) {
                ForEach(Self.languages, id: \.0) { code, name in Text(name).tag(code) }
            }
            .onChange(of: language) { _, new in settings.set(new, AppSettings.Key.wikipediaLanguage) }
            Text("Artists are matched through MusicBrainz and Wikidata; other subjects use Wikipedia’s search.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 280)
    }
}
