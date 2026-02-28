import Foundation

/// A card on the Kanban board, combining Link + Session data for display.
public struct KanbanCard: Identifiable, Sendable {
    public let id: String // sessionId — stable across refreshes
    public let link: Link
    public let session: Session?
    public let activityState: ActivityState?

    public init(link: Link, session: Session? = nil, activityState: ActivityState? = nil) {
        self.id = link.sessionId
        self.link = link
        self.session = session
        self.activityState = activityState
    }

    /// Whether Claude is confirmed actively working right now (not just waiting).
    public var isActivelyWorking: Bool {
        activityState == .activelyWorking
    }

    /// Best display title: link name → session display title → session ID prefix.
    public var displayTitle: String {
        if let name = link.name, !name.isEmpty { return name }
        if let session { return session.displayTitle }
        return String(link.sessionId.prefix(8)) + "..."
    }

    /// Project name extracted from project path.
    public var projectName: String? {
        guard let path = link.projectPath ?? session?.projectPath else { return nil }
        return (path as NSString).lastPathComponent
    }

    /// Relative time since last activity.
    public var relativeTime: String {
        let date = link.lastActivity ?? link.updatedAt
        return Self.formatRelativeTime(date)
    }

    /// The column this card is in.
    public var column: KanbanColumn { link.column }

    static func formatRelativeTime(_ date: Date) -> String {
        let interval = Date.now.timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        let days = Int(interval / 86400)
        if days == 1 { return "yesterday" }
        if days < 30 { return "\(days)d ago" }
        return "\(days / 30)mo ago"
    }
}

/// Observable state for the Kanban board.
/// Holds all cards grouped by column, handles refresh from discovery + coordination.
@Observable
public final class BoardState: @unchecked Sendable {
    public var cards: [KanbanCard] = []
    public var selectedCardId: String?
    public var isLoading: Bool = false
    public var lastRefresh: Date?
    public var error: String?

    private let discovery: SessionDiscovery
    private let coordinationStore: CoordinationStore
    private let activityDetector: ClaudeCodeActivityDetector?

    public init(
        discovery: SessionDiscovery,
        coordinationStore: CoordinationStore,
        activityDetector: ClaudeCodeActivityDetector? = nil
    ) {
        self.discovery = discovery
        self.coordinationStore = coordinationStore
        self.activityDetector = activityDetector
    }

    /// Cards for a specific column, sorted by last activity (newest first).
    public func cards(in column: KanbanColumn) -> [KanbanCard] {
        cards.filter { $0.column == column }
            .sorted { ($0.link.lastActivity ?? $0.link.updatedAt) > ($1.link.lastActivity ?? $1.link.updatedAt) }
    }

    /// Count of cards in a column.
    public func cardCount(in column: KanbanColumn) -> Int {
        cards.filter { $0.column == column }.count
    }

    /// The visible columns (non-empty or always-shown).
    public var visibleColumns: [KanbanColumn] {
        // Always show the main workflow columns; show allSessions only if it has cards
        let alwaysVisible: [KanbanColumn] = [.backlog, .inProgress, .requiresAttention, .inReview, .done]
        var result = alwaysVisible
        if cardCount(in: .allSessions) > 0 {
            result.append(.allSessions)
        }
        return result
    }

    /// Rename a card (manual override).
    public func renameCard(cardId: String, name: String) {
        guard let index = cards.firstIndex(where: { $0.id == cardId }) else { return }
        var link = cards[index].link
        link.name = name
        link.manualOverrides.name = true
        link.updatedAt = .now
        let session = cards[index].session
        let activity = cards[index].activityState
        cards[index] = KanbanCard(link: link, session: session, activityState: activity)

        let sessionId = link.sessionId
        Task {
            // Persist to our coordination store
            try? await coordinationStore.upsertLink(link)
            // Also update Claude's sessions-index.json so other tools see the rename
            try? SessionIndexReader.updateSummary(sessionId: sessionId, summary: name)
        }
    }

    /// Archive a card — sets manuallyArchived and moves to allSessions.
    public func archiveCard(cardId: String) {
        guard let index = cards.firstIndex(where: { $0.id == cardId }) else { return }
        var link = cards[index].link
        link.manuallyArchived = true
        link.column = .allSessions
        link.updatedAt = .now
        let session = cards[index].session
        let activity = cards[index].activityState
        cards[index] = KanbanCard(link: link, session: session, activityState: activity)

        Task {
            try? await coordinationStore.upsertLink(link)
        }
    }

    /// Move a card to a different column (manual override).
    public func moveCard(cardId: String, to column: KanbanColumn) {
        guard let index = cards.firstIndex(where: { $0.id == cardId }) else { return }
        var link = cards[index].link
        link.column = column
        link.manualOverrides.column = true
        link.updatedAt = .now
        let session = cards[index].session
        let activity = cards[index].activityState
        cards[index] = KanbanCard(link: link, session: session, activityState: activity)

        // Persist — use upsertLink so discovered-only links get written too
        Task {
            try? await coordinationStore.upsertLink(link)
        }
    }

    /// Full refresh: discover sessions, load links, merge, assign columns.
    public func refresh() async {
        isLoading = true
        error = nil

        do {
            let sessions = try await discovery.discoverSessions()
            var links = try await coordinationStore.readLinks()
            let sessionsById = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

            // Create links for newly discovered sessions
            var linksById = Dictionary(links.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })

            for session in sessions {
                if linksById[session.id] == nil {
                    let newLink = Link(
                        sessionId: session.id,
                        sessionPath: session.jsonlPath,
                        projectPath: session.projectPath,
                        column: .allSessions,
                        lastActivity: session.modifiedTime,
                        source: .discovered
                    )
                    linksById[session.id] = newLink
                    links.append(newLink)
                } else {
                    // Update existing link with latest session data (non-override fields)
                    var link = linksById[session.id]!
                    link.sessionPath = session.jsonlPath
                    link.lastActivity = session.modifiedTime
                    if !link.manualOverrides.column {
                        let activity = await activityDetector?.activityState(for: session.id)
                        link.column = AssignColumn.assign(link: link, activityState: activity)
                    }
                    linksById[session.id] = link
                }
            }

            // Build cards with activity states
            let mergedLinks = Array(linksById.values)
            var newCards: [KanbanCard] = []
            for link in mergedLinks {
                let activity = await activityDetector?.activityState(for: link.sessionId)
                newCards.append(KanbanCard(
                    link: link,
                    session: sessionsById[link.sessionId],
                    activityState: activity
                ))
            }

            cards = newCards
            lastRefresh = Date()

            // Persist merged links so manual overrides survive
            try? await coordinationStore.writeLinks(mergedLinks)

            // Validate selected card still exists
            if let selectedId = selectedCardId,
               !newCards.contains(where: { $0.id == selectedId }) {
                selectedCardId = nil
            }
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }
}
