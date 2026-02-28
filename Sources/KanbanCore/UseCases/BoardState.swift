import Foundation

/// A card on the Kanban board, combining Link + Session data for display.
public struct KanbanCard: Identifiable, Sendable {
    public let id: String // link.id — stable across refreshes
    public let link: Link
    public let session: Session?
    public let activityState: ActivityState?

    public init(link: Link, session: Session? = nil, activityState: ActivityState? = nil) {
        self.id = link.id
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
        if let sid = link.sessionLink?.sessionId { return String(sid.prefix(8)) + "..." }
        return String(link.id.prefix(8)) + "..."
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

    /// Currently selected project path (nil = global/All Projects view).
    public var selectedProjectPath: String?

    /// Project paths discovered from sessions but not yet configured.
    public var discoveredProjectPaths: [String] = []

    /// Configured projects (refreshed from settings on each refresh).
    public var configuredProjects: [Project] = []

    /// Cached excluded paths for global view (refreshed from settings).
    private var excludedPaths: [String] = []

    /// Last time GitHub issues were fetched.
    public var lastGitHubRefresh: Date?

    /// Whether a GitHub issue refresh is currently running.
    public var isRefreshingBacklog = false

    private let discovery: SessionDiscovery
    private let coordinationStore: CoordinationStore
    private let activityDetector: ClaudeCodeActivityDetector?
    private let settingsStore: SettingsStore?
    private let ghAdapter: GhCliAdapter?

    public init(
        discovery: SessionDiscovery,
        coordinationStore: CoordinationStore,
        activityDetector: ClaudeCodeActivityDetector? = nil,
        settingsStore: SettingsStore? = nil,
        ghAdapter: GhCliAdapter? = nil
    ) {
        self.discovery = discovery
        self.coordinationStore = coordinationStore
        self.activityDetector = activityDetector
        self.settingsStore = settingsStore
        self.ghAdapter = ghAdapter
    }

    /// Cards visible after project filtering.
    public var filteredCards: [KanbanCard] {
        cards.filter { cardMatchesProjectFilter($0) }
    }

    /// Cards for a specific column, sorted by last activity (newest first).
    public func cards(in column: KanbanColumn) -> [KanbanCard] {
        filteredCards.filter { $0.column == column }
            .sorted { ($0.link.lastActivity ?? $0.link.updatedAt) > ($1.link.lastActivity ?? $1.link.updatedAt) }
    }

    /// Count of cards in a column.
    public func cardCount(in column: KanbanColumn) -> Int {
        filteredCards.filter { $0.column == column }.count
    }

    /// Check if a card matches the current project filter.
    private func cardMatchesProjectFilter(_ card: KanbanCard) -> Bool {
        guard let selectedPath = selectedProjectPath else {
            // Global view — apply exclusions
            return !isExcludedFromGlobalView(card)
        }
        // Project view — match by project path
        let cardPath = card.link.projectPath ?? card.session?.projectPath
        guard let cardPath else { return false }
        let normalizedCard = ProjectDiscovery.normalizePath(cardPath)
        let normalizedSelected = ProjectDiscovery.normalizePath(selectedPath)
        return normalizedCard == normalizedSelected || normalizedCard.hasPrefix(normalizedSelected + "/")
    }

    /// Check if a card should be excluded from the global view.
    private func isExcludedFromGlobalView(_ card: KanbanCard) -> Bool {
        guard !excludedPaths.isEmpty else { return false }
        let cardPath = card.link.projectPath ?? card.session?.projectPath
        guard let cardPath else { return false }
        let normalized = ProjectDiscovery.normalizePath(cardPath)
        for excluded in excludedPaths {
            let normalizedExcluded = ProjectDiscovery.normalizePath(excluded)
            if normalized == normalizedExcluded || normalized.hasPrefix(normalizedExcluded + "/") {
                return true
            }
        }
        return false
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

        Task {
            // Persist to our coordination store
            try? await coordinationStore.upsertLink(link)
            // Also update Claude's sessions-index.json so other tools see the rename
            if let sessionId = link.sessionLink?.sessionId {
                try? SessionIndexReader.updateSummary(sessionId: sessionId, summary: name)
            }
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

    /// Move a card to a different column (manual override — e.g. user drag).
    public func moveCard(cardId: String, to column: KanbanColumn) {
        setCardColumn(cardId: cardId, to: column, manualOverride: true)
    }

    /// Set a card's column programmatically (no manual override — auto-assignment can still take over).
    public func setCardColumn(cardId: String, to column: KanbanColumn, manualOverride: Bool = false) {
        guard let index = cards.firstIndex(where: { $0.id == cardId }) else { return }
        var link = cards[index].link
        link.column = column
        if manualOverride {
            link.manualOverrides.column = true
        }
        link.updatedAt = .now
        let session = cards[index].session
        let activity = cards[index].activityState
        cards[index] = KanbanCard(link: link, session: session, activityState: activity)

        Task {
            try? await coordinationStore.upsertLink(link)
        }
    }

    /// Full refresh: discover sessions, load links, merge, assign columns.
    public func refresh() async {
        isLoading = true
        error = nil

        do {
            // Load settings for project filtering
            if let store = settingsStore {
                let settings = try await store.read()
                configuredProjects = settings.projects
                excludedPaths = settings.globalView.excludedPaths
            }

            let sessions = try await discovery.discoverSessions()
            let existingLinks = try await coordinationStore.readLinks()
            let sessionsById = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

            // Reconcile: match sessions/worktrees/PRs to existing cards
            let snapshot = CardReconciler.DiscoverySnapshot(sessions: sessions)
            let mergedLinks = CardReconciler.reconcile(existing: existingLinks, snapshot: snapshot)
            var newCards: [KanbanCard] = []
            for link in mergedLinks {
                let sessionId = link.sessionLink?.sessionId ?? link.id
                let activity = await activityDetector?.activityState(for: sessionId)
                newCards.append(KanbanCard(
                    link: link,
                    session: link.sessionLink.flatMap { sessionsById[$0.sessionId] },
                    activityState: activity
                ))
            }

            cards = newCards
            lastRefresh = Date()

            // Compute discovered project paths
            let sessionPaths = newCards.map { $0.link.projectPath ?? $0.session?.projectPath }
            discoveredProjectPaths = ProjectDiscovery.findUnconfiguredPaths(
                sessionPaths: sessionPaths,
                configuredProjects: configuredProjects
            )

            // Persist merged links so manual overrides survive
            try? await coordinationStore.writeLinks(mergedLinks)

            // Fetch GitHub issues if enough time has elapsed
            await refreshGitHubIssuesIfNeeded()

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

    /// Force-refresh GitHub issues from all configured project filters.
    public func refreshBacklog() async {
        lastGitHubRefresh = nil // reset timer to force fetch
        isRefreshingBacklog = true
        await refreshGitHubIssues()
        isRefreshingBacklog = false
    }

    /// Fetch GitHub issues if enough time has elapsed since last fetch.
    private func refreshGitHubIssuesIfNeeded() async {
        guard ghAdapter != nil else { return }
        let interval: TimeInterval
        if let store = settingsStore, let settings = try? await store.read() {
            interval = TimeInterval(settings.github.pollIntervalSeconds)
        } else {
            interval = 300
        }
        if let last = lastGitHubRefresh, Date.now.timeIntervalSince(last) < interval {
            return
        }
        await refreshGitHubIssues()
    }

    /// Fetch GitHub issues from all configured project filters and sync to links.
    private func refreshGitHubIssues() async {
        guard let ghAdapter else { return }

        let settings: Settings?
        if let store = settingsStore {
            settings = try? await store.read()
        } else {
            settings = nil
        }
        guard let settings else { return }

        guard var links = try? await coordinationStore.readLinks() else { return }

        let defaultFilter = settings.github.defaultFilter
        var fetchedIssueKeys: Set<String> = [] // "projectPath:issueNumber"
        var changed = false

        for project in settings.projects {
            let filter = project.githubFilter ?? defaultFilter
            guard !filter.isEmpty else { continue }

            do {
                let issues = try await ghAdapter.fetchIssues(repoRoot: project.effectiveRepoRoot, filter: filter)
                for issue in issues {
                    let key = "\(project.path):\(issue.number)"
                    fetchedIssueKeys.insert(key)

                    // Check if link already exists
                    let existing = links.first(where: {
                        $0.issueLink?.number == issue.number && $0.projectPath == project.path
                    })
                    if existing == nil {
                        let link = Link(
                            name: "#\(issue.number): \(issue.title)",
                            projectPath: project.path,
                            column: .backlog,
                            source: .githubIssue,
                            issueLink: IssueLink(number: issue.number, body: issue.body)
                        )
                        links.append(link)
                        changed = true
                    }
                }
            } catch {
                // Silently continue — keep cached issues
            }
        }

        // Remove stale GitHub issue links (still in backlog, no longer in fetch results)
        let before = links.count
        links.removeAll { link in
            guard link.source == .githubIssue,
                  link.column == .backlog,
                  let issueNum = link.issueLink?.number,
                  let projPath = link.projectPath else { return false }
            let key = "\(projPath):\(issueNum)"
            return !fetchedIssueKeys.contains(key)
        }
        if links.count != before { changed = true }

        if changed {
            try? await coordinationStore.writeLinks(links)
            // Re-build cards from updated links
            let sessions = (try? await discovery.discoverSessions()) ?? []
            let sessionsById = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var newCards: [KanbanCard] = []
            for link in links {
                let activity: ActivityState?
                if let sessionId = link.sessionLink?.sessionId {
                    activity = await activityDetector?.activityState(for: sessionId)
                } else {
                    activity = nil
                }
                newCards.append(KanbanCard(
                    link: link,
                    session: link.sessionLink.flatMap { sessionsById[$0.sessionId] },
                    activityState: activity
                ))
            }
            cards = newCards
        }

        lastGitHubRefresh = Date()
    }
}
