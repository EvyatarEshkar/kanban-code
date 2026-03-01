import Foundation

// MARK: - Typed Link Sub-Structs

/// Link to a Claude Code session.
public struct SessionLink: Codable, Sendable, Equatable {
    public var sessionId: String
    public var sessionPath: String?
    public var sessionNumber: Int?

    public init(sessionId: String, sessionPath: String? = nil, sessionNumber: Int? = nil) {
        self.sessionId = sessionId
        self.sessionPath = sessionPath
        self.sessionNumber = sessionNumber
    }
}

/// Link to a tmux terminal session.
public struct TmuxLink: Codable, Sendable, Equatable {
    public var sessionName: String          // Primary Claude session
    public var extraSessions: [String]?     // User-created shell terminals

    /// All session names (primary + extras).
    public var allSessionNames: [String] {
        var result = [sessionName]
        if let extra = extraSessions { result.append(contentsOf: extra) }
        return result
    }

    /// Total count of terminals.
    public var terminalCount: Int { allSessionNames.count }

    public init(sessionName: String, extraSessions: [String]? = nil) {
        self.sessionName = sessionName
        self.extraSessions = extraSessions
    }
}

/// Link to a git worktree.
public struct WorktreeLink: Codable, Sendable, Equatable {
    public var path: String
    public var branch: String?

    public init(path: String, branch: String? = nil) {
        self.path = path
        self.branch = branch
    }
}

/// Link to a GitHub pull request.
public struct PRLink: Codable, Sendable, Equatable {
    public var number: Int
    public var url: String?
    public var status: PRStatus?
    public var unresolvedThreads: Int?
    public var title: String?
    public var body: String?
    public var approvalCount: Int?
    public var checkRuns: [CheckRun]?

    public init(
        number: Int,
        url: String? = nil,
        status: PRStatus? = nil,
        unresolvedThreads: Int? = nil,
        title: String? = nil,
        body: String? = nil,
        approvalCount: Int? = nil,
        checkRuns: [CheckRun]? = nil
    ) {
        self.number = number
        self.url = url
        self.status = status
        self.unresolvedThreads = unresolvedThreads
        self.title = title
        self.body = body
        self.approvalCount = approvalCount
        self.checkRuns = checkRuns
    }
}

/// Link to a GitHub issue.
public struct IssueLink: Codable, Sendable, Equatable {
    public var number: Int
    public var url: String?
    public var body: String?
    public var title: String?

    public init(number: Int, url: String? = nil, body: String? = nil, title: String? = nil) {
        self.number = number
        self.url = url
        self.body = body
        self.title = title
    }
}

// MARK: - Card Label

/// The primary label shown on a card, derived from which links are present.
public enum CardLabel: String, Sendable {
    case session = "SESSION"
    case worktree = "WORKTREE"
    case issue = "ISSUE"
    case pr = "PR"
    case task = "TASK"
}

// MARK: - Link (Card Entity)

/// The coordination record — a card on the board with independently optional typed links.
/// Stored in ~/.kanban/links.json.
public struct Link: Identifiable, Codable, Sendable {
    public let id: String

    // Card-level properties
    public var name: String?
    public var projectPath: String?
    public var column: KanbanColumn
    public var createdAt: Date
    public var updatedAt: Date
    public var lastActivity: Date?
    public var manualOverrides: ManualOverrides
    public var manuallyArchived: Bool
    public var source: LinkSource
    public var promptBody: String?

    // Typed links — each independently optional
    public var sessionLink: SessionLink?
    public var tmuxLink: TmuxLink?
    public var worktreeLink: WorktreeLink?
    public var prLinks: [PRLink]
    public var issueLink: IssueLink?

    /// Branches discovered by scanning the conversation for `git push` commands.
    /// nil = not yet scanned; empty = scanned but no branches found.
    public var discoveredBranches: [String]?

    /// Whether this card's project is configured for remote execution.
    public var isRemote: Bool

    // MARK: - Multi-PR computed properties

    /// Primary PR (first in array, or nil). Backward-compat shorthand.
    public var prLink: PRLink? { prLinks.first }
    /// Worst PR status across all PRs (highest urgency).
    public var worstPRStatus: PRStatus? { prLinks.compactMap(\.status).min() }
    /// True if ALL PRs are merged or closed.
    public var allPRsDone: Bool { !prLinks.isEmpty && prLinks.allSatisfy { $0.status == .merged || $0.status == .closed } }

    // MARK: - Backward-compat computed properties

    /// Claude session UUID. Use `sessionLink?.sessionId` for new code.
    public var sessionId: String? { sessionLink?.sessionId }
    /// Path to .jsonl transcript. Use `sessionLink?.sessionPath` for new code.
    public var sessionPath: String? { sessionLink?.sessionPath }
    /// Tmux session name. Use `tmuxLink?.sessionName` for new code.
    public var tmuxSession: String? { tmuxLink?.sessionName }
    /// Worktree directory path. Use `worktreeLink?.path` for new code.
    public var worktreePath: String? { worktreeLink?.path }
    /// Git branch name. Use `worktreeLink?.branch` for new code.
    public var worktreeBranch: String? { worktreeLink?.branch }
    /// GitHub issue number. Use `issueLink?.number` for new code.
    public var githubIssue: Int? { issueLink?.number }
    /// GitHub PR number. Use `prLinks.first?.number` for new code.
    public var githubPR: Int? { prLinks.first?.number }
    /// Session display number. Use `sessionLink?.sessionNumber` for new code.
    public var sessionNumber: Int? { sessionLink?.sessionNumber }
    /// Issue body or manual prompt. Use `issueLink?.body ?? promptBody` for new code.
    public var issueBody: String? { issueLink?.body ?? promptBody }

    /// The primary label for this card based on which links are present.
    public var cardLabel: CardLabel {
        if sessionLink != nil { return .session }
        if worktreeLink != nil { return .worktree }
        if issueLink != nil { return .issue }
        if !prLinks.isEmpty { return .pr }
        return .task
    }

    // MARK: - Init

    public init(
        id: String = KSUID.generate(prefix: "card"),
        name: String? = nil,
        projectPath: String? = nil,
        column: KanbanColumn = .allSessions,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        lastActivity: Date? = nil,
        manualOverrides: ManualOverrides = ManualOverrides(),
        manuallyArchived: Bool = false,
        source: LinkSource = .discovered,
        promptBody: String? = nil,
        sessionLink: SessionLink? = nil,
        tmuxLink: TmuxLink? = nil,
        worktreeLink: WorktreeLink? = nil,
        prLinks: [PRLink] = [],
        issueLink: IssueLink? = nil,
        isRemote: Bool = false,
        discoveredBranches: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.projectPath = projectPath
        self.column = column
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastActivity = lastActivity
        self.manualOverrides = manualOverrides
        self.manuallyArchived = manuallyArchived
        self.source = source
        self.promptBody = promptBody
        self.sessionLink = sessionLink
        self.tmuxLink = tmuxLink
        self.worktreeLink = worktreeLink
        self.prLinks = prLinks
        self.issueLink = issueLink
        self.isRemote = isRemote
        self.discoveredBranches = discoveredBranches
    }

    // MARK: - Backward-compatible Codable

    private enum CodingKeys: String, CodingKey {
        // Card-level
        case id, name, projectPath, column, createdAt, updatedAt, lastActivity
        case manualOverrides, manuallyArchived, source, promptBody, isRemote
        case discoveredBranches
        // Typed links (new nested format)
        case sessionLink, tmuxLink, worktreeLink, prLinks, issueLink
        // Old format keys (for reading legacy format)
        case prLink
        case sessionId, sessionPath, worktreePath, worktreeBranch
        case tmuxSession, githubIssue, githubPR, sessionNumber, issueBody
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        projectPath = try c.decodeIfPresent(String.self, forKey: .projectPath)
        column = try c.decodeIfPresent(KanbanColumn.self, forKey: .column) ?? .allSessions
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
        lastActivity = try c.decodeIfPresent(Date.self, forKey: .lastActivity)
        manualOverrides = try c.decodeIfPresent(ManualOverrides.self, forKey: .manualOverrides) ?? ManualOverrides()
        manuallyArchived = try c.decodeIfPresent(Bool.self, forKey: .manuallyArchived) ?? false
        source = try c.decodeIfPresent(LinkSource.self, forKey: .source) ?? .discovered
        promptBody = try c.decodeIfPresent(String.self, forKey: .promptBody)
        isRemote = try c.decodeIfPresent(Bool.self, forKey: .isRemote) ?? false
        discoveredBranches = try c.decodeIfPresent([String].self, forKey: .discoveredBranches)

        // Session link: try nested first, fallback to flat
        if let sl = try c.decodeIfPresent(SessionLink.self, forKey: .sessionLink) {
            sessionLink = sl
        } else {
            let sid = try c.decodeIfPresent(String.self, forKey: .sessionId)
            let sp = try c.decodeIfPresent(String.self, forKey: .sessionPath)
            let sn = try c.decodeIfPresent(Int.self, forKey: .sessionNumber)
            sessionLink = sid.map { SessionLink(sessionId: $0, sessionPath: sp, sessionNumber: sn) }
        }

        // Tmux link
        if let tl = try c.decodeIfPresent(TmuxLink.self, forKey: .tmuxLink) {
            tmuxLink = tl
        } else if let ts = try c.decodeIfPresent(String.self, forKey: .tmuxSession) {
            tmuxLink = TmuxLink(sessionName: ts)
        } else {
            tmuxLink = nil
        }

        // Worktree link
        if let wl = try c.decodeIfPresent(WorktreeLink.self, forKey: .worktreeLink) {
            worktreeLink = wl
        } else {
            let wp = try c.decodeIfPresent(String.self, forKey: .worktreePath)
            let wb = try c.decodeIfPresent(String.self, forKey: .worktreeBranch)
            if let wp {
                worktreeLink = WorktreeLink(path: wp, branch: wb)
            } else if let wb {
                worktreeLink = WorktreeLink(path: "", branch: wb)
            } else {
                worktreeLink = nil
            }
        }

        // PR links: try array first, fallback to singular prLink, fallback to legacy githubPR
        if let pls = try c.decodeIfPresent([PRLink].self, forKey: .prLinks) {
            prLinks = pls
        } else if let pl = try c.decodeIfPresent(PRLink.self, forKey: .prLink) {
            prLinks = [pl]
        } else if let pn = try c.decodeIfPresent(Int.self, forKey: .githubPR) {
            prLinks = [PRLink(number: pn)]
        } else {
            prLinks = []
        }

        // Issue link
        if let il = try c.decodeIfPresent(IssueLink.self, forKey: .issueLink) {
            issueLink = il
        } else if let issueNum = try c.decodeIfPresent(Int.self, forKey: .githubIssue) {
            let body = try c.decodeIfPresent(String.self, forKey: .issueBody)
            issueLink = IssueLink(number: issueNum, body: body)
        } else {
            issueLink = nil
            // Migrate issueBody to promptBody for manual tasks
            if promptBody == nil {
                promptBody = try c.decodeIfPresent(String.self, forKey: .issueBody)
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)

        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(projectPath, forKey: .projectPath)
        try c.encode(column, forKey: .column)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(lastActivity, forKey: .lastActivity)
        try c.encode(manualOverrides, forKey: .manualOverrides)
        try c.encode(manuallyArchived, forKey: .manuallyArchived)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(promptBody, forKey: .promptBody)
        try c.encode(isRemote, forKey: .isRemote)
        try c.encodeIfPresent(discoveredBranches, forKey: .discoveredBranches)

        // Always write new nested format
        try c.encodeIfPresent(sessionLink, forKey: .sessionLink)
        try c.encodeIfPresent(tmuxLink, forKey: .tmuxLink)
        try c.encodeIfPresent(worktreeLink, forKey: .worktreeLink)
        if !prLinks.isEmpty {
            try c.encode(prLinks, forKey: .prLinks)
        }
        try c.encodeIfPresent(issueLink, forKey: .issueLink)
    }
}

/// Tracks which fields have been manually set by the user.
public struct ManualOverrides: Codable, Sendable {
    public var worktreePath: Bool
    public var tmuxSession: Bool
    public var name: Bool
    public var column: Bool
    public var prLink: Bool
    public var issueLink: Bool

    public init(
        worktreePath: Bool = false,
        tmuxSession: Bool = false,
        name: Bool = false,
        column: Bool = false,
        prLink: Bool = false,
        issueLink: Bool = false
    ) {
        self.worktreePath = worktreePath
        self.tmuxSession = tmuxSession
        self.name = name
        self.column = column
        self.prLink = prLink
        self.issueLink = issueLink
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        worktreePath = try c.decodeIfPresent(Bool.self, forKey: .worktreePath) ?? false
        tmuxSession = try c.decodeIfPresent(Bool.self, forKey: .tmuxSession) ?? false
        name = try c.decodeIfPresent(Bool.self, forKey: .name) ?? false
        column = try c.decodeIfPresent(Bool.self, forKey: .column) ?? false
        prLink = try c.decodeIfPresent(Bool.self, forKey: .prLink) ?? false
        issueLink = try c.decodeIfPresent(Bool.self, forKey: .issueLink) ?? false
    }
}

/// How a link was created.
public enum LinkSource: String, Codable, Sendable {
    case discovered // Found via session scanning
    case hook // Created via Claude hook event
    case githubIssue = "github_issue" // Created from a GitHub issue
    case manual // User-created task
}

/// A single content block within a conversation turn.
public struct ContentBlock: Sendable {
    public enum Kind: Sendable, Equatable {
        case text
        case toolUse(name: String, input: [String: String])
        case toolResult(toolName: String?)
        case thinking
    }

    public let kind: Kind
    public let text: String // rendered text for display

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// A conversation turn for history display and checkpoint operations.
public struct ConversationTurn: Sendable {
    public let index: Int
    public let lineNumber: Int
    public let role: String // "user" or "assistant"
    public let textPreview: String
    public let timestamp: String?
    public let contentBlocks: [ContentBlock]

    public init(index: Int, lineNumber: Int, role: String, textPreview: String, timestamp: String? = nil, contentBlocks: [ContentBlock] = []) {
        self.index = index
        self.lineNumber = lineNumber
        self.role = role
        self.textPreview = textPreview
        self.timestamp = timestamp
        self.contentBlocks = contentBlocks
    }
}
