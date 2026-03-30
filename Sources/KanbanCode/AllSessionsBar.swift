import SwiftUI
import KanbanCodeCore

struct AllSessionsBar: View {
    var store: BoardStore
    @State private var isExpanded = false

    private var sessionCards: [KanbanCodeCard] {
        let projectPath = store.state.selectedProjectPath
        return store.state.cards
            .filter { card in
                guard card.link.sessionLink != nil else { return false }
                guard let path = projectPath else { return true }
                let cardPath = card.link.projectPath ?? ""
                return cardPath == path || cardPath.hasPrefix(path + "/")
            }
            .sorted {
                let t0 = $0.link.lastActivity ?? $0.link.updatedAt
                let t1 = $1.link.lastActivity ?? $1.link.updatedAt
                return t0 > t1
            }
    }

    private var projects: [(name: String, path: String)] {
        var seen = Set<String>()
        var result: [(name: String, path: String)] = []
        for project in store.state.configuredProjects {
            guard !seen.contains(project.path) else { continue }
            seen.insert(project.path)
            let name = (project.path as NSString).lastPathComponent
            result.append((name: name, path: project.path))
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            // ── Header bar ──────────────────────────────────────────────
            HStack(spacing: 10) {
                Button {
                    withAnimation(.spring(duration: 0.25)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 11, weight: .medium))
                        Text("All Sessions")
                            .font(.system(size: 13, weight: .semibold))
                        Text("\(sessionCards.count)")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.up")
                            .font(.system(size: 10, weight: .bold))
                            .rotationEffect(.degrees(isExpanded ? 0 : 180))
                            .animation(.spring(duration: 0.25), value: isExpanded)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)

                if !projects.isEmpty {
                    Divider().frame(height: 16)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ProjectFilterPill(
                                label: "All",
                                isSelected: store.state.selectedProjectPath == nil
                            ) {
                                store.dispatch(.setSelectedProject(nil))
                            }
                            ForEach(projects, id: \.path) { project in
                                ProjectFilterPill(
                                    label: project.name,
                                    isSelected: store.state.selectedProjectPath == project.path
                                ) {
                                    let alreadySelected = store.state.selectedProjectPath == project.path
                                    store.dispatch(.setSelectedProject(alreadySelected ? nil : project.path))
                                }
                            }
                        }
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 40)

            // ── Expanded card grid ───────────────────────────────────────
            if isExpanded {
                Divider()
                if sessionCards.isEmpty {
                    Text("No archived sessions")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 8)],
                            spacing: 8
                        ) {
                            ForEach(sessionCards) { card in
                                ArchiveCardView(
                                    card: card,
                                    isSelected: store.state.selectedCardId == card.id
                                ) {
                                    let alreadySelected = store.state.selectedCardId == card.id
                                    store.dispatch(.selectCard(cardId: alreadySelected ? nil : card.id))
                                }
                            }
                        }
                        .padding(10)
                    }
                    .frame(maxHeight: 220)
                }
            }
        }
    }
}

// ── Project filter pill ──────────────────────────────────────────────────────

private struct ProjectFilterPill: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    isSelected ? Color.accentColor : Color.secondary.opacity(0.12),
                    in: Capsule()
                )
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
        }
        .buttonStyle(.plain)
    }
}

// ── Compact archive card ─────────────────────────────────────────────────────

private struct ArchiveCardView: View {
    let card: KanbanCodeCard
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 5) {
                Text(card.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .foregroundStyle(.primary)

                if let projectName = card.projectName {
                    Text(projectName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    if let branch = card.link.worktreeLink?.branch {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(card.relativeTime)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.12)
                    : Color.secondary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.5) : Color.clear,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
