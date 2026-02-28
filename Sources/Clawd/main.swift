import Foundation

// Tiny helper process that shows up as "clawd" in Activity Monitor.
// Kanban spawns this when Claude sessions are actively working.
// Amphetamine can be configured to detect this process to prevent sleep.
// Exits when it receives SIGTERM or SIGINT.

signal(SIGTERM, SIG_DFL)
signal(SIGINT, SIG_DFL)

dispatchMain()
