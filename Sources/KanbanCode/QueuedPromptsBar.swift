import SwiftUI
import KanbanCodeCore

struct QueuedPromptsBar: View {
    let prompts: [QueuedPrompt]
    var onSendNow: (String) -> Void    // promptId
    var onEdit: (QueuedPrompt) -> Void
    var onRemove: (String) -> Void     // promptId

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(prompts) { prompt in
                HStack(spacing: 6) {
                    if prompt.sendAutomatically {
                        Image(systemName: "bolt.fill")
                            .font(.app(size: 9))
                            .foregroundStyle(.orange)
                            .help("Will send automatically when Claude finishes")
                    }

                    Text(prompt.body)
                        .font(.app(.caption))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Send Now") {
                        onSendNow(prompt.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)

                    Button {
                        onEdit(prompt)
                    } label: {
                        Image(systemName: "pencil")
                            .font(.app(.caption2))
                    }
                    .buttonStyle(.borderless)
                    .help("Edit prompt")

                    Button {
                        onRemove(prompt.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.app(.caption2))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove prompt")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)

                if prompt.id != prompts.last?.id {
                    Divider().padding(.leading, 12)
                }
            }
        }
        .padding(.vertical, 4)
        .background(.ultraThinMaterial.opacity(0.5))
    }
}
