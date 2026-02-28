Feature: Card Reconciliation and Link Management
  As a developer with sessions started from various places
  I want Kanban to intelligently match sessions, worktrees, tmux sessions, and PRs to existing cards
  So that my board accurately represents the state of all work without duplicates

  Background:
    Given the Kanban application is running
    And the background reconciliation process is active

  # ── Core Reconciliation: Session → Card Matching ──

  Scenario: Discovered session matches existing card by sessionId
    Given a card exists with sessionLink.sessionId = "abc-123"
    When session discovery finds session "abc-123" with updated data
    Then the existing card's sessionLink should be updated (path, timestamps)
    And no new card should be created

  Scenario: Discovered session matches pending card via hook claim
    Given a card was just launched (has tmuxLink but no sessionLink, updated < 60s ago)
    When a SessionStart hook event fires with sessionId "new-session-uuid"
    And no other card already has sessionLink.sessionId = "new-session-uuid"
    Then the sessionLink should be added to the pending card
    And the card should now be fully linked (tmux + session)

  Scenario: Discovered session has no matching card
    Given no card has a sessionLink or tmuxLink matching the new session
    When session discovery finds a new session "xyz-789"
    Then a new card should be created with:
      | Field                  | Value        |
      | source                 | discovered   |
      | sessionLink.sessionId  | xyz-789      |
    And it should appear on the board

  Scenario: Manual create + start + discovery produces exactly one card
    Given I create a manual task "Fix login bug" with "Start immediately" checked
    Then exactly one card should exist for this task
    When the launch creates a tmux session
    Then the existing card should gain a tmuxLink
    When the SessionStart hook fires with the new Claude session UUID
    Then the existing card should gain a sessionLink
    When session discovery runs and finds the new session
    Then the session should match the existing card by sessionId
    And there should still be exactly one card (not 3!)

  # ── Worktree Matching ──

  Scenario: Session started with --worktree flag
    Given Claude was started with `claude --worktree feat-123`
    When the session .jsonl contains cwd pointing to a worktree path
    Then the card's worktreeLink should be set with the worktree path and branch

  Scenario: Orphan worktree creates a new card
    Given a worktree exists at ~/Projects/remote/repo/.claude/worktrees/feat-auth
    And no card has worktreeLink.branch matching "feat/auth"
    When the reconciler scans worktrees
    Then a new card should be created with:
      | Field                | Value              |
      | source               | discovered         |
      | worktreeLink.path    | .../feat-auth      |
      | worktreeLink.branch  | feat/auth          |
      | column               | requires_attention |
    And the card label should show "WORKTREE"

  Scenario: Skip bare and main branch worktrees
    Given the repo has a bare worktree and a main branch worktree
    When the reconciler scans worktrees
    Then no cards should be created for bare or main branch worktrees

  Scenario: Worktree already tracked by a card
    Given a card exists with worktreeLink.branch = "feat/login"
    When the reconciler finds a worktree with branch "feat/login"
    Then it should verify/update the worktreeLink.path if needed
    And not create a new card

  # ── PR Matching ──

  Scenario: PR linked by branch name
    Given a card has worktreeLink.branch = "feat/issue-123"
    And a PR exists with headRefName = "feat/issue-123"
    When the reconciler matches PRs
    Then a prLink should be added to the card with the PR number

  Scenario: PR discovery does not create new cards
    Given a PR exists for branch "feat/unknown"
    And no card has a worktreeLink matching that branch
    Then no new card should be created for the PR alone
    Because PRs are attached to existing cards, not standalone

  # ── GitHub Issue → Card Flow ──

  Scenario: GitHub issue creates a backlog card with issueLink
    Given a GitHub issue #123 "Fix login bug" is fetched
    And no card has issueLink.number = 123 for this project
    Then a new card should be created with:
      | Field              | Value        |
      | source             | github_issue |
      | column             | backlog      |
      | issueLink.number   | 123          |
      | issueLink.body     | (issue body) |
      | name               | #123: Fix login bug |

  Scenario: Starting work on issue card adds session + tmux + worktree
    Given a card with issueLink.number = 123 is in Backlog
    When I click "Start" and the launch completes
    Then the same card should gain:
      | Link         | Value                          |
      | tmuxLink     | sessionName = "issue-123"      |
      | sessionLink  | (from SessionStart hook claim) |
      | worktreeLink | (from Claude --worktree)       |
    And the card should move to In Progress
    And no second card should be created

  Scenario: Issue already started is not duplicated on re-fetch
    Given a card with issueLink.number = 123 also has a sessionLink
    When the next GitHub fetch returns issue #123 again
    Then the existing card should be kept as-is
    And no duplicate card should be created

  Scenario: Stale issue removed from backlog
    Given a card with issueLink.number = 123 is in Backlog (no sessionLink)
    When the GitHub fetch no longer returns issue #123
    Then the card should be removed from the board

  Scenario: Started issue not removed even if stale
    Given a card with issueLink.number = 123 also has a sessionLink
    When the GitHub fetch no longer returns issue #123
    Then the card should NOT be removed
    Because work has already started on it

  # ── Dead Link Cleanup ──

  Scenario: Tmux session dies
    Given a card has tmuxLink.sessionName = "feat-login"
    When "feat-login" is no longer in the live tmux session list
    Then tmuxLink should be set to nil
    But the card should remain with its other links intact

  Scenario: Worktree deleted from disk
    Given a card has worktreeLink.path = "/path/to/worktree"
    And the path no longer exists on disk
    When the reconciler runs
    Then worktreeLink should be set to nil
    Unless manualOverrides.worktreePath is true

  Scenario: Session .jsonl file temporarily unavailable
    Given a card has sessionLink.sessionPath pointing to a file
    And the file is temporarily inaccessible (e.g., remote mount down)
    When the reconciler runs
    Then the sessionLink should NOT be cleared
    Because sessions may be temporarily unavailable

  # ── Manual Override ──

  Scenario: User manually changes worktree link
    Given a card is linked to worktree "feat-login"
    When I change the worktreeLink to a different worktree
    Then manualOverrides.worktreePath should be set to true
    And the reconciler should not overwrite this manual link

  Scenario: Manual overrides survive re-linking
    Given a card has manualOverrides.worktreePath = true
    When the reconciler runs
    Then it should skip updating the worktreeLink
    And only update non-overridden links

  # ── Multiple Sessions per Branch ──

  Scenario: Two sessions linked to the same worktree branch
    Given I started a session in worktree "feat-login"
    And I later forked it, creating a second session in the same worktree
    Then both sessions should appear as separate cards
    And both should have worktreeLink.branch = "feat/login"
    And the PR should appear on both cards (same prLink.number)

  # ── Session Switching Worktrees ──

  Scenario: Session changes worktree
    Given a card has sessionLink and worktreeLink.branch = "feat-login"
    When the session's .jsonl shows cwd changed to a different worktree
    Then worktreeLink should update to the new worktree
    Unless manualOverrides.worktreePath is true

  # ── Performance ──

  Scenario: Reconciliation is lightweight
    Given 50 active sessions and 200 archived sessions
    When the reconciler runs
    Then it should complete in under 500ms
    And it should not block the UI thread
    And it should use indexed lookups (not O(n^2) scanning)

  Scenario: tmux session list is cached and refreshed
    Given the reconciler polls tmux sessions
    Then `tmux list-sessions` should be called at most every 5 seconds
    And the result should be cached between polls
