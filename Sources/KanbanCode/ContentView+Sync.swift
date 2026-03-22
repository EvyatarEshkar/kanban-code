import SwiftUI
import KanbanCodeCore

// MARK: - Sync Status (Mutagen)

extension ContentView {
    func abbreviateHomePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    @ViewBuilder
    var syncStatusView: some View {
        Button { showSyncPopover.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: syncStatusIcon(currentSyncStatus))
                    .foregroundStyle(currentSyncStatus == .watching ? .primary : syncStatusColor(currentSyncStatus))
                if !isExpandedDetail {
                    Text(syncStatusLabel(currentSyncStatus))
                        .font(.app(.headline))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, isExpandedDetail ? 12 : 8)
        }
        .buttonStyle(.plain)
        .help(syncStatusLabel(currentSyncStatus))
        .task(id: currentSyncStatus) {
            await refreshSyncStatus()
            let interval: Duration = currentSyncStatus == .staging ? .seconds(1) : .seconds(10)
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await refreshSyncStatus()
            }
        }
        .popover(isPresented: $showSyncPopover) {
            syncStatusPopover
        }
        .onChange(of: currentSyncStatus) {
            if showSyncPopover {
                showSyncPopover = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    showSyncPopover = true
                }
            }
        }
    }

    @ViewBuilder
    var syncStatusPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("File sync for remote Claude Code sessions, configured in Settings > Remote.")
                .font(.app(.callout))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Image(systemName: syncStatusIcon(currentSyncStatus))
                    .foregroundStyle(syncStatusColor(currentSyncStatus))
                Text(syncStatusLabel(currentSyncStatus))
                    .font(.app(.callout))
            }

            ScrollView {
                Text(rawSyncOutput)
                    .font(.app(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .id(rawSyncOutput.count)
            .frame(maxHeight: 250)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 4) {
                Text("mutagen sync list -l")
                    .font(.app(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("mutagen sync list -l", forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.app(.caption))
                }
                .buttonStyle(.borderless)
                .help("Copy command")
            }

            HStack {
                Button {
                    Task {
                        isSyncRefreshing = true
                        try? await mutagenAdapter.flushSync()
                        await refreshSyncStatus()
                    }
                } label: {
                    Label("Flush", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isSyncRefreshing)

                if currentSyncStatus == .notRunning {
                    Button {
                        Task {
                            isSyncRefreshing = true
                            if let remote = store.state.globalRemoteSettings {
                                let syncName = "kanban-code-sync"
                                let remoteDest = "\(remote.host):\(remote.remotePath)"
                                let ignores = remote.syncIgnores ?? MutagenAdapter.defaultIgnores
                                try? await mutagenAdapter.startSync(
                                    localPath: remote.localPath,
                                    remotePath: remoteDest,
                                    name: syncName,
                                    ignores: ignores
                                )
                            }
                            await refreshSyncStatus()
                        }
                    } label: {
                        Label("Start", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isSyncRefreshing)
                }

                if currentSyncStatus == .error || currentSyncStatus == .paused {
                    Button {
                        Task {
                            isSyncRefreshing = true
                            for name in syncStatuses.keys {
                                try? await mutagenAdapter.resetSync(name: name)
                            }
                            await refreshSyncStatus()
                        }
                    } label: {
                        Label("Restart", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isSyncRefreshing)
                }

                if !syncStatuses.isEmpty {
                    Button {
                        Task {
                            isSyncRefreshing = true
                            for name in syncStatuses.keys {
                                try? await mutagenAdapter.stopSync(name: name)
                            }
                            await refreshSyncStatus()
                        }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isSyncRefreshing)
                }

                Spacer()

                Button {
                    Task { await refreshSyncStatus() }
                } label: {
                    if isSyncRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isSyncRefreshing)
                .help("Refresh status")
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    func refreshSyncStatus() async {
        guard await mutagenAdapter.isAvailable() else {
            syncStatuses = [:]
            rawSyncOutput = "Mutagen is not installed."
            return
        }
        isSyncRefreshing = true
        defer { isSyncRefreshing = false }
        syncStatuses = (try? await mutagenAdapter.status()) ?? [:]
        rawSyncOutput = (try? await mutagenAdapter.rawStatus()) ?? "Failed to fetch status."
    }

    func syncStatusIcon(_ status: SyncStatus) -> String {
        switch status {
        case .watching: "checkmark.circle.fill"
        case .staging: "arrow.triangle.2.circlepath"
        case .conflicts: "exclamationmark.triangle.fill"
        case .paused: "pause.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .notRunning: "circle.dashed"
        }
    }

    func syncStatusColor(_ status: SyncStatus) -> Color {
        switch status {
        case .watching: .green
        case .staging: .secondary
        case .conflicts: .yellow
        case .paused: .yellow
        case .error: .red
        case .notRunning: .secondary
        }
    }

    func syncStatusLabel(_ status: SyncStatus) -> String {
        switch status {
        case .watching: "Files in Sync"
        case .staging: "Syncing Files…"
        case .conflicts: "Conflicts Detected"
        case .paused: "Sync Paused"
        case .error: "Sync Error"
        case .notRunning: "Sync Not Running"
        }
    }
}
