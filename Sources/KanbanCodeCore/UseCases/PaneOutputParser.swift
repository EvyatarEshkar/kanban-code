import Foundation

/// Parses tmux capture-pane output to detect Claude Code state.
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

    /// Check if Claude Code's input prompt is visible (ready for input).
    public static func isClaudeReady(_ paneOutput: String) -> Bool {
        paneOutput.contains("❯")
    }
}
