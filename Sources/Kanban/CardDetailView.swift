import SwiftUI
import KanbanCore
import MarkdownUI

private enum DetailTab: String {
    case terminal, history, issue, pullRequest, prompt
}

struct CardDetailView: View {
    let card: KanbanCard
    var onResume: () -> Void = {}
    var onRename: (String) -> Void = { _ in }
    var onFork: () -> Void = {}
    var onDismiss: () -> Void = {}
    var onUnlink: (BoardState.LinkType) -> Void = { _ in }
    var onAddBranch: (String) -> Void = { _ in }
    var onAddIssue: (Int) -> Void = { _ in }
    var onCleanupWorktree: () -> Void = {}
    var onDeleteCard: () -> Void = {}
    var onCreateTerminal: () -> Void = {}
    var onKillTerminal: (String) -> Void = { _ in }
    var onDiscover: () -> Void = {}

    @State private var turns: [ConversationTurn] = []
    @State private var isLoadingHistory = false
    @State private var hasMoreTurns = false
    @State private var isLoadingMore = false
    @State private var selectedTab: DetailTab
    @State private var showRenameSheet = false
    @State private var renameText = ""

    // Checkpoint mode
    @State private var checkpointMode = false
    @State private var checkpointTurn: ConversationTurn?
    @State private var showCheckpointConfirm = false

    // Fork
    @State private var showForkConfirm = false
    @State private var forkResult: String?

    // Add link popover
    @State private var showAddLink = false

    // Resolved GitHub base URL for constructing issue/PR links
    @State private var githubBaseURL: String?

    // Lazy PR body loading
    @State private var prBody: String?
    @State private var isLoadingPRBody = false

    // Delete confirmation
    @State private var showDeleteConfirm = false
    @State private var deleteConfirmText = ""

    // File watcher for real-time history
    @State private var historyWatcherFD: Int32 = -1
    @State private var historyWatcherSource: DispatchSourceFileSystemObject?
    @State private var historyPollTask: Task<Void, Never>?
    @State private var lastReloadTime: Date = .distantPast

    // Multi-terminal
    @State private var selectedTerminalSession: String?

    let sessionStore: SessionStore

    init(card: KanbanCard, sessionStore: SessionStore = ClaudeCodeSessionStore(), onResume: @escaping () -> Void = {}, onRename: @escaping (String) -> Void = { _ in }, onFork: @escaping () -> Void = {}, onDismiss: @escaping () -> Void = {}, onUnlink: @escaping (BoardState.LinkType) -> Void = { _ in }, onAddBranch: @escaping (String) -> Void = { _ in }, onAddIssue: @escaping (Int) -> Void = { _ in }, onCleanupWorktree: @escaping () -> Void = {}, onDeleteCard: @escaping () -> Void = {}, onCreateTerminal: @escaping () -> Void = {}, onKillTerminal: @escaping (String) -> Void = { _ in }, onDiscover: @escaping () -> Void = {}) {
        self.card = card
        self.sessionStore = sessionStore
        self.onResume = onResume
        self.onRename = onRename
        self.onFork = onFork
        self.onDismiss = onDismiss
        self.onUnlink = onUnlink
        self.onAddBranch = onAddBranch
        self.onAddIssue = onAddIssue
        self.onCleanupWorktree = onCleanupWorktree
        self.onDeleteCard = onDeleteCard
        self.onCreateTerminal = onCreateTerminal
        self.onKillTerminal = onKillTerminal
        self.onDiscover = onDiscover
        _selectedTab = State(initialValue: Self.initialTab(for: card))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Text(card.displayTitle)
                        .font(.headline)
                        .textCase(nil)
                        .lineLimit(2)

                    Spacer()

                    // Action pills
                    HStack(spacing: 8) {
                        if card.column == .backlog {
                            Button(action: onResume) {
                                Label("Start", systemImage: "play.fill")
                                    .font(.system(size: 13))
                                    .padding(.horizontal, 12)
                                    .frame(height: 36)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular, in: .capsule)
                            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                            .help("Start work on this task")
                        } else {
                            Button(action: onResume) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 13))
                                    .frame(width: 36, height: 36)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular, in: .capsule)
                            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                            .help("Resume session")
                        }

                        actionsMenu
                            .frame(width: 36, height: 36)
                            .glassEffect(.regular, in: .capsule)
                            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                            .help("More actions")
                    }
                }

                // Badge + timestamp row
                HStack(spacing: 6) {
                    CardLabelBadge(label: card.link.cardLabel)
                    Spacer()
                    Text(card.relativeTime)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                // Property rows — one per link type
                VStack(alignment: .leading, spacing: 2) {
                    if let branch = card.link.worktreeLink?.branch, !branch.isEmpty {
                        linkPropertyRow(
                            icon: "arrow.triangle.branch", label: "Branch", value: branch,
                            onUnlink: { onUnlink(.worktree) }
                        )
                    }
                    if let worktreePath = card.link.worktreeLink?.path, !worktreePath.isEmpty {
                        copyableRow(icon: "folder", text: worktreePath)
                    }
                    ForEach(card.link.prLinks, id: \.number) { pr in
                        let detail = pr.status.map { " · \($0.rawValue)" } ?? ""
                        let prURL = pr.url ?? githubBaseURL.map { GitRemoteResolver.prURL(base: $0, number: pr.number) }
                        linkPropertyRow(
                            icon: "arrow.triangle.pull", label: "PR", value: "#\(pr.number)\(detail)",
                            url: prURL,
                            onUnlink: { onUnlink(.pr) }
                        )
                    }
                    if let issue = card.link.issueLink {
                        let issueURL = issue.url ?? githubBaseURL.map { GitRemoteResolver.issueURL(base: $0, number: issue.number) }
                        linkPropertyRow(
                            icon: "circle.circle", label: "Issue", value: "#\(issue.number)",
                            url: issueURL,
                            onUnlink: { onUnlink(.issue) }
                        )
                    }
                    if let projectPath = card.link.projectPath {
                        copyableRow(icon: "folder.badge.gearshape", text: projectPath)
                    }
                    if let sessionId = card.link.sessionLink?.sessionId {
                        copyableRow(icon: "number", text: sessionId)
                    }

                    // Add link button
                    Button {
                        showAddLink = true
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "plus")
                                .font(.caption2)
                            Text("Add link")
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showAddLink) {
                        AddLinkPopover(
                            onAddBranch: { branch in
                                onAddBranch(branch)
                                showAddLink = false
                            },
                            onAddIssue: { number in
                                onAddIssue(number)
                                showAddLink = false
                            }
                        )
                    }
                }
            }
            .padding(16)

            Divider()

            // Tab bar — only show tabs relevant to this card
            Picker("Tab", selection: $selectedTab) {
                if card.link.tmuxLink != nil {
                    Text("Terminal").tag(DetailTab.terminal)
                }
                Text("History").tag(DetailTab.history)
                if card.link.issueLink != nil {
                    Text("Issue").tag(DetailTab.issue)
                }
                if !card.link.prLinks.isEmpty {
                    Text("Pull Request").tag(DetailTab.pullRequest)
                }
                if card.link.promptBody != nil && card.link.issueLink == nil {
                    Text("Prompt").tag(DetailTab.prompt)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            // Content
            switch selectedTab {
            case .terminal:
                terminalView
            case .history:
                SessionHistoryView(
                    turns: turns,
                    isLoading: isLoadingHistory,
                    checkpointMode: checkpointMode,
                    hasMoreTurns: hasMoreTurns,
                    isLoadingMore: isLoadingMore,
                    onCancelCheckpoint: { checkpointMode = false },
                    onSelectTurn: { turn in
                        checkpointTurn = turn
                        showCheckpointConfirm = true
                    },
                    onLoadMore: { Task { await loadMoreHistory() } }
                )
            case .issue:
                issueTabView
            case .pullRequest:
                prTabView
            case .prompt:
                promptTabView
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: card.id) {
            turns = []
            isLoadingHistory = false
            isLoadingMore = false
            hasMoreTurns = false
            checkpointMode = false
            prBody = nil
            isLoadingPRBody = false
            selectedTerminalSession = nil
            // Reset tab to a valid one for this card
            selectedTab = defaultTab(for: card)
            // Resolve GitHub base URL for constructing issue/PR links
            if let projectPath = card.link.projectPath {
                githubBaseURL = await GitRemoteResolver.shared.githubBaseURL(for: projectPath)
            } else {
                githubBaseURL = nil
            }
            await loadHistory()
            if selectedTab == .history {
                startHistoryWatcher()
            }
        }
        .onChange(of: selectedTab) {
            if selectedTab == .history {
                startHistoryWatcher()
            } else {
                stopHistoryWatcher()
            }
            if selectedTab == .pullRequest && prBody == nil && !isLoadingPRBody {
                Task { await loadPRBody() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .kanbanHistoryChanged)) { _ in
            guard selectedTab == .history else { return }
            // Debounce: only reload if >0.5s since last reload
            let now = Date()
            guard now.timeIntervalSince(lastReloadTime) > 0.5 else { return }
            lastReloadTime = now
            Task { await loadHistory() }
        }
        .onDisappear {
            stopHistoryWatcher()
        }
        .sheet(isPresented: $showRenameSheet) {
            RenameSessionDialog(
                currentName: card.link.name ?? card.displayTitle,
                isPresented: $showRenameSheet,
                onRename: onRename
            )
        }
        .alert("Fork Session?", isPresented: $showForkConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Fork") { performFork() }
        } message: {
            Text("This creates a duplicate session you can resume independently.")
        }
        .alert("Restore to Turn \(checkpointTurn.map { String($0.index + 1) } ?? "")?", isPresented: $showCheckpointConfirm) {
            Button("Cancel", role: .cancel) {
                checkpointTurn = nil
            }
            Button("Restore") { performCheckpoint() }
        } message: {
            Text("Everything after this point will be removed. A .bkp backup will be created.")
        }
        .alert("Delete Task", isPresented: $showDeleteConfirm) {
            TextField("Type \"delete\" to confirm", text: $deleteConfirmText)
            Button("Cancel", role: .cancel) {
                deleteConfirmText = ""
            }
            Button("Delete", role: .destructive) {
                if deleteConfirmText.lowercased() == "delete" {
                    onDeleteCard()
                    onDismiss()
                }
                deleteConfirmText = ""
            }
            .disabled(deleteConfirmText.lowercased() != "delete")
        } message: {
            Text("This will permanently delete this task. Type \"delete\" to confirm.")
        }
    }

    @ViewBuilder
    private var terminalView: some View {
        if let tmux = card.link.tmuxLink {
            let allSessions = tmux.allSessionNames
            let currentSession = selectedTerminalSession ?? tmux.sessionName

            VStack(spacing: 0) {
                // Terminal picker bar (only show if multiple terminals or to offer "+")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(allSessions, id: \.self) { sessionName in
                            let isPrimary = sessionName == tmux.sessionName
                            let isSelected = sessionName == currentSession

                            Button {
                                selectedTerminalSession = sessionName
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: isPrimary ? "brain" : "terminal")
                                        .font(.caption2)
                                    Text(isPrimary ? "Claude" : sessionName.replacingOccurrences(
                                        of: "\(tmux.sessionName)-", with: ""
                                    ))
                                    .font(.caption)
                                    .lineLimit(1)

                                    if !isPrimary {
                                        Button {
                                            onKillTerminal(sessionName)
                                            if selectedTerminalSession == sessionName {
                                                selectedTerminalSession = tmux.sessionName
                                            }
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 8, weight: .bold))
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    isSelected ? Color.accentColor.opacity(0.15) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                            }
                            .buttonStyle(.plain)
                        }

                        Button(action: onCreateTerminal) {
                            Image(systemName: "plus")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .help("Open new terminal")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }

                Divider()

                TerminalRepresentable.tmuxAttach(sessionName: currentSession)
                    .id(currentSession)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onChange(of: card.link.tmuxLink) {
                // Validate selection when terminals are added/killed
                if let selected = selectedTerminalSession,
                   let tmux = card.link.tmuxLink,
                   !tmux.allSessionNames.contains(selected) {
                    selectedTerminalSession = tmux.sessionName
                }
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "terminal")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("No tmux session attached")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Button(action: onResume) {
                    Label("Launch Terminal", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private static func initialTab(for card: KanbanCard) -> DetailTab {
        if card.link.tmuxLink != nil { return .terminal }
        if card.link.sessionLink != nil { return .history }
        if card.link.issueLink != nil { return .issue }
        if !card.link.prLinks.isEmpty { return .pullRequest }
        if card.link.promptBody != nil { return .prompt }
        return .history
    }

    private func defaultTab(for card: KanbanCard) -> DetailTab {
        Self.initialTab(for: card)
    }

    // MARK: - Issue Tab

    @ViewBuilder
    private var issueTabView: some View {
        if let issue = card.link.issueLink {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Header: title + number + open button
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.title ?? card.displayTitle)
                                .font(.headline)
                                .textSelection(.enabled)
                            Text("#\(issue.number)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let url = resolvedIssueURL(issue) {
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                Label("Open in Browser", systemImage: "arrow.up.right.square")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    Divider()

                    // Markdown body
                    if let body = issue.body, !body.isEmpty {
                        Markdown(body)
                            .markdownTheme(.compact)
                            .textSelection(.enabled)
                    } else {
                        Text("No description provided.")
                            .foregroundStyle(.tertiary)
                            .italic()
                    }
                }
                .padding(16)
            }
        }
    }

    // MARK: - Pull Request Tab

    @ViewBuilder
    private var prTabView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(card.link.prLinks.enumerated()), id: \.element.number) { index, pr in
                    if index > 0 { Divider().padding(.vertical, 4) }

                    // Header: title + number + badge + open button
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pr.title ?? "Pull Request")
                                .font(.headline)
                                .textSelection(.enabled)
                            HStack(spacing: 6) {
                                Text("#\(pr.number)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                if let status = pr.status {
                                    PRBadge(status: status, prNumber: pr.number)
                                }
                            }
                        }
                        Spacer()
                        if let url = resolvedPRURL(pr) {
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                Label("Open in Browser", systemImage: "arrow.up.right.square")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    // CI Check Runs
                    if let checks = pr.checkRuns, !checks.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Checks")
                                .font(.subheadline.bold())
                                .foregroundStyle(.secondary)
                            ForEach(checks, id: \.name) { check in
                                HStack(spacing: 6) {
                                    checkRunIcon(check)
                                    Text(check.name)
                                        .font(.caption)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }

                    // Reviews summary
                    if pr.approvalCount != nil || pr.unresolvedThreads != nil {
                        HStack(spacing: 16) {
                            if let approvals = pr.approvalCount, approvals > 0 {
                                Label("\(approvals) approval\(approvals == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                            if let unresolved = pr.unresolvedThreads, unresolved > 0 {
                                Label("\(unresolved) unresolved", systemImage: "bubble.left.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }

                Divider()

                // PR Body (lazy loaded — shows primary PR body)
                if isLoadingPRBody {
                    HStack {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading PR description...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                } else if let body = prBody ?? card.link.prLink?.body, !body.isEmpty {
                    Markdown(body)
                        .markdownTheme(.compact)
                        .textSelection(.enabled)
                } else {
                    Text("No description provided.")
                        .foregroundStyle(.tertiary)
                        .italic()
                }
            }
            .padding(16)
        }
    }

    // MARK: - Prompt Tab

    @ViewBuilder
    private var promptTabView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Prompt")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)

                if let body = card.link.promptBody {
                    Markdown(body)
                        .markdownTheme(.compact)
                        .textSelection(.enabled)
                }
            }
            .padding(16)
        }
    }

    // MARK: - PR helpers

    private func checkRunIcon(_ check: CheckRun) -> some View {
        Group {
            switch check.status {
            case .completed:
                switch check.conclusion {
                case .success:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failure:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                case .neutral, .skipped:
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.secondary)
                case .cancelled, .timedOut, .actionRequired:
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                case nil:
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
            case .inProgress:
                Image(systemName: "clock.fill")
                    .foregroundStyle(.yellow)
            case .queued:
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    private func resolvedIssueURL(_ issue: IssueLink) -> URL? {
        let urlString = issue.url ?? githubBaseURL.map { GitRemoteResolver.issueURL(base: $0, number: issue.number) }
        return urlString.flatMap { URL(string: $0) }
    }

    private func resolvedPRURL(_ pr: PRLink) -> URL? {
        let urlString = pr.url ?? githubBaseURL.map { GitRemoteResolver.prURL(base: $0, number: pr.number) }
        return urlString.flatMap { URL(string: $0) }
    }

    private func loadPRBody() async {
        guard let pr = card.link.prLink,
              let projectPath = card.link.projectPath else { return }
        isLoadingPRBody = true
        do {
            let body = try await GhCliAdapter().fetchPRBody(repoRoot: projectPath, prNumber: pr.number)
            prBody = body
        } catch {
            // Silently fail — body is optional
        }
        isLoadingPRBody = false
    }

    private var actionsMenu: some View {
        Menu {
            Button(action: { showRenameSheet = true }) {
                Label("Rename", systemImage: "pencil")
            }

            Button(action: { showForkConfirm = true }) {
                Label("Fork Session", systemImage: "arrow.branch")
            }
            .disabled(card.link.sessionLink?.sessionPath == nil)

            Button {
                checkpointMode = true
                selectedTab = .history
            } label: {
                Label("Checkpoint / Restore", systemImage: "clock.arrow.circlepath")
            }
            .disabled(card.link.sessionLink?.sessionPath == nil || turns.isEmpty)

            Divider()

            Button(action: copyResumeCommand) {
                Label("Copy Resume Command", systemImage: "doc.on.doc")
            }

            if let sessionId = card.link.sessionLink?.sessionId {
                Button(action: { copyToClipboard(sessionId) }) {
                    Label("Copy Session ID", systemImage: "number")
                }
            }

            if let tmux = card.link.tmuxLink?.sessionName {
                Button(action: { copyToClipboard("tmux attach -t \(tmux)") }) {
                    Label("Copy Tmux Command", systemImage: "terminal")
                }
            }

            if !card.link.prLinks.isEmpty {
                Divider()
                ForEach(card.link.prLinks, id: \.number) { pr in
                    Button {
                        if let url = pr.url.flatMap({ URL(string: $0) }) {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("Open PR #\(pr.number)", systemImage: "arrow.up.right.square")
                    }
                }
            }
            if card.link.sessionLink != nil {
                Divider()
                Button(action: onDiscover) {
                    Label("Discover PRs", systemImage: "arrow.triangle.pull")
                }
            }
            if let issue = card.link.issueLink {
                Button {
                    if let url = issue.url.flatMap({ URL(string: $0) }) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Open Issue #\(issue.number)", systemImage: "arrow.up.right.square")
                }
            }

            if card.link.worktreeLink != nil {
                Divider()
                Button(role: .destructive, action: onCleanupWorktree) {
                    Label("Remove Worktree", systemImage: "trash")
                }
            }

            Divider()
            Button(role: .destructive, action: { showDeleteConfirm = true }) {
                Label("Delete Card", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    // MARK: - History loading

    private static let pageSize = 80

    private func loadHistory() async {
        guard let path = card.link.sessionLink?.sessionPath ?? card.session?.jsonlPath else { return }
        if turns.isEmpty { isLoadingHistory = true }
        do {
            let result = try await TranscriptReader.readTail(from: path, maxTurns: Self.pageSize)
            turns = result.turns
            hasMoreTurns = result.hasMore
        } catch {
            // Silently fail — empty history is fine
        }
        isLoadingHistory = false
    }

    private func loadMoreHistory() async {
        guard hasMoreTurns, !isLoadingMore else { return }
        guard let path = card.link.sessionLink?.sessionPath ?? card.session?.jsonlPath else { return }
        guard let firstTurn = turns.first else { return }

        isLoadingMore = true
        let rangeStart = max(0, firstTurn.index - Self.pageSize)
        let rangeEnd = firstTurn.index

        do {
            let earlier = try await TranscriptReader.readRange(from: path, turnRange: rangeStart..<rangeEnd)
            turns = earlier + turns
            hasMoreTurns = rangeStart > 0
        } catch {
            // Silently fail
        }
        isLoadingMore = false
    }

    // MARK: - File watcher

    private func startHistoryWatcher() {
        stopHistoryWatcher()
        guard let path = card.link.sessionLink?.sessionPath ?? card.session?.jsonlPath else { return }

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        historyWatcherFD = fd

        let source = Self.makeHistorySource(fd: fd)
        historyWatcherSource = source

        // Periodic poll as fallback (every 3s) in case DispatchSource misses events
        historyPollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, selectedTab == .history else { break }
                await loadHistory()
            }
        }
    }

    /// Must be nonisolated so GCD closures don't inherit @MainActor isolation (causes crash).
    private nonisolated static func makeHistorySource(fd: Int32) -> DispatchSourceFileSystemObject {
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib],
            queue: .global(qos: .userInitiated)
        )
        source.setEventHandler {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .kanbanHistoryChanged, object: nil)
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        return source
    }

    private func stopHistoryWatcher() {
        historyWatcherSource?.cancel()
        historyWatcherSource = nil
        historyWatcherFD = -1
        historyPollTask?.cancel()
        historyPollTask = nil
    }

    // MARK: - Fork

    private func performFork() {
        guard let path = card.link.sessionLink?.sessionPath else { return }
        Task {
            do {
                let newId = try await sessionStore.forkSession(sessionPath: path)
                forkResult = newId
                onFork()
            } catch {
                // Could show error toast
            }
        }
    }

    // MARK: - Checkpoint

    private func performCheckpoint() {
        guard let path = card.link.sessionLink?.sessionPath,
              let turn = checkpointTurn else { return }
        Task {
            do {
                try await sessionStore.truncateSession(sessionPath: path, afterTurn: turn)
                checkpointMode = false
                checkpointTurn = nil
                await loadHistory()
            } catch {
                // Could show error toast
            }
        }
    }

    private func copyResumeCommand() {
        var cmd = ""
        if let projectPath = card.link.projectPath {
            cmd += "cd \(projectPath) && "
        }
        if let sessionId = card.link.sessionLink?.sessionId {
            cmd += "claude --resume \(sessionId)"
        } else {
            cmd += "# no session yet"
        }
        copyToClipboard(cmd)
    }

    /// Property row: icon + "Label: value", all secondary color, with optional link and × buttons.
    private func linkPropertyRow(
        icon: String, label: String, value: String,
        color: Color = .secondary,
        url: String? = nil,
        onUnlink: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 4) {
            Label {
                Text("\(label): \(value)")
            } icon: {
                Image(systemName: icon)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)

            if let url, let parsed = URL(string: url) {
                Button {
                    NSWorkspace.shared.open(parsed)
                } label: {
                    Image(systemName: "link")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Open in browser")
            }

            if let onUnlink {
                Button {
                    onUnlink()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("Remove link")
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func copyableRow(icon: String, text: String) -> some View {
        CopyableRow(icon: icon, text: text)
    }
}

private struct CopyableRow: View {
    let icon: String
    let text: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 4) {
            Label(text, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 12)
            }
            .buttonStyle(.borderless)
            .help("Copy to clipboard")
        }
    }
}

// MARK: - Compact Markdown Theme

@MainActor
extension Theme {
    /// Smaller text, tighter spacing, no opaque background on code blocks.
    static let compact = Theme()
        .text { FontSize(.em(0.87)) }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.82))
        }
        .heading1 { configuration in
            configuration.label
                .markdownTextStyle { FontSize(.em(1.25)); FontWeight(.semibold) }
                .markdownMargin(top: 12, bottom: 4)
        }
        .heading2 { configuration in
            configuration.label
                .markdownTextStyle { FontSize(.em(1.12)); FontWeight(.semibold) }
                .markdownMargin(top: 10, bottom: 4)
        }
        .heading3 { configuration in
            configuration.label
                .markdownTextStyle { FontSize(.em(1.0)); FontWeight(.semibold) }
                .markdownMargin(top: 8, bottom: 2)
        }
        .paragraph { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.15))
                .markdownMargin(top: 0, bottom: 8)
        }
        .codeBlock { configuration in
            configuration.label
                .markdownTextStyle {
                    FontFamilyVariant(.monospaced)
                    FontSize(.em(0.8))
                }
                .padding(8)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .markdownMargin(top: 4, bottom: 8)
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: 2, bottom: 2)
        }
}

/// Native rename dialog sheet.
struct RenameSessionDialog: View {
    let currentName: String
    @Binding var isPresented: Bool
    var onRename: (String) -> Void = { _ in }

    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Session")
                .font(.title3)
                .fontWeight(.semibold)

            TextField("Session name", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Rename") {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        onRename(trimmed)
                    }
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 350)
        .onAppear {
            name = currentName
        }
    }
}
