import SwiftUI
import AppKit
import UserNotifications

@main
struct KanbanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 500)
        }
        .defaultSize(width: 1200, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Task") {
                    NotificationCenter.default.post(name: .kanbanNewTask, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            CommandGroup(after: .toolbar) {
                Button("Search Sessions") {
                    NotificationCenter.default.post(name: .kanbanToggleSearch, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
        }

        // Set app icon from bundled resource (SPM uses Bundle.module)
        if let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "icns", subdirectory: "Resources"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }

        // Request notification permissions
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }
}


enum AppearanceMode: String, CaseIterable {
    case auto, light, dark

    var next: AppearanceMode {
        switch self {
        case .auto: .dark
        case .dark: .light
        case .light: .auto
        }
    }

    var icon: String {
        switch self {
        case .auto: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    var helpText: String {
        switch self {
        case .auto: "Appearance: Auto (click for Dark)"
        case .dark: "Appearance: Dark (click for Light)"
        case .light: "Appearance: Light (click for Auto)"
        }
    }
}

extension Notification.Name {
    static let kanbanNewTask = Notification.Name("kanbanNewTask")
    static let kanbanToggleSearch = Notification.Name("kanbanToggleSearch")
    static let kanbanHookEvent = Notification.Name("kanbanHookEvent")
    static let kanbanHistoryChanged = Notification.Name("kanbanHistoryChanged")
    static let kanbanSettingsChanged = Notification.Name("kanbanSettingsChanged")
}
