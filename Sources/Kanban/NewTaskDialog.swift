import SwiftUI
import KanbanCore

struct NewTaskDialog: View {
    @Binding var isPresented: Bool
    var projects: [Project] = []
    var defaultProjectPath: String?
    /// (prompt, projectPath, title, startImmediately) — creates task, optionally starts via LaunchConfirmation
    var onCreate: (String, String?, String?, Bool) -> Void = { _, _, _, _ in }
    /// (prompt, projectPath, title, createWorktree, runRemotely, commandOverride) — creates and launches directly (skips LaunchConfirmation)
    var onCreateAndLaunch: (String, String?, String?, Bool, Bool, String?) -> Void = { _, _, _, _, _, _ in }

    @State private var prompt = ""
    @State private var title = ""
    @State private var selectedProjectPath: String = ""
    @State private var customPath = ""
    @State private var command = ""
    @State private var commandEdited = false
    @AppStorage("startTaskImmediately") private var startImmediately = true
    @AppStorage("createWorktree") private var createWorktree = true
    @AppStorage("runRemotely") private var runRemotely = true

    private static let customPathSentinel = "__custom__"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Task")
                .font(.title3)
                .fontWeight(.semibold)

            // Prompt
            VStack(alignment: .leading, spacing: 4) {
                Text("Prompt")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                PromptEditor(
                    text: $prompt,
                    placeholder: "Describe what you want Claude to do...",
                    onSubmit: submitForm
                )
                .frame(minHeight: 80, maxHeight: 200)
                .padding(4)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }

            // Title (optional)
            TextField("Title (optional)", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.callout)

            // Project picker
            if projects.isEmpty {
                TextField("Project path (optional)", text: $customPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            } else {
                Picker("Project", selection: $selectedProjectPath) {
                    ForEach(projects) { project in
                        Text(project.name).tag(project.path)
                    }
                    Divider()
                    Text("Custom path...").tag(Self.customPathSentinel)
                }

                if selectedProjectPath == Self.customPathSentinel {
                    TextField("Project path", text: $customPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                }
            }

            // Start immediately toggle
            Toggle("Start immediately", isOn: $startImmediately)
                .font(.callout)

            // Launch options (shown when "Start immediately" is checked)
            if startImmediately {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Create worktree", isOn: isGitRepo ? $createWorktree : .constant(false))
                        .font(.callout)
                        .disabled(!isGitRepo)
                    if !isGitRepo {
                        Label("Not a git repository", systemImage: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 20)
                    }

                    Toggle("Run remotely", isOn: hasRemoteConfig ? $runRemotely : .constant(false))
                        .font(.callout)
                        .disabled(!hasRemoteConfig)
                    if !hasRemoteConfig {
                        Label("Configure remote execution in project settings", systemImage: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 20)
                    }
                }

                // Editable command
                VStack(alignment: .leading, spacing: 4) {
                    Text("Command")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("", text: $command)
                        .font(.caption.monospaced())
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: command) {
                            if command != commandPreview {
                                commandEdited = true
                            }
                        }
                }
            }

            // Buttons
            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button(startImmediately ? "Create & Start" : "Create", action: submitForm)
                .keyboardShortcut(.defaultAction)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 450)
        .onAppear {
            if let defaultPath = defaultProjectPath,
               projects.contains(where: { $0.path == defaultPath }) {
                selectedProjectPath = defaultPath
            } else if let first = projects.first {
                selectedProjectPath = first.path
            }
            command = commandPreview
        }
        .onChange(of: prompt) {
            if !commandEdited { command = commandPreview }
        }
        .onChange(of: createWorktree) {
            if !commandEdited { command = commandPreview }
        }
    }

    // MARK: - Actions

    private func submitForm() {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let proj = resolvedProjectPath
        let titleOrNil = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : title.trimmingCharacters(in: .whitespacesAndNewlines)
        if startImmediately {
            onCreateAndLaunch(
                prompt,
                proj,
                titleOrNil,
                createWorktree && isGitRepo,
                runRemotely && hasRemoteConfig,
                commandEdited ? command : nil
            )
        } else {
            onCreate(prompt, proj, titleOrNil, false)
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

    private var isGitRepo: Bool {
        guard let path = resolvedProjectPath, !path.isEmpty else { return false }
        return FileManager.default.fileExists(
            atPath: (path as NSString).appendingPathComponent(".git")
        )
    }

    private var hasRemoteConfig: Bool {
        selectedProject?.remoteConfig != nil
    }

    private var remoteHost: String? {
        selectedProject?.remoteConfig?.host
    }

    private var commandPreview: String {
        var parts: [String] = []

        if runRemotely && hasRemoteConfig {
            parts.append("SHELL=~/.kanban/remote/zsh")
            if let host = remoteHost {
                parts.append("KANBAN_REMOTE_HOST=\(host)")
            }
            parts.append("...")
        }

        var cmd = "claude"

        if createWorktree && isGitRepo {
            cmd += " --worktree"
        }

        let truncated = LaunchConfirmationDialog.truncatePrompt(prompt, maxLength: 60)
        cmd += " -p '\(truncated)'"

        parts.append(cmd)
        return parts.joined(separator: " \\\n  ")
    }
}
