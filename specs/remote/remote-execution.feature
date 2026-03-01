Feature: Remote Execution
  As a developer with a powerful remote server
  I want Kanban to support running Claude Code remotely
  So that my local machine stays fast while heavy work runs on the server

  Background:
    Given the Kanban application is running
    And remote execution is configured

  # ── Shell Interception ──
  # (Learned from claude-remote: $SHELL override, path replacement)

  Scenario: Launching Claude with remote shell
    Given remote execution is configured for a project
    When a Claude session is started for that project
    Then the SHELL environment variable should point to the fake shell
    And the fake shell should be named "zsh" (symlink) for compatibility
    And `exec claude` should inherit the SHELL override

  Scenario: Command routing through fake shell
    Given Claude executes a command via $SHELL -c "npm test"
    Then the fake shell should:
      | Step | Action                                             |
      | 1    | Check remote availability (plain SSH, no ControlMaster) |
      | 2    | If available: flush Mutagen sync                   |
      | 3    | Replace local paths with remote paths in command   |
      | 4    | Execute via SSH with ControlMaster                 |
      | 5    | Replace remote paths with local paths in output    |
      | 6    | Handle pwd tracking (Claude's working dir file)    |
      | 7    | Flush Mutagen sync after completion                |
      | 8    | Return exit code                                   |

  Scenario: Path replacement in commands
    Given localPath is "~/Projects/remote"
    And remotePath is "/home/ubuntu/Projects"
    When Claude runs a command containing "~/Projects/remote/langwatch-saas"
    Then it should be replaced with "/home/ubuntu/Projects/langwatch-saas"
    And paths in output should be reverse-replaced

  Scenario: Working directory tracking
    Given Claude appends `&& pwd -P >| /tmp/file` to commands
    Then the fake shell should:
      | Step | Action                                          |
      | 1    | Strip the pwd capture from the command          |
      | 2    | Append a MARKER and pwd to the remote command   |
      | 3    | Split output on MARKER to get remote pwd        |
      | 4    | Translate remote pwd to local path              |
      | 5    | Write local path to Claude's expected file      |

  # ── SSH Multiplexing ──

  Scenario: SSH ControlMaster for connection reuse
    Given remote commands execute frequently
    Then SSH should use ControlMaster with:
      | Setting        | Value                                |
      | ControlMaster  | auto                                 |
      | ControlPath    | /tmp/ssh-kanban-%r@%h:%p             |
      | ControlPersist | 600 (10 minutes)                     |
    And subsequent commands should reuse the connection

  Scenario: Stale SSH socket detection
    Given the SSH control socket exists but is stale
    When a command is attempted
    Then the socket should be tested with `ssh -O check`
    And if stale, deleted and recreated
    And the command should still succeed

  # ── Local Fallback ──
  # (Learned from claude-remote: state file, cooldown, notifications)

  Scenario: Automatic local fallback when remote unavailable
    Given the remote server is unreachable
    When Claude tries to execute a command
    Then the command should execute locally instead
    And a macOS notification should fire: "Claude Remote: Running locally"
    And the UI should show "local" indicator on the session card

  Scenario: Fallback notification cooldown
    Given the remote is offline
    And a notification was sent 2 minutes ago
    Then no repeat notification should be sent
    Until the 5-minute cooldown elapses

  Scenario: Reconnection notification
    Given commands were running locally due to offline remote
    When the remote becomes available again
    Then a notification should fire: "Claude Remote: Back online"
    And subsequent commands should route to remote
    And the UI indicator should switch to "remote"

  Scenario: State persistence for online/offline
    Given the remote connection state changes
    Then the state should be persisted to a temp file
    And the last notification timestamp should be tracked
    And state transitions should be: offline → online or online → offline

  # ── Display ──

  Scenario: Remote indicator on session cards
    Given a session is running with remote execution
    Then the card should show a "remote" badge
    And hovering should show the remote host name

  Scenario: Local fallback indicator
    Given a session fell back to local execution
    Then the card should show a "local (fallback)" badge in yellow
    And a tooltip should explain the remote is unavailable

  # ── Launch Dialog Remote Checkbox ──

  Scenario: Run remotely checkbox in launch dialog
    Given remote execution is configured for the project
    When the launch confirmation dialog appears
    Then "Run remotely" should be checked by default
    And the command preview should show the SHELL override and KANBAN_* env vars
    When I uncheck "Run remotely"
    Then the command preview should show a plain claude command
    And launching should run Claude locally without remote shell

  Scenario: Run remotely checkbox disabled without config
    Given remote execution is NOT configured for the project
    When the launch confirmation dialog appears
    Then "Run remotely" should be disabled and unchecked
    And a tooltip should explain "Configure remote execution in project settings"
    And the command preview should show a plain claude command

  Scenario: Run remotely preference persists across launches
    Given I unchecked "Run remotely" in a previous launch
    When I open the launch dialog again
    Then "Run remotely" should still be unchecked
    Because it is persisted via @AppStorage("runRemotely")

  Scenario: New task dialog also shows Run remotely
    Given "Start immediately" is checked in the new task dialog
    And the selected project has remoteConfig
    Then the "Run remotely" checkbox should be enabled
    And the command preview should show remote env vars
    And clicking "Create & Start" launches with remote shell directly

  # ── Edge Cases ──

  Scenario: Remote not configured for a project
    Given remote execution is configured only for ~/Projects/remote/*
    And I start a session for ~/Projects/local-project
    Then the session should run locally without any remote shell
    And no remote indicators should appear

  Scenario: Remote profile sourcing
    Given the remote machine needs ~/.profile for PATH
    Then remote commands should source ~/.profile first
    And .bashrc non-interactive guard should be bypassed:
      `sed 's/return;;/;;/' ~/.bashrc`
