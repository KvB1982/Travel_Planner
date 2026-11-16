import SwiftUI
import TravelPlannerKit

/// Packing, shopping and tasks of a trip, ticked off together.
struct ChecklistSections: View {
    @Environment(AppModel.self) private var model
    let tripID: String
    let role: MemberRole

    @State private var lists: Checklists?
    @State private var shown = "packing"
    @State private var newTitle = ""
    @State private var onlyMine = false
    @State private var error: String?
    @FocusState private var typing: Bool

    private var current: Checklists.List? { lists?.lists.first { $0.list == shown } ?? lists?.lists.first }

    var body: some View {
        Group {
            if let error { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) } }
            if let lists {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(lists.lists) { list in
                                Button { shown = list.list } label: {
                                    Label("\(list.label) \(list.done)/\(list.items.count)", systemImage: list.symbol)
                                        .font(.subheadline.weight(.medium))
                                        .padding(.horizontal, 12).padding(.vertical, 7)
                                        .background(list.list == current?.list ? Color.accentColor : Color(.secondarySystemFill), in: Capsule())
                                        .foregroundStyle(list.list == current?.list ? Color.white : Color.primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 0))
                }
                .listSectionSpacing(.compact)
                if let current {
                    Section {
                        ForEach(current.items.sorted { !$0.done && $1.done }) { item in row(item) }
                        HStack {
                            Image(systemName: "plus.circle").foregroundStyle(.tint)
                            TextField(current.list == "todo" ? "Neue Aufgabe" : "Neuer Eintrag", text: $newTitle)
                                .focused($typing)
                                .submitLabel(.done)
                                .onSubmit(add)
                            if !newTitle.trimmingCharacters(in: .whitespaces).isEmpty {
                                Button("Hinzufügen", action: add).buttonStyle(.borderless)
                            }
                        }
                        if current.items.isEmpty {
                            Text("Noch nichts auf dieser Liste.").font(.footnote).foregroundStyle(.secondary).listRowSeparator(.hidden)
                        }
                    } header: {
                        Text(current.label)
                    }
                    Section {
                        Toggle("Nur für mich eintragen", isOn: $onlyMine)
                        let fitting = lists.templates.filter { $0.list == current.list }
                        if role.canEdit, !fitting.isEmpty {
                            Menu {
                                ForEach(fitting) { template in
                                    Button(template.count.map { "\(template.label) (\($0))" } ?? template.label) {
                                        run { try await $0.applyChecklistTemplate(tripId: tripID, template: template.key) }
                                    }
                                }
                            } label: {
                                Label("Vorlage einfügen", systemImage: "doc.on.doc")
                            }
                        }
                        Text("Persönliche Einträge siehst nur du. Eine Vorlage ergänzt, was noch fehlt, vorhandene Einträge bleiben.")
                            .font(.footnote).foregroundStyle(.secondary).listRowSeparator(.hidden)
                    }
                }
            } else if error == nil {
                Section { HStack { ProgressView(); Text("Lade die Listen …").foregroundStyle(.secondary) } }
            }
        }
        .task(id: model.revision) { run { try await $0.checklists(tripId: tripID) } }
    }

    private func row(_ item: ChecklistItem) -> some View {
        Button {
            run { try await $0.updateChecklistItem(itemId: item.id, change: ChecklistChange(done: !item.done)) }
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle").foregroundStyle(item.done ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).strikethrough(item.done).foregroundStyle(item.done ? Color.secondary : Color.primary)
                    let notes = [item.quantity, item.dueOn.flatMap(Format.day).map { "bis \($0.formatted(.dateTime.day().month().locale(Locale(identifier: "de_DE"))))" },
                                 item.isPrivate ? "nur für dich" : nil].compactMap { $0 }
                    if !notes.isEmpty { Text(notes.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary) }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.title), \(item.done ? "erledigt" : "offen")")
        .swipeActions {
            Button("Löschen", systemImage: "trash", role: .destructive) { run { try await $0.deleteChecklistItem(itemId: item.id) } }
        }
    }

    private func add() {
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, let list = current?.list else { return }
        newTitle = ""
        let mine = onlyMine
        run { try await $0.addChecklistItem(tripId: tripID, list: list, title: title, quantity: nil, isPrivate: mine) }
        typing = true
    }

    private func run(_ action: @escaping (any TravelBackend) async throws -> Checklists) {
        guard let backend = model.backend else { return }
        Task {
            do {
                lists = try await action(backend)
                error = nil
            } catch is CancellationError {
            } catch {
                self.error = model.message(for: error)
            }
        }
    }
}
