import SwiftUI
import TravelPlannerKit

/// The phases of a trip as a bar: shows where the trip stands and switches the surface below.
struct PhaseBar: View {
    let trip: Trip
    @Binding var viewed: TripPhase
    /// Set for organizers: moves the trip itself to a phase.
    var setPhase: ((TripPhase) -> Void)?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(TripPhase.shown) { phase in
                        Button {
                            viewed = phase
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: phase.symbol)
                                Text(phase.label)
                                // A dot marks where the trip really is, whatever is being looked at.
                                if phase == trip.activePhase {
                                    Circle().fill(viewed == phase ? Color.white : Color.accentColor).frame(width: 6, height: 6)
                                        .accessibilityLabel("aktuelle Phase")
                                }
                            }
                            .font(.subheadline.weight(viewed == phase ? .semibold : .regular))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .foregroundStyle(viewed == phase ? Color.white : Color.primary)
                            .background(viewed == phase ? Color.accentColor : Color(.secondarySystemFill), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .id(phase)
                        .contextMenu {
                            if let setPhase, phase != trip.activePhase {
                                Button("Reise auf „\(phase.label)“ stellen", systemImage: "arrow.right.circle") { setPhase(phase) }
                            }
                        }
                        .accessibilityAddTraits(viewed == phase ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
            .onAppear { proxy.scrollTo(viewed, anchor: .center) }
            .onChange(of: viewed) { withAnimation { proxy.scrollTo(viewed, anchor: .center) } }
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }
}

/// The phase of a trip as one prominent pill with a menu: it says where you are, opens every other phase, and lets
/// those who organise move the trip on. Takes a fraction of the room the bar of all phases needed.
struct PhaseMenu: View {
    let trip: Trip
    @Binding var viewed: TripPhase
    /// Set for organizers: moves the trip itself to a phase.
    var setPhase: ((TripPhase) -> Void)?

    private var position: Int { (TripPhase.shown.firstIndex(of: viewed) ?? 0) + 1 }

    var body: some View {
        Menu {
            Section("Ansicht wechseln") {
                Picker("Phase", selection: $viewed) {
                    ForEach(Array(TripPhase.shown.enumerated()), id: \.element) { index, phase in
                        Label("\(index + 1)  \(phase.label)\(phase == trip.activePhase ? " (aktuell)" : "")", systemImage: phase.symbol).tag(phase)
                    }
                }
            }
            if let setPhase, viewed != trip.activePhase {
                Section {
                    Button("Reise auf „\(viewed.label)“ stellen", systemImage: "arrow.right.circle") { setPhase(viewed) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: viewed.symbol)
                Text(viewed.label)
                Text("\(position)/\(TripPhase.shown.count)").font(.caption.weight(.medium)).opacity(0.8)
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(.white)
            .background(Color.accentColor, in: Capsule())
            .overlay(alignment: .topTrailing) {
                // Looking at another phase than the trip is in: a small mark says so.
                if viewed != trip.activePhase {
                    Circle().fill(.orange).frame(width: 9, height: 9).overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5)).offset(x: 2, y: -2)
                }
            }
        }
        .accessibilityLabel("Phase \(viewed.label), \(position) von \(TripPhase.shown.count)\(viewed == trip.activePhase ? "" : ", die Reise steht in \(trip.activePhase.label)")")
    }
}

/// What a phase is for, where its surface does not exist yet.
struct PhasePlaceholder: View {
    let phase: TripPhase

    var body: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: phase.symbol).font(.system(size: 40)).foregroundStyle(.secondary)
                Text(phase.label).font(.title3.weight(.semibold))
                Text(phase.purpose).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Text("Diese Oberfläche ist noch nicht gebaut.").font(.footnote).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }
}

/// The decision round inside the trip: pick finalists, rank them, see the result, record the decision.
struct PitchSections: View {
    @Environment(AppModel.self) private var model
    let tripID: String
    let role: MemberRole
    /// All offers of the trip, to pick finalists from.
    let candidates: [CandidateSummary]
    let persons: Int?
    @Binding var selection: String?

    @State private var pitch: Pitch?
    @State private var error: String?
    @State private var order: [String] = []
    @State private var orderChanged = false
    @State private var choosing = false
    @State private var deciding: Pitch.Finalist?
    @State private var presenting = false
    @State private var confirmUndo = false

    var body: some View {
        Group {
            if let error { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) } }
            if let pitch {
                if pitch.finalists.isEmpty {
                    empty
                } else {
                    if let winner = pitch.finalists.first(where: { $0.candidate.id == pitch.decidedCandidateId }) { decided(winner) }
                    result(pitch)
                    if pitch.decidedCandidateId == nil { ranking(pitch) }
                    actions(pitch)
                }
            } else if error == nil {
                Section { HStack { ProgressView(); Text("Lade die Entscheidungsrunde …").foregroundStyle(.secondary) } }
            }
        }
        .task(id: model.revision) { await load() }
        .sheet(isPresented: $choosing) {
            FinalistPicker(candidates: candidates, preselected: Set(pitch?.finalists.map(\.candidate.id) ?? [])) { ids in
                run { try await $0.startPitch(tripId: tripID, candidateIds: ids) }
            }
        }
        .fullScreenCover(isPresented: $presenting) {
            PresentationView(candidates: pitch?.finalists.map(\.candidate) ?? [], persons: persons)
        }
        .alert("Entscheidung festhalten?", isPresented: .init(get: { deciding != nil }, set: { if !$0 { deciding = nil } }), presenting: deciding) { finalist in
            Button("Abbrechen", role: .cancel) {}
            Button("Festhalten") { run { try await $0.decide(tripId: tripID, candidateId: finalist.candidate.id, dateOptionId: nil) } }
        } message: { finalist in
            Text("„\(finalist.candidate.listing.title ?? "Dieses Angebot")“ wird als Gewinner festgehalten, und die Reise geht in die Phase Buchung. Die übrigen Angebote bleiben erhalten. Das lässt sich zurücknehmen.")
        }
        .alert("Entscheidung zurücknehmen?", isPresented: $confirmUndo) {
            Button("Abbrechen", role: .cancel) {}
            Button("Zurücknehmen", role: .destructive) { run { try await $0.undoDecision(tripId: tripID) } }
        } message: {
            Text("Die Reise steht dann wieder in der Entscheidungsrunde. Rangfolgen und Stimmen bleiben erhalten.")
        }
    }

    private func load() async {
        guard let backend = model.backend else { return }
        do {
            let loaded = try await backend.pitch(tripId: tripID)
            apply(loaded)
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = model.message(for: error)
        }
    }

    private func apply(_ loaded: Pitch) {
        pitch = loaded
        if !orderChanged {
            // Start from the own ranking; finalists not ranked yet follow in the order of the result.
            let ids = loaded.finalists.map(\.candidate.id)
            order = loaded.myRanking.filter(ids.contains) + ids.filter { !loaded.myRanking.contains($0) }
        }
    }

    private func run(_ action: @escaping (any TravelBackend) async throws -> Pitch) {
        guard let backend = model.backend else { return }
        Task {
            do {
                orderChanged = false
                apply(try await action(backend))
                error = nil
                model.dataChanged()
            } catch {
                self.error = model.message(for: error)
            }
        }
    }

    // MARK: Parts

    private var empty: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("Noch keine Finalisten").font(.headline)
                Text("Wähle zwei bis acht Angebote aus, zwischen denen sich die Gruppe entscheidet. Jeder bringt sie dann in seine Rangfolge, daraus ergeben sich Punkte.")
                    .foregroundStyle(.secondary)
                if role == .organizer {
                    Button("Finalisten auswählen") { choosing = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(candidates.count < 2)
                    if candidates.count < 2 {
                        Text("Dafür braucht die Reise mindestens zwei Angebote.").font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Das macht die Person, die die Reise organisiert.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func decided(_ winner: Pitch.Finalist) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("Entschieden", systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(.green)
                Text(winner.candidate.listing.title ?? "Angebot").font(.title3.weight(.semibold))
                Text("Die Reise steht in der Phase Buchung.").font(.footnote).foregroundStyle(.secondary)
            }
            if role == .organizer {
                Button("Entscheidung zurücknehmen", systemImage: "arrow.uturn.backward", role: .destructive) { confirmUndo = true }
            }
        }
    }

    private func result(_ pitch: Pitch) -> some View {
        Section {
            ForEach(pitch.finalists) { finalist in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(finalist.place ?? 0).")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(finalist.place == 1 ? Color.accentColor : Color.secondary)
                        .frame(width: 30, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(finalist.candidate.listing.title ?? "Angebot").font(.headline).lineLimit(2)
                            if let verdict = finalist.candidate.criteria { CriteriaLight(verdict: verdict).font(.subheadline) }
                        }
                        Text(points(finalist)).font(.subheadline).foregroundStyle(.secondary)
                        HStack {
                            Text(price(finalist.candidate)).font(.subheadline.weight(.semibold))
                                .foregroundStyle(finalist.candidate.isUnavailable ? Color.red : Color.primary)
                            Spacer()
                            VoteBadges(votes: finalist.candidate.votes)
                        }
                        if let highlights = finalist.highlights, !highlights.isEmpty {
                            Text(highlights.prefix(3).joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                        }
                        ForEach(finalist.warnings?.prefix(2) ?? [], id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange).lineLimit(2)
                        }
                    }
                }
                .padding(.vertical, 2)
                .tag(finalist.candidate.id)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if role == .organizer && pitch.decidedCandidateId == nil {
                        Button("Entscheiden", systemImage: "checkmark.seal") { deciding = finalist }.tint(.green)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                if pitch.rankings.isEmpty {
                    Text("Noch hat niemand eine Rangfolge abgegeben.")
                } else {
                    Text("Abgegeben: \(pitch.rankings.map(\.name).joined(separator: ", ")).")
                }
                if !pitch.missing.isEmpty { Text("Es fehlt noch: \(pitch.missing.map(\.name).joined(separator: ", ")).") }
                Text("Der erste Platz bringt \(pitch.finalists.count) Punkte, jeder weitere einen weniger. Ein Veto setzt ein Angebot ans Ende. Tippe ein Angebot an, um den Steckbrief zu öffnen.")
            }
            .font(.footnote).foregroundStyle(.secondary).listRowSeparator(.hidden)
        } header: {
            Text("Rangfolge der Gruppe")
        }
    }

    private func points(_ finalist: Pitch.Finalist) -> String {
        let value = finalist.points ?? 0
        var parts = [value == 1 ? "1 Punkt" : "\(Format.number(value)) Punkte"]
        if let first = finalist.firstPlaces, first > 0 { parts.append(first == 1 ? "1 erster Platz" : "\(first) erste Plätze") }
        if finalist.candidate.votes.vetoes > 0 { parts.append("Veto") }
        return parts.joined(separator: " · ")
    }

    private func price(_ candidate: CandidateSummary) -> String {
        if candidate.isUnavailable { return "Im Reisezeitraum nicht verfügbar" }
        if let price = candidate.price, price.forThisTrip,
           let text = Format.price(totalCents: price.totalCents, rangeMaxCents: price.rangeMaxCents, kind: price.kind) { return text }
        return "Preis noch offen"
    }

    private func ranking(_ pitch: Pitch) -> some View {
        Section {
            ForEach(Array(order.enumerated()), id: \.element) { index, id in
                HStack {
                    Text("\(index + 1).").font(.headline).frame(width: 26, alignment: .leading)
                    Text(pitch.finalists.first { $0.candidate.id == id }?.candidate.listing.title ?? "Angebot").lineLimit(2)
                    Spacer()
                    // Buttons instead of dragging: clear on every device and with VoiceOver.
                    Button { move(index, by: -1) } label: { Image(systemName: "arrow.up.circle").font(.title3) }
                        .buttonStyle(.borderless).disabled(index == 0).accessibilityLabel("Einen Platz nach oben")
                    Button { move(index, by: 1) } label: { Image(systemName: "arrow.down.circle").font(.title3) }
                        .buttonStyle(.borderless).disabled(index == order.count - 1).accessibilityLabel("Einen Platz nach unten")
                }
            }
            Button(pitch.myRanking.isEmpty ? "Rangfolge abgeben" : "Rangfolge ändern", systemImage: "paperplane") {
                let mine = order
                run { try await $0.setRanking(tripId: tripID, order: mine) }
            }
            .disabled(!pitch.myRanking.isEmpty && !orderChanged)
            Text(pitch.myRanking.isEmpty ? "Bring die Finalisten mit den Pfeilen in deine Reihenfolge, das beste zuerst, und gib sie ab."
                                         : orderChanged ? "Geändert, aber noch nicht abgegeben." : "Abgegeben. Du kannst sie jederzeit ändern.")
                .font(.footnote).foregroundStyle(.secondary).listRowSeparator(.hidden)
        } header: {
            Text("Deine Rangfolge")
        }
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard order.indices.contains(index), order.indices.contains(target) else { return }
        order.swapAt(index, target)
        orderChanged = true
    }

    private func actions(_ pitch: Pitch) -> some View {
        Section {
            Button("Finalisten präsentieren", systemImage: "play.rectangle") { presenting = true }
            if role == .organizer && pitch.decidedCandidateId == nil {
                Button("Finalisten ändern", systemImage: "trophy") { choosing = true }
                if let leader = pitch.finalists.first {
                    Button("„\(leader.candidate.listing.title ?? "Platz 1")“ als Entscheidung festhalten", systemImage: "checkmark.seal") { deciding = leader }
                }
            }
            if role == .organizer && pitch.decidedCandidateId == nil {
                Text("Ein anderes Angebot hältst du fest, indem du es in der Rangfolge der Gruppe nach links wischst.")
                    .font(.footnote).foregroundStyle(.secondary).listRowSeparator(.hidden)
            }
        }
    }
}

/// Picks the finalists among the offers of the trip.
private struct FinalistPicker: View {
    @Environment(\.dismiss) private var dismiss
    let candidates: [CandidateSummary]
    let preselected: Set<String>
    var done: ([String]) -> Void

    @State private var chosen: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(candidates.filter { $0.status != .rejected }) { candidate in
                        Button {
                            if chosen.contains(candidate.id) { chosen.remove(candidate.id) } else { chosen.insert(candidate.id) }
                        } label: {
                            HStack {
                                Image(systemName: chosen.contains(candidate.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(chosen.contains(candidate.id) ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(candidate.listing.title ?? "Angebot").foregroundStyle(.primary)
                                        if let verdict = candidate.criteria { CriteriaLight(verdict: verdict).font(.caption) }
                                    }
                                    Text(candidate.isUnavailable ? "Im Reisezeitraum nicht verfügbar" : candidate.status.label)
                                        .font(.caption).foregroundStyle(candidate.isUnavailable ? Color.red : Color.secondary)
                                }
                                Spacer()
                                VoteBadges(votes: candidate.votes)
                            }
                        }
                        .accessibilityAddTraits(chosen.contains(candidate.id) ? .isSelected : [])
                    }
                } footer: {
                    Text("Zwei bis acht Angebote. Gewählt: \(chosen.count). Beim Start geht die Reise in die Phase Entscheidung, bisherige Rangfolgen für abgewählte Angebote entfallen.")
                }
            }
            .navigationTitle("Finalisten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Starten") {
                        // Keep the order of the list.
                        done(candidates.map(\.id).filter(chosen.contains))
                        dismiss()
                    }
                    .disabled(!(2...8).contains(chosen.count))
                }
            }
        }
        .onAppear { chosen = preselected }
    }
}
