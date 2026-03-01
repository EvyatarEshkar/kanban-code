import SwiftUI
import AppKit
import KanbanCore

struct ContentView: View {
    @State private var boardState: BoardState
    @State private var orchestrator: BackgroundOrchestrator
    @State private var showSearch = false
    @State private var showNewTask = false
    @State private var showOnboarding = false
    @AppStorage("appearanceMode") private var appearanceMode: AppearanceMode = .auto
    @State private var showAddFromPath = false
    @State private var addFromPathText = ""
    @State private var showLaunchConfirmation = false
    @State private var launchCardId: String?
    @State private var launchPrompt: String = ""
    @State private var launchProjectPath: String = ""
    @State private var launchWorktreeName: String?
    @State private var launchHasExistingWorktree = false
    @State private var launchIsGitRepo = false
    @State private var launchHasRemoteConfig = false
    @State private var launchRemoteHost: String?
    @State private var syncStatuses: [String: SyncStatus] = [:]
    @State private var isSyncRefreshing = false
    @AppStorage("selectedProject") private var selectedProjectPersisted: String = ""
    private let coordinationStore: CoordinationStore
    private let settingsStore: SettingsStore
    private let launcher: LaunchSession
    private let systemTray = SystemTray()
    private let mutagenAdapter = MutagenAdapter()
    private let hookEventsPath: String
    private let settingsFilePath: String

    private var showInspector: Binding<Bool> {
        Binding(
            get: { boardState.selectedCardId != nil },
            set: { if !$0 { boardState.selectedCardId = nil } }
        )
    }

    init() {
        let discovery = ClaudeCodeSessionDiscovery()
        let coordination = CoordinationStore()
        let settings = SettingsStore()
        let activityDetector = ClaudeCodeActivityDetector()
        let state = BoardState(
            discovery: discovery,
            coordinationStore: coordination,
            activityDetector: activityDetector,
            settingsStore: settings,
            ghAdapter: GhCliAdapter()
        )

        // Load Pushover from settings.json, wrap in CompositeNotifier with macOS fallback
        let pushover = Self.loadPushoverConfig()
        let notifier = CompositeNotifier(primary: pushover, fallback: MacOSNotificationClient())

        let orch = BackgroundOrchestrator(
            discovery: discovery,
            coordinationStore: coordination,
            activityDetector: activityDetector,
            tmux: TmuxAdapter(),
            prTracker: GhCliAdapter(),
            notifier: notifier
        )

        let launch = LaunchSession(tmux: TmuxAdapter())

        _boardState = State(initialValue: state)
        _orchestrator = State(initialValue: orch)
        self.coordinationStore = coordination
        self.settingsStore = settings
        self.launcher = launch
        self.hookEventsPath = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".kanban/hook-events.jsonl")
        self.settingsFilePath = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".kanban/settings.json")
    }

    private static func loadPushoverConfig() -> PushoverClient? {
        let settingsPath = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".kanban/settings.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
              let settings = try? JSONDecoder().decode(Settings.self, from: data) else {
            return nil
        }

        guard let token = settings.notifications.pushoverToken,
              let user = settings.notifications.pushoverUserKey,
              !token.isEmpty, !user.isEmpty else {
            return nil
        }
        return PushoverClient(token: token, userKey: user)
    }

    var body: some View {
        NavigationStack {
        BoardView(
            state: boardState,
            onStartCard: { cardId in startCard(cardId: cardId) },
            onResumeCard: { cardId in resumeCard(cardId: cardId) },
            onForkCard: { cardId in
                // Select card and show detail view for fork action
                boardState.selectedCardId = cardId
            },
            onCopyResumeCmd: { cardId in
                guard let card = boardState.cards.first(where: { $0.id == cardId }) else { return }
                var cmd = ""
                if let projectPath = card.link.projectPath {
                    cmd += "cd \(projectPath) && "
                }
                if let sessionId = card.link.sessionLink?.sessionId {
                    cmd += "claude --resume \(sessionId)"
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cmd, forType: .string)
            },
            onRefreshBacklog: { Task { await boardState.refreshBacklog() } },
            onNewTask: { showNewTask = true }
        )
            .ignoresSafeArea(edges: .top)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .navigationTitle("")
            .inspector(isPresented: showInspector) {
                if let card = boardState.cards.first(where: { $0.id == boardState.selectedCardId }) {
                    CardDetailView(
                        card: card,
                        sessionStore: boardState.sessionStore,
                        onResume: { resumeCard(cardId: card.id) },
                        onRename: { name in
                            boardState.renameCard(cardId: card.id, name: name)
                        },
                        onFork: {},
                        onDismiss: { boardState.selectedCardId = nil },
                        onUnlink: { linkType in
                            boardState.unlinkFromCard(cardId: card.id, linkType: linkType)
                        },
                        onAddBranch: { branch in
                            boardState.addBranchToCard(cardId: card.id, branch: branch)
                        },
                        onAddIssue: { number in
                            boardState.addIssueLinkToCard(cardId: card.id, issueNumber: number)
                        },
                        onCleanupWorktree: {
                            Task { await cleanupWorktree(cardId: card.id) }
                        },
                        onDeleteCard: {
                            deleteCardWithCleanup(cardId: card.id)
                        },
                        onCreateTerminal: {
                            createExtraTerminal(cardId: card.id)
                        },
                        onKillTerminal: { sessionName in
                            killExtraTerminal(cardId: card.id, sessionName: sessionName)
                        },
                        onDiscover: {
                            Task {
                                await orchestrator.discoverBranchesForCard(cardId: card.id)
                                await boardState.refresh()
                            }
                        }
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
                        sessionStore: boardState.sessionStore,
                        onSelectCard: { card in
                            boardState.selectedCardId = card.id
                        },
                        onResumeCard: { card in
                            resumeCard(cardId: card.id)
                        },
                        onForkCard: { card in
                            boardState.selectedCardId = card.id
                        },
                        onCheckpointCard: { card in
                            boardState.selectedCardId = card.id
                        }
                    )
                    .padding(40)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            .animation(.easeInOut(duration: 0.15), value: showSearch)
            .sheet(isPresented: $showNewTask) {
                NewTaskDialog(
                    isPresented: $showNewTask,
                    projects: boardState.configuredProjects,
                    defaultProjectPath: boardState.selectedProjectPath,
                    onCreate: { prompt, projectPath, title, startImmediately in
                        createManualTask(prompt: prompt, projectPath: projectPath, title: title, startImmediately: startImmediately)
                    },
                    onCreateAndLaunch: { prompt, projectPath, title, createWorktree, runRemotely in
                        createManualTaskAndLaunch(prompt: prompt, projectPath: projectPath, title: title, createWorktree: createWorktree, runRemotely: runRemotely)
                    }
                )
            }
            .sheet(isPresented: $showAddFromPath) {
                addFromPathSheet
            }
            .sheet(isPresented: $showLaunchConfirmation) {
                LaunchConfirmationDialog(
                    cardId: launchCardId ?? "",
                    projectPath: launchProjectPath,
                    initialPrompt: launchPrompt,
                    worktreeName: launchWorktreeName,
                    hasExistingWorktree: launchHasExistingWorktree,
                    isGitRepo: launchIsGitRepo,
                    hasRemoteConfig: launchHasRemoteConfig,
                    remoteHost: launchRemoteHost,
                    isPresented: $showLaunchConfirmation
                ) { editedPrompt, createWorktree, runRemotely in
                    if let cardId = launchCardId {
                        let wtName: String? = createWorktree ? (launchWorktreeName ?? "") : nil
                        executeLaunch(cardId: cardId, prompt: editedPrompt, projectPath: launchProjectPath, worktreeName: wtName, runRemotely: runRemotely)
                    }
                }
            }
            .sheet(isPresented: $showOnboarding) {
                OnboardingWizard(
                    settingsStore: settingsStore,
                    onComplete: {
                        showOnboarding = false
                        // Reload notifier with potentially new pushover credentials
                        let pushover = Self.loadPushoverConfig()
                        let newNotifier = CompositeNotifier(primary: pushover, fallback: MacOSNotificationClient())
                        orchestrator.updateNotifier(newNotifier)
                    }
                )
            }
            .task {
                // Show onboarding wizard on first launch
                if let settings = try? await settingsStore.read(), !settings.hasCompletedOnboarding {
                    showOnboarding = true
                }
                applyAppearance()
                // Deploy remote shell script (idempotent)
                try? RemoteShellManager.deploy()
                // Restore persisted project selection (validate it still exists)
                if !selectedProjectPersisted.isEmpty {
                    let settings = try? await settingsStore.read()
                    let validPaths = Set(settings?.projects.map(\.path) ?? [])
                    if validPaths.contains(selectedProjectPersisted) {
                        boardState.selectedProjectPath = selectedProjectPersisted
                    } else {
                        selectedProjectPersisted = ""
                        boardState.selectedProjectPath = nil
                    }
                }
                systemTray.setup(boardState: boardState)
                await boardState.refresh()
                systemTray.update()
                orchestrator.start()
            }
            .task(id: "hook-watcher") {
                // Watch hook-events.jsonl for changes → instant refresh
                // Pass path explicitly so watchHookEvents can be nonisolated
                await watchHookEvents(path: hookEventsPath)
            }
            .task(id: "settings-watcher") {
                // Watch settings.json for changes → hot-reload
                await watchSettingsFile(path: settingsFilePath)
            }
            .task(id: "refresh-timer") {
                // Fallback periodic refresh for non-hook changes (new sessions, file mtime)
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
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
            .onReceive(NotificationCenter.default.publisher(for: .kanbanHookEvent)) { _ in
                Task {
                    await orchestrator.tick()
                    await boardState.refresh()
                    systemTray.update()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .kanbanSettingsChanged)) { _ in
                Task {
                    await boardState.refresh()
                    applyAppearance()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task {
                    await boardState.refresh()
                    systemTray.update()
                }
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

                    Button {
                        appearanceMode = appearanceMode.next
                        applyAppearance()
                    } label: {
                        Image(systemName: appearanceMode.icon)
                    }
                    .help(appearanceMode.helpText)
                }

                // Left: project selector pill
                ToolbarItem(placement: .navigation) {
                    projectSelectorMenu
                }

                // Left: sync status (only when remote is configured for selected project)
                ToolbarItem(placement: .navigation) {
                    if currentProjectHasRemote {
                        syncStatusView
                    }
                }

                // Right: search pill
                ToolbarItem(placement: .primaryAction) {
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

                // Spacer between search and sidebar pills
                ToolbarSpacer(.fixed, placement: .primaryAction)

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
                // Project switching shortcuts ⌘1..⌘9
                Button("") { selectProject(at: 0) }
                    .keyboardShortcut("1", modifiers: .command)
                    .hidden()
                Button("") { selectProject(at: 1) }
                    .keyboardShortcut("2", modifiers: .command)
                    .hidden()
                Button("") { selectProject(at: 2) }
                    .keyboardShortcut("3", modifiers: .command)
                    .hidden()
                Button("") { selectProject(at: 3) }
                    .keyboardShortcut("4", modifiers: .command)
                    .hidden()
                Button("") { selectProject(at: 4) }
                    .keyboardShortcut("5", modifiers: .command)
                    .hidden()
                Button("") { selectProject(at: 5) }
                    .keyboardShortcut("6", modifiers: .command)
                    .hidden()
                Button("") { selectProject(at: 6) }
                    .keyboardShortcut("7", modifiers: .command)
                    .hidden()
                Button("") { selectProject(at: 7) }
                    .keyboardShortcut("8", modifiers: .command)
                    .hidden()
                Button("") { selectProject(at: 8) }
                    .keyboardShortcut("9", modifiers: .command)
                    .hidden()
            }
        } // NavigationStack
    }

    /// Watch ~/.kanban/hook-events.jsonl for writes → post notification (handled by onReceive above).
    /// Must be nonisolated so GCD closures don't inherit @MainActor isolation (causes crash).
    private nonisolated func watchHookEvents(path: String) async {

        // Ensure the directory and file exist
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }

        guard let fd = open(path, O_EVTONLY) as Int32?,
              fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: .global(qos: .userInitiated)
        )

        // AsyncStream bridges GCD callbacks → async/await without actor isolation issues
        let events = AsyncStream<Void> { continuation in
            source.setEventHandler {
                continuation.yield()
            }
            source.setCancelHandler {
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                source.cancel()
            }
            source.resume()
        }

        // for-await runs on @MainActor, so posting notifications is safe
        for await _ in events {
            NotificationCenter.default.post(name: .kanbanHookEvent, object: nil)
        }

        close(fd)
    }

    /// Watch ~/.kanban/settings.json for changes → hot-reload settings and refresh board.
    private nonisolated func watchSettingsFile(path: String) async {
        guard FileManager.default.fileExists(atPath: path) else { return }

        guard let fd = open(path, O_EVTONLY) as Int32?,
              fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .global(qos: .utility)
        )

        let events = AsyncStream<Void> { continuation in
            source.setEventHandler {
                continuation.yield()
            }
            source.setCancelHandler {
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                source.cancel()
            }
            source.resume()
        }

        for await _ in events {
            NotificationCenter.default.post(name: .kanbanSettingsChanged, object: nil)
        }

        close(fd)
    }

    // MARK: - Project Selector Menu

    private var projectSelectorMenu: some View {
        Menu {
            Button {
                setSelectedProject(nil)
            } label: {
                HStack {
                    Text("All Projects")
                    Spacer()
                    Text("\(boardState.cards.count)")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    if boardState.selectedProjectPath == nil {
                        Image(systemName: "checkmark")
                    }
                }
            }

            let visibleProjects = boardState.configuredProjects.filter(\.visible)
            if !visibleProjects.isEmpty {
                Divider()
                ForEach(visibleProjects) { project in
                    Button {
                        setSelectedProject(project.path)
                    } label: {
                        HStack {
                            Text(project.name)
                            Spacer()
                            let count = boardState.cards.filter { $0.link.projectPath == project.path }.count
                            if count > 0 {
                                Text("\(count)")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                            if boardState.selectedProjectPath == project.path {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            // Discovered projects (from sessions, not yet configured)
            let discovered = boardState.discoveredProjectPaths
            if !discovered.isEmpty {
                Divider()
                Section("Discovered") {
                    ForEach(discovered.prefix(8), id: \.self) { path in
                        Button {
                            addDiscoveredProject(path: path)
                        } label: {
                            Label(
                                (path as NSString).lastPathComponent,
                                systemImage: "folder.badge.plus"
                            )
                        }
                    }
                }
            }

            Divider()

            Button("Add from folder...") {
                addProjectViaFolderPicker()
            }

            Button("Add from path...") {
                addFromPathText = ""
                showAddFromPath = true
            }

            SettingsLink {
                Text("Settings...")
            }
        } label: {
            Text(currentProjectName)
                .font(.headline)
        }
    }

    private var currentProjectName: String {
        guard let path = boardState.selectedProjectPath else { return "All Projects" }
        return boardState.configuredProjects.first(where: { $0.path == path })?.name
            ?? (path as NSString).lastPathComponent
    }

    /// Whether the currently selected project has remote execution configured.
    private var currentProjectHasRemote: Bool {
        guard let path = boardState.selectedProjectPath else {
            // Global view — show if any project has remote config
            return boardState.configuredProjects.contains { $0.remoteConfig != nil }
        }
        return boardState.configuredProjects.first(where: { $0.path == path })?.remoteConfig != nil
    }

    /// The aggregate sync status for the current project(s).
    private var currentSyncStatus: SyncStatus {
        if syncStatuses.isEmpty { return .notRunning }
        // Return worst status: error > paused > staging > watching
        if syncStatuses.values.contains(.error) { return .error }
        if syncStatuses.values.contains(.paused) { return .paused }
        if syncStatuses.values.contains(.staging) { return .staging }
        if syncStatuses.values.contains(.watching) { return .watching }
        return .notRunning
    }

    @ViewBuilder
    private var syncStatusView: some View {
        Menu {
            let status = currentSyncStatus
            Text("Mutagen Sync: \(syncStatusLabel(status))")

            if !syncStatuses.isEmpty {
                Divider()
                ForEach(Array(syncStatuses.keys.sorted()), id: \.self) { name in
                    if let st = syncStatuses[name] {
                        Label("\(name): \(syncStatusLabel(st))", systemImage: syncStatusIcon(st))
                    }
                }
            }

            Divider()

            Button {
                Task {
                    try? await mutagenAdapter.flushSync()
                    await refreshSyncStatus()
                }
            } label: {
                Label("Flush Sync", systemImage: "arrow.triangle.2.circlepath")
            }

            if currentSyncStatus == .error || currentSyncStatus == .paused {
                Button {
                    Task {
                        for name in syncStatuses.keys {
                            try? await mutagenAdapter.resetSync(name: name)
                        }
                        await refreshSyncStatus()
                    }
                } label: {
                    Label("Reset Sync", systemImage: "arrow.counterclockwise")
                }
            }

            Button {
                Task { await refreshSyncStatus() }
            } label: {
                Label("Refresh Status", systemImage: "arrow.clockwise")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: syncStatusIcon(currentSyncStatus))
                    .font(.caption)
                    .foregroundStyle(syncStatusColor(currentSyncStatus))
                Text("Sync")
                    .font(.caption)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Mutagen file sync status")
        .task { await refreshSyncStatus() }
    }

    private func refreshSyncStatus() async {
        guard await mutagenAdapter.isAvailable() else {
            syncStatuses = [:]
            return
        }
        isSyncRefreshing = true
        defer { isSyncRefreshing = false }
        syncStatuses = (try? await mutagenAdapter.status()) ?? [:]
    }

    private func syncStatusLabel(_ status: SyncStatus) -> String {
        switch status {
        case .watching: "Watching"
        case .staging: "Syncing..."
        case .paused: "Paused"
        case .error: "Error"
        case .notRunning: "Not Running"
        }
    }

    private func syncStatusIcon(_ status: SyncStatus) -> String {
        switch status {
        case .watching: "checkmark.circle.fill"
        case .staging: "arrow.triangle.2.circlepath"
        case .paused: "pause.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .notRunning: "circle.dashed"
        }
    }

    private func syncStatusColor(_ status: SyncStatus) -> Color {
        switch status {
        case .watching: .green
        case .staging: .blue
        case .paused: .yellow
        case .error: .red
        case .notRunning: .secondary
        }
    }

    private func setSelectedProject(_ path: String?) {
        boardState.selectedProjectPath = path
        selectedProjectPersisted = path ?? ""
    }

    /// Select project by index: 0 = All Projects, 1+ = configured projects by order.
    private func selectProject(at index: Int) {
        if index == 0 {
            setSelectedProject(nil)
            return
        }
        let visibleProjects = boardState.configuredProjects.filter(\.visible)
        let projectIndex = index - 1
        guard projectIndex < visibleProjects.count else { return }
        setSelectedProject(visibleProjects[projectIndex].path)
    }

    private func addProjectViaFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a project directory"
        panel.prompt = "Add Project"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        let project = Project(path: path)
        Task {
            try? await settingsStore.addProject(project)
            await boardState.refresh()
            setSelectedProject(path)
        }
    }

    private func addDiscoveredProject(path: String) {
        let project = Project(path: path)
        Task {
            try? await settingsStore.addProject(project)
            await boardState.refresh()
            setSelectedProject(path)
        }
    }

    // MARK: - Add from Path Sheet

    private var addFromPathSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Project")
                .font(.title3)
                .fontWeight(.semibold)

            TextField("Project path (e.g. ~/Projects/my-repo)", text: $addFromPathText)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") {
                    showAddFromPath = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Add") {
                    let path = (addFromPathText as NSString).expandingTildeInPath
                    let project = Project(path: path)
                    Task {
                        try? await settingsStore.addProject(project)
                        await boardState.refresh()
                        setSelectedProject(path)
                    }
                    showAddFromPath = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(addFromPathText.isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func applyAppearance() {
        switch appearanceMode {
        case .auto: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func createManualTask(prompt: String, projectPath: String?, title: String? = nil, startImmediately: Bool = false) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String
        if let title, !title.isEmpty {
            name = String(title.prefix(100))
        } else {
            let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
            name = String(firstLine.prefix(100))
        }
        let link = Link(
            name: name,
            projectPath: projectPath,
            column: startImmediately ? .inProgress : .backlog,
            source: .manual,
            promptBody: trimmed
        )
        let linkId = link.id
        Task {
            try? await coordinationStore.upsertLink(link)
            await boardState.refresh()
            if startImmediately {
                startCard(cardId: linkId)
            }
        }
    }

    /// Create a manual task and launch it directly, bypassing the LaunchConfirmationDialog.
    private func createManualTaskAndLaunch(prompt: String, projectPath: String?, title: String? = nil, createWorktree: Bool, runRemotely: Bool) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String
        if let title, !title.isEmpty {
            name = String(title.prefix(100))
        } else {
            let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
            name = String(firstLine.prefix(100))
        }
        let link = Link(
            name: name,
            projectPath: projectPath,
            column: .inProgress,
            source: .manual,
            promptBody: trimmed
        )
        let linkId = link.id
        let effectivePath = projectPath ?? NSHomeDirectory()
        Task {
            try? await coordinationStore.upsertLink(link)
            await boardState.refresh()

            // Build prompt using PromptBuilder
            let settings = try? await settingsStore.read()
            let project = settings?.projects.first(where: { $0.path == effectivePath })
            guard let card = boardState.cards.first(where: { $0.id == linkId }) else { return }
            let builtPrompt = PromptBuilder.buildPrompt(card: card.link, project: project, settings: settings)

            let wtName: String? = createWorktree ? "" : nil
            executeLaunch(cardId: linkId, prompt: builtPrompt, projectPath: effectivePath, worktreeName: wtName, runRemotely: runRemotely)
        }
    }

    // MARK: - Start / Resume

    private func startCard(cardId: String) {
        guard let card = boardState.cards.first(where: { $0.id == cardId }) else { return }
        // If card has an existing worktree, launch from there instead of project root
        let effectivePath: String
        if let worktreePath = card.link.worktreeLink?.path, !worktreePath.isEmpty {
            effectivePath = worktreePath
        } else {
            effectivePath = card.link.projectPath ?? NSHomeDirectory()
        }

        // Build prompt using PromptBuilder
        Task {
            let settings = try? await settingsStore.read()
            let project = settings?.projects.first(where: { $0.path == (card.link.projectPath ?? effectivePath) })
            var prompt = PromptBuilder.buildPrompt(card: card.link, project: project, settings: settings)
            // Fallback: if builder returns empty, use promptBody or card name directly
            if prompt.isEmpty {
                prompt = card.link.promptBody ?? card.link.name ?? ""
            }

            // Determine worktree name
            let worktreeName: String?
            if card.link.worktreeLink != nil {
                // Already has a worktree — don't create another
                worktreeName = nil
            } else if let issueNum = card.link.issueLink?.number {
                worktreeName = "issue-\(issueNum)"
            } else {
                worktreeName = nil
            }

            // Detect git repo and remote config for dialog
            let isGitRepo = FileManager.default.fileExists(
                atPath: (effectivePath as NSString).appendingPathComponent(".git")
            )

            // Show launch confirmation dialog
            launchCardId = cardId
            launchPrompt = prompt
            launchProjectPath = effectivePath
            launchWorktreeName = worktreeName
            launchHasExistingWorktree = card.link.worktreeLink != nil
            launchIsGitRepo = isGitRepo
            launchHasRemoteConfig = project?.remoteConfig != nil
            launchRemoteHost = project?.remoteConfig?.host
            showLaunchConfirmation = true
        }
    }

    private func executeLaunch(cardId: String, prompt: String, projectPath: String, worktreeName: String?, runRemotely: Bool = true) {
        Task {
            do {
                // Pre-set tmuxLink BEFORE launching to prevent duplicate card creation.
                // The reconciler matches discovered sessions to cards via tmuxLink + projectPath,
                // so this must be set before any background refresh can race.
                let predictedTmuxName = LaunchSession.tmuxSessionName(project: projectPath, worktree: worktreeName)
                try? await coordinationStore.updateLink(id: cardId) { @Sendable link in
                    link.tmuxLink = TmuxLink(sessionName: predictedTmuxName)
                    link.column = .inProgress
                }

                // Resolve remote config from project settings
                let settings = try? await settingsStore.read()
                let project = settings?.projects.first(where: { $0.path == projectPath })

                let shellOverride: String?
                let extraEnv: [String: String]
                let isRemote: Bool

                if runRemotely, let project, project.remoteConfig != nil {
                    // Deploy remote shell script and get override path
                    try? RemoteShellManager.deploy()
                    shellOverride = RemoteShellManager.shellOverridePath(for: project)
                    extraEnv = RemoteShellManager.setupEnvironment(for: project)
                    isRemote = true

                    // Start Mutagen sync before launching
                    if let remote = project.remoteConfig {
                        let syncName = "kanban-\((project.path as NSString).lastPathComponent)"
                        let remoteDest = "\(remote.host):\(remote.remotePath)"
                        try? await mutagenAdapter.startSync(
                            localPath: remote.localPath,
                            remotePath: remoteDest,
                            name: syncName
                        )
                    }
                } else {
                    shellOverride = nil
                    extraEnv = [:]
                    isRemote = false
                }

                // Snapshot existing .jsonl files before launch for session detection
                let claudeProjectsDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
                let encodedProject = projectPath.replacingOccurrences(of: "/", with: "-")
                let sessionDir = (claudeProjectsDir as NSString).appendingPathComponent(encodedProject)
                let existingFiles = Set(
                    ((try? FileManager.default.contentsOfDirectory(atPath: sessionDir)) ?? [])
                        .filter { $0.hasSuffix(".jsonl") }
                )

                let tmuxName = try await launcher.launch(
                    projectPath: projectPath,
                    prompt: prompt,
                    worktreeName: worktreeName,
                    shellOverride: shellOverride,
                    extraEnv: extraEnv
                )

                // Update with actual name (should match predicted) + remote flag
                let remoteFlag = isRemote
                try? await coordinationStore.updateLink(id: cardId) { @Sendable link in
                    link.tmuxLink = TmuxLink(sessionName: tmuxName)
                    link.column = .inProgress
                    link.isRemote = remoteFlag
                }

                // Detect new Claude session by polling for new .jsonl file (up to 3 seconds)
                for _ in 0..<6 {
                    try? await Task.sleep(for: .milliseconds(500))
                    let currentFiles = Set(
                        ((try? FileManager.default.contentsOfDirectory(atPath: sessionDir)) ?? [])
                            .filter { $0.hasSuffix(".jsonl") }
                    )
                    if let newFile = currentFiles.subtracting(existingFiles).first {
                        let sessionId = (newFile as NSString).deletingPathExtension
                        let sessionPath = (sessionDir as NSString).appendingPathComponent(newFile)
                        try? await coordinationStore.updateLink(id: cardId) { @Sendable link in
                            link.sessionLink = SessionLink(sessionId: sessionId, sessionPath: sessionPath)
                        }
                        break
                    }
                }

                boardState.setCardColumn(cardId: cardId, to: .inProgress)
                await boardState.refresh()
            } catch {
                // Clear tmuxLink on failure
                try? await coordinationStore.updateLink(id: cardId) { @Sendable link in
                    link.tmuxLink = nil
                }
                boardState.error = "Launch failed: \(error.localizedDescription)"
            }
        }
    }

    private func cleanupWorktree(cardId: String) async {
        guard let card = boardState.cards.first(where: { $0.id == cardId }),
              let worktreePath = card.link.worktreeLink?.path,
              !worktreePath.isEmpty else { return }

        let adapter = GitWorktreeAdapter()
        do {
            try await adapter.removeWorktree(path: worktreePath, force: false)
            // Clear worktree link from card
            try? await coordinationStore.updateLink(id: cardId) { @Sendable link in
                link.worktreeLink = nil
            }
            await boardState.refresh()
        } catch {
            boardState.error = "Worktree cleanup failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Extra Terminals

    private func createExtraTerminal(cardId: String) {
        guard let card = boardState.cards.first(where: { $0.id == cardId }),
              let tmux = card.link.tmuxLink else { return }

        // Working directory: worktree > projectPath > home
        let workDir: String
        if let wtPath = card.link.worktreeLink?.path, !wtPath.isEmpty {
            workDir = wtPath
        } else {
            workDir = card.link.projectPath ?? NSHomeDirectory()
        }

        // Next available shell number
        let existing = tmux.extraSessions ?? []
        let baseName = tmux.sessionName
        var n = 1
        while existing.contains("\(baseName)-sh\(n)") { n += 1 }
        let newName = "\(baseName)-sh\(n)"

        Task {
            do {
                let tmuxAdapter = TmuxAdapter()
                try await tmuxAdapter.createSession(name: newName, path: workDir, command: nil)

                try? await coordinationStore.updateLink(id: cardId) { @Sendable link in
                    var sessions = link.tmuxLink?.extraSessions ?? []
                    sessions.append(newName)
                    link.tmuxLink?.extraSessions = sessions
                }
                await boardState.refresh()
            } catch {
                boardState.error = "Failed to create terminal: \(error.localizedDescription)"
            }
        }
    }

    private func killExtraTerminal(cardId: String, sessionName: String) {
        Task {
            let tmuxAdapter = TmuxAdapter()
            try? await tmuxAdapter.killSession(name: sessionName)

            try? await coordinationStore.updateLink(id: cardId) { @Sendable link in
                link.tmuxLink?.extraSessions?.removeAll { $0 == sessionName }
                if link.tmuxLink?.extraSessions?.isEmpty == true {
                    link.tmuxLink?.extraSessions = nil
                }
            }
            await boardState.refresh()
        }
    }

    private func deleteCardWithCleanup(cardId: String) {
        guard let link = boardState.deleteCard(cardId: cardId) else { return }
        Task {
            let tmuxAdapter = TmuxAdapter()
            // Kill all tmux sessions (primary + extras)
            if let tmux = link.tmuxLink {
                for name in tmux.allSessionNames {
                    try? await tmuxAdapter.killSession(name: name)
                }
            }
            // Delete the .jsonl session file
            if let sessionPath = link.sessionLink?.sessionPath {
                try? FileManager.default.removeItem(atPath: sessionPath)
            }
        }
    }

    private func resumeCard(cardId: String) {
        guard let card = boardState.cards.first(where: { $0.id == cardId }) else { return }
        let sessionId = card.link.sessionLink?.sessionId ?? card.link.id
        let projectPath = card.link.projectPath ?? NSHomeDirectory()

        Task {
            do {
                // Resolve remote config from project settings
                let settings = try? await settingsStore.read()
                let project = settings?.projects.first(where: { $0.path == projectPath })

                let shellOverride: String?
                let extraEnv: [String: String]

                if let project, project.remoteConfig != nil {
                    try? RemoteShellManager.deploy()
                    shellOverride = RemoteShellManager.shellOverridePath(for: project)
                    extraEnv = RemoteShellManager.setupEnvironment(for: project)

                    // Start Mutagen sync before resuming
                    if let remote = project.remoteConfig {
                        let syncName = "kanban-\((project.path as NSString).lastPathComponent)"
                        let remoteDest = "\(remote.host):\(remote.remotePath)"
                        try? await mutagenAdapter.startSync(
                            localPath: remote.localPath,
                            remotePath: remoteDest,
                            name: syncName
                        )
                    }
                } else {
                    shellOverride = nil
                    extraEnv = [:]
                }

                let tmuxName = try await launcher.resume(
                    sessionId: sessionId,
                    projectPath: projectPath,
                    shellOverride: shellOverride,
                    extraEnv: extraEnv
                )

                // Update link with tmux session (by link.id)
                try? await coordinationStore.updateLink(id: cardId) { @Sendable link in
                    link.tmuxLink = TmuxLink(sessionName: tmuxName)
                    if link.column != .inProgress {
                        link.column = .inProgress
                    }
                }
                boardState.setCardColumn(cardId: cardId, to: .inProgress)
                await boardState.refresh()
            } catch {
                boardState.error = "Resume failed: \(error.localizedDescription)"
            }
        }
    }
}
