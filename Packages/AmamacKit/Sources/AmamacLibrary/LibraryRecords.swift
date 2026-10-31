import AmamacBase
import AmamacDatabase
import Foundation

extension Array where Element == CollectionFolder {
    /// The innermost collection folder that contains `path`.
    func folderId(containing path: String) -> Int64? {
        filter { Paths.isInside(path, folder: $0.path) }.max { $0.path.count < $1.path.count }?.id
    }
}
