import SwiftUI
import TravelPlannerKit

/// The offers of a trip side by side, to help the group decide.
struct CompareView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let candidates: [CandidateSummary]
    /// Travellers of the trip, for the price per person.
    let persons: Int?

    @State private var selected: Set<String> = []
    @State private var details: [String: CandidateDetail] = [:]
    @State private var onlyDifferences = false
    @State private var loading = true
    @State private var error: String?
    @State private var showSelection = false
    /// How far the table is scrolled sideways and down, so the pinned line of names moves with its columns.
    @State private var across: CGFloat = 0
    @State private var pinned = false
    /// The bar with "Fertig" and the filters is out of the way while reading down the table, as in Safari:
    /// scrolling down hides it, scrolling back up or reaching the top brings it back.
    @State private var barHidden = false
    @State private var barMoved = Date.distantPast
    @State private var turn: CGFloat = 0
    /// Only offers of this country are compared; nil compares those of all countries.
    @State private var country: String?

    private var countries: [String] { OfferGrouping.countries(in: candidates) }

    /// The offers of the chosen country, or all of them.
    private var inCountry: [CandidateSummary] {
        guard let country else { return candidates }
        return candidates.filter { OfferGrouping.country(of: $0) == country }
    }

    private let labelWidth: CGFloat = 132
    private let columnWidth: CGFloat = 176

    /// Offers in list order, as far as they are chosen and loaded.
    private var offers: [CandidateDetail] {
        inCountry.filter { selected.contains($0.id) }.compactMap { details[$0.id] }
    }

    private var comparison: Comparison {
        let all = Comparison(offers: offers, persons: persons)
        return onlyDifferences ? all.differencesOnly() : all
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Lade Angebote …")
                } else if let error {
                    ContentUnavailableView("Nicht geladen", systemImage: "wifi.exclamationmark", description: Text(error))
                } else if offers.count < 2 {
                    ContentUnavailableView {
                        Label(country == nil ? "Wähle mindestens zwei Angebote" : "Zu wenige Angebote in \(country ?? "")", systemImage: "rectangle.split.3x1")
                    } description: {
                        if country != nil { Text("Für einen Vergleich braucht es mindestens zwei ausgewählte Angebote aus diesem Land.") }
                    } actions: {
                        Button("Angebote auswählen") { showSelection = true }
                        if country != nil { Button("Alle Länder zeigen") { country = nil } }
                    }
                } else {
                    table(comparison)
                }
            }
            .navigationTitle("Vergleich")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarVisibility(barHidden && offers.count >= 2 ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() } }
                if countries.count > 1 {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Picker("Land", selection: $country) {
                                Text("Alle Länder").tag(String?.none)
                                ForEach(countries, id: \.self) { name in
                                    Text([Format.flag(forCountry: name), name].compactMap { $0 }.joined(separator: " ")).tag(String?.some(name))
                                }
                            }
                        } label: {
                            Label(country ?? "Land", systemImage: country == nil ? "globe.europe.africa" : "globe.europe.africa.fill")
                        }
                        .accessibilityLabel(country.map { "Land: \($0)" } ?? "Nach Land filtern")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Auswahl (\(inCountry.filter { selected.contains($0.id) }.count))", systemImage: "checklist") { showSelection = true }
                }
            }
            .sheet(isPresented: $showSelection) { selection }
        }
        .task { await load() }
    }

    private func load() async {
        guard let backend = model.backend else { return }
        // Rejected offers start unchecked; they can be added back in the selection.
        if selected.isEmpty { selected = Set(candidates.filter { $0.status != .rejected }.map(\.id)) }
        do {
            try await withThrowingTaskGroup(of: CandidateDetail.self) { group in
                for candidate in candidates { group.addTask { try await backend.candidate(candidate.id) } }
                for try await detail in group { details[detail.candidate.id] = detail }
            }
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = model.message(for: error)
        }
        loading = false
    }

    private var selection: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(inCountry) { candidate in
                        Button {
                            if selected.contains(candidate.id) { selected.remove(candidate.id) } else { selected.insert(candidate.id) }
                        } label: {
                            HStack {
                                Image(systemName: selected.contains(candidate.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(candidate.id) ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.listing.title ?? "Angebot").foregroundStyle(.primary)
                                    Text(candidate.status.label).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityAddTraits(selected.contains(candidate.id) ? .isSelected : [])
                    }
                } header: {
                    if let country { Text("Angebote in \(country)") }
                } footer: {
                    Text("Zwei bis fünf Angebote lassen sich gut nebeneinander lesen.")
                }
                Section {
                    // With a country chosen these act on its offers only; the choice in other countries stays.
                    Button("Alle") { selected.formUnion(inCountry.map(\.id)) }
                    Button("Nur Favoriten und engere Wahl") {
                        selected.subtract(inCountry.map(\.id))
                        selected.formUnion(inCountry.filter { $0.status == .favorite || $0.status == .shortlist }.map(\.id))
                    }
                    Button("Keine") { selected.subtract(inCountry.map(\.id)) }
                }
            }
            .navigationTitle("Angebote auswählen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { showSelection = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Table. The label column stays put while the offers scroll sideways; both share the vertical scroll.

    private func height(of row: Comparison.Row) -> CGFloat {
        ["praise", "critique", "cancel"].contains(row.id) ? 104 : 46
    }

    private let headerHeight: CGFloat = 168
    private let sectionHeight: CGFloat = 34

    private func table(_ comparison: Comparison) -> some View {
        let wins = comparison.wins
        return ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    // The corner above the labels holds the switch, where it covers nothing.
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Nur Unterschiede").font(.caption).foregroundStyle(.secondary)
                        Toggle("Nur Unterschiede zeigen", isOn: $onlyDifferences).labelsHidden()
                    }
                    .padding(.leading, 12)
                    .padding(.top, 10)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(height: headerHeight, alignment: .topLeading)
                    ForEach(comparison.sections) { section in
                        Text(section.title)
                            .font(.subheadline.weight(.semibold))
                            .padding(.leading, 12)
                            .padding(.bottom, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: sectionHeight, alignment: .bottomLeading)
                        ForEach(section.rows) { row in
                            Text(row.label)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                // Padding sits inside the fixed height, so both columns stay in step row by row.
                                .padding(.leading, 12)
                                .padding(.top, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(height: height(of: row), alignment: .topLeading)
                                .overlay(alignment: .top) { Divider() }
                        }
                    }
                }
                .frame(width: labelWidth)

                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(Array(comparison.offers.enumerated()), id: \.element.candidate.id) { index, offer in
                                header(offer, wins: wins[index], top: wins.max() ?? 0)
                            }
                        }
                        .frame(height: headerHeight)
                        ForEach(comparison.sections) { section in
                            Color.clear.frame(height: sectionHeight)
                            ForEach(section.rows) { row in
                                HStack(alignment: .top, spacing: 0) {
                                    ForEach(Array(row.values.enumerated()), id: \.offset) { index, value in
                                        cell(value, best: row.best.contains(index))
                                            .frame(width: columnWidth, height: height(of: row), alignment: .topLeading)
                                    }
                                }
                                .overlay(alignment: .top) { Divider() }
                            }
                        }
                    }
                }
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, now in across = now }
            }
            if let note = comparison.sections.flatMap(\.rows).compactMap(\.note).first {
                Text(note).font(.footnote).foregroundStyle(.secondary).padding()
            }
            Text("Grün markiert ist der jeweils beste bekannte Wert. Ein Strich heißt: Das Inserat sagt dazu nichts.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .bottom])
        }
        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > headerHeight - 24 } action: { _, now in
            withAnimation(.easeInOut(duration: 0.15)) { pinned = now }
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { before, now in
            // Hiding the bar shifts the table itself; what follows right after a change is that shift, not a finger.
            guard Date.now.timeIntervalSince(barMoved) > 0.4 else { turn = now; return }
            if now < 30 {
                if barHidden { barHidden = false; barMoved = .now }
                turn = now
            } else if (now > before) != (now > turn) || abs(now - before) < 0.5 {
                // Direction changed: measure the new stretch from here.
                turn = before
            } else if !barHidden, now - turn > 40 {
                withAnimation(.easeInOut(duration: 0.2)) { barHidden = true }
                barMoved = .now
            } else if barHidden, turn - now > 40 {
                withAnimation(.easeInOut(duration: 0.2)) { barHidden = false }
                barMoved = .now
            }
        }
        // Once the pictures and names have scrolled away, a slim line keeps saying which column is which offer.
        .overlay(alignment: .top) {
            if pinned {
                HStack(spacing: 0) {
                    Text("Angebot").font(.caption).foregroundStyle(.secondary)
                        .padding(.leading, 12)
                        .frame(width: labelWidth, alignment: .leading)
                    // The names take no room of their own: they lie on the space beside the labels and are cut at its edges.
                    Color.clear
                        .overlay(alignment: .leading) {
                            HStack(spacing: 0) {
                                ForEach(comparison.offers, id: \.candidate.id) { offer in
                                    Text(offer.listing.title ?? "Angebot")
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(2)
                                        .padding(.trailing, 12)
                                        .frame(width: columnWidth, alignment: .leading)
                                }
                            }
                            .fixedSize()
                            .offset(x: -across)
                        }
                        .clipped()
                }
                .frame(height: 40)
                .background(.bar)
                .overlay(alignment: .bottom) { Divider() }
                .transition(.opacity)
                .accessibilityHidden(true)
            }
        }
    }

    private func header(_ offer: CandidateDetail, wins: Int, top: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            CoverImage(url: offer.gallery.first?.stripAddress)
                .frame(width: columnWidth - 12, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(offer.listing.title ?? "Angebot").font(.subheadline.weight(.semibold)).lineLimit(2)
            if wins > 0 {
                Label(wins == 1 ? "1 Bestwert" : "\(wins) Bestwerte", systemImage: wins == top ? "rosette" : "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(wins == top ? Color.green : Color.secondary)
            }
        }
        .frame(width: columnWidth - 12, alignment: .topLeading)
        .padding(.trailing, 12)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func cell(_ value: String?, best: Bool) -> some View {
        if let value {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                // The mark carries the meaning as well, not the colour alone.
                if best { Image(systemName: "checkmark.circle.fill").font(.caption).accessibilityLabel("Bestwert") }
                Text(value).lineLimit(5).minimumScaleFactor(0.85)
            }
            .font(best ? .callout.weight(.semibold) : .callout)
            .foregroundStyle(best ? Color.green : Color.primary)
            .padding(.top, 6)
            .padding(.trailing, 12)
        } else {
            Text("–").foregroundStyle(.tertiary).padding(.top, 6).accessibilityLabel("unbekannt")
        }
    }
}
