import SwiftUI
import KanbanCore

struct CardView: View {
    let card: KanbanCard
    let isSelected: Bool
    var onSelect: () -> Void = {}
    var onStart: () -> Void = {}
    var onResume: () -> Void = {}
    var onFork: () -> Void = {}
    var onRename: () -> Void = {}
    var onCopyResumeCmd: () -> Void = {}
    var onArchive: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Title
            Text(card.displayTitle)
                .font(.system(.body, weight: .medium))
                .lineLimit(2)
                .foregroundStyle(.primary)

            // Project + branch + link icons
            HStack(spacing: 4) {
                if let projectName = card.projectName {
                    Label(projectName, systemImage: "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let branch = card.link.worktreeLink?.branch {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)

            // Bottom row: badge + time + link indicators + session number
            HStack(spacing: 6) {
                CardLabelBadge(label: card.link.cardLabel)

                Text(card.relativeTime)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            if card.isActivelyWorking {
                ProgressView()
                    .controlSize(.small)
                    .padding(6)
            } else if card.column == .backlog {
                Button(action: onStart) {
                    Image(systemName: "play.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.green, in: Circle())
                }
                .buttonStyle(.borderless)
                .help("Start task")
                .padding(4)
            }
        }
        .background(
            isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .contextMenu {
            if card.column == .backlog {
                Button(action: onStart) {
                    Label("Start", systemImage: "play.fill")
                }
            }
            if card.column != .backlog {
                Button(action: onResume) {
                    Label("Resume Session", systemImage: "play.fill")
                }
            }
            Button(action: onFork) {
                Label("Fork Session", systemImage: "arrow.branch")
            }
            Button(action: onRename) {
                Label("Rename", systemImage: "pencil")
            }
            Button(action: onCopyResumeCmd) {
                Label("Copy Resume Command", systemImage: "doc.on.doc")
            }
            Divider()
            if let pr = card.link.prLink?.number {
                Button(action: {}) {
                    Label("Open PR #\(pr)", systemImage: "arrow.up.right.square")
                }
            }
            Divider()
            Button(action: onArchive) {
                Label("Archive", systemImage: "archivebox")
            }
        }
    }
}

// MARK: - Card Label Badge

struct CardLabelBadge: View {
    let label: CardLabel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(label.rawValue)
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(colorScheme == .dark ? .black : .white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color, in: Capsule())
    }

    private var color: Color {
        switch label {
        case .session: .orange
        case .worktree: .teal
        case .issue: .blue
        case .pr: .purple
        case .task: .gray
        }
    }
}
