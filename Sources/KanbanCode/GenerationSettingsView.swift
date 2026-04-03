import SwiftUI

let defaultGenerationSystemPrompt = """
You are a prompt engineer for AI coding assistants (like Claude Code).

Given an "object" — a short description of what the user wants to work on — produce a detailed, actionable prompt ready to paste into a coding AI session.

Rules:
- Be specific and concrete. Include file paths, function names, or module names when they can be inferred.
- Focus on what needs to be done, not how long it takes.
- Use imperative language ("Add", "Fix", "Refactor", "Create").
- If a CLAUDE.md or CONTEXT.md is provided, use it to tailor the prompt to the project's conventions.
- Output ONLY the prompt — no preamble, no explanation, no markdown wrapper.
"""

struct GenerationSettingsView: View {
    @AppStorage("generationAPIKey") private var apiKey = ""
    @AppStorage("generationModel") private var model = "claude-haiku-4-5-20251001"
    @AppStorage("generationSystemPrompt") private var systemPrompt = defaultGenerationSystemPrompt
    @AppStorage("generationIncludeClaudeMd") private var includeClaudeMd = true
    @AppStorage("generationIncludeContextMd") private var includeContextMd = false

    @State private var isCreatingClaudeMd = false
    @State private var claudeMdCreated = false
    @State private var claudeMdError: String? = nil
    @State private var claudeMdStatus: FileStatus? = nil

    @State private var isCreatingContextMd = false
    @State private var contextMdCreated = false
    @State private var contextMdError: String? = nil
    @State private var contextMdStatus: FileStatus? = nil

    private let models = [
        ("claude-haiku-4-5-20251001", "Claude Haiku 4.5 (fast, cheap)"),
        ("claude-sonnet-4-6", "Claude Sonnet 4.6 (balanced)"),
        ("claude-opus-4-6", "Claude Opus 4.6 (best quality)"),
    ]

    var body: some View {
        Form {
            Section("Anthropic API") {
                LabeledContent("API Key") {
                    SecureField("sk-ant-...", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 300)
                }
                LabeledContent("Model") {
                    Picker("", selection: $model) {
                        ForEach(models, id: \.0) { id, name in
                            Text(name).tag(id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 300)
                }
            }

            Section("System Prompt") {
                Text("Sent with every generation request. The AI uses this to turn your Object into a ready-to-use coding prompt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $systemPrompt)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 140, maxHeight: 200)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

                Button("Reset to default") {
                    systemPrompt = defaultGenerationSystemPrompt
                }
                .font(.caption)
            }

            Section("Context Files") {
                Text("These files are injected into generation requests so the AI can tailor prompts to your project's conventions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // CLAUDE.md row
                contextFileRow(
                    fileName: "CLAUDE.md",
                    toggleBinding: $includeClaudeMd,
                    status: claudeMdStatus,
                    isCreating: isCreatingClaudeMd,
                    justCreated: claudeMdCreated,
                    error: claudeMdError,
                    description: "Coding conventions and architecture notes — created manually or by your team.",
                    onCreate: { generateContextFile(type: .claudeMd) }
                )

                Divider()

                // CONTEXT.md row
                contextFileRow(
                    fileName: "CONTEXT.md",
                    toggleBinding: $includeContextMd,
                    status: contextMdStatus,
                    isCreating: isCreatingContextMd,
                    justCreated: contextMdCreated,
                    error: contextMdError,
                    description: "AI-generated codebase overview — describes purpose, stack, key directories and conventions.",
                    onCreate: { generateContextFile(type: .contextMd) }
                )
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onAppear { refreshFileStatuses() }
    }

    @ViewBuilder
    private func contextFileRow(
        fileName: String,
        toggleBinding: Binding<Bool>,
        status: FileStatus?,
        isCreating: Bool,
        justCreated: Bool,
        error: String?,
        description: String,
        onCreate: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Toggle("Include \(fileName)", isOn: toggleBinding)

                Spacer()

                fileStatusBadge(status: status)
            }

            HStack(spacing: 8) {
                Button {
                    onCreate()
                } label: {
                    HStack(spacing: 6) {
                        if isCreating {
                            ProgressView().controlSize(.small)
                        }
                        Text(isCreating
                             ? "Working…"
                             : status != nil
                                ? "Update \(fileName) via Claude Code"
                                : "Create \(fileName) via Claude Code")
                    }
                }
                .disabled(isCreating)

                if justCreated {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            if let err = error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func fileStatusBadge(status: FileStatus?) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(status != nil ? .green : .secondary.opacity(0.4))
                .frame(width: 7, height: 7)
            Text(status.map { "Updated \($0.relativeDate)" } ?? "Not found")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.secondary.opacity(0.1), in: Capsule())
    }

    private struct FileStatus {
        nonisolated(unsafe) private static let formatter: RelativeDateTimeFormatter = {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .abbreviated
            return f
        }()

        let modifiedAt: Date
        var relativeDate: String {
            FileStatus.formatter.localizedString(for: modifiedAt, relativeTo: Date())
        }
    }

    private func refreshFileStatuses() {
        guard let path = selectedProjectPath() else { return }
        claudeMdStatus = fileStatus(at: (path as NSString).appendingPathComponent("CLAUDE.md"))
        contextMdStatus = fileStatus(at: (path as NSString).appendingPathComponent("CONTEXT.md"))
    }

    private func fileStatus(at path: String) -> FileStatus? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attrs[.modificationDate] as? Date else { return nil }
        return FileStatus(modifiedAt: modified)
    }

    // MARK: - Generation

    private enum ContextFileType { case claudeMd, contextMd }

    private func generateContextFile(type: ContextFileType) {
        guard let projectPath = selectedProjectPath() else {
            switch type {
            case .claudeMd:  claudeMdError  = "No project selected. Select a project first."
            case .contextMd: contextMdError = "No project selected. Select a project first."
            }
            return
        }

        switch type {
        case .claudeMd:
            isCreatingClaudeMd = true
            claudeMdError = nil
            claudeMdCreated = false
        case .contextMd:
            isCreatingContextMd = true
            contextMdError = nil
            contextMdCreated = false
        }

        let (prompt, outputFile): (String, String) = switch type {
        case .claudeMd:
            (
                "Analyze this codebase and write a concise CLAUDE.md file for Claude Code. Include: build & test commands, high-level architecture, key files and their roles, important conventions, and anything an AI assistant must know before making changes. Be concrete and brief. Do not add obvious advice.",
                "CLAUDE.md"
            )
        case .contextMd:
            (
                "Analyze this codebase and write a concise CONTEXT.md file that describes: the project purpose, tech stack, key directories and their roles, important conventions, and anything a new developer (or AI coding assistant) should know before making changes. Be concrete and brief.",
                "CONTEXT.md"
            )
        }

        Task {
            do {
                let result = try await runClaudeCode(in: projectPath, prompt: prompt, outputFile: outputFile)
                await MainActor.run {
                    switch type {
                    case .claudeMd:
                        isCreatingClaudeMd = false
                        if result {
                            claudeMdCreated = true
                            includeClaudeMd = true
                        } else {
                            claudeMdError = "Claude Code did not produce \(outputFile)."
                        }
                    case .contextMd:
                        isCreatingContextMd = false
                        if result {
                            contextMdCreated = true
                            includeContextMd = true
                        } else {
                            contextMdError = "Claude Code did not produce \(outputFile)."
                        }
                    }
                    refreshFileStatuses()
                }
            } catch {
                await MainActor.run {
                    switch type {
                    case .claudeMd:
                        isCreatingClaudeMd = false
                        claudeMdError = error.localizedDescription
                    case .contextMd:
                        isCreatingContextMd = false
                        contextMdError = error.localizedDescription
                    }
                }
            }
        }
    }

    private func selectedProjectPath() -> String? {
        let persisted = UserDefaults.standard.string(forKey: "selectedProject") ?? ""
        return persisted.isEmpty ? nil : persisted
    }

    private func runClaudeCode(in path: String, prompt: String, outputFile: String) async throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let script = """
        cd \(path.shellEscaped) && claude -p \(prompt.shellEscaped) > \(outputFile.shellEscaped) 2>/dev/null
        """
        process.arguments = ["-c", script]
        try process.run()
        process.waitUntilExit()
        let outputPath = (path as NSString).appendingPathComponent(outputFile)
        return FileManager.default.fileExists(atPath: outputPath)
    }
}

private extension String {
    var shellEscaped: String {
        "'" + self.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
