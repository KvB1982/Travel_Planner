import SwiftUI
import TravelPlannerKit
import UIKit
import UniformTypeIdentifiers

/// Entry point of the share sheet: pick a trip, the link is sent, the sheet closes.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.finish = { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        Task { await model.start(items: items) }
    }
}

struct SharedPage {
    var url: URL
    var html: String?
}

@MainActor
@Observable
final class ShareModel {
    enum Phase: Equatable {
        case loading
        case choose
        case sending(String)
        case done(String)
        case problem(String)
    }

    var phase: Phase = .loading
    var trips: [Trip] = []
    var page: SharedPage?
    var finish: () -> Void = {}

    private let store = SessionStore()
    private var backend: (any TravelBackend)?
    private let lastTripKey = "lastSharedTrip"
    private var defaults: UserDefaults { UserDefaults(suiteName: SessionStore.appGroup) ?? .standard }

    func start(items: [NSExtensionItem]) async {
        guard let page = await Self.readPage(from: items) else {
            phase = .problem("In dem geteilten Inhalt steckt kein Link.")
            return
        }
        self.page = page
        backend = store.demoMode ? DemoBackend() : store.client
        guard let backend else {
            phase = .problem("Öffne zuerst die App und melde dich an. Danach kannst du Angebote direkt hierher teilen.")
            return
        }
        do {
            let all = try await backend.trips().filter { $0.status != .archived && $0.role != .guest }
            guard !all.isEmpty else {
                phase = .problem("Du hast noch keine Reise, in die du Angebote sammeln kannst. Lege in der App eine an.")
                return
            }
            // The trip used last comes first: most links in a row belong to the same trip.
            let last = defaults.string(forKey: lastTripKey)
            trips = all.sorted { ($0.id == last ? 0 : 1) < ($1.id == last ? 0 : 1) }
            phase = .choose
        } catch {
            phase = .problem(error.localizedDescription)
        }
    }

    func send(to trip: Trip) async {
        guard let backend, let page else { return }
        phase = .sending(trip.title)
        do {
            let result = try await backend.importLink(tripId: trip.id, url: page.url.absoluteString, html: page.html)
            defaults.set(trip.id, forKey: lastTripKey)
            if store.demoMode {
                // Sample data lives only inside the app, so there is nowhere to keep the link.
                phase = .done("Link erkannt. Mit Beispieldaten wird nichts gespeichert.")
            } else {
                phase = .done(result.duplicate ? "Schon in „\(trip.title)“ vorhanden" : "In „\(trip.title)“ gespeichert")
            }
            try? await Task.sleep(for: .seconds(store.demoMode ? 2 : 0.9))
            finish()
        } catch {
            phase = .problem(error.localizedDescription)
        }
    }

    /// Safari delivers the result of GetPage.js, other apps a URL or text that contains one.
    static func readPage(from items: [NSExtensionItem]) async -> SharedPage? {
        let providers = items.flatMap { $0.attachments ?? [] }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier) {
            if let dictionary = try? await provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier) as? NSDictionary,
               let result = dictionary[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any],
               let text = result["url"] as? String, let url = URL(string: text), url.scheme?.hasPrefix("http") == true {
                return SharedPage(url: url, html: result["html"] as? String)
            }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL, url.scheme?.hasPrefix("http") == true {
                return SharedPage(url: url)
            }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
               let url = LinkFinder.firstURL(in: text) {
                return SharedPage(url: url)
            }
        }
        return nil
    }
}

struct ShareView: View {
    let model: ShareModel

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .loading:
                    ProgressView()
                case .choose:
                    List {
                        let shelf = TripShelf(trips: model.trips, groups: [])
                        ForEach(shelf.sections) { section in
                            Section {
                                ForEach(section.trips + (section.watchlist.map { [$0] } ?? [])) { trip in
                                    Button {
                                        Task { await model.send(to: trip) }
                                    } label: {
                                        Label {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(trip.isWatchlist ? (section.id == "private" ? "Meine Merkliste" : "Merkliste der Gruppe") : trip.title)
                                                    .font(.headline).foregroundStyle(.primary)
                                                if let region = trip.region, !region.isEmpty {
                                                    Text(region).font(.subheadline).foregroundStyle(.secondary)
                                                }
                                            }
                                        } icon: {
                                            Image(systemName: trip.isWatchlist ? "bookmark" : "suitcase")
                                        }
                                    }
                                }
                            } header: {
                                Text(shelf.sections.count > 1 ? section.title : "Wohin?")
                            }
                        }
                        Section {
                        } footer: {
                            if let host = model.page?.url.host() { Text(host) }
                        }
                    }
                case .sending(let title):
                    ProgressView("Speichere in „\(title)“ …")
                case .done(let message):
                    Label(message, systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                        .multilineTextAlignment(.center)
                        .padding()
                case .problem(let message):
                    ContentUnavailableView("Nicht gespeichert", systemImage: "exclamationmark.triangle", description: Text(message))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Travel Planner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.phase == .choose || model.phase == .loading ? "Abbrechen" : "Schließen") { model.finish() }
                }
            }
        }
    }
}
