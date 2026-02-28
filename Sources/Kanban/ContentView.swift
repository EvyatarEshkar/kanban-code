import SwiftUI
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
    @AppStorage("selectedProject") private var selectedProjectPersisted: String = ""
    private let coordinationStore: CoordinationStore
    private let settingsStore: SettingsStore
    private let launcher: LaunchSession
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
            onRefreshBacklog: { Task { await boardState.refreshBacklog() } }
        )
            .ignoresSafeArea(edges: .top)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .navigationTitle("")
            .inspector(isPresented: showInspector) {
                if let card = boardState.cards.first(where: { $0.id == boardState.selectedCardId }) {
                    CardDetailView(
                        card: card,
                        onResume: { resumeCard(cardId: card.id) },
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
                NewTaskDialog(
                    isPresented: $showNewTask,
                    projects: boardState.configuredProjects,
                    defaultProjectPath: boardState.selectedProjectPath
                ) { prompt, projectPath, startImmediately in
                    createManualTask(prompt: prompt, projectPath: projectPath, startImmediately: startImmediately)
                }
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
                    isPresented: $showLaunchConfirmation
                ) { editedPrompt, createWorktree in
                    if let cardId = launchCardId {
                        executeLaunch(cardId: cardId, prompt: editedPrompt, projectPath: launchProjectPath, worktreeName: createWorktree ? launchWorktreeName : nil)
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
                // Restore persisted project selection
                boardState.selectedProjectPath = selectedProjectPersisted.isEmpty ? nil : selectedProjectPersisted
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
            .onReceive(NotificationCenter.default.publisher(for: .kanbanHookEvent)) { _ in
                Task {
                    await orchestrator.tick()
                    await boardState.refresh()
                    systemTray.update()
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

    // MARK: - Project Selector Menu

    private var projectSelectorMenu: some View {
        Menu {
            Button {
                setSelectedProject(nil)
            } label: {
                HStack {
                    Text("All Projects")
                    Spacer()
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

    private func createManualTask(prompt: String, projectPath: String?, startImmediately: Bool = false) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
        let name = String(firstLine.prefix(100))
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

    // MARK: - Start / Resume

    private func startCard(cardId: String) {
        guard let card = boardState.cards.first(where: { $0.id == cardId }) else { return }
        let projectPath = card.link.projectPath ?? NSHomeDirectory()

        // Build prompt using PromptBuilder
        Task {
            let settings = try? await settingsStore.read()
            let project = settings?.projects.first(where: { $0.path == projectPath })
            let prompt = PromptBuilder.buildPrompt(card: card.link, project: project, settings: settings)

            // Determine worktree name
            let worktreeName: String?
            if let issueNum = card.link.issueLink?.number {
                worktreeName = "issue-\(issueNum)"
            } else {
                worktreeName = nil
            }

            // Show launch confirmation dialog
            launchCardId = cardId
            launchPrompt = prompt
            launchProjectPath = projectPath
            launchWorktreeName = worktreeName
            showLaunchConfirmation = true
        }
    }

    private func executeLaunch(cardId: String, prompt: String, projectPath: String, worktreeName: String?) {
        Task {
            do {
                let tmuxName = try await launcher.launch(
                    projectPath: projectPath,
                    prompt: prompt,
                    worktreeName: worktreeName,
                    shellOverride: nil
                )

                // Update the EXISTING link (by link.id) — no new link created
                try? await coordinationStore.updateLink(id: cardId) { @Sendable link in
                    link.tmuxLink = TmuxLink(sessionName: tmuxName)
                    link.column = .inProgress
                }
                boardState.setCardColumn(cardId: cardId, to: .inProgress)
                await boardState.refresh()
            } catch {
                boardState.error = "Launch failed: \(error.localizedDescription)"
            }
        }
    }

    private func resumeCard(cardId: String) {
        guard let card = boardState.cards.first(where: { $0.id == cardId }) else { return }
        let sessionId = card.link.sessionLink?.sessionId ?? card.link.id
        let projectPath = card.link.projectPath ?? NSHomeDirectory()

        Task {
            do {
                let tmuxName = try await launcher.resume(
                    sessionId: sessionId,
                    projectPath: projectPath,
                    shellOverride: nil
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
