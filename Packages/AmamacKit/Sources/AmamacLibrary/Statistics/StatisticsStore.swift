import AmamacDatabase
import AmamacModels
import Foundation
import GRDB

/// Play counts, scores and ratings in the database.
public struct StatisticsStore: Sendable {
    public let database: LibraryDatabase

    public init(database: LibraryDatabase) { self.database = database }

    /// Records a finished listening session under Amarok's play-count and score rules.
    public func recordPlay(trackId: Int64, playedSeconds: TimeInterval, duration: TimeInterval,
                           reachedEnd: Bool) async throws -> TrackStatistics {
        try await database.writer.write { db in
            var stats = try TrackStatistics.fetchOne(db, key: trackId) ?? TrackStatistics(trackId: trackId)
            PlayStatistics.apply(to: &stats, playedSeconds: playedSeconds, duration: duration, reachedEnd: reachedEnd)
            try stats.save(db)
            return stats
        }
    }

    /// Sets the rating (0...10) of each track and returns their updated statistics.
    public func setRating(_ rating: Int, trackIds: [Int64]) async throws -> [(trackId: Int64, statistics: TrackStatistics)] {
        try await database.writer.write { db in
            try trackIds.map { id in
                var stats = try TrackStatistics.fetchOne(db, key: id) ?? TrackStatistics(trackId: id)
                stats.rating = max(0, min(10, rating))
                try stats.save(db)
                return (id, stats)
            }
        }
    }
}
