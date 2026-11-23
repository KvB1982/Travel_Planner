import CoreLocation
import MapKit
import SwiftUI
import TravelPlannerKit

/// A position on the map and how far it can be trusted.
struct ResolvedPlace: Equatable {
    var coordinate: CLLocationCoordinate2D
    /// Looked up from the place name, or marked as unsure by the server: the house is somewhere around here.
    var approximate: Bool

    static func == (a: ResolvedPlace, b: ResolvedPlace) -> Bool {
        a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude && a.approximate == b.approximate
    }
}

/// Turns what an advert says about its location into a map position. Place names are looked up once and remembered.
@MainActor
final class PlaceResolver {
    static let shared = PlaceResolver()
    private var known: [String: CLLocationCoordinate2D?] = [:]

    /// How far coordinates may lie from the place the advert names before they are taken for a mistake.
    private let plausibleDistance: CLLocationDistance = 150_000

    func resolve(_ hint: PlaceHint) async -> ResolvedPlace? {
        let named = await lookUp(hint.query)
        if let latitude = hint.latitude, let longitude = hint.longitude {
            let given = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            // Coordinates in another part of the world than the named place are wrong data (a page that
            // located the reader instead of the house, for example). The place name wins then.
            if let named, CLLocation(latitude: latitude, longitude: longitude)
                .distance(from: CLLocation(latitude: named.latitude, longitude: named.longitude)) > plausibleDistance {
                return ResolvedPlace(coordinate: named, approximate: true)
            }
            return ResolvedPlace(coordinate: given, approximate: hint.uncertain)
        }
        return named.map { ResolvedPlace(coordinate: $0, approximate: true) }
    }

    private func lookUp(_ query: String?) async -> CLLocationCoordinate2D? {
        guard let query else { return nil }
        if let cached = known[query] { return cached }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = .address
        let found = try? await MKLocalSearch(request: request).start().mapItems.first?.placemark.coordinate
        known[query] = .some(found)
        return found
    }
}

private extension MKCoordinateRegion {
    /// Wide enough to see the town, the coast and the next bigger place at a glance.
    static func overview(_ center: CLLocationCoordinate2D, kilometers: Double = 30) -> MKCoordinateRegion {
        MKCoordinateRegion(center: center, latitudinalMeters: kilometers * 1000, longitudinalMeters: kilometers * 1000)
    }
}

/// The house on the map: a pin for a known position, a circle when only the area is known.
private struct PlaceMark: MapContent {
    let title: String
    let place: ResolvedPlace

    var body: some MapContent {
        if place.approximate {
            MapCircle(center: place.coordinate, radius: 2500)
                .foregroundStyle(Color.accentColor.opacity(0.18))
                .stroke(Color.accentColor, lineWidth: 2)
            Annotation(title, coordinate: place.coordinate) {
                Image(systemName: "house.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white, Color.accentColor)
                    .accessibilityLabel("ungefähre Lage")
            }
        } else {
            Marker(title, systemImage: "house.fill", coordinate: place.coordinate).tint(Color.accentColor)
        }
    }
}

/// What the full map needs to show one offer.
struct MapTarget: Identifiable {
    let title: String
    let hint: PlaceHint
    let place: ResolvedPlace
    var id: String { title + (hint.query ?? "") }
}

/// Section of the profile: where the house is, with a wide first view. A tap opens the full map.
struct LocationSection: View {
    let detail: CandidateDetail
    /// Opens the full map. The sheet belongs to the surrounding screen, not to a list row.
    var open: (MapTarget) -> Void

    @State private var place: ResolvedPlace?
    @State private var searched = false

    private var hint: PlaceHint { PlaceHint(listing: detail.listing) }
    private var title: String { detail.listing.title ?? "Angebot" }

    var body: some View {
        if !hint.isEmpty {
            Section {
                if let place {
                    // The small map stands still: moving it would fight with scrolling the profile. A tap anywhere
                    // on it opens the full map, which moves and zooms.
                    Map(initialPosition: .region(.overview(place.coordinate)), interactionModes: []) {
                        PlaceMark(title: title, place: place)
                    }
                    .frame(height: 260)
                    .overlay(alignment: .bottomTrailing) {
                        Label("Karte öffnen", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                            .padding(8)
                    }
                    .overlay {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { open(MapTarget(title: title, hint: hint, place: place)) }
                            .accessibilityElement()
                            .accessibilityLabel("Karte öffnen: \(hint.query ?? title)")
                            .accessibilityAddTraits(.isButton)
                    }
                    .listRowInsets(EdgeInsets())
                } else if !searched {
                    HStack { ProgressView(); Text("Suche den Ort …").foregroundStyle(.secondary) }
                } else {
                    Label("Der Ort „\(hint.query ?? "")“ ließ sich auf der Karte nicht finden.", systemImage: "mappin.slash")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Karte")
            } footer: {
                if let place, place.approximate {
                    Text("Ungefähre Lage: Das Inserat nennt keine genaue Position. Der Kreis zeigt die Gegend um \(hint.query ?? "den Ort").")
                }
            }
            .task(id: hint) {
                place = await PlaceResolver.shared.resolve(hint)
                searched = true
            }
        }
    }
}

/// Icon above a short caption, so a row of map buttons fits a phone without breaking words.
private struct AdaptiveLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 2) {
            configuration.icon.font(.body)
            configuration.title.font(.caption2).lineLimit(1).fixedSize()
        }
    }
}

enum MapLook: String, CaseIterable, Identifiable {
    case standard = "Karte", hybrid = "Hybrid", satellite = "Satellit"
    var id: String { rawValue }

    var style: MapStyle {
        switch self {
        case .standard: .standard(elevation: .realistic)
        case .hybrid: .hybrid(elevation: .realistic)
        case .satellite: .imagery(elevation: .realistic)
        }
    }
}

/// Full map of one offer: free to move and zoom, satellite view, and a way out to the big map apps.
struct LocationMapView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let title: String
    let hint: PlaceHint
    let place: ResolvedPlace

    @State private var position: MapCameraPosition
    @State private var look: MapLook = .standard

    init(title: String, hint: PlaceHint, place: ResolvedPlace) {
        self.title = title
        self.hint = hint
        self.place = place
        _position = State(initialValue: .region(.overview(place.coordinate)))
    }

    var body: some View {
        NavigationStack {
            Map(position: $position) {
                PlaceMark(title: title, place: place)
            }
            .mapStyle(look.style)
            .mapControls {
                MapCompass()
                MapScaleView()
                MapPitchToggle()
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Picker("Darstellung", selection: $look) {
                        ForEach(MapLook.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    HStack(spacing: 12) {
                        // Three fixed views instead of fiddling with two fingers: the house, the area, the region.
                        Button("Haus", systemImage: "house") {
                            withAnimation { position = .region(.overview(place.coordinate, kilometers: 3)) }
                        }
                        Button("Umgebung", systemImage: "map") {
                            withAnimation { position = .region(.overview(place.coordinate)) }
                        }
                        Button("Region", systemImage: "globe.europe.africa") {
                            withAnimation { position = .region(.overview(place.coordinate, kilometers: 150)) }
                        }
                        Spacer()
                        Menu {
                            Button("Apple Karten", systemImage: "map") { openInAppleMaps() }
                            if let url = googleURL {
                                Button("Google Maps", systemImage: "globe") { openURL(url) }
                            }
                        } label: {
                            Label("Öffnen in …", systemImage: "arrow.up.forward.app")
                        }
                    }
                    .buttonStyle(.bordered)
                    .labelStyle(AdaptiveLabel())
                    if place.approximate {
                        Text("Ungefähre Lage, das Inserat nennt keine genaue Position.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding()
                .background(.regularMaterial)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
    }

    /// An exact position goes over as coordinates; an approximate one as the place name, so Google shows the town.
    private var googleURL: URL? {
        place.approximate && hint.query != nil
            ? MapLinks.googleMaps(query: hint.query)
            : MapLinks.googleMaps(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude)
    }

    private func openInAppleMaps() {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: place.coordinate))
        item.name = place.approximate ? (hint.query ?? title) : title
        item.openInMaps(launchOptions: [MKLaunchOptionsMapSpanKey: NSValue(mkCoordinateSpan: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2))])
    }
}

/// All offers of a trip on one map. Tapping a pin shows the offer; from there it opens in the profile.
struct TripMapView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let candidates: [CandidateSummary]
    /// Called with the offer to open; the map closes itself.
    var open: (String) -> Void

    @State private var places: [String: ResolvedPlace] = [:]
    @State private var loading = true
    @State private var selected: String?
    @State private var position: MapCameraPosition = .automatic
    @State private var look: MapLook = .standard

    private var missing: Int { candidates.count - places.count }

    var body: some View {
        NavigationStack {
            Map(position: $position, selection: $selected) {
                ForEach(candidates.filter { places[$0.id] != nil }) { candidate in
                    let place = places[candidate.id]!
                    Annotation(candidate.listing.title ?? "Angebot", coordinate: place.coordinate, anchor: .bottom) {
                        PricePin(candidate: candidate, approximate: place.approximate, selected: selected == candidate.id)
                    }
                    .tag(candidate.id)
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(look.style)
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .overlay {
                if loading { ProgressView("Suche die Orte …").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    if let candidate = candidates.first(where: { $0.id == selected }) {
                        card(candidate)
                    } else if !loading {
                        Text(places.isEmpty ? "Für diese Angebote ist kein Ort bekannt." : "Tippe ein Angebot auf der Karte an.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if !loading && missing > 0 && !places.isEmpty {
                        Text(missing == 1 ? "1 Angebot ohne Ortsangabe fehlt auf der Karte." : "\(missing) Angebote ohne Ortsangabe fehlen auf der Karte.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(.regularMaterial)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Picker("Darstellung", selection: $look) {
                        ForEach(MapLook.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        for candidate in candidates {
            if let place = await PlaceResolver.shared.resolve(PlaceHint(summary: candidate.listing)) {
                places[candidate.id] = place
            }
        }
        loading = false
        // One offer alone would be shown at street level; give it the same wide view as in the profile.
        if places.count == 1, let only = places.values.first {
            position = .region(.overview(only.coordinate, kilometers: 60))
        }
    }

    private func card(_ candidate: CandidateSummary) -> some View {
        HStack(spacing: 12) {
            CoverImage(url: candidate.listing.coverImageUrl)
                .frame(width: 84, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.listing.title ?? "Angebot").font(.headline).lineLimit(2)
                HStack(spacing: 8) {
                    if let price = candidate.price, price.forThisTrip, let text = candidate.groupPriceText {
                        Text(text).font(.subheadline.weight(.semibold))
                    }
                    VoteBadges(votes: candidate.votes)
                }
                if places[candidate.id]?.approximate == true {
                    Text("Ungefähre Lage").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Öffnen") {
                open(candidate.id)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// A pin that already says the most important thing: the price for this trip, or the status when there is none.
private struct PricePin: View {
    let candidate: CandidateSummary
    let approximate: Bool
    let selected: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                if candidate.status == .favorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                Text(label)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? Color.accentColor : Color(.systemBackground), in: Capsule())
            // A dashed outline marks a position that is only roughly known.
            .overlay(Capsule().strokeBorder(selected ? Color.white : Color.accentColor,
                                            style: StrokeStyle(lineWidth: 1.5, dash: approximate ? [4, 3] : [])))
            .shadow(radius: 2, y: 1)
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 9))
                .foregroundStyle(selected ? Color.accentColor : Color(.systemBackground))
                .offset(y: -2)
        }
        .scaleEffect(selected ? 1.15 : 1, anchor: .bottom)
        .accessibilityLabel("\(candidate.listing.title ?? "Angebot"), \(label)\(approximate ? ", ungefähre Lage" : "")")
    }

    private var label: String {
        if let price = candidate.price, price.forThisTrip, let cents = candidate.share.group(price.totalCents) { return Format.euro(cents: cents) }
        return candidate.status == .new ? "ohne Preis" : candidate.status.label
    }
}
