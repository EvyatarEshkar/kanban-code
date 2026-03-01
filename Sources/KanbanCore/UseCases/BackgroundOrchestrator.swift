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

    private var pollingTask: Task<Void, Never>?

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

    /// Start the background polling loop.
    public func start() {
        guard !isRunning else { return }
        isRunning = true

        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
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
            let scanned = (try? await JsonlParser.extractPushedBranches(from: sessionPath)) ?? []
            links[idx].discoveredBranches = scanned

            // Re-fetch PRs to match newly discovered branches
            if let prTracker, let projectPath = links[idx].projectPath {
                var allPRs: [String: PullRequest] = [:]
                if var prs = try? await prTracker.fetchPRs(repoRoot: projectPath) {
                    try? await prTracker.enrichPRDetails(repoRoot: projectPath, prs: &prs)
                    allPRs = prs
                }

                let branches = [links[idx].worktreeLink?.branch].compactMap { $0 } + scanned
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

            links[idx].updatedAt = .now
            try await coordinationStore.writeLinks(links)
        } catch {
            // Best-effort
        }
    }

    /// Stop the background polling loop.
    public func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        isRunning = false
    }

    /// Single tick of the orchestration loop.
    public func tick() async {
        // 1. Process hook events
        await processHookEvents()

        // 2. Resolve pending stops (may trigger notifications)
        let resolvedStops = await activityDetector.resolvePendingStops()
        for sessionId in resolvedStops {
            await handleStopResolved(sessionId: sessionId)
        }

        // 3. Update activity states for all links
        await updateActivityStates()

        // 4. Update card columns
        await updateColumns()
    }

    // MARK: - Private

    private func processHookEvents() async {
        do {
            let events = try await hookEventStore.readNewEvents()
            for event in events {
                await activityDetector.handleHookEvent(event)

                // Update dedup tracker
                switch event.eventName {
                case "Stop":
                    let _ = await notificationDedup.recordStop(sessionId: event.sessionId)
                case "Notification":
                    // Notification hook fires when Claude needs user attention
                    // (permission request, question, etc.) — also send push
                    let _ = await notificationDedup.recordStop(sessionId: event.sessionId)
                case "UserPromptSubmit":
                    await notificationDedup.recordPrompt(sessionId: event.sessionId)
                default:
                    break
                }
            }
        } catch {
            // Silently continue — hook events are best-effort
        }
    }

    private func handleStopResolved(sessionId: String) async {
        let shouldNotify = await notificationDedup.shouldNotify(sessionId: sessionId)
        guard shouldNotify, let notifier else { return }

        // Get session info for notification
        let link = try? await coordinationStore.linkForSession(sessionId)
        let sessionNum = await notificationDedup.sessionNumber(for: sessionId)
        let sessionName = link?.name ?? "Session #\(sessionNum)"
        let title = "Claude #\(sessionNum): \(sessionName)"

        // Try to get last assistant response for rich notification
        var message = "Waiting for input"
        var imageData: Data?

        if let transcriptPath = link?.sessionLink?.sessionPath {
            if let lastText = await TranscriptNotificationReader.lastAssistantText(transcriptPath: transcriptPath) {
                let lineCount = lastText.components(separatedBy: "\n").count
                if lineCount > 1 {
                    // Multi-line: render as image
                    imageData = await MarkdownImageRenderer.renderToImage(markdown: lastText)
                    message = imageData != nil ? "Task completed" : String(lastText.prefix(500))
                } else {
                    // Single-line: send as plain text
                    message = String(lastText.prefix(500))
                }
            }
        }

        try? await notifier.sendNotification(
            title: title,
            message: message,
            imageData: imageData
        )
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
            var links = try await coordinationStore.readLinks()
            var changed = false

            // Get PR data if tracker available
            var allPRs: [String: PullRequest] = [:]
            if let prTracker {
                // Group links by project for batch PR fetching
                let projects = Set(links.compactMap(\.projectPath))
                for project in projects {
                    if var prs = try? await prTracker.fetchPRs(repoRoot: project) {
                        try? await prTracker.enrichPRDetails(repoRoot: project, prs: &prs)
                        allPRs.merge(prs) { a, _ in a }
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

                // Sync PR enrichment data to prLinks (multi-branch)
                let branches = [links[i].worktreeLink?.branch].compactMap { $0 }
                    + (links[i].discoveredBranches ?? [])
                let matchedPRs = branches.compactMap { allPRs[$0] }
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
                    changed = true
                }

                // Conversation branch scan for recent sessions without discoveredBranches
                if links[i].discoveredBranches == nil,
                   let path = links[i].sessionLink?.sessionPath {
                    let activity = links[i].lastActivity ?? links[i].updatedAt
                    let isRecent = activity.timeIntervalSinceNow > -86400 // 24h
                    if isRecent {
                        let scanned = (try? await JsonlParser.extractPushedBranches(from: path)) ?? []
                        links[i].discoveredBranches = scanned
                        if !scanned.isEmpty {
                            // Re-match PRs with newly discovered branches
                            for branch in scanned {
                                if let pr = allPRs[branch],
                                   !links[i].prLinks.contains(where: { $0.number == pr.number }) {
                                    links[i].prLinks.append(PRLink(
                                        number: pr.number, url: pr.url,
                                        status: pr.status, title: pr.title
                                    ))
                                }
                            }
                        }
                        changed = true
                    }
                }

                // Clear manual column override when we have definitive activity data
                // (hooks fired, or tmux session gone). Manual override is only for user drags.
                if links[i].manualOverrides.column {
                    if activityState != .stale {
                        // Hooks provided real data — let auto-assignment take over
                        links[i].manualOverrides.column = false
                    } else if links[i].tmuxLink != nil && !hasTmux {
                        // Had a tmux session but it's gone now
                        links[i].tmuxLink = nil
                        links[i].manualOverrides.column = false
                    }
                }

                let oldColumn = links[i].column

                UpdateCardColumn.update(
                    link: &links[i],
                    activityState: activityState,
                    hasWorktree: hasWorktree || hasTmux
                )

                if links[i].column != oldColumn {
                    changed = true
                }
            }

            if changed {
                try await coordinationStore.writeLinks(links)
            }
        } catch {
            // Continue on error
        }
    }
}
