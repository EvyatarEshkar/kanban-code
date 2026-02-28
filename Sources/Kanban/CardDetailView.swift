import SwiftUI
import KanbanCore

struct CardDetailView: View {
    let card: KanbanCard
    var onResume: () -> Void = {}
    var onRename: (String) -> Void = { _ in }
    var onFork: () -> Void = {}
    var onDismiss: () -> Void = {}

    @State private var turns: [ConversationTurn] = []
    @State private var isLoadingHistory = false
    @State private var selectedTab: Int
    @State private var showRenameSheet = false
    @State private var renameText = ""

    // Checkpoint mode
    @State private var checkpointMode = false
    @State private var checkpointTurn: ConversationTurn?
    @State private var showCheckpointConfirm = false

    // Fork
    @State private var showForkConfirm = false
    @State private var forkResult: String?

    // File watcher for real-time history
    @State private var historyWatcherFD: Int32 = -1
    @State private var historyWatcherSource: DispatchSourceFileSystemObject?
    @State private var lastReloadTime: Date = .distantPast

    private let sessionStore = ClaudeCodeSessionStore()

    init(card: KanbanCard, onResume: @escaping () -> Void = {}, onRename: @escaping (String) -> Void = { _ in }, onFork: @escaping () -> Void = {}, onDismiss: @escaping () -> Void = {}) {
        self.card = card
        self.onResume = onResume
        self.onRename = onRename
        self.onFork = onFork
        self.onDismiss = onDismiss
        _selectedTab = State(initialValue: card.link.tmuxLink == nil ? 1 : 0)
        // Tab 0 = Terminal, Tab 1 = History (Actions tab removed — buttons in header now)
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
                        Button(action: onResume) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 13))
                                .frame(width: 36, height: 36)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular, in: .capsule)
                        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                        .help("Resume session")

                        actionsMenu
                            .frame(width: 36, height: 36)
                            .glassEffect(.regular, in: .capsule)
                            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                            .help("More actions")
                    }
                }

                // Link pills
                HStack(spacing: 6) {
                    CardLabelBadge(label: card.link.cardLabel)

                    if let sessionNum = card.link.sessionLink?.sessionNumber {
                        linkPill(icon: "terminal", text: "#\(sessionNum)", color: .blue)
                    }
                    if let tmux = card.link.tmuxLink?.sessionName {
                        linkPill(icon: "terminal.fill", text: tmux, color: .green)
                    }
                    if let branch = card.link.worktreeLink?.branch {
                        linkPill(icon: "arrow.triangle.branch", text: branch, color: .teal)
                    }
                    if let pr = card.link.prLink?.number {
                        linkPill(icon: "arrow.triangle.pull", text: "#\(pr)", color: .purple)
                    }
                    if let issue = card.link.issueLink?.number {
                        linkPill(icon: "exclamationmark.circle", text: "#\(issue)", color: .orange)
                    }

                    Spacer()

                    Text(card.relativeTime)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                if let projectPath = card.link.projectPath {
                    copyableRow(icon: "folder", text: projectPath)
                }

                if let sessionId = card.link.sessionLink?.sessionId {
                    copyableRow(icon: "number", text: sessionId)
                }
            }
            .padding(16)

            Divider()

            // Tab bar
            Picker("Tab", selection: $selectedTab) {
                Text("Terminal").tag(0)
                Text("History").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            // Content
            switch selectedTab {
            case 0:
                terminalView
            case 1:
                SessionHistoryView(
                    turns: turns,
                    isLoading: isLoadingHistory,
                    checkpointMode: checkpointMode,
                    onCancelCheckpoint: { checkpointMode = false },
                    onSelectTurn: { turn in
                        checkpointTurn = turn
                        showCheckpointConfirm = true
                    }
                )
            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: card.id) {
            turns = []
            isLoadingHistory = false
            checkpointMode = false
            await loadHistory()
        }
        .onChange(of: selectedTab) {
            if selectedTab == 1 {
                startHistoryWatcher()
            } else {
                stopHistoryWatcher()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .kanbanHistoryChanged)) { _ in
            guard selectedTab == 1 else { return }
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
    }

    @ViewBuilder
    private var terminalView: some View {
        if let tmuxSession = card.link.tmuxLink?.sessionName {
            TerminalRepresentable.tmuxAttach(sessionName: tmuxSession)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                selectedTab = 1
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

            if let pr = card.link.prLink?.number {
                Divider()
                Button(action: {}) {
                    Label("Open PR #\(pr)", systemImage: "arrow.up.right.square")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    // MARK: - History loading

    private func loadHistory() async {
        guard let path = card.link.sessionLink?.sessionPath ?? card.session?.jsonlPath else { return }
        if turns.isEmpty { isLoadingHistory = true }
        do {
            turns = try await TranscriptReader.readTurns(from: path)
        } catch {
            // Silently fail — empty history is fine
        }
        isLoadingHistory = false
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
    }

    /// Must be nonisolated so GCD closures don't inherit @MainActor isolation (causes crash).
    private nonisolated static func makeHistorySource(fd: Int32) -> DispatchSourceFileSystemObject {
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: .global(qos: .userInitiated)
        )
        source.setEventHandler {
            NotificationCenter.default.post(name: .kanbanHistoryChanged, object: nil)
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

    private func linkPill(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.caption2)
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.12), in: Capsule())
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
