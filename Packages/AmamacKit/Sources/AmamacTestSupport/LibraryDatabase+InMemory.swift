// Debug builds and tests only: Release builds compile this out.
#if DEBUG
import AmamacDatabase
import GRDB

extension LibraryDatabase {
    /// An in-memory database for tests and the snapshot and perf runs.
    public static func inMemory() throws -> LibraryDatabase {
        try LibraryDatabase(writer: DatabaseQueue(configuration: configuration()))
    }
}
#endif
