import SwiftUI
import KanbanCore

struct NewTaskDialog: View {
    @Binding var isPresented: Bool
    var projects: [Project] = []
    var defaultProjectPath: String?
    var onCreate: (String, String?, Bool) -> Void = { _, _, _ in }

    @State private var prompt = ""
    @State private var selectedProjectPath: String = ""
    @State private var customPath = ""
    @AppStorage("startTaskImmediately") private var startImmediately = true

    private static let customPathSentinel = "__custom__"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Task")
                .font(.title3)
                .fontWeight(.semibold)

            TextEditor(text: $prompt)
                .font(.body.monospaced())
                .frame(minHeight: 80, maxHeight: 200)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text("Describe what you want Claude to do...")
                            .font(.body.monospaced())
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }

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

            Toggle("Start immediately", isOn: $startImmediately)
                .font(.callout)

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button(startImmediately ? "Create & Start" : "Create") {
                    let proj = resolvedProjectPath
                    onCreate(prompt, proj, startImmediately)
                    isPresented = false
                }
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
        }
    }

    private var resolvedProjectPath: String? {
        if projects.isEmpty {
            return customPath.isEmpty ? nil : customPath
        }
        if selectedProjectPath == Self.customPathSentinel {
            return customPath.isEmpty ? nil : customPath
        }
        return selectedProjectPath.isEmpty ? nil : selectedProjectPath
    }
}
