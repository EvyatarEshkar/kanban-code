import SwiftUI
import KanbanCore

/// Pre-launch confirmation dialog showing editable prompt and options.
struct LaunchConfirmationDialog: View {
    let cardId: String
    let projectPath: String
    let initialPrompt: String
    var worktreeName: String?
    @Binding var isPresented: Bool
    var onLaunch: (String, Bool) -> Void = { _, _ in } // (editedPrompt, createWorktree)

    @State private var prompt: String = ""
    @AppStorage("createWorktree") private var createWorktree = true

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

            // Create worktree checkbox
            Toggle("Create worktree", isOn: $createWorktree)
                .font(.callout)

            // Buttons
            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Launch") {
                    onLaunch(prompt, createWorktree)
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
}
