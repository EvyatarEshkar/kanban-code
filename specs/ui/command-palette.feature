Feature: Command Palette
  As a developer switching between many tasks
  I want a VS Code-style command palette (Cmd+P / Cmd+K)
  So that I can quickly jump between recent cards and run commands

  Background:
    Given the Kanban Code application is running

  # ── Opening the Palette ──

  Scenario: Open with Cmd+K
    When I press Cmd+K
    Then the command palette overlay should appear
    And the search input should be focused

  Scenario: Open with Cmd+P
    When I press Cmd+P
    Then the command palette overlay should appear
    And the search input should be focused

  Scenario: Close with Escape
    Given the command palette is open
    When I press Escape
    Then the palette should close

  # ── Recent Cards ──

  Scenario: Empty query shows cards ordered by last opened
    Given the command palette is open
    And I have opened cards in this order: Card A, Card B, Card C
    When the query is empty
    Then cards should be listed in reverse last-opened order:
      | Position | Card   |
      | 1        | Card C |
      | 2        | Card B |
      | 3        | Card A |

  Scenario: Second-most-recent card is pre-selected
    Given I last opened Card C, then Card B
    When I open the command palette
    Then Card C should be pre-selected (the second-most-recent)
    And Card B should be listed first (the most recent, currently open)

  Scenario: Toggle between two most recent cards
    Given I have Card A and Card B open recently
    And Card B is the most recently opened
    When I press Cmd+P
    Then Card A should be pre-selected
    When I press Enter
    Then Card A should be selected on the board
    When I press Cmd+P again
    Then Card B should be pre-selected
    When I press Enter
    Then Card B should be selected on the board

  Scenario: Cards without lastOpenedAt fall back to lastActivity
    Given a card has never been opened via the palette
    Then it should be sorted by lastActivity or updatedAt
    And it should appear after cards that have a lastOpenedAt timestamp

  # ── Command Mode ──

  Scenario: Typing > enters command mode
    Given the command palette is open
    When I type ">"
    Then the palette should show available commands instead of cards

  Scenario: Available commands
    Given the command palette is in command mode
    Then I should see commands including:
      | Command              | Icon                               |
      | Open Settings        | gear                               |
      | Toggle View Mode     | rectangle.split.3x1                |
      | New Task             | plus                               |
      | Toggle Expanded Mode | arrow.up.left.and.arrow.down.right |

  Scenario: Project switching commands
    Given I have configured projects: "langwatch", "kanban"
    When I type ">"
    Then I should see commands:
      | Command                  |
      | Switch to langwatch      |
      | Switch to kanban         |
      | Show All Projects        |

  Scenario: Filter commands by typing
    Given the command palette is in command mode
    When I type ">sett"
    Then only commands matching "sett" should appear
    And "Open Settings" should be visible
    And "New Task" should not be visible

  Scenario: Execute a command
    Given the command palette shows "Open Settings"
    When I select "Open Settings"
    Then the settings window should open
    And the command palette should close

  # ── Search (existing behavior preserved) ──

  Scenario: Live filter by typing
    Given the command palette is open
    When I type "langwatch auth"
    Then cards should be filtered by title, project, branch
    And matching terms should be highlighted

  Scenario: Deep search on Enter
    Given I typed "database migration" in the palette
    When I press Enter
    Then a BM25 deep search should run through .jsonl files
    And results should stream in ranked by relevance

  # ── Keyboard Navigation ──

  Scenario: Arrow keys navigate items
    Given the command palette shows results
    When I press Down Arrow
    Then the next item should be highlighted
    When I press Up Arrow
    Then the previous item should be highlighted

  Scenario: Enter selects the highlighted item
    Given a card is highlighted in the palette
    When I press Enter
    Then that card should be selected on the board
    And the palette should close

  # ── Terminal Focus ──

  Scenario: Terminal receives focus after card selection
    Given a card has a live terminal session
    When I select that card from the command palette
    Then the card detail should open
    And the terminal tab should be active
    And the terminal should receive keyboard focus
