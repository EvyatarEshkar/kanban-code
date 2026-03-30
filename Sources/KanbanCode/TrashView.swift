import SwiftUI
import KanbanCodeCore

struct TrashView: View {
    var store: BoardStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "trash")
                    .font(.app(.title3))
                Text("Trash")
                    .font(.app(.title3, weight: .semibold))
                Spacer()
                if !store.state.trashedCards.isEmpty {
                    Button(role: .destructive) {
                        for card in store.state.trashedCards {
                            store.dispatch(.deleteCard(cardId: card.id))
                        }
                    } label: {
                        Text("Empty Trash")
                            .font(.app(.callout))
                    }
                }
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.app(.title3))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider()

            if store.state.trashedCards.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "trash")
                        .font(.system(size: 40))
                        .foregroundStyle(.quaternary)
                    Text("Trash is empty")
                        .font(.app(.title3))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(store.state.trashedCards) { card in
                            TrashCardRow(card: card) {
                                store.dispatch(.restoreFromTrash(cardId: card.id))
                            } onDelete: {
                                store.dispatch(.deleteCard(cardId: card.id))
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 480, height: 420)
    }
}

private struct TrashCardRow: View {
    let card: KanbanCodeCard
    let onRestore: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(card.displayTitle)
                    .font(.app(.body, weight: .medium))
                    .lineLimit(1)
                if let object = card.link.object, !object.isEmpty {
                    Text(object)
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let projectName = card.projectName {
                    Label(projectName, systemImage: "folder")
                        .font(.app(.caption2))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button(action: onRestore) {
                Text("Restore")
                    .font(.app(.caption))
            }
            .buttonStyle(.bordered)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.app(.caption))
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}
