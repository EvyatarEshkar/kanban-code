import SwiftUI
import KanbanCodeCore

struct QueuedPromptDialog: View {
    @Binding var isPresented: Bool
    var existingPrompt: QueuedPrompt?
    var onSave: (String, Bool) -> Void // (body, sendAutomatically)

    @State private var promptText: String
    @State private var sendAutomatically: Bool

    init(
        isPresented: Binding<Bool>,
        existingPrompt: QueuedPrompt? = nil,
        onSave: @escaping (String, Bool) -> Void
    ) {
        self._isPresented = isPresented
        self.existingPrompt = existingPrompt
        self.onSave = onSave
        self._promptText = State(initialValue: existingPrompt?.body ?? "")
        self._sendAutomatically = State(initialValue: existingPrompt?.sendAutomatically ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existingPrompt != nil ? "Edit Queued Prompt" : "Queue Prompt")
                .font(.app(.title3))
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 4) {
                Text("Prompt")
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)

                PromptEditor(
                    text: $promptText,
                    placeholder: "Type the next prompt for Claude...",
                    maxHeight: 300,
                    onSubmit: submit
                )
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 80, maxHeight: 300)
                .padding(4)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }

            Toggle("Send automatically when Claude finishes", isOn: $sendAutomatically)
                .font(.app(.callout))

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button(existingPrompt != nil ? "Save" : "Add", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 450)
    }

    private func submit() {
        let trimmed = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed, sendAutomatically)
        isPresented = false
    }
}
