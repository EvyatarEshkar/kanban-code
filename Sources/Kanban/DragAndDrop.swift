import SwiftUI
import UniformTypeIdentifiers
import KanbanCore

/// Transferable data for dragging a card between columns.
struct CardDragData: Codable, Transferable {
    let cardId: String
    let sourceColumn: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .kanbanCard)
    }
}

extension UTType {
    static let kanbanCard = UTType(exportedAs: "com.kanban.card")
}

/// A column view that supports drag and drop.
struct DroppableColumnView: View {
    let column: KanbanColumn
    let cards: [KanbanCard]
    @Binding var selectedCardId: String?
    var onMoveCard: (String, KanbanColumn) -> Void = { _, _ in }
    var onRenameCard: (String, String) -> Void = { _, _ in }
    var onArchiveCard: (String) -> Void = { _ in }

    @State private var isTargeted = false
    @State private var renamingCardId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Column header
            HStack {
                Text(column.displayName)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer()

                Text("\(cards.count)")
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.2)))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // Card list
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(cards) { card in
                        CardView(
                            card: card,
                            isSelected: card.id == selectedCardId,
                            onSelect: {
                                selectedCardId = selectedCardId == card.id ? nil : card.id
                            },
                            onRename: {
                                renamingCardId = card.id
                            },
                            onArchive: {
                                onArchiveCard(card.id)
                            }
                        )
                        .draggable(CardDragData(cardId: card.id, sourceColumn: column.rawValue))
                        .sheet(isPresented: Binding(
                            get: { renamingCardId == card.id },
                            set: { if !$0 { renamingCardId = nil } }
                        )) {
                            RenameSessionDialog(
                                currentName: card.link.name ?? card.displayTitle,
                                isPresented: Binding(
                                    get: { renamingCardId == card.id },
                                    set: { if !$0 { renamingCardId = nil } }
                                ),
                                onRename: { name in
                                    onRenameCard(card.id, name)
                                }
                            )
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
        }
        .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
        .glassColumn()
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isTargeted ? Color.accentColor.opacity(0.5) : Color.clear,
                    lineWidth: isTargeted ? 2 : 0
                )
        )
        .dropDestination(for: CardDragData.self) { items, _ in
            guard let item = items.first else { return false }
            if item.sourceColumn != column.rawValue {
                onMoveCard(item.cardId, column)
            }
            return true
        } isTargeted: { targeted in
            withAnimation(.easeInOut(duration: 0.15)) {
                isTargeted = targeted
            }
        }
    }
}
