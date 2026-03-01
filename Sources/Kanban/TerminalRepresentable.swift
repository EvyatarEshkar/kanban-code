import SwiftUI
import AppKit
import SwiftTerm

// MARK: - Terminal process cache

/// Caches tmux terminal views across drawer close/open cycles.
/// When the drawer closes, terminals are detached from the view hierarchy but kept alive.
/// When reopened, the cached terminal is reparented — no new tmux attach needed,
/// preserving scrollback and terminal state.
@MainActor
final class TerminalCache {
    static let shared = TerminalCache()
    private var terminals: [String: LocalProcessTerminalView] = [:]

    /// Get or create a terminal for the given tmux session name.
    func terminal(for sessionName: String, frame: NSRect) -> LocalProcessTerminalView {
        if let existing = terminals[sessionName] {
            return existing
        }
        let terminal = LocalProcessTerminalView(frame: frame)
        terminal.caretColor = .systemGreen
        terminal.autoresizingMask = [.width, .height]
        terminal.isHidden = true
        terminal.startProcess(
            executable: "/opt/homebrew/bin/tmux",
            args: ["attach-session", "-t", sessionName],
            environment: nil,
            execName: nil,
            currentDirectory: nil
        )
        terminals[sessionName] = terminal
        return terminal
    }

    /// Remove and terminate a specific terminal (e.g., when user kills a session).
    func remove(_ sessionName: String) {
        if let terminal = terminals.removeValue(forKey: sessionName) {
            terminal.removeFromSuperview()
            terminal.terminate()
        }
    }

    /// Check if a terminal exists for this session.
    func has(_ sessionName: String) -> Bool {
        terminals[sessionName] != nil
    }
}

// MARK: - Multi-terminal container (manages all terminals for a card)

/// A single NSViewRepresentable that manages multiple tmux terminal subviews.
/// Uses TerminalCache to persist terminals across drawer close/open cycles.
/// Terminals are created once globally and reparented as needed — never destroyed
/// just because the drawer was toggled.
struct TerminalContainerView: NSViewRepresentable {
    /// All tmux session names to show tabs for.
    let sessions: [String]
    /// Which session is currently visible.
    let activeSession: String

    func makeNSView(context: Context) -> TerminalContainerNSView {
        let container = TerminalContainerNSView()
        for session in sessions {
            container.ensureTerminal(for: session)
        }
        container.showTerminal(for: activeSession)
        return container
    }

    func updateNSView(_ nsView: TerminalContainerNSView, context: Context) {
        // Add any new sessions (idempotent — reuses cached terminals)
        for session in sessions {
            nsView.ensureTerminal(for: session)
        }
        // Remove terminals that are no longer in the list
        nsView.removeTerminalsNotIn(Set(sessions))
        // Switch visible terminal
        nsView.showTerminal(for: activeSession)
    }

    static func dismantleNSView(_ nsView: TerminalContainerNSView, coordinator: ()) {
        // Detach terminals from this container but do NOT terminate them.
        // They live on in TerminalCache and will be reparented when the drawer reopens.
        nsView.detachAll()
    }
}

/// AppKit container that owns multiple LocalProcessTerminalView instances.
/// Uses TerminalCache for process lifecycle — terminal processes survive view teardown.
final class TerminalContainerNSView: NSView {
    /// Ordered list of session names managed by this container.
    private var managedSessions: [String] = []
    private var activeSession: String?

    /// Ensure a terminal for `sessionName` is attached to this container.
    func ensureTerminal(for sessionName: String) {
        guard !managedSessions.contains(sessionName) else { return }
        let terminal = TerminalCache.shared.terminal(for: sessionName, frame: bounds)
        // Reparent: remove from any previous superview and add to this container
        if terminal.superview !== self {
            terminal.removeFromSuperview()
            addSubview(terminal)
        }
        terminal.frame = bounds
        terminal.isHidden = true
        managedSessions.append(sessionName)
    }

    /// Show only the terminal for `sessionName`, hide all others.
    func showTerminal(for sessionName: String) {
        guard activeSession != sessionName else { return }
        activeSession = sessionName
        for name in managedSessions {
            let terminal = TerminalCache.shared.terminal(for: name, frame: bounds)
            terminal.isHidden = (name != sessionName)
        }
    }

    /// Remove terminals whose session names are not in `keep`.
    /// This is called when sessions are killed — terminals are fully terminated.
    func removeTerminalsNotIn(_ keep: Set<String>) {
        let toRemove = managedSessions.filter { !keep.contains($0) }
        for name in toRemove {
            TerminalCache.shared.remove(name)
            managedSessions.removeAll { $0 == name }
        }
    }

    /// Detach all terminals from this container without terminating them.
    /// Called when the drawer closes — terminals survive in TerminalCache.
    func detachAll() {
        for sub in subviews {
            sub.removeFromSuperview()
        }
        managedSessions.removeAll()
        activeSession = nil
    }

    override func layout() {
        super.layout()
        for sub in subviews {
            sub.frame = bounds
        }
    }
}
