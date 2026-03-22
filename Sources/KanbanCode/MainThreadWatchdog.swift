import Foundation
import QuartzCore
import os

/// Detects main thread hangs by pinging from a background thread.
/// Logs any hang > threshold to ~/.kanban-code/logs/main-thread-hangs.log
/// Dormant by default — call start() to enable. In release builds,
/// only starts when KANBAN_WATCHDOG=1 environment variable is set.
final class MainThreadWatchdog: @unchecked Sendable {
    static let shared = MainThreadWatchdog()

    private let checkInterval: TimeInterval = 0.016  // 16ms (1 frame at 60fps)
    private let hangThreshold: TimeInterval = 0.032   // 32ms — 2 dropped frames
    private let _isRunning = os.OSAllocatedUnfairLock(initialState: false)
    private let logPath: String
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()

    private init() {
        let logsDir = (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code/logs")
        try? FileManager.default.createDirectory(atPath: logsDir, withIntermediateDirectories: true)
        logPath = (logsDir as NSString).appendingPathComponent("main-thread-hangs.log")
        // Clear previous log on init
        try? "".write(toFile: logPath, atomically: true, encoding: .utf8)
    }

    func start() {
        #if !DEBUG
        // In release builds, only run if explicitly opted in
        guard ProcessInfo.processInfo.environment["KANBAN_WATCHDOG"] == "1" else { return }
        #endif

        let alreadyRunning = _isRunning.withLock { val -> Bool in
            if val { return true }
            val = true
            return false
        }
        guard !alreadyRunning else { return }

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self else { return }

            while self._isRunning.withLock({ $0 }) {
                let semaphore = DispatchSemaphore(value: 0)
                let pingTime = CACurrentMediaTime()

                DispatchQueue.main.async {
                    semaphore.signal()
                }

                let result = semaphore.wait(timeout: .now() + 0.5)
                let elapsed = CACurrentMediaTime() - pingTime

                if result == .timedOut {
                    self.log(String(format: "HANG: main thread blocked for >500ms at %.3f", pingTime))
                } else if elapsed > self.hangThreshold {
                    self.log(String(format: "HITCH: main thread blocked for %.1fms at %.3f", elapsed * 1000, pingTime))
                }

                Thread.sleep(forTimeInterval: self.checkInterval)
            }
        }
    }

    func stop() {
        _isRunning.withLock { $0 = false }
    }

    private func log(_ message: String) {
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if let fh = FileHandle(forWritingAtPath: logPath) {
                fh.seekToEndOfFile()
                fh.write(data)
                try? fh.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: logPath))
            }
        }
    }
}
