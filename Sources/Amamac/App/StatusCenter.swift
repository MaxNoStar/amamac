import Foundation

/// Progress tasks and short messages shown at the bottom of Media Sources.
@MainActor
@Observable
final class StatusCenter {
    struct TaskInfo: Identifiable {
        let id: UUID
        var title: String
        var phase: String
        var fraction: Double?
    }

    private(set) var tasks: [TaskInfo] = []
    private(set) var message: String?
    @ObservationIgnored private var messageToken = UUID()

    func beginTask(_ title: String) -> UUID {
        let id = UUID()
        tasks.append(TaskInfo(id: id, title: title, phase: "", fraction: nil))
        return id
    }

    func update(_ id: UUID, phase: String, fraction: Double?) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].phase = phase
        tasks[i].fraction = fraction
    }

    func endTask(_ id: UUID) { tasks.removeAll { $0.id == id } }

    func showMessage(_ text: String, seconds: Double = 6) {
        message = text
        let token = UUID()
        messageToken = token
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if self.messageToken == token { self.message = nil }
        }
    }
}
