import SwiftUI
import TravelPlannerKit

/// The adverts an offer is known from, and the search for the same house on other platforms.
struct SourcesSection: View {
    @Environment(\.openURL) private var openURL
    let detail: CandidateDetail
    let canEdit: Bool
    /// Asks the server to read the offer again.
    var refresh: () -> Void
    /// Opens the advert of one source inside the app to read it on this device.
    var readOnDevice: (ListingSource) -> Void
    var removeSource: (ListingSource) -> Void
    var search: () -> Void
    var decide: (OtherPlatforms.Suggestion, Bool) -> Void
    var addLink: () -> Void

    private var isReady: Bool { detail.candidate.importStatus == .ready }

    var body: some View {
        Section {
            ForEach(Array(detail.sources.enumerated()), id: \.element.id) { index, source in
                // On servers that do not say which source leads, it is the first one.
                sourceRow(source, leading: source.primary ?? (index == 0))
            }
            if canEdit, detail.candidate.importStatus != .pending, !detail.sources.isEmpty {
                Button("Aktualisieren", systemImage: "arrow.clockwise", action: refresh)
            }
            LabeledContent("Steckbrief gefüllt", value: "\(detail.listing.fillPercent) %")
        } header: {
            Text("Quellen")
        } footer: {
            if canEdit, !detail.sources.isEmpty {
                Text("„Aktualisieren“ lässt den Server das Inserat neu abrufen. „Auf diesem Gerät“ öffnet es hier in der App, wenn die Plattform den Server sperrt oder du Preis, Bilder und Bewertungen nachtragen willst.")
            }
        }

        if let other = detail.otherPlatforms, canEdit {
            otherPlatforms(other)
        }
    }

    @ViewBuilder
    private func sourceRow(_ source: ListingSource, leading: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(Format.platformName(source.platform)).font(.headline)
                if leading && detail.sources.count > 1 {
                    Text("führend").font(.caption).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
                }
                Spacer()
                if let rating = source.rating, let value = rating.value {
                    HStack(spacing: 3) {
                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                        Text(Format.number(value) + (rating.count.map { " (\(Format.number($0)))" } ?? ""))
                    }
                    .font(.subheadline)
                }
            }
            if let title = source.title, !title.isEmpty, title != detail.listing.title {
                Text(title).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            if source.needsDevice == true {
                Label("Die Plattform sperrt den Server. Bitte auf diesem Gerät auslesen.", systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.orange)
            } else if source.read == false {
                Label("Noch nicht gelesen", systemImage: "clock").font(.footnote).foregroundStyle(.secondary)
            } else if let count = source.reviewCount, count > 0 {
                Text(count == 1 ? "1 Bewertung gelesen" : "\(Format.number(count)) Bewertungen gelesen").font(.footnote).foregroundStyle(.secondary)
            }
            // Side by side where there is room, one below the other on a narrow phone, never wrapped mid-label.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { sourceActions(source, leading: leading) }
                VStack(alignment: .leading, spacing: 10) { sourceActions(source, leading: leading) }
            }
            .font(.subheadline)
            .buttonStyle(.borderless)
            .labelStyle(.titleAndIcon)
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canEdit && !leading {
                Button("Entfernen", systemImage: "minus.circle") { removeSource(source) }.tint(.red)
            }
        }
    }

    @ViewBuilder
    private func sourceActions(_ source: ListingSource, leading: Bool) -> some View {
        if let url = URL(string: source.url) {
            Button("Öffnen", systemImage: "safari") { openURL(url) }.fixedSize()
        }
        // For the leading source of an unfinished offer the prominent button at the top does this.
        if canEdit, !leading || isReady {
            Button(source.needsDevice == true || source.read == false ? "Auf diesem Gerät auslesen" : "Auf diesem Gerät aktualisieren",
                   systemImage: "iphone.and.arrow.forward") { readOnDevice(source) }
                .fixedSize()
        }
    }

    @ViewBuilder
    private func otherPlatforms(_ other: OtherPlatforms) -> some View {
        Section {
            ForEach(other.open) { suggestion in
                suggestionRow(suggestion)
            }
            if other.isRunning {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Suche läuft, das dauert bis zu einer Minute …").foregroundStyle(.secondary)
                }
            } else {
                if let note = other.note, !note.isEmpty, other.open.isEmpty {
                    Text(note).font(.callout).foregroundStyle(.secondary)
                }
                if other.available != false {
                    Button(other.searchedAt == nil ? "Auf anderen Plattformen suchen" : "Erneut suchen", systemImage: "magnifyingglass", action: search)
                }
                Button("Link von Hand hinzufügen", systemImage: "link.badge.plus", action: addLink)
            }
        } header: {
            Text("Dasselbe Haus auf anderen Plattformen")
        } footer: {
            if other.available == false {
                Text("Die Suche ist auf dem Server nicht eingerichtet. Links lassen sich von Hand hinzufügen.")
            } else {
                Text("Die Suche läuft über den Server und kostet jedes Mal etwas, deshalb startet sie nur auf Knopfdruck. Treffer sind Vorschläge: Ob es wirklich dasselbe Haus ist, entscheidest du. Bestätigte Treffer bringen ihre Bewertungen und Preise mit.")
            }
        }
    }

    private func suggestionRow(_ suggestion: OtherPlatforms.Suggestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(Format.platformName(suggestion.platform)).font(.headline)
                Spacer()
                if let confidence = suggestion.confidence {
                    Text(confidenceLabel(confidence))
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
            if let title = suggestion.title, !title.isEmpty { Text(title).font(.subheadline) }
            if let reason = suggestion.reason, !reason.isEmpty { Text(reason).font(.footnote).foregroundStyle(.secondary) }
            HStack(spacing: 16) {
                if let url = URL(string: suggestion.url) {
                    Button("Ansehen", systemImage: "safari") { openURL(url) }
                }
                Button("Dasselbe Haus", systemImage: "checkmark.circle") { decide(suggestion, true) }
                Button("Nein", systemImage: "xmark.circle") { decide(suggestion, false) }.tint(.secondary)
            }
            .font(.subheadline)
            .buttonStyle(.borderless)
            .labelStyle(.titleAndIcon)
        }
        .padding(.vertical, 2)
    }

    private func confidenceLabel(_ confidence: OtherPlatforms.Confidence) -> String {
        switch confidence {
        case .high: "passt wahrscheinlich"
        case .medium: "passt vielleicht"
        case .low: "unsicher"
        }
    }
}
