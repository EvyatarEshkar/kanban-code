Feature: Manual Task Creation
  As a developer
  I want to add tasks manually to the Kanban Code backlog
  So that I can track work not tied to GitHub issues

  Background:
    Given the Kanban Code application is running

  # ── Task Creation ──

  Scenario: Creating a manual task with single prompt field
    When I click the "+" button or press ⌘N
    Then a task creation form should appear with:
      | Field              | Type                    | Required |
      | Prompt             | Multiline text editor   | yes      |
      | Title              | Text field              | no       |
      | Project            | Dropdown picker         | yes      |
      | Start immediately  | Checkbox                | no       |
    And the prompt field placeholder should say "Describe what you want Claude to do..."
    And the title field defaults to empty (first line of prompt used as card name)

  Scenario: Double-clicking a working lane background opens the task creation form
    When I double-click the empty background of the "Waiting" lane
    Then the same task creation form should appear as if I clicked "+" or pressed ⌘N

  Scenario: Double-clicking All Sessions does not open task creation
    When I double-click the empty background of the "All Sessions" lane
    Then the task creation form should not appear

  Scenario: Title field overrides auto-derived name
    When I enter title "Auth Refactor" and prompt "Refactor the auth module..."
    Then the card name should be "Auth Refactor"
    And promptBody should be "Refactor the auth module..."

  Scenario: Empty title uses first line of prompt
    When I leave title empty and enter a multi-line prompt:
      """
      Refactor database layer

      Move all SQL queries to a dedicated repository pattern.
      Add proper error handling and connection pooling.
      """
    Then the card name should be "Refactor database layer" (first line)
    And the promptBody should be the full text
    And the promptBody is what gets sent to Claude

  Scenario: Single-line prompt with no title
    When I enter just "Fix the login button color"
    Then the card name should be "Fix the login button color"
    And the promptBody should be "Fix the login button color"

  Scenario: Project defaults to current selection
    Given I'm viewing the "LangWatch" project
    When I create a new task
    Then the project dropdown should default to "LangWatch"

  Scenario: Custom project path
    When I need a project path not in the configured list
    Then I should be able to select "Custom path..." from the dropdown
    And type a path manually

  # ── Start Immediately ──

  Scenario: Start immediately checkbox
    When the task creation form appears
    Then a "Start immediately" checkbox should be visible
    And it should remember the last setting via @AppStorage

  Scenario: Start immediately preference persists
    Given I unchecked "Start immediately" on the last task I created
    When I open the task creation form again
    Then "Start immediately" should still be unchecked

  Scenario: Create and start immediately shows inline launch options
    When "Start immediately" is checked, additional options appear inline:
      | Option           | Condition                                    |
      | Create worktree  | Enabled if project folder is a git repo      |
      | Run remotely     | Enabled if global remote configured & project under localPath |
      | Command preview  | Shows the command that will be executed       |
    And clicking "Create & Start" launches directly (no second dialog)
    And the card gains tmuxLink + sessionLink
    And exactly one card should exist (no duplicates)

  Scenario: Create without starting
    When I uncheck "Start immediately" and create a task
    Then the card should appear in Backlog with label "TASK"
    And no tmux session should be created
    And the card should have no sessionLink, tmuxLink, or worktreeLink
    And I can start it later by clicking the Start button

  Scenario: Lane double-click uses the same creation defaults as New Task
    Given I opened the task creation form by double-clicking the empty background of the "In Review" lane
    When I uncheck "Start immediately" and create a task
    Then the card should appear in Backlog with label "TASK"

  # ── Card Structure ──

  Scenario: Manual task card structure
    When I create a manual task "Fix auth flow"
    Then a card should be created with:
      | Field         | Value                         |
      | id            | card_<KSUID>                  |
      | name          | Fix auth flow                 |
      | source        | manual                        |
      | column        | backlog (or in_progress)      |
      | promptBody    | Full prompt text              |
    And sessionLink, tmuxLink, worktreeLink, prLink, issueLink should all be nil

  # ── Starting a Manual Task ──

  Scenario: Starting a manual task from backlog
    Given a manual task "Refactor database layer" exists in Backlog
    When I click "Start"
    Then the launch confirmation dialog should show the promptBody
    And the prompt should be wrapped with the project's promptTemplate
    And on launch, the card gains tmuxLink (and later sessionLink via hook)

  Scenario: Manual task with specific project
    Given a manual task is linked to project "~/Projects/remote/langwatch-saas"
    When I start the task
    Then Claude should be launched in that project directory

  # ── Editing and Deleting ──

  Scenario: Editing a manual task
    Given a manual task exists in the Backlog
    When I click on the card to open it
    Then I should be able to edit the name
    And changes should save automatically

  Scenario: Deleting a manual task
    Given a manual task exists in the Backlog
    When I click "Delete" in the card detail view
    Then a confirmation dialog should appear
    And on confirm, the card should be permanently removed

  Scenario: Deleting a card with an active session
    Given a card has a tmux session and a .jsonl session file
    When I delete the card
    Then the tmux session should be killed
    And the .jsonl session file should be deleted from disk
    And the link should be removed from the coordination store
    And the card should disappear from the board

  # ── Conversion ──

  Scenario: Manual task gains GitHub issue link
    Given a manual task is in progress
    And the Claude session created a PR linked to issue #456
    When the reconciler detects the PR and matches it by branch
    Then the card should gain a prLink
    And the card label should remain "SESSION" (session takes priority)
