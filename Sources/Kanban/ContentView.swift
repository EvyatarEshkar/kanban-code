import SwiftUI
import KanbanCore

struct ContentView: View {
    @State private var boardState: BoardState
    @State private var orchestrator: BackgroundOrchestrator
    @State private var showSearch = false
    @State private var showNewTask = false
    @State private var hooksInstalled = true // assume true until checked
    @State private var hookSetupError: String?
    private let coordinationStore: CoordinationStore
    private let systemTray = SystemTray()
    private let hookEventsPath: String

    private var showInspector: Binding<Bool> {
        Binding(
            get: { boardState.selectedCardId != nil },
            set: { if !$0 { boardState.selectedCardId = nil } }
        )
    }

    init() {
        let discovery = ClaudeCodeSessionDiscovery()
        let coordination = CoordinationStore()
        let activityDetector = ClaudeCodeActivityDetector()
        let state = BoardState(
            discovery: discovery,
            coordinationStore: coordination,
            activityDetector: activityDetector
        )

        // Load Pushover config if available
        let notifier: PushoverClient? = Self.loadPushoverConfig()

        let orch = BackgroundOrchestrator(
            discovery: discovery,
            coordinationStore: coordination,
            activityDetector: activityDetector,
            tmux: TmuxAdapter(),
            notifier: notifier
        )

        _boardState = State(initialValue: state)
        _orchestrator = State(initialValue: orch)
        self.coordinationStore = coordination
        self.hookEventsPath = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".kanban/hook-events.jsonl")
    }

    private static func loadPushoverConfig() -> PushoverClient? {
        let configPath = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".config/claude-pushover/config")
        guard let contents = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return nil
        }

        var token: String?
        var user: String?
        for line in contents.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || trimmed.isEmpty { continue }
            if trimmed.hasPrefix("PUSHOVER_TOKEN=") {
                token = trimmed.replacingOccurrences(of: "PUSHOVER_TOKEN=", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            } else if trimmed.hasPrefix("PUSHOVER_USER=") {
                user = trimmed.replacingOccurrences(of: "PUSHOVER_USER=", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }

        guard let t = token, let u = user, !t.isEmpty, !u.isEmpty else { return nil }
        return PushoverClient(token: t, userKey: u)
    }

    var body: some View {
        NavigationStack {
        BoardView(state: boardState)
            // Hook onboarding banner
            .overlay(alignment: .top) {
                if !hooksInstalled {
                    hookOnboardingBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: hooksInstalled)
            .extendedBackground()
            .navigationTitle("")
            .inspector(isPresented: showInspector) {
                if let card = boardState.cards.first(where: { $0.id == boardState.selectedCardId }) {
                    CardDetailView(
                        card: card,
                        onRename: { name in
                            boardState.renameCard(cardId: card.id, name: name)
                        },
                        onFork: {},
                        onDismiss: { boardState.selectedCardId = nil }
                    )
                    .inspectorColumnWidth(min: 600, ideal: 800, max: 1000)
                }
            }
            .overlay {
                if showSearch {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .onTapGesture { showSearch = false }

                    SearchOverlay(
                        isPresented: $showSearch,
                        cards: boardState.cards,
                        onSelectCard: { card in
                            boardState.selectedCardId = card.id
                        }
                    )
                    .padding(40)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            .animation(.easeInOut(duration: 0.15), value: showSearch)
            .sheet(isPresented: $showNewTask) {
                NewTaskDialog(isPresented: $showNewTask) { title, description, projectPath in
                    createManualTask(title: title, description: description, projectPath: projectPath)
                }
            }
            .task {
                hooksInstalled = HookManager.isInstalled()
                systemTray.setup(boardState: boardState)
                await boardState.refresh()
                systemTray.update()
                orchestrator.start()
            }
            .task(id: "hook-watcher") {
                // Watch hook-events.jsonl for changes → instant refresh
                await watchHookEvents()
            }
            .task(id: "refresh-timer") {
                // Fallback periodic refresh for non-hook changes (new sessions, file mtime)
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled else { break }
                    await boardState.refresh()
                    systemTray.update()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .kanbanToggleSearch)) { _ in
                showSearch.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .kanbanNewTask)) { _ in
                showNewTask = true
            }
            .toolbar {
                // Left: actions pill
                ToolbarItemGroup(placement: .navigation) {
                    Button { showNewTask = true } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .help("New task (⌘N)")

                    Button { Task { await boardState.refresh() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(boardState.isLoading)
                    .help("Refresh sessions")
                }

                // Center-left: title pill
                ToolbarItem(placement: .principal) {
                    Text("Kanban")
                        .font(.headline)
                        .padding(.horizontal, 6)
                }

                // Flexible spacer separates title and search into two pills
                ToolbarSpacer(.flexible, placement: .principal)

                // Center-right: search pill
                ToolbarItem(placement: .principal) {
                    Button { showSearch.toggle() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                            Text("Search")
                            Text("⌘K")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                        }
                        .padding(.horizontal, 4)
                    }
                    .help("Search sessions (⌘K)")
                }

                // Right: sidebar pill
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if boardState.selectedCardId != nil {
                            boardState.selectedCardId = nil
                        }
                    } label: {
                        Image(systemName: "sidebar.right")
                    }
                    .disabled(boardState.selectedCardId == nil)
                    .opacity(boardState.selectedCardId != nil ? 1.0 : 0.3)
                    .help("Toggle session details")
                }
            }
            .background {
                Button("") { showSearch.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
                    .hidden()
            }
        } // NavigationStack
    }

    private var hookOnboardingBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.orange)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text("Set up Claude Code hooks")
                    .font(.callout)
                    .fontWeight(.medium)
                Text("Kanban needs hooks to detect when Claude is actively working, stops, or needs attention.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = hookSetupError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Spacer()

            Button("Set up for me") {
                do {
                    try HookManager.install()
                    hooksInstalled = true
                    hookSetupError = nil
                } catch {
                    hookSetupError = error.localizedDescription
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button(action: { hooksInstalled = true }) {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Dismiss — Kanban will use file polling as fallback")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// Watch ~/.kanban/hook-events.jsonl for writes → trigger immediate orchestrator tick + board refresh.
    private func watchHookEvents() async {
        // Ensure the directory exists
        let dir = (hookEventsPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Ensure the file exists
        if !FileManager.default.fileExists(atPath: hookEventsPath) {
            FileManager.default.createFile(atPath: hookEventsPath, contents: nil)
        }

        guard let fd = open(hookEventsPath, O_EVTONLY) as Int32?,
              fd >= 0 else { return }
        defer { close(fd) }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: .global(qos: .userInitiated)
        )

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            source.setEventHandler {
                Task { @MainActor in
                    // Process new hook events through orchestrator, then refresh board
                    await self.orchestrator.tick()
                    await self.boardState.refresh()
                    self.systemTray.update()
                }
            }
            source.setCancelHandler {
                continuation.resume()
            }
            source.resume()

            // Keep alive until task is cancelled
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                }
                source.cancel()
            }
        }
    }

    private func createManualTask(title: String, description: String, projectPath: String?) {
        let link = Link(
            sessionId: UUID().uuidString,
            projectPath: projectPath,
            column: .backlog,
            name: title,
            source: .manual
        )
        Task {
            try? await coordinationStore.upsertLink(link)
            await boardState.refresh()
        }
    }
}
