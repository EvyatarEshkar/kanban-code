import Foundation

/// Manages Claude Code hook installation for Kanban.
public enum HookManager {

    /// The hook events we need to listen to.
    static let requiredHooks = [
        "Stop", "Notification", "SessionStart", "SessionEnd", "UserPromptSubmit",
    ]

    /// Check if hooks are already installed.
    /// Handles Claude Code's nested format: {matcher: "", hooks: [{type, command}]}
    public static func isInstalled(claudeSettingsPath: String? = nil) -> Bool {
        let path = claudeSettingsPath ?? defaultSettingsPath()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else {
            return false
        }

        return requiredHooks.allSatisfy { eventName in
            guard let groups = hooks[eventName] as? [[String: Any]] else { return false }
            return groups.contains { group in
                guard let hookEntries = group["hooks"] as? [[String: Any]] else { return false }
                return hookEntries.contains { entry in
                    (entry["command"] as? String)?.contains("kanban-hook") == true
                }
            }
        }
    }

    /// Install hooks: deploys the hook script and updates Claude's settings.
    /// Uses Claude Code's nested format: [{matcher: "", hooks: [{type, command}]}]
    public static func install(
        claudeSettingsPath: String? = nil,
        hookScriptPath: String? = nil
    ) throws {
        let settingsPath = claudeSettingsPath ?? defaultSettingsPath()
        let scriptPath = hookScriptPath ?? defaultHookScriptPath()

        // Step 1: Deploy the hook script to disk
        try deployHookScript(to: scriptPath)

        // Read existing settings
        var root: [String: Any]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
        } else {
            root = [:]
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]

        let hookEntry: [String: Any] = [
            "type": "command",
            "command": scriptPath,
        ]

        for eventName in requiredHooks {
            var groups = hooks[eventName] as? [[String: Any]] ?? []

            // Check if kanban-hook already exists in any group
            let alreadyInstalled = groups.contains { group in
                guard let entries = group["hooks"] as? [[String: Any]] else { return false }
                return entries.contains { ($0["command"] as? String)?.contains("kanban-hook") == true }
            }

            if !alreadyInstalled {
                if groups.isEmpty {
                    // No existing hooks for this event — create new group
                    groups.append(["matcher": "", "hooks": [hookEntry]])
                } else {
                    // Add to the first group's hooks array
                    var firstGroup = groups[0]
                    var entries = firstGroup["hooks"] as? [[String: Any]] ?? []
                    entries.append(hookEntry)
                    firstGroup["hooks"] = entries
                    groups[0] = firstGroup
                }
            }

            hooks[eventName] = groups
        }

        root["hooks"] = hooks

        // Write back
        let fileManager = FileManager.default
        let dir = (settingsPath as NSString).deletingLastPathComponent
        try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: settingsPath))
    }

    /// Remove Kanban hooks from settings.
    public static func uninstall(claudeSettingsPath: String? = nil) throws {
        let settingsPath = claudeSettingsPath ?? defaultSettingsPath()

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = root["hooks"] as? [String: Any] else {
            return
        }

        for eventName in requiredHooks {
            if var groups = hooks[eventName] as? [[String: Any]] {
                // Remove kanban-hook entries from each group
                for i in groups.indices {
                    if var entries = groups[i]["hooks"] as? [[String: Any]] {
                        entries.removeAll { ($0["command"] as? String)?.contains("kanban-hook") == true }
                        groups[i]["hooks"] = entries
                    }
                }
                // Remove groups that have no hooks left
                groups.removeAll { group in
                    guard let entries = group["hooks"] as? [[String: Any]] else { return true }
                    return entries.isEmpty
                }
                if groups.isEmpty {
                    hooks.removeValue(forKey: eventName)
                } else {
                    hooks[eventName] = groups
                }
            }
        }

        root["hooks"] = hooks

        let newData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try newData.write(to: URL(fileURLWithPath: settingsPath))
    }

    /// Deploy the hook script to the target path, creating directories as needed.
    private static func deployHookScript(to path: String) throws {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Write script (overwrites if exists — ensures latest version)
        try hookScriptContent.write(toFile: path, atomically: true, encoding: .utf8)

        // Make executable (755)
        try fm.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: path
        )
    }

    private static let hookScriptContent = """
    #!/usr/bin/env bash
    # Kanban hook handler for Claude Code.
    # Receives JSON on stdin from Claude hooks, appends a timestamped
    # event line to ~/.kanban/hook-events.jsonl.

    set -euo pipefail

    EVENTS_DIR="${HOME}/.kanban"
    EVENTS_FILE="${EVENTS_DIR}/hook-events.jsonl"

    # Ensure directory exists
    mkdir -p "$EVENTS_DIR"

    # Read the JSON payload from stdin
    input=$(cat)

    # Extract fields using lightweight parsing (no jq dependency)
    session_id=$(echo "$input" | grep -o '"session_id":"[^"]*"' | head -1 | cut -d'"' -f4)
    hook_event=$(echo "$input" | grep -o '"hook_event_name":"[^"]*"' | head -1 | cut -d'"' -f4)
    transcript=$(echo "$input" | grep -o '"transcript_path":"[^"]*"' | head -1 | cut -d'"' -f4)

    # Fallback: try sessionId (different hook formats)
    if [ -z "$session_id" ]; then
        session_id=$(echo "$input" | grep -o '"sessionId":"[^"]*"' | head -1 | cut -d'"' -f4)
    fi

    # Skip if we couldn't extract a session ID
    [ -z "$session_id" ] && exit 0

    # Get current timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Append event line
    printf '{\"sessionId\":\"%s\",\"event\":\"%s\",\"timestamp\":\"%s\",\"transcriptPath\":\"%s\"}\\n' \\
        "$session_id" "$hook_event" "$timestamp" "$transcript" >> "$EVENTS_FILE"
    """

    private static func defaultSettingsPath() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude/settings.json")
    }

    private static func defaultHookScriptPath() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".kanban/hooks/kanban-hook.sh")
    }
}
