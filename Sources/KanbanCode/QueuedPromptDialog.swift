import SwiftUI
import KanbanCodeCore

struct QueuedPromptDialog: View {
    @Binding var isPresented: Bool
    var existingPrompt: QueuedPrompt?
    var onSave: (String, Bool, [ImageAttachment]) -> Void // (body, sendAutomatically, images)

    @State private var promptText: String
    @State private var sendAutomatically: Bool
    @State private var images: [ImageAttachment]

    init(
        isPresented: Binding<Bool>,
        existingPrompt: QueuedPrompt? = nil,
        onSave: @escaping (String, Bool, [ImageAttachment]) -> Void
    ) {
        self._isPresented = isPresented
        self.existingPrompt = existingPrompt
        self.onSave = onSave
        self._promptText = State(initialValue: existingPrompt?.body ?? "")
        self._sendAutomatically = State(initialValue: existingPrompt?.sendAutomatically ?? true)
        // Load images from existing prompt's temp paths
        let loaded: [ImageAttachment] = (existingPrompt?.imagePaths ?? []).compactMap { ImageAttachment.fromPath($0) }
        self._images = State(initialValue: loaded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existingPrompt != nil ? "Edit Queued Prompt" : "Queue Prompt")
                .font(.app(.title3))
                .fontWeight(.semibold)

            PromptSection(
                text: $promptText,
                images: $images,
                placeholder: "Type the next prompt for Claude...",
                maxHeight: 300,
                onSubmit: submit
            )

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
        onSave(trimmed, sendAutomatically, images)
        isPresented = false
    }
}
