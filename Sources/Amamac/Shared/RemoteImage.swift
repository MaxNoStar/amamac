import AmamacWeb
import AppKit
import SwiftUI

/// Station logos and podcast artwork, fetched through `HTTPClient` (so its cache and stubs apply).
@MainActor
final class RemoteImageCache {
    private let http: HTTPClient
    private let cache = NSCache<NSURL, NSImage>()
    private var failed = Set<URL>()

    init(http: HTTPClient) { self.http = http }

    func image(for url: URL) async -> NSImage? {
        if let image = cache.object(forKey: url as NSURL) { return image }
        guard !failed.contains(url), url.scheme == "https" || url.scheme == "http" else { return nil }
        guard let data = try? await http.data(from: url), let image = NSImage(data: data) else {
            failed.insert(url)
            return nil
        }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

struct RemoteImage: View {
    let url: URL?
    let images: RemoteImageCache
    var symbol = "photo"
    var size: CGFloat = 32
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: size / 6).fill(.quaternary)
                Image(systemName: symbol).font(.system(size: size * 0.45)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 6))
        .task(id: url) {
            image = nil
            if let url { image = await images.image(for: url) }
        }
    }
}
