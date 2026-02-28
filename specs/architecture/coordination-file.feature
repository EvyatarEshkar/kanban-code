Feature: Coordination File
  As a developer debugging Kanban's card linking
  I want a clear, human-readable coordination file
  So that I can inspect and manually fix cards and their links when needed

  Background:
    Given the Kanban application is running

  # ── File Structure ──

  Scenario: Coordination file location and format
    Then the coordination file should be at ~/.kanban/links.json
    And it should be valid JSON, pretty-printed for readability
    And it should be inspectable with `cat ~/.kanban/links.json | jq`

  Scenario: Card entry with all links attached
    Given a card has a session, worktree, tmux, PR, and GitHub issue linked
    Then the entry should use typed link sub-structs:
      """json
      {
        "id": "card_2MtCMwXZOHPSlEMDe7OYW6bRfXX",
        "name": "Implement login flow",
        "projectPath": "/Users/rchaves/Projects/remote/langwatch-saas",
        "column": "in_progress",
        "createdAt": "2026-02-28T10:00:00.000Z",
        "updatedAt": "2026-02-28T10:30:00.000Z",
        "lastActivity": "2026-02-28T10:30:00.000Z",
        "manualOverrides": {
          "worktreePath": false,
          "tmuxSession": false,
          "name": true,
          "column": false
        },
        "manuallyArchived": false,
        "source": "github_issue",
        "sessionLink": {
          "sessionId": "claude-session-uuid",
          "sessionPath": "/Users/rchaves/.claude/projects/-Users-rchaves-Projects-remote-langwatch/uuid.jsonl",
          "sessionNumber": 3
        },
        "tmuxLink": {
          "sessionName": "issue-123"
        },
        "worktreeLink": {
          "path": "/Users/rchaves/Projects/remote/langwatch-saas/.claude/worktrees/issue-123",
          "branch": "feat/issue-123"
        },
        "prLink": {
          "number": 456
        },
        "issueLink": {
          "number": 123,
          "url": "https://github.com/langwatch/langwatch/issues/123",
          "body": "Fix the login bug where users get redirected..."
        }
      }
      """

  Scenario: Card with only a GitHub issue (backlog)
    Given a GitHub issue was fetched but no work has started
    Then the card should have only an issueLink:
      """json
      {
        "id": "card_2MtBXe1kP7nRQZ4J5aYjL9mhTvW",
        "name": "#42: Add dark mode support",
        "projectPath": "/Users/rchaves/Projects/remote/langwatch-saas",
        "column": "backlog",
        "source": "github_issue",
        "issueLink": {
          "number": 42,
          "url": "https://github.com/langwatch/langwatch/issues/42",
          "body": "Users have requested dark mode..."
        }
      }
      """
    And sessionLink, tmuxLink, worktreeLink, prLink should all be absent (not null)

  Scenario: Card with only an orphan worktree
    Given a worktree exists on disk but no session references it
    Then a card should be created with only a worktreeLink:
      """json
      {
        "id": "card_2MtDFgH3mKpQ8sR7wXvN0oYiUcA",
        "projectPath": "/Users/rchaves/Projects/remote/langwatch-saas",
        "column": "requires_attention",
        "source": "discovered",
        "worktreeLink": {
          "path": "/Users/rchaves/Projects/remote/langwatch-saas/.claude/worktrees/feat-auth",
          "branch": "feat/auth"
        }
      }
      """

  Scenario: Card with only a session (discovered externally)
    Given a Claude session was started from the terminal (not via Kanban)
    Then a card should be created with only a sessionLink:
      """json
      {
        "id": "card_2MtEAb9nK4pRtSw2xYz3oQm1VgH",
        "name": "Quick question about APIs",
        "projectPath": "/Users/rchaves/Projects/remote/langwatch-saas",
        "column": "all_sessions",
        "source": "discovered",
        "sessionLink": {
          "sessionId": "abc-123-def-456",
          "sessionPath": "/Users/rchaves/.claude/projects/.../abc-123-def-456.jsonl"
        }
      }
      """

  Scenario: Manual task without a session yet
    Given a user created a task but hasn't started it
    Then the card should have no typed links, just promptBody:
      """json
      {
        "id": "card_2MtFCd7mL5qStUx3yZa4pRn2WhJ",
        "name": "Refactor database layer",
        "projectPath": "/Users/rchaves/Projects/remote/langwatch-saas",
        "column": "backlog",
        "source": "manual",
        "promptBody": "Refactor database layer\n\nMove all SQL queries to a dedicated repository pattern..."
      }
      """

  Scenario: Card IDs use KSUID format
    Given a new card is created
    Then its ID should be a KSUID with "card_" prefix
    And the KSUID part should be 27 base62 characters
    And cards should be naturally sortable by creation time via their IDs
    And old UUID-format IDs from previous versions should still work

  # ── Backward Compatibility ──

  Scenario: Old flat-format links.json is auto-migrated
    Given an existing links.json with flat fields:
      """json
      {
        "id": "old-uuid-format",
        "sessionId": "claude-uuid",
        "worktreePath": "/path/to/worktree",
        "worktreeBranch": "feat/login",
        "tmuxSession": "feat-login",
        "githubIssue": 123,
        "githubPR": 456,
        "column": "in_progress",
        "source": "discovered"
      }
      """
    When Kanban reads the file
    Then it should decode the flat fields into typed link sub-structs
    And the next write should output the new nested format
    And no data should be lost

  # ── File Operations ──

  Scenario: Atomic writes
    When the coordination file is updated
    Then it should be written atomically:
      | Step | Action                                    |
      | 1    | Write to ~/.kanban/links.json.tmp         |
      | 2    | Rename links.json.tmp to links.json       |
    And this prevents partial writes on crash

  Scenario: Concurrent access safety
    Given multiple processes might read/write the file
    Then updates should use file locking
    And reads should not require locks (eventual consistency is OK)
    And the lock file should be ~/.kanban/links.json.lock

  Scenario: File corruption recovery
    Given the coordination file is corrupted
    When Kanban tries to read it
    Then it should:
      | Step | Action                                    |
      | 1    | Detect invalid JSON                       |
      | 2    | Back up corrupted file as links.json.bkp  |
      | 3    | Rebuild from session discovery             |
      | 4    | Show notification about the recovery      |

  # ── Card Lifecycle ──

  Scenario: New session creates a card
    Given a new Claude session "abc-123" is discovered
    When no card has a sessionLink with that sessionId
    Then a new card should be created with:
      | Field                  | Value                |
      | sessionLink.sessionId  | abc-123              |
      | column                 | all_sessions or in_progress (if hook triggered) |
      | source                 | discovered or hook   |

  Scenario: Links are added incrementally to existing cards
    Given a card exists with only a sessionLink
    When the background process discovers a matching worktree
    Then a worktreeLink should be added to the existing card
    And the sessionLink should remain unchanged
    And updatedAt should be refreshed

  Scenario: Dead links are cleaned up
    Given a card has a worktreeLink pointing to a path that no longer exists
    When the reconciler detects the missing worktree
    Then the worktreeLink should be set to nil
    But the card itself should remain (other links may still be valid)

  Scenario: Dead tmux links are cleared
    Given a card has a tmuxLink with sessionName "issue-123"
    When "issue-123" is no longer in the live tmux session list
    Then the tmuxLink should be set to nil
    But the card should remain with its other links

  # ── Manual Editing ──

  Scenario: User edits the file directly
    Given I open ~/.kanban/links.json in a text editor
    When I add a worktreeLink to a card that didn't have one
    And save the file
    Then Kanban should detect the change
    And the UI should update to reflect the new link
    And the manual change should be treated as a manual override

  Scenario: User adds a manual card entry
    Given I add a new JSON entry to the links array
    When Kanban reloads the file
    Then the new entry should appear on the board
    And it should be treated as a manually created card

  # ── Debugging ──

  Scenario: Card file is useful for debugging
    Given I'm debugging why a session isn't linked to its worktree
    When I run `cat ~/.kanban/links.json | jq '.links[] | select(.sessionLink.sessionId == "abc-123")'`
    Then I should see all the card data including all typed links
    And I should be able to identify what's missing or wrong
    And manually fix it if needed
