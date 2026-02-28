Feature: Session Launching
  As a developer using Kanban
  I want to launch Claude Code sessions from the board with a confirmation dialog
  So that I can review and edit prompts before starting work

  Background:
    Given the Kanban application is running
    And tmux is installed

  # ── Launch Confirmation Dialog ──

  Scenario: Launch confirmation dialog appears before every launch
    Given I click "Start" on any backlog card
    Then a launch confirmation dialog should appear with:
      | Field            | Type              | Editable |
      | Project path     | Text              | no       |
      | Prompt           | TextEditor        | yes      |
      | Create worktree  | Checkbox          | yes      |
    And the prompt should be pre-filled from prompt templates
    And I can edit the prompt before clicking "Launch"
    And "Cancel" dismisses without launching

  Scenario: Prompt is built from templates before dialog
    Given the promptTemplate is "/orchestrate ${prompt}"
    And a manual task has promptBody "Fix the login flow"
    When I click "Start"
    Then the dialog should show: "/orchestrate Fix the login flow"
    And I can modify it before launching

  Scenario: Create worktree checkbox defaults and persists
    When the launch confirmation dialog first appears
    Then "Create worktree" should be checked by default
    When I uncheck "Create worktree" and launch
    Then the next time I open the dialog, it should be unchecked
    Because the preference is saved via @AppStorage("createWorktree")

  Scenario: Launching without worktree
    Given "Create worktree" is unchecked in the dialog
    When I click "Launch"
    Then Claude should be started without the --worktree flag
    And no worktreeLink should be set on the card

  Scenario: Launching with worktree
    Given "Create worktree" is checked in the dialog
    When I click "Launch"
    Then Claude should be started with `claude --worktree <name>`
    And the worktree name should be derived from the card:
      | Card type      | Worktree name        |
      | GitHub issue   | issue-123            |
      | Manual task    | (auto-generated)     |

  # ── Launching from Backlog ──

  Scenario: Launch Claude for a GitHub issue
    Given a GitHub issue "#123: Fix login bug" is in Backlog
    And the project is configured at "~/Projects/remote/langwatch-saas"
    When I click "Start" and confirm the launch dialog
    Then the following should happen in order:
      | Step | Action                                                        |
      | 1    | Create tmux session named "issue-123"                         |
      | 2    | Inside tmux: cd to project directory                          |
      | 3    | Run: claude --worktree issue-123                              |
      | 4    | Send the prompt from the dialog                              |
    And the existing card should gain a tmuxLink
    And no new card should be created

  Scenario: Launch Claude for a manual task
    Given a manual task is in Backlog
    When I click "Start" and confirm the launch dialog
    Then Claude should be launched with the edited prompt
    And the existing card should gain a tmuxLink

  Scenario: Launch Claude on an orphan worktree
    Given an orphan worktree card exists (has worktreeLink, no sessionLink)
    When I click "Start Work"
    Then the launch confirmation dialog should appear
    And the prompt field should be empty (user must provide a prompt)
    And "Create worktree" should be hidden (worktree already exists)
    When I enter a prompt and click "Launch"
    Then Claude should be launched in the existing worktree directory
    And no --worktree flag should be passed

  Scenario: Launch Claude with auto-generated worktree name
    Given a manual task without a specific branch name
    When "Create worktree" is checked in the launch dialog
    Then Claude should be launched with `claude --worktree`
    And Claude Code will auto-generate the worktree name
    And the reconciler should later detect the worktree and add worktreeLink

  # ── Sub-repo Support ──

  Scenario: Launch Claude in a sub-repo
    Given a project is configured with:
      | projectPath | ~/Projects/remote/langwatch-saas/langwatch |
      | repoRoot    | ~/Projects/remote/langwatch-saas           |
    When I start a task
    Then Claude should be launched in the projectPath
    But worktrees and PRs should be tracked against the repoRoot

  # ── Launching without tmux ──

  Scenario: tmux not installed
    Given tmux is not installed
    When I click "Start" on a backlog item
    Then Claude should still be launched
    But in a background process instead of a tmux session
    And the card should show "no tmux" indicator
    And I should see a hint to install tmux for better experience

  # ── Remote Execution ──

  Scenario: Remote execution configured
    Given remote execution is configured with:
      | Setting    | Value                         |
      | host       | ubuntu@server.com             |
      | remotePath | /home/ubuntu/Projects         |
      | localPath  | ~/Projects/remote             |
    When I start a task for project "~/Projects/remote/langwatch-saas"
    Then Claude should be launched with the remote shell wrapper
    And the SHELL environment variable should point to the fake shell
    And Mutagen sync should be started for the project

  # ── Start Button on Cards ──

  Scenario: Backlog cards show a Start button
    Given a card is in the Backlog column
    Then a play button should be visible on the card
    And clicking it should open the launch confirmation dialog

  Scenario: Context menu Start option
    Given any card in the Backlog column
    When I right-click the card
    Then a "Start" option should appear in the context menu

  # ── Resuming ──

  Scenario: Resume an existing session from any column
    Given a card has sessionLink.sessionId = "abc-123"
    When I click "Resume"
    Then if there's an existing tmux session, it should be used
    Otherwise a new tmux session should be created
    And Claude should be resumed with `claude --resume abc-123`
    And the card should gain/update its tmuxLink

  Scenario: Resume without tmux session
    Given a card has sessionLink but no tmuxLink
    When I click "Resume"
    Then a new tmux session should be created
    And `claude --resume <sessionId>` should be run inside it
    And the card should gain a tmuxLink

  Scenario: Copy resume command
    Given a card has sessionLink.sessionId = "abc-123"
    When I click "Copy resume command"
    Then `cd <projectPath> && claude --resume abc-123` should be copied to clipboard

  Scenario: Copy resume command for card without session
    Given a card has no sessionLink (e.g., backlog issue)
    When I click "Copy resume command"
    Then "# no session yet" should be copied to clipboard
