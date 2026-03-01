import SwiftUI
import KanbanCore

/// Pre-launch confirmation dialog showing editable prompt, options, and editable command.
struct LaunchConfirmationDialog: View {
    let cardId: String
    let projectPath: String
    let initialPrompt: String
    var worktreeName: String?
    let hasExistingWorktree: Bool
    let isGitRepo: Bool
    let hasRemoteConfig: Bool
    let remoteHost: String?
    @Binding var isPresented: Bool
    var onLaunch: (String, Bool, Bool, String?) -> Void = { _, _, _, _ in } // (editedPrompt, createWorktree, runRemotely, commandOverride)

    @State private var prompt: String
    @State private var command: String = ""
    @State private var commandEdited: Bool = false
    @AppStorage("createWorktree") private var createWorktree = true
    @AppStorage("runRemotely") private var runRemotely = true

    init(
        cardId: String,
        projectPath: String,
        initialPrompt: String,
        worktreeName: String? = nil,
        hasExistingWorktree: Bool = false,
        isGitRepo: Bool = false,
        hasRemoteConfig: Bool = false,
        remoteHost: String? = nil,
        isPresented: Binding<Bool>,
        onLaunch: @escaping (String, Bool, Bool, String?) -> Void = { _, _, _, _ in }
    ) {
        self.cardId = cardId
        self.projectPath = projectPath
        self.initialPrompt = initialPrompt
        self.worktreeName = worktreeName
        self.hasExistingWorktree = hasExistingWorktree
        self.isGitRepo = isGitRepo
        self.hasRemoteConfig = hasRemoteConfig
        self.remoteHost = remoteHost
        self._isPresented = isPresented
        self.onLaunch = onLaunch
        // Initialize prompt state directly — avoids .onAppear timing issues
        self._prompt = State(initialValue: initialPrompt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Launch Session")
                .font(.title3)
                .fontWeight(.semibold)

            // Project path (read-only)
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(projectPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // Worktree name (if applicable)
            if let name = worktreeName {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(.secondary)
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Editable prompt
            VStack(alignment: .leading, spacing: 4) {
                Text("Prompt")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                PromptEditor(
                    text: $prompt,
                    onSubmit: submitForm
                )
                .frame(minHeight: 120, maxHeight: 300)
                .padding(4)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }

            // Checkboxes
            VStack(alignment: .leading, spacing: 6) {
                if !hasExistingWorktree {
                    Toggle("Create worktree", isOn: isGitRepo ? $createWorktree : .constant(false))
                        .font(.callout)
                        .disabled(!isGitRepo)
                    if !isGitRepo {
                        Label("Not a git repository", systemImage: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 20)
                    }
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
                        // Track if user manually edited the command
                        if command != commandPreview {
                            commandEdited = true
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

                Button("Launch", action: submitForm)
                .keyboardShortcut(.defaultAction)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 500)
        .onAppear {
            command = commandPreview
        }
        .onChange(of: prompt) {
            if !commandEdited { command = commandPreview }
        }
    }

    // MARK: - Actions

    private func submitForm() {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let override = commandEdited ? command : nil
        onLaunch(prompt, effectiveCreateWorktree, effectiveRunRemotely, override)
        isPresented = false
    }

    // MARK: - Computed

    private var effectiveCreateWorktree: Bool {
        !hasExistingWorktree && createWorktree && isGitRepo
    }

    private var effectiveRunRemotely: Bool {
        runRemotely && hasRemoteConfig
    }

    private var commandPreview: String {
        var parts: [String] = []

        if effectiveRunRemotely {
            parts.append("SHELL=~/.kanban/remote/zsh")
            if let host = remoteHost {
                parts.append("KANBAN_REMOTE_HOST=\(host)")
            }
            parts.append("...")
        }

        var cmd = "claude"

        if effectiveCreateWorktree {
            if let name = worktreeName, !name.isEmpty {
                cmd += " --worktree \(name)"
            } else {
                cmd += " --worktree"
            }
        }

        let truncated = Self.truncatePrompt(prompt, maxLength: 60)
        cmd += " -p '\(truncated)'"

        parts.append(cmd)
        return parts.joined(separator: " \\\n  ")
    }

    static func truncatePrompt(_ text: String, maxLength: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let singleLine = trimmed.components(separatedBy: .newlines)
            .joined(separator: " ")
        if singleLine.count <= maxLength { return singleLine }
        return String(singleLine.prefix(maxLength)) + "..."
    }
}
