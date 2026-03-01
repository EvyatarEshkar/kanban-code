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

  # ── PR Matching (Multi-PR) ──
  #
  # A card can have multiple PRs (prLinks array).
  # PRs are discovered from worktreeLink.branch AND discoveredBranches.

  Scenario: PR linked by worktree branch name
    Given a card has worktreeLink.branch = "feat/issue-123"
    And a PR exists with headRefName = "feat/issue-123"
    When the reconciler matches PRs
    Then a PRLink should be appended to the card's prLinks array

  Scenario: Multiple PRs linked from discovered branches
    Given a card has discoveredBranches = ["feat/trace-discovery", "feat/custom-config"]
    And PRs exist for both branches (#240 and #242)
    When the orchestrator syncs PR data
    Then prLinks should contain both PRs
    And each should have status, title, and check runs populated

  Scenario: PR discovery does not create new cards
    Given a PR exists for branch "feat/unknown"
    And no card has a worktreeLink or discoveredBranch matching that branch
    Then no new card should be created for the PR alone
    Because PRs are attached to existing cards, not standalone

  Scenario: Duplicate PRs are not added
    Given a card already has PR #240 in prLinks
    When the orchestrator finds PR #240 again on the next sync
    Then it should update the existing entry (status, checks, etc.)
    And NOT add a second entry for #240

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
    And the PR should appear on both cards (same prLinks entry)

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

  # ── Branch Auto-Discovery ──
  #
  # Three layers of branch discovery, from cheapest to most expensive:
  #   1. gitBranch field from JSONL metadata (every line has it)
  #   2. Worktree disk scan (git worktree list)
  #   3. Conversation scan for git push / gh pr create (cached, one-time)

  Scenario: Session with --worktree auto-links branch from gitBranch field
    Given a session was started with `claude --worktree`
    And the JSONL lines contain gitBranch "worktree-feat-login"
    When the session is discovered
    Then worktreeLink.branch should be set to "worktree-feat-login"
    And the card should match to any existing backlog/orphan card with that branch

  Scenario: Session on main branch gets no branch link from gitBranch
    Given a session was started without --worktree
    And the JSONL gitBranch field is "main"
    When the session is discovered
    Then worktreeLink should NOT be set from gitBranch
    Because "main" and "master" are filtered out as uninformative

  Scenario: Session without worktree scans conversation for pushed branches
    Given a session's gitBranch is "main" (no worktree)
    And the session is less than 24 hours old
    And the conversation contains Bash tool_use with `git push origin feat/new-feature`
    When branch discovery runs
    Then "feat/new-feature" should be added to discoveredBranches
    And a PR matching that branch should be linked to the card

  Scenario: Conversation scan extracts gh pr create output
    Given a session contains a tool_result with "https://github.com/org/repo/pull/240"
    When branch discovery runs
    Then PR #240 should be discovered from the conversation

  Scenario: Conversation scan finds multiple branches
    Given a session pushed to branches "feat/progressive-trace-discovery" and "feat/custom-config"
    And also pushed to "docs/custom-judge-docs" in a worktree
    When branch discovery runs
    Then all three branches should be in discoveredBranches
    And PRs for each branch should be linked to the card

  Scenario: Conversation scan is cached
    Given a session was already scanned for branches (discoveredBranches is not nil)
    When discovery runs again
    Then the JSONL should NOT be re-scanned
    And the cached discoveredBranches should be used

  Scenario: Conversation scan only runs for recent sessions
    Given a session is older than 24 hours
    And it has no discoveredBranches
    When discovery runs
    Then the conversation should NOT be scanned
    Because old sessions are unlikely to gain new branches

  # ── Branch-Centric Link Model ──
  #
  # A branch is the anchor for work:
  #   card → branch → {worktree (on disk), PR (on GitHub)}
  # PRs are NEVER manually linked — they are discovered from branches.
  # Issues are standalone (come from GitHub, not branch-dependent).
  # A branch can be linked without a worktree existing on disk.

  Scenario: Branch is the anchor for worktree and PR
    Given a card has worktreeLink.branch = "feat/issue-123"
    Then the reconciler should:
      | Action                | Source                              |
      | Find worktree on disk | Branch name → worktree path         |
      | Find PR on GitHub     | headRefName = "feat/issue-123"      |
    And both worktreeLink.path and prLinks should be populated automatically

  Scenario: Adding a branch to a card
    Given a card with no worktreeLink
    When I click "+ Add link" in the detail header
    And I select "Branch" and enter "feat/new-feature"
    Then worktreeLink should be set with branch = "feat/new-feature" and path = ""
    And manualOverrides.worktreePath should be true
    And the reconciler should discover the worktree path and PR on next run

  Scenario: Branch without a worktree on disk
    Given a card has worktreeLink.branch = "feat/remote-only"
    And no worktree directory exists on disk for that branch
    Then the branch link should persist (manualOverrides protects it)
    And worktreeLink.path should remain empty
    And the PR can still be discovered if a PR exists for that branch

  Scenario: PRs cannot be manually linked
    Given a card with no prLink
    When I click "+ Add link"
    Then the popover should offer "Branch" and "Issue" options
    And there should be NO option to add a PR number directly
    Because PRs are discovered from branches, not linked independently

  # ── Interactive Link Management (Property Rows) ──
  #
  # The card detail header shows each link as a full property row:
  #   icon + label + value + action buttons (↗ open, × unlink)
  # This replaces the old cramped pill layout.

  Scenario: Open PR in browser from property row
    Given a card has prLink with number 42 and url "https://github.com/org/repo/pull/42"
    When I click the ↗ button on the PR property row
    Then the PR should open in the default browser

  Scenario: Open issue in browser from property row
    Given a card has issueLink with number 11 and url "https://github.com/org/repo/issues/11"
    When I click the ↗ button on the issue property row
    Then the issue should open in the default browser

  Scenario: Remove branch link from card
    Given a card has worktreeLink.branch = "feat/login"
    When I click the × button on the Branch property row
    Then worktreeLink should be set to nil
    And manualOverrides.worktreePath should be true
    And the reconciler should not re-add this worktree link

  Scenario: Remove PR link from card
    Given a card has prLink.number = 42
    When I click the × button on the PR property row
    Then prLink should be set to nil
    And manualOverrides.prLink should be true
    And the reconciler should not re-add this PR

  Scenario: Remove issue link from card
    Given a card has issueLink.number = 11
    When I click the × button on the Issue property row
    Then issueLink should be set to nil
    And manualOverrides.issueLink should be true

  Scenario: Add issue link manually
    Given a card with no issueLink
    When I click "+ Add link" and select "Issue" with number 55
    Then issueLink should be set with number 55
    And manualOverrides.issueLink should be true

  Scenario: Remove tmux link from card
    Given a card has tmuxLink.sessionName = "feat-login"
    When I click the × button on the Tmux property row
    Then tmuxLink should be set to nil
    And manualOverrides.tmuxSession should be true
