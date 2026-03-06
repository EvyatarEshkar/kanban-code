import Foundation

/// Errors from image sending operations.
public enum ImageSendError: Error, LocalizedError {
    case claudeNotReady
    case imageUploadTimeout(expected: Int)

    public var errorDescription: String? {
        switch self {
        case .claudeNotReady:
            "Claude Code did not become ready within the timeout period"
        case .imageUploadTimeout(let n):
            "Timed out waiting for image #\(n) to be accepted by Claude Code"
        }
    }
}

/// Orchestrates sending images to a Claude Code session via tmux.
///
/// For each image:
/// 1. Sets the system clipboard to the image data (via injected closure)
/// 2. Sends an empty bracketed paste event to the tmux session
/// 3. Polls `tmux capture-pane` until Claude confirms the image with `[Image #N]`
public actor ImageSender {
    private let tmux: TmuxManagerPort

    public init(tmux: TmuxManagerPort) {
        self.tmux = tmux
    }

    /// Wait for Claude Code to show its input prompt (❯).
    public func waitForReady(
        sessionName: String,
        pollInterval: Duration = .milliseconds(500),
        timeout: Duration = .seconds(30)
    ) async throws {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < timeout {
            let output = try await tmux.capturePane(sessionName: sessionName)
            if PaneOutputParser.isClaudeReady(output) { return }
            try await Task.sleep(for: pollInterval)
        }
        throw ImageSendError.claudeNotReady
    }

    /// Send images one by one, confirming each before sending the next.
    ///
    /// - Parameters:
    ///   - sessionName: tmux session target
    ///   - images: images to send
    ///   - setClipboard: closure that sets the system clipboard to image data (injected for testability)
    ///   - pollInterval: how often to check for confirmation
    ///   - timeout: max time to wait per image
    public func sendImages(
        sessionName: String,
        images: [ImageAttachment],
        setClipboard: @Sendable (Data) -> Void,
        pollInterval: Duration = .milliseconds(500),
        timeout: Duration = .seconds(30)
    ) async throws {
        for (index, image) in images.enumerated() {
            // Count before sending
            let before = try await tmux.capturePane(sessionName: sessionName)
            let countBefore = PaneOutputParser.countImages(in: before)

            setClipboard(image.data)
            try await tmux.sendBracketedPaste(to: sessionName)

            // Poll until count goes up
            let start = ContinuousClock.now
            while ContinuousClock.now - start < timeout {
                try await Task.sleep(for: pollInterval)
                let output = try await tmux.capturePane(sessionName: sessionName)
                if PaneOutputParser.countImages(in: output) > countBefore {
                    break
                }
                if ContinuousClock.now - start >= timeout {
                    throw ImageSendError.imageUploadTimeout(expected: index + 1)
                }
            }
        }
    }
}
