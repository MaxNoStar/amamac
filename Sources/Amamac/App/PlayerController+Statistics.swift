import AmamacLibrary
import AmamacModels
import Foundation

/// Play statistics: recorded when a track's session ends, mirrored into files when asked.
extension PlayerController {
    func finishSession(reachedEnd: Bool) {
        guard let item = currentItem, sessionStart != nil else { return }
        sessionStart = nil
        guard let trackId = item.track.id, item.source == .collection else { return }
        let duration = item.duration > 0 ? item.duration : self.duration
        let played = reachedEnd ? duration : lastPosition
        let statistics = StatisticsStore(database: database)
        Task {
            let stats = try? await statistics.recordPlay(trackId: trackId, playedSeconds: played, duration: duration, reachedEnd: reachedEnd)
            if let stats { self.statisticsUpdated(trackId: trackId, stats) }
        }
    }

    func statisticsUpdated(trackId: Int64, _ stats: TrackStatistics) {
        model.updateTrack(id: trackId) { $0.statistics = stats }
        if currentItem?.track.id == trackId { currentItem?.statistics = stats }
        statisticsRevision += 1
        writeStatisticsToFile(trackId: trackId, stats)
    }

    /// Keeps the playing item's metadata in step with tag edits and moves.
    func trackUpdated(_ track: Track) {
        guard let current = currentItem, current.track.id == track.id else { return }
        currentItem?.track = track
        if current.url.isFileURL { currentItem?.url = track.url }
        emit(.trackChanged)
    }

    /// Optional: mirrors rating and play count into the file's FMPS tags.
    private func writeStatisticsToFile(trackId: Int64, _ stats: TrackStatistics) {
        guard settings.bool(AppSettings.Key.writeStatisticsToFile),
              let path = model.items.first(where: { $0.track.id == trackId })?.track.path ?? (currentItem?.track.id == trackId ? currentItem?.track.path : nil)
        else { return }
        willWriteFile?(path)
        let rating = stats.rating, plays = stats.playCount
        Task { await StatisticsTagWriter.write(rating: rating, playCount: plays, to: path) }
    }

    /// Sets the rating (0...10) of a track and updates every copy of it.
    func setRating(_ rating: Int, trackId: Int64) {
        let statistics = StatisticsStore(database: database)
        Task {
            let stats = try? await statistics.setRating(rating, trackIds: [trackId]).first?.statistics
            if let stats {
                self.statisticsUpdated(trackId: trackId, stats)
                NotificationCenter.default.post(name: AppEnvironment.collectionChanged, object: nil)
            }
        }
    }
}
