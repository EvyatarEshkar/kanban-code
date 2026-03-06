use crate::activity_detector::ActivityState;
use crate::coordination_store::Link;

/// Port of AssignColumn.swift.
/// Determines which Kanban column a link belongs in based on its current state.
/// Respects manual overrides — if the user dragged a card, keep it there.
pub fn assign_column(
    link: &Link,
    activity: Option<&ActivityState>,
    has_worktree: bool,
) -> String {
    let has_pr = !link.pr_links.is_empty();
    let all_prs_done = !link.pr_links.is_empty()
        && link
            .pr_links
            .iter()
            .all(|p| matches!(p.status.as_deref(), Some("MERGED") | Some("CLOSED")));

    // Actively working always wins — even overrides archive
    if activity == Some(&ActivityState::ActivelyWorking) {
        return "in_progress".to_string();
    }

    // Archived
    if link.manually_archived {
        return "all_sessions".to_string();
    }

    // All PRs merged/closed → done
    if all_prs_done {
        return "done".to_string();
    }

    // User manually dragged → respect it
    if link.manual_overrides.column {
        return link.column.clone();
    }

    // PR exists + session not actively working → in review
    if has_pr {
        if let Some(state) = activity {
            match state {
                ActivityState::NeedsAttention
                | ActivityState::IdleWaiting
                | ActivityState::Ended
                | ActivityState::Stale => return "in_review".to_string(),
                _ => {}
            }
        }
    }

    // Activity-based
    if let Some(state) = activity {
        match state {
            ActivityState::ActivelyWorking => return "in_progress".to_string(),
            ActivityState::NeedsAttention => return "requires_attention".to_string(),
            ActivityState::IdleWaiting => return "requires_attention".to_string(),
            ActivityState::Ended => {
                if has_worktree {
                    return "requires_attention".to_string();
                }
                // fall through to recency check
            }
            ActivityState::Stale => {
                // fall through to recency check
            }
        }
    }

    // GitHub issue without a session → backlog
    if link.source == "github_issue" && link.session_link.is_none() {
        return "backlog".to_string();
    }

    // Manual task without a session → backlog
    if link.source == "manual" && link.session_link.is_none() {
        return "backlog".to_string();
    }

    // Has an active worktree → at least waiting
    if has_worktree {
        return "requires_attention".to_string();
    }

    // Recently active (within 24h) → waiting
    if let Some(last) = link.last_activity {
        let hours = (chrono::Utc::now() - last).num_seconds() as f64 / 3600.0;
        if hours < 24.0 {
            return "requires_attention".to_string();
        }
    }

    // Default
    "all_sessions".to_string()
}

/// Apply column assignment to a link in-place, clearing archive flag if
/// the session just became actively working.
pub fn update_card_column(link: &mut Link, activity: Option<&ActivityState>, has_worktree: bool) {
    let new_col = assign_column(link, activity, has_worktree);

    // If an archived card becomes actively working, unarchive it
    if link.manually_archived && new_col == "in_progress" {
        link.manually_archived = false;
    }

    if new_col != link.column {
        link.column = new_col;
        link.updated_at = chrono::Utc::now();
    }
}
