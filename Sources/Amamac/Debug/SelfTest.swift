import Foundation
import AmamacCore

/// `Amamac --selftest-decoders`: generates one file per format, decodes it and reads its tags.
enum SelfTest {
    static func runDecoders() -> Int32 {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("amamac-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var failures = 0
        for ext in AudioFixtures.selfTestExtensions {
            var tags = TagChanges()
            tags.title = "Self Test \(ext)"
            tags.artist = "Amamac"
            do {
                let url = try AudioFixtures.make(.init("selftest.\(ext)", seconds: 1, tags: tags), in: root)
                let frames = try AudioFixtures.decodeAll(url)
                let read = try TagReader.read(url: url)
                let ok = frames > 30_000 && read.track.title == "Self Test \(ext)"
                print(String(format: "%-5@ %@ frames=%lld title=%@ format=%@ rate=%d", ext as NSString,
                             ok ? "OK  " : "FAIL", frames, read.track.title, read.track.format, read.track.sampleRate))
                if !ok { failures += 1 }
                fflush(stdout)
            } catch {
                print("\(ext) FAIL \(error)")
                fflush(stdout)
                failures += 1
            }
        }
        print(failures == 0 ? "All decoders OK" : "\(failures) decoder checks failed")
        return failures == 0 ? 0 : 1
    }
}
