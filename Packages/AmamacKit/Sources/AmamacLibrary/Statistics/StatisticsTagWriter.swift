import Foundation
import GRDB

/// Writes rating and play count into files (FMPS tags) when the user enabled it.
public enum StatisticsTagWriter {
    @concurrent
    public static func write(rating: Int?, playCount: Int?, to path: String) async {
        var changes = TagChanges()
        changes.rating = rating
        changes.playCount = playCount
        guard !changes.isEmpty else { return }
        try? TagWriter.write(changes, to: URL(fileURLWithPath: path))
    }
}
