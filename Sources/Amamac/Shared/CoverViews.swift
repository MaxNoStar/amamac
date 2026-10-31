import AmamacLibrary
import AppKit
import SwiftUI

/// A cover with a placeholder when missing.
struct CoverImage: View {
    let image: NSImage?
    var symbol = "opticaldisc"

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                Image(systemName: symbol).font(.system(size: 36, weight: .light)).foregroundStyle(.tertiary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
    }
}

/// Loads an album cover from the cover cache.
struct AlbumCover: View {
    let albumKey: String?
    let covers: CoverImageCache
    @State private var image: NSImage?

    var body: some View {
        CoverImage(image: image)
            .task(id: albumKey) {
                if let albumKey { image = await covers.image(albumKey: albumKey, size: 48) }
            }
    }
}

/// Loads cover thumbnails from `CoverStore` into NSImages, memoised per album and size.
@MainActor
final class CoverImageCache {
    let store: CoverStore
    private let cache = NSCache<NSString, NSImage>()
    private var missing = Set<String>()
    private var pending: [String: [(NSImage?) -> Void]] = [:]

    init(store: CoverStore) {
        self.store = store
        cache.countLimit = 600
    }

    func removeAll() {
        cache.removeAllObjects()
        missing.removeAll()
    }

    func invalidate(albumKey: String) {
        for size in [32, 48, 64, 100, 128, 200, 300, 600] { cache.removeObject(forKey: "\(albumKey)#\(size)" as NSString) }
        missing = missing.filter { !$0.hasPrefix(albumKey + "#") }
        Task { await store.invalidate(albumKey: albumKey) }
    }

    /// Returns a cached image immediately, or nil and calls `completion` once loaded.
    func image(albumKey: String, size: Int, completion: @escaping (NSImage?) -> Void) -> NSImage? {
        let key = "\(albumKey)#\(size)"
        if let image = cache.object(forKey: key as NSString) { return image }
        if missing.contains(key) { return nil }
        if pending[key] != nil {
            pending[key]!.append(completion)
            return nil
        }
        pending[key] = [completion]
        let store = self.store
        Task {
            let url = await store.cover(albumKey: albumKey, size: size * 2)
            let image = url.flatMap { NSImage(contentsOf: $0) }
            if let image { cache.setObject(image, forKey: key as NSString) } else { missing.insert(key) }
            let callbacks = pending.removeValue(forKey: key) ?? []
            for cb in callbacks { cb(image) }
        }
        return nil
    }

    func image(albumKey: String, size: Int) async -> NSImage? {
        let key = "\(albumKey)#\(size)"
        if let image = cache.object(forKey: key as NSString) { return image }
        if missing.contains(key) { return nil }
        return await withCheckedContinuation { cont in
            if let img = image(albumKey: albumKey, size: size, completion: { cont.resume(returning: $0) }) {
                cont.resume(returning: img)
            }
        }
    }
}
