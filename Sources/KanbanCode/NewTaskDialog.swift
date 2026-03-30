import SwiftUI
import KanbanCodeCore

struct NewTaskDialog: View {
    @Binding var isPresented: Bool
    var projects: [Project] = []
    var defaultProjectPath: String?
    var globalRemoteSettings: RemoteSettings?
    var enabledAssistants: [CodingAssistant] = CodingAssistant.allCases
    var existingCards: [KanbanCodeCard] = []
    /// (prompt, object, projectPath, title, startImmediately, images) — creates task without an assistant set
    var onCreate: (String, String?, String?, String?, Bool, [ImageAttachment]) -> Void = { _, _, _, _, _, _ in }
    /// (prompt, object, projectPath, title, createWorktree, runRemotely, skipPermissions, commandOverride, images, assistant) — creates and launches directly (skips LaunchConfirmation)
    var onCreateAndLaunch: (String, String?, String?, String?, Bool, Bool, Bool, String?, [ImageAttachment], CodingAssistant) -> Void = { _, _, _, _, _, _, _, _, _, _ in }
    /// (cardId, prompt) — sends prompt to an existing card's session queue
    var onSendToExisting: (String, String) -> Void = { _, _ in }
    // Edit mode — pass existing fields to pre-fill
    var editingName: String? = nil
    var editingObject: String? = nil
    var editingPrompt: String? = nil
    var editingProjectPath: String? = nil
    /// (prompt, object, projectPath, title) — updates existing card
    var onUpdate: (String, String?, String?, String?) -> Void = { _, _, _, _ in }

    @AppStorage("selectedAssistant") private var selectedAssistantRaw: String = CodingAssistant.claude.rawValue
    private var selectedAssistant: CodingAssistant {
        get { CodingAssistant(rawValue: selectedAssistantRaw) ?? .claude }
        nonmutating set { selectedAssistantRaw = newValue.rawValue }
    }
    @State private var prompt = ""
    @State private var images: [ImageAttachment] = []
    @State private var title = ""
    @State private var object = ""
    @State private var selectedProjectPath: String = ""
    @State private var selectedExistingCardId: String? = nil
    @State private var customPath = ""
    @State private var command = ""
    @State private var commandEdited = false
    @State private var worktreeBranch = ""
    @AppStorage("startTaskImmediately") private var startImmediately = true
    @State private var createWorktree = true
    @State private var runRemotely = true
    @AppStorage("dangerouslySkipPermissions") private var dangerouslySkipPermissions = true
    @AppStorage("lastSelectedProjectPath") private var lastSelectedProjectPath = ""

    // Generation
    @AppStorage("generationAPIKey") private var generationAPIKey = ""
    @State private var showGenerationChat = false

    private static let customPathSentinel = "__custom__"

    private var isEditing: Bool { editingName != nil || editingObject != nil || editingPrompt != nil || editingProjectPath != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isEditing ? "Edit Task" : "New Task")
                .font(.app(.title3))
                .fontWeight(.semibold)

            // Row 1: Title + Project
            HStack(alignment: .center, spacing: 10) {
                TextField("Title (optional)", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .font(.app(.callout))

                // Project picker
                if projects.isEmpty {
                    TextField("Project path", text: $customPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.app(.caption))
                        .frame(width: 160)
                } else {
                    Picker("", selection: $selectedProjectPath) {
                        ForEach(projects) { project in
                            Text(project.name).tag(project.path)
                        }
                        Divider()
                        Text("Custom path...").tag(Self.customPathSentinel)
                    }
                    .frame(width: 160)
                }
            }

            if selectedProjectPath == Self.customPathSentinel {
                TextField("Project path", text: $customPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.app(.caption))
            }

            // Object field — multiline, same style as prompt
            VStack(alignment: .leading, spacing: 4) {
                Text("Object")
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
                PromptEditor(
                    text: $object,
                    placeholder: "What are you working on?",
                    maxHeight: 200,
                    submitOnReturn: false,
                    onSubmit: submitForm
                )
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 80, maxHeight: 200, alignment: .top)
                .padding(4)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }

            // Prompt header row with Generate button
            HStack {
                Text("Prompt")
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showGenerationChat = true
                } label: {
                    Label("Generate", systemImage: "sparkles")
                        .font(.app(.caption))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.borderless)
                .disabled(object.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || generationAPIKey.isEmpty)
                .popover(isPresented: $showGenerationChat, arrowEdge: .top) {
                    PromptGenerationChat(
                        object: object.trimmingCharacters(in: .whitespacesAndNewlines),
                        projectPath: resolvedProjectPath
                    ) { generated in
                        prompt = generated
                        showGenerationChat = false
                    }
                }
            }

            // Prompt field (no label — shown above)
            PromptEditor(
                text: $prompt,
                placeholder: "Describe what you want \(selectedAssistant.displayName) to do... (optional)",
                maxHeight: 400,
                submitOnReturn: false,
                onSubmit: submitForm
            )
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 80, maxHeight: 400, alignment: .top)
            .padding(4)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

            // Existing session picker (shown when project has existing cards)
            if !cardsForSelectedProject.isEmpty {
                Picker("Session", selection: $selectedExistingCardId) {
                    Text("New session").tag(String?.none)
                    Divider()
                    ForEach(cardsForSelectedProject) { card in
                        Text(card.displayTitle)
                            .lineLimit(1)
                            .tag(String?.some(card.id))
                    }
                }
                .font(.app(.callout))
                .onChange(of: selectedExistingCardId) {
                    if selectedExistingCardId != nil { startImmediately = false }
                }
            }

            // Start immediately toggle (hidden when sending to existing session)
            if selectedExistingCardId == nil {
                Toggle("Start immediately", isOn: $startImmediately)
                    .font(.app(.callout))
            }

            // Launch options (hidden when sending to an existing session)
            if startImmediately && selectedExistingCardId == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Create worktree", isOn: (isGitRepo && selectedAssistant.supportsWorktree) ? $createWorktree : .constant(false))
                        .font(.app(.callout))
                        .disabled(!isGitRepo || !selectedAssistant.supportsWorktree)
                    if !isGitRepo {
                        Label("Not a git repository", systemImage: "info.circle")
                            .font(.app(.caption2))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 20)
                    } else if !selectedAssistant.supportsWorktree {
                        Label("\(selectedAssistant.displayName) doesn't support worktrees", systemImage: "info.circle")
                            .font(.app(.caption2))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 20)
                    }
                    if createWorktree && isGitRepo {
                        HStack {
                            Text("Branch name")
                                .font(.app(.callout))
                                .foregroundStyle(.secondary)
                            TextField("", text: $worktreeBranch, prompt: Text("Leave empty for a random name"))
                                .textFieldStyle(.roundedBorder)
                                .font(.app(.callout))
                        }
                        .padding(.leading, 20)
                    }

                    Toggle("Run remotely", isOn: hasRemoteConfig ? $runRemotely : .constant(false))
                        .font(.app(.callout))
                        .disabled(!hasRemoteConfig)
                    if !hasRemoteConfig {
                        Label(
                            globalRemoteSettings != nil
                                ? "Project not under remote sync path"
                                : "Configure remote execution in Settings > Remote",
                            systemImage: "info.circle"
                        )
                            .font(.app(.caption2))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 20)
                    }

                    Toggle("Dangerously skip permissions", isOn: $dangerouslySkipPermissions)
                        .font(.app(.callout))
                }

                // Editable command
                VStack(alignment: .leading, spacing: 4) {
                    Text("Command")
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $command)
                        .font(.app(.caption).monospaced())
                        .frame(minHeight: 36, maxHeight: 80)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(4)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                        .onChange(of: command) {
                            if command != commandPreview {
                                commandEdited = true
                            }
                        }
                }
            }

            // Buttons
            HStack {
                if startImmediately && enabledAssistants.count > 1 {
                    Picker(selection: $selectedAssistantRaw) {
                        ForEach(enabledAssistants, id: \.self) { assistant in
                            Text(assistant.displayName)
                                .tag(assistant.rawValue)
                        }
                    } label: {
                        EmptyView()
                    }
                    .fixedSize()
                }

                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button(isEditing ? "Save" : selectedExistingCardId != nil ? "Send to Session" : startImmediately ? "Create & Start" : "Create", action: submitForm)
                .keyboardShortcut(.defaultAction)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && object.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 450)
        .onAppear {
            // Pre-fill for edit mode
            if isEditing {
                title = editingName ?? ""
                object = editingObject ?? ""
                prompt = editingPrompt ?? ""
                if let path = editingProjectPath, projects.contains(where: { $0.path == path }) {
                    selectedProjectPath = path
                } else if let first = projects.first {
                    selectedProjectPath = first.path
                }
            } else {
                if let defaultPath = defaultProjectPath,
                   projects.contains(where: { $0.path == defaultPath }) {
                    selectedProjectPath = defaultPath
                } else if !lastSelectedProjectPath.isEmpty,
                   projects.contains(where: { $0.path == lastSelectedProjectPath }) {
                    selectedProjectPath = lastSelectedProjectPath
                } else if let first = projects.first {
                    selectedProjectPath = first.path
                }
            }
            // Ensure selected assistant is enabled; fall back to first enabled
            if !enabledAssistants.contains(selectedAssistant),
               let first = enabledAssistants.first {
                selectedAssistant = first
            }
            if let path = resolvedProjectPath {
                runRemotely = UserDefaults.standard.object(forKey: "runRemotely_\(path)") as? Bool ?? true
                createWorktree = UserDefaults.standard.object(forKey: "createWorktree_\(path)") as? Bool ?? true
            }
            command = commandPreview
        }
        .onChange(of: prompt) {
            if !commandEdited { command = commandPreview }
        }
        .onChange(of: createWorktree) {
            if let path = resolvedProjectPath {
                UserDefaults.standard.set(createWorktree, forKey: "createWorktree_\(path)")
            }
            if !commandEdited { command = commandPreview }
        }
        .onChange(of: worktreeBranch) {
            if !commandEdited { command = commandPreview }
        }
        .onChange(of: runRemotely) {
            if let path = resolvedProjectPath {
                UserDefaults.standard.set(runRemotely, forKey: "runRemotely_\(path)")
            }
            if !commandEdited { command = commandPreview }
        }
        .onChange(of: selectedProjectPath) {
            if let path = resolvedProjectPath {
                runRemotely = UserDefaults.standard.object(forKey: "runRemotely_\(path)") as? Bool ?? true
                createWorktree = UserDefaults.standard.object(forKey: "createWorktree_\(path)") as? Bool ?? true
            }
            selectedExistingCardId = nil
            if !commandEdited { command = commandPreview }
        }
        .onChange(of: dangerouslySkipPermissions) {
            if !commandEdited { command = commandPreview }
        }
        .onChange(of: selectedAssistantRaw) {
            if !commandEdited { command = commandPreview }
        }
    }

    // MARK: - Actions

    private func submitForm() {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !object.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let proj = resolvedProjectPath
        let titleOrNil = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let proj { lastSelectedProjectPath = proj }

        let objectOrNil = object.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : object.trimmingCharacters(in: .whitespacesAndNewlines)

        // Edit mode
        if isEditing {
            onUpdate(prompt, objectOrNil, proj, titleOrNil)
            isPresented = false
            return
        }

        if let existingCardId = selectedExistingCardId {
            onSendToExisting(existingCardId, prompt)
        } else if startImmediately {
            onCreateAndLaunch(
                prompt,
                objectOrNil,
                proj,
                titleOrNil,
                createWorktree && isGitRepo && selectedAssistant.supportsWorktree,
                runRemotely && hasRemoteConfig,
                dangerouslySkipPermissions,
                commandEdited ? command : nil,
                images,
                selectedAssistant
            )
        } else {
            onCreate(prompt, objectOrNil, proj, titleOrNil, false, images)
        }
        isPresented = false
    }

    // MARK: - Computed

    private var resolvedProjectPath: String? {
        if projects.isEmpty {
            return customPath.isEmpty ? nil : customPath
        }
        if selectedProjectPath == Self.customPathSentinel {
            return customPath.isEmpty ? nil : customPath
        }
        return selectedProjectPath.isEmpty ? nil : selectedProjectPath
    }

    private var selectedProject: Project? {
        projects.first(where: { $0.path == resolvedProjectPath })
    }

    private var cardsForSelectedProject: [KanbanCodeCard] {
        guard let path = resolvedProjectPath, !path.isEmpty else { return [] }
        return existingCards.filter { card in
            let cardPath = card.link.projectPath ?? ""
            guard cardPath == path || cardPath.hasPrefix(path + "/") else { return false }
            guard card.link.sessionLink != nil else { return false }
            return true
        }
    }

    private var isGitRepo: Bool {
        guard let path = resolvedProjectPath, !path.isEmpty else { return false }
        return FileManager.default.fileExists(
            atPath: (path as NSString).appendingPathComponent(".git")
        )
    }

    private var hasRemoteConfig: Bool {
        guard let remote = globalRemoteSettings else { return false }
        guard let path = resolvedProjectPath else { return false }
        return path.hasPrefix(remote.localPath)
    }

    private var remoteHost: String? {
        globalRemoteSettings?.host
    }

    private var commandPreview: String {
        var parts: [String] = []

        if runRemotely && hasRemoteConfig {
            parts.append("SHELL=~/.kanban-code/remote/zsh")
            if selectedAssistant == .gemini {
                parts.append("PATH=~/.kanban-code/remote:$PATH")
            }
        }

        var cmd = selectedAssistant.cliCommand
        if dangerouslySkipPermissions { cmd += " \(selectedAssistant.autoApproveFlag)" }

        if createWorktree && isGitRepo && selectedAssistant.supportsWorktree {
            let branch = worktreeBranch.trimmingCharacters(in: .whitespacesAndNewlines)
            if branch.isEmpty {
                cmd += " --worktree"
            } else {
                cmd += " --worktree \(branch)"
            }
        }

        parts.append(cmd)

        return parts.joined(separator: " \\\n  ")
    }
}
