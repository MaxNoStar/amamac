import AmamacModels
import AmamacPlaylist
import AppKit
import SwiftUI

/// Scan / download progress and short messages at the bottom of Media Sources.
struct ProgressStrip: View {
    let status: StatusCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(status.tasks) { task in
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.phase.isEmpty ? task.title : "\(task.title): \(task.phase)")
                        .font(.caption).lineLimit(1)
                    if let fraction = task.fraction {
                        ProgressView(value: fraction).controlSize(.small)
                    } else {
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                    }
                }
            }
            if let message = status.message {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, status.tasks.isEmpty && status.message == nil ? 0 : 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.default, value: status.tasks.count)
    }
}
