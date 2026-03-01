import SwiftUI
import KanbanCore

/// Pre-launch confirmation dialog showing editable prompt, options, and command preview.
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
    var onLaunch: (String, Bool, Bool) -> Void = { _, _, _ in } // (editedPrompt, createWorktree, runRemotely)

    @State private var prompt: String = ""
    @AppStorage("createWorktree") private var createWorktree = true
    @AppStorage("runRemotely") private var runRemotely = true

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

                TextEditor(text: $prompt)
                    .font(.body.monospaced())
                    .frame(minHeight: 120, maxHeight: 300)
                    .scrollContentBackground(.hidden)
                    .padding(8)
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

            // Command preview
            VStack(alignment: .leading, spacing: 4) {
                Text("Command")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(commandPreview)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            }

            // Buttons
            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Launch") {
                    onLaunch(prompt, effectiveCreateWorktree, effectiveRunRemotely)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 500)
        .onAppear {
            prompt = initialPrompt
        }
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
