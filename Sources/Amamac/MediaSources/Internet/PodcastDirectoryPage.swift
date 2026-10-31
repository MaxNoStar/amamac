import AmamacBase
import AmamacModels
import AmamacPodcasts
import AmamacWeb
import AppKit
import SwiftUI

@MainActor
@Observable
final class PodcastDirectoryModel {
    let env: AppEnvironment
    var term = ""
    private(set) var results: [PodcastDirectoryClient.Result] = []
    private(set) var searching = false
    private(set) var error: String?
    private(set) var subscribing: Set<Int> = []

    init(env: AppEnvironment) { self.env = env }

    func search() {
        let term = self.term.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        searching = true
        error = nil
        Task {
            do {
                results = try await PodcastDirectoryClient(http: env.http).search(term)
            } catch {
                self.error = "The podcast directory could not be reached. \(error.localizedDescription)"
            }
            searching = false
        }
    }

    func isSubscribed(_ result: PodcastDirectoryClient.Result) -> Bool {
        result.feedUrl.map { env.podcasts.isSubscribed(feedURL: $0) } ?? false
    }

    func subscribe(_ result: PodcastDirectoryClient.Result) {
        guard let feed = result.feedUrl.flatMap(URL.init(string:)) else { return }
        subscribing.insert(result.id)
        Task {
            await env.podcasts.subscribe(feed)
            subscribing.remove(result.id)
        }
    }
}

struct PodcastDirectoryView: View {
    @Bindable var model: PodcastDirectoryModel

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search podcasts", text: $model.term)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.search() }
                .padding(8)
            Divider()
            if let error = model.error {
                Text(error).font(.callout).foregroundStyle(.secondary).padding().frame(maxHeight: .infinity)
            } else {
                List(model.results) { result in
                    HStack(spacing: 8) {
                        RemoteImage(url: (result.artworkUrl600 ?? result.artworkUrl100).flatMap(URL.init(string:)), images: model.env.remoteImages,
                                    symbol: "mic", size: 40)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(result.collectionName).lineLimit(2)
                            Text([result.artistName, result.primaryGenreName].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if model.isSubscribed(result) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Subscribed")
                        } else if model.subscribing.contains(result.id) {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Subscribe") { model.subscribe(result) }.controlSize(.small)
                        }
                    }
                }
                .listStyle(.plain)
                .overlay {
                    if model.searching {
                        ProgressView()
                    } else if model.results.isEmpty {
                        Text("Search by title, topic or host, then subscribe. Episodes appear under Podcasts.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                    }
                }
            }
        }
    }
}
