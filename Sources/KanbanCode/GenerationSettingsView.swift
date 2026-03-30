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

    @State private var isCreatingContext = false
    @State private var contextCreated = false
    @State private var contextError: String? = nil

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

            Section("Context") {
                Toggle("Include CLAUDE.md from project root", isOn: $includeClaudeMd)
                Toggle("Include CONTEXT.md from project root", isOn: $includeContextMd)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button {
                            generateContextMd()
                        } label: {
                            HStack(spacing: 6) {
                                if isCreatingContext {
                                    ProgressView().controlSize(.small)
                                }
                                Text(isCreatingContext ? "Creating…" : "Create CONTEXT.md via Claude Code")
                            }
                        }
                        .disabled(isCreatingContext)

                        if contextCreated {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }

                    if let error = contextError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text("Runs `claude -p` in the selected project to generate a CONTEXT.md describing the codebase — used by the Generate feature to craft project-aware prompts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
    }

    private func generateContextMd() {
        guard let projectPath = selectedProjectPath() else {
            contextError = "No project selected. Select a project first."
            return
        }
        isCreatingContext = true
        contextError = nil
        contextCreated = false
        Task {
            do {
                let prompt = "Analyze this codebase and write a concise CONTEXT.md file that describes: the project purpose, tech stack, key directories and their roles, important conventions, and anything a new developer (or AI coding assistant) should know before making changes. Be concrete and brief."
                let result = try await runClaudeCode(in: projectPath, prompt: prompt, outputFile: "CONTEXT.md")
                await MainActor.run {
                    isCreatingContext = false
                    if result {
                        contextCreated = true
                        includeContextMd = true
                    } else {
                        contextError = "Claude Code did not produce CONTEXT.md."
                    }
                }
            } catch {
                await MainActor.run {
                    isCreatingContext = false
                    contextError = error.localizedDescription
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
