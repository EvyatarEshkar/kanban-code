import Foundation

/// Parses tmux capture-pane output to detect coding assistant state.
public enum PaneOutputParser {

    /// Count image attachments visible in Claude Code's TUI.
    /// Only counts lines containing `[Image` that also have context like "to select" or "to remove",
    /// to avoid false positives from user-typed text.
    public static func countImages(in paneOutput: String) -> Int {
        // Count actual [Image #N] occurrences, not lines — multiple images can appear on one line
        var count = 0
        var searchRange = paneOutput.startIndex..<paneOutput.endIndex
        while let range = paneOutput.range(of: "[Image #", range: searchRange) {
            count += 1
            searchRange = range.upperBound..<paneOutput.endIndex
        }
        return count
    }

    /// Check if the assistant's input prompt is visible (ready for input).
    public static func isReady(_ paneOutput: String, assistant: CodingAssistant) -> Bool {
        paneOutput.contains(assistant.promptCharacter)
    }

    /// Backward-compatible: check if Claude Code's input prompt is visible.
    public static func isClaudeReady(_ paneOutput: String) -> Bool {
        isReady(paneOutput, assistant: .claude)
    }

    /// Check if Claude Code is actively working by looking for the status line
    /// (e.g. "✶ Brewing… (56s · ↓ 539 tokens)") in the bottom of pane output.
    /// tmux capture-pane includes Unicode control/color codes between the ellipsis
    /// and the parenthesis, so we just search for `…` (U+2026) in the tail.
    public static func isWorking(_ paneOutput: String) -> Bool {
        // Check last ~1000 chars — the status line can be 600+ chars from
        // the end due to the ──── border lines and footer in Claude's TUI.
        let tail = paneOutput.suffix(1000)
        return tail.contains("\u{2026}")
    }
}
