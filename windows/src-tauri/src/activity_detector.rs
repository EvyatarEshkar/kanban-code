use std::time::{Duration, SystemTime};

/// Mirrors the macOS ActivityState enum exactly.
/// Without hook events we approximate from JSONL mtime — good enough for WSL.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ActivityState {
    /// Claude is actively writing/running tools right now (mtime < 30s)
    ActivelyWorking,
    /// Claude stopped and is waiting for the user to respond (30s–5min)
    NeedsAttention,
    /// Claude is idle, session still open (5min–24h)
    IdleWaiting,
    /// Session ended cleanly (24h–7d)
    Ended,
    /// Very stale — no hook data, file old (> 7d)
    Stale,
}

use serde::Serialize;

impl ActivityState {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::ActivelyWorking => "activelyWorking",
            Self::NeedsAttention => "needsAttention",
            Self::IdleWaiting => "idleWaiting",
            Self::Ended => "ended",
            Self::Stale => "stale",
        }
    }
}

/// Detect session activity from JSONL mtime.
///
/// WSL note: the JSONL file may live under /mnt/c/… (Windows FS).
/// Windows filesystem timestamps are accurate to 100ns so mtime works fine.
///
/// Thresholds mirror what the macOS hook-based detector produces in practice:
///   < 30s   → actively working
///   < 5min  → needs attention (Claude just finished, waiting for user)
///   < 24h   → idle waiting
///   < 7d    → ended
///   else    → stale
pub fn detect_activity(jsonl_path: &str) -> ActivityState {
    let mtime = std::fs::metadata(jsonl_path)
        .and_then(|m| m.modified())
        .unwrap_or(SystemTime::UNIX_EPOCH);

    let elapsed = SystemTime::now()
        .duration_since(mtime)
        .unwrap_or(Duration::MAX);

    if elapsed < Duration::from_secs(30) {
        ActivityState::ActivelyWorking
    } else if elapsed < Duration::from_secs(5 * 60) {
        ActivityState::NeedsAttention
    } else if elapsed < Duration::from_secs(24 * 60 * 60) {
        ActivityState::IdleWaiting
    } else if elapsed < Duration::from_secs(7 * 24 * 60 * 60) {
        ActivityState::Ended
    } else {
        ActivityState::Stale
    }
}
