import SwiftUI
import AppKit
import KanbanCore

/// Manages the menu bar status item (system tray).
/// Shows clawd icon when Claude sessions are actively working.
/// Spawns a separate "clawd" helper process so Amphetamine can detect it.
@MainActor
final class SystemTray: @unchecked Sendable {
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private weak var boardState: BoardState?
    private var clawdProcess: Process?
    /// Time when In Progress last had sessions (for linger timeout).
    private var lastActiveTime: Date?
    /// How long to keep tray visible after last active session (seconds).
    var lingerTimeout: TimeInterval = 60

    func setup(boardState: BoardState) {
        self.boardState = boardState
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Build icon with 1x + 2x representations for crisp rendering at 22x22pt
        // (same approach as cc-amphetamine's Electron nativeImage)
        let icon = NSImage(size: NSSize(width: 22, height: 22))
        var hasReps = false

        if let url = Bundle.module.url(forResource: "clawd", withExtension: "png", subdirectory: "Resources"),
           let rep = NSImageRep(contentsOf: url) {
            rep.size = NSSize(width: 22, height: 22)
            icon.addRepresentation(rep)
            hasReps = true
        }
        if let url = Bundle.module.url(forResource: "clawd@2x", withExtension: "png", subdirectory: "Resources"),
           let rep = NSImageRep(contentsOf: url) {
            rep.size = NSSize(width: 22, height: 22) // same logical size; 44px used on retina
            icon.addRepresentation(rep)
            hasReps = true
        }

        if hasReps {
            icon.isTemplate = true
            statusItem?.button?.image = icon
        } else {
            statusItem?.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "Kanban")
        }

        updateMenu()
        updateVisibility()
    }

    func update() {
        updateMenu()
        updateVisibility()
    }

    private func updateMenu() {
        let menu = NSMenu()

        if let state = boardState {
            let activeCards = state.cards(in: .inProgress)
            let attentionCards = state.cards(in: .requiresAttention)

            if !activeCards.isEmpty {
                menu.addItem(NSMenuItem.sectionHeader(title: "In Progress"))
                for card in activeCards.prefix(5) {
                    let item = NSMenuItem(title: card.displayTitle, action: nil, keyEquivalent: "")
                    if card.isActivelyWorking {
                        item.image = NSImage(systemSymbolName: "gear.circle.fill", accessibilityDescription: nil)
                    } else {
                        item.image = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: nil)
                    }
                    menu.addItem(item)
                }
            }

            if !attentionCards.isEmpty {
                menu.addItem(NSMenuItem.separator())
                menu.addItem(NSMenuItem.sectionHeader(title: "Requires Attention"))
                for card in attentionCards.prefix(5) {
                    let item = NSMenuItem(title: card.displayTitle, action: nil, keyEquivalent: "")
                    item.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil)
                    menu.addItem(item)
                }
            }

            if activeCards.isEmpty && attentionCards.isEmpty {
                let item = NSMenuItem(title: "No active sessions", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())

        let openItem = NSMenuItem(title: "Open Kanban", action: #selector(openMainWindow), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem?.menu = menu
        self.menu = menu
    }

    @objc func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }

    /// Show tray icon when there are In Progress sessions, or within linger timeout.
    /// Also manages the "clawd" helper process for Amphetamine integration.
    private func updateVisibility() {
        guard let state = boardState else { return }
        let hasActive = state.cardCount(in: .inProgress) > 0

        if hasActive {
            lastActiveTime = Date()
            statusItem?.isVisible = true
            startClawdIfNeeded()
        } else if let lastActive = lastActiveTime,
                  Date().timeIntervalSince(lastActive) < lingerTimeout {
            // Linger: keep visible for a bit after last active session
            statusItem?.isVisible = true
            // Keep clawd running during linger
        } else {
            statusItem?.isVisible = false
            stopClawd()
        }
    }

    // MARK: - Clawd helper process (for Amphetamine)

    /// Spawns the "clawd" helper so Amphetamine can detect it.
    private func startClawdIfNeeded() {
        // Already running?
        if let proc = clawdProcess, proc.isRunning { return }

        // Find clawd binary next to the Kanban binary
        let clawdPath = Self.findClawdBinary()
        guard let path = clawdPath else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.qualityOfService = .background
        do {
            try proc.run()
            clawdProcess = proc
        } catch {
            // Best-effort — Amphetamine integration is optional
        }
    }

    /// Kill the clawd helper when no more active sessions.
    private func stopClawd() {
        guard let proc = clawdProcess, proc.isRunning else {
            clawdProcess = nil
            return
        }
        proc.terminate()
        clawdProcess = nil
    }

    /// Find the clawd binary relative to the running Kanban binary.
    private static func findClawdBinary() -> String? {
        // In a Swift Package build, both binaries are in the same .build/debug/ directory
        let kanbanPath = ProcessInfo.processInfo.arguments[0]
        let dir = (kanbanPath as NSString).deletingLastPathComponent
        let clawdPath = (dir as NSString).appendingPathComponent("clawd")
        if FileManager.default.isExecutableFile(atPath: clawdPath) {
            return clawdPath
        }
        // Also check ~/.kanban/bin/clawd for installed locations
        let installedPath = (NSHomeDirectory() as NSString).appendingPathComponent(".kanban/bin/clawd")
        if FileManager.default.isExecutableFile(atPath: installedPath) {
            return installedPath
        }
        return nil
    }
}
