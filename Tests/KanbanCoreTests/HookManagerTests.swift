import Testing
import Foundation
@testable import KanbanCore

@Suite("HookManager")
struct HookManagerTests {
    func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "kanban-hooks-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test("Install hooks into empty settings")
    func installEmpty() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let settingsPath = (dir as NSString).appendingPathComponent("settings.json")
        let scriptPath = (dir as NSString).appendingPathComponent("hooks/kanban-hook.sh")
        try "{}".write(toFile: settingsPath, atomically: true, encoding: .utf8)

        try HookManager.install(claudeSettingsPath: settingsPath, hookScriptPath: scriptPath)

        let installed = HookManager.isInstalled(claudeSettingsPath: settingsPath)
        #expect(installed)

        // Verify all hook events are present
        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = root["hooks"] as! [String: Any]
        #expect(hooks["Stop"] != nil)
        #expect(hooks["Notification"] != nil)
        #expect(hooks["UserPromptSubmit"] != nil)
        #expect(hooks["SessionStart"] != nil)
        #expect(hooks["SessionEnd"] != nil)

        // Verify nested format: [{matcher: "", hooks: [{type, command}]}]
        let stopGroups = hooks["Stop"] as! [[String: Any]]
        #expect(stopGroups.count == 1)
        let entries = stopGroups[0]["hooks"] as! [[String: Any]]
        #expect(entries.count == 1)
        #expect((entries[0]["command"] as! String).contains("kanban-hook"))

        // Verify hook script was deployed
        #expect(FileManager.default.fileExists(atPath: scriptPath))
        #expect(FileManager.default.isExecutableFile(atPath: scriptPath))
    }

    @Test("Install preserves existing hooks in nested format")
    func installPreservesExisting() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let settingsPath = (dir as NSString).appendingPathComponent("settings.json")
        let scriptPath = (dir as NSString).appendingPathComponent("hooks/kanban-hook.sh")
        let existing = """
        {
            "hooks": {
                "Stop": [
                    {
                        "matcher": "",
                        "hooks": [
                            {"type": "command", "command": "/usr/local/bin/other-hook.sh"}
                        ]
                    }
                ]
            }
        }
        """
        try existing.write(toFile: settingsPath, atomically: true, encoding: .utf8)

        try HookManager.install(claudeSettingsPath: settingsPath, hookScriptPath: scriptPath)

        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = root["hooks"] as! [String: Any]
        let stopGroups = hooks["Stop"] as! [[String: Any]]

        // Should have one group with both hooks
        #expect(stopGroups.count == 1)
        let entries = stopGroups[0]["hooks"] as! [[String: Any]]
        #expect(entries.count == 2)
    }

    @Test("Install is idempotent")
    func installIdempotent() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let settingsPath = (dir as NSString).appendingPathComponent("settings.json")
        let scriptPath = (dir as NSString).appendingPathComponent("hooks/kanban-hook.sh")
        try "{}".write(toFile: settingsPath, atomically: true, encoding: .utf8)

        try HookManager.install(claudeSettingsPath: settingsPath, hookScriptPath: scriptPath)
        try HookManager.install(claudeSettingsPath: settingsPath, hookScriptPath: scriptPath)

        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = root["hooks"] as! [String: Any]
        let stopGroups = hooks["Stop"] as! [[String: Any]]
        let entries = stopGroups[0]["hooks"] as! [[String: Any]]

        // Should NOT have duplicates
        #expect(entries.count == 1)
    }

    @Test("Uninstall removes only kanban hooks")
    func uninstall() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let settingsPath = (dir as NSString).appendingPathComponent("settings.json")
        let existing = """
        {
            "hooks": {
                "Stop": [
                    {
                        "matcher": "",
                        "hooks": [
                            {"type": "command", "command": "/usr/local/bin/other-hook.sh"},
                            {"type": "command", "command": "/path/to/kanban-hook.sh"}
                        ]
                    }
                ]
            }
        }
        """
        try existing.write(toFile: settingsPath, atomically: true, encoding: .utf8)

        try HookManager.uninstall(claudeSettingsPath: settingsPath)

        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = root["hooks"] as! [String: Any]
        let stopGroups = hooks["Stop"] as! [[String: Any]]
        let entries = stopGroups[0]["hooks"] as! [[String: Any]]

        #expect(entries.count == 1)
        #expect((entries[0]["command"] as! String).contains("other-hook"))
    }

    @Test("isInstalled returns false for missing hooks")
    func notInstalled() {
        let installed = HookManager.isInstalled(claudeSettingsPath: "/nonexistent/path")
        #expect(!installed)
    }

    @Test("Install creates settings file if missing")
    func installCreatesFile() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let settingsPath = (dir as NSString).appendingPathComponent("subdir/settings.json")
        let scriptPath = (dir as NSString).appendingPathComponent("hooks/kanban-hook.sh")
        try HookManager.install(claudeSettingsPath: settingsPath, hookScriptPath: scriptPath)

        #expect(FileManager.default.fileExists(atPath: settingsPath))
        let installed = HookManager.isInstalled(claudeSettingsPath: settingsPath)
        #expect(installed)
    }

    @Test("Install deploys executable hook script")
    func installDeploysScript() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let settingsPath = (dir as NSString).appendingPathComponent("settings.json")
        let scriptPath = (dir as NSString).appendingPathComponent("hooks/kanban-hook.sh")
        try "{}".write(toFile: settingsPath, atomically: true, encoding: .utf8)

        try HookManager.install(claudeSettingsPath: settingsPath, hookScriptPath: scriptPath)

        // Script should exist and be executable
        #expect(FileManager.default.fileExists(atPath: scriptPath))
        #expect(FileManager.default.isExecutableFile(atPath: scriptPath))

        // Script should contain the shebang and event writing logic
        let content = try String(contentsOfFile: scriptPath, encoding: .utf8)
        #expect(content.contains("#!/usr/bin/env bash"))
        #expect(content.contains("hook-events.jsonl"))
        #expect(content.contains("session_id"))
    }
}
