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

    private let labelWidth: CGFloat = 132
    private let columnWidth: CGFloat = 176

    /// Offers in list order, as far as they are chosen and loaded.
    private var offers: [CandidateDetail] {
        candidates.filter { selected.contains($0.id) }.compactMap { details[$0.id] }
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
                        Label("Wähle mindestens zwei Angebote", systemImage: "rectangle.split.3x1")
                    } actions: {
                        Button("Angebote auswählen") { showSelection = true }
                    }
                } else {
                    table(comparison)
                }
            }
            .navigationTitle("Vergleich")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Auswahl (\(selected.count))", systemImage: "checklist") { showSelection = true }
                }
                ToolbarItem(placement: .bottomBar) {
                    Toggle("Nur Unterschiede zeigen", isOn: $onlyDifferences).toggleStyle(.switch)
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
                    ForEach(candidates) { candidate in
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
                } footer: {
                    Text("Zwei bis fünf Angebote lassen sich gut nebeneinander lesen.")
                }
                Section {
                    Button("Alle") { selected = Set(candidates.map(\.id)) }
                    Button("Nur Favoriten und engere Wahl") {
                        selected = Set(candidates.filter { $0.status == .favorite || $0.status == .shortlist }.map(\.id))
                    }
                    Button("Keine") { selected = [] }
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
                    Color.clear.frame(height: headerHeight)
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
