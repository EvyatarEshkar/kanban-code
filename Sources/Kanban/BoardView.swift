import SwiftUI
import KanbanCore

struct BoardView: View {
    @Bindable var state: BoardState
    var onStartCard: (String) -> Void = { _ in }
    var onResumeCard: (String) -> Void = { _ in }
    var onForkCard: (String) -> Void = { _ in }
    var onCopyResumeCmd: (String) -> Void = { _ in }
    var onCleanupWorktree: (String) -> Void = { _ in }
    var onDeleteCard: (String) -> Void = { _ in }
    var onRefreshBacklog: () -> Void = {}

    var onNewTask: () -> Void = {}

    var body: some View {
        boardContent
    }

    private var boardContent: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 6) {
                ForEach(state.visibleColumns, id: \.self) { column in
                    DroppableColumnView(
                        column: column,
                        cards: state.cards(in: column),
                        selectedCardId: $state.selectedCardId,
                        isRefreshingBacklog: state.isRefreshingBacklog,
                        onMoveCard: { cardId, targetColumn in
                            state.moveCard(cardId: cardId, to: targetColumn)
                        },
                        onRenameCard: { cardId, name in
                            state.renameCard(cardId: cardId, name: name)
                        },
                        onArchiveCard: { cardId in
                            state.archiveCard(cardId: cardId)
                        },
                        onStartCard: onStartCard,
                        onResumeCard: onResumeCard,
                        onForkCard: onForkCard,
                        onCopyResumeCmd: onCopyResumeCmd,
                        onCleanupWorktree: onCleanupWorktree,
                        onDeleteCard: onDeleteCard,
                        onRefreshBacklog: column == .backlog ? onRefreshBacklog : nil
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 52)
            .padding(.bottom, 16)
        }
        // Error banner at bottom
        .overlay(alignment: .bottom) {
            if let error = state.error {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer()
                    Button("Dismiss") { state.error = nil }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: state.error != nil)
        // Empty board hint
        .overlay {
            if state.filteredCards.isEmpty && !state.isLoading {
                VStack(spacing: 12) {
                    if let projectPath = state.selectedProjectPath {
                        let name = state.configuredProjects.first(where: { $0.path == projectPath })?.name
                            ?? (projectPath as NSString).lastPathComponent
                        Text("No sessions yet for \(name)")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No sessions found")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    Text("Create a new task or start a Claude session to get going.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    Button(action: onNewTask) {
                        Label("New Task", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
    }
}
