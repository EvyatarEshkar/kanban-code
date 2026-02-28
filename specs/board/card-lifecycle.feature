Feature: Card Lifecycle and Automation
  As a developer using Kanban to manage Claude Code sessions
  I want cards to automatically move between columns based on their links and state
  So that my board always reflects the true state of work

  Background:
    Given the Kanban application is running
    And the background reconciliation process is active

  # ── Card Labels ──

  Scenario: Card label reflects the primary link type
    Given a card exists on the board
    Then the card should show a label based on which links are present:
      | Links present                    | Label     | Color  |
      | sessionLink (with or without others) | SESSION   | blue   |
      | worktreeLink only                | WORKTREE  | green  |
      | issueLink only                   | ISSUE     | orange |
      | prLink only                      | PR        | purple |
      | no typed links (manual task)     | TASK      | gray   |
    And the priority order is: SESSION > WORKTREE > ISSUE > PR > TASK

  Scenario: Card shows secondary link indicators
    Given a card has sessionLink AND prLink AND issueLink
    Then the primary label should be "SESSION" (blue)
    And small secondary icons should appear for PR and issue

  # ── Card Detail Header ──

  Scenario: Card detail shows link pills
    Given I select a card with sessionLink, tmuxLink, worktreeLink, prLink, and issueLink
    Then the detail header should show link pills for each:
      | Pill      | Icon                        | Label                |
      | Session   | terminal                    | #3 (session number)  |
      | Tmux      | rectangle.on.rectangle      | tmux                 |
      | Worktree  | arrow.triangle.branch       | feat/login           |
      | PR        | arrow.triangle.pull         | #456                 |
      | Issue     | exclamationmark.circle      | #123                 |

  Scenario: Card detail has dynamic tabs based on links
    Given a card's available links determine which tabs appear:
      | Links present     | Available tabs           |
      | tmuxLink          | Terminal                 |
      | sessionLink       | History                  |
      | issueLink         | Context (issue body)     |
      | promptBody        | Context (prompt text)    |
    And a card with all links has Terminal + History + Context tabs

  Scenario: Card with no session or tmux shows Context tab only
    Given a card has only an issueLink (backlog GitHub issue)
    Then the detail view should show a Context tab with the issue body
    And a "Start Work" button to begin a session

  # ── Backlog → In Progress ──

  Scenario: Starting a task from backlog via Kanban
    Given a task "Implement user auth" is in the Backlog column
    When I click the "Start" button on the card
    Then a launch confirmation dialog should appear with the prompt
    And on confirmation:
      | Step | Action                                              |
      | 1    | A tmux session should be created                    |
      | 2    | Claude Code should be launched with the prompt      |
      | 3    | The card gains a tmuxLink                           |
      | 4    | The card moves to "In Progress"                     |
      | 5    | SessionStart hook adds sessionLink to the same card |

  Scenario: Starting a GitHub issue from backlog
    Given a GitHub issue "#123: Fix login bug" is in the Backlog
    When I click "Start" on the card
    Then the launch confirmation dialog shows the prompt built from templates
    And on launch, the existing card (with issueLink) gains tmuxLink + sessionLink
    And the card moves to "In Progress" (no new card created)

  Scenario: Starting work on an orphan worktree
    Given an orphan worktree card (label "WORKTREE") is on the board
    When I click "Start Work"
    Then the launch confirmation dialog should appear
    And Claude should be launched in the existing worktree directory
    And no --worktree flag should be passed (worktree already exists)
    And the card gains tmuxLink + sessionLink while keeping worktreeLink

  Scenario: Task started externally appears in In Progress
    Given I started Claude Code from my terminal with `claude --worktree feat-123`
    When the background process detects the new session
    Then a new card should appear in "In Progress"
    And it should attempt to match to any backlog item by branch name

  # ── In Progress → Requires Attention ──

  Scenario: Claude asks for plan approval
    Given a Claude session is actively working in "In Progress"
    When Claude enters plan mode and waits for user input
    Then the card should move to "Requires Attention"
    And a push notification should be sent
    And the card should show "Waiting for plan approval" status

  Scenario: Claude thinks it's done
    Given a Claude session is actively working in "In Progress"
    When Claude's Stop hook fires and no new prompt follows within 1 second
    Then the card should move to "Requires Attention"
    And a push notification should be sent
    And the card should show "Task may be complete" status

  Scenario: Claude needs permission for a tool
    Given a Claude session is actively working
    When Claude triggers a Notification hook for permission request
    Then the card should move to "Requires Attention"
    And the notification should include the permission being requested

  Scenario: Anti-duplicate notifications
    Given a Claude session just triggered a Stop hook
    And a notification was sent
    When a Notification hook fires within 62 seconds for the same session
    Then no duplicate notification should be sent
    And the card should remain in "Requires Attention"

  # ── Requires Attention → In Progress ──

  Scenario: User responds to Claude from Kanban terminal
    Given a card is in "Requires Attention"
    When I open the card's terminal and send a message to Claude
    Then the card should move back to "In Progress"
    And the session activity timestamp should update

  Scenario: User responds from external terminal
    Given a card is in "Requires Attention"
    When I send a message to Claude from my own terminal
    And the UserPromptSubmit hook fires
    Then the card should move back to "In Progress"

  # ── In Progress → In Review ──

  Scenario: PR created while Claude is not actively working
    Given a Claude session created a PR on GitHub
    And the session has been idle for more than 5 minutes
    When the reconciler detects the PR via branch matching
    Then a prLink should be added to the card
    And the card should move to "In Review"
    And the PR number, title, and status should appear on the card

  Scenario: PR exists but Claude is still working
    Given a card has a prLink
    But the session is actively working (recent activity)
    Then the card should remain in "In Progress"
    And the PR badge should be visible on the card

  # ── In Review → In Progress (addressing feedback) ──

  Scenario: User asks Claude to address review comments
    Given a card is in "In Review" for PR #42
    When I open the terminal and ask Claude to address review feedback
    Then the card should move to "In Progress"
    And when Claude finishes, it should skip "Requires Attention"
    And move directly to "In Review"
    And a notification should still be sent when Claude stops

  # ── In Review → Done ──

  Scenario: PR is merged
    Given a card is in "In Review" for PR #42
    When the PR is merged on GitHub
    And the background process detects the merge via `gh`
    Then the card should move to "Done"

  Scenario: PR is closed without merge
    Given a card is in "In Review" for PR #42
    When the PR is closed without merging
    Then the card should move to "Done"
    And the card should show "Closed" status

  # ── Done → Cleanup ──

  Scenario: Cleaning up a worktree from Done
    Given a card is in "Done" with a worktreeLink
    Then a "Clean up worktree" button should be visible
    When I click it
    Then a confirmation dialog should appear
    And on confirm:
      | Step | Action                                    |
      | 1    | Kill associated tmux session if exists     |
      | 2    | Remove the git worktree                   |
      | 3    | Clear worktreeLink and tmuxLink on card    |
    And the card should move to "All Sessions"

  Scenario: Done card without worktree moves to archive directly
    Given a card is in "Done" without a worktreeLink
    When I click "Archive"
    Then the card should move to "All Sessions"

  # ── All Sessions → In Progress (reviving) ──

  Scenario: Resuming a session from All Sessions
    Given a card with a sessionLink is in "All Sessions"
    When I click "Resume"
    Then a tmux session should be created (tmuxLink added)
    And Claude should be resumed with `claude --resume <sessionId>`
    And the card should move to "In Progress"

  Scenario: Forking a session from All Sessions
    Given a card is in "All Sessions"
    When I click "Fork"
    Then the session .jsonl should be duplicated with a new UUID
    And a new card should appear (new KSUID id, new sessionLink)
    And the original card should remain in "All Sessions"

  # ── Session Staleness ──

  Scenario: Active session without worktree or tmux
    Given a session is less than 24 hours old (configurable)
    And it has no worktreeLink or tmuxLink
    Then it should remain in its current column
    And not be auto-archived

  Scenario: Stale session auto-archives
    Given a session has been idle for more than 24 hours (configurable)
    And it has no worktreeLink or tmuxLink
    And it is not in "Backlog"
    Then it should automatically move to "All Sessions"

  Scenario: Manually archiving an active session
    Given a session is in "In Progress"
    When I drag it to "All Sessions"
    Then the card should move to "All Sessions"
    And the card should be marked as manually archived
    And it should not auto-return to "In Progress" based on age alone
