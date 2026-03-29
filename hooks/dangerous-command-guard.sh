#!/bin/bash
# PreToolUse hook: Block dangerous shell commands in Claude Code
# Intercepts irreversible commands and requires explicit approval before execution.
#
# Extracted from a production AI assistant system (jfdi.bot)
# Original concept adapted to use file-based single-use approval tokens.
#
# Install: Add to .claude/settings.json under hooks.PreToolUse
# Requires: jq

# --- Configuration ---
# Approval token directory (change if needed)
DANGEROUS_DIR="/tmp/claude-dangerous"
PENDING_DIR="$DANGEROUS_DIR/pending"
APPROVED_DIR="$DANGEROUS_DIR/approved"

mkdir -p "$PENDING_DIR" "$APPROVED_DIR" 2>/dev/null

# --- Read hook input ---
INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

# Only intercept Bash tool calls
if [[ "$TOOL_NAME" != "Bash" ]]; then
    exit 0
fi

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [[ -z "$COMMAND" ]]; then
    exit 0
fi

# Cleanup stale tokens (pending: 5 min, approved: 60s)
find "$PENDING_DIR" -type f -mmin +5 -delete 2>/dev/null
find "$APPROVED_DIR" -type f -mmin +1 -delete 2>/dev/null

# --- Hash generation ---
# Each approval token is scoped to a specific command in a specific session
generate_hash() {
    echo -n "${SESSION_ID}:${COMMAND}" | md5sum | cut -d' ' -f1
}

# --- Pattern matching ---
# Returns a human-readable reason if the command is dangerous, empty otherwise.
# Customize this function to add or remove patterns for your environment.
check_dangerous() {
    local cmd="$1"

    # System reboot/shutdown
    if echo "$cmd" | grep -qiE '(^|[[:space:]])(reboot|shutdown|poweroff|halt)([[:space:]]|$)'; then
        echo "restart or shut down the system"
        return 0
    fi

    # Systemctl dangerous operations
    if echo "$cmd" | grep -qiE 'systemctl[[:space:]]+(restart|stop|reboot|poweroff|halt)([[:space:]]|$)'; then
        echo "stop or restart system services"
        return 0
    fi

    # Sudo reboot/shutdown
    if echo "$cmd" | grep -qiE '(^|[[:space:]])sudo[[:space:]]+(reboot|shutdown|poweroff|halt)([[:space:]]|$)'; then
        echo "restart or shut down the system with elevated privileges"
        return 0
    fi

    # rm -rf from root (but allow /tmp paths)
    if echo "$cmd" | grep -qiE 'rm[[:space:]]+(-[rfRF]+[[:space:]]+)*/[[:space:]]*$'; then
        echo "delete from root directory"
        return 0
    fi

    if echo "$cmd" | grep -qiE 'rm[[:space:]]+-[rfRF]+[[:space:]]+/' && ! echo "$cmd" | grep -qiE 'rm[[:space:]]+-[rfRF]+[[:space:]]+/tmp'; then
        echo "recursively delete from root directory"
        return 0
    fi

    # rm -rf home directory
    if echo "$cmd" | grep -qiE 'rm[[:space:]]+-[rfRF]+[[:space:]]+~'; then
        echo "recursively delete from home directory"
        return 0
    fi

    # Kill all processes
    if echo "$cmd" | grep -qiE '(^|[[:space:]])kill[[:space:]]+(-9[[:space:]]+)?-1([[:space:]]|$)'; then
        echo "kill all processes"
        return 0
    fi

    # Force kill with pkill -9
    if echo "$cmd" | grep -qiE '(^|[[:space:]])pkill[[:space:]]+-9[[:space:]]+'; then
        echo "force kill processes"
        return 0
    fi

    # Format filesystem
    if echo "$cmd" | grep -qiE '(^|[[:space:]])mkfs'; then
        echo "format a filesystem"
        return 0
    fi

    # Direct disk write with dd
    if echo "$cmd" | grep -qiE '(^|[[:space:]])dd[[:space:]]+.*of=/dev/'; then
        echo "write directly to disk device"
        return 0
    fi

    # Destructive git: reset --hard
    if echo "$cmd" | grep -qiE '(^|[[:space:]])git[[:space:]]+reset[[:space:]]+--hard([[:space:]]|$)'; then
        echo "destroy uncommitted changes with git reset --hard"
        return 0
    fi

    # Destructive git: clean -f (unless --dry-run)
    if echo "$cmd" | grep -qiE '(^|[[:space:]])git[[:space:]]+clean[[:space:]]+-[a-zA-Z]*f' && ! echo "$cmd" | grep -qiE 'git[[:space:]]+clean[[:space:]]+.*--dry-run'; then
        echo "permanently remove untracked files with git clean -f"
        return 0
    fi

    # Destructive git: force push
    if echo "$cmd" | grep -qiE '(^|[[:space:]])git[[:space:]]+push[[:space:]]+.*--force([[:space:]]|$)|(^|[[:space:]])git[[:space:]]+push[[:space:]]+-f([[:space:]]|$)'; then
        echo "force push and potentially destroy remote history"
        return 0
    fi

    # Destructive git: stash drop/clear
    if echo "$cmd" | grep -qiE '(^|[[:space:]])git[[:space:]]+stash[[:space:]]+(drop|clear)([[:space:]]|$)'; then
        echo "permanently delete stashed changes"
        return 0
    fi

    # Not dangerous
    return 1
}

# --- Main logic ---
REASON=$(check_dangerous "$COMMAND")
if [[ -z "$REASON" ]]; then
    exit 0  # Not dangerous, allow
fi

# Check for pre-existing approval token
HASH=$(generate_hash)
APPROVAL_FILE="$APPROVED_DIR/$HASH"
PENDING_FILE="$PENDING_DIR/$HASH.json"

if [[ -f "$APPROVAL_FILE" ]]; then
    # Consume the single-use approval token
    rm -f "$APPROVAL_FILE"
    rm -f "$PENDING_FILE"
    exit 0  # Allow
fi

# Write pending file (for external approval systems to read)
cat > "$PENDING_FILE" << PENDING_EOF
{
  "hash": "$HASH",
  "session_id": "$SESSION_ID",
  "command": $(echo "$COMMAND" | jq -Rs .),
  "reason": "$REASON",
  "timestamp": $(date +%s)
}
PENDING_EOF

# --- Notification hook point ---
# This is where you'd add your own notification system.
# In production, we send a Discord message with Approve/Deny buttons.
# You could also:
#   - Send a Slack message
#   - Trigger a webhook
#   - Send a desktop notification (notify-send, osascript)
#   - Write to a log file for manual review
#
# To approve externally, create the approval token file:
#   touch /tmp/claude-dangerous/approved/$HASH
#
# Example desktop notification (uncomment to use):
# notify-send "Claude Code: Dangerous Command Blocked" "$REASON: $COMMAND" 2>/dev/null || true

# Deny the command with a clear explanation
cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "BLOCKED: This command would $REASON. To approve, create the token file: touch $APPROVAL_FILE"
  }
}
EOF
exit 0
