import SwiftUI

// MARK: - Model

struct GenerationMessage: Identifiable {
    let id = UUID()
    let role: String   // "user" | "assistant"
    var content: String
    var isStreaming: Bool = false
}

// MARK: - Chat view (shown as popover)

struct PromptGenerationChat: View {
    let object: String
    let projectPath: String?
    var onUsePrompt: (String) -> Void

    @AppStorage("generationAPIKey")     private var apiKey = ""
    @AppStorage("generationModel")      private var model = "claude-haiku-4-5-20251001"
    @AppStorage("generationSystemPrompt") private var systemPrompt = defaultGenerationSystemPrompt
    @AppStorage("generationIncludeClaudeMd")   private var includeClaudeMd = true
    @AppStorage("generationIncludeContextMd")  private var includeContextMd = false

    @State private var messages: [GenerationMessage] = []
    @State private var followUp = ""
    @State private var isLoading = false
    @State private var error: String? = nil
    @FocusState private var inputFocused: Bool

    private let quickActions = [
        ("Make it shorter",       "Rewrite the prompt to be more concise while keeping all the key requirements."),
        ("More specific",         "Make the prompt more specific and concrete with clear acceptance criteria."),
        ("Add error handling",    "Expand the prompt to explicitly cover edge cases and error handling."),
        ("Focus on tests",        "Adjust the prompt to also ask for tests alongside the implementation."),
        ("Step-by-step",          "Rewrite as a numbered step-by-step breakdown of what needs to be done."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ──────────────────────────────────────────────────
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                Text("Prompt Generator")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // ── Messages ─────────────────────────────────────────────────
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(messages) { msg in
                            ChatBubble(
                                message: msg,
                                onUse: {
                                    onUsePrompt(msg.content)
                                }
                            )
                            .id(msg.id)
                        }
                        if let err = error {
                            Text(err)
                                .font(.system(size: 12))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 12)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.vertical, 10)
                }
                .onChange(of: messages.count) {
                    withAnimation { proxy.scrollTo("bottom") }
                }
                .onChange(of: messages.last?.content) {
                    withAnimation { proxy.scrollTo("bottom") }
                }
            }

            Divider()

            // ── Quick actions ─────────────────────────────────────────────
            if !messages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(quickActions, id: \.0) { label, instruction in
                            Button {
                                send(instruction)
                            } label: {
                                Text(label)
                                    .font(.system(size: 11, weight: .medium))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(.secondary.opacity(0.12), in: Capsule())
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .disabled(isLoading)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                }
                Divider()
            }

            // ── Input row ────────────────────────────────────────────────
            HStack(spacing: 8) {
                TextField("Ask for changes…", text: $followUp)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .focused($inputFocused)
                    .onSubmit { sendFollowUp() }
                    .disabled(isLoading || messages.isEmpty)

                Button {
                    if messages.isEmpty {
                        startGeneration()
                    } else {
                        sendFollowUp()
                    }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(width: 400, height: 480)
        .onAppear {
            startGeneration()
            inputFocused = false
        }
    }

    private var canSend: Bool {
        if isLoading { return false }
        if messages.isEmpty { return true }
        return !followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Generation

    private func startGeneration() {
        var userContent = object

        if let path = projectPath {
            if includeClaudeMd,
               let txt = try? String(contentsOfFile: (path as NSString).appendingPathComponent("CLAUDE.md"), encoding: .utf8) {
                userContent += "\n\n<CLAUDE.md>\n\(txt)\n</CLAUDE.md>"
            }
            if includeContextMd,
               let txt = try? String(contentsOfFile: (path as NSString).appendingPathComponent("CONTEXT.md"), encoding: .utf8) {
                userContent += "\n\n<CONTEXT.md>\n\(txt)\n</CONTEXT.md>"
            }
        }

        send(userContent, isFirstMessage: true)
    }

    private func sendFollowUp() {
        let text = followUp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        followUp = ""
        send(text)
    }

    private func send(_ userText: String, isFirstMessage: Bool = false) {
        error = nil
        let userMsg = GenerationMessage(role: "user", content: isFirstMessage ? object : userText)
        if isFirstMessage {
            messages = [userMsg]
        } else {
            messages.append(userMsg)
        }

        var placeholderId: UUID? = nil
        let placeholder = GenerationMessage(role: "assistant", content: "", isStreaming: true)
        placeholderId = placeholder.id
        messages.append(placeholder)

        isLoading = true

        // Build full history to send (use actual user content for API, display content for UI)
        var apiMessages: [[String: String]] = []
        // First user message includes context files; rest are display messages
        for (i, m) in messages.enumerated() {
            guard !m.isStreaming else { continue }
            if i == 0 && isFirstMessage {
                // Already handled — the first msg shown is "object" but we actually send userText
                apiMessages.append(["role": "user", "content": userText])
            } else if m.role == "user" || m.role == "assistant" {
                apiMessages.append(["role": m.role, "content": m.content])
            }
        }
        // If not first message, we need the full history including prior messages
        if !isFirstMessage {
            // Rebuild: all messages except the placeholder we just added
            apiMessages = []
            let priorMessages = messages.dropLast() // drop placeholder
            for (i, m) in priorMessages.enumerated() {
                if i == 0 {
                    // First display msg is "object"; API got context-enriched version — reconstruct
                    var content = object
                    if let path = projectPath {
                        if includeClaudeMd,
                           let txt = try? String(contentsOfFile: (path as NSString).appendingPathComponent("CLAUDE.md"), encoding: .utf8) {
                            content += "\n\n<CLAUDE.md>\n\(txt)\n</CLAUDE.md>"
                        }
                        if includeContextMd,
                           let txt = try? String(contentsOfFile: (path as NSString).appendingPathComponent("CONTEXT.md"), encoding: .utf8) {
                            content += "\n\n<CONTEXT.md>\n\(txt)\n</CONTEXT.md>"
                        }
                    }
                    apiMessages.append(["role": "user", "content": content])
                } else {
                    apiMessages.append(["role": m.role, "content": m.content])
                }
            }
            apiMessages.append(["role": "user", "content": userText])
        }

        Task {
            do {
                let result = try await callAnthropic(messages: apiMessages)
                await MainActor.run {
                    if let pid = placeholderId,
                       let idx = messages.firstIndex(where: { $0.id == pid }) {
                        messages[idx].content = result
                        messages[idx].isStreaming = false
                    }
                    isLoading = false
                    inputFocused = true
                }
            } catch {
                await MainActor.run {
                    if let pid = placeholderId,
                       let idx = messages.firstIndex(where: { $0.id == pid }) {
                        messages.remove(at: idx)
                    }
                    self.error = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func callAnthropic(messages apiMessages: [[String: String]]) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": systemPrompt,
            "messages": apiMessages
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw GenChatError.invalidResponse }
        guard http.statusCode == 200 else {
            let msg = (try? JSONDecoder().decode(AnthropicErrResp.self, from: data))?.error.message ?? "HTTP \(http.statusCode)"
            throw GenChatError.api(msg)
        }
        let decoded = try JSONDecoder().decode(AnthropicResp.self, from: data)
        guard let text = decoded.content.first?.text else { throw GenChatError.empty }
        return text
    }
}

// MARK: - Chat bubble

private struct ChatBubble: View {
    let message: GenerationMessage
    let onUse: () -> Void

    @State private var hovered = false

    var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: 40) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(message.content.isEmpty && message.isStreaming ? "…" : message.content)
                    .font(.system(size: 13))
                    .foregroundStyle(isUser ? Color.white : Color.primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(
                        isUser ? Color.accentColor : Color.secondary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 12)
                    )

                if !isUser && !message.isStreaming && !message.content.isEmpty {
                    HStack(spacing: 8) {
                        Button {
                            onUse()
                        } label: {
                            Label("Use this prompt", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.green)
                        }
                        .buttonStyle(.plain)

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.content, forType: .string)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 4)
                    .transition(.opacity)
                }
            }

            if !isUser { Spacer(minLength: 40) }
        }
        .padding(.horizontal, 12)
        .animation(.easeInOut(duration: 0.15), value: message.isStreaming)
    }
}

// MARK: - Decodable helpers

private enum GenChatError: LocalizedError {
    case invalidResponse, api(String), empty
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid API response"
        case .api(let m):      return m
        case .empty:           return "Empty response"
        }
    }
}

private struct AnthropicResp: Decodable {
    struct Block: Decodable { let text: String }
    let content: [Block]
}

private struct AnthropicErrResp: Decodable {
    struct Body: Decodable { let message: String }
    let error: Body
}
