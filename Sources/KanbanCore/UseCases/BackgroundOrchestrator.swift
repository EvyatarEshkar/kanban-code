import Foundation

/// Coordinates all background processes: session discovery, tmux polling,
/// hook event processing, activity detection, PR tracking, and link management.
@Observable
public final class BackgroundOrchestrator: @unchecked Sendable {
    public var isRunning = false

    private let discovery: SessionDiscovery
    private let coordinationStore: CoordinationStore
    private let activityDetector: ClaudeCodeActivityDetector
    private let hookEventStore: HookEventStore
    private let tmux: TmuxManagerPort?
    private let prTracker: PRTrackerPort?
    private let notificationDedup: NotificationDeduplicator
    private var notifier: NotifierPort?

    private var backgroundTask: Task<Void, Never>?
    private var didInitialLoad = false

    public init(
        discovery: SessionDiscovery,
        coordinationStore: CoordinationStore,
        activityDetector: ClaudeCodeActivityDetector = .init(),
        hookEventStore: HookEventStore = .init(),
        tmux: TmuxManagerPort? = nil,
        prTracker: PRTrackerPort? = nil,
        notificationDedup: NotificationDeduplicator = .init(),
        notifier: NotifierPort? = nil
    ) {
        self.discovery = discovery
        self.coordinationStore = coordinationStore
        self.activityDetector = activityDetector
        self.hookEventStore = hookEventStore
        self.tmux = tmux
        self.prTracker = prTracker
        self.notificationDedup = notificationDedup
        self.notifier = notifier
    }

    /// Start the slow background loop (columns, PRs, activity polling).
    /// Notifications are handled event-driven via processHookEvents().
    public func start() {
        guard !isRunning else { return }
        isRunning = true

        backgroundTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.backgroundTick()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Update the notifier (e.g. when settings change).
    public func updateNotifier(_ newNotifier: NotifierPort?) {
        self.notifier = newNotifier
    }

    /// Force re-scan a card's conversation for pushed branches and re-fetch PRs.
    /// Used by the UI "Discover" button to manually trigger discovery for older cards.
    public func discoverBranchesForCard(cardId: String) async {
        do {
            var links = try await coordinationStore.readLinks()
            guard let idx = links.firstIndex(where: { $0.id == cardId }),
                  let sessionPath = links[idx].sessionLink?.sessionPath else { return }

            // Force rescan by clearing cached value
            links[idx].discoveredBranches = nil
            links[idx].discoveredRepos = nil
            let scanned = (try? await JsonlParser.extractPushedBranches(from: sessionPath)) ?? []
            links[idx].discoveredBranches = scanned.map(\.branch)
            // Store repo paths for branches that differ from projectPath
            var repos: [String: String] = [:]
            for db in scanned {
                if let repo = db.repoPath, repo != links[idx].projectPath {
                    repos[db.branch] = repo
                }
            }
            links[idx].discoveredRepos = repos.isEmpty ? nil : repos

            // Re-fetch PRs — group branches by repo for batch fetching
            if let prTracker {
                let projectPath = links[idx].projectPath
                // Collect all branches with their effective repo paths
                var branchesByRepo: [String: [String]] = [:]
                if let branch = links[idx].worktreeLink?.branch, let pp = projectPath {
                    branchesByRepo[pp, default: []].append(branch)
                }
                for db in scanned {
                    let repo = db.repoPath ?? projectPath ?? ""
                    guard !repo.isEmpty else { continue }
                    branchesByRepo[repo, default: []].append(db.branch)
                }

                // Fetch PRs from each repo
                for (repo, branches) in branchesByRepo {
                    var allPRs: [String: PullRequest] = [:]
                    if var prs = try? await prTracker.fetchPRs(repoRoot: repo) {
                        try? await prTracker.enrichPRDetails(repoRoot: repo, prs: &prs)
                        allPRs = prs
                    }
                    for branch in branches {
                        if let pr = allPRs[branch],
                           !links[idx].prLinks.contains(where: { $0.number == pr.number }) {
                            links[idx].prLinks.append(PRLink(
                                number: pr.number, url: pr.url,
                                status: pr.status, title: pr.title,
                                approvalCount: pr.approvalCount > 0 ? pr.approvalCount : nil,
                                checkRuns: pr.checkRuns.isEmpty ? nil : pr.checkRuns
                            ))
                        }
                    }
                }
            }

            // Run column assignment after discovery
            var activityState: ActivityState?
            if let sessionId = links[idx].sessionLink?.sessionId {
                activityState = await activityDetector.activityState(for: sessionId)
            }
            let hasWorktree = links[idx].worktreeLink?.branch != nil
            UpdateCardColumn.update(link: &links[idx], activityState: activityState, hasWorktree: hasWorktree)

            links[idx].updatedAt = .now
            try await coordinationStore.writeLinks(links)
        } catch {
            // Best-effort
        }
    }

    /// Stop the background loop.
    public func stop() {
        backgroundTask?.cancel()
        backgroundTask = nil
        isRunning = false
    }

    // MARK: - Event-driven notification path (called from file watcher)

    /// Process new hook events and send notifications. Called directly by file watcher
    /// for instant response — mirrors claude-pushover's hook-driven approach.
    public func processHookEvents() async {
        do {
            let events = try await hookEventStore.readNewEvents()

            if !didInitialLoad {
                // First call: consume all old events without notifying.
                KanbanLog.info("notify", "Initial load: consuming \(events.count) old events")
                for event in events {
                    await activityDetector.handleHookEvent(event)
                }
                let _ = await activityDetector.resolvePendingStops()
                await notificationDedup.clearAllPending()
                didInitialLoad = true
                return
            }

            if !events.isEmpty {
                KanbanLog.info("notify", "Processing \(events.count) hook events")
            }

            for event in events {
                await activityDetector.handleHookEvent(event)

                // Notification logic — mirrors claude-pushover, adapted for batch processing.
                // Uses EVENT TIMESTAMPS (not wall-clock) so batch-processed events
                // behave identically to claude-pushover's one-event-per-process model.
                switch event.eventName {
                case "Stop":
                    // claude-pushover: sleep 1s, check if user prompted, send if not.
                    // NO 62s dedup — Stop always sends (dedup only applies to Notification events).
                    KanbanLog.info("notify", "Stop event for session \(event.sessionId.prefix(8)) at \(event.timestamp)")
                    let stopTime = event.timestamp
                    let sessionId = event.sessionId
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(1))
                        guard let self else {
                            KanbanLog.info("notify", "Stop handler: self deallocated")
                            return
                        }
                        // Check if user sent a prompt within 1s after this Stop
                        let prompted = await notificationDedup.hasPromptedWithin(
                            sessionId: sessionId, after: stopTime
                        )
                        if prompted {
                            KanbanLog.info("notify", "Stop skipped: user prompted within 1s after stop")
                            return
                        }
                        // Send directly — no dedup for Stop events (matches claude-pushover)
                        await self.doNotify(sessionId: sessionId)
                    }

                case "Notification":
                    // claude-pushover: send if not within 62s dedup window
                    KanbanLog.info("notify", "Notification event for session \(event.sessionId.prefix(8)) at \(event.timestamp)")
                    let sessionId = event.sessionId
                    let eventTime = event.timestamp
                    Task { [weak self] in
                        // Notification events go through 62s dedup
                        let shouldNotify = await self?.notificationDedup.shouldNotify(
                            sessionId: sessionId, eventTime: eventTime
                        ) ?? false
                        guard shouldNotify else {
                            KanbanLog.info("notify", "Notification deduped for \(sessionId.prefix(8))")
                            return
                        }
                        await self?.doNotify(sessionId: sessionId)
                    }

                case "UserPromptSubmit":
                    KanbanLog.info("notify", "UserPromptSubmit for session \(event.sessionId.prefix(8)) at \(event.timestamp)")
                    await notificationDedup.recordPrompt(sessionId: event.sessionId, at: event.timestamp)

                default:
                    break
                }
            }
        } catch {
            KanbanLog.info("notify", "processHookEvents error: \(error)")
        }
    }

    // MARK: - Private

    /// Send notification — no dedup check, just format and send.
    /// Mirrors claude-pushover's do_notify() exactly.
    private func doNotify(sessionId: String) async {
        guard let notifier else {
            KanbanLog.info("notify", "Notification skipped: notifier is nil")
            return
        }

        let link = try? await coordinationStore.linkForSession(sessionId)
        let title = link?.displayTitle ?? "Session done"

        // Mirrors claude-pushover's do_notify() exactly:
        // 1. Get last assistant response
        // 2. If multi-line: render image + use text preview
        // 3. If single line: use as-is
        // 4. No response: "Waiting for input"
        var message = "Waiting for input"
        var imageData: Data?

        if let transcriptPath = link?.sessionLink?.sessionPath {
            if let lastText = await TranscriptNotificationReader.lastAssistantText(transcriptPath: transcriptPath) {
                let lineCount = lastText.components(separatedBy: "\n").count
                if lineCount > 1 {
                    imageData = await MarkdownImageRenderer.renderToImage(markdown: lastText)
                    message = TranscriptNotificationReader.textPreview(lastText)
                } else {
                    message = lastText
                }
            }
        }

        KanbanLog.info("notify", "Sending notification: title=\(title), message=\(message.prefix(60))..., hasImage=\(imageData != nil)")
        try? await notifier.sendNotification(
            title: title,
            message: message,
            imageData: imageData,
            cardId: link?.id
        )
    }

    /// Slow background tick: activity states + column updates + PRs.
    private func backgroundTick() async {
        await updateActivityStates()
        await updateColumns()
    }

    private func updateActivityStates() async {
        do {
            let links = try await coordinationStore.readLinks()
            let sessionPaths = Dictionary(
                links.compactMap { link -> (String, String)? in
                    guard let sessionId = link.sessionLink?.sessionId,
                          let path = link.sessionLink?.sessionPath else { return nil }
                    return (sessionId, path)
                },
                uniquingKeysWith: { a, _ in a }
            )

            // Poll activity for sessions without hook events
            let _  = await activityDetector.pollActivity(sessionPaths: sessionPaths)
        } catch {
            // Continue on error
        }
    }

    private func updateColumns() async {
        do {
            // Read a snapshot of links for computing changes.
            // We process this snapshot asynchronously, then apply changes atomically
            // via modifyLinks() to avoid overwriting concurrent additions.
            var links = try await coordinationStore.readLinks()
            var changedIds: Set<String> = []

            // Get PR data if tracker available — keyed by "repo:branch" for multi-repo
            var prsByRepoBranch: [String: PullRequest] = [:]
            if let prTracker {
                // Collect all repo paths: projectPaths + discoveredRepos values
                var allRepos = Set(links.compactMap(\.projectPath))
                for link in links {
                    if let repos = link.discoveredRepos {
                        for repo in repos.values { allRepos.insert(repo) }
                    }
                }
                for repo in allRepos {
                    if var prs = try? await prTracker.fetchPRs(repoRoot: repo) {
                        try? await prTracker.enrichPRDetails(repoRoot: repo, prs: &prs)
                        for (branch, pr) in prs {
                            prsByRepoBranch["\(repo):\(branch)"] = pr
                        }
                    }
                }
            }

            // Get tmux sessions
            let tmuxSessions = (try? await tmux?.listSessions()) ?? []
            let tmuxNames = Set(tmuxSessions.map(\.name))

            for i in links.indices {
                guard let sessionId = links[i].sessionLink?.sessionId else { continue }
                let activityState = await activityDetector.activityState(for: sessionId)
                let hasWorktree = links[i].worktreeLink?.branch != nil
                let hasTmux = links[i].tmuxLink.map { tmux in
                    tmux.allSessionNames.contains(where: { tmuxNames.contains($0) })
                } ?? false

                // Sync PR enrichment data to prLinks (multi-branch, multi-repo)
                let projectPath = links[i].projectPath ?? ""
                let discoveredRepos = links[i].discoveredRepos ?? [:]
                var branchRepoPairs: [(String, String)] = [] // (branch, repoPath)
                if let branch = links[i].worktreeLink?.branch {
                    branchRepoPairs.append((branch, projectPath))
                }
                for branch in links[i].discoveredBranches ?? [] {
                    let repo = discoveredRepos[branch] ?? projectPath
                    branchRepoPairs.append((branch, repo))
                }
                let matchedPRs = branchRepoPairs.compactMap { prsByRepoBranch["\($0.1):\($0.0)"] }
                for pr in matchedPRs {
                    if let idx = links[i].prLinks.firstIndex(where: { $0.number == pr.number }) {
                        // Update existing
                        links[i].prLinks[idx].url = pr.url
                        links[i].prLinks[idx].status = pr.status
                        links[i].prLinks[idx].title = pr.title
                        links[i].prLinks[idx].unresolvedThreads = pr.unresolvedThreads > 0 ? pr.unresolvedThreads : nil
                        links[i].prLinks[idx].approvalCount = pr.approvalCount > 0 ? pr.approvalCount : nil
                        links[i].prLinks[idx].checkRuns = pr.checkRuns.isEmpty ? nil : pr.checkRuns
                    } else {
                        // Add new
                        links[i].prLinks.append(PRLink(
                            number: pr.number,
                            url: pr.url,
                            status: pr.status,
                            title: pr.title,
                            approvalCount: pr.approvalCount > 0 ? pr.approvalCount : nil,
                            checkRuns: pr.checkRuns.isEmpty ? nil : pr.checkRuns
                        ))
                    }
                    // body is NOT synced here — lazy-loaded on demand via fetchPRBody
                    changedIds.insert(links[i].id)
                }

                // Conversation branch scan for recent sessions without discoveredBranches
                if links[i].discoveredBranches == nil,
                   let path = links[i].sessionLink?.sessionPath {
                    let activity = links[i].lastActivity ?? links[i].updatedAt
                    let isRecent = activity.timeIntervalSinceNow > -86400 // 24h
                    if isRecent {
                        let scanned = (try? await JsonlParser.extractPushedBranches(from: path)) ?? []
                        links[i].discoveredBranches = scanned.map(\.branch)
                        // Store repo paths for branches in different repos
                        var repos: [String: String] = [:]
                        for db in scanned {
                            if let repo = db.repoPath, repo != links[i].projectPath {
                                repos[db.branch] = repo
                            }
                        }
                        links[i].discoveredRepos = repos.isEmpty ? nil : repos
                        if !scanned.isEmpty {
                            // Re-match PRs with newly discovered branches
                            for db in scanned {
                                let repo = db.repoPath ?? projectPath
                                let key = "\(repo):\(db.branch)"
                                if let pr = prsByRepoBranch[key],
                                   !links[i].prLinks.contains(where: { $0.number == pr.number }) {
                                    links[i].prLinks.append(PRLink(
                                        number: pr.number, url: pr.url,
                                        status: pr.status, title: pr.title
                                    ))
                                }
                            }
                        }
                        changedIds.insert(links[i].id)
                    }
                }

                // Clear manual column override when we have definitive activity data
                // (hooks fired, or tmux session gone). Manual override is only for user drags.
                if links[i].manualOverrides.column {
                    if activityState != .stale {
                        // Hooks provided real data — let auto-assignment take over
                        links[i].manualOverrides.column = false
                        changedIds.insert(links[i].id)
                    } else if links[i].tmuxLink != nil && !hasTmux {
                        // Had a tmux session but it's gone now
                        links[i].tmuxLink = nil
                        links[i].manualOverrides.column = false
                        changedIds.insert(links[i].id)
                    }
                }

                let oldColumn = links[i].column

                UpdateCardColumn.update(
                    link: &links[i],
                    activityState: activityState,
                    hasWorktree: hasWorktree || hasTmux
                )

                if links[i].column != oldColumn {
                    changedIds.insert(links[i].id)
                }
            }

            // Apply changes atomically — re-reads fresh data so we don't overwrite
            // concurrent additions (e.g. manual tasks created between our read and write)
            if !changedIds.isEmpty {
                let updatedById = Dictionary(
                    links.filter { changedIds.contains($0.id) }.map { ($0.id, $0) },
                    uniquingKeysWith: { a, _ in a }
                )
                try await coordinationStore.modifyLinks { freshLinks in
                    for i in freshLinks.indices {
                        if let updated = updatedById[freshLinks[i].id] {
                            freshLinks[i] = updated
                        }
                    }
                }
            }
        } catch {
            // Continue on error
        }
    }
}
