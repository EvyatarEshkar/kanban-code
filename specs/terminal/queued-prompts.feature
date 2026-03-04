Feature: Queued Prompts
  As a developer using Kanban Code
  I want to queue prompts that auto-send when Claude finishes
  So I can chain tasks without waiting at the keyboard

  Background:
    Given the Kanban Code application is running
    And a card exists with an active tmux session

  # ── Adding Queued Prompts ──

  Scenario: Adding a queued prompt from the terminal tab
    When I open the card detail drawer
    And I switch to the Terminal tab
    Then I should see a "+ Queue Prompt" button next to "Copy tmux attach"
    When I click "+ Queue Prompt"
    Then a dialog opens with a prompt text field
    And a "Send automatically" checkbox that is checked by default
    When I type "fix the failing tests" and click "Add"
    Then the prompt appears in a bar above the terminal
    And it shows a bolt icon indicating auto-send is enabled

  Scenario: Adding multiple queued prompts
    Given I already have a queued prompt "fix the failing tests"
    When I add another prompt "then run the linter"
    Then both prompts appear in order in the bar above the terminal
    And each has its own Send Now, edit, and remove buttons

  # ── Manual Send ──

  Scenario: Sending a queued prompt manually
    Given I have a queued prompt "fix the failing tests"
    When I click "Send Now" on that prompt
    Then the prompt text is sent to the tmux session via send-keys
    And the terminal receives the prompt and Enter is pressed
    And the prompt is removed from the queue

  # ── Editing and Removing ──

  Scenario: Editing a queued prompt
    Given I have a queued prompt "fix the failing tests"
    When I click the edit button on that prompt
    Then the dialog opens pre-filled with "fix the failing tests"
    When I change it to "fix the failing tests and add coverage"
    And click "Save"
    Then the prompt updates in the bar

  Scenario: Removing a queued prompt
    Given I have a queued prompt "fix the failing tests"
    When I click the X button on that prompt
    Then the prompt is removed from the queue

  # ── Auto-Send ──

  Scenario: Auto-send when Claude stops and was actively working
    Given I have a queued prompt with "Send automatically" checked
    And Claude is actively working on the card (in progress)
    When Claude stops (Stop hook fires)
    Then after ~2 seconds the first auto-send prompt is sent to tmux
    And the prompt is removed from the queue
    And the remaining prompts stay queued

  Scenario: Auto-send does NOT fire on app launch
    Given I have a queued prompt with "Send automatically" checked
    And the card was already in "Waiting" when the app launched
    When the app starts and detects the session is idle
    Then the prompt is NOT auto-sent
    And the user can click "Send Now" manually

  Scenario: Auto-send does NOT fire if user already interacted
    Given I have a queued prompt with "Send automatically" checked
    And Claude stops (Stop hook fires)
    But within 2 seconds I submit a prompt manually
    Then the queued prompt is NOT auto-sent

  Scenario: Auto-send fires after card goes in-progress then back to waiting
    Given a card was already in "Waiting" when the app launched
    And I have a queued prompt with "Send automatically" checked
    When I manually send a prompt (card goes to in-progress)
    And Claude finishes and stops (card goes back to waiting)
    Then the queued auto-send prompt IS sent after ~2 seconds

  # ── Persistence ──

  Scenario: Queued prompts survive app restart
    Given I have queued prompts on a card
    When I quit and relaunch Kanban Code
    Then the queued prompts are still visible on the card
    And they are stored in the card's link data (~/.kanban-code/links.json)
