Feature: Manual Task Creation
  As a developer
  I want to add tasks manually to the Kanban backlog
  So that I can track work not tied to GitHub issues

  Background:
    Given the Kanban application is running

  # ── Task Creation ──

  Scenario: Creating a manual task with single prompt field
    When I click the "+" button or press ⌘N
    Then a task creation form should appear with:
      | Field              | Type                    | Required |
      | Prompt             | Multiline text editor   | yes      |
      | Project            | Dropdown picker         | yes      |
      | Start immediately  | Checkbox                | no       |
    And the prompt field placeholder should say "Describe what you want Claude to do..."

  Scenario: Prompt field splits into name and body
    When I enter a multi-line prompt:
      """
      Refactor database layer

      Move all SQL queries to a dedicated repository pattern.
      Add proper error handling and connection pooling.
      """
    Then the card name should be "Refactor database layer" (first line)
    And the promptBody should be the full text
    And the promptBody is what gets sent to Claude

  Scenario: Single-line prompt
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

  Scenario: Create and start immediately
    When I create a task with "Start immediately" checked
    Then the card should be created in the board
    And the launch confirmation dialog should appear with the prompt
    And on launch, the card gains tmuxLink + sessionLink
    And exactly one card should exist (no duplicates)

  Scenario: Create without starting
    When I uncheck "Start immediately" and create a task
    Then the card should appear in Backlog with label "TASK"
    And no tmux session should be created
    And the card should have no sessionLink, tmuxLink, or worktreeLink
    And I can start it later by clicking the Start button

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
    When I right-click and select "Delete"
    Then a confirmation dialog should appear
    And on confirm, the card should be permanently removed

  # ── Conversion ──

  Scenario: Manual task gains GitHub issue link
    Given a manual task is in progress
    And the Claude session created a PR linked to issue #456
    When the reconciler detects the PR and matches it by branch
    Then the card should gain a prLink
    And the card label should remain "SESSION" (session takes priority)
