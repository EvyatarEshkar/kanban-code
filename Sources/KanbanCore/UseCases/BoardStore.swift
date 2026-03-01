import Foundation

// MARK: - AppState

/// Single source of truth for the entire board.
/// All mutations go through the Reducer — no direct writes.
public struct AppState: Sendable {
    public var links: [String: Link] = [:]                     // cardId → Link
    public var sessions: [String: Session] = [:]               // sessionId → Session
    public var activityMap: [String: ActivityState] = [:]       // sessionId → activity
    public var tmuxSessions: Set<String> = []                  // live tmux names
    public var selectedCardId: String?
    public var selectedProjectPath: String?
    public var error: String?
    public var isLoading: Bool = false
    public var lastRefresh: Date?

    /// Configured projects (refreshed from settings on each reconciliation).
    public var configuredProjects: [Project] = []
    /// Cached excluded paths for global view.
    public var excludedPaths: [String] = []
    /// Project paths discovered from sessions but not yet configured.
    public var discoveredProjectPaths: [String] = []

    /// Last time GitHub issues were fetched.
    public var lastGitHubRefresh: Date?
    /// Whether a GitHub issue refresh is currently running.
    public var isRefreshingBacklog = false

    // MARK: - Derived

    /// All cards, built from links + sessions + activity.
    public var cards: [KanbanCard] {
        links.values.map { link in
            let session = link.sessionLink.flatMap { sessions[$0.sessionId] }
            let activity = link.sessionLink.flatMap { activityMap[$0.sessionId] }
            return KanbanCard(link: link, session: session, activityState: activity)
        }
    }

    /// Cards visible after project filtering.
    public var filteredCards: [KanbanCard] {
        cards.filter { cardMatchesProjectFilter($0) }
    }

    /// Cards for a specific column, sorted by last activity (newest first).
    public func cards(in column: KanbanColumn) -> [KanbanCard] {
        filteredCards.filter { $0.column == column }
            .sorted {
                let t0 = $0.link.lastActivity ?? $0.link.updatedAt
                let t1 = $1.link.lastActivity ?? $1.link.updatedAt
                if t0 != t1 { return t0 > t1 }
                return $0.id < $1.id
            }
    }

    public func cardCount(in column: KanbanColumn) -> Int {
        filteredCards.filter { $0.column == column }.count
    }

    /// The visible columns (non-empty or always-shown).
    public var visibleColumns: [KanbanColumn] {
        let alwaysVisible: [KanbanColumn] = [.backlog, .inProgress, .waiting, .inReview, .done]
        var result = alwaysVisible
        if cardCount(in: .allSessions) > 0 {
            result.append(.allSessions)
        }
        return result
    }

    private func cardMatchesProjectFilter(_ card: KanbanCard) -> Bool {
        guard let selectedPath = selectedProjectPath else {
            return !isExcludedFromGlobalView(card)
        }
        let cardPath = card.link.projectPath ?? card.session?.projectPath
        guard let cardPath else { return false }
        let normalizedCard = ProjectDiscovery.normalizePath(cardPath)
        let normalizedSelected = ProjectDiscovery.normalizePath(selectedPath)
        return normalizedCard == normalizedSelected || normalizedCard.hasPrefix(normalizedSelected + "/")
    }

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

    public init() {}
}

// MARK: - Action

/// Exhaustive enum of everything that can happen to the board.
public enum Action: Sendable {
    // UI actions
    case createManualTask(Link)
    case createTerminal(cardId: String)
    case addExtraTerminal(cardId: String, sessionName: String)
    case launchCard(cardId: String, prompt: String, projectPath: String, worktreeName: String?, runRemotely: Bool, commandOverride: String?)
    case resumeCard(cardId: String)
    case moveCard(cardId: String, to: KanbanColumn)
    case renameCard(cardId: String, name: String)
    case archiveCard(cardId: String)
    case deleteCard(cardId: String)
    case selectCard(cardId: String?)
    case unlinkFromCard(cardId: String, linkType: LinkType)
    case killTerminal(cardId: String, sessionName: String)
    case addBranchToCard(cardId: String, branch: String)
    case addIssueLinkToCard(cardId: String, issueNumber: Int)

    // Async completions
    case launchCompleted(cardId: String, tmuxName: String, sessionLink: SessionLink?, isRemote: Bool)
    case launchFailed(cardId: String, error: String)
    case resumeCompleted(cardId: String, tmuxName: String)
    case resumeFailed(cardId: String, error: String)
    case terminalCreated(cardId: String, tmuxName: String)
    case terminalFailed(cardId: String, error: String)
    case extraTerminalCreated(cardId: String, sessionName: String)

    // Background reconciliation
    case reconciled(ReconciliationResult)
    case gitHubIssuesUpdated(links: [Link])

    // Settings / misc
    case setError(String?)
    case setSelectedProject(String?)
    case setLoading(Bool)
    case setIsRefreshingBacklog(Bool)

    public enum LinkType: Sendable {
        case pr, issue, worktree, tmux
    }
}

/// Bundles the result of a full background reconciliation cycle.
public struct ReconciliationResult: Sendable {
    public let links: [Link]
    public let sessions: [Session]
    public let activityMap: [String: ActivityState]
    public let tmuxSessions: Set<String>
    public let configuredProjects: [Project]
    public let excludedPaths: [String]
    public let discoveredProjectPaths: [String]

    public init(
        links: [Link],
        sessions: [Session],
        activityMap: [String: ActivityState],
        tmuxSessions: Set<String>,
        configuredProjects: [Project] = [],
        excludedPaths: [String] = [],
        discoveredProjectPaths: [String] = []
    ) {
        self.links = links
        self.sessions = sessions
        self.activityMap = activityMap
        self.tmuxSessions = tmuxSessions
        self.configuredProjects = configuredProjects
        self.excludedPaths = excludedPaths
        self.discoveredProjectPaths = discoveredProjectPaths
    }
}

// MARK: - Effect

/// Side effects returned by the reducer. Executed asynchronously by EffectHandler.
public enum Effect: Sendable {
    case persistLinks([Link])
    case upsertLink(Link)
    case removeLink(String) // id
    case createTmuxSession(cardId: String, name: String, path: String)
    case killTmuxSession(String) // name
    case killTmuxSessions([String])
    case deleteSessionFile(String) // path
    case cleanupTerminalCache(sessionNames: [String])
    case refreshDiscovery
    case updateSessionIndex(sessionId: String, name: String)
}

// MARK: - Reducer

/// Pure function: (state, action) → (state', effects).
/// No async. No side effects. Fully testable.
public enum Reducer {
    public static func reduce(state: inout AppState, action: Action) -> [Effect] {
        switch action {

        // MARK: UI Actions

        case .createManualTask(let link):
            state.links[link.id] = link
            return [.upsertLink(link)]

        case .createTerminal(let cardId):
            guard var link = state.links[cardId] else { return [] }
            let projectName = link.projectPath.map { ($0 as NSString).lastPathComponent } ?? "shell"
            let tmuxName = "\(projectName)-\(link.id)"
            link.tmuxLink = TmuxLink(sessionName: tmuxName, isShellOnly: true)
            // Do NOT change column. Terminal ≠ in progress.
            link.updatedAt = .now
            state.links[cardId] = link
            let workDir = link.worktreeLink?.path.isEmpty == false
                ? link.worktreeLink!.path
                : (link.projectPath ?? NSHomeDirectory())
            return [.createTmuxSession(cardId: cardId, name: tmuxName, path: workDir), .upsertLink(link)]

        case .addExtraTerminal(let cardId, let sessionName):
            guard var link = state.links[cardId] else { return [] }
            let workDir = link.worktreeLink?.path.isEmpty == false
                ? link.worktreeLink!.path
                : (link.projectPath ?? NSHomeDirectory())
            // Add to extra sessions list
            var extras = link.tmuxLink?.extraSessions ?? []
            extras.append(sessionName)
            link.tmuxLink?.extraSessions = extras
            link.updatedAt = .now
            state.links[cardId] = link
            return [.createTmuxSession(cardId: cardId, name: sessionName, path: workDir), .upsertLink(link)]

        case .launchCard(let cardId, _, let projectPath, let worktreeName, _, _):
            guard var link = state.links[cardId] else { return [] }
            let projectName = (projectPath as NSString).lastPathComponent
            let tmuxName = worktreeName != nil
                ? "\(projectName)-\(worktreeName!)"
                : "\(projectName)-\(cardId)"
            link.tmuxLink = TmuxLink(sessionName: tmuxName)
            link.column = .inProgress
            link.isLaunching = true
            link.updatedAt = .now
            state.links[cardId] = link
            state.selectedCardId = cardId
            KanbanLog.info("store", "Launch: card=\(cardId.prefix(12)) tmux=\(tmuxName)")
            return [.upsertLink(link)]

        case .resumeCard(let cardId):
            guard var link = state.links[cardId] else { return [] }
            let sid = link.sessionLink?.sessionId ?? link.id
            let tmuxName = "claude-\(String(sid.prefix(8)))"
            link.tmuxLink = TmuxLink(sessionName: tmuxName)
            link.column = .inProgress
            link.isLaunching = true
            link.updatedAt = .now
            state.links[cardId] = link
            state.selectedCardId = cardId
            KanbanLog.info("store", "Resume: card=\(cardId.prefix(12)) tmux=\(tmuxName)")
            return [.upsertLink(link)]

        case .moveCard(let cardId, let column):
            guard var link = state.links[cardId] else { return [] }
            link.column = column
            link.manualOverrides.column = true
            if column == .allSessions {
                link.manuallyArchived = true
            } else if link.manuallyArchived {
                link.manuallyArchived = false
            }
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

        case .renameCard(let cardId, let name):
            guard var link = state.links[cardId] else { return [] }
            link.name = name
            link.manualOverrides.name = true
            link.updatedAt = .now
            state.links[cardId] = link
            var effects: [Effect] = [.upsertLink(link)]
            if let sessionId = link.sessionLink?.sessionId {
                effects.append(.updateSessionIndex(sessionId: sessionId, name: name))
            }
            return effects

        case .archiveCard(let cardId):
            guard var link = state.links[cardId] else { return [] }
            link.manuallyArchived = true
            link.column = .allSessions
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

        case .deleteCard(let cardId):
            guard let link = state.links.removeValue(forKey: cardId) else { return [] }
            if state.selectedCardId == cardId { state.selectedCardId = nil }
            var effects: [Effect] = [.removeLink(cardId)]
            if let tmux = link.tmuxLink {
                effects.append(.killTmuxSessions(tmux.allSessionNames))
                effects.append(.cleanupTerminalCache(sessionNames: tmux.allSessionNames))
            }
            if let sessionPath = link.sessionLink?.sessionPath {
                effects.append(.deleteSessionFile(sessionPath))
            }
            return effects

        case .selectCard(let cardId):
            state.selectedCardId = cardId
            return []

        case .unlinkFromCard(let cardId, let linkType):
            guard var link = state.links[cardId] else { return [] }
            switch linkType {
            case .pr:
                link.prLinks = []
                link.manualOverrides.prLink = true
            case .issue:
                link.issueLink = nil
                link.manualOverrides.issueLink = true
            case .worktree:
                link.worktreeLink = nil
                link.manualOverrides.worktreePath = true
            case .tmux:
                link.tmuxLink = nil
                link.manualOverrides.tmuxSession = true
            }
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

        case .killTerminal(let cardId, let sessionName):
            guard var link = state.links[cardId] else { return [] }
            link.tmuxLink?.extraSessions?.removeAll { $0 == sessionName }
            if link.tmuxLink?.extraSessions?.isEmpty == true {
                link.tmuxLink?.extraSessions = nil
            }
            link.updatedAt = .now
            state.links[cardId] = link
            return [.killTmuxSession(sessionName), .upsertLink(link), .cleanupTerminalCache(sessionNames: [sessionName])]

        case .addBranchToCard(let cardId, let branch):
            guard var link = state.links[cardId] else { return [] }
            if link.worktreeLink != nil {
                link.worktreeLink?.branch = branch
            } else {
                link.worktreeLink = WorktreeLink(path: "", branch: branch)
            }
            link.manualOverrides.worktreePath = true
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

        case .addIssueLinkToCard(let cardId, let issueNumber):
            guard var link = state.links[cardId] else { return [] }
            link.issueLink = IssueLink(number: issueNumber)
            link.manualOverrides.issueLink = true
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

        // MARK: Async Completions

        case .launchCompleted(let cardId, let tmuxName, let sessionLink, let isRemote):
            guard var link = state.links[cardId] else { return [] }
            link.tmuxLink = TmuxLink(sessionName: tmuxName)
            if let sl = sessionLink { link.sessionLink = sl }
            link.isLaunching = nil
            link.isRemote = isRemote
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

        case .launchFailed(let cardId, let error):
            guard var link = state.links[cardId] else { return [] }
            link.tmuxLink = nil
            link.isLaunching = nil
            link.updatedAt = .now
            state.links[cardId] = link
            state.error = "Launch failed: \(error)"
            return [.upsertLink(link)]

        case .resumeCompleted(let cardId, let tmuxName):
            guard var link = state.links[cardId] else { return [] }
            link.tmuxLink = TmuxLink(sessionName: tmuxName)
            link.isLaunching = nil
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

        case .resumeFailed(let cardId, let error):
            guard var link = state.links[cardId] else { return [] }
            link.tmuxLink = nil
            link.isLaunching = nil
            link.updatedAt = .now
            state.links[cardId] = link
            state.error = "Resume failed: \(error)"
            return [.upsertLink(link)]

        case .terminalCreated:
            // Terminal was created successfully — link already updated in createTerminal/addExtraTerminal
            return []

        case .terminalFailed(let cardId, let error):
            guard var link = state.links[cardId] else { return [] }
            link.tmuxLink = nil
            link.updatedAt = .now
            state.links[cardId] = link
            state.error = "Terminal failed: \(error)"
            return [.upsertLink(link)]

        case .extraTerminalCreated:
            // Extra terminal was created — link already updated in addExtraTerminal
            return []

        // MARK: Background Reconciliation

        case .reconciled(let result):
            state.tmuxSessions = result.tmuxSessions
            state.configuredProjects = result.configuredProjects
            state.excludedPaths = result.excludedPaths
            state.discoveredProjectPaths = result.discoveredProjectPaths

            // Rebuild sessions map
            state.sessions = Dictionary(
                result.sessions.map { ($0.id, $0) },
                uniquingKeysWith: { a, _ in a }
            )
            state.activityMap = result.activityMap

            // Merge reconciled links, but SKIP cards mid-launch (with 30s timeout)
            var mergedLinks = state.links
            for link in result.links {
                if let existing = mergedLinks[link.id], existing.isLaunching == true {
                    // Clear stale launch locks (app restart, crash, etc.)
                    if Date.now.timeIntervalSince(existing.updatedAt) > 30 {
                        var cleared = link
                        cleared.isLaunching = nil
                        mergedLinks[link.id] = cleared
                    }
                    // Otherwise preserve in-progress launch state
                    continue
                }
                mergedLinks[link.id] = link
            }

            // Recompute columns for non-launching cards
            let liveTmuxNames = result.tmuxSessions
            for (id, var link) in mergedLinks where link.isLaunching != true {
                let activity = result.activityMap[link.sessionLink?.sessionId ?? ""]
                let hasTmux = link.tmuxLink.map { tmux in
                    // Shell-only terminals don't count as "active work" for column assignment
                    guard tmux.isShellOnly != true else { return false }
                    return tmux.allSessionNames.contains(where: { liveTmuxNames.contains($0) })
                } ?? false
                let hasWorktree = link.worktreeLink?.branch != nil

                // Clear manual column override when we have definitive data
                if link.manualOverrides.column {
                    if activity != nil && activity != .stale {
                        link.manualOverrides.column = false
                    } else if link.tmuxLink != nil && !hasTmux {
                        link.tmuxLink = nil
                        link.manualOverrides.column = false
                    }
                }

                UpdateCardColumn.update(
                    link: &link,
                    activityState: activity,
                    hasWorktree: hasWorktree || hasTmux
                )

                // Copy session's firstPrompt into link.promptBody
                if link.promptBody == nil,
                   let sessionId = link.sessionLink?.sessionId,
                   let session = result.sessions.first(where: { $0.id == sessionId }),
                   let firstPrompt = session.firstPrompt, !firstPrompt.isEmpty {
                    link.promptBody = firstPrompt
                }

                mergedLinks[id] = link
            }

            state.links = mergedLinks
            state.lastRefresh = Date()
            state.isLoading = false

            // Validate selected card still exists
            if let selectedId = state.selectedCardId,
               !mergedLinks.keys.contains(selectedId) {
                state.selectedCardId = nil
            }

            return [.persistLinks(Array(mergedLinks.values))]

        case .gitHubIssuesUpdated(let updatedLinks):
            for link in updatedLinks {
                state.links[link.id] = link
            }
            state.lastGitHubRefresh = Date()
            return [.persistLinks(Array(state.links.values))]

        // MARK: Settings / Misc

        case .setError(let message):
            state.error = message
            return []

        case .setSelectedProject(let path):
            state.selectedProjectPath = path
            return []

        case .setLoading(let loading):
            state.isLoading = loading
            return []

        case .setIsRefreshingBacklog(let refreshing):
            state.isRefreshingBacklog = refreshing
            return []
        }
    }
}

// MARK: - BoardStore

/// The main store. Replaces BoardState as the single source of truth.
/// All mutations go through dispatch() → Reducer → Effects.
@Observable
@MainActor
public final class BoardStore: @unchecked Sendable {
    public private(set) var state: AppState
    private let effectHandler: EffectHandler
    private var _lastErrorId: UUID?

    // Dependencies for reconciliation
    private let discovery: SessionDiscovery
    private let coordinationStore: CoordinationStore
    private let activityDetector: ClaudeCodeActivityDetector?
    private let settingsStore: SettingsStore?
    private let ghAdapter: GhCliAdapter?
    private let worktreeAdapter: GitWorktreeAdapter?
    private let tmuxAdapter: TmuxManagerPort?

    public let sessionStore: SessionStore

    public init(
        effectHandler: EffectHandler,
        discovery: SessionDiscovery,
        coordinationStore: CoordinationStore,
        activityDetector: ClaudeCodeActivityDetector? = nil,
        settingsStore: SettingsStore? = nil,
        ghAdapter: GhCliAdapter? = nil,
        worktreeAdapter: GitWorktreeAdapter? = nil,
        tmuxAdapter: TmuxManagerPort? = nil,
        sessionStore: SessionStore = ClaudeCodeSessionStore()
    ) {
        self.state = AppState()
        self.effectHandler = effectHandler
        self.discovery = discovery
        self.coordinationStore = coordinationStore
        self.activityDetector = activityDetector
        self.settingsStore = settingsStore
        self.ghAdapter = ghAdapter
        self.worktreeAdapter = worktreeAdapter
        self.tmuxAdapter = tmuxAdapter
        self.sessionStore = sessionStore
    }

    /// Dispatch an action. Reducer runs synchronously, effects run async.
    public func dispatch(_ action: Action) {
        let effects = Reducer.reduce(state: &state, action: action)
        for effect in effects {
            Task { [weak self] in
                guard let self else { return }
                await self.effectHandler.execute(effect, dispatch: self.dispatch)
            }
        }

        // Auto-dismiss errors for certain actions
        switch action {
        case .setError(let msg) where msg != nil:
            let dismissId = UUID()
            _lastErrorId = dismissId
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                if self?._lastErrorId == dismissId {
                    self?.state.error = nil
                }
            }
        case .launchFailed, .resumeFailed, .terminalFailed:
            let dismissId = UUID()
            _lastErrorId = dismissId
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                if self?._lastErrorId == dismissId {
                    self?.state.error = nil
                }
            }
        default:
            break
        }
    }

    // MARK: - Reconciliation

    /// Full reconciliation: discover sessions, load links, merge, assign columns.
    /// Replaces BoardState.refresh(). The async work happens here; the state mutation
    /// happens atomically via dispatch(.reconciled(...)).
    public func reconcile() async {
        dispatch(.setLoading(true))

        do {
            // Load settings for project filtering
            var configuredProjects: [Project] = []
            var excludedPaths: [String] = []
            if let store = settingsStore {
                let settings = try await store.read()
                configuredProjects = settings.projects
                excludedPaths = settings.globalView.excludedPaths
            }

            // Show cached data immediately while discovery runs
            if state.links.isEmpty {
                let cached = try await coordinationStore.readLinks()
                if !cached.isEmpty {
                    for link in cached {
                        state.links[link.id] = link
                    }
                }
            }

            let sessions = try await discovery.discoverSessions()
            // Use in-memory state as source of truth — NOT disk.
            // Disk reads race with async effect writes, causing duplicates.
            let existingLinks = Array(state.links.values)

            // Deduplicate repo roots — multiple projects can share the same repo
            let uniqueRepoRoots = Set(configuredProjects.map(\.effectiveRepoRoot))

            // Scan worktrees once per unique repo
            var worktreesByRepo: [String: [Worktree]] = [:]
            if let worktreeAdapter {
                for repoRoot in uniqueRepoRoots {
                    if let worktrees = try? await worktreeAdapter.listWorktrees(repoRoot: repoRoot) {
                        worktreesByRepo[repoRoot] = worktrees
                    }
                }
            }

            // Fetch PRs once per unique repo
            var pullRequests: [String: PullRequest] = [:]
            if let ghAdapter {
                for repoRoot in uniqueRepoRoots {
                    if let prs = try? await ghAdapter.fetchPRs(repoRoot: repoRoot) {
                        pullRequests.merge(prs, uniquingKeysWith: { existing, _ in existing })
                    }
                }
            }

            // Scan tmux sessions
            let tmuxSessions = (try? await tmuxAdapter?.listSessions()) ?? []

            // Reconcile
            let snapshot = CardReconciler.DiscoverySnapshot(
                sessions: sessions,
                tmuxSessions: tmuxSessions,
                didScanTmux: tmuxAdapter != nil,
                worktrees: worktreesByRepo,
                pullRequests: pullRequests
            )
            var mergedLinks = CardReconciler.reconcile(existing: existingLinks, snapshot: snapshot)

            // Post-reconciliation: targeted PR discovery via batched GraphQL
            if let ghAdapter {
                let coveredBranches = Set(pullRequests.keys)
                let coveredPRNumbers = Set(pullRequests.values.map(\.number))

                var branchesByRepo: [String: [(index: Int, branch: String)]] = [:]
                var prNumbersByRepo: [String: [(index: Int, prIndex: Int, number: Int)]] = [:]

                for i in mergedLinks.indices {
                    let link = mergedLinks[i]
                    guard !link.manuallyArchived else { continue }
                    guard let repoRoot = link.projectPath, !repoRoot.isEmpty else { continue }

                    if let branch = link.worktreeLink?.branch, link.prLinks.isEmpty, !coveredBranches.contains(branch) {
                        branchesByRepo[repoRoot, default: []].append((index: i, branch: branch))
                    }
                    for j in link.prLinks.indices {
                        let prNumber = link.prLinks[j].number
                        if !coveredPRNumbers.contains(prNumber) {
                            prNumbersByRepo[repoRoot, default: []].append((index: i, prIndex: j, number: prNumber))
                        }
                    }
                }

                let allRepos = Set(branchesByRepo.keys).union(prNumbersByRepo.keys)
                for repoRoot in allRepos {
                    let branches = (branchesByRepo[repoRoot] ?? []).map(\.branch)
                    let numbers = (prNumbersByRepo[repoRoot] ?? []).map(\.number)
                    guard !branches.isEmpty || !numbers.isEmpty else { continue }

                    let (byBranch, byNumber) = (try? await ghAdapter.batchPRLookup(repoRoot: repoRoot, branches: branches, prNumbers: numbers)) ?? ([:], [:])

                    for entry in branchesByRepo[repoRoot] ?? [] {
                        if let pr = byBranch[entry.branch] {
                            mergedLinks[entry.index].prLinks.append(PRLink(number: pr.number, url: pr.url, status: pr.status, title: pr.title))
                        }
                    }
                    for entry in prNumbersByRepo[repoRoot] ?? [] {
                        if let pr = byNumber[entry.number] {
                            mergedLinks[entry.index].prLinks[entry.prIndex].status = pr.status
                            mergedLinks[entry.index].prLinks[entry.prIndex].title = pr.title
                            mergedLinks[entry.index].prLinks[entry.prIndex].url = pr.url
                        }
                    }
                }
            }

            // Build activity map
            var activityMap: [String: ActivityState] = [:]
            for link in mergedLinks {
                if let sessionId = link.sessionLink?.sessionId {
                    if let activity = await activityDetector?.activityState(for: sessionId) {
                        activityMap[sessionId] = activity
                    }
                }
            }

            // Compute discovered project paths
            let sessionPaths = mergedLinks.map { $0.projectPath }
            let discoveredProjectPaths = ProjectDiscovery.findUnconfiguredPaths(
                sessionPaths: sessionPaths,
                configuredProjects: configuredProjects
            )

            // Dispatch reconciled result — reducer handles all state mutations atomically
            let result = ReconciliationResult(
                links: mergedLinks,
                sessions: sessions,
                activityMap: activityMap,
                tmuxSessions: Set(tmuxSessions.map(\.name)),
                configuredProjects: configuredProjects,
                excludedPaths: excludedPaths,
                discoveredProjectPaths: discoveredProjectPaths
            )
            dispatch(.reconciled(result))

            // Fetch GitHub issues if enough time has elapsed
            await refreshGitHubIssuesIfNeeded()
        } catch {
            dispatch(.setError(error.localizedDescription))
            dispatch(.setLoading(false))
        }
    }

    // MARK: - GitHub Issues

    public func refreshBacklog() async {
        state.lastGitHubRefresh = nil
        dispatch(.setIsRefreshingBacklog(true))
        await refreshGitHubIssues()
        dispatch(.setIsRefreshingBacklog(false))
    }

    private func refreshGitHubIssuesIfNeeded() async {
        guard ghAdapter != nil else { return }
        let interval: TimeInterval
        if let store = settingsStore, let settings = try? await store.read() {
            interval = TimeInterval(settings.github.pollIntervalSeconds)
        } else {
            interval = 300
        }
        if let last = state.lastGitHubRefresh, Date.now.timeIntervalSince(last) < interval {
            return
        }
        await refreshGitHubIssues()
    }

    private func refreshGitHubIssues() async {
        guard let ghAdapter else { return }
        guard let settings = try? await settingsStore?.read() else { return }
        guard var links = try? await coordinationStore.readLinks() else { return }

        let defaultFilter = settings.github.defaultFilter
        var fetchedIssueKeys: Set<String> = []
        var changed = false

        for project in settings.projects {
            let filter = project.githubFilter ?? defaultFilter
            guard !filter.isEmpty else { continue }

            do {
                let issues = try await ghAdapter.fetchIssues(repoRoot: project.effectiveRepoRoot, filter: filter)
                for issue in issues {
                    let key = "\(project.path):\(issue.number)"
                    fetchedIssueKeys.insert(key)

                    let existing = links.first(where: {
                        $0.issueLink?.number == issue.number && $0.projectPath == project.path
                    })
                    if existing == nil {
                        let link = Link(
                            name: "#\(issue.number): \(issue.title)",
                            projectPath: project.path,
                            column: .backlog,
                            source: .githubIssue,
                            issueLink: IssueLink(number: issue.number, url: issue.url, body: issue.body, title: issue.title)
                        )
                        links.append(link)
                        changed = true
                    }
                }
            } catch {
                dispatch(.setError("GitHub: \(error.localizedDescription)"))
            }
        }

        // Remove stale GitHub issue links
        let before = links.count
        links.removeAll { link in
            guard link.source == .githubIssue,
                  link.column == .backlog,
                  let issueNum = link.issueLink?.number,
                  let projPath = link.projectPath else { return false }
            return !fetchedIssueKeys.contains("\(projPath):\(issueNum)")
        }
        if links.count != before { changed = true }

        if changed {
            dispatch(.gitHubIssuesUpdated(links: links))
        } else {
            state.lastGitHubRefresh = Date()
        }
    }
}
