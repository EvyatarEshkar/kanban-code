Feature: GitHub Issues as Backlog Source
  As a developer using GitHub Projects
  I want my assigned issues to appear in the Kanban backlog
  So that I can start working on them with Claude Code directly

  Background:
    Given the Kanban application is running
    And the user has `gh` CLI installed and authenticated
    And the user has configured a GitHub filter

  # ── Configuration ──

  Scenario: Configuring GitHub issue source
    Given I open the settings
    When I set the GitHub filter to "assignee:@me is:open"
    Then the filter should be saved to ~/.kanban/settings.json
    And the backlog should refresh with matching issues

  Scenario: GitHub filter is a raw gh command input
    Given the settings editor shows the GitHub filter field
    Then it should accept raw gh search syntax
    And display a hint: "Uses `gh search issues` syntax"
    And examples like "assignee:@me repo:org/repo is:open label:bug"

  # ── Card Structure for Issues ──

  Scenario: GitHub issues create cards with issueLink
    When a GitHub issue #123 "Fix login bug" is fetched
    Then a card should be created with:
      | Field              | Value                              |
      | id                 | card_<KSUID>                       |
      | source             | github_issue                       |
      | column             | backlog                            |
      | name               | #123: Fix login bug                |
      | issueLink.number   | 123                                |
      | issueLink.body     | (the issue body text)              |
      | issueLink.url      | https://github.com/.../issues/123  |
    And sessionLink, tmuxLink, worktreeLink, prLink should all be nil
    And the card label should be "ISSUE" (orange)

  Scenario: Issue card detail shows issue body
    Given an issue card "#123: Fix login bug" is selected
    Then the detail view should have a "Context" tab
    And it should show the full issue body as scrollable text
    And an "Open in Browser" button should link to the issue URL
    And a "Start Work" button should be available

  # ── Fetching and Display ──

  Scenario: Initial backlog load
    When the Kanban board opens
    Then GitHub issues should be fetched via `gh search issues`
    And each issue should appear as a card in "Backlog" with:
      | Field       | Source              |
      | Title       | #number: Issue title|
      | Labels      | Issue labels        |

  Scenario: Deduplication of GitHub issues
    Given a card with issueLink.number = 123 exists for this project
    When the next GitHub fetch also returns issue #123
    Then the existing card should be kept
    And no duplicate card should be created

  Scenario: Background polling for new issues
    Given the backlog was loaded 5 minutes ago
    When the poll interval elapses (configurable, default 300s)
    Then new issues matching the filter should be fetched
    And new cards should appear in "Backlog"
    And stale issues (no longer matching) should be removed from "Backlog"
    But started issues (have sessionLink) should not be removed

  Scenario: Manual backlog refresh via column button
    Given the backlog column is visible
    Then a refresh button (arrow.clockwise) should appear in the column header
    When I click the refresh button
    Then GitHub issues should be re-fetched immediately regardless of timer
    And the button should show a spinner while loading

  # ── Starting Work on an Issue ──

  Scenario: Start work on a GitHub issue
    Given issue "#123: Fix login bug" is in the Backlog
    When I click "Start" on the card
    Then the launch confirmation dialog should appear
    And the prompt should be built from templates:
      | Template                    | Applied to                      |
      | githubIssuePromptTemplate   | Issue title, number, body       |
      | promptTemplate              | Wraps the result                |
    And I can edit the prompt before launching

  Scenario: Issue prompt template rendering
    Given the githubIssuePromptTemplate is "#${number}: ${title}\n\n${body}"
    And the promptTemplate is "/orchestrate ${prompt}"
    And issue #123 has title "Fix login bug" and body "Users get redirected..."
    Then the rendered prompt should be:
      """
      /orchestrate #123: Fix login bug

      Users get redirected...
      """

  Scenario: Launching adds links to existing issue card
    Given I started work on issue #123 from the launch confirmation dialog
    Then the EXISTING card (with issueLink.number = 123) should gain:
      | Link         | Value                          |
      | tmuxLink     | sessionName = "issue-123"      |
      | sessionLink  | (added via SessionStart hook)  |
      | worktreeLink | (added when worktree created)  |
    And the card should move from Backlog to In Progress
    And the label should change from "ISSUE" to "SESSION"
    And there should still be exactly one card

  # ── Prompt Templates ──

  Scenario: Default prompt template
    Given no custom promptTemplate is configured
    Then the default promptTemplate should be "${prompt}"
    And the prompt should be sent as-is to Claude

  Scenario: Custom prompt template wraps the issue
    Given settings has promptTemplate = "/orchestrate ${prompt}"
    When I start a GitHub issue
    Then the prompt should be prepended with "/orchestrate"

  Scenario: Per-project prompt template override
    Given project "LangWatch" has promptTemplate = "/orchestrate ${prompt}"
    And project "SideProject" has no promptTemplate (inherits global)
    When I start a LangWatch issue
    Then the project's template should be used
    When I start a SideProject issue
    Then the global template should be used

  Scenario: GitHub issue prompt template
    Given settings has githubIssuePromptTemplate = "Fix issue #${number}: ${title}\n\nDetails:\n${body}"
    When building a prompt for issue #42 "Add dark mode"
    Then the issue template should render first
    Then the result should be wrapped by promptTemplate

  # ── Edge Cases ──

  Scenario: gh CLI not installed
    Given `gh` is not installed
    When the Kanban board opens
    Then the Backlog should show a message: "Install GitHub CLI for issue integration"
    And a link to https://cli.github.com/
    And manual task creation should still work

  Scenario: gh CLI not authenticated
    Given `gh` is installed but not authenticated
    When the Kanban board opens
    Then the Backlog should show: "Run `gh auth login` to connect GitHub"
    And manual task creation should still work

  Scenario: GitHub API rate limit
    Given the GitHub API returns a rate limit error
    Then a subtle warning should appear on the Backlog column header
    And previously fetched issues should remain visible
    And retry should happen on next poll interval

  Scenario: Network offline
    Given the network is unavailable
    When a GitHub fetch fails
    Then previously cached issues should remain in the backlog
    And a subtle "offline" indicator should appear

  # ── Per-Project Filters ──

  Scenario: Per-project GitHub filter
    Given project "LangWatch" has githubFilter "assignee:@me repo:langwatch/langwatch is:open"
    When I select the LangWatch project view
    Then the backlog should only show issues matching that filter

  Scenario: Global view combines per-project filters
    Given "LangWatch" has filter "repo:langwatch/langwatch"
    And "Scenario" has filter "repo:langwatch/scenario"
    When I select "All Projects"
    Then the backlog should combine issues from both filters

  Scenario: Project without filter inherits default
    Given a project "SideProject" has no githubFilter
    And the global default filter is "assignee:@me is:open"
    When I view SideProject
    Then the backlog should use the global default filter
