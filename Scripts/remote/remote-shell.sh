#!/bin/bash
# Remote shell wrapper for Claude Code.
# Intercepts shell commands and runs them on a remote host via SSH.
# Designed to be used as $SHELL override: SHELL=/path/to/remote-shell.sh claude
#
# Features:
# - SSH ControlMaster for connection reuse
# - Working directory tracking via MARKER pattern
# - Path replacement (local ↔ remote)
# - Pre/post Mutagen sync flush
# - Local fallback with state file + notification
#
# Configuration via environment variables:
#   KANBAN_REMOTE_HOST     - SSH host (required)
#   KANBAN_REMOTE_PATH     - Remote base path (required)
#   KANBAN_LOCAL_PATH      - Local base path (required)
#   KANBAN_MUTAGEN_LABEL   - Mutagen sync label (optional)
#   KANBAN_CODE_STATE_DIR       - State directory (default: ~/.kanban-code/remote)

set -euo pipefail

# Configuration
REMOTE_HOST="${KANBAN_REMOTE_HOST:-}"
REMOTE_PATH="${KANBAN_REMOTE_PATH:-}"
LOCAL_PATH="${KANBAN_LOCAL_PATH:-}"
MUTAGEN_LABEL="${KANBAN_MUTAGEN_LABEL:-}"
STATE_DIR="${KANBAN_CODE_STATE_DIR:-${HOME}/.kanban-code/remote}"
MARKER="__KANBAN_CWD_MARKER__"

# SSH ControlMaster settings
SSH_CONTROL_DIR="${STATE_DIR}/ssh"
SSH_CONTROL_PATH="${SSH_CONTROL_DIR}/control-%h-%p-%r"
SSH_OPTS=(-o "ControlMaster=auto" -o "ControlPath=${SSH_CONTROL_PATH}" -o "ControlPersist=600" -o "ServerAliveInterval=30")

mkdir -p "$STATE_DIR" "$SSH_CONTROL_DIR"

# ---------- Helpers ----------

log() {
    echo "[kanban-code-remote] $*" >&2
}

replace_paths_to_remote() {
    local cmd="$1"
    echo "${cmd//$LOCAL_PATH/$REMOTE_PATH}"
}

replace_paths_to_local() {
    local output="$1"
    echo "${output//$REMOTE_PATH/$LOCAL_PATH}"
}

flush_mutagen() {
    if [ -n "$MUTAGEN_LABEL" ]; then
        mutagen sync flush --label-selector="$MUTAGEN_LABEL" 2>/dev/null || true
    fi
}

check_remote() {
    ssh "${SSH_OPTS[@]}" -o "ConnectTimeout=5" "$REMOTE_HOST" "echo ok" 2>/dev/null
}

write_state() {
    echo "$1" > "${STATE_DIR}/state"
}

read_state() {
    cat "${STATE_DIR}/state" 2>/dev/null || echo "unknown"
}

notify_fallback() {
    local msg="$1"
    # Write to state file for the app to pick up
    write_state "local_fallback"
    echo "$msg" > "${STATE_DIR}/fallback_reason"
    log "$msg"
}

# Worktree path fix functions — injected into SSH commands.
# Git worktrees use absolute paths in .git files and gitdir files.
# When Mutagen syncs between machines, those absolute paths break.
# These functions convert them to relative paths that survive sync.
#
# Defined as a single string that gets prepended to SSH commands.
# Runs on the REMOTE machine before/after each command.
read -r -d '' WORKTREE_FIX_FN << 'WFIX' || true
__relpath(){
  local t="$1" b="$2"; t="${t%/}"; b="${b%/}"
  local c="$b" r=""
  while [ "${t#"$c"}" = "$t" ]; do c=$(dirname "$c"); r="../$r"; done
  local f="${t#"$c"}"; f="${f#/}"; printf '%s\n' "${r}${f}"
}
__fix_gitlink(){
  local f="$1" wp="$2" rp="$3"
  [ -f "$f" ] || return 0
  local c; c=$(cat "$f"); local ig=false p="$c"
  case "$c" in gitdir:*) ig=true; p="${c#gitdir: }";; esac
  p="${p//$wp/$rp}"
  case "$p" in /*) ;; *) return 0;; esac
  [ -e "$p" ] || return 0
  local d; d=$(dirname "$f")
  local rl; rl=$(__relpath "$p" "$d")
  [ -n "$rl" ] || return 0
  if $ig; then printf 'gitdir: %s\n' "$rl" > "$f"; else printf '%s\n' "$rl" > "$f"; fi
}
__fix_wt(){
  local wp="$1" rp="$2" d; d=$(pwd); local gr=""
  while [ "$d" != "/" ]; do
    if [ -d "$d/.git" ]; then gr="$d"; break
    elif [ -f "$d/.git" ]; then
      __fix_gitlink "$d/.git" "$wp" "$rp"
      local g; g=$(cat "$d/.git"); g="${g#gitdir: }"
      case "$g" in /*) gr="${g%/.git/worktrees/*}";; *) gr=$(cd "$d/$g/../../.." 2>/dev/null && pwd);; esac
      break
    fi
    d=$(dirname "$d")
  done
  [ -n "$gr" ] && [ -d "$gr/.git/worktrees" ] || return 0
  for m in "$gr/.git/worktrees"/*/; do
    [ -d "$m" ] || continue
    __fix_gitlink "${m}gitdir" "$wp" "$rp"
    local gc; [ -f "${m}gitdir" ] && gc=$(cat "${m}gitdir") || continue
    [ -n "$gc" ] || continue
    local wf
    case "$gc" in /*) wf="$gc";;
      *) wf=$(cd "$m" && cd "$(dirname "$gc")" 2>/dev/null && printf '%s/%s\n' "$(pwd)" "$(basename "$gc")") || continue;;
    esac
    [ -n "$wf" ] && __fix_gitlink "$wf" "$wp" "$rp"
  done
}
WFIX

# ---------- Modes ----------

# Interactive mode: called when Claude spawns our "shell"
run_interactive() {
    if [ -z "$REMOTE_HOST" ] || [ -z "$REMOTE_PATH" ] || [ -z "$LOCAL_PATH" ]; then
        log "Remote not configured, running locally"
        exec /bin/zsh "$@"
    fi

    # Check connectivity
    if ! check_remote; then
        notify_fallback "Cannot reach $REMOTE_HOST, falling back to local"
        exec /bin/zsh "$@"
    fi

    write_state "remote"
    flush_mutagen

    # Start remote shell with working directory tracking
    local remote_cwd
    remote_cwd=$(replace_paths_to_remote "$(pwd)")

    ssh "${SSH_OPTS[@]}" -t "$REMOTE_HOST" \
        "cd '$remote_cwd' 2>/dev/null || cd '$REMOTE_PATH'; exec /bin/bash"
}

# Command mode: called as `$SHELL -c "command"`
run_command() {
    local cmd="$1"

    if [ -z "$REMOTE_HOST" ] || [ -z "$REMOTE_PATH" ] || [ -z "$LOCAL_PATH" ]; then
        exec /bin/zsh -c "$cmd"
    fi

    # Check connectivity
    if ! check_remote; then
        notify_fallback "Cannot reach $REMOTE_HOST, running locally"
        exec /bin/zsh -c "$cmd"
    fi

    write_state "remote"

    # Pre-sync
    flush_mutagen

    # Replace local paths with remote paths
    local remote_cmd
    remote_cmd=$(replace_paths_to_remote "$cmd")

    local remote_cwd
    remote_cwd=$(replace_paths_to_remote "$(pwd)")

    # Execute remotely with CWD marker.
    # Inject worktree fix functions: convert absolute .git/gitdir paths to relative
    # so worktrees created on one machine work after Mutagen syncs to the other.
    local output
    output=$(ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" \
        "${WORKTREE_FIX_FN}
cd '$remote_cwd' 2>/dev/null || cd '$REMOTE_PATH'
__fix_wt '$LOCAL_PATH' '$REMOTE_PATH'
$remote_cmd
__fix_wt '$LOCAL_PATH' '$REMOTE_PATH'
echo '${MARKER}'\$(pwd)" 2>&1) || true

    # Extract CWD from marker
    local new_cwd=""
    if [[ "$output" == *"${MARKER}"* ]]; then
        new_cwd="${output##*${MARKER}}"
        output="${output%${MARKER}*}"
        new_cwd=$(replace_paths_to_local "$new_cwd")
    fi

    # Post-sync
    flush_mutagen

    # Replace remote paths back to local in output
    local local_output
    local_output=$(replace_paths_to_local "$output")
    echo "$local_output"

    # Track working directory changes
    if [ -n "$new_cwd" ]; then
        echo "$new_cwd" > "${STATE_DIR}/cwd"
    fi
}

# ---------- Main ----------

if [ "$#" -eq 0 ]; then
    run_interactive
elif [ "$1" = "-c" ] && [ "$#" -ge 2 ]; then
    shift
    run_command "$*"
elif [ "$1" = "-l" ] || [ "$1" = "--login" ]; then
    run_interactive
else
    # Pass through to local shell
    exec /bin/zsh "$@"
fi
