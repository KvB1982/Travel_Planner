import SwiftUI
import TravelPlannerKit

/// Summary of the guest reviews inside the profile, with a way to read every single one.
struct ReviewsSection: View {
    let reviews: Reviews
    let rating: Rating?
    /// Opens the list of single reviews. The sheet belongs to the surrounding screen, not to a list row.
    var showAll: () -> Void

    var body: some View {
        Section {
            if let rating, let value = rating.value {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                    Text(Format.number(value)).font(.title3.weight(.semibold))
                    if let scale = rating.scale { Text("von \(Format.number(scale))").foregroundStyle(.secondary) }
                    Spacer()
                    if let count = rating.count { Text("\(Format.number(count)) Bewertungen").foregroundStyle(.secondary) }
                }
            }
            if let summary = reviews.summary, !summary.isEmpty {
                Text(summary)
            }
            points(reviews.positives, symbol: "hand.thumbsup.fill", color: .green, label: "Gelobt")
            points(reviews.negatives, symbol: "hand.thumbsdown.fill", color: .orange, label: "Kritisiert")
            if let items = reviews.items, !items.isEmpty {
                Button(items.count == 1 ? "Die Bewertung lesen" : "Alle \(items.count) Bewertungen lesen", systemImage: "text.bubble") {
                    showAll()
                }
            }
        } header: {
            Text("Bewertungen")
        } footer: {
            if !(reviews.summary ?? "").isEmpty {
                Text(basis)
            }
        }
    }

    /// Says where the summary comes from, so nobody mistakes it for the platform's own text.
    private var basis: String {
        var text = "Automatisch zusammengefasst"
        if let count = reviews.basedOn, count > 0 { text += " aus \(Format.number(count)) Bewertungen" }
        if let date = reviews.generatedAt { text += ", Stand \(date.formatted(date: .abbreviated, time: .omitted))" }
        return text + ". Im Zweifel die Einzelbewertungen lesen."
    }

    @ViewBuilder
    private func points(_ list: [String]?, symbol: String, color: Color, label: String) -> some View {
        if let list, !list.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label(label, systemImage: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(color)
                ForEach(list, id: \.self) { point in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(point)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

struct ReviewList: View {
    let items: [Reviews.Item]
    /// Scale of the overall rating, used for reviews that do not name their own.
    var fallbackScale: Double?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(items) { item in
                ReviewRow(item: item, fallbackScale: fallbackScale)
            }
            .navigationTitle(items.count == 1 ? "1 Bewertung" : "\(items.count) Bewertungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
    }
}

private struct ReviewRow: View {
    let item: Reviews.Item
    var fallbackScale: Double?
    @State private var showOriginal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                if let rating = item.rating {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                        Text((item.scale ?? fallbackScale).map { "\(Format.number(rating)) von \(Format.number($0))" } ?? Format.number(rating))
                    }
                    .font(.subheadline.weight(.semibold))
                    .accessibilityElement(children: .combine)
                }
                Spacer()
                Text(byline).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
            if let title = item.title, !title.isEmpty { Text(title).font(.headline) }
            Text(shownText).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if item.translatedText != nil {
                Button(showOriginal ? "Übersetzung zeigen" : "Original zeigen") { showOriginal.toggle() }
                    .font(.footnote)
                    .buttonStyle(.borderless)
            }
            if let reply = item.ownerReply, !reply.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Antwort des Vermieters").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(reply).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(.vertical, 4)
    }

    private var shownText: String {
        if let translated = item.translatedText, !translated.isEmpty, !showOriginal { return translated }
        return item.text
    }

    private var byline: String {
        var parts: [String] = []
        if let author = item.author, !author.isEmpty { parts.append(author) }
        if let stay = item.stayType, !stay.isEmpty { parts.append(stay) }
        if let date = item.date, !date.isEmpty {
            // An exact day is shortened to month and year; anything else is the page's own wording and shown as is.
            parts.append(Format.day(date).map { $0.formatted(.dateTime.month(.abbreviated).year().locale(Locale(identifier: "de_DE"))) } ?? date)
        }
        if let platform = item.platform { parts.append(Format.platformName(platform)) }
        return parts.joined(separator: " · ")
    }
}
