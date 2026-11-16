import SwiftUI
import TravelPlannerKit

/// Shows the offers of a trip one after the other, full screen: tap to go through photos and fact sheets,
/// swipe right for yes, left for no. Meant for a quick first verdict, alone or together in front of a screen.
struct PresentationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let candidates: [CandidateSummary]
    /// Travellers of the trip, for the price per person and night.
    let persons: Int?

    @State private var index = 0
    @State private var slide = 0
    @State private var details: [String: CandidateDetail] = [:]
    @State private var failed: Set<String> = []
    @State private var drag: CGSize = .zero
    @State private var given: [String: Verdict] = [:]
    @State private var error: String?

    private enum Slide: Hashable {
        case photo(Photo)
        case facts
        case reviews
    }

    private let photoLimit = 10

    private var current: CandidateSummary? { candidates.indices.contains(index) ? candidates[index] : nil }

    /// Cover first, the facts right after it, then the remaining photos and what guests say.
    private func slides(for detail: CandidateDetail) -> [Slide] {
        let photos = Array(detail.gallery.prefix(photoLimit))
        var result: [Slide] = []
        if let cover = photos.first { result.append(.photo(cover)) }
        result.append(.facts)
        result.append(contentsOf: photos.dropFirst().map(Slide.photo))
        if let reviews = detail.reviews, !reviews.isEmpty { result.append(.reviews) }
        return result
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let current {
                card(current)
                    .id(current.id)
                    .offset(x: drag.width, y: drag.height * 0.15)
                    .rotationEffect(.degrees(Double(drag.width) / 28))
                    .gesture(swipe(current))
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            } else {
                finished
            }
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden()
        .task(id: index) { await load() }
        .alert("Das hat nicht geklappt", isPresented: .init(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: {
            Text(error ?? "")
        }
    }

    // MARK: Card

    @ViewBuilder
    private func card(_ candidate: CandidateSummary) -> some View {
        GeometryReader { geometry in
            let detail = details[candidate.id]
            let all = detail.map(slides(for:)) ?? []
            let shown = min(slide, max(all.count - 1, 0))
            ZStack {
                if let detail, all.indices.contains(shown) {
                    content(all[shown], detail: detail, candidate: candidate)
                } else if failed.contains(candidate.id) {
                    ContentUnavailableView("Nicht geladen", systemImage: "wifi.exclamationmark", description: Text(candidate.listing.title ?? "Angebot"))
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            // Left third goes back, the rest forward, like turning pages.
            .onTapGesture { location in
                if location.x < geometry.size.width * 0.3 {
                    slide = max(shown - 1, 0)
                } else if shown < all.count - 1 {
                    slide = shown + 1
                } else {
                    slide = 0
                }
            }
            .overlay(alignment: .top) { header(candidate, count: all.count, shown: shown) }
            .overlay(alignment: .bottom) { controls(candidate) }
            .overlay { verdictStamp }
        }
    }

    private func header(_ candidate: CandidateSummary, count: Int, shown: Int) -> some View {
        VStack(spacing: 10) {
            // One bar per slide, like the progress of a story.
            HStack(spacing: 4) {
                ForEach(0..<max(count, 1), id: \.self) { position in
                    Capsule().fill(position <= shown ? Color.white : Color.white.opacity(0.3)).frame(height: 3)
                }
            }
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark").font(.headline).frame(width: 40, height: 40).background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Präsentation schließen")
                Spacer()
                Text("\(index + 1) von \(candidates.count)")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal)
        .padding(.top, 10)
    }

    private func controls(_ candidate: CandidateSummary) -> some View {
        HStack(spacing: 28) {
            decisionButton("Nein", symbol: "hand.thumbsdown.fill", color: .red) { decide(.no, for: candidate, direction: -1) }
            decisionButton("Vielleicht", symbol: "questionmark", color: .orange) { decide(.maybe, for: candidate, direction: 0) }
            decisionButton("Ja", symbol: "hand.thumbsup.fill", color: .green) { decide(.yes, for: candidate, direction: 1) }
        }
        .padding(.bottom, 18)
    }

    private func decisionButton(_ label: String, symbol: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(color)
                    .frame(width: 60, height: 60)
                    .background(.ultraThinMaterial, in: Circle())
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
    }

    /// Shows which way the swipe is heading, before the finger lets go.
    @ViewBuilder
    private var verdictStamp: some View {
        let strength = min(abs(drag.width) / 120, 1)
        if strength > 0.15 {
            Text(drag.width > 0 ? "JA" : "NEIN")
                .font(.system(size: 54, weight: .heavy))
                .foregroundStyle(drag.width > 0 ? Color.green : Color.red)
                .padding(.horizontal, 22).padding(.vertical, 8)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(drag.width > 0 ? Color.green : Color.red, lineWidth: 5))
                .rotationEffect(.degrees(drag.width > 0 ? -14 : 14))
                .opacity(strength)
                .allowsHitTesting(false)
        }
    }

    // MARK: Slides

    @ViewBuilder
    private func content(_ slide: Slide, detail: CandidateDetail, candidate: CandidateSummary) -> some View {
        switch slide {
        case .photo(let photo):
            RemoteImage(address: photo.url, maxPixel: 1800, contentMode: .fit,
                        placeholderAddress: photo.stripAddress, placeholderMaxPixel: PhotoSize.strip)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottomLeading) { caption(detail, candidate: candidate) }
        case .facts:
            factSheet(detail, candidate: candidate)
        case .reviews:
            reviewSheet(detail)
        }
    }

    /// Title and price over the lower edge of a photo, so every picture says which offer it is.
    private func caption(_ detail: CandidateDetail, candidate: CandidateSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(detail.listing.title ?? "Angebot").font(.title2.weight(.bold)).lineLimit(2)
            Text(place(detail)).font(.subheadline)
            Text(priceLine(candidate)).font(.headline)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.top, 60)
        .padding(.bottom, 120)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom))
        .allowsHitTesting(false)
    }

    private func place(_ detail: CandidateDetail) -> String {
        [detail.listing.place, detail.listing.profile.region, detail.listing.country].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func priceLine(_ candidate: CandidateSummary) -> String {
        if candidate.isUnavailable { return "Im Reisezeitraum nicht verfügbar" }
        if let price = candidate.price, price.forThisTrip,
           let text = Format.price(totalCents: price.totalCents, rangeMaxCents: price.rangeMaxCents, kind: price.kind) {
            return text
        }
        return "Preis für euren Zeitraum noch offen"
    }

    private func factSheet(_ detail: CandidateDetail, candidate: CandidateSummary) -> some View {
        let profile = detail.listing.profile
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(detail.listing.title ?? "Angebot").font(.title.weight(.bold))
                    Text(place(detail)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(priceLine(candidate)).font(.title2.weight(.semibold))
                        .foregroundStyle(candidate.isUnavailable ? Color.red : Color.primary)
                    if let price = candidate.price, price.forThisTrip, !candidate.isUnavailable,
                       let each = Format.perPersonNight(totalCents: price.totalCents, persons: persons ?? price.persons, nights: price.nights) {
                        Text(each).foregroundStyle(.secondary)
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
                    fact("person.2", profile.maxGuests.map { "\(Format.number($0)) Gäste" })
                    fact("bed.double", profile.bedrooms.map { "\(Format.number($0)) Schlafzimmer" })
                    fact("shower", profile.bathrooms.map { "\(Format.number($0)) Bäder" })
                    fact("square.dashed", profile.livingAreaSqm.map { "\(Format.number($0)) m²" })
                    fact("beach.umbrella", (profile.distances?.beachM ?? profile.distances?.seaM).map { "\(Format.distance(meters: $0)) zum Strand" })
                    fact("star.fill", profile.rating?.value.map { value in
                        "\(Format.number(value))" + (profile.rating?.count.map { " (\(Format.number($0)))" } ?? "")
                    })
                }
                let has = Profile.amenityKeys.filter { profile.amenity($0) == true }
                if !has.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Vorhanden").font(.headline)
                        Text(has.map(Format.amenityName).joined(separator: " · "))
                    }
                }
                let lacks = Profile.amenityKeys.filter { profile.amenity($0) == false }
                if !lacks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Nicht vorhanden").font(.headline)
                        Text(lacks.map(Format.amenityName).joined(separator: " · ")).foregroundStyle(.secondary)
                    }
                }
                if let summary = profile.summary, !summary.isEmpty { Text(summary) }
                let hints = detail.hints.filter { !$0.hidden }
                if !hints.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(hints) { hint in
                            Label(hint.text, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                    }
                    .font(.callout)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 110)
            .padding(.bottom, 140)
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private func fact(_ symbol: String, _ text: String?) -> some View {
        if let text {
            Label(text, systemImage: symbol)
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func reviewSheet(_ detail: CandidateDetail) -> some View {
        let reviews = detail.reviews ?? Reviews()
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Was Gäste sagen").font(.title.weight(.bold))
                if let value = detail.listing.profile.rating?.value {
                    Label(Format.number(value) + (detail.listing.profile.rating?.count.map { " aus \(Format.number($0)) Bewertungen" } ?? ""),
                          systemImage: "star.fill")
                        .font(.title3.weight(.semibold))
                }
                if let summary = reviews.summary, !summary.isEmpty { Text(summary) }
                points("Gelobt", reviews.positives, color: .green)
                points("Kritisiert", reviews.negatives, color: .orange)
                // A few voices in their own words; all of them are in the profile.
                let voices = Array((reviews.items ?? []).prefix(4))
                if !voices.isEmpty {
                    Text("Stimmen im Wortlaut").font(.headline).padding(.top, 6)
                    ForEach(voices) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                if let rating = item.rating {
                                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                                    Text(Format.number(rating)).fontWeight(.semibold)
                                }
                                Text([item.author, item.date.flatMap { Format.day($0) == nil ? $0 : String($0.prefix(4)) }]
                                    .compactMap { $0 }.joined(separator: " · "))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                            Text(item.translatedText ?? item.text).lineLimit(6)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if (reviews.items?.count ?? 0) > voices.count {
                        Text("Alle \(reviews.items?.count ?? 0) Bewertungen stehen im Steckbrief.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 110)
            .padding(.bottom, 140)
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private func points(_ title: String, _ list: [String]?, color: Color) -> some View {
        if let list, !list.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline).foregroundStyle(color)
                ForEach(list, id: \.self) { point in
                    HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•"); Text(point) }
                }
            }
        }
    }

    // MARK: Deciding

    private func swipe(_ candidate: CandidateSummary) -> some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                // Mostly sideways movement only: scrolling a fact sheet up and down must not throw the card away.
                if abs(value.translation.width) > abs(value.translation.height) { drag = value.translation }
            }
            .onEnded { value in
                if drag.width > 120 {
                    decide(.yes, for: candidate, direction: 1)
                } else if drag.width < -120 {
                    decide(.no, for: candidate, direction: -1)
                } else {
                    withAnimation(.spring(duration: 0.3)) { drag = .zero }
                }
            }
    }

    /// Records the own vote and moves on. The vote is what the list and the comparison already show.
    private func decide(_ verdict: Verdict, for candidate: CandidateSummary, direction: CGFloat) {
        guard let backend = model.backend else { return }
        given[candidate.id] = verdict
        Task {
            do {
                try await backend.vote(candidateId: candidate.id, verdict: verdict, veto: false)
                model.dataChanged()
            } catch {
                given[candidate.id] = nil
                self.error = model.message(for: error)
            }
        }
        withAnimation(.easeIn(duration: 0.22)) { drag = CGSize(width: direction * 700, height: direction == 0 ? -500 : 0) }
        Task {
            try? await Task.sleep(for: .milliseconds(230))
            drag = .zero
            slide = 0
            withAnimation(.easeOut(duration: 0.2)) { index += 1 }
        }
    }

    private func load() async {
        guard let backend = model.backend else { return }
        // The offer on screen and the one after it, so the next card is ready when the swipe ends.
        for position in [index, index + 1] where candidates.indices.contains(position) {
            let id = candidates[position].id
            guard details[id] == nil else { continue }
            do {
                let detail = try await backend.candidate(id)
                details[id] = detail
                failed.remove(id)
                if let cover = detail.gallery.first {
                    ImageLoader.shared.preload(cover.url, maxPixel: 1800, backend: backend)
                }
            } catch {
                failed.insert(id)
            }
        }
    }

    // MARK: End

    private var finished: some View {
        let yes = given.values.filter { $0 == .yes }.count
        let maybe = given.values.filter { $0 == .maybe }.count
        let no = given.values.filter { $0 == .no }.count
        return VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 60)).foregroundStyle(.green)
            Text("Alle \(candidates.count) Angebote durchgesehen").font(.title2.weight(.bold))
            Text("Deine Stimmen: \(yes) Ja, \(maybe) Vielleicht, \(no) Nein")
                .foregroundStyle(.secondary)
            Text("Sie stehen in der Angebotsliste und im Vergleich. Du kannst sie dort jederzeit ändern.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 14) {
                Button("Noch einmal") {
                    slide = 0
                    index = 0
                }
                .buttonStyle(.bordered)
                Button("Fertig") { dismiss() }.buttonStyle(.borderedProminent)
            }
        }
        .foregroundStyle(.white)
        .padding(32)
    }
}
